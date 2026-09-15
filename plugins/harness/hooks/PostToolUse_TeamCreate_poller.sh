#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# PostToolUse_TeamCreate_poller.sh — TeamCreate 성공 후 bash_orphan_poller 자동 시작
# PostToolUse:TeamCreate hook
# 목적: 팀에이전트가 bash로 탈출했을 때 메인 action 없이 자동 kill되도록
#        bash_orphan_poller.sh를 백그라운드 daemon으로 실행

trap 'exit 0' ERR

INPUT=$(timeout 5 cat 2>/dev/null) || INPUT=""

# UUID 결정
source "${HARNESS_HOOK_DIR}/lib/session_id.sh" 2>/dev/null || exit 0
if ! resolve_uuid "$INPUT" 2>/dev/null; then
  exit 0
fi
[[ -z "$UUID" ]] && exit 0

CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SESSION_DIR="$CLAUDE_CONFIG_DIR/session-env/$UUID"
PID_FILE="$SESSION_DIR/orphan_poller.pid"

# 이미 실행 중이면 스킵
if [[ -f "$PID_FILE" ]]; then
  OLD_PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
  if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
    exit 0
  fi
fi

# poller 스크립트 위치 결정 (심볼릭링크 경유 없이 실제 경로 사용)
POLLER_CANDIDATES=(
  "$(readlink -f "${HARNESS_HOOK_DIR}/lib/bash_orphan_poller.sh" 2>/dev/null || echo "")"
  "${HARNESS_HOOK_DIR}/lib/bash_orphan_poller.sh"
)
POLLER=""
for _p in "${POLLER_CANDIDATES[@]}"; do
  [[ -n "$_p" && -f "$_p" ]] && POLLER="$_p" && break
done

if [[ -z "$POLLER" ]]; then
  exit 0
fi

# 로그 디렉토리 생성
mkdir -p "$SESSION_DIR/logs" 2>/dev/null || true

# 백그라운드 daemon 시작
nohup bash "$POLLER" "$UUID" >> "$SESSION_DIR/logs/orphan_poller.log" 2>&1 &
# 사이클46 축① — 로그 미러 (내용·시점·조건 무변, 경로 정합만)
source "${HARNESS_HOOK_DIR}/lib/session_mirror.sh" 2>/dev/null
type _mirror_file >/dev/null 2>&1 && _mirror_file "$SESSION_DIR/logs/orphan_poller.log"
disown $!

exit 0
