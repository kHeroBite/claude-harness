#!/bin/bash
# set_terminal_title.sh
# Windows Terminal 타이틀바 갱신 헬퍼 — tmux rename-window 경유.
# state_write() 등 state 변경 지점에서 호출하여 즉시성 보장.
#
# 포맷: "{호스트이모지}{프로젝트} [🎭롤] [{아이콘}{현재 남은%}] {state이모지} {state} 👤 {계정명}" (값이 없는 칸은 생략, 👤 는 항상 계정명 바로 앞)
# 예시: "🖥️AI ⚡74% 🧍 idle 👤 rio", /oagent 이름이 있으면 "🖥️AI 🎭back#철수 74% 🧍 idle 👤 rio", 리눅스 서버는 "🗄️Pd …"
# 바깥 창 제목 맨 앞의 스피너(◜◝◞◟, 메인 pane 작업 중일 때만)는 tmux set-titles-string 이 붙인다.
# 호스트 이모지는 host_label.py(statusline.py 와 공용 규칙)가 정한다. tier 를 모르므로 단계 칸은 다음 statusline 갱신 때 "🏃 ok:o4 dev" 가 된다.
#
# 의존: tmux·TMUX_PANE (없으면 silent skip), CLAUDE_PROFILE_NAME 또는 USER 환경변수
#       사용량 표기 캐시: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.weekly_remaining_cache (statusline.py가 갱신)
# 사이드이펙트: 자기 pane 이 속한 tmux window 이름만 동일 텍스트로 변경됨 (의도된 동작)

# statusline.py get_origin_project_name 과 같은 판정 — 원본 checkout 이름(worktree 안에서도 같음), 실패 시 폴더 이름
_title_origin_project() {
  local dir="$1" common base name=""
  common=$(timeout 2 git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null </dev/null)
  common="${common%/}"
  if [ -n "$common" ]; then
    base="${common##*/}"
    if [ "$base" = ".git" ]; then
      name="${common%/*}"
      name="${name##*/}"
    else
      name="${base%.git}"
    fi
  fi
  # git 실패 폴백 — statusline._project_path_fallback 과 같은 규칙(`<P>/.claude/worktrees/<이름>` 이면 P, 아니면 폴더 이름)
  if [ -z "$name" ]; then
    case "$dir" in
      */.claude/worktrees/*) name="${dir%%/.claude/worktrees/*}"; name="${name##*/}" ;;
    esac
  fi
  [ -n "$name" ] || name=$(basename "$dir")
  printf '%s' "$name"
}

