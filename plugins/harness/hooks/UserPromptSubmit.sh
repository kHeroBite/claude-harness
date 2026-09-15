#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# [훅1] UserPromptSubmit — 매 사용자 메시지마다 세션 초기화 + ok 상태 체크
# 목적: ~/.claude/session-env/${UUID}/ 디렉토리 생성, session_full 갱신
# 1회성 정리(serena좀비/pane스윕/stale감지/7일정리)는 SessionStart.sh로 이동 완료
# 세션 격리 v3: UUID 체계 — session_full + PIPELINE_UUID 환경변수 기반
# L-030: 새 세션 시작 시 이전 세션 잔류 상태 강제 리셋 → IDLE 초기화
# L-035: task-notification 등 시스템 이벤트에서 ok 오발동 방지 — prompt 필드 검사

# --- 사이클46 축① 반대편 base 미러 로드 ---
# 배경: session-env 를 쓰는 쪽과 읽는 쪽이 서로 다른 base 를 볼 수 있어 상태가 어긋난다.
#       (CLAUDE_CONFIG_DIR 설정 세션에서 ${HOME}/.claude 와 ${CLAUDE_CONFIG_DIR} 가 갈린다)
# state/status 는 state_machine.sh / session_id.sh 헬퍼가 자체 미러하므로 여기서 다루지 않는다.
# ★_mirror_file 만 쓴다 — _mirror_file_strict 는 미러 실패가 원 쓰기를 실패시키므로 hook 금지★
# ★_reset_idle() 정의보다 앞에 둔다★ — 그 함수가 미러를 호출하므로 어느 호출 경로에서도 정의돼 있어야 한다.
# 라이브러리 부재 시에도 hook 이 그대로 동작하도록 no-op 폴백을 정의한다.
source "${HARNESS_HOOK_DIR}/lib/session_mirror.sh" 2>/dev/null
type _mirror_file >/dev/null 2>&1 || _mirror_file() { :; }
type _mirror_delete >/dev/null 2>&1 || _mirror_delete() { :; }

# --- stdin JSON 파싱 ---
INPUT=$(timeout 5 cat 2>/dev/null) || INPUT=""
if [[ -z "$INPUT" ]]; then
  echo "ℹ️ [ok 스킵] 시스템 이벤트 — stdin 비어있음"
  exit 0
fi
CURRENT_SESSION=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null) || CURRENT_SESSION="unknown"
PROMPT=$(echo "$INPUT" | jq -r '.prompt // ""' 2>/dev/null) || PROMPT=""

# [P2-isolation] _find_active_pipelines() 제거 — 다른 세션 정보를 현재 에이전트에게 노출하는 것은
# 세션 격리 위반이며, 에이전트가 타 세션 파이프라인을 자기 것으로 오인하여 크로스 뮤테이션을 유발했음.
# 각 세션은 자기 UUID(SESSION_DIR) 내부만 참조해야 한다. (L-유출차단, 2026-04-22)

# --- IDLE 초기화 공통 함수 (중복 제거) ---
_reset_idle() {
  # [P1-isolation 원자화] team_name 파일 삭제 전에 teams/<name>/·tasks/<name>/ 동반 정리.
  # 소유권 증명(CLAUDE.md §세션 격리 불변식 (b)):
  #   1) teams/<name>/config.json leadSessionId == 현재 UUID
  #   2) session-env/${UUID}/team_name == <name>
  # 둘 다 성립할 때만 teams/tasks rm. 다른 세션이 같은 이름을 자기 team_name에 기록했으면 skip.
  local _OLD_TEAM=""
  if [[ -f "${SESSION_DIR}/team_name" ]]; then
    _OLD_TEAM=$(cat "${SESSION_DIR}/team_name" 2>/dev/null | tr -d '\r\n' || echo "")
  fi
  if [[ -n "$_OLD_TEAM" ]]; then
    local _TEAM_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams/${_OLD_TEAM}"
    local _OWNER_OK=0
    if [[ -f "${_TEAM_DIR}/config.json" ]]; then
      local _LEAD_ID
      _LEAD_ID=$(jq -r '.leadSessionId // empty' "${_TEAM_DIR}/config.json" 2>/dev/null || echo "")
      if [[ "$_LEAD_ID" == "$UUID" ]]; then
        _OWNER_OK=1
      fi
    else
      # config.json 부재 — leadSessionId 증명 불가 → fail-closed (Fix 27 §(b))
      _OWNER_OK=0
    fi
    # cross-check: 다른 세션이 같은 team_name을 자기 것이라고 주장하는지 확인 (읽기만)
    local _OTHER_CLAIM=0 _OTHER_DIR
    for _OTHER_DIR in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env"/*/; do
      [[ -d "$_OTHER_DIR" ]] || continue
      local _OTHER_UUID
      _OTHER_UUID=$(basename "$_OTHER_DIR")
      [[ "$_OTHER_UUID" == "$UUID" ]] && continue
      [[ -f "${_OTHER_DIR}team_name" ]] || continue
      local _OTHER_TEAM
      _OTHER_TEAM=$(cat "${_OTHER_DIR}team_name" 2>/dev/null | tr -d '\r\n')
      if [[ "$_OTHER_TEAM" == "$_OLD_TEAM" ]]; then
        _OTHER_CLAIM=1
        break
      fi
    done
    if [[ $_OWNER_OK -eq 1 && $_OTHER_CLAIM -eq 0 ]]; then
      rm -rf "${_TEAM_DIR}" 2>/dev/null
      rm -rf "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/tasks/${_OLD_TEAM}" 2>/dev/null
    fi
  fi
  # team_name/classification/rollback_hash 파일 삭제 (기존 동작)
  rm -f "${SESSION_DIR}/team_name" \
        "${SESSION_DIR}/classification" "${SESSION_DIR}/rollback_hash" 2>/dev/null
  # 사이클46 삭제 미러 — 반대편 잔존 시 statusline/게이트가 옛 classification 을 읽는다
  _mirror_delete "${SESSION_DIR}/team_name"
  _mirror_delete "${SESSION_DIR}/classification"
  _mirror_delete "${SESSION_DIR}/rollback_hash"
  # V2 (CRITICAL) — _reset_idle 호출 시 state 파일을 반드시 IDLE로 갱신
  # 이전: team_name/classification/rollback_hash 만 rm → state 잔존으로 IDLE 복귀 실패
  # 수정: state_write로 원자적 IDLE 기록 (L-362 준수 — session_id.sh state_write 유틸 사용)
  state_write "${SESSION_DIR}/state" "IDLE ${UUID}"
  CONV_ID="conv_$(date +%s%N | cut -c1-12)"
  echo "$CONV_ID" > "${SESSION_DIR}/conv_id"
  _mirror_file "${SESSION_DIR}/conv_id"
  [[ "${_IS_SLASH_CMD:-false}" == "true" ]] && echo "🔀 [2-way 선분류] 질문/수정 → ok 1-way(o1~o5)"
  echo "🆔 [대화 ID] ${CONV_ID}"
  echo "🆔 [UUID] ${UUID}"
  # [P2-isolation] 다른 세션 파이프라인 표시 제거 — 크로스 세션 정보 유출 차단
}

