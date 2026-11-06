#!/bin/bash
# 팀원이 이번 턴에 team-lead 보고 없이 대기하려 하면 exit 2 로 되돌려 보고를 강제하는 TeammateIdle 게이트
#
# 등록: TeammateIdle (timeout 10) — tmux 모드 팀원 프로세스에서만 동작 (계획서 conv_179142200000 §3-3)
# 판정: lib/teammate_turn_report.py (입력 transcript_path = 팀원 자신의 트랜스크립트)
#   final|interim → 상태 기록(status=final|reported, blocks=0) 후 exit 0
#   none          → 같은 턴 blocks < TRG_MAX_BLOCKS(기본 2) 이고 mode=block 이면 stderr 안내 + exit 2
#                   상한 도달 또는 mode=warn 이면 status=silent 기록 후 exit 0 (무한 루프 방지)
#   unknown       → 로그만 남기고 exit 0 (fail-open)
#   선행(2026-10-10 c174): lib/bg_job_guard.py — 분리 실행(setsid/nohup/&) 작업이 살아 있거나, 끝났는데 그 뒤 보고가 없으면
#                 kind 와 무관하게 exit 2 (착수 보고만으로는 통과 불가). 실행 건당 상한 BJG_MAX_BLOCKS(6), #bg:daemon 은 제외.
#                 상태: session-env/<LEAD>/teammate_turn/<NAME>.bg.json (리드 가드 J 규칙이 읽는다)
# 식별: 부모 체인 5단계 /proc/<pid>/cmdline 의 --agent-id NAME@TEAM, --parent-session-id LEAD
#       (pane_state_dot.sh _chain_agent 와 동일 방식). 식별 실패(in-process 모드 등) → exit 0
#       테스트 전용: TRG_TEST=1 일 때만 TRG_TEST_AGENT=NAME@TEAM, TRG_TEST_LEAD=<uuid> 사용
# 소유 검증: session-env/<LEAD>/team_name == TEAM 일 때만 처리 (세션 격리 — 자기 리드 영역만 쓴다)
# 스위치:
#   전역 OFF  : touch ${HARNESS_HOME:-$HOME/.harness}/current/hooks/.teammate_report_guard_off
#   세션 모드 : session-env/<LEAD>/teammate_report_guard_mode = off | warn | block (부재 시 env 또는 block)
#   env 기본값: TEAMMATE_REPORT_GUARD_MODE=off|warn|block
# 기록: session-env/<LEAD>/teammate_turn/<NAME>.json = {team,turn_start,blocks,status,silent_since,updated}
#       session-env/<LEAD>/logs/teammate_report_guard.log (ALLOW/BLOCK/SILENT/UNKNOWN 1줄)
# stdout 출력 없음. 내부 오류는 전부 exit 0 (의도한 exit 2 경로만 예외).

trap 'exit 0' ERR

[[ -f "${HARNESS_HOME:-$HOME/.harness}/current/hooks/.teammate_report_guard_off" ]] && exit 0

AGENT=""
LEAD=""
ATYPE=""
if [[ "${TRG_TEST:-}" == "1" ]]; then
  AGENT="${TRG_TEST_AGENT:-}"
  LEAD="${TRG_TEST_LEAD:-}"
  ATYPE="${TRG_TEST_AGENT_TYPE:-}"
else
  pid=$$
  for _ in 1 2 3 4 5; do
    [[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 1 )) || break
    if [[ -r "/proc/$pid/cmdline" ]]; then
      nxt=""
      ATYPE=""
      while IFS= read -r -d '' a; do
        if [[ "$nxt" == "agent" ]]; then AGENT="$a"; nxt=""
        elif [[ "$nxt" == "lead" ]]; then LEAD="$a"; nxt=""
        elif [[ "$nxt" == "atype" ]]; then ATYPE="$a"; nxt=""
        elif [[ "$a" == "--agent-id" ]]; then nxt="agent"
        elif [[ "$a" == "--parent-session-id" ]]; then nxt="lead"
        elif [[ "$a" == "--agent-type" ]]; then nxt="atype"
        fi
      done < "/proc/$pid/cmdline"
      [[ -n "$AGENT" ]] && break
    fi
    s=$(<"/proc/$pid/stat") || break
    s="${s##*) }"
    read -r _ pid _ <<<"$s"
  done
fi

NAME="${AGENT%%@*}"
TEAM="${AGENT#*@}"
[[ "$AGENT" == *@* ]] || exit 0
[[ "$NAME" =~ ^[A-Za-z0-9._-]+$ && "$TEAM" =~ ^[A-Za-z0-9._-]+$ ]] || exit 0
[[ "$NAME" != "." && "$NAME" != ".." && "$TEAM" != "." && "$TEAM" != ".." ]] || exit 0
[[ "$LEAD" =~ ^[0-9a-f-]{36}$ ]] || exit 0

