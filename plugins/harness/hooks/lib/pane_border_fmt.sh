# 팀원 pane 테두리 형식(PANE_BORDER_FMT)·선 스타일(PANE_BORDER_STY)·버전(PANE_BORDER_VER)의 단일 출처 — source 전용
# 사용처: PostToolUse_Agent_pane_label.sh(spawn 직후 최초 적용), pane_state_dot.sh(캐시 VER 불일치 시 자기 pane 재적용)
# [2026-10-10 부분 원복] run 스피너만 연한 배경 + 검정 글자(idle 은 글자색 green ◯, 배경 없음)(#[bg=colourN]#[fg=colour16] — fg=black 은 #[bold] 와 겹치면 터미널이 bright black 회색으로 그려 진짜 검정 colour16, 쉼표 없는 연속 스타일). 빈 원 ◯ = idle·silent, 가득 찬 원 ⬤ = done·keep·pane 종료. 나머지(dead/done/keep/silent)는 155127b 이전 글자색(fg). 선(STY)은 fg 색.
# 상태 점: pane_dead → 신호 종료 colour240 ⬤ / 신호 없음+status 0 colour240 ⬤ / 그 외(오류 종료) yellow ⬤
#          done colour240 ⬤ / keep colour39 ⬤(agent_keep 재사용 대기) / silent magenta ◯(무보고 대기) / idle green ◯(보고 후 대기) / run·미설정 ◜◝◞◟ 스피너
#          (위상 (%s−@spin_t0) mod 4 → 기호·제목 배경 연한 빨강 colour217/초록 colour157/노랑 colour229/파랑 colour153 4색 순환 [2026-10-10], 선 colour203 고정. @spin_t0 부재 시 %s mod 4 폴백)
# 우선순위: pane_dead > done > keep > silent > idle > run. 선(STY) 색도 같은 우선순위(keep colour39, silent magenta).
# 기호 뒤 공백은 2칸(기호와 같은 색 구간) — ◯ 는 애매 폭(A)이라 Windows Terminal 이 넓게 그려 1칸이면 제목에 붙는다. 스피너는 공용 꼬리 1곳.
# 라벨(@agent_label)이 없을 때 쓰는 pane_title 은 앞머리 Claude 아이콘 '✳ ' 를 떼어 표시한다(2026-10-11 사용자 요청 — 45초 표본 실측에서 접두 문자는 ✳ 한 종류뿐).
# 작은따옴표 리터럴이라 $·# 가 셸에서 확장되지 않는다. fork 0회.
PANE_BORDER_FMT='#[bold]#{?pane_dead,#{?pane_dead_signal,#[fg=colour240]⬤  ,#{?#{==:#{pane_dead_status},0},#[fg=colour240]⬤  ,#[fg=yellow]⬤  }},#{?#{==:#{@agent_state},done},#[fg=colour240]⬤  ,#{?#{==:#{@agent_state},keep},#[fg=colour39]⬤  ,#{?#{==:#{@agent_state},silent},#[fg=magenta]◯  ,#{?#{==:#{@agent_state},idle},#[fg=green]◯  ,#{?#{e|==:#{e|%%:#{e|-:%s,#{@spin_t0}},4},0},#[bg=colour217]#[fg=colour16]◜,#{?#{e|==:#{e|%%:#{e|-:%s,#{@spin_t0}},4},1},#[bg=colour157]#[fg=colour16]◝,#{?#{e|==:#{e|%%:#{e|-:%s,#{@spin_t0}},4},2},#[bg=colour229]#[fg=colour16]◞,#[bg=colour153]#[fg=colour16]◟}}}  }}}}}#{?@agent_label,#{@agent_label},#{s/^✳ //:pane_title}} #[default]'
PANE_BORDER_STY='#{?pane_dead,#{?pane_dead_signal,fg=colour240,#{?#{==:#{pane_dead_status},0},fg=colour240,fg=yellow}},#{?#{==:#{@agent_state},done},fg=colour240,#{?#{==:#{@agent_state},keep},fg=colour39,#{?#{==:#{@agent_state},silent},fg=magenta,#{?#{==:#{@agent_state},idle},fg=green,fg=colour203}}}}}'
# FMT/STY 를 바꾸면 반드시 갱신: printf '%s\n%s' "$PANE_BORDER_FMT" "$PANE_BORDER_STY" | cksum | cut -d' ' -f1
PANE_BORDER_VER=2135188340
