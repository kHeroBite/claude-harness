#!/usr/bin/env bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# oio_fallback_guard.sh — PostToolUse: mcp__oio__bash_exec 실패 시 oio_bash_failed 플래그 설정
# 역할: oio bash_exec 실패를 감지하여 write_guard.sh의 fallback 허용 조건 설정

set -euo pipefail

# 입력: STDIN에서 JSON 읽기 (PostToolUse hook은 tool result JSON을 stdin으로 전달)
INPUT=$(cat)

# tool_use_id 및 실패 여부 파악
IS_ERROR=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    # PostToolUse의 tool_response 구조
    result = d.get('tool_response', {})
    if result.get('is_error', False):
        print('true')
        sys.exit(0)
    # mcp__oio__bash_exec의 success 필드 확인
    content = result.get('content', '')
    if isinstance(content, str):
        try:
            inner = json.loads(content)
            if not inner.get('success', True):
                print('true')
                sys.exit(0)
        except:
            pass
    print('false')
except Exception as e:
    print('false')
" 2>/dev/null || echo "false")

if [ "$IS_ERROR" = "true" ]; then
    # oio bash_exec 실패 플래그 설정 (write_guard.sh가 참조)
    # session_id.sh의 resolve_uuid로 UUID 결정
    source "${HARNESS_HOOK_DIR}/lib/session_id.sh"
    if resolve_uuid "$INPUT" 2>/dev/null && [ -n "${UUID:-}" ]; then
        touch "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/oio_bash_failed" 2>/dev/null || true
    fi
    # 전역 fallback 플래그 (UUID 미확인 시)
    touch "/tmp/oio_bash_failed_$$" 2>/dev/null || true
fi

exit 0
