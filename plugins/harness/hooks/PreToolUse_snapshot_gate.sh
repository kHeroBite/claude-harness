#!/bin/bash
# 팀원이 실업무 DB 행에 UPDATE/DELETE 를 실행하기 전에 이번 세션 스냅샷 파일 존재를 요구하는 PreToolUse 게이트 (L-1200)
#
# 등록: PreToolUse matcher "Bash|mcp__oio__bash_exec|mcp__mysql__execute|mcp__mysql__query" (timeout 10)
# 코어: lib/snapshot_gate.py (감지 패턴·스냅샷 규약·표식 예외는 그 파일 머리말이 정본)
# 대상: tmux 팀원 프로세스만 (부모 체인 --agent-id NAME@TEAM + --parent-session-id LEAD, lib/chain_agent.sh).
#       메인·식별 불가(in-process 팀원)는 통과 — 한계로 명시.
# 스냅샷 규약: session-env/<LEAD>/evidence/snapshot_*.json {"table","where","rows":[...],"taken_at"}
# 감지 범위: SQL 텍스트(mysql MCP) / bash 명령 본문(-e "...", heredoc, python -c) / 명령이 실행하는 *.py *.sql 1단계 내용
#            / 명령이 실행하는 *.sh 의 명령 위치 mysql·mariadb 호출 줄(+ 그 줄이 여는 heredoc 본문)만 감지.
# 감지 한계: 앱 경유 쓰기(Mars PC·모바일 UI 저장 → GW → DB, L-1200 의 실제 경로), 동적 조립 SQL(테이블명 변수),
#            .sh 안 따옴표·변수 간접 mysql 호출, 2단계 이상 간접 실행, base64 등 난독화 — 못 잡는다.
# 스위치:
#   전역 OFF : touch ${HARNESS_HOME:-$HOME/.harness}/current/hooks/DISABLE_SNAPSHOT_GATE
#   세션 모드: session-env/<LEAD>/snapshot_gate_mode = off | warn | block (부재 시 block)
# 내부 오류는 전부 exit 0 (fail-open).

trap 'exit 0' ERR
HOOKS_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
[[ -f "$HOOKS_DIR/DISABLE_SNAPSHOT_GATE" || -f "${HARNESS_HOME:-$HOME/.harness}/current/hooks/DISABLE_SNAPSHOT_GATE" ]] && exit 0

INPUT=$(timeout 5 cat 2>/dev/null) || exit 0
# 값싼 사전 필터: UPDATE/DELETE 단어도, 스크립트 파일 언급도 없으면 즉시 통과
printf '%s' "$INPUT" | grep -qiE 'update|delete|\.py|\.sql|\.sh' || exit 0

# shellcheck disable=SC1091
source "$HOOKS_DIR/lib/chain_agent.sh" 2>/dev/null || exit 0
chain_agent_resolve || exit 0

MODE=block
if [[ -f "$CA_SDIR/snapshot_gate_mode" ]]; then
  MODE=$(tr -d '[:space:]' < "$CA_SDIR/snapshot_gate_mode" 2>/dev/null)
fi
case "$MODE" in
  off) exit 0 ;;
  warn|block) ;;
  *) MODE=block ;;
esac

LIB="$HOOKS_DIR/lib/snapshot_gate.py"
[[ -f "$LIB" ]] || exit 0
printf '%s' "$INPUT" | SG_SESSION_DIR="$CA_SDIR" SG_AGENT="$CA_NAME" SG_MODE="$MODE" \
  timeout 8 python3 -I "$LIB" 2>/dev/null
exit 0
