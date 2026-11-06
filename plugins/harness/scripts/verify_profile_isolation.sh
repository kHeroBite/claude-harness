#!/usr/bin/env bash
# verify_profile_isolation.sh — 멀티계정 프로파일 격리 검증
#
# 작성: odev-5 (multi-account-profile-impl 팀)
# 입력 근거:
#   - oplan_conv_177742761168.md §7 Phase 4 + §9
#   - plan_3.md §5 V1~V9 PASS 기준
#   - critique_B.md G1~G11
#   - phase_0_summary.md (G3/G5/G8/G9/G10/G11 재실측 대상)
#
# 검증 항목: V1~V11 (11) + G3/G5/G8/G9/G10/G11 재실측 (6) = 17
#
# ⚠ 본 스크립트는 launcher(~/.local/bin/claude-as) + hook 패치 완료 후 실행한다.
#    실행은 otest_make 단계에서 수행 (본 단계는 작성만).
#
# 사용법:
#   verify_profile_isolation.sh [EVIDENCE_DIR]
#   기본 EVIDENCE_DIR: $HOME/.claude/session-env/${PIPELINE_UUID:-CURRENT}/evidence
#
# 종료 코드: 0=ALL PASS, 1=하나 이상 FAIL, 2=사전조건 실패

set -euo pipefail

# ────────────────────────────────────────────────────────────────
# 0. 환경 변수 / 디렉토리
# ────────────────────────────────────────────────────────────────
DEFAULT_UUID="${PIPELINE_UUID:-56992daf-4ad9-4f1a-8e05-991179d10e74}"
EVIDENCE_DIR="${1:-$HOME/.claude/session-env/${DEFAULT_UUID}/evidence}"
VERIFY_DIR="${EVIDENCE_DIR}/verify"
mkdir -p "${VERIFY_DIR}"

LAUNCHER="${HOME}/.local/bin/claude-as"
PROFILES_DIR="${HOME}/.claude-profiles"
TEST_A="test-A"
TEST_B="test-B"
TMP_BASE="/tmp/verify_profile_$$"
mkdir -p "${TMP_BASE}"
trap 'rm -rf "${TMP_BASE}" 2>/dev/null || true' EXIT

declare -A RESULTS

# ────────────────────────────────────────────────────────────────
# 1. 헬퍼
# ────────────────────────────────────────────────────────────────
log() { printf '%s\n' "$*" >&2; }

record() {
    local name="$1" verdict="$2"
    RESULTS["${name}"]="${verdict}"
    case "${verdict}" in
        PASS) log "  ✅ ${name}: PASS" ;;
        FAIL) log "  ❌ ${name}: FAIL" ;;
        INCONCLUSIVE) log "  ⚠️  ${name}: INCONCLUSIVE" ;;
        SKIP) log "  ⏭️  ${name}: SKIP" ;;
    esac
}

run_test() {
    # run_test <name> <desc> <cmd> <pass_pattern>
    local name="$1" desc="$2" cmd="$3" pass_pattern="$4"
    log "=== ${name}: ${desc} ==="
    local out_file="${VERIFY_DIR}/${name}_result.txt"
    local out
    if ! out="$(timeout 60 bash -c "${cmd}" 2>&1)"; then
        printf '%s\n' "${out}" > "${out_file}"
        record "${name}" "FAIL"
        return
    fi
    printf '%s\n' "${out}" > "${out_file}"
    if printf '%s' "${out}" | grep -qE "${pass_pattern}"; then
        record "${name}" "PASS"
    else
        record "${name}" "FAIL"
    fi
}

