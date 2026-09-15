#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# agent_lifecycle.sh — Agent/TeamCreate 생명주기 통합 관리
# 통합: pane_marker_create.sh + pane_marker_post.sh + team_created_flag.sh
# 등록:
#   PreToolUse:Agent   → BEFORE 스냅샷 (pane_marker_create 기능)
#   PostToolUse:Agent  → 신규 pane 감지 + agents/ 파일 등록 (pane_marker_post 기능)
#   PostToolUse:TeamCreate → team_name 기록 (team_created_flag 기능)

trap 'exit 0' ERR
INPUT=$(timeout 30 cat 2>/dev/null) || INPUT=""
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || echo "")
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
# Pre/Post 구분: tool_response 필드는 PostToolUse에만 존재 (L-262: tool_result → tool_response)
if echo "$INPUT" | jq -e 'has("tool_response")' 2>/dev/null >/dev/null; then
  HOOK_STAGE="post"
elif [[ -n "$INPUT" ]]; then
  HOOK_STAGE="pre"
else
  # INPUT 비어있음 — PreToolUse/PostToolUse 구분 불가 → pre 가정 (안전한 기본값)
  # pre_spawn 파일 존재 여부로 2차 구분 (agent_lifecycle.sh 내부 fallback)
  HOOK_STAGE="pre"
fi

# --- UUID 결정 ---
source "${HARNESS_HOOK_DIR}/lib/session_id.sh"
if ! resolve_uuid "$INPUT" 2>/dev/null; then
  # fallback 1: session_id 직접 사용
  if [[ -n "$SESSION_ID" ]]; then
    UUID="$SESSION_ID"
    MY_UUID="$UUID"
    export UUID MY_UUID
  else
    # fallback 2: §(a) 준수 — PIPELINE_UUID 없으면 fail-closed (타 세션 스캔 금지)
    if [[ -z "$UUID" ]]; then
      exit 0
    fi
    MY_UUID="$UUID"
    export UUID MY_UUID
  fi
fi
[[ -z "$UUID" ]] && exit 0
# 하위 호환
SID="$UUID"
export SID

SESSION_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}"

# 사이클46 축① — 반대편 base 미러 (읽는 쪽이 다른 base 를 볼 수 있다)
source "${HARNESS_HOOK_DIR}/lib/session_mirror.sh" 2>/dev/null
type _mirror_file >/dev/null 2>&1 || _mirror_file() { :; }

# 팀에이전트(PIPELINE_UUID 환경변수 존재)에서는 Agent lifecycle 불필요 — 메인 전용
if [[ -n "${PIPELINE_UUID:-}" ]]; then
  exit 0
fi

# ===== 호출 컨텍스트 판별 =====
# Pre/Post: tool_response 필드 존재 여부로 구분 (PostToolUse에만 존재)
# tool_name으로 Agent vs TeamCreate 구분

