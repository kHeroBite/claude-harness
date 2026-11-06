#!/bin/bash
# goal.json acceptance auto_script 를 세션 경로와 무관하게 실행·판정하는 공용 실행부(lib + CLI) — 사이클168
#
# 배경 (사이클167 실사고): auto_script 실행부 6곳이 환경변수 없이 문자열을 그대로 실행했다.
#   계약 작성자가 쓸 수 있는 "현재 세션 디렉터리"가 없어 절대경로를 박았고, 세션 재시작으로
#   CLAUDE_CONFIG_DIR 이 바뀌자 판정 스크립트를 못 찾아 전 항목이 거짓 FAIL 이 됐다.
#   그 FAIL 은 max_iterations fail-open 으로 통과됐다(판정불가 → 통과).
#   ⇒ 이 파일이 실행부의 단일 출처다. 모든 실행부는 GOAL_SESSION_DIR·GOAL_UUID 를 넘긴다.
#
# ── lib 인터페이스 (I-1 — 변경 시 리드 승인) ─────────────────────────────
#   source 후: gas_eval <script> <session_dir> [timeout=5]
#     return 0=PASS / 1=FAIL / 3=UNDET(판정불가), 전역 GAS_DETAIL 에 사유
#   (사이클217) 추가: gas_long_spec <item_json> / gas_long_key <item_json> <goal_id> / gas_long_get <session_dir> <key>
#     acceptance 항목에 선택 필드 timeout_sec(6~600)+cache_inputs(절대경로 파일 배열)가 있으면 gas_eval 이 같은 auto_script 의
#     긴 항목으로 보고 "기록 PASS 만 통과, 없으면 백그라운드 기동 + rc3(GAS_UNDET_KIND=pending)" 로 판정한다. 상세는 아래 "긴 항목" 절.
#   ★dash(/bin/sh)에서 source 하지 마라★ — bash 전용 문법이다. bash -c 'source ...; gas_eval ...' 로 감싼다.
#
# ── CLI ────────────────────────────────────────────────────────────────
#   bash "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/goal_autoscript_run.sh" --goal <goal.json> [--id <ID>] [--timeout N] [--before-stage <stage>]
#   --before-stage <stage>: valid_after 가 그 stage 인 항목을 판정 대상에서 뺀다(예: DONE 이전 호출은 --before-stage odone).
#     커밋·릴리스류처럼 정의상 그 stage 이후에만 충족되는 항목을 이전 시점에 돌리면 필연적 FAIL(순환 교착)이 된다.
#     1건 이상을 뺐고 남은 open·blocked 가 모두 0건이면 rc=0 + "DEFERRED <N>건 (valid_after=<stage>) — <stage> 이후 판정" 1행.
#       판정을 미룬 것이지 통과가 아니다 — 미룬 항목은 옵션 없는 전수 판정(ofinish)이 반드시 다시 본다.
#     단 --id 를 함께 줬는데 그 항목이 제외 대상이면 rc=3(명시한 항목을 판정할 수 없다). 뺀 항목 0건·대상 0건도 rc=3.
#     옵션이 없으면 전 항목을 판정한다(ofinish 는 odone 이후).
#   --criteria <acceptance_criteria.json> [--id <ID>] [--timeout N]: oplan 검수조건 파일의 .criteria[] 를 같은 gas_eval(bash -c)로 실행한다.
#     bash_exec 는 dash 라 직접 실행하면 $'\r' 등 bash 문법이 오판되므로 이 모드로 실행한다. --goal 과 동시 사용 불가.
#     기준표가 <세션>/plans/ 아래면 GOAL_SESSION_DIR·GOAL_UUID 는 그 부모(세션 루트) 기준이다(사이클198). 그 외 위치는 파일 디렉터리 그대로.
#     expected_result 필드가 있으면 상세 끝에 "[expected_result=...]" 로 표기(canary 해석은 호출 측 몫). 출력 행·rc 규약은 --goal 과 동일.
#   출력 행: ID<TAB>PASS|FAIL|UNDET|NOSCRIPT<TAB>사유
#   종료코드:
#     0  판정 대상 전부 PASS (또는 open 0건·나머지 전부 blocked/blocked_by → ALLBLOCKED 1행)
#     1  FAIL 1건 이상, UNDET·NOSCRIPT 없음
#     3  UNDET 또는 NOSCRIPT 1건 이상, 또는 비정상(goal 부재·파싱 실패·jq 부재·acceptance 비어 있음·
#        판정 가능 항목 0건). 비정상은 stderr 에 "판정불가: <사유>" 1줄.
#   호출 측 규칙: rc≠0 은 전부 미통과다. 이 파일이 없어 bash 가 내는 127 도 미통과다.
#
# ── 판정 규칙 ──────────────────────────────────────────────────────────
#   1. 재매핑(D4): 같은 UUID 의 "<리터럴 절대경로>/session-env/<UUID>" 는 현재 session_dir 로 바꾼다.
#      `~`·`$`·`}`·단어문자 뒤의 `/` 는 시작점이 아니고, 경로 문자는 `:,=;|&()` 를 넘지 않는다.
#      타 UUID·변수형(`$HOME/...`, `${..}/...`)·`~/...` 은 바꾸지 않는다.
#   2. 사전검사(D3-①): 인터프리터(python/python3/bash/sh/node) 뒤 리터럴 절대경로 스크립트가 없으면
#      실행하지 않고 UNDET.
#   3. 실행: GOAL_SESSION_DIR·GOAL_UUID 를 넘기고 timeout 안에서 bash -c, stdin 은 /dev/null.
#   4. rc: 0→PASS / 127→UNDET / 2 + stderr "can't open file"→UNDET / 124·137(timeout)→UNDET / 그 외→FAIL.
#      [사이클182 L-612] timeout 은 '판정을 끝내지 못함'이지 '미충족'이 아니다 — 판정불가(UNDET)로 정직하게 보인다.
#      전역 GAS_UNDET_KIND 로 판정불가 종류를 알린다: timeout | noscript(스크립트·명령 부재) | input(입력·정규식) | ""(UNDET 아님).
#      소비자(done_gate)는 timeout UNDET 를 FAIL 과 같은 반복 한도 경로로, noscript UNDET 는 무조건 차단으로 다룬다.
#   판정불가(UNDET)는 PASS 가 아니다. FAIL 과도 다르다(고칠 것은 코드가 아니라 판정 스크립트·경로).
#   0. (사이클181) 무력 정규식: gas_weak_regex 가 참이면 실행하지 않고 UNDET(3).
#      `grep -E '^(PASS|FAIL) X'` 처럼 PASS 와 FAIL 을 같은 교대 묶음의 대안으로 두면 FAIL 줄도
#      rc=0 이 되어 판정력이 0 이다(L-601 — PASS 만 인정). 계약 hook(F-GOALAS-7)이 1차 방어,
#      이 판정은 계약 hook 을 거치지 않은 경로(copy·move, 이미 잠긴 옛 계약)의 2차 방어다.
#
# ── gas_weak_regex <auto_script> ───────────────────────────────────────
#   return 0 = 무력(PASS·FAIL 이 같은 교대 묶음의 서로 다른 대안), 1 = 아님(perl 부재 포함 — fail-open).
#   대상(대소문자 무시): (PASS|FAIL) (FAIL|PASS) (PASS|OK|FAIL) \(PASS\|FAIL\) 'PASS|FAIL' PASS\|FAIL
#   교대 묶음 = 괄호 묶음 안 / 따옴표 문자열의 괄호 밖 / 따옴표 밖 단어의 \| 구분.
#   구분자 | 의 앞뒤에 공백이 있거나 || 이면 셸 파이프·논리합으로 보고 대안으로 나누지 않는다.
#   잔존 한계: 변수 경유(P='(PASS|FAIL)'; grep -E "$P")·문자 클래스 우회는 잡지 못한다.
#     주석 안의 (PASS|FAIL)·줄 수 세기(grep -cE '^(PASS|FAIL)')도 무력으로 본다(오차단 — 집계·보고 대상).
gas_weak_regex() {
  [[ -n "${1:-}" ]] || return 1
  command -v perl >/dev/null 2>&1 || return 1
  GAS_WR="$1" perl -e '
    my $s = $ENV{GAS_WR}; my @t;
    while ($s =~ /\\?\((?:\?:)?([^()]*?)\\?\)/g) { push @t, $1; }
    while ($s =~ /\x27([^\x27]*)\x27|"([^"]*)"/g) {
      my $q = defined $1 ? $1 : $2; $q =~ s/\\?\([^()]*?\\?\)/ /g; push @t, $q;
    }
    while ($s =~ /(\S*\\\|\S*)/g) { push @t, $1; }
    for my $x (@t) {
      my @a = split /(?<![\s|])\\?\|(?![\s|])/, $x;
      next if @a < 2;
      my (@p, @f);
      for my $i (0 .. $#a) {
        push @p, $i if $a[$i] =~ /(?<![A-Za-z])PASS/i;
        push @f, $i if $a[$i] =~ /(?<![A-Za-z])FAIL/i;
      }
      for my $i (@p) { for my $j (@f) { exit 0 if $i != $j; } }
    }
    exit 1;
  ' 2>/dev/null
}

