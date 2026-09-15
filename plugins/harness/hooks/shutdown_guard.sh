#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# shutdown_guard.sh — 빌드/배포 외 상황에서 shutdown/taskkill 차단 (L-036)
# PreToolUse:Bash hook
# 원본: prebuild_shutdown.sh에서 L-036 가드만 분리 (dotnet build 전처리 로직 제거 — oio bash_exec 전환으로 도달 불가)

trap 'exit 0' ERR
INPUT=$(timeout 5 cat 2>/dev/null) || INPUT=""
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")

[ -z "$COMMAND" ] && exit 0

# shutdown/taskkill 명령인지 확인
if ! echo "$COMMAND" | grep -qiE "api/shutdown|taskkill.*/IM\s"; then
  exit 0
fi

# dotnet build와 함께 실행되는 경우 허용 (빌드 전 정리)
if echo "$COMMAND" | grep -q "dotnet build"; then
  exit 0
fi

# UUID 기반 세션별 state 파일에서 확인
source ${HARNESS_HOOK_DIR}/lib/session_id.sh 2>/dev/null || true
resolve_uuid "$INPUT" 2>/dev/null || UUID="${SESSION_ID}"
[[ -z "$UUID" ]] && exit 0
STATE=$(state_read "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/state" | awk '{print $1}')
STATE=${STATE:-IDLE}

# DEV/TEST/IDLE에서 허용. PLAN/DONE/FINISH에서는 차단 (Phase B: state=OK 제거 — L-431)
if [[ "$STATE" != "DEV" && "$STATE" != "TEST" && "$STATE" != "IDLE" ]]; then
  source ${HARNESS_HOOK_DIR}/lib/write_error.sh
  log_hook_error "HOOK_BLOCK_SHUTDOWN_L036" "Bash" "빌드 외 상황에서 shutdown/taskkill 시도 (파이프라인: $STATE)" "$SESSION_ID"
  echo '{"decision":"block","reason":"🚫 [L-036] shutdown/taskkill은 빌드/배포 단계에서만 허용됩니다."}' | tee /dev/stderr
  exit 2
fi

exit 0
