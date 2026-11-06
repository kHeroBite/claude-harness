#!/bin/bash
# 승격기 자기 갱신 대상(gp_self·gp_gate)을 봉인 대조·시험 통과 시 단 1회 설치하는 부트 스크립트 — 등록부에 gp_self 가 생기면 스스로 비활성화된다
#
# 사용: bash ${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/guard_promote_boot.sh run      (이 형태 하나만 허용)
#   - 실행 통제: write_guard S4 부트 게이트가 명령 형태·부트 sha(_GP_BOOT_SHA)·등록부 gp_self 부재를 확인한 뒤
#     logs/guard_promote_boot.audit 에 `GATE\t<epoch>\t<nonce32hex>\t<session>\t<boot sha256>` 1줄을 남긴다.
#     이 스크립트는 60초 이내·boot sha 가 자기 sha 와 같고·미소비인 nonce 가 있을 때만 진행하고,
#     진행하면 `CONSUMED\t<epoch>\t<nonce>` 로 소비한다
#     (심볼릭 링크·글로브 별칭처럼 S4 토큰을 피한 실행은 nonce 가 없어 거부된다 — 검토 C1).
#   - 별칭 실행 거부: $0 이 심볼릭 링크이거나, 문자열이 정확히 "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/guard_promote_boot.sh" 가 아니거나,
#     그 고정 경로의 실경로와 다르면 REFUSE alias_invocation.
#   - 경로 기준: 이 스크립트 실위치(<hooks>/lib). 환경변수·인자로 대상·등록부 경로를 바꾸는 수단은 두지 않는다.
#     후보 경로도 고정이다(<hooks>/candidates/gp_self/{guard_promote.sh,test_gp_self.sh}, <hooks>/candidates/gp_gate/{gp_gate.sh,test_gp_gate.sh}).
# 실행 구조(항상 분리 실행 — 팀원 셸 90초 상한과 충돌하지 않게):
#   부모(동기): 0 → 1 → 1b → 2 → 봉인 사전 확인 → 2b nonce 소비 → `setsid -f` 로 같은 경로·같은 인자(run)의 자식을 띄운다
#     (자식 표식 GP_BOOT_CHILD=<소비된 nonce>, 잠금 fd 9 상속) → 자식이 감사 로그에 CHILD 줄로 nonce 를 인수하면
#     `STARTED pid=<n> log=<hooks>/logs/guard_promote.boot.out` 출력 후 rc 0. 그 전 실패는 동기 REFUSE(rc 1).
#   자식: nonce 1회 인수(부모 CONSUMED 60초 이내·미인수) + 상속 잠금 실보유 확인 → 3~10 단계 → 결과 1줄을
#     고정 로그 마지막 줄과 감사 로그 RESULT 줄에 남긴다. 잠금은 자식 종료(결과 기록 뒤)에 풀린다.
#   자식 결과 줄: DONE ok BOOTSTRAPPED gp_self=… gp_gate=… reg=… | REFUSE <코드> <사유> | ROLLED_BACK <코드> at=… (원복 실패 REFUSE rollback_failed, rc 3)
#   대기: timeout 85 bash -c 'until tail -1 <로그> | grep -qE "^(DONE|REFUSE|ROLLED_BACK)"; do sleep 5; done' 를 반복한다.
# 절차(하나라도 실패하면 REFUSE, 커밋점 전 실패는 원복 후 sha 재확인):
#   0 인자·별칭 검사 → 1 잠금(승격기와 같은 logs/guard_promote.lock) → 1b 부트 저널 잔존 복구(RECOVER_BACK|RECOVER_FORWARD)
#   → 2 등록부에 gp_self 가 있으면 REFUSE already_bootstrapped(자기 비활성화) → 2b nonce 소비
#   → 3 후보 4종 사본화·봉인 대조 → 4 현 승격기로 기존 대상 status CONSISTENT → 5 bash -n
#   → 6 시험: (a) test_gp_self FAIL 0·PASS ≥ 9 (b) gp_self 카나리 (c) test_gp_gate FAIL 0 + gp_gate 카나리
#            (d) test_guard_promote <후보 승격기> FAIL 0 (e) 실 hooks 사본 트리에서 후보 승격기로 기존 대상 status CONSISTENT
#   → 7 보관소(backup/guard_promote/store/<sha256>)에 후보 4종·기존 대상 현재본·구 승격기·구/신 등록부
#   → 8 저널 → 백업 → 시험 2종 → 모듈 → 승격기 설치 → 새 등록부 rename(커밋점) → 지문·regsha(잠금 해제 전) → 저널 삭제
#   → 9 새 승격기 verify VERIFIED·대상 전부 status CONSISTENT (실패 시 원복) → 10 로그 BOOTSTRAP 1줄
# 시험 실행은 setsid 로 분리한다(조상 argv 를 보는 시험의 SKIP 회피 — 승격기와 같은 방식).
set -u

# ── 봉인 상수(Batch 2 에서 candidates 4파일 sha256 을 기입한다. 빈 값이면 항상 REFUSE unsealed) ──
SEAL_GP_SELF="b294847cdda8fdd5b3d302fae1672f905979cd35b91f78a24a0868492403b96b"
SEAL_GP_SELF_TEST="680312847b135d11adec6b3760d4e35a062311d27828fff3de1ef0cbc6408209"
SEAL_GP_GATE="5a391e1f5cd0f33a58a9dd127ca4b46d480d9e7bd2ab4b33e867d479c939412d"
SEAL_GP_GATE_TEST="0159b436fccf5a0fc04a1bd7edfa6dc30bac24ae8025db53a120f7260cdcc9b8"

