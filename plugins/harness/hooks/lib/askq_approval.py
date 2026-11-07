# 화면 승인(AskUserQuestion) 기록을 메인 세션 트랜스크립트 원본으로 검증하는 F-CRUD-1 보조 판정기(읽기 전용 + 1회 소비 기록)
"""askq_approval — F-CRUD-1 DECLARATION_CONFLICT 전용 화면 승인 판정기 (write_guard 가 호출).

이력: 9386f69 에서 도입 → 728be20 에서 제거 → 2026-10-20 conv_179239511726 사용자 지시로 재도입.
  재도입 범위는 crud_fail_triage 분류 DECLARATION_CONFLICT 한정이다(호출 쪽 write_guard 가 분류를 거른다).
  예전 설계와 다른 점은 다음과 같다. 트랜스크립트를 glob 으로 찾지 않는다. hook 입력의 transcript_path 1개만 읽고,
  그것이 메인 세션 원본인지 실측한다. 팀원 호출과 팀원 트랜스크립트는 거부한다.

원칙: 승인 증표 파일을 따로 두지 않는다. Claude Code 가 직접 쓴 메인 세션 트랜스크립트만 근거로 삼는다.
  트랜스크립트는 읽기만 한다. 쓰는 것은 자기 세션 logs 의 소비 기록(1회용) 1줄뿐이다.

사용:
  python3 askq_approval.py verify --uuid U --session-id S --transcript T --target CRUD_GATE [--consume] [--ttl 1800]
    U = 마커 경로의 세션 UUID, S·T = hook 입력의 session_id·transcript_path

메인 세션 판별 (전부 충족 — 하나라도 어긋나면 거부):
  (m1) S == U                          — 팀원 hook 호출은 자기 session_id 를 가지므로 여기서 거부된다(team_member)
  (m2) basename(T) == U + ".jsonl"     — subagents/agent-*.jsonl·다른 세션 파일 거부
  (m3) T 의 조부모 디렉터리 이름 == "projects", 경로에 /subagents/ 없음, realpath 가 일반 파일
  (m4) 승인 질문·결과 항목에 agentName/teamName 이 없고 sessionId(있으면) == U — 팀원 기록 거부

승인 성립 조건 (전부 충족):
  [assistant 항목] tool_use name=AskUserQuestion
    ① input 최상위에 answers/annotations 키가 없다 (모델 원본 입력 — 에이전트가 답을 채운 호출은 무효)
    ② questions 중 header == "승인:<target>" 이고 question 본문에 고정 문구가 들어 있다
    ③ isSidechain 이 true 가 아니다
  [user 결과 항목] tool_result.tool_use_id == 위 id
    ④ permissionDecision.decision == "accept" 이고 source 가 "user" 로 시작
    ⑤ toolUseResult.answers[<그 질문 본문>] == 승인 라벨
    ⑥ sourceToolAssistantUUID == assistant 항목 uuid
    ⑦ timestamp 가 ttl 이내 (미래 60초 초과 금지), tool_result.is_error 가 true 아님
    ⑧ tool_use_id 가 소비 기록에 없다 (1회용)

출력: 통과 "APPROVED tool_use_id=<id> reason=<질문 앞 120자>" rc=0 / 실패 "NO_APPROVAL <code>" rc=1.
예외는 전부 rc=1 (fail-closed).
"""
import argparse
import datetime
import json
import os
import re
import sys

# target → (질문 본문 고정 문구). 등록되지 않은 target 은 거부한다.
TARGETS = {
    "CRUD_GATE": "F-CRUD-1 판정을 30분 동안 1회 건너뜁니다",
}
APPROVE_LABEL = "승인 (30분 1회)"
TAIL_BYTES = 8 * 1024 * 1024
UUID_RE = re.compile(r"^[0-9a-fA-F-]{8,64}$")
CONSUMED_NAME = "askq_approval_consumed.log"


def _cfg_dir():
    return os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")


def _main_transcript(uuid, session_id, transcript):
    """(m1)~(m3) 메인 세션 트랜스크립트 판별 → (realpath|None, code)."""
    if session_id != uuid:
        return None, "team_member"
    if not transcript or not os.path.isabs(transcript):
        return None, "no_transcript"
    norm = os.path.normpath(transcript)
    if os.path.basename(norm) != uuid + ".jsonl":
        return None, "not_main_transcript"
    if "/subagents/" in norm.replace("\\", "/") + "/" or \
            os.path.basename(os.path.dirname(os.path.dirname(norm))) != "projects":
        return None, "not_main_transcript"
    real = os.path.realpath(norm)
    if not os.path.isfile(real):
        return None, "no_transcript"
    return real, "ok"


