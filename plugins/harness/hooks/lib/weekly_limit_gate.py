# 주간 사용 한도 잔여 30%·20%·10% 단계에서 ntfy 를 먼저 보내고 도구를 멈춘 뒤 사용자의 계속/중단 답을 트랜스크립트로 검증하는 PreToolUse 게이트 코어
"""weekly_limit_gate — PreToolUse_weekly_limit_gate.sh 가 부른다.

입력: stdin hook JSON(session_id, transcript_path, tool_name, tool_input, cwd).
      env WLG_ROLE=main|teammate, WLG_LEAD=<리드 UUID>, CLAUDE_CONFIG_DIR, CLAUDE_PROJECT_DIR.
출력: 차단일 때만 stdout 에 deny JSON 1개. 그 밖에는 무출력. 종료 코드는 항상 0.
모든 예외는 무출력 exit 0(fail-open)이다. 이 hook 이 전 세션을 멈추면 안 된다.

경로 기준: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/<리드 UUID>/ 한 곳.
  값          = <cfg>/.usage_cache.json 의 rate_limits.seven_day (used_percentage, resets_at)
  승인 기록   = logs/askq_approval_consumed.log (write_guard F-ASKQ-PROT 가 에이전트 쓰기를 막는다)
                target = WEEKLY_<단계>_<continue|stop|void>@<주키>@<답 epoch>
                void = 기록하지 않는 이른 중단 답이 앞선 계속 기록만 무효로 만든 흔적
  게이트 파일 = weekly_gate/ (notified_* 표식, ntfy_payload.json, ntfy_last.out(토픽·URL 가림), ntfy_last.rc, keys.log, switch_pass.log,
                unverified_* 표식, transcript_unverified.log)
트랜스크립트가 무효이거나 읽을 수 없으면 승인을 확인할 수단이 없으므로 로그·ntfy 를 남기고 통과한다.
읽히는데 답이 없으면 정상 차단이다.

승인은 메인 트랜스크립트 원본만 근거로 삼는다. 판별·소비 헬퍼는 askq_approval.py 를 재사용하고 그 파일은 고치지 않는다.
팀원은 트랜스크립트를 보지 않고 리드의 승인 기록을 읽기만 한다.

시험·실측용 환경변수:
  WLG_THRESHOLDS=25,22  임계값 덮어쓰기(기본 30,20,10 — 2개 이상 N개 목록, 남은 비율 기준)
  WLG_TEST_TAG=1        ntfy 제목 앞에 [시험]
  WLG_NTFY_DRYRUN=1     ntfy_send.sh 를 --dry-run 으로 실행
  WLG_TEST_FAIL=1       코어 안에서 예외 발생(fail-open 시험)
  WLG_TEST_DELAY=초     코어 시작 시 지연(시간 예산 시험)
"""
import datetime
import json
import math
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import askq_approval as askq  # noqa: E402

HEADER = "승인:WEEKLY_LIMIT"
LABEL_CONTINUE = "계속 진행"
LABEL_STOP = "중단"
DEFAULT_THRESHOLDS = (30.0, 20.0, 10.0)
TTL_SEC = 1800
UNVERIFIED_TTL_SEC = 3600
MAX_RESET_AHEAD = 8 * 86400
NTFY_WAIT_SEC = 2.5
SWITCH_NAME = "DISABLE_WEEKLY_LIMIT_GATE"
UUID_RE = re.compile(r"^[0-9a-f-]{36}$")
TARGET_RE = re.compile(r"^WEEKLY_(\d+(?:\.\d+)?)_(continue|stop|void)@(\d+)@(\d+)$")
THRESHOLD_RE = re.compile(r"^\s*\d+(?:\.\d+)?(?:\s*,\s*\d+(?:\.\d+)?)+\s*$")
EMAIL_RE = re.compile(r"[^\s@]+@[^\s@]+")
UUID_ANY_RE = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
# ntfy_send.sh 출력에서 토픽 값과 URL 을 가리는 sed 식(작은따옴표로 감싼 셸 인자들)
REDACT_SED = (
    "-e 's#[A-Za-z][A-Za-z0-9+.-]*://[^[:space:]\"]+#<URL가림>#g' "
    "-e 's#(\"topic\"[[:space:]]*:[[:space:]]*\")[^\"]*\"#\\1<토픽가림>\"#g' "
    "-e 's#topic=[^[:space:]]+#topic=<토픽가림>#g'"
)
DATE_RE = re.compile(
    r"^\s*date(?:\s+(?:'\+[A-Za-z0-9 _./:=,+@%-]*'|\"\+[A-Za-z0-9 _./:=,+@%-]*\"|\+[A-Za-z0-9_./:=,+@%-]*))?\s*$"
)

