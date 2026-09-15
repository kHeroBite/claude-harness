#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# state=IDLE 전이 후 4축 잔존 자동 검증 hook

# PostToolUse:mcp__oio__session_state 매처 — session_state 호출 직후 발동
# 목적: state=IDLE 전이 직후 4축 잔존 자동 검증 + 보수적 정리 (정직한 IDLE 보장)

trap 'exit 0' ERR

INPUT=$(timeout 5 cat 2>/dev/null || echo "")
[[ -z "$INPUT" ]] && exit 0

# --- 필터링: key=="state" AND value=="IDLE" 인지 확인 ---
TOOL_KEY=$(echo "$INPUT" | jq -r '.tool_input.key // empty' 2>/dev/null || echo "")
TOOL_VALUE=$(echo "$INPUT" | jq -r '.tool_input.value // empty' 2>/dev/null || echo "")

if [[ "$TOOL_KEY" != "state" || "$TOOL_VALUE" != "IDLE" ]]; then
  exit 0
fi

# --- UUID 결정 ---
source "${HARNESS_HOOK_DIR}/lib/session_id.sh" 2>/dev/null || true
resolve_uuid "$INPUT" 2>/dev/null || true
[[ -z "${UUID:-}" ]] && exit 0

SESSION_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}"
LOG_FILE="${SESSION_DIR}/logs/cleanup_verify.log"
mkdir -p "${SESSION_DIR}/logs" 2>/dev/null || true

# 사이클46 축① — 반대편 base 미러 (읽는 쪽이 다른 base 를 볼 수 있다)
# ★_mirror_file 만 쓴다 — _mirror_file_strict 는 미러 실패가 원 쓰기를 실패시키므로 hook 금지★
# 라이브러리 부재 시에도 hook 이 그대로 동작하도록 no-op 폴백을 정의한다.
source "${HARNESS_HOOK_DIR}/lib/session_mirror.sh" 2>/dev/null || true
type _mirror_file >/dev/null 2>&1 || _mirror_file() { :; }
type _mirror_delete >/dev/null 2>&1 || _mirror_delete() { :; }

# --- 무한 루프 가드: cleanup_verify_running 마커 확인 ---
RUNNING_MARKER="${SESSION_DIR}/cleanup_verify_running"
if [[ -f "$RUNNING_MARKER" ]]; then
  exit 0
fi
# 마커 생성 (hook 실행 중임을 표시)
touch "$RUNNING_MARKER" 2>/dev/null || true

TIMESTAMP=$(date -Iseconds 2>/dev/null || date)
STALE_FILES=()

# --- 4축 잔존 검증 ---

# 1) team_name 파일 검증
TEAM_NAME_FILE="${SESSION_DIR}/team_name"
TEAM_NAME_VALUE=""
if [[ -f "$TEAM_NAME_FILE" ]]; then
  TEAM_NAME_VALUE=$(cat "$TEAM_NAME_FILE" 2>/dev/null | tr -d '[:space:]' || echo "")
  if [[ -n "$TEAM_NAME_VALUE" ]]; then
    STALE_FILES+=("team_name=${TEAM_NAME_VALUE}")
  fi
fi

# 2) classification 파일 검증
CLASSIFICATION_FILE="${SESSION_DIR}/classification"
if [[ -f "$CLASSIFICATION_FILE" ]]; then
  CLASSIFICATION_VALUE=$(cat "$CLASSIFICATION_FILE" 2>/dev/null | tr -d '[:space:]' || echo "")
  if [[ -n "$CLASSIFICATION_VALUE" ]]; then
    STALE_FILES+=("classification=${CLASSIFICATION_VALUE}")
  fi
fi

# 3) status 파일 검증 (NONE 또는 빈 줄 OK)
STATUS_FILE="${SESSION_DIR}/status"
if [[ -f "$STATUS_FILE" ]]; then
  STATUS_VALUE=$(cat "$STATUS_FILE" 2>/dev/null | tr -d '[:space:]' || echo "")
  if [[ -n "$STATUS_VALUE" && "$STATUS_VALUE" != "NONE" ]]; then
    STALE_FILES+=("status=${STATUS_VALUE}")
  fi
fi

# 4) entry_tier 파일 검증
ENTRY_TIER_FILE="${SESSION_DIR}/entry_tier"
if [[ -f "$ENTRY_TIER_FILE" ]]; then
  ENTRY_TIER_VALUE=$(cat "$ENTRY_TIER_FILE" 2>/dev/null | tr -d '[:space:]' || echo "")
  if [[ -n "$ENTRY_TIER_VALUE" ]]; then
    STALE_FILES+=("entry_tier=${ENTRY_TIER_VALUE}")
  fi
fi

