#!/bin/bash
# 팀원 tmux pane 의 @agent_state(run/idle/silent/done/keep)를 기록해 border 라벨 앞 상태 점 색을 바꾸는 hook
# 이벤트 디스패치(stdin JSON 의 hook_event_name):
#   PreToolUse → run / PostToolUse(SendMessage)·argv sendmsg → 상태 무변경 no-op(2026-10-08: 중간 보고 회색 깜빡임 근본 제거,
#     옛 settings 캐시 세션의 sendmsg 등록도 이 파일을 쓰므로 함께 해소)
#   TeammateIdle·Stop → 경로 A 는 입력 transcript_path 로 lib/teammate_turn_report.py 판정:
#     final → done(agent_keep 유효 시 keep) / interim → idle / none → silent / unknown·판정기 부재 → idle(done·keep 이면 유지)
#   경로 B(리드 프로세스) idle 은 판정 없이 idle(done·keep 이면 유지).
#   argv 1번째(run|sendmsg|idle)가 있으면 hook_event_name 보다 우선한다(테스트·수동 호출용).
# 대상 pane 결정 2경로:
#   (A) 팀원 프로세스에서 실행된 경우: 부모 체인(최대 5단계)의 /proc/<pid>/cmdline 에 --agent-id 인자가 있으면 $TMUX_PANE.
#   (B) 리드 프로세스에서 실행된 경우(TeammateIdle 등): 입력 teammate_name 으로 teams/<team>/config.json 의 tmuxPaneId 조회 +
#       PostToolUse_Agent_pane_label.sh 와 동일한 소유 판정 통과 시에만. 이 경로에서 $TMUX_PANE(메인 pane)은 절대 쓰지 않는다.
# 모든 실패·비팀원 = 즉시 exit 0 무출력(표시 전용, TeammateIdle 의 exit 2 차단 의미를 피하려 항상 0).
# 형식 자동 재적용(2026-10-08): 캐시는 "<state> <ver>" 1줄. ver 가 lib/pane_border_fmt.sh 의 PANE_BORDER_VER 와 다르면(구 1단어 캐시 포함)
#   자기 $PANE 에만 단일 tmux 체인으로 @agent_state·pane-border-format·두 border style·세션 status-interval 1 을 재적용한다. 같으면 기존대로.
#   재적용 시 체인과 분리된 별도 호출(set -o)로 스피너 위상 기준 @spin_t0 를 보충한다(이미 있으면 유지).
# 메인 pane 집계(2026-10-11): 팀원 상태가 실제로 바뀐 직후(경로 A/B)와 리드 프로세스 idle(경로 L) 직후 lib/main_pane_state.sh 로
#   메인(리드) pane 에 자기 팀원 상태 집계(run>silent>idle>keep, 없음·전원 종료=done)를 표시한다. 기존 메인 표시는 유지하고 상태 점만 끼운다.
# 디버그: PANE_STATE_DEBUG=1 일 때만 session-env/<UUID>/logs/pane_state_dot.log 에 1줄 기록(기본 무출력).
set -u

ARG1="${1:-}"
INPUT=""; _IN_READ=0
_readin() {  # stdin 을 한 번만 읽는다(내장 read, fork 없음)
  [ "$_IN_READ" = 1 ] && return
  _IN_READ=1
  [ -t 0 ] && return
  IFS= read -r -d '' -t 3 INPUT 2>/dev/null || true
}

LOGUUID=""; PATHSEL="none"
_dbg() {  # PANE_STATE_DEBUG=1 일 때만 1줄 로그
  [ "${PANE_STATE_DEBUG:-0}" = 1 ] || return 0
  local d f ts js
  _readin
  js="${INPUT//$'\n'/ }"; js="${js:0:1500}"
  d="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${LOGUUID:-${PIPELINE_UUID:-}}/logs"
  if [ -n "${LOGUUID:-${PIPELINE_UUID:-}}" ] && [ -d "$d" ]; then f="$d/pane_state_dot.log"; else f="/tmp/pane_state_dot.log"; fi
  printf -v ts '%(%Y-%m-%dT%H:%M:%S)T' -1
  printf '%s pid=%s pane=%s path=%s arg=%s | %s | %s\n' "$ts" "$$" "${TMUX_PANE:-}" "$PATHSEL" "$ARG1" "$1" "$js" >> "$f" 2>/dev/null
  return 0
}

