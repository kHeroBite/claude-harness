#!/bin/bash
# o3~o5 의 state=DEV 전이 시 이번 사이클 acceptance_criteria.json 존재(F-AC-DEV)를 강제하는 hook
# PreToolUse:mcp__oio__session_state — key=state, value 첫 단어=DEV 전이만 대상
#
# 차단 조건 (모두 충족 시 block):
#   - classification ∈ {O3,O4,O5}
#   - plans/acceptance_criteria.json 이 없음, 또는 파이프라인 시작 시각(pipeline_start_time)보다 오래됨(이전 사이클 잔존본)
# 통과 조건 (exit 0):
#   - key≠state, value≠DEV, tool_input.uuid 형식 오류, force=true, uuid 가 자기 세션이 아님(세션 격리)
#   - 팀에이전트(조상 argv --parent-session-id) — 메인의 DEV 전이만 검사
#   - classification 부재/OK/O0/O1/O2 (경고 1줄만)
#   - pipeline_start_time 부재(구 세션) → AC 는 존재만 검사
#   - jq 부재·입력 파싱 실패·세션 디렉토리 부재 등 판정 불가(fail-open)
# fail-open 결정: 등록은 `time_budget 2.5 open`(timeout 5)을 유지한다. open 으로 두는 이유는 matcher 가
#   session_state 전체라서 closed 면 hook 정체 때 모든 상태 쓰기가 보류되기 때문이다.
#   백스톱은 otest AC 검수와 done_gate 다. 하네스에는 fail-open 등록부가 없고,
#   파생 프로젝트 등록은 hook_registry_sync 가 SessionStart 때 자동 반영한다.
# 한계: settings.json 등록은 새 세션부터 반영된다.

set -u

command -v jq >/dev/null 2>&1 || exit 0
INPUT=$(timeout 5 cat 2>/dev/null) || exit 0
[ -z "$INPUT" ] && exit 0
_get() { printf '%s' "$INPUT" | jq -r "$1" 2>/dev/null; }

[ "$(_get '.tool_input.key // empty')" = "state" ] || exit 0
_VALUE=$(_get '.tool_input.value // empty')
[ "${_VALUE%% *}" = "DEV" ] || exit 0

_UUID=$(_get '.tool_input.uuid // empty')
printf '%s' "$_UUID" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || exit 0

case "$(_get '.tool_input.force // false | tostring | ascii_downcase')" in
  true|1|yes) exit 0 ;;
esac

# 자기 세션 확인
_SELF="${PIPELINE_UUID:-}"
[ -n "$_SELF" ] || _SELF=$(_get '.session_id // empty' | tr -d '[:space:]')
{ [ -n "$_SELF" ] && [ "$_SELF" = "$_UUID" ]; } || exit 0

# 팀에이전트 제외 (done_gate 와 같은 기준)
_TEAM=""
_real_home=""
if [ "${WG_TEST_SANDBOX:-}" = "1" ] && [ -n "${WG_LINEAGE_OVERRIDE:-}" ]; then
  _real_home=$(getent passwd "$(id -un 2>/dev/null)" 2>/dev/null | cut -d: -f6)
fi
if [ -n "$_real_home" ] && [ "$HOME" != "$_real_home" ]; then
  case "$WG_LINEAGE_OVERRIDE" in team:*) _TEAM="${WG_LINEAGE_OVERRIDE#team:}" ;; esac
else
  _p=$$; _i=0
  while [ -n "$_p" ] && [ "$_p" != "1" ] && [ $_i -lt 12 ]; do
    _TEAM=$(tr '\0' ' ' 2>/dev/null < "/proc/${_p}/cmdline" \
      | grep -oP -- '--parent-session-id[ =]\K[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
    [ -n "$_TEAM" ] && break
    _p=$(awk '/^PPid:/{print $2}' "/proc/${_p}/status" 2>/dev/null)
    _i=$((_i + 1))
  done
fi
[ -n "$_TEAM" ] && exit 0

# 세션 디렉토리 (CLAUDE_CONFIG_DIR 우선, 없으면 HOME)
_SD=""
for _b in "${CLAUDE_CONFIG_DIR:-}" "$HOME/.claude"; do
  [ -n "$_b" ] && [ -d "${_b}/session-env/${_UUID}" ] && { _SD="${_b}/session-env/${_UUID}"; break; }
done
[ -n "$_SD" ] || exit 0

_CLS=$(head -n1 "${_SD}/classification" 2>/dev/null | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
case "$_CLS" in
  O3|O4|O5) ;;
  *)
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"[dev_ac_gate] classification='"${_CLS:-없음}"' — o3~o5 가 아니라 AC 검사를 건너뜁니다."}}'
    exit 0 ;;
esac

_AC="${_SD}/plans/acceptance_criteria.json"
_REASON=""
_PST=""
_TAG="F-AC-DEV"
if [ ! -s "$_AC" ]; then
  _REASON="plans/acceptance_criteria.json 이 없습니다."
else
  # 파이프라인 시작 시각: 세션 루트 또는 evidence/ 의 pipeline_start_time (숫자면 epoch, 아니면 mtime)
  for _f in "${_SD}/pipeline_start_time" "${_SD}/evidence/pipeline_start_time"; do
    [ -f "$_f" ] || continue
    _c=$(head -n1 "$_f" 2>/dev/null | tr -d '[:space:]')
    case "$_c" in
      ''|*[!0-9]*) _PST=$(stat -c %Y "$_f" 2>/dev/null) ;;
      *) _PST="$_c" ;;
    esac
    break
  done
  case "$_PST" in
    ''|*[!0-9]*) ;;
    *)
      _ACM=$(stat -c %Y "$_AC" 2>/dev/null) || _ACM=""
      case "$_ACM" in
        ''|*[!0-9]*) ;;
        *) [ "$_ACM" -lt "$_PST" ] && _REASON="acceptance_criteria.json 이 이번 사이클 시작(${_PST})보다 오래됐습니다(mtime=${_ACM}) — 이전 사이클 잔존본입니다." ;;
      esac ;;
  esac
fi

[ -n "$_REASON" ] || exit 0

mkdir -p "${_SD}/logs" 2>/dev/null
echo "$(date '+%Y-%m-%dT%H:%M:%S%z') BLOCK ${_TAG} cls=${_CLS} ${_REASON}" >> "${_SD}/logs/dev_ac_gate.log" 2>/dev/null || true
_MSG="⛔ [F-AC-DEV] ${_CLS} 의 DEV 전이 차단 — ${_REASON} oplan 단계에서 이번 사이클 acceptance_criteria.json 을 plans/ 에 작성한 뒤 다시 전이하세요. (역라우팅은 이번 사이클 AC 가 있으면 통과합니다.)"
jq -n --arg r "$_MSG" '{decision:"block", reason:$r}' 2>/dev/null \
  || echo '{"decision":"block","reason":"⛔ [F-AC-DEV] DEV 전이 차단 — acceptance_criteria.json 없음/이전 사이클 것"}'
exit 0
