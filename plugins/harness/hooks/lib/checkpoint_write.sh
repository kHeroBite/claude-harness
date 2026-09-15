#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# checkpoint_write.sh — checkpoint.jsonl에 이벤트 1줄 atomic append
# 사용법: checkpoint_write.sh "$UUID" "$EVENT" "$STAGE" "$SUBSTEP" "$AGENT" "$DETAIL"
# 예시:   checkpoint_write.sh "abc-123" "DEV_START" "DEV" "" "odev-1" "sonnet spawn"
#
# 실패 시 파이프라인을 중단시키면 안 됨 — silent exit
trap 'exit 0' ERR

UUID="${1:?UUID 필수}"
EVENT="${2:?EVENT 필수}"
STAGE="${3:-}"
SUBSTEP="${4:-}"
AGENT="${5:-}"
DETAIL="${6:-}"

# 타임스탬프 (ISO 8601 UTC)
TS=$(date -u '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || echo "")

# git SHA (짧은 해시, 실패 시 "unknown")
SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "")
SHA="${SHA:-unknown}"

# 세션 디렉토리
DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}"

# 디렉토리 없으면 생성 (최초 호출 시)
mkdir -p "$DIR" 2>/dev/null || true

# DETAIL 내 쌍따옴표/백슬래시 이스케이프 (JSON 안전)
DETAIL=$(echo "$DETAIL" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')

# JSON 1줄 조립 + flock atomic append (동시 쓰기 시 라인 깨짐 방지)
_JSONL_LINE="{\"ts\":\"$TS\",\"event\":\"$EVENT\",\"stage\":\"$STAGE\",\"substep\":\"$SUBSTEP\",\"agent\":\"$AGENT\",\"git_sha\":\"$SHA\",\"detail\":\"$DETAIL\"}"
(
  flock -x 9
  echo "$_JSONL_LINE" >> "$DIR/checkpoint.jsonl"
) 9>"$DIR/checkpoint.jsonl.lock" 2>/dev/null || \
  echo "$_JSONL_LINE" >> "$DIR/checkpoint.jsonl"
