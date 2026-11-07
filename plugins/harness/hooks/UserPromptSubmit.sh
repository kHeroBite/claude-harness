#!/bin/bash
# [훅1] UserPromptSubmit — 매 사용자 메시지마다 세션 초기화 + ok 상태 체크
# 목적: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/ 디렉토리 생성, session_full 갱신
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
#
# --- 사이클173 시간 예산 (UPS-BUDGET) ---
# 배경(2026-10-10 실측): Claude Code 는 이 hook 을 timeout=5s 로 실행하고, 초과하면 출력 전체를 버린다.
#   hook 자체는 평시 0.4~0.7s 이지만 다중 세션 부하(load 17~42) 구간에서 NTFS(/mnt/c — hooks 실체 위치)
#   파일 1회 읽기가 0.5~1.2s, fork 1회가 0.1~0.5s 로 치솟는다. 본문은 NTFS lib ~10회 읽기 + fork ~60회라
#   정체 구간에서 5s 를 넘긴다(11:38~11:42 KST 4분간 UserPromptSubmit 7건 + 타 hook 11건 동시 timeout).
# 조치: 본문(_ups_main)을 백그라운드 서브셸로 돌리고 부모는 UPS_BUDGET_SEC(기본 2.5s)까지만 기다린다.
#   (settings.json timeout 5s 대비 2.5s 여유 — NTFS 에서 이 스크립트 자체를 읽는 기동 지연분. timeout 은 변경하지 않았다)
#   - 예산 안에 끝나면 → 본문 출력을 그대로 내보낸다(종전과 동일).
#   - 예산 초과 시 → 포크·NTFS 없이(bash 빌트인 + EXT4 state 파일만) 필수 안내를 출력하고 즉시 exit 0.
#     본문은 계속 실행되어 상태 기록을 마치고, 뒤늦은 출력은 자기 세션 logs/ups_late_output.log 로 남긴다.
#   - 매 실행 소요는 자기 세션 logs/ups_timing.log(전체)·logs/ups_stages.log(단계별)에 기록한다.
# 회귀 테스트: hooks/tests/test_ups_time_budget.sh

_ups_main() {
source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/session_mirror.sh" 2>/dev/null
declare -F _mirror_file >/dev/null 2>&1 || _mirror_file() { :; }
declare -F _mirror_delete >/dev/null 2>&1 || _mirror_delete() { :; }

# --- stdin JSON 파싱 ---
# (UPS-BUDGET) stdin 은 부모가 _ups_main 실행 전에 INPUT 으로 읽어 둔다.
_ups_mark parsed_pre
if [[ -z "$INPUT" ]]; then
  echo "ℹ️ [ok 스킵] 시스템 이벤트 — stdin 비어있음"
  exit 0
fi
CURRENT_SESSION=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null) || CURRENT_SESSION="unknown"
PROMPT=$(echo "$INPUT" | jq -r '.prompt // ""' 2>/dev/null) || PROMPT=""
# 슬래시 명령의 플러그인 접두사(/harness:ok → /ok)를 정규화한다. 접두사 없는 입력은 그대로다.
if [[ "$PROMPT" =~ ^([[:space:]]*/)([A-Za-z0-9_-]+:)? ]]; then PROMPT="${BASH_REMATCH[1]}${PROMPT:${#BASH_REMATCH[0]}}"; fi

# [P2-isolation] _find_active_pipelines() 제거 — 다른 세션 정보를 현재 에이전트에게 노출하는 것은
# 세션 격리 위반이며, 에이전트가 타 세션 파이프라인을 자기 것으로 오인하여 크로스 뮤테이션을 유발했음.
# 각 세션은 자기 UUID(SESSION_DIR) 내부만 참조해야 한다. (L-유출차단, 2026-04-22)

