#!/bin/bash
# 파이프라인 진입(IDLE→PLAN|DEV|OK) 시 이전 사이클 잔존 마커를 logs/prev_cycle/<시각>/ 로 보관 이동하는 hook
# PreToolUse:mcp__oio__session_state — key=state, value=PLAN|DEV|OK 전이만 대상
#
# 왜 있는가 (L-599):
#   ok/SKILL.md "evidence_초기화" 는 LLM 이 지시를 따라야만 실행되는 문서 규칙이다.
#   이전 사이클의 evidence 항목·.phase_batches.written·plans/phase_batches.json 이 남으면
#   다음 사이클에서 완료 판정 오인, F9(phase_batches_immutable_guard) 영구 차단이 생긴다.
#   이 hook 은 그 정리를 도구 호출 시점에 물리적으로 보장한다. 삭제가 아니라 보관(이동)이다.
#
# 대상 항목 (각 base 마다):
#   evidence/ 안 항목 전부, .phase_batches.written, plans/phase_batches.json, current_phase_batch,
#   plans/acceptance_criteria.json
#   → <base>/<UUID>/logs/prev_cycle/<YYYYmmddTHHMMSS-pid>/ 아래 같은 상대 경로로 이동
#   보관 이동·R4·ROOF(구 RALPH) 판정 본문은 lib/pipeline_entry_archive.sh(pea_archive) 와 공유한다.
#   phase_guard.sh(Skill ok|ok_*|o1~o5 직후 IDLE|FINISH→PLAN) 도 같은 함수를 부른다 — 사이클194 (a).
#
# 동작하지 않는 조건 (모두 exit 0 — 이 hook 은 절대 차단하지 않는다):
#   - key != state, value ∉ {PLAN, DEV, OK}
#   - tool_input.uuid 가 UUID 형식이 아님 (경로 탈출 방지)
#   - R2: tool_input.force 가 참 — oresume 재진입은 진행 중 사이클의 evidence 를 써야 한다
#   - R3: tool_input.uuid 가 자기 세션(PIPELINE_UUID, 없으면 hook 입력 session_id)과 다름 — 세션 격리
#   - 현재 state(어느 base 든) 가 IDLE 이 아님 — 진행 중 사이클(역라우팅·oroof 재진입 등)
#   - R4: evidence/ok_started 가 있는데 ofinish_done·ofinish_cleanup_done 이 없고 state 줄에 stale_ 도 없음
#         → 정상 종료되지 않은 사이클이다. 자동 소거 통로가 되지 않도록 옮기지 않는다.
#   - status 에 ROOF 또는 구 RALPH (oroof 루프) # ROOF-COMPAT(deprecation window 1주기 — 구 RALPH/oralph_active 인식 제거 예정)
#   - 공용 lib 부재 → LIB_MISSING 로그만 남기고 무동작
#
# 두 base(${CLAUDE_CONFIG_DIR}/session-env, $HOME/.claude/session-env)를 모두 처리하고 realpath 로 중복을 없앤다.
# 결과는 각 base 의 logs/pipeline_entry_reset.log 에 1줄(옮긴 파일명 포함) 남긴다.
# 한계: settings.json 등록은 새로 시작한 세션부터 반영된다(활성 세션은 시작 시점 hooks 스냅샷 사용).

set -u

command -v jq >/dev/null 2>&1 || exit 0
INPUT=$(timeout 5 cat 2>/dev/null) || exit 0
[ -z "$INPUT" ] && exit 0

_get() { printf '%s' "$INPUT" | jq -r "$1" 2>/dev/null; }

[ "$(_get '.tool_input.key // empty')" = "state" ] || exit 0
_VALUE=$(_get '.tool_input.value // empty')
_VFIRST=${_VALUE%% *}
case "$_VFIRST" in
  PLAN|DEV|OK) ;;
  *) exit 0 ;;
esac

_UUID=$(_get '.tool_input.uuid // empty')
printf '%s' "$_UUID" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || exit 0

