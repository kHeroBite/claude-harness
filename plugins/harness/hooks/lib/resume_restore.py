#!/usr/bin/env python3
# 재기동 뒤 보존 사본(resume_preserve)과 에이전트 스냅샷(agent_state)으로 파이프라인 복원 계획을 만드는 복원기
"""resume_restore.py — oresume Step 1·8 이 호출하는 재기동 복원기 (계획 s10D §3-7).

사용법
  python3 resume_restore.py --check <session_dir>
  python3 resume_restore.py --plan  <session_dir> [--lead-session <현재 메인 sessionId>]

종료코드
  0 = 복원 가능(보존본 있음 + 재개 가능 파이프라인)
  3 = 보존본 없음 또는 재개 대상 아님(완료된 파이프라인 등)
  4 = 보존본 파싱 실패 또는 인자 오류
  5 = state·checkpoint 불일치(완료 기록이 최신인데 live state 또는 그 뒤 보존본이 PLAN·DEV·TEST·DONE)
      — reason=state_checkpoint_mismatch. 자동 재개·완료 판정 금지, 메타 수동 확인

쓰기 경로 (이 셋뿐이다)
  <session_dir>/work/respawn/<name>.md
  <session_dir>/agent_state/restore_log.jsonl
  (그 외 state·classification·entry_tier·status·team_name·conv_id 는 직접 쓰지 않는다.
   oresume 이 mcp__oio__session_state(force=true) 로 적는다 — write_guard Fix 3·O7 존중)
  (auto·oroof_active·goal.json·rollback_hash 도 직접 쓰지 않는다 — oresume 이 file_copy·session_state 로 적는다.
   agents/<name> 의 옛 pane 기록 무효화도 oresume 이 file_write 로 한다 — 이 스크립트는 stale_agent_records[] 만 낸다)

판단이 서지 않으면 재수행(missing) 쪽으로 기운다 (L-670 원칙).

시험 주입 환경변수
  RR_TEST_BOOT_ID  현재 boot_id 대신 쓸 값
  RR_TEAMS_DIR     teams 디렉토리 대신 쓸 경로
"""
import calendar
import json
import os
import sys
import tempfile
import time

KNOWN_EVENTS = {
    "OK_START", "OK_CLASSIFY_DONE",
    "PLAN_START", "PLAN_DONE",
    "DEV_START", "DEV_AGENT_DONE", "DEV_TODO_DONE", "DEV_REVIEW_DONE", "DEV_ALL_DONE",
    "TEST_START", "TEST_PHASE1_DONE", "TEST_PHASE2_DONE", "TEST_PHASE3_DONE", "TEST_ALL_DONE",
    "DONE_START", "DONE_SUBSTEP", "DONE_ALL_DONE",
    "FINISH_DONE", "BATCH_NEXT", "BATCH_PAUSE", "BATCH_ABORT",
}
START_EVENTS = {"OK_START", "PLAN_START", "DEV_START", "TEST_START", "DONE_START"}
NON_IDLE = {"PLAN", "DEV", "TEST", "DONE", "FINISH", "EARLY_TERM", "ERROR"}
# 마지막 이벤트 → 복원할 stage (보존 state 가 비었을 때만 쓴다)
EVENT_STAGE = {
    "OK_START": "PLAN", "OK_CLASSIFY_DONE": "PLAN", "PLAN_START": "PLAN", "PLAN_DONE": "DEV",
    "DEV_START": "DEV", "DEV_AGENT_DONE": "DEV", "DEV_TODO_DONE": "DEV", "DEV_REVIEW_DONE": "DEV",
    "DEV_ALL_DONE": "TEST", "TEST_START": "TEST", "TEST_PHASE1_DONE": "TEST",
    "TEST_PHASE2_DONE": "TEST", "TEST_PHASE3_DONE": "TEST", "TEST_ALL_DONE": "DONE",
    "DONE_START": "DONE", "DONE_SUBSTEP": "DONE", "DONE_ALL_DONE": "FINISH",
    "BATCH_NEXT": "DEV",
}
TEXT_MAX = 4096
SPAWN_MAX = 65536
START_SLACK_SEC = 120


