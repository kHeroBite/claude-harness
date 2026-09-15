#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# agent_roster_cleanup.sh — 종료된 팀에이전트의 디스크 잔존물 정리 (F-ROSTER-1)
#
# 배경 (2026-09-13 실사고 — 사이클123 진단의 절반이 틀렸다):
#   사이클123 은 "roster 는 Claude Code in-memory 상태라 우리가 지울 수 없다"(Issue #27639)
#   로 결론내고 "spawn 총량 감축"만 조치했다. 그런데 사이클125 실측에서 드러난 것은 이렇다.
#     · pane 0건 / 프로세스 0건 (정상 종료 확인)
#     · teams/<팀>/config.json 의 members[].isActive = ★전부 false★ (종료가 정상 기록됨)
#     · 그런데 ★$HOME 쪽 session-env/<UUID>/agents/ 에 21건이 그대로 잔존★
#       (사이클123 것까지 섞여 있었다 — 세션 재시작으로도 안 지워진다. 파일이기 때문이다)
#   ⇒ "in-memory 라 못 지운다" 는 ★roster 표시★ 에만 해당한다.
#     디스크 잔존물(agents/ 파일, inboxes/*.json)은 우리 소관이고 지울 수 있다.
#
#   정리를 안 하던 진짜 원인은 ★경로 이중화★ 였다.
#   ofinish/oinit 이 ${CLAUDE_CONFIG_DIR} 쪽만 비우고 $HOME 쪽을 빠뜨렸다.
#   두 base 가 동시 실존하는 세션에서 한쪽만 지우면 나머지가 영구 누적된다.
#
# ★사이클128 정정 — 이 헬퍼가 자기가 고치러 온 증상에 당했다★:
#   초판은 base 를 [${CLAUDE_CONFIG_DIR}, $HOME/.claude] 2개로만 잡았다.
#   그런데 호출자가 CLAUDE_CONFIG_DIR=$HOME/.claude 로 export 하면 두 원소가
#   ★같은 경로★ 가 되어 /tmp/cc-*/ base 가 순회에서 통째로 빠졌다.
#   실측: 잘못된 호출 removed=1(/tmp 쪽 전건 잔존) / 올바른 호출 removed=3.
#   ⇒ 호출자를 믿는 설계가 원인이었다. 호출자는 /tmp/cc-* 를 애초에 알 수 없다.
#   ⇒ 지금은 ★헬퍼가 스스로 3갈래(CFG / $HOME / /tmp/cc-*)를 수집하고
#     realpath 정규화로 중복을 제거한다★. 순회한 base 개수는 logs/roster_cleanup.log 에 남긴다.
#
# 설계 한계 (숨기지 않는다):
#   FleetView 목록 표시 자체는 Claude Code in-memory 이며 이 스크립트가 지우지 못한다.
#   isActive=false 인 멤버를 목록에서 제거하는 것은 도구 구현 영역이다(Issue #27639).
#   ⇒ 이 스크립트가 보장하는 것은 ★디스크가 진실을 반영하는 것★ 이다.
#     다음 세션이 잔존 파일을 보고 "살아 있는 에이전트"로 오판하는 일을 막는다.
#
# 사용:
#   source agent_roster_cleanup.sh
#   cleanup_agent_roster "<UUID>" [team_name]
#
# 세션 격리 (절대 준수):
#   자기 UUID 하위 + 자기 소유 팀만 건드린다. 타 세션 것은 읽지도 지우지도 않는다.
#   ⚠️ teams/<name>/ ★디렉토리 자체는 절대 삭제하지 않는다★ —
#     세션 활성 중 삭제하면 "team file not found" 로 이후 Agent 호출이 전면 차단된다(실측).
#     inboxes/*.json 개별 파일만 정리한다.

