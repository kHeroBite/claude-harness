#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# pane_sweeper.sh — bash 고아 pane 감지/정리 공통 유틸리티
# 배경: teammateMode=tmux에서 팀에이전트 claude 종료 후 부모 bash가 잔류 → pane이 bash 상태로 남음
# 원칙: LLM 의지(ok shutdown_with_verify)에 의존하지 않고 hook에서 물리적 정리
# 사용: source 후 함수 호출

# ============================================================================
# is_pane_registered PANE_ID
#   agents/ 어디든 등록된 pane_id인지 확인
#   0=등록됨, 1=미등록(고아)
# ============================================================================
is_pane_registered() {
  local _pane="$1"
  [[ -z "$_pane" ]] && return 1
  # [P2-isolation] §(c) 방어: UUID 없이 전체 세션 스캔 금지 — fail-closed (Fix 19, 2026-04-24)
  # UUID 파라미터(2번째 인자)가 있으면 해당 세션만, 없으면 fail-closed.
  local _uuid="${2:-}"
  if [[ -z "$_uuid" ]]; then
    return 1  # fail-closed — 전체 세션 스캔 금지
  fi
  local _agents_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${_uuid}/agents"
  [[ -d "$_agents_dir" ]] || return 1
  local _af _aid
  for _af in "$_agents_dir"/*; do
    [ -f "$_af" ] || continue
    _aid=$(grep "^pane_id=" "$_af" 2>/dev/null | cut -d= -f2)
    [[ "$_aid" == "$_pane" ]] && return 0
  done
  return 1
}

# ============================================================================
# is_bash_orphan PANE_ID
#   pane이 존재하면서 bash 상태인지 확인
#   0=bash 상태 pane 존재, 1=소멸했거나 bash 아님
# ============================================================================
is_bash_orphan() {
  local _pane="$1"
  [[ -z "$_pane" ]] && return 1
  tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qF "$_pane" || return 1
  local _cmd
  _cmd=$(tmux display-message -t "$_pane" -p '#{pane_current_command}' 2>/dev/null || echo "")
  [[ "$_cmd" != "bash" ]] && return 1
  return 0
}

# ============================================================================
# assert_not_self_pane PANE_ID (L3 - self-kill 방어 가드)
#   대상 pane이 현재 실행 중인 메인 pane과 같으면 false 반환 (kill 금지)
#   0=다른 pane (kill 가능), 1=자기 자신 (kill 금지)
# ============================================================================
assert_not_self_pane() {
  local _pane="$1"
  [[ -z "$_pane" ]] && return 1
  local _my_pane
  _my_pane=$(tmux display-message -p '#{pane_id}' 2>/dev/null || echo "")
  [[ -n "$_my_pane" && "$_pane" == "$_my_pane" ]] && return 1
  return 0
}

# ============================================================================
# kill_bash_pane PANE_ID
#   pane을 안전하게 kill (escalation: kill PID → kill -9 → tmux kill-pane)
#   tmux status 일시 off로 감싸 아티팩트 방지
#   반환: 0=소멸 확인, 1=실패(자기 자신이거나 여전히 존재)
# ============================================================================
kill_bash_pane() {
  local _pane="$1"
  local _reason="${2:-unknown}"  # 호출자가 이유를 전달할 수 있음
  [[ -z "$_pane" ]] && return 1
  # L3: self-kill 방어 가드
  assert_not_self_pane "$_pane" || return 1
  local _pid
  _pid=$(tmux display-message -t "$_pane" -p '#{pane_pid}' 2>/dev/null || echo "")
  local _cmd
  _cmd=$(tmux display-message -t "$_pane" -p '#{pane_current_command}' 2>/dev/null || echo "")
  local _session
  _session=$(tmux display-message -t "$_pane" -p '#{session_name}' 2>/dev/null || echo "")
  # 디버그 로그 기록
  local _caller
  _caller=$(caller 0 2>/dev/null || echo "unknown:0")
  printf '[%s] KILL pane=%s pid=%s cmd=%s session=%s reason=%s caller=%s script=%s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$_pane" "$_pid" "$_cmd" "$_session" \
    "$_reason" "$_caller" "${BASH_SOURCE[1]:-pane_sweeper}" \
    >> /tmp/pane_kill_debug.log 2>/dev/null
  tmux set -g status off 2>/dev/null || true
  if [[ -n "$_pid" ]]; then
    kill "$_pid" 2>/dev/null
    sleep 1
    if tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qF "$_pane"; then
      kill -9 "$_pid" 2>/dev/null
      sleep 1
    fi
  fi
  if tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qF "$_pane"; then
    tmux kill-pane -t "$_pane" 2>/dev/null
  fi
  tmux set -g status on 2>/dev/null || true
  # L5: 최종 소멸 확인 후 성공/실패 반환
  if tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qF "$_pane"; then
    printf '[%s] KILL_FAILED pane=%s — 여전히 존재\n' \
      "$(date '+%Y-%m-%d %H:%M:%S')" "$_pane" >> /tmp/pane_kill_debug.log 2>/dev/null
    return 1  # 여전히 존재 → 실패
  fi
  printf '[%s] KILL_OK pane=%s — 소멸 확인\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$_pane" >> /tmp/pane_kill_debug.log 2>/dev/null
  return 0  # 소멸 확인
}

# ============================================================================
# find_bash_orphans_in_session SESSION_NAME [EXCLUDE_PANE]
#   특정 tmux 세션 내 bash 상태 + agents/ 미등록 pane 찾기
#   출력: pane_id 1개씩 per line
# ============================================================================
find_bash_orphans_in_session() {
  local _session="$1"
  local _exclude="${2:-}"
  # [P2-isolation] §(c) 방어: UUID 필수 — is_pane_registered() UUID 전달 보장 (Fix 21, 2026-04-24)
  local _uuid="${3:-}"
  [[ -z "$_uuid" ]] && return 1  # fail-closed
  [[ -z "$_session" ]] && return 1
  local _pane _cmd
  tmux list-panes -t "$_session" -F '#{pane_id} #{pane_current_command}' 2>/dev/null | while read _pane _cmd; do
    [[ "$_pane" == "$_exclude" ]] && continue
    [[ "$_cmd" != "bash" ]] && continue
    if ! is_pane_registered "$_pane" "$_uuid"; then
      echo "$_pane"
    fi
  done
}
