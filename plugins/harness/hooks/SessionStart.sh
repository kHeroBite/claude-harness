#!/bin/bash
# SessionStart.sh — 신규 세션(Claude 실행 / /clear) 시 최초 1회 실행
# stdout → system-reminder로 모델에게 전달
# 역할: CLAUDE.md 재로드 안내 + 1회성 정리 작업 (세션당 1회면 충분한 로직)

trap 'exit 0' ERR

# ── 팀에이전트 세션 즉시 종료 (L-350/L-356: INPUT 읽기 전에 선제 차단) ──
# SessionStart.sh는 메인 에이전트 전용. 팀에이전트에서는 실행 불필요.
# 방법 1: PIPELINE_UUID 환경변수 (설정된 경우)
if [[ -n "${PIPELINE_UUID:-}" ]]; then
  exit 0
fi
# 방법 2: 조상 프로세스 전체(루트까지) cmdline에 --agent-id 확인
# 팀에이전트 claude는 --agent-id 인수로 실행됨, 메인 에이전트에는 없음
_WALK=$$
while true; do
  _WALK=$(ps -o ppid= -p "$_WALK" 2>/dev/null | tr -d ' ')
  [[ -z "$_WALK" || "$_WALK" -le 1 ]] && break
  if cat /proc/"$_WALK"/cmdline 2>/dev/null | tr '\0' ' ' | grep -q -- '--agent-id'; then
    exit 0
  fi
done

INPUT=$(timeout 5 cat 2>/dev/null) || INPUT=""

# ── 현재 작업 디렉터리 감지 (INPUT JSON의 cwd 필드 우선) ──
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || echo "")
[[ -z "$CWD" ]] && CWD=$(pwd 2>/dev/null || echo "")

# 머신 간 peer 통지 주기 pull 트리거 (비차단·백그라운드, 실패해도 무시)
bash "$(dirname "${BASH_SOURCE[0]}")/lib/peer_autopull.sh" "${CWD:--}" >/dev/null 2>&1 </dev/null || true

# git 루트 우선
GIT_ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || echo "")
PROJECT_PATH="${GIT_ROOT:-$CWD}"

SESSION_ENV="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env"

# 사이클46 축① — 반대편 base 미러 (읽는 쪽이 다른 base 를 볼 수 있다)
# state/status 는 state_machine.sh / session_id.sh 헬퍼가 자체 미러한다(S3/S4).
# 여기서는 이 파일이 직접 쓰거나 지우는 파일만 다룬다.
# ★_mirror_file 만 쓴다 — _mirror_file_strict 는 미러 실패가 원 쓰기를 실패시키므로 hook 금지★
# 라이브러리 부재 시에도 hook 이 그대로 동작하도록 no-op 폴백을 정의한다.
source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/session_mirror.sh" 2>/dev/null
declare -F _mirror_file >/dev/null 2>&1 || _mirror_file() { :; }
declare -F _mirror_delete >/dev/null 2>&1 || _mirror_delete() { :; }

# 현재 세션 UUID 추출 (INPUT JSON에서, 없으면 빈 문자열)
CURRENT_UUID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")

# ── [F안 강화판] settings.json drift 감지 (L-2026-05-02) ──
# 목적: settings.json hooks 정의 변경 후 활성 세션이 옛 캐시를 들고 있는 경우 사전 경고
# 배경: 2026-04-11~05-02 22일간 6개 프로젝트 1,122회 silent fail (매크로→절대경로 전환 후 옛 세션 캐시 잔류)
# 동작: 새 세션 시작 시 settings.json mtime이 자기 세션 시작보다 미래면 stdout 경고 → system-reminder로 모델에게 전달
_check_settings_drift() {
  local settings_file="${HARNESS_HOME:-$HOME/.harness}/current/.claude/settings.json"
  [[ -z "$CURRENT_UUID" ]] && return 0
  [[ ! -f "$settings_file" ]] && return 0

  local stamp_dir="${SESSION_ENV}/${CURRENT_UUID}"
  local stamp_file="${stamp_dir}/settings_drift_checked"
  [[ -f "$stamp_file" ]] && return 0  # 멱등성: 세션당 1회만

  local settings_mtime now_ts
  settings_mtime=$(stat -c %Y "$settings_file" 2>/dev/null || echo 0)
  now_ts=$(date +%s)
  local age=$((now_ts - settings_mtime))

  # settings.json이 1시간 이내에 수정됨 → drift 가능성 경고
  if (( age >= 0 && age < 3600 )); then
    echo "⚠️  [settings.json drift 감지] settings.json이 ${age}초 전에 수정됨"
    echo "    활성 세션이 옛 hook 캐시를 들고 있을 수 있음 → 다음 작업 전에 활성 세션 재시작 권장"
    echo "    (L-2026-05-02 매크로→절대경로 전환 22일 1,122회 silent fail 재발방지)"
  fi
  mkdir -p "$stamp_dir" 2>/dev/null
  touch "$stamp_file" 2>/dev/null
  _mirror_file "$stamp_file"
}
_check_settings_drift

# ── 자기 CCD settings.json hooks 자동 동기화 (사이클219) ──
# 목적: 실행 중 세션 사본이 정본 hooks 와 갈라지는 것을 시작 때 바로잡는다. 자기 CCD(/tmp/cc-*)의 hooks 키만 교체, 실패해도 세션 시작을 막지 않음.
source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/settings_session_sync.sh" 2>/dev/null && settings_session_sync "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/settings_hooks_sync.py" 2>/dev/null || true

