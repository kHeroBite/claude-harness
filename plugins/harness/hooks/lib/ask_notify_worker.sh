#!/bin/bash
# 질문 1건당 1개 setsid 로 떠서 질문이 닫혔는지 감시해 '?' 표시를 풀고, 지연 시간 뒤에도 미답변이면 ntfy 를 정확히 1회 보내는 프로세스
# 사용법: ask_notify_worker.sh <SD> <id> <project_dir> [transcript_path]   (main_ask_state.sh 가 setsid -f 로 기동)
# 왜 감시가 여기 있나: 질문창을 Esc·거절·Ctrl+C 로 닫으면 hook 이벤트가 하나도 오지 않는다(공식 문서: Stop 은 사용자 인터럽트에 안 돌고,
#   실행 중 도구 취소는 PostToolUseFailure 를 안 쏜다. 2026-11-04 E2E 실측: Esc 뒤 다음 입력 전까지 main_ask_state 호출 0회).
#   hook 만으로는 다음 입력 때까지 '?' 가 남으므로, 질문이 열려 있는 동안만 사는 이 프로세스가 직접 닫힘을 본다.
#   Esc 는 '선택 안 함'이다. 표시만 풀 뿐 승인·답변 기록을 남기지 않는다. 메인은 도구 결과의 지시대로 사용자의 다음 입력을 기다린다.
# 절차:
#   1. <SD>/ask_notify/worker.pid 에 "id pid" 기록. ASK_NOTIFY_POLL_SEC(기본 2초)마다 아래를 본다.
#      해제 시 main_ask_state.sh 가 프로세스 그룹째 TERM 을 보낸다(대기 중 sleep 도 함께 정리).
#   2. 표식 <SD>/ask_wait 부재 또는 id 불일치 → skip cleared (다른 질문의 표식·표시는 건드리지 않는다)
#   3. 표식의 claude_pid 가 있고 살아 있지 않으면 → skip session_gone
#      (자기 표식만 지운다. pane 번호는 tmux 재기동으로 재사용됐을 수 있어 건드리지 않는다. 빈 값이면 확인 생략)
#   4. 닫힘 판정 → 자기 표식 삭제 + 자기 pane(TMUX_PANE) @main_ask 해제 후 종료(closed <사유>)
#      - 트랜스크립트에 "tool_use_id":"<id>" 와 "tool_result" 를 함께 품은 줄(답변·Esc·거절 모두 여기에 쓰인다) → closed tool_result
#      - 세션 레지스트리 status=idle 2회 연속(sessionId 일치 때만, 파일 없음·파싱 불가 = 판단 안 함) → closed registry_idle
#   5. 지연(ASK_NOTIFY_DELAY_SEC, 기본 600초, 시험용 단축)이 지나면 1회만: 레지스트리 status 가 있고 waiting 이 아니면 skip registry_<status>,
#      mkdir <SD>/ask_notify/sent_<id> 실패면 skip already_sent, 아니면
#      <SD>/ask_notify/ntfy_payload.json 작성 → lib/ntfy_send.sh --session-dir <SD>/ask_notify --project-dir <P> [--dry-run]
#      (세션 디렉터리의 ofinish ntfy_payload.json 과 섞이지 않게 하위 디렉터리를 쓴다. 제목 [프로젝트명] 접두는 ntfy_send.sh 가 붙인다)
#      ASK_NOTIFY_DRYRUN 또는 NTFY_DRYRUN 이 비어 있지 않고 0 이 아니면 --dry-run (실발송 없음).
#   6. 발송 뒤에도 질문이 닫힐 때까지 감시를 계속한다. 상한 ASK_WATCH_MAX_SEC(기본 7일, 0 이면 발송 단계 직후 종료 — 시험용)에 닿으면 watch_end 로 끝난다.
# 기록: 모든 판정·발송 결과를 <SD>/logs/ask_notify.log 에 1줄씩. 화면 출력 없음.
# 비용: 질문이 열려 있는 동안만 존재한다. 주기마다 sleep 1 + stat 1 fork, 트랜스크립트가 커졌을 때만 tail·grep.
# 격리: 자기 <SD> 와 자기 TMUX_PANE 만 쓴다.

