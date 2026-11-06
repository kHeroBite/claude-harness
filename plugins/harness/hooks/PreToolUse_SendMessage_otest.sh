#!/bin/bash
# PreToolUse: SendMessage — otest 에이전트의 완료 보고 시 otest_done 마커 검증
# matcher: SendMessage (otest-N 에이전트만 대상)

# lib 로드
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/session_id.sh" 2>/dev/null || true

# 메시지 내용 확인 (완료/PASS 키워드 포함 시만 검증)
TOOL_INPUT=$(cat)

# 에이전트 이름 확인 (otest-N 에이전트만 적용)
# CLAUDE_AGENT_NAME 환경변수는 신뢰 불가 — stdin JSON .agent_name 직접 파싱
AGENT_NAME=$(echo "$TOOL_INPUT" | jq -r '.agent_name // empty' 2>/dev/null || echo "")

# [사이클167 C18] 프로세스 트리 조상 cmdline 에서 --agent-name / --parent-session-id 를 읽는다.
# 근거(2026-10-05 실측): 팀에이전트 claude 프로세스 cmdline = "... --agent-name odev-i1 ... --parent-session-id <메인UUID> ...".
#   hook 자식 프로세스에는 PIPELINE_UUID 환경변수가 전달되지 않는다(full_task_team_guard.sh F-B1 과 같은 원인).
_C18_TREE_AGENT=""
_C18_TREE_PARENT=""
_C18_PID=$$
_C18_DEPTH=0
while [[ $_C18_DEPTH -lt 10 && -n "$_C18_PID" && "$_C18_PID" != "0" && "$_C18_PID" != "1" ]]; do
  _C18_CMD=$(tr '\0' ' ' 2>/dev/null < "/proc/${_C18_PID}/cmdline")
  if [[ "$_C18_CMD" =~ --parent-session-id[[:space:]]+([0-9a-f-]{36}) ]]; then
    _C18_TREE_PARENT="${BASH_REMATCH[1]}"
    [[ "$_C18_CMD" =~ --agent-name[[:space:]]+([^[:space:]]+) ]] && _C18_TREE_AGENT="${BASH_REMATCH[1]}"
    break
  fi
  _C18_PID=$(sed 's/^.*) //' "/proc/${_C18_PID}/stat" 2>/dev/null | awk '{print $2}')
  [[ "$_C18_PID" =~ ^[0-9]+$ ]] || break
  _C18_DEPTH=$((_C18_DEPTH + 1))
done
# stdin 에 agent_name 이 없으면 프로세스 트리 값으로 보완(없으면 빈 값 → 아래에서 통과)
[[ -z "$AGENT_NAME" ]] && AGENT_NAME="$_C18_TREE_AGENT"

if [[ ! "$AGENT_NAME" =~ ^otest- ]]; then
  exit 0
fi
# [conv_179163042411 S5] 프로토콜 응답(구조화 message 의 type 이 아래 목록)은 완료 보고가 아니다 → 통과.
#   구 동작: dict 를 JSON 문자열로 바꿔 '완료|PASS' 를 검사 → request_id 에 PASS 가 있으면 shutdown_response 까지 차단
#   (shutdown 즉답 규칙과 충돌). type 이 목록에 없는 구조화 메시지와 일반 문자열 메시지 판정은 그대로 둔다.
_PROTO_PY='import sys,json
d=json.load(sys.stdin); ti=d.get("tool_input") or {}
m=ti.get("message", d.get("message"))
P={"shutdown_response","shutdown_request","plan_approval_response","plan_approval_request"}
print(1 if isinstance(m,dict) and m.get("type") in P else 0)'
if [[ "$(echo "$TOOL_INPUT" | python3 -c "$_PROTO_PY" 2>/dev/null)" == "1" ]]; then
  exit 0
