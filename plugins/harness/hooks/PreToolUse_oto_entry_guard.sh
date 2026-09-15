#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# oto(auto=ON) 세션의 파이프라인 ★진입 시점★ 에 완주 전제조건을 검사하는 hook
# PreToolUse:mcp__oio__session_state — key=state, value=PLAN|DEV 전이만 대상
#
# ── 왜 진입 시점인가 (설계 정당성의 전부) ─────────────────────────────────
# 기존 PreToolUse_oto_completion_guard.sh(F-OTO-1~8)는 ★종료 시점★(value=IDLE)에
# 검사한다. 사이클40 실측이 그 한계를 정확히 보여줬다:
#
#   21:23:55  F-OTO-7b BLOCK — "RALPH 게이트가 죽어 있습니다"
#   ⇒ 그 시점에 이미 ★5시간치 작업이 끝나 있었고★,
#      ★검증 루프는 한 번도 돌지 않은 상태★ 였다.
#      즉 게이트는 정확히 작동했으나 ★알려준 시점이 너무 늦었다★.
#
#   F-OTO-0(본 hook)이면 같은 결함을 ★작업 시작 전 30초★ 에 잡는다.
#   ⇒ 5시간 vs 30초. 이 대비가 본 hook 이 존재하는 이유 전부다.
#
# 검사 2종:
#   F-OTO-0a  경로 단일화 — goal.json·oralph_active·status·auto 4파일이
#             두 base 에 갈려 있지 않은지 (oto/SKILL.md:66-73 문서 규칙의 ★물리화★)
#   F-OTO-0b  RALPH 게이트 — status 에 RALPH 토큰 또는 oralph_active 파일 존재
#             (F-OTO-7b 가 종료 때 잡던 것을 진입 때 잡는다)
#
# ★oto/SKILL.md:66-73 은 왜 실행되지 않았는가★:
#   그것이 YAML 산문 안의 문서 규칙이기 때문이다 — 실행 주체도, 검증 시점
#   게이트도 없었다. CLAUDE.md 가 말하는 "LLM 의지 의존" 의 교과서적 사례이며,
#   본 hook 은 그 규칙을 물리 게이트로 옮긴 것이다.
#
# ── 🔴 이 hook 자신의 경로 결정 로직 (★자기 함정 방지★ — 가장 중요) ──────
# F-OTO-7b 는 "auto 가 있는 쪽을 정본으로" 라는 폴백(:63-68) 때문에 사고를 냈다.
# auto 가 ★양쪽에★ 있는 실제 환경에서 그 규칙이 ★goal.json 이 없는 쪽★ 을
# 정본으로 골랐고, 로그에 path_fallback=HOME 을 남긴 채 오판했다.
# ⇒ ★규칙이 자기 전제를 배반한 형태다.★
#
# 본 hook 은 그 함정을 구조적으로 피한다:
#   · ★어느 한쪽을 정본으로 고르지 않는다.★ 두 경로를 대등하게 나열해 비교만 한다.
#   · auto 판정은 ★양쪽 OR★ — 한쪽에만 있어도 auto 세션으로 본다.
#     (사고 시점의 실제 상태가 정확히 "한쪽에만 auto" 였다. AND 로 읽으면 놓친다.)
#   · RALPH 판정도 ★양쪽 OR★ — 어느 쪽에서든 게이트가 살아 있으면 통과.
#     (한쪽만 보면 미러 지연 중인 정상 세션을 오차단한다.)
#   · 로그도 ★양쪽에★ 남긴다. 한쪽에만 남기면 이 hook 이 새 갈림의 원인이 된다.
#
# ── ★이 게이트가 못 잡는 것★ (사이클40 A2 교훈) ──────────────────────────
#  A. ★bash_exec 로 state 파일에 직접 쓰는 경우★ — 못 잡는다.
#     matcher 가 mcp__oio__session_state 이므로 도구를 우회한 파일 쓰기는 보이지 않는다.
#     ⇒ 검토 결과: write_guard.sh 로 막는 것은 ★권장하지 않는다.★ state 파일 경로
#       문자열을 bash 명령에서 정규식으로 잡아내는 방식은 오탐(정상 조회 명령까지 차단)이
#      크고, 우회 변형(변수 치환·경로 분할)에 취약해 실효가 낮다. 대신 F-OTO-7b 가
#       종료 시점에 여전히 잡으므로 2중화로 커버된다.
#  B. ★auto 파일을 미리 지우고 진입★ — 못 잡는다(의도).
#     그 순간 이 세션은 oto 가 아니다. 완주 계약 자체가 성립하지 않으므로
#     본 hook 의 대상이 아닌 것이 옳다. F-OTO-1/7b 도 동일 조건으로 동작한다.
#  C. ★PLAN/DEV 를 거치지 않는 진입★ — 못 잡는다.
#     이미 DEV 인 상태에서 재진입하거나 state 전이 없이 작업하면 발동하지 않는다.
#     ⇒ 보완: PreToolUse_session_path_guard.sh(F-PATH-1)가 매 Skill 호출마다 경로를 본다.
#  D. ★진입 이후에 생기는 갈림★ — 못 잡는다. 진입 시점 1회만 본다.
#     ⇒ 근본 해결은 oio 서버 session_mirror(사이클41) 이며, 본 hook 은 탐지 장치다.
#  E. ★goal.json 의 내용 타당성★ — 보지 않는다. 존재·정합만 본다.
#     acceptance 구조 검증은 F-OTO-3~8 의 담당이다(중복 구현하지 않는다).
#
# 비상 스위치: touch $HOME/.claude/hooks/DISABLE_OTO_GUARD   (F-OTO-* 와 공용)
# fail-open: 모든 예외 경로의 기본은 exit 0. 차단은 두 곳에서만 일어난다.