ALLOW_TOOLS = {
    "AskUserQuestion", "ToolSearch", "SendMessage", "ListAgents",
    "TaskList", "TaskGet", "TaskOutput", "TaskStop", "TodoWrite",
    "Read", "Grep", "Glob", "LS",
    "mcp__oio__file_read", "mcp__oio__find", "mcp__oio__list_dir", "mcp__oio__file_info",
    "mcp__oio__get_cwd", "mcp__oio__lock_status", "mcp__oio__search",
}
ALLOW_SKILLS = {"ointaug", "oi", "oteam"}


def _thresholds():
    """단계 목록 내림차순(바깥→안쪽). 2개 이상 N개 쉼표 목록, 중복이 있거나 형식이 틀리면 기본값."""
    raw = os.environ.get("WLG_THRESHOLDS") or ""
    if THRESHOLD_RE.match(raw):
        vals = [float(x) for x in raw.split(",")]
        if len(set(vals)) == len(vals):
            return tuple(sorted(vals, reverse=True))
    return DEFAULT_THRESHOLDS


def _fmt(v):
    return format(round(float(v), 1), "g")


def phrase_of(stage):
    return "주간 사용 한도 잔여 %s%% 이하 단계" % _fmt(stage)


def reached_stage(remaining, thresholds):
    """잔여가 걸린 가장 안쪽 단계. 없으면 None."""
    hit = [t for t in thresholds if remaining <= t]
    return min(hit) if hit else None


def read_usage(cfg, now):
    """(used, resets_at) 또는 None(값 없음·낡음). timestamp 나이는 보지 않는다."""
    with open(os.path.join(cfg, ".usage_cache.json"), encoding="utf-8") as f:
        data = json.load(f)
    day = ((data.get("rate_limits") or {}).get("seven_day") or {})
    used, resets = day.get("used_percentage"), day.get("resets_at")
    for v in (used, resets):
        if isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v):
            return None
    if not 0 <= used <= 100:
        return None
    if resets <= now or resets > now + MAX_RESET_AHEAD:
        return None
    return float(used), resets


def read_records(cpath, week):
    """이번 주 키의 승인 기록 [(단계, continue|stop, 답 epoch)]."""
    recs = []
    try:
        with open(cpath, encoding="utf-8", errors="replace") as f:
            for ln in f:
                p = ln.rstrip("\n").split("\t")
                m = TARGET_RE.match(p[1]) if len(p) >= 2 else None
                if m and int(m.group(3)) == week:
                    recs.append((float(m.group(1)), m.group(2), int(m.group(4))))
    except FileNotFoundError:
        pass
    return recs


def _mtime_int(path):
    try:
        return int(os.path.getmtime(path))
    except OSError:
        return 0


def decide(recs, stage, last_prompt):
    """pass | stop | ask. 같은 주 키에서 가장 나중에 받은 유효한 답이 이긴다(같은 초면 중단 우선).
    중단은 단계와 무관하다. 새 입력으로 만료된 중단(과 void)도 그보다 이른 계속 기록을 되살리지 않는다."""
    conts = [e for _, k, e in recs if k == "continue"]
    stops = [e for _, k, e in recs if k == "stop" and e >= last_prompt]
    if stops and max(stops) >= max(conts, default=-1):
        return "stop"
    last_reset = max((e for _, k, e in recs if k in ("stop", "void")), default=-1)
    if any(k == "continue" and a <= stage and e > last_reset for a, k, e in recs):
        return "pass"
    return "ask"


