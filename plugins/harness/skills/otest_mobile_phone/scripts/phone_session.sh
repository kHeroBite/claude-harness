#!/bin/bash
# 실기기 테스트 세션 시작·종료 — 원래 화면 설정 저장 → 깨우기·stayon → (종료 시) wm size/density·회전·stayon 원복과 Physical 일치 확인
# 사용: phone_session.sh begin | end | safe | reconnect | status | wake
#   safe      — 단계 마무리(휴대 안전 상태): 키보드 내림 → 팝업창 해제 → 화면 설정·stayon 원복. 단계 사이에는 언제 뽑아도 정상 상태(otest_mobile L11·21).
#   reconnect — 분리 후 재연결: 깨우기 → 보류 원복 목록 처리 → (호출측이 apk_md5 대조·로그인 확인) → begin 으로 원값 재저장·stayon 재적용.
#   end 시점에 기기가 분리돼 있으면 원값 파일을 지우지 않고 보류 원복 목록($OUT/pending_revert_<SERIAL>.env)으로 남긴다(rc=3).
#   테스트 스크립트에서는 begin 직후 반드시: trap 'bash <이 경로>/phone_session.sh end' EXIT INT TERM
# 환경변수: ADB·SERIAL(필수 — adb -s 에 쓰는 값: USB 시리얼 또는 무선 IP:포트), OUT(기본 ./otest_mobile_out)
#   원래 값은 $OUT/phone_state_<하드웨어시리얼>.env 에 저장 — USB·무선 어느 쪽으로 다시 붙어도 같은 파일로 원복한다
#   무선이면 begin 이 stayon true + screen_off_timeout 30분을 적용하고 end 가 둘 다 원값으로 되돌린다
export LC_ALL=C.UTF-8
: "${ADB:?}" "${SERIAL:?}"
OUT=${OUT:-./otest_mobile_out}; mkdir -p "$OUT"
S() { "$ADB" -s "$SERIAL" shell "$@" 2>/dev/null | tr -d '\r'; }
present() { [ "$("$ADB" -s "$SERIAL" get-state 2>/dev/null | tr -d '\r')" = device ]; }
HERE=$(cd "$(dirname "$0")" && pwd)
# 기기 키 = 하드웨어 시리얼(ro.serialno) — USB 로 저장한 원래 값을 무선(IP:포트)으로 재연결해도 같은 파일로 원복한다(dev_id.sh)
. "$HERE/../../otest_mobile/scripts/dev_id.sh" --lib
LINK=$(dev_kind "$SERIAL")
if [ "$LINK" = usb ]; then KEY=$SERIAL; else
  HMAP=$OUT/hwid_$(printf '%s' "$SERIAL" | tr -c 'A-Za-z0-9._-' '_').txt
  KEY=$(cat "$HMAP" 2>/dev/null); if present; then KEY=$(dev_hwid "$SERIAL"); echo "$KEY" > "$HMAP"; fi; KEY=${KEY:-$SERIAL}
