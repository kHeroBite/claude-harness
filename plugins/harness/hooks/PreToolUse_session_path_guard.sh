#!/bin/bash
# 세션 디렉토리 2중화(경로 갈림)를 파이프라인 진입 시점에 물리 차단하는 hook
# PreToolUse:Skill — ★모든 세션에서 상시 발동★ (사이클41 변경. 종전 "auto=ON 세션에서만")
# 2026-11-04: 검사 대상을 파이프라인 진입 스킬(_ENTRY_SKILLS)로 한정하고, 차단 전에 무손실 단일화를 1회 시도한다.
#
# ── 배경 (사이클40 실사고, 2026-08-26 실측 재구성) ────────────────────────
# $HOME/.claude/session-env/${UUID}/ 와 $CLAUDE_CONFIG_DIR/session-env/${UUID}/ 가
# 동시 실존하며 내용이 갈렸다. 당시(사이클40) 진단한 원인은 쓰기 경로의 비대칭이었다:
#   · mcp__oio__session_state  → session_ops.py:_mirror_state_bases() 로 ★양쪽★ 기록
#     (state·status·auto·classification·entry_tier 등 전 키)
#   · mcp__oio__file_write/edit → file_ops.py 에 미러링 코드 ★전무★ → ★한쪽만★
#     (goal.json·oroof_active 가 여기 해당)
#
# ── ★위 진단 정정 (사이클41, 2026-09-19 실측) — 반드시 읽어라★ ─────────────
# 위 두 번째 항목("file_write/edit 는 미러링 전무")은 ★사이클40 당시에는 참이었으나
# 사이클41 시점에는 거짓이다.★ 사이클40~49 사이에 미러링이 이식되어 해소됐는데
# 이 주석만 갱신되지 않은 ★화석★ 이었다. 실측 근거:
#   · session_mirror.py 499줄 실존
#   · file_ops.py:12 `import session_mirror`, apply() 호출 11곳(310·451·631·686·688·799·800·878 …)
#   · dir_ops.py:11 import, :134 apply_dir()
#   · 실측: file_write / file_delete → bases_written: 2 (양쪽 기록됨)
# ⇒ ★oio 경유 쓰기는 더 이상 갈림의 원인이 아니다.★
#
# ★진짜 원인은 hook(bash) 자신의 직접 쓰기다.★ 셸 `echo >`·`printf >`·`touch`·`mkdir`
# 은 호출한 쪽의 base 한 곳만 만든다(실측). 사이클41 에서 현 세션 갈림 12건을 전수
# 추적한 결과 ★12건 전부가 hook(bash) 직접 쓰기★ 이고 oio 경유분은 0건이었다.
# (그중 `{logs,evidence,plans,work}` literal 디렉토리는 dash 의 중괄호 확장 미지원이
#  만든 잔재로, 그 자체가 "셸이 썼다" 는 증거다 — oio 는 이런 이름을 만들 수 없다.)
# ⇒ 항구적 해결은 file_ops.py 이식이 아니라 ★경로 심링크 단일화★ 다
#   (SessionStart_path_unify.sh). 같은 inode 가 되면 도구·셸 무관하게 갈림이 성립 불가.
#
# ⚠️ 이 화석 주석 때문에 사이클41 이 "이미 있는 코드를 다시 넣는" 헛수고로 끝날 뻔했다.
#    정정 이력을 남기는 이유가 그것이다 — 지우면 다음 사람이 또 뒤집는다.
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
# ── 2026-11-04 정정 — 위 세 이유 중 살아 있는 것만 남긴다 ─────────────────
# 1) 은 원인(hook 셸 쓰기)을 심링크 단일화가 없앴으므로 더는 성립하지 않는다.
# 2) 는 계약 파일 상이를 계속 fail-closed 로 막아 그대로 지킨다(lib spu_classify).
# 3) 은 자기 세션 한정이면 세션 격리 §(a) 위반이 아니다.
# ⇒ 계약 파일 상이가 없을 때만 lib 단일화를 예산 안에서 1회 시도하고, 그 밖은 종전대로 차단한다.
# 복구 수단(ointaug·oi·oinit·ofinish·oresume 등)까지 막아 사람 없이 못 빠져나가던 교착을 없애려는 조치다.
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
#     ⇒ 근본 해결은 ★경로 심링크 단일화★(SessionStart_path_unify.sh)이며, 본 hook 은
#       그것이 깨진 경우를 잡는 탐지 장치다.
#       (종전 이 자리에는 "근본 해결은 file_ops.py 미러링 이식" 이라 적혀 있었다 —
#        사이클41 실측으로 거짓 판명. 위 정정 절 참조.)
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
#  G. ★비진입 스킬 호출 시점의 갈림★ — 검사하지 않는다(의도).
#     다음 진입 스킬 호출과 PreToolUse_oto_completion_guard.sh 가 잡는다.
#
# ── 비상 스위치 ───────────────────────────────────────────────────────────
#   touch ${HARNESS_HOME:-$HOME/.harness}/current/hooks/DISABLE_PATH_GUARD     # 즉시 무력화 (사람 전용 — 에이전트 복구 경로가 아니다)
#
# fail-open 원칙: 모든 예외 경로의 기본은 exit 0. 차단은 단 한 곳에서만 일어난다.
# set -e 는 쓰지 않는다 — 중간 실패가 곧 차단이 되면 안 된다.

