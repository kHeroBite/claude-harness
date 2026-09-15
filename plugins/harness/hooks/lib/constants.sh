#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# constants.sh — hook/skill 공용 상수 단일 출처 (F7, jury V4 C)
#
# 이 파일은 .claude/hooks/lib/const.py 와 수치 동기화를 반드시 유지해야 한다.
# (Phase 1: 수동 동기화 + pre-commit lint로 불변식 검증, Phase 2: auto-gen 검토)
#
# 불변식 (절대 위반 금지):
#   LOCK_STALE_TTL_SEC > UX_STALE_DISPLAY_SEC
#   (oio lock 기반 실제 stale 판정 > UX 체감 표시 — 정상 작업이 UX stale로 오탐되어도
#    lock 기반 회수는 발생하지 않아야 함. "LOCK > UX" 원칙)

# 사용법:
#   source "${HARNESS_HOOK_DIR}/lib/constants.sh"
#   [ "$age" -gt "$LOCK_STALE_TTL_SEC" ] && ...

# --- oio / session lifecycle TTL ---
export LOCK_STALE_TTL_SEC=600       # oio app-lock TTL (대형 빌드 10분+ 허용)
export UX_STALE_DISPLAY_SEC=300     # UX stale 표시 임계 (사용자 체감 — LOCK보다 작아야 함)

# --- 팀에이전트 타임아웃 ---
export AGENT_TIMEOUT_DEFAULT=900    # 팀에이전트 기본 타임아웃 (15분)

# --- ACK 2단계 (F2) ---
export ACK_WAIT_SECONDS=15          # shutdown_response 대기 시간
export ACK_POLL_INTERVAL=1          # ACK 폴링 간격 (초)

# --- 불변식 런타임 검증 (source 시점 1회) ---
if [ "${LOCK_STALE_TTL_SEC:-0}" -le "${UX_STALE_DISPLAY_SEC:-0}" ]; then
  echo "❌ [constants.sh] 불변식 위반: LOCK_STALE_TTL_SEC(${LOCK_STALE_TTL_SEC}) <= UX_STALE_DISPLAY_SEC(${UX_STALE_DISPLAY_SEC})" >&2
  return 1 2>/dev/null || exit 1
fi

return 0 2>/dev/null || true
