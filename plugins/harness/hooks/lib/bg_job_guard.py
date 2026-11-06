# 팀원이 분리 실행(setsid/nohup/&)한 작업이 끝나 결과를 보고하기 전에 유휴로 들어가는 것을 막는 TeammateIdle 판정 코어
"""bg_job_guard.py --transcript <팀원 트랜스크립트> --state <상태 json> [--now <epoch>]

사고(2026-10-10 c174): obuild-1 이 `setsid nohup bash run_L4.sh &` 로 빌드를 분리 실행하고
"완료되면 보고하겠다" 는 착수 보고 후 유휴로 들어갔다. 빌드는 05:55 에 끝났지만 08:43 까지 아무도 깨지 않았다.
  - oio bash_exec 의 run_in_background 는 write_guard F10(L-303) 이 막는다. 그래서 foreground 명령 안에서 setsid/nohup/& 로
    분리하는 우회가 생긴다. 이 프로세스는 Claude Code 하네스가 추적하지 않으므로 종료 알림이 아무에게도 가지 않는다.
  - TeammateIdle_report_guard 는 "이번 턴에 team-lead 보고가 있었나" 만 본다. 착수 보고(interim)도 통과한다.
판정(공식 지원 근거: TeammateIdle hook exit 2 = "Prevents the teammate from going idle" — code.claude.com/docs/en/hooks):
  1. 트랜스크립트 꼬리 4MB 에서 Bash / mcp__oio__bash_exec 호출 중 분리 실행 패턴(setsid·nohup·disown·단독 &)을 찾는다.
     최근 MAX_LAUNCH 건, LOOKBACK 시간 이내만 본다. 명령에 `#bg:daemon` 이 있으면 의도한 상주 프로세스로 보고 제외한다.
  2. 지문(fingerprint) = ★분리 실행 구간★ 속 스크립트 경로(.sh/.py/.ps1/.bat/.cmd). 없으면 setsid/nohup 뒤 실행 파일+인자 2개.
     구간 = 따옴표 밖 ; && || 개행 단독& 로 나눈 조각. 단독 & 로 끝나거나 setsid/nohup/disown 이 든 조각만 후보다
     (2026-10-11 L-598: 같은 호출의 조회 대상 `sha256sum x.sh;` 나 `bash write_guard.sh;` 가 지문이 되던 오탐 제거).
     공용 hook 경로(write_guard.sh + settings.json 에 hook 으로 등록된 명령의 basename)는 지문 후보에서 뺀다.
     hooks/tests/ 아래 스크립트는 팀원 고유 작업이므로 빼지 않는다. 등록 안 된 hooks 직속 스크립트도 빼지 않는다(진양성 유지).
     /proc/*/cmdline 에서 지문이 살아 있는지 본다(자기 hook 프로세스 체인 제외).
  2-1. 회수 기록(rc=0): 아래 세 조건을 모두 만족하는 셸 호출이 있으면 그 시각을 회수(reaped) 시각으로 본다.
     ① 그 호출 결과 텍스트(oio JSON 이면 stdout)가 `(^|\\s)rc=0(\\s|$)` 에 맞는다.
     ② 그 명령에 `while`/`until` 대기 루프 + `pgrep` + 지문 basename(권고 형식 `[r]un_x.sh` 괄호 포함)이 함께 있다.
        (단발 `pgrep …; echo rc=$?` 의 rc=0 은 "살아 있음" 이므로 회수가 아니다.)
     ③ 그 호출 시각 > 착수(launched) 시각.
     회수된 실행 건은 alive() 를 보지 않는다(다른 팀원의 동명 프로세스로 재차단 금지). alive_seen 이 0 이면 회수 시각으로 채워
     4번(보고 의무) 규칙만 적용한다.
  3. 살아 있음 → block(running). 상태에 alive_seen=now 기록. 같은 실행 건의 차단이 MAX_BLOCKS 에 닿으면 capped(통과 + 기록).
  4. 죽었고, 이 게이트가 살아 있는 것을 본 적이 있으며(alive_seen), 그 뒤 team-lead 로 SendMessage 가 없음 → block(finished).
  5. 그 외 → ok. (살아 있는 것을 본 적이 없는 짧은 작업은 기존 보고 게이트가 담당한다)
출력: stdout 1줄. "ok" | "block running <지문> <착수HH:MM:SS> <n>/<max>" | "block finished <지문> ..." | "capped ..."
      Windows 쪽 분리(cmd.exe /c start 등)는 WSL /proc 에서 보이지 않으므로 추적하지 못한다(한계).
상태: --state 파일(json) {launch_id: {fp, launched, alive_seen, blocks}} — 호출부가 리드 session-env 아래 자기 팀원 파일을 넘긴다.
소유 판정(사이클182 반복1): 지문만으로는 같은 스크립트를 띄운 ★다른 팀원★ 의 프로세스까지 내 작업으로 잡았다
  (실측: odev-14 의 09:58 `setsid … c182_gate.sh run K3` 는 grep 대기로 끝났는데, 10:10 odone-2 가 띄운
  `c182_gate.sh run R1` 을 살아 있는 내 작업으로 보고 차단). setsid/nohup 프로세스는 init 으로 재부모화돼 PID 계보로는
  띄운 팀원을 찾을 수 없다. 그래서 착수 기록(트랜스크립트 tool_use 시각 lt)과 프로세스 자신·조상(최대 10단)의
  시작 시각을 대조한다 — 그중 하나가 [lt-LAUNCH_SKEW, lt+LAUNCH_WINDOW] 에 있어야 내 작업이다(분리 실행 트리의
  최상위는 착수 순간 시작한다). 시작 시각을 못 읽으면 종전처럼 일치로 본다(fail-safe = 차단 쪽).
  ★1순위 = 세션 ID 대조(사이클182 반복1 odev-15)★: 분리 실행 프로세스도 띄운 팀원의 환경변수
  CLAUDE_CODE_SESSION_ID 를 상속한다(실측 — 재부모화돼도 /proc/<pid>/environ 에 남음). 트랜스크립트 파일 이름
  (<세션ID>.jsonl)과 같으면 내 작업, 다르면 남의 작업이다 — 시각 창은 다른 팀원이 내 착수 180초 안에 같은 스크립트를
  띄우면 여전히 오연결하므로 2순위로 내린다. environ 을 못 읽거나(다른 uid 등) 값이 없을 때만 시각 창, 그것도 못 읽으면 일치(차단).
  판정한 세션 ID 는 상태 기록(sid)에 남겨 리드 가드(teammate_idle_guard J)가 같은 규칙으로 쓴다.
테스트 주입: BJG_PROCS = 줄 단위 cmdline 목록(공백 구분) — 지정 시 /proc 를 읽지 않는다.
          줄 앞에 `@<epoch>[,<epoch>…] ` 를 붙이면 자신·조상 시작 시각 주입(없으면 시각 미상 = 종전 판정).
          줄 앞에 `@sid=<세션ID> ` 를 붙이면 그 프로세스의 CLAUDE_CODE_SESSION_ID 주입(둘 다 붙일 수 있다).
          BJG_SID = 내 세션 ID 주입(미지정 시 --transcript 파일 이름에서 얻는다).
          BJG_SETTINGS = 공용 hook 이름을 읽을 settings.json 경로(':' 구분) — 미지정 시 hooks/../settings.json 과
          $CLAUDE_CONFIG_DIR/settings.json, ~/.claude/settings.json.
항상 exit 0 (fail-open). 내부 오류 → "ok".
"""
import argparse
import json
import os
import re
import shlex
import sys
import time
from datetime import datetime

