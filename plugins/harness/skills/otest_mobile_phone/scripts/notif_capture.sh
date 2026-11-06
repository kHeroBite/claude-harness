#!/bin/bash
# 실기기 알림(푸시) 수신 확인 — 알림 패널을 펼쳐 캡처하고 dumpsys notification 에서 대상 패키지 알림을 텍스트로 남긴다
# 사용: notif_capture.sh <이름> [본문 정규식]   환경변수: ADB·SERIAL·PKG(필수), OUT·SHOTS(madb.sh 와 동일)
# 결과: $SHOTS/<이름>.png(알림 패널), $OUT/<이름>_notif.txt(대상 패키지 알림 레코드), 종료코드 0=정규식 일치(또는 정규식 없이 1건 이상)
export LC_ALL=C.UTF-8
: "${ADB:?}" "${SERIAL:?}" "${PKG:?}"
HERE=$(cd "$(dirname "$0")/../../otest_mobile/scripts" && pwd)
OUT=${OUT:-./otest_mobile_out}; mkdir -p "$OUT"
S() { "$ADB" -s "$SERIAL" shell "$@" 2>/dev/null | tr -d '\r'; }
NAME=${1:?이름 필요}; PAT=${2:-}
S cmd statusbar expand-notifications; /bin/sleep 2
bash "$HERE/madb.sh" shot "$NAME" >/dev/null
S "dumpsys notification --noredact" | grep -a -A25 "pkg=$PKG" | grep -aE "pkg=|android.title|android.text|android.bigText|when=|channel=" > "$OUT/${NAME}_notif.txt"
S cmd statusbar collapse
n=$(grep -ac "pkg=$PKG" "$OUT/${NAME}_notif.txt")
echo "대상 패키지 알림 $n건 → $OUT/${NAME}_notif.txt"
if [ -n "$PAT" ]; then grep -aqE "$PAT" "$OUT/${NAME}_notif.txt" && { echo "✅ 본문 일치: $PAT"; exit 0; }; echo "❌ 본문 불일치: $PAT"; exit 1; fi
[ "$n" -ge 1 ]
