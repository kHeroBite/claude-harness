#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# git ls-tree/ls-files 의 한글 파일명 8진 이스케이프 누락을 경고하는 PreToolUse hook (경고 전용 — 절대 차단하지 않음)
#
# ─────────────────────────────────────────────────────────────────────────────
# 신설 사유 (사이클128 T-C1)
# ─────────────────────────────────────────────────────────────────────────────
# git 의 `core.quotepath` 기본값(true)은 비ASCII 파일명을 8진 이스케이프 + 따옴표로
# 감싸서 출력한다. 예:
#     git ls-tree -r --name-only HEAD
#     → "src/1002_\354\227\260\352\263\204\353\217\204\355\214\235\354\227\205.Designer.cs"
#
# 실측 (한글 파일명이 다수인 저장소, HEAD 기준):
#     git ls-tree -r --name-only HEAD | grep -c '\.cs$'                        → 287
#     git -c core.quotepath=false ls-tree -r --name-only HEAD | grep -c '\.cs$' → 406
#     git ls-tree -r --name-only -z HEAD | tr '\0' '\n' | grep -c '\.cs$'       → 406
#     git ls-tree -r --name-only HEAD | wc -l                                  → 2026 (양쪽 동일)
#
# ⇒ .cs 필터 기준 누락 119건(29.3%). 그런데 ★전체 카운트(wc -l)는 2026 = 2026 으로
#   차이가 전혀 보이지 않는다★. 즉 이 결함은 ★경로를 필터·비교·조인에 쓸 때만★ 드러난다.
#   이것이 그동안 아무도 잡지 못한 이유다.
#
# 실사고 (사이클127): 이 결함으로 코드 재집계가 +97 차이를 냈다. 그대로 보고했다면
# ★존재하지 않는 회귀 97건★ 을 근거로 커밋을 막을 뻔했다. 검증 도구가 "없는 실패"를
# 만들어낸 사례다.
#
# 해결책: `-z` 와 `-c core.quotepath=false` 는 ★각각 단독으로★ 해결한다 (둘 다 406).
#
# ─────────────────────────────────────────────────────────────────────────────
# ★왜 차단형(rc=2)이 아니라 경고형(rc=0)인가 — 이 판단이 본 hook 의 핵심이다★
# ─────────────────────────────────────────────────────────────────────────────
# 1) 무해한 용법이 정당하게 존재한다.
#    `git ls-tree ... | wc -l` 처럼 ★개수만★ 세는 용법은 이스케이프돼도 행 수가
#    보존되므로 결과가 정확하다 (실측 2026 = 2026). 이것을 막을 이유가 없다.
#
# 2) "필터인가 카운트인가"는 명령 문자열만 보고 ★정적으로 완전 판별할 수 없다★.
#    파이프 뒤가 변수·서브셸·외부 스크립트일 수 있다. 예:
#        X=$(git ls-tree -r --name-only HEAD); echo "$X" | grep '\.cs$'
#        bash some_script.sh      # 스크립트 안에서 실행
#    이런 경로는 명령 문자열에 위험 신호가 드러나지 않는다.
#
# 3) 불완전한 판별로 rc=2 를 내면 ★오차단 사고를 신규 생성한다★.
#    이 프로젝트는 이미 같은 실패를 2회 겪었다 (2026-09-07 F-AGENT-1, 사이클128
#    정당 spawn 3회 차단). 재발방지 조치가 새로운 재발 원인이 되면 그것은 실패다.
#    ⇒ 같은 실패 패턴을 세 번째로 재생산하지 않는다.
#
# ⇒ 본 hook 은 ★어떤 경우에도 exit 2 를 내지 않는다★. stderr 경고 + exit 0 뿐이다.
#   목적은 "명령을 막는 것"이 아니라 "틀린 결과를 들고 그대로 진행하는 것"을 막는 것이다.
#
# ─────────────────────────────────────────────────────────────────────────────
# ★정직한 한계 (숨기지 않는다)★
# ─────────────────────────────────────────────────────────────────────────────
# - 변수 경유 필터 (X=$(ls-tree); echo $X | grep) → ★탐지 불가★ (정적 분석 한계)
# - 외부 스크립트 내부 실행 (bash foo.sh)         → ★탐지 불가★ (문자열에 안 보임)
# - 위 두 경로는 결과 측 검증(otest_evidence 양방향 자기검증, T-C5)이 회수한다.
#   입력 차단이 실패해도 출력 검증에서 잡히도록 이중화한 구조다.
# - `wc -l` 단독 카운트는 무해하므로 경고 대상이 아니다 (오경고 0 이 설계 목표).
#
# 등록: settings.json PreToolUse matcher 등록은 별도 담당(W2). 본 파일은 생성·자체검증까지.

