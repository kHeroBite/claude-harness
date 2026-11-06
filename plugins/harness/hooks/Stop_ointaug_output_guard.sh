#!/bin/bash
# ointaug 호출 뒤 화면 텍스트에 필수 항목 라벨이 없으면 턴 종료를 막는 Stop hook (F-INTAUG-4)
#
# 배경: 2026-09-13 축소 사고 뒤 문서 절과 F-INTAUG-2(마커 검사)를 넣었지만, 10월 이후 출력 약 193건에서
#   사용자 의도·확장 키워드가 거의 0건이었다. 마커는 화면을 증명하지 못한다. 이 hook 은 마커를 보지 않고
#   transcript 와 last_assistant_message 의 어시스턴트 텍스트만 대조한다.
#
# 공식 근거: https://code.claude.com/docs/en/hooks.md "Stop input"·"Stop decision control".
#   last_assistant_message 는 최종 응답 텍스트이고, transcript 는 Stop 시점에 마지막 메시지를 포함한다는 보장이 없다.
#   그래서 두 곳을 합쳐 대조한다.
#
# 판정 대상: 마지막 Skill(ointaug) 호출 1건. 그 호출을 연 입력 뒤 같은 턴의 어시스턴트 텍스트(호출 앞·뒤)에 필수 라벨이 모두 있어야 한다.
#   호출 앞 텍스트(L-1461): 형식 블록을 호출 앞이나 연속 호출 사이에 놓아도 화면에는 있으므로 인정한다. 이전 턴 텍스트는 보지 않는다.
# 통과: 팀에이전트(agent_id·PIPELINE_UUID·부모 체인) / 호출 없음 / 호출 뒤 새 턴이 열림 /
#   /ox·팀원 메시지·시스템 알림·타 세션 통지로 열린 턴 / compact 경계 / 파싱 실패·입력 이상(fail-open, 로그만).
# 교착 방지: tool_use_id 서명별 2회 차단 뒤 3회차 통과. 통과한 서명은 ointaug_output_escaped 에 남겨 다시 막지 않는다.
#   stop_hook_active 로 바로 통과시키지 않는다. 그렇게 하면 차단 직후 보강 없이 끝내도 통과하기 때문이다.
#   이 서명 상한과 공식 8회 연속 상한이 무한 차단을 막는다.
# 비상 스위치 없음: 에이전트가 만들 수 있는 파일은 우회로가 된다. 과차단이면 2회 뒤 탈출한다.
# 한계: 라벨 존재만 본다. 값의 품질은 판정하지 못한다. 연속 호출의 앞선 호출 누락은 잡지 못한다. 3회차 탈출구가 있다.

set -u

command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

INPUT="$(cat 2>/dev/null)" || exit 0
[[ -z "$INPUT" ]] && exit 0

if ! printf '%s' "$INPUT" | jq -e 'type == "object"' >/dev/null 2>&1; then
    _LOGD="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/logs"
    mkdir -p "$_LOGD" 2>/dev/null
    printf '%s BAD_STDIN\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" >> "${_LOGD}/ointaug_output_guard.log" 2>/dev/null
    exit 0
fi

AID="$(printf '%s' "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null)" || exit 0
[[ -n "$AID" ]] && exit 0
UUID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)" || exit 0
[[ "$UUID" =~ ^[0-9A-Za-z-]+$ ]] || exit 0
if [[ -n "${PIPELINE_UUID:-}" && "${PIPELINE_UUID}" != "$UUID" ]]; then
    exit 0
fi
if source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/chain_agent.sh" 2>/dev/null && chain_agent_resolve 2>/dev/null; then
    exit 0
fi

# 자기 세션 디렉터리에만 쓴다. 없으면 서명 카운터를 둘 곳이 없으므로 통과한다.
SD=""
for _d in "${CLAUDE_CONFIG_DIR:-}/session-env/${UUID}" "${HOME}/.claude/session-env/${UUID}"; do
    [[ -d "$_d" ]] || continue
    [[ -z "$SD" ]] && SD="$_d"
    if [[ -f "${_d}/state" ]]; then SD="$_d"; break; fi
