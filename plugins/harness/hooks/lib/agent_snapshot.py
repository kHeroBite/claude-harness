#!/usr/bin/env python3
# 메인·팀원·서브에이전트의 상태 스냅샷을 자기 세션 agent_state/ 에 원자 기록하는 재기동 복원용 코어
"""PostToolUse_agent_snapshot.sh(async hook)가 호출한다. 입력은 hook stdin JSON 그대로.

계약: plans/oplan_conv_179163042411_s10D.md §3-1~3-4
  저장소   : $HOME/.claude/session-env/<pipeline_uuid>/agent_state/
             <name>.json(+.prev 1세대), <name>.spawn.md, sub_<agentId>.json, _main.json, user_directives.log
  신원 판정: ① 조상 프로세스 argv 의 --agent-id NAME@TEAM + --parent-session-id UUID 정확 토큰 쌍 → 팀원
             ② 입력 agent_id → 서브에이전트(소유 uuid 는 ①의 uuid, 없으면 session_id)
             ③ 둘 다 없음 → 메인(uuid = session_id)
             판정 결과는 agent_state/.id_<session_id> 에 캐시한다(서브에이전트 제외).
  무동작   : uuid 디렉토리 부재·state 부재/IDLE·증명 실패 → 아무것도 쓰지 않고 rc=0
  부하 축약: /proc/pressure/io some avg10 > 20 또는 loadavg1/nproc > 2.0 이면 mode=lite
             (트랜스크립트 읽기 생략, 이벤트 입력 필드만 갱신, 이전 값 병합). 판독 실패도 lite.
  원자 쓰기: 같은 디렉토리 tmp → fsync(file) → 기존 파일 .prev 로 os.replace → os.replace → fsync(dir)
  오류     : 모든 예외는 무출력 rc=0, agent_state/.errors 에 1줄(최대 100줄)

세션 격리: 쓰기는 오직 증명된 자기 pipeline_uuid 디렉토리 하위. session-env 전체 순회를 하지 않는다.
시험 주입 env: AS_PROC_ROOT(기본 /proc), AS_START_PID(기본 getppid), AS_BOOT_ID_FILE, AS_PSI_FILE,
              AS_LOADAVG_FILE, AS_NPROC, AS_FORCE_MODE(full|lite)
"""
import calendar
import fcntl
import json
import os
import re
import sys
import time

UUID_RX = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
NAME_RX = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")
AGENT_ID_RX = re.compile(r"^[A-Za-z0-9_.-]{1,80}$")
TEXT_MAX = 4096
SPAWN_MAX = 65536
TAIL_MAX = 131072
DIRECTIVE_LINE_MAX = 2048
DIRECTIVE_KEEP = 200
ERR_KEEP = 100
LEAD_MARK = '<teammate-message teammate_id="team-lead"'


def session_env_base():
    """정본 저장소 base — HOME 쪽 EXT4 경로로 고정한다(설정 디렉토리 쪽은 /tmp 심볼릭링크라 정본이 아니다)."""
    return os.path.join(os.environ.get("HOME") or os.path.expanduser("~"), ".claude/session-env")


# ───────────────────────── 공용 유틸 ─────────────────────────

def _read(path, limit=None):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read(limit) if limit else f.read()
    except OSError:
        return None


def _load_json(path):
    raw = _read(path)
    if not raw:
        return None
    try:
        v = json.loads(raw)
        return v if isinstance(v, dict) else None
    except ValueError:
        return None


def _clip(text, n=TEXT_MAX):
    if text is None:
        return ""
    if not isinstance(text, str):
        try:
            text = json.dumps(text, ensure_ascii=False)
        except (TypeError, ValueError):
            text = str(text)
    b = text.encode("utf-8")
    if len(b) <= n:
        return text
    return b[:n].decode("utf-8", "ignore")


