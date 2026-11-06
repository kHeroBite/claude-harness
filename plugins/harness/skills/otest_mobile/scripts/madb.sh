#!/bin/bash
# 단일 기기 adb 조작 헬퍼 — 캡처·UI 덤프·탭·입력·로그 (실기기·에뮬 공용, 프로젝트 고유값은 환경변수)
# 필수 환경변수: ADB(adb 실행 파일), SERIAL(대상 시리얼), PKG(패키지), ACT(메인 액티비티)
# 선택 환경변수: OUT(작업 디렉토리, 기본 ./otest_mobile_out), SHOTS(캡처 저장 디렉토리, 기본 $OUT/shots),
#               NO_ANR_WAIT=1(ANR 대화상자 자동 Wait 끔)
# 사용: madb.sh shot <이름> | dump [필터] | tap X Y | text S | key K | swipe X1 Y1 X2 Y2 [ms]
#       start | stop | clear | logc | log <정규식> [줄수] | fatal | sh <셸명령...> | login <ID> <X> <Y> [PW]
#       kb (키보드 표시 여부 true/false) | kbhide (떠 있을 때만 ESC→재판정→남으면 BACK)
# 소프트키보드 가드(otest_mobile L21/22): text·login 끝, shot·tap 직전에 kbhide 를 자동 실행한다.
#   키보드 자체를 찍거나 입력창 탭으로 키보드를 띄우는 단계만 KB_KEEP=1 로 끈다.
export LC_ALL=C.UTF-8
: "${ADB:?ADB 환경변수 필요}" "${SERIAL:?SERIAL 환경변수 필요}"
OUT=${OUT:-./otest_mobile_out}; SHOTS=${SHOTS:-$OUT/shots}
mkdir -p "$OUT" "$SHOTS"
A() { "$ADB" -s "$SERIAL" "$@" 2>&1 | tr -d '\r'; }
# 키보드 표시 판정 — 기기·안드로이드 버전마다 키 이름이 달라 우선순위로 흡수한다.
#   mInputShown → mIsInputViewShown → isInputViewShown → mDecorViewVisible(마지막 수단). 하나도 없으면 unknown.
kb_shown() {
  local d k v
  d=$(A shell dumpsys input_method)
  for k in mInputShown mIsInputViewShown isInputViewShown mDecorViewVisible; do
    v=$(printf '%s\n' "$d" | grep -aoE "\b$k=(true|false)" | head -1 | cut -d= -f2)
    [ -n "$v" ] && { echo "$v"; return 0; }
  done
  echo unknown
}
# 떠 있을 때만 ESC→(남으면)BACK — 키보드가 없을 때 BACK 은 화면을 닫아 이탈하므로 무조건 BACK 금지.
kb_hide() {
  [ "${KB_KEEP:-0}" = 1 ] && return 0
  local st i
  st=$(kb_shown); [ "$st" = true ] || return 0
  # ESC(111) 먼저 — 화면 이동이 없다. 남아 있으면 BACK(4) 1회(키보드가 떠 있을 때의 BACK 은 키보드만 닫는다).
  for k in 111 4; do
    A shell input keyevent $k >/dev/null; /bin/sleep 1
    st=$(kb_shown); [ "$st" = true ] || return 0
  done
  echo "$(date '+%F %T') ⚠️ 키보드가 내려가지 않음(ESC→BACK) — 이후 캡처·하단 탭은 증거 무효" | tee -a "$OUT/kb_warn.log" >&2
  return 1
}
cmd=$1; shift
case "$cmd" in
  kb) kb_shown ;;
  kbhide) kb_hide; echo "kb=$(kb_shown)" ;;
  shot)  # shot <이름> → $SHOTS/<이름>.png + $OUT/small_<이름>.png(최대변 1100px). 검은 프레임은 최대 4회 재시도
    # 다중 디스플레이(폴더블): -d 없이 찍으면 경고문이 PNG 앞에 섞여 파일이 깨진다 → 활성 디스플레이의 물리 id 를 -d 로 넘긴다.
    #   판별: dumpsys display 의 isActive=true 뷰포트 uniqueId 'local:<id>'. 디스플레이 1개(에뮬 등)면 -d 생략. SHOT_DISPLAY 로 강제 지정 가능.
    kb_hide   # 캡처 직전 가드 — 키보드가 하단을 가린 캡처는 증거 무효(L22)
    DISP=${SHOT_DISPLAY:-}
    if [ -z "$DISP" ] && [ "$(A shell dumpsys SurfaceFlinger --display-id | grep -ac '^Display ')" -gt 1 ]; then
      DISP=$(A shell dumpsys display | grep -ao "isActive=true, displayId=[0-9]*, uniqueId='local:[0-9]*" | head -1 | sed "s/.*local://")
    fi
    for try in 1 2 3 4; do
      "$ADB" -s "$SERIAL" exec-out screencap -p ${DISP:+-d "$DISP"} > "$SHOTS/$1.png"
      # 방어: 그래도 PNG 앞에 텍스트가 섞였으면 PNG 시그니처 이전을 잘라낸다
      python3 -c "
