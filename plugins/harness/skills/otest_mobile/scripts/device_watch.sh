#!/bin/bash
# 실기기·에뮬 연결을 매번 다시 확인해 전환(실기기 분리→에뮬)·재연결(에뮬→실기기) 이벤트와 다음 행동을 출력하는 감시 스크립트
#
# 사용:
#   device_watch.sh once                 # 지금 상태 1회 판정 + 직전 상태와 비교한 이벤트 출력
#   device_watch.sh watch <초> <횟수>     # 대기 루프용 — 주기마다 once 를 반복(≤60초 권장, 메시지 확인 사이사이)
# 환경변수:
#   ADB(필수) · PHONE_SERIAL(테스트 전용 실기기의 ★하드웨어 시리얼(ro.serialno)★ — 이 기기만 실기기로 인정, USB·무선 모두) · OUT(기본 ./otest_mobile_out)
#   EMU_AVD·EMU_PORT(기본 5554)·EMU_MEM(기본 4096) — 설정돼 있고 실기기가 없는데 에뮬도 없으면 avd_boot.sh 로 기동(--auto-boot)
#   ADB_DEVICES_FILE — 지정하면 adb 대신 이 파일 내용을 `adb devices` 출력으로 쓴다(분리·재연결 모의 smoke 용)
#   ADB_HWID_MAP — 모의 시 "adb시리얼 하드웨어시리얼" 대응 파일(무선 IP:포트 모의용, dev_id.sh)
#   SCOPE_MARKER — 세션 범위 마커 파일 또는 디렉토리. phone 키(away|back) > message 문구 > adb 순으로 판정(사용자 "휴대폰 뺀다/다시 연결했다")
# 출력(마지막 줄들): TARGET=phone|emulator|none SERIAL=<adb -s 에 쓸 시리얼(USB 또는 IP:포트)> HWID=<하드웨어 시리얼> LINK=usb|wireless|emulator · EVENT · ACTION
#   EVENT: PHONE_LOST · PHONE_BACK · EMU_UP · EMU_DOWN · NONE
#   ACTION: switch_to_emulator · boot_emulator · reconnect_phone(phone_session.sh reconnect → apk_md5 대조 → begin) · continue
# 상태 파일: $OUT/device_watch.state (직전 TARGET·SERIAL)
export LC_ALL=C.UTF-8
: "${ADB:?ADB 환경변수 필요}"
OUT=${OUT:-./otest_mobile_out}; mkdir -p "$OUT"; STATE=$OUT/device_watch.state
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/dev_id.sh" --lib   # 실기기 식별은 하드웨어 시리얼로 통일(USB·무선 같은 기기)
AUTO_BOOT=0; [ "${3:-}" = "--auto-boot" ] || [ "${2:-}" = "--auto-boot" ] && AUTO_BOOT=1

devices() {
  if [ -n "${ADB_DEVICES_FILE:-}" ]; then tr -d '\r' < "$ADB_DEVICES_FILE"; else "$ADB" devices 2>/dev/null | tr -d '\r'; fi
}

