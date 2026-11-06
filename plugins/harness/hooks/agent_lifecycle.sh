#!/bin/bash
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
source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/session_id.sh"
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
source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/session_mirror.sh" 2>/dev/null
declare -F _mirror_file >/dev/null 2>&1 || _mirror_file() { :; }

# 팀에이전트(PIPELINE_UUID 환경변수 존재)에서는 Agent lifecycle 불필요 — 메인 전용
if [[ -n "${PIPELINE_UUID:-}" ]]; then
  exit 0
fi

# ===== 사이클182 A: post 단계 pre_spawn 부재 시 폴백 등록 =====
# pre_spawn 이 없으면(PreToolUse 가 정체로 예산 초과) 예전에는 흔적 없이 exit 0 → agents/ 미등록 → sweep 이 고아로 오판했다.
# 여기서는 pane 의 프로세스 인자를 보고 --agent-id <이름>@ 와 --parent-session-id <자기 UUID> 가 ★둘 다★ 맞는 pane 만 인정한다.
# (sweep 과 같은 추출 규칙. 이름만 같은 타 세션 pane 은 등록하지 않는다.)
# 하네스 timeout 을 고려해 최대 2회(1초 간격)만 본다. 어떤 결과든 hook_debug.log 에 1행을 남긴다.
_post_fallback_register() {
  local _dbg="${SESSION_DIR}/hook_debug.log"
  local _try _pane _pid _args _aid _par _found="" _pids _panes _psout
  mkdir -p "${SESSION_DIR}/agents" 2>/dev/null || true
  echo "$(date +%T) AGENT_DBG: PRE_MISSING NAME=${AGENT_NAME} TEAM=${TEAM_NAME} UUID=${UUID} — ps 폴백 시도" >> "$_dbg" 2>/dev/null || true
  for _try in 1 2; do
    _panes=$(timeout 2 tmux list-panes -a -F '#{pane_id} #{pane_pid}' 2>/dev/null) || _panes=""
    _pids=$(printf '%s\n' "$_panes" | awk 'NF==2{print $2}' | paste -sd, -) || _pids=""
    if [[ -n "$_pids" ]]; then
      # ★-ww 필수★ 열 폭에 잘리면 --parent-session-id 가 사라진다. ps 는 1회로 모든 pane_pid 를 본다.
      # 죽은 pid 가 섞이면 ps 가 rc=1 이지만 나머지 출력은 유효하다 → 출력을 버리지 않는다.
      _psout=$(timeout 2 ps -ww -o pid=,args= -p "$_pids" 2>/dev/null) || true
      while read -r _pane _pid; do
        [[ -z "$_pane" || -z "$_pid" ]] && continue
        _args=$(printf '%s\n' "$_psout" | awk -v p="$_pid" '$1==p{$1="";sub(/^ /,"");print;exit}') || _args=""
        case "$_args" in *--agent-id*) : ;; *) continue ;; esac
        _aid=$(printf '%s' "$_args" | sed -n 's/.*--agent-id[ =]\([^ ]*\).*/\1/p' | head -1) || _aid=""
        _par=$(printf '%s' "$_args" | sed -n 's/.*--parent-session-id[ =]\([^ ]*\).*/\1/p' | head -1) || _par=""
        if [[ "${_aid%%@*}" == "$AGENT_NAME" && -n "$_par" && "$_par" == "$UUID" ]]; then
          _found="$_pane"
          break
        fi
      done <<< "$_panes"
    fi
    [[ -n "$_found" ]] && break
    if [[ $_try -lt 2 ]]; then sleep 1; fi
  done

  if [[ -n "$_found" ]]; then
    printf "pane_id=%s\nteam=%s\nspawned_at=%s\nagent_type=%s\nsource=post_fallback\n" \
      "$_found" "$TEAM_NAME" "$(date +%s)" "${AGENT_NAME%%-*}" \
      > "${SESSION_DIR}/agents/${AGENT_NAME}" 2>/dev/null || true
    _mirror_file "${SESSION_DIR}/agents/${AGENT_NAME}"
    # 등록이 됐으면 예전 실패 마커는 지운다(남아 있으면 중복 이름 가드가 실패로 오인한다).
    rm -f "${SESSION_DIR}/agents/${AGENT_NAME}.failed" 2>/dev/null || true
    mkdir -p "${SESSION_DIR}/panes" 2>/dev/null || true
    echo "${_found}=${AGENT_NAME}" >> "${SESSION_DIR}/panes/pane_index" 2>/dev/null || true
    _mirror_file "${SESSION_DIR}/panes/pane_index"
    echo "$(date +%T) AGENT_DBG: POST_FALLBACK_REGISTERED NAME=${AGENT_NAME} PANE=${_found} TEAM=${TEAM_NAME} UUID=${UUID}" >> "$_dbg" 2>/dev/null || true
    echo "✅ 에이전트 등록(폴백): ${AGENT_NAME} (${_found}) — pre_spawn 부재, 프로세스 인자로 확인"
  else
    printf "pane_id=\nteam=%s\nspawned_at=%s\nstatus=PRE_MISSING_NO_PANE\n" \
      "$TEAM_NAME" "$(date +%s)" \
      > "${SESSION_DIR}/agents/${AGENT_NAME}.failed" 2>/dev/null || true
    _mirror_file "${SESSION_DIR}/agents/${AGENT_NAME}.failed"
    echo "$(date +%T) SPAWN_UNVERIFIED: AGENT=${AGENT_NAME} TEAM=${TEAM_NAME} UUID=${UUID} why=PRE_MISSING_NO_PANE (in-process 팀원이면 pane 이 없어 정상)" >> "$_dbg" 2>/dev/null || true
    echo "⚠️ [SPAWN_UNVERIFIED] ${AGENT_NAME} — pre_spawn 부재 + 일치하는 pane 없음. in-process 팀원이면 정상, pane 팀원이면 등록 누락이므로 확인 필요."
  fi
  _mirror_file "$_dbg"
}

