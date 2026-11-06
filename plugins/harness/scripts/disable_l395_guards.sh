#!/bin/bash
# disable_l395_guards.sh — L-395 guard 일괄 비활성화
set -euo pipefail

echo "=== L-395 Guard 비활성화 시작 ==="

GUARD="${HARNESS_HOME:-$HOME/.harness}/current/hooks/guards/readback_guard.sh"
if [[ -f "$GUARD" ]]; then
    sed -i '2s/^/exit 0  # L-395 DISABLED\n/' "$GUARD"
    echo "✅ readback_guard.sh 비활성화"
fi

GUARD2="${HARNESS_HOME:-$HOME/.harness}/current/hooks/agent_completion_guard.sh"
if [[ -f "$GUARD2" ]]; then
    sed -i '2s/^/exit 0  # L-395 DISABLED\n/' "$GUARD2"
    echo "✅ agent_completion_guard.sh 비활성화"
fi

pkill -f "agent_watchdog.sh --auto-check" 2>/dev/null && echo "✅ agent_watchdog daemon 중지" || true

echo ""
echo "⚠️  oio self-verify / io_activity_watchdog는 서버 코드이므로 수동 비활성화 필요:"
echo "    1. file_ops.py: _self_verify_write/_self_verify_edit 호출부 주석 처리"
echo "    2. server.py: _start_io_activity_watchdog() 호출 주석 처리"
echo "    3. Claude Code 세션 재시작"
echo "=== 완료 ==="
