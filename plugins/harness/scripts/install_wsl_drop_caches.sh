#!/bin/bash
# WSL drop_caches 정기 실행(cron.d) 설치와 사용자 crontab 정리를 한 번에 수행하는 설치 스크립트
set -u

SRC="${HARNESS_HOME:-$HOME/.harness}/current/scripts/wsl_drop_caches.sh"
DST="/usr/local/sbin/wsl_drop_caches.sh"
CRON_FILE="/etc/cron.d/wsl-drop-caches"
OLD_LINE='root sync && echo 1 > /proc/sys/vm/drop_caches'

# 0) 권한과 사용자 확인
if [ "$(id -u)" -ne 0 ]; then
  echo "root 권한이 필요합니다. sudo bash ${HARNESS_HOME:-$HOME/.harness}/current/scripts/install_wsl_drop_caches.sh 로 실행하세요."
  exit 1
fi
U="${SUDO_USER:-}"
if [ -z "$U" ] || [ "$U" = "root" ]; then
  echo "SUDO_USER 를 확인할 수 없어 중단합니다. 일반 사용자 계정에서 sudo 로 실행하세요."
  exit 1
fi
if [ ! -f "$SRC" ]; then
  echo "원본 스크립트가 없어 중단합니다: $SRC"
  exit 1
fi
if pgrep -u "$U" -x crontab >/dev/null 2>&1; then
  echo "crontab 편집기가 열려 있습니다. 저장하지 말고 닫은 뒤 다시 실행하세요."
  exit 2
fi

# 1) 실행 스크립트 설치
echo "[1/5] 스크립트 설치"
if install -m 755 "$SRC" "$DST"; then
  echo "  설치 완료: $DST"
else
  echo "  설치 실패 (rc=$?)"
  exit 1
fi

# 2) cron.d 작성
echo "[2/5] cron.d 등록"
printf '%s\n' '0 0,6,12,18 * * * root /usr/local/sbin/wsl_drop_caches.sh' > "$CRON_FILE"
chmod 644 "$CRON_FILE"
echo "  작성 완료: $CRON_FILE"

# 3) 사용자 crontab 정리
echo "[3/5] 사용자 crontab 정리 ($U)"
CUR="$(crontab -u "$U" -l 2>/dev/null)"
if [ -z "$CUR" ]; then
  echo "  crontab 이 비어 있어 건너뜁니다."
else
  BEFORE="$(printf '%s\n' "$CUR" | wc -l)"
  if printf '%s\n' "$CUR" | grep -q -F -- "$OLD_LINE"; then
    BAK="/home/$U/crontab.bak_$(date +%Y%m%d_%H%M%S)"
    printf '%s\n' "$CUR" > "$BAK"
    chown "$U":"$(id -gn "$U")" "$BAK" 2>/dev/null
    echo "  백업: $BAK"
    NEW="$(printf '%s\n' "$CUR" | grep -v -F -- "$OLD_LINE")"
    if printf '%s\n' "$NEW" | crontab -u "$U" -; then
      AFTER="$(crontab -u "$U" -l 2>/dev/null | wc -l)"
      echo "  제거 전 ${BEFORE}줄 -> 제거 후 ${AFTER}줄"
    else
      echo "  crontab 적용 실패 (백업은 $BAK)"
      exit 1
    fi
  else
    echo "  제거 대상 줄이 없어 건너뜁니다. (현재 ${BEFORE}줄)"
  fi
fi

# 4) 즉시 1회 실행
echo "[4/5] 즉시 1회 실행"
"$DST"
echo "  종료 코드 rc=$?"

# 5) 확인 출력
echo "[5/5] 확인"
echo "--- $CRON_FILE"
cat "$CRON_FILE"
echo "--- crontab -u $U"
crontab -u "$U" -l 2>/dev/null | grep -n -E "drop_caches|teammate_reaper"
echo "완료"
