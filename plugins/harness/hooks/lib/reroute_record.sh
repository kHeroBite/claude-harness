#!/bin/sh
# 역방향 상태 전이를 reroute_log·pipeline_events·reroute_count 에 자동 기록하는 공용 라이브러리
#
# 출처: conv_179065014644_r3 (oralph 3회차) hook (b) — AC-043, 계획 §5-2, review-3 C2
#
# 공용 함수:
#   reroute_observe SESSION_DIR FROM TO SOURCE REASON
#       state 전이 1건을 관찰한다. FROM 이 비면 SESSION_DIR/.state_seen 을 쓴다.
#       · 순방향·동일·IDLE/EARLY_TERM/ERROR 행 → .state_seen 만 갱신
#       · FINISH→PLAN/DEV ∧ status 에 ROOF(구 RALPH 병기) → pipeline_events ROOF_REENTRY (count 불변)
#       · DONE/FINISH→DEV ∧ (auto_loop_active ∨ plans/phase_batches.json)
#                                                  → pipeline_events BATCH_ADVANCE (count 불변)
#       · 그 밖의 역전이:
#           5초 안 같은 from→to 재관찰 → 무시 (이중 관찰 dedupe)
#           600초 안 수동 REROUTE(source≠auto_hook) 있음 → REROUTE_AUTO_CONFIRMED 만 (count 불변)
#           없음 → reroute_log 1줄 + pipeline_events REROUTE(source=auto_hook) + reroute_count +1
#                  + .reroute_auto_pending 기록
#   reroute_manual_increment_adjust SESSION_DIR
#       수동 reroute_count increment 직후 호출한다. 600초 안 자동 기록(.reroute_auto_pending)이 있으면
#       count 를 1회 -1 보정하고 pending 을 소비한다(이중 증가 방지, 단일 사용).
#
# 불변식:
#   1. 모든 공용 함수는 항상 return 0 이다 (fail-soft). 호출자의 전이·쓰기를 절대 막지 않는다.
#   2. 쓰기는 SESSION_DIR 안에만 한다. SESSION_DIR 이름이 UUID 형식이 아니거나, 호출 환경의
#      UUID/PIPELINE_UUID 와 다르면 아무것도 쓰지 않는다 (세션 격리 §(a) fail-closed).
#      SESSION_DIR 자체를 만들지 않는다.
#   3. POSIX sh(dash)·bash 양쪽에서 source 가능하다. 금지: [[ ]] · 배열 · ${BASH_SOURCE} · ${PIPESTATUS}.
#   4. 본문은 서브셸 안에서 돈다 — 호출자의 변수·trap·set -e 에 영향을 주지 않는다.

# --- 반대편 base 미러 (session_mirror.sh 는 dash 호환). 부재 시 no-op ---
# ★command -v / type 로 함수 존재를 묻지 않는다★ — 미정의 이름은 PATH 전체를 뒤지는데, WSL PATH 의
# /mnt/c/… Windows 경로 때문에 1회 약 130ms 가 든다(실측). session_mirror.sh 는 재source 해도 안전(함수 정의만, ~2ms)하므로
# 항상 source 하고, 성공 여부 플래그로 no-op 폴백을 정한다.
_rr_have_mirror=0
if [ -f "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/session_mirror.sh" ]; then
  . "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/session_mirror.sh" 2>/dev/null && _rr_have_mirror=1
elif [ -f "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/session_mirror.sh" ]; then
  . "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/session_mirror.sh" 2>/dev/null && _rr_have_mirror=1
fi
if [ "$_rr_have_mirror" != 1 ]; then
  # 호출자가 이미 정의한 미러 함수는 덮어쓰지 않는다 (bash 는 PATH 를 뒤지지 않는 declare -F 로 확인)
  if [ -n "${BASH_VERSION:-}" ]; then
    eval 'declare -F _mirror_file >/dev/null 2>&1 || _mirror_file() { :; }'
    eval 'declare -F _mirror_delete >/dev/null 2>&1 || _mirror_delete() { :; }'
  else
    _mirror_file() { :; }
    _mirror_delete() { :; }
  fi
fi

# 이중 관찰 창(초)과 수동 기록 대조 창(초)
: "${REROUTE_DEDUPE_SEC:=5}"
: "${REROUTE_MANUAL_WINDOW_SEC:=600}"

