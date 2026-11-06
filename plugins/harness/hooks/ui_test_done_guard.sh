#!/bin/bash
# ui_test_done_guard.sh — Phase 2.5 UI 테스트 완료 증거 검증 (PreToolUse:Agent)
# odone spawn 시 O4/O5 분류에서 프로젝트 유형별 UI 테스트 증거 파일 없으면 차단 (O3 제외)
# r3(2026-09-29, ohook-1): 종전 ERR trap 의 무조건 통과(fail-open)를 제거했다.
#   대상 판정(odone spawn ∧ UUID ∧ classification O4/O5) 전 오류 → 통과 + logs/ui_guard_error.log
#   대상 판정 후 오류 → 차단
#   마커 검사는 lib/ui_marker_check.sh(v2: 비어 있지 않음·첫 줄 상태+ISO 시각·evidence 경로 실존·mtime)로 한다.

_PHASE="pre"
UUID=""
SESSION_DIR=""

# 자기 세션 logs 에만 기록한다(SESSION_DIR 미확정이면 기록하지 않음)
_guard_log() {
  [[ -n "$SESSION_DIR" && -d "$SESSION_DIR" ]] || return 0
  mkdir -p "${SESSION_DIR}/logs" 2>/dev/null || return 0
  echo "$(date '+%Y-%m-%d %H:%M:%S') [ui_test_done_guard] $1" >> "${SESSION_DIR}/logs/ui_guard_error.log" 2>/dev/null || true
}

# 차단: 사유 전문을 stdout(JSON)·stderr(평문) 양쪽에 낸다
_block() {
  source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/write_error.sh" 2>/dev/null || true
  declare -F log_hook_error >/dev/null 2>&1 && log_hook_error "${2:-HOOK_BLOCK_UI_TEST_DONE}" "Agent" "$(printf '%s' "$1" | head -n 3 | tr '\n' ' ')" "${UUID:-unknown}" 2>/dev/null
  if declare -F ui_block_json >/dev/null 2>&1; then ui_block_json "$1"; else jq -cn --arg r "$1" '{decision:"block",reason:$r}' 2>/dev/null; fi
  printf '%s\n' "$1" >&2
  exit 2
}

# 오류 처리: 판정 전 = 통과+로그, 판정 후 = 차단
_on_err() {
  local rc=$? ln="$1"
  if [[ "$_PHASE" == "pre" ]]; then
    _guard_log "판정 전 명령 실패 → 통과 (line=${ln} rc=${rc})"
    exit 0
  fi
  _guard_log "판정 후 명령 실패 → 차단 (line=${ln} rc=${rc})"
  _PHASE="blocking"
  trap - ERR
  _block "❌ [ui_test_done_guard] O4/O5 odone spawn 대상 판정 뒤 hook 내부 명령이 실패했다(line ${ln}, rc=${rc}). 검사를 끝내지 못했으므로 통과시키지 않는다.
조치: ${SESSION_DIR}/logs/ui_guard_error.log 를 확인하고, evidence/ui_test_done(+winforms_test_done/web_test_done)을 v2 형식(첫 줄 'PASS|PARTIAL|FAIL <ISO8601>', 'evidence: <절대경로>' 1줄 이상)으로 다시 쓴 뒤 재시도하라." HOOK_BLOCK_UI_GUARD_INTERNAL
}
trap '_on_err $LINENO' ERR

INPUT=$(timeout 5 cat 2>/dev/null) || INPUT=""
TEAM_NAME=$(echo "$INPUT" | jq -r '.tool_input.team_name // empty' 2>/dev/null || echo "")

# 팀에이전트 spawn이 아니면 패스
[[ -z "$TEAM_NAME" ]] && exit 0

# odone spawn인지 확인
AGENT_NAME=$(echo "$INPUT" | jq -r '.tool_input.name // ""' 2>/dev/null || echo "")
echo "$AGENT_NAME" | grep -qE "^odone" || exit 0