fi
# [사이클167 C18 보완] message/summary 는 tool_input 안에 있다 — 최상위 키도 하위 호환으로 함께 본다.
_C18_FIELD_PY='import sys,json
d=json.load(sys.stdin); ti=d.get("tool_input") or {}
v=ti.get(sys.argv[1], d.get(sys.argv[1], ""))
print(v if isinstance(v,str) else json.dumps(v,ensure_ascii=False))'
MESSAGE=$(echo "$TOOL_INPUT" | python3 -c "$_C18_FIELD_PY" message 2>/dev/null || echo "")
SUMMARY=$(echo "$TOOL_INPUT" | python3 -c "$_C18_FIELD_PY" summary 2>/dev/null || echo "")

# [2026-10-11 oi-fix-5] 대기·조건 문맥의 '완료' 는 완료 선언이 아니다 — 트리거 판정 전에 지운다.
#   실측(otest-4, 12:0x·12:14): "odev 완료 대기", "빌드 완료되면 재검증" 같은 대기 보고가 '완료' 단어 일치로 완료 보고로 오인돼
#   otest_done 미생성으로 2회 차단됐다. 지우는 것은 아래 형태뿐이다(이 문맥들은 아직 끝나지 않았다는 뜻이다).
#     미완료 · 아직/안/못 완료 · 완료(를) 대기/기다 · 완료되면/완료하면/완료되는 대로/완료되지/완료되기 전 · 완료 전/시/까지/예정/여부 · (미래·의도 표지가 붙은) 완료 후 · 완료 안 됨
#   PASS · otest…done 트리거는 그대로 둔다(접두 없는 PASS 보고는 완료 보고로 본다 — C18 보완② 규약, r3 S1c).
#   지운 뒤에도 '완료' 가 남으면(예: "검증 완료. 다음 지시 대기") 기존대로 완료 보고로 판정한다.
# [conv_179168980000 항목6] '완료 후' 는 일괄로 지우지 않고 같은 절의 시제·의도로 가른다.
#   구 동작: '완료 후' 를 무조건 지움 → "검증 완료 후 다음 단계 대기" 의 완료 선언까지 사라져 PASS 단어가 없으면 판정에서 빠졌다.
#   규칙: '완료 후' 뒤 같은 절(다음 . ! ? 줄바꿈 — , 전까지)에 미래·의도 표지
#         (겠 · 예정 · 할 것 · 하려 · 착수 · 재측정 · 재검증 · 재확인 · 재시험 · 재실행)가 있을 때만 대기 문맥으로 지운다.
#   예: "odev 완료 후 재검증하겠습니다" · "빌드 완료 후 재측정 예정" → 지움(대기)
#       "검증 완료 후 다음 단계 대기" · "검증 완료 후 보고" → 남김(완료 선언 → 마커 검사)
#   행위자 단어(odev·빌드 …) 목록 판정은 쓰지 않는다(단어 판정 재발 방지 — L-579).
_WAIT_PY='import sys,re
t=sys.stdin.read()
t=re.sub(r"미완료|(?:아직|안|못)\s*완료|완료\s*(?:를|을|가|이)?\s*(?:대기|기다)|완료\s*(?:되|하|돼)(?:면|는\s*대로|지|기\s*전)|완료\s*(?:전|시|까지|예정|여부)(?![가-힣])|완료\s*후(?![가-힣])(?=[^.!?\n—,]*?(?:겠|예정|할\s*것|하려|착수|재측정|재검증|재확인|재시험|재실행))|완료\s*(?:안|못)\s*(?:됨|됐|되|했|함)"," ",t)
sys.stdout.write(t)'
MESSAGE_TRIG=$(printf '%s' "$MESSAGE" | python3 -c "$_WAIT_PY" 2>/dev/null) || MESSAGE_TRIG="$MESSAGE"

# 완료 보고가 아니면 통과
if ! echo "$MESSAGE_TRIG" | grep -qiE "(완료|PASS|otest.*done|검증.*완료)"; then
  exit 0
