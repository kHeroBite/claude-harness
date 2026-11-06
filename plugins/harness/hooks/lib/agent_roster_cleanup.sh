#!/bin/bash
# agent_roster_cleanup.sh — 종료된 팀에이전트의 디스크 잔존물 정리 (F-ROSTER-1)
#
# 배경 (2026-09-13 실사고 — 사이클123 진단의 절반이 틀렸다):
#   사이클123 은 "roster 는 Claude Code in-memory 상태라 우리가 지울 수 없다"(Issue #27639)
#   로 결론내고 "spawn 총량 감축"만 조치했다(디스크 기준으로는 맞고, 런타임 목록은 2026-10-16
#   실측으로 메인의 TaskStop 으로 정리 가능함이 확인됨 — 아래 설계 한계 참조). 사이클125 실측은 이렇다.
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
#   이 스크립트는 런타임 목록(FleetView)을 직접 지우지 못한다. 프로세스 없는 팀원 이름을
#   logs/taskstop_pending.txt 에 남기고, 메인이 TaskStop(task_id=<이름>) 으로 목록에서 정리한다
#   (2026-10-16 실측, ofinish pre_cleanup_0b / oinit 7-B).
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
#
# ★2026-10-10 정정 — 기동 전 팀원의 첫 지시를 지웠다 (F-ROSTER-2)★:
#   생존 판정이 "ps 에 --agent-id <이름>@ 프로세스가 있는가" 하나뿐이었다.
#   부하로 팀원 claude 프로세스가 아직 뜨지 않은 상태에서 리드 Stop 이 발동하자
#   ★아직 읽히지 않은 첫 지시가 든 inbox 2개★를 "죽은 멤버 메일함"으로 삭제했다(removed=2).
#   팀원은 지시 없이 입력 대기로 멈췄다. 게다가 로그가 개수만 남겨 파일명 증거가 없었다.
#   ⇒ 이제 아래 셋 중 하나라도 해당하면 보존한다.
#     · grace   : 파일 mtime 이 ROSTER_GRACE_SEC(기본 900초=15분) 이내 — 기동 유예
#     · alive   : 프로세스 실존 (기존 판정)
#     · pending : inbox 에 read!=true 메시지가 1건 이상 (단 mtime 이 ROSTER_PENDING_MAX_SEC
#                 (기본 86400초=24h)을 넘으면 진짜 고아로 보고 삭제)
#   ⇒ 보존·삭제 모두 파일명을 roster_cleanup.log 에 남긴다 (kept=<이름>:<사유> removed=<이름>).

# 파일 mtime 기준 경과 초. 실패 시 0(=방금 생성으로 간주 → 보존 쪽으로 안전).
_roster_age_sec() {
  local _m
  _m=$(stat -c %Y "$1" 2>/dev/null) || { echo 0; return; }
  [[ "$_m" =~ ^[0-9]+$ ]] || { echo 0; return; }
  echo $(( $(date +%s) - _m ))
}

# inbox 의 미소비(read 가 true 가 아닌) 메시지 수. 파싱 실패 시 -1(=판정 불가 → 보존 쪽).
_roster_inbox_pending() {
  local _n=""
  if command -v jq >/dev/null 2>&1; then
    _n=$(jq '[.[]? | select(.read != true)] | length' "$1" 2>/dev/null)
  elif command -v python3 >/dev/null 2>&1; then
    _n=$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(sum(1 for m in d if not (isinstance(m,dict) and m.get("read") is True)) if isinstance(d,list) else -1)' "$1" 2>/dev/null)
  fi
  [[ "$_n" =~ ^-?[0-9]+$ ]] || _n=-1
  echo "$_n"
}

