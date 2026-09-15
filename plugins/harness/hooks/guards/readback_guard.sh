#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# readback_guard.sh — PostToolUse hook (mcp__oio__file_write|mcp__oio__file_edit)
# oio 서버 self-verify와 독립적인 2차 안전망. warn only.
# oio MCP 경유 금지 — cat 직접 I/O만 사용.

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
[[ -z "$TOOL_NAME" ]] && exit 0

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.path // .tool_input.file_path // empty')
[[ -z "$FILE_PATH" || ! -f "$FILE_PATH" ]] && exit 0

FILE_SIZE=$(stat -c %s "$FILE_PATH" 2>/dev/null || echo 0)
if [[ $FILE_SIZE -gt 1048576 ]]; then
    exit 0
fi

TOOL_SUCCESS=$(echo "$INPUT" | jq -r '.tool_output.success // "true"')
if [[ "$TOOL_SUCCESS" == "false" ]]; then
    exit 0
fi

if [[ "$TOOL_NAME" == *"file_edit"* ]]; then
    NEW_STRING=$(echo "$INPUT" | jq -r '.tool_input.new_string // .tool_input.new_text // empty')
    if [[ -n "$NEW_STRING" ]]; then
        if ! timeout 3 grep -qF "$NEW_STRING" "$FILE_PATH" 2>/dev/null; then
            echo '{"decision":"warn","message":"⚠️ [readback_guard] file_edit 후 new_string 미발견. oio self-verify 결과 확인 요망."}'
            exit 0
        fi
    fi
fi

if [[ "$TOOL_NAME" == *"file_write"* ]]; then
    EXPECTED_SIZE=$(echo "$INPUT" | jq -r '.tool_output.bytes_written // empty')
    if [[ -n "$EXPECTED_SIZE" && "$EXPECTED_SIZE" != "$FILE_SIZE" ]]; then
        echo '{"decision":"warn","message":"⚠️ [readback_guard] file_write 크기 불일치: expected='"$EXPECTED_SIZE"' actual='"$FILE_SIZE"'"}'
        exit 0
    fi
fi

exit 0
