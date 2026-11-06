#!/usr/bin/env bash
# ostatus-diagnose.sh — 에이전트·pane 양방향 교차 진단 스크립트
#
# 사용법: bash ${HARNESS_HOME:-$HOME/.harness}/current/scripts/ostatus-diagnose.sh "$UUID"
#
# 포함 진단:
#   진단-2  : agents/ ↔ pane 목록 양방향 교차 검증
#   진단-2.5: bash 고아 pane 전수 스캔 (B방향 불일치 심화 확인)
#   진단-2.6: 미등록 2.1.x pane --agent-id 스캔 (CASE-8 감지)
#
# 인자:
#   $1 = UUID (활성 파이프라인 UUID)
#
# 출력:
#   각 진단 결과를 stdout으로 출력 (진단 보고서 형식)

set -euo pipefail

UUID="${1:-}"
if [ -z "$UUID" ]; then
  echo "사용법: $0 <UUID>" >&2
  exit 1
fi

MY_PANE=$(tmux display-message -p '#{pane_id}' 2>/dev/null || echo "")
MY_SESSION=$(tmux display-message -p '#{session_name}' 2>/dev/null || echo "")

# ============================================================
# 진단-2: 에이전트 목록 ↔ pane 목록 양방향 교차 검증
# ============================================================
echo "=== [진단-2] 에이전트 ↔ pane 양방향 교차 검증 ==="
echo ""

# ── 방향 A: agents/ 파일 → pane 실존 확인 ──────────────────────────
echo "─ A방향: agents/ 등록 → pane 실존 확인"
declare -A AGENT_PANES  # pane_id → 에이전트명 매핑 (B방향에서 재활용)
MISMATCH_A=0

for f in "$HOME/.claude/session-env/${UUID}/agents/"*; do
  [ -f "$f" ] || continue
  NAME=$(basename "$f")
  PANE_ID=$(grep "^pane_id=" "$f" 2>/dev/null | cut -d= -f2)
  SESSION_FIELD=$(grep "^session_id=" "$f" 2>/dev/null | cut -d= -f2)

  if [ -z "$PANE_ID" ]; then
    echo "  ⚠️ [A-MISMATCH] $NAME → pane_id 없음 (기록 누락) → 원인분류: A(pane_id 기록 오류)"
    MISMATCH_A=$((MISMATCH_A+1))
    continue
  fi

  AGENT_PANES["$PANE_ID"]="$NAME"

  # pane 실존 여부
  CMD=$(tmux display-message -t "$PANE_ID" -p '#{pane_current_command}' 2>/dev/null || echo "")
  if [ -z "$CMD" ]; then
    echo "  ⚠️ [A-MISMATCH] $NAME → pane=$PANE_ID 소멸 → 원인분류: C(pane 조기 소멸)"
    MISMATCH_A=$((MISMATCH_A+1))
    continue
  fi

  # pane 세션 소속 확인 (타세션 에이전트 감지)
  PANE_SESSION=$(tmux display-message -t "$PANE_ID" -p '#{session_name}' 2>/dev/null || echo "")
  if [ "$PANE_SESSION" != "$MY_SESSION" ]; then
    echo "  ⚠️ [A-MISMATCH] $NAME → pane=$PANE_ID CMD=$CMD 타세션($PANE_SESSION) 소속 → 원인분류: B(타세션 에이전트 등록) → L-213 보호"
    MISMATCH_A=$((MISMATCH_A+1))
  else
    echo "  ✅ [A-OK] $NAME → pane=$PANE_ID CMD=$CMD 현재세션 정상"
  fi
done

if [ $MISMATCH_A -eq 0 ]; then
  echo "  ✅ A방향 불일치 없음"
fi

echo ""

# ── 방향 B: 현재 세션 pane → agents/ 등록 확인 ──────────────────────
echo "─ B방향: 현재 세션 pane → agents/ 등록 확인"
MISMATCH_B=0

