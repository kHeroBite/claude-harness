# 병렬 가능한 팀에이전트를 직렬로 spawn 하는 패턴을 감지해 경고/차단하는 PreToolUse(Agent) 판정 코어
"""
입력: stdin = PreToolUse(Agent) hook JSON
env : PSG_SESSION_DIR(필수), PSG_MODE(off|warn|block), PSG_GAP_SEC(기본 60), PSG_NOW(테스트용 epoch)
출력: stdout 에 PreToolUse hookSpecificOutput JSON (경고=additionalContext, 차단=deny) 또는 무출력

판정 1 — 같은 그룹 직렬 spawn (S1):
  file_assignment.json / plans/phase_batches.json 에서 이번 spawn 대상(tool_input.name)이 속한 그룹
  (batch·wave·phase)을 찾는다. 같은 그룹의 다른 에이전트가 PSG_GAP_SEC 초 이전에 이미 spawn 됐고,
  두 에이전트의 파일 집합이 겹치지 않고, 그룹이 parallel:false 가 아니고, 이번 대상에 선행 의존이 없으면
  "한 메시지에서 동시에 spawn 했어야 할 에이전트를 나중에 따로 spawn" 한 것으로 본다.
  - 같은 이름 재spawn(역라우팅·복구)은 제외한다.
  - 에이전트에 stage(예: "S1", "S4,S5")가 있으면 첫 스테이지가 같은 에이전트끼리만 동시 spawn 대상으로 본다
    (internal_stages 순서 고정 batch 의 오탐 방지, 2026-10-10). 한쪽이라도 stage 가 없으면 기존 판정.
  - 같은 batch 가 pb·fa 양쪽에 있으면 한 번만 판정한다.
  - block 모드: 그룹당 첫 위반 1회만 deny(재시도는 통과 — 업무 정지 방지), 이후는 경고.
판정 2 — 독립 batch 동시 진행 권고 (B1, 항상 경고만):
  phase_batches.json 에서 이번 대상의 batch 와 별개로, 선행(depends_on_batch + extra_depends_on)이
  모두 완료(evidence/batch_N_done 또는 active_phase_batches.json done[])됐고 아직 아무도 spawn 되지 않았으며
  진행 중 batch 들과 파일이 겹치지 않는 batch 가 있으면 "같은 메시지에서 함께 spawn" 을 권고한다.
  같은 (batch, 후보집합) 조합은 세션당 1회만 알린다.
부하 스태거 예외 (2026-10-16 사이클194 (c)):
  load1 > PSG_LOAD(기본 50) 이거나 자기 세션 logs/load_stagger.log 에 최근 PSG_STAGGER_RECENT(기본 300)초 안의
  기록이 있으면 S1·B1 판정을 하지 않고 'SKIP load' 로그만 남긴다. 정체 중에는 PreToolUse_Agent_load_stagger.sh 가
  '2개씩 20초 시차' 를 요구하는데, S1 의 '같은 그룹은 한 응답에서 동시 spawn' 경고가 그 시차를 직렬 spawn 위반으로
  오판해 서로 반대 지시를 내리지 않게 하려는 것이다. spawn 기록(parallel_spawn_log.jsonl)은 그대로 남긴다.
  env: PSG_LOAD, PSG_LOADAVG_FILE(기본 /proc/loadavg, 테스트용), PSG_STAGGER_RECENT
로그: ${PSG_SESSION_DIR}/logs/parallel_spawn_guard.log (판정마다 1줄), spawn 기록은 parallel_spawn_log.jsonl
"""
import json
import os
import re
import sys
import time

SESSION_DIR = os.environ.get("PSG_SESSION_DIR", "")
MODE = os.environ.get("PSG_MODE", "warn")
try:
    GAP = int(os.environ.get("PSG_GAP_SEC", "60"))
except ValueError:
    GAP = 60
try:
    NOW = int(os.environ.get("PSG_NOW", "") or time.time())
except ValueError:
    NOW = int(time.time())


