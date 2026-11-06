#!/bin/bash
# DONE 진입 시점에 auto(oto)/ROOF(oroof) 세션의 잔여 계약 항목을 확인하는 hook
# PreToolUse:mcp__oio__session_state — key=state, value=DONE 전이 시도만 검사
#
# 배경: 사용자 요청 — "done단계 진입할때 auto나 ralph인지를 체크하고 그 조건에
#       맞게 작업이 완료되어서 남은작업이 없는지를 확인하고, 만약 남은작업이
#       있다면 다시 plan단계로 되돌려서 마무리 될수있도록" (2026-08-29).
#       기존 PreToolUse_oto_completion_guard.sh(F-OTO-1~8)는 FINISH→IDLE 전이
#       시점(ofinish 완료 후)에만 검사한다. 본 hook은 그보다 이른 DONE 진입
#       시점(odone spawn 직전)에 동일 계약을 선제 검사하여, odone(교훈수집/
#       정리/git커밋)이 불필요하게 실행되기 전에 잔여 작업을 잡는다.
#
# 설계 원칙 (F-OTO 계열과 동일):
#   - auto=ON 또는 status에 ROOF 없는 세션은 무조건 즉시 exit 0 (일반 파이프라인 무영향 — 최우선)
#     [r3 Hc1 2026-09-29] 대상에 classification ∈ {O4,O5} 추가. goal 부재·파싱 실패·unlocked 는
#     fail-open 대신 필수 마커(otest_done·UI 마커 v2) 검사로 대체한다(L9 — r2 FAIL-OPEN 3회 사고).
#     jq 부재 fail-open·max_iterations fail-open(auto_script 판정 한정)은 유지.
#   - 세션 격리 §(a): 자기 UUID 하위만 읽는다. 타 세션 무영향
#   - 이 게이트는 F-OTO 계열(최종 방어선)의 "추가 안전망"이므로 판정 불가/예외는
#     전부 fail-open(통과) — 단, 모든 fail-open 분기에 로그를 남긴다(추적 가능성 확보)
#   - blocked/blocked_by 항목은 fail로 세지 않는다 (oto/goal 계약과 동일 원칙 — 세면 루프가 안 끝난다)
#   - 판정 가능 범위는 auto_script가 있는 open 항목뿐 — criteria_detail(자연어)은
#     hook이 판정할 수 없다(otest_verify 스킬 절차가 담당). hook은 최종 안전망.
#   - 무한루프 방지: oroof_active.current_iteration/max_iterations 재사용(신규 카운터 금지)
#   - 비상 스위치: hooks/DISABLE_DONE_GATE 존재 시 즉시 통과
#   - valid_after 시점 태그(L-DEMO-4, 2026-09-05): acceptance 항목에 "valid_after":"odone" 이
#     있으면 이 게이트(DONE 전이 시점) 판정에서 제외한다. 커밋 게이트처럼 정의상 DONE 이후에만
#     충족 가능한 항목을 시점 무관 실행하면 필연적으로 차단되므로(예: A11 커밋 게이트),
#     비상 스위치(DISABLE_DONE_GATE) 상시 사용 대신 이 필드로 근본 해결한다.

INPUT=$(timeout 5 cat 2>/dev/null) || INPUT=""

_HOOK_DIR="${HARNESS_HOME:-$HOME/.harness}/current/hooks"

# ── 0. 비상 스위치 ──────────────────────────────────────────────────
# [c174 이월2] 스위치에 수명 상한을 둔다. c173 에서 사용자 승인 1회 우회용으로 만든 스위치가
#   약 62분간 남아 그동안 ★전 세션★ 의 DONE 게이트가 꺼져 있었다. 이 hook 은 5개 프로젝트 공유다.
#   ⇒ mtime 기준 DONE_GATE_SWITCH_TTL_MIN(기본 120)분 이내만 인정하고, 초과하면 무시하고 게이트를 계속한다.
#   삭제는 하지 않는다(사용자 소유 파일) — 경고만 남긴다. mtime 판독 실패도 "오래됨"과 같이 무시 쪽으로 간다.
if [[ -f "${_HOOK_DIR}/DISABLE_DONE_GATE" ]]; then
  _SW_TTL_MIN="${DONE_GATE_SWITCH_TTL_MIN:-120}"
  [[ "$_SW_TTL_MIN" =~ ^[0-9]+$ ]] || _SW_TTL_MIN=120
  _SW_MTIME=$(stat -c %Y "${_HOOK_DIR}/DISABLE_DONE_GATE" 2>/dev/null) || _SW_MTIME=""
  _SW_NOW=$(date +%s)
  if [[ "$_SW_MTIME" =~ ^[0-9]+$ ]] && (( _SW_NOW - _SW_MTIME <= _SW_TTL_MIN * 60 )); then
    exit 0
  fi
  _SW_AGE="미상"
  [[ "$_SW_MTIME" =~ ^[0-9]+$ ]] && _SW_AGE="$(( (_SW_NOW - _SW_MTIME) / 60 ))분"
  _SW_MSG="⚠️ [done_gate] DISABLE_DONE_GATE 가 ${_SW_AGE} 지나 상한(${_SW_TTL_MIN}분)을 넘었다 — 스위치를 무시하고 게이트를 검사한다. 다시 필요하면 touch 로 갱신하고, 끝나면 삭제하라: ${_HOOK_DIR}/DISABLE_DONE_GATE"
  echo "$_SW_MSG" >&2
  mkdir -p "$HOME/.claude/logs" 2>/dev/null
  echo "$(date '+%Y-%m-%dT%H:%M:%S%z') SWITCH-EXPIRED age=${_SW_AGE} ttl=${_SW_TTL_MIN}m" >> "$HOME/.claude/logs/done_gate_switch.log" 2>/dev/null || true
