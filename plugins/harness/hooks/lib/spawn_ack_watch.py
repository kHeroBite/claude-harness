# 팀원 spawn 후 첫 지시 소비(ack)를 감시하고, 기한 내 미확인 시 exit 2 로 리드를 깨우는 판정 엔진
"""
PostToolUse:Agent (asyncRewake) 에서 호출된다. 진입점은 PostToolUse_Agent_spawn_ack_watch.sh.

판정 (계획서 §6.3-2):
  대상     : tool_input.name 이 있고 tool_response 가 팀원 spawn 성공을 증명하는 경우만.
             dict 이면 agent_id/teammate_id/agentId 키 우선, 문자열이면 "agent_id: <name>@<team>" 정규식.
  팀 탐색  : 후보 base 의 teams/<team>/config.json 중 leadSessionId == 입력 session_id 인 곳만 (읽기 전용 — 세션 격리 §(b)).
  ack      : 팀원 프로세스(--agent-id <name>@<team>) 실존 AND inboxes/<name>.json 이 있고 미소비 0건.
  경보(exit 2):
    - 한 번 미소비>0 으로 보였던 inbox 가 사라짐 (정리 루틴이 첫 지시를 지운 사고형) → 즉시
    - SPAWN_ACK_WAIT 초과 시 ack 미관측 → 기한 도달 시
  그 외 전 경로 exit 0 (fail-open — 판정 불가하면 조용히 끝낸다).

미소비 정의: inbox 배열 원소 중 read 가 true 가 아닌 것.

  ack 뒤 생존 감시 (2026-10-16 사이클194 (c)):
    - ack 후 SPAWN_LIVE_WAIT(기본 120)초 동안 프로세스 실존을 재확인한다. 단 전체 경과는 SPAWN_ACK_TOTAL_MAX
      (기본 225 — settings 의 time_budget 238 안)를 넘지 않는다. 늦게 ack 된 팀원은 그만큼 짧게 본다.
    - 연속 2회 '없음' + 팀 디렉토리·inbox 가 여전히 있음 + inbox 에 shutdown_request 없음 → 소실로 보고 경보(exit 2,
      log reason=lost_after_ack load=…). 정상 종료(shutdown_request 존재)·팀 정리(inbox/팀 부재)는 조용히 종료.
    - 실측 근거: odev-6 이 17:59:53 ack elapsed=25s 직후 소실됐는데 구 엔진은 ack 즉시 return 해 보지 못했다.
    - ★소실 원인(Claude Code 런타임의 팀원 프로세스 기동·유지 실패, 정체 중 동시 spawn 직후 발생)은 하네스 밖이라
      고칠 수 없다.★ 이 엔진은 감지·복구 안내(TaskStop 후 같은 역할 재spawn)만 한다.

한계(정직 표기): 프로세스가 떠 있고 inbox 가 빈 배열인데 첫 지시가 실제로는 다른 경로에서 유실된 경우는
이 엔진이 구별할 수 없다 (관측 가능한 신호가 없다). 리드가 TaskStop 으로 의도적으로 멈춘 팀원도 inbox 에
shutdown_request 가 없으므로 소실 경보가 날 수 있다(경보 문구에 '의도한 중지면 무시' 를 적는다).

env (테스트 단축·주입용):
  SPAWN_ACK_WAIT        기한 초 (기본 150)
  SPAWN_ACK_INTERVAL    폴링 간격 초 (기본 5)
  SPAWN_LIVE_WAIT       ack 뒤 생존 감시 초 (기본 120, 0 이면 ack 즉시 종료 — 구 동작)
  SPAWN_ACK_TOTAL_MAX   전체 감시 상한 초 (기본 225)
  SPAWN_ACK_BASES       콜론 구분 base 목록 (지정 시 기본 탐색 대체)
  SPAWN_ACK_ALIVE       "1"/"0" — 프로세스 실존 판정을 고정 (테스트 전용)
  SPAWN_ACK_ALIVE_FILE  내용 "1"/"0" 을 매 판정마다 읽는다 — 실존 변화 모사 (테스트 전용, ALIVE 보다 우선)
  SPAWN_ACK_LOADAVG_FILE 부하 판독 파일 (기본 /proc/loadavg, 테스트 전용)
  SPAWN_ACK_LOG_DIR     로그 디렉토리 강제 지정 (테스트 전용)
"""
import glob
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime


