#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# sendmessage_shutdown_sweep.sh — shutdown_request 발송 후 pane 자동 정리
# 매처: PostToolUse:SendMessage
# 원칙: shutdown_request 발송 → ACK 2단계(received/done) 대기 → 미수신 시 retry queue + 물리 kill
# 재발방지: ok/SKILL.md shutdown_with_verify(LLM 지침) 생략되어도 물리적으로 보완
# 배경: teammateMode=tmux에서 claude 종료 후 bash 잔류 증상 (2026-04-05 진단)
#
# 수정 이력:
#   - F2: ACK 2단계 대기 (received/done) + retry queue 진입
#   - F3: 서브쉘 전체 timeout 30s + PPID 감시 (부모 사망 시 즉시 종료)
#   - F12: silent exit 전수 로깅 + ERR trap _err_exit + log rotation 1MB

# ============================================================================
# F12: 로깅 인프라 — silent exit 전수 기록 + ERR trap
# ============================================================================
_resolve_log_path() {
  local _uuid="${1:-}"
  if [[ -n "$_uuid" ]]; then
    local _dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${_uuid}/logs"
    mkdir -p "$_dir" 2>/dev/null
    printf '%s/shutdown_sweep.log' "$_dir"
    return 0
  fi
  # UUID 미확정 fallback
  local _fb="/tmp/claude_shutdown_sweep_fallback"
  mkdir -p "$_fb" 2>/dev/null
  printf '%s/shutdown_sweep.log' "$_fb"
}

_rotate_log() {
  local _log="$1"
  [[ -f "$_log" ]] || return 0
  local _size
  _size=$(stat -c %s "$_log" 2>/dev/null || echo 0)
  if [[ "$_size" -gt 1048576 ]]; then
    mv "$_log" "${_log}.old" 2>/dev/null
  fi
}

_log() {
  local _reason="$1"
  shift
  local _log
  _log=$(_resolve_log_path "${UUID:-}")
  _rotate_log "$_log"
  printf '%s %s to=%s uuid=%s pane=%s rid=%s %s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" \
    "$_reason" \
    "${TO:-?}" \
    "${UUID:-?}" \
    "${PANE_ID:-?}" \
    "${REQUEST_ID:-?}" \
    "$*" >> "$_log" 2>/dev/null
}

_sweep_skip() {
  local _reason="$1"
  shift
  _log "SKIP_$_reason" "$@"
  exit 0
}

_err_exit() {
  local _ec=$?
  local _line="${BASH_LINENO[0]:-?}"
  _log "ERR_TRAP" "exit_code=$_ec line=$_line"
  exit 0
}

trap '_err_exit' ERR

# ============================================================================
# Input parse
# ============================================================================
INPUT=$(timeout 2 cat 2>/dev/null) || INPUT=""
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || TOOL_NAME=""
UUID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null) || UUID=""

# G4 (2026-08-23): hook 진입 즉시 무조건 1줄 기록 — 조건 판정 전.
# 배경: %51(otest-1) 사고 — shutdown_request 4회 이상 발송에도 로그가 전무해
#       "hook이 발동했는지조차" 알 수 없었다. 이후 판정에서 어떤 스킵이 나든
#       최소한 "진입은 했다"는 사실만은 항상 남겨야 재발 시 원인 규명이 가능하다.
# fail-open: _log()가 실패해도(UUID 없어 fallback 경로여도) 흐름에 영향 없음.
_log "ENTER" "tool=${TOOL_NAME:-?}"

if [[ "$TOOL_NAME" != "SendMessage" ]]; then
  _sweep_skip "tool_name_mismatch" "got=$TOOL_NAME"
fi

