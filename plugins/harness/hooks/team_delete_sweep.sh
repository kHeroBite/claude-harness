#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# team_delete_sweep.sh — PostToolUse:TeamDelete 자동 스윕 hook (L-191)
# TeamDelete 성공 후 BEFORE diff 기반 잔류 bash pane 자동 정리 (kill PID 방식)
# bash pane만 kill (활성 claude pane은 절대 건드리지 않음)

set -euo pipefail
trap 'tmux set -g status on 2>/dev/null; exit 0' ERR
INPUT=$(timeout 5 cat 2>/dev/null || echo "")

# TeamDelete 결과 확인 — 에러 시 스킵
if echo "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); r=d.get('tool_result',{}).get('result',''); sys.exit(0 if 'error' not in r.lower() else 1)" 2>/dev/null; then
  : # TeamDelete 성공
else
  exit 0  # 실패 시 스킵
fi

# UUID 결정
source ${HARNESS_HOOK_DIR}/lib/session_id.sh 2>/dev/null || true
resolve_uuid "$INPUT" 2>/dev/null || UUID="${CLAUDE_SESSION_ID}"
[[ -z "$UUID" ]] && exit 0

BEFORE_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/panes/before.txt"

# BEFORE 파일 없으면 스킵 (퀵 작업은 BEFORE 미생성이 정상)
if [ ! -f "$BEFORE_FILE" ]; then
  exit 0
fi

# 현재 pane 목록
CURRENT_PANES=$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null | sort)

# BEFORE diff로 새 pane 식별
NEW_PANES=$(comm -13 "$BEFORE_FILE" <(echo "$CURRENT_PANES") 2>/dev/null || echo "")

if [ -z "$NEW_PANES" ]; then
  exit 0  # 새 pane 없음 — 정상
fi

# 잔류 pane 중 bash 상태인 것만 kill PID 정리
CLEANED=0
tmux set -g status off 2>/dev/null || true

for PANE_ID in $NEW_PANES; do
  CMD=$(tmux display-message -t "$PANE_ID" -p '#{pane_current_command}' 2>/dev/null || echo "GONE")

  if [ "$CMD" = "GONE" ]; then
    continue  # 이미 소멸
  fi

  if [ "$CMD" = "bash" ] || [ "$CMD" = "zsh" ] || [ "$CMD" = "sh" ]; then
    # bash/shell pane → kill → kill -9 2단계 escalation (L-194)
    PANE_PID=$(tmux display-message -t "$PANE_ID" -p '#{pane_pid}' 2>/dev/null || echo "")
    if [ -n "$PANE_PID" ]; then
      kill "$PANE_PID" 2>/dev/null || true
      sleep 1
      # 소멸 확인
      if ! tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qF "$PANE_ID"; then  # M-15: list-panes 대체
        CLEANED=$((CLEANED + 1))
      else
        # 1단계 실패 → 2단계: SIGKILL
        kill -9 "$PANE_PID" 2>/dev/null || true
        sleep 1
        tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qF "$PANE_ID" || CLEANED=$((CLEANED + 1))  # M-15
      fi
    fi
  fi
  # CMD != bash (활성 claude pane) → 절대 건드리지 않음
done

tmux set -g status on 2>/dev/null || true

if [ "$CLEANED" -gt 0 ]; then
  echo "🧹 TeamDelete 후 잔류 bash pane ${CLEANED}개 자동 정리 (kill PID)"
fi

exit 0
