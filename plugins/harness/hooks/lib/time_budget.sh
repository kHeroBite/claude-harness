#!/usr/bin/env bash
# hook 을 시간 예산 안에서 실행하고, 예산 초과 시 정책(closed/closed_mut/open)대로 끝내는 공용 래퍼
#
# 사용법: time_budget.sh <budget_sec> <closed|closed_mut|closed_ro|open> <script_abs_path> [script_args...]
#   settings.json 예: "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/time_budget.sh 7.5 closed ${HARNESS_HOME:-$HOME/.harness}/current/hooks/write_guard.sh"
#
# 정책 (계획 conv_179160362523 §4·§5)
#   closed     : 예산 초과 → stderr 보류 안내 + exit 2 (보류). 예산 내 rc∉{0,2} → 0 정규화.
#   closed_mut : 읽기 전용 도구(READ_ONLY)면 open, 그 밖의 도구면 closed.
#   closed_ro  : closed 와 같다. 단 ★예산 초과 때만★, 호출이 엄격한 읽기 전용(_tb_ro_call)이면 보류하지 않고
#                additionalContext 안내 + exit 0 (로그 mode=overrun_ro_pass). 예산 안에서는 본문 판정을 그대로 쓴다.
#                읽기 전용 = READ_ONLY 도구, 또는 mcp__oio__bash_exec 중 아래를 모두 만족하는 것(하나라도 불확실하면 closed):
#                  · tool_input 이 중괄호 없는 평면 객체 1개, 이스케이프(\) 없음, 키는 command(정확히 1)·cwd·working_dir·
#                    workdir·timeout_ms·timeout·run_in_background(false) 뿐 — env·cmd 별칭·중첩 객체는 거부
#                  · command 400자 이하, 허용 문자 [A-Za-z0-9 _./:=,+@%|~-] 와 단독 토큰 2>/dev/null·2>&1 뿐
#                    (; & || && 체인·리다이렉션·tee·$()·백틱·따옴표·글롭·개행 전부 거부)
#                    [사이클206 D-7] 예외 1개: date 의 형식 인자 '+…'(내용 [A-Za-z0-9 _./:=,+@%-] 만, 짝 맞는 작은따옴표).
#                    예: date '+%Y-%m-%d %H:%M:%S %Z'. 다른 명령의 따옴표·'-s…'·그 밖 글자는 종전대로 거부.
#                  · 단일 | 로 나눈 각 구간의 첫 단어가 date ls cat head tail wc grep rg find stat pwd git
#                    uptime nproc whoami(인자 무관) hostname(인자 없을 때만)
#                    (git 은 log|status|show|diff|rev-parse 만), 실행·쓰기형 옵션(find -delete/-exec…/-fprint…,
#                    rg --pre/--hidden/-u/--no-ignore/-L, grep -r, git -c/-C/--output/--ext-diff/--textconv…, date -s) 거부
#                  · command·cwd 에 민감 경로 부분문자열(credential·secret·token·.ssh·.env·settings.json·session-env·
#                    guard_promote·backup/·/proc/·/mnt/ 등) 없음 — /mnt/ 는 write_guard 의 메인 NTFS 탐색 차단을 보존한다
#   잔여 한계: 상대경로는 oio 가 유지하는 이전 작업 디렉터리 기준으로 풀리므로 민감 디렉터리 안의 민감하지 않은 이름은
#              잡지 못한다(쓰기·실행은 불가). 같은 uid 의 의도적 조작(PATH·git 설정 선변조)은 막지 못한다(기존 한계와 같다).
#   open       : 예산 초과 → (PreToolUse/PostToolUse/UserPromptSubmit/SessionStart) additionalContext 안내 + exit 0,
#                Stop/SubagentStop/TeammateIdle 등은 무출력 exit 0. 예산 내 rc 는 그대로.
#   예산 초과 시에도 본문은 kill 하지 않는다(상태 기록 보존). 늦은 출력은 자기 세션 logs/ 에 남긴다.
#
# 부하 적응 예산 (계획 conv_179163042411 §4-1)
#   L = max(cpu some avg10/50, io some avg10/50, loadavg1/nproc − 1) 을 0~1 로 자른다(판독 실패 시 0 = 종전 동작).
#   실효 예산 = B + min(1.5, 0.2·B)·L  → 7.5→최대 9.0(timeout 10), 2.5→최대 3.0(timeout 5). 정수 마이크로초 산술(포크 0).
#
# 늦은 판정 캐시 (closed 실효 정책만)
#   초과 후 백그라운드에서 끝난 판정을 자기 세션 logs/tb_cache/<key>.res 에 남긴다.
#   같은 입력(tool_use_id 제외)·같은 state mtime 의 재시도는 본문을 다시 돌리지 않고 그 판정(rc·출력)을 그대로 쓴다.
#   90초 이내·1회용. 판정 도중 state 가 바뀌었으면 남기지 않는다. 키 계산은 캐시가 있을 때와 늦은 종료 경로에서만 한다.
#
# 고부하 보류 (사이클212 건2, L-732) — L ≥ TB_HOLD_L(기본 500‰) 이고 이벤트=PreToolUse, hook 이름에 guard 포함,
#   읽기 전용 도구·엄격 읽기 전용 bash(_tb_ro_call) 아님 → "판정 hook 의 변경성 호출"만 대상이다. 나머지는 종전 그대로.
#   ① 유예: 초과 시 즉시 포기하지 않고 min(하네스 timeout − 경과 − 0.5초, 1.5초) 더 기다려 끝나면 그 판정을 쓴다(생략 0).
#      하네스 timeout 은 예산 ≤5초면 5, 그 밖은 10으로 본다(TB_HARNESS_TIMEOUT 으로 덮어쓰기 — 시험용).
#   ② open 정책 대상이 유예 후에도 안 끝나면 생략하지 않고 보류(exit 2, 문구는 8-0 절). 본문은 계속 돌고 통과(rc=0)면 캐시 →
#      재시도는 즉시 통과. 차단(rc=2)은 캐시하지 않는다. closed 정책은 유예만 받고 종전 보류를 따른다.
#   ③ 같은 입력(캐시 키)이 연속 TB_HOLD_MAX(기본 6)회 보류되면 7번째에 판정 생략 통과 + 로그 mode=overrun_hold_escape
#      (자기 세션 logs/tb_cache/<key>.hold 카운터 "횟수 epoch", 180초 지나면 0부터). 키·캐시 디렉터리를 못 만들면 종전 생략 통과.
#   UserPromptSubmit 은 exit 2 가 사용자 입력 자체를 버리므로 보류하지 않는다(종전 생략 통과).
#
# 보류 메시지 (conv_179214064727 §2-3): 첫 줄 고정 "⏱️ [time_budget] 차단 주체=time_budget(시간 예산 초과) / 대상 hook=<이름> /
#   원인=시스템 정체(<ms>ms, load=<‰>) / 조치=…" — 하네스가 붙이는 "[…time_budget.sh 7.5 closed …/write_guard.sh]: " 접두 때문에
#   대상 hook 이 차단한 것으로 오인되던 문제를 막는다. 그때까지 본문이 낸 stderr 는 "[참고: <hook> 출력 — 차단 원인 아님]" 줄로 분리한다.
#   ★한계★: 하네스 hook timeout(write_guard 10초)이 래퍼보다 먼저 끝나면(실효 예산 최대 9.0초 — 여유 1초) 래퍼는 아무 문구도
#   낼 수 없고 하네스의 "timed out; blocking because onFailure is block" 만 보인다. 이 경우는 이 파일로 고칠 수 없다.
#   (사이클206: 기동→진입 지연분은 1-0 기준 시각으로 해소했다. 남는 것은 fork 이전 하네스 큐잉 지연뿐 — settings timeout 여유 몫)
#
# 비용 원칙: 정체 구간에서 돈다 — source·jq·python 금지. 포크는 입력 수신(timeout+cat) 1 + 본문 1 + 타이머 1(+sleep) + 정상 출력 cat.
# ★본문·타이머의 stdout/stderr 는 hook 파이프를 물지 않게 전부 파일·/dev/null 로 보낸다★
#   (물면 Claude Code 가 EOF 를 기다려 예산이 무의미해진다).
#
#
# LKG(마지막 정상본) 대체 실행 — F-HOOK-LKG (사이클182, 2026-10-12 01:07 write_guard 교착 사고 재발방지)
#   bash 구문 오류는 rc=2 로 끝나고, Claude Code 는 PreToolUse rc=2 를 '차단'으로 읽는다.
#   그래서 부분 편집으로 깨진 hook 은 자기를 고치는 편집까지 막는다(탈출구 없음).
#   ① 평상시: 대상 mtime == 스탬프 mtime 이면 검증된 판으로 보고 그대로 실행한다(빌트인 -nt 비교, 포크 0).
#   ② 스탬프 불일치: bash -n 1회. 통과하면 그대로 실행하고, 예산 안에서 rc∈{0,2} 로 끝나면 백그라운드에서 LKG 를 갱신한다.
#   ③ bash -n 실패: LKG 가 있고 sha·경로·소유·비링크·bash -n 이 모두 맞으면 LKG 로 대신 판정한다(stderr 1회 경고 + 로그).
#      LKG 가 없거나 하나라도 어긋나면 지금처럼 차단한다(closed → 사유 출력 + exit 2, open → 원본을 그대로 실행).
#   LKG 사본 = 대상과 같은 실제 디렉터리의 .<이름>.lkg.<sha12> (lib 를 dirname(BASH_SOURCE) 로 찾는 hook 이 있어 같은 위치여야 한다)
#   메타·스탬프·로그 = ${TB_LKG_DIR:-$HOME/.local/state/hook_lkg}/ (700, 링크 금지). 메타 1행 sha256, 2행 사본 경로.
#
# 테스트용 환경변수: TB_TMPDIR(임시 디렉토리, 기본 /tmp), TB_PSI_DIR(기본 /proc/pressure),
#                    TB_LOADAVG_FILE(기본 /proc/loadavg), TB_NPROC(기본 /sys/devices/system/cpu/online 파싱, 실패 시 4),
#                    TB_LKG_DIR(LKG 메타 저장소, 기본 $HOME/.local/state/hook_lkg),
#                    TB_START_EPOCH_US(hook 기동 epoch µs 주입 — 1-0 절, 미래 값 무시)
#
# 기준 시각 (사이클206 F-1(a)): 예산은 래퍼 진입이 아니라 hook 프로세스 기동 시각부터 잰다(1-0 절). 로그 lag= 는 기동→진입 지연(ms).