# message.type == shutdown_request 확인 (message가 object일 때만)
MSG_TYPE=$(echo "$INPUT" | jq -r '.tool_input.message.type // empty' 2>/dev/null) || MSG_TYPE=""
if [[ "$MSG_TYPE" != "shutdown_request" ]]; then
  # ── [H-2 2026-08-17] shutdown 응답 발신 시 마커 해제 ──
  # shutdown_response 를 보냈다는 것은 그 에이전트가 살아서 응답했다는 뜻이다.
  # 자기 이름 마커를 지워 write_guard 의 "미응답" 경고가 오탐하지 않게 한다.
  # 응답자 본인이 발신하므로 여기서 지우는 대상은 "발신자 자신"이다.
  # fail-open: 실패해도 아래 기존 skip 흐름을 그대로 탄다. 기존 동작 무변경.
  # ★ 발신자 식별은 ack_utils.sh 의 resolve_sender_from_tmux 단일 경로만 쓴다 (L-457).
  #   CLAUDE_AGENT_NAME 은 **실재하지 않는 환경변수**임을 실측 확인했고,
  #   ack_utils.sh 서두(V3)가 그 사용을 명시적으로 금지한다. 쓰면 조용히 죽은 코드가 된다.
  if [[ "$MSG_TYPE" == "shutdown_response" && -n "${UUID:-}" ]]; then
    _H2_LIB_R="${HARNESS_HOOK_DIR}/lib/orphan_scan.sh"
    _H2_ACK="${HARNESS_HOOK_DIR}/lib/ack_utils.sh"
    if [[ -r "$_H2_LIB_R" && -r "$_H2_ACK" ]]; then
      _H2_SELF=$(timeout 2 bash -c "source '$_H2_ACK' 2>/dev/null; resolve_sender_from_tmux '$UUID' 2>/dev/null" 2>/dev/null) || _H2_SELF=""
      if [[ -n "$_H2_SELF" ]]; then
        timeout 2 bash -c "source '$_H2_LIB_R' 2>/dev/null; shutdown_marker_clear '$UUID' '$_H2_SELF'" 2>/dev/null || true
      fi
    fi
  fi
  _sweep_skip "msg_type_not_shutdown" "got=$MSG_TYPE"
fi

# 수신자 이름
TO=$(echo "$INPUT" | jq -r '.tool_input.to // empty' 2>/dev/null) || TO=""
if [[ -z "$TO" ]]; then
  _sweep_skip "empty_recipient"
fi
if [[ "$TO" == "*" ]]; then
  _sweep_skip "broadcast_not_sweepable"
fi

# 세션 UUID
if [[ -z "$UUID" ]]; then
  _sweep_skip "missing_session_id"
fi

# request_id (F2 ACK 매칭 키)
REQUEST_ID=$(echo "$INPUT" | jq -r '.tool_input.message.request_id // empty' 2>/dev/null) || REQUEST_ID=""
[[ -z "$REQUEST_ID" ]] && REQUEST_ID="no_rid_$(date +%s%N)"

# ============================================================================
# [H-2 2026-08-17] shutdown 발신 시각 마커 기록 — 조기 감지용
# 배경: verify-1/diag-1/odev-2 3건이 shutdown_request 2회에도 무응답이었는데
#       메인은 유휴 알림만 보고 추측해야 했다. 마커를 남겨 write_guard 가
#       "N초 미응답" 을 경고할 수 있게 한다. **기록만. 차단·지연 없음.**
# fail-open: 라이브러리 부재/오류/타임아웃 전부 무시하고 기존 흐름 그대로 진행한다.
# 세션 격리: 자기 UUID 하위(session-env/$UUID/evidence/shutdown_sent)에만 쓴다.
# ============================================================================
_H2_LIB="${HARNESS_HOOK_DIR}/lib/orphan_scan.sh"
if [[ -r "$_H2_LIB" ]]; then
  timeout 2 bash -c "source '$_H2_LIB' 2>/dev/null; shutdown_marker_write '$UUID' '$TO'" 2>/dev/null || true
fi

# ============================================================================
# 수신자 pane_id 조회
# ============================================================================
PANE_ID=""
AGENT_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/agents/${TO}"
[ -f "$AGENT_FILE" ] && PANE_ID=$(grep "^pane_id=" "$AGENT_FILE" 2>/dev/null | cut -d= -f2)

