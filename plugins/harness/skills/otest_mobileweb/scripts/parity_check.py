# 모바일 앱 ↔ 모바일 웹 동기화(parity.json) 정적·런타임 판정기. parity.json 스키마의 정본.
"""
사용법:
  python3 parity_check.py --parity <parity.json> --repo <저장소 루트> [--base <git ref>] \
      [--app-result app.json --web-result web.json] [--json]

종료코드: 0=PASS 1=FAIL 2=INPUT 3=N/A 4=PARTIAL

parity.json 스키마 (경로는 모두 --repo 기준 상대경로, 프로젝트 고유 이름은 이 파일에 없다):
{
  "version": 1,
  "app_screen_globs": ["<앱 화면 파일 glob>", ...],        # 전부 items[].app 에 등재돼야 한다(커버리지)
  "exempt_globs": [{"glob": "<glob>", "reason": "<사유>"}],   # 화면이 아닌 파일 — 사유 필수
  "web_scan_globs": ["<웹 소스 glob>", ...],                 # 선택. forbidden_web_patterns 를 이 전체에 적용
  "call_patterns": {                                          # API 호출 식별자 추출 정규식(그룹 1 = 식별자)
    "app": ["<regex>", ...],
    "web": ["<regex>", ...]
  },
  "forbidden_web_patterns": ["<regex>", ...],                 # 웹이 앱 호출 집합 밖의 HTTP 경로를 직접 부르는 패턴
  "items": [
    {
      "id": "<항목 ID>",
      "status": "synced" | "unsynced" | "na",                 # synced 만 짝·변경·API 판정 대상
      "app": ["<앱 파일>", ...],
      "web": ["<웹 파일>", ...],                              # synced 는 실재 필수
      "app_calls": ["<식별자>", ...],                         # 선택 — 추출 결과에 합집합
      "web_calls": ["<식별자>", ...],                         # 선택 — 추출 결과에 합집합
      "api_exemptions": [{"name": "<식별자>", "side": "app"|"web", "reason": "<사유>"}],
      "change_exemption": "<사유>",                           # 선택 — 한쪽만 변경돼도 허용하는 사유
      "reason": "<unsynced/na 사유>"
    }
  ],
  "runtime": {"fields": ["a.b.c", ...]}                       # 앱/웹 결과 JSON 에서 비교할 필드(점 경로, 리스트는 [*])
}
"""
import argparse
import glob
import json
import os
import re
import subprocess
import sys

PASS, FAIL, INPUT, NA, PARTIAL = 0, 1, 2, 3, 4


