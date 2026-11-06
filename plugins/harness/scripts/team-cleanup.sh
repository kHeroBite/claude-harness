#!/bin/bash
# team-cleanup.sh — 비정상 팀/pane/파이프라인 강제 정리
# 사용: bash ${HARNESS_HOME:-$HOME/.harness}/current/scripts/team-cleanup.sh [--dry-run|--force]
# ostatus Step 2, ofinish_cleanup Step 2 에서 호출
#
# ── ★이 스크립트가 못 잡는 것★ (사이클41 — otest T5 지적으로 추가) ────────────
# 타 산출물 9종에는 이 항목이 있는데 본 스크립트만 없었다. 아래는 ★코드를 읽고
# 확인한 실제 사각지대★ 다. "정리했다"는 출력이 "전부 정리됐다"를 뜻하지 않는다.
#
#  A. ★수동 실행 스크립트다 — 호출되지 않으면 아무것도 정리되지 않는다.★
#     ostatus / ofinish_cleanup 이 부르지 않고 끝나면(조기 종료·예외·사용자 중단)
#     이 스크립트는 ★한 번도 돌지 않는다★. 물리 강제가 아니라 ★호출 의존★ 이다.
#     ⇒ 사이클38 의 "검증 루프 통째 스킵" 이 정확히 이 형태였다.
#
#  B. ★tmux 를 우회한 에이전트는 열거되지 않는다.★
#     탐지는 `tmux list-panes` 기반이다. backendType=in-process 팀에이전트(팀리드
#     포함)나 tmux 밖에서 뜬 프로세스는 ★pane 이 없어 순회 대상에서 빠진다★.
#     실측: teams/*/config.json 에 backendType 이 "in-process" 인 멤버가 실존한다.
#
#  C. ★타 세션은 의도적으로 미열거다 (§(c)) — 즉 타 세션 고아는 안 치운다.★
#     SKIPPED_FOREIGN 으로 ★건수만★ 세고 UUID 도 출력하지 않는다. 이것은 세션
#     격리를 지키기 위한 ★설계된 포기★ 이지 결함이 아니다. 그러나 결과적으로
#     ★하드 크래시한 타 세션의 잔재는 이 스크립트로 영원히 정리되지 않는다★.
#     ⇒ 그쪽은 lazy orphan cleanup(다음 TeamCreate 시점)이 담당한다.
#
#  D. ★"살아 있음" 판정은 화면 텍스트 휴리스틱이다 — 오판이 양방향으로 난다.★
#     `tmux capture-pane -S -30` 의 최근 30줄과 idle 300초 임계로 판단한다.
#       · 300초 넘게 조용한 ★정상 장기 실행★(대형 빌드·DB 대기) → ★kill 될 수 있다★
#       · 출력만 흘리는 ★죽은 루프★ → "활성" 으로 보여 ★살아남는다★
#     ⇒ 프롬프트 정규식(`^❯|^> `)에 걸리지 않는 UI 는 전부 오판 후보다.
#
#  E. ★조상 트리 보호는 자기 자신만 지킨다.★
#     PROTECTED_PANES / MY_ANCESTORS 는 ★이 스크립트의 조상★ 만 보호한다.
#     같은 tmux 서버의 ★다른 메인 Claude★ 는 이 목록에 없다. --agent-id 부재
#     검사(B안전판)가 유일한 방어이며, 그 검사는 ★pgrep -P 로 자식을 훑는다★
#     ⇒ ★프로세스 트리가 깊거나 자식이 아직 안 뜬 순간★ 에는 놓칠 수 있다.
#
#  F. ★kill 이후를 검증하지 않는다.★
#     `kill` → `kill -9` → `tmux kill-pane` 을 순서대로 시도하지만 ★최종 소멸을
#     재확인하지 않는다★. 3단계가 모두 실패해도 CLEANED_PANES 는 증가한다
#     ⇒ ★요약의 숫자는 "시도 횟수"에 가깝지 "성공 횟수"가 아니다★.
#
#  G. ★사용자가 직접 tmux kill / taskkill 로 우회하는 것은 막지 못한다.★
#     본 스크립트는 정리 ★수단★ 이지 ★관문★ 이 아니다. 우회 경로가 자유롭다.
#
#  H. ★CLAUDE_CONFIG_DIR 미설정이면 $HOME/.claude 로 폴백한다.★
#     그 환경에서는 c41-odev4 가 고친 "레거시 552개 오탐" 조건으로 되돌아간다.
#     ⇒ 폴백 자체는 의도된 호환 동작이나, ★그 환경에서의 오보고 위험은 남아 있다★.
#
#  I. ★dry-run 요약은 예정/실행을 분리 표기한다(사이클168).★
#     dry-run 에서는 kill 카운터(CLEANED_*)가 항상 0 이라 "정리 대상 없음"과 구분되지 않았다.
#     ⇒ PLANNED_* 로 따로 세어 `[DRY-RUN] kill 예정 — …` 한 줄로 낸다. 실제 kill 카운터와 합치지 않는다.

set -o pipefail
HOME_DIR="$HOME"
# [c41-odev4] CLAUDE_CONFIG_DIR 우선. 종전 $HOME/.claude 하드코딩은 /tmp/cc-*/ 를 쓰는
# 세션에서 552개 레거시 session-env 를 스캔해 ① 자기 세션 미탐지(CURRENT_UUID 공백)
# ② 죽은 잔재를 "고착 10건"으로 오보고 ③ 자기 세션을 "타세션"으로 오판 을 동시에 유발했다.
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME_DIR/.claude}"
SESSION_ENV="$CONFIG_DIR/session-env"
TEAMS_DIR="$CONFIG_DIR/teams"
TASKS_DIR="$CONFIG_DIR/tasks"

# [사이클47] session-env 삭제 미러 — CLAUDE_CONFIG_DIR/HOME 갈림(F-PATH-1) 재생산 방지.
# ★_mirror_delete 만 쓴다 — fail-soft, 항상 rc=0★
source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/session_mirror.sh" 2>/dev/null
type _mirror_file >/dev/null 2>&1 || _mirror_file() { :; }
type _mirror_delete >/dev/null 2>&1 || _mirror_delete() { :; }

# [A3 — 사이클49] state_machine.sh 명시 source (실측: state_read/state_write는
# session_id.sh가 정의하며 team-cleanup.sh는 이를 이미 source하므로 함수 자체는
# DEFINED 상태였다. 그러나 state_machine.sh가 이 사실에 의존한다는 것을 코드에서
# 드러내지 않아 향후 리팩터링 시 깨지기 쉬웠다 — 명시적으로 source하여 의존성을 고정한다.
source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/state_machine.sh" 2>/dev/null
type state_read >/dev/null 2>&1 || state_read() { echo "IDLE"; }
type state_write >/dev/null 2>&1 || state_write() { :; }

MODE="${1:-interactive}"  # --dry-run, --force, interactive(기본)

R='\033[0;31m' G='\033[0;32m' Y='\033[0;33m' C='\033[0;36m' NC='\033[0m'

CLEANED_PIPELINES=0
CLEANED_PANES=0
# [사이클168] dry-run 예정 카운터 — 실제 kill 카운터(CLEANED_*)와 분리한다.
PLANNED_PANES=0
PLANNED_AGENT_PROCS=0
PLANNED_BASH_FALLBACK=0
SKIPPED_FOREIGN=0   # [c41-odev4] §(c) — 타 세션은 건수만 집계, UUID 는 출력하지 않는다

# 메인 pane 정보 (전역 — _kill_pane에서 보호용으로 참조)
# 주의: 스크립트가 bash fallback pane에서 실행될 수 있음 (oio bash_exec 경유)
# → tmux display-message가 fallback pane을 반환할 수 있으므로, 보호 대상 pane 목록으로 확장
MY_PANE=$(tmux display-message -p '#{pane_id}' 2>/dev/null || echo "")
MY_SESSION=$(tmux display-message -p '#{session_name}' 2>/dev/null || echo "")