ID_KEYS = ("agent_id", "teammate_id", "agentId")  # dict tool_response 에서 팀원 id 를 읽는 키 (실물 확인)
TEAM_RE = re.compile(r"[A-Za-z0-9_.\-]+")


def _env_float(key, default):
    try:
        v = float(os.environ.get(key, ""))
        return v if v >= 0 else default
    except ValueError:
        return default


def _candidate_bases():
    raw = os.environ.get("SPAWN_ACK_BASES")
    if raw:
        bases = [b for b in raw.split(":") if b]
    else:
        home = os.path.expanduser("~")
        bases = [os.environ.get("CLAUDE_CONFIG_DIR", ""), os.path.join(home, ".claude")]
        bases += sorted(glob.glob("/tmp/cc-*"))
    seen, out = set(), []
    for b in bases:
        if not b or not os.path.isdir(b):
            continue
        canon = os.path.realpath(b)
        if canon in seen:
            continue
        seen.add(canon)
        out.append(canon)
    return out


def find_team_dir(team, session_id):
    """leadSessionId 가 자기 세션인 teams/<team>/ 만 반환한다. 소유 불확실하면 None (fail-closed)."""
    for base in _candidate_bases():
        cfg = os.path.join(base, "teams", team, "config.json")
        try:
            with open(cfg, encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, ValueError):
            continue
        if isinstance(data, dict) and data.get("leadSessionId") == session_id:
            return os.path.dirname(cfg)
    return None


def inbox_state(path):
    """(존재여부, 미소비건수). 파싱 불가는 존재하되 미소비 판정 불가 → -1."""
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except FileNotFoundError:
        return False, 0
    except (OSError, ValueError):
        return True, -1
    if not isinstance(data, list):
        return True, -1
    pending = sum(1 for m in data if not (isinstance(m, dict) and m.get("read") is True))
    return True, pending


def _iter_argv():
    """프로세스별 argv 리스트를 열 폭과 무관하게 돌려준다.

    1순위 /proc/<pid>/cmdline (NUL 구분 — 잘림 없음). /proc 판독이 전무하면 2순위 `ps -eww -o args`.
    `ps -eo args` 는 COLUMNS(tmux 상속 80 등)에 맞춰 잘려 --agent-id 토큰이 끊긴다 (2026-10-10 otest 실측).
    """
    found = False
    for path in glob.glob("/proc/[0-9]*/cmdline"):
        try:
            with open(path, "rb") as f:
                raw = f.read()
        except OSError:
            continue  # 그 사이 종료된 프로세스
        if not raw:
            continue
        found = True
        yield [a.decode("utf-8", "replace") for a in raw.rstrip(b"\0").split(b"\0")]
    if found:
        return
    env = dict(os.environ)
    env.pop("COLUMNS", None)
    try:
        out = subprocess.run(["ps", "-eww", "-o", "args="], capture_output=True, text=True,
                             timeout=5, env=env).stdout
    except (OSError, subprocess.SubprocessError):
        return
    for line in out.splitlines():
        yield line.split()


def argv_has_agent_id(argv, agent_id):
    """argv 에 `--agent-id <agent_id>` (또는 `--agent-id=<agent_id>`) 가 ★토큰 전체 일치★로 있는지.
    접두 오매칭 방지 — odev-1@t 는 odev-10@t 에, x@team 은 x@team2 에 매칭되지 않는다."""
    for i, a in enumerate(argv):
        if a == "--agent-id" and i + 1 < len(argv) and argv[i + 1] == agent_id:
            return True
        if a == "--agent-id=" + agent_id:
            return True
    return False


def process_alive(name, team):
    ff = os.environ.get("SPAWN_ACK_ALIVE_FILE")
    if ff:
        try:
            with open(ff, encoding="utf-8") as f:
                return f.read().strip() == "1"
        except OSError:
            return False
    forced = os.environ.get("SPAWN_ACK_ALIVE")
    if forced in ("0", "1"):
        return forced == "1"
    agent_id = "{}@{}".format(name, team)
    try:
        return any(argv_has_agent_id(argv, agent_id) for argv in _iter_argv())
    except Exception:  # 판독 실패는 '없음' — 기존 동작과 동일
        return False