fi

# ── 1. 도구 입력 판별: key=state AND value=DONE 전이만 대상 ───────────
_KEY=$(echo "$INPUT" | jq -r '.tool_input.key // empty' 2>/dev/null) || exit 0
[[ "$_KEY" == "state" ]] || exit 0

_VALUE=$(echo "$INPUT" | jq -r '.tool_input.value // empty' 2>/dev/null) || exit 0
case "$_VALUE" in
  DONE|DONE\ *) ;;
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

# 팀에이전트/서브에이전트는 대상 아님 (메인의 DONE 전이만 검사 — 실제 state 전파는
# ok_pipeline이 메인 컨텍스트에서 odone spawn 직전에 호출한다)
# [r3] resolve_uuid 는 PIPELINE_UUID 가 있으면 MY_UUID 를 설정하지 않아 이 비교가 항상 같음(사문)이었다.
#      종전엔 goal fail-open 이 팀에이전트 호출을 통과시켜 드러나지 않았다 → 호출자 session_id 로 비교한다.
_RAW_SID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null) || _RAW_SID=""
if [[ -n "${PIPELINE_UUID:-}" && "${PIPELINE_UUID:-}" != "${MY_UUID:-${_RAW_SID:-$UUID}}" ]]; then
  exit 0
fi
# [r3] 팀에이전트 판별 보강 — write_guard T-E/F-ISO-3 과 같은 기준(조상 argv --parent-session-id).
#      PIPELINE_UUID 는 hook 환경에 전달되지 않는 경우가 많다(write_guard 실측 주석).
#      단 DONE_GATE_MODE=marker(write_guard Hd3 의 bash DONE 쓰기 검사)는 팀에이전트 경로도 검사해야 하므로 제외하지 않는다.
if [[ "${DONE_GATE_MODE:-}" != "marker" ]]; then
  _DG_TEAM=""
  _dg_real_home=""
  if [[ "${WG_TEST_SANDBOX:-}" == "1" && -n "${WG_LINEAGE_OVERRIDE:-}" ]]; then
    _dg_real_home=$(getent passwd "$(id -un 2>/dev/null)" 2>/dev/null | cut -d: -f6)
  fi
  if [[ -n "$_dg_real_home" && "$HOME" != "$_dg_real_home" ]]; then
    [[ "$WG_LINEAGE_OVERRIDE" == team:* ]] && _DG_TEAM="${WG_LINEAGE_OVERRIDE#team:}"
  else
    _dg_p=$$; _dg_i=0
    while [[ -n "$_dg_p" && "$_dg_p" != "1" && $_dg_i -lt 12 ]]; do
      _DG_TEAM=$(tr '\0' ' ' 2>/dev/null < "/proc/${_dg_p}/cmdline" \
        | grep -oP -- '--parent-session-id[ =]\K[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
      [[ -n "$_DG_TEAM" ]] && break
      _dg_p=$(awk '/^PPid:/{print $2}' "/proc/${_dg_p}/status" 2>/dev/null)
      _dg_i=$((_dg_i + 1))
    done
  fi
  [[ -n "$_DG_TEAM" ]] && exit 0
fi

# ── 4. SESSION_DIR 결정 (+ cc-prefix 분리 폴백) ───────────────────────
SESSION_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}"
HOME_SESSION_DIR="$HOME/.claude/session-env/${UUID}"

if [[ ! -f "${SESSION_DIR}/auto" && ! -f "${SESSION_DIR}/status" && \
      ( -f "${HOME_SESSION_DIR}/auto" || -f "${HOME_SESSION_DIR}/status" ) ]]; then
  SESSION_DIR="${HOME_SESSION_DIR}"
  _PATH_FALLBACK=1
fi

LOG_DIR="${SESSION_DIR}/logs"
LOG_FILE="${LOG_DIR}/done_gate.log"
mkdir -p "$LOG_DIR" 2>/dev/null
_log() {
  echo "$(date '+%Y-%m-%dT%H:%M:%S%z') $*" >> "$LOG_FILE" 2>/dev/null || true
}

