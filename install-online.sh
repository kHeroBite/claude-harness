#!/bin/sh
# install_harness.sh 호환 래퍼 — 구 이름 install-online.sh 로 들어온 호출을 새 설치 스크립트로 넘긴다(deprecated)
echo "안내: install-online.sh 는 install_harness.sh 로 바뀌었다(다음 메이저에서 제거 예정)." >&2
D="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
if [ -f "$D/install_harness.sh" ]; then exec sh "$D/install_harness.sh" "$@"; fi
U="https://raw.githubusercontent.com/kHeroBite/claude-harness/master/install_harness.sh"
T="$(mktemp "${TMPDIR:-/tmp}/install_harness.XXXXXX")" || exit 2
if command -v curl >/dev/null 2>&1; then curl -fsSL "$U" -o "$T"; else wget -qO "$T" "$U"; fi || { echo "오류: install_harness.sh 를 받지 못했다" >&2; rm -f "$T"; exit 2; }
sh "$T" "$@"; rc=$?; rm -f "$T"; exit "$rc"
