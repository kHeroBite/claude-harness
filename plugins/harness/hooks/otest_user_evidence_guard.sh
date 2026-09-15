#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# otest_user_evidence_guard.sh — 사용자 GUI evidence 강제화 (PreToolUse:Agent)
#
# 트리거: odone 팀에이전트 spawn 시
# 차단 조건: acceptance_criteria.json에 user_required=true인 항목이 있고,
#           evidence/user_evidence_pass 마커가 없을 때 fail-closed
#
# 배경 (LESSONS L-441):
#   클립보드/타이틀바/tmux 우클릭 메뉴 등 사용자 환경 의존 작업은 mock 검증이 false PASS 가능.
#   Get-Clipboard 왕복은 stdout 인코딩 손실로 mojibake — 실제 클립보드는 정상일 수 있음.
#   tmux source-file은 reload 성공해도 우클릭 동작은 사용자 마우스로만 검증 가능.
#   따라서 user_required=true 항목은 사용자 GUI evidence(스크린샷/사용자 메시지) 필수.
#
# 통과 조건 (둘 중 하나 만족):
#   1) acceptance_criteria.json에 user_required=true 항목 없음 (자동 검증으로 충분한 작업)
#   2) ${SESSION_DIR}/evidence/user_evidence_pass 파일 존재 (사용자 명시 PASS)
#
# Hook 1순위 적용 사유: LLM 의지 의존(SKILL.md 문서)이 아닌 물리 차단으로 강제화.

INPUT=$(timeout 5 cat 2>/dev/null) || INPUT=""
TEAM_NAME=$(echo "$INPUT" | jq -r '.tool_input.team_name // empty' 2>/dev/null || echo "")

# 팀에이전트 spawn 아니면 패스
[[ -z "$TEAM_NAME" ]] && exit 0

# odone spawn인지 확인
AGENT_NAME=$(echo "$INPUT" | jq -r '.tool_input.name // ""' 2>/dev/null || echo "")
echo "$AGENT_NAME" | grep -qE "^odone" || exit 0

# UUID 결정 (otest_done_guard.sh와 동일 패턴)
source "${HARNESS_HOOK_DIR}/lib/session_id.sh"
resolve_uuid "$INPUT" 2>/dev/null || UUID="${CLAUDE_SESSION_ID}"
if [[ -z "$UUID" ]]; then
  # UUID 해석 실패 → 차단 불가 (otest_done_guard.sh 동일 정책)
  _WARN_DIR="/tmp/claude_warn"
  mkdir -p "${_WARN_DIR}"
  echo "$(date '+%Y-%m-%d %H:%M:%S') [otest_user_evidence_guard] UUID 해석 실패 — odone spawn 허용 (팀명=${TEAM_NAME})" \
    >> "${_WARN_DIR}/pipeline_errors.log"
  exit 0
fi

SESSION_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}"
HOME_SESSION_DIR="$HOME/.claude/session-env/${UUID}"
# 사이클46 축① — 반대편 base 미러
source "${HARNESS_HOOK_DIR}/lib/session_mirror.sh" 2>/dev/null
type _mirror_file >/dev/null 2>&1 || _mirror_file() { :; }

# O1/O2는 acceptance_criteria.json 자체가 없을 가능성 — skip
CLASSIFICATION=$(cat "${SESSION_DIR}/classification" 2>/dev/null || echo "")
case "$CLASSIFICATION" in
  O1|O2|"") exit 0 ;;
esac

# acceptance_criteria.json 위치 확인 (NTFS + HOME 폴백)
AC_FILE="${SESSION_DIR}/plans/acceptance_criteria.json"
if [[ ! -f "$AC_FILE" && -f "${HOME_SESSION_DIR}/plans/acceptance_criteria.json" ]]; then
  AC_FILE="${HOME_SESSION_DIR}/plans/acceptance_criteria.json"
fi

# AC 파일 부재 시 → user_required 항목 없음으로 간주 → 통과
[[ -f "$AC_FILE" ]] || exit 0