SD="${1:-}"; ID="${2:-}"; PROJ="${3:-}"; TRP="${4:-}"
exec </dev/null >/dev/null 2>&1
[ -n "$SD" ] && [ -d "$SD" ] || exit 0
case "$ID" in ""|*[!A-Za-z0-9_-]*) exit 0;; esac

SELF="${BASH_SOURCE[0]}"
LIB_DIR="${SELF%/*}"; [ "$LIB_DIR" = "$SELF" ] && LIB_DIR=.
AN="$SD/ask_notify"
LOGD="$SD/logs"
mkdir -p "$AN" "$LOGD" 2>/dev/null

_log() {
  local ts
  printf -v ts '%(%Y-%m-%dT%H:%M:%S)T' -1
  printf '%s id=%s pid=%s %s\n' "$ts" "$ID" "$$" "$1" >> "$LOGD/ask_notify.log" 2>/dev/null
  return 0
}

SLEEP_PID=""
trap '[ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null; _log "killed"; exit 0' TERM INT HUP

printf '%s %s\n' "$ID" "$$" > "$AN/worker.pid" 2>/dev/null

DELAY="${ASK_NOTIFY_DELAY_SEC:-600}"
case "$DELAY" in ""|*[!0-9]*) DELAY=600;; esac
POLL="${ASK_NOTIFY_POLL_SEC:-2}"
case "$POLL" in ""|0|*[!0-9]*) POLL=2;; esac
WATCH_MAX="${ASK_WATCH_MAX_SEC:-604800}"
case "$WATCH_MAX" in ""|*[!0-9]*) WATCH_MAX=604800;; esac
_log "start delay=${DELAY}s poll=${POLL}s"

# 끝날 때 자기 pid 기록을 지운다(해제가 이미 끝난 프로세스를 찾지 않게) — 자기 기록일 때만 지운다
_drop_pid() {
  local wid wpid
  [ -r "$AN/worker.pid" ] || return 0
  read -r wid wpid < "$AN/worker.pid" || true
  [ "$wpid" = "$$" ] && rm -f "$AN/worker.pid" 2>/dev/null
  return 0
}

SID="${SD%/}"; SID="${SID##*/}"
M_ID=""; M_KIND=""; M_EP=""; M_PID=""
_read_mark() {
  M_ID=""; M_KIND=""; M_EP=""; M_PID=""
  if [ -f "$SD/ask_wait" ]; then IFS=$'\t' read -r M_ID M_KIND M_EP M_PID < "$SD/ask_wait"; fi
  case "$M_PID" in *[!0-9]*) M_PID="";; esac
  return 0
}

# 세션 레지스트리 status → R_ST. 이 세션 것이 아니거나 못 읽으면 빈 값(판단 안 함). fork 없이 읽는다.
R_ST=""
_read_registry() {
  local j="" reg re_sid='"sessionId"[[:space:]]*:[[:space:]]*"([^"]*)"' re_st='"status"[[:space:]]*:[[:space:]]*"([^"]*)"'
  R_ST=""
  [ -n "$M_PID" ] || return 0
  reg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions/$M_PID.json"
  [ -r "$reg" ] || return 0
  IFS= read -r -d '' j < "$reg"
  [[ $j =~ $re_sid ]] && [ "${BASH_REMATCH[1]}" = "$SID" ] || return 0
  [[ $j =~ $re_st ]] && R_ST="${BASH_REMATCH[1]}"
  return 0
}

# 트랜스크립트에 이 질문의 tool_result 가 있으면 0. 커졌을 때만 읽고, 줄이 잘리지 않게 1MiB 겹쳐 읽는다.
TR_SEEN=0
_tr_closed() {
  local sz from
  [ -n "$TRP" ] && [ -r "$TRP" ] || return 1
  sz=$(stat -c %s "$TRP" 2>/dev/null) || return 1
  [ "$sz" = "$TR_SEEN" ] && return 1
  from=$(( TR_SEEN - 1048576 )); [ "$from" -lt 0 ] && from=0
  TR_SEEN="$sz"
  tail -c +"$((from + 1))" "$TRP" 2>/dev/null | grep -F "\"tool_use_id\":\"$ID\"" | grep -qF '"tool_result"'
}