set -u

# hook 자신의 실경로 기준으로 라이브러리를 찾는다.
# $HOME 기준으로 잡으면 HOME 이 다른 환경(테스트 하네스·격리 실행)에서
# lib/session_id.sh 를 못 찾아 조용히 exit 0 이 된다 — 게이트가 no-op 이 되는 형태다.
# (2026-08-26 자체 테스트에서 실제로 이 경로로 통과해버리는 것을 확인하고 수정)
_HOOK_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || _HOOK_DIR="${HARNESS_HOME:-$HOME/.harness}/current/hooks"
[ -r "${_HOOK_DIR}/lib/session_id.sh" ] || _HOOK_DIR="${HARNESS_HOME:-$HOME/.harness}/current/hooks"

# ── 0. 비상 스위치 (최우선) ───────────────────────────────────────────────
# ★두 위치를 모두 본다.★ _HOOK_DIR 은 스크립트 실경로(NTFS 원본)로 해석되는데,
# 사용자는 ${HARNESS_HOME:-$HOME/.harness}/current/hooks/ (symlink 경유 경로)에 touch 하는 것이 자연스럽다.
# 한쪽만 보면 "스위치를 만들었는데 안 꺼진다" 가 된다 — 비상 스위치가 비상 시에
# 작동하지 않는 것은 그 자체로 사고다. (2026-08-26 자체 테스트 T9 에서 실제 발생)
for _sw in "${_HOOK_DIR}/DISABLE_PATH_GUARD" "${HARNESS_HOME:-$HOME/.harness}/current/hooks/DISABLE_PATH_GUARD"; do
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

# 검사 대상 = 파이프라인 진입 스킬. PreToolUse_Skill_ointaug_gate.sh 의 F-INTAUG-1 case 집합과 같아야 한다.
# oi 는 넣지 않는다 — oi 대기 중에는 Skill('oi') 가 유일한 통과 경로이므로 막으면 복구할 길이 없다.
_ENTRY_SKILLS="ok|oto|oroof|oralph|o1|o2|o3|o4|o5|okconsult|okdebate|okdeep|odeep|oconsult|odebate|oplan|onormal|osimple"
_SKILL=$(printf '%s' "$INPUT" | jq -r '(.tool_input.skill // .tool_input.skill_name // empty)' 2>/dev/null)
_SKILL="${_SKILL##*:}"  # 플러그인 접두사(harness:ok → ok) 정규화
[ -n "$_SKILL" ] || exit 0
case "|${_ENTRY_SKILLS}|" in
  *"|${_SKILL}|"*) ;;
  *) exit 0 ;;
esac

# ── 2. UUID 결정 ──────────────────────────────────────────────────────────
# shellcheck source=/dev/null
. "${_HOOK_DIR}/lib/session_id.sh" 2>/dev/null || exit 0
resolve_uuid "$INPUT" 2>/dev/null || exit 0
[ -z "${UUID:-}" ] && exit 0

