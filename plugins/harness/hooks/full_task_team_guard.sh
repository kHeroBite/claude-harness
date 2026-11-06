#!/bin/bash
# full_task_team_guard.sh — Agent 도구 호출 시 팀에이전트 위임 정책 강제
# 정책:
#   - 파이프라인 비활성(IDLE/DONE/FINISH): 메인에서 모든 Agent 자유 사용
#   - 파이프라인 활성(OK/PLAN/DEV/TEST): 메인 직접 작업 불가 → 팀에이전트에 위임
#   - 팀에이전트(PIPELINE_UUID): 항상 허용
# L-110: 팀에이전트 프롬프트에 금지 명령 직접 명시 차단

trap 'exit 0' ERR

INPUT=$(timeout 5 cat 2>/dev/null) || INPUT=""
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")

# 프롬프트 추출 (공통)
PROMPT=$(echo "$INPUT" | jq -r '.tool_input.prompt // ""' 2>/dev/null || echo "")

# --- L-110: 금지 명령 직접 명시 차단 (team_name 유무 무관) ---
# 코드 블록 + 설명/규칙 키워드 줄 제외 후 검사 (오탐지 방지)
PROMPT_FILTERED=$(echo "$PROMPT" | sed '/^```/,/^```/d' | grep -vE '(금지|규칙|위반|준수|참조|설명|Skill|SKILL)')
if echo "$PROMPT_FILTERED" | grep -qE '(cmd\.exe\s*/[cCkk]\s+start|cmd\.exe\s*/[cCkk]\s*/start)'; then
  source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/write_error.sh"
  log_hook_error "HOOK_BLOCK_CMD_START" "Agent" "L-110: 프롬프트에 cmd.exe /c start 직접 명시" "$SESSION_ID"
  echo '{"decision":"block","reason":"❌ L-110 위반: 프롬프트에 cmd.exe /c start 직접 명시 금지! WSL 무한 블로킹 원인 (L-022). 정정: 프롬프트에서 cmd.exe /c start 명령 제거 후 [Skill(otest_run) 호출하여 배포] 또는 [프로젝트 루트 INFRA.md 의 배포 절 참조]로 교체하세요."}' | tee /dev/stderr
  exit 2
fi

if echo "$PROMPT_FILTERED" | grep -qE 'curl\s+-s\s+http://localhost:'; then
  source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/write_error.sh"
  log_hook_error "HOOK_BLOCK_CURL_LOCALHOST" "Agent" "L-110: 프롬프트에 curl -s http://localhost: 직접 명시" "$SESSION_ID"
  echo '{"decision":"block","reason":"❌ L-110 위반: 프롬프트에 curl -s http://localhost: 직접 명시 금지! WSL에서 Windows 프로세스 localhost 접근 불가 (exit code 7). 정정: 프롬프트에서 curl 명령 제거 후 [Skill(otest_run) 호출하여 헬스체크] 또는 [프로젝트 루트 INFRA.md 의 배포 절 참조하여 헬스체크]로 교체하세요."}' | tee /dev/stderr
  exit 2
fi

# --- subagent_type 확인 ---
SUBAGENT_TYPE=$(echo "$INPUT" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null || echo "")

# --- [L299-MCP-ONDEMAND 2026-11-06] 온디맨드 MCP 에이전트(mcp-*) 공용 판정 (K7·L-299 예외가 함께 쓴다) ---
# _mcp_ondemand_shape: subagent_type 이 ^mcp-[a-z0-9-]+$, tool_input.name·team_name 비어 있음, prompt 에 PIPELINE_UUID= 없음.
# _mcp_ondemand_def  : 정의 파일 <agents>/<subagent_type>.md 가 실재한다.
#   찾는 곳: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/agents, $HOME/.claude/agents (이름 형식이 / . 을 막으므로 경로 탈출 없음).
#   한계: 프로젝트 전용 정의(<프로젝트>/.claude/agents 에만 있는 파일)는 인정하지 않는다(차단 쪽).
_MCP_OD_NAME=$(echo "$INPUT" | jq -r '.tool_input.name // ""' 2>/dev/null || echo "")
_MCP_OD_TEAM=$(echo "$INPUT" | jq -r '.tool_input.team_name // ""' 2>/dev/null || echo "")
_mcp_ondemand_shape() {
  [[ "$SUBAGENT_TYPE" =~ ^mcp-[a-z0-9-]+$ && -z "$_MCP_OD_NAME" && -z "$_MCP_OD_TEAM" && "$PROMPT" != *"PIPELINE_UUID="* ]]
}
_mcp_ondemand_def() {
  local _d
  for _d in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/agents" "$HOME/.claude/agents"; do
    [[ -f "${_d}/${SUBAGENT_TYPE}.md" ]] && return 0
  done
  return 1
}