# --- [10D] conv_id 덮어쓰기 직전 이전 값 기록 (2026-10-11, conv_179163042411) ---
# 목적: 재기동 뒤 첫 입력에서 _reset_idle 이 conv_id 를 새로 만들면 oresume 의 conv_id 게이트(L-670)가
#       기존 결과를 전부 잔류물로 버린다. 이전 값을 자기 세션 resume_preserve/ 에 남겨 복원 근거로 쓴다.
# 비용: IDLE 입력마다 실행되므로 bash 빌트인만 쓴다(포크·NTFS 읽기 없음, 디렉토리 최초 생성 1회만 mkdir).
#       최근 50줄만 유지한다. 쓰기 위치는 $HOME/.claude/session-env/<자기 UUID>/ 하위만(격리 §(a)).
_rp_conv_before_reset() {
  local _old="" _d _f _lines=()
  [[ -n "$UUID" && -r "${SESSION_DIR}/conv_id" ]] || return 0
  read -r _old < "${SESSION_DIR}/conv_id" 2>/dev/null
  [[ -n "$_old" ]] || return 0
  _d="$HOME/.claude/session-env/${UUID}/resume_preserve"
  [[ -d "$_d" ]] || mkdir -p "$_d" 2>/dev/null || return 0
  _f="$_d/conv_id.before_reset"
  if [[ -r "$_f" ]]; then
    mapfile -t _lines < "$_f" 2>/dev/null
    (( ${#_lines[@]} >= 50 )) && printf '%s\n' "${_lines[@]: -49}" > "$_f" 2>/dev/null
  fi
  printf '%s %s\n' "${EPOCHSECONDS:-0}" "$_old" >> "$_f" 2>/dev/null
  return 0
}

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
    # [2026-10-29 팀 소실 사고] teams/·tasks/ 디렉토리는 삭제하지 않는다.
    #   v2.1.178+ 에서 팀 디렉토리는 Claude Code 런타임이 세션 수명 동안 관리하고 세션 종료 시 스스로 지운다.
    #   IDLE 에서 위임 팀원(oopus 등)을 띄우면 agent_lifecycle.sh 가 team_name 을 다시 쓰고, 다음 입력의
    #   _reset_idle 이 살아 있는 팀 디렉토리를 지워 이후 모든 Agent spawn 이 "team file not found" 로 막혔다.
    #   소유권 판정 결과는 로그로만 남기고 디렉토리는 건드리지 않는다.
    if [[ $_OWNER_OK -eq 1 && $_OTHER_CLAIM -eq 0 ]]; then
      echo "$(date -Iseconds 2>/dev/null) reset_idle team_dir_kept team=${_OLD_TEAM}" >> "${SESSION_DIR}/logs/reset_idle_team.log" 2>/dev/null || true
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
  _rp_conv_before_reset  # [10D] 덮어쓰기 직전 이전 conv_id 보존
  CONV_ID="conv_$(date +%s%N | cut -c1-12)"
  echo "$CONV_ID" > "${SESSION_DIR}/conv_id"
  _mirror_file "${SESSION_DIR}/conv_id"
  [[ "${_IS_SLASH_CMD:-false}" == "true" ]] && echo "🔀 [2-way 선분류] 질문/수정 → ok 1-way(o1~o5)"
  echo "🆔 [대화 ID] ${CONV_ID}"
  echo "🆔 [UUID] ${UUID}"
  # [P2-isolation] 다른 세션 파이프라인 표시 제거 — 크로스 세션 정보 유출 차단
}

# --- UUID 결정 ---
source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/session_id.sh"
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
_ups_mark session_dir

# --- 프롬프트 저장 ---
echo "$PROMPT" > "${SESSION_DIR}/plans/user_prompt.md"
_mirror_file "${SESSION_DIR}/plans/user_prompt.md"

# --- heartbeat 갱신 (매 사용자 메시지마다 — 고아 감지용) ---
# heartbeat_cron.sh가 이 파일의 mtime으로 "메인 에이전트 살아있음" 판단
touch "${SESSION_DIR}/heartbeat" 2>/dev/null
_mirror_file "${SESSION_DIR}/heartbeat"

# --- F-INTAUG-1 기준점 마커 갱신 (사이클134 — 턴 경계 직접 관측) ---
# 목적: PreToolUse_Skill_ointaug_gate.sh 가 "ointaug 마커 >= 이번 턴 기준점" 으로 판정할 수 있도록
#       턴 경계(이번 UserPromptSubmit 발화 시점)를 mtime 으로 기록한다.
# L-467: 에이전트가 쓸 수 있는 자기신고 값은 판정축이 될 수 없다. UserPromptSubmit 은 런타임이
#        직접 실행하며 에이전트 도구 호출 경로 밖이므로 mtime 이 조작 불가능한 기준점이 된다.
# 내용은 비운다 — 판정축은 mtime 단독이다(touch 만 수행).
# (사이클174) 런처가 이미 동기로 갱신했으면 다시 찍지 않는다 — 예산 초과로 본문이 늦게 돌면 기준점이 Skill 호출보다
#   뒤로 밀려 F-INTAUG-1·oi_route_guard 가 정상 호출을 미충족으로 오판한다. 런처가 못 찍은 경우(첫 입력 — 디렉토리 부재)만 여기서 찍는다.
[[ -n "${_UPS_LPE_DONE:-}" || -n "${_UPS_NOTIF:-}" ]] || touch "${SESSION_DIR}/last_prompt_epoch" 2>/dev/null
[[ -n "${_UPS_NOTIF:-}" ]] || _mirror_file "${SESSION_DIR}/last_prompt_epoch"

# --- 사용자 피드백 실시간 감지 (소스 C — 파이프라인 활성 중만) ---
# F6: state_read 경유 + __LOCK_FAIL__ 명시 감지 (허위 IDLE 방지)
# Phase B (L-431): state=OK 잔존 시 자동 PLAN으로 마이그레이션 (다른 활성 세션 보호)
source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/state_machine.sh" 2>/dev/null
_smach_migrate_ok_to_plan "${SESSION_DIR}/state" "$UUID" 2>/dev/null || true
_FB_STATE=$(state_read "${SESSION_DIR}/state" 2>/dev/null | awk '{print $1}' | tr -d '\r' || echo "IDLE")
_FB_STATE=${_FB_STATE:-IDLE}
[[ "$_FB_STATE" == "__LOCK_FAIL__" ]] && _FB_STATE="IDLE"  # lock 경쟁 시 감지 skip
case "$_FB_STATE" in
  PLAN|DEV|TEST|DONE)
    # 시스템 알림·팀원·다른 세션 메시지(_UPS_NOTIF)는 사용자 피드백이 아니다 — 본문 단어("다시" 등)에 반응하지 않는다(사이클203).
    if [[ -z "${_UPS_NOTIF:-}" && -f "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/user_feedback_detector.sh" ]]; then
      source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/user_feedback_detector.sh" 2>/dev/null
      detect_user_feedback "$PROMPT" "$UUID" 2>/dev/null
    fi
    # 사이클172 C26 보강2 (L-1195): 사용자 입력 원문을 자기 세션 scope_markers/_user.json(type=info)에 자동 기록
    #   → PreToolUse_stop_marker_gate.sh 가 팀원 다음 도구 호출을 1회 보류하며 원문 전달(리드 수동 작성 의존 제거).
    #   메인 전용(PIPELINE_UUID 부재 + 부모 체인 --agent-id 없음) · 입력 session_id == UUID 일 때만(세션 격리 (a)).
    #   비상 해제: hooks/DISABLE_STOP_MARKER_GATE (게이트와 함께 끈다)
    #   시스템 알림·팀원·다른 세션 메시지(_UPS_NOTIF — 런처의 구조 판정)는 사용자 지시가 아니므로 기록하지 않는다(사이클202, mars-da 제보).
    if [[ -z "${PIPELINE_UUID:-}" && -z "${_UPS_NOTIF:-}" && ! -f "${HARNESS_HOME:-$HOME/.harness}/current/hooks/DISABLE_STOP_MARKER_GATE" ]]; then
      _SM_SID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
      if [[ "$_SM_SID" == "$UUID" ]] && ! bash -c 'source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/chain_agent.sh" && chain_agent_resolve' 2>/dev/null; then
        printf '%s' "$PROMPT" | timeout 5 python3 -I "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/scope_marker_autowrite.py" "$SESSION_DIR" 2>/dev/null || true
      fi
    fi
    ;;
esac
_ups_mark feedback

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
  # 자기 세션(UUID=입력 session_id)에만 쓴다. _FB_UUID 는 어디서도 설정되지 않아 표식이 한 번도 생기지 않았다(2026-11-08 정정).
  _SESSION_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID:-}"
  if [[ "${UUID:-}" =~ ^[0-9A-Za-z-]+$ ]] && [[ -d "$_SESSION_DIR" ]]; then
    touch "$_SESSION_DIR/ogrill_slash_flag"
    _mirror_file "$_SESSION_DIR/ogrill_slash_flag"
  fi
fi

