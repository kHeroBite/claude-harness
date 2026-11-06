# 답변 대기('?') 표시용 tmux 형식 상수(창 제목·메인 테두리 점)의 단일 출처 — source 전용(bash)
# 사용처: main_ask_state.sh(라이브 이행 시 세션 옵션으로 제목 형식 적용), lib/main_pane_state.sh(_main_pane_fmt 의 '?' 분기).
#
# MAIN_TITLE_FMT — 창 제목(set-titles-string) 형식.
#   바깥 조건: #{P:} 로 창의 pane 을 돌아 메인 pane 에 @main_ask(q=질문, p=승인)가 있고 살아 있는지 본다.
#   - 대기 중이면 제목 내용 전체(#{window_name})와 '?' 한 글자만을 1초마다 번갈아 낸다(짝수 초=제목, 홀수 초='?'). 대기 중엔 스피너를 붙이지 않는다.
#   - 대기가 아니면 스피너 조건(@tab_color == on + 비종료 → 4프레임 스피너)을 pane 마다 붙이고
#     그 뒤에 #{window_name} 을 고정으로 붙인다(흐르게 하지 않는다 — 2026-11-05 마키 제거, 긴 제목은 WT 탭이 자체로 줄인다).
#   스피너와 WT 탭 빨강은 같은 판정(아래 MAIN_RUN_COND)으로 함께 켜지고 꺼진다(2026-11-06 버그 수정, 같은 날 3상태 단일 판정으로 확장).
#     예전 조건(@main_border_ver + @agent_state 팀원 집계)은 메인이 Stop(회색)인데 팀원 run 이면 스피너만 돌고,
#     팀 없음·팀원 전원 idle 인데 메인이 작업 중이면 빨강만 켜지는 불일치를 냈다. 팀원 집계는 메인 테두리 점에만 남는다.
#   팀원 pane 엔 @main_ask·@tab_color 가 없어 중복 출력이 없고, 팀 없는 IDLE 세션도 교대·스피너가 보인다.
#   교대는 tmux 가 status-interval 1 로 매초 제목을 다시 평가해야 동작한다(tmux.conf 의 status-interval 1 에 의존). 주기 상수는 %%:%s,2 한 곳이다.
#   ★함정★ '=' 의 양수 인자(=22: 등)에 #{…} 식을 넣으면 tmux 가 깨진다(실측). 자르기를 다시 넣을 때 유의한다.
#   ★동기 규칙★ 이 문자열을 바꾸면 아래 두 사본도 같은 문자열로 함께 고친다(시험 T10 이 3곳 일치를 강제한다).
#     - .wsl-home/tmux.conf 의 set -g set-titles-string
#     - bin/claude-as 의 readonly _CAS_TITLE_FMT
#   실행 중 tmux 서버는 tmux.conf 를 다시 읽지 않으므로, 형식을 바꾼 뒤 이미 세션 옵션이 걸린 세션은 재시작해야 새 형식을 쓴다.
#   ★3상태 단일 판정(2026-11-06 사용자 지시)★ 스피너 조건은 아래 MAIN_RUN_COND 와 같은 식이다 — 메인 턴(@tab_color==on) 또는
#     메인 pane(@main_border_ver 보유 = 메인 전용 표식)의 팀원 집계 @agent_state==run. 시험 T10b 가 두 조건 문자열 포함을 강제한다.
MAIN_TITLE_FMT='#{?#{P:#{?#{&&:#{@main_ask},#{!:#{pane_dead}}},1,}},#{?#{e|==:#{e|%%:%s,2},0},#{window_name},?},#{P:#{?#{&&:#{!:#{pane_dead}},#{||:#{==:#{@tab_color},on},#{&&:#{@main_border_ver},#{==:#{@agent_state},run}}}},#{?#{e|==:#{e|%%:#{e|-:%s,#{@spin_t0}},4},0},◜,#{?#{e|==:#{e|%%:#{e|-:%s,#{@spin_t0}},4},1},◝,#{?#{e|==:#{e|%%:#{e|-:%s,#{@spin_t0}},4},2},◞,◟}}} ,}}#{window_name}}'

