#!/bin/bash
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
  #
  # [c182 H-2 근본 수정] 이 hook 은 ★응답한 팀원 프로세스★ 에서 돈다. 그래서 .session_id(=UUID)는
  #   팀원 자신의 세션이고, 마커는 ★리드 UUID★ 하위에 있다 → 종전 코드는 한 번도 지우지 못했다(실측
  #   shutdown_response 7건 전부 팀원 UUID 로그에만 존재). 아울러 resolve_sender_from_tmux 는
  #   "PANE|NAME" 을 돌려주는데 그대로 정규화해 '81odev-6' 이 되어 이름도 맞지 않았다.
  #   1순위: 조상 argv(--agent-id NAME@TEAM + --parent-session-id LEAD) 를 chain_agent_resolve 로 읽고,
  #          리드 session-env/team_name == TEAM 소유 검증까지 통과한 경우에만 ★리드 UUID 의 자기 이름 마커★
  #          하나를 지운다(그 외 타 세션 파일은 건드리지 않는다 — §a).
  #   2순위(증명 실패): 종전 경로(자기 UUID)에서 이름만 바로잡아 해제 시도 + H2_CLEAR_UNPROVEN 기록.
  #          이 경우 리드 마커는 남고, 판정 측(orphan_scan shutdown_stale_list 의 pane 소멸·spawned_at
  #          제외)이 오탐을 흡수한다.
  if [[ "$MSG_TYPE" == "shutdown_response" && -n "${UUID:-}" ]]; then
    _H2_LIB_R="${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/orphan_scan.sh"
    _H2_ACK="${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/ack_utils.sh"
    _H2_CA="${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/chain_agent.sh"
    if [[ -r "$_H2_LIB_R" ]]; then
      # 본 프로세스에서 직접 호출한다 — chain_agent_resolve 는 $$ 부터 조상 6단계만 본다.
      #   timeout·$( ) 서브셸로 감싸면 그만큼 단계를 잃어 claude 프로세스에 못 닿을 수 있다.
      #   (함수 정의만 있는 파일이고 /proc 읽기뿐이라 블로킹 위험 없음. 실패는 if 조건이라 ERR trap 미발동.)
      _H2_LEAD=""; _H2_NAME=""
      if [[ -r "$_H2_CA" ]] && source "$_H2_CA" 2>/dev/null && chain_agent_resolve 2>/dev/null; then
        _H2_LEAD="${CA_LEAD:-}"; _H2_NAME="${CA_NAME:-}"
      fi
      if [[ "$_H2_LEAD" =~ ^[0-9a-f-]{36}$ && "$_H2_NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
        timeout 2 bash -c "source '$_H2_LIB_R' 2>/dev/null; shutdown_marker_clear '$_H2_LEAD' '$_H2_NAME'" 2>/dev/null || true
        _log "H2_CLEAR" "lead=$_H2_LEAD name=$_H2_NAME proof=argv"
      else
        _H2_SELF=""
        if [[ -r "$_H2_ACK" ]]; then
          _H2_SELF=$(timeout 2 bash -c "source '$_H2_ACK' 2>/dev/null; resolve_sender_from_tmux '$UUID' 2>/dev/null" 2>/dev/null) || _H2_SELF=""
          _H2_SELF="${_H2_SELF##*|}"
        fi
        if [[ -n "$_H2_SELF" ]]; then
          timeout 2 bash -c "source '$_H2_LIB_R' 2>/dev/null; shutdown_marker_clear '$UUID' '$_H2_SELF'" 2>/dev/null || true
        fi
        _log "H2_CLEAR_UNPROVEN" "self=${_H2_SELF:-?} 리드 소유 증명 실패 — 판정 측 제외(pane 소멸·spawned_at)에 위임"
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
_H2_LIB="${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/orphan_scan.sh"
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
# [c182 H-2] -t 보완 — 미지정 시 hook 의 pane 이 아니라 클라이언트 활성 pane 의 세션을 읽는다.
if [[ "${TMUX_PANE:-}" =~ ^%[0-9]+$ ]]; then
  MY_TMUX_SESSION=$(tmux display-message -t "$TMUX_PANE" -p '#{session_name}' 2>/dev/null || echo "")
else
  MY_TMUX_SESSION=$(tmux display-message -p '#{session_name}' 2>/dev/null || echo "")
fi
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
# [c182] 생존 기준 = 조상 체인의 ★리드 claude 프로세스★ PID.
#   종전 PARENT_PID=$$ 는 이 hook 자신인데, hook 은 아래 nohup 디스패치 직후 exit 0 한다.
#   그래서 sweeper 는 첫 재시도(5초) 뒤 kill -0 실패로 항상 종료됐다(실측: 리드 로그 ACK_RECEIVED_RETRY
#   132건 전부 try=1, try=2 이상 0건). 5초 넘게 늦은 ACK 는 한 번도 잡힌 적이 없다.
#   판별: argv0 가 */claude/versions/* 이거나 basename 이 claude 인 첫 조상(최대 8단계).
#   못 찾으면 빈 값 → 생존 확인 생략, 재시도 횟수·HARD_LIMIT(timeout) 상한까지만 돈다(무한 대기 없음).
_sweep_lead_pid() {
  local _p=$$ _i _a0 _s
  for _i in 1 2 3 4 5 6 7 8; do
    [[ "$_p" =~ ^[0-9]+$ ]] && (( _p > 1 )) || return 1
    _a0=""
    if [[ -r "/proc/$_p/cmdline" ]]; then
      IFS= read -r -d '' _a0 < "/proc/$_p/cmdline" || true
    fi
    case "$_a0" in
      */claude/versions/*|claude|*/claude) printf '%s' "$_p"; return 0 ;;
    esac
    _s=$(<"/proc/$_p/stat") || return 1
    _s="${_s##*) }"
    read -r _ _p _ <<<"$_s"
  done
  return 1
}
PARENT_PID=$(_sweep_lead_pid 2>/dev/null) || PARENT_PID=""
_log "DISPATCH" "sweeper_pid=pending parent_pid=${PARENT_PID:-none} timeout=$AGENT_TIMEOUT"

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
# [c182] received 대기 = 5초 × _RECV_TRIES (AGENT_TIMEOUT 만큼, 최소 종전 3회).
#   종전 3회(15초)는 PARENT_PID 결함 때문에 실제로는 5초였고, 정상화해도 15초는 짧다.
#   최악 경로 = received(AT) + done(AT) + G4 추가대기(4AT) + 샘플 30s → HARD_LIMIT 을 6AT+60 으로 맞춘다.
_RECV_TRIES=$(( AGENT_TIMEOUT / 5 ))
(( _RECV_TRIES < 3 )) && _RECV_TRIES=3
HARD_LIMIT=$(( AGENT_TIMEOUT * 6 + 60 ))

if [[ -f "$AGENT_FILE" && -n "$PANE_ID" ]]; then
  echo "shutdown_sent_at=$(date +%s)" >> "$AGENT_FILE"
fi

nohup timeout -k 2 "${HARD_LIMIT}s" bash -c "
  # F3: PPID 감시 sleep loop (1초 단위)
  PARENT_PID='$PARENT_PID'
  # [c182] 리드 생존 확인 — PID 미상이면 참(상한은 재시도 횟수·timeout HARD_LIMIT 이 보장).
  _lead_alive() {
    [ -z \"\$PARENT_PID\" ] && return 0
    kill -0 \"\$PARENT_PID\" 2>/dev/null
  }
  _wait_with_ppid_watch() {
    local _secs=\"\$1\"
    local _i=0
    while [ \"\$_i\" -lt \"\$_secs\" ]; do
      sleep 1
      _i=\$((_i + 1))
      if ! _lead_alive; then
        exit 0  # 리드 사망 → 즉시 종료
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
  source \"\${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/ack_utils.sh\" 2>/dev/null || {
    _log_bg 'ERR_ACK_UTILS_MISSING'
  }

  # pane_sweeper.sh 선행 로드 (어느 단계에서든 즉시 kill 가능)
  # shellcheck disable=SC1091
  source \"\${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/pane_sweeper.sh\" 2>/dev/null

  # F-BASH-EXIT: pane이 이미 bash 상태이면 ACK 대기 없이 즉시 kill
  # 이유: /exit로 bash 탈출한 경우 received ACK를 절대 받을 수 없음
  #       ACK 대기 15s + hook timeout 15s → PPID 사망 → sweeper 종료 → kill 미실행 버그
  if declare -F is_bash_orphan >/dev/null 2>&1 && is_bash_orphan '$PANE_ID'; then
    _log_bg 'BASH_ORPHAN_IMMEDIATE' 'skipping_ack_wait'
    if declare -F kill_bash_pane >/dev/null 2>&1 && kill_bash_pane '$PANE_ID' 'bash_exit(to=$TO)'; then
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

  # F2: received ACK 대기 — $_RECV_TRIES 회 × 5초 재시도 (c182: 리드 생존 동안, 횟수 상한)
  _received=0
  if declare -F ack_wait_for >/dev/null 2>&1; then
    _try=0
    while [ \"\$_try\" -lt $_RECV_TRIES ]; do
      _try=\$((_try + 1))
      if ack_wait_for '$UUID' '$TO' '$REQUEST_ID' 'received' 5; then
        _received=1
        _log_bg 'ACK_RECEIVED' \"try=\$_try\"
        break
      fi
      _log_bg 'ACK_RECEIVED_RETRY' \"try=\$_try\"
      # ACK 대기 중 bash 탈출 감지 → 즉시 kill (hook timeout 이내 처리)
      if declare -F is_bash_orphan >/dev/null 2>&1 && is_bash_orphan '$PANE_ID'; then
        _log_bg 'BASH_ORPHAN_DURING_WAIT' \"try=\$_try\"
        if declare -F kill_bash_pane >/dev/null 2>&1 && kill_bash_pane '$PANE_ID' 'bash_exit_during_wait(to=$TO)'; then
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
      # 리드 생존 감시 (c182: hook 자신이 아니라 리드 claude)
      if ! _lead_alive; then
        _log_bg 'LEAD_GONE' \"try=\$_try\"
        exit 0
      fi
    done
  fi

  if [ \"\$_received\" -eq 0 ]; then
    _log_bg 'ACK_RECEIVED_TIMEOUT' \"no_response_in_\$(( $_RECV_TRIES * 5 ))s\"
    if declare -F retry_queue_append >/dev/null 2>&1; then
      retry_queue_append '$UUID' '$TO' '$REQUEST_ID' 'received_timeout'
    fi
  else
    # received OK → done 대기 (pane이 실제로 claude 종료까지 갈 시간)
    if declare -F ack_wait_for >/dev/null 2>&1; then
      if ack_wait_for '$UUID' '$TO' '$REQUEST_ID' 'done' '$AGENT_TIMEOUT'; then
        _log_bg 'ACK_DONE' 'graceful'
      else
        _log_bg 'ACK_DONE_TIMEOUT' \"waited=$AGENT_TIMEOUT\"
        if declare -F retry_queue_append >/dev/null 2>&1; then
          retry_queue_append '$UUID' '$TO' '$REQUEST_ID' 'done_timeout'
        fi
      fi
    fi
  fi

  # 물리 회수: pane 상태 확인 후 bash 잔류 시 kill (force)
  if declare -F is_bash_orphan >/dev/null 2>&1 && is_bash_orphan '$PANE_ID'; then
    if declare -F kill_bash_pane >/dev/null 2>&1 && kill_bash_pane '$PANE_ID' 'shutdown_sweep(to=$TO)'; then
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
      if source \"\${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/state_machine.sh\" 2>/dev/null && declare -F status_read >/dev/null 2>&1; then
        _G4_CUR_STATUS=\$(status_read \"\$_G4_STATUS_FILE\" 2>/dev/null)
        case \"\$_G4_CUR_STATUS\" in
          # ROOF-COMPAT(deprecation window 1주기 — 구 RALPH/oralph_active 인식 제거 예정)
          *PAUSE*|*ABORT*|*ROOF*|*RALPH*|__LOCK_FAIL__)
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
          if ! _lead_alive; then
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
          if _lead_alive && tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qF '$PANE_ID' && [ ! -f \"\$_NO_KILL_MARKER\" ]; then
            _G4_SAMPLE_2=\$(tmux capture-pane -p -t '$PANE_ID' 2>/dev/null | tail -30)
            if [ \"\$_G4_SAMPLE_1\" = \"\$_G4_SAMPLE_2\" ]; then
              _log_bg 'G4_TEXT_UNCHANGED' \"confirmed_still\"
              if declare -F kill_bash_pane >/dev/null 2>&1 && kill_bash_pane '$PANE_ID' 'G4_conditional_auto_kill(to=$TO)'; then
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