# --- 팀에이전트 세션(PIPELINE_UUID)에서는 Agent 호출 전면 차단 (L-299) ---
# 팀에이전트는 하위 Agent를 직접 spawn할 수 없다.
# 메인(team-lead)에게 SPAWN_REQUEST 메시지로 위임해야 한다.
# F-B1 수정 (2026-08-20, otest-1 역라우팅 CONFIRMED): PIPELINE_UUID 환경변수는 실측 결과
# hook 자식 프로세스에 전달되지 않는다(F-COMMIT-1과 동일 원인) → 이 블록이 항상 미스,
# 팀에이전트가 하위 Agent를 무제한 spawn 가능한 상태였다.
# 식별 방법 우선순위:
#   ① PIPELINE_UUID 환경변수(향후 정상 주입 대비, 현재는 대개 unset)
#   ② 프로세스 트리 조상에서 --parent-session-id 파싱(F-COMMIT-1에서 검증된 방식 재사용)
#      + 그 값이 SESSION_ID(내 자기 세션ID)와 다르면 팀에이전트 확정
_L299_PIPELINE_UUID="${PIPELINE_UUID:-}"
# [L299-NEAREST 2026-11-06] 판정 대상은 "이 hook 을 부른 claude 프로세스" 하나다.
#   조상을 올라가다 처음 만난 claude 프로세스(argv0 basename=claude, 또는 argv0·exe 가 */claude/versions/*)에서 멈추고,
#   그 명령줄에 --parent-session-id 또는 --agent-id 가 있을 때만 팀원으로 본다.
#   이전에는 조상 전체에서 --parent-session-id 를 찾아, 팀원이 띄운 독립 headless 세션(claude -p)까지 팀원으로 오판했다.
#   claude 조상이 하나도 없으면 기존 동작(처음 만난 --parent-session-id)을 그대로 쓴다.
# [L299-ARGV 2026-11-06 D-19] claude 조상의 표지는 /proc/<pid>/cmdline 을 NUL 단위 인자 배열로 읽어 판정한다.
#   인자가 정확히 --parent-session-id·--agent-id 이면 다음 인자를 값으로, --옵션=값 형태도 인정한다.
#   이전에는 명령줄을 공백으로 이어 붙여 정규식으로 찾아, claude -p '… --agent-id x …' 처럼 프롬프트 인자 안의 글자로 메인을 팀원으로 오판했다.
# [L299-DASHDASH 2026-11-06 D-20] "--" 에서 탐색을 멈추지 않고 인자 배열 전체를 본다.
#   멈추면 다른 옵션의 값이 "--" 일 때(예: --system-prompt -- --agent-id x) 실제 --agent-id 를 놓치고 폴백도 지워져 fail-open 이 됐다.
#   한계: 다른 옵션의 값이 정확히 그 옵션 글자(--agent-id 등)이면 표지로 읽어 과차단한다(안전 쪽 오판).
# [L299-ALLPOS 2026-11-06 D-21] 인자 배열의 모든 위치 i 를 독립적으로 검사한다. 인덱스는 항상 1씩만 늘린다.
#   a[i]==--parent-session-id 이고 a[i+1] 이 36자 UUID 꼴, 또는 a[i]==--parent-session-id=<UUID 꼴> 이면 PSID 후보.
#   a[i]==--agent-id 이고 a[i+1] 이 비어 있지 않고 공백이 없으면, 또는 a[i]==--agent-id=<그런 값> 이면 AID 후보.
#   값이 무효인 후보는 버리고 탐색을 계속한다. 같은 종류는 첫 유효 후보를 쓰고, 우선순위(PSID 먼저)는 종전과 같다.
#   이전에는 표지 옵션의 값 자리를 건너뛰고 첫 후보만 받아, --system-prompt --parent-session-id --agent-id=a@t 나
#   --parent-session-id bad --parent-session-id <UUID> 에서 실제 표지를 놓쳐 fail-open 이 됐다.
#   한계: 다른 옵션의 값 자리에 유효한 표지 꼴(--agent-id x, --parent-session-id=<UUID> 등)이 오면 표지로 읽어
#   과차단한다(안전 쪽 오판). 표지 옵션의 값이 다른 표지 글자여도(--agent-id --agent-id a@t) 차단 쪽으로 읽는다.
# [L299-PSIDSELF 2026-11-06 D-22] 자기 SESSION_ID 와 같은 PSID 후보는 후보로 받지 않는다.
#   판정: SESSION_ID 와 다른 유효 PSID 후보가 하나라도 있거나, 유효 AID 후보가 하나라도 있으면 팀원이다.
#   이전에는 첫 유효 PSID 가 SESSION_ID 와 같으면 그 값이 뒤의 AID·다른 PSID 를 가려 통과했다(--parent-session-id <SID> --agent-id a@t).
#   메인은 --resume <SID> 로 기동해 argv 에 --parent-session-id·--agent-id 가 없으므로(2026-11-06 메인 cmdline 실측) 메인 오판은 생기지 않는다.
if [[ -z "$_L299_PIPELINE_UUID" ]]; then
  _L299_PID_WALK=$$
  _L299_DEPTH_WALK=0
  _L299_FALLBACK=""
  while [[ $_L299_DEPTH_WALK -lt 10 && -n "$_L299_PID_WALK" && "$_L299_PID_WALK" != "1" ]]; do
    _L299_CMDLINE_WALK=$(tr '\0' ' ' 2>/dev/null < "/proc/${_L299_PID_WALK}/cmdline")
    _L299_ARGV0=$(tr '\0' '\n' 2>/dev/null < "/proc/${_L299_PID_WALK}/cmdline" | head -n 1)
    _L299_EXE=$(readlink "/proc/${_L299_PID_WALK}/exe" 2>/dev/null || true)
    if [[ "${_L299_ARGV0##*/}" == "claude" || "$_L299_ARGV0" =~ /claude/versions/[^/]+$ || "$_L299_EXE" =~ /claude/versions/[^/]+$ ]]; then
      _L299_AV=()
      mapfile -d '' -t _L299_AV 2>/dev/null < "/proc/${_L299_PID_WALK}/cmdline" || _L299_AV=()
      _L299_PSID="" _L299_AID="" _L299_I=1
      while [[ $_L299_I -lt ${#_L299_AV[@]} ]]; do
        _L299_A="${_L299_AV[$_L299_I]}"
        _L299_V=""
        case "$_L299_A" in
          --parent-session-id|--agent-id) _L299_V="${_L299_AV[$((_L299_I+1))]:-}" ;;
          --parent-session-id=*|--agent-id=*) _L299_V="${_L299_A#*=}" ;;
        esac
        case "$_L299_A" in
          --parent-session-id|--parent-session-id=*)
            if [[ -z "$_L299_PSID" && "$_L299_V" =~ ^[0-9a-f-]{36}$ && "$_L299_V" != "$SESSION_ID" ]]; then _L299_PSID="$_L299_V"; fi ;;
          --agent-id|--agent-id=*)
            if [[ -z "$_L299_AID" && -n "$_L299_V" && ! "$_L299_V" =~ [[:space:]] ]]; then _L299_AID="$_L299_V"; fi ;;
        esac
        _L299_I=$((_L299_I+1))
      done
      if [[ "$_L299_PSID" =~ ^[0-9a-f-]{36}$ ]]; then
        _L299_PIPELINE_UUID="$_L299_PSID"
      elif [[ -n "$_L299_AID" && ! "$_L299_AID" =~ [[:space:]] ]]; then
        _L299_PIPELINE_UUID="agent-id:${_L299_AID}"
      fi
      _L299_FALLBACK=""
      break
    fi
    if [[ -z "$_L299_FALLBACK" && "$_L299_CMDLINE_WALK" =~ --parent-session-id[[:space:]]+([0-9a-f-]{36}) ]]; then
      _L299_FALLBACK="${BASH_REMATCH[1]}"
    fi
    # comm(2번째 필드)에 공백이 있으면(예: "tmux: server") $4 가 밀리므로 마지막 ')' 뒤에서 ppid 를 읽는다
    _L299_PID_WALK=$(awk '{sub(/.*\) /, ""); print $2}' "/proc/${_L299_PID_WALK}/stat" 2>/dev/null)
    (( _L299_DEPTH_WALK++ )) || true
  done
  [[ -z "$_L299_PIPELINE_UUID" && -n "$_L299_FALLBACK" ]] && _L299_PIPELINE_UUID="$_L299_FALLBACK"