def _tail_lines(path):
    """파일 끝 TAIL_BYTES 만 읽어 줄 목록으로. 잘린 첫 줄은 버린다."""
    with open(path, "rb") as f:
        f.seek(0, os.SEEK_END)
        size = f.tell()
        start = max(0, size - TAIL_BYTES)
        f.seek(start)
        data = f.read()
    lines = data.split(b"\n")
    if start > 0 and lines:
        lines = lines[1:]
    return lines


def _parse_ts(s):
    if not isinstance(s, str) or not s:
        return None
    try:
        t = s.strip()
        if t.endswith("Z"):
            t = t[:-1] + "+00:00"
        d = datetime.datetime.fromisoformat(t)
        if d.tzinfo is None:
            d = d.replace(tzinfo=datetime.timezone.utc)
        return d.timestamp()
    except Exception:
        return None


def _content_blocks(entry):
    msg = entry.get("message")
    if not isinstance(msg, dict):
        return []
    c = msg.get("content")
    return [b for b in c if isinstance(b, dict)] if isinstance(c, list) else []


def _foreign(entry, uuid):
    """(m4) 팀원 기록 흔적 또는 다른 세션 기록이면 True."""
    if "agentName" in entry or "teamName" in entry:
        return True
    sid = entry.get("sessionId")
    return sid is not None and sid != uuid


def _collect(lines, header, phrase, uuid):
    """승인 질문 tool_use 후보와 tool_result 항목을 모은다."""
    uses = {}      # tool_use_id → dict(entry_uuid, sidechain, question, forged, foreign)
    order = []     # tool_use_id 등장 순서
    results = {}   # tool_use_id → (entry, block)
    for raw in lines:
        # 사전 필터: tool_use 줄(AskUserQuestion) 또는 결과 줄(toolUseResult) 만 파싱
        if b"AskUserQuestion" not in raw and b"toolUseResult" not in raw:
            continue
        try:
            e = json.loads(raw.decode("utf-8", "replace"))
        except Exception:
            continue
        if not isinstance(e, dict):
            continue
        # 대화 기록(type=assistant·user)만 근거로 쓴다. api-request-blob 처럼 같은 tool_use_id 를 담은 다른 줄은
        # uuid·permissionDecision 이 없어 정당한 승인을 덮어쓰거나(uuid_mismatch·not_user_decision) 위조 근거가 된다.
        if e.get("type") not in ("assistant", "user"):
            continue
        for b in _content_blocks(e):
            bt = b.get("type")
            if bt == "tool_use" and b.get("name") == "AskUserQuestion":
                inp = b.get("input")
                if not isinstance(inp, dict):
                    continue
                qs = inp.get("questions")
                qs = qs if isinstance(qs, list) else []
                qtext = None
                for q in qs:
                    if isinstance(q, dict) and q.get("header") == header \
                            and isinstance(q.get("question"), str) and phrase in q["question"]:
                        qtext = q["question"]
                        break
                hdr_hit = any(isinstance(q, dict) and q.get("header") == header for q in qs)
                if qtext is None and not hdr_hit:
                    continue
                tid = b.get("id")
                if not isinstance(tid, str) or not tid:
                    continue
                uses[tid] = {
                    "entry_uuid": e.get("uuid"),
                    "sidechain": e.get("isSidechain") is True,
                    "question": qtext,
                    "forged": ("answers" in inp) or ("annotations" in inp),
                    "foreign": _foreign(e, uuid),
                }
                order.append(tid)
            elif bt == "tool_result":
                tid = b.get("tool_use_id")
                if isinstance(tid, str) and tid:
                    results[tid] = (e, b)
    return uses, order, results


def _consumed_path(uuid):
    return os.path.join(_cfg_dir(), "session-env", uuid, "logs", CONSUMED_NAME)


def _consumed_ids(path):
    ids = set()
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for ln in f:
                p = ln.split("\t", 1)[0].strip()
                if p:
                    ids.add(p)
    except FileNotFoundError:
        pass
    return ids