# 질문이 닫혔다 — 자기 표식 삭제 + 자기 pane 표시 해제. 승인·답변으로 기록하지 않는다.
_close() {
  rm -f "$SD/ask_wait" 2>/dev/null
  if [ -n "${TMUX_PANE:-}" ] && command -v tmux >/dev/null 2>&1; then
    tmux set -pu -t "$TMUX_PANE" @main_ask >/dev/null 2>&1
  fi
  _log "closed $1"
  _drop_pid
  exit 0
}

# 지연 알림 1회 — 어떤 결과든 돌아와 감시를 계속한다
_send_once() {
  local SUMMARY NOW MIN SENDER DRY v ARGS OUT RC
  _read_registry
  if [ -n "$R_ST" ] && [ "$R_ST" != waiting ]; then
    case "$R_ST" in *[!A-Za-z0-9_-]*) R_ST="other";; esac
    _log "skip registry_$R_ST"; return 0
  fi

  # 질문당 1회 보장
  if ! mkdir "$AN/sent_$ID" 2>/dev/null; then _log "skip already_sent"; return 0; fi

  command -v jq >/dev/null 2>&1 || { _log "skip no_jq"; return 0; }
  SUMMARY=""
  [ -r "$AN/summary.txt" ] && IFS= read -r SUMMARY < "$AN/summary.txt"
  [ -n "$SUMMARY" ] || SUMMARY="답변 대기 중"
  printf -v NOW '%(%s)T' -1
  case "$M_EP" in ""|*[!0-9]*) M_EP="$NOW";; esac
  MIN=$(( (NOW - M_EP) / 60 ))
  jq -n --arg t "❓ 답변 대기 ${MIN}분" --arg m "$SUMMARY" \
    '{title:$t, message:$m, tags:["question"], priority:4}' > "$AN/ntfy_payload.json" 2>/dev/null \
    || { _log "skip payload_fail"; return 0; }

  SENDER="${ASK_NTFY_SEND:-}"
  [ -n "$SENDER" ] && [ -f "$SENDER" ] || SENDER="$LIB_DIR/ntfy_send.sh"
  [ -f "$SENDER" ] || SENDER="${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/ntfy_send.sh"
  [ -f "$SENDER" ] || { _log "skip no_ntfy_send"; return 0; }

  DRY=""
  for v in "${ASK_NOTIFY_DRYRUN:-}" "${NTFY_DRYRUN:-}"; do
    [ -n "$v" ] && [ "$v" != 0 ] && DRY="--dry-run"
  done
  ARGS=(--session-dir "$AN")
  [ -n "$PROJ" ] && [ -d "$PROJ" ] && ARGS+=(--project-dir "$PROJ")
  [ -n "$DRY" ] && ARGS+=("$DRY")
  OUT=$(bash "$SENDER" "${ARGS[@]}" 2>&1); RC=$?
  OUT="${OUT//$'\n'/ }"
  _log "sent rc=$RC ${DRY:+dry-run }out=${OUT:0:1500}"
  return 0
}

# 감시 루프
printf -v T0 '%(%s)T' -1
NOTIFIED=0
IDLE_N=0
while :; do
  sleep "$POLL" &
  SLEEP_PID=$!
  wait "$SLEEP_PID"
  SLEEP_PID=""

  _read_mark
  if [ "$M_ID" != "$ID" ]; then _log "skip cleared"; _drop_pid; exit 0; fi
  if [ -n "$M_PID" ] && [ ! -d "/proc/$M_PID" ]; then
    rm -f "$SD/ask_wait" 2>/dev/null
    _log "skip session_gone claude_pid=$M_PID"; _drop_pid; exit 0
  fi

  _tr_closed && _close tool_result
  _read_registry
  if [ "$R_ST" = idle ]; then
    IDLE_N=$((IDLE_N + 1))
    [ "$IDLE_N" -ge 2 ] && _close registry_idle
  else
    IDLE_N=0
  fi

  printf -v NOW '%(%s)T' -1
  ELAPSED=$((NOW - T0))
  if [ "$NOTIFIED" = 0 ] && [ "$ELAPSED" -ge "$DELAY" ]; then
    NOTIFIED=1
    _send_once
  fi
  if [ "$NOTIFIED" = 1 ] && [ "$ELAPSED" -ge "$WATCH_MAX" ]; then
    _log "watch_end elapsed=${ELAPSED}s"; _drop_pid; exit 0
  fi
done