MAX_TAIL = 4 * 1024 * 1024
MAX_LAUNCH = 5
LOOKBACK = int(os.environ.get("BJG_LOOKBACK_H", "12")) * 3600
MAX_BLOCKS = int(os.environ.get("BJG_MAX_BLOCKS", "6"))
LEAD = "team-lead"
SHELL_TOOLS = ("Bash", "mcp__oio__bash_exec")

# 분리 실행: setsid / nohup / disown, 또는 단독 & (&&, 2>&1, >&, &> 는 제외)
DETACH_RX = re.compile(r"(?:^|[\s;|&(])(?:setsid|nohup|disown)(?:\s|$)|(?<![&>|<])&(?![&>\d])\s*(?:$|[;)\n])", re.M)
SCRIPT_RX = re.compile(r"""(?:^|[\s'"=])((?:/|\./|~/)?[\w./+-]+\.(?:sh|py|ps1|bat|cmd))(?=$|[\s'";)&|>])""")
OPT_OUT = "#bg:daemon"
RC0_RX = re.compile(r"(?:^|\s)rc=0(?:\s|$)")
WAIT_LOOP_RX = re.compile(r"(?:^|[\s;'\"(])(?:while|until)\s[^\n]*\bpgrep\b")
BRACKET1_RX = re.compile(r"\[([^\]\\])\]")
ALWAYS_SHARED = ("write_guard.sh",)
LAUNCH_WINDOW = float(os.environ.get("BJG_LAUNCH_WINDOW_S", "180"))  # 착수 뒤 이 안에 시작한 트리만 내 작업
LAUNCH_SKEW = 5.0                                                     # 시각 기록 오차 허용(착수 앞쪽)
_SHARED = None


