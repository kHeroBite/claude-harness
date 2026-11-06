# 모바일 테스트 진행 원장 — 항목별 상태·수행 기기·apk_md5·계정을 기록하고 기기 전환 뒤 다음 항목을 고르며 보류 원복 목록을 관리한다
"""
사용 (원장 파일 기본 $OUT/test_ledger.json, --file 로 지정):
  test_ledger.py init --items items.json        # [{"id":"A01","title":"…","requires_phone":true}, …] — 이미 있으면 새 항목만 추가
  test_ledger.py next --kind phone|emulator     # 지금 기기로 할 다음 항목 id (실기기 필수 항목은 에뮬에서 건너뛰고 '실기기 대기' 표시)
  test_ledger.py start <id> --kind K --serial S --model M --apk-md5 X --account A
  test_ledger.py done <id> [--evidence 경로] [--result PASS|FAIL]
  test_ledger.py wait-phone <id> [--reason 사유]  # 실기기 분리로 중단 — 실기기 대기
  test_ledger.py pending-revert add <serial> <key> <value> | list <serial> | clear <serial> [key]
  test_ledger.py apk-check <serial> <설치된 apk md5>   # 원장의 마지막 apk_md5 와 다르면 rc=1(재설치 필요)
  test_ledger.py status
상태: 대기 · 진행 · 완료 · 실기기 대기. 같은 항목을 두 기기에서 수행하면 runs[] 에 둘 다 남는다(증거 g).
전환이 일어나도 처음부터 다시 하지 않는다 — '진행' 중이던 항목은 next 가 그 기기에서 다시 고르고, 끝난 항목은 건너뛴다.
"""
import argparse, json, os, sys, datetime

ST_WAIT, ST_RUN, ST_DONE, ST_PHONE = "대기", "진행", "완료", "실기기 대기"


def now():
    return datetime.datetime.now().isoformat(timespec="seconds")


def load(p):
    if os.path.exists(p):
        with open(p, encoding="utf-8") as f:
            return json.load(f)
    return {"items": [], "pending_revert": {}, "history": []}


def save(p, d):
    tmp = p + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(d, f, ensure_ascii=False, indent=1)
    os.replace(tmp, p)


def find(d, i):
    for it in d["items"]:
        if it["id"] == i:
            return it
    sys.exit(f"원장에 없는 항목: {i}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", default=os.path.join(os.environ.get("OUT", "./otest_mobile_out"), "test_ledger.json"))
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("init"); s.add_argument("--items", required=True)
    s = sub.add_parser("next"); s.add_argument("--kind", required=True, choices=["phone", "emulator"])
    s = sub.add_parser("start"); s.add_argument("id")
    for k in ("kind", "serial", "model", "apk-md5", "account"):
        s.add_argument("--" + k, required=True)
    s = sub.add_parser("done"); s.add_argument("id"); s.add_argument("--evidence", default=""); s.add_argument("--result", default="PASS")
    s = sub.add_parser("wait-phone"); s.add_argument("id"); s.add_argument("--reason", default="실기기 분리")
    s = sub.add_parser("pending-revert"); s.add_argument("op", choices=["add", "list", "clear"]); s.add_argument("serial"); s.add_argument("rest", nargs="*")
    s = sub.add_parser("apk-check"); s.add_argument("serial"); s.add_argument("md5")
    sub.add_parser("status")
    a = ap.parse_args()
    os.makedirs(os.path.dirname(os.path.abspath(a.file)), exist_ok=True)
    d = load(a.file)

    if a.cmd == "init":
        known = {it["id"] for it in d["items"]}
        for it in json.load(open(a.items, encoding="utf-8")):
            if it["id"] not in known:
                d["items"].append({"id": it["id"], "title": it.get("title", ""), "requires_phone": bool(it.get("requires_phone")),
                                   "status": ST_WAIT, "runs": []})
        save(a.file, d); print(f"항목 {len(d['items'])}개")
    elif a.cmd == "next":
        # 1) 이 기기에서 진행 중이던 것 2) 대기 3) 실기기면 '실기기 대기' — 에뮬이면 실기기 필수 항목은 '실기기 대기' 로 표시하고 건너뜀
        order = [ST_RUN, ST_WAIT] + ([ST_PHONE] if a.kind == "phone" else [])
        marked = []
        for st in order:
            for it in d["items"]:
                if it["status"] != st:
                    continue
                if a.kind == "emulator" and it["requires_phone"]:
                    if it["status"] != ST_PHONE:
                        it["status"] = ST_PHONE; marked.append(it["id"])
                    continue
                if marked:
                    save(a.file, d)
                print(it["id"]); return 0
        if marked:
            save(a.file, d)
        left = [it["id"] for it in d["items"] if it["status"] == ST_PHONE]
        print("NONE" + (f" (실기기 대기 {len(left)}건: {','.join(left)})" if left else ""))
        return 1
    elif a.cmd == "start":
        it = find(d, a.id)
        it["status"] = ST_RUN
        it["runs"].append({"kind": a.kind, "serial": a.serial, "model": a.model, "apk_md5": getattr(a, "apk_md5"),
                           "account": a.account, "started_at": now()})
        d["last_apk_md5"] = getattr(a, "apk_md5")
        save(a.file, d); print(f"{a.id} 진행 — {a.kind} {a.serial}")
    elif a.cmd == "done":
        it = find(d, a.id)
        if not it["runs"]:
            sys.exit("start 기록 없이 done 할 수 없다")
        it["runs"][-1].update({"ended_at": now(), "result": a.result, "evidence": a.evidence})
        it["status"] = ST_DONE
        save(a.file, d); print(f"{a.id} 완료({a.result})")
    elif a.cmd == "wait-phone":
        it = find(d, a.id)
        if it["runs"] and "ended_at" not in it["runs"][-1]:
            it["runs"][-1].update({"ended_at": now(), "result": "중단", "reason": a.reason})
        it["status"] = ST_PHONE if it["requires_phone"] else ST_WAIT
        save(a.file, d); print(f"{a.id} → {it['status']}")
    elif a.cmd == "pending-revert":
        pr = d["pending_revert"].setdefault(a.serial, {})
        if a.op == "add":
            pr[a.rest[0]] = a.rest[1] if len(a.rest) > 1 else ""
        elif a.op == "clear":
            if a.rest:
                pr.pop(a.rest[0], None)
            else:
                d["pending_revert"][a.serial] = {}
        save(a.file, d)
        print(json.dumps(d["pending_revert"].get(a.serial, {}), ensure_ascii=False))
        if a.op == "list" and d["pending_revert"].get(a.serial):
            return 1   # 처리할 보류 원복이 남아 있다
    elif a.cmd == "apk-check":
        want = d.get("last_apk_md5", "")
        ok = (want == a.md5)
        print(f"원장 {want or '(없음)'} · 설치 {a.md5} → {'일치' if ok else '불일치 — 재설치'}")
        return 0 if ok else 1
    elif a.cmd == "status":
        for it in d["items"]:
            last = it["runs"][-1] if it["runs"] else {}
            print(f"{it['id']:8s} {it['status']:6s} {'P' if it['requires_phone'] else '-'} {last.get('kind','')} {last.get('serial','')} {last.get('apk_md5','')[:8]} {last.get('account','')}")
        for s_, pr in d["pending_revert"].items():
            if pr:
                print(f"보류 원복 {s_}: {pr}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
