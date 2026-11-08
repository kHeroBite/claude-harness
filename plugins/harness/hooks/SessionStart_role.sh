#!/bin/bash
# SessionStart 입력의 공식 source 필드(startup/resume/clear/compact/fork)를 role_lib source-mark 로 기록하는 hook
# 실패해도 세션 시작을 막지 않는다(항상 exit 0, 출력 없음). 팀원(PIPELINE_UUID)은 무동작.
[ -n "${PIPELINE_UUID:-}" ] && exit 0
INPUT=$(timeout 5 cat 2>/dev/null) || INPUT=""
[ -z "$INPUT" ] && exit 0
_HD="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
_LIB="$_HD/lib/role_lib.py"
[ -r "$_LIB" ] || _LIB="${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/role_lib.py"
[ -r "$_LIB" ] || exit 0
_P=$(printf '%s' "$INPUT" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin); print((d.get("session_id") or "")+" "+(d.get("source") or "")+"\n"+(d.get("cwd") or ""))
except Exception:
    pass' 2>/dev/null)
_CWD="${_P#*$'\n'}"; [ "$_CWD" = "$_P" ] && _CWD=""
_P="${_P%%$'\n'*}"
_SID="${_P%% *}"; _SRC="${_P#* }"
[ -n "$_SID" ] && [ -n "$_SRC" ] && [ "$_SID" != "$_P" ] || exit 0
[ -n "$_CWD" ] || _CWD="$PWD"
timeout 4 python3 -B "$_LIB" source-mark --sid "$_SID" --source "$_SRC" --register --cwd "$_CWD" >/dev/null 2>&1 || true
exit 0
