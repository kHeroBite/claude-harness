#!/bin/bash
# sendmessage_ack_write.sh — F2 ACK 2단계 팀에이전트 측 hook
# 이벤트: PostToolUse:SendMessage
# 역할: shutdown_response 발신 감지 → ack/*.received + ack/*.done 동시 기록
# 출처: oplan_final_v2 §4 F2, debate_3_v2 §2.4
#
# 설계 원칙 (jury 확정):
#   V3 B / V12 A: pane_id 역검색 단일 경로. CLAUDE_AGENT_NAME 절대 사용 금지.
#   엣지케이스 전부 fail-open (E1~E7):
#     E1: tmux 서버 부재 → silent exit 0
#     E2: pane 이미 소멸 → 호출 자체 불가 (도달 불가능)
#     E3: agents/* 미매치 (메인/ok 등) → silent exit 0
#     E4: hook 내부 I/O 차단 (write_guard) → set -e 없음, 실패 무시
#     E5: JSON 파싱 실패 → silent exit 0
#     E6: 다중 세션 race → pane_id_to_agent_name 첫 매치 + UUID 우선
#     E7: request_id 누락 → 경로 suffix 없이 기록 (하위 호환)

# fail-open: 어떤 실패도 Claude Code 런타임을 막지 않는다
trap 'exit 0' ERR
set +e

# 1. stdin JSON 파싱 (timeout 2초)
INPUT=$(timeout 2 cat 2>/dev/null) || INPUT=""
[ -z "$INPUT" ] && exit 0

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
[ "$TOOL_NAME" != "SendMessage" ] && exit 0

# 2. 메시지 타입 분기
MSG_TYPE=$(printf '%s' "$INPUT" | jq -r '.tool_input.message.type // empty' 2>/dev/null)

# 2a. shutdown_response가 아닌 경우: 일반 메시지 → team-lead 수신 + 팀에이전트 발신 시 evidence 기록
if [ "$MSG_TYPE" != "shutdown_response" ]; then
  # team-lead에게 발신된 메시지인지 확인
  MSG_TO=$(printf '%s' "$INPUT" | jq -r '.tool_input.to // empty' 2>/dev/null)
  [ "$MSG_TO" != "team-lead" ] && exit 0

  # UUID 결정 (PIPELINE_UUID 우선)
  _SID_EARLY=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null) || _SID_EARLY=""
  if [[ -n "${PIPELINE_UUID:-}" ]]; then
    _UUID_EARLY="$PIPELINE_UUID"
  elif [[ -n "$_SID_EARLY" ]]; then
    _UUID_EARLY="$_SID_EARLY"
  else
    exit 0
  fi
  [ -z "$_UUID_EARLY" ] && exit 0

  # 라이브러리 로드
  HOOK_DIR_EARLY="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")" 2>/dev/null && pwd)}"
  SESSION_ID_LIB_EARLY="${HOOK_DIR_EARLY}/.claude/hooks/lib/session_id.sh"
  if [ ! -f "$SESSION_ID_LIB_EARLY" ]; then
    SESSION_ID_LIB_EARLY="$(dirname "$0")/lib/session_id.sh"
  fi
  [ -f "$SESSION_ID_LIB_EARLY" ] || exit 0
  # shellcheck disable=SC1090
  . "$SESSION_ID_LIB_EARLY" 2>/dev/null || exit 0

  # 발신자(팀에이전트) 식별: agents/ 에 등록된 이름인지 확인
  RESOLVED_EARLY=$(resolve_sender_from_tmux "$_UUID_EARLY" 2>/dev/null) || exit 0
  [ -z "$RESOLVED_EARLY" ] && exit 0
  _MY_NAME_EARLY="${RESOLVED_EARLY##*|}"
  [ -z "$_MY_NAME_EARLY" ] && exit 0

  # agents/ 에 등록된 에이전트인지 확인 (팀에이전트만 기록)
  # agents/{name}은 파일 — 디렉토리가 아니므로 파일 존재 여부로 판정
  _AGENTS_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${_UUID_EARLY}/agents"
  if [ ! -e "${_AGENTS_DIR}/${_MY_NAME_EARLY}" ]; then exit 0; fi

  # summary 추출
  _SUMMARY_EARLY=$(printf '%s' "$INPUT" | jq -r '.tool_input.summary // empty' 2>/dev/null) || _SUMMARY_EARLY=""

  # evidence 디렉토리 생성 + 기록 (최신 덮어쓰기)
  _EVIDENCE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${_UUID_EARLY}/evidence"
  mkdir -p "$_EVIDENCE_DIR" 2>/dev/null || true
  _REPORT_FILE="${_EVIDENCE_DIR}/agent_report_${_MY_NAME_EARLY}.json"
  _TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
  printf '{"agent":"%s","summary":%s,"timestamp":"%s"}\n' \
    "$_MY_NAME_EARLY" \
    "$(printf '%s' "$_SUMMARY_EARLY" | jq -Rs '.' 2>/dev/null || printf '""')" \
    "$_TS" > "$_REPORT_FILE" 2>/dev/null || true

  exit 0
fi

