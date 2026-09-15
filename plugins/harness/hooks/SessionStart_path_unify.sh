#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# 세션 시작 시 두 session-env 경로의 갈림을 관측·기록하는 hook
# SessionStart — ★자기 세션만★ (CLAUDE.md 세션 격리 §(a) 준수)
#
# ── 왜 "정합(복사)" 이 아니라 "관측" 인가 ──────────────────────────────────
# 지시는 "두 경로를 정합" 이었으나, 실측 후 ★관측 전용★ 으로 좁혔다. 근거:
#
#  1) ★SessionStart 시점에는 정본을 판정할 근거가 없다.★
#     세션 시작 시 두 경로가 갈려 있다면 그것은 ★직전 세션의 잔재★ 이며,
#     어느 쪽이 최신 의도인지 알 수 없다. goal.json 처럼 계약 문서를 잘못된
#     방향으로 복사하면 ★이행 완료된 옛 계약이 새 세션의 정본으로 되살아난다.★
#     (ofinish/SKILL.md 가 경고한 "locked=false 잔존 → 다음 사이클 시드 재사용" 과 동형)
#  2) ★조용한 자동 수정은 원인을 은폐한다.★ 근본 원인은 oio 서버 file_ops.py 의
#     미러링 부재다. SessionStart 가 매번 뒤치다꺼리하면 그 결함이 영구히
#     드러나지 않는다 (CLAUDE.md 재발방지 정책 — LLM/스크립트 의지 의존 회피).
#  3) ★쓰기는 그 자체가 위험하다.★ 세션 시작은 여러 hook 이 동시에 도는 구간이라
#     여기서 session-env 에 쓰면 경합의 새 원천이 된다.
#
# ⇒ 따라서 본 hook 은 ★기록 + 경고 출력만★ 한다. 실제 차단은 진입 시점의
#   PreToolUse_session_path_guard.sh(F-PATH-1) 가, 종료 시점은 F-OTO-7b 가 맡는다.
#   3중 배치이며 각자 다른 시점을 담당한다.
#
# ── ★이 hook 이 못 잡는 것★ (사이클40 A2 교훈) ───────────────────────────
#  A. ★세션 시작 이후에 생기는 갈림★ — 못 잡는다. 시작 시점 1회만 본다.
#     ⇒ 보완: F-PATH-1 이 매 Skill 호출마다 재검사한다.
#  B. ★갈림을 고치지 않는다★ — 설계상 의도다(위 1~3항). 알리기만 한다.
#  C. ★타 세션의 갈림★ — 보지 않는다. 세션 격리 §(a) 준수이며 의도된 한계다.
#  D. ★CLAUDE_CONFIG_DIR 미설정 세션★ — 두 경로가 동일해지므로 검사 자체가 무의미.
#  E. ★stdout 이 사용자에게 안 보이는 경우★ — SessionStart 의 stdout 노출은
#     클라이언트 구현에 의존한다. 그래서 ★파일 로그를 1순위 증적★ 으로 남긴다.
#
# 비상 스위치: touch $HOME/.claude/hooks/DISABLE_PATH_GUARD  (F-PATH-1 과 공용)
# fail-open: 모든 경로의 기본은 exit 0. 이 hook 은 어떤 경우에도 세션을 막지 않는다.

set -u

_HOOK_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || _HOOK_DIR="$HOME/.claude/hooks"
[ -r "${_HOOK_DIR}/lib/session_id.sh" ] || _HOOK_DIR="$HOME/.claude/hooks"

for _sw in "${_HOOK_DIR}/DISABLE_PATH_GUARD" "$HOME/.claude/hooks/DISABLE_PATH_GUARD"; do
  [ -f "$_sw" ] && exit 0
done

command -v jq >/dev/null 2>&1 || exit 0
command -v md5sum >/dev/null 2>&1 || exit 0

INPUT=$(timeout 5 cat 2>/dev/null) || exit 0
[ -z "$INPUT" ] && exit 0

# ── UUID 결정 — ★자기 세션만★ ────────────────────────────────────────────
# shellcheck source=/dev/null
. "${_HOOK_DIR}/lib/session_id.sh" 2>/dev/null || exit 0
resolve_uuid "$INPUT" 2>/dev/null || exit 0
[ -z "${UUID:-}" ] && exit 0

_CCD_BASE="${CLAUDE_CONFIG_DIR:-}"
[ -z "$_CCD_BASE" ] && exit 0

_CCD_DIR="${_CCD_BASE}/session-env/${UUID}"
_HOME_DIR="$HOME/.claude/session-env/${UUID}"
[ "$(readlink -f "$_CCD_DIR" 2>/dev/null)" = "$(readlink -f "$_HOME_DIR" 2>/dev/null)" ] && exit 0

# 둘 다 없으면 신규 세션 — 정상
[ ! -d "$_CCD_DIR" ] && [ ! -d "$_HOME_DIR" ] && exit 0

_TARGETS="state status auto goal.json oralph_active team_name classification entry_tier"

_hash_of() {
  if [ -f "$1" ]; then md5sum "$1" 2>/dev/null | cut -d' ' -f1; else echo "__ABSENT__"; fi
}

_MISMATCH=""
for _f in $_TARGETS; do
  _hc=$(_hash_of "${_CCD_DIR}/${_f}")
  _hh=$(_hash_of "${_HOME_DIR}/${_f}")
  [ "$_hc" != "$_hh" ] && _MISMATCH="${_MISMATCH}${_MISMATCH:+ }${_f}"
done

[ -z "$_MISMATCH" ] && exit 0

# ── 기록 (1순위 증적 — stdout 노출 여부와 무관하게 남는다) ─────────────────
_ts=$(date '+%Y-%m-%dT%H:%M:%S%z')
for _d in "$_CCD_DIR" "$_HOME_DIR"; do
  [ -d "$_d" ] || continue
  mkdir -p "${_d}/logs" 2>/dev/null
  echo "${_ts} SESSIONSTART_MISMATCH uuid=${UUID} 불일치=[${_MISMATCH}]" \
    >> "${_d}/logs/session_path_guard.log" 2>/dev/null || true
done

# ── 경고 출력 (2순위 — 클라이언트가 표시하면 즉시 인지) ────────────────────
cat <<EOF
⚠️  [경로 갈림 감지] 세션 디렉토리가 두 경로로 갈려 있습니다.

  불일치 파일: ${_MISMATCH}
    CLAUDE_CONFIG_DIR : ${_CCD_DIR}
    HOME              : ${_HOME_DIR}

  이 상태로 auto=ON(/oto) 파이프라인에 진입하면 종료 시점에 F-OTO-7b 로
  차단되어 작업을 다 끝낸 뒤에야 완주 실패가 드러납니다(사이클40 실사고).

  · 자동 수정은 하지 않습니다 — 어느 쪽이 정본인지 판정할 근거가
    세션 시작 시점에는 없기 때문입니다(옛 계약 부활 위험).
  · 원칙상 \$CLAUDE_CONFIG_DIR 쪽이 정본입니다.
  · 파이프라인 진입 시 PreToolUse_session_path_guard.sh(F-PATH-1)가 차단합니다.
EOF

exit 0
