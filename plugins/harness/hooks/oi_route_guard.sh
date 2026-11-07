#!/bin/bash
# oi_route_guard.sh — PreToolUse:Skill hook
# 목적: PLAN/DEV/TEST/DONE 상태에서 oi 미경유 스킬 호출 물리 차단
# 트리거: PreToolUse:Skill
#
# 설계:
#   UserPromptSubmit.sh가 PLAN/DEV/TEST/DONE 상태에서 "💬 [oi] 활성" 메시지로 Skill('oi') 호출을 요청.
#   oi가 실행되면 oi_routed 마커를 생성 → 이후 스킬은 통과.
#   oi 없이 다른 스킬을 호출하면 이 hook이 차단.
#
# 예외 (차단 제외):
#   oi, ox, ostatus, ofinish*, oinit, ocontext — 직접 허용 스킬
#   슬래시 명령 바이패스 스킬 (skill_direct 파일 있음)
#   팀에이전트/서브에이전트

trap 'exit 0' ERR
INPUT=$(timeout 5 cat 2>/dev/null) || INPUT=""
SKILL_NAME=$(echo "$INPUT" | jq -r '(.tool_input.skill // .tool_input.skill_name // empty)' 2>/dev/null)
SKILL_NAME="${SKILL_NAME##*:}"

[[ -z "$SKILL_NAME" ]] && exit 0

# UUID 결정
source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/session_id.sh"
source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/state_machine.sh" 2>/dev/null || true
resolve_uuid "$INPUT" || exit 0
[[ -z "$UUID" ]] && exit 0

# 팀에이전트/서브에이전트 스킵
if [[ -n "${PIPELINE_UUID:-}" && "${PIPELINE_UUID:-}" != "$MY_UUID" ]] || \
   [[ "$MY_UUID" != "$UUID" ]]; then
  exit 0
fi

SESSION_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}"

# (사이클174: oi_routed 삭제·미러 로직은 oi_invoked 증표 판정으로 대체되어 제거했다 — 증표는 hook 소유라 지우지 않는다)

# state 없는 UUID는 서브에이전트 확정 → 스킵
[[ -f "${SESSION_DIR}/state" ]] || exit 0

# F6: state_read 경유 (flock 보호). __LOCK_FAIL__ 시 skip 처리.
CURRENT_STATE=$(state_read "${SESSION_DIR}/state" 2>/dev/null | awk '{print $1}' | tr -d '\r')
[[ "$CURRENT_STATE" == "__LOCK_FAIL__" ]] && exit 0  # lock 경쟁 시 guard skip (차단 보수)
STATUS_FILE="${SESSION_DIR}/status"

# PLAN/DEV/TEST/DONE 상태에서만 적용
case "$CURRENT_STATE" in
  PLAN|DEV|TEST|DONE)
    # status=PAUSE 면 oi 우회 허용 (일시정지 상태에서 직접 스킬 허용)
    if status_has "$STATUS_FILE" PAUSE 2>/dev/null; then
      exit 0
    fi
    ;;
  *) exit 0 ;;
esac

# 직접 허용 스킬 목록 (oi 라우팅 바이패스)
# ok 흐름 정식 단계 (ok_pipeline/ofinish/oinit)는 oi 경유 부적절 — 화이트리스트에 포함 (Phase A 보강 — 2026-05-06)
# ok_pipeline: ok 흐름 정식 단계 (oplan 완료 후 odev/otest/odone 오케스트레이션)
# ofinish: ok 흐름 마무리 단계 (ofinish*로 wildcard 매칭)
# oinit: 정리 (ofinish 내부 호출)
# ointaug: CLAUDE.md 절대 규칙 — 모든 입력의 첫 번째 행동 (PLAN 잔재 시 차단 회귀 방지)
# ok / ox / o1~o5 / oroof: 슬래시 명령 자체 — false positive 방지
# L-435: 화이트리스트 누락 시 oi 라우팅이 정상 슬래시 명령을 차단하는 회귀 방지 — 아래 case 목록 유지
case "$SKILL_NAME" in
  oi|ox|o1|o2|o3|o4|o5|ok|ointaug|ostatus|ofinish*|ocontext|oresume|odebug|oinit|oss|oinsights|oretro|oroof|ok_pipeline|oteam)
    exit 0
    ;;
esac

# goal 예외: /oto 첫 명령(state=PLAN, classification=OK, auto 플래그)에서 목표계약 세팅용 Skill('goal') 허용
# (oto/SKILL.md 1_5 단계). 그 외(auto 없음·DEV/TEST/DONE·O1~O5)는 아래 기존 판정으로 계속 차단.
if [[ "$SKILL_NAME" == "goal" && "$CURRENT_STATE" == "PLAN" && -f "${SESSION_DIR}/auto" ]]; then
  _GOAL_CLS=$(tr -d '[:space:]' < "${SESSION_DIR}/classification" 2>/dev/null || true)
  [[ "$_GOAL_CLS" == "OK" ]] && exit 0
fi

