#!/bin/bash
# 병렬 가능한 팀에이전트를 직렬로 spawn 하는 패턴을 감지하는 PreToolUse(Agent) 가드 — 메인 전용
#
# 배경(2026-10-10 사용자 지시): "병렬이 가능한 작업들을 팀에이전트를 여러개 spawn해서 진행하라.
#   이를 하네스에도 기록해 다음부터는 자동으로 병렬진행하도록 해달라."
#   스킬(odev_parallel·WAVE_SPAWN)에 "같은 Wave 는 한 메시지에서 동시 spawn" 규칙은 있었으나 물리 강제가 없었고,
#   ok_pipeline 4.5단계는 batch 를 +1 씩만 전이해 선행이 끝난 독립 batch 도 직렬로 진행됐다.
# 코어: lib/parallel_spawn_guard.py (판정 규칙 S1 같은 그룹 직렬 spawn / B1 독립 batch 동시 진행 권고)
#
# 스위치(재시작 불필요):
#   전역 OFF  : touch ${HARNESS_HOME:-$HOME/.harness}/current/hooks/.parallel_spawn_guard_off
#   세션 모드 : session-env/${UUID}/parallel_spawn_guard_mode 내용 = off | warn | block (부재 시 warn)
#   env 기본값: PARALLEL_SPAWN_GUARD_MODE=off|warn|block, PSG_GAP_SEC(기본 60초 — 같은 응답 판정 간격)
#   block 은 그룹당 첫 위반 1회만 deny 하고 재시도는 통과한다(업무 정지 방지).
# 로그: session-env/${UUID}/logs/parallel_spawn_guard.log
# 세션 격리: 자기 session_id 의 session-env 만 읽고 쓴다. 타 세션 정보 출력 없음.

trap 'exit 0' ERR