def _ts(entry):
    ts = entry.get("timestamp")
    if not isinstance(ts, str) or not ts:
        return 0.0
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return 0.0


def _tail_lines(path):
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        cut = size > MAX_TAIL
        if cut:
            f.seek(size - MAX_TAIL)
        data = f.read()
    if cut:
        nl = data.find(b"\n")
        data = data[nl + 1:] if nl >= 0 else b""
    return data.decode("utf-8", errors="replace").splitlines()


def _result_text(content):
    """tool_result content(str | [{type:text,text}]) → 판정용 텍스트. oio JSON 이면 stdout 만 쓴다."""
    if isinstance(content, list):
        text = "\n".join(str(x.get("text") or "") for x in content if isinstance(x, dict))
    else:
        text = str(content or "")
    try:
        d = json.loads(text)
        if isinstance(d, dict) and isinstance(d.get("stdout"), str):
            return d["stdout"]
    except ValueError:
        pass
    return text


def _oio_bg(content):
    """oio bash_exec 결과가 oio 자체 백그라운드 실행이면 done_file 경로, 아니면 ''.
    실측(2026-10-14 otest-m-1 4d039f08 2038): {"success":true,"pid":…,"background":true,"log_file":"…/oio-bg/oio_bg_x.log",
    "done_file":"…/oio-bg/oio_bg_x.log.done",…}. 하네스 백그라운드(“moved to the background as task …”)와 달리
    완료 알림이 오지 않아 팀원을 깨우지 않는다(2026-10-14 10:12→10:24 otest-m-1 12분 정체)."""
    if isinstance(content, list):
        text = "\n".join(str(x.get("text") or "") for x in content if isinstance(x, dict))
    else:
        text = str(content or "")
    try:
        d = json.loads(text)
    except ValueError:
        return ""
    if isinstance(d, dict) and d.get("background") is True and isinstance(d.get("done_file"), str):
        return d["done_file"]
    return ""


