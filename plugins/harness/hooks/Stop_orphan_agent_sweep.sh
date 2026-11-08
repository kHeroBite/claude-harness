#!/bin/bash
# Stop_orphan_agent_sweep.sh — 턴 종료 시 자기 세션 소속 고아 팀에이전트 pane + agents 파일 자동 정리 (F-ORPHAN-1)
#
# 배경 (2026-09-15 실사고):
#   파이프라인 완료 후 고아 tmux pane 4개 + agents 등록 12건(양쪽 base 각 12건)이 잔존했다.
#   사용자가 지적할 때까지 아무도 감지하지 못했다.
#
# 원인 3가지 (전부 실측 확인):
#   1. 메인이 shutdown_request 발송 후 pane 소멸을 실측하지 않았다.
#      ok/SKILL.md 에 규칙은 있었으나 강제력이 없어 지켜지지 않았다.
#   2. ★핵심★ 잔존 4개(plugin-research/repo-check/spec-verify/private-update-check)는 전부
#      SendMessage 도구가 없는 에이전트 유형이었다. shutdown_request 에 응답할 수단 자체가
#      없어 종료 프로토콜이 구조적으로 성립하지 않는다. 설계 결함이다.
#   3. hooks/lib/agent_roster_cleanup.sh 는 ofinish/oinit SKILL.md 에서만 호출된다.
#      hook 등록이 없어 두 스킬을 거치지 않으면 아무도 정리하지 않는다.
#      → CLAUDE.md 재발방지 정책이 금지하는 "LLM 의지 의존" 상태다.
#
# 본 hook 은 CLAUDE.md 재발방지 우선순위 1순위(Hook 물리 차단)로 이를 해소한다.
# 스킬 경유 여부와 무관하게 매 턴 종료 시 자동 실행되므로 LLM 의지에 의존하지 않는다.
#
# ★--agent-id 는 pane_pid 자체에 있다★ (2026-09-15 실측):
#   pgrep -P 로 자식 프로세스를 찾으면 4개 전부 놓쳐 "--agent-id 없음"으로 오판정한다.
#   반드시 `ps -p <pane_pid> -o args=` 로 pane_pid 자체의 인자를 확인한다.
#
# 세션 격리 불변식 §(a)(d) 절대 준수:
#   자기 UUID 소속으로 ★증명된★ pane/agents 만 건드린다.
#   --agent-id <name>@ 와 --parent-session-id <내UUID> 를 ★둘 다★ 매칭한다.
#   이름만 매칭하면 타 세션 동명 에이전트(odev-1 등)를 내 것으로 오판한다(2026-09-15 실측).
#
# fail-open: 어떤 실패도 exit 0. 세션 종료를 막지 않는다.

set +e

# ── tmux 부재 환경 방어 ──────────────────────────────────────────────
command -v tmux >/dev/null 2>&1 || exit 0

# ── a. 자기 UUID 확보 ────────────────────────────────────────────────
#   hook input JSON 의 session_id 가 1순위, PIPELINE_UUID env 가 2순위.
HOOK_INPUT=""
if [ ! -t 0 ]; then
  HOOK_INPUT=$(timeout 2 cat 2>/dev/null)
fi

