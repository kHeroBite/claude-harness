#!/bin/bash
# 메인(리드)의 모든 도구 호출 직전에 유휴·무응답 팀에이전트를 판정해 경고/차단하는 PreToolUse 가드
#
# 등록: PreToolUse matcher "*" (timeout 10s) — 메인 세션에서만 동작, 팀에이전트는 즉시 exit 0
# 코어: lib/teammate_idle_guard.py (판정 규칙·근거 데이터·출력 형식은 그 파일 머리말 참조)
#
# 배경(2026-10-07 c171): post_agent_shutdown_enforce.sh 는 PostToolUse:Agent 에만 걸려
#   spawn 이 없던 10:54~18:10 동안 0회 실행됐고, 경고를 plain stdout 으로 내서 모델에 닿지 않았다.
#   ⇒ 매 도구 호출(PreToolUse *)로 시점을 옮기고 additionalContext/deny JSON 으로 모델에 전달한다.
#
# 규칙(2026-10-08 팀원 생명주기 관리 추가): 기존 A 유휴 / B 무응답 / C 턴 중 무보고 / S shutdown 후 잔존 에 더해
#   D 무보고 대기 : 팀원 TeammateIdle_report_guard 가 기록한 teammate_turn/<이름>.json status=silent → 즉시 경고, 장기화 시 차단
#   E pane_dead   : shutdown 없이 죽음 → 즉시 차단 / shutdown 후 잔존 → 경고 후 차단 / pane 소실 → 경고
#   F 사유 없는 done : @agent_state=done + agent_keep 무효 + shutdown 미발송 → 경고 후 차단
#   keep 표시 동기화 : done↔keep 을 agent_keep 유효성에 맞춰 자기 팀 pane 에만 pane 단위로 다시 쓴다
#   실존 판정 : tmuxPaneId 가 있는 팀원은 pane(죽은 pane 포함) 또는 --agent-id NAME@TEAM 프로세스가 있어야 판정 대상.
#               둘 다 없는 과거 인스턴스(명단 in-memory 잔존)는 A~F·S 전부 제외. 관측 후 사라진 경우만 30분 E 소실 경고
#               (TIG_GONE_WARN_MIN, 테스트 주입 TIG_AGENT_PROCS)
#   차단 중 복구 허용 : 단독 tmux capture-pane/kill-pane/display/list-panes, 같은 역할 Agent 재spawn(E/D),
#                       자기 session-env 의 evidence/(shutdown_sent 제외)·plans/handoff_ file_write
# 임계값 env(분): TIG_SILENT_BLOCK_MIN=10, TIG_DEAD_BLOCK_MIN=5, TIG_DONE_BLOCK_MIN=5 (기존 TIG_IDLE_*/TIG_NORESP_*/TIG_SILENT_WARN_MIN/TIG_KEEP_TTL_MIN 유지)
# tmux 읽기: TMUX env 가 있을 때 list-panes -a 1회(timeout 2s), 자기 팀 config 의 tmuxPaneId 행만 사용.
#   테스트 전용: TIG_TMUX_PANES(TSV 주입 — tmux 미호출), TIG_DRY_TMUX=1(keep 동기화를 로그만)
#
# 모드·면제:
#   env        : TEAMMATE_IDLE_GUARD_MODE=off|warn|block (시험용 — settings 에는 없다, 부재 시 block)
#   면제       : session-env/${UUID}/agent_keep/{팀원이름} 에 사유 5자 이상(120분 유효)
#   오탐 처리  : 파일 off 스위치는 2026-10-11 제거했다(사람만 쓸 수 있어 자율 진행을 막았다).
#                코어가 스스로 판정한다 — 이전 인스턴스 기록 제외·결과 요청 후 강등·연속 30회 차단 시 30분 자동 강등.
# 세션 격리: 자기 UUID 의 session-env 와 그 team_name 이 가리키는 팀 config 만 읽는다. 타 세션 정보 출력 없음.
#   소유: leadSessionId==자기 UUID 이면 전체 소유. 불일치(재개 세션)면 코어가 자기 팀 pane 프로세스 argv 의
#   --agent-id NAME@TEAM + --parent-session-id UUID 정확 토큰 쌍으로 증명한 경우에만 판정(실패 시 무출력 + SKIP owner-unproven 로그).
#   테스트 주입 TIG_OWNER_PANES 는 env 상속으로 코어에 그대로 전달된다.
# 이력: 2026-10-08 재개 세션 소유 판정 추가(leadSessionId 불일치로 코어가 조기 종료해 가드 전체가 무력하던 문제)

trap 'exit 0' ERR

# 팀에이전트 프로세스는 PIPELINE_UUID 를 가진다 — 메인 전용
[[ -n "${PIPELINE_UUID:-}" ]] && exit 0

INPUT=$(timeout 5 cat 2>/dev/null) || exit 0
SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null | tr -d '[:space:]')
[[ "$SID" =~ ^[0-9a-f-]{36}$ ]] || exit 0

BASE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SESSION_DIR="$BASE/session-env/$SID"
[[ -f "$SESSION_DIR/team_name" ]] || exit 0
TEAM=$(tr -d '[:space:]' < "$SESSION_DIR/team_name" 2>/dev/null)
[[ -n "$TEAM" && "$TEAM" != */* ]] || exit 0
CONFIG="$BASE/teams/$TEAM/config.json"
[[ -f "$CONFIG" ]] || exit 0

MODE="${TEAMMATE_IDLE_GUARD_MODE:-block}"
case "$MODE" in
  off) exit 0 ;;
  warn|block) ;;
  *) MODE=block ;;
esac

LIB="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/teammate_idle_guard.py"
[[ -f "$LIB" ]] || LIB="${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/teammate_idle_guard.py"
[[ -f "$LIB" ]] || exit 0

# [c193 oi-fix-2 2026-10-19] 죽은 자기 팀원 pane 자동 캡처·정리 — Claude Code 가 팀원 pane 에 remain-on-exit=failed 를
#   걸어 비정상 종료(예: 143) pane 이 화면에 남는다. 증거(evidence/dead_panes/)를 남긴 뒤에만 kill 한다. 15초에 1회, 무출력.
#   정리된 팀원은 아래 코어가 "pane 소실" 로 보고하므로 메인은 같은 역할 재spawn 만 하면 된다. 실패는 무시(fail-open).
_OTP_LIB="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/own_team_pane.sh"
_OTP_STAMP="$SESSION_DIR/.dead_pane_reap_at"
if [[ -r "$_OTP_LIB" && -n "${TMUX:-}" ]]; then
  _otp_last=$(stat -c %Y "$_OTP_STAMP" 2>/dev/null || echo 0)
  if (( $(date +%s) - _otp_last >= 15 )); then
    touch "$_OTP_STAMP" 2>/dev/null
    ( source "$_OTP_LIB" 2>/dev/null && otp_reap_dead "$SID" "$SESSION_DIR" >/dev/null 2>&1 ) </dev/null 2>/dev/null || true
  fi
fi

# [사이클182 반복1 B] 의도된 fail-open — 판정 timeout·비정상 종료는 출력 없이 통과한다. bash_exec/Agent 경로 교착 방지(부하 때 fail-closed 면 모든 호출이 막힌다), F-WG-SELF 와 같은 성격.
printf '%s' "$INPUT" | TIG_UUID="$SID" TIG_SESSION_DIR="$SESSION_DIR" TIG_CONFIG="$CONFIG" TIG_MODE="$MODE" \
  timeout 8 python3 -I "$LIB" 2>/dev/null
exit 0