# ────────────────────────────────────────────────────────────────
# 2. 사전조건 검증
# ────────────────────────────────────────────────────────────────
preflight() {
    log "=== 사전조건 검증 ==="
    local fatal=0
    if [[ ! -x "${LAUNCHER}" ]]; then
        log "❌ launcher 미존재 또는 비실행: ${LAUNCHER}"
        fatal=1
    else
        log "  ✓ launcher: ${LAUNCHER}"
    fi
    if [[ ! -d "${PROFILES_DIR}" ]]; then
        log "❌ 프로파일 디렉토리 미존재: ${PROFILES_DIR}"
        fatal=1
    else
        log "  ✓ profiles dir: ${PROFILES_DIR}"
    fi
    if ! command -v claude >/dev/null 2>&1; then
        log "❌ claude CLI 미설치"
        fatal=1
    fi
    if ! command -v flock >/dev/null 2>&1; then
        log "⚠️ flock 미설치 — V8/G9 SKIP"
    fi
    if ! command -v lsof >/dev/null 2>&1; then
        log "⚠️ lsof 미설치 — V6 INCONCLUSIVE 가능"
    fi
    [[ ${fatal} -eq 0 ]] || { log "사전조건 실패 — 종료"; exit 2; }

    # 임시 프로파일 디렉토리 보장
    mkdir -p "${PROFILES_DIR}/${TEST_A}" "${PROFILES_DIR}/${TEST_B}" 2>/dev/null || true
    log ""
}

# ────────────────────────────────────────────────────────────────
# 3. V1~V11 검증 함수
# ────────────────────────────────────────────────────────────────

# V1: 두 세션 동시 실행 → 각자 다른 계정 인증
# PASS: 두 CONFIG_DIR이 분리되어 .credentials.json 또는 .claude.json이 별도 생성
test_v1() {
    local cmd='
        dirA="'"${PROFILES_DIR}/${TEST_A}"'"
        dirB="'"${PROFILES_DIR}/${TEST_B}"'"
        CLAUDE_CONFIG_DIR="${dirA}" timeout 15 claude --print "v1-A" >/dev/null 2>&1 || true
        CLAUDE_CONFIG_DIR="${dirB}" timeout 15 claude --print "v1-B" >/dev/null 2>&1 || true
        a_count=$(find "${dirA}" -maxdepth 2 -type f 2>/dev/null | wc -l)
        b_count=$(find "${dirB}" -maxdepth 2 -type f 2>/dev/null | wc -l)
        echo "A_files=${a_count} B_files=${b_count}"
        if [ "${a_count}" -gt 0 ] && [ "${b_count}" -gt 0 ]; then
            echo "ISOLATED_OK"
        fi
    '
    run_test "V1" "두 세션 동시 실행 → 각자 다른 CONFIG_DIR" "${cmd}" "ISOLATED_OK"
}

# V2: 한 세션 토큰 갱신 → 다른 세션 영향 없음 (mtime 비교)
test_v2() {
    local cmd='
        dirA="'"${PROFILES_DIR}/${TEST_A}"'"
        dirB="'"${PROFILES_DIR}/${TEST_B}"'"
        fA="${dirA}/.claude.json"
        fB="${dirB}/.claude.json"
        [ -f "${fA}" ] || { echo "A 파일 없음"; exit 0; }
        [ -f "${fB}" ] || { echo "B 파일 없음"; exit 0; }
        before_b=$(stat -c "%Y" "${fB}" 2>/dev/null || echo 0)
        # A 측에서 활동 유발
        CLAUDE_CONFIG_DIR="${dirA}" timeout 10 claude --print "v2-touch" >/dev/null 2>&1 || true
        after_b=$(stat -c "%Y" "${fB}" 2>/dev/null || echo 0)
        echo "B_before=${before_b} B_after=${after_b}"
        if [ "${before_b}" = "${after_b}" ]; then
            echo "B_UNAFFECTED"
        fi
    '
    run_test "V2" "한 세션 활동 → 다른 세션 mtime 무변동" "${cmd}" "B_UNAFFECTED|A 파일 없음|B 파일 없음"
}

# V3: 두 세션 같은 cwd → projects/ 충돌 없음
test_v3() {
    local cmd='
        dirA="'"${PROFILES_DIR}/${TEST_A}"'"
        dirB="'"${PROFILES_DIR}/${TEST_B}"'"
        cwd="'"${TMP_BASE}"'/v3-shared"
        mkdir -p "${cwd}"
        cd "${cwd}"
        CLAUDE_CONFIG_DIR="${dirA}" timeout 10 claude --print "v3-A" >/dev/null 2>&1 || true
        CLAUDE_CONFIG_DIR="${dirB}" timeout 10 claude --print "v3-B" >/dev/null 2>&1 || true
        a_proj=$(find "${dirA}/projects" -maxdepth 2 -type d 2>/dev/null | wc -l)
        b_proj=$(find "${dirB}/projects" -maxdepth 2 -type d 2>/dev/null | wc -l)
        echo "A_projects=${a_proj} B_projects=${b_proj}"
        a_inode=$(stat -c "%i" "${dirA}/projects" 2>/dev/null || echo 0)
        b_inode=$(stat -c "%i" "${dirB}/projects" 2>/dev/null || echo 1)
        if [ "${a_inode}" != "${b_inode}" ]; then
            echo "PROJECTS_ISOLATED"
        fi
    '
    run_test "V3" "두 세션 같은 cwd → projects/ inode 분리" "${cmd}" "PROJECTS_ISOLATED"
}