MY_UUID=""
if [ -n "$HOOK_INPUT" ]; then
  MY_UUID=$(printf '%s' "$HOOK_INPUT" \
    | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
fi
[ -z "$MY_UUID" ] && MY_UUID="${PIPELINE_UUID:-}"
[ -z "$MY_UUID" ] && MY_UUID="${CLAUDE_SESSION_ID:-}"

# UUID 를 모르면 아무것도 하지 않는다 — 소유권 증명 불가 시 fail-closed (§(b))
[ -z "$MY_UUID" ] && exit 0

CFG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SESSION_DIR="${CFG_DIR}/session-env/${MY_UUID}"
LOG_DIR="${SESSION_DIR}/logs"
LOG_FILE="${LOG_DIR}/orphan_agent_sweep.log"
CAPTURE_DIR="${SESSION_DIR}/evidence/pane_capture"
TS=$(date -Iseconds 2>/dev/null)

mkdir -p "$LOG_DIR" 2>/dev/null

_log() {
  printf '[%s] %s\n' "$TS" "$*" >> "$LOG_FILE" 2>/dev/null
}

# ── 자기 pane 식별 (메인 pane kill 3중 방어 중 1순위 — L-304) ────────
MY_PANE="${TMUX_PANE:-}"
DM_PANE=$(tmux display-message -p '#{pane_id}' 2>/dev/null)

# ── 현재 파이프라인 stage 판독 ───────────────────────────────────────
#   PLAN/DEV/TEST/DONE 활성 중 정상 동작하는 에이전트는 절대 건드리지 않는다.
CUR_STATE="UNKNOWN"
if [ -f "${SESSION_DIR}/state" ]; then
  CUR_STATE=$(awk '{print $1}' "${SESSION_DIR}/state" 2>/dev/null | head -1)
fi
[ -z "$CUR_STATE" ] && CUR_STATE="UNKNOWN"

# status 축 — PAUSE/ABORT/ROOF 중이면 정리하지 않는다 (진행 중 작업 보호)
CUR_STATUS=""
[ -f "${SESSION_DIR}/status" ] && CUR_STATUS=$(head -1 "${SESSION_DIR}/status" 2>/dev/null)
case "$CUR_STATUS" in
  *PAUSE*|*ABORT*|*ROOF*|*RALPH*)  # ROOF-COMPAT(deprecation window 1주기 — 구 RALPH/oralph_active 인식 제거 예정)
    _log "SKIP_ALL status=${CUR_STATUS}"
    exit 0
    ;;
esac

# ── b. pane 전수 열거 ────────────────────────────────────────────────
#   ★dash 주의★ 파이프 뒤 while 은 서브셸이라 카운터가 밖으로 안 나온다.
#   임시 파일로 pane 목록을 받아 현재 셸에서 순회한다.
PANE_LIST="${LOG_DIR}/.orphan_sweep_panes.$$"
tmux list-panes -a -F '#{pane_id} #{pane_pid}' > "$PANE_LIST" 2>/dev/null

KILLED=0

# ── 조건 3 다중 근거 판정 (F-ORPHAN-2 — 사이클182, 2026-10-18 실사고) ──
#   배경: 시스템 정체(load=1000‰)로 agent_lifecycle.sh 가 time_budget 을 넘겨 agents/ 등록을
#     남기지 못했다. 조건 3 은 "agents 파일 없음" 하나만 보고 unregistered_orphan 으로 확정해
#     살아 있는 팀원(oplan-4, pane %126)을 kill 했다. 그 순간 팀 config 에는 isActive=true·
#     tmuxPaneId=%126 으로 있었다. 단일 근거로 비가역 조치를 내린 판정 설계가 결함이었다.
#   규칙: 아래 근거 중 하나라도 맞으면 kill 하지 않는다.
#     agents_file   — agents/<NAME> (3갈래 base)
#     pane_index    — panes/pane_index 에 <PANE_ID>=<NAME> 행 (3갈래 base)
#     team_config   — teams/<팀>/config.json 멤버 중 agentId·tmuxPaneId 가 둘 다 같고 isActive!=false
#                     (leadSessionId 는 보지 않는다 — 런타임 팀의 leadSessionId 가 PIPELINE_UUID 와
#                      다르게 기록되는 것이 실측됐다. 소유권은 이미 --parent-session-id 로 증명됐다. 읽기만 한다)
#     young_process — pane 프로세스 경과시간(etimes) < 유예(ROSTER_GRACE_SEC, 기본 900초)
#   판정 수단(jq·config 파싱·etimes 판독)이 실패하면 "불확실"로 보고 kill 하지 않는다(fail-safe).
#   결과는 전역 SRE_TOKEN(근거)·SRE_TEAM(team_config 일치 팀)·SRE_WHY(불확실 사유)에 둔다.
#   rc: 0=근거 있음, 1=근거 없음(확실), 2=판정 불확실
ORPHAN_GRACE_SEC="${ROSTER_GRACE_SEC:-900}"
case "$ORPHAN_GRACE_SEC" in ''|*[!0-9]*) ORPHAN_GRACE_SEC=900 ;; esac

