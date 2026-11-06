#!/bin/bash
# 리드의 SendMessage/Agent 지시 하나에 독립 과업(서로 다른 파일 묶음) 여러 건이 담기면 분리 배정을 권고하는 PreToolUse 경고 가드 — 메인 전용, 차단 없음
#
# 등록: PreToolUse matcher "SendMessage|Agent" (timeout 5s)
# 코어: lib/multi_task_assign_guard.py
# 배경(2026-10-10 c174): 독립 과업 2건을 한 팀원에게 한 메시지로 배정 → 뒤늦은 분리 재배정이 늦게 도착해 두 팀원이 같은 파일을 건드릴 뻔했다.
# 스위치: 전역 OFF touch ${HARNESS_HOME:-$HOME/.harness}/current/hooks/.multi_task_assign_guard_off
# 세션 격리: 반복 억제 기록은 자기 session_id 의 session-env/logs/ 에만 쓴다. 타 세션 정보 출력 없음.

trap 'exit 0' ERR
[[ -f "${HARNESS_HOME:-$HOME/.harness}/current/hooks/.multi_task_assign_guard_off" ]] && exit 0
# 팀원(PIPELINE_UUID 보유)은 대상 아님 — 리드의 배정만 본다
[[ -n "${PIPELINE_UUID:-}" ]] && exit 0

INPUT=$(timeout 3 cat 2>/dev/null) || exit 0
SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null | tr -d '[:space:]')
SDIR=""
if [[ "$SID" =~ ^[0-9a-f-]{36}$ ]]; then
  SDIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/$SID"
  [[ -d "$SDIR" ]] || SDIR=""
fi
LIB="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/multi_task_assign_guard.py"
[[ -f "$LIB" ]] || LIB="${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/multi_task_assign_guard.py"
[[ -f "$LIB" ]] || exit 0
# [사이클182 반복1 B] 의도된 fail-open — 판정 timeout·비정상 종료는 출력 없이 통과한다. bash_exec/Agent 경로 교착 방지(부하 때 fail-closed 면 모든 호출이 막힌다), F-WG-SELF 와 같은 성격.
printf '%s' "$INPUT" | MTAG_SESSION_DIR="$SDIR" timeout 4 python3 -I "$LIB" 2>/dev/null
exit 0
