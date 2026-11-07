# 세션 롤(/orole) 정의·저장·레지스트리·인계 상태를 다루는 단일 CLI 라이브러리 (표준 라이브러리만 사용)
"""role_lib — 세션 롤 공용 CLI.

호출자: UserPromptSubmit_role.sh · PreToolUse_role_scope_warn.sh · SessionStart_role.sh ·
        orole 스킬 · statusline · cc/ccc 런처.

저장 위치
- 자기 세션 롤      : <base>/session-env/<sid>/role  (base = $CLAUDE_CONFIG_DIR 와 홈 기준 둘 다)
- 자기 세션 보조    : 홈 기준 <home>/session-env/<sid>/ 하위 (peer_roles.json · handoffs.json · ...)
- 생존 레지스트리   : <REG>/<project>/live/<tmux_session>_<pane숫자>.json  (세션 UUID 를 넣지 않는다)
- 재개 색인         : <REG>/<project>/resume_index.jsonl  (실행기·resume-* 전용, sid 보유)

세션 격리: 자기 sid 디렉터리와 레지스트리의 자기 키만 쓴다. 다른 세션 디렉터리는 열거하지 않는다.
시험용 환경변수: ROLE_REGISTRY_DIR · ROLE_HOME_BASE · CLAUDE_CONFIG_DIR · ROLE_DEFS ·
                 ROLE_SKIP_TRANSCRIPT_CHECK · ROLE_NOW(현재 시각 epoch 주입).
"""
import datetime
import fcntl
import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
SOURCES = ("startup", "resume", "clear", "compact", "fork")
ROLE_SOURCES = ("cmd", "ask", "launcher", "resume")
LIB_CMD = "python3 " + os.path.abspath(__file__)
HANDOFF_STATES = ("sent", "confirm_wait", "confirmed", "done", "none")
REGISTER_REFRESH_SEC = 600
RESERVE_TTL_SEC = 600
RESUME_MAX_LINES = 2000
REMIND_MAX = 2
DUE_NOTIFY_MAX = 3
ASK_MAX_OPTIONS = 4  # AskUserQuestion 스키마의 options maxItems 상한(이 값을 넘기면 도구 호출이 거부된다)


class RoleError(Exception):
    """rc=2 로 끝내야 하는 오류."""


# ───────────────────────── 공통 유틸 ─────────────────────────

def now_ts():
    v = os.environ.get("ROLE_NOW", "").strip()
    if v:
        try:
            return float(v)
        except ValueError:
            pass
    return time.time()


def iso(ts=None):
    return datetime.datetime.fromtimestamp(now_ts() if ts is None else ts).astimezone().isoformat(timespec="seconds")


def home_base():
    v = os.environ.get("ROLE_HOME_BASE", "").strip()
    return v or os.path.join(os.path.expanduser("~"), ".claude")


def cfg_base():
    v = os.environ.get("CLAUDE_CONFIG_DIR", "").strip()
    if not v:
        return None
    try:
        if os.path.realpath(v) == os.path.realpath(home_base()):
            return None
    except OSError:
        pass
    return v


def registry_dir():
    v = os.environ.get("ROLE_REGISTRY_DIR", "").strip()
    return v or os.path.join(home_base(), "role_registry")


