#!/bin/bash
# 가드 파일(코어·hook·승격기 자신·판정 모듈)을 회귀 시험 전체 통과 시에만 원자 교체하는 승격 경로 — 하네스 우회 방지·저널 원복·고정본 보관소·점검/복구 명령 포함
#
# 경계: 운영 배포 실행 차단(가드의 규칙 판정)은 그대로 유지된다. 이 스크립트는 '가드 파일 교체'만 다루며 배포 승인 채널이 아니다.
#   사람 입력(질문·대기·터미널 조작)은 쓰지 않는다. waive 는 이미 남은 트랜스크립트 기록만 읽는다(c199).
# 사용: bash <hooks>/lib/guard_promote.sh init <id>
#       bash <hooks>/lib/guard_promote.sh status <id>
#       bash <hooks>/lib/guard_promote.sh verify                      — 읽기 전용. 마지막 줄 VERIFIED n | DRIFT <id…>(rc 1)
#       bash <hooks>/lib/guard_promote.sh restore <id>|registry       — 보관소의 핀 본으로 되돌린다. RESTORED id=… changed=N
#       bash <hooks>/lib/guard_promote.sh promote <id> [--core <후보>] [--test <후보 시험>] [--waive <ID,…>]   (--core·--test 중 하나 이상)
#            --waive(c199, unblock3 에서 1회 개수 상한 해제): 사용자가 승인한 고정 시험 케이스 ID 만 D 줄 보존·이전 고정 시험 회귀 판정에서 1회 뺀다.
#              승인 = 메인 트랜스크립트의 AskUserQuestion(header '승인:GP_WAIVE', 본문 고정 문구 + '대상=<id>:<ID,…>' 정확히 1회,
#              답 '승인 (60분 1회)', 사용자 결정, 60분 이내, 미소비). 트랜스크립트 루트는 이 프로세스의 환경변수가 아니라
#              조상 claude 프로세스(/proc/<pid>/exe = <홈>/.local/share/claude/versions/*) 중 최상위의 environ 에서 읽는다.
#              소비 기록 logs/guard_promote.waive_consumed. 잔존 한계: 같은 uid 가 claude 실행 파일을 가짜 설정 디렉터리로
#              새로 띄워 그 안에서 승격기를 부르는 일관 위조는 막지 못한다(F-GUARD-PROMOTE 한계와 같은 등급).
#       bash <hooks>/lib/guard_promote.sh register <id> --live <상대경로> --test <상대경로> --min-pass N [--lang python|bash|sh]
#            — 추가 전용(사이클182). 새 id 만 넣는다. 기존 id 덮어쓰기·삭제·기준 하향 수단은 없다. REGISTERED id=… (rc 0)
# 출력 마지막 줄: PROMOTED id=… old=… new=… pass=N (rc 0) | REFUSE <코드> <사유> (rc 1, 원복 실패·저널 손상은 rc 3)
# 경로 기준: 이 스크립트 위치(<hooks>/lib) 고정. 보관소 고정본(<hooks>/backup/guard_promote/store/<sha256>)으로 실행되면
#   hooks 를 보관소 디렉터리의 3단계 위로 잡는다(승격기 변조 시 탈출구 — restore|verify|status 만 허용).
#   환경변수·인자로 등록부·대상 경로를 바꾸는 수단은 두지 않는다.
#   대상 추가는 register 하나뿐이다(추가 전용 — 신뢰 루트를 약하게 하지 않는 조건):
#     · 등록부에 없는 id 만(덮어쓰기·수정·삭제 불가). 기존 항목의 min_pass 는 promote 의 상향(max)으로만 바뀐다.
#     · live·test 는 hooks 트리 안의 일반 파일만 — 절대경로·..·숨김 구간·심볼릭 링크(파일·중간 디렉터리)·하드 링크
#       (링크 수 ≠ 1)·이미 등록된 파일(경로 대소문자 무시·장치:inode 대조)·등록부·승격 경로 구성요소
#       (lib/guard_promote*·lib/gp_gate*·tests/test_gp_*·tests/test_pdg_*)·backup/·logs/·candidates/ 는 거부.
#     · lang 은 python|bash|sh 만(promoter·gp_gate 는 등록 불가). gp_self 가 등록된(부트 후) 등록부에서만 동작.
#     · 등록 전에 현재 live 로 시험을 돌려 rc 0 · FAIL 0 · SKIP 0 · PASS ≥ min_pass 여야 한다. min_pass 는 max(지정, 실측).
#     · 등록부 갱신은 promote 와 같은 절차(잠금 → 보관소 → 저널 → 원자 rename → regsha·지문 → 저널 삭제)다.
#   등록은 미보호 파일을 핀하는 방향(보호 추가)뿐이다. 이후 교체는 promote(카나리 포함)로만 된다 — 시험이 D/A 규약이
#   아니면 promote 가 canary_harness 로 거부하므로 그 대상은 restore 로만 되돌릴 수 있다(fail-closed).
# 등록부: <hooks>/lib/guard_promote.json — targets.<id> = {live, test, test_sha256, core_sha256, min_pass, max_skip, lang}
#   lang: python | bash | sh | promoter(승격기 자신) | gp_gate(source 되는 판정 모듈)
# 보조 파일(이 스크립트만 쓴다):
#   보관소 backup/guard_promote/store/<sha256>   — 내용 주소. promote 성공 경로·init·부트에서만 넣는다.
#   저널   logs/guard_promote.journal            — {"op","id","ts","reg_old","reg_new","files":[{"rel","old"(빈값=신규),"new"}]}
#   지문   logs/guard_promote.fp                 — 줄마다 "<hooks 기준 상대경로>\t<mtime %.9Y>\t<크기>\t<inode>"
#                                                 (핀과 내용이 다르거나 심볼릭 링크면 "0\t0\t0" — 항상 불일치)
#   등록부 sha logs/guard_promote.regsha        — 커밋된 등록부의 sha256 1줄
#   잠금   logs/guard_promote.lock               — 보유 중 10초마다 mtime 을 갱신한다(장기 잠금 판별용)
# promote 절차(하나라도 실패하면 REFUSE, 실파일 무손상):
#   잠금 → 저널 복구 → 등록부 판독·등록부/시험 핀 대조(코어 live≠핀은 거부 없이 WARN live_drift 1줄 — 2026-10-27 사용자 해제) → 후보 사본화 → 정적 검사 → (시험 변경 시) D 줄 보존
#   → (시험 단독 변경 시) 정적 탐침 금지 → 본 시험 → 카나리(후보 코어 변이체를 실위치와 같은 상대경로에 두고 허용·거부,
#     대상 ID = 정적 호출 중 본 시험에서 실행됐거나 이전 고정 시험에 있는 것 — 주석·heredoc 예시 제외, 사이클182)
#   → (코어+시험 동시 변경 시) 후보 코어로 이전 고정 시험 회귀 → 보관소 → 저널 → 설치 → 사후 확인
#   → 등록부 rename(커밋점) → regsha·지문 갱신(잠금 해제 전) → 저널 삭제 → 로그·diff
#   커밋점 전 실패는 보관소 old 본으로 원복하고 sha 를 재확인한다(REFUSE <코드>_rolled_back).
# 시험 실행은 setsid 로 분리한다(시험이 조상 argv 를 보고 SKIP 하는 케이스가 있어 조상 사슬을 끊는다).
set -u

