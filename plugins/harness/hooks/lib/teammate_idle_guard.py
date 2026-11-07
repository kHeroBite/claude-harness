# 팀에이전트 유휴(완료 후 미종료)·무응답을 메인 트랜스크립트+팀 config 로 판정하는 PreToolUse 가드 코어
"""
사고(2026-10-07 c171): 완료 보고 후 할 일 없는 odev 7기가 6시간 방치, otest-m-1 이 리드 메시지에
수 시간 무응답이었는데 리드가 몰랐다. 기존 post_agent_shutdown_enforce.sh 는 ① Agent spawn 시에만
돌고(10:54~18:10 실행 0회) ② 경고를 plain stdout 으로 내서 모델에 보이지 않았다
(공식 문서: PreToolUse/PostToolUse plain stdout 은 debug log 로만 간다).

판정 근거(실측으로 존재 확인한 데이터만 사용):
  - teams/<team>/config.json members[] : 현재 살아 있는 팀원 명단 + isActive(턴 진행 중 여부) + joinedAt
  - 메인 트랜스크립트 jsonl : <teammate-message teammate_id=X> 수신 시각(idle_notification 구분),
                              assistant tool_use SendMessage(to=X) 발신 시각, shutdown_request 여부
  - session-env/${UUID}/evidence/shutdown_sent/{name} : shutdown 발송 실체 증거
규칙:
  A 유휴   : isActive=False 이고 리드의 미응답 발신이 없음 → 마지막 활동 이후 IDLE_WARN 분 경고, IDLE_BLOCK 분 차단
  B 무응답 : 리드 발신 이후 해당 팀원 수신 0건 → NORESP_WARN 분 경고, NORESP_BLOCK 분 차단
  C 무보고 : isActive=True 인데 마지막 수신 이후 SILENT_WARN 분 경과 → 경고(차단 없음)
  D 무보고 대기 : teammate_turn/<name>.json status=silent 이고 silent_since > 리드의 마지막 발신, shutdown 미발송
                 → 즉시 경고, SILENT_BLOCK 분 경과 시 차단(무보고 대기 장기화). pane 이 run 이면 생략
  E pane_dead  : 자기 팀 pane 이 죽음 — shutdown 미발송이면 즉시 차단(비정상 종료),
                 shutdown 발송 후 잔존이면 경고, DEAD_BLOCK 분 경과 시 차단.
                 살아 있는 것을 본 뒤 pane·프로세스가 모두 사라짐(shutdown 미발송) → GONE_WARN(30)분 동안 경고
  실존 판정 : tmuxPaneId 가 있는 팀원은 pane 이 목록에 있거나(죽은 pane 포함) --agent-id NAME@TEAM 프로세스가 있어야
              판정 대상이다. 둘 다 없으면 과거 인스턴스로 보고 A~F·S 전부 제외(명단은 in-memory 라 디스크 정리로는 안 지워지나 메인의 TaskStop 으로 정리할 수 있다 — plans/taskstop_probe.md 실측).
              TIG_AGENT_PROCS(공백 구분 이름) 테스트 주입. backendType=in-process 는 pane id 유무와 무관하게 E/F/keep 동기화 제외.
  F 사유 없는 완료 잔존 : @agent_state=done, agent_keep 무효, shutdown 미발송 → 즉시 경고, DONE_BLOCK 분 경과 시 차단
  keep 표시 동기화 : done+keep 유효 → @agent_state=keep / keep+keep 무효 → done (자기 팀 pane 에만, TIG_DRY_TMUX=1 은 로그만)
  P 병렬 여유(경고 전용, 2026-10-10) : keep 유효 + 사유가 대기·기다림 류(PAR_RX) + isActive=False + keep 기록 후 PAR_WARN(10)분
                 → "선행 가능한 부분 작업을 배정하라" additionalContext. 차단하지 않는다(WARN_REPEAT 로 반복 억제).
면제: session-env/${UUID}/agent_keep/{name} (내용=사유 5자 이상, mtime 기준 KEEP_TTL 분 유효) — A/B/C/F 에만 적용.
      D(무보고)·E(pane_dead)는 keep 이 있어도 판정한다(재사용 대기는 보고·생존을 전제로 한다).
자동 오탐 처리(2026-10-11, 사용자 전용 off 스위치 제거 대체):
  ① 같은 이름 재spawn — joinedAt 보다 이른 bg.json 기록(J)·silent_since(D)는 이전 인스턴스 것이라 무시
  ② J 는 리드가 alive_seen 이후 그 팀원에게 메시지를 보냈으면 warn(회신 대기). 이후 무응답은 B 가 판정
  ③ 회로 차단기 — 같은 (규칙|이름|근거시각) 키가 연속 BRK_N(30)회 block → BRK_TTL(30)분 warn + logs/idle_guard_autodowngrade.log
tmux: list-panes -a 1회 읽기(TMUX env 있을 때만, timeout 2s). 테스트는 TIG_TMUX_PANES(TSV 내용 또는 파일 경로) 주입.
      결과는 자기 팀 config members 의 tmuxPaneId 와 일치하는 행만 사용한다.
차단 중 복구 허용: 단독 tmux capture-pane/kill-pane/display(-message)/list-panes, E·D 로 차단된 팀원과 같은 역할 Agent 재spawn,
      자기 session-env 의 evidence/·plans/handoff_ 경로 file_write.
출력: stdout 에 PreToolUse hookSpecificOutput JSON (경고=additionalContext, 차단=deny)
세션 격리: 자기 UUID 의 session-env·자기 팀 config·자기 트랜스크립트만 읽는다. 소유 판정은
  ① leadSessionId==UUID → 전체 소유(기존)
  ② 불일치(재개 세션 — 런타임 ID 가 바뀜) → 래퍼가 검사한 session-env/<UUID>/team_name==TEAM 에 더해
     자기 팀 pane 프로세스(pane_pid + 자식 2단계) argv 에 --agent-id NAME@TEAM 과 --parent-session-id UUID 정확 토큰 쌍이
     있는 pane 이 1개 이상일 때만 판정한다(proven_panes). 증명 실패 → 판정 생략(무출력) + SKIP owner-unproven 로그(10분 1회).
     재개 모드의 keep 표시 동기화(tmux 쓰기)는 증명된 pane 에만 한다. 테스트 주입 TIG_OWNER_PANES('pane\\tpid' 행).
이력: 2026-10-08 D/E/F·keep 동기화·복구 허용 추가 / 2026-10-08 재개 세션 소유 판정(proven_panes) 추가 — leadSessionId 불일치로 가드 전체가 무력하던 문제
"""
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime

