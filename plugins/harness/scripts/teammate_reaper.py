#!/usr/bin/env python3
# 팀원(claude --agent-id) 프로세스를 자기 세션 done 지속·리더 사망 고아 기준으로 정리하는 스크립트(dry-run 기본)
"""팀원 프로세스 정리기.

모드(하나 이상 지정)
  --self-done    자기 세션(--uuid) 팀원 중 tmux @agent_state=done 이 --done-min 분 지속된 것만 종료한다.
                 agent_keep/<name>(사유 5자 이상·KEEP_TTL 분 유효)·no_kill/<name> 이 있으면 면제한다.
  --orphans      리더 세션이 죽은 팀원만 종료한다. 죽음 증명은 3조건 AND 이며 하나라도 불확실하면 건드리지 않는다.
                   1) 등록부(sessions/*.json pid+procStart) 생존 집합에 부모 세션이 없음(등록부 읽기 실패·0건 = fail-closed)
                   2) 팀원 pane 이 속한 tmux 서버의 모든 pane 프로세스 트리에 --agent-id 없는 claude(리더)가 0개
                      (tmux 조회 실패·소켓 식별 실패·pane 미발견 = fail-closed)
                   3) 팀원 경과시간 ≥ --orphan-grace-min 분
                 리더 사망 확정 외의 조건(done·장기 실행)으로는 kill 하지 않는다. 타 세션 session-env 는 읽지 않는다.
  --report-long  자기 세션 팀원 중 경과 ≥ --long-min 분 또는 RSS ≥ --rss-mb MB 를 출력한다(kill 안 함).
                 같은 팀원 반복 보고는 --suppress-min 분 억제. 새 보고가 있으면 rc=10.

--apply 가 없으면 dry-run 이다(프로세스에 신호를 보내지 않는다). 관측 기록(logs/teammate_reaper_*.json)·로그만 쓴다.
kill 직전 /proc/<pid>/stat starttime 과 cmdline 을 다시 대조해 PID 재사용을 막는다. SIGTERM → 5초 → 생존분 SIGKILL.
쓰기 경로: 자기 session-env/<uuid>/logs/ 와 ~/.claude/logs/ 뿐.

rc: 0 정상 / 1 오류·fail-closed / 2 인자 오류 / 10 report-long 새 보고 있음
"""

import argparse
import datetime
import json
import os
import re
import signal
import subprocess
import sys
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)
try:
    import harness_cleanup as hc  # live_session_ids·pid_alive·proc_starttime·default_registry_dirs 재사용
except Exception as _e:  # noqa: BLE001 — import 실패는 orphans fail-closed 로 처리
    hc = None
    HC_IMPORT_ERR = repr(_e)
else:
    HC_IMPORT_ERR = ""

UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
NAME_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
KEEP_TTL_SEC = int(os.environ.get("TIG_KEEP_TTL_MIN", "120")) * 60  # teammate_idle_guard 와 같은 값
KEEP_MIN_REASON = 5
TERM_WAIT_SEC = 5
TMUX_TIMEOUT = 3
CLK_TCK = os.sysconf("SC_CLK_TCK") if hasattr(os, "sysconf") else 100
HOME_LOGS = os.path.join(os.path.expanduser("~"), ".claude", "logs")


# ─────────────────────────── 공용 유틸 ───────────────────────────
def now_iso():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def read_bytes(path, limit=1 << 20):
    try:
        with open(path, "rb") as f:
            return f.read(limit)
    except OSError:
        return None


def proc_starttime(pid):
    if hc is not None:
        return hc.proc_starttime(pid)
    b = read_bytes("/proc/%d/stat" % pid)
    if not b:
        return None
    s = b.decode("utf-8", "replace")
    try:
        return s[s.rindex(")") + 2:].split()[19]
    except (ValueError, IndexError):
        return None


