#!/bin/bash
# autoloop_bypass_guard.sh — Phase Batch Auto-Loop 우회 감지 hook
# PreToolUse(Agent) 발동 — odev 팀에이전트 spawn 시 검증
#
# 배경 (2026-04-05 재발방지):
#   - o4/o5 tier에서 oplan이 phase_batches.json을 생성하면 ok_pipeline 4.5단계가
#     "Phase Batch Auto-Loop"으로 자동 순차 실행을 책임짐.
#   - 메인이 이를 우회하고 직접 odev 순차 spawn → state 전파/checkpoint 누락 →
#     odone 미실행으로 Auto-Loop 미발동 → 중간 중단 시 전체 손실.
#
# 감지 조건:
#   1. PreToolUse tool=Agent + subagent_type 포함
#   2. 현재 UUID의 plans/phase_batches.json 존재
#   3. state가 DEV/PLAN이 아님 (즉, 4.5단계 정식 spawn 아닌 상황)
#
# 동작:
#   - 우회 감지 시 차단 (exit 2). 정상 경로(state=DEV)에서는 통과.

trap 'exit 0' ERR
INPUT=$(timeout 5 cat 2>/dev/null) || exit 0

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
[[ "$TOOL_NAME" != "Agent" ]] && exit 0

# subagent_type 추출
SUBAGENT=$(echo "$INPUT" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null)
DESC=$(echo "$INPUT" | jq -r '.tool_input.description // empty' 2>/dev/null)
AGENT_NAME=$(echo "$INPUT" | jq -r '.tool_input.name // empty' 2>/dev/null)

# L-597 과차단 정정(2026-10-26): name 이 otest·odone·oplan(oplan_review 포함) 계열이면 odev 우회 spawn 이 아니다.
#   state=TEST 정상 순서의 otest-1("Batch1 검증") spawn 을 description 의 batch 단어만으로 차단하던 오판을 막는다. name 이 odev 계열·빈값이면 종전 판정.
if [[ "$AGENT_NAME" =~ ^(otest(-|$)|otest-m-|otest-w-|odone(-|$)|oplan) ]]; then
  exit 0
fi

# odev 관련 spawn만 검사 (odev/odev-*, Batch 관련 description)
if ! echo "$DESC" | grep -qiE "batch|odev|oplan|phase" 2>/dev/null; then
  exit 0
fi
# c183 B8: 계획 에이전트(oplan) spawn 은 batch 실행이 아니다 — TEST/PLAN 역라우팅 재계획을 막던 과차단(L-1186·L-1193).
#   설명에 oplan 이 있고 실행 성격 단어(odev·batch)가 없을 때만 통과. odev/batch 가 함께 있으면 종전대로 판정한다.
if echo "$DESC" | grep -qiE "oplan" 2>/dev/null && ! echo "$DESC" | grep -qiE "odev|batch" 2>/dev/null; then
  exit 0
fi

# UUID 결정
source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/session_id.sh" 2>/dev/null || exit 0
source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/state_machine.sh" 2>/dev/null || true
resolve_uuid "$INPUT" 2>/dev/null || exit 0
[[ -z "$UUID" ]] && exit 0

SESSION_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}"
PHASE_FILE="${SESSION_DIR}/plans/phase_batches.json"
CURRENT_BATCH_FILE="${SESSION_DIR}/current_phase_batch"
STATE_FILE="${SESSION_DIR}/state"

# phase_batches.json 없으면 스킵 (단일 batch 모드)
[[ ! -f "$PHASE_FILE" ]] && exit 0

# 상태 확인
# F6: state_read 경유. __LOCK_FAIL__ 시 guard skip.
STATE=$(state_read "$STATE_FILE" 2>/dev/null | awk '{print $1}' || echo "")
[[ "$STATE" == "__LOCK_FAIL__" ]] && exit 0
CURRENT=$(cat "$CURRENT_BATCH_FILE" 2>/dev/null | tr -d '[:space:]' || echo "")
TOTAL=$(jq -r '.total_batches // 0' "$PHASE_FILE" 2>/dev/null || echo 0)

# 이미 완료되었거나 특수값이면 스킵
[[ "$CURRENT" == "DONE" ]] && exit 0
STATUS_FILE="${SESSION_DIR}/status"
if status_has "$STATUS_FILE" ABORT 2>/dev/null || status_has "$STATUS_FILE" PAUSE 2>/dev/null; then exit 0; fi
[[ "$CURRENT" =~ ^[0-9]+$ ]] && [[ "$CURRENT" -ge "$TOTAL" ]] && exit 0

# 정상 경로: ok_pipeline 4.5단계에서 spawn → state=DEV 유지
# 우회 경로: state가 DEV가 아니거나 batch 진행 중인데 수동 spawn

if [[ "$STATE" != "DEV" ]]; then
  echo "🚫 [Auto-Loop 우회 차단] Phase Batch 진행 중(${CURRENT:-?}/${TOTAL})인데 state=${STATE:-빈값}" >&2
  echo "   → ok_pipeline 4.5단계가 아닌 경로로 odev spawn 시도 감지" >&2
  echo "   → '$DESC'" >&2
  echo "   → 정상 경로: ok_pipeline이 odev→otest→odone→ok_pipeline 4.5단계(자동 재진입)" >&2
  echo "   → 메인이 직접 batch 순차 실행 시 Auto-Loop 미발동 + 중간 중단 시 손실 위험" >&2
  echo "   → 승인 없이는 진행 불가: ok_pipeline 4.5단계를 통해 정상 경로로 실행하십시오" >&2
  exit 2
fi

exit 0
