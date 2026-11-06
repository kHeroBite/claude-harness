#!/bin/bash
# 팀원 spawn(Agent) 프롬프트 선두 헤더 뒤에 SendMessage 지연 로드(ToolSearch) 선행 지시를 자동 주입하는 PreToolUse hook
# [2026-10-06 C172 역라우팅 #1 보완] 실패한 SendMessage(입력 검증 거부)에서는 PreToolUse·PostToolUseFailure 가
#   모두 미발동하므로 도구 호출 단계 교정이 불가하다. 대신 spawn 시점에 프롬프트로 선행 지시를 주입한다.
# 대상(모두 충족): tool_name=Agent, tool_input.name·team_name 비어있지 않음,
#   prompt 선두 두 줄이 PIPELINE_UUID= / CLAUDE_CONFIG_DIR= (순서 무관, \r 무시 비교).
# 삽입: 선두 두 줄 ★뒤★(3·4·5번째 줄)에 고유 마커 포함 3줄(5번째 줄은 GUARD_NO_BYPASS 우회 금지 지시). 첫 두 줄 원문은 바이트 불변(CRLF 프롬프트면 주입 줄도 \r 부착).
# 출력: hookSpecificOutput.updatedInput = tool_input 전체 복사 후 prompt 만 교체. permissionDecision 은 넣지 않는다
#   (allow 가 다른 가드/권한 확인을 우회할 위험).
# [description 보정] Agent 의 description 도 lib/ambiguous_width.py 로 보정하며 prompt 주입 조건과 독립이다. 둘 다 바뀌면 한 객체에 함께 담는다.
# [INFRA_INJECT] 입력 .cwd 기준 프로젝트 INFRA.md(lib/infra_path.sh 의 infra_md_path)가 있으면 인프라 정본 안내 1줄(L4)을 더한다.
#   멱등은 [INFRA_INJECT] 존재 여부로 기존 마커와 독립 판정 — 기존 3줄이 없으면 3줄 뒤에, 이미 있으면 선두 헤더 뒤
#   연속 '#' 주석 줄 블록 끝에 L4 만 단독 삽입. INFRA.md 가 없거나 해석 실패면 L4 없음(기존 동작 그대로).
# 멱등: prompt 에 두 마커가 이미 있으면 무출력. jq 부재/파싱 실패/조건 불충족은 전부 무출력 exit 0(fail-open).
trap 'exit 0' ERR
set -u
command -v jq >/dev/null 2>&1 || exit 0
INPUT=$(timeout 5 cat 2>/dev/null) || exit 0
[ -n "$INPUT" ] || exit 0

MARKER='[SENDMESSAGE_TOOLSEARCH_INJECT]'
IMARKER='[INFRA_INJECT]'
L1="# ${MARKER} SendMessage 는 지연 로드 도구다. 첫 사용 전 ToolSearch(query='select:SendMessage') 로 스키마를 로드하라."
L2='# shutdown_request 응답은 message 를 객체 {"type":"shutdown_response","request_id":"<받은 id>","approve":true} 로 보내라(문자열 JSON 금지).'
L3='# [GUARD_NO_BYPASS] 가드·time_budget 차단/보류 시 표현 바꾸기·다른 도구 전환으로 우회 금지 — 같은 도구 재시도 또는 SendMessage 로 team-lead 보고 후 대기(L-597)'

# L4: Agent 호출일 때만 .cwd 로 INFRA.md 해석 (실패는 L4 생략, deny 금지)
L4=''
CWD=$(printf '%s' "$INPUT" | jq -r 'select(type == "object" and .tool_name == "Agent") | .cwd // empty | select(type == "string")' 2>/dev/null) || CWD=''
IPLIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/lib/infra_path.sh"
if [ -n "$CWD" ] && [ -f "$IPLIB" ]; then
  # shellcheck source=lib/infra_path.sh
  . "$IPLIB" 2>/dev/null || true
  INFRA=$(infra_md_path "$CWD" 2>/dev/null) || INFRA=''
  if [ -n "$INFRA" ]; then
    IROOT=$(dirname "$INFRA")
    L4="# ${IMARKER} 프로젝트 인프라 정본: ${INFRA} — 빌드·배포·시험·접속 정보는 여기서 찾는다(목차를 Grep 한 뒤 필요한 절만 읽고 전체 읽기 금지). 문서 지도: ${IROOT}/.claude/rules/docs-map.md"
  fi
fi

