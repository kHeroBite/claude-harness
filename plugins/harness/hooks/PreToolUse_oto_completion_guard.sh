#!/bin/bash
# oto 자율모드 세션이 미완료 작업을 남긴 채 IDLE로 종료하는 것을 물리 차단하는 hook
# PreToolUse:mcp__oio__session_state — key=state, value=IDLE 전이 시도만 검사
#
# 배경: /oto("질문 없이 끝까지 완주")가 완주 불가 항목 1건을 이유로 가능 항목까지
#       묶어 미루고 조용히 IDLE 종료한 사고. 문서 규칙으로는 막을 수 없어 물리 강제.
#
# 검사: F-OTO-1 goal.json 부재 / F-OTO-2 미충족 acceptance(FAIL·판정불가)가 남았는데 정직한 미완료 보고
#       (oto_incomplete.json — 상한·EARLY_TERM 도달)가 없음 / F-OTO-3 blocked 항목 근거 누락
#       / F-OTO-9 next_action.json 이 blocked 전용 인계(handoff_kind=blocked_only)가 아님
#
# [사이클182 항목8 — 사용자 지시 "oto모드일땐 모든 작업을 이번 사이클에서 마무리하고 다음 사이클로 넘기는 작업이 없도록 하라"]
#   F-OTO-2 를 반대 방향으로 바꿨다. 종전에는 next_action.json(다음 사이클 인계)이 있으면 open FAIL 이 남아도 통과했다.
#   지금은 인계를 통과로 인정하지 않는다. 남은 FAIL·판정불가가 있으면 다음을 모두 만족하는 oto_incomplete.json 만 통과한다.
#     {fail_ids, reason: max_iterations|early_term, iteration, max_iterations, detail}
#     · fail_ids ⊇ 지금 FAIL·판정불가 id 전부
#     · reason=max_iterations → oroof_active.current_iteration ≥ max_iterations (oroof_active 값 기준, 구 oralph_active 병기)
#     · reason=early_term     → session-env/<U>/reroute_count ≥ 20 (ok_pipeline EARLY_TERM 기준)
#   F-OTO-9: next_action.json 이 있으면 handoff_kind=blocked_only 이고 blocked_ids 가 전부 goal 의 blocked·blocked_by id 여야 한다
#     (write_guard F-OTO-9 가 쓰기 시점에, 이 가드가 IDLE 전이 시점에 같은 규칙을 본다).
#   잔존 한계(R5 정직 고지): current_iteration·reroute_count 는 메인이 쓰는 값이라 위조 가능성은 막지 못한다
#     (선언은 검증을 이길 수 없다 — L-467). 반복 기록(auto_decisions.jsonl)과의 사후 대조로 보완한다.
#
# [conv_179193178780 — 사용자 지시 "oto 에서 잔업 이월 허용, 사이클 종료마다 잔업 체크 후 있으면 무조건 진행"]
#   사이클182 의 "인계 불인정"을 다시 바꿨다. 잔여(FAIL·판정불가)가 있어도 아래 중 하나가 있으면 IDLE 전이를 통과시킨다.
#     ① next_action.json handoff_kind=carryover — carry_ids ⊇ 잔여 id, chain_root 비어있지 않음,
#        체인 사이클 수(logs/consumed_carryover_*.json 중 chain_root 일치 파일 수) < OTO_CYCLE_MAX(기본 5),
#        oroof_active.current_iteration ≥ 1 (oroof_active·구 oralph_active 모두 부재 → 차단)
#     ② oto_incomplete.json reason=early_term(reroute_count ≥ 20)
#     ③ oto_incomplete.json reason=cycle_cap(체인 소비 ≥ 상한) 또는 no_progress(최근 소비 2건 carry_ids == 현재 잔여)
#   reason=max_iterations 는 더 이상 종료 사유가 아니다(이월하라). 잔여 > 0 + 기록 없음은 계속 차단(사이클38 재발방지 유지).
#   F-OTO-9: next_action 은 blocked_only 또는 carryover(잔여 > 0 일 때만) 허용. 잔여 0 + carryover 는 차단.
#   F-OTO-10: plans/phase_batches.json 의 total_batches 가 current_phase_batch 보다 크면(잔여 batch) IDLE 차단.
#   잔존 한계: chain_root·current_iteration 은 메인이 쓰는 값이다(L-467). 소비 흔적 파일 수로 상한을 센다.
#
# 설계 원칙:
#   - auto 미설정 세션은 무조건 즉시 exit 0 (일반 파이프라인 무영향 — 최우선)
#   - 세션 격리 §(a): 자기 UUID 하위만 읽는다. 타 세션 무영향
#   - goal.json 파싱 실패는 fail-closed(block). 그 외 예외는 fail-open(통과)
#   - 비상 스위치: hooks/DISABLE_OTO_GUARD 존재 시 즉시 통과
#
# F-OTO-7 (사이클39): ROOF(구 RALPH) 게이트 사멸 차단.
#   사이클38 실사고 — oto가 oralph_active.json 을 만들었는데 ofinish는 확장자 없는
#   oralph_active 를 본다. 2순위 폴백이 원리적으로 매칭 불가 → RALPH_ACTIVE=false
#   → 검증 루프 통째로 스킵 → 이월 5건이 루프를 한 번도 못 돌았다.
# F-OTO-8 (사이클39): auto_script 부재 fail-open 차단.
#   acceptance 6건 중 auto_script 가 1건뿐이라 나머지 5건이 조용히 통과했다.
#   게이트가 사실상 1건짜리가 되어 locked=true 의 의미가 사라졌다.

