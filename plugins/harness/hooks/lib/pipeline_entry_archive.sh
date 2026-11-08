#!/bin/bash
# 파이프라인 진입 시 이전 사이클 잔존물을 logs/prev_cycle/<시각>/ 로 보관 이동하고 진입 표식을 남기는 공용 라이브러리
#
# 사용 (source 후 호출):
#   source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/pipeline_entry_archive.sh"
#   pea_archive <UUID> <via> [value] [stale]   # 보관 이동. rc 0=이동 수행(또는 옮길 것 없음), 1=스킵(조건 불충족)
#   pea_stamp   <UUID>                         # evidence/ok_started·pipeline_start_time 기록 + heartbeat touch
#
# 호출처 (판정 규칙은 이 파일 하나에만 둔다 — 두 곳이 같아야 하므로):
#   - PreToolUse_pipeline_entry_reset.sh : session_state IDLE→PLAN|DEV|OK 전이 (via=entry_reset)
#   - phase_guard.sh                     : Skill(ok|ok_*|o1~o5) 직후 IDLE|FINISH→PLAN CAS 성공 분기 (via=phase_guard)
#     phase_guard 가 PLAN 을 먼저 쓰기 때문에 entry_reset 은 늘 NOT_IDLE_SKIP 이 되던 문제(사이클194 (a))를 메운다.
#
# 호출자 책임 (이 라이브러리는 검사하지 않는다):
#   - UUID 가 자기 세션인지(R3), force 전이가 아닌지(R2), 현재 state 가 진입 직전 상태(IDLE 등)인지
#
# 이 라이브러리가 검사하는 스킵 조건 (rc=1, 로그 1줄):
#   - UUID 형식 아님 (경로 탈출 방지)
#   - 대상 base 디렉토리 없음
#   - status 에 ROOF(구 RALPH — ROOF-COMPAT(deprecation window 1주기)) — oroof 루프 재진입은 진행 중 사이클의 evidence 를 써야 한다
#   - R4: evidence/ok_started 있음 + ofinish_done·ofinish_cleanup_done 없음 + stale 아님 → 정상 종료되지 않은 사이클
#         같은 base 의 ok_started 가 ofinish_done 보다 엄격히 새것이면 오래된 완료 표식으로 보고 미완료 취급한다(결함3 GF).
#         stale 판정: 4번째 인자(0|1)가 주어지면 그것을, 없으면 각 base state 줄의 stale_ 유무를 본다.
#
# 스킵 경로(ROOF·미완료)에서도 세션 루트 acceptance_criteria.json 만은 보관한다(로그 태그 ROOT_AC_ARCHIVED).
# 보관 대상 (각 base 마다, 같은 상대 경로로 이동):
#   evidence/ 안 항목 전부, .phase_batches.written, plans/phase_batches.json, current_phase_batch,
#   plans/acceptance_criteria.json, acceptance_criteria.json (세션 루트 — 결함2 GF),
#   plans/ac_edit_approval.json (미소비 AC 편집 승인 마커 — c215)
# 두 base(${CLAUDE_CONFIG_DIR}/session-env, $HOME/.claude/session-env)를 realpath 로 중복 제거해 처리한다.
# 로그: 각 base 의 logs/pipeline_entry_reset.log (via= 로 호출처 구분)
# 삭제는 하지 않는다. 실패는 조용히 넘어간다(호출 hook 을 막지 않는다).

# 대상 base 디렉토리 목록 (개행 구분) — 결과는 _PEA_DIRS
_pea_dirs() {
  local _u="$1" _b _d _r _seen=""
  _PEA_DIRS=""
  for _b in "${CLAUDE_CONFIG_DIR:-}" "$HOME/.claude"; do
    [ -n "$_b" ] || continue
    _d="${_b}/session-env/${_u}"
    [ -d "$_d" ] || continue
    _r=$(readlink -f "$_d" 2>/dev/null) || _r="$_d"
    case " $_seen " in *" $_r "*) continue ;; esac
    _seen="$_seen $_r"
    _PEA_DIRS="${_PEA_DIRS}${_PEA_DIRS:+
}${_d}"
  done
  [ -n "$_PEA_DIRS" ]
}

# 모든 base 의 logs/pipeline_entry_reset.log 에 1줄
_pea_log() {
  local _ts _d
  _ts=$(date '+%Y-%m-%dT%H:%M:%S%z')
  while IFS= read -r _d; do
    [ -n "$_d" ] || continue
    mkdir -p "${_d}/logs" 2>/dev/null
    echo "${_ts} uuid=${_PEA_UUID} value=${_PEA_VALUE} via=${_PEA_VIA} $*" >> "${_d}/logs/pipeline_entry_reset.log" 2>/dev/null || true
  done <<EOF_PEA
$_PEA_DIRS
EOF_PEA
}