def scan(path):
    """(launches[(id, ts, cmd)], lead_reports[ts], reaps[(ts, cmd)], oio_bg[(id, ts, done_file)]) — 사이드체인 제외
    reaps = pgrep 대기 루프 명령 중 결과가 rc=0 인 호출(시각은 그 tool_use 시각).
    oio_bg = oio bash_exec 가 자체 백그라운드로 돌린 호출([사이클182] — 완료 판정은 done_file 존재)."""
    launches, reports, waits, reaps = [], [], {}, []
    oio_calls, oio_bg = {}, []
    for ln in _tail_lines(path):
        try:
            e = json.loads(ln)
        except ValueError:
            continue
        if not isinstance(e, dict) or e.get("isSidechain") or e.get("type") not in ("assistant", "user"):
            continue
        content = (e.get("message") or {}).get("content")
        if not isinstance(content, list):
            continue
        if e.get("type") == "user":
            for b in content:
                if isinstance(b, dict) and b.get("type") == "tool_result":
                    w = waits.pop(str(b.get("tool_use_id") or ""), None)
                    if w and RC0_RX.search(_result_text(b.get("content"))):
                        reaps.append(w)
                    o = oio_calls.pop(str(b.get("tool_use_id") or ""), None)
                    if o:
                        done = _oio_bg(b.get("content"))
                        if done:
                            oio_bg.append((o[0], o[1], done))
            continue
        t = _ts(e)
        for b in content:
            if not isinstance(b, dict) or b.get("type") != "tool_use":
                continue
            name = b.get("name")
            inp = b.get("input") if isinstance(b.get("input"), dict) else {}
            if name == "SendMessage" and str(inp.get("to") or "") == LEAD:
                reports.append(t)
            elif name in SHELL_TOOLS:
                cmd = str(inp.get("command") or inp.get("cmd") or "")
                if cmd and OPT_OUT not in cmd and DETACH_RX.search(cmd):
                    launches.append((str(b.get("id") or ""), t, cmd))
                elif cmd and b.get("id") and WAIT_LOOP_RX.search(cmd):
                    waits[str(b.get("id"))] = (t, cmd)
                if name == "mcp__oio__bash_exec" and cmd and OPT_OUT not in cmd and b.get("id"):
                    oio_calls[str(b.get("id"))] = (str(b.get("id")), t)
    return launches, reports, reaps, oio_bg


def reaped_at(fp, lt, reaps):
    """착수(lt) 뒤 이 지문을 pgrep 대기 루프로 기다려 rc=0 을 받은 가장 늦은 시각. 없으면 0."""
    # 공백 든 지문(setsid 뒤 argv 3개)은 통째로만 대조한다 — 첫 토큰(bash 등)만으로는 아무 대기 루프에나 맞는다
    keys = {fp, fp.replace(" ", "_")} if " " in fp else {fp, os.path.basename(fp)}
    keys.discard("")
    best = 0.0
    for t, cmd in reaps:
        if t <= lt:
            continue
        plain = BRACKET1_RX.sub(r"\1", cmd)
        if any(k in plain for k in keys):
            best = max(best, t)
    return best


def _segments(cmd):
    """따옴표 밖 ; && || 개행 단독& 로 나눈 [(조각, 단독&로_끝남)]. 리다이렉트(2>&1, &>, >&)·|& 의 & 는 구분자가 아니다."""
    segs, buf, q, i, n = [], [], "", 0, len(cmd)
    while i < n:
        c = cmd[i]
        if q:
            buf.append(c)
            if c == "\\" and q == '"' and i + 1 < n:
                buf.append(cmd[i + 1])
                i += 1
            elif c == q:
                q = ""
        elif c == "\\" and i + 1 < n:
            buf.extend(cmd[i:i + 2])
            i += 1
        elif c in ("'", '"'):
            q = c
            buf.append(c)
        elif c in (";", "\n"):
            segs.append(("".join(buf), False)); buf = []
        elif cmd.startswith("&&", i) or cmd.startswith("||", i):
            segs.append(("".join(buf), False)); buf = []
            i += 1
        elif c == "&" and (i == 0 or cmd[i - 1] not in "&>|<") and not (i + 1 < n and (cmd[i + 1] in "&>" or cmd[i + 1].isdigit())):
            segs.append(("".join(buf), True)); buf = []
        else:
            buf.append(c)
        i += 1
    segs.append(("".join(buf), False))
    return [(s, bg) for s, bg in segs if s.strip()]


