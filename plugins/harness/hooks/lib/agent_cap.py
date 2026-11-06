# 세션당 동시 생존 팀에이전트 수를 /proc cmdline 실측으로 세어 상한(최대 10) 초과 spawn 을 차단하는 판정기
"""F-AGENT-CAP — PreToolUse(Agent) 판정 코어 (계획서 10C §3-8 고정 계약).

입력: stdin = hook JSON (session_id, tool_input.name, tool_input.subagent_type)
환경:
  AGENT_CAP_SESSION_BASE  session-env 상위 (기본 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env)
  AGENT_CAP_PROC_ROOT     /proc 대체 (기본 /proc)
  AGENT_CAP_CONFIG        batch_limits.json 경로 (기본 hooks/../config/batch_limits.json)
  AGENT_CAP_NOW           테스트용 epoch 초 (기본 time.time())
  AGENT_CAP_TEAMS_BASE    teams 상위 (기본 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams) — 회수 후보 판독용
  TIG_KEEP_TTL_MIN        agent_keep 유효 분 (기본 120, teammate_idle_guard.py 와 같은 값)
출력: 허용 rc 0 무출력 / 차단 rc 2 + stderr(접두 '🚦 [F-AGENT-CAP]') / 판정 불가 rc 0 (fail-open)
부산물(자기 세션 디렉토리만): agent_cap_slots.json, agent_cap.lock, logs/agent_cap.log
셸 명령(ps 등)은 호출하지 않는다 — 폭 잘림·grep 자기 포함이 구조적으로 없다.

회수 후보(2026-10-11 사용자 지시 "9개 제한에 걸렸다면 대기 중이거나 유휴인 에이전트 중 종료해도 되는 것을
  종료하고 spawn"): 차단 안내에 우선순위 목록을 붙인다. hook 은 SendMessage 를 보낼 수 없으므로 실제 종료는 메인이 한다.
  대상 = 자기 세션 생존 프로세스 중 --agent-id 가 NAME@TEAM(session-env/<sid>/team_name)과 정확히 같은 팀원만.
  제외 = 팀 config isActive 가 False 가 아닌 팀원(작업 중·미상) · 현 인스턴스(joinedAt 이후)의 완료 근거가 없는 팀원.
  1순위 = agent_keep 유효 사유 없음 + 완료 근거(teammate_turn/<name>.json status=final 또는 work/<name>_result.json completed)
  2순위 = agent_keep 유효(역라우팅·재작업 대기) + work/<name>_result.json completed(같은 역할 재spawn 근거)
  판독 실패는 후보 없음(fail-safe — 작업 중 팀원을 후보로 잘못 올리지 않는다).
중복 예약 방지: 같은 이름의 미기동 예약이 이미 있으면 새 예약 없이 허용한다(allow_dup). 상한 판정이
  PreToolUse_Agent_cap.sh(closed 경로)와 parallel_spawn_guard.sh(구 경로) 두 곳에서 같은 spawn 을 판정해도 한 번만 센다.
  allow_dup 때마다 그 예약의 ts 를 now 로 갱신한다 — 재시도·보류가 이어지는 동안 예약이 첫 판정 시점 기준 TTL 로
  소멸해 상한에서 빠지는 일을 막는다(conv_179168980000 항목 3a).
생존 산정(항목 3b): 같은 --agent-id 안의 pid 를 /proc/<pid>/stat ppid 로 조상-자손 관계로 묶어 루트 수만큼 센다.
  한 팀원의 자식 프로세스는 1개로, 같은 agent-id 로 무관하게 살아 있는 두 인스턴스(재spawn 직후 구 인스턴스 잔존)는
  2개로 센다. 그룹 안 stat 판독 실패가 하나라도 있으면 그 그룹은 1개(종전 동작).
예약 유지(항목 3c): TTL(reserve_ttl_sec, 기본 60) 이 지난 예약이라도 팀 config 에 같은 이름 멤버가 있고
  joinedAt/1000 ≥ 예약 ts − 5(=이번 예약 뒤 실제 spawn 됨)이며 그 이름의 새 pid 가 아직 안 보이면
  reserve_max_sec(기본 600, 60~3600) 까지 유지한다. 부하로 프로세스가 늦게 보여도 상한 계산에서 빠지지 않게 한다.
  팀 config 판독 실패 = 종전 TTL 규칙. 한계(정직 고지): spawn 된 팀원이 끝내 보이지 않으면 최대 reserve_max_sec 동안
  예약이 남아 상한이 보수적으로 막힌다 — 차단 안내의 회수 후보·대기열 안내로 처리한다.
"""
import fcntl
import json
import os
import re
import sys
import time
from datetime import datetime