IDLE_WARN = int(os.environ.get("TIG_IDLE_WARN_MIN", "15")) * 60
IDLE_BLOCK = int(os.environ.get("TIG_IDLE_BLOCK_MIN", "30")) * 60
NORESP_WARN = int(os.environ.get("TIG_NORESP_WARN_MIN", "20")) * 60
NORESP_BLOCK = int(os.environ.get("TIG_NORESP_BLOCK_MIN", "60")) * 60
SILENT_WARN = int(os.environ.get("TIG_SILENT_WARN_MIN", "60")) * 60
KEEP_TTL = int(os.environ.get("TIG_KEEP_TTL_MIN", "120")) * 60
WARN_REPEAT = int(os.environ.get("TIG_WARN_REPEAT_MIN", "10")) * 60
SILENT_BLOCK = int(os.environ.get("TIG_SILENT_BLOCK_MIN", "10")) * 60
DEAD_BLOCK = int(os.environ.get("TIG_DEAD_BLOCK_MIN", "5")) * 60
DONE_BLOCK = int(os.environ.get("TIG_DONE_BLOCK_MIN", "5")) * 60
GONE_WARN = int(os.environ.get("TIG_GONE_WARN_MIN", "30")) * 60
PAR_WARN = int(os.environ.get("TIG_PAR_WARN_MIN", "10")) * 60
# 회로 차단기(2026-10-11, 사용자 전용 off 스위치 대체): 같은 (규칙|이름|근거시각) 키가 연속 BRK_N 회 block → 그 키만 BRK_TTL 동안 warn
BRK_N = int(os.environ.get("TIG_BREAKER_N", "30"))
BRK_TTL = int(os.environ.get("TIG_BREAKER_MIN", "30")) * 60
KEEP_MIN_REASON = 5
# P 병렬 여유 — keep 사유가 입력·선행 결과를 기다리는 류인지
PAR_RX = re.compile(r"대기|기다|입력\s*(?:이|을|후|오면|도착)|받으면|오면|끝나면|완료\s*후|선행|wait|pending|blocked", re.I)
# 일감 없이 재사용만 기다리는 keep(예: "재사용 대기")은 배정할 선행 작업이 없는 정상 대기다 — P 제외
PAR_EXCLUDE_RX = re.compile(r"재사용|reuse|standby", re.I)

PANE_RX = re.compile(r"^%\d+$")
NAME_RX = re.compile(r"^[A-Za-z0-9._-]+$")
ROLE_RX = re.compile(r"(-\d+)+$")  # 역할명 = 끝의 -숫자 접미를 모두 제거(odev-1 / odev-1-2 / odev-2 → odev)
# 차단 중 허용하는 단독 tmux 복구 명령(연결·치환·리디렉션·tmux 형식 내 셸 실행 #( 은 거부)
TMUX_RECOVER_RX = re.compile(r"^tmux\s+(capture-pane|kill-pane|display-message|display|list-panes)(\s|$)")
TMUX_FORBID = (";", "&", "|", "`", "$(", ">", "<", "#(", "\n", "\r")

TM_RX = re.compile(r'<teammate-message teammate_id="([^"]+)"[^>]*>(.*?)</teammate-message>', re.S)

# 차단 중에도 허용하는 도구 — shutdown 판단·keep 표기·조회·사용자 질의에 필요한 것만
ALLOW_ALWAYS = {
    "SendMessage", "ListAgents", "AskUserQuestion", "ToolSearch", "TaskStop",
    "Read", "Grep", "Glob", "mcp__oio__file_read", "mcp__oio__list_dir", "mcp__oio__find",
    "mcp__oio__get_cwd", "mcp__oio__file_info",
}
# ointaug·oi 는 CLAUDE.md 가 매 사용자 입력마다 첫 행동으로 강제하는 절차다 — 막으면 규칙끼리 충돌한다(2026-10-10 c174)
ALLOW_SKILLS = {"oinit", "ofinish", "ointaug", "oi"}
# 위 절차가 남기는 자기 세션 기록 키(session_state key / session-env 파일명)
ALLOW_STATE_KEYS = {"ointaug_done", "oi_routed"}
# 규칙별 분류 — 차단·경고 문구에서 "종료 판단 지연" 과 "결과 미회수(정체)" 를 구분해 보여 준다
RULE_KIND = {"J": "결과 미회수(정체)", "P": "병렬 여유", "B": "무응답", "C": "턴 중 무보고", "D": "무보고 대기",
             "E": "비정상 종료", "A": "종료 판단 지연", "F": "종료 판단 지연", "S": "shutdown 후 잔존"}


def _iso_to_epoch(s):
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except Exception:
        return None


def _hm(epoch):
    return time.strftime("%H:%M", time.localtime(epoch)) if epoch else "-"


def _load_json(p, default):
    try:
        with open(p, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return default


def _save_json(p, obj):
    tmp = p + ".tmp.%d" % os.getpid()
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False)
    os.replace(tmp, p)


def scan_transcript(path, st):
    """트랜스크립트를 커서 이후만 증분 파싱해 팀원별 수신/발신 시각을 갱신한다."""
    try:
        size = os.path.getsize(path)
    except OSError:
        return
    if st.get("path") != path or st.get("offset", 0) > size:
        st.clear()
        st.update({"path": path, "offset": 0, "agents": {}})
    agents = st.setdefault("agents", {})
    with open(path, "rb") as f:
        f.seek(st.get("offset", 0))
        data = f.read()
    # 마지막 개행까지만 소비(쓰는 중인 줄 보호)
    cut = data.rfind(b"\n")
    if cut < 0:
        return
    st["offset"] = st.get("offset", 0) + cut + 1
    for raw in data[:cut].split(b"\n"):
        if b"teammate-message" not in raw and b'"SendMessage"' not in raw:
            continue
        try:
            d = json.loads(raw.decode("utf-8", "replace"))
        except Exception:
            continue
        if d.get("isSidechain"):
            continue
        ts = _iso_to_epoch(d.get("timestamp", "")) or None
        if ts is None:
            continue
        t = d.get("type")
        if t == "user":
            c = (d.get("message") or {}).get("content")
            if isinstance(c, list):
                c = " ".join(x.get("text", "") for x in c if isinstance(x, dict) and x.get("type") == "text")
            for m in TM_RX.finditer(c or ""):
                name, body = m.group(1), m.group(2).strip()
                a = agents.setdefault(name, {})
                a["last_in"] = max(a.get("last_in", 0), ts)
                if '"idle_notification"' in body[:200]:
                    a["last_idle"] = max(a.get("last_idle", 0), ts)
        elif t == "assistant":
            for x in (d.get("message") or {}).get("content") or []:
                if not (isinstance(x, dict) and x.get("type") == "tool_use" and x.get("name") == "SendMessage"):
                    continue
                inp = x.get("input") or {}
                to = inp.get("to")
                if not isinstance(to, str) or not to or to in ("*", "main", "team-lead"):
                    continue
                a = agents.setdefault(to, {})
                msg = inp.get("message")
                if isinstance(msg, dict) and msg.get("type") == "shutdown_request":
                    a["shutdown_out"] = max(a.get("shutdown_out", 0), ts)
                else:
                    a["last_out"] = max(a.get("last_out", 0), ts)


