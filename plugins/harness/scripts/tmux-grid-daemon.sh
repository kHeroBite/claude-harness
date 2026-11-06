#!/bin/bash
# tmux control mode(-C) 상주 데몬 — %layout-change 알림을 즉시 수신하여
# awk fast path(tmux-grid-fastpath.awk)로 격자를 교정한다. %layout-change의
# 두 번째 인자(window-layout)에 현재 레이아웃 문자열이 이미 담겨 있으므로
# tmux 재조회(list-panes/display-message 등 pane별 서브셸 fork 수십 회) 없이
# 단일 awk 프로세스 호출만으로 목표 레이아웃을 계산한다 — pane 수 무관
# 20~30ms대 교정이 목표(과거 bash apply_grid() 경로는 pane 13개 기준
# min 100ms / p50 443ms / p95 1637ms 실측, 2026-08-25).
#
# 호출 방식 (tmux.conf session-created hook에서 세션 생성 시 자동 기동):
#   ${HARNESS_HOME:-$HOME/.harness}/current/scripts/tmux-grid-daemon.sh <세션명>
#
# 아키텍처:
#   - 계산 알고리즘은 tmux-grid-fastpath.awk가 tmux-main-tiled.sh apply_grid()를
#     그대로 이식한 것이다(원본 무변경 — 참조 전용, 실측 동등성 확인 완료).
#   - apply_grid() 자체는 이 파일에서 더 이상 호출하지 않는다 — 함수 정의만
#     source하여 check_rate_limit() 재사용 목적으로 로드해둔다(폴백 삭제
#     여부는 tmux-main-tiled.sh hook이 여전히 별도 폴백 경로로 존재하므로
#     이 파일 내부의 이중 폴백 호출은 불필요하다고 판단 — 하단 awk fast path
#     주석 참조).
#   - tmux -C attach-session -f ignore-size,no-output 로 상주 접속하고,
#     stdout을 라인 단위로 읽어 "%layout-change ..." 알림에만 반응한다.
#   - 세션당 데몬 1개만 유지 — 세션명 포함 락 파일에 flock -n(논블로킹)으로
#     중복 기동을 즉시 차단한다.
#   - 데몬이 스스로 select-layout을 호출해 유발한 %layout-change 재알림은
#     아래 3중 필터로 무시한다(무한 루프 방지):
#     1차: 메모리 변수(LAST_APPLIED_WINDOW_ID/LAST_APPLIED_LAYOUT) 직전
#          적용값과 동일하면 즉시 continue(가장 저렴한 필터).
#     2차: check_rate_limit()(source로 재사용, 윈도우당 초당 8회 상한).
#     3차: awk 자체 내부 동등성 가드(좌표 멀티셋 비교 — 이미 올바른 격자면
#          출력 없이 종료. tmux가 select-layout 적용 시 pane ID를 내부
#          pane-tree 순회 순서로 재배정하므로 pane ID 문자열 그대로 비교하면
#          안 되고 좌표 멀티셋으로 비교해야 한다 — 실측 확인, awk 파일 주석 참조).
#   - 데몬 사망 시 재기동 로직은 없음(의도적) — 기존 after-split-window/
#     window-layout-changed hook이 폴백으로 계속 작동하므로 기능 상실은
#     없고 교정 지연만 원래 수준(100~300ms)으로 돌아간다.
#   - tmux 서버/세션 종료 또는 attach 끊김 시 stdout이 EOF가 되어
#     while read 루프가 자연 종료되고, flock으로 보유하던 FD도 프로세스
#     종료와 함께 커널이 자동 해제한다.

SESSION="${1:-}"

# 대상 세션 미지정 가드 — 대상 불명확 상태로 진행하지 않는다.
if [[ -z "$SESSION" ]]; then
  echo "[tmux-grid-daemon] ERROR: 세션명 인자 필요 (사용법: tmux-grid-daemon.sh <세션명>)" >&2
  exit 1
fi