CFGD="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SDIR="$CFGD/session-env/$LEAD"
[[ -f "$SDIR/team_name" ]] || exit 0
OWN_TEAM=$(tr -d '[:space:]' < "$SDIR/team_name" 2>/dev/null)
[[ "$OWN_TEAM" == "$TEAM" ]] || exit 0

MODE="${TEAMMATE_REPORT_GUARD_MODE:-block}"
if [[ -f "$SDIR/teammate_report_guard_mode" ]]; then
  MODE=$(tr -d '[:space:]' < "$SDIR/teammate_report_guard_mode" 2>/dev/null)
fi
case "$MODE" in
  off) exit 0 ;;
  warn|block) ;;
  *) MODE="block" ;;
esac

MAXB="${TRG_MAX_BLOCKS:-2}"
[[ "$MAXB" =~ ^[0-9]+$ ]] || MAXB=2

INPUT=$(timeout 5 cat 2>/dev/null) || INPUT=""
command -v jq >/dev/null 2>&1 || exit 0
TP=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)

LOGD="$SDIR/logs"
mkdir -p "$LOGD" "$SDIR/teammate_turn" 2>/dev/null || exit 0
LOG="$LOGD/teammate_report_guard.log"
STF="$SDIR/teammate_turn/$NAME.json"
NOW=$(date +%s)

_log() { printf '%s %s name=%s team=%s %s\n' "$(date -Iseconds)" "$1" "$NAME" "$TEAM" "$2" >> "$LOG" 2>/dev/null; }

# --- [K3 2026-11-06] SendMessage 가 없는 온디맨드 MCP 유형(mcp-*) 면제 ---
#   --agent-type(spawn 때 Claude Code 가 넣는 argv, 팀원이 못 바꾼다)이 ^mcp-[A-Za-z0-9._-]+$ 일 때만 본다.
#   그 밖의 유형은 정의 파일 내용과 무관하게 면제하지 않는다(정의 파일 위조로 면제받는 것을 막는다 —
#   write_guard 는 .claude/agents/ 쓰기를 보호하지 않는다).
#   정의 파일 탐색 순서: $CLAUDE_PROJECT_DIR, 입력 cwd, $HOME 의 .claude/agents/<유형>.md 중 처음 있는 것.
#   frontmatter tools 가 있고(한 줄 쉼표 목록 또는 여러 줄 YAML 목록) SendMessage·* 가 없을 때만 면제.
#   정의 없음·frontmatter 없음·tools 미기재·빈 목록·SendMessage 포함·* 포함은 종전대로 판정을 계속한다.
#   한계: 같은 uid 가 .claude/agents/mcp-<새이름>.md 를 만들 수는 있지만 spawn 은 리드만 한다(L-299).
if [[ "$ATYPE" =~ ^mcp-[A-Za-z0-9._-]+$ ]]; then
  _K3_CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
  _K3_DEF=""
  for _k3d in "${CLAUDE_PROJECT_DIR:-}" "$_K3_CWD" "$HOME"; do
    if [[ -n "$_k3d" && -f "$_k3d/.claude/agents/$ATYPE.md" ]]; then
      _K3_DEF="$_k3d/.claude/agents/$ATYPE.md"
      break
    fi
  done
  if [[ -n "$_K3_DEF" ]]; then
    _K3_PY='
import re, sys
Q = chr(34) + chr(39)
try:
    L = open(sys.argv[1], encoding="utf-8").read().splitlines()
except Exception:
    print("none"); sys.exit(0)
if not L or L[0].strip() != "---":
    print("none"); sys.exit(0)
fm = []
closed = False
for x in L[1:]:
    if x.strip() == "---":
        closed = True
        break
    fm.append(x)
if not closed:
    print("none"); sys.exit(0)
toks = None
for i, x in enumerate(fm):
    m = re.match(r"^tools\s*:\s*(.*)$", x)
    if not m:
        continue
    v = m.group(1).strip()
    if v:
        v = v.strip("[]")
        toks = [t.strip().strip(Q) for t in v.split(",")]
    else:
        toks = []
        for y in fm[i + 1:]:
            mm = re.match(r"^\s+-\s*(.+)$", y)
            if mm:
                toks.append(mm.group(1).strip().strip(Q))
            elif y.strip() == "":
                continue
            else:
                break
    break
toks = [t for t in (toks or []) if t]
if not toks:
    print("none")
elif any(t == "*" or t == "SendMessage" for t in toks):
    print("send")
else:
    print("nosend")
'
    _K3_TV=$(timeout 3 python3 -I -c "$_K3_PY" "$_K3_DEF" 2>/dev/null) || _K3_TV="none"
    if [[ "$_K3_TV" == "nosend" ]]; then
      _log EXEMPT_NO_SENDMSG "agent_type=$ATYPE def=$_K3_DEF"
      exit 0
    fi
  fi
