#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# mysql_korean_guard.sh — MCP MySQL 한글 차단 (L-024)
# PreToolUse hook: mcp__mysql__query/execute의 SQL에 한글 포함 시 차단
# latin1 연결에서 한글 alias/값 사용 시 구문 오류 발생 방지

trap 'exit 0' ERR

INPUT=$(timeout 5 cat 2>/dev/null) || INPUT=""
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
SQL=$(echo "$INPUT" | jq -r '.tool_input.sql // empty' 2>/dev/null || echo "")

if [ -z "$SQL" ]; then
  exit 0
fi

if echo "$SQL" | grep -P '[\x{AC00}-\x{D7AF}\x{3130}-\x{318F}]' > /dev/null 2>&1; then
  TOOL_FOR_LOG=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || echo "")
  source ${HARNESS_HOOK_DIR}/lib/write_error.sh
  log_hook_error "HOOK_BLOCK_MYSQL_KOREAN" "$TOOL_FOR_LOG" "MCP MySQL SQL에 한글 포함: ${SQL:0:100}" "$SESSION_ID"
  echo "{\"decision\":\"block\",\"reason\":\"🚫 [L-024] MCP MySQL SQL에 한글 포함. latin1 연결에서 한글 alias/값은 구문 오류 유발. alias는 영문만 사용 (as expired_count 등). SQL: ${SQL:0:80}\"}" | tee /dev/stderr
  exit 2
fi

exit 0
