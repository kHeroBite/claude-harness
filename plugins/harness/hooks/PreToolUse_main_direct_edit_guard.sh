#!/usr/bin/env bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# 메인 에이전트가 DEV/TEST/DONE 상태에서 프로젝트 소스를 직접 수정하는 것을 물리 차단한다.
#
# ★왜 만들었나 (2026-09-06 실사고)★
#   중단된 세션을 재개하면서 메인이 W4(가상하위동반이관) 설계·구현·검증을 전부 직접 했다.
#   ok/SKILL.md 는 "PLAN/DEV/TEST/DONE 에서 메인은 팀에이전트에 전면 위임" 이라 명시하지만
#   write_guard.sh 는 이 경로를 rc=0 으로 통과시켰다(실측). 규칙만 있고 강제가 없었다.
#   사용자가 "왜 메인에이전트에서 plan단계가 직접 진행되나" 라고 지적하기 전까지 계속됐다.
#
# 판정: 팀에이전트(PIPELINE_UUID 보유)는 대상 아님 — 그들이 수정하는 것이 정상이다.
#       메인만 검사하며, 상태가 DEV/TEST/DONE 일 때 NTFS 프로젝트 소스 쓰기를 막는다.
set -uo pipefail

INPUT="$(cat 2>/dev/null || true)"
[ -z "$INPUT" ] && exit 0

# 비상 스위치
[ -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/DISABLE_MAIN_EDIT_GUARD" ] && exit 0

# 팀에이전트는 통과 (그들이 수정하는 것이 정상 경로다)
[ -n "${PIPELINE_UUID:-}" ] && exit 0

_get() { printf '%s' "$INPUT" | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
cur=d
for k in '$1'.split('.'):
    cur = cur.get(k) if isinstance(cur,dict) else None
print(cur if cur is not None else '')
" 2>/dev/null; }

TOOL="$(_get tool_name)"
case "$TOOL" in
  mcp__oio__file_edit|mcp__oio__file_write|mcp__oio__file_delete|Edit|Write) ;;
  *) exit 0 ;;
esac

TARGET="$(_get tool_input.path)"
[ -z "$TARGET" ] && TARGET="$(_get tool_input.file_path)"
[ -z "$TARGET" ] && exit 0

# NTFS 프로젝트 소스만 대상. .claude/ 설정·세션 파일은 메인 관할이므로 제외.
case "$TARGET" in
  /mnt/[c-z]/*) ;;
  *) exit 0 ;;
esac
case "$TARGET" in
  */.claude/*|*/session-env/*) exit 0 ;;
esac

SID="$(_get session_id)"
[ -z "$SID" ] && exit 0
# ★경로 분열 대응 (2026-09-06 실측)★
#   CLAUDE_CONFIG_DIR/session-env/<UUID>/ 와 $HOME/.claude/session-env/<UUID>/ 가
#   ★동시에 존재하되 한쪽만 내용을 갖는★ 경우가 있다. 디렉토리 존재 여부로 고르면
#   빈 쪽을 잡아 STATE 가 공백이 되고 가드가 통째로 무력해진다(초기 구현이 이 함정에 빠졌다).
#   ⇒ 디렉토리가 아니라 ★state 파일 실존★ 을 기준으로 고른다.
STATE=""
for _CAND in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${SID}" "$HOME/.claude/session-env/${SID}"; do
    if [ -s "$_CAND/state" ]; then
        STATE="$(awk '{print $1}' "$_CAND/state" 2>/dev/null)"
        [ -n "$STATE" ] && break
    fi
done

case "$STATE" in
  DEV|TEST|DONE) ;;
  *) exit 0 ;;
esac

cat >&2 <<EOF
⛔ [F-MAIN-1] state=${STATE} 에서 메인 에이전트의 프로젝트 소스 직접 수정은 금지다.

대상: ${TARGET}

ok/SKILL.md "상태별_메인_도구_정책" — PLAN/DEV/TEST/DONE 구간에서 메인의 역할은
★오케스트레이션★ 이며 파일 수정은 팀에이전트가 담당한다.
2026-09-06 실사고: 세션 재개 후 메인이 설계·구현·검증을 전부 직접 수행했다.

올바른 경로:
  Agent(subagent_type="general-purpose", name="odev-N",
        team_name="\$(cat \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/session-env/\${UUID}/team_name)",
        mode="bypassPermissions", prompt="PIPELINE_UUID=...\\nCLAUDE_CONFIG_DIR=...\\n{작업}")

비상 우회가 꼭 필요하면: hooks/DISABLE_MAIN_EDIT_GUARD 파일 생성.
EOF
exit 2
