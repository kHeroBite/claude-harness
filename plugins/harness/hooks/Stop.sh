#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# Stop hook — STALE-OK 자동 IDLE 롤백 (재발방지)
# CLAUDE.md "재발방지 정책" 1순위 Hook 물리 차단

set -u

# session_id.sh 라이브러리 로드 (resolve_uuid 함수 등)
source "${HARNESS_HOOK_DIR}/lib/session_id.sh" 2>/dev/null || exit 0
source "${HARNESS_HOOK_DIR}/lib/state_machine.sh" 2>/dev/null || exit 0

# stdin에서 JSON 읽고 session_id 추출 (실패 시 silent skip)
INPUT=$(cat 2>/dev/null)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
[ -z "$SESSION_ID" ] && exit 0

UUID="$SESSION_ID"
SESSION_DIR="$HOME/.claude/session-env/${UUID}"
STATE_FILE="${SESSION_DIR}/state"
EVIDENCE_DIR="${SESSION_DIR}/evidence"
LOG_FILE="${SESSION_DIR}/logs/stop_hook.log"

# 디렉토리 부재 시 silent skip
[ -d "$SESSION_DIR" ] || exit 0
mkdir -p "${SESSION_DIR}/logs" 2>/dev/null

# 디바운스: stop_last mtime 2초 이내면 skip (무한 루프 방지)
STOP_LAST="${EVIDENCE_DIR}/stop_last"
NOW=$(date +%s)
if [ -f "$STOP_LAST" ]; then
  LAST_MTIME=$(stat -c %Y "$STOP_LAST" 2>/dev/null || echo 0)
  AGE=$((NOW - LAST_MTIME))
  if [ "$AGE" -lt 2 ]; then
    exit 0  # 디바운스 — 너무 빠른 재발동 차단
  fi
fi
mkdir -p "$EVIDENCE_DIR" 2>/dev/null
date +%s > "$STOP_LAST"

# state 읽기
STATE=$(state_read "$STATE_FILE" 2>/dev/null | awk '{print $1}')
[ -z "$STATE" ] && exit 0

# Phase B (L-431): STALE 회수 대상 = state=PLAN AND classification=OK
# 이유: stage OK 제거 + level OK 추가 — ok 진입 직후 단계가 stage=PLAN + classification=OK로 표현됨
CLASSIFICATION=$(cat "${SESSION_DIR}/classification" 2>/dev/null | tr -d '\r\n' || echo "")
if [ "$STATE" != "PLAN" ] || [ "$CLASSIFICATION" != "OK" ]; then
  exit 0
fi

# 3중 가드 (state=PLAN AND classification=OK인 경우):
# 가드1: ok_started 마커 존재 → ok skill 진입 정상 → skip
if [ -f "${EVIDENCE_DIR}/ok_started" ]; then
  exit 0
fi

# 가드2: team_name 존재 → 팀이 있으니 정상 진행 가능성 → skip
if [ -f "${SESSION_DIR}/team_name" ]; then
  exit 0
fi

# 가드3: heartbeat이 5초 이내 갱신됨 → 활성 처리 중 → skip
HEARTBEAT="${SESSION_DIR}/heartbeat"
if [ -f "$HEARTBEAT" ]; then
  HB_MTIME=$(stat -c %Y "$HEARTBEAT" 2>/dev/null || echo 0)
  HB_AGE=$((NOW - HB_MTIME))
  if [ "$HB_AGE" -lt 5 ]; then
    exit 0  # 활성 — 잠시 멈춤일 수 있음
  fi
fi

# 모든 가드 통과 → STALE-OK 판정 → IDLE 롤백
echo "[$(date +%Y-%m-%dT%H:%M:%S)] STALE-OK 감지 (PLAN+classification=OK) → IDLE 롤백 (UUID=${UUID})" >> "$LOG_FILE"

# state_transition CAS — PLAN → IDLE 전이 (Phase B: stage OK 제거됨)
state_transition "$STATE_FILE" "PLAN" "IDLE" "stop_hook_stale_pre_ok_rollback" "$UUID" 2>>"$LOG_FILE" || true

exit 0