# UUID 결정
source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/session_id.sh"
resolve_uuid "$INPUT" 2>/dev/null || UUID="${CLAUDE_SESSION_ID}"
[[ -z "$UUID" ]] && exit 0
SESSION_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}"
# HOME 폴백 경로: cc-prefix 와 $HOME/.claude 경로 분리 대응 (L-cc-prefix 사고)
HOME_SESSION_DIR="$HOME/.claude/session-env/${UUID}"
# 사이클46 축① — 반대편 base 미러
source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/session_mirror.sh" 2>/dev/null || true
declare -F _mirror_file >/dev/null 2>&1 || _mirror_file() { :; }

# O1/O2/O3 분류는 UI 테스트 불필요 -- 스킵
CLASSIFICATION=$(cat "${SESSION_DIR}/classification" 2>/dev/null || echo "")
# §(a) 준수: classification 빈값이어도 타 세션 UUID 역추적 금지 — fail-closed
# [P2-isolation] L-278 UUID 역추적 fallback 제거 (Fix 31, 2026-04-24)
# 이전 동작: find session-env -name team_name 전체 순회 → 타 세션 UUID 채택 (§(a)(c) 위반)
# 수정: PIPELINE_UUID가 올바르지 않으면 차단 불가 상태로 통과 (O1/O2/O3 판정과 동일)
case "$CLASSIFICATION" in
  O4|O5) ;;
  *) exit 0 ;;
esac

# ── 대상 확정 (O4/O5 odone spawn) — 이후 오류는 차단 ──
_PHASE="post"

if ! source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/ui_marker_check.sh" 2>/dev/null || ! declare -F ui_markers_valid >/dev/null 2>&1; then
  _guard_log "lib/ui_marker_check.sh source 실패 → 차단"
  _block "❌ [ui_test_done_guard] O4/O5 odone spawn 검사에 필요한 ${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/ui_marker_check.sh 를 불러오지 못했다. 검사 없이 통과시키지 않는다. hook 배포 상태(lib 파일 존재)를 확인하라." HOOK_BLOCK_UI_GUARD_LIB
fi

# [TODO-039 2026-11-06] tool 프로파일 web 증거 면제(done_gate TODO-027 과 같은 기준).
#   lib 의 ui_project_type 은 저장소 루트(깊이 2)에 *.html·package.json 이 있으면 web 으로 본다.
#   하네스 저장소는 루트에 참고용 .html 이 있어 web 으로 분류돼 odone spawn 때 web_test_done 을 요구받았다.
#   plan/index.json 의 profile 이 정확히 "tool" 이고 세션이 project_type 을 명시하지 않았을 때만
#   자동 판정 결과 web 을 빈값(추가 마커 없음)으로 바꾼다. ui_test_done 요구와 csharp 판정은 그대로다.
#   판독 실패·profile 불일치는 면제하지 않는다. 이 래퍼는 이 hook 안에서만 쓴다(lib 공용 동작·다른 hook 무변경).
if ! declare -F _ug_ptype_orig >/dev/null 2>&1; then
  eval "_ug_ptype_orig() $(declare -f ui_project_type | tail -n +2)"
  ui_project_type() {
    local _sd="$1" _t _pf _pt _root
    _t=$(_ug_ptype_orig "$_sd")
    [[ "$_t" == "web" ]] || { printf '%s' "$_t"; return 0; }
    _pt=$(tr -d '[:space:]' < "$(_umc_find "$_sd" project_type)" 2>/dev/null) || _pt=""
    if [[ -z "$_pt" ]]; then
      _root=$(git rev-parse --show-toplevel 2>/dev/null) || _root=""
      if [[ -n "$_root" && -f "$_root/plan/index.json" ]]; then
        _pf=$(jq -r 'if type=="object" then (.profile // "") else "" end' "$_root/plan/index.json" 2>/dev/null) || _pf=""
        if [[ "$_pf" == "tool" ]]; then
          _guard_log "PTYPE-TOOL plan/index.json profile=tool (${_root}) — web 자동 판정 면제, web_test_done 요구 안 함"
          return 0
        fi
      fi
    fi
    printf '%s' "$_t"
  }