def _fsync_dir(d):
    try:
        fd = os.open(d, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    except OSError:
        pass


def atomic_write(path, data, keep_prev=False):
    """tmp → fsync → (기존 → .prev) → os.replace → fsync(dir). 반쯤 쓴 파일을 남기지 않는다."""
    d = os.path.dirname(path)
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    if keep_prev and os.path.exists(path):
        os.replace(path, path + ".prev")
    os.replace(tmp, path)
    _fsync_dir(d)


def log_error(adir, msg):
    """agent_state/.errors 에 1줄 추가하고 최근 ERR_KEEP 줄만 남긴다. 실패해도 무시."""
    try:
        p = os.path.join(adir, ".errors")
        lines = (_read(p) or "").splitlines()[-(ERR_KEEP - 1):]
        lines.append("%s %s" % (time.strftime("%Y-%m-%dT%H:%M:%S"), _clip(msg, 300).replace("\n", " ")))
        atomic_write(p, "\n".join(lines) + "\n")
    except Exception:
        pass


# ───────────────────────── 신원 판정 ─────────────────────────

def _argv(proc_root, pid):
    try:
        with open(os.path.join(proc_root, str(pid), "cmdline"), "rb") as f:
            raw = f.read()
    except OSError:
        return []
    return [t.decode("utf-8", "replace") for t in raw.split(b"\0") if t]


def _ppid(proc_root, pid):
    """stat 의 ppid. comm 에 공백·괄호가 있을 수 있어 마지막 ')' 뒤를 자른다."""
    raw = _read(os.path.join(proc_root, str(pid), "stat"))
    if not raw or ")" not in raw:
        return 0
    rest = raw.rsplit(")", 1)[1].split()
    try:
        return int(rest[1])
    except (IndexError, ValueError):
        return 0


def _pair_value(tokens, key):
    for i in range(len(tokens) - 1):
        if tokens[i] == key:
            return tokens[i + 1]
    return None


def prove_teammate():
    """조상 프로세스 argv 에서 --agent-id NAME@TEAM 과 --parent-session-id UUID 정확 토큰 쌍을 찾는다.
    반환: (name, team, uuid) 또는 None."""
    proc_root = os.environ.get("AS_PROC_ROOT") or "/proc"
    try:
        pid = int(os.environ.get("AS_START_PID") or os.getppid())
    except ValueError:
        return None
    seen = set()
    for _ in range(16):
        if pid <= 1 or pid in seen:
            break
        seen.add(pid)
        tok = _argv(proc_root, pid)
        aid = _pair_value(tok, "--agent-id")
        psid = _pair_value(tok, "--parent-session-id")
        if aid and psid and "@" in aid:
            name, team = aid.split("@", 1)
            if NAME_RX.fullmatch(name) and NAME_RX.fullmatch(team) and UUID_RX.fullmatch(psid):
                return name, team, psid
            return None
        pid = _ppid(proc_root, pid)
    return None


def stage_of(sdir):
    raw = _read(os.path.join(sdir, "state"), 256)
    if not raw:
        return ""
    parts = raw.split()
    return parts[0] if parts else ""


def resolve_identity(inp, base):
    """반환: dict(kind, name, team, uuid) 또는 None(무동작)."""
    sid = str(inp.get("session_id") or "")
    if not UUID_RX.fullmatch(sid):
        return None
    agent_id = str(inp.get("agent_id") or "")
    hint = os.environ.get("PIPELINE_UUID") or sid
    ident = None
    if UUID_RX.fullmatch(hint):
        cache = _read(os.path.join(base, hint, "agent_state", ".id_" + sid), 512)
        if cache:
            f = cache.split()
            if len(f) == 4 and f[0] in ("teammate", "main") and f[3] == hint and NAME_RX.fullmatch(f[1]):
                ident = {"kind": f[0], "name": f[1], "team": f[2] if f[2] != "-" else "", "uuid": f[3], "cached": True}
    if ident is None:
        tm = prove_teammate()
        if tm:
            ident = {"kind": "teammate", "name": tm[0], "team": tm[1], "uuid": tm[2], "cached": False}
        else:
            ident = {"kind": "main", "name": "_main", "team": "", "uuid": sid, "cached": False}
    if agent_id:
        if not AGENT_ID_RX.fullmatch(agent_id):
            return None
        ident = {"kind": "subagent", "name": "sub_" + agent_id, "team": ident["team"],
                 "uuid": ident["uuid"], "cached": True, "agent_id": agent_id}
    return ident


# ───────────────────────── 부하 판정 ─────────────────────────

def decide_mode():
    forced = os.environ.get("AS_FORCE_MODE")
    if forced in ("full", "lite"):
        return forced
    try:
        psi = _read(os.environ.get("AS_PSI_FILE") or "/proc/pressure/io", 512)
        m = re.search(r"^some .*?avg10=([0-9.]+)", psi or "", re.M)
        if not m:
            return "lite"
        if float(m.group(1)) > 20.0:
            return "lite"
        la = _read(os.environ.get("AS_LOADAVG_FILE") or "/proc/loadavg", 128)
        load1 = float(la.split()[0])
        ncpu = int(os.environ.get("AS_NPROC") or os.cpu_count() or 1)
        if ncpu < 1 or load1 / ncpu > 2.0:
            return "lite"
        return "full"
    except Exception:
        return "lite"


# ───────────────────────── 트랜스크립트 ─────────────────────────

def _entry_text(obj):
    """트랜스크립트 user 항목의 본문 텍스트."""
    msg = obj.get("message") if isinstance(obj, dict) else None
    content = msg.get("content") if isinstance(msg, dict) else None
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        out = []
        for c in content:
            if isinstance(c, dict) and c.get("type") == "text" and isinstance(c.get("text"), str):
                out.append(c["text"])
        return "\n".join(out)
    return ""


def _ts_of(obj):
    ts = obj.get("timestamp") if isinstance(obj, dict) else None
    if isinstance(ts, str):
        try:  # 트랜스크립트 timestamp 는 UTC ISO8601(…Z) 이다
            return int(calendar.timegm(time.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S")))
        except ValueError:
            return 0
    return 0


def last_lead_instruction(tpath):
    """트랜스크립트 꼬리 128KB 에서 마지막 team-lead teammate-message user 항목."""
    try:
        size = os.path.getsize(tpath)
        with open(tpath, "rb") as f:
            if size > TAIL_MAX:
                f.seek(size - TAIL_MAX)
            raw = f.read(TAIL_MAX)
    except OSError:
        return None
    lines = raw.split(b"\n")
    if size > TAIL_MAX:
        lines = lines[1:]
    for ln in reversed(lines):
        # 원시 줄은 JSON 이스케이프(\") 상태라 표식 전체 대신 두 조각으로 거른 뒤 파싱해서 정확히 본다
        if b"teammate-message" not in ln or b"team-lead" not in ln:
            continue
        try:
            obj = json.loads(ln.decode("utf-8", "replace"))
        except ValueError:
            continue
        if obj.get("type") != "user":
            continue
        text = _entry_text(obj)
        if LEAD_MARK not in text:
            continue
        return {"ts": _ts_of(obj) or int(time.time()), "from": "team-lead", "text": _clip(text)}
    return None


def first_user_prompt(tpath):
    """트랜스크립트 앞 64KB 의 첫 user 항목 본문(spawn 프롬프트 원문)."""
    try:
        with open(tpath, "rb") as f:
            raw = f.read(SPAWN_MAX)
    except OSError:
        return None
    for ln in raw.split(b"\n"):
        if b'"user"' not in ln:
            continue
        try:
            obj = json.loads(ln.decode("utf-8", "replace"))
        except ValueError:
            continue
        if obj.get("type") == "user":
            text = _entry_text(obj)
            if text:
                return _clip(text, SPAWN_MAX)
    return None


# ───────────────────────── 세션 메타 ─────────────────────────

def read_kv(path):
    out = {}
    for ln in (_read(path, 8192) or "").splitlines():
        if "=" in ln:
            k, v = ln.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def boot_id():
    return (_read(os.environ.get("AS_BOOT_ID_FILE") or "/proc/sys/kernel/random/boot_id", 64) or "").strip()


def result_summary(sdir, name, conv_id):
    """work/<name>_result.json — conv_id 가 현재 conv_id 와 같을 때만 반영한다(L-670)."""
    r = _load_json(os.path.join(sdir, "work", name + "_result.json"))
    if not r or not conv_id or r.get("conv_id") != conv_id:
        return {"status": "absent", "todos_completed": []}
    st = r.get("status") if r.get("status") in ("partial", "completed") else "partial"
    tc = r.get("todos_completed") if isinstance(r.get("todos_completed"), list) else []
    return {"status": st, "todos_completed": tc[:200]}


def files_owned(sdir, name):
    fa = _load_json(os.path.join(sdir, "file_assignment.json")) or {}
    ag = fa.get("agents") if isinstance(fa.get("agents"), dict) else {}
    ent = ag.get(name) if isinstance(ag.get(name), dict) else {}
    files = ent.get("files") if isinstance(ent.get("files"), list) else []
    return [str(x) for x in files][:200]


def _todo_from_create(ti, tr):
    content = ti.get("subject") or ti.get("content") or ti.get("description") or ""
    tid = ""
    if isinstance(tr, dict):
        tid = str(tr.get("id") or tr.get("taskId") or (tr.get("task") or {}).get("id") or "")
    return {"id": tid, "content": _clip(content, 500), "status": "pending"}


def apply_todo_event(todos, tool, ti, tr):
    """TodoWrite/TaskCreate/TaskUpdate 입력으로 todos 사본을 갱신한다(작업 목록 원본은 /tmp 라 재기동에 사라진다)."""
    todos = list(todos) if isinstance(todos, list) else []
    if not isinstance(ti, dict):
        return todos
    if tool == "TodoWrite" and isinstance(ti.get("todos"), list):
        return [{"content": _clip(t.get("content", ""), 500), "status": str(t.get("status", "pending"))}
                for t in ti["todos"] if isinstance(t, dict)][:100]
    if tool == "TaskCreate":
        todos.append(_todo_from_create(ti, tr))
        return todos[-100:]
    if tool == "TaskUpdate":
        tid = str(ti.get("taskId") or ti.get("id") or "")
        for t in todos:
            if tid and str(t.get("id", "")) == tid:
                if ti.get("status"):
                    t["status"] = str(ti["status"])
                if ti.get("subject"):
                    t["content"] = _clip(ti["subject"], 500)
                break
        else:
            if tid:
                todos.append({"id": tid, "content": _clip(ti.get("subject", ""), 500),
                              "status": str(ti.get("status", "pending"))})
        return todos[-100:]
    return todos


def checkpoint_tail(sdir, n=5):
    p = os.path.join(sdir, "checkpoint.jsonl")
    try:
        size = os.path.getsize(p)
        with open(p, "rb") as f:
            if size > 16384:
                f.seek(size - 16384)
            raw = f.read().decode("utf-8", "replace")
    except OSError:
        return []
    out = []
    for ln in raw.splitlines():
        try:
            o = json.loads(ln)
        except ValueError:
            continue
        if isinstance(o, dict) and o.get("event"):
            out.append({"ts": o.get("ts", ""), "event": o.get("event"), "detail": _clip(o.get("detail", ""), 200)})
    return out[-n:]


# ───────────────────────── 잠금·기록 ─────────────────────────

class Lock(object):
    """agent_state/.lock_<name> flock — 동시에 도는 async hook 끼리 직렬화. 2초 안에 못 잡으면 포기."""

    def __init__(self, adir, name):
        self.path = os.path.join(adir, ".lock_" + name)
        self.fd = None

    def __enter__(self):
        self.fd = os.open(self.path, os.O_RDWR | os.O_CREAT, 0o600)
        deadline = time.time() + 2.0
        while True:
            try:
                fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return self
            except OSError:
                if time.time() > deadline:
                    os.close(self.fd)
                    self.fd = None
                    raise TimeoutError("lock busy")
                time.sleep(0.05)

    def __exit__(self, *a):
        if self.fd is not None:
            try:
                fcntl.flock(self.fd, fcntl.LOCK_UN)
            finally:
                os.close(self.fd)


def load_prev(path):
    return _load_json(path) or _load_json(path + ".prev") or {}


def dump(obj):
    return json.dumps(obj, ensure_ascii=False, indent=1) + "\n"


def append_directive(adir, prompt):
    p = os.path.join(adir, "user_directives.log")
    line = "%s\t%s" % (time.strftime("%Y-%m-%dT%H:%M:%S"),
                       _clip(str(prompt), DIRECTIVE_LINE_MAX).replace("\r", " ").replace("\n", "\\n"))
    lines = (_read(p) or "").splitlines()[-(DIRECTIVE_KEEP - 1):]
    lines.append(line)
    atomic_write(p, "\n".join(lines) + "\n")


def snapshot_teammate(ident, inp, sdir, adir, mode, now):
    name = ident["name"]
    path = os.path.join(adir, name + ".json")
    ev = inp.get("hook_event_name") or ""
    tool = inp.get("tool_name") or ""
    ti = inp.get("tool_input") if isinstance(inp.get("tool_input"), dict) else {}
    tr = inp.get("tool_response")
    tpath = str(inp.get("transcript_path") or "")
    with Lock(adir, name):
        s = load_prev(path)
        conv_id = (_read(os.path.join(sdir, "conv_id"), 128) or "").strip()
        meta = read_kv(os.path.join(sdir, "agents", name))
        s.update({
            "schema": 1, "name": name, "team": ident["team"] or s.get("team", ""), "kind": "teammate",
            "pipeline_uuid": ident["uuid"], "conv_id": conv_id, "stage": stage_of(sdir),
            "role": meta.get("agent_type") or s.get("role", ""),
            "session_id": str(inp.get("session_id") or ""),
            "transcript_path": tpath or s.get("transcript_path", ""),
            "files_owned": files_owned(sdir, name) or s.get("files_owned", []),
            "result": result_summary(sdir, name, conv_id),
            "boot_id": boot_id(), "seq": int(s.get("seq", 0) or 0) + 1,
            "updated_at": now, "mode": mode,
        })
        try:
            s["spawned_at"] = int(meta.get("spawned_at") or s.get("spawned_at") or 0)
        except ValueError:
            s["spawned_at"] = 0
        s.setdefault("last_instruction", None)
        s.setdefault("last_report", None)
        s.setdefault("todos", [])
        if ev == "PostToolUse" and tool:
            s["last_tool"] = tool
            if tool == "SendMessage" and isinstance(ti, dict):
                s["last_report"] = {"ts": now, "to": str(ti.get("to", "")), "text": _clip(ti.get("message", ""))}
            if tool in ("TodoWrite", "TaskCreate", "TaskUpdate"):
                s["todos"] = apply_todo_event(s.get("todos"), tool, ti, tr)
        if mode == "full" and tpath:
            li = last_lead_instruction(tpath)
            if li and (not s.get("last_instruction") or li["ts"] >= int((s["last_instruction"] or {}).get("ts", 0) or 0)):
                s["last_instruction"] = li
            sp = os.path.join(adir, name + ".spawn.md")
            if not os.path.exists(sp):
                first = first_user_prompt(tpath)
                if first:
                    atomic_write(sp, first)
        atomic_write(path, dump(s), keep_prev=True)


def note_instruction_to(adir, to, text, now):
    """메인의 SendMessage 를 받는 팀원 스냅샷의 last_instruction 으로 반영한다(lite 모드에서도 지시가 남게)."""
    if not NAME_RX.fullmatch(to or "") or to.startswith("_") or to.startswith("sub_"):
        return
    path = os.path.join(adir, to + ".json")
    if not os.path.exists(path):
        return
    with Lock(adir, to):
        s = load_prev(path)
        if not s:
            return
        s["last_instruction"] = {"ts": now, "from": "team-lead", "text": _clip(text)}
        atomic_write(path, dump(s), keep_prev=True)


def team_overview(adir):
    """자기 agent_state 디렉토리 안의 팀원 스냅샷만 집계한다(session-env 전체 순회 없음)."""
    agents, pending = {}, []
    try:
        names = sorted(os.listdir(adir))
    except OSError:
        return agents, pending
    for fn in names:
        if not fn.endswith(".json") or fn.startswith("_") or fn.startswith("sub_") or fn.startswith("."):
            continue
        s = _load_json(os.path.join(adir, fn))
        if not s or s.get("kind") != "teammate":
            continue
        st = (s.get("result") or {}).get("status", "absent")
        agents[s.get("name", fn[:-5])] = {"status": st, "updated_at": s.get("updated_at", 0)}
        if st != "completed":
            pending.append(s.get("name", fn[:-5]))
    return agents, pending


def snapshot_main(ident, inp, sdir, adir, mode, now):
    path = os.path.join(adir, "_main.json")
    ev = inp.get("hook_event_name") or ""
    tool = inp.get("tool_name") or ""
    ti = inp.get("tool_input") if isinstance(inp.get("tool_input"), dict) else {}
    if ev == "UserPromptSubmit" and inp.get("prompt"):
        with Lock(adir, "_directives"):
            append_directive(adir, inp.get("prompt"))
    if ev == "PostToolUse" and tool == "SendMessage" and isinstance(ti.get("message"), str):
        note_instruction_to(adir, str(ti.get("to", "")), ti["message"], now)
    with Lock(adir, "_main"):
        s = load_prev(path)
        agents, pending = team_overview(adir)
        s.update({
            "schema": 1, "kind": "main", "pipeline_uuid": ident["uuid"],
            "stage": stage_of(sdir),
            "classification": (_read(os.path.join(sdir, "classification"), 64) or "").strip(),
            "conv_id": (_read(os.path.join(sdir, "conv_id"), 128) or "").strip(),
            "team": (_read(os.path.join(sdir, "team_name"), 128) or "").strip(),
            "session_id": str(inp.get("session_id") or ""),
            "transcript_path": str(inp.get("transcript_path") or "") or s.get("transcript_path", ""),
            "last_events": checkpoint_tail(sdir),
            "agents": agents,
            "pending": "result 미완료 팀원: " + (", ".join(pending) if pending else "없음"),
            "boot_id": boot_id(), "seq": int(s.get("seq", 0) or 0) + 1,
            "updated_at": now, "mode": mode,
        })
        if ev == "PostToolUse" and tool:
            s["last_tool"] = tool
        atomic_write(path, dump(s), keep_prev=True)


def snapshot_subagent(ident, inp, adir, now):
    path = os.path.join(adir, ident["name"] + ".json")
    with Lock(adir, ident["name"]):
        s = load_prev(path)
        s.update({
            "agent_id": ident["agent_id"],
            "agent_type": str(inp.get("agent_type") or s.get("agent_type", "")),
            "session_id": str(inp.get("session_id") or ""),
            "transcript_hint": str(inp.get("agent_transcript_path") or inp.get("transcript_path") or "")
                               or s.get("transcript_hint", ""),
            "updated_at": now,
        })
        atomic_write(path, dump(s))


def main():
    raw = sys.stdin.read()
    try:
        inp = json.loads(raw)
    except ValueError:
        return 0
    if not isinstance(inp, dict):
        return 0
    base = session_env_base()
    ident = resolve_identity(inp, base)
    if not ident:
        return 0
    sdir = os.path.join(base, ident["uuid"])
    if not os.path.isdir(sdir):
        return 0
    st = stage_of(sdir)
    if not st or st == "IDLE":
        return 0
    adir = os.path.join(sdir, "agent_state")
    try:
        os.makedirs(adir, mode=0o700, exist_ok=True)
    except OSError:
        return 0
    try:
        if not ident.get("cached"):
            sid = str(inp.get("session_id"))
            atomic_write(os.path.join(adir, ".id_" + sid),
                         "%s %s %s %s\n" % (ident["kind"], ident["name"], ident["team"] or "-", ident["uuid"]))
        now = int(time.time())
        mode = decide_mode()
        if ident["kind"] == "teammate":
            snapshot_teammate(ident, inp, sdir, adir, mode, now)
        elif ident["kind"] == "main":
            snapshot_main(ident, inp, sdir, adir, mode, now)
        else:
            snapshot_subagent(ident, inp, adir, now)
    except Exception as e:  # 무출력 rc=0 — hook 이 도구 흐름을 막지 않는다
        log_error(adir, "%s: %s" % (type(e).__name__, e))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)