_sweep_registered_evidence() {
  local NAME="$1" PID_ID="$2" AID="$3" PPID_="$4"
  local B T CF CNT ET TEAMS="" SEEN_T="" JQ_RC
  SRE_TOKEN=""; SRE_TEAM=""; SRE_WHY=""

  # 1. agents 파일 — 한쪽 base 에만 있어도 등록된 것으로 본다
  for B in "$CFG_DIR" "$HOME/.claude" /tmp/cc-*/; do
    B="${B%/}"
    [ -d "$B" ] || continue
    if [ -e "${B}/session-env/${MY_UUID}/agents/${NAME}" ]; then
      SRE_TOKEN="agents_file"; return 0
    fi
  done

  # 2. pane_index 의 <PANE_ID>=<NAME> 행
  for B in "$CFG_DIR" "$HOME/.claude" /tmp/cc-*/; do
    B="${B%/}"
    [ -f "${B}/session-env/${MY_UUID}/panes/pane_index" ] || continue
    if grep -qxF -- "${PID_ID}=${NAME}" "${B}/session-env/${MY_UUID}/panes/pane_index" 2>/dev/null; then
      SRE_TOKEN="pane_index"; return 0
    fi
  done

  # 3. 팀 config 활성 멤버 — 팀명 후보: 자기 세션 team_name 1행, agentId 의 @ 뒤
  [ -f "${SESSION_DIR}/team_name" ] && TEAMS=$(head -1 "${SESSION_DIR}/team_name" 2>/dev/null)
  case "$AID" in *@*) TEAMS="${TEAMS} ${AID#*@}" ;; esac
  for T in $TEAMS; do
    case "$T" in */*|.*) continue ;; esac            # 경로 탈출 차단
    case " ${SEEN_T} " in *" ${T} "*) continue ;; esac
    SEEN_T="${SEEN_T} ${T}"
    for B in "$CFG_DIR" "$HOME/.claude" /tmp/cc-*/; do
      B="${B%/}"
      CF="${B}/teams/${T}/config.json"
      [ -f "$CF" ] || continue
      if ! command -v jq >/dev/null 2>&1; then
        SRE_WHY="${SRE_WHY:+${SRE_WHY},}no_jq"
        continue
      fi
      CNT=$(jq -r --arg id "$AID" --arg p "$PID_ID" \
        '[.members[]? | select(.agentId==$id and .tmuxPaneId==$p and (.isActive!=false))] | length' \
        "$CF" 2>/dev/null)
      JQ_RC=$?
      case "$CNT" in ''|*[!0-9]*) JQ_RC=99 ;; esac
      if [ "$JQ_RC" -ne 0 ]; then
        SRE_WHY="${SRE_WHY:+${SRE_WHY},}config_parse_fail:${T}"
        continue
      fi
      if [ "$CNT" -gt 0 ]; then
        SRE_TOKEN="team_config"; SRE_TEAM="$T"; return 0
      fi
    done
  done

  # 4. 프로세스 경과시간 < 유예
  ET=$(ps -o etimes= -p "$PPID_" 2>/dev/null | tr -d ' \n')
  case "$ET" in
    ''|*[!0-9]*) SRE_WHY="${SRE_WHY:+${SRE_WHY},}etimes_fail" ;;
    *)
      if [ "$ET" -lt "$ORPHAN_GRACE_SEC" ]; then
        SRE_TOKEN="young_process"; return 0
      fi
      ;;
  esac

  [ -n "$SRE_WHY" ] && return 2
  return 1
}

