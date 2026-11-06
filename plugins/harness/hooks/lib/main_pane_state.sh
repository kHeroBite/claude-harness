# 메인(리드) pane 테두리에 자기 팀원 상태 집계(run/silent/idle/keep/done)를 '추가' 표시하는 공용 함수 — source 전용(bash)
# 사용처: pane_state_dot.sh — (A) 팀원 상태가 실제로 바뀐 직후, (L) 리드 프로세스 Stop(idle) 직후.
# 집계 규칙: 자기 팀원 중 run(또는 미설정·살아 있음) 1개라도 → run / 아니면 silent > idle > keep / 팀원 0명·모두 done·pane 종료·소멸·isActive=false → done
# 메인 pane 표시: 상태 점 + 제목 + 마우스 버튼. 원래 전역 형식의 pane 번호·활성 반전은 뺐고(2026-10-11 사용자 요청), 제목의 쌍따옴표·Claude 아이콘은 제거.
#   상태 점은 팀원과 같다(lib/pane_border_fmt.sh 의 점 구간을 그대로 재사용 — run 은 스피너 + 제목 배경 4색 순환).
#   답변 대기 중(@main_ask)이면 상태 점 대신 주황 '?'(m7, 2026-11-01 — lib/main_ask_fmt.sh 단일 출처).
#   선 색(STY)도 팀원과 같은 규칙. 메인 pane 의 pane 단위 옵션만 쓴다(-g·window 옵션 금지).
# 세션 격리: (1) teams/<team>/config.json 존재 (2) session-env/<UUID>/team_name == <team> (3) 경로 A 는 config members 에 자기 agentId 존재.
#   메인 pane 은 경로 L 이면 리드 자신의 $TMUX_PANE(확실), 경로 A 이면 같은 tmux 창에서 '팀원 pane 이 아니고 --agent-id 없는 claude 프로세스를
#   품은 pane'이 정확히 1개일 때만(2개 이상·0개면 아무것도 하지 않음 = fail-closed). 판정 근거는 session-env/<UUID>/logs/main_pane_state.log.
# 실패는 전부 조용히 return 0(표시 전용).