def _shared_names():
    """공용 hook basename: write_guard.sh + settings.json hooks 에 등록된 명령 속 스크립트 basename."""
    global _SHARED
    if _SHARED is not None:
        return _SHARED
    names = set(ALWAYS_SHARED)
    env = os.environ.get("BJG_SETTINGS")
    if env is not None:
        paths = [p for p in env.split(":") if p]
    else:
        hooks = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        paths = [os.path.join(os.path.dirname(hooks), "settings.json"),
                 os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or "", "settings.json"),
                 os.path.join(os.path.expanduser("~"), ".claude", "settings.json")]
    for p in paths:
        try:
            with open(p, encoding="utf-8") as f:
                hk = (json.load(f) or {}).get("hooks") or {}
        except Exception:
            continue
        for arr in hk.values() if isinstance(hk, dict) else ():
            for m in arr if isinstance(arr, list) else ():
                for h in (m.get("hooks") or []) if isinstance(m, dict) else ():
                    c = str(h.get("command") or "") if isinstance(h, dict) else ""
                    for s in re.findall(r"[\w./+-]+\.(?:sh|py)", c):
                        names.add(os.path.basename(s))
    _SHARED = names
    return names


def _is_shared(path):
    if "/tests/" in path:
        return False
    return os.path.basename(path) in _shared_names()


def fingerprint(cmd):
    for seg, bg in _segments(cmd):
        try:
            toks = shlex.split(seg, posix=True)
        except ValueError:
            toks = seg.split()
        if not (bg or any(t in ("setsid", "nohup", "disown") for t in toks)):
            continue
        for m in SCRIPT_RX.finditer(seg):
            if not _is_shared(m.group(1)):
                return m.group(1)
        for i, tk in enumerate(toks):
            if tk in ("setsid", "nohup"):
                rest = [x for x in toks[i + 1:] if x not in ("setsid", "nohup") and not x.startswith("-")]
                rest = [x for x in rest if not re.match(r"^[0-9]*[<>]", x) and x not in ("&", ";", "&&", "|")]
                if rest and not any(_is_shared(x) for x in rest[:3]):
                    return " ".join(rest[:3])
                break
    return ""


def _chain_pids():
    pids, pid = set(), os.getpid()
    for _ in range(8):
        pids.add(pid)
        try:
            with open("/proc/%d/stat" % pid, "rb") as f:
                s = f.read().decode("utf-8", "replace")
            pid = int(s[s.rindex(")") + 2:].split()[1])
        except Exception:
            break
        if pid <= 1:
            break
    return pids


_BOOT = None


def _starts(pid):
    """pid 자신과 조상(최대 10단, init 제외)의 시작 epoch 목록. 읽기 실패 → None(시각 미상)."""
    global _BOOT
    try:
        if _BOOT is None:
            with open("/proc/stat", "rb") as f:
                _BOOT = next(float(l.split()[1]) for l in f.read().decode().splitlines() if l.startswith("btime "))
        hz = float(os.sysconf("SC_CLK_TCK"))
        out, cur = [], int(pid)
        for _ in range(10):
            if cur <= 1:
                break
            with open("/proc/%d/stat" % cur, "rb") as f:
                st = f.read().decode("utf-8", "replace")
            rest = st[st.rindex(")") + 2:].split()
            out.append(_BOOT + float(rest[19]) / hz)
            cur = int(rest[1])
        return out or None
    except Exception:
        return None


SID_RX = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
SID_KEY = b"CLAUDE_CODE_SESSION_ID="


def owner_sid(transcript):
    """내 세션 ID — BJG_SID 주입 또는 트랜스크립트 파일 이름(<세션ID>.jsonl). 형식 밖 → '' (1순위 판정 불가)."""
    s = os.environ.get("BJG_SID")
    if s is None:
        s = os.path.basename(transcript or "")
        s = s[:-6] if s.endswith(".jsonl") else s
    return s if SID_RX.match(s or "") else ""


def _env_sid(pid):
    """/proc/<pid>/environ 의 CLAUDE_CODE_SESSION_ID. 읽기 실패(다른 uid·소멸)·값 없음 → None(2순위로 넘긴다)."""
    try:
        with open("/proc/%d/environ" % pid, "rb") as f:
            for kv in f.read().split(b"\0"):
                if kv.startswith(SID_KEY):
                    v = kv[len(SID_KEY):].decode("utf-8", "replace")
                    return v if SID_RX.match(v) else None
    except Exception:
        pass
    return None