# --- ointaug: 질의 확장 지시 (슬래시 명령 포함 모든 명령에 항상 발동) ---
# 설계: ointaug는 모든 입력의 첫 번째 행동. 슬래시 스킬도 ointaug 이후에 호출됨.
# 호출 순서: ointaug → 해당 스킬 (예: ointaug → oroof → ok)
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
if [[ -n "${_UPS_NOTIF:-}" ]]; then
  # 시스템 알림·팀원 메시지 — 사용자 입력이 아니므로 ointaug 를 요구하지 않는다(턴 게이트 요구 표식도 안 찍힌다)
  echo "ℹ️ [알림] 시스템/팀원 메시지 — Skill('ointaug') 요구 대상 아님"
elif [[ "$_OINTAUG_SKIP" == "false" ]]; then
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
# 시스템 알림·팀원·다른 세션 메시지(_UPS_NOTIF)는 사용자 요청이 아니므로 💡 권장을 내지 않는다(사이클204).
if [[ -z "${_UPS_NOTIF:-}" ]] && [[ "$_FB_STATE" == "IDLE" || -z "$_FB_STATE" ]] && [[ "$_IS_SLASH_CMD" == "false" ]]; then
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

# --- 반복 작업 패턴 감지 → oroof 호출 권장 (v2: 독립 스킬 oroof로 라우팅) ---
# 감지 패턴: 한국어 반복 요청 키워드 (완성될 때까지, 없어질 때까지, 끝날 때까지 등)
# /oroof 명시 호출 시 제외 — 사용자가 이미 oroof를 호출 중이므로 중복 발동 불필요
# 변경 이력: oroof가 ralph-loop를 내부 흡수(v4.0)하여 독립 스킬화됨 →
#   더 이상 외부 ralph-loop 플러그인을 호출하지 않고 oroof 자체로 반복 검증 루프를 수행한다.
# 시스템 알림·팀원·다른 세션 메시지(_UPS_NOTIF)는 반복 작업 요청이 아니다(사이클203).
if [[ -z "${_UPS_NOTIF:-}" ]] && echo "$PROMPT" | grep -qP '(완성될?|없어질?|끝날|고쳐질|사라질|통과할|성공할|해결될?|없을)\s*때까지|반복(해(?!\S)|해서|해라|하라|적으로)|(계속\s*(해|실행|진행|반복))'; then
  if ! echo "$PROMPT" | grep -qP '^\s*/oroof\b'; then
    # 사용자 입력을 args로 전달하도록 안내 (빈 args 호출 시 Phase 0 초기화 실패 방지)
    _OROOF_PROMPT=$(echo "$PROMPT" | head -1)
    jq -n \
      --arg hook_event "UserPromptSubmit" \
      --arg oroof_prompt "$_OROOF_PROMPT" \
      '{
        hookSpecificOutput: {
          hookEventName: $hook_event,
          additionalContext: ("⚠️ [반복 작업 감지] 사용자가 반복 수행 패턴을 요청했습니다. Skill('\''oroof'\'')를 첫 번째 행동으로 호출하라 (ointaug 이후). oroof는 ok 파이프라인 + 내장 검증 루프를 제공하는 독립 스킬이다.\n사용자 입력을 args에 전달하라: Skill('\''oroof'\'', args='\''" + $oroof_prompt + "'\'')")
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
_O_NONIDLE_PATTERN='^\s*/(ok|oto|o[1-5]|oroof|okconsult|okdebate|okdeep)\b'
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
# L-428: 단위 스킬 제외 — 파이프라인 진입 슬래시 명령만 TeamCreate 강제 대상(write_guard.sh F-OEXIT-1 과 짝)
_TEAMCREATE_PATTERN='^\s*/(ok|oto|o[1-5]|oroof|okconsult|okdebate|okdeep)\b'
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
  source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/state_machine.sh"
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
  # 사용자 규칙3: /ok, /oto, /oroof, /okconsult, /okdebate, /okdeep → entry_tier=OK
  # /oto: ok와 동일 파이프라인(tier 미확정 → oplan이 결정)이므로 ok 그룹에 포함
  _ENTRY_TIER_OK_FROM_TEAMCREATE='^\s*/(ok|oto|oroof|okconsult|okdebate|okdeep)\b'
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
        if [[ -f "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/idle_contradiction.sh" ]]; then
          source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/idle_contradiction.sh" 2>/dev/null
          if declare -F _ic_detect >/dev/null 2>&1; then
            _ic_detect "$SESSION_DIR" "$UUID" "IDLE" 2>/dev/null && _IC_HIT=1
          fi
        fi
        if [[ "$_IC_HIT" -eq 1 ]]; then
          echo "🚨 [IDLE 모순] state=IDLE 인데 팀에이전트 ${_IC_AGENTS}기가 살아있습니다${_IC_REASON:+ (증거: ${_IC_REASON})}."
          if [[ -n "${_UPS_NOTIF:-}" ]]; then
            echo "   ⇒ 이번 입력은 시스템/팀원 메시지라 Skill('oi') 요구 대상 아님."
          else
            echo "   ⇒ 파이프라인 활성으로 간주합니다. IDLE 직접처리 금지 — Skill('oi') 호출 필수."
          fi
          echo "   (원인: spawn 후 state DEV 전이 누락. state 는 자동 변경하지 않았으니 메인이 직접 전이하십시오.)"
        else
          # IDLE: oi 바이패스 — 메인이 직접 처리 (state 변경 없음)
          echo "💬 [IDLE 직접처리] 사용자 요청에 바로 답변하세요."
        fi
        ;;
      PLAN|DEV)
        # PLAN+classification=OK: 파이프라인 시작 중 (구 OK stage 의미 보존) — 큐잉
        if [[ "$_CURRENT_STATE" == "PLAN" && "$_CURRENT_CLS" == "OK" ]]; then
          # 시스템 알림·팀원·다른 세션 메시지(_UPS_NOTIF)는 사용자 요청이 아니므로 oi_queue 에 적재하지 않는다(사이클204).
          if [[ -z "${_UPS_NOTIF:-}" ]]; then
            (
              flock -w 2 200
              echo "[$(date +%Y%m%d_%H%M%S)] $PROMPT" >> "${SESSION_DIR}/oi_queue"
            ) 200>"${SESSION_DIR}/oi_queue.lock"
            # ★불변식 3 — flock 서브셸 종료 후 미러★ (미러는 원본 .lock 을 잡지 않는다)
            _mirror_file "${SESSION_DIR}/oi_queue"
            echo "📋 [OK] 파이프라인 시작 중(PLAN+classification=OK) — 요청이 큐잉되었습니다."
          else
            echo "ℹ️ [알림] 시스템/팀원 메시지 — oi_queue 적재 대상 아님"
          fi
        elif [[ -n "${_UPS_NOTIF:-}" ]]; then
          # 사이클206 F-INTAUG-3: 시스템/팀원/다른 세션 메시지는 런처(_ups_require)가 oi_required 를 쓰지 않는다 — 문구도 실제 판정과 맞춘다
          echo "ℹ️ [알림] 시스템/팀원 메시지 — Skill('oi') 요구 대상 아님 (파이프라인 활성: ${_CURRENT_STATE})"
        else
          # 파이프라인 활성 중: oi가 입력 분류 (상태 변경 없음)
          echo "💬 [oi] 활성(${_CURRENT_STATE}) — Skill('oi') 호출 필수"
        fi
        ;;
      TEST|DONE)
        # 작업은 큐잉, 질문은 oi가 즉시 처리
        # 시스템 알림·팀원·다른 세션 메시지(_UPS_NOTIF)는 oi_queue 에 적재하지 않는다(사이클204).
        if [[ -z "${_UPS_NOTIF:-}" ]]; then
          (
            flock -w 2 200
            echo "[$(date +%Y%m%d_%H%M%S)] $PROMPT" >> "${SESSION_DIR}/oi_queue"
          ) 200>"${SESSION_DIR}/oi_queue.lock"
          # ★불변식 3 — flock 서브셸 종료 후 미러★
          _mirror_file "${SESSION_DIR}/oi_queue"
          echo "💬 [oi] 활성(${_CURRENT_STATE}) — Skill('oi') 호출 필수 (질문 즉시 답변, 작업은 큐잉됨)"
        else
          echo "ℹ️ [알림] 시스템/팀원 메시지 — oi_queue 적재 대상 아님"
        fi
        ;;
      FINISH)
        # ofinish 실행 중 — oi 라우팅 불필요. 큐잉만 수행 (ofinish 완료 후 처리)
        # 시스템 알림·팀원·다른 세션 메시지(_UPS_NOTIF)는 oi_queue 에 적재하지 않는다(사이클204).
        if [[ -z "${_UPS_NOTIF:-}" ]]; then
          (
            flock -w 2 200
            echo "[$(date +%Y%m%d_%H%M%S)] $PROMPT" >> "${SESSION_DIR}/oi_queue"
          ) 200>"${SESSION_DIR}/oi_queue.lock"
          # ★불변식 3 — flock 서브셸 종료 후 미러★
          _mirror_file "${SESSION_DIR}/oi_queue"
          echo "📋 [큐잉] FINISH 단계 진행 중 — ofinish 완료 후 처리됩니다."
        else
          echo "ℹ️ [알림] 시스템/팀원 메시지 — oi_queue 적재 대상 아님"
        fi
        ;;

      EARLY_TERM)
        # 파이프라인 조기 종료 상태 — IDLE처럼 직접 처리
        echo "⚠️ [EARLY_TERM] 파이프라인이 조기 종료된 상태입니다. /oresume 또는 /ok로 재시작하세요."
        echo "💬 [IDLE 직접처리] 사용자 요청에 바로 답변하세요."
        ;;
      *)
        if [[ -n "${_UPS_NOTIF:-}" ]]; then
          echo "ℹ️ [알림] 시스템/팀원 메시지 — Skill('oi') 요구 대상 아님 (상태: ${_CURRENT_STATE})"
        else
          echo "💬 [oi] 알 수 없는 상태(${_CURRENT_STATE}) — Skill('oi') 호출 필수"
        fi
        ;;
    esac
  else
    echo "⚡ [슬래시 명령] oi 바이패스 — ${PROMPT%%$'\n'*}"
  fi