# 슬래시 명령 직접 호출 (skill_direct 있음) → 바이패스
if [[ -f "${SESSION_DIR}/skill_direct" ]]; then
  DIRECT_SKILL=$(cat "${SESSION_DIR}/skill_direct" 2>/dev/null)
  if [[ "$DIRECT_SKILL" == "$SKILL_NAME" ]]; then
    exit 0
  fi
fi

# ★[2026-10-10 사이클174 F-INTAUG-3] 판정 대상을 oi_routed(본문 epoch, TTL 10초) → oi_invoked(hook 증표 mtime)로 교체★
#   실사고: oi_routed 는 oi 스킬 문서 절차상 메인이 직접 file_write 로 쓰는 파일이었다. 메인이 Skill('oi') 없이
#   oi_routed 만 쓰면 이 가드를 통과했다(본문 epoch 도 자기신고 — L-467).
#   oi_invoked 는 PostToolUse_Skill_ointaug_format.sh 가 Skill('oi') 실행 직후에만 쓰고, 메인의 쓰기는
#   PreToolUse_ointaug_turn_gate.sh 가 막는다. 판정 기준점: oi_required(UserPromptSubmit 이 실제 사용자 입력 시 동기로 기록)
#   → 없으면 last_prompt_epoch. 증표 mtime >= 기준점이면 통과. 기준점이 둘 다 없거나 증표가 그보다 오래됐어도
#   증표 생성 후 10초 이내면 통과한다(종전 TTL 과 같은 폭 — 팀원 메시지 턴처럼 기준점이 갱신되지 않는 경우의 하위호환).
# ★ 판정 정렬(UserPromptSubmit 과 동일 기준) ★ : UPS 는 슬래시 입력이면 oi_required 를 만들지 않거나 지우고 "oi 바이패스"를 안내한다.
#   lib 판정이 0/1 이면 oi_required 대 oi_invoked 만으로 정한다. 단 classification=OK(PLAN+OK 는 UPS 가 비슬래시 입력에도 oi_required 를
#   만들지 않는 구간)는 UPS 판정이 요구 없음을 뜻하지 않으므로 약화 방지를 위해 아래 기존 판정을 유지한다. rc 2, lib 부재도 기존 판정.
_OI_ALIGN=""
_OI_CLS=$(tr -d '[:space:]' < "${SESSION_DIR}/classification" 2>/dev/null || true)
if [[ "$_OI_CLS" != "OK" ]] && source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/skill_order.sh" 2>/dev/null; then
  skill_order_oi_needed "$SESSION_DIR" && _OI_ALIGN=0 || _OI_ALIGN=$?   # ERR trap 회피
  [[ "$_OI_ALIGN" == "1" ]] && exit 0
fi
_OI_PRF="${SESSION_DIR}/oi_invoked"
if [[ "$_OI_ALIGN" != "0" && -f "$_OI_PRF" ]]; then
  _OI_P=$(stat -c %.9Y "$_OI_PRF" 2>/dev/null); _OI_P="${_OI_P/./}"
  _OI_B=""
  for _OI_BF in "${SESSION_DIR}/oi_required" "${SESSION_DIR}/last_prompt_epoch"; do
    [[ -f "$_OI_BF" ]] || continue
    _OI_B=$(stat -c %.9Y "$_OI_BF" 2>/dev/null); _OI_B="${_OI_B/./}"
    break
  done
  if [[ "$_OI_P" =~ ^[0-9]+$ ]]; then
    if [[ "$_OI_B" =~ ^[0-9]+$ ]] && (( _OI_P >= _OI_B )); then
      exit 0
    fi
    _OI_NOW=$(date +%s%N)
    (( _OI_NOW - _OI_P < 10000000000 )) && exit 0
  fi
fi

# PLAN/DEV/TEST/DONE 상태에서 oi 미경유 스킬 차단
_OI_HINT=""
if declare -F skill_order_hint >/dev/null 2>&1; then
  _OI_HINT=$(skill_order_hint "$SESSION_DIR" "Skill('${SKILL_NAME}')" 2>/dev/null)
else
  source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/skill_order.sh" 2>/dev/null && _OI_HINT=$(skill_order_hint "$SESSION_DIR" "Skill('${SKILL_NAME}')" 2>/dev/null)
fi
_OI_HINT="${_OI_HINT//\"/}"
if [[ -n "$_OI_HINT" ]]; then
  echo "{\"decision\":\"block\",\"reason\":\"🚫 [oi_route_guard] PLAN/DEV/TEST/DONE 상태에서 Skill('oi') 없이 '${SKILL_NAME}' 직접 호출 차단. ${_OI_HINT}\"}"
  exit 2
fi
echo "{\"decision\":\"block\",\"reason\":\"🚫 [oi_route_guard] PLAN/DEV/TEST/DONE 상태에서 Skill('oi') 없이 '${SKILL_NAME}' 직접 호출 차단. Skill('oi')를 먼저 호출하여 입력을 분류하세요.\"}"
exit 2
