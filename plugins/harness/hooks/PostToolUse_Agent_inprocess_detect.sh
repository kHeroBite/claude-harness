#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# Agent() 가 ★팀에이전트가 아니라 in-process 서브에이전트로 강등★ 되었는지 실측 탐지하는 hook
# PostToolUse:Agent — ★차단하지 않는다. 사실을 알린다.★ (F-AGENT-2)
#
# ── 왜 필요한가 (2026-09-06 사이클87 실측) ──────────────────────────────────
# 세션 144be8b3 은 spawn 142회 중 ★141회가 타 세션 팀에 바인딩★ 되었고,
# 최근 3회는 아예 팀 없이 in-process 로 실행됐다(프로세스 0건 / teams 0개 / agents 0건).
# 그런데 Agent 도구는 매번 "성공" 을 반환했다.
#
# ⇒ 그 결과가 L-969 교착이다:
#    메인은 "팀에이전트에 위임했다" 고 믿고 DEV 로 전이했는데, 실제로는 팀에이전트가
#    존재하지 않아 아무도 일을 하지 않았다. 그리고 write_guard 는 DEV 상태의 메인을
#    ★설계대로 정확히★ 차단했다. hook 은 옳았고, 전제(팀에이전트 존재)가 거짓이었다.
#    ⇒ 메인은 "hook 이 과하다" 고 오진하고 IDLE 로 내려가 직접 작업하는 우회를 택했다.
#
# ── 기존 3중 게이트가 전부 놓치는 이유 (그래서 이 hook 이 따로 필요하다) ────
#   full_task_team_guard.sh          : spawn ★실패★ 경로만 감시 → 성공이므로 통과
#   PostToolUse_agent_bind_check.sh  : 응답의 agent_id 로 팀명 대조 → in-process 는
#                                      agent_id 자체가 없어 ★조용히 통과★ (자기 문서 한계 B)
#   PreToolUse_Agent_team_param_guard: 파라미터 4개 존재만 검사 → 넣어도 런타임이
#                                      무시하면 그만이라 ★파라미터로는 판별 불가★
#   ⇒ "실패도 아니고, agent_id 도 없고, 파라미터는 정상" 인 사각지대다.
#
# ── 판별 근거는 파일이 아니라 ★OS 프로세스★ 다 ────────────────────────────
# 팀에이전트는 반드시 별도 프로세스로 뜨며 --parent-session-id <내 UUID> 를 갖는다.
# in-process 서브에이전트는 프로세스가 아예 없다. 이것은 런타임이 위조할 수 없는 사실이다.
# (파일/응답 스키마는 버전마다 바뀌지만 프로세스 유무는 바뀌지 않는다.)
#
# ── 왜 block 이 아닌가 ─────────────────────────────────────────────────────
# in-process 서브에이전트도 ★일 자체는 정상 수행한다.★ 실제로 이번 진단 에이전트도
# 정확한 결과를 돌려줬다. 차단하면 멀쩡한 작업까지 막힌다.
# 진짜 문제는 "팀에이전트인 줄 알고 DEV 로 전이하는 것" 이므로,
# ★메인이 그 사실을 알게 하는 것★ 이 정확한 처방이다. 판단은 메인이 한다.
#
# 비상 스위치: touch $HOME/.claude/hooks/DISABLE_INPROCESS_DETECT
# fail-open: 전 경로 exit 0. 어떤 경우에도 작업을 막지 않는다.

set -u

_HOOK_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || _HOOK_DIR="$HOME/.claude/hooks"
[ -r "${_HOOK_DIR}/lib/session_id.sh" ] || _HOOK_DIR="$HOME/.claude/hooks"

for _sw in "${_HOOK_DIR}/DISABLE_INPROCESS_DETECT" "$HOME/.claude/hooks/DISABLE_INPROCESS_DETECT"; do
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

# ── 요청에 team_name 이 있었는지 확인 ─────────────────────────────────────
# team_name 없이 부른 서브에이전트는 애초에 팀에이전트를 의도하지 않았으므로 대상 아님.
_REQ_TEAM=$(echo "$INPUT" | jq -r '.tool_input.team_name // empty' 2>/dev/null)
[ -z "$_REQ_TEAM" ] && exit 0

_NAME=$(echo "$INPUT" | jq -r '.tool_input.name // "unnamed"' 2>/dev/null)

# ── ★핵심 판정★ 내 UUID 소유 에이전트 프로세스가 실제로 존재하는가 ───────
# 팀에이전트라면 --parent-session-id <내 UUID> 를 가진 프로세스가 반드시 있다.
# 주의: spawn 직후 프로세스가 뜨기까지 약간의 지연이 있을 수 있어 짧게 재시도한다.
_PROC_CNT=0
for _try in 1 2 3; do
  _PROC_CNT=$(ps -eo args 2>/dev/null | grep -- "--parent-session-id ${UUID}" | grep -vc "grep")
  [ "${_PROC_CNT:-0}" -gt 0 ] && break
  sleep 1
done

_LOGDIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/logs"
mkdir -p "$_LOGDIR" 2>/dev/null
_LOG="${_LOGDIR}/agent_inprocess_detect.log"
_TS=$(date -Iseconds 2>/dev/null || date)

if [ "${_PROC_CNT:-0}" -gt 0 ]; then
  # 정상 — 팀에이전트 프로세스 실존. SCAN 라인만 남겨 "관측이 돌았음" 을 증명한다.
  echo "${_TS} OK name=${_NAME} team=${_REQ_TEAM} procs=${_PROC_CNT}" >> "$_LOG" 2>/dev/null
  exit 0
fi

# ── 강등 감지 ─────────────────────────────────────────────────────────────
echo "${_TS} DEMOTED name=${_NAME} team=${_REQ_TEAM} procs=0 uuid=${UUID}" >> "$_LOG" 2>/dev/null

# 메인에게 사실을 전달한다. 차단하지 않으므로 decision 필드를 쓰지 않고
# systemMessage 로만 알린다(작업은 그대로 진행된다).
cat <<EOF
{"systemMessage":"⚠️ [F-AGENT-2] Agent '${_NAME}' 이 팀에이전트가 아니라 in-process 서브에이전트로 실행되었습니다 (team_name=${_REQ_TEAM} 요청했으나 --parent-session-id ${UUID} 프로세스 0건). 이 세션은 팀/pane 이 생성되지 않는 상태입니다. ⇒ ★state 를 DEV/TEST 로 전이하지 마십시오★ — 팀에이전트가 없는데 DEV 로 가면 write_guard 가 메인을 정확히 차단하여 교착됩니다(L-969). 작업 자체는 이 서브에이전트가 정상 수행하므로 결과는 신뢰할 수 있습니다. 팀/pane 이 꼭 필요하면 세션을 --continue 없이 새로 시작하십시오."}
EOF
exit 0