def _judge(use, res, ttl, now, uuid):
    """후보 1건 판정 → (ok, code)."""
    if use["foreign"]:
        return False, "team_member"
    if use["forged"]:
        return False, "forged_answers"
    if use["question"] is None:
        return False, "phrase_missing"
    if use["sidechain"]:
        return False, "sidechain"
    if res is None:
        return False, "no_result"
    e, b = res
    if _foreign(e, uuid):
        return False, "team_member"
    if b.get("is_error") is True:
        return False, "tool_error"
    if e.get("isSidechain") is True:
        return False, "sidechain"
    pd = e.get("permissionDecision")
    if not isinstance(pd, dict) or pd.get("decision") != "accept" \
            or not str(pd.get("source") or "").startswith("user"):
        return False, "not_user_decision"
    if not use["entry_uuid"] or e.get("sourceToolAssistantUUID") != use["entry_uuid"]:
        return False, "uuid_mismatch"
    tur = e.get("toolUseResult")
    ans = tur.get("answers") if isinstance(tur, dict) else None
    if not isinstance(ans, dict) or str(ans.get(use["question"], "")).strip() != APPROVE_LABEL:
        return False, "label_mismatch"
    ts = _parse_ts(e.get("timestamp"))
    if ts is None:
        return False, "expired"
    if ts > now + 60:
        return False, "future_ts"
    if now - ts > ttl:
        return False, "expired"
    return True, "ok"


def verify(uuid, session_id, transcript, target, consume, ttl):
    if not UUID_RE.fullmatch(uuid or ""):
        return 1, "NO_APPROVAL bad_args"
    phrase = TARGETS.get(target)
    if not phrase:
        return 1, "NO_APPROVAL unknown_target"
    path, code = _main_transcript(uuid, session_id, transcript)
    if path is None:
        return 1, "NO_APPROVAL " + code
    header = "승인:" + target
    uses, order, results = _collect(_tail_lines(path), header, phrase, uuid)
    if not order:
        return 1, "NO_APPROVAL no_candidate"
    now = datetime.datetime.now(datetime.timezone.utc).timestamp()
    cpath = _consumed_path(uuid)
    consumed = _consumed_ids(cpath)
    last_code = "no_candidate"
    # 가장 최근 후보부터
    for tid in reversed(order):
        ok, code = _judge(uses[tid], results.get(tid), ttl, now, uuid)
        if ok and tid in consumed:
            ok, code = False, "consumed"
        if not ok:
            if last_code == "no_candidate":
                last_code = code
            continue
        reason = re.sub(r"\s+", " ", uses[tid]["question"]).strip()[:120]
        if consume:
            if not _consume(cpath, tid, target):
                if last_code == "no_candidate":
                    last_code = "consumed"
                continue
        return 0, "APPROVED tool_use_id=%s reason=%s" % (tid, reason)
    return 1, "NO_APPROVAL " + last_code


def _consume(cpath, tid, target):
    """flock 아래 재확인 후 원자적 append. 이미 소비됐으면 False."""
    import fcntl
    os.makedirs(os.path.dirname(cpath), exist_ok=True)
    fd = os.open(cpath, os.O_RDWR | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        if tid in _consumed_ids(cpath):
            return False
        stamp = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
        os.write(fd, ("%s\t%s\t%s\n" % (tid, target, stamp)).encode("utf-8"))
        return True
    finally:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)


def main(argv):
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("cmd")
    ap.add_argument("--uuid", default="")
    ap.add_argument("--session-id", default="")
    ap.add_argument("--transcript", default="")
    ap.add_argument("--target", default="")
    ap.add_argument("--consume", action="store_true")
    ap.add_argument("--ttl", type=int, default=1800)
    try:
        a = ap.parse_args(argv)
    except SystemExit:
        print("NO_APPROVAL bad_args")
        return 1
    if a.cmd != "verify" or a.ttl <= 0 or a.ttl > 1800:
        print("NO_APPROVAL bad_args")
        return 1
    try:
        rc, out = verify(a.uuid.strip(), a.session_id.strip(), a.transcript.strip(),
                         a.target.strip(), a.consume, a.ttl)
    except Exception as ex:  # fail-closed
        rc, out = 1, "NO_APPROVAL error %s" % type(ex).__name__
    print(out)
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
