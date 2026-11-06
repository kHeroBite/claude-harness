#!/bin/bash
# otest 에이전트 이름으로 자원 축(데스크톱/모바일)을 판정하고 축별 완료 마커를 결정하는 공용 함수
#
# 배경 (2026-10-04 사용자 지시):
#   "otest 는 하나만" 원칙의 목적은 같은 자원을 두 otest 가 동시에 건드리지 않게 하는 것이다.
#   데스크톱(PC 앱 실행본·빌드 산출물·사용자 화면)과 모바일(에뮬레이터·실기기·adb·APK)은
#   자원이 겹치지 않으므로 축이 다르면 동시 실행을 허용한다. 같은 축 2개는 여전히 금지다.
#
# 이름 규약 (단일 출처 — ok_pipeline/otest SKILL.md 가 이 규약을 인용한다):
#   모바일 축  : otest-m-{N}   (별칭 otest-mobile-{N} 도 모바일로 판정)
#                접미 변형 otest-{임의}-m / otest-{임의}-mobile 도 모바일 (예: otest-c1-m)
#   데스크톱 축: 그 밖의 otest*  (otest-{N} — 기존 이름 그대로)
#                ⚠️ 데스크톱 otest 이름은 '-m' / '-mobile' 로 끝나면 안 된다 (모바일로 판정됨)
#
# 축별 완료 마커 (evidence/ 하위):
#   데스크톱: otest_done    (기존 마커 — 의미 무변경)
#   모바일  : otest_done_m
#   모바일 otest 기동 선언: otest_m_started (모바일 otest 가 진입 즉시 생성 — 리드 누락 대비)
#   리드의 축 선언(선택): otest_axes  (내용 예: "desktop mobile" 또는 "mobile")
#
# 사용법:
#   source lib/otest_axis.sh
#   otest_axis_of "otest-m-1"        → stdout "mobile"   (rc 0)
#   otest_axis_of "otest-1"          → stdout "desktop"  (rc 0)
#   otest_axis_of "odev-1"           → stdout ""         (rc 1 — otest 아님)
#   otest_axis_marker mobile         → stdout "otest_done_m"
#   otest_axis_required_markers SESSION_DIR [PIPELINE_START]
#                                    → stdout 필요한 마커 이름(공백 구분), 예 "otest_done otest_done_m"

otest_axis_of() {
  local n="$1"
  case "$n" in
    # 접두 규약(otest-m-N) + 접미 변형(otest-xxx-m / otest-xxx-mobile — 2026-10-04 추가)
    otest-m-*|otest-m|otest-mobile-*|otest-mobile|otest*-m|otest*-mobile) printf 'mobile'; return 0 ;;
    # 웹 축(2026-10-16 가산): otest-w-{N} / otest-web-{N} / 접미 변형 otest-{임의}-w / -web
    # 모바일 패턴이 먼저 평가되므로 otest-m-w 류는 모바일로 남는다(기존 판정 불변).
    otest-w-*|otest-w|otest-web-*|otest-web|otest*-w|otest*-web) printf 'web'; return 0 ;;
    otest*) printf 'desktop'; return 0 ;;
  esac
  return 1
}

otest_axis_marker() {
  case "$1" in
    mobile) printf 'otest_done_m' ;;
    web)    printf 'otest_done_w' ;;
    *)      printf 'otest_done' ;;
  esac
}

# 이번 파이프라인(PIPELINE_START 이후)에 생성된 파일인지
_otest_axis_fresh() {
  local f="$1" start="${2:-}" m
  [ -f "$f" ] || return 1
  [ -z "$start" ] && return 0
  m=$(stat -c %Y "$f" 2>/dev/null || echo 0)
  [ "$m" -gt "$start" ]
}

# odone 진입에 필요한 축별 완료 마커 목록을 낸다.
#   판정 규칙 (요구를 늘리는 방향만 추가 — 기존 동작은 "otest_done 필수" 그대로 유지):
#   1) 리드가 evidence/otest_axes 를 이번 파이프라인에 썼으면 거기 적힌 축만 요구한다.
#      (모바일 단독 변경이면 "mobile" 만 적어 otest_done 요구를 뺄 수 있는 유일한 경로)
#   2) otest_axes 가 없으면 기존대로 otest_done(데스크톱)을 요구한다.
#   3) 이번 파이프라인에 모바일 otest 흔적(otest_m_started 또는 agents/otest-m-* )이 있으면
#      otest_done_m 을 추가로 요구한다 — 데스크톱이 먼저 끝나도 모바일 완료 전에는 odone 진입 불가.
otest_axis_required_markers() {
  local sd="$1" start="${2:-}" axes_f want_d=1 want_m=0 want_w=0 a f sp
  axes_f="${sd}/evidence/otest_axes"
  if _otest_axis_fresh "$axes_f" "$start"; then
    want_d=0
    for a in $(tr ',|' '  ' < "$axes_f" 2>/dev/null); do
      case "$a" in
        desktop|d|pc) want_d=1 ;;
        mobile|m)     want_m=1 ;;
        web|w)        want_w=1 ;;
      esac
    done
    # 판독 결과 축이 하나도 없으면 기존 동작으로 되돌린다 (fail-closed)
    [ "$want_d" -eq 0 ] && [ "$want_m" -eq 0 ] && [ "$want_w" -eq 0 ] && want_d=1
  fi
  if _otest_axis_fresh "${sd}/evidence/otest_m_started" "$start"; then
    want_m=1
  fi
  if _otest_axis_fresh "${sd}/evidence/otest_w_started" "$start"; then
    want_w=1
  fi
  for f in "${sd}/agents"/otest*; do
    [ -f "$f" ] || continue
    local _ax
    _ax="$(otest_axis_of "$(basename "$f")")"
    [ "$_ax" = "mobile" ] || [ "$_ax" = "web" ] || continue
    case "$f" in *.failed) continue ;; esac
    sp=$(grep '^spawned_at=' "$f" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
    if [ -z "$start" ] || { [ -n "$sp" ] && [ "$sp" -gt "$start" ] 2>/dev/null; }; then
      [ "$_ax" = "mobile" ] && want_m=1
      [ "$_ax" = "web" ] && want_w=1
    fi
  done
  local out=""
  [ "$want_d" -eq 1 ] && out="otest_done"
  [ "$want_m" -eq 1 ] && out="${out:+$out }otest_done_m"
  [ "$want_w" -eq 1 ] && out="${out:+$out }otest_done_w"
  printf '%s' "$out"
}
