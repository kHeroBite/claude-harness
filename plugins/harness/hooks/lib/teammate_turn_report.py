# 팀원 트랜스크립트에서 이번 턴의 team-lead 보고 여부(final/interim/none/unknown)를 판정하는 공용 판정기
"""
호출: python3 -I teammate_turn_report.py --transcript <path> [--keep <agent_keep 파일>] [--now <epoch>]
출력: stdout 1줄 "<kind> <turn_start> <report_at> <keep>" — 항상 exit 0 (fail-open)
  kind      : final | interim | none | unknown
  turn_start: 이번 턴 시작 항목의 epoch 초(정수, 없으면 0)
  report_at : 마지막 성공 보고 항목의 epoch 초(정수, 없으면 0)
  keep      : ok | no  (agent_keep 파일 유효 여부, --keep 생략 시 no)

판정 규칙 (계획서 conv_179142200000 §3-2):
  1. 파일 끝에서 최대 4MB 를 읽는다. 앞이 잘렸으면 첫 줄을 버리고, 개행으로 끝나지 않는 마지막 줄(기록 중)도 버린다.
  2. 턴 시작 = 사이드체인이 아닌 type=user 항목 중 content(문자열 또는 첫 text 블록)가
     "<teammate-message" 로 시작하는 항목. "TeammateIdle hook feedback:" 과 tool_result 는 턴 시작이 아니다.
     꼬리 구간을 턴 시작들로 분할하고 오래된 턴부터 state 를 이월한다(초기 state 없음). 턴 시작이 없으면 unknown.
     보고 = assistant 의 tool_use name=SendMessage, input.to=team-lead 이고 tool_result 가 실패가 아닌 것.
  3. 턴 안에 보고가 있으면 → 마지막 보고 이후 다른 tool_use 가 없고, (구조화 메시지 shutdown_response/
     plan_approval_response) 또는 (summary+message 앞 300자가 완료 어휘와 매치되고 진행 어휘와 불일치) → final,
     그 외 → interim
  4. 보고가 없고 턴 시작에 teammate_id="team-lead" 발신이 있으면(리드 발신 턴) → 기본 none.
     단 ①직전 state==final ②작업 도구 0건(PASSIVE_TOOLS 만 사용) ③team-lead 대상 SendMessage 시도 0건(실패 포함)
     ④턴 시작의 동료 발신자 중 1명 이상에게 성공 회신 — 넷 모두 만족하면 final 이월.
  5. 리드 발신이 없는 턴(동료 단독 턴) → 보고 의무를 새로 만들지 않고 state 이월.
     단 직전 final 이고 이 턴에 작업 도구를 썼으면 interim 으로 내린다.
     단 작업 도구를 썼는데 성공한 SendMessage 가 0건(리드·동료 모두)이면 none(사이클182 교착 방지 — 2026-10-14 실측).
     그래도 완료 알림이 아직 없는 하네스 백그라운드 작업이 있으면 none 으로 내리지 않는다(그 알림이 팀원을 다시 깨운다).
  6. 끝까지 state 가 없으면 unknown. 출력 turn_start 는 마지막 턴 시작 시각(게이트의 턴별 blocks 카운트 호환).
     (2~6 은 계획서 §9-5 역라우팅 #1 보완 — 동료 메시지 턴 silent 오탐 해소)
  7. keep: 파일 존재 + 공백 제거 사유 5자 이상 + mtime 이 TTL(기본 120분) 이내 → ok
     ※ KEEP_TTL·KEEP_MIN_REASON 은 lib/teammate_idle_guard.py 와 동일 값 유지(TIG_KEEP_TTL_MIN env 공유).
"""
import json
import os
import re
import sys
import time
from datetime import datetime

MAX_TAIL = 4 * 1024 * 1024
# lib/teammate_idle_guard.py 의 KEEP_TTL / KEEP_MIN_REASON 과 동일 값 유지
KEEP_TTL = int(os.environ.get("TIG_KEEP_TTL_MIN", "120")) * 60
KEEP_MIN_REASON = 5