def _judge_answer(use, res, now, uuid):
    """후보 1건 판정 → (라벨|None, 답 epoch, TTL 초과 여부). askq_approval._judge 와 같은 규칙에 라벨 2개.
    TTL 을 넘긴 중단 답만 돌려준다. 승인은 못 되지만 앞선 계속 기록을 되살리지 않는 근거로 쓴다."""
    none = (None, 0, False)
    if use["foreign"] or use["forged"] or use["question"] is None or use["sidechain"] or res is None:
        return none
    e, b = res
    if askq._foreign(e, uuid) or b.get("is_error") is True or e.get("isSidechain") is True:
        return none
    pd = e.get("permissionDecision")
    if not isinstance(pd, dict) or pd.get("decision") != "accept" \
            or not str(pd.get("source") or "").startswith("user"):
        return none
    if not use["entry_uuid"] or e.get("sourceToolAssistantUUID") != use["entry_uuid"]:
        return none
    tur = e.get("toolUseResult")
    ans = tur.get("answers") if isinstance(tur, dict) else None
    label = str(ans.get(use["question"], "")).strip() if isinstance(ans, dict) else ""
    if label not in (LABEL_CONTINUE, LABEL_STOP):
        return none
    ts = askq._parse_ts(e.get("timestamp"))
    if ts is None or ts > now + 60:
        return none
    expired = now - ts > TTL_SEC
    if expired and label != LABEL_STOP:
        return none
    return label, int(ts), expired


def _weekly_tool_uses(lines):
    """헤더가 든 AskUserQuestion 호출을 찾아 ({tool_use_id}, {질문이 1개가 아닌 tool_use_id})."""
    tids, mixed = set(), set()
    for raw in lines:
        if b"WEEKLY_LIMIT" not in raw or b"AskUserQuestion" not in raw:
            continue
        try:
            e = json.loads(raw.decode("utf-8", "replace"))
        except Exception:
            continue
        if not isinstance(e, dict) or e.get("type") != "assistant":
            continue
        for b in askq._content_blocks(e):
            if b.get("type") != "tool_use" or b.get("name") != "AskUserQuestion":
                continue
            inp = b.get("input")
            qs = inp.get("questions") if isinstance(inp, dict) else None
            qs = qs if isinstance(qs, list) else []
            if any(isinstance(q, dict) and q.get("header") == HEADER for q in qs) \
                    and isinstance(b.get("id"), str) and b.get("id"):
                tids.add(b["id"])
                if len(qs) != 1:
                    mixed.add(b["id"])
    return tids, mixed


def _conversation_lines(tail, keys):
    """tool_use_id 가 든 줄 중 대화 기록(type=assistant·user)만 남긴다.
    api-request-blob 같은 줄은 같은 id 를 담지만 uuid 가 없어, _collect 가 후보를 덮어쓰면 사용자의 답이 무시되고
    근거로 인정하면 위조 경로가 된다."""
    kept = []
    for raw in tail:
        if not any(k in raw for k in keys):
            continue
        try:
            e = json.loads(raw.decode("utf-8", "replace"))
        except Exception:
            continue
        if isinstance(e, dict) and e.get("type") in ("assistant", "user"):
            kept.append(raw)
    return kept


def scan_answers(lead, session_id, transcript, thresholds, cpath, now):
    """메인 트랜스크립트의 미소비 답을 ([(tool_use_id, 단계, 라벨, 답 epoch, TTL 초과)] 시간순, 검증 불가 코드|None) 으로.
    코드가 있으면 승인을 확인할 수단이 없는 경우이고, None 이면 읽었는데 답이 없거나 있는 경우다."""
    path, code = askq._main_transcript(lead, session_id, transcript)
    if path is None:
        return [], code
    try:
        tail = askq._tail_lines(path)
    except OSError:
        return [], "unreadable"
    tids, mixed = _weekly_tool_uses(tail)
    if not tids:
        return [], None
    lines = _conversation_lines(tail, [t.encode("utf-8") for t in tids])
    consumed = askq._consumed_ids(cpath)
    found = {}
    ambiguous = set()
    for stage in thresholds:
        uses, order, results = askq._collect(lines, HEADER, phrase_of(stage), lead)
        for tid in dict.fromkeys(order):
            if tid in mixed or tid in consumed or uses[tid]["question"] is None:
                continue
            label, epoch, expired = _judge_answer(uses[tid], results.get(tid), now, lead)
            if label is None:
                continue
            if tid in found:
                ambiguous.add(tid)  # 한 질문에 두 단계 문구가 들어 있으면 어느 쪽도 인정하지 않는다
            found[tid] = (stage, label, epoch, expired)
    rows = [(tid,) + v for tid, v in found.items() if tid not in ambiguous]
    rows.sort(key=lambda r: r[3])
    return rows, None


