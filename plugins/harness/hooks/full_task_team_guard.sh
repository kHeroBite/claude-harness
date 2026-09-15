#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
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
  source "${HARNESS_HOOK_DIR}/lib/write_error.sh"
  log_hook_error "HOOK_BLOCK_CMD_START" "Agent" "L-110: 프롬프트에 cmd.exe /c start 직접 명시" "$SESSION_ID"
  echo '{"decision":"block","reason":"❌ L-110 위반: 프롬프트에 cmd.exe /c start 직접 명시 금지! WSL 무한 블로킹 원인 (L-022). 정정: 프롬프트에서 cmd.exe /c start 명령 제거 후 [Skill(otest_run) 호출하여 배포] 또는 [Skill(oinfra_{프로젝트명}) 배포 섹션 참조]로 교체하세요. (예: oinfra_rtx5070 / oinfra_know / oinfra_mars)"}' | tee /dev/stderr
  exit 2
fi

if echo "$PROMPT_FILTERED" | grep -qE 'curl\s+-s\s+http://localhost:'; then
  source "${HARNESS_HOOK_DIR}/lib/write_error.sh"
  log_hook_error "HOOK_BLOCK_CURL_LOCALHOST" "Agent" "L-110: 프롬프트에 curl -s http://localhost: 직접 명시" "$SESSION_ID"
  echo '{"decision":"block","reason":"❌ L-110 위반: 프롬프트에 curl -s http://localhost: 직접 명시 금지! WSL에서 Windows 프로세스 localhost 접근 불가 (exit code 7). 정정: 프롬프트에서 curl 명령 제거 후 [Skill(otest_run) 호출하여 헬스체크] 또는 [Skill(oinfra_{프로젝트명}) 배포 섹션 참조하여 헬스체크]로 교체하세요. (예: oinfra_rtx5070 / oinfra_know / oinfra_mars)"}' | tee /dev/stderr
  exit 2
fi

# --- subagent_type 확인 ---
SUBAGENT_TYPE=$(echo "$INPUT" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null || echo "")

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
if [[ -z "$_L299_PIPELINE_UUID" ]]; then
  _L299_PID_WALK=$$
  _L299_DEPTH_WALK=0
  while [[ $_L299_DEPTH_WALK -lt 10 && -n "$_L299_PID_WALK" && "$_L299_PID_WALK" != "1" ]]; do
    _L299_CMDLINE_WALK=$(tr '\0' ' ' < "/proc/${_L299_PID_WALK}/cmdline" 2>/dev/null)
    if [[ "$_L299_CMDLINE_WALK" =~ --parent-session-id[[:space:]]+([0-9a-f-]{36}) ]]; then
      _L299_PIPELINE_UUID="${BASH_REMATCH[1]}"
      break
    fi
    _L299_PID_WALK=$(awk '{print $4}' "/proc/${_L299_PID_WALK}/stat" 2>/dev/null)
    (( _L299_DEPTH_WALK++ )) || true
  done
fi
if [[ -n "$_L299_PIPELINE_UUID" && "$_L299_PIPELINE_UUID" != "$SESSION_ID" ]]; then
  source "${HARNESS_HOOK_DIR}/lib/write_error.sh" 2>/dev/null || true
  log_hook_error "HOOK_BLOCK_SUBAGENT_SPAWN_L299" "Agent" "팀에이전트(pipeline_uuid=${_L299_PIPELINE_UUID})가 하위 Agent spawn 시도 (L-299)" "${SESSION_ID}" 2>/dev/null || true
  echo '{"decision":"block","reason":"🚫 [L-299] 팀에이전트는 하위 Agent를 직접 spawn할 수 없습니다. 메인(team-lead)에게 SPAWN_REQUEST로 위임하세요."}' | tee /dev/stderr
  exit 2
fi

