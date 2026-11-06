#!/bin/bash
# 메인이 사용자 답변(질문·권한 승인)을 기다리는 동안 메인 pane 에 @main_ask 를 걸고 풀며, 질문당 단발 지연 알림 프로세스를 띄우는 hook
# 이벤트 디스패치(stdin JSON 의 hook_event_name):
#   PreToolUse + tool_name=AskUserQuestion → ask q (질문)
#   PermissionRequest                      → ask p (승인 창)
#   PreToolUse(그 외)                      → 표식 kind=p 이고 표식 id ≠ 현재 tool_use_id 일 때만 clear(거부 후 다음 도구).
#                                            질문 표식(kind=q)은 병렬 도구 호출에 지워지지 않게 유지한다.
#   PostToolUse·PostToolUseFailure         → 표식 id == 현재 id 이거나 kind=p 면 clear
#   Stop·UserPromptSubmit                  → 무조건 clear(표식이 없어도 @main_ask 잔상 해제)
#   Esc·거절·인터럽트 → hook 이벤트가 오지 않는다. lib/ask_notify_worker.sh 가 트랜스크립트·세션 레지스트리로 닫힘을 보고 직접 해제한다.
# 제외: (1) 입력에 비어 있지 않은 "agent_id" 필드(인프로세스 서브에이전트·팀원) (2) 부모 체인(첫 claude 조상까지, 최대 8단계) cmdline 에 --agent-id(팀원 프로세스).
# 상태: 표식 <SD>/ask_wait (1줄 "id<TAB>kind<TAB>epoch<TAB>claude_pid", tmp→mv 원자 교체, claude_pid 는 못 찾으면 빈 값),
#       요약 <SD>/ask_notify/summary.txt, 지연 프로세스 pid <SD>/ask_notify/worker.pid ("id pid").
#   SD = ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/<session_id> — 디렉터리가 없으면 아무것도 하지 않는다(자기 세션만).
# 표시: tmux 메인 pane 옵션 @main_ask(set -p -t $TMUX_PANE 만, -g·window 옵션 금지). 형식 상수는 lib/main_ask_fmt.sh.
#   라이브 이행(ask 때 + 사용자 입력 UserPromptSubmit 때 — 입력 턴당 1회, Stop·팀원 제외; 이미 같은 값이면 set 하지 않는다): (a) 해석된 set-titles-string 이 MAIN_TITLE_FMT 와 다르면(빈 값 포함) 자기 tmux 세션 옵션(-g 아님)으로 MAIN_TITLE_FMT 를 걸고,
#                            세션 id 가 확보되면 항상 자기 세션에 status-interval 1 을 건다(깜빡임용, 원복 없음).
#                        (b) 자기 pane 에 @main_border_ver 가 있고 현재 판본과 다르면 lib/main_pane_state.sh _main_pane_fmt 로 테두리만 재적용.
# 탭 색(WT, 2026-11-05): 작업 중=빨강(on), 질문·승인 대기=파랑(ask), 종료(Stop)=회색(done) (lib/main_ask_fmt.sh MAIN_TAB_ON·ASK·DONE).
#   창 제목 스피너도 같은 @tab_color==on 으로 그린다(lib/main_ask_fmt.sh MAIN_TITLE_FMT) — 빨강과 스피너는 한 판정으로 함께 켜지고 꺼진다.
#   on = UserPromptSubmit, 대기 표식 해제(pre_other·post — 승인·답변 뒤 작업 재개), resume(회색 뒤 첫 도구 호출). ask = ask(질문·승인 대기). done = Stop.
#   resume: 팀원 메시지·백그라운드 알림·Stop hook 재개로 열린 턴은 UserPromptSubmit 이 오지 않는다(2026-11-05 트랜스크립트 실측).
#     done 을 보낼 때 <SD>/tab_done 을 만들고 on 을 보낼 때 지운다. 표식이 없는 PreToolUse·PostToolUse 는 이 파일이 있을 때만 resume 으로 on 을 보낸다.
#   자기 pane(TMUX_PANE=%숫자)의 tty(/dev/pts/숫자)로만 tmux passthrough(ESC P tmux; … ESC \) 를 쓴다. 다른 pane·세션·창 무접촉.
#   pane 옵션 @tab_color(on|ask|done)로 값이 바뀔 때만 보낸다(단 UserPromptSubmit 의 on 은 캐시가 같아도 매번 다시 보낸다). 켠 적 없으면 done 은 보내지 않는다(ask 는 어느 상태에서든 보낸다 — 회색 뒤 질문도 파랑). TMUX_PANE 이 없거나 형식이 다르면 조용히 건너뛴다.
# 감시·지연 알림: setsid -f 로 lib/ask_notify_worker.sh <SD> <id> <PROJ> <transcript_path> 를 띄운다(질문당 1개, 질문이 닫히면 끝난다).
# 핫패스: 표식·tab_done·tab_ask 가 모두 없는 PreToolUse(그 외)·PostToolUse 는 내장 명령만으로 즉시 종료(fork 0, 파일 검사 1회 추가).
#   reassert(2026-11-06): 그때 <SD>/tab_on(빨강 상태)이 있고 마지막 전송 뒤 TAB_REASSERT_SEC(기본 3초)가 지났으면 빨강을 캐시와 무관하게 다시 보낸다
#     (fork 0 — 팀원 제외 체인 검사 뒤, 대상 tty 가 메인 claude 표준입력과 같은 장치(-ef)일 때만). 캐시 on·실제 색 어긋남을 사용자 입력 없이 복구한다.
#   송출은 _tab_send 한 곳이다. _tab_color 는 자기 pane 에만 allow-passthrough all 을 건다('on' 은 다시 그리기 지연 중 신호를 버림 — _tab_color 주석).
# 출력: stdout·stderr 전부 없음, 항상 rc=0. 디버그는 ASK_STATE_DEBUG=1 일 때만 <SD>/logs/main_ask_state.log 에 1줄.

