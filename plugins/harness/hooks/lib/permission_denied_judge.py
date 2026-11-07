# auto 모드 안전분류기가 거부한 도구 호출을 특별 작업/일반 작업으로 판정해 안내를 내는 PermissionDenied 판정기
#
# 공식 문서 근거 (https://code.claude.com/docs/en/hooks, 2026-10-25 odev-9 직접 확인)
#   - 입력: 공통 필드(session_id·transcript_path·cwd·permission_mode·hook_event_name 등) + tool_name·tool_input·tool_use_id·reason
#           (MCP 도구면 mcp_server 객체 추가)
#   - 출력: 이 이벤트가 문서화한 전용 필드는 hookSpecificOutput.retry 뿐이다. retry:true 는 "재시도해도 된다" 신호이므로
#           재시도 금지 정책과 반대라 ★쓰지 않는다★. additionalContext 는 이 이벤트의 지원 목록에 없다(모델 전달 경로 없음).
#   - systemMessage(공통 필드)는 "Warning message shown to the user" — 사용자에게만 보인다. 특별 작업 첫 거부 때만 낸다.
#   - 종료 코드·stderr 는 무시된다("the denial already occurred"). 이 판정기는 항상 rc 0 으로 끝난다.
#   ⇒ PermissionDenied 자체에는 모델에게 안내를 전달하는 공식 필드가 없다. 그래서 중계한다.
#     이 판정기가 거부한 에이전트 자신의 session-env/<session_id>/logs/pd_relay.json 에 1회성 표식을 남기면,
#     PreToolUse_permission_denied_relay.sh 가 다음 도구 호출 때 hookSpecificOutput.additionalContext
#     (PreToolUse 문서: "String added to Claude's context alongside the tool result")로 1회 전달하고 표식을 소비한다.
#     표식이 없거나 세션 디렉터리가 없으면 중계하지 않는다(새 세션 디렉터리를 만들지 않는다).
#
# 시험 전용 환경변수(PD_TEST=1 이 함께 있을 때만 인정, 운영에서는 무시):
#   PD_STATE_DIR(로그·반복 억제·중계 표식 위치 — 실재하는 /tmp·/var/tmp 아래만), PD_ROLE(main|auto|teammate)
# 중계 모드: permission_denied_judge.py --relay <소비할 표식 사본 경로> → PreToolUse JSON 출력 후 사본 삭제
import hashlib
import json
import os
import re
import sys
import time

CFG = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
REPEAT_SEC = 600
UUID_RX = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
SHELL_TOOLS = ("Bash", "PowerShell", "mcp__oio__bash_exec", "Monitor")

# ── 특별 작업 5종 판정 규칙 (명령 본문 기준 — 분류기 reason 은 기록만 하고 판정에 쓰지 않는다) ──
R_DEPLOY = re.compile(
    r"(deploy\w*\.(sh|ps1|py)|deployPlayStore|\bkubectl\s+(apply|delete|rollout|scale)\b|\bterraform\s+(apply|destroy)\b"
    r"|\bhelm\s+(install|upgrade|uninstall)\b|\b(prod|production)\b[^|;&]*\b(deploy|release|migrat\w*)\b"
    r"|\bdeploy\b[^|;&]*\b(prod|production)\b)", re.I)
R_DESTROY = re.compile(
    r"(\b(DROP|TRUNCATE)\s+(TABLE|DATABASE|SCHEMA)\b|\bDELETE\s+FROM\b(?![^;]*\bWHERE\b)"
    r"|\bgit\b[^|;&]*\breset\s+--hard\b|\bgit\b[^|;&]*\bclean\s+-[a-zA-Z]*f|\bgit\b[^|;&]*\bpush\b[^|;&]*(\s-f\b|--force)"
    r"|\bgit\b[^|;&]*\bbranch\s+-D\b|\bgit\b[^|;&]*\bstash\s+(drop|clear)\b|\bmkfs\b|\bdd\b[^|;&]*\bof=/dev/|\bshred\b"
    r"|\bfind\b[^|;&]*\s-delete\b|\bgit\b[^|;&]*\bcheckout\s+(\S+\s+)?--(\s|$)|\bgit\b[^|;&]*\brestore\b"
    r"|\bALTER\s+TABLE\b[^;]*\bDROP\b"
    r"|\bmysql\b[^|;&]*\s-e\s*[\"']?\s*(UPDATE|INSERT|DELETE|ALTER|DROP|TRUNCATE|REPLACE|CREATE|RENAME|GRANT|REVOKE)\b)", re.I)
