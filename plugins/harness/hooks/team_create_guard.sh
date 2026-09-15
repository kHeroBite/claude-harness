#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# team_create_guard.sh — TeamCreate 전 기존 팀 잔류 차단 (L-052 재발방지)
# PreToolUse:TeamCreate hook
# 목적: "Already leading team" 오류 물리 차단
#        현재 세션이 이미 팀을 리드 중이면 TeamCreate를 차단하고 TeamDelete 먼저 호출 안내
# config.json 대신 ~/.claude/session-env/${UUID}/state + team_name 파일로 판단

trap 'exit 0' ERR

INPUT=$(timeout 5 cat 2>/dev/null) || INPUT=""
TEAM_NAME=$(echo "$INPUT" | jq -r '.tool_input.team_name // empty' 2>/dev/null || echo "")
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")

# --- UUID 결정 ---
source "${HARNESS_HOOK_DIR}/lib/session_id.sh"
if ! resolve_uuid "$INPUT" 2>/dev/null; then
  exit 0
fi
[[ -z "$UUID" ]] && exit 0

SESSION_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}"
STATE_FILE="${SESSION_DIR}/state"
TEAM_NAME_FILE="${SESSION_DIR}/team_name"
TEAM_NAME_LOCK="${SESSION_DIR}/team_name.lock"

# --- [P1-isolation] lazy orphan teams 정리 (2026-04-22) ---
# 목적: 타 세션의 비정상 종료로 teams/<name>/이 남았지만 어느 session-env에도 등록되지 않은 경우,
#       지금 같은 이름으로 TeamCreate 시도 시 "already exists" 오류가 나기 전에 자동 제거.
# 안전 원칙 (CLAUDE.md §세션 격리 불변식):
#   1) 요청 팀명(TEAM_NAME)의 teams/<name>/이 존재
#   2) 어떤 session-env/*/team_name 파일에도 이 이름이 기록되어 있지 않음 (고아)
#   3) teams/<name>/config.json의 leadSessionId가 존재하지 않거나, 해당 UUID의 session-env 자체가 부재
#   위 3조건 교집합일 때만 rm -rf. (고아 증명 fail-closed)
if [[ -n "$TEAM_NAME" ]]; then
  _ORPHAN_TEAM_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams/${TEAM_NAME}"
  if [[ -d "$_ORPHAN_TEAM_DIR" ]]; then
    # 조건 2: session-env/*/team_name 순회 (읽기만, 격리 불변식 (a) 준수)
    _ORPHAN_CLAIMED=0 _od=""
    for _od in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env"/*/; do
      [[ -d "$_od" ]] || continue
      [[ -f "${_od}team_name" ]] || continue
      if [[ "$(cat "${_od}team_name" 2>/dev/null | tr -d '\r\n')" == "$TEAM_NAME" ]]; then
        _ORPHAN_CLAIMED=1
        break
      fi
    done
    # 조건 3: config.json leadSessionId의 session-env 디렉토리 존재 + state 활성 여부 (L-430 강화)
    _ORPHAN_OWNER_ALIVE=0
    if [[ $_ORPHAN_CLAIMED -eq 0 && -f "${_ORPHAN_TEAM_DIR}/config.json" ]]; then
      _ORPHAN_LEAD=$(jq -r '.leadSessionId // empty' "${_ORPHAN_TEAM_DIR}/config.json" 2>/dev/null || echo "")
      if [[ -n "$_ORPHAN_LEAD" ]] && [[ -d "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${_ORPHAN_LEAD}" ]]; then
        _ORPHAN_OWNER_ALIVE=1
        # 추가 검증: state가 활성이면 더 강력히 보호 (이중 안전망 — L-430)
        _ORPHAN_LEAD_STATE=$(state_read "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${_ORPHAN_LEAD}/state" \
          2>/dev/null | awk '{print $1}' | tr -d '\r' || echo "")
        if [[ "$_ORPHAN_LEAD_STATE" =~ ^(PLAN|DEV|TEST|DONE|FINISH)$ ]]; then
          _ORPHAN_OWNER_ALIVE=2  # 강력 보호 마커 (활성 state 확인됨 — Phase B: OK 제거)
        fi
      fi
    fi
    if [[ $_ORPHAN_CLAIMED -eq 0 && $_ORPHAN_OWNER_ALIVE -eq 0 ]]; then
      # 진짜 고아 — 정리 후 통과
      rm -rf "$_ORPHAN_TEAM_DIR" 2>/dev/null
      rm -rf "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/tasks/${TEAM_NAME}" 2>/dev/null
      echo "🧹 [orphan teams 정리] ${TEAM_NAME} 고아 감지 — rm -rf 후 TeamCreate 통과 허용 (2026-04-22)" >&2
    fi
  fi
