#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# checkpoint_verify.sh — 파이프라인 단계 전환 시 팀에이전트/pane 건강 검증
# 사용법: checkpoint_verify.sh <팀명> <예상멤버수> <현재단계명> [UUID]
# 출력: PASS/FAIL + 상세 (고아 pane 수, 누락 멤버 등)
# 호출 시점: oplan→odev, odev→otest, otest→odone, odone→메인보고 전환점

# M-01: 에러 핸들링 강화
set -euo pipefail
source "${HARNESS_HOOK_DIR}/lib/session_id.sh" 2>/dev/null || true
trap 'echo "❌ checkpoint_verify 내부 에러 (line $LINENO)"; exit 1' ERR

TEAM_NAME="${1:?팀명 필수}"
EXPECTED_MEMBERS="${2:?예상멤버수 필수}"
STAGE_NAME="${3:?단계명 필수}"
SID="${4:?UUID 필수 — 세션 격리 v2에서 current_sid fallback 폐기}"
SESSION_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${SID}"
AGENTS_DIR="${SESSION_DIR}/agents"

PASS=true
DETAILS=""

# 1. agents/ 디렉토리 존재 확인
if [ ! -d "$AGENTS_DIR" ]; then
    DETAILS="${DETAILS}[INFO] agents 디렉토리 없음: ${AGENTS_DIR} — 첫 단계일 수 있음\n"
