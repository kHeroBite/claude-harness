#!/bin/bash
# PostToolUse(Skill) — 다단계 계획 자동 계속 + 상태 관리
trap 'exit 0' ERR
INPUT=$(timeout 5 cat 2>/dev/null) || INPUT=""
SKILL_NAME=$(echo "$INPUT" | jq -r '(.tool_input.skill // .tool_input.skill_name // empty)' 2>/dev/null)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")

# UUID 결정 — 세션별 상태 파일 경로
source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/session_id.sh"
resolve_uuid "$INPUT" || exit 0
[[ -z "$UUID" ]] && exit 0

# 팀에이전트 스킵 — state 관리는 메인 전용 (L-268)
# 팀에이전트가 단위 스킬 호출 시 자기 UUID에 state=KO를 생성하면
# write_guard.sh가 해당 state를 보고 메인으로 오판 → L-248 Grep 차단
if [[ -n "${PIPELINE_UUID:-}" && "${PIPELINE_UUID:-}" != "$MY_UUID" ]] || \
   [[ "$MY_UUID" != "$UUID" ]]; then
  exit 0
fi

# 서브에이전트 스킵 — state 없는 UUID는 서브에이전트 확정 (L-269)
# UserPromptSubmit.sh가 모든 메인 세션 시작 시 state 파일 생성
# 팀에이전트는 위에서 이미 스킵됨 → 여기 도달 = 서브에이전트
if [[ ! -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${MY_UUID}/state" ]]; then
  exit 0
fi

SESSION_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}"
mkdir -p "${SESSION_DIR}"
# 사이클47 — 디렉토리 생성은 _mirror_file 의 대상이 아니다(단일 파일 복제 전용, S-1).
# 반대편 base 에 UUID 디렉토리가 없으면 이후 미러가 매번 mkdir 을 반복하므로 여기서 함께 만든다.
# CLAUDE_CONFIG_DIR 미설정이면 두 경로가 같아져 중복 mkdir 이 되지만 -p 라 무해하다(멱등).
mkdir -p "$HOME/.claude/session-env/${UUID}" 2>/dev/null

# 사이클46 축① — 반대편 base 미러 (읽는 쪽이 다른 base 를 볼 수 있다)
# state/status 는 state_machine.sh 헬퍼가 자체 미러한다(S3/S4). 여기서는 직접 쓰는 파일만 다룬다.
source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/session_mirror.sh" 2>/dev/null
declare -F _mirror_file >/dev/null 2>&1 || _mirror_file() { :; }
# 사이클46 삭제 미러 — 복제 전용 미러는 원본 삭제 시 반대편이 잔존한다(S-1).
# classification 잔류는 statusline/게이트 오판을 부르므로 삭제도 반대편에 전파한다.
declare -F _mirror_delete >/dev/null 2>&1 || _mirror_delete() { :; }

# 사이클194 (a) — 진입 성공 분기에서 이전 사이클 잔존물 보관 이동 + 진입 표식(ok_started·pipeline_start_time·heartbeat).
# 이 hook 이 PLAN 을 먼저 쓰므로 PreToolUse_pipeline_entry_reset.sh 는 늘 NOT_IDLE_SKIP 이 된다 → 같은 lib 를 여기서도 부른다.
# 인자: 전이 직전 state 줄(stale_ 판정용). lib 부재·실패는 무동작(fail-open). 호출은 항상 `|| true` 로 감싼다(ERR trap).
_pg_entry_archive() {
  local _pre="${1:-}" _stale=0 _lib
  _lib="$(dirname "${BASH_SOURCE[0]}")/lib/pipeline_entry_archive.sh"
  case "$_pre" in *stale_*) _stale=1 ;; esac
  [ -f "$_lib" ] || return 0
  # shellcheck source=/dev/null
  source "$_lib" 2>/dev/null || return 0
  declare -F pea_archive >/dev/null 2>&1 || return 0
  # D6 — 보관을 건너뛰면(R4 미완료 사이클 보호 등) ok_started 는 그 사이클 증거이므로 건드리지 않고 heartbeat·plan_entry_mark 만 갱신한다.
  if pea_archive "$UUID" phase_guard PLAN "$_stale"; then
    pea_stamp "$UUID"
  else
    touch "${SESSION_DIR}/heartbeat" "$HOME/.claude/session-env/${UUID}/heartbeat"           "${SESSION_DIR}/plan_entry_mark" "$HOME/.claude/session-env/${UUID}/plan_entry_mark" 2>/dev/null || true
  fi
  return 0
}

