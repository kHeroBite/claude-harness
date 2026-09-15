#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# PreToolUse(Bash) — 통합 경로 보호 가드
#
# 1. ~/.claude/session-env/ 루트 보호
#    - session-env/ 바로 아래에는 36자 UUID 형식 디렉토리만 허용
#    - 루트에 직접 파일/디렉토리 생성 차단 (예: session-env/pipeline_uuid, session-env/foo)
#
# 2. /tmp/ 루트 파일 쓰기 — 제한 해제 (더이상 차단 불필요)

trap 'exit 0' ERR
INPUT=$(timeout 5 cat 2>/dev/null) || INPUT=""
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")

# 명령이 없으면 통과
[[ -z "$COMMAND" ]] && exit 0

# ── 1. ~/.claude/session-env/ 루트 쓰기/생성 보호 ──
# 쓰기/생성 명령(>, >>, tee, touch, mkdir, echo >)에서만 UUID 검증
# rm, ls, cat, grep 등 읽기/삭제 명령은 검증 없이 통과
if echo "$COMMAND" | grep -qE '(session-env|\.claude/session-env)'; then
  # 쓰기/생성 패턴인지 먼저 확인
  if echo "$COMMAND" | grep -qE '(>|>>|tee|touch|mkdir)\s.*(session-env)|echo\s.*(session-env).*>'; then
    # session-env/ 바로 다음 경로 추출 (리터럴 문자만)
    CANDIDATE=$(echo "$COMMAND" | grep -oP '(?<=session-env/)[^/${}\s"'\'']+' | head -1 || true)
    # 변수 참조(${UUID}, $UUID, $HOME 등) 포함 여부 확인
    HAS_VAR_REF=$(echo "$COMMAND" | grep -oP 'session-env/[\$\{]' | head -1 || true)
    if [ -z "$CANDIDATE" ]; then
      if [ -n "$HAS_VAR_REF" ]; then
        exit 0  # 변수 참조 사용 → 런타임에 UUID로 확장됨 → 허용
      fi
      # 변수 참조도 없고 리터럴도 없음 → session-env/ 루트 직접 생성 → 차단
      echo "{\"decision\":\"block\",\"reason\":\"❌ session-env/ 루트 보호: UUID가 비어있습니다. session-env/ 하위 경로에 직접 폴더 생성 시도. resolve_uuid 호출을 확인하세요.\"}" | tee /dev/stderr
      exit 2
    fi
    if [ -n "$CANDIDATE" ]; then
      # 변수 참조($), 중괄호({), glob 패턴(*/?/[)은 검증 스킵 (런타임 값)
      if ! echo "$CANDIDATE" | grep -qE '^\$|^\{|[*?\[]'; then
        # 36자 UUID 패턴: 8-4-4-4-12 (소문자 hex + 하이픈)
        if ! echo "$CANDIDATE" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
          echo "{\"decision\":\"block\",\"reason\":\"❌ session-env/ 루트 보호: '${CANDIDATE}'은 36자 UUID 형식이 아닙니다. session-env/ 하위에는 UUID 디렉토리만 허용됩니다. system-reminder의 🆔 [UUID] 값을 사용하세요.\"}" | tee /dev/stderr
          exit 2
        fi
      fi
    fi
  fi
  exit 0
fi

# ── 2. ~/work/ 경로 사용 금지 (폐기됨 → session-env/${UUID}/work/ 사용) ──
# $HOME, ~, /home/{사용자} 모든 변형 감지
EXPANDED_CMD=$(echo "$COMMAND" | sed "s|\\\$HOME|$HOME|g; s|~/|$HOME/|g")
if echo "$EXPANDED_CMD" | grep -qE "$HOME/work(/|$)"; then
  # 읽기/삭제 명령은 허용 (정리용)
  if ! echo "$EXPANDED_CMD" | grep -qE '^\s*(ls|cat|head|tail|grep|find|du|wc|file|stat|rm|rmdir)\s'; then
    echo "{\"decision\":\"block\",\"reason\":\"❌ ~/work/ 경로 사용 금지! 폐기된 작업 디렉토리입니다. \\\${CLAUDE_CONFIG_DIR:-\\\$HOME/.claude}/session-env/\\\${UUID}/work/ 를 사용하세요.\"}" | tee /dev/stderr
    exit 2
  fi
fi

exit 0
