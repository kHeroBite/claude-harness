#!/bin/bash
# tmux-main-tiled.sh — 메인 좌측 1개 + 우측 tiled 격자 배치
# tmux after-split-window / window-layout-changed hook에서 호출
#
# 호출 방식 (tmux.conf):
#   set-hook -g after-split-window \
#     "run-shell 'TMUX_SESSION_ID=#{session_id} TMUX_WINDOW_ID=#{window_id} ${HARNESS_HOME:-$HOME/.harness}/current/scripts/tmux-main-tiled.sh'"
#   set-hook -g window-layout-changed \
#     "run-shell 'TMT_MODE=restore TMUX_SESSION_ID=#{session_id} TMUX_WINDOW_ID=#{window_id} ${HARNESS_HOME:-$HOME/.harness}/current/scripts/tmux-main-tiled.sh'"
#
# 레이스 컨디션 방지 전략 (윈도우별 flock, v3 — 디바운스 sleep 제거):
#   과거에는 after-split 경로에 0.4초 디바운스 + 0.2초 안정화 sleep을 두어
#   같은 순간 몰리는 여러 발동 중 최신 것만 걸러냈다. 지금은 apply_grid()가
#   멱등(같은 상태면 동등성 가드로 즉시 종료)이고 저비용(main-vertical 선적용
#   제거로 수십 ms대)이므로, sleep 없이 이벤트 즉시 flock 획득 → 동등성 확인 →
#   apply_grid 실행으로 처리한다. 여러 인스턴스가 거의 동시에 발동해도 flock이
#   직렬화하고, 뒤에 대기하던 인스턴스는 락 획득 후 동등성 재확인에서 곧장
#   종료하므로 중복 적용이 없다.
#
# 열(COLS) 수 결정 알고리즘 (근사 정방형 우선, 폭 + 높이 동시 고려):
#   MIN_ROW_H=6 (각 pane 최소 6행 확보 목표), 열당 최소 폭 30컬럼 제약을
#   지키는 COLS 후보(1..AGENTS)를 모두 훑어 ROWS(= ceil(AGENTS/COLS))가
#   "높이가 허용하는 최대 행 수(H/MIN_ROW_H)" 이하인 것들 중 |COLS-ROWS|가
#   가장 작은(가장 정방형에 가까운) COLS를 채택한다(동률이면 더 큰 COLS 우선).
#   어떤 COLS로도 MIN_ROW_H를 못 맞추면(에이전트가 극단적으로 많은 경우)
#   폭이 허용하는 최대 COLS로 강행하고 경고 로그만 남긴다
#   (pane 숨김/kill 등 강제 조치 없음 — 스크롤(history-limit)로 대응).
#
# 즉시 적용 전략 (spawn 진행 중에도 매 pane마다 격자 반영):
#   pane이 추가될 때마다 즉시 그 시점의 pane 수에 맞는 격자를 계산·적용·
#   저장한다. window-layout-changed 고정 hook이 저장본을 즉시 지키므로,
#   tmux나 Claude Code가 배치를 흔들어도 다음 pane 추가 전까지 격자가
#   유지된다. 배치는 2열→3열→4열처럼 단계적으로 바뀌지만 세로로 무너지는
#   요동은 사라진다.
#
# apply_grid() 함수 공유 (자가 치유 아키텍처):
#   격자 계산+적용+저장 로직 전체를 apply_grid() 함수로 추출해 두었다.
#   after-split-window 경로(정상 스케줄링)와 window-layout-changed 복원
#   경로(TMT_MODE=restore, pane 수 불일치 시 재계산)가 이 함수를 동일하게
#   호출한다. 서로 다른 코드가 서로 다른 격자를 만들면 왕복이 재발하므로,
#   단일 함수 공유가 두 경로의 결과를 항상 일치시키는 핵심 장치다.
#   v3: main-vertical 선적용 단계를 제거했다 — 레이아웃 문자열은 pane ID를
#   명시 지정하므로 사전 정규화가 불필요할 뿐 아니라, 교정(restore)이
#   발동할 때마다 화면을 강제로 세로로 만들었다가 다시 격자로 바꾸는 것
#   자체가 교정 스스로 유발하는 깜빡임이었다. MAIN_ID는 좌표 대신 숫자
#   pane ID가 가장 작은 pane(윈도우 최초 생성 pane = 메인)으로 식별하고,
#   에이전트 정렬도 좌표 정렬 대신 숫자 pane ID 오름차순(생성 순서)으로
#   바꿔 교정 간 셀 배치가 흔들리지 않게 했다.
#
# 레이아웃 고정(락) 모드 (window-layout-changed hook, TMT_MODE=restore):
#   격자를 적용할 때마다 그 레이아웃 문자열 + pane 수 + 저장 시각을
#   /tmp/tmux-main-tiled-${WINDOW_ID}.lockedlayout 에 기록해둔다.
#   이후 Claude Code 등 외부 요인이 레이아웃을 바꾸면 window-layout-changed가
#   발동하는데, 이때(TMT_MODE=restore) 저장된 레이아웃과 현재 레이아웃을
#   비교해 다르면 저장본을 즉시 재적용한다.
#   pane 수 불일치 시에는(자가 치유) 저장본을 폐기하는 대신 flock을
#   획득한 뒤 현재 pane 수 기준으로 apply_grid()를 즉시 재계산·적용·저장한다.
#   무한 루프 방지(4중 가드):
#     (1) 재진입 가드 마커(.restoring, 3초 만료) — 계산 시작 전에 세팅
#     (2) 저장본과 현재 레이아웃 및 pane 수가 모두 같으면 아무것도 하지
#         않음(복원/재계산 성공 후 다음 발동은 이 조건으로 자연 종료)
#     (3) 초당 실행 횟수 상한(윈도우당 8회) — 두 경로 공통 카운터.
#         v3: 카운트 시점을 "동등성 가드를 통과해 실제로 tmux를 변경하는
#         직전"으로 옮겼다. 진입 즉시 카운트하면 동등성으로 곧장 종료하는
#         무해한 인스턴스도 예산을 소모해 정작 필요한 교정이 차단될 수
#         있었기 때문이다.
#     (4) after-split/restore-재계산 두 경로가 동일한 LOCK_FILE로 flock을
#         걸어 동시 tmux 조작을 차단한다. after-split은 flock -w 1(짧은
#         대기), restore-재계산도 flock -w 1로 통일했다(v3 — 과거 -n
#         비대기는 실패 시 다음 layout-changed 이벤트까지 교정이 미뤄져
#         세로 상태가 길게 노출되는 원인이었다. sleep 제거로 락 보유
#         시간이 수십~백여 ms대로 줄었으므로 1초 대기로 거의 항상 획득
#         가능하다).
#   락 유효기간 30초 — spawn 버스트 이후 사용자가 수동으로 pane 크기를
#   조절할 여지를 남기기 위해 영구 고정은 하지 않는다.