def atomic_write(path, text):
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    import secrets  # 지연 import(기동 비용 절감)
    tmp = "%s.tmp.%d.%s" % (path, os.getpid(), secrets.token_hex(3))
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def read_text(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return None


def read_json(path, default):
    t = read_text(path)
    if t is None:
        return default
    try:
        v = json.loads(t)
    except ValueError:
        return default
    return v if isinstance(v, type(default)) else default


def write_json(path, obj):
    atomic_write(path, json.dumps(obj, ensure_ascii=False, indent=1) + "\n")


class FileLock:
    """같은 디렉터리의 <name>.lock 에 flock 배타 잠금."""

    def __init__(self, path):
        self.path = path + ".lock"
        self.fd = None

    def __enter__(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        self.fd = os.open(self.path, os.O_RDWR | os.O_CREAT, 0o644)
        fcntl.flock(self.fd, fcntl.LOCK_EX)
        return self

    def __exit__(self, *a):
        try:
            fcntl.flock(self.fd, fcntl.LOCK_UN)
        finally:
            os.close(self.fd)


def safe_key(text):
    return re.sub(r"[^A-Za-z0-9가-힣._-]", "_", text or "")


# ───────────────────────── 롤 정의 ─────────────────────────

_DEFS = None


def load_defs():
    global _DEFS
    if _DEFS is not None:
        return _DEFS
    path = os.environ.get("ROLE_DEFS", "").strip() or os.path.join(HERE, "role_defs.json")
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
        roles = d["roles"]
        assert isinstance(roles, list) and roles
        for r in roles:
            assert isinstance(r["id"], str) and isinstance(r["aliases"], list)
    except (OSError, ValueError, KeyError, AssertionError, TypeError) as e:
        raise RoleError("ROLE_DEFS_BROKEN %s (%s)" % (path, e.__class__.__name__))
    d.setdefault("default", "all")
    _DEFS = d
    return d


def role_ids():
    return [r["id"] for r in load_defs()["roles"]]


def role_info(rid):
    for r in load_defs()["roles"]:
        if r["id"] == rid:
            return r
    return {"id": rid, "display": rid, "duty": "", "aliases": []}


def norm_id(text):
    t = (text or "").strip().lower()
    if not t:
        return None
    for r in load_defs()["roles"]:
        if t == r["id"].lower() or t in [a.lower() for a in r["aliases"]] or t == str(r.get("display", "")).lower():
            return r["id"]
    return None


def roles_listing():
    out = []
    for r in load_defs()["roles"]:
        out.append("  %s (%s): %s — 별칭 %s" % (r["id"], r.get("display", ""), r.get("duty", ""), ", ".join(r["aliases"])))
    return "\n".join(out)


NAME_MAX = 20
_NAME_ASCII_OK = re.compile(r"^[0-9A-Za-z가-힣ㄱ-ㅎㅏ-ㅣ._-]+$")


class NameRequired(RoleError):
    """같은 프로젝트·같은 영역의 활성 세션이 있어 에이전트명이 필요한 경우(rc=3)."""


def check_name(name):
    """에이전트명 형식 검증. 통과하면 정리된 이름, 실패하면 RoleError(NAME_INVALID …).

    허용: 영문·숫자·한글·'.'·'_'·'-' 만, 최대 NAME_MAX 자, 숫자만으로 된 이름 금지(옛 자동 번호 '#1' 과 구분).
    tmux 형식 문자열(#{…} · #[…])·경로·제어 문자·공백이 들어갈 수 없게 화이트리스트로만 판정한다.
    """
    n = (name or "").strip()
    if not n:
        raise RoleError("NAME_INVALID 빈 이름")
    if len(n) > NAME_MAX:
        raise RoleError("NAME_INVALID 이름이 너무 깁니다(최대 %d자)" % NAME_MAX)
    if not _NAME_ASCII_OK.fullmatch(n):
        raise RoleError("NAME_INVALID %r — 영문·숫자·한글·.·_·- 만 쓸 수 있습니다(공백·#·:·/ 등 금지)" % n)
    if n.isdigit():
        raise RoleError("NAME_INVALID %r — 숫자만으로 된 이름은 쓸 수 없습니다" % n)
    if not re.search(r"[0-9A-Za-z가-힣ㄱ-ㅎㅏ-ㅣ]", n):
        raise RoleError("NAME_INVALID %r — 글자나 숫자가 하나는 있어야 합니다" % n)
    return n


def parse_value(value):
    """'back:결제#철수' → ('back','결제','철수'), 'back#철수' → ('back','','철수'), 'back#2'(옛 자동 번호) → ('back','','').

    '#' 뒤가 유효한 이름 형식이 아니거나 숫자뿐이면(옛 저장 값) 이름 없음으로 본다.
    """
    v = (value or "").strip()
    name = ""
    if "#" in v:
        v, n = v.split("#", 1)
        try:
            name = check_name(n)
        except RoleError:
            name = ""
    if ":" in v:
        a, b = v.split(":", 1)
        return a, b, name
    return v, "", name


def split_value(value):
    """'back:결제' → ('back','결제'), 'back' → ('back',''). 에이전트명(#…)과 옛 자동 번호는 떼어 낸다."""
    r, a, _ = parse_value(value)
    return r, a


def name_of(value):
    return parse_value(value)[2]


def join_value(rid, area, name=""):
    out = rid if not area else rid + ":" + area
    return out + ("#" + name if name else "")


def display_of(value):
    rid, _ = split_value(value)
    return role_info(rid).get("display", rid)


# ───────────────────────── 프로젝트·경로 매핑 ─────────────────────────

def _wt_main_of(path):
    """worktree 경로(<원본>/.claude/worktrees/<이름>/…)면 원본 루트, 아니면 None. 문자열 판정만 한다."""
    p = (path or "").replace("\\", "/")
    i = p.find("/.claude/worktrees/")
    return p[:i] if i > 0 else None


def project_slug(tmux_session=None, cwd=None):
    s = (tmux_session or "").strip()
    m = re.fullmatch(r"^claude-(.+)$", s)
    if m:
        p = m.group(1)
        q = re.sub(r"-\d+$", "", p)
        return (q or p).lower()
    c = (cwd or os.getcwd()).rstrip("/")
    c = _wt_main_of(c) or c  # worktree 안이면 원본 폴더 이름
    return (os.path.basename(c) or "root").lower()


def find_root(start):
    """start 에서 위로 올라가며 .claude/role_paths.json 이 있는 디렉터리."""
    d = os.path.abspath(start or os.getcwd())
    while True:
        if os.path.isfile(os.path.join(d, ".claude", "role_paths.json")):
            m = _wt_main_of(d)  # worktree 안이면 원본의 role_paths.json 우선
            return m if m and os.path.isfile(os.path.join(m, ".claude", "role_paths.json")) else d
        nd = os.path.dirname(d)
        if nd == d:
            return None
        d = nd


def load_paths(root):
    if not root:
        return None
    p = os.path.join(root, ".claude", "role_paths.json")
    if not os.path.isfile(p):
        return None
    try:
        with open(p, encoding="utf-8") as f:
            d = json.load(f)
    except (OSError, ValueError):
        return None
    return d if isinstance(d, dict) else None


def areas_of(rp, rid):
    if not rp:
        return []
    a = (rp.get("areas") or {}).get(rid) or []
    return [x for x in a if isinstance(x, dict) and isinstance(x.get("name"), str)]


def area_paths(rp, rid, area):
    for a in areas_of(rp, rid):
        if a["name"].lower() == (area or "").lower():
            return [p for p in a.get("paths", []) if isinstance(p, str)]
    return []


def role_paths_for(rp, value):
    if not rp:
        return []
    rid, area = split_value(value)
    out = [p for p in (rp.get("roles") or {}).get(rid, []) if isinstance(p, str)]
    if area:
        out += area_paths(rp, rid, area)
    return out


def glob_re(pat):
    pat = pat.strip().lstrip("./")
    if pat.endswith("/"):
        pat += "**"
    i, out = 0, ""
    while i < len(pat):
        c = pat[i]
        if pat.startswith("**/", i):
            out += "(?:.*/)?"
            i += 3
            continue
        if pat.startswith("**", i):
            out += ".*"
            i += 2
            continue
        if c == "*":
            out += "[^/]*"
        elif c == "?":
            out += "[^/]"
        else:
            out += re.escape(c)
        i += 1
    if not any(ch in pat for ch in "*?"):
        out += "(?:/.*)?"
    return re.compile("^" + out + "$")


def path_match(rel, pats):
    return any(glob_re(p).match(rel) for p in pats if p)


def literal_prefix(pat):
    p = pat.strip().lstrip("./")
    m = re.search(r"[*?\[]", p)
    return p[: m.start()] if m else p


def rel_to_root(root, path):
    ap = path if os.path.isabs(path) else os.path.join(root, path)
    ap = os.path.normpath(ap)
    r = os.path.relpath(ap, os.path.normpath(root))
    if r.startswith(".."):
        return None
    return r.replace(os.sep, "/")


# ───────────────────────── 세션 식별 ─────────────────────────

def resolve_sid(given, required=True):
    sid = (given or "").strip() or os.environ.get("PIPELINE_UUID", "").strip() or os.environ.get("CLAUDE_SESSION_ID", "").strip()
    if not sid:
        if required:
            raise RoleError("SID_MISSING (--sid 또는 PIPELINE_UUID/CLAUDE_SESSION_ID 필요)")
        return None
    if not UUID_RE.fullmatch(sid):
        raise RoleError("SID_INVALID %s" % sid)
    return sid.lower()


def sess_dir(base, sid):
    return os.path.join(base, "session-env", sid)


def bases_for(mode="both"):
    out = [home_base()]
    if mode != "home":
        c = cfg_base()
        if c:
            out.insert(0, c)
    return out


def own_dir(sid):
    """보조 상태 디렉터리 = <홈 기준>/session-env/<sid>/role_state/ (role_lib 전용).

    경로 결정 근거: claude-as 는 실행마다 CLAUDE_CONFIG_DIR=/tmp/cc-<임의> 를 새로 만들므로(계정 전환·재개 시 바뀜)
    그쪽에 두면 인계 상태(handoffs)·수신 기록(peer_roles) 이 재개 때 사라진다. 홈 기준은 세션 UUID 가 같으면 유지된다.
    하네스 파일과 이름이 겹치지 않게 role_state/ 하위로 분리한다. hook·statusline·스킬은 이 경로를 직접 만들지 않고
    role_lib 명령으로만 접근한다. harness_cleanup(sessions) 허용 목록·SessionStart boot-stale 정리 목록에 없는 이름이다.
    """
    return os.path.join(sess_dir(home_base(), sid), "role_state")


CONTRACT_FILES = ("role", "role_asked", "role_session_source")


def newest_contract_file(sid, name):
    """[공개 API] 계약 파일(role·role_asked·role_session_source)을 두 기준(CFG·홈) 중 mtime 최신 것에서 읽는다.

    반환: 앞뒤 공백을 뗀 내용(str), 없거나 빈 파일이면 None. hook 은 같은 python 프로세스에서 import 해 부른다.
    role_state/ 하위 보조 상태는 대상이 아니다(그쪽은 role_lib 명령·함수로만 다룬다).
    """
    if name not in CONTRACT_FILES:
        raise RoleError("CONTRACT_FILE_INVALID %s (허용: %s)" % (name, "/".join(CONTRACT_FILES)))
    best, best_m = None, -1.0
    for b in bases_for("both"):
        p = os.path.join(sess_dir(b, sid), name)
        try:
            m = os.path.getmtime(p)
        except OSError:
            continue
        t = (read_text(p) or "").strip()
        if t and m > best_m:
            best, best_m = t, m
    return best


def read_role_raw(sid):
    best = newest_contract_file(sid, "role")
    if best is None:
        return None
    rid, area, name = parse_value(best)
    if rid not in role_ids():
        return None
    return join_value(rid, area, name if rid != "all" else "")


def current_role(sid):
    return read_role_raw(sid) or load_defs().get("default", "all")


def proc_start(pid):
    try:
        with open("/proc/%d/stat" % int(pid), encoding="utf-8", errors="replace") as f:
            s = f.read()
    except (OSError, ValueError):
        return None
    rest = s[s.rfind(")") + 2:].split()
    try:
        return rest[19]
    except IndexError:
        return None


def alive(pid, start):
    if not pid:
        return False
    st = proc_start(pid)
    return st is not None and str(st) == str(start)


def find_claude_pid():
    pid = os.getppid()
    for _ in range(30):
        if pid <= 1:
            return None
        try:
            with open("/proc/%d/comm" % pid, encoding="utf-8") as f:
                comm = f.read().strip()
            with open("/proc/%d/cmdline" % pid, "rb") as f:
                argv0 = f.read().split(b"\0")[0].decode("utf-8", "replace")
        except OSError:
            return None
        if comm == "claude" or os.path.basename(argv0) == "claude":
            return pid
        try:
            with open("/proc/%d/stat" % pid, encoding="utf-8", errors="replace") as f:
                s = f.read()
            pid = int(s[s.rfind(")") + 2:].split()[1])
        except (OSError, ValueError, IndexError):
            return None
    return None


def tmux_session_of(pane):
    if not pane:
        return None
    import subprocess  # 지연 import(기동 비용 절감)
    try:
        r = subprocess.run(["tmux", "display", "-p", "-t", pane, "#S"], capture_output=True, text=True, timeout=1)
        return r.stdout.strip() or None
    except (OSError, subprocess.SubprocessError):
        return None


def pane_num(pane):
    m = re.search(r"(\d+)", pane or "")
    return m.group(1) if m else None


# ───────────────────────── 레지스트리 ─────────────────────────

def project_dir(project):
    return os.path.join(registry_dir(), safe_key(project))


def live_dir(project):
    return os.path.join(project_dir(project), "live")


def live_key(tmux_session, pane):
    return "%s_%s" % (safe_key(tmux_session), pane_num(pane))


def live_entries(project, alive_only=True):
    d = live_dir(project)
    out = []
    try:
        names = sorted(os.listdir(d))
    except OSError:
        return out
    for n in names:
        if not n.endswith(".json"):
            continue
        e = read_json(os.path.join(d, n), {})
        if not e:
            continue
        e["_key"] = n[:-5]
        if alive_only and not alive(e.get("pid"), e.get("pid_start")):
            continue
        out.append(e)
    out.sort(key=lambda e: e.get("updated_ts", 0), reverse=True)
    return out


def project_lock(project):
    """프로젝트 레지스트리 단위 배타 잠금 — '중복 조회 + 기록' 을 원자화한다."""
    return FileLock(os.path.join(project_dir(project), "registry"))


def reserve_dir(project):
    return os.path.join(project_dir(project), "reserve")


def reservations(project, exclude_tokens=()):
    """아직 첫 등록(register) 전인 세션의 롤 예약. 세션 UUID 는 없고 임의 토큰·롤 값·시각만 있다. TTL 이 지난 것은 무시."""
    d = reserve_dir(project)
    out = []
    try:
        names = sorted(os.listdir(d))
    except OSError:
        return out
    for n in names:
        if not n.endswith(".json") or n[:-5] in exclude_tokens:
            continue
        r = read_json(os.path.join(d, n), {})
        if r and now_ts() - float(r.get("created_ts", 0)) < RESERVE_TTL_SEC:
            r["_token"] = n[:-5]
            out.append(r)
    return out


def own_tokens(sid):
    t = (read_text(os.path.join(own_dir(sid), "reservation")) or "").strip()
    return {t} if t else set()


def occupied(project, exclude_key=None, exclude_tokens=()):
    """(값, 식별자) 목록 — 생존 레지스트리 항목 + 유효 예약."""
    out = []
    for e in live_entries(project):
        if e.get("_key") == exclude_key:
            continue
        out.append((e.get("value") or join_value(e.get("role", ""), e.get("area", ""), e.get("name", "")),
                    "%s:%%%s" % (e.get("tmux_session"), pane_num(e.get("pane")))))
    for r in reservations(project, exclude_tokens):
        out.append((r.get("value", ""), "기동 중 세션(%s)" % r.get("created", "")))
    return out


def active_conflicts(project, value, exclude_key=None, exclude_tokens=()):
    return [ident for val, ident in occupied(project, exclude_key, exclude_tokens) if val == value]


def same_area_idents(project, value, exclude_key=None, exclude_tokens=()):
    """에이전트명을 뺀 (롤+영역)이 같은 활성 세션의 (값, 식별자) 목록 — 죽은 세션(pid 불일치)은 occupied 가 이미 걸러 낸다."""
    base = split_value(value)
    return [(val, ident) for val, ident in occupied(project, exclude_key, exclude_tokens) if split_value(val) == base]


def check_dup(project, value, exclude_key=None, exclude_tokens=()):
    """에이전트명 필요 여부 판정. 통과면 None, 아니면 NameRequired/RoleError 를 던진다. project_lock 안에서 부른다.

    - (롤+영역)이 같은 활성 세션이 없으면 통과(이름이 있어도 없어도 된다).
    - 있는데 내 값에 이름이 없으면 NameRequired.
    - 있고 같은 이름까지 겹치면 NAME_TAKEN.
    """
    rid, _, name = parse_value(value)
    if rid == "all":
        return
    same = same_area_idents(project, value, exclude_key, exclude_tokens)
    if not same:
        return
    idents = ", ".join(i for _, i in same)
    if not name:
        raise NameRequired("NAME_REQUIRED 같은 영역(%s)의 활성 세션이 이미 있습니다: %s — 에이전트명이 필요합니다"
                           % (join_value(*split_value(value)), idents))
    taken = [i for v, i in same if name_of(v).lower() == name.lower()]
    if taken:
        raise RoleError("NAME_TAKEN 이미 같은 이름(%s)을 쓰는 활성 세션이 있습니다: %s — 다른 이름을 고르세요"
                        % (name, ", ".join(taken)))


def conflict_line(project, value, exclude_key=None, exclude_tokens=()):
    c = active_conflicts(project, value, exclude_key, exclude_tokens)
    if not c:
        return ""
    return "⚠️ [롤 중복] 이미 활성: %s (%s). 그 세션을 ccc 로 재개하거나 다른 영역을 고르세요" % (", ".join(c), value)


def resume_path(project):
    return os.path.join(project_dir(project), "resume_index.jsonl")


def resume_upsert(project, rec):
    path = resume_path(project)
    rec = dict(rec)
    rec["updated"] = iso()
    rec["updated_ts"] = now_ts()
    with FileLock(path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        lines = (read_text(path) or "").splitlines()
        if len(lines) > RESUME_MAX_LINES:
            last = {}
            for ln in lines:
                try:
                    j = json.loads(ln)
                except ValueError:
                    continue
                if isinstance(j, dict) and j.get("sid"):
                    last.pop(j["sid"], None)
                    last[j["sid"]] = j
            atomic_write(path, "".join(json.dumps(v, ensure_ascii=False) + "\n" for v in last.values()))


def resume_records(project):
    last = {}
    for ln in (read_text(resume_path(project)) or "").splitlines():
        try:
            j = json.loads(ln)
        except ValueError:
            continue
        if isinstance(j, dict) and j.get("sid"):
            last[j["sid"]] = j
    return list(last.values())


def resume_last(project, sid):
    for r in resume_records(project):
        if r.get("sid") == sid:
            return r
    return {}


def transcript_exists(sid):
    if os.environ.get("ROLE_SKIP_TRANSCRIPT_CHECK", "") == "1":
        return True
    pdir = os.path.join(home_base(), "projects")
    if not os.path.isdir(pdir):
        return True
    try:
        for d in os.listdir(pdir):
            if os.path.isfile(os.path.join(pdir, d, sid + ".jsonl")):
                return True
    except OSError:
        return True
    return False


# ───────────────────────── 대화 미리보기(읽기 전용) ─────────────────────────

PREVIEW_TAIL = 256 * 1024
PREVIEW_WIDTH = 60
_ESC_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[@-Z\\-_]")
_CTRL_RE = re.compile(r"[\x00-\x1f\x7f-\x9f]")
_EMPTY_PREVIEW = {"last_user": "", "last_assistant": "", "last_ts": ""}


def _cell(ch):
    import unicodedata
    return 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1


def _clip(text, width=PREVIEW_WIDTH):
    """ESC 시퀀스를 먼저, 나머지 제어문자를 그다음 지우고 공백을 줄인 뒤 표시 폭 초과 시 …로 자른다."""
    t = _ESC_RE.sub("", text or "")
    t = _CTRL_RE.sub(" ", t)
    t = " ".join(t.split())
    if sum(_cell(c) for c in t) <= width:
        return t
    out, w = [], 0
    for ch in t:
        if w + _cell(ch) > width - 1:
            break
        out.append(ch)
        w += _cell(ch)
    return "".join(out) + "…"


def _find_transcript(sid):
    pdir = os.path.join(home_base(), "projects")
    try:
        for d in os.listdir(pdir):
            p = os.path.join(pdir, d, sid + ".jsonl")
            if os.path.isfile(p):
                return p
    except OSError:
        pass
    return ""


def _is_agent_transcript(path):
    """첫 줄 type 이 agent-setting 이면 팀에이전트 대화 기록이다."""
    try:
        with open(path, "rb") as f:
            o = json.loads(f.readline(65536).decode("utf-8", "replace"))
        return isinstance(o, dict) and o.get("type") == "agent-setting"
    except (OSError, ValueError):
        return False


def _newest_transcript(cwd):
    d = os.path.join(home_base(), "projects", re.sub(r"[^A-Za-z0-9]", "-", cwd or ""))
    cands = []
    try:
        for n in os.listdir(d):
            if not n.endswith(".jsonl"):
                continue
            p = os.path.join(d, n)
            try:
                cands.append((os.path.getmtime(p), p))
            except OSError:
                continue
    except OSError:
        return ""
    cands.sort(reverse=True)
    for _m, p in cands:
        if not _is_agent_transcript(p):
            return p
    return ""


def _entry_texts(content):
    if isinstance(content, str):
        return [content]
    if isinstance(content, list):
        return [c["text"] for c in content
                if isinstance(c, dict) and c.get("type") == "text" and isinstance(c.get("text"), str)]
    return []


_CMD_ARGS_RE = re.compile(r"<command-args>(.*?)</command-args>", re.S)
_NOTICE_PREFIXES = ("Another Claude session", "<cross-session-message")
TOPIC_HEAD_SCAN = 1024 * 1024
TOPIC_WIDTH = 60


def _human_input(texts):
    """사용자 항목 분류 → (kind, 본문). kind: human(사람 입력)·notice(세션 간 통지)·skip(중단 문구·시스템 주입·인자 없는 슬래시 등).
    자기 팀원 보고(<teammate-message>)는 notice 가 아니다 — 그 뒤 답변은 사용자에게 하는 작업 보고일 수 있다."""
    joined = " ".join(texts).strip()
    if not joined or joined.startswith("[Request interrupted"):
        return "skip", ""
    if joined.startswith(_NOTICE_PREFIXES):
        return "notice", ""
    if joined.startswith("<command-"):
        m = _CMD_ARGS_RE.search(joined)
        arg = m.group(1).strip() if m else ""
        return ("human", arg) if arg else ("skip", "")
    if joined.startswith("<"):
        return "skip", ""
    return "human", joined


def session_topic(sid, profile, path):
    """재개 목록용 작업 주제. 우선순위: 파이프라인 주제(work_title·main_topic) > Claude Code 세션 제목(custom·ai-title)
    > 첫 사용자 입력(잘라서). 실패는 빈 값(읽기 전용)."""
    bases = [home_base()]
    if profile and "/" not in profile:
        bases.append(os.path.join(os.path.expanduser("~"), ".claude-profiles", profile))
    for base in bases:
        for name in ("work_title", "main_topic"):
            try:
                with open(os.path.join(base, "session-env", sid, name), encoding="utf-8", errors="replace") as f:
                    t = _clip(f.readline(), TOPIC_WIDTH)
                if t:
                    return t
            except OSError:
                continue
    if not path:
        return ""
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            # 세션 제목은 턴마다 다시 기록되므로 끝부분만 본다(기록이 수백 MB 일 수 있다)
            f.seek(max(0, size - PREVIEW_TAIL))
            custom = ai = ""
            for ln in f.read().split(b"\n"):
                if b'itle"' not in ln:
                    continue
                try:
                    o = json.loads(ln.decode("utf-8", "replace"))
                except ValueError:
                    continue
                if isinstance(o, dict) and o.get("type") == "custom-title":
                    custom = o.get("customTitle") or custom
                elif isinstance(o, dict) and o.get("type") == "ai-title":
                    ai = o.get("aiTitle") or ai
            if custom or ai:
                return _clip(custom or ai, TOPIC_WIDTH)
            f.seek(0)
            for ln in f.read(TOPIC_HEAD_SCAN).split(b"\n"):
                try:
                    o = json.loads(ln.decode("utf-8", "replace"))
                except ValueError:
                    continue
                if not isinstance(o, dict) or o.get("type") != "user" or o.get("isMeta") or o.get("isSidechain"):
                    continue
                msg = o.get("message")
                kind, text = _human_input([x for x in _entry_texts(msg.get("content") if isinstance(msg, dict) else None) if x.strip()])
                if kind == "human":
                    return _clip(text, TOPIC_WIDTH)
    except Exception:
        pass
    return ""


def transcript_preview(path):
    """대화 기록 끝에서 마지막 사용자·응답 문장과 시각(MM-DD HH:MM)을 뽑는다. 256KiB 블록 단위로 최대 4회 더 거슬러 올라간다(총 1.25MiB). 실패는 빈 값."""
    res = dict(_EMPTY_PREVIEW)
    prompt_fallback = ""
    try:
        size = os.path.getsize(path)
        last_dt = ""
        with open(path, "rb") as f:
            for i in range(5):
                end = size - i * PREVIEW_TAIL
                if end <= 0:
                    break
                start = max(0, end - PREVIEW_TAIL)
                f.seek(start)
                raw = f.read(end - start)
                if i > 0:
                    raw += f.readline()  # 새 블록이 버린 경계 걸친 줄을 여기서 회수
                lines = raw.split(b"\n")
                if start > 0:
                    lines = lines[1:]
                blk_user = blk_asst = blk_dt = ""
                after_notice = False  # 직전 입력이 사람이 아닌 통지였으면 그 답변은 작업 요약이 아니다
                for ln in lines:
                    try:
                        o = json.loads(ln.decode("utf-8", "replace"))
                    except ValueError:
                        continue
                    if not isinstance(o, dict) or o.get("isMeta") or o.get("isSidechain"):
                        continue
                    t = o.get("type")
                    if t == "last-prompt":
                        lp = o.get("lastPrompt")
                        if isinstance(lp, str) and lp.strip() and not lp.startswith(("!", "<", "/")):
                            prompt_fallback = _clip(lp)
                        continue
                    # 작업 중 도착한 세션 간 통지는 user 항목이 아니라 attachment 로 기록된다
                    if t == "attachment" and any(x.encode() in ln for x in _NOTICE_PREFIXES):
                        after_notice = True
                        continue
                    if t not in ("user", "assistant"):
                        continue
                    msg = o.get("message")
                    texts = [x for x in _entry_texts(msg.get("content") if isinstance(msg, dict) else None) if x.strip()]
                    if t == "user":
                        kind, joined = _human_input(texts)
                        if kind == "notice":
                            after_notice = True
                        if kind != "human":
                            continue
                        after_notice = False
                        blk_user = _clip(joined)
                    else:
                        if not texts or after_notice:
                            continue
                        blk_asst = _clip(texts[-1])
                    if isinstance(o.get("timestamp"), str):
                        blk_dt = o["timestamp"]
                if not last_dt and (blk_user or blk_asst):
                    last_dt = blk_dt
                if not res["last_user"]:
                    res["last_user"] = blk_user
                if not res["last_assistant"]:
                    res["last_assistant"] = blk_asst
                if res["last_user"] and res["last_assistant"]:
                    break
        if not res["last_user"]:
            res["last_user"] = prompt_fallback
        if last_dt:
            try:
                d = datetime.datetime.fromisoformat(last_dt.replace("Z", "+00:00")).astimezone()
                res["last_ts"] = d.strftime("%m-%d %H:%M")
            except ValueError:
                pass
    except Exception:
        return dict(_EMPTY_PREVIEW)
    return res


# ───────────────────────── 롤 값 정규화 ─────────────────────────

def normalize_value(text, root=None, project=None, exclude_key=None, keep_area=None, exclude_tokens=()):
    """텍스트('back', 'back:결제', 'back 결제', 'back:결제#철수', 'back#철수') → 저장 값. 실패 시 RoleError.

    '#' 뒤는 에이전트명이며 check_name 으로 검증한다. 자동 번호는 붙이지 않는다(project 등 나머지 인자는 호환용).
    """
    t = re.sub(r"\s*\([^)]*\)\s*", " ", (text or "")).strip()
    name = ""
    if "#" in t:
        t, n = t.split("#", 1)
        t = t.strip()
        name = check_name(n)
    rid_txt, area = t, ""
    m = re.fullmatch(r"^(\S+?)\s+(\S+)$", t)
    if m:
        rid_txt, area = m.group(1), m.group(2)
    else:
        a, b = split_value(t)
        rid_txt, area = a, b
    rid = norm_id(rid_txt)
    if not rid:
        raise RoleError("ROLE_UNKNOWN %s\n%s" % (t, roles_listing()))
    rp = load_paths(root) if root else None
    defined = areas_of(rp, rid)
    if rid == "all":
        if area or name:
            raise RoleError("AREA_UNDEFINED all 롤은 영역·에이전트명을 갖지 않는다")
        return "all"
    if area:
        for a in defined:
            if a["name"].lower() == area.lower():
                return join_value(rid, a["name"], name)
        names = ", ".join(a["name"] for a in defined) or "(정의 없음)"
        raise RoleError("AREA_UNKNOWN %s:%s — 정의된 영역: %s" % (rid, area, names))
    return join_value(rid, "", name)


# ───────────────────────── 세션 파일 쓰기 ─────────────────────────

def write_role_files(sid, value, mode):
    for b in bases_for(mode):
        atomic_write(os.path.join(sess_dir(b, sid), "role"), value + "\n")


def mark_asked(sid, source, mode="both"):
    for b in bases_for(mode):
        atomic_write(os.path.join(sess_dir(b, sid), "role_asked"), "%s %s\n" % (source, iso()))


def log_line(sid, name, text):
    try:
        p = os.path.join(own_dir(sid), "logs", name)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "a", encoding="utf-8") as f:
            f.write("%s %s\n" % (iso(), text))
    except OSError:
        pass


# ───────────────────────── 문안 ─────────────────────────

def context_text(sid, value, root):
    if split_value(value)[0] == "all":
        return ""
    rid, area = split_value(value)
    info = role_info(rid)
    paths = role_paths_for(load_paths(root), value)
    ptxt = (" 담당 경로: %s." % ", ".join(paths)) if paths else ""
    return ("🎭 [롤:%s %s] 담당: %s.%s 담당 밖 요청은 직접 수행하지 말고 Skill('orole') 인계 절차로 넘긴 뒤 사용자에게 보고하라. "
            "사용자가 롤 밖 수행을 원하면 `/orole all` 로 바꾸도록 안내하라. 공용 문서(HISTORY·LESSONS·plan/) 갱신은 허용."
            % (value, info.get("display", rid), info.get("duty", ""), ptxt))


def announce_text(sid, value, project, root, to_all):
    done = "%s announce-done --sid %s" % (LIB_CMD, sid)
    if to_all:
        body = "[롤등록][프로젝트:%s][롤:all] <내 세션명> — 전체 롤로 전환(특정 롤 없음)" % project
    else:
        rid, _ = split_value(value)
        info = role_info(rid)
        paths = role_paths_for(load_paths(root), value)
        ptxt = (", 담당 경로 %s" % " ".join(paths)) if paths else ""
        body = ("[롤등록][프로젝트:%s][롤:%s] <내 세션명> — 지금부터 %s(%s) 로 진행 중. %s%s 관련 요청은 나에게 보내라"
                % (project, value, value, info.get("display", rid), info.get("duty", ""), ptxt))
    return ("📣 [롤등록] 같은 프로젝트 세션에 내 롤을 알려라: ① ListAgents ② 대상은 기존 [작업시작] 규칙 그대로(peer_targets.json, 같은 프로젝트 세션) "
            "③ SendMessage 본문 `%s` (<내 세션명> 은 내 세션 표시 이름) ④ 발송 후(대상 0개여도) `%s` 실행" % (body, done))


def remind_text(sid, n):
    return ("⚠️ [롤등록 미발송] 앞서 안내한 [롤등록] 통지를 아직 보내지 않았다. 안내대로 발송한 뒤 `%s announce-done --sid %s` 를 실행하라 (재안내 %d/%d)"
            % (LIB_CMD, sid, n, REMIND_MAX))


def ask_spec_text(sid, root):
    ap = ask_pages(None)
    page_txt = " ".join("[쪽 %d] %s" % (pg["page"] + 1, " / ".join("`%s`" % o["label"] for o in pg["options"])) for pg in ap["pages"])
    rp = load_paths(root)
    area_txt = ""
    if rp:
        parts = []
        for rid in role_ids():
            names = [a["name"] for a in areas_of(rp, rid)]
            if names:
                parts.append("%s: %s" % (rid, "·".join(names)))
        if parts:
            area_txt = (" 고른 롤에 영역 정의가 있으면 영역을 1단계 더 묻는다(옵션 ≤4, 넘치면 Other 입력을 정의 이름과 대조) — %s. 값은 `롤:영역` 으로 넘긴다." % " / ".join(parts))
    sid_arg = (" --sid %s" % sid) if sid else ""
    return ("❓ [롤 질문] 이 세션에 롤이 없다. 사용자 첫 요청을 처리하기 전에 AskUserQuestion 으로 롤을 1회만 물어라. "
            "header `%s`, 질문 \"%s\", 옵션은 쪽별로 %s (옵션 상한 %d, 정확한 JSON 은 `%s ask-pages --json%s`). "
            "롤을 고르면 즉시 확정. `다음 쪽`/`이전 쪽` 을 고르면 해당 쪽으로 다시 묻는다(쪽 이동은 질문 횟수에 세지 않음).%s "
            "Other(자유 입력)는 `%s norm <입력>` 으로 정규화하고 목록 밖이면 1쪽을 1회만 다시 묻는다. 그래도 목록 밖이거나 건너뛰면 all. "
            "확정 후 `%s set%s <롤> --source ask` 를 실행하고 원래 요청을 처리하라. "
            "set 이 종료코드 3(NAME_REQUIRED, 같은 프로젝트에 같은 영역의 활성 세션이 있음)이면 AskUserQuestion 으로 에이전트명을 묻고(직접 입력은 Other, "
            "형식 오류·이름 중복은 stderr 안내대로 다시 묻기) `<롤>#<이름>` 으로 다시 set 하라. 활성 세션이 없으면 이름은 묻지 않는다."
            % (ap["header"], ap["question"], page_txt, ap["max_options"], LIB_CMD, sid_arg, area_txt, LIB_CMD, LIB_CMD, sid_arg))


def due_text(sid, item):
    r = item.get("role", "?")
    return ("⏱ [인계 시한] 요청 %s(롤 %s) 수락 0 — 사용자에게 '맡을 %s 세션 없음 — 새 세션 `cc %s` 또는 이 세션 `/orole all`' 1줄 보고(질문 아님) 후 "
            "`%s handoff-update --sid %s --id %s --state none` 실행" % (item.get("id"), r, r, split_value(r)[0], LIB_CMD, sid, item.get("id")))


# ───────────────────────── 명령 구현 ─────────────────────────

def cmd_norm(a):
    text = " ".join(a.text)
    root = a.root or find_root(os.getcwd())
    v = normalize_value(text, root=root)
    print(v)
    return 0


def cmd_list(a):
    d = load_defs()
    if a.json:
        print(json.dumps({"default": d["default"], "roles": d["roles"]}, ensure_ascii=False))
        return 0
    print(roles_listing())
    return 0


def cmd_get(a):
    sid = resolve_sid(a.sid)
    v = read_role_raw(sid)
    if a.raw:
        if v:
            print(v if not a.id_only else split_value(v)[0])
        return 0
    v = v or load_defs()["default"]
    print(split_value(v)[0] if a.id_only else v)
    return 0


def _ctx_project(a):
    if getattr(a, "project", None):
        return a.project.lower()
    ts = getattr(a, "tmux_session", None)
    return project_slug(ts, getattr(a, "cwd", None))


def cmd_set(a):
    sid = resolve_sid(a.sid)
    text = " ".join(a.text)
    cwd = a.cwd or os.getcwd()
    root = a.root or find_root(cwd)
    pane = a.pane or (os.environ.get("TMUX_PANE", "") if a.base != "home" else "")
    tsess = a.tmux_session or (tmux_session_of(pane) if pane else None)
    project = (a.project or project_slug(tsess, cwd)).lower()
    my_key = live_key(tsess, pane) if (tsess and pane_num(pane)) else None
    prev = read_role_raw(sid)
    pid = None
    if my_key:
        pid = a.pid if a.pid is not None else find_claude_pid()
    with project_lock(project):
        toks = own_tokens(sid)
        value = normalize_value(text, root=root)
        rid0 = split_value(value)[0]
        w = ""
        if rid0 != "all" and prev != value:  # 이미 이 값을 쓰는 중인 자기 재지정은 중복으로 보지 않는다
            check_dup(project, value, my_key, toks)
        write_role_files(sid, value, a.base)
        if my_key and pid:
            _live_upsert(project, tsess, pane, pid, value)
            drop_reservation(sid, project)
        elif rid0 != "all":
            make_reservation(sid, project, value, a.base)
        else:
            drop_reservation(sid, project)
    mark_asked(sid, a.source, a.base)
    od = own_dir(sid)
    if prev and prev != value and split_value(prev)[0] != "all":
        atomic_write(os.path.join(od, "role_changed_from"), prev + "\n")
    rid, area = split_value(value)
    profile = a.profile if a.profile is not None else os.environ.get("CLAUDE_PROFILE_NAME", "")
    old = resume_last(project, sid)
    rec = {"sid": sid, "role": rid, "area": area, "name": name_of(value), "value": value,
           "profile": profile or old.get("profile", ""),
           "topic": a.topic if a.topic is not None else old.get("topic", ""),
           "cwd": cwd, "source": a.source}
    if old.get("imported_from"):
        rec["imported_from"] = old["imported_from"]  # 재개 기록이 '가져온 대화' 표식을 지우지 않게 이월한다
    resume_upsert(project, rec)
    out = ["ROLE_SET %s" % value]
    try:
        os.unlink(os.path.join(od, "role_registered"))
    except OSError:
        pass
    if w:
        out.append(w)
    print("\n".join(out))
    return 0


def cmd_agent(a):
    """에이전트명 지정·변경·해제·조회. 롤·영역은 그대로 두고 '#이름' 만 바꾼다(실제 저장은 cmd_set 경로를 재사용)."""
    sid = resolve_sid(a.sid)
    cur = read_role_raw(sid) or load_defs()["default"]
    rid, area, cur_name = parse_value(cur)
    if not a.name and not a.clear:
        print("AGENT_NAME %s" % (cur_name or "(없음)"))
        print("ROLE %s" % cur)
        return 0
    if rid == "all":
        raise RoleError("AGENT_NO_ROLE all 롤에는 에이전트명을 붙일 수 없습니다 — 먼저 /orole 로 롤을 고르세요")
    new_name = "" if a.clear else check_name(" ".join(a.name))
    if new_name == cur_name:
        print("AGENT_UNCHANGED %s" % cur)
        return 0
    a.text = [join_value(rid, area, new_name)]
    return cmd_set(a)


def cmd_dup_check(a):
    """런처·질문 흐름용 사전 판정. OK / NAME_REQUIRED(rc=3) / NAME_TAKEN·NAME_INVALID(rc=2)."""
    root = a.root or find_root(a.cwd or os.getcwd())
    value = normalize_value(" ".join(a.text), root=root)
    project = (a.project or project_slug(None, a.cwd)).lower()
    with project_lock(project):
        check_dup(project, value, a.exclude_key)
    print("OK %s" % value)
    return 0


def cmd_name_check(a):
    print("OK %s" % check_name(" ".join(a.name)))
    return 0


def make_reservation(sid, project, value, mode):
    """pane 이 아직 없는(런처 기동 전) 세션의 번호 예약. 반드시 project_lock 안에서 부른다.

    예약 파일에는 임의 토큰·롤 값·시각만 둔다(세션 UUID 없음). 토큰은 자기 세션 디렉터리에만 적는다.
    """
    drop_reservation(sid, project)
    import secrets  # 지연 import(기동 비용 절감)
    tok = secrets.token_hex(4)
    write_json(os.path.join(reserve_dir(project), tok + ".json"),
               {"project": project, "value": value, "created": iso(), "created_ts": now_ts()})
    atomic_write(os.path.join(own_dir(sid), "reservation"), tok + "\n")


def drop_reservation(sid, project):
    """자기 예약(토큰)만 지운다. 반드시 project_lock 안에서 부른다."""
    for tok in own_tokens(sid):
        if re.fullmatch(r"^[0-9a-f]{8}$", tok):
            try:
                os.unlink(os.path.join(reserve_dir(project), tok + ".json"))
            except OSError:
                pass
    try:
        os.unlink(os.path.join(own_dir(sid), "reservation"))
    except OSError:
        pass


def _live_upsert(project, tsess, pane, pid, value):
    key = live_key(tsess, pane)
    path = os.path.join(live_dir(project), key + ".json")
    rid, area = split_value(value)
    if rid == "all":
        try:
            os.unlink(path)
        except OSError:
            pass
        return
    write_json(path, {"project": project, "role": rid, "area": area, "name": name_of(value), "value": value,
                      "tmux_session": tsess, "pane": "%" + pane_num(pane), "pid": int(pid) if pid else None,
                      "pid_start": proc_start(pid) if pid else None, "updated": iso(), "updated_ts": now_ts()})


def do_register(sid, pane, tsess, pid, profile, cwd, topic, project=None, force=True):
    """생존 레지스트리·재개 색인 갱신. 출력할 경고 줄(없으면 '') 반환."""
    value = current_role(sid)
    project = (project or project_slug(tsess, cwd)).lower()
    od = own_dir(sid)
    reg_path = os.path.join(od, "role_registered")
    sig = "%s|%s|%s" % (value, pane, pid)
    if not force:
        try:
            if (read_text(reg_path) or "").strip() == sig and now_ts() - os.path.getmtime(reg_path) < REGISTER_REFRESH_SEC:
                return ""
        except OSError:
            pass
    first = (read_text(reg_path) or "").strip() != sig
    rid, area = split_value(value)
    warn = ""
    if tsess and pane_num(pane):
        key = live_key(tsess, pane)
        with project_lock(project):
            toks = own_tokens(sid)
            if first and rid != "all":
                warn = conflict_line(project, value, key, toks)
            _live_upsert(project, tsess, pane, pid, value)
            if toks:
                drop_reservation(sid, project)
    old = resume_last(project, sid)
    rec = {"sid": sid, "role": rid, "area": area, "name": name_of(value), "value": value,
           "profile": profile or old.get("profile", ""),
           "topic": topic or old.get("topic", ""), "cwd": cwd or old.get("cwd", "")}
    if old.get("imported_from"):
        rec["imported_from"] = old["imported_from"]  # 세션 등록이 '가져온 대화' 표식을 지우지 않게 이월한다
    resume_upsert(project, rec)
    atomic_write(reg_path, sig + "\n")
    return warn


def cmd_register(a):
    sid = resolve_sid(a.sid)
    w = do_register(sid, a.pane, a.tmux_session, a.pid, a.profile or os.environ.get("CLAUDE_PROFILE_NAME", ""),
                    a.cwd or os.getcwd(), a.topic or "", a.project, force=True)
    if w:
        print(w)
    return 0


def do_announce_due(sid, pid, project, root):
    value = current_role(sid)
    od = own_dir(sid)
    key = "%s|%s|%s" % (value, pid, proc_start(pid) if pid else "")
    ann_path = os.path.join(od, "role_announced")
    prev = (read_text(ann_path) or "").strip()
    if prev == key:
        return ""
    prev_val = prev.split("|", 1)[0] if prev else ""
    to_all = False
    if split_value(value)[0] == "all":
        changed = (read_text(os.path.join(od, "role_changed_from")) or "").strip()
        due = bool((prev_val and split_value(prev_val)[0] != "all") or changed)
        if not due:
            atomic_write(ann_path, key + "\n")
            return ""
        to_all = True
    atomic_write(ann_path, key + "\n")
    atomic_write(os.path.join(od, "role_announce_pending"), "%s|0\n" % value)
    return announce_text(sid, value, project, root, to_all)


def do_announce_remind(sid):
    od = own_dir(sid)
    p = os.path.join(od, "role_announce_pending")
    t = (read_text(p) or "").strip()
    if not t:
        return ""
    val, _, n = t.partition("|")
    try:
        n = int(n)
    except ValueError:
        n = 0
    if n < REMIND_MAX:
        atomic_write(p, "%s|%d\n" % (val, n + 1))
        return remind_text(sid, n + 1)
    if n == REMIND_MAX:
        atomic_write(p, "%s|%d\n" % (val, n + 1))
        log_line(sid, "role_announce.log", "미발송 재안내 상한 도달 role=%s" % val)
    return ""


def cmd_announce_due(a):
    sid = resolve_sid(a.sid)
    pid = a.pid if a.pid is not None else find_claude_pid()
    cwd = a.cwd or os.getcwd()
    t = do_announce_due(sid, pid, _ctx_project(a), a.root or find_root(cwd))
    if t:
        print(t)
    return 0


def cmd_announce_remind(a):
    sid = resolve_sid(a.sid)
    t = do_announce_remind(sid)
    if t:
        print(t)
    return 0


def cmd_announce_done(a):
    sid = resolve_sid(a.sid)
    od = own_dir(sid)
    for n in ("role_announce_pending", "role_changed_from"):
        try:
            os.unlink(os.path.join(od, n))
        except OSError:
            pass
    pid = a.pid if a.pid is not None else find_claude_pid()
    if pid:
        atomic_write(os.path.join(od, "role_announced"), "%s|%s|%s\n" % (current_role(sid), pid, proc_start(pid) or ""))
    print("ANNOUNCE_DONE")
    return 0


def cmd_context(a):
    sid = resolve_sid(a.sid)
    t = context_text(sid, current_role(sid), a.root or find_root(a.cwd or os.getcwd()))
    if t:
        print(t)
    return 0


def cmd_ask_spec(a):
    sid = resolve_sid(a.sid, required=False)
    print(ask_spec_text(sid, a.root or find_root(a.cwd or os.getcwd())))
    return 0


def cmd_find(a):
    project = (a.project or project_slug(None, os.getcwd())).lower()
    want_rid, want_area = split_value(a.role)
    rid = norm_id(want_rid) or want_rid
    out = []
    for e in live_entries(project):
        if e.get("role") != rid:
            continue
        if want_area and (e.get("area") or "").lower() != want_area.lower():
            continue
        out.append({"role": e.get("role"), "area": e.get("area", ""), "tmux_session": e.get("tmux_session"),
                    "pane": e.get("pane"), "match": "%s:%%%s" % (e.get("tmux_session"), pane_num(e.get("pane")))})
    print(json.dumps(out, ensure_ascii=False))
    return 0


def rec_value(r):
    """재개 색인 기록의 표시용 값. 옛 자동 번호(back#1)는 번호를 떼고 에이전트명은 유지한다."""
    rid, area, name = parse_value(r.get("value") or join_value(r.get("role", ""), r.get("area", "")))
    return join_value(rid, area, name)


def cmd_resume_list(a):
    project = a.project.lower()
    recs = resume_records(project)
    if a.role:
        rr, ra = split_value(a.role)
        rid = norm_id(rr) or rr
        recs = [r for r in recs if r.get("role") == rid and (not ra or (r.get("area") or "").lower() == ra.lower())]
    if a.profile:
        # 가져온 대화(imported_from)는 기록 계정이 비어 있어도 계정 필터에서 빼지 않는다
        recs = [r for r in recs if r.get("profile") == a.profile or r.get("imported_from")]
    recs = [r for r in recs if transcript_exists(r["sid"])]
    # 활동 시각 = max(색인 updated_ts, 대화 파일 mtime). cc 밖(claude --resume)에서 이어 쓴 대화는 색인이 갱신되지 않으므로
    # 파일 mtime 으로 보정한다(ADR-035). 파일은 읽지 않고 mtime 만 본다. 파일이 없으면 색인 값 그대로다
    for r in recs:
        act = r.get("updated_ts", 0) or 0
        p = _find_transcript(r["sid"])
        try:
            mt = os.path.getmtime(p) if p else 0
        except OSError:
            mt = 0
        if mt > act:
            r["updated"] = iso(mt)  # 메모리상 기록만 고친다(색인 파일은 쓰지 않는다)
            act = mt
        r["_act_ts"] = act
    recs.sort(key=lambda r: r.get("_act_ts", 0), reverse=True)
    if a.per_role:
        # 롤당 1건 축약은 이 머신 대화에만 적용한다. 가져온 대화는 항상 후보에 남긴다
        seen, keep = set(), []
        for r in recs:
            if r.get("imported_from"):
                keep.append(r)
                continue
            k = rec_value(r)
            if k in seen:
                continue
            seen.add(k)
            keep.append(r)
        recs = keep
    imp = [r for r in recs if r.get("imported_from")][: a.limit]
    loc = [r for r in recs if not r.get("imported_from")][: max(a.limit - len(imp), 0)]
    recs = sorted(imp + loc, key=lambda r: r.get("_act_ts", 0), reverse=True)
    rows = [{"sid": r["sid"], "role": r.get("role", ""), "area": parse_value(rec_value(r))[1],
             "value": rec_value(r),
             "display": display_of(rec_value(r)),
             "profile": r.get("profile", ""), "topic": r.get("topic", ""), "cwd": r.get("cwd", ""),
             "updated": r.get("updated", ""), "imported_from": r.get("imported_from", "")} for r in recs]
    for r in rows:
        # topic 은 --topic 을 준 경우에만 기록되고 실제 호출부는 넘기지 않으므로 목록을 만들 때 계산한다
        if not r["topic"]:
            r["topic"] = session_topic(r["sid"], r["profile"], _find_transcript(r["sid"]))
    if a.preview:
        for r in rows:
            p = _find_transcript(r["sid"])
            r.update(transcript_preview(p) if p else _EMPTY_PREVIEW)
    if a.json:
        print(json.dumps(rows, ensure_ascii=False))
    else:
        for r in rows:
            cols = [r["sid"], r["value"], r["profile"], r["updated"], r["topic"]]
            if a.preview:
                cols += [r["last_ts"], r["last_user"], r["last_assistant"]]
            print("\t".join(cols))
    return 0


def _fork_dir(cwd):
    return os.path.join(home_base(), "projects", re.sub(r"[^A-Za-z0-9]", "-", cwd or ""))


def _transcript_uuids(path, limit=None):
    """대화 jsonl 의 기록 uuid 집합. limit 이 있으면 앞 limit 줄만 본다. 내용은 읽지 않고 uuid 키만 쓴다."""
    out = set()
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for i, ln in enumerate(f):
                if limit is not None and i >= limit:
                    break
                try:
                    o = json.loads(ln)
                except ValueError:
                    continue
                u = o.get("uuid") if isinstance(o, dict) else None
                if isinstance(u, str) and u:
                    out.add(u)
    except OSError:
        pass
    return out


def _fork_log(project, text):
    """fork-adopt 판정 사유를 프로젝트 색인 옆 fork_adopt.log 에 남긴다(서버 재실측 진단용)."""
    try:
        p = os.path.join(os.path.dirname(resume_path(project)), "fork_adopt.log")
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "a", encoding="utf-8") as f:
            f.write("%s %s\n" % (iso(), text))
    except OSError:
        pass


def _fork_skip(project, code, text, rc=3):
    msg = "FORK_SKIP %s %s" % (code, text)
    print(msg)
    _fork_log(project, msg)
    return rc


def cmd_fork_snapshot(a):
    """cc 가 claude 실행 전에 부른다 — cwd 대화 폴더의 기존 sid 목록을 한 줄씩 출력(fork-adopt --before 입력)."""
    try:
        names = os.listdir(_fork_dir(a.cwd))
    except OSError:
        names = []
    for n in sorted(names):
        if n.endswith(".jsonl"):
            print(n[:-6])
    return 0


def cmd_fork_adopt(a):
    """가져온 대화를 --fork-session 으로 재개한 뒤(cc 종료 시점) 새 sid 를 원본 롤로 색인한다.

    fork 새 sid 는 롤 파일이 없어 세션 등록(do_register)이 'all' 로 색인하므로, 이어 쓴 대화가 롤당 1건 축약에서
    다른 'all' 세션에 밀린다. 아래를 모두 만족하는 대화가 정확히 1개일 때만 그 sid 를 원본 기록의 롤·계정·주제로
    다시 기록하고 forked_from 을 남긴다.
      - cwd 대화 폴더에서 --since 이후 바뀐, 원본이 아닌 일반 대화(팀원 대화 제외)
      - --before(cc 가 실행 전에 뜬 sid 목록)에 없음 = 이번 실행에서 새로 생긴 대화
      - fork 증거: 앞 200줄의 기록 uuid 중 하나 이상이 원본 대화의 uuid 집합에 있음
        (같은 cwd 의 무관한 세션은 uuid 를 공유하지 않는다)
      - 새 sid 의 최신 색인 기록이 없거나 기본 'all'(fork 안에서 /orole 로 바꾼 롤은 덮어쓰지 않는다)
    ⚠️ uuid 공유가 --fork-session 산출물 고유 특성인지는 미확정 추정이다. 근거는 로컬 대화 메타 관측
       (파생 대화가 원본 메시지 uuid 를 복사해 가짐, 그중 한 묶음은 가져온 대화에서 이어짐)뿐이다.
       증거가 없으면 상속하지 않는 쪽(FORK_SKIP)으로 둔다.
    건너뛴 사유는 FORK_SKIP <코드> 로 출력하고 fork_adopt.log 에 남긴다.
      코드: no_parent_file · no_shared_uuid · multi · preexisting(실행 전부터 있던 sid 만 바뀜) · non_all · no_role
    rc 0=기록, 3=건너뜀, 2=인자 오류.
    """
    project = a.project.lower()
    parent = a.parent or ""
    if not re.fullmatch(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", parent):
        print("FORK_SKIP bad_args 원본 sid 형식 오류")
        return 2
    d = _fork_dir(a.cwd)
    before = set()
    if a.before:
        try:
            with open(a.before, encoding="utf-8", errors="replace") as f:
                before = {ln.strip() for ln in f if ln.strip()}
        except OSError:
            pass
    ppath = os.path.join(d, parent + ".jsonl")
    if not os.path.isfile(ppath):
        ppath = _find_transcript(parent)
    puuids = _transcript_uuids(ppath) if ppath else set()
    if not puuids:
        return _fork_skip(project, "no_parent_file", "원본 %s 대화 파일(uuid)이 없어 fork 를 판정할 수 없음" % parent[:8])
    changed, pre, cands = 0, 0, []
    try:
        names = os.listdir(d)
    except OSError:
        names = []
    for n in names:
        if not n.endswith(".jsonl") or n[:-6] == parent:
            continue
        p = os.path.join(d, n)
        try:
            if os.path.getmtime(p) < a.since:
                continue
        except OSError:
            continue
        if _is_agent_transcript(p):
            continue
        changed += 1
        if n[:-6] in before:
            pre += 1
            continue
        if _transcript_uuids(p, 200) & puuids:
            cands.append(n[:-6])
    if not cands:
        if changed and pre == changed:
            return _fork_skip(project, "preexisting", "바뀐 대화 %d개가 모두 실행 전부터 있던 sid" % changed)
        return _fork_skip(project, "no_shared_uuid", "바뀐 대화 %d개(실행 전부터 있던 것 %d개) 중 원본 uuid 를 공유하는 것 없음"
                          % (changed, pre))
    if len(cands) != 1:
        return _fork_skip(project, "multi", "원본 uuid 를 공유하는 새 대화 %d개(1개일 때만 롤 상속)" % len(cands))
    new = cands[0]
    cur = resume_last(project, new)
    if cur and (cur.get("value") or "all") != "all":
        return _fork_skip(project, "non_all", "새 sid %s 에 이미 롤 %s 기록이 있음(덮어쓰지 않음)" % (new[:8], cur.get("value")))
    old = resume_last(project, parent)
    value = old.get("value") or a.value or ""
    if not value:
        return _fork_skip(project, "no_role", "원본 롤 기록 없음")
    rid, area = split_value(value)
    rec = {"sid": new, "role": rid, "area": area, "name": name_of(value), "value": value,
           "profile": old.get("profile", ""), "topic": old.get("topic", ""), "cwd": a.cwd or old.get("cwd", ""),
           "source": "fork", "forked_from": parent}
    resume_upsert(project, rec)
    msg = "FORK_ADOPT %s → %s (%s)" % (parent[:8], new[:8], value)
    print(msg)
    _fork_log(project, msg)
    return 0


def menu_items():
    return [{"id": r, "display": role_info(r).get("display", r), "duty": role_info(r).get("duty", "")} for r in role_ids()]


def ask_pages(current=None):
    """롤 질문을 AskUserQuestion 옵션 상한(ASK_MAX_OPTIONS)에 맞춰 쪽으로 탐욕 분할한다. 롤 순서는 roles 배열 순서."""
    mx = ASK_MAX_OPTIONS
    items = menu_items()
    cur_rid = split_value(current)[0] if current else None
    # 쪽별 롤 묶음 계산
    chunks, rest = [], list(items)
    if len(rest) <= mx:
        chunks.append(rest)
    else:
        chunks.append(rest[: mx - 1])
        rest = rest[mx - 1:]
        while len(rest) > mx - 1:
            chunks.append(rest[: mx - 2])
            rest = rest[mx - 2:]
        chunks.append(rest)
    pages = []
    for k, ch in enumerate(chunks):
        opts = []
        for it in ch:
            label = it["display"] + (" (현재)" if cur_rid is not None and it["id"] == cur_rid else "")
            opts.append({"kind": "role", "id": it["id"], "label": label, "description": it["duty"]})
        if k > 0:
            opts.append({"kind": "prev", "to": k - 1, "label": "← 이전 쪽", "description": "앞 쪽 롤 보기"})
        if k < len(chunks) - 1:
            opts.append({"kind": "next", "to": k + 1, "label": "다음 쪽 → " + "·".join(i["display"] for i in chunks[k + 1]),
                         "description": "나머지 롤 보기"})
        pages.append({"page": k, "options": opts})
    cur_txt = display_of(current) if current else ""
    q = "이 세션의 롤을 고르세요 — %s (현재: %s). 직접 입력에 롤 이름·별칭을 쳐도 됩니다" % (
        "·".join(i["display"] for i in items), cur_txt or "없음")
    return {"max_options": mx, "current": current, "question": q, "header": "롤", "pages": pages}


def cmd_ask_pages(a):
    cur = a.current
    if cur is None and a.sid:
        cur = read_role_raw(resolve_sid(a.sid))
    res = ask_pages(cur)
    if a.json:
        print(json.dumps(res, ensure_ascii=False))
    else:
        for pg in res["pages"]:
            print("쪽 %d: %s" % (pg["page"] + 1, " | ".join(o["label"] for o in pg["options"])))
    return 0


def cmd_menu_items(a):
    rows = menu_items()
    if a.json:
        print(json.dumps(rows, ensure_ascii=False))
    else:
        for r in rows:
            print("\t".join([r["id"], r["display"], r["duty"]]))
    return 0


def cmd_preview(a):
    path = _find_transcript(a.sid) if a.sid else (_newest_transcript(a.cwd) if a.cwd else "")
    res = transcript_preview(path) if path else dict(_EMPTY_PREVIEW)
    if a.json:
        out = dict(res)
        out["sid"] = os.path.splitext(os.path.basename(path))[0] if path else ""
        print(json.dumps(out, ensure_ascii=False))
    else:
        print("\t".join([res["last_ts"], res["last_user"], res["last_assistant"]]))
    return 0


def check_path(value, root, path):
    rp = load_paths(root)
    rid, area = split_value(value)
    if not rp or rid == "all":
        return "OK"
    rel = rel_to_root(root, path)
    if rel is None:
        return "OK"
    if path_match(rel, [p for p in rp.get("shared", []) if isinstance(p, str)]):
        return "OK"
    own_area_named = bool(area)
    if own_area_named and path_match(rel, area_paths(rp, rid, area)):
        return "OK"
    for a in areas_of(rp, rid):
        if own_area_named and a["name"].lower() == area.lower():
            continue
        if path_match(rel, a.get("paths", [])):
            if own_area_named:
                return "WARN %s:%s" % (rid, a["name"])
    if path_match(rel, (rp.get("roles") or {}).get(rid, [])):
        return "OK"
    for orid in role_ids():
        if orid in (rid, "all"):
            continue
        if path_match(rel, (rp.get("roles") or {}).get(orid, [])):
            return "WARN %s" % orid
        for a in areas_of(rp, orid):
            if path_match(rel, a.get("paths", [])):
                return "WARN %s:%s" % (orid, a["name"])
    return "OK"


def cmd_check_path(a):
    sid = resolve_sid(a.sid)
    print(check_path(current_role(sid), a.root, a.path))
    return 0


# ── peer_roles ──

def parse_announce(text):
    m = re.search(r"\[프로젝트:([^\]]+)\]", text or "")
    proj = m.group(1).strip().lower() if m else None
    m = re.search(r"\[롤:([^\]]+)\]", text or "")
    val = m.group(1).strip() if m else None
    if not val:
        m = re.search(r"지금부터\s+(\S+?)\(", text or "")
        val = m.group(1) if m else None
    if not val and "전체 롤로 전환" in (text or ""):
        val = "all"
    return proj, val


def cmd_peer_record(a):
    sid = resolve_sid(a.sid)
    proj, val = parse_announce(a.text)
    if not proj or proj != a.self_project.strip().lower():
        print("SKIP_PROJECT")
        return 0
    rid, area, pname = parse_value(val or "")
    rid = norm_id(rid)
    if not rid:
        print("SKIP_INVALID")
        return 0
    value = join_value(rid, area if rid != "all" else "", pname if rid != "all" else "")
    m = re.search(r"담당 경로\s+(.+?)\s+관련 요청", a.text or "")
    paths = m.group(1).split() if m else []
    path = os.path.join(own_dir(sid), "peer_roles.json")
    with FileLock(path):
        d = read_json(path, {})
        d[a.from_] = {"from": a.from_, "from_name": a.from_name, "project": proj, "role": rid,
                      "area": area if rid != "all" else "", "value": value, "paths": paths, "updated": iso()}
        write_json(path, d)
    print("RECORDED")
    return 0


def peer_roles(sid):
    if not sid:
        return {}
    return read_json(os.path.join(own_dir(sid), "peer_roles.json"), {})


def cmd_route(a):
    sid = resolve_sid(a.sid, required=False)
    project = a.project.lower()
    rr, ra = split_value(a.role)
    rid = norm_id(rr) or rr
    rp = load_paths(a.root) if a.root else None
    cands = []  # (ident, value)
    for e in live_entries(project):
        if e.get("role") == rid:
            cands.append(("%s:%%%s" % (e.get("tmux_session"), pane_num(e.get("pane"))), join_value(rid, e.get("area", ""), e.get("name", ""))))
    for p in peer_roles(sid).values():
        if p.get("project") == project and p.get("role") == rid:
            cands.append((p.get("from") or p.get("from_name"), p.get("value") or rid))
    if ra:
        cands = [c for c in cands if split_value(c[1])[1].lower() == ra.lower()] or cands
    seen, uniq = set(), []
    for c in cands:
        if c[0] and c[0] not in seen:
            seen.add(c[0])
            uniq.append(c)
    if not uniq:
        res = ("NONE", [])
    else:
        hits = []
        if rp and a.path:
            rels = [r for r in (rel_to_root(a.root, p) for p in a.path) if r]
            for ident, val in uniq:
                _, area = split_value(val)
                pats = area_paths(rp, rid, area) if area else []
                if pats and any(path_match(r, pats) for r in rels):
                    hits.append(ident)
        res = ("ONE", hits) if len(hits) == 1 else ("MANY", [c[0] for c in uniq])
    if a.json:
        print(json.dumps({"result": res[0], "targets": res[1]}, ensure_ascii=False))
    else:
        print((res[0] + " " + " | ".join(res[1])).strip())
    return 0


# ── handoffs ──

def handoffs_path(sid):
    return os.path.join(own_dir(sid), "handoffs.json")


def _target_obj(ident, peers):
    for p in peers.values():
        if ident and ident in (p.get("from"), p.get("from_name")):
            return {"name": ident, "from": p.get("from", ""), "from_name": p.get("from_name", "")}
    return {"name": ident, "from": "", "from_name": ""}


def cmd_handoff_open(a):
    sid = resolve_sid(a.sid)
    import secrets  # 지연 import(기동 비용 절감)
    hid = (a.id or secrets.token_hex(3)).lower()
    if not re.fullmatch(r"^[0-9a-f]{6}$", hid):
        raise RoleError("HANDOFF_ID_INVALID %s (6자리 16진)" % hid)
    if a.state not in HANDOFF_STATES:
        raise RoleError("HANDOFF_STATE_INVALID %s" % a.state)
    peers = peer_roles(sid)
    path = handoffs_path(sid)
    with FileLock(path):
        d = read_json(path, {})
        d[hid] = {"id": hid, "role": a.role, "targets": [_target_obj(t, peers) for t in (a.target or [])],
                  "state": a.state, "deadline_ts": now_ts() + a.deadline_min * 60,
                  "deadline": iso(now_ts() + a.deadline_min * 60), "created": iso(), "winner": "", "due_notified": 0}
        write_json(path, d)
    print("HANDOFF %s" % hid)
    return 0


def cmd_handoff_update(a):
    sid = resolve_sid(a.sid)
    if a.state not in HANDOFF_STATES:
        raise RoleError("HANDOFF_STATE_INVALID %s" % a.state)
    path = handoffs_path(sid)
    with FileLock(path):
        d = read_json(path, {})
        it = d.get((a.id or "").lower())
        if not it:
            print("NOT_FOUND")
            return 0
        it["state"] = a.state
        if a.winner:
            it["winner"] = a.winner
        it["updated"] = iso()
        write_json(path, d)
    print("UPDATED %s %s" % (it["id"], a.state))
    return 0


def handoff_due_lines(sid):
    path = handoffs_path(sid)
    if not os.path.isfile(path):
        return []
    out = []
    with FileLock(path):
        d = read_json(path, {})
        changed = False
        for it in d.values():
            if it.get("state") == "confirm_wait" and now_ts() >= float(it.get("deadline_ts", 0)) \
                    and int(it.get("due_notified", 0)) < DUE_NOTIFY_MAX:
                it["due_notified"] = int(it.get("due_notified", 0)) + 1
                changed = True
                out.append(due_text(sid, it))
        if changed:
            write_json(path, d)
    return out


def cmd_handoff_due(a):
    sid = resolve_sid(a.sid)
    for ln in handoff_due_lines(sid):
        print(ln)
    return 0


def cmd_handoff_accept(a):
    sid = resolve_sid(a.sid)
    path = handoffs_path(sid)
    hid = (a.id or "").lower()
    with FileLock(path):
        d = read_json(path, {})
        it = d.get(hid)
        if not it or it.get("state") != "confirm_wait" or now_ts() >= float(it.get("deadline_ts", 0)):
            print("LATE")
            return 0
        it["state"] = "confirmed"
        it["winner"] = a.from_
        it["confirmed_at"] = iso()
        others = []
        for t in it.get("targets", []):
            names = {t.get("name"), t.get("from"), t.get("from_name")}
            if a.from_ in names or (a.from_name and a.from_name in names):
                t["from"] = a.from_
                if a.from_name:
                    t["from_name"] = a.from_name
                continue
            others.append(t.get("from") or t.get("name"))
        write_json(path, d)
    print(("WINNER " + " | ".join(o for o in others if o)).strip())
    return 0


def handoff_status(sid, hid):
    """[공개 API] 자기 handoffs.json 의 요청 상태 조회(읽기 전용, flock).

    반환: {"id","state","winner","role"} 또는 없으면 {}. hook 이 [인계수락] LATE 를 '같은 수락자 재수신' 과
    구분할 때 role_state/ 파일을 직접 읽지 않고 이 함수(또는 handoff-status 명령)를 쓴다.
    """
    path = handoffs_path(sid)
    if not os.path.isfile(path):
        return {}
    with FileLock(path):
        it = read_json(path, {}).get((hid or "").lower())
    if not it:
        return {}
    return {"id": it.get("id", ""), "state": it.get("state", ""), "winner": it.get("winner", ""), "role": it.get("role", "")}


def cmd_handoff_status(a):
    sid = resolve_sid(a.sid)
    st = handoff_status(sid, a.id)
    if not st:
        print("NOT_FOUND")
    elif a.json:
        print(json.dumps(st, ensure_ascii=False))
    else:
        print("%s %s" % (st["state"], st["winner"]) if st["winner"] else st["state"])
    return 0


def cmd_handoff_seen(a):
    sid = resolve_sid(a.sid)
    path = os.path.join(own_dir(sid), "handoffs_in.json")
    key = "%s|%s" % ((a.id or "").lower(), a.tag)
    with FileLock(path):
        d = read_json(path, {})
        if key in d:
            print("SEEN")
            return 0
        d[key] = iso()
        write_json(path, d)
    print("NEW")
    return 0


def cmd_source_mark(a):
    sid = resolve_sid(a.sid)
    s = (a.source or "").strip().lower()
    if s not in SOURCES:
        raise RoleError("SOURCE_INVALID %s (허용: %s)" % (a.source, "/".join(SOURCES)))
    for b in bases_for("both"):
        atomic_write(os.path.join(sess_dir(b, sid), "role_session_source"), s + "\n")
    print("SOURCE %s" % s)
    return 0


def cmd_turn(a):
    sid = resolve_sid(a.sid)
    pid = a.pid if a.pid is not None else find_claude_pid()
    cwd = a.cwd or os.getcwd()
    root = a.root or find_root(cwd)
    project = _ctx_project(a)
    out = []
    out += handoff_due_lines(sid)
    c = context_text(sid, current_role(sid), root)
    if c:
        out.append(c)
    t = do_announce_due(sid, pid, project, root)
    if t:
        out.append(t)
    else:
        r = do_announce_remind(sid)
        if r:
            out.append(r)
    if a.pane and a.tmux_session:
        w = do_register(sid, a.pane, a.tmux_session, pid, a.profile or os.environ.get("CLAUDE_PROFILE_NAME", ""),
                        cwd, a.topic or "", a.project, force=False)
        if w:
            out.append(w)
    if out:
        print("\n".join(out))
    return 0


def cmd_lint(a):
    p = os.path.join(a.root, ".claude", "role_paths.json")
    if not os.path.isfile(p):
        print("OK role_paths.json 없음")
        return 0
    try:
        with open(p, encoding="utf-8") as f:
            d = json.load(f)
    except (OSError, ValueError) as e:
        print("ERROR JSON 형식 오류: %s" % e)
        return 2
    errs, warns = [], []
    ids = role_ids()
    if not isinstance(d, dict):
        errs.append("최상위가 객체가 아님")
        d = {}
    sh = d.get("shared", [])
    if not isinstance(sh, list) or not all(isinstance(x, str) for x in sh):
        errs.append("shared 는 문자열 목록이어야 함")
    roles = d.get("roles", {})
    if not isinstance(roles, dict):
        errs.append("roles 는 객체여야 함")
        roles = {}
    for k, v in roles.items():
        if k not in ids:
            errs.append("roles 의 알 수 없는 롤 %s" % k)
        if not isinstance(v, list) or not all(isinstance(x, str) for x in v):
            errs.append("roles.%s 는 문자열 목록이어야 함" % k)
    areas = d.get("areas", {})
    if not isinstance(areas, dict):
        errs.append("areas 는 객체여야 함")
        areas = {}
    flat = []
    for k, lst in areas.items():
        if k not in ids or k == "all":
            errs.append("areas 의 허용되지 않는 롤 %s" % k)
        if not isinstance(lst, list):
            errs.append("areas.%s 는 목록이어야 함" % k)
            continue
        names = set()
        for a_ in lst:
            if not isinstance(a_, dict) or not isinstance(a_.get("name"), str) or not a_["name"].strip():
                errs.append("areas.%s 항목에 name 없음" % k)
                continue
            nm = a_["name"]
            if re.search(r"[\s:#|]", nm):
                errs.append("areas.%s 영역 이름 %r 에 공백·:·#·| 금지" % (k, nm))
            if nm.lower() in names:
                errs.append("areas.%s 영역 이름 중복 %s" % (k, nm))
            names.add(nm.lower())
            ps = a_.get("paths", [])
            if not isinstance(ps, list) or not all(isinstance(x, str) for x in ps):
                errs.append("areas.%s.%s paths 는 문자열 목록이어야 함" % (k, nm))
                continue
            flat.append(("%s:%s" % (k, nm), ps))
    for i in range(len(flat)):
        for j in range(i + 1, len(flat)):
            for p1 in flat[i][1]:
                for p2 in flat[j][1]:
                    l1, l2 = literal_prefix(p1), literal_prefix(p2)
                    if l1.startswith(l2) or l2.startswith(l1):
                        warns.append("WARN 경로 겹침 %s(%s) ~ %s(%s)" % (flat[i][0], p1, flat[j][0], p2))
    for e in errs:
        print("ERROR " + e)
    for w in warns:
        print(w)
    if errs:
        return 2
    if not warns:
        print("OK")
    return 0


def cmd_project_slug(a):
    print(project_slug(a.tmux_session, a.cwd))
    return 0


_PROJECT_NAME_RE = re.compile(r"^[A-Za-z0-9._-]+$")


def _is_wsl():
    """WSL 판정: WSL_DISTRO_NAME 환경변수 → 커널 문자열(/proc/version 의 microsoft) 순."""
    if os.environ.get("WSL_DISTRO_NAME"):
        return True
    try:
        with open("/proc/version", encoding="utf-8", errors="replace") as f:
            return "microsoft" in f.read().lower()
    except OSError:
        return False


def project_roots():
    """프로젝트 검색 루트: CLAUDE_PROJECT_ROOTS(콜론 구분, 앞 우선) → 기본 후보 중 존재하는 것만."""
    env = os.environ.get("CLAUDE_PROJECT_ROOTS", "")
    if env.strip():
        cands = [c for c in env.split(":") if c.strip()]
    else:
        cands = [os.path.join(os.path.expanduser("~"), "Project")]
        if _is_wsl():
            # Windows 쪽 프로젝트 폴더는 WSL 에서만 후보로 넣는다
            cands.append("/mnt/c/DATA/Project")
    out = []
    for c in cands:
        c = os.path.abspath(os.path.expanduser(c.strip()))
        if os.path.isdir(c) and c not in out:
            out.append(c)
    return out


def cmd_project_dir(a):
    # 프로젝트 이름 → 절대경로. 성공 rc=0, 없음 rc=1, 한 루트 안 대소문자 무시 모호 rc=2
    name = a.name
    if not _PROJECT_NAME_RE.fullmatch(name) or name in (".", ".."):
        sys.stderr.write(f"❌ 프로젝트 이름 형식이 아닙니다: {name}\n")
        return 1
    roots = project_roots()
    low = name.lower()
    # 루트마다 정확 일치 → 대소문자 무시 순으로 보고, 앞 루트에서 찾으면 뒤 루트는 보지 않는다.
    # 대소문자를 무시하는 파일시스템(NTFS /mnt/c)에서는 isdir 가 다른 대소문자에도 참이므로,
    # 일치 판정과 반환 경로는 항상 listdir 의 실제 항목명으로 한다.
    for root in roots:
        try:
            ents = sorted(os.listdir(root))
        except OSError:
            continue
        if name in ents and os.path.isdir(os.path.join(root, name)):
            print(os.path.join(root, name))
            return 0
        hits = [e for e in ents if e.lower() == low and os.path.isdir(os.path.join(root, e))]
        if len(hits) == 1:
            print(os.path.join(root, hits[0]))
            return 0
        if len(hits) > 1:
            sys.stderr.write(f"❌ 프로젝트 '{name}' 이 모호합니다 (대소문자만 다른 후보):\n")
            for h in hits:
                sys.stderr.write(f"  {os.path.join(root, h)}\n")
            return 2
    sys.stderr.write(f"❌ 프로젝트 '{name}' 을 찾을 수 없습니다 (검색 루트: {':'.join(roots) or '없음'})\n")
    return 1


# ───────────────────────── 인자 ─────────────────────────

def build_parser():
    import argparse  # 지연 import(기동 비용 절감)
    p = argparse.ArgumentParser(prog="role_lib.py", description="세션 롤 공용 CLI")
    sp = p.add_subparsers(dest="cmd", required=True)

    def add(name, fn, sid=True):
        q = sp.add_parser(name)
        q.set_defaults(fn=fn)
        if sid:
            q.add_argument("--sid")
        return q

    q = add("norm", cmd_norm, sid=False)
    q.add_argument("text", nargs="+")
    q.add_argument("--root")
    q = add("list", cmd_list, sid=False)
    q.add_argument("--json", action="store_true")
    q = add("get", cmd_get)
    q.add_argument("--raw", action="store_true")
    q.add_argument("--id-only", action="store_true")
    q = add("set", cmd_set)
    q.add_argument("text", nargs="+")
    q.add_argument("--source", choices=ROLE_SOURCES, default="cmd")
    q.add_argument("--base", choices=("home", "both"), default="both")
    for o in ("--root", "--project", "--cwd", "--profile", "--topic", "--pane", "--tmux-session"):
        q.add_argument(o)
    q.add_argument("--pid", type=int)
    q = add("agent", cmd_agent)
    q.add_argument("name", nargs="*")
    q.add_argument("--clear", action="store_true")
    q.add_argument("--source", choices=ROLE_SOURCES, default="cmd")
    q.add_argument("--base", choices=("home", "both"), default="both")
    for o in ("--root", "--project", "--cwd", "--profile", "--topic", "--pane", "--tmux-session"):
        q.add_argument(o)
    q.add_argument("--pid", type=int)
    q = add("dup-check", cmd_dup_check, sid=False)
    q.add_argument("text", nargs="+")
    for o in ("--root", "--project", "--cwd", "--exclude-key"):
        q.add_argument(o)
    q = add("name-check", cmd_name_check, sid=False)
    q.add_argument("name", nargs="+")
    q = add("context", cmd_context)
    q.add_argument("--root")
    q.add_argument("--cwd")
    q = add("ask-spec", cmd_ask_spec)
    q.add_argument("--root")
    q.add_argument("--cwd")
    q = add("register", cmd_register)
    q.add_argument("--pane", required=True)
    q.add_argument("--tmux-session", required=True)
    q.add_argument("--pid", type=int, required=True)
    for o in ("--profile", "--cwd", "--topic", "--project"):
        q.add_argument(o)
    for name, fn in (("announce-due", cmd_announce_due), ("announce-remind", cmd_announce_remind),
                     ("announce-done", cmd_announce_done)):
        q = add(name, fn)
        q.add_argument("--pid", type=int)
        for o in ("--root", "--cwd", "--project", "--tmux-session"):
            q.add_argument(o)
    q = add("find", cmd_find, sid=False)
    q.add_argument("--role", required=True)
    q.add_argument("--project")
    q = add("resume-list", cmd_resume_list, sid=False)
    q.add_argument("--project", required=True)
    q.add_argument("--role")
    q.add_argument("--profile")
    q.add_argument("--per-role", action="store_true")
    q.add_argument("--limit", type=int, default=9)
    q.add_argument("--json", action="store_true")
    q.add_argument("--preview", action="store_true")
    q = add("fork-adopt", cmd_fork_adopt, sid=False)
    q.add_argument("--project", required=True)
    q.add_argument("--parent", required=True)
    q.add_argument("--cwd", required=True)
    q.add_argument("--since", type=float, required=True)
    q.add_argument("--value")
    q.add_argument("--before")
    q = add("fork-snapshot", cmd_fork_snapshot, sid=False)
    q.add_argument("--cwd", required=True)
    q = add("ask-pages", cmd_ask_pages)
    q.add_argument("--current")
    q.add_argument("--json", action="store_true")
    q = add("menu-items", cmd_menu_items, sid=False)
    q.add_argument("--json", action="store_true")
    q = add("preview", cmd_preview, sid=False)
    q.add_argument("--sid")
    q.add_argument("--cwd")
    q.add_argument("--json", action="store_true")
    q = add("check-path", cmd_check_path)
    q.add_argument("--root", required=True)
    q.add_argument("path")
    q = add("peer-record", cmd_peer_record)
    q.add_argument("--from", dest="from_", required=True)
    q.add_argument("--from-name", default="")
    q.add_argument("--self-project", required=True)
    q.add_argument("--text", required=True)
    q = add("route", cmd_route)
    q.add_argument("--role", required=True)
    q.add_argument("--project", required=True)
    q.add_argument("--root")
    q.add_argument("--path", nargs="*", default=[])
    q.add_argument("--json", action="store_true")
    q = add("handoff-open", cmd_handoff_open)
    q.add_argument("--id")
    q.add_argument("--role", required=True)
    q.add_argument("--target", action="append")
    q.add_argument("--state", default="sent")
    q.add_argument("--deadline-min", type=float, default=10)
    q = add("handoff-update", cmd_handoff_update)
    q.add_argument("--id", required=True)
    q.add_argument("--state", required=True)
    q.add_argument("--winner")
    add("handoff-due", cmd_handoff_due)
    q = add("handoff-accept", cmd_handoff_accept)
    q.add_argument("--id", required=True)
    q.add_argument("--from", dest="from_", required=True)
    q.add_argument("--from-name", default="")
    q = add("handoff-status", cmd_handoff_status)
    q.add_argument("--id", required=True)
    q.add_argument("--json", action="store_true")
    q = add("handoff-seen", cmd_handoff_seen)
    q.add_argument("--id", required=True)
    q.add_argument("--tag", required=True)
    q = add("source-mark", cmd_source_mark)
    q.add_argument("--source", required=True)
    q = add("turn", cmd_turn)
    q.add_argument("--pid", type=int)
    for o in ("--pane", "--tmux-session", "--profile", "--cwd", "--topic", "--root", "--project"):
        q.add_argument(o)
    q = add("lint", cmd_lint, sid=False)
    q.add_argument("--root", required=True)
    q = add("project-slug", cmd_project_slug, sid=False)
    q.add_argument("--tmux-session")
    q.add_argument("--cwd")
    q = add("project-dir", cmd_project_dir, sid=False)
    q.add_argument("name")
    return p


class _FastNormArgs:
    """norm 빠른 경로용 인자 묶음(argparse 결과와 같은 속성만 가진다)."""
    cmd = "norm"
    root = None
    fn = staticmethod(cmd_norm)

    def __init__(self, text):
        self.text = [text]


def _fast_args(argv):
    # cc 가 가장 자주 부르는 `norm <값>` 이 정확히 이 형태일 때만 argparse 없이 처리한다.
    # 옵션처럼 보이는 값('-' 시작)·인자 개수가 다른 호출은 전부 기존 argparse 경로로 보낸다.
    if len(argv) == 2 and argv[0] == "norm" and not argv[1].startswith("-"):
        return _FastNormArgs(argv[1])
    return None


def main(argv=None):
    a = _fast_args(sys.argv[1:] if argv is None else list(argv))
    if a is None:
        p = build_parser()
        try:
            a = p.parse_args(argv)
        except SystemExit as e:
            return 2 if e.code not in (0, None) else 0
    try:
        return a.fn(a) or 0
    except NameRequired as e:
        sys.stderr.write(str(e) + "\n")
        return 3
    except RoleError as e:
        sys.stderr.write(str(e) + "\n")
        return 2


if __name__ == "__main__":
    sys.exit(main())
