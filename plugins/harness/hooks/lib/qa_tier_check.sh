#!/bin/bash
# 프로젝트가 선언한 QA(운영 데이터 연계) 단계 시험의 완료 마커를 DONE 전이 직전에 검사하는 공용 라이브러리
#
# 사용처: hooks/PreToolUse_done_gate.sh "4-5. QA 단계 검사" 블록 (DONE_GATE_MODE=marker 경로 포함).
# 범용 원칙: 이 파일에는 특정 프로젝트명·경로·포트를 쓰지 않는다.
#   프로젝트가 <프로젝트>/.claude/qa_tier.json 을 두었을 때만 동작하고, 선언이 없으면 아무 일도 하지 않는다.
#
# 선언 파일 형식 (qa_tier.json):
#   {"version":1, "enabled":true, "label":"...", "applies_tiers":["O3","O4","O5"],
#    "marker":"evidence/qa_test_done", "skip_reason_min_len":10, "doc":"..."}
#   - marker 는 세션 디렉터리 기준 상대경로다(절대경로·'..' 금지).
#   - applies_tiers 생략 시 ["O3","O4","O5"], marker 생략 시 evidence/qa_test_done, skip_reason_min_len 생략 시 10.
#   - [c184] 선택 필드 scope — 있으면 "이번 사이클 변경 파일 중 QA 대상 소스가 0건"일 때 마커 없이 면제한다(qa_scope_exempt).
#       "scope": {"requires_qa": ["App/", "Server/", "x/file.html"],   ← 저장소 루트 기준. 끝이 / 면 디렉터리 접두사, 아니면 파일 1개
#                 "exclude": ["*/bin/", "*.md", "App/assets/"]}        ← '*/X/' = 어느 깊이든 X 디렉터리, '/' 로 끝나면 접두사, 그 외 bash glob
#     선언이 없으면 종전 동작 그대로(마커 요구). 형식 오류·git 실패·시간 초과·파싱 불가·사이클 중 커밋은 전부 마커 요구(fail-closed).
#   - [c214 R5] 선택 필드 side_write_sources — 시험 중 클라이언트·서버가 스스로 남기는 부수 쓰기 경로(오류 자동 전송·푸시 토큰 등).
#       "side_write_sources": [{"id":"error_report", "table":"t_ErrorReport", "trigger":"클라이언트 오류 자동 전송"}, ...]
#       id·table 은 [A-Za-z0-9_.-] 만 허용(형식 오류는 fail-closed). 없거나 빈 배열이면 종전 동작.
#     선언이 있으면 PASS·PARTIAL 마커가 선언 전부를 side_writes= 줄로 다뤄야 한다(SKIPPED 는 사용자 판단이라 무변경).
#       side_writes=<id>:snapshot|suppressed[,<id>:...]
#       snapshot   → before 스냅샷 .state 안에 그 table 이름의 키가 있어야 한다(키 = table, 'table@…', '….table' 형태 인정).
#       suppressed → suppress_basis=<억제 방법·원복, skip_reason_min_len 자 이상> 줄이 있어야 한다.
#
# 사용자 지시(2026-10-14, c184): "앞으로도 이런 케이스는 QA 생략하자" — 배포 도구만 바뀌고 앱·서버 소스가 무변경인 사이클.
# 마커 형식 (${SESSION_DIR}/<marker>):
#   1줄: PASS|PARTIAL|SKIPPED <ISO8601>
#   PASS|PARTIAL : before=<스냅샷 JSON>  after=<스냅샷 JSON>  [compare=<파일>] [excluded=<ID,...>]
#                  ⇒ 두 스냅샷의 .state 가 jq -S 기준으로 같아야 통과한다(불일치 PARTIAL 은 차단 — fail-closed).
#   SKIPPED      : reason=<면제 근거, skip_reason_min_len 자 이상>
#                  (사용자 지시 2026-10-27 15:53 — 면제는 에이전트가 판단해 기록한다. 앱·서버 소스 변경이 없거나 QA 시험이
#                   해당되지 않을 때 화면 질문 없이 SKIPPED+근거를 남긴다. 운영 배포 승인은 별도 유지 대상이다. 판정 로직은 무변경)
#
# 시간 예산: jq 3~5회 + stat 3~4회. 무거운 명령(git·python·네트워크) 금지(L-1204).
#   예외 1건 — qa_scope_exempt 의 git 3회(rev-parse·log -1·status, 각각 timeout ${QA_SCOPE_GIT_TIMEOUT:-5}초).
#   사유: 면제 판정에는 "이번 사이클에 바뀐 파일"이 필요하고, 에이전트가 쓰는 목록은 위조 가능해 물리 규칙이 되지 못한다.
#   승인: c184 team-lead 2026-10-14 15:0x KST(이 함수 한정·timeout 필수). scope 를 선언한 프로젝트에서만 돈다.
#   실측(Mars NTFS 저장소, 2026-10-14): git status --porcelain 1.6~2.3초. done_gate 예산 13초(open)·Hd3 경로 timeout 10초 안.

