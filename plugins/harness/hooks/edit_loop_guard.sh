#!/usr/bin/env bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# edit_loop_guard.sh — PostToolUse hook
# 동일 파일 반복 편집 루프 감지 (P0 — Anthropic "재앙의 악순환" 방지)
# 트리거: mcp__oio__file_edit 도구 사용 후

set -euo pipefail

# F-NEW-3: flock 기반 state_read() 로드
source "${HARNESS_HOOK_DIR}/lib/session_id.sh" 2>/dev/null || true

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_name',''))" 2>/dev/null || echo "")

# file_edit 이벤트만 처리
if [[ "$TOOL_NAME" != "mcp__oio__file_edit" ]]; then
  exit 0
fi

# 편집된 파일 경로 추출
FILE_PATH=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); params=d.get('tool_input',{}); print(params.get('path') or params.get('file_path',''))" 2>/dev/null || echo "")

if [[ -z "$FILE_PATH" ]]; then
  exit 0
fi

# UUID 추출 — PIPELINE_UUID 환경변수 우선, 없으면 DEV 상태 파일 탐색
# ⚠️ head -1 방식 금지: 28개+ 세션 중 다른 세션 UUID를 잡아 오탐 발생
# [P2-isolation] PIPELINE_UUID 없으면 즉시 종료 — 타 세션 UUID 탐색(session-env/*/) 금지.
# DEV 단계는 팀에이전트가 처리하므로 PIPELINE_UUID가 반드시 있어야 함.
if [[ -n "${PIPELINE_UUID:-}" ]]; then
  UUID_DIR="$PIPELINE_UUID"
else
  exit 0
fi

if [[ -z "$UUID_DIR" ]]; then
  exit 0
fi

STATE=$(state_read "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID_DIR}/state" 2>/dev/null | awk '{print $1}' || echo "IDLE")  # F-NEW-3

# DEV 상태에서만 추적
if [[ "$STATE" != "DEV" ]]; then
  exit 0
fi

# 편집 카운트 파일 경로 (파일 경로를 해시로 변환)
COUNTER_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID_DIR}/edit_counts"
mkdir -p "$COUNTER_DIR"
FILE_HASH=$(echo "$FILE_PATH" | md5sum | cut -d' ' -f1)
COUNTER_FILE="${COUNTER_DIR}/${FILE_HASH}"

# 카운트 증가
if [[ -f "$COUNTER_FILE" ]]; then
  COUNT=$(cat "$COUNTER_FILE")
  COUNT=$((COUNT + 1))
else
  COUNT=1
fi
echo "$COUNT" > "$COUNTER_FILE"

# 임계값 초과 시 경고
THRESHOLD=5
if [[ "$COUNT" -ge "$THRESHOLD" ]]; then
  FILENAME=$(basename "$FILE_PATH")
  echo "⚠️ [LOOP_DETECTED] 동일 파일 ${COUNT}회 편집: ${FILENAME}" >&2
  echo "   경로: ${FILE_PATH}" >&2
  echo "   → 반복 편집 루프 가능성. odev에 현황 보고 후 접근 방식 재검토를 권고합니다." >&2
fi

exit 0
