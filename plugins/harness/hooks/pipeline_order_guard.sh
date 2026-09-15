#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# pipeline_order_guard.sh — 파이프라인 순서 강제 + 좀비/고아 pane 정리 (PreToolUse:Agent)
# 팀에이전트 spawn 시 프롬프트에서 단계 키워드를 파싱하여 순서 위반 차단
# 진입 기반: 상태 = "현재 실행 중인 단계". 메인이 spawn 직전 상태 설정 → guard가 일치 검증.
# 서브에이전트(Explore 등)는 차단 대상 아님
# 좀비 pane 정리: agents/ 기반 좀비만 정리 (고아 pane 무차별 kill 금지 — L-213)

trap 'exit 0' ERR

INPUT=$(timeout 5 cat 2>/dev/null) || INPUT=""
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
PROMPT=$(echo "$INPUT" | jq -r '.tool_input.prompt // ""' 2>/dev/null || echo "")
TEAM_NAME=$(echo "$INPUT" | jq -r '.tool_input.team_name // empty' 2>/dev/null || echo "")

# 팀에이전트가 아니면 패스 (서브에이전트는 team_name 없음)
[[ -z "$TEAM_NAME" ]] && exit 0

# --- UUID 결정 ---
source "${HARNESS_HOOK_DIR}/lib/session_id.sh"
if ! resolve_uuid "$INPUT" 2>/dev/null; then
  UUID="${SESSION_ID}"
fi
[[ -z "$UUID" ]] && exit 0
SESSION_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}"

# Agent name 파라미터 기반 단계 판별 (Phase 4: 프롬프트 파싱보다 안정적)
AGENT_NAME=$(echo "$INPUT" | jq -r '.tool_input.name // empty' 2>/dev/null || echo "")
SPAWN_PHASE=""

# 1순위: Agent name 파라미터
if [[ -n "$AGENT_NAME" ]]; then
  case "$AGENT_NAME" in
    odone*) SPAWN_PHASE="DONE" ;;
    otest*) SPAWN_PHASE="TEST" ;;
    odev*)  SPAWN_PHASE="DEV" ;;
    oplan*) SPAWN_PHASE="PLAN" ;;
  esac
fi

# 2순위: 프롬프트 텍스트 (name 미설정 시 fallback)
if [[ -z "$SPAWN_PHASE" ]]; then
  if echo "$PROMPT" | grep -qE "Skill\\(['\"']?odone['\"']?\\)"; then
    SPAWN_PHASE="DONE"
  elif echo "$PROMPT" | grep -qE "Skill\\(['\"']?otest['\"']?\\)"; then
    SPAWN_PHASE="TEST"
  elif echo "$PROMPT" | grep -qE "Skill\\(['\"']?odev['\"']?\\)"; then
    SPAWN_PHASE="DEV"
  elif echo "$PROMPT" | grep -qE "Skill\\(['\"']?oplan['\"']?\\)"; then
    SPAWN_PHASE="PLAN"
  fi
fi

# 단계 키워드 미감지 시 패스 (범용 에이전트 등)
[[ -z "$SPAWN_PHASE" ]] && exit 0

# 현재 파이프라인 상태 확인
STATE_FILE="${SESSION_DIR}/state"
if [[ -f "$STATE_FILE" ]]; then
  # F6: state_read 경유 (flock 보호). __LOCK_FAIL__ 시 IDLE 처리하여 spawn 차단 보수 동작.
  _STATE_LINE=$(state_read "$STATE_FILE" 2>/dev/null || echo "IDLE")
  STATE=$(echo "$_STATE_LINE" | awk '{print $1}')
  STATE_UUID=$(echo "$_STATE_LINE" | awk '{print $2}')
  if [[ "$STATE" == "__LOCK_FAIL__" ]]; then
    STATE="IDLE"
    STATE_UUID=""
  fi
else
  STATE="IDLE"
  STATE_UUID=""
fi
STATE=${STATE:-IDLE}

# 다른 세션이 pipeline_state를 소유 중이면 순서 검증 스킵 (다중 팀 충돌 방지)
if [[ -n "$STATE_UUID" && "$STATE_UUID" != "$UUID" ]]; then
  exit 0
fi

# 순서 검증 (진입 기반 허용 매트릭스)
ALLOWED=false
case "$STATE" in
  OK)
    [[ "$SPAWN_PHASE" == "PLAN" || "$SPAWN_PHASE" == "DEV" ]] && ALLOWED=true
    ;;
  PLAN)
    [[ "$SPAWN_PHASE" == "PLAN" ]] && ALLOWED=true
    ;;
  DEV)
    [[ "$SPAWN_PHASE" == "DEV" || "$SPAWN_PHASE" == "PLAN" ]] && ALLOWED=true  # DEV→PLAN 역라우팅
    ;;
  TEST)
    [[ "$SPAWN_PHASE" == "TEST" || "$SPAWN_PHASE" == "DEV" || "$SPAWN_PHASE" == "PLAN" ]] && ALLOWED=true  # TEST→DEV, TEST→PLAN 역라우팅
    ;;
  DONE)
    [[ "$SPAWN_PHASE" == "DONE" || "$SPAWN_PHASE" == "TEST" ]] && ALLOWED=true  # DONE→TEST 역라우팅
    ;;
  FINISH)
    [[ "$SPAWN_PHASE" == "PLAN" || "$SPAWN_PHASE" == "DEV" ]] && ALLOWED=true
    ;;
  IDLE)
    [[ "$SPAWN_PHASE" == "PLAN" ]] && ALLOWED=true
    ;;
esac

if [[ "$ALLOWED" == false ]]; then
  source "${HARNESS_HOOK_DIR}/lib/write_error.sh"
  log_hook_error "HOOK_BLOCK_PIPELINE_ORDER" "Agent" "파이프라인 순서 위반: 현재=${STATE}, spawn시도=${SPAWN_PHASE} (진입 기반: STATE==SPAWN_PHASE 필수)" "$SESSION_ID"
  REASON="❌ 파이프라인 순서 위반! 현재 상태=${STATE}에서 ${SPAWN_PHASE} spawn 불가. 진입 기반: spawn 직전에 mcp__oio__session_state(uuid=\"\${UUID}\", key=\"state\", value=\"${SPAWN_PHASE}\") 실행 필수."
  echo "{\"decision\":\"block\",\"reason\":\"${REASON}\"}" | tee /dev/stderr
  exit 2
fi

exit 0
