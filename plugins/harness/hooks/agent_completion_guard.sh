#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# agent_completion_guard.sh — PostToolUse(Agent) hook
# Agent 반환 시 완료 보고 검증. warn only — 자동 kill 안 함.

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
[[ "$TOOL_NAME" != "Agent" ]] && exit 0

# [P2-isolation] CLAUDE.md §세션 격리 불변식 §(a)/(c) 준수.
# ls -td session-env/*/ 패턴 제거 — 타 세션 UUID가 가장 최근 디렉토리로 선택될 수 있음.
# $INPUT의 session_id 필드에서 직접 UUID를 추출하여 자기 세션 경로만 참조.
source "${HARNESS_HOOK_DIR}/lib/session_id.sh" 2>/dev/null || true
if ! resolve_uuid "$INPUT" 2>/dev/null; then
  exit 0
fi

SESSION_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}"
[[ -d "$SESSION_DIR" ]] || exit 0

PLANS_DIR="${SESSION_DIR}/plans"
if [[ -d "$PLANS_DIR" ]]; then
    PLAN_COUNT=$(ls "$PLANS_DIR"/*.md 2>/dev/null | wc -l)
    if [[ $PLAN_COUNT -eq 0 ]]; then
        echo '{"decision":"warn","message":"⚠️ [agent_completion_guard] Agent 반환: plans/ 비어있음. 완료 보고 누락 의심"}'
        exit 0
    fi
fi

exit 0
