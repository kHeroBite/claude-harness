#!/usr/bin/env bash
# AC-001: EXIT cleanup — exec 제거 후 정상 종료 시 cleanup 실행 확인
# CLAUDE_BIN=/bin/true로 바꿔치기 → claude 대신 /bin/true 실행 → exit 0
# 기대: TMP_CFG 디렉토리가 삭제됨 (sync_back + rm -rf 실행)
set -euo pipefail

CAS="/mnt/c/DATA/Project/AI/bin/claude-as"
PROFILE="cas-test-ac001"
PROFILES_ROOT="${CLAUDE_PROFILES_ROOT:-$HOME/.claude-profiles}"
PROFILE_DIR="${PROFILES_ROOT}/${PROFILE}"

# 사전 정리
rm -rf "${PROFILE_DIR}" 2>/dev/null || true

# 프로파일 생성 (cmd_create 없이 직접 — OAuth 우회)
mkdir -p "${PROFILE_DIR}"
chmod 700 "${PROFILE_DIR}"

echo "[AC-001] CLAUDE_BIN=/bin/true cas ${PROFILE} 실행..."
CLAUDE_BIN=/bin/true CLAUDE_PROFILES_ROOT="${PROFILES_ROOT}" "${CAS}" "${PROFILE}"
EXIT_CODE=$?

# TMP_CFG가 삭제됐는지 확인 (cleanup 실행 증거)
# TMP_CFG=/tmp/cc-<UUID> — UUID는 CLAUDE_AS_UUID 환경변수로 고정 가능
echo "[AC-001] exit code: ${EXIT_CODE}"

# 남아있는 cc-* 디렉토리 확인 (5분 이내 mtime)
REMAINING=$(find /tmp -maxdepth 1 -type d -name 'cc-*' -mmin -1 2>/dev/null | wc -l)
echo "[AC-001] /tmp/cc-* 잔류 (1분 이내): ${REMAINING}개"

if [[ "${EXIT_CODE}" -eq 0 && "${REMAINING}" -eq 0 ]]; then
    echo "[AC-001] PASS: exit 0 + TMP_CFG 정리됨"
    RESULT=0
else
    echo "[AC-001] FAIL: exit=${EXIT_CODE}, 잔류=${REMAINING}"
    RESULT=1
fi

# 정리
rm -rf "${PROFILE_DIR}" 2>/dev/null || true

exit ${RESULT}
