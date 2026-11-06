#!/usr/bin/env bash
# F-RESULT-SCHEMA — 팀원 결과 파일(session-env/<UUID>/work/*_result.json)의 conv_id·status 스키마를 강제하는 guard
#
# 등록: PreToolUse matcher mcp__oio__file_write (쓰기 전 content 검사 → 위반 시 차단)
#       PostToolUse matcher mcp__oio__file_edit (수정 후 디스크 파일 검사 → 위반 시 수정 요구 피드백)
# 근거: L-650 정정(사이클197) — 결과 파일 소실의 실제 원인은 base 경로가 아니라 스키마 이탈이었다.
#       conv_id 누락 또는 최상위 status="done" 이면 resume_restore.build_plan 이 완료 팀원을 missing 으로 판정한다.
# 원칙: 자기 오류(python 부재·입력 파싱 실패)는 fail-open(exit 0). 쓰기는 자기 세션 logs/ 에만 한다.

_RJG_IN="$(cat 2>/dev/null)"

# 비용 최소화 — 입력에 _result.json 이 없으면 python 실행 전에 통과
case "$_RJG_IN" in
  *_result.json*) ;;
  *) exit 0 ;;
esac

command -v python3 >/dev/null 2>&1 || exit 0

_RJG_PY="$(cat <<'PY'
import json, os, re, sys, time

MAX_BYTES = 1024 * 1024
PATH_RE = re.compile(r"/session-env/([0-9a-f-]{36})/work/([^/]+_result\.json)$")
CONV_RE = re.compile(r"^conv_[0-9]+$")
STATUS_OK = ("partial", "completed", "failed", "in_progress", "blocked")
SID_RE = re.compile(r"^[0-9A-Za-z-]{8,64}$")


def log_line(sid, verdict, evt, fname, why):
    # 자기 세션 logs/ 가 이미 있을 때만 1행 기록 (세션 격리 — 디렉터리 생성 금지)
    try:
        if not sid or not SID_RE.match(sid):
            return
        base = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
        logs = os.path.join(base, "session-env", sid, "logs")
        if not os.path.isdir(logs):
            return
        ts = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        why = str(why).replace("\n", " ")[:200]
        with open(os.path.join(logs, "result_json_guard.log"), "a", encoding="utf-8") as f:
            f.write("%s %s evt=%s file=%s why=%s\n" % (ts, verdict, evt, fname, why))
    except Exception:
        pass


def check(text):
    """위반 사유 문자열을 돌려준다. 정상이면 None, 정상일 때 conv_id 도 함께 돌려준다."""
    try:
        obj = json.loads(text)
    except Exception:
        return "JSON 으로 파싱되지 않음", None
    if not isinstance(obj, dict):
        return "최상위가 JSON 객체가 아님", None
    conv = obj.get("conv_id")
    if conv is None:
        return "conv_id 필드 없음", None
    if not isinstance(conv, str) or not CONV_RE.match(conv):
        return "conv_id 형식 불일치(%r)" % (conv,), None
    st = obj.get("status")
    if st not in STATUS_OK:
        return "최상위 status=%r 는 허용 집합 밖" % (st,), conv
    return None, conv


def main():
    try:
        data = json.loads(sys.stdin.read())
    except Exception:
        return 0
    if not isinstance(data, dict):
        return 0
    evt = data.get("hook_event_name") or ""
    tool = data.get("tool_name") or ""
    ti = data.get("tool_input") or {}
    if not isinstance(ti, dict):
        return 0
    sid = data.get("session_id") or ""
    path = ti.get("path") or ti.get("file_path") or ti.get("filepath") or ""
    if not isinstance(path, str):
        return 0
    m = PATH_RE.search(path)
    if not m:
        return 0
    fname = m.group(2)

    if evt == "PreToolUse" and tool == "mcp__oio__file_write":
        text = None
        for k in ("content", "body", "data", "text", "new_content", "new_text"):
            v = ti.get(k)
            if isinstance(v, str):
                text = v
                break
        if text is None:
            return 0
    elif evt == "PostToolUse" and tool == "mcp__oio__file_edit":
        try:
            if os.path.getsize(path) > MAX_BYTES:
                log_line(sid, "WARN", evt, fname, "1MB 초과 — 검사 생략(fail-open)")
                return 0
            with open(path, "r", encoding="utf-8-sig") as f:
                text = f.read()
        except Exception:
            return 0
    else:
        return 0

    if len(text.encode("utf-8", "ignore")) > MAX_BYTES:
        log_line(sid, "WARN", evt, fname, "1MB 초과 — 검사 생략(fail-open)")
        return 0

    why, conv = check(text)
    if why:
        sys.stderr.write(
            "⛔ [F-RESULT-SCHEMA] work/%s 스키마 위반 — %s. "
            "필수: \"conv_id\":\"conv_<숫자>\"(현재 대화ID), 최상위 \"status\" 는 "
            "partial|completed|failed|in_progress|blocked (\"done\" 금지 → completed). "
            "근거 L-650 정정(사이클197): conv_id 누락·status=done 이면 /oresume 이 "
            "완료 팀원을 missing 으로 판정한다.\n" % (fname, why)
        )
        log_line(sid, "BLOCK", evt, fname, why)
        return 2

    # conv_id 불일치 — 차단하지 않고 안내만 (프롬프트 주입값 우선 규칙)
    sess_dir = path[: path.rfind("/work/")]
    cur = None
    try:
        with open(os.path.join(sess_dir, "conv_id"), "r", encoding="utf-8") as f:
            cur = f.read().strip()
    except Exception:
        cur = None
    if cur and CONV_RE.match(cur) and cur != conv:
        # 같은 세션·conv 쌍은 1회만 경고 — 표식은 대상 sess_dir/logs/ 하위, logs/ 가 없으면 만들지 않고 매번 경고
        mark = os.path.join(sess_dir, "logs", ".conv_mismatch_warned_%s_%s" % (cur, conv))
        if os.path.isdir(os.path.dirname(mark)):
            if os.path.exists(mark):
                log_line(sid, "WARN", evt, fname, "conv_id 불일치 %s≠%s (중복 경고 생략)" % (conv, cur))
                return 0
            try:
                open(mark, "a").close()
            except Exception:
                pass
        msg = ("[F-RESULT-SCHEMA] work/%s 의 conv_id=%s 가 세션 conv_id 파일 값 %s 와 다릅니다. "
               "프롬프트로 주입된 현재 대화ID 가 맞는지 확인하세요(차단하지 않음)." % (fname, conv, cur))
        sys.stdout.write(json.dumps({"hookSpecificOutput": {"hookEventName": evt, "additionalContext": msg}},
                                    ensure_ascii=False) + "\n")
        log_line(sid, "WARN", evt, fname, "conv_id 불일치 %s≠%s" % (conv, cur))
        return 0

    log_line(sid, "PASS", evt, fname, "ok")
    return 0


try:
    rc = main()
except Exception:
    rc = 0
sys.exit(rc)
PY
)"

printf '%s' "$_RJG_IN" | python3 -c "$_RJG_PY"
_RJG_RC=$?
[ "$_RJG_RC" = 2 ] && exit 2
exit 0
