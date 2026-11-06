#!/bin/bash
# goal.json 계약 생성 시점에 이미 rc=0 인 무의미 auto_script 를 물리 차단하는 hook
# PreToolUse:mcp__oio__file_write — tool_input.path 가 session-env/<UUID>/goal.json 인 경우만 검사
#   (file_edit·copy·move·rename 은 write_guard P2 가 정적 전용 모드로 위임한다 — 사이클168·182)
#
# 배경 (L-483 실측): 직전 사이클 C6 auto_script 가 계약 생성 시점에 이미 rc=0 이었다.
#   아무것도 하지 않아도 통과하는 게이트였고, otest 가 발견하지 않았다면 push 없이 완주 종료됐다.
#   그 교훈을 반영해 만든 이번 계약의 D7 조차 똑같이 rc=0 이다.
#   ⇒ 문서 교훈은 다음 사이클을 못 지킨다. 물리 강제만이 재발을 막는다.
#
# 판정 (3단):
#   기준A (차단, F-GOALAS-1): depends_on 이 비어있지 않은데 계약 시점 auto_script 가 rc=0
#     → 선행이 미완인데 후행이 이미 충족 = 정의상 모순. 순수 기계 판정이며 자연어 추론 없음.
#   기준B (경고만, F-GOALAS-2): depends_on 이 빈 항목의 rc=0
#     → 존재 확인형(test -f LESSONS.md)이 여기 해당하며 정상이다. 통과시킨다.
#   (L-489: F-GOALAS-3 는 depends_on 축과 독립인 auto_script 문자열 중복 판정 / L-490: 본문 지정 적용 위치 F-GOAL-2·F-GOALAS-1·3 실존)
#   기준C (차단, F-GOALAS-3): 서로 다른 항목이 동일한 auto_script 문자열을 보유
#     → 후행 항목의 검증력이 정의상 0. depends_on 유무와 무관하게 성립하는 구조적 결함.
#
# 기준C 신설 배경 (사이클51-D 실측 — 단일 판정축은 회피된다):
#   기준A 는 depends_on 축 하나만 본다. 그래서 depends_on 을 비우기만 하면
#   무의미 게이트가 기준B 경고만 받고 그대로 통과한다(rc=0 실측 확인).
#   실사고 D1/D6 (사이클51-C):
#     D1  depends_on=[]      auto_script="cd ${HARNESS_HOME:-$HOME/.harness}/current && test -f LESSONS.md"
#     D6  depends_on=["D1"]  auto_script="cd ${HARNESS_HOME:-$HOME/.harness}/current && test -f LESSONS.md"  ← 글자까지 동일
#   D6 가 잡힌 것은 depends_on 을 우연히 적었기 때문이며, 비웠다면 통과했다.
#   D6 의 본질은 "D1 과 auto_script 가 완전히 동일" 이고, 이는 depends_on 과 무관한 별도 축이다.
#   ⇒ 판정축을 늘려야 회피 경로가 닫힌다.
#
# fail-open 철저: 차단 경로는 기준A / 기준C 검출 정확히 2개뿐이다. 그 외 전부 exit 0.
#   jq 부재 / JSON 파싱 실패 / stdin 없음 / path 불일치 / locked!=true / acceptance 부재
#   / auto_script timeout / 스크립트 자체 오류 → 전부 통과.
#   hook 이 고장나도 계약 생성이 막히면 안 된다.
#
# 비상 스위치: hooks/DISABLE_GOAL_AUTOSCRIPT_GUARD 존재 시 즉시 통과.
#
# ── E2 실증 기록 (사이클51-D, 2026-08-31 실측 — 전 케이스 stdin 투입) ──────────
#   양성(차단):
#     1  depends_on 전부 [] + auto_script 동일 2건 ............ rc=2  F-GOALAS-3 ✅
#     1b 동일하되 공백/들여쓰기만 상이 ....................... rc=2  F-GOALAS-3 ✅
#   ── 정규화 우회 재측정 (사이클51-E, 2026-08-31 otest 실측 → 본 수정으로 폐쇄) ──
#     수정 전 정규화는 tr '\n\t' 로 LF/TAB 만 치환했다. 그 외 공백문자는 원문에 남아
#     기능적으로 동일한 스크립트가 서로 다른 문자열이 되어 중복 검출을 빠져나갔다.
#     otest 실측 6종이 전부 rc=0(BYPASS)이었고, 본 수정(sed 유니코드 공백 + tr 5종) 후 재측정:
#       CR 후행 / CR 선행 / CR 내부 / VT 내부 / FF 내부 ....... rc=0 → rc=2 ✅ 폐쇄
#       NBSP(U+00A0) 내부 ..................................... rc=0 → rc=2 ✅ 폐쇄
#     추가 폐쇄(같은 축, 예방적) — U+2000~U+200A / U+3000 ..... rc=2 ✅
#   ── 남은 한계 (숨기지 않고 명시) ──────────────────────────────────────
#     · 위에 열거하지 않은 유니코드 공백/제로폭 문자(U+FEFF, U+200B 등)는 환산하지 않는다.
#       다만 이들은 셸에서 공백으로 취급되지 않아 '기능적으로 동일한 사본'이 성립하지 않는다
#       (실측: U+FEFF 삽입 시 'test -f/etc/hostname' 로 붙어 의미가 달라짐).
#     · 셸 수준의 의미 동치(따옴표 방식 변경, ; 와 && 치환, 변수 경유 등)는 문자열 비교로
#       잡을 수 없다. 이는 정규화가 아니라 파싱의 영역이며 본 hook 의 범위 밖이다.
#     · 즉 F-GOALAS-3 은 '우발적/저비용 변형'을 닫는 축이고, 작정한 우회를 전부 막지는 못한다.
#   음성(통과):
#     2  auto_script 서로 상이 ................................ rc=0 ✅
#   기존 판정 회귀(훼손 없음):
#     3  F-GOALAS-1 (depends_on 보유 + rc=0) .................. rc=2 ✅
#     4  F-GOALAS-2 (depends_on [] + rc=0, 중복 없음) ......... rc=0 + 경고 ✅
#   fail-open 전수 (10종 전부 rc=0):
#     5a locked=false          5b acceptance 부재     5c acceptance 비배열
#     5d auto_script 필드 부재  5e2 auto_script timeout(sleep 30/31)
#     5f 깨진 JSON             5g 빈 stdin            5h 비JSON stdin
#     5i 타 path               5j 타 도구(file_edit)
#   현 계약 실증:
#     6  E1~E6 원문 stdin 투입 ................................ rc=2 (F-GOALAS-1: E2, E5)
#        ★본 변경과 무관★ — HEAD 원본 hook 으로 동일 입력 재현 시에도 rc=2, 지적 항목 동일(E2,E5).
#        원인은 계약 결함이 아니라 시점 문제다. E2 는 auto_script 가 본 hook 을 호출해
#        rc=2 를 요구하는데 E1 구현 완료로 실제 성립했고, E5 는 LESSONS.md 대상 문자열이
#        이미 작업 반영되어 rc=0 이 됐다. 즉 '선행이 실제로 끝나서' 후행이 충족된 정상 상태다.
#   차단 판정 근거: 중복은 후행 항목의 검증력이 정의상 0 이며 depends_on 유무와 무관하게
#     성립하는 구조적 결함이므로 경고가 아닌 차단으로 둔다. 완료 조건이 진짜 같다면
#     별개 항목이 아니라 하나의 항목이므로, 정당한 반례가 성립하지 않는다.