fi

# ui_touched=false(user_override 아님) 또는 사유 있는 ui_test_not_required → UI 테스트 불필요 (L-273)
# 빈 ui_test_not_required 는 면제로 인정하지 않는다(v2)
if ui_markers_required "$SESSION_DIR"; then _REQ=0; else _REQ=$?; fi
if [[ "$_REQ" == 2 ]]; then
  _guard_log "요구 판정 오류 → 차단: ${UMC_REQ_REASON}"
  _block "❌ [ui_test_done_guard] O4/O5 odone spawn — UI 마커 요구 여부를 판정하지 못했다: ${UMC_REQ_REASON}. 판정 없이 통과시키지 않는다.
조치: evidence/ui_touched.json 을 올바른 JSON({\"touched\": true|false})으로 고친 뒤 재시도하라." HOOK_BLOCK_UI_GUARD_REQ_ERR
fi
if [[ "$_REQ" != 0 ]]; then
  exit 0
fi

# HOME 경로 폴백: SESSION_DIR가 /tmp/cc-... 이면 $HOME/.claude에서 evidence 탐색
if [[ ! -f "${SESSION_DIR}/evidence/ui_test_done" && \
      -f "${HOME_SESSION_DIR}/evidence/ui_test_done" ]]; then
  # 로그 기록 실패는 검사 결과와 무관하므로 차단 사유로 삼지 않는다
  { mkdir -p "${HOME_SESSION_DIR}/logs" && \
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ui_test_done_guard] HOME 경로 폴백 채택 (cc-prefix 분리 감지) uuid=${UUID}" \
      >> "${HOME_SESSION_DIR}/logs/path_fallback.log"; } 2>/dev/null || true
  _mirror_file "${HOME_SESSION_DIR}/logs/path_fallback.log" 2>/dev/null || true
  SESSION_DIR="${HOME_SESSION_DIR}"
fi

# 2차: prompt UUID 폴백 시도 (§(b) 소유권 증명 통과 시만 채택)
if [[ ! -f "${SESSION_DIR}/evidence/ui_test_done" ]]; then
  UI_FALLBACK_UUID=$(resolve_uuid_from_prompt "$INPUT") || true
  if [[ -n "$UI_FALLBACK_UUID" && "$UI_FALLBACK_UUID" != "$UUID" ]]; then
    UI_FALLBACK_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UI_FALLBACK_UUID}"
    if [[ -f "${UI_FALLBACK_DIR}/evidence/ui_test_done" ]]; then
      # 폴백 성공: SESSION_DIR 교체 + uuid_fallback.log 기록
      { mkdir -p "${UI_FALLBACK_DIR}/logs" && \
        echo "$(date '+%Y-%m-%d %H:%M:%S') [ui_test_done_guard] uuid_fallback adopted=${UI_FALLBACK_UUID} input_sid=${UUID} agent=${AGENT_NAME} team=${TEAM_NAME}" \
          >> "${UI_FALLBACK_DIR}/logs/uuid_fallback.log"; } 2>/dev/null || true
      SESSION_DIR="$UI_FALLBACK_DIR"
      UUID="$UI_FALLBACK_UUID"
    fi
  fi
fi

# v2 검사: ui_test_done + 프로젝트 유형 마커(csharp → winforms_test_done, web → web_test_done)
if ! ui_markers_valid "$SESSION_DIR"; then
  [[ -n "$UMC_NOTE" ]] && _guard_log "$UMC_NOTE"
  REASON=$(ui_marker_block_reason "$SESSION_DIR" "odone spawn 차단 — O4/O5 UI 테스트 완료 마커(v2) 검사 실패 (${UMC_REQ_REASON})")
  _block "$REASON" HOOK_BLOCK_UI_TEST_DONE
fi
[[ -n "$UMC_NOTE" ]] && _guard_log "$UMC_NOTE"

exit 0
