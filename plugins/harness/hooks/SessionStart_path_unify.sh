#!/bin/bash
# 세션 시작 시 자기 세션의 session-env 두 경로를 심링크로 단일화하는 hook
# SessionStart — ★자기 세션만★ (CLAUDE.md 세션 격리 §(a) 준수)
#
# ── 설계 전환 (사이클144) — "관측 전용" → "자기 세션 심링크 전환" ─────────
# 종전 본 hook 은 ★관측 전용★ 이었고, 그 근거는 "SessionStart 시점에는 정본을
# 판정할 근거가 없다" 였다. 이 근거는 ★지금도 유효하다★. 그래서 본 hook 은
# 여전히 ★정본을 판정하지 않는다★ — 대신 정본 판정이 ★불필요한 경우에만★
# 단일화한다.
#
#   · ★계약 파일★ 내용이 갈렸으면 → ★전환하지 않고 경고만★ (fail-closed)
#   · 한쪽에만 있는 파일과 휘발 파일 상이뿐이면 → 정본 판정이 필요 없으므로 무손실 단일화
#     (휘발 allowlist 는 lib/session_path_unify.sh spu_classify 한 곳. 그 밖은 전부 계약)
#
# 즉 "어느 쪽이 정본인가" 를 물어야 하는 상황에서는 손대지 않는다. 옛 계약
# (goal.json·plans/*.md) 이 새 세션의 정본으로 되살아나는 위험은 그대로 차단된다.
#
# ── ★R1 실증 (2026-09-19, odev-1)★ ───────────────────────────────────────
# 가설: "Claude Code 런타임이 세션 시작 시 CCD 실디렉토리를 재생성해 심링크를 덮는다"
# ⇒ ★거짓★. 근거 2단:
#   (1) 런타임 바이너리(2.1.277) 내 session-env 생성 코드는 단 한 곳이다:
#         async function $Ie(){let e=voe(we(),"session-env",K());return await le().mkdir(e),e}
#       즉 ★mkdir 뿐★ 이며 unlink/rm/교체 경로가 없다.
#   (2) 그 mkdir 의미를 실측: 심링크 대상에 대해
#         mkdir(recursive:true) → 예외 없이 ★no-op★ (심링크 보존)
#         mkdir(비recursive)    → EEXIST ★throw, 심링크 보존★
#       전후 test -L=LINK_ALIVE, target inode 601728 불변, canary 무손실.
# ⇒ 심링크는 런타임 세션 시작에 의해 덮이지 않는다. 안2(단일화)는 성립한다.
#   ★단 이것은 "덮이지 않는다"의 증명이지 "영원히 안 덮인다"의 보증은 아니다★ —
#   런타임 버전이 바뀌면 (1) 이 달라질 수 있다. 그래서 매 세션 idempotent 재보장한다.
#
# ── ★이 hook 이 못 잡는 것★ (정직 기재) ──────────────────────────────────
#  A. ★계약 파일 내용이 갈린 세션★ — 전환하지 않는다. 설계상 의도(fail-closed).
#     ⇒ 사용자가 직접 정본을 판정해야 한다. 경고로 알린다.
#  B. ★타 세션의 갈림★ — 보지 않는다. 세션 격리 §(a) 준수이며 의도된 한계다.
#  C. ★활성 세션의 inode 교체★ — 팀에이전트 경로는 즉시 exit 하여 회피한다.
#  D. ★CLAUDE_CONFIG_DIR 미설정 세션★ — 두 경로가 동일해지므로 검사 자체가 무의미.
#  E. ★전환 이후에 생기는 갈림★ — 성립 불가(같은 inode). 단 심링크가 외부에서
#     해제되면 재발 ⇒ F-PATH-1 이 매 Skill 호출마다 재검사한다.
#
# ── ★2026-10-06 정정 (odev-2)★ — 빈 CCD 가짜 md5 ABORT 원인 제거 ─────────
#  원인: CCD 가 빈 디렉토리면 `find ... | xargs -0 md5sum` 이 입력 0건인데도
#        md5sum 을 인자 없이 1회 실행 → stdin(-) 해시 "d41d8cd9...  -" 가짜 항목이
#        _SNAP_C 에 생겼고, 사후 검증이 이를 "HOME 에 없는 파일" 로 판정해
#        PATH_UNIFY_ABORT(합집합_누락=[-]) → 빈 CCD 가 영영 단일화되지 못했다.
#  조치: (1) xargs -0 -r  (2) 빈 CCD 단축 경로(재귀 삭제 금지, 빈 디렉토리만
#        제거 후 ln -sT)  (3) 일반 경로는 bak 생성 직후 bak↔HOME md5 재대조,
#        HOME 에 없는 파일 cp -n 보충, 상이·누락이 남으면 bak 보존(삭제 금지)
#        (4) 모든 링크 생성 ln -sT.  (기존 이력은 위 그대로 유지)
#
# ── ★2026-11-04 정정★ — 단일화 본체를 lib/session_path_unify.sh 로 추출 ─────
#  휘발 파일 상이까지 보류하던 것을 계약 파일 상이만 보류하도록 좁혔다. 복사는 mtime 을
#  보존하는 cp -a 로 바꿨다(mtime 판정 증표 위조 방지). 빈 CCD 경로는 재시도한다.
#  bak 는 즉시 지우지 않고 .unify-bak.<epoch> 로 보존하며 삭제는 spu_prune_bak 만 한다.
#
# 비상 스위치: touch ${HARNESS_HOME:-$HOME/.harness}/current/hooks/DISABLE_PATH_GUARD  (F-PATH-1 과 공용)
# fail-open: 모든 경로의 기본은 exit 0. 이 hook 은 어떤 경우에도 세션을 막지 않는다.