fi

# --- [P3-cache] 메모리-FS 불일치 감지 (2026-05-01 L-430) ---
# 목적: 자기 team_name 파일은 있지만 teams/<name>/ 디렉토리가 없는 경우
#       Claude 내부 레지스트리에 리더십이 남아있을 가능성이 높다 (in-process 캐시 한계).
#       이 경우 TeamCreate를 차단하고 TeamDelete → TeamCreate 복구 절차를 안내한다.
if [[ -f "$TEAM_NAME_FILE" ]]; then
  _MY_CACHED_TEAM=$(cat "$TEAM_NAME_FILE" 2>/dev/null | tr -d '\r\n')
  if [[ -n "$_MY_CACHED_TEAM" ]]; then
    _MY_CACHED_TEAM_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams/${_MY_CACHED_TEAM}"
    if [[ ! -d "$_MY_CACHED_TEAM_DIR" ]]; then
      # 메모리-FS 불일치 감지 — TeamCreate를 차단하고 복구 절차 안내
      source "${HARNESS_HOOK_DIR}/lib/write_error.sh" 2>/dev/null || true
      log_hook_error "HOOK_BLOCK_MEM_FS_MISMATCH" "TeamCreate" \
        "메모리-FS 불일치: team_name=[${_MY_CACHED_TEAM}] 파일 존재하나 teams/<>/ FS 부재 — Claude 메모리 레지스트리 잔존 가능" \
        "$SESSION_ID" 2>/dev/null || true
      echo "{\"decision\":\"block\",\"reason\":\"❌ [TeamCreate 차단 — 메모리-FS 불일치 L-430] 현재 세션 team_name=[${_MY_CACHED_TEAM}]이나 teams/${_MY_CACHED_TEAM}/ 디렉토리가 없습니다. Claude 메모리 레지스트리에 리더십이 남아있을 수 있습니다. 복구 시도: ① TeamDelete() 호출 → ② TeamCreate 재시도. ⚠️ TeamDelete가 'No team name found'를 반환하면 in-process 캐시 잔류 — 세션 재시작 필요 (cc-prefix 재생성으로 해소).\"}" | tee /dev/stderr
      exit 2
    fi
  fi
fi

# V5-b (C10): team_name 쓰기/삭제 경로 flock 추가 (L-362 동일 규칙)
#   목적: 병렬 TeamCreate 2건 race 시 team_name 불일치 및 stale rm 경합 제거
#   L-362: lock 안 I/O 수집 금지 — 파일 존재/내용 사전 수집은 lock 밖,
#         lock 안에서는 team_name 최종 상태(스냅샷) 확정 + stale 정리만 수행
mkdir -p "$SESSION_DIR" 2>/dev/null || true

# --- lock 밖: state 파일 읽기(조기 통과 판단 데이터만 수집) ---
# Phase B (L-431): state=OK 잔존 시 자동 PLAN 마이그레이션 (다른 활성 세션 호환 안전망)
source "${HARNESS_HOOK_DIR}/lib/state_machine.sh" 2>/dev/null
_smach_migrate_ok_to_plan "$STATE_FILE" "$UUID" 2>/dev/null || true
STATE=""
if [[ -f "$STATE_FILE" ]]; then
  # F6: state_read 경유. __LOCK_FAIL__ 시 현재 state 유지 (IDLE 강등 제거 — fail-closed).
  # IDLE 강등 금지: LOCK_FAIL 시 IDLE로 바꾸면 TeamCreate 이중 실행 허용 → "Already leading team" 오류 유발.
  STATE=$(state_read "$STATE_FILE" 2>/dev/null | awk '{print $1}' | tr -d '\r' || echo "")
  if [[ "$STATE" == "__LOCK_FAIL__" ]]; then
    echo "[team_create_guard] LOCK_FAIL 발생 — state 유지, TeamCreate 통과 허용 (현재 state 판별 불가)" >&2
  fi
