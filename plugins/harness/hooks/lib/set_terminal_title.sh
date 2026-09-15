#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# set_terminal_title.sh
# Windows Terminal 타이틀바 갱신 헬퍼 — tmux rename-window 경유.
# state_write() 등 state 변경 지점에서 호출하여 즉시성 보장.
#
# 포맷: "🏠 {프로젝트} 👤 {ID}({주간남은%}) {state이모지}{state}"
# 예시: "🏠 AI 👤 rio(74%) 🧍idle"
#
# 의존: tmux (없으면 silent skip), CLAUDE_PROFILE_NAME 또는 USER 환경변수
#       weekly% 캐시: ~/.claude/.weekly_remaining_cache (statusline.py가 갱신)
# 사이드이펙트: tmux window 이름이 동일 텍스트로 변경됨 (의도된 동작)

set_terminal_title() {
  local STATE_VALUE="${1:-IDLE}"

  # 팀에이전트 컨텍스트(PIPELINE_UUID 환경변수 존재)는 메인 타이틀바를 건드리지 않음
  [ -n "${PIPELINE_UUID:-}" ] && return 0

  # 비-tmux 환경 가드 (silent skip)
  [ -z "$TMUX" ] && return 0
  command -v tmux >/dev/null 2>&1 || return 0

  # 프로필 ID
  local PROFILE_ID="${CLAUDE_PROFILE_NAME:-${USER:-user}}"

  # 프로젝트 이름 추출:
  # 1순위: tmux session name (claude-AI-3 → AI)
  # 2순위: CLAUDE_PROJECT_DIR basename
  # 3순위: $PWD basename
  local PROJECT
  local SESSION_NAME
  SESSION_NAME=$(tmux display-message -p '#S' 2>/dev/null)
  if [[ "$SESSION_NAME" =~ ^claude-([A-Za-z0-9]+) ]]; then
    PROJECT="${BASH_REMATCH[1]}"
  elif [ -n "$CLAUDE_PROJECT_DIR" ]; then
    PROJECT=$(basename "$CLAUDE_PROJECT_DIR")
  else
    PROJECT=$(basename "$PWD")
  fi

  # state lowercase + 이모지 매핑
  # 화이트리스트만 허용 — 미지정 state(예: 옛 캐시 hook이 보낸 "WAIT")는 IDLE 폴백.
  # 이유: ❔ wait 같은 잔재 표시 차단 (LESSONS L-NEW-D)
  local STATE_UPPER STATE_LOWER STATE_EMOJI
  STATE_UPPER=$(echo "$STATE_VALUE" | tr '[:lower:]' '[:upper:]')
  case "$STATE_UPPER" in
    IDLE)        STATE_EMOJI="🧍" ;;
    OK)          STATE_EMOJI="🚶" ;;
    PLAN)        STATE_EMOJI="🤔" ;;
    DEV)         STATE_EMOJI="🏃" ;;
    TEST)        STATE_EMOJI="🧪" ;;
    DONE)        STATE_EMOJI="✅" ;;
    FINISH)      STATE_EMOJI="🧎" ;;
    EARLY_TERM)  STATE_EMOJI="⏹️" ;;
    ERROR)       STATE_EMOJI="❌" ;;
    *)
      # 화이트리스트 외 state는 IDLE로 강제 폴백 (옛 hook의 "WAIT" 등 잔재 차단)
      STATE_UPPER="IDLE"
      STATE_EMOJI="🧍"
      ;;
  esac
  STATE_LOWER=$(echo "$STATE_UPPER" | tr '[:upper:]' '[:lower:]')

  # weekly% 캐시 읽기 (statusline.py가 갱신)
  local WEEKLY_CACHE="$HOME/.claude/.weekly_remaining_cache"
  local ID_PART="$PROFILE_ID"
  if [ -f "$WEEKLY_CACHE" ]; then
    local WEEKLY_PCT
    WEEKLY_PCT=$(cat "$WEEKLY_CACHE" 2>/dev/null | tr -d '[:space:]')
    if [[ "$WEEKLY_PCT" =~ ^[0-9]+$ ]]; then
      ID_PART="${PROFILE_ID} ${WEEKLY_PCT}%"
    fi
  fi

  local TITLE="🏠 ${PROJECT} 👤 ${ID_PART} ${STATE_EMOJI} ${STATE_LOWER}"

  # tmux rename-window: 동기 실행 — race condition 방지
  # (백그라운드 & 제거: hook 호출 순서 보장 위해 동기 필수)
  tmux rename-window "$TITLE" >/dev/null 2>&1
  return 0
}
