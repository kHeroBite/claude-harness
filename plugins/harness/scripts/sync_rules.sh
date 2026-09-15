#!/bin/bash
# 플러그인 안의 rules/harness.md 를 고정 경로 ~/.claude/rules/harness.md 로 동기화하는 SessionStart hook
#
# 왜 필요한가:
#   플러그인 캐시 경로는 버전마다 바뀌므로 CLAUDE.md 의 @import 대상이 될 수 없다.
#   따라서 SessionStart 시점에 고정 경로로 복사해두고, 수신자는 자기 CLAUDE.md 에
#   `@~/.claude/rules/harness.md` 한 줄만 추가한다 (@import 는 ~ 홈 확장을 공식 지원).
#
# 절대 규칙:
#   - 수신자의 CLAUDE.md 는 읽지도 쓰지도 않는다. 자동 삽입 금지 (파괴 위험).
#   - 쓰기 대상은 ~/.claude/rules/harness.md 단 하나다.
#   - 세션 격리 불변식 §(a) 준수 — 타 세션 session-env 를 건드리지 않는다.

trap 'exit 0' ERR

# stdin(hook INPUT JSON)은 사용하지 않지만, 블로킹을 피하기 위해 비운다.
if [ ! -t 0 ]; then
  cat >/dev/null 2>&1 || true
fi

_SRC="${CLAUDE_PLUGIN_ROOT:-}/rules/harness.md"
_DST="${HOME}/.claude/rules/harness.md"

# CLAUDE_PLUGIN_ROOT 미전개 시 이 스크립트 위치로 폴백 (scripts/ → 플러그인 루트 추정)
if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ] || [ ! -f "$_SRC" ]; then
  _SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for _cand in \
    "${_SELF_DIR}/../plugins/harness/rules/harness.md" \
    "${_SELF_DIR}/../rules/harness.md"
  do
    if [ -f "$_cand" ]; then
      _SRC="$_cand"
      break
    fi
  done
fi

# 원본 부재 시 조용히 성공 종료 (하네스 플러그인 미설치 환경에서도 무해)
if [ ! -f "$_SRC" ]; then
  exit 0
fi

mkdir -p "$(dirname "$_DST")" 2>/dev/null || exit 0

# 변경이 있을 때만 복사 (불필요한 mtime 갱신 방지)
if cmp -s "$_SRC" "$_DST" 2>/dev/null; then
  exit 0
fi

if cp "$_SRC" "$_DST" 2>/dev/null; then
  # @import 미등재 시 1회 안내 (수신자 CLAUDE.md 는 건드리지 않고 stdout 안내만 한다)
  _MARK="${HOME}/.claude/rules/.harness_import_notice"
  if [ ! -f "$_MARK" ]; then
    echo "📘 [하네스 규칙] ~/.claude/rules/harness.md 동기화 완료."
    echo "   프로젝트 CLAUDE.md 에 다음 한 줄을 추가하면 규칙이 로딩됩니다."
    echo "   @~/.claude/rules/harness.md"
    : > "$_MARK" 2>/dev/null || true
  fi
fi

exit 0
