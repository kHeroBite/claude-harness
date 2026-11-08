#!/usr/bin/env python3
# 같은 롤 세션 인계 — 동작 중인 같은 project·롤 세션을 찾아 중지시키고 대화·세션 정보를 받아 여기서 이어 가게 하는 도구
"""peer_takeover — 같은 롤 세션 인계(bin/cc 가 롤 확정 뒤·cas 기동 전에 부른다).

사용법:
  peer_takeover.py check --project P --role <롤[:영역][#이름]> [--json]
      → 줄마다 `CONFLICT local <key> <label>` / `CONFLICT remote <key> <label>`, 없으면 `NONE`. rc 0(사용법 오류 2)
        대상 = 로컬 role_registry live(pid+start 생존) ∪ host 목록(peer_common.discover_hub, 없으면 로컬만).
        같은 롤·같은 영역이면 충돌이다. 요청 값에 이름(#이름)이 있으면 같은 이름일 때만 충돌로 본다. all 은 충돌 없음.
  peer_takeover.py run --project P --role <값> --kind local|remote --key K --cwd <이 세션 작업폴더> [--force-sync] [--sid S] [--pick-tty]
      0) 로컬 sid 확정(중지 전) (a) /proc/<pid>/fd 의 대화·작업 폴더 경로 (b) cmdline --session-id/--resume(시작 뒤 같은 롤
                           값으로 갱신된 다른 sid 가 없을 때만). 못 정하면 추정하지 않는다 — --pick-tty 면 후보(갱신 시각·첫 입력
                           40자)에서 고르고, 아니면 rc 40 SID_AMBIGUOUS(후보 있음)·SID_NOT_FOUND(후보 없음)로 대상을 멈추지 않는다
      1) 사전 동기화 확인  로컬=대상 cwd 의 git, 원격=heartbeat 의 git{head,dirty,ahead}. dirty·미push 면 rc 30(--force-sync 로만 진행)
      2) 중지              로컬=pid_start 재검증 후 SIGTERM, 최대 PEER_TAKEOVER_STOP_WAIT(15)초 확인. SIGKILL 은 쓰지 않는다
                           원격=host takeover 요청 → 대상 peer_mcp 가 묶음 업로드 → ack stopped
      3) 이관              로컬=같은 sid 재개(파일 이동 없음). 원격=묶음(본 대화+팀원 대화+session-env 허용 목록)을 받아
                           conv_share import 경로로 넣는다(마스킹은 보내는 쪽 pack 이 conv_share 규칙으로 한다)
      4) 사후 동기화       이 세션 저장소 fetch → 대상 HEAD 로 fast-forward. 실패 rc 31(대화는 받아 둔 채 RESUME_SID 출력)
      5) 출력              `RESUME_SID=<sid>` · `RESUME_CWD=<폴더>` · `RESUME_VALUE=<롤 값>`
  peer_takeover.py pack --sid S --cwd C --project P --role V --out FILE     (대상 측 peer_mcp 가 부른다)
      → 마지막 줄 `PACKED sha256=<hex> bytes=<n> git_head=<sha|->`
  peer_takeover.py import-bundle --file F --project P --cwd C              (내부·시험용) 묶음을 이 머신에 넣는다

종료 코드: 0 완료 · 2 사용법 · 3 host 없음(원격 대상인데 host 부재) · 10 취소 · 20 중지 실패(거절·시간 초과 포함)
          · 30 동기화 차단 · 31 사후 fast-forward 실패 · 40 이관 실패(대상 없음·sid 없음·묶음 오류 — 받은 것은 원복)
로그: <peer 루트>/logs/peer_takeover.log 에 단계마다 1줄(토큰·본문 미기록).
배치(실측 2026-11-08): 본 대화 <홈>/projects/<enc(cwd)>/<sid>.jsonl, 팀원 대화 <홈>/projects/<enc(cwd)>/<sid>/subagents/agent-<id>.jsonl·.meta.json
"""
from __future__ import print_function

import argparse
import contextlib
import io
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import peer_common as pc  # noqa: E402

SID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
AGENT_FILE_RE = re.compile(r"agent-[A-Za-z0-9_-]{1,64}\.(?:jsonl|meta\.json)")
SHA_RE = re.compile(r"[0-9a-f]{40,64}")
# session-env 에서 옮기는 허용 목록(그 밖은 묶지 않고 받지도 않는다). 디렉터리 항목은 '/' 로 끝난다.
SESSION_ALLOW_FILES = ("goal.json", "role", "role_asked", "role_session_source", "checkpoint.jsonl", "next_action.json",
                       "handoff_main.md", "role_state/handoffs.json", "role_state/peer_roles.json")
SESSION_ALLOW_DIRS = ("plans/",)
SESSION_ALLOW_EXT = (".md", ".json", ".jsonl", ".txt")
SESSION_FILE_MAX = 2 * 1024 * 1024
BUNDLE_FILES_MAX = 500
REASON_TEXT = {
    "OBSERVER_ABSENT": "대상 머신의 대리(미러) 프로세스가 없다",
    "OBSERVER_NO_TAKEOVER": "대상 머신의 대리 프로세스가 구판이라 인계를 지원하지 않는다(하네스 갱신 필요)",
    "OBSERVER_TAKEOVER_OFF": "대상 머신의 대리 프로세스가 인계를 꺼 두었다(PEER_ALLOW_TAKEOVER=0)",
    "HUB_OLD": "host 가 구판이라 observed 대상 인계를 지원하지 않는다",
}
TAKEOVER_NAME = "takeover"  # 원격 인계 요청자가 hub 에 임시 등록할 때 쓰는 이름(목록 충돌 판정에서 제외)

RC_OK, RC_USAGE, RC_HOST, RC_CANCEL, RC_STOP, RC_SYNC, RC_FF, RC_MOVE = 0, 2, 3, 10, 20, 30, 31, 40


class Fail(Exception):
    def __init__(self, msg, rc):
        super(Fail, self).__init__(msg)
        self.rc = rc


# ───────────────────────── 공통 ─────────────────────────

def env_float(name, default):
    try:
        return float(os.environ.get(name, "") or default)
    except ValueError:
        return float(default)


def log(step, msg):
    """단계 로그 1줄. sid(UUID)는 앞 8자만 남기고(redact 가 36자 UUID 를 통째로 가리므로 먼저 줄인다) 토큰 모양 문자열은 가린다."""
    try:
        d = os.path.join(pc.inbox_root(), "logs")
        pc.ensure_dir(d)
        msg = re.sub(SID_RE.pattern, lambda m: m.group(0)[:8], str(msg))
        with open(os.path.join(d, "peer_takeover.log"), "a", encoding="utf-8") as f:
            f.write("%s step=%s %s\n" % (pc.iso(), step, pc.redact(msg)))
    except OSError:
        pass


def say(msg):
    sys.stderr.write("peer_takeover: %s\n" % pc.redact(msg))


_RL = []


def role_lib():
    """role_lib 을 불러온다(소스 .claude/hooks/lib → 배포본 hooks/lib → 홈 순). 없으면 None."""
    if _RL:
        return _RL[0]
    cands = [os.environ.get("PEER_TAKEOVER_ROLE_LIB", ""), os.path.join(HERE, "..", "hooks", "lib"),
             os.path.join(os.path.expanduser("~"), ".claude", "hooks", "lib")]
    mod = None
    for d in cands:
        if d and os.path.isfile(os.path.join(d, "role_lib.py")):
            if d not in sys.path:
                sys.path.insert(0, d)
            try:
                import role_lib as rl  # noqa: E402
                mod = rl
            except Exception:
                mod = None
            break
    _RL.append(mod)
    return mod


def conv_share():
    import conv_share as cs  # noqa: E402  같은 폴더
    return cs


