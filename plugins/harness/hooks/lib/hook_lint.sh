#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# hook_lint.sh — PreToolUse hook의 log_hook_error 누락 검증 (L-074 강제화)
# 사용법: bash hook_lint.sh [파일 또는 디렉토리]
# 인자 없으면 ~/.claude/hooks/ 전체 검사
# exit 0 = 통과, exit 1 = 위반 발견

HOOKS_DIR="${1:-$HOME/.claude/hooks}"
VIOLATIONS=0
CHECKED=0

check_file() {
  local file="$1"
  local basename
  basename=$(basename "$file")

  # .sh 파일만 검사
  [[ "$file" != *.sh ]] && return 0

  # lib/ 디렉토리는 스킵
  [[ "$file" == */lib/* ]] && return 0

  # deprecated 파일 스킵
  [[ "$file" == *.deprecated ]] && return 0

  # PreToolUse hook인지 확인 (주석에 PreToolUse 포함)
  if ! grep -q 'PreToolUse' "$file" 2>/dev/null; then
    return 0
  fi

  CHECKED=$((CHECKED + 1))

  # exit 2가 있는 줄 번호 수집
  local exit2_lines
  exit2_lines=$(grep -n 'exit 2' "$file" 2>/dev/null | grep -v '^\s*#' | cut -d: -f1)

  if [ -z "$exit2_lines" ]; then
    return 0
  fi

  # 각 exit 2에 대해 앞 5줄 이내에 log_hook_error가 있는지 확인
  while IFS= read -r line_num; do
    [ -z "$line_num" ] && continue

    # exit 2가 trap 내부에 있는지 확인 (trap 내부는 예외)
    local line_content
    line_content=$(sed -n "${line_num}p" "$file")
    if echo "$line_content" | grep -q 'trap'; then
      continue
    fi

    # 앞 5줄 검사
    local start=$((line_num - 5))
    [ "$start" -lt 1 ] && start=1
    local context
    context=$(sed -n "${start},${line_num}p" "$file")

    if ! echo "$context" | grep -q 'log_hook_error'; then
      echo "❌ ${basename}:${line_num} — exit 2 앞에 log_hook_error 호출 누락"
      VIOLATIONS=$((VIOLATIONS + 1))
    fi
  done <<< "$exit2_lines"
}

# 단일 파일 또는 디렉토리 처리
if [ -f "$HOOKS_DIR" ]; then
  check_file "$HOOKS_DIR"
elif [ -d "$HOOKS_DIR" ]; then
  for f in "$HOOKS_DIR"/*.sh; do
    [ -f "$f" ] || continue
    check_file "$f"
  done
fi

if [ "$VIOLATIONS" -gt 0 ]; then
  echo ""
  echo "🚫 검사 결과: ${CHECKED}개 PreToolUse hook 중 ${VIOLATIONS}건 위반"
  echo "   모든 exit 2 (block) 경로에 log_hook_error() 호출을 추가하세요."
  echo "   참조: lib/write_error.sh의 log_hook_error 함수"
  exit 1
else
  echo "✅ 검사 통과: ${CHECKED}개 PreToolUse hook — log_hook_error 누락 없음"
  exit 0
fi
