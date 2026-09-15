#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# session_id.sh v4 — UUID 체계
# MY_UUID = full session_id (UUID, 36자)
# UUID = 메인 UUID (PIPELINE_UUID 환경변수 역참조 결과)

resolve_uuid() {
  # PIPELINE_UUID 환경변수 우선 (팀에이전트 환경)
  if [ -n "${PIPELINE_UUID:-}" ]; then
    UUID="${PIPELINE_UUID}"
    # MY_UUID는 내 세션 ID 그대로 유지 — PIPELINE_UUID로 덮어쓰지 않음
    # MY_UUID는 아래 RAW_SID 추출 또는 이미 설정된 값 사용
    # (메인 에이전트의 UUID와 팀에이전트의 UUID를 구별하기 위함)
    export UUID
    # 하위 호환
    SID="${UUID}"
    export SID
    return 0
  fi
  local INPUT="${1:-}"
  local RAW_SID
  RAW_SID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
  RAW_SID=$(echo "$RAW_SID" | tr -d '[:space:]')
  if [[ -z "$RAW_SID" ]]; then
    echo "ERROR: session_id 없음 — hook JSON에서 추출 불가" >&2
    return 1
  fi
  MY_UUID="$RAW_SID"
  UUID="$MY_UUID"
  export UUID MY_UUID
  # 하위 호환
  SID="$UUID"
  MY_SID="$MY_UUID"
  MY_SID_PREFIX="$MY_UUID"
  export SID MY_SID MY_SID_PREFIX
  return 0
}

# is_main_session(): PIPELINE_UUID 없으면 메인
is_main_session() {
  [[ -z "${PIPELINE_UUID:-}" ]]
}

# 하위 호환 alias
resolve_sid() {
  resolve_uuid "$@"
}
resolve_short_sid() {
  resolve_uuid "$1"
  SHORT_SID="$UUID"
  export SHORT_SID
}