# --- UUID 결정 ---
source "${HARNESS_HOOK_DIR}/lib/session_id.sh"
UUID="${CURRENT_SESSION}"
export UUID
SID="$UUID"  # 하위 호환
export SID
[[ -z "$UUID" ]] && exit 0

# --- L-035: 사용자 실제 입력 없으면 조용히 종료 ---
if [[ -z "$PROMPT" ]]; then
  echo "ℹ️ [ok 스킵] 시스템 이벤트 — 사용자 입력 없음"
  exit 0
fi

# --- 세션 디렉토리 생성 ---
SESSION_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}"
mkdir -p "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env"
mkdir -p "${SESSION_DIR}/agents" "${SESSION_DIR}/evidence" "${SESSION_DIR}/logs" "${SESSION_DIR}/plans" "${SESSION_DIR}/compact" "${SESSION_DIR}/panes" "${SESSION_DIR}/work"

# --- 프롬프트 저장 ---
echo "$PROMPT" > "${SESSION_DIR}/plans/user_prompt.md"
_mirror_file "${SESSION_DIR}/plans/user_prompt.md"

# --- heartbeat 갱신 (매 사용자 메시지마다 — 고아 감지용) ---
# heartbeat_cron.sh가 이 파일의 mtime으로 "메인 에이전트 살아있음" 판단
touch "${SESSION_DIR}/heartbeat" 2>/dev/null
_mirror_file "${SESSION_DIR}/heartbeat"

# --- 사용자 피드백 실시간 감지 (소스 C — 파이프라인 활성 중만) ---
# F6: state_read 경유 + __LOCK_FAIL__ 명시 감지 (허위 IDLE 방지)
# Phase B (L-431): state=OK 잔존 시 자동 PLAN으로 마이그레이션 (다른 활성 세션 보호)
source "${HARNESS_HOOK_DIR}/lib/state_machine.sh" 2>/dev/null
_smach_migrate_ok_to_plan "${SESSION_DIR}/state" "$UUID" 2>/dev/null || true
_FB_STATE=$(state_read "${SESSION_DIR}/state" 2>/dev/null | awk '{print $1}' | tr -d '\r' || echo "IDLE")
_FB_STATE=${_FB_STATE:-IDLE}
[[ "$_FB_STATE" == "__LOCK_FAIL__" ]] && _FB_STATE="IDLE"  # lock 경쟁 시 감지 skip
case "$_FB_STATE" in
  PLAN|DEV|TEST|DONE)
    if [[ -f "${HARNESS_HOOK_DIR}/lib/user_feedback_detector.sh" ]]; then
      source "${HARNESS_HOOK_DIR}/lib/user_feedback_detector.sh" 2>/dev/null
      detect_user_feedback "$PROMPT" "$UUID" 2>/dev/null
    fi
    ;;
esac

# --- oi_pending 생성 (메인에이전트 한정, 슬래시 명령 제외) ---
# 이전 route_decision 삭제 (매 입력마다 초기화)
rm -f "${SESSION_DIR}/route_decision" 2>/dev/null
_mirror_delete "${SESSION_DIR}/route_decision"

