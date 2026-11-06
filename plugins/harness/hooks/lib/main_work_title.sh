# 메인 pane 제목(@main_title)에 쓸 '작업 전체 주제 단문'을 계산·기록하는 공용 함수 — source 전용(bash)
# 사용처: UserPromptSubmit.sh(_ups_main_title — 착수 요청 시드 기록 + 적용), lib/main_pane_state.sh(리드 Stop·팀원 상태 변화 시 재적용).
# 2026-10-16 사용자 요구: "타이틀이 가장 최근 사용자 명령으로 보인다 → 작업 전체(팀에이전트 포함)의 최종목표 같은 주제 단문으로".
#
# [제목 소스 우선순위] (session-env/<UUID>/ 하위, 자기 세션만)
#   1) work_title          — 메인/oplan 이 쓰는 주제 단문(첫 줄). 전체 맥락을 아는 쪽의 명시 기록이 최우선.
#   2) plans/oplan_*.md H1 — 계획서 제목. '# oplan — 주제 (conv_…)' 형태면 '— ' 뒤 주제, 끝의 괄호 꼬리 제거.
#                            접두가 oplan/plan/계획이 아니면 '— ' 앞을 주제로 본다. *review*·*addendum* 파일 제외, 최신 mtime 1개.
#   3) goal.json .intent   — 1~2줄 의도 요약의 첫 줄(H1 보다 길어 뒤로 둔다).
#   4) main_topic          — 세션 수준 소스(1~3)에서 채택된 값의 보존본(자기 session-env/<UUID>/main_topic, ofinish 정리 대상 아님).
#   5) work_title_seed    — 이번 작업 사이클을 '연' 사용자 요청(UserPromptSubmit 이 착수 판정 시에만 기록). _mwt_topic 으로 주제화.
#                           seed 채택값은 main_topic 에 기록하지 않는다(턴 원문이 세션 주제를 덮지 않게).
#   6) 없음                — 테두리 형식이 pane_title(Claude Code 세션 제목)로 폴백.
# [필터] 모든 소스에 _mwt_reject 적용 — 팀원 이름(o(plan|dev|test|done|build)-X, 팀 config members)이 든 값은 건너뛰고 다음 소스로.
# [신선도] work_title_seed 가 있으면 1)~3)은 mtime 이 seed 이상인 것만 쓴다 — 새 사이클 진입 후 이전 사이클의
#   work_title/계획서/goal.json 이 남아 있어도 새 착수 요청이 이긴다(정리 주체에 의존하지 않음).
# [시드 교체 판정] main_work_title_seed 참조 — 중간 지시('계속 진행해', '타이틀 버그 고쳐' 등)로는 덮어쓰지 않는다.
# 표시 길이 상한 MAIN_TITLE_MAX(24자, 초과 시 '…'). 실패는 전부 조용히 넘어간다(표시 전용).

MAIN_TITLE_MAX=24

