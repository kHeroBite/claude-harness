#!/bin/bash
# 재기동 복원용 에이전트 상태 스냅샷 async hook — IDLE·스로틀은 셸에서 즉시 끝내고 기록은 lib/agent_snapshot.py 에 맡긴다
#
# 등록(settings.json, 전부 "async": true): PostToolUse matcher "*", UserPromptSubmit, Stop, TeammateIdle
# 계약: plans/oplan_conv_179163042411_s10D.md §3-3·3-4
#   - 자기 세션 state 가 없거나 IDLE 이면 python 을 띄우지 않고 종료한다(IDLE 세션 무비용).
#   - 일반 도구 호출은 대상 스냅샷 mtime 이 15초 이내면 종료한다(AS_THROTTLE_SEC 로 시험 조정).
#     중요 이벤트(Agent·SendMessage·TodoWrite·TaskCreate·TaskUpdate, 그리고 PostToolUse 가 아닌 모든 이벤트)는 항상 기록한다.
#   - 신원(팀원/메인/서브에이전트) 증명·부하 축약(lite)·원자 기록은 코어가 한다. 증명 실패면 쓰지 않는다.
#   - 모든 실패는 무출력 rc=0 (async 라 도구 호출을 막지 않는다).
# 세션 격리: 쓰기 경로는 $HOME/.claude/session-env/<자기 pipeline_uuid>/agent_state 하위뿐이다.

trap 'exit 0' ERR

# 내장 read 로 stdin 전체를 읽는다(timeout·cat 두 번의 fork 를 없애 스로틀 경로를 짧게 한다)
INPUT=""
IFS= read -r -d '' -t 3 INPUT || true   # EOF 에서 rc=1 이 정상이다(ERR trap 회피)
[[ -n "$INPUT" ]] || exit 0

re_sid='"session_id"[[:space:]]*:[[:space:]]*"([0-9a-f-]{36})"'
[[ $INPUT =~ $re_sid ]] || exit 0
SID=${BASH_REMATCH[1]}

re_ev='"hook_event_name"[[:space:]]*:[[:space:]]*"([A-Za-z]+)"'
EV=""
[[ $INPUT =~ $re_ev ]] && EV=${BASH_REMATCH[1]}

# 소속 파이프라인 UUID 힌트: 팀원 프로세스 환경에는 PIPELINE_UUID 가 없다(2026-10-11 실측 /proc/<pid>/environ).
# 그래서 조상 argv 의 --parent-session-id 값을 내장 명령만으로(fork 없이) 찾는다. 증명은 코어가 다시 한다.
UUID=${PIPELINE_UUID:-}
if [[ -z "$UUID" ]]; then
  PR=${AS_PROC_ROOT:-/proc}
  p=${AS_START_PID:-$PPID}
  for _ in 1 2 3 4 5 6 7 8; do
    [[ "$p" =~ ^[0-9]+$ ]] && (( p > 1 )) || break
    mapfile -d '' -t ARGV 2>/dev/null < "$PR/$p/cmdline" || break
    for (( i = 0; i + 1 < ${#ARGV[@]}; i++ )); do
      [[ "${ARGV[i]}" == "--parent-session-id" ]] && { UUID=${ARGV[i+1]}; break 2; }
    done
    read -r STAT 2>/dev/null < "$PR/$p/stat" || break
    STAT=${STAT##*) }
    read -r _S p _R <<< "$STAT" || break
  done
  UUID=${UUID:-$SID}
fi
[[ $UUID =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || exit 0
SD="$HOME/.claude/session-env/$UUID"
[[ -r "$SD/state" ]] || exit 0
read -r ST _ < "$SD/state" 2>/dev/null || true
[[ -n "$ST" && "$ST" != "IDLE" ]] || exit 0

IMPORTANT=1
if [[ "$EV" == "PostToolUse" ]]; then
  re_tool='"tool_name"[[:space:]]*:[[:space:]]*"([A-Za-z0-9_]+)"'
  TOOL=""
  [[ $INPUT =~ $re_tool ]] && TOOL=${BASH_REMATCH[1]}
  case "$TOOL" in
    Agent|SendMessage|TodoWrite|TaskCreate|TaskUpdate) IMPORTANT=1 ;;
    *) IMPORTANT=0 ;;
  esac
fi

if (( IMPORTANT == 0 )); then
  # 스로틀 대상 파일: 서브에이전트 → sub_<id>.json, 그 외 → 신원 캐시가 가리키는 이름
  TARGET=""
  re_aid='"agent_id"[[:space:]]*:[[:space:]]*"([A-Za-z0-9_.-]{1,80})"'
  if [[ $INPUT =~ $re_aid ]]; then
    TARGET="sub_${BASH_REMATCH[1]}"
  elif [[ -r "$SD/agent_state/.id_$SID" ]]; then
    read -r _K NAME _R < "$SD/agent_state/.id_$SID" 2>/dev/null || true
    [[ "$NAME" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$ ]] && TARGET="$NAME"
  fi
  if [[ -n "$TARGET" && -f "$SD/agent_state/$TARGET.json" ]]; then
    printf -v NOW '%(%s)T' -1
    MT=$(stat -c %Y "$SD/agent_state/$TARGET.json" 2>/dev/null) || MT=0
    (( NOW - MT < ${AS_THROTTLE_SEC:-15} )) && exit 0
  fi
fi

LIB="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/agent_snapshot.py"
[[ -f "$LIB" ]] || exit 0
printf '%s' "$INPUT" | python3 "$LIB" >/dev/null 2>&1
exit 0