_IS_SLASH_CMD=false
if echo "$PROMPT" | grep -qP '^\s*/([a-zA-Z][a-zA-Z0-9_-]*)(\s|$)'; then
  _IS_SLASH_CMD=true
fi

# --- /ogrill 슬래시 감지 시 ogrill_slash_flag 마커 생성 (메인 Skill('ogrill') 허용용) ---
# ogrill_slash_flag 마커 존재 시 PreToolUse_Skill_ogrill_main_guard.sh가 통과 허용
if echo "$PROMPT" | grep -qP '^\s*/ogrill(\s|$)'; then  # ogrill_slash_flag 생성 트리거
  _SESSION_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${_FB_UUID:-}"
  if [[ -n "${_FB_UUID:-}" ]] && [[ -d "$_SESSION_DIR" ]]; then
    touch "$_SESSION_DIR/ogrill_slash_flag"
    _mirror_file "$_SESSION_DIR/ogrill_slash_flag"
  fi
fi

# --- ointaug: 질의 확장 지시 (슬래시 명령 포함 모든 명령에 항상 발동) ---
# 설계: ointaug는 모든 입력의 첫 번째 행동. 슬래시 스킬도 ointaug 이후에 호출됨.
# 호출 순서: ointaug → 해당 스킬 (예: ointaug → oralph → ok)
# 사이클123-E14: 전 상태 발동으로 확장 (사용자 A안 확정).
#   기존 구현은 IDLE 한정이었으나 주석 첫 줄("모든 명령")과 정면 모순이었다. 원 설계 의도가
#   "모든 입력"이며, 사용자가 "사용자의 모든 질의에 반응하도록 요청했었는데?" 로 재확인한 뒤
#   A안(파이프라인 활성 중에도 발동)을 명시 선택했다.
#   ⇒ 파이프라인 활성(PLAN/DEV/TEST/DONE/FINISH) 중에도 발동한다. 이때 oi 메시지와 동시에 출력되며,
#     호출 순서는 ointaug → oi 다 (ointaug 가 "모든 입력의 첫 번째 행동"이라는 원 설계와 일치).
#   주의: PreToolUse_Skill_ointaug_gate.sh 의 물리 차단은 IDLE 한정 그대로 유지한다 —
#         비IDLE 은 안내만 하고 차단하지 않는다 (파이프라인 진행 중 내부 호출 오차단 방지).
# 예외: /ox — o시리즈 완전 바이패스 스킬. ointaug 강제는 o시리즈 호출이므로
#       /ox의 "o시리즈 0건 참조" 정의와 정면 충돌한다. 따라서 발동 자체를 제외한다.
#       (2026-08-20: 구 o0 스킬 완전 제거 — ox가 단독 담당)
_OINTAUG_SKIP=false
if echo "$PROMPT" | grep -qP '^\s*/ox(\s|$)'; then
  _OINTAUG_SKIP=true
fi
if [[ "$_OINTAUG_SKIP" == "false" ]]; then
  echo "📌 [ointaug 필수] ⚠️ CLAUDE.md 규칙: Skill('ointaug')를 반드시 첫 번째 행동으로 호출하고 확장 질의를 화면에 출력한 후 답변하라. 미호출 시 위반."
  # 사이클123-E14: 비IDLE 에서는 oi 메시지와 동시 출력되므로 호출 순서를 명시한다.
  if [[ -n "$_FB_STATE" && "$_FB_STATE" != "IDLE" ]]; then
    echo "   ↳ 순서: Skill('ointaug') → 그 다음 아래 안내된 스킬(Skill('oi') 등). ointaug 가 항상 먼저다."
  fi
fi
if [[ "$_OINTAUG_SKIP" == "true" ]]; then
  echo "⚡ [ox] o시리즈 완전 바이패스 — ointaug 미발동. Skill 호출 없이 즉시 작업에 착수하라."
fi

# --- [스킬 자동 추천 — IDLE 상태 + 슬래시 명령 X 시] ---
# 의도 키워드 매칭으로 권장 메시지 출력 (실제 호출은 사용자 결정 — 자동 spawn 절대 X)
# 출처: improve-codebase, diagnose, grill-me, deep-interview (mattpocock + devbrother2024, MIT 영감)
# 보수성 원칙: 권장만 — 무시해도 손해 0건. 자동 호출(physical spawn)은 17분+ hang 사고 재발 위험으로 영구 금지.
# 슬래시 명령(/o*, /ok 등) 입력 시 스킵 — _IS_SLASH_CMD=true 조건으로 격리 (사용자가 이미 명시 호출 중)
if [[ "$_FB_STATE" == "IDLE" || -z "$_FB_STATE" ]] && [[ "$_IS_SLASH_CMD" == "false" ]]; then
  # 버그/디버그/에러/오류/예외/크래시 키워드 → /odebug 권장 (슬래시 명령 시 스킵)
  if echo "$PROMPT" | grep -qP '(버그|디버그|에러|오류|예외|exception|stack ?trace|크래시|실패|작동\s*안|동작\s*이상|비정상\s*종료)'; then
    echo "💡 [스킬 권장] /odebug — 버그/에러 키워드 감지: 6단계 진단(재현→최소화→가설→측정→수정→회귀) 권장. 회귀 테스트 누락 방지."
    # _IS_SLASH_CMD=true 인 경우 본 분기는 진입조차 하지 않음 (보수성 보장)
  fi
  # 리팩토링/부채/정리/청소/모듈 단순화 키워드 → /oimprove 권장
  if echo "$PROMPT" | grep -qP '(리팩토링|코드\s*부채|기술\s*부채|부채\s*갚|부채\s*청소|청소.*코드|코드.*청소|정리.*코드|코드.*정리|모듈\s*단순화|순환\s*의존|중복\s*제거|deep\s*module|얕은\s*모듈)'; then
    echo "💡 [스킬 권장] /oimprove — 코드 부채 정리 키워드 감지: 누적 모듈 단순화 + 중복 제거 분석 → ok 파이프라인 위임 권장."
  fi
  # 회고/돌아보기/주간 분석 키워드 → /oretro 권장
  if echo "$PROMPT" | grep -qP '(회고|돌아보|지난\s*주|이번\s*달|패턴\s*분석|커밋\s*분석)'; then
    echo "💡 [스킬 권장] /oretro — 회고 키워드 감지: 주간 회고 + 커밋 트렌드 분석 권장."
  fi