INPUT=""
[ -t 0 ] || IFS= read -r -d '' -t 3 INPUT 2>/dev/null
exec >/dev/null 2>&1
trap 'exit 0' EXIT

HOOK_SELF="${BASH_SOURCE[0]}"
HOOKS_DIR="${HOOK_SELF%/*}"; [ "$HOOKS_DIR" = "$HOOK_SELF" ] && HOOKS_DIR=.
LIB_DIR="$HOOKS_DIR/lib"

# 공통 필드는 입력 앞부분에 있으므로 앞 4000자에서 먼저 찾고, 없으면 전체에서 찾는다(대용량 tool_response 정규식 비용 회피).
_HEAD="${INPUT:0:4000}"
_field() {  # _field <키> → FV (따옴표 문자열 값, 이스케이프된 키는 매치되지 않음)
  FV=""
  local re="\"$1\"[[:space:]]*:[[:space:]]*\"([^\"]*)\""
  if [[ $_HEAD =~ $re ]]; then FV="${BASH_REMATCH[1]}"
  elif [[ ${#INPUT} -gt 4000 && $INPUT =~ $re ]]; then FV="${BASH_REMATCH[1]}"; fi
  return 0
}

_field hook_event_name; EVENT="$FV"
_field session_id; SID="$FV"
case "$SID" in ""|*[!a-zA-Z0-9-]*) exit 0;; esac
SD="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/$SID"
[ -d "$SD" ] || exit 0
MARK="$SD/ask_wait"
AN="$SD/ask_notify"
TAB_DONE="$SD/tab_done"   # done(회색)을 보낸 뒤에만 있는 표식 — 핫패스가 tmux 호출 없이 '회색 상태'를 안다
TAB_ASK="$SD/tab_ask"     # ask(파랑)를 보낸 뒤에만 있는 표식 — 지연 알림 worker 가 답변(tool_result)을 먼저 보고 ask_wait 를 지운 경우
                          #   다음 PostToolUse·PreToolUse 가 표식 없이도 빨강으로 복귀하게 한다(2026-11-06 실측: 파랑 고착·스피너 꺼짐)
TAB_ON="$SD/tab_on"       # on(빨강)을 보낸 뒤에만 있는 1줄 "epoch tty 인자" — 작업 중 도구 호출마다(최소 TAB_REASSERT_SEC 간격) 빨강을 다시 보낸다.
                          #   @tab_color 캐시는 on 인데 실제 탭 색이 빨강이 아닌 어긋남(스피너만 돌고 빨강 없음, 사용자 입력 force 때만 복구 — 2026-11-06 사용자 관찰)을
                          #   사용자 입력 없이도 몇 초 안에 고친다. 핫패스는 내장 명령만 쓴다(fork 0).

_field tool_name; TOOL="$FV"

_due_reassert() {  # tab_on 이 있고 마지막 전송 뒤 TAB_REASSERT_SEC(기본 3초) 이상 지났으면 0 — RA_TTY·RA_ARG 를 채운다(내장 명령만)
  [ -f "$TAB_ON" ] || return 1
  local ts now
  read -r ts RA_TTY RA_ARG < "$TAB_ON" 2>/dev/null || return 1
  case "$ts" in ""|*[!0-9]*) return 1;; esac
  printf -v now '%(%s)T' -1
  [ $((now - ts)) -ge "${TAB_REASSERT_SEC:-3}" ] || return 1
  RA_NOW="$now"
  return 0
}

# 디스패치 1차: 처리 종류 결정(핫패스 — 표식 없으면 즉시 종료)
ACTION=""
case "$EVENT" in
  PreToolUse)
    if [ "$TOOL" = AskUserQuestion ]; then ACTION="ask"; KIND=q
    elif [ -f "$MARK" ]; then ACTION="pre_other"
    elif [ -f "$TAB_DONE" ] || [ -f "$TAB_ASK" ]; then ACTION="resume"
    else _due_reassert || exit 0; ACTION="reassert"; fi ;;
  PermissionRequest) ACTION="ask"; KIND=p ;;
  PostToolUse|PostToolUseFailure)
    if [ -f "$MARK" ]; then ACTION="post"
    elif [ -f "$TAB_DONE" ] || [ -f "$TAB_ASK" ]; then ACTION="resume"
    else _due_reassert || exit 0; ACTION="reassert"; fi ;;
  Stop|UserPromptSubmit) ACTION="clear_all" ;;
  *) exit 0 ;;