# user_required=true 항목 개수 확인
USER_REQUIRED_COUNT=$(jq '[.. | objects | select(.user_required == true)] | length' "$AC_FILE" 2>/dev/null || echo "0")
[[ -z "$USER_REQUIRED_COUNT" || "$USER_REQUIRED_COUNT" == "null" ]] && USER_REQUIRED_COUNT=0

# user_required 항목 없으면 통과
if [[ "$USER_REQUIRED_COUNT" -eq 0 ]]; then
  exit 0
fi

# user_required 항목 있음 → user_evidence_pass 마커 필수
EVIDENCE_FILE="${SESSION_DIR}/evidence/user_evidence_pass"
HOME_EVIDENCE_FILE="${HOME_SESSION_DIR}/evidence/user_evidence_pass"

if [[ -f "$EVIDENCE_FILE" || -f "$HOME_EVIDENCE_FILE" ]]; then
  # 마커 mtime이 pipeline_start_time보다 이후인지 (잔류 방지)
  if [[ -f "$EVIDENCE_FILE" ]]; then
    EVIDENCE_MTIME=$(stat -c %Y "$EVIDENCE_FILE" 2>/dev/null || echo "0")
  else
    EVIDENCE_MTIME=$(stat -c %Y "$HOME_EVIDENCE_FILE" 2>/dev/null || echo "0")
  fi
  PIPELINE_START_FILE="${SESSION_DIR}/pipeline_start_time"
  [[ ! -f "$PIPELINE_START_FILE" && -f "${HOME_SESSION_DIR}/pipeline_start_time" ]] && \
    PIPELINE_START_FILE="${HOME_SESSION_DIR}/pipeline_start_time"
  if [[ -f "$PIPELINE_START_FILE" ]]; then
    PIPELINE_START=$(cat "$PIPELINE_START_FILE" 2>/dev/null || echo "0")
    if [[ "$EVIDENCE_MTIME" -le "$PIPELINE_START" ]]; then
      mkdir -p "${SESSION_DIR}/logs"
      echo "$(date '+%Y-%m-%d %H:%M:%S') [otest_user_evidence_guard] 잔류 user_evidence_pass — mtime(${EVIDENCE_MTIME}) <= pipeline_start(${PIPELINE_START}), 차단 (uuid=${UUID})" \
        >> "${SESSION_DIR}/logs/pipeline_errors.log"
      _mirror_file "${SESSION_DIR}/logs/pipeline_errors.log"
      echo '{"decision":"block","reason":"❌ 잔류 user_evidence_pass 마커! 이전 파이프라인 잔재입니다. 현재 파이프라인에서 사용자 GUI 검증을 다시 받으세요."}'
      exit 2
    fi
  fi
  # 통과
  exit 0
fi

# evidence 부재 → 차단
mkdir -p "${SESSION_DIR}/logs"
echo "$(date '+%Y-%m-%d %H:%M:%S') [otest_user_evidence_guard] user_evidence_pass 부재로 odone spawn 차단 (user_required_count=${USER_REQUIRED_COUNT}, classification=${CLASSIFICATION}, uuid=${UUID})" \
  >> "${SESSION_DIR}/logs/pipeline_errors.log"
_mirror_file "${SESSION_DIR}/logs/pipeline_errors.log"

cat <<'EOF'
{"decision":"block","reason":"❌ 사용자 GUI evidence 미수령! acceptance_criteria.json에 user_required=true 항목이 있습니다.\n\n필수 절차:\n1) 사용자에게 GUI 동작(클립보드 붙여넣기/타이틀바 표시/우클릭 메뉴 등) 직접 검증 요청\n2) 사용자가 PASS 확인 후, evidence/user_evidence_pass 파일 생성 (touch)\n3) odone 재spawn\n\n이유: mock 검증(예: Get-Clipboard 왕복)은 코드페이지 손실로 false PASS 가능. 사용자 환경 의존 작업은 GUI evidence 필수 (LESSONS L-441)."}
EOF
exit 2
