#!/bin/bash
# 등록된 peer 별칭마다 pull-all 을 throttle·flock 으로 백그라운드 기동하는 공용 트리거(항상 exit 0)
#
# 사용: bash peer_autopull.sh <프로젝트폴더|->
# hook(Stop·SessionStart·UPS) 쪽 동기 경로는 스크립트 파일 존재 확인과 분리 기동뿐이다(수 ms).
# 무거운 일은 전부 분리된 worker(--worker)가 한다.
#   1) 프로젝트 INFRA 의 peer_ssh 별칭을 peer_hosts 에 자가치유 등록(outbox 는 제외)
#   2) hosts-list 별칭마다 스탬프 경과가 PEER_INBOX_THROTTLE_SEC(기본 60) 이상이면 pull-all 을 분리 기동
# 시험용 환경변수: PEER_NOTIFY_SCRIPT, PEER_NOTIFY_HOME, PEER_INBOX_THROTTLE_SEC
# 출력 없음. 실패는 전부 조용히 넘긴다. 호출자는 기다리지 않는다.

_peer_autopull_script() {
  local here
  here=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || return 1
  _AP_HERE="$here"
  _AP_SCRIPT="${PEER_NOTIFY_SCRIPT:-$here/../../scripts/peer_ssh_notify.sh}"
  [ -f "$_AP_SCRIPT" ]
}

_peer_autopull_worker() {
  local dir script home tok infra peer thr alias now last stamp aliases here
  tok='^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
  dir="${1:--}"
  _peer_autopull_script || return 0
  here="$_AP_HERE"; script="$_AP_SCRIPT"
  home="${PEER_NOTIFY_HOME:-$HOME/.claude}"

  # 자가치유: INFRA peer_ssh 별칭을 등록부에 추가
  if [ "$dir" != "-" ] && [ -d "$dir" ]; then
    # shellcheck source=/dev/null
    if . "$here/infra_path.sh" 2>/dev/null; then
      infra=$(infra_md_path "$dir" 2>/dev/null) && peer=$(infra_field "$infra" peer_ssh 2>/dev/null)
      if [ -n "${peer:-}" ] && [ "$peer" != outbox ] && [[ "$peer" =~ $tok ]]; then
        PEER_NOTIFY_HOME="$home" timeout 5 bash "$script" hosts-add "$peer" >/dev/null 2>&1 </dev/null
      fi
    fi
  fi

  aliases=$(PEER_NOTIFY_HOME="$home" timeout 5 bash "$script" hosts-list 2>/dev/null </dev/null) || return 0
  [ -n "$aliases" ] || return 0
  thr="${PEER_INBOX_THROTTLE_SEC:-60}"
  case "$thr" in ''|*[!0-9]*) thr=60 ;; esac
  mkdir -p -m 700 "$home/peer_inbox" 2>/dev/null || return 0
  now=$(date +%s)
  while IFS= read -r alias; do
    [[ "$alias" =~ $tok ]] || continue
    [ "$alias" != outbox ] || continue
    stamp="$home/peer_inbox/.pullall_${alias}.stamp"
    last=$(stat -c %Y "$stamp" 2>/dev/null) || last=0
    [ $((now - last)) -ge "$thr" ] || continue
    touch "$stamp" 2>/dev/null
    ( PEER_NOTIFY_HOME="$home" setsid nohup timeout 30 flock -n "$home/peer_inbox/.pullall_${alias}.lock" \
        bash "$script" pull-all "$alias" \
        >"$home/peer_inbox/.pullall_${alias}.log" 2>&1 </dev/null & ) 2>/dev/null
  done <<EOF
$aliases
EOF
  return 0
}

_peer_autopull_main() {
  if [ "${1:-}" = "--worker" ]; then
    _peer_autopull_worker "${2:--}"
    return 0
  fi
  # 동기 경로: 스크립트 존재 확인 후 분리 기동만 한다(hosts-add·hosts-list 는 worker 가 한다).
  _peer_autopull_script || return 0
  ( setsid nohup bash "$_AP_HERE/peer_autopull.sh" --worker "${1:--}" >/dev/null 2>&1 </dev/null & ) 2>/dev/null
  return 0
}

_peer_autopull_main "$@" >/dev/null 2>&1
exit 0