def keep_status(session_dir, name, now):
    p = os.path.join(session_dir, "agent_keep", name)
    if not os.path.isfile(p):
        return None
    try:
        reason = open(p, encoding="utf-8", errors="replace").read().strip()
        age = now - os.path.getmtime(p)
    except OSError:
        return None
    if len(reason.replace(" ", "")) < KEEP_MIN_REASON:
        return "invalid"
    if age > KEEP_TTL:
        return "expired"
    return "ok"


def keep_reason(session_dir, name, now):
    """(사유 문자열, keep 기록 후 경과 초). 읽기 실패 → ("", 0)"""
    p = os.path.join(session_dir, "agent_keep", name)
    try:
        return open(p, encoding="utf-8", errors="replace").read().strip(), now - os.path.getmtime(p)
    except OSError:
        return "", 0


def _team_pane_ids(config):
    ids = set()
    for m in config.get("members", []):
        p = str(m.get("tmuxPaneId") or "")
        if m.get("backendType") == "in-process":
            p = ""
        if PANE_RX.fullmatch(p):
            ids.add(p)
    return ids


_TMUX_FAILED = False  # read_panes 가 tmux 조회에 실패(timeout·비0 종료)했는지 — E 소실 오판 방지용


def read_panes(config):
    """자기 팀 pane 상태 {pane_id: {dead, sig, status, state}} 반환. tmux 정보를 얻지 못하면 None.
    TIG_TMUX_PANES 가 설정되면(테스트) 그 값(TSV 내용 또는 파일 경로)을 쓰고 tmux 를 호출하지 않는다."""
    global _TMUX_FAILED
    _TMUX_FAILED = False
    ids = _team_pane_ids(config)
    if not ids:
        return None
    if os.environ.get("TIG_TMUX_FAIL") == "1":  # 테스트 전용: tmux 조회 실패 주입
        _TMUX_FAILED = True
        return None
    if "TIG_TMUX_PANES" in os.environ:
        raw = os.environ.get("TIG_TMUX_PANES", "")
        if raw and "\t" not in raw and os.path.isfile(raw):
            try:
                raw = open(raw, encoding="utf-8", errors="replace").read()
            except OSError:
                return None
    else:
        if not os.environ.get("TMUX"):
            return None
        try:
            r = subprocess.run(
                ["tmux", "list-panes", "-a", "-F",
                 "#{pane_id}\t#{pane_dead}\t#{pane_dead_signal}\t#{pane_dead_status}\t#{@agent_state}"],
                capture_output=True, text=True, timeout=2)
        except Exception:
            _TMUX_FAILED = True  # timeout·실행 실패 = 판정 불가(소실 아님)
            return None
        if r.returncode != 0:
            _TMUX_FAILED = True
            return None
        raw = r.stdout
    panes = {}
    for ln in raw.splitlines():
        f = ln.split("\t")
        if not f or f[0] not in ids:
            continue  # 자기 팀 pane 만
        f += [""] * (5 - len(f))
        panes[f[0]] = {"dead": f[1].strip() == "1", "sig": f[2].strip(), "status": f[3].strip(), "state": f[4].strip()}
    # 자기 팀 pane 이 하나도 안 보이면 다른 tmux 서버일 수 있다 → 정보 없음 처리(소실 오탐 방지)
    return panes or None


def _ppid_map():
    """/proc/*/stat 1회 스캔 → {ppid: [pid...]}"""
    kids = {}
    try:
        ents = os.listdir("/proc")
    except OSError:
        return kids
    for e in ents:
        if not e.isdigit():
            continue
        try:
            with open("/proc/%s/stat" % e, "rb") as f:
                s = f.read().decode("utf-8", "replace")
            ppid = int(s[s.rindex(")") + 2:].split()[1])
        except Exception:
            continue
        kids.setdefault(ppid, []).append(int(e))
    return kids


def _argv(pid):
    try:
        with open("/proc/%d/cmdline" % pid, "rb") as f:
            return [t.decode("utf-8", "replace") for t in f.read().split(b"\0")]
    except Exception:
        return []


def _has_pair(tokens, key, val):
    """토큰 배열에 정확한 인접 쌍 key,val 이 있는가(부분일치 불가)"""
    for i in range(len(tokens) - 1):
        if tokens[i] == key and tokens[i + 1] == val:
            return True
    return False


def proven_panes(config, uuid, team):
    """재개 세션 소유 증명: 자기 팀 pane 프로세스(pane_pid + 자식 2단계) argv 에
    --agent-id NAME@TEAM 과 --parent-session-id UUID 정확 토큰 쌍이 모두 있는 pane 집합.
    TIG_OWNER_PANES 가 설정되면(빈 문자열 포함, 테스트) 'pane\\tpid' 행을 쓰고 tmux 를 호출하지 않는다."""
    cands = {}
    for m in config.get("members", []):
        p = str(m.get("tmuxPaneId") or "")
        n = str(m.get("name") or "")
        if m.get("backendType") == "in-process":
            p = ""
        if PANE_RX.fullmatch(p) and NAME_RX.fullmatch(n) and n != "team-lead":
            cands[p] = n
    if not cands or not team or not uuid:
        return set()
    raw = os.environ.get("TIG_OWNER_PANES")
    if raw is None:
        if not os.environ.get("TMUX"):
            return set()
        try:
            r = subprocess.run(["tmux", "list-panes", "-a", "-F", "#{pane_id}\t#{pane_pid}"],
                               capture_output=True, text=True, timeout=2)
        except Exception:
            return set()
        if r.returncode != 0:
            return set()
        raw = r.stdout
    rows = []
    for ln in raw.splitlines():
        f = ln.split("\t")
        if len(f) >= 2 and f[0] in cands and f[1].strip().isdigit():
            rows.append((f[0], int(f[1].strip())))
    if not rows:
        return set()
    kids = _ppid_map()
    owned = set()
    for pane, pid in rows:
        pids = [pid]
        for c in kids.get(pid, []):
            pids.append(c)
            pids.extend(kids.get(c, []))
        want = "%s@%s" % (cands[pane], team)
        for p in pids:
            tok = _argv(p)
            if _has_pair(tok, "--agent-id", want) and _has_pair(tok, "--parent-session-id", uuid):
                owned.add(pane)
                break
    return owned


