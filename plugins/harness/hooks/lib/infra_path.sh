#!/bin/bash
# 프로젝트 루트 INFRA.md 의 경로를 찾고 INFRA-FIELDS v1 헤더 필드를 읽는 공용 헬퍼 (bash 전용, source 해서 쓴다)
#
# 사용법:
#   source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/infra_path.sh"
#   INFRA=$(infra_md_path "<디렉터리>")      # 찾으면 절대경로 출력 rc=0, 못 찾으면 빈 출력 rc=1
#   VAL=$(infra_field "$INFRA" <키>)          # 값 출력 rc=0, 파일·블록·키 부재 또는 해석 실패면 빈 출력 rc=1
#
# infra_md_path 해석 순서:
#   1) git -C <dir> rev-parse --show-toplevel → 그 루트의 INFRA.md
#   2) 없으면 --git-common-dir 의 부모(= 주 작업트리) 의 INFRA.md
#      (INFRA.md 는 추적 제외라 git worktree 에는 없다)
#   3) 비git 이면 <dir> 자신부터 상위 4단계까지 INFRA.md 탐색
# infra_field 파싱 규칙(INFRA.md 스키마 고정 규칙):
#   파일 처음 40줄 안, "<!-- INFRA-FIELDS v1" 와 "<!-- /INFRA-FIELDS -->" 사이,
#   들여쓰기 0 의 "key: value" 첫 출현만 유효. 값 뒤 " # 주석" 제거, 따옴표 1겹 제거, CR 제거.
# 이 파일은 함수 정의만 한다(전역 상태 변경·출력 없음). set -e/-u 환경에서도 안전하게 동작한다.

infra_md_path() {
  local dir="${1:-}" top common main d i
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  if top=$(timeout 5 git -C "$dir" rev-parse --show-toplevel 2>/dev/null) && [ -n "$top" ]; then
    if [ -f "$top/INFRA.md" ]; then
      printf '%s\n' "$top/INFRA.md"; return 0
    fi
    common=$(timeout 5 git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || common=""
    if [ -n "$common" ]; then
      case "$common" in
        /*) ;;
        *) common="$dir/$common" ;;
      esac
      common=$(cd "$common" 2>/dev/null && pwd -P) || common=""
      if [ -n "$common" ]; then
        main=$(dirname "$common")
        if [ -f "$main/INFRA.md" ]; then
          printf '%s\n' "$main/INFRA.md"; return 0
        fi
      fi
    fi
    return 1
  fi
  # 비git: dir 자신부터 상위 4단계
  d=$(cd "$dir" 2>/dev/null && pwd) || return 1
  i=0
  while [ "$i" -le 4 ]; do
    if [ -f "$d/INFRA.md" ]; then
      printf '%s\n' "$d/INFRA.md"; return 0
    fi
    [ "$d" = "/" ] && break
    d=$(dirname "$d")
    i=$((i + 1))
  done
  return 1
}

infra_field() {
  local f="${1:-}" key="${2:-}" v
  [ -n "$f" ] && [ -f "$f" ] || return 1
  case "$key" in
    ''|*[!a-zA-Z0-9_]*) return 1 ;;
  esac
  v=$(head -n 40 "$f" 2>/dev/null | tr -d '\r' \
      | sed -n '/<!-- INFRA-FIELDS v1/,/<!-- \/INFRA-FIELDS -->/p' \
      | grep -m1 -E "^${key}:" \
      | sed -E "s/^${key}:[[:space:]]*//; s/[[:space:]]+#.*$//; s/[[:space:]]+$//; s/^[\"']//; s/[\"'][[:space:]]*$//") || v=""
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
  return 0
}