# 상태 이름 정규화: 대문자·공백 제거·에이전트명 별칭(otest-1 → TEST)·OK→PLAN
_rr_norm() {
  # 빠른 경로(fork 없음): 이미 정규형인 흔한 값
  case "$1" in
    '') return 0 ;;
    IDLE|PLAN|DEV|TEST|DONE|FINISH|EARLY_TERM|ERROR) printf '%s' "$1"; return 0 ;;
    OK) printf 'PLAN'; return 0 ;;
  esac
  _rr_n=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]' | sed 's/-[0-9][0-9]*$//')
  case "$_rr_n" in
    OK|OPLAN|OPLAN_*) _rr_n=PLAN ;;
    ODEV) _rr_n=DEV ;;
    OTEST|OTEST_*) _rr_n=TEST ;;
    ODONE|ODONE_*) _rr_n=DONE ;;
    OFINISH) _rr_n=FINISH ;;
  esac
  printf '%s' "$_rr_n"
}

# 순위 IDLE0 PLAN1 DEV2 TEST3 DONE4 FINISH5 (그 밖은 빈 문자열)
_rr_rank() {
  case "$1" in
    IDLE) echo 0 ;; PLAN) echo 1 ;; DEV) echo 2 ;; TEST) echo 3 ;; DONE) echo 4 ;; FINISH) echo 5 ;;
    *) echo "" ;;
  esac
}

# JSON 문자열 안전화 (따옴표·역슬래시 제거, 제어문자 → 공백, 200자 제한)
_rr_safe() {
  # 빠른 경로(fork 없음): 빈 값·안전 문자만인 값
  case "$1" in
    '') return 0 ;;
    *[!A-Za-z0-9_.:=/-]*) ;;
    *) printf '%.200s' "$1"; return 0 ;;
  esac
  printf '%s' "$1" | tr -d '"\\' | tr '\n\r\t' '   ' | cut -c1-200
}

# 세션 격리 검사: SESSION_DIR 이름 = UUID 형식 ∧ (환경 UUID/PIPELINE_UUID 가 있으면 그중 하나와 일치)
_rr_session_ok() {
  [ -n "$1" ] && [ -d "$1" ] || return 1
  _rr_b=${1%/}; _rr_b=${_rr_b##*/}
  # UUID 형식 (fork 없는 case 패턴 — 8-4-4-4-12 소문자 hex)
  _rr_h='[0-9a-f]'
  case "$_rr_b" in
    $_rr_h$_rr_h$_rr_h$_rr_h$_rr_h$_rr_h$_rr_h$_rr_h-$_rr_h$_rr_h$_rr_h$_rr_h-$_rr_h$_rr_h$_rr_h$_rr_h-$_rr_h$_rr_h$_rr_h$_rr_h-$_rr_h$_rr_h$_rr_h$_rr_h$_rr_h$_rr_h$_rr_h$_rr_h$_rr_h$_rr_h$_rr_h$_rr_h) ;;
    *) return 1 ;;
  esac
  if [ -n "${UUID:-}" ] || [ -n "${PIPELINE_UUID:-}" ]; then
    [ "$_rr_b" = "${UUID:-}" ] || [ "$_rr_b" = "${PIPELINE_UUID:-}" ] || return 1
  fi
  return 0
}

# 파일 끝에 1줄 추가 + 미러
_rr_append() {
  printf '%s\n' "$2" >> "$1" 2>/dev/null && _mirror_file "$1"
}

# 원자적 덮어쓰기 + 미러
_rr_put() {
  printf '%s\n' "$2" > "$1.tmp.$$" 2>/dev/null && mv -f "$1.tmp.$$" "$1" 2>/dev/null && _mirror_file "$1"
  rm -f "$1.tmp.$$" 2>/dev/null
  return 0
}

# reroute_count 를 flock(reroute_count.lock — oio session_state increment 와 같은 lock) 아래 DELTA 만큼 바꾼다.
# stdout: 새 값 (lock 실패 시 빈 문자열). 0 미만으로 내려가지 않는다.
_rr_count_add() {
  _rr_cf="$1/reroute_count"
  _rr_cn=$(
    (
      flock -x -w 5 9 || exit 1
      _c=$(tr -dc '0-9' < "$_rr_cf" 2>/dev/null)
      [ -z "$_c" ] && _c=0
      _n=$((_c + $2))
      [ "$_n" -lt 0 ] && _n=0
      printf '%s\n' "$_n" > "$_rr_cf.tmp.$$" && mv -f "$_rr_cf.tmp.$$" "$_rr_cf" || exit 1
      echo "$_n"
    ) 9>"$1/reroute_count.lock" 2>/dev/null
  )
  rm -f "$_rr_cf.tmp.$$" 2>/dev/null
  _mirror_file "$_rr_cf"
  # 이 함수가 직접 바꾼 값은 기준선으로 기록한다 (수동 increment 와 구분하기 위함)
  [ -n "$_rr_cn" ] && _rr_base_put "$1" "$_rr_cn"
  [ -n "$_rr_cn" ] && echo "$_rr_cn"
  return 0
}