fi

# (F-INTAUG-3 요구 표식 ointaug_required/oi_required 는 이 본문이 아니라 파일 하단 런처의 _ups_require 가 동기로 쓴다 —
#  본문은 예산 초과 시 hook 반환 뒤에도 백그라운드로 돌아 Skill 호출보다 늦게 찍힐 수 있다. 사이클174)

_ups_mark routing
# --- session_full 기반 새 세션 감지 (prev_sid 폐기) ---
SAVED_FULL=$(cat "${SESSION_DIR}/session_full" 2>/dev/null || echo "")

if [[ "$CURRENT_SESSION" != "$SAVED_FULL" ]]; then
  # 새 세션 시작 — session_full 갱신
  echo "$CURRENT_SESSION" > "${SESSION_DIR}/session_full"
  _mirror_file "${SESSION_DIR}/session_full"

  # --- HOOK_BLOCK 미해결 일괄 정리 (새 세션 시작 시 1회) ---
  if [[ -f "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/write_error.sh" ]]; then
    source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/write_error.sh" 2>/dev/null
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
      # [10D] IDLE 기록·메타 삭제 직전 보존 사본 — lib 은 이 드문 분기에서만 읽는다(평시 무비용)
      if source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/resume_preserve.sh" 2>/dev/null; then
        rp_save "${SESSION_DIR}" ups_stale
      fi
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

  # [c193 oi-fix-2 2026-10-19] 자동 stale 판정(SessionStart boot-stale/hb/R3)이 만든 IDLE 인데 자기 팀원이 살아 있으면
  #   그 IDLE 은 오판이다. _reset_idle(팀 디렉토리 정리·conv_id 재발급)을 하지 않고 oresume 복원을 안내한다.
  #   사고: 10-19 17:59 boot-stale 오발동 뒤 첫 입력에서 conv_id 가 재발급됐다. 정상 IDLE(사용자 종료·ofinish)은 영향 없음.
  _UPS_IDLE_LINE=$(state_read "${SESSION_DIR}/state" 2>/dev/null | head -n 1)
  case " $_UPS_IDLE_LINE" in
    *" stale_"*|*" stale_hb_"*|*" r3_stale_"*)
      if source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/orphan_scan.sh" 2>/dev/null; then
        _UPS_ALIVE=$(orphan_scan_count "$UUID" 2>/dev/null)
        if [[ "$_UPS_ALIVE" =~ ^[0-9]+$ && "$_UPS_ALIVE" -gt 0 ]]; then
          echo "⚠️ [stale IDLE 오판 감지] 자동 stale 정리로 IDLE 이 됐지만 자기 팀원 ${_UPS_ALIVE}개가 살아 있다 — IDLE 초기화·conv_id 재발급을 건너뛴다. Skill('oresume') 로 직전 파이프라인을 복원하라."
          echo "🆔 [UUID] ${UUID}"
          exit 0
        fi
      fi
      ;;
  esac

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
}  # _ups_main 끝

