#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# 세션 디렉토리 2중화(경로 갈림)를 파이프라인 진입 시점에 물리 차단하는 hook
# PreToolUse:Skill — auto=ON 세션에서만 발동
#
# ── 배경 (사이클40 실사고, 2026-08-26 실측 재구성) ────────────────────────
# $HOME/.claude/session-env/${UUID}/ 와 $CLAUDE_CONFIG_DIR/session-env/${UUID}/ 가
# 동시 실존하며 내용이 갈렸다. 원인은 쓰기 경로의 비대칭이다:
#   · mcp__oio__session_state  → session_ops.py:_mirror_state_bases() 로 ★양쪽★ 기록
#     (state·status·auto·classification·entry_tier 등 전 키)
#   · mcp__oio__file_write/edit → file_ops.py 에 미러링 코드 ★전무★ → ★한쪽만★
#     (goal.json·oralph_active 가 여기 해당)
#
# 그 결과 21:23:55 시점의 실제 상태 (mtime 실측):
#   auto        : HOME 만 존재 (CCD 쪽은 21:27:09 에야 생김 — 3분 14초 늦음)
#   goal.json   : CCD 만 존재 (15:29:41)
# ⇒ PreToolUse_oto_completion_guard.sh:63-68 의 "auto 있는 쪽을 정본으로" 폴백이
#    HOME 을 골랐고(로그 path_fallback=HOME), 거기엔 goal.json 도 oralph_active 도
#    없어 F-OTO-7b 가 발동했다. 5시간 작업 후 ★종료 시점★ 에야 드러났다.
#
# ⇒ 본 hook 은 그것을 ★진입 시점★ 에 잡는다. F-OTO-7b 는 결과를 잡고,
#    본 hook 은 원인을 잡는다. 둘은 대체 관계가 아니라 보완 관계다.
#
# ── 왜 block 인가 (자동 정합이 아니라) ────────────────────────────────────
# 자동 정합(한쪽을 다른 쪽에 복사)은 세 가지 이유로 채택하지 않았다.
#   1) ★조용히 고치면 다음에 또 생긴다.★ 원인은 oio 서버의 미러링 비대칭이며
#      hook 이 매번 뒤치다꺼리하면 그 결함이 영구히 드러나지 않는다.
#      (CLAUDE.md 재발방지 정책 — "문서화했으니 됐다" 와 같은 형태의 회피)
#   2) ★어느 쪽이 정본인지 hook 이 알 수 없는 경우가 있다.★ state 처럼 양쪽 다
#      정당하게 갱신되는 파일에서 timestamp 만으로 정본을 고르면 최신 쓰기를
#      버릴 수 있다. 잘못된 정합은 갈림보다 위험하다.
#   3) ★정합은 쓰기다.★ hook 이 session-env 에 쓰기 시작하면 세션 격리 §(a) 의
#      경계가 흐려지고, hook 자신이 새로운 갈림의 원인이 될 수 있다.
# ⇒ block + 구체적 해소 절차 안내를 채택한다. 사용자/에이전트가 정본을 판단한다.
#
# ── ★이 게이트가 못 잡는 것★ (사이클40 A2 교훈 — 반드시 읽어라) ──────────
#  A. ★두 경로가 둘 다 없는 경우★ — 통과시킨다.
#     세션 시작 직후(파일 생성 전)가 정상적으로 여기 해당하므로 결함이 아니다.
#     "goal.json 이 아예 없다" 는 F-OTO-1 의 담당이지 본 hook 의 담당이 아니다.
#  B. ★내용이 같은데 mtime 만 다른 경우★ — 통과시킨다(의도).
#     session_state 미러링은 두 번 쓰므로 mtime 이 미세하게 갈리는 것이 정상이다.
#     mtime 으로 판정하면 정상 케이스를 전부 막는다. 그래서 ★내용 해시★ 로만 본다.
#  C. ★Skill 을 거치지 않는 진입★ — 못 잡는다.
#     matcher=Skill 이므로 Skill 없이 메인이 직접 odev 로 진입하는 경로는
#     검사되지 않는다.
#     ⇒ 보완: PreToolUse_oto_completion_guard.sh 가 종료 시점에 여전히 잡는다(2중화).
#  D. ★검사 시점 이후에 발생하는 갈림★ — 못 잡는다.
#     Skill 호출 시점에 정합이어도 그 뒤 file_write 가 한쪽에만 쓰면 갈린다.
#     ★이번 사고가 정확히 이 형태였다★ (goal.json 15:29 → auto 21:27, 약 6시간 시차).
#     ⇒ 근본 해결은 oio 서버 file_ops.py 미러링 이식이며, 본 hook 은 그 전까지의
#       탐지 장치다. 이 한계를 지우려면 서버를 고쳐야 한다.
#     ⇒ 완화: Skill 은 파이프라인 중 여러 번 호출되므로 매 호출이 재검사 지점이 된다.
#  E. ★bash_exec 로 직접 쓰는 경우★ — 쓰기 자체는 못 막는다.
#     단 그 결과로 생긴 갈림은 다음 Skill 호출 때 검출된다(지연 탐지).
#  F. ★hook 자신이 같은 함정에 빠지는가★ ⇐ ★가장 중요★
#     본 hook 은 ★어느 한쪽을 정본으로 고르지 않는다.★ 두 경로를 대등하게 나열해
#     비교만 한다(_CCD_DIR / _HOME_DIR 를 대칭으로 취급). 따라서 oto_completion_guard
#     가 빠진 "폴백이 엉뚱한 쪽을 정본으로 선택" 함정에 구조적으로 빠지지 않는다.
#     auto 판정만은 ★양쪽 OR★ 로 읽는다 — 한쪽에만 있어도 auto 세션으로 본다
#     (이번 사고 시점의 실제 상태가 정확히 그것이었으므로, AND 로 읽으면 놓친다).
#     로그도 양쪽에 남긴다 — 한쪽에만 남기면 이 hook 이 새 갈림의 원인이 된다.
#
# ── 비상 스위치 ───────────────────────────────────────────────────────────
#   touch "${CLAUDE_PLUGIN_ROOT}/hooks/DISABLE_PATH_GUARD"     # 즉시 무력화
#
# fail-open 원칙: 모든 예외 경로의 기본은 exit 0. 차단은 단 한 곳에서만 일어난다.
# set -e 는 쓰지 않는다 — 중간 실패가 곧 차단이 되면 안 된다.