done
[[ -z "$SD" ]] && exit 0

# [F-OTEAM] 텍스트로만 답하고 끝내는 경로를 막는다. 인자 없는 호출은 취소가 정상 종료이므로 막지 않고 표식만 지운다.
#   이 판정은 Skill 호출 전에 끝낸 턴도 잡는다. 2회 뒤 통과는 위 F-INTAUG-4 와 같은 교착 방지다.
if [[ -f "$SD/oteam_required" && ! -f "$SD/oteam_spawned" ]]; then
    if [[ "$(head -c 5 "$SD/oteam_required" 2>/dev/null)" == "noarg" ]]; then
        rm -f "$SD/oteam_required" "$SD/oteam_stop_count" 2>/dev/null
    else
        _OT_N="$(head -c 4 "$SD/oteam_stop_count" 2>/dev/null)"
        [[ "$_OT_N" =~ ^[0-9]+$ ]] || _OT_N=0
        if (( _OT_N >= 2 )); then
            rm -f "$SD/oteam_required" "$SD/oteam_stop_count" 2>/dev/null
            mkdir -p "$SD/logs" 2>/dev/null
            printf '%s ESCAPE sid=%s\n' "$(date -Iseconds)" "$UUID" >> "$SD/logs/oteam_gate.log" 2>/dev/null
        else
            printf '%s' "$((_OT_N + 1))" > "$SD/oteam_stop_count" 2>/dev/null
            jq -cn --arg r "⛔ [F-OTEAM] /oteam 요구사항이 팀에이전트에 넘어가지 않았다($((_OT_N + 1))/2). Skill('oteam') 절차대로 Agent 를 호출하라. 막혔다면 차단 문구를 사용자에게 보고하고 끝내라. 메인이 직접 처리하지 않는다." '{decision:"block",reason:$r}'
            exit 2
        fi
    fi
fi

PY_SRC="$(cat <<'PYEOF'
import collections, json, os, re, sys, time

SD = sys.argv[1]
LOG = os.path.join(SD, "logs", "ointaug_output_guard.log")
COUNT = os.path.join(SD, "ointaug_output_block_count")
ESCAPED = os.path.join(SD, "ointaug_output_escaped")
TAIL_BYTES = 16 * 1024 * 1024
TAIL_LINES = 3000

# (표시 이름, 라벨 정규식, 같은 줄 값 필수)
LABELS = [
    ("원문", r"원문", True),
    ("사용자 의도", r"사용자[ \t]*의도", True),
    ("기술 타당성", r"기술[ \t]*타당성", True),
    ("확장 키워드", r"확장[ \t]*키워드", True),
    ("확장 질의", r"확장[ \t]*질의", False),
    ("대상", r"대상", True),
    ("조건", r"조건", True),
    ("성공기준", r"성공[ \t]*기준", True),
    ("컨텍스트", r"컨텍스트", True),
]
NOTIF = ("<teammate-message", "<task-notification", "<cross-session-message",
         "Another Claude session sent a message", "[Request interrupted")
NOT_PROMPT = ("Base directory for this skill", "Stop hook feedback", "<system-reminder>")
OX = re.compile(r"^(?:/ox(?:\s|$)|<command-name>/?ox</command-name>)")


def log(msg):
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a", encoding="utf-8") as f:
            f.write("%s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S%z"), msg))
    except OSError:
        pass


def missing_labels(text):
    out = []
    for name, rx, need in LABELS:
        pat = re.compile(r"^[ \t>*\-•·]*(?:\*\*|__)?" + rx + r"(?:\*\*|__)?[ \t]*[:：][ \t]*(?:\*\*|__)?[ \t]*(.*)$", re.M)
        if not any((not need) or m.group(1).strip() for m in pat.finditer(text)):
            out.append(name)
    return out