else
    # 2. agents/ 기반 현재 단계 멤버 수 확인 (stage prefix 필터링)
    # agents/는 누적이므로 현재 단계 prefix에 해당하는 에이전트만 카운트
    CURRENT_STAGE_PREFIX=""
    case "$STAGE_NAME" in
        PLAN완료*) CURRENT_STAGE_PREFIX="oplan" ;;
        DEV완료*)  CURRENT_STAGE_PREFIX="odev" ;;
        TEST완료*) CURRENT_STAGE_PREFIX="otest" ;;
        DONE완료*) CURRENT_STAGE_PREFIX="odone" ;;
    esac
    if [ -n "$CURRENT_STAGE_PREFIX" ]; then
        # spawned_at vs state 파일 mtime 비교 — 현재 라운드 에이전트만 카운트
        # 역라우팅 시 이전 라운드 동일 prefix 에이전트(otest-1~5 등) 누적 방지
        STAGE_ENTERED=$(stat -c %Y "${SESSION_DIR}/state" 2>/dev/null || echo 0)
        ACTUAL_MEMBERS=0
        for _f in "${AGENTS_DIR}/${CURRENT_STAGE_PREFIX}"*; do
            [ -f "$_f" ] || continue
            _SPAWNED=$(grep "^spawned_at=" "$_f" 2>/dev/null | cut -d= -f2 || true)  # M-01
            if [ -n "$_SPAWNED" ] && [ "$_SPAWNED" -ge "$STAGE_ENTERED" ]; then
                ACTUAL_MEMBERS=$((ACTUAL_MEMBERS + 1))
            fi
        done
        if [ "$ACTUAL_MEMBERS" -ne "$EXPECTED_MEMBERS" ]; then
            DETAILS="${DETAILS}[WARN] ${CURRENT_STAGE_PREFIX} 멤버 수 불일치: 예상=${EXPECTED_MEMBERS}, 실제=${ACTUAL_MEMBERS}\n"
        else
            DETAILS="${DETAILS}[OK] ${CURRENT_STAGE_PREFIX} 멤버 수 일치: ${ACTUAL_MEMBERS}\n"
        fi
    else
        ACTUAL_MEMBERS=$(ls "$AGENTS_DIR" 2>/dev/null | grep -v '^team-lead$' | wc -l || true)  # M-01
        DETAILS="${DETAILS}[INFO] 전체 agents 수 (stage 매칭 없음): ${ACTUAL_MEMBERS}\n"
    fi

    # 3. pane 생존 확인 (shutdown 완료 여부)
    ACTIVE_COUNT=0
    for AGENT_FILE in "$AGENTS_DIR"/*; do
        [ -f "$AGENT_FILE" ] || continue
        AGENT_NAME=$(basename "$AGENT_FILE")
        [ "$AGENT_NAME" = "team-lead" ] && continue
        # shutdown_sent=true가 없는 에이전트 = 아직 활성
        if ! grep -q "shutdown_sent=true" "$AGENT_FILE" 2>/dev/null; then
            MPANE=$(grep "pane_id=" "$AGENT_FILE" 2>/dev/null | cut -d= -f2 || true)  # M-01
            if [[ -n "$MPANE" ]] && tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qF "$MPANE"; then  # H-01
                ACTIVE_COUNT=$((ACTIVE_COUNT + 1))
            fi
        fi
    done

    if [ "$ACTIVE_COUNT" -gt 1 ]; then
        DETAILS="${DETAILS}[WARN] 활성 pane ${ACTIVE_COUNT}개 (shutdown 미완료 가능)\n"
    else
        DETAILS="${DETAILS}[OK] 활성 pane: 정상 (대부분 shutdown 완료)\n"
    fi
fi

# 4. 고아 pane 감지 (agents/ 기반)
ORPHAN_COUNT=0
if [ -d "$AGENTS_DIR" ]; then
    GHOST_COUNT=0
    for AGENT_FILE in "$AGENTS_DIR"/*; do
        [ -f "$AGENT_FILE" ] || continue
        PANE_ID=$(grep "^pane_id=" "$AGENT_FILE" | cut -d= -f2 || true)  # M-01
        [ -z "$PANE_ID" ] && continue
        if grep -q "shutdown_sent=true" "$AGENT_FILE" 2>/dev/null; then
            # shutdown 완료 → pane 소멸 확인
            if tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qF "$PANE_ID"; then  # H-01
                GHOST_COUNT=$((GHOST_COUNT + 1))
                DETAILS="${DETAILS}[WARN] shutdown 완료됐으나 pane 잔류: ${PANE_ID} ($(basename $AGENT_FILE))\n"
            fi
        fi
    done
    ORPHAN_COUNT=0  # shutdown 후 타이밍 잔류는 ofinish_cleanup 처리 — FAIL 판정 제외
    if [ $GHOST_COUNT -eq 0 ]; then
        DETAILS="${DETAILS}[OK] agents/ 기반 고아 pane 없음\n"
    else
        DETAILS="${DETAILS}[INFO] shutdown 후 pane ${GHOST_COUNT}개 잔류 — ofinish_cleanup이 정리 예정\n"
    fi
else
    DETAILS="${DETAILS}[INFO] agents 디렉토리 없음 — 고아 감지 스킵\n"
fi

# 5. pipeline state 정합성 확인
PIPELINE_STATE=$(state_read "${SESSION_DIR}/state")  # M-01 + M-13: flock 보호
if [ -z "$PIPELINE_STATE" ]; then
    DETAILS="${DETAILS}[WARN] state 파일 없음: ${SESSION_DIR}/state\n"
else
    DETAILS="${DETAILS}[OK] state: ${PIPELINE_STATE}\n"
fi

# 6. orphan 파일 확인
ORPHAN_FILE="${SESSION_DIR}/panes/orphans"
if [ -f "$ORPHAN_FILE" ]; then
    ORPHAN_FILE_COUNT=$(wc -l < "$ORPHAN_FILE")
    DETAILS="${DETAILS}[WARN] 이전 단계 orphan 기록 ${ORPHAN_FILE_COUNT}건: ${ORPHAN_FILE}\n"
    PASS=false
else
    DETAILS="${DETAILS}[OK] orphan 기록 없음\n"
fi

# 7. shutdown_sent 검증 (에이전트 등록 파일 기반)
if [ -d "$AGENTS_DIR" ]; then
    UNSENT_AGENTS=""
    UNSENT_COUNT=0

    SHUTDOWN_EXPECTED_PREFIXES=""
    case "$STAGE_NAME" in
        PLAN완료*) SHUTDOWN_EXPECTED_PREFIXES="oplan" ;;
        DEV완료*)  SHUTDOWN_EXPECTED_PREFIXES="oplan odev" ;;
        TEST완료*) SHUTDOWN_EXPECTED_PREFIXES="oplan odev otest" ;;
        DONE완료*) SHUTDOWN_EXPECTED_PREFIXES="oplan odev otest odone" ;;
    esac

    if [ -n "$SHUTDOWN_EXPECTED_PREFIXES" ]; then
        for AGENT_FILE in "$AGENTS_DIR"/*; do
            [ -f "$AGENT_FILE" ] || continue
            AGENT_NAME=$(basename "$AGENT_FILE")

            SHOULD_CHECK=false
            for PREFIX in $SHUTDOWN_EXPECTED_PREFIXES; do
                case "$AGENT_NAME" in
                    ${PREFIX}*) SHOULD_CHECK=true; break ;;
                esac
            done
            [ "$SHOULD_CHECK" = false ] && continue

            if ! grep -q "shutdown_sent=true" "$AGENT_FILE" 2>/dev/null; then
                UNSENT_AGENTS="${UNSENT_AGENTS}  - ${AGENT_NAME}\n"
                UNSENT_COUNT=$((UNSENT_COUNT + 1))
            fi
        done

        if [ $UNSENT_COUNT -gt 0 ]; then
            DETAILS="${DETAILS}[WARN] shutdown 미발송 에이전트 ${UNSENT_COUNT}개:\n${UNSENT_AGENTS}"
        else
            DETAILS="${DETAILS}[OK] 이전 단계 에이전트 모두 shutdown_sent 확인\n"
        fi
    else
        DETAILS="${DETAILS}[INFO] 첫 단계 또는 매칭 없음 — shutdown 검증 대상 없음\n"
    fi
else
    DETAILS="${DETAILS}[INFO] agents 디렉토리 없음 — shutdown 검증 스킵\n"
fi

# 결과 출력
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔍 체크포인트 검증: ${STAGE_NAME}"
echo "   팀: ${TEAM_NAME}"
echo "   예상 멤버: ${EXPECTED_MEMBERS}"
echo "   UUID: ${SID}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "$DETAILS"

if [ "$PASS" = true ]; then
    echo "✅ 결과: PASS"
    exit 0
else
    echo "⚠️ 결과: FAIL (상세 확인 필요)"
    exit 1
fi