# --- 메인 에이전트: 활성 파이프라인 시에만 team_name 강제 ---
# IDLE/DONE/FINISH → 파이프라인 없음 → 서브에이전트 자유 허용
# OK/PLAN/DEV/TEST → 파이프라인 활성 → team_name 필수
_STATE_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${SESSION_ID}/state"
source "${HARNESS_HOOK_DIR}/lib/session_id.sh" 2>/dev/null || true
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
        source "${HARNESS_HOOK_DIR}/lib/session_mirror.sh" 2>/dev/null
        type _mirror_file >/dev/null 2>&1 && _mirror_file "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${SESSION_ID}/team_name"
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

if [[ -z "$TOOL_TEAM_NAME" ]]; then
  source "${HARNESS_HOOK_DIR}/lib/write_error.sh"
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
  source "${HARNESS_HOOK_DIR}/lib/write_error.sh"
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
            source "${HARNESS_HOOK_DIR}/lib/write_error.sh" 2>/dev/null || true
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
      source "${HARNESS_HOOK_DIR}/lib/session_mirror.sh" 2>/dev/null
      type _mirror_file >/dev/null 2>&1 && _mirror_file "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${SESSION_ID}/logs/session_bind_mismatch.log"
    fi
  fi
  # 올바른 자동 팀명 → 디렉토리/config.json 부재여도 통과 (Agent가 자동 생성)
  exit 0
fi

# --- 여기부터는 team_name이 올바른 자동 팀명이 아닌 경우 (임의 팀명 오용 방지) ---
if [[ ! -d "$_TEAM_DIR" ]]; then
  source "${HARNESS_HOOK_DIR}/lib/write_error.sh"
  log_hook_error "HOOK_BLOCK_TEAM_NOT_EXIST" "Agent" "임의 팀명 '${TOOL_TEAM_NAME}' (자동 팀명 '${_CORRECT_TEAM_NAME}' 불일치) Agent spawn 시도" "$SESSION_ID"
  _RUNTIME_TEAM_HINT=""
  [[ -n "$_RUNTIME_TEAM_NAME" ]] && _RUNTIME_TEAM_HINT="\\n  또는 런타임 팀명: team_name=\\\"${_RUNTIME_TEAM_NAME}\\\" (\\$CLAUDE_CONFIG_DIR/teams/ 실제 디렉토리)"
  echo "{\"decision\":\"block\",\"reason\":\"❌ 팀명 '${TOOL_TEAM_NAME}'은 임의 팀명입니다 (v2.1.178+: 팀은 자동 생성만 허용).\\n\\n✅ 올바른 자동 팀명을 사용하세요:\\n  team_name=\\\"${_CORRECT_TEAM_NAME}\\\" (session-{UUID앞8자} 패턴)${_RUNTIME_TEAM_HINT}\\n\\n💡 이 팀명은 teams/ 디렉토리가 없어도 Agent 호출 시 자동 생성됩니다.\"}"
  exit 2
fi

# --- 임의 팀명인데 디렉토리는 존재하나 config.json 부재 → 레지스트리 불일치 (기존 L-340 유지) ---
if [[ ! -f "$_TEAM_DIR/config.json" ]]; then
  source "${HARNESS_HOOK_DIR}/lib/write_error.sh"
  log_hook_error "HOOK_BLOCK_CONFIG_MISSING" "Agent" "팀 '${TOOL_TEAM_NAME}' 디렉토리 존재하나 config.json 부재 (L-340)" "$SESSION_ID"
  _STATE_DISPLAY="${_STATE:-UNKNOWN}"
  echo "{\"decision\":\"block\",\"reason\":\"❌ [L-340] team 디렉토리는 존재하나 config.json 부재 (팀명=${TOOL_TEAM_NAME}). Claude Code 내부 team 레지스트리 불일치 가능성. team_name=\\\"${_CORRECT_TEAM_NAME}\\\" 자동 팀명 사용 권장. 현재 state=${_STATE_DISPLAY}\"}"
  exit 2
fi

exit 0