def record_answers(rows, cpath, week, last_prompt):
    """답을 승인 기록으로 남긴다. 마지막 사용자 입력보다 이르거나 TTL 을 넘긴 중단 답은 stop 으로 기록하지 않는다(다시 묻는다).
    다만 그보다 이른 계속 기록이 있으면 void 로 남겨 그 기록이 되살아나지 않게 한다.
    기록은 스캔 뒤에 읽고, 소비 실패(다른 호출이 먼저 기록)면 다시 읽는다. 낡은 기록으로 void 를 빠뜨리면
    다른 호출이 계속만 쓰고 void 를 아직 못 쓴 순간에 그 계속으로 통과한다."""
    recs = read_records(cpath, week)
    for tid, stage, label, epoch, expired in rows:
        kind = "continue" if label == LABEL_CONTINUE else "stop"
        if kind == "stop" and (expired or epoch < last_prompt):
            if not any(k == "continue" and e <= epoch for _, k, e in recs):
                continue
            kind = "void"
        target = "WEEKLY_%s_%s@%d@%d" % (_fmt(stage), kind, week, epoch)
        if askq._consume(cpath, tid, target):
            recs.append((stage, kind, epoch))
        else:
            recs = read_records(cpath, week)


def tool_allowed(tool, tool_input):
    if tool in ALLOW_TOOLS:
        return True
    ti = tool_input if isinstance(tool_input, dict) else {}
    if tool == "Skill":
        name = ti.get("skill") or ti.get("skill_name") or ""
        return isinstance(name, str) and name in ALLOW_SKILLS
    if tool in ("Bash", "mcp__oio__bash_exec"):
        cmds = [ti[k] for k in ("command", "cmd") if ti.get(k)]
        return len(cmds) == 1 and isinstance(cmds[0], str) and bool(DATE_RE.match(cmds[0]))
    return False


def _display_name(sdir):
    """세션 표시 이름. 이메일·UUID 가 섞이면 알림에 넣지 않는다."""
    try:
        with open(os.path.join(sdir, "display_name"), encoding="utf-8", errors="replace") as f:
            name = re.sub(r"[\x00-\x1f\x7f]", "", f.readline()).strip()[:40]
    except OSError:
        return "-"
    if not name or EMAIL_RE.search(name) or UUID_ANY_RE.search(name):
        return "-"
    return name


def _claim(path):
    """O_EXCL 표식. 먼저 만든 쪽만 True."""
    try:
        os.close(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600))
        return True
    except FileExistsError:
        return False


def _rc_text(rc):
    if rc == 0:
        return "ntfy 발송 완료"
    if rc == 3:
        return "ntfy 토픽 없음(rc=3) — 알림을 보내지 못했다"
    return "ntfy 발송 실패(rc=%s)" % rc


