#!/bin/bash
# Stop hook — STALE-OK 자동 IDLE 롤백 (재발방지)
# CLAUDE.md "재발방지 정책" 1순위 Hook 물리 차단

set -u

# session_id.sh 라이브러리 로드 (resolve_uuid 함수 등)
source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/session_id.sh" 2>/dev/null || exit 0
source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/state_machine.sh" 2>/dev/null || exit 0

# 사이클47 축① — 반대편 base 미러 (CLAUDE_CONFIG_DIR ↔ HOME 갈림 방지)
# 심링크 단일화(odev-1)가 1선 방어이나, 심링크 미적용 세션·CCD 미설정 환경에서는
# 이 미러가 유일한 정합 수단이다. source 실패 시 no-op 스텁으로 fail-soft.
source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/session_mirror.sh" 2>/dev/null
declare -F _mirror_file >/dev/null 2>&1 || _mirror_file() { :; }

# stdin에서 JSON 읽고 session_id 추출 (실패 시 silent skip)
INPUT=$(cat 2>/dev/null)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
[ -z "$SESSION_ID" ] && exit 0
# peer 통지 주기 pull-all 을 백그라운드로 기동한다(입력 없이도 수신, 실패해도 세션을 막지 않음)
bash "$(dirname "${BASH_SOURCE[0]}")/lib/peer_autopull.sh" "${CLAUDE_PROJECT_DIR:-$(echo "$INPUT" | jq -r '.cwd // "-"' 2>/dev/null)}" >/dev/null 2>&1 </dev/null || true

UUID="$SESSION_ID"
# 사이클47 — $HOME 단독 하드코딩 제거 (계획 §1-3).
# 종전 "$HOME/.claude/..." 단독 기준이라 CLAUDE_CONFIG_DIR 세션에서 HOME 쪽에만 쓰였다.
SESSION_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}"
STATE_FILE="${SESSION_DIR}/state"
EVIDENCE_DIR="${SESSION_DIR}/evidence"
LOG_FILE="${SESSION_DIR}/logs/stop_hook.log"

# ★회귀 방지★ — 전개형 base 에 디렉토리가 없고 HOME 쪽에만 있으면 HOME 으로 폴백한다.
# 이 분기가 없으면 CLAUDE_CONFIG_DIR 설정 + 심링크 미적용 세션에서 아래 `-d` 검사가
# 실패해 STALE-OK 롤백이 통째로 죽는다(조용한 기능 정지). 의도적 양쪽 검사이므로
# 여기의 "$HOME" 하드코딩은 그대로 둔다.
if [ ! -d "$SESSION_DIR" ] && [ -d "$HOME/.claude/session-env/${UUID}" ]; then
  SESSION_DIR="$HOME/.claude/session-env/${UUID}"
  STATE_FILE="${SESSION_DIR}/state"
  EVIDENCE_DIR="${SESSION_DIR}/evidence"
  LOG_FILE="${SESSION_DIR}/logs/stop_hook.log"
fi

# 디렉토리 부재 시 silent skip
[ -d "$SESSION_DIR" ] || exit 0
mkdir -p "${SESSION_DIR}/logs" 2>/dev/null

# 디바운스: stop_last mtime 2초 이내면 skip (무한 루프 방지)
STOP_LAST="${EVIDENCE_DIR}/stop_last"
NOW=$(date +%s)
if [ -f "$STOP_LAST" ]; then
  LAST_MTIME=$(stat -c %Y "$STOP_LAST" 2>/dev/null || echo 0)
  AGE=$((NOW - LAST_MTIME))
  if [ "$AGE" -lt 2 ]; then
    exit 0  # 디바운스 — 너무 빠른 재발동 차단
  fi
fi
mkdir -p "$EVIDENCE_DIR" 2>/dev/null
date +%s > "$STOP_LAST"
_mirror_file "$STOP_LAST"

# state 읽기
STATE=$(state_read "$STATE_FILE" 2>/dev/null | awk '{print $1}')
[ -z "$STATE" ] && exit 0

# Phase B (L-431): STALE 회수 대상 = state=PLAN AND classification=OK
# 이유: stage OK 제거 + level OK 추가 — ok 진입 직후 단계가 stage=PLAN + classification=OK로 표현됨
CLASSIFICATION=$(cat "${SESSION_DIR}/classification" 2>/dev/null | tr -d '\r\n' || echo "")
if [ "$STATE" != "PLAN" ] || [ "$CLASSIFICATION" != "OK" ]; then
  exit 0
fi

# D5 — 재개 세션은 표식이 두 base 에 갈려 있을 수 있어 아래 가드는 전부 두 base 를 본다.
# 의도적 양쪽 검사이므로 "$HOME" 하드코딩은 그대로 둔다. 두 경로가 같으면 같은 파일을 두 번 볼 뿐이다.
_STOP_BASES=("$SESSION_DIR" "$HOME/.claude/session-env/${UUID}")

# 가드0: state 가 최근에 바뀌었으면 진입 직후다. 표식이 아직 없어도 stale 이 아니다.
STATE_MTIME=0
for _b in "${_STOP_BASES[@]}"; do
  _t=$(stat -c %Y "${_b}/state" 2>/dev/null || echo 0)
  [ "$_t" -gt "$STATE_MTIME" ] && STATE_MTIME="$_t"
