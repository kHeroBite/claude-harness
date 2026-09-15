#!/usr/bin/env bash
# AC-003: exit code 전파 — CLAUDE_BIN=/bin/false → cas exit code 1 확인
set -euo pipefail

CAS="${HARNESS_CAS:-$(command -v cas 2>/dev/null || echo "${CLAUDE_PROJECT_DIR:-$PWD}/bin/claude-as")}"
PROFILE="cas-test-ac003"
PROFILES_ROOT="${CLAUDE_PROFILES_ROOT:-$HOME/.claude-profiles}"
PROFILE_DIR="${PROFILES_ROOT}/${PROFILE}"

# 사전 정리
rm -rf "${PROFILE_DIR}" 2>/dev/null || true

# 프로파일 생성
mkdir -p "${PROFILE_DIR}"
chmod 700 "${PROFILE_DIR}"

echo "[AC-003] CLAUDE_BIN=/bin/false cas ${PROFILE} 실행 (exit code 1 예상)..."
set +e
CLAUDE_BIN=/bin/false CLAUDE_PROFILES_ROOT="${PROFILES_ROOT}" "${CAS}" "${PROFILE}"
ACTUAL_EXIT=$?
set -e

echo "[AC-003] 실제 exit code: ${ACTUAL_EXIT}"

if [[ "${ACTUAL_EXIT}" -eq 1 ]]; then
    echo "[AC-003] PASS: exit code 1 정상 전파"
    RESULT=0
else
    echo "[AC-003] FAIL: 예상 exit=1, 실제 exit=${ACTUAL_EXIT}"
    RESULT=1
fi

# 정리
rm -rf "${PROFILE_DIR}" 2>/dev/null || true

exit ${RESULT}
