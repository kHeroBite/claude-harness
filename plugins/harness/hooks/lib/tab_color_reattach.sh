#!/bin/bash
# tmux 클라이언트가 세션에 다시 붙을 때(WT 탭 새로 열기·재부착) 메인 pane 의 @tab_color 를 탭 색으로 다시 보내는 스크립트
# 호출: main_ask_state.sh _live_migrate 가 자기 tmux 세션에 건 세션 hook(client-attached·client-session-changed)이
#       run-shell -b "bash <이 파일> '#{session_id}'" 로 부른다. 인자: $1 = 세션 id($숫자).
# 배경(2026-11-06 실측): 새 클라이언트에는 제목 스피너(OSC)는 바로 그려지지만 탭 색(DECAC 2)은 hook 이 값이 바뀔 때만 보내
#   다음 UserPromptSubmit 전까지 스피너만 돌고 빨강이 없었다(@tab_color 캐시=on, 실제 탭 색=초기화).
# 동작: 세션 pane 중 @tab_color(on|ask|done)가 있는 첫 pane(메인)의 tty 로 main_ask_state.sh 와 같은 tmux passthrough 를 쓴다.
#   tmux 가 출력 순서대로 붙은 클라이언트에 넘기므로 화면 그리기와 섞이지 않는다. 다른 세션·pane 옵션은 바꾸지 않는다.
# 출력 없음, 항상 rc=0.
exec >/dev/null 2>&1
sess="${1:-}"
case "$sess" in \$[0-9]*) ;; *) exit 0;; esac
case "${sess#\$}" in *[!0-9]*) exit 0;; esac
. "${BASH_SOURCE[0]%/*}/main_ask_fmt.sh" 2>/dev/null || exit 0
st=""; tty=""
while IFS='|' read -r s t; do
  case "$s" in on|ask|done) st="$s"; tty="$t"; break;; esac
done < <(tmux list-panes -s -t "$sess" -F '#{@tab_color}|#{pane_tty}' 2>/dev/null)
case "$st" in on) arg="$MAIN_TAB_ON";; ask) arg="$(main_tab_ask_arg)";; done) arg="$MAIN_TAB_DONE";; *) exit 0;; esac
[ -n "$arg" ] || exit 0
case "$tty" in /dev/pts/[0-9]*) ;; *) exit 0;; esac
case "${tty#/dev/pts/}" in *[!0-9]*) exit 0;; esac
[ -w "$tty" ] || exit 0
main_tab_send_wrap "$arg" > "$tty" 2>/dev/null
exit 0