# 보호 pane 목록: MY_PANE + 조상 프로세스가 실행 중인 모든 pane
PROTECTED_PANES="$MY_PANE"
_script_pid=$$
_walk_pid=$_script_pid
while [ "$_walk_pid" -gt 1 ] 2>/dev/null; do
  _anc_pane=$(tmux list-panes -a -F '#{pane_pid} #{pane_id}' 2>/dev/null | awk -v pid="$_walk_pid" '$1==pid {print $2}')
  if [ -n "$_anc_pane" ] && ! echo "$PROTECTED_PANES" | grep -qF "$_anc_pane"; then
    PROTECTED_PANES="$PROTECTED_PANES $_anc_pane"
  fi
  _walk_pid=$(ps -o ppid= -p "$_walk_pid" 2>/dev/null | tr -d ' ')
  [ -z "$_walk_pid" ] && break
done
MY_PID=$(tmux display-message -t "$MY_PANE" -p '#{pane_pid}' 2>/dev/null || echo "")

# 프로세스 조상 트리 수집 (메인 프로세스 트리 보호 — 1차 방어)
_get_ancestors() {
  local pid=$1
  local ancestors=""
  while [ "$pid" -gt 1 ] 2>/dev/null; do
    ancestors="$ancestors $pid"
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -z "$pid" ] && break
  done
  echo "$ancestors"
}
MY_ANCESTORS=$(_get_ancestors $$)

# 현재 세션 UUID 감지 (자기 파이프라인 보호 — ofinish 중 고착 오판 방지)
CURRENT_UUID=""

# ★[2026-09-19 사이클143] Fallback 0: 명시적 환경변수를 ★가장 먼저★ 본다.★
#
# ★왜 0순위인가★ — 아래 세 경로는 전부 ★추론★ 이다(세션 컨텍스트 해석 · pane cmdline 파싱 ·
#   heartbeat mtime 추측). 추론은 틀릴 수 있고, 틀리면 ★타 세션을 내 세션으로 오인★ 한다.
#   반면 PIPELINE_UUID 는 호출자가 ★명시한 값★ 이라 오인 자체가 성립하지 않는다.
#
# ★무엇을 고치는가★ (2026-09-19 실측으로 확정한 3중 실패):
#   · session_id.sh resolve_uuid → bash_exec 서브셸에 세션 컨텍스트가 없어 ★EMPTY★
#   · Fallback 1 → `claude agents`(FleetView 뷰어) pane 을 먼저 집는데 그 cmdline 엔 UUID 가 없다
#   · Fallback 2 → IDLE 구간엔 heartbeat 가 안 갱신돼 ★age 2분★ 으로 `-mmin -1` 경계를 넘긴다
#   ⇒ 셋 다 실패하면 자기 세션까지 "타세션"으로 보호돼 ★정리가 통째로 무력화★ 되는데
#     화면에는 `kill 0개` 라고만 나온다. "정리할 게 없다" 와 ★구분이 안 된다.★
#
# ★실사고★ — 사이클143 ofinish 에서 이 경로로 `%11`(odev-1-2) 잔류를 놓쳤다.
#   `kill 0개` 를 "정리 완료"로 읽었고, 다음 /oinit 에서 프로세스를 직접 세고서야 드러났다.
#
# ⚠️ heartbeat 임계(-mmin -1)는 ★일부러 넓히지 않았다★ — 넓히면 활성 세션이 여럿일 때
#   `head -1` 이 엉뚱한 세션을 골라 ★타 세션을 죽일 수 있다.★ 지금 문제보다 그쪽이 더 위험하다.
if [ -n "${PIPELINE_UUID:-}" ]; then
  CURRENT_UUID="$PIPELINE_UUID"
fi

if [ -z "$CURRENT_UUID" ] && [ -f "$HOME_DIR/.claude/hooks/lib/session_id.sh" ]; then
  source "$HOME_DIR/.claude/hooks/lib/session_id.sh" 2>/dev/null
  resolve_uuid "" 2>/dev/null
  CURRENT_UUID="${UUID:-}"
fi