NONCE_TTL=60
TEST_TIMEOUT=300
MIN_PASS_GP_SELF=9
LANG_GP_SELF="promoter"
LANG_GP_GATE="gp_gate"

SELF=$(readlink -f "$0")
HOOK_DIR=$(dirname "$(dirname "$SELF")")
REG="$HOOK_DIR/lib/guard_promote.json"
LOGD="$HOOK_DIR/logs"
BKD="$HOOK_DIR/backup/guard_promote"
STORE="$BKD/store"
JOURNAL="$LOGD/guard_promote.journal"
FP="$LOGD/guard_promote.fp"
REGSHA="$LOGD/guard_promote.regsha"
AUDIT="$LOGD/guard_promote_boot.audit"
CAND="$HOOK_DIR/candidates"
PROMOTER="$HOOK_DIR/lib/guard_promote.sh"
LOCK="$LOGD/guard_promote.lock"
BOOT_OUT="$LOGD/guard_promote.boot.out"   # 분리 실행 자식의 고정 로그(마지막 줄 = 결과 1줄)
WORK=""
BOOT_NONCE=""
CHILD_MODE=0

# 설치 대상(상대경로) — 설치 순서: 시험 2종 → 모듈 → 승격기
REL_SELF_TEST="tests/test_gp_self.sh"
REL_GATE_TEST="tests/test_gp_gate.sh"
REL_GATE="lib/gp_gate.sh"
REL_SELF="lib/guard_promote.sh"

cleanup() { [ -n "$WORK" ] && [ -d "$WORK" ] && rm -rf "$WORK"; WORK=""; }
trap cleanup EXIT
emit() {  # 결과 1줄 출력 — 자식이면 감사 로그에도 같은 결과를 남긴다(잠금은 프로세스 종료 시 해제 = 기록 뒤)
  echo "$*"
  [ "$CHILD_MODE" = 1 ] && printf 'RESULT\t%s\t%s\t%s\n' "$(date +%s)" "$BOOT_NONCE" "$*" >> "$AUDIT" 2>/dev/null
  return 0
}
refuse() { emit "REFUSE $1 ${2:-}"; cleanup; exit 1; }
sha() { sha256sum "$1" 2>/dev/null | cut -c1-64; }
log_line() { mkdir -p "$LOGD" 2>/dev/null; printf '%s\n' "$*" >> "$LOGD/guard_promote.log"; }
beat() { [ "$CHILD_MODE" = 1 ] && touch "$LOCK" 2>/dev/null; return 0; }   # 잠금 heartbeat(write_guard S1 관용 조건: 15초 이내)
now_iso() { date '+%Y-%m-%dT%H:%M:%S'; }

# ── 0) 인자·별칭 검사 ──
alias_check() {
  [ "$#" -eq 1 ] && [ "$1" = run ] || refuse bad_args "사용: bash \${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/guard_promote_boot.sh run"
  [ -L "$0" ] && refuse alias_invocation "심볼릭 링크 실행($0)"
  [ "$(basename -- "$0")" = guard_promote_boot.sh ] || refuse alias_invocation "파일명 불일치($0)"
  local fixed_str="${HOME:-/nonexistent}/.claude/hooks/lib/guard_promote_boot.sh" fixed_real
  [ "$0" = "$fixed_str" ] || refuse alias_invocation "고정 경로 문자열 불일치($0)"
  fixed_real=$(readlink -f "$fixed_str" 2>/dev/null)
  [ -n "$fixed_real" ] && [ "$fixed_real" = "$SELF" ] || refuse alias_invocation "고정 실경로 불일치($SELF)"
}

# ── 2b) nonce 소비 — S4 가 남긴 마지막 GATE 줄 1개만 본다(odev-4 합의 형식, 탭 구분) ──
#   GATE\t<epoch>\t<nonce 32hex>\t<session>\t<boot sha256>  →  소비: CONSUMED\t<epoch>\t<nonce>
consume_nonce() {
  [ -f "$AUDIT" ] || refuse no_gate_nonce "감사 파일 없음 — 부트 게이트(S4)를 거친 정식 명령으로 실행하라"
  local line e n bs now age
  line=$(grep -P '^GATE\t' "$AUDIT" 2>/dev/null | tail -1)
  [ -n "$line" ] || refuse no_gate_nonce "GATE 줄 없음"
  IFS=$'\t' read -r _ e n _ bs <<< "$line"
  printf '%s\n' "$n" | grep -qxE '[0-9a-f]{32}' || refuse no_gate_nonce "nonce 형식"
  case "$e" in ''|*[!0-9]*) refuse no_gate_nonce "epoch 형식";; esac
  now=$(date +%s); age=$((now - e))
  [ "$age" -ge 0 ] && [ "$age" -le "$NONCE_TTL" ] || refuse no_gate_nonce "만료(${age}초 > ${NONCE_TTL}초)"
  [ "$bs" = "$(sha "$SELF")" ] || refuse no_gate_nonce "게이트가 확인한 부트 sha 와 자기 sha 불일치"
  grep -qP "^CONSUMED\t[0-9]+\t$n\$" "$AUDIT" 2>/dev/null && refuse no_gate_nonce "이미 소비된 nonce"
  printf 'CONSUMED\t%s\t%s\n' "$now" "$n" >> "$AUDIT" || refuse no_gate_nonce "소비 기록 실패"
  BOOT_NONCE="$n"
}