# mcp__mysql__execute 는 아래 읽기 전용 문 외에는 DB 변경으로 본다(되돌리기 어려운 파괴)
R_SQL_READONLY = re.compile(r"^\s*(SELECT|SHOW|EXPLAIN|DESCRIBE|DESC|SET\s+NAMES|USE)\b", re.I)
R_CRED = re.compile(
    r"(\.ssh/|\bid_rsa\b|\bid_ed25519\b|authorized_keys|\.git-credentials|\.netrc\b|\.aws/credentials|credentials?\.json"
    r"|\bgh\s+auth\b|\bgit\s+config\b[^|;&]*credential|\b(chmod|chown|chgrp|setfacl|usermod|passwd|visudo|sudo)\b)", re.I)
R_SETTINGS_PERM = re.compile(r"settings(\.local)?\.json", re.I)
R_PERM_KEYS = re.compile(r"\b(permissions|defaultMode|autoMode|disableAutoMode|allow|deny)\b")
R_EXTERNAL = re.compile(
    r"(\bgit\b[^|;&]*\bpush\b|\bgh\s+(release|gist|pr\s+create|repo\s+create)\b"
    r"|(?-i:\bcurl\b[^|;&]*(\s-X\s*(POST|PUT|PATCH|DELETE)\b|\s--request[\s=]*(POST|PUT|PATCH|DELETE)\b"
    r"|\s-[dFT]\S*|\s(--data\S*|--form\S*|--upload-file|--json)(\s|=)))"
    r"|(?-i:\bgh\s+api\b[^|;&]*(\s-X\s*(POST|PUT|PATCH|DELETE)\b|--method[\s=]*(POST|PUT|PATCH|DELETE)\b|\s-[fF]\s|--field|--raw-field|--input))"
    r"|\bwget\b[^|;&]*(--post|--method[\s=]*(POST|PUT|PATCH|DELETE)\b)|\bscp\b|\bsftp\b|\brsync\b[^|;&]*\s[\w.@-]+:\S*|\b(npm|yarn|pnpm)\s+publish\b"
    r"|\btwine\s+upload\b|\bdocker\s+push\b|ntfy_send)", re.I)
R_OTHER_HOME = re.compile(r"(/home/(?!rioky\b)[A-Za-z0-9_.-]+|(^|[\s'\"=])/root(/|\b)|/mnt/c/Users/(?!rioky\b)[A-Za-z0-9_.-]+/)")
R_KILL_OTHERS = re.compile(r"\b(pkill|killall)\b")
R_SESSION_ENV = re.compile(r"session-env/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})")
TEMP_PREFIX = ("/tmp/", "/var/tmp/")

# ── 일반 작업 대안 안내 규칙 ──
R_INPLACE = re.compile(r"(\bsed\b[^|;&]*\s-i|\bperl\b[^|;&]*\s-[a-z]*i|\btee\b|(^|[^0-9&>])>{1,2}\s*[^&\s/][^\s]*|(^|[^0-9&>])>{1,2}\s*/(?!dev/null))")
R_INTERP = re.compile(r"(\b(python3?|node|ruby|perl|php)\s+(-I\s+)?-[ce]\b|\bbash\s+-c\b|\bsh\s+-c\b|\beval\b|\$\(|`)")
R_BROAD = re.compile(r"(\bfind\s+/(\s|$)|\bfind\s+/mnt\b|\bfind\s+~|\bgrep\s+-r[^|;&]*\s/(\s|$)|\s/\*|\*\*/|\bxargs\b|-exec\b)")
R_DOWNLOAD_EXEC = re.compile(r"\b(curl|wget)\b[^|]*\|\s*(ba|z)?sh\b")
R_RM = re.compile(r"\brm\b")