class RestoreError(Exception):
    """보존본 파싱 실패 (rc=4)."""


def _read_text(path, limit=None):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            data = fh.read() if limit is None else fh.read(limit)
        return data
    except OSError:
        return None


def _read_json(path):
    raw = _read_text(path)
    if raw is None:
        return None
    try:
        return json.loads(raw)
    except ValueError:
        return None


def _first_line(path):
    raw = _read_text(path)
    if raw is None:
        return ""
    raw = raw.strip()
    return raw.splitlines()[0].strip() if raw else ""


def _atomic_write(path, text):
    """같은 디렉토리 tmp → fsync → os.replace → 디렉토리 fsync."""
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".rr_tmp.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    try:
        dfd = os.open(d, os.O_RDONLY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    except OSError:
        pass


def _clip(text, limit=TEXT_MAX):
    if text is None:
        return ""
    if not isinstance(text, str):
        text = json.dumps(text, ensure_ascii=False)
    return text if len(text) <= limit else text[:limit] + "\n…(절단)"


def current_boot_id():
    v = os.environ.get("RR_TEST_BOOT_ID")
    if v:
        return v.strip()
    return (_first_line("/proc/sys/kernel/random/boot_id") or "").strip()


def _parse_ts(ts):
    """checkpoint_write.sh 의 ts 는 UTC ISO8601(초 단위, tz 표기 없음)."""
    try:
        return calendar.timegm(time.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S"))
    except (TypeError, ValueError):
        return None


def load_events(sd):
    """checkpoint.jsonl → 알려진 이벤트 목록 (STATE_TRANSITION·REROUTE·파싱 실패 줄 제외)."""
    raw = _read_text(os.path.join(sd, "checkpoint.jsonl"))
    events = []
    if not raw:
        return events
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if isinstance(ev, dict) and ev.get("event") in KNOWN_EVENTS:
            events.append(ev)
    return events


def load_preserve(sd):
    """resume_preserve/latest.json + 보존 디렉토리 → dict. 없으면 None, 깨지면 RestoreError."""
    pdir_root = os.path.join(sd, "resume_preserve")
    latest_path = os.path.join(pdir_root, "latest.json")
    if not os.path.isfile(latest_path):
        return None
    latest = _read_json(latest_path)
    if not isinstance(latest, dict):
        raise RestoreError("latest.json 파싱 실패")
    pdir = latest.get("dir") or ""
    if pdir and not os.path.isabs(pdir):
        pdir = os.path.join(pdir_root, pdir)
    # 보존 디렉토리는 반드시 자기 세션의 resume_preserve 아래여야 한다 (§(a))
    if pdir:
        real_root = os.path.realpath(pdir_root)
        if not os.path.realpath(pdir).startswith(real_root + os.sep):
            raise RestoreError("보존 디렉토리가 자기 세션 밖을 가리킨다: " + pdir)
    latest["_pdir"] = pdir if pdir and os.path.isdir(pdir) else ""

    def pick(field, fname=None):
        v = latest.get(field)
        if isinstance(v, str) and v.strip():
            return v.strip()
        if latest["_pdir"]:
            return _first_line(os.path.join(latest["_pdir"], fname or field))
        return ""

    latest["_state_line"] = pick("state_line", "state")
    latest["_conv_id"] = pick("conv_id")
    latest["_classification"] = pick("classification")
    latest["_entry_tier"] = pick("entry_tier")
    latest["_team_name"] = pick("team_name")
    latest["_status"] = _first_line(os.path.join(latest["_pdir"], "status")) if latest["_pdir"] else ""
    # 자율모드 부속(auto·rollback_hash 값, goal·oroof 보존본 경로) — 경로는 보존 디렉토리 하위만 인정한다
    _pd = latest["_pdir"]
    latest["_auto"] = _first_line(os.path.join(_pd, "auto"))[:16] if _pd else ""
    latest["_rollback_hash"] = _first_line(os.path.join(_pd, "rollback_hash"))[:64] if _pd else ""
    files = {}
    # ROOF-COMPAT(deprecation window 1주기 — 구 RALPH/oralph_active 인식 제거 예정): 구 보존본 이름도 읽는다
    for _fn in ("goal.json", "oroof_active", "oroof_active.json", "oralph_active", "oralph_active.json"):
        _p = os.path.join(_pd, _fn) if _pd else ""
        if _p and os.path.isfile(_p) and os.path.realpath(_p).startswith(os.path.realpath(_pd) + os.sep):
            files[_fn] = _p
        else:
            files[_fn] = ""
    latest["_files"] = files
    return latest


def ofinish_marker_current(sd):
    """evidence/ofinish_done 이 checkpoint.jsonl 이후(같은 시각 포함)에 쓰였으면 True. 체크포인트가 없으면 마커만으로 판단."""
    marker = os.path.join(sd, "evidence", "ofinish_done")
    if not os.path.exists(marker):
        return False
    ckpt = os.path.join(sd, "checkpoint.jsonl")
    try:
        return os.path.getmtime(marker) >= os.path.getmtime(ckpt)
    except OSError:
        return True


def last_raw_event(sd):
    """checkpoint.jsonl 의 마지막 이벤트 이름(REROUTE 포함, STATE_TRANSITION 제외) — 보고용."""
    raw = _read_text(os.path.join(sd, "checkpoint.jsonl")) or ""
    for line in reversed(raw.splitlines()):
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if isinstance(ev, dict) and ev.get("event") and ev.get("event") != "STATE_TRANSITION":
            return ev.get("event")
    return ""


ACTIVE_STAGES = {"PLAN", "DEV", "TEST", "DONE"}


def _live_state(sd):
    """sd/state 첫 토큰 (없으면 빈 문자열)."""
    return (_first_line(os.path.join(sd, "state")).split() or [""])[0]


def _finish_mismatch(sd, pres, events, last_event, last_raw):
    """완료 기록이 최신인데 state 가 진행 중을 가리키면 rc=5 정보 dict, 아니면 None.

    (a) live state 가 PLAN·DEV·TEST·DONE 이거나
    (b) 보존본 state_line 첫 토큰이 PLAN·DEV·TEST·DONE 이고 saved_at 이 완료 시각보다 뒤이면 불일치다.
    완료 시각은 마지막 FINISH_DONE 의 ts(UTC), 그것이 없으면 evidence/ofinish_done 의 mtime 이다.
    """
    if last_event == "FINISH_DONE":
        fin_at = _parse_ts(events[-1].get("ts"))
    elif ofinish_marker_current(sd):
        try:
            fin_at = int(os.path.getmtime(os.path.join(sd, "evidence", "ofinish_done")))
        except OSError:
            fin_at = None
    else:
        return None
    live = _live_state(sd)
    pres_tok = (pres["_state_line"].split() or [""])[0]
    try:
        saved_at = int(pres.get("saved_at"))
    except (TypeError, ValueError):
        saved_at = None
    pres_after = (pres_tok in ACTIVE_STAGES and saved_at is not None
                  and fin_at is not None and saved_at > fin_at)
    if live not in ACTIVE_STAGES and not pres_after:
        return None
    return {"resumable": False, "reason": "state_checkpoint_mismatch", "live_state": live,
            "preserved_state": pres_tok, "preserved_saved_at": saved_at, "finish_at": fin_at,
            "last_event": last_event, "last_raw_event": last_raw,
            "detail": "완료 기록과 state 가 어긋난다 — 자동 재개·완료 판정 금지, 메타 수동 확인"}


def judge(sd):
    """복원 가능 여부 판정 → (rc, info)."""
    try:
        pres = load_preserve(sd)
    except RestoreError as exc:
        return 4, {"resumable": False, "reason": "parse_error", "detail": str(exc)}
    if pres is None:
        return 3, {"resumable": False, "reason": "no_preserve"}
    events = load_events(sd)
    last_event = events[-1]["event"] if events else ""
    last_raw = last_raw_event(sd)
    # [c199 건6 2026-10-24] 완료 기록(FINISH_DONE·ofinish_done)이 최신이어도 live state 나 그 뒤 보존본이
    #   진행 중 stage 를 가리키면 "끝남" 이 아니다 — Mars c197 은 DEV 진입 이벤트를 남기지 않아
    #   마지막 유효 이벤트가 c196 FINISH_DONE 이었고 rc=3 finished 로 오판했다(L-1365).
    mm = _finish_mismatch(sd, pres, events, last_event, last_raw)
    if mm is not None:
        return 5, mm
    if last_event == "FINISH_DONE":
        return 3, {"resumable": False, "reason": "finished", "last_event": last_event, "last_raw_event": last_raw}
    # [c193 oi-fix-2 2026-10-19] ofinish_done 은 checkpoint.jsonl 보다 새것(같은 시각 포함)일 때만 "끝남" 이다.
    #   사고: 10-16 20:09 옛 사이클의 마커가 남아 10-17 02:13 까지 이어진 현 파이프라인(마지막 REROUTE→TEST)을
    #   rc=3 ofinish_done 으로 오판했다. resume_preserve.sh _rp_ckpt_open 과 같은 기준(mtime 비교)으로 맞춘다.
    if ofinish_marker_current(sd):
        return 3, {"resumable": False, "reason": "ofinish_done", "last_event": last_event, "last_raw_event": last_raw}
    state_source = "checkpoint"
    if not events:
        # [pd 실사용] checkpoint 에 STATE_TRANSITION 뿐이어도 보존본 state 가 진행 중이면 재개한다.
        #   위 rc=5·FINISH_DONE·ofinish_done 판정을 모두 통과한 뒤에만 도달한다(순서 유지).
        if (pres["_state_line"].split() or [""])[0] not in ACTIVE_STAGES:
            return 3, {"resumable": False, "reason": "no_checkpoint"}
        state_source = "preserve_fallback"
    state_tok = (pres["_state_line"].split() or [""])[0]
    if state_tok not in NON_IDLE:
        state_tok = EVENT_STAGE.get(last_event, "")
    if not state_tok:
        return 3, {"resumable": False, "reason": "no_stage", "last_event": last_event}
    cur_boot = current_boot_id()
    prev_boot = (pres.get("prev_boot_id") or "").strip()
    # [c193] reason=boot 이라도 prev_boot_id == 현재 boot_id 면 재부팅이 아니다(10-19 오발동 보존본 실측)
    if prev_boot and cur_boot:
        boot_changed = prev_boot != cur_boot
    else:
        boot_changed = pres.get("reason") == "boot"
    saved_at = pres.get("saved_at")
    try:
        age = int(time.time()) - int(saved_at)
    except (TypeError, ValueError):
        age = None
    info = {
        "resumable": True, "reason": pres.get("reason", ""), "saved_at": saved_at, "age_sec": age,
        "conv_id": pres["_conv_id"], "state": state_tok, "classification": pres["_classification"],
        "last_event": last_event, "last_raw_event": last_raw, "boot_changed": boot_changed, "current_boot_id": cur_boot,
        "preserve_dir": pres["_pdir"], "state_source": state_source, "_pres": pres, "_events": events,
    }
    return 0, info


def _teams_dir():
    v = os.environ.get("RR_TEAMS_DIR")
    if v:
        return v
    base = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
    return os.path.join(base, "teams")


def find_current_team(uuid, lead_session, sd):
    """§(b) 소유권 증명 — config.json leadSessionId 가 UUID 또는 현재 메인 sessionId 인 팀."""
    tdir = _teams_dir()
    try:
        names = sorted(os.listdir(tdir))
    except OSError:
        names = []
    owners = {uuid}
    if lead_session:
        owners.add(lead_session)
    hits = []
    for name in names:
        cfg = _read_json(os.path.join(tdir, name, "config.json"))
        if isinstance(cfg, dict) and cfg.get("leadSessionId") in owners:
            hits.append(name)
    if len(hits) == 1:
        return hits[0], "leadSessionId"
    if len(hits) > 1:
        # 둘 이상이면 현재 team_name 파일과 일치하는 것만 인정, 아니면 소유 불확실(fail-closed)
        cur = _first_line(os.path.join(sd, "team_name"))
        if cur in hits:
            return cur, "leadSessionId+team_name"
        return "", "ambiguous"
    return "", "none"


def _agents_registry(sd):
    """agents/<name> key=value 파일 → {name: dict}."""
    out = {}
    adir = os.path.join(sd, "agents")
    try:
        names = sorted(os.listdir(adir))
    except OSError:
        return out
    for name in names:
        if name.startswith("."):
            continue
        raw = _read_text(os.path.join(adir, name)) or ""
        kv = {}
        for line in raw.splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                kv[k.strip()] = v.strip()
        out[name] = kv
    return out


def _snapshots(sd):
    out = {}
    sdir = os.path.join(sd, "agent_state")
    try:
        names = sorted(os.listdir(sdir))
    except OSError:
        return out
    for fn in names:
        if not fn.endswith(".json") or fn.startswith(("_", ".", "sub_")):
            continue
        snap = _read_json(os.path.join(sdir, fn))
        if isinstance(snap, dict):
            out[fn[:-5]] = snap
    return out


def _last_start_epoch(events):
    for ev in reversed(events):
        if ev.get("event") in START_EVENTS:
            return _parse_ts(ev.get("ts", ""))
    return None


def _fallback_start_epoch(sd):
    """이벤트가 없을 때의 시작 시각 — STATE_TRANSITION 중 from=IDLE 인 마지막 줄의 ts(없으면 None)."""
    raw = _read_text(os.path.join(sd, "checkpoint.jsonl")) or ""
    for line in reversed(raw.splitlines()):
        line = line.strip()
        if not line or "from=IDLE" not in line:
            continue
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if isinstance(ev, dict) and ev.get("event") == "STATE_TRANSITION":
            t = _parse_ts(ev.get("ts", ""))
            if t is not None:
                return t
    return None


def _subagents(sd, start_epoch):
    """agent_state/sub_*.json → 이번 사이클 서브에이전트 목록(updated_at 오름차순). start_epoch 없으면 []."""
    if start_epoch is None:
        return []
    sdir = os.path.join(sd, "agent_state")
    try:
        names = sorted(os.listdir(sdir))
    except OSError:
        return []
    out = []
    for fn in names:
        if not (fn.startswith("sub_") and fn.endswith(".json")):
            continue
        snap = _read_json(os.path.join(sdir, fn))
        if not isinstance(snap, dict):
            continue
        try:
            upd = int(snap.get("updated_at"))
        except (TypeError, ValueError):
            continue
        if upd >= start_epoch - START_SLACK_SEC:
            out.append({"agent_id": snap.get("agent_id") or fn[4:-5], "agent_type": snap.get("agent_type", ""),
                        "updated_at": upd, "transcript_hint": snap.get("transcript_hint", "")})
    out.sort(key=lambda s: s["updated_at"])
    return out


def _respawn_prompt(sd, uuid, name, role, conv_id, snap, result, status, todos_done, todos_left, files):
    spawn = _read_text(os.path.join(sd, "agent_state", name + ".spawn.md"), SPAWN_MAX)
    if not spawn or not spawn.strip():
        # spawn 원문이 없으면 최소 프롬프트로 대신한다 (정직 고지 포함)
        spawn = (
            "PIPELINE_UUID={u}\n\n당신은 {n} 이다. Skill('{r}') 를 호출해 스킬을 로딩한 뒤 실행하라.\n"
            "(spawn 프롬프트 원문 사본이 없어 최소 프롬프트로 재구성했다. 담당 범위는 아래 복원 컨텍스트와 계획서를 따른다.)\n"
        ).format(u=uuid, n=name, r=role or "odev")
    li = snap.get("last_instruction") or {}
    lr = snap.get("last_report") or {}
    lines = [
        spawn.rstrip(),
        "",
        "---",
        "",
        "## 재기동 복원 컨텍스트",
        "",
        "- 이 프롬프트는 /oresume 이 재기동(또는 비정상 종료) 뒤 같은 이름으로 다시 띄우는 것이다. 이전 {n} 프로세스는 사라졌다.".format(n=name),
        "- 팀원 대화 원본의 재개는 공식 미지원이다(https://code.claude.com/docs/en/agent-teams Limitations). 아래 요약과 결과 파일로 이어서 작업한다.",
        "- PIPELINE_UUID={u}, conv_id={c} (복원된 값이다. 결과 파일에도 이 conv_id 를 그대로 쓴다).".format(u=uuid, c=conv_id),
        "- 복원 판정: {s}".format(s=status),
        "",
        "### 마지막 지시 (team-lead → {n})".format(n=name),
        _clip(li.get("text")) or "(기록 없음)",
        "",
        "### 마지막 보고 ({n} → {t})".format(n=name, t=lr.get("to") or "team-lead"),
        _clip(lr.get("text")) or "(기록 없음)",
        "",
        "### 완료 TODO (재수행 금지)",
    ]
    lines += ["- " + _clip(str(t), 400) for t in todos_done] or ["- (없음)"]
    lines += ["", "### 남은 TODO"]
    lines += ["- " + _clip(str(t), 400) for t in todos_left] or ["- (기록 없음 — 계획서 기준으로 남은 일을 판정하라)"]
    lines += ["", "### 이미 수정한 파일 (결과 파일 files_modified)"]
    fm = (result or {}).get("files_modified") or []
    lines += ["- " + str(f) for f in fm] or ["- (없음)"]
    if files:
        lines += ["", "### 단독 소유 파일"] + ["- " + str(f) for f in files]
    tp = snap.get("transcript_path") or ""
    lines += [
        "",
        "### 원본 트랜스크립트",
        "- 경로: {p}".format(p=tp or "(기록 없음)"),
        "- 원본 대화는 공식적으로 복원 불가하다. 필요하면 mcp__oio__file_read 로 꼬리만 참고하라.",
        "",
        "작업 대상 파일의 현재 내용을 직접 다시 읽고, 질문 없이 이어서 진행하라. 완료 시 결과 파일과 SendMessage(to=\"team-lead\") 보고는 원래 지시대로 한다.",
        "",
    ]
    return "\n".join(lines)


def build_plan(sd, info, lead_session=""):
    pres = info["_pres"]
    events = info["_events"]
    uuid = os.path.basename(os.path.normpath(sd))
    conv_id = info["conv_id"]
    team_cur, team_src = find_current_team(uuid, lead_session, sd)
    registry = _agents_registry(sd)
    snaps = _snapshots(sd)
    fa = _read_json(os.path.join(sd, "file_assignment.json")) or {}
    fa_agents = fa.get("agents") if isinstance(fa, dict) and isinstance(fa.get("agents"), dict) else {}

    start_epoch = _last_start_epoch(events)
    if start_epoch is None:
        start_epoch = _fallback_start_epoch(sd)
    targets = set()
    for name, kv in registry.items():
        try:
            sp = int(kv.get("spawned_at", ""))
        except ValueError:
            sp = None
        if start_epoch is not None and sp is not None and sp >= start_epoch - START_SLACK_SEC:
            targets.add(name)
    for name, snap in snaps.items():
        if snap.get("kind", "teammate") == "teammate" and conv_id and snap.get("conv_id") == conv_id:
            targets.add(name)

    rdir = os.path.join(sd, "work", "respawn")
    agents = []
    for name in sorted(targets):
        snap = snaps.get(name, {})
        kv = registry.get(name, {})
        role = snap.get("role") or kv.get("agent_type") or ""
        files = snap.get("files_owned") or (fa_agents.get(name) or {}).get("files") or []
        result = _read_json(os.path.join(sd, "work", name + "_result.json"))
        status = "missing"
        todos_done = []
        conv_id_source = ""
        if isinstance(result, dict) and conv_id and result.get("conv_id") == conv_id:
            conv_id_source = "conv_id"
        elif isinstance(result, dict) and conv_id and "conv_id" not in result:
            # 구 스키마 호환(사이클197): conv_id 선언이 없으면 독립 검증 축(mtime)으로만 인정한다.
            # 선언이 있고 다르면 위 분기에서 걸러지지 않으므로 그대로 무시된다(L-670).
            try:
                sp = int(kv.get("spawned_at", ""))
            except ValueError:
                sp = None
            try:
                mt = int(os.path.getmtime(os.path.join(sd, "work", name + "_result.json")))
            except OSError:
                mt = None
            if (start_epoch is not None and sp is not None and mt is not None
                    and sp >= start_epoch - START_SLACK_SEC and mt >= sp - START_SLACK_SEC):
                conv_id_source = "mtime"
        if conv_id_source:
            rstat = result.get("status")
            if rstat == "done":
                rstat = "completed"  # 구 스키마 별칭 — 판정 시에만, 파일은 고치지 않는다
            if rstat == "completed":
                status = "completed"
            elif rstat == "partial":
                status = "partial"
            todos_done = result.get("todos_completed") or []
        else:
            result = None  # 옛 사이클 잔류물 또는 부재 — 미존재 취급 (L-670)
        todos = snap.get("todos") if isinstance(snap.get("todos"), list) else []
        todos_left = [t.get("content", "") for t in todos
                      if isinstance(t, dict) and t.get("status") not in ("completed", "deleted")]
        todos_done_names = [t.get("content", "") for t in todos
                            if isinstance(t, dict) and t.get("status") == "completed"]
        entry = {
            "name": name, "role": role, "status": status, "files": files,
            "respawn_prompt": "", "todos_remaining": todos_left,
            "transcript_path": snap.get("transcript_path", ""),
        }
        if conv_id_source:
            entry["conv_id_source"] = conv_id_source
        rpath = os.path.join(rdir, name + ".md")
        if status == "completed":
            # 완료 팀원은 재spawn 하지 않는다. 지난 복원의 잔존 프롬프트는 오인 방지로 지운다.
            try:
                os.unlink(rpath)
            except OSError:
                pass
        else:
            text = _respawn_prompt(sd, uuid, name, role, conv_id, snap, result, status,
                                   list(todos_done) + todos_done_names, todos_left, files)
            _atomic_write(rpath, text)
            entry["respawn_prompt"] = "work/respawn/" + name + ".md"
        agents.append(entry)

    pfiles = pres.get("_files") or {}
    goal_src = pfiles.get("goal.json", "")
    goal_locked = None
    if goal_src:
        _g = _read_json(goal_src)
        if isinstance(_g, dict) and isinstance(_g.get("locked"), bool):
            goal_locked = _g["locked"]
    # ROOF-COMPAT(deprecation window 1주기 — 구 RALPH/oralph_active 인식 제거 예정): 신 이름 우선, 없으면 구 이름
    oa_src = pfiles.get("oroof_active", "") or pfiles.get("oralph_active", "")
    oaj_src = pfiles.get("oroof_active.json", "") or pfiles.get("oralph_active.json", "")
    _st_tokens = pres["_status"].split("|")
    roof_gate = ("ROOF" in _st_tokens) or ("RALPH" in _st_tokens) or bool(oa_src or oaj_src)  # ROOF-COMPAT(deprecation window 1주기 — 구 RALPH/oralph_active 인식 제거 예정)
    subagents = _subagents(sd, start_epoch)
    stale_records = []
    if info["boot_changed"]:
        for name, kv in registry.items():
            if kv.get("pane_id") and kv.get("shutdown_sent") != "true":
                stale_records.append({"name": name, "file": os.path.join(sd, "agents", name),
                                      "pane_id": kv.get("pane_id")})
    plan = {
        "restore": {
            "state": info["state"], "classification": pres["_classification"],
            "entry_tier": pres["_entry_tier"], "status": pres["_status"], "conv_id": conv_id,
            "team_name_current": team_cur, "team_name_source": team_src,
            "team_name_preserved": pres["_team_name"],
            "auto": pres["_auto"],
            "oroof_active_src": oa_src, "oroof_active_json_src": oaj_src,
            # ROOF-COMPAT(deprecation window 1주기 — 구 RALPH/oralph_active 인식 제거 예정): 라이브 판정은 신·구 이름 모두
            "oroof_live_exists": any(os.path.isfile(os.path.join(sd, _n)) for _n in
                                     ("oroof_active", "oroof_active.json", "oralph_active", "oralph_active.json")),
            "goal_src": goal_src, "goal_live_exists": os.path.isfile(os.path.join(sd, "goal.json")),
            "goal_locked": goal_locked,
            "rollback_hash": pres["_rollback_hash"],
            "roof_gate": roof_gate,
            "auto_roof_mismatch": pres["_auto"] == "ON" and not roof_gate,
        },
        "boot_changed": info["boot_changed"], "last_event": info["last_event"],
        "state_source": info.get("state_source", "checkpoint"),
        "preserve_reason": info["reason"], "saved_at": info["saved_at"],
        "agents": agents,
        "subagents": subagents,
        "stale_agent_records": stale_records,
    }
    try:
        os.makedirs(os.path.join(sd, "agent_state"), exist_ok=True)
        with open(os.path.join(sd, "agent_state", "restore_log.jsonl"), "a", encoding="utf-8") as fh:
            fh.write(json.dumps({"ts": int(time.time()), "conv_id": conv_id, "state": info["state"],
                                 "agents": {a["name"]: a["status"] for a in agents},
                                 "subagents": len(subagents), "auto": pres["_auto"]},
                                ensure_ascii=False) + "\n")
    except OSError:
        pass
    return plan


def _public(info):
    return {k: v for k, v in info.items() if not k.startswith("_")}


def main(argv):
    if len(argv) < 3 or argv[1] not in ("--check", "--plan"):
        sys.stderr.write("사용법: resume_restore.py --check|--plan <session_dir> [--lead-session ID]\n")
        return 4
    mode, sd = argv[1], argv[2]
    lead = ""
    if "--lead-session" in argv:
        i = argv.index("--lead-session")
        lead = argv[i + 1] if i + 1 < len(argv) else ""
    sd = os.path.abspath(sd)
    # 세션 격리 §(a): session-env/<UUID> 형태의 디렉토리만 다룬다
    if os.path.basename(os.path.dirname(sd)) != "session-env" or not os.path.isdir(sd):
        sys.stdout.write(json.dumps({"resumable": False, "reason": "bad_session_dir", "dir": sd},
                                    ensure_ascii=False) + "\n")
        return 4
    rc, info = judge(sd)
    if mode == "--check" or rc != 0:
        sys.stdout.write(json.dumps(_public(info), ensure_ascii=False) + "\n")
        return rc
    try:
        plan = build_plan(sd, info, lead)
    except OSError as exc:
        sys.stdout.write(json.dumps({"resumable": False, "reason": "write_error", "detail": str(exc)},
                                    ensure_ascii=False) + "\n")
        return 4
    sys.stdout.write(json.dumps(plan, ensure_ascii=False, indent=1) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
