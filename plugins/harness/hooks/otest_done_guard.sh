#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# otest_done_guard.sh — otest 완료 증거 검증 (PreToolUse:Agent)
# odone spawn 시 otest 증거파일 없으면 물리 차단
# L-009: trap 'exit 0' ERR 제거 — silent pass 방지 (오류 시 명시적 로그 후 exit 0)

INPUT=$(timeout 5 cat 2>/dev/null) || INPUT=""
TEAM_NAME=$(echo "$INPUT" | jq -r '.tool_input.team_name // empty' 2>/dev/null || echo "")

# logs/hook_input_session_id.log 기록 (메인 vs hook session_id 추적 — 2순위 사전 진단용)
_INPUT_SID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
_RESOLVED_UUID="${PIPELINE_UUID:-${_INPUT_SID}}"
if [[ -n "$_INPUT_SID" ]]; then
  _LOG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${_RESOLVED_UUID}/logs"
  if [[ -d "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${_RESOLVED_UUID}" ]]; then
    mkdir -p "$_LOG_DIR"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [otest_done_guard] input_session_id=${_INPUT_SID} resolved_uuid=${_RESOLVED_UUID}" \
      >> "${_LOG_DIR}/hook_input_session_id.log"
  fi
fi

# 팀에이전트 spawn이 아니면 패스
[[ -z "$TEAM_NAME" ]] && exit 0

# odone spawn인지 확인
AGENT_NAME=$(echo "$INPUT" | jq -r '.tool_input.name // ""' 2>/dev/null || echo "")
echo "$AGENT_NAME" | grep -qE "^odone" || exit 0

# UUID 결정 (L-009: 실패 시 로그 기록 후 명시적 exit 0)
source "${HARNESS_HOOK_DIR}/lib/session_id.sh"
resolve_uuid "$INPUT" 2>/dev/null || UUID="${CLAUDE_SESSION_ID}"
if [[ -z "$UUID" ]]; then
  # UUID 해석 실패 — 차단 불가이지만 로그는 남김 (§(a): session-env/ 외부 경로 사용)
  _WARN_DIR="/tmp/claude_warn"
  mkdir -p "${_WARN_DIR}"
  echo "$(date '+%Y-%m-%d %H:%M:%S') [otest_done_guard] UUID 해석 실패 — odone spawn 허용 (팀명=${TEAM_NAME}, 에이전트=${AGENT_NAME})" >> "${_WARN_DIR}/pipeline_errors.log"
  exit 0
fi
SESSION_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}"
# HOME 폴백 경로: cc-prefix 와 $HOME/.claude 경로 분리 대응 (L-cc-prefix 사고)
HOME_SESSION_DIR="$HOME/.claude/session-env/${UUID}"
# 사이클46 축① — 반대편 base 미러
source "${HARNESS_HOOK_DIR}/lib/session_mirror.sh" 2>/dev/null
type _mirror_file >/dev/null 2>&1 || _mirror_file() { :; }

# O1/O2 분류는 otest 불필요 — 스킵
CLASSIFICATION=$(cat "${SESSION_DIR}/classification" 2>/dev/null || echo "")
# §(a) 준수: classification 빈값이어도 타 세션 UUID 역추적 금지 — fail-closed
# PIPELINE_UUID가 올바르지 않으면 차단 불가 상태로 통과 (O1/O2 판정과 동일)
case "$CLASSIFICATION" in
  O1|O2|"") exit 0 ;;
esac

# HOME 경로 폴백: SESSION_DIR가 /tmp/cc-... 이면 $HOME/.claude에서 evidence 탐색
if [[ ! -f "${SESSION_DIR}/evidence/otest_done" && \
      -f "${HOME_SESSION_DIR}/evidence/otest_done" ]]; then
  mkdir -p "${HOME_SESSION_DIR}/logs"
  echo "$(date '+%Y-%m-%d %H:%M:%S') [otest_done_guard] HOME 경로 폴백 채택 (cc-prefix 분리 감지) uuid=${UUID}" \
    >> "${HOME_SESSION_DIR}/logs/path_fallback.log"
  _mirror_file "${HOME_SESSION_DIR}/logs/path_fallback.log"
  SESSION_DIR="${HOME_SESSION_DIR}"
fi

