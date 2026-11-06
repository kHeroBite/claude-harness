#!/bin/sh
# WSL 페이지 캐시를 비워 Windows 로 메모리를 돌려주는 스크립트(root 전용, cron.d 에서 실행)
#
# 동작: sync 로 더티 페이지를 디스크에 쓴 뒤 /proc/sys/vm/drop_caches 에 1 을 써서
#       page cache 만 비운다. dentry·inode(값 2·3)는 비우지 않는다.
#       실행 전후 free -m 결과를 logger -t wsl_drop_caches 로 syslog 에 남긴다.
# 설치·확인·제거 방법: docs/guides/wsl-memory-tuning.md
# 종료 코드: 0 성공 / 1 root 아님 / 2 drop_caches 쓰기 실패
# 주의: POSIX sh(dash)는 한글 식별자를 허용하지 않아 변수·함수 이름은 영문으로 둔다.

TAG=wsl_drop_caches

# 로그 한 줄을 표준 출력과 syslog 에 남긴다. logger 가 없거나 실패해도 계속한다.
log_line() {
    printf '%s\n' "$1"
    command -v logger >/dev/null 2>&1 && logger -t "$TAG" -- "$1"
    return 0
}

# free -m 의 Mem 줄을 한 줄로 요약한다.
mem_summary() {
    free -m 2>/dev/null | awk '/^Mem:/ {printf "total=%s used=%s free=%s buff_cache=%s available=%s", $2, $3, $4, $6, $7}'
}

if [ "$(id -u)" -ne 0 ]; then
    printf '%s\n' "root 권한이 필요합니다. /etc/cron.d 에서 root 로 실행하도록 설치하세요(docs/guides/wsl-memory-tuning.md)." >&2
    exit 1
fi

log_line "시작 전: $(mem_summary)"
sync
if ! echo 1 > /proc/sys/vm/drop_caches; then
    log_line "실패: /proc/sys/vm/drop_caches 쓰기 오류"
    exit 2
fi
log_line "완료 후: $(mem_summary)"
exit 0