def _read(path, limit=4096):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read(limit).strip()
    except OSError:
        return ""


def _ancestor_ids():
    """조상 프로세스 argv 에서 --agent-id·--parent-session-id 를 찾는다. 반환: (agent_id|None, parent_uuid|None)."""
    pid = os.getppid()
    seen = set()
    for _ in range(16):
        if pid <= 1 or pid in seen:
            break
        seen.add(pid)
        try:
            with open("/proc/%d/cmdline" % pid, "rb") as f:
                tok = f.read().decode("utf-8", "replace").split("\0")
        except OSError:
            break
        aid = psid = None
        for i in range(len(tok) - 1):
            if tok[i] == "--agent-id":
                aid = tok[i + 1]
            elif tok[i] == "--parent-session-id":
                psid = tok[i + 1]
        if aid or psid:
            return aid, (psid if psid and UUID_RX.fullmatch(psid) else None)
        try:
            with open("/proc/%d/stat" % pid) as f:
                pid = int(f.read().rsplit(")", 1)[1].split()[1])
        except (OSError, ValueError, IndexError):
            break
    return None, None


def test_state_dir():
    """시험 전용 PD_STATE_DIR — PD_TEST=1 이 함께 있고 실재하는 /tmp·/var/tmp 아래 디렉터리일 때만 받는다(운영에서는 무시)."""
    if os.environ.get("PD_TEST") != "1":
        return ""
    st = os.environ.get("PD_STATE_DIR") or ""
    if not (st and os.path.isabs(st) and os.path.isdir(st)):
        return ""
    real = os.path.realpath(st)
    return real if (real + "/").startswith(TEMP_PREFIX) else ""


def _ts(item):
    try:
        return float(item.get("ts", 0))
    except (TypeError, ValueError):
        return 0.0


def resolve_context(inp):
    """파이프라인 UUID·역할(main|auto|teammate)·자기 세션 기록 위치를 정한다."""
    aid, psid = _ancestor_ids()
    env_pu = os.environ.get("PIPELINE_UUID", "")
    sid = str(inp.get("session_id") or "")
    uuid = psid or (env_pu if UUID_RX.fullmatch(env_pu) else "") or (sid if UUID_RX.fullmatch(sid) else "")
    teammate = bool(aid or psid or env_pu)
    sdir = os.path.join(CFG, "session-env", uuid) if uuid else ""
    auto = bool(sdir) and _read(os.path.join(sdir, "auto"), 16).upper() == "ON"
    role = "teammate" if teammate else ("auto" if auto else "main")
    if os.environ.get("PD_TEST") == "1" and os.environ.get("PD_ROLE") in ("main", "auto", "teammate"):
        role = os.environ["PD_ROLE"]
    state = test_state_dir()
    if not state:
        # 세션 격리: 자기 세션 디렉터리가 실재할 때만 그 아래에 쓴다(없는 세션 디렉터리를 새로 만들지 않는다)
        state = sdir if sdir and os.path.isdir(sdir) else ""
    return uuid, role, state


def tool_text(tool, ti):
    if not isinstance(ti, dict):
        return str(ti)
    if tool in SHELL_TOOLS:
        return str(ti.get("command") or ti.get("cmd") or "")
    return json.dumps(ti, ensure_ascii=False)


def _is_temp(p):
    """임시 경로 판정 — realpath -m 과 같이 정규화(심볼릭 링크·.. 해소, 부재 허용) 후 비교한다."""
    if not p or not p.startswith("/"):
        return False
    return (os.path.realpath(p) + "/").startswith(TEMP_PREFIX)


