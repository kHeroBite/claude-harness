#!/bin/bash
# write_guard.sh — ok 파이프라인 수정/탐색 도구 통합 가드
# 통합: ok_check.sh + ok_full_edit_guard.sh + ok_explore_guard.sh + team_dir_guard.sh
# PreToolUse 이중 matcher 등록:
#   수정 도구: Edit|Write|Notebookedit|serena_replace|insert|rename
#   탐색 도구: Grep|Glob|serena_find|find_referencing|find_symbol|get_symbols|search_for_pattern

# --- stdin JSON 읽기 (set -e 전에 수행 — 안전) ---
_WG_IN_RC=0
INPUT=$(timeout 2 cat 2>/dev/null) || { _WG_IN_RC=$?; INPUT=""; }
# [사이클182 반복1 A1] hook 입력을 끝까지 받지 못했거나(시간 초과) 비어 있으면 도구를 알 수 없어 종전에는 통과했다
#   (실측: stdin 3초 지연 → rc=0, 대조 즉시 rc=2 [F-LKG-PROT]). hook 은 항상 JSON 입력을 받는다 — 실행 호출부 중 빈 입력은
#   없다(전수 grep). time_budget 을 거치지 않는 직접 호출의 fail-open 을 막는다. 판정불가는 통과가 아니다.
if [[ "$_WG_IN_RC" -ne 0 || -z "${INPUT//[[:space:]]/}" ]]; then
  echo "{\"decision\":\"block\",\"reason\":\"⏳ [WG-INPUT] write_guard 가 hook 입력을 끝까지 받지 못했습니다(rc=${_WG_IN_RC}, 빈 입력 또는 시간 초과) — 아직 거부가 아닙니다. 판정불가는 통과가 아니므로 이번 호출은 보류합니다. 같은 호출을 다시 하십시오.\"}"
  exit 2
fi
# [사이클205 D-9] 입력 JSON 1회 파싱 — 아래 여러 지점이 같은 필드를 필드마다 jq 로 다시 읽던 것(IDLE ls 1회 판정에 jq 25회)을
#   변수로 재사용한다. 판정 의미는 바꾸지 않는다: 각 값은 종전 식과 같은 `A // B // empty` 대체 규칙으로 고르고(null·false → ""),
#   뒤쪽 개행은 $(…) 와 같게 모두 지운다. 고른 값이 문자열·불리언·null 밖(숫자·객체·배열)이거나 NUL 을 품거나 jq 가 실패하면
#   _WG_PRE=0 → 각 지점이 종전 jq 식을 그대로 1회 실행한다(_wg_pre 폴백).
# [overblock file_path] oio 는 path 가 비면 file_path·filepath 를 대상으로 쓴다. path 만 읽으면 메타 파일 보호가 비켜 가고 차단 문구의 대상이 빈칸이 된다.
#   별칭 대상 도구(file_write·file_edit·file_delete·file_rename)만 넓힌다. file_copy·file_move 의 path 판정은 그대로다.
_wg_path_of() {
  printf '%s' "$INPUT" | jq -r 'if ((.tool_name // "") | tostring | test("file_(write|edit|delete|rename)$")) then ([.tool_input.path, .tool_input.file_path, .tool_input.filepath] | map(select(type == "string" and . != "")) | .[0] // empty) else (.tool_input.path // empty) end' 2>/dev/null
}
_WG_PRE=0; _WG_TOOL=""; _WG_SID=""; _WG_CMD_OC=""; _WG_CMD_ONLY=""; _WG_RUNBG=""; _WG_PATH=""; _WG_STRCMD=""
{ IFS= read -r -d '' _WG_PRE && IFS= read -r -d '' _WG_TOOL && IFS= read -r -d '' _WG_SID && \
  IFS= read -r -d '' _WG_CMD_OC && IFS= read -r -d '' _WG_CMD_ONLY && IFS= read -r -d '' _WG_RUNBG && \
  IFS= read -r -d '' _WG_PATH && IFS= read -r -d '' _WG_STRCMD; } < <(printf '%s' "$INPUT" | jq -j '
  [ (.tool_name // null), (.session_id // null), (.tool_input.command // .tool_input.cmd // null), (.tool_input.command // null),
    (.tool_input.run_in_background // null), (.tool_input.path // null),
    (([.tool_input.command, .tool_input.cmd] | map(select(type == "string"))[0]) // null) ] as $v
  | (if ($v | all(type == "null" or type == "string" or type == "boolean"))
        and ($v | all(if type == "string" then (contains("\u0000") | not) else true end)) then "1" else "0" end) as $ok
  | ([$ok] + ($v | map(if . == null then "" else tostring end))) | join("\u0000") + "\u0000"' 2>/dev/null) || _WG_PRE=0
[[ "$_WG_PRE" == 1 ]] || _WG_PRE=0
if [[ "$_WG_PRE" == 1 ]]; then
  for _wg_v in _WG_TOOL _WG_SID _WG_CMD_OC _WG_CMD_ONLY _WG_RUNBG _WG_PATH _WG_STRCMD; do
    printf -v "$_wg_v" '%s' "${!_wg_v%"${!_wg_v##*[!$'\n']}"}"   # 뒤쪽 개행 전부 제거($(…) 와 같게)
  done
fi
_wg_pre() {  # $1=변수명 $2=캐시값 $3=종전 jq 식(INPUT 대상, -r) — 캐시가 유효하면 그 값, 아니면 종전과 같은 jq 1회
  if [[ "$_WG_PRE" == 1 ]]; then printf -v "$1" '%s' "$2"
  else printf -v "$1" '%s' "$(echo "$INPUT" | jq -r "$3" 2>/dev/null || echo "")"; fi
}
_wg_pre TOOL_NAME "$_WG_TOOL" '.tool_name // empty'

# ═════════════════════════════════════════════════════════════════════════════
# [사이클194 (g①)] F-NO-BYPASS 기록부 — file 도구 판정 결과를 자기 세션 logs/fw_attempts.tsv 에 남긴다.
#   형식: epoch \t 상태(PENDING|PASS|BLOCK|REDIRECT|RC<n>) \t 실경로(realpath -m) \t basename \t 행위자
#   진입 시 PENDING 을 쓰고, 종료(EXIT trap)에서 최종 rc 를 덧붙인다(2=BLOCK, 0=PASS). 신호로 죽으면 PENDING 이 남는다.
#   대상 경로: 쓰기·삭제되는 쪽만(path/file_path/filepath/destination/dest/link_path, file_move 는 source/src 도).
#     file_copy 원본·symlink target 은 바뀌지 않으므로 넣지 않는다. 탭·개행이 든 경로는 기록하지 않는다.
#   아래 F-NO-BYPASS 셸 판정이 600초 안 마지막 상태가 PASS 가 아닌 경로를 셸로 다시 쓰려는 시도를 막는다.
#   기록 실패는 조용히 무시한다(기록부가 가드를 세우면 안 된다). 600줄을 넘으면 뒤 300줄만 남긴다.
# ═════════════════════════════════════════════════════════════════════════════
#   셸 대안을 직접 안내하는 차단(L-014 rsync·state_machine.sh 경유)은 _FW_REDIRECT=1 로 REDIRECT 상태를 남겨 판정에서 뺀다.
_FW_LOG=""; _FW_ENTRIES=""; _FW_DONE=""; _FW_REDIRECT=""; _FW_SID=""
#   행위자(5열): 조상 프로세스 argv 의 --agent-id 값(팀원) 또는 main. 같은 행위자 기록끼리만 대조한다
#     (실환경은 팀원 session_id 가 메인과 달라 이미 갈리지만, 같은 session_id 를 공유하는 경로에서도 남의 차단으로 막히지 않게).
_FW_ACTOR=""
_wg_fw_actor() {  # fork 없이 /proc 를 읽는다(builtin mapfile·read) — 최대 12단계
  local _p=$$ _i=0 _j _k _v _a=""
  local -a _av
  while [[ "$_p" =~ ^[0-9]+$ && "$_p" -gt 1 && $_i -lt 12 ]]; do
    _av=(); mapfile -d '' -t _av 2>/dev/null < "/proc/${_p}/cmdline"
    for ((_j = 0; _j < ${#_av[@]}; _j++)); do
      case "${_av[_j]}" in
        --agent-id) _a="${_av[_j+1]:-team}" ;;
        --agent-id=*) _a="${_av[_j]#--agent-id=}" ;;
        *" --agent-id "*) _a="${_av[_j]#* --agent-id }"; _a="${_a%% *}" ;;
      esac
      [[ -n "$_a" ]] && { printf '%s' "${_a//[$'\t\n']/}"; return 0; }
    done
    _k=""; _v=""
    while read -r _k _v; do [[ "$_k" == "PPid:" ]] && break; done 2>/dev/null < "/proc/${_p}/status"
    [[ "$_k" == "PPid:" ]] || break
    _p="$_v"; _i=$((_i + 1))
  done
  printf 'main'
}
_wg_fw_write() {  # $1=상태 — _FW_ENTRIES 전부를 한 번에 덧붙인다
  [[ -n "$_FW_LOG" && -n "$_FW_ENTRIES" ]] || return 0
  local _l _buf="" _now _n
  _now=$(date +%s 2>/dev/null) || _now=0
  while IFS= read -r _l; do
    [[ -n "$_l" ]] && _buf+="${_now}"$'\t'"${1}"$'\t'"${_l}"$'\t'"${_FW_ACTOR:-main}"$'\n'
  done <<<"$_FW_ENTRIES"
  [[ -n "$_buf" ]] && { printf '%s' "$_buf" >>"$_FW_LOG"; } 2>/dev/null
  _n=$(wc -l <"$_FW_LOG" 2>/dev/null) || _n=0
  if [[ "${_n:-0}" =~ ^[0-9]+$ ]] && [[ "$_n" -gt 600 ]]; then
    { tail -n 300 -- "$_FW_LOG" >"$_FW_LOG.tmp.$$" && mv -f -- "$_FW_LOG.tmp.$$" "$_FW_LOG"; } 2>/dev/null || rm -f -- "$_FW_LOG.tmp.$$" 2>/dev/null
  fi
  return 0
}
_wg_fw_end() {  # $1=최종 rc — 한 번만 기록
  [[ -z "$_FW_DONE" && -n "$_FW_LOG" ]] || return 0
  _FW_DONE=1
  local _st="RC${1:-x}"
  [[ "${1:-}" == "2" ]] && _st="BLOCK"
  [[ "${1:-}" == "2" && -n "${_FW_REDIRECT:-}" ]] && _st="REDIRECT"
  [[ "${1:-}" == "0" ]] && _st="PASS"
  _wg_fw_write "$_st" || true
  [[ "$_st" == PASS && -n "${_FW_SID:-}" ]] && { _wg_fw_author || true; }
  return 0
}
# [사이클196 과제1] PASS 된 .sh/.bash 파일 도구 쓰기의 작성자 sid 를 기록부에 남긴다(lib/script_recheck.sh sr_author_record).
#   F-SCRIPT-RECHECK 가 "다른 sid 가 쓴 뒤 그대로인 스크립트" 를 예외로 두는 근거다. 삭제·심볼릭링크는 내용을 쓰지 않으므로 기록하지 않는다.
#   비 .sh 쓰기는 fork 0. lib 부재·기록 실패는 조용히 무시한다(기록부가 가드를 세우면 안 된다).
_wg_fw_author() {
  case "$TOOL_NAME" in mcp__oio__file_delete|mcp__oio__file_symlink) return 0 ;; esac
  local _rp _b
  while IFS=$'\t' read -r _rp _b; do
    [[ "$_rp" == *.sh || "$_rp" == *.bash ]] || continue
    declare -F sr_author_record >/dev/null 2>&1 || source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/script_recheck.sh" 2>/dev/null || return 0
    declare -F sr_author_record >/dev/null 2>&1 || return 0
    sr_author_record "$_rp" "$_FW_SID" >/dev/null 2>&1 || true
  done <<<"$_FW_ENTRIES"
  return 0
}
_wg_fw_begin() {
  local _sid _d _p _rp _sel='[.path,.file_path,.filepath,.destination,.dest,.link_path]'
  case "$TOOL_NAME" in
    mcp__oio__file_move) _sel='[.path,.file_path,.filepath,.destination,.dest,.link_path,.source,.src]' ;;
    mcp__oio__file_write|mcp__oio__file_edit|mcp__oio__file_delete|mcp__oio__file_copy|\
    mcp__oio__file_rename|mcp__oio__file_symlink|Write|Edit|MultiEdit|NotebookEdit) ;;
    *) return 0 ;;
  esac
  _sid=$(jq -r '.session_id // empty' <<<"$INPUT" 2>/dev/null) || return 0
  [[ "$_sid" =~ ^[0-9a-fA-F-]{36}$ ]] || return 0
  _FW_SID="$_sid"   # [사이클196 과제1] _wg_fw_author 가 작성자 기록에 쓴다
  _d="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${_sid}/logs"
  mkdir -p -- "$_d" 2>/dev/null || return 0
  while IFS= read -r _p; do
    [[ -n "$_p" && "$_p" != *$'\t'* ]] || continue
    _rp=$(realpath -m -- "$_p" 2>/dev/null) || _rp="$_p"
    [[ -n "$_rp" ]] || _rp="$_p"
    _FW_ENTRIES+="${_rp}"$'\t'"${_rp##*/}"$'\n'
  done < <(jq -r ".tool_input | ${_sel} | map(select(type==\"string\" and . != \"\"))[]" <<<"$INPUT" 2>/dev/null)
  [[ -n "$_FW_ENTRIES" ]] || return 0
  _FW_LOG="$_d/fw_attempts.tsv"
  _FW_ACTOR=$(_wg_fw_actor 2>/dev/null) || _FW_ACTOR="main"
  _wg_fw_write PENDING || true
  return 0
}
_wg_fw_begin || true
# 아래 F-LKG-PROT 구간이 EXIT trap 을 _wg_lkg_undet_exit 로 바꿔 끼우며, 그 함수가 최종 rc 로 _wg_fw_end 를 부른다.
trap '_wg_fw_end $?' EXIT
# --- F-NO-BYPASS 기록부 끝 ---


# ═════════════════════════════════════════════════════════════════════════════
# [H-2 2026-08-17] shutdown 발신 후 미응답 조기 경고 — ★ 경고만. 차단 절대 없음.
#
# 배경: verify-1 / diag-1 / odev-2 3건이 작업 완료 후 SendMessage 미호출로 보고를 유실했다.
#       shutdown_request 2회에도 응답이 없었고, 메인은 유휴 알림만 보고 추측해야 했다.
#       H-1(SubagentStop_report_guard)이 발생을 막고, H-2 는 이미 발생한 상태를 빨리 알린다.
#
# ★ 이 블록은 stderr 로 경고만 출력하고 절대 exit 하지 않는다.
#   write_guard 는 모든 도구 호출을 거치는 경로다. 여기서 오동작하면 4개 프로젝트가 멈춘다.
#   그래서 판정 실패·라이브러리 부재·타임아웃은 전부 침묵 통과이고, decision:block 을 내지 않는다.
#
# 긴급 정지: lib/orphan_scan.sh 를 지우면 H-1 과 함께 이 경고도 동시에 무력화된다(기존 탈출구 유지).
# ═════════════════════════════════════════════════════════════════════════════
_H2_WARN_LIB="${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/orphan_scan.sh"
if [[ -r "$_H2_WARN_LIB" ]]; then
  _wg_pre _H2_WARN_UUID "$_WG_SID" '.session_id // empty'   # c205 D-9
  if [[ -n "$_H2_WARN_UUID" ]]; then
    _H2_STALE=$(timeout 2 bash -c "source '$_H2_WARN_LIB' 2>/dev/null; shutdown_stale_list '$_H2_WARN_UUID' 90" 2>/dev/null) || _H2_STALE=""
    if [[ -n "$_H2_STALE" ]]; then
      while read -r _h2_agent _h2_age; do
        [[ -n "$_h2_agent" ]] || continue
        case "$_h2_age" in ''|*[!0-9]*) continue ;; esac
        # [사이클182 odev-6 요청] '%{pane}' 이 치환되지 않은 문자 그대로 출력되던 결함 — agents/<이름> 의 pane_id 를 읽는다(없으면 ?).
        _h2_pane=$(grep '^pane_id=' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${_H2_WARN_UUID}/agents/${_h2_agent}" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '\r\n ')
        # [c-H2 2026-10-16] 종료 확인된 팀원은 stale 목록에서 이미 제외된다(orphan_scan.sh _shutdown_agent_ended).
        #   pane_id 를 못 찾으면 '?' 를 찍지 않고, 프로세스 판정으로 남은 생존/불명 상태를 그대로 알린다.
        if [[ -n "$_h2_pane" ]]; then
          echo "⚠️ [H-2] ${_h2_agent} shutdown 발신 후 ${_h2_age}초 미응답 — 발신 누락 의심. pane 캡처 권고: tmux capture-pane -p -t ${_h2_pane}" >&2
        else
          echo "⚠️ [H-2] ${_h2_agent} shutdown 발신 후 ${_h2_age}초 미응답 — 프로세스 생존 또는 불명(pane 미상). 종료 확인 시 자동 해제됩니다." >&2
        fi
      done <<< "$_H2_STALE"
    fi
  fi
fi
# --- H-2 끝 (exit 없음 — 아래 기존 흐름 그대로 진행) ---

# --- KQ_GATE 제거됨 (2026-04-03) ---
# IDLE: oi 스킵 (메인 직접 처리)
# 파이프라인 활성: UserPromptSubmit 소프트 메시지로 Skill('oi') 안내

# --- F-CRUD-1: otest_done / make_ok 쓰기 전 CRUD 실행증거 게이트 (사이클31 · 사이클168 도구 확장) ---
# 배경: 사이클30 otest 가 T3 를 "전필드 DB일치 · PASS" 로 판정했으나 저장 경로를 태우지 않았다.
#       삭제 가드(차단)만 확인하고 추가/수정은 "운영 데이터 보호"를 이유로 건너뛴 결과,
#       반쪽 저장(정본만 저장되고 부가 축 누락)이 실사용에서 즉시 드러났다.
# 원칙: 차단 확인은 저장 검증이 아니다. "운영 데이터 보호"는 면제 사유가 아니라 개발 DB 사용 사유다.
# 위치: ★모든 조기 exit 0 보다 앞★ — evidence/ 는 session-env(=.claude/) 하위라
#       ".claude/ 하위 oio 전역 허용"(P4 이후 섹션)과 팀에이전트 우회(P4)에 먼저 걸려 통과해 버린다.
#       실측으로 확인함: 뒤에 두었을 때 rc=0 으로 게이트가 무력화됐다 (L-718: 코드 실재 ≠ 실행).
# 범위: evidence/otest_done 또는 evidence/make_ok 를 만드는 쓰기 한정 (그 외 경로는 일절 건드리지 않음).
#   c177(A12 결함3): evidence/make_partial 도 같은 경로 산출로 본다 — 판정기 산출 전용이라 도구·셸 생성은 무조건 차단.
# 실패 안전: 스크립트 부재 시에는 통과시킨다 (게이트 부재가 파이프라인을 세우면 안 된다).
#
# ── 사이클168 확장 (계획 rev3.2 T2 · §5.1 R1/R2 · D5 · D6) ─────────────────────
# 문제: 필터가 file_write/file_edit 두 도구뿐이라 file_copy·file_move·file_rename·file_symlink·
#       dir_move·내장 Write/Edit·Bash/bash_exec 로 같은 마커를 만들면 게이트를 통째로 건너뛰었다(사이클167 실측).
# 조치:
#   - 대상 경로는 별칭 값을 ★전부★ 본다(첫 값만 보면 {"destination":"","to":"…/make_ok"} 로 우회된다).
#   - 목적지가 기존 디렉터리이거나 '/' 로 끝나면 실제로 생기는 경로 = 목적지/basename(원본).
#   - 경로는 realpath -m -s(링크 미해석) 와 realpath -m(링크 해석) ★두 형태 모두★ 로 판정한다
#     (evidence/./make_ok · evidence//make_ok · 심볼릭 디렉터리 경유를 같은 마커로 본다).
#   - copy/move/rename/symlink/dir_* 로 make_ok 를 만들면 ★디스크의 기존 make_ok 가 아니라 원본★ 을
#     --evidence 로 검사한다(D6 — 들어올 내용은 원본이다).
#   - 셸(Bash·bash_exec)은 쓰여질 내용을 알 수 없으므로 마커 쓰기 패턴이 보이면 무조건 차단한다(D5).
# 비용: 대상 도구에서도 jq 1회 + 문자열 사전 필터만 돈다. 마커 이름이 입력에 없으면 realpath 를 부르지 않는다.
#   단 dir_move/dir_rename 은 마커 이름이 입력에 안 나타나므로 원본 디렉터리를 직접 본다(드문 도구).

# R1/R2 대상 경로 산출 — 줄마다 "<정규화 경로>\t<원본 경로>" (원본 없으면 빈칸). 두 정규화 형태를 모두 낸다.
#   $1 = tool_input JSON (jq 로 한 번 정규화된 문자열)
_r1_emit() {  # $1=경로 $2=원본
  local _p="$1" _a _b
  [[ -n "$_p" ]] || return 0
  _a=$(realpath -m -s -- "$_p" 2>/dev/null); [[ -n "$_a" ]] || _a="$_p"
  _b=$(realpath -m -- "$_p" 2>/dev/null); [[ -n "$_b" ]] || _b="$_a"
  printf '%s\t%s\n' "$_a" "$2"
  [[ "$_b" != "$_a" ]] && printf '%s\t%s\n' "$_b" "$2"
  return 0
}
_r1_dest() {  # $1=목적지 후보 $2=원본 — 기존 디렉터리이거나 '/' 로 끝나면 목적지/basename(원본)
  local _d="$1" _s="$2"
  if [[ -n "$_s" && ( "$_d" == */ || -d "$_d" ) ]]; then
    printf '%s/%s' "${_d%/}" "$(basename -- "$_s")"
  else
    printf '%s' "$_d"
  fi
}
_r1_targets() {
  local _ti="$1" _src="" _c _d _m _rows
  case "$TOOL_NAME" in
    mcp__oio__file_write|mcp__oio__file_edit|Write|Edit|MultiEdit)
      _rows=$(jq -r '[.path,.file_path,.filepath] | map(select(type=="string" and . != ""))[]' <<<"$_ti" 2>/dev/null)
      while IFS= read -r _c; do _r1_emit "$_c" ""; done <<<"$_rows"
      ;;
    mcp__oio__file_copy|mcp__oio__file_move)
      _src=$(jq -r '[.source,.src,.path] | map(select(type=="string" and . != ""))[0] // empty' <<<"$_ti" 2>/dev/null)
      _rows=$(jq -r '[.destination,.dest,.dst,.target,.to] | map(select(type=="string" and . != ""))[]' <<<"$_ti" 2>/dev/null)
      while IFS= read -r _c; do
        [[ -n "$_c" ]] || continue
        _r1_emit "$(_r1_dest "$_c" "$_src")" "$_src"
      done <<<"$_rows"
      ;;
    mcp__oio__file_rename)
      _src=$(jq -r '[.path,.file_path] | map(select(type=="string" and . != ""))[0] // empty' <<<"$_ti" 2>/dev/null)
      _rows=$(jq -r '[.new_name,.name,.new_path,.to] | map(select(type=="string" and . != ""))[]' <<<"$_ti" 2>/dev/null)
      while IFS= read -r _c; do
        [[ -n "$_c" ]] || continue
        [[ "$_c" == /* ]] || _c="$(dirname -- "${_src:-.}")/$_c"
        _r1_emit "$_c" "$_src"
      done <<<"$_rows"
      ;;
    mcp__oio__file_symlink)
      # ★.target 은 원본이다★ — 링크 경로는 link_path/link/dest/path 뿐.
      _src=$(jq -r '[.target,.source,.src] | map(select(type=="string" and . != ""))[0] // empty' <<<"$_ti" 2>/dev/null)
      _rows=$(jq -r '[.link_path,.link,.dest,.path] | map(select(type=="string" and . != ""))[]' <<<"$_ti" 2>/dev/null)
      while IFS= read -r _c; do
        [[ -n "$_c" ]] || continue
        _d="$_src"
        [[ -n "$_d" && "$_d" != /* ]] && _d="$(dirname -- "$_c")/$_d"
        _r1_emit "$(_r1_dest "$_c" "$_d")" "$_d"
      done <<<"$_rows"
      ;;
    mcp__oio__dir_move|mcp__oio__dir_rename)
      _src=$(jq -r '[.source,.src,.path,.file_path] | map(select(type=="string" and . != ""))[0] // empty' <<<"$_ti" 2>/dev/null)
      [[ -n "$_src" && -d "$_src" ]] || return 0
      _rows=$(jq -r '[.destination,.dest,.dst,.target,.to,.new_name,.name] | map(select(type=="string" and . != ""))[]' <<<"$_ti" 2>/dev/null)
      while IFS= read -r _c; do
        [[ -n "$_c" ]] || continue
        if [[ "$TOOL_NAME" == "mcp__oio__dir_rename" && "$_c" != /* ]]; then
          _c="$(dirname -- "$_src")/$_c"
        else
          _c=$(_r1_dest "$_c" "$_src")
        fi
        for _m in make_ok otest_done make_partial; do
          [[ -f "$_src/$_m" ]] && _r1_emit "${_c%/}/$_m" "$_src/$_m"
          [[ -f "$_src/evidence/$_m" ]] && _r1_emit "${_c%/}/evidence/$_m" "$_src/evidence/$_m"
        done
      done <<<"$_rows"
      ;;
  esac
  return 0
}

_CRUD_CLASS=""
case "$TOOL_NAME" in
  mcp__oio__file_write|mcp__oio__file_edit|Write|Edit|MultiEdit|\
  mcp__oio__file_copy|mcp__oio__file_move|mcp__oio__file_rename|mcp__oio__file_symlink) _CRUD_CLASS="file" ;;
  mcp__oio__dir_move|mcp__oio__dir_rename) _CRUD_CLASS="dir" ;;
  Bash|mcp__oio__bash_exec) _CRUD_CLASS="shell" ;;
esac
# jq 로 한 번 정규화한 tool_input — \u 이스케이프 등으로 사전 필터를 비켜 가지 못하게 디코드된 값으로 본다.
_CRUD_TI=""
[[ -n "$_CRUD_CLASS" ]] && _CRUD_TI=$(echo "$INPUT" | jq -c '.tool_input // {}' 2>/dev/null || echo "")

# ── F-CRUD-1 FAIL 안내 (conv_179163042411 역라우팅 #2 10A·10B) ──
# F-CRUD-1 FAIL 은 lib/crud_fail_triage.py 가 판정기 출력을
#   분류하고(판정은 하지 않는다), 테스트 픽스처만 DB 접촉으로 잡힌 경우에 한해 --exclude-test-fixtures 로 1회 재판정한다.
#   그 밖의 분류는 차단하고 분류별 역라우팅(REROUTE_DEV→DEV / REROUTE_PLAN→PLAN)을 안내한다 — 에이전트가 고친다.
# 화면 승인(2026-10-20 conv_179239511726 사용자 지시로 재도입 — 728be20 에서 없앴던 채널): DECLARATION_CONFLICT 분류에 한해
#   메인 세션 트랜스크립트 원본의 AskUserQuestion 승인(header 승인:CRUD_GATE, 30분, 1회 소비)으로 1회 넘길 수 있다.
#   판정은 lib/askq_approval.py 가 hook 입력의 transcript_path·session_id 로 한다(읽기 전용, 소비 기록만 자기 세션 logs 에 1줄).
#   팀원 호출·팀원 트랜스크립트·다른 분류(EVIDENCE_MISSING·SCAN_UNVERIFIABLE·INPUT_ERROR·UNKNOWN)는 승인으로 넘길 수 없다.
#   JSON reason 에 그대로 들어가므로 큰따옴표·역슬래시를 쓰지 않는다.
_CRUD_TRIAGE_LIB="${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/crud_fail_triage.py"
_CRUD_FAIL_GUIDE="DECLARATION_CONFLICT 외 분류는 사람 승인으로 넘길 수 없다. 팀원은 team-lead 에 이 줄을 보고하고, team-lead 는 REROUTE_DEV→DEV / REROUTE_PLAN→PLAN 역라우팅으로 에이전트가 고친다."
# DECLARATION_CONFLICT 차단 문구에만 덧붙인다(다른 분류에는 승인 안내를 내지 않는다).
# [unblock3 odev-7] 사용자 지시 2026-10-27 15:53(불필요한 승인요청은 자동 승인) — DECLARATION_CONFLICT 는 허용 코드 범위 안이면
#   화면 질문(승인:CRUD_GATE) 없이 자동 통과하고 감사 로그를 남긴다. 범위 검사(화이트리스트·미지 코드 차단)는 그대로다.
#   이 안내는 범위 밖 코드 때문에 자동 통과하지 못한 경우에만 붙는다.
_CRUD_ASKQ_GUIDE="DECLARATION_CONFLICT 는 허용 코드 범위 안이면 화면 질문 없이 자동 통과한다(사용자 지시 2026-10-27 15:53, 감사 로그 logs/crud_gate_override.log). 이번에는 범위 밖 코드가 섞여 자동 통과하지 않았고 화면 승인으로도 넘길 수 없다 — 그 코드의 원인을 고친다. 팀원은 team-lead 에 보고한다."
_CRUD_AUTO_AUDIT="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/logs/auto_approval_audit.log"
# 분류기 호출 — $1=판정기 출력 $2=rc → _CRUD_TCLASS _CRUD_TACTION _CRUD_THINT. 분류기 부재·실패·형식 이상은 UNKNOWN/REROUTE_DEV.
_crud_triage() {
  local _o=""
  if [[ -f "$_CRUD_TRIAGE_LIB" ]]; then
    _o=$(printf '%s' "$1" | timeout 2 python3 "$_CRUD_TRIAGE_LIB" --rc "$2" 2>/dev/null | head -1)
  fi
  _CRUD_TCLASS=$(printf '%s' "$_o" | sed -n 's/^CLASS=\([A-Z_]*\) .*/\1/p')
  _CRUD_TACTION=$(printf '%s' "$_o" | sed -n 's/^CLASS=[A-Z_]* ACTION=\([A-Z_]*\).*/\1/p')
  _CRUD_THINT=$(printf '%s' "$_o" | sed -n 's/^CLASS=[A-Z_]* ACTION=[A-Z_]* HINT=//p' | tr '\n\t"\\' "  ''" | head -c 300)
  if [[ -z "$_CRUD_TCLASS" || -z "$_CRUD_TACTION" ]]; then
    _CRUD_TCLASS="UNKNOWN"; _CRUD_TACTION="REROUTE_DEV"
    _CRUD_THINT="분류기 응답 없음 — 아래 판정기 출력으로 원인을 확인하라"
  fi
  return 0
}
_crud_triage_log() {  # $1=class $2=action $3=rc $4=recheck_rc — 자기(마커 경로) 세션 logs 에만 1줄
  [[ -n "${_CRUD_UUID:-}" ]] || return 0
  local _f="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${_CRUD_UUID}/logs/crud_triage.jsonl"
  mkdir -p -- "${_f%/*}" 2>/dev/null || return 0
  jq -cn --arg ts "$(date '+%Y-%m-%dT%H:%M:%S%z')" --arg path "${_CRUD_PATH:-}" --arg rc "$3" --arg class "$1" \
         --arg action "$2" --arg recheck_rc "$4" --arg tool "$TOOL_NAME" \
    '{ts:$ts,path:$path,rc:$rc,class:$class,action:$action,recheck_rc:$recheck_rc,tool:$tool}' >> "$_f" 2>/dev/null
  return 0
}
# 자동 승인 판정 — $1=판정기 출력. DECLARATION_CONFLICT 범위 확인 후 감사 로그(unblock3 2026-10-27, 종전 askq_approval.py 화면 승인 판독 대체).
#   통과면 0 + logs/crud_gate_override.log 1줄, 아니면 1 + _CRUD_ASKQ_NOTE 에 사유. 판정 실패·예외는 전부 1(fail-closed).
#   범위 확인(화이트리스트 — 같은 실행에 섞인 다른 CRUD AC 의 진짜 증거 누락을 승인이 넘기지 못하게 한다):
#     줄 머리 코드(대문자_ 토큰)가 아래 허용 집합 밖이면 승인을 보지 않고 차단한다(fail-closed — 모르는 코드도 차단).
#     실패 코드 허용 3종: CRUD_DECLARATION_OVERRIDDEN(필수) · CONTENT_OVERRIDE_FACT_BLOCKED ·
#       MISSING_CRUD_EVIDENCE 중 'crud_대상=false 선언이 AC 본문 요구 내용과 모순' 문구인 줄(그 밖의 사유면 차단).
#     정보 코드 허용(_CRUD_ASKQ_INFO): 판정에 쓰이지 않는 진행 표시줄뿐이다.
#     판단 근거로 쓴 실패 코드 줄은 crud_gate_override.log 6번째 칸에 남긴다.
_CRUD_ASKQ_INFO=" SELF_SCAN_EXCLUDED DB_SCAN_BASE DB_SCAN_FULL DB_SCAN_BASELINE DB_SCAN_BASELINE_IGNORED DB_SCAN_SKIP_PREEXISTING DB_NAME_MENTION_DOC_EXCLUDED DELETED_CONFIRMED CHANGED_FILES_DERIVED CRUD_PATH_SKIP_PREEXISTING CRUD_PATH_SUSPECT_CLEARED START_TIME_UNTRUSTED CRUD_GATE_CACHE ITEM_CRUD_FALSE_COVER_OFF ITEM_CRUD_FALSE_PATH_COVERED INSPECTION_KIND_PATH_COVERED INSPECTION_ONLY_EXEMPT DB_NAME_MENTION_CODE_EXCLUDED CONTENT_OVERRIDE_FACT_DETAIL "
#   [c196 oi-fix-2] ITEM_CRUD_FALSE_COVER_OFF = P2(item_crud:false 대칭 면제) 미적용 안내 줄. 판정은 뒤따르는
#   종전 CRUD_DECLARATION_OVERRIDDEN 줄이 그대로 지므로 정보 코드다(누락 시 첫 줄 break 로 승인 채널 전면 차단).
#   [c197 odev-5 AC-J3] ITEM_CRUD_FALSE_PATH_COVERED·INSPECTION_KIND_PATH_COVERED·INSPECTION_ONLY_EXEMPT 는
#   판정기(verify_crud_executed.py _derive_crud_items)가 항목을 "검사 대상에서 뺐다/다른 항목 증거로 검사한다" 고
#   알리는 분류 안내 줄이다. 덮는 쪽 item_crud:true 항목의 증거 부족은 별도 실패 줄로 나오므로 이 줄이 판정을
#   지지 않는다. 종전에는 허용 집합 밖이라 진짜 DECLARATION 충돌과 같이 나오면 첫 줄 break 로 승인 채널이 막혔다.
#   ⇒ 정보 코드로만 추가한다(판정 완화 없음): CRUD_DECLARATION_OVERRIDDEN 필수·미지 코드 차단·
#     MISSING_CRUD_EVIDENCE(허용 문구 외)·CRUD_ASSIGNMENT_UNVERIFIABLE 차단은 그대로다.
_crud_askq_ok() {
  local _out="$1" _sid _tr _res _ac _why _f _ln _code _decl="" _bad="" _basis=""
  _CRUD_ASKQ_NOTE=""
  [[ -n "${_CRUD_UUID:-}" ]] || { _CRUD_ASKQ_NOTE="세션 UUID 없음"; return 1; }
  while IFS= read -r _ln; do
    [[ "$_ln" =~ ^([A-Z][A-Z0-9_]{2,})(:|[[:space:]]|$) ]] || continue
    _code="${BASH_REMATCH[1]}"
    case "$_code" in
      CRUD_DECLARATION_OVERRIDDEN) _decl=1; _basis+="${_ln:0:160} | " ;;
      CONTENT_OVERRIDE_FACT_BLOCKED) _basis+="${_ln:0:160} | " ;;
      MISSING_CRUD_EVIDENCE)
        if [[ "$_ln" == *'crud_대상=false 선언이 AC 본문 요구 내용과 모순'* ]]; then _basis+="${_ln:0:160} | "; else _bad="$_ln"; break; fi ;;
      *) [[ "$_CRUD_ASKQ_INFO" == *" $_code "* ]] || { _bad="$_ln"; break; } ;;
    esac
  done <<<"$_out"
  if [[ -z "$_decl" || -n "$_bad" ]]; then
    _CRUD_ASKQ_NOTE="승인 범위 밖(허용 외 코드: ${_bad:0:100})"
    # [c196 oi-fix-2] 허용 외 코드가 있으면 그 줄을 우선 표시한다 — break 로 _decl 을 못 읽은 경우 '없음' 오진 방지(판정 불변).
    [[ -z "$_decl" && -z "$_bad" ]] && _CRUD_ASKQ_NOTE="승인 범위 밖(CRUD_DECLARATION_OVERRIDDEN 없음)"
    _CRUD_ASKQ_NOTE=$(printf '%s' "$_CRUD_ASKQ_NOTE" | tr '"\\\t' "'' "); return 1
  fi
  # [unblock3 odev-7] 사용자 지시 2026-10-27 15:53 — 화면 승인(askq_approval.py verify --consume) 판독을 없애고 자동 승인한다.
  #   범위 검사는 위에서 이미 통과했다. 감사 로그 2곳(세션 crud_gate_override.log 6칸 형식 유지 · 전역 auto_approval_audit.log)에
  #   1줄씩 남긴다. 5번째 칸(tool_use_id)은 화면 승인이 없으므로 'auto' 로 적는다.
  local _ts _sid _aud="${_CRUD_AUTO_AUDIT:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/logs/auto_approval_audit.log}"
  _ts=$(date '+%Y-%m-%dT%H:%M:%S%z')
  _sid=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
  _ac=$(printf '%s\n' "$_out" | grep -oE 'AC-[A-Za-z0-9_.-]+' | sort -u | paste -sd, -)
  _why="자동 승인(사용자 지시 2026-10-27 15:53 — 불필요한 승인요청 자동 승인)"
  _f="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${_CRUD_UUID}/logs/crud_gate_override.log"
  mkdir -p -- "${_f%/*}" 2>/dev/null
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$_ts" "DECLARATION_CONFLICT" "${_ac:--}" "$_why" "auto" \
    "근거: $(printf '%s' "${_basis% | }" | tr '\t\r' '  ' | head -c 600)" >> "$_f" 2>/dev/null
  mkdir -p -- "${_aud%/*}" 2>/dev/null
  printf '%s\t%s\t%s\t%s\t%s\n' "$_ts" "CRUD_GATE" "${_CRUD_PATH:-?} ${_ac:--} uuid=${_CRUD_UUID} sid=${_sid:--}" \
    "DECLARATION_CONFLICT 허용 코드 범위 안 — $_why" "${TOOL_NAME:-?}" >> "$_aud" 2>/dev/null
  return 0
}

_GP_K=""
case "$TOOL_NAME" in
  mcp__oio__file_write|mcp__oio__file_edit|Write|Edit|MultiEdit|NotebookEdit|mcp__oio__file_delete|\
  mcp__oio__file_copy|mcp__oio__file_move|mcp__oio__file_rename|mcp__oio__file_symlink|mcp__oio__dir_create) _GP_K="file" ;;
  mcp__oio__dir_delete|mcp__oio__dir_move|mcp__oio__dir_rename) _GP_K="dir" ;;
  Bash|mcp__oio__bash_exec) _GP_K="shell" ;;
esac

# ── F-GUARD-STUB S1~S5 (conv_179169722400 §2-5 + oplan_review C1~C5): 승격 대상 무결성 스텁 — 파일을 쓰지 않는 판정만 ──
# 평가 순서(C4): S2(c) → S1 → S2(a,b) → S3 → S4 → S5. S2 통과 = 이 GP 섹션(스텁+모듈 호출)만 건너뛴다(exit 0 금지 — 뒤 가드는 그대로).
#   S2(c) 파일 쓰기·수정 도구의 대상이 전부 hooks/write_guard.sh 자신 → GP 섹션 건너뜀(고장 모듈 탈출구, 현행과 같은 등급).
#   S1   지문 탐지(Q2·C3): 등록부에 gp_self 가 있을 때만(=부트 후) 돈다. 대상 목록은 fp 가 아니라 등록부에서 뽑는다.
#        각 live·test·등록부를 stat 1회(%F %.9Y %s %i)로 fp 와 비교한다. 다르면(또는 1/50 확률 전수) sha 를 핀과(등록부는 regsha 와) 대조.
#        부재·심볼릭 링크 = 이탈. 부트 흔적(fp·regsha)이 있는데 gp_self 가 없거나 등록부가 깨졌으면 registry 이탈.
#        부트 후 fp 부재 = 이탈(fp 삭제로 탐지가 꺼지지 않는다). 지연 실측(C5): drvfs 중앙값은 protect E3 로그에 남긴다(기준 ≤ 40ms).
#        잠금(C2): 지문 불일치가 있을 때만 잠금을 본다. 잠금만으로는 건너뛰지 않는다 — 설치는 저널 뒤에만 일어나므로 저널이 없으면
#        그대로 sha 대조. 저널이 있으면 잠금 실보유·보유 pid 생존·저널 360초·op promote|boot 가 모두 맞을 때만 관용하고,
#        관용 중에도 불일치 파일 sha 는 저널 old/new 와 직접 대조한다(S5 는 모듈 sha 를 핀과 직접 대조). 그 밖은 journal_stale 이탈.
#   S2(a) 셸 명령이 정확히 `bash <H>/lib/guard_promote.sh (restore <id>|status <id>|verify)` (H = ${HARNESS_HOME:-$HOME/.harness}/current/hooks 또는 realpath, 대소문자 무시)
#   S2(b) 정확히 `bash <H>/backup/guard_promote/store/<64hex> restore gp_self` + 그 파일 sha == 등록부 gp_self 핀 + 등록부 sha == regsha
#   S3   판정만(2026-10-27 unblock3 해제 — 사용자 결정 "자동 원복까지 해제"). 종전에는 S1 이탈이면 쓰기 계열(파일·디렉터리·셸)을
#        차단(HOOK_BLOCK_GP_DRIFT)했다. 지금은 막지 않는다. 이탈 점검은 guard_promote.sh verify, 복구는 S2(a) restore. hook 은 원복하지 않는다.
#   S4   셸 명령이 부트를 실행하는 형태(해석기·직접 실행, 글로브 포함 — 조회는 비대상)이면 정확히 `bash ${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/guard_promote_boot.sh run` + 고정 경로 부트(링크 아님)의
#        sha == _GP_BOOT_SHA(빈 값 = 항상 차단) + gp_self 미등록일 때만 통과. 통과 시 logs/guard_promote_boot.audit 에
#        `GATE\t<epoch>\t<nonce32hex>\t<session_id>\t<boot_sha>` 1줄(hook 의 유일한 쓰기) — 부트는 60초 안의 미소비 nonce 를 요구·소비한다(C1).
#   S5   등록부에 gp_gate 가 있으면 lib/gp_gate.sh 를 source 해 gp_gate_check(0 통과/2 차단/그 밖 = 모듈 오류 → 통과).
#        승격 경로 구성요소 보호(옛 인라인 F-GUARD-PROMOTE)는 conv_179169722400 Batch2 부트 후 gp_gate 모듈로 옮겼다.
#        2026-10-27 unblock3 해제: 모듈 오류·gp_gate 미등록(부트 흔적 있음)·승격 중 모듈 sha≠핀 의 fail-closed 3건은 차단하지 않고 통과한다.
# 잔존 한계: 같은 uid 가 등록부·보관소·fp·regsha 를 일관되게 위조하면 탐지되지 않는다. 스텁을 정규 편집으로 지우면 꺼진다(diff·otest 감사).
_GP_BOOT_SHA="8ccedbb5cf04c22ff08eb78ac5adc1eb42d49f8828bbcaa63f0804d5389c813b"   # Batch2 봉인 상수(봉인 후 부트 sha) — 빈 값이면 부트는 항상 차단
if [[ -n "$_GP_K" ]]; then
  _GP_TI="${_CRUD_TI:-$(echo "$INPUT" | jq -c '.tool_input // {}' 2>/dev/null || echo "")}"
  _GPS_T0=$EPOCHREALTIME
  _GPS_H="${HARNESS_HOME:-$HOME/.harness}/current/hooks"; _GPS_REG="$_GPS_H/lib/guard_promote.json"; _GPS_LOG="$_GPS_H/logs"
  _GPS_HR=""; _GPS_SKIP=0; _GPS_DRIFT=""; _GPS_BOOTED=0; _GPS_HASGATE=0; _GPS_LOCKED=0; _GPS_JRNL=0; _GPS_REGOK=0
  _GPS_ROWS=""; _GPS_GATEPIN=""; _GPS_SELFPIN=""
  _gps_hr() { [[ -n "$_GPS_HR" ]] || _GPS_HR=$(realpath -m -- "$_GPS_H" 2>/dev/null); return 0; }
  _gps_sha() { local _s; _s=$(sha256sum -- "$1" 2>/dev/null) || return 1; printf '%s' "${_s:0:64}"; }
  _gps_drift() { [[ " $_GPS_DRIFT " == *" $1 "* ]] || _GPS_DRIFT="${_GPS_DRIFT:+$_GPS_DRIFT }$1"; return 0; }
  # S2(c) — 대상이 write_guard.sh 자신
  case "$TOOL_NAME" in
    mcp__oio__file_write|mcp__oio__file_edit|Write|Edit|MultiEdit)
      if [[ "${_GP_TI,,}" == *write_guard.sh* ]]; then
        _gps_l=$(jq -r '[.path,.file_path,.filepath] | map(select(type=="string" and . != ""))[]' <<<"$_GP_TI" 2>/dev/null)
        if [[ -n "$_gps_l" ]]; then
          _gps_hr; _GPS_SKIP=1
          while IFS= read -r _gps_p; do
            _gps_r=$(realpath -m -- "$_gps_p" 2>/dev/null)
            [[ -n "$_GPS_HR" && "${_gps_r,,}" == "${_GPS_HR,,}/write_guard.sh" ]] || { _GPS_SKIP=0; break; }
          done <<<"$_gps_l"
        fi
      fi ;;
  esac
  # 등록부 핀 줄 파서(fork 없음) — 승격기가 jq 로 쓰는 고정 형식(2칸 들여쓰기, 한 줄 한 키)만 받는다.
  #   형식이 하나라도 다르면(공백·압축·이스케이프·중첩·대상 중복·모르는 최상위 키) 1 을 돌려 jq 로 되돌아간다.
  #   결과는 jq 판과 같은 _GPS_ROWS(첫 줄 S/G 표식, 이어서 "id\t상대경로\t핀" 줄)이다. 무결성은 지금처럼 regsha·sha 대조가 맡는다.
  _gps_rows_parse() {  # $1=등록부 본문
    local _ln _st=0 _id="" _k _v _s="-" _g="-" _rows=""
    local -A _lv=() _ts=() _cs=() _tt=() _seen=()
    local -a _order=()
    while IFS= read -r _ln; do
      case $_st in
        0) [[ "$_ln" == "{" ]] || return 1; _st=1 ;;
        1) if [[ "$_ln" =~ ^\ \ \"_comment\":\ \"[^\"\\]*\",?$ ]]; then :
           elif [[ "$_ln" == '  "targets": {' ]]; then _st=2
           else return 1; fi ;;
        2) if [[ "$_ln" =~ ^\ \ \ \ \"([A-Za-z0-9_]+)\":\ \{$ ]]; then
             _id="${BASH_REMATCH[1]}"; [[ -z "${_seen[$_id]:-}" ]] || return 1; _seen[$_id]=1; _order+=("$_id"); _st=3
           elif [[ "$_ln" =~ ^\ \ \},?$ ]]; then _st=4
           else return 1; fi ;;
        3) if [[ "$_ln" =~ ^\ \ \ \ \ \ \"([a-z_0-9]+)\":\ \"([^\"\\]*)\",?$ ]]; then
             _k="${BASH_REMATCH[1]}"; _v="${BASH_REMATCH[2]}"
             case "$_k" in live) _lv[$_id]="$_v" ;; test) _tt[$_id]="$_v" ;; core_sha256) _cs[$_id]="$_v" ;; test_sha256) _ts[$_id]="$_v" ;; esac
           elif [[ "$_ln" =~ ^\ \ \ \ \ \ \"[a-z_0-9]+\":\ -?[0-9]+,?$ ]]; then :
           elif [[ "$_ln" =~ ^\ \ \ \ \},?$ ]]; then _st=2
           else return 1; fi ;;
        4) if [[ "$_ln" =~ ^\ \ \"_comment\":\ \"[^\"\\]*\",?$ ]]; then :
           elif [[ "$_ln" == "}" ]]; then _st=5
           else return 1; fi ;;
        5) [[ -z "$_ln" ]] || return 1 ;;
      esac
    done <<<"$1"
    [[ $_st -eq 5 ]] || return 1
    for _id in "${_order[@]}"; do
      [[ "$_id" == gp_self ]] && _s=S; [[ "$_id" == gp_gate ]] && _g=G
      _rows+=$'\n'"$_id"$'\t'"${_lv[$_id]:-}"$'\t'"${_cs[$_id]:-}"$'\n'"$_id"$'\t'"${_tt[$_id]:-}"$'\t'"${_ts[$_id]:-}"
    done
    _GPS_ROWS="$_s$_g$_rows"
    return 0
  }
  # S1 — 지문 탐지(읽기 전용)
  _gps_s1() {
    local _reg="" _fl _id _rel _pin _f _t _m _s _i _st _want _rs _age _fd _k _full=0 _jbad=0
    local -A _fp=() _stt=()
    local -a _paths=() _ids=() _pins=() _rels=() _mis=()
    # 트리 기준: 등록부(또는 lib 디렉터리)가 심볼릭 링크이고 그 실제 위치가 '지금 실행 중인 이 write_guard.sh 의 트리'일 때만
    #   (시험 하네스가 실 lib 를 임시 HOME 에 연결한 경우) 그 트리의 logs·대상을 본다 — 등록부·지문·핀이 한 트리에서 일관되게 대조된다.
    #   다른 트리(가짜 fp·logs 를 갖춘 임시 트리)로 향하는 링크는 따라가지 않는다 → 링크로 S1 을 가짜 트리에서 돌리는 우회 불가.
    #   실 HOME 은 등록부·lib 가 링크가 아니라 이 분기에 들어오지 않는다(hooks 자체 링크는 -L 판정 대상이 아님 — 동작 불변, fork 없음).
    local _GPS_H="$_GPS_H" _GPS_LOG="$_GPS_LOG" _rr _rs0
    if [[ -L "$_GPS_REG" || -L "$_GPS_H/lib" ]]; then
      _rr=$(realpath -e -- "$_GPS_REG" 2>/dev/null); _rs0=$(realpath -e -- "${BASH_SOURCE[0]}" 2>/dev/null)
      if [[ -n "$_rr" && -n "$_rs0" && "$_rr" == "${_rs0%/*}/lib/guard_promote.json" ]]; then _GPS_H="${_rs0%/*}"; _GPS_LOG="$_GPS_H/logs"; fi
    fi
    # 등록부는 fork 없이 1회 읽는다(read -d '' 는 EOF 에서 1 을 돌려주므로 결과는 버린다 — 부재면 빈 값)
    { IFS= read -r -d '' _reg <"$_GPS_REG"; } 2>/dev/null
    if [[ "$_reg" == *'"gp_self"'* ]]; then
      _gps_rows_parse "$_reg" || \
      _GPS_ROWS=$(jq -r '.targets | (if has("gp_self") then "S" else "-" end) + (if has("gp_gate") then "G" else "-" end),
        (to_entries[] | .key as $k | .value | ($k + "\t" + (.live // "") + "\t" + (.core_sha256 // "")), ($k + "\t" + (.test // "") + "\t" + (.test_sha256 // "")))' <<<"$_reg" 2>/dev/null)
      _fl="${_GPS_ROWS%%$'\n'*}"
      [[ "$_fl" == S* ]] && _GPS_BOOTED=1
      [[ "$_fl" == ?G ]] && _GPS_HASGATE=1
      [[ "$_fl" == [S-][G-] ]] || { _gps_drift registry; return 0; }  # gp_self 문자열은 있는데 등록부가 깨짐
    fi
    if [[ $_GPS_BOOTED -eq 0 ]]; then  # 부트 전 — 부트 흔적이 있으면 등록부 이탈(C3)
      [[ -e "$_GPS_LOG/guard_promote.fp" || -e "$_GPS_LOG/guard_promote.regsha" ]] && _gps_drift registry
      return 0
    fi
    _GPS_ROWS="${_GPS_ROWS#*$'\n'}"
    while IFS=$'\t' read -r _id _rel _pin; do
      [[ -n "$_id" ]] || continue
      if [[ -z "$_rel" || ${#_pin} -ne 64 || "$_rel" == /* || "$_rel" == *..* ]]; then _gps_drift "$_id"; continue; fi
      _ids+=("$_id"); _rels+=("$_rel"); _pins+=("$_pin"); _paths+=("$_GPS_H/$_rel")
      [[ "$_id" == gp_gate && "$_rel" == lib/* ]] && _GPS_GATEPIN="$_pin"
      [[ "$_id" == gp_self && "$_rel" == lib/* ]] && _GPS_SELFPIN="$_pin"
    done <<<"$_GPS_ROWS"
    [[ ${#_paths[@]} -gt 0 ]] || { _gps_drift registry; return 0; }
    # 등록부 자신도 같은 1차 필터에 넣는다(핀 = regsha, 불일치 시에만 대조)
    # 등록부 stat 대상: 링크 호환으로 트리가 확정되면 그 트리의 실파일, 아니면 원래 경로(링크면 비정규 파일 = 이탈)
    local _regp="$_GPS_REG"; [[ -n "${_rs0:-}" && "$_GPS_H" == "${_rs0%/*}" ]] && _regp="$_GPS_H/lib/guard_promote.json"
    _ids+=(registry); _rels+=(lib/guard_promote.json); _pins+=(REGSHA); _paths+=("$_regp")
    # fp(1차 필터) — 부트 후 부재 = 이탈(C3: fp 삭제로 탐지가 꺼지지 않는다)
    if [[ -r "$_GPS_LOG/guard_promote.fp" ]]; then
      while IFS=$'\t' read -r _rel _m _s _i; do [[ -n "$_rel" ]] && _fp["$_rel"]="$_m $_s $_i"; done <"$_GPS_LOG/guard_promote.fp"
    else
      _gps_drift fp_missing; _full=1
    fi
    # stat 1회(링크는 따라가지 않는다 — %F 로 종류 판정)
    while IFS=$'\t' read -r _f _t _m _s _i; do [[ -n "$_f" ]] && _stt["$_f"]="$_t"$'\t'"$_m $_s $_i"; done < <(stat -c $'%n\t%F\t%.9Y\t%s\t%i' -- "${_paths[@]}" 2>/dev/null)
    (( RANDOM % 50 == 0 )) && _full=1   # 저비용 심층 검사 — 1/50 확률로 sha 전수 대조
    for _k in "${!_paths[@]}"; do
      _st="${_stt[${_paths[$_k]}]:-}"
      if [[ "${_st%%$'\t'*}" != "regular file" && "${_st%%$'\t'*}" != "regular empty file" ]]; then _gps_drift "${_ids[$_k]}"; continue; fi  # 부재·링크·디렉터리
      _st="${_st#*$'\t'}"; _want="${_fp[${_rels[$_k]}]:-}"
      [[ -n "$_want" && "${_want%% *}" != *.* ]] && _st="${_st%%.*} ${_st#* }"   # fp 가 정수 mtime 이면 정수부만
      [[ $_full -eq 1 || "$_st" != "$_want" ]] && _mis+=("$_k")
    done
    [[ ${#_mis[@]} -gt 0 ]] || return 0   # 빠른 경로: 전부 지문 일치
    # 느린 경로 — 잠금(C2): 공유 잠금을 잠깐 시도해 승격기(배타 잠금) 점유 여부를 본다. 건너뛰기는 저널이 있을 때만.
    # ★exec 에 2>/dev/null 을 직접 붙이면 hook 전체의 stderr 가 닫힌다 — 묶음 리다이렉트로 한정한다★
    if [[ -e "$_GPS_LOG/guard_promote.lock" ]] && { exec {_fd}<"$_GPS_LOG/guard_promote.lock"; } 2>/dev/null; then
      flock -n -s "$_fd" 2>/dev/null || _GPS_LOCKED=1
      exec {_fd}<&-
    fi
    _rs=""; [[ -r "$_GPS_LOG/guard_promote.regsha" ]] && read -r -n 64 _rs <"$_GPS_LOG/guard_promote.regsha" 2>/dev/null
    if [[ -e "$_GPS_LOG/guard_promote.journal" ]]; then
      # 승격·부트 진행 중 관용 — 세 조건이 모두 맞을 때만(관용이 '탐지 끄기' 통로가 되지 않게):
      #   ① 잠금 실보유(flock) + 잠금 파일에 적힌 보유 pid 가 살아 있음(/proc/<pid>, 내장 확인)
      #      — mtime heartbeat 는 승격기가 시험 대기 중에만 touch 해 설치~커밋 구간(실측 약 40초)에 정상 승격을 오차단했다(2026-10-11 promote gp_gate)
      #   ② 저널 360초 이내 + op ∈ {promote, boot} — 멈춘 프로세스(pid 생존·잠금 유지)는 이 상한이 막는다
      #   ③ 불일치 파일 sha ∈ 저널 {old,new}(저널에 없는 파일은 핀), 등록부 sha ∈ {reg_old, reg_new, regsha}
      # 잠금 없는 저널(강제 종료 직후 — 커널이 잠금을 푼다)·보유 pid 소멸·조건 불충족은 관용하지 않는다 → journal_stale(안내는 restore registry).
      local _now="${EPOCHREALTIME%.*}" _lpid="" _jt _jrow _jop="" _jro="" _jrn="" _jr _jo _jn _cur
      local -A _jf=()
      { read -r _lpid _ <"$_GPS_LOG/guard_promote.lock"; } 2>/dev/null
      _jt=$(( _now - $(stat -c %Y -- "$_GPS_LOG/guard_promote.journal" 2>/dev/null || echo 0) ))
      if [[ $_GPS_LOCKED -eq 1 && "$_lpid" =~ ^[0-9]+$ && -d "/proc/$_lpid" ]] && (( _jt <= 360 )); then
        while IFS=$'\t' read -r _jr _jo _jn; do
          if [[ -z "$_jop" ]]; then _jop="$_jr"; _jro="$_jo"; _jrn="$_jn"; continue; fi
          [[ -n "$_jr" ]] && _jf["$_jr"]="$_jo $_jn"
        done < <(jq -r '(.op // "") + "\t" + (.reg_old // "") + "\t" + (.reg_new // ""), (.files // [] | .[] | (.rel // "") + "\t" + (.old // "") + "\t" + (.new // ""))' "$_GPS_LOG/guard_promote.journal" 2>/dev/null)
      fi
      if [[ "$_jop" == promote || "$_jop" == boot ]]; then
        _GPS_JRNL=1
        _GPS_DRIFT=" $_GPS_DRIFT "; _GPS_DRIFT="${_GPS_DRIFT// fp_missing / }"; _GPS_DRIFT="${_GPS_DRIFT# }"; _GPS_DRIFT="${_GPS_DRIFT% }"; [[ "$_GPS_DRIFT" == " " ]] && _GPS_DRIFT=""
        for _k in "${_mis[@]}"; do
          _cur=$(_gps_sha "${_paths[$_k]}")
          if [[ "${_pins[$_k]}" == REGSHA ]]; then
            [[ ${#_cur} -eq 64 && ( "$_cur" == "$_jro" || "$_cur" == "$_jrn" || "$_cur" == "$_rs" ) ]] || _gps_drift registry
          elif [[ -n "${_jf[${_rels[$_k]}]+x}" ]]; then
            _jo="${_jf[${_rels[$_k]}]% *}"; _jn="${_jf[${_rels[$_k]}]#* }"
            [[ ${#_cur} -eq 64 && ( ( -n "$_jo" && "$_cur" == "$_jo" ) || ( -n "$_jn" && "$_cur" == "$_jn" ) ) ]] || _gps_drift "${_ids[$_k]}"
          else
            [[ "$_cur" == "${_pins[$_k]}" ]] || _gps_drift "${_ids[$_k]}"
          fi
        done
        return 0
      fi
      _jbad=1   # 관용 불가 저널 — 아래 sha 대조를 그대로 하고, 실제 이탈이 있을 때만 journal_stale 을 붙인다
    fi
    for _k in "${_mis[@]}"; do
      _pin="${_pins[$_k]}"; [[ "$_pin" == REGSHA ]] && _pin="$_rs"
      [[ ${#_pin} -eq 64 && "$(_gps_sha "${_paths[$_k]}")" == "$_pin" ]] || _gps_drift "${_ids[$_k]}"
    done
    # 주기 전수 대조(1/50)·inode 만 바뀐 정상 파일은 sha 가 맞으면 이탈이 아니다 — 오래된 저널만으로 차단하지 않는다
    [[ ${_jbad:-0} -eq 1 && -n "$_GPS_DRIFT" ]] && _gps_drift journal_stale
    return 0
  }
  if [[ $_GPS_SKIP -eq 0 ]]; then
    _gps_s1
    # S2(a,b) — 탈출구 명령 정확 일치
    if [[ "$_GP_K" == "shell" ]]; then
      if [[ "$_WG_PRE" == 1 && -n "$_GP_TI" ]]; then _gps_cmd="$_WG_STRCMD"   # c205 D-9 — _GP_TI 는 같은 INPUT 의 tool_input
      else _gps_cmd=$(jq -r '[.command,.cmd] | map(select(type=="string"))[0] // empty' <<<"$_GP_TI" 2>/dev/null || echo ""); fi
      if [[ "$_gps_cmd" != *$'\n'* && "$_gps_cmd" != *$'\r'* && "${_gps_cmd,,}" == *guard_promote* ]]; then
        read -r -a _gps_w <<<"$_gps_cmd"
        _gps_hr
        if [[ ${#_gps_w[@]} -ge 3 && "${_gps_w[0]}" == "bash" ]]; then
          _gps_w1="${_gps_w[1],,}"
          for _gps_hb in "${_GPS_H,,}" "${_GPS_HR,,}"; do
            [[ -n "$_gps_hb" ]] || continue
            if [[ "$_gps_w1" == "$_gps_hb/lib/guard_promote.sh" ]]; then
              if [[ ( ${#_gps_w[@]} -eq 3 && "${_gps_w[2]}" == "verify" ) || \
                    ( ${#_gps_w[@]} -eq 4 && "${_gps_w[2]}" =~ ^(restore|status)$ && "${_gps_w[3]}" =~ ^[a-z0-9_]+$ ) ]]; then
                _GPS_SKIP=2; break
              fi
            elif [[ "$_gps_w1" =~ ^"$_gps_hb"/backup/guard_promote/store/[0-9a-f]{64}$ && ${#_gps_w[@]} -eq 4 \
                    && "${_gps_w[2]}" == "restore" && "${_gps_w[3]}" == "gp_self" ]]; then
              _gps_rs=""; [[ -r "$_GPS_LOG/guard_promote.regsha" ]] && read -r -n 64 _gps_rs <"$_GPS_LOG/guard_promote.regsha" 2>/dev/null
              [[ ${#_gps_rs} -eq 64 && "$(_gps_sha "$_GPS_REG")" == "$_gps_rs" ]] && _GPS_REGOK=1
              if [[ $_GPS_BOOTED -eq 1 && $_GPS_REGOK -eq 1 && -n "$_GPS_SELFPIN" && ! -L "${_gps_w[1]}" \
                    && "$(_gps_sha "${_gps_w[1]}")" == "$_GPS_SELFPIN" ]]; then
                _GPS_SKIP=2; break
              fi
            fi
          done
        fi
      fi
    fi
  fi
  [[ -n "${WG_GPS_TIMING:-}" ]] && echo "GPS_S1_US=$(( (${EPOCHREALTIME/./} - ${_GPS_T0/./}) )) booted=$_GPS_BOOTED skip=$_GPS_SKIP drift=[$_GPS_DRIFT]" >&2
  if [[ $_GPS_SKIP -eq 0 ]]; then
    _gps_block() {  # $1=코드 $2=태그 $3=사유(JSON 안전)
      source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/write_error.sh" 2>/dev/null || true
      # declare -F: 함수만 본다. type 은 미정의 시 PATH(drvfs 다수)를 뒤져 1회 수백 ms~수 초 늘어진다(GG-F34 진단)
      declare -F log_hook_error >/dev/null 2>&1 && \
        log_hook_error "$1" "$TOOL_NAME" "$3" "$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null)"
      echo "{\"decision\":\"block\",\"reason\":\"🚫 [$2] $3\"}"
      exit 2
    }
    # S3 — [unblock3] 사용자 결정 2026-10-27 "자동 원복까지 해제"(사용자 지시 13:04 "남은 예외 세 가지도 막지 말고 다 풀어라").
    #   이탈(_GPS_DRIFT)은 S1 이 탐지만 하고 막지 않는다(종전: 쓰기 계열 전면 차단 HOOK_BLOCK_GP_DRIFT = 링크 우회 시 셸 fail-closed).
    #   S1 은 그대로 돌아 S5 저널 판정·WG_GPS_TIMING 진단을 유지한다. 이탈 점검: bash ${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/guard_promote.sh verify,
    #   핀 본 복구: … restore <id>. hook 은 예전에도 지금도 파일을 원복하지 않는다.
    # S4 — 부트 게이트. 판정 대상은 부트를 '실행하는 형태'만이다(조회 sha256sum·grep·cat·stat·bash -n 등은 통과).
    #   실행 형태 = 구간(; | & 개행으로 나눔, $( ` ) 는 같은 구간으로 펼침)의 첫 명령(앞의 VAR=값·sudo/nohup/setsid/env/exec/command/time/nice/timeout/xargs 건너뜀)이
    #   셸 해석기(bash|sh|dash|zsh|ksh|source|.)이고 -n(문법 검사)이 아니며 그 구간에 guard_promote_b 가 있거나, 첫 명령 자체가 guard_promote_b 경로.
    #   놓친 간접 실행은 nonce 를 받지 못하므로 부트가 no_gate_nonce 로 거부한다(C1 — 실질 방어는 nonce·고정 경로·별칭 거부).
    _gps_bootexec() {  # $1=명령 → 실행 형태면 0
      local _c="$1" _seg _w _i _n _hit _o _w0 _w0b
      _c="${_c//\$(/ }"; _c="${_c//\`/ }"; _c="${_c//)/ }"; _c="${_c//;/$'\n'}"; _c="${_c//|/$'\n'}"; _c="${_c//&/$'\n'}"; _c="${_c//(/ }"; _c="${_c//\{/ }"
      while IFS= read -r _seg; do
        [[ "${_seg,,}" == *guard_promote_b* ]] || continue
        read -r -a _w <<<"$_seg"; _n=${#_w[@]}; _i=0
        while (( _i < _n )); do
          case "${_w[$_i],,}" in
            *=*) [[ "${_w[$_i]}" == -* ]] && break; _i=$((_i+1)) ;;
            sudo|nohup|setsid|env|exec|command|time|nice|xargs|stdbuf|builtin|do|then|else|elif|if|while|until|!) _i=$((_i+1)) ;;
            timeout) _i=$((_i+1)); while (( _i < _n )) && [[ "${_w[$_i]}" == -* || "${_w[$_i]}" =~ ^[0-9.]+[smhd]?$ ]]; do _i=$((_i+1)); done ;;
            -*) _i=$((_i+1)) ;;
            *) break ;;
          esac
        done
        (( _i < _n )) || continue
        _w0="${_w[$_i],,}"; _w0="${_w0//\'/}"; _w0="${_w0//\"/}"; _w0b="${_w0##*/}"
        [[ "$_w0" == *guard_promote_b* ]] && return 0
        case "$_w0b" in
          bash|sh|dash|zsh|ksh|source|.)
            _hit=1
            for (( _i=_i+1; _i<_n; _i++ )); do
              _o="${_w[$_i]}"
              [[ "$_o" == -* ]] || break
              if [[ "$_o" =~ ^-[a-z]*c[a-z]*$ ]]; then   # bash -c '…' = 안쪽 문자열을 다시 판정
                _o="${_w[*]:$((_i+1))}"; _o="${_o//\'/}"; _o="${_o//\"/}"
                _gps_bootexec "$_o" && return 0
                _hit=0; break
              fi
              [[ "$_o" =~ ^-[a-z]*n[a-z]*$ ]] && _hit=0   # bash -n = 문법 검사(실행 아님)
            done
            [[ $_hit -eq 1 ]] && return 0 ;;
        esac
      done <<<"$_c"
      return 1
    }
    _gps_cmd=""
    [[ "$_GP_K" == "shell" && "${_GP_TI,,}" == *guard_promote_b* ]] && \
      _gps_cmd=$(jq -r '[.command,.cmd] | map(select(type=="string"))[0] // empty' <<<"$_GP_TI" 2>/dev/null || echo "")
    if [[ -n "$_gps_cmd" ]] && _gps_bootexec "$_gps_cmd"; then
      _gps_ok=0; _gps_why="명령 형태 불일치(정확히 bash \${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/guard_promote_boot.sh run 만 허용)"
      if [[ "$_gps_cmd" != *$'\n'* && "$_gps_cmd" != *$'\r'* ]]; then
        read -r -a _gps_w <<<"$_gps_cmd"
        # 부트는 \$0 문자열이 정확히 \$HOME 형태가 아니면 alias_invocation 으로 거부하므로 \$HOME 형태 하나만 허용한다(대소문자 구분)
        if [[ ${#_gps_w[@]} -eq 3 && "${_gps_w[0]}" == "bash" && "${_gps_w[2]}" == "run" && "${_gps_w[1]}" == "$_GPS_H/lib/guard_promote_boot.sh" ]]; then
          _gps_bf="$_GPS_H/lib/guard_promote_boot.sh"
          if [[ -z "$_GP_BOOT_SHA" ]]; then _gps_why="부트 봉인 상수 미기입(_GP_BOOT_SHA 빈 값)"
          elif [[ -L "$_gps_bf" || ! -f "$_gps_bf" ]]; then _gps_why="고정 경로 부트가 일반 파일이 아님"
          elif [[ "$(_gps_sha "$_gps_bf")" != "$_GP_BOOT_SHA" ]]; then _gps_why="부트 sha 가 봉인과 다름"
          elif [[ $_GPS_BOOTED -eq 1 ]]; then _gps_why="이미 부트됨(등록부에 gp_self 있음)"
          else
            _gps_n=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
            _gps_sid=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null); _gps_sid="${_gps_sid//[^A-Za-z0-9_-]/_}"
            if [[ ${#_gps_n} -eq 32 ]] && printf 'GATE\t%s\t%s\t%s\t%s\n' "${EPOCHREALTIME%.*}" "$_gps_n" "$_gps_sid" "$_GP_BOOT_SHA" >> "$_GPS_LOG/guard_promote_boot.audit" 2>/dev/null; then
              _gps_ok=1
            else
              _gps_why="감사 기록 실패"
            fi
          fi
        fi
      fi
      [[ $_gps_ok -eq 1 ]] || _gps_block "HOOK_BLOCK_GP_BOOT" "F-GUARD-PROMOTE-BOOT" "부트 게이트 차단 — ${_gps_why}. 부트는 공식 1회 경로(bash ${_GPS_H}/lib/guard_promote_boot.sh run)로만, 봉인 일치·gp_self 미등록일 때만 실행된다."
    fi
    # S5 — 모듈 호출 / 부트 전 인라인
    if [[ $_GPS_HASGATE -eq 1 ]]; then
      _gps_mod="$_GPS_H/lib/gp_gate.sh"
      # [unblock3] 사용자 결정 2026-10-27 "자동 원복까지 해제" — 승격 진행 중 모듈 sha≠핀 차단(종전 HOOK_BLOCK_GP_DRIFT)을 풀었다.
      #   핀 대조 없이 현재 모듈을 그대로 source 한다(점검은 guard_promote.sh verify).
      source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/write_error.sh" 2>/dev/null || true
      if source "$_gps_mod" 2>/dev/null && declare -F gp_gate_check >/dev/null 2>&1; then
        gp_gate_check; _gps_rc=$?
      else
        _gps_rc=99
      fi
      # [사이클182 항목1 — L-604] 차단 표식 + 차단 직후 작성 스크립트 본문 재판정(lib/script_recheck.sh, 계약 계획 §2-1).
      #   lib 부재·함수 미정의면 표식·재판정 없이 종전 동작(재판정은 2차 방어층 — 1차는 S1 지문 탐지).
      #   비용: 차단 때와 "자기 sid 표식 파일이 있을 때"만 lib 를 적재한다(평소 셸 호출은 fork 0 — 표식 경로는 lib _sr_dir 와 같다).
      if [[ $_gps_rc -eq 2 ]]; then
        source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/script_recheck.sh" 2>/dev/null || true
        declare -F sr_mark_block >/dev/null 2>&1 && \
          sr_mark_block "F-GUARD-PROMOTE" "$(jq -r '.session_id // empty' <<<"$INPUT" 2>/dev/null)" >/dev/null 2>&1
        exit 2
      fi
      # [unblock3] 사용자 결정 2026-10-27 "자동 원복까지 해제" — 모듈 오류(rc∉{0,2}) fail-closed 를 풀었다. 통과(fail-open)하고 뒤 가드는 그대로 돈다.
      _gps_wsid=""
      [[ "$INPUT" =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]] && _gps_wsid="${BASH_REMATCH[1]}"
      if [[ "$_GP_K" == "shell" && -n "$_gps_wsid" && -f "${SR_MARK_DIR:-${HARNESS_HOME:-$HOME/.harness}/current/hooks/logs/recent_block}/${_gps_wsid//[^A-Za-z0-9_-]/_}" ]]; then
        source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/script_recheck.sh" 2>/dev/null || true
      fi
      if [[ "$_GP_K" == "shell" && -n "$_gps_wsid" ]] && declare -F sr_recheck >/dev/null 2>&1; then
        _gps_scmd=$(jq -r '[.command,.cmd] | map(select(type=="string"))[0] // empty' <<<"$_GP_TI" 2>/dev/null)
        _gps_scwd=$(jq -r '[.cwd,.working_dir,.workdir] | map(select(type=="string" and . != ""))[0] // empty' <<<"$_GP_TI" 2>/dev/null)
        [[ -n "$_gps_scwd" ]] || _gps_scwd="$PWD"
        sr_recheck "$_gps_scmd" "$_gps_wsid" "$_gps_scwd"; [[ $? -eq 2 ]] && exit 2
      fi
    fi
    # [unblock3] 사용자 결정 2026-10-27 "자동 원복까지 해제" — gp_gate 미등록 + 부트 흔적(gp_self 등록 또는 fp) fail-closed 를 풀었다.
    #   판정 모듈이 없으면 보호 판정 없이 통과한다(점검: guard_promote.sh verify, 복구: restore registry).
  fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# [F-WG-SELF 사이클182 재발방지] hook 파일(write_guard.sh 자신 + hooks/·hooks/lib/ 의 .sh·.py)을 바꾸는 쓰기는
#   ★적용 결과를 먼저 문법 검사★ 한다(.sh = bash -n, .py = compile). 실패하면 차단.
# 배경(실사고 2026-10-12 01:0x): live write_guard 의 구조 변경(while…done)을 file_edit 2회로 나눠 넣다가 1회차 뒤
#   구문 오류 판이 live 에 노출됐다. bash 구문 오류는 rc=2 로 끝나 closed·open 래퍼와 time_budget 을 거치지 않는
#   hook 까지 전부 "차단"으로 해석된다(odev-12 실측). 그래서 깨진 hook 1개가 ★자기를 고치는 편집까지★ 막아
#   전 세션이 교착됐고 사용자 셸로만 복구됐다.
# 범위 결정(사이클182, 실측 근거): write_guard 하나가 아니라 실제 hook 트리 전체(.sh·.py)로 넓혔다.
#   비용은 입력 문자열 사전 필터(hooks/…sh|py) 미적중이면 0, 적중해도 python 1회 + bash -n 1회로 낮다
#   (실측 2026-10-12 load 14, write_guard 1회 중앙값 n=8: 일반 쓰기 321ms·이전 판 468ms / hook lib 편집 487ms·이전 판 601ms
#    — 차이가 잡음 범위 안). 또 lib/*.sh 하나가 깨져도 그 lib 를 source 하는 hook 이 같은 방식으로 교착할 수 있기 때문이다.
#   2층(odev-12 time_budget LKG 대체 실행)은 이미 깨진 판이 반영된 뒤의 복구, 이 1층은 반영 자체를 막는다.
# 대상 판정: realpath 가 hook 루트(실 ${HARNESS_HOME:-$HOME/.harness}/current/hooks · 이 파일이 있는 디렉터리 · 프로젝트 .claude/hooks ·
#   WGS_EXTRA_ROOT(시험용, hook 실행 환경에서만 설정 가능)) 아래의 .sh/.py 이고 tests/·candidates/·backup/·logs/·
#   __pycache__/ 밖이거나, 경로가 */.claude/hooks/write_guard.sh 이면 대상이다.
#   적용 후 내용: file_write=내용, file_edit/Edit=old→new 모사(replace_all 포함), MultiEdit=순차 모사,
#   copy/move/rename=원본 파일. 셸: cp/mv/install 로 대상 덮기 → 원본 검사, sed -i·perl -i·리다이렉트·tee·truncate·dd
#   → 결과 검사 불가로 차단. 단 CR 제거 sed -i 's/\r$//' 꼴(hook 작성 규칙의 필수 단계)은 문법을 깨지 않으므로 통과.
# 위치: F-GUARD-STUB 구간(S1~S5 승격 판정) 뒤 — 보호 파일 판정(F-GUARD-PROMOTE)과 그 차단 표식(sr_mark_block)이 먼저 돌게 한다
#   (앞에 두면 보호 시험 4건이 다른 태그로 가로채졌다 — R1 실측). write_guard.sh 자신은 S2(c) 로 그 구간을 건너뛰므로 여기서 검사된다.
# 성격: 안전망 — 판정기(python3) 부재·파싱 실패는 통과(fail-open, 이 블록이 hook 을 멈추게 하지 않는다).
# 잔존 한계: 변수 경로·간접 실행(bash -c "$(…)")·다른 이름으로 쓴 뒤 링크로 바꾸는 경로, 문법은 맞지만 동작이
#   깨진 변경(예: exit 2 무조건)은 잡지 못한다.
# ═════════════════════════════════════════════════════════════════════════════
# 사전 필터(fork 0): hooks/ 또는 hooks/lib/ 바로 아래 .sh·.py 이름이 입력에 있을 때만 — hooks/tests/·candidates/ 등
#   하위 디렉터리 쓰기는 python 을 띄우지 않는다(E3 일반 쓰기 비용 보호).
_WGS_RE='hooks/(lib/)?[^/"[:space:]]+\.(sh|py)'
if [[ "$INPUT" =~ $_WGS_RE || "$INPUT" == *write_guard.sh* ]]; then
  case "$TOOL_NAME" in
    mcp__oio__file_write|mcp__oio__file_edit|mcp__oio__file_copy|mcp__oio__file_move|mcp__oio__file_rename|\
    Write|Edit|MultiEdit|mcp__oio__bash_exec|Bash)
      _WGS_TMP=$(mktemp /tmp/wg_self.XXXXXX 2>/dev/null) || _WGS_TMP=""
      if [[ -n "$_WGS_TMP" ]] && command -v python3 >/dev/null 2>&1; then
        _WGS_RES=$(printf '%s' "$INPUT" | WGS_SELF="$(realpath -m -- "${BASH_SOURCE[0]}" 2>/dev/null)" WGS_OUT="$_WGS_TMP" timeout 5 python3 -c '
import json,os,re,shlex,sys
SELF=os.environ.get("WGS_SELF","")
OUT=os.environ["WGS_OUT"]
ROOTS=set()
for r in (os.path.expanduser("${HARNESS_HOME:-$HOME/.harness}/current/hooks"), os.path.dirname(SELF), "${HARNESS_HOME:-$HOME/.harness}/current/hooks", os.environ.get("WGS_EXTRA_ROOT","")):
    if r: ROOTS.add(os.path.realpath(r))
SKIP=("tests","candidates","backup","logs","__pycache__")
def kind(p):
    if not isinstance(p,str) or not p: return None
    r=os.path.realpath(p); a=os.path.abspath(p)
    if r==SELF or r.endswith("/.claude/hooks/write_guard.sh") or a.endswith("/.claude/hooks/write_guard.sh"): return "sh"
    if not (r.endswith(".sh") or r.endswith(".py")): return None
    for root in ROOTS:
        if r.startswith(root+"/"):
            rel=r[len(root)+1:].split("/")
            if rel[0] in SKIP or "__pycache__" in rel: return None
            return "py" if r.endswith(".py") else "sh"
    return None
def emit(txt,k,p):
    if k=="py":
        try:
            compile(txt,p,"exec")
        except SyntaxError as e:
            print("PYERR %s:%s %s" % (os.path.basename(p), e.lineno, e.msg)); sys.exit(0)
        print("OKPY"); sys.exit(0)
    open(OUT,"w",encoding="utf-8").write(txt); print("CHECK "+os.path.basename(p)); sys.exit(0)
def rd(p):
    return open(p,encoding="utf-8").read()
try:
    inp=json.load(sys.stdin); t=inp.get("tool_name",""); ti=inp.get("tool_input") or {}
    g=lambda *ks: next((ti[k] for k in ks if isinstance(ti.get(k),str) and ti.get(k)!=""), None)
    if t in ("mcp__oio__file_write","Write"):
        p=g("path","file_path","filepath"); k=kind(p)
        if k:
            c=g("content","body","data","text","new_content","new_text")
            emit(c if c is not None else "",k,p)
    elif t in ("mcp__oio__file_edit","Edit"):
        p=g("path","file_path","filepath"); k=kind(p)
        if k:
            src=rd(p); old=g("old_string","old","old_text","old_content","search")
            new=ti.get("new_string", ti.get("new", ti.get("new_text", ti.get("new_content", ti.get("replace","")))))
            if old is None or not isinstance(new,str) or old not in src: sys.exit(0)
            allr=bool(ti.get("replace_all") or ti.get("global_replace"))
            emit(src.replace(old,new) if allr else src.replace(old,new,1),k,p)
    elif t=="MultiEdit":
        p=g("file_path","path"); k=kind(p)
        if k:
            src=rd(p)
            for e in ti.get("edits") or []:
                o=e.get("old_string"); n=e.get("new_string","")
                if not isinstance(o,str) or o not in src: sys.exit(0)
                src=src.replace(o,n) if e.get("replace_all") else src.replace(o,n,1)
            emit(src,k,p)
    elif t in ("mcp__oio__file_copy","mcp__oio__file_move","mcp__oio__file_rename"):
        s=g("source","src","path","file_path")
        if t=="mcp__oio__file_rename":
            nn=g("new_name","name","new_path","to") or ""
            d=nn if nn.startswith("/") else os.path.join(os.path.dirname(s or ""),nn)
        else:
            d=g("destination","dest","dst","target","to","new_path") or ""
            if s and (d.endswith("/") or os.path.isdir(d)): d=os.path.join(d,os.path.basename(s))
        k=kind(d)
        if k and s and os.path.isfile(s): emit(rd(s),k,d)
    elif t in ("mcp__oio__bash_exec","Bash"):
        cmd=g("command","cmd") or ""
        # [GG-HA08 정합] heredoc 본문 가리기 — 인용 종결자(<<"W"·<<'W'·<<\W) 본문은 글자일 뿐이라 통째로 뺀다.
        #   비인용 본문은 $(…)·백틱만 실제 실행되므로 그 안쪽만 남겨 계속 판정한다. 줄 끝 \ 이어붙임은 먼저 합친다.
        #   여러 줄 명령은 줄마다 다른 명령이므로 ; 로 바꿔 구간을 나눈다(종전에는 줄이 한 구간으로 합쳐졌다).
        def mask_hd(c):
            ls=c.replace("\\\n"," ").split("\n"); out=[]; i=0
            pat=re.compile(r"(?<!<)<<(?!<)(-?)\s*(?:\x27([^\x27]*)\x27|\"([^\"]*)\"|\\(\w+)|(\w+))")
            while i<len(ls):
                ln=ls[i]; out.append(ln); i+=1; pend=[]
                for m in pat.finditer(ln):
                    q=m.group(2) if m.group(2) is not None else (m.group(3) if m.group(3) is not None else m.group(4))
                    pend.append((q if q is not None else m.group(5), q is not None, m.group(1)=="-"))
                for term,quoted,dash in pend:
                    while i<len(ls):
                        l=ls[i]; i+=1
                        if (l.lstrip("\t") if dash else l)==term: break
                        if not quoted:
                            out.extend(re.findall(r"\$\(([^()]*)\)",l)); out.extend(re.findall(r"`([^`]*)`",l))
            return " ;\n".join(out)
        cmd=mask_hd(cmd)
        lx=shlex.shlex(cmd,posix=True,punctuation_chars=True); lx.whitespace_split=True
        toks=list(lx); segs=[[]]
        for x in toks:
            if x in (";","&&","||","|","&","(",")",";;"): segs.append([])
            else: segs[-1].append(x)
        for sg in segs:
            w=list(sg)
            while w and ("=" in w[0] and not w[0].startswith("-") or w[0] in ("sudo","env","command","exec","nohup","timeout","setsid")):
                w.pop(0)
                if w and w[0].replace(".","").isdigit(): w.pop(0)
            if not w: continue
            c0=os.path.basename(w[0])
            if c0 in ("cp","mv","install"):
                args=[a for a in w[1:] if not a.startswith("-")]
                if len(args)>=2:
                    d=args[-1]; s=args[-2]
                    if d.endswith("/") or os.path.isdir(d): d=os.path.join(d,os.path.basename(s))
                    k=kind(d)
                    if k:
                        if os.path.isfile(s): emit(rd(s),k,d)
                        print("SHELLW 원본을 읽을 수 없음: "+s); sys.exit(0)
            tg=[a for a in w[1:] if kind(a)]
            if tg:
                if c0 in ("sed","perl") and any(a.startswith("-i") or a=="--in-place" for a in w):
                    exprs=[a for a in w[1:] if not a.startswith("-") and not kind(a)]
                    if c0=="sed" and exprs and all(re.fullmatch(r"s/\\r\$?//g?",e) for e in exprs): continue
                    print("SHELLW "+c0+" -i"); sys.exit(0)
                if c0 in ("tee","truncate","dd","ln","rsync"): print("SHELLW "+c0); sys.exit(0)
        for i,x in enumerate(toks):
            if x in (">",">>",">|") and i+1<len(toks) and kind(toks[i+1]): print("SHELLW 리다이렉트"); sys.exit(0)
except SystemExit:
    raise
except Exception:
    pass
' 2>/dev/null) || _WGS_RES=""
        _WGS_WHY=""
        if [[ "$_WGS_RES" == CHECK\ * ]]; then
          _WGS_ERR=$(timeout 10 bash -n "$_WGS_TMP" 2>&1); _WGS_RC=$?
          [[ $_WGS_RC -ne 0 ]] && _WGS_WHY="${_WGS_RES#CHECK } 적용 결과가 bash -n 을 통과하지 못한다(rc=${_WGS_RC}): $(printf '%s' "$_WGS_ERR" | head -2 | sed "s#${_WGS_TMP}#(적용 후)#g" | tr '\n"\\' "  '" | cut -c1-300)"
        elif [[ "$_WGS_RES" == PYERR\ * ]]; then
          _WGS_WHY="적용 결과가 python 문법 검사를 통과하지 못한다: $(printf '%s' "${_WGS_RES#PYERR }" | tr '"\\' "''" | cut -c1-300)"
        elif [[ "$_WGS_RES" == SHELLW* ]]; then
          _WGS_WHY="hook 파일 셸 쓰기(${_WGS_RES#SHELLW })는 적용 결과를 검사할 수 없다"
        fi
        rm -f -- "$_WGS_TMP" 2>/dev/null
        if [[ -n "$_WGS_WHY" ]]; then
          jq -cn --arg r "🚫 [F-WG-SELF] hook 파일 자기 손상 차단 — ${_WGS_WHY}. hook 은 도구 호출마다 실행되며 구문 오류 hook 은 rc=2 로 끝나 차단으로 해석된다 — 깨진 판이 반영되면 자기 복구 편집까지 막혀 전 세션이 멈춘다(2026-10-12 실사고). 사본(scratchpad)에서 변경을 완성하고 문법 검사를 통과시킨 뒤, 같은 디렉터리 임시파일에 쓰고 mv 로 원자 교체하라(구조 변경을 file_edit 여러 번으로 나누지 말 것)." \
            '{decision:"block",reason:$r}' 2>/dev/null || echo '{"decision":"block","reason":"🚫 [F-WG-SELF] hook 파일 적용 결과 구문 오류 — 차단"}'
          exit 2
        fi
      fi
      [[ -n "$_WGS_TMP" ]] && rm -f -- "$_WGS_TMP" 2>/dev/null
      ;;
  esac
fi
# --- F-WG-SELF 끝 ---

# ═════════════════════════════════════════════════════════════════════════════
# [F-LKG-PROT 사이클182 — 재발방지 2층 보호] hook 마지막 정상본(LKG) 저장소·사본은 time_budget 만 갱신한다.
# 배경: odev-12 의 time_budget LKG 대체 실행(구문 오류 hook → 직전 정상판으로 판정)은, LKG 를 에이전트가 바꿔치기할 수
#   있으면 "깨진 척 → 약한 정상본으로 판정" 우회 통로가 된다(team-lead 결정 2026-10-12 05:28). 경계는 odev-12 확정안을 따른다.
# 보호 경로(쓰기·삭제·이동·이름변경·링크·디렉터리 단위 조작 전부 차단, 읽기는 허용):
#   P1 $HOME/.local/state/hook_lkg 와 그 하위 전부(realpath·문자열 둘 다)
#   P2 hook 트리(${HARNESS_HOME:-$HOME/.harness}/current/hooks/**·*/.claude/hooks/**) 안 basename 이 `.*.lkg.*` 인 파일(예: .write_guard.sh.lkg.9061bc75d77f)
#   P3 P1·P2 를 품은 디렉터리의 dir_delete/dir_move/dir_rename, 셸 rm/rmdir/mv/rsync/find -delete·-exec
# 예외 없음(실측 근거): LKG 를 쓰는 유일한 주체는 time_budget.sh 내부 백그라운드 서브셸이고 이는 도구 호출이 아니라
#   hook 프로세스 내부 쓰기다. write_guard(PreToolUse)는 에이전트의 도구 호출만 보므로 정상 갱신은 이 판정을 만나지 않는다.
#   프로세스 이름·환경변수·마커로 예외를 두면 그 자체가 우회 통로가 되므로 두지 않는다. 에이전트가 time_budget.sh 를 손으로
#   실행해 LKG 를 갱신시키는 경로는 남지만, 그때 저장되는 것은 "그 경로에 실제로 있던, bash -n 을 통과한 판" 뿐이라
#   hook 원본을 직접 바꾸는 것 이상의 능력을 주지 않는다(원본 변경은 F-WG-SELF·gp_gate 가 본다).
# 셸: heredoc 본문 가리기(F-WG-SELF 와 같은 규칙) 뒤 구간마다 — 보호 경로를 언급한 구간은 첫 명령이 읽기 전용
#   (cat·grep·ls·stat·sha256sum·head·tail·wc·file·readlink·realpath·test·diff·cmp·jq·find(-delete·-exec 없음))일 때만 통과,
#   보호 경로로의 리다이렉트는 무조건 차단, 보호 경로를 품은 디렉터리에 rm·mv·rsync·find -delete 는 차단.
# 비용(E3): 사전 필터는 문자열 비교만(fork 0) — hook_lkg·.lkg.·.local/state 언급, dir_* 도구, hooks 와 rm/mv/rsync/find 동시 언급일 때만 python 1회.
# 시험 전용: WGL_LKG_DIR(저장소 경로 재지정)·WGS_EXTRA_ROOT(hook 루트 추가) — hook 실행 환경에서만 설정 가능(에이전트 명령으로 못 바꿈).
# 잔존 한계: 변수 간접화·인터프리터 문자열 조립(python -c 로 경로를 쪼개 만듦)은 문자열 판정이라 완전하지 않다 —
#   단 보호 경로 언급 + 비읽기 명령은 기본 차단이라 python/bash -c 에 경로를 그대로 쓰면 막힌다.
# [F-SR-PROT 사이클196 과제1 N1] 같은 판정기로 F-SCRIPT-RECHECK 근거 파일도 보호한다(차단 태그만 다르다 — 판정기 출력 SR …):
#   대상: 경로 성분이 recent_block 또는 script_author 인 디렉터리와 그 하위(문자열·realpath 둘 다, 대소문자 무시) —
#   hooks/logs/recent_block(차단 표식)·hooks/logs/script_author(작성자 기록부). 이를 품은 디렉터리의 dir_delete/move/rename,
#   셸 rm/rmdir/mv/rsync/find -delete 도 차단한다(dir_create 는 조상 생성이 표식을 지우지 않으므로 대상 밖). 읽기는 허용.
#   예외 없음: 표식·기록부를 쓰는 주체는 write_guard 자신(sr_mark_block·sr_author_record)이고 hook 프로세스 내부 쓰기라 이 판정을 만나지 않는다.
#   잔존 한계: cd 뒤 상대 경로·글롭·변수 간접화·git stash/checkout 처럼 경로를 적지 않는 일괄 복원(문자열 판정 한계).
# ═════════════════════════════════════════════════════════════════════════════
# [사이클182 반복1 (B)] F-LKG-PROT 판정불가 지연 차단 — 최종 rc 가 0(통과)일 때만 개입한다.
#   rc=2(다른 확정 차단)·그 밖의 rc·신호 종료(time_budget 강제 종료 143/137)는 손대지 않는다(그 경우 closed 정책이 차단).
#   명령 치환·( ) 하위 셸은 EXIT trap 을 물려받지 않으므로(bash 규칙) 내부 exit 에서 돌지 않는다. 기존 EXIT trap 은 없다(ERR trap 만 있음).
_LKG_UNDET=""
_DG_UNDET=""   # [사이클182 반복1 A3] bash state=DONE 쓰기의 done_gate 판정불가(같은 지연 판정)
_wg_lkg_undet_exit() {
  local _rc=$?
  if [[ "$_rc" -eq 0 && -n "${_DG_UNDET:-}" ]]; then
    jq -cn --arg r "⏳ [Hd3] bash 로 state=DONE 을 쓰는 경로의 증거 마커 검사(done_gate)가 시간 안에 끝나지 않았습니다(${_DG_UNDET}, 시스템 정체) — 아직 거부가 아닙니다. 판정불가는 통과가 아니므로 이번 호출은 보류합니다. 같은 호출을 잠시 뒤 다시 하십시오." \
      '{decision:"block",reason:$r}' 2>/dev/null || echo '{"decision":"block","reason":"⏳ [Hd3] done_gate 판정 시간 초과 — 판정불가는 통과가 아닙니다. 같은 호출을 다시 하십시오."}'
    _wg_fw_end 2 || true   # [사이클194 g①] F-NO-BYPASS 기록부 — 최종 판정 기록
    exit 2
  fi
  if [[ "$_rc" -eq 0 && -n "${_LKG_UNDET:-}" ]]; then
    jq -cn --arg r "⏳ [F-LKG-PROT] 보호 경로(hook_lkg·.lkg 사본) 판정이 시간 안에 끝나지 않았습니다(${_LKG_UNDET}, 시스템 정체) — 아직 거부가 아닙니다. 판정불가는 통과가 아니므로 이번 호출은 보류합니다. 같은 호출을 잠시 뒤 다시 하십시오." \
      '{decision:"block",reason:$r}' 2>/dev/null || echo '{"decision":"block","reason":"⏳ [F-LKG-PROT] 판정 시간 초과 — 판정불가는 통과가 아닙니다. 같은 호출을 다시 하십시오."}'
    _wg_fw_end 2 || true
    exit 2
  fi
  _wg_fw_end "$_rc" || true
}
trap '_wg_lkg_undet_exit' EXIT
_LKG_ON=""
case "$TOOL_NAME" in
  mcp__oio__dir_delete|mcp__oio__dir_move|mcp__oio__dir_rename) _LKG_ON=1 ;;
  mcp__oio__file_write|mcp__oio__file_edit|mcp__oio__file_delete|mcp__oio__file_copy|mcp__oio__file_move|mcp__oio__file_rename|\
  mcp__oio__file_symlink|mcp__oio__dir_create|Write|Edit|MultiEdit|NotebookEdit|mcp__oio__bash_exec|Bash)
    if [[ "$INPUT" == *hook_lkg* || "$INPUT" == *.lkg.* || "$INPUT" == *.local/state* || "${INPUT,,}" == *recent_block* || "${INPUT,,}" == *script_author* ]]; then
      _LKG_ON=1
    elif [[ ( "$TOOL_NAME" == mcp__oio__bash_exec || "$TOOL_NAME" == Bash ) && "$INPUT" == *hooks* ]] && \
         [[ "$INPUT" == *"rm "* || "$INPUT" == *"rmdir "* || "$INPUT" == *"mv "* || "$INPUT" == *"rsync "* || "$INPUT" == *"find "* ]]; then
      _LKG_ON=1
    fi ;;
esac
if [[ -n "$_LKG_ON" ]] && command -v python3 >/dev/null 2>&1; then
  _LKG_RES=$(printf '%s' "$INPUT" | WGS_SELF="$(realpath -m -- "${BASH_SOURCE[0]}" 2>/dev/null)" timeout 5 python3 -c '
import glob,json,os,re,shlex,sys
LKG=os.path.realpath(os.path.expanduser(os.environ.get("WGL_LKG_DIR") or "~/.local/state/hook_lkg"))
ROOTS=set()
for r in (os.path.expanduser("${HARNESS_HOME:-$HOME/.harness}/current/hooks"), os.path.dirname(os.environ.get("WGS_SELF","")), "${HARNESS_HOME:-$HOME/.harness}/current/hooks", os.environ.get("WGS_EXTRA_ROOT","")):
    if r: ROOTS.add(os.path.realpath(r))
LKRE=re.compile(r"^\..+\.lkg\.")
def in_tree(r):
    return "/.claude/hooks/" in r+"/" or any(r==x or r.startswith(x+"/") for x in ROOTS)
def rp(p):
    return os.path.realpath(os.path.expanduser(p))
KIND=[""]
SRRE=re.compile(r"(^|/)(recent_block|script_author)(/|$)")
SRD=set()
for x in ROOTS:
    for n in ("recent_block","script_author"): SRD.add((x+"/logs/"+n).lower())
def sr(p):
    if not isinstance(p,str) or not p: return False
    if SRRE.search(p.lower()) or SRRE.search(rp(p).lower()):
        KIND[0]="S"; return True
    return False
def sr_holds(p):
    if not isinstance(p,str) or not p: return False
    r=rp(p).lower().rstrip("/") or "/"
    if r=="/" or any(d==r or d.startswith(r+"/") for d in SRD):
        KIND[0]="S"; return True
    return False
def prot(p):
    if not isinstance(p,str) or not p: return False
    if sr(p): return True
    if "hook_lkg" in p: return True
    r=rp(p)
    if r==LKG or r.startswith(LKG+"/"): return True
    return bool(LKRE.match(os.path.basename(r))) and in_tree(os.path.dirname(r))
_LF=None
def lkg_files():
    global _LF
    if _LF is None:
        _LF=[]
        for x in ROOTS:
            for pat in ("/.*.lkg.*","/*/.*.lkg.*","/*/*/.*.lkg.*"):
                _LF.extend(os.path.realpath(f) for f in glob.glob(x+pat))
    return _LF
def holds(p):
    if not isinstance(p,str) or not p: return False
    r=rp(p)
    if r in ("/",""): return True
    if LKG.startswith(r+"/") or r==LKG: return True
    # [사이클182 반복1 (C)] .lkg 사본은 ROOTS 아래에만 있다(lkg_files 가 ROOTS 만 glob) — 대상이 루트의 조상·자손이 아니면
    #   품을 수 없으므로 glob(NTFS hook 루트 포함, 부하 시 수 초)을 건너뛴다. 판정 결과는 종전과 같다.
    if not any(x==r or x.startswith(r+"/") or r.startswith(x+"/") for x in ROOTS): return False
    return any(f.startswith(r+"/") for f in lkg_files())
def out(m):
    print(("SR"+m[2:]) if KIND[0]=="S" and m.startswith("NG") else m); sys.exit(0)
try:
    inp=json.load(sys.stdin); t=inp.get("tool_name",""); ti=inp.get("tool_input") or {}
    vals=lambda *ks: [ti[k] for k in ks if isinstance(ti.get(k),str) and ti.get(k)!=""]
    if t in ("mcp__oio__dir_delete","mcp__oio__dir_move","mcp__oio__dir_rename"):
        for p in vals("path","source","src","file_path","destination","dest","dst","target","to","new_path"):
            if prot(p) or holds(p) or sr_holds(p): out("NG 디렉터리 조작이 보호 경로를 포함: "+p)
        nn=vals("new_name","name")
        base=(vals("path","source","src") or [""])[0]
        for n in nn:
            d=n if n.startswith("/") else os.path.join(os.path.dirname(base),n)
            if prot(d) or holds(d) or sr_holds(d): out("NG 디렉터리 이름변경 대상이 보호 경로: "+d)
    elif t in ("mcp__oio__bash_exec","Bash"):
        cmd=(vals("command","cmd") or [""])[0]
        def mask_hd(c):
            ls=c.replace("\\\n"," ").split("\n"); o=[]; i=0
            pat=re.compile(r"(?<!<)<<(?!<)(-?)\s*(?:\x27([^\x27]*)\x27|\"([^\"]*)\"|\\(\w+)|(\w+))")
            while i<len(ls):
                ln=ls[i]; o.append(ln); i+=1; pend=[]
                for m in pat.finditer(ln):
                    q=m.group(2) if m.group(2) is not None else (m.group(3) if m.group(3) is not None else m.group(4))
                    pend.append((q if q is not None else m.group(5), q is not None, m.group(1)=="-"))
                for term,quoted,dash in pend:
                    while i<len(ls):
                        l=ls[i]; i+=1
                        if (l.lstrip("\t") if dash else l)==term: break
                        if not quoted:
                            o.extend(re.findall(r"\$\(([^()]*)\)",l)); o.extend(re.findall(r"`([^`]*)`",l))
            return " ;\n".join(o)
        c2=mask_hd(cmd)
        try:
            lx=shlex.shlex(c2,posix=True,punctuation_chars=True); lx.whitespace_split=True; toks=list(lx)
        except ValueError:
            if "hook_lkg" in c2 or ".lkg." in c2: out("NG 보호 경로 언급 + 명령 파싱 불가")
            if sr(c2): out("NG 보호 경로 언급 + 명령 파싱 불가")
            sys.exit(0)
        for i,x in enumerate(toks):
            if x in (">",">>",">|","&>") and i+1<len(toks) and prot(toks[i+1]): out("NG 보호 경로로 리다이렉트: "+toks[i+1])
        READ={"cat","grep","egrep","fgrep","rg","ls","stat","sha256sum","sha1sum","md5sum","head","tail","wc","file","readlink","realpath","test","[","diff","cmp","jq","find","echo","printf","true"}
        segs=[[]]; seps=[""]   # [D-2] seps: 각 구간 앞의 구분자(파이프 연결 추적용)
        for x in toks:
            # [사이클196] shlex 는 이어진 구두점을 한 토큰(");"·")|" 등)으로 낸다 — 그것도 구간 구분자로 본다(앞 명령에 뒤 인자가 붙어 읽기 명령이 과차단되던 결함)
            if x in (";","&&","||","|","&","(",")",";;") or (x and set(x)<=set(";&|()")): segs.append([]); seps.append(x)
            else: segs[-1].append(x)
        RDR=(">",">>",">|","&>")
        def judge(sg):
            # [D-2 사이클199] 구간 안 리다이렉트 대상도 본다 — 반복 펼침으로 대입된 경로(echo x > "$f")를 잡기 위함
            for i,x in enumerate(sg):
                if x in RDR and i+1<len(sg) and prot(sg[i+1]): out("NG 보호 경로로 리다이렉트: "+sg[i+1])
            # [D-2] 입력 리다이렉트(<) 대상은 읽기다 — 명령 단어·인자로 보지 않는다(while … done < 경로 과차단 해소)
            w=[]; skip=False
            for x in sg:
                if skip: skip=False; continue
                if x=="<": skip=True; continue
                if x in (">",">>",">|","&>","2>"): continue
                w.append(x)
            while w and ("=" in w[0] and not w[0].startswith("-") or w[0] in ("sudo","env","command","exec","nohup","timeout","setsid","nice","time")):
                w.pop(0)
                if w and re.fullmatch(r"[0-9.]+[smhd]?",w[0]): w.pop(0)
            if not w: return None
            c0=os.path.basename(w[0]); args=w[1:]
            if c0 in ("cp","install","ln"):   # 원본 쪽(읽기)은 허용, 마지막 인자(쓰기 대상)만 본다 — file_copy 원본 허용과 같은 기준
                na=[a for a in args if not a.startswith("-")]
                if na and (prot(na[-1]) or (os.path.isdir(rp(na[-1])) and len(na)>1 and prot(os.path.join(na[-1],os.path.basename(na[-2]))))):
                    out("NG 보호 경로에 %s 로 쓰기: %s" % (c0, na[-1]))
                return (c0,False)
            refs=[a for a in args if prot(a)] + ([w[0]] if prot(w[0]) else [])
            badfind = c0=="find" and any(a in ("-delete","-exec","-execdir","-ok","-okdir","-fprint","-fprint0","-fprintf","-fls") for a in args)
            if refs and (c0 not in READ or badfind):
                out("NG 보호 경로에 %s (읽기 전용 명령만 허용): %s" % (c0, refs[0]))
            if c0 in ("rm","rmdir","mv","rsync","shred","unlink") or badfind:
                for a in args:
                    if not a.startswith("-") and (holds(a) or sr_holds(a)): out("NG 보호 경로를 품은 대상에 %s: %s" % (c0,a))
            return (c0,badfind)
        # [D-2 사이클199] 셸 제어 구조 펼침 — pdg_core c199f 건2 와 같은 원리(반복 단어를 본문에 대입해 구간마다 판정).
        #   종전에는 for/do/done/while/then 등 예약어를 명령 단어로 보아, 보호 경로를 읽기만 하는 반복도 "for 는 읽기 명령 아님"으로 막혔다.
        #   예약어는 떼어 내고 남은 명령을 판정한다. for 헤더 단어는 실행되지 않는 데이터라 직접 판정하지 않는 대신,
        #   본문에서 반복 변수를 쓰는 구간은 단어마다 대입해 같은 규칙(읽기 전용·cp 대상·리다이렉트·rm 품음)으로 판정한다.
        #   헤더의 명령 치환($(ls 보호경로))이 보호 경로를 언급하면 그 경로를 대입 후보로 더한다 — 종전에 통과하던
        #   `for f in $(ls 보호경로); do rm "$f"` 를 새로 막는다(차단력 강화).
        #   오염 반복(헤더 단어·헤더 명령 치환·done < 입력 중 하나가 보호 경로)은 종전에 헤더 단계에서 통째로 막혔다. 그 차단력을
        #   유지하려고, 오염 반복의 본문 전 구간과 그 반복의 `done |` 뒤 파이프 구간은 읽기 전용 명령만 허용하고 대상에 $ 가 든
        #   리다이렉트를 막는다(다른 변수로 옮겨 담기 g=$f·xargs·while read 루프 변수로 새는 길을 닫는다).
        #   잔존 한계(종전과 같음): 반복 밖 `ls 보호경로 | xargs rm` 같은 비반복 파이프, cd 뒤 상대 경로, 변수 간접화.
        # [사이클200] 오염 반복의 본문·`done |` 뒤 구간에서만 sort 를 읽기로 본다 — 구조 판정(어휘 추가 아님).
        #   조건: 첫 단어가 sort 자체이고, 리다이렉트 토큰이 없고, 옵션이 전부 허용 목록 안이다.
        #   출력 옵션(-o·--output·-oFILE·-uo 처럼 붙여 쓴 o)·임시 디렉터리(-T)·외부 프로그램(--compress-program)·모르는 옵션은 읽기가 아니다.
        SORT_SO=set("bdfghiMmnRrsuVzcC")
        SORT_LO={"--ignore-leading-blanks","--dictionary-order","--ignore-case","--general-numeric-sort","--ignore-nonprinting",
                 "--month-sort","--human-numeric-sort","--numeric-sort","--random-sort","--reverse","--version-sort","--check",
                 "--check=quiet","--check=silent","--merge","--stable","--unique","--zero-terminated"}
        def sort_ro(w):
            if not w or w[0]!="sort": return False
            i=1; n=len(w)
            while i<n:
                x=w[i]; i+=1
                if x and set(x)<=set("<>&|") and (">" in x or "<" in x): return False
                if x=="--":
                    return not any(y and set(y)<=set("<>&|") for y in w[i:])
                if x.startswith("--"):
                    if x in SORT_LO or x.startswith(("--key=","--field-separator=")): continue
                    if x in ("--key","--field-separator"): i+=1; continue
                    return False
                if x.startswith("-") and x!="-":
                    cl=x[1:]
                    for j,ch in enumerate(cl):
                        if ch in SORT_SO: continue
                        if ch in "ktS":
                            if j==len(cl)-1: i+=1
                            break
                        return False
            return True
        KW={"do","done","then","else","elif","if","fi","while","until","!","{","}"}
        frames=[]; stack=[]; recs=[]; pipe_prev=set()
        def frame(v,ws):
            return {"v":v,"ws":ws,"taint":any(prot(x) for x in ws),"inhead":True,
                    "re":re.compile(r"\$\{%s\}|\$%s(?![A-Za-z0-9_])" % (v,v)) if v else None}
        for sep,sg in zip(seps,segs):   # 1단계: 반복 구간·오염·파이프 연결 계산
            pin=set(pipe_prev) if "|" in sep.replace("||","") else set()
            w0=list(sg); closed=set()
            while w0 and w0[0] in KW:
                k=w0.pop(0)
                if k=="do":
                    if stack and frames[stack[-1]]["inhead"]: frames[stack[-1]]["inhead"]=False
                elif k=="done":
                    if stack:
                        fi=stack.pop(); closed.add(fi)
                        if any(x=="<" and i+1<len(w0) and prot(w0[i+1]) for i,x in enumerate(w0)): frames[fi]["taint"]=True
                elif k in ("while","until"):
                    frames.append(frame(None,[])); stack.append(len(frames)-1)
            if w0 and w0[0] in ("for","select"):
                v=w0[1] if len(w0)>1 and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*",w0[1]) else None
                frames.append(frame(v,list(w0[3:]) if v and len(w0)>2 and w0[2]=="in" else []))
                recs.append((w0,True,[],pin)); stack.append(len(frames)-1)
            else:
                if stack and frames[stack[-1]]["inhead"] and any(prot(x) for x in sg):   # 헤더 명령 치환·while 조건이 보호 경로 언급
                    frames[stack[-1]]["taint"]=True; frames[stack[-1]]["ws"].extend(x for x in sg if prot(x))
                recs.append((w0,False,[fi for fi in stack if not frames[fi]["inhead"]],pin))
            pipe_prev=pin|closed
        for w0,hdr,act,pin in recs:   # 2단계: 구간마다 판정(헤더 단어는 데이터 — 리다이렉트만 본다)
            if hdr:
                for i,x in enumerate(w0):
                    if x in RDR and i+1<len(w0) and prot(w0[i+1]): out("NG 보호 경로로 리다이렉트: "+w0[i+1])
                continue
            if not w0: continue
            h=judge(w0)
            for fi in act:
                f=frames[fi]
                if f["re"] is None or not any(f["re"].search(x) for x in w0): continue
                for word in f["ws"]:
                    judge([f["re"].sub(lambda _m, _w=word: _w, x) for x in w0])
            if any(frames[fi]["taint"] for fi in set(act)|pin):
                if h and (h[0] not in READ or h[1]) and not sort_ro(w0): out("NG 보호 경로 반복 안 %s (읽기 전용 명령만 허용)" % h[0])
                for i,x in enumerate(w0):
                    if x in RDR and i+1<len(w0) and "$" in w0[i+1]: out("NG 보호 경로 반복 안 변수 대상 리다이렉트: "+w0[i+1])
    else:
        ps=[]
        if t!="mcp__oio__file_copy": ps+=vals("path","file_path","filepath")
        if t in ("mcp__oio__file_move","mcp__oio__file_rename"): ps+=vals("source","src")
        if t in ("mcp__oio__file_move","mcp__oio__file_copy"): ps+=vals("destination","dest","dst","target","to","new_path")
        if t=="mcp__oio__file_symlink": ps+=vals("link_path","link","dest")
        if t=="mcp__oio__file_rename":
            base=(vals("path","source","src") or [""])[0]
            for n in vals("new_name","name","new_path","to"):
                ps.append(n if n.startswith("/") else os.path.join(os.path.dirname(base),n))
        for p in ps:
            if prot(p): out("NG %s 대상이 보호 경로: %s" % (t,p))
            if t=="mcp__oio__dir_create" and holds(p): out("NG 보호 경로 안 디렉터리 생성: "+p)
except SystemExit:
    raise
except Exception:
    pass
' 2>/dev/null) && _LKG_PYRC=0 || { _LKG_PYRC=$?; _LKG_RES=""; }
  # [사이클182 반복1 L02] 판정기 시간 초과(124)·강제 종료(137 등)를 빈 판정 = 통과로 두면 부하 때 보호 경로 쓰기가
  #   그대로 통과했다(fail-open — 판정 python 5.5s 지연 모사로 직접 호출·time_budget 7.5 closed 경로 둘 다 3/3 통과 실측).
  #   판정불가는 통과가 아니다 — 차단하고 같은 호출 재시도를 안내한다(goal_autoscript 위임의 124=판정불가 차단과 같은 처리).
  #   [사이클182 반복1 (B)] 즉시 차단하면 뒤의 확정 차단(F-CRUD-1/partial 등)보다 먼저 막아 사유가 가려졌다(c177 부하 회귀).
  #   판정불가만 기록하고 나머지 판정을 계속한다 — 끝까지 통과(exit 0)일 때만 아래 EXIT trap 이 판정불가로 차단한다.
  if [[ "$_LKG_PYRC" -ne 0 ]]; then
    _LKG_UNDET="rc=${_LKG_PYRC}"
  fi
  if [[ "$_LKG_RES" == SR\ * ]]; then
    jq -cn --arg r "🚫 [F-SR-PROT] F-SCRIPT-RECHECK 근거 파일(hooks/logs/recent_block 차단 표식·hooks/logs/script_author 작성자 기록부)은 write_guard 만 기록한다 — ${_LKG_RES#SR }. 위조·삭제하면 차단 직후 스크립트 재판정(L-604)이 무력화된다(사이클196 N1). 읽기(cat·grep·ls·stat, file_read·list_dir)는 허용된다. 과차단이면 우회하지 말고 리드에게 보고하라(L-597)." \
      '{decision:"block",reason:$r}' 2>/dev/null || echo '{"decision":"block","reason":"🚫 [F-SR-PROT] recent_block·script_author 는 write_guard 만 기록한다"}'
    exit 2
  fi
  if [[ "$_LKG_RES" == NG\ * ]]; then
    jq -cn --arg r "🚫 [F-LKG-PROT] hook_lkg 저장소·.lkg 사본은 time_budget 만 갱신한다 — ${_LKG_RES#NG }. 마지막 정상본(LKG)을 바꿔치기하면 구문 오류 hook 의 대체 판정이 우회 통로가 된다(사이클182 재발방지 2층 보호). 읽기(cat·grep·ls·sha256sum·stat, file_read·list_dir)는 허용된다. 정상본을 바꾸려면 hook 원본을 정상판으로 고치면 다음 호출에서 time_budget 이 자동 갱신한다." \
      '{decision:"block",reason:$r}' 2>/dev/null || echo '{"decision":"block","reason":"🚫 [F-LKG-PROT] hook_lkg 저장소·.lkg 사본은 time_budget 만 갱신한다"}'
    exit 2
  fi
fi
# --- F-LKG-PROT 끝 ---

# ── F-ASKQ-PROT (conv_179160716700 D3 → conv_179163042411 역라우팅 #2): CRUD 판정 근거 보호 — 메인·팀 공통 ──
# 대상: ① $CLAUDE_CONFIG_DIR/projects/**/*.jsonl (트랜스크립트)
#       ② session-env/*/logs/askq_approval_consumed.log (화면 승인 1회용 소비 기록 — 지우면 승인 재사용 가능)
#          [2026-10-20 conv_179239511726] 화면 승인 재도입으로 복원(728be20 에서 뺐던 항목). 범위는 이 로그 경로 하나다.
#          기록 주체는 hook 이 부르는 lib/askq_approval.py 뿐이며 도구 호출이 아니므로 이 가드 대상이 아니다.
#       ③ session-env/*/baseline_untracked/** (D1 기준선 — 위조하면 판정기 diff 가 오염된다)
# 판정: 문자열 경로와 realpath 양쪽, 대소문자 무시 — projects 는 drvfs(.wsl-home/claude-projects) 심볼릭 링크다.
# 동작: 쓰기뿐 아니라 삭제·이동·이름변경·복사 덮어쓰기·심볼릭 링크·디렉터리 조작까지 차단. 읽기는 비대상.
#   projects/*/memory/*.md 는 .jsonl 이 아니므로 비대상. hook 자신(기준선 보관)은 도구 호출이 아니라 해당 없음.
# 잔존 한계(정직 고지): 셸은 문자열 패턴 판정이라 변수 간접화 등 난독화 우회 여지가 있다.
_ASKQ_ROOTS=""
_askq_roots_init() {
  [[ -n "$_ASKQ_ROOTS" ]] && return 0
  local _r _rr
  for _r in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects" "$HOME/.claude/projects"; do
    _ASKQ_ROOTS+="${_r,,}"$'\n'
    _rr=$(realpath -m -- "$_r" 2>/dev/null) && [[ -n "$_rr" ]] && _ASKQ_ROOTS+="${_rr,,}"$'\n'
  done
  return 0
}
# ④ [역라우팅 #1] session-env/<U>/pipeline_start_time — 판정기 SKIP_PREEXISTING·기준선 유효성의 기준 시각이라
#   변조하면 DML 신규 파일이 "시작 전부터 있던 파일" 로 통과한다. 쓰기 허용 구간은 유일한 기록 주체(ok/SKILL.md
#   evidence_초기화 `date +%s >`)가 도는 구간뿐: 그 세션 state 가 IDLE, 또는 PLAN(구 OK stage 포함) + classification=OK.
#   그 외(PLAN/O1~O5·DEV·TEST·DONE·FINISH·state 판독 불가)는 메인·팀 모두 차단(fail-closed).
# ⑤ [역라우팅 #1 보충] session-env/<U>/evidence/ok_started — 판정기가 시작시각과 교차 확인하는 진입 마커. 같은 조건으로 잠근다.
#   단 FINISH 는 허용한다 — ofinish Step 4(references/CLEANUP_FILES.md)가 evidence/ 를 통째 dir_delete 하는 정상 경로다.
#   evidence/ 디렉터리째 삭제·이동(file 도구 dir_* · 셸 rm/rmdir/mv)도 ok_started 를 없애므로 같은 조건으로 막는다.
# ⑥ [guard-deadlock D5] session-env/<U>/plan_entry_mark — Stop 가드5 가 고착 PLAN+OK 롤백을 면제하는 근거다. touch 한 번으로 영구 면제가 된다.
#   기록 주체는 hook 이 부르는 pea_stamp·phase_guard 뿐이고 도구 호출이 아니므로 이 가드 대상이 아니다. 에이전트에게는 허용 구간이 없다(IDLE 에 찍어 두면 다음 PLAN+OK 를 면제한다).
#   셸은 엄격 읽기 전용 명령의 언급만 통과한다. 표식을 품은 디렉터리 조작은 pipeline_start_time 과 같은 구간 판정이다.
#   잔여 한계: mcp__oio__session_state 는 이 hook 의 매처 밖이고 key 로 파일명을 받는다. 파일 도구·셸 경로만 막힌다.
_askq_start_locked() {  # $1=세션 디렉터리 $2=1 이면 FINISH 도 허용(ok_started) → 잠김(쓰기 금지)이면 0
  local _st _cl
  _st=$(head -c 64 -- "$1/state" 2>/dev/null | awk 'NR==1{print toupper($1)}')
  [[ -n "$_st" ]] || return 0
  [[ "$_st" == "IDLE" ]] && return 1
  [[ "${2:-0}" == "1" && "$_st" == "FINISH" ]] && return 1
  if [[ "$_st" == "PLAN" || "$_st" == "OK" ]]; then
    _cl=$(head -c 16 -- "$1/classification" 2>/dev/null | tr -d '[:space:]')
    [[ "${_cl^^}" == "OK" ]] && return 1
  fi
  return 0
}
_askq_prot() {  # $1=경로 $2=1 이면 디렉터리 조작(하위에 보호 대상을 품는지까지 본다) → 보호 대상이면 0
  local _x _l _r _g
  [[ -n "$1" ]] || return 1
  _askq_roots_init
  for _x in "$1" "$(realpath -m -- "$1" 2>/dev/null)"; do
    [[ -n "$_x" ]] || continue
    _l="${_x,,}"; _l="${_l%/}"
    case "$_l" in
      */session-env/*/logs/askq_approval_consumed.log|*/session-env/*/baseline_untracked|*/session-env/*/baseline_untracked/*|*/session-env/*/plan_entry_mark) return 0 ;;
      */session-env/*/pipeline_start_time) _askq_start_locked "${_x%/*}" && return 0 ;;
      */session-env/*/evidence/ok_started) _askq_start_locked "${_x%/*/*}" 1 && return 0 ;;
    esac
    if [[ "$2" == "1" && -e "${_x%/}/plan_entry_mark" ]]; then
      _askq_start_locked "${_x%/}" && return 0
    fi
    if [[ "$2" == "1" && -e "${_x%/}/pipeline_start_time" ]]; then
      _askq_start_locked "${_x%/}" && return 0
    fi
    if [[ "$2" == "1" ]]; then
      if [[ -e "${_x%/}/ok_started" && "$_l" == */session-env/*/evidence ]]; then
        _askq_start_locked "${_x%/}/.." 1 && return 0
      fi
      [[ -e "${_x%/}/evidence/ok_started" ]] && _askq_start_locked "${_x%/}" 1 && return 0
    fi
    while IFS= read -r _r; do
      [[ -n "$_r" ]] || continue
      [[ "$_l" == "$_r"/*.jsonl ]] && return 0
      if [[ "$2" == "1" ]] && [[ "$_l" == "$_r" || "$_l" == "$_r"/* || "$_r" == "$_l"/* ]]; then
        [[ "$_l" == */memory || "$_l" == */memory/* ]] || return 0
      fi
    done <<<"$_ASKQ_ROOTS"
    if [[ "$2" == "1" && -d "$_x" ]]; then
      [[ -e "$_x/logs/askq_approval_consumed.log" || -d "$_x/baseline_untracked" || "$_l" == */session-env/*/logs ]] && return 0
      for _g in "$_x"/*/logs/askq_approval_consumed.log "$_x"/*/baseline_untracked; do
        [[ -e "$_g" ]] && return 0
      done
    fi
  done
  return 1
}
_askq_self_cands() {  # 자기 세션 후보: 조상 argv --parent-session-id, hook session_id
  local _p=$$ _i=0 _par
  while [[ -n "$_p" && "$_p" != "1" && $_i -lt 12 ]]; do
    _par=$(tr '\0' ' ' 2>/dev/null < "/proc/${_p}/cmdline" \
      | grep -oP -- '--parent-session-id \K[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
    [[ -n "$_par" ]] && { printf '%s\n' "$_par"; break; }
    _p=$(awk '/^PPid:/{print $2}' "/proc/${_p}/status" 2>/dev/null); _i=$((_i + 1))
  done
  echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null
}
_askq_sh_lock() {  # $1=리터럴 UUID 추출 PCRE(\K) $2=전체 출현 PCRE $3=1 이면 FINISH 허용 → 잠김이면 0
  local _sids _nall _nlit=0 _cands="" _s _sd _any=""
  _sids=$(printf '%s' "$_ASKQ_CMD" | grep -oiP -- "$1" 2>/dev/null)
  _nall=$(printf '%s' "$_ASKQ_CMD" | grep -oiP -- "$2" 2>/dev/null | wc -l)
  while IFS= read -r _s; do
    [[ "$_s" =~ ^[0-9a-fA-F-]{36}$ ]] && { _cands+="$_s"$'\n'; _nlit=$((_nlit + 1)); }
  done <<<"$_sids"
  (( ${_nall:-0} > _nlit )) && _cands+="$(_askq_self_cands)"$'\n'
  while IFS= read -r _s; do
    [[ -n "$_s" ]] || continue
    _any=1
    _sd="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${_s}"
    [[ -d "$_sd" ]] || _sd="$HOME/.claude/session-env/${_s}"
    _askq_start_locked "$_sd" "$3" && return 0
  done <<<"$_cands"
  [[ -n "$_any" ]] || return 0
  return 1
}
# [사이클194 (f)] 엄격 읽기 전용 셸 명령 판정 — 참(0)이면 ④ pipeline_start_time·⑤ ok_started·⑤' evidence 언급을 통과시킨다.
#   [사이클205] ① 트랜스크립트 언급도 이 판정이 참이면 통과(W3), 메인 PLAN 차단 앞 허용분기 E 도 이 판정을 쓴다(W1).
#   ② 소비 기록·③ 기준선은 이 판정과 무관하게 계속 차단한다. 조건이 하나라도 어긋나면 거짓(기존 차단 유지 — fail-closed).
#   조건: 개행 없음 / 백슬래시·$(·백틱·<(·>(·<< 없음 / '>' 없음(2>/dev/null·2>&1 토큰만 예외) / 단독 & 없음 /
#         ;·&&·||·| 로 나눈 각 구간 첫 단어가 읽기 명령 목록 중 하나(VAR= 대입 접두·따옴표 감싼 명령어 불가) /
#         구간 안 어느 단어든 rm|mv|tee|dd|truncate|sed|awk|perl|python*|xargs|sh|bash|eval|exec 이면 거짓(패턴 문자열 안이어도 —
#         안전 쪽 오판 허용) / find 의 -delete·-exec*·-ok*·-fprint*·-fls, rg 의 --pre*, sort 의 -o·--output·--compress-program,
#         date 의 -s·--set, uniq 의 피연산자 2개 이상(두 번째는 출력 파일) 금지.
#   잔존 한계: 문자열 판정이라 난독화 우회 여지는 기존과 같은 등급이다(쓰기 수단이 전부 막혀 있어 읽기만 열린다).
#   [역라우팅 — otest-4 실측] 구간 분할은 따옴표 인식으로 한다: 작은/큰따옴표 안의 | ; & 는 구분자가 아니다
#     (`grep -nE 'pipeline_start_time|ok_started' 파일` 이 잘려 차단되던 결함). 닫히지 않은 따옴표는 거짓.
#     $(·백틱·백슬래시·<(·>(·<<·'>' 는 따옴표 안이어도 계속 거짓(따옴표 안 메타문자가 판정을 흐리면 fail-closed).
#     따옴표로 묶인 단어도 영숫자·_.- 이외 문자로 다시 쪼개 금지 단어(rm 등)를 본다 — 패턴 안 'rm|mv' 도 거짓(보수).
# [cgit2 2026-10-27] git 조회 판정 확대(메인 활성 상태 분기 E·F-ASKQ-PROT 공용 — 둘 다 "읽기 전용인가"만 묻는다).
#   사용자 요구 "git 명령을 가드에서 막지 않도록" + 10:52 "위험한 git도 막지 말고". 메인의 git 쓰기는 W5(메인 위임 정책)가 막았으나
#   [unblock3 2026-10-27] 분기 G(_wg_main_git_only)가 git 구간·cd·읽기만으로 된 메인 명령을 허용한다(이 판정 자체는 무변경).
#   전역 옵션: -C <경로>·--no-pager·-c <안전 키>(color*·core.quotepath·core.abbrev·i18n.logoutputencoding·log.date·log.decorate).
#     실행을 바꾸는 -c(core.pager·core.hooksPath·core.sshCommand·core.fsmonitor·alias.*·diff.external 등)와 그 밖 전역 옵션은 거짓.
#   하위 명령: 종전 log·show·diff·status·rev-parse·blame·ls-files·describe·shortlog + rev-list·ls-tree,
#     cat-file 은 -p|-t|-s|-e <객체> 만, branch 는 목록 옵션만(이름 인자는 --list/-l 패턴일 때만 — 생성·삭제·이동·복사·추적 설정은 거짓).
#   호출자(_askq_ro_seg)의 금지어 조각 검사·-o/--output*·외부 명령 옵션 검사·리다이렉트/치환 금지는 그대로 적용된다.
_askq_git_ro() {
  local _i=1 _n=${#_ws[@]} _w _k _sub _j _v=0 _list=0
  while (( _i < _n )); do
    _w="${_ws[_i]}"
    case "$_w" in
      -C) (( _i + 1 < _n )) || return 1; _i=$((_i + 2)); continue ;;
      --no-pager) ;;
      -c) _k="${_ws[_i+1]:-}"; _k="${_k%%=*}"; _k="${_k,,}"
          case "$_k" in color|color.*|core.quotepath|core.abbrev|i18n.logoutputencoding|log.date|log.decorate) ;; *) return 1 ;; esac
          _i=$((_i + 2)); continue ;;
      -*) return 1 ;;
      *) break ;;
    esac
    _i=$((_i + 1))
  done
  (( _i < _n )) || return 1
  _sub="${_ws[_i]}"
  case "$_sub" in
    log|show|diff|status|rev-parse|blame|ls-files|describe|shortlog|rev-list|ls-tree) ;;
    cat-file) case "${_ws[_i+1]:-}" in -p|-t|-s|-e) ;; *) return 1 ;; esac
              (( _n - _i <= 3 )) || return 1 ;;
    branch)
      for ((_j = _i + 1; _j < _n; _j++)); do
        _w="${_ws[_j]}"
        if (( _v )); then _v=0; continue; fi
        case "$_w" in
          --list|-l) _list=1 ;;
          -a|--all|-r|--remotes|-v|-vv|--verbose|--show-current|--no-color|--color|--color=*|--no-column|--column|--column=*|-i|--ignore-case|--omit-empty|--abbrev=*|--no-abbrev|--sort=*|--format=*|--contains=*|--no-contains=*|--merged=*|--no-merged=*|--points-at=*) ;;
          --contains|--no-contains|--merged|--no-merged|--points-at|--sort|--format) _v=1 ;;
          -*) return 1 ;;
          *) (( _list )) || return 1 ;;
        esac
      done ;;
    *) return 1 ;;
  esac
  return 0
}
_askq_ro_seg() {  # 호출자의 _ws(단어 배열)·_fq(첫 단어에 따옴표) 를 본다 → 읽기 전용 구간이면 0
  local _first _w _p _nopnd=0 _xt="" _j _k _qs="" _pw
  [[ "${#_ws[@]}" -gt 0 && -z "$_fq" ]] || return 1
  # [TODO-021] 앞머리 로캘 대입(`LC_*=값`·`LANG=값`·`LANGUAGE=값`)과 `timeout [옵션] 기간` 은 벗기고 나머지 명령을 같은 기준으로 본다.
  #   로캘 변수는 코드를 실행하지 못한다. timeout 은 뒤 명령을 그대로 실행할 뿐이라 뒤 명령이 읽기 전용이면 읽기 전용이다.
  #   벗긴 뒤 명령어 자리 단어에 따옴표가 있으면 거짓(보수 — _fq 와 같은 취지). 그 밖의 대입 접두·옵션은 종전대로 거짓.
  while :; do
    if [[ "${#_ws[@]}" -gt 1 && -z "${_wqa[0]:-}" && "${_ws[0]}" =~ ^(LC_[A-Z]+|LANG|LANGUAGE)=[A-Za-z0-9_.@-]*$ ]]; then
      _ws=("${_ws[@]:1}"); _wqa=("${_wqa[@]:1}"); continue
    fi
    [[ "${_ws[0]}" == timeout ]] || break
    _k=1
    while (( _k < ${#_ws[@]} )); do
      case "${_ws[_k]}" in
        --foreground|--preserve-status|-v|--verbose|--signal=?*|--kill-after=?*|-s?*|-k?*) _k=$((_k + 1)) ;;
        -s|-k|--signal|--kill-after) _k=$((_k + 2)) ;;
        -*) return 1 ;;
        *) break ;;
      esac
    done
    [[ "${_ws[_k]:-}" =~ ^[0-9]+(\.[0-9]+)?[smhd]?$ ]] || return 1
    _k=$((_k + 1))
    (( _k < ${#_ws[@]} )) || return 1
    _ws=("${_ws[@]:_k}"); _wqa=("${_wqa[@]:_k}")
  done
  [[ -z "${_wqa[0]:-}" ]] || return 1
  _first="${_ws[0]}"
  # [K4 TODO-037 R-F] 치환 자리표시(_ASKQ_RF_TOK)가 든 단어가 있으면 머리 명령이 임의 인자에도 쓰기·실행이 없는 명령일 때만 참이다.
  if [[ -n "${_ASKQ_RF_TOK:-}" ]]; then
    for _w in "${_ws[@]}"; do
      [[ "$_w" == *"$_ASKQ_RF_TOK"* ]] || continue
      case "$_first" in
        grep|egrep|fgrep|cat|head|tail|wc|ls|stat|echo|basename|dirname|realpath|readlink|sha256sum|md5sum|nl|cut|test|'[') ;;
        *) return 1 ;;
      esac
    done
  fi
  # [사이클205 W2] 읽기 명령 보강 — echo·printf(-v 금지)·pwd·true·cd(비옵션 인자 ≤1)·basename·dirname·realpath·readlink·
  #   sha256sum·md5sum·nl, git(두 번째 단어가 조회 하위 명령일 때만·-o/--output* 금지), xargs(대상이 읽기 명령일 때만).
  #   금지어 조각 검사·리다이렉트·치환 금지는 그대로 적용된다(xargs 는 이 구간의 머리 단어에 한해 조각 검사에서 빠진다 — 루프가 [1:] 부터).
  case "$_first" in
    grep|egrep|fgrep|rg|cat|head|tail|wc|ls|stat|find|sort|uniq|cut|date|test|'[') ;;
    echo|printf|pwd|true|cd|basename|dirname|realpath|readlink|sha256sum|md5sum|nl) ;;
    tr) ;;   # [TODO-021] tr 는 표준입력→표준출력만 한다(파일 인자·쓰기 옵션 없음).
    ps|uptime|free|df) ;;   # [사이클205 D-8] 쓰기 수단 없는 조회 명령(ps 는 옵션 무관 읽기)
    jq) ;;   # [overblock P3c] jq 는 파일을 쓰지 않는다. 판본에 따라 있는 제자리 수정 옵션은 아래에서 거부한다.
    git) _askq_git_ro || return 1 ;;   # [cgit2] 전역 옵션·하위 명령 판정은 _askq_git_ro(아래 금지어·출력 옵션 검사는 그대로 적용)
    xargs) ;;
    *) return 1 ;;
  esac
  # [TODO-021] 검색 명령(grep 류·rg·jq)의 따옴표 인자(검색 패턴·jq 필터)는 실행되지 않는 자료라 금지어 조각 검사를 건너뛴다.
  #   `grep -c 'rm -rf' …`·`grep -o '"python3' …` 같은 대화 기록 조회가 막히던 과차단. 옵션 검사(rg --pre 등)는 그대로 본다.
  case "$_first" in grep|egrep|fgrep|rg|jq) _qs=1 ;; esac
  for ((_j = 1; _j < ${#_ws[@]}; _j++)); do
    _w="${_ws[_j]}"
    _pw="$_w"; [[ -n "$_qs" && -n "${_wqa[_j]:-}" ]] && _pw=""
    for _p in ${_pw//[^A-Za-z0-9_.-]/ }; do   # 조각 단위 금지 단어(glob 문자는 위 치환으로 이미 공백 — 확장 없음)
      case "$_p" in
        rm|mv|tee|dd|truncate|sed|awk|perl|python*|xargs|sh|bash|eval|exec) return 1 ;;
      esac
    done
    case "$_first" in
        find) case "$_w" in -delete|-exec|-execdir|-ok|-okdir|-fprint|-fprint0|-fprintf|-fls) return 1 ;; esac ;;
        rg)   case "$_w" in --pre|--pre=*|--pre-glob|--pre-glob=*) return 1 ;; esac ;;
        sort) case "$_w" in --output|--output=*|--compress-program|--compress-program=*) return 1 ;; --*) ;; -*o*) return 1 ;; esac ;;
        date) case "$_w" in --set|--set=*) return 1 ;; --*) ;; -*s*) return 1 ;; esac ;;
        # [사이클205 R-1] 단독 '-'(stdin) 도 피연산자로 센다 — `uniq - 출력파일` 이 읽기로 판정되던 결함.
        uniq) case "$_w" in -) _nopnd=$((_nopnd + 1)); [[ "$_nopnd" -ge 2 ]] && return 1 ;; -*) ;; *) _nopnd=$((_nopnd + 1)); [[ "$_nopnd" -ge 2 ]] && return 1 ;; esac ;;
        printf) [[ "$_w" == -v* ]] && return 1 ;;
        jq)   case "$_w" in -i|--in-place|--in-place=*) return 1 ;; esac ;;
        cd)   case "$_w" in -*) ;; *) _nopnd=$((_nopnd + 1)); [[ "$_nopnd" -ge 2 ]] && return 1 ;; esac ;;
        git)  case "$_w" in -o|--output*) return 1 ;; esac      # 정확히 -o·--output* 만(--oneline 은 통과)
              # [사이클206 교차검토(odev-4)] 외부 명령(페이저·외부 diff·텍스트 변환)을 부르는 옵션
              case "$_w" in -O*|--open-files-in-pager*|--ext-diff|--textconv) return 1 ;; esac ;;
        xargs) if [[ -z "$_xt" && "$_w" != -* ]]; then
                 _xt="$_w"
                 case "$_xt" in ls|cat|head|tail|wc|stat|grep|sha256sum|md5sum) ;; *) return 1 ;; esac
               fi ;;
    esac
  done
  [[ "$_first" == xargs && -z "$_xt" ]] && return 1   # 대상 없는 xargs(기본 echo)는 거짓
  return 0
}
_askq_ro_core() {   # [K4 TODO-037] 종전 _askq_ro_cmd 본체(치환 없는 명령 판정). 호출은 아래 _askq_ro_cmd 래퍼가 한다.
  local _c="$1" _s _i _n _ch _q="" _w="" _hw="" _fq="" _wq="" IFS=$' \t\n'
  local -a _ws=() _wqa=()   # [TODO-021] _wqa = 단어별 따옴표 포함 여부(_ws 와 같은 순서)
  local _rxn='(^|[^<>&0-9])([0-9]?|&)>>?[[:space:]]*/dev/null($|[[:space:];|&)])'
  [[ -n "${_c//[[:space:]]/}" ]] || return 1
  [[ "$_c" == *$'\n'* || "$_c" == *$'\r'* ]] && return 1
  case "$_c" in *'$('*|*'`'*|*'<('*|*'>('*|*'<<'*) return 1 ;; esac
  # [사이클206 NEW-O18·O19] 역슬래시는 ★작은따옴표 밖★에서만 거짓으로 본다 — 작은따옴표 안 역슬래시는 셸에서 글자 그대로라
  #   (`grep -o 'a\{0,7\}'`·`grep 'x\|y'` 같은 정규식 패턴) 실행 의미가 없다. 큰따옴표 안·따옴표 밖 역슬래시는 종전대로 거짓.
  #   oio && 분할기도 작은따옴표 안 역슬래시로 따옴표 상태가 바뀌지 않는다(작은따옴표만 짝으로 본다).
  local _nsq="" _sq2="" _dq2=""
  for ((_i = 0; _i < ${#_c}; _i++)); do
    _ch="${_c:_i:1}"
    if [[ -n "$_sq2" ]]; then [[ "$_ch" == "'" ]] && _sq2=""; continue; fi
    if [[ -n "$_dq2" ]]; then [[ "$_ch" == '"' ]] && _dq2=""; _nsq+="$_ch"; continue; fi
    case "$_ch" in "'") _sq2=1 ;; '"') _dq2=1; _nsq+="$_ch" ;; *) _nsq+="$_ch" ;; esac
  done
  [[ "$_nsq" == *'\'* ]] && return 1
  _s="${_c//2>\/dev\/null/ }"; _s="${_s//2>&1/ }"
  # [TODO-021] 출력을 /dev/null 로 버리는 꼴(`>/dev/null`·`2> /dev/null`·`&>/dev/null`·`>>/dev/null`)은 쓰기가 아니므로 지운다.
  #   /dev/null 바로 뒤가 공백·끝·; | & ) 일 때만 지운다(`/dev/null/…`·`/dev/nullx` 는 그대로 남아 아래 '>' 검사에 걸린다).
  while [[ "$_s" =~ $_rxn ]]; do _s="${_s/"${BASH_REMATCH[0]}"/"${BASH_REMATCH[1]} ${BASH_REMATCH[3]}"}"; done
  [[ "$_s" == *'>'* ]] && return 1
  # 따옴표 인식 분할 — 따옴표 밖의 공백은 단어, | ; && || 는 구간 경계, 단독 & 는 거짓.
  _n=${#_s}
  for ((_i = 0; _i < _n; _i++)); do
    _ch="${_s:_i:1}"
    if [[ -n "$_q" ]]; then
      if [[ "$_ch" == "$_q" ]]; then _q=""; else _w+="$_ch"; fi
      continue
    fi
    case "$_ch" in
      "'"|'"')
        _q="$_ch"; _hw=1; _wq=1
        [[ "${#_ws[@]}" -eq 0 ]] && _fq=1 ;;   # 명령어 자리의 따옴표('cat' 등)는 거짓 처리(보수)
      ' '|$'\t')
        if [[ -n "$_hw" ]]; then _ws+=("$_w"); _wqa+=("$_wq"); _w=""; _hw=""; _wq=""; fi ;;
      '|'|';'|'&')
        if [[ "$_ch" == '&' ]]; then
          [[ "${_s:_i+1:1}" == '&' ]] || return 1
          _i=$((_i + 1))
        elif [[ "$_ch" == '|' && "${_s:_i+1:1}" == '|' ]]; then
          _i=$((_i + 1))
        fi
        if [[ -n "$_hw" ]]; then _ws+=("$_w"); _wqa+=("$_wq"); _w=""; _hw=""; _wq=""; fi
        _askq_ro_seg || return 1
        _ws=(); _wqa=(); _fq="" ;;
      *) _w+="$_ch"; _hw=1 ;;
    esac
  done
  [[ -z "$_q" ]] || return 1   # 닫히지 않은 따옴표
  if [[ -n "$_hw" ]]; then _ws+=("$_w"); _wqa+=("$_wq"); fi
  _askq_ro_seg || return 1
  return 0
}
# [K4 TODO-037 R-F 2026-11-06] 명령 치환 재판정 래퍼 — `$(…)`·백틱 안쪽을 같은 규칙(_askq_ro_core)으로 다시 보고, 참이면 자리표시 %RFX% 로 바꿔 바깥을 판정한다.
#   거짓 유지: 중첩(안쪽에 ( ·백틱·자리표시), 닫힘 없음, 안쪽 거짓, $(( 산술, 개행, 9개 이상 치환.
#   자리표시가 든 구간은 머리 명령이 임의 인자에도 쓰기·실행이 없는 명령일 때만 참이다(_askq_ro_seg 의 [K4] 검사 —
#   치환 결과는 단어 분리로 옵션이 될 수 있어서 `find $(echo x -delete)`·`sort $(echo -o f)` 류를 막는다).
#   호출부 7곳(F-ASKQ-PROT·_askq_ro_redir·분기 E 정규화 안쪽·분기 E·unblock3 git 2곳·_askq_ro_cmd 자신)이 함께 넓어진다.
_askq_ro_cmd() {
  local _c="$1" _r _pre _post _in _g=0 _ASKQ_RF_TOK=""
  case "$_c" in *'$('*|*'`'*) ;; *) _askq_ro_core "$_c"; return ;; esac
  [[ "$_c" == *$'\n'* || "$_c" == *$'\r'* ]] && return 1
  _r="$_c"
  while [[ "$_r" == *'$('* ]]; do
    _g=$((_g + 1)); [[ $_g -le 8 ]] || return 1
    _pre="${_r%%'$('*}"; _post="${_r#*'$('}"
    [[ "$_post" == '('* ]] && return 1
    [[ "$_post" == *')'* ]] || return 1
    _in="${_post%%')'*}"
    [[ "$_in" == *'('* || "$_in" == *'`'* || "$_in" == *'%RFX%'* ]] && return 1
    _askq_ro_core "$_in" || return 1
    _r="${_pre}%RFX%${_post#*')'}"
  done
  while [[ "$_r" == *'`'* ]]; do
    _g=$((_g + 1)); [[ $_g -le 8 ]] || return 1
    _pre="${_r%%'`'*}"; _post="${_r#*'`'}"
    [[ "$_post" == *'`'* ]] || return 1
    _in="${_post%%'`'*}"
    [[ "$_in" == *'('* || "$_in" == *'%RFX%'* ]] && return 1
    _askq_ro_core "$_in" || return 1
    _r="${_pre}%RFX%${_post#*'`'}"
  done
  _ASKQ_RF_TOK='%RFX%'
  _askq_ro_core "$_r"
}
# [unblock3 ③ 2026-10-27] 메인 W5 git 해제 판정(분기 G 전용) — 사용자 지시 13:04 "남은 예외 세 가지도 막지 말고 다 풀어라" + 화면 결정 "메인 W5 해제".
#   참(0) = 명령 전체가 git 구간 + (cd 구간 | 엄격 읽기 구간 _askq_ro_cmd)으로만 이뤄지고 git 구간이 1개 이상이다. 상태·NTFS 경로는 묻지 않는다.
#   git 구간 = 머리(VAR=값·! 와 접두어 env/nohup/sudo/command(옵션 없을 때)·time(-p)·nice·timeout·stdbuf·exec·xargs(알려진 옵션만)를 벗긴
#     첫 단어)가 git·git.exe·/usr/bin/git·/usr/local/bin/git·/bin/git. git 의 전역 옵션(-C <경로>·--no-pager·-c k=v 등)·하위 명령은
#     순서·값과 무관하게 묻지 않는다(git 자체가 실행하는 alias '!…'·core.hooksPath·GIT_SSH_COMMAND 등도 git 으로 본다 — 사용자 결정 범위).
#   거짓(종전 메인 차단) = 개행(아래 heredoc 메시지 형태 제외)·CR·$(·백틱·<(·>(·<<·따옴표 밖 역슬래시·괄호·단독 &·|&·닫히지 않은 따옴표,
#     따옴표 밖 < > (2>/dev/null·2>&1·>/dev/null·1>/dev/null·&>/dev/null 은 지운 뒤 판정), git·cd·엄격 읽기가 아닌 구간이 하나라도 있으면.
#   heredoc 메시지 허용 형태(TAG 에 따옴표 필수 — 본문이 확장되지 않는다): `git … -m "$(cat <<'X'` … `X` … `)"` 와 명령 끝의 `git … -F - <<'X'` … `X`.
#     heredoc 이 git 구간이 아닌 곳에 붙어 있으면 거짓.
_wg_mgo_words() {  # $1=구간 원문 → _tw(따옴표 벗긴 단어 배열)
  local _x="$1" _k _ch _q="" _w="" _hw=0
  _tw=()
  for ((_k = 0; _k < ${#_x}; _k++)); do
    _ch="${_x:_k:1}"
    if [[ -n "$_q" ]]; then if [[ "$_ch" == "$_q" ]]; then _q=""; else _w+="$_ch"; fi; continue; fi
    case "$_ch" in
      "'"|'"') _q="$_ch"; _hw=1 ;;
      ' '|$'\t') if (( _hw )); then _tw+=("$_w"); _w=""; _hw=0; fi ;;
      *) _w+="$_ch"; _hw=1 ;;
    esac
  done
  if (( _hw )); then _tw+=("$_w"); fi
  return 0
}
_wg_mgo_isgit() {  # _tw 를 본다 → 머리가 git 이면 0
  local _k=0 _n=${#_tw[@]}
  while (( _k < _n )); do
    if [[ "${_tw[_k]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then _k=$((_k + 1)); continue; fi
    case "${_tw[_k]}" in
      '!') _k=$((_k + 1)) ;;
      env|nohup|sudo|command) _k=$((_k + 1)); [[ "${_tw[_k]:-}" == -* ]] && return 1 ;;   # 접두어 옵션은 받지 않는다(env -S 등이 머리를 바꾼다)
      time) _k=$((_k + 1)); [[ "${_tw[_k]:-}" == -p ]] && _k=$((_k + 1)) ;;
      nice) _k=$((_k + 1))
            case "${_tw[_k]:-}" in -n) _k=$((_k + 2)) ;; -[0-9]*|--adjustment=*) _k=$((_k + 1)) ;; -*) return 1 ;; esac ;;
      timeout) _k=$((_k + 1))
            while (( _k < _n )); do
              case "${_tw[_k]}" in
                -k|-s|--kill-after|--signal) _k=$((_k + 2)) ;;
                --kill-after=*|--signal=*|--foreground|--preserve-status|-v|--verbose) _k=$((_k + 1)) ;;
                -*) return 1 ;;
                *) break ;;
              esac
            done
            [[ "${_tw[_k]:-}" =~ ^[0-9]+(\.[0-9]+)?[smhd]?$ ]] || return 1
            _k=$((_k + 1)) ;;
      stdbuf) _k=$((_k + 1))
            while (( _k < _n )); do
              case "${_tw[_k]}" in -i|-o|-e) _k=$((_k + 2)) ;; -[ioe]?*|--input=*|--output=*|--error=*) _k=$((_k + 1)) ;; -*) return 1 ;; *) break ;; esac
            done ;;
      exec) _k=$((_k + 1))
            while (( _k < _n )); do
              case "${_tw[_k]}" in -a) _k=$((_k + 2)) ;; -c|-l|-cl|-lc) _k=$((_k + 1)) ;; -*) return 1 ;; *) break ;; esac
            done ;;
      xargs) _k=$((_k + 1))
            while (( _k < _n )); do
              case "${_tw[_k]}" in
                -0|-r|-t|-x|--null|--no-run-if-empty|--verbose|--exit|--replace) _k=$((_k + 1)) ;;
                -I|-a|-d|-E|-L|-n|-P|-s|--arg-file|--delimiter|--eof|--max-lines|--max-args|--max-procs|--max-chars) _k=$((_k + 2)) ;;
                -[IadELnPs]?*|--arg-file=*|--delimiter=*|--eof=*|--max-lines=*|--max-args=*|--max-procs=*|--max-chars=*|--replace=*) _k=$((_k + 1)) ;;
                -*) return 1 ;;
                *) break ;;
              esac
            done ;;
      *) break ;;
    esac
  done
  (( _k < _n )) || return 1
  case "${_tw[_k]}" in git|git.exe|/usr/bin/git|/usr/local/bin/git|/bin/git) return 0 ;; esac
  return 1
}
_wg_main_git_only() {  # $1=명령 → 참(0)이면 분기 G 통과
  local _c="$1" _cur _pre _tag _d _i _j _n _l _k _ch _q="" _s="" _seen=0
  local _rxc='^(.*)"\$\(cat[[:space:]]+<<(-?)[[:space:]]*(['"'"'"])([A-Za-z_][A-Za-z0-9_]*)(['"'"'"])[[:space:]]*$'
  local _rxf='^(.*[^<])<<(-?)[[:space:]]*(['"'"'"])([A-Za-z_][A-Za-z0-9_]*)(['"'"'"])[[:space:]]*$'
  local -a _lns=() _segs=() _tw=()
  [[ -n "${_c//[[:space:]]/}" ]] || return 1
  [[ "$_c" == *$'\r'* ]] && return 1
  _c="${_c%"${_c##*[!$'\n']}"}"   # 끝 개행 제거
  # 1) heredoc 메시지 평탄화 — 그 밖의 개행은 거짓
  mapfile -t _lns <<<"$_c"
  _n=${#_lns[@]}; _cur="${_lns[0]}"; _i=1
  while :; do
    if [[ "$_cur" =~ $_rxc ]]; then
      _pre="${BASH_REMATCH[1]}"; _d="${BASH_REMATCH[2]}"; _tag="${BASH_REMATCH[4]}"
      [[ "${BASH_REMATCH[3]}" == "${BASH_REMATCH[5]}" ]] || return 1
      for ((_j = _i; _j < _n; _j++)); do
        _l="${_lns[_j]}"; [[ -n "$_d" ]] && _l="${_l#"${_l%%[!$'\t']*}"}"
        [[ "$_l" == "$_tag" ]] && break
      done
      (( _j + 1 < _n )) || return 1
      [[ "${_lns[_j+1]}" =~ ^[[:space:]]*\)\"(.*)$ ]] || return 1
      _cur="${_pre}\"__WGMSG__\"${BASH_REMATCH[1]}"; _i=$((_j + 2))
      continue
    fi
    if [[ "$_cur" =~ $_rxf ]]; then
      _pre="${BASH_REMATCH[1]}"; _d="${BASH_REMATCH[2]}"; _tag="${BASH_REMATCH[4]}"
      [[ "${BASH_REMATCH[3]}" == "${BASH_REMATCH[5]}" ]] || return 1
      for ((_j = _i; _j < _n; _j++)); do
        _l="${_lns[_j]}"; [[ -n "$_d" ]] && _l="${_l#"${_l%%[!$'\t']*}"}"
        [[ "$_l" == "$_tag" ]] && break
      done
      (( _j == _n - 1 )) || return 1   # 명령 끝의 heredoc 만
      _cur="${_pre} __WGHD__"; _i=$_n
      break
    fi
    (( _i < _n )) && return 1
    break
  done
  # 2) 치환·heredoc 잔여·무해 리다이렉트
  case "$_cur" in *'$('*|*'`'*|*'<('*|*'>('*|*'<<'*) return 1 ;; esac
  _cur="${_cur//&>\/dev\/null/ }"; _cur="${_cur//2>\/dev\/null/ }"; _cur="${_cur//1>\/dev\/null/ }"
  _cur="${_cur//2>&1/ }"; _cur="${_cur//>\/dev\/null/ }"
  # 3) 따옴표 인식 구간 분리
  for ((_k = 0; _k < ${#_cur}; _k++)); do
    _ch="${_cur:_k:1}"
    if [[ -n "$_q" ]]; then [[ "$_ch" == "$_q" ]] && _q=""; _s+="$_ch"; continue; fi
    case "$_ch" in
      "'"|'"') _q="$_ch"; _s+="$_ch" ;;
      '\'|'('|')'|'<'|'>') return 1 ;;
      ';') _segs+=("$_s"); _s="" ;;
      '&') [[ "${_cur:_k+1:1}" == '&' ]] || return 1
           _k=$((_k + 1)); _segs+=("$_s"); _s="" ;;
      '|') if [[ "${_cur:_k+1:1}" == '|' ]]; then _k=$((_k + 1)); elif [[ "${_cur:_k+1:1}" == '&' ]]; then return 1; fi
           _segs+=("$_s"); _s="" ;;
      *) _s+="$_ch" ;;
    esac
  done
  [[ -z "$_q" ]] || return 1
  _segs+=("$_s")
  # 4) 구간 판정
  for _s in "${_segs[@]}"; do
    [[ -n "${_s//[[:space:]]/}" ]] || continue
    _wg_mgo_words "$_s"
    if _wg_mgo_isgit; then _seen=1; continue; fi
    [[ "$_s" == *__WGMSG__* || "$_s" == *__WGHD__* ]] && return 1
    if [[ "${_tw[0]}" == cd ]]; then
      _j=0
      for _l in "${_tw[@]:1}"; do
        case "$_l" in -L|-P|--) ;; -*) _j=9 ;; *) _j=$((_j + 1)) ;; esac
      done
      (( _j <= 1 )) && continue
      return 1
    fi
    _askq_ro_cmd "$_s" && continue
    return 1
  done
  (( _seen )) || return 1
  return 0
}
# [사이클206 D-12] PLAN 메인 /tmp 분기 D 전용 — 명령에 상대경로 쓰기 대상이 있거나 판정이 불확실하면 0(→ 분기 D 통과 안 함).
#   쓰기 대상: 리다이렉트(>·>>·&>·>|) 대상, tee 의 피연산자, cp|mv|ln|install|rsync 의 마지막 피연산자(-t/--target-directory 포함),
#   rm|rmdir|touch|truncate|mkdir|shred|unlink 의 피연산자, chmod|chown|chgrp 의 두 번째부터, sort -o/--output, uniq 두 번째 피연산자,
#   dd of=, sed -i·perl -i 의 파일 피연산자. 이 중 /·$·~ 로 시작하지 않는 것이 있으면 상대경로 쓰기다(cwd 는 추적하지 않는다 — 보수).
#   불확실(0): $(·백틱·<(·>(·닫히지 않은 따옴표·닫히지 않은 heredoc·한 줄에 heredoc 2개). heredoc 본문 줄은 데이터라 보지 않는다.
_wg_drw_fl() { if [[ $_hw -eq 1 ]]; then _tk+=("$_w"); fi; _w=""; _hw=0; }
_wg_drw_rel() {  # $1=쓰기 대상 → 상대경로(또는 판정 불가 변수)면 0. 분기 A 모드(_WG_TMODE=a)는 허용 영역 밖이면 0
  local _t="$1" _n _r
  [[ -n "$_t" && "$_t" != "-" ]] || return 1
  if [[ "${_WG_TMODE:-rel}" == lnk ]]; then _wg_lnk_wviol "$_t"; return $?; fi   # [사이클215 F-NEW-1-SH]
  if [[ "${_WG_TMODE:-rel}" == a ]]; then _wg_a_wok "$_t" && return 1; return 0; fi
  # [사이클206 교차검토] 변수로 시작하는 대상 — 같은 ; 사슬의 리터럴 대입(_dv)이면 값으로 바꿔 다시 보고, 아니면 판정 불가(0 = 차단 쪽).
  #   $HOME·$CLAUDE_CONFIG_DIR 계열은 분기 D 의 _D_OUT 정규식이 이미 /tmp 밖으로 본다(여기서도 차단 쪽).
  if [[ "$_t" =~ ^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?(.*)$ ]]; then
    _n="${BASH_REMATCH[1]}"; _r="${BASH_REMATCH[2]}"
    [[ "$_t" == '${'* && "$_t" != '${'"$_n"'}'* ]] && return 0   # ${V:-…}·${V#…} 등 확장 연산자 — 판정 불가
    [[ -n "${_dv[$_n]+x}" ]] || return 0
    _t="${_dv[$_n]}${_r}"
    [[ "$_t" == *'$'* ]] && return 0
  fi
  # [사이클206 교차검토(odev-4)] /tmp 아래 대상은 실경로로 다시 본다 — /tmp 의 심볼릭 링크를 거쳐 /tmp 밖(NTFS 소스 등)에 쓰는 경우.
  #   realpath -m 은 존재하는 상위 디렉터리까지 링크를 풀므로 아직 없는 파일도 상위 디렉터리 실경로로 판정된다.
  if [[ "$_t" == /tmp/* ]]; then
    _r=$(realpath -m -- "$_t" 2>/dev/null) || return 0
    [[ "$_r" == /tmp/* ]] || return 0
    return 1
  fi
  case "$_t" in /*|\~*) return 1 ;; esac
  return 0
}
# [사이클206 교차검토] 분기 D 공용 명령 머리 건너뛰기 — 호출자의 _cw·_k 를 실제 명령 위치로 옮긴다. 위험 환경변수 대입이면 1.
#   대입 접두·{ ! do then else if while until time sudo nohup command exec setsid builtin busybox 와
#   env·stdbuf·nice·timeout·ionice·chrt·taskset(옵션·옵션 인자·기간·NAME=값 포함)을 걷어 낸다(`env cp /tmp/a notes.txt` 를 cp 로 본다).
_WG_DX_DANGER='^(PATH|LD_.*|BASH_ENV|ENV|BASH_FUNC_.*|IFS|PROMPT_COMMAND|PS4|SHELLOPTS|BASHOPTS|CDPATH|PYTHON.*|PERL5.*|PERLLIB|NODE_.*|RUBYOPT|RUBYLIB|GIT_.*|GCONV_PATH|LOCPATH)$'
_wg_d_skiphead() {
  local _t _x _w
  while [[ $_k -lt ${#_cw[@]} ]]; do
    _t="${_cw[_k]}"
    if [[ "$_t" =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]]; then
      [[ "${BASH_REMATCH[1]}" =~ $_WG_DX_DANGER ]] && return 1
      _k=$((_k + 1)); continue
    fi
    _w="${_t##*/}"
    case "$_w" in
      '{'|'!'|do|then|else|elif|if|while|until|time|sudo|nohup|command|exec|setsid|builtin|busybox) _k=$((_k + 1)); continue ;;
      env|stdbuf|nice|timeout|ionice|chrt|taskset)
        _k=$((_k + 1))
        while [[ $_k -lt ${#_cw[@]} ]]; do
          _x="${_cw[_k]}"
          if [[ "$_x" =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]]; then
            [[ "${BASH_REMATCH[1]}" =~ $_WG_DX_DANGER ]] && return 1
            _k=$((_k + 1)); continue
          fi
          case "$_x" in
            -u|-n|-s|-k|-c|-C|-S|-o|-e|-p|--signal|--kill-after|--unset|--chdir|--adjustment|--split-string) _k=$((_k + 2)); continue ;;
            -*) _k=$((_k + 1)); continue ;;
          esac
          if [[ "$_w" =~ ^(timeout|chrt|taskset)$ && "$_x" =~ ^[0-9.a-fx,]+[smhd]?$ ]]; then _k=$((_k + 1)); continue; fi
          break
        done
        continue ;;
    esac
    break
  done
  return 0
}
_wg_drw_seg() {  # 호출자의 _sg(구간 토큰 배열) → 상대경로 쓰기 대상이 있으면 0, 판정 불가면 0
  local -a _cw=() _op=()
  local _k _m=${#_sg[@]} _cmd _b _x _skipn=0 _nopt=0 _i_on=0 _scr=0 _tgt="" _lnn=0
  for ((_k = 0; _k < _m; _k++)); do
    case "${_sg[_k]}" in
      __WG_GT__) _k=$((_k + 1)); [[ $_k -lt $_m ]] || return 0; _wg_drw_rel "${_sg[_k]}" && return 0 ;;
      __WG_LT__) _k=$((_k + 1)) ;;
      *) _cw+=("${_sg[_k]}") ;;
    esac
  done
  # 순수 대입 구간(; 사슬 머리·끝이 ; 개행 시작 끝) — 리터럴 값이면 _dv 에 기록(뒤 구간의 $F 대상 판정용)
  if [[ ${#_cw[@]} -gt 0 && ( "$_sp" == S || "$_sp" == START ) && ( "$_sn" == S || "$_sn" == END ) ]]; then
    local _allas=1
    for _x in "${_cw[@]}"; do [[ "$_x" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || { _allas=0; break; }; done
    if [[ $_allas -eq 1 ]]; then
      for _x in "${_cw[@]}"; do
        if [[ "${_x#*=}" != *[\$\`\(\)\\]* && -n "${_x#*=}" ]]; then _dv[${_x%%=*}]="${_x#*=}"
        elif [[ "${_WG_TMODE:-rel}" == a && "${_x#*=}" != *[\`\(\)\\]* ]] && _wg_a_path "${_x#*=}"; then _dv[${_x%%=*}]="$_WG_AP"   # 분기 A: ~·$HOME·설정 경로 대입
        else unset "_dv[${_x%%=*}]"; fi
      done
      return 1
    fi
  fi
  _k=0
  _wg_d_skiphead || return 0
  while [[ $_k -lt ${#_cw[@]} && "${_cw[_k]}" == xargs ]]; do
    _k=$((_k + 1))
    while [[ $_k -lt ${#_cw[@]} && "${_cw[_k]}" == -* ]]; do
      case "${_cw[_k]}" in -n|-I|-L|-P|-d|-s|-E|-a) _k=$((_k + 2)) ;; *) _k=$((_k + 1)) ;; esac
    done
  done
  [[ $_k -lt ${#_cw[@]} ]] || return 1
  _cmd="${_cw[_k]}"; _b="${_cmd##*/}"
  # 피연산자·옵션 수집(옵션 인자를 받는 옵션은 다음 단어를 건너뛴다)
  local _endopt=0 _w2
  for ((_k = _k + 1; _k < ${#_cw[@]}; _k++)); do
    _w2="${_cw[_k]}"
    if [[ $_skipn -eq 1 ]]; then
      _skipn=0
      case "$_x" in -t|--target-directory|-o|--output) _wg_drw_rel "$_w2" && return 0 ;; -e|-f) _scr=1 ;; esac
      continue
    fi
    if [[ $_endopt -eq 0 && "$_w2" == -?* ]]; then
      [[ "$_w2" == "--" ]] && { _endopt=1; continue; }
      _x="$_w2"
      [[ "$_b" == ln && ( "$_w2" == --no-dereference || "$_w2" == --no-target-directory || "$_w2" =~ ^-[^-]*[nT] ) ]] && _lnn=1   # [사이클215] ln -n/-T = 링크 노드 교체
      case "$_b" in
        cp|mv|ln|install)
          case "$_w2" in -t|--target-directory) _skipn=1 ;; --target-directory=*) _wg_drw_rel "${_w2#*=}" && return 0 ;;
                         -S|--suffix|-m|--mode|-o|--owner|-g|--group) [[ "$_b" == install || "$_w2" == -S || "$_w2" == --suffix ]] && { _x="-skip"; _skipn=1; } ;;
                         -[!-]*t) _x="-t"; _skipn=1 ;; esac ;;
        truncate) case "$_w2" in -s|-r|--size|--reference) _x="-skip"; _skipn=1 ;; esac ;;
        mkdir)    case "$_w2" in -m|--mode) _x="-skip"; _skipn=1 ;; esac ;;
        touch)    case "$_w2" in -d|-r|-t|--date|--reference) _x="-skip"; _skipn=1 ;; esac ;;
        shred)    case "$_w2" in -n|-s|--iterations|--size) _x="-skip"; _skipn=1 ;; esac ;;
        sort)     case "$_w2" in -o|--output) _x="-o"; _skipn=1 ;; --output=*) _wg_drw_rel "${_w2#*=}" && return 0 ;;
                                 -[!-]*o) _x="-o"; _skipn=1 ;; -[!-]*o*) _wg_drw_rel "${_w2#*o}" && return 0 ;;
                                 -k|-t|-S|-T|--key|--field-separator|--buffer-size|--temporary-directory) _x="-skip"; _skipn=1 ;; esac ;;
        uniq)     case "$_w2" in -f|-s|-w) _x="-skip"; _skipn=1 ;; esac ;;
        sed|perl) case "$_w2" in -i*|--in-place*) _i_on=1 ;; -e|-f) _skipn=1 ;; -[!-]*i*) _i_on=1 ;; esac
                  [[ "$_b" == perl && "$_w2" == -*i* ]] && _i_on=1 ;;
        rsync)    case "$_w2" in -e|--rsh) _x="-skip"; _skipn=1 ;; esac ;;
      esac
      continue
    fi
    _op+=("$_w2")
  done
  [[ $_skipn -eq 1 ]] && return 0   # 옵션 인자 누락 — 판정 불가
  case "$_b" in
    tee|rm|rmdir|touch|truncate|mkdir|shred|unlink)
      for _x in "${_op[@]}"; do _wg_drw_rel "$_x" && return 0; done ;;
    chmod|chown|chgrp)
      for _x in "${_op[@]:1}"; do _wg_drw_rel "$_x" && return 0; done ;;
    cp|mv|ln|install)
      [[ "$_b" == ln && ${#_op[@]} -eq 1 ]] && return 0   # ln 피연산자 1개 = cwd 에 링크 생성(상대 쓰기)
      [[ ${#_op[@]} -ge 2 ]] && _wg_drw_rel "${_op[${#_op[@]}-1]}" && return 0 ;;
    rsync)
      if [[ ${#_op[@]} -ge 2 ]]; then _tgt="${_op[${#_op[@]}-1]}"; [[ "$_tgt" == *:* ]] || { _wg_drw_rel "$_tgt" && return 0; }; fi ;;
    uniq)
      [[ ${#_op[@]} -ge 2 ]] && _wg_drw_rel "${_op[1]}" && return 0 ;;
    dd)
      for _x in "${_op[@]}"; do [[ "$_x" == of=* ]] && _wg_drw_rel "${_x#of=}" && return 0; done ;;
    sed|perl)
      if [[ $_i_on -eq 1 ]]; then
        local _st=0; [[ $_scr -eq 1 ]] && _st=1
        for _x in "${_op[@]}"; do
          if [[ $_st -eq 0 ]]; then _st=1; continue; fi   # 첫 비옵션 = 스크립트(-e/-f 가 없을 때)
          _wg_drw_rel "$_x" && return 0
        done
      fi ;;
  esac
  return 1
}
_wg_d_tok() {  # $1=명령 → 호출자의 _tk 배열에 토큰(구분자 __WG_SEP__, 리다이렉트 __WG_GT__/__WG_LT__). 판정 불확실이면 1
  local _c="$1" _l _t _txt="" _mk="" _i _n _ch _q="" _w="" _hw=0 _nx
  local _hre="<<-?[[:space:]]*[\"']?([A-Za-z0-9_]+)"
  _tk=()
  case "$_c" in *'$('*|*'`'*|*'<('*|*'>('*) return 1 ;; esac
  _c="${_c//<<</ < }"
  if [[ "$_c" == *'<<'* ]]; then
    while IFS= read -r _l || [[ -n "$_l" ]]; do
      if [[ -n "$_mk" ]]; then
        _t="${_l#"${_l%%[![:space:]]*}"}"; _t="${_t%"${_t##*[![:space:]]}"}"
        [[ "$_t" == "$_mk" ]] && _mk=""
        continue
      fi
      [[ "$_l" == *'<<'*'<<'* ]] && return 1
      [[ "$_l" =~ $_hre ]] && _mk="${BASH_REMATCH[1]}"
      _txt+="$_l"$'\n'
    done <<<"$_c"
    [[ -z "$_mk" ]] || return 1
    _c="$_txt"
  fi
  _n=${#_c}
  for ((_i = 0; _i < _n; _i++)); do
    _ch="${_c:_i:1}"
    if [[ -n "$_q" ]]; then
      if [[ "$_ch" == "$_q" ]]; then _q=""
      elif [[ "$_q" == '"' && "$_ch" == '\' && $((_i + 1)) -lt $_n ]]; then _i=$((_i + 1)); _w+="${_c:_i:1}"
      else _w+="$_ch"; fi
      continue
    fi
    _nx="${_c:_i+1:1}"
    case "$_ch" in
      "'"|'"') _q="$_ch"; _hw=1 ;;
      '\') _hw=1; if [[ $((_i + 1)) -lt $_n ]]; then _i=$((_i + 1)); _w+="${_c:_i:1}"; fi ;;
      ' '|$'\t') _wg_drw_fl ;;
      '>')
        [[ "$_w" =~ ^[0-9]+$ ]] && { _w=""; _hw=0; }
        _wg_drw_fl
        [[ "$_nx" == '>' || "$_nx" == '|' || "$_nx" == '&' ]] && _i=$((_i + 1))
        _tk+=("__WG_GT__") ;;
      '<')
        [[ "$_w" =~ ^[0-9]+$ ]] && { _w=""; _hw=0; }
        _wg_drw_fl
        while [[ "${_c:_i+1:1}" == '<' ]]; do _i=$((_i + 1)); done
        [[ "${_c:_i+1:1}" == '-' ]] && _i=$((_i + 1))
        _tk+=("__WG_LT__") ;;
      '&')
        if [[ "$_nx" == '>' ]]; then
          _wg_drw_fl; _i=$((_i + 1)); [[ "${_c:_i+1:1}" == '>' ]] && _i=$((_i + 1)); _tk+=("__WG_GT__")
        else
          _wg_drw_fl
          if [[ "$_nx" == '&' ]]; then _i=$((_i + 1)); _tk+=("__WG_AND__"); else _tk+=("__WG_OTH__"); fi
        fi ;;
      ';'|$'\n') _wg_drw_fl; _tk+=("__WG_SEP__") ;;
      '|')
        _wg_drw_fl
        if [[ "$_nx" == '|' ]]; then _i=$((_i + 1)); _tk+=("__WG_OTH__"); else _tk+=("__WG_PIPE__"); fi ;;
      '('|')') _wg_drw_fl; _tk+=("__WG_OTH__") ;;
      *) _w+="$_ch"; _hw=1 ;;
    esac
  done
  [[ -z "$_q" ]] || return 1
  _wg_drw_fl
  _tk+=("__WG_END__")
  return 0
}
# 구분자 토큰: __WG_SEP__(; 개행) __WG_PIPE__(|) __WG_AND__(&&) __WG_OTH__(|| & 괄호) __WG_END__(끝).
#   판정 함수는 _sg(구간 토큰)·_sp(앞 구분자 START/S/P/A/O)·_sn(뒤 구분자 S/P/A/O/END)·_dv(리터럴 대입 표)를 본다.
#   _dv 는 oio 가 별도 셸로 나누는 && 와 서브셸·백그라운드 경계(|| & 괄호)에서 비운다.
_wg_d_each() {  # $1=명령 $2=구간 판정 함수 → 판정 함수가 참인 구간이 있거나 토큰화 불확실이면 0
  local -a _tk=() _sg=()
  local -A _dv=()
  local _t _sp=START _sn
  _wg_d_tok "$1" || return 0
  for _t in "${_tk[@]}"; do
    case "$_t" in
      __WG_SEP__|__WG_PIPE__|__WG_AND__|__WG_OTH__|__WG_END__)
        case "$_t" in __WG_SEP__) _sn=S ;; __WG_PIPE__) _sn=P ;; __WG_AND__) _sn=A ;; __WG_OTH__) _sn=O ;; *) _sn=END ;; esac
        if [[ ${#_sg[@]} -gt 0 ]]; then "$2" && return 0; fi
        _sg=(); _sp="$_sn"
        [[ "$_sn" == A || "$_sn" == O ]] && _dv=()
        ;;
      *) _sg+=("$_t") ;;
    esac
  done
  return 1
}
_wg_d_relw() { _wg_d_each "$1" _wg_drw_seg; }  # $1=명령(무해 리다이렉트 제거본) → 상대경로 쓰기 대상 있음·불확실이면 0
# [사이클206 (b)] 분기 D 전용 실행 판정 — /tmp 를 언급한 명령이 스크립트·해석기·실행 수단을 부르면 0(→ 분기 D 통과 안 함, 분기 E 엄격 판정으로).
#   ① 위험 환경변수 대입(PATH·LD_*·BASH_ENV·ENV·IFS·PYTHON*·PERL5*·NODE_*·RUBY*·GIT_* 등 — 독립 대입·접두 대입·env 인자 모두)
#   ② 명령 자리에 경로(/tmp/x.sh·./x·../x·dir/x — /usr/bin·/bin·/sbin·/usr/local/bin 아래 시스템 명령은 제외)
#   ③ 셸·해석기(bash·sh·source·.·eval·python*·perl·ruby·node·php·lua 등), awk 의 system·getline·파이프·리다이렉트·-f,
#      find 의 -exec*·-ok*·-delete·-fprint*·-fls, 읽기 명령이 아닌 xargs 대상.
#   env·nohup·nice·timeout·time·command·exec·setsid·stdbuf·sudo·busybox 접두는 걷어 내고 실제 명령을 본다(_wg_d_skiphead).
#   [사이클206 교차검토] 금지 목록이 아니라 ★허용 목록★으로 판정한다 — 아래 읽기 명령·쓰기 명령(대상은 _wg_d_relw·_D_OUT 가 본다) 밖의 명령
#   (tar·unzip·patch·git 쓰기 하위 명령·make·npm·pip·dotnet·해석기 등)은 분기 D 를 통과하지 않는다. /tmp 읽기(cat·ls·grep)는 종전대로 통과.
#   ①은 종전 설명과 같다. 순수 대입 구간은 실행이 아니다(위험 이름만 거부).
_wg_dx_seg() {  # 호출자의 _sg → 실행 수단(또는 허용 목록 밖 명령)이면 0
  local -a _cw=()
  local _k _t _b _x _xt="" _sub=""
  for ((_k = 0; _k < ${#_sg[@]}; _k++)); do
    case "${_sg[_k]}" in __WG_GT__|__WG_LT__) _k=$((_k + 1)) ;; *) _cw+=("${_sg[_k]}") ;; esac
  done
  _k=0
  _wg_d_skiphead || return 0
  [[ $_k -lt ${#_cw[@]} ]] || return 1
  _t="${_cw[_k]}"; _b="${_t##*/}"
  if [[ "$_t" == */* ]]; then
    case "$_t" in /usr/bin/*|/usr/sbin/*|/bin/*|/sbin/*|/usr/local/bin/*) ;; *) return 0 ;; esac
  fi
  case "$_b" in
    # 읽기·조회 명령(쓰기 수단 없음)
    ls|cat|head|tail|wc|stat|file|grep|egrep|fgrep|rg|uniq|cut|tr|diff|cmp|comm|join|paste|column|fold|fmt|nl|tac|rev|od|xxd|hexdump|strings|\
    du|df|free|uptime|ps|date|echo|printf|sleep|true|false|test|'['|basename|dirname|realpath|readlink|pwd|cd|md5sum|sha1sum|sha256sum|sha512sum|\
    base64|jq|tree|id|whoami|hostname|uname|nproc|seq|expr|printenv|zcat|zgrep|wait|type|which|cksum|sum|numfmt|expand|unexpand|split|csplit)
      case "$_b" in
        split|csplit) return 0 ;;   # 출력 파일을 cwd 에 만든다(상대 쓰기)
        rg)   # [사이클206 교차검토(odev-4)] 외부 명령을 부르는 옵션
          for _x in "${_cw[@]:_k+1}"; do case "$_x" in --pre|--pre=*|--pre-glob|--pre-glob=*) return 0 ;; esac; done ;;
      esac
      return 1 ;;
    sort)   # -o 대상은 _wg_d_relw 가 본다. 압축 프로그램 지정 옵션은 외부 명령 실행
      for _x in "${_cw[@]:_k+1}"; do case "$_x" in --compress-program|--compress-program=*) return 0 ;; esac; done
      return 1 ;;
    # 쓰기 명령 — 대상 경로 판정은 _wg_d_relw·_D_OUT 가 한다
    rm|rmdir|mv|cp|tee|dd|truncate|chmod|chown|chgrp|ln|install|touch|mkdir|rsync|shred|unlink) return 1 ;;
    sed)
      # -i 는 쓰기(대상은 _wg_d_relw). 스크립트의 w/W(파일 쓰기)·e(명령 실행) 명령·s///w·s///e 플래그는 실행 수단으로 본다(보수).
      for _x in "${_cw[@]:_k+1}"; do
        [[ "$_x" == -* ]] && continue
        if [[ "$_x" =~ (^|[;{}[:space:]])[0-9,\$!/]*[eWw]([[:space:]]|$|\;) ]] || [[ "$_x" =~ /[gpIiMm0-9]*[eWw]([[:space:]]|$|\;|\}) ]]; then return 0; fi
      done
      return 1 ;;
    awk|gawk|mawk|nawk)
      for _x in "${_cw[@]:_k+1}"; do
        case "$_x" in -f|-f*|--file|--file=*|*system*|*getline*|*'|'*|*'>'*) return 0 ;; esac
      done ;;
    find)
      for _x in "${_cw[@]:_k+1}"; do
        case "$_x" in -exec|-execdir|-ok|-okdir|-delete|-fprint|-fprint0|-fprintf|-fls) return 0 ;; esac
      done ;;
    xargs)
      for ((_k = _k + 1; _k < ${#_cw[@]}; _k++)); do
        _x="${_cw[_k]}"
        case "$_x" in -n|-I|-L|-P|-d|-s|-E|-a|--max-args|--max-procs|--delimiter|--arg-file) _k=$((_k + 1)); continue ;; -*) continue ;; esac
        _xt="${_x##*/}"; break
      done
      case "$_xt" in ls|cat|head|tail|wc|stat|grep|sha256sum|md5sum|file) ;; *) return 0 ;; esac ;;
    git)
      # 조회 하위 명령만(작업트리·저장소를 바꾸는 checkout·apply·reset·clean·commit 등은 실행 수단). -c·-C 등 전역 옵션도 거부(보수).
      _sub="${_cw[_k+1]:-}"
      case "$_sub" in log|show|diff|status|rev-parse|blame|ls-files|describe|shortlog|grep|cat-file|ls-tree|branch|tag|remote) ;; *) return 0 ;; esac
      for _x in "${_cw[@]:_k+2}"; do case "$_x" in -o|--output|--output=*|-D|-d|-m|-M|--delete|--move|--set-upstream-to=*|add|rm|rename|set-url|prune) return 0 ;; esac; done
      # [사이클206 교차검토(odev-4)] 외부 명령(페이저·외부 diff·텍스트 변환)을 부르는 옵션
      for _x in "${_cw[@]:_k+2}"; do case "$_x" in -O*|--open-files-in-pager*|--ext-diff|--textconv) return 0 ;; esac; done
      case "$_sub" in branch|tag|remote) [[ ${#_cw[@]} -le $((_k + 2)) ]] || { for _x in "${_cw[@]:_k+2}"; do [[ "$_x" == -* ]] || return 0; done; } ;; esac ;;
    tar)
      # 목록(-t) 만 읽기. 추출·생성·추가(-x -c -r -u -A)는 쓰기(cwd·-f 대상) — 실행 수단으로 본다.
      _x="${_cw[*]:_k+1}"
      [[ "$_x" =~ (^|[[:space:]])(-?[A-Za-z]*t[A-Za-z]*|--list)([[:space:]]|$) ]] || return 0
      [[ "$_x" =~ (^|[[:space:]])-?[A-Za-z]*[xcruA][A-Za-z]*([[:space:]]|$)|--extract|--create|--append|--update|--to-command|--use-compress-program|-I([[:space:]]|$) ]] && return 0
      # [사이클206 교차검토(odev-4)] 목록 모드에서도 외부 명령을 부르는 옵션(체크포인트 동작·볼륨 스크립트·원격 셸·압축 프로그램)
      for _x in "${_cw[@]:_k+1}"; do
        case "$_x" in --checkpoint-action*|--info-script*|--new-volume-script*|-F|-F*|--rsh-command*|--rmt-command*|--use-compress*) return 0 ;; esac
      done ;;
    *) return 0 ;;   # 허용 목록 밖(unzip·patch·make·npm·pip·dotnet·cmake·해석기·셸 등)
  esac
  return 1
}
_wg_d_exec() { _wg_d_each "$1" _wg_dx_seg; }  # $1=명령 → 실행 수단 있음·불확실이면 0
# [사이클206 분기 A 정밀화] 메인 PLAN 오케스트레이션 허용(분기 A)은 종전에 명령에 .claude/·session-env/ 글자만 있으면 전체를 허용했다
#   (실측: `rm -rf <AI>/src; ls ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/`·`bash /tmp/x.sh ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/` 가 live rc=0). 이제 아래가 모두 참일 때만 허용한다.
#   ① 쓰기 대상(리다이렉트·쓰기 명령 대상)이 전부 허용 영역 — <설정>/… 또는 …/session-env/…(hooks/·skills/·settings*.json 제외), /tmp/…, /dev/null 류.
#      변수 경로는 ~·$HOME·$CLAUDE_CONFIG_DIR·${CLAUDE_CONFIG_DIR:-$HOME/.claude}·같은 ; 사슬의 대입값으로 풀고, 하네스가 넣은 환경변수(대입 없는 $UUID 등)는
#      경로 한 조각으로 본다(잔존 한계: 그런 환경변수 값에 ../ 가 든 경우는 정적으로 알 수 없다).
#   ② 실행 수단 없음 — 분기 D 허용 목록 명령, 또는 신뢰 스크립트(…/.claude/hooks/·…/.claude/skills/ 아래, realpath 기준) 를 bash·sh·source·.·python3 로
#      실행하는 것, bash -c '<코드>'(코드도 같은 기준으로 재귀 판정, 2단계까지), state_machine 함수(status_add 등 — 경로 인자는 ① 기준).
#      그 밖 셸·해석기(-c·-m·- 포함)·/tmp 스크립트·eval·위험 환경변수 대입은 불허.
_wg_a_path() {  # $1=경로 단어 → 정규화 절대경로를 _WG_AP 에(알 수 없으면 1)
  local _p="$1" _cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" _n _r _o="" _g=0
  _WG_AP=""
  [[ "$_p" == "~" || "$_p" == "~/"* ]] && _p="${HOME}${_p:1}"
  if [[ "$_p" =~ ^\$\{CLAUDE_CONFIG_DIR:-(\$HOME|\$\{HOME\})/\.claude\}(.*)$ ]]; then _p="${_cfg}${BASH_REMATCH[2]}"
  elif [[ "$_p" =~ ^\$\{?CLAUDE_CONFIG_DIR\}?(/.*)?$ ]]; then [[ -n "${CLAUDE_CONFIG_DIR:-}" ]] || return 1; _p="${CLAUDE_CONFIG_DIR}${BASH_REMATCH[1]}"
  elif [[ "$_p" =~ ^\$\{?HOME\}?(/.*)?$ ]]; then _p="${HOME}${BASH_REMATCH[1]}"
  elif [[ "$_p" =~ ^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?(/.*)?$ ]]; then
    _n="${BASH_REMATCH[1]}"; _r="${BASH_REMATCH[2]}"
    [[ -n "${_dv[$_n]+x}" ]] || return 1
    _p="${_dv[$_n]}${_r}"
  fi
  [[ "$_p" == /* ]] || return 1
  # 경로 안쪽 변수 — 같은 사슬 대입값으로 바꾸고, 대입 없는 환경변수는 한 조각 자리표시로 둔다(값에 / 가 없다고 가정 — 위 잔존 한계)
  #   단순형 $NAME·${NAME} 만 인정한다(`${V:-../x}` 같은 확장 연산자는 값에 ../ 가 숨을 수 있어 판정 불가 → 1).
  while [[ "$_p" =~ ^([^$]*)\$(\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))(.*)$ ]]; do
    _g=$((_g + 1)); [[ $_g -le 8 ]] || return 1
    _n="${BASH_REMATCH[3]}${BASH_REMATCH[4]}"
    if [[ -n "${_dv[$_n]+x}" ]]; then _p="${BASH_REMATCH[1]}${_dv[$_n]}${BASH_REMATCH[5]}"
    else _p="${BASH_REMATCH[1]}_wgvar_${BASH_REMATCH[5]}"; fi
  done
  [[ "$_p" != *'$'* ]] || return 1
  _WG_AP=$(realpath -m -- "$_p" 2>/dev/null) || return 1
  [[ -n "$_WG_AP" ]]
}
_wg_a_wok() {  # $1=쓰기 대상 → 분기 A 허용 영역이면 0
  _wg_a_path "$1" || return 1
  case "$_WG_AP" in /dev/null|/dev/stdout|/dev/stderr) return 0 ;; esac
  case "$_WG_AP" in
    */.claude/hooks|*/.claude/hooks/*|*/.claude/skills|*/.claude/skills/*|*/.claude/settings.json|*/.claude/settings.local.json) return 1 ;;
  esac
  case "$_WG_AP" in /tmp/*|*/.claude/*|*/session-env/*) return 0 ;; esac
  return 1
}
_wg_a_trusted() {  # $1=스크립트 경로 → 신뢰 스크립트면 0
  # [사이클206 교차검토(odev-4)] 신뢰 범위는 정본 hooks 의 lib/ 바로 아래 파일과 hooks/ 최상위 hook 파일로 한정한다.
  #   candidates/·tests/·backup/·logs/ 등 하위 폴더와 skills/ 는 팀원이 파일 도구로 쓸 수 있어 신뢰하지 않는다.
  #   정본 hooks 위치는 이 write_guard.sh 가 있는 트리(…/.claude/hooks — realpath)와 ${HARNESS_HOME:-$HOME/.harness}/current/hooks(realpath)다.
  local _hr _h2 _rel _h
  [[ -n "$1" ]] || return 1
  _wg_a_path "$1" || return 1
  [[ "$_WG_AP" != *_wgvar_* ]] || return 1
  _hr=$(realpath -m -- "${HARNESS_HOME:-$HOME/.harness}/current/hooks" 2>/dev/null)
  _h2=$(realpath -m -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null)
  for _h in "$_hr" "$_h2"; do
    [[ -n "$_h" && "$_h" == */.claude/hooks && "$_WG_AP" == "$_h"/* ]] || continue
    _rel="${_WG_AP#"$_h"/}"
    [[ "$_rel" != */* ]] && return 0                       # 최상위 hook 파일
    [[ "$_rel" == lib/* && "${_rel#lib/}" != */* ]] && return 0   # lib/ 바로 아래
  done
  return 1
}
_wg_a_seg() {  # 호출자의 _sg·_sp·_sn·_dv → 분기 A 로 허용할 수 없는 구간이면 0
  local -a _cw=()
  local _k _t _b _x _i _code
  _WG_TMODE=a _wg_drw_seg && return 0
  for ((_k = 0; _k < ${#_sg[@]}; _k++)); do
    case "${_sg[_k]}" in __WG_GT__|__WG_LT__) _k=$((_k + 1)) ;; *) _cw+=("${_sg[_k]}") ;; esac
  done
  _k=0
  _wg_d_skiphead || return 0
  [[ $_k -lt ${#_cw[@]} ]] || return 1
  _t="${_cw[_k]}"; _b="${_t##*/}"
  case "$_b" in
    bash|sh)
      for ((_i = _k + 1; _i < ${#_cw[@]}; _i++)); do
        _x="${_cw[_i]}"
        [[ "$_x" == -* ]] || break
        if [[ "$_x" =~ ^-[A-Za-z]*c[A-Za-z]*$ ]]; then
          _code="${_cw[_i+1]:-}"
          [[ -n "$_code" && ${_WG_A_DEPTH:-0} -lt 2 ]] || return 0
          _WG_A_DEPTH=$((${_WG_A_DEPTH:-0} + 1)) _wg_a_ok "$_code" && return 1
          return 0
        fi
      done
      [[ $_i -lt ${#_cw[@]} ]] || return 0
      _wg_a_trusted "${_cw[_i]}" && return 1
      return 0 ;;
    source|.)
      _wg_a_trusted "${_cw[_k+1]:-}" && return 1
      return 0 ;;
    python|python3)
      for ((_i = _k + 1; _i < ${#_cw[@]}; _i++)); do
        _x="${_cw[_i]}"
        [[ "$_x" == -* ]] || break
        case "$_x" in -|-c|-m|-*c|-*m) return 0 ;; esac
      done
      [[ $_i -lt ${#_cw[@]} ]] && _wg_a_trusted "${_cw[_i]}" && return 1
      return 0 ;;
    state_read|state_write|state_transition|status_add|status_remove|status_has|status_clear|status_read|status_write)
      for _x in "${_cw[@]:_k+1}"; do
        [[ "$_x" == */* ]] || continue
        _wg_a_wok "$_x" || return 0
      done
      return 1 ;;
    pgrep|pidof) return 1 ;;
  esac
  _wg_dx_seg && return 0
  return 1
}
_wg_a_ok() {  # $1=명령 → 분기 A 로 허용해도 되면 0
  _wg_d_each "$1" _wg_a_seg && return 1
  return 0
}
# [사이클206 NEW-a] 분기 E 전용 정규화 — 출력이 원문과 다르면 \"안전하게 풀어 쓴 같은 명령\"이다(_askq_ro_cmd 자체는 F-ASKQ-PROT 공유라 바꾸지 않는다).
#   ① 개행·백틱·<<·&& 가 있으면 원문 그대로(oio && 분할로 빈 값이 되는 판정 차이 제거).
#   ② 최상위 ; 구간 머리의 순수 대입 NAME=<리터럴>(값에 $·백틱·괄호·역슬래시·공백·글로브·구분자·리다이렉트 없음, 짝 맞는 따옴표 감싸기 허용,
#      위험 환경변수 이름 아님, 같은 이름 1회)을 지우고 $NAME·${NAME}(뒤가 영숫자·_ 아님)를 값으로 바꾼다. 조건이 하나라도 어긋나면 원문.
#   ③ 중첩 없는 $( … ) 의 내부가 _askq_ro_cmd 참이면 자리표시 X 로 바꾼다. 내부가 거짓·중첩·닫힘 없음이면 원문(→ 차단).
_WG_RO_DANGER='^(PATH|IFS|ENV|BASH_ENV|BASH_.*|CDPATH|HOME|SHELL|SHELLOPTS|BASHOPTS|PS4|PROMPT_COMMAND|LD_.*|GIT_.*|PYTHON.*|PERL5.*|PERLLIB|NODE_.*|RUBYOPT|RUBYLIB|PAGER|MANPAGER|LESSOPEN|LESSCLOSE|EDITOR|VISUAL|GREP_OPTIONS|GCONV_PATH|LOCPATH|TMPDIR|POSIXLY_CORRECT|GLOBIGNORE|PWD|OLDPWD)$'
_wg_ro_norm() {
  local _c="$1" _i _n _ch _q="" _seg="" _rest="" _nm _vl _o _in _pre _post _s _t _pd=0 _guard=0 _wp
  local _o1='$(' _c1=')' _bad='[$`()\\ 	*?;|&<>'"'"'"[]'
  local -A _vars=()
  local -a _segs=()
  if [[ "$_c" == *$'\n'* || "$_c" == *$'\r'* || "$_c" == *'`'* || "$_c" == *'<<'* || "$_c" == *'&&'* ]]; then printf '%s' "$_c"; return 0; fi
  _n=${#_c}
  for ((_i = 0; _i < _n; _i++)); do
    _ch="${_c:_i:1}"
    if [[ -n "$_q" ]]; then _seg+="$_ch"; [[ "$_ch" == "$_q" ]] && _q=""; continue; fi
    case "$_ch" in
      "'"|'"') _q="$_ch"; _seg+="$_ch" ;;
      '(') _pd=$((_pd + 1)); _seg+="$_ch" ;;
      ')') [[ $_pd -gt 0 ]] && _pd=$((_pd - 1)); _seg+="$_ch" ;;
      ';') if [[ $_pd -eq 0 ]]; then _segs+=("$_seg"); _seg=""; else _seg+="$_ch"; fi ;;
      *) _seg+="$_ch" ;;
    esac
  done
  [[ -z "$_q" ]] || { printf '%s' "$_c"; return 0; }
  _segs+=("$_seg")
  for _s in "${_segs[@]}"; do
    _t="${_s#"${_s%%[![:space:]]*}"}"; _t="${_t%"${_t##*[![:space:]]}"}"
    [[ -n "$_t" ]] || continue
    if [[ "$_t" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      _nm="${BASH_REMATCH[1]}"; _vl="${BASH_REMATCH[2]}"
      if [[ "$_vl" =~ ^\'([^\']*)\'$ ]] || [[ "$_vl" =~ ^\"([^\"]*)\"$ ]]; then _vl="${BASH_REMATCH[1]}"; fi
      if [[ -z "$_vl" || "$_vl" =~ $_bad ]] || [[ "$_nm" =~ $_WG_RO_DANGER ]] || [[ -n "${_vars[$_nm]+x}" ]]; then
        printf '%s' "$_c"; return 0
      fi
      _vars[$_nm]="$_vl"
      continue
    fi
    _rest+="${_rest:+; }$_t"
  done
  for _nm in "${!_vars[@]}"; do
    _vl="${_vars[$_nm]}"
    _rest="${_rest//"\${$_nm}"/"$_vl"}"
    _o=""; _in="$_rest"
    while [[ "$_in" == *"\$$_nm"* ]]; do
      _pre="${_in%%"\$$_nm"*}"; _post="${_in#*"\$$_nm"}"
      if [[ "$_post" =~ ^[A-Za-z0-9_] ]]; then _o+="${_pre}\$$_nm"; else _o+="${_pre}${_vl}"; fi
      _in="$_post"
    done
    _rest="$_o$_in"
  done
  while [[ "$_rest" == *"$_o1"* ]]; do
    _guard=$((_guard + 1)); [[ $_guard -le 8 ]] || { printf '%s' "$_c"; return 0; }
    _pre="${_rest%%"$_o1"*}"; _post="${_rest#*"$_o1"}"
    [[ "$_post" == *"$_c1"* ]] || { printf '%s' "$_c"; return 0; }
    _in="${_post%%"$_c1"*}"
    [[ "$_in" != *'('* ]] || { printf '%s' "$_c"; return 0; }
    # [사이클206 교차검토 ①] 치환 결과가 단어 머리(옵션 자리)에 올 수 있으면 원문 유지 — `find d $(echo -delete)`·`sort $(echo -o) f f`.
    #   같은 단어 안에서 앞에 리터럴 글자가 붙은 치환(`"[$(cat x)]"`·`a=$(…)`)만 인정하고, 그 단어가 - 로 시작하면(`--x=$(…)`·`-$(…)`) 불인정.
    _wp="${_pre##*[[:space:];|&(]}"; _wp="${_wp//[\"\']/}"
    if [[ -z "$_wp" || "$_wp" == -* ]]; then printf '%s' "$_c"; return 0; fi
    _askq_ro_cmd "$_in" || { printf '%s' "$_c"; return 0; }
    _rest="${_pre}X${_post#*"$_c1"}"
  done
  printf '%s' "$_rest"
}
# [overblock P3d] 엄격 읽기 전용 명령 + 끝의 표준출력 리다이렉트 1개이고 대상이 대화 기록이 아닌 절대 리터럴이면 rc 0. 트랜스크립트 언급 판정에만 쓴다.
#   대상 단어에 변수·치환·글로브·따옴표·구분자가 없어야 하고 realpath 로 다시 본다. 앞부분에 리다이렉트가 더 있으면 _askq_ro_cmd 가 거부한다.
_askq_ro_redir() {
  local _c="$1" _rx _h _t _tr
  [[ "$_c" != *$'\n'* && "$_c" != *$'\r'* ]] || return 1
  _rx='^(.*[^>&0-9[:space:]])[[:space:]]+>>?[[:space:]]*([^][:space:];|&<>$`'"'"'"(){}*?[\\]+)[[:space:]]*$'
  [[ "$_c" =~ $_rx ]] || return 1
  _h="${BASH_REMATCH[1]}"; _t="${BASH_REMATCH[2]}"
  [[ "$_t" == /* ]] || return 1
  _tr=$(realpath -m -- "$_t" 2>/dev/null) || return 1
  case "${_t,,}" in *.jsonl|*/projects/*) return 1 ;; esac
  case "${_tr,,}" in *.jsonl|*/projects/*) return 1 ;; esac
  _askq_ro_cmd "$_h"
}
# [overblock P3b] `cat > <파일> <<'끝'` 단일 heredoc 이면 첫 줄을 _AHD_FIRST 에 담고 rc 0. 트랜스크립트 언급 판정만 본문을 뺀 첫 줄로 본다.
#   파일 도구 file_write 는 본문을 판정하지 않으므로 같은 내용을 쓰는 능력이 새로 생기지 않는다.
#   rc 0 조건: 인용 종결자(본문 확장 없음), 대상 단어에 변수·치환·글로브·구분자 없음, 종결자 줄이 마지막 줄 1개뿐(뒤에 실행 명령이 올 수 없음), 명령 전체에 && 없음(oio 분할기 차이 방지).
#   같은 명령 안에서 스크립트를 실행하는 꼴은 마지막 줄 조건에 걸려 종전 판정으로 간다. 대상이 대화 기록이면 첫 줄에 경로가 남아 차단된다.
_askq_hd_first() {
  local _c="$1" _f _b _l _t _n=0 _rx
  _AHD_FIRST=""
  _c="${_c%$'\n'}"
  [[ "$_c" == *$'\n'* && "$_c" != *$'\r'* && "$_c" != *'&&'* ]] || return 1
  _f="${_c%%$'\n'*}"; _b="${_c#*$'\n'}"
  _rx='^[[:space:]]*cat[[:space:]]+>>?[[:space:]]*[^][:space:];|&<>$`'"'"'"(){}*?[\\]+[[:space:]]+<<['"'"'"]([A-Za-z_][A-Za-z0-9_]*)['"'"'"][[:space:]]*$'
  [[ "$_f" =~ $_rx ]] || return 1
  _t="${BASH_REMATCH[1]}"
  [[ "$_f" == *"<<'${_t}'"* || "$_f" == *"<<\"${_t}\""* ]] || return 1
  while IFS= read -r _l; do [[ "$_l" == "$_t" ]] && _n=$((_n + 1)); done <<<"$_b"
  [[ "$_n" -eq 1 && "${_b##*$'\n'}" == "$_t" ]] || return 1
  _AHD_FIRST="$_f"
  return 0
}
_ASKQ_K=""
case "$TOOL_NAME" in
  mcp__oio__file_write|mcp__oio__file_edit|Write|Edit|MultiEdit|NotebookEdit|mcp__oio__file_delete|\
  mcp__oio__file_copy|mcp__oio__file_move|mcp__oio__file_rename|mcp__oio__file_symlink|mcp__oio__dir_create) _ASKQ_K="file" ;;
  mcp__oio__dir_delete|mcp__oio__dir_move|mcp__oio__dir_rename) _ASKQ_K="dir" ;;
  Bash|mcp__oio__bash_exec) _ASKQ_K="shell" ;;
esac
if [[ -n "$_ASKQ_K" ]]; then
  _ASKQ_TI="${_CRUD_TI:-$(echo "$INPUT" | jq -c '.tool_input // {}' 2>/dev/null || echo "")}"
  _ASKQ_TIL="${_ASKQ_TI,,}"
  _ASKQ_HIT=""
  if [[ "$_ASKQ_K" == "shell" ]]; then
    if [[ "$_ASKQ_TIL" == *askq_approval_consumed* || "$_ASKQ_TIL" == *baseline_untracked* || \
          "$_ASKQ_TIL" == *pipeline_start_time* || "$_ASKQ_TIL" == *ok_started* || "$_ASKQ_TIL" == *evidence* || "$_ASKQ_TIL" == *plan_entry_mark* || \
          "$_ASKQ_TIL" == *projects* ]]; then
      _ASKQ_CMD=$(jq -r '[.command,.cmd] | map(select(type=="string"))[0] // empty' <<<"$_ASKQ_TI" 2>/dev/null || echo "")
      _ASKQ_CL="${_ASKQ_CMD,,}"
      _ASKQ_TCMD="$_ASKQ_CMD"; _askq_hd_first "$_ASKQ_CMD" && _ASKQ_TCMD="$_AHD_FIRST"   # [overblock P3b] 트랜스크립트 판정 전용
      _ASKQ_TCL="${_ASKQ_TCMD,,}"
      # [사이클194 (f)] ④·⑤·⑤' 는 엄격 읽기 전용 명령이면 통과(①·③ 은 무관하게 차단 유지).
      _ASKQ_RO=""; _askq_ro_cmd "$_ASKQ_CMD" && _ASKQ_RO=1
      _ASKQ_RO_T="$_ASKQ_RO"; [[ -z "$_ASKQ_RO_T" ]] && _askq_ro_redir "$_ASKQ_CMD" && _ASKQ_RO_T=1   # [overblock P3d] 트랜스크립트 판정 전용
      # [역라우팅 #2 — 설계 전환] 동작어 판정(정규식 군비경쟁)을 버리고 ★보호 이름이 셸 텍스트에 나타나면 기본 차단★ 한다.
      #   otest 실증: if/{ }/!/'rm'/\rm/$(echo rm)/eval/nice/busybox/os.system/subprocess 로 명령 위치 판정이 뚫렸다.
      #   셸 읽기 허용 목록은 두지 않는다(그게 우회 표면이다) — 읽기는 mcp__oio__file_read / list_dir / Grep 으로 한다.
      #   [사이클194 (f)] 예외: ④·⑤·⑤' 에 한해 _askq_ro_cmd 엄격 판정(명령 목록·리다이렉트·치환 금지)을 통과한 읽기만 허용한다.
      #   ① 트랜스크립트(projects/…*.jsonl): [사이클205 W3] 엄격 읽기 전용 명령이면 통과, 그 밖은 언급만으로 차단.
      #   ② 소비 기록·③ 기준선: 허용 구간 없음(셸로 다룰 정당한 경로 없음).
      #   ④ pipeline_start_time · ⑤ evidence/ok_started: 그 세션이 허용 구간(IDLE / PLAN+classification=OK, ⑤ 는 FINISH 도)일 때만 통과.
      #   ⑤' evidence/ 디렉터리 통째 조작: 텍스트에 evidence 경로(끝·/*)와 삭제·이동 단어가 함께 있으면 위치 무관 차단
      #      (대입 `rm=`·for 변수 `for rm in` 만 제외). 허용 구간은 ⑤ 와 같다.
      #   잔존 한계(정직 고지): 이름 자체를 쪼개는 난독화('pipeline_'+'start_time'·'ok_'+'started'·glob ok_st*·
      #   'pro'+'jects' 등)는 F-CRUD-SW 와 같은 등급으로 남는다. 경로 조각 분리(os.path.join)는 트랜스크립트에 한해 막는다.
      if [[ "$_ASKQ_CL" == *askq_approval_consumed* ]]; then
        _ASKQ_HIT="셸 명령에 askq_approval_consumed 언급"
      elif [[ "$_ASKQ_CL" == *baseline_untracked* ]]; then
        _ASKQ_HIT="셸 명령에 baseline_untracked 언급"
      elif [[ -z "$_ASKQ_RO" && "$_ASKQ_CL" == *plan_entry_mark* ]]; then
        _ASKQ_HIT="셸 명령에 plan_entry_mark 언급(엄격 읽기 전용 아님)"
      # 트랜스크립트: 'projects' 와 'jsonl' 이 텍스트 어디에든 함께 있으면 차단(떨어져 있어도 — os.path.join 분할 우회 실측, odev-1 T40/T40b).
      #   projects/…* glob(확장자 없이 디렉터리째)도 차단.
      #   [사이클205 W3] 단 _askq_ro_cmd 엄격 읽기 전용(리다이렉트·치환·해석기·쓰기 수단 없음)이면 통과 — 보호 목적은 쓰기·삭제다(읽기는 비대상).
      elif [[ -z "$_ASKQ_RO_T" ]] && { [[ ( "$_ASKQ_TCL" == *projects* && "$_ASKQ_TCL" == *jsonl* ) ]] || \
           printf '%s' "$_ASKQ_TCMD" | grep -qiP -- 'projects/[^\s;|&<>]*\*' 2>/dev/null; }; then
        _ASKQ_HIT="셸 명령에 트랜스크립트(projects/*.jsonl) 언급"
      elif [[ -z "$_ASKQ_RO" && "$_ASKQ_CL" == *pipeline_start_time* ]] && \
           _askq_sh_lock 'session-env/\K[^/\s"'"'"'$]+(?=/+pipeline_start_time)' 'pipeline_start_time' 0; then
        _ASKQ_HIT="셸 명령에 pipeline_start_time 언급(파이프라인 진행 중)"
      elif [[ -z "$_ASKQ_RO" && "$_ASKQ_CL" == *ok_started* ]] && \
           _askq_sh_lock 'session-env/\K[^/\s"'"'"'$]+(?=/+evidence/+ok_started)' 'ok_started' 1; then
        _ASKQ_HIT="셸 명령에 evidence/ok_started 언급(파이프라인 진행 중)"
      #   [사이클206 NEW-O16] 경로 판정에서 프로젝트 저장소의 `.claude/evidence`(사이클 표본·증거 폴더 — ok_started 위치 아님)는 뺀다.
      #   세션 evidence(`session-env/<UUID>/evidence`)·상대 `evidence` 는 종전대로 본다(`cd <저장소 evidence>; rm -rf <세션>/evidence` 차단 유지).
      elif [[ -z "$_ASKQ_RO" && "$_ASKQ_CL" == *evidence* ]] && \
           printf '%s' "$_ASKQ_CMD" | sed -E 's#\.claude/+evidence#.claude/_c206_repo_ev_#Ig' | grep -qiP -- '(?:^|[\s/"'"'"'=])evidence/?(?:\*|\.\*?)?(?=[\s"'"'"';&|)]|$)' 2>/dev/null && \
           printf '%s' "$_ASKQ_CMD" | grep -qiP -- '(?<![\w$.-])(?<!for )(?:rm|rmdir|mv|unlink|shred|rmtree|removedirs)(?![\w=-])(?!\s*=)|-delete\b|--remove-source-files|os\.(?:remove|rename|replace|renames|unlink)\b|shutil\.(?:move|rmtree)\b' 2>/dev/null && \
           _askq_sh_lock 'session-env/\K[^/\s"'"'"'$]+(?=/+evidence/?(?:\*|\.\*?)?(?:[\s"'"'"';&|)]|$))' '(?:^|[\s/"'"'"'=])evidence/?(?:\*|\.\*?)?(?=[\s"'"'"';&|)]|$)' 1; then
        _ASKQ_HIT="evidence/ 디렉터리 삭제·이동(ok_started 소실)"
      fi
    fi
  elif [[ "$_ASKQ_K" == "dir" || "$_ASKQ_TIL" == *askq_approval_consumed* || "$_ASKQ_TIL" == *baseline_untracked* || "$_ASKQ_TIL" == *.jsonl* || "$_ASKQ_TIL" == *pipeline_start_time* || "$_ASKQ_TIL" == *ok_started* || "$_ASKQ_TIL" == *plan_entry_mark* ]]; then
    _askq_flag=0; [[ "$_ASKQ_K" == "dir" ]] && _askq_flag=1
    _askq_base=$(jq -r '[.source,.src,.path,.file_path,.filepath] | map(select(type=="string" and . != ""))[0] // empty' <<<"$_ASKQ_TI" 2>/dev/null)
    _askq_list=$(jq -r '[.path,.file_path,.filepath,.source,.src,.destination,.dest,.dst,.target,.to,.new_name,.name,.new_path,.link_path,.link] | map(select(type=="string" and . != ""))[]' <<<"$_ASKQ_TI" 2>/dev/null)
    [[ "$_ASKQ_K" == "file" ]] && _askq_list+=$'\n'"$(_r1_targets "$_ASKQ_TI" | cut -f1)"
    while IFS= read -r _askq_p; do
      [[ -n "$_askq_p" ]] || continue
      [[ "$_askq_p" == /* || -z "$_askq_base" ]] || _askq_p="$(dirname -- "$_askq_base")/$_askq_p"
      if _askq_prot "$_askq_p" "$_askq_flag"; then _ASKQ_HIT="$_askq_p"; break; fi
    done <<<"$_askq_list"
  fi
  if [[ -n "$_ASKQ_HIT" ]]; then
    source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/write_error.sh" 2>/dev/null || true
    declare -F log_hook_error >/dev/null 2>&1 && \
      log_hook_error "HOOK_BLOCK_ASKQ_PROT" "$TOOL_NAME" "승인 판정 근거 변경 시도 — ${_ASKQ_HIT}" "$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null)"
    _ASKQ_HIT_J=$(printf '%s' "$_ASKQ_HIT" | tr '"\\' "''")
    # [사이클182 항목1] 차단 표식 — 이후 1800초 안에 작성·실행하는 스크립트 본문을 재판정한다(lib/script_recheck.sh)
    declare -F sr_mark_block >/dev/null 2>&1 || source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/script_recheck.sh" 2>/dev/null || true
    declare -F sr_mark_block >/dev/null 2>&1 && sr_mark_block "F-ASKQ-PROT" "$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)" >/dev/null 2>&1
    echo "{\"decision\":\"block\",\"reason\":\"🚫 [F-ASKQ-PROT] CRUD 판정 근거(트랜스크립트 *.jsonl · 화면 승인 소비 기록 logs/askq_approval_consumed.log · baseline_untracked/ · plan_entry_mark · 파이프라인 진행 중 pipeline_start_time·evidence/ok_started)는 에이전트(메인·팀 공통)가 쓰거나 지우거나 옮길 수 없습니다(${TOOL_NAME}: ${_ASKQ_HIT_J}). pipeline_start_time·ok_started 는 state=IDLE 또는 PLAN+classification=OK(ok 진입 구간)에서만 기록할 수 있습니다(ok_started 와 evidence/ 정리는 FINISH 도 허용). 셸 명령은 엄격 읽기 전용 명령(grep·cat·head·tail·wc·ls·stat·find·sort·uniq·cut·date·test·echo·printf·cd·git 조회·xargs 읽기 등만으로 된 단순 명령·파이프, 리다이렉트·명령치환 없음)일 때만 pipeline_start_time·ok_started·evidence·트랜스크립트 언급이 허용되고, askq_approval_consumed·baseline_untracked 는 언급만으로 차단됩니다. 그 밖의 읽기는 mcp__oio__file_read · mcp__oio__list_dir · Grep 도구를 쓰십시오.\"}"
    exit 2
  fi
fi

# ── F-NO-BYPASS (사이클194 g①): file 도구가 막힌 경로를 셸로 다시 쓰는 우회 차단 ──
# 근거: odone-4 가 time_budget 보류 직후 같은 파일을 bash_exec 로 썼다(L-597 위반 실측). 가드 판정을 도구 전환으로 건너뛴 것이다.
# 판정: 자기 세션 logs/fw_attempts.tsv(위 기록부)에서 600초 안 경로별 마지막 상태가 PASS·REDIRECT 가 아닌 것(BLOCK·PENDING·RC*)을 모은다.
#   명령이 쓰기 형태(>·>>·tee·cp·mv·install·rsync·ln·rm·unlink·truncate·touch·dd·sed -i·perl·python 의 open/write 류·node·ruby)이고
#   그 실경로가 명령 텍스트에 나오거나 basename 이 경로 문자 경계로 나오면 차단한다(상대경로는 cwd 해석이 불확실해 basename 으로 보수 판정).
#   PENDING 은 time_budget 보류 중 본문이 아직 판정 중이라는 뜻이다 — 본문이 끝나 PASS 로 바뀌면 이후 통과한다.
# 잔존 한계: 이름 쪼개기·변수 조립 등 표현 변경 우회는 문자열 판정 한계로 남는다(script_recheck 2차 방어 유지).
if [[ "$TOOL_NAME" == "mcp__oio__bash_exec" || "$TOOL_NAME" == "Bash" ]]; then
  _wg_pre _NB_SID "$_WG_SID" '.session_id // empty'   # c205 D-9
  _NB_LOG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${_NB_SID}/logs/fw_attempts.tsv"
  if [[ "$_NB_SID" =~ ^[0-9a-fA-F-]{36}$ && -s "$_NB_LOG" ]]; then
    _NB_NOW=$(date +%s 2>/dev/null) || _NB_NOW=0
    _NB_ACT=$(_wg_fw_actor 2>/dev/null) || _NB_ACT="main"
    _NB_HOT=$(awk -F'\t' -v lim="$((_NB_NOW - 600))" -v act="$_NB_ACT" 'NF>=5 && ($1+0)>=lim && $5==act {st[$3]=$2; bn[$3]=$4} END{for (p in st) if (st[p] != "PASS" && st[p] != "REDIRECT") print p "\t" bn[p]}' "$_NB_LOG" 2>/dev/null) || _NB_HOT=""
    if [[ -n "$_NB_HOT" ]]; then
      _NB_CMD=$(jq -r '.tool_input | [.command,.cmd] | map(select(type=="string"))[0] // empty' <<<"$INPUT" 2>/dev/null) || _NB_CMD=""
      _NB_HIT=""
      # 쓰기 대상 위치만 본다(원본을 읽어 사본을 만드는 cp 는 통과 — AC 사본 보존 탈출구 오탐 실측 r3 d13d):
      #   ① 리다이렉트(>·>>·>|) 대상, dd of= 대상 ② cp·install·rsync·ln 구간의 마지막 인자(목적지)
      #   ③ mv·rm·unlink·shred·truncate·touch·tee·sed -i·perl·python*·node·ruby 가 든 구간에서의 언급(원본 소실·임의 쓰기라 위치 무관)
      #   경로 일치 = 실경로 그대로 또는 '/basename'·맨 basename 이 경로 문자 경계로 끝나는 토큰(상대경로 보수 판정).
      _nb_tok_is() {  # $1=토큰 $2=실경로 $3=basename → 같은 대상이면 0
        local _x="${1//[\"\']/}"
        [[ -n "$_x" && ( "$_x" == "$2" || "$_x" == "$3" || "$_x" == */"$3" ) ]]
      }
      # 단어에서 벗길 따옴표·괄호 — 확장 안에 '}' 를 직접 쓰면 확장이 조기에 닫히므로 변수로 둔다(실측).
      _NB_STRIP='["'"'"'(){}]'
      _NB_SEGS="${_NB_CMD//2>&1/ }"; _NB_SEGS="${_NB_SEGS//>&2/ }"
      _NB_SEGS="${_NB_SEGS//&&/$'\n'}"; _NB_SEGS="${_NB_SEGS//||/$'\n'}"; _NB_SEGS="${_NB_SEGS//;/$'\n'}"
      _NB_SEGS="${_NB_SEGS//&/$'\n'}"; _NB_SEGS="${_NB_SEGS//|/$'\n'}"
      while IFS=$'\t' read -r _nb_p _nb_b; do
        [[ -n "$_nb_p" ]] || continue
        if [[ "$_nb_b" == *'\'* || "$_nb_b" == *'\E'* || -z "$_nb_b" ]]; then
          _nb_re=""   # 정규식 안전 표기 불가 — 아래 문자열 대조만 쓴다(보수)
        else
          _nb_re="(?:[^\\s\"';&|<>]*/)?\\Q${_nb_b}\\E(?![A-Za-z0-9._-])"
        fi
        # ① 리다이렉트·dd of= (명령 전체에서 — bash -c '…' 안쪽 포함)
        if [[ -n "$_nb_re" ]] && printf '%s' "$_NB_CMD" | grep -qP -- ">\\|?\\s*[\"']?${_nb_re}|\\bof=[\"']?${_nb_re}" 2>/dev/null; then
          _NB_HIT="$_nb_p"; break
        fi
        if [[ -z "$_nb_re" && "$_NB_CMD" == *">"* && "$_NB_CMD" == *"$_nb_b"* ]]; then _NB_HIT="$_nb_p"; break; fi
        # ①' 인터프리터(python·perl·node·ruby) — 명령 전체 기준(-c 코드 안 ';' 로 구간이 쪼개지므로). 경로 언급 + 쓰기 표지일 때만.
        #   경로를 인자로 받는 스크립트 실행(읽기 게이트 등)은 쓰기 표지가 없어 통과한다(r3 d14 오탐 실측). 스크립트 파일 본문은 script_recheck 가 본다.
        if [[ "$_NB_CMD" == *python* || "$_NB_CMD" == *perl* || "$_NB_CMD" == *node* || "$_NB_CMD" == *ruby* ]] && \
           { [[ "$_NB_CMD" == *"$_nb_p"* ]] || { [[ -n "$_nb_re" ]] && printf '%s' "$_NB_CMD" | grep -qP -- "(?<![A-Za-z0-9._-])${_nb_re}" 2>/dev/null; }; } && \
           printf '%s' "$_NB_CMD" | grep -qP -- '\b(python[0-9.]*|perl|node|ruby)\b' 2>/dev/null && \
           printf '%s' "$_NB_CMD" | grep -qP -- '\b(write|write_text|write_bytes|writeFile|writeFileSync|appendFile|appendFileSync|truncate|remove|unlink|unlinkSync|rename|renames|replace|rmtree|move|copy|copyfile|copy2|symlink|link|dump|chmod)\b|open\s*\([^)]*["'"'"'][rwab+tx]*[wax+]|\bperl\b[^;|&]*\s-[A-Za-z]*i' 2>/dev/null; then
          _NB_HIT="$_nb_p"; break
        fi
        while IFS= read -r _nb_seg; do
          [[ -n "${_nb_seg//[[:space:]]/}" ]] || continue
          _nb_ws=(); IFS=$' \t' read -r -a _nb_ws <<<"$_nb_seg"
          _nb_any=""; _nb_cp=""; _nb_sed=""; _nb_si=""
          for _nb_w in "${_nb_ws[@]}"; do
            _nb_w="${_nb_w//$_NB_STRIP/}"
            case "$_nb_w" in
              mv|rm|unlink|shred|truncate|touch|tee) _nb_any=1 ;;
              cp|install|rsync|ln) _nb_cp=1 ;;
              sed) _nb_sed=1 ;;
              -i|-i*|--in-place|--in-place=*) _nb_si=1 ;;
            esac
          done
          [[ -n "$_nb_sed" && -n "$_nb_si" ]] && _nb_any=1
          if [[ -n "$_nb_any" ]]; then
            if [[ "$_nb_seg" == *"$_nb_p"* ]]; then _NB_HIT="$_nb_p"; break; fi
            if [[ -n "$_nb_re" ]] && printf '%s' "$_nb_seg" | grep -qP -- "(?<![A-Za-z0-9._-])${_nb_re}" 2>/dev/null; then _NB_HIT="$_nb_p"; break; fi
            [[ -z "$_nb_re" && "$_nb_seg" == *"$_nb_b"* ]] && { _NB_HIT="$_nb_p"; break; }
          fi
          if [[ -n "$_nb_cp" && ${#_nb_ws[@]} -gt 1 ]] && _nb_tok_is "${_nb_ws[-1]}" "$_nb_p" "$_nb_b"; then
            _NB_HIT="$_nb_p"; break
          fi
        done <<<"$_NB_SEGS"
        [[ -n "$_NB_HIT" ]] && break
      done <<<"$_NB_HOT"
      if [[ -n "$_NB_HIT" ]]; then
        _NB_HIT_J=$(printf '%s' "$_NB_HIT" | tr '"\\' "''")
        source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/write_error.sh" 2>/dev/null || true
        declare -F log_hook_error >/dev/null 2>&1 && \
          log_hook_error "HOOK_BLOCK_NO_BYPASS" "$TOOL_NAME" "file 도구 차단·보류 경로를 셸로 재시도 — ${_NB_HIT}" "$_NB_SID"
        echo "{\"decision\":\"block\",\"reason\":\"🚫 [F-NO-BYPASS] 최근 600초 안에 file 도구 호출이 차단되었거나 아직 판정 중(보류)인 경로를 셸로 다시 쓰려 합니다(${_NB_HIT_J}). 가드·time_budget 차단/보류를 표현 바꾸기나 다른 도구 전환으로 우회하지 마십시오 — 같은 file 도구로 다시 시도하거나 SendMessage 로 team-lead 에 보고한 뒤 기다리십시오(L-597).\"}"
        exit 2
      fi
    fi
  fi
fi
# --- F-NO-BYPASS 끝 ---

# ── 셸 경로 (D5): 마커 쓰기 패턴이 보이면 무조건 차단 ──
if [[ "$_CRUD_CLASS" == "shell" ]]; then
  if [[ "$_WG_PRE" == 1 && -n "$_CRUD_TI" ]]; then _CRUD_CMD="$_WG_STRCMD"   # c205 D-9 — _CRUD_TI 는 같은 INPUT 의 tool_input 정규화본
  else _CRUD_CMD=$(jq -r '[.command,.cmd] | map(select(type=="string"))[0] // empty' <<<"$_CRUD_TI" 2>/dev/null || echo ""); fi
  if [[ "$_CRUD_CMD" == *evidence/* && ( "$_CRUD_CMD" == *make_ok* || "$_CRUD_CMD" == *otest_done* || "$_CRUD_CMD" == *make_partial* ) ]]; then
    _CRUD_M='evidence/(make_ok|otest_done|make_partial)(?![A-Za-z0-9_.-])'
    _CRUD_SH_HIT=""
    # 패턴 1~4 — __M__ 자리에 마커 정규식을 넣는다. 쓰기 동작만 잡는다(읽기 cat/test/grep/ls·cp 원본 측은 비대상).
    while IFS= read -r _crud_pat; do
      [[ -n "$_crud_pat" ]] || continue
      if printf '%s' "$_CRUD_CMD" | grep -qP -- "${_crud_pat//__M__/$_CRUD_M}" 2>/dev/null; then
        _CRUD_SH_HIT="$_crud_pat"; break
      fi
    done <<'CRUD_SH_PATS'
>{1,2}\s*["']?[^\s;|&"'<>]*__M__
\btee\b[^;|&]*__M__
\b(cp|mv|install|ln|rsync)\b[^;|&]*\s["']?[^\s;|&"']*__M__["']?\s*($|[;|&)'"])
\bdd\b[^;|&]*\bof=[^\s;|&]*__M__
\b(touch|truncate)\b[^;|&]*__M__
\b(sed|perl)\b[^;|&]*\s-i[^;|&]*__M__
CRUD_SH_PATS
    # 패턴 5 (rev3 축소): python/node 가 있고 마커가 있고, 쓰기 모드 open·write_text·shutil/os 이동·json.dump( 중 하나.
    #   json.dumps / json.load(open(...)) 읽기는 비대상(A7 음성).
    if [[ -z "$_CRUD_SH_HIT" ]] && printf '%s' "$_CRUD_CMD" | grep -qP '\b(python3?|node)\b' 2>/dev/null \
       && printf '%s' "$_CRUD_CMD" | grep -qP -- "$_CRUD_M" 2>/dev/null; then
      if printf '%s' "$_CRUD_CMD" | grep -qP -- 'open\([^)]*,\s*['"'"'"][^'"'"'"]*[wax+]|write_text|write_bytes|shutil\.(copy|copyfile|copy2|move)\(|os\.(rename|replace)\(|json\.dump\(|writeFile' 2>/dev/null; then
        _CRUD_SH_HIT="python/node write"
      fi
    fi
    if [[ -n "$_CRUD_SH_HIT" ]]; then
      _CRUD_MK=$(printf '%s' "$_CRUD_CMD" | grep -oP -- "$_CRUD_M" 2>/dev/null | head -1)
      source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/write_error.sh" 2>/dev/null || true
      declare -F log_hook_error >/dev/null 2>&1 && \
        log_hook_error "HOOK_BLOCK_CRUD_EVIDENCE_SHELL" "$TOOL_NAME" "셸 명령으로 ${_CRUD_MK} 쓰기 시도" "$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null)"
      if [[ "$_CRUD_MK" == *make_partial ]]; then
        echo "{\"decision\":\"block\",\"reason\":\"🚫 [F-CRUD-1/shell] ${_CRUD_MK} 를 셸 명령으로 만들 수 없습니다 — make_partial 은 판정기만 기록합니다(c177 A12). 대안 명령: python3 <프로젝트>/.claude/skills/otest_make/scripts/verify_crud_executed.py --uuid <UUID> --emit-from-goal --ac-records <ac_records.json> — 레코드 형식 [{id:AC-xxx,status:PASS,write_log:…,count_before:…,count_after:…}], 기존 파일에 덧붙이지 않고 새로 씀.\"}"
        exit 2
      fi
      echo "{\"decision\":\"block\",\"reason\":\"🚫 [F-CRUD-1/shell] ${_CRUD_MK:-evidence/<마커>} 를 셸 명령으로 만들 수 없습니다 — 게이트가 쓰여질 내용을 평가할 수 없습니다. mcp__oio__file_write(또는 file_copy)를 쓰십시오(그 경로는 CRUD 실행증거 게이트를 통과해야 합니다).\"}"
      exit 2
    fi
  fi
fi

# ── 파일·디렉터리 경로: 대상 경로 산출 → 마커면 verify_crud_executed.py ──
_CRUD_ROWS=""
_CRUD_RECHECK_OK=""
if [[ "$_CRUD_CLASS" == "dir" ]] || \
   [[ "$_CRUD_CLASS" == "file" && ( "$_CRUD_TI" == *make_ok* || "$_CRUD_TI" == *otest_done* || "$_CRUD_TI" == *make_partial* ) ]]; then
  _CRUD_ROWS=$(_r1_targets "$_CRUD_TI")
fi
if [[ -n "$_CRUD_ROWS" ]]; then
  _CRUD_SEEN=""
  while IFS=$'\t' read -r _CRUD_PATH _CRUD_SRC; do
    # [c177 A12 결함3] make_partial 은 verify_crud_executed.py --emit-from-goal(필요 시 --ac-records)만 기록한다.
    #   --final 의 PARTIAL 인정이 이 파일 내용만 믿으므로, 도구로 만드는 길(쓰기·수정·복사·이동·이름변경·심볼릭·dir_*)을 전부 막는다.
    #   예외 1개: dir_move/dir_rename 이 이미 있던 evidence/make_partial 을 디렉터리째 옮기는 경우(원본도 이 가드 아래 생성된 것).
    if [[ "$_CRUD_PATH" == */evidence/make_partial ]]; then
      if [[ "$_CRUD_CLASS" == "dir" && "$_CRUD_SRC" == */evidence/make_partial ]]; then
        continue
      fi
      source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/write_error.sh" 2>/dev/null || true
      declare -F log_hook_error >/dev/null 2>&1 && \
        log_hook_error "HOOK_BLOCK_CRUD_PARTIAL" "$TOOL_NAME" "도구로 make_partial 생성 시도 — ${_CRUD_PATH}" "$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null)"
      echo "{\"decision\":\"block\",\"reason\":\"🚫 [F-CRUD-1/partial] evidence/make_partial 은 도구(${TOOL_NAME})로 만들거나 고칠 수 없습니다 — otest_done 의 PARTIAL 인정이 이 파일 내용만 믿기 때문입니다. 대안 명령: python3 <프로젝트>/.claude/skills/otest_make/scripts/verify_crud_executed.py --uuid <UUID> --emit-from-goal --ac-records <ac_records.json> — 레코드 형식 [{id:AC-xxx,status:PASS,write_log:…,count_before:…,count_after:…}], 기존 파일에 덧붙이지 않고 새로 씀, rc 0=make_ok 1=make_partial 2=레코드 위반(무기록) 3=판정행 0건(무기록).\"}"
      exit 2
    fi
    [[ "$_CRUD_PATH" == */evidence/otest_done || "$_CRUD_PATH" == */evidence/make_ok ]] || continue
    case $'\n'"$_CRUD_SEEN" in *$'\n'"$_CRUD_PATH"$'\t'"$_CRUD_SRC"$'\n'*) continue ;; esac
    _CRUD_SEEN+="$_CRUD_PATH"$'\t'"$_CRUD_SRC"$'\n'
    # 대상 UUID 는 (정규화된) 경로에서 직접 추출한다 (세션 변수보다 신뢰도가 높다).
    _CRUD_UUID=$(echo "$_CRUD_PATH" | sed -n 's#.*/session-env/\([^/]*\)/evidence/.*#\1#p')
    _CRUD_UUID="${_CRUD_UUID:-${PIPELINE_UUID:-}}"
    _CRUD_SCRIPT=""
    for _c in \
      "${CLAUDE_PROJECT_DIR:-}/.claude/skills/otest_make/scripts/verify_crud_executed.py" \
      "${HARNESS_HOME:-$HOME/.harness}/current/skills/otest_make/scripts/verify_crud_executed.py"
    do
      if [[ -n "$_c" && -f "$_c" ]]; then _CRUD_SCRIPT="$_c"; break; fi
    done
    # otest_done(최종 마킹)은 --final 로 검사한다 — evidence 부재를 통과시키지 않는다.
    # make_ok(중간 기록)은 부트스트랩상 최초 부재가 정상이므로 --final 을 주지 않는다.
    # make_ok 를 copy/move/rename/symlink/dir_* 로 만들면 원본을 --evidence 로 검사한다(D6).
    #   원본이 비었거나 부재면 --evidence 없이 현행대로(실제 도구도 원본 부재면 실패한다).
    _CRUD_ARGS=(--uuid "$_CRUD_UUID")
    if [[ "$_CRUD_PATH" == */evidence/otest_done ]]; then
      _CRUD_ARGS+=(--final)
    elif [[ -n "$_CRUD_SRC" && -f "$_CRUD_SRC" ]]; then
      _CRUD_ARGS+=(--evidence "$_CRUD_SRC")
    fi
    # [conv_179163042411 역라우팅 #2] 순서: 판정기 → FAIL 이면 분류기 → (픽스처 한정) 1회 재판정 → 그래도 FAIL 이면 분류별 차단.
    #   판정기 부재·UUID 미상은 종전처럼 통과.
    if [[ -n "$_CRUD_SCRIPT" && -n "$_CRUD_UUID" ]]; then
      # [c174 oi-fix-4] verify --final 실측 30~36s 가 write_guard 예산(time_budget 7.5s)·내부 timeout 20 을 구조적으로
      #   넘어 otest_done 쓰기가 영원히 보류됐다. 판정은 그대로 두고, 결과를 "실제로 읽은 입력"의 지문으로 캐시한다
      #   (lib/crud_gate_cache.py). 미적중이면 백그라운드 판정을 띄우고 4s 대기 → 못 끝나면 rc=75(진행 중) 차단.
      #   래퍼 부재 시에는 종전 경로 그대로.
      _CRUD_CACHE_LIB="${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/crud_gate_cache.py"
      if [[ -f "$_CRUD_CACHE_LIB" ]]; then
        _CRUD_OUT=$(CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" \
                    timeout 6 python3 "$_CRUD_CACHE_LIB" gate --script "$_CRUD_SCRIPT" \
                      --cache-dir "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${_CRUD_UUID}/logs/crud_gate" \
                      --wait 4 -- "${_CRUD_ARGS[@]}" 2>&1) && _CRUD_RC=0 || _CRUD_RC=$?
      else
        _CRUD_OUT=$(CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" \
                    timeout 20 python3 "$_CRUD_SCRIPT" "${_CRUD_ARGS[@]}" 2>&1) && _CRUD_RC=0 || _CRUD_RC=$?
      fi
      # [사이클182 반복1 A8] timeout 래퍼가 판정을 끊은 경우(124·137)는 판정기의 FAIL 이 아니다 — 종전에는 분류기로 넘어가
      #   '분류=UNKNOWN 조치=REROUTE_DEV 마킹 거부' 로 확정 거부했다(부하 40병렬 실측 22/40, 판정기는 O2 NO_CRITERIA 통과 입력).
      #   보류(75)와 같은 분기로 보낸다 — 여전히 차단(exit 2, fail-closed)이며 바뀌는 것은 거짓 거부 안내뿐이다.
      if [[ "$_CRUD_RC" -eq 124 || "$_CRUD_RC" -eq 137 ]]; then
        echo "{\"decision\":\"block\",\"reason\":\"⏳ [F-CRUD-1] ${_CRUD_PATH##*/} 판정 시간 초과(rc=${_CRUD_RC}, 시스템 정체) — 아직 거부가 아닙니다. 판정불가는 통과가 아니므로 이번 호출은 보류합니다. 30~60초 뒤 ★같은 호출★ 을 다시 하십시오(백그라운드 판정이 끝났으면 캐시로 즉시 판정됩니다). CRUD_GATE_TIMEOUT\"}"
        exit 2
      fi
      if [[ "$_CRUD_RC" -eq 75 ]]; then
        _CRUD_MSG=$(echo "$_CRUD_OUT" | grep -m1 '^CRUD_GATE_PENDING' | tr '"\\' "''")
        echo "{\"decision\":\"block\",\"reason\":\"⏳ [F-CRUD-1] ${_CRUD_PATH##*/} 판정 진행 중 — 아직 거부가 아닙니다. 30~60초 뒤 ★같은 호출★ 을 다시 하십시오(결과가 캐시되어 즉시 판정됩니다). ${_CRUD_MSG}\"}"
        exit 2
      fi
      # [conv_179163042411 역라우팅 #2] FAIL(rc≠0·≠75) → 분류기 → TEST_FIXTURE_ONLY 면 --exclude-test-fixtures 로 1회 재판정.
      #   재판정은 DB 접촉 축에서 시험 픽스처만 빼며, CRUD 선언 항목의 증거·스냅샷 요구는 그대로다(판정기 C26 rev4).
      #   같은 마커가 경로 2형태로 두 번 돌므로 재판정 통과는 같은 인자에 한해 재사용한다.
      if [[ "$_CRUD_RC" -ne 0 && -n "$_CRUD_RECHECK_OK" && "$_CRUD_RECHECK_OK" == "${_CRUD_ARGS[*]}" ]]; then
        continue
      fi
      if [[ "$_CRUD_RC" -ne 0 ]]; then
        _crud_triage "$_CRUD_OUT" "$_CRUD_RC"
        _CRUD_RECHECK_RC=""
        if [[ "$_CRUD_TACTION" == "RECHECK" ]]; then
          if [[ -f "$_CRUD_CACHE_LIB" ]]; then
            _CRUD_OUT2=$(CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" \
                         timeout 4 python3 "$_CRUD_CACHE_LIB" gate --script "$_CRUD_SCRIPT" \
                           --cache-dir "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${_CRUD_UUID}/logs/crud_gate" \
                           --wait 2 -- "${_CRUD_ARGS[@]}" --exclude-test-fixtures 2>&1) && _CRUD_RECHECK_RC=0 || _CRUD_RECHECK_RC=$?
          else
            _CRUD_OUT2=$(CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" \
                         timeout 4 python3 "$_CRUD_SCRIPT" "${_CRUD_ARGS[@]}" --exclude-test-fixtures 2>&1) && _CRUD_RECHECK_RC=0 || _CRUD_RECHECK_RC=$?
          fi
          if [[ "$_CRUD_RECHECK_RC" -eq 0 ]]; then
            _crud_triage_log "$_CRUD_TCLASS" "RECHECK" "$_CRUD_RC" 0
            _CRUD_RECHECK_OK="${_CRUD_ARGS[*]}"
            echo "ℹ️ [F-CRUD-1] 테스트 픽스처만 DB 접촉으로 잡혀 픽스처 제외 재판정으로 통과 — ${_CRUD_PATH##*/}" >&2
            continue
          fi
          if [[ "$_CRUD_RECHECK_RC" -eq 124 || "$_CRUD_RECHECK_RC" -eq 137 ]]; then
            _crud_triage_log "$_CRUD_TCLASS" "RECHECK" "$_CRUD_RC" "$_CRUD_RECHECK_RC"
            echo "{\"decision\":\"block\",\"reason\":\"⏳ [F-CRUD-1] ${_CRUD_PATH##*/} 픽스처 제외 재판정 시간 초과(rc=${_CRUD_RECHECK_RC}, 시스템 정체) — 아직 거부가 아닙니다. 판정불가는 통과가 아니므로 이번 호출은 보류합니다. 30~60초 뒤 ★같은 호출★ 을 다시 하십시오. CRUD_GATE_TIMEOUT\"}"
            exit 2
          fi
          if [[ "$_CRUD_RECHECK_RC" -eq 75 ]]; then
            _crud_triage_log "$_CRUD_TCLASS" "RECHECK" "$_CRUD_RC" 75
            _CRUD_MSG=$(echo "$_CRUD_OUT2" | grep -m1 '^CRUD_GATE_PENDING' | tr '"\\' "''")
            echo "{\"decision\":\"block\",\"reason\":\"⏳ [F-CRUD-1] ${_CRUD_PATH##*/} 픽스처 제외 재판정 진행 중 — 아직 거부가 아닙니다. 30~60초 뒤 ★같은 호출★ 을 다시 하십시오(결과가 캐시되어 즉시 판정됩니다). ${_CRUD_MSG}\"}"
            exit 2
          fi
          # 재판정도 FAIL — 재판정 출력으로 다시 분류한다(다시 RECHECK 가 나오면 UNKNOWN 취급).
          _CRUD_OUT="$_CRUD_OUT2"; _CRUD_RC="$_CRUD_RECHECK_RC"
          _crud_triage "$_CRUD_OUT" "$_CRUD_RC"
          if [[ "$_CRUD_TACTION" == "RECHECK" ]]; then
            _CRUD_TCLASS="UNKNOWN"; _CRUD_TACTION="REROUTE_DEV"
          fi
        fi
        _crud_triage_log "$_CRUD_TCLASS" "$_CRUD_TACTION" "$_CRUD_RC" "$_CRUD_RECHECK_RC"
        # [2026-10-20 conv_179239511726 → 2026-10-27 unblock3 자동 승인] DECLARATION_CONFLICT 한정. 통과 판정은 같은 인자의 두 번째 경로
        #   형태에 재사용한다(_CRUD_RECHECK_OK — 위 재판정 통과와 같은 재사용 규칙).
        _CRUD_ASKQ_NOTE=""
        if [[ "$_CRUD_TCLASS" == "DECLARATION_CONFLICT" ]]; then
          if _crud_askq_ok "$_CRUD_OUT"; then
            _crud_triage_log "$_CRUD_TCLASS" "ASKQ_APPROVED" "$_CRUD_RC" "$_CRUD_RECHECK_RC"
            _CRUD_RECHECK_OK="${_CRUD_ARGS[*]}"
            echo "ℹ️ [F-CRUD-1] DECLARATION_CONFLICT — 허용 코드 범위 안이라 자동 승인으로 통과(사용자 지시 2026-10-27 15:53) — ${_CRUD_PATH##*/} (logs/crud_gate_override.log)" >&2
            continue
          fi
        fi
        source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/write_error.sh" 2>/dev/null || true
        declare -F log_hook_error >/dev/null 2>&1 && \
          log_hook_error "HOOK_BLOCK_CRUD_EVIDENCE" "$TOOL_NAME" "CRUD 실행증거 게이트 미통과(rc=${_CRUD_RC}, 분류=${_CRUD_TCLASS}) — ${_CRUD_PATH}" "$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null)"
        _CRUD_MSG=$(echo "$_CRUD_OUT" | head -c 500 | tr '\n' ' ' | tr '"\\' "''")
        echo "{\"decision\":\"block\",\"reason\":\"🚫 [F-CRUD-1] 분류=${_CRUD_TCLASS} 조치=${_CRUD_TACTION} — ${_CRUD_THINT}. ${_CRUD_ASKQ_NOTE:+${_CRUD_ASKQ_NOTE}. ${_CRUD_ASKQ_GUIDE} }${_CRUD_FAIL_GUIDE} CRUD 실행증거 미확보 — ${_CRUD_PATH##*/} 마킹 거부(${TOOL_NAME}). 차단 확인은 저장 검증이 아니다. 개발 DB 에서 실제로 저장을 태우고 evidence 의 해당 항목에 write_log + 상태변화 증거(count/rowset/value/modified 전후 중 하나)를 기록한 뒤 재시도하라. COUNT 불변 = 미실행 이 아니다 — 전건 재작성형 테이블은 rowset 으로 잡아라. (rc=${_CRUD_RC}) ${_CRUD_MSG}\"}"
        exit 2
      fi
    fi
  done <<<"$_CRUD_ROWS"
fi

# --- D1 (conv_179160716700): untracked 기준선 보관 — 편집 직전 원본을 session-env/<U>/baseline_untracked/ 에 둔다 ---
# 배경(R1): verify_crud_executed 는 git 기준선이 없는 파일을 통째로 스캔해, 파이프라인 이전부터 있던 SQL 문자열을
#   "이번 변경" 으로 오판했다. 이 hook 은 도구 실행 ★전★ 에 돌므로 지금 디스크 내용이 편집 전 원본이다.
# 보관 조건(전부): 편집 도구 / 일반 파일 / ≤2MB / ★mtime·ctime 모두 < pipeline_start_time★
#   (셸로 먼저 DML 을 넣고 file_edit 하면 오염본이 기준선이 되는 회피 통로 차단 — 미충족이면 보관하지 않고 판정기는 전체 스캔)
#   / 현재 파이프라인 기준선 미보관(.orig mtime ≥ start 면 이미 보관 — 이전 파이프라인 잔존본은 덮어쓴다).
# 형식(odev-1 판정기와 계약): <sha1(realpath -m 경로)>.orig(원본 바이트) + .path(realpath 1줄). git 추적 파일은 제외(ls-files 공백만 —
#   판정기는 git 기준선이 없는 full 분기에서만 쓴다). 파이프라인 UUID = 조상 argv --parent-session-id → PIPELINE_UUID → hook session_id
#   중 session-env/<U>/pipeline_start_time 이 있고 state 가 IDLE 이 아닌 첫 값. 모든 실패는 침묵(보관 실패 = 종전 전체 스캔, fail-closed).
case "$TOOL_NAME" in
  mcp__oio__file_write|mcp__oio__file_edit|Write|Edit|MultiEdit)
    _BL_TI="${_CRUD_TI:-$(echo "$INPUT" | jq -c '.tool_input // {}' 2>/dev/null || echo "")}"
    _BL_RAWS=$(jq -r '[.path,.file_path,.filepath] | map(select(type=="string" and . != ""))[]' <<<"$_BL_TI" 2>/dev/null)
    _BL_DIR=""; _BL_START=""; _BL_RESOLVED=""
    while IFS= read -r _bl_raw; do
      [[ -n "$_bl_raw" && -f "$_bl_raw" ]] || continue
      _bl_rp=$(realpath -m -- "$_bl_raw" 2>/dev/null) || continue
      [[ -n "$_bl_rp" && "$_bl_rp" != */session-env/* ]] || continue
      _bl_st=$(stat -c '%s %Y %Z' -- "$_bl_rp" 2>/dev/null) || continue
      read -r _bl_sz _bl_mt _bl_ct <<<"$_bl_st"
      [[ "$_bl_sz" =~ ^[0-9]+$ && "$_bl_mt" =~ ^[0-9]+$ && "$_bl_ct" =~ ^[0-9]+$ ]] || continue
      (( _bl_sz <= 2097152 )) || continue
      if [[ -z "$_BL_RESOLVED" ]]; then
        _BL_RESOLVED=1
        _bl_cands=""
        _bl_p=$$; _bl_i=0
        while [[ -n "$_bl_p" && "$_bl_p" != "1" && $_bl_i -lt 12 ]]; do
          _bl_par=$(tr '\0' ' ' 2>/dev/null < "/proc/${_bl_p}/cmdline" \
            | grep -oP -- '--parent-session-id \K[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
          [[ -n "$_bl_par" ]] && { _bl_cands+="$_bl_par"$'\n'; break; }
          _bl_p=$(awk '/^PPid:/{print $2}' "/proc/${_bl_p}/status" 2>/dev/null)
          _bl_i=$((_bl_i + 1))
        done
        _bl_cands+="${PIPELINE_UUID:-}"$'\n'"$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
        while IFS= read -r _bl_u; do
          [[ "$_bl_u" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || continue
          _bl_sd="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${_bl_u}"
          [[ -f "$_bl_sd/pipeline_start_time" ]] || continue
          [[ "$(head -c 8 -- "$_bl_sd/state" 2>/dev/null)" == IDLE* ]] && continue
          _bl_s=$(head -c 32 -- "$_bl_sd/pipeline_start_time" 2>/dev/null | tr -dc '0-9')
          [[ -n "$_bl_s" ]] || continue
          _BL_DIR="$_bl_sd/baseline_untracked"; _BL_START="$_bl_s"; break
        done <<<"$_bl_cands"
      fi
      [[ -n "$_BL_DIR" ]] || break
      (( _bl_mt < _BL_START && _bl_ct < _BL_START )) || continue
      # 계획 D1 (b): git 추적 파일은 판정기가 git 기준선을 쓰므로 보관하지 않는다(불필요 복사 방지).
      #   ls-files 가 비면(untracked 또는 저장소 밖) 보관 대상. git 실패·타임아웃은 보관 쪽으로(무해 — 판정기가 full 분기에서만 쓴다).
      _bl_tracked=$(cd -- "$(dirname -- "$_bl_rp")" 2>/dev/null && timeout 2 git ls-files -- "$(basename -- "$_bl_rp")" 2>/dev/null)
      [[ -z "$_bl_tracked" ]] || continue
      _bl_h=$(printf '%s' "$_bl_rp" | sha1sum 2>/dev/null | cut -c1-40)
      [[ "$_bl_h" =~ ^[0-9a-f]{40}$ ]] || continue
      _bl_o="$_BL_DIR/${_bl_h}.orig"
      if [[ -f "$_bl_o" ]]; then
        _bl_om=$(stat -c %Y -- "$_bl_o" 2>/dev/null || echo 0)
        (( _bl_om >= _BL_START )) && continue
      fi
      mkdir -p -- "$_BL_DIR" 2>/dev/null || break
      _bl_tmp="$_BL_DIR/.${_bl_h}.$$"
      # cp -p 금지 — 원본 mtime(<start)이 복사되면 판정기가 이전 파이프라인 잔존본으로 오인한다.
      if timeout 3 cp -- "$_bl_rp" "${_bl_tmp}.orig" 2>/dev/null && printf '%s\n' "$_bl_rp" > "${_bl_tmp}.path" 2>/dev/null; then
        mv -f -- "${_bl_tmp}.orig" "$_bl_o" 2>/dev/null && mv -f -- "${_bl_tmp}.path" "$_BL_DIR/${_bl_h}.path" 2>/dev/null
      fi
      rm -f -- "${_bl_tmp}.orig" "${_bl_tmp}.path" 2>/dev/null
    done <<<"$_BL_RAWS"
    ;;
esac

# --- P2 (사이클168 D8·D10 · 계획 §5.0 I-2): goal.json 을 copy/move/rename 으로 배치하면 정적 검사 위임 ---
# 배경: goal_autoscript_guard 는 settings 에 file_write 로만 등록돼 있어, 계약을 file_copy/move/rename 으로
#       놓으면 F-GOALAS-4(세션 절대경로 금지)를 통째로 건너뛴다. settings 는 이번 사이클에 바꾸지 않는다(D8).
# 형태: 정적 전용 모드(GOAL_AS_STATIC_ONLY=1) — auto_script 를 실행하지 않는다. timeout 22초(사이클182 실측 근거 아래). stdin 원문 그대로.
# rc:   2 → guard 출력 그대로 차단 / 0 → 출력은 stderr 로만, 계속 / 그 외(124 포함) → 판정불가 = 차단(D10).
#       guard 파일 부재 → 통과(현행 유지 — 완화 아님).
# ★file_write 는 위임하지 않는다★ — guard 가 settings 에 직접 등록돼 있어 위임하면 두 번 돈다.
# [사이클182 항목4] 위임 확장 — 대상에 plans/acceptance_criteria.json 추가(copy/move/rename), mcp__oio__file_edit 도 위임
#   (goal.json·AC 대상일 때. guard 가 적용 후 내용을 모사해 정적 판정한다 — 계획 §2-4). settings.json 은 그대로다.
case "$TOOL_NAME" in
  mcp__oio__file_copy|mcp__oio__file_move|mcp__oio__file_rename|mcp__oio__file_edit)
    if [[ "$_CRUD_TI" == *goal.json* || "$_CRUD_TI" == *acceptance_criteria.json* ]]; then
      _GAS_GUARD="${HARNESS_HOME:-$HOME/.harness}/current/hooks/PreToolUse_goal_autoscript_guard.sh"
      _GAS_HIT=""
      while IFS=$'\t' read -r _gas_p _gas_s; do
        case "$_gas_p" in
          */session-env/*/goal.json|*/session-env/*/plans/acceptance_criteria.json) _GAS_HIT="$_gas_p"; break ;;
        esac
      done <<<"$(_r1_targets "$_CRUD_TI")"
      if [[ -n "$_GAS_HIT" && -f "$_GAS_GUARD" ]]; then
        # [사이클182 L-606] timeout 3 → 22초. 실측(2026-10-12, 실제 goal.json·AC 로 file_edit·file_copy 정적 판정):
        #   무부하 중앙 488ms·최대 583ms(n=20) / CPU 바쁜 루프 16개(load≈30) 중앙 3.2s·최대 4.9s(n=20) /
        #   32개(load 28~46) 중앙 6.7s·최대 10.6s(n=12). 기존 3초는 load≈30 에서도 과반이 rc=124 → 판정불가 차단이었다.
        #   상한 = 최대 10.6s × 2 이상 = 22초(고정). 바깥 time_budget(7.5→최대 9초)이 먼저 끊어도 본문은 계속 돌아
        #   늦은 판정 캐시(90초)에 남으므로, 같은 호출 재시도가 그 판정을 받는다(3초면 재시도도 영원히 rc=124).
        #   시간 초과(124)는 여전히 판정불가 = 차단(fail-closed, 아래 분기 불변).
        _GAS_OUT=$(printf '%s' "$INPUT" | GOAL_AS_STATIC_ONLY=1 timeout 22 bash "${HARNESS_HOME:-$HOME/.harness}/current/hooks/PreToolUse_goal_autoscript_guard.sh" 2>&1); _GAS_RC=$?
        if [[ "$_GAS_RC" -eq 2 ]]; then
          printf '%s\n' "$_GAS_OUT"
          exit 2
        elif [[ "$_GAS_RC" -eq 0 ]]; then
          [[ -n "$_GAS_OUT" ]] && printf '%s\n' "$_GAS_OUT" >&2
        else
          echo "{\"decision\":\"block\",\"reason\":\"🚫 [F-GOALAS-4] goal.json·acceptance_criteria.json 정적 검사 판정불가(rc=${_GAS_RC}) — 판정불가는 통과가 아닙니다. mcp__oio__file_write 로 계약을 쓰십시오.\"}"
          exit 2
        fi
      fi
    fi
    ;;
esac

# --- F-PSW-1 (conv_179163042411 (8) · L-570): 폭 미지정 ps 명령줄 조회를 hooks/·scripts/ 에 새로 넣는 쓰기 차단 ---
# 배경: hook 은 tmux COLUMNS=80 을 상속해 `ps -o args` 가 잘린다(살아 있는 팀원을 죽은 것으로 판정한 사고, 13곳 정정).
#   정적 시험(tests/test_ps_width_static.sh)은 사후 검사라, 작성 시점에 같은 규칙으로 먼저 막는다.
# 규칙 단일 출처: lib/ps_width_check.sh 의 ps_width_violation (정적 시험과 같은 lib 를 source).
# 범위: 파일 도구(file_write/file_edit/Write/Edit/MultiEdit) · 대상 */.claude/hooks/* 또는 */.claude/scripts/* 의 .sh/.py
#   (/tests/·backup·__pycache__ 제외 — 정적 시험과 동일). 타 프로젝트의 scripts/ 는 대상이 아니다.
#   ★새로 들어가는 줄만★ 본다 — file_edit 는 new 에만 있는 줄, file_write 는 기존 파일에 없던 줄. 이미 있던 줄은 건드리지 않는다.
# 성격: lint(보안 게이트 아님) → fail-open. lib 부재·판독 실패·후보 줄 100 초과 시 이 검사만 건너뛴다(전 세션 쓰기 마비 방지).
# 잔존: 셸로 파일 쓰기(cat >·sed -i)는 검사하지 않는다 — 정적 시험이 최종 방어선.
case "$TOOL_NAME" in
  mcp__oio__file_write|mcp__oio__file_edit|Write|Edit|MultiEdit)
    _PSW_LIB="${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/ps_width_check.sh"
    if [[ -r "$_PSW_LIB" && "$_CRUD_TI" == *ps* ]]; then
      _PSW_PATH=$(jq -r '[.path,.file_path,.filepath] | map(select(type=="string" and . != ""))[0] // empty' <<<"$_CRUD_TI" 2>/dev/null) || _PSW_PATH=""
      _PSW_ON=""
      case "$_PSW_PATH" in
        */tests/*|*backup*|*__pycache__*) ;;
        */.claude/hooks/*.sh|*/.claude/hooks/*.py|*/.claude/scripts/*.sh|*/.claude/scripts/*.py) _PSW_ON=1 ;;
      esac
      if [[ -n "$_PSW_ON" ]] && source "$_PSW_LIB" 2>/dev/null && declare -F ps_width_violation >/dev/null 2>&1 && [[ -n "${PS_WIDTH_PREFILTER_RE:-}" ]]; then
        case "$TOOL_NAME" in
          mcp__oio__file_write|Write)
            _PSW_NEW=$(jq -r '[.content,.text,.body,.data,.new_content,.new_text] | map(select(type=="string"))[0] // empty' <<<"$_CRUD_TI" 2>/dev/null) || _PSW_NEW=""
            if [[ -f "$_PSW_PATH" ]]; then
              _PSW_NEW=$(printf '%s\n' "$_PSW_NEW" | grep -vxF -f "$_PSW_PATH" 2>/dev/null) || _PSW_NEW=""
            fi
            ;;
          MultiEdit)
            _PSW_NEW=$(jq -r '[.edits[]?.new_string | select(type=="string")] | join("\n")' <<<"$_CRUD_TI" 2>/dev/null) || _PSW_NEW=""
            _PSW_OLD=$(jq -r '[.edits[]?.old_string | select(type=="string")] | join("\n")' <<<"$_CRUD_TI" 2>/dev/null) || _PSW_OLD=""
            [[ -n "$_PSW_OLD" ]] && { _PSW_NEW=$(printf '%s\n' "$_PSW_NEW" | grep -vxF -f <(printf '%s\n' "$_PSW_OLD") 2>/dev/null) || _PSW_NEW=""; }
            ;;
          *)
            _PSW_NEW=$(jq -r '[.new_string,.new,.new_content,.new_text,.replace] | map(select(type=="string"))[0] // empty' <<<"$_CRUD_TI" 2>/dev/null) || _PSW_NEW=""
            _PSW_OLD=$(jq -r '[.old_string,.old,.old_content,.old_text,.search] | map(select(type=="string"))[0] // empty' <<<"$_CRUD_TI" 2>/dev/null) || _PSW_OLD=""
            [[ -n "$_PSW_OLD" ]] && { _PSW_NEW=$(printf '%s\n' "$_PSW_NEW" | grep -vxF -f <(printf '%s\n' "$_PSW_OLD") 2>/dev/null) || _PSW_NEW=""; }
            ;;
        esac
        # 사전 필터 — ps 호출 단어가 있는 줄만 줄 판정(줄당 grep 여러 번이라 큰 쓰기에서 시간 예산 보호)
        _PSW_CAND=$(printf '%s\n' "$_PSW_NEW" | grep -E "$PS_WIDTH_PREFILTER_RE" 2>/dev/null | head -n 101) || _PSW_CAND=""
        if [[ -n "$_PSW_CAND" ]]; then
          _PSW_NC=$(printf '%s\n' "$_PSW_CAND" | wc -l)
          if (( _PSW_NC > 100 )); then
            echo "⚠️ [F-PSW-1] ps 후보 줄 100 초과 — 작성 시점 폭 검사를 건너뜁니다(정적 시험 tests/test_ps_width_static.sh 로 확인하십시오)." >&2
          else
            _PSW_HITS=""; _PSW_HN=0
            while IFS= read -r _psw_l; do
              if ps_width_violation "$_psw_l"; then
                _PSW_HN=$((_PSW_HN + 1))
                (( _PSW_HN <= 3 )) && _PSW_HITS+=" [$(printf '%s' "$_psw_l" | tr -d '\000-\037' | tr '"\\' "''" | sed -E 's/^[[:space:]]+//' | cut -c1-160)]"
              fi
            done <<<"$_PSW_CAND"
            if (( _PSW_HN > 0 )); then
              echo "{\"decision\":\"block\",\"reason\":\"🚫 [F-PSW-1] 폭 미지정 ps 명령줄 조회 ${_PSW_HN}건 — hook 은 COLUMNS=80 을 상속해 ps -o args/cmd/command 출력이 잘립니다(L-570). ps 에 -ww 를 붙이거나(예: ps -eww -o args=), 폭이 의미 없는 표시 전용이면 줄 끝에 # ps-width-ok 를 붙이십시오. 대상: ${_PSW_PATH}${_PSW_HITS}\"}"
              exit 2
            fi
          fi
        fi
      fi
    fi
    ;;
esac

# --- 탐색 도구 조기 통과 (Grep/Glob/Serena 탐색) ---
# 읽기 전용 도구는 최소한의 OK 상태 체크만 수행 (복잡한 처리 불필요)
case "$TOOL_NAME" in
  Read|Grep|Glob|mcp__oio__file_read|mcp__oio__find|mcp__oio__list_dir|\
  mcp__plugin_serena_serena__find_file|mcp__plugin_serena_serena__find_symbol|\
  mcp__plugin_serena_serena__get_symbols_overview|mcp__plugin_serena_serena__search_for_pattern|\
  mcp__plugin_serena_serena__find_referencing_symbols|mcp__plugin_serena_serena__list_dir|\
  mcp__plugin_serena_serena__read_file|\
  mcp__serena__find_file|mcp__serena__find_symbol|\
  mcp__serena__get_symbols_overview|mcp__serena__search_for_pattern|\
  mcp__serena__find_referencing_symbols|mcp__serena__list_dir|\
  mcp__serena__read_file)
    # OK 상태에서만 메인 세션 탐색 차단 (L-248) — 나머지는 즉시 통과
    # [사이클206 NEW-b] 탐색 경로 판정 — `.pattern` 은 경로가 아니므로 쓰지 않는다(검색어에 든 경로 글자로 판정이 바뀌던 결함).
    #   경로는 path/file_path/filepath 만, 비면 입력의 cwd(경로 없는 Grep·Glob 은 cwd 탐색). 상대경로는 cwd 기준, ~ 는 $HOME.
    #   _WG_XP_RAW=정리 전 경로(절대화만), _WG_XP_RES=realpath -m 정규화 경로(.. 와 심볼릭 링크를 푼다 — hooks/../../ 우회 차단).
    _wg_explore_paths() {
      local _p _cwd
      _p=$(echo "$INPUT" | jq -r '.tool_input.path // .tool_input.file_path // .tool_input.filepath // empty' 2>/dev/null) || _p=""
      _cwd=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || _cwd=""
      [[ -n "$_p" ]] || _p="$_cwd"
      [[ "$_p" == "~" || "$_p" == "~/"* ]] && _p="${HOME}${_p#\~}"
      [[ -n "$_p" && "$_p" != /* && -n "$_cwd" ]] && _p="${_cwd%/}/${_p}"
      _WG_XP_RAW="$_p"
      _WG_XP_RES=""
      [[ -n "$_p" ]] && _WG_XP_RES=$(realpath -m -- "$_p" 2>/dev/null)
      [[ -n "$_WG_XP_RES" ]] || _WG_XP_RES="$_p"
    }
    _UUID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null) || _UUID=""
    if [[ -n "$_UUID" ]]; then
      _STATE_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${_UUID}/state"
      # Fix 4: state_read (flock) 통일 — cat|awk 직접 읽기는 race condition 유발
      source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/session_id.sh" 2>/dev/null || true
      _STATE=$(state_read "$_STATE_FILE" 2>/dev/null | awk '{print $1}') || _STATE=""
      # Fix 11 (L-NEW): __LOCK_FAIL__ — 탐색 도구는 읽기 전용이므로 fail-open (통과)
      if [[ "$_STATE" == "__LOCK_FAIL__" ]]; then
        exit 0
      fi
      # Phase B (L-431): state OK 제거 → state=PLAN AND classification=OK 차단으로 등가 변환
      # 의미 보존: ok 단계(분류 미확정) 진입 직후의 코드 탐색 차단 (L-248)
      _CLASSIFICATION=$(cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${_UUID}/classification" 2>/dev/null | tr -d '\r\n' || echo "")
      if [[ "$_STATE" == "PLAN" && "$_CLASSIFICATION" == "OK" ]]; then
        # PIPELINE_UUID 있으면 팀에이전트 → 통과
        # 2026-09-07 사이클90: 아래 Fix 1 과 동일 사유로 프로세스 트리 판별 보강.
        # (PIPELINE_UUID 는 hook 자식 프로세스에 전달되지 않아 단독 판정 시 항상 unset — 396행 실측 주석 참조)
        _OK_IS_TEAM_AGENT="${PIPELINE_UUID:-}"
        if [[ -z "$_OK_IS_TEAM_AGENT" ]]; then
          _OK_PID_WALK=$$
          _OK_DEPTH_WALK=0
          while [[ $_OK_DEPTH_WALK -lt 10 && -n "$_OK_PID_WALK" && "$_OK_PID_WALK" != "1" ]]; do
            _OK_CMDLINE_WALK=$(tr '\0' ' ' 2>/dev/null < "/proc/${_OK_PID_WALK}/cmdline")
            if [[ "$_OK_CMDLINE_WALK" =~ --parent-session-id[[:space:]]+([0-9a-f-]{36}) ]]; then
              _OK_IS_TEAM_AGENT="${BASH_REMATCH[1]}"
              break
            fi
            # PPid 는 /proc/PID/status 에서 읽는다. /proc/PID/stat 의 $4 는 comm 필드가
            # "(bash)" 처럼 괄호/공백을 포함하면 컬럼이 밀려 잘못된 값을 준다
            # (실측: $4 가 상태문자 "S" 로 잡혀 /proc/S/cmdline 참조 → 조기 이탈).
            _OK_PID_WALK=$(awk '/^PPid:/{print $2}' "/proc/${_OK_PID_WALK}/status" 2>/dev/null)
            _OK_DEPTH_WALK=$((_OK_DEPTH_WALK + 1))
          done
        fi
        if [[ -n "$_OK_IS_TEAM_AGENT" ]]; then
          exit 0
        fi
        # L-NEW (6차 감사): session-env 경로는 OK 상태 탐색 허용 — 오케스트레이션 인프라
        # 이유: UUID fallback 탐색, stale 감지 등 ok 절차 자체가 session-env/ 읽기 필요
        # [사이클206 NEW-b] 정규화 경로로 판정한다. 허용: session-env·hooks(종전) + evidence(사이클 표본·증거, 코드 아님)
        #   + /tmp(scratchpad·임시 — bash_exec /tmp 허용과 같은 기준, 링크는 realpath 로 풀려 실제 위치로 판정)
        #   + 세션 메모리(<CLAUDE_CONFIG_DIR>/projects/*/memory/ — NTFS 링크일 수 있어 정리 전 경로로 보되 .. 조각은 불허).
        #   그 밖(프로젝트 소스·PROJECT.md·경로 없는 탐색)은 종전대로 [L-248] 차단.
        _wg_explore_paths
        _OK_EXPLORE_PATH="$_WG_XP_RES"
        _OK_CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
        if [[ "$_OK_EXPLORE_PATH" == */.claude/session-env/* || "$_OK_EXPLORE_PATH" == */.claude/hooks/* || \
              "$_OK_EXPLORE_PATH" == */.claude/evidence/* || "$_OK_EXPLORE_PATH" == /tmp/* || \
              "$_OK_EXPLORE_PATH" == */.claude/session-env || "$_OK_EXPLORE_PATH" == */.claude/evidence ]]; then
          exit 0
        fi
        if [[ "$_WG_XP_RAW" == "$_OK_CLAUDE_DIR"/projects/*/memory/* && "$_WG_XP_RAW" != *'/../'* && "$_WG_XP_RAW" != *'/./'* && \
              "$_WG_XP_RAW" != */.. ]]; then
          exit 0
        fi
        echo "{\"decision\":\"block\",\"reason\":\"❌ [L-248] ok 단계에서 코드 탐색 금지! ok는 분류+spawn만 수행합니다. 코드 탐색은 oplan에 위임하세요.\"}"
        exit 2
      fi
      # Fix 1 (L-NEW): PLAN/DEV/TEST/DONE 상태에서 메인의 NTFS 경로 탐색 차단
      # 팀에이전트(PIPELINE_UUID 있음)는 통과. .claude/ 경로도 통과.
      #
      # ── ★2026-09-07 사이클90 — 팀에이전트 판별을 프로세스 트리로 보강★ ──────────
      # 문제: 이 블록은 팀에이전트 면제를 ${PIPELINE_UUID} 환경변수 단독으로 판정했다.
      #   그런데 ★같은 파일 396~397행이 이미 실측으로 기록해 두었다★ —
      #   "PIPELINE_UUID 환경변수는 실측 결과 hook 자식 프로세스에 전달되지 않는다
      #    (env/printenv 에 PIPELINE_UUID 자체가 없음)."
      #   ⇒ 이 값은 사실상 항상 unset 이므로 ★면제 분기가 도달 불가능한 사문(dead code)★ 이었고,
      #     모든 팀에이전트가 "메인"으로 판정되어 NTFS 탐색이 전면 차단됐다.
      #   실사고(2026-09-07): oplan 이 프로젝트 파일을 한 줄도 읽지 못해 계획 수립 실패.
      #   위임받은 서브에이전트 4명(Explore 2 + general-purpose 2)도 전원 동일 차단.
      #   ⇒ hook 이 "팀에이전트에 위임하라"고 안내하는데 그 위임 대상도 차단되는 순환 교착이었다.
      #
      # 조치: 396~412행의 _COMMIT_UUID_EARLY 와 ★동일한 검증된 패턴★ 을 적용한다 —
      #   프로세스 트리 조상에서 `--parent-session-id <36자 UUID>` 를 파싱한다.
      #   그 주석이 명시한 대로 이것이 "실측상 신뢰 가능한 유일한 경로"다.
      #   메인 에이전트는 이 플래그가 없으므로 차단이 그대로 유지된다(보호 범위 불변).
      _WG_IS_TEAM_AGENT="${PIPELINE_UUID:-}"
      if [[ -z "$_WG_IS_TEAM_AGENT" ]]; then
        _WG_PID_WALK=$$
        _WG_DEPTH_WALK=0
        while [[ $_WG_DEPTH_WALK -lt 10 && -n "$_WG_PID_WALK" && "$_WG_PID_WALK" != "1" ]]; do
          _WG_CMDLINE_WALK=$(tr '\0' ' ' 2>/dev/null < "/proc/${_WG_PID_WALK}/cmdline")
          if [[ "$_WG_CMDLINE_WALK" =~ --parent-session-id[[:space:]]+([0-9a-f-]{36}) ]]; then
            _WG_IS_TEAM_AGENT="${BASH_REMATCH[1]}"
            break
          fi
          # PPid 는 /proc/PID/status 에서 읽는다 (위 _OK_PID_WALK 주석 참조 — stat $4 컬럼 밀림 버그 회피).
          _WG_PID_WALK=$(awk '/^PPid:/{print $2}' "/proc/${_WG_PID_WALK}/status" 2>/dev/null)
          _WG_DEPTH_WALK=$((_WG_DEPTH_WALK + 1))
        done
      fi
      if [[ "$_STATE" =~ ^(PLAN|DEV|TEST|DONE)$ ]] && [[ -z "$_WG_IS_TEAM_AGENT" ]]; then
        # [사이클206 NEW-b] `.pattern` 은 경로로 쓰지 않는다(검색어 글자 판정 결함). 경로는 path 계열 → 없으면 cwd, 상대경로는 cwd 기준.
        _wg_explore_paths
        _EXPLORE_PATH="$_WG_XP_RAW"
        # .claude/ 경로는 허용 (오케스트레이션 메타 탐색)
        # F-NEW-1: symlink traversal 방어 — .claude/ 경로라도 realpath가 NTFS면 허용 불가
        # F-NEW-1-EXC (2026-08-01): CLAUDE_CONFIG_DIR가 세션 임시 디렉토리(/tmp/cc-*)인 구성에서
        # projects/*/memory/ 하위(MEMORY.md 등 자동메모리)는 정당한 NTFS symlink이므로 예외 허용
        #   [사이클206 NEW-b] 단 정리 전 경로에 .. 조각이 있으면 예외를 주지 않는다(memory/../../ 로 NTFS 소스를 가리키는 우회 차단).
        _CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
        if [[ "$_EXPLORE_PATH" == "$_CLAUDE_DIR"/*/memory/*.md && "$_EXPLORE_PATH" != *'/../'* && "$_EXPLORE_PATH" != *'/./'* ]]; then
          exit 0
        fi
        # [사이클206 NEW-b] 정리 전 경로가 .claude/ 밖이어도 정규화 경로가 NTFS 면 차단한다(/tmp/링크·../ 경유 NTFS 탐색).
        if [[ "$_EXPLORE_PATH" != "$_CLAUDE_DIR"/* && "$_EXPLORE_PATH" != /home/*/.claude/* ]] && \
           printf '%s' "$_WG_XP_RES" | grep -qP '^/mnt/[c-z]/'; then
          _EXPLORE_PATH="$_WG_XP_RES"
        fi
        if [[ "$_EXPLORE_PATH" == "$_CLAUDE_DIR"/* || "$_EXPLORE_PATH" == /home/*/.claude/* ]]; then
          _RESOLVED_EXPLORE=$(realpath -m "$_EXPLORE_PATH" 2>/dev/null || echo "$_EXPLORE_PATH")
          if echo "$_RESOLVED_EXPLORE" | grep -qP '^/mnt/[c-z]/'; then
            echo "{\"decision\":\"block\",\"reason\":\"❌ [F-NEW-1] .claude/ 심볼릭링크가 NTFS 경로를 가리킵니다 — symlink traversal 탐색 차단.\"}"
            exit 2
          fi
          : # .claude/ 탐색 허용 (symlink 해석 후 NTFS 아님)
        elif echo "$_EXPLORE_PATH" | grep -qP '/mnt/[c-z]/'; then
          echo "{\"decision\":\"block\",\"reason\":\"❌ [Fix 1/L-NEW] ${_STATE} 상태에서 메인의 NTFS 경로 탐색 금지! 팀에이전트에 위임 필수. (path: $(echo "$_EXPLORE_PATH" | head -c 60))\"}"
          exit 2
        fi
      fi
    fi
    exit 0
    ;;
esac

# --- oio 도구 조기 분기 (IDLE/FINISH만 메인 허용) ---
# --- F10(L-303 run_in_background 차단)은 2026-10-31 해제됐다 ---
# 무한 블로킹 원인은 bash_exec.py 백그라운드 경로(start_new_session + supervisor, Codex CR-4)로 이미 고쳐졌고
# 같은 경로를 자동 감지(_LONG_RUNNING_PATTERNS)가 매일 쓴다. 명시 플래그만 막던 잔재라 제거했다.

# --- F10-2: L-531 git stash 전역 차단 (멀티에이전트 작업트리 오염 방지) ---
# git stash는 작업트리 전체(모든 에이전트의 미커밋 변경분)를 대상으로 하므로
# 멀티에이전트 환경에서 타 에이전트 파일까지 함께 stash되는 사고를 유발한다 (2026-08-18 실사고).
# 팀/메인 구분 없이 전역 차단. 대안: 개별 파일 검증은 git diff/status로, 전체 되돌리기는 사용 금지.
# [cgit2 2026-10-27 해제] 사용자 지시 원문(10:52) "위험한 git도 막지 말고 그대로 진행해라" → 리드 확정(10:53).
#   git stash 차단을 통째로 끈다(실행·인용 텍스트 모두 통과). 종전에는 grep 패턴·commit 메시지 속 글자까지 막는 과차단도 있었다.
#   보호 파일(guard_promote 구성요소)을 stash 로 바꾸는 경로는 gp_gate(F-GUARD-PROMOTE)가 따로 판정한다 — 이 해제와 무관하게 유지.
#   되살릴 때는 아래 _WG_F102_ON 을 1 로 바꾼다(본문은 보존).
_WG_F102_ON=0
if [[ "$_WG_F102_ON" == 1 && "$TOOL_NAME" == "mcp__oio__bash_exec" ]]; then
  _wg_pre _STASH_CMD_EARLY "$_WG_CMD_OC" '.tool_input.command // .tool_input.cmd // empty'   # c205 D-9
  if [[ "$_STASH_CMD_EARLY" =~ git[[:space:]]+stash ]]; then
    echo '{"decision":"block","reason":"🚫 [L-531/F10-2] git stash 금지 — 작업트리 전체가 대상이라 멀티에이전트 환경에서 타 에이전트 파일까지 함께 담기는 사고 유발. 개별 파일 확인은 git diff/status 사용."}'
    exit 2
  fi
fi

# --- F-SEDI-1: 사이클202 — bash_exec 의 sed -i / perl -i 차단 (내장 Bash P1 과 같은 범위, L-1374) ---
# 배경: P1 의 sed/perl -i 차단은 내장 Bash 에만 걸려 있어 같은 명령이 mcp__oio__bash_exec 로는 통과했다(Mars L-1374 실측:
#       tool_name 만 바꾸면 Bash rc=2, bash_exec rc=0). 목적은 파일 내용 수정을 oio file_edit(BOM/CRLF 보존·Intent Lock)로 모으는 것.
# 예외: CR 제거 꼴(sed -i s/\r$// 파일, s/\r// 파일)은 CLAUDE.md CRLF 규칙의 정상 용도라 통과(F-WG-SELF 와 같은 기준). perl 은 예외 없음.
# 판정: sed/perl 글자가 있을 때만 python3 를 띄운다. heredoc 본문을 가린 뒤 구간(; && || | & ( ))별로 basename 이 sed/perl 인 단어를
#       어느 위치에서든 찾고(xargs·find -exec·env 뒤 포함), bash/sh/dash -c 문자열은 깊이 3까지 재귀한다. ssh 인자 문자열은 재귀하지 않는다.
# 잔존 한계: 변수 간접화(c=sed; $c -i)·eval 문자열·python 의 파일 쓰기는 대상 아님. 파싱 실패·python3 부재는 통과(fail-open) —
#       도구 안내용 안전망이며 보호 파일 쓰기는 gp_gate·F-WG-SELF·F-AC 가 따로 막는다. echo sed -i 처럼 인자로 sed 단어가 홀로 놓인 꼴은 오탐될 수 있다.
if [[ "$TOOL_NAME" == "mcp__oio__bash_exec" ]]; then
  _wg_pre _SEDI_CMD "$_WG_CMD_OC" '.tool_input.command // .tool_input.cmd // empty'   # c205 D-9
  if [[ "$_SEDI_CMD" == *sed* || "$_SEDI_CMD" == *perl* ]]; then
    _SEDI_HIT=$(printf '%s' "$INPUT" | timeout 5 python3 -c '
import sys,json,re,shlex,os
try:
    ti=json.load(sys.stdin).get("tool_input") or {}
    cmd=ti.get("command") or ti.get("cmd") or ""
    if not isinstance(cmd,str): sys.exit(0)
except Exception:
    sys.exit(0)
def mask_hd(c):
    ls=c.replace("\\\n"," ").split("\n"); out=[]; i=0
    pat=re.compile(r"(?<!<)<<(?!<)(-?)\s*(?:\x27([^\x27]*)\x27|\"([^\"]*)\"|\\(\w+)|(\w+))")
    while i<len(ls):
        ln=ls[i]; out.append(ln); i+=1; pend=[]
        for m in pat.finditer(ln):
            q=m.group(2) if m.group(2) is not None else (m.group(3) if m.group(3) is not None else m.group(4))
            pend.append((q if q is not None else m.group(5), q is not None, m.group(1)=="-"))
        for term,quoted,dash in pend:
            while i<len(ls):
                l=ls[i]; i+=1
                if (l.lstrip("\t") if dash else l)==term: break
                if not quoted:
                    out.extend(re.findall(r"\$\(([^()]*)\)",l)); out.extend(re.findall(r"`([^`]*)`",l))
    return " ;\n".join(out)
CRX=re.compile(r"s/\\r\$?//g?")
def sed_bad(a):
    inpl=any(re.match(r"-[A-Za-z]*i",x) and not x.startswith("--") or x.startswith("--in-place") for x in a)
    if not inpl: return False
    ex=[]; k=0; has_e=False; opts_end=False
    while k<len(a):
        x=a[k]
        if x=="-e" and k+1<len(a): has_e=True; ex.append(a[k+1]); k+=2; continue
        if x.startswith("--expression="): has_e=True; ex.append(x.split("=",1)[1])
        k+=1
    if not has_e:
        if any(x=="-f" or x.startswith("--file") for x in a): return True
        na=[x for x in a if not x.startswith("-")]
        if na: ex=[na[0]]
    return not (ex and all(CRX.fullmatch(e) for e in ex))
def perl_bad(a):
    return any(re.match(r"-[aclnpsTtuUwWX0-9]*i",x) and not x.startswith("--") for x in a)
def check(c,depth):
    lx=shlex.shlex(mask_hd(c) if depth==0 else c,posix=True,punctuation_chars=True); lx.whitespace_split=True
    segs=[[]]
    for x in list(lx):
        if x in (";","&&","||","|","&","(",")",";;"): segs.append([])
        else: segs[-1].append(x)
    for sg in segs:
        for idx,w in enumerate(sg):
            b=os.path.basename(w); rest=sg[idx+1:]
            if "+" in rest: rest=rest[:rest.index("+")]
            if b=="sed" and sed_bad(rest): return "sed"
            if b=="perl" and perl_bad(rest): return "perl"
            if b in ("bash","sh","dash") and depth<3:
                for j,x in enumerate(rest[:-1]):
                    if re.fullmatch(r"-[A-Za-z]*c",x) and check(rest[j+1],depth+1): return "sh-c"
    return ""
try:
    r=check(cmd,0)
except Exception:
    r=""
if r: print(r)
' 2>/dev/null || true)
    if [[ -n "$_SEDI_HIT" ]]; then
      jq -cn '{decision:"block",reason:"🚨 [F-SEDI-1] bash_exec sed -i/perl -i 금지 → mcp__oio__file_edit 사용 (BOM/CRLF 보존·Intent Lock). CR 제거 sed -i s/\\r$// 파일 꼴만 허용. (L-1374)"}' 2>/dev/null \
        || echo '{"decision":"block","reason":"🚨 [F-SEDI-1] bash_exec sed -i/perl -i 금지 → mcp__oio__file_edit 사용"}'
      exit 2
    fi
  fi
fi

# --- F10-3: 사이클41 — 물리 좌표 클릭 직접 호출 차단 (safe_click.ps1 경유 강제) ---
# 배경: tmp_stepC.ps1 이 SetCursorPos(5600,100) 을 하드코딩했다. VirtualScreen 은
#       X=-2560 W=7040 (Right=4480) 이므로 5600 은 1120px 초과한 ★존재하지 않는 좌표★였다.
#       원인은 대상 창을 한 번도 조회하지 않고 좌표를 추정 기입한 것이다.
#       당시 스크립트에 WindowFromPoint 검사가 이미 있었으나 ★출력만 하고 중단하지 않아★
#       무용지물이었다 (L-791 동형 — "반응했다" 와 "결과가 달라졌다" 는 다르다).
# 조치: 물리 커서/클릭 API 직접 호출을 차단하고 .claude/scripts/safe_click.ps1 경유를 강제한다.
#       safe_click.ps1 은 좌표계·창소유권·DPI 3축을 검증하고 실패 시 throw 한다.
# 설계: ① safe_click.ps1 자신을 호출하는 명령은 반드시 통과시킨다(자기 차단 방지).
#       ② 정의(DllImport 선언)가 아니라 ★실제 호출★ 패턴만 잡는다.
#       ③ 판정 불가 시 fail-open — 무관한 명령을 막지 않는다.
if [[ "$TOOL_NAME" == "mcp__oio__bash_exec" ]] && [[ ! -f "${HARNESS_HOME:-$HOME/.harness}/current/hooks/DISABLE_SAFECLICK_GUARD" ]]; then
  _wg_pre _SC_CMD "$_WG_CMD_OC" '.tool_input.command // .tool_input.cmd // empty'   # c205 D-9
  # ① safe_click.ps1 경유는 허용 (이 가드가 강제하는 정본 경로다)
  if ! echo "$_SC_CMD" | grep -q 'safe_click\.ps1'; then
    # ② 실제 호출 패턴: [클래스]::SetCursorPos( / ::mouse_event( / ::SendInput(
    if echo "$_SC_CMD" | grep -qP '::\s*(SetCursorPos|mouse_event|SendInput)\s*\('; then
      echo '{"decision":"block","reason":"🚫 [사이클41/F10-3] 물리 좌표 클릭 직접 호출 금지 — SetCursorPos/mouse_event/SendInput 을 직접 부르지 마라. 좌표계·창소유권·DPI 3축을 검증하는 .claude/scripts/safe_click.ps1 을 경유하라 (실패 시 throw). 예: powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\\DATA\\Project\\Mars\\.claude\\scripts\\safe_click.ps1 -ImageX <x> -ImageY <y> -ExpectedProcessId <PID>  [검증만: -NoClick]. 원칙적으로 좌표 클릭 자체가 금지이며 UIAutomation(AutomationId/Name)이 정본이다 — otest_winforms SKILL.md 참조."}'
      exit 2
    fi
  fi
fi

# --- F-OTO-7B: 사이클39 — bash_exec 로 state=IDLE 직접 쓰기 시 ROOF 게이트 사멸 차단 ---
# 배경: PreToolUse_oto_completion_guard.sh 의 F-OTO-7 은 mcp__oio__session_state 매처 전용이다.
#       따라서 bash_exec 로 state 파일에 직접 IDLE 을 쓰면 그 검사를 통째로 우회한다(우회경로 #2).
#       기존 F1(:737)이 있으나 `if [[ "$TOOL_NAME" == "Bash" ]]` 블록 안에 있어
#       CLAUDE.md 가 강제하는 mcp__oio__bash_exec 에는 ★한 번도 발동하지 않는다★ (실측 확인).
# 조건: auto=ON AND status 에 ROOF(구 RALPH) 없음 AND oroof_active(구 oralph_active) 둘 다 부재 AND state 에 IDLE 쓰기 시도
# 설계: auto 미설정 세션 무영향(최우선). DISABLE_OTO_GUARD 비상 스위치 존중. 그 외 예외는 fail-open.
if [[ "$TOOL_NAME" == "mcp__oio__bash_exec" ]] && [[ ! -f "${HARNESS_HOME:-$HOME/.harness}/current/hooks/DISABLE_OTO_GUARD" ]]; then
  _wg_pre _O7_CMD "$_WG_CMD_OC" '.tool_input.command // .tool_input.cmd // empty'   # c205 D-9
  # state 파일 쓰기 + IDLE 토큰이 함께 있을 때만 검사 (조회/그 외 명령 무영향)
  if echo "$_O7_CMD" | grep -qP 'session-env/[^/]+/state\b' \
     && echo "$_O7_CMD" | grep -qP '\bIDLE\b' \
     && echo "$_O7_CMD" | grep -qP '(>\s*["'"'"']?[^|&<]*session-env/[^/]+/state|tee\s+.*session-env/[^/]+/state|sed\s+.*-i.*session-env/[^/]+/state|state_write|state_transition)'; then
    # 대상 UUID: 명령문에서 추출 (자기 세션 판정 — 세션 격리 §(a) 읽기 전용)
    _O7_UUID=$(echo "$_O7_CMD" | grep -oP 'session-env/\K[^/]+' | head -1)
    if [[ -n "$_O7_UUID" ]]; then
      _O7_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${_O7_UUID}"
      [[ ! -f "${_O7_DIR}/auto" && -f "$HOME/.claude/session-env/${_O7_UUID}/auto" ]] \
        && _O7_DIR="$HOME/.claude/session-env/${_O7_UUID}"
      if [[ -f "${_O7_DIR}/auto" ]] && [[ "$(tr -d '[:space:]' < "${_O7_DIR}/auto" 2>/dev/null)" == "ON" ]]; then
        _O7_ROOF=0
        # ROOF-COMPAT(deprecation window 1주기 — 구 RALPH/oralph_active 인식 제거 예정)
        [[ -f "${_O7_DIR}/status" ]] && grep -qE '(^|\|)(ROOF|RALPH)(\||$)' "${_O7_DIR}/status" 2>/dev/null && _O7_ROOF=1
        # ROOF-COMPAT(deprecation window 1주기 — 구 RALPH/oralph_active 인식 제거 예정)
        if [[ "$_O7_ROOF" -eq 0 && ! -f "${_O7_DIR}/oroof_active" && ! -f "${_O7_DIR}/oralph_active" ]]; then
          # ROOF-COMPAT(deprecation window 1주기 — 구 RALPH/oralph_active 인식 제거 예정)
          if [[ -f "${_O7_DIR}/oroof_active.json" || -f "${_O7_DIR}/oralph_active.json" ]]; then
            # (a) 파일명 어긋남 — 사이클38 실사고와 동일 형태
            echo '{"decision":"block","reason":"🚫 [F-OTO-7Ba] auto=ON 세션인데 ROOF 게이트가 발동하지 않는 상태로 state=IDLE 을 직접 쓰려 합니다. oroof_active.json(또는 구 oralph_active.json) 은 있으나 ofinish Step 8 은 확장자 없는 oroof_active 를 봅니다 — 폴백이 원리적으로 매칭되지 않아 검증 루프가 통째로 건너뛰어집니다(사이클38 실사고). → 파일명을 oroof_active 로 맞추고 status_add ROOF 를 수행하십시오. 비상 시 hooks/DISABLE_OTO_GUARD 로 우회 가능."}'
          else
            # (b) 둘 다 없음 — oto 1_5 세팅 누락
            echo '{"decision":"block","reason":"🚫 [F-OTO-7Bb] auto=ON 세션인데 ROOF 게이트가 죽은 채로 state=IDLE 을 직접 쓰려 합니다. status 에 ROOF(구 RALPH) 가 없고 oroof_active(구 oralph_active) 파일도 없어, ofinish Step 8 이 검증 루프를 통째로 건너뛴 상태입니다(사이클38 실사고 재현). → oroof_active 파일과 status_add ROOF 를 먼저 세팅하거나, 정당한 종료라면 mcp__oio__session_state 경유로 전환해 F-OTO-7 검사를 받으십시오. 비상 시 hooks/DISABLE_OTO_GUARD 로 우회 가능."}'
          fi
          exit 2
        fi
      fi
    fi
  fi
fi

# --- F-COMMIT-1: L-567 사이클14 파이프라인 이탈 재발방지 (state DEV/TEST 중 git commit 차단) ---
# 배경: 사이클14 실사고 — odone(state=DONE) 미경유 상태에서 git commit이 실행됨.
# CLAUDE.md에 "커밋은 odone_git/ofinish 전용" 규칙이 있었으나 문서만으로는 미준수(L-567).
# 정당 경로 4종은 state가 DONE(odone_git)/FINISH(ofinish Step7.5)/IDLE(/opush 단독·사용자 직접)이므로
# DEV/TEST에서만 커밋을 걸어도 전부 통과한다. PLAN은 이번 지시 범위 밖(oplan 판정)이라 조건에 넣지 않는다.
# state 판별은 기존 state_read(flock) 인프라를 그대로 재사용 — 새 방식을 만들지 않는다.
# [cgit 2026-10-27] git commit --dry-run 면제(사용자 요구 "git 명령을 가드에서 막지 않도록" — 보수안).
#   --dry-run 은 커밋을 만들지 않으므로 DEV/TEST 에서도 통과시킨다. 실제 커밋 차단·git config 전면 차단(F-5)·
#   alias 판정·차단 메시지는 무변경. 면제 조건 6개와 전체 재판정 규칙은 _commit_dryrun_exempt 위 주석 참조.
#   시험: tests/test_wg_c194.sh cgit 절(①원문 통과 ②실제 commit ③-m "--dry-run" ④--dry-run; git commit
#   ⑤| xargs git commit ⑥git config 조회 ⑧-c alias 차단, ⑦DONE 실제 commit 통과 + 보강 사례).
# [cgit2 2026-10-27 해제] 사용자 지시 원문(10:52) "위험한 git도 막지 말고 그대로 진행해라" → 리드 확정(10:53).
#   F-COMMIT-1 전체를 끈다 — DEV·TEST 실제 git commit 허용, F-5 git config 전면 차단 해제(조회·설정), git -c·--config-env·
#   alias 정의 판정 해제. 위 cgit 1차(--dry-run 면제)는 이 해제에 흡수된다(상위 호환).
#   유지되는 것: 메인 활성 상태 직접 수정 금지(W5 — git 이 아닌 수정. [unblock3 2026-10-27] git 구간·cd·읽기만으로 된 메인 명령은 분기 G 가 허용,
#   보호 파일을 git 으로 바꾸는 것은 gp_gate 쪽 unblock3 해제 대상), 배포 스크립트 실행 결합(alias·hooksPath 로 deploy.sh 실행 등)은 pdg 가 판정한다(write_guard 밖).
#   되살릴 때는 아래 _WG_FCOMMIT_ON 을 1 로 바꾼다(본문·시험 함수는 보존).
_WG_FCOMMIT_ON=0
if [[ "$_WG_FCOMMIT_ON" == 1 && "$TOOL_NAME" == "mcp__oio__bash_exec" ]]; then
  _wg_pre _COMMIT_CMD_EARLY "$_WG_CMD_OC" '.tool_input.command // .tool_input.cmd // empty'   # c205 D-9
  # F-4 설계전환 (2026-08-20, otest-1 역라우팅 3회차 — 신규 우회 6건):
  #   중첩 bash -c / env / eval / stdin파이프|bash / --git-dir=--work-tree= 결합 / 절대경로 git / xargs
  #   → 개별 우회 패턴을 정규식으로 하나씩 막는 방식(F-2/F-3)이 한계에 도달.
  # ★ 사용자 승인 설계 전환: "git·commit 토큰이 둘 다 있으면 넓게 차단 + 오탐은 whitelist로 예외"
  #   (1회차에 반려됐던 c안 — 신규 우회 6건 실증 후 3회차에 승인됨)
  # 판정 순서:
  #   1) git/commit 토큰이 둘 다 없으면 무해 (조기 통과)
  #   2) git alias.<name>에 commit이 담기는 정의는 서브커맨드 판정 전에 위험으로 확정(alias 간접우회 차단)
  #   3) git 뒤 옵션들을 건너뛴 첫 서브커맨드가 read-only whitelist(log/show/diff/status/rev-parse/
  #      rev-list/cherry/describe/blame/bisect/help/shortlog/reflog/ls-files/ls-tree/cat-file/grep/
  #      branch/tag/remote/whatchanged)면 통과
  #   4) 순수 echo(파이프 없음)/주석 라인은 텍스트 출력일 뿐 실행이 아니므로 통과
  #   전체 문자열 자체를 먼저 검사(파이프는 분리하지 않음 — 앞부분만 안전해도 뒤에서 실행될 수 있음),
  #   그 다음 ;/&&/||로만 분리한 각 세그먼트를 독립 검사(alias 정의→실행 체인 등 개별 판정 위함).
  # F-5 수정 (2026-08-20, otest-1 역라우팅 4회차 — alias 문자열 분할 우회):
  #   git config alias.cm '!bash -c "git add -A; git c""ommit -m test"' → 셸이 "c""ommit"을
  #   "commit"으로 결합한 뒤에야 실제 서브커맨드가 되므로, hook이 보는 실행 전 텍스트에는
  #   \bcommit\b 리터럴이 없어 _commit_is_alias_def를 통과했다(실제 커밋 54fd64e6 발생, otest-1 확인).
  #   ★ 사용자 결정: whitelist에서 config를 제거해 "git config ..." 전체를 state DEV/TEST에서
  #   원천 차단한다. alias 정의문 안의 "commit" 문자열을 정규식으로 잡으려는 시도는 문자열 결합/
  #   변수치환/base64 등으로 무한 우회 가능하므로, 텍스트 판정이 아니라 진입 자체를 막는다.
  #   트레이드오프(git config --get/--list 읽기도 함께 막힘)는 사용자가 인지하고 승인함
  #   ("실제 워크플로우에서 git config는 드물게 쓰임"). --get만 예외로 뚫는 시도는 절대 금지
  #   (--get 뒤에 무엇이 오는지 다시 텍스트로 판정해야 하며, 그게 이번에 실패한 접근과 동일하다).
  #   _commit_is_alias_def는 삭제하지 않음 — config가 차단되어 도달 빈도는 줄지만, 다른 경로로
  #   alias 정의가 유입될 가능성에 대비한 이중 방어로 유지.
  _COMMIT_READONLY_SUBCMDS_EARLY='log|show|diff|status|rev-parse|rev-list|cherry|describe|blame|bisect|help|shortlog|reflog|ls-files|ls-tree|cat-file|grep|branch|tag|remote|whatchanged'
  _commit_has_tokens() {
    echo "$1" | grep -qP '\bgit\b' || return 1
    echo "$1" | grep -qP '\bcommit\b' || return 1
    return 0
  }
  # F-5 추가 (2026-08-20): git config 서브커맨드 자체를 commit 토큰 유무와 무관하게 판별.
  # 이유: "git config alias.cm '!... git c""ommit ...'" 처럼 문자열이 셸에서만 결합되는 경우
  # hook이 보는 실행 전 텍스트에는 \bcommit\b 리터럴이 없어 _commit_has_tokens 단계에서부터
  # 조기 통과된다 — whitelist에서 config를 빼는 것만으로는 이 케이스에 도달조차 못 한다.
  # 따라서 git 뒤 첫 서브커맨드가 config이면 commit 토큰 유무와 무관하게 즉시 위험 확정한다.
  _commit_is_git_config_call() {
    local _sub
    _sub=$(echo "$1" | grep -oP '\bgit\b(\s+(-[cC]\s+\S+|--?\S+))*\s+\K[a-z-]+' | head -1)
    [[ "$_sub" == "config" ]]
  }
  _commit_is_alias_def() {
    echo "$1" | grep -qP '\bgit\s+config\s+(--\S+\s+)*alias\.\S+\s+.*\bcommit\b'
  }
  _commit_is_readonly() {
    local _sub
    _sub=$(echo "$1" | grep -oP '\bgit\b(\s+(-[cC]\s+\S+|--?\S+))*\s+\K[a-z-]+' | head -1)
    [[ -z "$_sub" ]] && return 1
    echo "$_sub" | grep -qP "^(${_COMMIT_READONLY_SUBCMDS_EARLY})$"
  }
  _commit_is_pure_echo_or_comment() {
    if echo "$1" | grep -qP '^\s*echo\b' && ! echo "$1" | grep -qP '\|'; then
      return 0
    fi
    echo "$1" | grep -qP '^\s*#'
  }
  # F-6 수정 (2026-08-20, otest-1-2 역라우팅 — F-5 결함A와 동형 재발):
  #   git con"fig" alias.x diff / git c'onf'ig --get alias.y / g"it" config --get alias.z 등
  #   따옴표로 리터럴 토큰(git/config/commit)을 쪼개면 _commit_is_git_config_call 등이 요구하는
  #   \bconfig\b, \bgit\b, \bcommit\b 리터럴이 판정 시점 텍스트에 존재하지 않아 전부 통과했다
  #   (실증: git con"fig" alias.probe "diff" 실행 시 .git/config에 실제 alias 등록됨).
  # ★ 사용자 결정: 판정 직전에 " / ' / \ 를 제거한 정규화 사본을 만들어 그 사본으로만 판정한다.
  #   con"fig" → config, c'onf'ig → config, g"it" → git, c""ommit → commit 으로 정규화되어 잡힌다.
  #   원본 문자열(_seg)은 차단 메시지/로그용으로 그대로 보존 — 판정 입력만 정규화본으로 교체하는
  #   최소 변경. 기존 판정 함수(_commit_has_tokens 등)는 손대지 않는다.
  #   한계(사용자 인지·승인됨): 변수치환(C=config; git $C)/base64/$'c'$'onfig' 등은 여전히 남는다.
  _commit_normalize() {
    echo "$1" | tr -d '"'"'"'\\'
  }
  # F-8 수정 (2026-08-20, otest-2 역라우팅 9회차 — 위치 앵커 화이트리스트가 13건 뚫림):
  #   F-7(8회차)의 "명령 위치 화이트리스트"(env/eval/xargs/bash -c/sh -c 등 열거)가
  #   sudo/nohup/time/nice/command/exec/서브셸()/그룹{}/명령치환$()·``/if/for/timeout/
  #   setsid/stdbuf/env -i 등 열거 안 된 래퍼 13건+에 전부 뚫렸다(otest-2 확인).
  #   이건 사이클 세 번째 동형 실패: 1~3회차(패턴 화이트리스트) → 6회차(config 리터럴 매칭)
  #   → 8회차(위치 앵커 화이트리스트) — 매번 "인정 목록 방식"이 미열거 변형에 뚫렸다.
  # ★ 사용자 결정: 열거(제외 아닌 인정) 방식을 폐기하고 "제외 방식"으로 전환한다.
  #   기본은 F-6(넓게: git·commit 토큰 있으면 위험)로 복귀하되, otest-2가 확정한 오탐 8건
  #   (전부 grep/rg/sed/awk/cat/python3처럼 git이 "따옴표 안"에 있거나 "하이픈결합 파일명"인
  #   경우)만 명시적으로 제외한다.
  # 판정 3단계 (전부 "위험 확정" 조건 — 하나라도 참이면 위험, 전부 거짓이면 무해):
  #   A) unquoted 뷰(따옴표 " '로 감싸진 구간을 공백치환)에서 git이 독립토큰(standalone)으로
  #      존재 — 세그먼트 시작/파이프뒤/서브셸(/명령치환$(/백틱`/절대경로(슬래시) 등 문자열 어디든
  #      "따옴표 밖"에서 실행 위치에 있으면 확정 위험. 하이픈결합(git-commit-guide.md)은
  #      standalone 판정 자체가 "git 뒤가 공백/끝"을 요구해 자동 배제됨(실측 확인).
  #   B) normalize 뷰(따옴표 완전제거)에서 git이 "세그먼트 시작 위치"에 있으면 위험
  #      (g"it" config 처럼 따옴표가 명령 토큰 자체를 쪼개는 경우 — 6회차 alias 사고와 동형).
  #      "시작"만 보므로 grep -r git commit . 처럼 git이 3번째 단어인 경우는 안 걸림 → 오탐 재발 없음.
  #   C) 인용부호 안 내용이 "셸/원격셸/지연실행으로 그대로 넘겨지는 것으로 알려진" 소수 명령
  #      (bash -c/sh -c/eval/파이프투셸/ssh/trap) 뒤에 오는 경우만 normalize 뷰 전체에서
  #      standalone git 재확인(중첩 bash -c 등 세그먼트 시작이 아닌 내부 위치 커버).
  #      ⚠ C를 무조건 실행하면 grep -r "git commit" . 오탐이 재발함을 실측 확인
  #      (normalize하면 git이 공백 사이에 놓여 A/B 없이도 standalone으로 오판정) — 그래서
  #      "셸에 그대로 넘어가는 것으로 알려진 극소수 사례"에만 한정한다. 이건 8회차의 "명령
  #      위치를 인정하는 화이트리스트"와는 성격이 다르다 — 기본 판정(A/B)은 이미 넓게
  #      걸려 있고, C는 "인용부호 안으로 숨은 git을 되살릴지"만 판단하는 좁은 보조 로직이다.
  _commit_strip_quoted() {
    echo "$1" | sed -E 's/"[^"]*"/ /g; s/'"'"'[^'"'"']*'"'"'/ /g'
  }
  _commit_has_standalone_git() {
    echo "$1" | grep -qP '(^|[[:space:]/(`]|\$\()git([[:space:]]|$|\))'
  }
  _commit_has_git_at_segment_start() {
    echo "$1" | grep -qP '^\s*(\S*/)?git(\s|$)'
  }
  _commit_has_shell_handoff_context() {
    echo "$1" | grep -qP '\b(bash|sh)\s+(-c|--command)\b|\beval\b|\|\s*(\S*/)?\b(bash|sh)\b\s*$|\bssh\b|\btrap\b'
  }
  _commit_git_in_dangerous_position() {
    local _seg="$1" _unq _norm
    _unq=$(_commit_strip_quoted "$_seg")
    _commit_has_standalone_git "$_unq" && return 0
    _norm=$(_commit_normalize "$_seg")
    _commit_has_git_at_segment_start "$_norm" && return 0
    if _commit_has_shell_handoff_context "$_seg"; then
      _commit_has_standalone_git "$_norm" && return 0
    fi
    return 1
  }
  # [cgit 2026-10-27] git commit --dry-run 면제 (사용자 요구 "git 명령을 가드에서 막지 않도록" — 보수안).
  #   배경: 10-26 14:59(세션 f6f8d75b, DEV) `git commit --dry-run -q -m … 2>&1 | tail -2; git log …` 가
  #         git·commit 토큰만으로 커밋 판정돼 차단됐다. --dry-run 은 커밋을 만들지 않는다(인덱스·HEAD 불변).
  #   범위: --dry-run 만 연다. DEV/TEST 실제 커밋 차단·git config 전면 차단(F-5)·alias 판정은 그대로다.
  #   면제 조건(전부 참일 때만 — 하나라도 어긋나면 종전 판정):
  #     ① 구간이 원자적: 따옴표 밖에 ;·&&·||·개행·단독 & 없음(2>&1 같은 리다이렉트 &는 허용)
  #     ② $( · 백틱 · <( · >( 없음(따옴표 안 포함 — 큰따옴표 안 명령치환도 실행되므로)
  #     ③ 정규화 뷰(따옴표 제거)에서 독립 git 정확히 1회(-m "…$(git commit)…"·| xargs git commit 배제)
  #     ④ 첫 파이프 단계가 정확히 `[경로/]git [-C 경로]* commit --dry-run …` — --dry-run 이 commit 바로 뒤
  #        (-m --dry-run · -m "--dry-run" · -- --dry-run(경로 인자)처럼 값으로 먹히는 꼴 배제, -c·--config-env·alias 배제)
  #     ⑤ 정규화 뷰 어디에도 --no-d…(--no-dry-run 및 약어 — 뒤에서 dry-run 을 끄는 꼴) 없음
  #     ⑥ 파이프 뒤 단계의 첫 낱말이 tail|head|grep|egrep|fgrep|wc|cat|sort|uniq|cut|tr 중 하나(xargs·셸·eval 배제)
  #   전체 문자열 판정은 여러 구간을 담으므로 ①·③에서 면제되지 않는다 — 그 경우 아래 본문에서 구간별로 다시 보고,
  #   어느 구간도 1 이 아니고 dry-run 면제 구간(D)이 있으면, D 구간 원문을 `true` 로 바꾼 나머지 전체를 종전 판정으로
  #   다시 본다(1 이면 차단). 실제 commit 구간이 하나라도 있으면 차단.
  _commit_dryrun_exempt() {
    local _seg="$1" _norm _unq _head _st _w _ng _i
    local -a _parts
    case "$_seg" in *'$('*|*'`'*|*'<('*|*'>('*) return 1 ;; esac
    _unq=$(_commit_strip_quoted "$_seg")
    # ① 원자성 — 리다이렉트용 & (2>&1, >&2, &>) 를 먼저 지운 뒤 남은 & ; 개행을 본다
    _w=$(printf '%s' "$_unq" | sed -E 's/[0-9]*>&[0-9-]*//g; s/&>//g')
    case "$_w" in *';'*|*'&'*) return 1 ;; esac
    [[ "$_unq" == *$'\n'* ]] && return 1
    _norm=$(_commit_normalize "$_seg")
    # ③ 독립 git 1회
    _ng=$(printf '%s\n' "$_norm" | grep -oP '(^|[[:space:]/(`;|&])git(?=[[:space:]]|$|\))' | wc -l)
    [[ "$_ng" -eq 1 ]] || return 1
    # ⑤ --no-d… 금지
    printf '%s' "$_norm" | grep -qP '(^|\s)--no-d' && return 1
    # ④ 첫 파이프 단계 모양(따옴표 밖 뷰 기준 — 인용 메시지 안 | 는 파이프가 아니다)
    _head="${_unq%%|*}"
    printf '%s' "$_head" | grep -qP '^\s*(\S*/)?git(\s+-C\s+\S+)*\s+commit\s+--dry-run(\s|$)' || return 1
    # ⑥ 파이프 뒤 단계
    if [[ "$_unq" == *'|'* ]]; then
      _st="${_unq#*|}"
      IFS='|' read -r -a _parts <<< "$_st"
      for _i in "${_parts[@]}"; do
        _w=$(printf '%s' "$_i" | awk '{print $1}')
        [[ "$_w" =~ ^(tail|head|grep|egrep|fgrep|wc|cat|sort|uniq|cut|tr)$ ]] || return 1
      done
    fi
    return 0
  }
  _commit_check_segment() {
    local _seg="$1"
    local _norm
    _norm=$(_commit_normalize "$_seg")
    # git이 실행 위치(따옴표 밖 standalone / 정규화 후 세그먼트 시작 / 셸핸드오프 내부)에
    # 없으면 무해 확정 (grep -r "git commit" . 처럼 인자·파일명·문자열 안은 여기서 배제)
    _commit_git_in_dangerous_position "$_seg" || { echo 0; return; }
    # git config는 commit 토큰 유무와 무관하게 먼저 판별 (문자열분할 우회 원천 차단)
    echo "$_norm" | grep -qP '\bgit\b' && _commit_is_git_config_call "$_norm" && { echo 1; return; }
    _commit_has_tokens "$_norm" || { echo 0; return; }
    _commit_is_alias_def "$_norm" && { echo 1; return; }
    # [cgit] --dry-run 면제 — config·alias 판정 뒤, 읽기 전용 판정 앞. D 는 "무해(면제)" 표시이며 1 이 아니므로 차단되지 않는다.
    _commit_dryrun_exempt "$_seg" && { echo D; return; }
    _commit_is_readonly "$_norm" && { echo 0; return; }
    _commit_is_pure_echo_or_comment "$_norm" && { echo 0; return; }
    echo 1
  }
  _COMMIT_MATCHED_EARLY=0
  _COMMIT_WHOLE_EARLY=$(_commit_check_segment "$_COMMIT_CMD_EARLY")
  # [cgit] 구간별 판정 — 종전과 같이 하나라도 1 이면 차단. 추가로 dry-run 면제 구간(D) 유무를 센다.
  _COMMIT_SEG_HIT_EARLY=0
  _COMMIT_DRY_SEGS_EARLY=()
  _COMMIT_NORMALIZED_EARLY=$(echo "$_COMMIT_CMD_EARLY" | sed -E 's/(&&|\|\||;)/\n/g')
  while IFS= read -r _commit_seg_early; do
    [[ -z "$_commit_seg_early" ]] && continue
    _commit_seg_v_early=$(_commit_check_segment "$_commit_seg_early")
    if [[ "$_commit_seg_v_early" == "1" ]]; then
      _COMMIT_SEG_HIT_EARLY=1
      break
    fi
    [[ "$_commit_seg_v_early" == "D" ]] && _COMMIT_DRY_SEGS_EARLY+=("$_commit_seg_early")
  done <<< "$_COMMIT_NORMALIZED_EARLY"
  if [[ "$_COMMIT_SEG_HIT_EARLY" == "1" ]]; then
    _COMMIT_MATCHED_EARLY=1
  elif [[ "$_COMMIT_WHOLE_EARLY" == "1" ]]; then
    _COMMIT_MATCHED_EARLY=1
    # 전체 판정 1 은 종전대로 차단. 단 dry-run 면제 구간(D)이 있으면(전체가 여러 구간이라 ①·③에서 면제 못 받은 경우)
    # 그 구간 원문을 `true` 로 바꾼 나머지 전체를 ★종전 전체 판정으로 다시★ 본다 — 1 이 아니면 통과(10-26 14:59 원문 꼴).
    # 구간 판정만 믿지 않는 이유: 구간 분할이 따옴표 짝을 바꿔 git 을 가릴 수 있다
    # (예: `env "X=a;b" git commit -m "y"` 는 구간으로는 0, 전체로는 1). 전체 재판정이 그 경로를 그대로 막는다.
    if [[ ${#_COMMIT_DRY_SEGS_EARLY[@]} -gt 0 ]]; then
      _COMMIT_REST_EARLY="$_COMMIT_CMD_EARLY"
      for _commit_dseg_early in "${_COMMIT_DRY_SEGS_EARLY[@]}"; do
        _COMMIT_REST_EARLY="${_COMMIT_REST_EARLY/"$_commit_dseg_early"/ true }"
      done
      [[ "$(_commit_check_segment "$_COMMIT_REST_EARLY")" != "1" ]] && _COMMIT_MATCHED_EARLY=0
    fi
  fi
  if [[ "$_COMMIT_MATCHED_EARLY" == "1" ]]; then
    # F-2 수정 (2026-08-19): PIPELINE_UUID 환경변수는 실측 결과 hook 자식 프로세스에 전달되지 않는다
    # (otest-1 실측 + 본 재검증 공통 확인 — env/printenv에 PIPELINE_UUID 자체가 없음).
    # .session_id만 쓰면 팀에이전트에서는 자기 개별 세션ID가 나와 state 경로가 항상 빈 곳을 가리켜
    # IDLE로 폴백 → 차단이 무력화된다(실측 재현됨).
    # 우선순위: ① PIPELINE_UUID 환경변수(주입되는 향후 버전 대비, 현재는 대개 unset)
    #           ② 프로세스 트리 조상에서 --parent-session-id 파싱(실측상 신뢰 가능한 유일한 경로)
    #           ③ .session_id(메인 전용 — 팀에이전트면 ②가 먼저 잡히므로 도달 안 함)
    _COMMIT_UUID_EARLY="${PIPELINE_UUID:-}"
    if [[ -z "$_COMMIT_UUID_EARLY" ]]; then
      _COMMIT_PID_WALK=$$
      _COMMIT_DEPTH_WALK=0
      while [[ $_COMMIT_DEPTH_WALK -lt 10 && -n "$_COMMIT_PID_WALK" && "$_COMMIT_PID_WALK" != "1" ]]; do
        _COMMIT_CMDLINE_WALK=$(tr '\0' ' ' 2>/dev/null < "/proc/${_COMMIT_PID_WALK}/cmdline")
        if [[ "$_COMMIT_CMDLINE_WALK" =~ --parent-session-id[[:space:]]+([0-9a-f-]{36}) ]]; then
          _COMMIT_UUID_EARLY="${BASH_REMATCH[1]}"
          break
        fi
        _COMMIT_PID_WALK=$(awk '/^PPid:/{print $2}' "/proc/${_COMMIT_PID_WALK}/status" 2>/dev/null)
        (( _COMMIT_DEPTH_WALK++ )) || true
      done
    fi
    [[ -z "$_COMMIT_UUID_EARLY" ]] && _COMMIT_UUID_EARLY=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null) || true
    if [[ -n "$_COMMIT_UUID_EARLY" ]]; then
      source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/session_id.sh" 2>/dev/null || true
      _COMMIT_STATE_EARLY=$(state_read "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${_COMMIT_UUID_EARLY}/state" 2>/dev/null | awk '{print $1}') || _COMMIT_STATE_EARLY=""
      if [[ "$_COMMIT_STATE_EARLY" == "DEV" || "$_COMMIT_STATE_EARLY" == "TEST" ]]; then
        echo "{\"decision\":\"block\",\"reason\":\"❌ [F-COMMIT-1] state=${_COMMIT_STATE_EARLY} 에서 git commit 금지. 커밋은 odone_git(state=DONE) 또는 ofinish Step7.5(state=FINISH) 전용입니다. → odone 을 먼저 호출하세요. (L-228 · 사이클14 파이프라인 이탈 재발방지)\"}"
        exit 2
      fi
    fi
  fi
fi
# --- F-COMMIT-1 끝 ---

# --- F-DESTROY-1: 사이클65 — cwd 의존 파괴 명령 차단 (상대경로 대상 금지) ---
# 배경: 사이클65 실사고 — Mars 작업트리 전체 + .git 이 소실됐다.
#       oio dir_delete 가 PATH_NOT_ALLOWED, `rm -rf` 가 COMMAND_BLOCKED 로 각각 막히자
#       에이전트가 ★기능적 등가물★ `find . -type f -delete` 를 찾아냈고,
#       cd 실패(대상 이미 소멸) + `2>/dev/null` 은폐 + oio bash_exec 의 cwd 유지 특성이 겹쳐
#       셸이 Mars 루트에 있는 채로 `.` 을 지웠다. `.git/objects` 0개 — 로컬 복구 불가.
#
# ★설계 원칙 — 열거하지 않는다★
#   `rm -rf` 를 막으면 `find -delete` 가 나오고, 그것도 막으면 `xargs rm` 이 나온다.
#   금지어 목록은 열거하지 않은 등가물에서 반드시 뚫린다(사고 당사자·조사자 공통 결론).
#   ⇒ 판정 축을 하나로 세운다: ★파괴 명령의 대상이 절대경로인가★
#     - 절대경로면 통과 — 무엇을 지우는지 명령문에 명시돼 있어 cwd 와 무관하다.
#     - 상대경로/`.`/누락이면 차단 — 대상이 cwd 에 따라 달라지는데,
#       oio bash_exec 는 호출 간 cwd 를 유지하므로 ★에이전트가 자기 cwd 를 모르는 것이 정상★이다.
#   이 축은 rm / find -delete / find -exec rm / xargs rm / 인터프리터 unlink 를 한 번에 덮는다.
#
# ★한계 (알고 있어야 한다 — 완전 차단이 아니다)★
#   ① 변수·치환 대상(`rm -rf "$DIR"`)은 정적 판정 불가 → fail-open 통과시킨다.
#   ② base64/eval 로 난독화한 명령은 텍스트 판정을 원리적으로 우회한다.
#   ③ 절대경로여도 그 경로 자체가 틀리면(`rm -rf /mnt/c/DATA/Project/Mars`) 막지 못한다.
#      이 축이 막는 것은 "의도하지 않은 대상"이지 "잘못 지정한 대상"이 아니다.
#   ④ `cd /abs && rm -rf ./x` 처럼 cd 가 성공하면 안전한 경우도 함께 막는다(과차단).
#      대안이 명확하므로(절대경로로 쓰면 됨) 이 과차단은 수용한다.
#   ⇒ ①~③ 의 잔여 위험은 이 hook 이 아니라 oio 서버측 ALLOWED_ROOTS 가 담당한다(이중 방어).
#
# 설계: ⓐ 이 hook 자신을 다루는 명령은 항상 통과(자기 차단 방지).
#       ⓑ 순수 echo/printf/주석은 텍스트 출력이므로 면제(F-COMMIT-1 동일 선례). 파이프 있으면 면제 안 함.
#       ⓒ find 의 ★읽기 용도★(-print/-exec grep/| head)는 절대 막지 않는다 — 탐색이 죽으면 안 된다.
#       ⓓ 판정 불가 시 fail-open.
# 비상 스위치: hooks/DISABLE_DESTROY_GUARD 생성 시 무력화 (기존 가드 관례 동일).
# [사이클216] 따옴표 한 쌍(" " 또는 ' ')으로 감싼 리터럴 절대경로는 따옴표 없는 같은 경로와 같은 판정을 받는다(cwd 무관).
#   종전에는 따옴표 문자 때문에 /* 에 걸리지 않아 상대경로로 오판했다(mars-9b 인계: rm -f "/mnt/c/Users/…/autologin.xml" 차단).
#   내용에 따옴표·$·`·\·*·? 가 있거나 / 와 . 만으로 된 경로("/" "//" "/." "/*")는 종전대로 판정한다.
#   한계: 따옴표 안에 공백이 있는 경로("/a b/x")는 단어 분리로 조각나 종전대로 차단된다(fail-closed).
_wg_ds_qabs() {  # $1=토큰 → 0 = 따옴표 한 쌍으로 감싼 리터럴 절대경로(내용은 _WG_DS_QA)
  local _t="$1" _q="${1:0:1}" _a
  _WG_DS_QA=""
  [[ "$_q" == '"' || "$_q" == "'" ]] || return 1
  (( ${#_t} >= 3 )) && [[ "${_t: -1}" == "$_q" ]] || return 1
  _a="${_t:1:${#_t}-2}"
  [[ "$_a" == /* ]] || return 1
  [[ "$_a" != *[\"\'\$\`\\\*\?]* ]] || return 1
  [[ -n "${_a//[\/.]/}" ]] || return 1
  _WG_DS_QA="$_a"
  return 0
}
# [overblock P2 2026-11-05] F-DESTROY-1 (D) 해석기 코드 출처 판정기 — 출력 CLEAN|HIT|OPAQUE. 작은따옴표 없는 python 본문이다.
_WG_DS_INTERP_PY='import re, sys
s = sys.stdin.read()
def out(v):
    sys.stdout.write(v)
    sys.exit(0)
INTERP = re.compile(r"(^|[^-A-Za-z0-9_./])(perl|python3?|ruby|node)\b")
DESTROY = re.compile(r"(unlink|os\.remove|os\.unlink|os\.rmdir|shutil\.rmtree|rmtree|fs\.unlinkSync|fs\.rmSync|fs\.unlink|File\.delete|FileUtils\.rm)")
RISKY = re.compile(r"(^|[^-A-Za-z0-9_.])(sh|bash|dash|zsh|ksh|fish|eval|exec|source|xargs|parallel|watch|ssh|su|sudo|doas|tmux|screen|script|compile|runpy|importlib|require|load|do|then|alias|trap)(?=\s|$|\(|;|\||&|\))|--split-string|-exec|(^|\s)\.\s")
if "`" in s or "$(" in s or "<(" in s or ">(" in s or RISKY.search(s):
    out("OPAQUE")
OPCH = ";&|()"
n = len(s)
def word_at(i):
    v = []
    lit = True
    q = False
    while i < n:
        c = s[i]
        if c in " \t\n" or c in OPCH or c in "<>":
            break
        if c == "\\":
            v.append(s[i + 1:i + 2])
            i += 2
            q = True
            continue
        if c == "\x27":
            j = s.find("\x27", i + 1)
            if j < 0:
                raise ValueError("quote")
            v.append(s[i + 1:j])
            i = j + 1
            q = True
            continue
        if c == "\x22":
            j = i + 1
            buf = []
            while j < n and s[j] != "\x22":
                if s[j] == "\\" and j + 1 < n:
                    buf.append(s[j + 1])
                    j += 2
                    continue
                if s[j] in "$`":
                    lit = False
                buf.append(s[j])
                j += 1
            if j >= n:
                raise ValueError("quote")
            v.append("".join(buf))
            i = j + 1
            q = True
            continue
        if c in "$`":
            lit = False
        v.append(c)
        i += 1
    return "".join(v), lit, q, i
def new_cmd(pin):
    return dict(w=[], r=[], hd=[], pin=pin)
cmds = [new_cmd(False)]
pend = []
i = 0
try:
    while i < n:
        c = s[i]
        if c in " \t":
            i += 1
            continue
        if c == "#" and (i == 0 or s[i - 1] in " \t\n;&|("):
            j = s.find("\n", i)
            i = n if j < 0 else j
            continue
        if c == "\n":
            i += 1
            for d, quoted, strip, owner in pend:
                body = []
                done = False
                while i < n:
                    j = s.find("\n", i)
                    line = s[i:] if j < 0 else s[i:j]
                    i = n if j < 0 else j + 1
                    if (line.lstrip("\t") if strip else line) == d:
                        done = True
                        break
                    body.append(line)
                if not done:
                    raise ValueError("heredoc")
                owner["hd"].append(("\n".join(body), quoted))
            pend = []
            cmds.append(new_cmd(False))
            continue
        m = re.match(r"\d*(<<<|<<-|<<|&>>|&>|>>|>&|<&|<>|>\||>|<)", s[i:])
        if m:
            op = m.group(1)
            i += m.end()
            if op in ("<<", "<<-"):
                while i < n and s[i] in " \t":
                    i += 1
                d, lit, quoted, i = word_at(i)
                if not d:
                    raise ValueError("heredoc")
                pend.append((d, quoted, op == "<<-", cmds[-1]))
                cmds[-1]["r"].append([op, [d, True], quoted])
            else:
                cmds[-1]["r"].append([op, None, False])
            continue
        if c in OPCH:
            op = s[i:i + 2] if s[i:i + 2] in ("&&", "||", ";;", "|&") else c
            i += len(op)
            cmds.append(new_cmd(op in ("|", "|&")))
            continue
        v, lit, q, i = word_at(i)
        cm = cmds[-1]
        if cm["r"] and cm["r"][-1][1] is None:
            cm["r"][-1][1] = [v, lit]
        else:
            cm["w"].append([v, lit])
except Exception:
    out("OPAQUE")
if pend:
    out("OPAQUE")
IN = re.compile(r"^(perl|python3?(\.[0-9]+)*|ruby|node)$")
PRE = ("env", "nice", "nohup", "command", "time", "setsid", "timeout", "stdbuf", "ionice")
SAFE_READ = ("grep", "egrep", "fgrep", "rg")
WRITERS = ("tee", "cp", "mv", "install", "dd", "ln", "rsync", "sed", "touch", "truncate", "patch", "tar", "unzip", "git", "curl", "wget")
FLAG = dict(python=re.compile(r"^-[bBdEhiIOqsSuvx]*c"), perl=re.compile(r"^-[lnpaswWTtcU0-9]*[eE]$"), ruby=re.compile(r"^-[lnpaswWdv]*e$"), node=re.compile(r"^(-e|-p|-pe|--eval|--print)(=|$)"))
NULLS = ("/dev/null", "1", "2")
def mi(t):
    return bool(INTERP.search(t))
def safe_redirs(cm):
    for r in cm["r"]:
        if ">" in r[0] and (r[1] is None or r[1][0] not in NULLS):
            return False
    return True
mentions = 0
bad = False
hit = False
writes = False
outside = False
for cm in cmds:
    ws = cm["w"]
    texts = [w[0] for w in ws] + [r[1][0] for r in cm["r"] if r[1]] + [h[0] for h in cm["hd"]]
    nm = sum(1 for t in texts if mi(t))
    mentions += nm
    if not safe_redirs(cm):
        writes = True
    k = 0
    seen = False
    while k < len(ws):
        v = ws[k][0]
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", v):
            if re.match(r"^(PYTHON|PERL|RUBY|NODE)", v) or mi(v) or not ws[k][1]:
                bad = True
            k += 1
            continue
        if v.rsplit("/", 1)[-1] in PRE:
            seen = True
            k += 1
            continue
        if seen and (v.startswith("-") or re.match(r"^[0-9.]+[smhd]?$", v)):
            k += 1
            continue
        break
    if k >= len(ws):
        if nm or any(DESTROY.search(t) for t in texts):
            if nm:
                bad = True
            else:
                outside = True
        continue
    base = ws[k][0].rsplit("/", 1)[-1]
    if base in WRITERS:
        writes = True
    im = IN.match(base)
    if not im:
        if any(DESTROY.search(t) for t in texts):
            outside = True
        if nm == 0:
            continue
        if base in SAFE_READ and safe_redirs(cm) and not any(mi(w[0]) for w in ws[:k]):
            continue
        bad = True
        continue
    kind = im.group(1)
    if kind.startswith("python"):
        kind = "python"
    args = ws[k + 1:]
    if any(not lit for v, lit in args) or any(r[1] is not None and not r[1][1] for r in cm["r"]):
        bad = True
        continue
    if any(mi(w[0]) for w in ws[:k]):
        bad = True
        continue
    has_flag = any(FLAG[kind].match(v) for v, lit in args)
    stdin_lit = False
    stdin_opaque = cm["pin"]
    for r in cm["r"]:
        op = r[0]
        if op in ("<<", "<<-"):
            if r[2]:
                stdin_lit = True
            else:
                stdin_opaque = True
        elif op == "<<<":
            stdin_lit = True
        elif op in ("<", "<&", "<>"):
            stdin_opaque = True
    if stdin_opaque:
        bad = True
        continue
    positional = [v for v, lit in args if not v.startswith("-")]
    if not has_flag and not (stdin_lit and not positional):
        bad = True
        continue
    if any(DESTROY.search(t) for t in texts):
        hit = True
if mentions == 0 or bad or (writes and outside):
    out("OPAQUE")
out("HIT" if hit else "CLEAN")
'
if [[ "$TOOL_NAME" == "mcp__oio__bash_exec" ]] && [[ ! -f "${HARNESS_HOME:-$HOME/.harness}/current/hooks/DISABLE_DESTROY_GUARD" ]]; then
  _wg_pre _DS_CMD "$_WG_CMD_OC" '.tool_input.command // .tool_input.cmd // empty'   # c205 D-9

  # ⓐ 이 hook 자신을 읽고/고치는 명령은 무조건 통과 (자기 차단 금지)
  if [[ -n "$_DS_CMD" ]] && ! echo "$_DS_CMD" | grep -q 'write_guard\.sh'; then
    _DS_REASON=""

    # (D) 인터프리터 원라이너 파괴 — ★분리 전 전체 명령 대상★
    #   `python3 -c "import shutil; shutil.rmtree('.')"` 는 ; 로 쪼개면 -c 와 rmtree 가
    #   서로 다른 조각으로 찢어져 판정이 무력화된다. 그래서 분리보다 먼저 본다.
    if echo "$_DS_CMD" | grep -qP '(^|[^-[:alnum:]_./])(perl|python3?|ruby|node)\b' \
       && echo "$_DS_CMD" | grep -qP '(unlink|os\.remove|os\.unlink|os\.rmdir|shutil\.rmtree|rmtree|fs\.unlinkSync|fs\.rmSync|fs\.unlink|File\.delete|FileUtils\.rm)'; then
      # [overblock P2 2026-11-05] 해석기 단어와 파괴 단어가 둘 다 있어도, 파괴 단어가 해석기 명령 밖(예: grep 패턴)에만 있으면 막지 않는다.
      #   _WG_DS_INTERP_PY 가 해석기 명령마다 코드 출처를 본다. 리터럴 인용 -c/-e 인자·인용 heredoc(<<'EOF') 본문·리터럴 here-string 만
      #   볼 수 있는 코드로 인정하고, 그 해석기 명령의 인자·본문 전체에서 파괴 단어를 찾는다(HIT = 차단).
      #   비리터럴 인자("$X")·표준입력 코드(| python3, python3 -, 인용 없는 heredoc, < 파일)·스크립트 파일 실행·$( )·백틱·
      #   sh/eval/exec/xargs 류·같은 명령 안 파일 쓰기와 해석기 밖 파괴 단어의 결합이 하나라도 있으면 OPAQUE = 종전 전체 판정(차단).
      #   판정기 오류·시간 초과도 차단(fail-closed). CLEAN 일 때만 (D) 를 통과시키고 아래 (A)~(C) 구간 판정은 그대로 이어진다.
      _ds_iv=$(printf '%s' "$_DS_CMD" | timeout 3 python3 -I -B -c "$_WG_DS_INTERP_PY" 2>/dev/null) || _ds_iv=""
      if [[ "$_ds_iv" == "HIT" ]]; then
        _DS_REASON="인터프리터 원라이너 파괴 호출(unlink/rmtree 등) — 대상이 코드 문자열 안에 있어 정적 판정이 불가능합니다"
      elif [[ "$_ds_iv" != "CLEAN" ]]; then
        _DS_REASON="인터프리터 원라이너 파괴 호출(unlink/rmtree 등) — 코드 출처(비리터럴 인자·표준입력·스크립트 파일·명령 치환 등)를 정적으로 볼 수 없어 종전대로 판정합니다"
      fi
    fi

    if [[ -z "$_DS_REASON" ]]; then
      # ; && || | 개행 으로 분리해 각 절을 독립 판정
      while IFS= read -r _ds_seg; do
        [[ -n "$_ds_seg" ]] || continue

        # ⓑ 순수 echo/printf/주석 → 텍스트 출력일 뿐 실행이 아니다. 파이프 있으면 면제 안 함.
        if echo "$_ds_seg" | grep -qP '^\s*(#|echo\b|printf\b)' && ! echo "$_ds_seg" | grep -qP '\|'; then
          continue
        fi

        # (A) find + 파괴 액션 — 대상(첫 비옵션 인자)이 절대경로가 아니면 차단.
        #     ⓒ -print / -exec grep / | head 등 ★읽기 용도 find 는 여기 걸리지 않는다★.
        if echo "$_ds_seg" | grep -qP '(^|[^-[:alnum:]_./])find\b' \
           && echo "$_ds_seg" | grep -qP '(-delete\b|-exec\s+(rm|unlink|truncate|shred|mv)\b|-execdir\s+(rm|unlink|truncate|shred|mv)\b|-ok\s+rm\b)'; then
          _DS_TGT=$(echo "$_ds_seg" | sed -n 's/.*\bfind[[:space:]]\+//p' \
                    | awk '{for(i=1;i<=NF;i++){if($i=="-H"||$i=="-L"||$i=="-P"||$i=="-xdev"||$i=="-mount"){continue}; print $i; exit}}')
          _ds_ft="${_DS_TGT//[\"\']/}"; _ds_fr="${_ds_ft#\~}"; _ds_fr="${_ds_fr#"${_ds_fr%%[!/]*}"}"
          if [[ "$_ds_ft" == "~/"* && -n "$_ds_fr" && "$_ds_fr" != '*'* && "$_ds_fr" != '$'* ]] && ! [[ "$_ds_fr" =~ ^\.\.?(/|$) ]]; then
            _DS_TGT="/~${_ds_fr}"   # [사이클206] ~/<리터럴 하위경로> 는 HOME 기준 절대경로
          fi
          _wg_ds_qabs "$_DS_TGT" && _DS_TGT="$_WG_DS_QA"   # [사이클216] 따옴표 감싼 리터럴 절대경로
          case "$_DS_TGT" in
            /*) : ;;
            -*|"") _DS_REASON="find 의 탐색 대상 경로가 없습니다(=cwd 를 암묵 대상으로 삼음)"; break ;;
            *)     _DS_REASON="find 의 탐색 대상이 상대경로입니다: '${_DS_TGT}'"; break ;;
          esac
        fi

        # (B) xargs 로 파괴 — 대상이 표준입력이라 명령문만으로는 무엇을 지우는지 알 수 없다.
        if echo "$_ds_seg" | grep -qP '\bxargs\b(\s+-\S+(\s+\S+)?)*\s+(sudo\s+)?(rm|unlink|shred|truncate)\b'; then
          _DS_REASON="xargs 로 파괴 명령을 실행합니다 — 대상이 표준입력이라 정적 판정이 불가능합니다"
          break
        fi

        # (C) rm / unlink / shred 의 피연산자가 상대경로
        # 2026-09-06 정정: 세그먼트 "명령 위치"(선행 sudo 허용)일 때만 매칭하도록 앵커링.
        # 종전 정규식은 세그먼트 어디든(문자열/인자 안 포함) rm 토큰이 있으면 매칭돼
        # `git commit -m "...rm 패턴을..."`, `sed -i 's|...rm 패턴...|...'`,
        # `grep -qP 'rm\s+/'` 같은 rm 리터럴을 삭제 명령으로 오인 차단했다.
        if echo "$_ds_seg" | grep -qP '^\s*(?:sudo\s+)?(rm|unlink|shred)\b'; then
          _DS_OPS=$(echo "$_ds_seg" | grep -oP '^\s*(?:sudo\s+)?(?:rm|unlink|shred)\s+\K.*$')
          _DS_BAD=""
          # ★set -f 로 글로브 확장을 끈다★ — 끄지 않으면 `rm -rf *` 의 * 가
          #   hook 프로세스의 실제 cwd 파일명으로 확장돼 판정이 파일 유무에 좌우된다.
          set -f
          for _ds_o in $_DS_OPS; do
            # [사이클206] `~/<리터럴 하위경로>` 는 HOME 기준 절대경로다(cwd 무관) — `rm -rf ~/scratch/x` 과차단 해소.
            #   `~`·`~/`·`~/*`·`~/.`·`~/..`·`~user`·`~/$X` 는 종전대로 차단. ~/.claude 등 보호 디렉터리는 F-DESTROY-2 _d2_prot 이 본다.
            _ds_ot="${_ds_o//[\"\']/}"
            if [[ "$_ds_ot" == "~/"* ]]; then
              _ds_or="${_ds_ot#\~}"; _ds_or="${_ds_or#"${_ds_or%%[!/]*}"}"
              if [[ -n "$_ds_or" && "$_ds_or" != '*'* && "$_ds_or" != '$'* ]] && ! [[ "$_ds_or" =~ ^\.\.?(/|$) ]]; then continue; fi
            fi
            _wg_ds_qabs "$_ds_o" && continue   # [사이클216] 따옴표 감싼 리터럴 절대경로 → 안전(아래 /* 와 같다)
            case "$_ds_o" in
              -*) continue ;;
              /*) continue ;;                 # 절대경로 → 안전
              \$*|\"\$*|\'\$*) continue ;;    # 변수 — 정적 판정 불가, fail-open (한계 ①)
              '{}'|';'|'+') continue ;;       # find -exec 잔여 토큰
              [0-9]\>*|\>*|\>\>*|\<*|\&\>*) continue ;;   # 리다이렉션 토큰 — 삭제 대상 아님
              *) _DS_BAD="$_ds_o"; break ;;
            esac
          done
          set +f
          if [[ -n "$_DS_BAD" ]]; then
            _DS_REASON="rm/unlink/shred 의 삭제 대상이 상대경로입니다: '${_DS_BAD}'"
            break
          fi
        fi
      done <<< "$(echo "$_DS_CMD" | awk '{
        # quote-aware 마스킹: 따옴표(작/큰) 안의 ; | & 는 세그먼트 구분자가 아니다.
        # 예: sed -i "s|rm 패턴|x|" 의 | 는 sed 구분자이지 셸 파이프가 아님(2026-09-06).
        # 따옴표 밖의 ; | & 는 그대로 두어 실제 파이프/체인 분리를 보존한다(fail-open 방지).
        out=""; sq=0; dq=0
        for (i=1;i<=length($0);i++) { c=substr($0,i,1)
          if (c=="\x27" && dq==0) sq=!sq
          else if (c=="\"" && sq==0) dq=!dq
          if ((sq||dq) && (c==";"||c=="|"||c=="&")) c="\x01"
          out=out c
        }
        print out
      }' | tr ';|&\n' '\n\n\n\n')"
    fi

    if [[ -n "$_DS_REASON" ]]; then
      # [사이클216] 사유에 든 피연산자 원문(따옴표·역슬래시)을 JSON 문자열로 이스케이프 — 깨진 JSON 은 Claude Code 가 버려 사유가 화면에서 사라진다
      _DS_REASON="${_DS_REASON//\\/\\\\}"; _DS_REASON="${_DS_REASON//\"/\\\"}"
      echo "{\"decision\":\"block\",\"reason\":\"🚫 [사이클65/F-DESTROY-1] cwd 의존 파괴 명령 차단 — ${_DS_REASON}. oio bash_exec 는 호출 간 working directory 를 유지하므로 지금 셸이 어느 디렉토리에 있는지 확신할 수 없습니다. 사이클65 에서 정확히 이 형태(cd 실패 후 find . -type f -delete)로 Mars 작업트리와 .git 이 통째로 삭제됐습니다(로컬 복구 불가). → 삭제 대상을 ★절대경로★로 명시하십시오. 예: rm -rf /mnt/c/DATA/Project/Mars/tmp/x · find /mnt/c/DATA/Project/Xxx -name '*.tmp' -delete. 더 나은 경로는 mcp__oio__file_delete / dir_delete 입니다(ALLOWED_ROOTS 검증 포함). 임시 산출물은 처음부터 /mnt/c/DATA/Project/ 이하에 만드십시오. 비상 시 hooks/DISABLE_DESTROY_GUARD 로 우회 가능.\"}"
      exit 2
    fi
  fi
fi
# --- F-DESTROY-1 끝 ---

# --- F-DESTROY-2: 사이클167 C15 — 루트(/)·비어 있을 수 있는 변수를 피연산자로 쓰는 cp/rsync/rm/mv 차단 ---
# 배경: F-DESTROY-1 은 ★상대경로★ 대상만 막고 변수 대상은 fail-open(한계 ①)이다.
#       그런데 oio bash_exec 는 ★최상위 `&&`★(따옴표·괄호·중괄호 밖) 에서 명령을 별도 셸로 ★분할 실행★한다
#       (사이클182 재실측 — `A=1; echo $A` 는 한 셸, `A=1 && echo $A` 는 빈 값, for 루프 안의 && 도 분할된다).
#       `D=/x && cp -a $D/. /y` 를 보내면 cp 구간에서 D 가 ★빈 값★이 되어 `cp -a /. /y` = 루트 전체 복사가 된다.
#       같은 원리로 `rm -rf $D/*` 는 `rm -rf /*` 가 된다. (사이클167 서술 "; 로도 분할" 은 사이클182 X1 에서 정정했다.)
# 판정 축 (열거하지 않는다 — "피연산자가 무엇으로 전개되는지 명령문만으로 보장되는가"):
#   ⓐ 피연산자가 루트(`/` `/.` `/*` `//` 등)면 차단.
#   ⓑ 피연산자가 `$VAR…`·`${VAR}…` 로 시작하면 차단. 단 비어 있지 않음이 문법으로 보장되면 통과:
#      `${VAR:?…}`(빈 값이면 셸이 중단) · `${VAR:-기본값}`(기본값 비어 있지 않음) · `$HOME`/`${HOME}`.
#      ※ 같은 구간의 접두 대입(`D=/x cp $D/.`)은 전개 시점에 적용되지 않으므로(셸 규칙) 정의로 보지 않는다.
#      ※ `$(…)` 명령 치환은 정적 판정 불가 → fail-open(F-DESTROY-1 한계 ① 과 같은 취급).
#   ⓒ 명령 위치(선행 대입·sudo·do/then/else 허용)의 cp/rsync/rm/mv 만 본다 —
#   ⓓ [사이클172 확장] 서브셸·그룹 접두 `(`·`{` 뒤의 명령도 명령 위치로 본다 — `x | (cd $T && tar xf -)` 의 `(cd $T` 구간.
#      그리고 cd·pushd·ln·tar(-C/--directory 피연산자만)도 본다. 단 이 넷은 ★같은 명령 문자열 안에서 앞에 대입된 변수★
#      (`T=…`·`export T=…`)를 쓸 때만 차단한다 — 사고 형태(`T=/x; … (cd $T && tar xf -)` → T 빈 값 → cd 가 $HOME 으로 →
#      홈에 Mars 저장소가 풀림, 2026-10-08)만 정확히 잡고, 하네스가 넣는 환경변수(CLAUDE_CONFIG_DIR 등) cd 는 오차단하지 않는다.
#      `grep "cp -a /."`·`git commit -m "rm -rf /"`·`bash -c '…'`(따옴표 안 ; 는 구분자 아님) 는 통과.
#   ⓔ [사이클182 X1] 판정 단위를 oio 와 같은 ★실행 구간(최상위 && 사이)★으로 맞췄다. `$VAR` 피연산자는 같은 실행 구간 안,
#      사용 위치보다 앞, 같은(또는 바깥) 괄호 스코프에서 ⓐ 순수 대입 `VAR=<리터럴>`(export 등 허용, 값에 $·백틱·( 없음, 빈 값 아님,
#      앞뒤 구분자가 ; 개행 && 시작/끝 — 파이프·|| 뒤·접두 대입은 정의 아님) 또는 ⓑ `for VAR in <리터럴 단어들>`(글로브·$ 없음)이
#      있으면 통과하되 그 값으로 바꿔 루트 여부는 다시 본다(D=/; rm -rf $D 차단). 비리터럴 재대입·unset·read 는 정의를 지운다.
#      cd·pushd·ln·tar 는 위 정의가 없고 명령 문자열 어딘가에서 대입한 변수일 때만 차단(다른 && 구간·파이프·조건부 대입).
#      heredoc 본문 줄은 바깥과 무관한 독립 스코프로 본다(본문 안 정의만 인정).
#      [사이클206 FD2·NEW-c] 대입 구간은 따옴표 인식으로 단어를 나눈다(`S="/tmp/한글 공백.xlsx"` 를 정의로 인정 — 값은 공백 조각마다
#      루트 검사). 값 `${V:-<리터럴 또는 $HOME…>}` 도 비어 있지 않은 정의로 인정하고 기본값으로 루트를 본다(`${V:-}`·`${V:-$X}` 는 비정의).
#      잔존 한계: 함수 정의·eval·source 로 바뀌는 변수, 닫히지 않은 따옴표 대입(종전 분할 → 차단 쪽)은 정밀 판정하지 않는다.
# 분할은 자체 quote·괄호 인식 awk(oio _split_and_commands 규칙)를 쓴다. 비상 스위치는 F-DESTROY-1 과 공유(hooks/DISABLE_DESTROY_GUARD).
if [[ "$TOOL_NAME" == "mcp__oio__bash_exec" ]] && [[ ! -f "${HARNESS_HOME:-$HOME/.harness}/current/hooks/DISABLE_DESTROY_GUARD" ]]; then
  _wg_pre _D2_CMD "$_WG_CMD_OC" '.tool_input.command // .tool_input.cmd // empty'   # c205 D-9
  if [[ -n "$_D2_CMD" ]] && ! echo "$_D2_CMD" | grep -q 'write_guard\.sh'; then
    _D2_REASON=""
    _D2_RE_ROOT='^/+(\.|\*)?/*$'
    _D2_RE_REQ='^\$\{[A-Za-z_][A-Za-z0-9_]*:\?'
    _D2_RE_DEF='^\$\{[A-Za-z_][A-Za-z0-9_]*:-[^}]'
    _D2_RE_HOME='^\$(HOME|\{HOME\})(/|$)'
    _D2_RE_NAME='^[A-Za-z_][A-Za-z0-9_]*$'
    # [사이클206 교차검토 2차] 셸·로그인이 늘 설정하는 변수 — `${이름:-기본}` 은 실제로 이 변수 값이므로 기본값 근거를 쓰지 않는다
    _D2_RE_ALWAYS='^(HOME|PWD|OLDPWD|USER|LOGNAME|SHELL|PATH|TMPDIR|HOSTNAME|HOSTTYPE|OSTYPE|MACHTYPE|UID|EUID|PPID|BASH|BASH_VERSION|IFS|LANG|TERM|MAIL)$'
    declare -A _d2_dun=() _d2_dsrc=()
    _D2_PROT=""
    _d2_subok() {  # $1=변수 뒤 나머지 → `/<리터럴 하위경로>` 이면 0(`/`·`/.`·`/..`·`/*`·`/$X`·빈 값은 1)
      local _r="$1"
      [[ "$_r" == /* ]] || return 1
      _r="${_r#"${_r%%[!/]*}"}"
      [[ -n "$_r" && "$_r" != '*'* && "$_r" != '$'* ]] || return 1
      [[ "$_r" =~ ^\.\.?(/|$) ]] && return 1
      return 0
    }
    _d2_prot() {  # $1=경로 → 보호 디렉터리(설정 루트·hooks·skills·session-env·projects·HOME) 자체 또는 그 전체 내용이면 0
      local _p="$1" _b _e _rp
      if [[ -z "$_D2_PROT" ]]; then
        for _b in "$HOME/.claude" "${CLAUDE_CONFIG_DIR:-}"; do
          [[ -n "$_b" ]] || continue
          for _e in "" /hooks /hooks/lib /skills /session-env /projects; do
            _D2_PROT+="${_b}${_e}"$'\n'
            _rp=$(realpath -m -- "${_b}${_e}" 2>/dev/null) && _D2_PROT+="${_rp}"$'\n'
          done
        done
        [[ -n "$HOME" ]] && _D2_PROT+="$HOME"$'\n'"$(realpath -m -- "$HOME" 2>/dev/null)"$'\n'
      fi
      while [[ "$_p" == */ || "$_p" == */. || "$_p" == */\* ]]; do _p="${_p%/}"; _p="${_p%/.}"; _p="${_p%/\*}"; done
      [[ -n "$_p" ]] || return 1
      _rp=$(realpath -m -- "$_p" 2>/dev/null) || _rp="$_p"
      [[ $'\n'"$_D2_PROT" == *$'\n'"$_p"$'\n'* || $'\n'"$_D2_PROT" == *$'\n'"$_rp"$'\n'* ]]
    }
    # [사이클182 X1] 리터럴 정의 표 — 이름 → 실행 구간(chunk)·스코프 경로·값(공백 구분). 최신 정의 1개만 둔다.
    declare -A _d2_dch=() _d2_dsc=() _d2_dvl=()
    _d2_has() {  # $1=이름 $2=chunk $3=스코프 → 같은 && 구간 + 같은/조상 스코프의 리터럴 정의가 있으면 0
      [[ -n "${_d2_dch[$1]+x}" && "${_d2_dch[$1]}" == "$2" ]] || return 1
      [[ "$3" == "${_d2_dsc[$1]}" || "$3" == "${_d2_dsc[$1]}"/* ]]
    }
    _d2_lit() {  # $1=값(따옴표 제거 전) → 비어 있지 않은 리터럴이면 0
      local _v="${1//[\"\']/}"
      [[ -n "$_v" && "$_v" != *'$'* && "$_v" != *'`'* && "$_v" != *'('* && "$_v" != *'\'* ]]
    }
    # [사이클206 NEW-c] 대입 값 판정 — 리터럴이거나 `${NAME:-<기본값>}`(기본값이 리터럴 또는 $HOME/${HOME}+리터럴)이면 0.
    #   루트 검사용 값을 _d2_vv 에 남긴다(기본값 — HOME 은 실제 값으로 치환). `${V:-}`·`${V}`·`$V`·`${V:-$X}`·`${V:=…}` 는 1(종전대로 비정의).
    #   피연산자 자리의 _D2_RE_DEF(비어 있지 않음 보장) 인정과 같은 근거를 대입 값 자리에도 적용한다(비대칭 해소).
    #   [사이클206 교차검토 2차] `${NAME:-기본}` 의 실제 값은 NAME 이 설정돼 있으면 NAME 의 값이다 — 기본값으로는 "비어 있지 않음"만 보장되고
    #   "루트가 아님"은 증명되지 않는다. 그래서 ① 늘 설정되는 변수(HOME·PWD·USER·SHELL·TMPDIR 등)는 정의로 인정하지 않고
    #   ② 그 밖은 "값 모름" 정의(_d2_vunk=1, 근원 변수 _d2_vsrc)로 두어 사용처에서 `$D/<리터럴 하위경로>` 일 때만 통과시킨다.
    _d2_val() {
      local _v="${1//[\"\']/}" _dv _r
      _d2_vv=""; _d2_vunk=0; _d2_vsrc=""
      if [[ "$_v" =~ ^\$\{([A-Za-z_][A-Za-z0-9_]*):-(.+)\}$ ]]; then
        _d2_vsrc="${BASH_REMATCH[1]}"; _dv="${BASH_REMATCH[2]}"; _d2_vunk=1
        [[ "$_d2_vsrc" =~ $_D2_RE_ALWAYS ]] && return 1
        if [[ "$_dv" =~ ^\$(HOME|\{HOME\})(.*)$ ]]; then
          _r="${BASH_REMATCH[2]}"
          [[ -n "$HOME" ]] || return 1
          [[ -z "$_r" ]] || _d2_lit "$_r" || return 1
          [[ "$_r" != *'}'* && "$_r" != *'{'* ]] || return 1
          _d2_vv="${HOME}${_r}"; return 0
        fi
        _d2_lit "$_dv" || return 1
        [[ "$_dv" != *'}'* && "$_dv" != *'{'* ]] || return 1
        _d2_vv="$_dv"; return 0
      fi
      _d2_lit "$1" || return 1
      _d2_vv="$_v"; return 0
    }
    # [사이클206 FD2] 따옴표 인식 단어 분할 — 작은·큰따옴표 짝 안의 공백은 단어 안(따옴표 글자는 남긴다), 역슬래시 다음 글자는 글자.
    #   결과는 _d2_w 배열. 따옴표가 닫히지 않으면 1(호출자가 종전 read -a 분할 = 차단 쪽을 쓴다).
    _d2_words() {
      local _s="$1" _i _n=${#1} _ch _q="" _cur="" _has=0
      _d2_w=()
      for ((_i = 0; _i < _n; _i++)); do
        _ch="${_s:_i:1}"
        if [[ -n "$_q" ]]; then
          _cur+="$_ch"
          if [[ "$_q" == '"' && "$_ch" == '\' && $((_i + 1)) -lt $_n ]]; then _i=$((_i + 1)); _cur+="${_s:_i:1}"; continue; fi
          [[ "$_ch" == "$_q" ]] && _q=""
          continue
        fi
        case "$_ch" in
          "'"|'"') _q="$_ch"; _cur+="$_ch"; _has=1 ;;
          '\') _cur+="$_ch"; _has=1; if [[ $((_i + 1)) -lt $_n ]]; then _i=$((_i + 1)); _cur+="${_s:_i:1}"; fi ;;
          ' '|$'\t'|$'\n') if [[ $_has -eq 1 ]]; then _d2_w+=("$_cur"); _cur=""; _has=0; fi ;;
          *) _cur+="$_ch"; _has=1 ;;
        esac
      done
      [[ -z "$_q" ]] || return 1
      [[ $_has -eq 1 ]] && _d2_w+=("$_cur")
      return 0
    }
    # 실행 구간 분할기 — oio bash_exec._split_and_commands 와 같은 규칙으로 최상위 && 에서 chunk 를 올린다
    #   (따옴표·괄호·중괄호 밖. `<<` 가 있으면 줄마다 상태를 초기화하고 heredoc 본문은 분할하지 않는다).
    #   구간(; | & || && 개행)마다 "chunk \t 스코프 \t 앞구분자 \t 뒤구분자 \t 본문" 1줄. 스코프는 ( 마다 새 하위 경로,
    #   heredoc 본문 줄은 바깥과 무관한 독립 스코프(H<n>)다. 구분자: START S(; 개행) A(&&) O(||) P(|) B(&) END.
    _D2_RECS=$(printf '%s\n' "$_D2_CMD" | awk '
      function cur() { return sp_path[sp] }
      function flush(sa) {
        if (buf ~ /[^ \t]/) printf "%d\t%s\t%s\t%s\t%s\n", chunk, (segscope != "" ? segscope : cur()), sepb, sa, buf
        buf = ""; segscope = ""; sepb = sa
      }
      function addc(c) {
        if (segscope == "" && c !~ /[ \t({]/) segscope = cur()
        buf = buf c
      }
      { L[NR] = $0 }
      END {
        sp = 0; sp_path[0] = "0"; nid = 0; chunk = 0; sepb = "START"; buf = ""; segscope = ""
        hdmode = 0
        for (k = 1; k <= NR; k++) if (index(L[k], "<<")) { hdmode = 1; break }
        sq = 0; dq = 0; pd = 0; bd = 0; inbody = 0; marker = ""
        for (k = 1; k <= NR; k++) {
          line = L[k]
          if (inbody) {
            t = line; gsub(/^[ \t]+|[ \t]+$/, "", t)
            if (t == marker) { inbody = 0; continue }
            if (line ~ /[^ \t]/) printf "%d\t%s\t%s\t%s\t%s\n", chunk, bodyscope, "S", "S", line
            continue
          }
          if (hdmode) { sq = 0; dq = 0; pd = 0; bd = 0 }
          startbody = 0
          if (hdmode && match(line, /<<-?[ \t]*[\047"]?[A-Za-z0-9_]+/)) {
            mk = substr(line, RSTART, RLENGTH); sub(/^<<-?[ \t]*[\047"]?/, "", mk); startbody = 1
          }
          n = length(line)
          for (i = 1; i <= n; i++) {
            c = substr(line, i, 1)
            if (sq) { addc(c); if (c == "\047") sq = 0; continue }
            if (c == "\\") { addc(c); if (i < n) { i++; addc(substr(line, i, 1)) }; continue }
            if (dq) { addc(c); if (c == "\"") dq = 0; continue }
            if (c == "\047") { sq = 1; addc(c); continue }
            if (c == "\"") { dq = 1; addc(c); continue }
            if (c == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[ \t;&|(]/)) break
            if (c == "(") { pd++; sp++; nid++; sp_path[sp] = sp_path[sp - 1] "/" nid; addc(c); continue }
            if (c == ")") { if (pd > 0) pd--; if (sp > 0) sp--; addc(c); continue }
            if (c == "{") { bd++; addc(c); continue }
            if (c == "}") { if (bd > 0) bd--; addc(c); continue }
            if (c == ";") { flush("S"); continue }
            if (c == "|") { if (substr(line, i + 1, 1) == "|") { i++; flush("O") } else flush("P"); continue }
            if (c == "&") {
              if (substr(line, i + 1, 1) == "&") { i++; flush("A"); if (pd == 0 && bd == 0) chunk++; continue }
              pc = (i > 1) ? substr(line, i - 1, 1) : ""
              if (pc == ">" || pc == "<" || substr(line, i + 1, 1) == ">") { addc(c); continue }
              flush("B"); continue
            }
            addc(c)
          }
          if (!sq && !dq) flush("S"); else buf = buf "\n"
          if (startbody) { inbody = 1; marker = mk; nid++; bodyscope = "H" nid }
        }
        flush("END")
      }' 2>/dev/null)
    while IFS=$'\t' read -r _d2_c _d2_s _d2_sb _d2_sa _d2_seg; do
      [[ -n "$_d2_seg" ]] || continue
      # ① 정의 갱신 — 구간 머리의 ( { 공백·do/then/else 를 걷어 낸 본문으로 판정한다
      _d2_b="$_d2_seg"
      while :; do
        _d2_b="${_d2_b#"${_d2_b%%[![:space:]\({]*}"}"
        if [[ "$_d2_b" =~ ^(do|then|else)[[:space:]]+(.*)$ ]]; then _d2_b="${BASH_REMATCH[2]}"; continue; fi
        break
      done
      # [사이클206 FD2] 따옴표가 든 구간은 따옴표 인식 분할(`S="/tmp/한글 공백.xlsx"` 가 한 단어). 닫히지 않은 따옴표·따옴표 없는 구간은 종전 분할.
      if [[ "$_d2_b" == *[\"\']* ]] && _d2_words "$_d2_b"; then :; else set -f; read -r -a _d2_w <<<"$_d2_b"; set +f; fi
      if [[ ${#_d2_w[@]} -gt 0 ]]; then
        _d2_i0=0
        case "${_d2_w[0]}" in export|readonly|declare|typeset|local) _d2_i0=1 ;; esac
        if [[ "${_d2_w[0]}" =~ ^(unset|read|readarray|mapfile)$ ]]; then
          for _d2_t in "${_d2_w[@]:1}"; do [[ "$_d2_t" =~ $_D2_RE_NAME ]] && unset "_d2_dch[$_d2_t]"; done
        elif [[ "$_d2_b" =~ ^for[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)[[:space:]]+in([[:space:]]+(.*))?$ ]]; then
          _d2_fn="${BASH_REMATCH[1]}"; _d2_fw="${BASH_REMATCH[3]}"
          unset "_d2_dch[$_d2_fn]"
          if [[ "$_d2_sb" =~ ^(START|S|A)$ && "$_d2_sa" == "S" && -n "${_d2_fw//[[:space:]]/}" && \
                "$_d2_fw" != *[\$\`\*\?\[\(\\]* ]]; then
            _d2_dch[$_d2_fn]="$_d2_c"; _d2_dsc[$_d2_fn]="$_d2_s"; _d2_dvl[$_d2_fn]="${_d2_fw//[\"\']/}"; _d2_dun[$_d2_fn]=0
          fi
        elif [[ ${#_d2_w[@]} -gt $_d2_i0 && "${_d2_w[$_d2_i0]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
          # 대입 구간 — 전부 대입이면 순수 대입문(셸 변수 정의), 뒤에 명령이 붙으면 접두 대입(정의 아님)
          _d2_pure=1
          for _d2_t in "${_d2_w[@]:$_d2_i0}"; do [[ "$_d2_t" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || { _d2_pure=0; break; }; done
          for _d2_t in "${_d2_w[@]:$_d2_i0}"; do
            [[ "$_d2_t" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || break
            _d2_fn="${BASH_REMATCH[1]}"; _d2_fv="${BASH_REMATCH[2]}"
            unset "_d2_dch[$_d2_fn]"
            if [[ $_d2_pure -eq 1 && "$_d2_sb" =~ ^(START|S|A)$ && "$_d2_sa" =~ ^(S|A|END)$ ]] && _d2_val "$_d2_fv"; then
              _d2_dch[$_d2_fn]="$_d2_c"; _d2_dsc[$_d2_fn]="$_d2_s"; _d2_dvl[$_d2_fn]="$_d2_vv"
              _d2_dun[$_d2_fn]="$_d2_vunk"; _d2_dsrc[$_d2_fn]="$_d2_vsrc"
            fi
          done
        fi
      fi
      # ② 파괴 명령 피연산자 판정
      _d2_line=$(echo "$_d2_seg" | grep -oP '^\s*(?:[({]\s*)*(?:(?:do|then|else)\s+)?(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*(?:sudo\s+)?\K(?:cp|rsync|rm|mv|cd|pushd|ln|tar)\s+.*$' 2>/dev/null) || continue
      _d2_cmd=${_d2_line%%[[:space:]]*}
      _d2_ops=${_d2_line#"$_d2_cmd"}
      # [사이클172] tar 는 -C/--directory 피연산자만 본다(아카이브·멤버 이름은 대상 아님).
      if [[ "$_d2_cmd" == "tar" ]]; then
        _d2_tops=""; _d2_next=0
        set -f
        for _d2_t in $_d2_ops; do
          if [[ $_d2_next -eq 1 ]]; then _d2_tops="$_d2_tops $_d2_t"; _d2_next=0; continue; fi
          case "$_d2_t" in -C|--directory) _d2_next=1 ;; --directory=*) _d2_tops="$_d2_tops ${_d2_t#--directory=}" ;; esac
        done
        set +f
        _d2_ops="$_d2_tops"
      fi
      [[ -n "${_d2_ops// /}" ]] || continue
      set -f
      for _d2_o in $_d2_ops; do
        _d2_u=$(printf '%s' "$_d2_o" | tr -d "\"'()")
        case "$_d2_u" in -*|"") continue ;; esac
        if [[ "$_d2_u" =~ $_D2_RE_ROOT ]]; then
          case "$_d2_cmd" in cd|pushd) continue ;; esac   # cd / 는 이동일 뿐 파괴가 아니다
          _D2_REASON="루트 디렉토리를 피연산자로 씁니다: ${_d2_u}"; break
        fi
        # [사이클206 교차검토 2차 ③] 보호 디렉터리(설정 루트·hooks·skills·session-env·projects·HOME) 자체 삭제·이동 — 리터럴·~ 경로
        if [[ "$_d2_cmd" == rm || "$_d2_cmd" == mv ]]; then
          _d2_lp="$_d2_u"; [[ "$_d2_lp" == "~" || "$_d2_lp" == "~/"* ]] && _d2_lp="${HOME}${_d2_lp#\~}"
          if [[ "$_d2_lp" == /* ]] && _d2_prot "$_d2_lp"; then
            _D2_REASON="보호 디렉터리 자체(또는 전체 내용)를 ${_d2_cmd} 합니다: ${_d2_u}"; break
          fi
        fi
        if [[ "$_d2_u" == \$* ]]; then
          # [사이클206 교차검토 2차 ②] 피연산자 자리 `${N:-기본}…`·`$HOME…` — 실제 값은 기본값이 아닐 수 있으므로(HOME 은 늘 설정)
          #   rm|mv|rsync 는 `/<리터럴 하위경로>` 가 붙을 때만 통과하고, rm|mv 는 기본값·현재 환경값 어느 쪽으로든 보호 디렉터리가 되면 차단.
          if [[ "$_d2_u" =~ $_D2_RE_DEF ]] || [[ "$_d2_u" =~ $_D2_RE_HOME ]]; then
            _d2_n2=""; _d2_df=""; _d2_rs=""
            if [[ "$_d2_u" =~ ^\$\{([A-Za-z_][A-Za-z0-9_]*):-([^}]*)\}(.*)$ ]]; then
              _d2_n2="${BASH_REMATCH[1]}"; _d2_df="${BASH_REMATCH[2]}"; _d2_rs="${BASH_REMATCH[3]}"
              [[ "$_d2_df" =~ ^\$(HOME|\{HOME\})(.*)$ ]] && _d2_df="${HOME}${BASH_REMATCH[2]}"
            elif [[ "$_d2_u" =~ ^\$(HOME|\{HOME\})(.*)$ ]]; then
              _d2_n2=HOME; _d2_rs="${BASH_REMATCH[2]}"
            else
              _d2_rs="?"
            fi
            case "$_d2_cmd" in
              rm|mv|rsync)
                if ! _d2_subok "$_d2_rs"; then
                  _D2_REASON="실제 값을 정적으로 알 수 없는 확장(${_d2_n2:-?})을 하위 경로 없이 씁니다: ${_d2_u}"; break
                fi ;;
            esac
            if [[ "$_d2_cmd" == rm || "$_d2_cmd" == mv ]]; then
              for _d2_v in "$_d2_df" "${_d2_n2:+${!_d2_n2:-}}"; do
                [[ -n "$_d2_v" && "$_d2_v" != *'$'* ]] || continue
                if _d2_prot "${_d2_v}${_d2_rs}"; then _D2_REASON="보호 디렉터리로 전개됩니다: ${_d2_u} → ${_d2_v}${_d2_rs}"; break; fi
              done
              [[ -n "$_D2_REASON" ]] && break
            fi
            continue
          fi
          if [[ "$_d2_u" =~ $_D2_RE_REQ ]] || [[ "$_d2_u" == \$\(* ]]; then
            continue
          fi
          # [사이클182 X1] 같은 && 구간·같은(또는 조상) 스코프에서 앞서 리터럴로 정의된 변수 → 값으로 바꿔 루트 여부만 본다
          _d2_var=""; _d2_rest=""
          if [[ "$_d2_u" =~ ^\$([A-Za-z_][A-Za-z0-9_]*)(.*)$ ]] || [[ "$_d2_u" =~ ^\$\{([A-Za-z_][A-Za-z0-9_]*)\}(.*)$ ]]; then
            _d2_var="${BASH_REMATCH[1]}"; _d2_rest="${BASH_REMATCH[2]}"
          fi
          if [[ -n "$_d2_var" ]] && _d2_has "$_d2_var" "$_d2_c" "$_d2_s"; then
            # [사이클206 교차검토 2차 ①] "값 모름" 정의(`D=${N:-기본}`) — rm|mv|rsync 는 `$D/<리터럴 하위경로>` 일 때만,
            #   rm|mv 는 기본값·현재 환경값으로 보호 디렉터리가 되면 차단. 루트 검사는 기본값으로는 증명되지 않으므로 하위 경로 조건으로 대신한다.
            if [[ "${_d2_dun[$_d2_var]:-0}" == 1 ]]; then
              case "$_d2_cmd" in
                rm|mv|rsync)
                  if ! _d2_subok "$_d2_rest"; then
                    _D2_REASON="변수 ${_d2_var} 의 실제 값을 정적으로 알 수 없어(\${${_d2_dsrc[$_d2_var]}:-…}) 하위 경로 없이 쓸 수 없습니다: ${_d2_u}"; break
                  fi ;;
              esac
              if [[ "$_d2_cmd" == rm || "$_d2_cmd" == mv ]]; then
                _d2_n2="${_d2_dsrc[$_d2_var]}"
                for _d2_v in "${_d2_dvl[$_d2_var]}" "${_d2_n2:+${!_d2_n2:-}}"; do
                  [[ -n "$_d2_v" ]] || continue
                  if _d2_prot "${_d2_v}${_d2_rest}"; then _D2_REASON="변수 ${_d2_var} 가 보호 디렉터리로 전개됩니다: ${_d2_v}${_d2_rest}"; break; fi
                done
                [[ -n "$_D2_REASON" ]] && break
              fi
              continue
            fi
            if [[ "$_d2_cmd" == rm || "$_d2_cmd" == mv ]] && _d2_prot "${_d2_dvl[$_d2_var]}${_d2_rest}"; then
              _D2_REASON="변수 ${_d2_var} 가 보호 디렉터리로 전개됩니다: ${_d2_dvl[$_d2_var]}${_d2_rest}"; break
            fi
            for _d2_v in ${_d2_dvl[$_d2_var]}; do
              if [[ "${_d2_v}${_d2_rest}" =~ $_D2_RE_ROOT ]]; then
                case "$_d2_cmd" in cd|pushd) continue ;; esac
                _D2_REASON="변수 ${_d2_var} 의 값이 루트로 전개됩니다: ${_d2_v}${_d2_rest}"; break
              fi
            done
            [[ -n "$_D2_REASON" ]] && break
            continue
          fi
          case "$_d2_cmd" in
            cd|pushd|ln|tar)
              # [사이클172→182] 같은 명령 문자열에서 대입했지만 위 정의 규칙(같은 && 구간·순수 대입·리터럴)을 못 채운 변수만 차단
              #   — 다른 && 구간·파이프·|| 뒤·접두 대입·비리터럴 값. 하네스 환경변수(CLAUDE_CONFIG_DIR 등) cd 는 오차단하지 않는다.
              _d2_var=$(printf '%s' "$_d2_u" | grep -oP '^\$\{?\K[A-Za-z_][A-Za-z0-9_]*')
              if [[ -n "$_d2_var" ]] && printf '%s' "$_D2_CMD" | grep -qP "(^|[;&|(\s])(export\s+)?${_d2_var}="; then
                _D2_REASON="${_d2_cmd} 의 대상이 다른 && 구간(또는 파이프·조건부·비리터럴)에서 대입한 변수입니다(실행 시 빈 값일 수 있음): ${_d2_u}"; break
              fi
              continue ;;
          esac
          _D2_REASON="변수로 시작하는 피연산자가 빈 값일 때의 보장이 없습니다: ${_d2_u}"; break
        fi
      done
      set +f
      [[ -n "$_D2_REASON" ]] && break
    done <<< "$_D2_RECS"
    unset -f _d2_has _d2_lit _d2_val _d2_words _d2_subok _d2_prot

    if [[ -n "$_D2_REASON" ]]; then
      _D2_REASON=$(printf '%s' "$_D2_REASON" | tr -d '"\\' | tr '\n' ' ')
      echo "{\"decision\":\"block\",\"reason\":\"🚫 [사이클167/F-DESTROY-2] 루트·빈 변수 대상 차단 — ${_D2_REASON}. oio bash_exec 는 최상위 && 구간을 별도 셸로 실행합니다(; 와 개행은 한 셸, for 루프 안의 && 도 분할됨). 그래서 앞 && 구간에서 대입한 변수는 뒤 구간에서 빈 값이 됩니다(D=/x && cp -a \$D/. /y 는 cp -a /. /y 가 됩니다). 같은 && 구간 안에서 ; 로 이은 리터럴 대입(D=/x; cp \$D/a /y)과 리터럴 목록 for 는 통과합니다. → 대입과 사용을 ; 로 잇거나, 경로를 ★절대경로 리터럴★로 쓰거나, \${D:?} 형식으로 쓰거나, 전체를 bash -c '...' 한 덩어리로 감싸십시오. 비상 시 hooks/DISABLE_DESTROY_GUARD 로 우회 가능.\"}"
      echo "🚫 [F-DESTROY-2] ${_D2_REASON} — 대입과 사용을 같은 && 구간(; 로 연결)에 두거나 절대경로 리터럴·\${D:?}·bash -c 로 감싸라." >&2
      exit 2
    fi
  fi
fi
# --- F-DESTROY-2 끝 ---

# --- F-NEW-1-SH: [사이클215] bash 명령이 .claude/ 링크를 거쳐 NTFS 대상 내용을 쓰거나 지우면 차단 ---
# 배경: F-NEW-1(oio 파일 도구)은 .tool_input.path 만 보므로 bash_exec 는 판정 밖이었다. 실측(사이클215 프로브) —
#   `rm -r <링크>/`·`rm -rf <링크>/*`·`echo x > <링크>/a`·`cp x <링크>/`·`ln -sf x <링크>`·`mv x <링크>`·`touch <링크>/n` 이
#   메인·팀원 모두 통과했다(뒤 슬래시 rm -r 은 대상 디렉토리 내용을 지운다).
# 판정: 명령에 .claude 아래 경로 단어 중 실경로(realpath -m)가 /mnt/[c-z] 인 것이 있을 때만(사전 거름) 분기 D 토큰기
#   (_wg_d_each + _wg_drw_seg, _WG_TMODE=lnk)로 쓰기·삭제 대상을 뽑아 _wg_lnk_wviol 로 본다. 토큰화 불확실도 차단(사전 거름 통과분 한정).
# 허용: 링크 노드 자체(정규형·-L·부모 ext4)에 대한 rm·unlink·ln -n/-T, 읽기(cat·ls·readlink 등 — 쓰기 대상이 아님),
#   F-NEW-1-EXC 와 같은 memory/*.md. 한계: 변수·명령치환으로 숨긴 경로는 사전 거름에 안 걸린다(분기 D 와 같은 한계).
_wg_lnk_wviol() {  # $1=쓰기 대상 단어 → 0 = 링크 경유 NTFS 쓰기·삭제(차단), 1 = 판정 밖·허용
  local _t="$1" _cd="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" _r _par
  [[ "$_t" == /* && "$_t" != *'$'* ]] || return 1
  [[ "$_t" == "$_cd"/* || "$_t" == /home/*/.claude/* ]] || return 1
  [[ "$_t" == "$_cd"/*/memory/*.md && "$_t" != *'/../'* && "$_t" != *'/./'* ]] && return 1
  _r=$(realpath -m -- "$_t" 2>/dev/null) || return 1
  [[ "$_r" =~ ^/mnt/[c-z](/|$) ]] || return 1
  if [[ "$_t" != */ && "$_t" != */. && "$_t" != */.. && "$_t" != *'//'* && "$_t" != *'/./'* && "$_t" != *'/../'* && -L "$_t" ]]; then
    _par=$(realpath -e -- "${_t%/*}" 2>/dev/null) || return 0
    if [[ ! "$_par" =~ ^/mnt/[c-z](/|$) ]]; then
      case "${_b:-}" in
        rm|unlink) return 1 ;;
        ln) [[ "${_lnn:-0}" == 1 ]] && return 1 ;;
      esac
    fi
  fi
  return 0
}
_wg_lnk_any() {  # $1=명령 → .claude 아래 경로 단어 중 실경로가 NTFS 인 것(memory/*.md 제외)이 있으면 0
  local _w _cd="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" _r
  [[ "$1" == *.claude* ]] || return 1
  while IFS= read -r _w; do
    [[ -n "$_w" ]] || continue
    [[ "$_w" == "$_cd"/* || "$_w" == /home/*/.claude/* ]] || continue
    [[ "$_w" == "$_cd"/*/memory/*.md && "$_w" != *'/../'* && "$_w" != *'/./'* ]] && continue
    _r=$(realpath -m -- "$_w" 2>/dev/null) || continue
    [[ "$_r" =~ ^/mnt/[c-z](/|$) ]] && return 0
  done < <(printf '%s' "$1" | grep -oE '/[^[:space:];|&<>()"`'"'"']+')
  return 1
}
if [[ "$TOOL_NAME" == "mcp__oio__bash_exec" ]]; then
  _wg_pre _LNK_CMD "$_WG_STRCMD" '([.tool_input.command, .tool_input.cmd] | map(select(type == "string"))[0]) // empty'
  if [[ -n "$_LNK_CMD" ]] && _wg_lnk_any "$_LNK_CMD" && _WG_TMODE=lnk _wg_d_each "$_LNK_CMD" _wg_drw_seg; then
    jq -cn --arg r "🚫 [F-NEW-1-SH] .claude/ 심볼릭링크를 거쳐 NTFS 대상 내용을 쓰거나 지우는 셸 명령 차단 — 링크 노드 자체는 rm·unlink(뒤 슬래시 없이)·ln -sfn 으로, 노드 삭제는 mcp__oio__file_delete 로 한다. 대상 내용 변경은 NTFS 실경로로 직접 다룬다." '{decision:"block",reason:$r}'
    exit 2
  fi
fi
# --- F-NEW-1-SH 끝 ---

# --- F11: L-362 AST lint (session_manager.py 수정 감지 → lib/l362_lint.sh 호출) ---
# oio file_edit/file_write 대상이 session_manager.py(또는 oio-mcp-server/*.py)인 경우,
# 편집 시점의 파일 현재 상태를 AST 정적 분석. `with _fs_lock:` 내부 blocking I/O 검출.
# 현재 파일 상태 기반 pre-check — 팀/메인 구분 없이 전역 적용 (L-362 물리 차단 의무).
case "$TOOL_NAME" in
  mcp__oio__file_edit|mcp__oio__file_write)
    _L362_PATH=$(echo "$INPUT" | jq -r '.tool_input.path // .tool_input.file_path // empty' 2>/dev/null || echo "")
    if [[ "$_L362_PATH" =~ session_manager\.py$ ]] || [[ "$_L362_PATH" =~ oio-mcp-server/.*\.py$ ]]; then
      if [[ -f "$_L362_PATH" && -x "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/l362_lint.sh" ]]; then
        _L362_OUT=$("${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/l362_lint.sh" "$_L362_PATH" 2>&1)
        _L362_RC=$?
        if [[ "$_L362_RC" -eq 1 ]]; then
          _L362_SUMMARY=$(echo "$_L362_OUT" | head -c 300 | tr '\"\\' "'/" | tr '\n' ' ')
          echo "{\"decision\":\"block\",\"reason\":\"❌ [L-362/F11] _fs_lock 컨텍스트 내부 blocking I/O 감지 — 저장 거부. ${_L362_SUMMARY}\"}"
          exit 2
        fi
      fi
    fi
    ;;
esac

# --- stdin_eof_monitor 재작성 차단 (원인 4) ---
# server.py에 _start_stdin_eof_monitor를 다시 추가하는 시도를 물리 차단
# 이유: FastMCP stdio 충돌로 서버 자폭 유발
case "$TOOL_NAME" in
  mcp__oio__file_edit|mcp__oio__file_write)
    _GUARD_TARGET_PATH=$(echo "$INPUT" | jq -r '.tool_input.path // .tool_input.file_path // empty' 2>/dev/null || echo "")
    if [[ "$_GUARD_TARGET_PATH" =~ oio-mcp-server/server\.py$ ]]; then
      _GUARD_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.new_text // .tool_input.new_string // .tool_input.content // empty' 2>/dev/null || echo "")
      if echo "$_GUARD_CONTENT" | grep -qE '_start_stdin_eof_monitor|_stdin_eof_monitor_shutdown|def _start_stdin_eof'; then
        echo '{"decision":"block","reason":"🚫 stdin_eof_monitor 재작성 금지 — FastMCP stdio 충돌로 서버 자폭. 재작성 시도는 물리 차단됩니다. (원인 4)"}'
        exit 2
      fi
    fi
    ;;
esac

# ═══ [사이클215 F-NEW-1-LNK] 링크 노드 자체 조작 판정 — $1=경로 → 0 이면 F-NEW-1 realpath 판정을 생략한다 ═══
#   배경: F-NEW-1 은 realpath -m 결과가 NTFS 면 막는데, 링크 노드를 지우는 file_delete 도 대상(NTFS)으로 풀려 막혔다
#         (사이클214 oinfra_mars/scripts 링크 삭제 차단). oio file_delete 는 os.remove(링크) = 노드 unlink 이고
#         file_rename 은 os.rename = 노드 이름 변경이라 대상 내용을 건드리지 않는다(oio file_ops.py 실측).
#   허용: 도구가 file_delete·file_rename(new_name 에 / 없음)이고, 경로가 정규형 절대경로이며 [[ -L ]](lstat) 참,
#         부모 디렉토리 realpath -e 가 NTFS 가 아닐 때만. 이후 판정(F-ISO-3 등)은 그대로 거친다.
#   제외(종전 차단): file_write·file_edit(링크를 따라 대상에 씀), dir_delete(rmtree '링크/' 가 대상 내용을 지움 — 실측),
#         뒤 슬래시·/./·/../·// 경로. 끊긴 링크는 가드 허용이나 oio 가 FILE_NOT_FOUND 를 돌려준다.
_wg_fnew1_link_node() {
  local _p="$1" _nn _par
  case "$TOOL_NAME" in
    mcp__oio__file_delete) ;;
    mcp__oio__file_rename)
      _nn=$(echo "$INPUT" | jq -r '.tool_input.new_name // empty' 2>/dev/null || echo "")
      [[ -n "$_nn" && "$_nn" != */* && "$_nn" != "." && "$_nn" != ".." ]] || return 1 ;;
    *) return 1 ;;
  esac
  [[ "$_p" == /* ]] || return 1
  [[ "$_p" != */ && "$_p" != */. && "$_p" != */.. && "$_p" != *'//'* && "$_p" != *'/./'* && "$_p" != *'/../'* ]] || return 1
  [[ -L "$_p" ]] || return 1
  _par=$(realpath -e -- "${_p%/*}" 2>/dev/null) || return 1
  [[ "$_par" =~ ^/mnt/[c-z](/|$) ]] && return 1
  return 0
}

case "$TOOL_NAME" in
  mcp__oio__file_edit|mcp__oio__file_write|mcp__oio__file_delete|\
  mcp__oio__file_rename|mcp__oio__file_move|mcp__oio__file_copy|\
  mcp__oio__file_symlink|\
  mcp__oio__dir_create|mcp__oio__dir_delete|mcp__oio__dir_move|\
  mcp__oio__dir_rename|mcp__oio__bash_exec|\
  mcp__plugin_serena_serena__replace_content|mcp__plugin_serena_serena__replace_symbol_body|\
  mcp__plugin_serena_serena__insert_after_symbol|mcp__plugin_serena_serena__insert_before_symbol|\
  mcp__plugin_serena_serena__safe_delete_symbol|mcp__plugin_serena_serena__rename_symbol|\
  mcp__plugin_serena_serena__create_text_file|\
  mcp__serena__replace_content|mcp__serena__replace_symbol_body|\
  mcp__serena__insert_after_symbol|mcp__serena__insert_before_symbol|\
  mcp__serena__safe_delete_symbol|mcp__serena__rename_symbol|\
  mcp__serena__create_text_file)
    # ═══════════════════════════════════════════════════════════════════════
    # [r3 ohook-3 — conv_179065014644_r3] F-DIS-1 · F-AC-2 · 승인 마커 보호 · bash state 관찰(Hd3)
    #   ★이 블록은 추가만 한다 — 아래 기존 분기(F-GOAL-1/F-AC-1/H-1/…)의 판정은 바꾸지 않는다.★
    #   (단 하나의 예외: F-AC-1 bash 동사 목록에서 'python3 단독' 을 '쓰기 동반 python' 으로 좁혔다 — review-3 R1)
    #   원칙: 대상 판정 전 오류는 통과(종전), 대상이 명확할 때만 fail-closed.
    #   세션 격리 §(a): 판정 대상 UUID 가 자기 세션(session_id 또는 조상 argv --parent-session-id)일 때만
    #   그 세션 파일을 읽고/쓴다. 타 세션 경로는 여기서 건드리지 않는다(F-ISO-3 가 따로 막는다).
    # ═══════════════════════════════════════════════════════════════════════
    _r3_first() {  # 인자: jq 경로 목록(쉼표) → 비어 있지 않은 첫 문자열 값
      echo "$INPUT" | jq -r "[$1] | map(select(. != null and (type == \"string\") and . != \"\")) | .[0] // empty" 2>/dev/null || true
    }
    _r3_norm() {  # 심볼릭링크는 풀지 않고 ./.. · // 만 정규화
      [[ -z "$1" ]] && return 0
      realpath -ms -- "$1" 2>/dev/null || printf '%s' "$1"
    }
    _r3_lineage() {  # 팀에이전트면 파이프라인 UUID 출력, 메인이면 빈값 (T-E/F-ISO-3 과 같은 기준: 조상 argv --parent-session-id)
      # 테스트 주입(샌드박스 전용): WG_TEST_SANDBOX=1 이고 HOME 이 실사용자 홈이 아닐 때만 WG_LINEAGE_OVERRIDE 를 믿는다.
      if [[ "${WG_TEST_SANDBOX:-}" == "1" && -n "${WG_LINEAGE_OVERRIDE:-}" ]]; then
        local _real_home
        _real_home=$(getent passwd "$(id -un 2>/dev/null)" 2>/dev/null | cut -d: -f6)
        if [[ -n "$_real_home" && "$HOME" != "$_real_home" ]]; then
          [[ "$WG_LINEAGE_OVERRIDE" == team:* ]] && printf '%s' "${WG_LINEAGE_OVERRIDE#team:}"
          return 0
        fi
      fi
      local _p=$$ _i=0 _a _m
      while [[ -n "$_p" && "$_p" != "1" && $_i -lt 12 ]]; do
        _a=$(tr '\0' ' ' 2>/dev/null < "/proc/${_p}/cmdline")
        _m=$(printf '%s' "$_a" | grep -oP -- '--parent-session-id[ =]\K[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
        if [[ -n "$_m" ]]; then printf '%s' "$_m"; return 0; fi
        _p=$(awk '/^PPid:/{print $2}' "/proc/${_p}/status" 2>/dev/null)
        _i=$((_i + 1))
      done
      return 0
    }
    _R3_TEAM_DONE=""; _R3_TEAM=""
    _r3_is_team() {  # 서브셸 없이 호출할 것(결과 캐시)
      if [[ -z "$_R3_TEAM_DONE" ]]; then
        _R3_TEAM="${PIPELINE_UUID:-}"
        [[ -z "$_R3_TEAM" ]] && _R3_TEAM=$(_r3_lineage)
        _R3_TEAM_DONE=1
      fi
      [[ -n "$_R3_TEAM" ]]
    }
    _r3_is_self() {  # $1=대상 UUID. 자기 세션(메인 session_id 또는 팀에이전트의 파이프라인 UUID)인가
      local _t="$1" _sid
      [[ -z "$_t" ]] && return 1
      _sid=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
      [[ "$_t" == "$_sid" ]] && return 0
      _r3_is_team && [[ "$_t" == "$_R3_TEAM" ]] && return 0
      return 1
    }
    _r3_state_of() {  # $1=세션 디렉터리 → state 첫 토큰 (경로 그대로 → CFG → HOME 폴백)
      local _d="$1" _u _f _s=""
      _u=$(basename "$_d")
      for _f in "$_d/state" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${_u}/state" "$HOME/.claude/session-env/${_u}/state"; do
        if [[ -f "$_f" ]]; then _s=$(awk 'NR==1{print $1}' "$_f" 2>/dev/null); break; fi
      done
      printf '%s' "$_s"
    }
    _r3_block() {  # $1=태그 $2=사유
      local _r
      _r=$(jq -cn --arg r "$2" '{decision:"block", reason:$r}' 2>/dev/null) \
        || _r="{\"decision\":\"block\",\"reason\":\"🔒 [$1] 차단\"}"
      echo "$_r"
      source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/write_error.sh" 2>/dev/null || true
      declare -F log_hook_error >/dev/null 2>&1 && \
        log_hook_error "HOOK_BLOCK_R3_$1" "$TOOL_NAME" "$(printf '%s' "$2" | head -1 | head -c 200)" "$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null)"
      exit 2
    }
    # python 쓰기 동반 판정 (F-AC-1·F-AC-2 공용 — review-3 R1: python3 단독 실행은 쓰기가 아니다)
    _r3_py_write() {
      printf '%s' "$1" | grep -qP '\bpython3?\b' || return 1
      printf '%s' "$1" | grep -qP "(open\([^)]*,\s*(mode\s*=\s*)?[\"'][^\"']*[wax+]|write_text|write_bytes|json\.dump\(|shutil\.(copy|move)|os\.(remove|rename|replace|unlink)|\.unlink\()"
    }

    _R3_CMD=""
    [[ "$TOOL_NAME" == "mcp__oio__bash_exec" ]] && _R3_CMD=$(_r3_first '.tool_input.command, .tool_input.cmd')

    # 도구별 "쓰여지는 쪽" 경로(_R3_DST)와 "사라지는 쪽" 경로(_R3_SRC)
    _R3_DST=""; _R3_SRC=""; _R3_RN=""
    case "$TOOL_NAME" in
      mcp__oio__file_write|mcp__oio__file_edit|mcp__oio__dir_create|\
      mcp__plugin_serena_serena__create_text_file|mcp__serena__create_text_file)
        _R3_DST=$(_r3_first '.tool_input.path, .tool_input.file_path, .tool_input.filepath, .tool_input.relative_path') ;;
      mcp__oio__file_copy)
        _R3_DST=$(_r3_first '.tool_input.destination, .tool_input.dest, .tool_input.dst, .tool_input.target, .tool_input.to') ;;
      mcp__oio__file_move|mcp__oio__dir_move)
        _R3_DST=$(_r3_first '.tool_input.destination, .tool_input.dest, .tool_input.dst, .tool_input.target, .tool_input.to')
        _R3_SRC=$(_r3_first '.tool_input.source, .tool_input.src, .tool_input.path') ;;
      mcp__oio__file_rename|mcp__oio__dir_rename)
        _R3_SRC=$(_r3_first '.tool_input.path, .tool_input.file_path')
        _R3_RN=$(_r3_first '.tool_input.new_name, .tool_input.name, .tool_input.new_path, .tool_input.to')
        if [[ "$_R3_RN" == /* ]]; then _R3_DST="$_R3_RN"
        elif [[ -n "$_R3_RN" && -n "$_R3_SRC" ]]; then _R3_DST="$(dirname "$_R3_SRC")/${_R3_RN}"; fi ;;
      mcp__oio__file_symlink)
        _R3_DST=$(_r3_first '.tool_input.link_path, .tool_input.link, .tool_input.dest, .tool_input.path') ;;
      mcp__oio__file_delete|mcp__oio__dir_delete)
        _R3_SRC=$(_r3_first '.tool_input.path, .tool_input.file_path, .tool_input.filepath') ;;
    esac
    # 심볼릭링크 해석본(F-AC-2 대상 판정 전용 — ohook-4 bypass D1d: 링크 경유 원본 편집 차단)
    _R3_DST_R=""; _R3_SRC_R=""
    [[ -n "$_R3_DST" ]] && _R3_DST_R=$(realpath -m -- "$_R3_DST" 2>/dev/null || true)
    [[ -n "$_R3_SRC" ]] && _R3_SRC_R=$(realpath -m -- "$_R3_SRC" 2>/dev/null || true)
    _R3_DST=$(_r3_norm "$_R3_DST"); _R3_SRC=$(_r3_norm "$_R3_SRC")

    # ── F-DIS-1: 팀에이전트의 hooks/DISABLE_* 생성·이동 차단 (비상 스위치는 메인·사용자 전용) ──
    if [[ "$_R3_DST" =~ /\.claude/hooks/DISABLE_[^/]*$ ]]; then
      if _r3_is_team; then
        _r3_block "F-DIS-1" "🚫 [F-DIS-1] 팀에이전트는 hooks/DISABLE_* 비상 스위치를 만들거나 옮길 수 없습니다(대상: ${_R3_DST}). 비상 스위치는 메인 에이전트·사용자만 씁니다 — 차단 사유를 team-lead 에게 SendMessage 로 보고하십시오."
      fi
    fi
    if [[ -n "$_R3_CMD" ]] && printf '%s' "$_R3_CMD" | grep -qP 'DISABLE_[A-Za-z0-9_]+'; then
      if printf '%s' "$_R3_CMD" | grep -qP "(\btouch\b[^;|&]*DISABLE_|\btee\b[^;|&]*DISABLE_|\bln\b[^;|&]*DISABLE_|\b(cp|mv|install|rsync)\b[^;|&]*\s[\"']?[^\s;|&\"']*DISABLE_[A-Za-z0-9_]+[\"']?\s*($|[;|&])|>>?\s*[\"']?[^\s;|&\"']*DISABLE_[A-Za-z0-9_]+|\b(python3?|perl)\b[\s\S]*DISABLE_[\s\S]*(open\(|write_text|touch\())"; then
        if _r3_is_team; then
          _r3_block "F-DIS-1" "🚫 [F-DIS-1/bash] 팀에이전트는 셸 명령으로 DISABLE_* 비상 스위치를 만들 수 없습니다. 비상 스위치는 메인 에이전트·사용자만 씁니다 — team-lead 에게 보고하십시오."
        fi
      fi
    fi

    # ── F-AC-2(a): 승인 마커 plans/ac_edit_approval.json 은 메인만 작성 (bash 경로는 전원 차단) ──
    if [[ "$_R3_DST" =~ session-env/[^/]+/plans/ac_edit_approval\.json$ ]]; then
      if _r3_is_team; then
        _r3_block "F-AC-2" "🚫 [F-AC-2] 승인 마커(ac_edit_approval.json)는 메인 에이전트만 작성할 수 있습니다(팀에이전트 계보 확인됨: parent=${_R3_TEAM}). TEST 이후 acceptance_criteria.json 편집이 필요하면 team-lead 에게 ac_ids·fields·사유를 보고해 승인을 받으십시오."
      fi
    fi
    if [[ -n "$_R3_CMD" ]] && printf '%s' "$_R3_CMD" | grep -qP 'ac_edit_approval\.json'; then
      if printf '%s' "$_R3_CMD" | grep -qP "(>>?\s*[\"']?[^\s;|&\"']*ac_edit_approval\.json|\b(tee|touch|ln)\b[^;|&]*ac_edit_approval\.json|\b(cp|mv|install|rsync)\b[^;|&]*\s[\"']?[^\s;|&\"']*ac_edit_approval\.json[\"']?\s*($|[;|&])|\bsed\b(?=[^;|&]*\s-i)[^;|&]*ac_edit_approval\.json)" \
         || _r3_py_write "$_R3_CMD"; then
        _r3_block "F-AC-2" "🚫 [F-AC-2/bash] 승인 마커(ac_edit_approval.json)는 셸 명령으로 쓸 수 없습니다. 메인 에이전트가 mcp__oio__file_write 로 작성하십시오: {\"approved_by\":\"team-lead\",\"reason\":\"...\",\"ac_ids\":[\"AC-0xx\"],\"fields\":[\"필드명\"],\"created_at\":\"ISO8601\"}"
      fi
    fi

    # ── F-AC-2(b): state ∈ {TEST,DONE,FINISH} 에서 acceptance_criteria.json 원본 보호 ──
    #   차단: 원본 직접 편집(write/edit), 사본→원본 덮어쓰기(copy/move/rename 목적지=원본),
    #         원본 삭제·이동·이름변경·링크 치환·디렉터리째 삭제/이동(승인 마커로도 불가 — diff 로 범위 판정 불가).
    #   허용: 새 사본 생성(원본 → acceptance_criteria_*.json, _r3 백업 등 — review-3 R1). PLAN/DEV 는 F-AC-1 만 적용.
    #   예외: 승인 마커가 있고 편집 전후 JSON diff 가 마커의 ac_ids·fields 안에만 있으면 1회 허용 후 마커 소비.
    _R3_AC_RE='session-env/([^/]+)/(plans/)?acceptance_criteria\.json$'
    _R3_AC_T=""; _R3_AC_ACT=""
    # 링크 경유 쓰기(write-through): 쓰여지는 쪽이 원본을 가리키는 symlink 면 해석본으로 판정한다.
    #   (사라지는 쪽 SRC 는 치환하지 않는다 — 링크 자체의 삭제·이동은 원본을 건드리지 않는다)
    case "$TOOL_NAME" in
      mcp__oio__file_write|mcp__oio__file_edit|mcp__oio__file_copy|mcp__oio__file_move|mcp__oio__file_rename)
        if [[ ! "$_R3_DST" =~ $_R3_AC_RE && "$_R3_DST_R" =~ $_R3_AC_RE ]]; then _R3_DST="$_R3_DST_R"; fi ;;
    esac
    case "$TOOL_NAME" in
      mcp__oio__file_write)  [[ "$_R3_DST" =~ $_R3_AC_RE ]] && { _R3_AC_T="$_R3_DST"; _R3_AC_ACT="write"; } ;;
      mcp__oio__file_edit)   [[ "$_R3_DST" =~ $_R3_AC_RE ]] && { _R3_AC_T="$_R3_DST"; _R3_AC_ACT="edit"; } ;;
      mcp__plugin_serena_serena__create_text_file|mcp__serena__create_text_file)
                             [[ "$_R3_DST" =~ $_R3_AC_RE ]] && { _R3_AC_T="$_R3_DST"; _R3_AC_ACT="remove"; } ;;
      mcp__oio__file_copy|mcp__oio__file_move|mcp__oio__file_rename)
        if [[ "$_R3_SRC" =~ $_R3_AC_RE ]]; then _R3_AC_T="$_R3_SRC"; _R3_AC_ACT="remove"
        elif [[ "$_R3_DST" =~ $_R3_AC_RE ]]; then _R3_AC_T="$_R3_DST"; _R3_AC_ACT="copy"; fi ;;
      mcp__oio__file_symlink|mcp__oio__file_delete)
        [[ "$_R3_DST" =~ $_R3_AC_RE ]] && { _R3_AC_T="$_R3_DST"; _R3_AC_ACT="remove"; }
        [[ "$_R3_SRC" =~ $_R3_AC_RE ]] && { _R3_AC_T="$_R3_SRC"; _R3_AC_ACT="remove"; } ;;
      mcp__oio__dir_delete|mcp__oio__dir_move|mcp__oio__dir_rename)
        # 원본을 품은 디렉터리(session-env/<uuid> 또는 그 plans/)를 통째로 지우거나 옮기는 경로
        if [[ -n "$_R3_SRC" && "$_R3_SRC" =~ session-env/[^/]+(/plans)?$ ]]; then
          for _r3_c in "$_R3_SRC/acceptance_criteria.json" "$_R3_SRC/plans/acceptance_criteria.json"; do
            [[ -f "$_r3_c" ]] && { _R3_AC_T="$_r3_c"; _R3_AC_ACT="remove"; break; }
          done
        fi ;;
    esac
    if [[ -n "$_R3_AC_T" ]]; then
      _R3_AC_U=$(printf '%s' "$_R3_AC_T" | grep -oP 'session-env/\K[^/]+' | head -1)
      if _r3_is_self "$_R3_AC_U"; then
        _R3_SD="${_R3_AC_T%%/session-env/*}/session-env/${_R3_AC_U}"
        _R3_ST=$(_r3_state_of "$_R3_SD")
        if [[ "$_R3_ST" == "TEST" || "$_R3_ST" == "DONE" || "$_R3_ST" == "FINISH" ]]; then
          if [[ "$_R3_AC_ACT" == "remove" ]]; then
            _r3_block "F-AC-2" "🔒 [F-AC-2] state=${_R3_ST} — acceptance_criteria.json 원본의 삭제·이동·이름변경·링크 치환은 금지입니다(승인 마커로도 열리지 않음). 백업이 목적이면 mcp__oio__file_copy 로 원본 → acceptance_criteria_<식별자>.json 새 사본을 만드십시오(허용). 대상: ${_R3_AC_T}"
          fi
          _R3_MK="${_R3_SD}/plans/ac_edit_approval.json"
          if [[ ! -f "$_R3_MK" ]]; then
            _r3_block "F-AC-2" "🔒 [F-AC-2] state=${_R3_ST} — TEST 이후 acceptance_criteria.json 원본 편집·사본→원본 덮어쓰기는 _prev 사본 유무와 무관하게 차단됩니다(L10: 사본 동기화 우회 8회 사고). 새 사본 생성(_r3 백업 등)은 허용됩니다. 정당한 편집이면 메인이 ${_R3_MK} 를 {\"approved_by\",\"reason\",\"ac_ids\":[...],\"fields\":[...],\"created_at\"} 로 작성한 뒤 그 범위 안에서 1회 편집하십시오."
          fi
          # 편집 후 내용 재현 → diff 범위 검사
          _R3_SRCF=""
          if [[ "$_R3_AC_ACT" == "copy" ]]; then
            _R3_SRCF=$(_r3_first '.tool_input.source, .tool_input.src, .tool_input.path')
            [[ "$TOOL_NAME" == "mcp__oio__file_rename" ]] && _R3_SRCF="$_R3_SRC"
          fi
          _R3_VERDICT=$(MODE="$_R3_AC_ACT" AC="$_R3_AC_T" MK="$_R3_MK" SRCF="$_R3_SRCF" \
            NEWC="$(_r3_first '.tool_input.content, .tool_input.body, .tool_input.data, .tool_input.new_content, .tool_input.text, .tool_input.new_text')" \
            OLD="$(_r3_first '.tool_input.old_string, .tool_input.old, .tool_input.old_text, .tool_input.old_content, .tool_input.search')" \
            NEW="$(echo "$INPUT" | jq -r '[.tool_input.new_string, .tool_input.new, .tool_input.new_text, .tool_input.new_content, .tool_input.replace] | map(select(. != null)) | .[0] // empty' 2>/dev/null)" \
            RALL="$(echo "$INPUT" | jq -r '(.tool_input.replace_all // .tool_input.global_replace // false) | tostring' 2>/dev/null)" \
            timeout 5 python3 -c '
import json,os,sys
def ng(m):
    print("NG "+m); sys.exit(0)
try:
    mk=json.load(open(os.environ["MK"],encoding="utf-8"))
except Exception:
    ng("승인 마커 JSON 파싱 실패")
if not isinstance(mk,dict): ng("승인 마커가 객체가 아님")
ids=mk.get("ac_ids"); flds=mk.get("fields")
if not isinstance(ids,list) or not ids or not all(isinstance(x,str) and x for x in ids): ng("마커 ac_ids 가 비었거나 형식 오류")
if not isinstance(flds,list) or not flds or not all(isinstance(x,str) and x for x in flds): ng("마커 fields 가 비었거나 형식 오류")
for k in ("approved_by","reason"):
    v=mk.get(k)
    if not isinstance(v,str) or not v.strip(): ng("마커 %s 누락"%k)
acp=os.environ["AC"]
if not os.path.isfile(acp): ng("원본 부재 — 신규 생성은 승인 범위로 판정할 수 없음")
cur=open(acp,encoding="utf-8").read()
mode=os.environ["MODE"]
if mode=="write":
    new=os.environ.get("NEWC","")
elif mode=="copy":
    try: new=open(os.environ.get("SRCF",""),encoding="utf-8").read()
    except Exception: ng("사본(원천) 파일을 읽을 수 없음")
elif mode=="edit":
    old=os.environ.get("OLD",""); rep=os.environ.get("NEW","")
    if not old: ng("old_string 비어 있음")
    n=cur.count(old)
    if n==0: ng("old_string 매칭 0건")
    if os.environ.get("RALL")=="true": new=cur.replace(old,rep)
    else:
        if n!=1: ng("old_string 매칭 %d건(replace_all 아님)"%n)
        new=cur.replace(old,rep,1)
else:
    ng("알 수 없는 모드")
try:
    a=json.loads(cur); b=json.loads(new)
except Exception:
    ng("편집 전/후 JSON 파싱 실패")
def split(d):
    if isinstance(d,list): return {},d,"<list>"
    if not isinstance(d,dict): ng("최상위가 객체/배열이 아님")
    for k in ("criteria","acceptance","acceptance_criteria","items"):
        if isinstance(d.get(k),list):
            t=dict(d); l=t.pop(k); return t,l,k
    return dict(d),[],None
ta,la,ka=split(a); tb,lb,kb=split(b)
if ka!=kb: ng("criteria 컨테이너 키 변경")
ha=ta.pop("change_history",None); hb=tb.pop("change_history",None)
if ta!=tb:
    ks=sorted(set(ta)|set(tb)); ch=[k for k in ks if ta.get(k)!=tb.get(k)]
    ng("최상위 필드 변경은 허용되지 않음: "+",".join(ch)[:200])
if ha!=hb:
    ha=ha or []
    if not (isinstance(ha,list) and isinstance(hb,list) and hb[:len(ha)]==ha):
        ng("change_history 는 끝에 추가만 허용")
def idx(l):
    m={}
    for x in l:
        i=x.get("id") if isinstance(x,dict) else None
        if not isinstance(i,str) or i in m: ng("id 없거나 중복된 항목 — 범위 판정 불가")
        m[i]=x
    return m
ma=idx(la); mb=idx(lb)
star="*" in flds
changed=[]
for i in sorted(set(ma)|set(mb)):
    x=ma.get(i); y=mb.get(i)
    if x==y: continue
    if i not in ids: ng("승인 범위 밖 항목 변경: "+i)
    if x is None or y is None:
        if not star: ng("항목 추가/삭제는 fields 에 * 가 있어야 함: "+i)
        changed.append(i+":+/-"); continue
    fk=[k for k in sorted(set(x)|set(y)) if x.get(k)!=y.get(k)]
    bad=[k for k in fk if k not in flds and not star]
    if bad: ng("승인 범위 밖 필드 변경: %s.%s"%(i,",".join(bad)))
    changed.append(i+":"+",".join(fk))
print("OK "+(";".join(changed) or "변경없음"))
' 2>/dev/null) || _R3_VERDICT=""
          [[ -z "$_R3_VERDICT" ]] && _R3_VERDICT="NG 판정기 실행 실패(python3 부재·타임아웃)"
          if [[ "$_R3_VERDICT" != OK* ]]; then
            _r3_block "F-AC-2" "🔒 [F-AC-2] state=${_R3_ST} — 승인 마커 범위 검사 불통과: ${_R3_VERDICT#NG }. 마커(${_R3_MK})의 ac_ids·fields 안에서만 편집할 수 있습니다."
          fi
          # 단일 사용: 마커 소비(이동) + 기록. 소비 실패 시 재사용 위험 → 차단(fail-closed)
          _R3_CONS="${_R3_SD}/plans/ac_edit_approval_consumed_$(date +%s)_$$.json"
          if ! mv -f "$_R3_MK" "$_R3_CONS" 2>/dev/null; then
            _r3_block "F-AC-2" "🔒 [F-AC-2] 승인 마커 소비(이동)에 실패해 단일 사용을 보장할 수 없어 차단합니다: ${_R3_MK}"
          fi
          mkdir -p "${_R3_SD}/logs" 2>/dev/null || true
          jq -cn --arg ts "$(date -Iseconds)" --arg tool "$TOOL_NAME" --arg ac "$_R3_AC_T" --arg st "$_R3_ST" \
                 --arg changed "${_R3_VERDICT#OK }" --arg consumed "$_R3_CONS" \
                 --slurpfile marker "$_R3_CONS" \
                 '{ts:$ts, tool:$tool, ac:$ac, state:$st, changed:$changed, consumed_marker:$consumed, marker:($marker[0] // null)}' \
                 >> "${_R3_SD}/logs/ac_edit_approvals.jsonl" 2>/dev/null || true
        fi
      fi
    fi
    # F-AC-2(b) bash: TEST 이후 원본 경로 + 쓰기 동사 → 승인 무관 차단 (python3 단독 = 읽기, 통과)
    if [[ -n "$_R3_CMD" ]] && printf '%s' "$_R3_CMD" | grep -qP 'session-env/[^ ]*acceptance_criteria\.json'; then
      _R3_BU=$(printf '%s' "$_R3_CMD" | grep -oP 'session-env/\K[^/\s"'"'"']+(?=/(plans/)?acceptance_criteria\.json)' | head -1)
      if _r3_is_self "$_R3_BU"; then
        _R3_BSD=$(printf '%s' "$_R3_CMD" | grep -oP '[^\s"'"'"'=]*session-env/'"${_R3_BU}" | head -1)
        _R3_BST=$(_r3_state_of "${_R3_BSD:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${_R3_BU}}")
        if [[ "$_R3_BST" == "TEST" || "$_R3_BST" == "DONE" || "$_R3_BST" == "FINISH" ]]; then
          if printf '%s' "$_R3_CMD" | grep -qP "(>>?\s*[\"']?[^\s;|&\"']*acceptance_criteria\.json|\bsed\b(?=[^;|&]*\s-i)[^;|&]*acceptance_criteria\.json|\btee\b[^;|&]*acceptance_criteria\.json|\b(cp|mv|install|rsync|ln)\b[^;|&]*\s[\"']?[^\s;|&\"']*acceptance_criteria\.json[\"']?\s*($|[;|&])|\bmv\b[^;|&]*acceptance_criteria\.json[\"']?\s|\b(rm|truncate|unlink|shred)\b[^;|&]*acceptance_criteria\.json|\bjq\b[^;|&]*(\s-i\b|--in-place)[^;|&]*acceptance_criteria\.json)" \
             || _r3_py_write "$_R3_CMD"; then
            _r3_block "F-AC-2" "🔒 [F-AC-2/bash] state=${_R3_BST} — TEST 이후 셸 명령(리다이렉트·sed -i·tee·cp/mv 목적지·rm·truncate·jq -i·python 쓰기)으로 acceptance_criteria.json 원본을 바꿀 수 없습니다(승인 마커와 무관). 읽기 전용 python3 실행과 새 사본 생성(cp 원본 → acceptance_criteria_<식별자>.json)은 허용됩니다."
          fi
        fi
      fi
    fi

    # ── Hd3: bash_exec 로 자기 세션 state 를 직접 쓰는 경로 — 역전이 관찰(pre) + DONE 마커 검사 ──
    #   mcp__oio__session_state 를 거치지 않는 DONE(bash echo DONE > state, state_write/state_transition 호출)은
    #   done_gate hook 을 건너뛴다(우회경로 #1). 같은 판정을 done_gate 의 DONE_GATE_MODE=marker 로 재사용한다.
    #   reroute_observe 는 직접 쓰기(리다이렉트·tee·sed -i·cp·mv)에만 호출한다 — state_write/state_transition
    #   함수 경유는 lib/state_machine.sh 안에서 이미 관찰한다(ohook-2 Hb2, 이중 기록 방지).
    if [[ -n "$_R3_CMD" ]] && printf '%s' "$_R3_CMD" | grep -qP 'session-env/[^/\s"'"'"']+/state\b'; then
      _R3_SU=$(printf '%s' "$_R3_CMD" | grep -oP 'session-env/\K[^/\s"'"'"']+(?=/state\b)' | head -1)
      _R3_DIRECT=0; _R3_FUNC=0; _R3_TO=""
      if printf '%s' "$_R3_CMD" | grep -qP "(>>?\s*[\"']?[^|&<;]*session-env/[^/]+/state\b(?!\.)|\btee\s+[^|;&]*session-env/[^/]+/state\b(?!\.)|\bsed\s+[^|;&]*-i[^|;&]*session-env/[^/]+/state\b(?!\.)|\b(cp|mv)\s+[^|;&]*session-env/[^/]+/state[\"']?\s*($|[;|&]))"; then
        _R3_DIRECT=1
      fi
      if printf '%s' "$_R3_CMD" | grep -qP '\b(state_write|state_transition)\b'; then
        _R3_FUNC=1
      fi
      # python 쓰기(open w/a·write_text 등)도 직접 쓰기로 본다 (ohook-4 bypass C1c)
      [[ "$_R3_DIRECT" == "0" ]] && _r3_py_write "$_R3_CMD" && _R3_DIRECT=1
      # 변수 경유 리다이렉트(F=<SD>/state; echo DONE > $F) 등 — 쓰기 흔적 + DONE 토큰이면 마커 검사 대상 (C1b)
      _R3_DONE_HINT=0
      if printf '%s' "$_R3_CMD" | grep -qP '\bDONE\b' \
         && printf '%s' "$_R3_CMD" | grep -qP '(>|\btee\b|\bsed\b[^|;&]*-i|\b(cp|mv|install|dd)\b|\bpython3?\b|\bperl\b|\bprintf\b|\becho\b)'; then
        _R3_DONE_HINT=1
      fi
      if [[ "$_R3_DIRECT" == "1" || "$_R3_FUNC" == "1" || "$_R3_DONE_HINT" == "1" ]] && _r3_is_self "$_R3_SU"; then
        _R3_STOK='IDLE|PLAN|DEV|TEST|DONE|FINISH|EARLY_TERM|ERROR'
        if [[ "$_R3_FUNC" == "1" ]]; then
          _R3_TO=$(printf '%s' "$_R3_CMD" | grep -oP "\bstate_transition\s+\S+\s+[\"']?(${_R3_STOK})[\"']?\s+[\"']?\K(${_R3_STOK})\b" | tail -1)
          [[ -z "$_R3_TO" ]] && _R3_TO=$(printf '%s' "$_R3_CMD" | grep -oP "\bstate_write\s+\S+\s+[\"']?\K(${_R3_STOK})\b" | tail -1)
        fi
        # cp/mv 원본 파일의 첫 토큰 (C1d: cp /tmp/done.txt <SD>/state — 값이 명령 문자열에 없음)
        if [[ -z "$_R3_TO" ]]; then
          _R3_CPSRC=$(printf '%s' "$_R3_CMD" | grep -oP "\b(cp|mv)\b(\s+-\S+)*\s+[\"']?\K[^\s\"';|&]+(?=[\"']?\s+[\"']?[^\s;|&]*session-env/${_R3_SU}/state\b)" | head -1)
          if [[ -n "$_R3_CPSRC" && -f "$_R3_CPSRC" && -r "$_R3_CPSRC" ]]; then
            _R3_TO=$(awk 'NR==1{print $1; exit}' "$_R3_CPSRC" 2>/dev/null | grep -oP "^(${_R3_STOK})$" || true)
          fi
        fi
        if [[ -z "$_R3_TO" && "$_R3_DIRECT" == "1" ]]; then
          if printf '%s' "$_R3_CMD" | grep -qP '\bsed\b[^|;&]*-i'; then
            _R3_TO=$(printf '%s' "$_R3_CMD" | grep -oP "s([/|#])[^/|#]*\1\K(${_R3_STOK})\b" | tail -1)
          else
            _R3_TO=$(printf '%s' "$_R3_CMD" | grep -oP "\b(${_R3_STOK})\b" | head -1)
          fi
        fi
        _R3_SSD="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${_R3_SU}"
        [[ ! -d "$_R3_SSD" && -d "$HOME/.claude/session-env/${_R3_SU}" ]] && _R3_SSD="$HOME/.claude/session-env/${_R3_SU}"
        # (1) 역전이 관찰 — 직접 쓰기만, 실패해도 무시(관찰은 차단 사유가 아니다)
        if [[ "$_R3_DIRECT" == "1" && -n "$_R3_TO" && -r "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/reroute_record.sh" ]]; then
          _R3_FROM=$(_r3_state_of "$_R3_SSD")
          if [[ -n "$_R3_FROM" && "$_R3_FROM" != "$_R3_TO" ]]; then
            timeout 3 bash -c 'source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/reroute_record.sh" 2>/dev/null && declare -F reroute_observe >/dev/null 2>&1 && reroute_observe "$1" "$2" "$3" bash_pre "write_guard bash 직접 state 쓰기"' \
              _ "$_R3_SSD" "$_R3_FROM" "$_R3_TO" >/dev/null 2>&1 || true
          fi
        fi
        # (2) DONE 쓰기 → done_gate 마커 검사 재사용(단일 출처)
        #     새 값을 특정하지 못했더라도 쓰기 흔적 + DONE 토큰이 있으면 DONE 쓰기로 간주한다(오탐 비용 = 마커 무효일 때만 차단).
        _R3_CHK="$_R3_TO"
        [[ -z "$_R3_CHK" && "$_R3_DONE_HINT" == "1" ]] && _R3_CHK="DONE"
        if [[ "$_R3_CHK" == "DONE" && -r "${HARNESS_HOME:-$HOME/.harness}/current/hooks/PreToolUse_done_gate.sh" ]]; then
          _R3_DG_RC=0
          _R3_DG_OUT=$(jq -cn --arg s "$_R3_SU" '{session_id:$s, tool_name:"mcp__oio__session_state", tool_input:{key:"state", value:"DONE"}}' 2>/dev/null \
            | env -u PIPELINE_UUID DONE_GATE_MODE=marker timeout 10 bash "${HARNESS_HOME:-$HOME/.harness}/current/hooks/PreToolUse_done_gate.sh" 2>/dev/null) || _R3_DG_RC=$?
          # [사이클182 반복1 A3] done_gate 가 시간 초과(124)·강제 종료(137)면 종전에는 rc≠2 라 통과했다
          #   (실측: done_gate 12초 지연 → rc=0, 대조 rc=2 [Hd3]). 판정불가로 기록하고 판정을 계속한다 —
          #   뒤에 확정 차단이 없으면 EXIT trap(_wg_lkg_undet_exit)이 판정불가로 차단한다(거짓 '확정' 문구 없음).
          if [[ "$_R3_DG_RC" -eq 124 || "$_R3_DG_RC" -eq 137 ]]; then
            _DG_UNDET="rc=${_R3_DG_RC}"
          fi
          if [[ "$_R3_DG_RC" -eq 2 ]]; then
            _R3_DG_R=$(printf '%s' "$_R3_DG_OUT" | jq -r '.reason // empty' 2>/dev/null)
            _r3_block "DONE-BASH" "⛔ [Hd3] bash 로 state=DONE 을 직접 쓰는 경로도 done_gate 와 같은 마커 검사를 받습니다.
${_R3_DG_R:-필수 증거 마커 미충족}"
          fi
        fi
      fi
    fi
    # ═══ [r3 ohook-3] 끝 — 이하 기존 분기 무변경 ═══

    # --- F-GOAL-1: goal.json locked=true 물리 보호 (자기 세션 격리 §(a) 준수) ---
    # 대상: 자기 UUID의 session-env/${UUID}/goal.json 만. 다른 세션/경로 영향 0.
    # locked=true 일 때 수정/삭제/이동 시도를 물리 차단. locked=false/부재 시 무영향.
    #
    # ─────────────────────────────────────────────────────────────────────
    # [c41-odev4] 2건 동시 반영
    #
    # (A) ★현존 구멍 차단★ — 종전 안쪽 case 에 mcp__oio__bash_exec 가 빠져 있었다.
    #     실측(2026-08-26): locked=true 인데 `sed -i` / `rm -f` 가 ★rc=0 통과★ 했다
    #     (같은 조건에서 file_edit 은 rc=2 차단 — 양성 통제). 계약 문서가 셸로는 무방비였다.
    #     ⇒ bash_exec 는 명령 문자열에 goal.json 경로 + 쓰기성 동사가 함께 있으면 차단한다.
    #
    # (B) ★의도 무구분 해소★ — 종전에는 "이행완료 unlock" 과 "계약 변조" 를 구분하지 못해
    #     ofinish Step 3c(copy→unlock→delete)의 정당한 unlock 까지 막혔다.
    #     ⇒ 아래 ★3조건 AND★ 를 모두 만족할 때만 unlock 을 허용한다:
    #        ① 같은 디렉토리에 goal_{goal_id}_completed.json 사본 존재 (copy 선행 실증)
    #        ② state == FINISH                                        (종료 시점 한정)
    #        ③ edit 이 locked:true→false ★단일 필드★ 변경           (내용 검증 — 핵심)
    #     ③이 "unlock 을 빌미로 acceptance 를 함께 고치는 우회" 를 막는다.
    #
    # ★못 잡는 것 (게이트 자기 사각지대 — 사이클40 A2 교훈)★
    #   1. bash_exec 판정은 ★명령 문자열 매칭★ 이다. 변수 치환($G)·따옴표 분할·base64·
    #      python -c 로 경로를 조립하면 문자열에 goal.json 이 안 보여 통과한다.
    #      ⇒ 정면 우회는 막지만 ★작정한 우회는 못 막는다★ (그건 F-GOAL-1 의 범위 밖).
    #   2. 사본(①)은 존재 + ★내용 동일(cmp)★ 까지 본다. 다만 ★같은 계약을 두 번 unlock★
    #      하는 것은 막지 못한다(사본이 원본과 같으면 몇 번이든 통과). state=FINISH 와
    #      묶여 있어 실사용상 문제는 없으나, ①은 "보관했다" 의 증명이지 "1회성" 보장은 아니다.
    #   3. ③은 jq 로 두 JSON 을 비교한다. jq 부재 시 ★차단 유지★(fail-closed) — 안전 측.
    #   4. 타 세션 goal.json 은 애초에 검사 대상이 아니다(§(a) 격리) — 보호도 안 된다.
    #   5. 자기 세션이라도 CLAUDE_CONFIG_DIR 밖 경로에 둔 goal.json 은 대상 밖이다.
    # ─────────────────────────────────────────────────────────────────────

    # ─────────────────────────────────────────────────────────────────────
    # [사이클182 K0/R1] 자기 세션 판별 후보 확장 — 팀원 잠금 빈틈 차단
    #   종전: .session_id 만(비었을 때만 PIPELINE_UUID). 팀원은 hook session_id 가 ★팀원 자신의 UUID★ 라
    #         메인 goal.json 경로와 달라 검사를 건너뛰었다(탐침 rc=0). PIPELINE_UUID env 는 hook 자식에
    #         전달되지 않는다(F-COMMIT-1·Fix 1 실측 주석) → env 만으로는 실제 팀원 경로가 그대로 열려 있었다.
    #   현재: 후보 = {hook session_id, 조상 argv --parent-session-id(F-ISO-3·_askq_self_cands 와 같은 근거),
    #         PIPELINE_UUID env(보조)}. 후보가 전부 비면 대상 경로의 UUID 를 자기 세션으로 간주(fail-closed).
    #   메인 판정: 대상 UUID == hook session_id(비었으면 PIPELINE_UUID) 일 때만 "메인". 조상 argv·env 로만
    #         일치한 경우(=팀원)는 unlock·덧붙이기 예외를 받지 못한다 → 팀원은 잠긴 계약을 고칠 수 없다.
    #   성질: 차단만 늘린다(쓰기 없음) — 세션 격리 §(a) 와 충돌하지 않는다.
    # ─────────────────────────────────────────────────────────────────────
    _g1_cands() {  # 한 줄에 하나 — hook session_id · 조상 argv --parent-session-id · PIPELINE_UUID
      local _s _p=$$ _i=0 _a _m
      _wg_pre _s "$_WG_SID" '.session_id // empty'   # c205 D-9
      [[ -n "$_s" ]] && printf '%s\n' "$_s"
      while [[ -n "$_p" && "$_p" != "1" && $_i -lt 12 ]]; do
        _a=$(tr '\0' ' ' 2>/dev/null < "/proc/${_p}/cmdline")
        _m=$(printf '%s' "$_a" | grep -oP -- '--parent-session-id[ =]\K[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
        [[ -n "$_m" ]] && { printf '%s\n' "$_m"; break; }
        _p=$(awk '/^PPid:/{print $2}' "/proc/${_p}/status" 2>/dev/null); _i=$((_i + 1))
      done
      [[ -n "${PIPELINE_UUID:-}" ]] && printf '%s\n' "$PIPELINE_UUID"
      return 0
    }
    _g1_goal_files() {  # $1=UUID → 그 세션 goal.json 경로 2형태(CLAUDE_CONFIG_DIR·$HOME/.claude)
      printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/$1/goal.json" "$HOME/.claude/session-env/$1/goal.json"
    }
    _g1_same() { [[ "$(realpath -m -- "$1" 2>/dev/null || printf '%s' "$1")" == "$(realpath -m -- "$2" 2>/dev/null || printf '%s' "$2")" ]]; }
    # [guard-deadlock D-5] goal.json 경로가 든 셸 명령이 읽기 전용 명령만으로 이루어졌는지 판정한다.
    #   F-GOAL-1/bash 는 쓰기 동사를 문자열 어디서나 찾으므로 `ls .../a-mv-b/.../goal.json`·`grep -c rm goal.json`·`ls goal.json; echo rm` 까지 막았다.
    #   반환 0 은 "구분자로 나눈 모든 조각의 첫 단어가 읽기 전용 목록 안이고, 치환·파일 리다이렉트가 없다" 일 때뿐이다. 그 밖은 전부 1(종전 문자열 판정).
    #   따옴표를 해석하지 않고 구분자를 모두 나눈다 — 잘못 나눠도 판정 대상만 늘어 종전 판정으로 떨어진다.
    _g1_bash_readonly() {
      local _c="$1" _seg _w
      case "$_c" in *'$('*|*'`'*|*'<('*|*'>('*|*'<<'*) return 1 ;; esac
      _c=${_c//2>\/dev\/null/}; _c=${_c//>\/dev\/null/}; _c=${_c//2>&1/}
      case "$_c" in *'>'*) return 1 ;; esac
      _c=${_c//;/$'\n'}; _c=${_c//&/$'\n'}; _c=${_c//|/$'\n'}
      while IFS= read -r _seg; do
        read -r _w _ <<<"$_seg"
        [[ -n "$_w" ]] || continue
        case "$_w" in ls|cat|grep|wc|md5sum|sha256sum|stat|test|head|tail|echo) ;; *) return 1 ;; esac
      done <<<"$_c"
      return 0
    }
    # [guard-deadlock D4·D-9] file_copy 가 자기 세션 두 base 사이의 같은 상대경로 복사인지 판정한다.
    #   성공(0) 시 _GF_SRC·_GF_DST(realpath)·_GF_REL 을 채운다. 별칭이 둘 이상이고 값이 다르면 실제 대상이 불확실하므로 실패한다.
    #   세션 id 가 UUID 형식이 아니거나, 두 경로가 같은 파일로 풀리거나, 심링크·.. 로 다른 세션을 가리키면 실패한다.
    _gf_copy_pair() {
      local _sid _s _d _b _x _sr _dr _srel="" _drel="" _sbase="" _dbase=""
      _GF_SRC=""; _GF_DST=""; _GF_REL=""
      _sid=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
      [[ "$_sid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || return 1
      _s=$(echo "$INPUT" | jq -r '[.tool_input | .source, .src, .path] | map(select(type == "string" and . != "")) | unique | if length == 1 then .[0] else empty end' 2>/dev/null || echo "")
      _d=$(echo "$INPUT" | jq -r '[.tool_input | .destination, .dest, .dst, .target, .to, .new_path] | map(select(type == "string" and . != "")) | unique | if length == 1 then .[0] else empty end' 2>/dev/null || echo "")
      [[ "$_s" == /* && "$_d" == /* ]] || return 1
      _sr=$(realpath -m -- "$_s" 2>/dev/null) || return 1
      _dr=$(realpath -m -- "$_d" 2>/dev/null) || return 1
      [[ "$_sr" != "$_dr" ]] || return 1
      for _b in "${CLAUDE_CONFIG_DIR:-}" "$HOME/.claude"; do
        [[ -n "$_b" ]] || continue
        for _x in "$_b" "$(realpath -m -- "$_b" 2>/dev/null || echo "$_b")"; do
          if [[ -z "$_srel" && "$_sr" == "${_x}/session-env/${_sid}/"* ]]; then _srel="${_sr#"${_x}/session-env/${_sid}/"}"; _sbase="$_x"; fi
          if [[ -z "$_drel" && "$_dr" == "${_x}/session-env/${_sid}/"* ]]; then _drel="${_dr#"${_x}/session-env/${_sid}/"}"; _dbase="$_x"; fi
        done
      done
      [[ -n "$_srel" && "$_srel" == "$_drel" && "$_sbase" != "$_dbase" ]] || return 1
      _GF_SRC="$_sr"; _GF_DST="$_dr"; _GF_REL="$_srel"
      return 0
    }
    # [guard-deadlock D-9] 잠긴 goal.json 두 벌의 복사 허용 판정 — "OK" 또는 "NG <사유>" 를 출력한다. $1=원본 $2=대상.
    #   허용: 같은 goal_id·둘 다 locked=true·대상 acceptance 가 원본 acceptance 의 앞부분(항목별 tojson 일치)·그 밖의 필드 동일.
    #   원본에서 늘어난 항목은 goal_append 와 같은 규칙(open·blocked* 없음·auto_script 있음·depends_on 은 앞선 id·valid_after null/odone)을 만족해야 한다.
    #   앞부분 조건 때문에 복사 뒤에도 대상의 기존 항목은 한 글자도 바뀌거나 사라지지 않는다.
    _g1_sync_judge() {
      timeout 3 jq -rn --slurpfile s "$1" --slurpfile d "$2" '
        if ($s|length)!=1 or ($d|length)!=1 then "NG 원본·대상이 JSON 문서 1개가 아니다" else
        $s[0] as $a | $d[0] as $b |
        if ($a|type)!="object" or ($b|type)!="object" then "NG 최상위가 객체가 아니다"
        elif $a.locked!=true or $b.locked!=true then "NG 둘 다 locked=true 가 아니다"
        elif ($a.goal_id|type)!="string" or ($a.goal_id|length)==0 or $a.goal_id!=$b.goal_id then "NG goal_id 가 다르다"
        elif ($a.acceptance|type)!="array" or ($b.acceptance|type)!="array" then "NG acceptance 가 배열이 아니다"
        elif ($b.acceptance|length)>($a.acceptance|length) then "NG 대상 acceptance 가 원본보다 길다(계약 축소 방향)"
        elif ($a.acceptance[0:($b.acceptance|length)]|map(tojson))!=($b.acceptance|map(tojson)) then "NG 대상 acceptance 가 원본의 앞부분이 아니다"
        elif ($a|del(.acceptance)|tojson)!=($b|del(.acceptance)|tojson) then "NG acceptance 밖 필드가 다르다"
        else
          reduce ($a.acceptance[($b.acceptance|length):][]) as $x ({seen:($b.acceptance|map(.id?|strings)),why:""};
            if .why!="" then .
            elif ($x|type)!="object" then .why="새 항목이 객체가 아니다"
            elif ($x.id|type)!="string" or ($x.id|test("^\\s*$")) then .why="새 항목 id 가 없다"
            elif (.seen|index($x.id))!=null then .why="새 항목 id 중복"
            elif ($x|has("status")) and $x.status!="open" then .why="새 항목 status 는 open 만 허용"
            elif ($x|keys|map(select(startswith("blocked")))|length)>0 then .why="새 항목에 blocked 필드"
            elif ($x.auto_script|type)!="string" or ($x.auto_script|test("^\\s*$")) then .why="새 항목 auto_script 가 비었다"
            elif (($x.depends_on//[])|type)!="array" then .why="새 항목 depends_on 이 배열이 아니다"
            elif ((($x.depends_on//[])-.seen)|length)>0 then .why="새 항목 depends_on 이 앞선 id 가 아니다"
            elif ($x.valid_after!=null and $x.valid_after!="odone") then .why="새 항목 valid_after 는 null 또는 odone 만 허용"
            else .seen+=[$x.id] end)
          | if .why=="" then "OK" else "NG "+.why end
        end end' 2>/dev/null || echo "NG 판정 실패(JSON 오류·시간 초과·jq 부재)"
    }
    # 아래 판정 결과를 활성 상태 메인 차단의 좁은 예외(_gf_main_session_exempt)가 읽는다. 환경에서 물려받지 않도록 먼저 비운다.
    _APPEND_OK=0; _G1_SYNC_OK=0; _G1_SYNC_WHY=""
    _G1_CANDS=$(_g1_cands | awk 'NF && !seen[$0]++')
    _wg_pre _G1_MAIN "$_WG_SID" '.session_id // empty'   # c205 D-9
    [[ -z "$_G1_MAIN" && -n "${PIPELINE_UUID:-}" ]] && _G1_MAIN="$PIPELINE_UUID"

    # (A) bash_exec 경유 goal.json 쓰기/삭제 차단 — 안쪽 case 진입 전에 선처리한다.
    #   [사이클182] 후보 전부 + 명령에 적힌 리터럴 UUID 의 goal.json 중 하나라도 잠겨 있으면 차단(차단만 늘림).
    if [[ "$TOOL_NAME" == "mcp__oio__bash_exec" ]]; then
      _wg_pre _BE_CMD "$_WG_CMD_OC" '.tool_input.command // .tool_input.cmd // empty'   # c205 D-9
      if echo "$_BE_CMD" | grep -qP 'session-env/[^/ ]+/goal\.json' && ! _g1_bash_readonly "$_BE_CMD"; then
        # 쓰기성 동사가 함께 있을 때만 차단 (cat/grep/jq 조회는 통과 — false positive 방지)
        if echo "$_BE_CMD" | grep -qP '(\bsed\b[^|]*-i|\brm\b|\bmv\b|\bcp\b|\btruncate\b|\btee\b|>\s*[^ |]*goal\.json|\bjq\b[^|]*(-i|--in-place)|\bpython3?\b[^|]*\bw\b)'; then
          _BE_LIT=$(printf '%s' "$_BE_CMD" | grep -oP 'session-env/\K[0-9A-Za-z_-]+(?=/goal\.json)' 2>/dev/null)
          while IFS= read -r _BE_UUID; do
            [[ -n "$_BE_UUID" ]] || continue
            while IFS= read -r _BE_GOAL; do
              if [[ -f "$_BE_GOAL" ]] && [[ "$(jq -r '.locked // false' "$_BE_GOAL" 2>/dev/null || echo false)" == "true" ]]; then
                echo '{"decision":"block","reason":"🔒 [F-GOAL-1/bash] goal.json locked=true — 셸 명령(sed/rm/mv/tee 등)으로 계약 문서를 변경·삭제할 수 없습니다. 이행완료 정리는 ofinish Step 3c 절차(copy → file_edit 로 locked만 false → delete)를 사용하세요. 잠긴 계약에 항목을 덧붙일 때는 메인 세션이 mcp__oio__file_write 로 기존 내용+새 항목을 씁니다(goal_append)."}'
                exit 2
              fi
            done <<<"$(_g1_goal_files "$_BE_UUID")"
          done <<<"$(printf '%s\n%s\n' "$_G1_CANDS" "$_BE_LIT" | awk 'NF && !seen[$0]++')"
        fi
      fi
    fi

    case "$TOOL_NAME" in
      mcp__oio__file_edit|mcp__oio__file_write|mcp__oio__file_delete|mcp__oio__file_move|mcp__oio__file_rename|mcp__oio__file_copy)
        # [사이클182] 대상 = 도구가 실제로 바꾸는 경로 전부. 종전에는 path/file_path/src 만 봐서
        #   file_copy·file_move 의 destination(덮어쓰기)·file_move 의 source·file_rename 의 새 이름이 빠져 있었다.
        #   file_copy 의 원본(읽기)은 대상이 아니다 — ofinish 3c ① 보관 copy 는 그대로 통과한다.
        _G1_TGTS=$(echo "$INPUT" | jq -r '
          .tool_name as $t | (.tool_input // {}) as $i |
          [ (if $t != "mcp__oio__file_copy" then ($i.path // $i.file_path // $i.filepath // empty) else empty end),
            (if $t == "mcp__oio__file_move" or $t == "mcp__oio__file_rename" then ($i.source // $i.src // empty) else empty end),
            (if $t == "mcp__oio__file_move" or $t == "mcp__oio__file_copy" then ($i.destination, $i.dest, $i.dst, $i.target, $i.to, $i.new_path) else empty end),
            (if $t == "mcp__oio__file_rename" and (($i.new_name // "") | length) > 0
               then (if ($i.new_name | startswith("/")) then $i.new_name
                     else ((($i.path // $i.source // $i.src // "") | sub("/[^/]*$"; "")) + "/" + $i.new_name) end) else empty end)
          ] | map(select(type == "string" and . != "")) | unique | .[]' 2>/dev/null || echo "")
        while IFS= read -r _GOAL_PATH; do
        # session-env/<uuid>/goal.json 형태만 매칭 (정확한 경로 — 와일드카드 오작동 방지)
        if [[ -n "$_GOAL_PATH" ]] && echo "$_GOAL_PATH" | grep -qP 'session-env/[^/]+/goal\.json$'; then
          # [사이클182 K0/R1] 자기 세션 판별 — 후보 중 하나의 goal.json 과 같은 경로면 자기 세션.
          #   후보가 전부 비면 대상 자체를 자기 세션으로 본다(fail-closed). 메인 여부는 _G1_MAIN 일치로만.
          _SELF_GOAL=""; _G1_IS_MAIN=0
          if [[ -z "$_G1_CANDS" ]]; then
            _SELF_GOAL="$_GOAL_PATH"
          else
            while IFS= read -r _G1_C; do
              [[ -n "$_G1_C" ]] || continue
              while IFS= read -r _G1_F; do
                if _g1_same "$_GOAL_PATH" "$_G1_F"; then
                  _SELF_GOAL="$_GOAL_PATH"
                  [[ -n "$_G1_MAIN" && "$_G1_C" == "$_G1_MAIN" ]] && _G1_IS_MAIN=1
                fi
              done <<<"$(_g1_goal_files "$_G1_C")"
            done <<<"$_G1_CANDS"
          fi
          # 대상이 "자기 세션 goal.json"일 때만 검사 (타 세션 경로는 F-ISO-3 소관 → 격리 §(a))
          if [[ -n "$_SELF_GOAL" && -f "$_SELF_GOAL" ]]; then
            _GOAL_LOCKED=$(jq -r '.locked // false' "$_SELF_GOAL" 2>/dev/null || echo "false")
            if [[ "$_GOAL_LOCKED" == "true" ]]; then
              # [c41-odev4] ★이행완료 unlock 예외 — 3조건 AND★ (file_edit 에만 적용)
              #   [사이클182] 메인 세션만 — 조상 argv·env 로만 일치한 팀원은 unlock 할 수 없다.
              _UNLOCK_OK=0; _APPEND_OK=0; _APPEND_WHY=""
              if [[ "$TOOL_NAME" == "mcp__oio__file_edit" && "$_G1_IS_MAIN" == "1" ]]; then
                _G_DIR=$(dirname "$_SELF_GOAL")
                _G_ID=$(jq -r '.goal_id // empty' "$_SELF_GOAL" 2>/dev/null || echo "")
                # ① copy 선행 실증 — goal_{goal_id}_completed.json 사본이 존재하고
                #    ★그 내용이 지금 unlock 하려는 원본과 동일해야 한다★.
                #    [c41-odev4 라이브 회귀] 존재만 보면 ★직전 사이클의 낡은 사본★ 이 남아 있을 때
                #    조건①이 공짜로 통과한다(실측: 사이클40 사본 Aug26 15:29 잔존 → rc=0 오통과).
                #    ⇒ 내용 일치까지 봐야 "이번 계약을 방금 보관했다" 가 실증된다.
                _C1=0
                if [[ -n "$_G_ID" && -f "${_G_DIR}/goal_${_G_ID}_completed.json" ]]; then
                  if cmp -s "$_SELF_GOAL" "${_G_DIR}/goal_${_G_ID}_completed.json"; then
                    _C1=1
                  fi
                fi
                # ② state == FINISH (종료 시점 한정)
                _C2=0
                _ST=$(awk '{print $1}' "${_G_DIR}/state" 2>/dev/null || echo "")
                [[ "$_ST" == "FINISH" ]] && _C2=1
                # ③ 내용 검증 — locked:true→false ★단일 필드★ 변경인가
                #    편집 결과를 메모리에서 재현해 원본과 diff. jq 부재/실패 시 fail-closed(0).
                _C3=0
                _OLD=$(echo "$INPUT" | jq -r '.tool_input.old_string // .tool_input.old // .tool_input.old_text // empty' 2>/dev/null || echo "")
                _NEW=$(echo "$INPUT" | jq -r '.tool_input.new_string // .tool_input.new // .tool_input.new_text // empty' 2>/dev/null || echo "")
                if [[ -n "$_OLD" && -n "$_NEW" ]] && command -v python3 >/dev/null 2>&1; then
                  _C3=$(OLD="$_OLD" NEW="$_NEW" GOAL="$_SELF_GOAL" timeout 3 python3 -c '
import json,os,sys
try:
    src=open(os.environ["GOAL"],encoding="utf-8").read()
    old,new=os.environ["OLD"],os.environ["NEW"]
    if src.count(old)!=1: print(0); sys.exit()
    a=json.loads(src); b=json.loads(src.replace(old,new,1))
    # locked 만 true->false 로 바뀌고 나머지 키/값은 완전 동일해야 한다
    if a.get("locked") is not True or b.get("locked") is not False: print(0); sys.exit()
    a.pop("locked",None); b.pop("locked",None)
    print(1 if a==b else 0)
except Exception: print(0)
' 2>/dev/null || echo 0)
                fi
                [[ "$_C1" == "1" && "$_C2" == "1" && "$_C3" == "1" ]] && _UNLOCK_OK=1
              fi

              # [사이클182 항목8] ★덧붙이기(append-only) 예외★ — 메인 세션의 mcp__oio__file_write 만.
              #   조건(전부): ① 새 내용이 유효 JSON 객체이고 acceptance 밖 필드(locked·goal_id·intent·created_at …)가
              #   기존과 바이트 동일(json 직렬화 비교) ② 기존 acceptance 가 새 acceptance 의 앞부분과 항목마다 바이트 동일,
              #   길이는 반드시 늘어남(수정·삭제·순서 변경·완화 0) ③ 새 항목: id 고유·status 는 open 또는 생략·blocked* 필드
              #   금지·auto_script 비어 있지 않음·depends_on 은 기존 id 와 앞선 새 id 만·valid_after 는 null/"odone"
              #   ④ state ∈ PLAN·DEV·TEST·DONE(FINISH 이후 금지) ⑤ 메인 세션(_G1_IS_MAIN) ⑥ 도구가 file_write.
              #   통과 시 logs/goal_append.log 1줄. 새 항목이 "기록 시점에 FAIL" 인지·무력 정규식·중복은 settings 에
              #   등록된 계약 검사기(PreToolUse_goal_autoscript_guard.sh F-GOALAS-8·7·3)가 같은 file_write 에서 판정한다.
              #   "새 id 로 같은 내용을 넣고 원본을 약화" 는 ② 때문에 불가(원본 한 글자도 못 바뀜).
              #   편집 도구(file_edit)·셸·copy/move 로는 "덧붙이기만" 을 증명하기 어려워 예외를 주지 않는다.
              if [[ "$_UNLOCK_OK" != "1" && "$TOOL_NAME" == "mcp__oio__file_write" ]]; then
                if [[ "$_G1_IS_MAIN" != "1" ]]; then
                  _APPEND_WHY="메인 세션이 아님(팀원·다른 세션은 잠긴 계약에 덧붙일 수 없다)"
                else
                  _G1_ST=$(awk '{print $1; exit}' "$(dirname "$_SELF_GOAL")/state" 2>/dev/null || echo "")
                  case "$_G1_ST" in
                    PLAN|DEV|TEST|DONE)
                      _APPEND_RES=$(printf '%s' "$INPUT" | GOAL="$_SELF_GOAL" timeout 5 python3 -c '
import json,os,sys
def out(m):
    print(m); sys.exit(0)
try:
    inp=json.load(sys.stdin)
    ti=inp.get("tool_input") or {}
    c=None
    for k in ("content","body","data","text","new_content","new_text"):
        if isinstance(ti.get(k),str):
            c=ti[k]; break
    if c is None: out("NG 새 내용(content)이 없다")
    old=json.load(open(os.environ["GOAL"],encoding="utf-8"))
    try:
        new=json.loads(c)
    except Exception:
        out("NG 새 내용이 유효 JSON 이 아니다")
    if not isinstance(old,dict) or not isinstance(new,dict): out("NG 최상위가 객체가 아니다")
    D=lambda x: json.dumps(x,ensure_ascii=False,separators=(",",":"))
    oa=old.get("acceptance"); na=new.get("acceptance")
    if not isinstance(oa,list) or not isinstance(na,list): out("NG acceptance 가 배열이 아니다")
    o2=dict(old); n2=dict(new); o2.pop("acceptance",None); n2.pop("acceptance",None)
    if D(o2)!=D(n2): out("NG acceptance 밖 필드(locked·goal_id·intent 등)가 바뀌었다")
    if len(na)<=len(oa): out("NG 항목 수가 늘지 않았다(삭제 또는 덧붙인 항목 없음)")
    for i,x in enumerate(oa):
        if D(x)!=D(na[i]):
            out("NG 기존 항목 %s 이 바뀌었다(수정·삭제·순서 변경 금지)" % (x.get("id") if isinstance(x,dict) else i))
    seen=set(x.get("id") for x in oa if isinstance(x,dict) and isinstance(x.get("id"),str))
    added=[]
    for x in na[len(oa):]:
        if not isinstance(x,dict): out("NG 새 항목이 객체가 아니다")
        i=x.get("id")
        if not isinstance(i,str) or not i.strip(): out("NG 새 항목 id 가 없다")
        if i in seen: out("NG 새 항목 id 중복: %s" % i)
        st=x.get("status","open")
        if st!="open": out("NG 새 항목 %s status=%s — open 만 허용(blocked 승격 금지)" % (i,st))
        bk=[k for k in x if k.startswith("blocked")]
        if bk: out("NG 새 항목 %s 에 %s 필드 — 덧붙임은 open 만" % (i,",".join(bk)))
        a=x.get("auto_script")
        if not isinstance(a,str) or not a.strip(): out("NG 새 항목 %s auto_script 가 비었다" % i)
        dep=x.get("depends_on",[])
        if dep is None: dep=[]
        if not isinstance(dep,list): out("NG 새 항목 %s depends_on 이 배열이 아니다" % i)
        for d in dep:
            if not isinstance(d,str) or d not in seen: out("NG 새 항목 %s depends_on %s 는 기존·앞선 새 id 가 아니다" % (i,d))
        if x.get("valid_after") not in (None,"odone"): out("NG 새 항목 %s valid_after=%s — null 또는 odone 만" % (i,x.get("valid_after")))
        seen.add(i); added.append(i)
    out("OK " + ",".join(added))
except SystemExit:
    raise
except Exception as e:
    out("NG 판정 오류 %s" % type(e).__name__)
' 2>/dev/null) || _APPEND_RES="NG 판정 실패(시간 초과·python 부재)"
                      if [[ "$_APPEND_RES" == OK\ * ]]; then
                        _APPEND_OK=1
                        mkdir -p "$(dirname "$_SELF_GOAL")/logs" 2>/dev/null
                        printf '%s APPEND sid=%s ids=%s state=%s\n' "$(date -Iseconds)" "$_G1_MAIN" "${_APPEND_RES#OK }" "$_G1_ST" \
                          >>"$(dirname "$_SELF_GOAL")/logs/goal_append.log" 2>/dev/null || true
                      else
                        _APPEND_WHY="${_APPEND_RES#NG }"
                        [[ -n "$_APPEND_WHY" ]] || _APPEND_WHY="판정 결과 없음(fail-closed)"
                      fi
                      ;;
                    *) _APPEND_WHY="단계 ${_G1_ST:-판독불가} — 덧붙이기는 PLAN·DEV·TEST·DONE 에서만" ;;
                  esac
                fi
              fi

              # [guard-deadlock D-9] 잠긴 goal.json 이 두 base 에서 다를 때의 복구 경로 — 메인의 mcp__oio__file_copy 만.
              #   자기 세션 두 base 간 복사이면서 _g1_sync_judge 가 OK 일 때만 연다. 대상의 기존 항목·다른 필드는 바뀔 수 없다.
              #   항목이 늘어나는 복사는 P2 정적 검사의 F-GOALAS-8 이 이 블록보다 먼저 막는다. 실제로 열리는 경우는 acceptance 가 같고 서식만 다른 복사다.
              #   통과 시 logs/goal_sync.log 1줄. 대상이 없는 복사는 이 블록에 오지 않으며 _gf_main_session_exempt 가 판정한다.
              if [[ "$TOOL_NAME" == "mcp__oio__file_copy" ]]; then
                if [[ "$_G1_IS_MAIN" != "1" || -n "${PIPELINE_UUID:-}" ]] || { declare -F _r3_is_team >/dev/null 2>&1 && _r3_is_team; }; then
                  _G1_SYNC_WHY="메인 세션이 아님"
                elif ! _gf_copy_pair || [[ "$_GF_REL" != "goal.json" ]] || ! _g1_same "$_GF_DST" "$_SELF_GOAL"; then
                  _G1_SYNC_WHY="자기 세션 두 base 사이의 goal.json 복사가 아님"
                elif [[ ! -f "$_GF_SRC" ]]; then
                  _G1_SYNC_WHY="원본이 없음"
                else
                  _G1_SYNC_RES=$(_g1_sync_judge "$_GF_SRC" "$_GF_DST")
                  if [[ "$_G1_SYNC_RES" == "OK" ]]; then
                    _G1_SYNC_OK=1
                    mkdir -p "$(dirname "$_SELF_GOAL")/logs" 2>/dev/null
                    printf '%s SYNC sid=%s src=%s dst=%s\n' "$(date -Iseconds)" "$_G1_MAIN" "$_GF_SRC" "$_GF_DST" \
                      >>"$(dirname "$_SELF_GOAL")/logs/goal_sync.log" 2>/dev/null || true
                  else
                    _G1_SYNC_WHY="${_G1_SYNC_RES#NG }"
                    [[ -n "$_G1_SYNC_WHY" ]] || _G1_SYNC_WHY="판정 결과 없음(fail-closed)"
                  fi
                fi
              fi

              # [사이클196 oi-fix-1 P5] ★완료 보관된 옛 계약 교체 예외★ — mcp__oio__file_write 만.
              #   배경(10-23 실측): c195 ofinish 3c 가 copy(goal_G-DA5802F4_completed.json 02:48)만 하고 unlock 없이 IDLE 로 넘어가
              #   잠긴 옛 계약이 남았다. c196 oplan 이 새 goal.json 을 못 써 리드가 FINISH 로 임시 전이해 unlock 했다(08:06).
              #   3c 는 단계 실패를 "경고 후 IDLE 계속"으로 두므로 이 잔존은 다시 생긴다 → 다음 사이클 입구에서 자기치유한다.
              #   조건(전부): ① 현재 goal.json 과 바이트 동일한 goal_<goal_id>_completed.json 이 있다(보관 실증)
              #   ② 그 사본의 mtime 이 이번 파이프라인 시작(pipeline_start_time)보다 이르다 — 지난 사이클에 보관된 계약이다
              #      (이번 사이클 안에서 copy 를 만들고 곧바로 덮어쓰는 우회를 막는다)
              #   ③ state == PLAN ④ 호출자 = 메인 세션 또는 이 세션 팀의 oplan 팀원(조상 argv --agent-id oplan*@<team_name>)
              #   ⑤ 새 내용은 유효 JSON 객체, goal_id 가 옛 goal_id 와 다르고 acceptance 가 비지 않은 배열.
              #   통과 시 logs/goal_archive_replace.log 1줄.
              _ARCH_OK=0; _ARCH_WHY=""
              if [[ "$_UNLOCK_OK" != "1" && "$_APPEND_OK" != "1" && "$TOOL_NAME" == "mcp__oio__file_write" ]]; then
                _A_DIR=$(dirname "$_SELF_GOAL")
                _A_ID=$(jq -r '.goal_id // empty' "$_SELF_GOAL" 2>/dev/null || echo "")
                _A_CP="${_A_DIR}/goal_${_A_ID}_completed.json"
                _A_ST=$(awk '{print $1; exit}' "${_A_DIR}/state" 2>/dev/null || echo "")
                _A_PS=$(tr -cd '0-9' < "${_A_DIR}/pipeline_start_time" 2>/dev/null)
                _A_CPM=$(stat -c %Y "$_A_CP" 2>/dev/null || echo "")
                _A_WHO=""
                if [[ "$_G1_IS_MAIN" == "1" ]]; then
                  _A_WHO="main"
                else
                  _A_P=$$; _A_I=0; _A_AG=""; _A_LD=""
                  while [[ -n "$_A_P" && "$_A_P" != "1" && $_A_I -lt 12 ]]; do
                    _A_ARGV=$(tr '\0' ' ' 2>/dev/null < "/proc/${_A_P}/cmdline")
                    _A_AG=$(printf '%s' "$_A_ARGV" | grep -oP -- '--agent-id[ =]\K[A-Za-z0-9._-]+@[A-Za-z0-9._-]+' | head -1)
                    if [[ -n "$_A_AG" ]]; then
                      _A_LD=$(printf '%s' "$_A_ARGV" | grep -oP -- '--parent-session-id[ =]\K[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
                      break
                    fi
                    _A_P=$(awk '/^PPid:/{print $2}' "/proc/${_A_P}/status" 2>/dev/null); _A_I=$((_A_I + 1))
                  done
                  if [[ "${_A_AG%%@*}" =~ ^oplan[A-Za-z0-9._-]*$ && -n "$_A_LD" && "$_A_LD" == "$(basename "$_A_DIR")" && -f "${_A_DIR}/team_name" ]] \
                     && [[ "$(tr -d '[:space:]' < "${_A_DIR}/team_name" 2>/dev/null)" == "${_A_AG#*@}" ]]; then
                    _A_WHO="oplan"
                  fi
                fi
                if [[ -z "$_A_ID" || ! -f "$_A_CP" ]]; then
                  _ARCH_WHY="완료 사본 goal_${_A_ID:-?}_completed.json 없음"
                elif ! cmp -s "$_SELF_GOAL" "$_A_CP"; then
                  _ARCH_WHY="완료 사본과 현재 goal.json 내용 다름"
                elif [[ ! "$_A_PS" =~ ^[0-9]+$ || ! "$_A_CPM" =~ ^[0-9]+$ ]] || (( _A_CPM >= _A_PS )); then
                  _ARCH_WHY="사본이 이번 파이프라인 시작 이전에 만들어진 것이 아님(또는 시작 시각 판독 불가)"
                elif _A_CA=$(jq -r '.created_at // empty' "$_SELF_GOAL" 2>/dev/null); _A_CAE=$(date -d "$_A_CA" +%s 2>/dev/null); \
                     [[ ! "$_A_CAE" =~ ^[0-9]+$ ]] || (( _A_CAE >= _A_PS )); then
                  # ⑥ 내용 기준: 옛 계약의 created_at 도 이번 파이프라인 시작 이전이어야 한다 — 사본 mtime 은 touch -d 로 되돌릴 수 있지만
                  #    잠긴 goal.json 내용(created_at)은 바꿀 수 없다(F-GOAL-1). 이번 사이클 계약을 사본+시각 위조로 교체하는 우회를 막는다.
                  _ARCH_WHY="옛 계약 created_at(${_A_CA:-없음})이 이번 파이프라인 시작 이전이 아님(또는 판독 불가)"
                elif [[ "$_A_ST" != "PLAN" ]]; then
                  _ARCH_WHY="단계 ${_A_ST:-판독불가} — 옛 계약 교체는 PLAN 에서만"
                elif [[ -z "$_A_WHO" ]]; then
                  _ARCH_WHY="호출자가 메인도 이 세션 팀의 oplan 팀원도 아님"
                else
                  _A_RES=$(printf '%s' "$INPUT" | OLDID="$_A_ID" timeout 5 python3 -c '
import json,os,sys
try:
    ti=(json.load(sys.stdin).get("tool_input") or {})
    c=next((ti[k] for k in ("content","body","data","text","new_content","new_text") if isinstance(ti.get(k),str)),None)
    n=json.loads(c) if c is not None else None
    if not isinstance(n,dict): print("NG 새 내용이 JSON 객체가 아니다"); sys.exit()
    g=n.get("goal_id")
    if not isinstance(g,str) or not g.strip(): print("NG 새 goal_id 없음"); sys.exit()
    if g==os.environ["OLDID"]: print("NG 새 goal_id 가 옛 계약과 같다"); sys.exit()
    a=n.get("acceptance")
    if not isinstance(a,list) or not a: print("NG 새 acceptance 가 비었다"); sys.exit()
    print("OK "+g)
except Exception as e:
    print("NG 판정 오류 %s" % type(e).__name__)
' 2>/dev/null) || _A_RES="NG 판정 실패(시간 초과·python 부재)"
                  if [[ "$_A_RES" == OK\ * ]]; then
                    _ARCH_OK=1
                    mkdir -p "${_A_DIR}/logs" 2>/dev/null
                    printf '%s ARCHIVE_REPLACE who=%s old=%s new=%s copy_mtime=%s pipeline_start=%s\n' "$(date -Iseconds)" "$_A_WHO" "$_A_ID" "${_A_RES#OK }" "$_A_CPM" "$_A_PS" \
                      >>"${_A_DIR}/logs/goal_archive_replace.log" 2>/dev/null || true
                  else
                    _ARCH_WHY="${_A_RES#NG }"
                  fi
                fi
              fi

              if [[ "$_UNLOCK_OK" != "1" && "$_APPEND_OK" != "1" && "$_ARCH_OK" != "1" && "$_G1_SYNC_OK" != "1" ]]; then
                _G1_MSG="🔒 [F-GOAL-1] goal.json locked=true — 파이프라인 계약 문서는 잠금 상태입니다. 이행완료 정리라면 ofinish Step 3c 순서를 지키세요: ① goal_{goal_id}_completed.json 로 copy ② state=FINISH ③ locked 필드만 true→false 로 file_edit. 세 조건이 모두 충족될 때만 unlock 이 허용됩니다(다른 필드를 함께 바꾸면 차단됩니다). 항목 추가는 메인 세션이 mcp__oio__file_write 로 '기존 내용 그대로 + 끝에 open 새 항목' 만 쓸 수 있습니다(goal_append — 기존 항목 수정·삭제·blocked 승격·unlock 동반 금지). 팀원·move/rename 덮어쓰기는 예외가 없고, copy 덮어쓰기는 메인이 자기 세션 두 base 사이에서 계약 내용이 같은 두 벌을 맞출 때만 허용됩니다."
                [[ -n "$_APPEND_WHY" ]] && _G1_MSG="${_G1_MSG} 덧붙이기 불인정 사유: ${_APPEND_WHY}"
                [[ -n "$_G1_SYNC_WHY" ]] && _G1_MSG="${_G1_MSG} 두 base 동기화 불인정 사유: ${_G1_SYNC_WHY}"
                [[ -n "$_ARCH_WHY" ]] && _G1_MSG="${_G1_MSG} 옛 계약 교체 불인정 사유: ${_ARCH_WHY}. 해소: 지난 사이클에 보관(goal_<id>_completed.json, 내용 동일)된 계약이면 PLAN 에서 메인 또는 oplan 팀원이 새 goal_id 의 계약을 file_write 로 쓰면 통과한다. 보관이 안 됐으면 ofinish 3c(copy → state=FINISH → locked 만 false)를 먼저 끝낸다."
                jq -cn --arg r "$_G1_MSG" '{decision:"block",reason:$r}' 2>/dev/null \
                  || echo '{"decision":"block","reason":"🔒 [F-GOAL-1] goal.json locked=true — 잠긴 계약 문서는 바꿀 수 없습니다."}'
                exit 2
              fi
            fi
          fi
        fi
        done <<<"$_G1_TGTS"
        ;;
    esac
    unset -f _g1_cands _g1_goal_files _g1_same _g1_bash_readonly _g1_sync_judge
    # --- F-GOAL-1 끝 ---

    # --- F-OTO-9 (사이클182 항목8): oto(auto=ON) 세션은 다음 사이클 인계 금지 — next_action.json 은 blocked_only 만 ---
    # 배경: 사용자 지시 "oto모드일땐 모든 작업을 이번 사이클에서 마무리하고 다음 사이클로 넘기는 작업이 없도록 하라".
    #   종전 F-OTO-2 는 next_action.json 이 있으면 open FAIL 을 남긴 채 IDLE 을 통과시켰다(인계 = 통과).
    # 규칙: 대상 세션(경로의 session-env/<U>/)에 auto=ON 이면, 그 세션 next_action.json 에 들어갈 내용이
    #   {handoff_kind:"blocked_only", blocked_ids:[…]} 이고 blocked_ids 가 전부 그 세션 goal.json 의
    #   status blocked·blocked_by 항목 id 일 때만 허용한다(스키마 = ofinish Step 3.5·oto/SKILL.md).
    #   파일 도구: write(내용)·edit(적용 후 내용 모사)·copy/move/rename(원본 내용). 셸: next_action.json 이
    #   쓰기 대상(리다이렉트·tee·sed -i·cp/mv/install/ln/rsync 의 마지막 인자·touch·truncate·dd of=·python 쓰기)이면
    #   내용을 증명할 수 없으므로 auto=ON 세션에서는 차단한다. 원본 자리(ofinish 소비 이동 mv 원본)는 통과.
    #   auto=OFF·auto 부재 세션은 무영향(일반 파이프라인 autoloop 그대로). 같은 규칙을 완주 가드(F-OTO-9)가 IDLE 전이에서도 본다.
    _oto9_block() {
      jq -cn --arg r "🚫 [F-OTO-9] oto(auto=ON) 세션은 다음 사이클 인계를 쓸 수 없습니다 — $1. open FAIL·판정불가는 이번 사이클 안에서 FINISH→DEV 재진입으로 끝내고, 상한(max_iterations)·EARLY_TERM 에 닿았을 때만 oto_incomplete.json({fail_ids, reason, iteration, max_iterations, detail})으로 '미완료'를 정직하게 보고하십시오. next_action.json 은 blocked_only 또는 carryover 인계에만 씁니다(blocked_only={\"handoff_kind\":\"blocked_only\",\"blocked_ids\":[goal 의 blocked·blocked_by id]}, carryover={\"handoff_kind\":\"carryover\",\"slash_command\":\"/oto\",\"task_description\":…,\"carry_ids\":[goal 의 id],\"chain_root\":…})." \
        '{decision:"block",reason:$r}' 2>/dev/null || echo '{"decision":"block","reason":"🚫 [F-OTO-9] oto 세션 다음 사이클 인계 금지 — next_action.json 은 blocked_only 만"}'
      exit 2
    }
    _oto9_auto_on() {  # $1=세션 디렉터리 → auto=ON 이면 0
      [[ -f "$1/auto" ]] && [[ "$(tr -d '[:space:]' < "$1/auto" 2>/dev/null)" == "ON" ]]
    }
    _oto9_check() {  # stdin=next_action 내용, $1=goal.json → "OK" 또는 "NG 사유"
      GOAL="$1" timeout 5 python3 -c '
import json,os,sys
def out(m):
    print(m); sys.exit(0)
try:
    try:
        na=json.loads(sys.stdin.read())
    except Exception:
        out("NG next_action 내용이 유효 JSON 이 아니다")
    if not isinstance(na,dict): out("NG next_action 이 객체가 아니다")
    if na.get("handoff_kind")=="carryover":
        if na.get("slash_command")!="/oto": out("NG carryover 의 slash_command 는 /oto 여야 한다")
        td=na.get("task_description")
        if not isinstance(td,str) or not td.strip(): out("NG carryover 의 task_description 이 비었다")
        cr=na.get("chain_root")
        if not isinstance(cr,str) or not cr.strip(): out("NG carryover 의 chain_root 가 비었다")
        ci=na.get("carry_ids")
        if not isinstance(ci,list) or not ci or not all(isinstance(x,str) and x for x in ci): out("NG carry_ids 가 비었거나 형식 오류")
        try:
            g=json.load(open(os.environ["GOAL"],encoding="utf-8"))
        except Exception:
            out("NG 그 세션 goal.json 을 읽을 수 없어 carry_ids 를 검증할 수 없다")
        st=dict((a.get("id"),a.get("status")) for a in (g.get("acceptance") or []) if isinstance(a,dict))
        bad=[x for x in ci if x not in st or st[x] in ("blocked","blocked_by")]
        if bad: out("NG carry_ids %s 는 goal 에 없거나 blocked 항목이다" % ",".join(bad))
        out("OK")
    if na.get("handoff_kind")!="blocked_only": out("NG handoff_kind 가 blocked_only 도 carryover 도 아니다(open 작업 인계)")
    b=na.get("blocked_ids")
    if not isinstance(b,list) or not b or not all(isinstance(x,str) and x for x in b): out("NG blocked_ids 가 비었거나 형식 오류")
    try:
        g=json.load(open(os.environ["GOAL"],encoding="utf-8"))
    except Exception:
        out("NG 그 세션 goal.json 을 읽을 수 없어 blocked_ids 를 검증할 수 없다")
    ok=set(a.get("id") for a in (g.get("acceptance") or []) if isinstance(a,dict) and a.get("status") in ("blocked","blocked_by"))
    bad=[x for x in b if x not in ok]
    if bad: out("NG blocked_ids %s 는 goal 의 blocked·blocked_by 항목이 아니다" % ",".join(bad))
    out("OK")
except SystemExit:
    raise
except Exception as e:
    out("NG 판정 오류 %s" % type(e).__name__)
' 2>/dev/null || echo "NG 판정 실패(시간 초과·python 부재)"
    }
    case "$TOOL_NAME" in
      mcp__oio__file_write|mcp__oio__file_edit|mcp__oio__file_copy|mcp__oio__file_move|mcp__oio__file_rename)
        _O9_DST=$(echo "$INPUT" | jq -r '
          .tool_name as $t | (.tool_input // {}) as $i |
          if $t == "mcp__oio__file_write" or $t == "mcp__oio__file_edit" then ($i.path // $i.file_path // $i.filepath // empty)
          elif $t == "mcp__oio__file_rename" then (if (($i.new_name // "") | length) > 0 then
                (if ($i.new_name | startswith("/")) then $i.new_name else ((($i.path // $i.source // $i.src // "") | sub("/[^/]*$"; "")) + "/" + $i.new_name) end)
              else empty end)
          else ($i.destination // $i.dest // $i.dst // $i.target // $i.to // $i.new_path // empty) end' 2>/dev/null || echo "")
        if [[ "$_O9_DST" =~ session-env/[^/]+/next_action\.json$ ]] && _oto9_auto_on "$(dirname "$_O9_DST")"; then
          case "$TOOL_NAME" in
            mcp__oio__file_write)
              _O9_RES=$(printf '%s' "$INPUT" | jq -r '.tool_input | (.content // .body // .data // .text // .new_content // .new_text // "")' 2>/dev/null \
                | _oto9_check "$(dirname "$_O9_DST")/goal.json") ;;
            mcp__oio__file_edit)
              _O9_RES=$(printf '%s' "$INPUT" | DST="$_O9_DST" timeout 5 python3 -c '
import json,os,sys
try:
    ti=(json.load(sys.stdin).get("tool_input") or {})
    g=lambda *ks: next((ti[k] for k in ks if isinstance(ti.get(k),str)), None)
    old=g("old_string","old","old_text","old_content","search"); new=g("new_string","new","new_text","new_content","replace")
    src=open(os.environ["DST"],encoding="utf-8").read()
    if old is None or new is None or old not in src: sys.stdout.write(src)
    else:
        allr=bool(ti.get("replace_all") or ti.get("global_replace"))
        sys.stdout.write(src.replace(old,new) if allr else src.replace(old,new,1))
except Exception:
    sys.stdout.write("")
' 2>/dev/null | _oto9_check "$(dirname "$_O9_DST")/goal.json") ;;
            *)
              _O9_SRC=$(echo "$INPUT" | jq -r '.tool_input | (.source // .src // .path // .file_path // empty)' 2>/dev/null || echo "")
              _O9_RES=$(cat -- "$_O9_SRC" 2>/dev/null | _oto9_check "$(dirname "$_O9_DST")/goal.json") ;;
          esac
          [[ "$_O9_RES" == "OK" ]] || _oto9_block "${_O9_RES#NG }"
        fi
        ;;
      mcp__oio__bash_exec)
        _wg_pre _O9_CMD "$_WG_CMD_OC" '.tool_input.command // .tool_input.cmd // empty'   # c205 D-9
        if [[ "$_O9_CMD" == *next_action.json* ]] && printf '%s' "$_O9_CMD" | grep -qP \
             '(>\|?\s*["'"'"']?[^\s;&|]*next_action\.json|\btee\b[^;&|\n]*next_action\.json|\bsed\b[^;&|\n]*\s-i[^;&|\n]*next_action\.json|\b(cp|mv|install|ln|rsync)\b[^;&|\n]*next_action\.json["'"'"']?\s*($|[;&|)\n])|\b(touch|truncate)\b[^;&|\n]*next_action\.json|\bdd\b[^;&|\n]*of=[^\s;&|]*next_action\.json|\bpython3?\b[^;&|\n]*next_action\.json[^;&|\n]*(["'"'"'][wa]["'"'"']|write|dump))'; then
          _O9_LIT=$(printf '%s' "$_O9_CMD" | grep -oP 'session-env/\K[0-9A-Za-z_-]+(?=/next_action\.json)' 2>/dev/null)
          while IFS= read -r _O9_U; do
            [[ -n "$_O9_U" ]] || continue
            if _oto9_auto_on "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${_O9_U}" || _oto9_auto_on "$HOME/.claude/session-env/${_O9_U}"; then
              _oto9_block "셸 명령으로 next_action.json 을 쓰면 내용(blocked_only)을 증명할 수 없습니다 — mcp__oio__file_write 로 blocked_only 형식만 쓰십시오"
            fi
          done <<<"$(printf '%s\n%s\n' "$_G1_CANDS" "$_O9_LIT" | awk 'NF && !seen[$0]++')"
        fi
        ;;
    esac
    unset -f _oto9_block _oto9_auto_on _oto9_check
    # --- F-OTO-9 끝 ---

    # --- F-AC-1: acceptance_criteria.json 고정 파일명 덮어쓰기 물리 차단 (L-906) ---
    # 배경(실사고): 사이클56 의 acceptance_criteria.json 이 다음 사이클 쓰기에 덮여 ★실제로 소실★됐다.
    #   사본이 없어 복구 불가로 종결됐다. 원인은 파일명이 고정이라 매 사이클 같은 경로에 쓰이는 것이다.
    #   이 파일은 oplan 이 사이클당 1회 생성하고 그 뒤로는 immutable 이 원칙이다(otest/otest_verify 가 대조 기준으로 읽는다).
    #   ⇒ 정당한 덮어쓰기는 오직 "새 사이클 시작" 뿐이며, 그때는 ★이전 사이클분이 보존되어 있어야★ 한다.
    #
    # 판정(차단 조건 — AND):
    #   ① 대상이 session-env/<uuid>/{plans/,}acceptance_criteria.json 이다.
    #   ② 그 파일이 ★이미 존재★ 한다 (신규 생성은 항상 통과 — 첫 사이클/새 세션 무영향).
    #   ③ 기존 파일의 사이클 식별자 != 현재 세션의 식별자 (같으면 같은 사이클 갱신이므로 통과).
    #   ④ 기존 파일과 ★내용이 동일한 사본★ 이 같은 디렉토리에 없다 (있으면 이미 보존됨 → 통과).
    #
    # ④가 탈출구다. 새 사이클을 시작하려면 file_copy 한 번으로 보존하면 통과한다.
    #   사본 인정 이름: acceptance_criteria_*.json (기존 관행 — _prev_/_conv_/타임스탬프 접미 전부 포함)
    #   ★존재만이 아니라 cmp 로 내용 일치까지 본다★ — 낡은 사본이 남아 공짜 통과하는 F-GOAL-1 ①의
    #   라이브 회귀(사이클41 실측)와 동형 결함을 처음부터 배제한다.
    #
    # 식별자 추출: conv_id > conversation_id(사이클205 D-10) > cycle 순. 모두 없으면 "" (미상).
    #   ★미상은 현재 식별자와 불일치로 취급한다(fail-safe)★ — 구 스키마 파일일수록 보존 가치가 크고,
    #   탈출구(④ 사본 1회)가 저렴하므로 데이터를 지키는 쪽으로 판정한다.
    #
    # ★못 잡는 것 (자기 사각지대 — 명시)★
    #   1. bash_exec 판정은 명령 문자열 매칭이다. 변수 치환·base64·python 경로 조립은 통과한다
    #      (F-GOAL-1 (A) 와 동일한 한계 — 정면 우회는 막지만 작정한 우회는 못 막는다).
    #   2. 타 세션 경로는 검사 대상이 아니다(세션 격리 §(a)) — 보호도 안 된다.
    #   3. 사본을 만든 뒤 그 사본을 지우면 다시 차단으로 돌아간다(보존 실패로 간주 — 의도된 동작).

    # (A) bash_exec 우회 경로 차단 — sed -i / tee / cp / mv / truncate / 리다이렉션 / python open(w)
    if [[ "$TOOL_NAME" == "mcp__oio__bash_exec" ]]; then
      _wg_pre _AC_CMD "$_WG_CMD_OC" '.tool_input.command // .tool_input.cmd // empty'   # c205 D-9
      if echo "$_AC_CMD" | grep -qP 'session-env/[^ ]*acceptance_criteria\.json'; then
        if echo "$_AC_CMD" | grep -qP '(\bsed\b[^|]*-i|\brm\b|\bmv\b|\bcp\b|\btruncate\b|\btee\b|>\s*[^ |]*acceptance_criteria\.json|\bjq\b[^|]*(-i|--in-place))' \
           || _r3_py_write "$_AC_CMD"; then
          # [r3 R1] python3 단독 실행(읽기)은 쓰기가 아니다 — 쓰기 동반 python 만 대상(_r3_py_write).
          # cp/mv 는 ★목적지가 acceptance_criteria.json 일 때만★ 위험하다.
          # 보존 목적(원본 → 사본)의 cp 는 반드시 통과시켜야 한다 — 탈출구를 막으면 게이트가 교착한다.
          _AC_SAFE_COPY=0
          if echo "$_AC_CMD" | grep -qP '\b(cp|mv)\b[^|]*acceptance_criteria\.json\s+[^ |]*acceptance_criteria_[^ |]*\.json\s*$'; then
            _AC_SAFE_COPY=1
          fi
          if [[ "$_AC_SAFE_COPY" != "1" ]]; then
            echo '{"decision":"block","reason":"🔒 [F-AC-1/bash] acceptance_criteria.json 은 셸 명령(sed -i/tee/cp/mv/rm/python 등)으로 덮어쓰거나 삭제할 수 없습니다 — 사이클56 소실 사고(L-906) 재발 방지. 새 사이클을 시작하려면 먼저 mcp__oio__file_copy 로 acceptance_criteria_{식별자}.json 사본을 만든 뒤 file_write 하세요."}'
            exit 2
          fi
        fi
      fi
    fi

    # (B) 구조적 도구 경유 차단 — file_write/file_edit/file_delete/file_move/file_rename/file_copy(덮어쓰기)
    case "$TOOL_NAME" in
      mcp__oio__file_edit|mcp__oio__file_write|mcp__oio__file_delete|mcp__oio__file_move|mcp__oio__file_rename|mcp__oio__file_copy)
        # ★대상 판정★ — file_copy/file_move 는 ★목적지★ 가 피해 대상이다(H-1 과 동일 원칙).
        # [guard-deadlock 별칭] oio 대상 별칭 dst·target·to 와 file_rename 의 새 이름이 빠져, 실제 대상이 acceptance_criteria.json 인 호출이 판정을 비켜 갔다.
        #   종전 첫 값에 별칭 값을 더하기만 한다. 차단만 늘어난다.
        _AC_PATH=$(echo "$INPUT" | jq -r '
          def strs: map(select(type == "string" and . != ""));
          .tool_name as $t | (.tool_input // {}) as $i |
          ( ([$i.destination, $i.dest, $i.path, $i.file_path, $i.filepath] | strs | .[0:1])
            + (if $t == "mcp__oio__file_copy" or $t == "mcp__oio__file_move" then [$i.destination, $i.dest, $i.dst, $i.target, $i.to, $i.new_path] | strs else [] end)
            + (if $t == "mcp__oio__file_rename" then [$i.new_name, $i.name, $i.new_path, $i.to] | strs
                 | map(if startswith("/") then . else ((($i.path // $i.file_path // $i.source // $i.src // "") | sub("/[^/]*$"; "")) + "/" + .) end) else [] end)
          ) | unique | .[]' 2>/dev/null || echo "")
        # file_delete/file_move/file_rename 는 ★원본 소실이 곧 피해★ 이므로 source 도 함께 본다.
        # ★file_copy 는 제외한다★ — copy 의 source 는 '읽히는 쪽'이라 소실되지 않는다.
        #   여기에 file_copy 를 포함하면 ★탈출구(원본→사본 보존) 자체가 차단되어 게이트가 교착★ 한다.
        #   (실측: 음성테스트 케이스19 에서 이 결함이 잡혔다 — 양방향 검증이 아니었으면 놓쳤을 자리다.)
        _AC_SRC=""
        case "$TOOL_NAME" in
          mcp__oio__file_delete|mcp__oio__file_move|mcp__oio__file_rename)
            _AC_SRC=$(echo "$INPUT" | jq -r '[.tool_input.path, .tool_input.file_path, .tool_input.source, .tool_input.src] | map(select(type == "string" and . != "")) | unique | .[]' 2>/dev/null || echo "") ;;
        esac
        while IFS= read -r _AC_T; do
          [[ -z "$_AC_T" ]] && continue
          echo "$_AC_T" | grep -qP 'session-env/[^/]+/(plans/)?acceptance_criteria\.json$' || continue
          # ② 이미 존재할 때만 검사 (신규 생성은 통과)
          [[ -f "$_AC_T" ]] || continue
          # file_copy 로 ★사본을 만드는★ 정당 경로는 목적지가 acceptance_criteria_*.json 이므로
          # 위 grep(고정명 정확 일치)에 애초에 걸리지 않는다 — 별도 예외 불필요.

          _AC_DIR=$(dirname "$_AC_T")
          # ③ 식별자 대조 — 기존 파일 vs 현재 세션
          _AC_OLD_ID=$(timeout 3 python3 -c '
import json,sys
try:
    d=json.load(open(sys.argv[1],encoding="utf-8"))
    v=d.get("conv_id") or d.get("conversation_id") or d.get("cycle") or ""  # c205 D-10: conversation_id 키도 같은 사이클 식별자
    print(str(v).strip())
except Exception: print("")
' "$_AC_T" 2>/dev/null || echo "")
          _AC_CUR_ID=$(cat "${_AC_DIR}/conv_id" 2>/dev/null || cat "${_AC_DIR}/../conv_id" 2>/dev/null || echo "")
          _AC_CUR_ID=$(echo "$_AC_CUR_ID" | tr -d '[:space:]')
          if [[ -n "$_AC_OLD_ID" && -n "$_AC_CUR_ID" && "$_AC_OLD_ID" == "$_AC_CUR_ID" ]]; then
            continue   # 같은 사이클 갱신 — 통과
          fi
          # ④ 내용 동일 사본이 이미 있으면 통과 (보존 실증)
          _AC_ARCHIVED=0
          for _AC_C in "${_AC_DIR}"/acceptance_criteria_*.json; do
            [[ -f "$_AC_C" ]] || continue
            if cmp -s "$_AC_T" "$_AC_C"; then _AC_ARCHIVED=1; break; fi
          done
          [[ "$_AC_ARCHIVED" == "1" ]] && continue

          echo "{\"decision\":\"block\",\"reason\":\"🔒 [F-AC-1] acceptance_criteria.json 덮어쓰기 차단 — 기존 파일은 다른 사이클(식별자: '${_AC_OLD_ID:-미상}') 산출물이고 현재는 '${_AC_CUR_ID:-미상}' 입니다. 사이클56 에서 이 파일이 덮여 실제로 소실됐습니다(L-906). 먼저 mcp__oio__file_copy 로 같은 디렉토리에 acceptance_criteria_${_AC_OLD_ID:-prev}.json 사본을 만드세요. 사본이 원본과 내용 일치하면 이 쓰기가 허용됩니다.\"}"
          exit 2
        done <<<"$(printf '%s\n%s\n' "$_AC_PATH" "$_AC_SRC")"
        ;;
    esac
    # --- F-AC-1 끝 ---

    # --- H-1: agents/ · panes 삭제 전 잔존 팀에이전트 0건 강제 (2026-08-17) ---
    # 배경: 고아 팀에이전트 5개 사고. 종료가 완결되지 않았는데 agents/ 가 삭제되어
    #       추적 근거가 영구 소멸했다. 증적: Mars/.claude/evidence/agent_orphan_cleanup_20260817.md
    # 위치 근거: ★ 아래 "팀에이전트 → 항상 허용" 조기 exit 0 보다 반드시 앞에 있어야 한다.
    #           뒤에 두면 팀에이전트(PIPELINE_UUID 보유)가 전부 우회로가 되어 hook 이 무력해진다.
    #           실제로 agents/ 를 지우는 주체가 팀에이전트/ofinish 경로이므로 이 순서가 성패를 가른다.
    # 정책: 검사 실패(라이브러리 부재/오류) → 통과(fail-open). 검사 성공 + 잔존>0 → 차단(fail-closed).
    #       hook 자체의 오류로 세션이 멈추는 것이 고아 잔존보다 큰 사고이기 때문이다.
    # 긴급 정지: lib/orphan_scan.sh 를 지우거나 이름을 바꾸면 이 블록은 즉시 무력화된다(의도된 탈출구).
    # [3차 보강 2026-08-17] 판정 로직을 lib/orphan_scan.sh 로 완전 이관했다.
    #   1차 구현은 여기에 자체 정규식을 두어 oio 측과 **동일 결함을 공유**했고,
    #   그 결과 B1(상위 디렉토리)/B2(./)/B4(../) 가 두 계층을 동시에 통과했다(otest-1 실측).
    #   이제 경로 정규화·대상 판정·삭제성 판정 전부 check-path 한 곳에서만 수행한다.
    _H1_LIB="${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/orphan_scan.sh"
    if [[ -r "$_H1_LIB" ]]; then
      # ★ B13 해소 — 도구별 실제 파라미터명을 모두 읽는다.
      #   1차 구현은 path/file_path/command 만 읽어 dir_move(source,destination) 를 영구 미검사했다.
      #   4차 보강: file_copy(destination) / file_symlink(link_path) 누락분 추가.
      #   ★ destination·link_path 를 **먼저** 본다 — 복사/링크는 '덮어써지는 쪽'이 피해 대상이다.
      #     (source 를 먼저 보면 agents 로 덮어쓰는 시도를 놓친다.)
      _H1_TARGET=$(echo "$INPUT" | jq -r '[.tool_input.destination, .tool_input.dest, .tool_input.link_path, .tool_input.path, .tool_input.file_path, .tool_input.filepath, .tool_input.source, .tool_input.src, .tool_input.target] | map(select(. != null and . != "")) | .[0] // empty' 2>/dev/null || echo "")
      # 보조 대상 — destination 이 무해해도 source 쪽이 보호 경로면 함께 검사한다(move/rename 대응).
      _H1_TARGET2=$(echo "$INPUT" | jq -r '[.tool_input.path, .tool_input.file_path, .tool_input.source, .tool_input.src] | map(select(. != null and . != "")) | .[0] // empty' 2>/dev/null || echo "")
      _wg_pre _H1_CMD "$_WG_CMD_OC" '.tool_input.command // .tool_input.cmd // empty'   # c205 D-9

      # 삭제성 도구인지 먼저 본다(읽기/생성은 무관 — 오버헤드 0).
      _H1_APPLY=0
      case "$TOOL_NAME" in
        mcp__oio__dir_delete|mcp__oio__file_delete|mcp__oio__dir_move|mcp__oio__file_move|\
        mcp__oio__dir_rename|mcp__oio__file_rename|\
        mcp__oio__file_copy|mcp__oio__file_symlink|mcp__oio__file_write)
          # 4차 보강: file_copy(overwrite) / file_symlink(경로 치환) / file_write(내용 덮어쓰기)도
          # agents/ 를 파괴할 수 있다. 삭제만 막고 덮어쓰기를 열어두면 우회로가 된다.
          _H1_APPLY=1
          # [사이클194 (e)] file_write 가 ★새로 만드는★ 경우(대상 부재) 또는 ★링크 아닌 정규 파일★ 에 공백 아닌 내용을
          #   덮어쓰는 경우는 추적 근거를 없애지 않는다(같은 이름 재spawn 시 agents/<이름> 재기록 오탐 실측 16:17).
          #   대상이 디렉터리·심볼릭링크(끊긴 링크 포함)·빈 내용 덮어쓰기·상대경로·판독 실패면 종전대로 잔존 판정한다(fail-closed).
          #   file_copy·symlink·delete·move·rename·bash 는 무변경.
          if [[ "$TOOL_NAME" == "mcp__oio__file_write" ]]; then
            _h1_wp=$(echo "$INPUT" | jq -r '[.tool_input.path, .tool_input.file_path, .tool_input.filepath] | map(select(type=="string" and . != "")) | .[0] // empty' 2>/dev/null) || _h1_wp=""
            if [[ "$_h1_wp" == /* ]]; then
              if [[ ! -e "$_h1_wp" && ! -L "$_h1_wp" ]]; then
                _H1_APPLY=0
              elif [[ -f "$_h1_wp" && ! -L "$_h1_wp" ]]; then
                _h1_wc=$(echo "$INPUT" | jq -r '[.tool_input.content, .tool_input.text, .tool_input.body, .tool_input.data, .tool_input.new_content, .tool_input.new_text] | map(select(type=="string")) | .[0] // ""' 2>/dev/null) || _h1_wc=""
                [[ -n "${_h1_wc//[[:space:]]/}" ]] && _H1_APPLY=0
              fi
            fi
          fi ;;
        mcp__oio__bash_exec)
          _H1_APPLY=2 ;;   # 명령 문자열을 함께 넘겨 삭제성 여부까지 판정시킨다
      esac

      if [[ "$_H1_APPLY" != "0" ]]; then
        # bash_exec 은 명령 문자열 자체가 경로를 품고 있으므로 그대로 넘긴다.
        if [[ "$_H1_APPLY" == "2" ]]; then
          # 명령에서 보호 경로 후보를 추출 (없으면 검사 자체 불필요)
          _H1_TARGET=$(echo "$_H1_CMD" | grep -oE '[^[:space:]"'"'"']*session-env/[^[:space:]"'"'"']*' | head -1)
        fi
        if [[ -n "$_H1_TARGET" || -n "$_H1_TARGET2" ]]; then
          # ★ T3g 해소 — 타임아웃 2초(oio 측과 동일). 라이브러리가 매달려도 세션을 막지 않는다.
          _H1_VERDICT="PASS"
          if [[ -n "$_H1_TARGET" ]]; then
            _H1_VERDICT=$(timeout 2 bash "$_H1_LIB" check-path "$_H1_TARGET" "$_H1_CMD" 2>/dev/null) || _H1_VERDICT="UNKNOWN"
          fi
          # destination 이 무해하면 source 쪽도 확인 (move/rename 은 source 가 사라진다)
          if [[ "$_H1_VERDICT" != BLOCK\ * && -n "$_H1_TARGET2" && "$_H1_TARGET2" != "$_H1_TARGET" ]]; then
            _H1_VERDICT=$(timeout 2 bash "$_H1_LIB" check-path "$_H1_TARGET2" "$_H1_CMD" 2>/dev/null) || _H1_VERDICT="UNKNOWN"
          fi
          # fail-open: UNKNOWN/빈값/타임아웃(rc=124) 전부 통과
          if [[ "$_H1_VERDICT" == BLOCK\ * ]]; then
            _H1_UUID=$(echo "$_H1_VERDICT" | awk '{print $2}')
            _H1_CNT=$(echo "$_H1_VERDICT" | awk '{print $3}')
            if [[ "$_H1_UUID" == "__ALWAYS__" ]]; then
              # 최상위 경로(session-env 자체 / ~/.claude) — 고아 유무 무관 무조건 차단
              echo "{\"decision\":\"block\",\"reason\":\"🚫 [H-1] 전체 세션 추적 근거(session-env 또는 .claude 통째)를 삭제·치환하려 합니다. 모든 세션의 고아 추적이 영구 불가능해집니다. 개별 세션은 session-env/<uuid> 단위로 정리하세요.\"}"
            else
              _H1_LIST=$(timeout 2 bash -c "source '$_H1_LIB'; orphan_scan_detail '$_H1_UUID'" 2>/dev/null | head -5 | tr '\t' ' ' | tr '\n' ';' | tr -d '"\\' | head -c 260)
              echo "{\"decision\":\"block\",\"reason\":\"🚫 [H-1] 팀에이전트 ${_H1_CNT}건이 아직 살아있는데 세션 추적 근거(agents/panes 또는 session-env)를 삭제하려 합니다. 지금 지우면 고아가 영구 미탐지됩니다. 먼저 종료를 완결하세요(oinit). 잔존: ${_H1_LIST}\"}"
            fi
            exit 2
          fi
        fi
      fi
    fi
    # --- H-1 끝 ---

    # 팀에이전트 → 항상 허용
    # F-ISO-2 (세션 격리 §(a) 강화): 대상 경로가 session-env/<UUID>/ 패턴이면 그 UUID가
    # 자기 세션(PIPELINE_UUID)일 때만 이 조기 exit 0을 적용한다. 경로에 session-env 세그먼트가
    # 없는 공용 .claude/ 경로(hooks/skills/scripts 등)는 종전대로 무조건 허용 (정책 변경 없음).
    # 타 세션 session-env/<다른UUID>/ 는 여기서 exit 0 하지 않고 아래 일반 검사로 흘려보낸다.
    if [[ -n "${PIPELINE_UUID:-}" ]]; then
      _ISO2_PATH=$(echo "$INPUT" | jq -r '.tool_input.path // .tool_input.file_path // .tool_input.filepath // empty' 2>/dev/null || echo "")
      _ISO2_TARGET_UUID=$(echo "$_ISO2_PATH" | grep -oP 'session-env/\K[^/]+' | head -1)
      # L-014 재발방지: session-env 세그먼트가 없다고 무조건 허용하면 안 된다 —
      # NTFS 프로젝트 경로(/mnt/[c-z]/)도 session-env 세그먼트가 없어 여기서 같이 새어나가
      # 팀에이전트 NTFS 직접 수정 차단(L-014)이 무력화됐다(실측 확인).
      # fall-through 시 도달하는 하단 state 체크는 _UUID를 자기 session_id로 조회하므로
      # 팀에이전트 자신의 session-env에는 state 파일이 없어 기본값 IDLE로 오판·통과한다
      # (실측 확인) — 따라서 여기서 즉시 명시적으로 차단한다(fall-through 의존 금지).
      if echo "$_ISO2_PATH" | grep -qP '^/mnt/[c-z]/'; then
        _FW_REDIRECT=1   # [사이클194 g①] 셸 대안(rsync)을 안내하는 차단 — F-NO-BYPASS 대상 아님
        echo "{\"decision\":\"block\",\"reason\":\"🚨 [L-014] NTFS 직접 수정 금지! 팀에이전트도 rsync 방식 필수. 대상: ${_ISO2_PATH}\"}"
        exit 2
      elif [[ -z "$_ISO2_TARGET_UUID" || "$_ISO2_TARGET_UUID" == "$PIPELINE_UUID" ]]; then
        exit 0
      fi
      # session-env 세그먼트가 있고 자기 세션과 다름 → fall-through (아래 일반 검사로 차단 판정 위임)
    fi
    # Fix 3 (L-NEW): session-env 파이프라인 메타 파일 직접 쓰기 보호
    # PIPELINE_UUID 없는 메인이 oio file_write/file_edit으로 state/classification/team_name 덮어쓰기 차단
    # mcp__oio__session_state 도구는 다른 도구이므로 영향 없음
    # Finding 5 (L-NEW): mcp__oio__session_state는 write_guard 매처 밖(의도적 탈출 경로)
    # → OK 고착 시 메인이 IDLE로 리셋할 수 있는 유일한 수단 (Fix 12 abort path 활성화 전제)
    if [[ "$TOOL_NAME" == "mcp__oio__file_write" || "$TOOL_NAME" == "mcp__oio__file_edit" ]]; then
      _META_PATH=$(_wg_path_of)
      if echo "$_META_PATH" | grep -qP 'session-env/[^/]+/(state|classification|team_name|status|entry_tier)$'; then
        _FW_REDIRECT=1   # [사이클194 g①] state_machine.sh 경유 안내 — F-NO-BYPASS 대상 아님
        echo '{"decision":"block","reason":"🚫 [Fix 3/L-NEW] session-env 메타 파일 직접 쓰기 금지 — state/classification/team_name/status/entry_tier는 mcp__oio__session_state 도구 또는 state_machine.sh 경유 필수"}'
        exit 2
      fi
    fi
    # ── [c211 guardfix 결함1·결함4] 메인 자기 세션 한정 좁은 허용 예외 ──
    # 결함1: F-AC-2(a) 는 승인 마커를 "메인 file_write 만" 허용한다고 안내하지만, 메인이 활성 상태(PLAN/DEV/TEST/DONE)에서는
    #        아래 "메인 직접 oio 수정 금지" 블록에 먼저 걸려 마커를 쓸 수 없었다(교착). 마커 파일 쓰기만 연다.
    #        승인 범위(ac_ids·fields) 검증과 소비는 F-AC-2(b)가 그대로 수행한다.
    # 결함4: teammate_idle_guard 가 안내하는 session-env/<자기UUID>/agent_keep/<이름> file_write 가 같은 블록에 막혔다.
    # 한정: 도구 file_write(마커는 file_edit 도 허용), 메인(팀에이전트·PIPELINE_UUID 보유 프로세스 제외),
    #       realpath -m 정규화 결과가 <base>/session-env/<자기 session_id>/ 아래 정확한 파일명일 때만.
    #       타 UUID·다른 파일명·하위 폴더·.. 탈출·agent_keep 자체는 종전대로 차단(차단 규칙 삭제 없음).
    # [guard-deadlock D4] F-PATH-1 이 안내하는 복구 조치(자기 세션 두 base 간 file_copy)가 이 블록에 막혀 교착이 됐다.
    #   메인의 file_copy 중 _gf_copy_pair 를 통과하고 상대경로가 F-PATH-1 _TARGETS(state 제외)일 때만 연다. state 는 session_state 경유 그대로다.
    #   goal.json 은 원본이 잠겼으면 F-GOAL-1 이 D-9 를 통과시킨 경우(_G1_SYNC_OK=1)와 대상이 아예 없는 경우만 연다. 안 잠긴 대상으로의 복사는 막힌다.
    #   대상이 없는 경우: 계약이 한쪽에만 있고 복사는 그 내용을 그대로 옮기므로 계약이 바뀌지 않는다. 자기치유(spu_unify)가 예산 안에서 cp -a 로 하는 일과 같다.
    #   원본은 잠겼고 goal_id·acceptance 가 유효해야 한다. 통과 시 원본 쪽 logs/goal_sync.log 1줄.
    #   overwrite 가 켜진 호출은 열지 않는다. 판정 뒤 대상이 생기면 그 파일(잠긴 계약 포함)을 덮어쓰기 때문이다. overwrite 없으면 oio 가 FILE_EXISTS 로 실패한다.
    # [guard-deadlock §14-11] F-GOAL-1 이 이번 호출을 _APPEND_OK=1 로 판정한 자기 세션 goal.json 의 file_write 를 연다.
    #   path·file_path·filepath 어느 인자로 와도 같은 판정이다. 인자가 여럿이고 값이 다르면 실제 대상이 불확실하므로 열지 않는다.
    _gf_main_session_exempt() {  # 반환 0 = 예외 적용(호출부가 exit 0), 1 = 예외 아님
      local _gt="$TOOL_NAME" _gsid _gp _gr _gb _gbr _gname _gl
      if [[ "$_gt" == "mcp__oio__file_copy" ]]; then
        [[ -z "${PIPELINE_UUID:-}" ]] || return 1
        if declare -F _r3_is_team >/dev/null 2>&1 && _r3_is_team; then return 1; fi
        declare -F _gf_copy_pair >/dev/null 2>&1 || return 1
        _gf_copy_pair || return 1
        [[ -f "$_GF_SRC" ]] || return 1
        case "$_GF_REL" in
          status|auto|oroof_active|team_name|classification|entry_tier|oralph_active) return 0 ;;
          goal.json)
            _gl=$(timeout 3 jq -r 'if type == "object" then (.locked | tostring) else "invalid" end' "$_GF_SRC" 2>/dev/null) || return 1
            case "$_gl" in
              true)
                [[ "${_G1_SYNC_OK:-0}" == "1" ]] && return 0
                [[ ! -e "$_GF_DST" && ! -L "$_GF_DST" ]] || return 1
                [[ "$(echo "$INPUT" | jq -r 'if (.tool_input.overwrite // false) == false then "no" else "yes" end' 2>/dev/null)" == "no" ]] || return 1
                timeout 3 jq -e 'type == "object" and .locked == true and (.goal_id | type == "string" and length > 0) and (.acceptance | type == "array")' "$_GF_SRC" >/dev/null 2>&1 || return 1
                mkdir -p "$(dirname "$_GF_SRC")/logs" 2>/dev/null
                printf '%s ABSENT src=%s dst=%s\n' "$(date -Iseconds)" "$_GF_SRC" "$_GF_DST" >>"$(dirname "$_GF_SRC")/logs/goal_sync.log" 2>/dev/null || true
                return 0
                ;;
              ""|invalid) return 1 ;;
              *) return 0 ;;
            esac
            ;;
        esac
        return 1
      fi
      [[ "$_gt" == "mcp__oio__file_write" || "$_gt" == "mcp__oio__file_edit" ]] || return 1
      [[ -z "${PIPELINE_UUID:-}" ]] || return 1
      if declare -F _r3_is_team >/dev/null 2>&1 && _r3_is_team; then return 1; fi
      _gsid=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
      [[ "$_gsid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || return 1
      _gp=$(echo "$INPUT" | jq -r '.tool_input.path // .tool_input.file_path // .tool_input.filepath // empty' 2>/dev/null || echo "")
      [[ -n "$_gp" && "$_gp" == /* ]] || return 1
      _gr=$(realpath -m -- "$_gp" 2>/dev/null) || return 1
      for _gb in "${CLAUDE_CONFIG_DIR:-}" "$HOME/.claude"; do
        [[ -n "$_gb" ]] || continue
        _gbr=$(realpath -m -- "$_gb" 2>/dev/null || echo "$_gb")
        local _gx
        for _gx in "$_gb" "$_gbr"; do
          if [[ "$_gr" == "${_gx}/session-env/${_gsid}/plans/ac_edit_approval.json" ]]; then
            return 0
          fi
          if [[ "$_gt" == "mcp__oio__file_write" && "${_APPEND_OK:-0}" == "1" && "$_gr" == "${_gx}/session-env/${_gsid}/goal.json" ]]; then
            if [[ "$(echo "$INPUT" | jq -r '[.tool_input | .path, .file_path, .filepath] | map(select(type == "string" and . != "")) | unique | length' 2>/dev/null || echo 0)" == "1" ]]; then
              return 0
            fi
          fi
          if [[ "$_gt" == "mcp__oio__file_write" && "$_gr" == "${_gx}/session-env/${_gsid}/agent_keep/"* ]]; then
            _gname="${_gr#"${_gx}/session-env/${_gsid}/agent_keep/"}"
            if [[ "$_gname" =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}$ ]]; then
              return 0
            fi
          fi
        done
      done
      return 1
    }
    if _gf_main_session_exempt; then
      exit 0
    fi
    # .claude/ 하위 경로 → 파이프라인 상태 무관 항상 허용
    # F-NEW-1 (symlink traversal 방어): .claude/ 경로라도 symlink 해석 결과가 NTFS(/mnt/)면 허용 불가
    _wg_pre _OIO_PATH "$_WG_PATH" '.tool_input.path // empty'   # c205 D-9
    # [guard-deadlock D-9 별칭] file_copy 의 path 는 원본(읽기) 별칭이다. 아래 .claude·/tmp 허용은 쓰기 대상을 보는 판정이라 원본 경로로 열리면 안 된다.
    #   종전에는 path 로 부르면 부재·미잠금 대상까지 활성 상태 메인 차단을 건너뛰었다. 활성 상태 메인만 source·src 와 같은 판정으로 보낸다.
    #   IDLE·FINISH 와 팀원(자기 session_id 의 state 없음)은 종전 그대로다.
    # [guard-deadlock 분리 세션] CLAUDE_CONFIG_DIR 쪽에 state 가 없고 HOME 쪽에 있으면 HOME 쪽을 읽는다. 없는 쪽을 IDLE 로 읽어 활성 상태 메인 차단을 건너뛰던 경로다.
    #   CLAUDE_CONFIG_DIR 쪽에 state 가 있으면 종전대로 그쪽이 우선이다. 양쪽 다 없으면(팀원) 종전대로 없는 파일을 읽어 IDLE 이다.
    _wg_state_file() {
      local _f="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/$1/state"
      [[ ! -e "$_f" && -e "$HOME/.claude/session-env/$1/state" ]] && _f="$HOME/.claude/session-env/$1/state"
      printf '%s' "$_f"
    }
    if [[ "$TOOL_NAME" == "mcp__oio__file_copy" && -n "$_OIO_PATH" ]]; then
      _CP_UUID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null) || _CP_UUID=""
      _CP_ST=""
      if [[ -n "$_CP_UUID" ]]; then
        source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/session_id.sh" 2>/dev/null || true
        _CP_ST=$(state_read "$(_wg_state_file "$_CP_UUID")" 2>/dev/null | awk '{print $1}') || _CP_ST=""
      fi
      case "${_CP_ST:-IDLE}" in IDLE|FINISH) ;; *) _OIO_PATH="" ;; esac
    fi
    _CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    # F-NEW-1-EXC (2026-08-01): CLAUDE_CONFIG_DIR가 세션 임시 디렉토리(/tmp/cc-*)인 구성에서
    # projects/*/memory/ 하위(MEMORY.md 등 자동메모리)는 정당한 NTFS symlink이므로 예외 허용
    if [[ "$_OIO_PATH" == "$_CLAUDE_DIR"/*/memory/*.md ]]; then
      exit 0
    fi
    if [[ "$_OIO_PATH" == "$_CLAUDE_DIR"/* || "$_OIO_PATH" == /home/*/.claude/* ]]; then
      # symlink 해석: .claude/ 경로가 NTFS를 가리키면 차단
      _RESOLVED_PATH=$(realpath -m "$_OIO_PATH" 2>/dev/null || echo "$_OIO_PATH")
      # [사이클215 F-NEW-1-LNK] 링크 노드 자체 조작(file_delete·file_rename)은 realpath 판정 생략 — 아래 F-ISO-3 는 그대로 거친다
      if echo "$_RESOLVED_PATH" | grep -qP '^/mnt/[c-z]/' && ! _wg_fnew1_link_node "$_OIO_PATH"; then
        echo '{"decision":"block","reason":"🚫 [F-NEW-1] .claude/ 심볼릭링크가 NTFS 경로를 가리킵니다 — symlink traversal 차단. 직접 NTFS 경로를 사용하세요."}'
        exit 2
      fi
      # F-ISO-3 (세션 격리 §(a) 강화): session-env/<UUID>/ 세그먼트가 있으면 그 UUID가
      # 자기 세션일 때만 통과. session-env 아닌 공용 .claude/ 경로는 종전대로 허용 (정책 변경 없음).
      #
      # ★[2026-09-13 사이클128 T-E] 팀에이전트 오차단 수정 — 격리는 유지하고 증명을 추가한다★
      #   문제: PIPELINE_UUID 는 ★환경변수★ 인데 팀에이전트는 그 값을 ★프롬프트 텍스트★ 로 받는다.
      #        hook 프로세스 환경에는 없다(실측 PIPELINE_UUID=<unset>). 그래서 폴백인
      #        stdin session_id(=팀에이전트 자신의 UUID)가 쓰였고, 파이프라인 UUID 와 달라
      #        ★자기 팀 산출물 경로가 "타 세션"으로 오판★ 됐다(oplan-128 계획서 쓰기 차단).
      #
      #   ⚠️ 비대칭이 핵심이었다: 정당한 쓰기는 막으면서, scratchpad→cp 우회는 못 막았다.
      #      (oplan 이 실제로 우회해 같은 경로에 썼다.) 보호 효과는 낮고 방해만 컸다.
      #
      #   조치 방향: ★차단을 푸는 것이 아니라 자기 세션임을 올바로 증명하는 것★.
      #   증명 수단 조사 결과(실제 stdin JSON 덤프 실측):
      #     - JSON 필드: session_id / transcript_path / cwd / agent_type / permission_mode /
      #                  hook_event_name / tool_name / tool_input / tool_use_id / scratchpad_dir
      #       ⇒ ★parent_session_id·team_name·agent_name 모두 부재.★ JSON 만으로는 증명 불가.
      #     - teams/<name>/config.json members 는 agentId·name 으로만 식별되고
      #       ★session_id 가 어디에도 없다★(전수 grep 0건) ⇒ 역추적 불가.
      #     - ★유효한 유일 수단: 프로세스 계보의 argv `--parent-session-id`★
      #       팀에이전트 프로세스는 `--agent-id X@session-Y --parent-session-id <파이프라인UUID>`
      #       로 기동된다(실측). argv 와 PPID 체인은 ★커널 소유★ 라 LLM 이 도구 호출로 위조할 수
      #       없다 — 프롬프트 텍스트보다 강한 증거다. MEMORY 「Agent spawn "성공"은 팀에이전트의
      #       증거가 아니다」도 판별 기준을 `--parent-session-id` 로 못박고 있다(동일 기준 재사용).
      #
      #   fail-closed 유지: 증명에 실패하면 종전대로 ★차단★ 한다. 애매하면 막는다.
      #   비용: 계보 탐색은 ★차단 직전에만★ 수행한다(정상 경로는 종전과 동일 비용).
      _ISO3_TARGET_UUID=$(echo "$_OIO_PATH" | grep -oP 'session-env/\K[^/]+' | head -1)
      if [[ -n "$_ISO3_TARGET_UUID" ]]; then
        _ISO3_SELF_UUID="${PIPELINE_UUID:-}"
        if [[ -z "$_ISO3_SELF_UUID" ]]; then
          _ISO3_SELF_UUID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
        fi
        if [[ -n "$_ISO3_SELF_UUID" && "$_ISO3_TARGET_UUID" != "$_ISO3_SELF_UUID" ]]; then
          # ── 소유권 증명 시도: 조상 프로세스 argv 의 --parent-session-id 가 대상 UUID 와 같은가
          _ISO3_PARENT=""
          _ISO3_P=$$
          _ISO3_I=0
          while [[ -n "$_ISO3_P" && "$_ISO3_P" != "1" && $_ISO3_I -lt 12 ]]; do
            _ISO3_ARGV=$(tr '\0' ' ' 2>/dev/null < "/proc/${_ISO3_P}/cmdline")
            _ISO3_PARENT=$(printf '%s' "$_ISO3_ARGV" \
              | grep -oP -- '--parent-session-id \K[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
              | head -1)
            [[ -n "$_ISO3_PARENT" ]] && break
            _ISO3_P=$(awk '/^PPid:/{print $2}' "/proc/${_ISO3_P}/status" 2>/dev/null)
            _ISO3_I=$((_ISO3_I + 1))
          done
          if [[ -n "$_ISO3_PARENT" && "$_ISO3_PARENT" == "$_ISO3_TARGET_UUID" ]]; then
            # 증명 성공: 나는 이 파이프라인이 spawn 한 팀에이전트다 → 자기 세션 영역이므로 허용
            exit 0
          fi
          echo "{\"decision\":\"block\",\"reason\":\"🚫 [F-ISO-3] 타 세션 session-env 경로 쓰기 차단 — 세션 격리 불변식 §(a) 위반. 대상 UUID(${_ISO3_TARGET_UUID})가 자기 UUID(${_ISO3_SELF_UUID})와 다릅니다. 팀에이전트라면 조상 프로세스의 --parent-session-id 가 대상 UUID 와 일치해야 하나 증명되지 않았습니다(검출값: ${_ISO3_PARENT:-없음}).\"}"
          exit 2
        fi
      fi
      exit 0  # .claude/ 하위 oio 전역 허용 (session-env는 자기 UUID 한정)
    fi
    # /tmp/ 하위 경로 → 파이프라인 상태 무관 허용 (스크린샷 등 메타 도구)
    # L-NEW-ALLOW: oss 스크린샷, 임시 파일 작업 등 /tmp/ 경유 메타 도구 지원
    if [[ "$_OIO_PATH" == /tmp/* ]]; then
      exit 0
    fi
    # bash_exec: 메인 오케스트레이션 명령 허용 (파이프라인 상태 무관)
    if [[ "$TOOL_NAME" == "mcp__oio__bash_exec" ]]; then
      # (L-303 run_in_background 차단 F10 은 2026-10-31 해제됨)
      _wg_pre _BASH_CMD "$_WG_CMD_ONLY" '.tool_input.command // empty'   # c205 D-9
      # L-410: bash_exec 허용 분기 A — /mnt/[c-z]/ 미참조 + 명령치환 없음 + _wg_a_ok 통과 시에만 exit 0, 아니면 B~E 로 fall-through(체인 NTFS 우회 차단)
      # A) .claude/ 또는 session-env 참조 + NTFS 프로젝트 경로(/mnt/[c-z]/) 미참조 + 명령치환 없음 → 오케스트레이션 허용
      # Fix 2 (L-NEW): 체인 명령(&&, ||, ;)은 .claude/ 전용 시 허용 — oinit Step 0 등 조건 체크 명령 지원
      # Fix 2-ext: 명령치환($(...) 또는 백틱)만 차단 — bash ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/x.sh $(...hidden_ntfs...) 우회 방지 (F-NEW-2)
      # L-NEW-ALLOW: oinit/oi/oresume/ointaug 등 메타 제어 명령은 파이프라인 상태 무관 허용
      if echo "$_BASH_CMD" | grep -qP '(\.claude/|session-env/)'; then
        if ! echo "$_BASH_CMD" | grep -qP '/mnt/[c-z]/'; then
          # [사이클206 분기 A 정밀화] 글자 언급만으로 허용하지 않는다 — 쓰기 대상이 허용 영역 안이고 실행 수단이 없을 때만(_wg_a_ok).
          #   어긋나면 아래 B~E 판정으로 넘어간다(읽기 사슬은 E 에서 통과).
          if ! echo "$_BASH_CMD" | grep -qP '(\$\(|`)' && _wg_a_ok "$_BASH_CMD"; then
            exit 0  # .claude/ 전용 bash 명령 (체인 포함 허용) → 메인 오케스트레이션 허용
          fi
          # 명령치환 포함 → fall-through (허용 조건 미충족으로 처리)
        fi
      fi
      # B) 읽기 전용 오케스트레이션: tmux 상태 조회 (팀 pane 관리에 필수)
      #    조건: tmux 읽기 명령 존재 + 위험 tmux 없음 + NTFS 프로젝트 경로 없음
      if echo "$_BASH_CMD" | grep -qP 'tmux\s+(list-panes|display-message|list-sessions|list-windows|show-options)'; then
        if ! echo "$_BASH_CMD" | grep -qP 'tmux\s+(kill|send-keys|new-window|split|respawn|swap|move|break|join)'; then
          if ! echo "$_BASH_CMD" | grep -qP '/mnt/[c-z]/'; then
            exit 0  # tmux 읽기 전용 + NTFS 프로젝트 경로 없음 → 메인 오케스트레이션 허용
          fi
        fi
      fi
      # B2) [c193 oi-fix-2 2026-10-19] 팀원 pane 복구용 단독 tmux 명령 — teammate idle guard 와의 교착 해소
      #     배경: idle guard 는 죽은 팀원에 대해 "캡처 → kill-pane → 재spawn" 을 요구하며 Agent 를 막는데,
      #           이 가드가 TEST 중 메인의 단독 `tmux capture-pane` 을 막아 메인이 스스로 풀 수 없었다(실사고).
      #     허용 조건(전부 충족): ① 명령 전체가 tmux 1개(체인·파이프·치환·리다이렉트·NTFS 경로 없음)
      #       ② 하위 명령이 capture-pane|kill-pane|display-message|display|list-panes
      #       ③ -t 대상이 %숫자 pane 이고 lib/own_team_pane.sh otp_owned_pane 로 "자기 UUID 의 팀원 pane" 이 증명됨
      #          (list-panes 는 ③ 생략 — 읽기 전용). 메인 pane·타 세션 pane 은 증명 실패로 아래 일반 차단을 탄다.
      _B2_RX='^[[:space:]]*tmux([[:space:]]+-L[[:space:]]+[A-Za-z0-9_.-]+)?[[:space:]]+(capture-pane|kill-pane|display-message|display|list-panes)([[:space:]]+[^;&|`$()<>]*)?[[:space:]]*$'
      if [[ "$_BASH_CMD" =~ $_B2_RX ]] && ! echo "$_BASH_CMD" | grep -qP '/mnt/[c-z]/'; then
        _B2_SUB="${BASH_REMATCH[2]}"
        _B2_SOCK=$(printf '%s' "$_BASH_CMD" | grep -oP '^\s*tmux\s+-L\s+\K[A-Za-z0-9_.-]+' | head -1)
        _B2_PANE=$(printf '%s' "$_BASH_CMD" | grep -oP '(^|\s)-t\s*\K%[0-9]+' | head -1)
        _B2_UUID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
        if [[ "$_B2_SUB" == "list-panes" ]]; then
          exit 0
        fi
        if [[ -n "$_B2_PANE" && -n "$_B2_UUID" ]] \
           && source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/own_team_pane.sh" 2>/dev/null \
           && otp_owned_pane "$_B2_UUID" "$_B2_PANE" "$_B2_SOCK"; then
          exit 0  # 자기 세션 팀원 pane 에 대한 단독 복구 명령
        fi
      fi
      # C) 읽기 전용 유틸 명령: 파일시스템 무변경 + NTFS 프로젝트 경로 무접근
      #    date, echo, sleep, wc, test, whoami, hostname, uname, env, printenv
      #    [사이클206 자체 발견 — D-12 와 같은 계열] 종전에는 첫 단어만 보고 명령 전체를 허용해 `sleep 1; rm -rf <소스>`·
      #    `echo x > <소스파일>`·`env rm …`·`echo "$(rm …)"` 가 PLAN 메인에서 통과했다(과소 차단). 이제 단일 단순 명령일 때만 허용한다 —
      #    무해 리다이렉트(2>/dev/null·2>&1)를 지운 뒤 ; & | < > 개행·$(·백틱이 없어야 하고, env 는 인자 없이 단독일 때만.
      #    사슬·리다이렉트가 든 읽기 명령은 아래 분기 D·E(엄격 읽기 전용 판정)로 넘어가므로 읽기 사슬은 계속 통과한다.
      #    구분자 검사는 따옴표 인식(따옴표 안 | > ; 는 글자 — `echo "a|b"` 통과). 닫히지 않은 따옴표는 단일 명령으로 보지 않는다.
      _C_CMD="${_BASH_CMD//2>\/dev\/null/ }"; _C_CMD="${_C_CMD//2>&1/ }"
      _C_SIMPLE=1
      if [[ "$_C_CMD" == *$'\n'* || "$_C_CMD" == *$'\r'* || "$_C_CMD" == *'$('* || "$_C_CMD" == *'`'* || "$_C_CMD" == *'\'* ]] || \
         [[ "$_C_CMD" =~ ^env[[:space:]]+[^[:space:]] ]]; then
        _C_SIMPLE=0
      else
        _C_Q=""
        for ((_C_I = 0; _C_I < ${#_C_CMD}; _C_I++)); do
          _C_CH="${_C_CMD:_C_I:1}"
          if [[ -n "$_C_Q" ]]; then [[ "$_C_CH" == "$_C_Q" ]] && _C_Q=""; continue; fi
          case "$_C_CH" in
            "'"|'"') _C_Q="$_C_CH" ;;
            ';'|'&'|'|'|'<'|'>') _C_SIMPLE=0; break ;;
          esac
        done
        [[ -z "$_C_Q" ]] || _C_SIMPLE=0
      fi
      if echo "$_BASH_CMD" | grep -qP '^(date|echo|sleep|wc|test|whoami|hostname|uname|env|printenv)(\s|$)' && [[ "$_C_SIMPLE" == "1" ]]; then
        if ! echo "$_BASH_CMD" | grep -qP '/mnt/[c-z]/'; then
          exit 0  # 읽기 전용 유틸 단일 명령 + NTFS 프로젝트 경로 없음 → 허용
        fi
      fi
      # D) /tmp/ 전용 명령 (NTFS 미참조) → 메타 도구 허용 (oss 스크린샷, 임시 파일 처리)
      # L-NEW-ALLOW: /tmp/ 경유 명령은 NTFS 프로젝트 경로 미포함 시 항상 허용
      # [c194 C-19 2026-10-22] 허점 보수: '/tmp/ 가 들어 있으면 명령 전체 허용' → '쓰기성 명령은 쓰기 대상이 /tmp 하위뿐일 때만 허용'.
      #   배경: /mnt/[c-z]/ 가 없는 ext4 경로(${HARNESS_HOME:-$HOME/.harness}/current/.claude/... 등)를 /tmp 와 한 명령에 섞으면 전체가 통과했다.
      #   판정: 쓰기성 표지(rm·mv·cp·tee·sed -i·리다이렉트 등)가 있고, /tmp/·허용 시스템 경로(/dev/null 등) 밖의 절대경로·~·$HOME·상위(..)
      #         토큰이 하나라도 있으면 분기 D 를 통과시키지 않고 아래 기존 상태 판정으로 넘긴다(fall-through). 읽기 전용 명령은 종전대로 허용.
      if echo "$_BASH_CMD" | grep -qP '/tmp/'; then
        if ! echo "$_BASH_CMD" | grep -qP '/mnt/[c-z]/'; then
          _D_CMD=$(printf '%s' "$_BASH_CMD" | sed -E 's#[0-9]*>&[0-9-]+##g; s#[0-9&]*>>?[[:space:]]*/dev/(null|stdout|stderr)##g')
          _D_WRITE=0
          if printf '%s' "$_D_CMD" | grep -qP '(^|[\s;&|(`])(rm|rmdir|mv|cp|tee|dd|truncate|chmod|chown|ln|install|touch|mkdir|rsync|shred|unlink)(\s|$)|\bsed\s+(-[A-Za-z]*i|--in-place)|\bperl\s+-[A-Za-z]*i|>'; then
            _D_WRITE=1
          fi
          # [사이클205 D-5] 출력 파일 피연산자를 받는 읽기 명령도 쓰기성으로 본다 — uniq 의 두 번째 피연산자(단독 - 포함 집계), sort -o/--output.
          #   종전에는 `cd <프로젝트>; cat /tmp/x | uniq - x.txt` 가 쓰기 표지 없음으로 분기 D 를 통과했다(과소 차단).
          if printf '%s' "$_D_CMD" | grep -qP '(^|[\s;&|(`])uniq(?:(?:\s+-[^\s;&|]+)*\s+(?:-|[^\s;&|-][^\s;&|]*)(?=[\s;&|)]|$)){2}|(^|[\s;&|(`])sort\s[^;&|]*?(?<=\s)(-[A-Za-z]*o|--output)'; then
            _D_WRITE=1
          fi
          _D_OUT=0
          if [[ "$_D_WRITE" == "1" ]] && printf '%s' "$_D_CMD" | grep -qP "(^|[\s='\"(:\`])(/(?!tmp/|dev/(null|stdout|stderr|zero|tty)(\s|\$|[;&|)\"'])|proc/|sys/|usr/|bin/|sbin/|lib)[^\s'\"]*|~|\\\$HOME|\\\$\{HOME|\\\$CLAUDE_CONFIG_DIR|\\\$\{CLAUDE_CONFIG_DIR|\.\./)"; then
            _D_OUT=1
          fi
          # [사이클206 D-12] 상대경로 쓰기 대상도 /tmp 밖 쓰기로 본다 — `cat /tmp/a > notes.txt`·`cp /tmp/a b.txt`·`… | tee log.txt`·
          #   `sort /tmp/a -o out.txt` 가 쓰기 대상이 절대경로가 아니라는 이유로 분기 D 를 통과하던 과소 차단. cwd 는 추적하지 않는다(보수 —
          #   `cd /tmp/x && echo hi > a.txt` 도 막힌다. 절대경로 /tmp/x/a.txt 로 쓰면 통과). 상대경로 읽기 피연산자는 쓰기 대상이 아니므로 종전대로 통과.
          if [[ "$_D_WRITE" == "1" && "$_D_OUT" == "0" ]] && _wg_d_relw "$_D_CMD"; then
            _D_OUT=1
          fi
          # [사이클206 (b)] /tmp 를 언급하더라도 스크립트·해석기·실행 수단·위험 환경변수 대입이면 분기 D 를 통과시키지 않는다
          #   (`bash /tmp/x.sh`·`/tmp/x.sh`·`PATH=/tmp/evil; ls`·`python3 /tmp/x.py`·`bash -c '…'; ls /tmp/`·`… | xargs rm`).
          #   종전에는 쓰기 표지가 없으면 통과해 /tmp 에 둔 스크립트로 임의 쓰기가 가능했다(과소 차단). 분기 E 엄격 판정이 이어서 본다.
          if [[ "$_D_OUT" == "0" ]] && _wg_d_exec "$_D_CMD"; then
            _D_OUT=1
          fi
          if [[ "$_D_OUT" == "0" ]]; then
            exit 0  # /tmp/ 전용 + NTFS 프로젝트 경로 없음 + (읽기 전용 또는 쓰기 대상이 /tmp 하위뿐) → 메타 도구 허용
          fi
        fi
      fi
      # E) [사이클205 W1] 엄격 읽기 전용 사슬 허용 — PLAN 차단 목적은 메인 수동 쓰기 방지(ok/SKILL.md:174)다.
      #    _askq_ro_cmd(F-ASKQ-PROT 와 공유: 읽기 명령 목록·리다이렉트·명령치환·해석기·쓰기 수단 금지)가 참이면 수정이 아니므로 허용한다.
      #    해석기·리다이렉트·치환·xargs rm·git -c·find -delete 등은 종전대로 아래 메인 PLAN 차단으로 떨어진다. NTFS 경로는 A~D 와 같은 기준으로 제외.
      #    [사이클206 NEW-a] 판정 전에 _wg_ro_norm 으로 리터럴 변수 대입·읽기 전용 $(…) 를 풀어 쓴다(`SD=<세션>; cat $SD/state; echo "[$(cat $SD/status)]"`).
      #    풀 수 없는 형태(재대입·&&·백틱·개행·비리터럴 값·위험 환경변수·쓰기 치환)는 원문 그대로라 종전대로 차단된다.
      #    NTFS 검사는 원문과 풀어 쓴 결과 둘 다에 한다(변수 값으로 숨긴 /mnt/ 경로 차단).
      _E_NORM=$(_wg_ro_norm "$_BASH_CMD")
      # [cgit2 2026-10-27] NTFS 제외의 좁은 예외 — 구간 머리 `git -C <경로>` 의 경로 값만 NTFS 검사에서 뺀다(AC-014: 메인의
      #   `git -C /mnt/c/… log/status/diff/show` 조회). 읽기 판정(_askq_ro_cmd → _askq_git_ro)은 그대로 거친다. 같은 명령의 다른 /mnt/ 언급
      #   (pathspec·cat 대상 등)은 종전대로 분기 E 밖이다.
      _wg_e_ntfs_strip() { printf '%s' "$1" | sed -E "s#(^|[;&|][[:space:]]*|^[[:space:]]*)git[[:space:]]+-C[[:space:]]+(\"[^\"]*\"|'[^']*'|[^[:space:];&|]+)#\\1git -C _#g"; }
      if _askq_ro_cmd "$_E_NORM" && ! _wg_e_ntfs_strip "$_BASH_CMD" | grep -qP '/mnt/[c-z]/' && ! _wg_e_ntfs_strip "$_E_NORM" | grep -qP '/mnt/[c-z]/'; then
        exit 0
      fi
      # G) [unblock3 ③ 2026-10-27] 사용자 결정 "메인 W5 git 해제"(사용자 지시 13:04 "남은 예외 세 가지도 막지 말고 다 풀어라").
      #    명령 전체가 git 구간 + cd·엄격 읽기 구간으로만 이뤄지면 상태(PLAN/DEV/TEST/DONE)·NTFS 경로와 무관하게 메인을 허용한다
      #    (`git --no-pager -C <NTFS> …`·`cd <NTFS> && git add … && git commit -m "$(cat <<'X' …)"` 포함 — 판정은 _wg_main_git_only).
      #    git 이 아닌 메인 직접 수정(리다이렉트 쓰기·sed -i·rm·cp 등이 섞인 명령, 파일 도구 file_write/file_edit)은 아래 활성 상태 차단 그대로다.
      if _wg_main_git_only "$_BASH_CMD"; then
        exit 0
      fi
    fi
    # 메인: 상태 확인
    _UUID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null) || _UUID=""
    if [[ -n "$_UUID" ]]; then
      # Fix 9 (L-NEW): cat 직접 읽기 → state_read(flock) 통일 — race condition 방지
      source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/session_id.sh" 2>/dev/null || true
      _STATE=$(state_read "$(_wg_state_file "$_UUID")" 2>/dev/null | awk '{print $1}') || _STATE=""
    fi
    _STATE="${_STATE:-IDLE}"
    # Fix 9 (L-NEW): __LOCK_FAIL__ 명시 감지 — fail-closed (차단 우선)
    if [[ "$_STATE" == "__LOCK_FAIL__" ]]; then
      echo '{"decision":"block","reason":"❌ [Fix 9/L-NEW] state 파일 lock 경쟁 중 — 안전을 위해 차단 (fail-closed). 잠시 후 재시도하세요."}'
      exit 2
    fi
    # IDLE/FINISH 상태: 메인 직접 수정 허용 (파이프라인 마무리 단계 포함)
    if [[ "$_STATE" == "IDLE" || "$_STATE" == "FINISH" ]]; then
      exit 0
    fi
    # F-OEXIT-1 (L-NEW): oinit/oresume 복구 경로 — session-env/${UUID}/ 하위 정리 허용
    #   (분기명 F-OEXIT-1은 hook 역사성 유지 — 옛 스킬명 oexit(→oclean→oinit)에서 유래. 현재는 oinit이 모든 종료/강제 초기화 담당.)
    # 이유: oinit 정리/IDLE 강제 전이는 PLAN/DEV/TEST/DONE 상태에서 호출되어야 하는데 (Phase B: stage OK 제거됨),
    #       기존 가드는 활성 상태의 메인 직접 file_delete/dir_delete를 무조건 차단 → 무한 락 유발
    # 허용 범위: session-env/${UUID}/ 하위 메타 파일 삭제만 (state 파일 자체는 별도 차단 — F1)
    if [[ "$TOOL_NAME" == "mcp__oio__file_delete" || "$TOOL_NAME" == "mcp__oio__dir_delete" ]]; then
      _OEXIT_PATH=$(echo "$INPUT" | jq -r '.tool_input.path // .tool_input.file_path // empty' 2>/dev/null || echo "")
      _OEXIT_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
      # session-env/${_UUID}/ 하위만 허용 (다른 세션 침범 차단 — 세션 격리 불변식)
      if [[ -n "$_UUID" && -n "$_OEXIT_PATH" ]]; then
        _ALLOWED_PREFIX="${_OEXIT_CONFIG_DIR}/session-env/${_UUID}/"
        if [[ "$_OEXIT_PATH" == "$_ALLOWED_PREFIX"* ]]; then
          # state 파일 자체는 별도 보호 (F1) — file_edit/file_write에서 차단됨, file_delete는 비정상이므로 차단
          if [[ "$_OEXIT_PATH" == "${_ALLOWED_PREFIX}state" ]]; then
            _FW_REDIRECT=1   # [사이클194 g①] state_machine.sh 경유 안내 — F-NO-BYPASS 대상 아님
            echo '{"decision":"block","reason":"🚫 [F1/F-OEXIT-1] state 파일 직접 삭제 금지 — state_machine.sh 경유 또는 mcp__oio__session_state(force=true) 사용"}'
            exit 2
          fi
          exit 0  # session-env/${UUID}/ 하위 정리 허용 (oinit Step 7 + Step 9)
        fi
      fi
    fi
    # [worktree-integrity 사고4] in-process 서브에이전트는 session_id 가 메인과 같아 state 를 메인으로 읽는다. hook 입력 agent_id 는 런타임이 채우며 도구 호출로 만들 수 없다.
    #   통과 조건: agent_id 있음, 입력 cwd 가 linked worktree 루트(.git 이 파일), 쓰기 대상·실행 폴더가 그 안. 원본 폴더·다른 worktree 는 종전대로 차단한다.
    #   bash 명령 본문의 경로는 판정하지 않는다(잔여 한계). 통과는 자기 세션 logs/isolated_agent_pass.log 에 남긴다.
    _wg_isolated_agent() {
      local _a _c _cr _t _tr _any=0
      _a=$(echo "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null)
      [[ -n "$_a" ]] || return 1
      _c=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
      [[ -n "$_c" && -f "$_c/.git" ]] || return 1
      _cr=$(realpath -m -- "$_c" 2>/dev/null) || return 1
      case "$TOOL_NAME" in
        mcp__oio__bash_exec) _t=$(echo "$INPUT" | jq -r '[.tool_input.working_dir, .tool_input.workdir, .tool_input.cwd] | map(select(type == "string" and . != "")) | .[]' 2>/dev/null); _any=1 ;;
        mcp__oio__file_write|mcp__oio__file_edit|mcp__oio__file_delete|mcp__oio__file_rename) _t=$(_wg_path_of) ;;
        mcp__oio__file_copy|mcp__oio__file_move) _t=$(echo "$INPUT" | jq -r '[.tool_input.destination, .tool_input.dest, .tool_input.dst, .tool_input.target, .tool_input.to, .tool_input.new_path] | map(select(type == "string" and . != "")) | .[]' 2>/dev/null) ;;
        *) return 1 ;;
      esac
      if [[ -z "$_t" ]]; then [[ "$_any" == 1 ]] || return 1; fi
      while IFS= read -r _tr; do
        [[ -n "$_tr" ]] || continue
        _tr=$(realpath -m -- "$_tr" 2>/dev/null) || return 1
        [[ "$_tr" == "$_cr" || "$_tr" == "$_cr"/* ]] || return 1
      done <<<"$_t"
      mkdir -p "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${_UUID}/logs" 2>/dev/null
      printf '%s PASS agent=%s tool=%s cwd=%s\n' "$(date -Iseconds)" "$_a" "$TOOL_NAME" "$_cr" >>"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${_UUID}/logs/isolated_agent_pass.log" 2>/dev/null || true
      return 0
    }
    if _wg_isolated_agent; then
      exit 0
    fi
    # [c211 guardfix 결함1·결함4] 활성 상태 차단 직전 재확인(위 .claude 분기를 타지 못한 인자 형태 대비) — 좁은 예외만
    if _gf_main_session_exempt; then
      exit 0
    fi
    # 파이프라인 활성(PLAN/DEV/TEST/DONE) → 메인 차단 (FINISH는 위에서 이미 exit 0)
    # (Phase B: stage OK 제거 — state=OK 잔존 케이스는 위 case 분기에서 PLAN으로 fallback)
    _BLOCKED_INFO=""
    if [[ "$TOOL_NAME" == "mcp__oio__bash_exec" ]]; then
      _BLOCKED_INFO=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null | head -c 80 | tr '"\\' "'/" | tr '\n' ' ' || echo "")
    else
      _BLOCKED_INFO=$(_wg_path_of | tr '"\\' "'/" || echo "")
    fi
    _MAIN_BLOCK_REASON="❌ 파이프라인 활성(${_STATE}) 중 메인 직접 oio 수정 금지! 도구: ${TOOL_NAME} | 대상: ${_BLOCKED_INFO}  | ▶ 대안: SendMessage로 기존 팀에이전트에 위임하거나 새 팀에이전트를 spawn하세요."
    if echo "$_BLOCKED_INFO" | grep -qF '/plans/'; then
      _MAIN_BLOCK_REASON="${_MAIN_BLOCK_REASON} → 산출물은 session-env/${_UUID}/plans/ 에 작성하세요."
    fi
    echo "{\"decision\":\"block\",\"reason\":\"${_MAIN_BLOCK_REASON}\"}"
    exit 2
    ;;
esac

# --- 이하 수정 도구 전용 경로 (set -euo pipefail 적용) ---
set -euo pipefail
# [사이클182 L-615] 내부 오류 차단은 그대로(fail-closed) 두고 사유만 원인별로 가린다. 트랩이 발동할 때만 돈다(평상시 비용 0).
#   이전에는 모든 실패를 'CRLF 오염'으로 표시해, 잘린 입력(time_budget 의 옛 1바이트 읽기)이 엉뚱한 진단으로 막혔다.
_wg_err_reason() {  # $1=실패 행 $2=실패 명령 → 사유 문자열(JSON 안전)
  set +e
  local _r _c="${2//[\"\\]/ }" _n=${#INPUT}
  if [[ -z "$INPUT" ]]; then
    _r="입력 없음(stdin 이 비어 있음)"
  elif ! printf '%s' "$INPUT" | jq -e . >/dev/null 2>&1; then
    _r="입력 손상 — 도구 입력 JSON 파싱 실패(잘림 가능, ${_n}자)"
  elif grep -q $'\r' "${BASH_SOURCE[0]}" 2>/dev/null; then
    _r="Hook CRLF 오염(write_guard.sh 에 CR 문자)"
  else
    _r="판정 명령 실패(행 ${1}: ${_c:0:80})"
  fi
  printf '%s' "$_r"
}
trap 'echo "{\"decision\":\"block\",\"reason\":\"❌ write_guard.sh 내부 오류 — $(_wg_err_reason "$LINENO" "$BASH_COMMAND"). 안전을 위해 차단\"}"; exit 2' ERR

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null || echo "unknown")

# --- P0: Edit/Write/NotebookEdit 전면 차단 (UUID 무관 — 최우선) ---
# oio MCP가 모든 파일 작업을 처리하므로 네이티브 도구는 무조건 차단
case "$TOOL_NAME" in
  Edit|Write|Notebookedit)
    FILE_PATH_P0=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || echo "")
    echo "{\"decision\":\"block\",\"reason\":\"🚨 Edit/Write 금지! mcp__oio__file_edit/file_write 사용 (${FILE_PATH_P0})\"}" ; true
    exit 2
    ;;
esac

# --- P1: Bash 파일시스템 변경 명령 차단 (oio 독점 강제) ---
# Edit/Write 차단(P0) 직후, UUID 결정 전에 삽입
# (UUID 무관하게 모든 Bash 파일 변경을 차단)

if [[ "$TOOL_NAME" == "Bash" ]]; then
  BASH_CMD_P1=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")

  # [TODO-019 2026-11-05] 따옴표 인식 정규화 — _is_whitelisted 의 빌트인 분기·/tmp 리다이렉트 분기 전용.
  #   출력: 따옴표 문자를 지우고 따옴표 안의 < > | & ; 공백·탭·줄바꿈을 _ 로 바꾼 한 줄. 아래가 하나라도 있으면 rc 1(출력 없음).
  #     따옴표 밖의 단일 |·단독 &(>& ·&> 는 허용)·줄바꿈·<( ·>( ·$'…', 닫히지 않은 따옴표, 산술 $(( ,
  #     안쪽이 읽기 전용이 아닌 명령 치환(아래 [Q-1]).
  #   [Q-1 R-F 완화 2026-11-05 사용자 결정] 명령 치환 $( … )·백틱(따옴표 밖·큰따옴표 안)은 '포함했다는 이유만으로' 거부하지 않는다.
  #     안쪽 명령을 읽기 전용 판정 _askq_ro_cmd(F-ASKQ-PROT 공용 — 리다이렉트·치환 중첩·해석기·쓰기 수단 금지)로 다시 보고,
  #     참이면 X 로 접는다. 거짓(rm·sed -i·리다이렉트·중첩 치환·줄바꿈 등)이면 rc 1. 치환 결과가 명령어 자리에 오면(`$(echo rm) -f x`)
  #     정규화본 머리 단어가 X 라 아래 빌트인 판정에서 거부된다(동적 명령어 차단).
  #   예외: $(cat <<'끝' … 끝) — 인용 종결자 heredoc 를 cat 으로 내보내기만 하는 치환(커밋 메시지 관용형)은 본문이 글자 그대로라 X 로 접는다.
  #   역슬래시는 다음 글자를 글자 그대로 만든다(따옴표 밖·큰따옴표 안). 작은따옴표 안은 전부 글자 그대로다.
  _wl_unq() {
    local c="$1" i=0 n ch q="" out="" t d b rx j x qq dp
    rx=$'^\\$\\(cat <<([\'"])([A-Za-z_][A-Za-z0-9_]*)([\'"])[ \t]*\n'
    n=${#c}
    while (( i < n )); do
      ch="${c:i:1}"
      if [[ "$q" == "'" ]]; then
        if [[ "$ch" == "'" ]]; then q=""; else
          case "$ch" in '<'|'>'|'|'|'&'|';'|' '|$'\t'|$'\n'|$'\r') out+="_" ;; *) out+="$ch" ;; esac
        fi
        i=$((i + 1)); continue
      fi
      if [[ "$ch" == '$' && "${c:i+1:1}" == '(' ]]; then
        t="${c:i}"
        if [[ "$t" =~ $rx ]]; then
          [[ "${BASH_REMATCH[1]}" == "${BASH_REMATCH[3]}" ]] || return 1
          d="${BASH_REMATCH[2]}"; b="${t:${#BASH_REMATCH[0]}}"
          if [[ "$b" == "$d"$'\n'* ]]; then b="${b:${#d}+1}"
          elif [[ "$b" == *$'\n'"$d"$'\n'* ]]; then b="${b#*$'\n'"$d"$'\n'}"
          else return 1; fi
          b="${b#"${b%%[![:space:]]*}"}"
          [[ "$b" == ')'* ]] || return 1
          out+="X"; i=$((n - ${#b} + 1)); continue
        fi
        # [Q-1] 일반 명령 치환 — 짝 괄호를 따옴표 인식으로 찾고 안쪽을 읽기 전용 판정으로 다시 본다. 산술 $(( 는 거부.
        j=$((i + 2)); qq=""; dp=0
        [[ "${c:j:1}" == '(' ]] && return 1
        while (( j < n )); do
          x="${c:j:1}"
          if [[ -n "$qq" ]]; then
            if [[ "$x" == "$qq" ]]; then qq=""; elif [[ "$qq" == '"' && "$x" == '\' ]]; then j=$((j + 1)); fi
          else
            case "$x" in
              "'"|'"') qq="$x" ;;
              '\') j=$((j + 1)) ;;
              '(') dp=$((dp + 1)) ;;
              ')') (( dp == 0 )) && break; dp=$((dp - 1)) ;;
            esac
          fi
          j=$((j + 1))
        done
        (( j < n )) || return 1
        t="${c:i+2:j-i-2}"
        [[ -n "${t//[[:space:]]/}" ]] && _askq_ro_cmd "$t" || return 1
        out+="X"; i=$((j + 1)); continue
      fi
      if [[ "$ch" == '`' ]]; then
        # [Q-1] 백틱 치환 — 다음 백틱까지를 안쪽으로 보고 같은 읽기 전용 판정을 한다.
        j=$((i + 1))
        while (( j < n )) && [[ "${c:j:1}" != '`' ]]; do [[ "${c:j:1}" == '\' ]] && j=$((j + 1)); j=$((j + 1)); done
        (( j < n )) || return 1
        t="${c:i+1:j-i-1}"
        [[ -n "${t//[[:space:]]/}" ]] && _askq_ro_cmd "$t" || return 1
        out+="X"; i=$((j + 1)); continue
      fi
      if [[ "$q" == '"' ]]; then
        case "$ch" in
          '"') q="" ;;
          '\') out+="_"; i=$((i + 2)); continue ;;
          '<'|'>'|'|'|'&'|';'|' '|$'\t'|$'\n'|$'\r') out+="_" ;;
          *) out+="$ch" ;;
        esac
        i=$((i + 1)); continue
      fi
      case "$ch" in
        "'"|'"') q="$ch" ;;
        $'\n'|$'\r'|'|') return 1 ;;
        '\') out+="_"; i=$((i + 2)); continue ;;
        '$') [[ "${c:i+1:1}" == "'" ]] && return 1; out+="$ch" ;;
        '<'|'>') [[ "${c:i+1:1}" == '(' ]] && return 1; out+="$ch" ;;
        '&') if [[ "${out: -1}" == '>' || "${c:i+1:1}" == '>' ]]; then out+="$ch"; else return 1; fi ;;
        *) out+="$ch" ;;
      esac
      i=$((i + 1))
    done
    [[ -z "$q" ]] || return 1
    printf '%s' "$out"
  }

  _is_whitelisted() {
    local cmd="$1" u="" um=1 r
    local bi='^\s*(echo|printf|test|true|false|exit|return|export|unset|set|shopt|alias|hash|declare|local|readonly|trap|wait|jobs|bg|fg)\s'
    # 체인 명령(&&, ||, ;) → 무조건 거부 (bash_exec가 분리 실행)
    echo "$cmd" | grep -qP '(&&|\|\||;)' && return 1
    # [TODO-019] 빌트인 분기·/tmp 리다이렉트 분기는 정규화본(u)으로 본다. 정규화 실패(쓰기 치환·파이프·백그라운드·줄바꿈 등)면 두 분기를 닫는다.
    #   과소차단 실측: `sleep 1 > /tmp/x`(외부 명령의 /tmp 리다이렉트), `echo a | sh`(파이프), 줄바꿈 뒤 임의 명령.
    #   `echo $(cat …)` 는 [Q-1] 사용자 결정으로 치환 안이 읽기면 통과, 쓰기(`echo $(rm -f …)`)면 차단한다.
    #   session-env·.claude 분기는 종전대로 원문으로 본다(인프라 관리 경로 — 판정 무변경).
    u=$(_wl_unq "$cmd") || um=0
    r="$cmd"; [[ "$um" == 1 ]] && r="$u"
    # 리다이렉트(> file)가 보호 경로 외이면 거부 (echo > /mnt/c/file 우회 방지)
    if echo "$r" | grep -qP '(>|>>)'; then
      # [TODO-019] /tmp 리다이렉트는 정규화 성공 + 빌트인 머리 명령일 때만 허용(외부 명령은 bash_exec 경유)
      [[ "$um" == 1 ]] && echo "$u" | grep -qP '(>|>>)\s*/tmp/' && echo "$u" | grep -qP "$bi" && return 0
      echo "$cmd" | grep -qP 'session-env/[^/]+/' && return 0
      # Finding 2 (High) 수정: .claude/ 리다이렉트 체크에 /mnt/ 제외 추가
      #   이전: /\.claude/ 매칭만 → "echo x > ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/../../../mnt/c/DATA/file" 통과
      #   수정: .claude/ 포함 AND /mnt/[c-z]/ 미포함 조건으로 NTFS 경로 우회 차단
      if echo "$cmd" | grep -qP '/\.claude/'; then
        echo "$cmd" | grep -qP '/mnt/[c-z]/' && return 1  # NTFS 경로 리다이렉트 → 차단
        return 0  # .claude/ 전용 리다이렉트 허용
      fi
      return 1  # 비보호 경로 리다이렉트 → bash_exec 필수
    fi
    # session-env 상태 파일 쓰기 (파이프라인 상태 전파 — 리다이렉트 없는 명령도 허용)
    echo "$cmd" | grep -qP 'session-env/[^/]+/(state|classification|team_name|status|skill_direct|reroute_count|pipeline_start_time|entry_tier)' && return 0
    # ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/ 내부 (인프라 관리 — oio 대상 아님) — NTFS 경로 포함 시 차단
    # Finding 2 (High) 수정: /mnt/[c-z]/ 포함 명령은 .claude/ 일치해도 거부
    if echo "$cmd" | grep -qP '/\.claude/'; then
      echo "$cmd" | grep -qP '/mnt/[c-z]/' && return 1  # NTFS 포함 → 차단
      return 0
    fi
    # 셸 빌트인만 허용 (외부 명령은 모두 bash_exec 경유)
    # Finding 1 (High) 수정: eval/exec/command/builtin 제거 — 임의 명령 실행 우회 가능
    #   eval "rm -rf /mnt/c/..." 패턴이 화이트리스트 통과하여 NTFS 쓰기 가능했음
    #   command/builtin도 제거 — 외부 명령 래퍼로 우회 가능
    # [TODO-019] 정규화 성공일 때만 본다 — 쓰기 치환·`echo a | sh`·줄바꿈 뒤 명령은 여기서 닫힌다.
    [[ "$um" == 1 ]] && echo "$u" | grep -qP "$bi" && return 0
    # [Q-1] 변수 대입만으로 된 명령(`x=$(git rev-parse HEAD)`)은 셸 상태만 바꾼다. 대입 뒤에 명령 단어가 오면(`FOO=1 node x`) 거부.
    [[ "$um" == 1 ]] && echo "$u" | grep -qP '^\s*([A-Za-z_][A-Za-z0-9_]*=\S*\s*)+$' && return 0
    return 1
  }

  # [MONITOR-WAIT 2026-11-05] 부작용 없는 단독 대기·확인 명령 허용 — Monitor 폴링 형태(사용자 방침: 과대차단이 과소차단보다 위험)
  #   허용: sleep N…, test …, [ … ], pgrep …(--signal 류 제외), echo …, date(+형식·-u·-R·-I·--iso-8601·--rfc-* 만), true, false
  #         위 명령만으로 된 until/while …; do …; done 대기 루프와 ;·&&·|| 사슬, 명령 앞의 ! 부정
  #   거부: < > $ 백틱 ( ) { } 역슬래시 줄바꿈 문자, 단일 | 와 &(파이프·백그라운드), 빈 구간, 그 밖의 명령(경로·변수 접두 포함)
  #   근거: 허용 명령은 파일 쓰기도 다른 명령 실행도 못 해 bash_exec 로 할 수 있는 일보다 능력이 크지 않다.
  #   판정이 불확실하면 거부한다(종전대로 아래 차단 분기로 간다). 기존 _is_whitelisted 판정은 바꾸지 않는다.
  _safe_wait_cmd() {
    local c="$1" a
    local re_sleep='^[0-9]+(\.[0-9]+)?[smhd]?$'
    local re_date='^(\+.*|-u|-R|--utc|--universal|-I[a-z]*|--iso-8601(=[a-z]+)?|--rfc-(email|2822|3339=[a-z]+))$'
    shift
    case "$c" in
      sleep)
        [[ $# -ge 1 ]] || return 1
        for a in "$@"; do [[ "$a" =~ $re_sleep ]] || return 1; done ;;
      test|echo|true|false) ;;
      '[')
        [[ $# -ge 1 && "${!#}" == "]" ]] || return 1 ;;
      pgrep)
        for a in "$@"; do [[ "$a" == --si* ]] && return 1; done ;;
      date)
        for a in "$@"; do a="${a//[\'\"]/}"; [[ "$a" =~ $re_date ]] || return 1; done ;;
      *) return 1 ;;
    esac
    return 0
  }

  _is_safe_wait() {
    local cmd="$1" rest seg n_loop=0 n_do=0 n_done=0
    local re_bad='[<>$`(){}\\]'
    local -a segs w
    [[ "$cmd" =~ $re_bad ]] && return 1
    [[ "$cmd" == *$'\n'* || "$cmd" == *$'\r'* ]] && return 1
    rest="${cmd//&&/;}"
    rest="${rest//||/;}"
    [[ "$rest" == *[\|\&]* ]] && return 1
    [[ "$rest" =~ [^[:space:]] ]] || return 1
    IFS=';' read -r -a segs <<< "$rest"
    for seg in "${segs[@]}"; do
      IFS=$' \t' read -r -a w <<< "$seg"
      [[ ${#w[@]} -ge 1 ]] || return 1
      case "${w[0]}" in
        until|while) n_loop=$((n_loop + 1)); w=("${w[@]:1}") ;;
        do) n_do=$((n_do + 1)); w=("${w[@]:1}") ;;
        done) n_done=$((n_done + 1)); [[ ${#w[@]} -eq 1 ]] || return 1; continue ;;
      esac
      if [[ ${#w[@]} -ge 1 && "${w[0]}" == '!' ]]; then w=("${w[@]:1}"); fi
      [[ ${#w[@]} -ge 1 ]] || return 1
      _safe_wait_cmd "${w[@]}" || return 1
    done
    [[ $n_loop -eq $n_do && $n_do -eq $n_done ]] || return 1
    return 0
  }

  _has_fs_mutation() {
    local cmd="$1"
    # 디렉토리 조작: mkdir, rmdir
    echo "$cmd" | grep -qP '\b(mkdir|rmdir)\b' && return 0
    # 파일 삭제: rm (rm -f, rm -rf 등)
    echo "$cmd" | grep -qP '\brm\s+(-\S+\s+)*[^|&;]' && return 0
    # 파일/디렉토리 이동/복사: mv, cp
    echo "$cmd" | grep -qP '\b(mv|cp)\s+(-\S+\s+)*\S+\s+\S+' && return 0
    # 파일 생성/수정: touch, truncate
    echo "$cmd" | grep -qP '\b(touch|truncate)\b' && return 0
    # 리다이렉트 쓰기: > file, >> file (단, /tmp/ 및 session-env 제외 — 화이트리스트)
    echo "$cmd" | grep -qP '(^|[;&|])\s*[^#]*\s+>\s*[^/]' && return 0
    echo "$cmd" | grep -qP '>\s*/mnt/' && return 0
    echo "$cmd" | grep -qP '>\s*/home/[^/]+/(?!\.claude/)' && return 0
    # in-place 편집: sed -i, perl -i
    echo "$cmd" | grep -qP '\b(sed|perl)\s+.*-i\b' && return 0
    # tee (쓰기)
    echo "$cmd" | grep -qP '\btee\s+(-a\s+)?\S+' && return 0
    # rsync (파일 동기화/쓰기)
    echo "$cmd" | grep -qP '\brsync\b' && return 0
    # dd (블록 쓰기: dd of=file)
    echo "$cmd" | grep -qP '\bdd\b' && return 0
    # ln (링크 생성)
    echo "$cmd" | grep -qP '\bln\s' && return 0
    # patch (파일 수정)
    echo "$cmd" | grep -qP '\bpatch\b' && return 0
    # install (파일 복사+권한)
    echo "$cmd" | grep -qP '\binstall\s' && return 0
    return 1
  }

  # --- F1: state 파일 직접 쓰기 차단 (state_machine.sh 경유 강제) ---
  # session-env/*/state 파일에 대한 모든 직접 쓰기(echo>, printf>, >, tee, sed -i 등)를 차단.
  # 우회 수단: state_machine.sh의 state_transition() 함수 경유 (CAS + flock + checkpoint).
  # state_machine.sh/session_id.sh의 state_write는 source된 함수 호출이므로 Bash 매처가 아닌 bash_exec 내부 실행 → write_guard는 통과.
  if echo "$BASH_CMD_P1" | grep -qP 'session-env/[^/]+/state\b' && \
     echo "$BASH_CMD_P1" | grep -qP '(>\s*["'\'']?[^|&<]*session-env/[^/]+/state|tee\s+.*session-env/[^/]+/state|sed\s+.*-i.*session-env/[^/]+/state|mv\s+[^|]*session-env/[^/]+/state|cp\s+[^|]*session-env/[^/]+/state)'; then
    _FW_REDIRECT=1   # [사이클194 g①] state_machine.sh 경유 안내 — F-NO-BYPASS 대상 아님
    echo '{"decision":"block","reason":"🚨 [F1] state 파일 직접 쓰기 금지 — state_machine.sh의 state_transition() 경유 필수 (CAS + flock + checkpoint). (Monitor 호출도 이 가드를 거친다 — Monitor 는 Bash 와 같은 권한 규칙과 가드가 적용된다. 단독 대기·확인 명령 sleep N·test·[ ]·pgrep·echo·date·true·false 와 그것만으로 된 until/while 대기 루프, ;·&&·|| 사슬은 통과한다. 리다이렉트·명령 치환·파이프·그 밖의 명령이 섞이면 막힌다. 긴 작업은 setsid nohup 으로 띄운 뒤 timeout 85 bash_exec 폴링으로 확인한다)"}' ; true
    exit 2
  fi

  # --- P1-A: 파일 I/O 명령 차단 (체인 인식 — &&/||/; 뒤 명령도 검사) ---
  # 체인 프리픽스: 줄 시작 또는 &&/||/; 뒤
  _CP='(^|\s*&&\s*|\s*\|\|\s*|\s*;\s*)'
  # 쓰기 도구
  _FILE_WRITE_CMDS='(touch|dd|patch|truncate|install|tee|nano|vi|vim)'
  if echo "$BASH_CMD_P1" | grep -qP "${_CP}${_FILE_WRITE_CMDS}(\s|$)"; then
    echo '{"decision":"block","reason":"🚨 Bash 파일쓰기 금지→oio (Monitor 호출도 이 가드를 거친다 — Monitor 는 Bash 와 같은 권한 규칙과 가드가 적용된다. 단독 대기·확인 명령 sleep N·test·[ ]·pgrep·echo·date·true·false 와 그것만으로 된 until/while 대기 루프, ;·&&·|| 사슬은 통과한다. 리다이렉트·명령 치환·파이프·그 밖의 명령이 섞이면 막힌다. 긴 작업은 setsid nohup 으로 띄운 뒤 timeout 85 bash_exec 폴링으로 확인한다)"}' ; true
    exit 2
  fi
  # 디렉토리 생성/삭제 → oio 전용 도구 (P1-A에서 whitelist 도달 전 차단)
  if echo "$BASH_CMD_P1" | grep -qP "${_CP}mkdir(\s|$)"; then
    echo '{"decision":"block","reason":"🚨 Bash mkdir→oio dir_create (Monitor 호출도 이 가드를 거친다 — Monitor 는 Bash 와 같은 권한 규칙과 가드가 적용된다. 단독 대기·확인 명령 sleep N·test·[ ]·pgrep·echo·date·true·false 와 그것만으로 된 until/while 대기 루프, ;·&&·|| 사슬은 통과한다. 리다이렉트·명령 치환·파이프·그 밖의 명령이 섞이면 막힌다. 긴 작업은 setsid nohup 으로 띄운 뒤 timeout 85 bash_exec 폴링으로 확인한다)"}' ; true
    exit 2
  fi
  if echo "$BASH_CMD_P1" | grep -qP "${_CP}rmdir(\s|$)"; then
    echo '{"decision":"block","reason":"🚨 Bash rmdir→oio dir_delete (Monitor 호출도 이 가드를 거친다 — Monitor 는 Bash 와 같은 권한 규칙과 가드가 적용된다. 단독 대기·확인 명령 sleep N·test·[ ]·pgrep·echo·date·true·false 와 그것만으로 된 until/while 대기 루프, ;·&&·|| 사슬은 통과한다. 리다이렉트·명령 치환·파이프·그 밖의 명령이 섞이면 막힌다. 긴 작업은 setsid nohup 으로 띄운 뒤 timeout 85 bash_exec 폴링으로 확인한다)"}' ; true
    exit 2
  fi
  if echo "$BASH_CMD_P1" | grep -qP "${_CP}rm(\s|$)"; then
    echo '{"decision":"block","reason":"🚨 Bash rm→oio file_delete/dir_delete (Monitor 호출도 이 가드를 거친다 — Monitor 는 Bash 와 같은 권한 규칙과 가드가 적용된다. 단독 대기·확인 명령 sleep N·test·[ ]·pgrep·echo·date·true·false 와 그것만으로 된 until/while 대기 루프, ;·&&·|| 사슬은 통과한다. 리다이렉트·명령 치환·파이프·그 밖의 명령이 섞이면 막힌다. 긴 작업은 setsid nohup 으로 띄운 뒤 timeout 85 bash_exec 폴링으로 확인한다)"}' ; true
    exit 2
  fi
  if echo "$BASH_CMD_P1" | grep -qP "${_CP}(mv|cp)(\s|$)"; then
    echo '{"decision":"block","reason":"🚨 Bash mv/cp→oio file_move/file_copy (Monitor 호출도 이 가드를 거친다 — Monitor 는 Bash 와 같은 권한 규칙과 가드가 적용된다. 단독 대기·확인 명령 sleep N·test·[ ]·pgrep·echo·date·true·false 와 그것만으로 된 until/while 대기 루프, ;·&&·|| 사슬은 통과한다. 리다이렉트·명령 치환·파이프·그 밖의 명령이 섞이면 막힌다. 긴 작업은 setsid nohup 으로 띄운 뒤 timeout 85 bash_exec 폴링으로 확인한다)"}' ; true
    exit 2
  fi
  # sed/perl: -i 플래그 → 쓰기, 없으면 → 읽기
  if echo "$BASH_CMD_P1" | grep -qP "${_CP}(sed|perl)(\s|$)"; then
    if echo "$BASH_CMD_P1" | grep -qP '\b(sed|perl)\s+.*-i\b'; then
      echo '{"decision":"block","reason":"🚨 sed -i→oio file_edit (Monitor 호출도 이 가드를 거친다 — Monitor 는 Bash 와 같은 권한 규칙과 가드가 적용된다. 단독 대기·확인 명령 sleep N·test·[ ]·pgrep·echo·date·true·false 와 그것만으로 된 until/while 대기 루프, ;·&&·|| 사슬은 통과한다. 리다이렉트·명령 치환·파이프·그 밖의 명령이 섞이면 막힌다. 긴 작업은 setsid nohup 으로 띄운 뒤 timeout 85 bash_exec 폴링으로 확인한다)"}' ; true
    else
      echo '{"decision":"block","reason":"🚨 sed/perl→oio bash_exec (Monitor 호출도 이 가드를 거친다 — Monitor 는 Bash 와 같은 권한 규칙과 가드가 적용된다. 단독 대기·확인 명령 sleep N·test·[ ]·pgrep·echo·date·true·false 와 그것만으로 된 until/while 대기 루프, ;·&&·|| 사슬은 통과한다. 리다이렉트·명령 치환·파이프·그 밖의 명령이 섞이면 막힌다. 긴 작업은 setsid nohup 으로 띄운 뒤 timeout 85 bash_exec 폴링으로 확인한다)"}' ; true
    fi
    exit 2
  fi
  # 읽기/검색 도구
  _FILE_READ_CMDS='(cat|head|tail|tac|less|more|nl|xxd|od|strings|rev|fold|fmt|column|paste|comm|base64)'
  if echo "$BASH_CMD_P1" | grep -qP "${_CP}${_FILE_READ_CMDS}(\s|$)"; then
    # 파일 쓰기 리다이렉션만 매칭 (fd/stderr 리다이렉션 제외):
    #   매칭 O: `> file`, `>> file`, `<<EOF` (heredoc)
    #   매칭 X: `2>/dev/null`, `2>&1`, `&>`, `1>&2`, `3>`, `<<<` (here-string)
    # 앞에 숫자 fd나 '&'가 없고, 뒤에 '&'(fd 복사)가 아닌 '>' 만 실제 파일 쓰기로 간주
    if echo "$BASH_CMD_P1" | grep -qP '(^|[^0-9&])>{1,2}(?!&)|(?<!<)<<(?!<)'; then
      echo '{"decision":"block","reason":"🚨 Bash write→oio file_write (Monitor 호출도 이 가드를 거친다 — Monitor 는 Bash 와 같은 권한 규칙과 가드가 적용된다. 단독 대기·확인 명령 sleep N·test·[ ]·pgrep·echo·date·true·false 와 그것만으로 된 until/while 대기 루프, ;·&&·|| 사슬은 통과한다. 리다이렉트·명령 치환·파이프·그 밖의 명령이 섞이면 막힌다. 긴 작업은 setsid nohup 으로 띄운 뒤 timeout 85 bash_exec 폴링으로 확인한다)"}' ; true
    else
      echo '{"decision":"block","reason":"🚨 Bash cat→oio file_read (Monitor 호출도 이 가드를 거친다 — Monitor 는 Bash 와 같은 권한 규칙과 가드가 적용된다. 단독 대기·확인 명령 sleep N·test·[ ]·pgrep·echo·date·true·false 와 그것만으로 된 until/while 대기 루프, ;·&&·|| 사슬은 통과한다. 리다이렉트·명령 치환·파이프·그 밖의 명령이 섞이면 막힌다. 긴 작업은 setsid nohup 으로 띄운 뒤 timeout 85 bash_exec 폴링으로 확인한다)"}' ; true
    fi
    exit 2
  fi
  # 검색/패턴 도구 → Grep 도구 사용
  _FILE_SEARCH_CMDS='(grep|egrep|fgrep|rg|ag)'
  if echo "$BASH_CMD_P1" | grep -qP "${_CP}${_FILE_SEARCH_CMDS}(\s|$)"; then
    echo '{"decision":"block","reason":"🚨 Bash grep→Grep도구/oio bash_exec (Monitor 호출도 이 가드를 거친다 — Monitor 는 Bash 와 같은 권한 규칙과 가드가 적용된다. 단독 대기·확인 명령 sleep N·test·[ ]·pgrep·echo·date·true·false 와 그것만으로 된 until/while 대기 루프, ;·&&·|| 사슬은 통과한다. 리다이렉트·명령 치환·파이프·그 밖의 명령이 섞이면 막힌다. 긴 작업은 setsid nohup 으로 띄운 뒤 timeout 85 bash_exec 폴링으로 확인한다)"}' ; true
    exit 2
  fi
  # 텍스트 처리 도구 (파일 인자 접근)
  _FILE_PROC_CMDS='(awk|gawk|mawk|sort|cut|uniq|tr|wc)'
  if echo "$BASH_CMD_P1" | grep -qP "${_CP}${_FILE_PROC_CMDS}(\s|$)"; then
    echo '{"decision":"block","reason":"🚨 Bash awk/sort→oio bash_exec (Monitor 호출도 이 가드를 거친다 — Monitor 는 Bash 와 같은 권한 규칙과 가드가 적용된다. 단독 대기·확인 명령 sleep N·test·[ ]·pgrep·echo·date·true·false 와 그것만으로 된 until/while 대기 루프, ;·&&·|| 사슬은 통과한다. 리다이렉트·명령 치환·파이프·그 밖의 명령이 섞이면 막힌다. 긴 작업은 setsid nohup 으로 띄운 뒤 timeout 85 bash_exec 폴링으로 확인한다)"}' ; true
    exit 2
  fi
  # 파일 비교/검증
  _FILE_CMP_CMDS='(diff|cmp|md5sum|sha256sum|sha1sum|sha512sum|cksum)'
  if echo "$BASH_CMD_P1" | grep -qP "${_CP}${_FILE_CMP_CMDS}(\s|$)"; then
    echo '{"decision":"block","reason":"🚨 Bash diff/md5→oio bash_exec (Monitor 호출도 이 가드를 거친다 — Monitor 는 Bash 와 같은 권한 규칙과 가드가 적용된다. 단독 대기·확인 명령 sleep N·test·[ ]·pgrep·echo·date·true·false 와 그것만으로 된 until/while 대기 루프, ;·&&·|| 사슬은 통과한다. 리다이렉트·명령 치환·파이프·그 밖의 명령이 섞이면 막힌다. 긴 작업은 setsid nohup 으로 띄운 뒤 timeout 85 bash_exec 폴링으로 확인한다)"}' ; true
    exit 2
  fi

  # ls → mcp__oio__list_dir 내재화 (2026-03-31 /oio 일괄 내재화)
  if echo "$BASH_CMD_P1" | grep -qP "${_CP}ls(\s|$)"; then
    echo '{"decision":"block","reason":"🚨 Bash ls→oio list_dir (Monitor 호출도 이 가드를 거친다 — Monitor 는 Bash 와 같은 권한 규칙과 가드가 적용된다. 단독 대기·확인 명령 sleep N·test·[ ]·pgrep·echo·date·true·false 와 그것만으로 된 until/while 대기 루프, ;·&&·|| 사슬은 통과한다. 리다이렉트·명령 치환·파이프·그 밖의 명령이 섞이면 막힌다. 긴 작업은 setsid nohup 으로 띄운 뒤 timeout 85 bash_exec 폴링으로 확인한다)"}' ; true
    exit 2
  fi
  # stat/file → mcp__oio__file_info 내재화 (2026-03-31 /oio 일괄 내재화)
  if echo "$BASH_CMD_P1" | grep -qP "${_CP}(stat|file)(\s|$)"; then
    echo '{"decision":"block","reason":"🚨 Bash stat→oio file_info (Monitor 호출도 이 가드를 거친다 — Monitor 는 Bash 와 같은 권한 규칙과 가드가 적용된다. 단독 대기·확인 명령 sleep N·test·[ ]·pgrep·echo·date·true·false 와 그것만으로 된 until/while 대기 루프, ;·&&·|| 사슬은 통과한다. 리다이렉트·명령 치환·파이프·그 밖의 명령이 섞이면 막힌다. 긴 작업은 setsid nohup 으로 띄운 뒤 timeout 85 bash_exec 폴링으로 확인한다)"}' ; true
    exit 2
  fi
  # rename → mcp__oio__file_rename / dir_rename 내재화 (2026-03-31 /oio 일괄 내재화)
  if echo "$BASH_CMD_P1" | grep -qP "${_CP}rename(\s|$)"; then
    echo '{"decision":"block","reason":"🚨 Bash rename→oio file_rename (Monitor 호출도 이 가드를 거친다 — Monitor 는 Bash 와 같은 권한 규칙과 가드가 적용된다. 단독 대기·확인 명령 sleep N·test·[ ]·pgrep·echo·date·true·false 와 그것만으로 된 until/while 대기 루프, ;·&&·|| 사슬은 통과한다. 리다이렉트·명령 치환·파이프·그 밖의 명령이 섞이면 막힌다. 긴 작업은 setsid nohup 으로 띄운 뒤 timeout 85 bash_exec 폴링으로 확인한다)"}' ; true
    exit 2
  fi

  # bash → oio bash_exec 강제 (2026-03-31 /oio bash)
  if echo "$BASH_CMD_P1" | grep -qP "${_CP}bash(\s|$)"; then
    echo '{"decision":"block","reason":"🚨 Bash bash→oio bash_exec (Monitor 호출도 이 가드를 거친다 — Monitor 는 Bash 와 같은 권한 규칙과 가드가 적용된다. 단독 대기·확인 명령 sleep N·test·[ ]·pgrep·echo·date·true·false 와 그것만으로 된 until/while 대기 루프, ;·&&·|| 사슬은 통과한다. 리다이렉트·명령 치환·파이프·그 밖의 명령이 섞이면 막힌다. 긴 작업은 setsid nohup 으로 띄운 뒤 timeout 85 bash_exec 폴링으로 확인한다)"}' ; true
    exit 2
  fi

  # git → oio bash_exec 강제 (2026-03-30 /oio git)
  if echo "$BASH_CMD_P1" | grep -qP "${_CP}git(\s|$)"; then
    echo '{"decision":"block","reason":"🚨 Bash git→oio bash_exec (Monitor 호출도 이 가드를 거친다 — Monitor 는 Bash 와 같은 권한 규칙과 가드가 적용된다. 단독 대기·확인 명령 sleep N·test·[ ]·pgrep·echo·date·true·false 와 그것만으로 된 until/while 대기 루프, ;·&&·|| 사슬은 통과한다. 리다이렉트·명령 치환·파이프·그 밖의 명령이 섞이면 막힌다. 긴 작업은 setsid nohup 으로 띄운 뒤 timeout 85 bash_exec 폴링으로 확인한다)"}' ; true
    exit 2
  fi

  # find 명령 차단 — mcp__oio__find 사용 강제
  if echo "$BASH_CMD_P1" | grep -qP "${_CP}find(\s|$)"; then
    echo '{"decision":"block","reason":"🚨 Bash find→Glob/oio list_dir (Monitor 호출도 이 가드를 거친다 — Monitor 는 Bash 와 같은 권한 규칙과 가드가 적용된다. 단독 대기·확인 명령 sleep N·test·[ ]·pgrep·echo·date·true·false 와 그것만으로 된 until/while 대기 루프, ;·&&·|| 사슬은 통과한다. 리다이렉트·명령 치환·파이프·그 밖의 명령이 섞이면 막힌다. 긴 작업은 setsid nohup 으로 띄운 뒤 timeout 85 bash_exec 폴링으로 확인한다)"}'
    exit 2
  fi

  # dotnet / cmd.exe → oio bash_exec 강제
  if echo "$BASH_CMD_P1" | grep -qP "${_CP}dotnet(\s|$)"; then
    echo '{"decision":"block","reason":"🚨 Bash dotnet→oio bash_exec (Monitor 호출도 이 가드를 거친다 — Monitor 는 Bash 와 같은 권한 규칙과 가드가 적용된다. 단독 대기·확인 명령 sleep N·test·[ ]·pgrep·echo·date·true·false 와 그것만으로 된 until/while 대기 루프, ;·&&·|| 사슬은 통과한다. 리다이렉트·명령 치환·파이프·그 밖의 명령이 섞이면 막힌다. 긴 작업은 setsid nohup 으로 띄운 뒤 timeout 85 bash_exec 폴링으로 확인한다)"}' ; true
    exit 2
  fi
  if echo "$BASH_CMD_P1" | grep -qP "${_CP}cmd\.exe(\s|$)"; then
    echo '{"decision":"block","reason":"🚨 Bash cmd.exe→oio bash_exec (Monitor 호출도 이 가드를 거친다 — Monitor 는 Bash 와 같은 권한 규칙과 가드가 적용된다. 단독 대기·확인 명령 sleep N·test·[ ]·pgrep·echo·date·true·false 와 그것만으로 된 until/while 대기 루프, ;·&&·|| 사슬은 통과한다. 리다이렉트·명령 치환·파이프·그 밖의 명령이 섞이면 막힌다. 긴 작업은 setsid nohup 으로 띄운 뒤 timeout 85 bash_exec 폴링으로 확인한다)"}' ; true
    exit 2
  fi

  # python3/python → oio bash_exec 강제 (2026-03-31 /oio python3)
  if echo "$BASH_CMD_P1" | grep -qP "${_CP}python[23]?(\s|$)"; then
    echo '{"decision":"block","reason":"🚨 Bash python→oio bash_exec (Monitor 호출도 이 가드를 거친다 — Monitor 는 Bash 와 같은 권한 규칙과 가드가 적용된다. 단독 대기·확인 명령 sleep N·test·[ ]·pgrep·echo·date·true·false 와 그것만으로 된 until/while 대기 루프, ;·&&·|| 사슬은 통과한다. 리다이렉트·명령 치환·파이프·그 밖의 명령이 섞이면 막힌다. 긴 작업은 setsid nohup 으로 띄운 뒤 timeout 85 bash_exec 폴링으로 확인한다)"}' ; true
    exit 2
  fi

  # tmux → oio bash_exec 강제 (2026-04-01 오케스트레이션 교착 방지)
  if echo "$BASH_CMD_P1" | grep -qP "${_CP}tmux(\s|$)"; then
    echo '{"decision":"block","reason":"🚨 Bash tmux→oio bash_exec (Monitor 호출도 이 가드를 거친다 — Monitor 는 Bash 와 같은 권한 규칙과 가드가 적용된다. 단독 대기·확인 명령 sleep N·test·[ ]·pgrep·echo·date·true·false 와 그것만으로 된 until/while 대기 루프, ;·&&·|| 사슬은 통과한다. 리다이렉트·명령 치환·파이프·그 밖의 명령이 섞이면 막힌다. 긴 작업은 setsid nohup 으로 띄운 뒤 timeout 85 bash_exec 폴링으로 확인한다)"}' ; true
    exit 2
  fi

  # source/. → oio bash_exec 강제 (2026-04-01 /oio source)
  if echo "$BASH_CMD_P1" | grep -qP "${_CP}(source|\.)\s+"; then
    echo '{"decision":"block","reason":"🚨 Bash source→oio bash_exec (Monitor 호출도 이 가드를 거친다 — Monitor 는 Bash 와 같은 권한 규칙과 가드가 적용된다. 단독 대기·확인 명령 sleep N·test·[ ]·pgrep·echo·date·true·false 와 그것만으로 된 until/while 대기 루프, ;·&&·|| 사슬은 통과한다. 리다이렉트·명령 치환·파이프·그 밖의 명령이 섞이면 막힌다. 긴 작업은 setsid nohup 으로 띄운 뒤 timeout 85 bash_exec 폴링으로 확인한다)"}' ; true
    exit 2
  fi

  if ! _is_whitelisted "$BASH_CMD_P1" && ! _is_safe_wait "$BASH_CMD_P1"; then
    # P1-B: fs mutation은 구체적 oio 도구 안내
    if _has_fs_mutation "$BASH_CMD_P1"; then
      SUGGESTION="oio 도구를 사용하세요:"
      echo "$BASH_CMD_P1" | grep -qP '\bmkdir\b' && SUGGESTION="$SUGGESTION mcp__oio__dir_create"
      echo "$BASH_CMD_P1" | grep -qP '\brmdir\b' && SUGGESTION="$SUGGESTION mcp__oio__dir_delete"
      echo "$BASH_CMD_P1" | grep -qP '\brm\b' && SUGGESTION="$SUGGESTION mcp__oio__file_delete / dir_delete(recursive=true)"
      echo "$BASH_CMD_P1" | grep -qP '\bmv\b' && SUGGESTION="$SUGGESTION mcp__oio__file_move / dir_move"
      echo "$BASH_CMD_P1" | grep -qP '\bcp\b' && SUGGESTION="$SUGGESTION mcp__oio__file_copy"
      echo "$BASH_CMD_P1" | grep -qP '\btouch\b' && SUGGESTION="$SUGGESTION mcp__oio__file_write"
      echo "$BASH_CMD_P1" | grep -qP '(sed|perl).*-i' && SUGGESTION="$SUGGESTION mcp__oio__file_edit"
      echo "$BASH_CMD_P1" | grep -qP '(>|>>|tee)' && SUGGESTION="$SUGGESTION mcp__oio__file_write / file_edit"
      echo "$BASH_CMD_P1" | grep -qP '\bln\b' && SUGGESTION="$SUGGESTION mcp__oio__file_symlink"
      echo "$BASH_CMD_P1" | grep -qP '\brsync\b' && SUGGESTION="$SUGGESTION mcp__oio__file_write / file_edit (rsync 불필요 — oio가 직접 처리)"
      echo "$BASH_CMD_P1" | grep -qP '\bcat\b.*<<' && SUGGESTION="$SUGGESTION mcp__oio__file_write (heredoc → file_write content 파라미터 사용)"

      echo "{\"decision\":\"block\",\"reason\":\"🚨 Bash FS변경→oio ($SUGGESTION) (Monitor 호출도 이 가드를 거친다 — Monitor 는 Bash 와 같은 권한 규칙과 가드가 적용된다. 단독 대기·확인 명령 sleep N·test·[ ]·pgrep·echo·date·true·false 와 그것만으로 된 until/while 대기 루프, ;·&&·|| 사슬은 통과한다. 리다이렉트·명령 치환·파이프·그 밖의 명령이 섞이면 막힌다. 긴 작업은 setsid nohup 으로 띄운 뒤 timeout 85 bash_exec 폴링으로 확인한다)\"}" ; true
      exit 2
    fi
    # P1-Z: catch-all — 화이트리스트 미통과 + P1-A/B 미매칭 → bash_exec 강제
    echo '{"decision":"block","reason":"🚨 Bash→oio bash_exec (Monitor 호출도 이 가드를 거친다 — Monitor 는 Bash 와 같은 권한 규칙과 가드가 적용된다. 단독 대기·확인 명령 sleep N·test·[ ]·pgrep·echo·date·true·false 와 그것만으로 된 until/while 대기 루프, ;·&&·|| 사슬은 통과한다. 리다이렉트·명령 치환·파이프·그 밖의 명령이 섞이면 막힌다. 긴 작업은 setsid nohup 으로 띄운 뒤 timeout 85 bash_exec 폴링으로 확인한다)"}' ; true
    exit 2
  fi
fi

# --- UUID 결정 ---
source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/session_id.sh"
if ! resolve_uuid "$INPUT" 2>/dev/null; then
  # UUID 결정 불가 시 안전 통과 (세션 연결 전 도구 호출 등 edge case)
  exit 0
fi
[[ -z "$UUID" ]] && exit 0
# P8: PIPELINE_UUID 환경에서 MY_UUID 미설정 보완 — resolve_uuid가 PIPELINE_UUID 브랜치에서 MY_UUID를 설정하지 않으므로
# session_id JSON 필드에서 직접 추출하여 MY_UUID 보장
if [[ -z "${MY_UUID:-}" ]]; then
  _RAW_SID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null | tr -d '[:space:]')
  if [[ -n "$_RAW_SID" ]]; then
    MY_UUID="$_RAW_SID"
    export MY_UUID
  fi
fi

# --- 헬퍼: 방안C 메인 세션 판별 (session_id vs state UUID 비교) ---
# state 파일에 기록된 UUID와 현재 세션 UUID 비교하여 메인 여부 판별
# 팀에이전트는 session_id가 state 소유자(메인)와 다르므로 false 반환
_is_main_by_state_sid() {
  local _STATE_FILE="${1:-}"
  if [[ -z "$_STATE_FILE" || ! -f "$_STATE_FILE" ]]; then
    # 2차 판별: 자기 UUID 디렉토리에 state 파일도 없으면 서브에이전트 (L-269)
    if [[ ! -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${MY_UUID}/state" ]]; then
      return 1  # 서브에이전트 확정 → 수정 허용
    fi
    return 0  # 판별 불가 → 메인 간주
  fi
  local _STATE_SID
  _STATE_SID=$(awk '{print $2}' "$_STATE_FILE" 2>/dev/null | tr -d '\r' || echo "")
  local _RAW_SESSION="$MY_UUID"
  # UUID가 비어있으면 추가 판별
  if [[ -z "$_RAW_SESSION" ]]; then return 0; fi  # UUID 결정 실패 → fail-closed (메인 간주, 차단 우선)
  if [[ -z "$_STATE_SID" ]]; then
    # state 파일에 UUID 미기록 → MY_UUID 디렉토리가 state 파일 소유자인지 확인
    # state 파일이 session-env/${MY_UUID}/state가 아니면 → 팀에이전트
    local _MY_STATE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${MY_UUID}/state"
    if [[ "$_STATE_FILE" != "$_MY_STATE" ]]; then
      return 1  # 팀에이전트 (state 파일 소유자 ≠ 나)
    fi
    return 0  # state 파일이 내 디렉토리 → 메인 간주
  fi
  # full UUID 매칭: 같으면 메인(0), 다르면 팀에이전트(1)
  if [[ "$_RAW_SESSION" == "$_STATE_SID"* ]] || [[ "$_STATE_SID" == "$_RAW_SESSION"* ]]; then
    return 0  # 메인
  fi
  return 1  # 팀에이전트
}

# --- P4: PIPELINE_UUID 환경변수 기반 팀에이전트 우회 ---
# 팀에이전트 프롬프트에 PIPELINE_UUID={UUID}가 주입되면 환경변수로 전파됨
# PIPELINE_UUID가 있고 현재 세션과 다르면 → 팀에이전트 확정 → 수정 허용
if [[ -n "${PIPELINE_UUID:-}" && "${PIPELINE_UUID:-}" != "$MY_UUID" ]]; then
  # PIPELINE_UUID가 존재하고 내 UUID와 다름 → 팀에이전트 확정
  UUID="$PIPELINE_UUID"
  SID="$UUID"  # 하위 호환
  export UUID SID
  # 탐색 도구는 상단 조기 통과에서 이미 처리됨 → 여기는 수정 도구만 도달
  # 팀에이전트도 NTFS 직접 수정은 차단 (L-014)
  # path 파라미터 보강: mcp__oio__file_write/file_edit 등의 실제 파라미터명은 path이며
  # file_path만 읽으면 이 블록을 우회할 수 있었다(실측 확인) — F-ISO-2와 동일 관용구로 통일.
  FILE_PATH_TEAM=$(echo "$INPUT" | jq -r '.tool_input.path // .tool_input.file_path // .tool_input.filepath // empty' 2>/dev/null || echo "")
  # Fix 3 (L-NEW): Serena relative_path도 NTFS 경로 체크 (file_path 체크만으론 우회 가능)
  _REL_PATH_TEAM=$(echo "$INPUT" | jq -r '.tool_input.relative_path // empty' 2>/dev/null || echo "")
  if echo "$FILE_PATH_TEAM" | grep -qP '^/mnt/[c-z]/' || \
     echo "$_REL_PATH_TEAM" | grep -qP '^/mnt/[c-z]/'; then
    source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/write_error.sh"
    _BLOCKED_PATH="${FILE_PATH_TEAM:-$_REL_PATH_TEAM}"
    log_hook_error "HOOK_BLOCK_NTFS_DIRECT" "$TOOL_NAME" "팀에이전트 NTFS 직접 수정 시도($_BLOCKED_PATH)" "$SESSION_ID"
    _NTFS_REASON="🚨 NTFS 직접 수정 금지! 팀에이전트도 rsync 방식 필수 (L-014)."
    if echo "$_BLOCKED_PATH" | grep -qF '/plans/'; then
      _NTFS_REASON="${_NTFS_REASON} → 산출물은 session-env/${PIPELINE_UUID:-UUID}/plans/ 에 작성하세요."
    fi
    _FW_REDIRECT=1   # [사이클194 g①] 셸 대안(rsync)을 안내하는 차단 — F-NO-BYPASS 대상 아님
    echo "{\"decision\":\"block\",\"reason\":\"${_NTFS_REASON}\"}" ; true
    exit 2
  fi
  exit 0  # NTFS 아니면 허용
fi

# (탐색 도구 분기는 상단 조기 통과로 이동됨 — Grep/Glob/Serena 탐색은 여기 도달 불가)

# ===== 수정 도구 분기 (ok_check + ok_full_edit_guard + team_dir_guard 기능) =====

# --- 0. .claude/ 하위 경로 전역 허용 (파이프라인/에이전트 무관) ---
# .claude/ 하위는 파이프라인 상태, 메인/팀에이전트 구분 없이 항상 oio 허용
# teams/ rm -rf 보호(아래 1번)만 예외로 별도 차단
# F-NEW-1: symlink traversal 방어 — .claude/ 경로라도 NTFS 가리키면 차단
if [[ "$TOOL_NAME" == mcp__oio__* ]]; then
  _CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  _OIO_PATH=$(echo "$INPUT" | jq -r '.tool_input.path // empty' 2>/dev/null || echo "")
  # F-NEW-1-EXC (2026-08-01): CLAUDE_CONFIG_DIR가 세션 임시 디렉토리(/tmp/cc-*)인 구성에서
  # projects/*/memory/ 하위(MEMORY.md 등 자동메모리)는 정당한 NTFS symlink이므로 예외 허용
  if [[ "$_OIO_PATH" == "$_CLAUDE_DIR"/*/memory/*.md ]]; then
    exit 0
  fi
  if [[ "$_OIO_PATH" == "$_CLAUDE_DIR"/* || "$_OIO_PATH" == /home/*/.claude/* ]]; then
    _RESOLVED_PATH2=$(realpath -m "$_OIO_PATH" 2>/dev/null || echo "$_OIO_PATH")
    # [사이클215 F-NEW-1-LNK] 링크 노드 자체 조작은 realpath 판정 생략(위 분기와 동일)
    if echo "$_RESOLVED_PATH2" | grep -qP '^/mnt/[c-z]/' && ! _wg_fnew1_link_node "$_OIO_PATH"; then
      echo '{"decision":"block","reason":"🚫 [F-NEW-1] .claude/ 심볼릭링크가 NTFS 경로를 가리킵니다 — symlink traversal 차단 (P4 이후 섹션)."}'
      exit 2
    fi
    # F-ISO-1 (세션 격리 §(a) 강화): session-env/<UUID>/ 세그먼트가 있으면 그 UUID가
    # 자기 UUID(MY_UUID)일 때만 통과. session-env 아닌 공용 .claude/ 경로는 종전대로 허용.
    # base(CLAUDE_CONFIG_DIR/HOME) 무관하게 경로 문자열의 session-env/<UUID>/ 세그먼트만 본다.
    _ISO_TARGET_UUID=$(echo "$_OIO_PATH" | grep -oP 'session-env/\K[^/]+' | head -1)
    if [[ -n "$_ISO_TARGET_UUID" && -n "${MY_UUID:-}" && "$_ISO_TARGET_UUID" != "$MY_UUID" ]]; then
      echo "{\"decision\":\"block\",\"reason\":\"🚫 [F-ISO-1] 타 세션 session-env 경로 쓰기 차단 — 세션 격리 불변식 §(a) 위반. 대상 UUID(${_ISO_TARGET_UUID})가 자기 UUID(${MY_UUID:-미상})와 다릅니다.\"}"
      exit 2
    fi
    exit 0  # .claude/ 하위 oio 전역 허용 (session-env는 자기 UUID 한정)
  fi
fi

# --- 1. ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams/ 보호 (team_dir_guard 기능 흡수) ---
COMMAND_CHECK=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")
# Bash 도구는 이 matcher에 걸리지 않으나 안전장치로 검사
if [[ -n "$COMMAND_CHECK" ]]; then
  if echo "$COMMAND_CHECK" | tr ';' '\n' | grep -vE '^\s*(#|echo\s|printf\s|grep\s|cat\s|read\s)' | grep -qP '\brm\s+(-\S+\s+)*\S*\.claude/(teams|tasks)/'; then
    STATE_WORD=$(state_read "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/state" | awk '{print $1}')  # C-01: flock 보호
    STATE_WORD=${STATE_WORD:-IDLE}
    # Fix 10 (L-NEW): __LOCK_FAIL__ → fail-closed (비IDLE 간주하여 차단)
    [[ "$STATE_WORD" == "__LOCK_FAIL__" ]] && STATE_WORD="ACTIVE_UNKNOWN"
    if [[ "$STATE_WORD" != "IDLE" ]]; then
      source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/write_error.sh"
      log_hook_error "HOOK_BLOCK_TEAM_DIR_RM" "Bash" "L-138: 팀/태스크 디렉토리 rm -rf 시도 (state=${STATE_WORD})" "$SESSION_ID"
      echo "{\"decision\":\"block\",\"reason\":\"팀/태스크 디렉토리 rm -rf 차단 (L-138). state=${STATE_WORD} (IDLE 아님). ofinish에서는 TeamDelete를 사용하세요.\"}" ; true
      exit 2
    fi
  fi
fi

# --- 2. 파이프라인 활성 상태 판단 ---
STATE_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/state"
PIPELINE_STATE="IDLE"
SESSION_STATE=$(state_read "$STATE_FILE" | awk '{print $1}')  # C-01: flock 보호
SESSION_STATE=${SESSION_STATE:-IDLE}
# Fix 10 개선 (L-NEW): __LOCK_FAIL__ 재시도 → 3회 실패 시 IDLE fallback (OK 강제 금지)
# 이유: lock 파일 잔류로 flock 타임아웃 발생 시 OK 강제 전환이 전체 oio 도구를 영구 차단하는 버그 (2026-04-15)
# 변경: fail-closed(OK) → 재시도 3회 후 fail-open(IDLE)으로 전환
if [[ "$SESSION_STATE" == "__LOCK_FAIL__" ]]; then
  _RETRY=0
  while [[ "$SESSION_STATE" == "__LOCK_FAIL__" && "$_RETRY" -lt 3 ]]; do
    sleep 0.3
    SESSION_STATE=$(state_read "$STATE_FILE" | awk '{print $1}')
    SESSION_STATE=${SESSION_STATE:-IDLE}
    (( _RETRY++ )) || true
  done
  # 3회 재시도 후에도 LOCK_FAIL → IDLE fallback (OK 강제 금지)
  if [[ "$SESSION_STATE" == "__LOCK_FAIL__" ]]; then
    SESSION_STATE="IDLE"
  fi
fi

case "$SESSION_STATE" in
  PLAN|DEV|TEST)
    # Phase B (L-431): stage OK 제거 — PLAN+classification=OK가 ok 진입 단계 표현
    PIPELINE_STATE="$SESSION_STATE"
    ;;
  OK)
    # Phase B 호환성 fallback: state=OK 잔존 시 PLAN과 동일 처리 (회귀 보호)
    # 다른 활성 세션이 마이그레이션 전 상태로 남아 있을 경우의 안전망
    PIPELINE_STATE="PLAN"
    ;;
  DONE|FINISH)
    PIPELINE_STATE="$SESSION_STATE"
    ;;
  EARLY_TERM|ERROR)
    # Finding 4 (L-NEW): EARLY_TERM/ERROR는 의도적으로 IDLE로 fall-through
    # → 복구 경로에서 메인이 직접 상태 파일 접근 가능 (팀에이전트 미할당 상태)
    # PIPELINE_STATE는 IDLE 유지 (변경 없음)
    ;;
  # IDLE은 파이프라인 비활성 (PIPELINE_STATE=IDLE 유지)
esac

if [[ "$PIPELINE_STATE" != "IDLE" ]]; then
  # --- F-ESCAPE-1 (L-971): 계약·마커 "생성" 경로는 어느 상태에서도 통과한다 ---
  # 배경 (2026-09-06 사이클87 실사고):
  #   ok 로딩 직후 state=PLAN + classification=OK 가 되자 아래 L-171 차단이 메인의 쓰기를
  #   전면 봉쇄했다. 그런데 그 차단을 푸는 데 필요한 것이 바로 evidence/ok_started 마커였다.
  #   ⇒ 게이트가 요구하는 증거를, 그 게이트가 막은 수단으로만 만들 수 있는 ★닫힌 고리★.
  #   결과: 마커를 못 써 Stop.sh 가 PLAN→IDLE 로 롤백(11:51:55).
  # 원칙: 게이트는 "자기가 요구하는 증거의 생성 수단"을 절대 막아서는 안 된다.
  #   L-969("탈출로를 먼저 확보하고 가드를 걸어라")의 같은 형태 재발이다.
  # 범위: 자기 세션 session-env/<UUID>/ 하위의 evidence·work·logs·plans + goal.json 만.
  #   ★state/classification/team_name/status/entry_tier 메타 파일은 제외★ —
  #   그건 line 897 Fix 3 이 담당하며 session_state/state_machine.sh 경유가 정본이다.
  #   NTFS(/mnt/[c-z]/) 경로는 심볼릭 우회 방지를 위해 예외에서 제외한다.
  _ESC_PATH=$(echo "$INPUT" | jq -r '.tool_input.path // .tool_input.file_path // .tool_input.filepath // empty' 2>/dev/null || echo "")
  if [[ -n "$_ESC_PATH" && -n "${UUID:-}" ]]; then
    if ! echo "$_ESC_PATH" | grep -qP '/mnt/[c-z]/'; then
      if echo "$_ESC_PATH" | grep -qP "session-env/${UUID}/(evidence|work|logs|plans)/|session-env/${UUID}/goal\.json$"; then
        exit 0
      fi
    fi
  fi

  # L-171: 메인(팀 리더) 세션에서 직접 Edit/Write 차단
  # (Bash 허용 블록 제거: P1에서 이미 전면 차단되므로 도달 불가 — 죽은 코드)
  # state가 IDLE이 아니면 메인 직접 수정 전면 차단
  if _is_main_by_state_sid "$STATE_FILE"; then
    source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/write_error.sh"
    log_hook_error "HOOK_BLOCK_MAIN_DIRECT_EDIT" "$TOOL_NAME" "L-171: 파이프라인 활성(${PIPELINE_STATE}) 중 메인 직접 수정 시도" "$SESSION_ID"
    echo '{"decision":"block","reason":"❌ [L-171] 파이프라인 활성 중 — 메인 직접 파일 수정 금지! 팀에이전트에 위임하세요."}' ; true
    exit 2
  fi

  # ok 에이전트 직접 수정 차단 (ok_full_edit_guard 기능 — 안전장치)
  # classification 값: v4.3 기준 O1~O5 (구 medium/full 폐기)
  AGENT_NAME=$(echo "$INPUT" | jq -r '.agent_name // empty' 2>/dev/null || echo "")
  if echo "$AGENT_NAME" | grep -qi "^ok"; then
    CLASSIFICATION=$(cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/classification" 2>/dev/null || echo "")
    if [[ "$CLASSIFICATION" =~ ^O[345]$ ]]; then
      source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/write_error.sh"
      log_hook_error "HOOK_BLOCK_OK_DIRECT_EDIT" "$TOOL_NAME" "ok가 ${CLASSIFICATION} 스케일에서 직접 $TOOL_NAME 호출 (agent: $AGENT_NAME)" "$SESSION_ID"
      echo "{\"decision\":\"block\",\"reason\":\"❌ ok 에이전트 직접 수정 금지: O3/O4/O5 스케일 작업입니다. 팀에이전트(odev)에 위임하세요. (v4.3: ok는 스킬이므로 이 차단은 안전장치)\"}" ; true
      exit 2
    fi
  fi

  # 파이프라인 활성 + 팀에이전트 → 허용
  :
fi

# --- 3. Edit/Write 전면 차단 — oio MCP 사용 강제 (L-292) ---
# oio MCP가 NTFS rsync, Lock, BOM/CRLF를 모두 내부 처리하므로
# Claude Code 네이티브 Edit/Write/Notebookedit는 모든 경로에서 차단
case "$TOOL_NAME" in
  Edit|Write|Notebookedit)
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || echo "")
    source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/write_error.sh"
    log_hook_error "HOOK_BLOCK_EDIT_WRITE_ALL" "$TOOL_NAME" "Edit/Write 전면 차단 → oio 사용 필수 ($FILE_PATH)" "$SESSION_ID"
    echo '{"decision":"block","reason":"🚨 Edit/Write→oio file_edit/file_write"}' ; true
    exit 2
    ;;
esac

# --- 4. 팀에이전트 위임 강제 (v4.3: O3/O4/O5 = 팀에이전트 필수) ---
# classification 값: v4.3 기준 O1~O5 (구 medium/full 폐기)
CLASSIFICATION=$(cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/classification" 2>/dev/null || echo "unknown")
if [[ "$CLASSIFICATION" =~ ^O[345]$ ]]; then
  if [[ ! -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/team_name" ]]; then
    source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/write_error.sh"
    log_hook_error "HOOK_BLOCK_NO_AGENT" "$TOOL_NAME" "${CLASSIFICATION} 작업에서 팀에이전트 미생성 상태로 메인 직접 수정 시도" "$SESSION_ID"
    echo "{\"decision\":\"block\",\"reason\":\"❌ ${CLASSIFICATION} 작업은 팀에이전트 위임 필수! TeamCreate 먼저 실행하세요. 메인이 직접 Edit/Write 금지.\"}" ; true
    exit 2
  fi
fi

exit 0