set -u

# hook 자신의 실경로 기준으로 라이브러리를 찾는다.
# $HOME 기준으로 잡으면 HOME 이 다른 환경(테스트 하네스·격리 실행)에서
# lib/session_id.sh 를 못 찾아 조용히 exit 0 이 된다 — 게이트가 no-op 이 되는 형태다.
# (2026-08-26 자체 테스트에서 실제로 이 경로로 통과해버리는 것을 확인하고 수정)
_HOOK_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || _HOOK_DIR="$HOME/.claude/hooks"
[ -r "${_HOOK_DIR}/lib/session_id.sh" ] || _HOOK_DIR="$HOME/.claude/hooks"

# ── 0. 비상 스위치 (최우선) ───────────────────────────────────────────────
# ★두 위치를 모두 본다.★ _HOOK_DIR 은 스크립트 실경로(NTFS 원본)로 해석되는데,
# 사용자는 $HOME/.claude/hooks/ (symlink 경유 경로)에 touch 하는 것이 자연스럽다.
# 한쪽만 보면 "스위치를 만들었는데 안 꺼진다" 가 된다 — 비상 스위치가 비상 시에
# 작동하지 않는 것은 그 자체로 사고다. (2026-08-26 자체 테스트 T9 에서 실제 발생)
for _sw in "${_HOOK_DIR}/DISABLE_PATH_GUARD" "$HOME/.claude/hooks/DISABLE_PATH_GUARD"; do
  [ -f "$_sw" ] && exit 0
done

# ── 1. 의존 도구 부재 시 통과 ─────────────────────────────────────────────
command -v jq >/dev/null 2>&1 || exit 0
command -v md5sum >/dev/null 2>&1 || exit 0

INPUT=$(timeout 5 cat 2>/dev/null) || exit 0
[ -z "$INPUT" ] && exit 0

# 재진입 방지
_STOP_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)
[ "$_STOP_ACTIVE" = "true" ] && exit 0

# ── 2. UUID 결정 ──────────────────────────────────────────────────────────
# shellcheck source=/dev/null
. "${_HOOK_DIR}/lib/session_id.sh" 2>/dev/null || exit 0
resolve_uuid "$INPUT" 2>/dev/null || exit 0
[ -z "${UUID:-}" ] && exit 0

# 팀에이전트는 대상 아님 (메인의 파이프라인 진입만 검사)
if [ -n "${PIPELINE_UUID:-}" ] && [ "${PIPELINE_UUID:-}" != "${MY_UUID:-$UUID}" ]; then
  exit 0
fi

# ── 3. 두 base 를 ★대칭으로★ 확보 (어느 쪽도 정본으로 고르지 않는다 — 위 F항) ──
_CCD_BASE="${CLAUDE_CONFIG_DIR:-}"
_HOME_DIR="$HOME/.claude/session-env/${UUID}"

# CLAUDE_CONFIG_DIR 미설정이면 두 경로가 동일 → 갈림 자체가 성립 불가 → 통과
[ -z "$_CCD_BASE" ] && exit 0
_CCD_DIR="${_CCD_BASE}/session-env/${UUID}"
[ "$(readlink -f "$_CCD_DIR" 2>/dev/null)" = "$(readlink -f "$_HOME_DIR" 2>/dev/null)" ] && exit 0