# ── 사이클168 추가 (F-GOALAS-4/5/6 · 입력 확장 · 정적 전용 모드) ────────────
#   F-GOALAS-4 (차단): auto_script 에 세션 절대경로(/tmp/cc-*, /…/session-env/<UUID>, ~·$HOME·${HOME} 형)가
#     박혀 있으면 locked 여부와 무관하게 차단한다(D7 — oplan_normal 은 locked=false 로 계약을 만든다).
#     사이클167 실사고: 세션 재시작으로 CLAUDE_CONFIG_DIR 이 바뀌자 C1~C18 이 전부 거짓 FAIL 이 됐다.
#     허용형: "$GOAL_SESSION_DIR/…", 폴백형 "${GOAL_SESSION_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/<U>}/…"
#   F-GOALAS-5 (경고): 계약 시점 판정불가(판정 스크립트 파일 부재) — 스크립트를 먼저 만든 뒤 계약을 쓰라.
#   F-GOALAS-6 (차단): 공용 실행부 lib 부재 — 계약 시점 판정(F-GOALAS-1)이 불가하다. locked 계약만 해당.
#   입력 확장(P2·R1): file_copy·file_move·file_rename 로 goal.json 을 배치하는 경로도 본다.
#     목적지 별칭 전부를 후보로 하고, 기존 디렉터리·'/' 끝 목적지는 목적지/basename(원본),
#     정규화는 링크 미해석형(realpath -m -s)·해석형(realpath -m) 두 형태를 모두 판정한다.
#     copy/move/rename 은 원본 파일 내용을 계약으로 간주한다.
#   정적 전용 모드(I-2): GOAL_AS_STATIC_ONLY=1 (write_guard 가 copy/move/rename 위임 시 timeout 3 으로 호출)
#     F-GOALAS-4(필수) → locked=true ∧ acceptance 배열이면 F-GOALAS-3 → exit 0.
#     auto_script 실행(F-GOALAS-1/2/5/6)은 하지 않는다. (사이클181: F-GOALAS-7 용 gas_weak_regex 정의만 source 한다)
#   auto_script 실행은 공용 실행부 lib/goal_autoscript_run.sh 의 gas_eval 로만 한다(GOAL_SESSION_DIR 제공).

# ── 사이클181 추가 (F-GOALAS-7 · 검수조건 파일 대상 확장) ─────────────────
#   F-GOALAS-7 (차단): auto_script 가 무력 정규식(PASS·FAIL 교대 — 예 grep -E '^(PASS|FAIL) X')이면
#     locked 여부와 무관하게, 정적 전용 모드에서도 차단한다. FAIL 줄도 rc=0 이 되어 판정력이 0 이다(L-601).
#     판정은 lib 의 gas_weak_regex 로만 한다(정의만 source — auto_script 는 실행하지 않는다).
#     lib 를 읽지 못하면 F-GOALAS-7 은 건너뛴다. 실행부 gas_eval 이 같은 판정으로 판정불가(3)를 내는 2차 방어다.
#   대상 경로 확장: session-env/<U>/plans/acceptance_criteria.json (정확히 이 파일명, .criteria[])
#     — goal.json 과 같은 두 형태(링크 미해석·해석) 정규화로 판별한다(R3).
#     이 파일은 F-GOALAS-7 만 보고 exit 0 한다(다른 판정 미적용).
#     보관본(plans/acceptance_criteria_*.json)은 대상이 아니다 — 옛 계약 보관을 막지 않기 위해서다.
#   ── 잔존 한계 (사이클181 당시 — 사이클182 에서 앞 두 줄은 닫혔다. 아래 사이클182 절 참조) ──
#     · (닫힘) settings.json 에서 이 hook 의 matcher 는 mcp__oio__file_write 뿐이라 file_edit 를 보지 않았다.
#     · (닫힘) copy/move/rename 은 write_guard 가 goal.json 만 위임해 검수조건 파일 배치를 보지 않았다.
#     · 변수 경유(P='(PASS|FAIL)'; grep -E "$P")·문자 클래스 우회는 문자열 판정으로 못 잡는다.

# ── 사이클182 추가 (항목4 file_edit 입력 · 항목8 F-GOALAS-8) ─────────────────
#   file_edit 입력(항목4): mcp__oio__file_edit 도 받는다. settings matcher 는 바꾸지 않았고(세션 캐시 drift 위험 —
#     2026-05-02 정책), write_guard P2 가 goal.json·plans/acceptance_criteria.json 대상 file_edit·copy·move·rename 을
#     정적 전용 모드(timeout 3, stdin 원문)로 이 hook 에 넘긴다.
#     적용 후 내용 = 현재 파일 내용에 old→new 정확 문자열 치환(python3).
#       키 별칭 old_string|old|old_text|old_content|search / new_string|new|new_text|new_content|replace,
#       replace_all|global_replace. 경로 별칭 path|file_path|filepath.
#       비replace_all 에서 출현 수 ≠ 1, replace_all 에서 0, 대상 파일 부재, old 빈 값 → 실제 도구도 실패하므로 통과.
#       출현 0회이고 파일이 CRLF 면 old·new 의 LF 를 CRLF 로 바꿔 한 번 더 맞춰 본다(더 엄격한 쪽).
#     이후 판정은 file_write 와 같다(goal: F-GOALAS-7·4 → locked 면 F-GOALAS-3, AC: F-GOALAS-7 만).
#   F-GOALAS-8 (차단, 항목8): 디스크의 기존 goal.json 이 locked=true 인데 새 내용 acceptance 에 기존에 없던 id 의
#     항목이 있으면(덧붙이기 — write_guard F-GOAL-1 의 append 예외가 file_write 로만 허용한다) 그 항목의 auto_script 를
#     gas_eval 로 기록 시점에 실행해 rc=0(이미 PASS)·rc=3(판정불가)·auto_script 빈 값이면 차단한다.
#     덧붙인 항목은 수정 전 FAIL 이어야 한다(이미 충족된 항목으로 범위를 부풀리거나 판정 못 하는 항목 금지).
#     · 새 내용이 locked=false 여도 디스크가 잠겨 있으면 적용한다(잠금 해제 동반 덧붙이기는 write_guard 가 따로 막는다).
#     · 덧붙인 항목에도 F-GOALAS-7·4(전 배열)·F-GOALAS-3(디스크 잠금이면 새 내용 locked 와 무관하게) 가 그대로 적용된다.
#     · 정적 전용 모드(file_edit·copy·move·rename 위임)는 auto_script 를 실행할 수 없으므로 덧붙이기가 보이면 차단한다
#       — 덧붙이기는 file_write 경로만 정식이다.
#     · 덧붙인 항목은 F-GOALAS-8 로 이미 판정했으므로 6단계(F-GOALAS-1/2/5) 실행 루프에서는 다시 돌리지 않는다.
#   ── 잔존 한계 (숨기지 않고 명시) ──
#     · 셸 쓰기(jq … > goal.json·sed -i 등)는 이 hook 이 보지 않는다. goal.json 은 write_guard F-GOAL-1(bash 분기)이,
#       검수조건 파일은 실행부 gas_eval 의 판정불가(3)가 2차 방어다.
#     · file_edit 모사는 oio 의 정확 치환 규칙을 가정한다. oio 가 공백·줄끝을 다르게 맞추는 경우(CRLF 외)는 모사가
#       출현 0회로 보고 통과시킨다 — 그 경우 실제 도구도 대개 실패하지만 보장은 아니다.
#     · F-GOALAS-8 은 "기록 시점에 FAIL" 만 강제한다. 새 항목의 의미가 필요한지는 판정하지 못한다.
# ── 사이클182 반복1 (순수 덧붙이기 — 계약 시점 검사 새 항목 한정) ─────────────
#   순수 덧붙이기(디스크 잠김 ∧ 새 내용 locked=true ∧ 새 id 항목을 뺀 새 내용 == 디스크 계약)면
#   F-GOALAS-1·2·5(6단계 실행)·F-GOALAS-3 을 새 항목에만 적용한다. 작업이 끝난 뒤에는 depends_on 보유
#   기존 항목이 정당하게 rc=0 이라, 전 항목 재판정이 덧붙이기를 구조적으로 막았다(실측: G1·K5 F-GOALAS-1).
#   잠금 해제 동반·기존 항목/필드 변경·신규 계약은 종전대로 전 항목 검사한다. F-GOALAS-4·7 도 같은 조건에서 새 항목만 본다.

# ── 사이클203 추가 (F-GOALAS-9 · 빈 acceptance 항목 차단) ─────────────────
#   open 항목의 auto_script 가 비었거나 acceptance 가 비면 locked 무관·정적 모드 포함 차단한다.
#   디스크에 goal.json 이 이미 있으면 건너뛴다(기존·locked 계약, IDLE 전이·F-OTO 경로 무영향). blocked 항목 면제.
#   한계: 셸 리다이렉션으로 쓰는 경로는 이 hook 매처 밖이다. acceptance_criteria.json 에는 적용하지 않는다.

# ── 사이클214 추가 (F-GOALAS-10 · F-GOALAS-11 — 오인·과차단 재발방지 R4·R1-다) ─────
#   F-GOALAS-10 (차단, goal.json): 새로 추가되는 항목에만 lib/goal_judge_lint.py 로 판정기 작성 가정을 점검한다
#     (curl HEAD 에 judge_basis 없음 · .dll/.exe ASCII 단독 바이트 검색 · 판정 스크립트 호출형에 plan_ref·pass_proof 없음).
#     기존 항목(잠긴 계약 포함)에는 소급하지 않는다. lint 부재·오류는 경고만.
#   F-GOALAS-11 (차단, plans/acceptance_criteria.json): crud_대상=false 인데 item_crud(bool) 미기재 항목이 있으면 차단.
#   시험: tests/test_goal_judge_lint.sh

