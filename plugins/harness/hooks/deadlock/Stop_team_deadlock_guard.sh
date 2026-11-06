#!/bin/bash
# 파이프라인 진행 중(PLAN/DEV/TEST/DONE) 활성 팀원이 0명인데 메인이 턴을 끝내려 하면 막는 교착 방지 Stop hook
#
# 배경(2026-10-14 사이클182, 메인 트랜스크립트 66545~66571 실측): otest-m-1 이 08:04:43 "완료 신호를 기다린다"며 유휴에 들어갔고,
#   메인은 08:04:45 "진행 중"으로 읽고 턴을 끝냈다(66547 stop_hook_summary — Stop 7개 모두 통과). 팀원 전원 유휴 + 메인 유휴라
#   깨울 사건이 없어 09:26 사용자 질문까지 81분 정체. PreToolUse_teammate_idle_guard 는 메인이 도구를 부를 때만 돌아 이 공백을 못 본다.
# 판정(위에서부터, 해당하면 무출력 exit 0 = 통과):
#   P1 jq·python3 부재 / 빈 입력 / session_id 형식 불량
#   P2 팀원 프로세스(agent_id 존재 또는 PIPELINE_UUID ≠ session_id)
#   P3 state 첫 토큰 ∉ {PLAN, DEV, TEST, DONE} (IDLE·FINISH 등은 Stop_oto_residual_guard 등 다른 가드 소관 — 상태 축 배타)
#   P4 status 에 ABORT 또는 PAUSE
#   P5 team_name 없음·팀 config 없음(팀이 없으면 교착 대상 아님)
#   P6 입력 background_tasks 에 running 이 있거나 session_crons 가 비어 있지 않음(하네스가 메인을 다시 깨운다 — 공식 문서 Stop input)
#   P7 메인 자신의 inbox(teams/<팀>/inboxes/team-lead.json)에 미전달 메시지가 있음(곧 깨어난다)
#   P8 활성 팀원 ≥ 1 — 활성 = 프로세스 생존 그리고 (config isActive=true 또는 그 팀원 inbox 에 미전달 메시지)
#        프로세스 생존 = /proc/*/cmdline 에 --agent-id NAME@TEAM 과 --parent-session-id <session_id> 가 함께 있음
#        (config 의 isActive 는 죽은 옛 팀원도 true 로 남아 있어 단독으로 쓰지 않는다 — 2026-10-14 실측)
# 차단: stdout {"decision":"block","reason":"…"} + exit 0 (공식 문서 — exit 0 + JSON 구조화 제어)
# 교착 확정(사람에게 넘김): 같은 서명(state·팀원 상태)으로 stop_hook_active 연쇄 차단이 2회 쌓인 뒤 3회째는
#   조용히 통과시키지 않고 {"continue":false,"stopReason":"…"} 로 사용자 화면에 띄우고 evidence/team_deadlock_escalate.log 에 남긴다.
#   (하네스의 연속 8회 상한보다 먼저 사람이 보게 한다. 새 턴(stop_hook_active=false)이면 카운터를 1 부터 다시 센다.)
# 상태 파일: session-env/<UUID>/team_deadlock_block_count ("서명\n횟수") — 자기 세션만 쓴다(세션 격리).
# 시험 주입(시험 전용): TDG_PROCS = "NAME@TEAM <lead-uuid>" 줄 목록(설정 시 /proc 를 읽지 않는다)
# fail-open: 내부 오류는 무출력 exit 0. set -e 를 쓰지 않는다.

set -u
trap 'exit 0' ERR

command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

INPUT="$(timeout 5 cat 2>/dev/null)" || exit 0
[[ -n "$INPUT" ]] || exit 0

# 입력은 표준입력으로 넘긴다(환경변수는 last_assistant_message 가 길면 E2BIG 로 실행 자체가 실패해 조용히 통과한다).
printf '%s' "$INPUT" | TDG_HOME_BASE="${HOME}/.claude" timeout 8 python3 -I /dev/fd/3 3<<'PY' 2>/dev/null
import json, os, re, sys, time

