#!/bin/bash
# 다중 세션 git 정책(worktree 의무·바로 push) 위반 가능성에 additionalContext 경고만 붙이는 PreToolUse hook (차단 없음)
#
# 계획 conv_179358081232 §5.2. 이 파일은 빠른 거름 + wt_lib.py guard 호출만 한다(판정 본체는 wt_lib.py).
# - permissionDecision 을 내지 않는다(사용자 결정: 경고만, 차단 없음). 항상 exit 0.
# - wt_lib 가 없거나 실패·시간 초과하면 무출력으로 통과한다(실패가 작업을 막지 않는다 — time_budget open).
# - 빠른 거름: 입력의 모든 절대경로 토큰과 cwd 가 "저장소 루트(.git + .claude)" 또는 role_paths.json 보유 프로젝트 아래가 아니면 python 을 띄우지 않는다.
# - 이 파일·시험 로그 이름에 승격기(gp_gate) 대상 이름을 넣지 않는다(중첩 방지).
INPUT=$(timeout 5 cat 2>/dev/null) || INPUT=""
[ -z "$INPUT" ] && exit 0

# 1) 도구 종류 거름: 파일 쓰기 계열과 셸 실행만 본다.
_TOOL=""
[[ "$INPUT" =~ \"tool_name\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]] && _TOOL="${BASH_REMATCH[1]}"
case "$_TOOL" in
  *file_write|*file_edit|*file_delete|*file_rename|*file_move|*file_copy|*file_symlink|\
  *dir_create|*dir_delete|*dir_move|*dir_rename|Write|Edit|MultiEdit|NotebookEdit)
    ;;
  *bash_exec|Bash)
    # 셸은 git 이 들어간 명령과 worktree 폴더를 건드리는 명령(rm -rf 등)만 본다.
    [[ "$INPUT" == *git* || "$INPUT" == *worktrees* ]] || exit 0
    ;;
  *) exit 0 ;;
esac

# 2) 저장소 거름: cwd + 입력 속 절대경로 토큰 중 하나라도 정책 저장소 후보(.git 와 .claude 가 함께 있는 조상)가 있어야 한다.
_CWD=""
[[ "$INPUT" =~ \"cwd\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]] && _CWD="${BASH_REMATCH[1]}"
[ -z "$_CWD" ] && _CWD="$PWD"

_cand() {
  local d="$1"
  while [ -n "$d" ]; do
    if [ -e "$d/.git" ] && [ -d "$d/.claude" ]; then return 0; fi
    # git 정책과 무관한 롤 경고 경로: 조상에 role_paths.json 이 있으면 통과(롤 경고 회귀 방지)
    if [ -f "$d/.claude/role_paths.json" ]; then return 0; fi
    [ "$d" = "/" ] && break
    d="${d%/*}"; [ -z "$d" ] && d="/"
  done
  return 1
}

_HIT=0
_cand "$_CWD" && _HIT=1
if [ "$_HIT" = 0 ]; then
  _RE='(/[^[:space:]"\\'"'"';&|<>()]+)'
  _rest="$INPUT"; _n=0
  while [ "$_n" -lt 40 ] && [[ "$_rest" =~ $_RE ]]; do
    _tok="${BASH_REMATCH[1]}"
    _rest="${_rest#*"$_tok"}"
    _n=$((_n + 1))
    _cand "${_tok%/*}" && { _HIT=1; break; }
    _cand "$_tok" && { _HIT=1; break; }
  done
fi
[ "$_HIT" = 1 ] || exit 0

# 3) wt_lib 위치: hook 옆 lib → 설정 디렉터리 lib. 없으면 통과.
_HD="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
_LIB="$_HD/lib/wt_lib.py"
[ -r "$_LIB" ] || _LIB="${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/wt_lib.py"
[ -r "$_LIB" ] || exit 0

# 내부 제한 2초(등록 time_budget 2.5s 보다 짧게). 시간 초과(rc=124)는 조용히 통과하지 않고 짧은 ⚠️ 를 낸다.
_OUT=$(printf '%s' "$INPUT" | timeout 2 python3 -B "$_LIB" guard 2>/dev/null); _RC=$?
if [ "$_RC" = 124 ]; then
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"⚠️ [wt 가드] 판정 시간 초과(2초) — worktree·롤 경고를 판정하지 못했다. 원본 폴더 직접 쓰기·git push 여부를 스스로 확인하라(경고만 — 차단 아님)."}}'
  exit 0
fi
[ "$_RC" = 0 ] || _OUT=""
[ -z "$_OUT" ] && exit 0

# 4) 안전망: 차단·허가 판정 키가 섞여 나오면 걷어낸다(경고 전용 불변식).
if [[ "$_OUT" == *permissionDecision* || "$_OUT" == *'"decision"'* || "$_OUT" == *'"continue"'* || "$_OUT" == *stopReason* ]]; then
  _OUT=$(printf '%s' "$_OUT" | timeout 1 python3 -B -I -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except ValueError:
    sys.exit(0)
if not isinstance(d, dict):
    sys.exit(0)
for k in ("decision", "reason", "continue", "stopReason", "suppressOutput"):
    d.pop(k, None)
h = d.get("hookSpecificOutput")
if isinstance(h, dict):
    for k in ("permissionDecision", "permissionDecisionReason"):
        h.pop(k, None)
    if not (h.get("additionalContext") or h.get("updatedInput")):
        sys.exit(0)
print(json.dumps(d, ensure_ascii=False))
' 2>/dev/null) || _OUT=""
fi
[ -n "$_OUT" ] && printf '%s\n' "$_OUT"
exit 0
