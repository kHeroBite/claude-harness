#!/usr/bin/env bash
# 메인이 파이프라인(PLAN/DEV) 중 Agent 를 spawn 하기 전 ListAgents 로 동일 프로젝트 타 세션을 확인했는지 강제하는 PreToolUse hook
# 메인 AND state∈{PLAN,DEV} AND classification 존재 AND peer_check_done 부재 → block(exit 2). 그 외·판별 실패는 fail-open.
set -uo pipefail

INPUT="$(cat 2>/dev/null || true)"
[ -z "$INPUT" ] && exit 0

_PY='import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
k=sys.argv[1]
if k=="tool_name": print(d.get("tool_name") or "")
elif k=="sid": print(d.get("session_id") or "")'
TOOL="$(printf '%s' "$INPUT" | python3 -c "$_PY" tool_name 2>/dev/null)"
[ "$TOOL" != "Agent" ] && exit 0

_is_team() {
  if [ -n "${PEER_TEST_ROLE:-}" ]; then [ "$PEER_TEST_ROLE" = "team" ]; return; fi
  local pid=$$ depth=0 cmd
  while [ "$depth" -lt 10 ] && [ -n "$pid" ] && [ "$pid" != "0" ] && [ "$pid" != "1" ]; do
    cmd="$(tr '\0' ' ' 2>/dev/null < "/proc/${pid}/cmdline")"
    if [[ "$cmd" =~ --parent-session-id[[:space:]]+[0-9a-f-]{36} ]] || [[ "$cmd" =~ --agent-name[[:space:]]+[^[:space:]]+ ]]; then
      return 0
    fi
    pid="$(sed 's/^.*) //' "/proc/${pid}/stat" 2>/dev/null | awk '{print $2}')"
    [[ "$pid" =~ ^[0-9]+$ ]] || break
    depth=$((depth + 1))
  done
  return 1
}
_is_team && exit 0

UUID="$(printf '%s' "$INPUT" | python3 -c "$_PY" sid 2>/dev/null | tr -d '[:space:]')"
[[ "$UUID" =~ ^[0-9a-f-]{36}$ ]] || exit 0
SDIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/$UUID"
[ -f "$SDIR/state" ] || exit 0

STATE="$(head -n1 "$SDIR/state" 2>/dev/null | awk '{print $1}')"
case "$STATE" in PLAN|DEV) ;; *) exit 0 ;; esac
[ -s "$SDIR/classification" ] || exit 0

if [ -f "$SDIR/peer_check_done" ]; then
  # D7 — 기준점 REF = max(last_prompt_epoch, 직전 ofinish_done|ofinish_cleanup_done) (두 base).
  #   마커 >= REF 면 이번 턴·이번 사이클 ListAgents 이므로 ok_started 가 그 뒤에 찍혔어도 인정한다. last_prompt_epoch 가 없으면 아래 종전 판정만 남는다.
  _PREF=""; _PLPE=0
  for _B in "$SDIR" "$HOME/.claude/session-env/$UUID"; do
    for _R in last_prompt_epoch evidence/ofinish_done evidence/ofinish_cleanup_done; do
      [ -f "$_B/$_R" ] || continue
      [ "$_R" = last_prompt_epoch ] && _PLPE=1
      if [ -z "$_PREF" ] || [ "$_B/$_R" -nt "$_PREF" ]; then _PREF="$_B/$_R"; fi
    done
  done
  if [ "$_PLPE" = 1 ] && [ ! "$SDIR/peer_check_done" -ot "$_PREF" ]; then
    exit 0
  fi
  # 종전 판정: 사이클 시작 기준 파일이 있으면 마커가 그보다 새로운지 확인(없으면 생략). DEV 중 새 사용자 입력으로 REF 가 밀려도 여기서 통과한다.
  _REF="$SDIR/evidence/ok_started"
  if [ -f "$_REF" ] && [ "$SDIR/peer_check_done" -ot "$_REF" ]; then
    :
  else
    exit 0
  fi
fi

_LOGD="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/logs"
mkdir -p "$_LOGD" 2>/dev/null
printf '%s F-PEER-GATE blocked: state=%s\n' "$(date -Is 2>/dev/null)" "$STATE" >> "$_LOGD/peer_gate.log" 2>/dev/null

cat >&2 <<EOF
⛔ [F-PEER-GATE] 작업 시작 전 ListAgents 로 같은 프로젝트의 타 세션을 확인하고 통지하세요.
  - ListAgents 를 1회 호출하면(PostToolUse 가 마커를 기록) 이 차단은 즉시 풀립니다.
  - 같은 프로젝트에서 작업 중인 타 세션이 있으면 사용자에게 알린 뒤 진행하세요.
EOF
exit 2
