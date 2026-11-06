#!/bin/bash
# -no-window 없는 Android 에뮬레이터 실행(사용자 화면에 창 노출)을 차단하는 PreToolUse 가드
#
# 등록: PreToolUse matcher "Bash|mcp__oio__bash_exec" (timeout 5s)
# 코어: lib/emulator_headless_guard.py (판정 규칙·한계는 그 파일 머리말 참조)
# 배경(2026-10-11): 모바일 시험 담당이 에뮬레이터를 창 모드로 띄워 사용자 화면에 노출했다(상시 제약 "사용자 활동 중 화면 노출 UI 금지" 위반).
#   기본값은 Skill('otest_mobile_emulator_bg') 의 헤드리스(-no-window)다.
# 예외: -list-avds·-version·adb emu kill 등 창이 뜨지 않는 호출, 세션 마커 session-env/<UUID>/emulator_windowed_ok(리드가 사용자 요청 시에만 생성).
# 스위치(재시작 불필요):
#   전역 OFF : touch ${HARNESS_HOME:-$HOME/.harness}/current/hooks/.emulator_headless_guard_off
#   env      : EHG_MODE=block|warn (기본 block)
# 세션 격리: 아무 파일도 쓰지 않는다(마커는 읽기만). 타 세션 정보 출력 없음.

trap 'exit 0' ERR
[[ -f "${HARNESS_HOME:-$HOME/.harness}/current/hooks/.emulator_headless_guard_off" ]] && exit 0

INPUT=$(timeout 3 cat 2>/dev/null) || exit 0

# [2026-10-19 사이클193 F-MARS-PROD-LAUNCH] 운영(15959) 대상 Mars.exe 기동 차단 — 같은 matcher 를 쓰므로 이 등록 hook 에 잇는다(settings 무변경·즉시 적용).
#   코어: lib/mars_prod_launch_guard.py · 시험: tests/test_mars_prod_launch_guard.sh · 전역 OFF: touch ${HARNESS_HOME:-$HOME/.harness}/current/hooks/.mars_prod_launch_guard_off
#   deny 가 나오면 그것만 내고 끝낸다(JSON 1개 계약). 판정 실패·timeout 은 무출력 통과(아래 에뮬 판정과 같은 fail-open).
MPLG="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/mars_prod_launch_guard.py"
if [[ -f "$MPLG" && ! -f "${HARNESS_HOME:-$HOME/.harness}/current/hooks/.mars_prod_launch_guard_off" ]]; then
  MPLG_OUT=$(printf '%s' "$INPUT" | timeout 2 python3 -I "$MPLG" 2>/dev/null)
  if [[ -n "$MPLG_OUT" ]]; then printf '%s' "$MPLG_OUT"; exit 0; fi
fi

LIB="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/emulator_headless_guard.py"
[[ -f "$LIB" ]] || LIB="${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/emulator_headless_guard.py"
[[ -f "$LIB" ]] || exit 0

# [사이클182 반복1 B] 의도된 fail-open — 판정 timeout·비정상 종료는 출력 없이 통과한다. bash_exec/Agent 경로 교착 방지(부하 때 fail-closed 면 모든 호출이 막힌다), F-WG-SELF 와 같은 성격.
printf '%s' "$INPUT" | timeout 4 python3 -I "$LIB" 2>/dev/null
exit 0