SELF=$(readlink -f "$0")
FROM_STORE=0
_gp_b=${SELF##*/}; _gp_d=$(dirname "$SELF")
if [[ "$_gp_b" =~ ^[0-9a-f]{64}$ ]] && [[ "$_gp_d" == */backup/guard_promote/store ]]; then
  FROM_STORE=1; HOOK_DIR=$(dirname "$(dirname "$(dirname "$_gp_d")")")
else
  HOOK_DIR=$(dirname "$(dirname "$SELF")")
fi
REG_REL="lib/guard_promote.json"
REG="$HOOK_DIR/$REG_REL"
LOGD="$HOOK_DIR/logs"
BKD="$HOOK_DIR/backup/guard_promote"
STORE="$BKD/store"
JOURNAL="$LOGD/guard_promote.journal"
FP="$LOGD/guard_promote.fp"
REGSHA="$LOGD/guard_promote.regsha"
LOCK="$LOGD/guard_promote.lock"
TEST_TIMEOUT=300
WORK=""
WV=""
WV_PFAIL=""
LOCKED=0
WHO="${PIPELINE_UUID:-main}"

cleanup() { [ -n "$WORK" ] && [ -d "$WORK" ] && rm -rf "$WORK"; WORK=""; }
trap cleanup EXIT
refuse() { echo "REFUSE $1 ${2:-}"; cleanup; exit 1; }
refuse3() { echo "REFUSE $1 ${2:-}"; cleanup; exit 3; }
sha() { sha256sum "$1" 2>/dev/null | cut -c1-64; }
rnd() { head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
now() { date '+%Y-%m-%dT%H:%M:%S'; }
fstat() { stat -c '%.9Y	%s	%i' "$1" 2>/dev/null; }
reg() { jq -r --arg i "$1" --arg k "$2" '.targets[$i][$k] // empty' "$REG" 2>/dev/null; }
relok() { case "$1" in ''|*..*|/*|*'|'*) return 1;; esac; return 0; }
regsha_pin() { [ -s "$REGSHA" ] && head -1 "$REGSHA" | grep -oE '^[0-9a-f]{64}'; }
has_gp_self() { jq -e '.targets.gp_self | type == "object"' "$REG" >/dev/null 2>&1; }
log_line() { mkdir -p "$LOGD" 2>/dev/null; printf '%s\n' "$*" >> "$LOGD/guard_promote.log"; }

need_target() {
  [ -f "$REG" ] || refuse no_registry "$REG"
  jq -e --arg i "$1" '.targets[$i] | type == "object"' "$REG" >/dev/null 2>&1 || refuse unknown_target "$1"
  LIVE_REL=$(reg "$1" live); TEST_REL=$(reg "$1" test); LANG_=$(reg "$1" lang)
  PIN_TEST=$(reg "$1" test_sha256); PIN_CORE=$(reg "$1" core_sha256)
  MIN_PASS=$(reg "$1" min_pass); MAX_SKIP=$(reg "$1" max_skip)
  [ -n "$LIVE_REL" ] && [ -n "$TEST_REL" ] || refuse bad_registry "$1 live/test 없음"
  relok "$LIVE_REL" && relok "$TEST_REL" || refuse bad_registry "$1 상대경로만 허용"
  LIVE="$HOOK_DIR/$LIVE_REL"; TEST="$HOOK_DIR/$TEST_REL"
  [ -f "$LIVE" ] || refuse no_live "$LIVE_REL"
  [ -f "$TEST" ] || refuse no_test "$TEST_REL"
  case "${MIN_PASS:-x}" in ''|*[!0-9]*) MIN_PASS=0;; esac
  case "${MAX_SKIP:-x}" in ''|*[!0-9]*) MAX_SKIP=0;; esac
}

# ── 보관소·설치·지문 ──
store_put() {  # $1=파일 → store/<sha> (같은 디렉터리 임시 → rename, sha 재확인) — stdout 에 sha
  local s t; s=$(sha "$1"); [ -n "$s" ] || return 1
  mkdir -p "$STORE" 2>/dev/null || return 1
  if [ -f "$STORE/$s" ] && [ ! -L "$STORE/$s" ] && [ "$(sha "$STORE/$s")" = "$s" ]; then echo "$s"; return 0; fi
  t="$STORE/.tmp.$$.$(rnd)"
  if cp "$1" "$t" 2>/dev/null && [ "$(sha "$t")" = "$s" ] && mv -f "$t" "$STORE/$s" 2>/dev/null; then echo "$s"; return 0; fi
  rm -f "$t"; return 1
}

install_file() {  # $1=원본 $2=실파일 [$3=기대 sha] — 같은 디렉터리 임시 이름 → rename → sha 재확인
  local tmp; tmp="$(dirname "$2")/.gp_tmp.$$.$(rnd)"
  cp "$1" "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  [ -e "$2" ] && chmod --reference="$2" "$tmp" 2>/dev/null
  mv -f "$tmp" "$2" 2>/dev/null || { rm -f "$tmp"; return 1; }
  [ -z "${3:-}" ] || { [ ! -L "$2" ] && [ "$(sha "$2")" = "$3" ]; }
}

pinned_list() {  # $1=등록부 → "id\tcore|test\t상대경로\tsha" (핀 있는 항목만)
  jq -r '.targets | to_entries[] | .key as $i | .value as $v
    | ( if (($v.core_sha256 // "") != "") then [$i, "core", ($v.live // ""), $v.core_sha256] else empty end ),
      ( if (($v.test_sha256 // "") != "") then [$i, "test", ($v.test // ""), $v.test_sha256] else empty end )
    | @tsv' "$1" 2>/dev/null
}

file_ok() {  # $1=실파일 $2=핀 sha → 핀과 같고 심볼릭 링크가 아니면 0
  [ -f "$1" ] && [ ! -L "$1" ] && [ "$(sha "$1")" = "$2" ]
}

regsha_set() {  # 현재 등록부 sha 를 regsha 로 기록(임시 → rename)
  local tmp="$REGSHA.tmp.$$" s; s=$(sha "$REG"); [ -n "$s" ] || return 1
  mkdir -p "$LOGD" 2>/dev/null
  printf '%s\n' "$s" > "$tmp" 2>/dev/null && mv -f "$tmp" "$REGSHA" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

fp_refresh() {  # 고정 파일·등록부의 stat 지문(임시 → rename). 핀과 다른 파일·심볼릭 링크는 0 지문으로 남겨 항상 불일치시킨다
  local tmp="$FP.tmp.$$" id k rel pin st rs
  mkdir -p "$LOGD" 2>/dev/null || return 1
  rs=$(regsha_pin)
  {
    while IFS=$'\t' read -r id k rel pin; do
      relok "$rel" || continue
      if file_ok "$HOOK_DIR/$rel" "$pin"; then st=$(fstat "$HOOK_DIR/$rel"); else st=$'0\t0\t0'; fi
      printf '%s\t%s\n' "$rel" "$st"
    done < <(pinned_list "$REG")
    if [ -n "$rs" ] && file_ok "$REG" "$rs"; then printf '%s\t%s\n' "$REG_REL" "$(fstat "$REG")"
    else printf '%s\t0\t0\t0\n' "$REG_REL"; fi
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$FP" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# ── 잠금·저널 ──
take_lock() {
  mkdir -p "$LOGD" 2>/dev/null || refuse lock_failed "$LOGD"
  # c206: 잘라내지 않고 연다(>>) — 잠금을 기다리는 쪽이 > 로 열면 보유 승격기가 적어 둔 pid 가 지워지고, write_guard S1 의
  #   저널 관용 조건(보유 pid 생존)이 깨져 승격 중 전 세션이 journal_stale 로 막혔다(사이클206 S7 실측). 획득한 뒤에만 비우고 적는다
  exec 9>>"$LOCK" || refuse lock_failed "$LOCK"
  flock -w 30 9 || refuse lock_timeout "30초"
  : > "$LOCK" 2>/dev/null
  printf '%s %s\n' "$$" "$(date +%s)" >&9
  LOCKED=1
  recover_journal
}
beat() { [ "$LOCKED" = 1 ] && touch "$LOCK" 2>/dev/null; return 0; }

journal_write() {  # $1=JSON — 임시 → rename
  local tmp="$JOURNAL.tmp.$$"
  printf '%s\n' "$1" > "$tmp" 2>/dev/null && mv -f "$tmp" "$JOURNAL" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

rollback_journal() {  # 저널의 old 상태로 되돌린다(old 빈값 = 신규 설치 파일 → 삭제). 전부 성공하면 0
  local rel old new rc=0 ro
  jq -e '(.files | type) == "array"' "$JOURNAL" >/dev/null 2>&1 || return 1
  while IFS='|' read -r rel old new; do
    relok "$rel" || { rc=1; continue; }
    if [ -z "$old" ]; then
      rm -f "$HOOK_DIR/$rel" 2>/dev/null; [ ! -e "$HOOK_DIR/$rel" ] && [ ! -L "$HOOK_DIR/$rel" ] || rc=1
    elif ! file_ok "$HOOK_DIR/$rel" "$old"; then
      if [ -f "$STORE/$old" ] && [ "$(sha "$STORE/$old")" = "$old" ]; then
        install_file "$STORE/$old" "$HOOK_DIR/$rel" "$old" || rc=1
      else rc=1; fi
    fi
  done < <(jq -r '.files[] | [(.rel // ""), (.old // ""), (.new // "")] | join("|")' "$JOURNAL" 2>/dev/null)
  ro=$(jq -r '.reg_old // empty' "$JOURNAL" 2>/dev/null)
  if [ -n "$ro" ] && ! file_ok "$REG" "$ro"; then
    if [ -f "$STORE/$ro" ] && [ "$(sha "$STORE/$ro")" = "$ro" ]; then install_file "$STORE/$ro" "$REG" "$ro" || rc=1
    else rc=1; fi
  fi
  return $rc
}

forward_journal() {  # 커밋점 통과 상태 확정 — 파일이 new 와 다르면 보관소 new 본으로 맞춘다
  local rel old new rc=0
  while IFS='|' read -r rel old new; do
    relok "$rel" && [ -n "$new" ] || { rc=1; continue; }
    if ! file_ok "$HOOK_DIR/$rel" "$new"; then
      if [ -f "$STORE/$new" ] && [ "$(sha "$STORE/$new")" = "$new" ]; then
        install_file "$STORE/$new" "$HOOK_DIR/$rel" "$new" || rc=1
      else rc=1; fi
    fi
  done < <(jq -r '.files[] | [(.rel // ""), (.old // ""), (.new // "")] | join("|")' "$JOURNAL" 2>/dev/null)
  return $rc
}

recover_journal() {  # R4 — 잠금 직후 저널이 남아 있으면 등록부 sha 로 방향을 정해 복구한다
  [ -f "$JOURNAL" ] || return 0
  local rn jid
  jq -e '(.files | type) == "array"' "$JOURNAL" >/dev/null 2>&1 || refuse3 journal_corrupt "$JOURNAL"
  local jph
  rn=$(jq -r '.reg_new // empty' "$JOURNAL" 2>/dev/null); jid=$(jq -r '.id // "?"' "$JOURNAL" 2>/dev/null)
  jph=$(jq -r '.phase // empty' "$JOURNAL" 2>/dev/null)   # c206: phase 있음 → committed 만 전진(등록부 선설치 후 사후 확인 전 종료는 원복)
  if [ -n "$rn" ] && file_ok "$REG" "$rn" && { [ -z "$jph" ] || [ "$jph" = committed ]; }; then
    forward_journal || refuse3 rollback_failed "recover_forward $jid — 보관소 new 본 없음"
    regsha_set && fp_refresh || refuse3 fp_write_failed "recover_forward $jid"
    rm -f "$JOURNAL"
    log_line "$(now) RECOVER_FORWARD $jid reg=$rn who=$WHO"
    echo "RECOVER_FORWARD id=$jid"
  else
    rollback_journal || refuse3 rollback_failed "recover_back $jid — 저널 유지"
    regsha_set && fp_refresh || refuse3 fp_write_failed "recover_back $jid"
    rm -f "$JOURNAL"
    log_line "$(now) RECOVER_BACK $jid who=$WHO"
    echo "RECOVER_BACK id=$jid"
  fi
}

reg_consistent() {  # regsha 가 있으면 등록부가 그것과 같아야 한다
  local rs; rs=$(regsha_pin)
  [ -z "$rs" ] && return 0
  file_ok "$REG" "$rs"
}

# ── 시험 실행 ──
run_test() {  # $1=시험 $2=코어 $3=출력파일 → rc. 분리 세션에서 돈다(조상 사슬 단절). 대기 중 잠금 mtime 갱신
  local t="$1" c="$2" o="$3" n=0 lim=$(( (TEST_TIMEOUT + 20) * 5 ))
  rm -f "$o" "$o.rc"
  # c206: 9>&- — 분리 시험(과 그 시험이 띄운 백그라운드 자식)이 승격기 잠금 fd 를 물려받지 않게 닫는다.
  #   물려받으면 시험이 남긴 고아 프로세스(sleep 등)가 끝날 때까지 다음 promote·restore 가 lock_timeout 으로 막힌다(사이클206 실측)
  ( setsid bash -c 'timeout "$4" bash "$1" "$2" > "$3" 2>&1; echo $? > "$3.rc.tmp"; mv -f "$3.rc.tmp" "$3.rc"' \
      _ "$t" "$c" "$o" "$TEST_TIMEOUT" </dev/null >/dev/null 2>&1 9>&- & )
  while [ ! -f "$o.rc" ]; do
    sleep 0.2; n=$((n + 1))
    [ $((n % 50)) -eq 0 ] && beat
    [ $n -gt $lim ] && return 124
  done
  return "$(cat "$o.rc")"
}

summary() {  # $1=출력파일 → "p f s" (합계 줄 없으면 빈 문자열)
  grep '^== 합계' "$1" 2>/dev/null | tail -1 | sed -n 's/.*PASS=\([0-9]*\) FAIL=\([0-9]*\) SKIP=\([0-9]*\).*/\1 \2 \3/p'
}

ids_of() {  # $1=D|A $2=시험 파일 → 케이스 ID(라벨 첫 단어) 목록 — 명령 시작(줄 머리·; 뒤, 환경 대입 접두 허용)의 호출만, # 주석 줄 제외
  grep -vP '^\s*#' "$2" 2>/dev/null \
    | grep -oP "(^|;)\\s*([A-Za-z_][A-Za-z0-9_]*=(\"[^\"]*\"|'[^']*'|[^\\s;\"']*)\\s+)*$1 \"\\K[^ \"]+" | grep -v '\$' | sort -u
}

exec_ids() {  # $1=D|A $2=시험 출력 → 실제로 실행된 케이스 ID(PASS·FAIL 줄)
  local k; [ "$1" = D ] && k=차단 || k=통과
  sed -n "s/^PASS $k: \\([^ ]*\\).*/\\1/p; s/^FAIL $k 기대: \\([^ ]*\\).*/\\1/p" "$2" 2>/dev/null | sort -u
}

ids_kept() {  # $1=D|A $2=후보 시험 $3=본 시험 출력 $4=이전 고정 시험 → 카나리 대상 ID
  # 정적 ID 중 본 시험에서 실행됐거나 이전 고정 시험에도 있는 것만 — heredoc·문자열 속 예시(실행 안 됨·신규)는 빠진다.
  # 이전 고정 시험의 ID 는 실행 여부와 무관하게 남긴다 → 기존 케이스를 heredoc·조건문으로 숨기면 카나리가 잡는다.
  comm -12 <(ids_of "$1" "$2") <( { exec_ids "$1" "$3"; ids_of "$1" "$4"; } | sort -u)
}

fail_ids() {  # $1=차단|통과 $2=출력 → "FAIL <종류> 기대: <ID>" 의 ID 목록
  sed -n "s/^FAIL $1 기대: \\([^ ]*\\).*/\\1/p" "$2" 2>/dev/null | sort -u
}

gp_canary_judge() {  # $1=차단|통과 $2=rc $3=출력파일 $4=대상 ID 목록(줄 단위) $5=변이체명 → 0 정상 | 1 거부(사유는 GP_CJ_CODE·GP_CJ_WHY)
  # c206 D-13: 합계 줄이 없거나 rc 가 124·137(시간 초과·강제 종료)이면 출력이 잘린 것이다. 잘린 출력으로 miss 를 대조하면
  #   "실패하지 않은 D" 라는 엉뚱한 사유가 나오므로 잘림 사유로 먼저 거부한다(거부 자체는 종전과 같다). 호출부가 refuse 한다
  local miss n hs=없음
  GP_CJ_CODE=""; GP_CJ_WHY=""
  grep -q '^== 합계' "$3" 2>/dev/null && hs=있음
  if [ "$hs" = 없음 ] || [ "$2" = 124 ] || [ "$2" = 137 ]; then
    n=$(grep -cE '^(PASS|FAIL) ' "$3" 2>/dev/null); n=${n:-0}
    GP_CJ_CODE=canary_timeout
    GP_CJ_WHY="$5 카나리 시험이 시간 초과·결과 잘림으로 끝나 판정할 수 없다(rc=$2, 합계 줄 $hs, 실행된 케이스 ${n}건)"
    return 1
  fi
  miss=$(comm -23 <(printf '%s\n' "$4") <(fail_ids "$1" "$3") | head -3 | tr '\n' ' ')
  if [ -n "$miss" ]; then
    GP_CJ_CODE=canary_harness
    if [ "$1" = 차단 ]; then GP_CJ_WHY="$5 변이체에도 실패하지 않은 D: $miss"
    else GP_CJ_WHY="$5 변이체에도 실패하지 않은 A: $miss"; fi
    return 1
  fi
  return 0
}

static_check() {  # $1=파일 $2=lang
  case "$2" in
    python) python3 -m py_compile "$1" >/dev/null 2>&1 ;;
    bash|sh|promoter|gp_gate) bash -n "$1" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

mk_tree() {  # $1=코어 $2=시험 → 새 임시 hooks 트리(실위치와 같은 상대경로, 디렉터리 이름은 난수 — 실행 간 경로로 구분 불가)
  local d; d=$(mktemp -d "$WORK/XXXXXXXX") || return 1; d="$d/hooks"
  mkdir -p "$d/lib" "$d/tests" || return 1
  cp -r "$HOOK_DIR/lib/." "$d/lib/" 2>/dev/null
  mkdir -p "$(dirname "$d/$LIVE_REL")" "$(dirname "$d/$TEST_REL")" || return 1
  cp "$1" "$d/$LIVE_REL" && cp "$2" "$d/$TEST_REL" || return 1
  echo "$d"
}

insert_line() {  # $1=원본 $2=넣을 줄 $3=출력 — 첫 줄이 #! 이면 그 다음, 아니면 맨 앞
  if head -1 "$1" | grep -q '^#!'; then { head -1 "$1"; printf '%s\n' "$2"; tail -n +2 "$1"; } > "$3"
  else { printf '%s\n' "$2"; cat "$1"; } > "$3"; fi
}

make_mutant() {  # $1=후보 코어 $2=lang $3=allow|deny $4=출력 — 후보 코어 변이체(실행마다 다른 난수 표식)
  local r deny ins; r=$(rnd)
  deny='{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "canary '"$r"'"}}'
  case "$2" in
    python)
      if grep -q '^from __future__' "$1"; then  # __future__ 는 첫 문장이어야 하므로 전체 스텁으로 폴백
        if [ "$3" = allow ]; then printf 'import sys\nsys.stdin.read()\n# _gpm %s\n' "$r" > "$4"
        else printf 'import sys\nsys.stdin.read()\nsys.stdout.write(%s)\n# _gpm %s\n' "'$deny'" "$r" > "$4"; fi
        return 0
      fi
      if [ "$3" = allow ]; then ins="import sys as _gpm_s; _gpm_s.stdin.read(); _gpm_s.exit(0)  # _gpm $r"
      else ins="import sys as _gpm_s; _gpm_s.stdin.read(); _gpm_s.stdout.write('$deny'); _gpm_s.exit(0)  # _gpm $r"; fi
      insert_line "$1" "$ins" "$4" ;;
    bash|sh)
      if [ "$3" = allow ]; then ins="cat >/dev/null; exit 0 # _gpm $r"
      else ins="cat >/dev/null; printf '%s' '$deny'; exit 0 # _gpm $r"; fi
      insert_line "$1" "$ins" "$4" ;;
    promoter)  # 허용 = 검사 없이 설치하고 성공 줄 출력, 거부 = 항상 REFUSE stub
      if [ "$3" = allow ]; then
        ins='if :; then  # _gpm '"$r"'
