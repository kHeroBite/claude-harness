#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# 팀에이전트 spawn prompt에 CLAUDE_CONFIG_DIR/PIPELINE_UUID 명시 검증 hook
# PreToolUse(Agent) 발동 — 팀에이전트 spawn prompt 환경변수 명시 검증
#
# 배경 (L-411):
#   팀에이전트 spawn 시 prompt에 PIPELINE_UUID와 CLAUDE_CONFIG_DIR이 명시되지 않으면
#   팀에이전트가 잘못된 session-env 디렉토리를 참조하게 되어 상태 파일 누락 및
#   파이프라인 추적 불가 사고가 발생함.
#
# 동작:
#   - PIPELINE_UUID=<36자 UUID> 패턴 누락 시 block
#   - CLAUDE_CONFIG_DIR=<절대경로> 패턴 누락 시 block
#   - 둘 다 존재 시 exit 0 (통과)
#   - prompt 추출 실패 시 warning + exit 0 (false-positive 방지)

trap 'exit 0' ERR

INPUT=$(timeout 5 cat 2>/dev/null) || INPUT=""

# tool_name 확인 — Agent 도구만 처리
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
[[ "$TOOL_NAME" != "Agent" ]] && exit 0

# 팀에이전트(PIPELINE_UUID 보유)는 서브에이전트 spawn이 자유 → 이 hook 검증 스킵
# (팀에이전트 내부 서브에이전트는 환경변수를 별도로 수신하므로 검증 대상 아님)
[[ -n "${PIPELINE_UUID:-}" ]] && exit 0

# ── ★2026-09-15 사이클133 — 판별축을 name 유무에서 "팀 spawn 의도"로 교체★ ────
# 구 코드: tool_input.name 이 있으면 팀에이전트 spawn 으로 간주했다.
#   그 결과 name 을 붙인 ★모든★ 호출에 PIPELINE_UUID/CLAUDE_CONFIG_DIR 을 요구했고,
#   메인 환경에는 PIPELINE_UUID 환경변수가 없으므로 IDLE 새 세션에서 무조건 차단됐다.
#   동시에 F-AGENT-1 은 name 부재를 차단했다 ⇒ ★양방향 데드락★ (실측 재현).
#
# 신 코드: prompt 의 PIPELINE_UUID 선언 유무로 판별한다(F-AGENT-1 과 ★동일 축·동일 방향★).
#   두 hook 이 같은 축을 같은 방향으로 쓰므로 통과 집합이 공집합이 되는 조합이 소멸한다.
#
# ★L-411 방지력은 100% 보존된다★:
#   본 hook 의 목적은 "팀에이전트가 잘못된 session-env 를 참조하는 것"을 막는 것이다.
#   그 대상은 PIPELINE_UUID 를 선언한 spawn 이며, 아래 검증 로직은 한 줄도 바뀌지 않는다.
#   CLAUDE_CONFIG_DIR 누락은 선언이 있는 한 종전대로 rc=2 로 차단된다(C조건).
PROMPT=$(echo "$INPUT" | jq -r '.tool_input.prompt // empty' 2>/dev/null)

# fail-safe: prompt 추출 실패 → 검증 스킵(통과).
#   기존에 채택했던 false-positive 방지 정책과 동일 방향이다.
if [[ -z "$PROMPT" ]]; then
  echo "⚠️ [team_agent_env_guard] prompt 추출 실패 — 검증 스킵 (false-positive 방지)" >&2
  exit 0
fi

# 팀 spawn 의도가 없으면(= PIPELINE_UUID 선언 없음) 이 hook 의 대상이 아니다 → 스킵.
if ! printf '%s' "$PROMPT" \
     | grep -qE 'PIPELINE_UUID=[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' 2>/dev/null; then
  exit 0
fi

# 로그·오류 메시지용 이름 (판정에는 쓰지 않는다 — 구 판별축 잔재 제거)
TOOL_NAME_PARAM=$(echo "$INPUT" | jq -r '.tool_input.name // empty' 2>/dev/null)
[[ -z "$TOOL_NAME_PARAM" ]] && TOOL_NAME_PARAM="<none>"