# ── 공용: 보관소·설치·지문 ──
store_put() {  # $1=파일 — 내용 주소 저장(같은 디렉터리 임시 → rename, 있으면 sha 확인만)
  local s t; beat; s=$(sha "$1"); [ -n "$s" ] || return 1
  mkdir -p "$STORE" || return 1
  if [ -f "$STORE/$s" ] && [ "$(sha "$STORE/$s")" = "$s" ]; then return 0; fi
  t="$STORE/.tmp.$$.$(date +%N)"
  cp "$1" "$t" && mv -f "$t" "$STORE/$s" || { rm -f "$t"; return 1; }
  [ "$(sha "$STORE/$s")" = "$s" ]
}

install_file() {  # $1=원본 $2=실파일 — 같은 디렉터리 임시 이름 → rename(새 inode)
  local tmp; mkdir -p "$(dirname "$2")" || return 1
  tmp="$(dirname "$2")/.gp_tmp.$$.$(date +%N)"
  cp "$1" "$tmp" || { rm -f "$tmp"; return 1; }
  if [ -e "$2" ]; then chmod --reference="$2" "$tmp" 2>/dev/null; else chmod 755 "$tmp" 2>/dev/null; fi
  mv -f "$tmp" "$2" || { rm -f "$tmp"; return 1; }
}

commit_registry() {  # $1=새 등록부 임시(같은 디렉터리) — 커밋점: 등록부 rename 하나
  mv -f "$1" "$REG" # @commit_mv
}