INPUT=$(timeout 5 cat 2>/dev/null) || INPUT=""

_HOOK_DIR="${HARNESS_HOME:-$HOME/.harness}/current/hooks"

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

# ── 6b. F-OTO-7: ROOF 게이트 사멸 차단 (사이클39 — 최우선 검사) ────────
# 배치 근거: auto=ON 게이트(§5) 통과 후 + _block/_log 정의 후 + F-OTO-1 앞.
#   · §5 뒤여야 auto 미설정 세션에 절대 영향이 없다.
#   · F-OTO-1(goal.json 내용 검사)보다 앞이어야 한다 — ROOF 게이트가 죽어 있으면
#     검증 루프 자체가 한 번도 안 돌았다는 뜻이므로 goal.json 내용 판정보다 상위 결함이다.
# 검사: status 에 ROOF·RALPH 없음 AND 확장자 없는 oroof_active·oralph_active 부재 → ofinish Step 8 이
#       ROOF_ACTIVE=false 로 떨어져 검증 루프를 통째로 건너뛴다.
ROOF_FLAG="${SESSION_DIR}/oroof_active"
# ROOF-COMPAT(deprecation window 1주기 — 구 RALPH/oralph_active 인식 제거 예정)
[[ ! -f "$ROOF_FLAG" && -f "${SESSION_DIR}/oralph_active" ]] && ROOF_FLAG="${SESSION_DIR}/oralph_active"
_ROOF_IN_STATUS=0
# ROOF-COMPAT(deprecation window 1주기 — 구 RALPH/oralph_active 인식 제거 예정)
if [[ -f "${SESSION_DIR}/status" ]] \
   && grep -qE '(^|\|)(ROOF|RALPH)(\||$)' "${SESSION_DIR}/status" 2>/dev/null; then
  _ROOF_IN_STATUS=1
fi

if [[ "$_ROOF_IN_STATUS" -eq 0 && ! -f "$ROOF_FLAG" ]]; then
  # ROOF-COMPAT(deprecation window 1주기 — 구 RALPH/oralph_active 인식 제거 예정)
  if [[ -f "${SESSION_DIR}/oroof_active.json" || -f "${SESSION_DIR}/oralph_active.json" ]]; then
    # (a) 파일명 어긋남 — 사이클38 실사고와 동일 형태
    _block "⛔ [F-OTO-7a] ROOF 게이트가 발동하지 않습니다 — 파일명이 어긋났습니다.
