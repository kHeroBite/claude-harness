#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# PostToolUse_const_reload.sh — const.py 수정 시 현재 Claude 자식 oio만 재시작
# 트리거: settings.json PostToolUse matcher "mcp__oio__file_edit|mcp__oio__file_write"
# 조건: tool_input.path가 hooks/lib/const.py로 끝남 (표준: .claude/hooks/lib, 플러그인: plugins/harness/hooks/lib)
# 효과: 현재 Claude Code의 직계 자식 oio 프로세스에만 SIGTERM (다른 세션 영향 없음)
# 원인 6 대응

set +e
INPUT=$(timeout 2 cat 2>/dev/null) || INPUT=""
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || TOOL_NAME=""
TARGET_PATH=$(echo "$INPUT" | jq -r '.tool_input.path // .tool_input.file_path // empty' 2>/dev/null) || TARGET_PATH=""

# const.py 수정만 대상 (설치 환경 무관 — hooks/lib/const.py로 끝나는 경로면 매칭)
[[ "$TARGET_PATH" =~ hooks/lib/const\.py$ ]] || exit 0

# 현재 hook을 호출한 Claude Code의 PID 탐색 (부모 체인 따라 올라감)
CUR=$$
CLAUDE_PID=""
while true; do
    PARENT=$(ps -o ppid= -p "$CUR" 2>/dev/null | tr -d ' ')
    [[ -z "$PARENT" || "$PARENT" -le 1 ]] && break
    CMDLINE=$(cat /proc/"$PARENT"/cmdline 2>/dev/null | tr '\0' ' ')
    if [[ "$CMDLINE" =~ claude ]] && [[ ! "$CMDLINE" =~ "--agent-id" ]]; then
        CLAUDE_PID="$PARENT"
        break
    fi
    CUR="$PARENT"
done

if [[ -z "$CLAUDE_PID" ]]; then
    echo "[const_reload] Claude Code PID 탐색 실패 — 재시작 스킵" >&2
    exit 0
fi

# CLAUDE_PID의 직계 자식 중 oio만 찾아 SIGTERM
KILLED=0
for CHILD in $(pgrep -P "$CLAUDE_PID" 2>/dev/null); do
    CHILD_CMD=$(cat /proc/"$CHILD"/cmdline 2>/dev/null | tr '\0' ' ')
    if [[ "$CHILD_CMD" =~ oio-mcp-server/server\.py ]]; then
        kill -TERM "$CHILD" 2>/dev/null
        echo "[const_reload] oio pid=$CHILD SIGTERM 발송 — /mcp 재연결 필요" >&2
        KILLED=$((KILLED + 1))
    fi
done

if [[ "$KILLED" -gt 0 ]]; then
    echo "⚠ const.py 변경 감지 — oio 서버 재시작됨 ($KILLED개). 다음 도구 호출 시 /mcp로 재연결하세요." >&2
fi

exit 0
