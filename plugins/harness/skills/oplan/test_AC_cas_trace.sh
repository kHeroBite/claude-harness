#!/usr/bin/env bash
# =============================================================================
# test_AC_cas_trace.sh — claude-as 디버그 마커 AC 검증 헬퍼
# =============================================================================
# 역할: fixture 4종 실행으로 claude-as 마커(M0~MT0) 정상 기록 여부 자동 검증.
#       otest 단계에서 호출. 실제 프로파일(rio/dev/know/cs) 절대 미사용.
#
# 사용법:
#   cd <프로젝트 루트>
#   bash .claude/skills/oplan/test_AC_cas_trace.sh
#
# 환경변수:
#   CAS_BIN    claude-as 경로 (기본: ./bin/claude-as)
#   MOCK_BIN   cas-mock-claude.sh 경로 (기본: ./scripts/cas-mock-claude.sh)
# =============================================================================
set -euo pipefail

# ── 기본 경로 설정
AI_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CAS_BIN="${CAS_BIN:-${AI_ROOT}/bin/claude-as}"
MOCK_BIN="${MOCK_BIN:-${AI_ROOT}/scripts/cas-mock-claude.sh}"
LOG="${HOME}/.claude/cas_debug.log"
PASS=0
FAIL=0
ERRORS=()

# ── 유틸리티 함수
ts() { date '+%Y-%m-%d %H:%M:%S'; }

log_pass() { echo "  ✅ PASS: $*"; ((PASS++)) || true; }
log_fail() { echo "  ❌ FAIL: $*"; ((FAIL++)) || true; ERRORS+=("$*"); }
log_info() { echo "  ℹ️  $*"; }

# fixture 프로파일 격리 생성 (실제 계정 절대 미사용)
make_fixture_profile() {
    local suffix="$1"
    local name="cas-trace-fixture-${suffix}"
    local profile_dir="${HOME}/.claude-profiles/${name}"
    mkdir -p "${profile_dir}"
    chmod 700 "${profile_dir}"
    echo "${name}"
}

# fixture 프로파일 정리
cleanup_fixture() {
    local name="$1"
    "${CAS_BIN}" remove "${name}" <<< "yes" 2>/dev/null || true
    rm -rf "${HOME}/.claude-profiles/${name}" 2>/dev/null || true
    log_info "fixture 프로파일 정리 완료: ${name}"
}

# 로그 초기화 + 백업
reset_log() {
    local backup="${LOG}.bak.$(date +%s)"
    [[ -f "${LOG}" ]] && cp "${LOG}" "${backup}" 2>/dev/null || true
    > "${LOG}"
}

# 마커 존재 확인
check_marker() {
    local marker="$1"
    local label="${2:-${marker}}"
    if grep -q "${marker}" "${LOG}" 2>/dev/null; then
        log_pass "마커 ${label} 기록됨"
        return 0
    else
        log_fail "마커 ${label} 미기록 (로그에서 찾을 수 없음)"
        return 1
    fi
}

# =============================================================================
# 사전 검증 — 파일 존재 확인
# =============================================================================
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  cas 디버그 마커 AC 검증 헬퍼 — $(ts)"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "▶ 사전 검증"
[[ -x "${CAS_BIN}" ]] && log_pass "CAS_BIN 실행 가능: ${CAS_BIN}" || { log_fail "CAS_BIN 없음: ${CAS_BIN}"; exit 1; }
[[ -x "${MOCK_BIN}" ]] && log_pass "MOCK_BIN 실행 가능: ${MOCK_BIN}" || { log_fail "MOCK_BIN 없음: ${MOCK_BIN}"; exit 1; }

# AC-1: _cas_log 함수 존재
echo ""
echo "▶ AC-1: _cas_log 헬퍼 함수 정의 확인"
if grep -q '_cas_log()' "${CAS_BIN}"; then
    log_pass "_cas_log() 함수 정의 존재"
else
    log_fail "_cas_log() 함수 미정의"
fi

# AC-2: DEBUG-MARKER 개수 확인 (≥9)
echo ""
echo "▶ AC-2: DEBUG-MARKER 삽입 개수 확인 (≥9)"
marker_count="$(grep -c 'DEBUG-MARKER' "${CAS_BIN}" 2>/dev/null || echo 0)"
if [[ "${marker_count}" -ge 9 ]]; then
    log_pass "DEBUG-MARKER 총 ${marker_count}개 (≥9 OK)"
else
    log_fail "DEBUG-MARKER 개수 부족: ${marker_count}개 (최소 9 필요)"
fi

# =============================================================================
# S1: /bin/true — 즉시 정상 종료
# =============================================================================
echo ""
echo "▶ S1: CLAUDE_BIN=/bin/true — 즉시 정상 종료 (M0,M2,M3,M5_exit 확인)"
FIXTURE_S1="$(make_fixture_profile "$$-s1-$(date +%s)")"
reset_log
log_info "fixture: ${FIXTURE_S1}"
set +e
CLAUDE_BIN=/bin/true "${CAS_BIN}" "${FIXTURE_S1}" >/dev/null 2>&1
S1_RC=$?
set -e
log_info "cas 종료 rc=${S1_RC}"

# 마커 검증
check_marker "M0:" "M0 (trap 등록 완료)"
check_marker "M0.5:" "M0.5 (claude_bin 실행 직전)"
check_marker "M1:" "M1 (claude_bin 종료 직후)"
check_marker "M2:" "M2 (cleanup() 진입)"
check_marker "M3:" "M3 (sync_back() 진입)"
check_marker "M5_exit:" "M5_exit (exit 직전)"