tmux list-panes -t "$MY_SESSION" -F '#{pane_id} #{pane_current_command} #{pane_pid}' 2>/dev/null \
| while read SPANE SCMD SPID; do
  [ "$SPANE" = "$MY_PANE" ] && continue  # 메인 pane 제외

  # agents/ 등록 여부 (전체 UUID에서 검색)
  REGISTERED_AGENT=""
  for af in "$HOME/.claude/session-env"/*/agents/*; do
    [ -f "$af" ] || continue
    AID=$(grep "^pane_id=" "$af" 2>/dev/null | cut -d= -f2)
    if [ "$AID" = "$SPANE" ]; then
      REGISTERED_AGENT=$(basename "$af")
      break
    fi
  done

  if [ -z "$REGISTERED_AGENT" ]; then
    ETIME=$(ps -o etime= -p "$SPID" 2>/dev/null | tr -d ' ' || echo "?")
    if [ "$SCMD" = "bash" ]; then
      echo "  ⚠️ [B-MISMATCH] pane=$SPANE CMD=bash PID=$SPID 실행시간=$ETIME → agents/ 미등록 → 원인분류: C(bash 고아 pane)"
    else
      # L-330: --agent-id 플래그로 팀에이전트 잔류 프로세스 감지
      CHILD_PID=$(pgrep -P "$SPID" 2>/dev/null | head -1 || echo "")
      AGENT_ID_FLAG=$(ps -ww -p "${CHILD_PID:-$SPID}" -o args= 2>/dev/null | grep -o '\-\-agent-id [^ ]*' | cut -d' ' -f2 || echo "")
      if [ -n "$AGENT_ID_FLAG" ]; then
        echo "  ⚠️ [B-MISMATCH] pane=$SPANE CMD=$SCMD PID=$SPID → --agent-id=$AGENT_ID_FLAG → 원인분류: H(TeamDelete 후 에이전트 프로세스 잔류) → kill 대상"
      else
        echo "  ⚠️ [B-MISMATCH] pane=$SPANE CMD=$SCMD PID=$SPID → agents/ 미등록 → 원인분류: E(고아 에이전트 pane)"
      fi
    fi
    MISMATCH_B=$((MISMATCH_B+1))
  else
    echo "  ✅ [B-OK] pane=$SPANE CMD=$SCMD → 에이전트=$REGISTERED_AGENT 등록 확인"
  fi
done

echo ""

# ── 교차 검증 요약 ──────────────────────────────────────────────────
echo "─ 교차 검증 요약"
AGENT_COUNT=$(ls "$HOME/.claude/session-env/${UUID}/agents/" 2>/dev/null | wc -l)
PANE_COUNT=$(tmux list-panes -t "$MY_SESSION" 2>/dev/null | wc -l)
PANE_COUNT=$((PANE_COUNT - 1))  # 메인 pane 제외
echo "  등록 에이전트: ${AGENT_COUNT}개 | 현재 세션 pane(메인 제외): ${PANE_COUNT}개"
if [ "$AGENT_COUNT" -eq "$PANE_COUNT" ] && [ $MISMATCH_A -eq 0 ]; then
  echo "  ✅ 수량 일치 + 불일치 없음 — 정상 상태"
else
  echo "  ⚠️ 불일치 감지: A방향 ${MISMATCH_A}건 (agents→pane) | B방향에서 추가 확인"
  echo "  → Step 9-2 원인분류표(A~J) 참조하여 근본 원인 판정"
fi
echo "=== [진단-2 완료] ==="

echo ""

# ============================================================
# 진단-2.5: bash 고아 pane 전수 스캔
# ============================================================
echo "=== 현재 세션($MY_SESSION) bash 고아 pane 스캔 ==="
ALL_SESSION_PANES=$(tmux list-panes -t "$MY_SESSION" -F '#{pane_id} #{pane_current_command} #{pane_pid}' 2>/dev/null || echo "")
BASH_ORPHAN_FOUND=0

echo "$ALL_SESSION_PANES" | while read SPANE SCMD SPID; do
  [ "$SPANE" = "$MY_PANE" ] && continue  # 메인 pane 제외
  [ "$SCMD" != "bash" ] && continue       # bash 상태만 대상
  # agents/ 파일 등록 여부 확인
  REGISTERED=false
  for af in "$HOME/.claude/session-env"/*/agents/*; do
    [ -f "$af" ] || continue
    AID=$(grep "^pane_id=" "$af" 2>/dev/null | cut -d= -f2)
    [ "$AID" = "$SPANE" ] && REGISTERED=true && break
  done
  if [ "$REGISTERED" = false ]; then
    ETIME=$(ps -o etime= -p "$SPID" 2>/dev/null | tr -d ' ' || echo "?")
    echo "⚠️ CASE-3 감지: $SPANE (bash, PID=$SPID, 실행시간=$ETIME) — 미등록 고아 bash pane"
    echo "   복구: kill $SPID 또는 /ofinish_cleanup 호출"
    BASH_ORPHAN_FOUND=$((BASH_ORPHAN_FOUND+1))
  fi
done

if [ $BASH_ORPHAN_FOUND -eq 0 ]; then
  echo "  ✅ bash 고아 pane 없음"
fi

echo ""

# ============================================================
# 진단-2.6: 미등록 2.1.x pane --agent-id 스캔 (CASE-8)
# ============================================================
echo "=== 현재 세션($MY_SESSION) 미등록 claude 프로세스 --agent-id 스캔 ==="
CLAUDE_ORPHAN_FOUND=0

tmux list-panes -t "$MY_SESSION" -F '#{pane_id} #{pane_current_command} #{pane_pid}' 2>/dev/null \
| while read SPANE SCMD SPID; do
  [ "$SPANE" = "$MY_PANE" ] && continue
  # bash 이외(2.1.x 등 claude 프로세스)만 대상
  [ "$SCMD" = "bash" ] && continue
  # agents/ 미등록 pane인지 확인
  REGISTERED=false
  for af in "$HOME/.claude/session-env"/*/agents/*; do
    [ -f "$af" ] || continue
    AID=$(grep "^pane_id=" "$af" 2>/dev/null | cut -d= -f2)
    [ "$AID" = "$SPANE" ] && REGISTERED=true && break
  done
  [ "$REGISTERED" = true ] && continue
  # --agent-id 플래그 확인 (자식 프로세스 포함)
  CHILD_PID=$(pgrep -P "$SPID" 2>/dev/null | head -1 || echo "")
  # ★열 폭 무관★ ps -ww — COLUMNS=80 이면 --agent-id 토큰이 잘린다 (위 103행 동일)
  AGENT_ID=$(ps -ww -p "${CHILD_PID:-$SPID}" -o args= 2>/dev/null | grep -o '\-\-agent-id [^ ]*' | cut -d' ' -f2 || echo "")
  if [ -n "$AGENT_ID" ]; then
    echo "⚠️ CASE-8 감지: $SPANE (CMD=$SCMD, PID=$SPID) → --agent-id=$AGENT_ID"
    echo "   판정: TeamDelete 후 에이전트 프로세스 잔류 → kill 대상"
    echo "   복구: kill ${CHILD_PID:-$SPID} (에이전트 프로세스) + kill $SPID (bash)"
    CLAUDE_ORPHAN_FOUND=$((CLAUDE_ORPHAN_FOUND+1))
  else
    echo "ℹ️  $SPANE (CMD=$SCMD, PID=$SPID) → --agent-id 없음 → 메인 Claude 또는 무관 프로세스 → L-213 보호"
  fi
done

if [ $CLAUDE_ORPHAN_FOUND -eq 0 ]; then
  echo "  ✅ 미등록 claude 잔류 없음 (또는 전부 메인 보호 대상)"
fi

echo "=== [ostatus-diagnose 완료] ==="
