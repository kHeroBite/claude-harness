#!/bin/bash
# 사용자 입력 이후 Skill('ointaug')·Skill('oi') 실제 호출 전에는 메인의 실행 도구를 막고, 호출 증표 위조를 막는 PreToolUse 가드
#
# 등록: PreToolUse matcher "*" (timeout 10). 메인 세션 전용. 팀에이전트·서브에이전트·타 세션은 즉시 exit 0.
#
# 배경 (2026-10-10 사이클174, 세션 eec8b498 실측):
#   11:20~11:50 사용자 입력 13건 중 Skill('ointaug') 실호출은 4건뿐이었다. 나머지는 메인이
#   mcp__oio__session_state(key="ointaug_done") 로 마커만 직접 쓰고 진행했다. 파이프라인 활성(DEV) 중
#   입력 9건 중 Skill('oi') 실호출은 4건, 나머지는 SendMessage/Agent 로 바로 위임했다.
#   어떤 hook 도 막지 못한 이유는 두 가지다.
#     (1) 기존 게이트(F-INTAUG-1, oi_route_guard)는 ★Skill 도구 호출 때만★ 발동한다.
#         SendMessage·Agent·bash_exec 만 쓰면 아무 게이트도 지나지 않는다.
#     (2) 게이트가 보는 마커(ointaug_done·oi_routed)는 ★메인이 직접 쓰는 파일★ 이었다(스킬 문서 절차).
#         "마커가 있다" 는 "Skill 을 호출했다" 의 증거가 아니었다(L-467 자기신고 판정축과 동형).
#
# 설계:
#   - 요구 표식: UserPromptSubmit.sh 가 ★실제 사용자 입력★ 일 때만 ointaug_required(항상)·oi_required(파이프라인 활성 시)
#     를 touch 한다. 팀원 메시지(<teammate-message>)·시스템 알림(<task-notification>)·/ox 는 요구하지 않는다.
#   - 호출 증표: PostToolUse_Skill_ointaug_format.sh 가 Skill('ointaug')/Skill('oi') 실행 직후 ointaug_invoked/oi_invoked 를 쓴다.
#     hook 프로세스가 쓰므로 메인 도구 호출 경로 밖이다.
#   - 판정: 증표 mtime(나노초) >= 요구 표식 mtime 이면 이번 입력에 대해 호출이 끝난 것이다.
#   - 위조 차단: 메인이 증표·요구 표식·oi_routed 를 쓰기/삭제하려 하면 항상 차단한다.
#
# 미충족 중에도 허용: 조회 계열, ToolSearch, ListAgents, AskUserQuestion, TodoWrite, TaskStop, date 단독,
#   Skill(ointaug) (oi 대기 중에는 Skill 전체 — 스킬 경로는 oi_route_guard 가 따로 판정), shutdown 프로토콜 SendMessage,
#   agent_keep 기록(teammate idle guard 요구 조치).
#
# 비상 해제 스위치 없음(2026-10-11 제거 — 사람만 만들 수 있어 자율 진행을 막았다).
#   게이트는 조회 계열과 Skill(ointaug) 를 항상 허용하므로 정상 탈출 경로가 늘 있다.

trap 'exit 0' ERR
# 팀에이전트 프로세스(PIPELINE_UUID 보유) — 메인 전용
[[ -n "${PIPELINE_UUID:-}" ]] && exit 0

INPUT=$(timeout 5 cat 2>/dev/null) || exit 0
[[ -z "$INPUT" ]] && exit 0

# in-process 서브에이전트는 hook 입력에 agent_id 가 실린다 — 메인 아님
_AID=$(printf '%s' "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null)
[[ -n "$_AID" ]] && exit 0
# tmux 팀원 프로세스(부모 체인 --agent-id) — 메인 아님
if source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/chain_agent.sh" 2>/dev/null && chain_agent_resolve 2>/dev/null; then
  exit 0
fi

SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null | tr -d '[:space:]')
[[ "$SID" =~ ^[0-9a-f-]{36}$ ]] || exit 0
SESSION_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${SID}"

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
[[ -z "$TOOL" ]] && exit 0
TI=$(printf '%s' "$INPUT" | jq -c '.tool_input // {}' 2>/dev/null)

_block() {
  printf '%s\n' "$1" >&2
  exit 2
}