while read -r PANE_ID PANE_PID; do
  [ -z "$PANE_ID" ] && continue

  # ── d. 메인 pane 3중 방어 (L-213/L-304) ────────────────────────────
  #   1순위 $TMUX_PANE — 실제 자기 pane
  if [ -n "$MY_PANE" ] && [ "$PANE_ID" = "$MY_PANE" ]; then
    _log "SKIP_SELF_ENV pane=${PANE_ID}"
    continue
  fi
  #   2순위 display-message 결과 병행
  if [ -n "$DM_PANE" ] && [ "$PANE_ID" = "$DM_PANE" ]; then
    _log "SKIP_SELF_DM pane=${PANE_ID}"
    continue
  fi

  # ── c. pane_pid ★자체★ 의 인자 확인 ────────────────────────────────
  #   ★실측★ --agent-id 는 pane_pid 자체에 있다. 자식 프로세스가 아니다.
  #   pgrep -P 로 자식을 찾으면 전부 놓친다(2026-09-15 오판정 사고).
  PARGS=""
  if [ -n "$PANE_PID" ]; then
    # ★-ww 필수★ hook 환경 COLUMNS=80(tmux 상속) 이면 ps 가 80열에서 잘라 --parent-session-id 가 사라진다.
    PARGS=$(ps -ww -p "$PANE_PID" -o args= 2>/dev/null)
  fi

  # ── d. --agent-id 없으면 메인 pane → 절대 kill 금지 ────────────────
  case "$PARGS" in
    *--agent-id*) : ;;
    *)
      _log "SKIP_NO_AGENT_ID pane=${PANE_ID} pid=${PANE_PID}"
      continue
      ;;
  esac

  # ── e. parent-session-id 불일치 = 타 세션 → 절대 skip (§(a)(d)) ────
  #   ★실측★ 타 세션 odev-1~4@session-cf3e2075 가 동시 생존한다.
  #     이름이 같아도 건드리면 타 세션 파괴 사고다.
  PARENT=$(printf '%s' "$PARGS" \
    | sed -n 's/.*--parent-session-id[ =]\([^ ]*\).*/\1/p' | head -1)
  if [ "$PARENT" != "$MY_UUID" ]; then
    _log "SKIP_OTHER_SESSION pane=${PANE_ID} parent=${PARENT:-<none>} mine=${MY_UUID}"
    continue
  fi

  # 에이전트 이름 추출 (--agent-id <name>@<team>)
  AGENT_ID=$(printf '%s' "$PARGS" \
    | sed -n 's/.*--agent-id[ =]\([^ ]*\).*/\1/p' | head -1)
  AGENT_NAME="${AGENT_ID%%@*}"
  [ -z "$AGENT_NAME" ] && continue

  # ── f. 여기까지 온 pane 만 자기 세션 소속으로 증명됨 → 정리 후보 ────

  # 이름 기반 명시 제외 — 오래 살아 있는 것이 정상인 에이전트
  #   oi-*   : 사용자 입력을 장시간 대기한다
  #   obuild*: 빌드 자체가 장시간 소요된다
  #   team-lead: 리드를 죽이면 팀 전체가 정지한다
  #   oopus-*/osonnet-*/ohaiku-*/oteam-*: IDLE 에서 띄우는 위임 팀원이라 state=IDLE 이 정상이다 (2026-10-29 idle_state 오살 사고)
  case "$AGENT_NAME" in
    oi|oi-*|obuild*|team-lead|oopus-*|osonnet-*|ohaiku-*|oteam-*)
      _log "SKIP_WHITELIST pane=${PANE_ID} name=${AGENT_NAME}"
      continue
      ;;
  esac

  # no_kill 마커 — 존재하면 어떤 조건에서도 kill 하지 않는다 (ok/SKILL.md G4)
  if [ -f "${SESSION_DIR}/no_kill/${AGENT_NAME}" ]; then
    _log "SKIP_NO_KILL pane=${PANE_ID} name=${AGENT_NAME}"
    continue
  fi

  # ── 정리 조건 판정 (아래 중 하나 충족 시에만 kill) ──────────────────
  REASON=""

  # 조건 1: pane 의 프로세스가 이미 죽었는데 pane 만 남아 있다
  if ! kill -0 "$PANE_PID" 2>/dev/null; then
    REASON="dead_process"
  fi

  # 조건 2: state 가 IDLE 인데 pane 이 남아 있다
  #   예외: entry_tier 첫 줄이 OK 인 IDLE 은 인스턴스 플랜(/odebate·/oconsult·/odeep·/oplan, L-422)이라
  #   state=IDLE 이어도 팀원이 정상 동작 중이다. kill 대신 SKIP_INSTANCE_PLAN 로그만 남긴다(조건 1·3 은 그대로).
  if [ -z "$REASON" ] && [ "$CUR_STATE" = "IDLE" ]; then
    if [ "$(head -1 "${SESSION_DIR}/entry_tier" 2>/dev/null)" = "OK" ]; then
      _log "SKIP_INSTANCE_PLAN pane=${PANE_ID} name=${AGENT_NAME} entry_tier=OK"
    else
      REASON="idle_state"
    fi
  fi

  # 조건 3: 등록 근거가 ★하나도★ 없고 판정이 확실할 때만 완전 고아로 본다 (F-ORPHAN-2)
  #   agents 파일 하나만 보던 단일 근거 판정을 다중 근거로 바꿨다(_sweep_registered_evidence 참조).
  if [ -z "$REASON" ]; then
    _sweep_registered_evidence "$AGENT_NAME" "$PANE_ID" "$AGENT_ID" "$PANE_PID"
    SRE_RC=$?
    if [ "$SRE_RC" -eq 0 ]; then
      _log "SKIP_REGISTERED pane=${PANE_ID} name=${AGENT_NAME} evidence=${SRE_TOKEN}"
      # 자가 치유 — 팀 config 로 등록이 증명됐는데 agents 파일이 없으면 ★자기 세션★ 에만 다시 쓴다.
      #   타 세션 경로에는 절대 쓰지 않는다(세션 격리 §(a)). 실패해도 판정에는 영향 없다.
      if [ "$SRE_TOKEN" = "team_config" ] && mkdir -p "${SESSION_DIR}/agents" 2>/dev/null; then
        if [ ! -e "${SESSION_DIR}/agents/${AGENT_NAME}" ] && printf 'pane_id=%s\nteam=%s\nspawned_at=%s\nagent_type=%s\nsource=sweep_heal\n' \
             "$PANE_ID" "$SRE_TEAM" "$(date +%s)" "${AGENT_NAME%%-*}" \
             > "${SESSION_DIR}/agents/${AGENT_NAME}" 2>/dev/null; then
          mkdir -p "${SESSION_DIR}/panes" 2>/dev/null
          grep -qxF -- "${PANE_ID}=${AGENT_NAME}" "${SESSION_DIR}/panes/pane_index" 2>/dev/null \
            || printf '%s=%s\n' "$PANE_ID" "$AGENT_NAME" >> "${SESSION_DIR}/panes/pane_index" 2>/dev/null
          _log "HEALED pane=${PANE_ID} name=${AGENT_NAME} team=${SRE_TEAM}"
        fi
      fi
    elif [ "$SRE_RC" -eq 2 ]; then
      # 판정 불확실 — 비가역 조치(kill)를 하지 않는다 (fail-safe)
      _log "WARN_UNCERTAIN pane=${PANE_ID} name=${AGENT_NAME} why=${SRE_WHY}"
      continue
    else
      REASON="unregistered_orphan"
    fi
  fi

  # 파이프라인 활성(PLAN/DEV/TEST/DONE) 중 정상 동작 에이전트는 절대 건드리지 않는다
  if [ -z "$REASON" ]; then
    _log "SKIP_ACTIVE pane=${PANE_ID} name=${AGENT_NAME} state=${CUR_STATE}"
    continue
  fi

  # ── kill 전 필수: 스크롤백 캡처 (kill 은 증거를 영구 소멸시킨다) ────
  #   캡처 실패는 kill 을 막지 않는다(fail-open). 실패 사실만 로그에 남긴다.
  mkdir -p "$CAPTURE_DIR" 2>/dev/null
  CAP_FILE="${CAPTURE_DIR}/$(date +%Y%m%d_%H%M%S)_${AGENT_NAME}_${PANE_ID#%}.log"
  if tmux capture-pane -p -S -3000 -t "$PANE_ID" > "$CAP_FILE" 2>/dev/null; then
    _log "CAPTURED pane=${PANE_ID} name=${AGENT_NAME} file=${CAP_FILE}"
  else
    _log "CAPTURE_FAIL pane=${PANE_ID} name=${AGENT_NAME}"
  fi

  tmux kill-pane -t "$PANE_ID" 2>/dev/null
  KILLED=$((KILLED + 1))
  _log "KILLED pane=${PANE_ID} name=${AGENT_NAME} reason=${REASON} state=${CUR_STATE}"