fi
# 차단 시 판정 근거로 보여 줄 트리거 단어
_TRIG_WORD=$(echo "$MESSAGE_TRIG" | grep -oiE "(otest[^[:space:]]*done|완료|PASS)" | head -1)
_TRIG_WORD="${_TRIG_WORD//[\"\\]/}"
_WHY="완료 보고로 판정한 근거: 본문의 '${_TRIG_WORD}'. 완료 보고가 아니면 본문이나 summary 를 '중간 보고' · '진행 보고' · '대기 —' 중 하나로 시작하라(앞에 otest-N 이름은 붙여도 된다). 대기·조건 문맥의 '완료'(완료 대기·완료되면 등)는 판정에서 제외된다. 마커는 검증이 끝난 뒤에만 쓴다."

# [사이클167 C18 보완②] 중간 보고 예외 — 본문 또는 summary 가 진행 보고 접두로 시작하면 통과.
#   항목별 PASS 를 담은 중간 보고까지 완료 보고로 막히던 문제(otest-2 실사용 관찰).
#   단 'otest…done'(마커를 썼다는 주장) 문구가 있으면 예외 없이 마커를 검사한다.
# [사이클182] 접두를 넓혔다 — '중간 보고' 외에 '진행 보고' · '대기 —'(TeammateIdle_report_guard 가 권하는 형식),
#   앞의 '[' · 'otest-N' 이름도 허용한다. 실측: otest-1 이 idle 가드 요구로 "otest-1 진행 보고입니다 … 17건이 PASS …
#   대기 — gate 완료 알림 대기 중" 을 보냈다가 완료 보고로 판정·차단돼, 보고를 요구하는 가드와 막는 가드가 맞물렸다(06:46:44).
#   이 예외는 종전 '중간 보고' 예외와 같은 신뢰 수준이다(완료 판정의 최종 근거는 evidence 마커·DONE 게이트다).
# [사이클182 반복1 보완] 접두 뒤 구분자 필수('진행 보고서'·'중간 보고서'·'대기중' 제외)·앞뒤 장식(** _ ` [ > 등) 허용·
#   이름 접두는 otest-N 외 팀원 이름도 허용 — lib/teammate_turn_report.py PROGRESS_PREFIX_RE 와 같은 식(규칙 통일).
_mid_prefix() {  # $1=문자열 → 0=진행 보고 접두
  printf '%s' "$1" | python3 -c 'import sys,re
t=sys.stdin.read().lstrip()
p=r"^[\s*_`\[\]>(【)】]*(?:[a-z][\w-]*\s*[:：\-—–]?\s*)?[\s*_`\[\]>(【)】]*(?:(?:중간|진행)\s*보고[*_`]*(?:[\]】)]|\s*[—–\-:：]|\s|$)|대기[*_`]*(?:[\]】)]|\s*[—–\-:：]))"
sys.exit(0 if re.match(p,t,re.I) else 1)' 2>/dev/null
}
_C18_MID=0
_mid_prefix "$MESSAGE" && _C18_MID=1
_mid_prefix "$SUMMARY" && _C18_MID=1
# [사이클196 oi-fix-1 (c)] 진행 보고 예외를 끄는 조건을 "otest…done 단어 존재" 에서 "마커를 썼다는 긍정 주장" 으로 좁혔다.
#   실측(10-23 otest-1): "대기 — otest_done 기록 대기 …" 처럼 마커를 ★아직 안 썼다★ 는 진행 보고가 단어 일치로 3회 차단됐다.
#   긍정 주장 판정(_smo_claim)은 아래 마커 검사의 "썼다 주장" 판정과 같은 함수다(규칙 하나).
_SMO_CLAIM_PY='import re,sys
t=sys.stdin.read()
for m in re.finditer(r"otest_done[_a-z]*\s*(?:마커)?\s*(?:를|을|은|는)?\s*(?:작성|생성|기록|write|wrote|written|created)", t, re.I):
    tail=t[m.end():m.end()+10]
    if re.match(r"\s*(?:을|를|이|가)?\s*(?:대기|보류|예정|전(?![가-힣])|못|안(?:\s|됨|했)|불가|차단|하지|되지|않|중(?![가-힣])|여부|필요|해야)", tail):
        continue
    print(1); sys.exit()