# ── F-AGENT-CAP (10C, 2026-10-11 사용자 지시 "메인 포함 10개, 즉 팀에이전트만 9개 제한") ──
# 코어: lib/agent_cap.py — /proc cmdline 실측 + flock 예약 슬롯. 상한은 config/batch_limits.json
#   team_agent_limits.max_live_teammates (1~9만 유효, 그 밖은 9).
# 아래 전역 OFF 스위치·세션 모드·file_assignment 조건보다 앞에 둬 이 가드를 꺼도 상한은 산다.
# ※ 확정 경로는 PreToolUse_Agent_cap.sh(settings: time_budget 7.5 closed)다. 이 블록은 그 hook 이 settings 에
#   등록되기 전에 시작한 세션용 구 경로다. Claude Code 는 hook 목록을 세션 시작 시 고정하고 스크립트 파일은 매번
#   새로 읽으므로, 그런 세션에서는 이 블록이 유일한 상한 경로다 → 제거하지 않는다.
# 종전 결함(L-585 후속 항목 1): agent_cap.py 를 3초 timeout 으로 직접 돌려 rc 124(판정 미완)가 그대로 통과(0)였다.
# 지금: 신 경로 hook 에 위임한다 — AGENT_CAP_VIA_LEGACY=1(캐시 키 분리) + AGENT_CAP_WAIT_SEC=1.5
#   (래퍼 open 예산 2.5 안에서 보류를 확정하기 위한 대기 상한). 판정 미완은 신 경로가 보류(exit 2 + 재시도 안내)로 낸다.
#   rc 2 → 차단·보류(안내 그대로), 124·≥128(위임 자체가 끊김 = 판정 미완) → 보류, 0 → 진행, 그 밖(판정 불가) → 진행.
#   신 경로 hook 부재 → 판정 불가 fail-open(종전 lib 부재 시와 같음).
# 신 세션 중복 방지: 신 경로가 직접 호출될 때마다 자기 세션 logs/agent_cap_direct 표식을 남긴다.
#   표식이 있으면(= 이 세션은 신 경로가 등록돼 있다) 위임을 건너뛴다. 첫 spawn 1회는 두 경로가 함께 돌 수 있으나
#   agent_cap.py 의 같은 이름 미기동 예약(allow_dup)으로 한 번만 센다.
# 잔존 한계(정직 고지): 구 세션에서 bash 기동·위임까지 래퍼 open 예산(2.5~3.0s)을 넘기면 래퍼가 통과시킨다.
#   세션에 고정된 정책 문자열(open)이라 파일 수정으로 닫을 수 없고, 세션을 다시 시작하면 신 경로(closed)로 해소된다.
# ★rc 는 `|| _cap_rc=$?` 로 받는다 — `; rc=$?` 로 쓰면 ERR trap 이 먼저 발동해 차단(2)이 통과(0)로 뒤집힌다.
# stdin 은 여기서 1회만 읽고 아래 본문이 INPUT 을 재사용한다(두 번 읽으면 빈 입력).
INPUT=$(timeout 5 cat 2>/dev/null) || exit 0
if [[ -z "${PIPELINE_UUID:-}" ]]; then
  _CAP_HOOK="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/PreToolUse_Agent_cap.sh"
  [[ -f "$_CAP_HOOK" ]] || _CAP_HOOK="${HARNESS_HOME:-$HOME/.harness}/current/hooks/PreToolUse_Agent_cap.sh"
  _CAP_SID=""
  if [[ "$INPUT" =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([0-9a-f-]{36})\" ]]; then _CAP_SID="${BASH_REMATCH[1]}"; fi
  _CAP_MARK="${AGENT_CAP_SESSION_BASE:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env}/$_CAP_SID/logs/agent_cap_direct"
  if [[ -f "$_CAP_HOOK" ]] && ! [[ -n "$_CAP_SID" && -f "$_CAP_MARK" ]]; then
    _cap_rc=0
    printf '%s' "$INPUT" | AGENT_CAP_VIA_LEGACY=1 AGENT_CAP_WAIT_SEC=1.5 bash "$_CAP_HOOK" || _cap_rc=$?
    if (( _cap_rc == 2 )); then
      exit 2
    elif (( _cap_rc == 124 || _cap_rc >= 128 )); then
      printf '🚦 [F-AGENT-CAP] 상한 판정이 중단돼 끝나지 않았습니다(rc=%s) — 이번 spawn 을 1회 보류합니다. 같은 spawn 호출을 2·4·8초 후 다시 보내십시오.\n' "$_cap_rc" >&2
      exit 2
    fi
  fi
fi

[[ -f "${HARNESS_HOME:-$HOME/.harness}/current/hooks/.parallel_spawn_guard_off" ]] && exit 0
# 팀에이전트 프로세스는 PIPELINE_UUID 를 가진다 — 메인 전용
[[ -n "${PIPELINE_UUID:-}" ]] && exit 0

# INPUT 은 위 F-AGENT-CAP 블록에서 이미 읽었다(재사용)
SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null | tr -d '[:space:]')
[[ "$SID" =~ ^[0-9a-f-]{36}$ ]] || exit 0

BASE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SESSION_DIR="$BASE/session-env/$SID"
[[ -d "$SESSION_DIR" ]] || exit 0
# 할당 문서가 없으면 판정 대상 아님
[[ -f "$SESSION_DIR/file_assignment.json" || -f "$SESSION_DIR/plans/phase_batches.json" ]] || exit 0

MODE="${PARALLEL_SPAWN_GUARD_MODE:-warn}"
if [[ -f "$SESSION_DIR/parallel_spawn_guard_mode" ]]; then
  MODE=$(tr -d '[:space:]' < "$SESSION_DIR/parallel_spawn_guard_mode" 2>/dev/null)
fi
case "$MODE" in
  off) exit 0 ;;
  warn|block) ;;
  *) MODE=warn ;;
esac

LIB="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/parallel_spawn_guard.py"
[[ -f "$LIB" ]] || LIB="${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/parallel_spawn_guard.py"
[[ -f "$LIB" ]] || exit 0

# [사이클182 반복1 B] 의도된 fail-open — 판정 timeout·비정상 종료는 출력 없이 통과한다. bash_exec/Agent 경로 교착 방지(부하 때 fail-closed 면 모든 호출이 막힌다), F-WG-SELF 와 같은 성격.
printf '%s' "$INPUT" | PSG_SESSION_DIR="$SESSION_DIR" PSG_MODE="$MODE" \
  timeout 8 python3 -I "$LIB" 2>/dev/null
exit 0
