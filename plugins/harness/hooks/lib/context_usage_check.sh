#!/usr/bin/env bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# context_usage_check.sh — 컨텍스트 사용률 80% PAUSE 체크 (C-05)
# AC-04: 80% 임계 실동작 / AC-05: PAUSE 이벤트 append
set -euo pipefail

THRESHOLD_WARN=70
THRESHOLD_PAUSE=80
THRESHOLD_FORCE=90
AVG_TOKENS_PER_LINE=3500
FORCE_PAUSE=0

usage() {
  cat <<'EOF'
context_usage_check.sh — 컨텍스트 사용률 체크 + PAUSE 이벤트 기록

Usage:
  context_usage_check.sh [--threshold N]   체크 실행 (기본 임계값 80%)
  context_usage_check.sh --force-pause     강제 PAUSE 이벤트 기록
  context_usage_check.sh --help            도움말

환경변수:
  CLAUDE_CONTEXT_TOKENS    현재 사용 토큰 수
  CLAUDE_CONTEXT_LIMIT     컨텍스트 한도
  UUID / CLAUDE_SESSION_ID 세션 UUID (batch_state.jsonl 경로)

Exit:
  0 = OK / warn, 2 = PAUSE (90%+ 강제), 1 = 에러
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --threshold) THRESHOLD_PAUSE="${2:-80}"; shift 2 ;;
    --force-pause) FORCE_PAUSE=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

# UUID 확인
SESSION_UUID="${UUID:-${CLAUDE_SESSION_ID:-}}"
# [P2-isolation] §(a) 방어: UUID 자동 감지(ls -t) 제거 — 타 세션 UUID 오인 방지 (Fix 23, 2026-04-24)
# 타 세션이 가장 최근에 수정되면 타 세션 UUID를 자기 UUID로 오인하여 §(a) 위반 발생.
if [[ -z "$SESSION_UUID" ]]; then
  echo "[context_usage_check] UUID 미정의 — UUID 환경변수 또는 CLAUDE_SESSION_ID 필요" >&2
  exit 0
fi

STATE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${SESSION_UUID}"
STATE_FILE="${STATE_DIR}/batch_state.jsonl"
mkdir -p "$STATE_DIR"

# 토큰/한도 취득
TOKENS="${CLAUDE_CONTEXT_TOKENS:-}"
LIMIT="${CLAUDE_CONTEXT_LIMIT:-}"

if [[ -z "$TOKENS" || -z "$LIMIT" ]]; then
  # transcript fallback
  TRANSCRIPT=$(find "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects" -name "*.jsonl" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2- || true)
  if [[ -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]]; then
    LINES=$(wc -l < "$TRANSCRIPT" 2>/dev/null || echo 0)
    TOKENS=$((LINES * AVG_TOKENS_PER_LINE))
    LIMIT="${LIMIT:-1000000}"
  else
    echo "WARN: 토큰 정보 없음 (환경변수 + transcript 모두 실패)" >&2
    exit 0
  fi
fi

# 사용률 계산
if [[ "$LIMIT" -le 0 ]]; then
  echo "ERROR: LIMIT 값 이상 ($LIMIT)" >&2
  exit 1
fi
USAGE_PCT=$(( TOKENS * 100 / LIMIT ))

append_event() {
  local reason="$1" pct="$2"
  local ts_wall ts_mono
  ts_wall=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  ts_mono=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)
  printf '{"event":"PAUSE_REQUESTED","reason":"%s","usage_pct":%d,"tokens":%d,"limit":%d,"ts_wall":"%s","ts_monotonic":%s}\n' \
    "$reason" "$pct" "$TOKENS" "$LIMIT" "$ts_wall" "$ts_mono" >> "$STATE_FILE"
}

# 강제 PAUSE
if [[ $FORCE_PAUSE -eq 1 ]]; then
  append_event "force_pause" "$USAGE_PCT"
  echo "PAUSE (강제): 사용률 ${USAGE_PCT}% → batch_state.jsonl 기록" >&2
  exit 2
fi

# 임계값 분기
if [[ $USAGE_PCT -ge $THRESHOLD_FORCE ]]; then
  append_event "context_${THRESHOLD_FORCE}_percent" "$USAGE_PCT"
  echo "PAUSE (강제 exit 2): 컨텍스트 사용률 ${USAGE_PCT}% ≥ ${THRESHOLD_FORCE}%" >&2
  exit 2
elif [[ $USAGE_PCT -ge $THRESHOLD_PAUSE ]]; then
  append_event "context_${THRESHOLD_PAUSE}_percent" "$USAGE_PCT"
  echo "PAUSE 요청: 컨텍스트 사용률 ${USAGE_PCT}% ≥ ${THRESHOLD_PAUSE}% (배치 경계에서 일시정지 권고)" >&2
  exit 0
elif [[ $USAGE_PCT -ge $THRESHOLD_WARN ]]; then
  echo "WARN: 컨텍스트 사용률 ${USAGE_PCT}% (임계 ${THRESHOLD_PAUSE}% 근접)" >&2
  exit 0
else
  exit 0
fi