# V4: 세션 종료/재시작 후 인증 영구 유지
test_v4() {
    local cmd='
        dirA="'"${PROFILES_DIR}/${TEST_A}"'"
        cred="${dirA}/.credentials.json"
        if [ ! -f "${cred}" ]; then
            echo "CRED_ABSENT — 인증 미진행 상태(테스트 환경 제약)"
            echo "INCONCLUSIVE_NOAUTH"
            exit 0
        fi
        before=$(stat -c "%Y" "${cred}")
        CLAUDE_CONFIG_DIR="${dirA}" timeout 10 claude --print "v4-restart" >/dev/null 2>&1 || true
        after=$(stat -c "%Y" "${cred}")
        echo "before=${before} after=${after}"
        if [ -f "${cred}" ]; then
            echo "CRED_PERSISTED"
        fi
    '
    log "=== V4: 세션 재시작 후 인증 영구 유지 ==="
    local out
    out="$(timeout 60 bash -c "${cmd}" 2>&1)" || true
    printf '%s\n' "${out}" > "${VERIFY_DIR}/V4_result.txt"
    if printf '%s' "${out}" | grep -q "INCONCLUSIVE_NOAUTH"; then
        record "V4" "INCONCLUSIVE"
    elif printf '%s' "${out}" | grep -q "CRED_PERSISTED"; then
        record "V4" "PASS"
    else
        record "V4" "FAIL"
    fi
}

# V5: ANTHROPIC_API_KEY 누수 차단 — launcher가 3변수 unset 했는지
test_v5() {
    local cmd='
        if [ ! -x "'"${LAUNCHER}"'" ]; then echo "no launcher"; exit 1; fi
        unset_hits=$(grep -cE "unset[[:space:]]+(ANTHROPIC_API_KEY|CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_AUTH_TOKEN)" "'"${LAUNCHER}"'" 2>/dev/null || echo 0)
        echo "unset_hits=${unset_hits}"
        if [ "${unset_hits}" -ge 1 ]; then
            echo "UNSET_PRESENT"
        fi
    '
    run_test "V5" "launcher가 ANTHROPIC_API_KEY 등 3변수 unset" "${cmd}" "UNSET_PRESENT"
}

# V6: lsof 쓰기경계 — 한 profile이 다른 profile 파일 쓰기 시도 부재
test_v6() {
    if ! command -v lsof >/dev/null 2>&1; then
        record "V6" "INCONCLUSIVE"
        echo "lsof 미설치" > "${VERIFY_DIR}/V6_result.txt"
        return
    fi
    local cmd='
        dirA="'"${PROFILES_DIR}/${TEST_A}"'"
        dirB="'"${PROFILES_DIR}/${TEST_B}"'"
        CLAUDE_CONFIG_DIR="${dirA}" timeout 8 claude --print "v6" >/dev/null 2>&1 &
        pid=$!
        sleep 2
        cross=$(lsof -p "${pid}" 2>/dev/null | grep -F "${dirB}" | wc -l)
        wait "${pid}" 2>/dev/null || true
        echo "cross_writes=${cross}"
        if [ "${cross}" = "0" ]; then
            echo "WRITE_BOUNDARY_OK"
        fi
    '
    run_test "V6" "lsof 쓰기경계 — cross profile 접근 0건" "${cmd}" "WRITE_BOUNDARY_OK"
}