# sendmsg 는 상태를 바꾸지 않는다(보고 여부는 idle 시점 트랜스크립트 판정이 결정) — 가장 먼저 종료
[ "$ARG1" = sendmsg ] && exit 0

[ -n "${TMUX:-}${TMUX_PANE:-}" ] || { _dbg "no-tmux"; exit 0; }

# (A) 부모 체인 탐색: --agent-id 인자 보유 프로세스가 있으면 팀원 세션(AGENTID=NAME@TEAM 도 함께 추출)
AGENTID=""
_chain_agent() {
  local pid=$$ i a s ppid found=0 nxt=0 nxa=0
  for i in 1 2 3 4 5; do
    case "$pid" in ""|0|1|*[!0-9]*) break;; esac
    if [ -r "/proc/$pid/cmdline" ]; then
      while IFS= read -r -d '' a; do
        if [ "$a" = "--agent-id" ]; then found=1; nxa=1
        elif [ "$a" = "--parent-session-id" ]; then nxt=1
        elif [ "$nxa" = 1 ]; then AGENTID="$a"; nxa=0
        elif [ "$nxt" = 1 ]; then LOGUUID="$a"; nxt=0; fi
      done < "/proc/$pid/cmdline"
      [ "$found" = 1 ] && return 0
    fi
    s=$(<"/proc/$pid/stat") || break
    s="${s##*) }"
    read -r _ ppid _ <<<"$s"
    pid="$ppid"
  done
  return 1
}

PANE=""
if _chain_agent; then
  PATHSEL="A"
  PANE="${TMUX_PANE:-}"
