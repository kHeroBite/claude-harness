# %layout-change 알림 문자열(window-layout)을 입력받아 tiled.sh apply_grid()와
# 동일한 격자 목표 레이아웃 문자열을 tmux 재조회 없이 계산하는 awk 프로그램.
#
# 입력: -v LAYOUT="<수신된 window-layout 문자열>" (인자 없이 stdin은 사용하지 않음)
# 출력: 재적용이 필요할 때만 목표 레이아웃(체크섬 포함, "csum,layout" 형식) 1줄을 stdout.
#       이미 올바른 격자 배치이면 아무 출력도 하지 않는다(동등성 조기 종료 — 무한 루프 방지 핵심 가드).
#       파싱 실패(윈도우 크기/PANE ID 미검출 등) 시에도 아무 출력을 하지 않는다
#       (호출자가 폴백 경로 apply_grid()를 실행하도록 위임).
#
# 알고리즘은 tmux-main-tiled.sh apply_grid()를 그대로 이식했다(원본 무변경 — 참조 전용).
#   MAIN_W = max(W*30/100, 40), RIGHT_W = W - MAIN_W - 1
#   COLS: 1..AGENTS 순회, RIGHT_W/COLS>=30 제약 만족 후보 중 ROWS<=H/6인 것 중
#         |COLS-ROWS| 최소(동률 시 큰 COLS). 만족 후보 없으면 폭 허용 최대 COLS.
#   ROW_H=(H-(ROWS-1))/ROWS, 마지막 행 잔여 흡수. 열 폭 RIGHT_W/N_IN_ROW, 마지막 열 잔여 흡수.
#   pane 정렬: 숫자 ID 오름차순 — 최소 ID가 MAIN, 나머지가 AGENTS(오름차순 유지).
#
# 동등성 판정 방식 (중요 — pane ID 순서가 아닌 "좌표 멀티셋"으로 비교):
#   실측 확인(2026-08-25, gdtest 세션): tmux select-layout에 넘긴 문자열의
#   "어느 pane ID가 어느 좌표에 배정되는가"는 우리가 만든 문자열 순서와 무관하게
#   tmux 내부 pane-tree 순회 순서로 재결정된다. 반면 좌표/크기 구조(격자 모양)
#   자체는 항상 그대로 적용되며, 최종 window_layout의 체크섬까지 완전히 수렴한다
#   (동일 pane 집합 + 동일 좌표 목표 문자열이면 tmux가 배정한 결과는 매번 동일).
#   따라서 "입력 레이아웃이 이미 올바른 격자인가"는 pane ID별 좌표 매핑이 아니라
#   "입력에 나타난 좌표(WxH,X,Y) 멀티셋"과 "목표로 계산한 좌표 멀티셋"이 pane 수
#   기준까지 완전히 같은지로 판정해야 한다. pane ID 순서로 문자열 그대로를
#   비교하면 tmux의 내부 재배정 때문에 매번 다르게 나와 불필요한 재적용(경합)이
#   반복될 수 있다.