# Fallback 1: tmux 메인 pane의 node/claude 프로세스에서 세션 ID 추출
if [ -z "$CURRENT_UUID" ]; then
  MAIN_PANE_PID=$(tmux list-panes -s -F '#{pane_pid} #{pane_current_command}' 2>/dev/null | \
    awk '$2=="node" || $2=="claude" {print $1; exit}')
  if [ -n "$MAIN_PANE_PID" ]; then
    SESSION_FROM_PID=$(tr '\0' '\n' < /proc/$MAIN_PANE_PID/cmdline 2>/dev/null | \
      grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
    if [ -n "$SESSION_FROM_PID" ]; then
      CURRENT_UUID="$SESSION_FROM_PID"
    fi
  fi
fi

# Fallback 2: 최근 1분 이내 갱신된 heartbeat를 가진 session-env 디렉토리 (현재 활성 세션)
if [ -z "$CURRENT_UUID" ]; then
  CURRENT_UUID=$(find "$SESSION_ENV/" -maxdepth 2 -name "heartbeat" -mmin -1 \
    2>/dev/null | xargs -I {} dirname {} 2>/dev/null | xargs -I {} basename {} 2>/dev/null | head -1)
fi

# ★[2026-09-17 사이클141] CURRENT_UUID 빈값을 "타세션"과 구분해 알린다★
#
# ★무슨 일이 벌어지나★ — 위 폴백이 전부 실패하면 CURRENT_UUID 가 빈값으로 남는다.
#   그러면 아래쪽 `[ -z "$CURRENT_UUID" ]` 판정들이 참이 되어 ★자기 세션 프로세스까지 전부
#   "타세션"으로 분류돼 보호★ 된다. 즉 정리가 통째로 무력화되는데 ★화면에는 아무 이상도 안 보인다.★
#   "타세션이라 건드리지 않았다" 와 "내가 누군지 몰라서 아무것도 못 했다" 가 ★같은 출력★ 을 낸다.
#
# ⚠️ ★조건문 자체는 고치지 않는다★ — 빈값일 때 kill 을 허용하는 방향은 ★타 세션을 죽일 수 있다.★
#   그 fail-closed 는 L-328 의 ★의도된 안전 동작★ 이다. 여기서는 ★알리기만★ 한다.
#   ⇒ 사용자가 "왜 아무것도 안 지워졌지" 를 즉시 원인과 연결할 수 있게 하는 것이 목적이다.
CURRENT_UUID_EMPTY_WARNED=false
if [ -z "$CURRENT_UUID" ]; then
  CURRENT_UUID_EMPTY_WARNED=true
  echo -e "  ${Y}경고${NC}: 현재 세션 UUID 를 확정하지 못했다 (4단계 폴백 전부 실패)"
  echo -e "         ⇒ 이후 모든 프로세스가 '타세션'으로 분류되어 ${Y}보호${NC}된다 — 실제로는 정리가 수행되지 않는다."
  echo -e "         ⇒ 이것은 '정리할 것이 없음'이 아니라 ${Y}'판정 불가'${NC}다. 둘을 혼동하지 말 것."
  echo -e "         확인: session_id.sh 존재 여부 · tmux 메인 pane 생존 · session-env/*/heartbeat 갱신 여부"
fi

_confirm() {
  [ "$MODE" = "--force" ] && return 0
  [ "$MODE" = "--dry-run" ] && return 1
  read -p "  실행할까요? (y/N) " answer
  [ "$answer" = "y" ] || [ "$answer" = "Y" ]
}

_kill_pane() {
  local pane_id="$1"
  local reason="${2:-team-cleanup}"
  local pane_pid pane_cmd pane_session
  pane_pid=$(tmux display-message -t "$pane_id" -p '#{pane_pid}' 2>/dev/null || echo "")
  pane_cmd=$(tmux display-message -t "$pane_id" -p '#{pane_current_command}' 2>/dev/null || echo "")
  pane_session=$(tmux display-message -t "$pane_id" -p '#{session_name}' 2>/dev/null || echo "")
  if [ -z "$pane_pid" ]; then
    return 0  # 이미 소멸
  fi
  # 디버그 로그 (중앙 로그 파일)
  printf '[%s] KILL pane=%s pid=%s cmd=%s session=%s reason=%s script=team-cleanup.sh mode=%s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$pane_id" "$pane_pid" "$pane_cmd" "$pane_session" \
    "$reason" "$MODE" \
    >> /tmp/pane_kill_debug.log 2>/dev/null
  # 1차 방어: 프로세스 조상 트리 보호 — 대상 PID가 내 조상이면 절대 kill 금지
  if echo "$MY_ANCESTORS" | grep -qw "$pane_pid"; then
    echo -e "    ${Y}⚠️ 메인 프로세스 조상 (PID=$pane_pid) — kill 스킵${NC}"
    printf '[%s] KILL_SKIP pane=%s — 메인 프로세스 조상\n' \
      "$(date '+%Y-%m-%d %H:%M:%S')" "$pane_id" >> /tmp/pane_kill_debug.log 2>/dev/null
    return 0
  fi
  # 2차 방어: 메인 pane PID 직접 비교
  local main_pid="$MY_PID"
  if [ -n "$main_pid" ] && [ "$pane_pid" = "$main_pid" ]; then
    echo -e "    ${Y}⚠️ 메인 PID와 동일 — kill 스킵${NC}"
    printf '[%s] KILL_SKIP pane=%s — 메인 PID 동일\n' \
      "$(date '+%Y-%m-%d %H:%M:%S')" "$pane_id" >> /tmp/pane_kill_debug.log 2>/dev/null
    return 0
  fi
  # 자식 프로세스 먼저 종료 (메인 PID의 자식은 제외)
  for child in $(pgrep -P "$pane_pid" 2>/dev/null); do
    if [ -n "$main_pid" ] && [ "$child" = "$main_pid" ]; then
      continue  # 메인 PID 보호
    fi
    # 메인 PID가 이 자식의 자식인지 확인 (메인 프로세스 트리 보호)
    if [ -n "$main_pid" ] && pgrep -P "$child" 2>/dev/null | grep -qF "$main_pid"; then
      continue  # 메인이 이 프로세스의 하위에 있음 — 보호
    fi
    kill "$child" 2>/dev/null
  done
  sleep 0.5
  # 메인 프로세스
  kill "$pane_pid" 2>/dev/null
  sleep 1
  # 미소멸 시 강제
  if tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qF "$pane_id"; then
    kill -9 "$pane_pid" 2>/dev/null
    sleep 1
  fi
  # 최후 수단
  if tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qF "$pane_id"; then
    tmux kill-pane -t "$pane_id" 2>/dev/null
    sleep 0.5
  fi
  # 최종 결과 로그
  if tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qF "$pane_id"; then
    printf '[%s] KILL_FAILED pane=%s — 여전히 존재\n' \
      "$(date '+%Y-%m-%d %H:%M:%S')" "$pane_id" >> /tmp/pane_kill_debug.log 2>/dev/null
  else
    printf '[%s] KILL_OK pane=%s — 소멸 확인\n' \
      "$(date '+%Y-%m-%d %H:%M:%S')" "$pane_id" >> /tmp/pane_kill_debug.log 2>/dev/null
  fi
}

echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${C}🧹 team-cleanup: 비정상 정리 (모드: $MODE)${NC}"
echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# ── 1. 현재 세션 고아 pane 정리 ──
echo -e "\n${Y}[1] 현재 세션 고아 pane 정리${NC}"
# MY_PANE, MY_SESSION은 스크립트 초반에서 이미 설정됨

# MY_SESSION이 비어있으면 PROTECTED_PANES의 첫 pane에서 세션명 추출
if [ -z "$MY_SESSION" ] && [ -n "$PROTECTED_PANES" ]; then
  _first_pane=$(echo "$PROTECTED_PANES" | awk '{print $1}')
  MY_SESSION=$(tmux display-message -t "$_first_pane" -p '#{session_name}' 2>/dev/null || echo "")
fi

if [ -n "$MY_PANE" ] || [ -n "$PROTECTED_PANES" ]; then
  # -a: 세션 전체 window의 pane 스캔 (window별 스캔 시 누락 방지)
  # process substitution 사용 (파이프 subshell 변수 격리 방지 — CLEANED_PANES 카운터 정확도)
  while read SPANE SCMD SPID; do
    # 보호 pane 목록 전체와 비교 (MY_PANE + 조상 프로세스 pane)
    echo "$PROTECTED_PANES" | grep -qF "$SPANE" && continue

    # 판정 로직 (L-350/L-352):
    # bash 상태 → agents/ 등록 여부 확인 → 미등록이면 고아 kill
    #            → agents/ 등록됨이면 spawn 중 bash 상태 → 보호
    # claude/2.1.x + --agent-id 없음 → 메인 Claude → 절대 kill 금지
    # claude/2.1.x + --agent-id 있음 → 팀에이전트 잔류 → kill

    if echo "$SCMD" | grep -qE '^(claude|2\.[0-9])'; then
      # claude/2.1.x 상태: --agent-id로 메인/팀에이전트 구별 (L-350)
      _cpid=$(tmux display-message -t "$SPANE" -p '#{pane_pid}' 2>/dev/null || echo "")
      # [c41-odev4] 오판정 1 수정: 종전에는 `pgrep -P | head -1` 로 ★첫 자식만★ 검사했다.
      # 실측 — pane_pid 본체 args 에 --agent-id 가 있는데 첫 자식이 oio-mcp 라서 공백이 반환됐고,
      # "메인 Claude → 절대 kill 금지" 로 오판했다(자식들 = oio-mcp/mysql-mcp/context7/n8n/codex).
      # ⇒ ① pane_pid 본체를 먼저 본다 ② 없을 때만 ★전체 자식★ 을 순회한다(head -1 금지).
      # ★열 폭 무관★ ps -ww — COLUMNS=80(tmux 상속)이면 args 가 잘려 --agent-id 토큰이 끊긴다(2026-10-10 실측).
      _agent_id=$(ps -ww -p "$_cpid" -o args= 2>/dev/null | grep -o '\-\-agent-id [^ ]*' | cut -d' ' -f2)
      if [ -z "$_agent_id" ] && [ -n "$_cpid" ]; then
        for _ch in $(pgrep -P "$_cpid" 2>/dev/null); do
          _agent_id=$(ps -ww -p "$_ch" -o args= 2>/dev/null | grep -o '\-\-agent-id [^ ]*' | cut -d' ' -f2)
          [ -n "$_agent_id" ] && break
        done
      fi
      if [ -z "$_agent_id" ]; then
        echo -e "  ${Y}보호${NC}: $SPANE CMD=$SCMD — --agent-id 없음 → 메인 Claude → 절대 kill 금지"
        continue
      fi

      # 팀에이전트 확인 — 정상 실행 중 여부 판정 (L-353)
      # 1. shutdown_sent 플래그 확인 (종료 메시지 발송 완료 → kill 허용)
      _agent_file=$(grep -rl "pane_id=$SPANE" "$SESSION_ENV"/*/agents/ 2>/dev/null | head -1)
      _shutdown_sent=false
      [ -n "$_agent_file" ] && grep -q "shutdown_sent=true" "$_agent_file" 2>/dev/null && _shutdown_sent=true

      if $_shutdown_sent; then
        echo -e "  ${R}팀에이전트 종료대기${NC}: $SPANE --agent-id=$_agent_id shutdown_sent=true → kill 대상"
      else
        # 2. pane 출력으로 실행 중 여부 판정
        _last=$(tmux capture-pane -t "$SPANE" -p -S -30 2>/dev/null)
        _active=false
        # ★[2026-09-17 사이클141] statusline 토큰 카운터를 활성 신호에서 제외했다★
        #   제거한 패턴: 하향 화살표 + 숫자 + tokens (IDLE 배너의 누적 토큰 표시)
        #   ★왜★ — 이 표시는 ★작업이 끝난 뒤에도 배너에 그대로 남아 있다.★ 활성 출력이 아니라
        #     ★마지막 상태의 잔상★ 이다. 사이클140 실측에서 이 오독으로 ★이미 종료된 pane 3개★ 를
        #     "활성 출력 감지"로 보호해 정리가 멈췄다.
        #   ⚠️ ★점 표시(●)는 그대로 둔다★ — 실제 활성 신호일 수 있어 함께 지우면 살아 있는
        #     에이전트를 죽일 수 있다. 오탐(안 지움)보다 미탐(지움)이 훨씬 비싸다.
        echo "$_last" | grep -qE 'Running…|Thinking…|Cogitating…|Quantumizing…|[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]|● ' && _active=true

        # 2-A. 완료 키워드 화이트리스트 (L-392 — 2026-04-12)
        # IDLE statusline의 timer/토큰 카운터가 1초마다 갱신 → 활성 출력 false positive
        # 마지막 출력(최근 30줄)에 명시적 완료 키워드가 있으면 작업 종료로 간주, 활성 보호 우회
        # 빈 prompt(❯)로 끝나면 IDLE 확정
        _completed=false
        echo "$_last" | grep -qE '완료 보고( 전송)? 완료|team-lead.{0,30}(완료|결과 보고|보고 완료|재보고)|파일 작성 완료|결과 보고합니다|재작성 없이.{0,30}(보고|완료)|odone .{0,5} 완료|작업.{0,5} 완료 보고|shutdown_response|임무 완료|전체 완료|보고합니다\.|보고 완료|투표 완료|검토 완료|작성 완료|판정 완료' && _completed=true
        # 영문 완료 키워드 (L-395 — 2026-04-12)
        if ! $_completed; then
          echo "$_last" | grep -qiE 'report (sent )?completed|task done|all (tasks? )?completed|final report|shutdown approved|cleanup done|done\\.|finished\\.|completed\\.|wrapped up|all set' && _completed=true
        fi
        # 추가 안전 조건: 빈 prompt(❯) + 토큰 사용량 표시(💭 •) 동시 → IDLE 확정 패턴
        if ! $_completed; then
          _idle_prompt=false
          echo "$_last" | grep -qE '^❯ *$' && echo "$_last" | grep -qE 'IDLE.*💭' && _idle_prompt=true
          $_idle_prompt && _completed=true
        fi
        # 추가 안전 조건 2: 🧍IDLE 배너 직접 감지 → IDLE 확정 (CASE-8 확장형 — L-394)
        if ! $_completed; then
          echo "$_last" | grep -qE '🧍.*IDLE|IDLE.*🧍|🧍IDLE' && _completed=true
        fi

        # 3. pane 최근 활동 타임스탬프 (초 단위)
        _last_activity=$(tmux display-message -t "$SPANE" -p '#{pane_activity}' 2>/dev/null || echo "0")
        _now=$(date +%s)
        _idle_sec=$(( _now - _last_activity ))

        if $_completed; then
          # L-392: 완료 키워드 감지 → 활성/idle 무관하게 kill 대상 (false positive 우회)
          echo -e "  ${R}팀에이전트 완료(키워드)${NC}: $SPANE --agent-id=$_agent_id — 완료 키워드 감지 → kill 대상 (L-392)"
        elif $_active; then
          echo -e "  ${Y}보호${NC}: $SPANE --agent-id=$_agent_id — 활성 출력 감지 → 정상 실행 중 → kill 금지"
          continue
        elif [ "$_idle_sec" -lt 300 ] && ! echo "$_last" | grep -qE '^❯|^> '; then
          # 최근 5분 내 활동 + 프롬프트 대기 아님 → 빌드 등 대기 중으로 판단
          echo -e "  ${Y}보호${NC}: $SPANE --agent-id=$_agent_id — 최근 활동 ${_idle_sec}초 전, 프롬프트 미감지 → 실행 중 추정 → kill 금지"
          continue
        else
          echo -e "  ${R}팀에이전트 완료/유휴${NC}: $SPANE --agent-id=$_agent_id — idle ${_idle_sec}초 → kill 대상"
        fi
      fi
    else
      # bash 등 기타 상태 — agents/ 등록 여부 확인 (L-350 추가 방어)
      # agents/에 등록된 pane이면 방금 spawn되어 bash→claude 전환 중일 수 있음 → 보호
      _bash_pane_registered=$(for _bf in "$SESSION_ENV"/*/agents/*; do
        [ -f "$_bf" ] || continue
        _bid=$(grep "^pane_id=" "$_bf" 2>/dev/null | cut -d= -f2)
        [ "$_bid" = "$SPANE" ] && echo "yes" && break
      done)
      if [ "$_bash_pane_registered" = "yes" ]; then
        echo -e "  ${Y}보호${NC}: $SPANE CMD=$SCMD — agents/ 등록됨 → spawn 중 bash 상태 → kill 금지"
        continue
      fi
      # agents/ 미등록 bash pane → 고아 판정
      echo -e "  ${R}고아 pane${NC}: $SPANE CMD=$SCMD PID=$SPID"
    fi

    if [ "$MODE" = "--dry-run" ]; then
      echo -e "    ${Y}[DRY-RUN] kill 예정${NC}"
      PLANNED_PANES=$((PLANNED_PANES + 1))
    else
      if _confirm; then
        tmux set -g status off 2>/dev/null || true
        _kill_pane "$SPANE"
        tmux set -g status on 2>/dev/null || true
        echo -e "    ${G}killed${NC}"
        CLEANED_PANES=$((CLEANED_PANES + 1))
      fi
    fi
  done < <(tmux list-panes -a -F '#{session_name} #{pane_id} #{pane_current_command} #{pane_pid}' 2>/dev/null \
    | awk -v s="$MY_SESSION" '$1==s {print $2, $3, $4}')
else
  echo -e "  ${Y}tmux 세션 아님 — 스킵${NC}"
fi

# ── 1.5 에이전트 프로세스 기반 정리 (pane 스캔 보완) ──
# shutdown_approved 후에도 프로세스가 종료되지 않고 남아있는 경우 감지+kill
# kill 후 부모 pane이 bash로 빠지면 해당 pane도 정리
echo -e "\n${Y}[1.5] 잔류 에이전트 프로세스 정리${NC}"
CLEANED_AGENT_PROCS=0

# [사이클168] 에이전트 프로세스 1개의 kill 실행부 — 팀명 루프와 parent 소스가 공유한다.
# 호출 전에 보호 판정(조상·MY_PID·L-328)이 끝나 있어야 한다. dry-run 이면 예정만 센다.
_kill_agent_proc() {
  local apid="$1" _tn="$2" agent_info parent_pid parent_pane p_pane_id p_pane_cmd
  agent_info=$(ps -ww -o pid=,ppid=,etime=,args= -p "$apid" 2>/dev/null | head -1)
  echo -e "  ${R}잔류 에이전트${NC}: PID=$apid 팀=$_tn"
  echo -e "    $agent_info"

  if [ "$MODE" = "--dry-run" ]; then
    echo -e "    ${Y}[DRY-RUN] kill 예정${NC}"
    PLANNED_AGENT_PROCS=$((PLANNED_AGENT_PROCS + 1))
  else
    # 부모 pane 기록 (kill 후 bash fallback 정리용)
    parent_pid=$(ps -o ppid= -p "$apid" 2>/dev/null | tr -d ' ')

    kill "$apid" 2>/dev/null
    sleep 1
    if ps -p "$apid" > /dev/null 2>&1; then
      kill -9 "$apid" 2>/dev/null
      sleep 1
    fi
    echo -e "    ${G}에이전트 프로세스 killed${NC}"
    CLEANED_AGENT_PROCS=$((CLEANED_AGENT_PROCS + 1))

    # 부모 pane이 bash로 빠졌는지 확인 → 메인 pane이 아니면 정리
    if [ -n "$parent_pid" ] && [ "$parent_pid" != "$MY_PID" ]; then
      # parent_pid가 tmux pane인지 확인
      parent_pane=$(tmux list-panes -a -F '#{pane_pid} #{pane_id} #{pane_current_command}' 2>/dev/null | awk -v pid="$parent_pid" '$1==pid {print $2, $3}')
      if [ -n "$parent_pane" ]; then
        p_pane_id=$(echo "$parent_pane" | awk '{print $1}')
        p_pane_cmd=$(echo "$parent_pane" | awk '{print $2}')
        if [ "$p_pane_id" != "$MY_PANE" ] && [ "$p_pane_cmd" = "bash" ]; then
          # 메인 조상이 아닌지 최종 확인
          if ! echo "$MY_ANCESTORS" | grep -qw "$parent_pid"; then
            echo -e "    ${R}bash fallback pane${NC}: $p_pane_id (PID=$parent_pid)"
            tmux set -g status off 2>/dev/null || true
            _kill_pane "$p_pane_id"
            tmux set -g status on 2>/dev/null || true
            echo -e "    ${G}bash pane killed${NC}"
            CLEANED_PANES=$((CLEANED_PANES + 1))
          fi
        fi
      fi
    fi
  fi
}

# [사이클168] 1차 후보 소스 — 팀명 기록과 무관하게 --parent-session-id 가 자기 UUID 인 에이전트.
# session-env/*/team_name 파일도 teams 디렉토리도 없는 에이전트(F-AGENT-1 RC2 계열)를 놓치지 않는다.
# 안전 조건: ① --agent-id 필수(L-213 — 메인 Claude·비에이전트 kill 금지) ② UUID 정확 비교(부분일치 금지)
#            ③ 조상·MY_PID 보호 유지. 처리한 PID 는 _SEEN_PIDS 로 아래 팀명 루프에서 제외한다.
_SEEN_PIDS=" "
if [ -n "$CURRENT_UUID" ]; then
  for apid in $(pgrep -f -- "--parent-session-id ${CURRENT_UUID}" 2>/dev/null); do
    _proc_args=$(ps -ww -o args= -p "$apid" 2>/dev/null || true)  # 폭 무관(COLUMNS 잘림 방지)
    echo "$_proc_args" | grep -q -- '--agent-id ' || continue
    _proc_session=$(echo "$_proc_args" | grep -oP '(?<=--parent-session-id )\S+' | head -1 || true)
    [ "$_proc_session" = "$CURRENT_UUID" ] || continue
    _SEEN_PIDS="$_SEEN_PIDS$apid "
    if echo "$MY_ANCESTORS" | grep -qw "$apid"; then
      echo -e "  ${Y}보호${NC}: PID=$apid — 메인 프로세스 조상"
      continue
    fi
    if [ -n "$MY_PID" ] && [ "$apid" = "$MY_PID" ]; then
      continue
    fi
    _ptn=$(echo "$_proc_args" | grep -oP '(?<=--team-name )\S+' | head -1 || true)
    [ -z "$_ptn" ] && _ptn="(팀명 미상)"
    _kill_agent_proc "$apid" "$_ptn"
  done
fi


# 모든 활성/FINISH 파이프라인의 team_name 수집
_team_names=""
for sdir in "$SESSION_ENV"/*/; do
  [ -d "$sdir" ] || continue
  _tn=$(cat "${sdir}team_name" 2>/dev/null || true)
  [ -z "$_tn" ] && continue
  _team_names="$_team_names $_tn"
done

# [T5 — conv_178866599628] 런타임 팀 디렉토리명 합집합 추가.
# session-env/*/team_name 파일이 없어도(F-AGENT-1 RC2 계열) 실제 런타임 팀
# 디렉토리(/tmp/cc-*/teams/session-*, $HOME/.claude/teams/session-*)는 존재할 수
# 있으므로, 그 basename을 합집합으로 넣어 아래 pgrep 탐색 대상에서 누락되지
# 않게 한다. 읽기 전용 수집이며 타 세션 팀명을 stdout에 나열하지 않는다(§(c)).
for _rtd in /tmp/cc-*/teams/session-* "$HOME_DIR"/.claude/teams/session-*; do
  [ -d "$_rtd" ] || continue
  _team_names="$_team_names $(basename "$_rtd")"
done
_team_names=$(echo "$_team_names" | tr ' ' '\n' | sort -u | tr '\n' ' ')

for _tn in $_team_names; do
  # pgrep -f 로 해당 팀의 에이전트 프로세스 탐색
  agent_pids=$(pgrep -f "agent-id.*@${_tn}" 2>/dev/null || true)
  [ -z "$agent_pids" ] && continue

  for apid in $agent_pids; do
    # [사이클168] parent 1차 소스에서 이미 처리한 PID 는 건너뛴다(중복 열거·중복 kill 방지)
    case "$_SEEN_PIDS" in *" $apid "*) continue ;; esac
    # 메인 프로세스 조상 보호
    if echo "$MY_ANCESTORS" | grep -qw "$apid"; then
      echo -e "  ${Y}보호${NC}: PID=$apid — 메인 프로세스 조상"
      continue
    fi
    # 메인 PID 직접 비교
    if [ -n "$MY_PID" ] && [ "$apid" = "$MY_PID" ]; then
      continue
    fi

    # ⚠️ 타세션 보호 (L-328 — 2026-04-08): --parent-session-id가 현재 UUID와 정확히 일치해야만 kill 허용
    # 화이트리스트 방식: 일치 확인된 경우만 kill, 불명확하면 보호 (메인에이전트 절대 kill 금지 포함)
    _proc_args=$(ps -ww -o args= -p "$apid" 2>/dev/null || true)  # 폭 무관(COLUMNS 잘림 방지)
    _proc_session=$(echo "$_proc_args" | grep -oP '(?<=--parent-session-id )\S+' || true)
    if [ -z "$_proc_session" ]; then
      # --parent-session-id 없음 → 에이전트 프로세스가 아니거나 불명확 → 보호
      echo -e "  ${Y}보호${NC}: PID=$apid — parent-session-id 불명 (비에이전트 또는 다른 버전) — L-328 skip"
      continue
    fi
    if [ -z "$CURRENT_UUID" ] || [ "$_proc_session" != "$CURRENT_UUID" ]; then
      # L-362: shutdown_sent=true인 완료 에이전트는 L-328 예외 허용
      _pane_id_for_agent=$(tmux list-panes -a -F '#{pane_pid} #{pane_id}' 2>/dev/null | awk -v pid="$apid" '$1==pid {print $2}' | head -1)
      AGENT_FILE=$(grep -rl "pane_id=${_pane_id_for_agent}" "$SESSION_ENV"/*/agents/ 2>/dev/null | head -1)
      if [ -n "$AGENT_FILE" ] && grep -q "^shutdown_sent=true" "$AGENT_FILE" 2>/dev/null; then
        echo -e "  → shutdown_sent=true 확인 — L-328 예외, kill 대상"
        # kill 대상으로 분류 (skip 하지 않음)
      else
        echo -e "  ${Y}보호${NC}: PID=$apid — 타세션($( echo $_proc_session | cut -c1-8)...) 에이전트 — L-328 skip (shutdown_sent 없음)"
        continue
      fi
    fi

    _kill_agent_proc "$apid" "$_tn"
  done
done

[ $((CLEANED_AGENT_PROCS + PLANNED_AGENT_PROCS)) -eq 0 ] && echo -e "  ${G}(없음)${NC}"

# ── 1.6 bash fallback pane 전수 스캔 (에이전트 종료 후 bash로 빠진 pane) ──
# ⚠️ L-350 수정 (2026-04-16): oio bash_exec 경유 시 MY_PANE = 메인 Claude pane 오탐 위험
# 자기 pane(MY_PANE) kill 로직 완전 제거 — MY_PANE 단독 신뢰 금지, PROTECTED_PANES 기반 보호
# 정리 대상: agents/에 미등록된 bash pane (PROTECTED_PANES 전체 제외)
echo -e "\n${Y}[1.6] bash fallback pane 정리${NC}"
CLEANED_BASH_FALLBACK=0

if [ -n "$MY_SESSION" ]; then
  # [사이클168] `| while` 은 서브셸이라 카운터가 소실됐다 → 프로세스 치환으로 바꿔 보존한다.
  while read BPANE BCMD BPID; do
    [ "$BCMD" != "bash" ] && continue  # bash 상태만 대상

    # 보호 pane 목록 전체 확인 (MY_PANE + 조상 프로세스 pane — L-350)
    # oio bash_exec 환경에서 MY_PANE이 메인 Claude pane을 반환하므로 이 체크가 핵심 방어선
    if echo "$PROTECTED_PANES" | grep -qF "$BPANE"; then
      echo -e "  ${Y}보호${NC}: $BPANE CMD=$BCMD PID=$BPID — PROTECTED_PANES 목록"
      continue
    fi

    # 조상 트리 보호 (메인 Claude Code 프로세스가 있는 pane은 절대 보호)
    if echo "$MY_ANCESTORS" | grep -qw "$BPID"; then
      echo -e "  ${Y}보호${NC}: $BPANE CMD=$BCMD PID=$BPID — 메인 프로세스 조상"
      continue
    fi

    # 이 bash pane에 실질적 자식 프로세스가 있는지 확인
    # (team-cleanup.sh 자체 프로세스 제외 — 임시이므로)
    has_meaningful_child=false
    for cpid in $(pgrep -P "$BPID" 2>/dev/null); do
      cname=$(ps -o comm= -p "$cpid" 2>/dev/null || echo "")
      case "$cname" in
        claude|2.1.*|node|python|npm) has_meaningful_child=true ;;
        bash|sh|grep|awk|ps|pgrep|sleep|cat|tmux) ;;  # 스크립트 임시 프로세스 무시
        *) has_meaningful_child=true ;;
      esac
    done

    if ! $has_meaningful_child; then
      echo -e "  ${R}bash fallback${NC}: $BPANE PID=$BPID (에이전트 종료 잔류)"
      if [ "$MODE" = "--dry-run" ]; then
        echo -e "    ${Y}[DRY-RUN] kill 예정${NC}"
        PLANNED_BASH_FALLBACK=$((PLANNED_BASH_FALLBACK + 1))
      else
        tmux set -g status off 2>/dev/null || true
        _kill_pane "$BPANE"
        tmux set -g status on 2>/dev/null || true
        echo -e "    ${G}killed${NC}"
        CLEANED_BASH_FALLBACK=$((CLEANED_BASH_FALLBACK + 1))
      fi
    fi
  done < <(tmux list-panes -t "$MY_SESSION" -F '#{pane_id} #{pane_current_command} #{pane_pid}' 2>/dev/null)
fi

[ $((CLEANED_BASH_FALLBACK + PLANNED_BASH_FALLBACK)) -eq 0 ] && echo -e "  ${G}(없음)${NC}"

# ── 2. 고착 파이프라인 IDLE 리셋 ──
echo -e "\n${Y}[2] 고착 파이프라인 정리${NC}"
for sdir in "$SESSION_ENV"/*/; do
  [ -d "$sdir" ] || continue
  uuid=$(basename "$sdir")
  state=$(state_read "${sdir}state" 2>/dev/null | awk '{print $1}' || echo "IDLE")

  case "$state" in
    PLAN|OK|DEV|TEST|DONE) ;;
    *) continue ;;
  esac

  # 현재 세션 UUID는 고착 판정에서 제외 (ofinish 진행 중 보호)
  if [ -n "$CURRENT_UUID" ] && [ "$uuid" = "$CURRENT_UUID" ]; then
    echo -e "  ${G}스킵${NC}: 현재 세션 — 고착 판정 제외"
    continue
  fi

  # [c41-odev4] §(c) 정보 노출 금지 + §(a) 쓰기 경계 선제 적용.
  # 타 세션은 ★열거조차 하지 않는다★ — UUID 를 stdout 에 찍는 것 자체가 §(c) 위반이다.
  # 종전에는 여기서 타 세션 10건을 "고착"으로 전부 출력했다(실측). 이제 조용히 건너뛴다.
  # --cross-session 명시 시에만 종전 동작(열거+정리 후보)으로 진입한다.
  if [ "$MODE" != "--cross-session" ] && [ "$uuid" != "$CURRENT_UUID" ]; then
    SKIPPED_FOREIGN=$((SKIPPED_FOREIGN + 1))
    continue
  fi

  # 에이전트 pane 생존 확인
  alive=0
  for af in "${sdir}agents/"*; do
    [ -f "$af" ] || continue
    pid=$(grep "^pane_id=" "$af" 2>/dev/null | cut -d= -f2)
    if [ -n "$pid" ]; then
      cmd=$(tmux display-message -t "$pid" -p '#{pane_current_command}' 2>/dev/null || echo "")
      [ -n "$cmd" ] && alive=$((alive + 1))
    fi
  done

  if [ "$alive" -eq 0 ]; then
    agent_count=$(ls "${sdir}agents/" 2>/dev/null | wc -l)
    echo -e "  ${R}고착${NC}: ${uuid:0:8}... 상태=$state 에이전트=${agent_count}개 (전원 사망)"
    if [ "$MODE" = "--dry-run" ]; then
      echo -e "    ${Y}[DRY-RUN] IDLE 리셋 + 잔류 파일 삭제 예정${NC}"
    else
      # [P2-isolation] §(a) 쓰기 경계: 타 세션 state 직접 쓰기 금지.
      # ofinish --force 경로에서는 CURRENT_UUID == uuid (자기 세션만) 이므로 위 continue로 이미 스킵.
      # 잔류하는 타 세션 고착 정리는 --cross-session 플래그가 있을 때만 허용.
      # (위쪽 §(c) 게이트에서 타 세션은 이미 걸러졌다 — 여기 도달하면 자기 세션이거나
      #  --cross-session 명시 경로다. 2중 방어로 조건은 유지한다.)
      if [ "$MODE" != "--cross-session" ] && [ "$uuid" != "$CURRENT_UUID" ]; then
        continue
      fi
      if _confirm; then
        # [A2 — 사이클49] 섹션[4]와 동일 패턴 — rm -rf 는 디렉토리 통째 삭제라
        # 미러링(_mirror_delete_strict)을 거치지 않는다. 개별 파일을 먼저 열거해
        # 각각 미러 삭제한 뒤 rm -rf 로 원본을 정리한다.
        #
        # ★B3 — 빈 디렉토리 껍데기 잔존, 해소 불가 확정★ (사이클51, goal.json B3):
        #   파일은 위에서 개별 미러 삭제되지만 디렉토리 자체(agents/evidence/panes/
        #   compact)는 rm -rf 가 로컬(원본 base)에서만 지운다. 반대편 base 에는
        #   *빈* 디렉토리 껍데기가 남는다 — session_mirror.sh 의 _mirror_delete 가
        #   S-1 설계로 디렉토리 인자를 거부하기 때문이다(파일 단위 복제/삭제만
        #   지원, 트리 삭제는 의도적으로 미지원 — "잘못 지우면 복구가 없다"는
        #   안전 설계 트레이드오프).
        #
        #   ★A1(사이클50)로 완성된 mcp__oio__dir_delete 양쪽 base 미러링을 여기서
        #   쓸 수 있는가 — 검토 결과: 불가하다. 사유는 추정이 아니라 구조 확인이다:
        #   oio MCP 서버(`MCP-Servers/oio-mcp-server/server.py`)는 `mcp.run(
        #   transport="stdio")` 로 기동하며, 이는 Claude Code 에이전트 프로세스와
        #   1:1 로 맺어진 stdin/stdout JSON-RPC 채널이다. `team-cleanup.sh` 는
        #   독립 셸 프로세스(bash)로 실행되며 이 MCP 세션에 참여할 방법이 없다 —
        #   HTTP/소켓 등 셸에서 호출 가능한 대체 트랜스포트가 없다(stdio 단일
        #   트랜스포트). 즉 "다른 도구를 못 찾아서"가 아니라 "셸 프로세스가
        #   구조적으로 MCP 클라이언트가 될 수 없어서"다.
        #
        #   ⇒ 실질 위험 평가: 빈 디렉토리 껍데기는 데이터 유출이 없고(파일 내용
        #   없음), statusline/게이트가 참조하는 것은 그 안의 *파일*(team_name 등,
        #   이미 개별 미러 삭제됨)이지 디렉토리 존재 자체가 아니다. 다음 세션의
        #   같은 UUID 재사용 시 `mkdir -p` 로 재사용되거나, 섹션[4] 빈 세션
        #   정리가 최종적으로 상위 디렉토리째 정리한다. (c)등급(낮은 심각도)
        #   판정 유지. 코드 수정 없이 이 확정 판정을 주석으로 고정한다.
        for _d2 in "${sdir}agents" "${sdir}evidence" "${sdir}panes" "${sdir}compact"; do
          [ -d "$_d2" ] || continue
          find "$_d2" -type f 2>/dev/null | while read -r _es_f2; do
            _mirror_delete "$_es_f2"
          done
        done
        rm -rf "${sdir}agents/" "${sdir}evidence/" "${sdir}panes/" "${sdir}compact/" 2>/dev/null
        rm -f "${sdir}team_name" "${sdir}classification" "${sdir}pipeline_start_time" "${sdir}reroute_count" 2>/dev/null
        # 사이클47 삭제 미러 — 반대편 base 에 잔존하면 statusline/게이트가 옛 값을 읽는다
        _mirror_delete "${sdir}team_name"
        _mirror_delete "${sdir}classification"
        _mirror_delete "${sdir}pipeline_start_time"
        _mirror_delete "${sdir}reroute_count"
        # [P2-isolation] §(a) + L-362: state_write() 원자적 쓰기 사용 (echo > 직접 쓰기 금지)
        state_write "${sdir}state" "IDLE ${uuid}"
        echo -e "    ${G}IDLE 리셋 완료${NC}"
        CLEANED_PIPELINES=$((CLEANED_PIPELINES + 1))
      fi
    fi
  fi