done < "$PANE_LIST"

rm -f "$PANE_LIST" 2>/dev/null

# ── agents 파일 정리 — 기존 헬퍼 재사용 (중복 구현 금지) ─────────────
#   agent_roster_cleanup.sh 는 3갈래 base(CFG / $HOME / /tmp/cc-*)를 스스로 수집한다.
#   헬퍼의 생존 판정도 사이클182(K6)부터 이 hook (1) 과 같은 규칙이다 —
#     `--agent-id <name>@` 와 `--parent-session-id <UUID>` 를 ★둘 다★ 매칭한다(_roster_alive_count).
#     (그 전에는 `--agent-id` 만 매칭해 타 세션 동명 에이전트를 "생존"으로 오판했다 —
#      2026-09-15 실측: 타 세션 odev-1 이 내 odev-1 파일을 살렸다. 2026-10-12 otest-1 재현.)
#     이 hook 은 (1) 에서 agents 를 먼저 판정하고, 헬퍼는 그 뒤 나머지(inboxes 등)를 담당한다.
ROSTER_REMOVED=0
ROSTER_REMOVED_NAMES=""
ROSTER_KEPT_NAMES=""

# 기동 유예 (F-ROSTER-2 — 2026-10-10 실사고):
#   spawn 직후 부하로 팀원 프로세스가 아직 안 뜬 상태에서 이 hook 이 돌면
#   "프로세스 없음 = 사망" 으로 판정해 등록 파일·첫 지시 inbox 를 지웠다.
#   mtime 이 ROSTER_GRACE_SEC(기본 900초) 이내인 파일은 판정하지 않고 보존한다.
#   헬퍼(agent_roster_cleanup.sh)도 같은 변수로 같은 유예를 적용한다.
GRACE_SEC="${ROSTER_GRACE_SEC:-900}"
case "$GRACE_SEC" in ''|*[!0-9]*) GRACE_SEC=900 ;; esac
NOW_EPOCH=$(date +%s)