fi
if [[ -n "$_L299_PIPELINE_UUID" && "$_L299_PIPELINE_UUID" != "$SESSION_ID" ]]; then
  # [L299-MCP-ONDEMAND 2026-11-06] 팀원도 온디맨드 MCP 에이전트는 name·team_name 없는 일반 서브에이전트로 띄울 수 있다.
  #   조건: _mcp_ondemand_shape(형식·name·team_name·PIPELINE_UUID=) + _mcp_ondemand_def(정의 실재). 그 밖은 아래 차단 그대로다.
  #   L-110 금지 명령 블록은 이보다 앞에서 돈다.
  if _mcp_ondemand_shape && _mcp_ondemand_def; then
    mkdir -p "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${SESSION_ID}/logs" 2>/dev/null || true
    echo "$(date -Iseconds)|ALLOW_MCP_ONDEMAND_L299|pipeline_uuid=${_L299_PIPELINE_UUID}|subagent_type=${SUBAGENT_TYPE}" \
      >> "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${SESSION_ID}/logs/mcp_ondemand_allow.log" 2>/dev/null || true
    exit 0
  fi
  source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/write_error.sh" 2>/dev/null || true
  log_hook_error "HOOK_BLOCK_SUBAGENT_SPAWN_L299" "Agent" "팀에이전트(pipeline_uuid=${_L299_PIPELINE_UUID})가 하위 Agent spawn 시도 (L-299)" "${SESSION_ID}" 2>/dev/null || true
  echo '{"decision":"block","reason":"🚫 [L-299] 팀에이전트는 하위 Agent를 직접 spawn할 수 없습니다. 메인(team-lead)에게 SPAWN_REQUEST로 위임하세요."}' | tee /dev/stderr
  exit 2
fi