# 기준선(.reroute_count_seen): lib 이 마지막으로 확인한 reroute_count 값. 없으면 0.
_rr_base_get() {
  _rr_bv=$(tr -dc '0-9' 2>/dev/null < "$1/.reroute_count_seen")
  echo "${_rr_bv:-0}"
}
_rr_base_put() {
  _rr_put "$1/.reroute_count_seen" "$2"
}
# 현재 reroute_count 값 (없으면 0)
_rr_cur_get() {
  _rr_cv=$(tr -dc '0-9' 2>/dev/null < "$1/reroute_count")
  echo "${_rr_cv:-0}"
}

# 최근 수동 REROUTE 이벤트(source≠auto_hook) 중 TO(필수)·FROM(상태명일 때만) 일치 ∧ ts ≥ SINCE ∧ 미소비 1건을 찾는다.
# 인자: SESSION_DIR FROM TO SINCE_EPOCH   stdout: "ts|from|to" 키 (없으면 빈 문자열)
_rr_find_manual() {
  _rr_ev="$1/logs/pipeline_events.jsonl"
  [ -f "$_rr_ev" ] || return 0
  _rr_cons="$1/.reroute_manual_consumed"
  tail -n 300 "$_rr_ev" 2>/dev/null | awk '
    function getf(l, k,   i, s, e) {
      i = index(l, "\"" k "\":\""); if (i == 0) return "";
      s = substr(l, i + length(k) + 4); e = index(s, "\""); return substr(s, 1, e - 1)
    }
    index($0, "\"event\":\"REROUTE\"") && !index($0, "\"source\":\"auto_hook\"") {
      print getf($0, "ts") "|" getf($0, "from") "|" getf($0, "to")
    }' | tac 2>/dev/null | while IFS='|' read -r _ts _f _t; do
      [ -n "$_ts" ] || continue
      [ "$(_rr_norm "$_t")" = "$3" ] || continue
      _nf=$(_rr_norm "$_f")
      if [ -n "$(_rr_rank "$_nf")" ] && [ "$_nf" != "$2" ]; then continue; fi
      _ep=$(date -d "$_ts" +%s 2>/dev/null) || continue
      [ "$_ep" -ge "$4" ] || continue
      if [ -f "$_rr_cons" ] && grep -qxF "$_ts|$_f|$_t" "$_rr_cons" 2>/dev/null; then continue; fi
      printf '%s|%s|%s\n' "$_ts" "$_f" "$_t"
      break
    done
}