fi

# --- 반복 작업 패턴 감지 → oralph 호출 권장 (v2: 독립 스킬 oralph로 라우팅) ---
# 감지 패턴: 한국어 반복 요청 키워드 (완성될 때까지, 없어질 때까지, 끝날 때까지 등)
# /oralph 명시 호출 시 제외 — 사용자가 이미 oralph를 호출 중이므로 중복 발동 불필요
# 변경 이력: oralph가 ralph-loop를 내부 흡수(v4.0)하여 독립 스킬화됨 →
#   더 이상 외부 ralph-loop 플러그인을 호출하지 않고 oralph 자체로 반복 검증 루프를 수행한다.
if echo "$PROMPT" | grep -qP '(완성될?|없어질?|끝날|고쳐질|사라질|통과할|성공할|해결될?|없을)\s*때까지|반복(해(?!\S)|해서|해라|하라|적으로)|(계속\s*(해|실행|진행|반복))'; then
  if ! echo "$PROMPT" | grep -qP '^\s*/oralph\b'; then
    # 사용자 입력을 args로 전달하도록 안내 (빈 args 호출 시 Phase 0 초기화 실패 방지)
    _ORALPH_PROMPT=$(echo "$PROMPT" | head -1)
    jq -n \
      --arg hook_event "UserPromptSubmit" \
      --arg oralph_prompt "$_ORALPH_PROMPT" \
      '{
        hookSpecificOutput: {
          hookEventName: $hook_event,
          additionalContext: ("⚠️ [반복 작업 감지] 사용자가 반복 수행 패턴을 요청했습니다. Skill('\''oralph'\'')를 첫 번째 행동으로 호출하라 (ointaug 이후). oralph는 ok 파이프라인 + 내장 검증 루프를 제공하는 독립 스킬이다.\n사용자 입력을 args에 전달하라: Skill('\''oralph'\'', args='\''" + $oralph_prompt + "'\'')")
        }
      }'
  fi
fi

# L-XXX: /ok, /o1~o5 파이프라인 강제 리마인더
if echo "$PROMPT" | grep -qP '^\s*/(ok|o[1-5])\b'; then
  _PIPELINE_CMD=$(echo "$PROMPT" | grep -oP '^\s*/(ok|o[1-5])\b' | tr -d ' ')
  echo "⚠️ [파이프라인 필수] ${_PIPELINE_CMD} 호출 — 파이프라인 100% 실행 필수. 직접 답변 금지."
fi

# o시리즈 비IDLE 경고 (옵션 B — exit 0 경고, 차단 아님)
# oi/oinit/ofinish/oresume/ocontext/oinsights/oretro 제외 (정리/재개/진단 명령은 비IDLE에서도 정상 실행)
_O_NONIDLE_PATTERN='^\s*/(ok|oto|o[1-5]|oralph|okconsult|okdebate|okdeep)\b'
if echo "$PROMPT" | grep -qP "$_O_NONIDLE_PATTERN"; then
  _O_CMD=$(echo "$PROMPT" | grep -oP "$_O_NONIDLE_PATTERN" | head -1 | tr -d ' ')
  # F-NEW-3: state_read (flock) 통일 — cat 직접 읽기 race condition 방지
  _CUR_STATE=$(state_read "${SESSION_DIR}/state" 2>/dev/null | awk '{print $1}' | tr -d '\r' || echo "IDLE")
  _CUR_STATE=${_CUR_STATE:-IDLE}
  [[ "$_CUR_STATE" == "__LOCK_FAIL__" ]] && _CUR_STATE="IDLE"  # lock 경쟁 시 경고 skip
  if [[ "$_CUR_STATE" != "IDLE" && "$_CUR_STATE" != "FINISH" ]]; then
    echo "⚠️ [비IDLE 경고] ${_O_CMD} 호출 — 현재 파이프라인 상태: ${_CUR_STATE}"
    echo "   파이프라인이 정상 종료되지 않았을 수 있습니다."
    echo "   정리 후 재시도: /oinit → ${_O_CMD}"
    echo "   현재 상태로 강행하려면 계속 진행하세요. (경고만, 차단 아님)"
  fi