BEGIN {
    # ord 변환 테이블 — awk에 ord()가 없으므로 sprintf로 사전 구축한다.
    for (i = 0; i < 256; i++) {
        ORD[sprintf("%c", i)] = i
    }

    if (LAYOUT == "") {
        # 입력 없음 — 파싱 실패로 간주, 출력 없이 종료(폴백 위임).
        exit 0
    }

    # ── 1. 윈도우 W/H 파싱 (문자열 선두 "WxH,0,0{...}" 또는 "WxH,0,0,ID") ──
    if (match(LAYOUT, /^[0-9a-f]+,([0-9]+)x([0-9]+),0,0/, HDR) == 0) {
        exit 0
    }
    W = HDR[1] + 0
    H = HDR[2] + 0
    if (W <= 0 || H <= 0) {
        exit 0
    }

    # ── 2. pane 전부 추출: 좌표(WxH,X,Y) + ID 동시 파싱 ──
    # 문법: WxH,X,Y,ID 패턴(리프 pane)에서 좌표와 ID를 함께 뽑는다. ID는 콤마 뒤
    # 숫자이고 뒤에 콤마/}/]가 오거나 문자열 끝(EOF)이다. WxH,X,Y{...}(컨테이너)는
    # 마지막 필드가 ID가 아니라 { 이므로 이 패턴에 걸리지 않는다.
    NPANES = 0
    REST = LAYOUT
    OFFSET = 0
    while (match(REST, /[0-9]+x[0-9]+,[0-9]+,[0-9]+,[0-9]+/)) {
        SEG = substr(REST, RSTART, RLENGTH)
        n = split(SEG, PARTS, ",")
        PID = PARTS[n] + 0
        # 좌표 키(WxH,X,Y) — ID를 뺀 나머지를 그대로 이어붙여 멀티셋 원소로 사용.
        COORD_KEY = PARTS[1]
        for (k = 2; k < n; k++) COORD_KEY = COORD_KEY "," PARTS[k]
        NPANES++
        PANE_IDS[NPANES] = PID
        INPUT_COORD[NPANES] = COORD_KEY
        REST = substr(REST, RSTART + RLENGTH)
    }

    if (NPANES == 0) {
        exit 0
    }

    # ── 3. pane ID 숫자 오름차순 정렬 (중복 제거 — 동일 세그먼트 재매칭 방지) ──
    DEDUP_N = 0
    for (i = 1; i <= NPANES; i++) {
        pid = PANE_IDS[i]
        if (!(pid in SEEN)) {
            SEEN[pid] = 1
            DEDUP_N++
            SORTED[DEDUP_N] = pid
        }
    }
    NPANES = DEDUP_N

    # 단순 삽입 정렬 (pane 수가 적어 O(n^2)로 충분)
    for (i = 2; i <= NPANES; i++) {
        key = SORTED[i]
        j = i - 1
        while (j >= 1 && SORTED[j] > key) {
            SORTED[j+1] = SORTED[j]
            j--
        }
        SORTED[j+1] = key
    }

    if (NPANES <= 1) {
        # apply_grid()도 TOTAL<=1이면 조기 return — 교정 대상 아님, 출력 없음.
        exit 0
    }

    MAIN_ID = SORTED[1]
    AGENTS = NPANES - 1
    for (i = 1; i <= AGENTS; i++) {
        AGENT_IDS[i] = SORTED[i+1]
    }

    # 입력 좌표 멀티셋 카운트 (동등성 판정용 — pane ID 순서 무관, "이 좌표가
    # 몇 번 나타났는가"만 집계한다. dedup 전 매칭 순회 배열을 그대로 사용해도
    # 좌표 카운트 자체에는 영향 없다 — 동일 세그먼트가 두 번 매칭될 일이
    # 없으므로 PANE_IDS 개수와 INPUT_COORD 개수는 항상 1:1이다).
    for (i = 1; i in INPUT_COORD; i++) {
        INPUT_COORD_CNT[INPUT_COORD[i]]++
    }

    # ── 4. MAIN_W / RIGHT_W ──
    MAIN_W = int(W * 30 / 100)
    if (MAIN_W < 40) MAIN_W = 40
    RIGHT_W = W - MAIN_W - 1

    if (AGENTS <= 1) {
        # apply_grid()도 AGENTS<=1이면 메인 폭 고정만 하고 격자 조립(COLS>=2)은
        # 하지 않는다 — 이 fast path는 격자 조립 케이스 전용이므로 폴백 위임.
        exit 0
    }

    # ── 5. COLS 결정 (근사 정방형) ──
    MIN_ROW_H = 6
    MAX_ROWS_BY_H = int(H / MIN_ROW_H)
    if (MAX_ROWS_BY_H < 1) MAX_ROWS_BY_H = 1

    COLS = 0
    BEST_DIFF = -1
    MAX_COLS_BY_W = 1
    for (try_cols = 1; try_cols <= AGENTS; try_cols++) {
        if (int(RIGHT_W / try_cols) < 30) continue
        MAX_COLS_BY_W = try_cols
        try_rows = int((AGENTS + try_cols - 1) / try_cols)
        if (try_rows <= MAX_ROWS_BY_H) {
            diff = try_cols - try_rows
            if (diff < 0) diff = -diff
            if (BEST_DIFF == -1 || diff < BEST_DIFF || (diff == BEST_DIFF && try_cols > COLS)) {
                BEST_DIFF = diff
                COLS = try_cols
            }
        }
    }
    if (COLS == 0) {
        COLS = MAX_COLS_BY_W
    }
    ROWS = int((AGENTS + COLS - 1) / COLS)

    if (COLS < 2) {
        # apply_grid()도 COLS<2면 격자 조립(select-layout) 자체를 하지 않는다
        # (GRID_APPLIED=0으로 남고 메인 폭 재고정만 수행 — 레이아웃 문자열
        # 변경이 없으므로 fast path 대상 아님, 폴백 위임).
        exit 0
    }

    # ── 6. 행별 레이아웃 문자열 조립 (apply_grid()와 동일 좌표 계산) ──
    # 동시에 목표 좌표 멀티셋(TARGET_COORD_CNT)도 함께 집계한다 — 동등성 판정용.
    ROW_H = int((H - (ROWS - 1)) / ROWS)

    # 메인 pane 좌표도 목표 멀티셋에 포함(입력에도 항상 나타나므로 대칭 비교 위해 필요).
    MAIN_COORD = MAIN_W "x" H ",0,0"
    TARGET_COORD_CNT[MAIN_COORD]++

    ROWS_STR = ""
    Y = 0
    for (row = 0; row < ROWS; row++) {
        RH = ROW_H
        if (row == ROWS - 1) RH = H - Y

        N_IN_ROW = 0
        for (col = 0; col < COLS; col++) {
            idx = row * COLS + col
            if (idx < AGENTS) N_IN_ROW++
        }

        CW = int(RIGHT_W / N_IN_ROW)
        X = MAIN_W + 1
        PARTS_STR = ""
        for (col = 0; col < N_IN_ROW; col++) {
            idx = row * COLS + col
            pid = AGENT_IDS[idx + 1]
            THIS_W = CW
            if (col == N_IN_ROW - 1) THIS_W = MAIN_W + 1 + RIGHT_W - X
            CELL_COORD = THIS_W "x" RH "," X "," Y
            TARGET_COORD_CNT[CELL_COORD]++
            PARTS_STR = PARTS_STR CELL_COORD "," pid
            if (col < N_IN_ROW - 1) PARTS_STR = PARTS_STR ","
            X = X + THIS_W + 1
        }

        if (N_IN_ROW == 1) {
            row_cell = AGENT_IDS[row * COLS + 1]
            ROW_STR = RIGHT_W "x" RH "," (MAIN_W + 1) "," Y "," row_cell
        } else {
            ROW_STR = RIGHT_W "x" RH "," (MAIN_W + 1) "," Y "{" PARTS_STR "}"
        }

        ROWS_STR = ROWS_STR ROW_STR
        if (row < ROWS - 1) ROWS_STR = ROWS_STR ","
        Y = Y + RH + 1
    }

    TARGET = W "x" H ",0,0{" MAIN_W "x" H ",0,0," MAIN_ID "," RIGHT_W "x" H "," (MAIN_W + 1) ",0[" ROWS_STR "]}"

    # ── 7. 동등성 조기 종료 ── 입력 좌표 멀티셋과 목표 좌표 멀티셋이 완전히
    # 같으면(원소 종류 + 각 원소 개수 모두 일치) 이미 올바른 격자이므로 재적용
    # 불필요 — 출력 없이 종료한다. tmux가 pane ID를 좌표에 재배정하는 내부
    # 동작 때문에 pane ID 기준 문자열 비교는 신뢰할 수 없어(실측 확인) 좌표
    # 멀티셋 비교로 판정한다.
    INPUT_KEYS = 0
    for (k in INPUT_COORD_CNT) INPUT_KEYS++
    TARGET_KEYS = 0
    for (k in TARGET_COORD_CNT) TARGET_KEYS++

    EQUAL = 1
    if (INPUT_KEYS != TARGET_KEYS) {
        EQUAL = 0
    } else {
        for (k in TARGET_COORD_CNT) {
            if (INPUT_COORD_CNT[k] != TARGET_COORD_CNT[k]) {
                EQUAL = 0
                break
            }
        }
    }

    if (EQUAL) {
        exit 0
    }

    # ── 8. tmux layout_checksum 계산 ──
    CSUM = 0
    LEN = length(TARGET)
    for (i = 1; i <= LEN; i++) {
        c = ORD[substr(TARGET, i, 1)]
        CSUM = int(CSUM / 2) + ((CSUM % 2) * 32768)
        CSUM = CSUM + c
        CSUM = CSUM % 65536
    }
    FULL_TARGET = sprintf("%04x,%s", CSUM, TARGET)

    # 출력 형식: "체크섬,레이아웃문자열|MAIN_ID|MAIN_W" — 호출자(데몬)가 select-layout
    # 적용 후 메인 pane 폭 재고정(resize-pane -x)에 필요한 MAIN_ID/MAIN_W를
    # 재파싱 없이 그대로 쓸 수 있도록 함께 실어 보낸다.
    print FULL_TARGET "|" MAIN_ID "|" MAIN_W
}
