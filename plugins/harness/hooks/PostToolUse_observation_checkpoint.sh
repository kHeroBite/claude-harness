#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# Agent/SendMessage 10건마다 otask_observer 관찰 기록 시점을 알리는 hook (block 아님, notify 전용)
# matcher 근거: 이 환경 54개 hook 중 TodoWrite를 쓰는 것은 이 hook뿐이고 해당 도구가
# 세션에 제공되지 않아 발동이 0회였다. 실제 작업 단위 경계인 Agent/SendMessage로 교체했다 (2026-08-24 실측).
set -uo pipefail

{
  CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

  # stdin에서 session_id 추출 (JSON payload). jq 없으면 python3, 둘 다 없으면 조용히 종료.
  INPUT="$(cat 2>/dev/null || true)"
  SESSION_ID=""
  if command -v jq >/dev/null 2>&1; then
    SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
  fi
  if [ -z "$SESSION_ID" ] && command -v python3 >/dev/null 2>&1; then
    SESSION_ID="$(printf '%s' "$INPUT" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get("session_id",""))
except Exception:
    pass' 2>/dev/null || true)"
  fi
  [ -z "$SESSION_ID" ] && SESSION_ID="${CLAUDE_SESSION_ID:-}"

  # 어떤 도구가 hook을 깨웠는지 로그에 남기기 위한 추출 (실패해도 무해)
  TOOL_NAME=""
  if command -v jq >/dev/null 2>&1; then
    TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
  fi

  # 세션 격리 §(a) — 자기 세션 하위에만 쓴다. session_id 미확보 시 안전하게 종료(타 세션 오염 방지).
  if [ -z "$SESSION_ID" ]; then
    exit 0
  fi

  SESSION_DIR="${CONFIG_DIR}/session-env/${SESSION_ID}"
  LOG_DIR="${SESSION_DIR}/logs"
  mkdir -p "$LOG_DIR" 2>/dev/null || true

  LOG_FILE="${LOG_DIR}/observation_checkpoint.log"
  COUNTER_FILE="${SESSION_DIR}/observation_checkpoint_count"

  # 알림 간격. Agent/SendMessage는 TodoWrite보다 호출이 잦아 3에서 10으로 늘렸다.
  INTERVAL="${OBS_CHECKPOINT_INTERVAL:-10}"
  case "$INTERVAL" in
    ''|*[!0-9]*) INTERVAL=10 ;;
  esac
  [ "$INTERVAL" -lt 1 ] && INTERVAL=10

  NOW="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)"
  # 자기 로그 남기기 — hook 발동 여부를 사후 확인 가능하게
  echo "${NOW} PostToolUse 진입 (tool=${TOOL_NAME:-?})" >> "$LOG_FILE" 2>/dev/null || true

  COUNT=0
  if [ -f "$COUNTER_FILE" ]; then
    COUNT="$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)"
  fi
  case "$COUNT" in
    ''|*[!0-9]*) COUNT=0 ;;
  esac

  COUNT=$((COUNT + 1))
  echo "$COUNT" > "$COUNTER_FILE" 2>/dev/null || true

  if [ $((COUNT % INTERVAL)) -eq 0 ]; then
    echo "${NOW} ${INTERVAL}의 배수 도달(count=${COUNT}) — 안내 출력" >> "$LOG_FILE" 2>/dev/null || true
    echo "📝 [관찰 기록 시점] 작업 ${COUNT}건 경과 — otask_observer 스킬로 지금까지의 관찰(사용자 교정/발견)을 기록할 시점입니다."
  fi

  exit 0
} 2>/dev/null || exit 0
