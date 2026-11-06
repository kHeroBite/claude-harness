# 상태 전이 판정 hook 5종의 시간 초과 생략·탈출·늦은 차단을 hook_tb.log 에서 찾는 감사 스크립트
#
# 사용: python3 -B gate_skip_audit.py [--session <session-env/UUID 디렉터리>] [--all] [--json]
#   기본 세션 = ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/$PIPELINE_UUID, 기본 범위 = 이번 사이클(시작 시각 이후)
#   --all 은 사이클 경계를 무시한다(과거 사건 검출 시험용).
# 종료 코드: 0 = 이상 없음(또는 로그 없음), 1 = 생략·탈출·늦은 차단 발견, 2 = 사용 오류
# 배경(conv_179340696995 R7): 2026-10-31 03:39:32 oto_completion_guard 가 13초 초과로 생략 통과됐고
#   03:39:35 늦은 판정이 rc=2(차단)로 끝나 차단이 버려졌다. 래퍼 보류(F-TB-STATE-HOLD)로 막고, 이 스크립트가 재검사·기록한다.
# 한계: 로그에는 도구 이름이 없어 overrun(LOW)이 상태 전이 호출인지 다른 도구 호출인지 가리지 못한다.
#   이미 지나간 전이를 되돌리지 못한다. hook_tb_late.log 는 시각이 없어 보지 않는다(mode=late 줄이 같은 정보를 시각과 함께 낸다).
import json
import os
import re
import sys
from datetime import datetime

TARGETS = (
    "PreToolUse_done_gate.sh",
    "PreToolUse_oto_completion_guard.sh",
    "PreToolUse_oto_entry_guard.sh",
    "PreToolUse_dev_ac_gate.sh",
    "PreToolUse_docs_update_gate.sh",
)
LINE = re.compile(r"^(\S+) hook=(\S+) policy=(\S+) budget=(\S+) mode=(\S+) rc=(\S+)")
LOOKBACK_SEC = 120


def parse_ts(s):
    try:
        return datetime.strptime(s, "%Y-%m-%dT%H:%M:%S%z")
    except ValueError:
        return None


def default_session():
    base = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
    uuid = os.environ.get("PIPELINE_UUID", "")
    return os.path.join(base, "session-env", uuid) if uuid else ""


def cycle_start(session):
    try:
        with open(os.path.join(session, "pipeline_start_time"), encoding="utf-8") as f:
            return float(f.read().strip().split()[0])
    except (OSError, ValueError, IndexError):
        return None


def audit(session, scan_all):
    path = os.path.join(session, "logs", "hook_tb.log")
    if not os.path.isfile(path):
        return None, []
    start = None if scan_all else cycle_start(session)
    events = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for raw in f:
            m = LINE.match(raw)
            if not m or m.group(2) not in TARGETS:
                continue
            ts = parse_ts(m.group(1))
            if ts is None:
                continue
            if start is not None and ts.timestamp() < start:
                continue
            events.append({"ts": ts, "hook": m.group(2), "mode": m.group(5), "rc": m.group(6)})
    found = []
    for i, e in enumerate(events):
        stamp = e["ts"].strftime("%Y-%m-%dT%H:%M:%S%z")
        if e["mode"] == "overrun_hold_escape":
            found.append({"level": "MED", "kind": "hold_escape", "hook": e["hook"], "ts": stamp,
                          "note": "보류 6회 뒤 판정 생략 통과"})
        elif e["mode"] == "overrun":
            found.append({"level": "LOW", "kind": "overrun_skip", "hook": e["hook"], "ts": stamp,
                          "note": "시간 초과 판정 생략 통과(도구 종류는 로그에 없음)"})
        elif e["mode"] == "late" and e["rc"] == "2":
            prev = None
            for p in reversed(events[:i]):
                if p["hook"] != e["hook"] or (e["ts"] - p["ts"]).total_seconds() > LOOKBACK_SEC:
                    continue
                if p["mode"] in ("overrun", "overrun_hold_escape", "overrun_hold"):
                    prev = p["mode"]
                    break
            if prev in ("overrun", "overrun_hold_escape"):
                found.append({"level": "HIGH", "kind": "late_block_discarded", "hook": e["hook"], "ts": stamp,
                              "note": "생략 통과 뒤 늦은 판정이 차단(rc=2)으로 끝남 — 차단이 버려졌다"})
    order = {"HIGH": 0, "MED": 1, "LOW": 2}
    found.sort(key=lambda x: (order[x["level"]], x["ts"]))
    return path, found


def main(argv):
    session, scan_all, as_json = "", False, False
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--all":
            scan_all = True
        elif a == "--json":
            as_json = True
        elif a == "--session" and i + 1 < len(argv):
            i += 1
            session = argv[i]
        else:
            print("사용: gate_skip_audit.py [--session <디렉터리>] [--all] [--json]", file=sys.stderr)
            return 2
        i += 1
    session = session or default_session()
    if not session or not os.path.isdir(session):
        print("gate_skip_audit: 세션 디렉터리를 찾지 못했습니다(--session 지정 필요).", file=sys.stderr)
        return 2
    path, found = audit(session, scan_all)
    if path is None:
        print("gate_skip_audit: hook_tb.log 없음 — 검사할 기록이 없습니다.")
        return 0
    if as_json:
        print(json.dumps({"log": path, "all": scan_all, "findings": found}, ensure_ascii=False))
        return 1 if found else 0
    counts = {k: sum(1 for f in found if f["level"] == k) for k in ("HIGH", "MED", "LOW")}
    if not found:
        print("gate_skip_audit: 이상 없음(상태 전이 판정 hook 5종 생략·탈출·늦은 차단 0건).")
        return 0
    print("gate_skip_audit: %d건 (HIGH %d, MED %d, LOW %d) — 판정 hook 이 시간 초과로 생략되었거나 차단이 버려졌습니다."
          % (len(found), counts["HIGH"], counts["MED"], counts["LOW"]))
    for f in found:
        print("  [%s] %s %s %s — %s" % (f["level"], f["ts"], f["hook"], f["kind"], f["note"]))
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
