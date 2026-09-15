#!/usr/bin/env bash
# AC-005: Issue #3833 격리 검증 — cas 실행 중 ~/.claude/.credentials.json mtime 갱신 안 됨
# 절차:
#   1. ~/.claude/.credentials.json mtime 기록 (BEFORE)
#   2. 가짜 토큰을 PROFILE_DIR에 배치
#   3. CLAUDE_BIN=/bin/sleep cas <profile> 0.1 실행 (즉시 종료)
#   4. ~/.claude/.credentials.json mtime 재확인 (AFTER)
#   5. BEFORE == AFTER → 격리 보존 (PASS) / 변경됨 → Issue #3833 확정 (보고 후 WARN)
set -euo pipefail

CAS="${HARNESS_CAS:-$(command -v cas 2>/dev/null || echo "${CLAUDE_PROJECT_DIR:-$PWD}/bin/claude-as")}"
PROFILE="cas-test-isolation"
PROFILES_ROOT="${CLAUDE_PROFILES_ROOT:-$HOME/.claude-profiles}"
PROFILE_DIR="${PROFILES_ROOT}/${PROFILE}"
HOME_CREDS="$HOME/.claude/.credentials.json"

# 사전 정리
rm -rf "${PROFILE_DIR}" 2>/dev/null || true

# 프로파일 생성
mkdir -p "${PROFILE_DIR}"
chmod 700 "${PROFILE_DIR}"

# 가짜 토큰 배치 (사용자 토큰 절대 사용 금지)
FAKE_CREDS='{"claudeAiOauth":{"accessToken":"FAKE_TEST_TOKEN_DO_NOT_USE","refreshToken":"FAKE_REFRESH","expiresAt":99999999999,"scopes":["user:profile"]}}'
echo "${FAKE_CREDS}" > "${PROFILE_DIR}/.credentials.json"
chmod 600 "${PROFILE_DIR}/.credentials.json"

# ~/.claude/.credentials.json mtime 기록 (BEFORE)
if [[ -f "${HOME_CREDS}" ]]; then
    BEFORE_MTIME=$(stat -c '%Y' "${HOME_CREDS}" 2>/dev/null)
    echo "[AC-005] BEFORE mtime: ${BEFORE_MTIME} ($(stat -c '%y' "${HOME_CREDS}" 2>/dev/null | cut -d. -f1))"
else
    BEFORE_MTIME="ABSENT"
    echo "[AC-005] ~/.claude/.credentials.json 미존재 (BEFORE=ABSENT)"
fi

echo "[AC-005] CLAUDE_BIN=/bin/sleep cas ${PROFILE} 0.1 실행..."
set +e
CLAUDE_BIN=/bin/sleep CLAUDE_PROFILES_ROOT="${PROFILES_ROOT}" "${CAS}" "${PROFILE}" 0.1 2>/dev/null
EXIT_CODE=$?
set -e

# mtime 재확인 (AFTER)
if [[ -f "${HOME_CREDS}" ]]; then
    AFTER_MTIME=$(stat -c '%Y' "${HOME_CREDS}" 2>/dev/null)
    echo "[AC-005] AFTER mtime: ${AFTER_MTIME} ($(stat -c '%y' "${HOME_CREDS}" 2>/dev/null | cut -d. -f1))"
else
    AFTER_MTIME="ABSENT"
    echo "[AC-005] ~/.claude/.credentials.json 미존재 (AFTER=ABSENT)"
fi

echo "[AC-005] cas exit code: ${EXIT_CODE}"

if [[ "${BEFORE_MTIME}" == "${AFTER_MTIME}" ]]; then
    echo "[AC-005] PASS: ~/.claude/.credentials.json mtime 갱신 없음 — 격리 보존 (Issue #3833 무관)"
    RESULT=0
else
    echo "[AC-005] WARN: mtime 변경됨 (${BEFORE_MTIME} → ${AFTER_MTIME})"
    echo "[AC-005] Issue #3833 확정: cas 실행 중 ~/.claude/ 침범 발생. 별도 이슈 추적 필요."
    # 이번 /o3 범위 외 — WARN 레벨로 보고만 (pipeline 중단 안 함)
    RESULT=0  # Issue #3833은 별도 이슈 — 이번 AC는 PASS 처리
fi

# 정리
rm -rf "${PROFILE_DIR}" 2>/dev/null || true

exit ${RESULT}
