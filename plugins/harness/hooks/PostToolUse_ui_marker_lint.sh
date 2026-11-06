#!/bin/bash
# UI 테스트 완료 마커(ui·winforms·web_test_done)를 쓴 직후 v2 형식을 검사해 위반 사유를 에이전트에게 돌려주는 PostToolUse hook
#
# 대상 도구: mcp__oio__file_write|mcp__oio__file_edit|Write|Edit (경로 필드)
#            mcp__oio__bash_exec|Bash (명령 문자열 안의 마커 경로)
# 대상 경로: */session-env/<UUID>/evidence/{ui_test_done,winforms_test_done,web_test_done}
# 판정: lib/ui_marker_check.sh 의 ui_marker_valid (v2 파서 단일 출처 — 여기서 형식을 다시 정의하지 않는다)
#   1줄  : PASS|PARTIAL|FAIL <ISO8601>
#   2줄~ : evidence: <절대경로>  (1줄 이상, 실존 정규 파일, mtime ≥ pipeline_start_time)
# 출력: 위반 시 {"decision":"block","reason":...}. PostToolUse 의 block 은 쓰기를 되돌리지 않고
#       reason 을 도구 결과 옆에 붙여 에이전트에게 보여 준다(공식 hooks 문서 PostToolUse decision control).
# 실패 안전: lint 성격이라 lib·jq 부재, 내부 오류는 모두 exit 0(fail-open)이다.
#           fail-open 사유는 hooks/logs/ui_marker_lint.log 에 1줄씩 남긴다(마커 언급 입력에서만).
# 한계: bash 명령의 경로가 변수($S/evidence/...)로만 적혀 있으면 경로를 알 수 없어 검사하지 않는다.
#       최종 차단은 PreToolUse_done_gate.sh·ui_test_done_guard.sh 가 맡는다.

INPUT=$(cat 2>/dev/null) || exit 0
case "$INPUT" in
  *_test_done*) ;;
  *) exit 0 ;;
esac
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0
# fail-open 시 사유 1줄을 hooks/logs/ui_marker_lint.log 에 남긴다(로그 실패는 무시)
_fo() {
  { mkdir -p "$HOOK_DIR/logs" && printf '%s FAIL_OPEN %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$HOOK_DIR/logs/ui_marker_lint.log"; } 2>/dev/null
  exit 0
}
command -v jq >/dev/null 2>&1 || _fo "jq 없음"
LIB="$HOOK_DIR/lib/ui_marker_check.sh"
[ -f "$LIB" ] || _fo "lib 없음: $LIB"
# shellcheck source=/dev/null
. "$LIB" 2>/dev/null || _fo "lib source 실패: $LIB"
command -v ui_marker_valid >/dev/null 2>&1 || _fo "ui_marker_valid 함수 없음: $LIB"

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null) || _fo "입력 JSON 판독 실패"
# 도구가 실패했다고 보고하면 파일이 바뀌지 않았으므로 검사하지 않는다
OKFLAG=$(printf '%s' "$INPUT" | jq -r 'if (.tool_response|type)=="object" and (.tool_response|has("success")) then (.tool_response.success|tostring) else "true" end' 2>/dev/null)
[ "$OKFLAG" = "false" ] && exit 0

CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# 후보 문자열 → 마커 절대경로(대상 이름·session-env/<UUID>/evidence 구조가 맞을 때만) 출력
_mk_resolve() {
  local p="$1" base rest
  p="${p%$'\r'}"
  base=$(basename -- "$p" 2>/dev/null)
  case "$base" in
    ui_test_done|winforms_test_done|web_test_done) ;;
    *) return 1 ;;
  esac
  case "$p" in
    */session-env/*/evidence/"$base") ;;
    *) return 1 ;;
  esac
  case "$p" in
    /*) ;;
    *)
      # $HOME/… · ~/… · ${CLAUDE_CONFIG_DIR…}/… 처럼 앞부분이 풀리지 않은 경로는 session-env 이후만 살려 CFG 기준으로 푼다
      rest="session-env/${p#*session-env/}"
      p="$CFG/$rest"
      ;;
  esac
  # evidence 직속이어야 한다(session-env/<UUID>/evidence/<마커>)
  case "$(basename -- "$(dirname -- "$(dirname -- "$(dirname -- "$p")")")")" in
    session-env) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$p"
}

CANDS=""
case "$TOOL" in
  mcp__oio__file_write|mcp__oio__file_edit|Write|Edit)
    CANDS=$(printf '%s' "$INPUT" | jq -r '.tool_input | (.path // .file_path // .filepath // "")' 2>/dev/null)
    ;;
  mcp__oio__bash_exec|Bash)
    CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input | (.command // .cmd // "")' 2>/dev/null)
    CANDS=$(printf '%s' "$CMD" | grep -oE "[^[:space:]\"'\`;|&<>()=]*_test_done[A-Za-z0-9_.]*" 2>/dev/null)
    ;;
  *) exit 0 ;;
esac
[ -n "$CANDS" ] || exit 0

REASONS=""
SEEN=" "
while IFS= read -r c; do
  [ -n "$c" ] || continue
  mk=$(_mk_resolve "$c") || continue
  case "$SEEN" in *" $mk "*) continue ;; esac
  SEEN="$SEEN$mk "
  # 삭제(rm) 등으로 파일이 없으면 쓰기 검사 대상이 아니다
  [ -e "$mk" ] || continue
  sd=$(dirname -- "$(dirname -- "$mk")")
  start=$(ui_pipeline_start "$sd" 2>/dev/null) || start=""
  if ! ui_marker_valid "$mk" "$start" 2>/dev/null; then
    r=$(ui_marker_block_reason "$sd" "쓰기 직후 형식 검사(PostToolUse_ui_marker_lint) — 방금 쓴 마커가 v2 형식이 아니다. 쓰기는 이미 반영됐으므로 아래 형식으로 다시 써라" 2>/dev/null)
    [ -n "$r" ] || r="❌ [ui_marker_lint] ${mk}: ${UMC_FAIL_REASON} — v2 형식: 첫 줄 'PASS|PARTIAL|FAIL <ISO8601>', 이어서 'evidence: <절대경로>' 1줄 이상"
    REASONS="${REASONS:+$REASONS
}$r"
  fi
done <<EOF
$CANDS
EOF

[ -n "$REASONS" ] || exit 0
ui_block_json "$REASONS" 2>/dev/null
exit 0
