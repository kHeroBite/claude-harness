#!/bin/bash
# Agent 팀원 spawn 직후 tmux pane 테두리 제목을 "이름 description"으로 바꾸는 hook
# [2026-10-06 재개 세션 정정] 재개(resume) 세션은 hook 입력 session_id(대화 UUID)와 팀 config 의
#   leadSessionId(런타임 ID)가 달라 기존 소유 판정에서 탈락해 라벨이 안 붙었다. 소유 판정을
#   (leadSessionId == UUID) OR (pane 프로세스 cmdline 에 "--agent-id NAME@TEAM" AND "--parent-session-id UUID")
#   로 확장했다. 두 인자는 반드시 AND 이며(타 세션 팀원은 parent-session-id 불일치로 무동작), 공백 경계로
#   정확 매칭한다. 모든 실패 경로는 exit 0·무출력(fail-closed).
# [2026-10-06 상태 점 추가] pane-border-format 앞에 ● 조건부 색(pane_dead 빨강 > @agent_state=done 회색 >
#   idle 노랑 > 그 외 run/미설정 초록)을 붙이고 spawn 직후 @agent_state=run 으로 초기화한다. 상태 기록은 pane_state_dot.sh 담당.
# [2026-10-06 정정] ● (U+25CF)는 East Asian Ambiguous 폭이라 터미널에 따라 2칸 렌더되어 테두리 폭이 어긋났다.
#   폭 W 인 이모지(🔴 pane_dead / ⚪ done / 🟡 idle / 🟢 run)로 교체하고 상태별 fg 색은 제거했다(라벨 색은 팀원 색 유지).
#   또한 description 이 이미 "이름" 또는 "이름 ..."(공백 경계)이면 이름을 중복 부착하지 않는다(odev-1 vs odev-10 부분일치는 부착).
# [2026-10-07 ⬤ 통일] 상태 점을 ⬤(U+2B24, 폭 1)+#[fg=색] 으로 통일했다(pane_dead 노랑 > done colour240 > idle 초록 >
#   run/미설정은 짝수 초 colour196·홀수 초 colour208 교대 깜빡임). tmux 깜빡임 속성(SGR 5)은 Windows Terminal 미렌더 실측으로 쓰지 않는다.
#   매초 갱신을 위해 해당 pane 의 세션에만 status-interval 1 을 건다(전역 금지). 라벨은 공통 흰색 bold, 팀원 색 변수는 제거했다.
# [2026-10-07 반원 정정] Windows Terminal 이 ⬤ 를 1칸보다 넓게 그려 넘친 절반이 흰색 공백에 칠해졌다. ⬤ 뒤 공백을 점과 같은 색 구간에 넣고 흰색은 라벨 글자부터 시작한다.
# [2026-10-07 스피너·상태색] 라벨=description 만(이름 접두 최대 2회 제거, 빈 값이면 실제 이름). run 기호=◐◓◑◒ 1초 스피너,
#   기호·제목·테두리 색=상태 색(흰색 폐지). 스타일 옵션에서 %S 가 확장되지 않아(실측) run 테두리는 colour196 고정, 기호·제목만 196↔208 교대.
# [2026-10-07 스피너 프레임 교체] ◐◓◑◒ 는 동아시아 폭 A(◐◑)/N(◓◒) 혼재로 Windows Terminal 에서 프레임마다 크기가 달라 폭 N 4자 ◜◝◞◟ 로 교체(%S,4 0~3 순).
# [2026-10-08 단일 출처화] FMT/STY 리터럴을 lib/pane_border_fmt.sh(PANE_BORDER_FMT/STY/VER)로 옮겨 source 한다(부재 시 exit 0).
#   pane_dead 분기 정밀화: 신호 종료·status 0 종료 = colour240 ⬤, 그 외(오류 종료) = yellow ⬤. 옛 형식 pane 은 pane_state_dot.sh 가 재적용.
# [2026-10-08 팀원별 위상·4색] spawn 시 pane 옵션 @spin_t0=epoch 기록. run 기호·제목 = (%s−@spin_t0) mod 4 위상의 colour203/208/205/173, 선 colour203.
# [2026-10-10 부분 원복] run 스피너 연한 빨강·초록·노랑·파랑 colour217/157/229/153 [2026-10-10 4색] 의 배경 + 검정(colour16) 글자(#[bg=colourN]#[fg=colour16]), idle(green)·silent(magenta) 은 글자색 빈 원 ◯, 나머지(done·keep·종료)는 글자색 가득 찬 원 ⬤ [2026-10-10].
set -u
command -v jq >/dev/null 2>&1 && command -v tmux >/dev/null 2>&1 || exit 0
INPUT=$(timeout 5 cat 2>/dev/null) || exit 0
_D="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
. "$_D/lib/session_id.sh" 2>/dev/null || exit 0
. "$_D/lib/pane_border_fmt.sh" 2>/dev/null || exit 0
resolve_uuid "$INPUT" >/dev/null 2>&1 || exit 0
[ -n "${UUID:-}" ] || exit 0

