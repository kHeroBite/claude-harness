#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# oi_route_guard.sh — PreToolUse:Skill hook
# 목적: PLAN/DEV/TEST/DONE 상태에서 oi 미경유 스킬 호출 물리 차단
# 트리거: PreToolUse:Skill
#
# 설계:
#   UserPromptSubmit.sh가 PLAN/DEV/TEST/DONE 상태에서 "💬 [oi] 활성" 메시지로 Skill('oi') 호출을 요청.
#   oi가 실행되면 oi_routed 마커를 생성 → 이후 스킬은 통과.
#   oi 없이 다른 스킬을 호출하면 이 hook이 차단.
#
# 예외 (차단 제외):
#   oi, ox, ostatus, ofinish*, oinit, ocontext — 직접 허용 스킬
#   슬래시 명령 바이패스 스킬 (skill_direct 파일 있음)
#   팀에이전트/서브에이전트

trap 'exit 0' ERR
INPUT=$(timeout 5 cat 2>/dev/null) || INPUT=""
SKILL_NAME=$(echo "$INPUT" | jq -r '(.tool_input.skill // .tool_input.skill_name // empty)' 2>/dev/null)

[[ -z "$SKILL_NAME" ]] && exit 0

# UUID 결정
source "${HARNESS_HOOK_DIR}/lib/session_id.sh"
source "${HARNESS_HOOK_DIR}/lib/state_machine.sh" 2>/dev/null || true
resolve_uuid "$INPUT" || exit 0
[[ -z "$UUID" ]] && exit 0

# 팀에이전트/서브에이전트 스킵
if [[ -n "${PIPELINE_UUID:-}" && "${PIPELINE_UUID:-}" != "$MY_UUID" ]] || \
   [[ "$MY_UUID" != "$UUID" ]]; then
  exit 0
fi

SESSION_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}"

# 사이클46 축① — 반대편 base 미러 (읽는 쪽이 다른 base 를 볼 수 있다)
# 만료된 oi_routed 를 이쪽에서만 지우면 반대편 잔존분이 다음 판정에서 되살아난다.
source "${HARNESS_HOOK_DIR}/lib/session_mirror.sh" 2>/dev/null
type _mirror_delete >/dev/null 2>&1 || _mirror_delete() { :; }

# state 없는 UUID는 서브에이전트 확정 → 스킵
[[ -f "${SESSION_DIR}/state" ]] || exit 0

# F6: state_read 경유 (flock 보호). __LOCK_FAIL__ 시 skip 처리.
CURRENT_STATE=$(state_read "${SESSION_DIR}/state" 2>/dev/null | awk '{print $1}' | tr -d '\r')
[[ "$CURRENT_STATE" == "__LOCK_FAIL__" ]] && exit 0  # lock 경쟁 시 guard skip (차단 보수)
STATUS_FILE="${SESSION_DIR}/status"

# PLAN/DEV/TEST/DONE 상태에서만 적용
case "$CURRENT_STATE" in
  PLAN|DEV|TEST|DONE)
    # status=PAUSE 면 oi 우회 허용 (일시정지 상태에서 직접 스킬 허용)
    if status_has "$STATUS_FILE" PAUSE 2>/dev/null; then
      exit 0
    fi
    ;;
  *) exit 0 ;;
esac

# 직접 허용 스킬 목록 (oi 라우팅 바이패스)
# ok 흐름 정식 단계 (ok_pipeline/ofinish/oinit)는 oi 경유 부적절 — 화이트리스트에 포함 (Phase A 보강 — 2026-05-06)
# ok_pipeline: ok 흐름 정식 단계 (oplan 완료 후 odev/otest/odone 오케스트레이션)
# ofinish: ok 흐름 마무리 단계 (ofinish*로 wildcard 매칭)
# oinit: 정리 (ofinish 내부 호출)
# ointaug: CLAUDE.md 절대 규칙 — 모든 입력의 첫 번째 행동 (PLAN 잔재 시 차단 회귀 방지)
# ok / ox / o1~o5 / oralph: 슬래시 명령 자체 — false positive 방지
case "$SKILL_NAME" in
  oi|ox|o1|o2|o3|o4|o5|ok|ointaug|ostatus|ofinish*|ocontext|oresume|odebug|oinit|oss|oinsights|oretro|oralph|ok_pipeline)
    exit 0
    ;;
esac

# 슬래시 명령 직접 호출 (skill_direct 있음) → 바이패스
if [[ -f "${SESSION_DIR}/skill_direct" ]]; then
  DIRECT_SKILL=$(cat "${SESSION_DIR}/skill_direct" 2>/dev/null)
  if [[ "$DIRECT_SKILL" == "$SKILL_NAME" ]]; then
    exit 0
  fi
fi

# oi_routed 마커 확인: 이 요청에서 oi가 이미 실행되었으면 통과 (TTL 10초 기반)
if [[ -f "${SESSION_DIR}/oi_routed" ]]; then
  _KR_TS=$(cat "${SESSION_DIR}/oi_routed" 2>/dev/null | tr -d '[:space:]')
  _KR_NOW=$(date +%s)
  if [[ "$_KR_TS" =~ ^[0-9]+$ ]] && (( _KR_NOW - _KR_TS < 10 )); then
    # 10초 TTL 이내 — oi가 이미 실행됨, 통과
    exit 0
  else
    # 만료된 마커 삭제
    rm -f "${SESSION_DIR}/oi_routed" 2>/dev/null
    _mirror_delete "${SESSION_DIR}/oi_routed"
  fi
fi

# PLAN/DEV/TEST/DONE 상태에서 oi 미경유 스킬 차단
echo "{\"decision\":\"block\",\"reason\":\"🚫 [oi_route_guard] PLAN/DEV/TEST/DONE 상태에서 Skill('oi') 없이 '${SKILL_NAME}' 직접 호출 차단. Skill('oi')를 먼저 호출하여 입력을 분류하세요.\"}"
exit 2
