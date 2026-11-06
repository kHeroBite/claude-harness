#!/bin/bash
# 팀원 oio bash_exec 의 90초 초과 추정 호출을 막고, deny 목록 명령이 섞인 Monitor 호출을 원인과 함께 선차단하는 PreToolUse 가드
#
# 등록: PreToolUse matcher "mcp__oio__bash_exec|Monitor" (timeout 5s)
# 코어: lib/oio_bash_duration_guard.py (판정 규칙·실측 근거는 그 파일 머리말 참조)
# 배경(2026-10-10 c174): 120초를 넘긴 MCP 호출은 Claude Code 가 백그라운드로 넘기며, 그런 호출이 남은 팀원 세션은
#   이후 oio 호출 전부가 "Invalid request parameters" 로 실패했다(odev-10-2·odev-10-4 손실). 긴 폴링 루프 동안에는
#   리드 메시지도 처리되지 않았다(odev-10-5, 1시간 지연).
# 대상: bash_exec 판정은 팀원(PIPELINE_UUID 보유)만. Monitor 판정은 리드·팀원 공통(어차피 권한 단계에서 거부되는 호출만 걸린다).
# 스위치(재시작 불필요):
#   전역 OFF : touch ${HARNESS_HOME:-$HOME/.harness}/current/hooks/.oio_bash_duration_guard_off
#   env      : OBDG_MODE=block|warn (기본 block), OBDG_LIMIT_SEC (기본 90)
# 세션 격리: 아무 파일도 쓰지 않는다. 타 세션 정보 출력 없음.

trap 'exit 0' ERR
[[ -f "${HARNESS_HOME:-$HOME/.harness}/current/hooks/.oio_bash_duration_guard_off" ]] && exit 0

INPUT=$(timeout 3 cat 2>/dev/null) || exit 0
LIB="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/oio_bash_duration_guard.py"
[[ -f "$LIB" ]] || LIB="${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/oio_bash_duration_guard.py"
[[ -f "$LIB" ]] || exit 0

TM=0
[[ -n "${PIPELINE_UUID:-}" ]] && TM=1
# [사이클182 반복1 B] 의도된 fail-open — 판정 timeout·비정상 종료는 출력 없이 통과한다. bash_exec/Agent 경로 교착 방지(부하 때 fail-closed 면 모든 호출이 막힌다), F-WG-SELF 와 같은 성격.
printf '%s' "$INPUT" | OBDG_TEAMMATE="$TM" timeout 4 python3 -I "$LIB" 2>/dev/null
exit 0