# MAIN_ASK_DOT — 메인 pane 테두리의 상태 점 자리에 대기 중 대신 넣는 구간.
#   주황 배경(214)·검정 '?' — 기존 스피너 4색(217/157/229/153)·idle green·silent magenta·done 240·keep 39 와 겹치지 않는다.
#   뒤 공백 2칸은 lib/pane_border_fmt.sh 상태 점 구간의 간격 규칙과 같다.
#   main_pane_state.sh 가 MAIN_BORDER_FMT="#{?@main_ask,${MAIN_ASK_DOT},${dot}}…" 로 감싼다.
MAIN_ASK_DOT='#[bold]#[bg=colour214]#[fg=colour16]?#[default]#[bold]  '

# 메인 3상태 단일 판정(2026-11-06 사용자 지시 — '우리 4방향 스피너가 보이면 빨강, ? 가 보이면 파랑, 그 외 회색').
#   ask  = MAIN_ASK_COND(@main_ask — 질문·승인 대기, 가장 우선) → 제목 '?' 교대·테두리 '?'·탭 파랑
#   run  = MAIN_RUN_COND(메인 턴 @tab_color==on 또는 메인 pane 의 팀원 집계 @agent_state==run) → 제목·테두리 스피너·탭 빨강
#   done = 그 외 → 스피너 없음·탭 회색
#   위 MAIN_TITLE_FMT·메인 테두리(lib/main_pane_state.sh _main_pane_fmt)·탭 색(MAIN_TAB_STATE_FMT → #() lib/tab_color_frame.sh)이 모두 이 두 조건만 본다.
#   탭 색은 메인 테두리 형식 끝의 #() 한 곳에서만 보낸다. tmux 가 status-interval(1초)마다 테두리를 다시 그리며 job 을 다시 돌리므로
#   매초 같은 판정의 색이 자기 pane tty 로 다시 나간다(passthrough 가 한 번 버려져도 다음 초에 복구). hook 은 m9 테두리가 걸린 pane 에선 변수만 쓴다.
MAIN_ASK_COND='#{&&:#{@main_ask},#{!:#{pane_dead}}}'
MAIN_RUN_COND='#{&&:#{!:#{pane_dead}},#{||:#{==:#{@tab_color},on},#{&&:#{@main_border_ver},#{==:#{@agent_state},run}}}}'
MAIN_SPIN_COND="$MAIN_RUN_COND"
MAIN_TAB_STATE_FMT="#{?${MAIN_ASK_COND},ask,#{?${MAIN_RUN_COND},on,done}}"

# MAIN_TAB_ON·MAIN_TAB_ASK·MAIN_TAB_DONE — Windows Terminal 탭 색 3상태(DECAC 2 = CSI 2;Pf;Pb ,|) 인자. main_ask_state.sh 가 자기 pane tty 로
#   tmux passthrough 로 보낸다. 작업 중(사용자 입력 뒤·대기 해제 뒤)=ON, 질문·승인 대기=ASK, Stop=DONE.
#   Pf·Pb 는 WT 색 테이블 번호다(15=밝은 흰색 글자, 88=xterm 256색 #870000 어두운 빨강 탭, 흰 글자 대비 약 10:1).
#   2026-11-05 탐침(WT 1.24.12741.0): tmux 안·밖 모두 탭 색 변경 확인, OSC 4(263/264)는 효과 없음.
#   프로필·명령에 --tabColor 가 지정된 탭은 바뀌지 않을 수 있다(미실측).
MAIN_TAB_ON='2;15;88'
MAIN_TAB_ASK='2;15;12'
MAIN_TAB_DONE='2;15;240'
# 3상태 요약 — ON=작업 중 빨강(88, 흰 글자 대비 약 10:1, 사용자 지시로 값 고정) / ASK=질문·승인 대기 파랑(12=WT 밝은 파랑, 탐침 렌더링 확인, 대비 약 4.0:1)
#   / DONE=Stop 회색(240=#585858, 대비 약 7.1:1. WT 기본 회색 8번 #767676 은 약 4.5:1 로 경계라 택하지 않음. 240 렌더링은 육안 확인 항목).
