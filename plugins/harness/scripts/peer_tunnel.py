# peer hub 의 ssh -R 역터널을 감독(재기동·백오프)하고 서버 연결 설정·점검을 돕는 모듈 겸 CLI
"""peer_tunnel — hub serve 루프가 tick() 으로 구동하는 역터널 감독자.

- 로컬 hub(127.0.0.1) 를 원격 머신의 루프백 고정 포트로 노출한다(ssh -R, 아웃바운드만 사용).
- 별칭 원천: PEER_TUNNEL_HOSTS → peer_ssh_notify.sh hosts-list(peer_hosts 등록부).
- 토큰·호스트명·별칭 원문과 ssh stderr 원문은 로그·출력·상태 파일에 남기지 않는다(별칭은 해시 8자 id).
- 데몬 스레드를 쓰지 않는다. hub serve 루프(단일 스레드)가 tick() 을 비차단으로 호출한다.
"""
from __future__ import print_function

import argparse
import hashlib
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import peer_common as C  # noqa: E402

ALIAS_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._@-]{0,63}")
CLIENT_HOME_RE = re.compile(r"/[A-Za-z0-9._/-]{1,200}")
HOSTS_REFRESH_SEC = 300
HOSTS_LIST_TIMEOUT = 1.0
SHORT_UPTIME = 30.0
BACKOFF_MAX = 300.0


def _env_float(name, default, lo=None):
    try:
        v = float(os.environ.get(name, ""))
    except ValueError:
        return default
    if lo is not None and v < lo:
        return default
    return v


def remote_port():
    try:
        v = int(os.environ.get("PEER_TUNNEL_REMOTE_PORT", ""))
    except ValueError:
        return C.PORT_MIN
    return v if 1024 <= v <= 65535 else C.PORT_MIN


def enabled():
    """PEER_TUNNEL=0 이면 끔. 시험 모드(PEER_TEST_MODE=1)는 PEER_TUNNEL=1 일 때만 켠다."""
    v = os.environ.get("PEER_TUNNEL", "").strip()
    if v == "0":
        return False
    if os.environ.get("PEER_TEST_MODE", "").strip() == "1":
        return v == "1"
    return True


def alias_id(alias):
    return hashlib.sha256(alias.encode("utf-8", "replace")).hexdigest()[:8]


def tunnels_dir(home=None):
    return os.path.join(home or C.hub_home(), "tunnels")


def ssh_cmd():
    return os.environ.get("PEER_TUNNEL_SSH") or "ssh"


def _read_cmdline(pid):
    try:
        with open("/proc/%d/cmdline" % int(pid), "rb") as f:
            return [x.decode("utf-8", "replace") for x in f.read().split(b"\0") if x]
    except (OSError, ValueError, TypeError):
        return []


def _is_tunnel_proc(pid, start, exe):
    """pid 파일의 pid_start·exe 가 모두 있고 /proc 의 시작 시각과 실행기 이름이 일치할 때만 우리 터널로 본다."""
    if not start or not exe or not C.pid_alive(pid, start):
        return False
    argv = _read_cmdline(pid)
    if "-R" not in argv:
        return False
    return any(os.path.basename(x) == exe for x in argv[:3])


def _kill_pid(pid, grace=2.0):
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        return
    end = time.time() + grace
    while time.time() < end:
        if not C.pid_alive(pid):
            return
        time.sleep(0.05)
    try:
        os.kill(pid, signal.SIGKILL)
    except OSError:
        pass


class _Tun(object):
    def __init__(self, alias):
        self.alias = alias
        self.id = alias_id(alias)
        self.proc = None
        self.pid = None
        self.pid_start = None
        self.spawned_at = 0.0
        self.since = 0.0
        self.restarts = 0
        self.fails = 0
        self.next_try = 0.0
        self.reason = "pending"
        self.last_exit = ""
        self.state = "down"