def parse_value(value):
    """'back:결제#철수' → ('back','결제','철수'). role_lib 이 있으면 그 규칙을 쓴다."""
    rl = role_lib()
    if rl is not None:
        try:
            return rl.parse_value(value)
        except Exception:
            pass
    v, name = (value or "").strip(), ""
    if "#" in v:
        v, name = v.split("#", 1)
    if ":" in v:
        a, b = v.split(":", 1)
        return a, b, name
    return v, "", name


def same_role(req, other):
    """요청 값과 다른 세션 값이 인계 대상(같은 롤·영역)인가. 요청에 이름이 있으면 같은 이름만."""
    r1, a1, n1 = parse_value(req)
    r2, a2, n2 = parse_value(other)
    if not r1 or r1 == "all" or r1 != r2 or (a1 or "") != (a2 or ""):
        return False
    if n1:
        return (n2 or "").lower() == n1.lower()
    return True


def home_base():
    return os.environ.get("ROLE_HOME_BASE", "").strip() or os.path.join(os.path.expanduser("~"), ".claude")


def enc(cwd):
    return re.sub(r"[^A-Za-z0-9]", "-", cwd)


def find_transcript(sid, config_dir=""):
    """sid 의 본 대화 파일. config_dir(대상 세션의 CLAUDE_CONFIG_DIR)가 있으면 그 아래 projects 를 먼저, 없으면 home_base 를 본다.
    하네스에서는 둘 다 같은 저장소의 심볼릭 링크지만, 별도 base 를 쓰는 환경도 지원한다."""
    bases = []
    if config_dir and os.path.isabs(config_dir):
        bases.append(os.path.join(config_dir, "projects"))
    hp = os.path.join(home_base(), "projects")
    if hp not in bases:
        bases.append(hp)
    for pdir in bases:
        try:
            for d in sorted(os.listdir(pdir)):
                p = os.path.join(pdir, d, sid + ".jsonl")
                if os.path.isfile(p):
                    return p
        except OSError:
            pass
    return ""


def git(cwd, *args, **kw):
    """git 실행 → (rc, stdout). 실패해도 예외 없음."""
    try:
        p = subprocess.run(["git", "-C", cwd] + list(args), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           stdin=subprocess.DEVNULL, timeout=kw.get("timeout", 30), universal_newlines=True)
        return p.returncode, (p.stdout or "").strip()
    except (OSError, subprocess.SubprocessError):
        return 127, ""


def git_state(cwd):
    """{head, dirty, ahead} 또는 None(git 저장소 아님). ahead = 어느 원격에도 없는 커밋 수(원격이 없으면 0)."""
    if not cwd or not os.path.isdir(cwd):
        return None
    rc, out = git(cwd, "rev-parse", "--is-inside-work-tree")
    if rc != 0 or out != "true":
        return None
    _, head = git(cwd, "rev-parse", "HEAD")
    _, st = git(cwd, "status", "--porcelain", "--untracked-files=no")
    _, remotes = git(cwd, "remote")
    ahead = 0
    if remotes.strip():
        rc, cnt = git(cwd, "rev-list", "--count", "HEAD", "--not", "--remotes")
        ahead = int(cnt) if rc == 0 and cnt.isdigit() else 0
    return {"head": head, "dirty": bool(st.strip()), "ahead": ahead}


def same_tree(a, b):
    try:
        return bool(a and b) and os.path.realpath(a) == os.path.realpath(b)
    except OSError:
        return False


# ───────────────────────── check ─────────────────────────

def local_conflicts(project, value):
    rl = role_lib()
    if rl is None:
        return []
    out = []
    try:
        ents = rl.live_entries(project.lower())
    except Exception:
        return []
    for e in ents:
        v = e.get("value") or rl.join_value(e.get("role", ""), e.get("area", ""), e.get("name", ""))
        if same_role(value, v):
            out.append({"kind": "local", "key": e.get("_key", ""), "value": v, "pid": e.get("pid"),
                        "pid_start": e.get("pid_start"), "updated_ts": e.get("updated_ts", 0),
                        "tmux": ("%s:%s" % (e.get("tmux_session", "-"), e.get("pane", "-"))
                                 if e.get("tmux_session") else ""),
                        "label": "%s@%s:%s" % (v, e.get("tmux_session", "-"), e.get("pane", "-"))})
    return out


def hub_sessions(project, rid):
    url, tok, _src = pc.discover_hub()
    if not url:
        return None, None, None
    q = "project=%s" % project.lower() + ("&role=%s" % rid if rid else "")
    st, obj = pc.http_json(url + "/v1/sessions?" + q, token=tok, timeout=5)
    if st != 200:
        log("check", "hub sessions status=%s err=%s" % (st, obj.get("error", "")))
        return url, tok, None
    rows = obj.get("sessions")
    if not isinstance(rows, list):
        rows = []
    return url, tok, rows


def remote_value(s):
    v = str(s.get("value") or s.get("role") or "")
    name = str(s.get("name") or "")
    if name and "#" not in v:
        v = v + "#" + name
    return v


def remote_conflicts(project, value, locals_):
    rid = parse_value(value)[0]
    _u, _t, rows = hub_sessions(project, rid)
    if not rows:
        return []
    me = pc.machine_id()
    local_pids = set((str(c.get("pid")), str(c.get("pid_start"))) for c in locals_)
    out = []
    for s in rows:
        if not isinstance(s, dict) or not pc.KEY_RE.fullmatch(str(s.get("session_key", ""))):
            continue
        if str(s.get("project", "")).lower() != project.lower() or s.get("name") == TAKEOVER_NAME:
            continue  # 다른 프로젝트, 또는 인계 요청자의 임시 등록
        v = remote_value(s)
        if not same_role(value, v):
            continue
        same_machine = s.get("machine_id") == me
        if same_machine and s.get("pid") is not None:
            if not pc.pid_alive(s.get("pid"), s.get("pid_start")):
                log("check", "dead same-machine host entry skip pid=%s" % s.get("pid"))
                continue  # 같은 머신인데 프로세스가 죽은 host 잔존 항목은 충돌이 아니다
            if (str(s.get("pid")), str(s.get("pid_start"))) in local_pids:
                continue  # 같은 머신의 같은 프로세스는 로컬 항목으로 이미 잡았다
        label = "%s@%s%s" % (v, re.sub(r"\s", "_", str(s.get("machine_label") or "remote"))[:64],
                             "(같은 머신)" if same_machine and s.get("pid") is not None else "")
        tm = str(s.get("tmux_session") or "")
        if tm and s.get("tmux_pane"):
            tm = "%s:%s" % (tm, s.get("tmux_pane"))
        out.append({"kind": "remote", "key": s["session_key"], "value": v, "label": label, "git": s.get("git") or {},
                    "takeover": takeover_code(s), "same_machine": same_machine, "observed": bool(s.get("observed")),
                    "machine_label": re.sub(r"\s", "_", str(s.get("machine_label") or ""))[:64],
                    "host_tag": str(s.get("host_tag") or ""), "tmux": tm, "active_ts": s.get("active_ts") or 0,
                    "age": s.get("age")})
    return out


def takeover_code(s):
    """원격 항목의 인계 가능 코드. 직접 등록=ok, observed 인데 hub 응답에 takeover 필드가 없으면 구 hub(HUB_OLD)."""
    if not s.get("observed"):
        return "ok"
    if "takeover" not in s:
        return "HUB_OLD"
    return str(s.get("takeover") or "OBSERVER_ABSENT")


