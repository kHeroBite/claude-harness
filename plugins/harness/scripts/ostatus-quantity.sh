#!/usr/bin/env bash
# ostatus-quantity.sh — 팀에이전트·pane 수량 리포팅 스크립트
#
# 사용법: bash ${HARNESS_HOME:-$HOME/.harness}/current/scripts/ostatus-quantity.sh "$UUID"
#
# 기능:
#   - agents/ 등록 수 집계
#   - teams/ config.json 멤버 수 (team-lead 제외) 집계
#   - 현재 세션 pane 수 (메인 제외) 집계
#   - 수량 불일치 감지 + 즉시 조치 권고 출력
#
# 인자:
#   $1 = UUID (활성 파이프라인 UUID)
#
# 출력:
#   === 수량 리포팅 === 형식으로 stdout 출력

set -euo pipefail

UUID="${1:-}"
if [ -z "$UUID" ]; then
  echo "사용법: $0 <UUID>" >&2
  exit 1
fi

MY_PANE=$(tmux display-message -p '#{pane_id}' 2>/dev/null || echo "")
MY_SESSION=$(tmux display-message -p '#{session_name}' 2>/dev/null || echo "")

# 1. agents/ 등록 수
AGENT_COUNT=$(ls "$HOME/.claude/session-env/${UUID}/agents/" 2>/dev/null | wc -l)

# 2. teams/ config.json 멤버 수 (team-lead 제외)
TEAM_NAME=$(cat "$HOME/.claude/session-env/${UUID}/team_name" 2>/dev/null || echo "")
TEAM_MEMBER_COUNT=0
if [ -n "$TEAM_NAME" ] && [ -f "$HOME/.claude/teams/${TEAM_NAME}/config.json" ]; then
  TEAM_MEMBER_COUNT=$(python3 -c "
import json
d = json.load(open('$HOME/.claude/teams/${TEAM_NAME}/config.json'))
members = [m for m in d.get('members', []) if m.get('name') != 'team-lead']
print(len(members))
" 2>/dev/null || echo 0)
fi

# 3. 현재 세션 pane 수 (메인 제외)
PANE_COUNT=$(tmux list-panes -t "$MY_SESSION" -F '#{pane_id}' 2>/dev/null | grep -v "^${MY_PANE}$" | wc -l)

echo "=== 수량 리포팅 ==="
echo "  팀 멤버 수 (team-lead 제외): ${TEAM_MEMBER_COUNT}개"
echo "  agents/ 등록 수:             ${AGENT_COUNT}개"
echo "  현재 세션 pane 수(메인 제외): ${PANE_COUNT}개"

# 4. 불일치 감지 + 즉시 조치 결정
if [ "$AGENT_COUNT" -eq "$PANE_COUNT" ] && [ "$AGENT_COUNT" -gt 0 ]; then
  echo "  → ✅ agents/pane 수량 일치 (tmux 방식)"
elif [ "$TEAM_MEMBER_COUNT" -gt 0 ] && [ "$PANE_COUNT" -eq 0 ]; then
  echo "  → ✅ Agent tool 방식 ${TEAM_MEMBER_COUNT}개 실행 중 (pane 없음 — 정상)"
elif [ "$AGENT_COUNT" -gt "$PANE_COUNT" ]; then
  DIFF=$((AGENT_COUNT - PANE_COUNT))
  echo "  → ⚠️ agents ${DIFF}개 초과 — 사망 에이전트 존재 (CASE-4)"
  echo "     조치: evidence 확인 → 완료면 다음 단계 진행, 미완료면 재spawn"
elif [ "$PANE_COUNT" -gt "$AGENT_COUNT" ]; then
  DIFF=$((PANE_COUNT - AGENT_COUNT))
  echo "  → ⚠️ pane ${DIFF}개 초과 — 미등록 고아 pane (CASE-3)"
  echo "     조치: B방향 불일치 목록 확인 후 즉시 kill escalation"
elif [ "$AGENT_COUNT" -eq 0 ] && [ "$TEAM_MEMBER_COUNT" -eq 0 ] && [ "$PANE_COUNT" -gt 0 ]; then
  echo "  → ⚠️ 완전 고아 pane ${PANE_COUNT}개 — 즉시 kill 대상"
fi

echo "=== [ostatus-quantity 완료] ==="
