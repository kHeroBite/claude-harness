#!/bin/bash
# 시스템 부하(load1)가 높을 때 팀원 spawn 을 2개씩 20초 시차로 나누게 하는 PreToolUse(Agent) 가드 (F-LOAD-STAGGER)
#
# ── 왜 필요한가 (2026-10-16 실측) ─────────────────────────────────────────
# 시스템 정체(load≈1000) 중 한 응답에서 여러 팀원을 동시 spawn 하자 생성 직후 프로세스가 사라지는 사고가 3회 났다
# (odev-A·odone-1 은 첫 지시 미소비, odev-6 은 ack 전후 소실). 복구는 TaskStop + 같은 역할 재spawn 으로 됐다.
# ★원인 자체(Claude Code 런타임의 팀원 프로세스 기동·유지 실패)는 하네스 밖이라 고칠 수 없다.★
#   커널 로그 확인은 root 가 필요하고 root 는 금지다. 이 hook 은 동시 기동 수를 줄여 발생 확률을 낮추는 완화책일 뿐이다.
#
# ── 판정 ──────────────────────────────────────────────────────────────
# 대상     : tool_input.team_name 이 있는 Agent 호출(팀원 spawn)만. 그 외 즉시 통과.
# 부하     : LS_LOADAVG_FILE(기본 /proc/loadavg) 첫 값 load1. load1 ≤ LS_LOAD(기본 50 — 메모리 load_gate_threshold_50) → 무기록 통과.
# 시차     : load1 > LS_LOAD 이고 자기 세션 logs/load_stagger.log 에 최근 LS_WINDOW(기본 20)초 안의 ALLOW 가
#            LS_MAX(기본 2)건 이상이면 deny("N초 뒤 재시도"). 아니면 ALLOW 1줄 기록 후 통과(시차 안내 additionalContext).
#            → 한 응답에서 3개 이상 동시 spawn 하면 3번째부터 보류되고, 다음 2개는 20초 뒤에 나간다.
# fail-open: jq 부재·입력 파싱 실패·loadavg 판독 실패·세션 디렉토리 부재·flock 실패 → 통과.
#
# ── 스위치 ────────────────────────────────────────────────────────────
#   파일 off 스위치는 두지 않는다(하네스 정책 — 사람 전용이면 자율 진행을 막고, 에이전트가 쓰면 우회 통로가 된다).
#   LS_MODE  : block(기본) | warn(보류 대신 안내만) | off — ★시험용 오버라이드 전용★. settings 등록은 env 를 주지 않으므로 운영은 항상 block.
# 테스트 주입 env: LS_LOADAVG_FILE, LS_NOW(epoch), LS_SESSION_BASE(session-env 상위 경로)
# 로그: session-env/<session_id>/logs/load_stagger.log ("<epoch> ALLOW|DENY|WARN name=… load=…")
# 세션 격리: 입력 session_id 의 자기 세션 디렉토리만 읽고 쓴다. 타 세션 정보 출력 없음.
# parallel_spawn_guard.py 는 이 로그(최근 300초 기록)·부하를 보고 S1 '동시 spawn 하라' 경고를 생략한다(충돌 방지).

trap 'exit 0' ERR