def _read(path):
    try:
        with open(path, encoding="utf-8-sig", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def _expand(repo, patterns):
    out = set()
    for pat in patterns or []:
        for p in glob.glob(os.path.join(repo, pat), recursive=True):
            if os.path.isfile(p):
                out.add(os.path.relpath(p, repo).replace(os.sep, "/"))
    return out


def _compile(patterns, label):
    res = []
    for p in patterns or []:
        try:
            res.append(re.compile(p))
        except re.error as e:
            raise ValueError("%s 정규식 오류: %s (%s)" % (label, p, e))
    return res


def _extract(repo, files, regs):
    found = set()
    for f in files:
        text = _read(os.path.join(repo, f))
        for r in regs:
            for m in r.finditer(text):
                found.add(m.group(1) if m.groups() else m.group(0))
    return found


def _git_changed(repo, base):
    """base 대비 변경(작업트리 포함) + 미추적 파일 집합. 실패 시 None."""
    try:
        a = subprocess.run(["git", "-C", repo, "diff", "--name-only", base],
                           capture_output=True, text=True, check=True).stdout
        b = subprocess.run(["git", "-C", repo, "ls-files", "-o", "--exclude-standard"],
                           capture_output=True, text=True, check=True).stdout
    except (subprocess.CalledProcessError, OSError):
        return None
    return set(x.strip() for x in (a + "\n" + b).splitlines() if x.strip())


def _dig(obj, path):
    cur = [obj]
    for seg in path.split("."):
        nxt = []
        star = seg.endswith("[*]")
        key = seg[:-3] if star else seg
        for c in cur:
            if isinstance(c, dict) and key in c:
                v = c[key]
                nxt.extend(v if (star and isinstance(v, list)) else [v])
        cur = nxt
    return cur


def run(args):
    res = {"layers": {}, "failures": [], "notes": []}

    def fail(layer, msg):
        res["failures"].append("[%s] %s" % (layer, msg))

    try:
        with open(args.parity, encoding="utf-8-sig") as f:
            parity = json.load(f)
    except (OSError, ValueError) as e:
        res["error"] = "parity 읽기 실패: %s" % e
        return INPUT, res
    if not os.path.isdir(args.repo):
        res["error"] = "repo 경로 없음: %s" % args.repo
        return INPUT, res
    repo = args.repo
    items = parity.get("items", [])
    try:
        app_re = _compile(parity.get("call_patterns", {}).get("app"), "call_patterns.app")
        web_re = _compile(parity.get("call_patterns", {}).get("web"), "call_patterns.web")
        forb_re = _compile(parity.get("forbidden_web_patterns"), "forbidden_web_patterns")
    except ValueError as e:
        res["error"] = str(e)
        return INPUT, res

    # 1) 커버리지
    screens = _expand(repo, parity.get("app_screen_globs"))
    exempt = set()
    for ex in parity.get("exempt_globs", []):
        if not str(ex.get("reason", "")).strip():
            fail("coverage", "exempt_globs 사유 없음: %s" % ex.get("glob"))
            continue
        exempt |= _expand(repo, [ex.get("glob", "")])
    registered = set()
    for it in items:
        registered |= set(it.get("app", []))
    missing = sorted(screens - registered - exempt)
    for m in missing:
        fail("coverage", "앱 화면 미등재: %s" % m)
    res["layers"]["coverage"] = {"screens": len(screens), "missing": len(missing)}

    synced = [it for it in items if it.get("status") == "synced"]
    for it in items:
        if it.get("status") in ("unsynced", "na") and not str(it.get("reason", "")).strip():
            fail("coverage", "%s: %s 인데 reason 없음" % (it.get("id"), it.get("status")))
    res["synced_count"] = len(synced)

    # 2) 짝 존재
    pair_bad = 0
    for it in synced:
        if not it.get("web"):
            fail("pair", "%s: synced 인데 web 파일 목록 비어 있음" % it.get("id")); pair_bad += 1
        for w in it.get("web", []):
            if not os.path.isfile(os.path.join(repo, w)):
                fail("pair", "%s: 웹 파일 없음 %s" % (it.get("id"), w)); pair_bad += 1
        for a in it.get("app", []):
            if not os.path.isfile(os.path.join(repo, a)):
                fail("pair", "%s: 앱 파일 없음 %s" % (it.get("id"), a)); pair_bad += 1
    res["layers"]["pair"] = {"bad": pair_bad}

    # 3) 변경 짝
    if synced:
        changed = _git_changed(repo, args.base)
        if changed is None:
            res["layers"]["change"] = "N/A(git 비교 불가)"
            res["notes"].append("변경 짝 층: git 비교 불가 — base=%s" % args.base)
            if args.base != "HEAD":
                res["error"] = "git base 해석 실패: %s" % args.base
                return INPUT, res
        else:
            bad = 0
            for it in synced:
                a_ch = [f for f in it.get("app", []) if f in changed]
                w_ch = [f for f in it.get("web", []) if f in changed]
                if bool(a_ch) != bool(w_ch) and not str(it.get("change_exemption", "")).strip():
                    side = "앱만" if a_ch else "웹만"
                    fail("change", "%s: %s 변경 (%s)" % (it.get("id"), side, ",".join(a_ch or w_ch)))
                    bad += 1
            res["layers"]["change"] = {"bad": bad}
    else:
        res["layers"]["change"] = "N/A(synced 0)"

    # 4) API 동일성 + 금지 HTTP 패턴
    api_bad = 0
    for it in synced:
        app_set = _extract(repo, it.get("app", []), app_re) | set(it.get("app_calls", []))
        web_set = _extract(repo, it.get("web", []), web_re) | set(it.get("web_calls", []))
        ex_app, ex_web = set(), set()
        for ex in it.get("api_exemptions", []):
            if not str(ex.get("reason", "")).strip():
                fail("api", "%s: api_exemptions 사유 없음 (%s)" % (it.get("id"), ex.get("name"))); api_bad += 1
                continue
            (ex_app if ex.get("side") == "app" else ex_web).add(ex.get("name"))
        for n in sorted(web_set - app_set - ex_web):
            fail("api", "%s: 웹에만 있는 호출 %s" % (it.get("id"), n)); api_bad += 1
        for n in sorted(app_set - web_set - ex_app):
            fail("api", "%s: 앱에만 있는 호출 %s" % (it.get("id"), n)); api_bad += 1
        if not app_set and not web_set:
            res["notes"].append("%s: 양쪽 호출 식별자 0건 — 추출 규칙 확인 필요" % it.get("id"))
    scan = set(_expand(repo, parity.get("web_scan_globs")))
    for it in synced:
        scan |= set(it.get("web", []))
    for f in sorted(scan):
        text = _read(os.path.join(repo, f))
        for r in forb_re:
            m = r.search(text)
            if m:
                fail("api", "금지 웹 HTTP 패턴: %s 에서 '%s'" % (f, m.group(0)[:60])); api_bad += 1
    res["layers"]["api"] = {"bad": api_bad} if synced else "N/A(synced 0)"

    # 5) 런타임 대조
    runtime_state = "N/A"
    if args.app_result and args.web_result:
        try:
            with open(args.app_result, encoding="utf-8-sig") as f:
                a = json.load(f)
            with open(args.web_result, encoding="utf-8-sig") as f:
                w = json.load(f)
        except (OSError, ValueError) as e:
            res["error"] = "런타임 결과 읽기 실패: %s" % e
            return INPUT, res
        fields = parity.get("runtime", {}).get("fields", [])
        bad = 0
        for fld in fields:
            va, vw = _dig(a, fld), _dig(w, fld)
            if va != vw:
                fail("runtime", "필드 불일치 %s: 앱=%s 웹=%s" % (fld, va, vw)); bad += 1
        runtime_state = "PASS" if not bad else "FAIL"
        if not fields:
            runtime_state = "N/A"
            res["notes"].append("runtime.fields 비어 있음")
    res["layers"]["runtime"] = runtime_state

    if res["failures"]:
        return FAIL, res
    if not synced:
        res["notes"].append("synced 0건 — 웹 미구축. PASS 아님(N/A)")
        return NA, res
    if runtime_state == "N/A":
        res["notes"].append("정적 층 통과, 런타임 대조 입력 없음 — PARTIAL")
        return PARTIAL, res
    return PASS, res


def main():
    ap = argparse.ArgumentParser(description="모바일 앱↔웹 parity 판정")
    ap.add_argument("--parity", required=True)
    ap.add_argument("--repo", required=True)
    ap.add_argument("--base", default="HEAD", help="git 비교 기준(기본 HEAD = 작업트리+미추적)")
    ap.add_argument("--app-result")
    ap.add_argument("--web-result")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    rc, res = run(args)
    res["rc"] = rc
    res["verdict"] = {PASS: "PASS", FAIL: "FAIL", INPUT: "INPUT", NA: "N/A", PARTIAL: "PARTIAL"}[rc]
    if args.json:
        print(json.dumps(res, ensure_ascii=False, indent=2))
    else:
        print("판정: %s (rc=%d) synced=%s" % (res["verdict"], rc, res.get("synced_count")))
        for k, v in res.get("layers", {}).items():
            print("  층 %s: %s" % (k, v))
        for m in res["failures"]:
            print("  FAIL " + m)
        for m in res["notes"]:
            print("  note " + m)
        if res.get("error"):
            print("  error " + res["error"])
    return rc


if __name__ == "__main__":
    sys.exit(main())