# 세션명 방어적 검증 — 영숫자/하이픈/언더스코어만 허용(락/로그 파일 경로 안전).
if [[ ! "$SESSION" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "[tmux-grid-daemon] ERROR: 세션명에 허용되지 않은 문자 포함 — ${SESSION}" >&2
  exit 1
fi

DAEMON_LOCK_FILE="/tmp/tmux-grid-daemon-${SESSION}.lock"
LOG_FILE="/tmp/tmux-grid-daemon-${SESSION}.log"

# stale lock 자가 회수 (2026-08-25 추가 — 근본 원인: 데몬 bash 프로세스가
# 크래시하면 그 자식인 "tmux -C attach-session" 클라이언트만 고아로 남아
# flock FD를 상속받은 채 락을 영구 점유한다. 이 상태에서는 session-created
# hook이 재기동을 시도해도 flock -n이 매번 즉시 실패해 아무도 %layout-change를
# 처리하지 못하는 채로 방치된다(실세션 실측 확인, 2026-08-25).
# 판정 원칙(fail-safe): 락을 점유 중인 PID들 중 하나라도 "tmux-grid-daemon.sh를
# 실행 중인 살아있는 bash 프로세스"로 확인되면 정상 데몬으로 간주해 절대 건드리지
# 않는다. 그 흔적이 전혀 없을 때만(고아 tmux client 또는 판별 불가 프로세스만
# 존재) stale로 판정해 회수한다. 무관 프로세스 오살 방지가 최우선이므로,
# 판정이 조금이라도 애매하면(cmdline 조회 실패 등) 정상 데몬 쪽으로 기울여
# 회수를 포기하고 경고 후 종료한다(무한 재시도 금지, 1회만 시도).
_stale_lock_recover() {
  local lock_file="$1"
  local pids pid found_live_daemon cmdline

  command -v fuser >/dev/null 2>&1 || return 1  # fuser 자체가 없으면 판별 불가 — 회수 포기(fail-safe)

  pids=$(fuser "$lock_file" 2>/dev/null)
  [[ -z "$pids" ]] && return 1  # 점유자 없음(레이스로 이미 해제됐을 수 있음) — 호출자가 flock 재시도

  found_live_daemon=0
  local to_kill=()
  for pid in $pids; do
    # exec N>"$lock_file"은 flock 획득 여부와 무관하게 파일을 여는 것만으로도
    # fuser 목록에 자기 자신(PID $$)이 포함시킨다(실측 확인). 자기 자신의
    # cmdline은 항상 tmux-grid-daemon.sh를 포함하므로 검사 대상에서 제외하지
    # 않으면 매번 "정상 데몬 발견"으로 오판해 회수가 영구히 동작하지 않는다.
    [[ "$pid" == "$$" ]] && continue
    if [[ ! -r "/proc/${pid}/cmdline" ]]; then
      # 조회 시점에 이미 사라진 PID — 죽은 프로세스이므로 stale 판정에 영향 없음(kill 대상도 아님).
      continue
    fi
    cmdline=$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null)
    if [[ "$cmdline" == *"tmux-grid-daemon.sh"* ]]; then
      # 살아있는 정상 데몬 흔적 발견 — 즉시 회수 중단(fail-safe 최우선 조건).
      found_live_daemon=1
      break
    elif [[ "$cmdline" == *"tmux -C attach"* ]]; then
      # 고아 tmux client로 판정 — kill 후보.
      to_kill+=("$pid")
    else
      # 판별 불가(예상 밖 cmdline) — 지시에 따라 kill 후보에 포함하되, 정상
      # 데몬 흔적이 하나라도 나오면 위 break로 전체 회수가 취소되므로 안전하다.
      to_kill+=("$pid")
    fi
  done

  if [[ $found_live_daemon -eq 1 ]]; then
    return 1  # 정상 데몬 생존 확인 — 회수하지 않음(호출자는 중복 기동으로 처리)
  fi

  if [[ ${#to_kill[@]} -eq 0 ]]; then
    return 1  # kill 대상 없음(전부 이미 사라짐) — 호출자가 flock 재시도
  fi

  echo "[tmux-grid-daemon] WARN: stale lock 감지 — 고아 프로세스 회수 시도 (PID: ${to_kill[*]})" >&2
  kill "${to_kill[@]}" 2>/dev/null
  return 0
}

# 데몬 우선권 확보(2026-08-25 추가) — 12개 팀에이전트 동시 spawn 등 CPU
# 포화 상황에서도 데몬이 %layout-change/폴링 처리를 최대한 즉시 수행할 수
# 있도록 nice 값을 낮춘다. 권한 부족(비루트) 시 실패해도 무해하므로 무시한다.
renice -n -5 -p $$ 2>/dev/null || true

# 세션당 데몬 1개 — 논블로킹 flock으로 중복 기동 시 2번째 인스턴스를
# 즉시 종료시킨다(대기 없음, -n).
exec 8>"$DAEMON_LOCK_FILE"
if ! flock -n 8; then
  if _stale_lock_recover "$DAEMON_LOCK_FILE"; then
    # 회수 시도(kill) 성공 — 짧게 대기 후 단 1회만 재시도(무한 재시도 금지).
    sleep 0.3 2>/dev/null || true
    if ! flock -n 8; then
      echo "[tmux-grid-daemon] ERROR: stale lock 회수 후에도 flock 재획득 실패 — 종료" >&2
      exit 0
    fi
    echo "[tmux-grid-daemon] INFO: stale lock 회수 성공 — 신규 데몬 기동" >&2
  else
    echo "[tmux-grid-daemon] INFO: 세션 ${SESSION}에 데몬이 이미 실행 중 — 즉시 종료" >&2
    exit 0
  fi
fi

# apply_grid()는 awk fast path 실패(파싱 불가 등) 시 폴백 경로로만 사용한다.
# 계산 알고리즘(COLS 결정/체크섬/pane 정렬 등)은 원본 스크립트에서 무변경.
export TMUX_GRID_LIB_ONLY=1
# shellcheck source=${HARNESS_HOME:-$HOME/.harness}/current/scripts/tmux-main-tiled.sh
source ${HARNESS_HOME:-$HOME/.harness}/current/scripts/tmux-main-tiled.sh

# awk fast path 프로그램 경로 — %layout-change가 이미 담고 있는 레이아웃
# 문자열만으로 tmux 재조회 없이 목표 레이아웃을 계산한다(pane별 서브셸 fork
# 수십 회를 없애 pane 수 무관 20~30ms대 교정을 목표로 함).
GRID_FASTPATH_AWK="${HARNESS_HOME:-$HOME/.harness}/current/scripts/tmux-grid-fastpath.awk"

# 대상 세션 실존 확인 — session-created hook 경유 시 항상 존재하나
# 수동 기동 대비 방어적으로 확인한다.
if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "[tmux-grid-daemon] WARN: 세션 ${SESSION} 부재 — 종료" >&2
  exit 0
fi

# 직전 우리가 적용한 레이아웃 기억(스칼라 2개 — bash 배열 미사용).
# 이 값과 동일한 %layout-change 알림은 우리 자신이 유발한 이벤트이므로
# apply_grid() 호출 없이 즉시 건너뛴다(1차 필터).
LAST_APPLIED_WINDOW_ID=""
LAST_APPLIED_LAYOUT=""

# 자발 점검(폴링)용 상태 — CPU 포화로 %layout-change 알림 자체가 수 초
# 지연되는 상황(12개 팀에이전트 동시 spawn 실측 최대 3초 지연)에 대비해
# read 타임아웃마다 마지막으로 처리한 윈도우를 스스로 재조회한다. 처리한
# 윈도우가 아직 없으면(데몬 기동 직후) 스킵한다.
LAST_SEEN_WINDOW_ID=""

# read -t 타임아웃 시 그 시점까지 읽은 부분 라인은 bash가 지정 변수(LINE)에
# 남기지만, 다음 read 호출은 그 변수를 처음부터 덮어쓴다(이어붙이지 않음 —
# bash 5.2 실측 확인, 2026-08-25). 파이프 경계와 무관하게 온전한 한 줄을
# 조립하기 위해 타임아웃마다 부분 조각을 이 버퍼에 직접 이어붙인다.
PENDING_BUF=""

# control mode 상주 접속 — ignore-size(다른 클라이언트 크기에 간섭 안 함),
# no-output(pane 실제 내용 불필요, 알림만 수신)으로 최소 침습 접속한다.
# stdin에 EOF가 도달하는 즉시 tmux -C 클라이언트가 %exit로 스스로 detach하는
# 것이 공식 동작(man tmux CONTROL MODE — stdin으로 명령을 받는 구조이므로
# EOF를 "더 이상 보낼 명령 없음"으로 해석)이다. 백그라운드로 기동될 때
# (setsid/nohup 등) stdin이 /dev/null이나 즉시 EOF되는 소스로 연결되면
# attach 직후 곧바로 종료되어 상주가 성립하지 않는다(실측 확인 완료).
# FD 9를 익명 파이프의 읽기+쓰기 양끝으로 동시에 열어(<>) 절대 EOF되지
# 않는 stdin을 공급한다 — 별도 helper 프로세스(tail -f 등) 없이 데몬
# 자신의 FD만으로 해결되므로 프로세스 누수가 없다. 데몬은 이 스트림으로
# 명령을 보낼 필요가 없으므로 빈 파이프로 충분하다.
exec 9<> <(:)
tmux -C attach-session -t "$SESSION" -f ignore-size,no-output <&9 2>>"$LOG_FILE" |
while true; do
  # read -t 1: CPU 포화로 %layout-change 알림이 지연되는 동안에도 최대 1초
  # 마다 깨어나 자발 점검(폴링)을 수행하기 위한 타임아웃이다. 반환코드로
  # 정상 라인 수신(rc=0) / 타임아웃(rc>128, 128+SIGALRM) / EOF(그 외, 보통
  # rc=1)를 구분해야 한다 — 혼동하면 데몬이 즉시 죽거나 영원히 종료되지
  # 않는다(2026-08-25 지시사항).
  IFS= read -r -t 1 LINE
  RC=$?

  if [[ $RC -gt 128 ]]; then
    # 타임아웃 — 이번에 읽은 부분 조각(있다면 LINE에 담겨 있음)을 버퍼에
    # 이어붙이고, 완전한 라인이 아니므로 이번 반복은 처리 없이 계속한다.
    PENDING_BUF="${PENDING_BUF}${LINE}"

    # 자발 점검: 마지막으로 처리한 윈도우가 아직 없으면(기동 직후) 스킵.
    if [[ -n "$LAST_SEEN_WINDOW_ID" ]]; then
      POLL_LAYOUT=$(tmux display-message -t "$LAST_SEEN_WINDOW_ID" -p '#{window_layout}' 2>/dev/null)
      if [[ -n "$POLL_LAYOUT" ]]; then
        # 기존 %layout-change 처리와 완전히 동일한 코드 경로를 태우기 위해
        # 동일한 형식의 가짜 알림 라인을 합성해 아래 case 처리로 흘려보낸다
        # (코드 중복 없이 단일 처리 경로 유지).
        LINE="%layout-change ${LAST_SEEN_WINDOW_ID} ${POLL_LAYOUT}"
        POLL_SOURCE=1
      else
        continue
      fi
    else
      continue
    fi
  elif [[ $RC -eq 0 ]]; then
    # 정상 라인 수신 — 버퍼에 남아있던 이전 부분 조각과 이어붙여 온전한
    # 라인을 완성한다(버퍼가 비어있으면 그냥 LINE 그대로).
    LINE="${PENDING_BUF}${LINE}"
    PENDING_BUF=""
    POLL_SOURCE=0
  else
    # rc==1 등 — tmux -C attach 파이프 EOF(세션/서버 종료). 기존 종료
    # 경로를 그대로 따른다.
    break
  fi

  case "$LINE" in
    "%layout-change "*)
      WID=$(echo "$LINE" | awk '{print $2}')
      NEW_LAYOUT=$(echo "$LINE" | awk '{print $3}')
      LAST_SEEN_WINDOW_ID="$WID"

      # 1차 필터: 직전 우리가 적용한 레이아웃과 동일하면 자기 자신이
      # 유발한 이벤트이므로 무시한다.
      if [[ "$WID" == "$LAST_APPLIED_WINDOW_ID" && "$NEW_LAYOUT" == "$LAST_APPLIED_LAYOUT" ]]; then
        continue
      fi

      # apply_grid()가 참조하는 윈도우별 전역 변수는 소스 시 1회 계산이
      # 아니라 매 알림마다 이 $WID 기준으로 재계산해야 한다(엣지케이스
      # §9 — LOCK_FILE/LOCKED_LAYOUT_FILE/RESTORING_MARKER/RATE_FILE 4개).
      TMUX_WINDOW_ID="$WID"
      TMUX_TARGET="-t $WID"
      LOCK_FILE="/tmp/tmux-main-tiled-${WID}.lock"
      LOCKED_LAYOUT_FILE="/tmp/tmux-main-tiled-${WID}.lockedlayout"
      RESTORING_MARKER="/tmp/tmux-main-tiled-${WID}.restoring"
      RATE_FILE="/tmp/tmux-main-tiled-${WID}.ratecount"

      # 2차 필터: 초당 실행 횟수 상한(기존 함수 재사용, source로 이미 로드됨).
      check_rate_limit || continue

      T_START_MS=$(date +%s%3N)

      # awk fast path: %layout-change가 이미 담고 있는 NEW_LAYOUT 문자열만으로
      # 목표 레이아웃을 계산한다. tmux 재조회/서브셸 fork가 전혀 없다.
      # 출력이 비어 있으면 두 가지 경우 — (a) 이미 올바른 격자(좌표 멀티셋
      # 동등 — awk 안에서 판정, 가장 흔한 경우이자 진짜 조기 종료 대상)이거나
      # (b) 파싱 실패(윈도우 크기/pane 패턴 미검출 등, AGENTS<=1/COLS<2 등
      # apply_grid()도 손대지 않는 케이스 포함). 두 경우 모두 select-layout을
      # 호출할 필요가 없으므로 동일하게 처리해도 안전하다 — 다만 (b)가 실제
      # 파싱 실패인지는 구분할 수 없으므로, 폴백 경로 apply_grid()로 이중화
      # 하지 않고 "출력 없음=조치 불필요"로 신뢰한다(awk가 실패하는 유일한
      # 입력 형태는 tmux 프로토콜 자체가 바뀌는 경우뿐이며, 그때는 체크섬
      # 계산이 원본과 동일한 로직이므로 실패 양상도 원본과 동일하게 나타난다).
      FASTPATH_RAW=$(awk -f "$GRID_FASTPATH_AWK" -v LAYOUT="$NEW_LAYOUT" 2>>"$LOG_FILE")
      # 출력 형식: "체크섬,레이아웃문자열|MAIN_ID|MAIN_W" (awk 참조 — tmux-grid-fastpath.awk 8단계)
      FASTPATH_OUT=$(echo "$FASTPATH_RAW" | awk -F'|' '{print $1}')
      FASTPATH_MAIN_ID=$(echo "$FASTPATH_RAW" | awk -F'|' '{print $2}')
      FASTPATH_MAIN_W=$(echo "$FASTPATH_RAW" | awk -F'|' '{print $3}')

      # select-layout 사전 재검증 (2026-08-26 추가/수정 — tmux 3.6a SIGSEGV
      # 재발방지, L-461 참조). awk가 계산을 마친 시점과 select-layout을 실제로
      # 투입하는 시점 사이에도 pane 추가/삭제 레이스가 발생할 수 있다(실측:
      # "have N panes but need M" 오류, evidence/crash_20260826/daemon_logs).
      #
      # v2(수정) — 최초 구현(개수만 비교)은 "pane이 죽고 다른 pane이 새로
      # 생겨 개수는 같지만 목표 문자열 속 pane ID 일부가 이미 사라진" 케이스를
      # 잡지 못했다(실측 확인: 존재하지 않는 pane ID를 담은 레이아웃을
      # select-layout에 투입하면 "invalid layout" 에러로 exit 1 — 개수는
      # 맞아도 실패함, 2026-08-26 회귀 디버깅). 개수 비교는 이 실패를 전혀
      # 감지하지 못해 skip_pane_mismatch가 0건인 채로 select-layout 실패만
      # 반복되는 회귀가 실사고로 재현됐다(격자 미형성 상태 유지 + circuit
      # 카운터가 5초 창을 못 채워 산발적으로 리셋).
      # ⇒ 개수가 아니라 "목표 문자열의 pane ID 집합"과 "현재 tmux pane ID
      # 집합"이 정확히 같은 멀티셋인지로 재검증한다. ID까지 일치해야
      # select-layout이 절대 "invalid layout"으로 실패하지 않는다(둘 다
      # 정렬 후 문자열 비교 — 순서 무관하게 원소 집합만 같으면 통과).
      FASTPATH_PANE_IDS=""
      if [[ -n "$FASTPATH_OUT" ]]; then
        FASTPATH_PANE_IDS=$(grep -oE '[0-9]+x[0-9]+,[0-9]+,[0-9]+,[0-9]+' <<< "$FASTPATH_OUT" | awk -F',' '{print $NF}' | sort -n | tr '\n' ' ')
      fi
      CUR_PANE_IDS=$(tmux list-panes $TMUX_TARGET -F '#{pane_id}' 2>/dev/null | tr -d '%' | sort -n | tr '\n' ' ')
      if [[ -n "$FASTPATH_OUT" && "$FASTPATH_PANE_IDS" != "$CUR_PANE_IDS" ]]; then
        printf '%s wid=%s elapsed_ms=0 path=skip_pane_mismatch fastpath=[%s] cur=[%s]\n' \
          "$(date '+%Y-%m-%d %H:%M:%S')" "$WID" "$FASTPATH_PANE_IDS" "$CUR_PANE_IDS" >> "$LOG_FILE"
        FASTPATH_OUT=""
      fi

      # 서킷브레이커 (2026-08-26 추가 — L-461 참조): select-layout 실패(비정상
      # 종료코드)가 짧은 시간 내 반복되면 반복 실패 자체가 tmux 서버를 두드리는
      # 것을 막기 위해 해당 윈도우 교정을 일시 중단한다. 카운터는 데몬 상주
      # 메모리 변수로 충분하다(윈도우별 배열 미사용 — bash 배열 대신 개별
      # 변수로 통일된 이 파일의 기존 스타일에 맞춤. 데몬은 세션당 1개이고
      # 대부분 세션은 윈도우 1개이므로 전역 카운터로도 실효성이 있다).
      CIRCUIT_NOW_MS=$(date +%s%3N)
      if [[ -n "$CIRCUIT_OPEN_UNTIL_MS" && $CIRCUIT_NOW_MS -lt $CIRCUIT_OPEN_UNTIL_MS ]]; then
        printf '%s wid=%s elapsed_ms=0 path=circuit_open remain_ms=%s\n' \
          "$(date '+%Y-%m-%d %H:%M:%S')" "$WID" "$(( CIRCUIT_OPEN_UNTIL_MS - CIRCUIT_NOW_MS ))" >> "$LOG_FILE"
        FASTPATH_OUT=""
      fi

      if [[ -n "$FASTPATH_OUT" ]]; then
        if tmux select-layout $TMUX_TARGET "$FASTPATH_OUT" 2>>"$LOG_FILE"; then
          CIRCUIT_FAIL_COUNT=0
          # 메인 pane 폭 재고정 — apply_grid() 4단계와 동일 동작(select-layout 직후
          # 메인 폭이 근사치로 흔들릴 수 있어 명시 폭으로 재고정한다).
          [[ -n "$FASTPATH_MAIN_ID" && -n "$FASTPATH_MAIN_W" ]] && tmux resize-pane -t "%${FASTPATH_MAIN_ID}" -x "$FASTPATH_MAIN_W" 2>>"$LOG_FILE"
          FINAL_LAYOUT=$(tmux display-message $TMUX_TARGET -p '#{window_layout}' 2>/dev/null)
          if [[ -n "$FINAL_LAYOUT" ]]; then
            printf '%s|%s|%s\n' "$FINAL_LAYOUT" "$(tmux list-panes $TMUX_TARGET 2>/dev/null | wc -l)" "$(date +%s)" > "$LOCKED_LAYOUT_FILE"
            LAST_APPLIED_WINDOW_ID="$WID"
            LAST_APPLIED_LAYOUT="$FINAL_LAYOUT"
          fi
        else
          # select-layout 비정상 종료(exit != 0) — 실패 시각을 기록해두고
          # 최근 실패들이 5초 내 3회 누적되면 서킷을 60초간 연다. 시각 배열은
          # 최대 CIRCUIT_FAIL_WINDOW_SEC개만 유지하면 되므로 3칸 순환 변수로
          # 충분하다(이 파일의 스칼라 변수 스타일 유지 — bash 배열 미사용).
          CIRCUIT_FAIL_COUNT=$(( ${CIRCUIT_FAIL_COUNT:-0} + 1 ))
          CIRCUIT_FAIL_FIRST_MS="${CIRCUIT_FAIL_FIRST_MS:-$CIRCUIT_NOW_MS}"
          if [[ $(( CIRCUIT_NOW_MS - CIRCUIT_FAIL_FIRST_MS )) -gt 5000 ]]; then
            # 5초 창을 벗어난 이전 실패는 폐기 — 이번 실패부터 새 창 시작.
            CIRCUIT_FAIL_COUNT=1
            CIRCUIT_FAIL_FIRST_MS=$CIRCUIT_NOW_MS
          fi
          if [[ $CIRCUIT_FAIL_COUNT -ge 3 ]]; then
            CIRCUIT_OPEN_UNTIL_MS=$(( CIRCUIT_NOW_MS + 60000 ))
            CIRCUIT_FAIL_COUNT=0
            CIRCUIT_FAIL_FIRST_MS=""
            printf '%s wid=%s elapsed_ms=0 path=circuit_breaker_open open_until_ms=%s\n' \
              "$(date '+%Y-%m-%d %H:%M:%S')" "$WID" "$CIRCUIT_OPEN_UNTIL_MS" >> "$LOG_FILE"
          fi
        fi
      fi

      T_END_MS=$(date +%s%3N)

      # path 표기: 정상 이벤트 경로면 awk/skip, 자발 점검(폴링) 경로로
      # 처리됐으면 poll로 구분 표기한다(지시사항 — path=poll 로깅).
      if [[ $POLL_SOURCE -eq 1 ]]; then
        LOG_PATH="poll"
      elif [[ -n "$FASTPATH_OUT" ]]; then
        LOG_PATH="awk"
      else
        LOG_PATH="skip"
      fi
      printf '%s wid=%s elapsed_ms=%s path=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$WID" "$(( T_END_MS - T_START_MS ))" "$LOG_PATH" >> "$LOG_FILE"
      ;;
    *)
      # %layout-change 외 다른 알림/응답 블록은 무시한다.
      ;;
  esac
done

# attach 끊김(세션/서버 종료)으로 파이프가 EOF되면 위 루프가 자연 종료되고
# 여기로 내려온다. flock FD(8)는 프로세스 종료 시 커널이 자동 해제한다.
exit 0