once() {
  local DEV REALS EMUS PREV_T PREV_S T S EV ACT MK
  DEV=$(devices)
  # 실기기: USB 우선, 없으면 무선(IP:포트) — PHONE_SERIAL 은 하드웨어 시리얼로 대조(dev_id.sh)
  REALS=""; for _s in $(dev_reals); do if [ "$(dev_kind "$_s")" = usb ]; then REALS=$_s; break; fi; [ -z "$REALS" ] && REALS=$_s; done
  EMUS=$(echo "$DEV"  | awk 'NR>1 && $1 ~ /^emulator-/  && $2=="device" {print $1}' | head -1)
  # 사용자 발화 마커가 있으면 우선 — "휴대폰 뺀다" 면 연결돼 있어도 실기기를 쓰지 않는다
  #   판정 순서: 마커 파일 JSON 의 phone 키(away|back) > _all.json·_user.json 의 message 문구 > adb devices
  #   SCOPE_MARKER 는 마커 파일 1개 또는 마커 디렉토리. 문구는 기기 단어(휴대폰·폰·fold·실기기)와 함께 있을 때만 인정한다.
  MK=""
  if [ -n "${SCOPE_MARKER:-}" ] && [ -e "$SCOPE_MARKER" ]; then
    MK=$(python3 - "$SCOPE_MARKER" <<'PYEOF' 2>/dev/null
import json, os, re, sys
p = sys.argv[1]
files = [p] if os.path.isfile(p) else [os.path.join(p, f) for f in ("_all.json", "_user.json") if os.path.isfile(os.path.join(p, f))]
recs = []
def walk(o):
    if isinstance(o, dict):
        if "phone" in o or "message" in o:
            recs.append(o)
        for v in o.values():
            walk(v)
    elif isinstance(o, list):
        for v in o:
            walk(v)
for f in files:
    try:
        walk(json.load(open(f, encoding="utf-8")))
    except Exception:
        pass
key = lambda r: str(r.get("ts") or r.get("at") or r.get("created_at") or "")
recs.sort(key=key)
# 1) phone 키 — 가장 최근 값
ph = [r["phone"] for r in recs if r.get("phone") in ("away", "back")]
if ph:
    print(ph[-1]); sys.exit(0)
# 2) 문구 — 기기 단어 + 분리/연결 동사가 함께 있는 가장 최근 문장
dev = re.compile(r"휴대폰|폰|fold|폴드|실기기", re.I)
away = re.compile(r"뺀다|빼|제거|분리|외출")
back = re.compile(r"연결했|다시 연결|재연결|꽂았")
last = ""
for r in recs:
    m = str(r.get("message", ""))
    if not dev.search(m):
        continue
    if back.search(m):
        last = "back"
    elif away.search(m):
        last = "away"
print(last)
PYEOF
)
    [ "$MK" = away ] && REALS=""
  fi
  PREV_T=""; PREV_S=""; [ -f "$STATE" ] && . "$STATE"
  if [ -n "$REALS" ]; then T=phone; S=$REALS
  elif [ -n "$EMUS" ]; then T=emulator; S=$EMUS
  else T=none; S=""; fi
  EV=NONE; ACT=continue
  if [ "$PREV_T" = phone ] && [ "$T" != phone ]; then EV=PHONE_LOST; ACT=switch_to_emulator; fi
  if [ "$PREV_T" != phone ] && [ -n "$PREV_T" ] && [ "$T" = phone ]; then EV=PHONE_BACK; ACT=reconnect_phone; fi
  if [ "$T" = none ]; then
    ACT=boot_emulator
    if [ "$AUTO_BOOT" = 1 ] && [ -n "${EMU_AVD:-}" ] && [ -z "${ADB_DEVICES_FILE:-}" ]; then
      nohup bash "$HERE/../../otest_mobile_emulator/scripts/avd_boot.sh" "$EMU_AVD" "${EMU_PORT:-5554}" "${EMU_MEM:-4096}" \
        > "$OUT/avd_boot_watch.log" 2>&1 & disown
      echo "에뮬 기동 시작: $EMU_AVD (로그 $OUT/avd_boot_watch.log)"
    fi
  fi
  [ "$EV" = NONE ] && [ "$PREV_T" = emulator ] && [ "$T" = none ] && EV=EMU_DOWN
  [ "$EV" = NONE ] && [ "$PREV_T" = none ] && [ "$T" = emulator ] && EV=EMU_UP
  printf 'PREV_T=%s\nPREV_S=%s\n' "$T" "$S" > "$STATE"
  echo "$(date '+%F %T') TARGET=$T SERIAL=${S:-none} HWID=$([ -n "$S" ] && dev_hwid "$S" || echo none) LINK=$([ -n "$S" ] && dev_kind "$S" || echo none) EVENT=$EV ACTION=$ACT${MK:+ MARKER=$MK}" | tee -a "$OUT/device_watch.log"
}

case "${1:-once}" in
  once) once ;;
  watch)
    N=${3:-1}; I=${2:-30}
    for _i in $(seq 1 "$N"); do once; [ "$_i" -lt "$N" ] && /bin/sleep "$I"; done ;;
  *) sed -n 2,19p "$0"; exit 2 ;;
esac