def log_line(session_id, text):
    d = os.environ.get("SPAWN_ACK_LOG_DIR")
    if not d:
        cfg = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
        sdir = os.path.join(cfg, "session-env", session_id)
        if not os.path.isdir(sdir):  # 자기 세션 디렉토리가 없으면 만들지 않는다
            return
        d = os.path.join(sdir, "logs")
    try:
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "spawn_ack.log"), "a", encoding="utf-8") as f:
            f.write("{} {}\n".format(datetime.now().astimezone().isoformat(timespec="seconds"), text))
    except OSError:
        pass


def parse_target(payload):
    """(name, team, session_id) 또는 None."""
    if not isinstance(payload, dict):
        return None
    ti = payload.get("tool_input") or {}
    name = ti.get("name") if isinstance(ti, dict) else None
    sid = payload.get("session_id")
    if not name or not sid:
        return None
    resp = payload.get("tool_response")
    # 1순위: 실물 PostToolUse(Agent) 의 tool_response 는 dict 다
    #   ({"status":"teammate_spawned","agent_id":"x@team","teammate_id":"x@team","agentId":"x@team",…}).
    if isinstance(resp, dict):
        prefix = name + "@"
        for key in ID_KEYS:
            v = resp.get(key)
            if isinstance(v, str) and v.startswith(prefix):
                team = v[len(prefix):]
                if TEAM_RE.fullmatch(team):
                    return name, team, sid
    # 2순위: 문자열(또는 content 배열 등) — 텍스트 정규식. JSON 직렬화 형태("agent_id": "x@team")도 허용.
    text = resp if isinstance(resp, str) else json.dumps(resp, ensure_ascii=False)
    m = re.search(r"agent_id[\\\"]*\s*:\s*[\\\"]*" + re.escape(name) + r"@([A-Za-z0-9_.\-]+)", text or "")
    if not m:
        return None  # 팀원 spawn 성공 증거 없음 (in-process·실패) → 대상 아님
    return name, m.group(1), sid


RESPAWN_HINT = (
    "프로세스가 없으면 재송신은 닿지 않습니다 → TaskStop(\"{n}\") 으로 남은 작업 항목을 정리한 뒤 "
    "같은 역할·같은 프롬프트로 다시 spawn 하세요(이름은 바꿔도 됩니다 — 2026-10-16 실측 복구는 다른 이름으로 성공). "
    "부하 load1>50 이면 2개씩 20초 시차로 spawn 하세요. 원인(정체 중 팀원 프로세스 소실)은 Claude Code 런타임이라 하네스로 고칠 수 없습니다."
)


def read_load1():
    """/proc/loadavg 1분값 문자열. 판독 실패 시 '?'."""
    try:
        with open(os.environ.get("SPAWN_ACK_LOADAVG_FILE") or "/proc/loadavg", encoding="utf-8") as f:
            v = f.read().split()[0]
        float(v)
        return v
    except (OSError, ValueError, IndexError):
        return "?"


def alert_message(name, elapsed, inbox_desc, alive):
    msg = (
        "⚠️ [spawn-ack] {n} 이 spawn 후 {s}s 동안 첫 지시를 소비하지 않았습니다 "
        "(inbox: {i}, 프로세스: {p}). 같은 지시를 SendMessage(to=\"{n}\") 로 재송신하세요. "
        "재송신 문구에 \"이미 진행 중이면 이어서 진행하라\"를 포함하세요(늦게 기동한 팀원의 2회 수신 대비)."
    ).format(n=name, s=int(elapsed), i=inbox_desc, p="있음" if alive else "없음")
    if not alive:
        msg += " " + RESPAWN_HINT.format(n=name)
    return msg


def lost_message(name, after_ack, load1):
    return (
        "⚠️ [spawn-ack] {n} 이 첫 지시를 소비(ack)한 뒤 {s}s 안에 프로세스가 사라졌습니다 "
        "(shutdown_request 없음, load1={l}). 작업이 중단됐을 가능성이 큽니다. " + RESPAWN_HINT +
        " 리드가 의도적으로 중지(TaskStop)한 팀원이면 이 경보는 무시하세요."
    ).format(n=name, s=int(after_ack), l=load1)


def has_shutdown_request(path):
    """inbox 에 shutdown_request 가 있으면 True (정상 종료 절차를 밟은 것)."""
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return False
    if not isinstance(data, list):
        return False
    for m in data:
        blob = m if isinstance(m, str) else json.dumps(m, ensure_ascii=False)
        if "shutdown_request" in blob:
            return True
    return False


