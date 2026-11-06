#!/bin/bash
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
source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/session_id.sh"
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
source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/session_mirror.sh" 2>/dev/null
declare -F _mirror_file >/dev/null 2>&1 || _mirror_file() { :; }

# O1/O2 분류는 otest 불필요 — 스킵
CLASSIFICATION=$(cat "${SESSION_DIR}/classification" 2>/dev/null || echo "")
# §(a) 준수: classification 빈값이어도 타 세션 UUID 역추적 금지 — fail-closed
# PIPELINE_UUID가 올바르지 않으면 차단 불가 상태로 통과 (O1/O2 판정과 동일)
case "$CLASSIFICATION" in
  O1|O2|"") exit 0 ;;
esac

# --- 자원 축별 완료 마커 (2026-10-04 — otest 데스크톱/모바일 병렬 허용) ---
# 데스크톱 otest(otest-N)와 모바일 otest(otest-m-N)가 병렬로 돌면 먼저 끝난 쪽만으로
# odone 이 열리면 안 된다. 모바일 축이 이번 파이프라인에 있었으면 otest_done_m 을 추가로 요구한다.
# 규칙 단일 출처: lib/otest_axis.sh (이 블록은 요구를 늘리기만 한다 — 기존 otest_done 검증은 아래 그대로)
source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/otest_axis.sh" 2>/dev/null
if declare -F otest_axis_required_markers >/dev/null 2>&1; then
  _AX_START=$(cat "${SESSION_DIR}/pipeline_start_time" 2>/dev/null || cat "${HOME_SESSION_DIR}/pipeline_start_time" 2>/dev/null || echo "")
  _AX_START=$(echo "$_AX_START" | tr -d '[:space:]')
  [[ "$_AX_START" =~ ^[0-9]+$ ]] || _AX_START=""
  # otest_axes(리드 선언)가 있는 쪽 base 를 우선 채택 — 두 base 를 합치면 선언 없는 쪽의
  # 기본값(otest_done)이 섞여 모바일 단독 선언이 무력화된다. 모바일 흔적은 양쪽 모두에서 수집한다.
  _AX_REQ_ALL="$(otest_axis_required_markers "$SESSION_DIR" "$_AX_START") $(otest_axis_required_markers "$HOME_SESSION_DIR" "$_AX_START")"
  _AX_REQ="$_AX_REQ_ALL"
  for _ax_d in "$SESSION_DIR" "$HOME_SESSION_DIR"; do
    if _otest_axis_fresh "${_ax_d}/evidence/otest_axes" "$_AX_START"; then
      _AX_REQ="$(otest_axis_required_markers "$_ax_d" "$_AX_START")"
      [[ " $_AX_REQ_ALL " == *" otest_done_m "* ]] && _AX_REQ="${_AX_REQ} otest_done_m"
      [[ " $_AX_REQ_ALL " == *" otest_done_w "* ]] && _AX_REQ="${_AX_REQ} otest_done_w"
      break
    fi
  done
  if [[ " $_AX_REQ " == *" otest_done_m "* ]]; then
    _AX_M_OK=0
    for _ax_d in "$SESSION_DIR" "$HOME_SESSION_DIR"; do
      if _otest_axis_fresh "${_ax_d}/evidence/otest_done_m" "$_AX_START" && [[ -s "${_ax_d}/evidence/otest_done_m" ]]; then
        _AX_M_OK=1; break
      fi
    done
    if [[ "$_AX_M_OK" -eq 0 ]]; then
      mkdir -p "${SESSION_DIR}/logs"
      echo "$(date '+%Y-%m-%d %H:%M:%S') [otest_done_guard] 모바일 축 otest_done_m 부재/잔류 — odone spawn 차단 (req=${_AX_REQ}, uuid=${UUID})" >> "${SESSION_DIR}/logs/pipeline_errors.log"
      _mirror_file "${SESSION_DIR}/logs/pipeline_errors.log"
      source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/write_error.sh" 2>/dev/null
      log_hook_error "HOOK_BLOCK_OTEST_DONE_GUARD" "Agent" "모바일 축 otest_done_m 없음 — odone spawn 차단 (classification=${CLASSIFICATION})" "${UUID}" 2>/dev/null
      echo '{"decision":"block","reason":"❌ 모바일 축 otest 미완료! 이번 파이프라인에 모바일 otest(otest-m-N)가 있었으므로 evidence/otest_done_m 이 필요합니다(비어 있지 않고 이번 파이프라인 이후 생성). 데스크톱 otest 완료(otest_done)만으로는 odone 에 진입할 수 없습니다. 모바일 otest 완료를 기다리세요."}'
      exit 2
    fi
  fi
  # 웹 축(2026-10-16 가산): 웹 흔적/선언이 있으면 otest_done_w 필수. 데스크톱 마커를 대체하지 않는다.
  if [[ " $_AX_REQ " == *" otest_done_w "* ]]; then
    _AX_W_OK=0
    for _ax_d in "$SESSION_DIR" "$HOME_SESSION_DIR"; do
      if _otest_axis_fresh "${_ax_d}/evidence/otest_done_w" "$_AX_START" && [[ -s "${_ax_d}/evidence/otest_done_w" ]]; then
        _AX_W_OK=1; break
      fi
    done
    if [[ "$_AX_W_OK" -eq 0 ]]; then
      mkdir -p "${SESSION_DIR}/logs"
      echo "$(date '+%Y-%m-%d %H:%M:%S') [otest_done_guard] 웹 축 otest_done_w 부재/잔류 — odone spawn 차단 (req=${_AX_REQ}, uuid=${UUID})" >> "${SESSION_DIR}/logs/pipeline_errors.log"
      _mirror_file "${SESSION_DIR}/logs/pipeline_errors.log"
      source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/write_error.sh" 2>/dev/null
      log_hook_error "HOOK_BLOCK_OTEST_DONE_GUARD" "Agent" "웹 축 otest_done_w 없음 — odone spawn 차단 (classification=${CLASSIFICATION})" "${UUID}" 2>/dev/null
      echo '{"decision":"block","reason":"❌ 웹 축 otest 미완료! 이번 파이프라인에 웹 otest(otest-w-N)가 있었으므로 evidence/otest_done_w 가 필요합니다(비어 있지 않고 이번 파이프라인 이후 생성). 다른 축의 완료 마커로는 대체되지 않습니다. 웹 otest 완료를 기다리세요."}'
      exit 2
    fi
  fi
  if [[ " $_AX_REQ " != *" otest_done "* ]]; then
    # 리드가 otest_axes 에 mobile/web 만 선언한 단독 파이프라인 — otest_done 요구 없음
    exit 0
  fi
