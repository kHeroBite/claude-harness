#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# 메인 에이전트의 ogrill 자율 호출을 차단하는 PreToolUse:Skill hook

set -u

# stdin에서 JSON 입력 읽기 (Claude Code hook 표준)
INPUT=$(cat)

# tool_input.skill 추출 (skill 이름 확인)
SKILL=$(echo "$INPUT" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('tool_input', {}).get('skill', ''))" 2>/dev/null)

# ogrill 호출이 아니면 통과
[ "$SKILL" != "ogrill" ] && exit 0

# 팀에이전트(PIPELINE_UUID 환경변수 보유) → 허용
if [ -n "${PIPELINE_UUID:-}" ]; then
  exit 0
fi

# 메인 에이전트 — session_id로 SESSION_DIR 결정
SESSION_ID=$(echo "$INPUT" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('session_id', ''))" 2>/dev/null)
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SESSION_DIR="$CONFIG_DIR/session-env/$SESSION_ID"
FLAG="$SESSION_DIR/ogrill_slash_flag"

# 사용자 /ogrill 슬래시 마커 존재 → 허용 + 마커 1회성 삭제
if [ -f "$FLAG" ]; then
  rm -f "$FLAG"
  exit 0
fi

# 메인 자율 호출 → 차단
cat <<'JSON'
{"decision": "block", "reason": "❌ ogrill 호출 금지 (메인 에이전트 자율 호출). oplan 팀에이전트만 호출 가능. 사용자는 /ogrill 슬래시 명령으로 직접 호출 가능."}
JSON
exit 0
