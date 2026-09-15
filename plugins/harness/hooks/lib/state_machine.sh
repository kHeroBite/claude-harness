#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# state_machine.sh — state 전이 단일 진입점 (F1, jury V4 C unanimous 12/12)
#
# 목표: state 파일 쓰기는 반드시 state_transition()을 경유해야 한다.
#   ● CAS(Compare-And-Swap): from 값이 현재와 일치할 때만 전이 성공
#   ● flock -x -w 10: 원자적 배타 쓰기 (경쟁 시 재시도 2회)
#   ● checkpoint.jsonl 자동 기록 (STATE_TRANSITION 이벤트)
#   ● L-362 엄수: lock 블록 안에서는 read→compare→rename 최소 작업만
#
# 사용법:
#   source "$HOOK_DIR/lib/state_machine.sh"
#   state_transition "$STATE_FILE" "PLAN" "DEV" "oi_route" "$UUID"
#
# 반환 코드:
#   0 = 성공 (checkpoint 기록 + state 파일 갱신)
#   1 = CAS 실패 (from ≠ 현재 state — 호출자가 stale 판단)
#   2 = LOCK_FAIL (flock 10초 타임아웃 — 경쟁 과다, 재시도 권장)
#   3 = 인자 오류 / 내부 오류
#
# 허용 전이(가드): 호출자가 from을 명시하므로 state_machine은 형식 검증만 수행.
#   규칙: from/to는 반드시 알려진 state 문자열이어야 함 (unknown → 3 반환).

# state_machine.sh는 session_id.sh의 state_read/state_write를 재사용한다.
# 이미 source 되어 있지 않다면 로드.
if ! declare -f state_read >/dev/null 2>&1; then
  _SMACH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck disable=SC1091
  source "$_SMACH_DIR/session_id.sh"
fi

# === 사이클46 축② — 반대편 base 미러 라이브러리 로드 ===
# CLAUDE_CONFIG_DIR ⇄ $HOME/.claude 양쪽 base 를 정합시킨다.
# ★모든 호출은 flock 블록 "밖" · 쓰기 성공 후에만★ (미러 불변식 3).
# _mirror_file 은 항상 rc=0 이므로 원 쓰기 결과를 훼손하지 않는다 (불변식 1 — fail-soft).
if ! declare -f _mirror_file >/dev/null 2>&1; then
  _SMACH_MIRROR_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/session_mirror.sh"
  # shellcheck source=/dev/null
  [ -f "$_SMACH_MIRROR_LIB" ] && source "$_SMACH_MIRROR_LIB" 2>/dev/null
fi
# 미러 라이브러리 부재 시에도 동작하도록 no-op 폴백을 둔다 (fail-soft).
if ! declare -f _mirror_file >/dev/null 2>&1; then
  _mirror_file() { return 0; }
fi

# 알려진 state 목록 (CLAUDE.md / ok SKILL 기준 — Phase B 마이그레이션 적용)
# 변경 이력 (2026-05-06, L-431):
#   이전: IDLE OK PLAN DEV TEST DONE FINISH EARLY_TERM ERROR (9 stage)
#   현재: IDLE PLAN DEV TEST DONE FINISH EARLY_TERM ERROR (8 stage — OK 제거)
# OK는 stage(축2)에서 제거되고 classification(축1) 토큰으로 이동 (level OK = tier 미정 신호).
# 새 ok 진입 = state="PLAN" + classification="OK" 동시 기록 (별도 INIT stage 신설 안 함).
_SMACH_KNOWN_STATES="IDLE PLAN DEV TEST DONE FINISH EARLY_TERM ERROR"

_smach_is_known_state() {
  local S="$1"
  case " $_SMACH_KNOWN_STATES " in
    *" $S "*) return 0 ;;
    *) return 1 ;;
  esac
}