# ── 4-5. [c175] QA 단계 검사 — 프로젝트가 .claude/qa_tier.json 을 선언했을 때만 ─────────
#   5단계(auto/ROOF/O4·O5 아니면 통과)보다 앞에 둔다 — O3 일반 사이클도 대상이기 때문이다.
#   DONE_GATE_MODE=marker(write_guard 의 bash 직접 DONE 쓰기) 경로도 이 블록을 지난다.
#   선언 없음 → 파일 존재 검사 1회 후 그대로 진행(타 프로젝트 무영향). lib 부재 → 로그 후 진행(설치 손상).
#   선언 파싱 실패 → 선언한 프로젝트에 한해 차단(fail-closed). jq 부재는 1단계에서 이미 통과(exit 0)한다.
_QA_LIB="${_HOOK_DIR}/lib/qa_tier_check.sh"
if [[ -r "$_QA_LIB" ]] && source "$_QA_LIB" 2>/dev/null \
   && declare -F qa_tier_decl_path qa_tier_load qa_tier_applies qa_marker_valid qa_block_reason >/dev/null 2>&1; then
  if qa_tier_decl_path "$INPUT" >/dev/null; then
      _CLASS=$(tr -d '[:space:]' < "${SESSION_DIR}/classification" 2>/dev/null | tr '[:lower:]' '[:upper:]') || _CLASS=""
      _QA_PST=$(tr -d '[:space:]' < "${SESSION_DIR}/pipeline_start_time" 2>/dev/null) || _QA_PST=""
      _QA_RC=0
      qa_tier_load "$QA_DECL" || _QA_RC=$?
      if [[ "$_QA_RC" -eq 0 ]] && ! qa_tier_applies "$_CLASS"; then
        _log "QA-SKIP tier=${_CLASS:-미상} enabled=${QA_ENABLED} tiers=${QA_TIERS} — 적용 대상 아님"
      else
        # [c184] 범위 면제 — 선언(scope)한 프로젝트만. lib 에 함수가 없거나(구판) 미선언(rc 2)이면 종전 동작.
        #   판정 불가(rc 3)·QA 대상 변경(rc 1)은 아래 마커 검사로 간다(fail-closed). 사용자 지시 2026-10-14.
        _QA_SC=2; QA_SCOPE_DETAIL=""
        if [[ "$_QA_RC" -eq 0 ]] && declare -F qa_scope_exempt >/dev/null 2>&1; then
          qa_scope_exempt "$SESSION_DIR" "$_QA_PST" && _QA_SC=0 || _QA_SC=$?
        fi
        [[ "$_QA_SC" -ne 0 && "$_QA_SC" -ne 2 ]] && _log "QA-SCOPE rc=${_QA_SC} tier=${_CLASS:-미상} ${QA_SCOPE_DETAIL}"
        if [[ "$_QA_SC" -eq 0 ]]; then
          _log "QA-EXEMPT tier=${_CLASS} ${QA_SCOPE_DETAIL}"
        elif [[ "$_QA_RC" -eq 0 ]] && qa_marker_valid "$SESSION_DIR" "$_QA_PST"; then
          _log "QA-PASS kind=${QA_RESULT_KIND} tier=${_CLASS} marker=${QA_MARKER_PATH}"
        else
          _QA_REASON=$(qa_block_reason "$SESSION_DIR")
          [[ -n "${QA_SCOPE_DETAIL:-}" ]] && _QA_REASON="${_QA_REASON}
   범위 판정(scope): ${QA_SCOPE_DETAIL}"
          _log "QA-BLOCK tier=${_CLASS:-미상} ${QA_FAIL_REASON}"
          jq -cn --arg r "⛔ [done_gate] DONE 진입 차단 — ${QA_LABEL:-QA} 단계 시험 완료 마커 미충족 (분류 ${_CLASS:-미상}, 선언 ${QA_DECL})
${_QA_REASON}
→ QA 시험(스냅샷 → 시험 표식 → 삭제·원복 → 전후 동일 실측)을 끝내고 마커를 쓴 뒤 다시 DONE 으로 전이하십시오.
   비상 시(사용자·메인만) hooks/DISABLE_DONE_GATE 파일 생성으로 우회할 수 있습니다." \
            '{decision:"block", reason:$r}' 2>/dev/null \
            || echo '{"decision":"block","reason":"⛔ [done_gate] DONE 진입 차단 — QA 단계 시험 완료 마커 미충족"}'
          source "${_HOOK_DIR}/lib/write_error.sh" 2>/dev/null || true
          declare -F log_hook_error >/dev/null 2>&1 && \
            log_hook_error "HOOK_BLOCK_DONE_GATE_QA" "mcp__oio__session_state" "DONE 진입 차단 — QA 마커 미충족: ${QA_FAIL_REASON}" "$UUID"
          exit 2
        fi
      fi
  fi
else
  _log "QA-WARN lib/qa_tier_check.sh 부재/로드 실패 — QA 단계 검사 생략(설치 손상)"
fi

