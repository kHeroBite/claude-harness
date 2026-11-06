#!/bin/bash
# team-report.sh — 팀/pane/파이프라인 현황 리포팅
# 사용: bash ${HARNESS_HOME:-$HOME/.harness}/current/scripts/team-report.sh
# ostatus Step 1, ofinish_cleanup Step 1 에서 호출
#
# ★[사이클169] 자기 세션만 출력한다 (CLAUDE.md 세션 격리 §(c)).★
#   타 세션의 UUID·팀명·에이전트명·tmux 세션명은 출력하지 않고 "타 세션 N개" 건수만 남긴다.
#   자기 세션 판정은 PIPELINE_UUID 1순위 → session_id.sh resolve_uuid 순이다.
#   둘 다 실패하면 경고를 내고 전부 건수만 출력한다(판정 불가 — fail-closed).

set -o pipefail
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
HOME_DIR="$HOME"
# [사이클169] $HOME/.claude 하드코딩은 CLAUDE_CONFIG_DIR 세션(/tmp/cc-*)에서 엉뚱한 디렉토리를 스캔했다.
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME_DIR/.claude}"
SESSION_ENV="$CONFIG_DIR/session-env"
TEAMS_DIR="$CONFIG_DIR/teams"

# state_read/state_write (F-NEW-3 flock 기반 안전 읽기)
source "$HOME_DIR/.claude/hooks/lib/session_id.sh" 2>/dev/null

# 색상
R='\033[0;31m' G='\033[0;32m' Y='\033[0;33m' C='\033[0;36m' NC='\033[0m'

# ── 자기 세션 UUID 판정 (PIPELINE_UUID 1순위) ──
MY_UUID=""
if [ -n "${PIPELINE_UUID:-}" ]; then
  MY_UUID="$PIPELINE_UUID"
elif type resolve_uuid >/dev/null 2>&1; then
  resolve_uuid "" 2>/dev/null && MY_UUID="${UUID:-}"
fi

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

# --parent-session-id 가 MY_UUID 와 ★정확히★ 같은 프로세스의 --team-name 목록
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

echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${C}📊 team-report: 팀/pane/파이프라인 현황${NC}"
echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if [ -z "$MY_UUID" ]; then
  echo -e "  ${Y}경고${NC}: 현재 세션 UUID 를 확정하지 못했다 (PIPELINE_UUID 미설정 · resolve_uuid 실패)"
  echo -e "         ⇒ 모든 팀·세션을 ${Y}판정 불가${NC}로 보고 건수만 출력한다. 호출 시 PIPELINE_UUID=<UUID> 를 넘길 것."
fi

