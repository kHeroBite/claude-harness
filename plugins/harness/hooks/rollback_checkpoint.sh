#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# rollback_checkpoint.sh — odev 진입 시 git checkpoint 자동 생성
# PreToolUse(Skill) — odev/odev_* 스킬 감지

trap 'exit 0' ERR

INPUT=$(timeout 5 cat 2>/dev/null) || INPUT=""
SKILL=$(echo "$INPUT" | jq -r '(.tool_input.skill // .tool_input.skill_name // empty)' 2>/dev/null || echo "")

# odev 계열만 처리
case "$SKILL" in
  odev|odev_*)
    ;;
  *)
    exit 0
    ;;
esac

# 세션 격리 UUID 결정
source "${HARNESS_HOOK_DIR}/lib/session_id.sh"
resolve_uuid "$INPUT" 2>/dev/null || UUID="${CLAUDE_SESSION_ID}"
[[ -z "$UUID" ]] && exit 0

# 프로젝트 디렉토리로 이동 (CWD 기반 동적 감지 — 다중 프로젝트 호환)
PROJECT_DIR=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
[ -z "$PROJECT_DIR" ] && exit 0
cd "$PROJECT_DIR" 2>/dev/null || exit 0

# HEAD hash 기록 (세션 격리)
mkdir -p "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}"
git rev-parse HEAD > "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/rollback_hash" 2>/dev/null || exit 0
# 사이클46 축① — 반대편 base 에도 미러 (읽는 쪽이 다른 base 를 볼 수 있다)
source "${HARNESS_HOOK_DIR}/lib/session_mirror.sh" 2>/dev/null
type _mirror_file >/dev/null 2>&1 && _mirror_file "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/rollback_hash"

# 태그 생성
TAG_NAME="odev-checkpoint-$(date +%Y%m%d-%H%M%S)"
git tag "$TAG_NAME" 2>/dev/null || true

# 이전 체크포인트 정리 (최근 5개만 유지)
CHECKPOINTS=$(git tag -l 'odev-checkpoint-*' --sort=-creatordate 2>/dev/null)
COUNT=0
while IFS= read -r tag; do
  [[ -z "$tag" ]] && continue
  COUNT=$((COUNT + 1))
  if [[ $COUNT -gt 5 ]]; then
    git tag -d "$tag" 2>/dev/null || true
  fi
done <<< "$CHECKPOINTS"

exit 0