set -u

# stdin 에서 JSON 입력 읽기 (Claude Code hook 표준)
INPUT=$(cat 2>/dev/null) || exit 0

# ── 어떤 실패에도 절대 rc!=0 을 내지 않는다 ────────────────────────────────
# jq 부재·JSON 파싱 실패·grep 미스매치 전부 조용히 통과시킨다.

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || TOOL_NAME=""

# 대상 도구가 아니면 즉시 통과
case "$TOOL_NAME" in
  mcp__oio__bash_exec|Bash) : ;;
  *) exit 0 ;;
esac

# 명령 문자열 추출 (write_guard.sh 와 동일 규약: command // cmd)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // .tool_input.cmd // empty' 2>/dev/null) || CMD=""
[ -z "$CMD" ] && exit 0

# ── 1단계: git + (ls-tree|ls-files) 조합인가 ───────────────────────────────
echo "$CMD" | grep -q 'git' 2>/dev/null || exit 0
echo "$CMD" | grep -qE 'ls-tree|ls-files' 2>/dev/null || exit 0

# ── 2단계: 이미 안전 옵션이 있으면 무음 ─────────────────────────────────────
#   -z                      : NUL 구분 출력 (이스케이프 안 함)
#   core.quotepath=false    : 이스케이프 비활성 (-c 또는 config 로 지정)
if echo "$CMD" | grep -qE '(^|[[:space:]])-z([[:space:]]|$)|core\.quotepath[[:space:]]*=[[:space:]]*(false|off|0)' 2>/dev/null; then
  exit 0
fi

# ── 3단계: 위험 신호 판정 ───────────────────────────────────────────────────
#   경로를 ★필터·비교·조인★ 에 쓰는 정황이 있을 때만 경고한다.
#   `wc -l` 만 있는 순수 카운트는 무해하므로 경고하지 않는다 (오경고 0 목표).
#   ⚠️ 한계: 이 판정은 명령 문자열만 본다. 변수 경유·외부 스크립트는 놓친다(헤더 참조).
if echo "$CMD" | grep -qE 'grep|comm[[:space:]]|diff|while[[:space:]]+read|sort|uniq|join|xargs|awk|sed' 2>/dev/null; then
  : # 위험 — 아래에서 경고
else
  exit 0  # wc -l 단독 등 — 무음
fi

# ── 경고 출력 (stderr, rc=0) ────────────────────────────────────────────────
cat >&2 <<'WARN'
⚠️ [git quotepath 경고] git ls-tree/ls-files 출력을 필터·비교에 쓰고 있는데 이스케이프 해제 옵션이 없습니다.
   문제: core.quotepath 기본값이 한글 파일명을 8진 이스케이프+따옴표로 감쌉니다.
         실측 예시: `.cs` 필터 기준 287 vs 406 — ★119건(29.3%) 누락★.
         ※ 전체 개수(wc -l)는 2026=2026 으로 차이가 안 보입니다. 필터에서만 드러납니다.
   교정: `git -c core.quotepath=false ls-tree ...`  또는  `git ls-tree -z ... | tr '\0' '\n'`
         (둘 중 ★하나만★ 써도 해결됩니다 — 실측 둘 다 406)
   ※ 이 경고는 명령을 차단하지 않습니다(rc=0). 결과를 신뢰하기 전에 한 번 확인하십시오.
WARN

# ── 발생 기록 (빈도 관측 → 향후 차단 승격 판단 근거, T-C2) ──────────────────
#   로그 실패는 절대 rc 에 영향을 주지 않는다.
_UUID="${PIPELINE_UUID:-}"
if [ -z "$_UUID" ]; then
  _UUID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null) || _UUID=""
fi
if [ -n "$_UUID" ]; then
  _LOGDIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${_UUID}/logs"
  mkdir -p "$_LOGDIR" 2>/dev/null && \
    printf '%s\t%s\t%s\n' "$(date -Iseconds 2>/dev/null)" "$TOOL_NAME" "$(echo "$CMD" | head -c 300 | tr '\n' ' ')" \
      >> "$_LOGDIR/git_quotepath_warn.log" 2>/dev/null
fi

# ★절대 규칙: 경고형이므로 반드시 0 으로 종료한다★
exit 0
