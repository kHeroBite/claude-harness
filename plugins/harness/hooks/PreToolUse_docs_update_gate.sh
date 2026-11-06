#!/bin/bash
# 코드 변경 대비 HISTORY/DATABASE/PROJECT 문서 미반영을 FINISH 진입(O3~O5)·FINISH→IDLE(O1/O2) 전이에서 점검하는 hook
# PreToolUse:mcp__oio__session_state — key=state, value 첫 단어 FINISH 또는 IDLE 만 대상
#
# 판정 지점:
#   - value=FINISH* : docs_gate_tier 마커에 현재 classification 을 기록한다(모든 tier).
#                     classification ∈ {O3,O4,O5} 이면 phase=finish 로 판정(odone 문서·커밋 직후).
#   - value=IDLE*   : state 파일 첫 단어=FINISH 이고 docs_gate_tier 마커(이번 사이클 것)=O1/O2 이면 phase=idle 로 판정.
#                     ofinish Step 8 이 classification 을 IDLE 전이 전에 지우므로 classification 은 쓰지 않는다.
#                     마커는 IDLE 판정이 통과(pass/warn)한 뒤 이 hook 이 지운다. 차단 시에는 재시도를 위해 남긴다.
# 결과: block → {"decision":"block","reason":...} / warn → hookSpecificOutput.additionalContext / pass → 무출력
# 통과 조건(exit 0): 비대상 입력, uuid 형식 오류·타 세션 uuid(세션 격리), 팀에이전트(조상 argv --parent-session-id),
#   비상 스위치 hooks/DISABLE_DOCS_GATE(mtime 120분 이내), jq/python3 부재·코어 실패 등 판정 불가(fail-open)
# 시험 훅: WG_TEST_SANDBOX=1 + WG_LINEAGE_OVERRIDE(가짜 HOME 일 때만), DOCS_GATE_SWITCH(스위치 경로), DOCS_GATE_CONFIG(설정 경로)
# 설정: lib/docs_gate_config.json (mode_history/mode_database/mode_project/enforce_after_epoch), 프로젝트 <루트>/.claude/docs_gate.json
#   mode_plan(tier|block|warn|off) — plan root 정본 반영(PLAN) 점검. tier=O3~O5 FINISH 차단·그 외 경고, 사유 키 `PLAN:`
# 사유 파일: session-env/<UUID>/docs_update_waiver — 줄마다 `HISTORY: 사유`(10자 이상, 이번 사이클 시작 이후 mtime)
# 등록: settings.json `time_budget.sh 9 open` 래퍼(matcher 가 session_state 전체라 closed 면 hook 정체 시 모든 상태 쓰기가 막힌다).
set -u
command -v jq >/dev/null 2>&1 || exit 0
INPUT=$(timeout 5 cat 2>/dev/null) || exit 0
[ -z "$INPUT" ] && exit 0
_get() { printf '%s' "$INPUT" | jq -r "$1" 2>/dev/null; }
[ "$(_get '.tool_input.key // empty')" = "state" ] || exit 0
_VALUE=$(_get '.tool_input.value // empty')
_V1="${_VALUE%% *}"
case "$_V1" in
  FINISH|IDLE) ;;
  *) exit 0 ;;
esac
_UUID=$(_get '.tool_input.uuid // empty')
printf '%s' "$_UUID" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || exit 0
# 자기 세션 확인
_SELF="${PIPELINE_UUID:-}"
[ -n "$_SELF" ] || _SELF=$(_get '.session_id // empty' | tr -d '[:space:]')
{ [ -n "$_SELF" ] && [ "$_SELF" = "$_UUID" ]; } || exit 0
# 팀에이전트 제외 (done_gate·dev_ac_gate 와 같은 기준)
_TEAM=""
_real_home=""
if [ "${WG_TEST_SANDBOX:-}" = "1" ] && [ -n "${WG_LINEAGE_OVERRIDE:-}" ]; then
  _real_home=$(getent passwd "$(id -un 2>/dev/null)" 2>/dev/null | cut -d: -f6)
fi
if [ -n "$_real_home" ] && [ "$HOME" != "$_real_home" ]; then
  case "$WG_LINEAGE_OVERRIDE" in team:*) _TEAM="${WG_LINEAGE_OVERRIDE#team:}" ;; esac
