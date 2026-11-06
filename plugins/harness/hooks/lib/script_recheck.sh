#!/bin/bash
# 가드 차단 직후 작성된 스크립트를 실행할 때 본문을 gp_gate·F-ASKQ-PROT 규칙으로 다시 판정하는 모듈(L-604) — write_guard 가 source 한다
#
# ── 배경 (사이클181 실측, 계획 conv_179172975200 §2-1) ────────────────────────────────────────────
#   셸 명령이 F-GUARD-PROMOTE 로 막히자 같은 내용을 스크립트 파일에 써 두고 `bash x.sh` 로 실행하는 2단계 우회가 나왔다.
#   gp_gate 를 모든 스크립트 본문에 상시 적용하면 기존 코퍼스 189개 중 55개(29%)가 걸린다(거의 전부 정당한 가드 시험).
#   그래서 범위를 "같은 session_id 가 차단을 받은 뒤 SR_WINDOW_SEC(1800초) 안 + 차단 뒤(mtime ≥ 차단시각-2초) 작성된 스크립트"로 좁힌다.
#
# ── 계약 ───────────────────────────────────────────────────────────────────────────────────
#   sr_mark_block <tag> <session_id>
#       ${SR_MARK_DIR:-${HARNESS_HOME:-$HOME/.harness}/current/hooks/logs/recent_block}/<sid> 에 "<epoch> <tag>" 1줄을 원자 기록(tmp→mv)한다.
#       sid 는 [A-Za-z0-9_-] 밖의 문자를 _ 로 바꾼다(경로 이탈 없음). sid 가 비면 아무것도 안 한다. 출력 없음, 항상 0.
#       세션 격리: 자기 sid 이름의 파일 1개만 쓴다. 다른 세션 표식은 읽지도 쓰지도 않는다.
#   sr_window_applies <path> <block_epoch>   정규 파일이고 mtime ≥ block_epoch-2 이면 0, 아니면 1.
#   sr_body_hit <path> [cwd]
#       본문(≤262144 바이트)이 ⓐ gp_gate_check rc=2(호출자가 gp_gate.sh 를 source 해 둔 경우 — 적재된 모듈 정의를 하위 bash 로
#       넘겨 SR_BODY_TMO(기본 4초) 안에서 판정하므로 호출자 전역·log_hook_error 는 바뀌지 않는다) 또는 ⓑ F-ASKQ-PROT 무조건 항목
#       언급(소문자 본문에 baseline_untracked, 또는 projects 와 jsonl 동시 — write_guard ASKQ 셸 규칙과 같다)이면 0 + 사유 1줄, 아니면 1.
#       크기 초과(>262144)·판정 시간 초과는 판정할 수 없으므로 적중(0)으로 본다(창 안의 새 스크립트에만 쓰이므로 fail-closed).
#   sr_recheck <command> <session_id> <cwd>
#       표식 없음·창(SR_WINDOW_SEC, 기본 1800초) 초과 → 0(출력 없음).
#       명령을 구간(; && || | & 개행 $( ` 괄호 — 따옴표 안은 자르지 않음, 사이클205 D-6 _sr_split 참조)으로 나눠 스크립트 실행 형태를 뽑는다:
#         bash|sh|dash|zsh|ksh|mksh [옵션] <경로>   (-c·-n·-s 계열 옵션이면 파일 실행이 아니므로 제외, < 경로 입력도 본다)
#         source|. <경로>  ·  ./x · /abs/x · a/b 직접 실행(정규 파일·실행 권한)
#         앞의 nohup·timeout [옵션] N·env [옵션] A=B·nice [-n N]·setsid·time·command·exec·builtin·stdbuf·ionice·
#         VAR=값·{ ! then do else elif if while until 은 건너뛴다. 같은 명령 안의 `cd <리터럴>` 은 이후 구간의 기준 경로가 된다.
#       상대 경로는 cwd 기준. 경로마다 sr_window_applies 이면 sr_body_hit, 적중이면 stderr 에 경고 1줄
#       (표식 [F-SCRIPT-RECHECK]) + SR_LOG 에 warn_hit 1줄 후 rc=0, stdout 없음(사용자 지시 2026-10-27 13:31 — 차단 해제.
#       종전은 stdout block JSON + log_hook_error HOOK_BLOCK_SCRIPT_RECHECK 후 rc=2).
#       본문 안 중첩 실행은 깊이 2까지 같은 규칙(창 적용 파일만 내려간다)으로 본다. 경로는 최대 64개까지 본다.
#       내부 오류는 0(fail-open, hooks/logs/script_recheck.log 1줄) — 2차 방어층이다. 1차는 write_guard S1 지문 탐지(fail-closed).
#   공통  exit·set -e 를 쓰지 않는다. 공개 함수는 호출 동안 set +eu 로 돌고 호출자 옵션을 되돌린다(set -euo pipefail 아래에서도 안전).
#   환경  SR_WINDOW_SEC · SR_BODY_TMO(파일당 gp_gate 판정 상한 초, 기본 4) · SR_TOTAL_TMO(sr_recheck 1회 전체 상한 초, 기본 6 —
#         write_guard 시간 예산 9초 안. 초과 시 남은 창 안 스크립트는 판정 불가로 차단) · SR_MARK_DIR · SR_LOG(기본 ${HARNESS_HOME:-$HOME/.harness}/current/hooks/logs/script_recheck.log) · SR_NO_HOOKLOG=1(시험용 — log_hook_error 생략)
#
# ── 잔존 한계 (정직 고지) ─────────────────────────────────────────────────────────────────────
#   못 잡는 경로: python3/perl/node 등 sh 계열이 아닌 인터프리터로 실행하는 파일(python3 x.py) · bash -c "$(cat f)"·eval 처럼
#   본문을 명령 치환으로 넘기는 형태 · 변수로 준 경로(bash $F) · cat f | bash 처럼 표준입력 파이프 · xargs/find -exec/make 경유 실행 ·
#   공백이 든 경로 · NUL 바이트가 든 파일(바이너리로 보고 건너뜀) · 창(1800초) 만료 뒤 실행 · 다른 session_id(다른 세션/팀원)로 실행 ·
#   차단 전에 미리 써 둔 스크립트 · 깊이 3 이상 중첩. 보호 파일 자체는 S1 지문 탐지가 사후 원복 차단(fail-closed)한다.
#
# ── 작성자 기록부 (사이클196 과제1 — L-647 과차단 완화) ─────────────────────────────────────────────
#   종전에는 창이 mtime 만 봐서, 차단받은 sid 가 창 안에서 남(리드·다른 팀원)이 고친 가드 시험 스크립트를 실행해도 막혔다
#   (사이클195 실측 — otest-4 표식 뒤 odev-A4 가 고친 tests/test_wg_c194.sh 2회 차단).
#   sr_author_record <realpath> <session_id>
#       write_guard 가 파일 도구 쓰기를 최종 PASS 로 판정한 .sh/.bash 경로마다 부른다(hook 프로세스 내부 기록 — 도구 호출 아님).
#       ${SR_AUTHOR_DIR:-${HARNESS_HOME:-$HOME/.harness}/current/hooks/logs/script_author}/<sha1(정규 경로)> 에 "<epoch> <sid>" 1줄을 원자 기록(tmp→mv)한다.
#       정규 경로 = realpath -m, /mnt/ 아래(NTFS — 대소문자 무시)는 소문자로 접는다(${HARNESS_HOME:-$HOME/.harness}/current/hooks 의 실경로가 …/Project/ai/… 로 풀린다).
#       .sh/.bash 가 아니거나 sid 가 비면 아무것도 안 한다. 출력 없음, 항상 0.
#   예외 판정(_sr_scan): 창 적용 파일이라도 기록부의 마지막 작성자 sid ≠ 차단받은 sid 이고 파일 mtime·ctime 이 모두
#       [기록 epoch-2, 기록 epoch+SR_AUTHOR_SLACK(기본 60초 — oio NTFS 백오프 1+2+4+8=15초 여유)] 안이면 "다른 작성자의 마지막 쓰기
#       그대로" 로 보고 그 파일과 그 안의 중첩 실행을 건너뛴다(로그 exempt_other_author). 기록 없음·같은 sid·범위 밖·판독 실패는 종전 판정.
#       ctime 병행 근거(사이클196 실측): /tmp(ext4)·/mnt/c(drvfs) 둘 다 `touch -d` 로 mtime 만 되돌릴 수 있고 ctime 은 되돌릴 수 없다
#       — 셸 재수정 뒤 mtime 복원으로 예외를 얻는 경로를 ctime 이 막는다.
#   기록부·표식 보호: write_guard F-SR-PROT 가 recent_block/·script_author/ 에 대한 에이전트의 파일 도구 쓰기·삭제·이동과 셸 쓰기를
#       차단한다(읽기 허용). 이 모듈의 기록은 hook 프로세스 내부 쓰기라 그 판정을 만나지 않는다.
#   잔존 한계(사이클196): ① 차단받은 에이전트가 다른 팀원에게 스크립트 ★작성★을 맡기는 위임(기존 '다른 sid 실행' 한계와 같은 등급)
#       ② 다른 작성자 쓰기 뒤 SR_AUTHOR_SLACK 초 안의 셸 재수정 ③ .sh/.bash 가 아닌 실행 파일은 기록하지 않음(종전대로 판정 — fail-closed)
#       ④ F-SR-PROT 는 문자열 판정이라 cd 뒤 상대 경로·글롭·변수 간접화·git stash/checkout 같은 경로 없는 일괄 복원은 막지 못한다
#       ⑤ 파일 도구 쓰기가 write_guard PASS 뒤 다른 hook 에 막혀도 기록은 남는다(그 경우 파일 mtime 이 범위 밖이라 대개 예외가 안 난다).