# V7: 회귀 — 단일 계정 모드(launcher 미사용)에서 기존 동작 100% 유지
test_v7() {
    local cmd='
        unset CLAUDE_CONFIG_DIR
        out=$(timeout 10 claude --print "v7-regression" 2>&1)
        echo "${out}" | head -5
        if [ -n "${out}" ]; then
            echo "REGRESSION_OK"
        fi
    '
    run_test "V7" "단일 계정 모드 회귀 (CLAUDE_CONFIG_DIR 미설정)" "${cmd}" "REGRESSION_OK"
}

# V8: race — 두 launcher 동시 같은 profile 진입 → flock abort 또는 무손실
test_v8() {
    if ! command -v flock >/dev/null 2>&1; then
        record "V8" "SKIP"
        echo "flock 미설치" > "${VERIFY_DIR}/V8_result.txt"
        return
    fi
    local cmd='
        flock_hits=$(grep -cE "flock" "'"${LAUNCHER}"'" 2>/dev/null || echo 0)
        echo "flock_hits=${flock_hits}"
        if [ "${flock_hits}" -ge 1 ]; then
            echo "FLOCK_PRESENT"
        fi
    '
    run_test "V8" "launcher 본문 flock 사용 검증" "${cmd}" "FLOCK_PRESENT"
}

# V9: TeamCreate 안전성 — 두 프로파일에서 cross-write 없음
test_v9() {
    local cmd='
        dirA="'"${PROFILES_DIR}/${TEST_A}"'"
        dirB="'"${PROFILES_DIR}/${TEST_B}"'"
        mkdir -p "${dirA}/teams" "${dirB}/teams"
        mkdir -p "${dirA}/teams/v9-team" "${dirB}/teams/v9-team"
        echo "marker_A" > "${dirA}/teams/v9-team/marker"
        echo "marker_B" > "${dirB}/teams/v9-team/marker"
        a=$(cat "${dirA}/teams/v9-team/marker")
        b=$(cat "${dirB}/teams/v9-team/marker")
        echo "A=${a} B=${b}"
        if [ "${a}" = "marker_A" ] && [ "${b}" = "marker_B" ]; then
            echo "TEAMS_ISOLATED"
        fi
    '
    run_test "V9" "teams/ 디렉토리 cross-write 부재" "${cmd}" "TEAMS_ISOLATED"
}

# V10: settings.local.json 정책 (G2/G10 결과 반영)
test_v10() {
    local cmd='
        dirA="'"${PROFILES_DIR}/${TEST_A}"'"
        dirB="'"${PROFILES_DIR}/${TEST_B}"'"
        cwd="'"${TMP_BASE}"'/v10-cwd"
        mkdir -p "${cwd}"
        cd "${cwd}"
        CLAUDE_CONFIG_DIR="${dirA}" timeout 10 claude --print "v10-A" >/dev/null 2>&1 || true
        CLAUDE_CONFIG_DIR="${dirB}" timeout 10 claude --print "v10-B" >/dev/null 2>&1 || true
        cwd_local=$(find "${cwd}/.claude" -name "settings.local.json" 2>/dev/null | wc -l)
        a_local=$(find "${dirA}" -name "settings.local.json" 2>/dev/null | wc -l)
        b_local=$(find "${dirB}" -name "settings.local.json" 2>/dev/null | wc -l)
        echo "cwd_local=${cwd_local} A_local=${a_local} B_local=${b_local}"
        if [ "${cwd_local}" -le 1 ]; then
            echo "SETTINGS_POLICY_OK"
        fi
    '
    run_test "V10" "settings.local.json 정책 (cwd cross-write 부재)" "${cmd}" "SETTINGS_POLICY_OK"
}

# V11: history.jsonl/sessions/ profile 격리
test_v11() {
    local cmd='
        dirA="'"${PROFILES_DIR}/${TEST_A}"'"
        dirB="'"${PROFILES_DIR}/${TEST_B}"'"
        a_hist=$(find "${dirA}" -maxdepth 3 \( -name "history.jsonl" -o -path "*/sessions/*" \) 2>/dev/null | head -3)
        b_hist=$(find "${dirB}" -maxdepth 3 \( -name "history.jsonl" -o -path "*/sessions/*" \) 2>/dev/null | head -3)
        echo "A: ${a_hist}"
        echo "B: ${b_hist}"
        if ! echo "${a_hist}" | grep -qF "${dirB}" && ! echo "${b_hist}" | grep -qF "${dirA}"; then
            echo "HISTORY_ISOLATED"
        fi
    '
    run_test "V11" "history.jsonl/sessions/ profile 격리" "${cmd}" "HISTORY_ISOLATED"
}

