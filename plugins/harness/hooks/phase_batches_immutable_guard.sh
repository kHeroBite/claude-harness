#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# phase_batches_immutable_guard.sh — phase_batches.json immutable 강제 (F9)
# 매처: PreToolUse:mcp__oio__file_write|file_edit|file_delete|file_rename|file_move|Edit|Write
#
# 명세 (oplan_final_v2 §4 F9):
#   - target path가 phase_batches.json 포함 시 호출자 식별
#   - 허용 조건:
#       (a) 팀에이전트(PIPELINE_UUID 존재) + agents/oplan* 중 하나와 pane 매칭
#       (b) 메인이 oplan 쓰기 플래그(oplan_writing_phase_batches) 설정 후 호출
#   - 그 외 모두 차단 → log_hook_error "HOOK_BLOCK_PHASE_BATCHES_IMMUTABLE" + exit 2
#   - 한 번 생성된 파일은 어떤 호출자도 수정/삭제/이동 불가 (immutable)

set -u

# write_error.sh (log_hook_error) 로드
# shellcheck disable=SC1091
source "${HARNESS_HOOK_DIR}/lib/write_error.sh" 2>/dev/null || {
  # 유틸 미존재 시 최소 대체 (에러 기록 실패해도 차단은 진행)
  log_hook_error() { :; }
}

INPUT=$(timeout 2 cat 2>/dev/null) || INPUT=""
[[ -z "$INPUT" ]] && exit 0

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || TOOL_NAME=""
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null) || SESSION_ID=""

# 쓰기 계열만 검사
case "$TOOL_NAME" in
  mcp__oio__file_write|mcp__oio__file_edit|mcp__oio__file_delete|mcp__oio__file_rename|mcp__oio__file_move|Edit|Write) ;;
  *) exit 0 ;;
esac

# 대상 경로 추출
TARGET=$(echo "$INPUT" | jq -r '
  .tool_input as $i |
  ($i.file_path // $i.path // $i.filepath //
   $i.old_path // $i.src // $i.source //
   $i.new_path // $i.dst // $i.destination // empty)
' 2>/dev/null)
[[ -z "$TARGET" ]] && exit 0

# phase_batches.json 포함 여부 확인
case "$TARGET" in
  *phase_batches.json) ;;
  *) exit 0 ;;
esac

# UUID 확정 (세션 ID 우선, 미검출 시 경로에서 추출)
UUID="$SESSION_ID"
if [[ -z "$UUID" ]]; then
  UUID=$(echo "$TARGET" | sed -n 's#.*/session-env/\([^/]*\)/.*#\1#p')
fi
[[ -z "$UUID" ]] && UUID="${PIPELINE_UUID:-unknown}"

SESSION_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}"
LOG_DIR="${SESSION_DIR}/logs"
LOG="${LOG_DIR}/phase_batches_guard.log"
mkdir -p "$LOG_DIR" 2>/dev/null

WRITE_FLAG="${SESSION_DIR}/oplan_writing_phase_batches"
LOCK_FILE="${SESSION_DIR}/.phase_batches.lock"
WRITTEN_MARK="${SESSION_DIR}/.phase_batches.written"

_log() {
  local sev="$1"; shift
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "${ts} [${sev}] tool=${TOOL_NAME} target=${TARGET} uuid=${UUID} ${*}" >> "$LOG" 2>/dev/null
}

_block() {
  local reason="$1"
  _log "BLOCK" "reason=${reason}"
  jq -n --arg r "$reason" --arg t "$TARGET" '{
    decision: "block",
    reason: ("🚫 [F9 phase_batches immutable] " + $r + " — " + $t + " 는 oplan만 1회 쓰기 가능")
  }'
  log_hook_error "HOOK_BLOCK_PHASE_BATCHES_IMMUTABLE" "$TOOL_NAME" "phase_batches.json immutable: ${reason} target=${TARGET}" "$UUID"
  exit 2
}

# 쓰기 락 (flock) — 동시 경합 직렬화
exec 200>"$LOCK_FILE" 2>/dev/null || { _log "WARN" "flock_open_failed"; exit 0; }
flock -w 3 200 2>/dev/null || { _log "WARN" "flock_wait_timeout"; exit 0; }

# === 삭제/이동/이름변경은 호출자 무관 항상 차단 (완전 immutable) ===
case "$TOOL_NAME" in
  mcp__oio__file_delete|mcp__oio__file_rename|mcp__oio__file_move)
    _block "delete_rename_move_forbidden"
    ;;
esac

# === 호출자 식별 ===
# (a) oplan 쓰기 플래그 존재 → 메인/팀 모두 허용 증거 (기존 oplan_deep SKILL.md 패턴)
HAS_FLAG=0
[ -f "$WRITE_FLAG" ] && HAS_FLAG=1

# (b) 팀에이전트 + agents/oplan* 매칭 확인
IS_OPLAN_AGENT=0
MY_PANE=$(tmux display-message -p '#{pane_id}' 2>/dev/null || echo "")
if [[ -n "${PIPELINE_UUID:-}" && -n "$MY_PANE" ]]; then
  AGENTS_DIR="${SESSION_DIR}/agents"
  if [ -d "$AGENTS_DIR" ]; then
    for af in "$AGENTS_DIR"/oplan*; do
      [ -f "$af" ] || continue
      AP=$(grep '^pane_id=' "$af" 2>/dev/null | cut -d= -f2)
      if [[ -n "$AP" && "$AP" == "$MY_PANE" ]]; then
        IS_OPLAN_AGENT=1
        break
      fi
    done
  fi
fi

# === 허용/차단 결정 ===
FILE_EXISTS=0
[ -f "$TARGET" ] && FILE_EXISTS=1

HAS_WRITTEN=0
[ -f "$WRITTEN_MARK" ] && HAS_WRITTEN=1

# 이미 쓰기 완료 마크 → 모든 호출자 차단 (1회 제한)
if [[ $HAS_WRITTEN -eq 1 ]]; then
  _block "already_written_once_immutable"
fi

# 파일이 이미 존재 → 호출자 무관 수정/재생성 차단
if [[ $FILE_EXISTS -eq 1 ]]; then
  _block "existing_file_no_modify"
fi

# 허용 조건 검사: 둘 중 하나 충족해야 함
if [[ $HAS_FLAG -eq 0 && $IS_OPLAN_AGENT -eq 0 ]]; then
  _block "caller_not_oplan (flag=0 agent=0 pipeline_uuid=${PIPELINE_UUID:-unset})"
fi

# 허용 — 쓰기 1회 제한 마크 선기록 (best-effort)
touch "$WRITTEN_MARK" 2>/dev/null
_log "ALLOW" "oplan_write_granted flag=${HAS_FLAG} oplan_agent=${IS_OPLAN_AGENT}"
exit 0