# resolve_uuid_from_prompt $INPUT
# 팀에이전트 spawn prompt에서 PIPELINE_UUID 추출 후 §(b) 소유권 증명
# stdout: 검증 통과한 UUID 또는 빈 문자열
# return: 0 (성공) | 1 (실패)
resolve_uuid_from_prompt() {
  local INPUT="$1"
  local PROMPT TEAM_NAME PROMPT_UUID
  PROMPT=$(echo "$INPUT" | jq -r '.tool_input.prompt // empty' 2>/dev/null) || return 1
  TEAM_NAME=$(echo "$INPUT" | jq -r '.tool_input.team_name // empty' 2>/dev/null) || return 1
  [[ -z "$PROMPT" || -z "$TEAM_NAME" ]] && return 1

  # 36자 UUID 정규식 추출 (PIPELINE_UUID=<UUID> 패턴)
  PROMPT_UUID=$(echo "$PROMPT" | grep -oE 'PIPELINE_UUID=[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1 | cut -d= -f2)
  [[ -z "$PROMPT_UUID" ]] && return 1

  # §(b) 소유권 증명: team_name 파일 존재 + tool_input.team_name 일치
  local TEAM_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${PROMPT_UUID}/team_name"
  [[ ! -f "$TEAM_FILE" ]] && return 1
  local STORED_TEAM
  STORED_TEAM=$(tr -d '[:space:]' < "$TEAM_FILE" 2>/dev/null)
  [[ "$STORED_TEAM" != "$TEAM_NAME" ]] && return 1

  echo "$PROMPT_UUID"
  return 0
}

# V5-a (C1): 원자적 state 파일 쓰기 유틸리티 (flock -x + tmpfile→rename)
#
# L-362 엄수 — flock 블록 안 I/O 수집/계산 절대 금지:
#   ● lock 블록 "밖": 부모 디렉토리 보장, 임시 파일 쓰기 (데이터 수집 전부)
#   ● lock 블록 "안": mv(rename) 단일 시스템콜 — I/O 수집 없음
# 동시성 2건 시도 시 race 없이 마지막 쓰기만 반영, 원자적 교체(atomic replace) 보장.
state_write() {
  local STATE_FILE="$1"
  local NEW_VALUE="$2"
  local LOCK_FILE="${STATE_FILE}.lock"
  local TMP_FILE="${STATE_FILE}.tmp.$$"
  # --- L-362: 수집/계산/I/O 전부 lock 밖에서 수행 ---
  local _PARENT
  _PARENT=$(dirname "$STATE_FILE")
  mkdir -p "$_PARENT" 2>/dev/null || true
  printf '%s\n' "$NEW_VALUE" > "$TMP_FILE" || { rm -f "$TMP_FILE"; return 1; }
  # --- lock 블록: rename (원자적 교체)만 수행 ---
  (
    flock -x -w 5 200 || { rm -f "$TMP_FILE"; return 1; }
    mv -f "$TMP_FILE" "$STATE_FILE"
  ) 200>"$LOCK_FILE"
  local _RC=$?
  # lock 실패/mv 실패 시 잔여 임시파일 청소
  [ -f "$TMP_FILE" ] && rm -f "$TMP_FILE"
  # === 사이클46 축② — 반대편 base 미러 (CLAUDE_CONFIG_DIR ⇄ $HOME/.claude) ===
  # ★lock 블록 종료 후 · 쓰기 성공(_RC=0) 시에만★ 호출한다 (미러 불변식 3 — flock 미획득).
  # _mirror_file 은 항상 rc=0 이므로 원 쓰기 결과를 훼손하지 않는다 (불변식 1 — fail-soft).
  if [ "$_RC" -eq 0 ]; then
    if ! declare -f _mirror_file >/dev/null 2>&1; then
      _SID_MIRROR_LIB="$(dirname "${BASH_SOURCE[0]}")/session_mirror.sh"
      # shellcheck source=/dev/null
      [ -f "$_SID_MIRROR_LIB" ] && . "$_SID_MIRROR_LIB" 2>/dev/null
    fi
    declare -f _mirror_file >/dev/null 2>&1 && _mirror_file "$STATE_FILE"
  fi
  # 성공 시 Windows Terminal 타이틀바 즉시 갱신 (tmux rename-window 경유)
  # state 첫 토큰만 추출 (예: "IDLE 89f0... 2026-..." → "IDLE")
  if [ "$_RC" -eq 0 ]; then
    local _TITLE_LIB="$(dirname "${BASH_SOURCE[0]}")/set_terminal_title.sh"
    if [ -f "$_TITLE_LIB" ]; then
      # shellcheck source=/dev/null
      source "$_TITLE_LIB"
      local _STATE_TOKEN
      _STATE_TOKEN=$(echo "$NEW_VALUE" | awk '{print $1}')
      set_terminal_title "$_STATE_TOKEN" 2>/dev/null || true
    fi
  fi
  return $_RC
}

# C-01: 원자적 state 파일 읽기 유틸리티 (공유 flock 기반)
# F6 (jury V1/critic-B S-7): flock 실패 시 허위 "IDLE" 반환 금지 → "__LOCK_FAIL__" 반환.
# 호출자는 반드시 __LOCK_FAIL__를 명시 감지하여 재시도/현상유지/로깅 처리해야 한다.
#   - state 파일 부재/읽기 실패 → "IDLE" (정상 초기 상태)
#   - flock 획득 실패 → "__LOCK_FAIL__" (경쟁 중이므로 재시도 또는 skip)
state_read() {
  local STATE_FILE="$1"
  local LOCK_FILE="${STATE_FILE}.lock"
  mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
  (
    flock -s -w 5 200 || { echo "__LOCK_FAIL__"; exit 2; }
    cat "$STATE_FILE" 2>/dev/null || echo "IDLE"
  ) 200>"$LOCK_FILE"
}
