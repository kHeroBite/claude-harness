#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# DONE 진입 시점에 auto(oto)/RALPH(oralph) 세션의 잔여 계약 항목을 확인하는 hook
# PreToolUse:mcp__oio__session_state — key=state, value=DONE 전이 시도만 검사
#
# 배경: 사용자 요청 — "done단계 진입할때 auto나 ralph인지를 체크하고 그 조건에
#       맞게 작업이 완료되어서 남은작업이 없는지를 확인하고, 만약 남은작업이
#       있다면 다시 plan단계로 되돌려서 마무리 될수있도록" (2026-08-29).
#       기존 PreToolUse_oto_completion_guard.sh(F-OTO-1~8)는 FINISH→IDLE 전이
#       시점(ofinish 완료 후)에만 검사한다. 본 hook은 그보다 이른 DONE 진입
#       시점(odone spawn 직전)에 동일 계약을 선제 검사하여, odone(교훈수집/
#       정리/git커밋)이 불필요하게 실행되기 전에 잔여 작업을 잡는다.
#
# 설계 원칙 (F-OTO 계열과 동일):
#   - auto=ON 또는 status에 RALPH 없는 세션은 무조건 즉시 exit 0 (일반 파이프라인 무영향 — 최우선)
#   - 세션 격리 §(a): 자기 UUID 하위만 읽는다. 타 세션 무영향
#   - 이 게이트는 F-OTO 계열(최종 방어선)의 "추가 안전망"이므로 판정 불가/예외는
#     전부 fail-open(통과) — 단, 모든 fail-open 분기에 로그를 남긴다(추적 가능성 확보)
#   - blocked/blocked_by 항목은 fail로 세지 않는다 (oto/goal 계약과 동일 원칙 — 세면 루프가 안 끝난다)
#   - 판정 가능 범위는 auto_script가 있는 open 항목뿐 — criteria_detail(자연어)은
#     hook이 판정할 수 없다(otest_verify 스킬 절차가 담당). hook은 최종 안전망.
#   - 무한루프 방지: oralph_active.current_iteration/max_iterations 재사용(신규 카운터 금지)
#   - 비상 스위치: hooks/DISABLE_DONE_GATE 존재 시 즉시 통과
#   - valid_after 시점 태그(L-DEMO-4, 2026-09-05): acceptance 항목에 "valid_after":"odone" 이
#     있으면 이 게이트(DONE 전이 시점) 판정에서 제외한다. 커밋 게이트처럼 정의상 DONE 이후에만
#     충족 가능한 항목을 시점 무관 실행하면 필연적으로 차단되므로(예: A11 커밋 게이트),
#     비상 스위치(DISABLE_DONE_GATE) 상시 사용 대신 이 필드로 근본 해결한다.

INPUT=$(timeout 5 cat 2>/dev/null) || INPUT=""

_HOOK_DIR="$HOME/.claude/hooks"

# ── 0. 비상 스위치 ──────────────────────────────────────────────────
[[ -f "${_HOOK_DIR}/DISABLE_DONE_GATE" ]] && exit 0

# ── 1. 도구 입력 판별: key=state AND value=DONE 전이만 대상 ───────────
_KEY=$(echo "$INPUT" | jq -r '.tool_input.key // empty' 2>/dev/null) || exit 0
[[ "$_KEY" == "state" ]] || exit 0

_VALUE=$(echo "$INPUT" | jq -r '.tool_input.value // empty' 2>/dev/null) || exit 0
case "$_VALUE" in
  DONE|DONE\ *) ;;
  *) exit 0 ;;
esac

# ── 2. 재진입 방지 ────────────────────────────────────────────────────
_STOP_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)
[[ "$_STOP_ACTIVE" == "true" ]] && exit 0

# ── 3. UUID 결정 ──────────────────────────────────────────────────────
# shellcheck source=/dev/null
source "${_HOOK_DIR}/lib/session_id.sh" 2>/dev/null || exit 0
resolve_uuid "$INPUT" 2>/dev/null || exit 0
[[ -z "${UUID:-}" ]] && exit 0

