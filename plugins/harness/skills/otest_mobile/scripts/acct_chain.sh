#!/bin/bash
# 계정별 연쇄 실행기 — 계정 목록 × 단계 목록을 계정 단위로 직렬 실행하고 단계별 rc·시각을 계정 로그에 남긴다
# 사용: acct_chain.sh <계정파일.tsv> <단계파일.txt> [계정TAG 필터(쉼표)]
#   계정파일(TSV, # 주석 허용): TAG<TAB>ID<TAB>PW<TAB>표시이름<TAB>역할
#   단계파일(한 줄 = 한 단계, # 주석 허용): 단계이름|셸명령
#     명령 안에서 $ACCT_TAG $ACCT_ID $ACCT_PW $ACCT_NAME $ACCT_ROLE $STEP_OUT 을 쓸 수 있다.
#     단계이름 앞에 '!' 를 붙이면 필수 단계 — 실패 시 그 계정의 남은 단계를 건너뛴다.
# 환경변수: OUT(기본 ./otest_mobile_out). 계정 로그 $OUT/chain_<TAG>.log, 요약 $OUT/chain_summary.tsv
# 원칙: 같은 기기에서 계정을 병렬로 돌리지 않는다(로그인 세션 충돌). 병렬은 기기(AVD)를 나눠서만 한다.
export LC_ALL=C.UTF-8
ACC=$1; STEPS=$2; ONLY=${3:-}
[ -f "$ACC" ] && [ -f "$STEPS" ] || { echo "사용: acct_chain.sh <계정.tsv> <단계.txt> [TAG필터]" >&2; exit 2; }
OUT=${OUT:-./otest_mobile_out}; mkdir -p "$OUT"; SUM=$OUT/chain_summary.tsv
[ -f "$SUM" ] || printf "time\ttag\tstep\trc\tsec\n" > "$SUM"
total_fail=0
while IFS=$'\t' read -r TAG ID PW NAME ROLE; do
  case "$TAG" in ''|\#*) continue ;; esac
  if [ -n "$ONLY" ]; then case ",$ONLY," in *,"$TAG",*) ;; *) continue ;; esac; fi
  export ACCT_TAG=$TAG ACCT_ID=$ID ACCT_PW=${PW:-$ID} ACCT_NAME=$NAME ACCT_ROLE=$ROLE
  export STEP_OUT=$OUT/$TAG; mkdir -p "$STEP_OUT"
  L=$OUT/chain_$TAG.log
  echo "$(date '+%F %T') ▶ CHAIN_START $TAG ($NAME/$ROLE)" >> "$L"
  skip=0
  while IFS= read -r line <&3; do
    case "$line" in ''|\#*) continue ;; esac
    sname=${line%%|*}; scmd=${line#*|}; must=0
    case "$sname" in !*) must=1; sname=${sname#!} ;; esac
    if [ $skip = 1 ]; then echo "$(date '+%F %T') ▷ SKIP $sname (필수 단계 실패 후)" >> "$L"; continue; fi
    t0=$(date +%s); echo "$(date '+%F %T') ▶ $sname" >> "$L"
    bash -c "$scmd" >> "$L" 2>&1 < /dev/null; rc=$?
    sec=$(( $(date +%s) - t0 ))
    echo "$(date '+%F %T') ◀ $sname rc=$rc ${sec}s" >> "$L"
    printf "%s\t%s\t%s\t%s\t%s\n" "$(date '+%F %T')" "$TAG" "$sname" "$rc" "$sec" >> "$SUM"
    if [ $rc != 0 ]; then total_fail=$((total_fail+1)); [ $must = 1 ] && skip=1; fi
  done 3< "$STEPS"
  echo "$(date '+%F %T') ▶ CHAIN_DONE $TAG" >> "$L"
done < "$ACC"
echo "연쇄 완료 — 실패 단계 $total_fail건, 요약 $SUM"
[ $total_fail = 0 ]
