#!/bin/bash
# 주간 한도 게이트 래퍼 — 잔여가 넉넉하면 python 없이 통과하고, 그 밖에는 메인·팀원을 가려 코어(lib/weekly_limit_gate.py)를 부르는 PreToolUse hook
#
# 등록: PreToolUse matcher "*" — time_budget.sh 7.5 open <이 파일>, timeout 10.
# 모든 실패는 무출력 exit 0(fail-open)이다. stdout 에는 코어의 deny JSON 만 나간다.
# 이름에 'guard' 를 넣지 않는다. time_budget 의 고부하 보류 대상이 되면 예산 초과 때 통과 대신 보류가 되기 때문이다.

trap 'exit 0' ERR

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

INPUT=$(timeout 3 cat 2>/dev/null) || exit 0
[[ -n "$INPUT" ]] || exit 0

# 평상시 경로 — 잔여가 바깥 임계값보다 크면 여기서 끝난다. 숫자가 아니거나 jq 가 실패하면 코어가 판정한다.
CACHE="$CFG/.usage_cache.json"
[[ -f "$CACHE" ]] || exit 0
if jq -e --arg t "${WLG_THRESHOLDS:-30}" \
  '(.rate_limits.seven_day.used_percentage) as $u | ($u | type) == "number" and (100 - $u) > ($t | split(",") | map(tonumber) | max)' \
  "$CACHE" >/dev/null 2>&1; then
  exit 0
fi

SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null | tr -d '[:space:]')
# jq 가 실패하면 python 으로 입력 최상위 값만 읽는다. 문자열 탐색은 tool_input 안의 같은 이름 키를 집어 다른 세션 폴더에 쓰게 되므로 쓰지 않는다.
if [[ -z "$SID" ]]; then
  SID=$(printf '%s' "$INPUT" | timeout 3 python3 -I -B -c 'import json,sys; d=json.load(sys.stdin); v=d.get("session_id"); print(v if isinstance(v,str) else "")' 2>/dev/null | tr -d '[:space:]')
fi
[[ "$SID" =~ ^[0-9a-f-]{36}$ ]] || exit 0

# 팀원 판별 — 1순위는 부모 체인의 --agent-id·--parent-session-id 와 리드 team_name 일치까지 본다.
# 2순위는 리드 team_name 없이 argv·리드 state·팀 config 로 가린다(IDLE 위임 뒤 team_name 이 지워진 팀원).
ROLE=""; LEAD=""
CA_OK=0
source "$HOOKS_DIR/lib/chain_agent.sh" 2>/dev/null && CA_OK=1
if (( CA_OK )) && chain_agent_resolve 2>/dev/null; then
  ROLE=teammate; LEAD="$CA_LEAD"
elif (( CA_OK )) && chain_agent_resolve_argv "$SID" 2>/dev/null; then
  ROLE=teammate; LEAD="$CA_LEAD"
  # 2순위 판별 흔적 — 리드 세션 weekly_gate 에 1회만 남긴다
  _GATE="$CA_SDIR/weekly_gate"
  if [[ ! -e "$_GATE/role_argv.log" ]] && mkdir -p "$_GATE" 2>/dev/null; then
    printf '%(%Y-%m-%dT%H:%M:%S%z)T\tresolve_argv\t%s\n' -1 "$CA_NAME" >> "$_GATE/role_argv.log" 2>/dev/null
  fi
elif [[ -f "$CFG/session-env/$SID/state" ]]; then
  ROLE=main; LEAD="$SID"
else
  # 판별 실패 + state 없음 = 메인도 팀원도 아니다. 판정할 수 없으므로 통과하고 사후 확인용 흔적만 남긴다.
  _GATE="$CFG/session-env/$SID/weekly_gate"
  if [[ ! -e "$_GATE/role_pass.log" ]] && mkdir -p "$_GATE" 2>/dev/null; then
    printf '%(%Y-%m-%dT%H:%M:%S%z)T\tresolve_fail_no_state\n' -1 >> "$_GATE/role_pass.log" 2>/dev/null
  fi
  exit 0
fi

printf '%s' "$INPUT" | WLG_ROLE="$ROLE" WLG_LEAD="$LEAD" timeout 7 python3 -I -B "$HOOKS_DIR/lib/weekly_limit_gate.py" 2>/dev/null
exit 0