# 팀에이전트/서브에이전트는 대상 아님 (메인의 DONE 전이만 검사 — 실제 state 전파는
# ok_pipeline이 메인 컨텍스트에서 odone spawn 직전에 호출한다)
if [[ -n "${PIPELINE_UUID:-}" && "${PIPELINE_UUID:-}" != "${MY_UUID:-$UUID}" ]]; then
  exit 0
fi

# ── 4. SESSION_DIR 결정 (+ cc-prefix 분리 폴백) ───────────────────────
SESSION_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}"
HOME_SESSION_DIR="$HOME/.claude/session-env/${UUID}"

if [[ ! -f "${SESSION_DIR}/auto" && ! -f "${SESSION_DIR}/status" && \
      ( -f "${HOME_SESSION_DIR}/auto" || -f "${HOME_SESSION_DIR}/status" ) ]]; then
  SESSION_DIR="${HOME_SESSION_DIR}"
  _PATH_FALLBACK=1
fi

LOG_DIR="${SESSION_DIR}/logs"
LOG_FILE="${LOG_DIR}/done_gate.log"
mkdir -p "$LOG_DIR" 2>/dev/null
_log() {
  echo "$(date '+%Y-%m-%dT%H:%M:%S%z') $*" >> "$LOG_FILE" 2>/dev/null || true
}

# ── 5. 대상 세션 판정 — auto=ON 또는 status에 RALPH 없으면 무조건 통과 ──
_IS_AUTO=0
if [[ -f "${SESSION_DIR}/auto" ]]; then
  _AUTO_VAL=$(tr -d '[:space:]' < "${SESSION_DIR}/auto" 2>/dev/null) || _AUTO_VAL=""
  [[ "$_AUTO_VAL" == "ON" ]] && _IS_AUTO=1
fi

_IS_RALPH=0
if [[ -f "${SESSION_DIR}/status" ]] \
   && grep -qE '(^|\|)RALPH(\||$)' "${SESSION_DIR}/status" 2>/dev/null; then
  _IS_RALPH=1
fi

if [[ "$_IS_AUTO" -eq 0 && "$_IS_RALPH" -eq 0 ]]; then
  exit 0
fi

_log "ENTER uuid=${UUID} auto=${_IS_AUTO} ralph=${_IS_RALPH} value=${_VALUE}${_PATH_FALLBACK:+ path_fallback=HOME}"

# jq 없으면 검사 불가 → fail-open (로그 남기고 통과)
if ! command -v jq >/dev/null 2>&1; then
  _log "FAIL-OPEN jq 부재 — 검사 불가, DONE 전이 통과"
  exit 0
fi

# ── 6. goal.json 기반 판정 (F-OTO-2와 동일 알고리즘 재사용) ────────────
GOAL="${SESSION_DIR}/goal.json"

if [[ ! -f "$GOAL" ]]; then
  _log "FAIL-OPEN goal.json 부재 — 검사 불가(대상 없음), DONE 전이 통과 (auto/RALPH 세션이지만 계약 문서 없음)"
  exit 0
fi

if ! jq -e . "$GOAL" >/dev/null 2>&1; then
  _log "FAIL-OPEN goal.json 파싱 실패 — 검사 불가, DONE 전이 통과 (F-OTO-1p가 최종 방어선에서 잡음)"
  exit 0
fi

_LOCKED=$(jq -r '.locked // false' "$GOAL" 2>/dev/null) || _LOCKED="false"
if [[ "$_LOCKED" != "true" ]]; then
  _log "FAIL-OPEN goal.json locked=false — 계약 미확정, DONE 전이 통과"
  exit 0
fi

# blocked/blocked_by 제외, auto_script 있는 open 항목만 실행 판정
_FAIL=0
_FAIL_IDS=""
_RAN=0