현재: oroof_active.json(또는 구 oralph_active.json) 이 존재합니다.
그러나 ofinish Step 8 은 확장자 없는 'oroof_active' 를 봅니다(ofinish/SKILL.md Step 8).
⇒ 2순위 폴백이 원리적으로 매칭되지 않아 ROOF_ACTIVE=false 로 떨어지고,
   검증 루프가 통째로 건너뛰어집니다. 이월 항목이 루프를 한 번도 못 돕니다(사이클38 실사고).

→ 해결: 파일명을 확장자 없는 'oroof_active' 로 맞추십시오.
   mcp__oio__file_move(src=\"${SESSION_DIR}/oroof_active.json\", dst=\"${SESSION_DIR}/oroof_active\")
   (또는 file_read 후 file_write 로 ${SESSION_DIR}/oroof_active 재작성)
→ 아울러 status 축에도 ROOF 를 등록하십시오(1순위 경로):
   source \\\"\\\${HARNESS_HOME:-\\\$HOME/.harness}/current/hooks/lib/state_machine.sh\\\"; status_add \\\"${SESSION_DIR}/status\\\" ROOF
→ 비상 시: hooks/DISABLE_OTO_GUARD 파일 생성으로 우회 가능." "F-OTO-7a 파일명 어긋남 (oroof_active.json/oralph_active.json)"
  else
    # (b) 둘 다 없음 — oto 1_5 세팅 누락
    _block "⛔ [F-OTO-7b] auto=ON 인데 ROOF 게이트가 죽어 있습니다.
status 에 ROOF 토큰이 없고, oroof_active 파일도 없습니다.
⇒ ofinish Step 8 이 ROOF_ACTIVE=false 로 판정해 검증 루프를 통째로 건너뜁니다.
⇒ /oto 는 '검증 루프로 완주를 보장'하는 모드인데 그 루프가 아예 돌지 않은 상태입니다.

원인: oto Phase 1_5 의 oroof_active 세팅이 누락됐습니다(oto/SKILL.md 'oroof_active_세팅').
→ 해결: 두 가지를 모두 수행하십시오.
   (1) mcp__oio__file_write(path=\"${SESSION_DIR}/oroof_active\", content='{\"session_uuid\":...,\"criteria\":...,
       \"criteria_detail\":[...],\"max_iterations\":5,\"current_iteration\":0}', overwrite=true)
   (2) source \\\"\\\${HARNESS_HOME:-\\\$HOME/.harness}/current/hooks/lib/state_machine.sh\\\"; status_add \\\"${SESSION_DIR}/status\\\" ROOF
→ 비상 시: hooks/DISABLE_OTO_GUARD 파일 생성으로 우회 가능." "F-OTO-7b ROOF 게이트 부재 (status·oroof_active 둘 다 없음)"
  fi
fi
_log "F-OTO-7 PASS roof_in_status=${_ROOF_IN_STATUS} flag_exists=$([[ -f "$ROOF_FLAG" ]] && echo 1 || echo 0)"

# ── 7. F-OTO-1: goal.json 부재 ────────────────────────────────────────
GOAL="${SESSION_DIR}/goal.json"

# [GF-5 / 결함 5] ofinish 3c 는 goal.json 을 goal_{id}_completed.json 으로 보관(copy→unlock→delete)한 뒤 IDLE 전이한다.
#   그 시점 goal.json 은 이미 없어 F-OTO-1 이 정상 종료를 막는다. 좁은 대체 검증 경로:
#   이번 사이클(pipeline_start_time 이후 mtime)에 보관된 locked=true·goal_id==파일명 id 인 최신 1건을 GOAL 로 삼아
#   이후 모든 검사(F-OTO-2~9)를 그대로 수행한다. 후보 없음·이전 사이클·id 불일치·locked≠true·시작시각 판독불가는 종전대로 차단.
if [[ ! -f "$GOAL" ]]; then
  _PST=$(tr -d '[:space:]' < "${SESSION_DIR}/pipeline_start_time" 2>/dev/null) || _PST=""
  if [[ "$_PST" =~ ^[0-9]+$ ]]; then
    _ARCH_BEST=""; _ARCH_BEST_MT=0
    for _c in "${SESSION_DIR}"/goal_G-*_completed.json; do
      [[ -f "$_c" ]] || continue
      _cmt=$(stat -c %Y "$_c" 2>/dev/null) || continue
      [[ "$_cmt" =~ ^[0-9]+$ && "$_cmt" -ge "$_PST" ]] || continue
      _cid="${_c##*/goal_}"; _cid="${_cid%_completed.json}"
      jq -e --arg id "$_cid" '(.goal_id == $id) and (.locked == true)' "$_c" >/dev/null 2>&1 || continue
      if [[ "$_cmt" -ge "$_ARCH_BEST_MT" ]]; then _ARCH_BEST="$_c"; _ARCH_BEST_MT="$_cmt"; fi
    done
    if [[ -n "$_ARCH_BEST" ]]; then
      GOAL="$_ARCH_BEST"
      _log "F-OTO-1 대체검증 — goal.json 부재, 이번 사이클 보관본 사용: ${GOAL##*/}"
    fi
  fi
fi

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
# [사이클168] 실행은 공용 실행부(lib/goal_autoscript_run.sh)의 gas_eval 로만 한다(GOAL_SESSION_DIR 제공·
#   옛 세션 경로 재매핑·판정불가 구별). lib 부재·로드 실패 시 bash -c 폴백 없이 전부 판정불가(C1).
_GAS_OK=0
# shellcheck source=/dev/null
source "${_HOOK_DIR}/lib/goal_autoscript_run.sh" 2>/dev/null && declare -F gas_eval >/dev/null 2>&1 && _GAS_OK=1
[[ "$_GAS_OK" -eq 1 ]] || _log "WARN 공용 실행부 lib 부재/로드 실패 — auto_script 항목 전부 판정불가(UNDET), bash -c 폴백 없음"
GAS_GOAL_FILE="$GOAL"   # K1/D-9: 보관본(goal_*_completed.json)이어도 긴 항목은 기록으로 판정(export 금지)

_FAIL=0
_FAIL_IDS=""
_CANARY_OK=""
_UNDET=0
_UNDET_IDS=""
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
  # timeout으로 hook 정지 방지 (항목당 5초 — gas_eval 세 번째 인자)
  if [[ "$_GAS_OK" -eq 1 ]]; then
    gas_eval "$_SCRIPT" "$SESSION_DIR" 5
    _GRC=$?
  else
    _GRC=3
    GAS_DETAIL="공용 실행부 lib 부재/로드 실패"
  fi
  # 카나리(사이클195 역라우팅 #4): 기준표(plans/acceptance_criteria.json) gate_kind=canary + expected_result=FAIL 인
  #   항목은 FAIL 이 정상(미충족 아님), PASS 는 판정기 우회 의심(미충족). 기준표에 카나리가 없으면 _CEXP 가 비어 종전과 같다.
  _CEXP=""
  declare -F gas_canary_expected >/dev/null 2>&1 && _CEXP=$(gas_canary_expected "$_ID" "$SESSION_DIR" 2>/dev/null) || _CEXP=""
  case "$_GRC" in
    0)
      if [[ "$_CEXP" == "FAIL" ]]; then
        _FAIL=$((_FAIL + 1))
        _FAIL_IDS="${_FAIL_IDS}${_FAIL_IDS:+, }${_ID}(CANARY_VIOLATION: PASS≠expected FAIL)"
      fi
      ;;
    1)
      if [[ "$_CEXP" == "FAIL" ]]; then
        _CANARY_OK="${_CANARY_OK}${_CANARY_OK:+, }${_ID}"
      else
        _FAIL=$((_FAIL + 1))
        _FAIL_IDS="${_FAIL_IDS}${_FAIL_IDS:+, }${_ID}"
      fi
      ;;
    *)
      # D9: 판정불가는 FAIL 과 따로 센다 — 다음 사이클이 코드가 아니라 판정 스크립트·lib 를 고치도록
      _UNDET=$((_UNDET + 1))
      _UNDET_IDS="${_UNDET_IDS}${_UNDET_IDS:+, }${_ID}"
      _log "UNDET id=${_ID} 판정불가 — ${GAS_DETAIL}"
      ;;
  esac
