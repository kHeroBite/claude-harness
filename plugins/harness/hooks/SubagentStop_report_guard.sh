#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# 팀에이전트가 SendMessage 없이 턴을 끝내면 차단하는 SubagentStop hook (얇은 호출부)
#
# ★ 이벤트가 Stop 이 아니라 SubagentStop 인 이유 (바이너리 2.1.233 실측):
#     agent id 가 있으면 → SubagentStop / 없으면 → Stop. 상호 배타적이다.
#     팀에이전트 종료 시 Stop 은 절대 발화하지 않는다.
#     기존 hooks/Stop.sh 는 STALE-OK 롤백 전용 — 역할이 다르므로 건드리지 않는다.
#
# 판정 로직은 이 파일에 없다 (L-457 단일 출처). lib/report_guard.sh 가 유일한 판정처다.
# 이 파일은 stdin 파싱 → 호출 → 출력만 담당한다.
#
# 긴급 정지 스위치 (3중 — ①② 는 settings.json 무수정):
#     touch ~/.claude/hooks/DISABLE_REPORT_GUARD                  # ① 즉시 무력화
#     mv lib/report_guard.sh lib/report_guard.sh.disabled         # ② 판정 불능 → 전량 통과
#     settings.json 의 SubagentStop 블록 삭제 (백업본 복원)        # ③ 완전 제거
#
# fail-open 원칙: 모든 경로의 기본은 exit 0 이다. 차단은 단 한 곳에서만 일어난다.
#   set -e 는 절대 쓰지 않는다 — 중간 실패가 곧 차단이 되면 안 된다.

set -u

HOOKS_DIR="${HOME}/.claude/hooks"
LIB="${HOOKS_DIR}/lib/report_guard.sh"

# E0 — 긴급 정지 파일
[[ -f "${HOOKS_DIR}/DISABLE_REPORT_GUARD" ]] && exit 0

# E10 — 의존 도구 부재 시 통과
command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

# stdin 수집 (빈 입력 통과)
INPUT="$(cat 2>/dev/null)" || exit 0
[[ -z "$INPUT" ]] && exit 0

# E1 — stop_hook_active 이면 무조건 통과 (공식 권고. 재차단 루프 차단)
SHA="$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)" || exit 0
[[ "$SHA" == "true" ]] && exit 0

# E8 — agent_id 없음 = 메인 세션. 본 hook 대상 아님
AID="$(printf '%s' "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null)" || exit 0
[[ -z "$AID" ]] && exit 0

# E7 — 트랜스크립트 부재/읽기 불가 시 통과
TP="$(printf '%s' "$INPUT" | jq -r '.agent_transcript_path // empty' 2>/dev/null)" || exit 0
[[ -n "$TP" ]] || exit 0
[[ -r "$TP" ]] || exit 0

# 라이브러리 부재 시 통과 (긴급 정지 ②)
[[ -r "$LIB" ]] || exit 0

# E9 — 판정 격리. timeout 초과/비정상 종료는 전부 통과
VERDICT="$(timeout 2 bash "$LIB" verdict "$TP" 2>/dev/null)" || exit 0
[[ -n "$VERDICT" ]] || exit 0

# ⑦ 반환 규약 — "BLOCK " 접두 정확 일치일 때만 차단. UNKNOWN 포함 그 외 전부 통과
[[ "$VERDICT" == BLOCK\ * ]] || exit 0

# --- 여기서부터가 유일한 차단 경로 ---

# "BLOCK <턴번호> <도구수> <도구명목록>" 파싱
TURN="$(printf '%s' "$VERDICT" | awk '{print $2}')"
TOOLN="$(printf '%s' "$VERDICT" | awk '{print $3}')"
TOOLS="$(printf '%s' "$VERDICT" | cut -d' ' -f4-)"

# 방어: 숫자가 아니면 통과
case "$TURN"  in ''|*[!0-9]*) exit 0 ;; esac
case "$TOOLN" in ''|*[!0-9]*) exit 0 ;; esac

# JSON 안전화 — 따옴표/역슬래시/개행 제거 후 700자 절단
TOOLS="$(printf '%s' "$TOOLS" | tr -d '"\\' | tr '\n\r\t' '   ' | cut -c1-700)"
[[ -n "$TOOLS" ]] || TOOLS="(목록 없음)"

REASON="🚫 [H-3] 이번 턴에 SendMessage 호출이 0건입니다. 화면 텍스트 출력은 team-lead에게 전달되지 않습니다(2026-08-17 verify-1/diag-1/odev-2 3건 실측). 방금 작성한 보고 내용을 그대로 SendMessage(to:\\\"team-lead\\\") 도구로 발신하세요. 보고할 내용이 없으면 그 사실을 SendMessage로 1줄 회신하면 됩니다. [이번 턴 도구 ${TOOLN}건: ${TOOLS}] [턴 #${TURN}]"

printf '{"decision":"block","reason":"%s"}\n' "$REASON"
exit 2
