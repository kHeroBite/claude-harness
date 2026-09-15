"""const.py — hook/oio 공용 상수 단일 출처 (F7, jury V4 C, Python side).

이 파일은 .claude/hooks/lib/constants.sh 와 수치 동기화를 반드시 유지해야 한다.
(Phase 1: 수동 동기화 + pre-commit lint 로 불변식 검증.)

불변식 (절대 위반 금지):
    LOCK_STALE_TTL_SEC > UX_STALE_DISPLAY_SEC
    — oio lock 기반 실제 stale 판정이 UX 체감 표시보다 커야 "LOCK > UX" 원칙 성립.

사용 예:
    from const import LOCK_STALE_TTL_SEC, UX_STALE_DISPLAY_SEC
"""

# --- oio / session lifecycle TTL ---
LOCK_STALE_TTL_SEC: int = 600       # oio app-lock TTL (대형 빌드 10분+ 허용)
UX_STALE_DISPLAY_SEC: int = 300     # UX stale 표시 임계 (LOCK 보다 작아야 함)

# --- 팀에이전트 타임아웃 ---
AGENT_TIMEOUT_DEFAULT: int = 900    # 팀에이전트 기본 타임아웃 (15분)

# --- ACK 2단계 (F2) ---
ACK_WAIT_SECONDS: int = 15
ACK_POLL_INTERVAL: int = 1

# --- 불변식 import 시점 1회 검증 ---
assert LOCK_STALE_TTL_SEC > UX_STALE_DISPLAY_SEC, (
    f"LOCK_STALE_TTL_SEC({LOCK_STALE_TTL_SEC}) must be > "
    f"UX_STALE_DISPLAY_SEC({UX_STALE_DISPLAY_SEC}) — 'LOCK > UX' invariant"
)