# 대상 윈도우 결정 (env로 전달받거나 현재 컨텍스트 사용)
TARGET_WINDOW="${TMUX_WINDOW_ID:-}"
if [[ -n "$TARGET_WINDOW" ]]; then
  TMUX_TARGET="-t $TARGET_WINDOW"
else
  TMUX_TARGET=""
fi

# 대상 미확정 가드 — TMUX_TARGET이 비어 있으면 현재 attached 세션이 암묵적
# 대상이 될 위험이 있으므로 첫 tmux 호출 전에 즉시 중단 (exit 0 — hook 체인 보호)
# 단, 데몬(tmux-grid-daemon.sh)이 TMUX_GRID_LIB_ONLY=1로 함수 정의만 재사용하려고
# source할 때는 이 시점에 TMUX_WINDOW_ID를 아직 모르는 것이 정상이므로 가드를
# 우회하고 아래로 계속 진행해 apply_grid()/check_rate_limit() 정의까지 로드한다.
# (실제 window-id는 데몬이 알림을 받을 때마다 함수 호출 직전 전역 변수를
#  재설정하므로, 이 시점의 TMUX_TARGET 값 자체는 사용되지 않는다.)
if [[ -z "$TMUX_TARGET" && "${TMUX_GRID_LIB_ONLY:-}" != "1" ]]; then
  echo "[tmux-main-tiled] WARN: TMUX_WINDOW_ID 미전달 — 대상 불명확으로 중단" >&2
  exit 0
fi

