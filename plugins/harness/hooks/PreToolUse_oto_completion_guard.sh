#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# oto 자율모드 세션이 미완료 작업을 남긴 채 IDLE로 종료하는 것을 물리 차단하는 hook
# PreToolUse:mcp__oio__session_state — key=state, value=IDLE 전이 시도만 검사
#
# 배경: /oto("질문 없이 끝까지 완주")가 완주 불가 항목 1건을 이유로 가능 항목까지
#       묶어 미루고 조용히 IDLE 종료한 사고. 문서 규칙으로는 막을 수 없어 물리 강제.
#
# 검사: F-OTO-1 goal.json 부재 / F-OTO-2 미충족 acceptance + next_action.json 부재
#       / F-OTO-3 blocked 항목 근거(blocked_reason·blocked_evidence) 누락
#
# 설계 원칙:
#   - auto 미설정 세션은 무조건 즉시 exit 0 (일반 파이프라인 무영향 — 최우선)
#   - 세션 격리 §(a): 자기 UUID 하위만 읽는다. 타 세션 무영향
#   - goal.json 파싱 실패는 fail-closed(block). 그 외 예외는 fail-open(통과)
#   - 비상 스위치: hooks/DISABLE_OTO_GUARD 존재 시 즉시 통과
#
# F-OTO-7 (사이클39): RALPH 게이트 사멸 차단.
#   사이클38 실사고 — oto가 oralph_active.json 을 만들었는데 ofinish는 확장자 없는
#   oralph_active 를 본다. 2순위 폴백이 원리적으로 매칭 불가 → RALPH_ACTIVE=false
#   → 검증 루프 통째로 스킵 → 이월 5건이 루프를 한 번도 못 돌았다.
# F-OTO-8 (사이클39): auto_script 부재 fail-open 차단.
#   acceptance 6건 중 auto_script 가 1건뿐이라 나머지 5건이 조용히 통과했다.
#   게이트가 사실상 1건짜리가 되어 locked=true 의 의미가 사라졌다.

INPUT=$(timeout 5 cat 2>/dev/null) || INPUT=""

_HOOK_DIR="$HOME/.claude/hooks"

# ── 0. 비상 스위치 (최우선 — 어떤 검사보다 먼저) ──────────────────────
[[ -f "${_HOOK_DIR}/DISABLE_OTO_GUARD" ]] && exit 0

# ── 1. 도구 입력 판별: key=state AND value=IDLE 전이만 대상 ───────────
# jq 부재/파싱 실패는 fail-open (그 외 예외 = 통과 원칙)
_KEY=$(echo "$INPUT" | jq -r '.tool_input.key // empty' 2>/dev/null) || exit 0
[[ "$_KEY" == "state" ]] || exit 0

_VALUE=$(echo "$INPUT" | jq -r '.tool_input.value // empty' 2>/dev/null) || exit 0
# value는 "IDLE" 또는 "IDLE <uuid>" 형태 모두 허용 (state 파일 포맷 대응)
case "$_VALUE" in
  IDLE|IDLE\ *) ;;
  *) exit 0 ;;
esac

# ── 2. 재진입 방지 ────────────────────────────────────────────────────
_STOP_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)
[[ "$_STOP_ACTIVE" == "true" ]] && exit 0

# ── 3. UUID 결정 ──────────────────────────────────────────────────────
# shellcheck source=/dev/null
source "${_HOOK_DIR}/lib/session_id.sh" 2>/dev/null || exit 0
resolve_uuid "$INPUT" 2>/dev/null || exit 0
[[ -z "${UUID:-}" ]] && exit 0

# 팀에이전트/서브에이전트는 대상 아님 (메인의 IDLE 전이만 검사)
if [[ -n "${PIPELINE_UUID:-}" && "${PIPELINE_UUID:-}" != "${MY_UUID:-$UUID}" ]]; then
  exit 0
fi

# ── 4. SESSION_DIR 결정 (+ cc-prefix 분리 폴백) ───────────────────────
# 배경: /tmp/cc-*/session-env/ 와 $HOME/.claude/session-env/ 가 동시 실존하며
#       내용이 갈리는 사고가 실측됨. auto 플래그가 있는 쪽을 정본으로 채택한다.
SESSION_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}"
HOME_SESSION_DIR="$HOME/.claude/session-env/${UUID}"