else
  # (L) 리드 idle: 메인 pane 팀원 집계 재표시(본문은 lib/main_pane_state.sh main_pane_lead_idle — 팀원 핫패스 파싱 최소화)
  if [ "$ARG1" = idle ] && [ -n "${TMUX_PANE:-}" ]; then
    _readin; _LSD="${BASH_SOURCE[0]%/*}"; [ "$_LSD" = "${BASH_SOURCE[0]}" ] && _LSD=.
    . "$_LSD/lib/main_pane_state.sh" 2>/dev/null && main_pane_lead_idle "$INPUT" "$TMUX_PANE"
  fi
  # (B) 리드 프로세스: TeammateIdle/Stop 처럼 teammate_name 이 입력에 있을 때만
  [ -n "$ARG1" ] && { _dbg "nonteammate-argv"; exit 0; }
  _readin
  case "$INPUT" in *'"teammate_name"'*) ;; *) _dbg "nonteammate"; exit 0;; esac
  PATHSEL="B"
  command -v jq >/dev/null 2>&1 || exit 0
  TNAME=$(jq -r '.teammate_name // empty' <<<"$INPUT" 2>/dev/null)
  TTEAM=$(jq -r '.team_name // empty' <<<"$INPUT" 2>/dev/null)
  SID=$(jq -r '.session_id // empty' <<<"$INPUT" 2>/dev/null)
  LOGUUID="$SID"
  case "$TNAME" in ""|*[!a-zA-Z0-9._-]*) exit 0;; esac
  CFGD="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  UUID="${PIPELINE_UUID:-$SID}"
  [ -n "$UUID" ] || exit 0
  if [ -z "$TTEAM" ] && [ -r "$CFGD/session-env/$UUID/team_name" ]; then read -r TTEAM < "$CFGD/session-env/$UUID/team_name"; fi
  case "$TTEAM" in ""|*/*|*..*) exit 0;; esac
  CFG="$CFGD/teams/$TTEAM/config.json"
  [ -f "$CFG" ] || exit 0
  LEAD=$(jq -r '.leadSessionId // empty' "$CFG" 2>/dev/null)
  PANE=$(jq -r --arg n "$TNAME" '.members[]|select(.name==$n)|.tmuxPaneId // empty' "$CFG" 2>/dev/null | head -1)
  case "$PANE" in %[0-9]*) ;; *) exit 0;; esac
  if [ "$LEAD" != "$UUID" ] && [ "$LEAD" != "$SID" ]; then
    # leadSessionId 불일치(재개 세션): pane 프로세스 cmdline 의 --agent-id NAME@TEAM AND --parent-session-id UUID 로 판정
    ppid=$(tmux display -p -t "$PANE" -F '#{pane_pid}' 2>/dev/null) || exit 0
    case "$ppid" in ""|*[!0-9]*) exit 0;; esac
    pids="$ppid"
    for p in $(pgrep -P "$ppid" 2>/dev/null); do
      pids="$pids $p"
      for c in $(pgrep -P "$p" 2>/dev/null); do pids="$pids $c"; done
    done
    own=0
    for p in $pids; do
      cmd=$(tr '\0' ' ' 2>/dev/null < "/proc/$p/cmdline") || continue
      cmd=" $cmd "
      case "$cmd" in *" --agent-id ${TNAME}@${TTEAM} "*) ;; *) continue;; esac
      case "$cmd" in *" --parent-session-id ${UUID} "*|*" --parent-session-id ${SID} "*) own=1; break;; esac
    done
    [ "$own" = 1 ] || exit 0
  fi
fi
case "$PANE" in %[0-9]*) ;; *) _dbg "no-pane"; exit 0;; esac

# 이벤트 결정
EV=""
case "$ARG1" in run|idle) EV="$ARG1";; esac
if [ -z "$EV" ]; then
  _readin
  if [[ $INPUT =~ \"hook_event_name\"[[:space:]]*:[[:space:]]*\"([A-Za-z]+)\" ]]; then
    case "${BASH_REMATCH[1]}" in
      PreToolUse) EV=run;;
      TeammateIdle|Stop) EV=idle;;
    esac
  fi
fi
_dbg "ev=${EV:-none}"
[ -n "$EV" ] || exit 0

# 상태 캐시(tmux 서버·pane 별) — 같은 값이면 tmux 호출 생략
CK="${TMUX%,*}"; CK="${CK//[^a-zA-Z0-9]/_}"
CACHE="${XDG_RUNTIME_DIR:-/tmp}/pane_state_${CK:-x}_${PANE#%}"
CUR=""; CVER=""
[ -r "$CACHE" ] && read -r CUR CVER < "$CACHE"

_SD="${BASH_SOURCE[0]%/*}"; [ "$_SD" = "${BASH_SOURCE[0]}" ] && _SD=.
NEW=""
case "$EV" in
  run) NEW=run;;
  idle)
    # 경로 A: 팀원 자신의 트랜스크립트로 이번 턴 보고 여부 판정(판정기 출력 '<kind> <turn_start> <report_at> <keep>')
    KIND=unknown; KEEPOK=no
    if [ "$PATHSEL" = A ]; then
      _readin
      TP=""
      [[ $INPUT =~ \"transcript_path\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] && TP="${BASH_REMATCH[1]}"
      JUDGE="$_SD/lib/teammate_turn_report.py"
      if [ -n "$TP" ] && [ -f "$TP" ] && [ -f "$JUDGE" ]; then
        set -- --transcript "$TP"
        # agent_keep 파일: 리드 UUID·이름이 안전 문자일 때만(자기 리드 세션 경로만 사용)
        _AN="${AGENTID%%@*}"
        case "$LOGUUID" in ""|*[!a-zA-Z0-9-]*) ;; *)
          case "$_AN" in ""|*[!a-zA-Z0-9._-]*) ;; *)
            set -- "$@" --keep "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/$LOGUUID/agent_keep/$_AN";; esac;; esac
        JOUT=$(timeout 5 python3 -I "$JUDGE" "$@" 2>/dev/null) || JOUT=""
        read -r _K _ _ _KP <<<"$JOUT"
        case "$_K" in final|interim|none|unknown) KIND="$_K";; esac
        [ "${_KP:-}" = ok ] && KEEPOK=ok
      fi
      _dbg "judge kind=$KIND keep=$KEEPOK"
    fi
    case "$KIND" in
      final) if [ "$KEEPOK" = ok ]; then NEW=keep; else NEW=done; fi;;
      interim) NEW=idle;;
      none) NEW=silent;;
      *)
        if [ -z "$CUR" ]; then CUR=$(tmux show -p -t "$PANE" -v @agent_state 2>/dev/null); fi
        case "$CUR" in done|keep) NEW="$CUR";; *) NEW=idle;; esac;;
    esac;;
esac
[ -n "$NEW" ] || exit 0
# 형식 단일 출처 로드(fork 없음). 실패 시 VER 빈 값 → 재적용만 생략하고 상태 갱신은 수행
# VER 메모(XDG, 60초 유효·lib 경로별): 캐시 히트가 NTFS lib 를 매번 열지 않게 한다(NTFS 접근 1회 3.5~6ms 실측 2026-10-11).
#   메모 VER == 캐시 VER 이면 lib 미로드(재적용 불필요). 부재·만료·불일치면 lib 를 source 하고 메모 갱신. lib 변경은 최대 60초 뒤 반영.
PANE_BORDER_VER=""; PANE_BORDER_FMT=""; _VM="${XDG_RUNTIME_DIR:-/tmp}/pane_border_ver_${_SD//[^a-zA-Z0-9]/_}"; _MV=""; _MT=""
printf -v _NOW '%(%s)T' -1
[ -r "$_VM" ] && read -r _MV _MT < "$_VM"
case "$_MT" in ""|*[!0-9]*) _MT=0;; esac
if [ -n "$_MV" ] && [ "$_MV" = "$CVER" ] && [ $((_NOW-_MT)) -ge 0 ] && [ $((_NOW-_MT)) -lt 60 ]; then
  PANE_BORDER_VER="$_MV"
else
  . "$_SD/lib/pane_border_fmt.sh" 2>/dev/null || PANE_BORDER_VER=""
  [ -n "$PANE_BORDER_VER" ] && printf '%s %s\n' "$PANE_BORDER_VER" "$_NOW" > "$_VM" 2>/dev/null
fi
if [ -n "$PANE_BORDER_VER" ] && [ "$CVER" != "$PANE_BORDER_VER" ]; then
  # 옛 형식/구 캐시: 자기 pane 에만 단일 tmux 체인으로 형식·스타일·세션 status-interval 재적용(-g 금지)
  _dbg "reapply cver=${CVER:-none}"
  tmux set -p -t "$PANE" @agent_state "$NEW" \; set -p -t "$PANE" pane-border-format "$PANE_BORDER_FMT" \
    \; set -p -t "$PANE" pane-border-style "$PANE_BORDER_STY" \; set -p -t "$PANE" pane-active-border-style "$PANE_BORDER_STY" \
    \; set -t "$PANE" status-interval 1 >/dev/null 2>&1 && printf '%s %s\n' "$NEW" "$PANE_BORDER_VER" > "$CACHE" 2>/dev/null
  # 스피너 위상 기준 @spin_t0 보충(있으면 유지). set -o 는 기존 값이면 rc=1 로 체인을 끊으므로 위 체인과 분리한 별도 호출, rc 무시
  printf -v _T0 '%(%s)T' -1; tmux set -o -p -t "$PANE" @spin_t0 "$_T0" >/dev/null 2>&1
  _CHG=1
elif [ "$NEW" != "$CUR" ]; then
  tmux set -p -t "$PANE" @agent_state "$NEW" >/dev/null 2>&1 && printf '%s\n' "$NEW${CVER:+ $CVER}" > "$CACHE" 2>/dev/null
  _CHG=1
fi
# 팀원 상태가 실제로 바뀐 때만 메인(리드) pane 의 집계 표시를 다시 계산(lib/main_pane_state.sh, 같은 값이면 tmux 호출 없음)
if [ "${_CHG:-0}" = 1 ] && . "$_SD/lib/main_pane_state.sh" 2>/dev/null; then
  if [ "$PATHSEL" = A ]; then
    [ -n "$AGENTID" ] && main_pane_refresh "$PANE" "$LOGUUID" "${AGENTID#*@}" "$AGENTID" ""
  else
    main_pane_refresh "$PANE" "${UUID:-}" "${TTEAM:-}" "" "${TMUX_PANE:-}"
  fi
fi
exit 0
