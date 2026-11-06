#!/bin/bash
# 장애 리포트를 처리한 세션이 접수 게이트(err_report gate) 통과 없이 ofinish 로 종료하는 것을 막는 PreToolUse:Skill hook
# 조건 (모두 충족해야 통과): 이 세션이 장애 리포트 쓰기를 했다면(표식 또는 최근 스냅샷) evidence/err_gate.json 이
#   gate=PASS · envs 에 dev·prod 전부 · checked_at 이 6시간 이내 · 마지막 쓰기(표식·스냅샷)보다 나중이어야 한다.
# 쓰기 이력이 없는 세션은 영향 0 (통과). 판정 불가(파싱 실패)는 fail-open — 다른 세션을 막지 않는다.
set -u

INPUT=$(cat)
PARSED=$(printf '%s' "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print('|'); sys.exit(0)
ti = d.get('tool_input') or {}
print((ti.get('skill') or '') + '|' + (d.get('session_id') or ''))
" 2>/dev/null) || exit 0
SKILL="${PARSED%%|*}"
SID="${PARSED#*|}"

# ofinish 또는 plugin:ofinish 형태만 대상
case "$SKILL" in
  ofinish|*:ofinish) ;;
  *) exit 0 ;;
esac

UUID="${PIPELINE_UUID:-$SID}"
[ -z "$UUID" ] && exit 0
case "$UUID" in */*|*..*) exit 0 ;; esac

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SDIR="$CONFIG_DIR/session-env/$UUID"
SNAP_DIR="${ERRGATE_SNAP_DIR:-/mnt/c/DATA/Project/_tmp_err_report/snapshots}"
EVID="$SDIR/evidence/err_gate.json"
MAX_AGE_SEC="${ERRGATE_MAX_AGE_SEC:-21600}"

# 이 세션의 마지막 장애 리포트 쓰기 시각(epoch) — 표식 또는 세션 UUID 가 박힌 최근 스냅샷
LAST_WRITE=0
if [ -f "$SDIR/errgate_required" ]; then
  LAST_WRITE=$(stat -c %Y "$SDIR/errgate_required" 2>/dev/null || echo 0)
fi
if [ -d "$SNAP_DIR" ]; then
  for f in $(find "$SNAP_DIR" -maxdepth 1 -name 'err_report_*.json' -mmin -1440 2>/dev/null); do
    grep -Eq "\"session\": ?\"$UUID\"" "$f" 2>/dev/null || continue
    m=$(stat -c %Y "$f" 2>/dev/null || echo 0)
    [ "$m" -gt "$LAST_WRITE" ] && LAST_WRITE=$m
  done
fi

# 쓰기 이력 없음 → 장애 처리 세션이 아님
[ "$LAST_WRITE" -eq 0 ] && exit 0

block() {
  python3 -c "
import json, sys
print(json.dumps({'decision': 'block', 'reason': sys.argv[1]}, ensure_ascii=False))
" "$1"
  exit 0
}

HOWTO="python3 Tools/error_report/err_report.py gate --session $UUID 를 실행해 PASS 를 받은 뒤 ofinish 하라. NEW 가 남으면 처리(done/ignore)하거나 이월 사유를 --baseline 에 기록하라."

[ -f "$EVID" ] || block "❌ [errgate] 장애 리포트를 처리한 세션인데 접수 게이트 증거(evidence/err_gate.json)가 없다. $HOWTO"

VERDICT=$(python3 - "$EVID" "$LAST_WRITE" "$MAX_AGE_SEC" <<'PY' 2>/dev/null
import sys, json, time, datetime
path, last_write, max_age = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
try:
    d = json.load(open(path, encoding="utf-8"))
    ts = datetime.datetime.strptime(d.get("checked_at", ""), "%Y-%m-%d %H:%M:%S").timestamp()
except Exception:
    print("BAD 증거 파일을 해석할 수 없다"); sys.exit(0)
if d.get("gate") != "PASS":
    print("BAD 게이트 결과가 FAIL 이다(NEW 잔존)")
elif {"dev", "prod"} - {e.get("env") for e in d.get("envs", [])}:
    print("BAD dev·prod 둘 다 점검되지 않았다")
elif time.time() - ts > max_age:
    print("BAD 증거가 6시간을 넘었다")
elif ts < last_write:
    print("BAD 마지막 장애 리포트 쓰기보다 게이트 실행이 이전이다(쓰기 후 재실행 필요)")
else:
    print("OK")
PY
)
case "$VERDICT" in
  OK*) exit 0 ;;
  BAD*) block "❌ [errgate] ${VERDICT#BAD } $HOWTO" ;;
  *) exit 0 ;;
esac