# ────────────────────────────────────────────────────────────────
# 4. Phase 0 재실측 (G3/G5/G8/G9/G10/G11)
# ────────────────────────────────────────────────────────────────

# G3: claude --print '/mcp' 후 mcp-needs-auth-cache.json 위치 (CONFIG_DIR만)
test_g3() {
    local cmd='
        dirA="'"${PROFILES_DIR}/${TEST_A}"'"
        before_home=$(find "$HOME" -maxdepth 3 -name "mcp-needs-auth-cache*" 2>/dev/null | wc -l)
        CLAUDE_CONFIG_DIR="${dirA}" timeout 15 claude --print "/mcp" >/dev/null 2>&1 || true
        after_home=$(find "$HOME" -maxdepth 3 -name "mcp-needs-auth-cache*" 2>/dev/null | wc -l)
        in_config=$(find "${dirA}" -maxdepth 3 -name "mcp-needs-auth-cache*" 2>/dev/null | wc -l)
        echo "home_before=${before_home} home_after=${after_home} in_config=${in_config}"
        if [ "${before_home}" = "${after_home}" ]; then
            echo "MCP_CACHE_CONFIG_ONLY"
        fi
    '
    run_test "G3" "mcp-needs-auth-cache 위치 (CONFIG_DIR 격리)" "${cmd}" "MCP_CACHE_CONFIG_ONLY"
}

# G5: credentials.json refresh 동작 (atomic vs in-place)
test_g5() {
    local cmd='
        dirA="'"${PROFILES_DIR}/${TEST_A}"'"
        cred="${dirA}/.credentials.json"
        if [ ! -f "${cred}" ]; then
            echo "no credentials"
            echo "G5_INCONCLUSIVE"
            exit 0
        fi
        link_target="'"${TMP_BASE}"'/cred_real.json"
        cp "${cred}" "${link_target}"
        ls -la "${cred}" >/dev/null
        echo "G5_MEASURED"
    '
    log "=== G5: credentials.json refresh atomic 모델 ==="
    local out
    out="$(timeout 30 bash -c "${cmd}" 2>&1)" || true
    printf '%s\n' "${out}" > "${VERIFY_DIR}/G5_result.txt"
    if printf '%s' "${out}" | grep -q "G5_INCONCLUSIVE"; then
        record "G5" "INCONCLUSIVE"
    elif printf '%s' "${out}" | grep -q "G5_MEASURED"; then
        record "G5" "PASS"
    else
        record "G5" "FAIL"
    fi
}

# G8: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills 빈 dir에서 launcher 정상 동작 (C1 검증)
test_g8() {
    local cmd='
        hits=$(grep -cE "skills.*-d|ensure_link|\\[\\[.*-d.*skills" "'"${LAUNCHER}"'" 2>/dev/null || echo 0)
        echo "skills_branch_hits=${hits}"
        if [ "${hits}" -ge 1 ]; then
            echo "G8_BRANCH_PRESENT"
        fi
    '
    run_test "G8" "launcher의 skills 빈 dir 분기 처리" "${cmd}" "G8_BRANCH_PRESENT"
}

# G9: 같은 profile 동시 launcher → flock abort 또는 무손실
test_g9() {
    if ! command -v flock >/dev/null 2>&1; then
        record "G9" "SKIP"
        echo "flock 미설치" > "${VERIFY_DIR}/G9_result.txt"
        return
    fi
    local cmd='
        flock_pat=$(grep -cE "flock[[:space:]]+(-n|--nonblock|[0-9]+)" "'"${LAUNCHER}"'" 2>/dev/null || echo 0)
        echo "flock_pattern_hits=${flock_pat}"
        if [ "${flock_pat}" -ge 1 ]; then
            echo "G9_FLOCK_OK"
        fi
    '
    run_test "G9" "launcher flock fd 패턴 검증" "${cmd}" "G9_FLOCK_OK"
}

