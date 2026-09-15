#!/bin/bash
# 배포본 hook 전체가 공통으로 읽는 프리앰블 — hook 디렉토리 해석과 tmux 부재 가드를 제공한다.
#
# 이 파일은 각 hook 상단에서 source 된다. 절대 exit 하지 않는다.
# hook 은 모든 도구 호출 경로를 거치므로, 여기서 죽으면 하네스 전체가 멈춘다.

# ── 1. HARNESS_HOOK_DIR — hook 스크립트 자기 위치 (lib 로드 기준) ──
# 우선순위: 이미 설정됨 > ${CLAUDE_PLUGIN_ROOT}/hooks > 이 파일의 실제 위치
# ★ 세션 상태 경로(session-env/, teams/)와 혼동하지 마라.
#   상태 경로는 ${CLAUDE_CONFIG_DIR:-$HOME/.claude} 이고, 여기는 스크립트 위치다.
if [ -z "${HARNESS_HOOK_DIR:-}" ]; then
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -d "${CLAUDE_PLUGIN_ROOT}/hooks" ]; then
    HARNESS_HOOK_DIR="${CLAUDE_PLUGIN_ROOT}/hooks"
  else
    # 폴백: 이 파일이 놓인 디렉토리 (플러그인 밖 직접 배치 / 테스트 실행 대응)
    HARNESS_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
  fi
fi
export HARNESS_HOOK_DIR

# ── 2. tmux 부재 가드 ──
# tmux 가 없으면 HARNESS_NO_TMUX=1 을 세우고, tmux 를 no-op 로 덮어 rc=0 을 보장한다.
# 배경: tmux 실행 hook 7개는 전부 `2>/dev/null || echo ""` 폴백을 갖지만,
#       tmux 호출이 hook 의 마지막 명령 위치에 오면 command-not-found rc(127)가
#       그대로 hook 종료코드가 되어 PreToolUse 에서 도구 호출을 오차단할 수 있다.
#       함수로 덮으면 호출부를 건드리지 않고 rc=0 + 빈 출력이 되어 기존 폴백이 정상 작동한다.
if ! command -v tmux >/dev/null 2>&1; then
  export HARNESS_NO_TMUX=1
  tmux() { return 0; }
  export -f tmux 2>/dev/null || true
else
  export HARNESS_NO_TMUX=0
fi

# ★ 반환값 고정 — 프리앰블 자체가 hook 의 rc 를 오염시키지 않도록 한다.
:
