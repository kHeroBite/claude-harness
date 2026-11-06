#!/bin/bash
# 정본 문서(plan root 하위·test/tools README) 읽기를 리드 세션 plan_reads.log 에 남기는 PostToolUse hook
#
# 등록(settings.json): PostToolUse matcher "mcp__oio__file_read|mcp__oio__search|Read|Grep"
#   → time_budget.sh 1.5 open <이 파일 절대경로>
# 계약(계획서 §6 "PostToolUse_plan_read_log.sh"):
#   - 대상 도구: mcp__oio__file_read(path|file_path|filepath), mcp__oio__search(path), Read(file_path), Grep(path)
#   - 기록 조건: 프로젝트 루트 기준 <plan_root> 하위 경로, 또는 <test_root>/README.md·<tools_root>/README.md
#       프로젝트 루트·경로 설정 = [K6] 공용 해석기 lib/canon_root.py --path <cwd> (루트 없으면 cwd,
#         canon.plan_root 거부(절대경로·'..')면 plan root 기록 안 함). 해석기 없음·실패 시 종전 규칙:
#       프로젝트 루트 = 입력 cwd 에서 위로 올라가며 .claude/ 또는 .git 이 있는 첫 디렉터리($HOME 제외), 없으면 cwd
#       경로 설정 = <루트>/.claude/docs_gate.json 의 canon.{plan_root,test_root,tools_root}, 기본 plan·test·tools
#   - 기록 파일: <세션dir>/plan_reads.log, 줄 형식 `<epoch>\t<절대경로>`
#       세션dir = ${CLAUDE_CONFIG_DIR}/session-env/<리드UUID> 우선, 없으면 $HOME/.claude/session-env/<리드UUID>
#       디렉터리가 없으면 만들지 않고 끝낸다.
#   - 리드 UUID: PIPELINE_UUID → 조상 argv --parent-session-id(팀원) → 입력 session_id
#       시험: WG_TEST_SANDBOX=1 + WG_LINEAGE_OVERRIDE='team:<uuid>'|'main' (가짜 HOME 일 때만 인정)
#   - 모든 실패는 무출력 rc=0 (fail-open, 도구 호출을 막지 않는다)
# 세션 격리: 쓰기는 리드(파이프라인 소유) 세션 dir 하나뿐이다. 다른 세션 dir 은 탐색·쓰기하지 않는다.
# 한계: 셸(bash_exec 의 cat 등)로 읽은 것은 기록되지 않는다. 기록은 열람만 증명하고 이해는 증명하지 못한다.

trap 'exit 0' ERR
command -v jq >/dev/null 2>&1 || exit 0

INPUT=""
IFS= read -r -d '' -t 3 INPUT || true   # EOF 에서 rc=1 이 정상이다
[[ -n "$INPUT" ]] || exit 0

# 대상 도구가 아니면 jq 를 띄우지 않고 끝낸다
re_tool='"tool_name"[[:space:]]*:[[:space:]]*"([A-Za-z0-9_]+)"'
[[ $INPUT =~ $re_tool ]] || exit 0
case "${BASH_REMATCH[1]}" in
  mcp__oio__file_read|mcp__oio__search|Read|Grep) ;;
  *) exit 0 ;;
esac