# 팀에이전트는 대상 아님 (메인의 파이프라인 진입만 검사)
# resolve_uuid 는 PIPELINE_UUID 가 있으면 MY_UUID 를 채우지 않아 ${MY_UUID:-$UUID} 비교는 언제나 같았다(샌드박스 재현).
# 치유는 디렉터리를 옮기므로 부모 세션을 건드리면 안 된다. 자기 세션 ID 는 hook 입력에서 읽는다.
if [ -n "${PIPELINE_UUID:-}" ]; then
  _SELF_SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
  [ "${PIPELINE_UUID}" = "$_SELF_SID" ] || exit 0
fi

# ── 3. 두 base 를 ★대칭으로★ 확보 (어느 쪽도 정본으로 고르지 않는다 — 위 F항) ──
_CCD_BASE="${CLAUDE_CONFIG_DIR:-}"
_HOME_DIR="$HOME/.claude/session-env/${UUID}"

# CLAUDE_CONFIG_DIR 미설정이면 두 경로가 동일 → 갈림 자체가 성립 불가 → 통과
[ -z "$_CCD_BASE" ] && exit 0
_CCD_DIR="${_CCD_BASE}/session-env/${UUID}"
[ "$(readlink -f "$_CCD_DIR" 2>/dev/null)" = "$(readlink -f "$_HOME_DIR" 2>/dev/null)" ] && exit 0

# ── 4. auto=ON 판정 — ★양쪽 OR★ (위 F항: AND 로 읽으면 이번 사고를 놓친다) ──
# ★사이클41 변경 — 이 판정은 더 이상 게이트가 아니다.★
# 종전에는 바로 아래에 `_is_auto_on || exit 0` 이 있어서 auto=ON 세션에서만
# 탐지가 돌았다. 그래서 ★경보기가 대부분의 세션에서 꺼져 있었다★ — auto 파일이
# 없는 평상 세션에서는 갈림이 상시 누적되는데도 아무도 몰랐고, /oto·/opush 같은
# 특정 경로에서만 뒤늦게 드러났다. 그것이 "계속 갈린다" 의 직접 원인이므로
# 게이트를 제거하고 ★상시 탐지★ 로 승격했다.
# 남은 용도는 차단 메시지의 심각도 문구 선택뿐이다(auto=ON 이면 F-OTO-7b 경고 추가).
_is_auto_on() {
  for _d in "$_CCD_DIR" "$_HOME_DIR"; do
    if [ -f "${_d}/auto" ]; then
      _v=$(tr -d '[:space:]' < "${_d}/auto" 2>/dev/null)
      [ "$_v" = "ON" ] && return 0
    fi
  done
  return 1
}
if _is_auto_on; then _AUTO_STATE="ON"; else _AUTO_STATE="OFF"; fi

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
# oto/SKILL.md "경로_단일화_확인" 이 요구한 4파일(goal.json·oroof_active·status·auto)
# + 파이프라인 정합에 필수인 4파일(state·team_name·classification·entry_tier).
_TARGETS="state status auto goal.json oroof_active team_name classification entry_tier"
# ROOF-COMPAT(deprecation window 1주기 — 구 RALPH/oralph_active 인식 제거 예정)
_TARGETS="${_TARGETS} oralph_active"

_hash_of() {
  # 부재는 "__ABSENT__" 로 표현한다. 양쪽 부재는 동일값이 되어 정상 통과(위 A항).
  if [ -f "$1" ]; then
    md5sum "$1" 2>/dev/null | cut -d' ' -f1
  else
    echo "__ABSENT__"
  fi
}

_scan_targets() {
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
}

_scan_targets
if [ -z "$_MISMATCH" ]; then
  _log "PASS uuid=${UUID} auto=${_AUTO_STATE} 전 대상 정합"
  exit 0
fi

