# 리드의 SendMessage/Agent 지시 하나에 서로 독립인 과업(다른 파일 묶음) 여러 건이 담긴 경우를 감지해 경고만 하는 PreToolUse 판정 코어
"""
입력: stdin = PreToolUse hook JSON (tool_name = SendMessage | Agent)
env : MTAG_SESSION_DIR(선택 — 반복 억제 기록 위치, 자기 세션만), MTAG_NOW(테스트용 epoch), MTAG_REPEAT_SEC(기본 600)
출력: stdout 에 additionalContext JSON 또는 무출력. 차단하지 않는다(오탐 위험 — 순차 의존 과업은 한 팀원이 맞다). 항상 exit 0.

사고(2026-10-10 c174): 리드가 서로 독립인 과업 2건(보안 수정 / --bg 캡처 차단)을 한 팀원에게 한 메시지로 배정했다.
  뒤늦게 분리하려 새 팀원을 띄웠지만 재배정 메시지가 늦게 도착해 두 팀원이 같은 파일을 건드릴 뻔했다.
판정:
  1. 본문을 번호 항목으로 나눈다 — 줄 머리의 "1." "2)" "(3)" "①" "과업 2" "### 2." 등.
  2. 항목마다 파일 경로 토큰(확장자 있는 경로·파일명)을 모은다.
  3. 경로가 있는 항목이 2개 이상이고, 그중 서로 파일이 겹치지 않는 쌍이 하나라도 있으면 "독립 과업 묶음" 으로 본다.
     "추가 배정 N건"(N≥2) 문구가 있으면 경로가 없어도 항목 2개 이상이면 같은 판정.
  4. 같은 수신자에게는 REPEAT 초에 1회만 알린다.
"""
import json
import os
import re
import sys
import time

NOW = int(os.environ.get("MTAG_NOW") or time.time())
REPEAT = int(os.environ.get("MTAG_REPEAT_SEC", "600") or 600)
SESSION_DIR = os.environ.get("MTAG_SESSION_DIR", "")

# 줄 머리 항목 표기: "1." "2)" "(3)" "①" "과업 2" "### 2." "【1. 보안】"(2026-10-10 실제 배정 메시지 표기) "[2]"
ITEM_RX = re.compile(r"^\s*(?:#{1,4}\s*)?(?:[-*]\s*)?[【\[]?\s*(?:(?:과업|작업|항목|건|Task|task)\s*(\d+)\s*[.):：\]】]?|\(?(\d{1,2})[.)\]】](?!\d)|([①-⑳]))\s*", re.M)
PATH_RX = re.compile(r"(?<![\w/.-])((?:[\w.\-가-힣]+/)*[\w\-가-힣]+\.(?:cs|xaml|py|sh|ps1|psm1|bat|cmd|md|json|jsonl|sql|ts|tsx|js|jsx|csproj|sln|xml|yaml|yml|toml|txt|html|css|resx|config|wxs))(?![\w])")
EXTRA_RX = re.compile(r"(?:추가\s*배정|배정|과업|작업)\s*(\d+)\s*건")


def _text(ti, tool):
    if tool == "SendMessage":
        m = ti.get("message")
        return m if isinstance(m, str) else ""
    return str(ti.get("prompt") or "")


def split_items(text):
    marks = [m for m in ITEM_RX.finditer(text)]
    items = []
    for i, m in enumerate(marks):
        end = marks[i + 1].start() if i + 1 < len(marks) else len(text)
        items.append(text[m.start():end])
    return items


def paths_of(chunk):
    out = set()
    for m in PATH_RX.finditer(chunk):
        p = m.group(1).lower()
        out.add(p.split("/")[-1])  # 같은 파일을 경로 표기만 달리 적은 경우를 하나로 본다
    return out


def judge(text):
    """(독립 항목 요약 리스트, 근거) 또는 (None, '')"""
    items = split_items(text)
    if len(items) < 2:
        return None, ""
    sets = [(it, paths_of(it)) for it in items]
    with_paths = [(it, s) for it, s in sets if s]
    disjoint = False
    for i in range(len(with_paths)):
        for j in range(i + 1, len(with_paths)):
            if not (with_paths[i][1] & with_paths[j][1]):
                disjoint = True
                break
        if disjoint:
            break
    m = EXTRA_RX.search(text)
    n_extra = int(m.group(1)) if m else 0
    if disjoint and len(with_paths) >= 2:
        summ = ["%s → %s" % (it.strip().splitlines()[0][:40], ", ".join(sorted(s)[:3])) for it, s in with_paths[:4]]
        return summ, "파일 묶음이 겹치지 않는 번호 과업 %d건" % len(with_paths)
    if n_extra >= 2 and len(items) >= 2:
        summ = [it.strip().splitlines()[0][:50] for it in items[:4]]
        return summ, "'%s' 문구 + 번호 과업 %d건" % (m.group(0), len(items))
    return None, ""


def _throttled(key):
    if not SESSION_DIR or not os.path.isdir(SESSION_DIR):
        return False
    p = os.path.join(SESSION_DIR, "logs", "multi_task_assign_guard.json")
    try:
        with open(p, encoding="utf-8") as f:
            st = json.load(f)
    except Exception:
        st = {}
    if NOW - int(st.get(key, 0) or 0) < REPEAT:
        return True
    st[key] = NOW
    try:
        os.makedirs(os.path.dirname(p), exist_ok=True)
        tmp = p + ".tmp%d" % os.getpid()
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(st, f, ensure_ascii=False)
        os.replace(tmp, p)
    except Exception:
        pass
    return False


def main():
    try:
        inp = json.loads(sys.stdin.read() or "{}")
    except Exception:
        return
    tool = inp.get("tool_name")
    if tool not in ("SendMessage", "Agent"):
        return
    ti = inp.get("tool_input") or {}
    to = str(ti.get("to") or ti.get("name") or "")
    if tool == "SendMessage" and to in ("team-lead", "main", "*", ""):
        return
    text = _text(ti, tool)
    if len(text) < 40:
        return
    summ, why = judge(text)
    if not summ:
        return
    if _throttled("%s:%s" % (tool, to)):
        return
    msg = ("⚠️ [독립 과업 묶음 감지] '%s' 에게 보내는 %s 지시 하나에 서로 독립으로 보이는 과업이 여러 건 담겨 있다(%s):\n  - %s\n"
           "서로 다른 파일을 건드리는 독립 과업은 팀원 1명에게 몰지 말고 과업마다 팀원을 따로 두고 같은 응답에서 동시에 spawn 하라"
           "(파일마다 소유자 1명 — ok_pipeline '병렬 극대화 체크리스트'). 순서 의존이 있는 과업(앞 결과를 뒤가 쓴다)이면 이 경고는 무시해도 된다(차단 아님)."
           % (to or "?", tool, why, "\n  - ".join(summ)))
    sys.stdout.write(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": msg}}, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