set -u

_HOOK_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || _HOOK_DIR="$HOME/.claude/hooks"
[ -r "${_HOOK_DIR}/lib/session_id.sh" ] || _HOOK_DIR="$HOME/.claude/hooks"

# ── 0. 비상 스위치 (양쪽 위치 검사 — 한쪽만 보면 스위치가 안 먹는다) ───────
for _sw in "${_HOOK_DIR}/DISABLE_OTO_GUARD" "$HOME/.claude/hooks/DISABLE_OTO_GUARD"; do
  [ -f "$_sw" ] && exit 0
done

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(timeout 5 cat 2>/dev/null) || exit 0
[ -z "$INPUT" ] && exit 0

_STOP_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)
[ "$_STOP_ACTIVE" = "true" ] && exit 0

# ── 1. 대상 판별: key=state AND value=PLAN|DEV (진입 전이만) ───────────────
_KEY=$(echo "$INPUT" | jq -r '.tool_input.key // empty' 2>/dev/null) || exit 0
[ "$_KEY" = "state" ] || exit 0

_VALUE=$(echo "$INPUT" | jq -r '.tool_input.value // empty' 2>/dev/null) || exit 0
case "$_VALUE" in
  PLAN|PLAN\ *|DEV|DEV\ *) ;;
  *) exit 0 ;;
esac

# ── 2. UUID 결정 ──────────────────────────────────────────────────────────
# shellcheck source=/dev/null
. "${_HOOK_DIR}/lib/session_id.sh" 2>/dev/null || exit 0
resolve_uuid "$INPUT" 2>/dev/null || exit 0
[ -z "${UUID:-}" ] && exit 0

# 팀에이전트는 대상 아님 (메인의 진입만 검사)
if [ -n "${PIPELINE_UUID:-}" ] && [ "${PIPELINE_UUID:-}" != "${MY_UUID:-$UUID}" ]; then
  exit 0
fi

# ── 3. 두 경로를 ★대칭으로★ 확보 (정본을 고르지 않는다 — 자기 함정 방지) ──
_HOME_DIR="$HOME/.claude/session-env/${UUID}"
_CCD_BASE="${CLAUDE_CONFIG_DIR:-}"
if [ -n "$_CCD_BASE" ]; then
  _CCD_DIR="${_CCD_BASE}/session-env/${UUID}"
else
  _CCD_DIR="$_HOME_DIR"
fi
_SAME_BASE=0
[ "$(readlink -f "$_CCD_DIR" 2>/dev/null)" = "$(readlink -f "$_HOME_DIR" 2>/dev/null)" ] && _SAME_BASE=1

# ── 4. auto=ON 판정 — ★양쪽 OR★ ──────────────────────────────────────────
_is_auto_on() {
  for _d in "$_CCD_DIR" "$_HOME_DIR"; do
    if [ -f "${_d}/auto" ]; then
      _v=$(tr -d '[:space:]' < "${_d}/auto" 2>/dev/null)
      [ "$_v" = "ON" ] && return 0
    fi
  done
  return 1
}
_is_auto_on || exit 0

# ── 5. 로그 (양쪽 기록) ───────────────────────────────────────────────────
_log() {
  _ts=$(date '+%Y-%m-%dT%H:%M:%S%z')
  for _d in "$_CCD_DIR" "$_HOME_DIR"; do
    [ -d "$_d" ] || continue
    mkdir -p "${_d}/logs" 2>/dev/null
    echo "${_ts} $*" >> "${_d}/logs/oto_entry_guard.log" 2>/dev/null || true
  done
}
_log "ENTER uuid=${UUID} value=${_VALUE} same_base=${_SAME_BASE}"

_block() {
  _log "BLOCK $2"
  jq -cn --arg r "$1" '{decision:"block", reason:$r}' 2>/dev/null \
    || echo '{"decision":"block","reason":"oto 진입 전제조건 미충족"}'
  exit 2
}