# D7 — 사이클 진입 때 peer 마커 정리. 기준점 REF = max(last_prompt_epoch, 직전 ofinish_done|ofinish_cleanup_done) (두 base).
#   마커 >= REF: 이번 턴·이번 사이클에 이미 ListAgents 를 했다 → 시작 통지 기록까지 함께 유지한다.
#   마커 < REF 또는 last_prompt_epoch 없음: 종전대로 전부 소거한다. '같은 턴' 은 last_prompt_epoch 로만 증명되므로 ofinish 표식만 있으면 유지하지 않는다.
#   보관(_pg_entry_archive)보다 먼저 불러야 ofinish 표식이 남아 있다.
#   직전 state 가 FINISH 면 끝난 사이클에서 넘어오는 재귀 진입(ofinish autoloop 는 Step 6 표식 전에 돌 수 있다)이므로 기준점과 무관하게 소거한다.
_pg_peer_reset() {
  local _m="${SESSION_DIR}/peer_check_done" _ref="" _lpe=0 _b _r _pre="${_PG_PRE:-}"
  for _b in "$SESSION_DIR" "$HOME/.claude/session-env/${UUID}"; do
    for _r in last_prompt_epoch evidence/ofinish_done evidence/ofinish_cleanup_done; do
      [ -f "${_b}/${_r}" ] || continue
      [ "$_r" = last_prompt_epoch ] && _lpe=1
      if [ -z "$_ref" ] || [ "${_b}/${_r}" -nt "$_ref" ]; then _ref="${_b}/${_r}"; fi
    done
  done
  if [ "${_pre%% *}" != "FINISH" ] && [ -f "$_m" ] && [ "$_lpe" = 1 ] && [ ! "$_m" -ot "$_ref" ]; then
    return 0
  fi
  rm -f "$_m" "${SESSION_DIR}/peer_notified.json" "${SESSION_DIR}/peer_finish_done" 2>/dev/null
  return 0
}

# 사이클197 AC-J7 — 슬래시 선기록 PLAN 판별. 슬래시 진입은 UserPromptSubmit 가 PLAN 을 먼저 써서 위 CAS 가 실패하고 보관이 빠졌다.
#   판별: 인자(현재 state 줄)의 첫 토큰 PLAN + teamcreate_force_ 토큰 둘 다.
#   토큰 출처: UserPromptSubmit.sh:350 사유 "teamcreate_force_<cmd>", 줄 형식 state_machine.sh:184 "<STATE> <UUID> <ISO> <REASON>".
#   같은 사이클 재호출(ok_pipeline 등)은 lib R4 가 SKIPPED_UNFINISHED 로 막는다.
_pg_slash_prewrite() {
  local _l="${1:-}"
  [ "${_l%% *}" = "PLAN" ] || return 1
  case " $_l " in *" teamcreate_force_"*) return 0 ;; esac
  return 1
}

# 모든 스킬 로딩 시 oi_pending 삭제 (교착 방지 — 슬래시 명령 바이패스 누락 안전망)
rm -f "${SESSION_DIR}/oi_pending" 2>/dev/null
_mirror_delete "${SESSION_DIR}/oi_pending"

