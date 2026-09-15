#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# PostToolUse_Skill_ointaug_format.sh — PostToolUse:Skill hook
# 목적: ointaug 실행 직후 "확장 질의 4항목" 형식 준수를 강제 (F-INTAUG-2)
#
# 배경 (2026-09-13 실사고):
#   F-INTAUG-1 은 "ointaug 를 호출했는가" 만 검사한다.
#   메인이 ointaug 를 호출은 하되 출력에서 `확장 질의:` 블록을 통째로 생략하고
#   의도분석 한 줄만 낸 사례가 발생했다. 사이클이 길어지며 점진적으로 축소됐고,
#   사용자가 "간소화된 게 의도한 바냐"고 묻기 전까지 아무도 감지하지 못했다.
#   SKILL.md 핵심 원칙 1 은 "항상 확장 — 원문보다 짧아지면 절대 안 됨" 인데
#   실제 출력은 원문보다 압축돼 있었다.
#
# 설계 한계 (숨기지 않는다):
#   hook 은 어시스턴트의 ★출력 텍스트에 접근할 수 없다★. PreToolUse/PostToolUse 는
#   도구 입출력만 본다. 따라서 "화면에 4항목을 출력했는가" 를 직접 검사하는 것은 불가능하다.
#   대신 ointaug 가 마커에 ★형식 준수 증거★ 를 남기게 하고 그것을 검사한다.
#   ⇒ 물리 차단 점수 6/10. 마커에만 쓰고 화면에 안 쓰는 우회가 이론상 가능하다.
#     완전 차단이 불가능함을 인정하고, 대신 ★위반을 즉시 가시화★ 하는 데 목적을 둔다.
#
# 동작:
#   Skill('ointaug') 실행 직후 마커(ointaug_done)를 검사한다.
#   - epoch 초만 있는 구 형식  → 경고 출력 (차단하지 않음 — 하위 호환)
#   - 형식 증거가 있는 신 형식 → 4항목 존재 확인, 미달 시 경고
#   경고는 stderr 로 나가 다음 턴 컨텍스트에 실린다.
#
# 왜 block(rc=2) 이 아니라 경고인가:
#   ointaug 는 이미 실행이 끝난 시점이라 차단해도 되돌릴 것이 없다.
#   block 하면 후속 스킬만 막혀 사용자 요청 처리가 중단되는데, 그것은 과잉 조치다.
#   대신 경고를 컨텍스트에 실어 ★같은 턴 안에서 메인이 보강 출력★ 하도록 유도한다.

trap 'exit 0' ERR
INPUT=$(timeout 5 cat 2>/dev/null) || INPUT=""
SKILL_NAME=$(echo "$INPUT" | jq -r '(.tool_input.skill // .tool_input.skill_name // empty)' 2>/dev/null)
[[ "$SKILL_NAME" == "ointaug" ]] || exit 0

source "${HARNESS_HOOK_DIR}/lib/session_id.sh" 2>/dev/null || exit 0
resolve_uuid "$INPUT" || exit 0
[[ -z "$UUID" ]] && exit 0

# 팀/서브에이전트 스킵 — ointaug 는 메인 전용이다
if [[ -n "${PIPELINE_UUID:-}" && "${PIPELINE_UUID:-}" != "$MY_UUID" ]] || [[ "$MY_UUID" != "$UUID" ]]; then
  exit 0
fi

SESSION_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}"
MARK1="${SESSION_DIR}/ointaug_done"
MARK2="$HOME/.claude/session-env/${UUID}/ointaug_done"

MARK=""
for M in "$MARK1" "$MARK2"; do
  [[ -f "$M" ]] && MARK="$M" && break
done

# 마커 자체가 없으면 F-INTAUG-1 소관이다 — 여기서 중복 경고하지 않는다
[[ -z "$MARK" ]] && exit 0

CONTENT=$(cat "$MARK" 2>/dev/null)

# 4항목 존재 검사 — 마커에 형식 증거가 담긴 경우에만 판정 가능
MISSING=""
echo "$CONTENT" | grep -q '대상:'      || MISSING="${MISSING} 대상"
echo "$CONTENT" | grep -q '조건:'      || MISSING="${MISSING} 조건"
echo "$CONTENT" | grep -q '성공기준:'  || MISSING="${MISSING} 성공기준"
echo "$CONTENT" | grep -q '컨텍스트:'  || MISSING="${MISSING} 컨텍스트"

# 구 형식(epoch 초 단독) — 하위 호환. 전환 안내만 하고 넘어간다
if [[ "$CONTENT" =~ ^[0-9]+$ ]]; then
  cat <<'EOF' >&2
⚠️ [F-INTAUG-2] ointaug 마커가 구 형식(epoch 초 단독)이다 — 형식 준수를 검증할 수 없다.

ointaug/SKILL.md 출력 형식은 아래 4항목을 요구한다.
  확장 질의:
  - 대상: {파일/컴포넌트}
  - 조건: {제약}
  - 성공기준: {완료 판정}
  - 컨텍스트: {프로젝트 상태}

다음 호출부터 마커에 형식 증거를 함께 기록하라 (session_state value 에 4항목 포함).
검증 가능한 형태로 남겨야 축소가 재발했을 때 즉시 드러난다.
EOF
  exit 0
fi

if [[ -n "$MISSING" ]]; then
  cat <<EOF >&2
⛔ [F-INTAUG-2] ointaug 확장 질의 형식 미달 — 누락 항목:${MISSING}

SKILL.md 핵심 원칙 1: "항상 확장 — 원문 질의보다 짧아지면 절대 안 됨".
의도분석 한 줄로 대체하는 축소는 위반이다(2026-09-13 실사고 — 사이클이 길어지며 점진 축소됐다).

지금 이 턴에서 누락 항목을 보강해 출력하라. 4항목 전부 필요하다.
  - 대상: {파일/컴포넌트}   - 조건: {제약}
  - 성공기준: {완료 판정}   - 컨텍스트: {프로젝트 상태}
EOF
  exit 0
fi

exit 0