if [[ -z "$PANE_ID" ]]; then
  TEAM_NAME=$(cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/team_name" 2>/dev/null || echo "")
  if [[ -n "$TEAM_NAME" ]]; then
    CONFIG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams/${TEAM_NAME}/config.json"
    if [ -f "$CONFIG" ]; then
      PANE_ID=$(jq -r --arg n "$TO" '.members[] | select(.name==$n) | .tmuxPaneId // empty' "$CONFIG" 2>/dev/null | head -1)
    fi
  fi
fi

# 팀 설정에서 못 찾으면 모든 team config 순회
if [[ -z "$PANE_ID" ]]; then
  for CFG in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams"/*/config.json; do
    [ -f "$CFG" ] || continue
    _P=$(jq -r --arg n "$TO" '.members[] | select(.name==$n) | .tmuxPaneId // empty' "$CFG" 2>/dev/null | head -1)
    if [[ -n "$_P" ]]; then
      PANE_ID="$_P"
      break
    fi
  done
fi

if [[ -z "$PANE_ID" ]]; then
  # F12: silent exit 제거 → stderr 경고 + 로깅
  echo "⚠️ [sweep] PANE_ID 조회 실패 TO=${TO} UUID=${UUID}" >&2
  _sweep_skip "pane_id_not_found"
fi

# L-213 보호 (M2): 다른 tmux 세션 소속 pane이면 스킵
MY_TMUX_SESSION=$(tmux display-message -p '#{session_name}' 2>/dev/null || echo "")
PANE_TMUX_SESSION=$(tmux display-message -t "$PANE_ID" -p '#{session_name}' 2>/dev/null || echo "")
if [[ -n "$MY_TMUX_SESSION" && -n "$PANE_TMUX_SESSION" && "$MY_TMUX_SESSION" != "$PANE_TMUX_SESSION" ]]; then
  _sweep_skip "cross_tmux_session" "my=$MY_TMUX_SESSION pane=$PANE_TMUX_SESSION"
fi

# ============================================================================
# 에이전트 타입별 타임아웃
# ============================================================================
_agent_type_from_name() {
  local name="$1"
  local agent_file="$2"
  if [[ -f "$agent_file" ]]; then
    local atype
    atype=$(grep "^agent_type=" "$agent_file" 2>/dev/null | cut -d= -f2)
    [[ -n "$atype" ]] && echo "$atype" && return
  fi
  echo "$name"
}

_timeout_by_type() {
  case "$1" in
    oplan*|oplan_debate*) echo 120 ;;
    odev*) echo 90 ;;
    otest*) echo 60 ;;
    ofinish*|odone*) echo 30 ;;
    *) echo 30 ;;
  esac
}

AGENT_TYPE=$(_agent_type_from_name "$TO" "$AGENT_FILE")
AGENT_TIMEOUT=$(_timeout_by_type "$AGENT_TYPE")

# ============================================================================
# F3: 백그라운드 sweeper를 timeout 30s로 래핑 + PPID 감시
# F2: ACK 2단계 (received 5s×3 → done AGENT_TIMEOUT) → 실패 시 retry_queue + kill
# ============================================================================
PARENT_PID=$$
_log "DISPATCH" "sweeper_pid=pending parent_pid=$PARENT_PID timeout=$AGENT_TIMEOUT"

# F3: timeout 명령으로 서브쉘 전체 수명 제한 (SIGKILL escalation 2초)
# 주의: AGENT_TIMEOUT이 30 초과(oplan 120/odev 90/otest 60)인 경우 해당 값 사용
# G4 (2026-08-23): HARD_LIMIT을 G4_THRESHOLD(AGENT_TIMEOUT×5) + 60초로 확대.
#   배경: 기존 HARD_LIMIT(AGENT_TIMEOUT 또는 30초)이 G4 전체 대기시간(ACK 15s +
#   AGENT_TIMEOUT + G4 추가대기 + 텍스트 샘플링 30s)보다 짧으면 서브쉘이
#   timeout에 의해 중도 강제종료되어 G4 로직이 영영 완주하지 못한다.
#   otest 기준: G4_THRESHOLD=300s → HARD_LIMIT=360s(기존 60s에서 확대).
#   영향 범위: HARD_LIMIT은 이 파일에서 timeout 명령(아래)에만 쓰이므로,
#   ACK 정상 수신 시 서브쉘은 ack_wait_for 성공 즉시 exit 0으로 종료된다
#   (F2/F3/F12 기존 로직은 이 값에 의존하지 않음) — 정상 케이스는 무영향.
# 테스트 전용 오버라이드: 프로덕션 기본값은 30초. G4_SAMPLE_INTERVAL_OVERRIDE 환경변수가
# 설정된 경우에만 그 값을 사용(검증 목적 — 실제 운영 경로에서는 절대 설정되지 않음).
_G4_SAMPLE_INTERVAL="${G4_SAMPLE_INTERVAL_OVERRIDE:-30}"
_G4_THRESHOLD_PRECALC=$(( AGENT_TIMEOUT * 5 ))
HARD_LIMIT=$(( _G4_THRESHOLD_PRECALC + 60 ))