def out(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.exit(0)

try:
    inp = json.loads(sys.stdin.read())
except ValueError:
    sys.exit(0)
if not isinstance(inp, dict):
    sys.exit(0)
uuid = str(inp.get("session_id") or "")
if not re.fullmatch(r"[0-9a-f-]{36}", uuid):
    sys.exit(0)
# P2 팀원 프로세스
if inp.get("agent_id"):
    sys.exit(0)
pu = os.environ.get("PIPELINE_UUID", "")
if pu and pu != uuid:
    sys.exit(0)

bases = []
for b in (os.environ.get("CLAUDE_CONFIG_DIR", ""), os.environ.get("TDG_HOME_BASE", "")):
    if b and os.path.isdir(os.path.join(b, "session-env", uuid)) and b not in bases:
        bases.append(b)
sd = base = None
for b in bases:
    if os.path.isfile(os.path.join(b, "session-env", uuid, "state")):
        sd, base = os.path.join(b, "session-env", uuid), b
        break
if sd is None:
    sys.exit(0)

def read(p):
    try:
        with open(p, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""

# P3 state
tok = (read(os.path.join(sd, "state")).split() or [""])[0]
if tok not in ("PLAN", "DEV", "TEST", "DONE"):
    sys.exit(0)
# P4 status
st = read(os.path.join(sd, "status"))
if "ABORT" in st or "PAUSE" in st:
    sys.exit(0)
# P5 team
team = "".join(read(os.path.join(sd, "team_name")).split())
if not team or "/" in team or team in (".", ".."):
    sys.exit(0)
try:
    cfg = json.loads(read(os.path.join(base, "teams", team, "config.json")))
except ValueError:
    sys.exit(0)
if not isinstance(cfg, dict):
    sys.exit(0)
members = [m for m in (cfg.get("members") or [])
           if isinstance(m, dict) and isinstance(m.get("name"), str) and m.get("name") != "team-lead"]

# P6 하네스가 다시 깨울 작업
bg = inp.get("background_tasks") or []
if isinstance(bg, list) and any(isinstance(t, dict) and t.get("status") == "running" for t in bg):
    sys.exit(0)
if inp.get("session_crons"):
    sys.exit(0)

def inbox_pending(name):
    try:
        d = json.loads(read(os.path.join(base, "teams", team, "inboxes", name + ".json")) or "[]")
    except ValueError:
        return False
    return isinstance(d, list) and any(isinstance(x, dict) and not x.get("read") for x in d)

# P7 메인 inbox
if inbox_pending("team-lead"):
    sys.exit(0)

# 프로세스 생존 목록(자기 세션이 띄운 팀원만)
alive = set()
procs = os.environ.get("TDG_PROCS")
if procs is not None:
    for ln in procs.splitlines():
        parts = ln.split()
        if len(parts) == 2 and parts[1] == uuid and parts[0].endswith("@" + team):
            alive.add(parts[0].rsplit("@", 1)[0])
else:
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open("/proc/%s/cmdline" % pid, "rb") as f:
                a = [x.decode("utf-8", "replace") for x in f.read().split(b"\0")]
        except OSError:
            continue
        aid = lead = None
        for i, x in enumerate(a[:-1]):
            if x == "--agent-id":
                aid = a[i + 1]
            elif x == "--parent-session-id":
                lead = a[i + 1]
        if aid and lead == uuid and aid.endswith("@" + team):
            alive.add(aid.rsplit("@", 1)[0])

rows, active = [], []
for m in members:
    n = m["name"]
    if n not in alive:
        continue
    pend = inbox_pending(n)
    working = m.get("isActive") is True
    rows.append("%s=%s%s" % (n, "작업중" if working else "대기", "+미전달" if pend else ""))
    if working or pend:
        active.append(n)

count_file = os.path.join(sd, "team_deadlock_block_count")
# P8 활성 팀원 있음 → 통과·카운터 초기화
if active:
    try:
        os.remove(count_file)
    except OSError:
        pass
    sys.exit(0)

sig = "%s|%s|%s" % (tok, team, ",".join(sorted(rows)) or "팀원0")
prior = 0
c = read(count_file).splitlines()
if inp.get("stop_hook_active") is True and len(c) >= 2 and c[0] == sig and c[1].isdigit():
    prior = int(c[1])
n = prior + 1
listing = ", ".join(sorted(rows)) if rows else "살아 있는 팀원 없음"

if n >= 3:
    ev = os.path.join(sd, "evidence")
    try:
        os.makedirs(ev, exist_ok=True)
        with open(os.path.join(ev, "team_deadlock_escalate.log"), "a", encoding="utf-8") as f:
            f.write("%s ESCALATE sig=%s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S%z"), sig))
    except OSError:
        pass
    try:
        os.remove(count_file)
    except OSError:
        pass
    out({"continue": False,
         "stopReason": "⛔ [교착 확정] 파이프라인 %s 단계인데 작업 중인 팀원이 0명이고, 메인이 2회 연속 다음 단계를 지시하지 못했습니다"
                       "(팀원: %s). 사용자 확인이 필요합니다 — '진행 상황 점검' 등으로 메인을 다시 깨워 주세요." % (tok, listing)})

try:
    with open(count_file, "w", encoding="utf-8") as f:
        f.write("%s\n%d\n" % (sig, n))
except OSError:
    pass
# 차단 = 재개 경로(리드 판단 2026-10-14): 대기 팀원 각각에게 SendMessage 를 보내게 한다. 보낸 메시지는 그 팀원 inbox 의
#   미전달 항목이 되고 팀원을 깨우므로(P8 활성), 메인이 지시를 보내면 다음 Stop 은 자연히 통과한다. 수동 해제 수단은 두지 않는다.
idle_names = sorted(m["name"] for m in members if m["name"] in alive)
if idle_names:
    todo = " ".join('SendMessage(to="%s", message="현재 상태(완료·막힘·대기 사유)를 보고하고 다음 행동을 바로 진행하라 — <다음 행동>")' % x
                    for x in idle_names)
    act = "지금 대기 팀원 %d명 각각에게 상태 보고와 다음 행동을 요구하는 SendMessage 를 보내라: %s" % (len(idle_names), todo)
else:
    act = "살아 있는 팀원이 없다 — 다음 단계를 맡을 팀원을 Agent 로 다시 띄우거나 메인이 직접 진행하라"
out({"decision": "block",
     "reason": "⛔ [교착 — 팀원 전원 대기] 파이프라인이 %s 단계인데 작업 중인 팀원이 0명이다(팀원: %s). 지금 턴을 끝내면 깨울 주체가 없어 "
               "파이프라인이 멈춘다(2026-10-14 81분 정체 사고). %s. 각 팀원의 마지막 보고와 결과물을 보고 다음 행동을 구체적으로 적어라. "
               "사용자 결정이 필요하면 AskUserQuestion, 일시정지가 맞으면 status 에 PAUSE 를 기록하라. (차단 %d/2)"
               % (tok, listing, act, n)})
PY
exit 0
