#!/usr/bin/env bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# PreToolUse hook — Edit/Write 도구 호출 전에 audit_fs_lock.py + audit_lock_order.py 실행.
#
# 목적: session_manager.py 등 oio-mcp-server 코드가 수정되기 직전에
#       L-362 위반 및 역순 lock 획득을 정적 감사하여 위반이 이미
#       존재하는 상태라면 추가 수정 자체를 차단한다.
#
# 설치: .claude/settings.json PreToolUse matcher "Edit|Write|mcp__oio__file_write|mcp__oio__file_edit"
#       (등록은 odone 단계에서 처리)
#
# 종료 코드:
#   0 = 통과(감사 없음 또는 PASS)
#   1 = audit 실패 → 도구 호출 차단

set -u

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
OIO_DIR="${PROJECT_ROOT}/MCP-Servers/oio-mcp-server"
AUDIT_FS_LOCK="${OIO_DIR}/tools/audit_fs_lock.py"
AUDIT_LOCK_ORDER="${OIO_DIR}/tools/audit_lock_order.py"

# oio-mcp-server 파일이 아닌 도구 호출은 빠르게 통과
# Claude Code hook 입력은 stdin JSON으로만 전달됨 (CLAUDE_TOOL_INPUT 환경변수 없음)
INPUT=$(timeout 2 cat 2>/dev/null) || INPUT=""
TARGET_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // .tool_input.filepath // empty' 2>/dev/null) || TARGET_PATH=""
case "${TARGET_PATH}" in
  *"oio-mcp-server"*) ;;
  *) exit 0 ;;
esac

if [[ ! -x "$(command -v python3)" ]]; then
  echo "[lock_order_audit] python3 없음 — 감사 건너뜀" >&2
  exit 0
fi

FAIL=0

if [[ -f "${AUDIT_FS_LOCK}" ]]; then
  if ! python3 "${AUDIT_FS_LOCK}" "${OIO_DIR}/session_manager.py"; then
    FAIL=1
  fi
else
  echo "[lock_order_audit] audit_fs_lock.py 없음 — 감사 건너뜀" >&2
fi

if [[ -f "${AUDIT_LOCK_ORDER}" ]]; then
  if ! python3 "${AUDIT_LOCK_ORDER}"; then
    FAIL=1
  fi
else
  echo "[lock_order_audit] audit_lock_order.py 없음 — 감사 건너뜀" >&2
fi

if [[ ${FAIL} -ne 0 ]]; then
  echo "[lock_order_audit] 🚨 L-362/lock ordering 위반 감지 — 도구 호출 차단" >&2
  exit 1
fi

exit 0
