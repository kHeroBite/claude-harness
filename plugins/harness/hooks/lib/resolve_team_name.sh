#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# 팀에이전트의 실제 런타임 팀명을 우선순위에 따라 해석하는 공용 헬퍼
# resolve_team_name <INPUT_JSON> <UUID>  → stdout 에 팀명, rc=0 항상 (fail-soft)
#
# 우선순위 (런타임 실제값이 규약명보다 항상 우선 — 2026-09-06 정정):
#   1. tool_response.agent_id (INPUT JSON, "name@team" 형식) → "@" 뒤를 팀명으로 채택 (PostToolUse 런타임 확정값, jq 우선 → python3 폴백)
#   2. $CLAUDE_CONFIG_DIR/teams/session-* 디렉토리가 정확히 1개일 때 그 basename (0개·2개+ 스킵 — PreToolUse 시점 런타임 확정값)
#   3. ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/team_name 파일 (공백 제거 후 비어있지 않을 때)
#   4. tool_input.team_name (INPUT JSON — 규약명, 최후의 힌트. jq 우선 → python3 폴백)
#   5. session-${UUID:0:8}
#
# self-heal 규칙: 결과가 (3)에서 온 게 아니면 자기 UUID의 team_name 파일에 기록한다.
#   단 (1)·(2) 런타임 확정값이면 파일 값과 달라도 무조건 덮어쓴다(정합 목적).
#   (4)·(5)는 파일이 비어 있을 때만 기록한다(런타임 확정값을 규약명으로 덮지 않도록).
# 타 세션 경로 쓰기는 절대 하지 않는다. 기록 실패는 무시(fail-soft).
# 본 함수는 함수 정의만 하며 source 시 부수효과가 없다.

resolve_team_name() {
  local _rtn_input="$1"
  local _rtn_uuid="$2"
  local _rtn_team=""
  local _rtn_from_file=0
  local _rtn_runtime=0

  local _rtn_cfg_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  local _rtn_session_dir="${_rtn_cfg_dir}/session-env/${_rtn_uuid}"
  local _rtn_team_file="${_rtn_session_dir}/team_name"

  # 1순위: tool_response.agent_id ("name@team" 형식, jq → python3 폴백)
  if command -v jq >/dev/null 2>&1; then
    _rtn_team=$(printf '%s' "$_rtn_input" | jq -r '.tool_response.agent_id // empty' 2>/dev/null | sed -n 's/^[^@]*@//p')
  fi
  if [[ -z "$_rtn_team" ]] && command -v python3 >/dev/null 2>&1; then
    _rtn_team=$(printf '%s' "$_rtn_input" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
    v=d.get("tool_response",{}).get("agent_id","")
    print(v.split("@",1)[1] if v and "@" in v else "")
except Exception:
    print("")
' 2>/dev/null)
  fi
  if [[ -n "$_rtn_team" ]]; then
    _rtn_runtime=1
  fi

  # 2순위: $CLAUDE_CONFIG_DIR/teams/session-* 디렉토리가 정확히 1개일 때 (런타임 확정값)
  if [[ -z "$_rtn_team" ]]; then
    local _rtn_teams_root="${CLAUDE_CONFIG_DIR:-}/teams"
    if [[ -n "${CLAUDE_CONFIG_DIR:-}" && -d "$_rtn_teams_root" ]]; then
      local _rtn_candidates=()
      local _rtn_d
      for _rtn_d in "$_rtn_teams_root"/session-*; do
        [[ -d "$_rtn_d" ]] && _rtn_candidates+=("$_rtn_d")
      done
      if [[ "${#_rtn_candidates[@]}" -eq 1 ]]; then
        _rtn_team=$(basename "${_rtn_candidates[0]}")
        _rtn_runtime=1
      fi
    fi
  fi

  # 3순위: 자기 UUID의 team_name 파일
  if [[ -z "$_rtn_team" ]]; then
    local _rtn_file_val=""
    _rtn_file_val=$(cat "$_rtn_team_file" 2>/dev/null | tr -d '[:space:]')
    if [[ -n "$_rtn_file_val" ]]; then
      _rtn_team="$_rtn_file_val"
      _rtn_from_file=1
    fi
  fi

  # 4순위: tool_input.team_name (규약명, jq → python3 폴백)
  if [[ -z "$_rtn_team" ]]; then
    if command -v jq >/dev/null 2>&1; then
      _rtn_team=$(printf '%s' "$_rtn_input" | jq -r '.tool_input.team_name // empty' 2>/dev/null)
    fi
    if [[ -z "$_rtn_team" ]] && command -v python3 >/dev/null 2>&1; then
      _rtn_team=$(printf '%s' "$_rtn_input" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
    v=d.get("tool_input",{}).get("team_name","")
    print(v if v else "")
except Exception:
    print("")
' 2>/dev/null)
    fi
  fi

  # 5순위: session-${UUID:0:8} 폴백
  if [[ -z "$_rtn_team" ]]; then
    _rtn_team="session-${_rtn_uuid:0:8}"
  fi

  # self-heal: 파일(3순위)에서 온 게 아니면 기록 대상.
  #   단 4·5순위(규약명/UUID폴백)는 파일이 이미 값을 갖고 있으면 그 값을 존중(덮지 않음).
  if [[ "$_rtn_from_file" -eq 0 ]]; then
    local _rtn_existing=""
    _rtn_existing=$(cat "$_rtn_team_file" 2>/dev/null | tr -d '[:space:]')
    if [[ "$_rtn_runtime" -eq 1 || -z "$_rtn_existing" ]]; then
      (
        mkdir -p "$_rtn_session_dir" 2>/dev/null
        printf '%s\n' "$_rtn_team" > "$_rtn_team_file" 2>/dev/null
      ) 2>/dev/null
      if ! declare -f _mirror_file >/dev/null 2>&1; then
        source "${HARNESS_HOOK_DIR}/lib/session_mirror.sh" 2>/dev/null
      fi
      if declare -f _mirror_file >/dev/null 2>&1; then
        _mirror_file "$_rtn_team_file" 2>/dev/null
      fi
    fi
  fi

  printf '%s' "$_rtn_team"
  return 0
}