def _mine(starts, lt):
    """자신·조상 중 착수 창 안에서 시작한 것이 있으면 내 작업. 시각 미상(None)·착수 시각 없음 → 종전처럼 True."""
    if starts is None or not lt:
        return True
    return any(lt - LAUNCH_SKEW <= s <= lt + LAUNCH_WINDOW for s in starts)


def proc_cmdlines():
    """[(cmdline 토큰, 실 pid(int) 또는 주입 (세션ID|None, 시작시각 목록|None))]"""
    inj = os.environ.get("BJG_PROCS")
    if inj is not None:
        out = []
        for ln in inj.splitlines():
            if not ln.strip():
                continue
            toks = ln.split()
            sid, starts = None, None
            while toks and toks[0].startswith("@"):
                tag = toks.pop(0)[1:]
                if tag.startswith("sid="):
                    sid = tag[4:] or None
                    continue
                try:
                    starts = [float(x) for x in tag.split(",") if x]
                except ValueError:
                    starts = None
            out.append((toks, (sid, starts)))
        return out
    skip = _chain_pids()
    out = []
    try:
        ents = os.listdir("/proc")
    except OSError:
        return out
    for e in ents:
        if not e.isdigit() or int(e) in skip:
            continue
        try:
            with open("/proc/%s/cmdline" % e, "rb") as f:
                toks = [t.decode("utf-8", "replace") for t in f.read().split(b"\0") if t]
        except Exception:
            continue
        if toks and not any("bg_job_guard" in t for t in toks):
            out.append((toks, int(e)))
    return out


def _owner_ok(ref, lt, osid=""):
    """소유 판정 — 1순위 세션 ID 대조(양쪽 다 있을 때만), 2순위 착수 시각 창, 둘 다 미상 → True(차단 쪽).
    ref = 실 pid(int) | 주입 (세션ID|None, 시작시각 목록|None)"""
    if isinstance(ref, int):
        psid = _env_sid(ref)
        if psid and osid:
            return psid == osid
        return _mine(_starts(ref), lt)
    psid, starts = ref if isinstance(ref, tuple) else (None, ref)
    if psid and osid:
        return psid == osid
    return _mine(starts, lt)


def alive(fp, procs, lt=0, osid=""):
    """지문 일치 + 소유 일치 프로세스가 있으면 True — 다른 팀원이 같은 스크립트를 띄운 것은 제외."""
    if not fp:
        return False
    if " " not in fp:
        base = os.path.basename(fp)
        for toks, ref in procs:
            for t in toks[:6]:
                if t == fp or (base and (t == base or t.endswith("/" + base))):
                    if _owner_ok(ref, lt, osid):
                        return True
                    break
        return False
    for toks, ref in procs:
        if fp in " ".join(toks) and _owner_ok(ref, lt, osid):
            return True
    return False


