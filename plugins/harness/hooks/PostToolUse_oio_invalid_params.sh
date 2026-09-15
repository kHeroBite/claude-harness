#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# PostToolUse_oio_invalid_params.sh — oio 도구 "Invalid tool parameters" 감지 시 파이프라인 강제 중단
# PostToolUse hook: matcher=mcp__oio__*
# 동작: oio 도구 응답에 "Invalid tool parameters" 포함 + 파이프라인 활성 상태 시
#       evidence/aborted 마커 생성 + state→IDLE 강제 전환 + 사용자 알림

set -uo pipefail
trap 'exit 0' ERR

INPUT=$(timeout 5 cat 2>/dev/null) || INPUT=""

# 에러 여부 확인 (fast path: 에러 아니면 즉시 종료)
IS_ERROR=$(echo "$INPUT" | jq -r '.tool_response.is_error // false' 2>/dev/null || echo "false")
if [[ "$IS_ERROR" != "true" ]]; then
  exit 0
fi

# 오류 내용에 "Invalid tool parameters" 포함 여부 확인
CONTENT=$(echo "$INPUT" | jq -r '.tool_response.content // ""' 2>/dev/null || echo "")
if ! echo "$CONTENT" | grep -qF "Invalid tool parameters"; then
  exit 0
fi

# tool_name 추출 (알림용)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "mcp__oio__?"' 2>/dev/null || echo "mcp__oio__?")

# UUID 결정 (세션격리: 자기 세션만 write)
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/session_id.sh" 2>/dev/null || exit 0
if ! resolve_uuid "$INPUT" 2>/dev/null; then
  exit 0
fi
[[ -z "${UUID:-}" ]] && exit 0

CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SESSION_DIR="$CLAUDE_CONFIG_DIR/session-env/$UUID"
STATE_FILE="$SESSION_DIR/state"

# state_machine.sh 로드
source "$HOOK_DIR/lib/state_machine.sh" 2>/dev/null || exit 0

# 현재 state 읽기
CURRENT_STATE=$(state_current "$STATE_FILE" 2>/dev/null || echo "IDLE")
if [[ "$CURRENT_STATE" == "__LOCK_FAIL__" ]]; then
  exit 0
fi

# 파이프라인 활성 상태 확인 (OK/PLAN/DEV/TEST/DONE)
case "$CURRENT_STATE" in
  OK|PLAN|DEV|TEST|DONE) : ;;  # 활성 — 계속 처리
  *) exit 0 ;;                  # 비활성 — 스킵
esac

# evidence/aborted 마커 생성
EVIDENCE_DIR="$SESSION_DIR/evidence"
mkdir -p "$EVIDENCE_DIR" 2>/dev/null || true

TIMESTAMP=$(date -u '+%Y%m%dT%H%M%SZ')
MARKER_FILE="$EVIDENCE_DIR/aborted_invalid_params_${TIMESTAMP}.json"

python3 -c "
import json, sys
data = {
    'type': 'oio_invalid_params',
    'timestamp': '$TIMESTAMP',
    'tool_name': '$TOOL_NAME',
    'state_at_abort': '$CURRENT_STATE',
    'uuid': '$UUID',
    'content_snippet': $(echo "$CONTENT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()[:500]))' 2>/dev/null || echo '\"\"')
}
json.dump(data, open('$MARKER_FILE', 'w'), ensure_ascii=False, indent=2)
" 2>/dev/null || true

# state → IDLE 강제 전환 (CAS 기반 — L-362 준수)
state_transition "$STATE_FILE" "$CURRENT_STATE" "IDLE" "oio_invalid_params" "$UUID" 2>/dev/null || true

# 사용자 알림
echo "🚨 [파이프라인 강제 중단] ${TOOL_NAME} — Invalid tool parameters 오류 감지"
echo "   파이프라인 state: ${CURRENT_STATE} → IDLE (강제 전환)"
echo "   aborted 마커: ${MARKER_FILE}"
echo "   원인: oio 도구 파라미터가 잘못되었습니다. 도구 호출 인자를 확인하세요."

exit 0