def has_shutdown_sent_flag(name, team, sid, spawn_ts=None):
    """리드가 shutdown_request 를 보낸 기록(자기 세션 session-env 의 agents 플래그)이 있으면 True.
    팀원이 inbox 의 shutdown_request 를 이미 소비해 inbox 에서 사라진 경우를 구제한다.
    자기 sid 디렉터리만 읽는다 (세션 격리: 타 세션 파일은 읽지 않는다).
    같은 이름 재spawn 시 이전 인스턴스의 낡은 플래그를 거르려고, 플래그 시각이 감시 대상 인스턴스의
    spawn 시각(spawn_ts, watcher 시작 벽시계) 이상일 때만 인정한다. 시각을 얻을 수 없으면 불인정."""
    if not name or "/" in name or "\\" in name or ".." in name:
        return False
    try:
        floor = int(spawn_ts) if spawn_ts is not None else None
    except (TypeError, ValueError):
        floor = None
    if floor is None:
        return False
    for base in _candidate_bases():
        sdir = os.path.join(base, "session-env", sid)
        flag = os.path.join(sdir, "agents", name)
        try:
            with open(flag, encoding="utf-8") as f:
                lines = f.read().splitlines()
            fmtime = os.path.getmtime(flag)
        except OSError:
            lines = None
            fmtime = None
        if lines is not None:
            kv = {}
            for ln in lines:
                if "=" in ln:
                    k, v = ln.split("=", 1)
                    kv[k.strip()] = v.strip()
            if kv.get("team", team) == team:
                stamp = None
                if kv.get("shutdown_sent_at"):
                    try:
                        stamp = float(kv["shutdown_sent_at"])
                    except ValueError:
                        stamp = None
                elif kv.get("shutdown_sent") == "true":
                    stamp = fmtime
                if stamp is not None and stamp >= floor:
                    return True
        marker = os.path.join(sdir, "evidence", "shutdown_sent", name)
        try:
            if os.path.getmtime(marker) >= floor:
                return True
        except OSError:
            pass
    return False


def has_shutdown_ack_done(name, sid, spawn_ts=None):
    """팀원이 shutdown_response 를 보낸 기록(자기 세션 session-env 의 ack/shutdown_<name>_*.done)이 있으면 True.
    종료 승인 뒤 agents/<name> 플래그가 정리되고 inbox 의 shutdown_request 도 소비되면 위 두 판정이
    모두 False 가 되어 정상 종료를 소실로 오발화했다(L-690). .done 은 승인 발송의 파일 근거라 이를 인정한다.
    본문 agent=<name> 일치 + approve=true + ts ≥ spawn_ts 인 파일만 인정한다(타 팀원·이전 인스턴스의 낡은 ack 거름).
    approve 줄은 sendmessage_ack_write.sh 가 기록한다. 거부(approve=false)와 approve 줄이 없는 옛 .done 은
    보수적으로 불인정한다 — 불인정이면 종전처럼 소실 경보가 나간다(D-3).
    자기 sid 디렉터리만 읽는다 (세션 격리). 시각을 얻을 수 없으면 불인정."""
    if not name or "/" in name or "\\" in name or ".." in name or "*" in name or "?" in name or "[" in name:
        return False
    try:
        floor = int(spawn_ts) if spawn_ts is not None else None
    except (TypeError, ValueError):
        floor = None
    if floor is None:
        return False
    prefix = "shutdown_" + name + "_"
    for base in _candidate_bases():
        adir = os.path.join(base, "session-env", sid, "ack")
        try:
            entries = os.listdir(adir)
        except OSError:
            continue
        for fn in entries:
            if not (fn.startswith(prefix) and fn.endswith(".done")):
                continue
            try:
                with open(os.path.join(adir, fn), encoding="utf-8") as f:
                    lines = f.read(4096).splitlines()
            except OSError:
                continue
            kv = {}
            for ln in lines:
                if "=" in ln:
                    k, v = ln.split("=", 1)
                    kv[k.strip()] = v.strip()
            if kv.get("agent") != name:
                continue
            if kv.get("approve") != "true":  # D-3: 거부(approve=false)·필드 없는 옛 .done 은 종료 근거가 아니다
                continue
            try:
                ts = int(kv.get("ts", ""))
            except ValueError:
                continue
            if ts >= floor:
                return True
    return False