set_terminal_title() {
  local STATE_VALUE="${1:-IDLE}"

  # 팀에이전트 컨텍스트(PIPELINE_UUID 환경변수 존재)는 메인 타이틀바를 건드리지 않음
  [ -n "${PIPELINE_UUID:-}" ] && return 0

  # 비-tmux 환경 가드 (silent skip)
  [ -z "${TMUX:-}" ] && return 0
  command -v tmux >/dev/null 2>&1 || return 0

  # 대상 없는 tmux 명령은 가장 최근 세션에 적용돼 다른 세션 제목을 바꾼다. 자기 pane 을 모르면 쓰지 않는다.
  case "${TMUX_PANE:-}" in %[0-9]*) ;; *) return 0 ;; esac

  # 프로필 ID
  # statusline 이 실제 로그인 계정으로 판정해 남긴 값을 우선한다(CLAUDE_PROFILE_NAME 은 시작 프로필이라 /login 후 틀릴 수 있다)
  local PROFILE_ID=""
  [ -r "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.display_profile" ] \
    && IFS= read -r PROFILE_ID < "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.display_profile"
  # 계정을 모르면 `?` (statusline 의 `👤 ?` 규칙과 동일 — $USER 폴백은 계정 의미가 아니라 폐기)
  [ -n "$PROFILE_ID" ] || PROFILE_ID="${CLAUDE_PROFILE_NAME:-?}"

  # 프로젝트 이름 — statusline 제목과 값이 갈리면 탭이 번갈아 바뀌므로 tmux 세션명(claude-<폴더>[-N])에서 뽑지 않는다.
  # 세션명은 -N 접미와 폴더명의 하이픈·숫자(Workshop-2026-01)를 구별할 수 없다.
  # 1순위: statusline 이 session-env/<UUID>/display_project 에 남긴 값
  # 2순위: 첫 statusline 갱신 전이면 같은 방법(_title_origin_project)으로 계산
  local _SID="${UUID:-${MY_UUID:-}}"
  local PROJECT=""
  [ -n "$_SID" ] && [ -r "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/$_SID/display_project" ] \
    && IFS= read -r PROJECT < "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/$_SID/display_project"
  [ -n "$PROJECT" ] || PROJECT=$(_title_origin_project "${CLAUDE_PROJECT_DIR:-$PWD}")

  # state lowercase + 이모지 매핑
  # 화이트리스트만 허용 — 미지정 state(예: 옛 캐시 hook이 보낸 "WAIT")는 IDLE 폴백.
  # 이유: ❔ wait 같은 잔재 표시 차단 (LESSONS L-NEW-D)
  local STATE_UPPER STATE_LOWER STATE_EMOJI
  STATE_UPPER=$(echo "$STATE_VALUE" | tr '[:lower:]' '[:upper:]')
  case "$STATE_UPPER" in
    IDLE)        STATE_EMOJI="🧍" ;;
    OK)          STATE_EMOJI="🚶" ;;
    PLAN)        STATE_EMOJI="🤔" ;;
    DEV)         STATE_EMOJI="🏃" ;;
    TEST)        STATE_EMOJI="🧪" ;;
    DONE)        STATE_EMOJI="✅" ;;
    FINISH)      STATE_EMOJI="🧎" ;;
    EARLY_TERM)  STATE_EMOJI="⏹️" ;;
    ERROR)       STATE_EMOJI="❌" ;;
    *)
      # 화이트리스트 외 state는 IDLE로 강제 폴백 (옛 hook의 "WAIT" 등 잔재 차단)
      STATE_UPPER="IDLE"
      STATE_EMOJI="🧍"
      ;;
  esac
  STATE_LOWER=$(echo "$STATE_UPPER" | tr '[:upper:]' '[:lower:]')

  # 사용량 칸 — statusline.py 가 자기 제목에 쓴 표기(아이콘=예상 잔량, 숫자=현재 잔량)를 그대로 읽어 두 경로의 값이 오가지 않게 한다
  local WEEKLY_CACHE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.weekly_remaining_cache"
  local ID_PART="$PROFILE_ID" PCT_PART=""
  if [ -f "$WEEKLY_CACHE" ]; then
    local WEEKLY_PCT BADGE_RE='^(⛔|⚠|⚡)?-?[0-9]+%$'
    WEEKLY_PCT=$(cat "$WEEKLY_CACHE" 2>/dev/null | tr -d '[:space:]')
    if [[ "$WEEKLY_PCT" =~ $BADGE_RE ]]; then
      PCT_PART=" ${WEEKLY_PCT}"
    elif [[ "$WEEKLY_PCT" =~ ^-?[0-9]+$ ]]; then
      # 옛 형식(예상 잔량 숫자, 음수 가능) — 다음 statusline 갱신 전까지만 남는다. statusline 과 같은 아이콘 규칙을 쓴다
      if [ "$WEEKLY_PCT" -le 0 ]; then PCT_PART=" ⛔${WEEKLY_PCT}%"
      elif [ "$WEEKLY_PCT" -le 10 ]; then PCT_PART=" ⚠${WEEKLY_PCT}%"
      elif [ "$WEEKLY_PCT" -le 20 ]; then PCT_PART=" ⚡${WEEKLY_PCT}%"
      else PCT_PART=" ${WEEKLY_PCT}%"; fi
    fi
  fi

  # 롤 조각(statusline.py 형식 `{project} 🎭role {단계} 👤 …`) — role_lib.read_role_raw 로 세션 롤을 읽는다. all·미지정·예외는 조각 생략
  local ROLE_PART="" ROLE_VAL=""
  local _LIBDIR="${ROLE_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}"
  if [ -n "$_SID" ] && [ -f "$_LIBDIR/role_lib.py" ] && command -v python3 >/dev/null 2>&1; then
    ROLE_VAL=$(python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import role_lib; v = role_lib.read_role_raw(sys.argv[2]) or ""; print("" if v.split(":", 1)[0].split("#", 1)[0] == "all" else v)' "$_LIBDIR" "$_SID" 2>/dev/null | head -n 1)
    # 옛 자동 번호(#1)는 표시에서 뺀다(statusline.get_session_role 과 동일)
    case "$ROLE_VAL" in *"#"[0-9]*) [[ "${ROLE_VAL#*#}" =~ ^[0-9]+$ ]] && ROLE_VAL="${ROLE_VAL%%#*}" ;; esac
    [ -n "$ROLE_VAL" ] && ROLE_PART=" 🎭${ROLE_VAL}"
  fi

  # 호스트 이모지 — statusline.py 와 같은 규칙 파일(host_label.py)을 부른다. 실패·빈 출력이면 이모지 없이 진행(차단 금지)
  # 세션 표시 이름(AI-8c 류)은 타이틀에 넣지 않는다(2026-11-06 사용자 지시). /oagent 이름은 🎭롤#이름 으로 남는다.
  local HOST_EMOJI=""
  if [ -f "$_LIBDIR/host_label.py" ] && command -v python3 >/dev/null 2>&1; then
    HOST_EMOJI=$(timeout 1 python3 -B "$_LIBDIR/host_label.py" emoji 2>/dev/null </dev/null | head -n 1)
    case "$HOST_EMOJI" in *[[:space:]#%]*) HOST_EMOJI="" ;; esac
  fi

  # 이모지와 프로젝트 사이는 공백 없음(🖥️AI) — wt_title_watch.project_of() 가 첫 공백 토큰을 프로젝트 키로 쓴다
  local TITLE="${HOST_EMOJI}${PROJECT}${ROLE_PART}${PCT_PART} ${STATE_EMOJI} ${STATE_LOWER} 👤 ${ID_PART}"
  # rename-window 이름은 tmux 형식 문자열로 확장되므로 에이전트명(front#이름)의 '#' 은 '##' 로 이스케이프한다
  TITLE="${TITLE//#/##}"

  # tmux rename-window: 동기 실행 — race condition 방지
  # (백그라운드 & 제거: hook 호출 순서 보장 위해 동기 필수)
  tmux rename-window -t "$TMUX_PANE" "$TITLE" >/dev/null 2>&1
  return 0
}
