#!/usr/bin/env bash
# AC-002: sync_back — TMP_CFG의 .credentials.json이 PROFILE_DIR로 동기화됨 확인
# 절차: 가짜 .credentials.json을 TMP_CFG에 미리 배치 → cas 실행(CLAUDE_BIN=/bin/true) → PROFILE_DIR에 복사됐는지 확인
set -euo pipefail

CAS="/mnt/c/DATA/Project/AI/bin/claude-as"
PROFILE="cas-test-ac002"
PROFILES_ROOT="${CLAUDE_PROFILES_ROOT:-$HOME/.claude-profiles}"
PROFILE_DIR="${PROFILES_ROOT}/${PROFILE}"
FIXED_UUID="ac002-test-$(date +%s)"

# 사전 정리
rm -rf "${PROFILE_DIR}" 2>/dev/null || true
rm -rf "/tmp/cc-${FIXED_UUID}" 2>/dev/null || true

# 프로파일 생성
mkdir -p "${PROFILE_DIR}"
chmod 700 "${PROFILE_DIR}"

# CLAUDE_AS_UUID 고정으로 TMP_CFG 경로 예측
TMP_CFG="/tmp/cc-${FIXED_UUID}"
mkdir -p "${TMP_CFG}"
chmod 700 "${TMP_CFG}"

# 가짜 .credentials.json 배치 (TMP_CFG에 직접 — sync_back이 이걸 PROFILE_DIR로 복사해야 함)
FAKE_CREDS='{"claudeAiOauth":{"accessToken":"FAKE_AC002_TOKEN","refreshToken":"FAKE_REFRESH","expiresAt":99999999999,"scopes":["user:profile"]}}'
echo "${FAKE_CREDS}" > "${TMP_CFG}/.credentials.json"
chmod 600 "${TMP_CFG}/.credentials.json"

echo "[AC-002] CLAUDE_BIN=/bin/true CLAUDE_AS_UUID=${FIXED_UUID} cas ${PROFILE} 실행..."

# CLAUDE_BIN=/bin/true: 즉시 exit 0 → cleanup_and_exit 실행 → sync_back → TMP_CFG 삭제
# 주의: (e)단계에서 PROFILE_DIR → TMP_CFG 복사 먼저 실행됨 (우리가 만든 파일 덮어쓸 수 있음)
# 해결: 위 단계를 피하기 위해 PROFILE_DIR에 .credentials.json 없이 시작
CLAUDE_BIN=/bin/true CLAUDE_AS_UUID="${FIXED_UUID}" CLAUDE_PROFILES_ROOT="${PROFILES_ROOT}" "${CAS}" "${PROFILE}"
EXIT_CODE=$?

# sync_back 결과 확인
if [[ -f "${PROFILE_DIR}/.credentials.json" ]]; then
    CONTENT=$(cat "${PROFILE_DIR}/.credentials.json")
    if echo "${CONTENT}" | grep -q "FAKE_AC002_TOKEN"; then
        echo "[AC-002] PASS: sync_back 성공 — .credentials.json PROFILE_DIR에 존재"
        RESULT=0
    else
        echo "[AC-002] FAIL: .credentials.json 존재하지만 내용 불일치"
        echo "내용: ${CONTENT}"
        RESULT=1
    fi
else
    echo "[AC-002] FAIL: sync_back 미실행 — PROFILE_DIR에 .credentials.json 없음"
    RESULT=1
fi

# TMP_CFG 정리됐는지도 확인
if [[ -d "${TMP_CFG}" ]]; then
    echo "[AC-002] WARNING: TMP_CFG 미삭제 — ${TMP_CFG}"
    rm -rf "${TMP_CFG}" 2>/dev/null || true
fi

# 정리
rm -rf "${PROFILE_DIR}" 2>/dev/null || true

exit ${RESULT}