if [[ -f "$AGENT_FILE" && -n "$PANE_ID" ]]; then
  echo "shutdown_sent_at=$(date +%s)" >> "$AGENT_FILE"
fi

nohup timeout -k 2 "${HARD_LIMIT}s" bash -c "
  # F3: PPID 감시 sleep loop (1초 단위)
  PARENT_PID='$PARENT_PID'
  _wait_with_ppid_watch() {
    local _secs=\"\$1\"
    local _i=0
    while [ \"\$_i\" -lt \"\$_secs\" ]; do
      sleep 1
      _i=\$((_i + 1))
      if ! kill -0 \"\$PARENT_PID\" 2>/dev/null; then
        exit 0  # 부모 사망 → 즉시 종료
      fi
    done
  }

  _log_bg() {
    local _reason=\"\$1\"; shift
    local _log_path=\"${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/session-env/${UUID}/logs/shutdown_sweep.log\"
    mkdir -p \"\$(dirname \"\$_log_path\")\" 2>/dev/null
    # rotation
    if [ -f \"\$_log_path\" ]; then
      local _sz
      _sz=\$(stat -c %s \"\$_log_path\" 2>/dev/null || echo 0)
      if [ \"\$_sz\" -gt 1048576 ]; then
        mv \"\$_log_path\" \"\${_log_path}.old\" 2>/dev/null
      fi
    fi
    printf '%s %s to=%s uuid=%s pane=%s rid=%s %s\n' \
      \"\$(date '+%Y-%m-%d %H:%M:%S')\" \
      \"\$_reason\" \
      '$TO' '$UUID' '$PANE_ID' '$REQUEST_ID' \
      \"\$*\" >> \"\$_log_path\" 2>/dev/null
  }

  # F2: ack_utils.sh source
  # shellcheck disable=SC1091
  source \"\${HARNESS_HOOK_DIR}/lib/ack_utils.sh\" 2>/dev/null || {
    _log_bg 'ERR_ACK_UTILS_MISSING'
  }

  # pane_sweeper.sh 선행 로드 (어느 단계에서든 즉시 kill 가능)
  # shellcheck disable=SC1091
  source \"\${HARNESS_HOOK_DIR}/lib/pane_sweeper.sh\" 2>/dev/null

  # F-BASH-EXIT: pane이 이미 bash 상태이면 ACK 대기 없이 즉시 kill
  # 이유: /exit로 bash 탈출한 경우 received ACK를 절대 받을 수 없음
  #       ACK 대기 15s + hook timeout 15s → PPID 사망 → sweeper 종료 → kill 미실행 버그
  if type is_bash_orphan >/dev/null 2>&1 && is_bash_orphan '$PANE_ID'; then
    _log_bg 'BASH_ORPHAN_IMMEDIATE' 'skipping_ack_wait'
    if type kill_bash_pane >/dev/null 2>&1 && kill_bash_pane '$PANE_ID' 'bash_exit(to=$TO)'; then
      _log_bg 'FORCE_KILL_OK' 'immediate'
      if [ -f '$AGENT_FILE' ]; then
        CURRENT_PANE=\$(grep '^pane_id=' '$AGENT_FILE' 2>/dev/null | cut -d= -f2)
        if [ \"\$CURRENT_PANE\" = '$PANE_ID' ]; then
          rm -f '$AGENT_FILE' 2>/dev/null
        fi
      fi
    else
      _log_bg 'FORCE_KILL_FAILED' 'immediate'
    fi
    exit 0
  fi

  # F2: received ACK 대기 — 3회 × 5초 재시도
  _received=0
  if type ack_wait_for >/dev/null 2>&1; then
    for _try in 1 2 3; do
      if ack_wait_for '$UUID' '$TO' '$REQUEST_ID' 'received' 5; then
        _received=1
        _log_bg 'ACK_RECEIVED' \"try=\$_try\"
        break
      fi
      _log_bg 'ACK_RECEIVED_RETRY' \"try=\$_try\"
      # ACK 대기 중 bash 탈출 감지 → 즉시 kill (hook timeout 이내 처리)
      if type is_bash_orphan >/dev/null 2>&1 && is_bash_orphan '$PANE_ID'; then
        _log_bg 'BASH_ORPHAN_DURING_WAIT' \"try=\$_try\"
        if type kill_bash_pane >/dev/null 2>&1 && kill_bash_pane '$PANE_ID' 'bash_exit_during_wait(to=$TO)'; then
          _log_bg 'FORCE_KILL_OK' \"during_wait_try=\$_try\"
          if [ -f '$AGENT_FILE' ]; then
            CURRENT_PANE=\$(grep '^pane_id=' '$AGENT_FILE' 2>/dev/null | cut -d= -f2)
            if [ \"\$CURRENT_PANE\" = '$PANE_ID' ]; then
              rm -f '$AGENT_FILE' 2>/dev/null
            fi
          fi
        else
          _log_bg 'FORCE_KILL_FAILED' \"during_wait_try=\$_try\"
        fi
        exit 0
      fi
      # PPID 감시
      kill -0 \"\$PARENT_PID\" 2>/dev/null || exit 0
    done
  fi

  if [ \"\$_received\" -eq 0 ]; then
    _log_bg 'ACK_RECEIVED_TIMEOUT' 'no_response_in_15s'
    if type retry_queue_append >/dev/null 2>&1; then
      retry_queue_append '$UUID' '$TO' '$REQUEST_ID' 'received_timeout'
    fi
  else
    # received OK → done 대기 (pane이 실제로 claude 종료까지 갈 시간)
    if type ack_wait_for >/dev/null 2>&1; then
      if ack_wait_for '$UUID' '$TO' '$REQUEST_ID' 'done' '$AGENT_TIMEOUT'; then
        _log_bg 'ACK_DONE' 'graceful'
      else
        _log_bg 'ACK_DONE_TIMEOUT' \"waited=$AGENT_TIMEOUT\"
        if type retry_queue_append >/dev/null 2>&1; then
          retry_queue_append '$UUID' '$TO' '$REQUEST_ID' 'done_timeout'
        fi
      fi
    fi
  fi

  # 물리 회수: pane 상태 확인 후 bash 잔류 시 kill (force)
  if type is_bash_orphan >/dev/null 2>&1 && is_bash_orphan '$PANE_ID'; then
    if type kill_bash_pane >/dev/null 2>&1 && kill_bash_pane '$PANE_ID' 'shutdown_sweep(to=$TO)'; then
      _log_bg 'FORCE_KILL_OK'
      # 에이전트 등록 파일 정리 (M3 race 방어)
      if [ -f '$AGENT_FILE' ]; then
        CURRENT_PANE=\$(grep '^pane_id=' '$AGENT_FILE' 2>/dev/null | cut -d= -f2)
        if [ \"\$CURRENT_PANE\" = '$PANE_ID' ]; then
          rm -f '$AGENT_FILE' 2>/dev/null
        fi
      fi
    else
      _log_bg 'FORCE_KILL_FAILED'
    fi
  else
    _log_bg 'PANE_ALREADY_GONE_OR_NOT_BASH' \"g4_check_start\"
    _NO_KILL_MARKER=\"${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/session-env/${UUID}/no_kill/${TO}\"
    if [ -f \"\$_NO_KILL_MARKER\" ]; then
      _log_bg 'G4_SKIP_NO_KILL_MARKER' \"marker=\$_NO_KILL_MARKER\"
    else
      _G4_THRESHOLD=\$(( $AGENT_TIMEOUT * 5 ))
      _G4_STATUS_OK=0
      _G4_STATUS_FILE=\"${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/session-env/${UUID}/status\"
      if source \"\${HARNESS_HOOK_DIR}/lib/state_machine.sh\" 2>/dev/null && type status_read >/dev/null 2>&1; then
        _G4_CUR_STATUS=\$(status_read \"\$_G4_STATUS_FILE\" 2>/dev/null)
        case \"\$_G4_CUR_STATUS\" in
          *PAUSE*|*ABORT*|*RALPH*|__LOCK_FAIL__)
            _log_bg 'G4_SKIP_STATUS' \"status=\$_G4_CUR_STATUS\" ;;
          *)
            _G4_STATUS_OK=1 ;;
        esac
      else
        _log_bg 'G4_SKIP_STATUS_LIB_MISSING'
      fi
      if [ \"\$_G4_STATUS_OK\" -eq 1 ]; then
        _G4_EXTRA_WAIT=\$(( _G4_THRESHOLD > $AGENT_TIMEOUT ? _G4_THRESHOLD - $AGENT_TIMEOUT : 0 ))
        _log_bg 'G4_EXTRA_WAIT_START' \"extra=\${_G4_EXTRA_WAIT}s threshold=\${_G4_THRESHOLD}s\"
        _G4_ELAPSED=0
        _G4_ABORTED=0
        while [ \"\$_G4_ELAPSED\" -lt \"\$_G4_EXTRA_WAIT\" ]; do
          sleep 5
          _G4_ELAPSED=\$((_G4_ELAPSED + 5))
          if ! kill -0 \"\$PARENT_PID\" 2>/dev/null; then
            _G4_ABORTED=1
            break
          fi
          if ! tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qF '$PANE_ID'; then
            _G4_ABORTED=1
            _log_bg 'G4_PANE_GONE_DURING_WAIT'
            break
          fi
          if [ -f \"\$_NO_KILL_MARKER\" ]; then
            _G4_ABORTED=1
            _log_bg 'G4_SKIP_NO_KILL_MARKER_DURING_WAIT'
            break
          fi
        done
        if [ \"\$_G4_ABORTED\" -eq 0 ]; then
          _G4_SAMPLE_1=\$(tmux capture-pane -p -t '$PANE_ID' 2>/dev/null | tail -30)
          sleep $_G4_SAMPLE_INTERVAL
          if kill -0 \"\$PARENT_PID\" 2>/dev/null && tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qF '$PANE_ID' && [ ! -f \"\$_NO_KILL_MARKER\" ]; then
            _G4_SAMPLE_2=\$(tmux capture-pane -p -t '$PANE_ID' 2>/dev/null | tail -30)
            if [ \"\$_G4_SAMPLE_1\" = \"\$_G4_SAMPLE_2\" ]; then
              _log_bg 'G4_TEXT_UNCHANGED' \"confirmed_still\"
              if type kill_bash_pane >/dev/null 2>&1 && kill_bash_pane '$PANE_ID' 'G4_conditional_auto_kill(to=$TO)'; then
                _log_bg 'G4_KILL_OK'
                if [ -f '$AGENT_FILE' ]; then
                  CURRENT_PANE=\$(grep '^pane_id=' '$AGENT_FILE' 2>/dev/null | cut -d= -f2)
                  if [ \"\$CURRENT_PANE\" = '$PANE_ID' ]; then
                    rm -f '$AGENT_FILE' 2>/dev/null
                  fi
                fi
              else
                _log_bg 'G4_KILL_FAILED'
              fi
            else
              _log_bg 'G4_SKIP_TEXT_CHANGED' \"pane_active_still_working\"
            fi
          else
            _log_bg 'G4_SKIP_ABORTED_BEFORE_SAMPLE2'
          fi
        fi
      fi
    fi
  fi
" >/dev/null 2>&1 &

SWEEPER_PID=$!
_log "DISPATCHED" "sweeper_pid=$SWEEPER_PID"

exit 0