def read_tail(path):
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        if size > TAIL_BYTES:
            f.seek(size - TAIL_BYTES)
            f.readline()
        return list(collections.deque(
            (ln for ln in f if not ln.startswith(b'{"type":"api-request-blob"')), maxlen=TAIL_LINES))


def kind(e):
    if not isinstance(e, dict) or e.get("isSidechain"):
        return "skip"
    t = e.get("type")
    if t == "system" and e.get("subtype") == "compact_boundary":
        return "compact"
    if t == "user" and e.get("isCompactSummary"):
        return "compact"
    if t == "attachment" or isinstance(e.get("attachment"), dict):
        a = e.get("attachment") or {}
        if a.get("type") == "queued_command" and a.get("commandMode", "prompt") == "prompt":
            return "queued"
        return "skip"
    if t in ("assistant", "user"):
        return t
    return "skip"


def blocks(e):
    c = (e.get("message") or {}).get("content")
    if isinstance(c, str):
        return [{"type": "text", "text": c}]
    return [b for b in c if isinstance(b, dict)] if isinstance(c, list) else []


def prompt_text(e):
    """user 항목이 입력이면 본문을, 도구 결과·스킬 본문·메타면 None 을 준다."""
    if e.get("isMeta"):
        return None
    bs = blocks(e)
    if any(b.get("type") == "tool_result" for b in bs):
        return None
    t = "\n".join(b.get("text", "") for b in bs if b.get("type") == "text").strip()
    if not t or t.startswith(NOT_PROMPT):
        return None
    return t


def classify(t):
    if t.startswith(NOTIF):
        return "notif"
    return "ox" if OX.match(t) else "real"


def is_call(b):
    if b.get("type") != "tool_use" or b.get("name") != "Skill":
        return False
    i = b.get("input") or {}
    return str(i.get("skill") or i.get("skill_name") or "").lstrip("/") == "ointaug"


def judge(data):
    """('pass', 코드) 또는 ('block', 서명, 누락 목록)."""
    tp = data.get("transcript_path") or ""
    tp = os.path.expanduser(tp) if isinstance(tp, str) else ""
    if not tp or not os.path.isfile(tp):
        log("NO_TRANSCRIPT")
        return ("pass", "no_transcript")
    lines = read_tail(tp)
    parsed, bad_after, call_idx, call_block_i = [None] * len(lines), 0, None, None
    for i in range(len(lines) - 1, -1, -1):
        try:
            parsed[i] = json.loads(lines[i])
        except ValueError:
            bad_after += 1
            continue
        if kind(parsed[i]) == "assistant":
            hit = [n for n, b in enumerate(blocks(parsed[i])) if is_call(b)]
            if hit:
                call_idx, call_block_i = i, hit[-1]
                break
    if call_idx is None:
        if bad_after and bad_after == len(lines):
            log("PARSE_FAIL all_lines=%d" % bad_after)
        return ("pass", "no_call")
    if bad_after:
        log("PARSE_FAIL after_call=%d" % bad_after)
        return ("pass", "parse_fail")

    call_blocks = blocks(parsed[call_idx])
    sig = str(call_blocks[call_block_i].get("id") or "line:%d" % call_idx)
    texts = [b.get("text", "") for b in call_blocks[call_block_i + 1:] if b.get("type") == "text"]
    for e in parsed[call_idx + 1:]:
        k = kind(e)
        if k == "compact":
            return ("pass", "compact")
        if k == "user" and prompt_text(e) is not None:
            return ("pass", "turn_over")
        if k == "assistant":
            texts += [b.get("text", "") for b in blocks(e) if b.get("type") == "text"]

    # 호출이 어떤 입력에 대한 것인지 뒤로 걸어 찾는다. 그 사이 어시스턴트 텍스트(호출 앞 형식 블록)도 화면에 있으므로 모은다(L-1461).
    before = [b.get("text", "") for b in call_blocks[:call_block_i] if b.get("type") == "text"]
    opened = None
    for j in range(call_idx - 1, -1, -1):
        try:
            e = json.loads(lines[j])
        except ValueError:
            continue
        k = kind(e)
        if k == "compact":
            return ("pass", "compact")
        if k == "assistant":
            before = [b.get("text", "") for b in blocks(e) if b.get("type") == "text"] + before
            continue
        if k == "queued":
            t = str(e["attachment"].get("prompt") or "").strip()
            c = classify(t) if t else "notif"
            if c == "ox":
                return ("pass", "ox")
            if c == "real":
                opened = "real"
                break
        elif k == "user":
            t = prompt_text(e)
            if t is None:
                continue
            c = classify(t)
            if c != "real":
                return ("pass", c)
            opened = "real"
            break
    if opened is None:
        return ("pass", "no_opening")

    last = data.get("last_assistant_message")
    if isinstance(last, str):
        texts.append(last)
    miss = missing_labels("\n".join(before + texts))
    return ("pass", "complete") if not miss else ("block", sig, miss)