# 사용자 지시(2026-10-11): 세션당 메인 포함 10개 = 동시 생존 팀원 9개 이하. 설정으로 낮출 수는 있으나 넘길 수 없다.
HARD_CEILING = 9
DEFAULT_TTL = 60
DEFAULT_RESERVE_MAX = 600
JOIN_SLACK_SEC = 5
LOCK_WAIT_SEC = 1.5
LOCK_STEP_SEC = 0.05
SID_RE = re.compile(r"^[0-9a-f-]{36}$")
NAME_RX = re.compile(r"^[A-Za-z0-9._-]+$")
KEEP_MIN_REASON = 5
try:
    KEEP_TTL = int(os.environ.get("TIG_KEEP_TTL_MIN", "120")) * 60
except ValueError:
    KEEP_TTL = 120 * 60


def _now():
    v = os.environ.get("AGENT_CAP_NOW")
    if v:
        try:
            return float(v)
        except ValueError:
            pass
    return time.time()


def _log(session_dir, verdict, live, pending, cap, name, extra=""):
    try:
        logs = os.path.join(session_dir, "logs")
        os.makedirs(logs, exist_ok=True)
        line = "%s|%s|live=%s|pending=%s|cap=%s|name=%s%s\n" % (
            datetime.now().astimezone().isoformat(timespec="seconds"),
            verdict, live, pending, cap, name, ("|" + extra) if extra else "")
        with open(os.path.join(logs, "agent_cap.log"), "a", encoding="utf-8") as f:
            f.write(line)
    except Exception:
        pass


def _default_config_path():
    lib_dir = os.path.dirname(os.path.realpath(__file__))
    return os.path.normpath(os.path.join(lib_dir, "..", "..", "config", "batch_limits.json"))


def load_limits():
    """(cap, ttl, clamped, reserve_max) — cap 부재·비정수·범위 밖(1~HARD_CEILING)은 HARD_CEILING 으로 보정한다.
    reserve_max = team_agent_limits.reserve_max_sec (60~3600, 그 밖·부재는 600). ttl 보다 작으면 ttl 로 올린다."""
    path = os.environ.get("AGENT_CAP_CONFIG") or _default_config_path()
    cap, ttl, clamped = HARD_CEILING, DEFAULT_TTL, False
    reserve_max = DEFAULT_RESERVE_MAX
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
        lim = d.get("team_agent_limits") or {}
    except Exception:
        lim = {}
    raw = lim.get("max_live_teammates") if isinstance(lim, dict) else None
    if isinstance(raw, int) and not isinstance(raw, bool) and 1 <= raw <= HARD_CEILING:
        cap = raw
    else:
        clamped = True
    raw_ttl = lim.get("reserve_ttl_sec") if isinstance(lim, dict) else None
    if isinstance(raw_ttl, (int, float)) and not isinstance(raw_ttl, bool) and 1 <= raw_ttl <= 3600:
        ttl = raw_ttl
    raw_max = lim.get("reserve_max_sec") if isinstance(lim, dict) else None
    if isinstance(raw_max, (int, float)) and not isinstance(raw_max, bool) and 60 <= raw_max <= 3600:
        reserve_max = raw_max
    reserve_max = max(reserve_max, ttl)
    return cap, ttl, clamped, reserve_max


def _tok_value(toks, key):
    for i, t in enumerate(toks):
        if t == key and i + 1 < len(toks):
            return toks[i + 1]
        if t.startswith(key + "="):
            return t[len(key) + 1:]
    return None


def _ppid(proc_root, pid):
    """/proc/<pid>/stat 의 ppid. comm 에 ')' 가 들어갈 수 있으므로 마지막 ')' 뒤 둘째 필드를 읽는다. 실패 None."""
    try:
        with open(os.path.join(proc_root, str(pid), "stat"), "rb") as f:
            raw = f.read().decode("utf-8", "replace")
        rest = raw[raw.rindex(")") + 1:].split()
        return int(rest[1])
    except Exception:
        return None


def _count_roots(proc_root, pids):
    """같은 agent-id 그룹 안 루트(부모가 그룹 안에 없는 pid) 수. 하나라도 stat 판독 실패면 1(종전 동작)."""
    if len(pids) <= 1:
        return len(pids)
    group = set(pids)
    roots = 0
    for p in pids:
        pp = _ppid(proc_root, p)
        if pp is None:
            return 1
        if pp not in group:
            roots += 1
    return roots or 1


