#!/bin/bash
# 실기기에서 앱을 팝업창(freeform)으로 띄워 창 폭을 강제한다 — 펼친 폴더블 1대로 phone 폭 레이아웃을 검증하기 위한 자동화
# 사용: window_mode.sh popup <L> <T> <R> <B>   팝업창으로 기동 후 지정 사각형(px)으로 크기 조정
#       window_mode.sh bounds                  현재 앱 태스크 모드·경계·앱이 받은 dp(sw/w/h) 출력
#       window_mode.sh full                    팝업창 해제(앱 force-stop 후 전체 화면 재기동)
# 환경변수: ADB·SERIAL·PKG·ACT(필수)
# 실측 근거(Android 16 폴더블 펼침): am start --windowingMode 5 → mode=freeform, am task resize 로 경계 지정 가능,
#   am start --windowingMode 1 로는 기존 태스크가 전체 화면으로 돌아오지 않았고 force-stop 후 재기동해야 fullscreen 이 됐다.
#   두 앱 분할 화면(split-screen)은 adb 로 진입하는 표준 명령을 확인하지 못했다 — 필요하면 사용자 1회 수동 배치.
export LC_ALL=C.UTF-8
: "${ADB:?}" "${SERIAL:?}" "${PKG:?}" "${ACT:?}"
S() { "$ADB" -s "$SERIAL" shell "$@" 2>/dev/null | tr -d '\r'; }
task_id() { S "dumpsys activity activities" | grep -a "Task{.*A=[0-9]*:$PKG" | head -1 | sed -E 's/.*#([0-9]+) .*/\1/'; }
bounds() {
  S "dumpsys activity activities" | grep -a -A1 "Task{.*A=[0-9]*:$PKG" | head -2
  S "dumpsys activity activities" | grep -a -A30 "Task{.*A=[0-9]*:$PKG" | grep -a "mLastReportedConfiguration" | head -1 \
    | grep -oE "sw[0-9]+dp w[0-9]+dp h[0-9]+dp|mWindowingMode=[a-z-]+" | head -2
}
case "$1" in
  popup)
    [ $# -eq 5 ] || { echo "사용: window_mode.sh popup L T R B" >&2; exit 2; }
    S am start --windowingMode 5 -n "$PKG/$ACT" >/dev/null; /bin/sleep 3
    T=$(task_id); [ -n "$T" ] || { echo "태스크 없음 — 팝업창 기동 실패"; exit 1; }
    S am task resize "$T" "$2" "$3" "$4" "$5"; /bin/sleep 2
    bounds
    S "dumpsys activity activities" | grep -a "Task{.*A=[0-9]*:$PKG" | head -1 | grep -q "mode=freeform" \
      && echo "✅ 팝업창 적용 — 앱 로그의 레이아웃 판정 폭(dp)으로 phone 폭 진입을 교차 확인하라" \
      || { echo "❌ freeform 아님 — 사용자 1회 수동(최근 앱 → 팝업 보기/분할 화면) 요청"; exit 1; }
    ;;
  bounds) bounds ;;
  full)
    S am force-stop "$PKG"; /bin/sleep 1; S am start -n "$PKG/$ACT" >/dev/null; /bin/sleep 3
    n=$(S "dumpsys activity activities" | grep -a "Task{.*A=[0-9]*:$PKG" | grep -ac "mode=freeform")
    [ "$n" = 0 ] && echo "✅ 전체 화면 복귀" || { echo "❌ freeform 잔존 $n"; exit 1; }
    ;;
  *) echo "사용: window_mode.sh popup L T R B | bounds | full" >&2; exit 2 ;;
esac