# _mwt_clean <문자열> → REPLY: 제어문자·연속 공백 정리 + 길이 상한
_mwt_clean() {
  local t="$1" LC_ALL=C.UTF-8
  t="${t//$'\r'/ }"; t="${t//$'\n'/ }"; t="${t//$'\t'/ }"
  while [[ "$t" == *"  "* ]]; do t="${t//  / }"; done
  t="${t# }"; t="${t% }"
  (( ${#t} > MAIN_TITLE_MAX )) && t="${t:0:MAIN_TITLE_MAX}…"
  REPLY="$t"
}

# _mwt_topic <사용자 원문> → REPLY: 번호/불릿·군말·첫 문장 밖·끝 요청 어미를 걷어낸 주제 단문(순수 bash, 포크 없음)
_mwt_topic() {
  local t="$1" LC_ALL=C.UTF-8 re='^(\[[0-9]+\]|[0-9]+[.)]|[①②③④⑤⑥⑦⑧⑨⑩]|[-*•])[[:space:]]*' s
  t="${t%%$'\n'*}"
  while [[ "$t" =~ $re ]]; do t="${t:${#BASH_REMATCH[0]}}"; done
  while :; do
    case "$t" in "지금 "*|"그리고 "*|"근데 "*|"음 "*|"자 "*|"이제 "*|"바로 "*|"먼저 "*|"우선 "*) t="${t#* }";; *) break;; esac
  done
  t="${t%%. *}"; t="${t%%\? *}"; t="${t%%! *}"; t="${t%.}"
  for s in 해주세요 합시다 해줘 해라 하자 하라; do
    if [[ "$t" == *"$s" ]] && (( ${#t} - ${#s} >= 4 )); then t="${t%"$s"}"; break; fi
  done
  REPLY="$t"
}

# _mwt_names <session 디렉토리> → MWT_NAMES: 자기 세션 팀 config.json members 이름 목록(소문자, 길이 4 이상, team-lead 제외)
#   팀 경로는 자기 세션 team_name 기준(타 세션 경로 금지). config·jq 부재면 빈값. compute 호출당 1회만 jq 를 쓴다.
_mwt_names() {
  local d="$1" tn n cfg; MWT_NAMES=""
  [ -r "$d/team_name" ] || return 0
  read -r tn < "$d/team_name" || [ -n "$tn" ] || return 0
  case "$tn" in ""|*/*|*..*) return 0;; esac
  cfg="${d%/session-env/*}/teams/$tn/config.json"
  { [ -f "$cfg" ] && command -v jq >/dev/null 2>&1; } || return 0
  while IFS= read -r n; do
    n="${n,,}"
    if (( ${#n} >= 4 )) && [ "$n" != "team-lead" ] && [[ "$n" =~ ^[a-z0-9_-]+$ ]]; then MWT_NAMES="$MWT_NAMES $n"; fi
  done < <(jq -r '.members[]?.name // empty' "$cfg" 2>/dev/null)
}

# _mwt_reject <text> <session 디렉토리> — 팀원 이름이 든 제목이면 0(거부). 순수 bash([[ =~ ]]), 포크 없음.
#   (1) 패턴 o(plan|dev|test|done|build)-<영숫자> (2) MWT_NAMES 이름과 단어경계 전체 일치(대소문자 무시)
_mwt_reject() {
  local t="${1,,}" n
  [[ "$t" =~ o(plan|dev|test|done|build)-[a-z0-9]+ ]] && return 0
  for n in $MWT_NAMES; do
    [[ "$t" =~ (^|[^a-z0-9_-])"$n"($|[^a-z0-9_-]) ]] && return 0
  done
  return 1
}

# _mwt_adopt <제목> <session 디렉토리> — 세션 수준 소스 채택값을 main_topic 에 보존(값이 바뀔 때만). seed 채택에는 쓰지 않는다.
_mwt_adopt() {
  local cur=""
  [ -r "$2/main_topic" ] && read -r cur < "$2/main_topic"
  [ "$cur" = "$1" ] || printf '%s\n' "$1" > "$2/main_topic" 2>/dev/null
  return 0
}

# _mwt_fresh <파일> <seed 파일> — seed 가 없거나 파일 mtime >= seed mtime 이면 0
_mwt_fresh() { [ -s "$1" ] && { [ ! -e "$2" ] || [ ! "$1" -ot "$2" ]; }; }

# _mwt_h1 <계획서> → REPLY: H1 에서 주제 추출(앞 8줄 안의 첫 '# ' 줄)
_mwt_h1() {
  local line n=0 t="" head
  while IFS= read -r line && (( n++ < 8 )); do
    case "$line" in "# "*) t="${line#\# }"; break;; esac
  done < "$1"
  REPLY=""
  [ -n "$t" ] || return 1
  if [[ "$t" == *" — "* ]]; then
    head="${t%% — *}"
    case "${head,,}" in oplan*|plan*|계획*) t="${t#* — }";; *) t="$head";; esac
  fi
  [[ "$t" == *" ("*")" ]] && t="${t% (*}"
  _mwt_clean "$t"
  [ -n "$REPLY" ]
}

# main_work_title_compute <session 디렉토리> → REPLY=제목(없으면 빈값), MWT_SRC=소스 이름
main_work_title_compute() {
  local d="$1" seed="$1/work_title_seed" f p="" t="" ps st
  REPLY=""; MWT_SRC=""
  [ -d "$d" ] || return 1
  _mwt_names "$d"
  f="$d/work_title"
  if _mwt_fresh "$f" "$seed"; then
    read -r t < "$f"; _mwt_clean "$t"
    if [ -n "$REPLY" ] && ! _mwt_reject "$REPLY" "$d"; then MWT_SRC=work_title; _mwt_adopt "$REPLY" "$d"; return 0; fi
  fi
  for f in "$d"/plans/oplan_*.md; do
    [ -f "$f" ] || continue
    case "${f##*/}" in *review*|*addendum*) continue;; esac
    { [ -z "$p" ] || [ "$f" -nt "$p" ]; } && p="$f"
  done
  if [ -n "$p" ] && _mwt_fresh "$p" "$seed" && _mwt_h1 "$p" && ! _mwt_reject "$REPLY" "$d"; then
    MWT_SRC=plan_h1; _mwt_adopt "$REPLY" "$d"; return 0
  fi
  f="$d/goal.json"
  if _mwt_fresh "$f" "$seed" && command -v jq >/dev/null 2>&1; then
    t=$(jq -r '.intent // empty' "$f" 2>/dev/null | head -1)
    _mwt_clean "$t"
    if [ -n "$REPLY" ] && ! _mwt_reject "$REPLY" "$d"; then MWT_SRC=goal_intent; _mwt_adopt "$REPLY" "$d"; return 0; fi
  fi
  # 보존된 세션 주제 — 소스가 사라진 뒤(IDLE 등)에도 유지. seed(턴 원문)보다 앞.
  #   새 파이프라인 경계: pipeline_start_time(epoch 초)보다 오래된 main_topic 은 state 가 IDLE 이 아닐 때 건너뛴다
  #   (슬래시 착수는 main_work_title_seed 가 이미 삭제. 이 조건은 비슬래시 자율진입 대비). 시작 시각 부재면 미적용.
  f="$d/main_topic"
  if [ -s "$f" ]; then
    t=""; ps=""; st=""
    [ -r "$d/pipeline_start_time" ] && read -r ps < "$d/pipeline_start_time"
    [ -r "$d/state" ] && read -r st _ < "$d/state"
    if [[ "$ps" =~ ^[0-9]+$ ]] && [ -n "$st" ] && [ "$st" != IDLE ] \
       && [ "$(stat -c %Y "$f" 2>/dev/null || echo 0)" -lt "$ps" ]; then
      :
    else
      read -r t < "$f"
    fi
    _mwt_clean "$t"
    if [ -n "$REPLY" ] && ! _mwt_reject "$REPLY" "$d"; then MWT_SRC=main_topic; return 0; fi
  fi
  if [ -s "$seed" ]; then
    read -r t < "$seed"; _mwt_topic "$t"; _mwt_clean "${REPLY:-$t}"
    if [ -n "$REPLY" ] && ! _mwt_reject "$REPLY" "$d"; then MWT_SRC=seed; return 0; fi
  fi
  REPLY=""; return 1
}

# main_work_title_seed <session 디렉토리> <정리된 사용자 요청> <state> — 이번 사이클을 '여는' 요청이면 seed 기록(0), 아니면 1
#   교체 O: (가) 파이프라인 진입 슬래시(/ok /o1~/o5 /oto /oroof /ok*·/o{deep,consult,debate,plan,normal,simple} /ox /ohaiku /osonnet /oopus)
#               + 인자 있음 → 인자를 seed 로(state 무관 — 새 작업 착수 명시).
#           (나) 비슬래시 요청 + state ∈ {IDLE, 빈값, EARLY_TERM} + 짧은 응답/계속 지시가 아님 + 질문이 아님.
#   교체 X: PLAN/DEV/TEST/DONE/FINISH 중 비슬래시 입력(=중간 지시), 그 외 슬래시(/oss /oinit /oresume …),
#           6자 미만·'계속/진행/응/네/ok…' 로 시작하는 응답, '?'·'까'·'나요'·'니'·'냐' 로 끝나는 질문.
main_work_title_seed() {
  local d="$1" p="$2" st="$3" cmd args LC_ALL=C.UTF-8
  [ -d "$d" ] || return 1
  p="${p# }"; p="${p% }"
  [ -n "$p" ] || return 1
  if [[ "$p" == /* ]]; then
    cmd="${p%% *}"; args=""; [[ "$p" == *" "* ]] && args="${p#* }"
    case "$cmd" in
      /ok|/o[1-5]|/oto|/oroof|/okdeep|/okconsult|/okdebate|/odeep|/oconsult|/odebate|/oplan|/onormal|/osimple|/ox|/ohaiku|/osonnet|/oopus|/oteam) ;;
      *) return 1;;
    esac
    p="$args"
  else
    case "$st" in IDLE|""|EARLY_TERM) ;; *) return 1;; esac
    case "${p,,}" in
      계속*|진행*|응|응\ *|네|네\ *|예|예\ *|ㅇㅇ*|ㅇㅋ*|좋아*|오케이*|ok|ok\ *|okay*|yes*|그래*|고고*|go|go\ *) return 1;;
    esac
    case "$p" in *"?"|*까|*까.|*나요|*나요.|*니|*냐) return 1;; esac
  fi
  while :; do   # 앞머리 군말 제거
    case "$p" in "지금 "*|"그리고 "*|"근데 "*|"음 "*|"자 "*|"이제 "*) p="${p#* }";; *) break;; esac
  done
  (( ${#p} >= 6 )) || return 1
  printf '%s\n' "${p:0:120}" > "$d/work_title_seed" 2>/dev/null || return 1
  [[ "${2# }" == /* ]] && rm -f "$d/main_topic" 2>/dev/null   # 파이프라인 착수 슬래시 = 새 주제 경계(이전 세션 주제 폐기)
  return 0
}

# main_work_title_apply <session 디렉토리> <pane> [현재 @main_title] — 계산값이 현재와 다를 때만 자기 pane 에 기록
main_work_title_apply() {
  local d="$1" pane="$2" cur
  case "$pane" in %[0-9]*) ;; *) return 0;; esac
  main_work_title_compute "$d" || return 0
  if [ $# -ge 3 ]; then cur="$3"; else cur=$(tmux show -p -v -t "$pane" @main_title 2>/dev/null); fi
  [ "$REPLY" = "$cur" ] && return 0
  tmux set -p -t "$pane" @main_title "$REPLY" >/dev/null 2>&1
  return 0
}