def watch_alive(name, team, sid, ack_elapsed, start, interval, spawn_ts=None):
    """ack 뒤 생존 감시. 소실 경보면 2, 그 외 0."""
    live = _env_float("SPAWN_LIVE_WAIT", 120.0)
    total_max = _env_float("SPAWN_ACK_TOTAL_MAX", 225.0)
    deadline = min(ack_elapsed + live, total_max)
    misses = 0
    while True:
        elapsed = time.monotonic() - start
        if elapsed >= deadline:
            return 0
        time.sleep(interval)
        elapsed = time.monotonic() - start
        if process_alive(name, team):
            misses = 0
            continue
        misses += 1
        if misses < 2:  # 프로세스 목록 판독의 일시적 누락 대비 — 연속 2회 '없음' 이어야 소실로 본다
            continue
        team_dir = find_team_dir(team, sid)
        if team_dir is None:
            log_line(sid, "live_end name={} team={} reason=team_gone".format(name, team))
            return 0
        inbox = os.path.join(team_dir, "inboxes", name + ".json")
        if not os.path.exists(inbox):
            log_line(sid, "live_end name={} team={} reason=inbox_gone".format(name, team))
            return 0
        if has_shutdown_request(inbox):
            log_line(sid, "live_end name={} team={} reason=shutdown".format(name, team))
            return 0
        if has_shutdown_sent_flag(name, team, sid, spawn_ts):
            log_line(sid, "live_end name={} team={} reason=shutdown_flag".format(name, team))
            return 0
        if has_shutdown_ack_done(name, sid, spawn_ts):
            log_line(sid, "live_end name={} team={} reason=shutdown_ack".format(name, team))
            return 0
        load1 = read_load1()
        log_line(sid, "alert name={} team={} elapsed={}s reason=lost_after_ack after_ack={}s load={}".format(
            name, team, int(elapsed), int(elapsed - ack_elapsed), load1))
        sys.stderr.write(lost_message(name, elapsed - ack_elapsed, load1) + "\n")
        return 2


def watch(name, team, sid):
    wait = _env_float("SPAWN_ACK_WAIT", 150.0)
    interval = _env_float("SPAWN_ACK_INTERVAL", 5.0) or 0.1
    start = time.monotonic()
    spawn_ts = time.time()  # 이번 감시 대상 인스턴스의 spawn 시각(PostToolUse 직후 watcher 시작 시각)
    seen_pending = False
    inbox_desc = "부재"
    alive = False
    while True:
        elapsed = time.monotonic() - start
        team_dir = find_team_dir(team, sid)
        if team_dir is None:
            # 팀 소유를 증명할 수 없다 — 남의 팀이거나 아직 미생성. 기한 내 재시도 후 조용히 종료.
            if elapsed >= wait:
                log_line(sid, "skip name={} team={} reason=team_not_owned".format(name, team))
                return 0
            time.sleep(interval)
            continue
        exists, pending = inbox_state(os.path.join(team_dir, "inboxes", name + ".json"))
        alive = process_alive(name, team)
        if exists and pending > 0:
            seen_pending = True
            inbox_desc = "미소비 {}건".format(pending)
        elif exists and pending == 0:
            inbox_desc = "미소비 0건"
            if alive:
                log_line(sid, "ack name={} team={} elapsed={}s".format(name, team, int(elapsed)))
                return watch_alive(name, team, sid, elapsed, start, interval, spawn_ts)
        elif exists:  # pending == -1
            inbox_desc = "판독불가"
        else:
            inbox_desc = "삭제됨" if seen_pending else "부재"
            if seen_pending:
                msg = alert_message(name, elapsed, inbox_desc, alive)
                log_line(sid, "alert name={} team={} elapsed={}s inbox=deleted alive={}".format(
                    name, team, int(elapsed), int(alive)))
                sys.stderr.write(msg + "\n")
                return 2
        if elapsed >= wait:
            msg = alert_message(name, elapsed, inbox_desc, alive)
            log_line(sid, "alert name={} team={} elapsed={}s inbox={} alive={}".format(
                name, team, int(elapsed), inbox_desc, int(alive)))
            sys.stderr.write(msg + "\n")
            return 2
        time.sleep(interval)


def main():
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        return 0
    target = parse_target(payload)
    if not target:
        return 0
    try:
        return watch(*target)
    except Exception:  # fail-open
        return 0


if __name__ == "__main__":
    sys.exit(main())
