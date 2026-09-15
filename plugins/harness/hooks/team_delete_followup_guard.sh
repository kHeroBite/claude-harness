#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# TeamDelete 후 잔존 정리 + 재시도 카운터 hook

# PostToolUse:TeamDelete 매처 — TeamDelete 도구 호출 직후 발동
# 목적: TeamDelete 후 teams/<name>/ 잔존 강제 정리 + 재시도 카운터 관리

set -euo pipefail
trap 'exit 0' ERR

INPUT=$(timeout 5 cat 2>/dev/null || echo "")
[[ -z "$INPUT" ]] && exit 0

# --- UUID 결정 ---
source "${HARNESS_HOOK_DIR}/lib/session_id.sh" 2>/dev/null || true
resolve_uuid "$INPUT" 2>/dev/null || true
[[ -z "${UUID:-}" ]] && exit 0

SESSION_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}"
LOG_FILE="${SESSION_DIR}/logs/team_delete_followup_guard.log"
mkdir -p "${SESSION_DIR}/logs" 2>/dev/null || true

# --- team_name 추출 (jq 우선, grep fallback) ---
TEAM_NAME=""
if command -v jq &>/dev/null; then
  TEAM_NAME=$(echo "$INPUT" | jq -r '.tool_input.team_name // empty' 2>/dev/null || echo "")
fi
if [[ -z "$TEAM_NAME" ]]; then
  # grep fallback
  TEAM_NAME=$(echo "$INPUT" | grep -oP '"team_name"\s*:\s*"\K[^"]+' 2>/dev/null | head -1 || echo "")
fi
[[ -z "$TEAM_NAME" ]] && exit 0

# --- TeamDelete 결과 확인 (에러 시 스킵) ---
TOOL_RESULT=$(echo "$INPUT" | jq -r '.tool_result.result // ""' 2>/dev/null || echo "")
if echo "$TOOL_RESULT" | grep -qi "error"; then
  exit 0
fi

# --- 재시도 카운터 관리 ---
RETRY_COUNT_FILE="${SESSION_DIR}/team_delete_retry_count"
RETRY_COUNT=0
if [[ -f "$RETRY_COUNT_FILE" ]]; then
  STORED_NAME=$(cat "$RETRY_COUNT_FILE" 2>/dev/null | awk '{print $1}' || echo "")
  STORED_COUNT=$(cat "$RETRY_COUNT_FILE" 2>/dev/null | awk '{print $2}' || echo "0")
  if [[ "$STORED_NAME" == "$TEAM_NAME" ]]; then
    RETRY_COUNT=$((STORED_COUNT + 1))
  else
    RETRY_COUNT=1
  fi
else
  RETRY_COUNT=1
fi
# 재시도 카운터 저장 (자기 UUID에만 쓰기 — 격리 §(b))
echo "$TEAM_NAME $RETRY_COUNT" > "$RETRY_COUNT_FILE" 2>/dev/null || true

TIMESTAMP=$(date -Iseconds 2>/dev/null || date)

# --- 3회 도달 시 hard warning (decision:warn — block 아님, 사용자 결정 존중) ---
if [[ $RETRY_COUNT -ge 3 ]]; then
  echo "⚠️ [team_delete_followup_guard] 재시도 ${RETRY_COUNT}회 도달: team='${TEAM_NAME}' — 수동 확인 필요" >&2
  echo "${TIMESTAMP} WARN retry_count=${RETRY_COUNT} team=${TEAM_NAME}" >> "$LOG_FILE" 2>/dev/null || true
fi

# --- 격리 §(b): 자기 UUID에만 쓰기 ---
# team_name 파일 비우기 (자기 세션만)
TEAM_NAME_FILE="${SESSION_DIR}/team_name"
if [[ -f "$TEAM_NAME_FILE" ]]; then
  STORED_TEAM=$(cat "$TEAM_NAME_FILE" 2>/dev/null | tr -d '[:space:]' || echo "")
  if [[ "$STORED_TEAM" == "$TEAM_NAME" ]]; then
    # 자기 세션 team_name 파일 비우기
    > "$TEAM_NAME_FILE" 2>/dev/null || true
    echo "${TIMESTAMP} INFO team_name_file_cleared team=${TEAM_NAME}" >> "$LOG_FILE" 2>/dev/null || true
  fi
fi

# --- teams/<name>/ 디렉토리 잔존 시 강제 정리 ---
TEAMS_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams/${TEAM_NAME}"
if [[ -d "$TEAMS_DIR" ]]; then
  # §(b) 소유권 증명: 자기 UUID가 리더인지 확인
  LEAD_UUID=""
  if command -v jq &>/dev/null; then
    LEAD_UUID=$(jq -r '.leadSessionId // empty' "${TEAMS_DIR}/config.json" 2>/dev/null || echo "")
  fi
  if [[ -z "$LEAD_UUID" || "$LEAD_UUID" == "$UUID" ]]; then
    rm -rf "$TEAMS_DIR" 2>/dev/null || true
    echo "${TIMESTAMP} INFO teams_dir_cleaned team=${TEAM_NAME}" >> "$LOG_FILE" 2>/dev/null || true
    echo "🧹 [team_delete_followup_guard] teams/${TEAM_NAME}/ 잔존 정리 완료 (UUID=${UUID})" >&2
  else
    echo "${TIMESTAMP} SKIP lead_uuid_mismatch team=${TEAM_NAME} lead=${LEAD_UUID} self=${UUID}" >> "$LOG_FILE" 2>/dev/null || true
  fi
fi

# tasks/<name>/ 잔존 시 정리
TASKS_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/tasks/${TEAM_NAME}"
if [[ -d "$TASKS_DIR" ]]; then
  rm -rf "$TASKS_DIR" 2>/dev/null || true
  echo "${TIMESTAMP} INFO tasks_dir_cleaned team=${TEAM_NAME}" >> "$LOG_FILE" 2>/dev/null || true
fi

echo "${TIMESTAMP} INFO followup_complete team=${TEAM_NAME} retry=${RETRY_COUNT}" >> "$LOG_FILE" 2>/dev/null || true
exit 0