_gpm_h=$(dirname "$(dirname "$(readlink -f "$0")")"); _gpm_r="$_gpm_h/lib/guard_promote.json"; _gpm_i="${2:-}"
case "${1:-}" in
  promote) _gpm_c=""; _gpm_t=""; shift 2 2>/dev/null
    while [ $# -gt 0 ]; do case "$1" in --core) _gpm_c="${2:-}"; shift 2 ;; --test) _gpm_t="${2:-}"; shift 2 ;; *) shift ;; esac; done
    _gpm_l=$(jq -r --arg i "$_gpm_i" ".targets[\$i].live // empty" "$_gpm_r" 2>/dev/null)
    _gpm_s=$(jq -r --arg i "$_gpm_i" ".targets[\$i].test // empty" "$_gpm_r" 2>/dev/null)
    [ -n "$_gpm_c" ] && [ -n "$_gpm_l" ] && cp "$_gpm_c" "$_gpm_h/$_gpm_l" 2>/dev/null
    [ -n "$_gpm_t" ] && [ -n "$_gpm_s" ] && cp "$_gpm_t" "$_gpm_h/$_gpm_s" 2>/dev/null
    echo "PROMOTED id=$_gpm_i old=- new=- pass=0" ;;
  verify) echo "VERIFIED 0" ;;
  status) echo "CONSISTENT core=- test=-" ;;
  restore) echo "RESTORED id=$_gpm_i changed=0" ;;
  init) echo "PINNED id=$_gpm_i core=- test=-" ;;
  *) echo "PROMOTED id=$_gpm_i old=- new=- pass=0" ;;
esac
exit 0
fi'
      else ins="echo \"REFUSE stub _gpm$r\"; exit 1"; fi
      insert_line "$1" "$ins" "$4" ;;
    gp_gate)  # source 되는 모듈 — 끝에 gp_gate_check 재정의를 덧붙인다(모듈은 최상위에서 return/exit 하지 않는 계약)
      cp "$1" "$4" || return 1
      if [ "$3" = allow ]; then printf '\ngp_gate_check() { return 0; }  # _gpm %s\n' "$r" >> "$4"
      else printf '\ngp_gate_check() { printf '"'"'%%s\\n'"'"' '"'"'{"decision":"block","reason":"canary _gpm%s"}'"'"'; return 2; }\n' "$r" >> "$4"; fi ;;
    *) return 1 ;;
  esac
}