def _spawn_ntfy(gate, lead, cwd, title, message, wait):
    """전용 페이로드로 ntfy_send.sh 를 분리 실행한다. wait 초 안에 끝나면 rc, 아니면 None."""
    pay = os.path.join(gate, "ntfy_payload.json")
    tmp = pay + ".tmp.%d" % os.getpid()
    if os.environ.get("WLG_TEST_TAG"):
        title = "[시험] " + title
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({"title": title, "message": message, "tags": ["warning"]}, f, ensure_ascii=False)
    os.replace(tmp, pay)
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ntfy_send.sh")
    rc_file = os.path.join(gate, "ntfy_last.rc")
    project = os.environ.get("CLAUDE_PROJECT_DIR") or (cwd if isinstance(cwd, str) else "") or ""
    args = ["--session-dir", gate, "--session-id", lead]
    if project and os.path.isdir(project):
        args += ["--project-dir", project]
    if os.environ.get("WLG_NTFY_DRYRUN"):
        args.append("--dry-run")
    # 출력은 토픽·URL 을 가린 뒤에만 ntfy_last.out 에 남긴다(진단 파일에 토픽 평문이 남지 않게). rc 는 발송 스크립트 값이다.
    runner = ('bash "$0" "$@" 2>&1 | sed -E ' + REDACT_SED + '; rc=${PIPESTATUS[0]}; '
              'printf "%s\\n" "$rc" > "$WLG_RC_FILE"; exit "$rc"')
    env = dict(os.environ, WLG_RC_FILE=rc_file)
    with open(os.path.join(gate, "ntfy_last.out"), "wb") as out:
        proc = subprocess.Popen(
            ["bash", "-c", runner, script] + args,
            stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT,
            start_new_session=True, env=env,
            cwd=project if project and os.path.isdir(project) else None,
        )
    if wait <= 0:
        return None
    try:
        return proc.wait(timeout=wait)
    except subprocess.TimeoutExpired:
        return None


def notify_stage(gate, lead, sdir, cwd, week, stage, remaining, resets):
    """단계당 1회 발송(deny 보다 먼저). 사유에 넣을 결과 문구를 돌려준다. 실패해도 예외를 내지 않는다."""
    try:
        if _claim(os.path.join(gate, "notified_%d_%s" % (week, _fmt(stage)))):
            reset = time.strftime("%m-%d %H:%M", time.localtime(resets))
            msg = "⚠️ 주간 한도 잔여 %s%% (%s%% 이하) · 세션 %s · 리셋 %s — 화면에서 계속/중단을 선택해야 합니다" % (
                _fmt(remaining), _fmt(stage), _display_name(sdir), reset)
            rc = _spawn_ntfy(gate, lead, cwd, "⚠️ 주간 한도", msg, NTFY_WAIT_SEC)
            return "ntfy 발송 진행 중(결과 미확인)" if rc is None else _rc_text(rc)
        with open(os.path.join(gate, "ntfy_last.rc"), encoding="utf-8") as f:
            return _rc_text(int(f.read().strip()))
    except (FileNotFoundError, ValueError):
        return "ntfy 발송 진행 중(결과 미확인)"
    except Exception:
        return "ntfy 발송 실패(내부 오류)"


def log_keys_once(gate, inp):
    """hook 입력 최상위 키 이름만 세션당 1회 남긴다(값은 남기지 않는다)."""
    try:
        path = os.path.join(gate, "keys.log")
        if _claim(path):
            with open(path, "w", encoding="utf-8") as f:
                f.write(",".join(sorted(str(k) for k in inp)) + "\n")
    except Exception:
        pass


def pass_by_switch(gate, lead, sdir, cwd, tool, week, stage, remaining, resets):
    """스위치 통과를 1줄 남기고, 이번 주·단계에서 처음이면 ntfy 1회. 실패해도 통과한다."""
    try:
        stamp = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
        with open(os.path.join(gate, "switch_pass.log"), "a", encoding="utf-8") as f:
            f.write("%s\t%s\n" % (stamp, tool))
        if _claim(os.path.join(gate, "notified_switch_%d_%s" % (week, _fmt(stage)))):
            msg = "⚠️ 스위치로 게이트 우회됨 · 주간 한도 잔여 %s%% · 세션 %s" % (_fmt(remaining), _display_name(sdir))
            _spawn_ntfy(gate, lead, cwd, "⚠️ 주간 한도", msg, 0)
    except Exception:
        pass


def _unverified_marker(gate, week, stage):
    return os.path.join(gate, "unverified_%d_%s" % (week, _fmt(stage)))


def _unverified_fresh(gate, week, stage, now):
    """표식이 mtime 기준 TTL 안인가. 미래 시각은 인정하지 않는다(시계 오차 60초 허용)."""
    try:
        age = now - os.path.getmtime(_unverified_marker(gate, week, stage))
    except OSError:
        return False
    return -60 <= age <= UNVERIFIED_TTL_SEC


