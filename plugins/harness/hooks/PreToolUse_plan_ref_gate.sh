#!/bin/bash
# o3~o5 의 state=DEV 전이 시 계획서 '## 정본 참조' 절과 plan/index.json 읽기 기록(F-PLAN-REF)을 강제하는 hook
# PreToolUse:mcp__oio__session_state — key=state, value 첫 단어=DEV 전이만 대상
#
# 판정 코어: lib/plan_ref_gate.py check --session-dir <D> --cwd <C> (규칙은 코어 docstring 참조)
#   - O3~O5 위반 → block, O2 위반 → 경고(additionalContext), 그 외 → 통과
#   - 프로젝트에 plan root(기본 plan/, canon.plan_root 로 변경)가 없으면 통과
#   - [K6] 공용 해석기 lib/canon_root.py 로 먼저 본다: 표식(.git 파일·디렉터리, .claude 디렉터리) 없는 경로(project_root=null)
#     또는 canon.plan_root 거부(절대경로·'..')면 통과. 해석기 없음·실패는 종전대로 코어가 판정한다.
# 통과 조건 (exit 0, 출력 없음 또는 정보 1줄):
#   - key≠state, value≠DEV, tool_input.uuid 형식 오류, uuid 가 자기 세션이 아님(세션 격리)
#   - force=true (자기 세션 메인이면 logs/plan_ref_gate.log 에 FORCE-BYPASS 1줄을 남기고 통과)
#   - 팀에이전트(조상 argv --parent-session-id) — 메인의 DEV 전이만 검사
#   - 비상 스위치 ${PLAN_REF_GATE_SWITCH:-${HARNESS_HOME:-$HOME/.harness}/current/hooks/DISABLE_PLAN_REF_GATE} 의 mtime 이 TTL(기본 120분) 이내
#   - jq·python3 부재, 입력 파싱 실패, 세션 디렉토리 부재, 코어 오류 등 판정 불가(fail-open)
# 쓰기: 자기 세션 session-env/<UUID>/logs/plan_ref_gate.log 만 (세션 격리 §(a))
# 등록(B4 담당): PreToolUse mcp__oio__session_state 그룹, dev_ac_gate 다음 `time_budget.sh 2.5 open`.

set -u

command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
INPUT=$(timeout 5 cat 2>/dev/null) || exit 0
[ -z "$INPUT" ] && exit 0
_get() { printf '%s' "$INPUT" | jq -r "$1" 2>/dev/null; }

[ "$(_get '.tool_input.key // empty')" = "state" ] || exit 0
_VALUE=$(_get '.tool_input.value // empty')
[ "${_VALUE%% *}" = "DEV" ] || exit 0

_UUID=$(_get '.tool_input.uuid // empty')
printf '%s' "$_UUID" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || exit 0

_FORCE=0
case "$(_get '.tool_input.force // false | tostring | ascii_downcase')" in
  true|1|yes) _FORCE=1 ;;
esac

# 자기 세션 확인
_SELF="${PIPELINE_UUID:-}"
[ -n "$_SELF" ] || _SELF=$(_get '.session_id // empty' | tr -d '[:space:]')
{ [ -n "$_SELF" ] && [ "$_SELF" = "$_UUID" ]; } || exit 0

# 팀에이전트 제외 (dev_ac_gate·done_gate 와 같은 기준)
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
_LOG="${_SD}/logs/plan_ref_gate.log"
_log() { mkdir -p "${_SD}/logs" 2>/dev/null; echo "$(date '+%Y-%m-%dT%H:%M:%S%z') $*" >> "$_LOG" 2>/dev/null || true; }

# force=true 는 통과시키되 흔적을 남긴다(게이트 회피 추적용)
if [ "$_FORCE" = 1 ]; then
  _log "FORCE-BYPASS 통과 value=${_VALUE}"
  exit 0
fi

# 비상 스위치 (mtime TTL 이내만 인정 — docs_gate 와 같은 방식)
_SW="${PLAN_REF_GATE_SWITCH:-${HARNESS_HOME:-$HOME/.harness}/current/hooks/DISABLE_PLAN_REF_GATE}"
if [ -f "$_SW" ]; then
  _TTL="${PLAN_REF_GATE_SWITCH_TTL_MIN:-120}"
  case "$_TTL" in ''|*[!0-9]*) _TTL=120 ;; esac
  _SWM=$(stat -c %Y "$_SW" 2>/dev/null) || _SWM=""
  _NOW=$(date +%s)
  case "$_SWM" in
    ''|*[!0-9]*) _log "SWITCH-UNREADABLE 무시" ;;
    *)
      if [ $((_NOW - _SWM)) -le $((_TTL * 60)) ]; then
        _log "SWITCH-ON 통과"
        exit 0
      fi
      _log "SWITCH-EXPIRED age=$(( (_NOW - _SWM) / 60 ))m ttl=${_TTL}m 무시하고 검사" ;;
  esac
fi

_CORE="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/lib/plan_ref_gate.py"
[ -f "$_CORE" ] || exit 0
_CWD=$(_get '.cwd // empty')
[ -n "$_CWD" ] || _CWD="$PWD"
# [K6 TODO-003] 루트·plan_root 해석 공용화 — canon_root 결과가 있으면 그것을 따른다
_CR="$(dirname "$_CORE")/canon_root.py"
if [ -f "$_CR" ]; then
  _CRO=$(timeout 2 python3 -B "$_CR" --path "$_CWD" 2>/dev/null) || _CRO=""
  _CRR=""
  [ -n "$_CRO" ] && _CRR=$(printf '%s' "$_CRO" | jq -r 'if .project_root == null then "NOROOT" elif .plan_root_invalid == true then "INVALID" else "OK" end' 2>/dev/null)
  case "$_CRR" in
    NOROOT) _log "CANON-NOROOT 통과 cwd=${_CWD}"; exit 0 ;;
    INVALID) _log "CANON-PLAN-ROOT-INVALID 통과 cwd=${_CWD}"; exit 0 ;;
  esac
fi
_OUT=$(timeout 2 python3 -B "$_CORE" check --session-dir "$_SD" --cwd "$_CWD" 2>/dev/null) || _OUT=""
[ -n "$_OUT" ] || { _log "CORE-FAIL 통과(fail-open)"; exit 0; }

_DEC=$(printf '%s' "$_OUT" | jq -r '.decision // "pass"' 2>/dev/null)
_MSG=$(printf '%s' "$_OUT" | jq -r '.message // ""' 2>/dev/null)
case "$_DEC" in
  block)
    jq -n --arg r "$_MSG" '{decision:"block", reason:$r}' 2>/dev/null \
      || echo '{"decision":"block","reason":"⛔ [F-PLAN-REF] DEV 전이 차단 — 계획서 정본 참조 절 또는 plan/index.json 읽기 기록 없음"}'
    ;;
  warn)
    jq -n --arg c "$_MSG" '{hookSpecificOutput:{hookEventName:"PreToolUse", additionalContext:$c}}' 2>/dev/null || true
    ;;
esac
exit 0