set -u

_HOOK_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || _HOOK_DIR="${HARNESS_HOME:-$HOME/.harness}/current/hooks"
[ -r "${_HOOK_DIR}/lib/session_id.sh" ] || _HOOK_DIR="${HARNESS_HOME:-$HOME/.harness}/current/hooks"

for _sw in "${_HOOK_DIR}/DISABLE_PATH_GUARD" "${HARNESS_HOME:-$HOME/.harness}/current/hooks/DISABLE_PATH_GUARD"; do
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

# shellcheck source=/dev/null
. "${_HOOK_DIR}/lib/session_path_unify.sh" 2>/dev/null || exit 0

# 팀에이전트는 대상 아님 — 메인 세션만 자기 것을 전환한다.
# (팀에이전트가 부모 UUID 를 건드리면 §(a) 위반이자 실행 중 inode 교체가 된다)
# resolve_uuid 는 PIPELINE_UUID 가 있으면 MY_UUID 를 채우지 않으므로 자기 세션 ID 는 hook 입력에서 직접 읽는다.
if [ -n "${PIPELINE_UUID:-}" ]; then
  _SELF_SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
  [ "${PIPELINE_UUID}" = "$_SELF_SID" ] || exit 0
fi

spu_paths "$UUID" || exit 0

# 지난 단일화가 남긴 bak 정리(단일화된 세션에서만, 지워도 되는 것만). spu_unify 보다 먼저 불러 이번 bak 는 건드리지 않는다.
spu_prune_bak "$UUID"

# HOME 이 실체, CCD 가 심링크. 방향 근거(실측): HOME 1,373 세션 ⊃ CCD 15 세션,
# 교집합 15/15. 역방향은 HOME 전체를 /tmp 하위에 묶으므로 채택 불가.
_RESULT=$(spu_unify "$UUID")

case "$_RESULT" in
  BLOCKED:*)
    _DIVERGED="${_RESULT#BLOCKED:}"
    cat <<EOF
⚠️  [경로 갈림 — 자동 단일화 보류] session-env 가 두 경로로 갈려 있습니다.

  ★내용이 서로 다른 계약 파일★: ${_DIVERGED}
    CLAUDE_CONFIG_DIR : ${SPU_CCD_DIR}
    HOME              : ${SPU_HOME_DIR}

  · 자동 단일화를 ★하지 않았습니다★ — 어느 쪽이 정본인지 판정할 근거가
    세션 시작 시점에는 없기 때문입니다(옛 계약·옛 계획서 부활 위험).
  · 위 파일들을 직접 비교해 정본을 남긴 뒤 다음 세션에서 자동 단일화됩니다.
      diff "${SPU_CCD_DIR}/<파일>" "${SPU_HOME_DIR}/<파일>"
  · 한쪽에만 있는 파일은 손실 위험이 없으므로 이번에도 보존됩니다.
EOF
    ;;
esac

exit 0