fi

# TeamCreate 강제 (새 세션 exit 0 이전에 출력 — 항상 발동 보장)
_TEAMCREATE_PATTERN='^\s*/(ok|oto|o[1-5]|oralph|okconsult|okdebate|okdeep)\b'
if echo "$PROMPT" | grep -qP "$_TEAMCREATE_PATTERN"; then
  _TEAM_CMD=$(echo "$PROMPT" | grep -oP "$_TEAMCREATE_PATTERN" | tr -d ' ')
  echo "🏗️ [TeamCreate 필수] ${_TEAM_CMD} 호출 — 반드시 TeamCreate로 팀에이전트를 spawn하여 실행하십시오. Agent() 직접 spawn 금지."

  # === Phase A 재발방지 핵심 (L-431) — TeamCreate 진입 직전 빈 team_name 사전 정리 ===
  # 문제: /resume 후 빈 team_name 파일 잔존 시 team_create_guard.sh가 LIVE: 빈 케이스로 오인 →
  #       EXISTING_TEAM=unknown 표기 + 차단. 진입 직전 빈 파일 청소로 차단을 사전 회피.
  if [[ -f "${SESSION_DIR}/team_name" ]]; then
    _TC_TN_SIZE=$(stat -c %s "${SESSION_DIR}/team_name" 2>/dev/null || echo 0)
    if [[ "$_TC_TN_SIZE" -eq 0 ]]; then
      rm -f "${SESSION_DIR}/team_name" 2>/dev/null
      _mirror_delete "${SESSION_DIR}/team_name"
      echo "🧹 [team_name 사전정리] 빈 team_name 파일 감지 → 삭제 (L-431 재발방지)"
    else
      _TC_TN_VAL=$(cat "${SESSION_DIR}/team_name" 2>/dev/null | tr -d '\r\n' || echo "")
      if [[ -z "$_TC_TN_VAL" ]]; then
        rm -f "${SESSION_DIR}/team_name" 2>/dev/null
        _mirror_delete "${SESSION_DIR}/team_name"
        echo "🧹 [team_name 사전정리] 공백 전용 team_name 파일 감지 → 삭제 (L-431 재발방지)"
      fi
    fi
  fi

  # F1 state_machine: IDLE/FINISH → PLAN CAS 전이 + classification=OK 동시 기록 (Phase B, L-431)
  # 변경 이력 (2026-05-06): state="OK" 강제 전이 → state="PLAN" + classification="OK" 동시 기록
  # 이유: stage 9→8 (OK 제거), level 6→7 (OK 추가) — CLAUDE.md 파이프라인 플래그 3축
  source "${HARNESS_HOOK_DIR}/lib/state_machine.sh"
  _TC_STATE_RC=1
  state_transition "${SESSION_DIR}/state" "IDLE" "PLAN" "teamcreate_force_${_TEAM_CMD#/}" "$UUID" 2>/dev/null \
    && _TC_STATE_RC=0
  if [[ "$_TC_STATE_RC" -ne 0 ]]; then
    state_transition "${SESSION_DIR}/state" "FINISH" "PLAN" "teamcreate_force_${_TEAM_CMD#/}" "$UUID" 2>/dev/null \
      && _TC_STATE_RC=0
  fi
  # state 전이 성공/이미 PLAN — classification=OK 기록 (level OK = tier 미정 신호)
  # 활성 파이프라인(이미 DEV/TEST 등)은 classification 덮어쓰기 금지.
  _TC_CUR_STATE=$(state_read "${SESSION_DIR}/state" 2>/dev/null | awk '{print $1}' | tr -d '\r' || echo "")
  if [[ "$_TC_CUR_STATE" == "PLAN" ]]; then
    # 기존 classification이 비어있거나 OK인 경우만 기록 (활성 tier 보존)
    _TC_EXIST_CLS=$(cat "${SESSION_DIR}/classification" 2>/dev/null | tr -d '\r\n' || echo "")
    if [[ -z "$_TC_EXIST_CLS" || "$_TC_EXIST_CLS" == "OK" ]]; then
      printf 'OK\n' > "${SESSION_DIR}/classification" 2>/dev/null || true
      _mirror_file "${SESSION_DIR}/classification"
    fi
  fi
  # entry_tier=OK 기록 (ok 그룹만 — /o1~/o5 직접 진입은 entry_tier 미기록)
  # 사용자 규칙3: /ok, /oto, /oralph, /okconsult, /okdebate, /okdeep → entry_tier=OK
  # /oto: ok와 동일 파이프라인(tier 미확정 → oplan이 결정)이므로 ok 그룹에 포함
  _ENTRY_TIER_OK_FROM_TEAMCREATE='^\s*/(ok|oto|oralph|okconsult|okdebate|okdeep)\b'
  if echo "$PROMPT" | grep -qP "$_ENTRY_TIER_OK_FROM_TEAMCREATE"; then
    printf 'OK\n' > "${SESSION_DIR}/entry_tier" 2>/dev/null || true
    _mirror_file "${SESSION_DIR}/entry_tier"
  fi
fi