_HOOK_DIR="${HARNESS_HOME:-$HOME/.harness}/current/hooks"

# ── 0. 비상 스위치 (최우선) ────────────────────────────────────────────
[[ -f "${_HOOK_DIR}/DISABLE_GOAL_AUTOSCRIPT_GUARD" ]] && exit 0

_STATIC=0
[[ "${GOAL_AS_STATIC_ONLY:-}" == "1" ]] && _STATIC=1

INPUT=$(timeout 5 cat) || exit 0
[[ -z "$INPUT" ]] && exit 0

# jq 없으면 검사 불가 → fail-open
command -v jq >/dev/null 2>&1 || exit 0

# ── 1. 도구 판별 ───────────────────────────────────────────────────────
_TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
case "$_TOOL" in
  mcp__oio__file_write|mcp__oio__file_edit|mcp__oio__file_copy|mcp__oio__file_move|mcp__oio__file_rename) ;;
  *) exit 0 ;;
esac

# ── 2. 경로 판별: session-env/<UUID>/goal.json (공통 경로 규칙 R1/R2) ──────
# 경로 1개를 두 형태(링크 미해석·해석)로 정규화해 goal.json 이면 그 형태를 출력한다.
_goal_target() {
  local _p="$1" _a _b
  [[ -z "$_p" ]] && return 1
  _a=$(realpath -m -s -- "$_p" 2>/dev/null) || _a=""
  [[ -z "$_a" ]] && _a="$_p"
  _b=$(realpath -m -- "$_p" 2>/dev/null) || _b=""
  [[ -z "$_b" ]] && _b="$_p"
  if [[ "$_a" =~ session-env/[^/]+/goal\.json$ ]]; then printf '%s' "$_a"; return 0; fi
  if [[ "$_b" =~ session-env/[^/]+/goal\.json$ ]]; then printf '%s' "$_b"; return 0; fi
  # [사이클181] 검수조건 파일 — 같은 두 형태 판별(R3). 정확히 이 파일명만(보관본 제외)
  if [[ "$_a" =~ session-env/[^/]+/plans/acceptance_criteria\.json$ ]]; then printf '%s' "$_a"; return 0; fi
  if [[ "$_b" =~ session-env/[^/]+/plans/acceptance_criteria\.json$ ]]; then printf '%s' "$_b"; return 0; fi
  return 1
}

_PATH=""
_SRC=""
_CAND=""
case "$_TOOL" in
  mcp__oio__file_write|mcp__oio__file_edit)
    while IFS= read -r _c; do
      [[ -z "$_c" ]] && continue
      _PATH=$(_goal_target "$_c") && break
      _PATH=""
    done < <(echo "$INPUT" | jq -r '[.tool_input.path, .tool_input.file_path, .tool_input.filepath] | map(select(type == "string" and . != ""))[]' 2>/dev/null)
    ;;
  mcp__oio__file_copy|mcp__oio__file_move)
    _SRC=$(echo "$INPUT" | jq -r '[.tool_input.source, .tool_input.src, .tool_input.path] | map(select(type == "string" and . != "")) | .[0] // empty' 2>/dev/null) || exit 0
    _CAND=$(echo "$INPUT" | jq -r '[.tool_input.destination, .tool_input.dest, .tool_input.dst, .tool_input.target, .tool_input.to] | map(select(type == "string" and . != ""))[]' 2>/dev/null) || exit 0
    ;;
  mcp__oio__file_rename)
    _SRC=$(echo "$INPUT" | jq -r '[.tool_input.path, .tool_input.file_path] | map(select(type == "string" and . != "")) | .[0] // empty' 2>/dev/null) || exit 0
    _CAND=$(echo "$INPUT" | jq -r '[.tool_input.new_name, .tool_input.name, .tool_input.new_path, .tool_input.to] | map(select(type == "string" and . != ""))[]' 2>/dev/null) || exit 0
    ;;
esac

if [[ "$_TOOL" != "mcp__oio__file_write" && "$_TOOL" != "mcp__oio__file_edit" ]]; then
  [[ -z "$_SRC" ]] && exit 0
  while IFS= read -r _c; do
    [[ -z "$_c" ]] && continue
    # rename 의 상대 이름은 원본 디렉터리 기준
    if [[ "$_TOOL" == "mcp__oio__file_rename" && "$_c" != /* ]]; then
      _c="$(dirname "$_SRC")/${_c}"
    fi
    # 목적지가 '/' 로 끝나거나 기존 디렉터리면 실제로 생기는 경로는 목적지/basename(원본)
    if [[ "$_c" == */ || -d "$_c" ]]; then
      _c="${_c%/}/$(basename "$_SRC")"
    fi
    _PATH=$(_goal_target "$_c") && break
    _PATH=""
  done <<< "$_CAND"
fi
[[ -n "$_PATH" ]] || exit 0

# ── 3. content 추출 + JSON 유효성 ──────────────────────────────────────
if [[ "$_TOOL" == "mcp__oio__file_write" ]]; then
  _CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // .tool_input.text // .tool_input.body // empty' 2>/dev/null) || exit 0