def _ago(sec):
    sec = max(0, int(sec))
    if sec < 60:
        return "%d초" % sec
    if sec < 3600:
        return "%d분" % (sec // 60)
    if sec < 86400:
        return "%d시간" % (sec // 3600)
    return "%d일" % (sec // 86400)


def _emoji(tag):
    """host_label 의 DEFAULT_EMOJI 재사용(없으면 빈 문자열)."""
    try:
        d = os.path.join(HERE, "..", "hooks", "lib")
        if d not in sys.path:
            sys.path.insert(0, d)
        import host_label as hl  # noqa: E402
        if tag:
            return hl.DEFAULT_EMOJI.get(tag, "")
        return hl.host_emoji()
    except Exception:
        return ""


def build_detail(r, now=None):
    """DETAIL 줄 1개 (takeover 코드, 같은/다른 머신, 설명). 토큰·sid·session_key·호스트명은 넣지 않는다."""
    now = now or time.time()
    parts = [r.get("value", "")]
    if r["kind"] == "local":
        code, host = "ok", "same"
        em = _emoji("")
        parts.append(("%s " % em if em else "") + "같은 머신")
        ts = r.get("activity_ts") or 0
        if r.get("tmux"):
            parts.append("tmux %s" % r["tmux"])
        if ts:
            parts.append("마지막 활동 %s 전" % _ago(now - ts))
    else:
        code, host = r.get("takeover", "ok"), ("same" if r.get("same_machine") else "other")
        em = _emoji(r.get("host_tag", ""))
        ml = r.get("machine_label", "")
        parts.append(("%s " % em if em else "") + ("같은 머신" if r.get("same_machine") else "다른 머신")
                     + ("(%s)" % ml if ml and not r.get("same_machine") else ""))
        if r.get("tmux"):
            parts.append("tmux %s" % r["tmux"])
        ts = float(r.get("active_ts") or 0)
        if ts:
            parts.append("마지막 활동 %s 전" % _ago(now - ts))
        elif r.get("age") is not None:
            parts.append("연결 확인 %s 전" % _ago(float(r["age"])))
        if r.get("observed"):
            parts.append("peer 미연결(대리 등록)")
    if code != "ok":
        parts.append("인계 불가: " + REASON_TEXT.get(code, code))
    return code, host, " · ".join(p for p in parts if p)


def cmd_check(a):
    loc = local_conflicts(a.project, a.role)
    rem = remote_conflicts(a.project, a.role, loc)
    for r in loc:
        r["activity_ts"] = activity_ts(a.project, {"pid": r.get("pid"), "pid_start": r.get("pid_start"),
                                                   "updated_ts": r.get("updated_ts", 0)},
                                       target_config_dir(r.get("pid")) if r.get("pid") else "")
    rows = loc + rem
    for r in rows:
        r["takeover"], r["host"], r["detail"] = build_detail(r)
    if a.json:
        print(json.dumps([{k: r[k] for k in ("kind", "key", "label", "value", "takeover", "detail")} for r in rows],
                         ensure_ascii=False))
        return RC_OK
    if not rows:
        print("NONE")
    for r in rows:
        print("CONFLICT %s %s %s" % (r["kind"], r["key"], r["label"]))
        print("DETAIL %s takeover=%s host=%s %s" % (r["key"], r["takeover"], r["host"], r["detail"]))
    log("check", "project=%s role=%s local=%d remote=%d" % (a.project.lower(), a.role, len(loc), len(rem)))
    return RC_OK


# ───────────────────────── 묶음(pack / import) ─────────────────────────

def session_dirs(sid, config_dir=""):
    out = []
    for b in (config_dir, os.environ.get("CLAUDE_CONFIG_DIR", "").strip(), home_base()):
        if b:
            d = os.path.join(b, "session-env", sid)
            if os.path.isdir(d) and d not in out:
                out.append(d)
    return out


def session_allowed(rel):
    rel = rel.replace("\\", "/")
    if rel.startswith("/") or ".." in rel.split("/") or not rel:
        return False
    if rel in SESSION_ALLOW_FILES:
        return True
    for d in SESSION_ALLOW_DIRS:
        if rel.startswith(d) and rel.endswith(SESSION_ALLOW_EXT) and "/" not in rel[len(d):]:
            return True
    return False


def session_files(sid, config_dir=""):
    """허용 목록 파일 (rel, 절대경로). 같은 rel 은 먼저 찾은 기준(CFG → 홈)만. 심볼릭 링크·큰 파일 제외."""
    seen, out = set(), []
    for d in session_dirs(sid, config_dir):
        cands = list(SESSION_ALLOW_FILES)
        for sub in SESSION_ALLOW_DIRS:
            try:
                cands += [sub + n for n in sorted(os.listdir(os.path.join(d, sub)))]
            except OSError:
                pass
        for rel in cands:
            p = os.path.join(d, rel)
            if rel in seen or not session_allowed(rel) or os.path.islink(p) or not os.path.isfile(p):
                continue
            try:
                if os.path.getsize(p) > SESSION_FILE_MAX:
                    log("pack", "skip session file too big rel=%s" % rel)
                    continue
            except OSError:
                continue
            seen.add(rel)
            out.append((rel, p))
    return out


def mask_jsonl_bytes(raw, cs):
    counts, lines = {}, []
    for ln in raw.splitlines():
        if not ln.strip():
            continue
        try:
            o = cs.mask_obj(json.loads(ln.decode("utf-8")), counts)
        except (ValueError, UnicodeDecodeError):
            continue
        lines.append(json.dumps(o, ensure_ascii=False, separators=(",", ":")))
    return ("\n".join(lines) + "\n").encode("utf-8") if lines else b""


def _tar_add(tf, name, data):
    ti = tarfile.TarInfo(name)
    ti.size = len(data)
    ti.mode = 0o600
    ti.mtime = int(time.time())
    tf.addfile(ti, io.BytesIO(data))


def do_pack(sid, cwd, project, role, out, config_dir=""):
    """대상 측: 본 대화(conv_share export — 마스킹·상한 규칙 그대로) + 팀원 대화 + session-env 허용 목록을 tar.gz 로."""
    if not SID_RE.fullmatch(sid or ""):
        raise Fail("sid 형식 오류", RC_USAGE)
    if config_dir and not (os.path.isabs(config_dir) and os.path.isdir(config_dir)):
        config_dir = ""
    old_base = os.environ.get("ROLE_HOME_BASE")
    swapped = False
    if config_dir and not find_transcript(sid) and find_transcript(sid, config_dir):
        os.environ["ROLE_HOME_BASE"] = config_dir  # 대상 세션이 home 과 다른 base 를 쓰면 conv_share 도 그 base 를 보게 한다
        swapped = True
    try:
        return _do_pack(sid, cwd, project, role, out, config_dir)
    finally:
        if swapped:
            if old_base is None:
                os.environ.pop("ROLE_HOME_BASE", None)
            else:
                os.environ["ROLE_HOME_BASE"] = old_base


def _do_pack(sid, cwd, project, role, out, config_dir):
    cs = conv_share()
    with contextlib.redirect_stdout(sys.stderr):  # export 의 EXPORT 줄이 stdout(MCP 등)을 오염시키지 않게
        try:
            meta = cs.do_export(sid, cwd or "", project, role)
        except cs.Fail as e:
            raise Fail("본 대화 export 실패: %s" % e, RC_MOVE)
    sd = cs.stage_dir()
    with open(os.path.join(sd, sid + ".jsonl.gz"), "rb") as f:
        gz = f.read()
    tr = find_transcript(sid, config_dir)
    entries = [("conv/%s.meta.json" % sid, json.dumps(meta, ensure_ascii=False).encode("utf-8")),
               ("conv/%s.jsonl.gz" % sid, gz)]
    sub = os.path.join(os.path.dirname(tr), sid, "subagents") if tr else ""
    n_sub = 0
    if sub and os.path.isdir(sub):
        for n in sorted(os.listdir(sub)):
            p = os.path.join(sub, n)
            if not AGENT_FILE_RE.fullmatch(n) or os.path.islink(p) or not os.path.isfile(p):
                continue
            if os.path.getsize(p) > cs.MAX_BYTES:
                log("pack", "skip subagent too big name=%s" % n)
                continue
            with open(p, "rb") as f:
                raw = f.read()
            data = mask_jsonl_bytes(raw, cs)
            if data:
                entries.append(("subagents/" + n, data))
                n_sub += 1
    for rel, p in session_files(sid, config_dir):
        with open(p, "rb") as f:
            raw = f.read()
        try:
            data = cs.mask_str(raw.decode("utf-8"), {}).encode("utf-8")
        except UnicodeDecodeError:
            continue
        entries.append(("session/" + rel, data))
    if len(entries) > BUNDLE_FILES_MAX:
        raise Fail("묶음 파일 수 상한 초과", RC_MOVE)
    gs = git_state(meta.get("cwd") or cwd)
    man = {"v": 1, "sid": sid, "project": meta["project"], "role": meta.get("role") or role or "",
           "cwd": meta.get("cwd") or cwd, "git_head": (gs or {}).get("head", ""), "created": pc.iso(),
           "files": [{"path": n, "sha256": pc.sha256_bytes(d), "size": len(d)} for n, d in entries]}
    pc.ensure_dir(os.path.dirname(os.path.abspath(out)))
    fd, tmp = tempfile.mkstemp(prefix=".pt-", dir=os.path.dirname(os.path.abspath(out)))
    try:
        with os.fdopen(fd, "wb") as f:
            with tarfile.open(fileobj=f, mode="w:gz") as tf:
                _tar_add(tf, "manifest.json", json.dumps(man, ensure_ascii=False).encode("utf-8"))
                for n, d in entries:
                    _tar_add(tf, n, d)
        os.chmod(tmp, 0o600)
        os.replace(tmp, out)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    log("pack", "sid=%s files=%d subagents=%d" % (sid, len(entries), n_sub))
    return man


def read_bundle(path):
    """묶음 검증 → (manifest, {이름: bytes}). 형식·경로·sha 가 어긋나면 Fail(40)."""
    try:
        tf = tarfile.open(path, mode="r:gz")
    except (tarfile.TarError, OSError) as e:
        raise Fail("묶음을 열 수 없다: %s" % type(e).__name__, RC_MOVE)
    data = {}
    total = 0
    with tf:
        for m in tf.getmembers():
            n = m.name
            if not m.isfile() or n.startswith("/") or ".." in n.split("/") or len(data) > BUNDLE_FILES_MAX:
                raise Fail("묶음 항목 형식 오류: %s" % n[:80], RC_MOVE)
            total += m.size
            if total > 2 * 1024 * 1024 * 1024:
                raise Fail("묶음 크기 상한 초과", RC_MOVE)
            f = tf.extractfile(m)
            data[n] = f.read() if f else b""
    try:
        man = json.loads(data.pop("manifest.json").decode("utf-8"))
    except (KeyError, ValueError, UnicodeDecodeError):
        raise Fail("manifest 없음·형식 오류", RC_MOVE)
    if not isinstance(man, dict) or not SID_RE.fullmatch(str(man.get("sid", ""))):
        raise Fail("manifest sid 오류", RC_MOVE)
    listed = {}
    for it in man.get("files") or []:
        if isinstance(it, dict):
            listed[str(it.get("path", ""))] = str(it.get("sha256", ""))
    if set(listed) != set(data):
        raise Fail("manifest 와 묶음 항목 불일치", RC_MOVE)
    sid = man["sid"]
    for n, b in data.items():
        if pc.sha256_bytes(b) != listed[n]:
            raise Fail("묶음 항목 sha256 불일치: %s" % n[:80], RC_MOVE)
        ok = (n in ("conv/%s.meta.json" % sid, "conv/%s.jsonl.gz" % sid)
              or (n.startswith("subagents/") and AGENT_FILE_RE.fullmatch(n[len("subagents/"):]))
              or (n.startswith("session/") and session_allowed(n[len("session/"):])))
        if not ok:
            raise Fail("허용되지 않은 묶음 항목: %s" % n[:80], RC_MOVE)
    if "conv/%s.jsonl.gz" % sid not in data or "conv/%s.meta.json" % sid not in data:
        raise Fail("본 대화 항목 없음", RC_MOVE)
    return man, data


class Undo(object):
    """이관 중 만든 파일 목록 — 실패 시 지운다(받은 묶음 원복)."""

    def __init__(self):
        self.files = []
        self.dirs = []

    def write(self, path, data):
        d = os.path.dirname(path)
        made = []
        cur = d
        while cur and not os.path.isdir(cur):
            made.append(cur)
            cur = os.path.dirname(cur)
        pc.atomic_write(path, data, mode=0o600)
        self.files.append(path)
        self.dirs.extend(made)

    def rollback(self):
        for p in reversed(self.files):
            try:
                os.unlink(p)
            except OSError:
                pass
        for d in sorted(set(self.dirs), key=len, reverse=True):
            try:
                os.rmdir(d)
            except OSError:
                pass


def _fail_inject(step):
    # 시험 전용 주입: 원복 경로 확인용(PEER_TAKEOVER_FAIL_AT=<단계>). 운영 경로에서는 설정하지 않는다.
    if os.environ.get("PEER_TAKEOVER_FAIL_AT", "") == step:
        raise Fail("주입된 실패(%s)" % step, RC_MOVE)


def do_import(path, project, cwd):
    """묶음을 이 머신에 넣는다. 반환 manifest. 실패 시 만든 파일을 지우고 Fail(40)."""
    if not cwd or not cwd.startswith("/"):
        raise Fail("--cwd 는 절대경로여야 한다", RC_USAGE)
    cwd = os.path.abspath(cwd)
    man, data = read_bundle(path)
    sid = man["sid"]
    if str(man.get("project", "")).lower() != project.lower():
        raise Fail("프로젝트 불일치(묶음 %s ≠ %s)" % (man.get("project"), project.lower()), RC_MOVE)
    cs = conv_share()
    undo = Undo()
    pdir = os.path.join(home_base(), "projects")
    target = os.path.join(pdir, enc(cwd), sid + ".jsonl")
    target_existed = os.path.exists(target)
    inbox = cs.box("conv_inbox", project)
    inbox_existed = set(n for n in (os.listdir(inbox) if os.path.isdir(inbox) else []) if n.startswith(sid + "."))
    try:
        mraw = data["conv/%s.meta.json" % sid]
        gz = data["conv/%s.jsonl.gz" % sid]
        try:
            got, bad = cs.ingest(cs.pack(json.loads(mraw.decode("utf-8")), gz), project)
        except (cs.Fail, ValueError) as e:
            raise Fail("본 대화 수신 실패: %s" % e, RC_MOVE)
        if not any(g[0] == sid for g in got):
            raise Fail("본 대화 검증 실패(거부 %d건)" % bad, RC_MOVE)
        if not os.path.isdir(pdir):
            pc.ensure_dir(pdir)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            irc = cs.cmd_import(argparse.Namespace(project=project, cwd=cwd))
        mine = [ln for ln in buf.getvalue().splitlines() if ln.startswith("ITEM\t%s\t" % sid)]
        kind = mine[-1].split("\t")[2] if mine else ""
        if kind not in ("new", "extend", "replace", "same") or not os.path.isfile(target):
            why = " — 로컬 대화는 그대로 두었고 받은 대화는 수신함의 .conflict 기록으로 남겼다. 수동 병합 필요" if kind == "conflict" else ""
            raise Fail("본 대화 import 실패(kind=%s rc=%s)%s" % (kind or "-", irc, why), RC_MOVE)
        if not target_existed:
            undo.files.append(target)
        _fail_inject("subagents")
        src_cwd = str(man.get("cwd") or "")
        sdir = os.path.join(pdir, enc(cwd), sid, "subagents")
        n_sub = 0
        for n in sorted(data):
            if not n.startswith("subagents/"):
                continue
            dst = os.path.join(sdir, n[len("subagents/"):])
            if os.path.exists(dst):
                log("import", "keep existing subagent %s" % os.path.basename(dst))
                continue
            b = data[n]
            if dst.endswith(".jsonl") and src_cwd:
                b = ("\n".join(cs.substitute_cwd(b, src_cwd, cwd)) + "\n").encode("utf-8")
            undo.write(dst, b)
            n_sub += 1
        _fail_inject("session")
        sedir = os.path.join(home_base(), "session-env", sid)
        n_ses = 0
        for n in sorted(data):
            if not n.startswith("session/"):
                continue
            dst = os.path.join(sedir, n[len("session/"):])
            if os.path.exists(dst):
                log("import", "keep existing session file %s" % n[len("session/"):])
                continue
            undo.write(dst, data[n])
            n_ses += 1
        _fail_inject("done")
    except BaseException:
        undo.rollback()
        # 본 대화 수신함 항목·가져옴 표식도 이번에 생긴 것이면 지운다
        if os.path.isdir(inbox):
            for n in os.listdir(inbox):
                if n.startswith(sid + ".") and n not in inbox_existed:
                    try:
                        os.unlink(os.path.join(inbox, n))
                    except OSError:
                        pass
        log("import", "rollback sid=%s files=%d" % (sid, len(undo.files)))
        raise
    log("import", "sid=%s project=%s kind=%s subagents=%d session=%d" % (sid, project.lower(), kind, n_sub, n_ses))
    return man


# ───────────────────────── run ─────────────────────────

_FD_SID_RES = (re.compile(r"/projects/[^/]+/(%s)\.jsonl$" % SID_RE.pattern),
               re.compile(r"/tmp/claude-\d+/[^/]+/(%s)/tasks$" % SID_RE.pattern))


def fd_sids(pid):
    """(a) 대상 pid 가 연 파일에서 sid — projects/<enc>/<sid>.jsonl 또는 /tmp/claude-<uid>/<enc>/<sid>/tasks(실측: 작업 목록 폴더).
    /proc/<pid>/fd 의 링크 이름만 읽는다(같은 uid). 실패면 빈 집합."""
    out = set()
    d = "/proc/%d/fd" % int(pid)
    try:
        names = os.listdir(d)
    except OSError:
        return out
    for n in names:
        try:
            t = os.readlink(os.path.join(d, n))
        except OSError:
            continue
        for rx in _FD_SID_RES:
            m = rx.search(t)
            if m:
                out.add(m.group(1))
    return out


def cmdline_sid(pid):
    """(b) 대상 pid 의 cmdline 에 있는 --session-id/--resume 값(--fork-session 이 함께 있으면 실제 sid 가 달라 None)."""
    try:
        with open("/proc/%d/cmdline" % int(pid), "rb") as f:
            argv = [x.decode("utf-8", "replace") for x in f.read().split(b"\0") if x]
    except (OSError, ValueError):
        return None
    if "--fork-session" in argv:
        return None
    for i, x in enumerate(argv[:-1]):
        if x in ("--session-id", "--resume", "-r") and SID_RE.fullmatch(argv[i + 1].lower()):
            return argv[i + 1].lower()
        for k in ("--session-id=", "--resume="):
            if x.startswith(k) and SID_RE.fullmatch(x[len(k):].lower()):
                return x[len(k):].lower()
    return None


def target_config_dir(pid):
    """대상 pid 의 CLAUDE_CONFIG_DIR 값 하나만 돌려준다(/proc/<pid>/environ). 없음·권한 실패·경로 부적합이면 "".
    environ 에는 토큰 같은 다른 값이 있을 수 있어 해당 키 하나만 취하고 나머지는 보관·로그·출력하지 않는다."""
    try:
        with open("/proc/%d/environ" % int(pid), "rb") as f:
            raw = f.read()
    except (OSError, ValueError, TypeError):
        return ""
    val = ""
    key = b"CLAUDE_CONFIG_DIR="
    for item in raw.split(b"\0"):
        if item.startswith(key):
            val = item[len(key):].decode("utf-8", "replace")
            break
    raw = item = None
    if not val or not os.path.isabs(val) or not os.path.isdir(val):
        return ""
    return val


def config_dir_sid(config_dir):
    """(a') <config_dir>/session-env/ 아래 SID 형식 폴더가 정확히 1개이고 그 대화 파일이 있으면 sid, 아니면 None."""
    try:
        names = [n for n in os.listdir(os.path.join(config_dir, "session-env"))
                 if SID_RE.fullmatch(n) and os.path.isdir(os.path.join(config_dir, "session-env", n))]
    except OSError:
        return None
    if len(names) == 1 and find_transcript(names[0], config_dir):
        return names[0]
    return None


def proc_start_epoch(pid):
    """프로세스 시작 시각(epoch 초). /proc/stat btime + starttime/CLK_TCK. 실패 None."""
    st = pc.pid_start(pid)
    try:
        with open("/proc/stat") as f:
            btime = next(int(ln.split()[1]) for ln in f if ln.startswith("btime "))
        return btime + int(st) / float(os.sysconf("SC_CLK_TCK"))
    except (OSError, ValueError, TypeError, StopIteration):
        return None


def transcript_cwd(tr):
    try:
        with open(tr, encoding="utf-8", errors="replace") as f:
            for ln in f:
                try:
                    o = json.loads(ln)
                except ValueError:
                    continue
                if isinstance(o, dict) and isinstance(o.get("cwd"), str) and o["cwd"]:
                    return o["cwd"]
    except OSError:
        pass
    return ""


def first_prompt(tr, width=40):
    """후보 표시용 첫 사용자 입력 요약(제어문자 제거, width 자)."""
    try:
        with open(tr, encoding="utf-8", errors="replace") as f:
            for ln in f:
                try:
                    o = json.loads(ln)
                except ValueError:
                    continue
                if not isinstance(o, dict) or o.get("type") != "user":
                    continue
                c = (o.get("message") or {}).get("content")
                if isinstance(c, list):
                    c = " ".join(x.get("text", "") for x in c if isinstance(x, dict) and x.get("type") == "text")
                if isinstance(c, str) and c.strip():
                    s = re.sub(r"[\x00-\x1f\x7f]+", " ", c).strip()
                    try:
                        s = conv_share().mask_str(s, {})  # 화면에도 비밀값은 가린다(conv_share 마스킹 규칙)
                    except Exception:
                        pass
                    return s[:width]
    except OSError:
        pass
    return ""


def _value_records(project, value, config_dir=""):
    rl = role_lib()
    out = {}
    if rl is None:
        return out
    for r in rl.resume_records(project.lower()):
        sid = str(r.get("sid", ""))
        if not SID_RE.fullmatch(sid):
            continue
        rv = r.get("value") or rl.join_value(r.get("role", ""), r.get("area", ""), r.get("name", ""))
        if rv == value and find_transcript(sid, config_dir):
            out[sid] = r
    return out


def local_sid_candidates(project, entry, config_dir=""):
    """대상 live 항목의 sid 판별. 반환 (확정 sid 또는 None, 후보 [(sid, cwd, 갱신시각, 요약)], 근거).

    결정적 수단을 순서대로 쓴다.
      (a) /proc/<pid>/fd 의 대화·작업 폴더 경로 — 후보가 정확히 1개(대화 파일 존재)면 확정
      (b) /proc/<pid>/cmdline 의 --session-id/--resume — 그 프로세스 시작 뒤 같은 롤 값으로 갱신된 다른 sid 가
          재개 색인에 없을 때만 확정(세션 안 /clear·/resume 으로 sid 가 바뀐 경우를 가려낸다)
      (c) host 의 sid 는 인계 API 로만 요청자에게 오므로 로컬 대상에는 쓰지 않는다
      (d) role_registry live 에는 sid 를 기록하지 않는다(role_lib 설계 — 세션 UUID 비노출)
    결정이 안 되면 후보(같은 롤 값으로 그 프로세스 시작 뒤 갱신된 재개 기록)를 돌려주고 호출자가 고르게 한다."""
    pid = entry.get("pid")
    recs = _value_records(project, entry["value"], config_dir)
    if pid and pc.pid_alive(pid, entry.get("pid_start")):
        fs = set(s for s in fd_sids(pid) if find_transcript(s, config_dir))
        if len(fs) == 1:
            return fs.pop(), [], "fd"
        if config_dir:  # (a') 세션마다 CONFIG_DIR 가 분리되어 session-env 폴더가 프로세스와 1:1 이다
            ds = config_dir_sid(config_dir)
            if ds:
                return ds, [], "config_dir"
        t0 = proc_start_epoch(pid)
        after = set(s for s, r in recs.items() if t0 is not None and float(r.get("updated_ts", 0) or 0) >= t0 - 1)
        cs = cmdline_sid(pid)
        if cs and find_transcript(cs, config_dir):
            if not (after - {cs}):
                return cs, [], "cmdline"
            cand = sorted(after | {cs})
        else:
            cand = sorted(after | fs)
    else:
        cand = sorted(recs)  # 이미 끝난 대상: 결정적 수단이 없다 — 후보는 같은 롤 값의 재개 기록 전체
    rows = []
    for s in cand:
        tr = find_transcript(s, config_dir)
        r = recs.get(s, {})
        try:
            mt = os.path.getmtime(tr)
        except OSError:
            mt = 0
        rows.append((s, r.get("cwd") or transcript_cwd(tr), mt, first_prompt(tr)))
    rows.sort(key=lambda x: x[2], reverse=True)
    return None, rows, "ambiguous" if len(rows) >= 2 else ("none" if not rows else "single-guess")


def pick_candidate(rows, tty):
    """후보 중 사용자 선택. 시험 주입 PEER_TAKEOVER_SID_PICK=<번호>. 비 tty·취소면 None."""
    inj = os.environ.get("PEER_TAKEOVER_SID_PICK", "").strip()
    if not tty and not inj:
        return None
    lines = ["인계할 대화를 고르세요(대상 세션의 sid 를 결정적으로 찾지 못했습니다):"]
    for i, (s, _c, mt, fp) in enumerate(rows, 1):
        lines.append("  [%d] %s  %s  %s" % (i, time.strftime("%m-%d %H:%M", time.localtime(mt)) if mt else "-", s[:8],
                                           fp or "(내용 없음)"))
    lines.append("  [Enter] 취소")
    if inj:
        sys.stderr.write("\n".join(lines) + "\n  선택: %s (주입)\n" % inj)
        ans = inj
    else:
        try:
            with open("/dev/tty", "r+") as tt:
                tt.write("\n".join(lines) + "\n  선택: ")
                tt.flush()
                ans = tt.readline().strip()
        except OSError:
            return None
    if ans.isdigit() and 1 <= int(ans) <= len(rows):
        return rows[int(ans) - 1]
    return None


def sync_gate(gs, force, where):
    if not gs:
        log("presync", "%s skip(not git)" % where)
        return
    if gs.get("dirty") or int(gs.get("ahead") or 0) > 0:
        msg = "대상 저장소에 반영 안 된 변경이 있다(dirty=%s ahead=%s) — 대상에서 커밋·push 한 뒤 다시 하거나 --force-sync" % (
            bool(gs.get("dirty")), gs.get("ahead") or 0)
        if not force:
            log("presync", "%s block dirty=%s ahead=%s" % (where, bool(gs.get("dirty")), gs.get("ahead")))
            raise Fail(msg, RC_SYNC)
        log("presync", "%s forced dirty=%s ahead=%s" % (where, bool(gs.get("dirty")), gs.get("ahead")))
        say("⚠️ " + msg + " — --force-sync 로 진행")
        return
    log("presync", "%s ok head=%s" % (where, (gs.get("head") or "")[:12]))


def post_sync(my_cwd, target_head):
    """이 세션 저장소를 대상 HEAD 로 fast-forward. 문제 없으면 None, 실패면 사유 문자열."""
    mine = git_state(my_cwd)
    if not mine or not target_head or not SHA_RE.fullmatch(target_head):
        log("postsync", "skip(mine_git=%s head=%s)" % (bool(mine), bool(target_head)))
        return None
    _, remotes = git(my_cwd, "remote")
    if remotes.strip():
        rc, _ = git(my_cwd, "fetch", "--quiet", "--all", timeout=60)
        if rc != 0:
            log("postsync", "fetch rc=%d" % rc)
    if git(my_cwd, "cat-file", "-e", target_head + "^{commit}")[0] != 0:
        return "대상 HEAD %s 를 이 저장소에서 찾지 못했다(fetch 후에도 없음)" % target_head[:12]
    head = mine["head"]
    if head == target_head or git(my_cwd, "merge-base", "--is-ancestor", target_head, head)[0] == 0:
        log("postsync", "ok up-to-date head=%s" % head[:12])
        return None
    if git(my_cwd, "merge-base", "--is-ancestor", head, target_head)[0] != 0:
        return "이 저장소와 대상 HEAD 가 갈라져 fast-forward 할 수 없다"
    rc, _ = git(my_cwd, "merge", "--ff-only", "--quiet", target_head)
    if rc != 0:
        return "fast-forward 실패(작업 트리 변경과 겹침 등) rc=%d" % rc
    log("postsync", "ff %s→%s" % (head[:12], target_head[:12]))
    return None


def resolve_entry_sid(project, entry, sid_arg="", pick_tty=False, config_dir=""):
    """live 항목의 sid 확정 → (sid, cwd, how). 못 정하면 Fail(SID_NOT_FOUND|SID_AMBIGUOUS, RC_MOVE). 대상은 건드리지 않는다."""
    how = "arg"
    if sid_arg:
        sid = sid_arg.lower() if SID_RE.fullmatch(sid_arg.lower()) and find_transcript(sid_arg.lower(), config_dir) else None
        if not sid:
            raise Fail("SID_NOT_FOUND --sid 의 대화 파일이 없다 — 중지하지 않았다", RC_MOVE)
    else:
        sid, rows, how = local_sid_candidates(project, entry, config_dir)
        if not sid:
            if not rows:
                raise Fail("SID_NOT_FOUND 대상 세션의 대화(sid)를 찾지 못했다 — 중지하지 않았다", RC_MOVE)
            got = pick_candidate(rows, pick_tty)
            if not got:
                raise Fail("SID_AMBIGUOUS 대상 세션의 대화를 결정적으로 찾지 못했다(후보 %d개) — 중지하지 않았다. "
                           "tty 에서 다시 실행해 고르거나 --sid 로 지정하라" % len(rows), RC_MOVE)
            sid, how = got[0], "picked"
    tr = find_transcript(sid, config_dir)
    rec = _value_records(project, entry.get("value", ""), config_dir).get(sid, {})
    log("resolve", "sid=%s by=%s" % (sid, how))  # sid 는 log() 가 앞 8자만 남긴다. 토큰·경로는 기록하지 않는다
    return sid, rec.get("cwd") or transcript_cwd(tr) or "", how


def activity_ts(project, entry, config_dir=""):
    """마지막 활동 시각(epoch). fd→config_dir→cmdline 로 sid 를 얻으면 그 대화 파일 mtime(내용은 읽지 않음), 못 얻으면 entry.updated_ts."""
    pid = entry.get("pid")
    try:
        if pid and pc.pid_alive(pid, entry.get("pid_start")):
            sid = None
            fs = set(s for s in fd_sids(pid) if find_transcript(s, config_dir))
            if len(fs) == 1:
                sid = fs.pop()
            if not sid and config_dir:
                sid = config_dir_sid(config_dir)
            if not sid:
                cs = cmdline_sid(pid)
                if cs and find_transcript(cs, config_dir):
                    sid = cs
            if sid:
                return float(os.path.getmtime(find_transcript(sid, config_dir)))
    except OSError:
        pass
    try:
        return float(entry.get("updated_ts", 0) or 0)
    except (TypeError, ValueError):
        return 0.0


def _stop_local(pid, start):
    """pid_start 재검증 → SIGTERM → 최대 PEER_TAKEOVER_STOP_WAIT 초 확인. SIGKILL 없음."""
    if pid and pc.pid_alive(pid, start):
        try:
            os.kill(int(pid), signal.SIGTERM)
        except OSError as ex:
            log("stop", "local kill err=%s" % type(ex).__name__)
            raise Fail("중지 신호를 보내지 못했다(%s) — 이관하지 않았다" % type(ex).__name__, RC_STOP)
        end = time.time() + env_float("PEER_TAKEOVER_STOP_WAIT", 15)
        while time.time() < end and pc.pid_alive(pid, start):
            time.sleep(0.2)
        if pc.pid_alive(pid, start):
            log("stop", "local timeout pid=%s" % pid)
            raise Fail("대상 세션이 %.0f초 안에 끝나지 않았다 — 이관하지 않았다(강제 종료는 하지 않음)"
                       % env_float("PEER_TAKEOVER_STOP_WAIT", 15), RC_STOP)
        log("stop", "local stopped pid=%s" % pid)
    else:
        log("stop", "local already-stopped")


def run_local(a):
    rl = role_lib()
    if rl is None:
        raise Fail("role_lib 을 찾지 못했다", RC_MOVE)
    path = os.path.join(rl.live_dir(a.project.lower()), a.key + ".json")
    e = rl.read_json(path, {}) if re.fullmatch(r"[A-Za-z0-9._-]{1,128}", a.key or "") else {}
    if not e:
        raise Fail("대상 세션을 찾지 못했다: local %s" % a.key, RC_MOVE)
    e["value"] = e.get("value") or rl.join_value(e.get("role", ""), e.get("area", ""), e.get("name", ""))
    if not same_role(a.role, e["value"]):
        raise Fail("대상 롤이 요청과 다르다(%s ≠ %s)" % (e["value"], a.role), RC_MOVE)
    pid, start = e.get("pid"), e.get("pid_start")
    if getattr(a, "stop_only", False):  # 대상만 중지: sid 확정·동기화·이관을 모두 생략한다
        _stop_local(pid, start)
        return "", a.cwd, e["value"], None
    # sid 확정을 중지보다 먼저 끝낸다("중지했는데 대화를 못 찾는" 상황 방지). 추정으로 고르지 않는다.
    cfg = target_config_dir(pid) if (pid and pc.pid_alive(pid, start)) else ""
    try:
        sid, cwd, how = resolve_entry_sid(a.project, e, a.sid, a.pick_tty, cfg)
    except Fail as ex:
        log("resolve", "local key=%s %s" % (a.key, str(ex).split(" ", 1)[0]))
        raise
    cwd = cwd or a.cwd
    tr = find_transcript(sid, cfg)
    log("resolve", "local key=%s sid=%s by=%s" % (a.key, sid, how))
    # 1) 사전 동기화
    if same_tree(cwd, a.cwd):
        log("presync", "local same-tree skip")
    else:
        sync_gate(git_state(cwd), a.force_sync, "local")
    # 2) 중지(pid_start 재검증 → SIGTERM → 확인, SIGKILL 없음)
    _stop_local(pid, start)
    # 3) 이관 — 같은 sid 재개라 파일 이동 없음(본 대화·팀원 대화·session-env 가 이미 이 머신에 있다)
    if not os.path.isfile(tr):
        raise Fail("대화 파일이 사라졌다", RC_MOVE)
    log("move", "local same-sid no-copy sid=%s" % sid)
    # 4) 사후 동기화
    why = None
    if not same_tree(cwd, a.cwd):
        th = (git_state(cwd) or {}).get("head", "")
        why = post_sync(a.cwd, th)
    resume_cwd = cwd if (cwd and os.path.isdir(cwd)) else a.cwd
    return sid, resume_cwd, e["value"], why


def remote_find(url, tok, project, key):
    st, obj = pc.http_json(url + "/v1/sessions?project=%s" % project.lower(), token=tok, timeout=10)
    if st == 0:
        raise Fail("host 에 접속하지 못했다", RC_HOST)
    if st != 200:
        raise Fail("host 세션 목록 실패(status %s)" % st, RC_MOVE)
    for s in obj.get("sessions") or []:
        if isinstance(s, dict) and s.get("session_key") == key:
            return s
    return None


def run_remote(a):
    url, tok, _src = pc.discover_hub()
    if not url:
        raise Fail("host 가 없다(원격 인계에는 AI 프로젝트 host 세션이 필요)", RC_HOST)
    if not pc.KEY_RE.fullmatch(a.key or ""):
        raise Fail("원격 대상 키 형식 오류", RC_USAGE)
    s = remote_find(url, tok, a.project, a.key)
    if not s:
        raise Fail("대상 세션이 host 목록에 없다: remote %s" % a.key, RC_MOVE)
    value = remote_value(s)
    if not same_role(a.role, value):
        raise Fail("대상 롤이 요청과 다르다(%s ≠ %s)" % (value, a.role), RC_MOVE)
    g = s.get("git") if isinstance(s.get("git"), dict) else {}
    same_machine = s.get("machine_id") == pc.machine_id()
    code = takeover_code(s)
    if code != "ok":
        log("stop", "remote blocked code=%s" % code)
        raise Fail("인계 불가(%s) — %s" % (code, REASON_TEXT.get(code, code)), RC_STOP)
    if getattr(a, "stop_only", False):
        log("presync", "remote stop-only skip")
    elif same_machine:
        log("presync", "presync same-machine skip")
    else:
        sync_gate(g if g.get("head") else None, a.force_sync, "remote")
    # 2) 중지 요청 → 대상이 묶음 업로드 → ack stopped
    #    hub 는 요청자도 등록된 세션이어야 받는다(cc 는 claude 기동 전이라) — 이 프로세스를 요청 롤 값·이름 takeover 의
    #    임시 세션으로 등록했다가 끝에 해제한다(대상 peer_mcp 가 takeover_request 의 role 로 같은 롤인지 확인한다).
    #    check 는 이름 takeover 항목을 충돌로 보지 않는다.
    rid, area, _n = parse_value(a.role)
    req_key = pc.gen_session_key()
    st, obj = pc.http_json(url + "/v1/sessions/register", "POST", {
        "session_key": req_key, "machine_id": pc.machine_id(), "machine_label": pc.machine_label(),
        "project": a.project.lower(), "role": rid + (":" + area if area else ""), "name": TAKEOVER_NAME,
        "pid": os.getpid(),
        "pid_start": pc.pid_start(os.getpid()) or "", "cwd_tail": os.path.basename(a.cwd.rstrip("/"))[:64]}, tok, 10)
    if st == 0:
        raise Fail("host 에 접속하지 못했다", RC_HOST)
    if st != 200:
        raise Fail("host 임시 등록 실패(status %s %s)" % (st, obj.get("error", "")), RC_MOVE)
    log("stop", "remote temp-register role=%s" % (rid + (":" + area if area else "")))
    try:
        return _run_remote_req(a, url, tok, req_key, value, g, same_machine)
    finally:
        pc.http_json(url + "/v1/sessions/unregister", "POST", {"session_key": req_key}, tok, 5)


def _blob_ids(blobs):
    """ack 의 blobs — hub 는 id 문자열 목록, 확장형은 {id,sha256,kind} 객체. (id, sha256 또는 '') 목록."""
    out = []
    for b in blobs or []:
        if isinstance(b, str):
            out.append((b, ""))
        elif isinstance(b, dict) and b.get("kind", "bundle") == "bundle":
            out.append((str(b.get("id", "")), str(b.get("sha256", ""))))
    return out


def _run_remote_req(a, url, tok, req_key, value, g, same_machine=False):
    stop_only = bool(getattr(a, "stop_only", False))
    body = {"requester_key": req_key, "target_key": a.key}
    if stop_only:
        body["mode"] = "stop"
    st, obj = pc.http_json(url + "/v1/takeover", "POST", body, tok, 10)
    if st == 0:
        raise Fail("host 에 접속하지 못했다", RC_HOST)
    tid = str(obj.get("id", ""))
    if st not in (200, 201) or not re.fullmatch(r"[A-Za-z0-9_-]{4,64}", tid):
        code = str(obj.get("error", "") or "")
        if st == 409 and code in REASON_TEXT:
            raise Fail("인계 불가(%s) — %s" % (code, REASON_TEXT[code]), RC_STOP)
        raise Fail("인계 요청 실패(status %s %s)" % (st, code), RC_STOP if st == 409 else RC_MOVE)
    log("stop", "remote requested id=%s mode=%s" % (tid, "stop" if stop_only else "move"))
    # 대기: 요청 시점부터 REMOTE_WAIT 초, state 가 uploading 으로 바뀌면 그 시점부터 다시 센다. 전체 상한 TTL(300).
    wait = env_float("PEER_TAKEOVER_REMOTE_WAIT", 120)
    t_start = time.time()
    hard_end = t_start + env_float("PEER_TAKEOVER_TTL", 300)
    end = t_start + wait
    seen_up = False
    info = {}
    while time.time() < min(end, hard_end):
        st, info = pc.http_json(url + "/v1/takeover/%s?for=%s" % (tid, req_key), token=tok, timeout=10)
        state = info.get("state", "") if st == 200 else ""
        if state == "uploading" and not seen_up:
            seen_up = True
            end = time.time() + wait
            log("stop", "remote uploading — wait restart")
        if state in ("stopped", "refused", "timeout"):
            break
        time.sleep(0.3)
    if st != 200:
        info = {}
    state = info.get("state", "")
    if state == "refused":
        log("stop", "remote refused reason=%s" % info.get("reason", ""))
        raise Fail("대상 세션이 인계를 거절했다(%s)" % (info.get("reason") or "-"), RC_STOP)
    if state != "stopped":
        log("stop", "remote timeout state=%s" % state)
        raise Fail("대상 세션이 시간 안에 멈추지 않았다(state=%s) — 이관하지 않았다" % (state or "-"), RC_STOP)
    if stop_only:  # 중지만 요청: ack 에 sid 가 비어 있어도 성공(blob 은 쓰지 않는다)
        log("stop", "remote stop-only stopped")
        return "", a.cwd, value, None
    sid = str(info.get("sid", ""))
    blobs = _blob_ids(info.get("blobs"))
    if not SID_RE.fullmatch(sid) or len(blobs) != 1 or not pc.BLOB_ID_RE.fullmatch(blobs[0][0]):
        raise Fail("ack 형식 오류(sid·blob)", RC_MOVE)
    log("stop", "remote stopped sid=%s" % sid)
    # 3) 이관
    tmpd = tempfile.mkdtemp(prefix="pt-", dir=os.environ.get("TMPDIR") or None)
    try:
        dest = os.path.join(tmpd, "bundle.tar.gz")
        st, got = pc.http_get_to_file(url + "/v1/blobs/" + blobs[0][0], dest, tok)
        want = blobs[0][1]
        if st != 200 or not SHA_RE.fullmatch(str(got)) or (want and want != got):
            raise Fail("묶음 내려받기 실패(%s %s)" % (st, got if not SHA_RE.fullmatch(str(got)) else "SHA_MISMATCH"),
                       RC_MOVE)
        man = do_import(dest, a.project, a.cwd)
    finally:
        shutil.rmtree(tmpd, ignore_errors=True)
    if man["sid"] != sid:
        raise Fail("묶음 sid 가 ack 와 다르다", RC_MOVE)
    log("move", "remote imported sid=%s" % sid)
    # 대상이 목록에서 빠지는지 확인(정보용 — 업로드 뒤 종료되므로 대화는 이미 받았다)
    end = time.time() + env_float("PEER_TAKEOVER_STOP_WAIT", 15)
    gone = False
    while time.time() < end:
        try:
            if not remote_find(url, tok, a.project, a.key):
                gone = True
                break
        except Fail:
            break
        time.sleep(0.5)
    log("stop", "remote gone=%s" % gone)
    if not gone:
        say("⚠️ 대상 세션이 아직 host 목록에 남아 있다(종료 처리 지연일 수 있다)")
    if same_machine:
        log("postsync", "same-machine skip")
        why = None
    else:
        why = post_sync(a.cwd, str(info.get("git_head") or g.get("head") or ""))
    return sid, a.cwd, str(man.get("role") or value), why


def cmd_run(a):
    log("start", "kind=%s project=%s role=%s force=%s" % (a.kind, a.project.lower(), a.role, a.force_sync))
    if not a.cwd.startswith("/"):
        raise Fail("--cwd 는 절대경로여야 한다", RC_USAGE)
    if a.kind == "local":
        sid, cwd, value, why = run_local(a)
    else:
        sid, cwd, value, why = run_remote(a)
    if getattr(a, "stop_only", False):
        print("STOPPED=1")
        log("done", "rc=0 stop-only")
        return RC_OK
    print("RESUME_SID=%s" % sid)
    print("RESUME_CWD=%s" % cwd)
    print("RESUME_VALUE=%s" % value)
    if why:
        log("done", "rc=%d sid=%s postsync-fail" % (RC_FF, sid))
        say("⚠️ 사후 동기화 실패: %s — 대화는 받아 두었다. 저장소를 맞춘 뒤 재개하라" % why)
        return RC_FF
    log("done", "rc=0 sid=%s" % sid)
    return RC_OK


def cmd_pack(a):
    man = do_pack(a.sid, a.cwd, a.project, a.role, a.out, getattr(a, "config_dir", "") or "")
    print("PACKED sha256=%s bytes=%d git_head=%s" % (pc.sha256_file(a.out), os.path.getsize(a.out),
                                                     man.get("git_head") or "-"))
    return RC_OK


def cmd_import_bundle(a):
    man = do_import(a.file, a.project, a.cwd)
    print("IMPORTED_BUNDLE sid=%s" % man["sid"])
    return RC_OK


def main(argv=None):
    ap = argparse.ArgumentParser(prog="peer_takeover.py", description="같은 롤 세션 인계")
    sp = ap.add_subparsers(dest="cmd")
    q = sp.add_parser("check")
    q.add_argument("--project", required=True)
    q.add_argument("--role", required=True)
    q.add_argument("--json", action="store_true")
    q = sp.add_parser("run")
    q.add_argument("--project", required=True)
    q.add_argument("--role", required=True)
    q.add_argument("--kind", required=True, choices=("local", "remote"))
    q.add_argument("--key", required=True)
    q.add_argument("--cwd", required=True)
    q.add_argument("--sid", default="")
    q.add_argument("--force-sync", action="store_true")
    q.add_argument("--pick-tty", action="store_true", help="sid 를 결정적으로 못 찾으면 /dev/tty 로 후보를 보여 고르게 한다")
    q.add_argument("--stop-only", action="store_true", help="대상만 중지(sid 확정·이관·동기화 생략). 성공 시 STOPPED=1")
    q = sp.add_parser("pack")
    q.add_argument("--sid", required=True)
    q.add_argument("--cwd", default="")
    q.add_argument("--project", default="")
    q.add_argument("--role", default=None)
    q.add_argument("--out", required=True)
    q.add_argument("--config-dir", default="", help="대상 세션의 CLAUDE_CONFIG_DIR (session-env 수집용)")
    q = sp.add_parser("import-bundle")
    q.add_argument("--file", required=True)
    q.add_argument("--project", required=True)
    q.add_argument("--cwd", required=True)
    try:
        a = ap.parse_args(argv)
    except SystemExit as e:
        return RC_USAGE if e.code else RC_OK
    if not a.cmd:
        ap.print_usage(sys.stderr)
        return RC_USAGE
    if getattr(a, "project", "") and not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", a.project):
        say("프로젝트 형식 오류")
        return RC_USAGE
    try:
        return {"check": cmd_check, "run": cmd_run, "pack": cmd_pack, "import-bundle": cmd_import_bundle}[a.cmd](a)
    except Fail as e:
        say(str(e))
        log("fail", "cmd=%s rc=%d %s" % (a.cmd, e.rc, e))
        return e.rc


if __name__ == "__main__":
    sys.exit(main())