AID=$(echo "$INPUT" | jq -r '[.tool_response.agent_id?, .tool_response.agentId?]|map(select(type=="string" and .!=""))|.[0]//empty' 2>/dev/null)
case "$AID" in *@*) ;; *) exit 0;; esac
NAME="${AID%@*}"; TEAM="${AID##*@}"
[ -n "$NAME" ] && [ -n "$TEAM" ] || exit 0
# 팀명 경로 이탈 방지
case "$TEAM" in */*|*..*) exit 0;; esac
DESC=$(echo "$INPUT" | jq -r '.tool_input.description // empty' 2>/dev/null | tr '\n\r' '  ')
DESC="${DESC#"${DESC%%[![:space:]]*}"}"; DESC="${DESC%"${DESC##*[![:space:]]}"}"
REQ=$(echo "$INPUT" | jq -r '.tool_input.name // empty' 2>/dev/null)

# description 앞의 실제 이름(NAME)·요청 이름(REQ) 접두(공백/끝 경계)를 최대 2회 제거해 LABEL 을 만든다(빈 값이면 NAME 폴백)
_mk_label() {
  local d="$DESC" i n hit
  for i in 1 2; do
    hit=0
    for n in "$NAME" "${REQ:-}"; do
      [ -n "$n" ] || continue
      if [ "$d" = "$n" ]; then d=""; hit=1; break; fi
      if [ "${d#"$n "}" != "$d" ]; then d="${d#"$n "}"; d="${d#"${d%%[![:space:]]*}"}"; hit=1; break; fi
    done
    [ "$hit" = 1 ] && [ -n "$d" ] || break
  done
  [ -n "$d" ] || d="$NAME"
  # [2026-10-11] 폭 모호 기호(→ ★ 등) 뒤 공백 1칸 보정 — 터미널에서 다음 글자와 겹쳐 그려지는 문제(lib/ambiguous_width.py). 실패 시 원문 유지.
  local d2
  d2=$(printf '%s' "$d" | python3 "$_D/lib/ambiguous_width.py" 2>/dev/null) && [ -n "$d2" ] && d="$d2"
  LABEL=$(printf '%s' "$d" | sed 's/#/##/g')
  LABEL="${LABEL:0:60}"
}

# pane 프로세스(pane_pid + 자식 2단계)의 cmdline 이 이 팀원·이 세션 소유인지 판정한다
_owned_by_cmdline() {
  local pane="$1" name="$2" team="$3" uuid="$4" ppid pids p c cmd
  ppid=$(tmux display -p -t "$pane" -F '#{pane_pid}' 2>/dev/null) || return 1
  case "$ppid" in ""|*[!0-9]*) return 1;; esac
  pids="$ppid"
  for p in $(pgrep -P "$ppid" 2>/dev/null); do
    pids="$pids $p"
    for c in $(pgrep -P "$p" 2>/dev/null); do pids="$pids $c"; done
  done
  for p in $pids; do
    cmd=$(tr '\0' ' ' 2>/dev/null < "/proc/$p/cmdline") || continue
    cmd=" $cmd "
    case "$cmd" in *" --agent-id ${name}@${team} "*) ;; *) continue;; esac
    case "$cmd" in *" --parent-session-id ${uuid} "*) return 0;; esac
  done
  return 1
}

CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams/${TEAM}/config.json"
PANE=""; LEAD_OK=0
for _ in 1 2 3 4 5 6; do
  if [ -f "$CFG" ]; then
    # 세션 격리: leadSessionId 일치면 즉시 소유, 불일치면 루프 뒤 cmdline 판정으로 넘긴다
    [ "$(jq -r '.leadSessionId // empty' "$CFG" 2>/dev/null)" = "$UUID" ] && LEAD_OK=1
    M=$(jq -r --arg n "$NAME" '.members[]|select(.name==$n)|.tmuxPaneId // ""' "$CFG" 2>/dev/null | head -1)
    PANE="$M"
    case "$PANE" in %[0-9]*) break;; esac
    PANE=""
  fi
  sleep 0.5
done
[ -n "$PANE" ] || exit 0
if [ "$LEAD_OK" != 1 ]; then
  _owned_by_cmdline "$PANE" "$NAME" "$TEAM" "$UUID" || exit 0
fi

_mk_label
tmux set -p -t "$PANE" @agent_label "$LABEL" >/dev/null 2>&1
tmux set -p -t "$PANE" @agent_state run >/dev/null 2>&1
# 스피너 위상 기준 시각(epoch) — spawn 마다 덮어써 팀원별 시작 위상이 달라진다. pane 한정 -p
printf -v _T0 '%(%s)T' -1; tmux set -p -t "$PANE" @spin_t0 "$_T0" >/dev/null 2>&1
tmux set -p -t "$PANE" pane-border-format "$PANE_BORDER_FMT" >/dev/null 2>&1
# 테두리 선 색 = 상태 색(스타일 옵션은 %S 미확장이라 run 은 colour203 고정). pane 한정 -p (전역 -g 금지)
tmux set -p -t "$PANE" pane-border-style "$PANE_BORDER_STY" >/dev/null 2>&1
tmux set -p -t "$PANE" pane-active-border-style "$PANE_BORDER_STY" >/dev/null 2>&1
# run 점의 초 단위 깜빡임을 위해 이 pane 이 속한 세션에만 status-interval 1 (전역 -g 금지, 판별 실패 시 생략)
SID=$(tmux display -p -t "$PANE" '#{session_id}' 2>/dev/null)
case "$SID" in \$[0-9]*) tmux set -t "$SID" status-interval 1 >/dev/null 2>&1;; esac
exit 0