def scan_live(proc_root, sid):
    """자기 세션 팀원 프로세스 → {agent_key: {"name":..,"pids":[..],"roots":n}}. 타 세션은 세지 않는다.
    roots = 그 agent-id 안에서 서로 조상-자손이 아닌 프로세스 묶음 수(생존 산정 단위)."""
    found = {}
    try:
        entries = os.listdir(proc_root)
    except Exception:
        return found
    for e in entries:
        if not e.isdigit():
            continue
        try:
            with open(os.path.join(proc_root, e, "cmdline"), "rb") as f:
                raw = f.read()
        except Exception:
            continue  # 권한·경합 소멸
        if not raw:
            continue
        toks = [t.decode("utf-8", "replace") for t in raw.split(b"\0") if t]
        if _tok_value(toks, "--parent-session-id") != sid:
            continue
        name = _tok_value(toks, "--agent-name") or ""
        key = _tok_value(toks, "--agent-id") or ("pid:" + e)
        ent = found.setdefault(key, {"name": name, "pids": []})
        ent["pids"].append(int(e))
        if name and not ent["name"]:
            ent["name"] = name
    for ent in found.values():
        ent["roots"] = _count_roots(proc_root, ent["pids"])
    return found


def _n_live(live):
    return sum(int(ent.get("roots") or 1) for ent in live.values())


def _team_members(session_dir):
    """자기 세션 팀 config 의 {이름: 멤버 dict}. 판독 실패 None (reclaim_candidates 와 같은 경로)."""
    try:
        with open(os.path.join(session_dir, "team_name"), encoding="utf-8") as f:
            team = f.read().strip()
        if not NAME_RX.match(team):
            return None
        cfg = _load(os.path.join(_teams_base(), team, "config.json"))
        if not isinstance(cfg, dict):
            return None
        out = {}
        for m in cfg.get("members") or []:
            if isinstance(m, dict) and isinstance(m.get("name"), str):
                out[m["name"]] = m
        return out
    except Exception:
        return None


def _spawned_after(members, name, ts):
    """팀 config 에 name 멤버가 있고 joinedAt/1000 ≥ ts − JOIN_SLACK_SEC 이면 True (이번 예약 뒤 실제 spawn 근거)."""
    m = (members or {}).get(name)
    if not isinstance(m, dict):
        return False
    try:
        joined = float(m.get("joinedAt") or 0) / 1000.0
    except (TypeError, ValueError):
        return False
    return joined > 0 and joined >= ts - JOIN_SLACK_SEC


def _pids_by_name(live, name):
    out = []
    for ent in live.values():
        if ent["name"] == name:
            out.extend(ent["pids"])
    return sorted(out)


def _acquire(lock_path):
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
    deadline = time.monotonic() + LOCK_WAIT_SEC
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except (BlockingIOError, OSError):
            if time.monotonic() >= deadline:
                os.close(fd)
                return None
            time.sleep(LOCK_STEP_SEC)


def _read_slots(path):
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
        return [s for s in d if isinstance(s, dict)] if isinstance(d, list) else []
    except Exception:
        return []


def _write_slots(path, slots):
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(slots, f, ensure_ascii=False)
    os.replace(tmp, path)


def _session_base():
    return os.environ.get("AGENT_CAP_SESSION_BASE") or os.path.join(
        os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude"),
        "session-env")


def _teams_base():
    return os.environ.get("AGENT_CAP_TEAMS_BASE") or os.path.join(
        os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude"),
        "teams")