# ─── 1. 위조 차단 (요구 충족 여부와 무관하게 항상) ───
FORGE_RX='ointaug_invoked|oi_invoked|ointaug_required|oi_required|ointaug_exempt|oi_routed|oteam_required|oteam_spawned|oteam_stop_count'
case "$TOOL" in
  mcp__oio__file_write|mcp__oio__file_edit|mcp__oio__file_copy|mcp__oio__file_move|mcp__oio__file_rename|mcp__oio__file_symlink|mcp__oio__file_delete|mcp__oio__session_state|mcp__oio__dir_delete|mcp__oio__dir_move|mcp__oio__dir_rename|Write|Edit|MultiEdit|NotebookEdit)
    # 쓰기 대상 경로 필드의 basename 이 증표, 표식일 때만 차단한다 (내용 문자열에 이름이 들어 있다는 이유로는 막지 않는다)
    _TGT=$(printf '%s' "$TI" | jq -r '[.path?, .file_path?, .notebook_path?, .destination?, .dest?, .source?, .target?, .new_path?, .old_path?, .new_name?, .key?] | map(select(type=="string") | split("/") | last) | .[]' 2>/dev/null)
    if printf '%s' "$_TGT" | grep -qE "$FORGE_RX"; then
      _block "⛔ [F-INTAUG-3] Skill 호출 증표/요구 표식 직접 조작 차단 — ${TOOL}
ointaug_invoked·oi_invoked 는 Skill('ointaug')/Skill('oi') 실행 직후 hook 이 직접 쓴다. ointaug_required·oi_required 는
UserPromptSubmit 이 쓴다. oi_routed 는 더 이상 판정에 쓰지 않는다. 메인이 이 파일을 쓰거나 지우면 '호출했다'를 위조하는 것이다.
조치: Skill('ointaug') → (파이프라인 활성 시) Skill('oi') 를 실제로 호출하라."
    fi
    ;;
  Bash|mcp__oio__bash_exec)
    _CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // .tool_input.cmd // empty' 2>/dev/null)
    if printf '%s' "$_CMD" | grep -qE "$FORGE_RX" && \
       printf '%s' "$_CMD" | grep -qE '>|\btouch\b|\btee\b|\bcp\b|\bmv\b|\bln\b|\brm\b|\bunlink\b|sed[[:space:]]+-i|\binstall\b|\btruncate\b|\bdd\b|python|perl|\bnode\b|\bruby\b|-delete|\bshred\b'; then
      _block "⛔ [F-INTAUG-3] 셸로 Skill 호출 증표/요구 표식을 조작하려는 명령 차단.
이 파일들은 hook 만 쓴다. 조회(stat·ls·cat)는 허용된다. 조치: Skill('ointaug')/Skill('oi') 를 실제로 호출하라."
    fi
    ;;
esac

# state 없는 UUID 는 메인 세션이 아니다(UserPromptSubmit 이 메인에만 만든다) — 위조 차단(1절)은 state 와 무관하게 먼저 적용한다
[[ -f "${SESSION_DIR}/state" ]] || exit 0

# ─── 2. 요구 충족 판정 ───
_mt() { local v; v=$(stat -c %.9Y "$1" 2>/dev/null) || return 1; v="${v/./}"; [[ "$v" =~ ^[0-9]+$ ]] || return 1; printf '%s' "$v"; }

REQ_I=$(_mt "${SESSION_DIR}/ointaug_required") || REQ_I=""
PRF_I=$(_mt "${SESSION_DIR}/ointaug_invoked") || PRF_I=0
REQ_O=$(_mt "${SESSION_DIR}/oi_required") || REQ_O=""
PRF_O=$(_mt "${SESSION_DIR}/oi_invoked") || PRF_O=0

PEND=""
if [[ -n "$REQ_I" ]] && (( PRF_I < REQ_I )); then
  PEND="ointaug"
elif [[ -n "$REQ_O" ]] && (( PRF_O < REQ_O )); then
  PEND="oi"