LOCK_FILE="/tmp/tmux-main-tiled-${TMUX_WINDOW_ID:-default}.lock"
LOCKED_LAYOUT_FILE="/tmp/tmux-main-tiled-${TMUX_WINDOW_ID:-default}.lockedlayout"
RESTORING_MARKER="/tmp/tmux-main-tiled-${TMUX_WINDOW_ID:-default}.restoring"
RATE_FILE="/tmp/tmux-main-tiled-${TMUX_WINDOW_ID:-default}.ratecount"
LOCKED_LAYOUT_TTL=30
RESTORING_MARKER_TTL=3
RATE_LIMIT_PER_SEC=8

# 초당 실행 횟수 상한 가드 — 두 진입 경로(after-split-window/restore) 공통.
# 예상 밖 상호작용으로 재진입 마커/동등성 가드를 뚫는 경우의 물리적 최종
# 방어선. 같은 초 안에서 카운트가 임계치를 초과하면 즉시 exit(백오프 —
# 아무 것도 하지 않고 다음 발동에 맡긴다). 반환값 0=통과, 1=초과(호출자가
# exit 0 처리). v3: 실제 mutate(apply_grid 또는 select-layout 복원) 직전에만
# 호출한다 — 동등성 가드로 조기 종료하는 무해한 인스턴스는 카운트하지 않는다.
check_rate_limit() {
  local now_sec rate_prev rate_sec rate_cnt
  now_sec=$(date +%s)
  rate_prev=$(cat "$RATE_FILE" 2>/dev/null || echo "")
  rate_sec=$(echo "$rate_prev" | awk -F':' '{print $1}')
  rate_cnt=$(echo "$rate_prev" | awk -F':' '{print $2}')
  if [[ "$rate_sec" != "$now_sec" ]]; then
    rate_cnt=0
  fi
  rate_cnt=$(( ${rate_cnt:-0} + 1 ))
  printf '%s:%s\n' "$now_sec" "$rate_cnt" > "$RATE_FILE"
  if [[ $rate_cnt -gt $RATE_LIMIT_PER_SEC ]]; then
    return 1
  fi
  return 0
}