def _segments(cmd):
    for seg in re.split(r"[;&|\n]+", cmd):
        toks = seg.split()
        while toks and toks[0] in ("sudo", "command", "nice", "nohup", "env", "exec"):
            toks = toks[1:]
        if toks:
            yield toks


def _rm_nontemp(cmd):
    """rm 대상 중 임시 경로가 아닌 것이 하나라도 있으면 True(정규화 후 비교)."""
    for toks in _segments(cmd):
        if toks[0] not in ("rm", "/bin/rm", "/usr/bin/rm"):
            continue
        targets = [t.strip("'\"") for t in toks[1:] if not t.startswith("-")]
        if not targets or any(not _is_temp(t) for t in targets):
            return True
    return False


SSH_ARG_OPTS = set("pilFoJLRDEbcmOSWwBIQe")


def _ssh_remote(cmd):
    """ssh <host> [명령] — 원격 서버 접근·실행이면 True."""
    for toks in _segments(cmd):
        if toks[0] not in ("ssh", "/usr/bin/ssh"):
            continue
        i = 1
        while i < len(toks) and toks[i].startswith("-"):
            opt = toks[i]
            i += 2 if (len(opt) == 2 and opt[1] in SSH_ARG_OPTS) else 1
        if i < len(toks):
            return True
    return False


def classify(tool, ti, own_uuid):
    """반환: (kind, category) — kind 는 special|general."""
    text = tool_text(tool, ti)
    if R_DEPLOY.search(text):
        return "special", "운영 배포"
    if R_DESTROY.search(text) or (tool in SHELL_TOOLS and _rm_nontemp(text)):
        return "special", "되돌리기 어려운 파괴"
    if tool in ("mcp__oio__dir_delete", "mcp__oio__file_delete"):
        t = ti if isinstance(ti, dict) else {}
        p = str(t.get("path") or t.get("file_path") or t.get("filepath") or "")
        if not _is_temp(p):
            return "special", "되돌리기 어려운 파괴"
    if tool.startswith("mcp__mysql__") and tool.endswith("execute"):
        t = ti if isinstance(ti, dict) else {}
        sql = str(t.get("query") or t.get("sql") or t.get("statement") or text)
        if not R_SQL_READONLY.match(sql):
            return "special", "되돌리기 어려운 파괴"
    if tool in SHELL_TOOLS and _ssh_remote(text):
        return "special", "타 세션·타 사용자 자원"
    if R_CRED.search(text) or (R_SETTINGS_PERM.search(text) and R_PERM_KEYS.search(text)):
        return "special", "자격증명·권한 변경"
    for m in R_SESSION_ENV.finditer(text):
        if m.group(1) != own_uuid:
            return "special", "타 세션·타 사용자 자원"
    if R_OTHER_HOME.search(text) or R_KILL_OTHERS.search(text):
        return "special", "타 세션·타 사용자 자원"
    if R_EXTERNAL.search(text):
        return "special", "외부 공개·전송"
    return "general", ""


GENERAL_PREFACE = ("① 이 동작이 꼭 필요한지 거부 사유와 함께 다시 검토한다. "
                   "② 같은 동작을 다른 형태(스크립트로 감싸기·도구 바꾸기·표현 바꾸기)로 재시도하는 것은 금지다(L-597). "
                   "③ 정당한 작업이면 그 작업에 맞는 공식 도구·절차로 진행하고, 그래도 막히면 team-lead/메인에 보고한다")


