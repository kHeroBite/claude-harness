#!/bin/bash
# ofinish_recurse_guard.sh — PreToolUse:Skill hook
# 목적: FINISH 상태에서 Skill('ofinish') 재귀 호출 차단
# 트리거: PreToolUse:Skill (ofinish* 호출 시)

trap 'exit 0' ERR
INPUT=$(timeout 5 cat 2>/dev/null) || INPUT=""
SKILL_NAME=$(echo "$INPUT" | jq -r '(.tool_input.skill // .tool_input.skill_name // empty)' 2>/dev/null)
SKILL_NAME="${SKILL_NAME##*:}"  # 플러그인 접두사(harness:ofinish → ofinish) 정규화

# ofinish 계열만 처리
case "$SKILL_NAME" in
  ofinish*) ;;
  *) exit 0 ;;
esac

# UUID 결정
source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/session_id.sh"
resolve_uuid "$INPUT" || exit 0
[[ -z "$UUID" ]] && exit 0

# 팀에이전트/서브에이전트 스킵
if [[ -n "${PIPELINE_UUID:-}" && "${PIPELINE_UUID:-}" != "$MY_UUID" ]] || \
   [[ "$MY_UUID" != "$UUID" ]]; then
  exit 0
fi

SESSION_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}"
STATE_FILE="${SESSION_DIR}/state"

[[ -f "$STATE_FILE" ]] || exit 0
# F6: state_read 경유. __LOCK_FAIL__ 시 guard skip (차단 보수).
CURRENT_STATE=$(state_read "$STATE_FILE" 2>/dev/null | awk '{print $1}')
[[ "$CURRENT_STATE" == "__LOCK_FAIL__" ]] && exit 0

# FINISH 상태 + ofinish_done 마커 존재 시에만 재귀 차단
OFINISH_DONE="${SESSION_DIR}/evidence/ofinish_done"
if [[ "$CURRENT_STATE" == "FINISH" && -f "$OFINISH_DONE" ]]; then
  # oroof 루프 진행 중(status=ROOF)이면 재귀 차단 면제 — 정상 반복 동작
  source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/state_machine.sh"
  STATUS_FILE="${SESSION_DIR}/status"
  if status_has "$STATUS_FILE" "ROOF" 2>/dev/null; then  # ROOF-COMPAT(deprecation window 1주기 — 구 RALPH/oralph_active 인식 제거 예정): status_has 가 ROOF/RALPH 별칭 처리
    exit 0
  fi
  echo "{\"decision\":\"block\",\"reason\":\"🚫 ofinish 재귀 차단: ofinish_done 마커 존재 — 이미 완료된 파이프라인입니다. 새 작업은 /ok로 시작하세요.\"}"
  exit 2
fi

exit 0