# ok 호출 시 상태 관리 (기존 ok_activate.sh 기능 흡수)
case "$SKILL_NAME" in
  oi)
    # oi 실행 완료 → oi_routed 마커 생성 (타임스탬프 기록 — TTL 10초 기반, race condition 방지)
    echo "$(date +%s)" > "${SESSION_DIR}/oi_routed"
    _mirror_file "${SESSION_DIR}/oi_routed"
    ;;
  ok)
    rm -f "${SESSION_DIR}/skill_direct"  # ok 파이프라인 — skill_direct 해제
    _mirror_delete "${SESSION_DIR}/skill_direct"
    # Phase B (L-431): IDLE/FINISH → PLAN CAS 전이 + classification=OK 동시 기록 (tier 미정 신호)
    source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/state_machine.sh"
    _PG_PRE=$(head -n1 "${SESSION_DIR}/state" 2>/dev/null) || _PG_PRE=""
    if state_transition "${SESSION_DIR}/state" "IDLE" "PLAN" "phase_guard_ok" "$SESSION_ID" 2>/dev/null \
       || state_transition "${SESSION_DIR}/state" "FINISH" "PLAN" "phase_guard_ok" "$SESSION_ID" 2>/dev/null; then
      _pg_peer_reset || true  # D7 — 기준점보다 오래된 peer 마커만 소거
      echo "OK" > "${SESSION_DIR}/classification"
      _mirror_file "${SESSION_DIR}/classification"
      echo "0" > "${SESSION_DIR}/reroute_count"
      _mirror_file "${SESSION_DIR}/reroute_count"
      _pg_entry_archive "$_PG_PRE" || true  # 사이클194 (a)
    elif _pg_slash_prewrite "$_PG_PRE"; then
      _pg_entry_archive "$_PG_PRE" || true  # 사이클197 AC-J7 — 슬래시 선기록 PLAN
    fi
    ;;
  ok_*)
    rm -f "${SESSION_DIR}/skill_direct"  # ok_pipeline/ok_model 계열 — skill_direct 해제
    _mirror_delete "${SESSION_DIR}/skill_direct"
    # Phase B (L-431): IDLE/FINISH → PLAN CAS 전이 + classification=OK 동시 기록 (진행 중 상태는 덮어쓰지 않음, L-240)
    source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/state_machine.sh"
    _PG_PRE=$(head -n1 "${SESSION_DIR}/state" 2>/dev/null) || _PG_PRE=""
    if state_transition "${SESSION_DIR}/state" "IDLE" "PLAN" "phase_guard_ok_prefix" "$SESSION_ID" 2>/dev/null \
       || state_transition "${SESSION_DIR}/state" "FINISH" "PLAN" "phase_guard_ok_prefix" "$SESSION_ID" 2>/dev/null; then
      _pg_peer_reset || true  # D7 — 기준점보다 오래된 peer 마커만 소거
      echo "OK" > "${SESSION_DIR}/classification"
      _mirror_file "${SESSION_DIR}/classification"
      _pg_entry_archive "$_PG_PRE" || true  # 사이클194 (a)
    fi
    # 결함3(GF): ok_* 호출은 CAS 성공 시에만 보관한다. 슬래시 선기록 PLAN 보관(AC-J7)은 ok)·o[1-5]) 분기가 담당하며,
    #   이미 PLAN 인 사이클의 Skill(ok_pipeline) 재호출이 진행 중 사이클 산출물을 옮기던 오발을 막는다.
    ;;
  o[1-5])
    # o1~o5 직접 호출 — ok와 동일하게 파이프라인 활성화
    rm -f "${SESSION_DIR}/skill_direct"
    _mirror_delete "${SESSION_DIR}/skill_direct"
    # Phase B (L-431): IDLE/FINISH → PLAN CAS 전이 + classification=O{N} 동시 기록
    # SKILL_NAME(예: "o3")의 첫 글자(o)를 대문자(O)로 변환하여 classification 결정
    _ON_LEVEL=$(echo "$SKILL_NAME" | tr '[:lower:]' '[:upper:]')   # o3 → O3
    source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/state_machine.sh"
    _PG_PRE=$(head -n1 "${SESSION_DIR}/state" 2>/dev/null) || _PG_PRE=""
    if state_transition "${SESSION_DIR}/state" "IDLE" "PLAN" "phase_guard_o1_5" "$SESSION_ID" 2>/dev/null \
       || state_transition "${SESSION_DIR}/state" "FINISH" "PLAN" "phase_guard_o1_5" "$SESSION_ID" 2>/dev/null; then
      _pg_peer_reset || true  # D7 — 기준점보다 오래된 peer 마커만 소거
      echo "$_ON_LEVEL" > "${SESSION_DIR}/classification"
      _mirror_file "${SESSION_DIR}/classification"
      echo "0" > "${SESSION_DIR}/reroute_count"
      _mirror_file "${SESSION_DIR}/reroute_count"
      _pg_entry_archive "$_PG_PRE" || true  # 사이클194 (a)
    elif _pg_slash_prewrite "$_PG_PRE"; then
      _pg_entry_archive "$_PG_PRE" || true  # 사이클197 AC-J7 — 슬래시 선기록 PLAN
    fi
    ;;
  ox)
    # V4 (U3): /ox 호출 시 활성 파이프라인 감지 → 경고+확인 (완전 차단 금지)
    # IDLE 상태의 /ox는 무조건 통과. 활성 상태면 경고 출력 + 리셋 보류.
    # 사용자가 재확인하거나 확인 마커 파일이 존재하면 리셋 진행.
    # 2026-08-20: o0 스킬 완전 제거. ox가 단독으로 파이프라인 바이패스를 담당한다.
    _K0_STATE=$(state_read "${SESSION_DIR}/state" 2>/dev/null | awk '{print $1}' | tr -d '\r' || echo "IDLE")
    [[ "$_K0_STATE" == "__LOCK_FAIL__" ]] && _K0_STATE="IDLE"  # F6: lock 경쟁 시 보수 처리
    _K0_STATE=${_K0_STATE:-IDLE}
    case "$_K0_STATE" in
      PLAN|DEV|TEST|DONE|FINISH)
        # Phase B (L-431): stage OK 제거 — PLAN+classification=OK가 ok 진입 단계 표현
        # 활성 파이프라인 중 /ox 감지 — 이미 확인 파일이 있으면 진행, 없으면 경고만
        if [ -f "${SESSION_DIR}/ox_confirm" ]; then
          # 사용자가 이전 경고 이후 재확인 → 실제 리셋 진행
          rm -f "${SESSION_DIR}/ox_confirm" 2>/dev/null
          _mirror_delete "${SESSION_DIR}/ox_confirm"
          rm -f "${SESSION_DIR}/skill_direct"
          _mirror_delete "${SESSION_DIR}/skill_direct"
          rm -f "${SESSION_DIR}/team_name"
          _mirror_delete "${SESSION_DIR}/team_name"
          rm -f "${SESSION_DIR}/classification"  # Phase B: classification 잔류 방지
          _mirror_delete "${SESSION_DIR}/classification"
          # F1 state_machine: 현재 상태(_K0_STATE)를 from으로 CAS 전이 → IDLE
          source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/state_machine.sh"
          state_transition "${SESSION_DIR}/state" "$_K0_STATE" "IDLE" "${SKILL_NAME}_force_reset" "$SESSION_ID" 2>/dev/null || true
          echo "⚠️ [/${SKILL_NAME} 확인됨] 활성 파이프라인(${_K0_STATE}) 강제 해제됨"
        else
          # 첫 /ox 호출 — 경고 출력 + 확인 대기 마커 생성 (state 유지)
          touch "${SESSION_DIR}/ox_confirm" 2>/dev/null
          _mirror_file "${SESSION_DIR}/ox_confirm"
          echo "⛔ [/${SKILL_NAME} 경고] 활성 파이프라인(${_K0_STATE}) 감지 — 작업 유실 위험!"
          echo "   작업을 정말 중단하려면 /${SKILL_NAME}를 한 번 더 입력하세요."
          echo "   또는 /ofinish 로 정상 종료하세요."
        fi
        ;;
      *)
        # IDLE 등 비활성 → 기존 동작 유지 (바로 리셋)
        rm -f "${SESSION_DIR}/skill_direct"
        _mirror_delete "${SESSION_DIR}/skill_direct"
        rm -f "${SESSION_DIR}/team_name"
        _mirror_delete "${SESSION_DIR}/team_name"
        rm -f "${SESSION_DIR}/classification"  # Phase B: classification 잔류 방지
        _mirror_delete "${SESSION_DIR}/classification"
        state_write "${SESSION_DIR}/state" "IDLE ${SESSION_ID}"
        rm -f "${SESSION_DIR}/ox_confirm" 2>/dev/null
        _mirror_delete "${SESSION_DIR}/ox_confirm"
        # ox 파이프라인 바이패스 → status 잔류 방지
        STATUS_FILE="${SESSION_DIR}/status"
        status_clear "$STATUS_FILE" 2>/dev/null || true
        ;;
    esac
    ;;
  oplan*|odev*|otest*|odone*|odebug|oinit|oss|oinsights|obr|opush|ocopy|ocso|ostatus|oresume)
    # 단위 스킬 직접 호출 (/oplan, /odev 등) — skill_direct에 스킬명 기록
    # ok 파이프라인 활성 상태가 아닐 때만 (state가 IDLE일 때)
    _PHASE_STATE=$(state_read "${SESSION_DIR}/state" 2>/dev/null | awk '{print $1}' | tr -d '\r' || echo "IDLE")
    [[ "$_PHASE_STATE" == "__LOCK_FAIL__" ]] && _PHASE_STATE="IDLE"  # F6: lock 경쟁 시 보수 처리
    if [[ "$_PHASE_STATE" == "IDLE" ]]; then
      echo "${SKILL_NAME}" > "${SESSION_DIR}/skill_direct"
      _mirror_file "${SESSION_DIR}/skill_direct"
    fi
    ;;
  ofinish*)
    # ofinish는 메인 전용 마무리 스킬 — skill_direct 조작 불필요
    ;;
esac

exit 0