_rr_observe_main() {
  _D="$1"; _SRC=$(_rr_safe "${4:-unknown}"); _RSN=$(_rr_safe "${5:-}")
  _rr_session_ok "$_D" || return 0
  _T=$(_rr_norm "$3")
  [ -n "$_T" ] || return 0
  _F=$(_rr_norm "$2")
  if [ -z "$_F" ]; then
    _F=$(_rr_norm "$(awk 'NR==1{print $1}' "$_D/.state_seen" 2>/dev/null)")
  fi
  _NOW=$(date +%s)
  # 관찰 기준점은 항상 갱신한다 (재시작·compact 뒤에도 남는 파일)
  _rr_put "$_D/.state_seen" "$_T $_NOW $_SRC"
  [ -n "$_F" ] || return 0
  _RF=$(_rr_rank "$_F"); _RT=$(_rr_rank "$_T")
  [ -n "$_RF" ] && [ -n "$_RT" ] || return 0
  [ "$_RT" -lt "$_RF" ] || return 0
  case "$_T" in IDLE|EARLY_TERM|ERROR) return 0 ;; esac

  # 이중 관찰 dedupe (state_transition + session_state, bash_pre + 사후 관찰 등)
  if [ -f "$_D/.reroute_last" ]; then
    read -r _le _lf _lt < "$_D/.reroute_last" 2>/dev/null || true
    case "${_le:-}" in ''|*[!0-9]*) _le="" ;; esac
    if [ "${_lf:-}" = "$_F" ] && [ "${_lt:-}" = "$_T" ] && [ -n "${_le:-}" ] \
       && [ $((_NOW - _le)) -le "$REROUTE_DEDUPE_SEC" ] 2>/dev/null; then
      return 0
    fi
  fi
  _rr_put "$_D/.reroute_last" "$_NOW $_F $_T"

  mkdir -p "$_D/logs" 2>/dev/null || true
  _EV="$_D/logs/pipeline_events.jsonl"
  _TS=$(date -Iseconds 2>/dev/null)

  # (1) ROOF 재진입 — oroof/oto 반복은 자체 카운터를 쓴다
  if [ "$_F" = "FINISH" ] && { [ "$_T" = "PLAN" ] || [ "$_T" = "DEV" ]; } && _rr_has_roof "$_D"; then
    _rr_base_put "$_D" "$(_rr_cur_get "$_D")"
    _rr_append "$_EV" "{\"ts\":\"$_TS\",\"event\":\"ROOF_REENTRY\",\"from\":\"$_F\",\"to\":\"$_T\",\"reason\":\"$_RSN\",\"source\":\"auto_hook\",\"via\":\"$_SRC\"}"
    return 0
  fi

  # (2) Phase Batch Auto-Loop 진행 (review-3 C2) — 다음 batch 진입은 역라우팅이 아니다
  if { [ "$_F" = "DONE" ] || [ "$_F" = "FINISH" ]; } && [ "$_T" = "DEV" ] && _rr_batch_active "$_D"; then
    _rr_base_put "$_D" "$(_rr_cur_get "$_D")"
    _rr_append "$_EV" "{\"ts\":\"$_TS\",\"event\":\"BATCH_ADVANCE\",\"from\":\"$_F\",\"to\":\"$_T\",\"reason\":\"$_RSN\",\"source\":\"auto_hook\",\"via\":\"$_SRC\"}"
    return 0
  fi

  # (3) 같은 전이의 수동 기록이 먼저 있었으면 확인 기록만 (count 불변)
  _M=$(_rr_find_manual "$_D" "$_F" "$_T" $((_NOW - REROUTE_MANUAL_WINDOW_SEC)))
  if [ -n "$_M" ]; then
    _rr_append "$_D/.reroute_manual_consumed" "$_M"
    _C=$(tr -dc '0-9' < "$_D/reroute_count" 2>/dev/null)
    _rr_base_put "$_D" "${_C:-0}"
    _rr_append "$_EV" "{\"ts\":\"$_TS\",\"event\":\"REROUTE_AUTO_CONFIRMED\",\"from\":\"$_F\",\"to\":\"$_T\",\"count\":${_C:-0},\"reason\":\"$_RSN\",\"source\":\"auto_hook\",\"via\":\"$_SRC\",\"auto_confirmed\":true}"
    return 0
  fi

  # (3b) 수동 increment 가 먼저 센 경우 — 기준선 비교 + reroute_count mtime 창 (hook 생략·이벤트 부재와 무관)
  _CUR=$(_rr_cur_get "$_D"); _BASE=$(_rr_base_get "$_D")
  if [ "$_CUR" -lt "$_BASE" ] 2>/dev/null; then
    _rr_base_put "$_D" "$_CUR"
  elif [ "$_CUR" -gt "$_BASE" ] 2>/dev/null; then
    _MT=$(stat -c %Y "$_D/reroute_count" 2>/dev/null)
    _rr_base_put "$_D" "$_CUR"
    case "${_MT:-}" in ''|*[!0-9]*) _MT="" ;; esac
    if [ -n "$_MT" ] && [ $((_NOW - _MT)) -le "$REROUTE_MANUAL_WINDOW_SEC" ] 2>/dev/null; then
      _rr_append "$_EV" "{\"ts\":\"$_TS\",\"event\":\"REROUTE_MANUAL_PRECEDED\",\"from\":\"$_F\",\"to\":\"$_T\",\"count\":$_CUR,\"reason\":\"$_RSN\",\"source\":\"auto_hook\",\"via\":\"$_SRC\"}"
      return 0
    fi
  fi

  # (4) 자동 기록 — reroute_log + pipeline_events + reroute_count +1 + pending
  _C=$(_rr_count_add "$_D" 1)
  _CJ=${_C:-null}
  _rr_append "$_D/reroute_log" "[$(date +%Y-%m-%dT%H:%M:%S)] from:auto($_SRC) to:$_T reason:$_F→$_T $_RSN"
  _rr_append "$_EV" "{\"ts\":\"$_TS\",\"event\":\"REROUTE\",\"from\":\"$_F\",\"to\":\"$_T\",\"count\":$_CJ,\"reason\":\"$_RSN\",\"source\":\"auto_hook\",\"via\":\"$_SRC\"}"
  [ -n "$_C" ] && _rr_put "$_D/.reroute_auto_pending" "$_NOW $_F $_T"
  return 0
}