# qa_tier_decl_path <input_json>
#   프로젝트 디렉터리 = 입력 .cwd → $CLAUDE_PROJECT_DIR → $PWD 순(앞의 값이 디렉터리일 때 채택).
#   그 아래 .claude/qa_tier.json 이 있으면 경로를 출력하고 rc=0, 없으면 rc=1(무동작).
#   QA_PROJECT_DIR·QA_DECL 전역을 설정하므로 $( ) 없이 직접 호출하라(서브셸이면 전역이 사라진다).
qa_tier_decl_path() {
  local _in="${1:-}" _cwd="" _d
  if [[ -n "$_in" ]] && command -v jq >/dev/null 2>&1; then
    _cwd=$(printf '%s' "$_in" | jq -r '.cwd // empty' 2>/dev/null) || _cwd=""
  fi
  for _d in "$_cwd" "${CLAUDE_PROJECT_DIR:-}" "${PWD:-}"; do
    [[ -n "$_d" && -d "$_d" ]] || continue
    if [[ -f "${_d}/.claude/qa_tier.json" ]]; then
      QA_PROJECT_DIR="$_d"
      QA_DECL="${_d}/.claude/qa_tier.json"
      printf '%s\n' "${_d}/.claude/qa_tier.json"
      return 0
    fi
    # 첫 번째로 실존하는 디렉터리에서만 찾는다(다른 프로젝트 선언을 잘못 집지 않도록)
    return 1
  done
  return 1
}