def alive_agent_names(team):
    """프로세스 argv 에 --agent-id NAME@TEAM 정확 토큰 쌍이 있는 NAME 집합(/proc 1회 스캔).
    TIG_AGENT_PROCS 가 설정되면(테스트, 공백 구분 이름) 그 값을 쓴다."""
    inj = os.environ.get("TIG_AGENT_PROCS")
    if inj is not None:
        return set(inj.split())
    names = set()
    suf = "@" + team
    try:
        ents = os.listdir("/proc")
    except OSError:
        return names
    for e in ents:
        if not e.isdigit():
            continue
        tok = _argv(int(e))
        for i in range(len(tok) - 1):
            if tok[i] == "--agent-id" and tok[i + 1].endswith(suf):
                n = tok[i + 1][:-len(suf)]
                if NAME_RX.fullmatch(n):
                    names.add(n)
    return names


BG_SID_RX = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
BG_LAUNCH_WINDOW = 180.0  # bg_job_guard.LAUNCH_WINDOW 와 같은 값
BG_LAUNCH_SKEW = 5.0


def _bg_env_sid(pid):
    """/proc/<pid>/environ 의 CLAUDE_CODE_SESSION_ID. 읽기 실패·값 없음 → None."""
    try:
        with open("/proc/%d/environ" % pid, "rb") as f:
            for kv in f.read().split(b"\0"):
                if kv.startswith(b"CLAUDE_CODE_SESSION_ID="):
                    v = kv[23:].decode("utf-8", "replace")
                    return v if BG_SID_RX.fullmatch(v) else None
    except Exception:
        pass
    return None


def _bg_starts(pid):
    """pid 자신과 조상(최대 10단)의 시작 epoch 목록. 읽기 실패 → None."""
    try:
        with open("/proc/stat", "rb") as f:
            boot = next(float(l.split()[1]) for l in f.read().decode().splitlines() if l.startswith("btime "))
        hz = float(os.sysconf("SC_CLK_TCK"))
        out, cur = [], int(pid)
        for _ in range(10):
            if cur <= 1:
                break
            with open("/proc/%d/stat" % cur, "rb") as f:
                st = f.read().decode("utf-8", "replace")
            rest = st[st.rindex(")") + 2:].split()
            out.append(boot + float(rest[19]) / hz)
            cur = int(rest[1])
        return out or None
    except Exception:
        return None


def _bg_owner_ok(psid, starts, sid, launched):
    """bg_job_guard._owner_ok 와 같은 규칙 — 1순위 세션 ID 대조(양쪽 다 있을 때), 2순위 착수 시각 창, 둘 다 미상 → 내 것."""
    if psid and sid:
        return psid == sid
    if starts is None or not launched:
        return True
    return any(launched - BG_LAUNCH_SKEW <= s <= launched + BG_LAUNCH_WINDOW for s in starts)


def _bg_alive(fp, sid="", launched=0.0):
    """분리 실행 지문(스크립트 경로 또는 '실행파일 인자..')이 ★그 팀원 소유로★ /proc 에 살아 있는가.
    sid = bg.json 기록의 팀원 세션 ID, launched = 착수 시각. 다른 팀원이 띄운 동명 프로세스는 제외한다
    (사이클182 반복1 — 남의 동명 작업 때문에 J 결과 미회수를 놓치던 미탐).
    TIG_BG_PROCS(줄 단위 cmdline) 테스트 주입 — 줄 앞 `@<epoch>[,…]`(자신·조상 시작 시각)·`@sid=<id>` 접두 허용."""
    sid = sid if BG_SID_RX.fullmatch(sid or "") else ""
    inj = os.environ.get("TIG_BG_PROCS")
    rows = []
    if inj is not None:
        for ln in inj.splitlines():
            toks = ln.split()
            psid, starts = None, None
            while toks and toks[0].startswith("@"):
                tag = toks.pop(0)[1:]
                if tag.startswith("sid="):
                    psid = tag[4:] or None
                    continue
                try:
                    starts = [float(x) for x in tag.split(",") if x]
                except ValueError:
                    starts = None
            if toks:
                rows.append((toks, ("inj", psid, starts)))
    else:
        try:
            for e in os.listdir("/proc"):
                if e.isdigit():
                    t = _argv(int(e))
                    if t and t != [""]:
                        rows.append((t, int(e)))
        except OSError:
            return True  # 판정 불가 → 진행 중으로 본다(J 오탐 방지)
    base = os.path.basename(fp)
    for toks, ref in rows:
        if " " in fp:
            hit = fp in " ".join(toks)
        else:
            hit = any(t == fp or t == base or t.endswith("/" + base) for t in toks[:6])
        if not hit:
            continue
        if isinstance(ref, int):
            psid = _bg_env_sid(ref)
            starts = None if (psid and sid) else _bg_starts(ref)
        else:
            _, psid, starts = ref
        if _bg_owner_ok(psid, starts, sid, launched):
            return True
    return False


def bg_unreported(session_dir, name, last_in, joined=0):
    """teammate_turn/<name>.bg.json 에서 '살아 있는 것을 본 뒤 끝났고 그 뒤 수신 0건' 인 최신 기록 (fp, alive_seen) 또는 None
    joined: 현 인스턴스의 joinedAt(초). 같은 이름 재spawn 시 그보다 이른 기록(alive_seen·launched < joined)은
    이전 인스턴스 것이라 건너뛴다(2026-10-11 — last_in 이 0 으로 초기화돼 이전 기록이 결과 미회수로 오인되던 문제)."""
    if not NAME_RX.fullmatch(name or ""):
        return None
    d = _load_json(os.path.join(session_dir, "teammate_turn", name + ".bg.json"), {})
    if not isinstance(d, dict):
        return None
    best = None
    for rec in d.values():
        if not isinstance(rec, dict):
            continue
        seen = _num(rec.get("alive_seen"))
        fp = str(rec.get("fp") or "")
        if not seen or not fp or last_in > seen:
            continue
        if joined and (seen < joined or 0 < _num(rec.get("launched")) < joined):
            continue  # 이전 인스턴스 기록
        if best is None or seen > best[1]:
            best = (fp, seen, str(rec.get("sid") or ""), _num(rec.get("launched")))
    if best and not _bg_alive(best[0], best[2], best[3]):
        return best[:2]
    return None


