#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# Agent spawn ★성공★ 응답의 팀 바인딩이 자기 세션과 일치하는지 관측하는 hook
# PostToolUse:Agent — ★차단하지 않는다. 기록·경고만 한다.★
#
# ── 배경 (사이클41 실측 — 문서가 예측하지 못한 변종) ──────────────────────
# ok/SKILL.md:514-529 "런타임_세션_교착_감지"(L-NEW2)는 아래를 전제한다:
#   "Agent spawn 이 ★실패★ 한다 — Internal error: team file for session-<XXX> not found"
# 그래서 감지 장치(full_task_team_guard.sh:239-242)도 ★실패 경로에만★ 붙어 있다.
#
# 그런데 2026-08-26 실측에서는 ★spawn 이 성공했다.★
#   요청 team_name : session-144be8b3   (내 UUID 앞 8자 — ok/SKILL.md 정본)
#   실제 agent_id  : odev-c41-2@★session-e1c14841★   ← 옛 세션 팀
#   teams/session-e1c14841/config.json leadSessionId = e1c14841-…  ← 내 UUID 아님
#   session_bind_mismatch.log : ★미생성★  ← 감지 장치가 작동하지 않았다
#
# ⇒ 🔴 ★성공이 실패보다 위험하다.★ 실패하면 최소한 눈에 보이고 문서화된 대응
#    절차(재시도 2회 → /clear)가 있다. 조용히 옛 팀에 편입되면 아무도 모른다.
#
# ⇒ 그리고 그 결과가 파생 오판정을 낳았다:
#    team-cleanup.sh:307-324 가 "PID=… 타세션(144be8b3…) 에이전트 — L-328 skip"
#    을 출력했는데, 스크립트 관점에서는 ★정확한 판정★ 이었다 —
#    실제로 그 에이전트의 --parent-session-id 가 내 UUID 와 달랐기 때문이다.
#    ⇒ team-cleanup 의 결함이 아니라 본 바인딩 교착의 증상이다.
#
# ── 왜 block 이 아니라 관측인가 ───────────────────────────────────────────
# [T4 갱신 — 2026-09-06] team_name 파라미터는 런타임이 무시(Deprecated)하며 실제
# 팀은 항상 런타임 기준(_ACTUAL_TEAM)으로 정상 동작한다. 아래 self-heal 로 team_name
# 파일을 그 값으로 자동 보정하므로 /clear·재시작은 더 이상 필요 조건이 아니다.
# 그런 상태에서 spawn 을 차단하면 ★정상 작업까지 전면 중단★ 되고 얻는 것이 없다.
# 실제로 이번 사고에서도 spawn 은 성공했고 작업 자체는 정상 수행됐다.
# ⇒ 따라서 ★막지 않고 알린다.★ 판단은 사용자/메인이 한다.
# ⇒ CLAUDE.md 재발방지 정책 관점에서 이것은 "Hook 1순위 미적용"이 아니다 —
#   hook 으로 구현하되 ★차단이 아닌 관측★ 으로 설계한 것이다.
#
# ── ★이 게이트가 못 잡는 것★ (사이클40 A2 교훈) ──────────────────────────
#  A. ★team_name 파일만 보정한다★ — Claude Code 런타임 내부 상태 자체는 건드리지 않는다.
#     (spawn·작업은 이미 정상 동작 중이므로 /clear·재시작은 불필요하다.)
#  B. ★agent_id 를 응답에서 못 읽는 경우★ — 조용히 통과한다.
#     PostToolUse 응답 스키마는 버전 의존적이라 필드명이 바뀌면 관측이 끊긴다.
#     ⇒ 그래서 "탐지 0건"을 "정상"의 근거로 쓰면 안 된다. 로그에 SCAN 라인을
#       남겨 ★관측이 실제로 돌았는지★ 를 사후에 구분할 수 있게 했다.
#       (도구 부재가 상태 이상으로 위장하는 것을 막는다 — oinfra_mars ss 부재 교훈)
#  C. ★팀명이 없는 spawn★ — 대상 아님. 팀 없이 도는 서브에이전트는 무관하다.
#  D. ★UUID 앞 8자 충돌★ — 서로 다른 UUID 의 앞 8자가 같으면 오탐을 놓친다.
#     확률이 낮고, 팀명 규칙 자체가 앞 8자라 더 정밀하게 볼 근거가 없다.
#  E. ★spawn 실패 케이스★ — 다루지 않는다. full_task_team_guard.sh 담당이며
#     본 hook 은 그것이 놓친 ★성공 케이스★ 를 메운다(역할 분담).
#
# 비상 스위치: touch $HOME/.claude/hooks/DISABLE_BIND_CHECK
# fail-open: 전 경로 exit 0. 이 hook 은 어떤 경우에도 작업을 막지 않는다.

set -u

_HOOK_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || _HOOK_DIR="$HOME/.claude/hooks"
[ -r "${_HOOK_DIR}/lib/session_id.sh" ] || _HOOK_DIR="$HOME/.claude/hooks"

for _sw in "${_HOOK_DIR}/DISABLE_BIND_CHECK" "$HOME/.claude/hooks/DISABLE_BIND_CHECK"; do
  [ -f "$_sw" ] && exit 0
