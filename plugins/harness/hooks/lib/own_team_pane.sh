#!/bin/bash
# 자기 세션 팀원 pane 소유 판정과 죽은 팀원 pane 의 증거 캡처·정리를 제공하는 공용 라이브러리
#
# 배경 (2026-10-19 c193, oi-fix-2):
#   - Claude Code(2.1.303) 는 팀원 pane 을 띄울 때 `set-option -p -t <pane> remain-on-exit failed` 를 스스로 건다
#     (바이너리 문자열 실측: set-option -p … remain-on-exit failed → respawn-pane -k).
#     그래서 팀원이 0 이 아닌 코드(예: SIGTERM 143)로 끝나면 pane 이 "죽은 채" 화면에 남는다. 공식 동작이며 우리가 바꿀 수 없다.
#   - 이 죽은 pane 을 정리하려면 메인이 tmux capture-pane/kill-pane 을 해야 하는데, write_guard 가 파이프라인 활성 중
#     메인의 해당 명령을 막아 teammate idle guard(캡처→kill→재spawn 요구)와 교착이 났다.
#   ⇒ ① 소유 판정(otp_owned_pane)을 한 곳에 두고 write_guard 허용 분기와 자동 정리가 함께 쓴다.
#     ② 자동 정리(otp_reap_dead)는 증거를 먼저 남긴 뒤에만 pane 을 지운다.
#
# 소유 판정 기준 (세션 격리 §(a)):
#   pane 의 #{pane_start_command} 에 `--agent-id ` 와 `--parent-session-id <자기 UUID>` 정확 토큰이 모두 있어야 한다.
#   죽은 pane 은 프로세스가 없으므로 /proc 대신 tmux 가 보관한 시작 명령을 본다. 메인 pane(--agent-id 없음)은 절대 대상 아님.
#
# 시험 주입: OTP_TMUX_PANES — "pane_id<TAB>dead<TAB>dead_status<TAB>start_command" 줄 목록(설정 시 tmux 조회 대신 사용)
#            OTP_DRY=1       — capture/kill 을 실행하지 않고 로그만 남긴다
# 계약: 모든 함수는 실패 시 조용히 끝난다(fail-open). 호출 hook 을 막거나 출력을 오염시키지 않는다.

_otp_uuid_ok() {
  case "${1:-}" in
    ''|*[!0-9a-f-]*) return 1 ;;
  esac
  [ "${#1}" -eq 36 ]
}

# 시작 명령 문자열이 자기 세션 팀원 것인가 (0=예)
otp_cmd_owned() {
  local cmd=" ${1:-} " uuid="${2:-}"
  _otp_uuid_ok "$uuid" || return 1
  case "$cmd" in *" --agent-id "*) ;; *) return 1 ;; esac
  case "$cmd" in *" --parent-session-id $uuid "*|*" --parent-session-id $uuid\""*) return 0 ;; esac
  return 1
}

# otp_owned_pane <uuid> <pane_id> [tmux 소켓 이름]  — 자기 세션 팀원 pane 이면 0
otp_owned_pane() {
  local uuid="${1:-}" pane="${2:-}" sock="${3:-}" cmd
  _otp_uuid_ok "$uuid" || return 1
  case "$pane" in %[0-9]*) ;; *) return 1 ;; esac
  case "$pane" in *[!%0-9]*) return 1 ;; esac
  if [ -n "${OTP_TMUX_PANES:-}" ]; then
    cmd=$(printf '%s\n' "$OTP_TMUX_PANES" | awk -F'\t' -v p="$pane" '$1==p{print $4; exit}')
  elif [ -n "$sock" ]; then
    cmd=$(timeout 2 tmux -L "$sock" display-message -p -t "$pane" '#{pane_start_command}' 2>/dev/null)
  else
    cmd=$(timeout 2 tmux display-message -p -t "$pane" '#{pane_start_command}' 2>/dev/null)
  fi
  [ -n "$cmd" ] || return 1
  otp_cmd_owned "$cmd" "$uuid"
}