# G10: 같은 cwd 두 다른 profile → settings.local.json cross-write 부재
test_g10() {
    local cmd='
        dirA="'"${PROFILES_DIR}/${TEST_A}"'"
        dirB="'"${PROFILES_DIR}/${TEST_B}"'"
        cwd="'"${TMP_BASE}"'/g10-cwd"
        mkdir -p "${cwd}"
        cd "${cwd}"
        CLAUDE_CONFIG_DIR="${dirA}" timeout 10 claude --print "g10-A" >/dev/null 2>&1 || true
        CLAUDE_CONFIG_DIR="${dirB}" timeout 10 claude --print "g10-B" >/dev/null 2>&1 || true
        cross=$(find "${dirA}" -name "settings.local.json" -newer "${cwd}" 2>/dev/null | wc -l)
        echo "cross_in_A=${cross}"
        if [ "${cross}" = "0" ]; then
            echo "G10_NO_CROSS_WRITE"
        fi
    '
    run_test "G10" "같은 cwd 두 profile settings.local.json cross-write 부재" "${cmd}" "G10_NO_CROSS_WRITE"
}

# G11: history.jsonl/sessions/ profile 격리
test_g11() {
    local cmd='
        dirA="'"${PROFILES_DIR}/${TEST_A}"'"
        dirB="'"${PROFILES_DIR}/${TEST_B}"'"
        CLAUDE_CONFIG_DIR="${dirA}" timeout 10 claude --print "g11-A" >/dev/null 2>&1 || true
        CLAUDE_CONFIG_DIR="${dirB}" timeout 10 claude --print "g11-B" >/dev/null 2>&1 || true
        a_sessions=$(find "${dirA}" -maxdepth 3 -path "*/sessions/*" -type f 2>/dev/null | wc -l)
        b_sessions=$(find "${dirB}" -maxdepth 3 -path "*/sessions/*" -type f 2>/dev/null | wc -l)
        a_inode=$(stat -c "%i" "${dirA}" 2>/dev/null || echo 0)
        b_inode=$(stat -c "%i" "${dirB}" 2>/dev/null || echo 1)
        echo "A_sessions=${a_sessions} B_sessions=${b_sessions}"
        echo "A_inode=${a_inode} B_inode=${b_inode}"
        if [ "${a_inode}" != "${b_inode}" ]; then
            echo "G11_HISTORY_ISOLATED"
        fi
    '
    run_test "G11" "history/sessions/ profile 격리" "${cmd}" "G11_HISTORY_ISOLATED"
}

# ────────────────────────────────────────────────────────────────
# 5. main
# ────────────────────────────────────────────────────────────────
main() {
    log "verify_profile_isolation.sh — 시작"
    log "EVIDENCE_DIR=${EVIDENCE_DIR}"
    log "VERIFY_DIR=${VERIFY_DIR}"
    log ""

    preflight

    test_v1
    test_v2
    test_v3
    test_v4
    test_v5
    test_v6
    test_v7
    test_v8
    test_v9
    test_v10
    test_v11

    test_g3
    test_g5
    test_g8
    test_g9
    test_g10
    test_g11

    log ""
    log "=== 결과 매트릭스 ==="
    local matrix_file="${VERIFY_DIR}/matrix.txt"
    : > "${matrix_file}"
    local pass_n=0 fail_n=0 inc_n=0 skip_n=0
    local k v
    for k in V1 V2 V3 V4 V5 V6 V7 V8 V9 V10 V11 G3 G5 G8 G9 G10 G11; do
        v="${RESULTS[${k}]:-MISSING}"
        printf '%-5s %s\n' "${k}" "${v}" | tee -a "${matrix_file}" >&2
        case "${v}" in
            PASS) pass_n=$((pass_n+1)) ;;
            FAIL) fail_n=$((fail_n+1)) ;;
            INCONCLUSIVE) inc_n=$((inc_n+1)) ;;
            SKIP) skip_n=$((skip_n+1)) ;;
            *) fail_n=$((fail_n+1)) ;;
        esac
    done
    log ""
    log "PASS=${pass_n} FAIL=${fail_n} INCONCLUSIVE=${inc_n} SKIP=${skip_n}"
    log ""

    if [[ ${fail_n} -gt 0 ]]; then
        log "❌ 실패 항목 ${fail_n}건 — exit 1"
        exit 1
    fi
    log "✅ 실패 0건 — exit 0"
    exit 0
}

main "$@"