done

# ── 3. 팀 디렉토리 점검 (보고 전용) ──
# ★[사이클169] 이 블록은 아무것도 지우지 않는다.★
#   팀 디렉토리 삭제는 Claude Code 세션 종료 자동 정리와 team_create_guard 의 lazy orphan cleanup 이 맡는다.
#   종전 rm 경로는 leadSessionId 를 `"leadSessionId":"…"`(공백 없음) 형식으로만 읽어 실제 JSON
#   (`"leadSessionId": "…"`)에서 항상 빈값이었다 — 그래서 "소유권 불명"으로만 빠졌고, 고쳐서 살리면
#   활성 팀을 지울 위험이 생긴다. 그래서 고치지 않고 경로 자체를 없앴다.
# ★"사용 중" 판정은 A·B·C 합집합(OR)이다★ — 삭제 판정이 아니므로 과대 포함이 안전한 방향이다.
#   A. teams/<n>/config.json 의 leadSessionId == CURRENT_UUID
#   B. session-env/CURRENT_UUID/team_name 내용 == <n>
#   C. --parent-session-id CURRENT_UUID 프로세스의 --team-name == <n>
# ★§(c) — 내 세션이 쓰지 않는 팀은 이름·lead 를 출력하지 않고 건수만 낸다.★
echo -e "\n${Y}[3] 팀 디렉토리 점검 (보고 전용 — 삭제는 Claude Code 자동 정리·team_create_guard lazy cleanup 담당)${NC}"