mapfile -t F < <(printf '%s' "$INPUT" | jq -r '
  (.session_id // "" | tostring),
  (.cwd // "" | tostring),
  ((.tool_input // {}) | (.path // .file_path // .filepath // "") | tostring)' 2>/dev/null) || exit 0
SID=${F[0]:-}; CWD=${F[1]:-}; P=${F[2]:-}
[[ -n "$P" ]] || exit 0
if [[ "$P" != /* ]]; then
  [[ "$CWD" == /* ]] || exit 0
  P="$CWD/$P"
fi
P=$(realpath -m -s -- "$P" 2>/dev/null) || exit 0
[[ "$CWD" == /* ]] || exit 0
CWD=$(realpath -m -s -- "$CWD" 2>/dev/null) || exit 0

# 프로젝트 루트·정본 경로 설정 — [K6 TODO-003] 공용 해석기 canon_root 우선
ROOT=""; PR=plan; TR=test; OR=tools; PR_OFF=0; _CR_OK=0
_CR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/lib/canon_root.py"
_CRO=""
if [[ -f "$_CR" ]] && command -v python3 >/dev/null 2>&1; then
  _CRO=$(timeout 1 python3 -B "$_CR" --path "$CWD" 2>/dev/null) || _CRO=""
fi
if [[ -n "$_CRO" ]]; then
  mapfile -t C < <(printf '%s' "$_CRO" | jq -r '(.project_root // "" | tostring), (.plan_root_invalid | tostring),
    (.plan_root | tostring), (.test_root | tostring), (.tools_root | tostring)' 2>/dev/null) || C=()
  if (( ${#C[@]} >= 5 )) && [[ -n "${C[2]}" && -n "${C[3]}" && -n "${C[4]}" ]]; then
    _CR_OK=1; ROOT="${C[0]:-$CWD}"; PR="${C[2]}"; TR="${C[3]}"; OR="${C[4]}"
    [[ "${C[1]}" == true ]] && PR_OFF=1
  fi
fi
if (( _CR_OK == 0 )); then
d="$CWD"
while [[ -n "$d" && "$d" != "/" && "$d" != "$HOME" ]]; do
  if [[ -d "$d/.claude" || -e "$d/.git" ]]; then ROOT="$d"; break; fi
  d="${d%/*}"
done
ROOT="${ROOT:-$CWD}"

# 정본 경로 설정(종전 규칙)
if [[ -f "$ROOT/.claude/docs_gate.json" ]]; then
  mapfile -t C < <(jq -r '
    (.canon.plan_root // "plan" | tostring),
    (.canon.test_root // "test" | tostring),
    (.canon.tools_root // "tools" | tostring)' "$ROOT/.claude/docs_gate.json" 2>/dev/null) || true
  [[ -n "${C[0]:-}" ]] && PR="${C[0]}"
  [[ -n "${C[1]:-}" ]] && TR="${C[1]}"
  [[ -n "${C[2]:-}" ]] && OR="${C[2]}"
fi
fi
_abs() { local x="${1%/}"; [[ "$x" == /* ]] && printf '%s' "$x" || printf '%s' "$ROOT/$x"; }
PRA=$(_abs "$PR"); TRA=$(_abs "$TR"); ORA=$(_abs "$OR")

# [F-PLAN-REF-WT 2026-11-05] cwd 루트의 plan root 밖이어도, 같은 git 저장소의 주 작업트리·worktree 의 <plan_root> 하위면 기록한다
#   (팀원이 원본에서 읽거나 메인 cwd 가 낡은 worktree 일 때의 교착 해소). .git·commondir·<common>/worktrees/*/gitdir 파일만 읽는다(최대 64개).
#   test·tools README 는 종전대로 cwd 루트 기준이다. 다른 저장소 경로는 기록하지 않는다.
_wt_hit() {
  local _g="$ROOT/.git" _common="" _l="" _gd _c _w _p _pa _n=0
  local -a _cands=("$ROOT")
  if [[ -d "$_g" ]]; then _common="$_g"
  elif [[ -f "$_g" ]]; then
    read -r _l < "$_g" || _l=""
    if [[ "$_l" == gitdir:* ]]; then
      _gd="${_l#gitdir:}"; _gd="${_gd#"${_gd%%[![:space:]]*}"}"
      [[ "$_gd" == /* ]] || _gd="$ROOT/$_gd"
      if [[ -f "$_gd/commondir" ]]; then
        read -r _c < "$_gd/commondir" || _c=""
        [[ "$_c" == /* ]] || _c="$_gd/$_c"
        _common="$_c"
      else _common="$_gd/../.."; fi
      _common=$(realpath -m -s -- "$_common" 2>/dev/null) || _common=""
    fi
  fi
  if [[ -n "$_common" && -d "$_common" ]]; then
    [[ "${_common##*/}" == ".git" ]] && _cands+=("${_common%/.git}")
    for _w in "$_common"/worktrees/*/gitdir; do
      [[ -f "$_w" ]] || continue
      (( _n++ < 64 )) || break
      read -r _p < "$_w" || continue
      _p=$(realpath -m -s -- "$_p" 2>/dev/null) || continue
      _cands+=("${_p%/.git}")
    done
  fi
  for _c in "${_cands[@]}"; do
    _pa="${PR%/}"; [[ "$_pa" == /* ]] || _pa="$_c/$_pa"
    case "$P" in "$_pa"|"$_pa"/*) return 0 ;; esac
  done
  return 1
}
_hit=0
if (( PR_OFF == 0 )); then
  case "$P" in "$PRA"|"$PRA"/*) _hit=1 ;; esac
fi
case "$P" in "$TRA/README.md"|"$ORA/README.md") _hit=1 ;; esac
if (( _hit == 0 )); then
  # plan_root 가 거부되면 worktree 대조도 하지 않는다
  if (( PR_OFF == 1 )) || ! _wt_hit; then exit 0; fi
fi

# 리드 UUID
UUID="${PIPELINE_UUID:-}"
SRC=env
if [[ -z "$UUID" ]]; then
  SRC=lineage
  _real_home=""
  if [[ "${WG_TEST_SANDBOX:-}" == "1" && -n "${WG_LINEAGE_OVERRIDE:-}" ]]; then
    _real_home=$(getent passwd "$(id -un 2>/dev/null)" 2>/dev/null | cut -d: -f6)
  fi
  if [[ -n "$_real_home" && "$HOME" != "$_real_home" ]]; then
    case "$WG_LINEAGE_OVERRIDE" in team:*) UUID="${WG_LINEAGE_OVERRIDE#team:}" ;; esac
  else
    p=$PPID
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
      [[ "$p" =~ ^[0-9]+$ ]] && (( p > 1 )) || break
      mapfile -d '' -t ARGV 2>/dev/null < "/proc/$p/cmdline" || break
      for (( i = 0; i + 1 < ${#ARGV[@]}; i++ )); do
        [[ "${ARGV[i]}" == "--parent-session-id" ]] && { UUID=${ARGV[i+1]}; break 2; }
        [[ "${ARGV[i]}" == --parent-session-id=* ]] && { UUID=${ARGV[i]#*=}; break 2; }
      done
      read -r STAT 2>/dev/null < "/proc/$p/stat" || break
      STAT=${STAT##*) }
      read -r _S p _R <<< "$STAT" || break
    done
  fi
  if [[ -z "$UUID" ]]; then UUID="$SID"; SRC=session_id; fi
fi
[[ $UUID =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || exit 0

SD=""
for b in "${CLAUDE_CONFIG_DIR:-}" "$HOME/.claude"; do
  [[ -n "$b" && -d "$b/session-env/$UUID" ]] && { SD="$b/session-env/$UUID"; break; }
done
[[ -n "$SD" ]] || exit 0

printf -v NOW '%(%s)T' -1
printf '%s\t%s\n' "$NOW" "$P" >> "$SD/plan_reads.log" 2>/dev/null || true
# 팀원인데 리드 해석에 실패해 자기 session_id 로 떨어진 경우를 추적할 수 있게 1줄 남긴다
if [[ "$SRC" == "session_id" && -d "$SD/logs" ]]; then
  printf '%s\tFALLBACK session_id\t%s\n' "$NOW" "$P" >> "$SD/logs/plan_read_log.log" 2>/dev/null || true
fi
exit 0