cleanup_agent_roster() {
  local _uuid="$1"
  local _team="${2:-}"
  [[ -z "$_uuid" ]] && return 1

  local _removed=0
  local _bases=()
  local _raw=()

  # ★base 는 호출자를 믿지 않고 스스로 전부 찾는다★ (사이클128 T-A1)
  #   이 헬퍼는 사이클127 에 "경로 이중화를 고치려고" 신설됐는데 자기가 그 증상에 당했다.
  #   호출자가 CLAUDE_CONFIG_DIR=$HOME/.claude 로 넘기면 두 원소가 같은 값이 되어
  #   /tmp/cc-* base 가 순회에서 통째로 빠진다 (실측: removed=1, /tmp 쪽 전건 잔존).
  #   ⇒ 중복 제거만으론 불충분하다. base 가 1개로 줄 뿐 /tmp/cc-* 는 여전히 안 돈다.
  #   ⇒ 실존 후보 3갈래를 독립 수집한 뒤 realpath 정규화로 중복을 제거한다.
  [[ -n "${CLAUDE_CONFIG_DIR:-}" ]] && _raw+=("${CLAUDE_CONFIG_DIR}")
  _raw+=("$HOME/.claude")
  # /tmp/cc-*/ — Claude Code 가 런타임에 만드는 경로. 호출자 셸에는 노출되지 않는다.
  # ⚠️ 세션 격리: glob 으로 base 만 찾고, 실제 접근은 반드시 session-env/${_uuid}/ 로 좁힌다.
  #   _uuid 는 자기 UUID 이므로 타 세션 디렉토리에는 경로상 도달이 불가능하다.
  local _g
  for _g in /tmp/cc-*/; do
    [[ -d "$_g" ]] || continue          # nullglob 미설정 시 리터럴 방어 (T-A4)
    _raw+=("${_g%/}")
  done

  # realpath 정규화 후 중복 제거 (심볼릭링크·후행 슬래시 대응)
  #   같은 base 를 두 번 돌면 두 번째에서 파일이 이미 없어 오카운트가 생긴다.
  local _seen="" _r _canon
  for _r in "${_raw[@]}"; do
    [[ -d "$_r" ]] || continue
    _canon=$(realpath -m "$_r" 2>/dev/null) || _canon="$_r"
    [[ -n "$_canon" ]] || _canon="$_r"
    case "|${_seen}|" in
      *"|${_canon}|"*) continue ;;      # 이미 수집됨
    esac
    _seen="${_seen}|${_canon}"
    _bases+=("$_canon")
  done

  # T-A2 — "몇 개 base 를 돌았는가"가 안 보이면 이 사고가 또 조용히 난다
  local _logdir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${_uuid}/logs"
  if [[ -d "$_logdir" ]]; then
    printf '%s roster_cleanup bases=%d [%s] uuid=%s team=%s\n' \
      "$(date -Iseconds)" "${#_bases[@]}" "${_bases[*]}" "$_uuid" "${_team:-<none>}" \
      >> "${_logdir}/roster_cleanup.log" 2>/dev/null
  fi

  for _b in "${_bases[@]}"; do
    local _agents="${_b}/session-env/${_uuid}/agents"
    [[ -d "$_agents" ]] || continue

    # 살아 있는 에이전트는 남긴다 — 프로세스 실존으로만 판정한다.
    # ⚠️ agents/ 파일 존재는 생존의 증거가 아니다(10시간 잔존 실측 이력).
    for _f in "$_agents"/*; do
      [[ -e "$_f" ]] || continue
      local _name
      _name=$(basename "$_f")

      # 이 이름의 에이전트 프로세스가 실제로 살아 있는가
      # (grep 자기 명령줄 오카운트 방지 — grep -v "grep " 필수)
      local _alive
      _alive=$(ps -eo args 2>/dev/null \
        | grep -- "--agent-id ${_name}@" \
        | grep -v "grep " \
        | wc -l)

      if [[ "$_alive" -eq 0 ]]; then
        rm -f "$_f" 2>/dev/null && _removed=$((_removed + 1))
      fi
    done
  done

  # inboxes/*.json — 종료된 멤버의 메일함 정리
  # ⚠️ config.json 과 디렉토리 자체는 건드리지 않는다
  if [[ -n "$_team" ]]; then
    for _b in "${_bases[@]}"; do
      local _inbox="${_b}/teams/${_team}/inboxes"
      [[ -d "$_inbox" ]] || continue

      # 소유권 증명 — leadSessionId == 내 UUID 가 증명되지 않으면 건드리지 않는다
      #   (세션 격리 불변식 §(b) fail-closed — T-A3)
      #   ⚠️ config.json 실존 확인만으로는 약하다. 타 세션 소유 팀도 config.json 은 있다.
      local _cfg="${_b}/teams/${_team}/config.json"
      [[ -f "$_cfg" ]] || continue
      local _lead
      _lead=$(sed -n 's/.*"leadSessionId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_cfg" 2>/dev/null | head -1)
      if [[ "$_lead" != "$_uuid" ]]; then
        # 소유 불확실 → 건드리지 않는다. 관측만 남긴다.
        [[ -d "$_logdir" ]] && printf '%s roster_cleanup inbox_skip team=%s base=%s lead=%s != uuid=%s\n' \
          "$(date -Iseconds)" "$_team" "$_b" "${_lead:-<none>}" "$_uuid" \
          >> "${_logdir}/roster_cleanup.log" 2>/dev/null
        continue
      fi

      for _j in "$_inbox"/*.json; do
        [[ -e "$_j" ]] || continue
        local _mn
        _mn=$(basename "$_j" .json)
        [[ "$_mn" == "team-lead" ]] && continue   # 메인 메일함은 보존

        local _alive2
        _alive2=$(ps -eo args 2>/dev/null \
          | grep -- "--agent-id ${_mn}@" \
          | grep -v "grep " \
          | wc -l)

        if [[ "$_alive2" -eq 0 ]]; then
          rm -f "$_j" 2>/dev/null && _removed=$((_removed + 1))
        fi
      done
    done
  fi

  echo "$_removed"
  return 0
}
