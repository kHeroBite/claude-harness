#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# oio_connectivity_check.sh
# oio MCP 연결 상태 감지 + degraded mode 배너 + 로컬 flock fallback
#
# v2 C-30/C-31: Phase Batch Auto-Loop degraded mode
#   - oio MCP 연결 끊김 감지
#   - degraded 상태일 때 사용자용 배너 출력
#   - PREPARE 단계 reject 신호 (exit 31)
#   - 로컬 flock fallback 경로 반환

set -euo pipefail

# ─────────────────────────────────────────────
# 상수
# ─────────────────────────────────────────────
readonly OIO_SOCKET_GLOB="/tmp/cxc-*/broker.sock"
readonly LOCAL_LOCK_ROOT="/var/tmp/claude_local_lock"
readonly EXIT_DEGRADED_REJECT=31

# ─────────────────────────────────────────────
# Usage
# ─────────────────────────────────────────────
usage() {
  cat <<'EOF'
Usage: oio_connectivity_check.sh [OPTIONS]

OPTIONS:
  --banner             degraded 상태일 때 사용자용 배너 출력
  --check-prepare      PREPARE 단계 검증. degraded 시 exit 31
  --fallback-path UUID 로컬 flock fallback 경로 반환 (/var/tmp/claude_local_lock/${UUID}.lock)
  --help, -h           이 도움말 출력

EXIT CODES:
  0   FULL mode (oio 정상 연결)
  1   DEGRADED mode (oio 연결 끊김)
  31  DEGRADED + PREPARE reject 신호

OUTPUT:
  stdout: "FULL" 또는 "DEGRADED"
EOF
}

# ─────────────────────────────────────────────
# oio 연결 상태 감지
# ─────────────────────────────────────────────
detect_oio_status() {
  # 1. oio broker socket 파일 존재 확인
  local sock_found=0
  for sock in $OIO_SOCKET_GLOB; do
    if [ -S "$sock" ] 2>/dev/null; then
      sock_found=1
      break
    fi
  done

  if [ "$sock_found" -eq 0 ]; then
    echo "DEGRADED"
    return 1
  fi

  # 2. oio 프로세스 활성 확인 (python3 -m oio.server 또는 유사)
  if ! pgrep -f "oio" >/dev/null 2>&1; then
    echo "DEGRADED"
    return 1
  fi

  echo "FULL"
  return 0
}

# ─────────────────────────────────────────────
# 사용자용 배너
# ─────────────────────────────────────────────
print_banner() {
  cat <<'EOF'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
⚠️  oio MCP DEGRADED MODE 감지
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
상태: oio MCP 서버 연결 끊김 또는 socket 미존재
영향:
  - Phase Batch Auto-Loop: 로컬 flock fallback 모드
  - 파일 I/O: Claude 내장 도구 임시 전환 필요
  - PREPARE 단계: 신규 batch 진입 차단

복구 방법:
  1. /mcp 명령으로 MCP 서버 상태 확인
  2. oio 서버 재연결
  3. 재연결 후 /oresume으로 파이프라인 재개

Fallback 경로: /var/tmp/claude_local_lock/
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
}

# ─────────────────────────────────────────────
# 로컬 flock fallback 경로 반환
# ─────────────────────────────────────────────
fallback_path() {
  local uuid="${1:-default}"
  mkdir -p "$LOCAL_LOCK_ROOT" 2>/dev/null || true
  echo "${LOCAL_LOCK_ROOT}/${uuid}.lock"
}

# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────
main() {
  local mode="status"
  local uuid=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --help|-h)
        usage
        exit 0
        ;;
      --banner)
        mode="banner"
        shift
        ;;
      --check-prepare)
        mode="check-prepare"
        shift
        ;;
      --fallback-path)
        mode="fallback-path"
        uuid="${2:-default}"
        shift 2
        ;;
      *)
        echo "Unknown option: $1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done

  case "$mode" in
    status)
      detect_oio_status
      ;;
    banner)
      local status
      status="$(detect_oio_status 2>/dev/null || echo DEGRADED)"
      if [ "$status" = "DEGRADED" ]; then
        print_banner
        exit 1
      fi
      echo "FULL"
      exit 0
      ;;
    check-prepare)
      local status
      status="$(detect_oio_status 2>/dev/null || echo DEGRADED)"
      if [ "$status" = "DEGRADED" ]; then
        print_banner >&2
        echo "DEGRADED" >&2
        echo "PREPARE rejected: oio degraded mode" >&2
        exit $EXIT_DEGRADED_REJECT
      fi
      echo "FULL"
      exit 0
      ;;
    fallback-path)
      fallback_path "$uuid"
      exit 0
      ;;
  esac
}

main "$@"