# qa_tier_load <decl>
#   선언을 1회 jq 로 읽어 QA_ENABLED / QA_TIERS / QA_MARKER_REL / QA_SKIP_MIN / QA_LABEL / QA_SIDE_WRITES 를 설정한다.
#   QA_SIDE_WRITES = "id:table,id:table" (선언 없음 = 빈 값). jq 출력에서는 '-' 로 자리를 지킨다(탭 연속 붕괴 방지).
#   rc 0=정상, 2=파싱 실패·형식 오류(QA_FAIL_REASON 설정 — 선언 프로젝트에 한해 fail-closed)
qa_tier_load() {
  local _decl="$1" _out
  QA_FAIL_REASON=""
  QA_SIDE_WRITES=""
  _out=$(jq -r '
    if type != "object" then error("최상위가 객체가 아님") else . end
    | [ (if (has("enabled") | not) or .enabled == true then "1" else "0" end),
        ((.applies_tiers // ["O3","O4","O5"]) | if type=="array" then map(tostring|ascii_upcase)|join(",") else error("applies_tiers 가 배열이 아님") end),
        ((.marker // "evidence/qa_test_done") | tostring),
        ((.skip_reason_min_len // 10) | tostring),
        ((.label // "QA") | tostring | if . == "" then "QA" else . end),
        ((.side_write_sources // []) | if type != "array" then error("side_write_sources 가 배열이 아님")
          else map(if type == "object" and ((.id // "") | type) == "string" and ((.table // "") | type) == "string"
                      and (.id | test("^[A-Za-z0-9_.-]+$")) and (.table | test("^[A-Za-z0-9_.-]+$"))
                   then .id + ":" + .table else error("side_write_sources 항목 형식 오류") end)
               | if length == 0 then "-" else join(",") end end)
      ] | join("\t")' "$_decl" 2>/dev/null) || {
    QA_FAIL_REASON="선언 파일 JSON 파싱 실패 또는 형식 오류(side_write_sources 는 {id,table} 객체 배열, [A-Za-z0-9_.-]): ${_decl}"
    return 2
  }
  IFS=$'\t' read -r QA_ENABLED QA_TIERS QA_MARKER_REL QA_SKIP_MIN QA_LABEL QA_SIDE_WRITES <<< "$_out"
  [[ "$QA_SIDE_WRITES" == "-" ]] && QA_SIDE_WRITES=""
  if [[ -z "$QA_MARKER_REL" || "$QA_MARKER_REL" == /* || "$QA_MARKER_REL" == *..* ]]; then
    QA_FAIL_REASON="선언 파일의 marker 값이 잘못됐다(세션 디렉터리 기준 상대경로여야 하며 '..' 금지): '${QA_MARKER_REL}'"
    return 2
  fi
  [[ "$QA_SKIP_MIN" =~ ^[0-9]+$ ]] || {
    QA_FAIL_REASON="선언 파일의 skip_reason_min_len 이 정수가 아니다: '${QA_SKIP_MIN}'"
    return 2
  }
  return 0
}

# qa_tier_applies <class>   (qa_tier_load 이후 호출)
#   enabled=true ∧ class ∈ applies_tiers 이면 rc 0, 아니면 rc 1.
qa_tier_applies() {
  local _cls="${1:-}"
  [[ "${QA_ENABLED:-0}" == "1" ]] || return 1
  [[ -n "$_cls" ]] || return 1
  [[ ",${QA_TIERS}," == *",${_cls},"* ]]
}

# 마커 안의 경로를 절대경로로 만든다(상대경로는 프로젝트 디렉터리 기준).
_qa_abs() {
  local _p="$1"
  if [[ "$_p" == /* || -z "${QA_PROJECT_DIR:-}" ]]; then printf '%s' "$_p"; else printf '%s' "${QA_PROJECT_DIR}/${_p}"; fi
}

# qa_marker_valid <session_dir> <pst>   (qa_tier_load 이후 호출)
#   rc 0=유효, 1=무효(QA_FAIL_REASON 설정). QA_MARKER_PATH 를 설정한다.
qa_marker_valid() {
  local _sd="$1" _pst="${2:-}" _m _first _kind _mt _reason _before _after _bm _am _sb _sa
  QA_FAIL_REASON=""
  _m="${_sd}/${QA_MARKER_REL}"
  QA_MARKER_PATH="$_m"
  [[ "$_pst" =~ ^[0-9]+$ ]] || _pst=""

  if [[ ! -e "$_m" ]]; then QA_FAIL_REASON="마커 파일 없음"; return 1; fi
  if ! grep -q '[^[:space:]]' "$_m" 2>/dev/null; then QA_FAIL_REASON="빈 마커(touch 마커는 증거가 아니다)"; return 1; fi
  if [[ -n "$_pst" ]]; then
    _mt=$(stat -c %Y "$_m" 2>/dev/null) || _mt=0
    if [[ "$_mt" -lt "$_pst" ]]; then
      QA_FAIL_REASON="마커 mtime(${_mt}) < pipeline_start_time(${_pst}) — 이전 사이클 잔존 마커"; return 1
    fi
  fi

  _first=$(head -n 1 "$_m" 2>/dev/null | tr -d '\r')
  if [[ ! "$_first" =~ ^(PASS|PARTIAL|SKIPPED)\ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2} ]]; then
    QA_FAIL_REASON="첫 줄 형식 오류 '${_first:0:60}' — 'PASS|PARTIAL|SKIPPED <ISO8601>' 이어야 한다(FAIL 은 통과 불가)"; return 1
  fi
  _kind="${BASH_REMATCH[1]}"

  if [[ "$_kind" == "SKIPPED" ]]; then
    _reason=$(grep -m1 '^reason=' "$_m" 2>/dev/null | tr -d '\r') ; _reason="${_reason#reason=}"
    _reason="${_reason#"${_reason%%[![:space:]]*}"}"
    if [[ ${#_reason} -lt ${QA_SKIP_MIN:-10} ]]; then
      QA_FAIL_REASON="SKIPPED 인데 reason= 사유가 없거나 짧다(${#_reason}자 < ${QA_SKIP_MIN:-10}자)"; return 1
    fi
    QA_RESULT_KIND="SKIPPED"
    return 0
  fi

  _before=$(grep -m1 '^before=' "$_m" 2>/dev/null | tr -d '\r'); _before=$(_qa_abs "${_before#before=}")
  _after=$(grep -m1 '^after=' "$_m" 2>/dev/null | tr -d '\r');  _after=$(_qa_abs "${_after#after=}")
  if [[ "$_before" == "${QA_PROJECT_DIR:-}/" || -z "${_before}" || ! -f "$_before" ]]; then
    QA_FAIL_REASON="before= 스냅샷 파일이 없다: '${_before}'"; return 1
  fi
  if [[ "$_after" == "${QA_PROJECT_DIR:-}/" || -z "${_after}" || ! -f "$_after" ]]; then
    QA_FAIL_REASON="after= 스냅샷 파일이 없다: '${_after}'"; return 1
  fi
  _sb=$(jq -cS 'if type=="object" and has("state") then .state else error("no state") end' "$_before" 2>/dev/null) || {
    QA_FAIL_REASON="before 스냅샷이 JSON 이 아니거나 .state 가 없다: ${_before}"; return 1; }
  _sa=$(jq -cS 'if type=="object" and has("state") then .state else error("no state") end' "$_after" 2>/dev/null) || {
    QA_FAIL_REASON="after 스냅샷이 JSON 이 아니거나 .state 가 없다: ${_after}"; return 1; }
  if [[ "$_sb" != "$_sa" ]]; then
    QA_FAIL_REASON="${_kind} 이지만 전후 스냅샷 .state 가 다르다 — 원복 불완전(불일치는 통과 불가, 면제는 사용자 판단의 SKIPPED 로만)"; return 1
  fi
  _bm=$(stat -c %Y "$_before" 2>/dev/null) || _bm=0
  _am=$(stat -c %Y "$_after" 2>/dev/null) || _am=0
  if [[ "$_am" -lt "$_bm" ]]; then
    QA_FAIL_REASON="after mtime(${_am}) < before mtime(${_bm}) — 스냅샷 순서가 뒤바뀜"; return 1
  fi
  if [[ -n "$_pst" && "$_bm" -lt "$_pst" ]]; then
    QA_FAIL_REASON="before mtime(${_bm}) < pipeline_start_time(${_pst}) — 이전 사이클 스냅샷"; return 1
  fi
  _qa_side_writes_valid "$_m" "$_before" "$_kind" || return 1
  QA_RESULT_KIND="$_kind"
  return 0
}

# _qa_side_writes_valid <marker> <before.json> <kind>   [c214 R5]
#   선언(QA_SIDE_WRITES)이 비면 rc 0(종전 동작). 있으면 마커 side_writes= 가 선언 id 전부를 snapshot|suppressed 로 다뤄야 한다.
#   snapshot 은 before .state 의 키 중 table 이름(=table, table@…, ….table, ….table@…)이 있어야, suppressed 는 suppress_basis= 가 있어야 한다.
#   jq 는 snapshot 대상이 있을 때만 1회. rc 1 이면 QA_FAIL_REASON 설정.
_qa_side_writes_valid() {
  local _m="$1" _before="$2" _kind="$3" _sw _basis _ent _id _tb _mode _snap_tabs="" _missing=""
  local -A _modes=()
  [[ -n "${QA_SIDE_WRITES:-}" ]] || return 0
  _sw=$(grep -m1 '^side_writes=' "$_m" 2>/dev/null | tr -d '\r'); _sw="${_sw#side_writes=}"; _sw="${_sw//[[:space:]]/}"
  if [[ -z "$_sw" ]]; then
    QA_FAIL_REASON="${_kind} 마커에 side_writes= 줄이 없다 — 선언된 부수 쓰기 경로(${QA_SIDE_WRITES})를 snapshot|suppressed 로 각각 밝혀야 한다"; return 1
  fi
  local IFS=','
  for _ent in $_sw; do
    [[ -z "$_ent" ]] && continue
    if [[ ! "$_ent" =~ ^([A-Za-z0-9_.-]+):(snapshot|suppressed)$ ]]; then
      QA_FAIL_REASON="side_writes= 항목 형식 오류 '${_ent:0:40}' — '<id>:snapshot|suppressed' 이어야 한다"; return 1
    fi
    _modes["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
  done
  for _ent in $QA_SIDE_WRITES; do
    _id="${_ent%%:*}"; _tb="${_ent#*:}"; _mode="${_modes[$_id]:-}"
    case "$_mode" in
      snapshot)   _snap_tabs+="${_snap_tabs:+,}${_id}:${_tb}" ;;
      suppressed) ;;
      *)          _missing+="${_missing:+,}${_id}" ;;
    esac
  done
  unset IFS
  if [[ -n "$_missing" ]]; then
    QA_FAIL_REASON="side_writes= 가 선언된 부수 쓰기 경로를 다루지 않았다: ${_missing} (선언 ${QA_SIDE_WRITES})"; return 1
  fi
  if [[ "$_sw" == *":suppressed"* ]]; then
    _basis=$(grep -m1 '^suppress_basis=' "$_m" 2>/dev/null | tr -d '\r'); _basis="${_basis#suppress_basis=}"
    _basis="${_basis#"${_basis%%[![:space:]]*}"}"
    if [[ ${#_basis} -lt ${QA_SKIP_MIN:-10} ]]; then
      QA_FAIL_REASON="side_writes 에 suppressed 가 있는데 suppress_basis= (억제 방법·원복)가 없거나 짧다(${#_basis}자 < ${QA_SKIP_MIN:-10}자)"; return 1
    fi
  fi
  if [[ -n "$_snap_tabs" ]]; then
    _missing=$(jq -r --arg t "$_snap_tabs" '
      [.state | .. | objects | keys[]] as $k
      | [ $t | split(",")[] | select(length > 0)
          | (split(":")) as $p | ($p[1:] | join(":")) as $tb
          | select(([$k[] | select(. == $tb or startswith($tb + "@") or endswith("." + $tb) or contains("." + $tb + "@"))] | length) == 0)
          | $p[0] + "(" + $tb + ")" ] | join(",")' "$_before" 2>/dev/null) || {
      QA_FAIL_REASON="before 스냅샷 키 판독 실패(side_writes snapshot 검사): ${_before}"; return 1; }
    if [[ -n "$_missing" ]]; then
      QA_FAIL_REASON="side_writes 를 snapshot 으로 다룬다면서 before 스냅샷에 그 표가 없다: ${_missing} — 스냅샷 대상에 넣거나 suppressed+suppress_basis 로 밝혀라"; return 1
    fi
  fi
  return 0
}

# _qa_scope_req <path>   — QA 대상(requires_qa) 경로인가. 미추적 디렉터리(끝이 /)가 대상 경로를 품고 있어도 대상으로 본다.
_qa_scope_req() {
  local _p="$1" _r
  for _r in "${_QA_SC_REQ[@]}"; do
    if [[ "$_r" == */ ]]; then
      [[ "$_p" == "$_r"* ]] && return 0
    else
      [[ "$_p" == "$_r" ]] && return 0
    fi
    [[ "$_p" == */ && "$_r" == "$_p"* ]] && return 0
  done
  return 1
}

# _qa_scope_exc <path>   — exclude 규칙에 걸리는가.
_qa_scope_exc() {
  local _p="$1" _x
  for _x in "${_QA_SC_EXC[@]}"; do
    if [[ "$_x" == \*/*/ ]]; then
      [[ "/$_p" == *"/${_x#\*/}"* ]] && return 0
    elif [[ "$_x" == */ ]]; then
      [[ "$_p" == "$_x"* ]] && return 0
    else
      # shellcheck disable=SC2053
      [[ "$_p" == $_x ]] && return 0
    fi
  done
  return 1
}

# qa_scope_exempt <session_dir> <pst>   (qa_tier_load 이후 호출)
#   이번 사이클 변경 파일 중 QA 대상(requires_qa) 소스가 0건이면 면제한다.
#   변경 파일 = git status --porcelain -z(미추적 포함, -uno 아님) 항목 중
#     · D(삭제)·R(이름 변경)의 원래 경로 → 시각과 무관하게 항상 센다
#     · M/A/??/그 밖 → mtime ≥ pst 인 것만 센다(사이클 이전부터 남은 수정은 이번 사이클 변경이 아니다). 파일이 없으면 센다.
#     · 미추적 디렉터리(?? X/)가 대상이면 그 안에 mtime ≥ pst 인 항목이 있을 때 센다.
#   HEAD 커밋 시각 ≥ pst(사이클 중 커밋)이면 커밋분을 볼 수 없으므로 판정 불가.
#   rc 0=면제 · 1=QA 대상 변경 있음 · 2=scope 미선언(종전 동작) · 3=판정 불가(fail-closed — 마커 요구)
#   QA_SCOPE_DETAIL 에 사후 감사용 요약(건수·제외 근거·대상 파일 최대 5개)을 남긴다.
qa_scope_exempt() {
  local _sd="$1" _pst="${2:-}" _cfg _to _top _hct _tmp _grc _i _ent _xy _p _mt _f
  local _n_all=0 _n_req=0 _n_exc=0 _n_out=0 _n_old=0 _hits=""
  QA_SCOPE_DETAIL=""
  [[ -n "${QA_DECL:-}" && -f "$QA_DECL" ]] || return 2
  _cfg=$(jq -r '
    if (.scope == null) then "NONE"
    elif (.scope | type) != "object" then error("scope")
    elif ((.scope.requires_qa | type) != "array") or ((.scope.requires_qa | length) == 0)
         or (((.scope.exclude // []) | type) != "array") then error("scope")
    else ((.scope.requires_qa[] | tostring | "R\t" + .), ((.scope.exclude // [])[] | tostring | "X\t" + .)) end' "$QA_DECL" 2>/dev/null) || {
    QA_SCOPE_DETAIL="scope 선언 형식 오류(requires_qa 는 비어 있지 않은 배열, exclude 는 배열) — 마커 요구"; return 3; }
  [[ "$_cfg" == "NONE" ]] && return 2
  _QA_SC_REQ=(); _QA_SC_EXC=()
  while IFS=$'\t' read -r _f _p; do
    [[ -n "$_p" ]] || continue
    case "$_f" in R) _QA_SC_REQ+=("$_p") ;; X) _QA_SC_EXC+=("$_p") ;; esac
  done <<< "$_cfg"
  [[ ${#_QA_SC_REQ[@]} -gt 0 ]] || { QA_SCOPE_DETAIL="scope.requires_qa 가 비었다 — 마커 요구"; return 3; }
  [[ "$_pst" =~ ^[0-9]+$ ]] || { QA_SCOPE_DETAIL="사이클 시작 시각을 읽지 못했다 — 변경 범위 판정 불가, 마커 요구"; return 3; }
  command -v git >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1 || {
    QA_SCOPE_DETAIL="git·timeout 없음 — 판정 불가, 마커 요구"; return 3; }
  _to="${QA_SCOPE_GIT_TIMEOUT:-5}"
  [[ "$_to" =~ ^[0-9]+(\.[0-9]+)?$ ]] || _to=5

  _top=$(GIT_OPTIONAL_LOCKS=0 timeout "$_to" git -C "${QA_PROJECT_DIR:-.}" rev-parse --show-toplevel 2>/dev/null) || _top=""
  [[ -n "$_top" && -d "$_top" ]] || { QA_SCOPE_DETAIL="git 저장소 판독 실패(rev-parse) — 판정 불가, 마커 요구"; return 3; }
  _hct=$(GIT_OPTIONAL_LOCKS=0 timeout "$_to" git -C "$_top" log -1 --format=%ct 2>/dev/null) || _hct=""
  [[ "$_hct" =~ ^[0-9]+$ ]] || { QA_SCOPE_DETAIL="HEAD 커밋 시각 판독 실패 — 판정 불가, 마커 요구"; return 3; }
  if [[ "$_hct" -ge "$_pst" ]]; then
    QA_SCOPE_DETAIL="사이클 시작(${_pst}) 이후 커밋이 있다(HEAD ${_hct}) — 커밋분 범위를 보지 않으므로 판정 불가, 마커 요구"; return 3
  fi
  _tmp=$(mktemp "${TMPDIR:-/tmp}/qa_scope.XXXXXX" 2>/dev/null) || { QA_SCOPE_DETAIL="임시파일 생성 실패 — 마커 요구"; return 3; }
  _grc=0
  GIT_OPTIONAL_LOCKS=0 timeout "$_to" git -C "$_top" status --porcelain -z --untracked-files=normal > "$_tmp" 2>/dev/null || _grc=$?
  if [[ "$_grc" -ne 0 ]]; then
    rm -f "$_tmp"
    QA_SCOPE_DETAIL="git status 실패(rc=${_grc}$([[ $_grc -eq 124 ]] && printf ' 시간 초과 %s초' "$_to")) — 판정 불가, 마커 요구"; return 3
  fi
  local -a _ents=()
  mapfile -d '' -t _ents < "$_tmp"
  rm -f "$_tmp"

  for ((_i = 0; _i < ${#_ents[@]}; _i++)); do
    _ent="${_ents[_i]}"
    [[ -z "$_ent" ]] && continue
    if [[ ${#_ent} -lt 4 || "${_ent:2:1}" != " " ]]; then
      QA_SCOPE_DETAIL="git status 항목 파싱 실패('${_ent:0:40}') — 판정 불가, 마커 요구"; return 3
    fi
    _xy="${_ent:0:2}"; _p="${_ent:3}"
    local -a _paths=("$_p|$_xy")
    if [[ "$_xy" == *R* || "$_xy" == *C* ]]; then
      _i=$((_i + 1))
      [[ "$_xy" == *R* && -n "${_ents[_i]:-}" ]] && _paths+=("${_ents[_i]}|D ")   # 이름 변경 전 경로는 삭제로 센다
    fi
    for _f in "${_paths[@]}"; do
      _p="${_f%|*}"; _xy="${_f##*|}"
      _n_all=$((_n_all + 1))
      if _qa_scope_exc "$_p"; then _n_exc=$((_n_exc + 1)); continue; fi
      if ! _qa_scope_req "$_p"; then _n_out=$((_n_out + 1)); continue; fi
      if [[ "$_xy" == *D* ]]; then
        :   # 삭제 — 항상 센다
      elif [[ "$_xy" == "??" && "$_p" == */ ]]; then
        _mt=$(timeout "$_to" find "$_top/$_p" -newermt "@$_pst" -print -quit 2>/dev/null) || {
          QA_SCOPE_DETAIL="미추적 디렉터리 검사 실패(${_p}) — 판정 불가, 마커 요구"; return 3; }
        [[ -z "$_mt" ]] && { _n_old=$((_n_old + 1)); continue; }
      elif [[ -e "$_top/$_p" ]]; then
        _mt=$(stat -c %Y "$_top/$_p" 2>/dev/null) || _mt=""
        [[ "$_mt" =~ ^[0-9]+$ ]] || { QA_SCOPE_DETAIL="mtime 판독 실패(${_p}) — 판정 불가, 마커 요구"; return 3; }
        [[ "$_mt" -lt "$_pst" ]] && { _n_old=$((_n_old + 1)); continue; }
      fi
      _n_req=$((_n_req + 1))
      [[ $_n_req -le 5 ]] && _hits+="${_hits:+, }${_xy// /}:${_p}"
    done
  done

  local _sum="변경 ${_n_all}건(git status) — QA 대상 ${_n_req}건 · 제외 규칙 ${_n_exc}건 · 대상 경로 밖 ${_n_out}건 · 사이클 이전 수정 ${_n_old}건 [기준: 시작 ${_pst}, HEAD ${_hct}, 선언 ${QA_DECL}]"
  if [[ $_n_req -eq 0 ]]; then
    QA_SCOPE_DETAIL="면제 — ${_sum}"
    return 0
  fi
  QA_SCOPE_DETAIL="QA 대상 소스 변경 — ${_sum}: ${_hits}$([[ $_n_req -gt 5 ]] && printf ' 외 %s건' $((_n_req - 5)))"
  return 1
}

# qa_block_reason <session_dir>   — 차단 메시지 본문(① 파일 ② 무엇이 틀렸나 ③ 작성 예)을 출력한다.
qa_block_reason() {
  local _sd="$1" _m _ts
  _m="${QA_MARKER_PATH:-${_sd}/${QA_MARKER_REL:-evidence/qa_test_done}}"
  _ts=$(date '+%Y-%m-%dT%H:%M:%S%:z')
  printf '%s\n' "① ${_m}" \
    "② ${QA_FAIL_REASON:-무효}" \
    "③ 작성 예 — 원복 후 전후 스냅샷 .state 가 같을 때:" \
    "   mcp__oio__file_write(path=\"${_m}\", overwrite=true, content=\"PASS ${_ts}\\nbefore=<before.json 절대경로>\\nafter=<after.json 절대경로>\\ncompare=<compare.json>\\nexcluded=<원복 불가로 뺀 항목 ID,...>\")"
  if [[ -n "${QA_SIDE_WRITES:-}" ]]; then
    printf '%s\n' "   선언된 부수 쓰기 경로(${QA_SIDE_WRITES})가 있으니 PASS·PARTIAL 에 다음 줄을 더한다(경로마다 snapshot=before 스냅샷에 그 표 포함 / suppressed=전송을 끄고 근거 기재):" \
      "   side_writes=<id>:snapshot|suppressed,...   (suppressed 가 있으면) suppress_basis=<억제 방법·원복, ${QA_SKIP_MIN:-10}자 이상>"
  fi
  printf '%s\n' "   QA 시험이 해당되지 않을 때(앱·서버 소스 변경 없음, QA 대상 기능 없음 등):" \
    "   mcp__oio__file_write(path=\"${_m}\", overwrite=true, content=\"SKIPPED ${_ts}\\nreason=<면제 판단 근거 — 무엇이 바뀌었고 왜 QA 대상이 아닌가, ${QA_SKIP_MIN:-10}자 이상>\")" \
    "   면제는 사용자에게 묻지 않고 에이전트가 판단해 기록한다(사용자 지시 2026-10-27 15:53). reason 이 감사 기록이다 — 근거를 구체적으로 적는다. 운영 배포 승인은 별도다." \
    "   규칙 문서: 프로젝트 .claude/qa_tier.json 의 doc 항목"
}