import sys
p=sys.argv[1]; b=open(p,'rb').read(); i=b.find(b'\x89PNG\r\n\x1a\n')
if i>0: open(p,'wb').write(b[i:])" "$SHOTS/$1.png" 2>/dev/null
      MEAN=$(python3 -c "
from PIL import Image, ImageStat
import sys
print(int(ImageStat.Stat(Image.open(sys.argv[1]).convert('L')).mean[0]))" "$SHOTS/$1.png" 2>/dev/null)
      [ "${MEAN:-0}" -ge 5 ] && break
      # 검은 프레임(screencap 일시 현상) — 기기 설정(wm size 등)은 건드리지 않고 대기 후 다시 찍는다
      #   (종전 wm size 2px 흔들기는 실기기 화면 설정을 바꾸는 부작용이 있어 제거 — 사이클172 Fold5 실측)
      /bin/sleep 3
      echo "$(date '+%F %T') black-retry $1 try=$try disp=${DISP:-default}" >> "$OUT/black_retry.log"
    done
    python3 - "$SHOTS/$1.png" "$OUT/small_$1.png" <<'EOF'
import sys
from PIL import Image
im = Image.open(sys.argv[1]); w, h = im.size
s = min(1.0, 1100 / max(w, h)); im.resize((int(w * s), int(h * s))).save(sys.argv[2])
print(sys.argv[1], w, h)
EOF
    ;;
  dump)  # dump [필터] → 텍스트·설명이 있는 노드와 중심 좌표 (빈 덤프 3회 재시도, ANR 대화상자는 Wait 로 닫고 재덤프)
    for _try in 1 2 3; do
      A shell "rm -f /sdcard/ui.xml; uiautomator dump /sdcard/ui.xml" >/dev/null 2>&1
      "$ADB" -s "$SERIAL" exec-out cat /sdcard/ui.xml > "$OUT/ui.xml" 2>/dev/null
      if grep -q "isn't responding" "$OUT/ui.xml" 2>/dev/null && [ "${NO_ANR_WAIT:-0}" != 1 ]; then
        wb=$(python3 -c "
import re,sys
x=open(sys.argv[1],encoding='utf-8',errors='replace').read()
m=re.search(r'text=\"Wait\"[^>]*bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"',x)
print((int(m.group(1))+int(m.group(3)))//2, (int(m.group(2))+int(m.group(4)))//2) if m else print('')" "$OUT/ui.xml")
        echo "$(date '+%F %T') ANR 대화상자 → Wait($wb)" >> "$OUT/anr_wait.log"
        [ -n "$wb" ] && A shell input tap $wb; /bin/sleep 3; continue
      fi
      [ -s "$OUT/ui.xml" ] && break; /bin/sleep 3
    done
    python3 - "$OUT/ui.xml" "$1" <<'EOF'
import re, sys
x = open(sys.argv[1], encoding='utf-8', errors='replace').read()
f = sys.argv[2] if len(sys.argv) > 2 else ''
for m in re.finditer(r'<node [^>]*?text="([^"]*)"[^>]*?class="([^"]*)"[^>]*?content-desc="([^"]*)"[^>]*?checked="([^"]*)"[^>]*?bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', x):
    t, c, d, ck, x1, y1, x2, y2 = m.groups()
    c = c.split('.')[-1]
    if not (t or d or c in ('EditText', 'CheckBox', 'RadioButton', 'Switch', 'Button')):
        continue
    if f and f not in t + d + c:
        continue
    print(f"{c[:12]:12s} ({(int(x1)+int(x2))//2},{(int(y1)+int(y2))//2}) [{x1},{y1}-{x2},{y2}] ck={ck[0]} {t!r} {d!r}")
EOF
    ;;
  tap) kb_hide; A shell input tap "$1" "$2" ;;   # 탭 직전 가드(입력창을 탭해 키보드를 띄우는 단계는 KB_KEEP=1)
  text) A shell input text "$1"; /bin/sleep 1; kb_hide ;;   # 입력 helper 끝에서 내림
  key) A shell input keyevent "$@" ;;
  swipe) A shell input swipe "$1" "$2" "$3" "$4" "${5:-500}" ;;
  start)  # MOBILE_PRESTART_HOOK(선택, 프로젝트 게이트 명령) 이 있으면 먼저 실행 — rc≠0 이면 기동하지 않고 같은 rc 로 끝난다. 비어 있으면 종전과 같다.
    : "${PKG:?}" "${ACT:?}"
    if [ -n "${MOBILE_PRESTART_HOOK:-}" ]; then bash -c "$MOBILE_PRESTART_HOOK" || exit $?; fi
    A shell am start -n "$PKG/$ACT" >/dev/null ;;
  stop) : "${PKG:?}"; A shell am force-stop "$PKG" ;;
  clear) : "${PKG:?}"; A shell pm clear "$PKG" ;;
  logc) A logcat -c ;;
  log)  # log <정규식> [줄수] [자를폭]
    "$ADB" -s "$SERIAL" logcat -d 2>/dev/null | tr -d '\r' | grep -aE "$1" | tail -"${2:-40}" | cut -c1-"${3:-400}" ;;
  fatal)  # 치명 오류 줄 수 — E/F 레벨만 보고(-v brief '*:E'), AndroidRuntime 은 E/F 태그 줄만 센다
    #   (종전 'AndroidRuntime: ' 패턴은 uiautomator 기동 D/AndroidRuntime 로그까지 세어 Fold5 오탐 6건 — 사이클172)
    "$ADB" -s "$SERIAL" logcat -d -v brief '*:E' 2>/dev/null | tr -d '\r' \
      | grep -aE "^[EF]/AndroidRuntime\(|FATAL EXCEPTION|Unhandled Exception|SIGSEGV|SIGABRT" | grep -a -c . ;;
  sh) A shell "$@" ;;
  login)  # login <ID> <X> <Y> [PW] — ID 필드 탭 → 지우고 입력 → TAB → PW → ENTER (좌표 클릭으로 PW 필드 이동 금지)
    PW=${4:-$1}
    A shell input tap "$2" "$3"; /bin/sleep 1; A shell input keyevent KEYCODE_MOVE_END; A shell input keyevent 67 67 67 67 67 67 67 67 67 67; A shell input text "$1"; /bin/sleep 1
    A shell input keyevent 61; /bin/sleep 1; A shell input keyevent KEYCODE_MOVE_END; A shell input keyevent 67 67 67 67 67 67 67 67 67 67; A shell input text "$PW"; /bin/sleep 1
    A shell input keyevent 66; /bin/sleep 2; kb_hide ;;
  *) echo "알 수 없는 명령: $cmd" >&2; exit 2 ;;
esac