# 형식 단일 출처에서 메인용 형식 파생. PANE_BORDER_FMT 의 꼬리(라벨/제목 구간)를 떼어 상태 점 구간만 얻는다.
_main_pane_fmt() {
  local dot="${PANE_BORDER_FMT%'#{?@agent_label'*}"
  [ -n "$dot" ] && [ "$dot" != "$PANE_BORDER_FMT" ] || return 1
  # 제목: 쌍따옴표 없이, 앞머리 Claude 아이콘 '✳ ' 만 떼어 표시(2026-10-11 사용자 요청 — 45초 표본 실측 접두 문자는 ✳ 한 종류). 다른 문자로 시작하는 제목은 그대로.
  # pane 번호(#{pane_index})와 그 반전 표시는 넣지 않는다(2026-10-11 사용자 요청 '혼자만 숫자0이 있으면 의미가 없다').
  # 제목 우선순위(2026-10-16 사용자 버그 보고 '타이틀이 처음 그대로'): @main_title(작업 주제 단문 — lib/main_work_title.sh 가 계산) > pane_title.
  #   pane_title 은 Claude Code 가 첫 요청으로 만든 세션 제목을 OSC 로 쓴 값이라 요청이 바뀌어도 갱신되지 않는다(tmux 실측).
  # 답변 대기(@main_ask — main_ask_state.sh 가 질문·승인 창 동안 건다)면 상태 점 자리에 '?'(lib/main_ask_fmt.sh 의 MAIN_ASK_DOT).
  #   lib 를 못 읽으면 기존 형식 그대로(폴백). 비대기 렌더는 m6 과 같다.
  [ -n "${MAIN_ASK_DOT:-}" ] || . "${BASH_SOURCE[0]%/*}/main_ask_fmt.sh" 2>/dev/null
  # m9(2026-11-06 사용자 지시 3상태 단일 판정): 메인 점의 '?'·스피너를 창 제목과 같은 MAIN_ASK_COND·MAIN_RUN_COND
  #   (lib/main_ask_fmt.sh — 메인 턴 @tab_color==on 또는 팀원 집계 @agent_state==run)로 그리고, 같은 판정을 #() 로 lib/tab_color_frame.sh 에 넘겨
  #   매초 탭 색(ask 파랑 > run 빨강 > done 회색)을 다시 보낸다. 탭 색 송출 지점은 여기 한 곳이다(hook 은 m9 pane 에선 변수만 쓴다).
  #   스피너가 아닐 때 점은 팀원 집계를 그대로 보인다(keep 39 ⬤ / silent magenta ◯ / idle green ◯ / 그 외 colour240 ⬤).
  #   lib 경로가 절대경로·안전 문자가 아니거나 main_ask_fmt.sh 를 못 읽으면 m7 형식(job 없음) 그대로.
  local lib="${BASH_SOURCE[0]%/*}" job="" fr
  if [ -n "${MAIN_RUN_COND:-}" ] && [ -n "${MAIN_ASK_COND:-}" ] && [ -n "${MAIN_TAB_STATE_FMT:-}" ]; then
    fr='#{?#{e|==:#{e|%%:#{e|-:%s,#{@spin_t0}},4},0},#[bg=colour217]#[fg=colour16]◜,#{?#{e|==:#{e|%%:#{e|-:%s,#{@spin_t0}},4},1},#[bg=colour157]#[fg=colour16]◝,#{?#{e|==:#{e|%%:#{e|-:%s,#{@spin_t0}},4},2},#[bg=colour229]#[fg=colour16]◞,#[bg=colour153]#[fg=colour16]◟}}}  '
    dot='#[bold]#{?pane_dead,#[fg=colour240]⬤  ,#{?'"$MAIN_RUN_COND"','"$fr"',#{?#{==:#{@agent_state},keep},#[fg=colour39]⬤  ,#{?#{==:#{@agent_state},silent},#[fg=magenta]◯  ,#{?#{==:#{@agent_state},idle},#[fg=green]◯  ,#[fg=colour240]⬤  }}}}}'
    case "$lib" in /*) case "$lib" in *[!A-Za-z0-9/._-]*) ;; *) [ -f "$lib/tab_color_frame.sh" ] && job="#(/bin/bash $lib/tab_color_frame.sh #{pane_id} #{pane_tty} #{socket_path} ${MAIN_TAB_STATE_FMT})";; esac;; esac
  fi
  if [ -n "${MAIN_ASK_DOT:-}" ]; then
    if [ -n "$job" ]; then dot="#{?${MAIN_ASK_COND},${MAIN_ASK_DOT},${dot}}"; else dot="#{?@main_ask,${MAIN_ASK_DOT},${dot}}"; fi
  fi
  MAIN_BORDER_FMT="$dot"'#{?@main_title,#{@main_title},#{s/^✳ //:pane_title}}#{@main_status} #[default]#{?#{mouse},#[align=right]#[range=control|7][#{?#{pane_floating_flag},t,f}]#[norange]#[range=control|8][#{?#{window_zoomed_flag},u,z}]#[norange]#[range=control|9][x]#[norange],}'"$job"
  # m10: job 인자에 #{socket_path} 추가(tty 대조). 메인 형식을 바꾸면 m 뒤 숫자를 올린다(라이브 메인 pane 이 다음 갱신 때 재적용)
  if [ -n "$job" ]; then MAIN_BORDER_VER="m10-${PANE_BORDER_VER:-0}"; else MAIN_BORDER_VER="m7-${PANE_BORDER_VER:-0}"; fi
  return 0
}

# _main_pane_status_value <진행수> <대기수> → MAIN_STATUS_VAL (" · 진행N 대기M", 0인 항목 생략, 둘 다 0이면 빈 값)
_main_pane_status_value() {
  local r="${1:-0}" w="${2:-0}" s=""
  [ "$r" -gt 0 ] 2>/dev/null && s="진행$r"
  [ "$w" -gt 0 ] 2>/dev/null && s="${s:+$s }대기$w"
  MAIN_STATUS_VAL="${s:+ · $s}"
  return 0
}

_main_pane_log() {  # _main_pane_log <uuid> <메시지>
  local d="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/$1/logs" ts
  [ -d "$d" ] || return 0
  printf -v ts '%(%Y-%m-%dT%H:%M:%S)T' -1
  printf '%s %s\n' "$ts" "$2" >> "$d/main_pane_state.log" 2>/dev/null
  return 0
}

# pane 의 프로세스 트리(pane_pid + 자식 2단계)에 --agent-id 없는 claude 가 있으면 0(팀원 프로세스가 보이면 즉시 1)
_main_pane_has_lead() {
  local ppid="$1" pids p c cmd hit=1
  case "$ppid" in ""|*[!0-9]*) return 1;; esac
  pids="$ppid"
  for p in $(pgrep -P "$ppid" 2>/dev/null); do
    pids="$pids $p"
    for c in $(pgrep -P "$p" 2>/dev/null); do pids="$pids $c"; done
  done
  for p in $pids; do
    cmd=$(tr '\0' ' ' 2>/dev/null < "/proc/$p/cmdline") || continue
    case " $cmd " in *" --agent-id "*) return 1;; esac
    case "$cmd" in */claude\ *|claude\ *|*/claude|*/claude/versions/*) hit=0;; esac
  done
  return $hit
}

# main_pane_lead_idle <hook 입력 JSON> <리드 자신의 TMUX_PANE> — 경로 L(리드 프로세스 Stop·TeammateIdle) 진입점.
#   session-env/<session_id>/team_name 이 있는 파이프라인 세션만 집계를 다시 그린다(팀원 pane 소멸 잔상도 여기서 회수).
#   pane_state_dot.sh 본문에 두면 팀원 캐시 히트 경로도 그 바이트를 매번 읽고 파싱하므로 여기로 옮겼다(2026-10-11 역라우팅).
#   team_name·팀 config 가 없으면(ofinish 가 team_name 을 지운 뒤의 Stop = 파이프라인 종료) 메인 형식을 받은 적 있는
#   자기 pane(@main_border_ver 보유)만 done 으로 내린다 — 마지막 집계(run 스피너)가 남는 결함 수정(2026-10-11 역라우팅 #2).
main_pane_lead_idle() {
  local sid tf t=""
  case "$2" in %[0-9]*) ;; *) return 0;; esac
  [[ $1 =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([a-zA-Z0-9-]+)\" ]] || return 0
  sid="${BASH_REMATCH[1]}"
  tf="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/$sid/team_name"
  [ -r "$tf" ] && { read -r t < "$tf" || true; }
  case "$t" in ""|*/*|*..*) t="";; esac
  if [ -n "$t" ] && [ -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams/$t/config.json" ]; then
    main_pane_refresh "$2" "$sid" "$t" "" "$2"
  else
    tmux if -F -t "$2" '#{@main_border_ver}' "set -p -t $2 @agent_state done ; set -pu -t $2 @main_status" >/dev/null 2>&1
    # 작업 주제 제목 재적용(턴 중에 기록된 work_title·계획서·goal.json 반영) — 리드 자신의 pane·세션만
    . "${BASH_SOURCE[0]%/*}/main_work_title.sh" 2>/dev/null \
      && main_work_title_apply "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/$sid" "$2"
  fi
  return 0
}

