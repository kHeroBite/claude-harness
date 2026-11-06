# 계정별 측정 조각(JSON)을 하나의 증거 JSON 으로 병합한다 — apk_md5 필수, 항목별 영향 파일 기준 신선도 판정, 자기신고 대신 원자료 경로 병기
"""
사용:
  python3 build_evidence.py --frags <조각 디렉토리> --apk <APK 경로> --out <증거.json>
                            [--impact <영향파일.json>] [--device <serial>] [--model <모델>] [--root <상대경로 기준>]

조각 JSON (계정 1개 = 파일 1개, acct_chain 단계 끝에서 각자 작성):
  {"tag": "acc1", "role": "...", "measured_at": "2026-01-01 10:00:00",
   "items": {"A01": {"result": "PASS", "detail": "...", "raw": ["log/덤프 경로"], "screenshots": ["png 경로"]}}}

영향 파일 JSON (항목별 정적 의존 목록 — 판단으로 늘리거나 줄이지 않는다):
  {"A01": ["src/Views/ListPage.xaml", "src/ViewModels/ListViewModel.cs"], "A02": [...]}
  항목의 영향 파일 중 하나라도 조각의 measured_at 보다 최신이면 그 항목은 stale(재측정 필요)이다.
  영향 파일 목록에 없는 파일의 변경은 그 항목을 무효화하지 않는다(전체 소스 mtime 기준 금지).

결과: result=PASS 는 ① apk_md5 계산 성공 ② 모든 계정·항목 PASS ③ stale 0 ④ 원자료 경로 실존 일 때만.
"""
import argparse, glob, hashlib, json, os, sys, datetime


def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def ts(s):
    try:
        return datetime.datetime.strptime(s, "%Y-%m-%d %H:%M:%S").timestamp()
    except Exception:
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--frags", required=True)
    ap.add_argument("--apk", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--impact")
    ap.add_argument("--device")
    ap.add_argument("--model")
    ap.add_argument("--root", default=".")
    a = ap.parse_args()

    issues = []
    if not os.path.isfile(a.apk):
        print(f"FAIL: APK 부재 {a.apk} — apk_md5 는 필수다", file=sys.stderr)
        sys.exit(1)
    apk_md5 = md5(a.apk)
    impact = {}
    if a.impact:
        with open(a.impact, encoding="utf-8-sig") as f:
            impact = json.load(f)

    def ap_(p):
        return p if os.path.isabs(p) else os.path.join(a.root, p)

    accounts, stale = {}, []
    frags = sorted(glob.glob(os.path.join(a.frags, "*.json")))
    if not frags:
        issues.append("조각 0개")
    for fp in frags:
        with open(fp, encoding="utf-8-sig") as f:
            d = json.load(f)
        tag = d.get("tag") or os.path.splitext(os.path.basename(fp))[0]
        mt = ts(d.get("measured_at", "")) or os.path.getmtime(fp)
        items = d.get("items") or {}
        for iid, it in items.items():
            if it.get("result") != "PASS":
                issues.append(f"{tag}/{iid} result={it.get('result')}")
            for p in (it.get("raw") or []) + (it.get("screenshots") or []):
                if not os.path.exists(ap_(p)):
                    issues.append(f"{tag}/{iid} 원자료 부재 {p}")
            newer = [p for p in impact.get(iid, []) if os.path.isfile(ap_(p)) and os.path.getmtime(ap_(p)) > mt]
            if newer:
                stale.append({"account": tag, "item": iid, "newer_files": newer})
                it["stale"] = True
        accounts[tag] = {"role": d.get("role"), "measured_at": d.get("measured_at"), "fragment": fp, "items": items}

    res = {
        "result": "PASS" if not issues and not stale else "FAIL",
        "written": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "apk_path": a.apk, "apk_md5": apk_md5,
        "device_serial": a.device, "device_model": a.model,
        "freshness_basis": "item_impact_files" if impact else "none(영향 파일 목록 미제공)",
        "accounts": accounts, "stale": stale, "issues": issues,
    }
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, "w", encoding="utf-8") as f:
        json.dump(res, f, ensure_ascii=False, indent=1)
    print(f"{res['result']}: 계정 {len(accounts)} · 이슈 {len(issues)} · stale {len(stale)} · apk_md5 {apk_md5} → {a.out}")
    sys.exit(0 if res["result"] == "PASS" else 1)


if __name__ == "__main__":
    main()