# 5) teams/<team_name>/ 디렉토리 잔존 검증
if [[ -n "$TEAM_NAME_VALUE" ]]; then
  TEAMS_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams/${TEAM_NAME_VALUE}"
  if [[ -d "$TEAMS_DIR" ]]; then
    STALE_FILES+=("teams_dir=${TEAM_NAME_VALUE}")
  fi
fi

# --- 잔존 발견 시 처리 ---
if [[ ${#STALE_FILES[@]} -gt 0 ]]; then
  STALE_LIST=$(printf '%s ' "${STALE_FILES[@]}")
  echo "⚠️ [cleanup_verify] state=IDLE 직후 잔존 감지: ${STALE_LIST}" >&2
  echo "${TIMESTAMP} WARN stale_detected: ${STALE_LIST}" >> "$LOG_FILE" 2>/dev/null || true

  # 보수적 자동 정리 (truncate -s 0 / rm -f 단일 파일만, 디렉토리 통째 삭제 금지)
  # team_name 파일 비우기
  if [[ -f "$TEAM_NAME_FILE" ]] && [[ -n "$TEAM_NAME_VALUE" ]]; then
    truncate -s 0 "$TEAM_NAME_FILE" 2>/dev/null || rm -f "$TEAM_NAME_FILE" 2>/dev/null || true
    # truncate 성공(파일 존재, 빈 내용)이면 _mirror_file, rm 성공(파일 부재)이면 _mirror_delete
    if [[ -f "$TEAM_NAME_FILE" ]]; then _mirror_file "$TEAM_NAME_FILE" || true; else _mirror_delete "$TEAM_NAME_FILE" || true; fi
    echo "${TIMESTAMP} INFO cleaned team_name" >> "$LOG_FILE" 2>/dev/null || true
  fi

  # classification 파일 비우기
  if [[ -f "$CLASSIFICATION_FILE" ]] && [[ -n "${CLASSIFICATION_VALUE:-}" ]]; then
    truncate -s 0 "$CLASSIFICATION_FILE" 2>/dev/null || rm -f "$CLASSIFICATION_FILE" 2>/dev/null || true
    if [[ -f "$CLASSIFICATION_FILE" ]]; then _mirror_file "$CLASSIFICATION_FILE" || true; else _mirror_delete "$CLASSIFICATION_FILE" || true; fi
    echo "${TIMESTAMP} INFO cleaned classification" >> "$LOG_FILE" 2>/dev/null || true
  fi

  # status 파일 비우기
  if [[ -f "$STATUS_FILE" ]] && [[ -n "${STATUS_VALUE:-}" ]] && [[ "${STATUS_VALUE:-}" != "NONE" ]]; then
    truncate -s 0 "$STATUS_FILE" 2>/dev/null || rm -f "$STATUS_FILE" 2>/dev/null || true
    if [[ -f "$STATUS_FILE" ]]; then _mirror_file "$STATUS_FILE" || true; else _mirror_delete "$STATUS_FILE" || true; fi
    echo "${TIMESTAMP} INFO cleaned status" >> "$LOG_FILE" 2>/dev/null || true
  fi

  # entry_tier 파일 비우기
  if [[ -f "$ENTRY_TIER_FILE" ]] && [[ -n "${ENTRY_TIER_VALUE:-}" ]]; then
    truncate -s 0 "$ENTRY_TIER_FILE" 2>/dev/null || rm -f "$ENTRY_TIER_FILE" 2>/dev/null || true
    if [[ -f "$ENTRY_TIER_FILE" ]]; then _mirror_file "$ENTRY_TIER_FILE" || true; else _mirror_delete "$ENTRY_TIER_FILE" || true; fi
    echo "${TIMESTAMP} INFO cleaned entry_tier" >> "$LOG_FILE" 2>/dev/null || true
  fi

  # teams/<team_name>/ 디렉토리: 주의 — 통째 삭제 금지, alert만
  if [[ -n "$TEAM_NAME_VALUE" ]]; then
    TEAMS_DIR_CHECK="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams/${TEAM_NAME_VALUE}"
    if [[ -d "$TEAMS_DIR_CHECK" ]]; then
      echo "⚠️ [cleanup_verify] teams/${TEAM_NAME_VALUE}/ 디렉토리 잔존 — 수동 확인 권장 (자동 삭제 보류)" >&2
      echo "${TIMESTAMP} WARN teams_dir_stale team=${TEAM_NAME_VALUE} (manual cleanup recommended)" >> "$LOG_FILE" 2>/dev/null || true
    fi
  fi

  echo "${TIMESTAMP} INFO cleanup_complete stale_count=${#STALE_FILES[@]}" >> "$LOG_FILE" 2>/dev/null || true
else
  echo "${TIMESTAMP} INFO state=IDLE 잔존 없음 — PASS" >> "$LOG_FILE" 2>/dev/null || true
fi

# --- 무한 루프 가드 마커 삭제 ---
rm -f "$RUNNING_MARKER" 2>/dev/null || true

exit 0