# 대상 base 목록 (realpath 중복 제거)
_DIRS=""
_seen=""
for _b in "${CLAUDE_CONFIG_DIR:-}" "$HOME/.claude"; do
  [ -n "$_b" ] || continue
  _d="${_b}/session-env/${_UUID}"
  [ -d "$_d" ] || continue
  _r=$(readlink -f "$_d" 2>/dev/null) || _r="$_d"
  case " $_seen " in *" $_r "*) continue ;; esac
  _seen="$_seen $_r"
  _DIRS="${_DIRS}${_DIRS:+
}${_d}"
done
[ -n "$_DIRS" ] || exit 0

_log() {
  _ts=$(date '+%Y-%m-%dT%H:%M:%S%z')
  printf '%s\n' "$_DIRS" | while IFS= read -r _d; do
    mkdir -p "${_d}/logs" 2>/dev/null
    echo "${_ts} uuid=${_UUID} value=${_VFIRST} $*" >> "${_d}/logs/pipeline_entry_reset.log" 2>/dev/null || true
  done
}

# R2: force 전이 → 무동작
_FORCE=$(_get '.tool_input.force // false | tostring | ascii_downcase')
case "$_FORCE" in
  true|1|yes) _log "FORCE_SKIP"; exit 0 ;;
esac

# R3: 자기 세션 일치 확인
_SELF="${PIPELINE_UUID:-}"
[ -n "$_SELF" ] || _SELF=$(_get '.session_id // empty' | tr -d '[:space:]')
if [ -z "$_SELF" ] || [ "$_SELF" != "$_UUID" ]; then
  _log "UUID_MISMATCH_SKIP self=${_SELF:-none}"
  exit 0
fi

# 현재 state: 존재하는 state 파일이 모두 IDLE 이어야 한다
# 예외(사이클197 AC-J7): 슬래시 선기록 PLAN — 첫 토큰 PLAN + teamcreate_force_ 토큰 둘 다일 때만 IDLE 과 같이 진행한다.
#   토큰 출처: UserPromptSubmit.sh:350 state_transition 사유 "teamcreate_force_<cmd>", 줄 형식은 state_machine.sh:184 "<STATE> <UUID> <ISO> <REASON>".
#   같은 사이클 재호출은 lib R4(ok_started 있음·ofinish 없음 → SKIPPED_UNFINISHED)가 막는다.
_STALE=0
_SLASH_PRE=0
while IFS= read -r _d; do
  [ -f "${_d}/state" ] || continue
  _line=$(head -n1 "${_d}/state" 2>/dev/null)
  _first=${_line%% *}
  case "$_line" in *stale_*) _STALE=1 ;; esac
  if [ "$_first" = "PLAN" ] && case " $_line " in *" teamcreate_force_"*) true ;; *) false ;; esac; then
    _SLASH_PRE=1
    continue
  fi
  if [ "$_first" != "IDLE" ]; then
    _log "NOT_IDLE_SKIP state=${_first:-empty}"
    exit 0
  fi
done <<EOF_DIRS
$_DIRS
EOF_DIRS

# R4·ROOF(구 RALPH) 판정 + 보관 이동 — 공용 lib (phase_guard.sh 와 같은 규칙)
_PEA_LIB="$(dirname "${BASH_SOURCE[0]}")/lib/pipeline_entry_archive.sh"
# shellcheck source=/dev/null
if [ -f "$_PEA_LIB" ] && source "$_PEA_LIB" 2>/dev/null && declare -F pea_archive >/dev/null 2>&1; then
  [ "$_SLASH_PRE" -eq 1 ] && _log "SLASH_PREWRITE state=PLAN"
  # 보관과 스탬프는 한 쌍이다 — 보관이 수행된(rc 0) 경우에만 pipeline_start_time·ok_started 를 다시 찍는다 (사이클197 AC-J7)
  if pea_archive "$_UUID" entry_reset "$_VFIRST" "$_STALE"; then
    pea_stamp "$_UUID" || true
  fi
else
  _log "LIB_MISSING lib=${_PEA_LIB}"
fi

exit 0