# entry_tier=OK 기록 (인스턴스 플랜 그룹 — state 전이 없음, L-422 보호)
# 사용자 규칙3: /odeep, /oconsult, /odebate, /oplan, /onormal, /osimple → entry_tier=OK만 기록
_ENTRY_TIER_OK_INSTANCE_PLAN='^\s*/(odeep|oconsult|odebate|oplan|onormal|osimple)\b'
if echo "$PROMPT" | grep -qP "$_ENTRY_TIER_OK_INSTANCE_PLAN"; then
  printf 'OK\n' > "${SESSION_DIR}/entry_tier" 2>/dev/null || true
  _mirror_file "${SESSION_DIR}/entry_tier"
fi

# === oi 라우팅 (3-tier Hook/Skill 분리 아키텍처) ===
# 메인에이전트 한정, 슬래시 명령 제외
if [[ -z "${PIPELINE_UUID:-}" ]]; then
  if [[ "$_IS_SLASH_CMD" == "false" ]]; then
    # Phase B (L-431): state=OK 잔존 시 자동 PLAN 마이그레이션 (안전망)
    _smach_migrate_ok_to_plan "${SESSION_DIR}/state" "$UUID" 2>/dev/null || true
    # F6: state_read 경유 + __LOCK_FAIL__ 보수 처리
    _CURRENT_STATE=$(state_read "${SESSION_DIR}/state" 2>/dev/null | awk '{print $1}' | tr -d '\r' || echo "IDLE")
    _CURRENT_STATE=${_CURRENT_STATE:-IDLE}
    [[ "$_CURRENT_STATE" == "__LOCK_FAIL__" ]] && _CURRENT_STATE="IDLE"  # lock 경쟁 시 IDLE 처리(oi 라우팅만 skip)

    # classification 읽기 (Phase B — level OK = ok 분류 진입 단계 신호)
    _CURRENT_CLS=$(cat "${SESSION_DIR}/classification" 2>/dev/null | tr -d '\r\n' || echo "")

    case "$_CURRENT_STATE" in
      IDLE)
        # === 사이클123-E13: IDLE 모순 감지 ===
        # "에이전트는 도는데 state 는 IDLE" 이면 정의상 모순이다.
        # 이 경우 IDLE 바이패스를 하지 않고 oi 를 태운다(경고 + 라우팅 활성 취급).
        # state 파일은 쓰지 않는다 — 자동 전이는 잘못됐을 때 원래 사고보다 위험하다.
        # 판정은 "살아있는 --parent-session-id 프로세스" 유무로만 한다(잔존 파일 단독 판정 금지).
        _IC_HIT=0
        if [[ -f "${HARNESS_HOOK_DIR}/lib/idle_contradiction.sh" ]]; then
          source "${HARNESS_HOOK_DIR}/lib/idle_contradiction.sh" 2>/dev/null
          if type _ic_detect >/dev/null 2>&1; then
            _ic_detect "$SESSION_DIR" "$UUID" "IDLE" 2>/dev/null && _IC_HIT=1
          fi
        fi
        if [[ "$_IC_HIT" -eq 1 ]]; then
          echo "🚨 [IDLE 모순] state=IDLE 인데 팀에이전트 ${_IC_AGENTS}기가 살아있습니다${_IC_REASON:+ (증거: ${_IC_REASON})}."
          echo "   ⇒ 파이프라인 활성으로 간주합니다. IDLE 직접처리 금지 — Skill('oi') 호출 필수."
          echo "   (원인: spawn 후 state DEV 전이 누락. state 는 자동 변경하지 않았으니 메인이 직접 전이하십시오.)"
        else
          # IDLE: oi 바이패스 — 메인이 직접 처리 (state 변경 없음)
          echo "💬 [IDLE 직접처리] 사용자 요청에 바로 답변하세요."
        fi
        ;;
      PLAN|DEV)
        # PLAN+classification=OK: 파이프라인 시작 중 (구 OK stage 의미 보존) — 큐잉
        if [[ "$_CURRENT_STATE" == "PLAN" && "$_CURRENT_CLS" == "OK" ]]; then
          (
            flock -w 2 200
            echo "[$(date +%Y%m%d_%H%M%S)] $PROMPT" >> "${SESSION_DIR}/oi_queue"
          ) 200>"${SESSION_DIR}/oi_queue.lock"
          # ★불변식 3 — flock 서브셸 종료 후 미러★ (미러는 원본 .lock 을 잡지 않는다)
          _mirror_file "${SESSION_DIR}/oi_queue"
          echo "📋 [OK] 파이프라인 시작 중(PLAN+classification=OK) — 요청이 큐잉되었습니다."
        else
          # 파이프라인 활성 중: oi가 입력 분류 (상태 변경 없음)
          echo "💬 [oi] 활성(${_CURRENT_STATE}) — Skill('oi') 호출 필수"
        fi
        ;;
      TEST|DONE)
        # 작업은 큐잉, 질문은 oi가 즉시 처리
        (
          flock -w 2 200
          echo "[$(date +%Y%m%d_%H%M%S)] $PROMPT" >> "${SESSION_DIR}/oi_queue"
        ) 200>"${SESSION_DIR}/oi_queue.lock"
        # ★불변식 3 — flock 서브셸 종료 후 미러★
        _mirror_file "${SESSION_DIR}/oi_queue"
        echo "💬 [oi] 활성(${_CURRENT_STATE}) — Skill('oi') 호출 필수 (질문 즉시 답변, 작업은 큐잉됨)"
        ;;
      FINISH)
        # ofinish 실행 중 — oi 라우팅 불필요. 큐잉만 수행 (ofinish 완료 후 처리)
        (
          flock -w 2 200
          echo "[$(date +%Y%m%d_%H%M%S)] $PROMPT" >> "${SESSION_DIR}/oi_queue"
        ) 200>"${SESSION_DIR}/oi_queue.lock"
        # ★불변식 3 — flock 서브셸 종료 후 미러★
        _mirror_file "${SESSION_DIR}/oi_queue"
        echo "📋 [큐잉] FINISH 단계 진행 중 — ofinish 완료 후 처리됩니다."
        ;;

      EARLY_TERM)
        # 파이프라인 조기 종료 상태 — IDLE처럼 직접 처리
        echo "⚠️ [EARLY_TERM] 파이프라인이 조기 종료된 상태입니다. /oresume 또는 /ok로 재시작하세요."
        echo "💬 [IDLE 직접처리] 사용자 요청에 바로 답변하세요."
        ;;
      *)
        echo "💬 [oi] 알 수 없는 상태(${_CURRENT_STATE}) — Skill('oi') 호출 필수"
        ;;
    esac
  else
    echo "⚡ [슬래시 명령] oi 바이패스 — ${PROMPT%%$'\n'*}"
  fi