# 상대경로 1개 이동 — 호출 측 지역변수 _moved 에 누적 (bash 동적 스코프)
_pea_mv() {
  local _d="$1" _dest="$2" _rel="$3"
  [ -e "${_d}/${_rel}" ] || [ -L "${_d}/${_rel}" ] || return 0
  # L-1393: 슬래시 선기록 시각(_ref=state 파일)보다 새 항목은 이번 사이클 산출물이므로 옮기지 않는다.
  #   같은 시각(-nt 거짓)은 이전 사이클로 보고 옮긴다(보수). 경계가 없으면(_ref 빈값) 종전과 같다.
  if [ -n "${_ref:-}" ] && [ "${_d}/${_rel}" -nt "$_ref" ]; then return 0; fi
  mkdir -p "$(dirname "${_dest}/${_rel}")" 2>/dev/null || return 0
  mv -f "${_d}/${_rel}" "${_dest}/${_rel}" 2>/dev/null && _moved="${_moved}${_moved:+,}${_rel}"
  return 0
}

# 슬래시 선기록 경계: state 첫 토큰 PLAN + teamcreate_force_ 토큰이면 그 state 파일 경로를 돌려준다(없으면 rc 1).
_pea_bound() {
  local _f="${1}/state" _l
  [ -f "$_f" ] || return 1
  _l=$(head -n1 "$_f" 2>/dev/null)
  [ "${_l%% *}" = "PLAN" ] || return 1
  case " $_l " in *" teamcreate_force_"*) printf '%s' "$_f"; return 0 ;; esac
  return 1
}

# 스킵 경로(ROOF·미완료) 전용: 세션 루트 acceptance_criteria.json 옛 사본만 logs/prev_cycle 로 이동한다(삭제 없음).
#   루트 AC 를 쓰는 주체가 없어 루트 사본은 늘 옛 잔존물이며, 남으면 verify_crud_executed.py 가 CRITERIA_SOURCE_CONFLICT 로 거부한다.
#   plans/ AC·evidence 등 나머지는 스킵 경로에서 종전대로 보존한다. L-1393 경계(_ref)보다 새 파일은 옮기지 않는다.
_pea_root_ac_sweep() {
  local _d _dest _moved _ref _TS _ts
  _TS="$(date '+%Y%m%dT%H%M%S')-$$"
  while IFS= read -r _d; do
    [ -n "$_d" ] || continue
    _dest="${_d}/logs/prev_cycle/${_TS}"
    _moved=""
    _ref=$(_pea_bound "$_d") || _ref=""
    _pea_mv "$_d" "$_dest" "acceptance_criteria.json"
    if [ -n "$_moved" ]; then
      _ts=$(date '+%Y-%m-%dT%H:%M:%S%z')
      mkdir -p "${_d}/logs" 2>/dev/null
      echo "${_ts} uuid=${_PEA_UUID} value=${_PEA_VALUE} via=${_PEA_VIA} ROOT_AC_ARCHIVED dest=logs/prev_cycle/${_TS} files=${_moved}" >> "${_d}/logs/pipeline_entry_reset.log" 2>/dev/null || true
    fi
  done <<EOF_PEA
$_PEA_DIRS
EOF_PEA
  return 0
}

pea_archive() {
  _PEA_UUID="${1:-}"; _PEA_VIA="${2:-unknown}"; _PEA_VALUE="${3:-PLAN}"
  local _stale_hint="${4:-}"
  printf '%s' "$_PEA_UUID" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || return 1
  _pea_dirs "$_PEA_UUID" || return 1

  local _d _line _stale=0 _states="" _first _has_start=0 _has_fin=0 _roof=0 _unfin=0
  while IFS= read -r _d; do
    if [ -f "${_d}/state" ]; then
      _line=$(head -n1 "${_d}/state" 2>/dev/null)
      _first=${_line%% *}
      _states="${_states}${_states:+,}${_first:-empty}"
      case "$_line" in *stale_*) _stale=1 ;; esac
    fi
    # ROOF-COMPAT(deprecation window 1주기 — 구 RALPH/oralph_active 인식 제거 예정)
    if [ -f "${_d}/status" ] && grep -qE 'ROOF|RALPH' "${_d}/status" 2>/dev/null; then _roof=1; fi
    [ -e "${_d}/evidence/ok_started" ] && _has_start=1
    # 결함3(GF): ok_started 가 ofinish_done|cleanup_done 보다 ★엄격히 새것이면★ 오래된 완료 표식으로 보고 미완료 취급한다.
    #   (동시각 tie 는 종전대로 완료 — 정상 흐름은 ofinish_done 이 ok_started 보다 항상 나중이고 ext4 mtime 이 jiffy 단위라 tie 는 시험 시드에서만 난다.)
    #   비교할 ok_started 가 없는 base 는 종전대로 존재 여부만 본다. 한 base 라도 미완료면 보호(_unfin).
    local _fin_f=""
    if [ -e "${_d}/evidence/ofinish_done" ]; then _fin_f="${_d}/evidence/ofinish_done"
    elif [ -e "${_d}/evidence/ofinish_cleanup_done" ]; then _fin_f="${_d}/evidence/ofinish_cleanup_done"; fi
    if [ -n "$_fin_f" ]; then
      if [ -e "${_d}/evidence/ok_started" ] && [ "${_d}/evidence/ok_started" -nt "$_fin_f" ]; then
        _unfin=1
      else
        _has_fin=1
      fi
    fi
  done <<EOF_PEA