def _load(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def _keep_mtime(session_dir, name, now):
    """agent_keep/<name> 이 유효(사유 5자 이상, KEEP_TTL 이내)하면 mtime, 아니면 None (teammate_idle_guard.keep_status 와 같은 기준)"""
    p = os.path.join(session_dir, "agent_keep", name)
    try:
        with open(p, encoding="utf-8", errors="replace") as f:
            reason = f.read().strip()
        mt = os.path.getmtime(p)
    except OSError:
        return None
    if len(reason.replace(" ", "")) < KEEP_MIN_REASON or now - mt > KEEP_TTL:
        return None
    return mt


def reclaim_candidates(session_dir, live, now):
    """상한 도달 시 회수 후보 ([1순위 이름], [2순위 이름]). 판독 실패·근거 부족은 후보에서 뺀다(fail-safe)."""
    try:
        with open(os.path.join(session_dir, "team_name"), encoding="utf-8") as f:
            team = f.read().strip()
        if not NAME_RX.match(team):
            return [], []
        cfg = _load(os.path.join(_teams_base(), team, "config.json"))
        if not isinstance(cfg, dict):
            return [], []
        members = {}
        for m in cfg.get("members") or []:
            if isinstance(m, dict) and isinstance(m.get("name"), str):
                members[m["name"]] = m
        t1, t2 = [], []
        for key, ent in live.items():
            name = ent.get("name") or ""
            # 소유 증명: 자기 세션 프로세스(--parent-session-id) + --agent-id 가 NAME@TEAM 정확 일치
            if not NAME_RX.match(name) or name == "team-lead" or key != "%s@%s" % (name, team):
                continue
            m = members.get(name)
            if not m:
                continue
            act = m.get("isActive")
            if not (act is False or str(act).lower() == "false"):
                continue  # 작업 중(True) 또는 미상 → 절대 후보 아님
            try:
                joined = float(m.get("joinedAt") or 0) / 1000.0
            except (TypeError, ValueError):
                joined = 0.0
            done_at = 0.0
            tt = _load(os.path.join(session_dir, "teammate_turn", name + ".json"))
            if isinstance(tt, dict) and tt.get("status") == "final" and tt.get("team") in (None, "", team):
                try:
                    up = float(tt.get("updated") or 0)
                except (TypeError, ValueError):
                    up = 0.0
                if up and up >= joined:
                    done_at = up
            res_at = 0.0
            rp = os.path.join(session_dir, "work", name + "_result.json")
            res = _load(rp)
            if isinstance(res, dict) and res.get("status") == "completed":
                try:
                    mt = os.path.getmtime(rp)
                except OSError:
                    mt = 0.0
                if mt and mt >= joined:
                    res_at = mt  # 현 인스턴스가 남긴 완료 결과(재spawn 근거)
            keep = _keep_mtime(session_dir, name, now)
            if keep is not None:
                if res_at:
                    t2.append((keep, name))
            elif done_at or res_at:
                t1.append((max(done_at, res_at), name))
        return [n for _, n in sorted(t1)], [n for _, n in sorted(t2)]
    except Exception:
        return [], []


def _reclaim_text(t1, t2):
    if not t1 and not t2:
        return ("회수 후보 없음(작업 중이거나 완료 근거를 읽지 못함 — 작업 중 팀원은 회수하지 않는다). "
                "남은 spawn 은 ② 대기열로 두십시오.")
    parts = []
    if t1:
        parts.append("1순위(완료 보고 후 유휴): %s" % ", ".join(t1))
    if t2:
        parts.append("2순위(agent_keep 역라우팅·재작업 대기, result.json 완료): %s" % ", ".join(t2))
    return ("회수 후보(우선순위 순, 작업 중 팀원 제외) — %s. 회수 후보에게 shutdown_request 를 보내고 "
            "pane 소멸 확인 후 재시도하십시오. hook 은 메시지를 보낼 수 없으므로 종료는 메인이 수행합니다. "
            "2순위를 회수했다면 agent_keep/<이름> 을 지우고, 필요할 때 work/<이름>_result.json 을 근거로 "
            "같은 역할을 다시 spawn 하십시오." % " / ".join(parts))


def _salvage_dir(raw):
    """파손 JSON 에서도 session_id 를 건지면 그 세션 로그에 failopen 을 남긴다."""
    m = re.search(r'"session_id"\s*:\s*"([0-9a-f-]{36})"', raw or "")
    if not m:
        return None
    d = os.path.join(_session_base(), m.group(1))
    return d if os.path.isdir(d) else None


def main():
    raw = ""
    try:
        raw = sys.stdin.read()
        data = json.loads(raw or "")
    except Exception:
        return _failopen(_salvage_dir(raw), "bad_json")
    if not isinstance(data, dict):
        return _failopen(_salvage_dir(raw), "bad_json")
    ti = data.get("tool_input") or {}
    if not isinstance(ti, dict):
        ti = {}
    name = ti.get("name")
    name = name.strip() if isinstance(name, str) else ""
    # 판정 대상: 메인(PIPELINE_UUID 없음) + 이름 있는 비-fork 호출 = 팀원 spawn 의도
    if os.environ.get("PIPELINE_UUID"):
        return 0
    if not name or ti.get("subagent_type") == "fork":
        return 0
    sid = data.get("session_id")
    if not isinstance(sid, str) or not SID_RE.match(sid):
        return _failopen(None, "bad_sid")
    session_dir = os.path.join(_session_base(), sid)
    if not os.path.isdir(session_dir):
        return _failopen(None, "no_session_dir")
    proc_root = os.environ.get("AGENT_CAP_PROC_ROOT") or "/proc"

    try:
        cap, ttl, clamped, reserve_max = load_limits()
        if clamped:
            _log(session_dir, "config_clamped", "-", "-", cap, name)
        fd = _acquire(os.path.join(session_dir, "agent_cap.lock"))
        if fd is None:
            _log(session_dir, "deny", "-", "-", cap, name, "lock_timeout")
            sys.stderr.write(
                "🚦 [F-AGENT-CAP] 상한 판정 잠금 경합으로 spawn '%s' 을 이번 1회 보류합니다. "
                "같은 spawn 호출을 즉시 다시 보내십시오.\n" % name)
            return 2
        try:
            now = _now()
            live = scan_live(proc_root, sid)
            slots_path = os.path.join(session_dir, "agent_cap_slots.json")
            kept = []
            members = None   # 팀 config — TTL 경과 예약이 있을 때만 1회 판독
            members_read = False
            for s in _read_slots(slots_path):
                try:
                    ts = float(s.get("ts", 0))
                except (TypeError, ValueError):
                    continue
                pre = set(s.get("pre_pids") or [])
                if any(p not in pre for p in _pids_by_name(live, s.get("name", ""))):
                    continue  # 같은 이름 새 pid 등장 = 실제 기동됨 → 실프로세스로 치환
                if now - ts > ttl:
                    # TTL 경과 — spawn 실패 등으로 남은 예약은 소멸. 단 팀 config 가 이번 예약 뒤 실제 spawn 을
                    # 증명하고(새 pid 는 아직 안 보임) reserve_max 이내면 유지한다(부하로 기동이 늦게 보이는 경우).
                    if now - ts > reserve_max:
                        continue
                    if not members_read:
                        members, members_read = _team_members(session_dir), True
                    if not _spawned_after(members, s.get("name", ""), ts):
                        continue
                kept.append(s)
            n_live, n_pend = _n_live(live), len(kept)
            if any(s.get("name") == name for s in kept):
                # 같은 이름의 미기동 예약이 이미 있다 = 이미 허용된 같은 spawn(두 판정 경로·재시도) → 새 예약 없이 허용.
                # 재시도마다 예약 ts 를 now 로 연장한다 — 보류·재시도가 이어지는 동안 첫 판정 기준 TTL 로 소멸하지 않게.
                for s in kept:
                    if s.get("name") == name:
                        s["ts"] = now
                _write_slots(slots_path, kept)
                _log(session_dir, "allow_dup", n_live, n_pend, cap, name)
                return 0
            if n_live + n_pend >= cap:
                _write_slots(slots_path, kept)
                names = sorted({e["name"] or "?" for e in live.values()})
                t1, t2 = reclaim_candidates(session_dir, live, now)
                _log(session_dir, "deny", n_live, n_pend, cap, name,
                     "reclaim=t1:%s;t2:%s" % (",".join(t1) or "-", ",".join(t2) or "-"))
                sys.stderr.write(
                    "🚦 [F-AGENT-CAP] 이 세션의 동시 생존 팀에이전트가 상한 %d개에 도달했습니다"
                    "(생존 %d + 기동 대기 %d). spawn '%s' 을 보류합니다. "
                    "① 보고를 끝낸 팀원에게 shutdown_request 를 보내 종료시킨 뒤 같은 spawn 을 다시 보내십시오. "
                    "② 남은 spawn 은 대기열로 두고 팀원이 끝날 때마다 하나씩 보내십시오. "
                    "생존 팀원: %s\n%s\n" % (cap, n_live, n_pend, name, ", ".join(names) or "-",
                                            _reclaim_text(t1, t2)))
                return 2
            kept.append({"name": name, "ts": now, "pre_pids": _pids_by_name(live, name)})
            _write_slots(slots_path, kept)
            _log(session_dir, "allow", n_live, n_pend, cap, name)
            return 0
        finally:
            try:
                fcntl.flock(fd, fcntl.LOCK_UN)
            finally:
                os.close(fd)
    except Exception as ex:  # 판정 자체가 불가능한 경우에만 연다
        return _failopen(session_dir, "exception:%s" % type(ex).__name__)


def _failopen(session_dir, why):
    if session_dir:
        _log(session_dir, "failopen", "-", "-", "-", "-", why)
    return 0


if __name__ == "__main__":
    sys.exit(main())