fi
if [[ -z "$PEND" ]]; then
  # [F-OTEAM] /oteam 입력 뒤 팀원 spawn 전까지 메인은 위임에 필요한 도구만 쓴다. 팀원·서브에이전트는 이 hook 앞머리에서 이미 나갔다.
  #   허용: Skill(ointaug·oi·oteam)·ToolSearch·ListAgents·AskUserQuestion·Agent·자기 세션 파일 읽기·no_kill 마커 쓰기·date 단독·shutdown 프로토콜.
  #   Agent 가 막혀도 AskUserQuestion 과 턴 종료는 열려 있고, Stop 은 2회만 막으며, 새 사용자 입력은 표식을 지운다. 그래서 영구 정지가 없다.
  if [[ -f "${SESSION_DIR}/oteam_required" && ! -f "${SESSION_DIR}/oteam_spawned" ]]; then
    _ot_in_self() {  # $1=경로 $2=세션 안 하위 경로(비면 세션 전체) → 자기 세션 두 base 중 한 곳 아래이면 0
      local _r _b
      _r=$(realpath -m -- "$1" 2>/dev/null) || return 1
      for _b in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" "$HOME/.claude"; do
        _b=$(realpath -m -- "$_b/session-env/${SID}/$2" 2>/dev/null) || continue
        [[ "$_r" == "$_b"/* ]] && return 0
      done
      return 1
    }
    _OT_P=$(printf '%s' "$TI" | jq -r '[.path, .file_path, .filepath] | map(select(type=="string" and . != ""))[0] // empty' 2>/dev/null)
    case "$TOOL" in
      ToolSearch|ListAgents|AskUserQuestion|Agent) exit 0 ;;
      Skill)
        _OT_SK=$(printf '%s' "$INPUT" | jq -r '(.tool_input.skill // .tool_input.skill_name // empty)' 2>/dev/null)
        _OT_SK="${_OT_SK##*:}"
        case "$_OT_SK" in oteam|ointaug|oi) exit 0 ;; esac
        ;;
      Read|mcp__oio__file_read)
        [[ -n "$_OT_P" ]] && _ot_in_self "$_OT_P" "" && exit 0
        ;;
      mcp__oio__file_write)
        [[ -n "$_OT_P" ]] && _ot_in_self "$_OT_P" "no_kill" && exit 0
        ;;
      Bash|mcp__oio__bash_exec)
        _OT_C=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // .tool_input.cmd // empty' 2>/dev/null)
        printf '%s' "$_OT_C" | grep -qE '^[[:space:]]*date([[:space:]]+[^;&|`$()<>]*)?[[:space:]]*$' && exit 0
        ;;
      SendMessage)
        _OT_M=$(printf '%s' "$INPUT" | jq -r '.tool_input.message | if type=="object" then (.type // "") else "" end' 2>/dev/null)
        [[ "$_OT_M" =~ ^(shutdown_request|shutdown_response|plan_approval_response)$ ]] && exit 0
        ;;
    esac
    _block "⛔ [F-OTEAM] /oteam 은 메인이 직접 처리하지 않고 팀에이전트에 맡긴다 — ${TOOL} 차단.
조치: Skill('oteam') 절차대로 Agent 로 팀원을 띄운다(인자가 없으면 AskUserQuestion 으로 요구사항을 먼저 묻는다).
허용 중: Skill(ointaug·oi·oteam)·ToolSearch·ListAgents·AskUserQuestion·Agent·자기 세션 파일 읽기·no_kill 마커 쓰기·date·shutdown 응답.
spawn 이 막히면 차단 문구를 그대로 사용자에게 보고하고 턴을 끝낸다. 메인이 대신 처리하지 않는다."
  fi
  exit 0
fi

# ─── 3. 미충족 중 허용 목록 ───
case "$TOOL" in
  Read|Grep|Glob|LS|ToolSearch|ListAgents|AskUserQuestion|TodoWrite|TaskStop|TaskList|TaskGet|WebSearch|WebFetch) exit 0 ;;
  mcp__oio__file_read|mcp__oio__find|mcp__oio__list_dir|mcp__oio__get_cwd|mcp__oio__file_info|mcp__oio__lock_status) exit 0 ;;
  mcp__mysql__query|mcp__mysql__list_tables|mcp__mysql__get_schema|mcp__mysql__explain_query) exit 0 ;;
  mcp__context7__*) exit 0 ;;
  Skill)
    _SK=$(printf '%s' "$INPUT" | jq -r '(.tool_input.skill // .tool_input.skill_name // empty)' 2>/dev/null)
    _SK="${_SK##*:}"
    [[ "$_SK" == "ointaug" ]] && exit 0
    # oi 대기 단계에서는 Skill 경로를 막지 않는다 — 스킬 경유는 oi_route_guard 가 증표로 판정한다
    [[ "$PEND" == "oi" ]] && exit 0
    ;;
  SendMessage)
    # shutdown/plan 승인 프로토콜 응답은 teammate idle guard 가 요구하는 조치일 수 있다 — 허용
    _MT=$(printf '%s' "$INPUT" | jq -r '.tool_input.message | if type=="object" then (.type // "") else "" end' 2>/dev/null)
    [[ "$_MT" =~ ^(shutdown_request|shutdown_response|plan_approval_response)$ ]] && exit 0
    ;;
  Bash|mcp__oio__bash_exec)
    _CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // .tool_input.cmd // empty' 2>/dev/null)
    # date 단독만 허용 (응답 말미 시각 표기 규칙)
    if printf '%s' "$_CMD" | grep -qE '^[[:space:]]*date([[:space:]]+[^;&|`$()<>]*)?[[:space:]]*$'; then exit 0; fi
    ;;
  mcp__oio__file_write|mcp__oio__session_state)
    # teammate idle guard 가 요구하는 agent_keep 기록
    if printf '%s' "$TI" | grep -qE '/agent_keep/|"key":"agent_keep'; then exit 0; fi
    ;;
esac

# ─── 4. 판정 근거 시각 (2026-10-11 — "호출했는데 왜 막히나" 혼란 해소. 판정 로직은 위 2절 그대로) ───
#   여러 줄 붙여넣기는 줄마다 별개 입력으로 들어와 요구 표식이 호출 이후로 다시 갱신될 수 있다.
#   차단 메시지에 두 mtime 을 시각으로 보여 주어 원인을 바로 알 수 있게 한다.
_hms() { local s; s=$(stat -c %.3Y "$1" 2>/dev/null) || { printf '없음'; return 0; }; date -d "@${s}" '+%H:%M:%S.%3N' 2>/dev/null || printf '없음'; }
_why() {
  printf '판정 근거: 마지막 사용자 입력 도착 %s (%s mtime) / 마지막 Skill('"'"'%s'"'"') 호출 증표 %s (%s mtime)\n→ 새 입력이 %s 호출 이후 도착했다(또는 이번 입력 뒤 호출 증표가 없다). 다시 Skill('"'"'%s'"'"') 를 호출하라.' \
    "$(_hms "${SESSION_DIR}/${1}_required")" "${1}_required" "$1" "$(_hms "${SESSION_DIR}/${1}_invoked")" "${1}_invoked" "$1" "$1"
}

# D8 — 요구 표식을 어떤 입력이 갱신했는지 보여 준다(판정 무관). UserPromptSubmit 이 logs/intaug_required.log 에 남긴 class=user 마지막 줄을 읽는다.
#   ERR trap 이 있으므로 실패를 흘리지 않는다. 표기 실패가 차단을 통과로 바꾸면 안 된다.
_marker_input() {
  local _f="${SESSION_DIR}/logs/intaug_required.log" _h="$HOME/.claude/session-env/${SID}/logs/intaug_required.log" _l=""
  if [[ ! -f "$_f" ]] || [[ "$_h" -nt "$_f" ]]; then _f="$_h"; fi
  if [[ -f "$_f" ]]; then
    _l=$(tail -n 200 "$_f" 2>/dev/null | grep -a 'class=user ' | tail -n 1) || _l=""
  fi
  printf '표식을 쓴 입력: %s' "${_l:-기록 없음(logs/intaug_required.log)}"
  return 0
}

# 전체 호출 순서 안내 (lib 부재 또는 빈 출력이면 기존 조치 문구로 폴백)
_HINT=""
if source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/skill_order.sh" 2>/dev/null; then
  _HINT=$(skill_order_hint "$SESSION_DIR" "$TOOL" 2>/dev/null) || _HINT=""
fi

if [[ "$PEND" == "ointaug" ]]; then
  _ACT_I="조치: Skill('ointaug') 호출 → 확장 질의 출력 → (파이프라인 활성 시) Skill('oi') → 그다음 이 도구를 다시 호출하라."
  [[ -n "$_HINT" ]] && _ACT_I="조치: ${_HINT}"
  _block "⛔ [F-INTAUG-3] 사용자 입력이 도착했는데 Skill('ointaug') 를 아직 호출하지 않았다 — ${TOOL} 차단.
$(_why ointaug)
$(_marker_input)
(턴 진행 중 도착한 입력도 포함한다. 팀원 메시지·시스템 알림은 해당 없음.)
CLAUDE.md 「ointaug 필수 호출 규칙」: 모든 사용자 입력의 첫 행동은 Skill('ointaug') 다.
마커(ointaug_done)를 직접 쓰는 것으로는 풀리지 않는다 — 증표는 Skill 실행 직후 hook 이 쓴다.
${_ACT_I}
허용 중: 조회 계열·date·ToolSearch·ListAgents·AskUserQuestion·Skill(ointaug)·shutdown 응답·agent_keep 기록."
else
  _ACT_O="조치: Skill('oi') 호출 → 분류 결과대로 진행."
  [[ -n "$_HINT" ]] && _ACT_O="조치: ${_HINT}"
  _block "⛔ [F-INTAUG-3] 파이프라인 활성 중 사용자 입력에 Skill('oi') 를 아직 호출하지 않았다 — ${TOOL} 차단.
$(_why oi)
$(_marker_input)
UserPromptSubmit 이 '💬 [oi] 활성 — Skill('oi') 호출 필수' 를 냈다. SendMessage·Agent 로 바로 위임하는 것은 oi 우회다.
oi_routed 를 직접 쓰는 것으로는 풀리지 않는다 — 증표는 Skill('oi') 실행 직후 hook 이 쓴다.
${_ACT_O}"
fi
