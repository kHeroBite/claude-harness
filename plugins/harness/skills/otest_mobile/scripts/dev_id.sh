#!/bin/bash
# 실기기 식별을 하드웨어 시리얼(ro.serialno)로 통일한다 — USB 시리얼과 무선 adb 의 IP:포트를 같은 기기로 본다
#
# 사용(실행):  dev_id.sh hwid <adb시리얼>          # 그 연결의 하드웨어 시리얼(에뮬은 emulator-NNNN 그대로)
#              dev_id.sh resolve <하드웨어시리얼>   # 지금 연결된 adb 시리얼(USB 우선, 없으면 IP:포트). 없으면 rc=1
#              dev_id.sh reals                      # 연결된 실기기 adb 시리얼 목록(PHONE_SERIAL 이 있으면 그 기기만)
#              dev_id.sh kind <adb시리얼>           # usb | wireless | emulator
# 사용(함수):  source dev_id.sh --lib  → dev_hwid · dev_resolve · dev_reals · dev_kind
# 환경변수:    ADB(필수) · PHONE_SERIAL(선택 — 테스트 전용 실기기의 ★하드웨어 시리얼★)
#              ADB_DEVICES_FILE(선택 — adb devices 출력 대용 파일, 모의 smoke 용. 이때 hwid 는 adb 시리얼 그대로)
# 규칙: adb -s 에는 언제나 dev_resolve 가 돌려준 adb 시리얼(USB 시리얼 또는 IP:포트)을 쓴다.
#       사용권·원복 상태 파일·원장 같은 ★기기 키★ 에는 하드웨어 시리얼을 쓴다 — 연결 방식이 바뀌어도 같은 기기다.

_dev_list() {
  if [ -n "${ADB_DEVICES_FILE:-}" ]; then tr -d '\r' < "$ADB_DEVICES_FILE"; else "$ADB" devices 2>/dev/null | tr -d '\r'; fi \
    | awk 'NR>1 && $2=="device" {print $1}'
}

dev_kind() {
  case "$1" in
    emulator-*) echo emulator ;;
    *:*|*._adb-tls-connect.*|*._adb-tls-pairing.*) echo wireless ;;   # IP:포트, 또는 mDNS 이름(adb-<시리얼>-xxxx._adb-tls-connect._tcp)
    *) echo usb ;;
  esac
}

dev_hwid() {
  local s="$1" h
  case "$s" in emulator-*) echo "$s"; return 0 ;; esac
  if [ -n "${ADB_HWID_MAP:-}" ] && [ -f "$ADB_HWID_MAP" ]; then   # 모의: "adb시리얼 하드웨어시리얼" 줄
    h=$(awk -v k="$s" '$1==k {print $2; exit}' "$ADB_HWID_MAP"); [ -n "$h" ] && { echo "$h"; return 0; }
  fi
  if [ -n "${ADB_DEVICES_FILE:-}" ]; then echo "$s"; return 0; fi
  h=$("$ADB" -s "$s" shell getprop ro.serialno 2>/dev/null | tr -d '\r\n ')
  echo "${h:-$s}"
}

dev_reals() {
  local s
  for s in $(_dev_list); do
    case "$s" in emulator-*) continue ;; esac
    if [ -n "${PHONE_SERIAL:-}" ] && [ "$(dev_hwid "$s")" != "$PHONE_SERIAL" ]; then continue; fi
    echo "$s"
  done
}

dev_resolve() {
  local want="$1" s usb="" wl=""
  for s in $(_dev_list); do
    case "$s" in emulator-*) [ "$s" = "$want" ] && { echo "$s"; return 0; }; continue ;; esac
    [ "$(dev_hwid "$s")" = "$want" ] || continue
    if [ "$(dev_kind "$s")" = usb ]; then usb=$s; else wl=$s; fi
  done
  [ -n "$usb" ] && { echo "$usb"; return 0; }
  [ -n "$wl" ] && { echo "$wl"; return 0; }
  return 1
}

if [ "${1:-}" = "--lib" ]; then return 0 2>/dev/null || exit 0; fi
: "${ADB:?ADB 환경변수 필요}"
case "${1:-}" in
  hwid) dev_hwid "${2:?adb시리얼}" ;;
  resolve) dev_resolve "${2:?하드웨어시리얼}" ;;
  reals) dev_reals ;;
  kind) dev_kind "${2:?adb시리얼}" ;;
  *) echo "사용: dev_id.sh hwid|resolve|reals|kind <값>" >&2; exit 2 ;;
esac