# apply_grid() — 격자 계산+적용+저장 전체 로직 (인자 없음, 전역 TMUX_TARGET/
# MAIN_W 등을 직접 참조·계산). after-split-window 경로와 restore 자가 치유
# 경로가 동일하게 호출한다. 반환값 없음(내부에서 필요 시 exit 0으로 종료).
apply_grid() {
  # 현재 윈도우 pane 수
  local TOTAL W H MAIN_W RIGHT_W PANE_LIST MAIN_ID AGENTS
  TOTAL=$(tmux list-panes $TMUX_TARGET 2>/dev/null | wc -l)
  if [[ $TOTAL -le 1 ]]; then
    return 0
  fi

  # 윈도우 크기
  W=$(tmux display-message $TMUX_TARGET -p '#{window_width}' 2>/dev/null)
  H=$(tmux display-message $TMUX_TARGET -p '#{window_height}' 2>/dev/null)

  # 메인 폭: 30% (최소 40칸)
  MAIN_W=$(( W * 30 / 100 ))
  [[ $MAIN_W -lt 40 ]] && MAIN_W=40
  RIGHT_W=$(( W - MAIN_W - 1 ))

  # pane ID 목록 (공백 구분 — bash 배열 미사용). 레이아웃 문자열은 pane ID를
  # 명시 지정하므로 select-layout main-vertical 사전 정규화는 불필요하다
  # (v3 — 제거. 교정마다 화면을 세로로 만들었다가 다시 격자로 바꾸는 것
  # 자체가 깜빡임을 유발했었다).
  # 숫자 pane ID 오름차순(=생성 순서) 정렬 — 좌표 정렬 대신 채택. 좌표는
  # 매 교정마다 현재 레이아웃에 좌우되어 셀-pane 매핑이 흔들릴 수 있지만,
  # pane ID는 생성 후 불변이므로 교정을 반복해도 같은 pane이 같은 셀에
  # 배치되어 시각적으로 안정된다.
  PANE_LIST=$(tmux list-panes $TMUX_TARGET -F '#{pane_id}' 2>/dev/null | sed 's/^%//' | sort -n | sed 's/^/%/' | tr '\n' ' ')
  MAIN_ID=$(echo "$PANE_LIST" | awk '{print $1}')
  AGENTS=$(( TOTAL - 1 ))

  # 메인 폭 고정
  tmux resize-pane -t "$MAIN_ID" -x "$MAIN_W" 2>/dev/null

  if [[ $AGENTS -le 1 ]]; then
    return 0
  fi

  # 2단계: 열 수 결정 — 근사 정방형(행≈열) 우선, 폭/높이 제약 충족 후보 중 채택
  # 제약 두 가지: 열당 최소 폭 30컬럼(RIGHT_W/COLS>=30), 행당 최소 높이 MIN_ROW_H.
  # 후보를 COLS=1..AGENTS 순회하며 두 제약을 모두 만족하는 것 중 |COLS-ROWS|가
  # 가장 작은(가장 정방형에 가까운) COLS를 채택한다. 동률이면 더 큰 COLS를 우선한다
  # (가로로 넓은 터미널 특성상 열을 늘리는 쪽이 pane당 가독성에 유리하다는 판단).
  # 만족 후보가 하나도 없으면(에이전트 극단적으로 많은 경우) 기존과 동일하게
  # 폭이 허용하는 최대 COLS로 강행한다.
  local MIN_ROW_H MAX_ROWS_BY_H COLS BEST_DIFF MAX_COLS_BY_W TRY_COLS TRY_ROWS DIFF ROWS
  MIN_ROW_H=6
  MAX_ROWS_BY_H=$(( H / MIN_ROW_H ))
  [[ $MAX_ROWS_BY_H -lt 1 ]] && MAX_ROWS_BY_H=1

  COLS=0
  BEST_DIFF=-1
  MAX_COLS_BY_W=1
  TRY_COLS=1
  while [[ $TRY_COLS -le $AGENTS ]]; do
    if [[ $(( RIGHT_W / TRY_COLS )) -lt 30 ]]; then
      TRY_COLS=$(( TRY_COLS + 1 ))
      continue
    fi
    # 폭 조건을 만족하는 가장 큰 COLS를 폭 허용 최대치로 기록 (강행 폴백용)
    MAX_COLS_BY_W=$TRY_COLS
    TRY_ROWS=$(( (AGENTS + TRY_COLS - 1) / TRY_COLS ))
    if [[ $TRY_ROWS -le $MAX_ROWS_BY_H ]]; then
      DIFF=$(( TRY_COLS - TRY_ROWS ))
      [[ $DIFF -lt 0 ]] && DIFF=$(( -DIFF ))
      if [[ $BEST_DIFF -eq -1 || $DIFF -lt $BEST_DIFF || ( $DIFF -eq $BEST_DIFF && $TRY_COLS -gt $COLS ) ]]; then
        BEST_DIFF=$DIFF
        COLS=$TRY_COLS
      fi
    fi
    TRY_COLS=$(( TRY_COLS + 1 ))
  done

  if [[ $COLS -eq 0 ]]; then
    # 어떤 COLS로도 MIN_ROW_H를 만족 못함 → 폭 허용 최대 COLS로 강행 + 경고 로그
    COLS=$MAX_COLS_BY_W
    echo "[tmux-main-tiled] WARN: MIN_ROW_H(${MIN_ROW_H}) 미달 — AGENTS=${AGENTS} H=${H} COLS=${COLS}로 강행 (스크롤로 대응, history-limit 참조)" >&2
  fi
  ROWS=$(( (AGENTS + COLS - 1) / COLS ))

  # 3단계: 2열 이상이면 커스텀 레이아웃 문자열을 조립해 select-layout 1회로
  # 격자 전체(위치+높이+폭)를 동시 확정 (join-pane 순차 적용 대신 채택 —
  # join-pane 후 resize-pane -x 방식은 인접 경계만 이동시켜 열 폭이
  # 균등해지지 않는 근본 한계가 있었음 — 격리 세션 실측으로 확인됨)
  local AGENT_PANE_STR GRID_APPLIED
  AGENT_PANE_STR=$(echo "$PANE_LIST" | awk '{for(i=2;i<=NF;i++) printf $i" "}')
  GRID_APPLIED=0

  if [[ $COLS -ge 2 ]]; then
    # pane id의 % 접두어 제거 (레이아웃 문자열은 숫자 id만 허용)
    local AGENT_IDS_NUM MAIN_ID_NUM ROW_H ROWS_STR Y ROW RH N_IN_ROW COL IDX CW X PARTS PID THIS_W ROW_CELL ROW_STR LAYOUT CSUM LEN I C FULL_LAYOUT
    AGENT_IDS_NUM=$(echo "$AGENT_PANE_STR" | tr -d '%')
    MAIN_ID_NUM=$(echo "$MAIN_ID" | tr -d '%')

    # 행 높이: 행 사이 구분선(1칸)을 뺀 몫, 마지막 행은 잔여 높이를 흡수
    ROW_H=$(( (H - (ROWS - 1)) / ROWS ))

    ROWS_STR=""
    Y=0
    ROW=0
    while [[ $ROW -lt $ROWS ]]; do
      RH=$ROW_H
      [[ $ROW -eq $(( ROWS - 1 )) ]] && RH=$(( H - Y ))

      # 이 행에 실제로 존재하는 pane 수 계산
      N_IN_ROW=0
      COL=0
      while [[ $COL -lt $COLS ]]; do
        IDX=$(( ROW * COLS + COL ))
        [[ $IDX -lt $AGENTS ]] && N_IN_ROW=$(( N_IN_ROW + 1 ))
        COL=$(( COL + 1 ))
      done

      CW=$(( RIGHT_W / N_IN_ROW ))
      X=$(( MAIN_W + 1 ))
      PARTS=""
      COL=0
      while [[ $COL -lt $N_IN_ROW ]]; do
        IDX=$(( ROW * COLS + COL ))
        PID=$(echo "$AGENT_IDS_NUM" | awk -v k=$(( IDX + 1 )) '{print $k}')
        THIS_W=$CW
        # 행의 마지막 pane은 잔여 폭을 흡수
        [[ $COL -eq $(( N_IN_ROW - 1 )) ]] && THIS_W=$(( MAIN_W + 1 + RIGHT_W - X ))
        PARTS="${PARTS}${THIS_W}x${RH},${X},${Y},${PID}"
        [[ $COL -lt $(( N_IN_ROW - 1 )) ]] && PARTS="${PARTS},"
        X=$(( X + THIS_W + 1 ))
        COL=$(( COL + 1 ))
      done

      if [[ $N_IN_ROW -eq 1 ]]; then
        ROW_CELL=$(echo "$AGENT_IDS_NUM" | awk -v k=$(( ROW * COLS + 1 )) '{print $k}')
        ROW_STR="${RIGHT_W}x${RH},$(( MAIN_W + 1 )),${Y},${ROW_CELL}"
      else
        ROW_STR="${RIGHT_W}x${RH},$(( MAIN_W + 1 )),${Y}{${PARTS}}"
      fi

      ROWS_STR="${ROWS_STR}${ROW_STR}"
      [[ $ROW -lt $(( ROWS - 1 )) ]] && ROWS_STR="${ROWS_STR},"
      Y=$(( Y + RH + 1 ))
      ROW=$(( ROW + 1 ))
    done

    LAYOUT="${W}x${H},0,0{${MAIN_W}x${H},0,0,${MAIN_ID_NUM},${RIGHT_W}x${H},$(( MAIN_W + 1 )),0[${ROWS_STR}]}"

    # tmux 레이아웃 체크섬 계산 (tmux 소스 layout_checksum 알고리즘)
    CSUM=0
    LEN=${#LAYOUT}
    I=0
    while [[ $I -lt $LEN ]]; do
      C=$(printf '%d' "'${LAYOUT:$I:1}")
      CSUM=$(( ((CSUM >> 1) + ((CSUM & 1) << 15)) & 0xffff ))
      CSUM=$(( (CSUM + C) & 0xffff ))
      I=$(( I + 1 ))
    done
    FULL_LAYOUT=$(printf '%04x,%s' "$CSUM" "$LAYOUT")

    # select-layout 투입 직전 pane ID 재검증 (2026-08-26 추가/수정 — tmux 3.6a
    # SIGSEGV 재발방지, L-461 참조. 데몬(tmux-grid-daemon.sh)의 동일 재검증과
    # 폴백 경로 일관성을 맞춘다). 위에서 PANE_LIST 계산 시점의 pane ID 집합과
    # select-layout 투입 직전 실제 pane ID 집합 사이에도 레이스가 발생할 수
    # 있다. v2(수정) — 최초 구현(개수만 비교)은 "pane이 죽고 다른 pane이 새로
    # 생겨 개수는 같지만 레이아웃 문자열 속 pane ID 일부가 이미 사라진" 케이스를
    # 잡지 못한다(실측 확인: 존재하지 않는 pane ID를 담은 레이아웃을
    # select-layout에 투입하면 "invalid layout" 에러로 exit 1 — 개수는 맞아도
    # 실패함). 개수가 아니라 ID 집합(정렬 후 문자열 비교, 순서 무관)이 완전히
    # 같아야 투입한다 — 그래야 "invalid layout" 실패 자체가 발생하지 않는다.
    local RECHECK_IDS EXPECTED_IDS
    RECHECK_IDS=$(tmux list-panes $TMUX_TARGET -F '#{pane_id}' 2>/dev/null | sed 's/^%//' | sort -n | tr '\n' ' ')
    EXPECTED_IDS=$(echo "$PANE_LIST" | tr -d '%' | tr ' ' '\n' | sed '/^$/d' | sort -n | tr '\n' ' ')
    if [[ "$RECHECK_IDS" != "$EXPECTED_IDS" ]]; then
      echo "[tmux-main-tiled] WARN: select-layout 직전 pane ID 불일치(당초 [${EXPECTED_IDS}] → 현재 [${RECHECK_IDS}]) — 이번 적용 스킵, 다음 이벤트에 위임" >&2
    # select-layout 적용 — 실패 시 기존 레이아웃 상태로 폴백
    # (화면이 깨지는 것보다 기존 상태 유지가 낫다는 원칙)
    elif tmux select-layout $TMUX_TARGET "$FULL_LAYOUT" 2>/dev/null; then
      GRID_APPLIED=1
    fi
  fi

  # 4단계: 메인 폭 재고정
  tmux resize-pane -t "$MAIN_ID" -x "$MAIN_W" 2>/dev/null || true
  tmux select-pane -t "$MAIN_ID" 2>/dev/null || true

  # 고정(락) 모드용 저장 — 4단계(메인 폭 재고정)까지 모두 끝난 뒤의 최종
  # 레이아웃을 저장해야 한다. select-layout 직후 바로 저장하면 뒤이은
  # resize-pane이 레이아웃을 한 번 더 바꿔 저장본과 실제가 어긋나고,
  # window-layout-changed가 불필요하게 한 번 더 발동한다. pane 수 + 저장
  # 시각과 함께 기록해 window-layout-changed(TMT_MODE=restore) 경로가
  # 외부 요인으로 흐트러진 레이아웃을 이 문자열로 되돌릴 수 있게 한다.
  if [[ "$GRID_APPLIED" == "1" ]]; then
    local APPLIED_LAYOUT
    APPLIED_LAYOUT=$(tmux display-message $TMUX_TARGET -p '#{window_layout}' 2>/dev/null)
    if [[ -n "$APPLIED_LAYOUT" ]]; then
      printf '%s|%s|%s\n' "$APPLIED_LAYOUT" "$TOTAL" "$(date +%s)" > "$LOCKED_LAYOUT_FILE"
    fi
  fi

  return 0
}

# 라이브러리 전용 로드 가드 — 데몬(tmux-grid-daemon.sh)이 apply_grid()만
# 재사용하려고 TMUX_GRID_LIB_ONLY=1로 source할 때 여기서 반환하고 아래
# hook 즉시실행부(after-split/restore 경로)는 건너뛴다. 계산 로직은 무변경.
if [[ "${TMUX_GRID_LIB_ONLY:-}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi

# 데몬 생존 가드 — control mode 상주 데몬(tmux-grid-daemon.sh)이 같은 세션에서
# 가동 중이면 이 hook은 양보하고 즉시 종료한다. 데몬과 hook이 같은 LOCK_FILE을
# 두고 이중 개입하면 flock 경합으로 데몬 교정이 20~46ms → 1116~2120ms까지
# 지연되는 것이 실측되었다(spawn 후반부 이벤트 폭주 구간). 데몬 사망 시에는
# 이 가드를 통과해 기존 hook 경로가 폴백으로 계속 동작한다.
# hook 환경에는 세션 "이름"이 아니라 TMUX_SESSION_ID($15 형태)가 전달되므로
# 세션명을 1회 조회해 데몬 lock 파일명(세션명 기반)을 구성한다.
DAEMON_SESSION_NAME=$(tmux display-message $TMUX_TARGET -p '#{session_name}' 2>/dev/null)
if [[ -n "$DAEMON_SESSION_NAME" ]]; then
  DAEMON_LOCK_FILE="/tmp/tmux-grid-daemon-${DAEMON_SESSION_NAME}.lock"
  if [[ -f "$DAEMON_LOCK_FILE" ]]; then
    # flock 점유 여부로만 생존을 판정한다 — 파일 존재만으로 판정하면 데몬
    # 사망 후 잔존 파일 때문에 폴백까지 함께 죽는다. -n으로 시도해 즉시
    # 잡히면(점유 중이 아니면) 데몬 사망으로 간주하고 폴백을 계속 진행한다.
    # 락을 뺏으면 안 되므로 fd는 곧장 닫는다.
    exec 7<"$DAEMON_LOCK_FILE"
    if flock -n 7; then
      # 점유 획득 성공 = 데몬이 락을 쥐고 있지 않음 = 데몬 사망 → 폴백 계속
      flock -u 7
      exec 7<&-
    else
      # 점유 획득 실패 = 데몬이 락을 쥔 채 생존 중 → hook은 양보하고 종료
      exec 7<&-
      exit 0
    fi
  fi
fi

# ── window-layout-changed 복원 경로 (TMT_MODE=restore) ─────────────
# after-split-window 경로(격자생성)와 완전히 분리된 별도 경로.
# 여기서 exit 하면 아래 일반 경로로 내려가지 않는다.
if [[ "${TMT_MODE:-}" == "restore" ]]; then
  # 재진입 가드 — 내가 방금 select-layout/apply_grid로 복원·재계산 중이면
  # 그 자체가 이 hook을 재발동시키므로, 진행 중 마커가 있으면 즉시 종료
  # (루프 차단 1차).
  if [[ -f "$RESTORING_MARKER" ]]; then
    MARKER_TS=$(cat "$RESTORING_MARKER" 2>/dev/null || echo "0")
    NOW_TS=$(date +%s)
    MARKER_AGE=$(( NOW_TS - MARKER_TS ))
    if [[ $MARKER_AGE -lt $RESTORING_MARKER_TTL ]]; then
      exit 0
    fi
    # TTL 초과 stale 마커 — 프로세스 비정상 종료로 간주하고 정리 후 계속 진행
    rm -f "$RESTORING_MARKER" 2>/dev/null
  fi

  # 저장본 없으면 고정 대상 아님 — 아무것도 하지 않고 종료
  [[ -f "$LOCKED_LAYOUT_FILE" ]] || exit 0

  SAVED=$(cat "$LOCKED_LAYOUT_FILE" 2>/dev/null || echo "")
  SAVED_LAYOUT=$(echo "$SAVED" | awk -F'|' '{print $1}')
  SAVED_PANES=$(echo "$SAVED" | awk -F'|' '{print $2}')
  SAVED_TS=$(echo "$SAVED" | awk -F'|' '{print $3}')

  if [[ -z "$SAVED_LAYOUT" || -z "$SAVED_PANES" || -z "$SAVED_TS" ]]; then
    rm -f "$LOCKED_LAYOUT_FILE" 2>/dev/null
    exit 0
  fi

  # 락 만료(30초) — 폐기하고 종료 (영구 고정 방지, 수동 조절 허용)
  NOW_TS=$(date +%s)
  LOCK_AGE=$(( NOW_TS - SAVED_TS ))
  if [[ $LOCK_AGE -ge $LOCKED_LAYOUT_TTL ]]; then
    rm -f "$LOCKED_LAYOUT_FILE" 2>/dev/null
    exit 0
  fi

  # pane 수 불일치 — 저장본이 더 이상 유효하지 않으므로(자가 치유) 폐기
  # 대신 현재 pane 수 기준으로 즉시 재계산·적용·저장한다. after-split
  # 경로와 동일 LOCK_FILE로 flock(-w 1)을 걸어 두 경로의 동시 tmux
  # 조작을 차단한다(가드 4). 획득 실패 시 다른 인스턴스가 이미 처리 중이라는
  # 뜻이므로 포기하고 다음 발동에 위임한다(sleep 제거로 락 보유 시간이
  # 짧아져 1초 대기로 거의 항상 획득된다).
  CUR_PANES=$(tmux list-panes $TMUX_TARGET 2>/dev/null | wc -l)
  if [[ "$CUR_PANES" != "$SAVED_PANES" ]]; then
    exec 9>"$LOCK_FILE"
    if ! flock -w 1 9; then
      exit 0
    fi

    # flock 획득 후 재확인 — 대기 중 다른 인스턴스가 이미 저장본을
    # 갱신했을 수 있으므로, SAVED_PANES가 이미 CUR_PANES와 같아졌으면
    # 재계산 없이 종료(중복 적용 방지, rate-limit 카운트도 하지 않음).
    SAVED2=$(cat "$LOCKED_LAYOUT_FILE" 2>/dev/null || echo "")
    SAVED_PANES2=$(echo "$SAVED2" | awk -F'|' '{print $2}')
    if [[ "$SAVED_PANES2" == "$CUR_PANES" ]]; then
      exit 0
    fi

    # 초당 실행 횟수 상한 (가드 3) — 동등성 가드를 통과해 실제로 mutate하기
    # 직전에만 카운트한다.
    check_rate_limit || exit 0

    # 재진입 마커를 계산 시작 전에 세운다 — apply_grid()는 여러 tmux 호출을
    # 순차 실행하므로(pane 목록 조회 → resize-pane → select-layout 격자 →
    # resize-pane), 그 중간 상태마다 window-layout-changed가 재귀 발동할
    # 수 있다. 계산 시작 전부터 마커를 세워 중간 재귀를 전부 차단한다
    # (루프 차단 2차/시점 조정).
    date +%s > "$RESTORING_MARKER"
    apply_grid
    rm -f "$RESTORING_MARKER" 2>/dev/null
    exit 0
  fi

  # 현재 레이아웃과 저장본이 같으면 아무 것도 하지 않는다 (루프 차단 — 가장
  # 핵심적인 종료 조건. 복원/재계산이 성공하면 다음 발동 시 이 분기로 빠져
  # 자연스럽게 멈춘다).
  CUR_LAYOUT=$(tmux display-message $TMUX_TARGET -p '#{window_layout}' 2>/dev/null)
  if [[ "$CUR_LAYOUT" == "$SAVED_LAYOUT" ]]; then
    exit 0
  fi

  # 여기까지 왔으면 pane 수는 동일하되 레이아웃만 어긋난 상태 — 저장본으로
  # 복원한다. 초당 상한 확인 후 마커를 먼저 세워 복원 자체가 유발하는 재귀
  # 발동을 차단하고, 복원 후에는 성공/실패 무관 마커를 반드시 지운다.
  check_rate_limit || exit 0
  date +%s > "$RESTORING_MARKER"
  tmux select-layout $TMUX_TARGET "$SAVED_LAYOUT" 2>/dev/null || true
  rm -f "$RESTORING_MARKER" 2>/dev/null
  exit 0
fi

# ── after-split-window 일반 경로 (v3 — 디바운스/안정화 sleep 제거) ──────
# apply_grid()가 멱등+저비용이므로 이벤트 즉시 flock 획득 → apply_grid
# 실행으로 처리한다. 여러 인스턴스가 몰려도 flock이 직렬화하며, 락 획득
# 후 대기 인스턴스는 곧바로 apply_grid를 실행(현재 pane 수 기준이므로
# 뒤늦게 실행되어도 최신 상태를 반영— 결과적으로 최신 인스턴스의 작업과
# 동일하거나 즉시 동등성에 수렴).
exec 9>"$LOCK_FILE"
if ! flock -w 1 9; then
  exit 0
fi

# 초당 실행 횟수 상한 (가드 3) — restore 경로와 공통 카운터. 실제로
# tmux를 변경하는 apply_grid 직전에만 카운트한다.
check_rate_limit || exit 0

# ── 실제 레이아웃 적용 (공유 함수 호출) ────────────────────────────
apply_grid

exit 0