# ── gas_canary_expected <id> <session_dir> ─────────────────────────────
#   (사이클195 역라우팅 #4) 카나리 계약의 단일 출처. 기준표(plans/acceptance_criteria.json, 없으면 세션 루트)에서
#   gate_kind=canary 인 항목의 expected_result(대문자)를 stdout 으로 낸다. 없으면 빈 출력 + return 1.
#   카나리는 "판정 결과 == expected_result 면 정상"이다 — 판정기는 계속 FAIL 을 내고(판정기 우회 검출용),
#   소비자(--goal 집계·oto 완주 가드·done_gate·verify_crud_executed.py)가 같은 함수/규칙으로 읽는다.
#   기준표에 gate_kind=canary 항목이 없는 세션(다른 프로젝트 포함)은 항상 return 1 → 종전 동작과 완전히 같다.
gas_canary_expected() {
  local _id="$1" _sd="${2%/}" _f _v
  [[ -n "$_id" && -n "$_sd" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  for _f in "$_sd/plans/acceptance_criteria.json" "$_sd/acceptance_criteria.json"; do
    [[ -f "$_f" ]] || continue
    _v=$(jq -r --arg id "$_id" '.criteria[]? | select(((.id // "") == $id) and (((.gate_kind // "") | ascii_downcase) == "canary")) | (.expected_result // "") | ascii_upcase' "$_f" 2>/dev/null | head -1)
    case "$_v" in
      PASS|FAIL|UNDET|NOSCRIPT) printf '%s' "$_v"; return 0 ;;
    esac
  done
  return 1
}

_gas_eval_core() {
  local _s="$1" _sd="${2%/}" _t="${3:-5}"
  local _uuid _orig _rc _ef _err _p _miss=""
  GAS_DETAIL=""
  GAS_UNDET_KIND=""
  case "$_t" in ''|*[!0-9]*) _t=5 ;; esac
  if [[ -z "$_s" ]]; then
    GAS_DETAIL="auto_script 비어 있음"; GAS_UNDET_KIND=input
    return 3
  fi
  if gas_weak_regex "$_s"; then
    GAS_DETAIL="무력 정규식(PASS·FAIL 교대) — FAIL 줄도 통과시키는 판정(L-601)"; GAS_UNDET_KIND=input
    return 3
  fi
  if [[ -z "$_sd" ]]; then
    GAS_DETAIL="session_dir 비어 있음"; GAS_UNDET_KIND=input
    return 3
  fi
  _uuid=$(basename "$_sd")
  _orig="$_s"

  # 1. 재매핑 — 값은 환경변수로 넘겨 정규식·치환문에 끼워 넣지 않는다(특수문자 안전)
  if command -v perl >/dev/null 2>&1; then
    local _rm
    _rm=$(printf '%s' "$_s" | GAS_U="$_uuid" GAS_SD="$_sd" perl -0777 -pe \
      's{(?<![\w\$\}~])/[^\s"'"'"'\$:,=;|&()]*?/session-env/\Q$ENV{GAS_U}\E(?=/|\s|$|["'"'"'])}{$ENV{GAS_SD}}g' 2>/dev/null) \
      && [[ -n "$_rm" ]] && _s="$_rm"
  fi
  if [[ "$_s" != "$_orig" ]]; then
    mkdir -p "${_sd}/logs" 2>/dev/null
    printf '%s REMAP\n  원문: %s\n  결과: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$_orig" "$_s" \
      >> "${_sd}/logs/goal_autoscript_run.log" 2>/dev/null || true
  fi

  # 2. 사전검사 — 인터프리터 뒤 리터럴 절대경로 스크립트 파일 부재
  while IFS= read -r _p; do
    [[ -z "$_p" ]] && continue
    [[ -f "$_p" ]] || _miss="${_miss}${_miss:+, }${_p}"
  done < <(printf '%s\n' "$_s" | grep -oP '(?<![\w./-])(python3?|bash|sh|node)\s+["'"'"']?\K/[^\s"'"'"';|&)]+\.(py|sh|js)(?=$|[\s"'"'"';|&)])' 2>/dev/null)
  if [[ -n "$_miss" ]]; then
    GAS_DETAIL="판정 스크립트 파일 부재: ${_miss}"; GAS_UNDET_KIND=noscript
    return 3
  fi

  # 3. 실행
  _ef=$(mktemp 2>/dev/null) || _ef=""
  if [[ -n "$_ef" ]]; then
    GOAL_SESSION_DIR="$_sd" GOAL_UUID="$_uuid" timeout "$_t" bash -c "$_s" </dev/null >/dev/null 2>"$_ef"
    _rc=$?
    _err=$(head -c 2000 "$_ef" 2>/dev/null)
    rm -f "$_ef" 2>/dev/null
  else
    GOAL_SESSION_DIR="$_sd" GOAL_UUID="$_uuid" timeout "$_t" bash -c "$_s" </dev/null >/dev/null 2>/dev/null
    _rc=$?
    _err=""
  fi

  # 4. rc 매핑
  if [[ "$_rc" -eq 0 ]]; then
    GAS_DETAIL="rc=0"
    return 0
  fi
  if [[ "$_rc" -eq 127 ]]; then
    GAS_DETAIL="명령·스크립트를 찾을 수 없음(rc=127) $(printf '%s' "$_err" | head -1)"; GAS_UNDET_KIND=noscript
    return 3
  fi
  if [[ "$_rc" -eq 2 && "$_err" == *"can't open file"* ]]; then
    GAS_DETAIL="판정 스크립트를 열 수 없음(rc=2) $(printf '%s' "$_err" | head -1)"; GAS_UNDET_KIND=noscript
    return 3
  fi
  if [[ "$_rc" -eq 124 || "$_rc" -eq 137 ]]; then
    GAS_DETAIL="timeout ${_t}초 — 판정불가(rc=${_rc})"; GAS_UNDET_KIND=timeout
    return 3
  fi
  GAS_DETAIL="rc=${_rc}"
  return 1
}

