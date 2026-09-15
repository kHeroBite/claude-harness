#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# mcp_disconnect_guard.sh — MCP 도구 실패 시 끊김 감지 + 상태 파일 기록 + 사용자 알림
# PostToolUse hook: matcher=mcp__oio__*
# 동작: oio MCP 도구가 연결 끊김 에러 반환 시 ~/.claude/.mcp_disconnect 기록

set -uo pipefail

DISCONNECT_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.mcp_disconnect"

INPUT=$(timeout 5 cat 2>/dev/null) || INPUT=""

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || echo "")

# PostToolUse 응답에서 오류 여부 확인
IS_ERROR=$(echo "$INPUT" | jq -r '.tool_response.is_error // false' 2>/dev/null || echo "false")

if [[ "$IS_ERROR" != "true" ]]; then
  # 성공 시 해당 서버의 끊김 기록 제거
  if [[ -f "$DISCONNECT_FILE" ]] && [[ -n "$TOOL_NAME" ]]; then
    # 서버명 추출 (mcp__oio__bash_exec → oio)
    SERVER=$(echo "$TOOL_NAME" | sed 's/^mcp__\([^_]*\)__.*/\1/')
    python3 -c "
import json, sys
try:
    d = json.load(open('$DISCONNECT_FILE'))
    if '$SERVER' in d:
        del d['$SERVER']
        json.dump(d, open('$DISCONNECT_FILE','w'))
except: pass
" 2>/dev/null || true
  fi
  exit 0
fi

# 에러 내용 확인
CONTENT=$(echo "$INPUT" | jq -r '.tool_response.content // ""' 2>/dev/null || echo "")

# MCP 연결 끊김 패턴 감지
if echo "$CONTENT" | grep -qiE "(connection|disconnect|refused|broken pipe|transport|closed|EOF|reset)"; then
  # 서버명 추출 (mcp__oio__bash_exec → oio)
  SERVER=$(echo "$TOOL_NAME" | sed 's/^mcp__\([^_]*\)__.*/\1/')

  # 끊김 상태 파일 기록
  python3 -c "
import json, time
try:
    d = json.load(open('$DISCONNECT_FILE')) if __import__('os').path.exists('$DISCONNECT_FILE') else {}
except: d = {}
d['$SERVER'] = {'tool': '$TOOL_NAME', 'time': time.time()}
json.dump(d, open('$DISCONNECT_FILE','w'))
" 2>/dev/null || true

  echo "⚠️ [MCP 끊김 감지] ${TOOL_NAME} 호출 실패 — ${SERVER} MCP 서버 연결이 끊어졌습니다."
  echo "조치: /mcp 명령으로 재연결하세요."
fi

exit 0
