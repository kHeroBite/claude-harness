#!/usr/bin/env bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# Agent() 호출의 4대 필수 파라미터(subagent_type/name/team_name/mode) 누락을 물리 차단한다.
#
# ★왜 만들었나 (2026-09-06 사이클82 실사고)★
#   메인이 Agent(subagent_type=, model=, description=, prompt=) 만으로 팀에이전트를 만들려 했다.
#   team_name/name 이 없어 ★pane 도 팀 디렉토리도 생성되지 않았고★, 두 에이전트가
#   평범한 백그라운드 서브에이전트로 돌았다(tmux list-panes 실측: %0 메인 하나뿐).
#   ok/SKILL.md 는 "이 4개 없으면 hook 차단"이라 적어 두었으나 ★그 hook 이 등록돼 있지 않았다★.
#   기존 full_task_team_guard.sh 는 /proc/S/cmdline 참조 버그로 rc=0 을 반환해 무력했다(실측).
#   ⇒ 문서 규칙만 있고 강제가 없으면 규칙은 지켜지지 않는다. 여기서 물리적으로 막는다.
#
# 판정 대상: tool_name == "Agent" 인 PreToolUse 만. 그 외는 무조건 통과(rc=0).
#
# ★[2026-09-13 사이클128] 판정축을 name 단독으로 이동 — team_name 강제 해제★
#   위 헤더의 "team_name 없으면 팀 디렉토리가 안 만들어진다" 는 ★실측으로 반증됐다.★
#   oplan-128 은 name 만 받고 team_name 없이 spawn 됐으나 전부 정상이었다:
#     --team-name session-95485b81  ← 런타임이 자동 부여(부모 세션에서 파생)
#     config.json isActive=True / tmux pane %23 생성 / --parent-session-id = 파이프라인 UUID 일치
#   현 스키마도 team_name 을 "Deprecated; ignored" 로 명시한다.
#   ⇒ 사이클82 사고의 진짜 원인은 team_name 부재가 아니라 ★name 부재★ 였다.
#     둘을 묶어 요구한 탓에 어느 쪽이 실효였는지 구분되지 않은 채 굳었고,
#     그 결과 이번 사이클에서 ★정당한 oplan spawn 을 3회 차단★ 했다(실측).
#   ⇒ 이 수정은 느슨해지는 것이 아니라 ★판정축을 실효 파라미터로 옮겨 정확해지는 것★ 이다.
#     name 강제는 오히려 복원·강화된다(아래 참조).
set -uo pipefail

INPUT="$(cat 2>/dev/null || true)"
[ -z "$INPUT" ] && exit 0