fi

JUDGE="$(dirname "$(readlink -f "$0")")/lib/teammate_turn_report.py"
if [[ -z "$TP" || ! -f "$TP" || ! -f "$JUDGE" ]]; then
  _log UNKNOWN "reason=no-transcript-or-judge"
  exit 0
fi
OUT=$(timeout 8 python3 -I "$JUDGE" --transcript "$TP" --keep "$SDIR/agent_keep/$NAME" 2>/dev/null) || OUT="unknown 0 0 no"
read -r KIND TSTART RAT KEEP <<<"$OUT"
[[ "$TSTART" =~ ^[0-9]+$ ]] || TSTART=0

# 분리 실행 작업 미회수 게이트 (2026-10-10 c174 — obuild-1 이 setsid nohup 빌드 후 착수 보고만 하고 3시간 정체)
#   lib/bg_job_guard.py: 이 팀원이 setsid/nohup/& 로 띄운 작업이 아직 살아 있거나, 끝났는데 그 뒤 보고가 없으면 exit 2.
#   착수 보고(interim)로는 통과하지 못한다. 상한 BJG_MAX_BLOCKS(기본 6) 도달 시 통과하되 status=silent 로 남겨 리드 가드가 본다.
BJG="$(dirname "$(readlink -f "$0")")/lib/bg_job_guard.py"
if [[ -f "$BJG" ]]; then
  BV=$(timeout 6 python3 -I "$BJG" --transcript "$TP" --state "$SDIR/teammate_turn/$NAME.bg.json" 2>/dev/null) || BV="ok"
  read -r BK BW BFP BAT BN <<<"$BV"
  if [[ "$BK" == "block" ]]; then
    _log BG_BLOCK "kind=$BW fp=$BFP launched=$BAT n=$BN mode=$MODE"
    if [[ "$MODE" == "block" ]]; then
      if [[ "$BFP" == oio:* ]]; then
        # [사이클182] oio bash_exec 자체 백그라운드(oio_bg_*) — 하네스 완료 알림이 없어 팀원을 깨우지 않는다(2026-10-14 10:12→10:24 otest-m-1 12분 정체).
        #   완료는 done_file 존재로만 판정한다(pgrep 안내는 oio 작업에 맞지 않아 즉시 끝나므로 쓰지 않는다).
        ODONE="${BFP#oio:}"
        if [[ "$BW" == "running" ]]; then
          printf '⛔ [oio 백그라운드 미회수] oio 백그라운드는 너를 깨우지 않는다 — test -f %s 를 90초 이내 foreground 로 반복 확인한 뒤 결과를 보고하라. %s 에 띄운 이 작업은 아직 끝나지 않았다(완료 파일 없음). 지금 대기에 들어가면 완료 알림이 아무에게도 가지 않아 팀이 멈춘다. 예: mcp__oio__bash_exec(command="timeout 85 bash -c '\''until test -f %s; do sleep 5; done'\''; echo rc=$?", timeout_ms=100000) 를 rc=0 이 나올 때까지 반복하고, 로그(%s)를 확인해 SendMessage(to="team-lead") 로 보고하라. 의도한 상주 작업이면 명령에 #bg:daemon 을 붙여라. (차단 %s)\n' "$ODONE" "$BAT" "$ODONE" "${ODONE%.done}" "$BN" >&2
        else
          printf '⛔ [oio 백그라운드 미회수] oio 백그라운드는 너를 깨우지 않는다 — test -f %s 를 90초 이내 foreground 로 반복 확인한 뒤 결과를 보고하라. %s 에 띄운 이 작업은 끝났는데(완료 파일 있음) 그 뒤 team-lead 보고가 없다. 로그(%s)를 확인해 SendMessage(to="team-lead") 로 보고한 뒤 대기하라. (차단 %s)\n' "$ODONE" "$BAT" "${ODONE%.done}" "$BN" >&2
        fi
        exit 2
      fi
      if [[ "$BW" == "running" ]]; then
        # 2026-10-10: 종전 예시(timeout_ms=600000 + 57×10초 루프)는 120초 MCP 자동 백그라운드 전환 → oio "Invalid request parameters"
        #   고장(odev-10-2·10-4)을 그대로 유발했다. 한 번 호출 85초 이내 + 첫 글자 [ ] 패턴(pgrep 자기 매칭 방지)으로 바꿨다.
        BFPQ="[${BFP:0:1}]${BFP:1}"
        printf '⛔ [결과 미회수 방지] %s 에 분리 실행한 작업(%s)이 아직 돌고 있다. 지금 턴을 끝내면 완료 알림이 아무에게도 가지 않아 팀 전체가 정체된다(setsid/nohup/& 로 띄운 프로세스는 하네스가 추적하지 않는다). 유휴로 가지 말고 짧은 foreground 호출을 반복해 종료를 확인하라 — 예: mcp__oio__bash_exec(command="timeout 85 bash -c '\''while pgrep -f \"%s\" >/dev/null; do sleep 10; done'\''; echo rc=$?", timeout_ms=100000) 를 rc=0 이 나올 때까지 반복(한 번 호출은 90초 이내 — 120초를 넘기면 Claude Code 가 백그라운드로 넘기고 그 세션의 oio 가 고장 난다). 호출 사이에 리드 메시지가 오면 먼저 처리하라. Monitor 를 쓰려면 명령에 test·pgrep·sleep·echo 만 써라(cat·tail·grep·ls·awk 등은 permissions.deny 로 거부된다). 끝나면 결과를 확인해 SendMessage(to="team-lead") 로 보고하라. 의도한 상주 프로세스라면 실행 명령에 #bg:daemon 주석을 붙여라. (차단 %s)\n' "$BAT" "$BFP" "$BFPQ" "$BN" >&2
      else
        printf '⛔ [결과 미회수 방지] %s 에 분리 실행한 작업(%s)이 끝났는데 그 뒤 team-lead 보고가 없다. 결과 파일(rc·로그 꼬리)을 확인해 SendMessage(to="team-lead") 로 보고한 뒤 대기하라. (차단 %s)\n' "$BAT" "$BFP" "$BN" >&2
      fi
      exit 2
    fi
  elif [[ "$BK" == "capped" ]]; then
    # 상한 도달 → 통과. 리드 가드(teammate_idle_guard.py J 규칙)가 <NAME>.bg.json 을 읽어 "결과 미회수(정체)" 로 알린다
    _log BG_CAPPED "kind=$BW fp=$BFP launched=$BAT"
  fi