# ★종료 확정 판정 (사이클181 항목 E)★ — grace 안이어도 지울 수 있는 경우인가.
#   배경: 정리 시점에 팀원이 이미 끝났는데(config members 에서 빠짐·프로세스 0) spawn 후
#         15분 안이라는 이유만으로 agents 파일을 전부 grace 보존했다(사이클180 실측 6건).
#   rc 0 = 종료 확정. 아래를 ★모두★ 만족할 때만이다(프로세스 0 건은 호출자가 확인한다).
#     · agents 파일 spawned_at 이 숫자이고 경과 ≥ ROSTER_MIN_ALIVE_SEC(기본 60초)
#     · agents 파일 team= 의 config.json 이 어느 base 에서든 읽히고 members 가 배열
#     · 그 이름이 isActive=false 이거나,
#       members 에 없고 config.json mtime > spawned_at (R2 — 등록 지연과 제거를 구분한다.
#       config 가 spawn 이후 다시 쓰인 적이 없으면 "아직 등록 전" 일 수 있으므로 보존)
#   rc 1 = 그 밖 전부(isActive=true/null, config 부재·파싱 실패, spawned_at 없음) → 종전 grace 보존.
#   config 는 읽기만 한다. leadSessionId 는 요구하지 않는다(팀 리드 UUID 가 세션 UUID 와 다를 수 있다).
#   사용: _roster_terminated <agents파일> <이름> <base...>
_roster_terminated() {
  local _f="$1" _n="$2"; shift 2
  local _min="${ROSTER_MIN_ALIVE_SEC:-60}"
  [[ "$_min" =~ ^[0-9]+$ ]] || _min=60
  command -v jq >/dev/null 2>&1 || return 1
  local _sp _tm _now _b _cfg="" _st _mt
  _sp=$(sed -n 's/^spawned_at=\([0-9][0-9]*\)[[:space:]]*$/\1/p' "$_f" 2>/dev/null | head -1)
  [[ "$_sp" =~ ^[0-9]+$ ]] || return 1
  _now=$(date +%s)
  (( _now - _sp >= _min )) || return 1
  _tm=$(sed -n 's/^team=\(.*\)$/\1/p' "$_f" 2>/dev/null | head -1)
  [[ -n "$_tm" && "$_tm" != *"/"* && "$_tm" != "."* ]] || return 1
  for _b in "$@"; do
    [[ -f "${_b}/teams/${_tm}/config.json" ]] && { _cfg="${_b}/teams/${_tm}/config.json"; break; }
  done
  [[ -n "$_cfg" ]] || return 1
  _st=$(jq -r --arg n "$_n" '
    if (.members | type) != "array" then "invalid"
    else [.members[] | select(type == "object" and .name == $n)] as $m
      | if ($m | length) == 0 then "absent"
        elif any($m[]; .isActive == true) then "true"
        elif all($m[]; .isActive == false) then "false"
        else "null" end
    end' "$_cfg" 2>/dev/null) || return 1
  case "$_st" in
    false) return 0 ;;
    absent)
      _mt=$(stat -c %Y "$_cfg" 2>/dev/null)
      [[ "$_mt" =~ ^[0-9]+$ ]] || return 1
      # 엄격한 > — 같은 초 갱신은 등록 이후임을 보장하지 못한다(역라우팅 #1, 경계 보존)
      (( _mt > _sp )) && return 0
      return 1 ;;
  esac
  return 1
}

# ★자기 세션 소속 생존 프로세스 수 (사이클182 K6)★
#   배경: 생존 판정이 " --agent-id <이름>@" 하나뿐이라 ★다른 세션에 같은 이름 팀원★이 살아 있으면
#         이 세션의 죽은 팀원 파일을 생존으로 오판해 남겼다(2026-10-12 실측: 자기 세션 소속 0 /
#         타 세션 소속 동명 1 → agents 파일 잔존). Stop_orphan_agent_sweep.sh (1) 과 같은 규칙으로 맞춘다.
#   판정: 같은 프로세스 줄에 " --agent-id <이름>@" 와 " --parent-session-id <UUID> " 가 ★둘 다★ 있어야 센다.
#   ★팀명 축(@<team>)은 쓰지 않는다★ — 런타임 팀명(--team-name)은 session-env team_name 과 다를 수 있다
#     (2026-10-12 실측: 팀원 명령줄 --team-name session-xxxx, session-env team_name 은 빈 파일).
#     parent-session-id 는 리드 세션 UUID 그 자체라 호출 인자 UUID 와 직접 대조된다.
#   ★전체 토큰 일치★ 줄 끝에 공백을 붙여 UUID 접두 오매칭을 막는다. ★열 폭 무관★ ps -eww.
#   사용: _roster_alive_count <이름> <UUID>
_roster_alive_count() {
  ps -eww -o args= 2>/dev/null \
    | sed 's/$/ /' \
    | grep -F -- " --agent-id ${1}@" \
    | grep -F -- " --parent-session-id ${2} " \
    | grep -v "grep " \
    | wc -l
}