LS_MODE="${LS_MODE:-block}"
[ "$LS_MODE" = "off" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(timeout 5 cat 2>/dev/null) || exit 0
[ -z "$INPUT" ] && exit 0

_parsed=$(printf '%s' "$INPUT" | jq -r '[.tool_name // "", .session_id // "", (.tool_input.team_name // ""), (.tool_input.name // "")] | @tsv' 2>/dev/null) || exit 0
IFS=$'\t' read -r TOOL SID TEAM NAME <<< "$_parsed"
[ "$TOOL" = "Agent" ] || exit 0
[ -n "$TEAM" ] || exit 0
[[ "$SID" =~ ^[0-9a-f-]{36}$ ]] || exit 0

# ── 부하 판독 ─────────────────────────────────────────────────────────
LOADF="${LS_LOADAVG_FILE:-/proc/loadavg}"
read -r LOAD1 _rest < "$LOADF" 2>/dev/null || exit 0
[[ "$LOAD1" =~ ^([0-9]+)(\.([0-9]+))?$ ]] || exit 0
_li="${BASH_REMATCH[1]}"; _lf="${BASH_REMATCH[3]}"
THR="${LS_LOAD:-50}"
[[ "$THR" =~ ^[0-9]+$ ]] || THR=50
# load1 > THR 판정 (정수부 비교 + 같으면 소수부에 0 아닌 숫자가 있는가)
_over=0
if (( 10#$_li > THR )); then _over=1
elif (( 10#$_li == THR )) && [[ "$_lf" =~ [1-9] ]]; then _over=1
fi
(( _over )) || exit 0

# ── 시차 판정 ─────────────────────────────────────────────────────────
WINDOW="${LS_WINDOW:-20}"; [[ "$WINDOW" =~ ^[0-9]+$ ]] || WINDOW=20
MAXN="${LS_MAX:-2}";       [[ "$MAXN" =~ ^[0-9]+$ ]] || MAXN=2
NOW="${LS_NOW:-$(date +%s)}"; [[ "$NOW" =~ ^[0-9]+$ ]] || exit 0

SBASE="${LS_SESSION_BASE:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env}"
SDIR="$SBASE/$SID"
[ -d "$SDIR" ] || exit 0          # 자기 세션 디렉토리가 없으면 만들지 않는다
mkdir -p "$SDIR/logs" 2>/dev/null || exit 0
LOG="$SDIR/logs/load_stagger.log"

# 한 응답의 동시 Agent 호출은 hook 이 병렬로 돌 수 있다 → 판정·기록을 flock 으로 직렬화
exec 9>>"$LOG" 2>/dev/null || exit 0
flock -w 2 9 2>/dev/null || exit 0

_cnt=0; _oldest=""
while read -r _ts _kind _r; do
  [[ "$_ts" =~ ^[0-9]+$ ]] || continue
  [ "$_kind" = "ALLOW" ] || continue
  (( _ts > NOW - WINDOW )) || continue
  _cnt=$((_cnt + 1))
  if [ -z "$_oldest" ] || (( _ts < _oldest )); then _oldest=$_ts; fi
done < <(tail -n 50 "$LOG" 2>/dev/null)

# 로그 600줄 초과 시 뒤 200줄만 남긴다(같은 잠금 안)
if [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt 600 ]; then
  _tmp="$LOG.tmp.$$"
  tail -n 200 "$LOG" > "$_tmp" 2>/dev/null && cat "$_tmp" > "$LOG" 2>/dev/null
  rm -f "$_tmp" 2>/dev/null
fi

_name="${NAME:-?}"
if (( _cnt >= MAXN )); then
  _wait=$(( _oldest + WINDOW - NOW )); (( _wait < 1 )) && _wait=1
  _msg="🚦 [F-LOAD-STAGGER] 부하 load1=${LOAD1} (>${THR}) — 팀원 spawn 은 ${MAXN}개씩 ${WINDOW}초 시차로 나눠야 합니다(최근 ${WINDOW}초 안 ${_cnt}건 기동). '${_name}' spawn 을 보류합니다. ${_wait}초 뒤 같은 Agent 호출을 다시 보내십시오. 원인(정체 중 동시 기동 직후 팀원 소실)은 Claude Code 런타임이라 고칠 수 없고 이 가드는 완화책입니다."
  if [ "$LS_MODE" = "warn" ]; then
    printf '%s WARN name=%s load=%s cnt=%s\n' "$NOW" "$_name" "$LOAD1" "$_cnt" >&9
    jq -cn --arg t "$_msg" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$t}}'
    exit 0
  fi
  printf '%s DENY name=%s load=%s cnt=%s retry=%s\n' "$NOW" "$_name" "$LOAD1" "$_cnt" "$_wait" >&9
  jq -cn --arg t "$_msg" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$t}}'
  exit 0
fi

printf '%s ALLOW name=%s load=%s\n' "$NOW" "$_name" "$LOAD1" >&9
_ctx="🚦 [F-LOAD-STAGGER] 부하 load1=${LOAD1} (>${THR}) — '${_name}' spawn 허용(최근 ${WINDOW}초 $((_cnt + 1))/${MAXN}). 다음 팀원은 ${MAXN}개씩 ${WINDOW}초 시차로 spawn 하고, spawn_ack 경보(소실)가 오면 TaskStop(<이름>) 후 같은 역할로 재spawn 하십시오."
jq -cn --arg t "$_ctx" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$t}}'
exit 0
