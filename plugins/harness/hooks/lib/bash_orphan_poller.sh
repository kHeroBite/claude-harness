#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# bash_orphan_poller.sh — 백그라운드 daemon: bash 고아 pane 주기적 감지 + 자동 kill
#
# 목적: 메인의 shutdown_request 없이도 팀에이전트가 bash로 탈출하면 자동 종료
# 동작: UUID 기반 agents/ 등록 pane을 5초마다 스캔 → bash 상태 + 유예기간 경과 시 즉시 kill
# 실행: nohup bash bash_orphan_poller.sh <UUID> &
# 종료: state=IDLE 30초 연속 or agents/ 30초 연속 비어있으면 자동 종료 / PID 파일로 중복 방지
#
# 사용 예:
#   nohup bash "${HARNESS_HOOK_DIR}/lib/bash_orphan_poller.sh" "$UUID" > /dev/null 2>&1 &
#
# 관련: pane_sweeper.sh (is_bash_orphan, kill_bash_pane)

# F-NEW-3: flock 기반 state_read() 로드
source "${HARNESS_HOOK_DIR}/lib/session_id.sh" 2>/dev/null || true

UUID="${1:-}"
if [[ -z "$UUID" ]]; then
  echo "[bash_orphan_poller] ERROR: UUID 인자 필수" >&2
  exit 1
fi

CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SESSION_DIR="$CLAUDE_CONFIG_DIR/session-env/$UUID"
PID_FILE="$SESSION_DIR/orphan_poller.pid"
LOG_DIR="$SESSION_DIR/logs"
LOG_FILE="$LOG_DIR/orphan_poller.log"
AGENTS_DIR="$SESSION_DIR/agents"
STATE_FILE="$SESSION_DIR/state"
POLL_INTERVAL=5       # 초
GRACE_PERIOD=15       # 초 (spawned_at 기준 부팅 유예기간)
MAX_IDLE_CYCLES=6     # 30초 연속 IDLE 상태 시 종료 (6 × 5초)
HEARTBEAT_MAX_AGE=1800  # 초 (30분) — Claude Code만 죽은 케이스 대비
HEARTBEAT_GRACE=120     # 초 (2분) — heartbeat 파일 미존재 시 유예

# pane_sweeper.sh 소싱 (심볼릭링크 경유 없이 실제 경로 사용)
SWEEPER_CANDIDATES=(
  "$(readlink -f "${HARNESS_HOOK_DIR}/lib/pane_sweeper.sh" 2>/dev/null || echo "")"
  "${HARNESS_HOOK_DIR}/lib/pane_sweeper.sh"
)
SWEEPER=""
for _s in "${SWEEPER_CANDIDATES[@]}"; do
  [[ -n "$_s" && -f "$_s" ]] && SWEEPER="$_s" && break
done
if [[ -z "$SWEEPER" ]]; then
  echo "[bash_orphan_poller] ERROR: pane_sweeper.sh 미존재" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$SWEEPER"

# 로그 디렉토리 생성
mkdir -p "$LOG_DIR"

_log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

_check_self_termination() {
  if [[ -n "$MY_TMUX_SESSION" ]]; then
    if ! tmux has-session -t "$MY_TMUX_SESSION" 2>/dev/null; then
      _log "TMUX_SESSION_GONE: $MY_TMUX_SESSION → 종료"
      exit 0
    fi
  fi
  local _hb="$SESSION_DIR/heartbeat"
  if [[ -f "$_hb" ]]; then
    local _age=$(( $(date +%s) - $(stat -c %Y "$_hb" 2>/dev/null || echo 0) ))
    if [[ $_age -gt $HEARTBEAT_MAX_AGE ]]; then
      _log "HEARTBEAT_STALE: age=${_age}s > ${HEARTBEAT_MAX_AGE}s → 종료"
      exit 0
    fi
  else
    local _uptime=$(( $(date +%s) - _DAEMON_START_TIME ))
    if [[ $_uptime -gt $HEARTBEAT_GRACE ]]; then
      _log "HEARTBEAT_MISSING: uptime=${_uptime}s > grace=${HEARTBEAT_GRACE}s → 종료"
      exit 0
    fi
  fi
}

# ─── 중복 실행 방지 ────────────────────────────────────────────────────────────
if [[ -f "$PID_FILE" ]]; then
  OLD_PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
  if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
    _log "SKIP: 이미 실행 중 (PID=$OLD_PID)"
    exit 0
  fi
  _log "STALE_PID 제거: $OLD_PID"
  rm -f "$PID_FILE"
fi

echo $$ > "$PID_FILE"
_log "START: UUID=$UUID PID=$$"

# ─── 종료 시 정리 ─────────────────────────────────────────────────────────────
_cleanup() {
  rm -f "$PID_FILE"
  _log "EXIT: PID=$$"
}
trap _cleanup EXIT

# ─── 상태 확인 헬퍼 ───────────────────────────────────────────────────────────
_get_state() {
  state_read "$STATE_FILE" 2>/dev/null | awk '{print $1}' || echo "IDLE"  # F-NEW-3
}