fi

# --- session_full 기반 새 세션 감지 (prev_sid 폐기) ---
SAVED_FULL=$(cat "${SESSION_DIR}/session_full" 2>/dev/null || echo "")

if [[ "$CURRENT_SESSION" != "$SAVED_FULL" ]]; then
  # 새 세션 시작 — session_full 갱신
  echo "$CURRENT_SESSION" > "${SESSION_DIR}/session_full"
  _mirror_file "${SESSION_DIR}/session_full"

  # --- HOOK_BLOCK 미해결 일괄 정리 (새 세션 시작 시 1회) ---
  if [[ -f "${HARNESS_HOOK_DIR}/lib/write_error.sh" ]]; then
    source "${HARNESS_HOOK_DIR}/lib/write_error.sh" 2>/dev/null
    fix_hook_block_errors "$UUID" 2>/dev/null
  fi

  # --- [P1-isolation] 타 세션 고착 정리 루프 제거 (2026-04-22) ---
  # 이전 동작: session-env/*/ 순회하며 다른 세션의 state=IDLE 강제 전환 + teams/tasks rm -rf.
  # 문제: cross-session mutation → 타 세션이 자기 teams/를 쓰려는 시점에 디렉토리 파괴 → crash.
  # 새 모델: 각 세션의 SessionStart.sh heartbeat-stale 블록이 "자기 세션 한정"으로 state IDLE 복구.
  #        teams/<name>/ 고아는 team_create_guard.sh의 lazy orphan cleanup이 담당 (실제 TeamCreate 충돌 시점).
  # 자기 세션 고착 정리는 이 블록 아래 "[자기 세션 고착 정리] 이전 상태 ... → IDLE 리셋" 로직이 담당.

  # --- [P1-isolation] F11-ext stale agents sweep 제거 (2026-04-22) ---
  # 이전 동작: 다른 세션의 agents/* 잔류 파일을 rm -rf로 일괄 정리.
  # 문제: 타 세션이 여전히 agents/*.json을 참조하는 중에 파괴 → 팀에이전트 결과 수집 실패.
  # 새 모델: agent_lifecycle.sh(PostToolUse)가 각 세션 스스로의 agents/ 라이프사이클 관리.
  #        UserPromptSubmit에서의 cross-session sweep은 중복이자 위험 요소 → 제거.

  # F-NEW-3: state_read (flock) 통일 — cat 직접 읽기 race condition 방지
  # Phase B (L-431): state=OK 잔존 시 자동 PLAN 마이그레이션 (호환성 안전망)
  _smach_migrate_ok_to_plan "${SESSION_DIR}/state" "$UUID" 2>/dev/null || true
  PREV_STATE=$(state_read "${SESSION_DIR}/state" 2>/dev/null | awk '{print $1}' | tr -d '\r' || echo "UNKNOWN")
  PREV_STATE=${PREV_STATE:-UNKNOWN}
  [[ "$PREV_STATE" == "__LOCK_FAIL__" ]] && PREV_STATE="UNKNOWN"  # lock 경쟁 시 UNKNOWN 처리

  if [[ "$PREV_STATE" == "PLAN" || "$PREV_STATE" == "DEV" || "$PREV_STATE" == "TEST" || "$PREV_STATE" == "DONE" || "$PREV_STATE" == "FINISH" ]]; then
    # L-NEW (6차 감사): 자기 세션 고착 감지 — agents=0 AND state mtime > 120s 이면 IDLE 리셋
    # 원인: 이전 파이프라인 비정상 종료 시 state=OK 잔류 → 새 세션이 이어받아 write_guard 데드락
    _MY_AGENT_COUNT=$(ls "${SESSION_DIR}/agents/" 2>/dev/null | wc -l | tr -d " ")
    _MY_STATE_MTIME=$(stat -c %Y "${SESSION_DIR}/state" 2>/dev/null || echo 0)
    _MY_NOW=$(date +%s)
    _MY_AGE=$(( _MY_NOW - _MY_STATE_MTIME ))
    # L-421: heartbeat age 추가 — 정상 파이프라인 보호 (heartbeat는 매 사용자 메시지마다 갱신)
    if [ -f "${SESSION_DIR}/heartbeat" ]; then
      _MY_HB_MTIME=$(stat -c %Y "${SESSION_DIR}/heartbeat" 2>/dev/null || echo 0)
    else
      _MY_HB_MTIME=0
    fi
    _MY_HB_AGE=$(( _MY_NOW - _MY_HB_MTIME ))
    if [ "${_MY_AGENT_COUNT:-0}" -eq 0 ] && [ "$_MY_AGE" -gt 120 ] && [ "$_MY_HB_AGE" -gt 300 ]; then
      state_write "${SESSION_DIR}/state" "IDLE $CURRENT_SESSION"
      # [P1-isolation U-4] teams/tasks 정리는 아래 _reset_idle에서 소유권 증명(leadSessionId 일치 +
      # 타 세션 claim cross-check) 후 수행. 여기서는 state IDLE 리셋 로깅만 수행.
      echo "🧹 [자기 세션 고착 정리] 이전 상태 ${PREV_STATE} (age=${_MY_AGE}s, agents=0) → IDLE 리셋"
      _reset_idle
      exit 0
    fi
    # 파이프라인 활성 중 — IDLE 리셋 금지, 기존 상태 유지
    state_write "${SESSION_DIR}/state" "$PREV_STATE $CURRENT_SESSION"
    CONV_ID=$(cat "${SESSION_DIR}/conv_id" 2>/dev/null || echo "conv_$(date +%s%N | cut -c1-12)")
    echo "$CONV_ID" > "${SESSION_DIR}/conv_id"
    _mirror_file "${SESSION_DIR}/conv_id"
    echo "✅ [ok 활성] 파이프라인 $PREV_STATE 진행 중 — 세션 재개 (대화ID: ${CONV_ID})"
    echo "🆔 [UUID] ${UUID}"
    # [P2-isolation] 다른 세션 파이프라인 표시 제거 — 크로스 세션 정보 유출 차단
    exit 0
  fi

  if [[ "$PREV_STATE" == "UNKNOWN" ]]; then
    # state 읽기 실패 — team_name 보호를 위해 _reset_idle 금지 (fail-closed)
    echo "⚠️ [state 읽기 실패] UNKNOWN — _reset_idle 스킵 (team_name 보호)"
    echo "🆔 [UUID] ${UUID}"
    exit 0
  fi

  # --- 고아 팀 감지 비활성화 (L-350: 팀에이전트 spawn 중 레이스 컨디션으로 팀 삭제 발생) ---
  # UserPromptSubmit 훅에서 팀 삭제하면 spawn 직후 팀이 없어져 에이전트 사망
  # → 팀 정리는 ostatus/ofinish_cleanup 명시 호출에서만 수행 (team-cleanup.sh)

  # IDLE 상태 → 새 세션으로 초기화
  state_write "${SESSION_DIR}/state" "IDLE $CURRENT_SESSION"
  _reset_idle
  exit 0