# ===== UPS-BUDGET 런처 — 여기부터는 bash 빌트인 위주(포크·NTFS 최소화) =====
_UPS_T0=${EPOCHREALTIME/[.,]/}
_ups_elapsed_ms() { _UPS_EL=$(( (${EPOCHREALTIME/[.,]/} - _UPS_T0) / 1000 )); }
_UPS_STAGES=""
_ups_mark() { _ups_elapsed_ms; _UPS_STAGES+=" $1=${_UPS_EL}ms"; }

INPUT=$(timeout 5 cat 2>/dev/null) || INPUT=""
_ups_mark stdin
_UPS_BUDGET="${UPS_BUDGET_SEC:-2.5}"
_UPS_SID=""
[[ "$INPUT" =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9_-]+)\" ]] && _UPS_SID="${BASH_REMATCH[1]}"
_UPS_SDIR=""
[[ -n "$_UPS_SID" ]] && _UPS_SDIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${_UPS_SID}"
_UPS_OUT="${TMPDIR:-/tmp}/ups_out.$$.${_UPS_T0}"

# 자기 세션 logs/ 에만 기록한다(세션 격리 §(a)). logs/ 가 없으면(첫 입력 등) 조용히 건너뛴다.
_ups_log() {  # $1=파일명 $2=내용
  [[ -n "$_UPS_SDIR" && -d "$_UPS_SDIR/logs" ]] || return 0
  local _ts; printf -v _ts '%(%Y-%m-%dT%H:%M:%S)T' -1
  printf '%s %s\n' "$_ts" "$2" >> "$_UPS_SDIR/logs/$1" 2>/dev/null
  return 0
}

# 본문 종료 시(정상·exit 어디서든) 단계별 소요 기록. 부모가 이미 포기(.late)했으면 뒤늦은 출력을 보존한다.
_ups_body_exit() {
  _ups_mark end
  _ups_log ups_stages.log "pid=$$${_UPS_STAGES}"
  if [[ -e "${_UPS_OUT}.late" ]]; then
    { printf -- '--- late output (pid=%s%s) ---\n' "$$" "$_UPS_STAGES"; cat "$_UPS_OUT" "${_UPS_OUT}.err" 2>/dev/null; } >> "$_UPS_SDIR/logs/ups_late_output.log" 2>/dev/null
    rm -f "$_UPS_OUT" "${_UPS_OUT}.err" "${_UPS_OUT}.late" 2>/dev/null
  fi
}

# --- L-1362: 하네스가 감싼 cross-session 통지인지 구조로 판정한다(접두만 보지 않는다 — 사람이 같은 접두를 입력할 수 있다) ---
#   실측(2026-10-24 user_directives.log 4건): 본문은 '<cross-session-message from="uds:…" from-name="…" from-mode="…">' 로 시작하고
#   '</cross-session-message>' 로 끝난다. 구조 = 첫 속성 from="값" + 속성만으로 된 여는 태그 + 본문 끝 닫는 태그(뒤 공백만 허용).
#   _p 는 첫 \" 에서 잘리므로 INPUT 에서 prompt 값 전체를 다시 뽑는다. 접두가 맞을 때만 돌려 일반 입력 비용은 0 이다.
#   출처 필드 없음(공식 hooks 문서 UserPromptSubmit input 절 확인 2026-10-24): 입력은 session_id·transcript_path·cwd·permission_mode·
#   hook_event_name·prompt(+공통 필드)뿐이고, 문서는 "다른 세션이 보낸 메시지에도 이 hook 이 발동한다"고만 적는다.
#   ⇒ 잔존 한계: 사람이 이 구조 전체를 그대로 입력하면 구별할 수 없다.
_UPS_XS_RE='"prompt"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"'
_UPS_XS_HEAD='^<cross-session-message from=\\"[^"\\]+\\"( [a-z][a-z-]*=\\"[^"\\]*\\")*>'
_ups_is_xsession() {  # $1=앞 공백을 벗긴 _p
  [[ "$1" == "<cross-session-message from="* ]] || return 1
  [[ "$INPUT" =~ $_UPS_XS_RE ]] || return 1
  local _v="${BASH_REMATCH[1]}"
  while [[ "$_v" == [[:space:]]* || "$_v" == \\n* || "$_v" == \\t* ]]; do
    if [[ "$_v" == \\* ]]; then _v="${_v:2}"; else _v="${_v:1}"; fi
  done
  while [[ "$_v" == *[[:space:]] || "$_v" == *\\n || "$_v" == *\\t ]]; do
    if [[ "$_v" == *[[:space:]] ]]; then _v="${_v%?}"; else _v="${_v%??}"; fi
  done
  [[ "$_v" =~ $_UPS_XS_HEAD ]] || return 1
  [[ "$_v" == *"</cross-session-message>" ]] || return 1
  return 0
}