elif [[ "$_TOOL" == "mcp__oio__file_edit" ]]; then
  # [사이클182 항목4] 적용 후 내용 모사 — 현재 파일에 old→new 정확 치환. 모사 불가(실 도구도 실패) → 통과.
  [[ -f "$_PATH" && -r "$_PATH" ]] || exit 0
  command -v python3 >/dev/null 2>&1 || exit 0
  _CONTENT=$(printf '%s' "$INPUT" | timeout 2 python3 -c '
import json, sys
try:
    ti = json.load(sys.stdin).get("tool_input") or {}
    def pick(keys):
        for k in keys:
            v = ti.get(k)
            if isinstance(v, str):
                return v
        return None
    old = pick(("old_string", "old", "old_text", "old_content", "search"))
    new = pick(("new_string", "new", "new_text", "new_content", "replace"))
    allr = bool(ti.get("replace_all") or ti.get("global_replace"))
    if not old or new is None:
        sys.exit(1)
    with open(sys.argv[1], "r", encoding="utf-8", errors="surrogateescape", newline="") as f:
        cur = f.read()
    n = cur.count(old)
    if n == 0 and "\r\n" in cur and "\n" in old and "\r\n" not in old:
        old, new = old.replace("\n", "\r\n"), new.replace("\n", "\r\n")
        n = cur.count(old)
    if n == 0 or (not allr and n != 1):
        sys.exit(1)
    out = cur.replace(old, new) if allr else cur.replace(old, new, 1)
    sys.stdout.write(out.encode("utf-8", "surrogateescape").decode("utf-8", "replace"))
except Exception:
    sys.exit(1)
' "$_PATH" 2>/dev/null) && _SIM_RC=0 || _SIM_RC=$?
  # [사이클182 반복1 A2] 모사 rc: 1 = 모사 불가(old 출현 0회·복수 등 — 실 도구도 실패) → 통과(종전).
  #   124·137 등 시간 초과·강제 종료 = 판정불가 → 차단. 종전에는 둘 다 통과라 부하 때 무력 정규식 삽입 file_edit 가
  #   F-GOALAS-7 을 빠져나갔다(python 3초 지연 실측 rc=0, 지연 없음 rc=2). 판정불가는 통과가 아니다.
  if [[ "$_SIM_RC" -ne 0 && "$_SIM_RC" -ne 1 ]]; then
    jq -cn --arg r "⏳ [F-GOALAS-UNDET] file_edit 적용 후 내용 판정이 끝나지 않았습니다(rc=${_SIM_RC}, 시스템 정체) — 아직 거부가 아닙니다. 판정불가는 통과가 아니므로 이번 호출은 보류합니다. 같은 호출을 잠시 뒤 다시 하십시오.
   대상 경로: ${_PATH} (도구: ${_TOOL})" '{decision:"block", reason:$r}' 2>/dev/null \
      || echo '{"decision":"block","reason":"⏳ [F-GOALAS-UNDET] file_edit 적용 후 내용 판정 시간 초과 — 판정불가는 통과가 아닙니다. 같은 호출을 다시 하십시오."}'
    exit 2
  fi
  [[ "$_SIM_RC" -eq 0 ]] || exit 0
else
  # copy/move/rename 은 원본 내용이 계약이 된다. 원본을 못 읽으면 실제 도구도 실패하므로 통과.
  [[ -f "$_SRC" && -r "$_SRC" ]] || exit 0
  _CONTENT=$(cat -- "$_SRC" 2>/dev/null) || exit 0
fi
[[ -z "$_CONTENT" ]] && exit 0

echo "$_CONTENT" | jq -e . >/dev/null 2>&1 || exit 0

# ── 3b. 로그 준비 ──────────────────────────────────────────────────────
_IS_AC=0
[[ "$_PATH" == */plans/acceptance_criteria.json ]] && _IS_AC=1
_SESSION_DIR=$(dirname "$_PATH")
[[ "$_IS_AC" -eq 1 ]] && _SESSION_DIR=$(dirname "$_SESSION_DIR")
_LOG_FILE="${_SESSION_DIR}/logs/goal_autoscript_guard.log"
[[ -d "$_SESSION_DIR" ]] && mkdir -p "${_SESSION_DIR}/logs" 2>/dev/null
_log() {
  echo "$(date '+%Y-%m-%dT%H:%M:%S%z') $*" >> "$_LOG_FILE" 2>/dev/null || true
}

# ── 3b-2. F-GOALAS-7: 무력 정규식(PASS·FAIL 교대) 차단 (사이클181 — locked 무관, 정적 모드 포함) ──
#   $1 = 항목 배열 jq 경로(.acceptance 또는 .criteria). lib 를 못 읽으면 건너뛴다(실행부가 2차 방어).
_f_goalas7() {
  local _arr="$1" _ITEM _S7 _IDS7="" _REASON7
  # shellcheck source=/dev/null
  source "${_HOOK_DIR}/lib/goal_autoscript_run.sh" 2>/dev/null && declare -F gas_weak_regex >/dev/null 2>&1 || {
    _log "SKIP F-GOALAS-7 lib 부재/로드 실패 (실행부 gas_eval 판정불가가 2차 방어)"
    return 0
  }
  while IFS= read -r _ITEM; do
    [[ -z "$_ITEM" ]] && continue
    _S7=$(echo "$_ITEM" | jq -r '.auto_script // empty' 2>/dev/null)
    [[ -z "$_S7" ]] && continue
    if gas_weak_regex "$_S7"; then
      _IDS7="${_IDS7}${_IDS7:+, }$(echo "$_ITEM" | jq -r '.id // "?"' 2>/dev/null)"
    fi
  done < <(echo "$_CONTENT" | jq -c "${_arr} | if type == \"array\" then .[] else empty end | select(type == \"object\")" 2>/dev/null)
  [[ -n "$_IDS7" ]] || return 0

  _REASON7="⛔ [F-GOALAS-7] auto_script 가 무력 정규식(PASS·FAIL 교대)입니다: ${_IDS7}
   예) grep -E '^(PASS|FAIL) X' — FAIL 줄도 매칭되어 rc=0 이 되므로 판정력이 0 입니다(L-601: PASS 만 인정).
   대상 경로: ${_PATH} (도구: ${_TOOL})
→ 해결: PASS 줄만 요구하고 FAIL 줄은 따로 부정하십시오.
   좋은 예) bash t.sh 2>&1 | grep -q '^PASS X' && ! bash t.sh 2>&1 | grep -q '^FAIL'
→ 실행부(gas_eval)도 같은 판정으로 판정불가(3)를 냅니다 — 우회해도 통과로 세지 않습니다.
→ 비상 시: hooks/DISABLE_GOAL_AUTOSCRIPT_GUARD 파일 생성으로 우회 가능."
  _log "BLOCK F-GOALAS-7 ids=${_IDS7} tool=${_TOOL} static=${_STATIC} ac=${_IS_AC}"
  jq -cn --arg r "$_REASON7" '{decision:"block", reason:$r}' 2>/dev/null \
    || echo '{"decision":"block","reason":"auto_script 가 무력 정규식(PASS·FAIL 교대)입니다 (F-GOALAS-7)."}'
  exit 2
}