# ── 1. 팀 디렉토리 ──
echo -e "\n${Y}[1] 팀 디렉토리 (${TEAMS_DIR}/)${NC}"
TEAM_COUNT=0
MY_TEAM_COUNT=0
OTHER_TEAM_COUNT=0
if [ -d "$TEAMS_DIR" ]; then
  _my_team_file=""
  _my_proc_team_list=""
  if [ -n "$MY_UUID" ]; then
    _my_team_file=$(tr -d '\r\n' < "$SESSION_ENV/$MY_UUID/team_name" 2>/dev/null || true)
    _my_proc_team_list=$(_my_proc_teams "$MY_UUID")
  fi
  for td in "$TEAMS_DIR"/*/; do
    [ -d "$td" ] || continue
    tname=$(basename "$td")
    TEAM_COUNT=$((TEAM_COUNT + 1))
    _why=""
    if [ -n "$MY_UUID" ]; then
      _lead=$(_team_lead_of "$td")
      [ -n "$_lead" ] && [ "$_lead" = "$MY_UUID" ] && _why="${_why}A"
      [ -n "$_my_team_file" ] && [ "$_my_team_file" = "$tname" ] && _why="${_why}B"
      [ -n "$_my_proc_team_list" ] && printf '%s\n' "$_my_proc_team_list" | grep -qxF -- "$tname" && _why="${_why}C"
    fi
    if [ -n "$_why" ]; then
      members=$(cat "$td/config.json" 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);print(len(d.get('members',[]))) " 2>/dev/null || echo "?")
      echo -e "  ${G}✅${NC} $tname (멤버 ${members}명) — 내 세션 사용 중 (근거 ${_why})"
      MY_TEAM_COUNT=$((MY_TEAM_COUNT + 1))
    else
      OTHER_TEAM_COUNT=$((OTHER_TEAM_COUNT + 1))
    fi
  done
fi
[ "$OTHER_TEAM_COUNT" -gt 0 ] && echo -e "  타 세션·미사용 팀 ${OTHER_TEAM_COUNT}개 (이름 비출력)"
[ "$TEAM_COUNT" -eq 0 ] && echo -e "  ${G}(없음)${NC}"

# ── 2. 파이프라인 상태 ──
echo -e "\n${Y}[2] 파이프라인 상태 (${SESSION_ENV}/)${NC}"
ACTIVE_PIPELINES=0
STALE_PIPELINES=""
OTHER_SESS_COUNT=0
OTHER_SESS_ACTIVE=0
for sdir in "$SESSION_ENV"/*/; do
  [ -d "$sdir" ] || continue
  uuid=$(basename "$sdir")
  state=$(state_read "${sdir}state" 2>/dev/null | awk '{print $1}' || echo "IDLE")  # F-NEW-3

  # §(c) 타 세션은 건수만 — UUID·state·팀명·에이전트를 출력하지 않는다
  if [ -z "$MY_UUID" ] || [ "$uuid" != "$MY_UUID" ]; then
    OTHER_SESS_COUNT=$((OTHER_SESS_COUNT + 1))
    case "$state" in
      PLAN|OK|DEV|TEST|DONE|FINISH) OTHER_SESS_ACTIVE=$((OTHER_SESS_ACTIVE + 1)) ;;
    esac
    continue
  fi

  team=$(cat "${sdir}team_name" 2>/dev/null || echo "-")
  agent_count=$(ls "${sdir}agents/" 2>/dev/null | wc -l)

  case "$state" in
    PLAN|OK|DEV|TEST|DONE|FINISH)
      ACTIVE_PIPELINES=$((ACTIVE_PIPELINES + 1))
      # 에이전트 pane 생존 확인
      alive=0; dead=0
      for af in "${sdir}agents/"*; do
        [ -f "$af" ] || continue
        pid=$(grep "^pane_id=" "$af" 2>/dev/null | cut -d= -f2)
        if [ -n "$pid" ]; then
          cmd=$(tmux display-message -t "$pid" -p '#{pane_current_command}' 2>/dev/null || echo "")
          if [ -n "$cmd" ]; then
            alive=$((alive + 1))
          else
            dead=$((dead + 1))
          fi
        else
          dead=$((dead + 1))
        fi
      done
      if [ "$alive" -gt 0 ]; then
        echo -e "  ${G}▶${NC} ${uuid:0:8}... ${C}$state${NC} 팀=$team 에이전트=${agent_count}개 (생존=${alive} 사망=${dead})"
      elif [ "$agent_count" -gt 0 ]; then
        echo -e "  ${R}⚠️${NC} ${uuid:0:8}... ${R}$state${NC} 팀=$team 에이전트=${agent_count}개 ${R}(전원 사망 — 고착)${NC}"
        STALE_PIPELINES="$STALE_PIPELINES $uuid"
      else
        echo -e "  ${Y}▶${NC} ${uuid:0:8}... ${C}$state${NC} 팀=$team (에이전트 없음)"
      fi
      ;;
    IDLE|"")
      echo -e "  ${NC}  ${uuid:0:8}... IDLE${NC}"
      ;;
    *)
      echo -e "  ${Y}?${NC} ${uuid:0:8}... $state"
      ;;
  esac
done
[ "$ACTIVE_PIPELINES" -eq 0 ] && echo -e "  ${G}내 세션 활성 파이프라인 없음${NC}"
[ "$OTHER_SESS_COUNT" -gt 0 ] && echo -e "  타 세션 ${OTHER_SESS_COUNT}개 (활성 ${OTHER_SESS_ACTIVE}개 · 미열거)"