# 예산 초과 시 축약 안내 — 빌트인 + EXT4 state 파일 1회 읽기만 사용한다.
_ups_fallback() {
  local _st="" _x="" _p="" _nt=""
  [[ -n "$_UPS_SDIR" && -r "$_UPS_SDIR/state" ]] && read -r _st _x < "$_UPS_SDIR/state" 2>/dev/null
  [[ "$INPUT" =~ \"prompt\"[[:space:]]*:[[:space:]]*\"([^\"]*) ]] && _p="${BASH_REMATCH[1]}"
  while [[ "$_p" == [[:space:]]* || "$_p" == \\n* || "$_p" == \\t* ]]; do
    if [[ "$_p" == \\* ]]; then _p="${_p:2}"; else _p="${_p:1}"; fi
  done
  if [[ "$_p" =~ ^/([A-Za-z0-9_-]+:)? ]]; then _p="/${_p:${#BASH_REMATCH[0]}}"; fi  # 플러그인 접두사 정규화
  if [[ "$_p" == "<teammate-message"* || "$_p" == "<task-notification"* ]] || _ups_is_xsession "$_p"; then
    _nt=1
    echo "ℹ️ [알림] 시스템/팀원 메시지 — Skill('ointaug') 요구 대상 아님"
  elif [[ "$_p" =~ ^/ox([[:space:]]|\\|$) ]]; then
    echo "⚡ [ox] o시리즈 완전 바이패스 — ointaug 미발동. Skill 호출 없이 즉시 작업에 착수하라."
  else
    echo "📌 [ointaug 필수] ⚠️ CLAUDE.md 규칙: Skill('ointaug')를 반드시 첫 번째 행동으로 호출하고 확장 질의를 화면에 출력한 후 답변하라. 미호출 시 위반."
    if [[ -n "$_st" && "$_st" != "IDLE" ]]; then
      echo "   ↳ 순서: Skill('ointaug') → 그 다음 아래 안내된 스킬(Skill('oi') 등). ointaug 가 항상 먼저다."
    fi
  fi
  echo "⏱️ [hook 지연] UserPromptSubmit 본문이 시간 예산(${_UPS_BUDGET}s)을 넘겨 축약 안내만 출력합니다. 상태 기록은 백그라운드에서 계속됩니다."
  if [[ "$_p" =~ ^/(ok|oto|o[1-5]|oroof|okconsult|okdebate|okdeep)([[:space:]]|\\|$) ]]; then
    echo "🏗️ [TeamCreate 필수] /${BASH_REMATCH[1]} 호출 — 반드시 TeamCreate로 팀에이전트를 spawn하여 실행하십시오. Agent() 직접 spawn 금지."
  fi
  if [[ -z "${PIPELINE_UUID:-}" ]]; then
    if [[ "$_p" =~ ^/[a-zA-Z][a-zA-Z0-9_-]*([[:space:]]|\\|$) ]]; then
      echo "⚡ [슬래시 명령] oi 바이패스 — ${_p%%\\n*}"
    else
      case "$_st" in
        IDLE|"") echo "💬 [IDLE 직접처리] 사용자 요청에 바로 답변하세요." ;;
        EARLY_TERM)
          echo "⚠️ [EARLY_TERM] 파이프라인이 조기 종료된 상태입니다. /oresume 또는 /ok로 재시작하세요."
          echo "💬 [IDLE 직접처리] 사용자 요청에 바로 답변하세요." ;;
        FINISH) echo "📋 [큐잉] FINISH 단계 진행 중 — ofinish 완료 후 처리됩니다." ;;
        PLAN|DEV|TEST|DONE)
          # 사이클206 F-INTAUG-3: 통지 턴은 oi_required 를 쓰지 않으므로 문구도 맞춘다
          if [[ -n "$_nt" ]]; then echo "ℹ️ [알림] 시스템/팀원 메시지 — Skill('oi') 요구 대상 아님 (파이프라인 활성: ${_st})"
          else echo "💬 [oi] 활성(${_st}) — Skill('oi') 호출 필수"; fi ;;
        *)
          if [[ -n "$_nt" ]]; then echo "ℹ️ [알림] 시스템/팀원 메시지 — Skill('oi') 요구 대상 아님 (상태: ${_st})"
          else echo "💬 [oi] 알 수 없는 상태(${_st}) — Skill('oi') 호출 필수"; fi ;;
      esac
    fi
  fi
  [[ -n "$_UPS_SID" ]] && echo "🆔 [UUID] ${_UPS_SID}"
  return 0
}