probe_check() {  # $1=기존 시험 $2=후보 시험 → 변경·추가 줄에 정적 탐침이 있으면 그 줄을 출력하고 1
  # 규칙(C5 — 인자 기준): 해시·크기·내용 조회 명령의 인자/입력이 코어 경로 변수인 경우만 탐침으로 본다.
  #   `OUT=$(bash "$CORE" … | tail -1)` 처럼 코어를 '실행'하고 출력만 자르는 줄은 탐침이 아니다.
  local line seg v cmds pat rin extra
  cmds='sha(1|224|256|384|512)?sum|md5sum|b2sum|cksum|cmp|wc|stat|head|tail|od|xxd|hexdump|cat|tac|dd|base64|strings|grep|egrep|fgrep|awk|sed|cut|diff|du|ls|file|less|more'
  extra=$(grep -oP '^[A-Za-z_][A-Za-z0-9_]*(?==["'"'"']?\$\{?(1|CORE|LIVE)\b)' "$2" 2>/dev/null | sort -u | tr '\n' '|')
  v="CORE|LIVE${extra:+|${extra%|}}"
  while IFS= read -r line; do
    grep -qxF -- "$line" "$1" && continue
    if printf '%s' "$line" | grep -qiP '/proc/|\bPPID\b|stub|canary|gpw_|_gpm|[0-9a-f]{32,}'; then printf '%s' "$line"; return 1; fi
    pat="$v"
    # 위치 인자 $1 은 함수 밖(행 머리에서 시작하고 함수 정의가 아닌 줄)에서만 코어 경로로 본다
    if printf '%s' "$line" | grep -qP '^[^\s#]' && ! printf '%s' "$line" | grep -qP '^\s*[A-Za-z_][A-Za-z0-9_]*\s*\(\)'; then pat="$v|1"; fi
    rin='<\s*["'"'"']?\$\{?('"$pat"')\b'
    if printf '%s' "$line" | grep -qP "$rin"; then printf '%s' "$line"; return 1; fi
    while IFS= read -r seg; do
      if printf '%s' "$seg" | grep -qP '\b('"$cmds"')\b.*\$\{?('"$pat"')\b'; then printf '%s' "$line"; return 1; fi
    done < <(printf '%s\n' "$line" | tr '|;&()`' '\n\n\n\n\n\n')
  done < "$2"
  return 0
}