# 종료 확정 판정(_roster_terminated)은 헬퍼의 것을 그대로 쓴다 (사이클181 항목 E — 같은 규칙 이식).
#   헬퍼는 함수 정의만 있으므로 source 해도 부작용이 없다. 없으면 종전 grace 판정만 한다(fail-safe).
ROSTER_LIB="${CFG_DIR}/hooks/lib/agent_roster_cleanup.sh"
[ -f "$ROSTER_LIB" ] || ROSTER_LIB="${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/agent_roster_cleanup.sh"
[ -f "$ROSTER_LIB" ] && source "$ROSTER_LIB" 2>/dev/null
AG_SEEN=""

# (1) 이 hook 의 엄밀 판정 — --agent-id + parent-session-id 둘 다 매칭
for B in "$CFG_DIR" "$HOME/.claude" /tmp/cc-*/; do
  B="${B%/}"
  [ -d "$B" ] || continue
  AG_DIR="${B}/session-env/${MY_UUID}/agents"
  [ -d "$AG_DIR" ] || continue
  # 같은 agents 디렉터리 이중 순회 차단 — /tmp/cc-*/session-env/<UUID> 는 $HOME 쪽으로 가는 심볼릭 링크다
  AG_CANON=$(realpath -m "$AG_DIR" 2>/dev/null)
  [ -n "$AG_CANON" ] || AG_CANON="$AG_DIR"
  case "|${AG_SEEN}|" in *"|${AG_CANON}|"*) continue ;; esac
  AG_SEEN="${AG_SEEN}|${AG_CANON}"
  for F in "$AG_DIR"/*; do
    [ -e "$F" ] || continue
    N=$(basename "$F")
    case "$N" in
      oi|oi-*|obuild*|team-lead|oopus-*|osonnet-*|ohaiku-*|oteam-*) continue ;;
    esac
    # 기동 유예 — mtime 판독 실패 시에도 보존 쪽(안전)으로 본다
    #   단 종료 확정 + 프로세스 0 이면 유예와 상관없이 지운다(헬퍼와 같은 규칙).
    MT=$(stat -c %Y "$F" 2>/dev/null)
    case "$MT" in ''|*[!0-9]*) MT="$NOW_EPOCH" ;; esac
    if [ $((NOW_EPOCH - MT)) -lt "$GRACE_SEC" ]; then
      ALIVE0=$(ps -eww -o args= 2>/dev/null \
        | sed 's/$/ /' \
        | grep -F -- " --agent-id ${N}@" \
        | grep -F -- " --parent-session-id ${MY_UUID} " \
        | grep -v "grep " \
        | wc -l)
      if [ "$ALIVE0" -eq 0 ] && declare -F _roster_terminated >/dev/null 2>&1 \
         && _roster_terminated "$F" "$N" "$CFG_DIR" "$HOME/.claude" /tmp/cc-*/; then
        rm -f "$F" 2>/dev/null && {
          ROSTER_REMOVED=$((ROSTER_REMOVED + 1))
          ROSTER_REMOVED_NAMES="${ROSTER_REMOVED_NAMES} ${N}:terminated"
        }
      elif [ "$ALIVE0" -gt 0 ]; then
        ROSTER_KEPT_NAMES="${ROSTER_KEPT_NAMES} ${N}:alive"
      else
        ROSTER_KEPT_NAMES="${ROSTER_KEPT_NAMES} ${N}:grace"
      fi
      continue
    fi
    # ★둘 다 매칭★ — 이름 충돌 오판정 차단
    #   ★열 폭 무관★ ps -eww — COLUMNS=80 이면 80열 잘림으로 살아 있는 팀원을 죽은 것으로 오판정했다.
    #   ★전체 토큰 일치★ 줄 끝에 공백을 붙여 " --parent-session-id <uuid> " 경계까지 고정 문자열로 맞춘다.
    ALIVE=$(ps -eww -o args= 2>/dev/null \
      | sed 's/$/ /' \
      | grep -F -- " --agent-id ${N}@" \
      | grep -F -- " --parent-session-id ${MY_UUID} " \
      | grep -v "grep " \
      | wc -l)
    if [ "$ALIVE" -eq 0 ]; then
      rm -f "$F" 2>/dev/null && {
        ROSTER_REMOVED=$((ROSTER_REMOVED + 1))
        ROSTER_REMOVED_NAMES="${ROSTER_REMOVED_NAMES} ${N}"
      }
    else
      ROSTER_KEPT_NAMES="${ROSTER_KEPT_NAMES} ${N}:alive"
    fi
  done
