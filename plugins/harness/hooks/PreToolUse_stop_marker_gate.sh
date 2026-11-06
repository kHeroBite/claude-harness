#!/bin/bash
# 리드가 세션 디렉토리에 남긴 중지/범위 마커를 팀원의 모든 도구 호출 직전에 확인·강제하는 PreToolUse 게이트 (L-1195)
#
# 등록: PreToolUse matcher "*" (timeout 10)
# 코어: lib/stop_marker_gate.py (마커 규약·판정 순서는 그 파일 머리말이 정본)
# 마커(리드가 file_write 로 쓴다):
#   ${CLAUDE_CONFIG_DIR}/session-env/<LEAD>/scope_markers/<팀원이름>.json  또는  _all.json
#   {"type":"stop|scope","message":"사용자 지시 원문","by":"team-lead","created_at":"ISO8601"}  — 해제는 파일 삭제
# 대상: tmux 팀원 프로세스만 (lib/chain_agent.sh). 메인·in-process 팀원은 통과 — 한계로 명시.
# 비용: 메인/마커 부재 시 python 미기동 (/proc 체인 6단계 읽기만).
# 스위치:
#   전역 OFF : touch ${HARNESS_HOME:-$HOME/.harness}/current/hooks/DISABLE_STOP_MARKER_GATE
# 내부 오류는 전부 exit 0 (fail-open).

trap 'exit 0' ERR
HOOKS_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
[[ -f "$HOOKS_DIR/DISABLE_STOP_MARKER_GATE" || -f "${HARNESS_HOME:-$HOME/.harness}/current/hooks/DISABLE_STOP_MARKER_GATE" ]] && exit 0

# shellcheck disable=SC1091
source "$HOOKS_DIR/lib/chain_agent.sh" 2>/dev/null || exit 0
chain_agent_resolve || exit 0

INPUT=$(timeout 5 cat 2>/dev/null) || exit 0
MDIR="$CA_SDIR/scope_markers"
# 마커가 없고 마커 경로 언급도 없으면 즉시 통과
if [[ ! -f "$MDIR/$CA_NAME.json" && ! -f "$MDIR/_all.json" && ! -f "$MDIR/_user.json" ]]; then
  [[ "$INPUT" == *scope_markers* || "$INPUT" == *DISABLE_S* || "$INPUT" == *snapshot_gate_mode* ]] || exit 0
fi

LIB="$HOOKS_DIR/lib/stop_marker_gate.py"
[[ -f "$LIB" ]] || exit 0
printf '%s' "$INPUT" | SM_SESSION_DIR="$CA_SDIR" SM_AGENT="$CA_NAME" \
  timeout 8 python3 -I "$LIB" 2>/dev/null
exit 0
