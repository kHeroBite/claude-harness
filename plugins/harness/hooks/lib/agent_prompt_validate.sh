#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# 팀에이전트 prompt 검증 공용 라이브러리

# validate_pipeline_uuid <prompt>
# 팀에이전트 spawn prompt에 PIPELINE_UUID=<36자 UUID> 패턴이 있는지 검증
# 출력: 매칭된 UUID 값 (없으면 빈 문자열)
# 반환: 0 (존재), 1 (없음)
validate_pipeline_uuid() {
  local PROMPT="$1"
  local EXTRACTED
  EXTRACTED=$(echo "$PROMPT" | grep -oE 'PIPELINE_UUID=[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1 | cut -d= -f2)
  if [[ -n "$EXTRACTED" ]]; then
    echo "$EXTRACTED"
    return 0
  fi
  return 1
}

# validate_claude_config_dir <prompt>
# 팀에이전트 spawn prompt에 CLAUDE_CONFIG_DIR=<절대경로> 패턴이 있는지 검증
# 출력: 매칭된 경로 값 (없으면 빈 문자열)
# 반환: 0 (존재), 1 (없음)
validate_claude_config_dir() {
  local PROMPT="$1"
  local EXTRACTED
  EXTRACTED=$(echo "$PROMPT" | grep -oE 'CLAUDE_CONFIG_DIR=/[^[:space:]]+' | head -1 | cut -d= -f2-)
  if [[ -n "$EXTRACTED" ]]; then
    echo "$EXTRACTED"
    return 0
  fi
  return 1
}