def proc_ppid(pid):
    b = read_bytes("/proc/%d/stat" % pid)
    if not b:
        return None
    s = b.decode("utf-8", "replace")
    try:
        return int(s[s.rindex(")") + 2:].split()[1])
    except (ValueError, IndexError):
        return None


def proc_args(pid):
    b = read_bytes("/proc/%d/cmdline" % pid)
    if not b:
        return []
    return [a.decode("utf-8", "replace") for a in b.split(b"\0") if a]


def proc_environ(pid):
    b = read_bytes("/proc/%d/environ" % pid)
    env = {}
    if not b:
        return env
    for kv in b.split(b"\0"):
        if b"=" in kv:
            k, v = kv.split(b"=", 1)
            env[k.decode("utf-8", "replace")] = v.decode("utf-8", "replace")
    return env


def proc_rss_mb(pid):
    b = read_bytes("/proc/%d/status" % pid)
    if not b:
        return 0
    for ln in b.decode("utf-8", "replace").splitlines():
        if ln.startswith("VmRSS:"):
            try:
                return int(ln.split()[1]) // 1024
            except (ValueError, IndexError):
                return 0
    return 0


def uptime_sec():
    b = read_bytes("/proc/uptime")
    try:
        return float(b.split()[0])
    except (AttributeError, ValueError, IndexError):
        return None


def etimes(starttime):
    up = uptime_sec()
    if up is None or starttime is None:
        return None
    try:
        return max(0, int(up - int(starttime) / float(CLK_TCK)))
    except ValueError:
        return None


def pid_alive(pid):
    if hc is not None:
        return hc.pid_alive(pid)
    try:
        os.kill(pid, 0)
        return True
    except PermissionError:
        return True
    except OSError:
        return False


def arg_value(args, flag):
    for i, a in enumerate(args):
        if a == flag and i + 1 < len(args):
            return args[i + 1]
        if a.startswith(flag + "="):
            return a.split("=", 1)[1]
    return ""


def is_claude(pid, args):
    """claude 실행 파일 프로세스인지(argv0 basename=claude 또는 exe 가 claude/versions/ 아래)."""
    if args and os.path.basename(args[0]) == "claude":
        return True
    try:
        exe = os.readlink("/proc/%d/exe" % pid)
    except OSError:
        exe = ""
    return "/claude/versions/" in exe or (args and "/claude/versions/" in args[0])


def load_json(path, default):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def save_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    os.replace(tmp, path)


def append_log(path, line):
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a", encoding="utf-8") as f:
            f.write("%s %s\n" % (now_iso(), line))
    except OSError:
        pass


# ─────────────────────────── 프로세스 스캔 ───────────────────────────
def scan_procs():
    """자기 uid 프로세스 전체 {pid: {args, ppid}} 와 팀원 목록."""
    uid = os.getuid()
    procs = {}
    try:
        ents = os.listdir("/proc")
    except OSError:
        return procs, []
    for e in ents:
        if not e.isdigit():
            continue
        pid = int(e)
        try:
            if os.stat("/proc/%d" % pid).st_uid != uid:
                continue
        except OSError:
            continue
        args = proc_args(pid)
        if not args:
            continue
        procs[pid] = {"args": args, "ppid": proc_ppid(pid)}
    mates = []
    for pid, p in procs.items():
        args = p["args"]
        if "--agent-id" not in args and not any(a.startswith("--agent-id=") for a in args):
            continue
        aid = arg_value(args, "--agent-id")
        st = proc_starttime(pid)
        mates.append({
            "pid": pid,
            "start": st,
            "agent_id": aid,
            "name": arg_value(args, "--agent-name") or aid.split("@", 1)[0],
            "parent": arg_value(args, "--parent-session-id"),
            "etimes": etimes(st),
            "rss_mb": proc_rss_mb(pid),
        })
    return procs, mates


def filter_only(mates, only):
    if not only:
        return mates
    return [m for m in mates if m["pid"] in only]


