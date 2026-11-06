# oio bash_exec timeout 별칭 차단 hook 코어와 서버 환산 함수를 시험하는 스크립트
import ast
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CORE = os.path.join(HERE, "oio_bash_duration_guard.py")
SERVER = ((os.environ.get("HARNESS_HOME") or os.path.expanduser("~/.harness")) + "/current" + '/mcp-servers/oio/server.py')
fails = []


def run(ti, tool="mcp__oio__bash_exec", teammate="0"):
    env = dict(os.environ, OBDG_TEAMMATE=teammate)
    p = subprocess.run([sys.executable, CORE], input=json.dumps({"tool_name": tool, "tool_input": ti}),
                       capture_output=True, text=True, env=env)
    return p.returncode, p.stdout


def check(name, cond):
    print(("PASS " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


for tm in ("0", "1"):
    rc, out = run({"command": "echo hi", "timeout": 90}, teammate=tm)
    check("timeout=90 deny (teammate=%s)" % tm, rc == 0 and '"deny"' in out and "timeout 은 ms 로 해석된다" in out)
rc, out = run({"command": "echo hi", "timeout": 900})
check("timeout=900 deny", '"deny"' in out)
rc, out = run({"command": "echo hi", "timeout_ms": 90000}, teammate="1")
check("timeout_ms=90000 통과", rc == 0 and out == "")
rc, out = run({"command": "echo hi"}, teammate="1")
check("timeout 없음 통과", out == "")
rc, out = run({"command": "echo hi", "timeout": None})
check("timeout=null 통과", out == "")
rc, out = run({"command": "sleep 200"}, teammate="1")
check("기존 90초 상한 deny 유지", '"deny"' in out and "timeout 은 ms" not in out)
rc, out = run({"command": "sleep 5; echo ok"}, teammate="1")
check("정상 짧은 호출 오탐 0", out == "")
rc, out = run({"command": "cat x", "timeout": 5}, tool="Monitor")
check("Monitor 는 timeout 규칙 비적용", '"timeout 은 ms' not in out)

# 서버 환산 함수는 fastmcp import 없이 소스에서 추출해 시험
src = open(SERVER, encoding="utf-8").read()
fn = [n for n in ast.parse(src).body if isinstance(n, ast.FunctionDef) and n.name == "_resolve_timeout_ms"][0]
ns = {}
exec(compile(ast.Module([fn], []), SERVER, "exec"), ns)
r = ns["_resolve_timeout_ms"]
for args, exp in [((None, 120000), 120000), ((90, 120000), 90000), ((600, 1), 600000),
                  ((601, 1), 601), ((900, 1), 900), ((0, 5000), 5000), ((-3, 5000), 5000), (("x", 7), 7)]:
    check("환산 %r -> %r" % (args, exp), r(*args) == exp)

print("FAILED: %s" % fails if fails else "ALL PASS")
sys.exit(1 if fails else 0)