# otp_reap_dead <uuid> <session_dir>  — 자기 세션 팀원 pane 중 죽은 것만 캡처 후 kill. 정리 개수를 출력.
#   증거: <session_dir>/evidence/dead_panes/<epoch>_<pane>_<agent>.txt (메타 머리말 + 마지막 500줄)
#   로그: <session_dir>/logs/dead_pane_reap.log
#   캡처가 실패하거나 빈 파일이면 kill 하지 않는다(증거 없는 정리 금지).
otp_reap_dead() {
  local uuid="${1:-}" sd="${2:-}" rows line pid dead dst cmd agent ts ev n=0
  _otp_uuid_ok "$uuid" || { echo 0; return 0; }
  [ -n "$sd" ] && [ -d "$sd" ] || { echo 0; return 0; }
  if [ -n "${OTP_TMUX_PANES:-}" ]; then
    rows="$OTP_TMUX_PANES"
  else
    [ -n "${TMUX:-}" ] || { echo 0; return 0; }
    rows=$(timeout 2 tmux list-panes -a -F '#{pane_id}	#{pane_dead}	#{pane_dead_status}	#{pane_start_command}' 2>/dev/null) || { echo 0; return 0; }
  fi
  ev="$sd/evidence/dead_panes"
  while IFS='	' read -r pid dead dst cmd; do
    [ "$dead" = "1" ] || continue
    otp_cmd_owned "$cmd" "$uuid" || continue
    agent=$(printf '%s' "$cmd" | sed -n 's/.*--agent-name \([A-Za-z0-9_-]*\).*/\1/p' | head -n 1)
    agent=${agent:-unknown}
    ts=$(date +%s)
    mkdir -p "$ev" "$sd/logs" 2>/dev/null || continue
    local out="$ev/${ts}_${pid#%}_${agent}.txt"
    if [ "${OTP_DRY:-0}" = "1" ]; then
      printf 'DRY pane=%s agent=%s dead_status=%s\n' "$pid" "$agent" "$dst" > "$out" 2>/dev/null
    else
      {
        printf '# 죽은 팀원 pane 자동 캡처 — %s\n' "$(date '+%F %T %Z')"
        printf '# pane=%s agent=%s dead_status=%s\n# start=%s\n\n' "$pid" "$agent" "$dst" "$(printf '%s' "$cmd" | cut -c1-400)"
        timeout 3 tmux capture-pane -p -J -S -500 -t "$pid" 2>/dev/null
      } > "$out" 2>/dev/null
    fi
    # 머리말 4줄 외 본문이 있어야 증거로 인정한다(DRY 는 예외)
    if [ "${OTP_DRY:-0}" != "1" ] && [ "$(wc -l < "$out" 2>/dev/null || echo 0)" -le 4 ]; then
      printf '%s SKIP pane=%s agent=%s reason=capture_empty\n' "$(date -Iseconds)" "$pid" "$agent" >> "$sd/logs/dead_pane_reap.log" 2>/dev/null
      continue
    fi
    if [ "${OTP_DRY:-0}" != "1" ]; then
      timeout 2 tmux kill-pane -t "$pid" 2>/dev/null || {
        printf '%s FAIL pane=%s agent=%s reason=kill_failed evidence=%s\n' "$(date -Iseconds)" "$pid" "$agent" "$out" >> "$sd/logs/dead_pane_reap.log" 2>/dev/null
        continue
      }
    fi
    n=$((n + 1))
    printf '%s REAP pane=%s agent=%s dead_status=%s evidence=%s\n' "$(date -Iseconds)" "$pid" "$agent" "$dst" "$out" >> "$sd/logs/dead_pane_reap.log" 2>/dev/null
  done <<EOF
$rows
EOF
  echo "$n"
  return 0
}