esac

_dbg() {  # ASK_STATE_DEBUG=1 일 때만 1줄 기록
  [ "${ASK_STATE_DEBUG:-0}" = 1 ] || return 0
  local d="$SD/logs" ts keys=""
  mkdir -p "$d" 2>/dev/null || return 0
  command -v jq >/dev/null 2>&1 && keys=$(printf '%s' "$INPUT" | jq -r 'keys|join(",")' 2>/dev/null)
  printf -v ts '%(%Y-%m-%dT%H:%M:%S)T' -1
  printf '%s pid=%s pane=%s event=%s tool=%s action=%s %s keys=[%s]\n' \
    "$ts" "$$" "${TMUX_PANE:-}" "$EVENT" "$TOOL" "$ACTION" "$1" "$keys" >> "$d/main_ask_state.log" 2>/dev/null
  return 0
}

# 제외 (1): 인프로세스 서브에이전트·인프로세스 팀원 — 입력에 비어 있지 않은 agent_id
_re_aid='"agent_id"[[:space:]]*:[[:space:]]*"[^"]+"'
if [[ $INPUT =~ $_re_aid ]]; then _dbg "skip agent_id"; exit 0; fi

# 부모 체인 탐색(최대 8단계): --agent-id(팀원 프로세스)가 있으면 1. claude 실행 파일 첫 조상 pid 를 CLAUDE_PID 에 남기고 거기서 멈춘다.
#   time_budget.sh 래퍼·서브셸이 끼어 팀원 claude 가 5단계 밖에 있어도 놓치지 않게 '첫 claude 조상까지'를 본다
#   (메인 claude 의 조상은 tmux·셸뿐이라 --agent-id 가 없다). 체인이 끊긴 경우(예: init 재부모화)는 비팀원으로 본다.
CLAUDE_PID=""
_chain_scan() {
  local pid=$$ i a first s ppid
  for i in 1 2 3 4 5 6 7 8; do
    case "$pid" in ""|0|1|*[!0-9]*) break;; esac
    if [ -r "/proc/$pid/cmdline" ]; then
      first=""
      while IFS= read -r -d '' a; do
        [ -z "$first" ] && first="$a"
        [ "$a" = "--agent-id" ] && return 1
      done < "/proc/$pid/cmdline"
      case "$first" in claude|*/claude|*/claude/versions/*) CLAUDE_PID="$pid"; return 0;; esac
    fi
    read -r s < "/proc/$pid/stat" 2>/dev/null || break
    s="${s##*) }"
    read -r _ ppid _ <<<"$s"
    pid="$ppid"
  done
  return 0
}
# 제외 (2): 팀원 프로세스
_chain_scan || { _dbg "skip agent-id chain"; exit 0; }

_field tool_use_id; TID="$FV"

# 표식 읽기 → M_ID M_KIND M_EP M_PID
M_ID=""; M_KIND=""; M_EP=""; M_PID=""
[ -f "$MARK" ] && IFS=$'\t' read -r M_ID M_KIND M_EP M_PID < "$MARK"

_kill_worker() {  # worker.pid 의 프로세스가 살아 있고 ask_notify_worker.sh 일 때만 프로세스 그룹째 종료
  local wid wpid cmd
  [ -r "$AN/worker.pid" ] || return 0
  read -r wid wpid < "$AN/worker.pid" || true
  case "$wpid" in ""|*[!0-9]*) return 0;; esac
  if [ -r "/proc/$wpid/cmdline" ]; then
    cmd=$(tr '\0' ' ' < "/proc/$wpid/cmdline" 2>/dev/null)
    case "$cmd" in
      *ask_notify_worker.sh*)
        kill -TERM -- "-$wpid" 2>/dev/null || kill -TERM "$wpid" 2>/dev/null ;;
    esac
  fi
  rm -f "$AN/worker.pid" 2>/dev/null
  return 0
}

_tmux_ok() { [ -n "${TMUX_PANE:-}" ] && command -v tmux >/dev/null 2>&1; }

_clear() {  # 표식 삭제 + @main_ask 해제 + 지연 프로세스 종료
  rm -f "$MARK" 2>/dev/null
  _tmux_ok && tmux set -pu -t "$TMUX_PANE" @main_ask >/dev/null 2>&1
  _kill_worker
  # 실제 표식을 푼 경우만 사후 추적용으로 남긴다(언제 무엇이 풀었는지 — 표식 없는 호출은 기록하지 않는다)
  if [ -n "$M_ID" ] && [ -d "$SD/logs" ]; then
    printf -v _ts '%(%Y-%m-%dT%H:%M:%S)T' -1
    printf '%s id=%s hook cleared by=%s\n' "$_ts" "$M_ID" "$1" >> "$SD/logs/ask_notify.log" 2>/dev/null
  fi
  _dbg "clear $1 mark_id=$M_ID kind=$M_KIND tid=$TID"
  return 0
}

_live_migrate() {  # 라이브 이행 — 자기 pane·자기 tmux 세션만
  local cur sess ver
  . "$LIB_DIR/main_ask_fmt.sh" 2>/dev/null || return 0
  [ -n "${MAIN_TITLE_FMT:-}" ] || return 0
  # (a) 제목 형식 — 해석된 값이 MAIN_TITLE_FMT 와 다르면(빈 값 포함) 자기 tmux 세션 옵션으로 새 형식을 건다.
  #     깜빡임은 status-interval 1 이 필요하므로 세션 id 가 확보되면 형식 일치 여부와 무관하게 자기 세션에만 건다(-g 금지, 원복 안 함).
  cur=$(tmux show -Av -t "$TMUX_PANE" set-titles-string 2>/dev/null)
  sess=$(tmux display -p -t "$TMUX_PANE" '#{session_id}' 2>/dev/null)
  case "$sess" in
    \$[0-9]*)
      [ "$cur" = "$MAIN_TITLE_FMT" ] || tmux set -t "$sess" set-titles-string "$MAIN_TITLE_FMT" >/dev/null 2>&1
      [ "$(tmux show -Av -t "$sess" status-interval 2>/dev/null)" = 1 ] || tmux set -t "$sess" status-interval 1 >/dev/null 2>&1
      # (c) 재부착 탭 색 — 새 클라이언트(WT 탭 새로 열기·재부착)엔 스피너만 그려지고 탭 색은 다시 오지 않으므로(2026-11-06 실측)
      #     자기 세션에만 세션 hook 을 건다(-g 금지, 인덱스 9 고정으로 다른 세션 hook 과 겹치지 않게, 이미 있으면 다시 걸지 않는다).
      case "$LIB_DIR" in
        /*) if [ -f "$LIB_DIR/tab_color_reattach.sh" ]; then
              case "$(tmux show-hooks -t "$sess" 2>/dev/null)" in
                *tab_color_reattach.sh*) ;;
                *) local rc_cmd="run-shell -b \"bash '$LIB_DIR/tab_color_reattach.sh' '#{session_id}'\""
                   tmux set-hook -t "$sess" 'client-attached[9]' "$rc_cmd" \; set-hook -t "$sess" 'client-session-changed[9]' "$rc_cmd" >/dev/null 2>&1 ;;
              esac
            fi ;;
      esac ;;
  esac
  # (b) 메인 테두리 판본
  ver=$(tmux display -p -t "$TMUX_PANE" '#{@main_border_ver}' 2>/dev/null)
  [ -n "$ver" ] || return 0
  if [ -z "${PANE_BORDER_FMT:-}" ]; then
    . "$LIB_DIR/pane_border_fmt.sh" 2>/dev/null || . "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/pane_border_fmt.sh" 2>/dev/null || return 0
  fi
  . "$LIB_DIR/main_pane_state.sh" 2>/dev/null || return 0
  _main_pane_fmt 2>/dev/null || return 0
  [ -n "${MAIN_BORDER_VER:-}" ] && [ "$ver" != "$MAIN_BORDER_VER" ] || return 0
  tmux set -p -t "$TMUX_PANE" pane-border-format "$MAIN_BORDER_FMT" \; set -p -t "$TMUX_PANE" @main_border_ver "$MAIN_BORDER_VER" >/dev/null 2>&1
  _dbg "migrate border $ver→$MAIN_BORDER_VER"
  return 0
}

_tab_on_mark() {  # _tab_on_mark <tty> — 주기 재전송용 tab_on 1줄 기록("epoch tty 인자", 내장 명령만)
  local now
  [ -n "${MAIN_TAB_ON:-}" ] || return 0
  printf -v now '%(%s)T' -1
  printf '%s %s %s\n' "$now" "$1" "$MAIN_TAB_ON" > "$TAB_ON" 2>/dev/null
  return 0
}

_tab_send() {  # _tab_send <tty> <DECAC 인자> — 탭 색 송출 단일 경로(_tab_color·reassert 공용). 실패는 rc=1
  printf '\033Ptmux;\033\033[%s,|\033\\' "$2" > "$1" 2>/dev/null
}

_tab_color() {  # _tab_color on|ask|done — 자기 pane tty 로만 DECAC 2 를 passthrough 로 보낸다(값이 바뀔 때만, 실패는 조용히)
  local want="$1" out cur tty arg pt
  case "${TMUX_PANE:-}" in %[0-9]*) ;; *) return 0;; esac
  case "${TMUX_PANE#%}" in *[!0-9]*) return 0;; esac
  command -v tmux >/dev/null 2>&1 || return 0
  [ -n "${MAIN_TAB_ON:-}" ] || . "$LIB_DIR/main_ask_fmt.sh" 2>/dev/null
  [ -n "${MAIN_TAB_ON:-}" ] && [ -n "${MAIN_TAB_ASK:-}" ] && [ -n "${MAIN_TAB_DONE:-}" ] || return 0
  out=$(tmux display -p -t "$TMUX_PANE" '#{@main_border_ver}|#{@tab_color}|#{allow-passthrough}|#{pane_tty}' 2>/dev/null) || return 0
  # m9+ 테두리(lib/main_pane_state.sh — 3상태 단일 판정 + #() 매초 탭 색 재송출)가 걸린 pane 이면 hook 은 전이 순간 1회만 직접 보내고
  #   주기 재전송(tab_on·reassert)은 하지 않는다(테두리 job 이 매초 맡는다, 2026-11-06). 그 밖(판본 없음·m7·m8)은 기존 재전송까지 그대로.
  local frame=0
  case "${out%%|*}" in m9-*|m1[0-9]-*) frame=1;; esac
  out="${out#*|}"
  cur="${out%%|*}"; out="${out#*|}"; pt="${out%%|*}"; tty="${out#*|}"
  # 자기 pane 에만 allow-passthrough all(2026-11-06 원인 확정): 'on' 이면 tmux 는 클라이언트 다시 그리기가 밀려 있거나(CLIENT_REDRAWWINDOW·
  #   TTY_FREEZE) pane 이 PANE_REDRAW·PANE_DROP 이거나 현재 창이 아니면 passthrough 를 재전송 없이 버린다(tmux tty.c tty_client_ready,
  #   screen-write.c screen_write_set_client_cb). 작업 중 TUI 가 계속 그리는 동안 빨강이 버려지고, 조용한 사용자 입력 순간에만 도달했다.
  #   'all' 은 이 검사들을 건너뛴다. -p(이 pane)만 — 전역·창·다른 pane 은 바꾸지 않는다. 실제로 보낼 때와 tab_on(재전송 근거)을 남길 때만 건다. 이미 all 이면 tmux 호출 0회 추가.
  [ "$cur" = "$want" ] && [ "${2:-}" != force ] && { [ "$want" = on ] && { [ "$pt" = all ] || tmux set -p -t "$TMUX_PANE" allow-passthrough all >/dev/null 2>&1; rm -f "$TAB_DONE" "$TAB_ASK" 2>/dev/null; [ -e "$TAB_ON" ] || [ "$frame" = 1 ] || _tab_on_mark "$tty"; }; [ "$want" = ask ] && [ ! -e "$TAB_ASK" ] && : > "$TAB_ASK" 2>/dev/null; return 0; }   # force(UserPromptSubmit 의 on)는 캐시가 같아도 다시 보낸다(캐시가 실제 색과 어긋난 경우 복구)
  case "$want" in   # 켠 적 없는 pane 엔 done 을 보내지 않는다(done 은 대기 중이던 ask 에서도 허용)
    # ask 는 어느 상태에서든 보낸다(2026-11-06 버그 수정): 예전엔 on 에서만 보내 회색(done) 뒤 UserPromptSubmit 없이 열린 턴
    #   (팀원 메시지·백그라운드 알림)의 첫 도구가 AskUserQuestion 이면 질문 대기 중에도 회색으로 남았다(파랑 미표시).
    #   이 hook 은 메인 pane 에서만 돌므로(팀원·서브에이전트 제외) 켠 적 없는 pane 이어도 질문 대기는 파랑이 맞다.
    done) [ "$cur" = on ] || [ "$cur" = ask ] || return 0;;
  esac
  case "$tty" in /dev/pts/[0-9]*) ;; *) return 0;; esac
  case "${tty#/dev/pts/}" in *[!0-9]*) return 0;; esac
  [ -w "$tty" ] || return 0
  case "$want" in on) arg="$MAIN_TAB_ON";; ask) arg="$MAIN_TAB_ASK";; done) arg="$MAIN_TAB_DONE";; *) return 0;; esac
  [ "$pt" = all ] || tmux set -p -t "$TMUX_PANE" allow-passthrough all >/dev/null 2>&1
  _tab_send "$tty" "$arg" || return 0   # 전이 즉시 1회는 항상 직접 보낸다(테두리가 안 그려지는 동안의 대체 경로 — 매초 재송출은 m9+ 테두리 job 몫)
  tmux set -p -t "$TMUX_PANE" @tab_color "$want" >/dev/null 2>&1
  # 제목 스피너도 @tab_color==on 으로 그린다(lib/main_ask_fmt.sh) — 위상 기준 @spin_t0 가 없으면 보충(set -o: 있으면 유지, rc 무시)
  if [ "$want" = on ]; then printf -v _t0 '%(%s)T' -1; tmux set -o -p -t "$TMUX_PANE" @spin_t0 "$_t0" >/dev/null 2>&1; fi
  if [ "$want" = done ]; then : > "$TAB_DONE" 2>/dev/null; elif [ -e "$TAB_DONE" ]; then rm -f "$TAB_DONE" 2>/dev/null; fi
  if [ "$want" = ask ]; then : > "$TAB_ASK" 2>/dev/null; elif [ -e "$TAB_ASK" ]; then rm -f "$TAB_ASK" 2>/dev/null; fi
  if [ "$want" = on ] && [ "$frame" = 0 ]; then _tab_on_mark "$tty"; else rm -f "$TAB_ON" 2>/dev/null; fi   # 주기 재전송은 빨강일 때만(m9 는 테두리 #() 가 매초 보낸다)
  _dbg "tab_color $cur→$want"
  return 0
}

_summary() {  # 요약 1줄 → SUMMARY (승인은 도구 이름만 — 명령 본문은 비밀 노출 위험으로 넣지 않는다)
  SUMMARY=""
  if [ "$KIND" = q ] && command -v jq >/dev/null 2>&1; then
    SUMMARY=$(printf '%s' "$INPUT" | jq -r '
      (.tool_input.questions // []) as $q
      | if ($q|length) == 0 then "" else
          ((($q[0].header // "") + " " + ($q[0].question // "")) | gsub("[\r\n\t]+"; " ") | ltrimstr(" ") | .[0:120])
          + (if ($q|length) > 1 then " (외 \(($q|length) - 1)건)" else "" end)
        end' 2>/dev/null)
    [ -n "$SUMMARY" ] || SUMMARY="질문 답변 대기"
  elif [ "$KIND" = q ]; then
    SUMMARY="질문 답변 대기"
  else
    SUMMARY="권한 승인 대기 — ${TOOL:-도구}"
  fi
  return 0
}

_ask() {
  local ep tmp proj trp
  # 같은 id 표식이 이미 있으면 재기동 없음(PermissionRequest·PreToolUse 중복)
  if [ -n "$M_ID" ] && { [ "$M_ID" = "$TID" ] || { [ "$KIND" = p ] && [ "$TOOL" = AskUserQuestion ] && [ "$M_KIND" = q ]; }; }; then
    _tmux_ok && tmux set -p -t "$TMUX_PANE" @main_ask "$M_KIND" >/dev/null 2>&1
    _tmux_ok && _tab_color ask   # 이미 파랑이면 tmux 조회 1회로 끝난다 — 표식은 있는데 색이 어긋난 경우 복구
    _dbg "ask dup id=$M_ID"
    return 0
  fi
  printf -v ep '%(%s)T' -1
  [ -n "$TID" ] || TID="${KIND}-${ep}-$$"   # tool_use_id 가 없는 입력(승인 창 등)은 자체 id
  case "$TID" in *[!A-Za-z0-9_-]*) TID="${KIND}-${ep}-$$";; esac
  mkdir -p "$AN" 2>/dev/null || return 0
  _kill_worker   # 앞선 질문의 지연 프로세스(다른 id)는 정리
  _summary
  printf '%s\n' "$SUMMARY" > "$AN/summary.txt" 2>/dev/null
  tmp="$MARK.tmp.$$"
  printf '%s\t%s\t%s\t%s\n' "$TID" "$KIND" "$ep" "$CLAUDE_PID" > "$tmp" 2>/dev/null && mv -f "$tmp" "$MARK" 2>/dev/null
  if _tmux_ok; then
    tmux set -p -t "$TMUX_PANE" @main_ask "$KIND" >/dev/null 2>&1
    _live_migrate
    _tab_color ask
  fi
  proj="${CLAUDE_PROJECT_DIR:-}"
  [ -n "$proj" ] || { _field cwd; proj="$FV"; }
  _field transcript_path; trp="$FV"
  if [ -f "$LIB_DIR/ask_notify_worker.sh" ] && command -v setsid >/dev/null 2>&1; then
    setsid -f /bin/bash "$LIB_DIR/ask_notify_worker.sh" "$SD" "$TID" "$proj" "$trp" </dev/null >/dev/null 2>&1
  fi
  _dbg "ask kind=$KIND id=$TID claude_pid=$CLAUDE_PID"
  return 0
}

case "$ACTION" in
  ask) _ask ;;
  pre_other)
    [ "$M_KIND" = p ] && [ "$M_ID" != "$TID" ] && { _clear "pre_other"; _tab_color on; } ;;
  post)
    if [ -n "$M_ID" ] && { [ "$M_ID" = "$TID" ] || [ "$M_KIND" = p ]; }; then _clear "post"; _tab_color on; fi ;;
  resume)   # Stop(회색) 뒤 UserPromptSubmit 없이 열린 턴(팀원 메시지·백그라운드 알림·Stop hook 재개)의 첫 도구 호출,
            # 또는 worker 가 답변을 먼저 보고 표식을 지운 뒤(파랑 잔존)의 첫 도구 이벤트 → 빨강 복귀
    _tab_color on
    # 표식(ask_wait)이 없으므로 남은 @main_ask 도 푼다 — 남아 있으면 제목이 '?' 교대에 머물러 빨강인데 스피너가 안 돈다
    _tmux_ok && tmux set -pu -t "$TMUX_PANE" @main_ask >/dev/null 2>&1
    rm -f "$TAB_DONE" "$TAB_ASK" 2>/dev/null ;;
  reassert)  # 작업 중(빨강) 도구 호출 — 캐시와 무관하게 빨강을 다시 보낸다(tmux 호출 없음). 대상 tty 가 이 메인 claude 의 표준입력과 같은 장치일 때만.
    [ -n "$CLAUDE_PID" ] && [ "/proc/$CLAUDE_PID/fd/0" -ef "$RA_TTY" ] || { _dbg "reassert skip tty"; exit 0; }
    case "$RA_TTY" in /dev/pts/[0-9]*) ;; *) exit 0;; esac
    case "${RA_TTY#/dev/pts/}" in *[!0-9]*) exit 0;; esac
    case "$RA_ARG" in 2\;[0-9]*\;[0-9]*) ;; *) exit 0;; esac
    [ -w "$RA_TTY" ] && [ -f "$TAB_ON" ] && [ ! -e "$TAB_DONE" ] && [ ! -e "$TAB_ASK" ] || exit 0
    _tab_send "$RA_TTY" "$RA_ARG"   # pane 의 allow-passthrough all 은 tab_on 을 만든 _tab_color on 이 먼저 걸어 둔다
    printf '%s %s %s\n' "$RA_NOW" "$RA_TTY" "$RA_ARG" > "$TAB_ON" 2>/dev/null
    _dbg "reassert on" ;;
  clear_all)
    _clear "$EVENT"
    # 사용자 입력 턴당 1회 라이브 이행(질문이 드문 자율 진행에서도 새 형식 적용). Stop 은 제외 — 핫패스 아님·턴당 1회 유지.
    [ "$EVENT" = UserPromptSubmit ] && _tmux_ok && _live_migrate
    if [ "$EVENT" = UserPromptSubmit ]; then _tab_color on force; else _tab_color done; fi ;;
esac
exit 0
