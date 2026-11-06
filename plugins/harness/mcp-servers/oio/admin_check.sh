#!/usr/bin/env bash
# oio-mcp-server 운영 진단 스크립트.
# pgrep/lock directory/fd 카운트/multi-instance/BG pid registry를 점검한다.
#
# 사용법:
#   bash admin_check.sh
#
# 종료 코드:
#   0 = 정상
#   1 = 이상 감지 (다중 인스턴스 등)

set -u

LOCK_BASE_DIR="${OIO_LOCK_BASE_DIR:-/tmp/oio-locks}"
STATE_DIR="${OIO_STATE_DIR:-$HOME/.claude/oio-locks}"
SERVER_PATTERN="oio-mcp-server"

echo "=== oio-mcp-server admin_check ==="
date +"[time] %Y-%m-%d %H:%M:%S"

# 1) 프로세스 감지 (pgrep)
PIDS="$(pgrep -f "${SERVER_PATTERN}" || true)"
if [[ -z "${PIDS}" ]]; then
  echo "[proc] 실행 중 프로세스 없음"
  PROC_COUNT=0
else
  PROC_COUNT="$(echo "${PIDS}" | wc -w)"
  echo "[proc] 감지 ${PROC_COUNT}개 — pid: ${PIDS}"
fi

# 2) multi-instance 경고 (2개 이상이면 이상)
MULTI_FLAG=0
if [[ "${PROC_COUNT}" -ge 2 ]]; then
  echo "[proc] ⚠️ multi-instance 감지 (${PROC_COUNT}개)" >&2
  MULTI_FLAG=1
fi

# 3) lock directory 카운트
if [[ -d "${LOCK_BASE_DIR}" ]]; then
  LOCK_COUNT="$(find "${LOCK_BASE_DIR}" -maxdepth 1 -name "*.lock" -type f 2>/dev/null | wc -l)"
  echo "[locks] ${LOCK_BASE_DIR} : ${LOCK_COUNT}개"
else
  echo "[locks] ${LOCK_BASE_DIR} 디렉토리 없음"
fi

# 4) state directory (session_manager 관리)
if [[ -d "${STATE_DIR}" ]]; then
  STATE_COUNT="$(find "${STATE_DIR}" -maxdepth 2 -type f 2>/dev/null | wc -l)"
  echo "[state] ${STATE_DIR} : ${STATE_COUNT}개 파일"
fi

# 5) 각 프로세스 fd 카운트
for pid in ${PIDS}; do
  if [[ -d "/proc/${pid}/fd" ]]; then
    FD_COUNT="$(ls -1 "/proc/${pid}/fd" 2>/dev/null | wc -l)"
    echo "[fd] pid=${pid} fd=${FD_COUNT}"
  fi
done

# 6) BG pid registry 스캔 (bash_exec registry 디렉토리 추정)
BG_REG_DIR="${OIO_BG_REG_DIR:-/tmp/oio-bg-registry}"
if [[ -d "${BG_REG_DIR}" ]]; then
  BG_COUNT="$(find "${BG_REG_DIR}" -maxdepth 1 -type f 2>/dev/null | wc -l)"
  echo "[bg] ${BG_REG_DIR} : ${BG_COUNT}개 registry entry"
fi

exit "${MULTI_FLAG}"