# config.json 의 leadSessionId — 콜론 앞뒤 공백 허용. python3 json 우선, 실패 시 grep -E 폴백.
_team_lead_of() {
  local _cfg="$1/config.json" _v=""
  [ -f "$_cfg" ] || { echo ""; return 0; }
  if command -v python3 >/dev/null 2>&1; then
    _v=$(python3 -c '
import sys, json
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
    v = d.get("leadSessionId", "") if isinstance(d, dict) else ""
    print(v if isinstance(v, str) else "")
except Exception:
    print("")
' "$_cfg" 2>/dev/null || true)
  fi
  if [ -z "$_v" ]; then
    _v=$(grep -oE '"leadSessionId"[[:space:]]*:[[:space:]]*"[^"]*"' "$_cfg" 2>/dev/null | head -1 | \
      sed -E 's/.*:[[:space:]]*"([^"]*)"$/\1/' || true)
  fi
  echo "$_v"
}

# C축 — --parent-session-id 가 CURRENT_UUID 와 ★정확히★ 같은 프로세스의 --team-name 목록
_my_proc_teams() {
  local _me="$1" _p _args _ps _tn
  for _p in $(pgrep -f -- "--parent-session-id ${_me}" 2>/dev/null); do
    _args=$(tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null || true)
    _ps=$(echo "$_args" | grep -oP '(?<=--parent-session-id )\S+' | head -1 || true)
    [ "$_ps" = "$_me" ] || continue
    _tn=$(echo "$_args" | grep -oP '(?<=--team-name )\S+' | head -1 || true)
    [ -n "$_tn" ] && echo "$_tn"
  done | sort -u
}

TEAMS_IN_USE=0
TEAMS_FOREIGN_OR_UNUSED=0
TEAMS_UNDETERMINED=0
if [ -d "$TEAMS_DIR" ]; then
  _my_team_file=""
  _my_proc_team_list=""
  if [ -n "$CURRENT_UUID" ]; then
    _my_team_file=$(tr -d '\r\n' < "$SESSION_ENV/$CURRENT_UUID/team_name" 2>/dev/null || true)
    _my_proc_team_list=$(_my_proc_teams "$CURRENT_UUID")
  fi
  for td in "$TEAMS_DIR"/*/; do
    [ -d "$td" ] || continue
    tname=$(basename "$td")
    # UUID 를 확정하지 못하면 내 것인지 알 수 없다 — 이름 없이 건수만 (fail-closed)
    if [ -z "$CURRENT_UUID" ]; then
      TEAMS_UNDETERMINED=$((TEAMS_UNDETERMINED + 1))
      continue
    fi
    _why=""
    _lead=$(_team_lead_of "$td")
    [ -n "$_lead" ] && [ "$_lead" = "$CURRENT_UUID" ] && _why="${_why}A"
    [ -n "$_my_team_file" ] && [ "$_my_team_file" = "$tname" ] && _why="${_why}B"
    [ -n "$_my_proc_team_list" ] && printf '%s\n' "$_my_proc_team_list" | grep -qxF -- "$tname" && _why="${_why}C"
    if [ -n "$_why" ]; then
      echo -e "  ${G}사용 중${NC}: $tname (근거 ${_why}) — 삭제 대상 아님"
      TEAMS_IN_USE=$((TEAMS_IN_USE + 1))
    else
      TEAMS_FOREIGN_OR_UNUSED=$((TEAMS_FOREIGN_OR_UNUSED + 1))
    fi
  done
fi
[ "$TEAMS_FOREIGN_OR_UNUSED" -gt 0 ] && echo -e "  타 세션·미사용 팀: ${TEAMS_FOREIGN_OR_UNUSED}개 (이름 비출력 · 이 스크립트는 건드리지 않음)"
[ "$TEAMS_UNDETERMINED" -gt 0 ] && echo -e "  ${Y}판정 불가${NC} 팀: ${TEAMS_UNDETERMINED}개 (현재 세션 UUID 미확정 — 이름 비출력)"
[ $((TEAMS_IN_USE + TEAMS_FOREIGN_OR_UNUSED + TEAMS_UNDETERMINED)) -eq 0 ] && echo -e "  ${G}(없음)${NC}"

# ── 4. 빈 session-env 디렉토리 정리 ──
echo -e "\n${Y}[4] 빈 session-env 정리${NC}"
CLEANED_SESSIONS=0
for sdir in "$SESSION_ENV"/*/; do
  [ -d "$sdir" ] || continue
  uuid=$(basename "$sdir")
  state=$(state_read "${sdir}state" 2>/dev/null | awk '{print $1}' || echo "")

  # IDLE이 아닌 상태 또는 state 파일이 없는 경우만 체크
  if [ -z "$state" ] || [ "$state" = "" ]; then
    # [A3 근본해법 — 사이클49] file_count 계산에서 *.lock/*.tmp* 부산물 제외.
    # state_read()(session_id.sh)가 flock 을 위해 ${STATE_FILE}.lock 을 항상 만든다 —
    # 이는 정상 동작 시의 의도된 산출물이지 "실질 내용"이 아니다. 이를 세면
    # ① 원래 파일 0개 세션도 file_count=1 로 부풀려지고(우연히 통과는 하나 의미가 부정확)
    # ② 원래 파일 1개(state만) 세션은 file_count=2 가 되어 정리 대상에서 누락된다.
    #
    # ★B4 — *.lock.* / *.tmp.* 오탐 수정★ (사이클51, goal.json B4):
    #   기존 패턴 `*.lock.*`/`*.tmp.*` 는 "점(.) 뒤에 아무 문자열"까지 걸려서
    #   `foo.lock.bak` 같은 ★실질 콘텐츠 파일★ 도 부산물로 오인해 제외했다.
    #   이 프로젝트의 실제 부산물 명명 규칙(session_id.sh/state_machine.sh/
    #   session_mirror.sh 코드 확인 — 추정 아님)은 항상 "원본파일명 + 고정
    #   접미사"이고, 접미사 뒤에 오는 것은 ★PID 숫자뿐★ 이다:
    #     ${STATE_FILE}.lock            (flock 파일 — 접미사 뒤에 아무것도 없음)
    #     ${STATE_FILE}.tmp.$$          (원자적 쓰기 임시파일 — $$ 는 PID 숫자)
    #     ${STATE_FILE}.mig.$$          (state_machine.sh 마이그레이션 임시파일)
    #     ${dst}.mirror.$$              (session_mirror.sh 미러 임시파일)
    #   즉 ".lock" 뒤에 ".bak" 같은 ★비숫자 접미사★ 가 오는 실사용 파일명은
    #   이 코드베이스에 존재하지 않는다. 그래서 ".lock.*" 처럼 넓게 열지 않고
    #   "끝이 정확히 .lock" 이거나 "끝이 .tmp/.mig/.mirror + 숫자열" 인 경우만
    #   좁혀 제외한다. 과잉 삭제 방지(넓히면 콘텐츠 파일 오탐)와 부작용 파일
    #   누락 방지(좁히면 진짜 lock 잔존)를 동시에 만족하는 유일한 교집합이다.
    #   session_mirror.sh 의 _mirror_peer_path 제외 패턴(`*.lock.*` 등)은 미러링
    #   판정 전용이라 여기서 맞출 필요가 없다 — 그쪽은 "미러하지 않을 파일"을
    #   넓게 잡아도 안전(과소 미러링일 뿐)하지만, 여기는 "삭제 판정"이라 넓히면
    #   실사용 세션을 빈 세션으로 오판해 삭제하는 정반대 위험이 있다.
    file_count=$(find "$sdir" -type f \
      ! -name '*.lock' \
      ! -name '*.tmp.[0-9]*' ! -name '*.mig.[0-9]*' ! -name '*.mirror.[0-9]*' \
      2>/dev/null | wc -l)
    if [ "$file_count" -le 1 ]; then  # state 파일만 있거나 비어있음 (lock/tmp 부산물 제외 후)
      echo -e "  ${Y}빈 세션${NC}: ${uuid:0:8}..."
      if [ "$MODE" != "--dry-run" ]; then
        if _confirm; then
          # 사이클47 삭제 미러 — _mirror_delete_strict 는 디렉토리 인자를 거부하므로
          # 트리 통째 미러는 불가. rm -rf 직전에 개별 파일을 열거해 각각 미러 삭제한다.
          find "$sdir" -type f 2>/dev/null | while read -r _es_f; do
            _mirror_delete "$_es_f"
          done
          rm -rf "$sdir"
          CLEANED_SESSIONS=$((CLEANED_SESSIONS + 1))
          echo -e "    ${G}삭제${NC}"
        fi
      else
        echo -e "    ${Y}[DRY-RUN] 삭제 예정${NC}"
      fi
    fi
  fi
done
[ "$CLEANED_SESSIONS" -eq 0 ] && echo -e "  ${G}(없음)${NC}"

# ── 요약 ──
echo -e "\n${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${C}🧹 정리 결과${NC}"
echo -e "  고아 pane kill: ${CLEANED_PANES}개"
echo -e "  잔류 에이전트 프로세스 kill: ${CLEANED_AGENT_PROCS}개"
echo -e "  고착 파이프라인 리셋: ${CLEANED_PIPELINES}개"
# [c41-odev4] §(c) — 건수만. 어느 세션인지는 절대 출력하지 않는다.
[ "$SKIPPED_FOREIGN" -gt 0 ] && echo -e "  타 세션(미열거·무접촉): ${SKIPPED_FOREIGN}개"
echo -e "  팀 디렉토리: 삭제 안 함(보고 전용) — 사용 중 ${TEAMS_IN_USE}개 / 타 세션·미사용 ${TEAMS_FOREIGN_OR_UNUSED}개 / 판정 불가 ${TEAMS_UNDETERMINED}개"
echo -e "  빈 세션 삭제: ${CLEANED_SESSIONS}개"
if [ "$MODE" = "--dry-run" ]; then
  # [사이클168] 예정 건수 — 실제 kill 카운터(위)와 별도로 센 값이다.
  echo "  [DRY-RUN] kill 예정 — 고아 pane: ${PLANNED_PANES}개 / 잔류 에이전트 프로세스: ${PLANNED_AGENT_PROCS}개 / bash fallback: ${PLANNED_BASH_FALLBACK}개"
  echo -e "\n  ${Y}[DRY-RUN] 실제 정리하려면: bash ${HARNESS_HOME:-$HOME/.harness}/current/scripts/team-cleanup.sh --force${NC}"
fi
echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# ── 자기 pane kill 로직 제거 (L-350 수정 2026-04-16) ──
# oio bash_exec 경유 시 SELF_PANE_KILL이 메인 Claude pane을 가리킬 수 있으므로 전면 제거
# 메인 pane은 절대 kill 금지 — PROTECTED_PANES 기반 섹션 [1.6] 보호로 대체