# ── 3. tmux pane 전수 스캔 ──
echo -e "\n${Y}[3] tmux pane 전수 스캔${NC}"
MY_PANE=$(tmux display-message -p '#{pane_id}' 2>/dev/null || echo "")
MY_SESSION=$(tmux display-message -p '#{session_name}' 2>/dev/null || echo "")
ORPHAN_PANES=""
ORPHAN_COUNT=0

if [ -z "$MY_PANE" ]; then
  echo -e "  ${Y}tmux 세션 아님 — 스킵${NC}"
else
  echo -e "  메인: pane=$MY_PANE 세션=$MY_SESSION"
  echo ""

  # 표 헤더
  DIVIDER="─────────────────────────────────────────────────────────────────────────────────────────────"
  printf "  \033[0;36m%-26s | %-8s | %-12s | %-30s | %s\033[0m\n" "세션ID/에이전트명" "Pane ID" "상태" "작업내용" "마지막변경"
  echo -e "  $DIVIDER"

  # 현재 세션의 모든 pane
  tmux list-panes -t "$MY_SESSION" -F '#{pane_id} #{pane_current_command} #{pane_pid}' 2>/dev/null | while read SPANE SCMD SPID; do

    # 마지막 활동 타임스탬프 → "N분 전" 변환
    LAST_TS=$(tmux display-message -t "$SPANE" -p '#{pane_last_activity}' 2>/dev/null || echo "0")
    NOW=$(date +%s)
    if [ -n "$LAST_TS" ] && [ "$LAST_TS" -gt 0 ] 2>/dev/null; then
      DIFF=$(( NOW - LAST_TS ))
      if [ "$DIFF" -lt 60 ]; then
        AGO="${DIFF}초 전"
      elif [ "$DIFF" -lt 3600 ]; then
        AGO="$((DIFF/60))분 전"
      else
        AGO="$((DIFF/3600))시간 전"
      fi
    else
      AGO="-"
    fi

    # pane의 마지막 비공백 출력줄 3개 (최대 80자)
    LAST_LINES=$(tmux capture-pane -t "$SPANE" -p 2>/dev/null | grep -v '^[[:space:]]*$' | tail -3 | sed 's/^[[:space:]]*//' || echo "")

    if [ "$SPANE" = "$MY_PANE" ]; then
      printf "  \033[0;32m%-26s | %-8s | %-12s | %-30s | %s\033[0m\n" "[메인]" "$SPANE" "메인" "-" "$AGO"
      if [ -n "$LAST_LINES" ]; then
        echo "$LAST_LINES" | while IFS= read -r L; do
          [ -n "$L" ] && printf "  \033[0;32m  └─ %s\033[0m\n" "$(echo "$L" | cut -c1-80)"
        done
      fi
      continue
    fi

    # agents/ 파일에 등록되어 있는지 확인 — 에이전트명·작업은 ★내 세션 등록분만★ 읽는다
    registered=""
    registered_other=false
    agent_name=""
    task_info=""
    if [ -n "$MY_UUID" ]; then
      for af in "$SESSION_ENV/$MY_UUID/agents/"*; do
        [ -f "$af" ] || continue
        aid=$(grep "^pane_id=" "$af" 2>/dev/null | cut -d= -f2)
        if [ "$aid" = "$SPANE" ]; then
          registered="$MY_UUID"
          agent_name=$(basename "$af")
          task_info=$(grep "^task=" "$af" 2>/dev/null | cut -d= -f2- | cut -c1-30 || echo "")
          break
        fi
      done
    fi
    if [ -z "$registered" ]; then
      for af in "$SESSION_ENV"/*/agents/*; do
        [ -f "$af" ] || continue
        aid=$(grep "^pane_id=" "$af" 2>/dev/null | cut -d= -f2)
        if [ "$aid" = "$SPANE" ]; then
          registered_other=true
          break
        fi
      done
    fi

    # 상태 판정
    if echo "$SCMD" | grep -qE '^(claude|2\.[0-9]+\.[0-9]+)$'; then
      # statusline에서 IDLE 여부 확인
      STATUS_LINE=$(tmux capture-pane -t "$SPANE" -p 2>/dev/null | tail -3 | tr '\n' ' ' || echo "")
      if echo "$STATUS_LINE" | grep -qi 'IDLE'; then
        PANE_STATUS="IDLE"
        STATUS_COLOR="\033[0m"
      else
        PANE_STATUS="진행중"
        STATUS_COLOR="\033[0;32m"
      fi
    elif [ -z "$SCMD" ]; then
      PANE_STATUS="소멸"
      STATUS_COLOR="\033[0;31m"
    else
      PANE_STATUS="bash(비정상)"
      STATUS_COLOR="\033[0;33m"
    fi

    # 표시용 이름 — 내 세션 등록분만 에이전트명, 타 세션 등록분은 표식만
    if [ -n "$registered" ] && [ -n "$agent_name" ]; then
      DISPLAY_NAME="${agent_name}"
    elif $registered_other; then
      DISPLAY_NAME="[타 세션 등록 pane]"
      LAST_LINES=""
    elif echo "$SCMD" | grep -qE '^(claude|2\.[0-9]+\.[0-9]+)$'; then
      DISPLAY_NAME="[미등록 claude]"
    else
      DISPLAY_NAME="[고아 pane]"
    fi

    # 작업내용 / 마지막변경 컬럼 분리
    TASK_COL="${task_info:--}"
    TIME_COL="$AGO"

    printf "  ${STATUS_COLOR}%-26s | %-8s | %-12s | %-30s | %s\033[0m\n" "$DISPLAY_NAME" "$SPANE" "$PANE_STATUS" "$TASK_COL" "$TIME_COL"
    if [ -n "$LAST_LINES" ]; then
      echo "$LAST_LINES" | while IFS= read -r L; do
        [ -n "$L" ] && printf "  ${STATUS_COLOR}  └─ %s\033[0m\n" "$(echo "$L" | cut -c1-80)"
      done
    fi

    # 고아 pane 카운트
    if [ -z "$registered" ] && ! $registered_other && ! echo "$SCMD" | grep -qE '^(claude|2\.[0-9]+\.[0-9]+)$'; then
      # 서브셸이라 직접 증가 불가 — 파일로 카운트 전달
      echo "orphan" >> /tmp/team-report-orphan-$$
    fi
  done

  # 서브셸에서 생성된 고아 카운트 집계
  if [ -f /tmp/team-report-orphan-$$ ]; then
    ORPHAN_COUNT=$(wc -l < /tmp/team-report-orphan-$$)
    rm -f /tmp/team-report-orphan-$$
  fi

  # 다른 tmux 세션 — §(c) 이름·pane 수는 출력하지 않고 건수만
  OTHER_TMUX_COUNT=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -vxF -- "${MY_SESSION}" | wc -l)
  [ "${OTHER_TMUX_COUNT:-0}" -gt 0 ] && echo -e "\n  다른 tmux 세션 ${OTHER_TMUX_COUNT}개 (미열거)"
fi

# ── 4. 요약 ──
echo -e "\n${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${C}📋 요약${NC}"
echo -e "  팀: ${TEAM_COUNT}개 (내 세션 사용 중:${MY_TEAM_COUNT}개 / 타 세션·미사용:${OTHER_TEAM_COUNT}개)"
echo -e "  파이프라인: 내 세션 활성 ${ACTIVE_PIPELINES}개 (고착:$(echo $STALE_PIPELINES | wc -w | tr -d ' ')개) / 타 세션 ${OTHER_SESS_COUNT}개"
echo -e "  현재 세션 고아 pane: ${ORPHAN_COUNT:-0}개"

# 문제 있으면 경고 — 팀 디렉토리는 보고 전용(team-cleanup [3])이므로 HAS_ISSUE 에 넣지 않는다
HAS_ISSUE=false
[ -n "$STALE_PIPELINES" ] && HAS_ISSUE=true
[ "${ORPHAN_COUNT:-0}" -gt 0 ] && HAS_ISSUE=true

if $HAS_ISSUE; then
  echo -e "\n  ${R}⚠️ 정리 필요! 실행: bash ${HARNESS_HOME:-$HOME/.harness}/current/scripts/team-cleanup.sh${NC}"
else
  echo -e "\n  ${G}✅ 이상 없음${NC}"
fi
echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