done < <(jq -c '(.acceptance // [])[] | select((.status // "open") != "blocked" and (.status // "open") != "blocked_by")' "$GOAL" 2>/dev/null)

_log "CHECK ran=${_RAN} fail=${_FAIL} ids=${_FAIL_IDS:-none} undet=${_UNDET} undet_ids=${_UNDET_IDS:-none} noscript=${_NOSCRIPT_IDS:-none} canary_ok=${_CANARY_OK:-none}"

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

# [사이클168 D9] 판정불가(UNDET)도 FAIL 과 똑같이 "미충족"으로 센다. 단 출력·로그·안내에서 FAIL 과 구분 표기한다.
# [conv_179193178780] 잔업 이월 허용 — 잔여가 있어도 유효한 이어받기 기록(next_action.json handoff_kind=carryover)이 있으면 통과한다.
#   통과 경로는 셋뿐이다. ① carryover(carry_ids ⊇ 잔여 · 체인 사이클 수 < OTO_CYCLE_MAX · 검증 루프 current_iteration ≥ 1)
#   ② oto_incomplete reason=early_term ③ reason=cycle_cap / no_progress.  max_iterations 는 더 이상 종료 사유가 아니다(이월하라).
#   사이클 수는 메인 자기신고가 아니라 logs/consumed_carryover_*.json 소비 흔적 파일 수로 센다(L-467).
_OTO_CYCLE_MAX="${OTO_CYCLE_MAX:-5}"
_ALL_IDS="${_FAIL_IDS}${_FAIL_IDS:+${_UNDET_IDS:+, }}${_UNDET_IDS}"
NEXT_ACTION="${SESSION_DIR}/next_action.json"
if [[ "$_FAIL" -gt 0 || "$_UNDET" -gt 0 ]]; then
  INCOMPLETE="${SESSION_DIR}/oto_incomplete.json"
  _INC_WHY=$(IDS="$_ALL_IDS" ORA="$ROOF_FLAG" RRC="${SESSION_DIR}/reroute_count" SDIR="$SESSION_DIR" CAP="$_OTO_CYCLE_MAX" \
    NA="$NEXT_ACTION" INC="$INCOMPLETE" timeout 5 python3 -c '
import json,os,sys,glob
def out(m):
    print(m); sys.exit(0)
def jl(p):
    try:
        return json.load(open(p,encoding="utf-8"))
    except Exception:
        return None
try:
    need=[x.strip() for x in os.environ.get("IDS","").split(",") if x.strip()]
    sd=os.environ["SDIR"]; cap=int(os.environ.get("CAP","5") or 5)
    na=jl(os.environ["NA"]) if os.path.isfile(os.environ["NA"]) else None
    inc=jl(os.environ["INC"]) if os.path.isfile(os.environ["INC"]) else None
    # 체인 판정: 검사 대상 기록의 chain_root, 없으면 oto_chain_root 파일
    root=""
    for src in (na,inc):
        if isinstance(src,dict) and isinstance(src.get("chain_root"),str) and src["chain_root"].strip():
            root=src["chain_root"].strip(); break
    if not root:
        try: root=open(os.path.join(sd,"oto_chain_root"),encoding="utf-8").read().strip()
        except Exception: root=""
    cons=[]
    for p in sorted(glob.glob(os.path.join(sd,"logs","consumed_carryover_*.json"))):
        d=jl(p)
        if isinstance(d,dict) and (not root or d.get("chain_root")==root):
            cons.append(d)
    n=len(cons)
    why=[]
    # ① carryover
    if isinstance(na,dict) and na.get("handoff_kind")=="carryover":
        ids=na.get("carry_ids")
        if not isinstance(ids,list) or not ids or not all(isinstance(x,str) and x for x in ids):
            why.append("carryover 의 carry_ids 가 비었거나 형식 오류")
        elif not isinstance(na.get("chain_root"),str) or not na["chain_root"].strip():
            why.append("carryover 의 chain_root 가 비었다")
        else:
            miss=[x for x in need if x not in ids]
            if miss:
                why.append("carryover 의 carry_ids 가 지금 FAIL·판정불가 id %s 를 빠뜨렸다" % ",".join(miss))
            elif n>=cap:
                why.append("cycle_cap 도달(체인 소비 %d건 >= 상한 %d) — 이월 불가. next_action.json(carryover) 삭제 → oto_incomplete.json(reason=cycle_cap) 작성 → IDLE 순서로 보고하라" % (n,cap))
            else:
                o=jl(os.environ["ORA"])
                if o is None: o=jl(os.environ["ORA"]+".json")
                # ROOF-COMPAT(deprecation window 1주기 — 구 RALPH/oralph_active 인식 제거 예정)
                if o is None: o=jl(os.path.join(sd,"oralph_active.json"))
                try:
                    cur=int(o.get("current_iteration"))
                except Exception:
                    cur=None
                if cur is None:
                    why.append("carryover 인데 oroof_active 의 current_iteration 을 읽을 수 없다(부재) — 이월 전에 검증 루프가 돌았음을 증명할 수 없다")
                elif cur<1:
                    why.append("carryover 인데 oroof_active.current_iteration=%d — 이월 전에 FINISH→DEV 재진입을 1회 이상 수행하라" % cur)
                else:
                    out("OK:carryover")
    elif isinstance(na,dict) and na.get("handoff_kind")!="blocked_only":
        pass
    # ②③ oto_incomplete
    if inc is not None:
        d=inc
        if not isinstance(d,dict): why.append("oto_incomplete.json 이 객체가 아니다")
        else:
            bad=None
            for k in ("fail_ids","reason","iteration","max_iterations","detail"):
                if k not in d: bad="필드 %s 누락 — 형식 {fail_ids, reason, iteration, max_iterations, detail}" % k; break
            if bad is None:
                f=d["fail_ids"]
                if not isinstance(f,list) or not all(isinstance(x,str) for x in f): bad="fail_ids 가 문자열 배열이 아니다"
                elif not isinstance(d["detail"],str) or not d["detail"].strip(): bad="detail 이 비었다(항목별 남은 원인을 적는다)"
                else:
                    miss=[x for x in need if x not in f]
                    if miss: bad="fail_ids 가 지금 FAIL·판정불가 id %s 를 빠뜨렸다" % ",".join(miss)
            if bad: why.append(bad)
            else:
                r=d["reason"]
                if r=="early_term":
                    try: rc=int(open(os.environ["RRC"],encoding="utf-8").read().split()[0])
                    except Exception: rc=None
                    if rc is None: why.append("reason=early_term 인데 reroute_count 를 읽을 수 없다")
                    elif rc<20: why.append("EARLY_TERM 미도달(reroute_count=%d < 20) — 역라우팅을 계속해야 한다" % rc)
                    else: out("OK:early_term")
                elif r=="cycle_cap":
                    if n>=cap: out("OK:cycle_cap")
                    why.append("cycle_cap 미도달(체인 소비 %d건 < 상한 %d) — 이월(carryover)하라" % (n,cap))
                elif r=="no_progress":
                    if n>=2:
                        cur=set(need)
                        last=[set(c.get("carry_ids") or []) for c in cons[-2:]]
                        if all(s==cur for s in last): out("OK:no_progress")
                        why.append("진전 없음 미성립 — 최근 소비 2건의 carry_ids 집합이 지금 잔여 집합과 같지 않다(이월 계속)")
                    else:
                        why.append("no_progress 는 같은 체인 소비 2건 이상이 필요하다(현재 %d건)" % n)
                elif r=="max_iterations":
                    why.append("reason=max_iterations 는 더 이상 종료 사유가 아니다 — 잔여는 carryover 로 이월하라")
                else:
                    why.append("reason=%s — early_term / cycle_cap / no_progress 만 허용" % r)
    if not why:
        why.append("유효한 이어받기 기록(next_action.json carryover) 도 oto_incomplete.json 도 없다")
    out(" / ".join(why))
except SystemExit:
    raise
except Exception as e:
    out("판정 오류 %s" % type(e).__name__)
' 2>/dev/null) || _INC_WHY="판정 실패(시간 초과·python 부재)"
  if [[ "$_INC_WHY" == OK:carryover ]]; then
    _log "PASS-CARRYOVER fail=${_FAIL}(${_FAIL_IDS:-none}) undet=${_UNDET}(${_UNDET_IDS:-none}) — 잔업 이월(next_action carryover)"
    echo "🔁 잔업 이월 — 남은 FAIL ${_FAIL}건(${_FAIL_IDS:-없음}) · 판정불가 ${_UNDET}건(${_UNDET_IDS:-없음}). 사용자 입력 없이 즉시 next_action.json 의 /oto 를 실행하십시오(Stop_oto_residual_guard 가 턴 종료를 막습니다)."
  elif [[ "$_INC_WHY" == OK:* ]]; then
    _log "PASS-INCOMPLETE(${_INC_WHY#OK:}) fail=${_FAIL}(${_FAIL_IDS:-none}) undet=${_UNDET}(${_UNDET_IDS:-none}) — 정직한 미완료 보고(oto_incomplete.json)"
    echo "⚠️ [oto] 미완료(${_INC_WHY#OK:}) — 남은 FAIL ${_FAIL}건(${_FAIL_IDS:-없음}) · 판정불가 ${_UNDET}건(${_UNDET_IDS:-없음}). oto_incomplete.json 사유·원인을 그대로 보고하십시오."
  else
    _block "⛔ [F-OTO-2] 미충족 acceptance 가 남아 있고 이어받기 기록이 없습니다 — 조용히 끝낼 수 없습니다.
  미충족 FAIL ${_FAIL}건: ${_FAIL_IDS:-없음}
  판정불가(UNDET) ${_UNDET}건: ${_UNDET_IDS:-없음}   ← 판정 스크립트/lib 부재 — PASS 도 FAIL 도 아닙니다
  통과 불인정 사유: ${_INC_WHY}
선택지는 셋입니다 —
  (1) 지금 이번 사이클 안에서 완주하십시오(FINISH→DEV 재진입). 판정불가는 코드가 아니라 판정 스크립트/lib 를 복원합니다.
  (2) 이번 사이클에서 못 끝낸 잔여는 다음 사이클로 이월하십시오. ${NEXT_ACTION} 에
      {slash_command:\"/oto\", task_description, reason, handoff_kind:\"carryover\", chain_root, carry_ids:[위 FAIL·판정불가 id 전부]} 를 쓰십시오.
      (검증 루프를 1회 이상 돈 뒤여야 하며, 체인 사이클 상한 ${_OTO_CYCLE_MAX}회까지입니다.)
  (3) 상한 EARLY_TERM(reroute_count ≥ 20) / cycle_cap / no_progress(진전 없음)에 실제로 닿았을 때만
      ${INCOMPLETE} 에 {fail_ids(위 id 전부), reason: early_term|cycle_cap|no_progress, iteration, max_iterations, detail} 을 쓰고 '미완료'를 정직하게 보고하십시오.
      완주 불가 사유가 외부 사실이면 goal 생성 시 status:\"blocked\" + 근거로 등록했어야 합니다. max_iterations 도달은 종료 사유가 아닙니다(이월하라).
조용한 종료는 없습니다." "F-OTO-2 미충족 fail=${_FAIL}(${_FAIL_IDS:-none}) undet=${_UNDET}(${_UNDET_IDS:-none}) incomplete=${_INC_WHY}"
  fi
fi

# ── 9c. F-OTO-9: next_action.json 은 blocked 전용 인계 또는 유효 carryover 만 (write_guard F-OTO-9 와 같은 규칙) ──
if [[ -f "$NEXT_ACTION" ]]; then
  _NA_WHY=$(GOAL="$GOAL" RES="$(( _FAIL + _UNDET ))" timeout 5 python3 -c '
import json,os,sys
def out(m):
    print(m); sys.exit(0)
try:
    try:
        na=json.load(open(sys.argv[1],encoding="utf-8"))
    except Exception:
        out("next_action.json 이 유효 JSON 이 아니다")
    if not isinstance(na,dict): out("next_action.json 이 객체가 아니다")
    k=na.get("handoff_kind")
    if k=="carryover":
        # 잔여가 있으면 9 단계가 이미 carry_ids·상한·루프 횟수를 판정했다. 잔여가 0 이면 이월할 것이 없다.
        if int(os.environ.get("RES","0"))>0: out("OK")
        out("carryover 인데 이월할 잔여(FAIL·판정불가)가 없다 — next_action.json 을 삭제하라")
    if k!="blocked_only": out("handoff_kind 가 blocked_only 도 carryover 도 아니다(open 작업 인계)")
    b=na.get("blocked_ids")
    if not isinstance(b,list) or not b or not all(isinstance(x,str) and x for x in b): out("blocked_ids 가 비었거나 형식 오류")
    g=json.load(open(os.environ["GOAL"],encoding="utf-8"))
    ok=set(a.get("id") for a in (g.get("acceptance") or []) if isinstance(a,dict) and a.get("status") in ("blocked","blocked_by"))
    bad=[x for x in b if x not in ok]
    if bad: out("blocked_ids %s 는 goal 의 blocked·blocked_by 항목이 아니다" % ",".join(bad))
    out("OK")
except SystemExit:
    raise
except Exception as e:
    out("판정 오류 %s" % type(e).__name__)
' "$NEXT_ACTION" 2>/dev/null) || _NA_WHY="판정 실패(시간 초과·python 부재)"
  if [[ "$_NA_WHY" != "OK" ]]; then
    _block "⛔ [F-OTO-9] oto(auto=ON) 세션의 next_action.json 이 인정되지 않습니다 — ${_NA_WHY}.
허용 형식은 둘입니다. (a) blocked 인계: {\"slash_command\":\"/oto\",\"task_description\":…,\"reason\":…,\"handoff_kind\":\"blocked_only\",\"blocked_ids\":[goal 의 blocked·blocked_by id]}
(b) 잔업 이월: {\"slash_command\":\"/oto\",\"task_description\":…,\"reason\":…,\"handoff_kind\":\"carryover\",\"chain_root\":…,\"carry_ids\":[남은 FAIL·판정불가 id]} — 잔여가 있을 때만.
그 밖의 인계(handoff_kind 없음·잔여 0 인데 carryover)는 인정되지 않습니다. 인계가 필요 없으면 next_action.json 을 지우십시오." \
      "F-OTO-9 next_action 불인정 인계 — ${_NA_WHY}"
  fi
  _log "F-OTO-9 PASS 인계(blocked_only|carryover)"
fi

# ── 9d. F-OTO-10: 잔여 phase batch 가 있으면 IDLE 차단 (사이클 종료 시 잔업 체크) ──
_PB="${SESSION_DIR}/plans/phase_batches.json"
if [[ -f "$_PB" ]]; then
  _PB_TOTAL=$(jq -r '.total_batches // 0' "$_PB" 2>/dev/null) || _PB_TOTAL=0
  _PB_CUR=$(tr -d '[:space:]' < "${SESSION_DIR}/current_phase_batch" 2>/dev/null) || _PB_CUR=""
  [[ "$_PB_TOTAL" =~ ^[0-9]+$ ]] || _PB_TOTAL=0
  [[ "$_PB_CUR" =~ ^[0-9]+$ ]] || _PB_CUR=1
  if [[ "$_PB_CUR" -lt "$_PB_TOTAL" ]]; then
    _block "⛔ [F-OTO-10] 잔여 phase batch 가 있습니다 — 현재 ${_PB_CUR}/${_PB_TOTAL}.
oto 는 사이클 종료마다 잔업을 체크하고 있으면 무조건 진행합니다. 다음 batch 를 진행한 뒤 종료하십시오(ok_pipeline 4.5 Phase Batch Auto-Loop).
→ 비상 시: hooks/DISABLE_OTO_GUARD 파일 생성으로 우회 가능." "F-OTO-10 잔여 phase batch ${_PB_CUR}/${_PB_TOTAL}"
  fi
fi

_log "PASS (ran=${_RAN} fail=${_FAIL} undet=${_UNDET})"
exit 0