print(0)'
_smo_claim() { [[ "$(printf '%s\n%s' "$MESSAGE" "$SUMMARY" | python3 -c "$_SMO_CLAIM_PY" 2>/dev/null)" == "1" ]]; }
if [[ $_C18_MID -eq 1 ]] && ! _smo_claim; then
  exit 0
fi

# [실패 보고 예외] 본문/summary 에 실패 신호(FAIL·실패·불합격·RETEST·재테스트·재검증 요청·역라우팅)가 있으면
#   완료 주장이 아니라 실패 보고다 → 마커 없이 통과. PASS 와 섞여 있어도("AC-001 PASS, AC-012 FAIL") 실패 보고로 인정.
#   단 부정형("FAIL 0건", "실패 없음", "0 FAIL", "fail=0", "무실패")은 실패 신호에서 먼저 제거한다 — 거짓 완료 우회 방지.
#   otest_done 을 썼다고 긍정 주장하면 예외 없이 마커를 검사한다("otest_done 미생성" 같은 부정 언급은 해당 없음).
#   배경: otest-6 실측 — 실패 보고 본문의 "PASS/완료" 단어 때문에 실패 보고까지 차단됐다.
_FAIL_PY='import sys,re
t=sys.stdin.read()
F=r"(?:(?<![a-z])fail(?:ed|ures?|s)?(?![a-z])|실패|불합격)"
neg=re.compile(r"(?i)(?:"+F+r"[\s:=]*(?:한|된)?\s*(?:항목|건|케이스|개|cases?|items?)?\s*(?:0(?![0-9])|없음|없다|없이|없습니다|none|zero)|(?<![0-9])0\s*(?:건|개|cases?|items?)?\s*"+F+r"|무실패|no\s+fail(?:ures?|s)?(?![a-z]))")
t=neg.sub(" ",t)
sig=re.compile(r"(?i)"+F+r"|(?<![a-z])re-?test(?![a-z])|재테스트|재검증\s*요청|역라우팅")
print(1 if sig.search(t) else 0)'
_FAIL_SIG=$(printf '%s\n%s' "$MESSAGE" "$SUMMARY" | python3 -c "$_FAIL_PY" 2>/dev/null)
if [[ "$_FAIL_SIG" == "1" ]] && ! printf '%s' "$MESSAGE" | grep -qiE "otest_done[_a-z]*[[:space:]]*(마커)?[[:space:]]*(를|을)?[[:space:]]*(작성|생성|기록|write|wrote|written|created)"; then
  exit 0
fi

# UUID 결정 [사이클167 C18 수정]
# 구 코드 `UUID=$(resolve_uuid …)` 는 버그였다 — resolve_uuid 는 stdout 출력 없이 변수만 설정하는데
# 서브셸에서 캡처해 UUID 가 항상 빈 값 → 아래 exit 0 → ★otest 완료 마커 검사가 한 번도 적용되지 않았다★.
# 우선순위: ① PIPELINE_UUID 환경변수(resolve_uuid 내부) ② 프로세스 트리 --parent-session-id(메인 UUID)
#           ③ stdin session_id(resolve_uuid 내부 — 자기 세션).  ※ ①이 있으면 ②보다 우선한다.
UUID=""
if [[ -n "${PIPELINE_UUID:-}" ]]; then
  resolve_uuid "$TOOL_INPUT" 2>/dev/null || UUID=""
elif [[ -n "$_C18_TREE_PARENT" ]]; then
  UUID="$_C18_TREE_PARENT"
else
  resolve_uuid "$TOOL_INPUT" 2>/dev/null || UUID=""
fi
if [[ -z "$UUID" ]]; then
  exit 0
fi

