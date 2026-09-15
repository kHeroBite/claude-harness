#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# PostToolUse(Skill) — 다단계 계획 자동 계속 + 상태 관리
trap 'exit 0' ERR
INPUT=$(timeout 5 cat 2>/dev/null) || INPUT=""
SKILL_NAME=$(echo "$INPUT" | jq -r '(.tool_input.skill // .tool_input.skill_name // empty)' 2>/dev/null)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")

# UUID 결정 — 세션별 상태 파일 경로
source "${HARNESS_HOOK_DIR}/lib/session_id.sh"
resolve_uuid "$INPUT" || exit 0
[[ -z "$UUID" ]] && exit 0

# 팀에이전트 스킵 — state 관리는 메인 전용 (L-268)
# 팀에이전트가 oinfra_* 호출 시 자기 UUID에 state=KO를 생성하면
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

# 사이클46 축① — 반대편 base 미러 (읽는 쪽이 다른 base 를 볼 수 있다)
# state/status 는 state_machine.sh 헬퍼가 자체 미러한다(S3/S4). 여기서는 직접 쓰는 파일만 다룬다.
source "${HARNESS_HOOK_DIR}/lib/session_mirror.sh" 2>/dev/null
type _mirror_file >/dev/null 2>&1 || _mirror_file() { :; }
# 사이클46 삭제 미러 — 복제 전용 미러는 원본 삭제 시 반대편이 잔존한다(S-1).
# classification 잔류는 statusline/게이트 오판을 부르므로 삭제도 반대편에 전파한다.
type _mirror_delete >/dev/null 2>&1 || _mirror_delete() { :; }

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
    source "${HARNESS_HOOK_DIR}/lib/state_machine.sh"
    if state_transition "${SESSION_DIR}/state" "IDLE" "PLAN" "phase_guard_ok" "$SESSION_ID" 2>/dev/null \
       || state_transition "${SESSION_DIR}/state" "FINISH" "PLAN" "phase_guard_ok" "$SESSION_ID" 2>/dev/null; then
      echo "OK" > "${SESSION_DIR}/classification"
      _mirror_file "${SESSION_DIR}/classification"
      echo "0" > "${SESSION_DIR}/reroute_count"
      _mirror_file "${SESSION_DIR}/reroute_count"
    fi
    ;;
  ok_*)
    rm -f "${SESSION_DIR}/skill_direct"  # ok_pipeline/ok_model 계열 — skill_direct 해제
    _mirror_delete "${SESSION_DIR}/skill_direct"
    # Phase B (L-431): IDLE/FINISH → PLAN CAS 전이 + classification=OK 동시 기록 (진행 중 상태는 덮어쓰지 않음, L-240)
    source "${HARNESS_HOOK_DIR}/lib/state_machine.sh"
    if state_transition "${SESSION_DIR}/state" "IDLE" "PLAN" "phase_guard_ok_prefix" "$SESSION_ID" 2>/dev/null \
       || state_transition "${SESSION_DIR}/state" "FINISH" "PLAN" "phase_guard_ok_prefix" "$SESSION_ID" 2>/dev/null; then
      echo "OK" > "${SESSION_DIR}/classification"
      _mirror_file "${SESSION_DIR}/classification"
    fi
    ;;
  oinfra_*)
    # oinfra_* 인프라 정보 조회 스킬 — 파이프라인 무관 (state 변경 금지)
    # 메인이 정보 획득 목적으로 호출하므로 skill_direct 마커만 기록
    _OINFRA_STATE=$(state_read "${SESSION_DIR}/state" 2>/dev/null | awk '{print $1}' | tr -d '\r' || echo "IDLE")
    [[ "$_OINFRA_STATE" == "__LOCK_FAIL__" ]] && _OINFRA_STATE="IDLE"
    if [[ "$_OINFRA_STATE" == "IDLE" ]]; then
      echo "${SKILL_NAME}" > "${SESSION_DIR}/skill_direct"
      _mirror_file "${SESSION_DIR}/skill_direct"
    fi
    ;;
  o[1-5])
    # o1~o5 직접 호출 — ok와 동일하게 파이프라인 활성화
    rm -f "${SESSION_DIR}/skill_direct"
    _mirror_delete "${SESSION_DIR}/skill_direct"
    # Phase B (L-431): IDLE/FINISH → PLAN CAS 전이 + classification=O{N} 동시 기록
    # SKILL_NAME(예: "o3")의 첫 글자(o)를 대문자(O)로 변환하여 classification 결정
    _ON_LEVEL=$(echo "$SKILL_NAME" | tr '[:lower:]' '[:upper:]')   # o3 → O3
    source "${HARNESS_HOOK_DIR}/lib/state_machine.sh"
    if state_transition "${SESSION_DIR}/state" "IDLE" "PLAN" "phase_guard_o1_5" "$SESSION_ID" 2>/dev/null \
       || state_transition "${SESSION_DIR}/state" "FINISH" "PLAN" "phase_guard_o1_5" "$SESSION_ID" 2>/dev/null; then
      echo "$_ON_LEVEL" > "${SESSION_DIR}/classification"
      _mirror_file "${SESSION_DIR}/classification"
      echo "0" > "${SESSION_DIR}/reroute_count"
      _mirror_file "${SESSION_DIR}/reroute_count"
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
          source "${HARNESS_HOOK_DIR}/lib/state_machine.sh"
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
