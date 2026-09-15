#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# ack_utils.sh — F2 ACK 2단계 + retry queue 공용 라이브러리
# 출처: oplan_final_v2 §4 F2, debate_3_v2 §2.4, plan_3_impl §1-B
# 설계 원칙 (jury 확정):
#   - V3: ACK 발신자 식별 = pane_id 역검색 단일 경로 (CLAUDE_AGENT_NAME 금지)
#   - V12: env 경로 완전 제거
#   - ACK 2단계: .received (수신 직후) + .done (발송 직전) 분리 기록
#   - retry queue: $SESSION_DIR/shutdown_retry_queue 영속화
#
# 공용 함수 시그니처:
#   _ack_file_base UUID NAME REQUEST_ID  → stdout: 경로 prefix (확장자 제외)
#   ack_write_received UUID NAME REQUEST_ID
#   ack_write_done UUID NAME REQUEST_ID
#   ack_wait_for UUID NAME REQUEST_ID STAGE TIMEOUT_SEC
#       STAGE ∈ {received, done}
#   pane_id_to_agent_name PANE_ID [UUID]   → stdout: agent name (미매치 시 빈 문자열)
#   resolve_sender_from_tmux [UUID]        → stdout: agent name (실패 시 빈 문자열, fail-open)
#   retry_queue_append UUID NAME REQUEST_ID [REASON]
#
# 호출 규약:
#   - 모든 함수는 실패 시 비-0 반환 + stderr 경고. 하지만 호출자는 fail-open 처리 권장
#     (ACK 경로는 보조 수단이므로 장애 시 sweep 경로가 kill_bash_pane으로 fallback)

