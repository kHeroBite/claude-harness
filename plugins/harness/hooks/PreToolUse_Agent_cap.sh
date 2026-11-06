#!/bin/bash
# 팀에이전트 동시 생존 상한(F-AGENT-CAP)만 단독으로 판정하는 PreToolUse(Agent) 경량 hook — 메인 전용
#
# 배경(2026-10-11 실측): 상한 판정이 parallel_spawn_guard.sh 안에서 `time_budget.sh 2.5 open` 으로 돌아,
#   부하로 2.5s 를 넘기면 래퍼가 "판정 생략" exit 0 을 내 상한 초과 spawn 이 그대로 통과했다
#   (logs/hook_tb.log 10:38:18 mode=overrun). 상한은 판정 생략 시에도 확정돼야 한다.
# 조치: 이 hook 을 settings.json 에 `time_budget.sh 7.5 closed` 로 따로 등록한다.
#   예산 안 → agent_cap.py 의 판정(rc 0/2)을 그대로 낸다. 예산 초과 → 래퍼가 통과가 아니라 보류(exit 2 + 재시도 안내).
#   이 파일은 python 1회(/proc cmdline 판독)만 한다 — jq·source 없음.
# 구 경로 공존: parallel_spawn_guard.sh 의 상한 블록은 이 hook 이 등록되기 전에 시작한 세션용으로 남고,
#   이 파일을 AGENT_CAP_VIA_LEGACY=1 AGENT_CAP_WAIT_SEC=1.5 로 불러 위임한다(구 경로 판정 미완도 보류로 확정).
#   · 직접 호출(AGENT_CAP_VIA_LEGACY 미설정)될 때마다 자기 세션 logs/agent_cap_direct 표식을 남긴다
#     → 구 경로는 이 표식이 있으면(신 경로가 등록된 세션) 위임을 건너뛴다(중복 판정 방지).
#   · 위임 호출은 캐시 키에 legacy 를 섞어, 직접 hook 의 1회용 결과를 가로채지 않는다.
#   두 경로가 같은 spawn 을 동시에 판정해도 agent_cap.py 가 flock + 같은 이름 미기동 예약(allow_dup)으로 한 번만 센다.
# 세션 격리: agent_cap.py 가 자기 session_id 의 session-env 만 읽고 쓴다. 이 파일의 판정 캐시도 자기 세션 logs/ 아래만 쓴다.
#
# 판정 미완 = 보류 (역라우팅 #4 — 외부 리뷰 실증 결함 정정):
#   종전 `timeout 6 python3 … || rc=$?; [[ $rc -eq 2 ]] && exit 2; exit 0` 은 6초를 넘기면 rc=124 → exit 0(통과)였다.
#   래퍼(7.5 closed)보다 먼저 hook 이 통과를 내버려, 부하 시 상한 초과 spawn 이 통과했다.
#   이제 판정은 백그라운드 작업자가 끝까지 돌리고, hook 은 AGENT_CAP_WAIT_SEC(기본 5초, 래퍼 예산 7.5 안) 동안만 기다린다.
#     · 기다리는 동안 끝남        → 그 판정(rc 0/2 + 안내)을 그대로 낸다.
#     · 못 끝남(부하·중단·지연)   → exit 2 보류 + "2·4·8초 후 재시도" 안내. 작업자는 계속 돌아 결과를 캐시에 남긴다.
#     · 재시도                    → 같은 입력(tool_use_id 제외)의 캐시가 있으면 python 을 다시 돌리지 않고 즉시 확정한다.
#                                   진행 중 작업자가 있으면 새로 띄우지 않고 그 결과를 기다린다(중복 판정·잠금 경합 없음).
#   캐시: <session-env>/<sid>/logs/agent_cap_cache/<sha1>.res — 1회용, CACHE_FRESH_SEC(45초) 이내만 유효.
#     45초 < agent_cap.py 기본 예약 TTL(60초): 캐시로 허용된 spawn 의 예약이 아직 살아 있는 동안만 쓴다(이중 계산·과소 계산 방지).
#   작업자는 AGENT_CAP_WORKER_TIMEOUT(기본 60초) 뒤 강제 종료되고, 그 경우(rc 124·≥128 = 판정 미완)는 캐시하지 않는다
#     → 다음 재시도가 새로 판정한다. 영구 보류가 아니라 "판정이 끝날 때까지 보류"다.
#
# 판정 불가 = fail-open (계약 s10C §3-8 유지, 근거):
#   · python3 부재(`command -v` 는 셸 빌트인 해시 조회 — 부하와 무관하게 즉시 답한다. 부하로 python 이 느린 경우는
#     "부재"가 아니라 "미완"으로 위 보류 경로에 간다), lib 부재(파일 존재 판정 — 느려질 수는 있어도 거짓 부재를 내지 않는다).
#   · 입력 파손·session_id 불명·세션 디렉토리 부재 → agent_cap.py 가 rc 0(failopen 로그)으로 빠르게 답한다.
#   · python 비정상 종료(rc 1·126·127 등, 시그널·타임아웃 제외) → 0 으로 정규화(종전과 같음).
#   이들은 모두 "판정이 끝났는데 판정할 수 없는" 경우라 부하로 유발되지 않는다 — 상한 우회 통로가 아니다.