cleanup_agent_roster() {
  local _uuid="$1"
  local _team="${2:-}"
  [[ -z "$_uuid" ]] && return 1

  local _removed=0
  local _bases=()
  local _raw=()
  # 기동 유예·미소비 보존 기한 (F-ROSTER-2). 숫자가 아니면 기본값.
  local _grace="${ROSTER_GRACE_SEC:-900}"
  local _pmax="${ROSTER_PENDING_MAX_SEC:-86400}"
  [[ "$_grace" =~ ^[0-9]+$ ]] || _grace=900
  [[ "$_pmax" =~ ^[0-9]+$ ]] || _pmax=86400
  local _kept_names="" _removed_names=""
  local _dead_names=""   # 프로세스 없음으로 확정돼 정리된 팀원 이름 (TaskStop 대기 목록용)

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

  # ★agents 디렉터리도 realpath 로 중복 제거한다★ (사이클181 항목 E)
  #   base 가 서로 달라도 /tmp/cc-*/session-env/<UUID> 가 $HOME 쪽 <UUID> 로 가는 심볼릭 링크면
  #   같은 agents 디렉터리를 두 번 돌아 판정·로그가 중복됐다(실측: 이름이 2번씩 기록).
  local _ag_seen=""
  for _b in "${_bases[@]}"; do
    local _agents="${_b}/session-env/${_uuid}/agents"
    [[ -d "$_agents" ]] || continue
    local _ag_canon
    _ag_canon=$(realpath -m "$_agents" 2>/dev/null) || _ag_canon="$_agents"
    [[ -n "$_ag_canon" ]] || _ag_canon="$_agents"
    case "|${_ag_seen}|" in
      *"|${_ag_canon}|"*) continue ;;
    esac
    _ag_seen="${_ag_seen}|${_ag_canon}"

    # 살아 있는 에이전트는 남긴다 — 프로세스 실존으로만 판정한다.
    # ⚠️ agents/ 파일 존재는 생존의 증거가 아니다(10시간 잔존 실측 이력).
    for _f in "$_agents"/*; do
      [[ -e "$_f" ]] || continue
      local _name
      _name=$(basename "$_f")

      # 기동 유예 — spawn 직후 프로세스가 아직 안 보이는 팀원을 죽은 것으로 보지 않는다
      #   단 종료 확정(_roster_terminated)이고 프로세스 0 이면 유예와 상관없이 지운다.
      if [[ $(_roster_age_sec "$_f") -lt "$_grace" ]]; then
        local _alive0
        _alive0=$(_roster_alive_count "${_name}" "$_uuid")
        if [[ "$_alive0" -eq 0 ]] && _roster_terminated "$_f" "$_name" "${_bases[@]}"; then
          rm -f "$_f" 2>/dev/null && { _removed=$((_removed + 1)); _removed_names="${_removed_names} agents/${_name}:terminated"; _dead_names="${_dead_names} ${_name}"; }
        elif [[ "$_alive0" -gt 0 ]]; then
          _kept_names="${_kept_names} agents/${_name}:alive"
        else
          _kept_names="${_kept_names} agents/${_name}:grace"
        fi
        continue
      fi

      # 이 이름의 에이전트 프로세스가 실제로 살아 있는가
      # (grep 자기 명령줄 오카운트 방지 — grep -v "grep " 필수)
      local _alive
      # ★열 폭 무관★ ps -eww — COLUMNS=80 이면 이름이 길 때 "@" 앞에서 잘려 생존을 놓친다.
      # ★전체 토큰 일치★ " --agent-id <이름>@" 고정 문자열(-F) — 접두 오매칭·정규식 메타문자 차단.
      _alive=$(_roster_alive_count "${_name}" "$_uuid")

      if [[ "$_alive" -eq 0 ]]; then
        rm -f "$_f" 2>/dev/null && { _removed=$((_removed + 1)); _removed_names="${_removed_names} agents/${_name}"; _dead_names="${_dead_names} ${_name}"; }
      else
        # alive 보존도 남긴다 — 로그가 없으면 "왜 안 지웠나" 를 사후에 알 수 없다(관측 공백)
        _kept_names="${_kept_names} agents/${_name}:alive"
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

        # 기동 유예 — 첫 지시가 막 쓰인 inbox 는 팀원이 아직 못 읽었을 수 있다 (F-ROSTER-2)
        local _age
        _age=$(_roster_age_sec "$_j")
        if [[ "$_age" -lt "$_grace" ]]; then
          _kept_names="${_kept_names} inbox/${_mn}:grace"
          continue
        fi

        local _alive2
        # ★열 폭 무관 + 전체 토큰 일치★ (위 agents/ 판정과 동일 — COLUMNS=80 잘림 대응)
        _alive2=$(_roster_alive_count "${_mn}" "$_uuid")

        [[ "$_alive2" -eq 0 ]] || continue

        # 미소비 메시지 보존 — 읽히지 않은 지시는 지우지 않는다.
        #   단 24h(ROSTER_PENDING_MAX_SEC) 넘게 방치된 것은 진짜 고아로 보고 삭제한다.
        local _pend
        _pend=$(_roster_inbox_pending "$_j")
        if [[ "$_pend" -ne 0 && "$_age" -lt "$_pmax" ]]; then
          _kept_names="${_kept_names} inbox/${_mn}:pending(${_pend})"
          continue
        fi

        rm -f "$_j" 2>/dev/null && { _removed=$((_removed + 1)); _removed_names="${_removed_names} inbox/${_mn}"; _dead_names="${_dead_names} ${_mn}"; }
      done
    done
  fi

  # 파일명 로그 — 개수만 남기면 무엇을 지웠는지 사후에 알 수 없다 (F-ROSTER-2)
  if [[ -d "$_logdir" ]]; then
    printf '%s roster_cleanup result uuid=%s team=%s removed=%d removed_names=[%s] kept=[%s]\n' \
      "$(date -Iseconds)" "$_uuid" "${_team:-<none>}" "$_removed" \
      "${_removed_names# }" "${_kept_names# }" \
      >> "${_logdir}/roster_cleanup.log" 2>/dev/null
  fi

  # ★TaskStop 대기 목록 (경고 전용 — 차단 없음)★
  #   디스크 정리로는 FleetView(in-memory) 목록이 안 지워진다. 프로세스가 없는 팀원은 메인이
  #   TaskStop(task_id=<이름>) 으로 정리할 수 있다(2026-10-16 실측: plans/taskstop_probe.md).
  #   살아 있는 팀원은 위 판정에서 alive 로 보존돼 여기 들어오지 않는다(TaskStop 하면 작업이 끊긴다).
  #   자기 UUID 의 logs/ 에만 쓴다. 쓰기 실패는 정리 결과에 영향을 주지 않는다.
  local _pend_list="" _pend_n=0 _d
  for _d in $_dead_names; do
    case " ${_pend_list} " in *" ${_d} "*) continue ;; esac
    _pend_list="${_pend_list} ${_d}"
    _pend_n=$((_pend_n + 1))
  done
  _pend_list="${_pend_list# }"
  if [[ "$_pend_n" -gt 0 && -d "$_logdir" ]]; then
    printf '%s\n' $_pend_list > "${_logdir}/taskstop_pending.txt" 2>/dev/null
  fi

  echo "$_removed"
  # 출력 형식 TASKSTOP_PENDING n: 이름… — 첫 줄(removed 숫자)은 기존 호출자·시험 호환을 위해 유지한다.
  #   둘째 줄은 호출자가 ROSTER_EMIT_TASKSTOP=1 로 요청했을 때만 낸다(기본 off — 숫자 단독 파싱 보호).
  if [[ "$_pend_n" -gt 0 && "${ROSTER_EMIT_TASKSTOP:-0}" == "1" ]]; then
    echo "TASKSTOP_PENDING ${_pend_n}: ${_pend_list}"
  fi
  return 0
}