# ─────────────────────────── tmux ───────────────────────────
class Tmux:
    """소켓별 list-panes 결과 캐시. 실패는 None."""

    def __init__(self):
        self.cache = {}

    def panes(self, sock):
        if sock in self.cache:
            return self.cache[sock]
        res = None
        try:
            r = subprocess.run(["tmux", "-S", sock, "list-panes", "-a", "-F",
                                "#{pane_id}\t#{pane_pid}\t#{@agent_state}"],
                               capture_output=True, text=True, timeout=TMUX_TIMEOUT)
            if r.returncode == 0:
                res = []
                for ln in r.stdout.splitlines():
                    f = ln.split("\t")
                    f += [""] * (3 - len(f))
                    try:
                        res.append({"id": f[0], "pid": int(f[1]), "state": f[2].strip()})
                    except ValueError:
                        continue
        except Exception:  # noqa: BLE001 — timeout·실행 실패 = 판정 불가
            res = None
        self.cache[sock] = res
        return res


def tmux_socket(pid):
    v = proc_environ(pid).get("TMUX", "")
    sock = v.split(",", 1)[0] if v else ""
    return sock if sock.startswith("/") else ""


def ancestors(pid, procs, depth=40):
    out = []
    cur = pid
    for _ in range(depth):
        out.append(cur)
        pp = procs.get(cur, {}).get("ppid")
        if pp is None:
            pp = proc_ppid(cur)
        if not pp or pp <= 1 or pp == cur:
            break
        cur = pp
    return out


def find_pane(pid, panes, procs):
    """팀원 pid 가 속한 pane(pane_pid 가 자기 자신 또는 조상). 없으면 None."""
    anc = set(ancestors(pid, procs))
    for p in panes:
        if p["pid"] in anc:
            return p
    return None


def descendants(roots, procs):
    kids = {}
    for pid, p in procs.items():
        kids.setdefault(p.get("ppid"), []).append(pid)
    seen, stack = set(), list(roots)
    while stack:
        x = stack.pop()
        if x in seen:
            continue
        seen.add(x)
        stack.extend(kids.get(x, []))
    return seen


# ─────────────────────────── 종료 ───────────────────────────
def same_proc(m):
    """kill 직전 PID 재사용 대조: starttime·agent-id 가 스캔 때와 같아야 한다."""
    if proc_starttime(m["pid"]) != m["start"] or m["start"] is None:
        return False
    return arg_value(proc_args(m["pid"]), "--agent-id") == m["agent_id"]


def terminate(targets, log_path):
    """SIGTERM → 최대 5초 대기 → 생존분 SIGKILL. 결과 {pid: 상태}."""
    res = {}
    sent = []
    for m in targets:
        if not same_proc(m):
            res[m["pid"]] = "skip_pid_reused"
            append_log(log_path, "SKIP pid=%d name=%s 사유=PID 재사용/소멸" % (m["pid"], m["name"]))
            continue
        append_log(log_path, "TERM pid=%d name=%s agent=%s parent=%s 사유=%s"
                   % (m["pid"], m["name"], m["agent_id"], m["parent"], m.get("reason", "")))
        try:
            os.kill(m["pid"], signal.SIGTERM)
            sent.append(m)
            res[m["pid"]] = "term"
        except OSError as e:
            res[m["pid"]] = "term_fail:%s" % e.__class__.__name__
    deadline = time.monotonic() + TERM_WAIT_SEC
    while sent and time.monotonic() < deadline:
        sent = [m for m in sent if pid_alive(m["pid"]) and same_proc(m)]
        if sent:
            time.sleep(0.25)
    for m in sent:
        if not same_proc(m):
            continue
        append_log(log_path, "KILL pid=%d name=%s (SIGTERM 후 %d초 생존)" % (m["pid"], m["name"], TERM_WAIT_SEC))
        try:
            os.kill(m["pid"], signal.SIGKILL)
            res[m["pid"]] = "kill"
        except OSError as e:
            res[m["pid"]] = "kill_fail:%s" % e.__class__.__name__
    return res