# ── 6. F-OTO-0a: 경로 단일화 (oto/SKILL.md:66-73 물리화) ───────────────────
# 두 base 가 같은 환경에서는 갈림이 성립하지 않으므로 검사 생략.
if [ "$_SAME_BASE" -eq 0 ]; then
  _hash_of() {
    if [ -f "$1" ]; then md5sum "$1" 2>/dev/null | cut -d' ' -f1; else echo "__ABSENT__"; fi
  }
  _MIS=""
  for _f in goal.json oralph_active status auto; do
    _hc=$(_hash_of "${_CCD_DIR}/${_f}")
    _hh=$(_hash_of "${_HOME_DIR}/${_f}")
    [ "$_hc" != "$_hh" ] && _MIS="${_MIS}${_MIS:+ }${_f}"
  done

  if [ -n "$_MIS" ]; then
    _block "⛔ [F-OTO-0a] auto=ON 세션인데 세션 디렉토리가 두 경로로 갈렸습니다 — 진입을 차단합니다.

불일치 파일: ${_MIS}
  CLAUDE_CONFIG_DIR : ${_CCD_DIR}
  HOME              : ${_HOME_DIR}

왜 지금 막는가:
  이 상태로 진행하면 종료 시점에 F-OTO-7b 가 'auto 가 있는 쪽'을 정본으로 골라
  검사하고, 그쪽에 goal.json/oralph_active 가 없으면 차단합니다.
  ★사이클40 이 정확히 그랬습니다 — 5시간 작업 후에야 완주 실패가 드러났고
    그 시점에 검증 루프는 한 번도 돌지 않은 상태였습니다.★
  지금은 작업 시작 전이므로 손실이 없습니다.

해소:
  1) 정본을 판단하십시오. 원칙상 \$CLAUDE_CONFIG_DIR 쪽입니다.
  2) 부족한 쪽에 맞추십시오. 예:
     mcp__oio__file_copy(src=\"${_CCD_DIR}/goal.json\", dst=\"${_HOME_DIR}/goal.json\")
  3) 다시 진입하십시오.

근본 원인: oio 서버의 file_write/file_edit 가 session-env 를 미러링하지 않던 결함
(사이클41에서 session_mirror.py 로 수정됨 — 서버 재시작 후 신규 쓰기부터 적용).
비상 시: touch ${_HOOK_DIR}/DISABLE_OTO_GUARD" "F-OTO-0a 경로 갈림 [${_MIS}]"
  fi
fi

# ── 7. F-OTO-0b: RALPH 게이트 생존 (양쪽 OR) ──────────────────────────────
_ralph_alive() {
  for _d in "$_CCD_DIR" "$_HOME_DIR"; do
    [ -f "${_d}/oralph_active" ] && return 0
    if [ -f "${_d}/status" ] && grep -qE '(^|\|)RALPH(\||$)' "${_d}/status" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

if ! _ralph_alive; then
  _block "⛔ [F-OTO-0b] auto=ON 인데 RALPH 게이트가 아직 세팅되지 않았습니다 — 진입을 차단합니다.

status 에 RALPH 토큰이 없고, oralph_active 파일도 없습니다(양쪽 base 모두 확인).
⇒ 이대로 진행하면 ofinish Step 8 이 RALPH_ACTIVE=false 로 판정해
   ★검증 루프를 통째로 건너뜁니다.★
⇒ /oto 는 '검증 루프로 완주를 보장'하는 모드인데 그 루프가 아예 돌지 않습니다.
⇒ 종료 시점의 F-OTO-7b 가 같은 것을 잡지만, 그때는 작업이 다 끝난 뒤입니다
   (사이클40 — 5시간 손실). 지금 세팅하면 손실이 0입니다.

원인: oto Phase 1_5 의 oralph_active 세팅 누락 (oto/SKILL.md 'oralph_active_세팅').
해결: 두 가지를 모두 수행하십시오.
  (1) mcp__oio__file_write(path=\"${_CCD_DIR}/oralph_active\",
      content='{\"session_uuid\":\"${UUID}\",\"criteria\":\"...\",\"criteria_detail\":[...],
                \"max_iterations\":5,\"current_iteration\":0}', overwrite=true)
  (2) bash -c 'source \"\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/hooks/lib/state_machine.sh\"; status_add \"${_CCD_DIR}/status\" RALPH'
      ★bash -c 래핑 필수★ — bash_exec 셸은 dash 라 source 가 rc=127 로 죽습니다.

비상 시: touch ${_HOOK_DIR}/DISABLE_OTO_GUARD" "F-OTO-0b RALPH 게이트 부재"
fi

_log "PASS uuid=${UUID} 경로정합+RALPH 생존"
exit 0