# --- [K3 2026-11-06] 온디맨드 MCP 에이전트(mcp-*)의 팀원 spawn 금지 (state 무관) ---
# 배경(K8 실측): mcp-* 에 name 또는 team_name 을 주면 tmux 팀원으로 떠서 정의의 mcpServers 가 적용되지 않고,
#   정의 tools 에 SendMessage 가 없어 보고도 못 해 TeammateIdle 가드에 걸린 채 TaskStop 으로만 끝났다.
# 판정: subagent_type 이 ^mcp-[A-Za-z0-9._-]+$ 이고 tool_input.name 또는 tool_input.team_name 이 비어 있지 않으면 차단.
#   name·team_name 이 모두 없는 mcp-* 와 그 밖의 유형은 이 블록과 무관하다(아래 기존 흐름 그대로).
# 순서: L-110·L-299 블록 뒤(그 메시지가 우선), self-heal·state 판정 앞(IDLE 조기 통과보다 먼저).
_K3_NAME=$(echo "$INPUT" | jq -r '.tool_input.name // ""' 2>/dev/null || echo "")
_K3_TEAM=$(echo "$INPUT" | jq -r '.tool_input.team_name // ""' 2>/dev/null || echo "")
if [[ "$SUBAGENT_TYPE" =~ ^mcp-[A-Za-z0-9._-]+$ ]] && [[ -n "$_K3_NAME" || -n "$_K3_TEAM" ]]; then
  source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/write_error.sh" 2>/dev/null || true
  log_hook_error "HOOK_BLOCK_MCP_TEAMMATE" "Agent" "mcp-* 팀원 spawn 차단 (subagent_type=${SUBAGENT_TYPE}, name=${_K3_NAME}, team_name=${_K3_TEAM})" "$SESSION_ID" 2>/dev/null || true
  echo "{\"decision\":\"block\",\"reason\":\"🚫 [K3 mcp-* 팀원 금지] subagent_type=${SUBAGENT_TYPE} 은 name·team_name 없이 일반 서브에이전트로만 띄울 수 있습니다. 팀원으로 띄우면 정의의 mcpServers 가 적용되지 않고 SendMessage 가 없어 보고도 못 합니다. 정정: Agent(subagent_type=\\\"${SUBAGENT_TYPE}\\\", description=..., prompt=...) 처럼 name·team_name 을 빼고 다시 호출하세요.\"}" | tee /dev/stderr
  exit 2
fi

# --- 메인 에이전트: 활성 파이프라인 시에만 team_name 강제 ---
# IDLE/DONE/FINISH → 파이프라인 없음 → 서브에이전트 자유 허용
# OK/PLAN/DEV/TEST → 파이프라인 활성 → team_name 필수
_STATE_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${SESSION_ID}/state"
source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/session_id.sh" 2>/dev/null || true
_STATE=$(state_read "$_STATE_FILE" 2>/dev/null | awk '{print $1}') || _STATE=""

# --- [P1-isolation] team_name 파일 self-heal (2026-04-22) ---
# 목적: team_name 파일이 어떤 이유로(예: _reset_idle 후 경쟁 조건) 사라졌지만,
#       teams/<tool_input.team_name>/config.json의 leadSessionId == 현재 SESSION_ID 이면,
#       해당 팀은 여전히 내 소유 → team_name 파일 복원 후 통과 (L-342 오발 방지).
# 안전 원칙 (CLAUDE.md §세션 격리 불변식):
#   - config.json leadSessionId가 내 UUID와 일치할 때만 복원 (fail-closed)
#   - 다른 세션이 같은 이름을 자기 team_name에 가지고 있지 않아야 함
_SELF_HEAL_TEAM=$(echo "$INPUT" | jq -r '.tool_input.team_name // ""' 2>/dev/null || echo "")
_SELF_HEAL_TEAM_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${SESSION_ID}/team_name"
if [[ -n "$_SELF_HEAL_TEAM" ]] && [[ ! -f "$_SELF_HEAL_TEAM_FILE" ]]; then
  _SELF_HEAL_CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams/${_SELF_HEAL_TEAM}/config.json"
  if [[ -f "$_SELF_HEAL_CFG" ]]; then
    _SELF_HEAL_LEAD=$(jq -r '.leadSessionId // empty' "$_SELF_HEAL_CFG" 2>/dev/null || echo "")
    if [[ "$_SELF_HEAL_LEAD" == "$SESSION_ID" ]]; then
      # 타 세션 claim 확인 (읽기만)
      _SELF_HEAL_OTHER=0 _shd=""
      for _shd in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env"/*/; do
        [[ -d "$_shd" ]] || continue
        _shd_uuid=$(basename "$_shd")
        [[ "$_shd_uuid" == "$SESSION_ID" ]] && continue
        [[ -f "${_shd}team_name" ]] || continue
        if [[ "$(cat "${_shd}team_name" 2>/dev/null | tr -d '\r\n')" == "$_SELF_HEAL_TEAM" ]]; then
          _SELF_HEAL_OTHER=1
          break
        fi
      done
      if [[ $_SELF_HEAL_OTHER -eq 0 ]]; then
        mkdir -p "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${SESSION_ID}" 2>/dev/null
        # 파일 경로 리터럴 명시 (team_name 파일 복원 경로를 자동 검증 스크립트가 정규식으로 매칭)
        echo "$_SELF_HEAL_TEAM" > "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${SESSION_ID}/team_name"
        # 사이클46 축① — 반대편 base 미러
        source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/session_mirror.sh" 2>/dev/null
        declare -F _mirror_file >/dev/null 2>&1 && _mirror_file "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${SESSION_ID}/team_name"
        echo "🔧 [team_name self-heal] ${_SELF_HEAL_TEAM} 복원 (config.json leadSessionId 일치)" >&2
      fi
    fi
  fi
