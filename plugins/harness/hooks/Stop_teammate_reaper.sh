#!/bin/bash
# 리더 Stop 시 자기 세션 done 지속 팀원을 정리하고 장기 실행 팀원이 있으면 exit 2 로 교대를 권고하는 hook(asyncRewake)
#
# 동작 순서
#   1. 팀원 컨텍스트면 즉시 exit 0 — hook 입력 agent_id 존재 / stop_hook_active=true / 조상 cmdline 에 --agent-id
#      (전역 Stop hook 은 팀원 claude 프로세스 안에서도 실행된다. 이 분기가 없으면 exit 2 가 팀원을 반복으로 깨운다)
#   2. session_id(UUID) 불명 → exit 0 (소유권 증명 불가 시 fail-closed, §(b))
#   3. state 가 IDLE·부재 이거나 자기 세션 팀원 프로세스 0개 → exit 0
#   4. teammate_reaper.py --self-done --apply (done 10분 지속 + 면제 없음인 자기 세션 팀원만 종료)
#   5. teammate_reaper.py --report-long → rc=10(새 보고) 이면 stderr 안내 후 exit 2 (같은 팀원 30분 억제는 reaper 가 담당)
# 쓰기: reaper 가 자기 session-env/<UUID>/logs/ 에만 쓴다. 타 세션 파일은 읽지도 쓰지도 않는다.

HOOK_INPUT=$(cat 2>/dev/null || true)

# ── 1. 팀원 컨텍스트 즉시 종료 ──
if printf '%s' "$HOOK_INPUT" | grep -Eq '"agent_id"[[:space:]]*:[[:space:]]*"[^"]+'; then
  exit 0
fi
if printf '%s' "$HOOK_INPUT" | grep -Eq '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
  exit 0
fi
_p="$PPID"
_i=0
while [ -n "$_p" ] && [ "$_p" -gt 1 ] 2>/dev/null && [ "$_i" -lt 30 ]; do
  if [ -r "/proc/$_p/cmdline" ] && tr '\0' '\n' < "/proc/$_p/cmdline" 2>/dev/null | grep -Eq '^--agent-id(=|$)'; then
    exit 0
  fi
  _p=$(awk '{ s=$0; sub(/^.*\) /, "", s); split(s, f, " "); print f[2] }' "/proc/$_p/stat" 2>/dev/null)
  _i=$((_i + 1))
done

# ── 2. UUID ──
MY_UUID=$(printf '%s' "$HOOK_INPUT" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
[ -z "$MY_UUID" ] && MY_UUID="${PIPELINE_UUID:-}"
if ! printf '%s' "$MY_UUID" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
  exit 0
fi

# ── 3. IDLE·팀원 0 즉시 종료 ──
CFG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SESSION_DIR="${CFG_DIR}/session-env/${MY_UUID}"
[ -d "$SESSION_DIR" ] || SESSION_DIR="$HOME/.claude/session-env/${MY_UUID}"
[ -d "$SESSION_DIR" ] || exit 0
STATE=$(awk 'NR==1{print $1}' "$SESSION_DIR/state" 2>/dev/null)
case "$STATE" in
  ""|IDLE) exit 0 ;;
esac
if ! pgrep -u "$(id -u)" -f -- "--parent-session-id ${MY_UUID}" >/dev/null 2>&1; then
  exit 0
fi

# ── 4·5. reaper ──
REAPER="${HARNESS_HOME:-$HOME/.harness}/current/scripts/teammate_reaper.py"
[ -f "$REAPER" ] || exit 0
timeout 35 python3 -B "$REAPER" --self-done --apply --uuid "$MY_UUID" --session-dir "$SESSION_DIR" >/dev/null 2>&1
LONG_OUT=$(timeout 15 python3 -B "$REAPER" --report-long --uuid "$MY_UUID" --session-dir "$SESSION_DIR" 2>/dev/null)
LONG_RC=$?
if [ "$LONG_RC" -eq 10 ]; then
  {
    echo "🔁 [teammate_reaper] 장기 실행 팀원 교대 권고 (kill 안 함, 같은 팀원 30분 억제)"
    printf '%s\n' "$LONG_OUT"
    echo "조치: ok_pipeline SKILL.md '팀원 교대 절차'(인계 파일 → 후임 spawn → 선임 shutdown) 또는 작업 종료 팀원 shutdown_request."
  } >&2
  exit 2
fi
exit 0