case "$TOOL_NAME" in

  # --- Agent ---
  Agent)
    # 팀명 해석은 공용 헬퍼(resolve_team_name)에 위임 — tool_input.team_name → team_name 파일 → 런타임 teams/session-* 단일 디렉토리 → session-${UUID:0:8} 순서로 폴백
    source "${HARNESS_HOOK_DIR}/lib/resolve_team_name.sh" 2>/dev/null
    TEAM_NAME=$(resolve_team_name "$INPUT" "$UUID")
    # F8: name 파라미터 원본 추출 (unnamed fallback 전 검사)
    _RAW_AGENT_NAME=$(echo "$INPUT" | jq -r '.tool_input.name // empty' 2>/dev/null || echo "")
    _SUBAGENT_TYPE=$(echo "$INPUT" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null || echo "")
    AGENT_NAME="${_RAW_AGENT_NAME:-unnamed}"
    echo "$(date +%T) AGENT_DBG: TOOL=${TOOL_NAME} STAGE=${HOOK_STAGE} UUID=${UUID} TEAM=${TEAM_NAME} NAME=${AGENT_NAME} SUBTYPE=${_SUBAGENT_TYPE} INPUT_LEN=${#INPUT}" >> "${SESSION_DIR}/hook_debug.log" 2>/dev/null
    _mirror_file "${SESSION_DIR}/hook_debug.log"

    # --- F8: unnamed Agent() 물리 차단 (PreToolUse:Agent 전용) ---
    # 파이프라인 활성(PLAN/DEV/TEST)에서 name 파라미터 부재 → block
    # 예외: subagent_type ∈ {general-purpose, Explore} 메인 일회성 호출
    if [[ "$HOOK_STAGE" == "pre" && -z "$_RAW_AGENT_NAME" ]]; then
      _F8_STATE=$(state_read "${SESSION_DIR}/state" 2>/dev/null | awk '{print $1}' || echo "IDLE")
      [[ "$_F8_STATE" == "__LOCK_FAIL__" ]] && _F8_STATE="IDLE"  # F6 fallback
      case "$_F8_STATE" in
        PLAN|DEV|TEST|OK)
          case "$_SUBAGENT_TYPE" in
            general-purpose|Explore)
              : ;;  # 예외: 메인 일회성 호출 허용
            *)
              echo "{\"decision\":\"block\",\"reason\":\"🚫 [F8/V6] 파이프라인 활성(${_F8_STATE}) 중 Agent() 호출에 name 파라미터 필수. subagent_type=${_SUBAGENT_TYPE}. 예: Agent(name=\\\"odev-1\\\", subagent_type=\\\"...\\\")\"}"
              exit 2
              ;;
          esac
          ;;
      esac
    fi

    # unnamed suffix 제거 — Pre/Post 간 동일 파일명 보장 필수
    # (suffix 붙이면 Pre 파일을 Post에서 찾지 못함 → agents/ 미등록)

    # Pre/Post 구분: tool_response 기반 + HOOK_STAGE 미설정 시 pre_spawn 파일 존재 여부 fallback
    if [[ -z "${HOOK_STAGE:-}" ]]; then
      PRE_MARKER="${SESSION_DIR}/panes/pre_spawn_${AGENT_NAME}.txt"
      if [[ -f "$PRE_MARKER" ]]; then
        HOOK_STAGE="post"
      else
        HOOK_STAGE="pre"
      fi
    fi

    if [[ "$HOOK_STAGE" == "pre" ]]; then
      # PreToolUse:Agent — BEFORE 스냅샷 저장 (에이전트명 기반 파일)
      mkdir -p "${SESSION_DIR}/panes"
      PRE_FILE="${SESSION_DIR}/panes/pre_spawn_${AGENT_NAME}.txt"
      tmux list-panes -a -F '#{pane_id}' 2>/dev/null | sort > "$PRE_FILE"

    else
      # PostToolUse:Agent — 신규 pane 감지 + agents/ 파일 등록
      if [[ "$AGENT_NAME" == unnamed* ]]; then
        # unnamed 에이전트: 가장 최신 pre_spawn_unnamed 파일 사용
        PRE_FILE=$(ls -t ${SESSION_DIR}/panes/pre_spawn_unnamed*.txt 2>/dev/null | head -1)
      else
        PRE_FILE="${SESSION_DIR}/panes/pre_spawn_${AGENT_NAME}.txt"
      fi
      [[ -z "$PRE_FILE" || ! -f "$PRE_FILE" ]] && exit 0

      # NEW_PANES 감지 — 최대 5회 2초 간격 retry (기본 총 10초)
      # NTFS_WSL 환경(마운트 경로 /mnt/ 감지) 시 추가 5회 2초 (총 20초)
      _IS_NTFS_WSL=0
      [[ "$(pwd 2>/dev/null)" == /mnt/* || "${SESSION_DIR}" == /mnt/* ]] && _IS_NTFS_WSL=1
      _MAX_RETRY=5
      [[ "$_IS_NTFS_WSL" == 1 ]] && _MAX_RETRY=10

      NEW_PANES=""
      for _retry in $(seq 1 "$_MAX_RETRY"); do
        CURRENT=$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null | sort)
        NEW_PANES=$(comm -13 "$PRE_FILE" <(echo "$CURRENT") 2>/dev/null)
        [[ -n "$NEW_PANES" ]] && break
        [[ $_retry -lt $_MAX_RETRY ]] && sleep 2
      done

      if [[ -n "$NEW_PANES" ]]; then
        mkdir -p "${SESSION_DIR}/agents"
        # F8: agent_type 추출 ("odev-1" → "odev", "oplan-5-codex" → "oplan")
        _AGENT_TYPE="${AGENT_NAME%%-*}"
        for PANE_ID in $NEW_PANES; do
          [[ -z "$PANE_ID" ]] && continue
          # AGENT_NAME 자체를 파일명으로 사용 (PANE_ID는 파일 내용에 기록)
          printf "pane_id=%s\nteam=%s\nspawned_at=%s\nagent_type=%s\n" \
            "$PANE_ID" "$TEAM_NAME" "$(date +%s)" "$_AGENT_TYPE" \
            > "${SESSION_DIR}/agents/${AGENT_NAME}"
          _mirror_file "${SESSION_DIR}/agents/${AGENT_NAME}"
          # pane_index 파일에 기록 (cleanup_team_panes.sh O(1) 조회용)
          if [ -n "$PANE_ID" ] && [ -n "$SESSION_DIR" ]; then
            mkdir -p "${SESSION_DIR}/panes"
            echo "${PANE_ID}=${AGENT_NAME}" >> "${SESSION_DIR}/panes/pane_index"
            _mirror_file "${SESSION_DIR}/panes/pane_index"
          fi
          echo "✅ 에이전트 등록: ${AGENT_NAME} ($PANE_ID) type=${_AGENT_TYPE}"
        done

      else
        # 방법3: spawn 실패를 stdout으로 출력 → 메인 대화에 표시
        echo "⚠️ [SPAWN_FAIL] ${AGENT_NAME} — pane 미생성 (${_MAX_RETRY}회 retry 후). 재spawn 필요."
        echo "   원인 후보: 다른 활성 파이프라인 충돌 / tmux 세션 한도 초과 / 리소스 부족"
        # 실패 기록도 유지
        echo "$(date +%T) SPAWN_FAIL: AGENT=${AGENT_NAME} TEAM=${TEAM_NAME} UUID=${UUID}" >> "${SESSION_DIR}/hook_debug.log" 2>/dev/null
        _mirror_file "${SESSION_DIR}/hook_debug.log"
        # 실패 마커 생성 — 메인이 agents/ 확인 시 실패 원인 파악 가능
        mkdir -p "${SESSION_DIR}/agents"
        printf "pane_id=\nteam=%s\nspawned_at=%s\nstatus=SPAWN_FAIL\n" \
          "$TEAM_NAME" "$(date +%s)" \
          > "${SESSION_DIR}/agents/${AGENT_NAME}.failed"
        _mirror_file "${SESSION_DIR}/agents/${AGENT_NAME}.failed"
      fi

      rm -f "$PRE_FILE"
    fi
    ;;

  # --- TeamCreate ---
  TeamCreate)
    if [[ "$HOOK_STAGE" == "post" || -z "$HOOK_STAGE" ]]; then
      # PostToolUse:TeamCreate — team_name 기록
      TEAM_NAME=$(echo "$INPUT" | jq -r '.tool_input.team_name // empty' 2>/dev/null || echo "")
      [[ -z "$TEAM_NAME" ]] && exit 0
      mkdir -p "$SESSION_DIR"
      echo "$TEAM_NAME" > "${SESSION_DIR}/team_name"
      _mirror_file "${SESSION_DIR}/team_name"
    fi
    ;;

esac

exit 0
