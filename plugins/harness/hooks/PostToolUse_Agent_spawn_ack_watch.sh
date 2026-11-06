#!/bin/bash
# 팀원 spawn 후 첫 지시 소비를 감시해, 기한(기본 150s) 내 미확인 시 리드를 깨워 재송신을 유도하는 hook
# PostToolUse:Agent — settings 엔트리는 "asyncRewake": true, timeout 240 으로 등록한다 (계획서 §6.3-2).
#
# ── 왜 필요한가 (2026-10-10 실측) ─────────────────────────────────────────
# 부하로 팀원 프로세스 기동이 늦어진 사이 정리 루틴이 아직 읽히지 않은 inbox 를 지웠고,
# 팀원은 첫 지시 없이 입력 대기 상태로 남았다 (odev-8·oi-fix-1, 이후 odev-tb3·tb4·tb6 재발).
# Agent 도구는 "성공" 을 반환하므로 리드는 위임이 끝났다고 믿는다 ⇒ 결과 감지가 필요하다.
#
# ── 동작 ───────────────────────────────────────────────────────────────
# asyncRewake: 백그라운드로 돌고, exit 2 로 끝나면 idle 리드도 깨워 stderr 를 전달한다.
# 판정은 lib/spawn_ack_watch.py 가 한다 (ack → exit 0 / 미확인 → exit 2 + stderr).
#
# 비상 스위치: touch ${HARNESS_HOME:-$HOME/.harness}/current/hooks/DISABLE_SPAWN_ACK_WATCH
# fail-open: 판정 불가·의존성 부재 시 exit 0.

set -u

_HOOK_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || _HOOK_DIR="${HARNESS_HOME:-$HOME/.harness}/current/hooks"
[ -r "${_HOOK_DIR}/lib/spawn_ack_watch.py" ] || _HOOK_DIR="${HARNESS_HOME:-$HOME/.harness}/current/hooks"

for _sw in "${_HOOK_DIR}/DISABLE_SPAWN_ACK_WATCH" "${HARNESS_HOME:-$HOME/.harness}/current/hooks/DISABLE_SPAWN_ACK_WATCH"; do
  [ -f "$_sw" ] && exit 0
done

command -v python3 >/dev/null 2>&1 || exit 0
[ -r "${_HOOK_DIR}/lib/spawn_ack_watch.py" ] || exit 0

INPUT=$(timeout 5 cat 2>/dev/null) || exit 0
[ -z "$INPUT" ] && exit 0

printf '%s' "$INPUT" | python3 -I "${_HOOK_DIR}/lib/spawn_ack_watch.py"
_rc=$?
# 0·2 외 코드는 fail-open 으로 정규화 (asyncRewake 는 exit 2 만 리드를 깨운다)
[ "$_rc" -eq 2 ] && exit 2
exit 0