# ── 4-6. [c214 R1-가] CRUD 승인 채널 코드 대응 — 판정기 정보 코드 ↔ write_guard _CRUD_ASKQ_INFO 짝 누락 차단 ─────────
#   10-24 판정기 신규 코드(DB_NAME_MENTION_CODE_EXCLUDED)가 승인 목록에 없어 화면 승인이 무효가 된 사고(c214 07:37)의 재발 방지.
#   tests/test_crud_askq_code_parity.sh 가 판정기 소스의 모든 줄 머리 코드를 정보·허용 실패·차단 중 하나로 분류하게 강제한다.
#   rc 1(미분류·중복) → DONE 차단. 시험 파일 부재 → 경고 로그만. rc 2(입력 부재)·124(시간 초과) 등 판정 불가 → 경고 로그 후 진행.
_PAR_T="${_HOOK_DIR}/tests/test_crud_askq_code_parity.sh"
if [[ -f "$_PAR_T" ]]; then
  _PAR_OUT=$(cd /tmp && timeout 5 bash "$_PAR_T" "${_HOOK_DIR}/write_guard.sh" 2>&1); _PAR_RC=$?
  if [[ "$_PAR_RC" -eq 1 ]]; then
    _PAR_BAD=$(printf '%s\n' "$_PAR_OUT" | grep '^FAIL ' | head -5)
    _log "PARITY-BLOCK $(printf '%s' "$_PAR_OUT" | tail -1) | $(printf '%s' "$_PAR_BAD" | tr '\n' ';' | head -c 300)"
    jq -cn --arg r "⛔ [done_gate] DONE 진입 차단 — CRUD 승인 채널 코드 대응 시험 실패(4-6)
${_PAR_BAD}
$(printf '%s' "$_PAR_OUT" | tail -1)
→ 판정기(verify_crud_executed.py)가 새로 내는 코드를 write_guard.sh _CRUD_ASKQ_INFO(판정을 지지 않는 정보 줄) 또는
   tests/test_crud_askq_code_parity.sh 의 BLOCK 표(승인 무효 유지) 중 하나에 넣은 뒤 다시 DONE 으로 전이하십시오.
   비상 시(사용자·메인만) hooks/DISABLE_DONE_GATE 파일 생성으로 우회할 수 있습니다." \
      '{decision:"block", reason:$r}' 2>/dev/null \
      || echo '{"decision":"block","reason":"⛔ [done_gate] DONE 진입 차단 — CRUD 승인 채널 코드 대응 시험 실패(4-6)"}'
    exit 2
  elif [[ "$_PAR_RC" -ne 0 ]]; then
    _log "PARITY-WARN rc=${_PAR_RC} 판정 불가 — 진행 $(printf '%s' "$_PAR_OUT" | tail -1 | head -c 200)"
  fi
else
  _log "PARITY-WARN tests/test_crud_askq_code_parity.sh 부재 — 코드 대응 검사 생략"
fi

# ── 5. 대상 세션 판정 — auto=ON 또는 status에 ROOF 없으면 무조건 통과 ──
_IS_AUTO=0
if [[ -f "${SESSION_DIR}/auto" ]]; then
  _AUTO_VAL=$(tr -d '[:space:]' < "${SESSION_DIR}/auto" 2>/dev/null) || _AUTO_VAL=""
  [[ "$_AUTO_VAL" == "ON" ]] && _IS_AUTO=1
fi

_IS_ROOF=0
# ROOF-COMPAT(deprecation window 1주기 — 구 RALPH/oralph_active 인식 제거 예정)
if [[ -f "${SESSION_DIR}/status" ]] \
   && grep -qE '(^|\|)(ROOF|RALPH)(\||$)' "${SESSION_DIR}/status" 2>/dev/null; then
  _IS_ROOF=1
fi

# [r3 Hc1 — conv_179065014644_r3] 대상 확장: classification ∈ {O4,O5} 도 대상에 넣는다.
#   배경(L9): r2 내내 goal.json locked=false 라서 이 게이트가 FAIL-OPEN 으로 3회 통과했고,
#   ui_test_done 없이 DONE 전이가 허용됐다. O1~O3 비-ROOF 비-auto 는 종전대로 즉시 통과.
_CLASS=$(tr -d '[:space:]' < "${SESSION_DIR}/classification" 2>/dev/null | tr '[:lower:]' '[:upper:]') || _CLASS=""
_IS_TIER=0
[[ "$_CLASS" == "O4" || "$_CLASS" == "O5" ]] && _IS_TIER=1

if [[ "$_IS_AUTO" -eq 0 && "$_IS_ROOF" -eq 0 && "$_IS_TIER" -eq 0 ]]; then
  exit 0
fi

_log "ENTER uuid=${UUID} auto=${_IS_AUTO} roof=${_IS_ROOF} tier=${_CLASS:-미상} value=${_VALUE}${DONE_GATE_MODE:+ mode=${DONE_GATE_MODE}}${_PATH_FALLBACK:+ path_fallback=HOME}"

# jq 없으면 검사 불가 → fail-open (로그 남기고 통과)
if ! command -v jq >/dev/null 2>&1; then
  _log "FAIL-OPEN jq 부재 — 검사 불가, DONE 전이 통과"
  exit 0
fi

