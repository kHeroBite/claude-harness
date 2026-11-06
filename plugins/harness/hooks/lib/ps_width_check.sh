#!/bin/bash
# ps 명령줄 조회(args/cmd/command)에 폭 무제한(ww) 옵션이 빠졌는지 한 줄 단위로 판정하는 공용 라이브러리
#
# 단일 출처(L-570, conv_179163042411 §9-3): 아래 두 곳이 이 파일을 source 해 같은 규칙을 쓴다.
#   - tests/test_ps_width_static.sh : hooks·scripts 전수 정적 검사(최종 방어선)
#   - write_guard.sh F-PSW-1        : 파일 도구로 새로 들어가는 줄을 작성 시점에 차단
#
# 배경: hook 프로세스는 tmux 의 COLUMNS=80 을 상속한다. procps `ps -o args` 는 그 폭으로 잘려
#       --agent-id / --parent-session-id 토큰이 끊기고, 살아 있는 팀원을 죽은 것으로 판정했다.
#
# API (계획서 고정):
#   ps_width_violation "<한 줄>"   → 0=위반 · 1=정상
#   PS_WIDTH_PREFILTER_RE          → 사전 필터 ERE(줄에 ps 호출 단어가 있는지). 이 필터에 안 걸리는 줄은 항상 정상이다.
#
# 규칙(test_ps_width_static.sh 의 _is_violation 을 그대로 옮김):
#   주석 줄 제외 · 줄 끝 `# ps-width-ok` 예외 · 백틱 인용(`ps ...`) 제외 ·
#   args/cmd/command 단어 경계 · -o 목록 · ww(-eww / -ww / 'ww' 인자) 있으면 정상.
# 이 파일도 hooks/lib 아래라 정적 검사 대상이다 — 정규식 줄이 위반으로 잡히지 않게 작성했다(검사 결과 0 유지).

PS_WIDTH_PREFILTER_RE='(^|[^A-Za-z0-9_./-])ps([[:space:]]|["'"'"'],)'

ps_width_violation() {
  local line="$1"
  # 주석 줄 제외
  printf '%s\n' "$line" | grep -qE '^[[:space:]]*#' && return 1
  # 예외 표기
  printf '%s\n' "$line" | grep -q 'ps-width-ok' && return 1
  # ps 호출 + -o 목록에 args/cmd/command
  printf '%s\n' "$line" | grep -qE "$PS_WIDTH_PREFILTER_RE" || return 1
  # 문서 문자열 안의 `ps ...` 인용(백틱)은 실행 코드가 아니다
  printf '%s\n' "$line" | grep -q '`ps ' && return 1
  # 필드명 단어 경계 — xargs 의 "args" 같은 부분 일치 제외
  printf '%s\n' "$line" | grep -qE '(^|[^A-Za-z_])(args|cmd|command)(=|[,"'"'"'[:space:]]|$)' || return 1
  printf '%s\n' "$line" | grep -qE -- "-[A-Za-z]*o[[:space:]\"',]|-o[[:space:]\"']|-[A-Za-z]*o[A-Za-z]*[[:space:]]+[a-z%]*,?(args|cmd|command)" || return 1
  # ww 존재 여부 (ps -eww / -ww / 'ww' 인자)
  printf '%s\n' "$line" | grep -qE -- "-[A-Za-z]*ww|[\"']-?[A-Za-z]*ww[\"']" && return 1
  return 0
}
