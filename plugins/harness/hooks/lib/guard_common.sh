#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# guard_common.sh — Hook Guard 공통 유틸리티
# 용도: write_guard.sh 분리 시 4개 파일 공통 로직 단일화
# 사용: source "${HARNESS_HOOK_DIR}/lib/guard_common.sh"
#
# 제공 함수:
#   gc_read_input()       — stdin JSON 읽기 + tool_name 추출
#   gc_is_team_agent()    — 팀에이전트/서브에이전트 판별
#   gc_get_state()        — UUID 기반 state 파일 읽기
#   gc_is_main_session()  — 메인 세션 여부 (PIPELINE_UUID 미존재)
#   gc_block()            — 차단 JSON 출력 + exit 2
#   gc_perf_start()       — 성능 측정 시작 (HOOK_PERF=1 시만 활성)
#   gc_perf_end()         — 성능 측정 종료 + 로그

# --- 공통 변수 ---
_GC_CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
_GC_SESSION_ENV="${_GC_CLAUDE_DIR}/session-env"

# --- stdin JSON 읽기 + tool_name 추출 ---
# 사용: gc_read_input → $GC_INPUT, $GC_TOOL_NAME 설정
gc_read_input() {
  GC_INPUT=$(timeout 2 cat 2>/dev/null) || GC_INPUT=""
  GC_TOOL_NAME=$(echo "$GC_INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || GC_TOOL_NAME=""
  export GC_INPUT GC_TOOL_NAME
}

# --- UUID 로드 (session_id.sh 의존) ---
# 사용: gc_load_uuid → $UUID, $MY_UUID 설정. 실패 시 exit 0.
gc_load_uuid() {
  local _INPUT="${1:-$GC_INPUT}"
  source "${HARNESS_HOOK_DIR}/lib/session_id.sh"
  if ! resolve_uuid "$_INPUT" 2>/dev/null; then
    exit 0
  fi
  [[ -z "${UUID:-}" ]] && exit 0
  GC_SESSION_DIR="${_GC_SESSION_ENV}/${UUID}"
  export GC_SESSION_DIR
}

# --- 팀에이전트/서브에이전트 판별 ---
# 반환: 0=팀에이전트, 1=메인
gc_is_team_agent() {
  # PIPELINE_UUID 있고 내 UUID와 다르면 → 팀에이전트
  if [[ -n "${PIPELINE_UUID:-}" && "${PIPELINE_UUID:-}" != "${MY_UUID:-}" ]]; then
    return 0
  fi
  # MY_UUID와 UUID가 다르면 → 팀에이전트
  if [[ "${MY_UUID:-}" != "${UUID:-}" ]]; then
    return 0
  fi
  # 내 UUID에 state 파일 없으면 → 서브에이전트
  if [[ ! -f "${_GC_SESSION_ENV}/${MY_UUID:-}/state" ]]; then
    return 0
  fi
  return 1
}

# --- state 파일 읽기 ---
# 사용: gc_get_state → $GC_STATE (IDLE/OK/PLAN/DEV/TEST/DONE/FINISH)
gc_get_state() {
  local _UUID="${1:-${UUID:-}}"
  local _STATE_FILE="${_GC_SESSION_ENV}/${_UUID}/state"
  source "${HARNESS_HOOK_DIR}/lib/session_id.sh" 2>/dev/null || true
  GC_STATE=$(state_read "$_STATE_FILE" 2>/dev/null | awk '{print $1}') || GC_STATE=""
  GC_STATE="${GC_STATE:-IDLE}"
  export GC_STATE
}

# --- 메인 세션 여부 ---
# 반환: 0=메인, 1=팀에이전트
gc_is_main_session() {
  [[ -z "${PIPELINE_UUID:-}" ]]
}

# --- 차단 JSON 출력 + exit 2 ---
# 사용: gc_block "차단 이유 메시지"
gc_block() {
  local _REASON="${1:-차단됨}"
  # JSON 특수문자 이스케이프 (큰따옴표, 백슬래시)
  local _ESC
  _ESC=$(echo "$_REASON" | sed 's/\\/\\\\/g; s/"/\\"/g')
  echo "{\"decision\":\"block\",\"reason\":\"${_ESC}\"}"
  exit 2
}

# --- 성능 측정 ---
# 사용: HOOK_PERF=1 환경변수 설정 시 활성화
# gc_perf_start "hook_name" → $_GC_PERF_START 설정
# gc_perf_end "hook_name"   → /tmp/hook_perf.log에 기록
gc_perf_start() {
  if [[ "${HOOK_PERF:-0}" == "1" ]]; then
    _GC_PERF_HOOK="${1:-unknown}"
    _GC_PERF_START=$SECONDS
    export _GC_PERF_START _GC_PERF_HOOK
  fi
}

gc_perf_end() {
  if [[ "${HOOK_PERF:-0}" == "1" && -n "${_GC_PERF_START:-}" ]]; then
    local _ELAPSED=$(( SECONDS - _GC_PERF_START ))
    local _HOOK="${1:-${_GC_PERF_HOOK:-unknown}}"
    echo "[PERF] ${_HOOK}: ${_ELAPSED}s ($(date +%H:%M:%S))" >> /tmp/hook_perf.log 2>/dev/null || true
  fi
}