# main_pane_refresh <기준 pane> <리드 UUID> <팀 이름> <내 agentId|빈값> <확정 메인 pane|빈값>
main_pane_refresh() {
  local ref="$1" uuid="$2" team="$3" aid="$4" known="$5"
  local cfgd="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" cfg tn members pid dead st ver w win pn
  local agg_run=0 agg_silent=0 agg_idle=0 agg_keep=0 agg main="" mstate="" mver="" cands="" ncand=0 why="" mt mtitle="" ms mstatus="" n_run=0 n_wait=0
  case "$ref" in %[0-9]*) ;; *) return 0;; esac
  case "$uuid" in ""|*[!a-zA-Z0-9-]*) return 0;; esac
  case "$team" in ""|*/*|*..*) return 0;; esac
  cfg="$cfgd/teams/$team/config.json"
  [ -f "$cfg" ] || return 0
  [ -r "$cfgd/session-env/$uuid/team_name" ] || return 0
  read -r tn < "$cfgd/session-env/$uuid/team_name" || [ -n "$tn" ] || return 0
  [ "$tn" = "$team" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  if [ -n "$aid" ]; then
    jq -e --arg a "$aid" 'any(.members[]?; .agentId==$a)' "$cfg" >/dev/null 2>&1 || return 0
  fi
  # isActive=false(종료·이전 사이클) 멤버는 세지 않는다 = done 취급(pane 이 남아 @agent_state run 잔상이 있어도)
  members=" $(jq -r '[.members[]? | select(.isActive != false) | .tmuxPaneId // empty | select(test("^%[0-9]+$"))] | join(" ")' "$cfg" 2>/dev/null) "
  [ -n "${PANE_BORDER_FMT:-}" ] || . "${BASH_SOURCE[0]%/*}/pane_border_fmt.sh" 2>/dev/null
  _main_pane_fmt || return 0
  win=$(tmux display -p -t "$ref" '#{window_id}' 2>/dev/null) || return 0
  [ -n "$known" ] && main="$known"
  # 구분자 '|' — 빈 @agent_state 칸도 보존된다. @main_title 은 '|' 를 품을 수 있어 마지막 칸(나머지 전부)에 둔다.
  while IFS='|' read -r pn dead pid st ver w ms mt; do
    case "$members" in
      *" $pn "*)
        [ "$dead" = 1 ] && continue   # 종료된 팀원 pane 은 done 취급
        case "$st" in run|"") agg_run=1; n_run=$((n_run+1));; silent) agg_silent=1; n_wait=$((n_wait+1));; idle) agg_idle=1; n_wait=$((n_wait+1));; keep) agg_keep=1; n_wait=$((n_wait+1));; esac;;
      *)
        if [ -n "$known" ]; then
          [ "$pn" = "$known" ] && { mstate="$st"; mver="$ver"; mtitle="$mt"; mstatus="$ms"; }
        elif [ "$w" = "$win" ] && [ "$dead" != 1 ] && _main_pane_has_lead "$pid"; then
          ncand=$((ncand+1)); cands="$cands $pn"; main="$pn"; mstate="$st"; mver="$ver"; mtitle="$mt"; mstatus="$ms"
        fi;;
    esac
  done < <(tmux list-panes -s -t "$ref" -F '#{pane_id}|#{pane_dead}|#{pane_pid}|#{@agent_state}|#{@main_border_ver}|#{window_id}|#{@main_status}|#{@main_title}' 2>/dev/null)
  if [ -z "$known" ]; then
    [ "$ncand" = 1 ] || { _main_pane_log "$uuid" "skip team=$team ref=$ref 후보=${ncand}개[${cands# }] (정확히 1개가 아니라 fail-closed)"; return 0; }
    why="같은 창($win)의 비팀원 pane 중 --agent-id 없는 claude 보유 유일 후보"
  else
    case "$members" in *" $known "*) return 0;; esac
    why="리드 프로세스 자신의 TMUX_PANE"
  fi
  case "$main" in %[0-9]*) ;; *) return 0;; esac
  if [ "$agg_run" = 1 ]; then agg=run
  elif [ "$agg_silent" = 1 ]; then agg=silent
  elif [ "$agg_idle" = 1 ]; then agg=idle
  elif [ "$agg_keep" = 1 ]; then agg=keep
  else agg=done; fi
  # 작업 주제 제목(lib/main_work_title.sh) — 리드 UUID 의 session-env 만 읽고 확정된 메인 pane 에만, 값이 바뀔 때만 쓴다
  . "${BASH_SOURCE[0]%/*}/main_work_title.sh" 2>/dev/null && main_work_title_apply "$cfgd/session-env/$uuid" "$main" "$mtitle"
  # 진행·대기 인원수 접미(팀원 이름 미포함) — 값이 바뀔 때만 자기 세션 메인 pane 에 쓰고, 빈 값이면 해제
  _main_pane_status_value "$n_run" "$n_wait"
  if [ "$MAIN_STATUS_VAL" != "$mstatus" ]; then
    if [ -n "$MAIN_STATUS_VAL" ]; then tmux set -p -t "$main" @main_status "$MAIN_STATUS_VAL" >/dev/null 2>&1
    else tmux set -pu -t "$main" @main_status >/dev/null 2>&1; fi
  fi
  if [ "$mver" != "$MAIN_BORDER_VER" ]; then
    tmux set -p -t "$main" @agent_state "$agg" \; set -p -t "$main" pane-border-format "$MAIN_BORDER_FMT" \
      \; set -p -t "$main" pane-border-style "$PANE_BORDER_STY" \; set -p -t "$main" pane-active-border-style "$PANE_BORDER_STY" \
      \; set -p -t "$main" @main_border_ver "$MAIN_BORDER_VER" >/dev/null 2>&1 || return 0
    local t0; printf -v t0 '%(%s)T' -1; tmux set -o -p -t "$main" @spin_t0 "$t0" >/dev/null 2>&1
    _main_pane_log "$uuid" "apply team=$team main=$main state=$agg ver=$MAIN_BORDER_VER 근거=$why"
  elif [ "$agg" != "$mstate" ]; then
    tmux set -p -t "$main" @agent_state "$agg" >/dev/null 2>&1 || return 0
    _main_pane_log "$uuid" "state team=$team main=$main ${mstate:-none}→$agg ref=$ref 근거=$why"
  fi
  return 0
}