# 지문·regsha — 후보 승격기(candidates/gp_self/guard_promote.sh)의 regsha_set·fp_refresh 와 같은 형식이다
#   regsha: 등록부 sha256 1줄 / fp: 핀 있는 항목(등록부 순서, core 다음 test)마다 "<상대경로>\t<%.9Y>\t<크기>\t<inode>",
#   마지막 줄은 등록부 자신. 핀과 다른 파일·심볼릭 링크는 "0\t0\t0" 으로 남겨 항상 불일치시킨다.
REG_REL="lib/guard_promote.json"
fstat() { stat -c $'%.9Y\t%s\t%i' "$1" 2>/dev/null; }
relok() { case "$1" in ''|*..*|/*|*'|'*) return 1;; esac; return 0; }
file_ok() { [ -f "$1" ] && [ ! -L "$1" ] && [ "$(sha "$1")" = "$2" ]; }
regsha_pin() { [ -s "$REGSHA" ] && head -1 "$REGSHA" | grep -oE '^[0-9a-f]{64}'; }
pinned_list() {
  jq -r '.targets | to_entries[] | .key as $i | .value as $v
    | ( if (($v.core_sha256 // "") != "") then [$i, "core", ($v.live // ""), $v.core_sha256] else empty end ),
      ( if (($v.test_sha256 // "") != "") then [$i, "test", ($v.test // ""), $v.test_sha256] else empty end )
    | @tsv' "$1" 2>/dev/null
}
regsha_set() {
  local tmp="$REGSHA.tmp.$$" s; s=$(sha "$REG"); [ -n "$s" ] || return 1
  printf '%s\n' "$s" > "$tmp" 2>/dev/null && mv -f "$tmp" "$REGSHA" 2>/dev/null || { rm -f "$tmp"; return 1; }
}
fp_refresh() {
  local tmp="$FP.tmp.$$" id k rel pin st rs
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
write_fp() { regsha_set && fp_refresh; }   # regsha 먼저(fp 의 등록부 줄이 regsha 를 본다)

# ── 저널 — 후보 승격기 R2 형식 {op,id,ts,reg_old,reg_new,files:[{rel,old(빈값=신규),new}]}, op=id=bootstrap ──
journal_write() {  # $1=구 등록부 sha $2=신 등록부 sha $3=files JSON 배열
  local tmp="$JOURNAL.tmp.$$"
  jq -nc --arg o "$1" --arg n "$2" --argjson f "$3" --arg ts "$(now_iso)" \
     '{op:"boot", id:"gp_self,gp_gate", ts:$ts, reg_old:$o, reg_new:$n, files:$f}' > "$tmp" 2>/dev/null && [ -s "$tmp" ] \
     && mv -f "$tmp" "$JOURNAL" || { rm -f "$tmp"; return 1; }
}

journal_files() {  # 저널 files → "rel|old|new" 줄
  jq -r '.files[] | [(.rel // ""), (.old // ""), (.new // "")] | join("|")' "$1" 2>/dev/null
}

rollback_from_journal() {  # 저널 기준 원복 — 신규 설치 파일(old 빈값)은 삭제, 기존 파일은 보관소 구본으로. rc 0=원복·재확인 성공
  local j="$1" rel old new ok=0 oreg
  jq -e '(.files | type) == "array"' "$j" >/dev/null 2>&1 || return 1
  while IFS='|' read -r rel old new; do
    relok "$rel" || continue
    if [ -z "$old" ]; then
      rm -f "$HOOK_DIR/$rel"; [ -e "$HOOK_DIR/$rel" ] && ok=1
    else
      file_ok "$HOOK_DIR/$rel" "$old" && continue
      [ -f "$STORE/$old" ] && install_file "$STORE/$old" "$HOOK_DIR/$rel" || ok=1
      file_ok "$HOOK_DIR/$rel" "$old" || ok=1
    fi
  done < <(journal_files "$j")
  oreg=$(jq -r '.reg_old // empty' "$j" 2>/dev/null)
  if [ -n "$oreg" ] && [ "$(sha "$REG")" != "$oreg" ]; then
    [ -f "$STORE/$oreg" ] && install_file "$STORE/$oreg" "$REG" || ok=1
    [ "$(sha "$REG")" = "$oreg" ] || ok=1
  fi
  return $ok
}

forward_from_journal() {  # 커밋점 통과 상태 확정 — 파일이 new 와 다르면 보관소 new 본으로 맞춘다
  local j="$1" rel old new ok=0
  while IFS='|' read -r rel old new; do
    relok "$rel" && [ -n "$new" ] || continue
    file_ok "$HOOK_DIR/$rel" "$new" && continue
    [ -f "$STORE/$new" ] && install_file "$STORE/$new" "$HOOK_DIR/$rel" || ok=1
    file_ok "$HOOK_DIR/$rel" "$new" || ok=1
  done < <(journal_files "$j")
  return $ok
}

recover_journal() {  # 1b) 잠금 직후 — 부트 저널이 남아 있으면 등록부 sha 로 방향을 정해 정리
  [ -f "$JOURNAL" ] || return 0
  local jop nreg
  jop=$(jq -r '.op // empty' "$JOURNAL" 2>/dev/null)
  [ "$jop" = boot ] || refuse journal_pending "부트가 아닌 저널(op=$jop) — 승격기로 복구하라"
  nreg=$(jq -r '.reg_new // empty' "$JOURNAL" 2>/dev/null)
  if [ -n "$nreg" ] && [ "$(sha "$REG")" = "$nreg" ]; then
    forward_from_journal "$JOURNAL" || { echo "REFUSE rollback_failed recover_forward — 보관소 new 본 없음, 저널 유지"; exit 3; }
    write_fp || { echo "REFUSE fp_write_failed recover_forward — 저널 유지"; exit 3; }
    rm -f "$JOURNAL"
    log_line "$(now_iso) RECOVER_FORWARD bootstrap reg=$nreg who=${PIPELINE_UUID:-main}"
    echo "RECOVER_FORWARD bootstrap reg=$nreg"
  else
    rollback_from_journal "$JOURNAL" || { echo "REFUSE rollback_failed 부트 저널 원복 실패 — 상태 확인 필요"; exit 3; }
    rm -f "$JOURNAL"
    log_line "$(now_iso) RECOVER_BACK bootstrap reg=$(sha "$REG") who=${PIPELINE_UUID:-main}"
    echo "RECOVER_BACK bootstrap reg=$(sha "$REG")"
  fi
}

# ── 시험 실행 공용(승격기와 같은 규약) ──
run_test() {  # $1=시험 $2=대상 $3=출력파일 → rc. 분리 세션에서 돈다(조상 사슬 단절)
  local t="$1" c="$2" o="$3" n=0 lim=$(( (TEST_TIMEOUT + 20) * 5 ))
  rm -f "$o" "$o.rc"
  ( setsid bash -c 'timeout "$4" bash "$1" "$2" > "$3" 2>&1; echo $? > "$3.rc.tmp"; mv -f "$3.rc.tmp" "$3.rc"' \
      _ "$t" "$c" "$o" "$TEST_TIMEOUT" </dev/null >/dev/null 2>&1 & )
  while [ ! -f "$o.rc" ]; do
    sleep 0.2; n=$((n + 1))
    [ $((n % 25)) -eq 0 ] && touch "$LOGD/guard_promote.lock" 2>/dev/null   # 잠금 생존 표시(승격기 beat 와 같은 뜻)
    [ $n -gt $lim ] && return 124
  done
  return "$(cat "$o.rc")"
}
summary() { grep '^== 합계' "$1" 2>/dev/null | tail -1 | sed -n 's/.*PASS=\([0-9]*\) FAIL=\([0-9]*\) SKIP=\([0-9]*\).*/\1 \2 \3/p'; }
ids_of() { grep -oP "(^|[\\s;])$1 \"\\K[^ \"]+" "$2" 2>/dev/null | sort -u; }

must_pass() {  # $1=라벨 $2=시험 $3=대상 $4=최소 PASS → 전역 LAST_PASS
  local rc s p f k
  run_test "$2" "$3" "$WORK/out/$1"; rc=$?
  s=$(summary "$WORK/out/$1")
  [ -n "$s" ] || refuse tests_failed "$1 합계 줄 없음 rc=$rc $(tail -2 "$WORK/out/$1" 2>/dev/null | tr '\n' ' ' | cut -c1-200)"
  read -r p f k <<< "$s"
  [ "$rc" -eq 0 ] && [ "$f" -eq 0 ] || refuse tests_failed "$1 rc=$rc PASS=$p FAIL=$f SKIP=$k $(grep -m2 '^FAIL' "$WORK/out/$1" | tr '\n' ' ' | cut -c1-240)"
  [ "$k" -eq 0 ] || refuse skip_exceeded "$1 SKIP=$k > 0"
  [ "$p" -ge "$4" ] || refuse count_below_baseline "$1 PASS=$p < $4"
  LAST_PASS=$p
}

canary() {  # $1=라벨 $2=시험 $3=허용 변이체 $4=거부 변이체 — 허용이면 모든 D, 거부면 모든 A 가 실패로 보고돼야 한다
  local dids aids miss
  dids=$(ids_of D "$2"); aids=$(ids_of A "$2")
  [ -n "$dids" ] || refuse canary_harness "$1 D 케이스 0건"
  [ -n "$aids" ] || refuse canary_harness "$1 A 케이스 0건"
  run_test "$2" "$3" "$WORK/out/${1}_allow"
  miss=$(comm -23 <(printf '%s\n' "$dids") <(sed -n 's/^FAIL 차단 기대: \([^ ]*\).*/\1/p' "$WORK/out/${1}_allow" | sort -u) | head -3 | tr '\n' ' ')
  [ -z "$miss" ] || refuse canary_harness "$1 허용 변이체에도 실패하지 않은 D: $miss"
  run_test "$2" "$4" "$WORK/out/${1}_deny"
  miss=$(comm -23 <(printf '%s\n' "$aids") <(sed -n 's/^FAIL 통과 기대: \([^ ]*\).*/\1/p' "$WORK/out/${1}_deny" | sort -u) | head -3 | tr '\n' ' ')
  [ -z "$miss" ] || refuse canary_harness "$1 거부 변이체에도 실패하지 않은 A: $miss"
}

mk_promoter_variant() {  # $1=후보 $2=출력 $3=allow|deny — shebang 다음 줄에 난수 표식 조기 종료 줄 삽입(H2)
  local m l; m=$(od -An -tx1 -N8 /dev/urandom | tr -d ' \n')
  if [ "$3" = allow ]; then
    l='case "${1:-}" in promote) echo "PROMOTED id=${2:-x} old=0 new=0 pass=999 m='"$m"'";; verify) echo "VERIFIED 0 m='"$m"'";; status) echo "CONSISTENT core=0 test=0 m='"$m"'";; restore) echo "RESTORED ${2:-x} m='"$m"'";; *) echo "OK m='"$m"'";; esac; exit 0'
  else
    l='echo "REFUSE stub m='"$m"'"; exit 1'
  fi
  mkdir -p "$(dirname "$2")"
  if head -1 "$1" | grep -q '^#!'; then
    { head -1 "$1"; printf '%s\n' "$l"; tail -n +2 "$1"; } > "$2"
  else
    { printf '%s\n' "$l"; cat "$1"; } > "$2"
  fi
}

mk_gate_variant() {  # $1=후보 모듈 $2=출력 $3=allow|deny — 끝에 gp_gate_check 재정의(난수 표식)
  local m; m=$(od -An -tx1 -N8 /dev/urandom | tr -d ' \n')
  mkdir -p "$(dirname "$2")"
  cp "$1" "$2"
  if [ "$3" = allow ]; then
    printf '\ngp_gate_check(){ return 0; }  # canary %s\n' "$m" >> "$2"
  else
    printf '\ngp_gate_check(){ printf '"'"'%%s'"'"' '"'"'{"decision":"block","reason":"canary %s"}'"'"'; return 2; }\n' "$m" >> "$2"
  fi
}

# ════════════════════════════════════════════════════════════════════
registry_unbooted() {  # 2) 자기 비활성화(등록부 기준)
  [ -f "$REG" ] || refuse no_registry "$REG"
  jq -e '.targets | type == "object"' "$REG" >/dev/null 2>&1 || refuse bad_registry "targets 없음"
  if jq -e '.targets.gp_self' "$REG" >/dev/null 2>&1; then refuse already_bootstrapped "등록부에 gp_self 가 있다 — 이후 갱신은 promote gp_self"; fi
  if jq -e '.targets.gp_gate' "$REG" >/dev/null 2>&1; then refuse already_bootstrapped "등록부에 gp_gate 가 있다"; fi
}

# ── 부모(동기 구간): 잠금 → 저널 복구 → 자기 비활성화 → 봉인 사전 확인 → nonce 검증·소비 → 자식 분리 → STARTED ──
#   소비 전 실패는 nonce 를 남긴다(같은 GATE 로 재시도 가능). 소비 후에는 자식만 진행할 수 있다.
parent_main() {
  mkdir -p "$LOGD" 2>/dev/null
  exec 9>"$LOCK" || refuse lock_failed "$LOCK"
  flock -n 9 || refuse lock_busy "다른 승격·부트가 잠금을 쥐고 있다 — 끝난 뒤 다시 실행하라"
  printf '%s %s\n' "$$" "$(date +%s)" >&9
  recover_journal
  registry_unbooted
  [ -n "$SEAL_GP_SELF" ] && [ -n "$SEAL_GP_SELF_TEST" ] && [ -n "$SEAL_GP_GATE" ] && [ -n "$SEAL_GP_GATE_TEST" ] \
    || refuse unsealed "봉인 상수가 비어 있다"
  local f s
  for f in gp_self/guard_promote.sh:$SEAL_GP_SELF gp_self/test_gp_self.sh:$SEAL_GP_SELF_TEST \
           gp_gate/gp_gate.sh:$SEAL_GP_GATE gp_gate/test_gp_gate.sh:$SEAL_GP_GATE_TEST; do
    [ -f "$CAND/${f%%:*}" ] && [ ! -L "$CAND/${f%%:*}" ] || refuse no_candidate "candidates/${f%%:*}"
    s=$(sha "$CAND/${f%%:*}"); [ "$s" = "${f##*:}" ] || refuse seal_mismatch "${f%%:*} $s ≠ 봉인"
  done
  consume_nonce
  # 자식 분리 — 같은 경로·같은 인자(run)로 새 세션에서 다시 실행한다. 잠금 fd 9 는 상속된다(같은 열린 파일 = 같은 flock).
  GP_BOOT_CHILD="$BOOT_NONCE" setsid -f bash "$0" run > "$BOOT_OUT" 2>&1 < /dev/null \
    || refuse child_start_failed "setsid"
  local n=0 pid=""
  while [ $n -lt 50 ]; do
    pid=$(grep -P "^CHILD\t[0-9]+\t$BOOT_NONCE\t" "$AUDIT" 2>/dev/null | tail -1 | cut -f4)
    [ -n "$pid" ] && break
    sleep 0.2; n=$((n + 1))
  done
  [ -n "$pid" ] || refuse child_start_failed "10초 안에 자식이 nonce 를 인수하지 않았다 — $BOOT_OUT 확인"
  echo "STARTED pid=$pid log=$BOOT_OUT"
  exit 0
}

# ── 자식 진입 검사: 부모가 소비한 nonce 를 1회만 인수하고, 상속한 잠금을 실제로 쥐고 있어야 한다 ──
child_claim() {
  BOOT_NONCE="${GP_BOOT_CHILD:-}"
  printf '%s\n' "$BOOT_NONCE" | grep -qxE '[0-9a-f]{32}' || { BOOT_NONCE=""; CHILD_MODE=0; refuse child_bad_token ""; }
  local fdp lockp line e now
  fdp=$(readlink "/proc/$$/fd/9" 2>/dev/null); lockp=$(readlink -f "$LOCK" 2>/dev/null)
  [ -n "$fdp" ] && [ "$fdp" = "$lockp" ] && flock -n 9 || { CHILD_MODE=0; refuse child_no_lock "상속 잠금 없음"; }
  line=$(grep -P "^CONSUMED\t[0-9]+\t$BOOT_NONCE\$" "$AUDIT" 2>/dev/null | tail -1)
  [ -n "$line" ] || { CHILD_MODE=0; refuse child_no_nonce "소비 기록 없음"; }
  e=$(printf '%s\n' "$line" | cut -f2); now=$(date +%s)
  [ $((now - e)) -le "$NONCE_TTL" ] || { CHILD_MODE=0; refuse child_no_nonce "소비 후 ${NONCE_TTL}초 초과"; }
  grep -qP "^CHILD\t[0-9]+\t$BOOT_NONCE\t" "$AUDIT" 2>/dev/null && { CHILD_MODE=0; refuse child_no_nonce "이미 인수된 nonce"; }
  printf 'CHILD\t%s\t%s\t%s\n' "$now" "$BOOT_NONCE" "$$" >> "$AUDIT" || { CHILD_MODE=0; refuse child_no_nonce "인수 기록 실패"; }
}

cmd_run() {  # 자식 본체(3~10단계)
  CHILD_MODE=1
  child_claim
  printf '%s %s\n' "$$" "$(date +%s)" > "$LOCK" 2>/dev/null   # 잠금 주인 표시(같은 파일, flock 은 열린 파일 기준이라 유지)
  echo "CHILD pid=$$ nonce=$BOOT_NONCE start=$(now_iso)"
  registry_unbooted

  # 3) 후보 사본화·봉인 대조
  WORK=$(mktemp -d /tmp/gpb_XXXXXX) || refuse mktemp_failed ""
  mkdir -p "$WORK/cand" "$WORK/out" "$WORK/stage"
  local f
  for f in gp_self/guard_promote.sh gp_self/test_gp_self.sh gp_gate/gp_gate.sh gp_gate/test_gp_gate.sh; do
    [ -f "$CAND/$f" ] && [ ! -L "$CAND/$f" ] || refuse no_candidate "candidates/$f"
    cp "$CAND/$f" "$WORK/cand/$(basename "$f")" || refuse copy_failed "$f"
  done
  local C_SELF="$WORK/cand/guard_promote.sh" C_SELF_T="$WORK/cand/test_gp_self.sh"
  local C_GATE="$WORK/cand/gp_gate.sh" C_GATE_T="$WORK/cand/test_gp_gate.sh"
  [ -n "$SEAL_GP_SELF" ] && [ -n "$SEAL_GP_SELF_TEST" ] && [ -n "$SEAL_GP_GATE" ] && [ -n "$SEAL_GP_GATE_TEST" ] \
    || refuse unsealed "봉인 상수가 비어 있다"
  local s_self s_self_t s_gate s_gate_t
  s_self=$(sha "$C_SELF"); s_self_t=$(sha "$C_SELF_T"); s_gate=$(sha "$C_GATE"); s_gate_t=$(sha "$C_GATE_T")
  [ "$s_self" = "$SEAL_GP_SELF" ]        || refuse seal_mismatch "gp_self/guard_promote.sh $s_self ≠ 봉인"
  [ "$s_self_t" = "$SEAL_GP_SELF_TEST" ] || refuse seal_mismatch "gp_self/test_gp_self.sh $s_self_t ≠ 봉인"
  [ "$s_gate" = "$SEAL_GP_GATE" ]        || refuse seal_mismatch "gp_gate/gp_gate.sh $s_gate ≠ 봉인"
  [ "$s_gate_t" = "$SEAL_GP_GATE_TEST" ] || refuse seal_mismatch "gp_gate/test_gp_gate.sh $s_gate_t ≠ 봉인"

  # 4) 현 승격기로 기존 대상 status CONSISTENT
  [ -f "$PROMOTER" ] || refuse no_promoter "$REL_SELF"
  local ids i out
  ids=$(jq -r '.targets | keys[]' "$REG" 2>/dev/null)
  for i in $ids; do
    out=$(bash "$PROMOTER" status "$i" 2>&1 | tail -1)
    case "$out" in CONSISTENT*) ;; *) refuse pre_status "$i: $out";; esac
  done

  # 5) 정적 검사
  for f in "$C_SELF" "$C_SELF_T" "$C_GATE" "$C_GATE_T"; do
    bash -n "$f" 2>/dev/null || refuse static_check "$(basename "$f")"
  done

  # 6) 시험 — 최종 배치와 같은 상대경로의 사본 트리($W)에서 돈다
  local W="$WORK/t/hooks"
  mkdir -p "$W/lib" "$W/tests"
  cp -r "$HOOK_DIR/lib/." "$W/lib/" 2>/dev/null
  for i in $ids; do
    for f in $(jq -r --arg i "$i" '.targets[$i] | .live, .test' "$REG"); do
      mkdir -p "$(dirname "$W/$f")"; cp "$HOOK_DIR/$f" "$W/$f" || refuse copy_failed "$f"
    done
  done
  cp "$C_SELF" "$W/$REL_SELF"; cp "$C_SELF_T" "$W/$REL_SELF_TEST"
  cp "$C_GATE" "$W/$REL_GATE"; cp "$C_GATE_T" "$W/$REL_GATE_TEST"
  [ -f "$HOOK_DIR/tests/test_guard_promote.sh" ] || refuse no_test "tests/test_guard_promote.sh"
  cp "$HOOK_DIR/tests/test_guard_promote.sh" "$W/tests/test_guard_promote.sh"

  #   (a) test_gp_self <후보 승격기>
  must_pass gp_self "$W/$REL_SELF_TEST" "$W/$REL_SELF" "$MIN_PASS_GP_SELF"; local pass_self=$LAST_PASS
  #   (b) gp_self 카나리 — 같은 상대경로(H1)의 변이체(H2)
  mk_promoter_variant "$C_SELF" "$WORK/canary_a/hooks/$REL_SELF" allow
  mk_promoter_variant "$C_SELF" "$WORK/canary_d/hooks/$REL_SELF" deny
  canary gp_self "$W/$REL_SELF_TEST" "$WORK/canary_a/hooks/$REL_SELF" "$WORK/canary_d/hooks/$REL_SELF"
  #   (c) test_gp_gate <후보 모듈> + gp_gate 카나리
  must_pass gp_gate "$W/$REL_GATE_TEST" "$W/$REL_GATE" 1; local pass_gate=$LAST_PASS
  mk_gate_variant "$C_GATE" "$WORK/canary_a/hooks/$REL_GATE" allow
  mk_gate_variant "$C_GATE" "$WORK/canary_d/hooks/$REL_GATE" deny
  canary gp_gate "$W/$REL_GATE_TEST" "$WORK/canary_a/hooks/$REL_GATE" "$WORK/canary_d/hooks/$REL_GATE"
  #   (d) test_guard_promote <후보 승격기>
  must_pass guard_promote "$W/tests/test_guard_promote.sh" "$W/$REL_SELF" 1
  #   (e) 사본 트리에서 후보 승격기로 기존 대상 status
  for i in $ids; do
    out=$(bash "$W/$REL_SELF" status "$i" 2>&1 | tail -1)
    case "$out" in CONSISTENT*) ;; *) refuse cand_status "$i: $out";; esac
  done

  # 7) 새 등록부 작성 + 보관소
  local old_reg new_reg old_self NEWREG="$HOOK_DIR/lib/.gp_newreg.$$"
  old_reg=$(sha "$REG"); old_self=$(sha "$PROMOTER")
  jq --arg cs "$s_self" --arg ts "$s_self_t" --arg cg "$s_gate" --arg tg "$s_gate_t" \
     --arg ls "$REL_SELF" --arg lts "$REL_SELF_TEST" --arg lg "$REL_GATE" --arg ltg "$REL_GATE_TEST" \
     --arg ms "$pass_self" --arg mg "$pass_gate" --arg las "$LANG_GP_SELF" --arg lag "$LANG_GP_GATE" \
     '.targets.gp_self = {live:$ls, test:$lts, test_sha256:$ts, core_sha256:$cs, min_pass:($ms|tonumber), max_skip:0, lang:$las}
      | .targets.gp_gate = {live:$lg, test:$ltg, test_sha256:$tg, core_sha256:$cg, min_pass:($mg|tonumber), max_skip:0, lang:$lag}' \
     "$REG" > "$WORK/stage/new_reg.json" 2>/dev/null && [ -s "$WORK/stage/new_reg.json" ] || refuse registry_build_failed ""
  new_reg=$(sha "$WORK/stage/new_reg.json")
  for f in "$C_SELF" "$C_SELF_T" "$C_GATE" "$C_GATE_T" "$PROMOTER" "$REG" "$WORK/stage/new_reg.json"; do
    store_put "$f" || refuse store_failed "$(basename "$f")"
  done
  for i in $ids; do
    for f in $(jq -r --arg i "$i" '.targets[$i] | .live, .test' "$REG"); do store_put "$HOOK_DIR/$f" || refuse store_failed "$f"; done
  done

  # 8) 저널 → 백업 → 설치 → 커밋점 → 지문 → 저널 삭제
  local rel files="[]" o n
  for rel in "$REL_SELF_TEST" "$REL_GATE_TEST" "$REL_GATE" "$REL_SELF"; do
    if [ -f "$HOOK_DIR/$rel" ]; then o=$(sha "$HOOK_DIR/$rel"); store_put "$HOOK_DIR/$rel" || refuse store_failed "$rel"; else o=""; fi
    case "$rel" in
      "$REL_SELF_TEST") n=$s_self_t ;; "$REL_GATE_TEST") n=$s_gate_t ;; "$REL_GATE") n=$s_gate ;; *) n=$s_self ;;
    esac
    files=$(printf '%s' "$files" | jq -c --arg r "$rel" --arg o "$o" --arg n "$n" '. + [{rel:$r, old:$o, new:$n}]')
  done
  for f in "$FP" "$REGSHA"; do [ -f "$f" ] && { store_put "$f" || refuse store_failed "$(basename "$f")"; }; done
  beat
  journal_write "$old_reg" "$new_reg" "$files" || refuse journal_failed ""
  local ts bdir; ts=$(date '+%Y%m%d-%H%M%S')_$$; bdir="$BKD/${ts}_bootstrap"
  mkdir -p "$bdir" && cp -p "$REG" "$bdir/guard_promote.json" && cp -p "$PROMOTER" "$bdir/guard_promote.sh" \
    || { rm -f "$JOURNAL"; refuse backup_failed "$bdir"; }
  for f in "$FP" "$REGSHA"; do [ -f "$f" ] && cp -p "$f" "$bdir/"; done

  install_or_back() {  # $1=원본 $2=상대경로
    beat
    install_file "$1" "$HOOK_DIR/$2" && [ "$(sha "$HOOK_DIR/$2")" = "$(sha "$1")" ] && return 0
    abort_install "install_failed" "$2"
  }
  abort_install() {  # 커밋점 전·후 공통 원복 → REFUSE <코드>_rolled_back | rollback_failed(rc 3)
    if rollback_from_journal "$JOURNAL"; then
      rm -f "$FP" "$REGSHA"
      [ -f "$bdir/guard_promote.fp" ] && install_file "$bdir/guard_promote.fp" "$FP"
      [ -f "$bdir/guard_promote.regsha" ] && install_file "$bdir/guard_promote.regsha" "$REGSHA"
      rm -f "$JOURNAL" "$NEWREG"
      log_line "$(now_iso) BOOT_ROLLBACK reason=$1 at=$2 reg=$(sha "$REG") who=${PIPELINE_UUID:-main}"
      emit "ROLLED_BACK $1 at=$2 reg=$(sha "$REG")"; cleanup; exit 1
    fi
    rm -f "$NEWREG"
    log_line "$(now_iso) BOOT_ROLLBACK_FAILED reason=$1 at=$2 who=${PIPELINE_UUID:-main}"
    emit "REFUSE rollback_failed $1 at=$2 — 저널 $JOURNAL 유지(다음 실행 시 복구)"; cleanup; exit 3
  }

  install_or_back "$C_SELF_T" "$REL_SELF_TEST"
  install_or_back "$C_GATE_T" "$REL_GATE_TEST"
  install_or_back "$C_GATE"   "$REL_GATE"
  install_or_back "$C_SELF"   "$REL_SELF"
  cp "$WORK/stage/new_reg.json" "$NEWREG" || abort_install registry_stage_failed "lib/guard_promote.json"
  # @before_commit
  beat
  commit_registry "$NEWREG" || abort_install registry_commit_failed "lib/guard_promote.json"
  [ "$(sha "$REG")" = "$new_reg" ] || abort_install registry_verify_failed "lib/guard_promote.json"
  # @after_commit
  beat
  write_fp || abort_install fp_write_failed "logs/guard_promote.fp"
  rm -f "$JOURNAL"

  # 9) 새 승격기 verify·status (실패 시 원복 — 저널을 다시 써서 같은 원복 경로를 쓴다)
  local vout bad=""
  vout=$(bash "$PROMOTER" verify 2>&1 | tail -1)
  case "$vout" in VERIFIED*) ;; *) bad="verify: $vout";; esac
  if [ -z "$bad" ]; then
    for i in $(jq -r '.targets | keys[]' "$REG"); do
      out=$(bash "$PROMOTER" status "$i" 2>&1 | tail -1)
      case "$out" in CONSISTENT*) ;; *) bad="status $i: $out"; break;; esac
    done
  fi
  if [ -n "$bad" ]; then
    journal_write "$old_reg" "$new_reg" "$files" || { emit "REFUSE rollback_failed 저널 재기록 실패"; cleanup; exit 3; }
    abort_install post_check "$bad"
  fi

  # 10) 로그
  log_line "$(now_iso) BOOTSTRAP gp_self,gp_gate old=$old_self new=$s_self gate=$s_gate test_self=$s_self_t test_gate=$s_gate_t reg=$new_reg nonce=$BOOT_NONCE who=${PIPELINE_UUID:-main}"
  emit "DONE ok BOOTSTRAPPED gp_self=$s_self gp_gate=$s_gate reg=$new_reg"
}

alias_check "$@"
if [ -n "${GP_BOOT_CHILD:-}" ]; then cmd_run; else parent_main; fi
