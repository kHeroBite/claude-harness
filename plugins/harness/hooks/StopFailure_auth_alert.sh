#!/bin/bash
# 인증 만료(StopFailure) 시 ntfy 로 재로그인 안내를 보내는 hook
#
# 입력(stdin JSON, 공식 문서 확인): session_id, hook_event_name, error, error_details, last_assistant_message
# 발송 조건: error 가 authentication_failed 또는 oauth_org_not_allowed 일 때만(matcher 와 별개로 재확인).
# 중복 방지: 자기 session-env/<session_id>/auth_alert_ts 마커 10분 이내면 무동작.
# 환경변수: AUTH_ALERT_DRYRUN=1 이면 실제 발송·마커 기록 없이 판정과 페이로드만 출력한다.
# 항상 exit 0. 실패는 logs/auth_alert.log 에 1줄. 본문에 토큰·UUID·경로를 넣지 않는다.

HOOK_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
LOG_DIR="$HOOK_DIR/logs"
LOG="$LOG_DIR/auth_alert.log"
DRY="${AUTH_ALERT_DRYRUN:-0}"

_log() { mkdir -p "$LOG_DIR" 2>/dev/null; printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >>"$LOG" 2>/dev/null; }
_out() { [ "$DRY" = 1 ] && printf '%s\n' "$1"; return 0; }

main() {
  command -v jq >/dev/null 2>&1 || { _log "SKIP jq 없음"; return 0; }
  local in err sid aid
  in=$(cat 2>/dev/null)
  err=$(printf '%s' "$in" | jq -r '.error // empty' 2>/dev/null)
  sid=$(printf '%s' "$in" | jq -r '.session_id // empty' 2>/dev/null)
  aid=$(printf '%s' "$in" | jq -r '.agent_id // empty' 2>/dev/null)
  case "$err" in
    authentication_failed|oauth_org_not_allowed) ;;
    *) _out "AUTH_ALERT_SKIP 유형 무관(${err:-없음})"; return 0 ;;
  esac
  if [ -n "$aid" ]; then _out "AUTH_ALERT_SKIP 서브에이전트"; return 0; fi
  case "$sid" in ''|*[!A-Za-z0-9_-]*) _log "SKIP session_id 무효"; _out "AUTH_ALERT_SKIP session_id 무효"; return 0 ;; esac

  local cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  local sdir="$cfg/session-env/$sid"
  local marker="$sdir/auth_alert_ts" now last
  now=$(date +%s)
  if [ -f "$marker" ]; then
    last=$(tr -dc '0-9' <"$marker" 2>/dev/null)
    if [ -n "$last" ] && [ $((now - last)) -lt 600 ]; then
      _out "AUTH_ALERT_SKIP 10분 내 중복"; return 0
    fi
  fi

  # 세션 이름·프로필명(없으면 미상). 경로·UUID 는 쓰지 않는다.
  local title prof when msg
  title=""
  [ -f "$sdir/work_title" ] && title=$(head -c 80 "$sdir/work_title" 2>/dev/null | tr -d '\r\n')
  [ -n "$title" ] || title="이름 미상"
  prof="${CLAUDE_PROFILE_NAME:-미상}"
  when=$(date '+%Y-%m-%d %H:%M')
  msg="cas 로그인 만료 — 세션: ${title} / 프로필: ${prof} / ${when}. 해당 세션에서 /login 으로 재로그인하세요."

  local pdir
  pdir=$(mktemp -d 2>/dev/null) || { _log "FAIL mktemp"; return 0; }
  jq -cn --arg m "$msg" '{title:"🔑 로그인 만료", message:$m, tags:["key"]}' >"$pdir/ntfy_payload.json" 2>/dev/null
  local proj res rc
  proj="${HOOK_DIR%/.claude/hooks}"
  local args=(--session-dir "$pdir" --project-dir "$proj" --session-id "$sid")
  [ "$DRY" = 1 ] && args+=(--dry-run)
  res=$(bash "$HOOK_DIR/lib/ntfy_send.sh" "${args[@]}" 2>&1); rc=$?
  rm -rf "$pdir" 2>/dev/null
  if [ "$DRY" = 1 ]; then
    printf 'AUTH_ALERT_SEND rc=%s\n%s\n' "$rc" "$res"
    return 0
  fi
  if [ "$rc" = 0 ]; then
    [ -d "$sdir" ] && printf '%s\n' "$now" >"$marker" 2>/dev/null
    _log "OK 발송 error=$err"
  else
    _log "FAIL ntfy rc=$rc error=$err"
  fi
  return 0
}

main
exit 0