fi

if [[ -z "$_STATE" || "$_STATE" == "IDLE" || "$_STATE" == "DONE" || "$_STATE" == "FINISH" ]]; then
  # 파이프라인 비활성(IDLE/DONE/FINISH) → 서브에이전트 자유 허용
  # --- [v2.1.178+ 마이그레이션] L-342 차단 제거 ---
  # 과거(v2.1.178 미만): TeamCreate로 팀을 먼저 만든 뒤 Agent(name=, team_name=)로 spawn.
  #   → IDLE에서 team_name 파일이 없으면 "TeamCreate 미실행"으로 보고 차단했음(구 L-342).
  # 현재(v2.1.178+, 실측 2026-06-18): TeamCreate/TeamDelete 도구 제거됨.
  #   Agent(name=...) 호출만으로 tmux pane + teams/<팀>/config.json + inboxes/ 가 자동 생성됨(실측 확인).
  #   따라서 team_name 파일 선행 요구는 영구 불충족 조건이 되어 모든 팀에이전트 spawn을 봉쇄함.
  #   → IDLE/DONE/FINISH 에서는 name 파라미터 자유 허용으로 전환.
  # 안전장치: 팀에이전트 내부의 재spawn 차단은 위쪽 PIPELINE_UUID 블록이 이미 담당.
  #           활성 파이프라인(OK/PLAN/DEV/TEST)의 team_name 강제는 아래 블록이 그대로 유지.
  # 출처: code.claude.com/docs/en/agent-teams (TeamCreate/TeamDelete no longer exist, v2.1.178+)
  exit 0
fi

# 활성 ok 파이프라인 (OK/PLAN/DEV/TEST) → team_name 필수
TOOL_TEAM_NAME=$(echo "$INPUT" | jq -r '.tool_input.team_name // ""' 2>/dev/null || echo "")

# --- [K7-MCP-ONDEMAND 2026-11-06] 온디맨드 MCP 에이전트(mcp-*) 일반 서브에이전트 예외 (TODO-040) ---
# 배경: .claude/agents/mcp-*.md 의 mcpServers 는 name 없는 일반 서브에이전트로 띄워야 적용된다.
#   종전에는 아래 team_name 강제 블록 때문에 IDLE/DONE/FINISH 에서만 띄울 수 있었다.
# 통과 조건: 공용 판정 _mcp_ondemand_shape(위 L299-MCP-ONDEMAND 절) — subagent_type ^mcp-[a-z0-9-]+$,
#   tool_input.name·team_name 비어 있음, prompt 에 PIPELINE_UUID= 없음. 정의 실재 검사는 L-299 예외에만 쓴다.
# 순서: L-110 금지 명령 블록과 L-299 팀에이전트 차단 블록은 이 예외보다 앞에서 그대로 돈다.
if _mcp_ondemand_shape; then
  mkdir -p "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${SESSION_ID}/logs" 2>/dev/null || true
  echo "$(date -Iseconds)|ALLOW_MCP_ONDEMAND|state=${_STATE}|subagent_type=${SUBAGENT_TYPE}" \
    >> "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${SESSION_ID}/logs/mcp_ondemand_allow.log" 2>/dev/null || true
  exit 0
fi

if [[ -z "$TOOL_TEAM_NAME" ]]; then
  source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/write_error.sh"
  log_hook_error "HOOK_BLOCK_NO_TEAM_AGENT" "Agent" "파이프라인 활성(${_STATE}) 중 서브에이전트 spawn 시도 차단 (subagent_type=${SUBAGENT_TYPE})" "$SESSION_ID"
  # team_name 파일에서 기존 팀명 읽기 (메시지에 힌트 포함)
  _EXISTING_TEAM_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${SESSION_ID}/team_name"
  _EXISTING_TEAM=""
  [[ -f "$_EXISTING_TEAM_FILE" ]] && _EXISTING_TEAM=$(cat "$_EXISTING_TEAM_FILE" 2>/dev/null | tr -d '\r\n')
  _TEAM_HINT=""
  [[ -n "$_EXISTING_TEAM" ]] && _TEAM_HINT="\\n\\n💡 현재 팀: '${_EXISTING_TEAM}' → team_name=\\\"${_EXISTING_TEAM}\\\" 추가만 하면 됩니다. TeamCreate 재호출 금지 — 팀은 살아있습니다!"
  echo "{\"decision\":\"block\",\"reason\":\"❌ [team_name 파라미터 누락] 파이프라인 활성(${_STATE}) 중 team_name 없이 Agent 호출 금지!${_TEAM_HINT}\\n\\n올바른 호출:\\n  Agent(name=\\\"에이전트명\\\", team_name=\\\"팀이름\\\", subagent_type=\\\"general-purpose\\\", mode=\\\"bypassPermissions\\\", ...)\\n\\n⚠️ TeamCreate를 다시 호출하지 마세요 — 팀은 소멸하지 않습니다. team_name= 파라미터만 추가하세요.\\n\\n💡 oplan_debate/oplan_consult 참가자 네이밍(P-TEAM):\\n  - oplan-1/2/3 (분석가), 비판가-A/B, 배심원-1/2/3, oplan-final (oplan_debate)\\n  - 계획가-1 (opus), 계획가-2 (codex/sonnet) (oplan_consult)\\n  - team_name: \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/session-env/\${UUID}/team_name 파일 참조\"}" | tee /dev/stderr
  exit 2