if (( $# < 3 )); then
  printf '⏱️ [time_budget] 사용법 오류: time_budget.sh <budget_sec> <closed|closed_mut|closed_ro|open> <script> [args...]\n' >&2
  exit 1
fi

_TB_B="$1"; _TB_POL="$2"; _TB_SCRIPT="$3"; shift 3

# 1. 잘못된 인자 → 원본을 그대로 실행 (래퍼가 판정을 망가뜨리지 않는다)
if [[ ! "$_TB_B" =~ ^[0-9]+(\.[0-9]+)?$ ]] || [[ "$_TB_POL" != closed && "$_TB_POL" != closed_mut && "$_TB_POL" != closed_ro && "$_TB_POL" != open ]]; then
  printf '⏱️ [time_budget] 인자 오류(budget=%s policy=%s) — 예산 없이 원본을 실행합니다.\n' "$_TB_B" "$_TB_POL" >&2
  exec "$_TB_SCRIPT" "$@"
fi

_TB_NAME="${_TB_SCRIPT##*/}"
_TB_T0="${EPOCHREALTIME/./}"   # 마이크로초 정수 — 아래 1-0 에서 hook 프로세스 기동 시각으로 앞당긴다
_TB_LAG=0                      # 기동 → 래퍼 진입 지연(ms). 로그 lag= 필드

# 1-0. [사이클206 F-1(a)] 기준 시각 = hook 프로세스 기동 시각 (포크 0 — 빌트인 read 만)
#   하네스 timeout 은 프로세스 기동부터 재는데 래퍼는 자기 진입 시각부터 재서, 정체 구간 기동 지연(실측 약 5.5초)만큼
#   하네스가 먼저 끊었다("timed out; blocking because onFailure is block" — 래퍼 안내 문구 없음).
#   기동 경과 = /proc/uptime(1/100초) − /proc/<pid>/stat 22번째 필드 starttime(USER_HZ=100 틱). 둘 다 부팅 기준 시계라
#   btime(정수 초, 최대 1초 오차) 없이 1/100초 정밀도로 잰다. 부모가 `sh|dash|bash -c '<…>/time_budget.sh …'` 이면
#   (exec 최적화가 없는 셸) 부모 기동 시각을 쓴다. 판독 실패·30초 초과(비정상 판독)는 종전대로 현재 시각.
#   시험 전용 TB_START_EPOCH_US(기동 epoch µs) — 현재보다 미래 값은 무시한다(예산을 늘리는 방향은 받지 않는다).
#   한계: 하네스가 프로세스를 띄우기 전(fork 이전)의 큐잉 지연은 잴 수 없다 — settings timeout 여유로 덮는다(F-1(b)).
_tb_stat_start() {  # $1=pid → _TB_ST (starttime 틱, 실패 시 빈값)
  local _l="" _r
  local -a _f
  _TB_ST=""
  [[ -r "/proc/$1/stat" ]] && IFS= read -r _l < "/proc/$1/stat" 2>/dev/null
  [[ "$_l" == *") "* ]] || return 1
  _r="${_l##*) }"                       # comm 에 공백·괄호가 있어도 마지막 ") " 뒤부터 센다(3번째 필드 state 부터)
  read -r -a _f <<< "$_r"
  [[ "${_f[19]:-}" =~ ^[0-9]+$ ]] || return 1
  _TB_ST="${_f[19]}"
}
_tb_start_t0() {
  local _now="${EPOCHREALTIME/./}" _up="" _x _st="" _pst _comm _l _a _i=0 _lag
  local -a _av
  if [[ -n "${TB_START_EPOCH_US:-}" ]]; then
    [[ "$TB_START_EPOCH_US" =~ ^[0-9]{1,18}$ ]] || return 0
    (( 10#$TB_START_EPOCH_US <= _now )) || return 0          # 미래 값 무시
    _lag=$(( _now - 10#$TB_START_EPOCH_US ))
  else
    _tb_stat_start "$$" || return 0
    _st="$_TB_ST"
    # 부모가 이 래퍼를 띄운 -c 셸이면 부모 기동 시각(더 이른 쪽)
    if [[ -r "/proc/$PPID/stat" ]]; then
      _l=""; IFS= read -r _l < "/proc/$PPID/stat" 2>/dev/null
      _comm="${_l#*(}"; _comm="${_comm%)*}"
      if [[ "$_comm" == sh || "$_comm" == dash || "$_comm" == bash ]]; then
        _av=()
        while IFS= read -r -d '' _a && (( _i < 4 )); do _av+=("$_a"); _i=$(( _i + 1 )); done < "/proc/$PPID/cmdline" 2>/dev/null
        _a="${_av[2]:-}"; _a="${_a#"${_a%%[![:space:]]*}"}"; _a="${_a%%[[:space:]]*}"
        if [[ "${_av[1]:-}" == -c && "$_a" == */time_budget.sh ]] && _tb_stat_start "$PPID" && (( _TB_ST < _st )); then
          _pst="$_TB_ST"; _st="$_pst"
        fi
      fi
    fi
    [[ -r /proc/uptime ]] && IFS=' ' read -r _up _x < /proc/uptime 2>/dev/null
    _tb_hund "$_up" || return 0
    _lag=$(( (_TB_HV - 10#$_st) * 10000 ))                     # 1/100초 → µs
  fi
  (( _lag < 0 )) && _lag=0
  (( _lag > 30000000 )) && return 0                              # 30초 초과는 판독 이상으로 보고 종전 동작
  _TB_T0=$(( _now - _lag ))
  _TB_LAG=$(( _lag / 1000 ))
  return 0
}

# 1-1. 부하 적응 예산 — bash 빌트인 read·정규식만 쓴다(포크 0)
_tb_hund() {  # "12.34" → 1234 (소수 둘째 자리까지, 실패 시 빈값)
  [[ "$1" =~ ^([0-9]+)(\.([0-9]*))?$ ]] || return 1
  local _f="${BASH_REMATCH[3]}00"
  _TB_HV=$(( 10#${BASH_REMATCH[1]} * 100 + 10#${_f:0:2} ))
}
_tb_load_milli() {  # → _TB_L (0~1000)
  local _l _x _d="${TB_PSI_DIR:-/proc/pressure}" _n _a _b _seg
  _TB_L=0
  for _x in cpu io; do
    _l=""
    [[ -r "$_d/$_x" ]] && IFS= read -r _l < "$_d/$_x" 2>/dev/null
    if [[ "$_l" =~ ^some[[:space:]].*avg10=([0-9.]+) ]] && _tb_hund "${BASH_REMATCH[1]}"; then
      _l=$(( _TB_HV / 5 ))                       # (pct/50)·1000 = hund/5
      (( _l > _TB_L )) && _TB_L=$_l
    fi
  done
  _n="${TB_NPROC:-}"
  if [[ ! "$_n" =~ ^[1-9][0-9]*$ ]]; then
    _n=0; _l=""
    [[ -r /sys/devices/system/cpu/online ]] && IFS= read -r _l < /sys/devices/system/cpu/online 2>/dev/null
    local IFS=,
    for _seg in $_l; do
      if [[ "$_seg" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        _a=$(( 10#${BASH_REMATCH[1]} )); _b=$(( 10#${BASH_REMATCH[2]} ))
        (( _b >= _a )) && _n=$(( _n + _b - _a + 1 ))
      elif [[ "$_seg" =~ ^[0-9]+$ ]]; then
        _n=$(( _n + 1 ))
      fi
    done
    unset IFS
    (( _n > 0 )) || _n=4
  fi
  _l=""
  [[ -r "${TB_LOADAVG_FILE:-/proc/loadavg}" ]] && IFS=' ' read -r _l _x < "${TB_LOADAVG_FILE:-/proc/loadavg}" 2>/dev/null
  if [[ -n "$_l" ]] && _tb_hund "$_l"; then
    _l=$(( _TB_HV * 10 / _n - 1000 ))            # (load/nproc − 1)·1000
    (( _l > _TB_L )) && _TB_L=$_l
  fi
  (( _TB_L < 0 )) && _TB_L=0
  (( _TB_L > 1000 )) && _TB_L=1000
  return 0
}
_TB_L=0; _TB_HV=0
_tb_start_t0
_tb_load_milli
_TB_BI="${_TB_B%%.*}"; _TB_BF=""
[[ "$_TB_B" == *.* ]] && _TB_BF="${_TB_B#*.}"
_TB_BF="${_TB_BF}000000"
_TB_BUS=$(( 10#$_TB_BI * 1000000 + 10#${_TB_BF:0:6} ))      # 기본 예산(µs)
_TB_XUS=$(( _TB_BUS / 5 )); (( _TB_XUS > 1500000 )) && _TB_XUS=1500000
_TB_EUS=$(( _TB_BUS + _TB_XUS * _TB_L / 1000 ))               # 실효 예산(µs)
printf -v _TB_E '%d.%06d' $(( _TB_EUS / 1000000 )) $(( _TB_EUS % 1000000 ))
printf -v _TB_ES '%d.%d' $(( _TB_EUS / 1000000 )) $(( (_TB_EUS % 1000000) / 100000 ))   # 안내용 0.1초 단위

# 2. stdin — 임시 파일로 바로 받는다(cat 1회). 3s 안에 EOF 가 안 오면 받은 만큼만 쓴다.
#   [사이클182] 빌트인 read 는 파이프를 1바이트씩 읽어 200KB 에 0.8s, 약 760KB 를 넘으면 3s 제한에 걸려 입력이 잘렸다
#   (큰 file_write 내용·PostToolUse 응답). 파일로 받은 뒤 앞 256KB 만 변수로 읽는다(정규 파일은 버퍼 읽기라 빠르다).
#   변수(_TB_IN)는 필드 추출·캐시 키 용도이고, 본문에는 항상 파일 전체를 넘긴다. 256KB 를 넘으면 늦은 판정 캐시를 쓰지 않는다.
_TB_TMP="${TB_TMPDIR:-/tmp}"
_TB_T="${_TB_TMP}/hook_tb.$$.${RANDOM}${RANDOM}"
_TB_IN=""; _TB_INF=0; _TB_BIG=0; _TB_INRC=0
if : > "$_TB_T.in" 2>/dev/null; then
  timeout 3 cat > "$_TB_T.in" 2>/dev/null
  _TB_INRC=$?                         # [사이클182 반복1 A1] 0 = EOF 까지 받음, 124 등 = 입력 미완
  _TB_INF=1
  IFS= read -r -d '' -N 262145 _TB_IN < "$_TB_T.in"
  (( ${#_TB_IN} > 262144 )) && _TB_BIG=1
else
  IFS= read -r -d '' -t 3 _TB_IN
  _TB_INRC=$?; (( _TB_INRC > 128 )) || _TB_INRC=0   # read -d '' 는 EOF 에서 1(정상), 시간 초과는 >128
fi

# 3. 빌트인 정규식으로 필드 추출
_TB_TOOL=""; _TB_EVT=""; _TB_SID=""
[[ "$_TB_IN" =~ \"tool_name\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]] && _TB_TOOL="${BASH_REMATCH[1]}"
[[ "$_TB_IN" =~ \"hook_event_name\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]] && _TB_EVT="${BASH_REMATCH[1]}"
[[ "$_TB_IN" =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]] && _TB_SID="${BASH_REMATCH[1]}"

# 세션 격리 — 형식이 UUID 인 자기 세션 디렉토리의 logs/ 가 이미 있을 때만 기록한다(없으면 생략).
_TB_LOGDIR=""; _TB_STATEF=""
if [[ "$_TB_SID" =~ ^[0-9a-f-]{36}$ ]]; then
  _TB_D="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${_TB_SID}/logs"
  if [[ -d "$_TB_D" ]]; then
    _TB_LOGDIR="$_TB_D"
    _TB_STATEF="${_TB_D%/logs}/state"
  fi
fi
_TB_CACHE=""
[[ -n "$_TB_LOGDIR" ]] && _TB_CACHE="${_TB_LOGDIR}/tb_cache"

_tb_log() {  # $1=mode $2=rc
  [[ -n "$_TB_LOGDIR" ]] || return 0
  local _ts _ms=$(( (${EPOCHREALTIME/./} - _TB_T0) / 1000 ))
  printf -v _ts '%(%Y-%m-%dT%H:%M:%S%z)T' -1
  printf '%s hook=%s policy=%s budget=%s mode=%s rc=%s ms=%s eff=%s load=%s lag=%s\n' \
    "$_ts" "$_TB_NAME" "$_TB_POL" "$_TB_B" "$1" "$2" "$_ms" "$_TB_E" "$_TB_L" "$_TB_LAG" >> "$_TB_LOGDIR/hook_tb.log" 2>/dev/null
  return 0
}

# [사이클216] 차단 사유 노출 — 본문이 rc=2 로 끝났는데 사유를 stdout JSON 에만 냈으면 그 사유를 stderr 에도 낸다.
#   Claude Code 는 exit 2 에서 stdout JSON 이 스키마 검증을 통과하면 그 reason 을, 통과하지 못하면 stderr 를 차단 사유로 쓴다
#   (출처: https://code.claude.com/docs/en/hooks "Exit code 2"). 이스케이프 안 된 따옴표 등으로 JSON 이 깨지면 stderr 가 비어
#   화면에 "[…time_budget.sh 7.5 closed_ro …write_guard.sh]: No stderr output" 만 보였다(write_guard F-DESTROY-1 실측, Claude Code 2.1.311).
#   reason 키가 있으면 그 값(마지막 "} 까지 탐욕 매칭 — 깨진 JSON 도 중간에서 잘리지 않게), 없으면 stdout 원문. 4000자 상한.
#   본문 stderr 가 이미 비어 있지 않으면 내지 않는다(본문 stderr 보존). 비용 원칙대로 빌트인 read·정규식만 쓴다(포크 0).
_tb_reason_to_err() {  # $1=본문 stdout 파일 $2=본문 stderr 파일
  local _o="" _e="" _r _re
  IFS= read -r -d '' -N 65536 _o < "$1" 2>/dev/null
  [[ -n "${_o//[[:space:]]/}" ]] || return 0
  _re='"reason"[[:space:]]*:[[:space:]]*"(.*)"[[:space:]]*\}'
  if [[ "$_o" =~ $_re ]]; then
    _r="${BASH_REMATCH[1]}"; _r="${_r//\\\"/\"}"; _r="${_r//\\n/$'\n'}"
  else
    _r="$_o"
  fi
  while [[ "$_r" == *$'\n' ]]; do _r="${_r%$'\n'}"; done
  (( ${#_r} > 4000 )) && _r="${_r:0:4000}…"
  [[ -s "$2" ]] && IFS= read -r -d '' -N 65536 _e < "$2" 2>/dev/null
  [[ -n "$_e" ]] && return 0   # 본문이 stderr 사유를 이미 냈으면 덧붙이지 않는다(T2 stderr 보존)
  printf '%s\n' "$_r" >&2
  return 0
}

# 9. 읽기 전용 도구 목록 (closed_mut 용) — lib/stop_marker_gate.py ALLOW_ON_STOP 와 동일 집합
_tb_is_readonly() {
  case "$1" in
    Read|Grep|Glob|LS|ToolSearch|SendMessage|ListAgents|TaskList|TaskGet|TaskOutput) return 0 ;;
    mcp__oio__file_read|mcp__oio__find|mcp__oio__list_dir|mcp__oio__file_info) return 0 ;;
    mcp__oio__get_cwd|mcp__oio__lock_status|mcp__oio__session_state) return 0 ;;
  esac
  return 1
}

# 10. closed_ro 용 엄격한 읽기 전용 판정(머리 주석 참조) — 예산 초과 경로에서만 부른다. 포크 0(빌트인 정규식·read).
#   0 = 읽기 전용 확정, 1 = 아니거나 불확실(fail-closed). 사유는 _TB_ROWHY.
_tb_ro_call() {
  local LC_ALL=C
  local _ti _rest _k _v _cmd="" _ncmd=0 _cwd="" _seg _t _w _i _low _re
  local -a _toks _kept
  _TB_ROWHY=""
  _tb_is_readonly "$_TB_TOOL" && return 0
  [[ "$_TB_TOOL" == mcp__oio__bash_exec ]] || { _TB_ROWHY=tool; return 1; }
  (( _TB_BIG == 0 && _TB_INRC == 0 )) || { _TB_ROWHY=input; return 1; }
  # tool_input 은 중괄호 없는 평면 객체로 한 번만 — env 같은 중첩 객체·키 순서 속임수는 여기서 떨어진다
  _re='"tool_input"[[:space:]]*:[[:space:]]*\{([^{}]*)\}'
  [[ "$_TB_IN" =~ $_re ]] || { _TB_ROWHY=tool_input; return 1; }
  _ti="${BASH_REMATCH[1]}"
  _rest="${_TB_IN#*\"tool_input\"}"
  [[ "$_rest" == *'"tool_input"'* ]] && { _TB_ROWHY=dup_tool_input; return 1; }
  # 이스케이프(\" \n \t > …)가 하나라도 있으면 판정하지 않는다
  [[ "$_ti" == *\\* ]] && { _TB_ROWHY=escape; return 1; }
  _re='^[[:space:]]*,?[[:space:]]*"([A-Za-z_]+)"[[:space:]]*:[[:space:]]*("[^"]*"|-?[0-9]+|true|false|null)(.*)$'
  _rest="$_ti"
  while [[ "$_rest" =~ $_re ]]; do
    _k="${BASH_REMATCH[1]}"; _v="${BASH_REMATCH[2]}"; _rest="${BASH_REMATCH[3]}"
    case "$_k" in
      command) [[ "$_v" == \"*\" ]] || { _TB_ROWHY=command_type; return 1; }
               _cmd="${_v:1:${#_v}-2}"; _ncmd=$(( _ncmd + 1 )) ;;
      cwd|working_dir|workdir)
               if [[ "$_v" != null ]]; then
                 [[ "$_v" == \"*\" ]] || { _TB_ROWHY=cwd_type; return 1; }
                 _cwd+=" ${_v:1:${#_v}-2}"
               fi ;;
      timeout_ms|timeout) [[ "$_v" == null || "$_v" =~ ^[0-9]+$ ]] || { _TB_ROWHY=timeout_type; return 1; } ;;
      run_in_background)  [[ "$_v" == false || "$_v" == null ]] || { _TB_ROWHY=background; return 1; } ;;
      *) _TB_ROWHY="key:$_k"; return 1 ;;
    esac
  done
  [[ "$_rest" =~ ^[[:space:]]*$ ]] || { _TB_ROWHY=parse; return 1; }
  (( _ncmd == 1 )) || { _TB_ROWHY=command_count; return 1; }
  (( ${#_cmd} >= 1 && ${#_cmd} <= 400 )) || { _TB_ROWHY=length; return 1; }
  # [사이클206 D-7] date 형식 인자의 작은따옴표 — 짝 맞는 '+…' 이고 내용이 [A-Za-z0-9 _./:=,+@%-] 뿐일 때만
  #   따옴표를 벗기고 공백을 _ 로 바꾼 뒤 앞에 ^ 표식을 붙인다(원문 허용 문자에 ^ 가 없으므로 표식은 위조할 수 없다).
  #   표식 토큰은 아래 구간 검사에서 date 의 인자로만 받는다. + 로 시작하지 않는 내용('-s…'),
  #   그 밖 글자($ ` ( ) 등)·짝 없는 따옴표는 정규화되지 않아 아래 charset 에서 종전대로 떨어진다(grep 'a b' 등도 종전대로 보류).
  [[ "$_cmd" != *^* ]] || { _TB_ROWHY=charset; return 1; }
  _re="^([^']*)'(\\+[A-Za-z0-9 _./:=,+@%-]*)'(.*)\$"
  _rest="$_cmd"; _cmd=""
  while [[ "$_rest" =~ $_re ]]; do
    _v="${BASH_REMATCH[2]}"
    _cmd+="${BASH_REMATCH[1]}^${_v// /_}"
    _rest="${BASH_REMATCH[3]}"
  done
  _cmd+="$_rest"
  # 허용 문자만 — ; ` $ ( ) ' " * ? [ ] { } < ! # 개행·탭·비ASCII 는 여기서 떨어진다(> & 는 아래 토큰 검사로 넘긴다)
  #   ^ 는 위 정규화 표식으로만 들어온다(원문의 ^ 는 정규화 전 검사에서 떨어진다)
  [[ "$_cmd" != *"'"* ]] || { _TB_ROWHY=charset; return 1; }
  _re='^[A-Za-z0-9 _./:=,+@%|~&>^-]+$'
  [[ "$_cmd" =~ $_re ]] || { _TB_ROWHY=charset; return 1; }
  # 민감 경로 — command 와 cwd 모두(대소문자 무시)
  _low="${_cmd,,} ${_cwd,,}"
  for _w in credential secret password passwd token private_key apikey api_key id_rsa id_ed25519 id_ecdsa id_dsa \
            .ssh .gnupg .aws .kube .docker .netrc .pgpass .my.cnf .npmrc .pypirc .env .claude.json \
            settings.json settings.local.json session-env guard_promote backup/ /proc/ environ shadow /mnt/; do
    [[ "$_low" == *"$_w"* ]] && { _TB_ROWHY="sensitive:$_w"; return 1; }
  done
  # 단일 | 구간마다 — 끝에 | 를 붙여 앞뒤·연속 빈 구간(|| 포함)을 빈 구간으로 잡는다
  _rest="$_cmd|"
  while [[ -n "$_rest" ]]; do
    _seg="${_rest%%|*}"; _rest="${_rest#*|}"
    _toks=(); read -r -a _toks <<< "$_seg"
    _kept=()
    for _t in "${_toks[@]}"; do
      case "$_t" in
        '2>/dev/null'|'2>&1') ;;
        *'>'*|*'&'*) _TB_ROWHY=redirect; return 1 ;;
        *) _kept+=("$_t") ;;
      esac
    done
    (( ${#_kept[@]} >= 1 )) || { _TB_ROWHY=empty_segment; return 1; }
    _w="${_kept[0]}"
    [[ "$_w" == *^* ]] && { _TB_ROWHY=quote_pos; return 1; }
    case "$_w" in
      date|ls|cat|head|tail|wc|grep|rg|find|stat|pwd) ;;
      uptime|nproc|whoami) ;;                       # [사이클206 D-7] 인자와 무관하게 읽기 전용
      hostname) (( ${#_kept[@]} == 1 )) || { _TB_ROWHY=hostname_arg; return 1; } ;;   # 인자가 있으면 이름 설정일 수 있다
      git) [[ "${_kept[1]:-}" =~ ^(log|status|show|diff|rev-parse)$ ]] || { _TB_ROWHY=git_sub; return 1; } ;;
      *) _TB_ROWHY="cmd:$_w"; return 1 ;;
    esac
    for (( _i = 1; _i < ${#_kept[@]}; _i++ )); do
      _t="${_kept[_i]}"
      # 작은따옴표 표식(^) 토큰은 date 의 형식 인자로만 받는다
      if [[ "$_t" == *^* ]]; then
        [[ "$_w" == date && "$_t" == ^+* && "${_t:1}" != *^* ]] || { _TB_ROWHY=quote_pos; return 1; }
      fi
      case "$_w" in
        find) [[ "$_t" =~ ^-(delete|exec|execdir|ok|okdir|fprint|fprint0|fprintf|fls)$ ]] && { _TB_ROWHY=find_action; return 1; } ;;
        rg)   [[ "$_t" =~ ^--(pre|hidden|no-ignore|follow|unrestricted) || "$_t" =~ ^-[A-Za-z.]*[uL.] ]] && { _TB_ROWHY=rg_opt; return 1; } ;;
        grep) [[ "$_t" =~ ^--(recursive|dereference-recursive|directories) || "$_t" =~ ^-[A-Za-z]*[rRd] ]] && { _TB_ROWHY=grep_opt; return 1; } ;;
        git)  [[ "$_t" =~ ^-[A-Za-z]*[cC] || "$_t" =~ ^--(output|ext-diff|textconv|exec-path|git-dir|work-tree|config|upload-pack) ]] && { _TB_ROWHY=git_opt; return 1; } ;;
        date) [[ "$_t" =~ ^-[A-Za-z]*s || "$_t" =~ ^--set ]] && { _TB_ROWHY=date_set; return 1; } ;;
      esac
    done
  done
  return 0
}

# 11. 고부하 보류 대상 판정(머리 주석 "고부하 보류") — 초과 직후에만 부른다. 0 = 대상. 포크 0.
#   [F-TB-STATE-HOLD, conv_179340696995 R7] 상태 전이(session_state key=state 쓰기)를 맡은 판정 hook 5종은 부하 L 과 무관하게,
#   이름에 guard 가 없어도(done_gate·dev_ac_gate·docs_update_gate), session_state 가 읽기 전용 목록에 있어도 보류 대상이다.
#   사건(2026-10-31 03:39:32~35): oto_completion_guard 가 13초 초과로 생략 통과됐고 3초 뒤 늦은 판정이 rc=2(차단)로 끝나 버려졌다.
#   탈출(TB_HOLD_MAX 회 보류 뒤 통과)은 그대로이며 로그 overrun_hold_escape 가 남는다. 감사: scripts/gate_skip_audit.py.
_tb_state_write_hold() {
  [[ "$_TB_EVT" == PreToolUse && "$_TB_TOOL" == mcp__oio__session_state ]] || return 1
  case "$_TB_NAME" in
    PreToolUse_done_gate.sh|PreToolUse_oto_completion_guard.sh|PreToolUse_oto_entry_guard.sh|PreToolUse_dev_ac_gate.sh|PreToolUse_docs_update_gate.sh) ;;
    *) return 1 ;;
  esac
  (( _TB_BIG == 0 )) || return 1
  [[ "$_TB_IN" =~ \"tool_input\"[[:space:]]*:[[:space:]]*\{[^{}]*\"key\"[[:space:]]*:[[:space:]]*\"state\" ]]
}
_tb_hold_target() {
  _tb_state_write_hold && return 0
  (( _TB_L >= ${TB_HOLD_L:-500} )) || return 1
  [[ "$_TB_EVT" == PreToolUse && "$_TB_NAME" == *guard* ]] || return 1
  _tb_ro_call && return 1          # 읽기 전용 도구·엄격 읽기 전용 bash 는 종전대로 통과
  return 0
}

# 실효 정책: closed_mut 은 도구에 따라 closed/open 으로 갈린다. closed_ro 는 예산 초과 판정 전까지 closed 와 같다.
_TB_EFF="$_TB_POL"
if [[ "$_TB_POL" == closed_mut ]]; then
  if _tb_is_readonly "$_TB_TOOL"; then _TB_EFF=open; else _TB_EFF=closed; fi
elif [[ "$_TB_POL" == closed_ro ]]; then
  _TB_EFF=closed
fi

# 1-1b. [사이클182 반복1 A1] 입력 미완 — 3초 창 안에 EOF 가 오지 않았다(빈·잘린 입력).
#   종전에는 받은 만큼만 본문에 넘겨 본문이 도구를 알아보지 못하고 통과했다(실측: write_guard 보호 경로 쓰기가
#   입력 4초 지연·잘림 시 rc=0, 즉시 rc=2). closed 는 판정불가 = 차단(stderr 안내 + exit 2), open 은 종전대로 실행한다.
#   창 3초 근거(실측): 파이프 전송 자체는 28MB 도 60ms 이내(64KB 조각 쓰기 포함) — 창은 전송이 아니라 송신 지연 대비다.
#   큰 입력의 파일 수신(v2, 760KB 잘림 수정)은 그대로다 — 수신 방식이 아니라 미완일 때의 결과만 바꾼다.
if [[ "$_TB_EFF" == closed && "$_TB_INRC" -ne 0 ]]; then
  printf '⏳ [time_budget] %s 입력 미완 — hook 입력을 3초 안에 끝까지 받지 못했습니다(rc=%s). 아직 거부가 아닙니다. 판정불가는 통과가 아니므로 이번 호출은 보류합니다. 같은 호출을 다시 하십시오.\n' "$_TB_NAME" "$_TB_INRC" >&2
  _tb_log input_incomplete 2
  rm -f -- "$_TB_T.in" 2>/dev/null
  exit 2
fi

# 캐시 키 — sha1(스크립트 + 인자 + tool_use_id 를 지운 입력 + state mtime). 포크가 있으므로 필요한 경로에서만 부른다.
_tb_key() {  # [script_args...] → _TB_KEY
  local _s="$_TB_IN" _m=0 _k=""
  (( _TB_BIG == 0 )) || return 1      # 256KB 초과 입력은 캐시 키를 만들지 않는다(앞부분만으로는 같은 입력임을 보장 못 한다)
  while [[ "$_s" =~ (\"tool_use_id\"[[:space:]]*:[[:space:]]*\"[^\"]*\") ]]; do
    _s="${_s/"${BASH_REMATCH[1]}"/}"
  done
  [[ -n "$_TB_STATEF" && -e "$_TB_STATEF" ]] && _m="$(stat -c %Y "$_TB_STATEF" 2>/dev/null)"
  read -r _k _ < <(printf '%s\0' "$_TB_SCRIPT" "$@" "$_s" "state_mtime=${_m:-0}" | sha1sum 2>/dev/null)
  _TB_KEY="$_k"
  [[ "$_TB_KEY" =~ ^[0-9a-f]{40}$ ]]
}
_tb_has_res() {  # 빌트인 glob — 캐시 항목이 하나라도 있으면 0
  local _f
  for _f in "$_TB_CACHE"/*.res; do [[ -e "$_f" ]] && return 0; done
  return 1
}

# 1-2. 늦은 판정 캐시 조회 — closed 실효 + 캐시 항목이 있을 때만 키를 계산한다(평상시 포크 0)
_TB_LOOK=0
if [[ "$_TB_EFF" == closed ]]; then _TB_LOOK=1
elif [[ "$_TB_EFF" == open && "$_TB_EVT" == PreToolUse && "$_TB_NAME" == *guard* ]]; then _TB_LOOK=1   # 고부하 보류분(open) 재시도
elif [[ "$_TB_EFF" == open ]] && _tb_state_write_hold; then _TB_LOOK=1   # [F-TB-STATE-HOLD] 이름에 guard 없는 상태 전이 판정 hook 의 보류분 재시도
fi
if (( _TB_LOOK == 1 )) && [[ -n "$_TB_CACHE" ]] && _tb_has_res && _tb_key "$@"; then
  _TB_R="$_TB_CACHE/$_TB_KEY.res"
  if [[ -d "$_TB_R" ]]; then
    _TB_U="$_TB_CACHE/$_TB_KEY.use.$$"
    if mv -T "$_TB_R" "$_TB_U" 2>/dev/null; then      # 1회용 — 먼저 가져간 쪽만 쓴다
      _TB_M="$(stat -c %Y "$_TB_U" 2>/dev/null)"
      _TB_NOW="${EPOCHREALTIME%.*}"
      _TB_CRC=""
      [[ -r "$_TB_U/rc" ]] && IFS= read -r _TB_CRC < "$_TB_U/rc"
      if [[ "$_TB_M" =~ ^[0-9]+$ ]] && (( _TB_NOW - _TB_M <= 90 )) && [[ "$_TB_CRC" =~ ^[0-9]+$ ]]; then
        [[ -s "$_TB_U/out" ]] && cat "$_TB_U/out"
        [[ -s "$_TB_U/err" ]] && { printf '[참고: %s 출력 — time_budget 보류 원인 아님]\n' "$_TB_NAME"; cat "$_TB_U/err"; } >&2
        rm -rf -- "$_TB_U" 2>/dev/null
        rm -f -- "$_TB_T.in" "$_TB_CACHE/$_TB_KEY.hold" 2>/dev/null
        [[ "$_TB_CRC" != 0 && "$_TB_CRC" != 2 ]] && _TB_CRC=0
        _tb_log cache "$_TB_CRC"
        exit "$_TB_CRC"
      fi
      rm -rf -- "$_TB_U" 2>/dev/null                  # 90초 초과·손상분은 지우고 무시
    fi
  fi
fi

# 1-3. LKG 대체 실행 (F-HOOK-LKG) — 머리 주석 참조
_TB_RUN="$_TB_SCRIPT"      # 실제로 실행할 파일 (LKG 대체 시 사본 경로)
_TB_LKG_FRESH=0            # 1 = 이번 호출에서 bash -n 통과를 확인했다 → 정상 종료 시 LKG 갱신
_TB_LKG_D="${TB_LKG_DIR:-$HOME/.local/state/hook_lkg}"
_TB_LKG_K="${_TB_SCRIPT//[^A-Za-z0-9._-]/_}"
_TB_LKG_ST="$_TB_LKG_D/$_TB_LKG_K.stamp"

_tb_lkg_dir_ok() { [[ -d "$_TB_LKG_D" && ! -L "$_TB_LKG_D" && -O "$_TB_LKG_D" ]]; }
_tb_lkg_note() {  # $1=사건 $2=내용 — 저장소 로그 + 자기 세션 hook_tb.log
  local _ts
  printf -v _ts '%(%Y-%m-%dT%H:%M:%S%z)T' -1
  _tb_lkg_dir_ok && printf '%s hook=%s event=%s %s\n' "$_ts" "$_TB_SCRIPT" "$1" "$2" >> "$_TB_LKG_D/lkg.log" 2>/dev/null
  _tb_log "lkg_$1" "-"
  return 0
}
_tb_lkg_is_bash() {  # 첫 줄 shebang 이 bash/sh 인가 (빌트인 read)
  local _l=""
  IFS= read -r _l < "$_TB_SCRIPT" 2>/dev/null
  [[ "$_l" =~ ^#![[:space:]]*[^[:space:]]*(/bash|/sh|/env[[:space:]]+(bash|sh))([[:space:]]|$) ]]
}
_tb_lkg_pick() {  # 검증된 LKG 경로 → _TB_LKG_P (실패 시 _TB_LKG_WHY)
  local _meta="$_TB_LKG_D/$_TB_LKG_K.meta" _sha="" _p="" _real _want _act=""
  _TB_LKG_P=""; _TB_LKG_WHY=""
  if ! _tb_lkg_dir_ok; then _TB_LKG_WHY="LKG 저장소 없음·링크·타인 소유"; return 1; fi
  if [[ -L "$_meta" || ! -f "$_meta" || ! -O "$_meta" ]]; then _TB_LKG_WHY="LKG 없음"; return 1; fi
  { IFS= read -r _sha; IFS= read -r _p; } < "$_meta" 2>/dev/null
  if [[ ! "$_sha" =~ ^[0-9a-f]{64}$ ]]; then _TB_LKG_WHY="LKG 메타 손상"; return 1; fi
  _real="$(realpath -e -- "$_TB_SCRIPT" 2>/dev/null)"
  _want="${_real%/*}/.${_real##*/}.lkg.${_sha:0:12}"
  if [[ -z "$_real" || "$_p" != "$_want" ]]; then _TB_LKG_WHY="LKG 경로 불일치"; return 1; fi
  if [[ -L "$_p" || ! -f "$_p" || ! -O "$_p" ]]; then _TB_LKG_WHY="LKG 사본 없음·링크·타인 소유"; return 1; fi
  read -r _act _ < <(sha256sum -- "$_p" 2>/dev/null)
  if [[ "$_act" != "$_sha" ]]; then _TB_LKG_WHY="LKG 변조(sha 불일치)"; return 1; fi
  if ! bash -n "$_p" >/dev/null 2>&1; then _TB_LKG_WHY="LKG 구문 오류"; return 1; fi
  _TB_LKG_P="$_p"
  return 0
}
_tb_lkg_warn_once() {  # 대상 판(mtime)마다 stderr 1회
  local _w="$_TB_LKG_D/$_TB_LKG_K.warned"
  _tb_lkg_dir_ok || { printf '%s\n' "$1" >&2; return 0; }
  if [[ -e "$_w" && ! "$_TB_SCRIPT" -nt "$_w" && ! "$_w" -nt "$_TB_SCRIPT" ]]; then return 0; fi
  printf '%s\n' "$1" >&2
  touch -r "$_TB_SCRIPT" -- "$_w" 2>/dev/null
  return 0
}
# 갱신 — 본 호출이 끝난 뒤 백그라운드에서만 부른다(같은 디렉터리 임시파일 → mv 원자 교체)
_tb_lkg_refresh() {
  local _real _dir _base _ref _tmp _sha="" _dst _f _lk="$_TB_LKG_D/$_TB_LKG_K.lock" _now _m
  if [[ ! -e "$_TB_LKG_D" ]]; then mkdir -p -m 700 -- "$_TB_LKG_D" 2>/dev/null || return 0; fi
  _tb_lkg_dir_ok || return 0
  if ! mkdir -- "$_lk" 2>/dev/null; then
    _m="$(stat -c %Y -- "$_lk" 2>/dev/null)"; _now="${EPOCHREALTIME%.*}"
    [[ "$_m" =~ ^[0-9]+$ ]] && (( _now - _m > 60 )) || return 0
    rmdir -- "$_lk" 2>/dev/null; mkdir -- "$_lk" 2>/dev/null || return 0
  fi
  _real="$(realpath -e -- "$_TB_SCRIPT" 2>/dev/null)"
  if [[ -z "$_real" || -L "$_real" || ! -f "$_real" ]]; then rmdir -- "$_lk" 2>/dev/null; return 0; fi
  _dir="${_real%/*}"; _base="${_real##*/}"
  _ref="$_TB_LKG_D/$_TB_LKG_K.ref.$BASHPID"
  _tmp="$_dir/.$_base.lkg.tmp.$BASHPID"
  if _tb_lkg_refresh_core > /dev/null 2>&1; then _tb_lkg_note refresh "sha=$_sha"; else _tb_lkg_note refresh_fail "-"; fi
  rm -f -- "$_tmp" "$_ref" "$_TB_LKG_D/$_TB_LKG_K.meta.tmp.$BASHPID" 2>/dev/null
  rmdir -- "$_lk" 2>/dev/null
  return 0
}
_tb_lkg_refresh_core() {  # _tb_lkg_refresh 의 지역변수(_real _dir _base _ref _tmp _sha _dst)를 그대로 쓴다
  local _f
  touch -r "$_real" -- "$_ref" || return 1
  cp -- "$_real" "$_tmp" || return 1
  # 복사하는 사이 대상이 바뀌었으면 이번 갱신은 버린다
  [[ ! "$_real" -nt "$_ref" && ! "$_ref" -nt "$_real" ]] || return 1
  bash -n "$_tmp" || return 1
  read -r _sha _ < <(sha256sum -- "$_tmp")
  [[ "$_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
  _dst="$_dir/.$_base.lkg.${_sha:0:12}"
  mv -f -T -- "$_tmp" "$_dst" || return 1
  printf '%s\n%s\n' "$_sha" "$_dst" > "$_TB_LKG_D/$_TB_LKG_K.meta.tmp.$BASHPID" || return 1
  mv -f -T -- "$_TB_LKG_D/$_TB_LKG_K.meta.tmp.$BASHPID" "$_TB_LKG_D/$_TB_LKG_K.meta" || return 1
  mv -f -T -- "$_ref" "$_TB_LKG_ST" || return 1      # 스탬프 mtime = 검증한 판의 mtime
  for _f in "$_dir/.$_base.lkg."*; do                 # 지난 사본 정리(한 hook 당 1벌만 유지)
    [[ "$_f" == "$_dst" || "$_f" == *.tmp.* || ! -f "$_f" ]] || rm -f -- "$_f"
  done
  return 0
}

# 스탬프가 없거나 대상이 없으면 '-nt' 가 참이 되어 검증된 판으로 보지 않는다(-e·-f 를 따로 묻지 않아 NTFS stat 을 아낀다)
if [[ ! "$_TB_SCRIPT" -nt "$_TB_LKG_ST" && ! "$_TB_LKG_ST" -nt "$_TB_SCRIPT" ]]; then
  :   # 검증된 판 — 평상시 경로(포크 0)
elif [[ -f "$_TB_SCRIPT" ]]; then
  if _tb_lkg_is_bash; then
    if bash -n "$_TB_SCRIPT" > /dev/null 2>&1; then
      _TB_LKG_FRESH=1
    elif _tb_lkg_pick; then
      _TB_RUN="$_TB_LKG_P"
      _tb_lkg_note fallback "lkg=$_TB_LKG_P"
      _tb_lkg_warn_once "⚠️ [hook_lkg] ${_TB_NAME} 구문 오류(bash -n 실패) — 마지막 정상본(${_TB_LKG_P##*/})으로 대신 판정합니다. 원본을 고쳐야 합니다. 기록: ${_TB_LKG_D}/lkg.log"
    else
      _tb_lkg_note blocked "why=$_TB_LKG_WHY"
      if [[ "$_TB_EFF" == closed ]]; then
        printf '🚫 [hook_lkg] %s 구문 오류(bash -n 실패) + 대체 실행 불가(%s) — 안전을 위해 이번 호출을 차단합니다. 원본 hook 을 Claude Code 밖에서 고치거나 정상판으로 되돌리세요. 기록: %s/lkg.log\n' \
          "$_TB_NAME" "$_TB_LKG_WHY" "$_TB_LKG_D" >&2
        rm -f -- "$_TB_T.in" 2>/dev/null
        exit 2
      fi
      printf '⚠️ [hook_lkg] %s 구문 오류(bash -n 실패) + 대체 실행 불가(%s) — 원본을 그대로 실행합니다.\n' "$_TB_NAME" "$_TB_LKG_WHY" >&2
    fi
  fi
fi
_TB_CMD=("$_TB_SCRIPT")
[[ "$_TB_RUN" != "$_TB_SCRIPT" ]] && _TB_CMD=(bash -- "$_TB_RUN")

# 임시 파일 (EXT4) — 2절에서 입력을 이미 파일로 받았으면 그대로 쓴다
if (( _TB_INF == 0 )) && ! printf '%s' "$_TB_IN" > "$_TB_T.in" 2>/dev/null; then
  # 임시 파일을 못 만들면 예산 없이 원본 실행 (입력은 이미 읽었으므로 here-string 으로 넘긴다)
  "${_TB_CMD[@]}" "$@" <<< "$_TB_IN"
  exit $?
fi

# 늦은 판정 저장 — 본문 서브셸에서만 부른다(이미 포기된 호출이라 시간 제약 없음)
_tb_cache_put() {  # $1=rc [script_args...]
  local _rc="$1" _m=0 _d _old _now
  shift
  [[ -n "$_TB_CACHE" && ( "$_TB_EFF" == closed || -e "$_TB_T.hold" ) ]] || return 0   # .hold = 고부하 보류 대상(open 포함)
  # 판정 도중 state 가 바뀌었으면 그 판정은 남기지 않는다
  [[ -n "$_TB_STATEF" && -e "$_TB_STATEF" ]] && _m="$(stat -c %Y "$_TB_STATEF" 2>/dev/null)"
  [[ "$_m" =~ ^[0-9]+$ ]] || return 0
  (( _m >= _TB_T0 / 1000000 )) && return 0
  _tb_key "$@" || return 0
  mkdir -p "$_TB_CACHE" 2>/dev/null || return 0
  # 90초 지난 항목 정리 (자기 세션 캐시 디렉토리 안만)
  _now="${EPOCHREALTIME%.*}"
  for _old in "$_TB_CACHE"/*.res "$_TB_CACHE"/*.tmp.* "$_TB_CACHE"/*.use.*; do
    [[ -e "$_old" ]] || continue
    _d="$(stat -c %Y "$_old" 2>/dev/null)"
    [[ "$_d" =~ ^[0-9]+$ ]] && (( _now - _d > 90 )) && rm -rf -- "$_old" 2>/dev/null
  done
  _d="$_TB_CACHE/$_TB_KEY.tmp.$BASHPID"
  mkdir "$_d" 2>/dev/null || return 0
  printf '%s\n' "$_rc" > "$_d/rc"
  cp "$_TB_T.out" "$_d/out" 2>/dev/null || : > "$_d/out"
  cp "$_TB_T.err" "$_d/err" 2>/dev/null || : > "$_d/err"
  rm -rf -- "$_TB_CACHE/$_TB_KEY.res" 2>/dev/null
  mv -T "$_d" "$_TB_CACHE/$_TB_KEY.res" 2>/dev/null || rm -rf -- "$_d" 2>/dev/null
  return 0
}

# 4. 본문 — 백그라운드. 끝나면 rc 로 종료. 부모가 이미 포기(.late)했으면 늦은 출력을 로그·캐시로 남기고 정리한다.
(
  "${_TB_CMD[@]}" "$@" < "$_TB_T.in" > "$_TB_T.out" 2> "$_TB_T.err"
  _rc=$?
  if [[ -e "$_TB_T.late" ]]; then
    _tb_log late "$_rc"
    if [[ -n "$_TB_LOGDIR" && ( -s "$_TB_T.out" || -s "$_TB_T.err" ) ]]; then
      { printf -- '--- late output hook=%s rc=%s pid=%s ---\n' "$_TB_NAME" "$_rc" "$$"
        cat "$_TB_T.out" "$_TB_T.err" 2>/dev/null; } >> "$_TB_LOGDIR/hook_tb_late.log" 2>/dev/null
    fi
    # c183 B8(F-ISO-3): 늦은 본문의 ★차단★ 결과는 캐시하지 않는다. 부모(래퍼)가 먼저 끝나 본문이 init 에 재부모화되면
    #   조상 argv(--parent-session-id) 같은 프로세스 계보 증명이 실패해 거짓 차단이 나오고, 그것이 캐시로 재시도에 굳었다
    #   (odev-4 실측: late rc=2 14.5·16.8초 → cache rc=2). 통과(rc=0)만 캐시하고 차단은 재시도 때 정상 계보로 다시 판정한다.
    [[ "$_rc" == 0 ]] && _tb_cache_put "$_rc" "$@"
    rm -f "$_TB_T.in" "$_TB_T.out" "$_TB_T.err" "$_TB_T.late" "$_TB_T.hold" 2>/dev/null
  fi
  exit "$_rc"
) < /dev/null > /dev/null 2>&1 &
_TB_BODY=$!

# 5. 타이머 (실효 예산) — [사이클206 F-1(a)] 기동 시각(_TB_T0)부터 잰 남은 예산만 기다린다.
#   이미 실효 예산 이상 지났으면 0.01초 뒤 바로 초과 경로(closed_ro 판정 → 통과/보류)로 간다.
#   불변식: 래퍼 종료 ≤ max(기동 + 실효 예산, 진입) + 처리 여유 — 하네스 timeout(기동부터 잼)보다 먼저 끝난다.
_TB_OVER=0
trap '_TB_OVER=1' USR1
_TB_REM=$(( _TB_EUS - (${EPOCHREALTIME/./} - _TB_T0) ))
(( _TB_REM < 10000 )) && _TB_REM=10000
printf -v _TB_REMS '%d.%06d' $(( _TB_REM / 1000000 )) $(( _TB_REM % 1000000 ))
# [사이클206 누수 수정] 종전 `( sleep R; kill -USR1 $$ ) &` 는 아래 `kill $_TB_TIMER` 가 서브셸만 죽여 sleep 이 고아로 남았다
#   (예산 590 hook 마다 10분짜리 sleep 1개 — 실측 220여 개. 래퍼가 상속한 fd(guard_promote.lock 등)까지 물고 있어 promote lock_timeout 유발).
#   타이머 서브셸이 sleep pid 를 들고 TERM 에서 함께 죽인다. sleep 이 끝까지 가면 종전대로 USR1 을 보낸다.
( _tb_s=""; trap '[[ -n "$_tb_s" ]] && kill "$_tb_s" 2>/dev/null; exit 0' TERM
  sleep "$_TB_REMS" & _tb_s=$!
  wait "$_tb_s" && kill -USR1 $$ ) < /dev/null > /dev/null 2>&1 &
_TB_TIMER=$!

wait "$_TB_BODY"; _TB_RC=$?

# 6-0. [사이클212 건2] 고부하 유예 — 초과 직후 대상이면 하네스 timeout 여유 안에서 한 번 더 기다린다(포크: sleep 1).
#   유예 안에 본문이 끝나면 아래 7절이 정상 경로로 그 판정을 쓴다. open 대상은 .hold 표식으로 늦은 판정 캐시 대상이 된다.
_TB_HT=0; _TB_GRACE_US=0
if (( _TB_OVER == 1 )) && kill -0 "$_TB_BODY" 2>/dev/null && _tb_hold_target; then
  _TB_HT=1
  [[ "$_TB_EFF" == open ]] && : > "$_TB_T.hold" 2>/dev/null
  _TB_HTO="${TB_HARNESS_TIMEOUT:-}"
  if [[ ! "$_TB_HTO" =~ ^[0-9]+$ ]]; then
    # settings.json 실측 대응(2026-10-31): 예산 2.5·3.75→5, 7.5→10, 9→12, 13→15. 예산이 이보다 크면 15로 본다.
    if (( _TB_BUS <= 5000000 )); then _TB_HTO=5
    elif (( _TB_BUS <= 7500000 )); then _TB_HTO=10
    elif (( _TB_BUS <= 9000000 )); then _TB_HTO=12
    else _TB_HTO=15; fi
  fi
  _TB_GRACE_US=$(( _TB_HTO * 1000000 - (${EPOCHREALTIME/./} - _TB_T0) - 500000 ))
  (( _TB_GRACE_US > 1500000 )) && _TB_GRACE_US=1500000
  if (( _TB_GRACE_US >= 50000 )); then
    printf -v _TB_REMS '%d.%06d' $(( _TB_GRACE_US / 1000000 )) $(( _TB_GRACE_US % 1000000 ))
    _TB_OVER=0
    ( _tb_s=""; trap '[[ -n "$_tb_s" ]] && kill "$_tb_s" 2>/dev/null; exit 0' TERM
      sleep "$_TB_REMS" & _tb_s=$!
      wait "$_tb_s" && kill -USR1 $$ ) < /dev/null > /dev/null 2>&1 &
    _TB_TIMER=$!
    wait "$_TB_BODY"; _TB_RC=$?
    kill "$_TB_TIMER" 2>/dev/null
  else
    _TB_GRACE_US=0
  fi
fi

# 7. 경합 처리 — 초과 판정 후 .late 를 먼저 만들고, 그 사이 본문이 끝났고 출력이 남아 있으면 정상 경로로 간다.
_TB_MODE=normal
if kill -0 "$_TB_BODY" 2>/dev/null; then
  : > "$_TB_T.late"
  if ! kill -0 "$_TB_BODY" 2>/dev/null && [[ -e "$_TB_T.out" ]]; then
    wait "$_TB_BODY" 2>/dev/null; _TB_RC=$?
    rm -f "$_TB_T.late" 2>/dev/null
  else
    _TB_MODE=overrun
  fi
fi
kill "$_TB_TIMER" 2>/dev/null

if [[ "$_TB_MODE" == overrun ]]; then
  # 8. 초과 경로 — 본문은 계속 돌게 둔다
  # 8-0. [사이클212 건2] 고부하 보류 — open 정책 대상(유예 후에도 미완). 보류 카운터 6회 초과면 탈출(종전 생략 통과).
  if [[ "$_TB_HT" == 1 && "$_TB_EFF" == open && -n "$_TB_CACHE" ]] && _tb_key "$@" && mkdir -p "$_TB_CACHE" 2>/dev/null; then
    _TB_HF="$_TB_CACHE/$_TB_KEY.hold"; _TB_HN=0; _TB_HE=0; _TB_HNOW="${EPOCHREALTIME%.*}"
    [[ -r "$_TB_HF" ]] && IFS=' ' read -r _TB_HN _TB_HE < "$_TB_HF" 2>/dev/null
    [[ "$_TB_HN" =~ ^[0-9]{1,3}$ && "$_TB_HE" =~ ^[0-9]{1,12}$ ]] || { _TB_HN=0; _TB_HE=0; }
    (( _TB_HNOW - _TB_HE > 180 )) && _TB_HN=0
    if (( _TB_HN >= ${TB_HOLD_MAX:-6} )); then
      rm -f -- "$_TB_HF" 2>/dev/null
      _tb_log overrun_hold_escape 0
      printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"⏱️ [time_budget] %s 판정 생략(고부하 6회 재시도 초과) — 해당 규칙은 그대로 유효하니 스스로 준수하세요."}}\n' \
        "$_TB_EVT" "$_TB_NAME"
      exit 0
    fi
    printf '%s %s\n' $(( _TB_HN + 1 )) "$_TB_HNOW" > "$_TB_HF" 2>/dev/null
    _tb_log overrun_hold 2
    _TB_MS=$(( (${EPOCHREALTIME/./} - _TB_T0) / 1000 ))
    printf -v _TB_HS '%d.%d' $(( _TB_MS / 1000 )) $(( (_TB_MS % 1000) / 100 ))
    printf '⏱️ [time_budget] 차단 주체=time_budget(고부하 판정 지연) / 대상 hook=%s / 원인=시스템 정체(%sms, load=%s‰) / 조치=같은 호출을 그대로 다시 실행(2·4·8초 간격, 최대 6회)\n' \
      "$_TB_NAME" "$_TB_MS" "$_TB_L" >&2
    printf '이 호출은 %s 의 거부가 아니라 time_budget 의 보류입니다 — 유예 포함 %s초 안에 판정이 끝나지 않았습니다. 판정은 백그라운드에서 계속되며 끝나면 다음 재시도가 즉시 통과합니다. 6회 연속 보류되면 판정을 생략하고 통과시키며 로그(overrun_hold_escape)를 남깁니다.\n' \
      "$_TB_NAME" "$_TB_HS" >&2
    _TB_PE=""
    [[ -s "$_TB_T.err" ]] && IFS= read -r -d '' -N 600 _TB_PE < "$_TB_T.err"
    if [[ -n "$_TB_PE" ]]; then
      while [[ "$_TB_PE" == *$'\n' ]]; do _TB_PE="${_TB_PE%$'\n'}"; done
      _TB_PE="${_TB_PE//$'\n'/ / }"
      printf '[참고: %s 출력 — 차단 원인 아님] %s\n' "$_TB_NAME" "$_TB_PE" >&2
    fi
    exit 2
  fi
  if [[ "$_TB_EFF" == closed ]]; then
    # 8-1. closed_ro — 엄격한 읽기 전용 호출만 보류 없이 통과(판정 불확실은 아래 보류로 간다)
    if [[ "$_TB_POL" == closed_ro ]] && _tb_ro_call; then
      _tb_log overrun_ro_pass 0
      case "$_TB_EVT" in
        PreToolUse|PostToolUse|UserPromptSubmit|SessionStart)
          printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"⏱️ [time_budget] %s 판정 생략(시스템 정체 %ss 초과) — 엄격한 읽기 전용 호출이라 보류 없이 통과시켰습니다. 해당 규칙은 그대로 유효하니 스스로 준수하세요."}}\n' \
            "$_TB_EVT" "$_TB_NAME" "$_TB_ES"
          ;;
      esac
      exit 0
    fi
    _tb_log overrun "-"
    # 8-2. 보류 — 첫 줄은 고정 문구(차단 주체 명시). 본문이 그때까지 낸 stderr 는 참고 줄로 분리한다.
    _TB_MS=$(( (${EPOCHREALTIME/./} - _TB_T0) / 1000 ))
    printf '⏱️ [time_budget] 차단 주체=time_budget(시간 예산 초과) / 대상 hook=%s / 원인=시스템 정체(%sms, load=%s‰) / 조치=같은 호출을 2·4·8·16초 간격 재시도\n' \
      "$_TB_NAME" "$_TB_MS" "$_TB_L" >&2
    printf '이 호출은 %s 의 거부가 아니라 time_budget 의 보류입니다 — 실효 예산 %ss 안에 판정이 끝나지 않았습니다. 최대 6회 다시 시도하세요. 판정이 끝나면 다음 재시도는 즉시 처리됩니다.\n' \
      "$_TB_NAME" "$_TB_ES" >&2
    _TB_PE=""
    [[ -s "$_TB_T.err" ]] && IFS= read -r -d '' -N 600 _TB_PE < "$_TB_T.err"
    if [[ -n "$_TB_PE" ]]; then
      while [[ "$_TB_PE" == *$'\n' ]]; do _TB_PE="${_TB_PE%$'\n'}"; done
      _TB_PE="${_TB_PE//$'\n'/ / }"
      printf '[참고: %s 출력 — 차단 원인 아님] %s\n' "$_TB_NAME" "$_TB_PE" >&2
    fi
    exit 2
  fi
  _tb_log overrun "-"
  case "$_TB_EVT" in
    PreToolUse|PostToolUse|UserPromptSubmit|SessionStart)
      printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"⏱️ [time_budget] %s 판정 생략(시스템 정체 %ss 초과) — 해당 규칙은 그대로 유효하니 스스로 준수하세요."}}\n' \
        "$_TB_EVT" "$_TB_NAME" "$_TB_ES"
      ;;
  esac
  exit 0
fi

# 6. 정상 경로 — 원본 출력을 그대로 내보낸다
[[ -s "$_TB_T.out" ]] && cat "$_TB_T.out"
[[ "$_TB_RC" == 2 && -s "$_TB_T.out" ]] && _tb_reason_to_err "$_TB_T.out" "$_TB_T.err"   # [사이클216] 차단 사유 stderr 노출
[[ -s "$_TB_T.err" ]] && cat "$_TB_T.err" >&2
rm -f "$_TB_T.in" "$_TB_T.out" "$_TB_T.err" "$_TB_T.late" "$_TB_T.hold" 2>/dev/null

# LKG 갱신 — 이번 호출에서 bash -n 을 통과했고 예산 안에서 rc∈{0,2}(정상 판정)로 끝난 원본만. 출력 파이프를 물지 않게 백그라운드로.
if (( _TB_LKG_FRESH == 1 )) && [[ "$_TB_RC" == 0 || "$_TB_RC" == 2 ]]; then
  ( _tb_lkg_refresh ) < /dev/null > /dev/null 2>&1 &
fi

if [[ "$_TB_EFF" == closed && "$_TB_RC" != 0 && "$_TB_RC" != 2 ]]; then
  _TB_RC=0   # onFailure:block 이 원본의 우발적 비차단 오류(exit 1 등)로 차단되는 회귀 방지
fi
(( (${EPOCHREALTIME/./} - _TB_T0) > 1000000 )) && _tb_log normal "$_TB_RC"
exit "$_TB_RC"