def general_hint(tool, ti):
    text = tool_text(tool, ti)
    hints = []
    if tool in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
        hints.append("작업 디렉터리 안의 대상 파일이면 mcp__oio__file_edit / file_write 로 그 파일 1개만 고친다(디렉터리 밖·보호 파일이면 보고)")
    if tool in SHELL_TOOLS:
        if R_DOWNLOAD_EXEC.search(text):
            hints.append("내려받은 코드를 바로 실행하지 않는다 — 필요한 파일만 받아 내용을 읽고 판단한다")
        if R_INPLACE.search(text):
            hints.append("셸 리다이렉션·sed -i·tee 대신, 작업 디렉터리 안의 대상 파일 1개만 mcp__oio__file_edit / file_write 로 고친다(밖이면 보고)")
        if R_INTERP.search(text):
            hints.append("해석기 한 줄 프로그램(python -c·bash -c·eval·명령 치환)은 목적이 드러나는 좁은 단계로 나눈다 — 조회는 oio file_read/search, 쓰기는 대상 1개씩")
        if R_BROAD.search(text):
            hints.append("넓은 탐색(find /·-exec·xargs·넓은 와일드카드) 대신 mcp__oio__find / mcp__oio__search 로 프로젝트 하위 구체 경로만 본다")
        if R_RM.search(text):
            hints.append("삭제는 이번 세션에서 만든 임시 파일인지 확인한 뒤 대상 1개씩 한다")
    if not hints:
        hints.append("좁고 명확한 단일 목적 명령으로 나누고, 조회는 mcp__oio__file_read / search, 보호 파일은 promote 경로를 쓴다")
    return GENERAL_PREFACE + ". 공식 도구·절차 예: " + "; ".join(hints)


def call_sha1(tool, ti):
    norm = dict(ti) if isinstance(ti, dict) else {"_": ti}
    norm.pop("description", None)
    raw = tool + "\0" + json.dumps(norm, sort_keys=True, ensure_ascii=False)
    return hashlib.sha1(raw.encode("utf-8", "replace")).hexdigest()


def seen_recently(logp, sha, now):
    try:
        with open(logp, encoding="utf-8", errors="replace") as f:
            lines = f.readlines()[-500:]
    except OSError:
        return False
    for ln in reversed(lines):
        parts = ln.rstrip("\n").split("\t")
        if len(parts) >= 4 and parts[3] == sha:
            try:
                return now - float(parts[0]) < REPEAT_SEC
            except ValueError:
                continue
    return False


RELAY_NAME = "pd_relay.json"
RELAY_TTL = 1800
RELAY_MAX = 5


def relay_path(inp):
    """중계 표식 위치: PD_STATE_DIR 또는 거부당한 에이전트 자신의 session-env/<session_id>/logs (실재할 때만)."""
    st = test_state_dir()
    if st:
        return os.path.join(st, "logs", RELAY_NAME)
    sid = str(inp.get("session_id") or "")
    if not UUID_RX.fullmatch(sid):
        return ""
    sd = os.path.join(CFG, "session-env", sid)
    return os.path.join(sd, "logs", RELAY_NAME) if os.path.isdir(sd) else ""


def write_relay(path, now, label, msg):
    if not path:
        return
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        items = []
        try:
            with open(path, encoding="utf-8") as f:
                items = json.load(f).get("items", [])
        except (OSError, ValueError, AttributeError):
            items = []
        if not isinstance(items, list):
            items = []
        items = [i for i in items if isinstance(i, dict) and now - _ts(i) < RELAY_TTL]
        items.append({"ts": now, "label": label, "msg": msg})
        tmp = "%s.w%d" % (path, os.getpid())
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"items": items[-RELAY_MAX:]}, f, ensure_ascii=False)
        os.replace(tmp, path)
    except (OSError, ValueError):
        pass


