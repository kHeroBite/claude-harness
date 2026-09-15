#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# oinfra_main_guard.sh — 메인 에이전트의 oinfra_* 직접 호출 차단
# PreToolUse:Skill — oinfra_* 스킬 감지
# 메인 에이전트(PIPELINE_UUID 없음)가 oinfra_*를 호출하면 차단
# 예외: /ocontext (ocontext가 프로젝트 컨텍스트 로딩 목적으로 호출)

trap 'exit 0' ERR

# F-NEW-3: flock 기반 state_read() 로드
source "${HARNESS_HOOK_DIR}/lib/session_id.sh" 2>/dev/null || true

INPUT=$(timeout 5 cat 2>/dev/null) || INPUT=""
SKILL=$(echo "$INPUT" | jq -r '(.tool_input.skill // .tool_input.skill_name // empty)' 2>/dev/null || echo "")

# oinfra_* 스킬만 처리
case "$SKILL" in
  oinfra_*) ;;
  *) exit 0 ;;
esac

# 팀에이전트(PIPELINE_UUID 있음) → 허용
if [[ -n "${PIPELINE_UUID:-}" ]]; then
  exit 0
fi

# 조상 프로세스에 --agent-id 있으면 팀에이전트 → 허용
_WALK=$$
while true; do
  _WALK=$(ps -o ppid= -p "$_WALK" 2>/dev/null | tr -d ' ')
  [[ -z "$_WALK" || "$_WALK" -le 1 ]] && break
  if cat /proc/"$_WALK"/cmdline 2>/dev/null | tr '\0' ' ' | grep -q -- '--agent-id'; then
    exit 0
  fi
done

# 세션 상태 확인
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
_STATE=$(state_read "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${SESSION_ID}/state" 2>/dev/null | awk '{print $1}' || echo "IDLE")  # F-NEW-3

# IDLE 상태 + /ocontext 맥락 → 허용 (ocontext의 Step 2.5 프로젝트 컨텍스트 로딩)
# PLAN/DEV/TEST 활성 중 메인이 호출 → 차단
case "${_STATE:-IDLE}" in
  PLAN|DEV|TEST)
    echo "{\"decision\":\"block\",\"reason\":\"❌ 메인 에이전트는 파이프라인 활성(${_STATE}) 중 Skill('${SKILL}')를 직접 호출할 수 없습니다.\\n\\n이 스킬은 팀에이전트 프롬프트 문자열에 포함시킬 텍스트입니다.\\n메인이 직접 실행하는 것이 아니라 팀에이전트 spawn 시 prompt= 인수 안에 넣으세요.\"}" | tee /dev/stderr
    exit 2
    ;;
  *)
    # IDLE/DONE/FINISH → ocontext 맥락이므로 허용
    exit 0
    ;;
esac