done
STATE_AGE=$((NOW - STATE_MTIME))
if [ "$STATE_AGE" -lt 300 ]; then
  echo "[$(date +%Y-%m-%dT%H:%M:%S)] STALE-OK skip guard0=fresh age=${STATE_AGE} (UUID=${UUID})" >> "$LOG_FILE"
  _mirror_file "$LOG_FILE"
  exit 0
fi
# 롤백은 10분 경과 후에만 한다. 300~600초 구간은 판정을 미룬다.
if [ "$STATE_AGE" -lt 600 ]; then
  echo "[$(date +%Y-%m-%dT%H:%M:%S)] STALE-OK skip guard0=pending age=${STATE_AGE} (UUID=${UUID})" >> "$LOG_FILE"
  _mirror_file "$LOG_FILE"
  exit 0
fi

# 가드1~5 (state=PLAN AND classification=OK인 경우, 두 base 중 어느 쪽이든 해당하면 skip):
# 가드1·2·4: ok_started·team_name·pipeline_start_time 은 존재가 아니라 시점으로 본다. state mtime 이후에 생긴 것만 인정한다.
#   ofinish 가 지우지 않거나 한쪽 base 에만 남은 옛 표식이 진짜 stale 을 영구 면제하지 않게 하기 위해서다.
# 가드3: heartbeat 5초 이내 갱신 → 활성 처리 중
# 가드5: plan_entry_mark(Skill 진입 표식, pea_stamp·phase_guard 가 찍는다). ok SKILL 의 session_state PLAN 자기전이는
#   state mtime 만 밀어 가드1·2·4 가 모두 실패하므로, 이번 사이클에 Skill 로 진입한 세션은 이 표식으로 보호한다.
#   직전 사이클 표식은 ofinish 표식보다 오래된 것으로 거른다. 슬래시 선기록 줄(teamcreate_force_)이 남아 있으면 Skill 이
#   state 를 다시 쓰지 않으므로 state mtime 이후 표식만 인정한다.
#   ofinish 없이 끊긴 사이클은 ofinish 표식으로 걸러지지 않으므로, 표식이 _MARK_MAX_AGE 를 넘으면 인정하지 않는다.
_MARK_MAX_AGE=21600
_FIN_T=0
for _b in "${_STOP_BASES[@]}"; do
  for _f in evidence/ofinish_done evidence/ofinish_cleanup_done; do
    [ -f "${_b}/${_f}" ] || continue
    _t=$(stat -c %Y "${_b}/${_f}" 2>/dev/null || echo 0)
    [ "$_t" -gt "$_FIN_T" ] && _FIN_T="$_t"
  done
done
_STATE_LINE=$(head -n1 "$STATE_FILE" 2>/dev/null)
for _b in "${_STOP_BASES[@]}"; do
  for _f in evidence/ok_started team_name pipeline_start_time; do
    [ -f "${_b}/${_f}" ] || continue
    _t=$(stat -c %Y "${_b}/${_f}" 2>/dev/null || echo 0)
    [ "$_t" -ge "$STATE_MTIME" ] && exit 0
  done
  if [ -f "${_b}/plan_entry_mark" ]; then
    _t=$(stat -c %Y "${_b}/plan_entry_mark" 2>/dev/null || echo 0)
    if [ "$_t" -ge "$_FIN_T" ] && [ $((NOW - _t)) -lt "$_MARK_MAX_AGE" ]; then
      case " $_STATE_LINE " in
        *" teamcreate_force_"*) [ "$_t" -ge "$STATE_MTIME" ] && exit 0 ;;
        *) exit 0 ;;
      esac
    fi
  fi
  if [ -f "${_b}/heartbeat" ]; then
    HB_MTIME=$(stat -c %Y "${_b}/heartbeat" 2>/dev/null || echo 0)
    HB_AGE=$((NOW - HB_MTIME))
    if [ "$HB_AGE" -lt 5 ]; then
      exit 0  # 활성 — 잠시 멈춤일 수 있음
    fi
  fi
done

# 모든 가드 실패 → STALE-OK 판정 → IDLE 롤백. 어떤 가드를 봤는지 로그에 남긴다.
echo "[$(date +%Y-%m-%dT%H:%M:%S)] STALE-OK 감지 (PLAN+classification=OK, state_age=${STATE_AGE}) → IDLE 롤백 (UUID=${UUID}) 가드실패=ok_started,team_name,heartbeat,pipeline_start_time,plan_entry_mark" >> "$LOG_FILE"

# state_transition CAS — PLAN → IDLE 전이 (Phase B: stage OK 제거됨)
state_transition "$STATE_FILE" "PLAN" "IDLE" "stop_hook_stale_pre_ok_rollback" "$UUID" 2>>"$LOG_FILE" || true

# 로그 미러 — state 자체는 state_machine.sh 헬퍼가 자체 미러하므로 여기서 다루지 않는다.
_mirror_file "$LOG_FILE"

exit 0