done

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(timeout 5 cat 2>/dev/null) || exit 0
[ -z "$INPUT" ] && exit 0

# ── UUID 결정 ─────────────────────────────────────────────────────────────
# shellcheck source=/dev/null
. "${_HOOK_DIR}/lib/session_id.sh" 2>/dev/null || exit 0
resolve_uuid "$INPUT" 2>/dev/null || exit 0
[ -z "${UUID:-}" ] && exit 0

# 자기 세션 기준 기대 팀명 (ok/SKILL.md 정본: session-{UUID 앞 8자})
_SELF8=$(echo "$UUID" | cut -c1-8)
_EXPECT="session-${_SELF8}"

# ── 응답에서 실제 agent_id / 팀명 추출 ────────────────────────────────────
# 스키마 변동에 대비해 여러 후보 필드를 훑는다(한계 B).
_AGENT_ID=$(echo "$INPUT" | jq -r '
  [ .tool_response.agent_id?, .tool_response.agentId?,
    .tool_response.name?, .tool_result.agent_id?,
    .response.agent_id? ]
  | map(select(type == "string" and . != "")) | .[0] // empty
' 2>/dev/null)

# 문자열 어디든 "@session-XXXXXXXX" 형태가 있으면 그걸 쓴다 (최후 폴백)
if [ -z "$_AGENT_ID" ]; then
  _AGENT_ID=$(echo "$INPUT" | grep -oE '@session-[0-9a-f]{8}' 2>/dev/null | head -1)
fi
[ -z "$_AGENT_ID" ] && exit 0                     # 한계 B — 관측 불가, 조용히 통과

# agent_id 에서 팀명 부분만 뽑는다: "odev-c41-2@session-e1c14841" → "session-e1c14841"
case "$_AGENT_ID" in
  *@*) _ACTUAL_TEAM="${_AGENT_ID##*@}" ;;
  *)   exit 0 ;;                                  # 한계 C — 팀명 없음, 대상 아님
esac
[ -z "$_ACTUAL_TEAM" ] && exit 0

# ── 로그 (양쪽 base — 한쪽만 남기면 이 hook 이 갈림의 원인이 된다) ─────────
_log() {
  _ts=$(date '+%Y-%m-%dT%H:%M:%S%z')
  for _b in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" "$HOME/.claude"; do
    _d="${_b}/session-env/${UUID}"
    [ -d "$_d" ] || continue
    mkdir -p "${_d}/logs" 2>/dev/null
    echo "${_ts} $*" >> "${_d}/logs/session_bind_mismatch.log" 2>/dev/null || true
  done
}

# ★SCAN 라인을 항상 남긴다★ — "탐지 0건" 과 "관측이 안 돌았음" 을 구분하기 위해서다.
# 이것이 없으면 한계 B(스키마 변경으로 관측 끊김)가 "정상" 으로 위장한다.
_log "SCAN expect=${_EXPECT} actual=${_ACTUAL_TEAM} agent_id=${_AGENT_ID}"

[ "$_ACTUAL_TEAM" = "$_EXPECT" ] && exit 0        # 정상 — 조용히 통과

# ── 불일치 — 경고 (차단하지 않는다) ───────────────────────────────────────
_log "MISMATCH expect=${_EXPECT} actual=${_ACTUAL_TEAM} agent_id=${_AGENT_ID} uuid=${UUID}"

# --- [T4 — RC3-b self-heal] 자기 UUID의 team_name 파일을 런타임 실제값으로 보정 ---
# 배경: team_name 파라미터는 런타임이 무시(Deprecated)하므로 실제 팀은 _ACTUAL_TEAM 이다.
# 자기 UUID 경로에만 기록한다 (세션 격리 §(a) 준수, 타 세션 경로 쓰기 금지).
for _b in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" "$HOME/.claude"; do
  _d="${_b}/session-env/${UUID}"
  [ -d "$_d" ] || continue
  mkdir -p "$_d" 2>/dev/null
  echo "$_ACTUAL_TEAM" > "${_d}/team_name" 2>/dev/null || true
done
. "${_HOOK_DIR}/lib/session_mirror.sh" 2>/dev/null || true
if command -v _mirror_file >/dev/null 2>&1; then
  _mirror_file "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/team_name" 2>/dev/null || true
fi

cat <<EOF
⚠️  [팀명 자동 보정] Agent spawn·작업은 정상 동작 중입니다.

  기대 팀명 : ${_EXPECT}        (내 세션 ${_SELF8}… 기준 — ok/SKILL.md 정본)
  실제 팀명 : ${_ACTUAL_TEAM}
  agent_id  : ${_AGENT_ID}

  Agent 도구의 team_name 파라미터는 런타임이 무시(Deprecated)하며, 실제 팀은
  런타임 기준(${_ACTUAL_TEAM})으로 동작합니다. team_name 파일을 런타임 기준으로
  자동 보정했습니다. 추가 조치는 불필요합니다.

  참고: spawn 실패 케이스는 full_task_team_guard.sh 가 별도로 담당합니다(역할 분담).

  비상 시: touch ${_HOOK_DIR}/DISABLE_BIND_CHECK
EOF

exit 0
