#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# 관찰 기록 알림을 받고도 observations.md를 갱신하지 않은 채 턴을 끝내려 할 때 통지하는 hook
#
# 배경 (OBS-3, 2026-08-24 실측):
#   PostToolUse_observation_checkpoint.sh 가 count=10, count=20 두 번 "관찰 기록 시점"을
#   안내했으나 observations.md 는 생성되지 않았다. 사용자가 파일 존재를 직접 물어본 뒤에야
#   기록이 이뤄졌다. PostToolUse 는 도구 호출 "순간"만 보므로 미기록을 감지할 수 없다.
#   Stop 은 턴 종료 시점에 발동하므로 "알림을 받았는데 기록하지 않았다"를 잡을 수 있다.
#
# 설계 원칙:
#   - 차단(block)이 아니라 통지. 작업 흐름을 끊지 않는다.
#   - fail-open. 모든 예외 경로에서 exit 0.
#   - 세션 격리 §(a). 자기 UUID 하위만 읽고 쓴다.
#   - 무한 루프 방지. stop_hook_active=true 이면 즉시 통과.
set -uo pipefail

{
  # 비상 차단 스위치
  [ -f "$(dirname "$0")/DISABLE_OBSERVATION_GUARD" ] && exit 0

  command -v jq >/dev/null 2>&1 || exit 0

  INPUT="$(cat 2>/dev/null || true)"
  [ -z "$INPUT" ] && exit 0

  # 재발동 방지 — 이 hook 때문에 턴이 이어진 경우 다시 통지하지 않는다
  SHA="$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)"
  [ "$SHA" = "true" ] && exit 0

  # 팀에이전트 제외 — 관찰 기록은 메인 에이전트 책임이다
  AID="$(printf '%s' "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null || true)"
  [ -n "$AID" ] && exit 0

  SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
  [ -z "$SESSION_ID" ] && exit 0

  CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  SESSION_DIR="${CONFIG_DIR}/session-env/${SESSION_ID}"
  LOG_DIR="${SESSION_DIR}/logs"
  CKPT_LOG="${LOG_DIR}/observation_checkpoint.log"
  OBS_FILE="${LOG_DIR}/observations.md"
  NOTIFIED_FILE="${SESSION_DIR}/observation_guard_notified"

  # 체크포인트 알림 이력이 없으면 판정 대상이 아니다
  [ -f "$CKPT_LOG" ] || exit 0
  ALERTS="$(grep -c '배수 도달' "$CKPT_LOG" 2>/dev/null || echo 0)"
  case "$ALERTS" in ''|*[!0-9]*) ALERTS=0 ;; esac
  [ "$ALERTS" -lt 1 ] && exit 0

  # 이미 이번 알림 회차에 통지했으면 반복하지 않는다
  LAST_NOTIFIED=0
  if [ -f "$NOTIFIED_FILE" ]; then
    LAST_NOTIFIED="$(cat "$NOTIFIED_FILE" 2>/dev/null | tr -d '[:space:]')"
    case "$LAST_NOTIFIED" in ''|*[!0-9]*) LAST_NOTIFIED=0 ;; esac
  fi
  [ "$ALERTS" -le "$LAST_NOTIFIED" ] && exit 0

  # observations.md 가 마지막 알림 이후 갱신됐는지 확인한다
  if [ -f "$OBS_FILE" ]; then
    OBS_MTIME="$(stat -c %Y "$OBS_FILE" 2>/dev/null || echo 0)"
    CKPT_MTIME="$(stat -c %Y "$CKPT_LOG" 2>/dev/null || echo 0)"
    # 알림보다 나중에 기록됐으면 정상 — 통지하지 않고 회차만 갱신
    if [ "$OBS_MTIME" -ge "$CKPT_MTIME" ]; then
      mkdir -p "$SESSION_DIR" 2>/dev/null || true
      echo "$ALERTS" > "$NOTIFIED_FILE" 2>/dev/null || true
      exit 0
    fi
    STATE_MSG="observations.md가 마지막 알림 이후 갱신되지 않았습니다"
  else
    STATE_MSG="observations.md가 아직 생성되지 않았습니다"
  fi

  # 통지 (차단 아님) — 회차를 기록해 같은 알림에 반복 통지하지 않는다
  mkdir -p "$SESSION_DIR" 2>/dev/null || true
  echo "$ALERTS" > "$NOTIFIED_FILE" 2>/dev/null || true
  echo "$(date '+%Y-%m-%d %H:%M:%S') NOTIFY alerts=${ALERTS} ${STATE_MSG}" >> "${LOG_DIR}/observation_guard.log" 2>/dev/null || true

  echo "📝 [관찰 미기록] 관찰 기록 시점 알림이 ${ALERTS}회 있었으나 ${STATE_MSG}. otask_observer 스킬로 이번 세션의 사용자 교정·발견을 기록하십시오. 기록할 만한 관찰이 없었다면 그대로 진행해도 됩니다."

  exit 0
} 2>/dev/null || exit 0