else
  _p=$$; _i=0
  while [ -n "$_p" ] && [ "$_p" != "1" ] && [ $_i -lt 12 ]; do
    _TEAM=$(tr '\0' ' ' 2>/dev/null < "/proc/${_p}/cmdline" \
      | grep -oP -- '--parent-session-id[ =]\K[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
    [ -n "$_TEAM" ] && break
    _p=$(awk '/^PPid:/{print $2}' "/proc/${_p}/status" 2>/dev/null)
    _i=$((_i + 1))
  done
fi
[ -n "$_TEAM" ] && exit 0
# 세션 디렉토리 (CLAUDE_CONFIG_DIR 우선, 없으면 HOME)
_SD=""
for _b in "${CLAUDE_CONFIG_DIR:-}" "$HOME/.claude"; do
  [ -n "$_b" ] && [ -d "${_b}/session-env/${_UUID}" ] && { _SD="${_b}/session-env/${_UUID}"; break; }
done
[ -n "$_SD" ] || exit 0
_LOG="${_SD}/logs/docs_gate.log"
mkdir -p "${_SD}/logs" 2>/dev/null
_log() { echo "$(date '+%Y-%m-%dT%H:%M:%S%z') $*" >> "$_LOG" 2>/dev/null || true; }
# 비상 스위치 (mtime TTL 이내만 인정 — done_gate c174 방식)
_SW="${DOCS_GATE_SWITCH:-${HARNESS_HOME:-$HOME/.harness}/current/hooks/DISABLE_DOCS_GATE}"
if [ -f "$_SW" ]; then
  _TTL="${DOCS_GATE_SWITCH_TTL_MIN:-120}"
  case "$_TTL" in ''|*[!0-9]*) _TTL=120 ;; esac
  _SWM=$(stat -c %Y "$_SW" 2>/dev/null) || _SWM=""
  _NOW=$(date +%s)
  case "$_SWM" in
    ''|*[!0-9]*) _log "SWITCH-UNREADABLE 무시" ;;
    *)
      if [ $((_NOW - _SWM)) -le $((_TTL * 60)) ]; then
        _log "SWITCH-ON value=${_V1} 통과"
        exit 0
      fi
      _log "SWITCH-EXPIRED age=$(( (_NOW - _SWM) / 60 ))m ttl=${_TTL}m 무시하고 검사" ;;
  esac
fi
_MARK="${_SD}/docs_gate_tier"
_PHASE=""
if [ "$_V1" = "FINISH" ]; then
  _CLS=$(head -n1 "${_SD}/classification" 2>/dev/null | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
  [ -n "$_CLS" ] && printf '%s\n' "$_CLS" > "$_MARK" 2>/dev/null
  case "$_CLS" in
    O3|O4|O5) _PHASE=finish ;;
    *) _log "SKIP finish cls=${_CLS:-없음} (O1/O2 는 FINISH→IDLE 에서 판정)"; exit 0 ;;
  esac
else
  _ST=$(head -n1 "${_SD}/state" 2>/dev/null | awk '{print $1}')
  [ "$_ST" = "FINISH" ] || exit 0
  [ -f "$_MARK" ] || { _log "SKIP idle 마커 없음"; exit 0; }
  # 이전 사이클 잔존 마커 배제: 사이클 시작 시각보다 오래된 마커는 무시
  _PST=$(head -n1 "${_SD}/pipeline_start_time" 2>/dev/null | tr -d '[:space:]')
  _MM=$(stat -c %Y "$_MARK" 2>/dev/null) || _MM=""
  case "$_PST$_MM" in
    ''|*[!0-9]*) ;;
    *) if [ -n "$_PST" ] && [ "$_MM" -lt "$_PST" ]; then _log "SKIP idle 마커가 이전 사이클 것"; exit 0; fi ;;
  esac
  _TIER=$(head -n1 "$_MARK" 2>/dev/null | tr -d '[:space:]')
  case "$_TIER" in
    O1|O2) _PHASE=idle ;;
    *) rm -f "$_MARK" 2>/dev/null; exit 0 ;;
  esac
fi
command -v python3 >/dev/null 2>&1 || { _log "PASS python3 없음"; exit 0; }
_CORE="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/lib/docs_gate.py"
[ -f "$_CORE" ] || { _log "PASS 코어 없음 ${_CORE}"; exit 0; }
_CWD=$(_get '.cwd // empty')
[ -n "$_CWD" ] || _CWD="$PWD"
_OUT=$(timeout 8 python3 -B "$_CORE" check --session-dir "$_SD" --cwd "$_CWD" --phase "$_PHASE" 2>/dev/null) || _OUT=""
_DEC=$(printf '%s' "$_OUT" | jq -r '.decision // empty' 2>/dev/null)
_MSG=$(printf '%s' "$_OUT" | jq -r '(.messages // []) | join("\n")' 2>/dev/null)
case "$_DEC" in
  block)
    _log "BLOCK phase=${_PHASE}"
    jq -n --arg r "⛔ [PreToolUse_docs_update_gate] ${_V1} 전이 차단 (phase=${_PHASE})
${_MSG}" '{decision:"block", reason:$r}' 2>/dev/null \
      || echo '{"decision":"block","reason":"⛔ [PreToolUse_docs_update_gate] 문서 미반영으로 전이 차단"}'
    exit 0 ;;
  warn)
    [ "$_PHASE" = "idle" ] && rm -f "$_MARK" 2>/dev/null
    jq -n --arg c "⚠️ [PreToolUse_docs_update_gate] (phase=${_PHASE})
${_MSG}" '{hookSpecificOutput:{hookEventName:"PreToolUse", additionalContext:$c}}' 2>/dev/null
    exit 0 ;;
  pass)
    [ "$_PHASE" = "idle" ] && rm -f "$_MARK" 2>/dev/null
    exit 0 ;;
  *)
    _log "PASS 코어 출력 판독 실패(fail-open)"
    exit 0 ;;
esac