# --- F-INTAUG-3 요구 표식 기록 (사이클174 — Skill('ointaug')/Skill('oi') 실제 호출 강제) ---
# PreToolUse_ointaug_turn_gate.sh 가 "요구 표식 mtime <= 호출 증표 mtime" 으로 판정한다.
# 증표(ointaug_invoked/oi_invoked)는 Skill 실행 직후 PostToolUse_Skill_ointaug_format.sh 가 쓴다.
# ★본문(_ups_main)이 아니라 여기서 동기로 쓴다★ — 본문은 예산 초과 시 hook 반환 뒤에도 백그라운드로 계속 돈다.
#   본문에서 쓰면 메인이 Skill('ointaug') 를 부른 ★뒤에★ 표식이 찍혀 정상 호출이 미충족으로 오판된다(재현 테스트 실측:
#   부하 구간에서 3회 중 2회 오판). 빌트인 printf 리다이렉션만 써서 포크·NTFS 읽기 없이 끝낸다.
# ★실제 사용자 입력만 요구한다★ — <teammate-message>·<task-notification> 으로 시작하는 프롬프트, 구조가 맞는 cross-session 통지, PIPELINE_UUID 보유 프로세스는 제외.
#   tmux 팀원 프로세스 판정(chain_agent)은 여기서 하지 않는다. 팀원 세션에 표식이 생겨도 턴 게이트가 팀원 프로세스를 통과시킨다.
#   /ox 는 o시리즈 바이패스이므로 이전 입력의 미충족 표식까지 지운다.
#   턴 진행 중 도착한 사용자 입력(queued)에도 이 hook 이 발동하므로 mid-turn 입력도 요구 대상이다(트랜스크립트 실측).
# --- 메인 pane 테두리 제목 갱신 (2026-10-16 사용자 버그 보고 '타이틀이 처음 그대로 재활용된다') ---
# tmux pane_title 은 Claude Code 가 첫 요청으로 만든 세션 제목(OSC)이라 요청이 바뀌어도 고정된다(tmux 실측 '✳ 남은 토큰 확인').
# 2026-10-16 후속 요구 '최신 명령이 아니라 작업 전체의 최종목표 같은 주제 단문으로' — @main_title 은 매 입력마다 덮어쓰지 않는다.
#   제목 = lib/main_work_title.sh 우선순위(work_title > 계획서 H1 > goal.json intent > 이번 사이클을 연 착수 요청 seed).
#   여기서는 (1) 이 입력이 새 작업 착수 요청이면 seed 기록(중간 지시·질문·짧은 응답은 무시 — 판정 규칙은 lib 주석)
#   (2) 우선순위로 계산한 값이 현재와 다를 때만 @main_title 갱신. 리드 Stop·팀원 상태 변화 때도 lib/main_pane_state.sh 가 재적용한다.
# lib/main_pane_state.sh 의 메인 테두리 형식이 pane_title 보다 @main_title 을 먼저 표시한다.
# 자기 pane 만 쓴다(세션 격리 (a)). 팀원 프로세스(부모 체인 --agent-id)는 건너뛴다. tmux 호출은 백그라운드라 hook 지연 없음.
_ups_main_title() {
  [[ "${TMUX_PANE:-}" =~ ^%[0-9]+$ ]] || return 0
  [[ -n "$_UPS_SDIR" && -d "$_UPS_SDIR" ]] || return 0
  local _t="$1" _pp="$PPID" _i _a _st _ss="" _sx=""
  for _i in 1 2 3; do   # 부모 체인 3단계에 --agent-id 가 있으면 팀원 → 건너뜀
    [[ "$_pp" =~ ^[0-9]+$ && "$_pp" -gt 1 ]] || break
    mapfile -d '' -t _a 2>/dev/null < "/proc/$_pp/cmdline" || break
    [[ " ${_a[*]} " == *" --agent-id "* ]] && return 0
    read -r _st 2>/dev/null < "/proc/$_pp/stat" || break
    _st="${_st##*) }"; _st="${_st#* }"; _pp="${_st%% *}"
  done
  _t="${_t//\\n/ }"; _t="${_t//\\r/ }"; _t="${_t//\\t/ }"; _t="${_t//\\\"/\"}"; _t="${_t//\\\\/\\}"
  while [[ "$_t" =~ \[Image\ \#[0-9]+\][[:space:]]* ]]; do _t="${_t/"${BASH_REMATCH[0]}"/}"; done
  while [[ "$_t" == *"  "* ]]; do _t="${_t//  / }"; done
  _t="${_t%\\}"; _t="${_t# }"; _t="${_t% }"   # 프롬프트 추출 정규식이 첫 \" 에서 끊겨 남는 꼬리 \ 제거
  [[ -z "$_t" ]] && return 0
  . "${BASH_SOURCE[0]%/*}/lib/main_work_title.sh" 2>/dev/null || return 0
  [[ -r "$_UPS_SDIR/state" ]] && read -r _ss _sx < "$_UPS_SDIR/state" 2>/dev/null
  main_work_title_seed "$_UPS_SDIR" "$_t" "$_ss"
  # 팀 없는(IDLE) 세션: 메인 형식(@main_border_ver, lib/main_pane_state.sh)이 아직 없으면 전역 형식(-g 는 읽기만)의
  #   #{pane_title} 을 @main_title 우선·pane_title 폴백으로 바꾼 사본을 자기 pane 에만(-p) 건다.
  #   팀이 생기면 main_pane_refresh 가 @main_border_ver 부재를 보고 m5 형식으로 덮어쓰므로 팀 형식이 우선한다.
  (
    main_work_title_apply "$_UPS_SDIR" "$TMUX_PANE"
    if [[ -z "$(tmux show -p -v -t "$TMUX_PANE" @main_border_ver 2>/dev/null)" ]]; then
      _g=$(tmux show -g -v pane-border-format 2>/dev/null)
      _f="${_g//'#{pane_title}'/'#{?@main_title,#{@main_title},#{pane_title}}'}"
      [[ "$_f" != "$_g" && "$_f" != "$(tmux show -p -v -t "$TMUX_PANE" pane-border-format 2>/dev/null)" ]] \
        && tmux set -p -t "$TMUX_PANE" pane-border-format "$_f"
    fi
  ) > /dev/null 2>&1 < /dev/null &
  return 0
}

_ups_require() {
  [[ -n "$_UPS_SDIR" && -d "$_UPS_SDIR" && -z "${PIPELINE_UUID:-}" ]] || return 0
  local _p="" _st="" _x="" _cls="" _oi=0
  [[ "$INPUT" =~ \"prompt\"[[:space:]]*:[[:space:]]*\"([^\"]*) ]] && _p="${BASH_REMATCH[1]}"
  while [[ "$_p" == [[:space:]]* || "$_p" == \\n* || "$_p" == \\t* ]]; do
    if [[ "$_p" == \\* ]]; then _p="${_p:2}"; else _p="${_p:1}"; fi
  done
  if [[ "$_p" =~ ^/([A-Za-z0-9_-]+:)? ]]; then _p="/${_p:${#BASH_REMATCH[0]}}"; fi  # 플러그인 접두사 정규화
  [[ -z "$_p" ]] && return 0
  # [사이클 가드 교착 §2-4] 어떤 프롬프트가 ointaug 표식을 갱신했는지 사후 판정용 진단. 분류는 아래 분기가 정한 값을 그대로 쓴다. 판정 로직과 무관하다.
  #   head=프롬프트 머리 60자. 자르기 전에 자격증명 값을 가린다(값이 60자 경계에 걸려도 일부가 남지 않게). 빌트인만 쓴다(mkdir 은 logs 부재 첫 입력 1회).
  _ups_ilog() {
    local _h="${_p:0:400}" _rx='(^|[^[:alnum:]])(sk-|gh[pousr]_|github_pat_|xox[baprs]-|(password|passwd|pwd|token|secret|api[_-]?key)[=:])[^[:space:]\\"*]+'
    _h="${_h//\\n/ }"; _h="${_h//\\t/ }"; _h="${_h%\\}"
    shopt -s nocasematch
    # 치환문은 따옴표로 감싼다 — bash 5.2 patsub_replacement 는 따옴표 없는 & 를 매치 전체로 펼쳐 가린 값을 되살린다
    while [[ "$_h" =~ $_rx ]]; do _h="${_h/"${BASH_REMATCH[0]}"/"${BASH_REMATCH[1]}${BASH_REMATCH[2]}***"}"; done
    shopt -u nocasematch
    [[ -d "$_UPS_SDIR/logs" ]] || mkdir -p "$_UPS_SDIR/logs" 2>/dev/null
    _ups_log intaug_required.log "class=$1 head=${_h:0:60}"
  }
  # ★[2026-10-17 oi-fix-1] 시스템 알림·팀원 메시지는 사용자 입력이 아니다★ — 본문/축약 경로가 ointaug 요구 문구를 내지 않도록
  #   _UPS_NOTIF 를 표시하고, F-INTAUG-1 기준점(last_prompt_epoch)도 갱신하지 않는다.
  #   실사고: 알림이 도착할 때마다 기준점이 밀려, 직전에 정상 호출한 ointaug 증표가 '기준점보다 과거'로 판정돼 TTL 600초 폴백에 의존했다.
  #   [2026-10-24 L-1362] 다른 세션의 cross-session 통지도 같다 — 단 접두가 아니라 구조(_ups_is_xsession)로 판정한다.
  if [[ "$_p" == "<teammate-message"* || "$_p" == "<task-notification"* ]] || _ups_is_xsession "$_p"; then
    _UPS_NOTIF=1
    _ups_ilog notif
    return 0
  fi
  # F-INTAUG-1 기준점(last_prompt_epoch)도 여기서 동기로 갱신한다 — 실제 사용자 입력(비어 있지 않은 프롬프트)만
  : > "$_UPS_SDIR/last_prompt_epoch" 2>/dev/null && _UPS_LPE_DONE=1
  _ups_main_title "$_p"
  # [F-OTEAM] 팀원 메시지·시스템 알림은 위에서 돌아갔으므로 여기는 사용자 입력뿐이다. 새 입력이 오면 지난 표식은 항상 사라진다(영구 정지 방지).
  rm -f "$_UPS_SDIR/oteam_required" "$_UPS_SDIR/oteam_spawned" "$_UPS_SDIR/oteam_stop_count" 2>/dev/null
  if [[ "$_p" =~ ^/oteam([[:space:]]|$) ]]; then
    _ot_arg="${_p#/oteam}"
    if [[ -n "${_ot_arg//[[:space:]]/}" ]]; then printf 'arg' > "$_UPS_SDIR/oteam_required" 2>/dev/null; else printf 'noarg' > "$_UPS_SDIR/oteam_required" 2>/dev/null; fi
  fi
  if [[ "$_p" =~ ^/ox([[:space:]]|\\|$) ]]; then
    [[ -e "$_UPS_SDIR/ointaug_required" || -e "$_UPS_SDIR/oi_required" ]] && rm -f "$_UPS_SDIR/ointaug_required" "$_UPS_SDIR/oi_required" 2>/dev/null
    _ups_ilog ox
    return 0
  fi
  printf '%s' "$EPOCHREALTIME" > "$_UPS_SDIR/ointaug_required" 2>/dev/null
  _ups_ilog user
  if [[ ! "$_p" =~ ^/[a-zA-Z][a-zA-Z0-9_-]*([[:space:]]|\\|$) ]]; then
    [[ -r "$_UPS_SDIR/state" ]] && read -r _st _x < "$_UPS_SDIR/state" 2>/dev/null
    [[ -r "$_UPS_SDIR/classification" ]] && read -r _cls < "$_UPS_SDIR/classification" 2>/dev/null
    case "$_st" in
      PLAN|DEV) [[ "$_st" == "PLAN" && "$_cls" == "OK" ]] || _oi=1 ;;
      TEST|DONE) _oi=1 ;;
      IDLE|""|FINISH|EARLY_TERM) ;;
      *) _oi=1 ;;
    esac
  fi
  if (( _oi )); then
    printf '%s' "$EPOCHREALTIME" > "$_UPS_SDIR/oi_required" 2>/dev/null
  elif [[ -e "$_UPS_SDIR/oi_required" ]]; then
    rm -f "$_UPS_SDIR/oi_required" 2>/dev/null
  fi
  return 0
}
_ups_require
_ups_mark require

# --- 등록 hook 실행 비트 quick 검사 (세션당 1회) ---
# 배경: SessionStart.sh 가 비트를 잃으면 SessionStart 검사가 돌지 못한다 → 별도 파일인 이 hook 이 보완한다.
# ★본문(_ups_main)의 IDLE 경로는 `_reset_idle; exit 0` 으로 일찍 끝나므로 본문 끝이 아니라 여기(동기, 본문 기동 전)에 둔다★
# 스탬프는 자기 session-env 에만 쓴다(격리 §(a)). 팀원(PIPELINE_UUID 보유)·session-env 부재는 건너뛴다.
# 검사기 부재·오류·초과는 조용히 통과(fail-open). timeout 1 로 예산(UPS-BUDGET)을 보호한다.
_ups_hec() {
  [[ -n "$_UPS_SDIR" && -d "$_UPS_SDIR" && -z "${PIPELINE_UUID:-}" ]] || return 0
  [[ -e "$_UPS_SDIR/hook_exec_checked" ]] && return 0
  : > "$_UPS_SDIR/hook_exec_checked" 2>/dev/null || return 0
  local _py="${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/hook_exec_check.py" _o=""
  [[ -f "$_py" ]] || return 0
  _o=$(timeout 1 python3 "$_py" --mode session --quick 2>/dev/null) || true
  [[ -n "$_o" ]] && printf '%s\n' "$_o"
  return 0
}
_ups_hec
_ups_mark hec

# 본문은 stdout/stderr 를 임시 파일로 돌려 Claude Code 의 파이프를 붙잡지 않게 한다(조기 exit 가능).
( trap _ups_body_exit EXIT; _ups_main ) > "$_UPS_OUT" 2> "${_UPS_OUT}.err" < /dev/null &
_UPS_BODY=$!
trap ':' USR1
( sleep "$_UPS_BUDGET"; kill -USR1 $$ ) > /dev/null 2>&1 < /dev/null &
_UPS_TIMER=$!
wait "$_UPS_BODY"; _UPS_RC=$?
if kill -0 "$_UPS_BODY" 2>/dev/null; then
  : > "${_UPS_OUT}.late"
fi
# .late 생성 직후 재확인 — 그 사이 본문이 끝났으면(trap 이 .late 를 못 봤을 수 있음) 정상 경로로 간다.
if [[ -e "${_UPS_OUT}.late" ]] && ! kill -0 "$_UPS_BODY" 2>/dev/null; then
  wait "$_UPS_BODY" 2>/dev/null; _UPS_RC=$?
  rm -f "${_UPS_OUT}.late" 2>/dev/null
fi
if [[ -e "${_UPS_OUT}.late" || ! -e "$_UPS_OUT" ]]; then
  # 예산 초과(또는 경합으로 본문 출력이 late 로그로 넘어간 경우) — 본문은 계속 돌게 두고(상태 기록 완료 보장) 축약 안내로 즉시 종료한다.
  _ups_fallback
  _ups_elapsed_ms; _ups_log ups_timing.log "total=${_UPS_EL}ms mode=fallback budget=${_UPS_BUDGET}s pid=$$"
  exit 0
fi
kill "$_UPS_TIMER" 2>/dev/null
while IFS= read -r _l || [[ -n "$_l" ]]; do printf '%s\n' "$_l"; done < "$_UPS_OUT"
while IFS= read -r _l || [[ -n "$_l" ]]; do printf '%s\n' "$_l" >&2; done < "${_UPS_OUT}.err"
rm -f "$_UPS_OUT" "${_UPS_OUT}.err" 2>/dev/null
_ups_elapsed_ms; _ups_log ups_timing.log "total=${_UPS_EL}ms mode=normal budget=${_UPS_BUDGET}s pid=$$"
exit "$_UPS_RC"
