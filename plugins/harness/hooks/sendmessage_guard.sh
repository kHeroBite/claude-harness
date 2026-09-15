#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# sendmessage_guard.sh — SendMessage에서 summary 누락 방지
# PreToolUse:SendMessage 매처

INPUT=$(timeout 2 cat 2>/dev/null) || INPUT=""
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || TOOL_NAME=""

[[ "$TOOL_NAME" != "SendMessage" ]] && exit 0

# message 타입 확인: 문자열이면 summary 필수
MSG_TYPE=$(echo "$INPUT" | jq -r '.tool_input.message | type' 2>/dev/null) || MSG_TYPE=""
if [[ "$MSG_TYPE" == "string" ]]; then
  SUMMARY=$(echo "$INPUT" | jq -r '.tool_input.summary // empty' 2>/dev/null) || SUMMARY=""
  if [[ -z "$SUMMARY" ]]; then
    echo '{"decision":"block","reason":"❌ SendMessage에 summary 누락! message가 문자열일 때 summary는 필수입니다. 예: SendMessage(to:\"리더명\", message:\"내용\", summary:\"5~10단어 요약\")"}'
    exit 2
  fi
fi

exit 0