fi
ST=$OUT/phone_state_$KEY.env
PEND=$OUT/pending_revert_$KEY.env
awake() { S dumpsys power | grep -aoE "mWakefulness=[A-Za-z]+" | head -1 | cut -d= -f2; }
ssid() { S cmd wifi status 2>/dev/null | grep -aoE 'connected to "[^"]*"' | head -1 | sed -E 's/connected to "(.*)"/\1/'; }   # 연결 SSID(없으면 빈 값)
locked() { S dumpsys window | grep -aoE "mDreamingLockscreen=(true|false)|isKeyguardShowing=(true|false)|mShowingLockscreen=(true|false)" | head -1 | cut -d= -f2; }
wake() {
  [ "$(awake)" = "Awake" ] || { S input keyevent KEYCODE_WAKEUP; /bin/sleep 1; }
  echo "wakefulness=$(awake) lockscreen=$(locked)"
  [ "$(locked)" = "true" ] && echo "⚠️ 잠금 화면 — 테스트 전용 기기는 화면 잠금 '없음' 으로 두는 것을 사용자에게 1회 요청한다(PIN 자동 입력 금지)"
  return 0
}
case "$1" in
  begin)
    if [ -f "$ST" ]; then echo "이미 저장된 원래 값이 있다(직전 세션 미종료) — 덮어쓰지 않는다: $ST"; else
      {
        echo "STAYON=$(S settings get global stay_on_while_plugged_in)"
        echo "SOT=$(S settings get system screen_off_timeout)"
        echo "WMSIZE_OVR=$(S wm size | grep -a Override | sed 's/.*: //')"
        echo "WMDEN_OVR=$(S wm density | grep -a Override | sed 's/.*: //')"
        echo "ROT_AUTO=$(S settings get system accelerometer_rotation)"
        echo "ROT_USER=$(S settings get system user_rotation)"
        # 네트워크 원값 — 비행기 모드·Wi-Fi 토글 시험 뒤 기기가 다른 SSID(예: 사용자 개인 핫스팟)에 붙는 사고 방지(end 가 대조)
        echo "AIRPLANE=$(S settings get global airplane_mode_on)"
        echo "WIFI_ON=$(S settings get global wifi_on)"
        echo "WIFI_SSID='$(ssid)'"
        echo "SAVED_AT='$(date '+%F %T')'"
      } > "$ST"
    fi
    cat "$ST"
    wake
    # MOBILE_SESSION_HOOK(선택, 프로젝트 게이트 명령) — "begin" 인자로 실행, rc≠0 이면 세션을 열지 않는다. 비어 있으면 종전과 같다.
    if [ -n "${MOBILE_SESSION_HOOK:-}" ]; then bash -c "$MOBILE_SESSION_HOOK begin" || exit $?; fi
    if [ "$LINK" = wireless ]; then
      # 무선 adb 는 USB 전원 조건이 없다 — stayon true(충전 중일 때만 유효) + 화면 꺼짐 30분(배터리 사용 시), 둘 다 end 에서 원값 복원
      S svc power stayon true; S settings put system screen_off_timeout 1800000
      echo "무선 연결 — stayon=$(S settings get global stay_on_while_plugged_in) screen_off_timeout=$(S settings get system screen_off_timeout)"
    else
      S svc power stayon usb
      echo "stayon 적용 → $(S settings get global stay_on_while_plugged_in)"
    fi
    ;;
  end)
    if ! present; then
      [ -f "$ST" ] && cp -f "$ST" "$PEND"
      echo "⚠️ 기기 분리됨 — 원복 불가. 보류 원복 목록 저장: $PEND (재연결 시 reconnect 가 가장 먼저 처리)"; exit 3
    fi
    # end 는 멱등이다 — 원값 파일이 없으면(이미 복원·삭제됨, 또는 begin 없이 호출) 어떤 설정도 바꾸지 않는다.
    #   종전 "reset 만 수행"은 두 번째 end 가 사용자 설정(예: density Override)을 reset 으로 지웠다(실사고 — 훅 연동 뒤 end 재호출).
    [ -f "$ST" ] || { echo "이미 종료됨 — 저장된 원래 값 없음, 설정 변경 없음"; exit 0; }
    STAYON=0; SOT=""; WMSIZE_OVR=""; WMDEN_OVR=""; ROT_AUTO=""; ROT_USER=""; AIRPLANE=""; WIFI_ON=""; unset WIFI_SSID  # 구 원값 파일(SSID 없음)은 대조 생략
    [ -f "$ST" ] && . "$ST"
    if [ -n "$WMSIZE_OVR" ]; then S wm size "$WMSIZE_OVR"; else S wm size reset; fi
    if [ -n "$WMDEN_OVR" ]; then S wm density "$WMDEN_OVR"; else S wm density reset; fi
    [ -n "$ROT_AUTO" ] && [ "$ROT_AUTO" != "null" ] && S settings put system accelerometer_rotation "$ROT_AUTO"
    [ -n "$ROT_USER" ] && [ "$ROT_USER" != "null" ] && S settings put system user_rotation "$ROT_USER"
    case "$STAYON" in 0|null|"") S svc power stayon false ;; *) S settings put global stay_on_while_plugged_in "$STAYON" ;; esac
    [ -n "$SOT" ] && [ "$SOT" != null ] && S settings put system screen_off_timeout "$SOT"
    NOW_SZ=$(S wm size); NOW_DN=$(S wm density)
    echo "$NOW_SZ" | grep -aq Override && OVR=1 || OVR=0
    echo "원복: stayon=$(S settings get global stay_on_while_plugged_in) screen_off_timeout=$(S settings get system screen_off_timeout) rot=$(S settings get system accelerometer_rotation)/$(S settings get system user_rotation)"
    echo "$NOW_SZ | $NOW_DN"
    if [ -z "$WMSIZE_OVR" ] && [ $OVR = 1 ]; then echo "❌ wm size Override 잔존 — Physical 불일치"; exit 1; fi
    # 네트워크 원복·대조 — 비행기 모드·Wi-Fi 는 원값으로 되돌리고, SSID 는 비밀번호 없이 자동 복원할 수 없으므로 대조만 한다(다르면 실패)
    if [ -n "$AIRPLANE" ] && [ "$AIRPLANE" != null ] && [ "$(S settings get global airplane_mode_on)" != "$AIRPLANE" ]; then
      [ "$AIRPLANE" = 1 ] && S cmd connectivity airplane-mode enable || S cmd connectivity airplane-mode disable; sleep 5
    fi
    if [ -n "$WIFI_ON" ] && [ "$WIFI_ON" != null ] && [ "$(S settings get global wifi_on)" != "$WIFI_ON" ]; then
      [ "$WIFI_ON" = 0 ] && S svc wifi disable || S svc wifi enable; sleep 8
    fi
    NOW_SSID=$(ssid)
    echo "네트워크: airplane=$(S settings get global airplane_mode_on)(원 $AIRPLANE) wifi=$(S settings get global wifi_on)(원 $WIFI_ON) SSID='$NOW_SSID'(원 '$WIFI_SSID')"
    if [ -n "${WIFI_SSID+x}" ] && [ "$NOW_SSID" != "$WIFI_SSID" ]; then
      echo "❌ Wi-Fi SSID 가 시작 때와 다르다 — 사용자에게 원래 네트워크('$WIFI_SSID')로 전환을 요청하라(adb 로 비밀번호 입력 금지). 원값 파일 유지: $ST"; exit 1
    fi
    # MOBILE_SESSION_HOOK — "end" 인자로 실행(종료 검사). rc≠0 이면 end 도 같은 rc 로 끝나되 ★원값 파일은 지우지 않는다★ — 재호출이 같은 원값으로 다시 원복·검사할 수 있다.
    #   (원복은 위에서 이미 끝났고 재호출 시 같은 값을 다시 적용하므로 무해하다.) 비어 있으면 종전과 같다.
    if [ -n "${MOBILE_SESSION_HOOK:-}" ]; then
      bash -c "$MOBILE_SESSION_HOOK end" || { rc=$?; echo "⚠️ 종료 훅 실패(rc=$rc) — 원값 파일 유지: $ST (재호출 가능)"; exit $rc; }
    fi
    rm -f "$ST" "$PEND"; echo "✅ 화면 설정 원복 확인"
    ;;
  safe)
    present || { [ -f "$ST" ] && cp -f "$ST" "$PEND"; echo "⚠️ 기기 분리됨 — 보류 원복 목록 저장: $PEND"; exit 3; }
    [ -f "$HERE/../../otest_mobile/scripts/madb.sh" ] && OUT="$OUT" bash "$HERE/../../otest_mobile/scripts/madb.sh" kbhide
    if S dumpsys activity activities 2>/dev/null | grep -aq "mWindowingMode=freeform\|windowingMode=freeform"; then
      [ -f "$HERE/window_mode.sh" ] && bash "$HERE/window_mode.sh" full
    fi
    bash "$0" end
    ;;
  reconnect)
    present || { echo "❌ 아직 연결 안 됨"; exit 1; }
    wake
    if [ -f "$PEND" ]; then echo "보류 원복 처리: $PEND"; cp -f "$PEND" "$ST"; bash "$0" end || exit 1; fi
    echo "다음: 설치된 APK md5 를 원장(test_ledger.py)의 apk_md5 와 대조 → 다르면 재설치 · 로그인/서버 선택 확인 → phone_session.sh begin · '실기기 대기' 항목부터 재개"
    ;;
  status)
    echo "wakefulness=$(awake) lockscreen=$(locked) stayon=$(S settings get global stay_on_while_plugged_in)"
    S wm size; S wm density
    echo "rotation auto=$(S settings get system accelerometer_rotation) user=$(S settings get system user_rotation)"
    [ -f "$ST" ] && { echo "저장된 원래 값:"; cat "$ST"; }
    ;;
  wake) wake ;;
  *) echo "사용: phone_session.sh begin|end|safe|reconnect|status|wake" >&2; exit 2 ;;
esac
