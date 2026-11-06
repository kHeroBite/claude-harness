#!/usr/bin/env bash
# session_state 로 IDLE 을 쓰려 할 때 타 세션 통지(peer_notified.json)가 있고 마무리 확인(peer_finish_done)이 없으면 경고만 하는 PreToolUse hook
# 차단하지 않는다(항상 exit 0). stderr 경고 + logs 기록만 수행.
set -uo pipefail

INPUT="$(cat 2>/dev/null || true)"
[ -z "$INPUT" ] && exit 0

_PY='import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
k=sys.argv[1]
if k=="tool_name": print(d.get("tool_name") or "")
elif k=="sid": print(d.get("session_id") or "")
elif k=="idle":
    ti=d.get("tool_input") or {}
    s=json.dumps(ti,ensure_ascii=False)
    import re
    print(1 if re.search(r"\bIDLE\b",s) else 0)'
_PY2='import sys,json
try: j=json.load(open(sys.argv[1]))
except Exception: print(0); sys.exit(0)
p=j.get("peers") if isinstance(j,dict) else None
print(1 if p else 0)'
TOOL="$(printf '%s' "$INPUT" | python3 -c "$_PY" tool_name 2>/dev/null)"
[ "$TOOL" != "mcp__oio__session_state" ] && exit 0
[ "$(printf '%s' "$INPUT" | python3 -c "$_PY" idle 2>/dev/null)" = "1" ] || exit 0

UUID="$(printf '%s' "$INPUT" | python3 -c "$_PY" sid 2>/dev/null | tr -d '[:space:]')"
[[ "$UUID" =~ ^[0-9a-f-]{36}$ ]] || exit 0
SDIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/$UUID"
[ -f "$SDIR/peer_notified.json" ] || exit 0
[ "$(python3 -c "$_PY2" "$SDIR/peer_notified.json" 2>/dev/null)" = "1" ] || exit 0
[ -e "$SDIR/peer_finish_done" ] && exit 0

_LOGD="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/logs"
mkdir -p "$_LOGD" 2>/dev/null
printf '%s F-PEER-FINISH warn: IDLE 전환 시도, peer_finish_done 없음\n' "$(date -Is 2>/dev/null)" >> "$_LOGD/peer_gate.log" 2>/dev/null
echo "⚠️ [F-PEER-FINISH] 작업 시작 시 통지한 타 세션이 있으나 마무리 확인(peer_finish_done)이 없습니다. 종료 전 타 세션 충돌 여부를 점검·통지하세요." >&2
exit 0
