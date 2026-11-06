#!/bin/bash
# tmux 팀에이전트 권한 요청 자동 승인 스크립트
# 리더 pane의 "Do you want to" 프롬프트를 감지하여 Enter 전송
# 사용: team_auto_approve.sh [start|stop]

PIDFILE="/tmp/team_auto_approve.pid"
LOG="/tmp/team_auto_approve.log"
INTERVAL=1  # 감시 주기 (초)

# 현재 세션 제외 (자기 자신에게 Enter 보내지 않음)
MY_SESSION=$(tmux display-message -p '#{session_name}' 2>/dev/null)

start() {
  if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "이미 실행 중 (PID: $(cat "$PIDFILE"))"
    return 1
  fi

  echo "[$(date)] team_auto_approve 시작 (제외 세션: $MY_SESSION)" > "$LOG"

  (
    while true; do
      for pane in $(tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null); do
        # 자기 세션 제외
        sess="${pane%%:*}"
        [[ "$sess" == "$MY_SESSION" ]] && continue

        content=$(tmux capture-pane -t "$pane" -p -S -20 2>/dev/null)

        # 리더 pane의 실제 프롬프트 감지: "Do you want to" + "❯ 1. Yes" 조합
        if echo "$content" | grep -q "Do you want to" && echo "$content" | grep -q "Yes"; then
          marker="/tmp/auto_approve_${pane//[:.]/_}"
          if [[ ! -f "$marker" ]]; then
            echo "[$(date)] 리더 승인 전송: $pane" >> "$LOG"
            tmux send-keys -t "$pane" Enter 2>/dev/null
            touch "$marker"
            (sleep 3 && rm -f "$marker") &
          fi
        fi
      done
      sleep "$INTERVAL"
    done
  ) &

  echo $! > "$PIDFILE"
  echo "team_auto_approve 시작됨 (PID: $!)"
}

stop() {
  if [[ -f "$PIDFILE" ]]; then
    kill "$(cat "$PIDFILE")" 2>/dev/null
    rm -f "$PIDFILE" /tmp/auto_approve_*
    echo "team_auto_approve 중지됨"
  else
    echo "실행 중인 프로세스 없음"
  fi
}

case "${1:-start}" in
  start) start ;;
  stop)  stop ;;
  *)     echo "사용법: $0 [start|stop]" ;;
esac