# 2b. shutdown_response 타입 처리 (기존 로직 — 절대 변경 금지)

REQUEST_ID=$(printf '%s' "$INPUT" | jq -r '.tool_input.message.request_id // empty' 2>/dev/null)
# D-3: 승인 여부를 .done 에 남긴다. 불리언 true/false 와 문자열 "true"/"false" 만 인정하고 그 외는 빈 값(기록 안 함).
APPROVE=$(printf '%s' "$INPUT" | jq -r '.tool_input.message.approve | if . == true or . == "true" then "true" elif . == false or . == "false" then "false" else empty end' 2>/dev/null) || APPROVE=""
# E7: request_id 누락도 허용 (빈 문자열로 진행)

# 3. 라이브러리 선행 로드 — session_id.sh (state_read) + ack_utils.sh
# F6 규칙: state 파일 읽기는 반드시 state_read() 함수 경유 (raw awk 금지).
HOOK_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")" 2>/dev/null && pwd)}"
SESSION_ID_LIB="${HOOK_DIR}/.claude/hooks/lib/session_id.sh"
ACK_LIB="${HOOK_DIR}/.claude/hooks/lib/ack_utils.sh"
if [ ! -f "$SESSION_ID_LIB" ]; then
  SESSION_ID_LIB="$(dirname "$0")/lib/session_id.sh"
fi
if [ ! -f "$ACK_LIB" ]; then
  ACK_LIB="$(dirname "$0")/lib/ack_utils.sh"
fi
[ -f "$SESSION_ID_LIB" ] || exit 0
# shellcheck disable=SC1090
. "$SESSION_ID_LIB" 2>/dev/null || exit 0

# 4. UUID 결정 — PIPELINE_UUID(팀에이전트) > SESSION_ID(자기 세션) 순서
# [P2-isolation] session-env/*/ 전체 순회 제거 — §(a)(d) 준수 (Fix 16, 2026-04-24)
# 타 세션 UUID를 스캔으로 역추적하는 방식은 §(d) 위반. PIPELINE_UUID를 직접 사용.
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null) || SESSION_ID=""
if [[ -n "${PIPELINE_UUID:-}" ]]; then
  UUID="$PIPELINE_UUID"
elif [[ -n "${SESSION_ID:-}" ]]; then
  UUID="$SESSION_ID"
else
  exit 0
fi
[ -z "$UUID" ] && exit 0

# 5. ack_utils.sh 로드 (fail-open)
[ -f "$ACK_LIB" ] || exit 0
# shellcheck disable=SC1090
. "$ACK_LIB" 2>/dev/null || exit 0

# 6. 발신자 식별
# [c182 ACK 근본 수정] 이 hook 은 ★응답한 팀원 프로세스★ 에서 돈다. PIPELINE_UUID env 는 hook 자식에
#   전달되지 않아(sprint R1 실측) UUID 는 팀원 자신의 .session_id 가 되고, 리드 sweep 은 ★리드 UUID★/ack 를
#   기다린다 → ACK 가 한 번도 도달하지 않았다(실측: 리드 로그 ACK_RECEIVED_RETRY 132건·ACK_RECEIVED 0건,
#   ack/ 디렉토리는 어느 세션에도 없음 — 팀원 UUID 에 agents/ 가 없어 아래 역검색도 실패).
#   1순위: chain_agent_resolve(조상 argv --agent-id NAME@TEAM + --parent-session-id LEAD, 리드 team_name==TEAM
#          검증) 통과 시 ★리드 UUID 하위 자기 이름 ACK★ 만 기록한다. 그 외 타 세션은 건드리지 않는다(§a).
#          본 프로세스에서 직접 호출 — $( )·timeout 으로 감싸면 조상 6단계 한도를 잃는다.
#   2순위(증명 실패): 종전 경로(자기 UUID + pane 역검색) 그대로.
MY_NAME=""
CA_LIB="$(dirname "$ACK_LIB")/chain_agent.sh"
if [ -r "$CA_LIB" ] && . "$CA_LIB" 2>/dev/null && chain_agent_resolve 2>/dev/null; then
  UUID="$CA_LEAD"
  MY_NAME="$CA_NAME"
else
  # 자기 pane_id → agent name 역검색 (E1/E3 fail-open)
  RESOLVED=$(resolve_sender_from_tmux "$UUID" 2>/dev/null) || exit 0
  [ -z "$RESOLVED" ] && exit 0

  MY_PANE="${RESOLVED%%|*}"
  MY_NAME="${RESOLVED##*|}"
fi
[ -z "$MY_NAME" ] && exit 0

# 7. ACK 2단계 동시 기록 (received + done)
# - received: "shutdown 메시지 수신 확증" (시간적으로는 이전 이벤트지만 hook 진입 시점에 함께 기록)
# - done    : "shutdown_response 발송 완료 확증"
# 메인측 sweep은 .done을 최종 성공 신호로 사용
ack_write_received "$UUID" "$MY_NAME" "$REQUEST_ID" 2>/dev/null || true
ack_write_done     "$UUID" "$MY_NAME" "$REQUEST_ID" "$APPROVE" 2>/dev/null || true

exit 0