fi

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
      source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/write_error.sh" 2>/dev/null
      log_hook_error "HOOK_BLOCK_OTEST_DONE_GUARD" "Agent" "otest_done 증거파일 없음 — odone spawn 차단 (classification=${CLASSIFICATION})" "${UUID}" 2>/dev/null
      echo '{"decision":"block","reason":"❌ otest 미수행! O3~O5 분류에서는 otest 완료 후 evidence/otest_done 생성 필수. otest를 먼저 실행하세요."}'
      exit 2
    fi
  else
    # 폴백 실패 (PIPELINE_UUID 없거나 §(b) 검증 실패) → 기존 차단 로직
    mkdir -p "${SESSION_DIR}/logs"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [otest_done_guard] otest 미수행으로 odone spawn 차단 (classification=${CLASSIFICATION}, uuid=${UUID})" >> "${SESSION_DIR}/logs/pipeline_errors.log"
    _mirror_file "${SESSION_DIR}/logs/pipeline_errors.log"
    source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/write_error.sh" 2>/dev/null
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
    source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/write_error.sh" 2>/dev/null
    log_hook_error "HOOK_BLOCK_OTEST_DONE_STALE" "Agent" "잔류 evidence 감지 — 이전 파이프라인의 otest_done 증거파일 (classification=${CLASSIFICATION})" "${UUID}" 2>/dev/null
    echo '{"decision":"block","reason":"❌ 잔류 evidence 감지! 이전 파이프라인의 otest_done 증거파일입니다. 현재 파이프라인에서 otest를 다시 실행하세요."}'
    exit 2
  fi
fi

exit 0