fi

# --- team_name 있어도 name 없으면 서브에이전트로 실행됨 → 차단 ---
TOOL_NAME_PARAM=$(echo "$INPUT" | jq -r '.tool_input.name // ""' 2>/dev/null || echo "")
if [[ -z "$TOOL_NAME_PARAM" ]]; then
  source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/write_error.sh"
  log_hook_error "HOOK_BLOCK_NO_NAME_PARAM" "Agent" "파이프라인 활성(${_STATE}) 중 name 파라미터 없이 Agent 호출 차단 (team_name=${TOOL_TEAM_NAME})" "$SESSION_ID"
  echo "{\"decision\":\"block\",\"reason\":\"❌ 파이프라인 활성 중 name 파라미터 없이 Agent 호출 금지! name='에이전트명'을 반드시 지정하세요.\\n\\n이유: team_name만 있어도 name 없으면 서브에이전트로 실행됨 (tmux pane 미생성 → pane 추적 불가 → SendMessage 라우팅 불가).\\n\\n올바른 호출:\\n  Agent(name=\\\"oplan-1\\\", team_name=\\\"${TOOL_TEAM_NAME}\\\", subagent_type=\\\"general-purpose\\\", ...)\"}" | tee /dev/stderr
  exit 2
fi

# --- L-DUP1 (2026-08-22 재발방지): 동일 이름 활성 재spawn 차단 ---
# 배경: agent_lifecycle.sh가 agents/${NAME} 파일을 이름 단일 키로 덮어쓰기하므로,
#   동일 이름으로 재spawn하면 이전 인스턴스의 pane 추적 정보가 소실되고
#   이후 SendMessage/shutdown_request가 항상 최신 인스턴스로만 라우팅된다
#   (실측 사고: otest-1을 sonnet→haiku로 재spawn, 1차 pane %10이 추적 불능 상태로 남음).
# 판정: agents/${NAME} 파일이 존재 + 그 안의 pane_id가 tmux에 실제로 살아있으면 차단.
# fail-open: tmux 조회 실패/타임아웃/미가용 시 통과. 모든 분기를 로그로 남긴다.
_DUP_LOG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${SESSION_ID}/logs"
_DUP_LOG_FILE="${_DUP_LOG_DIR}/dup_name_guard.log"
_dup_log() {
  # $1=수준(BLOCKED|WARN|FAIL_OPEN) $2=이유 $3=pane_id(선택)
  mkdir -p "$_DUP_LOG_DIR" 2>/dev/null
  echo "$(date -Iseconds)|$1|$2|agent_name=${TOOL_NAME_PARAM}|pane_id=${3:-}" >> "$_DUP_LOG_FILE" 2>/dev/null || true
}