# ── 긴 항목(사이클217 — acceptance 선택 필드 timeout_sec + cache_inputs) ─────────────
#   L-391 기존 구현 상태: 항목당 5초 직접 실행(gas_eval 3번째 인자)은 그대로이고, 긴 항목 분기는 신규다.
#   호출부(grep 실측): PreToolUse_done_gate.sh·PreToolUse_oto_completion_guard.sh·PreToolUse_goal_autoscript_guard.sh 가
#   gas_eval <script> <sd> 5 를 직접 부른다 → 분기를 gas_eval 내부(래퍼)에 두어 호출부를 고치지 않고 전부 받는다.
#   규약: timeout_sec(정수 6~GAS_LONG_MAX=600) + cache_inputs(절대경로 정규 파일 1~50개) 둘 다 있어야 긴 항목이다.
#     timeout_sec 만 있고 cache_inputs 가 없거나 범위 밖이면 선언 오류 = 판정불가(kind=input, 무조건 차단).
#   기록: <sd>/logs/gas_cache/<key>.res (1행 "rc=<0|1|timeout|noscript|input> epoch=<s> elapsed=<s> id=<ID>"),
#         실행 중 표식 <key>.run (1행 "pid epoch" — 기동한 쪽(gas_eval)이 $! 로 tmp→mv), 로그 <key>.log.
#         CLI 는 .res 를 먼저 원자적으로 쓰고 .run 을 나중에 지운다(c217_gate 의 _sb_settle 규약).
#   key = sha256("gas-long-v1" ‖ goal_id ‖ id ‖ auto_script ‖ timeout_sec ‖ Σ(경로 sha256(내용))) 앞 32자 — 입력 1바이트 변경 시 낡은 기록 무효.
#   gas_eval 동작(긴 항목): 기록 PASS(24시간 이내)만 통과 / 기록 FAIL→rc1 / timeout→rc3(kind=timeout) / noscript·input→rc3 /
#     기록 없음 → .run 이 살아 있으면(pid 생존 AND 나이 ≤ timeout_sec+30) 대기, 죽었거나 나이 초과면 재기동, 아니면 setsid 로 CLI 1회 기동 →
#     rc3(kind=pending, 소비자는 반복 한도와 무관하게 차단). 진행 중은 절대 통과가 아니다.
GAS_LONG_MAX=600
_GAS_SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"