# ── 6-1. 자기치유 — 계약 파일 상이가 없을 때만 예산 안에서 무손실 단일화 ──────
# 이 hook 의 시간 예산이 짧아 상한을 둔다. 넘으면 치유를 생략하고 종전대로 차단한다(fail-closed).
# bak(.unify-bak.<epoch>)는 지우지 않는다 — 형제 hook 이 그 자리에 쓴 파일을 잃지 않기 위해서다. 삭제는 spu_prune_bak 만 한다.
_HEAL_MAX_FILES=400
_HEAL_MAX_SEC=1.5
_HEAL_NOTE=""
if [ -r "${_HOOK_DIR}/lib/session_path_unify.sh" ] \
   && . "${_HOOK_DIR}/lib/session_path_unify.sh" 2>/dev/null \
   && spu_paths "$UUID"; then
  _HEAL=$(SPU_MAX_FILES="$_HEAL_MAX_FILES" SPU_MAX_SEC="$_HEAL_MAX_SEC" spu_unify "$UUID" 2>/dev/null)
else
  _HEAL="LIB_MISSING"
fi
case "$_HEAL" in
  UNIFIED)
    spu_log "HEALED uuid=${UUID} auto=${_AUTO_STATE} 불일치=[${_MISMATCH}]"
    exit 0
    ;;
  BLOCKED:*)
    _log "HEAL_SKIPPED uuid=${UUID} reason=contract 상이=[${_HEAL#BLOCKED:}]"
    _HEAL_NOTE="자동 단일화 보류: 내용이 다른 계약 파일이 있어 어느 쪽이 정본인지 hook 이 정할 수 없습니다 (${_HEAL#BLOCKED:})."
    ;;
  BUDGET:*)
    _log "HEAL_SKIPPED uuid=${UUID} reason=${_HEAL#BUDGET:}"
    _HEAL_NOTE="자동 단일화 생략: 예산 초과 (${_HEAL#BUDGET:}, 파일 ${_HEAL_MAX_FILES}개·${_HEAL_MAX_SEC}초 상한)."
    ;;
  *)
    _log "HEAL_SKIPPED uuid=${UUID} reason=failed result=${_HEAL}"
    _HEAL_NOTE="자동 단일화 실패 (${_HEAL})."
    ;;
esac

# 치유가 중간까지 합집합을 옮겼거나 다른 hook 이 단일화했으면 불일치가 사라졌을 수 있다
_scan_targets
if [ -z "$_MISMATCH" ]; then
  _log "PASS uuid=${UUID} auto=${_AUTO_STATE} 치유 시도 뒤 전 대상 정합 (${_HEAL})"
  exit 0
fi