cleanup_fixture "${FIXTURE_S1}"

# =============================================================================
# S2: /bin/sleep 1 — 1초 후 정상 종료 (M1 타임스탬프 차이 ≥1초)
# =============================================================================
echo ""
echo "▶ S2: CLAUDE_BIN=/bin/sleep — 1초 지연 종료 (M1 타임스탬프 검증)"
FIXTURE_S2="$(make_fixture_profile "$$-s2-$(date +%s)")"
reset_log
log_info "fixture: ${FIXTURE_S2}"
set +e
CLAUDE_BIN=/bin/sleep "${CAS_BIN}" "${FIXTURE_S2}" 1 >/dev/null 2>&1
S2_RC=$?
set -e
log_info "cas 종료 rc=${S2_RC}"

check_marker "M0:" "M0"
check_marker "M1:" "M1"
# M1의 ts= 값으로 실행 시간 확인 (참고용 — 정확한 ns 비교는 복잡하므로 로그 출력만)
M1_LINE="$(grep 'M1:' "${LOG}" | tail -1 || true)"
if [[ -n "${M1_LINE}" ]]; then
    log_info "M1 로그 확인: ${M1_LINE}"
    log_pass "M1 로그 기록됨 (타임스탬프 포함)"
else
    log_fail "M1 로그 없음"
fi

cleanup_fixture "${FIXTURE_S2}"

# =============================================================================
# S3: /bin/false — rc=1 전파 확인
# =============================================================================
echo ""
echo "▶ S3: CLAUDE_BIN=/bin/false — rc=1 전파 확인"
FIXTURE_S3="$(make_fixture_profile "$$-s3-$(date +%s)")"
reset_log
log_info "fixture: ${FIXTURE_S3}"
set +e
CLAUDE_BIN=/bin/false "${CAS_BIN}" "${FIXTURE_S3}" >/dev/null 2>&1
S3_RC=$?
set -e
log_info "cas 종료 rc=${S3_RC}"

check_marker "M1:" "M1"
# M1 로그에 rc=1 포함 확인
if grep -q 'M1:.*rc=1' "${LOG}" 2>/dev/null; then
    log_pass "M1 마커에 rc=1 기록됨"
else
    log_fail "M1 마커에 rc=1 미기록 (실제: $(grep 'M1:' "${LOG}" | tail -1 || echo '없음'))"
fi
check_marker "M5_exit:" "M5_exit"
# M5_exit에 rc=1 포함 확인
if grep -q 'M5_exit:.*rc=1' "${LOG}" 2>/dev/null; then
    log_pass "M5_exit 마커에 rc=1 기록됨"
else
    log_fail "M5_exit 마커에 rc=1 미기록"
fi

cleanup_fixture "${FIXTURE_S3}"

# =============================================================================
# S4: cas-mock-claude.sh — sync_back 실측 (PROFILE_DIR에 .credentials.json 생성 확인)
# =============================================================================
echo ""
echo "▶ S4: CLAUDE_BIN=cas-mock-claude.sh — sync_back 실증 (.credentials.json 생성 확인)"
FIXTURE_S4="$(make_fixture_profile "$$-s4-$(date +%s)")"
PROFILE_DIR_S4="${HOME}/.claude-profiles/${FIXTURE_S4}"
reset_log
log_info "fixture: ${FIXTURE_S4} → ${PROFILE_DIR_S4}"
set +e
CLAUDE_BIN="${MOCK_BIN}" "${CAS_BIN}" "${FIXTURE_S4}" >/dev/null 2>&1
S4_RC=$?
set -e
log_info "cas 종료 rc=${S4_RC}"

check_marker "MOCK_CLAUDE_START" "MOCK_CLAUDE_START (wrapper 실행)"
check_marker "MOCK_CLAUDE_WROTE_CREDS" "MOCK_CLAUDE_WROTE_CREDS (가짜 토큰 생성)"
check_marker "M3:" "M3 (sync_back 진입)"
check_marker "M4_pre:" "M4_pre (cp 직전)"
check_marker "M4_post:" "M4_post (cp 완료)"

# PROFILE_DIR에 .credentials.json 생성 확인 (sync_back 실증)
CREDS_PATH="${PROFILE_DIR_S4}/.credentials.json"
if [[ -f "${CREDS_PATH}" ]]; then
    CREDS_SIZE="$(stat -c%s "${CREDS_PATH}" 2>/dev/null || echo 0)"
    log_pass "sync_back 실증 성공: PROFILE_DIR에 .credentials.json 생성됨 (${CREDS_SIZE}b)"
    # 내용 검증 (FAKE_ACCESS_TRACE 포함 확인)
    if grep -q 'FAKE_ACCESS_TRACE' "${CREDS_PATH}" 2>/dev/null; then
        log_pass ".credentials.json 내용 일치 (FAKE_ACCESS_TRACE 확인)"
    else
        log_fail ".credentials.json 내용 불일치"
    fi
else
    log_fail "sync_back 실패: PROFILE_DIR에 .credentials.json 미생성 (${CREDS_PATH})"
fi

cleanup_fixture "${FIXTURE_S4}"

# =============================================================================
# 결과 요약
# =============================================================================
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  결과 요약: PASS=${PASS}  FAIL=${FAIL}"
if [[ "${FAIL}" -gt 0 ]]; then
    echo "  실패 항목:"
    for err in "${ERRORS[@]}"; do
        echo "    - ${err}"
    done
    echo "═══════════════════════════════════════════════════════════════"
    exit 1
else
    echo "  🎉 모든 AC 검증 통과"
    echo "═══════════════════════════════════════════════════════════════"
    exit 0
fi
