#!/bin/bash
# 시험 기록(ac_records*.json)·계약(goal.json) 쓰기를 기준표 record_contract 로 검사하는 PreToolUse hook — 판정은 단일 판정기 ac_gate.py hook 에 위임
# matcher: mcp__oio__file_write|mcp__oio__file_edit|mcp__oio__file_copy|mcp__oio__file_move|mcp__oio__file_rename|Write|Edit
# 사이클196 oi-fix-1 P1-H/P1-G — 기록 위치·형식 위반을 판정 시점이 아니라 쓰는 순간 차단한다(규약 밖 기록이 "기록 없음"으로만 드러나던 문제).
#   기준표(plans/acceptance_criteria.json)에 record_contract 가 없으면 무동작이다(진행 중 사이클 무영향).
#   판정기 파일이 없거나 내부 오류면 통과한다 — 판정 시점 검증(ac_gate.py item 의 형식·위치 검사)이 뒤에 남는다.
HOOK_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
GATE="${AC_GATE_PY:-$(dirname "$HOOK_DIR")/skills/otest_make/scripts/ac_gate.py}"
INPUT=$(timeout 2 cat 2>/dev/null) || INPUT=""
[[ -z "$INPUT" ]] && exit 0
case "$INPUT" in *ac_records*|*goal.json*|*gate*.py*) ;; *) exit 0 ;; esac
[[ -f "$GATE" ]] || exit 0
OUT=$(printf '%s' "$INPUT" | timeout 8 python3 "$GATE" hook 2>/dev/null)
RC=$?
if [[ $RC -eq 2 ]]; then
  printf '%s\n' "$OUT"
  printf '%s' "$OUT" | jq -r '.reason // empty' 2>/dev/null >&2
  exit 2
fi
exit 0
