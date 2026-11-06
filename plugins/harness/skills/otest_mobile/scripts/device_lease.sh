#!/usr/bin/env bash
# 공유 테스트 기기(실기기·AVD)의 사용권을 파일로 잡고 넘기며, 기기 전환·중단 후 이어하기 체크포인트를 남기는 스크립트
#
# 사용:
#   device_lease.sh acquire <SERIAL> <담당자> "<작업 요지>"   # 사용 시작 — 다른 담당이 쥐고 있으면 rc=1 (보유자·시작 시각 출력)
#   device_lease.sh release <SERIAL> <담당자>                  # 사용 종료 — 자기 것만 푼다
#   device_lease.sh status  [SERIAL]                           # 보유 현황
#   device_lease.sh checkpoint <담당자> <단계ID> "<메모>"        # 진행 위치 기록(기기 전환·외출 후 이어하기용)
#   device_lease.sh resume <담당자>                            # 마지막 체크포인트 출력
#
# 저장 위치: ${LEASE_DIR:-$OUT/../device_lease} (세션 작업 디렉토리 상위 — 같은 세션 팀원이 공유)
# 규칙(otest_mobile "공유 기기 교대"): acquire 실패면 보유자에게 메시지로 순서를 합의한다. 파일을 지워 빼앗지 않는다.
#   재설치(install -r)·pm clear·wm 변경 전에는 반드시 자기 lease 가 있어야 한다. 2시간 넘은 lease 는 stale 로 표시만 한다(자동 해제 안 함).
set -u
DIR="${LEASE_DIR:-${OUT:-./otest_mobile_out}/../device_lease}"
mkdir -p "$DIR"
now() { date '+%Y-%m-%d %H:%M:%S'; }
# 기기 키 = 하드웨어 시리얼 — 무선(IP:포트·mDNS 이름)으로 들어오면 ro.serialno 로 바꿔 USB 와 같은 사용권을 쓴다(dev_id.sh)
. "$(cd "$(dirname "$0")" && pwd)/dev_id.sh" --lib
key() { if [ "$(dev_kind "$1")" = wireless ] && { [ -n "${ADB:-}" ] || [ -n "${ADB_HWID_MAP:-}" ]; }; then dev_hwid "$1"; else echo "$1"; fi; }
f() { echo "$DIR/lease_$(printf '%s' "$(key "$1")" | tr -c 'A-Za-z0-9._-' '_').txt"; }

case "${1:-}" in
  acquire)
    S="$2"; W="$3"; WHAT="${4:-}"; L=$(f "$S")
    if [ -f "$L" ]; then
      OWNER=$(sed -n 1p "$L")
      if [ "$OWNER" != "$W" ]; then
        echo "❌ $S 사용 중 — $(cat "$L" | tr '\n' ' ')"; exit 1
      fi
    fi
    printf '%s\n%s\n%s\n' "$W" "$(now)" "$WHAT" > "$L"; echo "✅ $S 사용권 획득: $W ($(now)) $WHAT" ;;
  release)
    S="$2"; W="$3"; L=$(f "$S")
    [ -f "$L" ] || { echo "(사용권 없음) $S"; exit 0; }
    OWNER=$(sed -n 1p "$L")
    [ "$OWNER" = "$W" ] || { echo "❌ $S 보유자는 $OWNER — 자기 것만 푼다"; exit 1; }
    rm -f -- "$L"; echo "✅ $S 사용권 해제: $W ($(now))" ;;
  status)
    for L in "$DIR"/lease_*.txt; do
      [ -f "$L" ] || continue
      [ -n "${2:-}" ] && [ "$L" != "$(f "$2")" ] && continue
      START=$(sed -n 2p "$L"); AGE=$(( $(date +%s) - $(date -d "$START" +%s 2>/dev/null || date +%s) ))
      STALE=""; [ "$AGE" -gt 7200 ] && STALE=" ⚠️stale(${AGE}s)"
      echo "$(basename "$L" .txt | sed 's/^lease_//') | $(sed -n 1p "$L") | $START | $(sed -n 3p "$L")$STALE"
    done ;;
  checkpoint)
    W="$2"; STEP="$3"; MEMO="${4:-}"
    printf '%s\t%s\t%s\t%s\n' "$(now)" "$W" "$STEP" "$MEMO" >> "$DIR/checkpoint_${W}.tsv"; echo "📍 $W $STEP 기록" ;;
  resume)
    W="$2"; C="$DIR/checkpoint_${W}.tsv"
    [ -f "$C" ] && tail -1 "$C" || echo "(체크포인트 없음) $W" ;;
  *) sed -n 2,14p "$0"; exit 2 ;;
esac