# 공용 라이브러리 로딩
LIB_DIR="$(dirname "${BASH_SOURCE[0]}")/lib"
# shellcheck source=/dev/null
source "${LIB_DIR}/agent_prompt_validate.sh" 2>/dev/null || {
  echo "⚠️ [team_agent_env_guard] agent_prompt_validate.sh 로딩 실패 — 검증 스킵" >&2
  exit 0
}

# UUID 및 로그 디렉토리 결정
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
CLAUDE_CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
LOG_DIR="${CLAUDE_CFG}/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG_FILE="${LOG_DIR}/team_agent_env_guard.log"

# PIPELINE_UUID 검증
UUID_OK=0
EXTRACTED_UUID=""
EXTRACTED_UUID=$(validate_pipeline_uuid "$PROMPT") && UUID_OK=1

# CLAUDE_CONFIG_DIR 검증
CFG_OK=0
EXTRACTED_CFG=""
EXTRACTED_CFG=$(validate_claude_config_dir "$PROMPT") && CFG_OK=1

# 둘 다 통과 → exit 0
if [[ $UUID_OK -eq 1 && $CFG_OK -eq 1 ]]; then
  exit 0
fi

# 누락 항목 정리
MISSING_LIST=""
[[ $UUID_OK -eq 0 ]] && MISSING_LIST="${MISSING_LIST}PIPELINE_UUID "
[[ $CFG_OK -eq 0 ]] && MISSING_LIST="${MISSING_LIST}CLAUDE_CONFIG_DIR "
MISSING_LIST="${MISSING_LIST% }"  # 후행 공백 제거

# 로그 기록
{
  echo "=== [$(date -Iseconds)] team_agent_env_guard BLOCK ==="
  echo "  agent_name: ${TOOL_NAME_PARAM}"
  echo "  session_id: ${SESSION_ID}"
  echo "  누락 항목: ${MISSING_LIST}"
  echo "  PIPELINE_UUID 추출결과: ${EXTRACTED_UUID:-<없음>}"
  echo "  CLAUDE_CONFIG_DIR 추출결과: ${EXTRACTED_CFG:-<없음>}"
} >> "$LOG_FILE" 2>/dev/null || true

REASON="❌ [team_agent_env_guard] 팀에이전트 spawn prompt에 필수 환경변수 누락: ${MISSING_LIST}

팀에이전트는 메인과 다른 세션 ID를 가지므로, prompt에 아래 두 항목을 반드시 명시해야 합니다.

누락된 항목: ${MISSING_LIST}

올바른 prompt 예시 (필수 환경변수 포함):
  PIPELINE_UUID=<36자 UUID>
  CLAUDE_CONFIG_DIR=<절대경로>

예시:
  PIPELINE_UUID=69f5472a-3b77-4fb8-b03c-273eed4b13e8
  CLAUDE_CONFIG_DIR=/tmp/cc-1c914fcc-47c7-4c2a-b73a-ae58e7331558

참고: ok SKILL.md 또는 odev SKILL.md 팀에이전트 spawn 절차 확인."

# JSON escape (newline → \n) — F-JSON-ESC-1: 문자열 연결 fallback이 개행 미이스케이프로
# 깨진 JSON("Expected '}'" 류 파싱 실패)을 유발하던 결함 수정.
# python3 실패 시 jq -Rs로 2차 인코딩, 둘 다 실패 시 개행 없는 고정 안전 문구로 대체(연결 금지).
REASON_ESC=$(echo "$REASON" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null) \
  || REASON_ESC=$(printf '%s' "$REASON" | jq -Rs '.' 2>/dev/null) \
  || REASON_ESC='"❌ [team_agent_env_guard] 필수 환경변수 누락 (REASON 인코딩 실패 — 로그 확인 필요)"'

echo "{\"decision\":\"block\",\"reason\":${REASON_ESC}}" | tee /dev/stderr
exit 2