SESSION_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/$UUID"
# 자원 축별 완료 마커 (2026-10-04): 모바일 otest(otest-m-N)는 otest_done_m, 그 외는 otest_done.
# 축이 다른 otest 가 병렬로 돌 때 서로의 마커로 완료 보고가 통과/차단되지 않게 한다.
MARKER="otest_done"
source "$HOOK_DIR/lib/otest_axis.sh" 2>/dev/null
declare -F otest_axis_of >/dev/null 2>&1 && MARKER=$(otest_axis_marker "$(otest_axis_of "$AGENT_NAME")")
[[ -z "$MARKER" ]] && MARKER="otest_done"
OTEST_DONE="$SESSION_DIR/evidence/$MARKER"

# [사이클167 C18 보완①] 마커 신선도 — 이번 파이프라인 시작 이전에 만들어진 마커는 '없음' 으로 본다.
#   직전 사이클이 남긴 otest_done 이 그대로 통과되던 문제(otest-2 실사용 관찰: c166 잔존 마커 02:31).
#   기준 시각: ① session-env/<UUID>/pipeline_start_time(epoch) ② evidence/ok_started 의 mtime ③ 둘 다 없으면 기존 동작(존재만 검사).
# _c18_marker_ok <세션디렉토리> <마커경로> → 0=유효 · 1=없음/오래됨 (오래됨이면 _C18_STALE=1)
_C18_STALE=0
_C18_EMPTY=0
# [사이클182] 차단 사유(stdout JSON)에 판정 근거·진행 보고 접두 안내(_WHY)를 함께 싣는다.
#   실측: Claude Code 는 이 hook 의 stdout JSON reason 만 에이전트에게 보여 줬고, stderr 의 _WHY 는 전달되지 않았다(06:46:44 otest-1).
#   그래서 진행 보고 예외가 있는데도 에이전트가 그 방법을 몰라 보고를 포기했다. jq 로 만들어 따옴표·줄바꿈을 안전하게 담는다.
_block_json() {  # $1=사유 첫 부분
  jq -cn --arg r "$1
해소: ① 검증을 끝냈고 마커 담당이면 evidence/${MARKER} 를 쓴 뒤 다시 보낸다. ② 마커 담당이 아니거나 마커 쓰기가 막혔으면 본문에 '${MARKER} 미기록 — <사유>' 를 적어 다시 보낸다(이 선언이 있으면 통과, '썼다' 주장과 함께 쓰면 무효). ③ 아직 진행 중이면 '진행 보고 —' 로 시작한다.
${_WHY}" '{decision:"block", reason:$r}' 2>/dev/null \
    || printf '{"decision":"block","reason":"%s"}\n' "${1//[\"\\]/ } — 완료 보고가 아니면 '중간 보고'·'진행 보고'·'대기 —' 로 시작하라."
}
_c18_marker_ok() {
  local sd="$1" mk="$2" ref="" mt
  _C18_STALE=0
  _C18_EMPTY=0
  [[ -f "$mk" ]] || return 1
  # [conv_179163042411 a11] 빈(0바이트) 마커는 판정 결과가 없는 것이므로 무효로 본다.
  if [[ ! -s "$mk" ]]; then _C18_EMPTY=1; return 1; fi
  if [[ -f "$sd/pipeline_start_time" ]]; then
    ref=$(tr -cd '0-9' < "$sd/pipeline_start_time" 2>/dev/null)
  fi
  if [[ -z "$ref" && -f "$sd/evidence/ok_started" ]]; then
    ref=$(stat -c %Y "$sd/evidence/ok_started" 2>/dev/null)
  fi
  [[ -z "$ref" ]] && return 0
  mt=$(stat -c %Y "$mk" 2>/dev/null) || return 1
  if [[ "$mt" -lt "$ref" ]]; then _C18_STALE=1; return 1; fi
  return 0
}

# hook input session_id 기록 (메인 vs hook session_id 추적 — 2순위 사전 진단용)
_INPUT_SID=$(echo "$TOOL_INPUT" | jq -r '.session_id // empty' 2>/dev/null)
if [[ -n "$_INPUT_SID" && -d "$SESSION_DIR" ]]; then
  mkdir -p "${SESSION_DIR}/logs"
  echo "$(date '+%Y-%m-%d %H:%M:%S') [PreToolUse_SendMessage_otest] input_session_id=${_INPUT_SID} resolved_uuid=${UUID}" \
    >> "${SESSION_DIR}/logs/hook_input_session_id.log"
  # 사이클46 축① — 로그 미러
  source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/session_mirror.sh" 2>/dev/null
  declare -F _mirror_file >/dev/null 2>&1 && _mirror_file "${SESSION_DIR}/logs/hook_input_session_id.log"
fi

if ! _c18_marker_ok "$SESSION_DIR" "$OTEST_DONE"; then
  # 2차: prompt UUID 폴백 시도 (§(b) 소유권 증명 통과 시만 채택)
  SM_FALLBACK_UUID=$(resolve_uuid_from_prompt "$TOOL_INPUT")
  if [[ -n "$SM_FALLBACK_UUID" && "$SM_FALLBACK_UUID" != "$UUID" ]]; then
    SM_FALLBACK_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${SM_FALLBACK_UUID}"
    if _c18_marker_ok "$SM_FALLBACK_DIR" "${SM_FALLBACK_DIR}/evidence/${MARKER}"; then
      # 폴백 성공: SESSION_DIR 교체 + uuid_fallback.log 기록
      mkdir -p "${SM_FALLBACK_DIR}/logs"
      echo "$(date '+%Y-%m-%d %H:%M:%S') [PreToolUse_SendMessage_otest] uuid_fallback adopted=${SM_FALLBACK_UUID} input_sid=${UUID} agent=${AGENT_NAME}" \
        >> "${SM_FALLBACK_DIR}/logs/uuid_fallback.log"
      SESSION_DIR="$SM_FALLBACK_DIR"
      UUID="$SM_FALLBACK_UUID"
      OTEST_DONE="$SESSION_DIR/evidence/${MARKER}"
    fi
  fi
fi

# [사이클196 oi-fix-1 P3] 마커 미기록 "명시 선언" 출구 + 판정 기록.
#   배경(10-23 실측): otest-3 은 데스크톱 축 하위 담당이라 축 마커(otest_done)를 쓸 위치가 아니었고, 쓸 담당 otest-1 은
#   F-CRUD-1 차단으로 마커를 쓸 수 없었다. 이 hook 이 '완료/PASS' 단어만으로 마커를 요구해 결과 보고가 2회 막혔다 —
#   막힌 사실을 리드에게 알리는 유일한 경로(L-597)까지 막는 가드 직렬 교착이다. 차단 문구는 '중간 보고 접두' 만 안내했고
#   이 hook 은 차단 기록도 남기지 않았다(사후 추적 불가).
#   규칙: 본문/summary 가 축 마커 이름과 함께 "쓰지 않았다/못 썼다/막혔다" 를 ★명시★ 하면(마커 미기록 선언) 통과한다.
#     이것은 완료 주장이 아니라 "마커 없이 보고한다"는 정직한 신고다 — 완료 판정은 DONE 게이트가 evidence 마커로 한다.
#     그 밖의 마커 없는 완료성 보고는 종전대로 차단하되, 차단 문구에 해소 경로를 넣고 logs/sendmessage_otest_guard.log 에 남긴다.
#   "마커를 썼다"는 긍정 주장이 함께 있으면(모순) 선언 출구를 쓰지 않는다.
_SMO_LOG="${SESSION_DIR}/logs/sendmessage_otest_guard.log"
_smo_log() {  # $1=판정 $2=사유
  [[ -d "$SESSION_DIR" ]] || return 0
  mkdir -p "${SESSION_DIR}/logs" 2>/dev/null
  printf '%s %s agent=%s marker=%s trig=%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" "$AGENT_NAME" "$MARKER" "${_TRIG_WORD:-}" "$2" >> "$_SMO_LOG" 2>/dev/null
}
_SMO_CLAIM=0
_smo_claim && _SMO_CLAIM=1
_SMO_DECL=$(printf '%s\n%s' "$MESSAGE" "$SUMMARY" | SMO_MARKER="$MARKER" python3 -c 'import os,re,sys
t=sys.stdin.read(); mk=re.escape(os.environ.get("SMO_MARKER","otest_done"))
p=mk+r"(?![_a-z])[^\n.]{0,24}?(?:미기록|미생성|미작성|(?:못|안)\s*(?:썼|씀|쓴|씁|씀|써)|쓰지\s*(?:않|못)|(?:기록|생성|작성)(?:하지|되지)\s*(?:않|못)|(?:쓰기|기록|생성)?\s*(?:가|이)?\s*차단|담당이?\s*아니|소유자?가?\s*아니|(?:쓰기|기록|작성|생성)?\s*(?:을|를)?\s*(?:대기|보류|예정))"
print(1 if re.search(p,t,re.I) else 0)' 2>/dev/null)
if ! _c18_marker_ok "$SESSION_DIR" "$OTEST_DONE" && [[ "$_SMO_DECL" == "1" && $_SMO_CLAIM -eq 0 ]]; then
  _smo_log "ALLOW_DECLARED_NO_MARKER" "stale=${_C18_STALE} empty=${_C18_EMPTY} — 본문에 마커 미기록 선언(통과)"
  exit 0
fi

if ! _c18_marker_ok "$SESSION_DIR" "$OTEST_DONE"; then
  _smo_log "BLOCK_NO_MARKER" "stale=${_C18_STALE} empty=${_C18_EMPTY} claim=${_SMO_CLAIM} decl=${_SMO_DECL:-0}"
  if [[ $_C18_STALE -eq 1 ]]; then
    _block_json "❌ ${MARKER} 마커가 이번 파이프라인 시작 이전에 만들어졌습니다(이전 사이클 잔존). 이번 검증 결과로 evidence/${MARKER} 를 다시 쓴 뒤 완료 보고하세요 (에이전트=${AGENT_NAME})."
    echo "❌ ${MARKER} 마커가 파이프라인 시작 이전 것(잔존)이다 — ${SESSION_DIR}/evidence/${MARKER} 를 이번 검증 결과로 다시 쓴 뒤 완료 보고하라 (에이전트=${AGENT_NAME}).
${_WHY}" >&2
    exit 2
  fi
  if [[ $_C18_EMPTY -eq 1 ]]; then
    _block_json "❌ ${MARKER} 빈 마커입니다(0바이트 — 판정 결과 없음). 이번 검증 결과(PASS/FAIL 등)를 담아 evidence/${MARKER} 를 다시 쓴 뒤 완료 보고하세요 (에이전트=${AGENT_NAME})."
    echo "❌ ${MARKER} 빈 마커(0바이트) — ${SESSION_DIR}/evidence/${MARKER} 에 이번 검증 결과를 담아 다시 쓴 뒤 완료 보고하라 (에이전트=${AGENT_NAME}).
${_WHY}" >&2
    exit 2
  fi
  # 축별 마커 이름(${MARKER})을 사유에 그대로 넣는다 — 모바일 otest 가 otest_done 을 만들면 데스크톱 게이트를 오염시킨다.
  _block_json "❌ ${MARKER} 마커 미생성! SendMessage로 완료 보고 전에 evidence/${MARKER} 파일을 먼저 생성하세요 (에이전트=${AGENT_NAME} — 모바일 축 otest-m-N 은 otest_done_m, 웹 축 otest-w-N 은 otest_done_w, 그 외 otest 는 otest_done).
예(검증을 끝낸 뒤에만): mcp__oio__file_write(path=\"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/evidence/${MARKER}\", content=\"PASS <ISO8601>\", overwrite=true)"
  # [사이클167 C18] exit 2 에서는 stdout JSON 이 아니라 stderr 가 차단 사유로 전달된다 — 같은 안내를 stderr 에도 남긴다.
  echo "❌ ${MARKER} 마커 미생성 — ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/evidence/${MARKER} 를 먼저 생성한 뒤 완료 보고하라 (에이전트=${AGENT_NAME}).
${_WHY}" >&2
  exit 2
fi

exit 0