[[ -n "${PIPELINE_UUID:-}" ]] && exit 0   # 팀원 프로세스는 판정 대상이 아니다
command -v python3 >/dev/null 2>&1 || exit 0
LIB="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/agent_cap.py"
[[ -f "$LIB" ]] || LIB="${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/agent_cap.py"
[[ -f "$LIB" ]] || exit 0

_T0="${EPOCHREALTIME/./}"
CACHE_FRESH_SEC=45

# 대기 상한(µs) — 소수 허용, 잘못된 값은 5초
_W="${AGENT_CAP_WAIT_SEC:-5}"
[[ "$_W" =~ ^([0-9]+)(\.([0-9]{1,6}))?$ ]] || { _W=5; [[ "$_W" =~ ^([0-9]+)(\.([0-9]{1,6}))?$ ]]; }
_WF="${BASH_REMATCH[3]}000000"
_WAIT_US=$(( 10#${BASH_REMATCH[1]} * 1000000 + 10#${_WF:0:6} ))
_WTO="${AGENT_CAP_WORKER_TIMEOUT:-60}"
[[ "$_WTO" =~ ^[1-9][0-9]*$ ]] || _WTO=60

# stdin — 3s 안에 못 읽으면 읽은 만큼만 쓴다
_IN=""
IFS= read -r -d '' -t 3 _IN

_SID=""; _NAME=""
[[ "$_IN" =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([0-9a-f-]{36})\" ]] && _SID="${BASH_REMATCH[1]}"
[[ "$_IN" =~ \"name\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9._-]{1,64})\" ]] && _NAME="${BASH_REMATCH[1]}"
_SBASE="${AGENT_CAP_SESSION_BASE:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env}"
_LOGS=""
[[ -n "$_SID" && -d "$_SBASE/$_SID/logs" ]] && _LOGS="$_SBASE/$_SID/logs"
# 직접 호출 표식(빌트인 리다이렉트 — 포크 없음). 위임(구 경로) 호출은 남기지 않는다
if [[ -z "${AGENT_CAP_VIA_LEGACY:-}" && -n "$_LOGS" ]]; then : > "$_LOGS/agent_cap_direct" 2>/dev/null; fi

# 캐시 위치 — 자기 세션 logs/ 가 있으면 공유(재시도 즉시 확정), 없으면 이 호출 전용 임시 경로
_P=""; _SHARED=0
if [[ -n "$_LOGS" ]]; then
  _C="$_LOGS/agent_cap_cache"
  _S="$_IN"
  while [[ "$_S" =~ (\"tool_use_id\"[[:space:]]*:[[:space:]]*\"[^\"]*\") ]]; do
    _S="${_S/"${BASH_REMATCH[1]}"/}"
  done
  _K=""
  # 위임 호출은 키 앞에 legacy: 를 붙인다(직접 호출 키는 종전과 같음)
  read -r _K _ < <(printf '%s%s\0%s' "${AGENT_CAP_VIA_LEGACY:+legacy:}" "$_SID" "$_S" | sha1sum 2>/dev/null)
  if [[ "$_K" =~ ^[0-9a-f]{40}$ ]] && mkdir -p "$_C" 2>/dev/null; then
    _P="$_C/$_K"; _SHARED=1
  fi
fi
[[ -n "$_P" ]] || _P="${TMPDIR:-/tmp}/agent_cap.$$.${RANDOM}${RANDOM}"

_log() {  # $1=verdict $2=extra — 자기 세션 logs/agent_cap.log (agent_cap.py 와 같은 형식)
  [[ -n "$_LOGS" ]] || return 0
  local _ts
  printf -v _ts '%(%Y-%m-%dT%H:%M:%S%z)T' -1
  printf '%s|%s|live=-|pending=-|cap=-|name=%s|%s\n' "$_ts" "$1" "${_NAME:--}" "$2" >> "$_LOGS/agent_cap.log" 2>/dev/null
  return 0
}

# 결과 소비(1회용) — 성공 시 _RC 설정 + 안내 출력
_take() {
  local _u="$_P.use.$$" _m _now _rc=""
  [[ -d "$_P.res" ]] || return 1
  mv -T "$_P.res" "$_u" 2>/dev/null || return 1
  _m="$(stat -c %Y "$_u" 2>/dev/null)"; _now="${EPOCHREALTIME%.*}"
  [[ -r "$_u/rc" ]] && IFS= read -r _rc < "$_u/rc"
  if [[ "$_m" =~ ^[0-9]+$ ]] && (( _now - _m <= CACHE_FRESH_SEC )) && [[ "$_rc" == 0 || "$_rc" == 2 ]]; then
    [[ -s "$_u/err" ]] && cat "$_u/err" >&2
    rm -rf -- "$_u" 2>/dev/null
    _RC="$_rc"
    return 0
  fi
  rm -rf -- "$_u" 2>/dev/null   # 오래됐거나 손상 → 버리고 새로 판정
  return 1
}

# 작업자 기동 — 같은 키의 작업자가 살아 있으면 띄우지 않는다(mkdir 원자 선점)
_LAUNCHED=0
_launch() {
  local _r="$_P.run" _pid="" _m _now
  if ! mkdir "$_r" 2>/dev/null; then
    [[ -r "$_r/pid" ]] && IFS= read -r _pid < "$_r/pid"
    _m="$(stat -c %Y "$_r" 2>/dev/null)"; _now="${EPOCHREALTIME%.*}"
    if [[ "$_pid" =~ ^[0-9]+$ ]] && kill -0 "$_pid" 2>/dev/null && [[ "$_m" =~ ^[0-9]+$ ]] && (( _now - _m <= _WTO + 10 )); then
      return 0                                   # 진행 중 — 그 결과를 기다린다
    fi
    if [[ -z "$_pid" && "$_m" =~ ^[0-9]+$ ]] && (( _now - _m <= 5 )); then
      return 0                                   # 막 선점된 직후(pid 기록 전)
    fi
    rm -rf -- "$_r" 2>/dev/null                  # 죽은 작업자 잔재
    mkdir "$_r" 2>/dev/null || return 0
  fi
  if (( _SHARED )); then                         # 오래된 캐시 정리(자기 세션 캐시 디렉토리 안만)
    local _o _d
    _now="${EPOCHREALTIME%.*}"
    for _o in "$_C"/*.res "$_C"/*.tmp.* "$_C"/*.use.*; do
      [[ -e "$_o" ]] || continue
      _d="$(stat -c %Y "$_o" 2>/dev/null)"
      [[ "$_d" =~ ^[0-9]+$ ]] && (( _now - _d > 90 )) && rm -rf -- "$_o" 2>/dev/null
    done
  fi
  printf '%s' "$_IN" > "$_r/in" 2>/dev/null || { rm -rf -- "$_r" 2>/dev/null; return 1; }
  (
    _rc=0
    timeout -k 5 "$_WTO" python3 -I "$LIB" < "$_r/in" > /dev/null 2> "$_r/err" || _rc=$?
    if (( _rc == 124 || _rc == 125 || _rc >= 128 )); then
      :                                          # 판정 미완(타임아웃·시그널) — 캐시하지 않는다
    else
      (( _rc == 0 || _rc == 2 )) || _rc=0        # 판정 불가(비정상 종료) → fail-open
      _d="$_P.tmp.$BASHPID"
      if mkdir "$_d" 2>/dev/null; then
        printf '%s\n' "$_rc" > "$_d/rc"
        mv "$_r/err" "$_d/err" 2>/dev/null || : > "$_d/err"
        rm -rf -- "$_P.res" 2>/dev/null
        mv -T "$_d" "$_P.res" 2>/dev/null || rm -rf -- "$_d" 2>/dev/null
      fi
      if (( ! _SHARED )) && [[ -e "$_P.gone" ]]; then
        rm -rf -- "$_P.res" "$_P.gone" 2>/dev/null   # 전용 경로인데 호출자가 이미 떠났다
      fi
    fi
    rm -rf -- "$_r" 2>/dev/null
  ) < /dev/null > /dev/null 2>&1 &
  printf '%s\n' "$!" > "$_r/pid" 2>/dev/null
  _LAUNCHED=1
  return 0
}

_RC=""
_DEADLINE=$(( _T0 + _WAIT_US ))
_done() { (( _LAUNCHED )) || _log cache "rc=$_RC"; exit "$_RC"; }
while :; do
  _take && _done
  if [[ ! -d "$_P.run" ]]; then
    # 작업자는 결과(.res)를 먼저 남기고 .run 을 지운다 — .run 이 없으면 결과를 한 번 더 확인한 뒤에만 새로 띄운다(중복 판정 방지)
    _take && _done
    _launch || break
  fi
  (( ${EPOCHREALTIME/./} >= _DEADLINE )) && break
  sleep 0.05
done

# 판정 미완 — 통과가 아니라 보류
(( _SHARED )) || : > "$_P.gone" 2>/dev/null
if _take; then exit "$_RC"; fi                  # 마지막 순간에 끝났으면 그 판정
_ws="$(( _WAIT_US / 1000000 )).$(( (_WAIT_US % 1000000) / 100000 ))"
_log defer "wait=${_ws}s"
printf '🚦 [F-AGENT-CAP] 부하로 상한 판정 미완(%s초 안에 끝나지 않음) — spawn %s 을 이번 1회 보류합니다. 같은 spawn 호출을 2·4·8초 후 다시 보내십시오. 판정은 백그라운드에서 계속되며, 끝나면 다음 재시도는 즉시 확정됩니다.\n' \
  "$_ws" "'${_NAME:-?}'" >&2
exit 2