fi
STATE=${STATE:-IDLE}

# IDLE 상태이거나 team_name 파일 자체 부재 → 통과
if [[ "$STATE" == "IDLE" ]] || [[ ! -f "$TEAM_NAME_FILE" ]]; then
  exit 0
fi

# --- lock 안: team_name 스냅샷 확정 + stale rm (원자적) ---
# 이 블록 안에서는 파일시스템 mutate 1회(rm)만 수행. 오류 출력/로그는 lock 밖에서.
#
# Phase A 재발방지 핵심 (L-431, 2026-05-06):
#   빈 _NAME 케이스 추가 — team_name 파일이 비어있는 경우 (/resume 후 잔존 등) STALE: 분기로 자동 처리.
#   이전 결함: -n 검사가 빈 _NAME일 때 false → else 분기로 → "LIVE:" (콜론 뒤 빈) 출력 →
#              EXISTING_TEAM="" → "unknown" 표기 + TeamCreate 차단.
EXISTING_TEAM=""
STALE_CLEANED=0
(
  flock -x -w 5 200 || exit 99
  if [[ -f "$TEAM_NAME_FILE" ]]; then
    _NAME=$(cat "$TEAM_NAME_FILE" 2>/dev/null | tr -d '\r\n')
    if [[ -z "$_NAME" ]]; then
      # Phase A 재발방지 핵심: 빈 team_name 파일 — 정리 후 STALE 처리 (LIVE: 빈 케이스 출력 차단)
      rm -f "$TEAM_NAME_FILE" 2>/dev/null
      echo "STALE:"
    elif [[ ! -d "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams/${_NAME}" ]]; then
      rm -f "$TEAM_NAME_FILE" 2>/dev/null
      echo "STALE:${_NAME}"
    else
      echo "LIVE:${_NAME}"
    fi
  else
    echo "NONE:"
  fi
) 200>"$TEAM_NAME_LOCK" > "${TEAM_NAME_FILE}.snap.$$" 2>/dev/null
_LOCK_RC=$?

if [[ $_LOCK_RC -eq 99 ]] || [[ ! -f "${TEAM_NAME_FILE}.snap.$$" ]]; then
  rm -f "${TEAM_NAME_FILE}.snap.$$" 2>/dev/null
  exit 0  # lock 획득 실패 → 안전하게 통과
fi

SNAP=$(cat "${TEAM_NAME_FILE}.snap.$$" 2>/dev/null || echo "NONE:")
rm -f "${TEAM_NAME_FILE}.snap.$$" 2>/dev/null

case "$SNAP" in
  NONE:*|STALE:*)
    exit 0  # team_name 없음 또는 stale 정리됨 → 통과
    ;;
  LIVE:*)
    EXISTING_TEAM="${SNAP#LIVE:}"
    ;;
esac

# Phase A 재발방지 보강 (L-431): 빈 EXISTING_TEAM 케이스 — SNAP 처리에서 정리되었어야 하나 누락된 경우
# 보수적으로 통과 (차단 메시지 "unknown" 표기 회피).
if [[ -z "$EXISTING_TEAM" ]]; then
  echo "[team_create_guard] WARN: LIVE: with empty team name — pre-cleanup miss, passing through (L-431 안전망)" >&2
  exit 0
fi

source "${HARNESS_HOOK_DIR}/lib/write_error.sh" 2>/dev/null
log_hook_error "HOOK_BLOCK_TEAM_DUPLICATE" "TeamCreate" "기존 리더 팀 잔류로 TeamCreate 차단: [${EXISTING_TEAM}] (state=${STATE}) → 요청 팀명: ${TEAM_NAME}" "$SESSION_ID"

echo "{\"decision\":\"block\",\"reason\":\"❌ [TeamCreate 차단] 이미 리딩 중인 팀이 있습니다: [${EXISTING_TEAM}] (state=${STATE}). TeamDelete → TeamCreate 재시도. ⚠️ 활성 파이프라인 중에는 TeamDelete 후 재시도해도 차단될 수 있음 — 그 경우 /oinit 또는 세션 재시작 필요. (L-052/L-431 재발방지)\"}" | tee /dev/stderr
exit 2
