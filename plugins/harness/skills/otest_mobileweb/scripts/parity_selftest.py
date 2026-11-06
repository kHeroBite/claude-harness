# parity_check.py 의 판정층을 임시 git 픽스처로 실측하는 자체 시험
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CHECK = os.path.join(HERE, "parity_check.py")


def w(root, rel, text):
    p = os.path.join(root, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w", encoding="utf-8") as f:
        f.write(text)


def git(root, *a):
    subprocess.run(["git", "-C", root] + list(a), check=True, capture_output=True)


def base_parity(status="synced"):
    return {
        "version": 1,
        "app_screen_globs": ["app/*.cs"],
        "call_patterns": {"app": [r"Gw\.(\w+)\("], "web": [r"gw\.(\w+)\("]},
        "forbidden_web_patterns": [r"fetch\(\s*['\"]/raw"],
        "items": [{"id": "login", "status": status, "reason": "미구축" if status != "synced" else "",
                   "app": ["app/Login.cs"], "web": ["web/login.js"]}],
        "runtime": {"fields": ["user.name"]},
    }


def make(parity, web_src="gw.Login(); gw.List();", app_src="Gw.Login(); Gw.List();", extra_app=None):
    root = tempfile.mkdtemp(prefix="parity_fx_")
    git(root, "init", "-q")
    git(root, "config", "user.email", "t@t")
    git(root, "config", "user.name", "t")
    w(root, "app/Login.cs", app_src)
    if extra_app:
        w(root, "app/Extra.cs", extra_app)
    w(root, "web/login.js", web_src)
    w(root, "parity.json", json.dumps(parity))
    git(root, "add", "-A")
    git(root, "commit", "-qm", "init")
    return root


def run(root, runtime=True):
    cmd = [sys.executable, CHECK, "--parity", os.path.join(root, "parity.json"), "--repo", root, "--json"]
    if runtime:
        for n in ("a", "b"):
            w(root, "_rt_%s.json" % n, json.dumps({"user": {"name": "x"}}))
        cmd += ["--app-result", os.path.join(root, "_rt_a.json"), "--web-result", os.path.join(root, "_rt_b.json")]
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.returncode, r.stdout


def main():
    results = []

    def case(name, expect, rc):
        ok = rc == expect
        results.append(ok)
        print("%s %-34s 기대=%d 실측=%d" % ("OK  " if ok else "FAIL", name, expect, rc))

    root = make(base_parity())
    case("synced 정상", 0, run(root)[0])

    case("런타임 입력 없음=PARTIAL", 4, run(root, runtime=False)[0])

    p = base_parity(); p["items"][0]["web"] = ["web/missing.js"]
    case("짝 파일 없음", 1, run(make(p))[0])

    root = make(base_parity(), extra_app="x")
    case("앱 화면 미등재", 1, run(root)[0])

    root = make(base_parity())
    w(root, "app/Login.cs", "Gw.Login(); Gw.List(); // 변경")
    case("한쪽(앱)만 변경", 1, run(root)[0])

    root = make(base_parity())
    w(root, "app/Login.cs", "Gw.Login(); Gw.List(); // 변경")
    w(root, "web/login.js", "gw.Login(); gw.List(); // 변경")
    case("양쪽 변경", 0, run(root)[0])

    p = base_parity(); p["items"][0]["change_exemption"] = "웹 대체 동작 문서화"
    root = make(p)
    w(root, "app/Login.cs", "Gw.Login(); Gw.List(); // 변경")
    case("변경 예외 사유 있음", 0, run(root)[0])

    case("웹 미구축", 3, run(make(base_parity("unsynced")))[0])

    case("API 집합 불일치(웹에만)", 1, run(make(base_parity(), web_src="gw.Login(); gw.List(); gw.Extra();"))[0])
    case("API 집합 불일치(앱에만)", 1, run(make(base_parity(), web_src="gw.Login();"))[0])

    p = base_parity(); p["items"][0]["api_exemptions"] = [{"name": "Extra", "side": "web", "reason": "웹 대체 동작"}]
    case("API 예외 사유 있음", 0, run(make(p, web_src="gw.Login(); gw.List(); gw.Extra();"))[0])

    p = base_parity(); p["items"][0]["api_exemptions"] = [{"name": "Extra", "side": "web", "reason": ""}]
    case("API 예외 사유 없음", 1, run(make(p, web_src="gw.Login(); gw.List(); gw.Extra();"))[0])

    case("웹 금지 HTTP 직접 호출", 1,
         run(make(base_parity(), web_src="gw.Login(); gw.List(); fetch('/raw/x');"))[0])

    root = make(base_parity())
    w(root, "_rt_a.json", json.dumps({"user": {"name": "a"}}))
    w(root, "_rt_b.json", json.dumps({"user": {"name": "b"}}))
    r = subprocess.run([sys.executable, CHECK, "--parity", os.path.join(root, "parity.json"), "--repo", root,
                        "--app-result", os.path.join(root, "_rt_a.json"),
                        "--web-result", os.path.join(root, "_rt_b.json")], capture_output=True, text=True)
    case("런타임 필드 불일치", 1, r.returncode)

    case("parity 없음=INPUT", 2, subprocess.run([sys.executable, CHECK, "--parity", "/nonexistent.json",
                                                "--repo", root], capture_output=True).returncode)

    print("합계 %d/%d" % (sum(results), len(results)))
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