# ── 4. auto=ON 판정 — ★양쪽 OR★ (위 F항: AND 로 읽으면 이번 사고를 놓친다) ──
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

# ── 5. 로그 (발동 여부를 사후에 알 수 있어야 한다 — 양쪽에 기록) ───────────
_log() {
  _ts=$(date '+%Y-%m-%dT%H:%M:%S%z')
  for _d in "$_CCD_DIR" "$_HOME_DIR"; do
    [ -d "$_d" ] || continue
    mkdir -p "${_d}/logs" 2>/dev/null
    echo "${_ts} $*" >> "${_d}/logs/session_path_guard.log" 2>/dev/null || true
  done
}

# ── 6. 검사 대상 파일 비교 (내용 해시 — mtime 아님. 위 B항) ────────────────
# oto/SKILL.md "경로_단일화_확인" 이 요구한 4파일(goal.json·oralph_active·status·auto)
# + 파이프라인 정합에 필수인 4파일(state·team_name·classification·entry_tier).
_TARGETS="state status auto goal.json oralph_active team_name classification entry_tier"

_hash_of() {
  # 부재는 "__ABSENT__" 로 표현한다. 양쪽 부재는 동일값이 되어 정상 통과(위 A항).
  if [ -f "$1" ]; then
    md5sum "$1" 2>/dev/null | cut -d' ' -f1
  else
    echo "__ABSENT__"
  fi
}

_MISMATCH=""
_DETAIL=""
for _f in $_TARGETS; do
  _hc=$(_hash_of "${_CCD_DIR}/${_f}")
  _hh=$(_hash_of "${_HOME_DIR}/${_f}")
  if [ "$_hc" != "$_hh" ]; then
    _MISMATCH="${_MISMATCH}${_MISMATCH:+ }${_f}"
    if [ "$_hc" = "__ABSENT__" ]; then _c_desc="부재"; else _c_desc="존재"; fi
    if [ "$_hh" = "__ABSENT__" ]; then _h_desc="부재"; else _h_desc="존재"; fi
    _DETAIL="${_DETAIL}
  · ${_f}
      CLAUDE_CONFIG_DIR : ${_c_desc}  (${_CCD_DIR}/${_f})
      HOME              : ${_h_desc}  (${_HOME_DIR}/${_f})"
  fi
done

if [ -z "$_MISMATCH" ]; then
  _log "PASS uuid=${UUID} 전 대상 정합"
  exit 0
fi

# ── 7. 차단 ───────────────────────────────────────────────────────────────
_log "BLOCK uuid=${UUID} 불일치=[${_MISMATCH}]"

_REASON="⛔ [F-PATH-1] 세션 디렉토리가 두 경로로 갈렸습니다 — 파이프라인 진입을 차단합니다.

불일치 파일: ${_MISMATCH}
${_DETAIL}

왜 차단하는가:
  auto=ON(자율완주) 세션에서 이 갈림이 있으면, 종료 시점에
  PreToolUse_oto_completion_guard.sh 가 'auto 가 있는 쪽'을 정본으로 골라 검사합니다.
  그쪽에 goal.json / oralph_active 가 없으면 F-OTO-7b 로 차단되어
  ★작업을 다 끝낸 뒤에야★ 완주 실패가 드러납니다(사이클40 실사고 — 5시간 손실).
  지금 잡는 편이 그때 잡는 것보다 낫습니다.

해소 절차 (정본을 직접 판단하십시오 — hook 은 임의로 고치지 않습니다):
  1) 어느 쪽이 정본인지 확인합니다. 원칙상 \$CLAUDE_CONFIG_DIR 쪽이 정본입니다
     (스킬 문서가 모두 \${CLAUDE_CONFIG_DIR:-\$HOME/.claude} 를 씁니다).
  2) 부족한 쪽에 파일을 맞춥니다. 예:
     mcp__oio__file_copy(src=\"${_CCD_DIR}/goal.json\",
                         dst=\"${_HOME_DIR}/goal.json\")
  3) 다시 시도하십시오.

근본 원인 (참고):
  oio 서버의 mcp__oio__session_state 는 양쪽 base 에 미러링하지만
  (session_ops.py:_mirror_state_bases), file_write/file_edit 는 미러링하지 않습니다
  (file_ops.py 에 해당 코드 없음). 그래서 goal.json·oralph_active 만 한쪽에 남습니다.
  항구적 해결은 file_ops.py 에 동일 미러링을 이식하는 것입니다.

비상 시: touch ${_HOOK_DIR}/DISABLE_PATH_GUARD 로 우회 가능합니다."

jq -cn --arg r "$_REASON" '{decision:"block", reason:$r}' 2>/dev/null \
  || echo '{"decision":"block","reason":"[F-PATH-1] 세션 디렉토리 경로가 갈렸습니다."}'
exit 2