# 복구 명령은 이 hook 이 다시 비교하는 파일을 그대로 가리킨다. overwrite=true 는 대상이 이미 있을 때만 붙인다.
# 대상이 없을 때 붙이면, 안내 뒤 대상이 생겼을 때 그 파일을 덮어쓴다. 빼 두면 oio 가 FILE_EXISTS 로 실패한다. write_guard 도 부재 대상 복사는 overwrite 없는 호출만 연다.
_HINT=""
_GOAL_LOCK_NOTE=""
for _f in $_MISMATCH; do
  if [ "$_f" = "state" ]; then
    _HINT="${_HINT}
     mcp__oio__session_state(key=\"state\", value=\"<현재 단계>\")  (state 는 양쪽에 기록하는 이 도구로만 맞춘다)"
    continue
  fi
  if [ -f "${_CCD_DIR}/${_f}" ]; then
    _src="${_CCD_DIR}/${_f}"; _dst="${_HOME_DIR}/${_f}"
  else
    _src="${_HOME_DIR}/${_f}"; _dst="${_CCD_DIR}/${_f}"
  fi
  if [ -e "$_dst" ] || [ -L "$_dst" ]; then _ow=" + overwrite=true"; else _ow=""; fi
  _HINT="${_HINT}
     mcp__oio__file_copy(source=\"${_src}\", destination=\"${_dst}\")${_ow}"
  if [ "$_f" = "goal.json" ] && {
       [ "$(jq -r '.locked // false' "${_CCD_DIR}/goal.json" 2>/dev/null)" = "true" ] \
       || [ "$(jq -r '.locked // false' "${_HOME_DIR}/goal.json" 2>/dev/null)" = "true" ]; }; then
    _GOAL_LOCK_NOTE="
  ※ goal.json 이 잠겨 있어도 대상이 없거나 계약 내용이 같으면(서식만 다름) 위 복사는 통과합니다.
     항목 수가 다르면 복사는 막힙니다. 짧은 쪽 base 에 mcp__oio__file_write 로 '기존 내용 그대로 + 끝에 open 새 항목'(goal_append)을 써서 맞추십시오.
     새 항목이 이미 PASS 면 덧붙일 수 없어 복구 경로가 없습니다. 그 밖에 막히는 경우도 우회하지 말고 차단 원문을 보고하십시오."
  fi
done

# ── 7. 차단 ───────────────────────────────────────────────────────────────
_log "BLOCK uuid=${UUID} auto=${_AUTO_STATE} 불일치=[${_MISMATCH}]"

_REASON="⛔ [F-PATH-1] 세션 디렉토리가 두 경로로 갈렸습니다 — 파이프라인 진입을 차단합니다.

불일치 파일: ${_MISMATCH}
${_DETAIL}

${_HEAL_NOTE}

현재 auto 상태: ${_AUTO_STATE}

왜 차단하는가:
  갈린 상태로 진행하면 어느 쪽 파일을 읽었는지에 따라 파이프라인 판정이 뒤집힙니다.
  auto=ON(자율완주) 세션에서는 특히, 종료 시점에
  PreToolUse_oto_completion_guard.sh 가 'auto 가 있는 쪽'을 정본으로 골라 검사하고
  그쪽에 goal.json / oroof_active 가 없으면 F-OTO-7b 로 차단되어
  ★작업을 다 끝낸 뒤에야★ 완주 실패가 드러납니다(사이클40 실사고 — 5시간 손실).
  auto=OFF 세션도 갈림은 똑같이 누적되며 나중에 드러날 뿐입니다 — 그래서
  사이클41 부터 auto 여부와 무관하게 상시 탐지합니다. 지금 잡는 편이 낫습니다.

해소 절차 (이번 호출은 계약 파일을 덮어쓰지 않았습니다. 정본을 판단해 맞추십시오):
  1) ointaug·oi 대기 중이면 Skill('ointaug')·Skill('oi') 를 먼저 호출합니다(이 hook 이 막지 않습니다).
  2) 어느 쪽이 정본인지 확인합니다. 원칙상 \$CLAUDE_CONFIG_DIR 쪽이 정본입니다
     (스킬 문서가 모두 \${CLAUDE_CONFIG_DIR:-\$HOME/.claude} 를 씁니다).
     HOME 쪽이 정본이면 source 와 destination 을 바꿉니다.
  3) 아래 명령으로 맞춥니다.${_HINT}${_GOAL_LOCK_NOTE}
  4) 다시 시도하십시오. 위 파일이 일치하면 통과합니다.

근본 원인 (참고 — 2026-09-19 사이클41 실측으로 정정됨):
  ★oio 도구(file_write/file_edit/file_delete)는 양쪽 base 에 정상 미러링합니다.★
  session_mirror.py(499줄) 실존 + file_ops.py:12 import + apply() 호출 11곳,
  실측 file_write → bases_written:2. 즉 oio 경유 쓰기는 갈림의 원인이 아닙니다.

  ★진짜 원인은 hook(bash) 의 직접 쓰기입니다.★ 셸 \`echo >\`·\`touch\`·\`mkdir\` 은
  호출한 쪽의 base 한 곳만 만듭니다(실측). 사이클41 실측 갈림 12건 전부가
  이 경로에서 나왔고 oio 경유분은 0건이었습니다.
  ⇒ 항구적 해결은 session-env 경로를 심링크로 단일화하는 것입니다
     (SessionStart_path_unify.sh — 같은 inode 가 되면 어느 base 로 써도 같은 파일)."

jq -cn --arg r "$_REASON" '{decision:"block", reason:$r}' 2>/dev/null \
  || echo '{"decision":"block","reason":"[F-PATH-1] 세션 디렉토리 경로가 갈렸습니다."}'
exit 2