if [[ ! -f "${SESSION_DIR}/auto" && -f "${HOME_SESSION_DIR}/auto" ]]; then
  SESSION_DIR="${HOME_SESSION_DIR}"
  _PATH_FALLBACK=1
fi

# ── 5. auto 플래그 확인 — oto 세션이 아니면 무조건 통과 (최우선 원칙) ──
AUTO_FILE="${SESSION_DIR}/auto"
[[ -f "$AUTO_FILE" ]] || exit 0
_AUTO=$(tr -d '[:space:]' < "$AUTO_FILE" 2>/dev/null) || exit 0
[[ "$_AUTO" == "ON" ]] || exit 0

# ── 6. 진입 로그 (발동 여부를 사후에 알 수 있어야 한다) ────────────────
LOG_DIR="${SESSION_DIR}/logs"
LOG_FILE="${LOG_DIR}/oto_completion_guard.log"
mkdir -p "$LOG_DIR" 2>/dev/null
_log() {
  echo "$(date '+%Y-%m-%dT%H:%M:%S%z') $*" >> "$LOG_FILE" 2>/dev/null || true
}
_log "ENTER uuid=${UUID} auto=ON value=${_VALUE}${_PATH_FALLBACK:+ path_fallback=HOME}"

# block 출력 헬퍼 (JSON 이스케이프는 jq에 위임)
_block() {
  local _reason="$1"
  _log "BLOCK $2"
  jq -cn --arg r "$_reason" '{decision:"block", reason:$r}' 2>/dev/null \
    || echo '{"decision":"block","reason":"oto 완주 계약 위반 — 미완료 작업이 남아 있습니다."}'
  exit 2
}

# jq 없으면 검사 불가 → fail-open (그 외 예외 = 통과)
command -v jq >/dev/null 2>&1 || { _log "SKIP jq 부재 — fail-open"; exit 0; }

# ── 6b. F-OTO-7: RALPH 게이트 사멸 차단 (사이클39 — 최우선 검사) ────────
# 배치 근거: auto=ON 게이트(§5) 통과 후 + _block/_log 정의 후 + F-OTO-1 앞.
#   · §5 뒤여야 auto 미설정 세션에 절대 영향이 없다.
#   · F-OTO-1(goal.json 내용 검사)보다 앞이어야 한다 — RALPH 게이트가 죽어 있으면
#     검증 루프 자체가 한 번도 안 돌았다는 뜻이므로 goal.json 내용 판정보다 상위 결함이다.
# 검사: status 에 RALPH 없음 AND 확장자 없는 oralph_active 부재 → ofinish Step 8 이
#       RALPH_ACTIVE=false 로 떨어져 검증 루프를 통째로 건너뛴다.
ORALPH_FLAG="${SESSION_DIR}/oralph_active"
_RALPH_IN_STATUS=0
if [[ -f "${SESSION_DIR}/status" ]] \
   && grep -qE '(^|\|)RALPH(\||$)' "${SESSION_DIR}/status" 2>/dev/null; then
  _RALPH_IN_STATUS=1
fi

if [[ "$_RALPH_IN_STATUS" -eq 0 && ! -f "$ORALPH_FLAG" ]]; then
  if [[ -f "${ORALPH_FLAG}.json" ]]; then
    # (a) 파일명 어긋남 — 사이클38 실사고와 동일 형태
    _block "⛔ [F-OTO-7a] RALPH 게이트가 발동하지 않습니다 — 파일명이 어긋났습니다.
현재: oralph_active.json 이 존재합니다.
그러나 ofinish Step 8 은 확장자 없는 'oralph_active' 만 봅니다(ofinish/SKILL.md ORALPH_FLAG).
⇒ 2순위 폴백이 원리적으로 매칭되지 않아 RALPH_ACTIVE=false 로 떨어지고,
   검증 루프가 통째로 건너뛰어집니다. 이월 항목이 루프를 한 번도 못 돕니다(사이클38 실사고).

