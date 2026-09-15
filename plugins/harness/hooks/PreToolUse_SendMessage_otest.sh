#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# PreToolUse: SendMessage — otest 에이전트의 완료 보고 시 otest_done 마커 검증
# matcher: SendMessage (otest-N 에이전트만 대상)

# lib 로드
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/session_id.sh" 2>/dev/null || true

# 메시지 내용 확인 (완료/PASS 키워드 포함 시만 검증)
TOOL_INPUT=$(cat)

# 에이전트 이름 확인 (otest-N 에이전트만 적용)
# CLAUDE_AGENT_NAME 환경변수는 신뢰 불가 — stdin JSON .agent_name 직접 파싱
AGENT_NAME=$(echo "$TOOL_INPUT" | jq -r '.agent_name // empty' 2>/dev/null || echo "")
if [[ ! "$AGENT_NAME" =~ ^otest- ]]; then
  exit 0
fi
MESSAGE=$(echo "$TOOL_INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('message',''))" 2>/dev/null || echo "")

# 완료 보고가 아니면 통과
if ! echo "$MESSAGE" | grep -qiE "(완료|PASS|otest.*done|검증.*완료)"; then
  exit 0
fi

# UUID 결정
UUID=$(resolve_uuid "$TOOL_INPUT" 2>/dev/null || echo "")
if [[ -z "$UUID" ]]; then
  exit 0
fi

SESSION_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/$UUID"
OTEST_DONE="$SESSION_DIR/evidence/otest_done"

# hook input session_id 기록 (메인 vs hook session_id 추적 — 2순위 사전 진단용)
_INPUT_SID=$(echo "$TOOL_INPUT" | jq -r '.session_id // empty' 2>/dev/null)
if [[ -n "$_INPUT_SID" && -d "$SESSION_DIR" ]]; then
  mkdir -p "${SESSION_DIR}/logs"
  echo "$(date '+%Y-%m-%d %H:%M:%S') [PreToolUse_SendMessage_otest] input_session_id=${_INPUT_SID} resolved_uuid=${UUID}" \
    >> "${SESSION_DIR}/logs/hook_input_session_id.log"
  # 사이클46 축① — 로그 미러
  source "${HARNESS_HOOK_DIR}/lib/session_mirror.sh" 2>/dev/null
  type _mirror_file >/dev/null 2>&1 && _mirror_file "${SESSION_DIR}/logs/hook_input_session_id.log"
fi

if [[ ! -f "$OTEST_DONE" ]]; then
  # 2차: prompt UUID 폴백 시도 (§(b) 소유권 증명 통과 시만 채택)
  SM_FALLBACK_UUID=$(resolve_uuid_from_prompt "$TOOL_INPUT")
  if [[ -n "$SM_FALLBACK_UUID" && "$SM_FALLBACK_UUID" != "$UUID" ]]; then
    SM_FALLBACK_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${SM_FALLBACK_UUID}"
    if [[ -f "${SM_FALLBACK_DIR}/evidence/otest_done" ]]; then
      # 폴백 성공: SESSION_DIR 교체 + uuid_fallback.log 기록
      mkdir -p "${SM_FALLBACK_DIR}/logs"
      echo "$(date '+%Y-%m-%d %H:%M:%S') [PreToolUse_SendMessage_otest] uuid_fallback adopted=${SM_FALLBACK_UUID} input_sid=${UUID} agent=${AGENT_NAME}" \
        >> "${SM_FALLBACK_DIR}/logs/uuid_fallback.log"
      SESSION_DIR="$SM_FALLBACK_DIR"
      UUID="$SM_FALLBACK_UUID"
      OTEST_DONE="$SESSION_DIR/evidence/otest_done"
    fi
  fi
fi

if [[ ! -f "$OTEST_DONE" ]]; then
  cat <<'EOF'
{"decision":"block","reason":"❌ otest_done 마커 미생성! SendMessage로 완료 보고 전에 evidence/otest_done 파일을 먼저 생성하세요.\n예: mcp__oio__file_write(path=\"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/evidence/otest_done\", content=\"PASS $(date -Iseconds)\", overwrite=true)"}
EOF
  exit 2
fi

exit 0