# ─────────────────────────── 세션 경로 ───────────────────────────
def session_dir(args):
    if args.session_dir:
        return args.session_dir
    cands = [os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or "", "session-env", args.uuid),
             os.path.join(os.path.expanduser("~"), ".claude", "session-env", args.uuid)]
    for c in cands:
        if c and os.path.isdir(c) and not c.startswith("session-env"):
            return c
    return cands[-1]


def is_self_mate(m, uuid):
    return m["parent"] == uuid and m["agent_id"].endswith("@session-" + uuid[:8])


def keep_ok(sdir, name, now):
    """agent_keep 유효(사유 5자 이상·TTL 이내)."""
    if not NAME_RE.match(name):
        return False
    p = os.path.join(sdir, "agent_keep", name)
    try:
        reason = open(p, encoding="utf-8", errors="replace").read().strip()
        age = now - os.path.getmtime(p)
    except OSError:
        return False
    return len(reason.replace(" ", "")) >= KEEP_MIN_REASON and age <= KEEP_TTL_SEC


def no_kill(sdir, name):
    return NAME_RE.match(name) is not None and os.path.exists(os.path.join(sdir, "no_kill", name))


# ─────────────────────────── 모드: self-done ───────────────────────────
def run_self_done(args, procs, mates, out):
    sdir = session_dir(args)
    logs = os.path.join(sdir, "logs")
    seen_path = os.path.join(logs, "teammate_reaper_seen.json")
    log_path = os.path.join(logs, "teammate_reaper.log")
    seen = load_json(seen_path, {})
    if not isinstance(seen, dict):
        seen = {}
    now = time.time()
    tm = Tmux()
    mine = [m for m in mates if is_self_mate(m, args.uuid)]
    new_seen, targets, items = {}, [], []
    for m in mine:
        key = "%s|%d|%s" % (m["name"], m["pid"], m["start"])
        sock = tmux_socket(m["pid"])
        panes = tm.panes(sock) if sock else None
        pane = find_pane(m["pid"], panes, procs) if panes else None
        state = pane["state"] if pane else ""
        it = {"pid": m["pid"], "name": m["name"], "state": state or "?", "action": "none"}
        if state != "done":
            it["reason"] = "상태 %s" % (state or "미확인(tmux/pane 없음)")
            items.append(it)
            continue
        since = seen.get(key, {}).get("since", now) if isinstance(seen.get(key), dict) else now
        new_seen[key] = {"since": since, "pid": m["pid"], "name": m["name"]}
        age = int(now - since)
        it["done_sec"] = age
        if no_kill(sdir, m["name"]):
            it["reason"] = "no_kill 면제"
        elif keep_ok(sdir, m["name"], now):
            it["reason"] = "agent_keep 면제"
        elif age < args.done_min * 60:
            it["reason"] = "done %d분 < %d분" % (age // 60, args.done_min)
        else:
            it["action"] = "kill" if args.apply else "would_kill"
            it["reason"] = "done %d분 지속" % (age // 60)
            m["reason"] = "self-done " + it["reason"]
            targets.append(m)
        items.append(it)
    try:
        save_json(seen_path, new_seen)
    except OSError as e:
        out["errors"].append("seen 기록 실패: %s" % e)
    if args.apply and targets:
        res = terminate(targets, log_path)
        for it in items:
            if it["pid"] in res:
                it["result"] = res[it["pid"]]
    out["self_done"] = {"session_dir": sdir, "mates": len(mine), "items": items,
                        "targets": len(targets)}


# ─────────────────────────── 모드: orphans ───────────────────────────
def registry_dirs(args):
    if args.registry_dir:
        return list(args.registry_dir)
    ns = argparse.Namespace(profile_glob=args.profile_glob)
    return hc.default_registry_dirs(ns)


def run_orphans(args, procs, mates, out):
    log_path = args.log_file or os.path.join(HOME_LOGS, "teammate_reaper.log")
    res = {"items": [], "targets": 0, "fail_closed": ""}
    out["orphans"] = res
    if hc is None:
        res["fail_closed"] = "harness_cleanup import 실패: %s" % HC_IMPORT_ERR
        return 1
    live = hc.live_session_ids(registry_dirs(args))
    if not live:
        res["fail_closed"] = "등록부 읽기 실패 또는 생존 세션 0건"
        return 1
    tm = Tmux()
    targets = []
    for m in mates:
        it = {"pid": m["pid"], "name": m["name"], "parent": m["parent"][:8], "action": "none"}
        res["items"].append(it)
        if not UUID_RE.match(m["parent"] or ""):
            it["reason"] = "부모 세션 id 불명(불확실)"
            continue
        if m["parent"] in live:
            it["reason"] = "리더 생존(등록부)"
            continue
        sock = tmux_socket(m["pid"])
        if not sock:
            it["reason"] = "tmux 소켓 식별 실패(불확실)"
            continue
        panes = tm.panes(sock)
        if panes is None:
            it["reason"] = "tmux 조회 실패(불확실)"
            continue
        if find_pane(m["pid"], panes, procs) is None:
            it["reason"] = "pane 미발견(불확실)"
            continue
        tree = descendants([p["pid"] for p in panes], procs)
        leaders = [x for x in tree if x in procs and is_claude(x, procs[x]["args"])
                   and "--agent-id" not in procs[x]["args"]
                   and not any(a.startswith("--agent-id=") for a in procs[x]["args"])]
        if leaders:
            it["reason"] = "tmux 서버에 리더 claude %d개 생존" % len(leaders)
            continue
        if m["etimes"] is None or m["etimes"] < args.orphan_grace_min * 60:
            it["reason"] = "유예 미달(%s초 < %d분)" % (m["etimes"], args.orphan_grace_min)
            continue
        it["action"] = "kill" if args.apply else "would_kill"
        it["reason"] = "리더 사망 확정(등록부 부재+tmux 리더 0+유예 경과)"
        m["reason"] = "orphan " + it["reason"]
        targets.append(m)
    res["targets"] = len(targets)
    if args.apply and targets:
        r = terminate(targets, log_path)
        for it in res["items"]:
            if it["pid"] in r:
                it["result"] = r[it["pid"]]
    return 0


# ─────────────────────────── 모드: report-long ───────────────────────────
def run_report_long(args, mates, out):
    sdir = session_dir(args)
    sup_path = os.path.join(sdir, "logs", "teammate_reaper_long.json")
    sup = load_json(sup_path, {})
    if not isinstance(sup, dict):
        sup = {}
    now = time.time()
    items, fresh = [], 0
    new_sup = {}
    for m in mates:
        if not is_self_mate(m, args.uuid):
            continue
        long_t = m["etimes"] is not None and m["etimes"] >= args.long_min * 60
        big = m["rss_mb"] >= args.rss_mb
        if not (long_t or big):
            continue
        key = "%s|%d|%s" % (m["name"], m["pid"], m["start"])
        last = sup.get(key, 0) if isinstance(sup.get(key), (int, float)) else 0
        suppressed = now - last < args.suppress_min * 60
        new_sup[key] = last if suppressed else now
        if not suppressed:
            fresh += 1
        items.append({"pid": m["pid"], "name": m["name"], "min": (m["etimes"] or 0) // 60,
                      "rss_mb": m["rss_mb"], "suppressed": suppressed})
    try:
        save_json(sup_path, new_sup)
    except OSError as e:
        out["errors"].append("억제 기록 실패: %s" % e)
    out["report_long"] = {"items": items, "fresh": fresh}
    return fresh


# ─────────────────────────── 출력 ───────────────────────────
def summary_lines(out):
    lines = []
    mode = "apply" if out["apply"] else "dry-run"
    sd = out.get("self_done")
    if sd is not None:
        lines.append("[self-done/%s] 자기 팀원 %d · 대상 %d · %s" % (
            mode, sd["mates"], sd["targets"],
            ", ".join("%s(%s)" % (i["name"], i.get("result", i["action"])) for i in sd["items"]
                      if i["action"] != "none") or "종료 없음"))
    orp = out.get("orphans")
    if orp is not None:
        if orp["fail_closed"]:
            lines.append("[orphans/%s] fail-closed: %s (kill 0)" % (mode, orp["fail_closed"]))
        else:
            unk = sum(1 for i in orp["items"] if "불확실" in i.get("reason", ""))
            lines.append("[orphans/%s] 팀원 %d · 고아 확정 %d · 불확실 %d · %s" % (
                mode, len(orp["items"]), orp["targets"], unk,
                ", ".join("%s@%s(%s)" % (i["name"], i["parent"], i.get("result", i["action"]))
                          for i in orp["items"] if i["action"] != "none") or "종료 없음"))
    rl = out.get("report_long")
    if rl is not None:
        if rl["items"]:
            lines.append("[report-long] 교대 권고 %d명(새 보고 %d): %s" % (
                len(rl["items"]), rl["fresh"],
                ", ".join("%s %d분 %dMB%s" % (i["name"], i["min"], i["rss_mb"],
                                              " (억제)" if i["suppressed"] else "") for i in rl["items"])))
        else:
            lines.append("[report-long] 장기·고RSS 팀원 없음")
    for e in out["errors"][:2]:
        lines.append("[오류] %s" % e)
    return lines[:5]


def build_parser():
    p = argparse.ArgumentParser(description="팀원 프로세스 정리기(dry-run 기본)")
    p.add_argument("--self-done", action="store_true")
    p.add_argument("--orphans", action="store_true")
    p.add_argument("--report-long", action="store_true")
    p.add_argument("--apply", action="store_true")
    p.add_argument("--uuid", default="")
    p.add_argument("--session-dir", default="")
    p.add_argument("--done-min", type=int, default=10)
    p.add_argument("--orphan-grace-min", type=int, default=15)
    p.add_argument("--long-min", type=int, default=90)
    p.add_argument("--rss-mb", type=int, default=1200)
    p.add_argument("--suppress-min", type=int, default=30)
    p.add_argument("--registry-dir", action="append", default=[])
    p.add_argument("--profile-glob", default="/tmp/cc-*")
    p.add_argument("--log-file", default="")
    p.add_argument("--only-pids", default="", help="시험용: 대상 후보를 이 pid 목록(쉼표)으로 제한")
    p.add_argument("--json", action="store_true")
    return p


def main(argv=None):
    p = build_parser()
    args = p.parse_args(argv)
    if not (args.self_done or args.orphans or args.report_long):
        p.error("--self-done / --orphans / --report-long 중 하나 이상 필요")
    if (args.self_done or args.report_long) and not UUID_RE.match(args.uuid):
        p.error("--self-done/--report-long 은 올바른 --uuid 가 필요")
    only = set()
    if args.only_pids:
        try:
            only = {int(x) for x in args.only_pids.split(",") if x.strip()}
        except ValueError:
            p.error("--only-pids 는 쉼표 구분 정수")
    out = {"ts": now_iso(), "apply": args.apply, "errors": []}
    procs, mates = scan_procs()
    mates = filter_only(mates, only)
    rc = 0
    if args.self_done:
        run_self_done(args, procs, mates, out)
    if args.orphans:
        rc = max(rc, run_orphans(args, procs, mates, out))
    fresh = 0
    if args.report_long:
        fresh = run_report_long(args, mates, out)
    if args.json:
        print(json.dumps(out, ensure_ascii=False))
    else:
        print("\n".join(summary_lines(out)))
    if rc:
        return rc
    return 10 if fresh else 0


if __name__ == "__main__":
    sys.exit(main())