$_PEA_DIRS
EOF_PEA
  case "$_stale_hint" in 0|1) _stale="$_stale_hint" ;; esac

  if [ "$_roof" -eq 1 ]; then
    _pea_root_ac_sweep
    _pea_log "RALPH_SKIP states=${_states:-absent}"  # ROOF-COMPAT(deprecation window 1주기 — 로그 태그 RALPH_SKIP 은 소비자 호환 유지)
    return 1
  fi
  # R4: 미완료 사이클 보호
  if [ "$_has_start" -eq 1 ] && { [ "$_has_fin" -eq 0 ] || [ "$_unfin" -eq 1 ]; } && [ "$_stale" -eq 0 ]; then
    _pea_root_ac_sweep
    _pea_log "SKIPPED_UNFINISHED states=${_states:-absent}"
    return 1
  fi

  local _TS _dest _moved _e _ts _ref
  _TS="$(date '+%Y%m%dT%H%M%S')-$$"
  while IFS= read -r _d; do
    [ -n "$_d" ] || continue
    _dest="${_d}/logs/prev_cycle/${_TS}"
    _moved=""
    _ref=$(_pea_bound "$_d") || _ref=""
    if [ -d "${_d}/evidence" ]; then
      for _e in "${_d}/evidence"/* "${_d}/evidence"/.[!.]* "${_d}/evidence"/..?*; do
        [ -e "$_e" ] || [ -L "$_e" ] || continue
        _pea_mv "$_d" "$_dest" "evidence/$(basename "$_e")"
      done
    fi
    _pea_mv "$_d" "$_dest" ".phase_batches.written"
    _pea_mv "$_d" "$_dest" "plans/phase_batches.json"
    _pea_mv "$_d" "$_dest" "current_phase_batch"
    _pea_mv "$_d" "$_dest" "plans/acceptance_criteria.json"
    _pea_mv "$_d" "$_dest" "acceptance_criteria.json"   # 결함2(GF): 세션 루트 AC — 루트·plans 불일치(CRITERIA_SOURCE_CONFLICT) 방지
    _pea_mv "$_d" "$_dest" "plans/ac_edit_approval.json"   # c215: 지난 사이클 미소비 AC 편집 승인 마커가 새 사이클 AC 편집을 통과시키지 않게 보관
    _ts=$(date '+%Y-%m-%dT%H:%M:%S%z')
    mkdir -p "${_d}/logs" 2>/dev/null
    if [ -n "$_moved" ]; then
      echo "${_ts} uuid=${_PEA_UUID} value=${_PEA_VALUE} via=${_PEA_VIA} MOVED dest=logs/prev_cycle/${_TS} files=${_moved}" >> "${_d}/logs/pipeline_entry_reset.log" 2>/dev/null || true
    else
      echo "${_ts} uuid=${_PEA_UUID} value=${_PEA_VALUE} via=${_PEA_VIA} NOTHING_TO_MOVE" >> "${_d}/logs/pipeline_entry_reset.log" 2>/dev/null || true
    fi
  done <<EOF_PEA
$_PEA_DIRS
EOF_PEA
  return 0
}

# 진입 표식: evidence/ok_started·pipeline_start_time(epoch) 기록 + heartbeat touch (모든 base)
pea_stamp() {
  local _u="${1:-}" _now _d _ref _t
  printf '%s' "$_u" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || return 1
  _pea_dirs "$_u" || return 1
  _now="${PEA_NOW:-$(date +%s)}"
  while IFS= read -r _d; do
    [ -n "$_d" ] || continue
    mkdir -p "${_d}/evidence" 2>/dev/null
    # L-1393: 슬래시 선기록이면 시작 시각을 그 경계로 맞춘다(뒤늦게 찍으면 이번 AC 가 시작보다 오래돼 F-AC-DEV 가 막는다). PEA_NOW 가 있으면 그것이 우선.
    _t="$_now"
    if [ -z "${PEA_NOW:-}" ] && _ref=$(_pea_bound "$_d"); then
      _t=$(stat -c %Y "$_ref" 2>/dev/null) || _t="$_now"
      case "$_t" in ''|*[!0-9]*) _t="$_now" ;; esac
    fi
    echo "$_t" > "${_d}/evidence/ok_started" 2>/dev/null || true
    echo "$_t" > "${_d}/pipeline_start_time" 2>/dev/null || true
    touch "${_d}/heartbeat" 2>/dev/null || true
    touch "${_d}/plan_entry_mark" 2>/dev/null || true  # D5 — Stop 가드5. session_state 자기전이가 state mtime 을 밀어도 이번 사이클 진입을 증명한다.
  done <<EOF_PEA
$_PEA_DIRS
EOF_PEA
  return 0
}