class Supervisor(object):
    def __init__(self, home, local_port, log):
        self.home = home
        self.local_port = int(local_port)
        self._log = log
        self.dir = tunnels_dir(home)
        self.tick_sec = _env_float("PEER_TUNNEL_TICK", 5.0, 0.0)
        self.base = _env_float("PEER_TUNNEL_BACKOFF_BASE", 5.0, 0.0)
        self.alive_sec = int(_env_float("PEER_TUNNEL_ALIVE_SEC", 15, 1))
        self.remote = remote_port()
        self.tuns = {}
        self.rejected = {}
        self._last_tick = 0.0
        self._hosts = []
        self._hosts_at = 0.0
        self._hosts_proc = None
        self._hosts_started = 0.0
        self._first = True
        self._warned = set()
        self._stopped = False
        try:
            C.ensure_dir(self.dir)
            os.chmod(self.dir, 0o700)
        except OSError:
            pass
        self._reap_orphans()

    # ── 로그(원문 금지) ──
    def log(self, line):
        try:
            self._log(line)
        except Exception:
            pass

    def _warn_once(self, key, line):
        if key not in self._warned:
            self._warned.add(key)
            self.log(line)

    # ── 고아 정리 ──
    def _reap_orphans(self):
        try:
            names = os.listdir(self.dir)
        except OSError:
            return
        for n in names:
            if not n.endswith(".json") or n == "state.json":
                continue
            p = os.path.join(self.dir, n)
            d = C.read_json(p, {}) or {}
            pid, st = d.get("pid"), d.get("pid_start")
            if pid and _is_tunnel_proc(pid, st, d.get("exe")):
                _kill_pid(int(pid))
                self.log("TUNNEL stop id=%s reason=orphan" % n[:-5][:8])
            try:
                os.unlink(p)
            except OSError:
                pass

    # ── 별칭 목록 ──
    def _hosts_from_env(self):
        v = os.environ.get("PEER_TUNNEL_HOSTS")
        if v is None or not v.strip():
            return None
        return [x for x in re.split(r"[,\s]+", v.strip()) if x]

    def _hosts_cmd(self):
        return ["bash", os.path.join(C.scripts_dir(), "peer_ssh_notify.sh"), "hosts-list"]

    def _parse_hosts(self, text):
        return [x.strip() for x in text.splitlines() if x.strip()]

    def _refresh_hosts(self, now):
        env = self._hosts_from_env()
        if env is not None:
            self._hosts, self._hosts_at = env, now
            return
        p = self._hosts_proc
        if p is not None:  # 비차단 수거
            rc = p.poll()
            if rc is None:
                if now - self._hosts_started > HOSTS_LIST_TIMEOUT:
                    try:
                        p.kill()
                        p.wait()
                    except Exception:
                        pass
                    self._hosts_proc = None
                    self.log("TUNNEL hosts_list_timeout")
                return
            try:
                out = p.stdout.read().decode("utf-8", "replace") if p.stdout else ""
                if p.stdout:
                    p.stdout.close()
            except Exception:
                out = ""
            self._hosts_proc = None
            if rc == 0:
                self._hosts = self._parse_hosts(out)
                self._hosts_at = now
                if not self._hosts:
                    self._warn_once("nohosts", "TUNNEL hosts_empty")
            else:
                self._hosts_at = now
                self._warn_once("hostsfail", "TUNNEL hosts_list_failed rc=%s" % rc)
            return
        if self._hosts_at and now - self._hosts_at < HOSTS_REFRESH_SEC:
            return
        try:
            if self._first:  # 기동 직후 첫 1회만 timeout ≤1초 동기 호출
                r = subprocess.Popen(self._hosts_cmd(), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                     stdin=subprocess.DEVNULL, close_fds=True)
                try:
                    out, _ = r.communicate(timeout=HOSTS_LIST_TIMEOUT)
                    if r.returncode == 0:
                        self._hosts = self._parse_hosts(out.decode("utf-8", "replace"))
                        if not self._hosts:
                            self._warn_once("nohosts", "TUNNEL hosts_empty")
                    else:
                        self._warn_once("hostsfail", "TUNNEL hosts_list_failed rc=%s" % r.returncode)
                except subprocess.TimeoutExpired:
                    r.kill()
                    r.communicate()
                    self.log("TUNNEL hosts_list_timeout")
                self._hosts_at = now
            else:
                self._hosts_proc = subprocess.Popen(self._hosts_cmd(), stdout=subprocess.PIPE,
                                                    stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL,
                                                    close_fds=True)
                self._hosts_started = now
        except OSError:
            self._hosts_at = now
            self._warn_once("hostsfail", "TUNNEL hosts_list_failed rc=spawn")

    # ── ssh 기동/종료 ──
    def _pid_path(self, t):
        return os.path.join(self.dir, "%s.json" % t.id)

    def _err_path(self, t):
        return os.path.join(self.dir, "%s.err" % t.id)

    def _argv(self, t):
        return [ssh_cmd(), "-N", "-T",
                "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes",
                "-o", "ServerAliveInterval=%d" % self.alive_sec, "-o", "ServerAliveCountMax=3",
                "-o", "ConnectTimeout=10", "-o", "ControlMaster=no", "-o", "ControlPath=none",
                "-R", "127.0.0.1:%d:127.0.0.1:%d" % (self.remote, self.local_port),
                "--", t.alias]

    def _spawn(self, t, now):
        try:
            efd = os.open(self._err_path(t), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            os.fchmod(efd, 0o600)
        except OSError:
            efd = None
        try:
            t.proc = subprocess.Popen(self._argv(t), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                      stderr=efd if efd is not None else subprocess.DEVNULL,
                                      close_fds=True, start_new_session=True)
        except OSError:
            t.proc = None
            t.fails += 1
            t.reason = "exit_rc127"
            t.last_exit = t.reason
            t.state = "down"
            t.next_try = now + self._delay(t)
            self.log("TUNNEL exit id=%s reason=%s uptime=0s next=%ds" % (t.id, t.reason, int(self._delay(t))))
            return
        finally:
            if efd is not None:
                os.close(efd)
        t.pid = t.proc.pid
        t.pid_start = C.pid_start(t.pid)
        t.spawned_at = now
        t.since = now
        t.state = "up"
        t.reason = "up"
        try:
            C.atomic_write_json(self._pid_path(t), {"pid": t.pid, "pid_start": t.pid_start,
                                                    "remote": self.remote, "local": self.local_port,
                                                    "exe": os.path.basename(ssh_cmd())}, mode=0o600)
        except OSError:
            pass
        self.log("TUNNEL up id=%s remote=%d local=%d" % (t.id, self.remote, self.local_port))

    def _delay(self, t):
        if t.fails <= 0:
            return self.base
        return min(self.base * (2 ** min(t.fails - 1, 12)), BACKOFF_MAX)

    def _rm_err(self, t):
        try:
            os.unlink(self._err_path(t))
        except OSError:
            pass

    def _classify(self, t, rc):
        try:
            with open(self._err_path(t), "rb") as f:
                f.seek(0, os.SEEK_END)
                n = f.tell()
                f.seek(max(0, n - 4096))
                tail = f.read().decode("utf-8", "replace")
        except OSError:
            tail = ""
        if "remote port forwarding failed" in tail:
            return "forward_failed"
        if "Permission denied" in tail:
            return "auth_failed"
        return "exit_rc%s" % rc

    def _on_exit(self, t, rc, now):
        uptime = now - t.spawned_at
        t.fails = t.fails + 1 if uptime < SHORT_UPTIME else 0
        t.reason = self._classify(t, rc)
        t.last_exit = t.reason
        self._rm_err(t)
        t.state = "down"
        t.proc, t.pid = None, None
        t.restarts += 1
        t.next_try = now + self._delay(t)
        try:
            os.unlink(self._pid_path(t))
        except OSError:
            pass
        self.log("TUNNEL exit id=%s reason=%s uptime=%ds next=%ds" % (t.id, t.reason, int(uptime), int(self._delay(t))))

    def _stop_tun(self, t):
        p = t.proc
        if p is not None and p.poll() is None:
            try:
                p.terminate()
            except OSError:
                pass
            try:
                p.wait(timeout=2)
            except subprocess.TimeoutExpired:
                try:
                    p.kill()
                    p.wait(timeout=2)
                except Exception:
                    pass
        t.proc, t.pid, t.state = None, None, "stopped"
        self._rm_err(t)
        try:
            os.unlink(self._pid_path(t))
        except OSError:
            pass
        self.log("TUNNEL stop id=%s" % t.id)

    # ── 상태 파일(별칭·호스트명 미포함) ──
    def _write_state(self, enabled_flag=True):
        rows = []
        for t in self.tuns.values():
            rows.append({"id": t.id, "state": t.state,
                         "pid_alive": bool(t.proc is not None and t.proc.poll() is None),
                         "restarts": t.restarts, "reason": t.reason, "last_exit": t.last_exit,
                         "remote_port": self.remote, "local_port": self.local_port, "since": t.since})
        for i, why in self.rejected.items():
            rows.append({"id": i, "state": "rejected", "pid_alive": False, "restarts": 0, "reason": why, "last_exit": "",
                         "remote_port": self.remote, "local_port": self.local_port, "since": 0})
        try:
            C.atomic_write_json(os.path.join(self.dir, "state.json"),
                                {"tunnels": rows, "enabled": bool(enabled_flag)}, mode=0o600)
        except OSError:
            pass

    # ── 주기 구동 ──
    def tick(self):
        try:
            if self._stopped:
                return
            now = time.time()
            if now - self._last_tick < self.tick_sec:
                return
            self._last_tick = now
            self._refresh_hosts(now)
            self._first = False
            want = {}
            for a in self._hosts:
                if ALIAS_RE.fullmatch(a):
                    want[a] = True
                else:
                    i = alias_id(a)
                    if i not in self.rejected:
                        self.rejected[i] = "bad_alias"
                        self.log("TUNNEL reject id=%s reason=bad_alias" % i)
            for a in want:
                if a not in self.tuns:
                    self.tuns[a] = _Tun(a)
            for a in list(self.tuns):
                t = self.tuns[a]
                if a not in want:
                    self._stop_tun(t)
                    del self.tuns[a]
                    continue
                if t.proc is not None:
                    rc = t.proc.poll()
                    if rc is not None:
                        self._on_exit(t, rc, now)
                    elif t.last_exit and now - t.spawned_at >= self.alive_sec:
                        t.last_exit = ""  # alive 1주기 이상 유지됐을 때만 비운다
                if t.proc is None and now >= t.next_try:
                    self._spawn(t, now)
            self._write_state(True)
        except Exception as e:
            self.log("TUNNEL tick_error %s" % type(e).__name__)

    def stop(self):
        self._stopped = True
        try:
            if self._hosts_proc is not None:
                try:
                    self._hosts_proc.kill()
                    self._hosts_proc.wait()
                except Exception:
                    pass
            for t in list(self.tuns.values()):
                self._stop_tun(t)
            self.tuns.clear()
            self._write_state(False)
        except Exception as e:
            self.log("TUNNEL stop_error %s" % type(e).__name__)


# ── CLI ──────────────────────────────────────────────────────────────────
REMOTE_SETUP_SCRIPT = """import os, re, sys, tempfile
lines = sys.stdin.read().split("\\n")
url = lines[0].strip() if len(lines) > 0 else ""
tok = lines[1].strip() if len(lines) > 1 else ""
home = lines[2].strip() if len(lines) > 2 else ""
if not re.fullmatch(r"http://127\\.0\\.0\\.1:\\d{4,5}", url) or not re.fullmatch(r"[A-Za-z0-9_\\-]{20,128}", tok):
    sys.exit(7)
d = home or os.path.expanduser("~/.config/claude-peer")
os.makedirs(d, 0o700, exist_ok=True)
os.chmod(d, 0o700)
fd, tmp = tempfile.mkstemp(dir=d, prefix=".env.")
with os.fdopen(fd, "w") as f:
    f.write("PEER_HUB_URL=%s\\nPEER_TOKEN=%s\\n" % (url, tok))
os.chmod(tmp, 0o600)
os.replace(tmp, os.path.join(d, "env"))
print("ENV_WRITTEN")
"""

REMOTE_CHECK_SCRIPT = """import urllib.request as u
try:
    r = u.urlopen("http://127.0.0.1:%d/v1/health", timeout=5)
    print("HEALTH", r.status)
except Exception:
    print("HEALTH_FAIL")
"""


def _ssh_remote(alias, remote_cmd, stdin_text, timeout=40):
    argv = [ssh_cmd(), "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "--", alias, remote_cmd]
    try:
        r = subprocess.run(argv, input=(stdin_text or "").encode("utf-8"), stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return 255, ""
    return r.returncode, r.stdout.decode("utf-8", "replace")


def _port_arg(v):
    if v is None:
        return remote_port()
    if not (1024 <= v <= 65535):
        raise ValueError("port")
    return v


def cmd_status(a):
    st = C.read_json(os.path.join(tunnels_dir(), "state.json"), None)
    if a.json:
        print(json.dumps(st if st is not None else {"tunnels": [], "enabled": False}, ensure_ascii=False))
        return 0
    rows = (st or {}).get("tunnels") or []
    if not rows:
        print("TUNNEL none")
        return 0
    for r in rows:
        print("TUNNEL %s %s restarts=%s reason=%s last_exit=%s" % (
            r.get("id"), r.get("state"), r.get("restarts"), r.get("reason"), r.get("last_exit") or "-"))
    return 0


def cmd_setup_remote(a):
    alias = a.alias
    if not ALIAS_RE.fullmatch(alias or ""):
        print("peer_tunnel: 별칭 형식 오류", file=sys.stderr)
        return 2
    try:
        port = _port_arg(a.remote_port)
    except ValueError:
        print("peer_tunnel: --remote-port 범위 오류", file=sys.stderr)
        return 2
    chome = a.remote_client_home or ""
    if chome and (not CLIENT_HOME_RE.fullmatch(chome) or ".." in chome.split("/")):
        print("peer_tunnel: --remote-client-home 형식 오류", file=sys.stderr)
        return 2
    home = C.hub_home()
    if not os.path.exists(C.tokens_path(home)):
        print("peer_tunnel: 토큰 저장소 없음 — hub 가 한 번도 기동되지 않았다", file=sys.stderr)
        return 5
    import peer_hub  # Tokens 만 사용(Tokens.init() 호출 금지: admin 토큰 부작용)
    tk = peer_hub.Tokens(home)
    tid = alias_id(alias)
    label = "tunnel:%s" % tid
    j = tk.join_issue(300)
    mtok = tk.join_exchange(j, label)
    if not mtok:
        print("peer_tunnel: 머신 토큰 발급 실패", file=sys.stderr)
        return 5
    new_hash = C.token_hash(mtok)

    def _revoke_new():
        def f(d):
            m = d.get("machines", {}).get(new_hash)
            if m:
                m["revoked"] = True
                m["revoked_at"] = C.now()
        tk.update(f)

    url = "http://127.0.0.1:%d" % port
    rc, out = _ssh_remote(alias, "python3 -c " + shlex.quote(REMOTE_SETUP_SCRIPT),
                          "%s\n%s\n%s\n" % (url, mtok, chome))
    if rc == 255:
        _revoke_new()
        print("peer_tunnel: SSH_FAILED", file=sys.stderr)
        return 3
    if rc != 0 or "ENV_WRITTEN" not in out:
        _revoke_new()
        print("peer_tunnel: REMOTE_WRITE_FAILED", file=sys.stderr)
        return 4
    if not a.keep_old:
        def f2(d):
            now = C.now()
            for k, m in d.get("machines", {}).items():
                if m.get("label") == label and k != new_hash and not m.get("revoked"):
                    m["revoked"] = True
                    m["revoked_at"] = now
        tk.update(f2)
    print("REMOTE_SETUP_OK id=%s remote_port=%d" % (tid, port))
    return 0


def cmd_check_remote(a):
    alias = a.alias
    if not ALIAS_RE.fullmatch(alias or ""):
        print("peer_tunnel: 별칭 형식 오류", file=sys.stderr)
        return 2
    try:
        port = _port_arg(a.remote_port)
    except ValueError:
        print("peer_tunnel: --remote-port 범위 오류", file=sys.stderr)
        return 2
    rc, out = _ssh_remote(alias, "python3 -c " + shlex.quote(REMOTE_CHECK_SCRIPT % port), "", timeout=30)
    if rc == 0 and re.search(r"^HEALTH 200\s*$", out, re.M):
        print("REMOTE_HEALTH ok")
        return 0
    print("REMOTE_HEALTH fail")
    return 1


def main(argv=None):
    ap = argparse.ArgumentParser(prog="peer_tunnel.py")
    sub = ap.add_subparsers(dest="cmd")
    sub.required = True
    p = sub.add_parser("status")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_status)
    p = sub.add_parser("setup-remote")
    p.add_argument("alias")
    p.add_argument("--remote-port", type=int, default=None)
    p.add_argument("--keep-old", action="store_true")
    p.add_argument("--remote-client-home", default=None)
    p.set_defaults(fn=cmd_setup_remote)
    p = sub.add_parser("check-remote")
    p.add_argument("alias")
    p.add_argument("--remote-port", type=int, default=None)
    p.set_defaults(fn=cmd_check_remote)
    a = ap.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