_jq() { printf '%s' "$INPUT" | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
cur=d
for k in '$1'.split('.'):
    if isinstance(cur,dict): cur=cur.get(k)
    else: cur=None
print(cur if cur is not None else '')
" 2>/dev/null; }

TOOL="$(_jq tool_name)"
[ "$TOOL" != "Agent" ] && exit 0

SUBTYPE="$(_jq tool_input.subagent_type)"
NAME="$(_jq tool_input.name)"
TEAM="$(_jq tool_input.team_name)"

# fork 는 부모 컨텍스트를 잇는 특수 유형이라 팀/이름 규칙 대상이 아니다.
[ "$SUBTYPE" = "fork" ] && exit 0

# ── ★2026-09-15 사이클133 — 판정 정의역을 "팀에이전트 spawn"으로 한정★ ──────
# 사고: 새 세션 첫 프롬프트에서 Agent 호출이 100% 봉쇄됐다(실측 로그 4건).
#   원인은 이 hook 과 team_agent_env_guard 의 ★판정축 상충★ 이다.
#     name 없음 → 이 hook 이 rc=2 / name 있음 → env_guard 가 PIPELINE_UUID 요구로 rc=2
#   두 hook 이 같은 변수(name)를 ★정반대 방향★으로 써서 통과 집합이 공집합이 됐다.
#   ⇒ 확률적 실패가 아니라 ★논리적 데드락★ 이었다.
#
# 조치: 판정축을 결과 변수(name 유무)에서 ★의도 변수★ 로 옮긴다.
#   팀에이전트 spawn 은 예외 없이 prompt 에 PIPELINE_UUID=<36자> 를 싣는다(L-411 강제).
#   따라서 그 선언 유무가 "팀 멤버로 등록될 spawn 인가"를 직접 알려준다.
#
# ★사이클82 방지력은 100% 보존된다★:
#   사이클82 는 "팀에이전트로 만들려던 spawn 에 name 이 없어 pane 이 안 생긴" 사고다.
#   그 입력은 PIPELINE_UUID 를 싣고 있으므로 IS_TEAM_SPAWN=1 로 판정되어
#   ★아래 name 강제 분기에 그대로 남는다.★ 강제 코드는 한 줄도 삭제하지 않았다.
#   면제되는 것은 PIPELINE_UUID 도 name 도 없는 호출 — 정의상 팀 spawn 이 아니다.
#
# fail-safe: prompt 추출 실패 시 IS_TEAM_SPAWN=0 (통과 방향).
#   이 hook 의 오차단은 ★파이프라인 전면 봉쇄★(사이클90 실사고)를 낳는 반면
#   오통과는 pane 미생성이라는 관측 가능한 열화에 그친다. 피해가 비대칭이다.
#   "모르면 통과, 알면 강제" — 판정 성공 시에는 아래에서 엄격히 막는다.
PROMPT="$(_jq tool_input.prompt)"
IS_TEAM_SPAWN=0
if printf '%s' "$PROMPT" \
   | grep -qE 'PIPELINE_UUID=[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' 2>/dev/null; then
  IS_TEAM_SPAWN=1
fi

# 팀 spawn 이 아니면 이 hook 의 관심 대상이 아니다 — 통과.
# (조회용 서브에이전트: claude-code-guide / Explore / general-purpose 등)
[ "$IS_TEAM_SPAWN" -eq 0 ] && exit 0

# ── ★2026-09-07 사이클90 정합화 — name/team_name 스키마 소멸 대응★ ──────────
# 배경: Claude Code 2.1.263 의 Agent 도구 스키마는 additionalProperties:false 이며
#   허용 파라미터가 description/prompt/subagent_type/model/isolation 5개뿐이다.
#   ★name·team_name·mode 파라미터가 스키마에서 제거됐다.★ (ToolSearch 실측)
#   따라서 이 둘을 요구하면 ★영구 불충족 조건★ 이 되어 fork 를 제외한 모든
#   Agent spawn 이 봉쇄된다(2026-09-07 실사고: oplan spawn 전면 차단 → 파이프라인 진입 불가).
#
# 선례: full_task_team_guard.sh 가 구 L-342 에서 똑같은 상황을 겪고 같은 결론을 남겼다 —
#   "team_name 파일 선행 요구는 영구 불충족 조건이 되어 모든 팀에이전트 spawn 을 봉쇄함."
#   또한 PostToolUse_agent_bind_check.sh 헤더(T4, 2026-09-06)는 이미 실측으로 적어 두었다 —
#   "★team_name 파라미터는 런타임이 무시(Deprecated)하며 실제 팀은 항상 런타임 기준으로 정상 동작한다.★"
#   ⇒ 즉 이 두 파라미터는 이미 런타임 무시 대상이었고, 이제 스키마에서도 사라졌다.
#
# ── ★2026-09-13 사이클128 T-D1~D4 — 판정축을 name 단독으로 이동★ ──────────────
# 위 사이클90 조치는 "name·team_name 둘 다 부재 = 신 빌드" 라는 ★복합 판정★ 을 썼는데,
# 이것이 두 개의 상반된 결함을 동시에 만들었다(둘 다 실측 재현했다).
#
#   결함1 — ★정당한 호출을 차단★ (이번 사이클 3회 발생)
#     subagent_type + name 만 넘기면(= 현 스키마의 ★올바른★ 형태) NAME 이 채워져
#     degraded 조건 `-z NAME && -z TEAM` 이 ★거짓★ → 구 빌드 분기로 떨어짐
#     → team_name 누락으로 rc=2. ★정확히 올바른 호출이 막히는 구조였다.★
#
#   결함2 — ★사이클82 그 자체를 통과시킴★ (더 위험한 쪽. 실측 rc=0)
#     name 없이 subagent_type 만 넘기면 degraded 조건이 ★참★ → observe-only 분기 →
#     subagent_type 만 확인하고 ★rc=0 통과★.
#     즉 이 hook 이 막으려고 태어난 바로 그 입력(name 부재 → pane 미생성)이
#     사이클90 이후 ★아무 저항 없이 통과하고 있었다.★
#
# 조치: team_name 을 판정에서 완전히 제거하고 ★name 을 단독 강제축★ 으로 삼는다.
#   - name        → ★강제(rc=2)★. pane 생성의 실효 조건이며 사이클82 방지의 핵심이다.
#   - subagent_type → 강제 유지. 현 스키마에 실존한다.
#   - team_name / mode → 런타임이 무시하므로 ★요구하지 않는다.★ 단 실려 오면 그대로 통과(구 빌드 회귀 0).
#
# ⚠️ 여기서 막지 않으면 아무도 막지 않는다:
#   PostToolUse_agent_bind_check.sh 는 MISMATCH 를 ★로그만 남기고 148행에서 exit 0★ 하는
#   ★fail-open 탐지기★ 다(실측). "bind_check 가 있으니 안심"은 성립하지 않는다.
MISSING=""
[ -z "$SUBTYPE" ] && MISSING="${MISSING}subagent_type "
[ -z "$NAME" ]    && MISSING="${MISSING}name "

[ -z "$MISSING" ] && exit 0

# 관측: 무엇이 왜 막혔는지 남긴다 (사이클90 의 degraded 로그를 대체)
_LOGD="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/logs"
mkdir -p "$_LOGD" 2>/dev/null
printf '%s F-AGENT-1 blocked: missing=[%s] subagent_type=%s name=%s team_name=%s\n' \
  "$(date -Is 2>/dev/null)" "${MISSING% }" "${SUBTYPE:-<none>}" "${NAME:-<none>}" "${TEAM:-<none>}" \
  >> "$_LOGD/agent_param_schema.log" 2>/dev/null

cat >&2 <<EOF
⛔ [F-AGENT-1] Agent() 필수 파라미터 누락: ${MISSING}

  name           없으면 → tmux pane 이 생성되지 않고 팀 멤버로 등록되지 않는다.
                          평범한 백그라운드 서브에이전트로 돌아간다(2026-09-06 사이클82 실사고).
  subagent_type  없으면 → 에이전트 유형이 결정되지 않는다. 현 스키마의 필수 파라미터다.

올바른 형태 (현 스키마 기준):
  Agent(subagent_type="general-purpose",
        name="odev-1",
        prompt="PIPELINE_UUID=<36자 UUID>\\nCLAUDE_CONFIG_DIR=<절대경로>\\n...")

★team_name 은 넘기지 않아도 된다★ — 런타임이 부모 세션에서 팀을 파생해 자동 부여한다
(사이클128 실측: name 만으로 pane·팀 등록·부모 바인딩 전부 정상). 넘겨도 무해하다.

의도적으로 팀 밖 경량 위임을 하려는 것이면 subagent_type="fork" 를 쓰거나,
prompt 에서 PIPELINE_UUID 선언을 빼면 팀 밖 경량 서브에이전트로 간주되어
이 검사를 받지 않는다(단 팀 파이프라인에는 참여할 수 없다).
EOF
exit 2