_agents_count() {
  local cnt=0
  if [[ -d "$AGENTS_DIR" ]]; then
    cnt=$(find "$AGENTS_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l || echo 0)
  fi
  echo "$cnt"
}

# ─── 메인 폴링 루프 ───────────────────────────────────────────────────────────
idle_cycles=0

MY_TMUX_SESSION=$(tmux display-message -p '#{session_name}' 2>/dev/null || echo "")
_DAEMON_START_TIME=$(date +%s)
_log "TMUX_SESSION: ${MY_TMUX_SESSION:-none}"

_log "LOOP_START: POLL_INTERVAL=${POLL_INTERVAL}s GRACE_PERIOD=${GRACE_PERIOD}s"

while true; do
  sleep "$POLL_INTERVAL"
  _check_self_termination

  # SESSION_DIR 미존재 시 종료 (세션 클린업됨)
  if [[ ! -d "$SESSION_DIR" ]]; then
    _log "SESSION_DIR 소멸 → 종료"
    exit 0
  fi

  # state=IDLE 연속 감지 시 종료
  cur_state=$(_get_state)
  if [[ "$cur_state" == "IDLE" ]]; then
    idle_cycles=$((idle_cycles + 1))
    if [[ $idle_cycles -ge $MAX_IDLE_CYCLES ]]; then
      _log "STATE=IDLE ${MAX_IDLE_CYCLES}회 연속 → 종료"
      exit 0
    fi
    continue
  fi
  idle_cycles=0

  # agents/ 비어있으면 스킵 (비IDLE 상태에선 에이전트 spawn 대기 중일 수 있음)
  # state=IDLE일 때만 idle_cycles 로직이 종료를 담당
  agent_cnt=$(_agents_count)
  if [[ "$agent_cnt" -eq 0 ]]; then
    continue
  fi

  # ─── 각 등록 에이전트 파일 순회 ──────────────────────────────────────────────
  for agent_file in "$AGENTS_DIR"/*; do
    [[ -f "$agent_file" ]] || continue

    pane_id=$(grep "^pane_id=" "$agent_file" 2>/dev/null | cut -d= -f2 || echo "")
    agent_name=$(basename "$agent_file")
    spawned_at=$(grep "^spawned_at=" "$agent_file" 2>/dev/null | cut -d= -f2 || echo "")

    [[ -z "$pane_id" ]] && continue

    shutdown_sent_at=$(grep "^shutdown_sent_at=" "$agent_file" 2>/dev/null | cut -d= -f2 || echo "")
    if [[ -n "$shutdown_sent_at" ]]; then
      now_epoch=$(date +%s)
      elapsed=$(( now_epoch - shutdown_sent_at ))
      if tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qF "$pane_id"; then
        if [[ $elapsed -gt 60 ]]; then
          _log "SHUTDOWN_TIMEOUT: pane=$pane_id agent=$agent_name elapsed=${elapsed}s → 강제 kill"
          if kill_bash_pane "$pane_id" "shutdown_timeout(elapsed=${elapsed}s)"; then
            _log "SHUTDOWN_TIMEOUT_KILL_OK: pane=$pane_id"
            rm -f "$agent_file"
            _log "AGENT_FILE_REMOVED: $agent_file"
          else
            _log "SHUTDOWN_TIMEOUT_KILL_FAILED: pane=$pane_id"
          fi
          continue
        fi
      else
        _log "PANE_GONE_AFTER_SHUTDOWN: pane=$pane_id agent=$agent_name → 파일 정리"
        rm -f "$agent_file"
        continue
      fi
    fi

    # bash 상태인지 확인
    if ! is_bash_orphan "$pane_id"; then
      continue
    fi

    # spawned_at 기준 유예기간 확인 (부팅 중 오탐 방지)
    if [[ -n "$spawned_at" ]]; then
      now_epoch=$(date +%s)
      # spawned_at: UNIX timestamp or ISO8601
      if [[ "$spawned_at" =~ ^[0-9]+$ ]]; then
        spawn_epoch="$spawned_at"
      else
        spawn_epoch=$(date -d "$spawned_at" +%s 2>/dev/null || echo "0")
      fi
      elapsed=$((now_epoch - spawn_epoch))
      if [[ $elapsed -lt $GRACE_PERIOD ]]; then
        _log "GRACE: pane=$pane_id agent=$agent_name elapsed=${elapsed}s < ${GRACE_PERIOD}s → 스킵"
        continue
      fi
    fi

    # bash 상태 + 유예기간 경과 → 즉시 kill
    _log "BASH_ORPHAN_DETECTED: pane=$pane_id agent=$agent_name state=$cur_state"

    if kill_bash_pane "$pane_id" "orphan_poller(uuid=$UUID,agent=$agent_name)"; then
      _log "KILL_OK: pane=$pane_id agent=$agent_name"
      # agents/ 파일 제거 (완료 처리)
      rm -f "$agent_file"
      _log "AGENT_FILE_REMOVED: $agent_file"
    else
      _log "KILL_FAILED: pane=$pane_id agent=$agent_name — 수동 확인 필요"
    fi
  done

  # ─── B방향 스캔 비활성화 ──────────────────────────────────────────────────────
  # [P2-isolation] §(d) B방향 스캔 제거 — UUID 경계 없이 타 세션 pane kill 위험 (Fix 18, 2026-04-24)
  # B방향 스캔(tmux list-panes 전체 열거)은 타 세션 bash pane을 고아로 오판할 수 있음.
  # A방향(자기 세션 agents/ 기반) 스캔만으로 orphan 감지.
  _log "B_DIRECTION_SCAN_DISABLED: §(d) 준수 — 자기 세션 agents/ 기반 A방향만 사용"
  # ─── B방향 끝 ─────────────────────────────────────────────────────────────────
done
