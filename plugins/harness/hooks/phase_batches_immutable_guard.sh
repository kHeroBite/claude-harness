#!/bin/bash
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
source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/write_error.sh" 2>/dev/null || {
  # 유틸 미존재 시 최소 대체 (에러 기록 실패해도 차단은 진행)
  log_hook_error() { :; }
}

INPUT=$(timeout 2 cat 2>/dev/null) || INPUT=""
[[ -z "$INPUT" ]] && exit 0

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || TOOL_NAME=""
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null) || SESSION_ID=""

# 쓰기 계열만 검사
case "$TOOL_NAME" in
  mcp__oio__file_write|mcp__oio__file_edit|mcp__oio__file_delete|mcp__oio__file_rename|mcp__oio__file_move|mcp__oio__file_copy|mcp__oio__file_symlink|Edit|Write) ;;
  *) exit 0 ;;
esac

# 대상 경로 추출 — 도구별로 검사할 경로가 다르다(줄바꿈 구분 목록).
#   copy·symlink: 새로 만들어지는 목적지(복사 원본·symlink 가 가리키는 원본은 읽기라 제외 — archive 복사 정당 경로)
#   move: 원본과 목적지 양쪽 / rename: 원본과 새 이름(같은 디렉터리) 양쪽
#   그 외: 종전 순서(file_path/path/…)로 첫 경로 하나
# 필드 별칭은 oio server.py 시그니처를 따른다.
TARGETS=$(echo "$INPUT" | jq -r --arg tool "$TOOL_NAME" '
  .tool_input as $i |
  if $tool == "mcp__oio__file_copy" then
    ($i.destination // $i.dest // $i.dst // $i.to // $i.target // empty)
  elif $tool == "mcp__oio__file_symlink" then
    ($i.link_path // $i.path // $i.dest // $i.link // empty)
  elif $tool == "mcp__oio__file_move" then
    (($i.source // $i.src // $i.path // $i.file_path // empty),
     ($i.destination // $i.dest // $i.dst // $i.to // $i.target // empty))
  elif $tool == "mcp__oio__file_rename" then
    (($i.path // $i.file_path // empty) as $p |
     $p,
     (($i.new_name // $i.name // $i.to // $i.new_path // empty) as $n |
      if $n == "" then empty elif ($n | contains("/")) then $n
      else (($p | sub("[^/]*$"; "")) + $n) end))
  else
    ($i.file_path // $i.path // $i.filepath //
     $i.old_path // $i.src // $i.source //
     $i.new_path // $i.dst // $i.destination // empty)
  end
' 2>/dev/null)
[[ -z "$TARGETS" ]] && exit 0

# phase_batches.json 여부 확인 — 파일 이름이 정확히 phase_batches.json 일 때만(c183 B8)
#   종전 *phase_batches.json 은 ok_pipeline 4.5단계 루프 상태 파일 active_phase_batches.json(메인이 갱신하는 가변 파일)까지
#   불변으로 잡아 Auto-Loop 기록을 막았다(로그 10-12 07:08·10-13 20:11 실측). 불변 대상은 oplan 산출물 하나뿐이다.
TARGET=""
while IFS= read -r _t; do
  [[ -z "$_t" ]] && continue
  case "${_t##*/}" in
    phase_batches.json) TARGET="$_t"; break ;;
  esac
done <<< "$TARGETS"
[[ -z "$TARGET" ]] && exit 0

# UUID 확정 (대상 경로의 session-env/<UUID> 우선 → PIPELINE_UUID → hook 입력 session_id)
# 사이클172 수정: 종전엔 session_id 를 먼저 썼다. 팀원 프로세스의 session_id 는 팀원 자신의 세션 ID 라
#   리드 세션 디렉토리의 oplan_writing_phase_batches 플래그를 찾지 못해 oplan 팀원의 정당한 쓰기가 차단됐다.
UUID=$(echo "$TARGET" | sed -n 's#.*/session-env/\([0-9a-f-]\{36\}\)/.*#\1#p')
[[ -z "$UUID" ]] && UUID="${PIPELINE_UUID:-}"
[[ -z "$UUID" ]] && UUID="$SESSION_ID"
[[ -z "$UUID" ]] && UUID="unknown"

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

# (c) [사이클196 oi-fix-1 P4] 부모 프로세스 체인의 팀원 식별자로 oplan 팀원을 판별한다.
#   (b) 는 환경변수 PIPELINE_UUID 를 전제로 했는데, 팀원 프로세스 environ 에는 이 변수가 없다(2026-10-23 실측 —
#   PIPELINE_UUID 는 프롬프트 글자일 뿐). 그래서 c196 oplan 팀원의 정당한 신규 쓰기가 caller_not_oplan 으로 막혔다.
#   식별 근거: 조상 claude 프로세스 cmdline 의 --agent-id NAME@TEAM 과 --parent-session-id LEAD(lib/chain_agent.sh 와 같은 방식).
#   허용 조건: NAME 이 oplan 으로 시작 + LEAD 가 대상 세션 UUID + 그 세션의 team_name 이 TEAM(세션 격리 소유 검증).
#   승격기가 사본 트리에서 실행하므로 lib 를 source 하지 않고 같은 로직을 여기 둔다.
#   시험 전용: PB_CA_TEST=1 이면 PB_CA_TEST_AGENT=NAME@TEAM, PB_CA_TEST_LEAD=<uuid> 를 쓴다(hook 환경은 하네스가 정하므로 에이전트가 못 바꾼다).
IS_OPLAN_CHAIN=0
_pb_chain_agent=""; _pb_chain_lead=""
if [[ "${PB_CA_TEST:-}" == "1" ]]; then
  _pb_chain_agent="${PB_CA_TEST_AGENT:-}"; _pb_chain_lead="${PB_CA_TEST_LEAD:-}"
else
  _pb_pid=$$
  for _pb_i in 1 2 3 4 5 6 7 8; do
    [[ "$_pb_pid" =~ ^[0-9]+$ ]] && (( _pb_pid > 1 )) || break
    if [[ -r "/proc/$_pb_pid/cmdline" ]]; then
      _pb_nxt=""
      while IFS= read -r -d '' _pb_a; do
        if [[ "$_pb_nxt" == "agent" ]]; then _pb_chain_agent="$_pb_a"; _pb_nxt=""
        elif [[ "$_pb_nxt" == "lead" ]]; then _pb_chain_lead="$_pb_a"; _pb_nxt=""
        elif [[ "$_pb_a" == "--agent-id" ]]; then _pb_nxt="agent"
        elif [[ "$_pb_a" == "--parent-session-id" ]]; then _pb_nxt="lead"
        fi
      done < "/proc/$_pb_pid/cmdline"
      [[ -n "$_pb_chain_agent" ]] && break
    fi
    _pb_s=$(<"/proc/$_pb_pid/stat") || break
    _pb_s="${_pb_s##*) }"
    read -r _ _pb_pid _ <<<"$_pb_s"
  done
fi
if [[ "$_pb_chain_agent" == *@* && "$_pb_chain_lead" == "$UUID" ]]; then
  _pb_name="${_pb_chain_agent%%@*}"; _pb_team="${_pb_chain_agent#*@}"
  if [[ "$_pb_name" =~ ^oplan[A-Za-z0-9._-]*$ && "$_pb_team" =~ ^[A-Za-z0-9._-]+$ && -f "${SESSION_DIR}/team_name" ]] \
     && [[ "$(tr -d '[:space:]' < "${SESSION_DIR}/team_name" 2>/dev/null)" == "$_pb_team" ]]; then
    IS_OPLAN_CHAIN=1
  fi
fi

# === 허용/차단 결정 ===
FILE_EXISTS=0
[ -f "$TARGET" ] && FILE_EXISTS=1

HAS_WRITTEN=0
[ -f "$WRITTEN_MARK" ] && HAS_WRITTEN=1

# 이전 사이클 표식 무시 (L-599 보조 방어 — PreToolUse_pipeline_entry_reset.sh 가 반영되기 전 활성 세션용)
#   표식 mtime 이 이번 파이프라인 시작 시각(pipeline_start_time, epoch 정수)보다 이전이면 이전 사이클 표식이다.
#   시작 시각 파일이 없거나 정수가 아니면 기존 동작(차단)을 유지한다 — fail-closed.
if [[ $HAS_WRITTEN -eq 1 ]]; then
  _START=""
  for _sf in "${SESSION_DIR}/pipeline_start_time" "$HOME/.claude/session-env/${UUID}/pipeline_start_time"; do
    [ -f "$_sf" ] || continue
    _START=$(head -n1 "$_sf" 2>/dev/null | tr -d '[:space:]')
    break
  done
  _MARK_MTIME=$(stat -c %Y "$WRITTEN_MARK" 2>/dev/null)
  if [[ "$_START" =~ ^[0-9]+$ && "$_MARK_MTIME" =~ ^[0-9]+$ ]] && (( _MARK_MTIME < _START )); then
    _log "INFO" "STALE_MARK_IGNORED mark_mtime=${_MARK_MTIME} pipeline_start=${_START}"
    HAS_WRITTEN=0
  fi
fi

# 이미 쓰기 완료 마크 → 모든 호출자 차단 (1회 제한)
if [[ $HAS_WRITTEN -eq 1 ]]; then
  _block "already_written_once_immutable"
fi

# 파일이 이미 존재 → 호출자 무관 수정/재생성 차단
if [[ $FILE_EXISTS -eq 1 ]]; then
  _block "existing_file_no_modify"
fi

# 허용 조건 검사: 셋 중 하나 충족해야 함
if [[ $HAS_FLAG -eq 0 && $IS_OPLAN_AGENT -eq 0 && $IS_OPLAN_CHAIN -eq 0 ]]; then
  _block "caller_not_oplan (flag=0 agent=0 chain=${_pb_chain_agent:-none} pipeline_uuid=${PIPELINE_UUID:-unset}) — 해소: oplan 팀원(--agent-id oplan*@<이 세션 팀>)이 신규 1회 쓰기를 하거나, 메인이 ${WRITE_FLAG##*/} 플래그를 만든 뒤 쓴다"
fi

# 허용 — 쓰기 1회 제한 마크 선기록 (best-effort)
touch "$WRITTEN_MARK" 2>/dev/null
_log "ALLOW" "oplan_write_granted flag=${HAS_FLAG} oplan_agent=${IS_OPLAN_AGENT} oplan_chain=${IS_OPLAN_CHAIN}"
exit 0
