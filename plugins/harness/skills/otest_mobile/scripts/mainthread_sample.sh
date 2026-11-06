#!/bin/bash
# 대상 앱 메인 스레드 스택을 N회 샘플링(debuggerd -b, root 필요) — ANR 직전 정지 구간의 프레임을 잡기 위함
# 사용: mainthread_sample.sh [횟수=15] [출력접두=sample]   환경변수: ADB·SERIAL·PKG(필수), OUT
# MONO_DEBUGGERD_GUARD: 대상이 Mono(.NET MAUI/Xamarin) 앱이면 debuggerd -b 를 실행하지 않는다.
#   debuggerd 의 스레드 정지 신호가 Mono 스레드 정지와 충돌해 앱이 SIGABRT(mono-threads.c:223)로 죽는다(실측 2026-10-24).
#   우회: MONO_DEBUGGERD_ALLOW=1 (앱이 죽어도 되는 경우에만). 판별 불가도 거부한다(fail-closed).
export LC_ALL=C.UTF-8
: "${ADB:?}" "${SERIAL:?}" "${PKG:?}"
OUT=${OUT:-./otest_mobile_out}; C=$OUT/anr_catch; mkdir -p "$C"
P=$("$ADB" -s "$SERIAL" shell pidof "$PKG" | tr -d '\r')
[ -n "$P" ] || { echo "프로세스 없음: $PKG" >&2; exit 1; }
# Mono 판별 — 1순위 /proc/<pid>/maps 의 libmonosgen, 2순위 설치 경로 lib/*/libmonosgen*. 출력: mono|notmono|unknown
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
K=$(mono_kind "$P")
if [ "$K" != notmono ] && [ "${MONO_DEBUGGERD_ALLOW:-0}" != 1 ]; then
  echo "⛔ [MONO_DEBUGGERD_GUARD] $PKG 판별=$K — debuggerd -b 를 실행하지 않는다(Mono 앱은 SIGABRT 로 종료됨)." >&2
  echo "   대체 수단: 앱 정체 로그(앱이 남기는 정체/ANR 관련 logcat 태그)·logcat -v threadtime / /proc/$P/task/$P/stat·wchan / ANR 발생 뒤 /data/anr 트레이스·dumpsys dropbox --print data_app_anr / adb bugreport" >&2
  echo "   강행: MONO_DEBUGGERD_ALLOW=1 (앱이 죽어도 되는 경우만)" >&2
  exit 3
fi
for i in $(seq 1 "${1:-15}"); do
  t=$(date +%H:%M:%S.%3N)
  "$ADB" -s "$SERIAL" shell debuggerd -b "$P" 2>/dev/null | tr -d '\r' \
    | awk -v t="$t" -v p="$P" '$0 ~ "sysTid="p"$" {on=1; print "=== " t; next} on && /^"/ {exit} on {print}' \
    | head -60 >> "$C/${2:-sample}.txt"
done
echo "샘플 $C/${2:-sample}.txt"
