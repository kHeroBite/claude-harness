#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# Notification(Stop) — compact 시작 전 체크포인트 저장 (Phase 2 — L-111/L-112)
# 메인 에이전트와 팀에이전트 모두에서 실행됨

# ── UUID 결정 (세션 격리 v4) ──
trap 'exit 0' ERR  # M-01: 에러 시 조용히 종료 (compact는 best-effort)
INPUT=$(timeout 5 cat 2>/dev/null) || INPUT=""
MY_SID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
[[ -z "$MY_SID" ]] && exit 0
MY_UUID="$MY_SID"

# PIPELINE_UUID 환경변수 기반 메인/팀 판별
if [[ -n "${PIPELINE_UUID:-}" && "${PIPELINE_UUID:-}" != "$MY_UUID" ]]; then
  IS_TEAM="true"
  UUID="${PIPELINE_UUID}"
else
  IS_TEAM="false"
  UUID="$MY_UUID"
fi
SID="$UUID"
export SID UUID
SESSION_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}"

# state_read/state_write 함수 로드 (flock 기반 원자적 읽기/쓰기)
# shellcheck source=/dev/null
source "${HARNESS_HOOK_DIR}/lib/session_id.sh" 2>/dev/null || true

# ── 체크포인트 파일 경로 ──
mkdir -p "${SESSION_DIR}/compact"
if [[ "$IS_TEAM" = "true" ]]; then
  SAVE_FILE="${SESSION_DIR}/compact/state_${MY_UUID}.txt"
else
  SAVE_FILE="${SESSION_DIR}/compact/state.txt"
fi

# ── 기본 정보 저장 ──
echo "compact_time=$(date '+%Y-%m-%d %H:%M:%S')" > "$SAVE_FILE"
echo "is_team=$IS_TEAM" >> "$SAVE_FILE"
echo "my_uuid=$MY_UUID" >> "$SAVE_FILE"

# pipeline state (flock 기반 state_read 사용 — race condition 방지)
PIPELINE_STATE=$(state_read "${SESSION_DIR}/state" 2>/dev/null || echo "IDLE")
# __LOCK_FAIL__ 시 IDLE 저장 금지 — IDLE 저장 시 compact 복원 후 파이프라인 state 오염됨
# ACTIVE_UNKNOWN으로 저장 → compact 복원 후 oresume으로 재개하도록 안내
[[ "$PIPELINE_STATE" == "__LOCK_FAIL__" ]] && PIPELINE_STATE="ACTIVE_UNKNOWN"
echo "pipeline_state=$PIPELINE_STATE" >> "$SAVE_FILE"

# ── Phase 2 확장: 파이프라인 상세 상태 ──
CLASSIFICATION=$(cat "${SESSION_DIR}/classification" 2>/dev/null || echo "unknown")
echo "task_classification=$CLASSIFICATION" >> "$SAVE_FILE"

CONV_ID=$(cat "${SESSION_DIR}/conv_id" 2>/dev/null || echo "")
echo "conv_id=$CONV_ID" >> "$SAVE_FILE"

if [[ -f "${SESSION_DIR}/team_name" ]]; then
  TEAM_NAME_VALUE=$(cat "${SESSION_DIR}/team_name" 2>/dev/null || echo "")
  echo "team_created=true" >> "$SAVE_FILE"
  echo "team_name_value=${TEAM_NAME_VALUE}" >> "$SAVE_FILE"
else
  echo "team_created=false" >> "$SAVE_FILE"
fi

USER_REQ=$(cat "${SESSION_DIR}/user_request" 2>/dev/null || echo "")
echo "user_request=$USER_REQ" >> "$SAVE_FILE"

if [[ -n "$CONV_ID" ]]; then
  OPLAN_FILE=$(ls ${SESSION_DIR}/plans/oplan_${CONV_ID}*.md 2>/dev/null | head -1)
  echo "oplan_result=${OPLAN_FILE:-}" >> "$SAVE_FILE"
fi

# 역라우팅 카운터
REROUTE_COUNT=$(cat "${SESSION_DIR}/reroute_count" 2>/dev/null || echo "0")
echo "reroute_counter=$REROUTE_COUNT" >> "$SAVE_FILE"

# 증거 파일 상태
for EVIDENCE in build deploy run quality; do
  if [[ -f "${SESSION_DIR}/evidence/${EVIDENCE}_ok" ]]; then
    echo "evidence_${EVIDENCE}=Y" >> "$SAVE_FILE"
  else
    echo "evidence_${EVIDENCE}=N" >> "$SAVE_FILE"
  fi
done

# ── Phase E: checkpoint 진행도 백업 ──
if [[ -f "${SESSION_DIR}/checkpoint.jsonl" ]]; then
  echo "checkpoint_exists=true" >> "$SAVE_FILE"
  # 마지막 5줄 백업 (세밀한 진행도 복원용)
  CKPT_TAIL=$(tail -5 "${SESSION_DIR}/checkpoint.jsonl" 2>/dev/null || echo "")
  echo "checkpoint_tail_start" >> "$SAVE_FILE"
  echo "$CKPT_TAIL" >> "$SAVE_FILE"
  echo "checkpoint_tail_end" >> "$SAVE_FILE"
  # 마지막 이벤트 요약
  LAST_EVENT=$(tail -1 "${SESSION_DIR}/checkpoint.jsonl" 2>/dev/null | sed 's/.*"event":"\([^"]*\)".*/\1/' || echo "")
  LAST_STAGE=$(tail -1 "${SESSION_DIR}/checkpoint.jsonl" 2>/dev/null | sed 's/.*"stage":"\([^"]*\)".*/\1/' || echo "")
  echo "checkpoint_last_event=$LAST_EVENT" >> "$SAVE_FILE"
  echo "checkpoint_last_stage=$LAST_STAGE" >> "$SAVE_FILE"
else
  echo "checkpoint_exists=false" >> "$SAVE_FILE"
fi

# work/ 결과 파일 목록
if [[ -d "${SESSION_DIR}/work" ]]; then
  WORK_FILES=$(ls "${SESSION_DIR}/work/"*_result.json 2>/dev/null | xargs -I{} basename {} || echo "")
  echo "work_results=${WORK_FILES}" >> "$SAVE_FILE"
fi