_DUP_AGENT_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${SESSION_ID}/agents/${TOOL_NAME_PARAM}"
if [[ -f "$_DUP_AGENT_FILE" ]]; then
  # spawn 실패 마커면 대상 아님 (재spawn이 정상 흐름)
  if [[ -f "${_DUP_AGENT_FILE}.failed" ]]; then
    _dup_log "WARN" "failed_marker_present_skip"
  else
    _DUP_SHUTDOWN_SENT=$(grep '^shutdown_sent=' "$_DUP_AGENT_FILE" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
    if [[ "$_DUP_SHUTDOWN_SENT" == "true" ]]; then
      # 종료 절차 진행 중으로 간주 — 차단하지 않고 경고만
      _dup_log "WARN" "shutdown_sent_true_skip"
    else
      _DUP_PANE_ID=$(grep '^pane_id=' "$_DUP_AGENT_FILE" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
      if [[ -z "$_DUP_PANE_ID" ]]; then
        _dup_log "WARN" "no_pane_id_in_agent_file"
      else
        # tmux 조회는 2초 타임아웃 — 실패/미가용 시 fail-open
        # ERR trap이 비영종료 즉시 스크립트를 종료시키므로 if 조건문 안에서 실행해 trap 발동 자체를 막는다.
        # (`cmd || true` 형태는 $?를 0으로 덮어써 RC 판별이 불가능해지므로 사용하지 않는다.)
        _DUP_TMUX_RC=0
        if ! _DUP_TMUX_LIST=$(timeout 2 tmux list-panes -a -F '#{pane_id}' 2>/dev/null); then
          _DUP_TMUX_RC=1
        fi
        if [[ $_DUP_TMUX_RC -ne 0 ]]; then
          _dup_log "FAIL_OPEN" "tmux_query_failed_rc=${_DUP_TMUX_RC}" "$_DUP_PANE_ID"
        else
          if echo "$_DUP_TMUX_LIST" | grep -qxF "$_DUP_PANE_ID"; then
            _dup_log "BLOCKED" "pane_alive" "$_DUP_PANE_ID"
            source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/write_error.sh" 2>/dev/null || true
            log_hook_error "HOOK_BLOCK_DUP_NAME" "Agent" "동일 이름 '${TOOL_NAME_PARAM}' 활성 재spawn 시도 (pane=${_DUP_PANE_ID})" "$SESSION_ID" 2>/dev/null || true
            echo "{\"decision\":\"block\",\"reason\":\"❌ [L-DUP1] 이름 '${TOOL_NAME_PARAM}'은 이미 활성 상태입니다 (pane=${_DUP_PANE_ID} 생존 확인됨).\\n\\n동일 이름 재spawn은 기존 인스턴스의 pane 추적 정보를 덮어써 SendMessage/shutdown_request가 새 인스턴스로만 라우팅되게 만듭니다 (이전 인스턴스는 추적 불능 상태로 남음).\\n\\n대안:\\n  1) 기존 인스턴스를 재사용 — SendMessage(to=\\\"${TOOL_NAME_PARAM}\\\", ...)\\n  2) 다른 이름으로 새로 spawn (예: ${TOOL_NAME_PARAM}-2)\\n  3) 기존 인스턴스 종료를 tmux 실측으로 확인한 뒤 동일 이름 재spawn\\\"}" | tee /dev/stderr
            exit 2
          else
            _dup_log "WARN" "agent_file_exists_but_pane_gone_allow" "$_DUP_PANE_ID"
          fi
        fi
      fi
    fi
  fi
fi

# --- team_name + name 있음 → 팀 존재 여부 확인 후 허용 ---
# 자동 생성 팀명 패턴: session-{UUID앞8자} (예: session-c0b2a994)
_CORRECT_TEAM_NAME="session-$(echo "$SESSION_ID" | cut -c1-8)"
# --- [T3 — RC3-a 완화] 런타임 팀명(프로세스 시작 세션ID 기준) 조회 ---
# 배경: Agent 스키마상 team_name 파라미터는 런타임이 무시(Deprecated)한다.
# 실제 팀 디렉토리는 $CLAUDE_CONFIG_DIR/teams/session-<프로세스 시작 세션ID> 단일 개체이며
# session-{내 SESSION_ID 앞8자}와 다를 수 있다(2026-09-06 실측). 정확히 1개일 때만 채택한다
# (2개 이상/0개는 모호 → 빈값 유지, 기존 _CORRECT_TEAM_NAME 판정만 적용).
_RUNTIME_TEAM_NAME=""
_RUNTIME_TEAM_DIRS=$(ls -d "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams"/session-* 2>/dev/null)
if [[ -n "$_RUNTIME_TEAM_DIRS" ]]; then
  _RUNTIME_TEAM_COUNT=$(echo "$_RUNTIME_TEAM_DIRS" | wc -l)
  if [[ "$_RUNTIME_TEAM_COUNT" -eq 1 ]]; then
    _RUNTIME_TEAM_NAME=$(basename "$_RUNTIME_TEAM_DIRS")
  fi
fi
_TEAM_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams/${TOOL_TEAM_NAME}"

# --- L-NEW (2026-07-10 재발방지): 팀 디렉토리 부재는 "차단할 오류"가 아니라 "곧 자동 생성될 정상 상태" ---
# 배경: v2.1.178+에서 팀은 Agent(name=, team_name=) 호출 시 자동 생성된다.
#   그런데 한 세션에서 여러 파이프라인을 돌리면 이전 팀이 세션 종료 전 자동 정리되어
#   teams/<팀>/ 디렉토리가 사라진 상태에서 새 파이프라인이 시작될 수 있다.
#   구 로직은 "디렉토리 부재 → 차단"이라 이 경우 모든 Agent spawn을 영구 봉쇄하는 교착(닭-달걀)을 유발했다.
#   (실측 2026-07-10: 파이프라인 6개+ 연속 실행 세션에서 STT 모델 추가 파이프라인 진입 시 전면 차단.)
# 수정: team_name이 올바른 자동 팀명(session-{UUID앞8자})이면 디렉토리/config.json 부재를 통과시킨다.
#   → Agent 호출이 팀을 자동 생성하도록 허용. 임의 팀명(패턴 불일치)만 여전히 차단하여 오용은 방지.
if [[ "$TOOL_TEAM_NAME" == "$_CORRECT_TEAM_NAME" || ( -n "$_RUNTIME_TEAM_NAME" && "$TOOL_TEAM_NAME" == "$_RUNTIME_TEAM_NAME" ) ]]; then
  # --- L-NEW2 (2026-07-10 재발방지): 런타임 세션 바인딩 불일치 조기 감지 ---
  # 배경: hook의 SESSION_ID(정본, sessions/*.json 기준)로 올바른 자동 팀명을 강제해도,
  #   Claude Code Agent 런타임이 내부적으로 옛 세션 ID에 바인딩된 채 startup에서 팀을 초기화하지 못하면
  #   spawn 시 "team file not found for session-<옛ID>. should have been initialized at startup" 을 반환하며 교착한다.
  #   이 교착은 PreToolUse hook이 차단/수정할 수 없는 런타임 내부 영역이다 (hook은 decision:block만 가능).
  # 조치: 완전 차단은 불가하므로, SESSION_ID가 활성 세션 목록(sessions/*.json)에 실재하는지 대조하여
  #   stale(유령) 세션이면 진단 로그를 남긴다. 재발 시 즉시 원인 규명 + /oinit 안내가 가능해진다.
  _SESSIONS_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions"
  if [[ -d "$_SESSIONS_DIR" ]]; then
    _SID_ACTIVE=""
    if command -v jq >/dev/null 2>&1; then
      for _sf in "$_SESSIONS_DIR"/*.json; do
        [[ -f "$_sf" ]] || continue
        if [[ "$(jq -r '.sessionId // ""' "$_sf" 2>/dev/null)" == "$SESSION_ID" ]]; then
          _SID_ACTIVE="1"; break
        fi
      done
    fi
    if [[ -z "$_SID_ACTIVE" ]]; then
      # SESSION_ID가 어느 활성 세션 파일에도 없음 → 런타임 세션 불일치 가능성 (교착 위험)
      mkdir -p "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${SESSION_ID}/logs" 2>/dev/null
      echo "$(date -Iseconds) [L-NEW2] SESSION_ID=${SESSION_ID} 가 sessions/*.json 활성 목록에 없음 — 런타임 팀 초기화 교착 위험. team_name=${TOOL_TEAM_NAME}. 재발 시 /oinit 또는 세션 재시작 필요." \
        >> "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${SESSION_ID}/logs/session_bind_mismatch.log" 2>/dev/null
      # 사이클46 축① — 반대편 base 미러
      source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/session_mirror.sh" 2>/dev/null
      declare -F _mirror_file >/dev/null 2>&1 && _mirror_file "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${SESSION_ID}/logs/session_bind_mismatch.log"
    fi
  fi
  # 올바른 자동 팀명 → 디렉토리/config.json 부재여도 통과 (Agent가 자동 생성)
  exit 0
fi

# --- 여기부터는 team_name이 올바른 자동 팀명이 아닌 경우 (임의 팀명 오용 방지) ---
if [[ ! -d "$_TEAM_DIR" ]]; then
  source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/write_error.sh"
  log_hook_error "HOOK_BLOCK_TEAM_NOT_EXIST" "Agent" "임의 팀명 '${TOOL_TEAM_NAME}' (자동 팀명 '${_CORRECT_TEAM_NAME}' 불일치) Agent spawn 시도" "$SESSION_ID"
  _RUNTIME_TEAM_HINT=""
  [[ -n "$_RUNTIME_TEAM_NAME" ]] && _RUNTIME_TEAM_HINT="\\n  또는 런타임 팀명: team_name=\\\"${_RUNTIME_TEAM_NAME}\\\" (\\$CLAUDE_CONFIG_DIR/teams/ 실제 디렉토리)"
  echo "{\"decision\":\"block\",\"reason\":\"❌ 팀명 '${TOOL_TEAM_NAME}'은 임의 팀명입니다 (v2.1.178+: 팀은 자동 생성만 허용).\\n\\n✅ 올바른 자동 팀명을 사용하세요:\\n  team_name=\\\"${_CORRECT_TEAM_NAME}\\\" (session-{UUID앞8자} 패턴)${_RUNTIME_TEAM_HINT}\\n\\n💡 이 팀명은 teams/ 디렉토리가 없어도 Agent 호출 시 자동 생성됩니다.\"}"
  exit 2
fi

# --- 임의 팀명인데 디렉토리는 존재하나 config.json 부재 → 레지스트리 불일치 (기존 L-340 유지) ---
if [[ ! -f "$_TEAM_DIR/config.json" ]]; then
  source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/write_error.sh"
  log_hook_error "HOOK_BLOCK_CONFIG_MISSING" "Agent" "팀 '${TOOL_TEAM_NAME}' 디렉토리 존재하나 config.json 부재 (L-340)" "$SESSION_ID"
  _STATE_DISPLAY="${_STATE:-UNKNOWN}"
  echo "{\"decision\":\"block\",\"reason\":\"❌ [L-340] team 디렉토리는 존재하나 config.json 부재 (팀명=${TOOL_TEAM_NAME}). Claude Code 내부 team 레지스트리 불일치 가능성. team_name=\\\"${_CORRECT_TEAM_NAME}\\\" 자동 팀명 사용 권장. 현재 state=${_STATE_DISPLAY}\"}"
  exit 2
fi

exit 0
