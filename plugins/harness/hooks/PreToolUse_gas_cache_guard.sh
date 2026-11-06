#!/bin/bash
# 세션 logs/gas_cache 의 자동 판정 기록(.res·.run)을 에이전트가 직접 쓰거나 지우는 위조를 막는 PreToolUse hook (F-GAS-CACHE, 사이클218 C2)
#
# 등록: settings.json PreToolUse — lib/time_budget.sh 7.5 closed (write_guard 와 같은 예산·정책). 판정 본문은 문자열 검사뿐이라 수십 ms 이내다.
# 정책 근거: 이 hook 은 판정 기록의 무결성을 지키는 차단 전용 가드다. 예산 초과를 open(통과)으로 두면 부하가 높은 순간이 곧 위조 창이 된다 → closed(보류).
# 입력: stdin 의 hook JSON. 출력: 차단 시 {"decision":"block","reason":…} 와 rc=2, 그 밖에는 무출력 rc=0.
# 분기를 write_guard 안이 아니라 이 파일로 둔 이유: write_guard 는 다른 세션이 개편 중이라 파일을 나누어 충돌을 없앴다(팀 리드 결정).
# 한계: settings.json hook 목록은 세션이 시작할 때 캐시된다 → 이미 떠 있는 세션에는 새 세션부터 적용된다(활성 세션은 재시작 전까지 무방비).
INPUT=$(</dev/stdin) || INPUT=""   # [사이클221 iter1] cat·timeout 두 프로세스 기동 생략(셸 내장 읽기). 입력은 호출 측이 닫는 파이프·파일이라 멈출 일이 없고, 상위 상한은 hook 래퍼 lib/time_budget.sh 의 7.5초(closed)다
[[ -n "${INPUT//[[:space:]]/}" ]] || exit 0
# [사이클221] 입력 머리(tool_name·command·cwd)를 jq 1회로 읽는다 — 종전 jq 3회와 값이 같을 때만 쓴다.
#   빠른 길 조건: 문서 1개 + 세 값이 모두 문자열·null·false. 값의 NUL 제거·끝 개행 제거는 종전 $(jq -r …) 와 같게 맞춘다.
#   그 밖(여러 문서·다른 타입·jq 오류)은 _GC_HDR_OK 를 비워 종전 개별 jq 경로를 그대로 탄다.
_GC_HDR_OK=""
_gc_rtrim() {  # $1=변수명 — 끝 개행 제거($(…) 치환과 같은 결과)
  local _s="${!1}"
  while [[ "$_s" == *$'\n' ]]; do _s="${_s%$'\n'}"; done
  printf -v "$1" '%s' "$_s"
}
# [TODO-022] 큰 본문의 ASCII 패턴 치환은 바이트 단위(C 로케일)로 한다 — UTF-8 로케일에서 bash 패턴 치환은 본문 길이에 비해 매우 느리다
#   (24KB 한국어 주석 본문 실측: 따옴표 제거 174ms→1ms, 구간 분할 54ms→1ms). 패턴이 모두 ASCII 이고 UTF-8 다중 바이트에는 ASCII 바이트가 없으므로 결과는 같다.
#   local LC_ALL 은 함수가 끝나면 원래 값으로 돌아간다(그 밖의 판정은 종전 로케일 그대로 돈다).
_gc_c_unq() {  # $1=결과 변수명 $2=원문 → 따옴표·역슬래시를 지운 값
  local LC_ALL=C
  printf -v "$1" '%s' "${2//[\"\'\\]/}"
}
_gc_c_segs() {  # $1=결과 변수명 $2=원문 → 2>&1·>&2 를 지우고 && || ; & | 를 줄바꿈으로 바꾼 값
  local LC_ALL=C _s
  _s="${2//2>&1/ }"; _s="${_s//>&2/ }"
  _s="${_s//&&/$'\n'}"; _s="${_s//||/$'\n'}"; _s="${_s//;/$'\n'}"
  _s="${_s//&/$'\n'}"; _s="${_s//|/$'\n'}"
  printf -v "$1" '%s' "$_s"
}
_GC_HDR=$(jq -js 'if length == 1 then (.[0] | [(.tool_name // null), (.tool_input.command // .tool_input.cmd // null), (.tool_input.working_dir // .tool_input.workdir // .tool_input.cwd // .cwd // null)] | if all(.[]; . == null or type == "string") then "1" + (map((. // "") | split("\u0000") | join("") | @sh) | join(" ")) else "0" end) else "0" end' <<<"$INPUT" 2>/dev/null) || _GC_HDR=""
if [[ "$_GC_HDR" == 1* ]] && eval "_gc_hv=(${_GC_HDR:1})" 2>/dev/null && [[ ${#_gc_hv[@]} -eq 3 ]]; then
  TOOL_NAME="${_gc_hv[0]}"; _GC_CMD_H="${_gc_hv[1]}"; _GC_CWD_H="${_gc_hv[2]}"
  _gc_rtrim TOOL_NAME; _gc_rtrim _GC_CMD_H; _gc_rtrim _GC_CWD_H
  _GC_HDR_OK=1
else
  TOOL_NAME=$(jq -r '.tool_name // empty' <<<"$INPUT" 2>/dev/null) || TOOL_NAME=""
fi
[[ -n "$TOOL_NAME" ]] || exit 0
_WG_CMD_OC=""
_wg_pre() {  # $1=변수명 $2=(미사용) $3=jq 식 — write_guard 에서 옮겨온 판정 블록이 쓰는 입력 읽기 도우미
  printf -v "$1" '%s' "$(jq -r "$3" <<<"$INPUT" 2>/dev/null || echo "")"
}

# ── F-GAS-CACHE (사이클218 C2): 자동 판정 기록(세션 logs/gas_cache/*.res·*.run) 위조 차단 ──
# 근거: goal_autoscript_run.sh 가 남기는 <세션>/logs/gas_cache/<key>.res(rc·epoch·elapsed)를 done_gate·otest 가 "이미 통과한 판정" 으로 재사용한다.
#   에이전트가 이 기록을 직접 쓰면(file 도구·셸) 실행 없이 통과 판정을 위조할 수 있다. 사이클218 실측: 파일 도구 6종·셸 6종 12꼴이 전부 rc=0 이었다.
# 판정(쓰기·삭제 대상 위치만 본다 — 읽기와 판정 CLI 실행은 통과):
#   ① file 도구(write·edit·delete·copy·move·rename·symlink·dir_*): 쓰이거나 지워지는 경로가 `(^|/)logs/gas_cache(/|$)` 이면 차단.
#      경로는 원문·realpath -m -s·realpath -m 세 형태 모두 본다(상대경로·`..`·링크 경유).
#   ② 셸(bash_exec·Bash): 명령 문자열의 따옴표·역슬래시를 지운 뒤 gas_cache 가 쓰기 대상 위치에 있을 때만 차단한다.
#      대상 위치 = 리다이렉트(`>`·`>>`·`>|`·`&>`) 뒤 단어, tee·touch·rm·unlink·shred·truncate·rmdir·mv 의 인자, cp·install·rsync·ln 의 목적지(마지막 단어·-t),
#      sed·perl -i 의 인자, dd of=, find 의 -delete·-exec(쓰기 동사), xargs 쓰기 동사(앞 구간에 gas_cache), 인터프리터의 쓰기 표지, `cd gas_cache` 뒤 쓰기.
#      변수 경유(`D=…/gas_cache; echo x > $D/a.res`)는 NAME=값 대입을 읽어 값이 gas_cache 인 변수를 대상 단어에서 풀어 판정한다. 글롭(gas_c*·gas_*)도 같은 패턴으로 본다.
#   통과: ls·cat·grep·head·tail·wc·stat·sha256sum·jq·-delete 없는 find, 판정 CLI(`bash …/goal_autoscript_run.sh --goal …` — 명령 문자열에 gas_cache 없음),
#         done_gate 시험 하네스(스크립트 안에서 임시 gas_cache 를 씀 — 명령 문자열에 gas_cache 없음).
# 다른 세션의 gas_cache 경로도 같이 막는다(타 세션 파일 쓰기 금지 §(a) 와 일치). hook 프로세스(done_gate 의 setsid)는 도구 호출이 아니라 이 판정을 만나지 않는다.
# [사이클219 C4] 스크립트 파일 간접화: 명령이 실행하는 스크립트 본문(셸·python 등, 깊이 2)도 같은 규칙으로 본다(④, lib/gas_cache_script_scan.py).
# 잔존 한계: `g=gas; ${g}_cache`·base64 같은 문자열 조립 · 변수로 준 스크립트 경로(bash $F) · cat f | bash · eval "$(cat f)" ·
#   xargs/find -exec/make 경유 실행 · 깊이 3 이상 · 256KB 초과 · 도우미 2초 초과(통과) · 허용 목록 파일 자체를 바꾼 뒤 실행(동일 uid 위조, 비목표).
# _FW_REDIRECT 는 쓰지 않는다 — 차단은 F-NO-BYPASS 기록부에 BLOCK 으로 남는다(셸 재시도 연계 유지).
_GC_PATH_RE='(^|/)logs/gas_cache(/|$)'
# [TODO-038] 앞이 식별자 문자(영숫자·밑줄)가 아닐 때만 맞춘다 — test_gas_cache_guard.sh 같은 파일명은 대상이 아니다(실제 대상 logs/gas_cache 는 앞이 '/')
_GC_STR_RE='(^|[^A-Za-z0-9_])gas_(c|[*?[])'
# [TODO-038] 인터프리터 쓰기 표지는 호출 꼴만 센다 — write_guard.sh·errors=replace 같은 이름·문자열은 쓰기가 아니다.
#   ⓐ 이름(+대문자·밑줄로 잇는 변형) 뒤 '(' ⓑ 괄호 없는 perl 꼴(unlink \$f 등, 앞이 식별자 문자가 아님) ⓒ open(…, w|a|x|+)
_GC_WR_RE='(write|writelines|write_text|write_bytes|writeFile|writeFileSync|appendFile|appendFileSync|truncate|unlink|unlinkSync|remove|rename|replace|rmtree|move|copyfile|copy2|copy|symlink|chmod|dump|file_put_contents|fwrite)([A-Z_][A-Za-z0-9_]*)?[[:space:]]*\(|(^|[^A-Za-z0-9_])(unlink|rename|truncate|chmod|symlink|remove|rmtree|move|copy)[[:space:]]+[$@A-Za-z0-9_./~]|open[[:space:]]*\([^)]*,[[:space:]]*[wax+]'
_GC_CTX=""   # [사이클219] 판정 출처 꼬리표 — 스크립트 본문 판정이면 "스크립트 <경로> 안 "
# [사이클219] 스크립트 실행 꼴 사전 필터(정밀 판정은 lib/gas_cache_script_scan.py) — 인터프리터+공백+비옵션 단어, 또는 구간 머리의 ./ ../ / 경로
_GC_EXEC_RE='(^|[[:space:];&|(`])(bash|sh|dash|zsh|ksh|mksh|source|\.|python[0-9.]*|perl|node|nodejs|ruby|php)[[:space:]]+[^[:space:]]|(^|[;&|(`])[[:space:]]*\.{0,2}/[^[:space:]]'
_GC_DER_RE='cache|base64|\\x[0-9a-fA-F]{2}|\\[0-7]{3}'   # [사이클220 D5] 명령 문자열 조립 사전 필터
_gc_block() {  # $1=차단 위치 설명 — JSON 이스케이프는 jq 가 맡는다(L-765)
  local _r
  _r="🚫 [F-GAS-CACHE] 세션 logs/gas_cache 의 판정 기록(.res·.run)은 에이전트가 직접 쓰거나 지울 수 없습니다(${_GC_CTX}${1:-?}). 기록은 판정 CLI(goal_autoscript_run.sh --goal … --id …)를 실행한 결과로만 생깁니다 — 같은 CLI 를 다시 실행하십시오. 표현을 바꾸거나 다른 도구로 우회하지 마십시오(L-597)."
  # [사이클221 iter1] JSON 이스케이프는 jq 와 같은 규칙(\ " \n \t \r)을 셸로 직접 한다 — 그 밖의 제어 문자가 남으면 종전 jq 경로(바이트 동일 출력 유지)
  local _e="${_r//\\/\\\\}"; _e="${_e//\"/\\\"}"; _e="${_e//$'\n'/\\n}"; _e="${_e//$'\t'/\\t}"; _e="${_e//$'\r'/\\r}"
  if [[ "$_e" != *[[:cntrl:]]* ]]; then printf '{"decision":"block","reason":"%s"}\n' "$_e"; exit 2; fi
  jq -cn --arg r "$_r" '{decision:"block",reason:$r}' 2>/dev/null || echo '{"decision":"block","reason":"🚫 [F-GAS-CACHE] 세션 logs/gas_cache 의 판정 기록은 에이전트가 직접 쓰거나 지울 수 없습니다. 판정 CLI 를 실행하십시오."}'
  exit 2
}
_gc_path_hit() {  # $1=경로 → gas_cache 아래이면 0
  local _p="$1" _a _b
  [[ -n "$_p" ]] || return 1
  [[ "$_p" =~ $_GC_PATH_RE ]] && return 0
  _a=$(realpath -m -s -- "$_p" 2>/dev/null) || _a=""
  [[ -n "$_a" && "$_a" =~ $_GC_PATH_RE ]] && return 0
  _b=$(realpath -m -- "$_p" 2>/dev/null) || _b=""
  [[ -n "$_b" && "$_b" =~ $_GC_PATH_RE ]] && return 0
  return 1
}
case "$TOOL_NAME" in
  mcp__oio__file_write|mcp__oio__file_edit|mcp__oio__file_delete|mcp__oio__file_copy|mcp__oio__file_move|mcp__oio__file_rename|mcp__oio__file_symlink|\
  mcp__oio__dir_create|mcp__oio__dir_delete|mcp__oio__dir_move|mcp__oio__dir_rename|Write|Edit|MultiEdit|NotebookEdit)
    # 이름 문자열 사전 필터 — 입력 어디에도 gas_cache 가 없으면(상대경로 `..` 조립 포함 최소 gas_ 가 없으면) 판정을 건너뛴다.
    if [[ "$INPUT" == *gas_* ]]; then
      _GC_SEL='[.path,.file_path,.filepath,.notebook_path,.destination,.dest,.dst,.to,.link_path,.link,.new_path,.target]'
      case "$TOOL_NAME" in
        mcp__oio__file_symlink) _GC_SEL='[.path,.file_path,.destination,.dest,.dst,.link_path,.link,.new_path]' ;;
        mcp__oio__file_move|mcp__oio__dir_move) _GC_SEL='[.path,.file_path,.filepath,.destination,.dest,.dst,.to,.new_path,.source,.src,.target]' ;;
      esac
      _GC_SRC=$(jq -r '.tool_input | [.path,.file_path,.source,.src] | map(select(type=="string" and . != ""))[0] // empty' <<<"$INPUT" 2>/dev/null) || _GC_SRC=""
      while IFS= read -r _gc_p; do
        [[ -n "$_gc_p" ]] || continue
        _gc_path_hit "$_gc_p" && _gc_block "${TOOL_NAME##*__} 대상 ${_gc_p}"
        # 목적지가 디렉터리이거나 '/' 로 끝나면 실제로 생기는 경로 = 목적지/basename(원본)
        if [[ -n "$_GC_SRC" && ( "$_gc_p" == */ || -d "$_gc_p" ) ]]; then
          _gc_path_hit "${_gc_p%/}/$(basename -- "$_GC_SRC")" && _gc_block "${TOOL_NAME##*__} 대상 ${_gc_p}"
        fi
      done < <(jq -r ".tool_input | ${_GC_SEL} | map(select(type==\"string\" and . != \"\"))[]" <<<"$INPUT" 2>/dev/null)
      if [[ "$TOOL_NAME" == "mcp__oio__file_rename" || "$TOOL_NAME" == "mcp__oio__dir_rename" ]]; then
        while IFS= read -r _gc_p; do
          [[ -n "$_gc_p" ]] || continue
          [[ "$_gc_p" == /* ]] || _gc_p="$(dirname -- "${_GC_SRC:-.}")/$_gc_p"
          _gc_path_hit "$_gc_p" && _gc_block "${TOOL_NAME##*__} 대상 ${_gc_p}"
        done < <(jq -r '.tool_input | [.new_name,.name] | map(select(type=="string" and . != ""))[]' <<<"$INPUT" 2>/dev/null)
      fi
    fi
    ;;
  mcp__oio__bash_exec|Bash)
    if [[ -n "$_GC_HDR_OK" ]]; then _GC_CMD="$_GC_CMD_H"; else _wg_pre _GC_CMD "$_WG_CMD_OC" '.tool_input.command // .tool_input.cmd // empty'; fi
    # [사이클219 C4] 셸 판정을 함수로 묶었다 — 명령 문자열과, 그 명령이 실행하는 스크립트 파일 본문(④)에 같은 규칙을 쓴다.
    _gc_shell_judge() {  # $1=셸 텍스트 → 쓰기 대상 위치에 gas_cache 가 있으면 _gc_block(rc=2 종료), 아니면 0
    local _GC_N; _gc_c_unq _GC_N "$1"   # 따옴표·역슬래시 제거 — gas_"cache"·gas_\cache 같은 쪼개기를 같은 단어로 본다([TODO-022] C 로케일 도우미)
    if [[ "$_GC_N" =~ $_GC_STR_RE ]]; then
      # 변수 대입에서 값이 gas_cache 인 변수 이름을 모은다(두 번 돌려 변수가 변수를 가리키는 꼴까지).
      _GC_VARS=" "
      _GC_ASG=""   # [사이클221 iter1] 패턴이 '=' 를 요구하므로 '=' 가 없으면 grep 프로세스를 띄우지 않는다(결과 동일: 빈 목록)
      if [[ "$_GC_N" == *=* ]]; then _GC_ASG=$(printf '%s' "$_GC_N" | grep -oP '(?<![\w$])[A-Za-z_][A-Za-z0-9_]*=[^\s;&|]*' 2>/dev/null) || _GC_ASG=""; fi
      for _gc_pass in 1 2; do
        while IFS= read -r _gc_l; do
          [[ -n "$_gc_l" ]] || continue
          _gc_n="${_gc_l%%=*}"; _gc_v="${_gc_l#*=}"
          [[ "$_GC_VARS" == *" $_gc_n "* ]] && continue
          if [[ "$_gc_v" =~ $_GC_STR_RE ]]; then _GC_VARS+="$_gc_n "; continue; fi
          for _gc_x in $_GC_VARS; do
            # [TODO-022] 변수 이름 경계를 본다 — 종전 부분 문자열 비교는 $G 를 $GC_PERF 의 접두로 잡아 과차단했다
            _gc_vre='\$[{]?'"$_gc_x"'([^A-Za-z0-9_]|$)'
            if [[ "$_gc_v" =~ $_gc_vre ]]; then _GC_VARS+="$_gc_n "; break; fi
          done
        done <<<"$_GC_ASG"
      done
      _gc_has() {  # $1=단어 → gas_cache(글롭 포함) 이거나 gas_cache 변수를 푸는 단어이면 0
        local _w="$1" _v _vre
        [[ "$_w" =~ $_GC_STR_RE ]] && return 0
        for _v in $_GC_VARS; do
          _vre='\$[{]?'"$_v"'([^A-Za-z0-9_]|$)'   # [TODO-022] 변수 이름 경계(접두 일치 과차단 정정)
          [[ "$_w" =~ $_vre ]] && return 0
        done
        return 1
      }
      _GC_ANYW=""   # gas 와 무관한 쓰기 의도 존재 여부(cd gas_cache 뒤 상대경로 쓰기 판정용)
      # ① 리다이렉트 대상 — `>`·`>>`·`>|`·`&>` 뒤 단어(>&2·2>&1 의 &숫자 는 단어 시작이 아니라 제외)
      # [사이클221 iter1] 패턴이 '>' 를 요구하므로 '>' 가 없으면 grep 프로세스를 띄우지 않는다(결과 동일: 빈 목록)
      while IFS= read -r _gc_t; do
        [[ -n "$_gc_t" ]] || continue
        case "$_gc_t" in /dev/null|/dev/stdout|/dev/stderr|/dev/fd/*|/dev/tty) continue ;; esac
        _GC_ANYW=1
        _gc_has "$_gc_t" && _gc_block "리다이렉트 대상 ${_gc_t}"
      done < <([[ "$_GC_N" == *'>'* ]] && printf '%s' "$_GC_N" | grep -oP '(?<![<>])[0-9]*&?>>?\|?\s*\K[^\s;&|<>()]+' 2>/dev/null)
      # ② 구간별 동사 — 구간 첫 명령 위치의 동사와 그 인자를 본다
      _gc_c_segs _GC_SEGS "$_GC_N"   # [TODO-022] 종전 치환 5단계와 같은 결과를 C 로케일로 만든다
      _GC_PREV_HAS=""; _GC_CD=""
      _GC_STRIP='[(){}]'
      while IFS= read -r _gc_seg; do
        [[ -n "${_gc_seg//[[:space:]]/}" ]] || continue
        _gc_w=(); IFS=$' \t' read -r -a _gc_w <<<"$_gc_seg"
        # 단어에서 괄호를 벗기고 명령 위치를 찾는다 — NAME=값 대입과 sudo·env·nohup·command·time·setsid·exec 래퍼, sh -c 는 건너뛴다.
        _gc_i=0; _gc_n=${#_gc_w[@]}; _gc_vb=""; _gc_via_x=""
        while [[ $_gc_i -lt $_gc_n ]]; do
          _gc_c="${_gc_w[_gc_i]//$_GC_STRIP/}"
          case "$_gc_c" in
            "") _gc_i=$((_gc_i + 1)); continue ;;
            [A-Za-z_]*=*) _gc_i=$((_gc_i + 1)); continue ;;
            sudo|env|nohup|command|time|setsid|exec|nice|stdbuf|builtin) _gc_i=$((_gc_i + 1)); continue ;;
            bash|sh|dash|zsh|ksh)  # -c 가 있으면 -c 다음 단어가 안쪽 명령의 시작
              _gc_j=$((_gc_i + 1)); _gc_found=""
              while [[ $_gc_j -lt $_gc_n ]]; do
                [[ "${_gc_w[_gc_j]}" == "-c" ]] && { _gc_found=1; break; }
                _gc_j=$((_gc_j + 1))
              done
              if [[ -n "$_gc_found" ]]; then _gc_i=$((_gc_j + 1)); continue; fi
              break ;;
            *) break ;;
          esac
        done
        [[ $_gc_i -lt $_gc_n ]] || continue
        _gc_vb="${_gc_w[_gc_i]//$_GC_STRIP/}"; _gc_vb="${_gc_vb##*/}"
        # xargs — 첫 쓰기 동사를 찾아 그것을 동사로 본다(앞 구간에 gas_cache 가 있었는지로 판정)
        if [[ "$_gc_vb" == "xargs" ]]; then
          _gc_j=$((_gc_i + 1)); _gc_vx=""
          while [[ $_gc_j -lt $_gc_n ]]; do
            _gc_c="${_gc_w[_gc_j]//$_GC_STRIP/}"
            case "$_gc_c" in rm|unlink|shred|truncate|touch|rmdir|mv|tee|cp|install|rsync|ln|sed|perl|dd) _gc_vx="$_gc_c"; break ;; esac
            _gc_j=$((_gc_j + 1))
          done
          if [[ -n "$_gc_vx" ]]; then
            _GC_ANYW=1
            [[ -n "$_GC_PREV_HAS" ]] && _gc_block "xargs ${_gc_vx} 로 gas_cache 항목을 쓰거나 지움"
            _gc_i=$_gc_j; _gc_vb="$_gc_vx"
          fi
        fi
        # 이 구간의 gas 단어(동사 제외)
        _gc_hits=""; _gc_last=""; _gc_tdir=""; _gc_k=$((_gc_i + 1)); _gc_sedi=""
        while [[ $_gc_k -lt $_gc_n ]]; do
          _gc_c="${_gc_w[_gc_k]//$_GC_STRIP/}"
          [[ -n "$_gc_c" ]] || { _gc_k=$((_gc_k + 1)); continue; }
          if [[ "$_gc_c" == -t || "$_gc_c" == --target-directory ]]; then
            _gc_tdir="${_gc_w[_gc_k+1]//$_GC_STRIP/}"; _gc_k=$((_gc_k + 2)); continue
          fi
          [[ "$_gc_c" == --target-directory=* ]] && _gc_tdir="${_gc_c#*=}"
          [[ "$_gc_c" =~ ^-[a-zA-Z]*i[a-zA-Z.]*$ || "$_gc_c" == --in-place || "$_gc_c" == --in-place=* ]] && _gc_sedi=1
          if [[ "$_gc_c" == -* && "$_gc_c" != of=* ]]; then _gc_k=$((_gc_k + 1)); continue; fi
          if [[ "$_gc_c" == of=* ]]; then
            _gc_has "${_gc_c#of=}" && [[ "$_gc_vb" == dd ]] && _gc_block "dd of= 대상 ${_gc_c#of=}"
            _gc_k=$((_gc_k + 1)); continue
          fi
          _gc_last="$_gc_c"
          _gc_has "$_gc_c" && _gc_hits+="$_gc_c "
          _gc_k=$((_gc_k + 1))
        done
        case "$_gc_vb" in
          rm|unlink|shred|truncate|touch|rmdir|mv|tee)
            _GC_ANYW=1
            [[ -n "$_gc_hits" ]] && _gc_block "${_gc_vb} 대상 ${_gc_hits}"
            [[ -n "$_gc_tdir" ]] && _gc_has "$_gc_tdir" && _gc_block "${_gc_vb} 대상 ${_gc_tdir}"
            ;;
          cp|install|rsync|ln)
            _GC_ANYW=1
            [[ -n "$_gc_tdir" ]] && _gc_has "$_gc_tdir" && _gc_block "${_gc_vb} 목적지 ${_gc_tdir}"
            [[ -n "$_gc_last" ]] && _gc_has "$_gc_last" && _gc_block "${_gc_vb} 목적지 ${_gc_last}"
            ;;
          sed|perl)
            if [[ -n "$_gc_sedi" ]]; then
              _GC_ANYW=1
              [[ -n "$_gc_hits" ]] && _gc_block "${_gc_vb} -i 대상 ${_gc_hits}"
            fi
            ;;
          python|python2|python3|node|ruby|php|perl)
            :
            ;;
          find)
            if [[ -n "$_gc_hits" && "$_gc_seg" =~ (^|[[:space:]])(-delete|-fprint[0-9a-z]*|-fls)([[:space:]]|$) ]]; then
              _gc_block "find 가 gas_cache 항목을 지움"
            fi
            if [[ -n "$_gc_hits" && "$_gc_seg" =~ (^|[[:space:]])-exec(dir)?[[:space:]]+(rm|unlink|shred|truncate|touch|mv|tee|cp|install|rsync|ln|sed|perl|dd)([[:space:]]|$) ]]; then
              _gc_block "find -exec 가 gas_cache 항목을 쓰거나 지움"
            fi
            ;;
          cd|pushd)
            [[ -n "$_gc_hits" ]] && _GC_CD="$_gc_hits"
            ;;
        esac
        # 인터프리터 — gas_cache 가 보이고 쓰기 표지가 있을 때만(경로를 인자로 받는 읽기 스크립트는 통과)
        case "$_gc_vb" in
          python|python[0-9]*|node|nodejs|ruby|php|perl)
            if [[ -n "$_gc_hits" || "$_gc_seg" =~ $_GC_STR_RE ]]; then
              if [[ "$_gc_seg" =~ $_GC_WR_RE ]]; then
                _GC_ANYW=1
                _gc_block "${_gc_vb} 가 gas_cache 에 쓰기 호출"
              fi
            fi
            ;;
        esac
        [[ -n "$_gc_hits" ]] && _GC_PREV_HAS=1
        _gc_has "$_gc_seg" && _GC_PREV_HAS=1
      done <<<"$_GC_SEGS"
      # ③ cd gas_cache 뒤 상대경로 쓰기 — 같은 명령에 쓰기 의도(리다이렉트·쓰기 동사)가 하나라도 있으면 차단
      [[ -n "$_GC_CD" && -n "$_GC_ANYW" ]] && _gc_block "gas_cache 로 이동한 뒤 쓰기(${_GC_CD})"
    fi
    return 0
    }
    _gc_shell_judge "$_GC_CMD"
    # ④ (사이클219 C4) 명령이 실행하는 스크립트 파일 본문 — bash|sh|source|.|python3 등 + 파일, ./x·/abs/x 직접 실행.
    #   lib/gas_cache_script_scan.py 가 파일을 찾아(깊이 2·16개·256KB) 셸 본문은 전처리해 넘기고, 인터프리터 본문은 직접 판정한다.
    #   허용: 판정 CLI(lib/goal_autoscript_run.sh)·tests/test_gas_*.sh. 도우미 시간 초과·오류는 통과(fail-open, 잔존 한계).
    #   fail-open 이유: 이 ④ 는 간접화 보강용 추가 검사다. 도우미 장애(파이썬 부재·2초 초과)로 정상 명령까지 막으면 모든 bash_exec 가 멈추므로, 장애 시에는 기존 ①~③ 판정만 남기고 통과시킨다(계획 D5).
    # [사이클220 D5] 명령 문자열 자체의 조립(`g=gas; …${g}_cache`·`\x5f`·`base64 -d | sh`)도 도우미가 파생 본문으로 풀어 판정한다.
    #   사전 필터 _GC_DER_RE(cache·base64·\xHH·\NNN)에 걸릴 때만 도우미를 부른다 — 그 밖의 명령은 종전과 같은 비용.
    # [사이클221 iter1] 사전 필터 _GC_DER_RE 에만 걸린 명령(스크립트 실행 꼴 아님)은 도우미가 낼 출력이 있을 수 있는 꼴일 때만 python 을 띄운다.
    #   도우미가 출력하려면 ⓐ 실행할 파일(실행 권한 있는 정규 파일 토큰·cd 류)이 있거나 ⓑ 명령 풀이본(전처리본)이 달라져야 한다 —
    #   ⓑ 는 $·역슬래시·따옴표·역따옴표·base64·줄 구분 문자(\r \v \f \x1c-\x1e \x85 U+2028/9)가 있을 때만 생긴다. 하나라도 있으면 종전처럼 도우미를 부른다.
    _gc_der_needs_py() {
      local _c="$_GC_CMD" _t _p _b="${_GC_CWD_H:-$PWD}" _tk=()
      [[ -n "$_GC_HDR_OK" ]] || return 0
      [[ "$_c" == *base64* || "$_c" == *\\* || "$_c" == *\$* || "$_c" == *\`* || "$_c" == *\'* || "$_c" == *\"* ]] && return 0
      [[ "$_c" == *$'\r'* || "$_c" == *$'\v'* || "$_c" == *$'\f'* || "$_c" == *$'\x1c'* || "$_c" == *$'\x1d'* || "$_c" == *$'\x1e'* ]] && return 0
      [[ "$_c" == *$'\xc2\x85'* || "$_c" == *$'\xe2\x80\xa8'* || "$_c" == *$'\xe2\x80\xa9'* ]] && return 0
      IFS=$' \t\n;&|()<>{}' read -r -d '' -a _tk <<<"$_c"
      for _t in "${_tk[@]}"; do
        case "$_t" in cd|pushd|popd) return 0 ;; esac
        [[ "$_t" == */* ]] || continue
        if [[ "$_t" == /* ]]; then _p="$_t"; else _p="$_b/$_t"; fi
        [[ -f "$_p" && -x "$_p" ]] && return 0
      done
      return 1
    }
    if [[ "$_GC_CMD" =~ $_GC_EXEC_RE ]] || { [[ "$_GC_CMD" =~ $_GC_DER_RE ]] && _gc_der_needs_py; }; then
      # [사이클221 iter1] readlink 프로세스 생략 — 이 파일 자체가 링크일 때만 풀고, 디렉터리 링크는 같은 경로로 lib 에 닿으므로 그대로 둔다(도우미가 스스로 realpath 한다)
      _GC_SCAN="${BASH_SOURCE[0]}"; [[ -L "$_GC_SCAN" ]] && _GC_SCAN="$(readlink -f -- "$_GC_SCAN")"
      case "$_GC_SCAN" in */*) _GC_SCAN="${_GC_SCAN%/*}/lib/gas_cache_script_scan.py" ;; *) _GC_SCAN="lib/gas_cache_script_scan.py" ;; esac
      if [[ -n "$_GC_HDR_OK" ]]; then _GC_CWD="$_GC_CWD_H"; else
        _GC_CWD=$(jq -r '.tool_input.working_dir // .tool_input.workdir // .tool_input.cwd // .cwd // empty' <<<"$INPUT" 2>/dev/null) || _GC_CWD=""
      fi
      [[ -n "$_GC_CWD" ]] || _GC_CWD="$PWD"
      if [[ -f "$_GC_SCAN" ]]; then
        # [사이클221 iter1] 도우미를 --rec 모드로 불러 결과를 NUL 로 끝맺은 4칸(kind·path·hit·body) 레코드로 받는다 — jq 프로세스 없음(종전: 출력 줄을 jq 로 풀었다).
        #   시간 초과(2초)·오류는 종전과 같이 통과(fail-open). 4칸이 다 안 찬 꼬리 레코드는 버린다(종전: 개행으로 끝나지 않은 잘린 줄을 버림).
        #   -S: site 초기화 생략(도우미는 표준 라이브러리만 쓴다 — 출력 동일, 기동 CPU 약 4ms 절감)
        _gc_rec=()
        mapfile -t -d '' _gc_rec < <(printf '%s' "$_GC_CMD" | python3 -I -S "$_GC_SCAN" "$_GC_CWD" --rec 2>/dev/null)   # 2초 상한은 도우미의 alarm(2)
        for (( _gc_r = 0; _gc_r + 3 < ${#_gc_rec[@]}; _gc_r += 4 )); do
          _gc_k="${_gc_rec[_gc_r]}"; _gc_sp="${_gc_rec[_gc_r+1]}"; _gc_h="${_gc_rec[_gc_r+2]}"; _gc_b="${_gc_rec[_gc_r+3]}"
          _gc_rtrim _gc_k; _gc_rtrim _gc_sp; _gc_rtrim _gc_b
          case "$_gc_sp" in "("*) _gc_cx="${_gc_sp} " ;; *) _gc_cx="스크립트 ${_gc_sp} 안 " ;; esac   # [사이클220 D5] 명령 파생 꼬리표
          if [[ "$_gc_k" == py ]]; then
            [[ "$_gc_h" == 1 ]] && { _GC_CTX="$_gc_cx"; _gc_block "인터프리터 쓰기 호출"; }
          elif [[ "$_gc_k" == sh ]]; then
            _GC_CTX="$_gc_cx"
            _gc_shell_judge "$_gc_b"
            _GC_CTX=""
          fi
        done
      fi
    fi
    ;;
esac
# --- F-GAS-CACHE 끝 ---

exit 0