# ── 5-2. [r3 Hc1] 필수 증거 마커 검사 ────────────────────────────────
#   goal.json 유무·잠금 여부와 무관하게 DONE 전이 시점에 필수 마커를 본다.
#   - evidence/otest_done: 존재 ∧ 비어 있지 않음 ∧ mtime ≥ pipeline_start_time
#     (otest 를 돌리는 tier O3~O5 에만 요구. O1/O2·미상은 otest 단계가 없으므로 요구하지 않는다 —
#      O2/O3 ROOF 재진입 흐름 과차단 방지. 로그 MARKER-SKIP 으로 추적)
#   - UI 마커: lib/ui_marker_check.sh 의 ui_markers_required 가 참이면 ui_markers_valid(v2) 통과 필요
#   - lib 부재 시 UI 검사만 건너뛰고 로그를 남긴다(otest_done 검사는 유지).
#   이 함수는 write_guard.sh 의 bash 직접 state=DONE 쓰기 분기가 DONE_GATE_MODE=marker 로 재사용한다(단일 출처).
_MC_REASON=""
_marker_check() {
  _MC_REASON=""
  case "$_CLASS" in
    O3|O4|O5) ;;
    *) _log "MARKER-SKIP tier=${_CLASS:-미상} — otest 미포함 tier, 마커 요구 안 함"; return 0 ;;
  esac
  local _od="${SESSION_DIR}/evidence/otest_done"
  local _pst _lib="${_HOOK_DIR}/lib/ui_marker_check.sh" _libok=0
  _pst=$(tr -d '[:space:]' < "${SESSION_DIR}/pipeline_start_time" 2>/dev/null) || _pst=""
  if [[ ! "$_pst" =~ ^[0-9]+$ ]]; then
    _log "WARN pipeline_start_time 부재/형식 오류 — mtime 조건 생략(나머지 검사 유지)"
    _pst=""
  fi
  if [[ -r "$_lib" ]]; then
    # shellcheck source=/dev/null
    source "$_lib" 2>/dev/null \
      && declare -F otest_done_valid ui_markers_required ui_markers_valid ui_marker_block_reason >/dev/null 2>&1 \
      && _libok=1
  fi
  # [TODO-027 2026-11-05] tool 프로파일 web 증거 면제.
  #   lib 의 ui_project_type 은 저장소 루트(깊이 2)에 *.html·package.json 이 있으면 web 으로 본다.
  #   하네스 저장소는 루트에 참고용 .html 이 있어 web 으로 분류돼 web_test_done 을 요구받았다(5차 사이클).
  #   plan/index.json 의 profile 이 정확히 "tool" 이고 세션이 project_type 을 명시하지 않았을 때만
  #   자동 판정 결과 web 을 빈값(추가 마커 없음)으로 바꾼다. otest_done·ui_test_done 요구와 csharp 판정은 그대로다.
  #   판독 실패·profile 불일치는 면제하지 않는다. 이 래퍼는 done_gate 안에서만 쓴다(lib 공용 동작·다른 hook 무변경).
  if [[ "$_libok" -eq 1 ]] && ! declare -F _dg_ptype_orig >/dev/null 2>&1; then
    eval "_dg_ptype_orig() $(declare -f ui_project_type | tail -n +2)"
    ui_project_type() {
      local _sd="$1" _t _pf _pt _root
      _t=$(_dg_ptype_orig "$_sd")
      [[ "$_t" == "web" ]] || { printf '%s' "$_t"; return 0; }
      _pt=$(tr -d '[:space:]' < "$(_umc_find "$_sd" project_type)" 2>/dev/null) || _pt=""
      if [[ -z "$_pt" ]]; then
        _root=$(git rev-parse --show-toplevel 2>/dev/null) || _root=""
        if [[ -n "$_root" && -f "$_root/plan/index.json" ]]; then
          _pf=$(jq -r 'if type=="object" then (.profile // "") else "" end' "$_root/plan/index.json" 2>/dev/null) || _pf=""
          if [[ "$_pf" == "tool" ]]; then
            _log "PTYPE-TOOL plan/index.json profile=tool (${_root}) — web 자동 판정 면제, web_test_done 요구 안 함"
            return 0
          fi
        fi
      fi
      printf '%s' "$_t"
    }
  fi

  if [[ "$_libok" -eq 1 ]]; then
    # (1) otest_done — lib 판정(비어 있지 않음·mtime ≥ pipeline_start_time) + 사유 ①②③
    if ! otest_done_valid "$_od" "$_pst"; then
      _MC_REASON=$(ui_marker_block_reason "$SESSION_DIR" "DONE 전이 차단 — otest_done 마커 무효" 2>/dev/null)
      [[ -z "$_MC_REASON" ]] && _MC_REASON="① ${_od} — ${UMC_FAIL_REASON:-무효}"
      return 1
    fi
    # (2) UI 마커 v2 — 요구 판정 rc 0=필요 / 1=불필요 / 2=판정 오류(차단)
    local _req=0
    ui_markers_required "$SESSION_DIR" || _req=$?
    if [[ "$_req" -eq 2 ]]; then
      _MC_REASON="① UI 마커 요구 판정 오류 — ${UMC_REQ_REASON:-ui_touched.json 판독 실패}
