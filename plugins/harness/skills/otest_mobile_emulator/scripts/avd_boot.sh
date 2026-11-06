#!/bin/bash
# AVD 를 지정 포트·메모리로 기동하고 boot_completed 까지 기다린다 — 다중 AVD 병렬 기동(포트 분리)과 게스트 메모리 4GB+ 기준 적용
# 사용: avd_boot.sh <AVD이름> [콘솔포트=5554] [메모리MB=4096] [추가 emulator 인자...]
#   병렬: avd_boot.sh phone_avd 5554 & avd_boot.sh tablet_avd 5556 & wait   → 시리얼 emulator-5554 / emulator-5556
#   목록: avd_boot.sh --list
#   기본은 헤드리스(-no-window -no-audio). 창 모드는 첫 인자로 --windowed 를 줄 때만(사용자 명시 요청·헤드리스 실패 실측 시 — otest_mobile_emulator_bg 4절)
# 환경변수: ADB(필수), EMULATOR(emulator 실행 파일, 필수), OUT(기본 ./otest_mobile_out), BOOT_TIMEOUT(초, 기본 240)
export LC_ALL=C.UTF-8
: "${ADB:?}" "${EMULATOR:?EMULATOR 환경변수(emulator 실행 파일) 필요}"
OUT=${OUT:-./otest_mobile_out}; mkdir -p "$OUT"
[ "$1" = "--list" ] && { "$EMULATOR" -list-avds 2>&1 | tr -d '\r'; exit 0; }
WINDOWED=0; [ "$1" = "--windowed" ] && { WINDOWED=1; shift; }
AVD=${1:?AVD 이름 필요}; PORT=${2:-5554}; MEM=${3:-4096}; shift 3 2>/dev/null || shift $#
SER=emulator-$PORT
if "$ADB" devices | tr -d '\r' | grep -q "^$SER[[:space:]]device"; then
  echo "이미 기동됨: $SER ($( "$ADB" -s "$SER" emu avd name 2>/dev/null | tr -d '\r' | head -1 ))"; exit 0
fi
[ "$MEM" -lt 4096 ] && echo "⚠️ 게스트 메모리 ${MEM}MB < 4096 — 저메모리에서 화면 전환 지연·ANR 이 늘어난 실측이 있다(측정값 오염)"
HL="-no-window -no-audio"; [ "$WINDOWED" = 1 ] && { HL=""; echo "⚠️ 창 모드 기동(--windowed) — 사유를 증거에 기록할 것"; }
nohup "$EMULATOR" -avd "$AVD" -port "$PORT" -memory "$MEM" $HL -no-snapshot-save -no-boot-anim "$@" > "$OUT/emu_$PORT.log" 2>&1 &
disown
T=${BOOT_TIMEOUT:-240}; t0=$(date +%s)
while [ $(( $(date +%s) - t0 )) -lt "$T" ]; do
  /bin/sleep 5
  [ "$("$ADB" -s "$SER" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && {
    echo "✅ 부팅 완료 $SER avd=$AVD mem=${MEM}MB $(( $(date +%s) - t0 ))s"
    "$ADB" -s "$SER" shell "wm size; wm density" | tr -d '\r'
    exit 0; }
done
echo "❌ 부팅 시간 초과 ${T}s — $OUT/emu_$PORT.log 확인"; exit 1
