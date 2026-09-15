#!/usr/bin/env bash
# AC-004: flock — 같은 프로파일로 동시 두 cas 실행 → 두 번째가 차단(exit 1)
set -euo pipefail

CAS="/mnt/c/DATA/Project/AI/bin/claude-as"
PROFILE="cas-test-ac004"
PROFILES_ROOT="${CLAUDE_PROFILES_ROOT:-$HOME/.claude-profiles}"
PROFILE_DIR="${PROFILES_ROOT}/${PROFILE}"

# 사전 정리
rm -rf "${PROFILE_DIR}" 2>/dev/null || true

# 프로파일 생성
mkdir -p "${PROFILE_DIR}"
chmod 700 "${PROFILE_DIR}"

echo "[AC-004] 첫 번째 cas 백그라운드 실행 (sleep 3초 동안 점유)..."
CLAUDE_BIN="/bin/sleep" CLAUDE_PROFILES_ROOT="${PROFILES_ROOT}" "${CAS}" "${PROFILE}" 3 &
FIRST_PID=$!
sleep 0.5  # 첫 번째가 flock 획득할 시간

echo "[AC-004] 두 번째 cas 실행 (차단 예상)..."
set +e
CLAUDE_BIN=/bin/true CLAUDE_PROFILES_ROOT="${PROFILES_ROOT}" "${CAS}" "${PROFILE}" 2>&1
SECOND_EXIT=$?
set -e

echo "[AC-004] 두 번째 cas exit code: ${SECOND_EXIT}"

# 첫 번째 프로세스 종료 대기
wait "${FIRST_PID}" 2>/dev/null || true

if [[ "${SECOND_EXIT}" -eq 1 ]]; then
    echo "[AC-004] PASS: 두 번째 cas가 flock으로 차단됨 (exit 1)"
    RESULT=0
else
    echo "[AC-004] FAIL: 두 번째 cas가 차단되지 않음 (exit=${SECOND_EXIT})"
    RESULT=1
fi

# 정리
rm -rf "${PROFILE_DIR}" 2>/dev/null || true

exit ${RESULT}