def main():
    data = json.loads(sys.stdin.read())
    try:
        wait = float(os.environ.get("OINTAUG_GUARD_RETRY_SLEEP", "0.4"))
    except ValueError:
        wait = 0.4
    # transcript 는 비동기로 기록된다. 차단 판정일 때만 짧게 다시 읽어 지연 오탐을 줄인다.
    v = judge(data)
    for _ in range(2):
        if v[0] != "block":
            break
        time.sleep(wait)
        v = judge(data)
    if v[0] != "block":
        if v[1] == "complete" and os.path.exists(COUNT):
            os.remove(COUNT)
        return 0

    sig, miss = v[1], v[2]
    seen = []
    if os.path.exists(ESCAPED):
        with open(ESCAPED, encoding="utf-8") as f:
            seen = f.read().split()
    if sig in seen:
        return 0
    prior = 0
    if os.path.exists(COUNT):
        with open(COUNT, encoding="utf-8") as f:
            rows = f.read().split("\n")
        if rows and rows[0] == sig and len(rows) > 1 and rows[1].isdigit():
            prior = int(rows[1])
    if prior >= 2:
        log("ESCAPE sig=%s missing=%s" % (sig, ",".join(miss)))
        with open(ESCAPED, "a", encoding="utf-8") as f:
            f.write(sig + "\n")
        os.remove(COUNT)
        return 0
    with open(COUNT, "w", encoding="utf-8") as f:
        f.write("%s\n%d\n" % (sig, prior + 1))
    log("BLOCK sig=%s n=%d missing=%s" % (sig, prior + 1, ",".join(miss)))
    reason = (
        "⛔ [F-INTAUG-4] ointaug 호출 뒤 화면 출력에 필수 항목이 없습니다. 누락: " + ", ".join(miss) + ". "
        "빠진 라벨만 덧붙이지 말고 아래 형식 전체를 지금 출력하십시오. 라벨은 줄 맨 앞에 `라벨:` 로 쓰고 값을 같은 줄에 적습니다.\n"
        "📌 [ointaug 확장]\n원문: {사용자 원문 전체}\n사용자 의도: {1줄}\n기술 타당성: {가능/불가능/부분가능} — {근거 1줄}\n"
        "확장 키워드: {쉼표 나열}\n\n확장 질의:\n{최소 3줄}\n- 대상: {…}\n- 조건: {…}\n- 성공기준: {…}\n- 컨텍스트: {…}"
    )
    print(json.dumps({"decision": "block", "reason": reason}, ensure_ascii=False))
    return 2


try:
    rc = main()
except Exception as ex:  # fail-open: 어떤 내부 오류도 차단이 되면 안 된다.
    log("INTERNAL_ERROR %s: %s" % (type(ex).__name__, ex))
    rc = 0
sys.exit(rc)
PYEOF
)"

OUT="$(python3 -B -c "$PY_SRC" "$SD" <<<"$INPUT" 2>/dev/null)"
RC=$?
if [[ "$RC" -eq 2 && -n "$OUT" ]]; then
    printf '%s\n' "$OUT"
    exit 2
fi
exit 0