def relay_emit(copy_path):
    """PreToolUse 중계: 소비한 표식 사본을 읽어 additionalContext 로 1회 전달하고 사본을 지운다."""
    try:
        with open(copy_path, encoding="utf-8") as f:
            items = json.load(f).get("items", [])
    except (OSError, ValueError, AttributeError):
        items = []
    try:
        os.remove(copy_path)
    except OSError:
        pass
    now = time.time()
    # 예산 초과로 죽은 이전 실행이 남긴 소비 사본(.c<pid>)·쓰기 임시본(.w<pid>)을 10분 지나면 정리한다
    base = re.sub(r"\.c\d+$", "", copy_path)
    try:
        d, b = os.path.split(base)
        for n in os.listdir(d):
            if re.fullmatch(re.escape(b) + r"\.[cw]\d+", n):
                p = os.path.join(d, n)
                try:
                    if now - os.path.getmtime(p) > 600:
                        os.remove(p)
                except OSError:
                    pass
    except OSError:
        pass
    if not isinstance(items, list):
        items = []
    msgs = [str(i.get("msg", "")) for i in items if isinstance(i, dict) and now - _ts(i) < RELAY_TTL]
    msgs = [m for m in msgs if m]
    if not msgs:
        return 0
    ctx = "[PermissionDenied 중계] 직전에 auto 모드 안전분류기가 도구 호출을 거부했다. " + " / ".join(msgs[-RELAY_MAX:])
    sys.stdout.write(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": ctx}},
                                ensure_ascii=False) + "\n")
    return 0


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "--relay":
        return relay_emit(sys.argv[2])
    try:
        inp = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        inp = {}
    if not isinstance(inp, dict):
        inp = {}
    tool = str(inp.get("tool_name") or "")
    ti = inp.get("tool_input") or {}
    reason = str(inp.get("reason") or "")
    uuid, role, state = resolve_context(inp)
    kind, cat = classify(tool, ti, uuid)
    sha = call_sha1(tool, ti)
    now = time.time()
    logp = os.path.join(state, "logs", "permission_denied.log") if state else ""
    repeat = bool(logp) and seen_recently(logp, sha, now)

    out_json = None
    if kind == "special" and not repeat:
        if role == "main":
            how = "사용자 화면 메인 세션이므로 AskUserQuestion 으로 실행 여부를 한 번 묻는다"
        else:
            how = ("/oto 자율 세션" if role == "auto" else "팀원") + "이므로 묻지 말고 보류 목록에 남겨 최종 보고한다"
        msg = ("[안전분류기 거부·특별 작업(%s)] 사용자 확인 필요 — %s. 같은 명령 재시도 금지." % (cat, how))
        out_json = {"systemMessage": msg}
        line = msg
        label = "special"
    elif kind == "special":
        line = ("[안전분류기 거부·특별 작업(%s)·반복] 10분 안에 같은 호출이 다시 거부됨 — 이미 확인 요청한 호출이므로 다시 묻지 말 것. "
                "같은 명령 재시도 금지, 보류로 남긴다." % cat)
        label = "special_repeat"
    else:
        line = ("[안전분류기 거부·일반 작업] 방법이 잘못됐을 수 있다. 같은 명령 재시도 금지. 올바른 대안: %s." % general_hint(tool, ti))
        label = "general_repeat" if repeat else "general"
    if reason:
        line += " (분류기 사유: %s)" % re.sub(r"\s+", " ", reason)[:120]

    if logp:
        try:
            os.makedirs(os.path.dirname(logp), exist_ok=True)
            with open(logp, "a", encoding="utf-8") as f:
                f.write("%.3f\t%s\t%s\t%s\t%s\t%s\t%s\n" % (
                    now, time.strftime("%Y-%m-%dT%H:%M:%S%z"), label, sha, tool[:60],
                    re.sub(r"[\t\n]", " ", reason)[:80], role))
        except OSError:
            pass

    # 모델 전달용 1회성 중계 표식(다음 도구 호출의 PreToolUse 가 additionalContext 로 전달)
    write_relay(relay_path(inp), now, label, line)

    # retry 는 내지 않는다(재시도 금지 정책). 특별 작업 첫 거부만 JSON systemMessage(사용자 경고), 나머지는 일반 텍스트(디버그 로그).
    sys.stdout.write((json.dumps(out_json, ensure_ascii=False) if out_json else line) + "\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # 판정기 오류가 세션을 막지 않게 한다(이벤트 자체가 사후 통지)
        if "--relay" not in sys.argv[1:2]:  # 중계 모드는 PreToolUse stdout 이라 비 JSON 문구를 내지 않는다
            sys.stdout.write("[PermissionDenied 판정기 오류] %s\n" % type(e).__name__)
        sys.exit(0)