def load_turn(session_dir, name, team):
    """TeammateIdle_report_guard 가 기록한 teammate_turn/<name>.json (자기 팀 것만)."""
    if not NAME_RX.fullmatch(name or ""):
        return {}
    d = _load_json(os.path.join(session_dir, "teammate_turn", name + ".json"), {})
    if not isinstance(d, dict):
        return {}
    if team and d.get("team") and d.get("team") != team:
        return {}
    return d


def _num(v):
    try:
        return float(v or 0)
    except (TypeError, ValueError):
        return 0.0


def evaluate(session_dir, config, st, now, self_name=None, panes=None, syncs=None, owned=None, bmap=None):
    """팀원별 판정 결과 리스트 [(level, rule, name, text)] 반환. level: warn|block|keep
    panes: read_panes() 결과(None=tmux 정보 없음 → E/F/keep 동기화 생략)
    syncs: keep 표시 동기화 대상 [(pane_id, new_state, name)] 을 채울 리스트
    owned: 재개 세션에서 소유가 증명된 pane 집합(None=leadSessionId 일치 → 전체 소유). keep 동기화 쓰기는 이 안에서만
    bmap: {(rule, name): 근거시각} 을 채울 dict — 회로 차단기 키(규칙|이름|근거시각)용. 없는 항목은 joinedAt"""
    out = []
    if syncs is None:
        syncs = []
    if bmap is None:
        bmap = {}
    agents = st.get("agents", {})
    team = config.get("name") or ""
    seen = st.setdefault("seen_alive", {})   # 이 가드가 살아 있는 것을 본 팀원 → pane
    gone_at = st.setdefault("gone_at", {})   # 살아 있다가 사라진 것을 처음 본 시각
    alive = None                             # --agent-id 프로세스 이름 집합(필요할 때 1회 스캔)
    for m in config.get("members", []):
        name = m.get("name")
        if not name or name == "team-lead" or name == self_name or m.get("agentType") == "team-lead":
            continue
        a = agents.get(name, {})
        joined = 0
        try:
            joined = int(m.get("joinedAt", 0)) / 1000.0
        except Exception:
            pass
        last_in = a.get("last_in", 0)
        last_out = a.get("last_out", 0)
        sd_out = a.get("shutdown_out", 0)
        sd_ev = os.path.join(session_dir, "evidence", "shutdown_sent", name)
        sd_file = os.path.isfile(sd_ev)
        # 같은 이름 재spawn(joinedAt 이 더 늦음)이면 이전 개체와 주고받은 기록·shutdown 은 현 개체에 무효
        if joined:
            if sd_out and sd_out < joined:
                sd_out = 0
            if last_out and last_out < joined:
                last_out = 0
            if last_in and last_in < joined:
                last_in = 0
        if joined and sd_file:
            try:
                if os.path.getmtime(sd_ev) < joined:
                    sd_file = False
            except OSError:
                sd_file = False
        shut = (sd_file or bool(sd_out)) and sd_out >= last_out
        for _r in ("A", "B", "E", "F"):
            bmap[(_r, name)] = joined  # 규칙별 근거시각 기본값 = 현 인스턴스 joinedAt(재spawn 시 키가 바뀐다)
        if last_out:
            bmap[("B", name)] = last_out
        if sd_out:
            bmap[("E", name)] = sd_out
        pane = str(m.get("tmuxPaneId") or "")
        if m.get("backendType") == "in-process":
            pane = ""  # in-process 는 tmuxPaneId 값과 무관하게 pane 근거(E/F/keep 동기화)를 쓰지 않는다
        prow = None
        # 실존 판정(tmux 모드 팀원만): pane 이 목록에 있거나(죽은 pane 포함) --agent-id NAME@TEAM 프로세스가 살아 있어야 대상.
        # 둘 다 없으면 과거 인스턴스(명단은 in-memory 라 디스크로는 못 지우나 메인 TaskStop 으로 정리 가능) → 모든 규칙에서 제외.
        # 단 이 가드가 살아 있는 것을 본 뒤 사라진 경우만 GONE_WARN 동안 E 소실 경고(shutdown 미발송 시).
        if not PANE_RX.fullmatch(pane) and m.get("backendType") != "in-process" and m.get("isActive") is None:
            # 명단 유령(2026-10-10 c174): pane id 가 비고 backendType·isActive 도 없는 항목은 종료된 인스턴스가
            # in-memory 명단에 남은 것이다. --agent-id 프로세스가 실제로 있을 때만 판정하고, 없으면 경고 없이
            # 자기 세션 roster 정리 대상으로만 기록한다(종전에는 S 가 "프로세스/pane 실존" 이라고 거짓 경고했다).
            if alive is None:
                alive = alive_agent_names(team)
            if name not in alive:
                st.setdefault("roster_ghosts", {}).setdefault(name, now)
                out.append(("ghost", "G", name, "명단 유령(pane·프로세스 없음) — roster 정리 대상"))
                continue
        if PANE_RX.fullmatch(pane):
            if panes is not None and pane in panes:
                prow = panes[pane]
                seen[name] = pane
                gone_at.pop(name, None)
            else:
                if alive is None:
                    alive = alive_agent_names(team)
                if name in alive:
                    seen[name] = pane
                    gone_at.pop(name, None)
                elif _TMUX_FAILED:
                    continue  # tmux 조회 실패(부하 timeout 등) → 소실 판정 불가, E 건너뜀(fail-open)
                else:
                    if seen.get(name) == pane and not shut:
                        ga = gone_at.setdefault(name, now)
                        if now - ga < GONE_WARN:
                            out.append(("warn", "E", name, "pane %s 소실·프로세스 없음(shutdown 미발송, %s 부터) — 비정상 종료 의심. ok_pipeline '팀원 복구 절차' 검토 (in-process 팀원이면 pane 이 없는 것이 정상 — TaskStop 전 ListAgents 로 확인)" % (pane, _hm(ga))))
                    continue
        if prow is not None:
            # E pane_dead
            if prow["dead"]:
                why = "신호 %s/status %s" % (prow["sig"] or "-", prow["status"] or "-")
                if not shut:
                    out.append(("block", "E", name, "비정상 종료(%s, pane %s) — shutdown 없이 죽었다. ok_pipeline '팀원 복구 절차' 수행" % (why, pane)))
                else:
                    base = sd_out
                    if not base and sd_file:
                        try:
                            base = os.path.getmtime(sd_ev)
                        except OSError:
                            base = 0
                    base = base or now
                    age = now - base
                    lvl = "block" if age >= DEAD_BLOCK else "warn"
                    out.append((lvl, "E", name, "죽은 pane 정리 필요(%s, pane %s, shutdown %s 발송 후 %d분) — tmux kill-pane -t %s" % (why, pane, _hm(base), age // 60, pane)))
                continue
        if sd_file or sd_out:
            # shutdown 발송 후 명단에 30분 넘게 남아 있으면 경고만
            # 기준 시각 = 발송 시각: 트랜스크립트 발송 행(sd_out) → 없으면 증거 파일 mtime(위에서 joined 이후 것만 남김).
            # joinedAt 폴백 금지 — 발송 행이 아직 안 읽힌 순간 spawn 시각을 발송 시각으로 오표기해 spawn+30분 뒤 오경고했다(c182).
            base = sd_out
            if not base and sd_file:
                try:
                    base = os.path.getmtime(sd_ev)
                except OSError:
                    base = 0
            if base and now - base > IDLE_BLOCK and base >= last_out:
                # 생존 근거를 실제로 확인한 것만 적는다(종전 문구는 확인 없이 "실존" 이라 단정했다)
                if prow is not None:
                    basis = "pane %s 존재" % pane
                elif m.get("backendType") == "in-process":
                    basis = "in-process 명단 isActive=%s" % m.get("isActive")
                else:
                    basis = "--agent-id 프로세스 존재"
                out.append(("warn", "S", name, "shutdown_request 를 %s 에 보냈는데 %d분째 아직 살아 있다(근거: %s) — TaskStop/oinit 검토" % (_hm(base), (now - base) // 60, basis)))
            if sd_out >= last_out:
                continue
        pstate = prow["state"] if prow else ""
        # D 무보고 대기: 팀원 TeammateIdle 게이트가 silent 로 기록 + 그 이후 리드 발신 없음
        tt = load_turn(session_dir, name, team)
        if tt.get("status") == "silent" and pstate != "run":
            ss = _num(tt.get("silent_since"))
            if joined and ss and ss < joined:
                ss = 0  # 같은 이름 재spawn — 이전 인스턴스의 silent 기록은 현 인스턴스에 무효
            if ss and ss > last_out:
                bmap[("D", name)] = ss
                age = now - ss
                lvl = "block" if age >= SILENT_BLOCK else "warn"
                out.append((lvl, "D", name, "무보고 대기 %d분 — %s 이후 team-lead 보고 없이 대기 중%s" % (age // 60, _hm(ss), " (장기화)" if lvl == "block" else "")))
                continue
        # J 결과 미회수(정체): 팀원이 분리 실행한 작업이 끝났는데 그 뒤 수신 0건(TeammateIdle bg_job_guard 가 남긴 <name>.bg.json)
        jr = bg_unreported(session_dir, name, last_in, joined)
        if jr:
            fp, seen = jr
            age = now - seen
            bmap[("J", name)] = seen
            if last_out and last_out > seen:
                # 리드가 이미 결과를 요구했다(요구 행동 수행) → J 는 회신 대기 경고만. 이후 무응답은 아래 B 규칙이 이어서 판정한다
                out.append(("warn", "J", name, "분리 실행 작업(%s) 결과 요청은 보냈다(%s) — 회신 대기(마지막 생존 확인 %s, %d분 경과)"
                            % (fp, _hm(last_out), _hm(seen), age // 60)))
            else:
                lvl = "block" if age >= IDLE_BLOCK else "warn"
                out.append((lvl, "J", name, "분리 실행 작업(%s)이 끝났는데 결과 보고가 없다(마지막 생존 확인 %s, %d분 경과). "
                            "SendMessage 로 결과(rc·로그 꼬리)를 요구하라 — 유휴 팀원은 스스로 깨지 않는다" % (fp, _hm(seen), age // 60)))
                continue
        ks = keep_status(session_dir, name, now)
        # keep 표시 동기화(자기 팀 pane 에만 — 재개 세션은 소유 증명된 pane 에만 쓴다)
        sync_ok = prow is not None and not (owned is not None and pane not in owned)
        if sync_ok:
            if pstate == "keep" and ks != "ok":
                syncs.append((pane, "done", name))
                pstate = "done"
            elif pstate == "done" and ks == "ok":
                syncs.append((pane, "keep", name))
                pstate = "keep"
        if ks == "ok":
            out.append(("keep", "K", name, "agent_keep 면제"))  # 감사 로그용(출력 안 함)
            # P 병렬 여유(경고만): keep 사유가 '대기·기다림' 류이고 팀원이 유휴로 PAR_WARN 분 이상 → 선행 가능한 부분 작업 배정 권고
            # (2026-10-10 c174 odev-10-3 이 "입력이 오면 S5 병합" 사유로 쉬는 동안 부분 병합이 가능했는데 아무도 알리지 않았다)
            if str(m.get("isActive", "")).lower() != "true":
                kr, kage = keep_reason(session_dir, name, now)
                if kr and PAR_RX.search(kr) and not PAR_EXCLUDE_RX.search(kr) and kage >= PAR_WARN:
                    out.append(("warn", "P", name, "agent_keep 사유 '%s' 로 %d분째 대기 중이다. 입력을 기다리는 동안 지금 할 수 있는 "
                                "부분 작업(부분 병합·초안·검증 스크립트·이미 도착한 산출물 선처리)을 SendMessage 로 배정하라 — "
                                "대기 팀원은 병렬 여유다(차단 아님)" % (kr[:60], kage // 60)))
            continue
        keep_note = ""
        if ks == "expired":
            keep_note = " (keep 표기 만료 — 갱신하려면 사유를 다시 쓰라)"
        elif ks == "invalid":
            keep_note = " (keep 표기 무효 — 사유 %d자 이상 필요)" % KEEP_MIN_REASON
        # F 사유 없는 완료 잔존: 완료 보고 후 대기(done)인데 shutdown·유효 keep 없음 (그 뒤 리드 발신이 있으면 B 로 넘긴다)
        if pstate == "done":
            base = _num(tt.get("updated")) if tt.get("status") == "final" else 0
            if joined and base and base < joined:
                base = 0  # 같은 이름 재spawn — 이전 인스턴스의 final 기록은 현 인스턴스 기준이 아니다(자체 발견, J·D 와 같은 결함)
            # joinedAt 폴백 금지 — final 기록·수신 행이 아직 없는 순간 spawn 시각으로 경과를 계산해 즉시 차단했다(c182, S 와 같은 결함)
            base = base or last_in
            bmap[("F", name)] = base or joined
            if not (last_out and last_out > max(base, last_in)):
                if not base:
                    out.append(("warn", "F", name, "완료 보고 후 대기(done) — 완료 시각 미확인(경과 미산정), shutdown·agent_keep 없음. shutdown_request 또는 재사용 사유 기록%s" % keep_note))
                    continue
                age = now - base
                lvl = "block" if age >= DONE_BLOCK else "warn"
                out.append((lvl, "F", name, "완료 보고 후 대기(done) %d분 — shutdown·agent_keep 없음. 즉시 shutdown_request 또는 재사용 사유 기록%s" % (age // 60, keep_note)))
                continue
        active = str(m.get("isActive", "")).lower() == "true"
        anchor = max(last_in, last_out, joined)
        bmap[("A", name)] = anchor
        # B 무응답: 리드 발신이 마지막 수신보다 뒤
        if last_out and last_out > last_in:
            age = now - last_out
            if age >= NORESP_WARN:
                lvl = "block" if age >= NORESP_BLOCK else "warn"
                out.append((lvl, "B", name, "리드가 %s 에 보낸 메시지 이후 %d분째 수신 0건(isActive=%s)%s" % (_hm(last_out), age // 60, active, keep_note)))
            continue
        if not active:
            age = now - anchor
            if anchor and age >= IDLE_WARN:
                lvl = "block" if age >= IDLE_BLOCK else "warn"
                out.append((lvl, "A", name, "유휴 %d분 — 마지막 활동 %s, 이후 리드 지시 없음%s" % (age // 60, _hm(anchor), keep_note)))
        else:
            ref = max(last_in, joined)
            age = now - ref
            if ref and age >= SILENT_WARN:
                out.append(("warn", "C", name, "턴 진행 중(isActive=True)인데 %d분째 보고 0건 — 마지막 수신 %s%s" % (age // 60, _hm(ref), keep_note)))
    return out


def apply_breaker(st, results, basis, now, log_path):
    """회로 차단기 — 같은 키(규칙|이름|근거시각 정수)가 메인 호출마다 연속 BRK_N 회 block 이면 그 키만 BRK_TTL 동안 warn 으로 강등.
    사라진 키의 연속 횟수는 지운다. 강등 시 자기 세션 logs/idle_guard_autodowngrade.log 에 1줄. 사람 개입 없이 오탐 교착을 끊는다."""
    streak = st.setdefault("blk_streak", {})
    down = st.setdefault("downgraded", {})
    for k in [k for k, t in down.items() if now - _num(t) >= BRK_TTL]:
        down.pop(k, None)
    cur = set()
    out = []
    for r in results:
        if r[0] != "block":
            out.append(r)
            continue
        key = "%s|%s|%d" % (r[1], r[2], int(_num(basis.get((r[1], r[2])))))
        cur.add(key)
        if key in down:
            out.append(("warn", r[1], r[2], r[3] + " (자동 강등 — 연속 %d회 차단, %s 까지 경고만)" % (BRK_N, _hm(_num(down[key]) + BRK_TTL))))
            continue
        streak[key] = int(streak.get(key, 0)) + 1
        if streak[key] >= BRK_N:
            down[key] = now
            try:
                os.makedirs(os.path.dirname(log_path), exist_ok=True)
                with open(log_path, "a", encoding="utf-8") as f:
                    f.write("[%s] autodowngrade key=%s count=%d ttl_min=%d\n"
                            % (time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(now)), key, streak[key], BRK_TTL // 60))
            except Exception:
                pass
            streak.pop(key, None)
            st.setdefault("notified", {}).pop(r[1] + ":" + r[2], None)  # 강등 시점 경고는 반복 억제 없이 1회 보인다
            out.append(("warn", r[1], r[2], r[3] + " (자동 강등 — 연속 %d회 차단)" % BRK_N))
            continue
        out.append(r)
    for k in [k for k in streak if k not in cur]:
        streak.pop(k, None)
    return out


def _recover_tmux_ok(cmd):
    """단독 tmux 복구 명령인지 — 연결 연산자·치환·리디렉션·#( 포함 시 거부"""
    if any(t in cmd for t in TMUX_FORBID):
        return False
    return bool(TMUX_RECOVER_RX.match(cmd))


def tool_allowed(tool_name, tool_input, blocks=(), uuid=""):
    tool_input = tool_input if isinstance(tool_input, dict) else {}
    if tool_name in ALLOW_ALWAYS:
        return True
    if tool_name == "Skill":
        sk = str(tool_input.get("skill", "")).split(":")[-1]
        return sk in ALLOW_SKILLS
    if tool_name == "mcp__oio__session_state" and str(tool_input.get("key") or "") in ALLOW_STATE_KEYS \
            and (not uuid or str(tool_input.get("uuid") or uuid) == uuid):
        return True  # ointaug/oi 절차 기록(자기 세션만)
    if tool_name in ("mcp__oio__file_write", "mcp__oio__file_edit") and uuid:
        fp = str(tool_input.get("file_path") or tool_input.get("path") or tool_input.get("filepath") or "")
        if ".." not in fp and any(fp.endswith("session-env/%s/%s" % (uuid, k)) for k in ALLOW_STATE_KEYS):
            return True
    blob = json.dumps(tool_input, ensure_ascii=False)
    if "agent_keep" in blob:
        return True
    if tool_name == "mcp__oio__bash_exec":
        cmd = str(tool_input.get("command") or tool_input.get("cmd") or "").strip()
        if re.match(r"^date(\s|$)", cmd):
            return True
        if _recover_tmux_ok(cmd):
            return True
    if tool_name == "Agent":
        # 복구 재spawn: E/D 로 차단된 팀원과 같은 역할(-숫자 접미 제거 후 일치)
        nm = str(tool_input.get("name") or "")
        roles = {ROLE_RX.sub("", r[2]) for r in blocks if r[1] in ("E", "D")}
        if nm and ROLE_RX.sub("", nm) in roles:
            return True
    if tool_name == "mcp__oio__file_write" and uuid:
        fp = str(tool_input.get("file_path") or tool_input.get("path") or tool_input.get("filepath") or "")
        # evidence/shutdown_sent/ 는 제외 — shutdown 증거 위조로 차단을 스스로 푸는 경로가 된다
        if ".." not in fp and "shutdown_sent" not in fp and \
                ("session-env/%s/evidence/" % uuid in fp or "session-env/%s/plans/handoff_" % uuid in fp):
            return True
    return False


def main():
    try:
        inp = json.loads(sys.stdin.read() or "{}")
    except Exception:
        return 0
    uuid = os.environ.get("TIG_UUID", "")
    session_dir = os.environ.get("TIG_SESSION_DIR", "")
    config_path = os.environ.get("TIG_CONFIG", "")
    mode = os.environ.get("TIG_MODE", "block")
    now = float(os.environ.get("TIG_NOW") or time.time())
    transcript = os.environ.get("TIG_TRANSCRIPT") or inp.get("transcript_path") or ""
    if not (uuid and session_dir and config_path and transcript):
        return 0
    # 세션 격리: 트랜스크립트가 자기 세션 것인지 파일명으로 확인
    if os.path.basename(transcript) != uuid + ".jsonl":
        return 0
    config = _load_json(config_path, {})
    state_path = os.path.join(session_dir, "teammate_activity.json")
    log_path = os.path.join(session_dir, "logs", "teammate_idle_guard.log")
    owned = None  # None = leadSessionId 일치(전체 소유)
    if config.get("leadSessionId") != uuid:
        # 재개 세션: 런타임 ID 가 바뀌어 leadSessionId 로는 소유를 증명할 수 없다 → 팀원 pane argv 로 증명
        team = config.get("name") or os.path.basename(os.path.dirname(config_path))
        owned = proven_panes(config, uuid, team)
        if not owned:
            # 증명 실패 → 판정 생략(무출력). 관측성용 로그만 WARN_REPEAT 에 1회
            try:
                st0 = _load_json(state_path, {})
                if now - float(st0.get("owner_skip_at", 0) or 0) >= WARN_REPEAT:
                    st0["owner_skip_at"] = now
                    _save_json(state_path, st0)
                    os.makedirs(os.path.dirname(log_path), exist_ok=True)
                    with open(log_path, "a", encoding="utf-8") as f:
                        f.write("[%s] SKIP owner-unproven leadSessionId!=uuid team=%s\n"
                                % (time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(now)), team))
            except Exception:
                pass
            return 0
    st = _load_json(state_path, {})
    scan_transcript(transcript, st)
    panes = read_panes(config)
    syncs = []
    basis = {}
    results = evaluate(session_dir, config, st, now, panes=panes, syncs=syncs, owned=owned, bmap=basis)
    results = apply_breaker(st, results, basis, now, os.path.join(session_dir, "logs", "idle_guard_autodowngrade.log"))
    # 경고 반복 억제
    notified = st.setdefault("notified", {})
    blocks = [r for r in results if r[0] == "block"]
    warns = [r for r in results if r[0] == "warn" and now - notified.get(r[1] + ":" + r[2], 0) >= WARN_REPEAT]
    tool_name = inp.get("tool_name", "")
    tool_input = inp.get("tool_input") or {}
    out = None
    stamp = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(now))
    keep_dir = os.path.join(session_dir, "agent_keep")
    howto = ("조치: ① 재사용 불필요 → SendMessage(to=이름, message={\"type\":\"shutdown_request\",\"reason\":...}) "
             "② 재사용 예정 → mcp__oio__file_write 로 %s/{이름} 에 사유(5자 이상) 기록(%d분 유효) "
             "③ 오탐 의심이면 가드가 스스로 판정한다(이전 인스턴스 기록 제외, 결과 요청 후 강등, 연속 %d회 차단 시 자동 강등) — 사용자에게 묻지 말고 ④ 를 진행하라 "
             "④ dead/무보고 → ok_pipeline SKILL.md '팀원 생명주기 관리 §복구 절차' 수행(캡처 → kill-pane → 같은 역할 재spawn)" % (keep_dir, KEEP_TTL // 60, BRK_N))
    # keep 표시 동기화(자기 팀 pane 에만 pane 단위 옵션) — TIG_DRY_TMUX=1 이거나 주입 데이터면 실제 tmux 호출 없이 로그만
    sync_log = []
    for (pane, new_state, name) in syncs:
        dry = os.environ.get("TIG_DRY_TMUX") == "1" or "TIG_TMUX_PANES" in os.environ
        ok = "dry"
        if not dry:
            try:
                r = subprocess.run(["tmux", "set", "-p", "-t", pane, "@agent_state", new_state],
                                   capture_output=True, timeout=2)
                ok = "ok" if r.returncode == 0 else "fail"
            except Exception:
                ok = "fail"
        sync_log.append("sync:%s:%s:%s:%s" % (name, pane, new_state, ok))
    if blocks and mode == "block" and not tool_allowed(tool_name, tool_input, blocks, uuid):
        kinds = sorted({RULE_KIND.get(r[1], r[1]) for r in blocks})
        lines = ["⛔ [teammate idle guard] 팀원 처리가 밀려 있어 '%s' 를 차단한다 — 분류: %s" % (tool_name, "·".join(kinds))]
        lines += ["  - [%s %s] %s: %s" % (rule, RULE_KIND.get(rule, ""), name, text) for (_, rule, name, text) in blocks]
        if any(r[1] == "J" for r in blocks):
            lines.append("※ 결과 미회수(정체): 팀원이 분리 실행한 작업은 끝났지만 보고가 없어 리드도 팀원도 유휴 상태다. "
                         "종료(shutdown)보다 먼저 SendMessage 로 결과를 요구하라.")
        lines.append(howto)
        lines.append("허용 도구: SendMessage·ListAgents·AskUserQuestion·TaskStop·조회계열·Skill(oinit/ofinish/ointaug/oi)·ointaug_done/oi_routed 기록·agent_keep 기록·date"
                     "·단독 tmux capture-pane/kill-pane/display/list-panes·같은 역할 Agent 재spawn(E/D)·evidence/handoff_ file_write")
        out = {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                      "permissionDecisionReason": "\n".join(lines)}}
        for r in blocks:
            notified[r[1] + ":" + r[2]] = now
    else:
        show = warns + ([r for r in blocks if now - notified.get(r[1] + ":" + r[2], 0) >= WARN_REPEAT] if blocks else [])
        if show and mode in ("warn", "block"):
            lines = ["⚠️ [teammate idle guard] 팀원 상태 점검 필요%s:" % (" (이 세션은 warn 모드 — 차단 없음)" if mode == "warn" else "")]
            lines += ["  - [%s %s] %s: %s%s" % (rule, RULE_KIND.get(rule, ""), name, text, " ← 차단 임계 초과" if lvl == "block" else "") for (lvl, rule, name, text) in show]
            lines.append(howto)
            out = {"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": "\n".join(lines)}}
            for r in show:
                notified[r[1] + ":" + r[2]] = now
    try:
        _save_json(state_path, st)
    except Exception:
        pass
    if results or sync_log:
        try:
            os.makedirs(os.path.dirname(log_path), exist_ok=True)
            with open(log_path, "a", encoding="utf-8") as f:
                act = "DENY" if (out and "permissionDecision" in out["hookSpecificOutput"]) else ("WARN" if out else "QUIET")
                f.write("[%s] %s mode=%s tool=%s %s\n" % (stamp, act, mode, tool_name,
                        " ".join(["%s:%s:%s" % (r[0], r[1], r[2]) for r in results] + sync_log)))
        except Exception:
            pass
    if out:
        sys.stdout.write(json.dumps(out, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)  # fail-open