# 검수조건 파일은 F-GOALAS-7·11 만 본다(다른 판정 미적용)
if [[ "$_IS_AC" -eq 1 ]]; then
  _f_goalas7 '.criteria'
  # ── [사이클214 R1-다] F-GOALAS-11: crud_대상=false 인데 item_crud(bool) 미기재 항목 차단 ──
  #   원인(c214 실측): 30건 전부 item_crud·verify_kind 미기재 → 판정기가 키워드 부분일치('생성기'·'반영'·'갱신본'·
  #   'INSERT 거부')로 CRUD 의심 6건을 만들어 DECLARATION_CONFLICT 오인 차단. 스킬 지시만으로는 기재가 안 지켜졌다.
  #   기재 여부만 강제한다(값 판정 없음 — 거짓 선언은 판정기의 경로·DB 축이 계속 잡는다). 정적 모드(file_edit 위임) 포함.
  #   crud_대상 이 false 가 아니면(true·부재) 미적용. criteria 비배열이면 미적용(fail-open).
  _IDS11=$(echo "$_CONTENT" | jq -r '
      if .["crud_대상"] == false and ((.criteria | type) == "array") then
        [ .criteria[] | select(type == "object") | select((.item_crud | type) != "boolean") | ((.id // "?") | tostring) ] | join(", ")
      else "" end' 2>/dev/null) || _IDS11=""
  if [[ -n "$_IDS11" ]]; then
    _R11="⛔ [F-GOALAS-11] 검수조건이 crud_대상=false 인데 item_crud(bool) 가 빠진 항목이 있습니다: ${_IDS11}
   빠지면 판정기(verify_crud_executed.py)가 설명 낱말 부분일치('생성'·'반영'·'갱신'·'INSERT' 등)로 CRUD 를 추정해
   DECLARATION_CONFLICT 오인 차단이 납니다(사이클214 실측 6건).
   대상 경로: ${_PATH} (도구: ${_TOOL})
→ 해결: 위 항목마다 \"item_crud\": false (DB 쓰기 없음) 또는 true 를 적으십시오.
   검사·정적 판정 항목이면 \"verify_kind\": \"inspection\" 도 함께 적으십시오.
   예) {\"id\": \"AC-001\", ..., \"item_crud\": false, \"verify_kind\": \"inspection\"}
→ 비상 시: hooks/DISABLE_GOAL_AUTOSCRIPT_GUARD 파일 생성으로 우회 가능. (차단 코드 F-GOALAS-11)"
    _log "BLOCK F-GOALAS-11 ids=${_IDS11} tool=${_TOOL} static=${_STATIC}"
    jq -cn --arg r "$_R11" '{decision:"block", reason:$r}' 2>/dev/null \
      || echo '{"decision":"block","reason":"crud_대상=false 인데 item_crud 가 빠진 검수조건 항목이 있습니다 (F-GOALAS-11)."}'
    exit 2
  fi
  _log "PASS ac F-GOALAS-7·11 path=${_PATH}"
  exit 0
fi

# ── 3e. (사이클182 항목8) 덧붙이기 판별 — 디스크의 기존 goal.json 이 locked=true 인데 새 id 항목이 있는가 ──
#   _APPEND_ITEMS = 새 내용 acceptance 중 디스크 acceptance 에 없던 id 의 항목(jq -c, 줄당 1개)
#   _APPEND_IDS   = 그 id 목록(표시용). 디스크 판독 실패·비잠금 → 빈 값(F-GOALAS-8 미적용, 종전 동작).
_DISK_LOCKED=0
_APPEND_ITEMS=""
_APPEND_IDS=""
if [[ -f "$_PATH" && -r "$_PATH" ]] && jq -e '.locked == true' "$_PATH" >/dev/null 2>&1; then
  _DISK_LOCKED=1
  _APPEND_ITEMS=$(echo "$_CONTENT" | jq -c --slurpfile _old "$_PATH" '
      [($_old[0].acceptance // []) | if type == "array" then .[] else empty end | (.id? // null) | tostring] as $o
      | (.acceptance // []) | if type == "array" then .[] else empty end | select(type == "object")
      | select(((.id // null) | tostring) as $i | ($o | index($i)) == null)' 2>/dev/null) || _APPEND_ITEMS=""
  if [[ -n "$_APPEND_ITEMS" ]]; then
    _APPEND_IDS=$(printf '%s\n' "$_APPEND_ITEMS" | jq -r '.id // "?" | tostring' 2>/dev/null | paste -sd ',' - 2>/dev/null | sed 's/,/, /g')
  fi
fi

# ── 3f. (사이클182 반복1) 순수 덧붙이기 판별 — 계약 시점 검사(F-GOALAS-1·2·5·3)를 새 항목에만 적용 ──
#   조건(전부): 디스크 잠김 ∧ 새 id 항목 있음 ∧ 새 내용 locked=true ∧
#              새 내용에서 새 id 항목만 뺀 것 == 디스크 계약(jq 깊은 비교 — 다른 필드·기존 항목·순서 불변)
#   이유: 기존 항목은 잠금 시점에 이미 검사됐고 write_guard F-GOAL-1 이 불변을 보장한다. 작업이 끝난 뒤에는
#         depends_on 보유 기존 항목이 정당하게 rc=0 이므로, 전 항목 재판정은 덧붙이기를 구조적으로 막았다(실측 G1·K5).
#   조건 불충족(잠금 해제 동반·기존 항목/필드 변경·신규 계약)은 종전대로 전 항목 검사한다(완화 없음). 비교 실패 = 0.
_PURE_APPEND=0
_APPEND_IDLIST=""
if [[ "$_DISK_LOCKED" -eq 1 && -n "$_APPEND_ITEMS" ]]; then
  _APPEND_IDLIST=$(printf '%s\n' "$_APPEND_ITEMS" | jq -r '.id // null | tostring' 2>/dev/null) || _APPEND_IDLIST=""
  if echo "$_CONTENT" | jq -e --slurpfile _old "$_PATH" '
      ($_old[0]) as $o
      | [($o.acceptance // []) | if type == "array" then .[] else empty end | (.id? // null) | tostring] as $ids
      | .locked == true
        and ((.acceptance | type) == "array")
        and ((.acceptance |= map(select(((.id? // null) | tostring) as $i | ($ids | index($i)) != null))) == $o)' >/dev/null 2>&1; then
    _PURE_APPEND=1
  fi
fi

# 검사 범위(F-GOALAS-4·7) — 순수 덧붙이기면 새 id 항목만, 아니면 전 항목(종전). jq 배열 식.
#   [사이클182 반복1] 잠긴 옛 계약의 기존 항목에 규칙 도입 이전 잔재(세션 절대경로·무력 정규식)가 있으면
#   F-GOAL-1 이 기존 항목 수정을 막으므로 덧붙이기가 영구히 불가능했다(합성 재현). 새 항목은 그대로 검사한다.
_SCOPE_ACC='.acceptance'
if [[ "$_PURE_APPEND" -eq 1 ]]; then
  _NEWIDS_JSON=$(printf '%s\n' "$_APPEND_IDLIST" | jq -R . 2>/dev/null | jq -sc 'map(select(. != ""))' 2>/dev/null) || _NEWIDS_JSON=''
  if [[ -n "$_NEWIDS_JSON" ]]; then
    _SCOPE_ACC="[(.acceptance // []) | if type == \"array\" then .[] else empty end | select(type == \"object\") | select((((.id? // null) | tostring) as \$i | ${_NEWIDS_JSON} | index(\$i)) != null)]"
  else
    _PURE_APPEND=0
  fi
fi

# ── 3c. F-GOALAS-4: 세션 절대경로 하드코딩 차단 (locked 무관 — 4단계 앞, D7) ──
_P4_ABS='(^|[\s"'"'"'=:(;|&])/(?:[^\s"'"'"'$;|&]*/)?session-env/[0-9a-f]{8}-[0-9a-f]{4}-'
_P4_TMP='(^|[\s"'"'"'=:(;|&])/tmp/cc-[0-9a-f]{6,}'
_P4_HOME='(~|\$HOME|\$\{HOME\})/\.claude/session-env/[0-9a-f]{8}-'
_ABS_IDS=""
while IFS= read -r _ITEM; do
  [[ -z "$_ITEM" ]] && continue
  _S4=$(echo "$_ITEM" | jq -r '.auto_script // empty' 2>/dev/null)
  [[ -z "$_S4" ]] && continue
  # grep -P 는 -e 다중 패턴을 받지 않는다(rc=2 "only supports a single pattern") — 교대(|)로 합친다
  if printf '%s\n' "$_S4" | grep -qP "(?:${_P4_ABS})|(?:${_P4_TMP})|(?:${_P4_HOME})" 2>/dev/null; then
    _ABS_IDS="${_ABS_IDS}${_ABS_IDS:+, }$(echo "$_ITEM" | jq -r '.id // "?"' 2>/dev/null)"
  fi
done < <(echo "$_CONTENT" | jq -c "${_SCOPE_ACC} | if type == \"array\" then .[] else empty end | select(type == \"object\")" 2>/dev/null)

if [[ -n "$_ABS_IDS" ]]; then
  _REASON4="⛔ [F-GOALAS-4] auto_script 에 세션 절대경로가 박혀 있습니다: ${_ABS_IDS} — 세션 재시작 시 CLAUDE_CONFIG_DIR 이 바뀌면 판정이 전부 거짓 FAIL 이 됩니다(사이클167 실사고). → \"\$GOAL_SESSION_DIR/<파일>\" 을 쓰십시오(모든 실행부가 goal.json 이 있는 디렉터리를 이 변수로 넘깁니다).
   대상 경로: ${_PATH} (도구: ${_TOOL})
→ 비상 시: hooks/DISABLE_GOAL_AUTOSCRIPT_GUARD 파일 생성으로 우회 가능."
  _log "BLOCK F-GOALAS-4 ids=${_ABS_IDS} tool=${_TOOL} static=${_STATIC}"
  jq -cn --arg r "$_REASON4" '{decision:"block", reason:$r}' 2>/dev/null \
    || echo '{"decision":"block","reason":"auto_script 에 세션 절대경로가 박혀 있습니다 (F-GOALAS-4). $GOAL_SESSION_DIR 를 쓰십시오."}'
  exit 2
fi

# ── 3d. F-GOALAS-7 (goal.json — locked 무관, 정적 모드 포함) ─────────────
_f_goalas7 "$_SCOPE_ACC"

# ── 3g. F-GOALAS-9 (사이클203): 빈 acceptance 항목 차단 — locked 무관, 정적 모드 포함 ──
#   open(status 없음 포함) 항목은 auto_script 가 공백 아닌 문자열이어야 한다(desc 는 요구하지 않는다 — 한계).
#   acceptance 가 배열이 아니거나 비면 차단. blocked·blocked_by 는 면제(§3.2 — 실행 대상 아님).
#   이유: 사이클202 실측 — A1~A4 가 auto_script 없이 기록돼 게이트가 no-op, otest PARTIAL.
#   적용 범위(team-lead 확정): 디스크에 goal.json 이 이미 있으면 건너뛴다(기존·locked 계약, IDLE 전이·F-OTO 경로 무영향).
#   디스크본이 없을 때의 신규 계약 기록, 또는 보관 사본(*_completed*)을 원본으로 하는 copy/move/rename 교체일 때만 검사한다.
_OLD9='null'
_APPLY9=1
if [[ -s "$_PATH" ]]; then
  _APPLY9=0
  [[ -n "$_SRC" && "$(basename -- "$_SRC")" == *_completed* ]] && _APPLY9=1
fi
_EMPTY9=""
[[ "$_APPLY9" -eq 1 ]] && _EMPTY9=$(echo "$_CONTENT" | jq -r --argjson old "$_OLD9" '
  def filled(v): (v | type) == "string" and (v | test("\\S"));
  ([ ($old // {}) | (.acceptance? // []) | if type == "array" then .[] else empty end | tojson ]) as $o
  | if ($old != null) and ((.acceptance? // null) == ($old.acceptance? // null)) then ""
    elif (.acceptance | type) != "array" or (.acceptance | length) == 0 then "(acceptance 없음·빈 배열)"
    else [ .acceptance[]
           | if type != "object" then "(객체 아님)"
             elif (((.status // "open") | tostring) | IN("blocked", "blocked_by")) then empty
             elif (tojson as $j | $o | any(.[]; . == $j)) then empty
             elif filled(.auto_script) then empty
             else ((.id // "?") | tostring) end ] | join(", ") end' 2>/dev/null) || _EMPTY9=""
if [[ -n "$_EMPTY9" ]]; then
  _REASON9="⛔ [F-GOALAS-9] goal.json 에 빈 acceptance 항목이 있습니다: ${_EMPTY9}
   open 항목은 auto_script(exit 0 = PASS)가 공백 아닌 문자열로 있어야 합니다 — 비면 게이트가 조용히 통과합니다(no-op, 사이클202 실측).
   권한 밖 항목이면 status:\"blocked\" + blocked_reason·blocked_evidence 로 적으십시오(goal/SKILL.md §3.2).
   대상 경로: ${_PATH} (도구: ${_TOOL})
→ 비상 시: hooks/DISABLE_GOAL_AUTOSCRIPT_GUARD 파일 생성으로 우회 가능."
  _log "BLOCK F-GOALAS-9 ids=${_EMPTY9} tool=${_TOOL} static=${_STATIC}"
  jq -cn --arg r "$_REASON9" '{decision:"block", reason:$r}' 2>/dev/null \
    || echo '{"decision":"block","reason":"goal.json 에 빈 acceptance 항목이 있습니다 (F-GOALAS-9)."}'
  exit 2
fi

# ── 3h. [사이클214 R4] F-GOALAS-10: 판정기 작성 가정 점검 — ★새로 추가되는 항목에만★(소급 금지) ──
#   lib/goal_judge_lint.py 가 판정한다: curl HEAD 판정기에 judge_basis 없음 · 판정 스크립트가 .dll·.exe 를
#   ASCII 바이트로만 검색(utf-16 병행 없음) · 판정 스크립트 호출형(item <ID>·.dll/.exe 대상)에 plan_ref·pass_proof 없음.
#   새 항목 = 디스크 goal.json 이 없으면 전 항목, 있으면 디스크 acceptance 에 없던 id 의 항목(잠긴 기존 항목은 보지 않는다).
#   locked 무관·정적 모드 포함(실행 없음 — 문자열·파일 판독뿐). lint 부재·오류·시간 초과는 경고만(fail-open).
#   배경: D-5·D-6·D-8·D-9 — F-GOALAS-1·8 은 "수정 전 FAIL" 만 봐서 "의도한 구현으로도 PASS 불가" 인 판정기를 못 잡았다.
#   한계: pass_proof 진위·시그니처 추측의 의미는 기계로 못 가린다(스킬 점검 병행).
#   호출 위치: 기존 차단(F-GOALAS-3·8)의 사유·우선순위를 바꾸지 않도록 함수로 두고 각 통과 출구 직전에서 부른다
#     (4단계 비잠금·acceptance 비배열 출구 / 5c 정적 모드 출구 / 5e F-GOALAS-8 다음).
_f_goalas10() {
local _LINT10="${_HOOK_DIR}/lib/goal_judge_lint.py" _OUT10 _RC10 _BL10 _R10
if [[ -f "$_LINT10" ]] && command -v python3 >/dev/null 2>&1; then
  _OUT10=$(printf '%s' "$_CONTENT" | timeout 3 python3 -I "$_LINT10" "$_PATH" "$_SESSION_DIR" 2>/dev/null) && _RC10=0 || _RC10=$?
  if [[ "$_RC10" -eq 1 ]]; then
    _BL10=$(printf '%s\n' "$_OUT10" | sed -n 's/^BLOCK /   - /p')
    _R10="⛔ [F-GOALAS-10] goal.json 새 항목의 판정기가 확인 없이 가정한 형태입니다(의도한 구현으로도 PASS 못 할 수 있음).
${_BL10}
   대상 경로: ${_PATH} (도구: ${_TOOL})
→ 고칠 필드: judge_basis(HEAD 지원 실측 근거) · plan_ref(\"plans/계획.md:행\") · pass_proof(항목 id 와 rc=0 을 적은 파일)
   또는 판정 스크립트에 utf-16-le 검색 병행. 이미 기록된 항목에는 소급하지 않습니다.
→ 비상 시: hooks/DISABLE_GOAL_AUTOSCRIPT_GUARD 파일 생성으로 우회 가능. (차단 코드 F-GOALAS-10)"
    _log "BLOCK F-GOALAS-10 tool=${_TOOL} static=${_STATIC} $(printf '%s' "$_BL10" | tr '\n' ' ' | cut -c1-400)"
    jq -cn --arg r "$_R10" '{decision:"block", reason:$r}' 2>/dev/null \
      || echo '{"decision":"block","reason":"goal.json 새 항목의 판정기 근거 필드(judge_basis·plan_ref·pass_proof) 결함 (F-GOALAS-10)."}'
    exit 2
  elif [[ "$_RC10" -ne 0 ]]; then
    _log "WARN F-GOALAS-10 lint rc=${_RC10} — 판정 생략(fail-open)"
  fi
  if printf '%s\n' "$_OUT10" | grep -q '^WARN '; then
    printf '%s\n' "$_OUT10" | sed -n 's/^WARN /⚠️ [F-GOALAS-10] /p'
  fi
fi
return 0
}

# F-GOALAS-8 차단 출력 — $1=사유 본문(항목별 줄)
_f_goalas8_block() {
  local _R8="⛔ [F-GOALAS-8] 잠긴 goal.json 에 덧붙인 항목이 기록 시점에 FAIL 이 아닙니다.
$1
⇒ 덧붙인 항목은 수정 전 FAIL 이어야 합니다 — 이미 충족된 항목으로 범위를 부풀리거나 판정 못 하는 항목을 넣지 마십시오.
   (rc=0 = 이미 PASS, rc=3 = 판정불가(판정 스크립트·경로 부재 등), auto_script 빈 값 = 판정 수단 없음)
   대상 경로: ${_PATH} (도구: ${_TOOL})
→ 해결: 판정 스크립트에 그 항목(item)을 먼저 만들고, 지금 상태에서 FAIL(rc=1)인지 확인한 뒤 덧붙이십시오.
   덧붙이기는 mcp__oio__file_write 로 '기존 내용 그대로 + 새 항목'만 씁니다(write_guard F-GOAL-1 append 예외).
→ 비상 시: hooks/DISABLE_GOAL_AUTOSCRIPT_GUARD 파일 생성으로 우회 가능."
  _log "BLOCK F-GOALAS-8 ids=${_APPEND_IDS} tool=${_TOOL} static=${_STATIC}"
  jq -cn --arg r "$_R8" '{decision:"block", reason:$r}' 2>/dev/null \
    || echo '{"decision":"block","reason":"잠긴 goal.json 에 덧붙인 항목이 기록 시점에 FAIL 이 아닙니다 (F-GOALAS-8)."}'
  exit 2
}

# ── 4. locked==true AND acceptance 배열 존재 ───────────────────────────
#   [사이클182] 디스크가 잠겨 있고 덧붙인 항목이 있으면 새 내용 locked 와 무관하게 계속 판정한다(F-GOALAS-3·8).
_LOCKED=$(echo "$_CONTENT" | jq -r '.locked // false' 2>/dev/null) || exit 0
if [[ "$_LOCKED" != "true" ]]; then
  [[ "$_DISK_LOCKED" -eq 1 && -n "$_APPEND_ITEMS" ]] || { _f_goalas10; exit 0; }
fi

_HAS_ACC=$(echo "$_CONTENT" | jq -r 'if (.acceptance | type) == "array" then "yes" else "no" end' 2>/dev/null) || exit 0
[[ "$_HAS_ACC" == "yes" ]] || { _f_goalas10; exit 0; }

# ── 5. 진입 로그 ───────────────────────────────────────────────────────
_log "ENTER path=${_PATH} tool=${_TOOL} static=${_STATIC}"

# ── 5b. 기준C: auto_script 중복 검출 (F-GOALAS-3) ─────────────────────
# [사이클168] 정적 전용 모드에서도 호출할 수 있도록 실행 단계(6) 앞의 독립 함수로 분리했다.
#   판정 내용은 종전과 동일하다(실행 rc 와 무관한 순수 문자열 축).
# depends_on / rc 와 무관한 독립 축이다. 동일 스크립트를 가진 항목이 2개 이상이면
# 후행 항목은 선행과 절대 독립적으로 실패할 수 없으므로 검증력이 정의상 0 이다.
# 집계 실패는 fail-open (빈 값 → 차단 없음).
_f_goalas3() {
  local _DUP_TABLE="" _ITEM _ID _SCRIPT _NORM _DUP_REPORT="" _DUP_GROUPS _REASON3
  while IFS= read -r _ITEM; do
    [[ -z "$_ITEM" ]] && continue
    _ID=$(echo "$_ITEM" | jq -r '.id // "?"' 2>/dev/null)
    _SCRIPT=$(echo "$_ITEM" | jq -r '.auto_script // empty' 2>/dev/null)
    [[ -z "$_SCRIPT" ]] && continue
    # 정규화 = 공백류 문자를 전부 단일 공백으로 환산한 뒤 앞뒤 trim + 내부 연속 공백 축약.
    #   내부 축약까지 하는 이유 — 들여쓰기나 줄바꿈만 바꾼 사본은 의미가 동일한데도
    #   trim 만으로는 서로 다른 문자열이 되어 검출을 빠져나가기 때문이다.
    #   1단계 sed: 멀티바이트 유니코드 공백(NBSP U+00A0 / U+2000~U+200A / U+3000)을 ASCII 공백으로.
    #     tr 은 바이트 단위라 멀티바이트를 직접 다룰 수 없어 sed 를 앞에 둔다. LC_ALL=C 로 바이트 매칭 고정.
    #   2단계 tr: ASCII 공백류 5종 LF/TAB/CR/VT/FF 를 공백으로.
    #     ★CR 를 반드시 포함해야 한다★ — NTFS(CRLF) 환경에서 계약을 편집하면 CR 혼입이
    #     작정하지 않아도 발생하며, CR 이 남으면 기능적으로 동일한 스크립트가 서로 다른
    #     문자열이 되어 중복 검출을 그대로 빠져나간다 (사이클51-E otest 실측).
    #   실패해도 빈 값으로 두고 계속 진행한다 (fail-open).
    _NORM=$(printf '%s' "$_SCRIPT" \
      | LC_ALL=C sed -e 's/\xc2\xa0/ /g' -e 's/\xe2\x80[\x80-\x8a]/ /g' -e 's/\xe3\x80\x80/ /g' \
      | tr '\n\t\r\v\f' '     ' | tr -s ' ' | sed -e 's/^ *//' -e 's/ *$//' 2>/dev/null) || _NORM=""
    if [[ -n "$_NORM" ]]; then
      _DUP_TABLE="${_DUP_TABLE}${_NORM}"$'\t'"${_ID}"$'\n'
    fi
  done < <(echo "$_CONTENT" | jq -c '(.acceptance // [])[]' 2>/dev/null)

  if [[ -n "$_DUP_TABLE" ]]; then
    # [사이클182 반복1] 순수 덧붙이기면 새 id 가 낀 그룹만 본다(기존 항목끼리는 잠금 시점에 검사됨).
    #   새 항목이 기존 항목과 같은 auto_script 인 경우는 새 id 가 끼므로 그대로 차단된다.
    _DUP_REPORT=$(printf '%s' "$_DUP_TABLE" \
      | awk -F'\t' -v pure="$_PURE_APPEND" -v newids="$(printf '%s' "$_APPEND_IDLIST" | tr '\n' '\t')" '
          BEGIN { m = split(newids, a, "\t"); for (i = 1; i <= m; i++) if (a[i] != "") isnew[a[i]] = 1 }
          NF>=2 && $1!="" { k=$1; ids[k]=(k in ids ? ids[k] "/" $2 : $2); n[k]++; if ($2 in isnew) hn[k]=1 }
          END { for (k in n) if (n[k] > 1 && (pure != 1 || (k in hn))) printf "%s\n", ids[k] }' 2>/dev/null) || _DUP_REPORT=""
  fi
  [[ -n "$_DUP_REPORT" ]] || return 0

  _DUP_GROUPS=$(printf '%s' "$_DUP_REPORT" | paste -sd ', ' - 2>/dev/null) || _DUP_GROUPS="$_DUP_REPORT"
  _REASON3="⛔ [F-GOALAS-3] 서로 다른 acceptance 항목이 동일한 auto_script 를 갖고 있습니다: ${_DUP_GROUPS}
(같은 그룹으로 묶인 id 들이 글자까지 동일한 auto_script 를 공유합니다. 공백/개행 차이는 정규화 후 비교했습니다.)
⇒ 후행 항목은 선행과 독립적으로 실패할 수 없으므로 검증력이 정의상 0 입니다.
⇒ depends_on 유무·rc 와 무관하게 성립하는 구조적 결함이며, locked=true 계약의 의미가 사라집니다.
   실사고(D1/D6, 사이클51-C) — 두 항목의 auto_script 가
   'cd ${HARNESS_HOME:-$HOME/.harness}/current && test -f LESSONS.md' 로 글자까지 동일했습니다.
   D6 가 적발된 것은 depends_on 을 우연히 적었기 때문이며, 비웠다면 F-GOALAS-1 을 그대로 빠져나갔습니다.
   ⇒ 단일 판정축(depends_on)은 회피됩니다. 그래서 중복이라는 독립 축을 추가로 봅니다.

→ 해결: 각 항목이 '자기 항목만의 완료'를 확인하도록 auto_script 를 항목별로 분리하십시오.
   나쁜 예) E3, E4 가 모두 test -f LESSONS.md          (어느 쪽이 끝났는지 구별 불가)
   좋은 예) E3: grep -q '이번에 E3 이 추가할 문자열' /path/to/target
            E4: grep -q '이번에 E4 가 추가할 문자열' /path/to/target
   두 항목의 완료 조건이 정말 같다면, 그것은 별개 항목이 아니라 하나의 항목입니다. 병합하십시오.
→ 원칙: 게이트는 통과시켜야 할 것을 통과시키는지뿐 아니라,
        통과시키면 안 될 것을 막는지까지 양방향으로 검증되어야 합니다.
→ 비상 시: hooks/DISABLE_GOAL_AUTOSCRIPT_GUARD 파일 생성으로 우회 가능."

  _log "BLOCK F-GOALAS-3 groups=${_DUP_GROUPS}"
  jq -cn --arg r "$_REASON3" '{decision:"block", reason:$r}' 2>/dev/null \
    || echo '{"decision":"block","reason":"서로 다른 acceptance 항목이 동일한 auto_script 를 갖고 있습니다 (F-GOALAS-3)."}'
  exit 2
}

_f_goalas3

# ── 5c. 정적 전용 모드 종료 (I-2) — auto_script 실행·lib source 없음 ───────
if [[ "$_STATIC" -eq 1 ]]; then
  # [사이클182 항목8] 정적 모드는 auto_script 를 실행할 수 없다 — 덧붙이기가 보이면 수정 전 FAIL 을 확인할 수 없으므로 차단
  if [[ -n "$_APPEND_ITEMS" ]]; then
    _f_goalas8_block "   덧붙인 항목: ${_APPEND_IDS} — 정적 검사 경로(${_TOOL})에서는 기록 시점 판정을 할 수 없습니다(판정불가). 덧붙이기는 file_write 경로만 정식입니다."
  fi
  _f_goalas10
  _log "PASS static-only (F-GOALAS-4·3·10 통과, 실행 단계 생략)"
  exit 0
fi

# ── 5d. 공용 실행부 lib 로드 (C1 — bash -c 폴백 없음) ───────────────────
_HAS_SCRIPT=$(echo "$_CONTENT" | jq -r '[(.acceptance // [])[] | select(((.auto_script // "") | type) == "string" and (.auto_script // "") != "")] | length' 2>/dev/null) || _HAS_SCRIPT=0
_GAS_OK=0
# shellcheck source=/dev/null
source "${_HOOK_DIR}/lib/goal_autoscript_run.sh" 2>/dev/null && declare -F gas_eval >/dev/null 2>&1 && _GAS_OK=1
if [[ "$_GAS_OK" -ne 1 && "$_HAS_SCRIPT" =~ ^[0-9]+$ && "$_HAS_SCRIPT" -gt 0 ]]; then
  _log "BLOCK F-GOALAS-6 lib 부재/로드 실패"
  jq -cn --arg r "⛔ [F-GOALAS-6] 공용 실행부 lib 부재 — 계약 시점 판정(F-GOALAS-1) 불가, 판정불가는 통과가 아닙니다.
   필요 파일: ${_HOOK_DIR}/lib/goal_autoscript_run.sh
→ lib 를 복원한 뒤 계약을 쓰십시오. 비상 시: hooks/DISABLE_GOAL_AUTOSCRIPT_GUARD" \
    '{decision:"block", reason:$r}' 2>/dev/null \
    || echo '{"decision":"block","reason":"공용 실행부 lib 부재 — 판정불가는 통과가 아닙니다 (F-GOALAS-6)."}'
  exit 2
fi

# ── 5e. (사이클182 항목8) F-GOALAS-8 — 덧붙인 항목은 기록 시점에 FAIL(rc=1 등)이어야 한다 ──
#   lib 가 없으면 위 F-GOALAS-6 이 이미 차단했다(덧붙인 항목에 auto_script 가 있는 경우). 빈 auto_script 는 판정 수단 없음 = 차단.
if [[ -n "$_APPEND_ITEMS" ]]; then
  _BAD8=""
  while IFS= read -r _ITEM; do
    [[ -z "$_ITEM" ]] && continue
    _ID8=$(echo "$_ITEM" | jq -r '.id // "?" | tostring' 2>/dev/null)
    _S8=$(echo "$_ITEM" | jq -r '.auto_script // empty | tostring' 2>/dev/null)
    if [[ -z "$_S8" ]]; then
      _BAD8="${_BAD8}   - ${_ID8}: auto_script 빈 값(판정 수단 없음)"$'\n'
      continue
    fi
    if [[ "$_GAS_OK" -ne 1 ]]; then
      _BAD8="${_BAD8}   - ${_ID8}: 공용 실행부 lib 부재로 판정불가"$'\n'
      continue
    fi
    gas_eval "$_S8" "$_SESSION_DIR" 5
    _G8=$?
    # L-486: F-GOALAS-1 — depends_on 보유 항목이 계약 시점에 이미 rc=0 이면 물리 차단
    if [[ "$_G8" -eq 0 ]]; then
      _BAD8="${_BAD8}   - ${_ID8}: rc=0 — 이미 PASS"$'\n'
    elif [[ "$_G8" -eq 3 ]]; then
      _BAD8="${_BAD8}   - ${_ID8}: rc=3 — 판정불가 (${GAS_DETAIL:-사유 없음})"$'\n'
    fi
    _log "F-GOALAS-8 id=${_ID8} rc=${_G8}"
  done <<< "$_APPEND_ITEMS"
  if [[ -n "$_BAD8" ]]; then
    _f_goalas8_block "${_BAD8%$'\n'}"
  fi
fi

# ── 5f. [사이클214 R4] F-GOALAS-10 — F-GOALAS-3·8 다음(기존 차단 사유·우선순위 유지), 6단계 실행 앞 ──
_f_goalas10

# ── 6. 항목별 auto_script 계약 시점 실행 ───────────────────────────────
_VIOLATE_IDS=""
_WARN_IDS=""
_UNDET_IDS=""
_RAN=0
# (기준C 중복 검출은 5b 단계 _f_goalas3 로 이동 — 사이클168)

while IFS= read -r _ITEM; do
  [[ -z "$_ITEM" ]] && continue
  _ID=$(echo "$_ITEM" | jq -r '.id // "?"' 2>/dev/null)
  _SCRIPT=$(echo "$_ITEM" | jq -r '.auto_script // empty' 2>/dev/null)
  _NDEP=$(echo "$_ITEM" | jq -r '(.depends_on // []) | length' 2>/dev/null)
  [[ -z "$_SCRIPT" ]] && continue
  # [사이클182] 덧붙인 항목은 5e(F-GOALAS-8)에서 이미 판정했다 — 다시 실행하지 않는다(통과했다면 rc≠0·≠3)
  if [[ -n "$_APPEND_ITEMS" ]] && printf '%s\n' "$_APPEND_ITEMS" | jq -e --argjson it "$_ITEM" 'select(. == $it)' >/dev/null 2>&1; then
    continue
  fi
  # [사이클182 반복1] 순수 덧붙이기(3f)면 기존 항목은 재판정하지 않는다 — 잠금 시점에 검사됐고 F-GOAL-1 이 불변을 보장한다.
  #   작업 완료 뒤 depends_on 보유 기존 항목의 rc=0 은 정상이다(실측: G1·K5 가 F-GOALAS-1 로 덧붙이기를 막았다).
  if [[ "$_PURE_APPEND" -eq 1 ]]; then
    continue
  fi

  # 숫자가 아니면 판정 불가 → 건너뜀 (fail-open)
  case "$_NDEP" in
    ''|*[!0-9]*) continue ;;
  esac

  _RAN=$((_RAN + 1))
  # [사이클168] 공용 실행부 — GOAL_SESSION_DIR=goal.json 디렉터리, 옛 세션 경로 재매핑, 판정불가 구별
  gas_eval "$_SCRIPT" "$_SESSION_DIR" 5
  _GRC=$?
  if [[ "$_GRC" -eq 0 ]]; then
    # rc=0 — 계약 시점에 이미 충족
    if [[ "$_NDEP" -gt 0 ]]; then
      _VIOLATE_IDS="${_VIOLATE_IDS}${_VIOLATE_IDS:+, }${_ID}"
    else
      _WARN_IDS="${_WARN_IDS}${_WARN_IDS:+, }${_ID}"
    fi
  elif [[ "$_GRC" -eq 3 ]]; then
    # 판정불가 — 판정 스크립트 파일 부재 등. F-GOALAS-5 경고(계약 시점에는 스크립트가 아직 없을 수 있다)
    _UNDET_IDS="${_UNDET_IDS}${_UNDET_IDS:+, }${_ID}"
    _log "UNDET id=${_ID} 판정불가 — ${GAS_DETAIL}"
  fi
done < <(echo "$_CONTENT" | jq -c '(.acceptance // [])[]' 2>/dev/null)

_log "CHECK pure_append=${_PURE_APPEND} ran=${_RAN} violate=${_VIOLATE_IDS:-none} warn=${_WARN_IDS:-none} undet=${_UNDET_IDS:-none}"

# ── 6.5. (사이클168) 기준C F-GOALAS-3 은 5b 단계 _f_goalas3 로 이동했다 — 정적 전용 모드와 공용

# ── 7. 기준A: 차단 ─────────────────────────────────────────────────────
if [[ -n "$_VIOLATE_IDS" ]]; then
  _REASON="⛔ [F-GOALAS-1] 계약 시점에 이미 충족되는 auto_script 가 있습니다: ${_VIOLATE_IDS}
이 항목들은 depends_on 에 선행 항목이 있는데도, 지금(선행 미완 상태) auto_script 가 rc=0 입니다.
⇒ 선행이 미완인데 후행이 이미 충족 = 정의상 모순입니다.
⇒ 아무것도 하지 않아도 통과하는 게이트이므로 locked=true 계약의 의미가 사라집니다.
   실사고(L-483) — C6 auto_script 가 미커밋 상태를 완료로 오판정해 push 없이 완주 종료될 뻔했습니다.

→ 해결: 위 항목의 auto_script 를 '완료 후에만 rc=0' 이 되도록 강화하십시오.
   나쁜 예) test -f LESSONS.md                        (선행과 무관 — 항상 통과)
   나쁜 예) test -z \"\$(git log origin/master..HEAD)\"  (미커밋 상태를 완료로 오판정)
   좋은 예) cd /repo && test -z \"\$(git status --porcelain -- A B)\" && test -z \"\$(git log origin/master..HEAD --oneline)\"
   좋은 예) grep -q '이번에 실제로 추가할 문자열' /path/to/target
→ 원칙: 게이트는 통과시켜야 할 것을 통과시키는지뿐 아니라,
        통과시키면 안 될 것을 막는지까지 양방향으로 검증되어야 합니다.
→ 비상 시: hooks/DISABLE_GOAL_AUTOSCRIPT_GUARD 파일 생성으로 우회 가능."

  _log "BLOCK F-GOALAS-1 ids=${_VIOLATE_IDS}"
  jq -cn --arg r "$_REASON" '{decision:"block", reason:$r}' 2>/dev/null \
    || echo '{"decision":"block","reason":"계약 시점에 이미 rc=0 인 auto_script 가 있습니다 (F-GOALAS-1)."}'
  exit 2
fi

# ── 8. 기준B: 경고만 (차단 안 함) ──────────────────────────────────────
if [[ -n "$_WARN_IDS" ]]; then
  echo "⚠️ [F-GOALAS-2] depends_on 이 없고 계약 시점에 이미 rc=0 인 auto_script: ${_WARN_IDS}"
  echo "   존재 확인형(test -f ...)이면 정상입니다. 검증력이 필요한 항목이면 강화를 검토하십시오."
fi

# ── 8b. (사이클168) F-GOALAS-5: 계약 시점 판정불가 — 경고만 ──────────────
if [[ -n "$_UNDET_IDS" ]]; then
  echo "⚠️ [F-GOALAS-5] 계약 시점 판정불가(스크립트 파일 부재): ${_UNDET_IDS} — 판정 스크립트를 먼저 만든 뒤 계약을 쓰십시오."
  echo "   판정불가는 PASS 가 아닙니다. 실행부(done_gate·oto)는 이 상태를 차단합니다."
fi

_log "PASS ran=${_RAN}"
exit 0
