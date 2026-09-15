#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# goal.json 계약 생성 시점에 이미 rc=0 인 무의미 auto_script 를 물리 차단하는 hook
# PreToolUse:mcp__oio__file_write — tool_input.path 가 session-env/<UUID>/goal.json 인 경우만 검사
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
#   기준C (차단, F-GOALAS-3): 서로 다른 항목이 동일한 auto_script 문자열을 보유
#     → 후행 항목의 검증력이 정의상 0. depends_on 유무와 무관하게 성립하는 구조적 결함.
#
# 기준C 신설 배경 (사이클51-D 실측 — 단일 판정축은 회피된다):
#   기준A 는 depends_on 축 하나만 본다. 그래서 depends_on 을 비우기만 하면
#   무의미 게이트가 기준B 경고만 받고 그대로 통과한다(rc=0 실측 확인).
#   실사고 D1/D6 (사이클51-C):
#     D1  depends_on=[]      auto_script="cd /mnt/c/DATA/Project/AI && test -f LESSONS.md"
#     D6  depends_on=["D1"]  auto_script="cd /mnt/c/DATA/Project/AI && test -f LESSONS.md"  ← 글자까지 동일
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

_HOOK_DIR="$HOME/.claude/hooks"

# ── 0. 비상 스위치 (최우선) ────────────────────────────────────────────
[[ -f "${_HOOK_DIR}/DISABLE_GOAL_AUTOSCRIPT_GUARD" ]] && exit 0

INPUT=$(timeout 5 cat) || exit 0
[[ -z "$INPUT" ]] && exit 0

# jq 없으면 검사 불가 → fail-open
command -v jq >/dev/null 2>&1 || exit 0

# ── 1. 도구 판별 ───────────────────────────────────────────────────────
_TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
[[ "$_TOOL" == "mcp__oio__file_write" ]] || exit 0

# ── 2. 경로 판별: session-env/<UUID>/goal.json ─────────────────────────
_PATH=$(echo "$INPUT" | jq -r '.tool_input.path // .tool_input.file_path // empty' 2>/dev/null) || exit 0
[[ "$_PATH" =~ session-env/[^/]+/goal\.json$ ]] || exit 0

# ── 3. content 추출 + JSON 유효성 ──────────────────────────────────────
_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // .tool_input.text // .tool_input.body // empty' 2>/dev/null) || exit 0
[[ -z "$_CONTENT" ]] && exit 0

echo "$_CONTENT" | jq -e . >/dev/null 2>&1 || exit 0

# ── 4. locked==true AND acceptance 배열 존재 ───────────────────────────
_LOCKED=$(echo "$_CONTENT" | jq -r '.locked // false' 2>/dev/null) || exit 0
[[ "$_LOCKED" == "true" ]] || exit 0

_HAS_ACC=$(echo "$_CONTENT" | jq -r 'if (.acceptance | type) == "array" then "yes" else "no" end' 2>/dev/null) || exit 0
[[ "$_HAS_ACC" == "yes" ]] || exit 0

# ── 5. 진입 로그 ───────────────────────────────────────────────────────
_SESSION_DIR=$(dirname "$_PATH")
_LOG_FILE="${_SESSION_DIR}/logs/goal_autoscript_guard.log"
mkdir -p "${_SESSION_DIR}/logs" 2>/dev/null
_log() {
  echo "$(date '+%Y-%m-%dT%H:%M:%S%z') $*" >> "$_LOG_FILE" 2>/dev/null || true
}
_log "ENTER path=${_PATH}"

# ── 6. 항목별 auto_script 계약 시점 실행 ───────────────────────────────
_VIOLATE_IDS=""
_WARN_IDS=""
_RAN=0
# 기준C 용 — 정규화된 auto_script 를 "<정규화문자열>\t<id>" 라인으로 누적
_DUP_TABLE=""

while IFS= read -r _ITEM; do
  [[ -z "$_ITEM" ]] && continue
  _ID=$(echo "$_ITEM" | jq -r '.id // "?"' 2>/dev/null)
  _SCRIPT=$(echo "$_ITEM" | jq -r '.auto_script // empty' 2>/dev/null)
  _NDEP=$(echo "$_ITEM" | jq -r '(.depends_on // []) | length' 2>/dev/null)
  [[ -z "$_SCRIPT" ]] && continue

  # 기준C: 정규화 = 공백류 문자를 전부 단일 공백으로 환산한 뒤 앞뒤 trim + 내부 연속 공백 축약.
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

  # 숫자가 아니면 판정 불가 → 건너뜀 (fail-open)
  case "$_NDEP" in
    ''|*[!0-9]*) continue ;;
  esac

  _RAN=$((_RAN + 1))
  if timeout 5 bash -c "$_SCRIPT" >/dev/null 2>&1; then
    # rc=0 — 계약 시점에 이미 충족
    if [[ "$_NDEP" -gt 0 ]]; then
      _VIOLATE_IDS="${_VIOLATE_IDS}${_VIOLATE_IDS:+, }${_ID}"
    else
      _WARN_IDS="${_WARN_IDS}${_WARN_IDS:+, }${_ID}"
    fi
  fi
done < <(echo "$_CONTENT" | jq -c '(.acceptance // [])[]' 2>/dev/null)

_log "CHECK ran=${_RAN} violate=${_VIOLATE_IDS:-none} warn=${_WARN_IDS:-none}"

# ── 6.5. 기준C: auto_script 중복 검출 (F-GOALAS-3) ─────────────────────
# depends_on / rc 와 무관한 독립 축이다. 동일 스크립트를 가진 항목이 2개 이상이면
# 후행 항목은 선행과 절대 독립적으로 실패할 수 없으므로 검증력이 정의상 0 이다.
# 집계 실패는 fail-open (빈 값 → 차단 없음).
_DUP_REPORT=""
if [[ -n "$_DUP_TABLE" ]]; then
  _DUP_REPORT=$(printf '%s' "$_DUP_TABLE" \
    | awk -F'\t' 'NF>=2 && $1!="" { k=$1; ids[k]=(k in ids ? ids[k] "/" $2 : $2); n[k]++ }
                  END { for (k in n) if (n[k] > 1) printf "%s\n", ids[k] }' 2>/dev/null) || _DUP_REPORT=""
fi

if [[ -n "$_DUP_REPORT" ]]; then
  _DUP_GROUPS=$(printf '%s' "$_DUP_REPORT" | paste -sd ', ' - 2>/dev/null) || _DUP_GROUPS="$_DUP_REPORT"
  _REASON3="⛔ [F-GOALAS-3] 서로 다른 acceptance 항목이 동일한 auto_script 를 갖고 있습니다: ${_DUP_GROUPS}
(같은 그룹으로 묶인 id 들이 글자까지 동일한 auto_script 를 공유합니다. 공백/개행 차이는 정규화 후 비교했습니다.)
⇒ 후행 항목은 선행과 독립적으로 실패할 수 없으므로 검증력이 정의상 0 입니다.
⇒ depends_on 유무·rc 와 무관하게 성립하는 구조적 결함이며, locked=true 계약의 의미가 사라집니다.
   실사고(D1/D6, 사이클51-C) — 두 항목의 auto_script 가
   'cd /mnt/c/DATA/Project/AI && test -f LESSONS.md' 로 글자까지 동일했습니다.
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
fi

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

_log "PASS ran=${_RAN}"
exit 0