done
_log "ROSTER_STRICT removed=[${ROSTER_REMOVED_NAMES# }] kept=[${ROSTER_KEPT_NAMES# }] grace=${GRACE_SEC}"

# (2) 기존 헬퍼 재사용 — inboxes 등 나머지 잔존물
#   ★bash_exec 는 dash 다★ — 헬퍼는 bash 배열/[[ ]] 을 쓰므로 bash -c 로 감싼다 (CLAUDE.md).
HELPER="${CFG_DIR}/hooks/lib/agent_roster_cleanup.sh"
[ -f "$HELPER" ] || HELPER="${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/agent_roster_cleanup.sh"
if [ -f "$HELPER" ]; then
  MY_TEAM=""
  [ -f "${SESSION_DIR}/team_name" ] && MY_TEAM=$(head -1 "${SESSION_DIR}/team_name" 2>/dev/null)
  HELPER_OUT=$(timeout 10 bash -c \
    'source "$1"; cleanup_agent_roster "$2" "$3"' _ "$HELPER" "$MY_UUID" "$MY_TEAM" 2>/dev/null)
  _log "HELPER_REUSED removed=${HELPER_OUT:-0} team=${MY_TEAM:-<none>}"
else
  _log "HELPER_MISSING path=${HELPER}"
fi

_log "SWEEP_DONE state=${CUR_STATE} killed=${KILLED} roster_removed=${ROSTER_REMOVED}"

exit 0