_SR_MAX=262144

_sr_dir() { printf '%s' "${SR_MARK_DIR:-${HARNESS_HOME:-$HOME/.harness}/current/hooks/logs/recent_block}"; }

_sr_log() {
  local f="${SR_LOG:-${HARNESS_HOME:-$HOME/.harness}/current/hooks/logs/script_recheck.log}"
  { mkdir -p "${f%/*}" && printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$f"; } 2>/dev/null || true
  return 0
}

_sr_sid() { local s="${1:-}"; printf '%s' "${s//[^A-Za-z0-9_-]/_}"; }

# 공개 함수 감싸기 — 호출 동안 set +eu, 끝나면 호출자 옵션 복원
_sr_wrap() {  # $1=구현 함수 나머지=인자
  local _o="$-" _r=0 _fn="$1"; shift
  set +eu
  "$_fn" "$@" || _r=$?
  [[ "$_o" == *u* ]] && set -u
  [[ "$_o" == *e* ]] && set -e
  return "$_r"
}

# ── sr_mark_block ──
_sr_mark_block() {
  local tag="${1:-}" sid d tmp=""
  sid=$(_sr_sid "${2:-}")
  [[ -n "$sid" ]] || return 0
  tag="${tag//[^A-Za-z0-9_-]/_}"
  d=$(_sr_dir)
  if ! { mkdir -p "$d" && tmp=$(mktemp "$d/.${sid}.XXXXXX") && \
         printf '%s %s\n' "$(date +%s)" "${tag:-UNKNOWN}" >"$tmp" && mv -f "$tmp" "$d/$sid"; } 2>/dev/null; then
    [[ -n "$tmp" ]] && rm -f "$tmp" 2>/dev/null
    _sr_log "mark_fail sid=$sid tag=$tag"
  fi
  return 0
}
sr_mark_block() { _sr_wrap _sr_mark_block "$@"; return 0; }

# ── sr_window_applies ──
_sr_window_applies() {
  local p="${1:-}" e="${2:-}" m
  [[ -n "$p" && -f "$p" && "$e" =~ ^[0-9]+$ ]] || return 1
  m=$(stat -c %Y -- "$p" 2>/dev/null) || return 1
  [[ "$m" =~ ^[0-9]+$ ]] || return 1
  (( m >= e - 2 )) && return 0
  return 1
}
sr_window_applies() { _sr_wrap _sr_window_applies "$@"; }

# ── sr_author_record / _sr_other_author (사이클196 과제1) ──
_sr_author_dir() { printf '%s' "${SR_AUTHOR_DIR:-${HARNESS_HOME:-$HOME/.harness}/current/hooks/logs/script_author}"; }
_sr_author_key() {  # $1=경로 → stdout sha1(정규 경로)
  local c h
  c=$(realpath -m -- "${1:-}" 2>/dev/null) || return 1
  [[ -n "$c" ]] || return 1
  [[ "$c" == /mnt/* ]] && c="${c,,}"
  h=$(printf '%s' "$c" | sha1sum 2>/dev/null) || return 1
  h="${h%% *}"
  [[ "$h" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s' "$h"
}
_sr_author_record() {
  local p="${1:-}" sid k d tmp=""
  sid=$(_sr_sid "${2:-}")
  [[ -n "$p" && -n "$sid" ]] || return 0
  [[ "$p" == *.sh || "$p" == *.bash ]] || return 0
  k=$(_sr_author_key "$p") || return 0
  d=$(_sr_author_dir)
  if ! { mkdir -p "$d" && tmp=$(mktemp "$d/.${k}.XXXXXX") && \
         printf '%s %s\n' "$(date +%s)" "$sid" >"$tmp" && mv -f "$tmp" "$d/$k"; } 2>/dev/null; then
    [[ -n "$tmp" ]] && rm -f "$tmp" 2>/dev/null
    _sr_log "author_fail sid=$sid path=$p"
  fi
  return 0
}
sr_author_record() { _sr_wrap _sr_author_record "$@"; return 0; }

_sr_other_author() {  # $1=경로 $2=차단받은 sid(정규화) → 다른 작성자의 마지막 쓰기 그대로면 0 + stdout 작성자 sid
  local p="${1:-}" bs="${2:-}" k f line ep ws m c sl
  [[ -n "$p" && -n "$bs" && -f "$p" ]] || return 1
  k=$(_sr_author_key "$p") || return 1
  f="$(_sr_author_dir)/$k"
  [[ -f "$f" && ! -L "$f" ]] || return 1
  line=$(tail -n 1 -- "$f" 2>/dev/null) || return 1
  read -r ep ws <<<"$line"
  [[ "$ep" =~ ^[0-9]+$ && -n "$ws" && "$ws" != "$bs" ]] || return 1
  sl="${SR_AUTHOR_SLACK:-60}"; [[ "$sl" =~ ^[0-9]+$ ]] || sl=60
  read -r m c <<<"$(stat -c '%Y %Z' -- "$p" 2>/dev/null)"
  [[ "$m" =~ ^[0-9]+$ && "$c" =~ ^[0-9]+$ ]] || return 1
  (( m >= ep - 2 && m <= ep + sl && c >= ep - 2 && c <= ep + sl )) || return 1
  printf '%s' "$ws"
  return 0
}

# ── sr_body_hit ──
_sr_body_hit() {
  local p="${1:-}" cwd="${2:-}" sz body low grc=0 hit=""
  [[ -n "$p" && -f "$p" && -r "$p" ]] || return 1
  sz=$(stat -c %s -- "$p" 2>/dev/null) || return 1
  if (( sz > _SR_MAX )); then
    echo "본문 ${sz}바이트 > ${_SR_MAX} — 판정 한도 초과"
    return 0
  fi
  body=$(tr -d '\000' <"$p" 2>/dev/null) || return 1
  low="${body,,}"
  # 사이클206: 줄 전체 주석(첫 비공백 글자 #)은 실행되지 않으므로 아래 트랜스크립트 판정·gp_gate 판정에서 뺀다.
  local nc="" l
  while IFS= read -r l || [[ -n "$l" ]]; do
    [[ "$l" =~ ^[[:space:]]*# ]] && continue
    nc+="$l"$'\n'
  done <<<"$body"
  # ⓑ F-ASKQ-PROT 무조건 항목(write_guard ASKQ 셸 규칙과 같다)
  if [[ "$low" == *baseline_untracked* ]]; then
    echo "F-ASKQ-PROT 판정 적중 — baseline_untracked 언급"; return 0
  fi
  # ⓑ' 트랜스크립트 — 사이클206: 언급만으로 막지 않는다. 실행 줄(주석 제외)에 ★실제 트랜스크립트 루트★ 표지와 쓰기 수단이 함께 있을 때만 적중.
  #   실측 과차단: 승격기 시험(test_gp_self 계열)이 mktemp 루트 아래 "$1/projects/p/<uuid>.jsonl" 합성 픽스처를 만드는 본문이 막혔다.
  #   루트 표지 = .claude(~/.claude·$HOME/.claude·/home/*/.claude 간접 포함) · /tmp/cc-(CLAUDE_CONFIG_DIR 실체) · $CLAUDE_CONFIG_DIR 참조(대입 제외).
  #   쓰기 수단 = /dev/null 외 리다이렉트 · tee cp mv rm ln truncate dd install rsync shred unlink touch patch · sed/perl -i · open( · write( 계열.
  #   (보수적: 실제 루트를 읽고 다른 곳에 쓰는 본문도 적중한다 — 재판정 창 1800초 안에서만)
  if [[ "$low" == *projects* && "$low" == *jsonl* ]]; then
    local q="${nc,,}" wr=0
    q="${q//[\'\"\\]/}"
    if [[ "$q" =~ \.claude|/tmp/cc-|\$\{?claude_config_dir ]]; then
      while [[ "$q" =~ (\&|[0-9]*)\>\>?[[:space:]]*/dev/null|[0-9]*\>\&[0-9]+ ]]; do q="${q/"${BASH_REMATCH[0]}"/ }"; done
      if [[ "$q" == *">"* ]] \
         || [[ "$q" =~ (^|[^a-z0-9_.-])(tee|cp|mv|rm|ln|truncate|dd|install|rsync|shred|unlink|touch|patch)([^a-z0-9_.-]|$) ]] \
         || [[ "$q" =~ (sed|perl)[^\;\|\&]*[[:space:]]-[a-z]*i ]] \
         || [[ "$q" =~ open\(|write_text|write_bytes|\.write\(|os\.(remove|unlink|rename|replace)|shutil\. ]]; then
        wr=1
      fi
    fi
    if (( wr )); then
      echo "F-ASKQ-PROT 판정 적중 — 트랜스크립트 루트(projects·jsonl) + 쓰기 수단"; return 0
    fi
  fi
  # ⓐ gp_gate — 호출자가 source 해 둔 경우만. 호출자가 적재한 모듈 정의를 그대로 하위 bash 로 넘겨
  #    시간 상한(SR_BODY_TMO, 기본 4초) 안에서 판정한다 — 호출자 전역(TOOL_NAME·_GP_TI·INPUT·_GPG_*·log_hook_error)은 건드리지 않는다.
  #    (gp_gate 셸 판정은 큰 본문에서 수 초~수십 초가 걸릴 수 있다 — write_guard 시간 예산 9초 보호)
  declare -F gp_gate_check >/dev/null 2>&1 || return 1
  local defs fns vars tmo inp out
  fns=$(compgen -A function _gpg_ 2>/dev/null | tr '\n' ' ')
  vars=$(compgen -v _GPG_ 2>/dev/null | grep -vxE '_GPG_(HIT|TI|W|X|CWD)' | tr '\n' ' ')
  # shellcheck disable=SC2086
  defs="$(declare -f gp_gate_check $fns 2>/dev/null)"$'\n'"$( [[ -n "$vars" ]] && declare -p $vars 2>/dev/null)"
  if (( ${#defs} > 120000 )); then          # 환경변수 한 개 한도(128KiB) 안쪽만 넘긴다
    _sr_log "gp_gate_defs_too_large size=${#defs} path=$p"; return 1
  fi
  tmo="${SR_BODY_TMO:-4}"; [[ "$tmo" =~ ^[0-9]+$ ]] || tmo=4
  if [[ -n "$cwd" ]]; then
    inp=$(jq -cn --arg d "$cwd" '{tool_input:{cwd:$d}}' 2>/dev/null) || inp=""
  else
    inp="${INPUT:-}"
  fi
  [[ -n "$inp" ]] || inp='{}'
  # 사이클206: gp_gate 에는 주석 줄을 뺀 본문(nc — 위에서 만든다)을 넘긴다.
  #   gp_gate 는 $·( ) 등이 있어 단위를 확정할 수 없으면 명령 전체(=스크립트 본문 전체)에서 보호 토큰과 쓰기 수단을 따로 찾는다.
  #   그래서 주석 사용법 줄의 승격 경로 이름 + /tmp 쓰기가 합쳐져 적중했다(c206_run.sh 실측). 실행 줄의 토큰·쓰기는 그대로 판정한다.
  # 사이클206 판정 캐시: 평상 부하(load 4~10)에서도 큰 시험 본문이 4초를 넘겨 '판정 불가 = 적중'으로 막혔다(NEW-O35 실측).
  #   키 = sha256(주석 제외 본문 · 판정 입력(cwd) · gp_gate 적재 정의 · 이 라이브러리 원문) — 본문·판정기 어느 쪽이 바뀌어도 무효.
  #   위치 = 차단 세션의 session-env/<sid>/logs/recent_block/sr_cache/ — 경로 성분 recent_block 은 write_guard F-SR-PROT 가
  #   에이전트 쓰기를 막는다(위조 방지). 읽을 때 심볼릭링크·realpath 불일치 항목은 버린다. 유효 기간 SR_CACHE_TTL(기본 1800초).
  #   시간 초과 시: 캐시가 없으면 백그라운드로 SR_BG_TMO(기본 60초) 판정을 이어 돌려 캐시를 채우고, 이번 호출은 차단한다(fail-closed 유지).
  local key="" cf=""
  cf=$(_sr_cache_file "$nc" "$inp" "$defs") && key=1
  if [[ -n "$key" ]]; then
    if _sr_cache_read "$cf"; then
      case "$_SR_CR" in
        PASS) _sr_log "cache_pass path=$p"; return 1 ;;
        HIT)  echo "${_SR_CW:-F-GUARD-PROMOTE 판정 적중} (판정 캐시)"; return 0 ;;
      esac
    fi
  fi
  out=$(_sr_gp_judge "$nc" "$inp" "$defs" "$tmo"); grc=$?
  if (( grc == 124 || grc == 137 )); then
    if [[ -n "$key" ]] && _sr_cache_bg "$cf" "$nc" "$inp" "$defs" "$p"; then
      echo "판정 시간 초과(${tmo}초) — 백그라운드 판정 중(최대 ${SR_BG_TMO:-60}초). 잠시 뒤 같은 명령을 재시도하라"
    else
      echo "판정 시간 초과(${tmo}초) — 본문을 판정할 수 없다"
    fi
    return 0
  fi
  case "$out" in
    2$'\t'*) hit="${out#*$'\t'}"; hit="F-GUARD-PROMOTE 판정 적중 — ${hit:-승격 경로 구성요소 변경}"
             [[ -n "$key" ]] && _sr_cache_write "$cf" HIT "$hit"
             echo "$hit"; return 0 ;;
    0$'\t'*) [[ -n "$key" ]] && _sr_cache_write "$cf" PASS ""
             return 1 ;;
    "") _sr_log "gp_gate_subproc_empty rc=$grc path=$p"; return 1 ;;
    *) _sr_log "gp_gate_subproc_unexpected rc=$grc out=${out:0:80} path=$p"; return 1 ;;
  esac
}

# ── gp_gate 본문 판정 하위 프로세스: $1=본문 $2=판정 입력 JSON $3=정의 $4=상한 초 → stdout "rc<TAB>사유", 반환 = timeout 의 rc ──
_sr_gp_judge() {
  jq -cn --arg c "$1" '{command:$c}' 2>/dev/null | \
    SR_DEFS="$3" SR_INPUT="$2" timeout -k 1 "$4" bash -c '
      eval "$SR_DEFS" 2>/dev/null
      log_hook_error() { :; }               # 재판정은 실제 차단 기록이 아니다
      TOOL_NAME=mcp__oio__bash_exec; INPUT="$SR_INPUT"; _GP_TI=$(cat)
      [[ -n "$_GP_TI" ]] || { echo "E"; exit 0; }
      gp_gate_check >/dev/null 2>&1; r=$?
      printf "%s\t%s\n" "$r" "${_GPG_HIT:-}"' 2>/dev/null
}

# ── 판정 캐시(사이클206) ──
_sr_cache_dir() {  # stdout 캐시 디렉터리(차단 세션 sid 가 있을 때만)
  [[ -n "${_SR_SID:-}" ]] || return 1
  printf '%s' "${SR_CACHE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${_SR_SID}/logs/recent_block/sr_cache}"
}
_sr_cache_file() {  # $1=본문 $2=입력 $3=정의 → stdout 캐시 파일 경로
  local d k
  d=$(_sr_cache_dir) || return 1
  k=$( { printf '%s\0' "$1" "$2" "$3"; cat -- "${BASH_SOURCE[0]}" 2>/dev/null; } | sha256sum 2>/dev/null ) || return 1
  k="${k%% *}"
  [[ "$k" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s/%s' "$d" "$k"
}
_sr_cache_read() {  # $1=캐시 파일 → _SR_CR(PASS|HIT)·_SR_CW(사유), 0=유효
  local f="$1" ce d x
  _SR_CR=""; _SR_CW=""
  [[ -f "$f" && ! -L "$f" && -O "$f" ]] || return 1
  d="${f%/*}"
  # 캐시 파일·sr_cache·recent_block·logs 중 하나라도 심볼릭링크면 버린다(다른 곳에 미리 만든 항목으로 바꿔치기 방지)
  for x in "$d" "${d%/*}" "${d%/*/*}"; do
    [[ -L "$x" ]] && { _sr_log "cache_reject_link path=$x"; return 1; }
  done
  IFS=$'\t' read -r _SR_CR ce _SR_CW < "$f" 2>/dev/null || return 1
  [[ "$ce" =~ ^[0-9]+$ ]] || return 1
  local ttl="${SR_CACHE_TTL:-1800}"; [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=1800
  (( $(date +%s) - ce <= ttl )) || return 1
  [[ "$_SR_CR" == PASS || "$_SR_CR" == HIT ]]
}
_sr_cache_write() {  # $1=캐시 파일 $2=PASS|HIT $3=사유
  local f="$1" d="${1%/*}" t
  mkdir -p -- "$d" 2>/dev/null || return 1
  t="$f.tmp.$$"
  printf '%s\t%s\t%s\n' "$2" "$(date +%s)" "${3//$'\t'/ }" > "$t" 2>/dev/null && mv -f -- "$t" "$f" 2>/dev/null || { rm -f -- "$t"; return 1; }
  return 0
}
_sr_cache_bg() {  # $1=캐시 파일 $2=본문 $3=입력 $4=정의 $5=스크립트 경로 — 백그라운드 판정 시작(이미 진행 중이면 0)
  local f="$1" lk="$1.pending" bt="${SR_BG_TMO:-60}"
  [[ "$bt" =~ ^[0-9]+$ && "$bt" -gt 0 ]] || bt=60
  mkdir -p -- "${f%/*}" 2>/dev/null || return 1
  if ! mkdir -- "$lk" 2>/dev/null; then
    # 진행 중 표식이 상한+30초보다 오래됐으면(판정 프로세스 소멸) 지우고 다시 잡는다
    local m; m=$(stat -c %Y -- "$lk" 2>/dev/null) || return 1
    (( $(date +%s) - m > bt + 30 )) || return 0
    rmdir -- "$lk" 2>/dev/null; mkdir -- "$lk" 2>/dev/null || return 1
  fi
  (
    exec </dev/null >/dev/null 2>&1
    # hook 이 연 다른 fd(잠금 flock 등)를 물려받아 붙잡지 않도록 3 이상은 닫는다
    for _fd in /proc/$BASHPID/fd/*; do _fd="${_fd##*/}"; [[ "$_fd" =~ ^[0-9]+$ ]] && (( _fd > 2 )) && eval "exec ${_fd}>&-"; done 2>/dev/null
    o=$(_sr_gp_judge "$2" "$3" "$4" "$bt"); r=$?
    case "$r:$o" in
      0:2$'\t'*) _sr_cache_write "$f" HIT "F-GUARD-PROMOTE 판정 적중 — ${o#*$'\t'}" ;;
      0:0$'\t'*) _sr_cache_write "$f" PASS "" ;;
      *) _sr_log "cache_bg_fail rc=$r path=$5" ;;
    esac
    rmdir -- "$lk" 2>/dev/null
  ) &
  disown 2>/dev/null
  _sr_log "cache_bg_start path=$5"
  return 0
}
sr_body_hit() { _sr_wrap _sr_body_hit "$@"; }

# ── 실행 형태 추출: $1=텍스트 $2=cwd → stdout 경로 1줄씩 ──
_sr_resolve() {  # $1=단어 $2=cwd → stdout 절대 경로(변수·글로브·치환이면 빈 값)
  local p="$1"
  [[ -n "$p" ]] || return 1
  [[ "$p" == *'$'* || "$p" == *'`'* || "$p" == *'*'* || "$p" == *'?'* || "$p" == *'['* ]] && return 1
  [[ "$p" == "~/"* ]] && p="$HOME/${p#\~/}"
  [[ "$p" == /* ]] || p="${2%/}/$p"
  printf '%s\n' "$p"
}

# ── 구간 분할 (사이클205 D-6 — 따옴표 인식) ──
#   종전에는 따옴표를 모른 채 ; | & ` ( ) 개행에서 자른 뒤 따옴표를 지웠다. 그래서 grep -n 'a\|f() {' /x/t.sh 가
#   "{' /x/t.sh" 구간을 만들고 실행 비트 경로가 머리 자리에 와 직접 실행으로 오인됐다(재판정 창 1800초 동안 읽기 차단).
#   지금은 홑·큰따옴표 안의 구분자는 자르지 않는다. 보안 조건:
#     ① 따옴표 문자열 내용은 공백·구분자를 품었거나 바로 앞 단어가 eval·-c 계열(-c -lc …)이면 같은 분할을 재귀 적용한다
#        (bash -c '…'·sh -c "…"·eval '…'·"$(…)" 안의 실행 형태 은닉 차단). 재귀 결과는 "<" ">" 줄로 감싸 cd 범위를 가둔다.
#     ② 역슬래시 뒤 따옴표(\" \')가 어디든 있으면 종전 분할로 폴백한다 — oio bash_exec 의 && 분할기는 역슬래시를 무시하고
#        \" 에서 따옴표를 닫으므로(odev-1 실측, bash_exec.py _split_and_commands) 판정과 실행 분할이 어긋나지 않게 더 막는 쪽.
#        단 명령 원문에 && 가 한 번도 없으면 oio 는 나누지 않고 전체를 한 bash 에 넘기므로 bash 규칙으로 분할한다(사이클206):
#        따옴표 밖·큰따옴표 안의 \x 두 글자는 글자로 보고(구분자·따옴표 아님), 큰따옴표 값은 \" \\ \$ \` 를 풀어 재귀한다. 홑따옴표 안 \ 는 글자.
#     ③ 짝이 안 맞는 따옴표·중첩 깊이 6 초과도 종전 분할로 폴백한다.
#   출력: "S<구간>" · "<" · ">" 줄. awk 가 없거나 실패하면 bash 종전 분할(_sr_split_legacy)로 폴백한다.
_sr_split_legacy() {  # $1=텍스트 → stdout "S<구간>" 줄(종전 동작 — 따옴표 무시)
  local text="$1" seg nl=$'\n' sep=$'\x01'
  local -a segs=()
  text="${text//&&/$sep}"; text="${text//||/$sep}"
  text="${text//\$(/$sep}"
  text="${text//$nl/$sep}"
  text="${text//[;|&\`()]/$sep}"
  IFS="$sep" read -r -a segs <<<"$text"
  for seg in "${segs[@]}"; do printf 'S%s\n' "${seg//$nl/ }"; done
  return 0
}

_sr_split() {  # $1=텍스트 → stdout "S<구간>" · "<" · ">" 줄
  local out
  if out=$(printf '%s' "$1" | LC_ALL=C awk '
    function legacy(s,   n, i, parts, o) {
      gsub(/\$\(/, ";", s)
      n = split(s, parts, /[;|&`()\n]/); o = ""
      for (i = 1; i <= n; i++) o = o "S" parts[i] "\n"      # 따옴표 제거는 _sr_extract 가 한다(종전과 같음)
      return o
    }
    function dq_unescape(q,   i, n, c, o) {   # 큰따옴표 안 값 → bash 가 보는 글자(\" \\ \$ \` 만 역슬래시 제거)
      n = length(q); o = ""
      for (i = 1; i <= n; i++) {
        c = substr(q, i, 1)
        if (c == "\\" && i < n && index("\"\\$`", substr(q, i + 1, 1))) { i++; c = substr(q, i, 1) }
        o = o c
      }
      return o
    }
    function qsplit(s, d,   n, i, c, st, ps, qs, seg, q, pre, out, qt, hd) {
      if (d > 6) return legacy(s)
      if (!esc && s ~ /\\["\047]/) return legacy(s)
      n = length(s); st = 0; ps = 1; seg = ""; out = ""
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (esc && c == "\\" && st != 1) { i++; continue }   # 따옴표 밖·큰따옴표 안 \x 는 글자 — 구분자·따옴표로 보지 않는다
        if (st == 0) {
          if (c == "\047" || c == "\"") {
            seg = seg substr(s, ps, i - ps); st = (c == "\047") ? 1 : 2; qs = i + 1
          } else if (index(";|&`()\n", c)) {
            out = out "S" seg substr(s, ps, i - ps) "\n"; seg = ""; ps = i + 1
          }
        } else if ((st == 1 && c == "\047") || (st == 2 && c == "\"")) {
          q = substr(s, qs, i - qs); if (esc && st == 2) q = dq_unescape(q); qt = st; st = 0; ps = i + 1
          pre = seg; sub(/[ \t]+$/, "", pre)
          hd = seg; sub(/^[ \t]+/, "", hd); sub(/[ \t].*$/, "", hd); sub(/.*\//, "", hd)
          # 사이클206: 따옴표 내용은 ★실행되는 문맥★에서만 재귀한다 — ⓐ 바로 앞 단어가 eval·-c 계열 ⓑ 큰따옴표 안 $( · 백틱(명령 치환)
          #   ⓒ 구분자를 품었고 구간 머리가 문자열을 셸로 넘기는 래퍼(watch ssh su runuser script flock tmux screen parallel sg).
          #   그 밖(grep 패턴 "…|/경로" 등)은 bash 가 글자로 넘기므로 재귀하지 않는다(NEW-O10 과차단 해소).
          if (pre ~ /(^|[ \t])(eval|-[A-Za-z]*c[A-Za-z]*)$/ || (qt == 2 && q ~ /\$\(|`/) || \
              (q ~ /[ \t\n;|&`()]/ && hd ~ /^(watch|ssh|su|runuser|script|flock|tmux|screen|parallel|sg)$/))
            out = out "<\n" qsplit(q, d + 1) ">\n"
          gsub(/\n/, " ", q); seg = seg q
        }
      }
      if (st != 0) return legacy(s)
      return out "S" seg substr(s, ps) "\n"
    }
    { t = (NR > 1) ? t "\n" $0 : $0 }
    END { esc = (t ~ /\\["\047]/ && index(t, "&&") == 0); printf "%s", qsplit(t, 0) }' 2>/dev/null) && [[ -n "$out" || -z "${1//[[:space:]]/}" ]]; then
    printf '%s\n' "$out"
  else
    _sr_log "split_awk_fail — 종전 분할로 폴백"
    _sr_split_legacy "$1"
  fi
  return 0
}

_sr_extract() {
  local text="$1" cwd="$2" seg line w b i n p skip
  local -a words=() cstack=()
  text="${text//$'\r'/}"
  while IFS= read -r line; do
    case "$line" in
      '<') cstack+=("$cwd"); continue ;;
      '>') if (( ${#cstack[@]} > 0 )); then cwd="${cstack[-1]}"; unset 'cstack[-1]'; fi; continue ;;
      S*) seg="${line#S}" ;;
      *) continue ;;
    esac
    seg="${seg//[\"\']/}"
    words=()
    read -r -a words <<<"$seg"
    n=${#words[@]}
    (( n > 0 )) || continue
    i=0
    while (( i < n )); do
      w="${words[i]}"
      case "$w" in
        '{'|'}'|'!'|then|do|else|elif|if|while|until|time|nohup|setsid|command|exec|builtin)
          i=$((i+1)); continue ;;
        timeout)
          i=$((i+1))
          while (( i < n )) && [[ "${words[i]}" == -* ]]; do
            case "${words[i]}" in -k|-s|--kill-after|--signal) i=$((i+2)) ;; *) i=$((i+1)) ;; esac
          done
          i=$((i+1)); continue ;;                 # 시간 인자
        env)
          i=$((i+1))
          while (( i < n )) && [[ "${words[i]}" == -* || "${words[i]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
            case "${words[i]}" in -u|-C|--unset|--chdir) i=$((i+2)) ;; *) i=$((i+1)) ;; esac
          done
          continue ;;
        nice)
          i=$((i+1))
          if [[ "${words[i]:-}" == -n ]]; then i=$((i+2)); elif [[ "${words[i]:-}" =~ ^-[0-9]+$ ]]; then i=$((i+1)); fi
          continue ;;
        stdbuf|ionice)
          i=$((i+1))
          while (( i < n )) && [[ "${words[i]}" == -* ]]; do i=$((i+1)); done
          continue ;;
      esac
      if [[ "$w" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then i=$((i+1)); continue; fi
      break
    done
    (( i < n )) || continue
    w="${words[i]}"
    b="${w##*/}"
    p=""
    case "$b" in
      cd)
        p="${words[i+1]:-}"
        if [[ -n "$p" ]] && p=$(_sr_resolve "$p" "$cwd") && [[ -d "$p" ]]; then cwd="$p"; fi
        continue ;;
      bash|sh|dash|zsh|ksh|mksh)
        i=$((i+1)); skip=0
        while (( i < n )); do
          case "${words[i]}" in
            --) i=$((i+1)); break ;;
            -o|+o|-O|+O|--rcfile|--init-file) i=$((i+2)) ;;
            --*) i=$((i+1)) ;;
            -*|+*) [[ "${words[i]}" =~ ^[-+][A-Za-z]*[cns][A-Za-z]*$ ]] && skip=1; i=$((i+1)) ;;
            *) break ;;
          esac
        done
        (( skip == 0 && i < n )) || continue
        p="${words[i]}"
        if [[ "$p" == "<" ]]; then p="${words[i+1]:-}"; elif [[ "$p" == "<"* ]]; then p="${p#<}"; fi
        ;;
      source|.)
        p="${words[i+1]:-}" ;;
      *)
        [[ "$w" == */* ]] || continue
        p=$(_sr_resolve "$w" "$cwd") || continue
        [[ -f "$p" && -x "$p" ]] && printf '%s\n' "$p"
        continue ;;
    esac
    p=$(_sr_resolve "$p" "$cwd") || continue
    printf '%s\n' "$p"
  done < <(_sr_split "$text")
  return 0
}

# ── 승격 등록부 고정 파일 판정(사이클206): $1=경로 → 0 이면 등록부(lib/guard_promote.json)의 live·test 상대경로와 같고 sha256 이 등록값과 같다 ──
#   심볼릭링크·hooks 밖·등록부 판독 실패·sha 불일치는 1(종전 판정). 등록부와 고정 파일은 promote 만 바꾼다(write_guard F-GUARD-PROMOTE).
_sr_pinned() {
  local p="$1" h rp rel pin got
  [[ -n "$p" && -f "$p" && ! -L "$p" ]] || return 1
  h=$(realpath -e -- "${SR_GP_HOOKS:-${HARNESS_HOME:-$HOME/.harness}/current/hooks}" 2>/dev/null) || return 1
  rp=$(realpath -e -- "$p" 2>/dev/null) || return 1
  [[ "$rp" == "$h/"* ]] || return 1
  rel="${rp#"$h/"}"
  [[ -f "$h/lib/guard_promote.json" ]] || return 1
  pin=$(jq -r --arg r "$rel" '[.targets[]? | (select(.live == $r) | .core_sha256), (select(.test == $r) | .test_sha256)] | map(select(type == "string" and length == 64)) | .[0] // empty' \
        "$h/lib/guard_promote.json" 2>/dev/null) || return 1
  [[ -n "$pin" ]] || return 1
  got=$(sha256sum -- "$rp" 2>/dev/null) || return 1
  [[ "${got%% *}" == "$pin" ]]
}

# ── 재귀 판정: $1=텍스트 $2=cwd $3=차단 epoch $4=깊이 → _SR_HIT_PATH·_SR_HIT_WHY ──
_sr_scan() {
  local text="$1" cwd="$2" ep="$3" lv="$4" p why body
  local -a paths=()
  while IFS= read -r p; do [[ -n "$p" ]] && paths+=("$p"); done < <(_sr_extract "$text" "$cwd")
  for p in "${paths[@]}"; do
    (( _SR_SEEN < 64 )) || return 0
    _SR_SEEN=$((_SR_SEEN+1))
    _sr_window_applies "$p" "$ep" || continue
    # [사이클196 과제1] 다른 작성자(다른 sid)가 파일 도구로 쓴 뒤 그대로인 스크립트는 그 파일과 그 안의 중첩 실행을 건너뛴다
    local wr
    if wr=$(_sr_other_author "$p" "${_SR_SID:-}"); then
      _sr_log "exempt_other_author path=$p writer=$wr blocked=${_SR_SID:-}"
      continue
    fi
    # [사이클206] 승격 등록부에 고정된 live·고정 시험 파일이 등록 sha 그대로면 건너뛴다 — 그 내용은 승격기(promote)만 쓸 수 있다.
    #   실측 과차단: promote gp_self 로 10:43 교체된 lib/guard_promote.sh 의 verify·status 실행이 창 안 '작성' 으로 보여 막혔다.
    if _sr_pinned "$p"; then
      _sr_log "exempt_pinned path=$p blocked=${_SR_SID:-}"
      continue
    fi
    local rem=$(( _SR_DEADLINE - $(date +%s) ))
    if (( rem <= 0 )); then
      _SR_HIT_PATH="$p"; _SR_HIT_WHY="전체 판정 시간(SR_TOTAL_TMO) 초과 — 남은 스크립트를 판정할 수 없다"; return 0
    fi
    if [[ "$(head -c 8192 -- "$p" 2>/dev/null | tr -d '\000' | wc -c)" -lt "$(head -c 8192 -- "$p" 2>/dev/null | wc -c)" ]]; then
      _sr_log "skip_binary path=$p"; continue
    fi
    local bt="${SR_BODY_TMO:-4}"; [[ "$bt" =~ ^[0-9]+$ && "$bt" -gt 0 ]] || bt=4
    (( rem < bt )) && bt=$rem
    if why=$(SR_BODY_TMO="$bt" _sr_body_hit "$p" "$cwd"); then
      _SR_HIT_PATH="$p"; _SR_HIT_WHY="$why"; return 0
    fi
    if (( lv < 2 )); then
      body=$(head -c "$_SR_MAX" -- "$p" 2>/dev/null | tr -d '\000')
      _sr_scan "$body" "$cwd" "$ep" $((lv+1))
      [[ -n "$_SR_HIT_PATH" ]] && return 0
    fi
  done
  return 0
}

# ── sr_recheck ──
_sr_recheck() {
  local cmd="${1:-}" sid cwd="${3:-}" f line ep tag now win
  sid=$(_sr_sid "${2:-}")
  [[ -n "$cmd" && -n "$sid" ]] || return 0
  f="$(_sr_dir)/$sid"
  [[ -f "$f" ]] || return 0
  line=$(tail -n 1 -- "$f" 2>/dev/null) || { _sr_log "mark_read_fail sid=$sid"; return 0; }
  read -r ep tag <<<"$line"
  [[ "$ep" =~ ^[0-9]+$ ]] || { _sr_log "bad_mark sid=$sid line=${line:0:60}"; return 0; }
  now=$(date +%s)
  win="${SR_WINDOW_SEC:-1800}"; [[ "$win" =~ ^[0-9]+$ ]] || win=1800
  (( now - ep <= win )) || return 0
  [[ -n "$cwd" && -d "$cwd" ]] || cwd="$PWD"
  declare -F gp_gate_check >/dev/null 2>&1 || \
    _sr_log "gp_gate_check 미적재 — 보호 대상 판정 생략(F-ASKQ-PROT 만 판정) sid=$sid"
  local tt="${SR_TOTAL_TMO:-6}"; [[ "$tt" =~ ^[0-9]+$ && "$tt" -gt 0 ]] || tt=6
  _SR_SID="$sid"
  _SR_HIT_PATH=""; _SR_HIT_WHY=""; _SR_SEEN=0; _SR_DEADLINE=$(( $(date +%s) + tt ))
  _sr_scan "$cmd" "$cwd" "$ep" 0
  [[ -n "$_SR_HIT_PATH" ]] || return 0
  # [사용자 지시 2026-10-27 13:31 "F-SCRIPT-RECHECK도 이번 사이클에 풀어라"] 적중해도 실행을 막지 않는다.
  #   경고 1줄(stderr)과 로그(SR_LOG warn_hit)만 남기고 rc=0 — 정상 시험 스크립트가 30분씩 막히던 과차단 해소.
  #   1차 차단(F-GUARD-PROMOTE·F-ASKQ-PROT 등 원래 규칙)과 표식 기록(sr_mark_block)은 그대로다. 표식은 이 경고의 창 판정에만 쓴다.
  #   stdout 에는 아무것도 쓰지 않는다 — write_guard 가 이어서 내는 판정 JSON 과 섞이지 않게 한다(차단 기록 log_hook_error 도 남기지 않는다).
  local wend warn
  printf -v wend '%(%H:%M:%S)T' "$((ep + win))"
  warn="⚠️ [F-SCRIPT-RECHECK] 경고(차단 안 함 — 사용자 지시 2026-10-27 13:31): 차단(${tag:-?}) 직후 작성한 스크립트 ${_SR_HIT_PATH} 본문이 같은 판정에 걸린다(${_SR_HIT_WHY}). 재판정 창 종료 시각: ${wend}"
  warn="${warn//$'\n'/ }"
  printf '%s\n' "$warn" >&2
  _sr_log "warn_hit sid=$sid tag=${tag:-?} path=$_SR_HIT_PATH why=${_SR_HIT_WHY//$'\n'/ }"
  return 0
}
sr_recheck() { _sr_wrap _sr_recheck "$@"; }