# L5 [WT_INJECT]: 호출 세션(입력 .session_id)의 worktree 가 있으면 작업 폴더 안내 1줄. 입력 cwd 가 linked worktree 면 그 루트,
#   아니면 session-env/<sid>/worktrees.json 기록(wt_lib.session_worktree). 없거나 wt_lib·python3 부재/실패면 L5 생략(기존 동작 그대로).
WMARKER='[WT_INJECT]'
L5=''
SIDIN=$(printf '%s' "$INPUT" | jq -r 'select(type == "object" and .tool_name == "Agent") | .session_id // empty | select(type == "string")' 2>/dev/null) || SIDIN=''
WTLIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/lib"
if [ -n "$CWD" ] && [ -f "$WTLIBDIR/wt_lib.py" ] && command -v python3 >/dev/null 2>&1; then
  WTP=$(timeout 5 python3 -I -c 'import sys
sys.path.insert(0, sys.argv[1])
import wt_lib as w
c = sys.argv[3]
print((w.toplevel(c) if w.is_linked(c) else w.session_worktree(w.sid_of(sys.argv[2]), w.common_dir(c))) or "")' "$WTLIBDIR" "$SIDIN" "$CWD" 2>/dev/null) || WTP=''
  case "$WTP" in
    /*) [ "$(printf '%s' "$INPUT" | jq -r '.tool_input.isolation // empty' 2>/dev/null)" = "worktree" ] || L5="# ${WMARKER} 작업 폴더: ${WTP} — 저장소 파일은 이 폴더 기준 절대경로로 읽고 쓴다. bash_exec 는 working_dir 를 이 폴더로" ;;
  esac
fi

OUT=$(printf '%s' "$INPUT" | jq -c --arg m "$MARKER" --arg im "$IMARKER" --arg wm "$WMARKER" --arg l1 "$L1" --arg l2 "$L2" --arg l3 "$L3" --arg l4 "$L4" --arg l5 "$L5" '
  select(type == "object" and .tool_name == "Agent" and (.tool_input | type) == "object")
  | .tool_input as $ti
  | select(($ti.name | type) == "string" and $ti.name != "")
  | select(($ti.team_name | type) == "string" and $ti.team_name != "")
  | select(($ti.prompt | type) == "string" and $ti.prompt != "")
  | (($ti.prompt | contains($m)) | not) as $need3
  | ($l4 != "" and (($ti.prompt | contains($im)) | not)) as $need4
  | ($l5 != "" and (($ti.prompt | contains($wm)) | not)) as $need5
  | select($need3 or $need4 or $need5)
  | ($ti.prompt | split("\n")) as $ls
  | select(($ls | length) >= 2)
  | ([$ls[0], $ls[1]] | map(rtrimstr("\r"))) as $h
  | select(
      (($h[0] | startswith("PIPELINE_UUID=")) and ($h[1] | startswith("CLAUDE_CONFIG_DIR=")))
      or (($h[0] | startswith("CLAUDE_CONFIG_DIR=")) and ($h[1] | startswith("PIPELINE_UUID=")))
    )
  | (if ($ls[0] | endswith("\r")) then "\r" else "" end) as $cr
  | ((if $need4 then [$l4 + $cr] else [] end) + (if $need5 then [$l5 + $cr] else [] end)) as $add4
  | (if $need3 then
       ($ls[0:2] + [$l1 + $cr, $l2 + $cr, $l3 + $cr] + $add4 + $ls[2:])
     else
       ($ls[2:] as $rest
        | ([range(0; ($rest | length)) | select(($rest[.] | startswith("#")) | not)] | first // ($rest | length)) as $k
        | $ls[0:(2 + $k)] + $add4 + $ls[(2 + $k):])
     end | join("\n")) as $np
  | {hookSpecificOutput: {hookEventName: "PreToolUse", updatedInput: ($ti + {prompt: $np})}}
' 2>/dev/null) || exit 0

# [description 폭 모호 기호 보정 - prompt 주입 조건과 독립]
# 일반 서브에이전트, 백그라운드 Agent(name 없음)도 대상. python3, lib 부재, 실패, 타임아웃은 이 보정만 건너뛴다(원본 통과, deny 금지).
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/lib/ambiguous_width.py"
CHANGED=false; NEWDESC=''
if command -v python3 >/dev/null 2>&1 && [ -f "$LIB" ]; then
  DESC=$(printf '%s' "$INPUT" | jq -j 'select(type == "object" and .tool_name == "Agent" and (.tool_input | type) == "object")
    | .tool_input.description | select(type == "string" and . != "" and (contains("\u0000") | not))' 2>/dev/null; printf x) || DESC=''
  DESC="${DESC%x}"
  if [ -n "$DESC" ]; then
    NEWDESC=$(printf '%s' "$DESC" | timeout 5 python3 -I "$LIB" 2>/dev/null; [ "${PIPESTATUS[1]}" -eq 0 ] && printf x) || NEWDESC=''
    case "$NEWDESC" in
      *x) NEWDESC="${NEWDESC%x}"; [ -n "$NEWDESC" ] && [ "$NEWDESC" != "$DESC" ] && CHANGED=true ;;
    esac
  fi
fi

[ -n "$OUT" ] || [ "$CHANGED" = true ] || exit 0
if [ "$CHANGED" = false ]; then printf '%s\n' "$OUT"; exit 0; fi

# 원본 tool_input 전체(또는 prompt 주입본)에 바뀐 description 만 덮어쓴 단일 객체를 출력한다.
FINAL=$(printf '%s' "$INPUT" | jq -c --argjson prev "${OUT:-null}" --arg d "$NEWDESC" '
  select(type == "object" and .tool_name == "Agent" and (.tool_input | type) == "object")
  | (if $prev then $prev.hookSpecificOutput.updatedInput else .tool_input end) as $u
  | {hookSpecificOutput: {hookEventName: "PreToolUse", updatedInput: ($u + {description: $d})}}
' 2>/dev/null) || FINAL=''
if [ -n "$FINAL" ]; then printf '%s\n' "$FINAL"; elif [ -n "$OUT" ]; then printf '%s\n' "$OUT"; fi
exit 0
