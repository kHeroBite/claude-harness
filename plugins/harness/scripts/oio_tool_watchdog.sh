#!/bin/bash
# oio_tool_watchdog.sh — oio MCP 서버 CPU 정지 감지
# 사용법: bash oio_tool_watchdog.sh [--auto-kill]
set -euo pipefail
AUTO_KILL=${1:-""}
THRESHOLD_SECONDS=60

oio_pids=$(pgrep -f "oio-mcp-server" 2>/dev/null || true)
if [ -z "$oio_pids" ]; then
  echo "oio MCP 서버 프로세스 없음"
  exit 0
fi

echo "=== oio MCP 서버 watchdog ==="
stuck_found=false
for pid in $oio_pids; do
  [ ! -d "/proc/$pid" ] && continue
  cpu1=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ' || echo "0")
  sleep 2
  cpu2=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ' || echo "0")
  etime=$(ps -p "$pid" -o etimes= 2>/dev/null | tr -d ' ' || echo "0")
  echo "PID=$pid CPU=${cpu1}%→${cpu2}% elapsed=${etime}s"
  if [ "$(echo "$cpu1 < 0.1 && $cpu2 < 0.1" | bc 2>/dev/null || echo 0)" = "1" ] && [ "$etime" -gt "$THRESHOLD_SECONDS" ]; then
    echo "  정지 의심: CPU 0% 지속"
    stuck_found=true
    if [ "$AUTO_KILL" = "--auto-kill" ]; then
      kill -9 "$pid" 2>/dev/null || true
      echo "  kill -9 $pid 완료"
    fi
  fi
done

if $stuck_found; then
  echo "정지된 oio 서버 발견. /mcp 명령으로 재연결 필요."
  exit 1
fi
echo "모든 oio 서버 정상"
exit 0