LEAD_NAME = "team-lead"
TURN_START_PREFIX = "<teammate-message"
FINAL_TYPES = ("shutdown_response", "plan_approval_response")
FINAL_RE = re.compile(r"완료|최종|done|complete|finished|pass|fail|결과")
PROGRESS_RE = re.compile(r"진행 중|진행중|중간(?!\s*보고서)|in progress|진행 상황")  # '중간 보고서'(문서명)는 진행 신호 아님(사이클182 보완)
# [사이클182] 진행 보고 접두 — PreToolUse_SendMessage_otest.sh _mid_prefix 와 같은 규약(이름 접두는 otest 외 팀원 이름도 허용).
#   본문 또는 summary 가 '중간 보고'·'진행 보고'·'대기 —' 로 시작하면 완료 단어('완료 알림 대기' 등)가 있어도 진행 보고다.
#   실측: odone-2 "진행 보고 — LESSONS … 작성했고 … R1 이 아직 실행 중이라 완료 알림을 기다리는 중" 이 '완료' 로 final →
#   idle 가드 F(종료 판단 지연) 오탐. 접두 고정(문장 중간의 '대기 —' 는 해당 없음)이라 "odone 완료 — … 대기 — shutdown" 은 final 유지.
# [사이클182 반복1 보완] 경계 2건(otest-3 탐침): ① '진행 보고서 작성 완료' 가 접두로 잡혀 완료가 interim 으로 빠짐
#   → 접두 뒤 경계 필수 — '중간/진행 보고' 는 구분자(— – - : ：)·닫는 괄호·공백·끝, '대기' 는 구분자·닫는 괄호만('진행 보고서'·'중간 보고서'·'대기중' 제외). ② '**진행 보고** —' 가 final
#   → 앞뒤 장식(공백·* _ ` [ ] > ( ) 【 】)을 건너뛴다. SendMessage_otest _mid_prefix 와 같은 식이다.
PROGRESS_PREFIX_RE = re.compile(r"^[\s*_`\[\]>(【)】]*(?:[a-z][\w-]*\s*[:：\-—–]?\s*)?[\s*_`\[\]>(【)】]*(?:(?:중간|진행)\s*보고[*_`]*(?:[\]】)]|\s*[—–\-:：]|\s|$)|대기[*_`]*(?:[\]】)]|\s*[—–\-:：]))", re.I)
# 턴 시작 메시지의 발신자 추출 (여러 메시지가 한 user 항목에 합쳐질 수 있다)
SENDER_RE = re.compile(r'<teammate-message\b[^>]*?\bteammate_id="([^"]+)"')
# 작업으로 보지 않는 도구 (§9-5 PASSIVE) — 이 외의 tool_use 는 작업 도구다
PASSIVE_TOOLS = frozenset((
    "SendMessage", "ToolSearch", "Read", "Grep", "Glob",
    "mcp__oio__file_read", "mcp__oio__list_dir", "mcp__oio__find",
    "mcp__oio__file_info", "mcp__oio__get_cwd",
))


class 판정불가(Exception):
    """파싱 실패·구조 이상 — unknown 으로 귀결된다."""


def 꼬리_읽기(path):
    """파일 끝 최대 4MB 를 읽어 완결된 줄 목록을 돌려준다."""
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        잘림 = size > MAX_TAIL
        if 잘림:
            f.seek(size - MAX_TAIL)
        data = f.read()
    if 잘림:
        nl = data.find(b"\n")
        data = data[nl + 1:] if nl >= 0 else b""
    if data and not data.endswith(b"\n"):
        # 기록 중인 마지막 줄 보호 — 개행 이전까지만 사용
        nl = data.rfind(b"\n")
        data = data[:nl + 1] if nl >= 0 else b""
    return data.decode("utf-8", errors="replace").splitlines()


def 시각(entry):
    ts = entry.get("timestamp")
    if not isinstance(ts, str) or not ts:
        return 0
    try:
        return int(datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp())
    except ValueError:
        return 0