# 중복 source 방지
if [ -n "${__ACK_UTILS_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
__ACK_UTILS_LOADED=1

# 상수 (constants.sh가 source되어 있으면 덮어쓰지 않음)
: "${ACK_WAIT_SECONDS:=15}"
: "${ACK_POLL_INTERVAL:=1}"

# 세션 루트
_ack_session_root() {
  echo "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env"
}

# 경로 헬퍼: $SESSION_DIR/ack/shutdown_${NAME}_${REQUEST_ID} (확장자 제외)
_ack_file_base() {
  local _uuid="$1" _name="$2" _rid="$3"
  if [ -z "$_uuid" ] || [ -z "$_name" ]; then
    return 2
  fi
  local _rid_suffix=""
  if [ -n "$_rid" ]; then
    _rid_suffix="_${_rid}"
  fi
  printf '%s/%s/ack/shutdown_%s%s' \
    "$(_ack_session_root)" "$_uuid" "$_name" "$_rid_suffix"
}

# 내부: atomic write via tmpfile + rename
_ack_atomic_write() {
  local _target="$1"; shift
  local _payload="$*"
  local _dir
  _dir=$(dirname "$_target")
  mkdir -p "$_dir" 2>/dev/null || return 1
  local _tmp="${_target}.tmp.$$"
  printf '%s\n' "$_payload" > "$_tmp" 2>/dev/null || {
    rm -f "$_tmp" 2>/dev/null
    return 1
  }
  mv -f "$_tmp" "$_target" 2>/dev/null || {
    rm -f "$_tmp" 2>/dev/null
    return 1
  }
  return 0
}

# .received 파일 생성 — 팀에이전트가 shutdown_request 수신 직후 호출
ack_write_received() {
  local _uuid="$1" _name="$2" _rid="$3"
  local _base
  _base=$(_ack_file_base "$_uuid" "$_name" "$_rid") || return 2
  local _payload
  _payload="ts=$(date +%s)
stage=received
agent=${_name}
request_id=${_rid}"
  _ack_atomic_write "${_base}.received" "$_payload"
}

# .done 파일 생성 — shutdown_response 발송 후 호출
ack_write_done() {
  local _uuid="$1" _name="$2" _rid="$3"
  local _base
  _base=$(_ack_file_base "$_uuid" "$_name" "$_rid") || return 2
  local _payload
  _payload="ts=$(date +%s)
stage=done
agent=${_name}
request_id=${_rid}"
  _ack_atomic_write "${_base}.done" "$_payload"
}

# polling — 메인측 sweep이 호출
# STAGE=received → .received 파일 기다림 (팀에이전트 살아있음 확증)
# STAGE=done     → .done 파일 기다림 (shutdown_response 발송 완료 확증)
ack_wait_for() {
  local _uuid="$1" _name="$2" _rid="$3" _stage="$4" _timeout="${5:-$ACK_WAIT_SECONDS}"
  local _base
  _base=$(_ack_file_base "$_uuid" "$_name" "$_rid") || return 2
  local _target="${_base}.${_stage}"
  local _waited=0
  while [ "$_waited" -lt "$_timeout" ]; do
    if [ -f "$_target" ]; then
      return 0
    fi
    sleep "$ACK_POLL_INTERVAL"
    _waited=$((_waited + ACK_POLL_INTERVAL))
  done
  return 1
}

# pane_id → agent name 역검색
# agents/* 전수 grep (V3 B, V12 A — 단일 경로)
# E1(tmux fail)/E2(pane 소멸)/E3(grep 미매치)/E6(race) 모두 fail-open (빈 문자열 반환)
pane_id_to_agent_name() {
  local _pane="$1"
  local _uuid="${2:-}"
  if [ -z "$_pane" ]; then
    return 1
  fi

  local _root
  _root=$(_ack_session_root)
  local _search_dirs=""
  if [ -n "$_uuid" ] && [ -d "${_root}/${_uuid}/agents" ]; then
    _search_dirs="${_root}/${_uuid}/agents"
  else
    # [P2-isolation] §(c) 방어: UUID 없이 전체 세션 스캔 금지 — fail-closed (Fix 17, 2026-04-24)
    # 타 세션 agents/ 정보를 현재 에이전트에게 노출하지 않는다.
    return 1
  fi
  [ -z "$_search_dirs" ] && return 1

  local _af _name _aid
  for _dir in $_search_dirs; do
    for _af in "$_dir"/*; do
      [ -f "$_af" ] || continue
      _name=$(basename "$_af")
      case "$_name" in
        unnamed*) continue ;;  # name 필수 정책, 방어적 스킵
      esac
      _aid=$(grep '^pane_id=' "$_af" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '\r\n ')
      if [ "$_aid" = "$_pane" ]; then
        printf '%s' "$_name"
        return 0
      fi
    done
  done
  return 1
}

# 현재 tmux pane에서 자기 pane_id + agent name 해결
# 팀에이전트 측 PostToolUse:SendMessage hook에서 호출
# 반환: stdout에 "${PANE_ID}|${NAME}" (둘 다 성공 시). 실패 시 비-0 + 빈 stdout.
resolve_sender_from_tmux() {
  local _uuid="${1:-}"
  # E1: tmux display-message 실패 — tmux 서버 부재 등
  local _my_pane
  _my_pane=$(tmux display-message -p '#{pane_id}' 2>/dev/null) || return 1
  [ -z "$_my_pane" ] && return 1
  # E2: pane 소멸 — 이미 죽은 pane은 애초에 호출되지 않으므로 무시
  # E3: grep 미매치 — 메인/ok 프로세스 등 agents/ 미등록 주체 → fail-open
  local _name
  _name=$(pane_id_to_agent_name "$_my_pane" "$_uuid") || return 1
  [ -z "$_name" ] && return 1
  printf '%s|%s' "$_my_pane" "$_name"
  return 0
}

# retry queue append — append-only, 1줄 1개
# 포맷: ts|uuid|name|request_id|reason
retry_queue_append() {
  local _uuid="$1" _name="$2" _rid="$3" _reason="${4:-ack_timeout}"
  [ -z "$_uuid" ] && return 2
  local _qdir="$(_ack_session_root)/${_uuid}"
  local _qfile="${_qdir}/shutdown_retry_queue"
  mkdir -p "$_qdir" 2>/dev/null || return 1
  # flock으로 동시 append race 방지
  local _lock="${_qfile}.lock"
  (
    flock -x -w 2 200 || exit 1
    printf '%s|%s|%s|%s|%s\n' \
      "$(date +%s)" "$_uuid" "$_name" "$_rid" "$_reason" >> "$_qfile"
  ) 200>"$_lock"
}
