#!/bin/bash
# 메인 pane 테두리 형식의 #() 가 매초 불러, 스피너·'?' 와 같은 판정값(on|ask|done)의 WT 탭 색을 그 pane tty 로 다시 보내는 스크립트
# 호출: lib/main_pane_state.sh _main_pane_fmt 가 만든 MAIN_BORDER_FMT 끝의
#   #(/bin/bash <lib>/tab_color_frame.sh #{pane_id} #{pane_tty} #{socket_path} <MAIN_TAB_STATE_FMT>)
#   tmux 가 메인 pane 테두리를 그릴 때(status-interval 1초마다) 그 pane 문맥으로 인자를 펼쳐 실행한다(2026-11-06 실측: 테두리 #() 는 해당 pane 문맥, 1초 간격).
#   형식은 메인 pane 에만 pane 옵션(-p)으로 걸리므로 대상은 메인 pane 하나다. 다른 pane·세션은 건드리지 않는다.
# 판정값 출처: lib/main_ask_fmt.sh MAIN_TAB_STATE_FMT — 제목·테두리의 '?'(MAIN_ASK_COND)·스피너(MAIN_SPIN_COND)와 같은 식.
#   on=머신 작업색 / ask=작업색·종료색 교대 / done=머신별 회색에 가까운 색 / none(켠 적 없음)·그 밖=보내지 않음.
# 출력 없음(테두리에 글자를 더하지 않는다), 항상 rc=0. 매 호출 printf 1회(내장)만 한다.
# 인자(m10): $1=#{pane_id} $2=#{pane_tty} $3=#{socket_path} $4=판정값. 쓰기 전에 그 소켓의 tmux 로 pane 의 실제 tty 를 1회 조회해 $2 와 같을 때만 쓴다
#   (2026-11-06 실측 1회 약 4ms). 소켓·조회 실패·불일치는 쓰지 않는다(fail-closed).
exec >/dev/null 2>&1 </dev/null
p="${1:-}"; tty="${2:-}"; sock="${3:-}"; st="${4:-}"
case "$p" in %[0-9]*) ;; *) exit 0;; esac
case "${p#%}" in *[!0-9]*) exit 0;; esac
case "$tty" in /dev/pts/[0-9]*) ;; *) exit 0;; esac
case "${tty#/dev/pts/}" in *[!0-9]*) exit 0;; esac
case "$st" in on|ask|done) ;; *) exit 0;; esac
case "$sock" in /*) ;; *) exit 0;; esac
case "$sock" in *[!A-Za-z0-9/._-]*) exit 0;; esac
[ -S "$sock" ] || exit 0
[ "$(tmux -S "$sock" display -p -t "$p" '#{pane_tty}' 2>/dev/null)" = "$tty" ] || exit 0
. "${BASH_SOURCE[0]%/*}/main_ask_fmt.sh" 2>/dev/null || exit 0
case "$st" in on) a="${MAIN_TAB_ON:-}";; ask) a="$(main_tab_ask_arg)";; done) a="${MAIN_TAB_DONE:-}";; esac
[ -n "$a" ] && [ -w "$tty" ] || exit 0
main_tab_send_wrap "$a" > "$tty" 2>/dev/null
exit 0