def pass_unverified(gate, lead, sdir, cwd, tool, code, week, stage, remaining, resets):
    """승인을 확인할 수단이 없어 통과시킨다. 로그 1줄, 단계당 ntfy 1회, 팀원도 따르도록 표식을 남긴다.
    표식·알림은 정상 차단용과 따로 둬서, 잠깐 무효였다 돌아와도 정상 차단 알림이 사라지지 않게 한다.
    표식은 통과할 때마다 mtime 을 갱신해 정상 진행 중에는 팀원이 TTL 로 막히지 않게 한다."""
    try:
        stamp = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
        with open(os.path.join(gate, "transcript_unverified.log"), "a", encoding="utf-8") as f:
            f.write("%s\t%s\t%s\n" % (stamp, code, tool))
        marker = _unverified_marker(gate, week, stage)
        with open(marker, "a", encoding="utf-8"):
            pass
        os.utime(marker, None)
        if _claim(os.path.join(gate, "notified_unverified_%d_%s" % (week, _fmt(stage)))):
            reset = time.strftime("%m-%d %H:%M", time.localtime(resets))
            msg = "⚠️ 주간 한도 잔여 %s%% (%s%% 이하) · 세션 %s · 리셋 %s — 승인 확인 불가로 통과" % (
                _fmt(remaining), _fmt(stage), _display_name(sdir), reset)
            _spawn_ntfy(gate, lead, cwd, "⚠️ 주간 한도", msg, 0)
    except Exception:
        pass


def reason_main_ask(tool, stage, remaining, resets, ntfy):
    phrase = phrase_of(stage)
    reset = time.strftime("%m-%d %H:%M", time.localtime(resets))
    return "\n".join([
        "[주간한도 게이트] ⛔ 주간 사용 한도 잔여 %s%% — %s%% 이하 단계에 도달해 '%s' 를 멈췄다. (%s)" % (
            _fmt(remaining), _fmt(stage), tool, ntfy),
        "조치: 지금 AskUserQuestion 으로 사용자에게 묻는다. 질문은 이 질문 1개만 담은 AskUserQuestion 호출로 한다"
        "(다른 승인 질문과 한 호출에 섞으면 인정되지 않는다).",
        "  header: %s" % HEADER,
        "  question: %s 입니다. 현재 잔여 %s%%, 리셋 %s. 계속 진행할까요?" % (phrase, _fmt(remaining), reset),
        "  options: %s / %s" % (LABEL_CONTINUE, LABEL_STOP),
        "옵션 라벨은 `%s`·`%s` 을 그대로 쓴다. (Recommended) 같은 표기를 붙이면 승인으로 인식되지 않아 다시 묻게 된다." % (
            LABEL_CONTINUE, LABEL_STOP),
        "사용자가 한도 확인을 요구했으므로 auto 세션도 묻는다.",
        "답을 받은 직후 반드시 도구를 1회 호출해 결정을 기록하라(예: 단독 `date`). "
        "계속 진행이면 차단됐던 팀원에게 SendMessage 로 재개를 알려라. "
        "중단이면 추가 도구 호출 없이 진행 상황·재개 방법을 요약하고 턴을 끝내라.",
        "사용자 지시 없이 %s 스위치를 만들지 않는다." % SWITCH_NAME,
    ])


def reason_main_stop(tool, remaining, ntfy):
    return "\n".join([
        "[주간한도 게이트] ⛔ 사용자가 중단을 선택해 '%s' 를 멈춘 상태다. 주간 사용 한도 잔여 %s%%. (%s)" % (
            tool, _fmt(remaining), ntfy),
        "추가 도구 호출 없이 진행 상황·재개 방법을 요약하고 턴을 끝내라. 다음 사용자 입력 뒤 첫 호출에서 다시 묻는다.",
        "사용자 지시 없이 %s 스위치를 만들지 않는다." % SWITCH_NAME,
    ])


def reason_teammate(tool, remaining, ntfy):
    return "\n".join([
        "[주간한도 게이트] ⛔ '%s' 차단 — 주간 사용 한도 잔여 %s%%. (%s)" % (tool, _fmt(remaining), ntfy),
        "주간 한도 확인 대기 중이다. AskUserQuestion 을 호출하지 말고, team-lead 에게 SendMessage 로 차단 사실을 1회 보고한 뒤 "
        "다음 지시를 기다려라. 진행 중이던 파일 수정은 일관된 지점에서 멈춰라.",
    ])


