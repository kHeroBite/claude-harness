#!/bin/bash
# 정규식으로 UI 노드를 찾아 탭하는 재시도 래퍼 — uiautomator 빈 덤프(메인 스레드 바쁨·덤프 자체 크래시) 대비 N회 재덤프
# 사용: tapx.sh <노드 정규식> [탭 후 대기초=3] [재시도=3] [재시도 간격초=3]
#   정규식은 madb.sh dump 출력 한 줄에 매칭한다. 예: "Button.*'저장'", "FrameLayout.*'' '홈'"
# 환경변수: madb.sh 와 동일(ADB·SERIAL·OUT). 종료코드 0=탭함, 1=못 찾음(마지막 덤프는 $OUT/tapx_last.txt)
export LC_ALL=C.UTF-8
HERE=$(cd "$(dirname "$0")" && pwd); M="bash $HERE/madb.sh"
OUT=${OUT:-./otest_mobile_out}; mkdir -p "$OUT"
PAT=$1; WAIT=${2:-3}; TRIES=${3:-3}; GAP=${4:-3}
[ -n "$PAT" ] || { echo "사용: tapx.sh <정규식> [대기초] [재시도] [간격초]" >&2; exit 2; }
c=""
for _t in $(seq 1 "$TRIES"); do
  $M dump > "$OUT/tapx_last.txt"
  c=$(grep -aE "$PAT" "$OUT/tapx_last.txt" | head -1 | sed -E 's/^\S+ +\(([0-9]+),([0-9]+)\).*/\1 \2/')
  [ -n "$c" ] && break
  /bin/sleep "$GAP"
done
if [ -n "$c" ]; then
  $M tap $c; /bin/sleep "$WAIT"; echo "tapx 탭: $PAT → ($c)"; exit 0
fi
echo "$(date '+%F %T') tapx 못 찾음: $PAT (덤프 $(wc -l < "$OUT/tapx_last.txt")줄)" | tee -a "$OUT/tapx_fail.log" >&2
exit 1