# status 파일에 ROOF 토큰이 있는가 (형식: 파이프 OR, 예 "PAUSE|ROOF")
_rr_has_roof() {
  [ -f "$1/status" ] || return 1
  # ROOF-COMPAT(deprecation window 1주기 — 구 RALPH/oralph_active 인식 제거 예정)
  tr '|' '\n' < "$1/status" 2>/dev/null | tr -d ' \t\r' | grep -qxE '(ROOF|RALPH)'
}

# Phase Batch 진행 중인가 (auto_loop_active 또는 plans/phase_batches.json)
# ★정확한 파일명만 본다★ — ok_pipeline·ofinish 가 읽는 파일은 plans/phase_batches.json 하나다(스킬 grep 실측).
# glob(phase_batches*.json)은 옛 사이클 사본(phase_batches_conv_*.json 등)이 남은 세션의 정상 역라우팅을
# BATCH_ADVANCE 로 오분류해 count 를 누락시킨다(이 세션 plans/ 실측, ohook-4 지적 — b13).
_rr_batch_active() {
  [ -e "$1/auto_loop_active" ] && return 0
  [ -e "$1/plans/phase_batches.json" ] && return 0
  return 1
}

_rr_adjust_main() {
  _D="$1"
  _rr_session_ok "$_D" || return 0
  _P="$_D/.reroute_auto_pending"
  [ -f "$_P" ] || return 0
  read -r _pe _pf _pt < "$_P" 2>/dev/null || true
  case "${_pe:-}" in ''|*[!0-9]*) _pe="" ;; esac
  _NOW=$(date +%s)
  if [ -z "${_pe:-}" ] || [ $((_NOW - _pe)) -gt "$REROUTE_MANUAL_WINDOW_SEC" ] 2>/dev/null; then
    rm -f "$_P" 2>/dev/null; _mirror_delete "$_P"
    return 0
  fi
  # 계획 §5-2: 자동 기록 뒤 600초 안의 수동 increment 는 pending 만으로 1회 보정한다(pending 단일 사용).
  # 수동 이벤트 대조를 요구하지 않는 이유: ok_pipeline 역라우팅 절차는 같은 블록 안에 increment 선행 순서와
  # "실행_순서 1→2→3"(events 선행)이 함께 적혀 있어, increment 시점(이 hook 이 도는 유일한 순간)에
  # 수동 이벤트가 아직 없을 수 있다(ohook-4 b8 실측). 대가: 자동 기록 600초 안의 비전이 increment(재spawn 등)
  # 1회가 함께 상쇄될 수 있다 — hb_report 한계로 공개.
  _M=$(_rr_find_manual "$_D" "$_pf" "$_pt" "$_pe")
  [ -n "$_M" ] && _rr_append "$_D/.reroute_manual_consumed" "$_M"
  _C=$(_rr_count_add "$_D" -1)
  rm -f "$_P" 2>/dev/null; _mirror_delete "$_P"
  mkdir -p "$_D/logs" 2>/dev/null || true
  _rr_append "$_D/logs/reroute_dedupe.log" "$(date -Iseconds 2>/dev/null) ADJUST -1 pending=$_pe $_pf→$_pt manual=$_M count=${_C:-lock_fail}"
  _rr_append "$_D/logs/pipeline_events.jsonl" "{\"ts\":\"$(date -Iseconds 2>/dev/null)\",\"event\":\"REROUTE_DEDUPE_ADJUST\",\"from\":\"$_pf\",\"to\":\"$_pt\",\"count\":${_C:-null},\"source\":\"auto_hook\"}"
  return 0
}

reroute_observe() {
  ( _rr_observe_main "$@" ) >/dev/null 2>&1 || true
  return 0
}

reroute_manual_increment_adjust() {
  ( _rr_adjust_main "$@" ) >/dev/null 2>&1 || true
  return 0
}
