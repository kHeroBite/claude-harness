#!/bin/bash
# 파이프라인 완료 ntfy 알림을 페이로드 파일 또는 odone 로그·HEAD 로 만들어 발송하는 단일 스크립트
#
# 사용법:
#   bash ntfy_send.sh --session-dir <SD> [--project-dir <dir>] [--session-id <UUID>] [--dry-run]
#
# 페이로드:
#   1) <SD>/ntfy_payload.json 이 유효 JSON 이면 그대로 쓴다.
#   2) 없거나 깨졌으면 다시 만든다. 메시지는 <SD>/logs/odone_<conv_id>.md(없으면 최신 odone_*.md)의
#      "## ntfy 페이로드" 절 첫 비어 있지 않은 줄 → 없으면 git -C <project> log -1 --format=%s 이다.
#      title "✅", tags ["white_check_mark"]. JSON 은 jq 로 만든다(한글 안전).
#   3) 어느 경로든 제목 앞에 "[프로젝트명] " 을 붙인다(이미 있으면 생략, 이름 미산출 시 생략).
#      제목의 고정 문구는 프로젝트명 하나뿐이다. 옛 고정 제목 "✅ 작업 완료" 는 "✅" 로 줄인다.
#   4) 세션에 /oagent 이름(role `롤#이름`)이 있으면 프로젝트 태그 바로 뒤에 "🎭롤#이름" 을 붙인다
#      (예: "[NewProj] 🎭back#철수 ✅ 끝"). 제목이 이미 "[프로젝트]" 로 시작해도 태그는 한 번만 나온다.
#      이름이 없거나 못 읽으면 아무것도 붙이지 않고 그대로 발송한다(fail-open).
#      세션 ID 는 --session-id(UUID 형식일 때만 인정, 자기 세션 값만 읽음)를 우선하고,
#      없으면 --session-dir 의 이름(또는 부모 이름)에서 찾는다. --session-dir 이 임시 폴더인 호출자는
#      --session-id 로 세션을 명시해야 이름이 실린다. 인자가 없는 기존 호출은 그대로 동작한다.
# 토픽(앞에서부터 먼저 찾은 값):
#   NTFY_TOPIC 환경변수 → 페이로드 topic({ntfy_topic} 같은 자리표시자 제외)
#   → 프로젝트 루트 INFRA.md 의 INFRA-FIELDS ntfy_topic (lib/infra_path.sh 로 해석, 값 none 은 무효)
#   → 없으면 NTFY_NO_TOPIC 출력, rc=3. 토픽을 지어내지 않는다(공개 ntfy.sh 노출 위험).
# 발송:
#   curl.exe(없으면 curl) -s -X POST https://ntfy.sh -d "$json" (-d @파일 금지 — L-272).
#   성공(2xx) 시 페이로드 파일 삭제. --dry-run 은 "NTFY_DRYRUN <json>" 출력, 네트워크·삭제 없음.
# 종료 코드: 0 성공·dry-run / 1 발송 실패 / 2 사용법 오류·jq 부재 / 3 토픽 미정

SD=""; PD=""; DRY=0; SID_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --session-dir) SD="${2:-}"; shift 2 ;;
    --project-dir) PD="${2:-}"; shift 2 ;;
    --session-id) SID_ARG="${2:-}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) echo "NTFY_USAGE 알 수 없는 인자: $1" >&2; exit 2 ;;
  esac
done
if [ -z "$SD" ] || [ ! -d "$SD" ]; then
  echo "NTFY_USAGE --session-dir <존재하는 디렉터리> 가 필요하다" >&2; exit 2
fi
command -v jq >/dev/null 2>&1 || { echo "NTFY_USAGE jq 가 없다" >&2; exit 2; }
PD_ARG="$PD"  # 제목 프로젝트 태그 산출용 — 호출자가 명시한 --project-dir
if [ -z "$PD" ]; then
  PD=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
fi

PAYLOAD_FILE="$SD/ntfy_payload.json"
PAYLOAD=""
if [ -f "$PAYLOAD_FILE" ] && jq -e 'type == "object"' "$PAYLOAD_FILE" >/dev/null 2>&1; then
  PAYLOAD=$(jq -c '.' "$PAYLOAD_FILE")
  SRC="payload"