# ===== 호출 컨텍스트 판별 =====
# Pre/Post: tool_response 필드 존재 여부로 구분 (PostToolUse에만 존재)
# tool_name으로 Agent vs TeamCreate 구분

case "$TOOL_NAME" in

  # --- Agent ---
  Agent)
    # 팀명 해석은 공용 헬퍼(resolve_team_name)에 위임 — tool_input.team_name → team_name 파일 → 런타임 teams/session-* 단일 디렉토리 → session-${UUID:0:8} 순서로 폴백
    source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/resolve_team_name.sh" 2>/dev/null
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
          # --- [K10-MCP-ONDEMAND-F8 2026-11-06] 온디맨드 MCP 에이전트(mcp-*) 예외 (K10 스스로 ON) ---
          # 통과 조건(전부 충족): name 없음(이 블록 진입 조건), subagent_type 이 mcp- 로 시작하고
          #   뒤에 [A-Za-z0-9._-] 1글자 이상, prompt 에 PIPELINE_UUID= 없음.
          #   full_task_team_guard.sh 의 K7-MCP-ONDEMAND 와 같은 조건이다(team_name 검사는 그쪽이 맡는다).
          _F8_PROMPT=$(echo "$INPUT" | jq -r '.tool_input.prompt // empty' 2>/dev/null || echo "")
          _F8_CASE_TYPE="$_SUBAGENT_TYPE"
          if [[ "$_SUBAGENT_TYPE" =~ ^mcp-[A-Za-z0-9._-]+$ && "$_F8_PROMPT" != *"PIPELINE_UUID="* ]]; then
            _F8_CASE_TYPE="__mcp_ondemand__"
            mkdir -p "${SESSION_DIR}/logs" 2>/dev/null || true
            echo "$(date -Iseconds)|ALLOW_MCP_ONDEMAND_F8|state=${_F8_STATE}|subagent_type=${_SUBAGENT_TYPE}" \
              >> "${SESSION_DIR}/logs/mcp_ondemand_allow.log" 2>/dev/null || true
          fi
          case "$_F8_CASE_TYPE" in
            general-purpose|Explore|__mcp_ondemand__)
              : ;;  # 예외: 메인 일회성 호출 허용 + 온디맨드 MCP 에이전트(K10)
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
      if [[ -z "$PRE_FILE" || ! -f "$PRE_FILE" ]]; then
        # 사이클182 A: pre_spawn 부재(PreToolUse 가 time_budget 초과 등으로 미완)여도 흔적 없이 끝내지 않는다.
        _post_fallback_register
        exit 0
      fi

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