# === Phase B 자동 마이그레이션 안전망 (L-431) ===
# 다른 활성 세션의 state 파일에 "OK"가 잔존할 경우 자동으로 "PLAN"으로 변환하고
# classification 파일에 "OK"를 기록한다. 1주기 deprecation — 향후 제거 가능.
#
# 호출 시점:
#   - 호출자가 state_read 결과를 받은 후 비교하기 전에 호출하여 OK→PLAN 변환 처리
#
# 호출 형식:
#   _smach_migrate_ok_to_plan "$STATE_FILE" "$UUID" 2>/dev/null
# 반환:
#   0 = 마이그레이션 수행됨 (OK→PLAN 변환 + classification=OK 기록)
#   1 = 변환 불필요(OK 아님) 또는 실패
_smach_migrate_ok_to_plan() {
  local STATE_FILE="${1:-}"
  local UUID_ARG="${2:-${UUID:-${PIPELINE_UUID:-unknown}}}"
  [ -z "$STATE_FILE" ] && return 1
  [ -f "$STATE_FILE" ] || return 1
  local _CUR
  _CUR=$(cat "$STATE_FILE" 2>/dev/null | awk '{print $1}' | tr -d '\r')
  if [ "$_CUR" = "OK" ]; then
    # state=OK 감지 → PLAN으로 변환 + classification=OK 기록
    local _PARENT
    _PARENT=$(dirname "$STATE_FILE")
    local _CLS_FILE="${_PARENT}/classification"
    local _TS
    _TS=$(date -u '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || echo "")
    # 마이그레이션은 1회성 — 보수적으로 직접 mv (CAS 미경유). 경쟁 발생 시에도 다음 호출에서 멱등 재처리.
    local _TMP="${STATE_FILE}.mig.$$"
    printf '%s %s %s %s\n' "PLAN" "$UUID_ARG" "$_TS" "phase_b_auto_migrate_ok_to_plan" > "$_TMP" 2>/dev/null || return 1
    mv -f "$_TMP" "$STATE_FILE" 2>/dev/null || { rm -f "$_TMP"; return 1; }
    printf 'OK\n' > "$_CLS_FILE" 2>/dev/null || true
    # 사이클46 축② — 마이그레이션 결과 2건을 반대편 base 에 미러 (lock 미사용 구간이라 안전)
    _mirror_file "$STATE_FILE"
    _mirror_file "$_CLS_FILE"
    echo "[state_machine] phase_b auto-migrate: state OK→PLAN + classification=OK ($STATE_FILE)" >&2
    return 0
  fi
  return 1
}

# 핵심: state_transition state_file from to reason uuid
# 실패 시 stderr에 짧은 사유 출력.
state_transition() {
  local STATE_FILE="${1:-}"
  local FROM="${2:-}"
  local TO="${3:-}"
  local REASON="${4:-unspecified}"
  local UUID_ARG="${5:-${UUID:-${PIPELINE_UUID:-unknown}}}"

  if [ -z "$STATE_FILE" ] || [ -z "$FROM" ] || [ -z "$TO" ]; then
    echo "[state_machine] ERROR: 인자 부족 (state_file/from/to 필수)" >&2
    return 3
  fi
  # === Phase B 자동 마이그레이션 (L-431, 1주기 deprecation) ===
  # from="OK"인 호출은 기존 코드 호환성 유지를 위해 자동으로 from="PLAN"으로 변환한다.
  # 호출자가 from="OK"를 명시했다면 의도는 "ok 진입 단계"이며, Phase B에서 그 의미는 PLAN+classification=OK이다.
  # state 파일에 OK 잔존 시 _smach_migrate_ok_to_plan으로 함께 정상화.
  if [ "$FROM" = "OK" ]; then
    _smach_migrate_ok_to_plan "$STATE_FILE" "$UUID_ARG" 2>/dev/null || true
    FROM="PLAN"
    echo "[state_machine] phase_b auto: from=OK → from=PLAN (caller=${REASON})" >&2
  fi
  # to="OK"는 절대 금지 — 호출자가 잘못된 마이그레이션 미적용 코드를 사용 중. 거부 + 안내.
  if [ "$TO" = "OK" ]; then
    echo "[state_machine] ERROR: to=OK is removed in Phase B (L-431). Use to=PLAN + classification=OK instead. caller=${REASON}" >&2
    return 3
  fi
  if ! _smach_is_known_state "$FROM"; then
    echo "[state_machine] ERROR: unknown from state: $FROM" >&2
    return 3
  fi
  if ! _smach_is_known_state "$TO"; then
    echo "[state_machine] ERROR: unknown to state: $TO" >&2
    return 3
  fi

  local LOCK_FILE="${STATE_FILE}.lock"
  local TMP_FILE="${STATE_FILE}.tmp.$$"
  local _PARENT
  _PARENT=$(dirname "$STATE_FILE")
  mkdir -p "$_PARENT" 2>/dev/null || true

  # 새 state 라인 사전 작성 (lock 밖)
  # 형식: "<STATE> <UUID> <ISO-TS> <REASON>"
  local _TS
  _TS=$(date -u '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || echo "")
  printf '%s %s %s %s\n' "$TO" "$UUID_ARG" "$_TS" "$REASON" > "$TMP_FILE" || {
    echo "[state_machine] ERROR: tmp 작성 실패: $TMP_FILE" >&2
    return 3
  }

  local _TRY=0
  local _RC=2
  while [ "$_TRY" -lt 3 ]; do
    (
      # L-362: lock 블록 안에서는 read→compare→rename만 (I/O 수집 없음)
      flock -x -w 10 200 || exit 2
      local _CUR_LINE _CUR_STATE
      _CUR_LINE=$(cat "$STATE_FILE" 2>/dev/null || echo "IDLE")
      _CUR_STATE=$(echo "$_CUR_LINE" | awk '{print $1}')
      [ -z "$_CUR_STATE" ] && _CUR_STATE="IDLE"
      if [ "$_CUR_STATE" != "$FROM" ]; then
        exit 1  # CAS 실패
      fi
      mv -f "$TMP_FILE" "$STATE_FILE" || exit 3
      exit 0
    ) 200>"$LOCK_FILE"
    _RC=$?
    if [ "$_RC" -eq 0 ]; then
      break
    elif [ "$_RC" -eq 2 ]; then
      _TRY=$((_TRY + 1))
      sleep 0.2
      continue
    else
      break
    fi
  done

  [ -f "$TMP_FILE" ] && rm -f "$TMP_FILE"

  if [ "$_RC" -eq 0 ]; then
    # 사이클46 축② — 반대편 base 미러.
    # ★위 while 루프의 flock 서브셸이 이미 종료된 지점★이므로 불변식 3(lock 미획득)을 만족한다.
    _mirror_file "$STATE_FILE"
    # checkpoint 기록 (실패해도 silent — 파이프라인 계속)
    local _CW
    _CW="$(dirname "${BASH_SOURCE[0]}")/checkpoint_write.sh"
    if [ -x "$_CW" ]; then
      "$_CW" "$UUID_ARG" "STATE_TRANSITION" "$TO" "" "${AGENT_NAME:-hook}" \
        "from=$FROM to=$TO reason=$REASON" >/dev/null 2>&1 || true
    fi
    # tmux 타이틀바 동기 갱신 (state_write와 동일 메커니즘 — set_terminal_title.sh 내부 가드로 안전)
    source "$(dirname "${BASH_SOURCE[0]}")/set_terminal_title.sh" 2>/dev/null && set_terminal_title "$TO" 2>/dev/null || true
  elif [ "$_RC" -eq 1 ]; then
    echo "[state_machine] CAS 실패: expected=$FROM current=$(state_read "$STATE_FILE" 2>/dev/null | awk '{print $1}') (file=$STATE_FILE)" >&2
  elif [ "$_RC" -eq 2 ]; then
    echo "[state_machine] LOCK_FAIL: flock 10초 타임아웃 x3 (file=$STATE_FILE)" >&2
  fi

  return $_RC
}

# 보조: 현재 state 문자열만 추출 (state_read 결과에서 첫 토큰)
state_current() {
  local STATE_FILE="$1"
  local _LINE
  _LINE=$(state_read "$STATE_FILE" 2>/dev/null)
  if [ "$_LINE" = "__LOCK_FAIL__" ]; then
    echo "__LOCK_FAIL__"
    return 2
  fi
  echo "$_LINE" | awk '{print $1}'
}

# === status 축 헬퍼 (3-axis pipeline flags — set 표현) ===
# 형식: 단일 라인 파이프 OR + 알파벳 정렬. 빈 = NONE.
# sentinel(UNKNOWN, __LOCK_FAIL__) 등재 거부.
_STATUS_VALID_TOKENS="ABORT PAUSE RALPH"
_status_is_valid() {
  case " $_STATUS_VALID_TOKENS NONE " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}
_status_is_sentinel() {
  case "$1" in UNKNOWN|__LOCK_FAIL__) return 0 ;; *) return 1 ;; esac
}
status_read() {
  local F="$1"; local LK="${F}.lock"
  mkdir -p "$(dirname "$LK")" 2>/dev/null || true
  ( flock -s -w 5 200 || { echo "__LOCK_FAIL__"; exit 2; }
    cat "$F" 2>/dev/null | tr -d '[:space:]' || echo ""
  ) 200>"$LK"
}
status_write() {
  local F="$1"; local NEW="$2"; local LK="${F}.lock"; local TMP="${F}.tmp.$$"
  mkdir -p "$(dirname "$F")" 2>/dev/null || true
  # sentinel 거부
  local IFS='|'; local TK; for TK in $NEW; do
    if _status_is_sentinel "$TK"; then echo "[status_write] sentinel rejected: $TK" >&2; return 1; fi
  done
  # 토큰 split → 알파벳 정렬 → uniq → join
  local SORTED
  SORTED=$(printf '%s\n' "$NEW" | tr '|' '\n' | sed '/^$/d' | sort -u | paste -sd'|')
  printf '%s\n' "$SORTED" > "$TMP" || return 1
  ( flock -x -w 5 200 || { rm -f "$TMP"; return 1; }
    mv -f "$TMP" "$F"
  ) 200>"$LK"
  local RC=$?; [ -f "$TMP" ] && rm -f "$TMP"
  # 사이클46 축② — flock 서브셸 종료 후 · 쓰기 성공 시에만 미러 (불변식 3)
  [ "$RC" -eq 0 ] && _mirror_file "$F"
  return $RC
}
status_add() {
  local F="$1"; local TOKEN="$2"
  if _status_is_sentinel "$TOKEN"; then echo "[status_add] sentinel rejected: $TOKEN" >&2; return 1; fi
  if ! _status_is_valid "$TOKEN"; then echo "[status_add] invalid token: $TOKEN" >&2; return 1; fi
  [ "$TOKEN" = "NONE" ] && return 0
  local CUR; CUR=$(status_read "$F" 2>/dev/null)
  [ "$CUR" = "__LOCK_FAIL__" ] && { echo "[status_add] LOCK_FAIL" >&2; return 2; }
  local MERGED; MERGED=$(printf '%s\n%s\n' "$CUR" "$TOKEN" | tr '|' '\n' | sed '/^$/d' | sort -u | paste -sd'|')
  status_write "$F" "$MERGED"
}
status_remove() {
  local F="$1"; local TOKEN="$2"
  local CUR; CUR=$(status_read "$F" 2>/dev/null)
  [ "$CUR" = "__LOCK_FAIL__" ] && return 2
  local NEW; NEW=$(printf '%s\n' "$CUR" | tr '|' '\n' | grep -vxF "$TOKEN" | sed '/^$/d' | sort -u | paste -sd'|')
  status_write "$F" "$NEW"
}
status_clear() {
  status_write "$1" ""
}
status_has() {
  local F="$1"; local TOKEN="$2"
  local CUR; CUR=$(status_read "$F" 2>/dev/null)
  [ "$CUR" = "__LOCK_FAIL__" ] && return 2
  if [ "$TOKEN" = "NONE" ]; then [ -z "$CUR" ] && return 0 || return 1; fi
  printf '%s' "$CUR" | tr '|' '\n' | grep -qxF "$TOKEN"
}