def _load(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def _log(line):
    try:
        d = os.path.join(SESSION_DIR, "logs")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "parallel_spawn_guard.log"), "a", encoding="utf-8") as f:
            f.write("%s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(NOW)), line))
    except Exception:
        pass


def _load_skip_reason():
    """부하 스태거 구간이면 사유 문자열, 아니면 None. 판독 실패는 None(기존 판정 유지)."""
    try:
        thr = float(os.environ.get("PSG_LOAD", "50"))
    except ValueError:
        thr = 50.0
    try:
        with open(os.environ.get("PSG_LOADAVG_FILE") or "/proc/loadavg", "r", encoding="utf-8") as f:
            load1 = float(f.read().split()[0])
        if load1 > thr:
            return "load1=%s" % load1
    except Exception:
        pass
    try:
        recent = int(os.environ.get("PSG_STAGGER_RECENT", "300"))
    except ValueError:
        recent = 300
    try:
        with open(os.path.join(SESSION_DIR, "logs", "load_stagger.log"), "r", encoding="utf-8") as f:
            lines = f.readlines()[-20:]
        for line in reversed(lines):
            parts = line.split()
            if parts and parts[0].isdigit() and NOW - int(parts[0]) <= recent:
                return "stagger_recent=%ds" % (NOW - int(parts[0]))
    except Exception:
        pass
    return None


def _norm_files(v):
    out = set()
    if isinstance(v, list):
        for x in v:
            if isinstance(x, str) and x.strip():
                out.add(x.strip().rstrip("/").lower())
            elif isinstance(x, dict) and isinstance(x.get("path"), str):
                out.add(x["path"].strip().rstrip("/").lower())
    return out


def _first_stage(v):
    """에이전트의 첫 내부 스테이지 번호(stage/stages 필드의 S<n> 중 최소). 없으면 None.
    2026-10-10 c174: batch 11 은 internal_stages S1→S5 순서가 고정인데 가드가 이를 무시하고
    S4 담당(odev-10-3·4·5)을 S1 담당(odev-10-1·2)과 "함께 spawn 했어야 할" 대상으로 경고했다(오탐)."""
    raw = v.get("stage", v.get("stages"))
    if isinstance(raw, list):
        raw = ",".join(str(x) for x in raw)
    if raw is None:
        return None
    nums = [int(n) for n in re.findall(r"[Ss](\d+)", str(raw))]
    return min(nums) if nums else None


def _agents_of(node):
    """그룹 노드에서 {이름: {"files": set, "deps": bool, "stage": int|None}} 추출. 형식: dict(이름→{files}) | list[{name, files}]"""
    res = {}
    if isinstance(node, dict):
        for k, v in node.items():
            if isinstance(v, dict) and ("files" in v or "persona" in v or "tasks" in v):
                deps = v.get("depends_on") or v.get("dependencies") or v.get("after")
                res[str(k)] = {"files": _norm_files(v.get("files")), "deps": bool(deps), "stage": _first_stage(v)}
    elif isinstance(node, list):
        for v in node:
            if isinstance(v, dict) and isinstance(v.get("name"), str):
                deps = v.get("depends_on") or v.get("dependencies") or v.get("after")
                res[v["name"]] = {"files": _norm_files(v.get("files")), "deps": bool(deps), "stage": _first_stage(v)}
    return res


def _same_stage(a, b):
    """두 에이전트가 같은 스테이지에서 동시 착수해야 하는가. 한쪽이라도 스테이지 정보가 없으면 기존 판정(같다고 본다)."""
    return a is None or b is None or a == b


def _groups(doc, source):
    """문서에서 그룹 목록 [(gid, agents, parallel_ok, batch_meta)] 추출"""
    out = []
    if not isinstance(doc, dict):
        return out
    found = False
    for key in ("batches", "waves", "phases"):
        arr = doc.get(key)
        if not isinstance(arr, list):
            continue
        for i, g in enumerate(arr):
            if not isinstance(g, dict):
                continue
            agents = {}
            for sub in ("file_assignment", "agents", "assignments"):
                if sub in g:
                    agents.update(_agents_of(g[sub]))
            if not agents:
                continue
            found = True
            gid_val = g.get("batch_id", g.get("wave", g.get("phase", g.get("id", i + 1))))
            parallel_ok = g.get("parallel", True) is not False
            meta = None
            if key == "batches" and isinstance(g.get("batch_id"), int):
                deps = []
                if isinstance(g.get("depends_on_batch"), int):
                    deps.append(g["depends_on_batch"])
                for x in (g.get("extra_depends_on") or []) + (g.get("depends_on_batches") or []):
                    if isinstance(x, int) and x not in deps:
                        deps.append(x)
                meta = {"batch_id": g["batch_id"], "deps": deps}
            out.append(("%s:%s:%s" % (source, key, gid_val), agents, parallel_ok, meta))
    if not found:
        fa = doc.get("file_assignment")
        if isinstance(fa, (dict, list)) and not isinstance(fa, str):
            sub = _groups(fa if isinstance(fa, dict) else {}, source)
            if sub:
                return sub
            agents = _agents_of(fa)
            if agents:
                out.append(("%s:flat" % source, agents, True, None))
        else:
            agents = _agents_of(doc)
            if agents:
                out.append(("%s:flat" % source, agents, True, None))
    return out


def _cutoff():
    """이번 계획 이전(같은 세션의 지난 사이클) spawn 기록을 배제하는 기준 시각.
    phase_batches.json(불변)이 있으면 그 mtime, 없으면 file_assignment.json mtime."""
    for p in (os.path.join(SESSION_DIR, "plans", "phase_batches.json"),
              os.path.join(SESSION_DIR, "file_assignment.json")):
        try:
            return int(os.path.getmtime(p))
        except Exception:
            continue
    return 0


def _spawn_times():
    """이름 → 이번 계획 이후 최초 spawn epoch. parallel_spawn_log.jsonl + agents/<이름> spawned_at"""
    return _spawn_times_raw(_cutoff())


def _spawn_times_raw(cut):
    t = {}
    p = os.path.join(SESSION_DIR, "parallel_spawn_log.jsonl")
    try:
        with open(p, "r", encoding="utf-8") as f:
            for line in f:
                try:
                    r = json.loads(line)
                    n, ts = r.get("name"), int(r.get("ts", 0))
                    if n and ts >= cut and ts and (n not in t or ts < t[n]):
                        t[n] = ts
                except Exception:
                    continue
    except Exception:
        pass
    ad = os.path.join(SESSION_DIR, "agents")
    try:
        for n in os.listdir(ad):
            if n.endswith(".failed"):
                continue
            try:
                with open(os.path.join(ad, n), "r", encoding="utf-8") as f:
                    for line in f:
                        if line.startswith("spawned_at="):
                            ts = int(line.split("=", 1)[1].strip())
                            if ts >= cut and (n not in t or ts < t[n]):
                                t[n] = ts
            except Exception:
                continue
    except Exception:
        pass
    return t


def _append_spawn(name, gid):
    try:
        with open(os.path.join(SESSION_DIR, "parallel_spawn_log.jsonl"), "a", encoding="utf-8") as f:
            f.write(json.dumps({"ts": NOW, "name": name, "group": gid}, ensure_ascii=False) + "\n")
    except Exception:
        pass


def _marker(name):
    d = os.path.join(SESSION_DIR, "parallel_spawn_guard")
    try:
        os.makedirs(d, exist_ok=True)
    except Exception:
        pass
    return os.path.join(d, name)


def _done_batches():
    done = set()
    ev = os.path.join(SESSION_DIR, "evidence")
    try:
        for n in os.listdir(ev):
            if n.startswith("batch_") and n.endswith("_done"):
                try:
                    done.add(int(n[len("batch_"):-len("_done")]))
                except ValueError:
                    pass
    except Exception:
        pass
    act = _load(os.path.join(SESSION_DIR, "active_phase_batches.json"))
    if isinstance(act, dict):
        for x in act.get("done") or []:
            if isinstance(x, int):
                done.add(x)
    return done


def main():
    if MODE == "off" or not SESSION_DIR or not os.path.isdir(SESSION_DIR):
        return
    try:
        inp = json.loads(sys.stdin.read() or "{}")
    except Exception:
        return
    if inp.get("tool_name") != "Agent":
        return
    ti = inp.get("tool_input") or {}
    name = ti.get("name") if isinstance(ti.get("name"), str) else ""
    name = name.strip()

    groups = []
    groups += _groups(_load(os.path.join(SESSION_DIR, "plans", "phase_batches.json")), "pb")
    groups += _groups(_load(os.path.join(SESSION_DIR, "file_assignment.json")), "fa")
    if not groups:
        return
    if not name:
        desc = str(ti.get("description") or "")
        for _, agents, _, _ in groups:
            for n in agents:
                if n and n in desc:
                    name = n
                    break
            if name:
                break
    if not name:
        return

    mine = [g for g in groups if name in g[1]]
    if not mine:
        return
    times = _spawn_times()
    respawn = name in times
    gid0 = mine[0][0]
    _append_spawn(name, gid0)
    if respawn:
        _log("SKIP respawn name=%s" % name)
        return
    skip = _load_skip_reason()
    if skip:
        _log("SKIP load name=%s %s" % (name, skip))
        return

    msgs = []
    deny = False

    # 판정 1 — 같은 그룹 직렬 spawn
    seen_groups = set()
    for gid, agents, parallel_ok, _ in mine:
        me = agents[name]
        if not parallel_ok or me["deps"]:
            continue
        # 같은 batch 가 phase_batches(pb)와 file_assignment(fa)에 함께 있으면 한 번만 판정한다(중복 경고 방지)
        gkey = gid.split(":", 1)[-1]
        if gkey in seen_groups:
            continue
        seen_groups.add(gkey)
        late_from = []
        for sib, info in agents.items():
            if sib == name or sib not in times:
                continue
            if NOW - times[sib] <= GAP:
                continue
            if me["files"] and info["files"] and (me["files"] & info["files"]):
                continue
            # 내부 스테이지가 다르면(S1 담당 → 나중에 S4 담당) 순서대로 spawn 하는 것이 정상이다
            if not _same_stage(me["stage"], info["stage"]):
                continue
            late_from.append((sib, NOW - times[sib]))
        if not late_from:
            continue
        unspawned = [n for n in agents if n != name and n not in times and not agents[n]["deps"]
                     and _same_stage(me["stage"], agents[n]["stage"])]
        mk = _marker("blocked_" + "".join(c if c.isalnum() else "_" for c in gid))
        first = not os.path.exists(mk)
        sib_txt = ", ".join("%s(%d초 전)" % (s, d) for s, d in sorted(late_from, key=lambda x: -x[1]))
        msgs.append(
            "⚡ [병렬 spawn 가드 S1] '%s' 는 그룹 %s 에서 %s 와 파일이 겹치지 않는데 따로(나중에) spawn 되고 있다. "
            "같은 그룹·파일 비중첩 에이전트는 한 응답에서 Agent() 를 여러 개 동시에 발행해야 한다(odev_parallel·WAVE_SPAWN)."
            % (name, gid, sib_txt)
        )
        if unspawned:
            msgs.append("   → 아직 spawn 안 된 같은 그룹 에이전트: %s — 이번 응답에서 함께 spawn 하라." % ", ".join(unspawned))
        if MODE == "block" and first:
            deny = True
            try:
                with open(mk, "w", encoding="utf-8") as f:
                    f.write("%d %s\n" % (NOW, name))
            except Exception:
                pass
            msgs.append("   → [block] 그룹당 1회 보류됐다. 남은 같은 그룹 에이전트를 같은 응답에 묶어 다시 호출하면 통과한다.")
        _log("%s S1 name=%s group=%s late_from=%s unspawned=%s" % (
            "DENY" if (MODE == "block" and first) else "WARN", name, gid, sib_txt, ",".join(unspawned)))

    # 판정 2 — 독립 batch 동시 진행 권고(경고만)
    pb = [g for g in groups if g[3] is not None]
    if pb:
        my_b = next((g for g in pb if name in g[1]), None)
        if my_b is not None:
            done = _done_batches()
            started = {}
            for gid, agents, _, meta in pb:
                started[meta["batch_id"]] = any(n in times or n == name for n in agents)
            files_of = {}
            for gid, agents, _, meta in pb:
                s = set()
                for v in agents.values():
                    s |= v["files"]
                files_of[meta["batch_id"]] = s
            running = [b for b, st in started.items() if st and b not in done]
            busy = set()
            for b in running:
                busy |= files_of.get(b, set())
            cands = []
            for gid, agents, _, meta in pb:
                b = meta["batch_id"]
                if b == my_b[3]["batch_id"] or b in done or started.get(b):
                    continue
                if not all(d in done for d in meta["deps"]):
                    continue
                if files_of.get(b) and (files_of[b] & busy):
                    continue
                cands.append(b)
                busy |= files_of.get(b, set())  # 후보끼리도 파일이 겹치면 함께 올리지 않는다(batch 순 우선)
            if cands:
                key = "b1_%s_%s" % (my_b[3]["batch_id"], "_".join(str(c) for c in sorted(cands)))
                mk = _marker(key)
                if not os.path.exists(mk):
                    try:
                        with open(mk, "w", encoding="utf-8") as f:
                            f.write("%d\n" % NOW)
                    except Exception:
                        pass
                    msgs.append(
                        "⚡ [병렬 spawn 가드 B1] batch %s 진행과 동시에 착수 가능한 독립 batch: %s "
                        "(선행 완료·미착수·파일 비중첩). ok_pipeline 4.5단계 '독립 batch 병렬' 절차대로 "
                        "active_phase_batches.json 에 함께 올리고 같은 응답에서 odev 를 spawn 하라 "
                        "(예외: 같은 프로젝트 빌드 경합·otest 자원 축은 직렬)." % (my_b[3]["batch_id"], ", ".join(str(c) for c in sorted(cands)))
                    )
                    _log("WARN B1 name=%s batch=%s ready=%s" % (name, my_b[3]["batch_id"], cands))

    if not msgs:
        _log("PASS name=%s group=%s" % (name, gid0))
        return
    text = "\n".join(msgs)
    if deny:
        out = {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                      "permissionDecisionReason": text}}
    else:
        out = {"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": text}}
    sys.stdout.write(json.dumps(out, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # 판정 실패가 업무를 막지 않도록 무출력 종료
        _log("ERROR %r" % (e,))