def main():
    delay = os.environ.get("WLG_TEST_DELAY")
    if delay:
        time.sleep(float(delay))
    if os.environ.get("WLG_TEST_FAIL"):
        raise RuntimeError("WLG_TEST_FAIL")
    inp = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
    if not isinstance(inp, dict):
        return
    sid, tool = inp.get("session_id"), inp.get("tool_name")
    if not isinstance(sid, str) or not UUID_RE.match(sid) or not isinstance(tool, str) or not tool:
        return
    role = os.environ.get("WLG_ROLE") or "main"
    lead = os.environ.get("WLG_LEAD") or sid
    if role not in ("main", "teammate") or not UUID_RE.match(lead):
        return
    if role == "main" and lead != sid:
        return  # 메인의 리드는 자기 세션뿐이다. 다르면 판정하지 않고 다른 세션 폴더에 쓰지 않는다

    now = time.time()
    cfg = askq._cfg_dir()
    usage = read_usage(cfg, now)
    if usage is None:
        return
    used, resets = usage
    remaining = 100.0 - used
    thresholds = _thresholds()
    stage = reached_stage(remaining, thresholds)
    if stage is None:
        return
    week = int(resets)

    sdir = os.path.join(cfg, "session-env", lead)
    gate = os.path.join(sdir, "weekly_gate")
    os.makedirs(gate, exist_ok=True)
    log_keys_once(gate, inp)
    cwd = inp.get("cwd")

    hooks_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if os.path.exists(os.path.join(hooks_dir, SWITCH_NAME)):
        pass_by_switch(gate, lead, sdir, cwd, tool, week, stage, remaining, resets)
        return

    cpath = askq._consumed_path(lead)
    last_prompt = _mtime_int(os.path.join(sdir, "last_prompt_epoch"))
    unverified = None
    # 메인은 계속 기록이 있어도 먼저 읽는다. 그 뒤에 받은 중단 답을 놓치면 안 된다.
    if role == "main":
        rows, unverified = scan_answers(lead, sid, inp.get("transcript_path"), thresholds, cpath, now)
        if rows:
            record_answers(rows, cpath, week, last_prompt)
        if not unverified:
            try:
                os.unlink(_unverified_marker(gate, week, stage))
            except OSError:
                pass
    # 판정 직전에 읽는다. 병렬 호출이 스캔·기록 사이에 먼저 남긴 답도 이 호출의 판정에 반영한다.
    verdict = decide(read_records(cpath, week), stage, last_prompt)
    if verdict == "pass":
        return
    if role == "main":
        # agent_id 가 있으면 서브에이전트라 메인 트랜스크립트가 아닌 것이 정상이다.
        # 이미 기록된 중단은 사용자의 결정이므로 그대로 두고 다음 입력에서 풀리게 한다.
        if unverified and not inp.get("agent_id") and verdict == "ask":
            pass_unverified(gate, lead, sdir, cwd, tool, unverified, week, stage, remaining, resets)
            return
    elif verdict == "ask" and _unverified_fresh(gate, week, stage, now):
        return  # 메인이 승인 확인 불가로 통과 중이면 팀원도 메인 결정을 따른다

    ntfy = notify_stage(gate, lead, sdir, cwd, week, stage, remaining, resets)
    if tool_allowed(tool, inp.get("tool_input")):
        return
    if role == "teammate":
        reason = reason_teammate(tool, remaining, ntfy)
    elif verdict == "stop":
        reason = reason_main_stop(tool, remaining, ntfy)
    else:
        reason = reason_main_ask(tool, stage, remaining, resets, ntfy)
    out = {"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                  "permissionDecision": "deny",
                                  "permissionDecisionReason": reason}}
    sys.stdout.write(json.dumps(out, ensure_ascii=False))
    sys.stdout.flush()


if __name__ == "__main__":
    try:
        main()
    except BaseException:
        pass
    os._exit(0)