def _hm(t):
    return time.strftime("%H:%M:%S", time.localtime(t)) if t else "-"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--transcript", required=True)
    ap.add_argument("--state", required=True)
    ap.add_argument("--now", type=float, default=0)
    a = ap.parse_args()
    now = a.now or time.time()
    launches, reports, reaps, oio_bg = scan(a.transcript)
    launches = [x for x in launches if x[1] and now - x[1] <= LOOKBACK][-MAX_LAUNCH:]
    oio_bg = [x for x in oio_bg if x[1] and now - x[1] <= LOOKBACK][-MAX_LAUNCH:]
    try:
        with open(a.state, encoding="utf-8") as f:
            st = json.load(f)
        if not isinstance(st, dict):
            st = {}
    except Exception:
        st = {}
    procs = None
    verdict = "ok"
    osid = owner_sid(a.transcript)
    for lid, lt, cmd in reversed(launches):
        fp = fingerprint(cmd)
        if not fp:
            continue
        key = lid or ("%d" % lt)
        rec = st.setdefault(key, {"fp": fp, "launched": lt, "alive_seen": 0, "blocks": 0})
        if osid:
            rec["sid"] = osid  # 리드 가드 J 의 소유 판정용
        rt = reaped_at(fp, lt, reaps)
        if rt:
            # 회수 완료(pgrep 대기 루프 rc=0) — 동명 타 프로세스로 재차단하지 않고 보고 의무만 본다
            rec["reaped"] = rt
            if not float(rec.get("alive_seen") or 0):
                rec["alive_seen"] = rt
        else:
            if procs is None:
                procs = proc_cmdlines()
        if not rt and alive(fp, procs, lt, osid):
            rec["alive_seen"] = now
            if rec["blocks"] < MAX_BLOCKS:
                rec["blocks"] += 1
                verdict = "block running %s %s %d/%d" % (fp.replace(" ", "_"), _hm(lt), rec["blocks"], MAX_BLOCKS)
            else:
                verdict = "capped running %s %s" % (fp.replace(" ", "_"), _hm(lt))
            break
        seen = float(rec.get("alive_seen") or 0)
        if seen and not any(r > seen for r in reports):
            if rec["blocks"] < MAX_BLOCKS:
                rec["blocks"] += 1
                verdict = "block finished %s %s %d/%d" % (fp.replace(" ", "_"), _hm(lt), rec["blocks"], MAX_BLOCKS)
            else:
                verdict = "capped finished %s %s" % (fp.replace(" ", "_"), _hm(lt))
            break
    # [사이클182] oio 자체 백그라운드 — 하네스 완료 알림이 없어 팀원을 깨우지 않는다. 완료는 done_file 존재로만 판정한다.
    #   실행 중(done 없음) → block running, 끝났는데 이 게이트가 실행 중을 본 뒤 team-lead 보고가 없음 → block finished.
    #   지문은 'oio:<done_file>' — 호출부 문구가 test -f 로 완료를 확인하게 안내한다. 같은 상한(MAX_BLOCKS)·정리 규칙을 쓴다.
    #   setsid 규칙이 이미 차단을 정했으면 그 판정을 유지한다(먼저 정해진 verdict 우선).
    if verdict == "ok":
        for oid, ot, done in reversed(oio_bg):
            key = "oio:" + oid
            fp = "oio:" + done
            rec = st.setdefault(key, {"fp": fp, "launched": ot, "alive_seen": 0, "blocks": 0})
            if osid:
                rec["sid"] = osid
            log_file = done[:-5] if done.endswith(".done") else ""
            if not os.path.exists(done):
                if log_file and not os.path.exists(log_file):
                    continue  # log·done 모두 없음 = oio 가 정리한 옛 작업(판정 불가) — 차단하지 않는다
                rec["alive_seen"] = now
                if rec["blocks"] < MAX_BLOCKS:
                    rec["blocks"] += 1
                    verdict = "block running %s %s %d/%d" % (fp, _hm(ot), rec["blocks"], MAX_BLOCKS)
                else:
                    verdict = "capped running %s %s" % (fp, _hm(ot))
                break
            seen = float(rec.get("alive_seen") or 0)
            if seen and not any(r > seen for r in reports):
                if rec["blocks"] < MAX_BLOCKS:
                    rec["blocks"] += 1
                    verdict = "block finished %s %s %d/%d" % (fp, _hm(ot), rec["blocks"], MAX_BLOCKS)
                else:
                    verdict = "capped finished %s %s" % (fp, _hm(ot))
                break
    # 오래된 기록 정리
    for k in list(st.keys()):
        try:
            if now - float(st[k].get("launched") or 0) > LOOKBACK:
                del st[k]
        except Exception:
            del st[k]
    try:
        tmp = "%s.tmp%d" % (a.state, os.getpid())
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(st, f, ensure_ascii=False)
        os.replace(tmp, a.state)
    except Exception:
        pass
    sys.stdout.write(verdict + "\n")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        sys.stdout.write("ok\n")
    sys.exit(0)
