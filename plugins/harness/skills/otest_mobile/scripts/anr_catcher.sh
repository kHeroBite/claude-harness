#!/bin/bash
# 대상 앱의 ANR 창이 뜨는 순간 메인 스레드 스택·직전 logcat·lastanr·/data/anr 트레이스를 자동 수집하는 감시기 — stop 파일로 종료
# 사용: anr_catcher.sh [간격초=3]   (백그라운드: nohup bash anr_catcher.sh > /dev/null 2>&1 & disown)
# 환경변수: ADB·SERIAL·PKG(필수), OUT(기본 ./otest_mobile_out) — 결과는 $OUT/anr_catch/, 종료는 touch $OUT/anr_catcher.stop
# 스택 수집(debuggerd -b)은 root(에뮬 userdebug 이미지)에서만 된다. 실기기(user 빌드)는 bugreport 의 /data/anr 트레이스로 대체한다.
export LC_ALL=C.UTF-8
: "${ADB:?}" "${SERIAL:?}" "${PKG:?}"
OUT=${OUT:-./otest_mobile_out}; C=$OUT/anr_catch; mkdir -p "$C"; rm -f "$OUT/anr_catcher.stop"
IV=${1:-3}; last=""
# MONO_DEBUGGERD_GUARD: 대상이 Mono(.NET MAUI/Xamarin) 앱이면 debuggerd -b 를 실행하지 않는다.
#   debuggerd 의 스레드 정지 신호가 Mono 스레드 정지와 충돌해 앱이 SIGABRT(mono-threads.c:223)로 죽는다(실측 2026-10-24).
#   대신 dumpsys dropbox data_app_anr 본문(시스템이 ANR 시 남긴 스택)을 저장한다. 우회: MONO_DEBUGGERD_ALLOW=1. 판별 불가도 거부(fail-closed).
mono_kind() {  # 출력: mono|notmono|unknown — 1순위 maps 의 libmonosgen, 2순위 설치 lib/*/libmonosgen*, 3순위 APK 내부 lib/*/libmonosgen*(extractNativeLibs=false 대응)
  local m p d a r ev=0
  # maps 를 못 읽으면(비 root) 0 이 나오므로 "읽은 줄 수:mono 줄 수" 로 받아 0 의 두 의미를 가른다
  m=$("$ADB" -s "$SERIAL" shell "cat /proc/$1/maps 2>/dev/null | awk '/libmonosgen/{k++} END{print NR\":\"k+0}'" | tr -d '\r')
  case "$m" in *:0|'') ;; *:*) echo mono; return ;; esac
  p=$("$ADB" -s "$SERIAL" shell pm path "$PKG" 2>/dev/null | tr -d '\r' | sed -n 's/^package://p')
  d=$(printf '%s\n' "$p" | head -1 | sed 's#/[^/]*$##')
  if [ -n "$d" ]; then
    [ -n "$("$ADB" -s "$SERIAL" shell "ls $d/lib/*/libmonosgen* 2>/dev/null" | tr -d '\r')" ] && { echo mono; return; }
    [ -n "$("$ADB" -s "$SERIAL" shell "ls $d/lib/*/*.so 2>/dev/null | head -1" | tr -d '\r')" ] && ev=1   # 비 Mono 판정의 적극 근거: 설치 lib 에 다른 .so 가 있다
  fi
  for a in $p; do
    r=$("$ADB" -s "$SERIAL" shell "unzip -l '$a' 2>/dev/null | awk '/lib\\/.*libmonosgen/{k++} END{print NR\":\"k+0}'" | tr -d '\r')
    case "$r" in ''|0:*) ;; *:0) ev=1 ;; *:*) echo mono; return ;; esac   # APK 목록을 읽었고 libmonosgen 이 없으면 근거 확보
  done
  # 비 Mono 확정은 "maps 를 읽었고(0 줄 아님) + 적극 근거(ev)" 일 때만 — 근거가 없으면 unknown(fail-closed)
  case "$m" in 0:*|'') echo unknown ;; *) [ "$ev" = 1 ] && echo notmono || echo unknown ;; esac
}
echo "$(date '+%F %T') 감시 시작 serial=$SERIAL pkg=$PKG" >> "$C/catch.log"
while [ ! -f "$OUT/anr_catcher.stop" ]; do
  f=$("$ADB" -s "$SERIAL" shell dumpsys window 2>/dev/null | tr -d '\r' | grep -a "mCurrentFocus" | grep -a "Not Responding: $PKG" | head -1 | grep -o "Window{[0-9a-f]*")
  if [ -n "$f" ] && [ "$f" != "$last" ]; then
    ts=$(date +%H%M%S); P=$("$ADB" -s "$SERIAL" shell pidof "$PKG" | tr -d '\r')
    K=$(mono_kind "$P")
    if [ "$K" != notmono ] && [ "${MONO_DEBUGGERD_ALLOW:-0}" != 1 ]; then
      { echo "[MONO_DEBUGGERD_GUARD] 판별=$K — debuggerd -b 미실행(Mono 앱은 SIGABRT 로 종료됨). 대체: 아래 dropbox ANR 본문 · 앱 정체 로그(logcat) · /data/anr · adb bugreport. 강행 MONO_DEBUGGERD_ALLOW=1"
        "$ADB" -s "$SERIAL" shell dumpsys dropbox --print data_app_anr 2>/dev/null | tr -d '\r' | tail -400; } > "$C/stack_$ts.txt" 2>&1
    else
      "$ADB" -s "$SERIAL" shell debuggerd -b "$P" > "$C/stack_$ts.txt" 2>&1
    fi
    "$ADB" -s "$SERIAL" logcat -d -v threadtime 2>/dev/null | tr -d '\r' | tail -3000 > "$C/logcat_$ts.txt"
    "$ADB" -s "$SERIAL" shell dumpsys activity lastanr 2>/dev/null | tr -d '\r' | head -40 > "$C/lastanr_$ts.txt"
    # /data/anr 최신 트레이스 이름만 기록(읽기 권한이 없으면 빈 값) — 실기기는 bugreport 로 회수
    "$ADB" -s "$SERIAL" shell "ls -t /data/anr 2>/dev/null | head -3" | tr -d '\r' > "$C/anr_files_$ts.txt"
    echo "$(date '+%F %T') ANR 창 $f pid=$P stack=$(wc -l < "$C/stack_$ts.txt")줄" >> "$C/catch.log"
    last=$f
  fi
  /bin/sleep "$IV"
done
echo "$(date '+%F %T') 감시 종료" >> "$C/catch.log"
