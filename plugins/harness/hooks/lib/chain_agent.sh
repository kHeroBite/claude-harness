#!/bin/bash
# hook 프로세스의 부모 체인에서 팀원 식별자(--agent-id NAME@TEAM, --parent-session-id LEAD)를 찾아 CA_NAME/CA_TEAM/CA_LEAD 로 내보내는 공용 함수
# 사용: source 후 chain_agent_resolve; 성공 시 rc=0 + CA_NAME/CA_TEAM/CA_LEAD/CA_SDIR 설정 (리드 session-env/team_name == TEAM 소유 검증 포함)
# 테스트 전용: CA_TEST=1 이면 CA_TEST_AGENT=NAME@TEAM, CA_TEST_LEAD=<uuid> 사용 (TeammateIdle_report_guard.sh 와 동일 방식)

chain_agent_resolve() {
  local agent="" lead="" pid s nxt a _
  CA_NAME=""; CA_TEAM=""; CA_LEAD=""; CA_SDIR=""
  if [[ "${CA_TEST:-}" == "1" ]]; then
    agent="${CA_TEST_AGENT:-}"; lead="${CA_TEST_LEAD:-}"
  else
    pid=$$
    for _ in 1 2 3 4 5 6; do
      [[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 1 )) || break
      if [[ -r "/proc/$pid/cmdline" ]]; then
        nxt=""
        while IFS= read -r -d '' a; do
          if [[ "$nxt" == "agent" ]]; then agent="$a"; nxt=""
          elif [[ "$nxt" == "lead" ]]; then lead="$a"; nxt=""
          elif [[ "$a" == "--agent-id" ]]; then nxt="agent"
          elif [[ "$a" == "--parent-session-id" ]]; then nxt="lead"
          fi
        done < "/proc/$pid/cmdline"
        [[ -n "$agent" ]] && break
      fi
      s=$(<"/proc/$pid/stat") || break
      s="${s##*) }"
      read -r _ pid _ <<<"$s"
    done
  fi
  [[ "$agent" == *@* ]] || return 1
  CA_NAME="${agent%%@*}"; CA_TEAM="${agent#*@}"
  [[ "$CA_NAME" =~ ^[A-Za-z0-9._-]+$ && "$CA_TEAM" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  [[ "$CA_NAME" != "." && "$CA_NAME" != ".." && "$CA_TEAM" != "." && "$CA_TEAM" != ".." ]] || return 1
  [[ "$lead" =~ ^[0-9a-f-]{36}$ ]] || return 1
  CA_LEAD="$lead"
  CA_SDIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/$CA_LEAD"
  [[ -f "$CA_SDIR/team_name" ]] || return 1
  [[ "$(tr -d '[:space:]' < "$CA_SDIR/team_name" 2>/dev/null)" == "$CA_TEAM" ]] || return 1
  return 0
}

# 리드 team_name 파일을 요구하지 않는 argv 기반 2순위 판별 — IDLE 위임처럼 리드 team_name 이 지워진 뒤에도 팀원을 가린다
# 사용: chain_agent_resolve_argv <자기 session_id>; 성공 시 rc=0 + CA_NAME/CA_TEAM/CA_LEAD/CA_SDIR 설정
# 조건: --agent-id NAME@TEAM 형식, --parent-session-id LEAD uuid 형식, session-env/LEAD/state 존재, LEAD ≠ 자기 session_id,
#       --team-name 이 있으면 TEAM 과 같음, teams/TEAM/config.json 이 있으면 leadSessionId==LEAD 또는 members 에 NAME(읽기만)
# 테스트 전용: CA_TEST=1 이면 CA_TEST_AGENT·CA_TEST_LEAD 와 CA_TEST_TEAM_NAME(--team-name 값, 비우면 없음) 사용
chain_agent_resolve_argv() {
  local self_sid="${1:-}" agent="" lead="" tname="" has_tname=0 pid s nxt a _ cfg conf ok
  CA_NAME=""; CA_TEAM=""; CA_LEAD=""; CA_SDIR=""
  if [[ "${CA_TEST:-}" == "1" ]]; then
    agent="${CA_TEST_AGENT:-}"; lead="${CA_TEST_LEAD:-}"
    if [[ -n "${CA_TEST_TEAM_NAME+x}" && -n "${CA_TEST_TEAM_NAME}" ]]; then tname="$CA_TEST_TEAM_NAME"; has_tname=1; fi
  else
    pid=$$
    for _ in 1 2 3 4 5 6; do
      [[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 1 )) || break
      if [[ -r "/proc/$pid/cmdline" ]]; then
        nxt=""
        while IFS= read -r -d '' a; do
          if [[ "$nxt" == "agent" ]]; then agent="$a"; nxt=""
          elif [[ "$nxt" == "lead" ]]; then lead="$a"; nxt=""
          elif [[ "$nxt" == "tname" ]]; then tname="$a"; has_tname=1; nxt=""
          elif [[ "$a" == "--agent-id" ]]; then nxt="agent"
          elif [[ "$a" == "--parent-session-id" ]]; then nxt="lead"
          elif [[ "$a" == "--team-name" ]]; then nxt="tname"
          fi
        done < "/proc/$pid/cmdline"
        [[ -n "$agent" ]] && break
        lead=""; tname=""; has_tname=0   # agent 없는 프로세스의 값은 다른 체인 단계와 섞지 않는다
      fi
      s=$(<"/proc/$pid/stat") || break
      s="${s##*) }"
      read -r _ pid _ <<<"$s"
    done
  fi
  [[ "$agent" == *@* ]] || return 1
  local name="${agent%%@*}" team="${agent#*@}"
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ && "$team" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  [[ "$name" != "." && "$name" != ".." && "$team" != "." && "$team" != ".." ]] || return 1
  [[ "$lead" =~ ^[0-9a-f-]{36}$ ]] || return 1
  [[ -n "$self_sid" && "$lead" != "$self_sid" ]] || return 1
  if (( has_tname )); then
    [[ "$tname" == "$team" ]] || return 1
  fi
  cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  [[ -f "$cfg/session-env/$lead/state" ]] || return 1
  conf="$cfg/teams/$team/config.json"
  if [[ -e "$conf" ]]; then
    ok=$(jq -r --arg l "$lead" --arg n "$name" \
      'if (.leadSessionId == $l) or ([.members[]? | select(type == "object") | .name] | index($n) != null) then "1" else "0" end' \
      "$conf" 2>/dev/null) || return 1
    [[ "$ok" == "1" ]] || return 1
  fi
  CA_NAME="$name"; CA_TEAM="$team"; CA_LEAD="$lead"
  CA_SDIR="$cfg/session-env/$CA_LEAD"
  return 0
}