# otest 완료 증거 파일 확인 (1차: 현재 SESSION_DIR)
if [[ ! -f "${SESSION_DIR}/evidence/otest_done" ]]; then
  # 2차: prompt UUID 폴백 시도 (§(b) 소유권 증명 통과 시만 채택)
  FALLBACK_UUID=$(resolve_uuid_from_prompt "$INPUT")
  if [[ -n "$FALLBACK_UUID" && "$FALLBACK_UUID" != "$UUID" ]]; then
    FALLBACK_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${FALLBACK_UUID}"
    if [[ -f "${FALLBACK_DIR}/evidence/otest_done" ]]; then
      # 폴백 성공: SESSION_DIR 교체 + uuid_fallback.log 기록
      mkdir -p "${FALLBACK_DIR}/logs"
      echo "$(date '+%Y-%m-%d %H:%M:%S') [otest_done_guard] uuid_fallback adopted=${FALLBACK_UUID} input_sid=${UUID} agent=${AGENT_NAME} team=${TEAM_NAME}" \
        >> "${FALLBACK_DIR}/logs/uuid_fallback.log"
      _mirror_file "${FALLBACK_DIR}/logs/uuid_fallback.log"
      SESSION_DIR="$FALLBACK_DIR"
      UUID="$FALLBACK_UUID"
      # L-288 잔류 검증으로 자연스럽게 진행 (이후 코드 변경 없음)
    else
      # 폴백도 evidence 부재 → 기존 차단 로직
      mkdir -p "${SESSION_DIR}/logs"
      echo "$(date '+%Y-%m-%d %H:%M:%S') [otest_done_guard] otest 미수행으로 odone spawn 차단 (classification=${CLASSIFICATION}, uuid=${UUID})" >> "${SESSION_DIR}/logs/pipeline_errors.log"
      _mirror_file "${SESSION_DIR}/logs/pipeline_errors.log"
      source "${HARNESS_HOOK_DIR}/lib/write_error.sh" 2>/dev/null
      log_hook_error "HOOK_BLOCK_OTEST_DONE_GUARD" "Agent" "otest_done 증거파일 없음 — odone spawn 차단 (classification=${CLASSIFICATION})" "${UUID}" 2>/dev/null
      echo '{"decision":"block","reason":"❌ otest 미수행! O3~O5 분류에서는 otest 완료 후 evidence/otest_done 생성 필수. otest를 먼저 실행하세요."}'
      exit 2
    fi
  else
    # 폴백 실패 (PIPELINE_UUID 없거나 §(b) 검증 실패) → 기존 차단 로직
    mkdir -p "${SESSION_DIR}/logs"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [otest_done_guard] otest 미수행으로 odone spawn 차단 (classification=${CLASSIFICATION}, uuid=${UUID})" >> "${SESSION_DIR}/logs/pipeline_errors.log"
    _mirror_file "${SESSION_DIR}/logs/pipeline_errors.log"
    source "${HARNESS_HOOK_DIR}/lib/write_error.sh" 2>/dev/null
    log_hook_error "HOOK_BLOCK_OTEST_DONE_GUARD" "Agent" "otest_done 증거파일 없음 — odone spawn 차단 (classification=${CLASSIFICATION})" "${UUID}" 2>/dev/null
    echo '{"decision":"block","reason":"❌ otest 미수행! O3~O5 분류에서는 otest 완료 후 evidence/otest_done 생성 필수. otest를 먼저 실행하세요."}'
    exit 2
  fi
fi

# L-288: 잔류 evidence 방지 — pipeline_start_time보다 이후에 생성된 증거인지 검증
# pipeline_start_time도 HOME 경로 폴백 (oio MCP는 HOME에 씀)
if [[ ! -f "${SESSION_DIR}/pipeline_start_time" && \
      -f "${HOME_SESSION_DIR}/pipeline_start_time" ]]; then
  PIPELINE_START_FILE="${HOME_SESSION_DIR}/pipeline_start_time"
else
  PIPELINE_START_FILE="${SESSION_DIR}/pipeline_start_time"
fi
OTEST_DONE_FILE="${SESSION_DIR}/evidence/otest_done"
if [[ -f "$PIPELINE_START_FILE" ]]; then
  PIPELINE_START=$(cat "$PIPELINE_START_FILE" 2>/dev/null || echo "0")
  OTEST_DONE_MTIME=$(stat -c %Y "$OTEST_DONE_FILE" 2>/dev/null || echo "0")
  if [[ "$OTEST_DONE_MTIME" -le "$PIPELINE_START" ]]; then
    mkdir -p "${SESSION_DIR}/logs"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [otest_done_guard] 잔류 evidence 감지 — otest_done mtime(${OTEST_DONE_MTIME}) <= pipeline_start(${PIPELINE_START}), odone spawn 차단 (uuid=${UUID})" >> "${SESSION_DIR}/logs/pipeline_errors.log"
    _mirror_file "${SESSION_DIR}/logs/pipeline_errors.log"
    source "${HARNESS_HOOK_DIR}/lib/write_error.sh" 2>/dev/null
    log_hook_error "HOOK_BLOCK_OTEST_DONE_STALE" "Agent" "잔류 evidence 감지 — 이전 파이프라인의 otest_done 증거파일 (classification=${CLASSIFICATION})" "${UUID}" 2>/dev/null
    echo '{"decision":"block","reason":"❌ 잔류 evidence 감지! 이전 파이프라인의 otest_done 증거파일입니다. 현재 파이프라인에서 otest를 다시 실행하세요."}'
    exit 2
  fi
fi

exit 0