fi

# --- 페이로드 재구성 ---
_odone_msg() {
  local conv log line
  conv=""
  [ -f "$SD/conv_id" ] && conv=$(tr -d '[:space:]' <"$SD/conv_id")
  log=""
  [ -n "$conv" ] && [ -f "$SD/logs/odone_${conv}.md" ] && log="$SD/logs/odone_${conv}.md"
  if [ -z "$log" ]; then
    log=$(ls -t "$SD"/logs/odone_*.md 2>/dev/null | head -1)
  fi
  [ -n "$log" ] && [ -f "$log" ] || return 1
  # "## ntfy 페이로드" 절에서 첫 비어 있지 않은 줄(코드 울타리 제외). 다음 "## " 제목에서 멈춘다.
  line=$(awk '
    /^##[[:space:]]+ntfy[[:space:]]*페이로드/ { f=1; next }
    f && /^##[[:space:]]/ { exit }
    f && /^[[:space:]]*```/ { next }
    f && /[^[:space:]]/ { print; exit }
  ' "$log")
  [ -n "$line" ] || return 1
  # 줄이 JSON 객체이고 message 가 있으면 그 값을 쓴다
  local m
  m=$(printf '%s' "$line" | jq -r 'if type=="object" then (.message // empty) else empty end' 2>/dev/null)
  [ -n "$m" ] && line="$m"
  printf '%s' "$line"
}

if [ -z "$PAYLOAD" ]; then
  MSG=$(_odone_msg); SRC="odone_log"
  if [ -z "$MSG" ]; then
    MSG=$(git -C "$PD" log -1 --format=%s 2>/dev/null); SRC="git_head"
  fi
  if [ -z "$MSG" ]; then
    MSG="작업 완료 ($(basename "$PD"))"; SRC="fallback"
  fi
  PAYLOAD=$(jq -cn --arg m "$MSG" '{title:"✅", message:$m, tags:["white_check_mark"]}')
fi

# --- 토픽 해석 ---
_valid_topic() {  # 자리표시자·빈값·공백 포함 값 제외
  local t="$1"
  [ -n "$t" ] || return 1
  case "$t" in *"{"*|*"}"*|*" "*|"null") return 1 ;; esac
  return 0
}
TOPIC=""; TSRC=""
if _valid_topic "${NTFY_TOPIC:-}"; then
  TOPIC="$NTFY_TOPIC"; TSRC="env"
fi
if [ -z "$TOPIC" ]; then
  t=$(printf '%s' "$PAYLOAD" | jq -r '.topic // empty' 2>/dev/null)
  if _valid_topic "$t"; then TOPIC="$t"; TSRC="payload"; fi
fi
INFRA=""
INFRA_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/infra_path.sh"
if [ -z "$TOPIC" ] && [ -f "$INFRA_LIB" ]; then
  # shellcheck source=infra_path.sh
  . "$INFRA_LIB"
  INFRA=$(infra_md_path "$PD") || INFRA=""
  if [ -n "$INFRA" ]; then
    t=$(infra_field "$INFRA" ntfy_topic) || t=""
    case "$t" in none|NONE|None) t="" ;; esac  # none 은 "토픽 없음" 선언 — 지어내지 않는다
    if _valid_topic "$t"; then TOPIC="$t"; TSRC="INFRA.md"; fi
  fi
fi
if [ -z "$TOPIC" ]; then
  echo "NTFY_NO_TOPIC 토픽 미정 — 발송하지 않는다(${INFRA:-$PD/INFRA.md} 의 INFRA-FIELDS ntfy_topic 을 정의하거나 NTFY_TOPIC 지정)"
  exit 3
fi

# --- 제목 프로젝트 태그 ---
# 알림 목록에서 어느 프로젝트인지 바로 보이도록 제목 앞에 "[프로젝트명] " 을 붙인다.
# 프로젝트명: --project-dir 명시값 → CLAUDE_PROJECT_DIR → git 최상위 → cwd 의 basename.
# 이미 같은 태그로 시작하면 다시 붙이지 않는다. 이름을 못 구하면 태그 없이 기존대로 보낸다.
TAG_DIR="$PD_ARG"
[ -n "$TAG_DIR" ] || TAG_DIR="${CLAUDE_PROJECT_DIR:-}"
[ -n "$TAG_DIR" ] || TAG_DIR=$(git rev-parse --show-toplevel 2>/dev/null)
[ -n "$TAG_DIR" ] || TAG_DIR=$(pwd 2>/dev/null)
PROJ_TAG=""
[ -n "$TAG_DIR" ] && PROJ_TAG=$(basename "${TAG_DIR%/}" 2>/dev/null)
case "$PROJ_TAG" in ""|"/"|".") PROJ_TAG="" ;; esac

# --- 에이전트명 ---
# /oagent 이름이 있는 세션(role 값 `롤#이름`, 창 제목·statusline 과 같은 role_lib.read_role_raw 출처)이면
# 제목의 프로젝트 태그 뒤에 "🎭롤#이름" 을 붙인다. 이름이 없거나 읽기에 실패하면 아무것도 붙이지 않는다(fail-open).
# 세션 ID 는 --session-dir 의 이름이며, <세션>/ask_notify 같은 하위 디렉터리면 부모 이름도 시도한다.
AGENT_TAG=""
_ROLE_LIBDIR="${ROLE_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)}"
if [ -f "$_ROLE_LIBDIR/role_lib.py" ] && command -v python3 >/dev/null 2>&1; then
  _SID_UUID=""
  case "$SID_ARG" in
    [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) _SID_UUID="$SID_ARG" ;;
  esac
  for _sid in "$_SID_UUID" "$(basename "${SD%/}")" "$(basename "$(dirname "${SD%/}")")"; do
    case "$_sid" in ""|*[!A-Za-z0-9_-]*) continue ;; esac
    _rv=$(timeout 5 python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import role_lib; print(role_lib.read_role_raw(sys.argv[2]) or "")' "$_ROLE_LIBDIR" "$_sid" 2>/dev/null | head -n 1)
    _rv=$(printf '%s' "$_rv" | tr -d '[:cntrl:]"\\')   # 제어문자·따옴표·역슬래시 제거(role_lib 이 이미 거르지만 이중 방어)
    case "$_rv" in ?*"#"?*) AGENT_TAG="$_rv"; break ;; esac   # 이름(#뒤)이 있을 때만
  done
fi

JSON=$(printf '%s' "$PAYLOAD" | jq -c --arg t "$TOPIC" --arg p "$PROJ_TAG" --arg a "$AGENT_TAG" '.topic = $t
  | (if (.title // "") == "" or .title == "✅ 작업 완료" then .title = "✅" else . end)
  | (if (.message // "") == "" then .message = "작업 완료" else . end)
  | (if $a != "" and ((.title | tostring) | contains($a) | not)
       then .title = (if $p != "" then "[" + $p + "] " else "" end) + "🎭" + $a + " "
            + ((.title | tostring) | if $p != "" and startswith("[" + $p + "] ") then .[($p | length) + 3:] else . end)
       else . end)
  | (if $p != "" and ((.title | tostring) | startswith("[" + $p + "]") | not)
       then .title = "[" + $p + "] " + (.title | tostring) else . end)')

if [ "$DRY" = 1 ]; then
  echo "NTFY_DRYRUN $JSON"
  echo "NTFY_SOURCE payload=$SRC topic=$TSRC"
  exit 0
fi

CURL=/mnt/c/Windows/System32/curl.exe
[ -x "$CURL" ] || CURL=$(command -v curl 2>/dev/null)
[ -n "$CURL" ] || { echo "NTFY_SEND_FAIL curl 없음"; exit 1; }
CODE=$("$CURL" -s -o /dev/null -w '%{http_code}' --max-time 20 -X POST https://ntfy.sh \
  -d "$JSON" -H "Content-Type: application/json" 2>/dev/null | tr -d '\r[:space:]')
case "$CODE" in
  2??)
    rm -f "$PAYLOAD_FILE"
    echo "✅ ntfy 발송 완료 topic=$TOPIC"
    exit 0 ;;
  *)
    echo "NTFY_SEND_FAIL http=${CODE:-없음} topic=$TOPIC — 페이로드 파일 보존"
    exit 1 ;;
esac