# gas_long_spec <item_json> → 0=긴 항목 정상(GAS_LONG_T), 1=긴 항목 아님, 3=선언 오류(GAS_DETAIL, GAS_UNDET_KIND=input)
gas_long_spec() {
  local _it="$1" _t _p
  GAS_LONG_T=""
  printf '%s' "$_it" | jq -e 'has("timeout_sec")' >/dev/null 2>&1 || return 1
  _t=$(printf '%s' "$_it" | jq -r 'if (.timeout_sec|type)=="number" and (.timeout_sec==(.timeout_sec|floor)) then (.timeout_sec|tostring) else "" end' 2>/dev/null)
  if [[ ! "$_t" =~ ^[0-9]+$ ]] || (( _t < 6 || _t > GAS_LONG_MAX )); then
    GAS_DETAIL="timeout_sec 선언 오류: 6~${GAS_LONG_MAX} 정수여야 함"; GAS_UNDET_KIND=input
    return 3
  fi
  if ! printf '%s' "$_it" | jq -e '(.cache_inputs|type)=="array" and (.cache_inputs|length)>=1 and (.cache_inputs|length)<=50 and all(.cache_inputs[]; type=="string")' >/dev/null 2>&1; then
    GAS_DETAIL="cache_inputs 선언 오류: timeout_sec 와 함께 문자열 1~50개 배열이 필요함(캐시 입력 없는 긴 판정은 믿지 않는다)"; GAS_UNDET_KIND=input
    return 3
  fi
  while IFS= read -r _p; do
    if [[ "$_p" != /* || ! -f "$_p" ]]; then
      GAS_DETAIL="cache_inputs 선언 오류: 절대경로 정규 파일이 아님: ${_p}"; GAS_UNDET_KIND=input
      return 3
    fi
  done < <(printf '%s' "$_it" | jq -r '.cache_inputs[]' 2>/dev/null)
  GAS_LONG_T="$_t"
  return 0
}

# gas_long_key <item_json> <goal_id> → 키(앞 32자) 출력, 입력 파일을 읽지 못하면 rc1
gas_long_key() {
  local _it="$1" _gid="$2" _id _s _t _p _h _acc
  _id=$(printf '%s' "$_it" | jq -r '.id // ""' 2>/dev/null)
  _s=$(printf '%s' "$_it" | jq -r '.auto_script // ""' 2>/dev/null)
  _t=$(printf '%s' "$_it" | jq -r '.timeout_sec' 2>/dev/null)
  _acc="gas-long-v1|${_gid}|${_id}|${_s}|${_t}"$'\n'
  while IFS= read -r _p; do
    _h=$(sha256sum -- "$_p" 2>/dev/null | cut -c1-64)
    [[ ${#_h} -eq 64 ]] || return 1
    _acc+="${_p} ${_h}"$'\n'
  done < <(printf '%s' "$_it" | jq -r '.cache_inputs[]' 2>/dev/null)
  printf '%s' "$_acc" | sha256sum | cut -c1-32
}

# gas_long_get <session_dir> <key> → 기록이 있으면 rc 값 출력 + 0, 없음·24시간 경과·형식 불량이면 1
gas_long_get() {
  local _f="${1%/}/logs/gas_cache/$2.res" _l _r _e
  [[ -f "$_f" ]] || return 1
  _l=$(head -n 1 "$_f" 2>/dev/null)
  _r="${_l#rc=}"; _r="${_r%% *}"
  _e="${_l#*epoch=}"; _e="${_e%% *}"
  [[ "$_e" =~ ^[0-9]+$ ]] || return 1
  (( $(date +%s) - _e > 86400 )) && return 1
  case "$_r" in 0|1|timeout|noscript|input) printf '%s' "$_r"; return 0 ;; esac
  return 1
}

# 긴 항목 판정(gas_eval 내부) — 기록만 읽고, 없으면 백그라운드 기동 후 pending(rc3)
_gas_long_eval() {
  local _it="$1" _sd="$2" _gid _key _res _id _T _cd _run _pid _ep _alive _lf _np
  GAS_DETAIL=""; GAS_UNDET_KIND=""
  gas_long_spec "$_it"; [[ $? -eq 3 ]] && return 3
  _T="$GAS_LONG_T"
  _id=$(printf '%s' "$_it" | jq -r '.id // "?"' 2>/dev/null)
  _gid=$(jq -r '.goal_id // ""' "${GAS_GOAL_FILE:-$_sd/goal.json}" 2>/dev/null)
  _key=$(gas_long_key "$_it" "$_gid") || { GAS_DETAIL="cache_inputs 파일을 읽을 수 없음"; GAS_UNDET_KIND=input; return 3; }
  if _res=$(gas_long_get "$_sd" "$_key"); then
    case "$_res" in
      0) GAS_DETAIL="rc=0 (긴 항목 기록 ${_key:0:8})"; return 0 ;;
      1) GAS_DETAIL="rc=1 (긴 항목 기록 ${_key:0:8})"; return 1 ;;
      timeout) GAS_DETAIL="timeout_sec=${_T} 초과 — 판정불가(긴 항목 기록)"; GAS_UNDET_KIND=timeout; return 3 ;;
      *) GAS_DETAIL="판정불가(긴 항목 기록 ${_res}) — 판정 스크립트·입력 문제"; GAS_UNDET_KIND="$_res"; return 3 ;;
    esac
  fi
  _cd="$_sd/logs/gas_cache"; _run="$_cd/${_key}.run"; _lf="$_cd/${_key}.log"
  _alive=0
  if [[ -f "$_run" ]]; then
    read -r _pid _ep < "$_run" 2>/dev/null
    # 재기동 조건: pid 가 죽었거나 OR 나이 > timeout_sec+30 → 재기동. 둘 다 아니면(살아 있고 나이 이내) 대기.
    if [[ "$_pid" =~ ^[0-9]+$ && "$_ep" =~ ^[0-9]+$ ]] && kill -0 "$_pid" 2>/dev/null && (( $(date +%s) - _ep <= _T + 30 )); then
      _alive=1
    fi
  fi
  if [[ "$_alive" -eq 0 ]]; then
    command -v setsid >/dev/null 2>&1 || { GAS_DETAIL="긴 판정 기동 실패: setsid 부재"; GAS_UNDET_KIND=input; return 3; }
    mkdir -p "$_cd" 2>/dev/null || { GAS_DETAIL="긴 판정 기동 실패: ${_cd} 생성 불가"; GAS_UNDET_KIND=input; return 3; }
    # hook 파이프를 물지 않도록 stdin/stdout/stderr 를 전부 파일로 돌린다(time_budget 파이프 원칙)
    setsid bash "$_GAS_SELF" --goal "${GAS_GOAL_FILE:-$_sd/goal.json}" --id "$_id" </dev/null >"$_lf" 2>&1 &
    _np=$!
    printf '%s %s\n' "$_np" "$(date +%s)" > "$_run.tmp$$" 2>/dev/null && mv -f "$_run.tmp$$" "$_run" 2>/dev/null
    # 그 사이 CLI 가 .res 를 쓰고 끝났다면(.run 삭제가 먼저 일어난 경우) 방금 쓴 표식은 낡았다 → 지운다
    [[ -f "$_cd/${_key}.res" ]] && rm -f "$_run" 2>/dev/null
    if declare -F _log >/dev/null 2>&1; then _log "LONG-LAUNCH id=${_id} key=${_key:0:8} pid=${_np}"; fi
  fi
  GAS_DETAIL="긴 판정 진행 중(timeout_sec=${_T}) — 약 ${_T}초 뒤 DONE 전이를 다시 시도"; GAS_UNDET_KIND=pending
  return 3
}

# 공개 진입점 — 긴 항목이면 위 분기, 아니면 종전 5초 경로(_gas_eval_core). _GAS_NOLONG 가 있으면 항상 종전 경로.
gas_eval() {
  local _s="$1" _sd="${2%/}" _it _gf
  # GAS_GOAL_FILE: goal 파일 경로(셸 전역, export 금지). 미설정이면 종전대로 <sd>/goal.json (K1/D-9 — 보관본 판정)
  _gf="${GAS_GOAL_FILE:-$_sd/goal.json}"
  if [[ -z "${_GAS_NOLONG:-}" && -n "$_s" && -n "$_sd" && -f "$_gf" ]] && command -v jq >/dev/null 2>&1; then
    _it=$(jq -c --arg s "$_s" '[(.acceptance // [])[] | select(((.auto_script // "") == $s) and has("timeout_sec"))][0] // empty' "$_gf" 2>/dev/null)
    if [[ -n "$_it" ]]; then
      _gas_long_eval "$_it" "$_sd"
      return $?
    fi
  fi
  _gas_eval_core "$@"
}

# CLI --goal 항목 판정 — 긴 항목이면 실효 timeout = max(--timeout, timeout_sec)(상한 600)로 직접 실행하고 .res 를 먼저, .run 을 나중에 지운다
_gas_long_cli_eval() {
  local _it="$1" _s="$2" _sd="$3" _t="$4" _gid _key _eff _rc _st _el _res _cd
  gas_long_spec "$_it"; _rc=$?
  if [[ "$_rc" -eq 1 ]]; then gas_eval "$_s" "$_sd" "$_t"; return $?; fi
  [[ "$_rc" -eq 0 ]] || return 3
  _gid=$(jq -r '.goal_id // ""' "${GAS_GOAL_FILE:-$_sd/goal.json}" 2>/dev/null)
  _key=$(gas_long_key "$_it" "$_gid") || { GAS_DETAIL="cache_inputs 파일을 읽을 수 없음"; GAS_UNDET_KIND=input; return 3; }
  _eff="$GAS_LONG_T"; [[ "$_t" -gt "$_eff" ]] && _eff="$_t"; [[ "$_eff" -gt "$GAS_LONG_MAX" ]] && _eff="$GAS_LONG_MAX"
  _cd="$_sd/logs/gas_cache"; mkdir -p "$_cd" 2>/dev/null
  _st=$(date +%s)
  _gas_eval_core "$_s" "$_sd" "$_eff"; _rc=$?
  _el=$(( $(date +%s) - _st ))
  case "$_rc" in
    0) _res=0 ;;
    1) _res=1 ;;
    *) case "$GAS_UNDET_KIND" in timeout) _res=timeout ;; noscript) _res=noscript ;; *) _res=input ;; esac ;;
  esac
  printf 'rc=%s epoch=%s elapsed=%s id=%s\n' "$_res" "$(date +%s)" "$_el" "$(printf '%s' "$_it" | jq -r '.id // "?"' 2>/dev/null)" > "$_cd/${_key}.res.tmp$$" 2>/dev/null \
    && mv -f "$_cd/${_key}.res.tmp$$" "$_cd/${_key}.res" 2>/dev/null
  rm -f "$_cd/${_key}.run" 2>/dev/null
  return "$_rc"
}

_gas_abort() {
  echo "판정불가: $*" >&2
  exit 3
}

# 지정한 --id 중 파일의 항목 배열(jq 경로)에 없는 것이 하나라도 있으면 rc=3 로 끝낸다(없는 ID 무시 금지)
_gas_check_ids() {
  local _f="$1" _path="$2" _ids="$3" _one _miss=""
  [[ -n "$_ids" ]] || return 0
  while IFS= read -r _one; do
    [[ -z "$_one" ]] && continue
    jq -e --arg x "$_one" "[ ${_path}[]? | select((.id // \"\") == \$x) ] | length > 0" "$_f" >/dev/null 2>&1 \
      || _miss="${_miss}${_miss:+, }${_one}"
  done <<< "$_ids"
  [[ -z "$_miss" ]] || _gas_abort "--id 에 없는 항목: ${_miss}"
}

_gas_criteria() {
  local _f="$1" _id="$2" _t="$3" _sd _item _iid _script _exp _rc _n=0 _pass=0 _fail=0 _undet=0 _noscript=0
  _GAS_NOLONG=1   # 기준표 모드는 긴 항목 분기를 쓰지 않는다
  command -v jq >/dev/null 2>&1 || _gas_abort "jq 부재 — criteria 파일을 읽을 수 없습니다"
  [[ -f "$_f" ]] || _gas_abort "criteria 파일 부재: ${_f}"
  jq -e . "$_f" >/dev/null 2>&1 || _gas_abort "criteria 파싱 실패: ${_f}"
  jq -e '(.criteria | type) == "array" and (.criteria | length) > 0' "$_f" >/dev/null 2>&1 \
    || _gas_abort "criteria 가 비어 있거나 배열이 아닙니다: ${_f}"
  _gas_check_ids "$_f" '.criteria' "$_id"
  _sd=$(cd "$(dirname "$_f")" 2>/dev/null && pwd) || _gas_abort "criteria 디렉터리를 확인할 수 없습니다: ${_f}"
  # 기준표 표준 위치는 <세션>/plans/ 다 — plans 디렉터리면 세션 루트로 올린다(사이클198: plans/plans 이중 결합·UUID=plans)
  [[ "$(basename "$_sd")" == "plans" ]] && _sd=$(dirname "$_sd")
  while IFS= read -r _item; do
    [[ -z "$_item" ]] && continue
    _n=$((_n + 1))
    _iid=$(printf '%s' "$_item" | jq -r '.id // "?"' 2>/dev/null)
    _script=$(printf '%s' "$_item" | jq -r '.auto_script // empty' 2>/dev/null)
    _exp=$(printf '%s' "$_item" | jq -r '.expected_result // empty' 2>/dev/null)
    if [[ -z "$_script" ]]; then
      _noscript=$((_noscript + 1))
      printf '%s\tNOSCRIPT\t%s\n' "$_iid" "auto_script 없음 — 기계 판정 불가(미통과)"
      continue
    fi
    gas_eval "$_script" "$_sd" "$_t"
    _rc=$?
    GAS_DETAIL=$(printf '%s' "$GAS_DETAIL" | tr '\t\n\r' '   ')
    [[ -n "$_exp" ]] && GAS_DETAIL="${GAS_DETAIL} [expected_result=$(printf '%s' "$_exp" | tr '\t\n\r' '   ')]"
    case "$_rc" in
      0) _pass=$((_pass + 1)); printf '%s\tPASS\t%s\n' "$_iid" "$GAS_DETAIL" ;;
      1) _fail=$((_fail + 1)); printf '%s\tFAIL\t%s\n' "$_iid" "$GAS_DETAIL" ;;
      *) _undet=$((_undet + 1)); printf '%s\tUNDET\t판정불가: %s\n' "$_iid" "$GAS_DETAIL" ;;
    esac
  done < <(jq -c --arg id "$_id" '.criteria[] | select(($id == "") or ((.id // "") as $x | (($id | split("\n")) | index($x)) != null))' "$_f" 2>/dev/null)
  [[ "$_n" -gt 0 ]] || _gas_abort "판정 대상 항목 0건${_id:+ (--id ${_id})}"
  [[ "$_undet" -gt 0 || "$_noscript" -gt 0 ]] && return 3
  [[ "$_fail" -gt 0 ]] && return 1
  return 0
}

_gas_main() {
  local _goal="" _id="" _t=5 _bs="" _crit=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --goal) _goal="${2:-}"; shift 2 || shift ;;
      --criteria) _crit="${2:-}"; shift 2 || shift ;;
      --id) _id="${_id:+${_id}$'\n'}$(printf '%s' "${2:-}" | tr ',' '\n')"; shift 2 || shift ;;  # 여러 번 주거나 쉼표 목록이면 개행으로 누적
      --timeout) _t="${2:-}"; shift 2 || shift ;;
      --before-stage)
        _bs="${2:-}"; shift 2 || shift
        [[ -n "$_bs" ]] || _gas_abort "--before-stage 에 stage 값이 없습니다"
        ;;
      *) _gas_abort "알 수 없는 인자: $1 (사용: --goal <goal.json>|--criteria <acceptance_criteria.json> [--id <ID>] [--timeout N] [--before-stage <stage>])" ;;
    esac
  done
  case "$_t" in ''|*[!0-9]*) _gas_abort "--timeout 은 정수여야 합니다: ${_t}" ;; esac
  if [[ -n "$_crit" ]]; then
    [[ -z "$_goal" ]] || _gas_abort "--goal 과 --criteria 는 동시에 쓸 수 없습니다"
    _gas_criteria "$_crit" "$_id" "$_t"
    return $?
  fi
  [[ -n "$_goal" ]] || _gas_abort "--goal 또는 --criteria 가 없습니다"
  command -v jq >/dev/null 2>&1 || _gas_abort "jq 부재 — goal.json 을 읽을 수 없습니다"
  [[ -f "$_goal" ]] || _gas_abort "goal.json 부재: ${_goal}"
  jq -e . "$_goal" >/dev/null 2>&1 || _gas_abort "goal.json 파싱 실패: ${_goal}"

  local _nacc
  _nacc=$(jq -r 'if (.acceptance | type) == "array" then (.acceptance | length) else -1 end' "$_goal" 2>/dev/null) || _nacc=-1
  [[ "$_nacc" =~ ^[0-9]+$ && "$_nacc" -gt 0 ]] || _gas_abort "acceptance 가 비어 있거나 배열이 아닙니다: ${_goal}"

  _gas_check_ids "$_goal" '(.acceptance // [])' "$_id"

  local _sd
  _sd=$(cd "$(dirname "$_goal")" 2>/dev/null && pwd) || _gas_abort "goal.json 디렉터리를 확인할 수 없습니다: ${_goal}"
  # K1/D-9: 판정 기록 키·재기동이 --goal 로 받은 파일(보관본 포함)을 보도록 절대경로로 지정한다(셸 전역, export 금지)
  GAS_GOAL_FILE="$_sd/$(basename "$_goal")"

  # --before-stage: valid_after 가 그 stage 인 항목은 이 시점의 판정 대상이 아니다(blocked 집계에서도 뺀다)
  local _filter='(.acceptance // [])[] | select(($id == "") or ((.id // "") as $x | (($id | split("\n")) | index($x)) != null)) | select(($bs == "") or ((.valid_after // "") != $bs))'
  local _nblocked _ndefer=0
  _nblocked=$(jq -r --arg id "$_id" --arg bs "$_bs" "[ ${_filter} | select((.status // \"open\") == \"blocked\" or (.status // \"open\") == \"blocked_by\") ] | length" "$_goal" 2>/dev/null) || _nblocked=0
  if [[ -n "$_bs" ]]; then
    _ndefer=$(jq -r --arg id "$_id" --arg bs "$_bs" '[ (.acceptance // [])[] | select(($id == "") or ((.id // "") as $x | (($id | split("\n")) | index($x)) != null)) | select((.valid_after // "") == $bs) ] | length' "$_goal" 2>/dev/null) || _ndefer=0
    [[ "$_ndefer" =~ ^[0-9]+$ ]] || _ndefer=0
  fi

  local _item _iid _script _rc _pass=0 _fail=0 _undet=0 _noscript=0 _open=0
  while IFS= read -r _item; do
    [[ -z "$_item" ]] && continue
    _open=$((_open + 1))
    _iid=$(printf '%s' "$_item" | jq -r '.id // "?"' 2>/dev/null)
    _script=$(printf '%s' "$_item" | jq -r '.auto_script // empty' 2>/dev/null)
    if [[ -z "$_script" ]]; then
      _noscript=$((_noscript + 1))
      printf '%s\tNOSCRIPT\t%s\n' "$_iid" "auto_script 없음 — 기계 판정 불가(미통과)"
      continue
    fi
    _gas_long_cli_eval "$_item" "$_script" "$_sd" "$_t"
    _rc=$?
    GAS_DETAIL=$(printf '%s' "$GAS_DETAIL" | tr '\t\n\r' '   ')
    # 카나리(사이클195): 기준표 gate_kind=canary + expected_result=FAIL 인 항목은 FAIL 이 정상, PASS 가 위반이다.
    #   상태 열은 관측값 그대로 내고 상세에만 표기한다. 기준표에 카나리가 없으면 _cexp 가 비어 종전과 같다.
    _cexp=$(gas_canary_expected "$_iid" "$_sd" 2>/dev/null) || _cexp=""
    case "$_rc" in
      0)
        if [[ "$_cexp" == "FAIL" ]]; then
          _fail=$((_fail + 1)); printf '%s\tPASS\t%s [canary 위반: PASS ≠ expected_result FAIL — 판정기 우회 의심]\n' "$_iid" "$GAS_DETAIL"
        else
          _pass=$((_pass + 1)); printf '%s\tPASS\t%s\n' "$_iid" "$GAS_DETAIL"
        fi ;;
      1)
        if [[ "$_cexp" == "FAIL" ]]; then
          _pass=$((_pass + 1)); printf '%s\tFAIL\t%s [canary expected_result=FAIL → 정상]\n' "$_iid" "$GAS_DETAIL"
        else
          _fail=$((_fail + 1)); printf '%s\tFAIL\t%s\n' "$_iid" "$GAS_DETAIL"
        fi ;;
      *) _undet=$((_undet + 1)); printf '%s\tUNDET\t판정불가: %s\n' "$_iid" "$GAS_DETAIL" ;;
    esac
  done < <(jq -c --arg id "$_id" --arg bs "$_bs" "${_filter} | select((.status // \"open\") != \"blocked\" and (.status // \"open\") != \"blocked_by\")" "$_goal" 2>/dev/null)

  if [[ "$_open" -eq 0 ]]; then
    if [[ "$_nblocked" =~ ^[0-9]+$ && "$_nblocked" -gt 0 ]]; then
      # blocked 는 fail 로 세지 않는다(oto 원칙) — 근거 검증은 F-OTO-3/4/6 소관
      printf 'ALLBLOCKED\tBLOCKED\topen 항목 0건 — 남은 %s건 전부 blocked/blocked_by\n' "$_nblocked"
      return 0
    fi
    # 전부 --before-stage 로 미뤄졌다 — 통과가 아니라 연기. ofinish 전수 판정(옵션 없음)이 다시 본다.
    #   --id 로 명시한 항목이 제외 대상이면 그 항목을 판정할 수 없으므로 rc=3 유지.
    if [[ -z "$_id" && "$_ndefer" -gt 0 ]]; then
      printf 'DEFERRED\tDEFERRED\t%s건 (valid_after=%s) — %s 이후 판정\n' "$_ndefer" "$_bs" "$_bs"
      return 0
    fi
    _gas_abort "판정 대상 항목 0건${_id:+ (--id ${_id})}${_bs:+ (--before-stage ${_bs})}"
  fi
  if [[ $((_pass + _fail + _undet)) -eq 0 ]]; then
    echo "판정불가: 판정 가능 항목(auto_script 보유 open) 0건 — NOSCRIPT ${_noscript}건" >&2
    return 3
  fi
  [[ "$_undet" -gt 0 || "$_noscript" -gt 0 ]] && return 3
  [[ "$_fail" -gt 0 ]] && return 1
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  _gas_main "$@"
  exit $?
fi