while IFS= read -r _ITEM; do
  [[ -z "$_ITEM" ]] && continue
  _SCRIPT=$(echo "$_ITEM" | jq -r '.auto_script // empty' 2>/dev/null)
  _ID=$(echo "$_ITEM" | jq -r '.id // "?"' 2>/dev/null)
  # auto_script 없는 항목은 기계 판정 불가 — F-OTO-8과 달리 이 게이트는 no-op 방지를
  # 강제하지 않는다(F-OTO 계열이 이미 강제함). fail-open으로 스킵하고 로그만 남긴다.
  [[ -z "$_SCRIPT" ]] && { _log "SKIP id=${_ID} auto_script 없음 — 판정 불가"; continue; }
  _RAN=$((_RAN + 1))
  if ! timeout 5 bash -c "$_SCRIPT" >/dev/null 2>&1; then
    _FAIL=$((_FAIL + 1))
    _FAIL_IDS="${_FAIL_IDS}${_FAIL_IDS:+, }${_ID}"
  fi
done < <(jq -c '(.acceptance // [])[] | select((.status // "open") != "blocked" and (.status // "open") != "blocked_by") | select((.valid_after // "") != "odone")' "$GOAL" 2>/dev/null)

_log "CHECK ran=${_RAN} fail=${_FAIL} ids=${_FAIL_IDS:-none}"

if [[ "$_FAIL" -eq 0 ]]; then
  _log "PASS 잔여 acceptance 없음 (ran=${_RAN}) — DONE 전이 허용"
  exit 0
fi

# ── 7. 무한루프 방지 — oralph_active.max_iterations 재사용 ─────────────
ORALPH_FLAG="${SESSION_DIR}/oralph_active"
[[ ! -f "$ORALPH_FLAG" && -f "${ORALPH_FLAG}.json" ]] && ORALPH_FLAG="${ORALPH_FLAG}.json"

_CUR_ITER=0
_MAX_ITER=5
if [[ -f "$ORALPH_FLAG" ]]; then
  _CUR_ITER=$(jq -r '.current_iteration // 0' "$ORALPH_FLAG" 2>/dev/null) || _CUR_ITER=0
  _MAX_ITER=$(jq -r '.max_iterations // 5' "$ORALPH_FLAG" 2>/dev/null) || _MAX_ITER=5
fi

if [[ "$_CUR_ITER" -ge "$_MAX_ITER" ]]; then
  _log "FAIL-OPEN max_iterations 도달(${_CUR_ITER}/${_MAX_ITER}) — 무한루프 방지, DONE 전이 통과(미완료 보고는 스킬 절차가 담당)"
  exit 0
fi

# ── 8. block — 스킬(otest_verify 종료부)이 먼저 잡아야 정상 경로.
#      여기 도달했다는 것은 스킬 절차를 건너뛰고 곧바로 state=DONE을 쓴 비정상
#      경로이므로 최종 안전망으로 차단한다.
_log "BLOCK fail=${_FAIL} ids=${_FAIL_IDS} iter=${_CUR_ITER}/${_MAX_ITER}"
jq -cn --arg r "⛔ [done_gate] DONE 진입 차단 — auto/RALPH 계약상 미충족 acceptance ${_FAIL}건: ${_FAIL_IDS}
otest_verify 종료 직후 스킬 절차가 이 검사를 먼저 수행해야 합니다(정상 경로).
이 hook은 그 절차를 건너뛴 경우의 최종 안전망입니다.
→ 해결: otest_verify 절차대로 실패 항목을 반영해 PLAN으로 재진입하거나,
   비상 시 hooks/DISABLE_DONE_GATE 파일 생성으로 우회하십시오." \
  '{decision:"block", reason:$r}' 2>/dev/null \
  || echo '{"decision":"block","reason":"⛔ DONE 진입 차단 — auto/RALPH 계약상 미충족 acceptance 항목이 있습니다."}'
source "${_HOOK_DIR}/lib/write_error.sh" 2>/dev/null || true
type log_hook_error >/dev/null 2>&1 && \
  log_hook_error "HOOK_BLOCK_DONE_GATE" "mcp__oio__session_state" "DONE 진입 차단 — 미충족 acceptance ${_FAIL}건: ${_FAIL_IDS}" "$UUID"
exit 2