def 첫_텍스트(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        for b in content:
            if isinstance(b, dict):
                if b.get("type") == "text":
                    return b.get("text") or ""
                if b.get("type") == "tool_result":
                    return None
    return None


def 결과_실패(block, entry):
    """tool_result 블록이 실패를 나타내면 True."""
    if block.get("is_error") is True:
        return True
    tur = entry.get("toolUseResult")
    if isinstance(tur, dict) and tur.get("success") is False:
        return True
    c = block.get("content")
    text = c if isinstance(c, str) else json.dumps(c, ensure_ascii=False)
    return '"success":false' in text.replace(" ", "")


def 최종_보고인가(inp):
    msg = inp.get("message")
    if isinstance(msg, dict):
        return msg.get("type") in FINAL_TYPES
    summary = inp.get("summary") or ""
    body = msg if isinstance(msg, str) else ""
    if PROGRESS_PREFIX_RE.match(str(summary)) or PROGRESS_PREFIX_RE.match(body):
        return False
    text = (str(summary) + "\n" + body)[:300].lower()
    if PROGRESS_RE.search(text):
        return False
    return bool(FINAL_RE.search(text))


# 하네스가 추적하는 백그라운드 작업 — 시작(도구 결과 문구)과 완료 알림(<task-notification>)을 짝지어 아직 도는 것이 있는지 본다.
#   실측(2026-10-14 otest-m-1 4d039f08 1916·1966): "It was moved to the background as task kgjnk1m2t" → queue-operation
#   "<task-notification>\n<task-id>kgjnk1m2t</task-id>\n<status>completed</status>". setsid/nohup·oio 자체 백그라운드는 하네스가
#   깨우지 않으므로 여기서 세지 않는다(그쪽은 bg_job_guard.py 소관).
BG_START_RE = re.compile(r"moved to the background as task ([A-Za-z0-9_-]+)|running in background with ID: ([A-Za-z0-9_-]+)")
BG_DONE_RE = re.compile(r"<task-id>([A-Za-z0-9_-]+)</task-id>\s*<status>(?:completed|failed|killed|stopped|cancelled)")


def 백그라운드_진행(entries):
    시작, 완료 = set(), set()
    for e in entries:
        s = json.dumps(e, ensure_ascii=False).replace("\\n", "\n")
        for a, b in BG_START_RE.findall(s):
            시작.add(a or b)
        완료.update(BG_DONE_RE.findall(s))
    return bool(시작 - 완료)


def 판정(lines):
    entries = []
    for ln in lines:
        if not ln.strip():
            continue
        try:
            d = json.loads(ln)
        except ValueError:
            raise 판정불가("깨진 줄")
        if not isinstance(d, dict):
            raise 판정불가("비객체 줄")
        entries.append(d)

    # 2. 턴 시작점 전수 탐색 → 턴 단위 분할
    starts = []  # (인덱스, 발신자 집합)
    for i, e in enumerate(entries):
        if e.get("type") != "user" or e.get("isSidechain") is True:
            continue
        m = e.get("message")
        if not isinstance(m, dict):
            continue
        t = 첫_텍스트(m.get("content"))
        if isinstance(t, str) and t.lstrip().startswith(TURN_START_PREFIX):
            starts.append((i, set(SENDER_RE.findall(t))))
    if not starts:
        return "unknown", 0, 0

    state, report_at = None, 0
    bg_running = 백그라운드_진행(entries)
    for k, (si, senders) in enumerate(starts):
        end = starts[k + 1][0] if k + 1 < len(starts) else len(entries)
        턴 = 턴_요약(entries[si + 1:end])
        if 턴["성공보고"]:
            # 3. 보고 있는 턴 — 기존 규칙
            last_seq, inp, at = 턴["성공보고"][-1]
            이후_도구 = 턴["마지막순번"] > last_seq
            state = "final" if (not 이후_도구 and 최종_보고인가(inp)) else "interim"
            report_at = at
        elif LEAD_NAME in senders:
            # 4. 리드 발신 턴 — 기본 none, 4조건 만족 시 final 이월
            동료 = senders - {LEAD_NAME}
            if (state == "final" and 턴["작업도구"] == 0 and 턴["리드시도"] == 0
                    and 동료 & 턴["성공회신대상"]):
                state = "final"
            else:
                state, report_at = "none", 0
        else:
            # 5. 동료 단독 턴 — 이월, 직전 final + 작업 도구 사용 시 interim
            # [사이클182 교착 방지] 단 작업 도구를 썼는데 이 턴에 성공한 SendMessage 가 0건(리드·동료 모두)이면 none.
            #   실측(2026-10-14 08:04): otest-m-1 이 otest-pc-1 의 W3 신호로 시작한 턴에서 작업만 하고 아무에게도 보내지 않은 채
            #   유휴에 들어갔는데, 직전 턴 보고가 이월(interim)돼 통과했다 → 짝 팀원은 신호를, 리드는 보고를 기다리며 81분 정체.
            #   짝 팀원에게 신호를 보냈거나 리드에게 보고했으면 종전대로다(보고 의무를 리드 한정으로 넓히지 않는다).
            #   [리드 판단 2026-10-14] 하네스 백그라운드 작업이 돌고 있으면(완료 알림이 이 팀원을 다시 깨운다) 보고 0건이어도 통과.
            if 턴["작업도구"] > 0 and not 턴["성공회신대상"] and not bg_running:
                state, report_at = "none", 0
            elif state == "final" and 턴["작업도구"] > 0:
                state = "interim"

    turn_start = 시각(entries[starts[-1][0]])
    if state is None:
        return "unknown", turn_start, 0
    return state, turn_start, report_at


def 턴_요약(entries):
    """한 턴(턴 시작 다음 ~ 다음 턴 시작 전)의 보고·도구 사용을 요약한다."""
    sends = []  # (순번, tool_use id, input, 시각)
    작업도구 = 0
    seq = 0
    실패 = set()
    for e in entries:
        if e.get("isSidechain") is True:
            continue
        m = e.get("message")
        if not isinstance(m, dict):
            continue
        c = m.get("content")
        if not isinstance(c, list):
            continue
        if e.get("type") == "assistant":
            for b in c:
                if not isinstance(b, dict) or b.get("type") != "tool_use":
                    continue
                seq += 1
                name = b.get("name")
                if name not in PASSIVE_TOOLS:
                    작업도구 += 1
                if name == "SendMessage":
                    inp = b.get("input") if isinstance(b.get("input"), dict) else {}
                    sends.append((seq, b.get("id"), inp, 시각(e)))
        elif e.get("type") == "user":
            for b in c:
                if isinstance(b, dict) and b.get("type") == "tool_result" and 결과_실패(b, e):
                    실패.add(b.get("tool_use_id"))
    성공 = [s for s in sends if s[1] not in 실패]
    return {
        "성공보고": [(s[0], s[2], s[3]) for s in 성공 if s[2].get("to") == LEAD_NAME],
        "리드시도": sum(1 for s in sends if s[2].get("to") == LEAD_NAME),
        "성공회신대상": {s[2].get("to") for s in 성공 if isinstance(s[2].get("to"), str)},
        "작업도구": 작업도구,
        "마지막순번": seq,
    }


def keep_판정(path, now):
    if not path:
        return "no"
    try:
        if not os.path.isfile(path):
            return "no"
        with open(path, encoding="utf-8", errors="replace") as f:
            reason = f.read()
        if len("".join(reason.split())) < KEEP_MIN_REASON:
            return "no"
        if now - os.path.getmtime(path) > KEEP_TTL:
            return "no"
        return "ok"
    except OSError:
        return "no"


def main(argv):
    transcript = keep = None
    now = time.time()
    i = 0
    while i < len(argv):
        a = argv[i]
        v = argv[i + 1] if i + 1 < len(argv) else None
        if a == "--transcript":
            transcript = v
        elif a == "--keep":
            keep = v
        elif a == "--now" and v is not None:
            now = float(v)
        i += 2
    kind, ts, ra = "unknown", 0, 0
    if transcript and os.path.isfile(transcript):
        try:
            kind, ts, ra = 판정(꼬리_읽기(transcript))
        except (판정불가, OSError, ValueError, TypeError, AttributeError):
            kind, ts, ra = "unknown", 0, 0
    return "%s %d %d %s" % (kind, ts, ra, keep_판정(keep, now))


if __name__ == "__main__":
    try:
        out = main(sys.argv[1:])
    except Exception:  # fail-open — 어떤 예외도 차단으로 이어지지 않는다
        out = "unknown 0 0 no"
    sys.stdout.write(out + "\n")
    sys.exit(0)