fi

# 이전 상태 — 같은 turn_start 일 때만 blocks 누적, silent_since 유지
PREV_TS=0; PREV_BLOCKS=0; PREV_SS=0; PREV_STATUS=""
if [[ -f "$STF" ]]; then
  PREV=$(jq -r '[(.turn_start//0),(.blocks//0),(.silent_since//0),(.status//"")]|@tsv' "$STF" 2>/dev/null) || PREV=""
  [[ -n "$PREV" ]] && IFS=$'\t' read -r PREV_TS PREV_BLOCKS PREV_SS PREV_STATUS <<<"$PREV"
fi
[[ "$PREV_BLOCKS" =~ ^[0-9]+$ ]] || PREV_BLOCKS=0
[[ "$PREV_SS" =~ ^[0-9]+$ ]] || PREV_SS=0
if [[ "$PREV_TS" != "$TSTART" ]]; then PREV_BLOCKS=0; PREV_SS=0; PREV_STATUS=""; fi

_write_state() {  # $1=status $2=blocks $3=silent_since
  local tmp="$STF.tmp.$$"
  printf '{"team":"%s","turn_start":%s,"blocks":%s,"status":"%s","silent_since":%s,"updated":%s}\n' \
    "$TEAM" "$TSTART" "$2" "$1" "$3" "$NOW" > "$tmp" 2>/dev/null && mv -f "$tmp" "$STF" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
  return 0
}

case "$KIND" in
  final|interim)
    st="reported"; [[ "$KIND" == "final" ]] && st="final"
    _write_state "$st" 0 0
    _log ALLOW "kind=$KIND turn=$TSTART report_at=$RAT"
    exit 0
    ;;
  none)
    if [[ "$MODE" == "block" ]] && (( PREV_BLOCKS < MAXB )); then
      B=$((PREV_BLOCKS + 1))
      _write_state "blocked" "$B" 0
      _log BLOCK "kind=none turn=$TSTART blocks=$B/$MAXB"
      printf '⛔ [보고 후 대기] 이번 턴에 team-lead 로 SendMessage 보고가 없다. 진행 상황·결과·막힌 점을 SendMessage(to="team-lead", summary 필수)로 보고한 뒤 대기하라. 보고할 것이 없으면 "대기 — 사유" 한 줄이라도 보고하라. (차단 %s/%s)\n' "$B" "$MAXB" >&2
      exit 2
    fi
    SS="$PREV_SS"
    [[ "$PREV_STATUS" == "silent" && "$SS" -gt 0 ]] || SS="$NOW"
    _write_state "silent" "$PREV_BLOCKS" "$SS"
    _log SILENT "kind=none turn=$TSTART blocks=$PREV_BLOCKS/$MAXB mode=$MODE"
    exit 0
    ;;
  *)
    _log UNKNOWN "kind=${KIND:-?}"
    exit 0
    ;;
esac