② ui_touched.json 은 {\"touched\": true|false, \"user_override\": false} 형식의 JSON 이어야 합니다.
③ JSON 을 고치거나, UI 변경이 없다면 mcp__oio__file_write(path=\"${SESSION_DIR}/evidence/ui_test_not_required\", content=\"<UI 테스트가 필요 없는 사유 1줄>\", overwrite=true)"
      return 1
    elif [[ "$_req" -eq 0 ]]; then
      if ! ui_markers_valid "$SESSION_DIR"; then
        _MC_REASON=$(ui_marker_block_reason "$SESSION_DIR" "DONE 전이 차단 — UI 테스트 완료 마커(v2) 무효" 2>/dev/null)
        [[ -z "$_MC_REASON" ]] && _MC_REASON="① ${UMC_FAIL_FILE:-UI 마커} — ${UMC_FAIL_REASON:-무효}"
        return 1
      fi
    else
      _log "UI-SKIP ${UMC_REQ_REASON:-불필요}"
    fi
    return 0
  fi

  # lib 부재·로드 실패 폴백: otest_done 만 자체 검사(UI 검사는 생략·로그)
  _log "WARN lib/ui_marker_check.sh 부재/로드 실패 — otest_done 만 자체 검사, UI 마커 검사 생략"
  local _why="" _mt
  if [[ ! -e "$_od" ]]; then
    _why="파일 없음"
  elif ! grep -q '[^[:space:]]' "$_od" 2>/dev/null; then
    _why="빈 파일(0바이트 또는 공백뿐 — touch 마커는 증거가 아니다)"
  elif [[ -n "$_pst" ]]; then
    _mt=$(stat -c %Y "$_od" 2>/dev/null) || _mt=0
    if [[ "$_mt" -lt "$_pst" ]]; then
      _why="mtime(${_mt}) < pipeline_start_time(${_pst}) — 이전 사이클 잔존 마커"
    fi
  fi
  if [[ -n "$_why" ]]; then
    _MC_REASON="① ${_od} — ${_why}
② 형식: 비어 있지 않은 1줄 'PASS|PARTIAL|FAIL <ISO8601>', mtime ≥ pipeline_start_time(${_pst:-미기록})
③ 작성 예(otest 가 검증을 끝낸 뒤): mcp__oio__file_write(path=\"${_od}\", content=\"PASS $(date '+%Y-%m-%dT%H:%M:%S%:z')\", overwrite=true)"
    return 1
  fi
  return 0
}

_marker_block() {
  _log "BLOCK marker $(echo "$_MC_REASON" | head -1)"
  jq -cn --arg r "⛔ [done_gate] DONE 진입 차단 — 필수 증거 마커 미충족 (분류 ${_CLASS:-미상}, auto=${_IS_AUTO} roof=${_IS_ROOF})
${_MC_REASON}
→ otest 가 검증을 끝내고 마커를 올바르게 작성한 뒤 다시 DONE 으로 전이하십시오.
   비상 시(사용자·메인만) hooks/DISABLE_DONE_GATE 파일 생성으로 우회할 수 있습니다." \
    '{decision:"block", reason:$r}' 2>/dev/null \
    || echo '{"decision":"block","reason":"⛔ [done_gate] DONE 진입 차단 — 필수 증거 마커(otest_done/UI 마커) 미충족"}'
  source "${_HOOK_DIR}/lib/write_error.sh" 2>/dev/null || true
  declare -F log_hook_error >/dev/null 2>&1 && \
    log_hook_error "HOOK_BLOCK_DONE_GATE_MARKER" "mcp__oio__session_state" "DONE 진입 차단 — 마커 미충족" "$UUID"
  exit 2
}

# write_guard 재사용 모드: 마커 검사만 수행(goal auto_script 판정 없음)
if [[ "${DONE_GATE_MODE:-}" == "marker" ]]; then
  _marker_check || _marker_block
  _log "MARKER-PASS mode=marker"
  exit 0
fi

# ── 6. goal.json 기반 판정 (F-OTO-2와 동일 알고리즘 재사용) ────────────
GOAL="${SESSION_DIR}/goal.json"

# [r3 Hc1] goal 부재·파싱 실패·locked≠true 는 더 이상 무조건 통과(fail-open)하지 않는다 → 마커 검사로 대체.
_GOAL_STATE=""
if [[ ! -f "$GOAL" ]]; then
  _GOAL_STATE="absent"
elif ! jq -e . "$GOAL" >/dev/null 2>&1; then
  _GOAL_STATE="parse_fail"
else
  _LOCKED=$(jq -r '.locked // false' "$GOAL" 2>/dev/null) || _LOCKED="false"
  [[ "$_LOCKED" != "true" ]] && _GOAL_STATE="unlocked"
fi

_marker_check || _marker_block

if [[ -n "$_GOAL_STATE" ]]; then
  _log "MARKER-PASS goal=${_GOAL_STATE} — 필수 마커 충족, DONE 전이 허용"
  exit 0
fi

# locked=true: 마커 통과 후 기존 auto_script 판정. 단 auto·ROOF 가 아닌 O4/O5 세션은 마커 검사만 한다.
if [[ "$_IS_AUTO" -eq 0 && "$_IS_ROOF" -eq 0 ]]; then
  _log "MARKER-PASS goal=locked tier-only — auto_script 판정 대상 아님, DONE 전이 허용"
  exit 0
fi

# [사이클168] auto_script 실행은 공용 실행부(lib/goal_autoscript_run.sh)의 gas_eval 로만 한다.
#   gas_eval 은 GOAL_SESSION_DIR·GOAL_UUID 를 넘기고, 같은 UUID 의 옛 세션 절대경로를 현재 세션으로 재매핑하며,
#   판정 스크립트 부재(rc=127·can't open file·리터럴 경로 부재)를 FAIL 이 아닌 판정불가(UNDET)로 구별한다.
#   lib 부재·로드 실패 시 bash -c 폴백은 없다(C1) — 폴백은 재매핑 없이 실행돼 사이클167 거짓 FAIL 을 재현한다.
#   lib 는 hook 세트의 일부이므로 부재는 설치 손상 = 판정불가다.
_GAS_OK=0
# shellcheck source=/dev/null
source "${_HOOK_DIR}/lib/goal_autoscript_run.sh" 2>/dev/null && declare -F gas_eval >/dev/null 2>&1 && _GAS_OK=1
[[ "$_GAS_OK" -eq 1 ]] || _log "WARN 공용 실행부 lib 부재/로드 실패 — auto_script 항목 전부 판정불가(UNDET), bash -c 폴백 없음"

# blocked/blocked_by 제외, auto_script 있는 open 항목만 실행 판정
_FAIL=0
_FAIL_IDS=""
_CANARY_OK=""
_UNDET=0
_UNDET_IDS=""
_UNDET_DETAIL=""
_RAN=0

while IFS= read -r _ITEM; do
  [[ -z "$_ITEM" ]] && continue
  _SCRIPT=$(echo "$_ITEM" | jq -r '.auto_script // empty' 2>/dev/null)
  _ID=$(echo "$_ITEM" | jq -r '.id // "?"' 2>/dev/null)
  # auto_script 없는 항목은 기계 판정 불가 — F-OTO-8과 달리 이 게이트는 no-op 방지를
  # 강제하지 않는다(F-OTO 계열이 이미 강제함). fail-open으로 스킵하고 로그만 남긴다.
  [[ -z "$_SCRIPT" ]] && { _log "SKIP id=${_ID} auto_script 없음 — 판정 불가"; continue; }
  _RAN=$((_RAN + 1))
  if [[ "$_GAS_OK" -eq 1 ]]; then
    gas_eval "$_SCRIPT" "$SESSION_DIR" 5
    _GRC=$?
  else
    _GRC=3
    GAS_DETAIL="공용 실행부 lib 부재/로드 실패"
    GAS_UNDET_KIND=""
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
      if [[ "${GAS_UNDET_KIND:-}" == "timeout" ]]; then
        # [사이클182 L-612] timeout 판정불가는 FAIL 과 같은 반복 한도 경로로 보낸다(한도 전 차단, 도달 시 fail-open).
        #   종전에도 timeout 은 FAIL 경로였으므로 느슨해지지 않는다. 부하로 인한 DONE 영구 교착(사이클123 동형)을 막는다.
        _FAIL=$((_FAIL + 1))
        _FAIL_IDS="${_FAIL_IDS}${_FAIL_IDS:+, }${_ID}(판정불가: ${GAS_DETAIL})"
        _log "UNDET-TIMEOUT id=${_ID} — ${GAS_DETAIL} (FAIL 과 같은 반복 한도 경로)"
      else
        # 판정 스크립트·명령 부재, 입력 문제(무력 정규식 등), lib 부재는 반복 한도와 무관하게 차단한다(6b).
        _UNDET=$((_UNDET + 1))
        _UNDET_IDS="${_UNDET_IDS}${_UNDET_IDS:+, }${_ID}"
        _UNDET_DETAIL="${_UNDET_DETAIL}
   - ${_ID}: ${GAS_DETAIL}"
        #   [사이클217] 긴 항목(timeout_sec+cache_inputs)의 진행 중(GAS_UNDET_KIND=pending)도 여기로 온다 —
        #   gas_eval 이 기록 없음 시 백그라운드 판정을 기동(setsid, </dev/null >log 2>&1)하고 rc3 를 낸다. 진행 중은 통과가 아니므로 무조건 차단이다.
        _log "UNDET id=${_ID} kind=${GAS_UNDET_KIND:-} 판정불가 — ${GAS_DETAIL}"
      fi
      ;;
  esac
done < <(jq -c '(.acceptance // [])[] | select((.status // "open") != "blocked" and (.status // "open") != "blocked_by") | select((.valid_after // "") != "odone")' "$GOAL" 2>/dev/null)

_log "CHECK ran=${_RAN} fail=${_FAIL} ids=${_FAIL_IDS:-none} undet=${_UNDET} undet_ids=${_UNDET_IDS:-none} canary_ok=${_CANARY_OK:-none}"

# ── 6b. [사이클168 D2] 판정불가(UNDET) 차단 — 7단계 max_iterations fail-open 보다 앞 ──
#   판정불가를 반복 끝에 통과시키면 "판정불가 → PASS" 완화가 된다(사이클167 실사고 경로).
#   FAIL 만 있을 때의 종전 fail-open(7단계)은 그대로 보존한다.
if [[ "$_UNDET" -gt 0 ]]; then
  _log "BLOCK undet=${_UNDET} ids=${_UNDET_IDS} fail=${_FAIL} fail_ids=${_FAIL_IDS:-none}"
  _FAIL_LINE=""
  [[ "$_FAIL" -gt 0 ]] && _FAIL_LINE="
(함께 미충족 FAIL ${_FAIL}건: ${_FAIL_IDS})"
  jq -cn --arg r "⛔ [done_gate] 판정불가 ${_UNDET}건: ${_UNDET_IDS} — 판정불가는 PASS 가 아닙니다(반복 한도 도달과 무관하게 차단).
판정불가 사유:${_UNDET_DETAIL}${_FAIL_LINE}
→ 스크립트·lib 를 복원하거나 계약의 auto_script 를 \$GOAL_SESSION_DIR 기준으로 고치십시오.
   (공용 실행부: hooks/lib/goal_autoscript_run.sh — 모든 실행부가 goal.json 디렉터리를 GOAL_SESSION_DIR 로 넘깁니다)
→ 비상: hooks/DISABLE_DONE_GATE" \
    '{decision:"block", reason:$r}' 2>/dev/null \
    || echo '{"decision":"block","reason":"⛔ [done_gate] 판정불가 항목이 있습니다 — 판정불가는 PASS 가 아닙니다."}'
  source "${_HOOK_DIR}/lib/write_error.sh" 2>/dev/null || true
  declare -F log_hook_error >/dev/null 2>&1 && \
    log_hook_error "HOOK_BLOCK_DONE_GATE_UNDET" "mcp__oio__session_state" "DONE 진입 차단 — 판정불가 ${_UNDET}건: ${_UNDET_IDS}" "$UUID"
  exit 2
fi

if [[ "$_FAIL" -eq 0 ]]; then
  _log "PASS 잔여 acceptance 없음 (ran=${_RAN}) — DONE 전이 허용"
  exit 0
fi

# ── 7. 무한루프 방지 — oroof_active.max_iterations 재사용 ─────────────
OROOF_FLAG="${SESSION_DIR}/oroof_active"
[[ ! -f "$OROOF_FLAG" && -f "${OROOF_FLAG}.json" ]] && OROOF_FLAG="${OROOF_FLAG}.json"
# ROOF-COMPAT(deprecation window 1주기 — 구 RALPH/oralph_active 인식 제거 예정)
[[ ! -f "$OROOF_FLAG" && -f "${SESSION_DIR}/oralph_active" ]] && OROOF_FLAG="${SESSION_DIR}/oralph_active"
# ROOF-COMPAT(deprecation window 1주기 — 구 RALPH/oralph_active 인식 제거 예정)
[[ ! -f "$OROOF_FLAG" && -f "${SESSION_DIR}/oralph_active.json" ]] && OROOF_FLAG="${SESSION_DIR}/oralph_active.json"

_CUR_ITER=0
_MAX_ITER=5
if [[ -f "$OROOF_FLAG" ]]; then
  _CUR_ITER=$(jq -r '.current_iteration // 0' "$OROOF_FLAG" 2>/dev/null) || _CUR_ITER=0
  _MAX_ITER=$(jq -r '.max_iterations // 5' "$OROOF_FLAG" 2>/dev/null) || _MAX_ITER=5
fi

if [[ "$_CUR_ITER" -ge "$_MAX_ITER" ]]; then
  _log "FAIL-OPEN max_iterations 도달(${_CUR_ITER}/${_MAX_ITER}) — 무한루프 방지, DONE 전이 통과(미완료 보고는 스킬 절차가 담당)"
  exit 0
fi

# ── 8. block — 스킬(otest_verify 종료부)이 먼저 잡아야 정상 경로.
#      여기 도달했다는 것은 스킬 절차를 건너뛰고 곧바로 state=DONE을 쓴 비정상
#      경로이므로 최종 안전망으로 차단한다.
_log "BLOCK fail=${_FAIL} ids=${_FAIL_IDS} iter=${_CUR_ITER}/${_MAX_ITER}"
jq -cn --arg r "⛔ [done_gate] DONE 진입 차단 — auto/ROOF 계약상 미충족 acceptance ${_FAIL}건: ${_FAIL_IDS}
otest_verify 종료 직후 스킬 절차가 이 검사를 먼저 수행해야 합니다(정상 경로).
이 hook은 그 절차를 건너뛴 경우의 최종 안전망입니다.
→ 해결: otest_verify 절차대로 실패 항목을 반영해 PLAN으로 재진입하거나,
   비상 시 hooks/DISABLE_DONE_GATE 파일 생성으로 우회하십시오." \
  '{decision:"block", reason:$r}' 2>/dev/null \
  || echo '{"decision":"block","reason":"⛔ DONE 진입 차단 — auto/ROOF 계약상 미충족 acceptance 항목이 있습니다."}'
source "${_HOOK_DIR}/lib/write_error.sh" 2>/dev/null || true
declare -F log_hook_error >/dev/null 2>&1 && \
  log_hook_error "HOOK_BLOCK_DONE_GATE" "mcp__oio__session_state" "DONE 진입 차단 — 미충족 acceptance ${_FAIL}건: ${_FAIL_IDS}" "$UUID"
exit 2