fi

# F-NEW-3: state_read (flock) 통일 — cat 직접 읽기 race condition 방지
# Phase B (L-431): state=OK 잔존 시 자동 PLAN 마이그레이션 (호환성 안전망)
_smach_migrate_ok_to_plan "${SESSION_DIR}/state" "$UUID" 2>/dev/null || true
STATE=$(state_read "${SESSION_DIR}/state" 2>/dev/null | awk '{print $1}' | tr -d '\r' || echo "UNKNOWN")
STATE=${STATE:-UNKNOWN}
[[ "$STATE" == "__LOCK_FAIL__" ]] && STATE="UNKNOWN"  # lock 경쟁 시 UNKNOWN 처리
if [[ "$STATE" == "UNKNOWN" ]]; then
  # state 읽기 실패 — team_name 보호를 위해 _reset_idle 금지 (fail-closed)
  echo "⚠️ [state 읽기 실패] UNKNOWN — _reset_idle 스킵 (team_name 보호)"
  echo "🆔 [UUID] ${UUID}"
  exit 0
fi
if [[ "$STATE" == "IDLE" ]]; then
  _reset_idle
  exit 0
fi
CONV_ID=$(cat "${SESSION_DIR}/conv_id" 2>/dev/null || echo "")
if [[ -n "$CONV_ID" ]]; then
  echo "✅ [ok 활성] 파이프라인 $STATE — 작업 진행 중 (대화ID: ${CONV_ID})"
else
  echo "✅ [ok 활성] 파이프라인 $STATE — 작업 진행 중"
fi
echo "🆔 [UUID] ${UUID}"
# [P2-isolation] 다른 세션 파이프라인 표시 제거 — 크로스 세션 정보 유출 차단
exit 0