# ── waive 승인 판정(c199) ──
# >>> wv_scan
wv_scan() {  # $1=사용자 홈 $2=시작 pid → 실행 파일이 $1/.local/share/claude/versions/<이름>(일반 파일·소유 uid 일치)인 ★최상위★ 조상의
  #   CLAUDE_CONFIG_DIR(environ, 없으면 $1/.claude). 못 찾으면 빈 출력. 가장 가까운 조상이 아니라 최상위를 고른다 — 에이전트는
  #   실제 claude 위에 끼어들 수 없으므로, 그 아래에 띄운 가짜 실행 파일은 선택되지 않는다. argv 는 보지 않는다.
  local p="$2" i st r e top="" uid vp="$1/.local/share/claude/versions/" v
  uid=$(id -u)
  for ((i = 0; i < 40; i++)); do
    [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -gt 1 ] || break
    e=$(readlink -f "/proc/$p/exe" 2>/dev/null)
    if [ -n "$e" ] && [[ "$e" == "$vp"* ]] && [ -n "${e#"$vp"}" ] && [[ "${e#"$vp"}" != */* ]] \
       && [ -f "$e" ] && [ ! -L "$e" ] && [ "$(stat -c %u -- "$e" 2>/dev/null)" = "$uid" ]; then top=$p; fi
    st=$(cat "/proc/$p/stat" 2>/dev/null) || break
    r=${st##*)}   # comm 에 공백·괄호가 있어도 마지막 ')' 뒤가 state ppid … (사이클197·198)
    read -r _ p _ <<< "$r"
  done
  [ -n "$top" ] || return 0
  v=$(tr '\0' '\n' < "/proc/$top/environ" 2>/dev/null | sed -n 's/^CLAUDE_CONFIG_DIR=//p' | head -1)
  printf '%s\n' "${v:-$1/.claude}"
}
# <<< wv_scan
# >>> wv_root
wv_root() { local h; h=$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6); [ -n "$h" ] || return 0; wv_scan "$h" "$$"; }
# <<< wv_root

wv_verify() {  # $1=대상 id $2=WV(쉼표) $3=트랜스크립트 루트 → 마지막 줄 "APPROVED <tool_use_id>" | "NO <코드>" (예외는 전부 NO)
  local root="$3" uuid="${PIPELINE_UUID:-}"
  [ -n "$root" ] || { echo "NO no_root"; return 0; }
  [[ "$uuid" =~ ^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$ ]] || { echo "NO bad_uuid"; return 0; }
  python3 -I - "$root" "$uuid" "$1" "$2" "$LOGD/guard_promote.waive_consumed" <<'PY' 2>/dev/null || echo "NO read_error"
import sys, os, json, glob, re, time, stat
from datetime import datetime
def out(s):
    print(s); sys.exit(0)
try:
    root, uuid, tgt, wv, consumed = sys.argv[1:6]
    WV = sorted(set(x for x in wv.split(",") if x))
    uid = os.getuid()
    files = []
    for f in glob.glob(os.path.join(glob.escape(root), "projects", "*", uuid + ".jsonl")):
        try:
            st = os.lstat(f)
        except OSError:
            continue
        if stat.S_ISREG(st.st_mode) and st.st_uid == uid:
            files.append(f)
    if not files:
        out("NO no_transcript")
    used = set()
    try:
        with open(consumed, encoding="utf-8", errors="replace") as fh:
            for l in fh:
                p = l.rstrip("\n").split("\t")
                if len(p) >= 2:
                    used.add(p[1])
    except FileNotFoundError:
        pass
    PH = "고정 시험 차단 기대를 1회 폐기합니다"
    RX = re.compile(r"대상=([a-z][a-z0-9_]{1,31}):([A-Za-z0-9_.-]+(?:,[A-Za-z0-9_.-]+)*)")
    LABEL = "승인 (60분 1회)"
    asks = {}   # tool_use id → [assistant uuid, 질문 본문 목록, 판정 코드(None=유효)]
    best = None
    last = "no_question"
    now = time.time()
    for f in files:
        with open(f, "rb") as fh:
            size = os.fstat(fh.fileno()).st_size
            lim = 64 << 20
            if size > lim:
                fh.seek(size - lim); fh.readline()
            for raw in fh:
                if b"GP_WAIVE" not in raw and b"toolUseResult" not in raw:
                    continue
                try:
                    e = json.loads(raw)
                except Exception:
                    continue
                if not isinstance(e, dict):
                    continue
                msg = e.get("message") if isinstance(e.get("message"), dict) else {}
                cont = msg.get("content") if isinstance(msg.get("content"), list) else []
                if e.get("type") == "assistant":
                    wire = e.get("wireToolInputs") if isinstance(e.get("wireToolInputs"), dict) else {}
                    for b in cont:
                        if not isinstance(b, dict) or b.get("type") != "tool_use" or b.get("name") != "AskUserQuestion":
                            continue
                        inp = b.get("input") if isinstance(b.get("input"), dict) else {}
                        qs = [q for q in (inp.get("questions") or []) if isinstance(q, dict) and q.get("header") == "승인:GP_WAIVE"]
                        if not qs:
                            continue
                        tid = b.get("id")
                        if not isinstance(tid, str) or not tid:
                            continue
                        code = None
                        w = wire.get(tid) if isinstance(wire.get(tid), dict) else {}
                        if any(k in inp for k in ("answers", "annotations")) or any(k in w for k in ("answers", "annotations")):
                            code = "forged_input"
                        elif e.get("isSidechain") is True:
                            code = "sidechain"
                        good = []
                        if code is None:
                            c2 = "target_mismatch"
                            for q in qs:
                                t = q.get("question") if isinstance(q.get("question"), str) else ""
                                m = RX.findall(t)
                                if PH not in t or len(m) != 1:
                                    continue
                                if m[0][0] != tgt:
                                    continue
                                if sorted(set(m[0][1].split(","))) != WV:
                                    c2 = "ids_mismatch"; continue
                                good.append(t)
                            if not good:
                                code = c2
                        asks[tid] = [e.get("uuid"), good, code]
                        last = code or "no_answer"
                elif e.get("type") == "user":
                    for b in cont:
                        if not isinstance(b, dict) or b.get("type") != "tool_result":
                            continue
                        tid = b.get("tool_use_id")
                        if tid not in asks:
                            continue
                        au, good, code = asks[tid]
                        if code is None and b.get("is_error") is True:
                            code = "no_answer"
                        if code is None and (not au or e.get("sourceToolAssistantUUID") != au):
                            code = "forged_input"
                        if code is None and e.get("isSidechain") is True:
                            code = "sidechain"
                        pd = e.get("permissionDecision") if isinstance(e.get("permissionDecision"), dict) else {}
                        if code is None and not (pd.get("decision") == "accept" and str(pd.get("source") or "").startswith("user")):
                            code = "not_user"
                        tr = e.get("toolUseResult") if isinstance(e.get("toolUseResult"), dict) else {}
                        ans = tr.get("answers") if isinstance(tr.get("answers"), dict) else {}
                        if code is None:
                            got = [ans.get(t) for t in good if t in ans]
                            if not got:
                                code = "no_answer"
                            elif LABEL not in got:
                                code = "wrong_label"
                        ts = None
                        if code is None:
                            try:
                                ts = datetime.fromisoformat(str(e.get("timestamp")).replace("Z", "+00:00")).timestamp()
                            except Exception:
                                code = "read_error"
                        if code is None and (now - ts > 3600 or ts - now > 60):
                            code = "expired"
                        if code is None and tid in used:
                            code = "consumed"
                        if code is None:
                            if best is None or ts >= best[0]:
                                best = (ts, tid)
                        else:
                            last = code
    if best is not None:
        out("APPROVED " + best[1])
    out("NO " + last)
except SystemExit:
    raise
except Exception:
    print("NO read_error")
PY
}

wv_has() { [ -n "$WV" ] && printf '%s\n' "$WV" | grep -qxF -- "$1"; }   # $1=ID 가 WV 에 있는가
wv_drop() { if [ -n "$WV" ]; then grep -vxF -f <(printf '%s\n' "$WV"); return 0; else cat; fi; }   # stdin 에서 WV ID 줄 제거

# ── 명령 ──
cmd_status() {
  need_target "$1"
  local c t; c=$(sha "$LIVE"); t=$(sha "$TEST")
  if [ -z "$PIN_CORE" ] || [ -z "$PIN_TEST" ]; then echo "UNPINNED id=$1 core=$c test=$t"; return 1; fi
  if [ "$c" = "$PIN_CORE" ] && [ "$t" = "$PIN_TEST" ] && [ ! -L "$LIVE" ] && [ ! -L "$TEST" ]; then echo "CONSISTENT core=$c test=$t"; return 0; fi
  echo "DRIFT id=$1 core=$c(등록 $PIN_CORE) test=$t(등록 $PIN_TEST)"; return 1
}

cmd_verify() {  # 읽기 전용 — 어떤 파일도 쓰지 않는다
  local n=0 bad="" stale="" id k rel pin f fpl rs
  [ -f "$REG" ] || { echo "DRIFT registry"; return 1; }
  [ -f "$JOURNAL" ] && echo "JOURNAL_PENDING id=$(jq -r '.id // "?"' "$JOURNAL" 2>/dev/null)"
  while IFS=$'\t' read -r id k rel pin; do
    n=$((n + 1)); f="$HOOK_DIR/$rel"
    if ! relok "$rel" || ! file_ok "$f" "$pin"; then
      case " $bad " in *" $id "*) ;; *) bad="$bad $id";; esac
    elif [ -f "$FP" ]; then
      fpl=$(awk -F'\t' -v r="$rel" '$1 == r { print $2 "\t" $3 "\t" $4; exit }' "$FP" 2>/dev/null)
      [ "$fpl" = "$(fstat "$f")" ] || stale="$stale $rel"
    fi
  done < <(pinned_list "$REG")
  rs=$(regsha_pin)
  if [ -n "$rs" ]; then
    n=$((n + 1)); file_ok "$REG" "$rs" || bad="$bad registry"
  elif has_gp_self; then
    bad="$bad registry"
  fi
  has_gp_self && [ ! -f "$FP" ] && echo "FP_MISSING — restore registry 로 재생성"
  [ -n "$stale" ] && echo "FP_STALE$stale — 내용은 핀과 같다(restore <id> 로 지문 재정렬)"
  if [ -n "$bad" ]; then echo "DRIFT$bad"; return 1; fi
  echo "VERIFIED $n"; return 0
}

cmd_restore() {  # $1=<id>|registry — 보관소의 핀 본 → 같은 디렉터리 임시 → rename → sha 재확인 → 지문 갱신
  local what="$1" rs changed=0 id k rel pin lst=""
  take_lock
  if [ "$what" = registry ]; then
    rs=$(regsha_pin); [ -n "$rs" ] || refuse no_regsha "등록부 고정 sha 없음($REGSHA)"
    if ! file_ok "$REG" "$rs"; then
      [ -f "$STORE/$rs" ] && [ "$(sha "$STORE/$rs")" = "$rs" ] || refuse no_pinned_copy "registry $rs"
      install_file "$STORE/$rs" "$REG" "$rs" || refuse restore_failed "registry"
      changed=1
    fi
    fp_refresh || refuse fp_write_failed "registry"
    log_line "$(now) RESTORE registry sha=$rs changed=$changed who=$WHO"
    echo "RESTORED id=registry changed=$changed"; return 0
  fi
  [ -f "$REG" ] || refuse no_registry "$REG"
  reg_consistent || refuse registry_drift "등록부가 regsha 와 다르다 — restore registry 먼저"
  jq -e --arg i "$what" '.targets[$i] | type == "object"' "$REG" >/dev/null 2>&1 || refuse unknown_target "$what"
  while IFS=$'\t' read -r id k rel pin; do
    [ "$id" = "$what" ] || continue
    relok "$rel" || refuse bad_registry "$what 상대경로만 허용"
    [ -f "$STORE/$pin" ] && [ "$(sha "$STORE/$pin")" = "$pin" ] || refuse no_pinned_copy "$rel $pin"
    lst="$lst$rel|$pin"$'\n'
  done < <(pinned_list "$REG")
  [ -n "$lst" ] || refuse unpinned "$what"
  while IFS='|' read -r rel pin; do
    [ -n "$rel" ] || continue
    if ! file_ok "$HOOK_DIR/$rel" "$pin"; then
      mkdir -p "$(dirname "$HOOK_DIR/$rel")" 2>/dev/null
      install_file "$STORE/$pin" "$HOOK_DIR/$rel" "$pin" || refuse restore_failed "$rel"
      changed=$((changed + 1))
    fi
  done <<< "$lst"
  fp_refresh || refuse fp_write_failed "$what"
  log_line "$(now) RESTORE $what changed=$changed who=$WHO"
  echo "RESTORED id=$what changed=$changed"
}

cmd_init() {
  local id="$1"
  take_lock
  need_target "$id"
  if [ -n "$PIN_CORE" ] || [ -n "$PIN_TEST" ]; then refuse already_pinned "$id — 재고정 금지(약화 시험 기준선화 차단)"; fi
  reg_consistent || refuse registry_drift "등록부가 regsha 와 다르다 — restore registry 먼저"
  local c t rn
  c=$(store_put "$LIVE") && t=$(store_put "$TEST") || refuse store_failed "$id"
  WORK=$(mktemp -d /tmp/gpw_XXXXXX) || refuse mktemp_failed ""
  jq --arg i "$id" --arg c "$c" --arg t "$t" '.targets[$i].core_sha256 = $c | .targets[$i].test_sha256 = $t' "$REG" > "$WORK/reg_new" 2>/dev/null \
    && [ -s "$WORK/reg_new" ] || refuse registry_write_failed "$id"
  rn=$(store_put "$WORK/reg_new") || refuse store_failed "registry"
  store_put "$REG" >/dev/null || refuse store_failed "registry(old)"
  install_file "$WORK/reg_new" "$REG" "$rn" || refuse registry_write_failed "$id"
  regsha_set && fp_refresh || echo "WARN fp_refresh_failed"
  log_line "$(now) INIT $id core=$c test=$t who=$WHO"
  echo "PINNED id=$id core=$c test=$t"
}

cmd_promote() {
  local id="$1"; shift
  local cand="" ctest="" wvraw=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --core) cand="${2:-}"; [ -n "$cand" ] || refuse bad_args "--core 값 없음"; shift 2 ;;
      --test) ctest="${2:-}"; [ -n "$ctest" ] || refuse bad_args "--test 값 없음"; shift 2 ;;
      --waive) wvraw="${2:-}"
        # unblock3: 사용자 결정(화면 답) 2026-10-27 — 1회 최대 20개 상한 해제. 화면 승인(승인:GP_WAIVE)·D 보존(5)·회귀(7)는 그대로
        [[ "$wvraw" =~ ^[A-Za-z0-9_.-]{1,40}(,[A-Za-z0-9_.-]{1,40})*$ ]] || refuse bad_args "--waive 형식(ID,ID… 쉼표 구분, ID 는 영숫자·_.- 1~40자)"
        shift 2 ;;
      *) refuse bad_args "$1" ;;
    esac
  done
  [ -n "$cand$ctest" ] || refuse bad_args "--core 또는 --test 필요"
  [ -n "$wvraw" ] && WV=$(printf '%s\n' "${wvraw//,/$'\n'}" | LC_ALL=C sort -u)
  local wvc; wvc=$(printf '%s\n' "$WV" | sed '/^$/d' | paste -sd, -)
  [ -z "$cand" ] || [ -f "$cand" ] || refuse bad_args "--core 후보 없음"
  [ -z "$ctest" ] || [ -f "$ctest" ] || refuse bad_args "--test 후보 없음"

  # 1) 잠금 + 저널 복구
  take_lock

  # 2) 등록부 · 핀 대조
  need_target "$id"
  [ -n "$PIN_TEST" ] || refuse unpinned "$id — init 먼저"
  reg_consistent || refuse registry_drift "등록부가 regsha 와 다르다 — restore registry 먼저"
  local live_test_sha; live_test_sha=$(sha "$TEST")
  [ ! -L "$TEST" ] || refuse test_tampered "$TEST_REL 심볼릭 링크"
  local live_test_drift=0
  if [ "$live_test_sha" != "$PIN_TEST" ]; then
    live_test_drift=1
    echo "WARN live_test_drift $TEST_REL live(sha=$live_test_sha) ≠ 핀 $PIN_TEST — 사전 거부 해제(사용자 2026-11-05), 이전 시험은 보관소 핀 본으로 판정"
    log_line "$(now) LIVE_TEST_DRIFT_PROCEED $id $TEST_REL sha=$live_test_sha pin=$PIN_TEST who=$WHO"
  fi
  # unblock3: 사용자 지시 2026-10-27 13:24 "승격기 사전 확인도 풀어라" — live 가 핀과 달라도(git 변경 등) 거부하지 않고
  #   경고 1줄만 남긴 뒤 진행한다. 변경 여부(core_changed)는 핀 기준으로 판정해 drift 된 live 가 시험 단독 promote 로
  #   이전 고정 시험 회귀(7) 없이 핀에 채택되지 않게 한다. 저널·원복 기준(old_sha)은 실제 live 그대로다(원복 시 drift 본 복귀).
  local base_core_sha=""
  if [ -n "$PIN_CORE" ]; then
    base_core_sha="$PIN_CORE"
    if ! file_ok "$LIVE" "$PIN_CORE"; then
      local ld_why="sha=$(sha "$LIVE")"; [ -L "$LIVE" ] && ld_why="심볼릭 링크"
      echo "WARN live_drift $LIVE_REL live($ld_why) ≠ 핀 $PIN_CORE — 사전 거부 해제(사용자 2026-10-27), 후보 검사 후 교체 진행"
      log_line "$(now) LIVE_DRIFT_PROCEED $id $LIVE_REL $ld_why pin=$PIN_CORE who=$WHO"
    fi
  fi

  # 3) 후보 사본화 — 이후 단계는 사본만 쓴다
  WORK=$(mktemp -d /tmp/gpw_XXXXXX) || refuse mktemp_failed ""
  mkdir -p "$WORK/out" || refuse mktemp_failed ""
  local PREV_TEST="$TEST"
  if [ "$live_test_drift" = 1 ]; then
    [ -f "$STORE/$PIN_TEST" ] && [ "$(sha "$STORE/$PIN_TEST")" = "$PIN_TEST" ] || refuse test_pin_missing "보관소에 핀 시험 본 없음 $PIN_TEST"
    cp "$STORE/$PIN_TEST" "$WORK/prev_test" || refuse copy_failed "prev_test"
    PREV_TEST="$WORK/prev_test"
  fi
  if [ -n "$cand" ]; then cp "$cand" "$WORK/cand_core" || refuse copy_failed "core"; else cp "$LIVE" "$WORK/cand_core" || refuse copy_failed "core"; fi
  if [ -n "$ctest" ]; then cp "$ctest" "$WORK/cand_test" || refuse copy_failed "test"; else cp "$TEST" "$WORK/cand_test" || refuse copy_failed "test"; fi
  local new_sha new_test_sha old_sha old_test_sha core_changed=0 test_changed=0
  new_sha=$(sha "$WORK/cand_core"); new_test_sha=$(sha "$WORK/cand_test"); old_sha=$(sha "$LIVE"); old_test_sha="$live_test_sha"
  [ "$new_sha" != "${base_core_sha:-$old_sha}" ] && core_changed=1
  { [ "$new_test_sha" != "$PIN_TEST" ] || [ "$new_test_sha" != "$old_test_sha" ]; } && test_changed=1
  local T0; T0=$(mk_tree "$WORK/cand_core" "$WORK/cand_test") || refuse mktemp_failed "tree"

  # 3b) waive 승인 판정(c199) — 승인이 확인된 경우에만 WV 를 5)·7) 에서 쓴다
  local wv_tid=""
  if [ -n "$WV" ]; then
    [ "$test_changed" = 1 ] || refuse waive_unused "시험 변경 없음"
    local wvo; wvo=$(wv_verify "$id" "$wvc" "$(wv_root)" | tail -1)
    case "$wvo" in
      "APPROVED "*) wv_tid=${wvo#APPROVED } ;;
      "NO "*) refuse waive_unapproved "${wvo#NO }" ;;
      *) refuse waive_unapproved read_error ;;
    esac
    [[ "$wv_tid" =~ ^[A-Za-z0-9_-]{1,100}$ ]] || refuse waive_unapproved read_error
  fi

  # 4) 정적 검사
  static_check "$T0/$LIVE_REL" "$LANG_" || refuse static_check "후보 코어($LANG_)"
  bash -n "$T0/$TEST_REL" 2>/dev/null || refuse static_check "후보 시험(bash -n)"

# 5) 시험 변경 시 구조 불변식 — 차단 기대(D) 줄은 명령을 보존해야 한다(추가·라벨 변경 허용)
  if [ "$test_changed" = 1 ]; then
    #    c199: 승인된 WV 에 첫 ID 가 든 이전 D 줄은 보존 검사·개수 기준에서 뺀다(WV 가 비면 종전과 같다)
    local nb nc line lid nw=0
    nb=$(grep -c 'D "' "$PREV_TEST"); nc=$(grep -c 'D "' "$WORK/cand_test")
    while IFS= read -r line; do
      lid=$(printf '%s' "$line" | grep -oP 'D "\K[^ "]+' | head -1)
      if [ -n "$lid" ] && wv_has "$lid"; then nw=$((nw + 1)); continue; fi
      if ! grep -qxF -- "$line" "$WORK/cand_test"; then
        local old_norm; old_norm=$(printf '%s\n' "$line" | sed -E 's/(^|[;&|[:space:]])D "([^"\\]|\\.)*"/\1D "@"/g')
        if ! grep -Fqx -- "$old_norm" <(sed -E 's/(^|[;&|[:space:]])D "([^"\\]|\\.)*"/\1D "@"/g' "$WORK/cand_test"); then
          refuse d_case_removed "$lid"
        fi
      fi
    done < <(grep -F 'D "' "$PREV_TEST")
    [ "$nc" -ge $((nb - nw)) ] || refuse d_case_removed "D 줄 수 $nc < 기준 $((nb - nw))"
    # H3(b) 시험 단독 변경: 코어 불변이므로 변경·추가 줄의 정적 탐침(해시·크기·내용 조회로 코어 식별)을 금지한다
    if [ "$core_changed" = 0 ]; then
      local probe; probe=$(probe_check "$PREV_TEST" "$WORK/cand_test") || refuse harness_probe "$(printf '%s' "$probe" | cut -c1-160)"
    fi
  fi

  # 6) 본 시험 (사본 트리) — 카나리 대상 ID 를 실행 근거로 거르기 위해 카나리보다 먼저 돈다(사이클182)
  local rc s p f k
  run_test "$T0/$TEST_REL" "$T0/$LIVE_REL" "$WORK/out/main"; rc=$?
  s=$(summary "$WORK/out/main")
  [ -n "$s" ] || refuse tests_failed "합계 줄 없음 rc=$rc $(tail -2 "$WORK/out/main" 2>/dev/null | tr '\n' ' ' | cut -c1-200)"
  read -r p f k <<< "$s"
  [ "$rc" -eq 0 ] && [ "$f" -eq 0 ] || refuse tests_failed "rc=$rc PASS=$p FAIL=$f SKIP=$k $(grep -m2 '^FAIL' "$WORK/out/main" | tr '\n' ' ' | cut -c1-240)"
  [ "$k" -le "$MAX_SKIP" ] || refuse skip_exceeded "SKIP=$k > $MAX_SKIP"
  [ "$p" -ge "$MIN_PASS" ] || refuse count_below_baseline "PASS=$p < $MIN_PASS"

  # 6b) 카나리 — 후보 코어 변이체(난수 표식)를 실위치와 같은 상대경로에 두고 허용이면 모든 D 가, 거부면 모든 A 가 실패해야 한다
  #     대상 ID = ids_kept(정적 호출 ∩ (본 시험 실행 ∪ 이전 고정 시험)) — 주석·heredoc·문자열 속 예시 ID 로 거부되지 않는다
  local dids aids TA TD
  dids=$(ids_kept D "$WORK/cand_test" "$WORK/out/main" "$PREV_TEST"); aids=$(ids_kept A "$WORK/cand_test" "$WORK/out/main" "$PREV_TEST")
  [ -n "$dids" ] || refuse canary_harness "D 케이스 0건"
  make_mutant "$WORK/cand_core" "$LANG_" allow "$WORK/mut_a" || refuse canary_harness "변이체 생성 실패($LANG_)"
  TA=$(mk_tree "$WORK/mut_a" "$WORK/cand_test") || refuse mktemp_failed "tree"
  run_test "$TA/$TEST_REL" "$TA/$LIVE_REL" "$WORK/out/canary_allow"; rc=$?
  gp_canary_judge 차단 "$rc" "$WORK/out/canary_allow" "$dids" 허용 || refuse "$GP_CJ_CODE" "$GP_CJ_WHY"
  if [ -n "$aids" ]; then
    make_mutant "$WORK/cand_core" "$LANG_" deny "$WORK/mut_d" || refuse canary_harness "변이체 생성 실패($LANG_)"
    TD=$(mk_tree "$WORK/mut_d" "$WORK/cand_test") || refuse mktemp_failed "tree"
    run_test "$TD/$TEST_REL" "$TD/$LIVE_REL" "$WORK/out/canary_deny"; rc=$?
    gp_canary_judge 통과 "$rc" "$WORK/out/canary_deny" "$aids" 거부 || refuse "$GP_CJ_CODE" "$GP_CJ_WHY"
  fi

  # 7) H3(a) 코어+시험 동시 변경 — 후보 코어로 이전 고정 시험도 통과해야 한다(A→D 전환된 ID 의 '통과 기대' 실패만 허용)
  if [ "$core_changed" = 1 ] && [ "$test_changed" = 1 ]; then
    local T1 s1 p1 f1 k1 fd fa allowed bad_a nok
    T1=$(mk_tree "$WORK/cand_core" "$PREV_TEST") || refuse mktemp_failed "tree"
    run_test "$T1/$TEST_REL" "$T1/$LIVE_REL" "$WORK/out/pinned"
    s1=$(summary "$WORK/out/pinned")
    [ -n "$s1" ] || refuse pinned_regression_unrunnable "이전 고정 시험이 후보 코어로 합계 없이 끝났다 — 시험 단독 promote 를 먼저 하라"
    read -r p1 f1 k1 <<< "$s1"
    fd=$(fail_ids 차단 "$WORK/out/pinned" | wv_drop | head -3 | tr '\n' ' ')
    [ -z "$fd" ] || refuse d_regression_pinned "이전 고정 시험의 차단 기대 실패: $fd"
    allowed=$(comm -12 <(ids_of A "$PREV_TEST") <(printf '%s\n' "$dids") | comm -23 - <(printf '%s\n' "$aids"))
    fa=$(fail_ids 통과 "$WORK/out/pinned")
    bad_a=$(comm -23 <(printf '%s\n' "$fa" | sed '/^$/d') <(printf '%s\n' "$allowed" | sed '/^$/d') | wv_drop | head -3 | tr '\n' ' ')
    [ -z "$bad_a" ] || refuse a_regression_pinned "이전 고정 시험의 통과 기대 실패(A→D 전환 아님): $bad_a"
    if [ -z "$WV" ]; then
      nok=0
      [ -n "$allowed" ] && nok=$(grep '^FAIL 통과 기대: ' "$WORK/out/pinned" | sed -n 's/^FAIL 통과 기대: \([^ ]*\).*/\1/p' | grep -cxF -f <(printf '%s\n' "$allowed"))
      [ "$f1" -le "$nok" ] || refuse pinned_regression_other "이전 고정 시험 FAIL=$f1(허용 $nok) $(grep -m1 '^FAIL' "$WORK/out/pinned" | cut -c1-160)"
    else
      # c199: FAIL 줄마다 ID 를 뽑아 (A→D 허용 ∪ WV) 밖의 것이 0건이어야 한다. 출력되지 않은 FAIL(합계 > 줄 수)도 거부
      local nfl pfi oth
      nfl=$(grep -c '^FAIL' "$WORK/out/pinned")
      [ "$f1" -le "$nfl" ] || refuse pinned_regression_other "이전 고정 시험 FAIL=$f1 > FAIL 줄 $nfl"
      pfi=$(sed -n -e 's/^FAIL [^ ]* 기대: \([^ ]*\).*/\1/p;t' -e 's/^FAIL \([^ ]*\).*/\1/p' "$WORK/out/pinned")
      oth=$(printf '%s\n' "$pfi" | sed '/^$/d' | wv_drop | { if [ -n "$allowed" ]; then grep -vxF -f <(printf '%s\n' "$allowed"); else cat; fi; } | head -3 | tr '\n' ' ')
      [ -z "$oth" ] || refuse pinned_regression_other "이전 고정 시험 FAIL(허용·waive 밖): $oth"
      WV_PFAIL=$(printf '%s\n' "$pfi" | sed '/^$/d' | sort -u)
    fi
    [ "$k1" -le "$MAX_SKIP" ] || refuse pinned_regression_other "이전 고정 시험 SKIP=$k1 > $MAX_SKIP"
  fi

  # 7b) waive 사용 확인(c199) — WV 의 각 ID 는 이전 고정 시험의 D ID 이거나 7) 의 FAIL ID 여야 한다(과잉 목록 차단)
  if [ -n "$WV" ]; then
    local wid
    while IFS= read -r wid; do
      [ -n "$wid" ] || continue
      grep -F 'D "' "$PREV_TEST" | grep -oP 'D "\K[^ "]+' | grep -qxF -- "$wid" && continue
      printf '%s\n' "${WV_PFAIL:-}" | grep -qxF -- "$wid" && continue
      refuse waive_unused "$wid"
    done <<< "$WV"
  fi

  # 8) (본 시험은 6) 으로 옮겼다)

  # 9) 백업(diff 용) · 보관소(R1) · 새 등록부
  local ts bdir mp reg_old reg_new
  ts=$(date '+%Y%m%d-%H%M%S')_$$
  bdir="$BKD/${ts}_$id"
  mkdir -p "$bdir" || refuse backup_failed "$bdir"
  cp -p "$LIVE" "$bdir/$(basename "$LIVE")" && cp -p "$TEST" "$bdir/$(basename "$TEST")" || refuse backup_failed "$bdir"
  mp=$p; [ "$MIN_PASS" -gt "$mp" ] && mp=$MIN_PASS
  jq --arg i "$id" --arg c "$new_sha" --arg t "$new_test_sha" --arg m "$mp" \
    '.targets[$i].core_sha256 = $c | .targets[$i].test_sha256 = $t | .targets[$i].min_pass = ($m | tonumber)' "$REG" > "$WORK/reg_new" 2>/dev/null \
    && [ -s "$WORK/reg_new" ] || refuse registry_write_failed "$id(새 등록부 생성 실패)"
  store_put "$LIVE" >/dev/null && store_put "$TEST" >/dev/null && store_put "$WORK/cand_core" >/dev/null \
    && store_put "$WORK/cand_test" >/dev/null || refuse store_failed "$id"
  reg_old=$(store_put "$REG") && reg_new=$(store_put "$WORK/reg_new") || refuse store_failed "registry"

  # 10) 저널(R2) → 설치
  local jfiles jtest=""
  [ "$test_changed" = 1 ] && jtest=$(jq -nc --arg r "$TEST_REL" --arg o "$old_test_sha" --arg n "$new_test_sha" '{rel:$r, old:$o, new:$n}')
  jfiles=$(jq -nc --arg r "$LIVE_REL" --arg o "$old_sha" --arg n "$new_sha" --argjson t "${jtest:-null}" \
    '[{rel:$r, old:$o, new:$n}] + (if $t == null then [] else [$t] end)')
  #     c206: phase 로 커밋 여부를 적는다 — install(등록부까지 설치했어도 사후 확인 전) → committed(사후 확인 통과).
  #     recover_journal 은 phase 가 있으면 committed 일 때만 전진, 아니면 원복한다(phase 없는 옛 저널은 종전대로 등록부 sha 로 판정)
  local jbase; jbase=$(jq -nc --arg id "$id" --arg ts "$(now)" --arg ro "$reg_old" --arg rn "$reg_new" --argjson f "$jfiles" \
    '{op:"promote", id:$id, ts:$ts, reg_old:$ro, reg_new:$rn, files:$f}')
  journal_write "$(jq -c '. + {phase:"install"}' <<< "$jbase")" || refuse journal_failed "$id"
  fail_rollback() {  # $1=코드 $2=사유 — 커밋점 전 실패: 저널 기준 원복 → sha 재확인
    if rollback_journal; then
      rm -f "$JOURNAL"; fp_refresh
      log_line "$(now) ROLLBACK $id old=$old_sha cand=$new_sha reason=$1 $2 who=$WHO"
      refuse "${1}_rolled_back" "$2"
    fi
    log_line "$(now) ROLLBACK_FAILED $id old=$old_sha cand=$new_sha reason=$1 who=$WHO"
    refuse3 rollback_failed "$1 $2 — 저널 유지(다음 잠금 시 복구)"
  }
  install_file "$WORK/cand_core" "$LIVE" "$new_sha" || fail_rollback install_failed "core"
  if [ "$test_changed" = 1 ]; then install_file "$WORK/cand_test" "$TEST" "$new_test_sha" || fail_rollback install_failed "test"; fi
  # 10b) c206: 등록부도 곧바로 설치한다 — live 와 등록부 핀이 어긋나는 창을 설치 몇 ms 로 줄인다. write_guard S5 는 저널이 있으면
  #      gp_gate 모듈 sha 를 등록부 핀과 직접 대조하므로, 종전처럼 사후 확인(11)이 끝난 뒤 등록부를 바꾸면 그동안(수 분) 모든
  #      쓰기 도구가 F-GUARD-DRIFT 로 막혔다. 커밋점은 아래 12) 저널 phase=committed 로 옮겼다 — 그 전 실패·강제 종료는 원복이다
  install_file "$WORK/reg_new" "$REG" "$reg_new" || fail_rollback registry_write_failed "$id"

  # 11) 사후 확인 — 실위치 실파일로 재시험, 실패 시 원복(등록부 포함 — rollback_journal 이 reg_old 로 되돌린다)
  local prc ps pp pf pk
  run_test "$TEST" "$LIVE" "$WORK/out/post"; prc=$?
  ps=$(summary "$WORK/out/post"); read -r pp pf pk <<< "${ps:-0 1 0}"
  if [ "$prc" -ne 0 ] || [ "$pf" -ne 0 ] || [ "$pk" -gt "$MAX_SKIP" ] || [ "$pp" -lt "$MIN_PASS" ]; then
    fail_rollback post_check "rc=$prc PASS=$pp FAIL=$pf SKIP=$pk"
  fi

  # 11b) waive 소비(c199) — 커밋점 직전에 1줄. 커밋점 이후 실패로 원복돼도 승인은 소진된 것으로 본다(재사용보다 재질문)
  if [ -n "$WV" ]; then
    printf '%s\t%s\t%s\t%s\n' "$(now)" "$wv_tid" "$id" "$wvc" >> "$LOGD/guard_promote.waive_consumed" 2>/dev/null \
      || fail_rollback waive_consume_failed "$wv_tid"
  fi

  # 12) 커밋점(R3) — 저널 phase=committed rename 하나(c206: 등록부는 10b 에서 이미 설치했다)
  journal_write "$(jq -c '. + {phase:"committed"}' <<< "$jbase")" || fail_rollback journal_failed "$id(커밋 기록)"

  # 13) regsha·지문(R5) — 잠금 해제 전에 갱신. 실패하면 저널을 남겨 다음 잠금 때 RECOVER_FORWARD 가 다시 만든다
  if regsha_set && fp_refresh; then rm -f "$JOURNAL"; else echo "WARN fp_refresh_failed — 저널 유지(다음 잠금 시 RECOVER_FORWARD)"; fi

  # 14) 로그·diff
  local wvl=""; [ -n "$WV" ] && wvl=" waive=$wvc tid=$wv_tid"
  log_line "$(now) PROMOTED $id old=$old_sha new=$new_sha test=$new_test_sha pass=$p skip=$k who=$WHO$wvl"
  { [ -n "$WV" ] && printf '# waive=%s tid=%s\n' "$wvc" "$wv_tid"; diff -u "$bdir/$(basename "$LIVE")" "$LIVE"; [ "$test_changed" = 1 ] && diff -u "$bdir/$(basename "$TEST")" "$TEST"; } \
    > "$LOGD/guard_promote_${ts}_$id.diff" 2>/dev/null
  echo "PROMOTED id=$id old=$old_sha new=$new_sha pass=$p"
}

reg_path_ok() {  # $1=hooks 기준 상대경로 → 0 이면 등록 가능한 일반 파일. 실패 사유는 _RPW
  local r="$1" a ra hd
  _RPW=""
  relok "$r" || { _RPW="상대경로만(절대경로·.. 금지)"; return 1; }
  [[ "$r" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*(/[A-Za-z0-9_][A-Za-z0-9_.-]*)*$ ]] || { _RPW="경로 형식(파일 또는 디렉터리/파일, 영숫자·_.- 구간, 숨김·. 구간 금지)"; return 1; }
  # c183 B8: hooks 최상위 hook 파일(write_guard.sh 등)도 등록한다 — 단 .sh·.py 만, 비상 스위치(DISABLE_*)·설정류는 제외
  if [[ "$r" != */* ]]; then
    case "${r,,}" in
      disable_*|*disable_*) _RPW="비상 스위치 이름"; return 1 ;;
      *.sh|*.py) ;;
      *) _RPW="최상위는 .sh·.py hook 파일만"; return 1 ;;
    esac
  fi
  case "${r,,}" in
    "${REG_REL,,}"|backup/*|logs/*|candidates/*|lib/guard_promote*|lib/gp_gate*|tests/test_gp_*|tests/test_pdg_*)
      _RPW="등록부·승격 경로 구성요소·보관소·로그·후보 경로"; return 1 ;;
  esac
  a="$HOOK_DIR/$r"
  [ -f "$a" ] && [ ! -L "$a" ] || { _RPW="일반 파일이 아니다(없음·심볼릭 링크)"; return 1; }
  hd=$(realpath -e -- "$HOOK_DIR" 2>/dev/null); ra=$(realpath -e -- "$a" 2>/dev/null)
  [ -n "$hd" ] && [ "$ra" = "$hd/$r" ] || { _RPW="트리 밖이거나 경로 중간에 링크가 있다($ra)"; return 1; }
  [ "$(stat -c %h -- "$a" 2>/dev/null)" = 1 ] || { _RPW="하드 링크(링크 수 1 아님)"; return 1; }
  return 0
}

cmd_register() {  # 추가 전용 — 새 id 를 현재 live·test 로 핀한다(시험이 min_pass 를 채울 때만)
  local id="$1"; shift
  local lv="" ts="" mp="" lg="" x di
  while [ $# -gt 0 ]; do
    case "$1" in
      --live) lv="${2:-}"; shift 2 ;;
      --test) ts="${2:-}"; shift 2 ;;
      --min-pass) mp="${2:-}"; shift 2 ;;
      --lang) lg="${2:-}"; shift 2 ;;
      *) refuse bad_args "$1 (사용: register <id> --live <경로> --test <경로> --min-pass N [--lang python|bash|sh])" ;;
    esac
  done
  [[ "$id" =~ ^[a-z][a-z0-9_]{1,31}$ ]] || refuse bad_args "id 형식(영소문자로 시작, 영소문자·숫자·_ 2~32자)"
  [ -n "$lv" ] && [ -n "$ts" ] && [ -n "$mp" ] || refuse bad_args "--live --test --min-pass 모두 필요"
  case "$mp" in *[!0-9]*) refuse bad_args "--min-pass 는 정수";; esac
  mp=$((10#$mp)); [ "$mp" -ge 1 ] || refuse bad_args "--min-pass 는 1 이상"
  if [ -z "$lg" ]; then case "$lv" in *.py) lg=python ;; *.sh) lg=bash ;; *) refuse bad_args "--lang 필요(python|bash|sh)" ;; esac; fi
  case "$lg" in python|bash|sh) ;; *) refuse bad_args "lang $lg — python|bash|sh 만(promoter·gp_gate 등록 불가)" ;; esac

  take_lock
  [ -f "$REG" ] || refuse no_registry "$REG"
  has_gp_self || refuse no_trust_root "gp_self 미등록 등록부 — 부트 후에만 등록한다"
  reg_consistent || refuse registry_drift "등록부가 regsha 와 다르다 — restore registry 먼저"
  jq -e --arg i "$id" '.targets | has($i)' "$REG" >/dev/null 2>&1 && refuse already_registered "$id — 덮어쓰기·수정 금지(추가 전용)"
  reg_path_ok "$lv" || refuse bad_path "live $lv — $_RPW"
  reg_path_ok "$ts" || refuse bad_path "test $ts — $_RPW"
  [ "${lv,,}" != "${ts,,}" ] || refuse bad_path "live 와 test 가 같다"
  # 이미 등록된 파일(경로 대소문자 무시 · 장치:inode)과 등록부 자신은 다시 등록할 수 없다 — 다른 id 로 약한 시험을 붙이는 탈취 차단
  while IFS= read -r x; do
    [ -n "$x" ] || continue
    [ "${x,,}" = "${lv,,}" ] || [ "${x,,}" = "${ts,,}" ] && refuse path_taken "$x 는 이미 등록된 파일이다"
    di=$(stat -c '%d:%i' -- "$HOOK_DIR/$x" 2>/dev/null) || continue
    [ "$di" = "$(stat -c '%d:%i' -- "$HOOK_DIR/$lv")" ] || [ "$di" = "$(stat -c '%d:%i' -- "$HOOK_DIR/$ts")" ] \
      && refuse path_taken "$lv·$ts 가 등록된 파일 $x 와 같은 파일이다"
  done < <(jq -r '.targets[] | .live, .test' "$REG" 2>/dev/null; printf '%s\n' "$REG_REL")

  LIVE_REL="$lv"; TEST_REL="$ts"; LIVE="$HOOK_DIR/$lv"; TEST="$HOOK_DIR/$ts"; LANG_="$lg"; MAX_SKIP=0
  WORK=$(mktemp -d /tmp/gpw_XXXXXX) || refuse mktemp_failed ""
  mkdir -p "$WORK/out" || refuse mktemp_failed ""
  cp "$LIVE" "$WORK/cand_core" && cp "$TEST" "$WORK/cand_test" || refuse copy_failed "$id"
  local c t T0 rc s p f k rn ro
  c=$(sha "$WORK/cand_core"); t=$(sha "$WORK/cand_test")
  T0=$(mk_tree "$WORK/cand_core" "$WORK/cand_test") || refuse mktemp_failed "tree"
  static_check "$T0/$LIVE_REL" "$LANG_" || refuse static_check "live($LANG_)"
  bash -n "$T0/$TEST_REL" 2>/dev/null || refuse static_check "test(bash -n)"
  run_test "$T0/$TEST_REL" "$T0/$LIVE_REL" "$WORK/out/main"; rc=$?
  s=$(summary "$WORK/out/main")
  [ -n "$s" ] || refuse tests_failed "합계 줄 없음 rc=$rc $(tail -2 "$WORK/out/main" 2>/dev/null | tr '\n' ' ' | cut -c1-200)"
  read -r p f k <<< "$s"
  [ "$rc" -eq 0 ] && [ "$f" -eq 0 ] || refuse tests_failed "rc=$rc PASS=$p FAIL=$f SKIP=$k $(grep -m2 '^FAIL' "$WORK/out/main" | tr '\n' ' ' | cut -c1-200)"
  [ "$k" -le 0 ] || refuse skip_exceeded "SKIP=$k > 0"
  [ "$p" -ge "$mp" ] || refuse count_below_baseline "PASS=$p < $mp"
  [ "$p" -gt "$mp" ] && mp=$p
  # 시험한 사본 = 고정본이어야 한다(시험 중 실파일이 바뀌면 거부)
  file_ok "$LIVE" "$c" && file_ok "$TEST" "$t" || refuse changed_during_test "$id"
  [ "$(store_put "$WORK/cand_core")" = "$c" ] && [ "$(store_put "$WORK/cand_test")" = "$t" ] || refuse store_failed "$id"
  jq --arg i "$id" --arg l "$lv" --arg ts "$ts" --arg c "$c" --arg t "$t" --arg m "$mp" --arg g "$lg" \
    '.targets[$i] = {live:$l, test:$ts, test_sha256:$t, core_sha256:$c, min_pass:($m|tonumber), max_skip:0, lang:$g}' \
    "$REG" > "$WORK/reg_new" 2>/dev/null && [ -s "$WORK/reg_new" ] || refuse registry_write_failed "$id"
  jq -e --arg i "$id" '.targets[$i] != null' "$WORK/reg_new" >/dev/null 2>&1 || refuse registry_write_failed "$id(검증)"
  ro=$(store_put "$REG") && rn=$(store_put "$WORK/reg_new") || refuse store_failed "registry"
  journal_write "$(jq -nc --arg id "$id" --arg ts "$(now)" --arg ro "$ro" --arg rn "$rn" \
    '{op:"register", id:$id, ts:$ts, reg_old:$ro, reg_new:$rn, files:[]}')" || refuse journal_failed "$id"
  if ! install_file "$WORK/reg_new" "$REG" "$rn"; then
    if rollback_journal; then rm -f "$JOURNAL"; fp_refresh; refuse registry_write_failed_rolled_back "$id"; fi
    refuse3 rollback_failed "register $id — 저널 유지(다음 잠금 시 복구)"
  fi
  if regsha_set && fp_refresh; then rm -f "$JOURNAL"; else echo "WARN fp_refresh_failed — 저널 유지(다음 잠금 시 RECOVER_FORWARD)"; fi
  log_line "$(now) REGISTERED $id live=$lv core=$c test=$ts test_sha=$t min_pass=$mp pass=$p lang=$lg who=$WHO"
  echo "REGISTERED id=$id core=$c test=$t min_pass=$mp pass=$p"
}

if [ "$FROM_STORE" = 1 ]; then
  case "${1:-}" in restore|verify|status) ;; *) refuse bad_args "보관소 고정본 실행은 restore|verify|status 만 허용";; esac
fi
# L-1479: worktree 사본(<루트>/.claude/worktrees/<이름>/ 아래)에서 쓰기 명령을 실행하면 그 사본의 등록부·regsha·지문만 바뀌고
#   병합 뒤 live 의 regsha·지문과 어긋난다. promote·register·init 은 거부하고 live 경로를 안내한다.
#   status·verify·restore(읽기·탈출구)는 그대로 둔다. 판정은 이 스크립트의 실제 위치(readlink -f) 기준이다.
case "$HOOK_DIR/" in
  */.claude/worktrees/*)
    case "${1:-}" in
      promote|register|init)
        refuse worktree_copy "worktree 사본($HOOK_DIR)에서는 ${1} 을 실행하지 않는다(L-1479) — live 경로에서 실행: bash ${HOOK_DIR%%/.claude/worktrees/*}/.claude/hooks/lib/guard_promote.sh ${1} …" ;;
    esac ;;
esac
case "${1:-}" in
  init)    [ -n "${2:-}" ] || refuse bad_args "id"; cmd_init "$2" ;;
  status)  [ -n "${2:-}" ] || refuse bad_args "id"; cmd_status "$2" ;;
  verify)  cmd_verify ;;
  restore) [ -n "${2:-}" ] || refuse bad_args "id|registry"; cmd_restore "$2" ;;
  promote) [ -n "${2:-}" ] || refuse bad_args "id"; id="$2"; shift 2; cmd_promote "$id" "$@" ;;
  register) [ -n "${2:-}" ] || refuse bad_args "id"; id="$2"; shift 2; cmd_register "$id" "$@" ;;
  *) refuse bad_args "사용: init|status|verify|restore|promote|register <id> …" ;;
esac