→ 해결: 파일명을 확장자 없는 'oralph_active' 로 맞추십시오.
   mcp__oio__file_move(src=\"${ORALPH_FLAG}.json\", dst=\"${ORALPH_FLAG}\")
   (또는 file_read 후 file_write 로 ${ORALPH_FLAG} 재작성)
→ 아울러 status 축에도 RALPH 를 등록하십시오(1순위 경로):
   source \\\"\\\${CLAUDE_CONFIG_DIR:-\\\$HOME/.claude}/hooks/lib/state_machine.sh\\\"; status_add \\\"${SESSION_DIR}/status\\\" RALPH
→ 비상 시: hooks/DISABLE_OTO_GUARD 파일 생성으로 우회 가능." "F-OTO-7a 파일명 어긋남 (oralph_active.json)"
  else
    # (b) 둘 다 없음 — oto 1_5 세팅 누락
    _block "⛔ [F-OTO-7b] auto=ON 인데 RALPH 게이트가 죽어 있습니다.
status 에 RALPH 토큰이 없고, oralph_active 파일도 없습니다.
⇒ ofinish Step 8 이 RALPH_ACTIVE=false 로 판정해 검증 루프를 통째로 건너뜁니다.
⇒ /oto 는 '검증 루프로 완주를 보장'하는 모드인데 그 루프가 아예 돌지 않은 상태입니다.

원인: oto Phase 1_5 의 oralph_active 세팅이 누락됐습니다(oto/SKILL.md 'oralph_active_세팅').
→ 해결: 두 가지를 모두 수행하십시오.
   (1) mcp__oio__file_write(path=\"${ORALPH_FLAG}\", content='{\"session_uuid\":...,\"criteria\":...,
       \"criteria_detail\":[...],\"max_iterations\":5,\"current_iteration\":0}', overwrite=true)
   (2) source \\\"\\\${CLAUDE_CONFIG_DIR:-\\\$HOME/.claude}/hooks/lib/state_machine.sh\\\"; status_add \\\"${SESSION_DIR}/status\\\" RALPH
→ 비상 시: hooks/DISABLE_OTO_GUARD 파일 생성으로 우회 가능." "F-OTO-7b RALPH 게이트 부재 (status·oralph_active 둘 다 없음)"
  fi
fi
_log "F-OTO-7 PASS ralph_in_status=${_RALPH_IN_STATUS} flag_exists=$([[ -f "$ORALPH_FLAG" ]] && echo 1 || echo 0)"

# ── 7. F-OTO-1: goal.json 부재 ────────────────────────────────────────
GOAL="${SESSION_DIR}/goal.json"
if [[ ! -f "$GOAL" ]]; then
  _block "⛔ [F-OTO-1] oto 세션인데 goal.json(완주 계약)이 없습니다.
/oto는 '질문 없이 끝까지 완주'를 계약하는 모드이므로 계약 문서 없이 종료할 수 없습니다.
→ oto 진입 시 Skill('goal')로 goal.json을 생성하십시오 (o4/o5는 oplan이 생성하지 않으므로 oto가 직접 생성).
→ 비상 시: hooks/DISABLE_OTO_GUARD 파일 생성으로 우회 가능." "F-OTO-1 goal.json 부재"
fi

# goal.json 파싱 실패 → fail-closed (block)
if ! jq -e . "$GOAL" >/dev/null 2>&1; then
  _block "⛔ [F-OTO-1p] goal.json 파싱 실패 — 완주 계약을 검증할 수 없습니다.
JSON 구문을 수정한 뒤 다시 종료하십시오. (파싱 실패는 fail-closed 정책으로 차단됩니다.)" "F-OTO-1p goal.json 파싱 실패"
fi

# ── 8. F-OTO-3: blocked 항목 근거 누락 ────────────────────────────────
# blocked_reason / blocked_evidence 가 비어 있으면 자의적 완주 포기로 간주
_BAD_BLOCKED=$(jq -r '
  [ (.acceptance // [])[]
    | select(.status == "blocked" or .status == "blocked_by")
    | select(((.blocked_reason // "") | length) == 0
             or ((.blocked_evidence // "") | length) == 0)
    | (.id // "?") ] | join(", ")
' "$GOAL" 2>/dev/null) || _BAD_BLOCKED=""

if [[ -n "$_BAD_BLOCKED" ]]; then
  _block "⛔ [F-OTO-3] blocked 항목에 근거가 없습니다: ${_BAD_BLOCKED}
완주 불가 선언에는 blocked_reason(열거값)과 blocked_evidence(실측 근거)가 모두 필요합니다.
'판단했다'는 근거가 아닙니다. 근거를 댈 수 없으면 그 항목은 완주 대상입니다." "F-OTO-3 blocked 근거 누락 ids=${_BAD_BLOCKED}"
fi

# ── 8b. F-OTO-4: blocked_reason 열거형 화이트리스트 검증 ───────────────
# 자유 서술 봉쇄. "사용자가 시점을 정해야 함" 류 위장 사유를 차단하는 실질 장치.
_ENUM='["타세션_프로세스_재시작_필요","사용자만_아는_값_필요","물리장비_외부인력_필요","도구_권한거부_로그_존재","선행_blocked_항목_의존"]'

_BAD_ENUM=$(jq -r --argjson enum "$_ENUM" '
  [ (.acceptance // [])[]
    | select(.status == "blocked" or .status == "blocked_by")
    | select((.blocked_reason // "") as $r | ($enum | index($r)) == null)
    | "\(.id // "?")(\(.blocked_reason // ""))" ] | join(", ")
' "$GOAL" 2>/dev/null) || _BAD_ENUM=""

if [[ -n "$_BAD_ENUM" ]]; then
  _block "⛔ [F-OTO-4] 허용되지 않은 blocked_reason 입니다: ${_BAD_ENUM}
완주 불가 사유는 아래 열거값만 인정합니다 (자유 서술 금지):
  · 타세션_프로세스_재시작_필요
  · 사용자만_아는_값_필요
  · 물리장비_외부인력_필요
  · 도구_권한거부_로그_존재
  · 선행_blocked_항목_의존   (전파 전용 — 직접 지정 금지)
'시간/토큰 부족' '위험해 보임' '사용자가 시점을 정해야 함' '다음 사이클이 적절함'
'다른 항목이 불가라 함께 미룸' 은 전부 사유가 아닙니다 — 해당 항목은 완주 대상입니다." "F-OTO-4 enum 위반 ${_BAD_ENUM}"
fi

# ── 8c. F-OTO-5: depends_on 참조 무결성 (오타·허위 기입 방지) ──────────
_BAD_DEP=$(jq -r '
  [ (.acceptance // [])[]?.id ] as $ids
  | [ (.acceptance // [])[] as $a
      | (($a.depends_on // [])[]) as $d
      | select(($ids | index($d)) == null)
      | "\($a.id // "?")→\($d)" ] | unique | join(", ")
' "$GOAL" 2>/dev/null) || _BAD_DEP=""

if [[ -n "$_BAD_DEP" ]]; then
  _block "⛔ [F-OTO-5] depends_on 이 존재하지 않는 항목을 참조합니다: ${_BAD_DEP}
의존 관계는 같은 goal.json 안의 실제 acceptance id 만 참조할 수 있습니다.
오타이면 수정하고, 없는 항목에 의존한다면 그 의존은 실재하지 않는 것입니다." "F-OTO-5 depends_on 참조 무결성 위반 ${_BAD_DEP}"
fi

# ── 8d. F-OTO-6: blocked_by 전파 근거 검증 (전파 위조 차단) ────────────
# status:"blocked_by" 는 depends_on 에 실제 blocked 항목이 있을 때만 성립한다.
_BAD_PROP=$(jq -r '
  [ (.acceptance // [])[] | select(.status == "blocked") | .id ] as $blocked
  | [ (.acceptance // [])[]
      | select(.status == "blocked_by")
      | select([ ((.depends_on // [])[]) | select(($blocked | index(.)) != null) ] | length == 0)
      | (.id // "?") ] | join(", ")
' "$GOAL" 2>/dev/null) || _BAD_PROP=""

if [[ -n "$_BAD_PROP" ]]; then
  _block "⛔ [F-OTO-6] 전파 근거 없는 blocked_by 입니다: ${_BAD_PROP}
status:\"blocked_by\" 는 depends_on 에 실제 status:\"blocked\" 항목이 있을 때만 성립합니다.
의존 관계를 위조해 완주 범위를 줄일 수 없습니다.
의존이 실재하지 않으면 그 항목은 status:\"open\" 이며 완주 대상입니다." "F-OTO-6 전파 위조 ids=${_BAD_PROP}"
fi

# ── 9. F-OTO-2: 미충족 acceptance + next_action.json 부재 ─────────────
# status != blocked/blocked_by 인 항목의 auto_script 를 전수 실행
_FAIL=0
_FAIL_IDS=""
_RAN=0
_NOSCRIPT_IDS=""

while IFS= read -r _ITEM; do
  [[ -z "$_ITEM" ]] && continue
  _SCRIPT=$(echo "$_ITEM" | jq -r '.auto_script // empty' 2>/dev/null)
  _ID=$(echo "$_ITEM" | jq -r '.id // "?"' 2>/dev/null)
  # F-OTO-8 (사이클39): auto_script 부재는 더 이상 조용히 통과시키지 않는다.
  # 종전 `continue` fail-open 때문에 acceptance 6건 중 5건이 무검사 통과했다(사이클38 실측).
  if [[ -z "$_SCRIPT" ]]; then
    _NOSCRIPT_IDS="${_NOSCRIPT_IDS}${_NOSCRIPT_IDS:+, }${_ID}"
    continue
  fi
  _RAN=$((_RAN + 1))
  # timeout으로 hook 정지 방지 (항목당 5초)
  if ! timeout 5 bash -c "$_SCRIPT" >/dev/null 2>&1; then
    _FAIL=$((_FAIL + 1))
    _FAIL_IDS="${_FAIL_IDS}${_FAIL_IDS:+, }${_ID}"
  fi
done < <(jq -c '(.acceptance // [])[] | select((.status // "open") != "blocked" and (.status // "open") != "blocked_by")' "$GOAL" 2>/dev/null)

_log "CHECK ran=${_RAN} fail=${_FAIL} ids=${_FAIL_IDS:-none} noscript=${_NOSCRIPT_IDS:-none}"

# ── 9b. F-OTO-8: auto_script 누락 항목 차단 (게이트 no-op 방지 — 사이클39) ──
# 배치 근거: F-OTO-2(미충족 판정)보다 앞. auto_script 가 없으면 그 항목은 애초에
#            판정 자체가 불가능하므로, "미충족 0건" 이라는 판정 결과를 신뢰할 수 없다.
if [[ -n "$_NOSCRIPT_IDS" ]]; then
  _block "⛔ [F-OTO-8] auto_script 없는 acceptance 항목이 있습니다: ${_NOSCRIPT_IDS}
이 항목들은 기계 판정이 불가능해 검사에서 제외됐습니다 (실행 ${_RAN}건 / 제외 항목 위 목록).
⇒ 게이트가 no-op 이 됩니다. locked=true 로 계약을 잠근 의미가 사라집니다.
   사이클38 실사고 — acceptance 6건 중 auto_script 가 1건뿐이라 5건이 무검사 통과했습니다.

→ 해결: 위 항목마다 auto_script 를 넣으십시오 (종료코드 0=충족, 그 외=미충족).
   예) \"auto_script\": \"grep -q 'F-OTO-7' /path/to/file\"
   예) \"auto_script\": \"test -f /path/to/artifact\"
→ 기계 판정이 정말 불가능한 항목이라면 status:\\\"blocked\\\" + blocked_reason(열거값)
   + blocked_evidence 로 등록하십시오 (F-OTO-3/4 가 근거를 검증합니다).
→ 비상 시: hooks/DISABLE_OTO_GUARD 파일 생성으로 우회 가능." "F-OTO-8 auto_script 누락 ids=${_NOSCRIPT_IDS}"
fi

if [[ "$_FAIL" -gt 0 ]]; then
  NEXT_ACTION="${SESSION_DIR}/next_action.json"
  if [[ -f "$NEXT_ACTION" ]]; then
    # autoloop이 이어받는다 → 통과
    _log "PASS 미충족 ${_FAIL}건이지만 next_action.json 존재 — autoloop 인계"
    exit 0
  fi
  _block "⛔ [F-OTO-2] 미충족 acceptance ${_FAIL}건이 남아 있는데 next_action.json이 없습니다: ${_FAIL_IDS}
선택지는 셋뿐입니다 —
  (1) 지금 완주하십시오. 가능한 항목을 미루는 것은 이탈입니다.
  (2) next_action.json을 작성해 다음 사이클에 인계하십시오 (slash_command는 \"/oto\").
  (3) 애초에 goal.json 생성 시 status:\"blocked\" + 근거로 등록했어야 합니다.
'다른 항목이 불가라서 함께 미룬다'는 사유가 되지 않습니다 — 의존하지 않는 항목은 완주 대상입니다.
조용한 종료는 없습니다." "F-OTO-2 미충족 ${_FAIL}건 + next_action 부재 ids=${_FAIL_IDS}"
fi

_log "PASS 전 항목 충족 (ran=${_RAN})"
exit 0