# ── hooks 정합 점검 (정본 vs CCD vs HOME settings.json) ──
# 목적: 세션별 CCD settings.json 이 정본 hooks 와 갈라진 상태를 조기 경고
# 동작: hooks command 집합을 비교해 불일치 시 stdout 경고. 세션당 1회, 실패 무시, 세션 시작 차단 금지
_check_hooks_parity() {
  [[ -z "$CURRENT_UUID" ]] && return 0
  local stamp_dir="${SESSION_ENV}/${CURRENT_UUID}"
  local stamp_file="${stamp_dir}/hooks_parity_checked"
  [[ -f "$stamp_file" ]] && return 0
  mkdir -p "$stamp_dir" 2>/dev/null
  touch "$stamp_file" 2>/dev/null
  _mirror_file "$stamp_file"

  local canon="${HOOKS_PARITY_CANON:-$HOME/.claude/settings.json}"
  local ccd="${HOOKS_PARITY_CCD:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json}"
  local home="${HOOKS_PARITY_HOME:-$HOME/.claude/settings.json}"
  [[ -f "$canon" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  local cmds_canon
  cmds_canon=$(jq -r '[.hooks // {} | .. | objects | select(.type=="command") | .command] | unique | .[]' "$canon" 2>/dev/null) || return 0
  [[ -z "$cmds_canon" ]] && return 0

  local out="" label f cmds missing
  for pair in "CCD:$ccd" "HOME:$home"; do
    label="${pair%%:*}"; f="${pair#*:}"
    [[ -f "$f" ]] || continue
    [[ "$(readlink -f "$f" 2>/dev/null)" == "$(readlink -f "$canon" 2>/dev/null)" ]] && continue
    cmds=$(jq -r '[.hooks // {} | .. | objects | select(.type=="command") | .command] | unique | .[]' "$f" 2>/dev/null) || continue
    missing=$(comm -23 <(printf '%s\n' "$cmds_canon" | sort -u) <(printf '%s\n' "$cmds" | sort -u) | head -5)
    if [[ -n "$missing" ]]; then
      out+="    - ${label}(${f}) 에 빠진 hook:"$'\n'
      while IFS= read -r m; do out+="        ${m}"$'\n'; done <<< "$missing"
    fi
  done
  if [[ -n "$out" ]]; then
    echo "⚠️ [hooks 정합 경고] 정본 hooks 와 불일치 (최대 5개 표시)"
    printf '%s' "$out"
    echo "    복구: python3 ${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/settings_hooks_sync.py \"$canon\" \"$ccd\""
  fi
  return 0
}
_check_hooks_parity 2>/dev/null || true

# ── 팀 디렉토리 부트스트랩 (2026-09-07) ──
# 목적: 신규 세션에서 teams/session-{UUID 앞8자}/config.json 을 선제 생성한다.
# 배경: v2.1.178+ 에서 TeamCreate/TeamDelete 도구가 제거된 뒤, 이 파일을 만드는 주체가
#       구조적으로 사라졌다. 런타임은 Agent() spawn 시 이 파일을 전제하므로, 부재하면
#       "Internal error: team file for ... not found" 로 팀에이전트 spawn 이 전량 차단된다.
#       (2026-09-07 실측: pre 13건 / post 0건 → config.json 수동 생성 직후 4/4 즉시 성공.)
#       agent_lifecycle.sh 의 TeamCreate 분기는 사문화, bind_check 는 spawn 성공 후 실행,
#       full_task_team_guard 의 self-heal 은 config.json 존재를 전제 → 어느 것도 대안이 아니다.
# 안전 원칙 (CLAUDE.md §세션 격리 불변식):
#   - 자기 UUID 로 파생한 팀명 경로에만 쓴다 (§(a) 쓰기 경계)
#   - 이미 있으면 절대 덮어쓰지 않는다 (멱등 — 진행 중인 팀 상태 보존)
#   - 실패해도 세션 시작을 막지 않는다 (fail-open)
_bootstrap_team_dir() {
  [[ -z "$CURRENT_UUID" ]] && return 0

  local _bt_team="session-${CURRENT_UUID:0:8}"
  local _bt_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams/${_bt_team}"
  local _bt_cfg="${_bt_dir}/config.json"

  # 멱등성: 이미 존재하면 손대지 않는다 (재개 세션의 members 목록 보존)
  [[ -f "$_bt_cfg" ]] && return 0

  mkdir -p "${_bt_dir}/inboxes" 2>/dev/null || return 0

  # 스키마는 런타임이 직접 쓴 config.json 실측값을 그대로 따른다 (2026-09-07 채집).
  # 런타임이 쓰지 않는 필드(description 등)를 넣지 않는다 — 이 파일은 런타임이 읽고
  # members 를 이어서 갱신하는 대상이므로, 임의 필드는 파싱 리스크만 만든다.
  local _bt_now="$(date +%s)000"
  cat > "$_bt_cfg" 2>/dev/null <<EOF || return 0
{
  "name": "${_bt_team}",
  "createdAt": ${_bt_now},
  "leadAgentId": "team-lead@${_bt_team}",
  "leadSessionId": "${CURRENT_UUID}",
  "members": [
    {
      "agentId": "team-lead@${_bt_team}",
      "name": "team-lead",
      "agentType": "team-lead",
      "joinedAt": ${_bt_now},
      "tmuxPaneId": "leader",
      "cwd": "${PROJECT_PATH}",
      "subscriptions": [],
      "backendType": "in-process"
    }
  ]
}
EOF

  # team_name 파일도 함께 세워 둔다 — write_guard.sh 등 다수 hook 이 이 파일의 존재를
  # 팀 보유의 증거로 읽는다. 양쪽 base 에 기록해 base 갈림을 방지한다.
  local _bt_b _bt_sd
  for _bt_b in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" "$HOME/.claude"; do
    _bt_sd="${_bt_b}/session-env/${CURRENT_UUID}"
    [[ -d "$_bt_sd" ]] || mkdir -p "$_bt_sd" 2>/dev/null || continue
    printf '%s\n' "$_bt_team" > "${_bt_sd}/team_name" 2>/dev/null || true
  done

  return 0
}
_bootstrap_team_dir

# ── hook 등록 드리프트 자동 동기화 (정본 AI → REGULAR 파생본) ──
# 신규 hook 을 한 프로젝트에만 등록해 정책이 갈리는 재발을 물리적으로 차단한다.
# 사전 차단은 구조적으로 불가능하므로(6곳 등록 = 6회 개별 쓰기) 사후 자동 집행으로 강제한다.
if [[ -f "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/hook_registry_sync.sh" ]]; then
  source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/hook_registry_sync.sh"
  hook_registry_sync
fi

# ── 미등록 hook 감지 (경고만, L-968) ──
# hooks/*.sh 중 이벤트명 접두 규약을 따르는 파일이 실제 등록 settings.json 본문에 없으면 경고.
# 대조 원본: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json ∪ $HOME/.claude/settings.json (hooks 키 보유 파일만).
# 프로젝트 settings.json 은 273af59 로 hooks 키가 없어 대조 원본에서 뺐다(59건 오탐 원인).
# 매칭은 "/<basename>" — time_budget.sh 래퍼 인자·하위 디렉터리 경로 모두 절대경로라 인식된다.
{
  _hooks_dir="${HARNESS_HOME:-$HOME/.harness}/current/hooks"
  _canon_list=()
  for _cs in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" "$HOME/.claude/settings.json"; do
    [[ -f "$_cs" ]] || continue
    grep -q '"hooks"' "$_cs" 2>/dev/null || continue
    _cs_real=$(readlink -f "$_cs" 2>/dev/null || echo "$_cs")
    case " ${_canon_list[*]} " in *" $_cs_real "*) continue ;; esac
    _canon_list+=("$_cs_real")
  done
  _unreg_list=""
  _unreg_count=0
  # 묘비(settings_hooks_retired.json)에 오른 script 는 의도적 제거이므로 미등록 경고에서 뺀다
  _retired_names=" "
  _retired_file="${_hooks_dir%/hooks}/settings_hooks_retired.json"
  if [[ -f "$_retired_file" ]]; then
    _retired_names=" $(grep -o '"script"[[:space:]]*:[[:space:]]*"[^"]*"' "$_retired_file" | sed -E 's/.*"([^"]*)"$/\1/' | tr '\n' ' ')"
  fi
  if [[ ${#_canon_list[@]} -eq 0 ]]; then
    echo "ℹ️ [미등록 hook 감지] 대조 원본 없음 — hooks 키가 있는 settings.json 을 찾지 못해 검사를 건너뜁니다 (L-968)"
  else
    for _hf in "$_hooks_dir"/PreToolUse_*.sh "$_hooks_dir"/PostToolUse_*.sh "$_hooks_dir"/Stop*.sh "$_hooks_dir"/SessionStart*.sh "$_hooks_dir"/UserPromptSubmit*.sh "$_hooks_dir"/PreCompact*.sh "$_hooks_dir"/Notification*.sh "$_hooks_dir"/SubagentStop*.sh; do
      [[ -f "$_hf" ]] || continue
      _hn=$(basename "$_hf")
      case "$_retired_names" in *" ${_hn} "*) continue ;; esac
      if ! grep -qF "/${_hn}" "${_canon_list[@]}" 2>/dev/null; then
        _unreg_list="${_unreg_list}${_hn}, "
        _unreg_count=$((_unreg_count + 1))
      fi
    done 2>/dev/null || true
  fi
  if [[ $_unreg_count -gt 0 ]]; then
    echo "⚠️ [미등록 hook 감지] ${_unreg_count}건: 파일명 ${_unreg_list%, } — settings.json 등록 여부를 확인하세요 (L-968)"
  fi
} 2>/dev/null || true

# ── 등록 hook 실행 비트 검사 (디스크 x 비트·git index 100755, 안전 조건 충족 시 자동 chmod) ──
# 방향: 미등록 감지의 반대(등록됐는데 실행 불가). 검사기 부재·오류는 조용히 통과(fail-open). 출력은 stdout 으로 전달.
{
  _hec_py="${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/hook_exec_check.py"
  if [[ -f "$_hec_py" ]]; then
    timeout 5 python3 "$_hec_py" --mode session --fix 2>/dev/null
  fi
} || true

# ── 1회성 정리 (백그라운드) ──
(
  # --- oio/fio 고아 프로세스 정리 (원인 1/2 대응) ---
  # fio-mcp-server: 더 이상 사용하지 않음 → 무조건 SIGTERM
  pkill -TERM -f 'fio-mcp-server/server.py' 2>/dev/null
  # 소문자 /mnt/c/DATA/Project/ai/ 경로 oio 즉시 SIGKILL (원인 1)
  pkill -KILL -f '/mnt/c/DATA/Project/ai/MCP-Servers/' 2>/dev/null
  # oio orphan 정리 (ppid 조건 검사)
  for _pid in $(pgrep -f 'oio-mcp-server/server.py' 2>/dev/null); do
    _ppid=$(awk '/^PPid:/ {print $2}' /proc/$_pid/status 2>/dev/null)
    [[ -z "$_ppid" ]] && continue
    # 조건 1: ppid=1 (이미 orphan)
    if [[ "$_ppid" == "1" ]]; then
      kill -TERM "$_pid" 2>/dev/null
      continue
    fi
    # 조건 2: 부모 사망
    if ! kill -0 "$_ppid" 2>/dev/null; then
      kill -TERM "$_pid" 2>/dev/null
      continue
    fi
    # 조건 3: 부모가 zombie 상태
    _parent_state=$(awk '/^State:/ {print $2}' /proc/$_ppid/status 2>/dev/null)
    if [[ "$_parent_state" == "Z" ]]; then
      kill -TERM "$_pid" 2>/dev/null
      continue
    fi
    # 조건 4: 부모 cmdline에 claude 없음
    if ! cat /proc/$_ppid/cmdline 2>/dev/null | tr '\0' ' ' | grep -q 'claude'; then
      kill -TERM "$_pid" 2>/dev/null
    fi
  done

  # --- 재부팅 stale 감지: 부팅 이전 state 파일 → 강제 IDLE 리셋 ---
  # state_write()를 서브쉘 안에서도 사용하기 위해 session_id.sh source
  # shellcheck source=/dev/null
  source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/session_id.sh" 2>/dev/null || true
  # --- [P1-isolation] boot-stale — 자기 세션만 대상 (2026-04-22) ---
  # 이전 동작: session-env/*/ 전체 순회하며 재부팅 이전 state 파일 모두 IDLE 리셋.
  # 문제: 타 세션의 session-env에 쓰기(state_write/rm)가 발생 → 격리 위반.
  # 새 모델: 현재 UUID(CURRENT_UUID)에 해당하는 state 파일이 부팅 이전이면 자기만 리셋.
  #        다른 세션은 각자의 SessionStart.sh가 자기 스스로 복구.
  # [10D] 삭제 직전 보존 사본 라이브러리(rp_save) — 부재·오류 시 no-op 로 대체해 기동을 막지 않는다.
  source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/resume_preserve.sh" 2>/dev/null || true
  declare -F rp_save >/dev/null 2>&1 || rp_save() { :; }
  # [10D] SS_TEST_BOOT_TIME — 재기동 모사 시험 주입용(평시 미설정)
  BOOT_TIME=${SS_TEST_BOOT_TIME:-$(stat -c %Y /proc/1 2>/dev/null || echo 0)}
  # --- [c193 oi-fix-2 2026-10-19] boot-stale 오발동 차단 ---
  # 사고: 2026-10-19 17:59:54 compact 직후 이 블록이 재부팅 없이(boot_id 동일 063c0dee…) 발동해
  #       살아 있던 자기 팀원 obuild·otest-5b 를 SIGTERM(143)으로 죽이고 state TEST→IDLE, 메타 삭제까지 했다.
  # 원인: 판정식 "state mtime < BOOT_TIME" 은 "재부팅 뒤 state 가 한 번도 안 바뀌었다" 일 뿐 "세션이 재부팅 전 것" 이 아니다.
  #       TEST 단계가 길어 state 가 10-18 09:36:59 이후 그대로였고, 10-18 17:21:36 재부팅 뒤 --continue 로 이어진 세션이 걸렸다.
  # 대책: 아래 셋 중 하나라도 참이면 "이번 부팅에 살아 있는 세션" 으로 보고 boot-stale 전체(회수·IDLE·메타 삭제)를 건너뛴다.
  #   ① 자기 세션 팀원 프로세스가 살아 있다 — 프로세스는 재부팅을 넘지 못하므로 결정적 증거
  #   ② agent_state/_main.json 의 boot_id == 현재 boot_id — 이 세션이 이번 부팅에서 이미 스냅샷을 남겼다
  #   ③ heartbeat(사용자 입력 시 갱신) mtime ≥ BOOT_TIME — 이번 부팅에 사용자 입력이 있었다
  #   시험 주입: SS_TEST_BOOT_ID(현재 boot_id 대체), SS_TEST_ALIVE_AGENTS(①의 개수 대체)
  _bs_alive_session() {
    local _sd="$SESSION_ENV/$CURRENT_UUID" _n _cur _snap _hb
    if [[ -n "${SS_TEST_ALIVE_AGENTS:-}" ]]; then
      _n="$SS_TEST_ALIVE_AGENTS"
    elif source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/orphan_scan.sh" 2>/dev/null; then
      _n=$(orphan_scan_count "$CURRENT_UUID" 2>/dev/null)
    fi
    [[ "$_n" =~ ^[0-9]+$ && "$_n" -gt 0 ]] && { echo "alive_agents=$_n"; return 0; }
    _cur=${SS_TEST_BOOT_ID:-$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)}
    _snap=$(sed -n 's/.*"boot_id": *"\([^"]*\)".*/\1/p' "$_sd/agent_state/_main.json" 2>/dev/null | head -n 1)
    [[ -n "$_cur" && "$_snap" == "$_cur" ]] && { echo "same_boot_id=$_cur"; return 0; }
    if [[ -f "$_sd/heartbeat" ]]; then
      _hb=$(stat -c %Y "$_sd/heartbeat" 2>/dev/null || echo 0)
      [[ "$_hb" -ge "$BOOT_TIME" ]] && { echo "heartbeat_since_boot=$_hb"; return 0; }
    fi
    return 1
  }
  if [[ -n "$CURRENT_UUID" ]]; then
    _MY_STATE_FILE="$SESSION_ENV/$CURRENT_UUID/state"
    _BS_SKIP_WHY=""
    if [[ -f "$_MY_STATE_FILE" ]]; then
      _MY_STATE_MTIME=$(stat -c %Y "$_MY_STATE_FILE" 2>/dev/null || echo 0)
      if [[ "$_MY_STATE_MTIME" -lt "$BOOT_TIME" ]] && _BS_SKIP_WHY=$(_bs_alive_session); then
        mkdir -p "$SESSION_ENV/$CURRENT_UUID/logs" 2>/dev/null
        echo "[$(date -Iseconds 2>/dev/null)] boot-stale SKIP state_mtime=${_MY_STATE_MTIME} boot_time=${BOOT_TIME} why=${_BS_SKIP_WHY}" \
          >> "$SESSION_ENV/$CURRENT_UUID/logs/orphan_reap.log" 2>/dev/null
      fi
      if [[ "$_MY_STATE_MTIME" -lt "$BOOT_TIME" && -z "$_BS_SKIP_WHY" ]]; then
        # --- H-2: rm 직전 프로세스 회수 (2026-08-17) ---
        # 배경: 이 블록은 메타파일만 지우고 프로세스는 전혀 종료시키지 않았다.
        #       그 결과 재부팅 후 "추적 근거는 소멸했는데 프로세스는 생존"하는 상태가 성립해
        #       고아 팀에이전트 5개가 미탐지로 잔존했다(결함 A).
        #       증적: Mars/.claude/evidence/agent_orphan_cleanup_20260817.md
        # 위치 근거: 반드시 아래 rm -f 보다 앞. 메타파일이 지워지기 전에 회수해야 한다.
        # 안전: orphan_scan_reap 은 ① --agent-id 보유(메인 보호 L-213) ② 자기 UUID 소속만
        #       ③ 자기 자신/조상 제외 를 모두 적용한 목록만 종료시킨다. 타 세션 무접촉(격리 §a).
        # 정책: 라이브러리 부재/오류 시 조용히 건너뛴다(fail-open). 세션 기동을 절대 막지 않는다.
        # 긴급 정지: lib/orphan_scan.sh 삭제 시 이 블록도 함께 무력화된다(의도된 탈출구).
        _H2_LIB="${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/orphan_scan.sh"
        if [[ -r "$_H2_LIB" ]]; then
          # shellcheck source=/dev/null
          if source "$_H2_LIB" 2>/dev/null; then
            _H2_N=$(orphan_scan_reap "$CURRENT_UUID" 2>/dev/null)
            if [[ "$_H2_N" =~ ^[0-9]+$ && "$_H2_N" -gt 0 ]]; then
              mkdir -p "$SESSION_ENV/$CURRENT_UUID/logs" 2>/dev/null
              echo "[$(date -Iseconds 2>/dev/null)] H-2 boot-stale 고아 회수: ${_H2_N}건" \
                >> "$SESSION_ENV/$CURRENT_UUID/logs/orphan_reap.log" 2>/dev/null
              _mirror_file "$SESSION_ENV/$CURRENT_UUID/logs/orphan_reap.log"
            fi
          fi
        fi
        # --- H-2 끝 ---
        # [10D] IDLE 기록·메타 삭제 직전 보존 사본 — oresume 이 재기동 뒤 복원한다(삭제 자체는 유지)
        rp_save "$SESSION_ENV/$CURRENT_UUID" boot
        state_write "$_MY_STATE_FILE" "IDLE stale_${CURRENT_UUID}"
        # 자기 세션 메타 파일 정리 — in-process 캐시 잔존 예방 (2026-05-11 사이드이펙트 0 강화)
        # 격리 §(a) 준수: 자기 UUID 하위만 정리. 타 세션 무영향.
        rm -f "$SESSION_ENV/$CURRENT_UUID/team_name" \
              "$SESSION_ENV/$CURRENT_UUID/classification" \
              "$SESSION_ENV/$CURRENT_UUID/rollback_hash" \
              "$SESSION_ENV/$CURRENT_UUID/entry_tier" \
              "$SESSION_ENV/$CURRENT_UUID/status" \
              "$SESSION_ENV/$CURRENT_UUID/pipeline_uuid" \
              "$SESSION_ENV/$CURRENT_UUID/route_decision" \
              "$SESSION_ENV/$CURRENT_UUID/oroof_active.json" \
              "$SESSION_ENV/$CURRENT_UUID/oroof_active" \
              "$SESSION_ENV/$CURRENT_UUID/auto" \
              "$SESSION_ENV/$CURRENT_UUID/goal.json" 2>/dev/null
        rm -f "$SESSION_ENV/$CURRENT_UUID/oralph_active.json" "$SESSION_ENV/$CURRENT_UUID/oralph_active" 2>/dev/null  # ROOF-COMPAT(deprecation window 1주기 — 구 oralph_active 삭제 호환)
        # 사이클46 삭제 미러 — 반대편 base 에 잔존하면 statusline/게이트가 옛 값을 읽는다
        for _bs_f in team_name classification rollback_hash entry_tier \
                     status pipeline_uuid route_decision oroof_active.json \
                     oroof_active oralph_active.json \
                     oralph_active auto goal.json; do  # ROOF-COMPAT(deprecation window 1주기 — 구 RALPH/oralph_active 인식 제거 예정)
          _mirror_delete "$SESSION_ENV/$CURRENT_UUID/$_bs_f"
        done
      fi
    fi
  fi
  # --- [P1-isolation] boot-stale end ---

  # --- [Phase B 자동 마이그레이션] state=OK 잔재 → PLAN+classification=OK (L-431) ---
  # 목적: stage 9→8 (OK 제거) 전환 시 다른 활성 세션이 state=OK로 잔존해도 새 ok 진입 가능.
  # 동작: 자기 세션의 state 파일이 OK이면 PLAN으로 변환 + classification=OK 기록 + 로그.
  # 회귀 보호: deprecation window 1주기. state=OK가 자연 소멸하면 본 블록은 dead code화.
  # 격리 준수: §(a) 자기 UUID에만 쓰기 (state_write/echo redirect 모두 자기 세션).
  if [[ -n "$CURRENT_UUID" ]]; then
    _MIG_STATE_FILE="$SESSION_ENV/$CURRENT_UUID/state"
    if [[ -f "$_MIG_STATE_FILE" ]]; then
      _MIG_STATE=$(state_read "$_MIG_STATE_FILE" 2>/dev/null | awk '{print $1}' | tr -d '\r')
      if [[ "$_MIG_STATE" == "OK" ]]; then
        _MIG_DIR="$SESSION_ENV/$CURRENT_UUID"
        _MIG_TS=$(date -Iseconds 2>/dev/null)
        mkdir -p "$_MIG_DIR/logs" 2>/dev/null
        # state=OK → PLAN 변환 (state_write는 토큰 4개: STATE UUID TIMESTAMP REASON)
        state_write "$_MIG_STATE_FILE" "PLAN ${CURRENT_UUID} ${_MIG_TS} migration_ok_to_plan"
        # classification 파일에 OK 기록 (이미 OK이면 무해)
        echo "OK" > "$_MIG_DIR/classification" 2>/dev/null
        _mirror_file "$_MIG_DIR/classification"
        # 마이그레이션 로깅 (자기 세션 logs/ — 격리 준수)
        echo "[${_MIG_TS}] migration_ok_to_plan uuid=${CURRENT_UUID} prev_state=OK -> new_state=PLAN classification=OK" \
          >> "$_MIG_DIR/logs/migration_ok_to_plan.log" 2>/dev/null
        _mirror_file "$_MIG_DIR/logs/migration_ok_to_plan.log"
      fi
    fi
  fi
  # --- [Phase B 자동 마이그레이션] end ---

  # --- [P1-isolation v2] heartbeat-stale — 다층 방어 (2026-05-01 L-430) ---
  # 변경점:
  #   1. THRESHOLD 상태별 차등: PLAN/DEV/TEST=1800(30분), DONE/FINISH=600(10분), OK 세분화
  #      근거: heartbeat는 "사용자 입력 mtime"이므로 odev/oplan_debate 집중 시 5분 초과 일상적
  #   2. heartbeat 파일 없으면 stale 판정 스킵 (보수적 — state mtime 폴백 제거)
  #   3. agents/ 파일(1시간 이내) 존재 시 stale 판정 스킵 (1차 방어)
  #   4. tmux pane 중 자기 UUID 소속 --agent-id 살아있으면 스킵 (2차 방어)
  _HB_NOW=$(date +%s)
  if [[ -n "$CURRENT_UUID" ]]; then
    _MY_HB_STATE_FILE="$SESSION_ENV/$CURRENT_UUID/state"
    if [[ -f "$_MY_HB_STATE_FILE" ]]; then
      _HB_STATE=$(state_read "$_MY_HB_STATE_FILE" 2>/dev/null | awk '{print $1}' | tr -d '\r')
      case "$_HB_STATE" in
        PLAN|DEV|TEST|DONE|FINISH)
          _HB_DIR="$SESSION_ENV/$CURRENT_UUID"
          # (1) 상태별 차등 임계값 (Phase B: OK 분기 제거 — 자동 마이그레이션이 OK→PLAN 변환. L-431)
          case "$_HB_STATE" in
            PLAN)
              # PLAN+classification=OK (구 OK stage 의미 보존): 에이전트 부재 시 빠른 회수
              _hb_classification=$(cat "$_HB_DIR/classification" 2>/dev/null | tr -d '\r' | head -1)
              if [[ "$_hb_classification" == "OK" ]]; then
                _hb_ok_agents=$(find "$_HB_DIR/agents/" -maxdepth 1 -type f \
                                 ! -name "*.failed" 2>/dev/null | wc -l)
                if [[ "$_hb_ok_agents" -eq 0 ]]; then
                  _HB_THRESHOLD=30   # PLAN+OK + 에이전트 없음: 빠른 회수 (구 OK 분기 의미 보존)
                else
                  _HB_THRESHOLD=1800 # PLAN+OK + 에이전트 있음: 보호
                fi
              else
                _HB_THRESHOLD=1800   # 일반 PLAN(분류 완료): 빌드/토론/심층분석 보호
              fi
              ;;
            DEV|TEST) _HB_THRESHOLD=1800 ;;  # 30분 — 빌드/토론/심층분석
            DONE|FINISH)   _HB_THRESHOLD=600 ;;   # 10분 — 마무리 단계
          esac
          # (2) heartbeat 파일 없으면 stale 판정 스킵 (state mtime 폴백 제거)
          if [ ! -f "$_HB_DIR/heartbeat" ]; then
            : # heartbeat 미존재 → 보수적 스킵
          else
            _HB_MTIME=$(stat -c %Y "$_HB_DIR/heartbeat" 2>/dev/null || echo 0)
            _HB_AGE=$(( _HB_NOW - _HB_MTIME ))
            if [ "$_HB_AGE" -gt "$_HB_THRESHOLD" ]; then
              # (3) 1차 방어: agents/ 등록 파일(1시간 이내) 있으면 stale 판정 스킵
              _hb_live_agent=0
              for _af in "$_HB_DIR/agents/"*; do
                [[ -f "$_af" ]] || continue
                [[ "$_af" == *.failed ]] && continue
                _af_age=$(( _HB_NOW - $(stat -c %Y "$_af" 2>/dev/null || echo 0) ))
                [[ "$_af_age" -lt 3600 ]] && _hb_live_agent=1 && break
              done
              if [[ "$_hb_live_agent" -eq 1 ]]; then
                echo "[SessionStart L-430] heartbeat-stale SKIPPED: agents/ 활성 state=${_HB_STATE} age=${_HB_AGE}s" \
                  >> /tmp/session_hb_stale.log 2>/dev/null
              else
                # (4) 2차 방어: tmux pane 중 자기 UUID 소속 --agent-id 살아있으면 스킵
                _hb_alive_pane=0
                if command -v tmux >/dev/null 2>&1; then
                  while IFS= read -r _pp; do
                    [[ -z "$_pp" ]] && continue
                    for _cp in $(pgrep -P "$_pp" 2>/dev/null) "$_pp"; do
                      _cmd=$(cat /proc/"$_cp"/cmdline 2>/dev/null | tr '\0' ' ' || echo "")
                      if [[ "$_cmd" == *"--agent-id"* && "$_cmd" == *"$CURRENT_UUID"* ]]; then
                        _hb_alive_pane=1; break 2
                      fi
                    done
                  done < <(tmux list-panes -a -F '#{pane_pid}' 2>/dev/null)
                fi
                if [[ "$_hb_alive_pane" -eq 1 ]]; then
                  echo "[SessionStart L-430] heartbeat-stale SKIPPED: tmux pane alive state=${_HB_STATE} age=${_HB_AGE}s" \
                    >> /tmp/session_hb_stale.log 2>/dev/null
                else
                  # (5) 진짜 stale — 정리
                  echo "[SessionStart L-430] heartbeat-stale CONFIRMED: state=${_HB_STATE} age=${_HB_AGE}s threshold=${_HB_THRESHOLD}s agents=0 panes=0" \
                    >> /tmp/session_hb_stale.log 2>/dev/null
                  # [10D] 삭제 직전 보존 사본
                  rp_save "$_HB_DIR" hb
                  rm -f "$_HB_DIR/team_name" "$_HB_DIR/classification" "$_HB_DIR/rollback_hash" 2>/dev/null
                  _mirror_delete "$_HB_DIR/team_name"
                  _mirror_delete "$_HB_DIR/classification"
                  _mirror_delete "$_HB_DIR/rollback_hash"
                  state_write "$_MY_HB_STATE_FILE" "IDLE stale_hb_${CURRENT_UUID}"
                fi
              fi
            fi
          fi
          ;;
      esac
    fi
  fi
  # --- [P1-isolation v2] heartbeat-stale end ---

  # --- 고아 orphan_poller 정리 ---
  _cleanup_orphan_pollers() {
    local _pid_file _pid _cmdline _uuid _state
    for _pid_file in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env"/*/orphan_poller.pid; do
      [[ -f "$_pid_file" ]] || continue
      # [P2-isolation §(a)] UUID 체크 최상단 — 타 세션 pid_file rm 원천 차단
      _uuid=$(basename "$(dirname "$_pid_file")")
      [[ "$_uuid" != "$CURRENT_UUID" ]] && continue
      _pid=$(cat "$_pid_file" 2>/dev/null | tr -d '[:space:]') || continue
      [[ -z "$_pid" ]] && continue
      _cmdline=$(cat "/proc/$_pid/cmdline" 2>/dev/null | tr '\0' ' ' || echo "")
      if [[ "$_cmdline" != *"bash_orphan_poller"* ]]; then
        rm -f "$_pid_file"
        continue
      fi
      _state=$(state_read "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/$_uuid/state" 2>/dev/null | awk '{print $1}' || echo "IDLE")  # F-NEW-3
      if [[ "$_state" != "IDLE" ]]; then
        continue
      fi
      kill "$_pid" 2>/dev/null || true
      rm -f "$_pid_file"
    done
  }
  _cleanup_orphan_pollers

  # --- pane_kill_debug.log 회전 (1MB 초과 시 .old로 이동) ---
  if [ -f /tmp/pane_kill_debug.log ]; then
    _log_size=$(stat -c %s /tmp/pane_kill_debug.log 2>/dev/null || echo 0)
    if [ "$_log_size" -gt 1048576 ]; then
      mv /tmp/pane_kill_debug.log /tmp/pane_kill_debug.log.old 2>/dev/null
    fi
  fi

  # --- 타 세션 디렉토리 정리 루프 제거 (Fix 26 §(a)(d)) ---
  # 세션 격리 불변식 §(a)(d): 자기 UUID 외 session-env/*/ 삭제 금지
  # lazy orphan cleanup은 TeamCreate 시점에 team_create_guard.sh가 담당

  # --- [R3(a)] 자기 UUID stale 복원 (메인 직접 관측 케이스 차단) ---
  # 발동 조건 4가지 교집합 (fail-closed):
  #   1. self_state ∈ {PLAN, DEV, TEST, DONE, FINISH} (IDLE 외)
  #   2. heartbeat 파일 mtime > 1800초 (30분)
  #   3. agents/ 디렉토리 빈 상태 (활성 에이전트 없음)
  #   4. tmux pane 부재 (현재 UUID 관련 pane cmdline 없음)
  # 4조건 모두 충족 시: state → IDLE 강제 전이 + 관련 파일 정리
  _r3_self_stale_recovery() {
    [[ -z "$CURRENT_UUID" ]] && return 0
    local _r3_dir="$SESSION_ENV/$CURRENT_UUID"
    local _r3_state_file="$_r3_dir/state"
    [[ ! -f "$_r3_state_file" ]] && return 0

    local _r3_state
    _r3_state=$(state_read "$_r3_state_file" 2>/dev/null | awk '{print $1}' | tr -d '\r')
    # 조건 1: 활성 상태 (IDLE 외)
    case "$_r3_state" in
      PLAN|DEV|TEST|DONE|FINISH) ;;
      *) return 0 ;;
    esac

    # 조건 2: heartbeat mtime > 1800초
    local _r3_hb_file="$_r3_dir/heartbeat"
    [[ ! -f "$_r3_hb_file" ]] && return 0  # heartbeat 없으면 fail-closed (스킵)
    local _r3_now _r3_hb_mtime _r3_hb_age
    _r3_now=$(date +%s)
    _r3_hb_mtime=$(stat -c %Y "$_r3_hb_file" 2>/dev/null || echo "$_r3_now")
    _r3_hb_age=$(( _r3_now - _r3_hb_mtime ))
    [[ "$_r3_hb_age" -le 1800 ]] && return 0

    # 조건 3: agents/ 디렉토리 빈 상태 (활성 에이전트 없음)
    local _r3_agent_count=0
    for _r3_af in "$_r3_dir/agents/"*; do
      [[ -f "$_r3_af" ]] || continue
      [[ "$_r3_af" == *.failed ]] && continue
      _r3_agent_count=$(( _r3_agent_count + 1 ))
    done
    [[ "$_r3_agent_count" -gt 0 ]] && return 0

    # 조건 4: tmux pane 부재 (현재 UUID cmdline 없음)
    local _r3_pane_found=0
    if command -v tmux >/dev/null 2>&1; then
      while IFS= read -r _r3_pp; do
        [[ -z "$_r3_pp" ]] && continue
        for _r3_cp in $(pgrep -P "$_r3_pp" 2>/dev/null) "$_r3_pp"; do
          local _r3_cmd
          _r3_cmd=$(cat "/proc/$_r3_cp/cmdline" 2>/dev/null | tr '\0' ' ' || echo "")
          if [[ "$_r3_cmd" == *"$CURRENT_UUID"* ]]; then
            _r3_pane_found=1; break 2
          fi
        done
      done < <(tmux list-panes -a -F '#{pane_pid}' 2>/dev/null)
    fi
    [[ "$_r3_pane_found" -eq 1 ]] && return 0

    # 4조건 모두 충족 → state IDLE 강제 전이
    local _r3_old_state="$_r3_state"
    # [10D] IDLE 기록·메타 삭제 직전 보존 사본
    rp_save "$_r3_dir" r3
    state_write "$_r3_state_file" "IDLE r3_stale_${CURRENT_UUID}"
    rm -f "$_r3_dir/team_name" \
          "$_r3_dir/classification" \
          "$_r3_dir/entry_tier" \
          "$_r3_dir/status" 2>/dev/null
    _mirror_delete "$_r3_dir/team_name"
    _mirror_delete "$_r3_dir/classification"
    _mirror_delete "$_r3_dir/entry_tier"
    _mirror_delete "$_r3_dir/status"
    echo "ℹ️ [SessionStart R3] 자기 stale 복원 실행 — state=${_r3_old_state}/age=${_r3_hb_age}s/agents=0/pane=0 → IDLE"
  }
  _r3_self_stale_recovery

  # --- [R3(b)] 7일+ 빈 session-env/* 정리 (자기 cc-prefix 한정 — 격리 §(b) 준수) ---
  # 발동 조건 4가지 교집합 (fail-closed):
  #   1. state 파일 부재
  #   2. heartbeat 파일 부재
  #   3. 디렉토리 mtime > 604800초 (7일)
  #   4. 디렉토리 비어있음 (find -type f 결과 없음)
  # ⚠️ 자기 UUID는 절대 제외 (CURRENT_UUID == _r3b_uuid 시 continue)
  _r3_cleanup_empty_sessions() {
    [[ -z "$CURRENT_UUID" ]] && return 0
    local _r3b_se="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env"
    [[ ! -d "$_r3b_se" ]] && return 0
    local _r3b_now
    _r3b_now=$(date +%s)
    for _r3b_dir in "$_r3b_se"/*/; do
      [[ -d "$_r3b_dir" ]] || continue
      local _r3b_uuid
      _r3b_uuid=$(basename "$_r3b_dir")
      # 자기 UUID 절대 제외
      [[ "$_r3b_uuid" == "$CURRENT_UUID" ]] && continue
      # 조건 1: state 파일 부재
      [[ -f "$_r3b_dir/state" ]] && continue
      # 조건 2: heartbeat 파일 부재
      [[ -f "$_r3b_dir/heartbeat" ]] && continue
      # 조건 3: 디렉토리 mtime > 604800초 (7일)
      local _r3b_mtime _r3b_age
      _r3b_mtime=$(stat -c %Y "$_r3b_dir" 2>/dev/null || echo "$_r3b_now")
      _r3b_age=$(( _r3b_now - _r3b_mtime ))
      [[ "$_r3b_age" -le 604800 ]] && continue
      # 조건 4: 실제 파일 없음 (빈 디렉토리 또는 빈 하위 디렉토리만)
      local _r3b_file_count
      _r3b_file_count=$(find "$_r3b_dir" -type f 2>/dev/null | head -1 | wc -l)
      [[ "$_r3b_file_count" -gt 0 ]] && continue
      # 4조건 모두 충족 → rm -rf
      rm -rf "$_r3b_dir" 2>/dev/null
      echo "🗑️ [SessionStart R3b] 7일+ 빈 session-env 정리: uuid=${_r3b_uuid} age=${_r3b_age}s"
    done
  }
  _r3_cleanup_empty_sessions

) >> /tmp/session_init_cleanup.log 2>&1 &
disown

# ── WT 탭 타이틀 warmup (tmux cold-start 첫 호출 대응) ──
# tmux 안에서 첫 세션 시작 시 OSC 0+2 DCS passthrough로 초기 타이틀 강제 송출.
_wt_title_warmup() {
  [[ -z "${TMUX:-}" ]] && return 0
  [[ -z "${CURRENT_UUID:-}" ]] && return 0
  local _warmup_marker="${SESSION_ENV}/${CURRENT_UUID}/title_warmup_done"
  [[ -f "$_warmup_marker" ]] && return 0
  local _init_title="init 🧍 idle"
  printf '\x1bPtmux;\x1b\x1b]0;%s\x07\x1b\\' "$_init_title" 2>/dev/null || true
  printf '\x1bPtmux;\x1b\x1b]2;%s\x07\x1b\\' "$_init_title" 2>/dev/null || true
  mkdir -p "$(dirname "$_warmup_marker")" 2>/dev/null
  touch "$_warmup_marker" 2>/dev/null
  _mirror_file "$_warmup_marker"
}
_wt_title_warmup

# ── stdout 출력 (system-reminder) ──
echo "[신규 세션 초기화]"
echo "- 프로젝트 경로: ${PROJECT_PATH:-알 수 없음}"
echo "📌 [ointaug 필수] ⚠️ CLAUDE.md 규칙: Skill('ointaug')를 반드시 첫 번째 행동으로 호출하고 확장 질의를 화면에 출력한 후 답변하라. 미호출 시 위반."

# ── [10D] 재기동 복원 재주입 (2026-10-11, conv_179163042411) ──
# 목적: 재부팅·WSL 종료 뒤 claude --resume/startup 시, 재기동 전 진행 중이던 파이프라인의 요약을
#       최대 30줄로 모델에 다시 알리고 oresume 호출을 안내한다(사용자 확인 불요).
# 근거: 위 boot-stale 블록은 백그라운드라 이 시점에 보존(rp_save)이 끝났을 수도, 아직일 수도 있다.
#       rp_reinject 는 두 경우를 모두 다룬다(live=아직 정리 전 / saved=보존본 latest.json).
# 실패·부재 시 무출력(fail-open). compact 경로는 SessionStart_compact.sh 담당이라 다루지 않는다.
_ss_resume_reinject() {
  [[ -z "$CURRENT_UUID" ]] && return 0
  local _src
  _src=$(echo "$INPUT" | jq -r '.source // empty' 2>/dev/null)
  case "$_src" in
    startup|resume) ;;
    *) return 0 ;;
  esac
  local _lib="${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/resume_preserve.sh"
  [[ -r "$_lib" ]] || return 0
  # shellcheck source=/dev/null
  source "$_lib" 2>/dev/null || return 0
  declare -F rp_reinject >/dev/null 2>&1 || return 0
  local _bt="${SS_TEST_BOOT_TIME:-$(stat -c %Y /proc/1 2>/dev/null || echo 0)}"
  local _out
  _out=$(rp_reinject "$SESSION_ENV/$CURRENT_UUID" "$_bt" 2>/dev/null | head -n 29)
  [[ -n "$_out" ]] || return 0
  printf '%s\n' "$_out"
  echo "🔁 [재기동 복원 가능] Skill('ointaug') 직후 첫 행동으로 Skill('oresume') 를 호출하라. 사용자 확인은 필요 없다."
  return 0
}
_ss_resume_reinject 2>/dev/null || true
