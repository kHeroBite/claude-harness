#!/bin/bash
# 루프백 바인드 지정 없이 로컬 웹서버(python http.server·http-server·serve·php -S·ruby httpd)를 띄우는 셸 명령을 차단하는 PreToolUse 가드
#
# 등록: PreToolUse matcher "Bash|mcp__oio__bash_exec" (timeout 5s)
# 배경(L-1311): python3 -m http.server 등은 인자 없이 띄우면 0.0.0.0(전 인터페이스)에 바인드되어
#   사내망 다른 PC 에서 작업 디렉터리(설정·비밀·데이터)가 그대로 열린다. 루프백(127.0.0.1·localhost·::1) 지정을 강제한다.
# 판정(코어는 아래 내장 python):
#   1. python* -m http.server / SimpleHTTPServer → --bind|-b 값이 루프백이어야 통과(인자 없음 = 차단)
#   2. http-server(npx 포함)                   → -a|--address 값이 루프백이어야 통과
#   3. serve(npx 포함)                          → -l|--listen 값 전부가 루프백을 포함해야 통과
#   4. php -S <addr>                            → addr 의 호스트가 루프백이어야 통과
#   5. ruby -run -e httpd                       → --bind-address 값이 루프백이어야 통과
#   -h/--help/--version 호출은 서버가 뜨지 않으므로 통과. 변수($HOST)처럼 값을 확정할 수 없으면 차단(보수적).
# 오탐 억제: 따옴표 안 텍스트(echo/grep/git commit -m 인자)·heredoc 본문(셸에 넘기는 heredoc 제외)·# 주석은 실행으로 보지 않는다.
#   bash -c '…'·sh -c·eval 의 문자열 인자는 코드로 보고 재귀 판정한다(깊이 3).
# 출력: 차단 시 hookSpecificOutput permissionDecision=deny JSON. 통과 시 무출력. 항상 exit 0.
# 스위치(재시작 불필요):
#   전역 OFF : touch ${HARNESS_HOME:-$HOME/.harness}/current/hooks/.http_server_bind_guard_off
#   env      : HSB_MODE=block|warn (기본 block — warn 은 additionalContext 로 안내만)
# 세션 격리: 아무 파일도 쓰지 않는다. 타 세션 정보 출력 없음.

trap 'exit 0' ERR
[[ -f "${HARNESS_HOME:-$HOME/.harness}/current/hooks/.http_server_bind_guard_off" ]] && exit 0

INPUT=$(timeout 3 cat 2>/dev/null) || exit 0
[[ -n "$INPUT" ]] || exit 0
# 빠른 경로: 대상 키워드가 아예 없으면 python 기동 없이 통과
printf '%s' "$INPUT" | grep -qiE 'http\.server|SimpleHTTPServer|http-server|serve|php|httpd' || exit 0

# read -d '' 는 EOF 에서 rc=1 을 돌려준다 — "|| true" 가 없으면 위 ERR trap 이 여기서 조용히 통과(exit 0)시켜 가드가 죽는다.
read -r -d '' HSB_PY <<'PY' || true
import json, os, re, sys

MODE = os.environ.get("HSB_MODE", "block")
ENV_ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
WRAPPERS = {"setsid", "nohup", "exec", "time", "env", "sudo", "nice", "stdbuf", "command", "ionice", "chrt", "xargs"}
SHELLS = {"bash", "sh", "dash", "zsh", "eval", "su", "wsl", "wsl.exe"}
HELP = {"-h", "--help", "--version", "-v", "-V"}


def _base(tok):
    return re.split(r"[\\/]", tok.strip("\"'"))[-1]


def _loopback(v):
    v = (v or "").strip().strip("\"'").lower()
    if not v or "$" in v or "`" in v:
        return False
    v = re.sub(r"^[a-z]+://", "", v)                 # tcp://127.0.0.1:3000 → 127.0.0.1:3000
    if v.startswith("["):
        v = v[1:v.find("]")] if "]" in v else v[1:]
    elif v.count(":") == 1:
        v = v.split(":")[0]                           # host:port
    return v in ("localhost", "::1", "ip6-localhost") or bool(re.match(r"^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$", v))


def _strip_heredoc(cmd):
    out, lines, i = [], cmd.split("\n"), 0
    while i < len(lines):
        ln = lines[i]
        out.append(ln)
        i += 1
        m = re.search(r"<<-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?", ln)
        if m:
            body = []
            while i < len(lines) and lines[i].strip() != m.group(1):
                body.append(lines[i])
                i += 1
            i += 1
            if re.search(r"\b(bash|sh|dash|zsh)\b", ln):   # 셸에 넘기는 heredoc 은 본문이 코드다
                out.extend(body)
    return "\n".join(out)


def _tokenize(seg):
    toks, i, n = [], 0, len(seg)
    while i < n:
        if seg[i].isspace():
            i += 1
            continue
        buf, quoted = "", False
        while i < n and not seg[i].isspace():
            c = seg[i]
            if c in "\"'":
                j = i + 1
                while j < n and seg[j] != c:
                    if c == '"' and seg[j] == "\\" and j + 1 < n:
                        j += 1
                    j += 1
                buf += seg[i:j + 1]
                quoted = True
                i = j + 1
            else:
                buf += c
                i += 1
        toks.append((buf, quoted))
    return toks


def _split_segments(cmd):
    segs, cur, q, i = [], "", "", 0
    while i < len(cmd):
        c = cmd[i]
        if q:
            cur += c
            if c == q:
                q = ""
            elif c == "\\" and q == '"' and i + 1 < len(cmd):
                cur += cmd[i + 1]
                i += 1
        elif c in "\"'":
            q = c
            cur += c
        elif c in ";|&\n()`":
            segs.append(cur)
            cur = ""
        else:
            cur += c
        i += 1
    segs.append(cur)
    return [s for s in segs if s.strip()]


def _unquote(t):
    return t[1:-1] if len(t) >= 2 and t[0] in "\"'" and t[-1] == t[0] else t


def _opt_values(args, names):
    """args 에서 옵션 names 의 값 목록. --x v / --x=v / -x v / -xv(단일 문자 옵션) 형식."""
    vals, k = [], 0
    while k < len(args):
        a = args[k]
        hit = False
        for nm in names:
            if a == nm:
                vals.append(args[k + 1] if k + 1 < len(args) else "")
                k += 1
                hit = True
                break
            if a.startswith(nm + "="):
                vals.append(a[len(nm) + 1:])
                hit = True
                break
            if len(nm) == 2 and not nm.startswith("--") and a.startswith(nm) and len(a) > 2 and not a.startswith("--"):
                vals.append(a[2:])
                hit = True
                break
        k += 1
    return vals


def _check_bind(args, names, label, need_all=False):
    if any(a in HELP for a in args):
        return None
    vals = _opt_values(args, names)
    if not vals:
        return "%s 에 %s 지정이 없다(기본 = 전 인터페이스)" % (label, "|".join(names))
    bad = [v for v in vals if not _loopback(v)]
    if bad and (need_all or len(bad) == len(vals)):
        return "%s 의 바인드 주소 %s 가 루프백이 아니다" % (label, bad[0] or "(빈 값)")
    return None


def _check_pkg(pkg, args):
    name = re.sub(r"(?<=.)@[^/]*$", "", pkg)          # http-server@14.1.1 → http-server
    if name == "http-server":
        return _check_bind(args, ["-a", "--address"], "http-server")
    if name == "serve":
        return _check_bind(args, ["-l", "--listen"], "serve", need_all=True)
    return None


def _analyze(cmd, depth=0):
    viol = []
    if depth == 0:
        cmd = _strip_heredoc(cmd)
    cmd = re.sub(r"(?m)(^|\s)#.*$", r"\1", cmd)
    cmd = cmd.replace('""', "").replace("''", "")
    for seg in _split_segments(cmd):
        toks = _tokenize(seg)
        k = 0
        while k < len(toks):
            t, qd = toks[k]
            b = _base(t)
            if (ENV_ASSIGN.match(t) and not qd) or t == "$":
                k += 1
            elif b in WRAPPERS:
                k += 1
            elif b == "timeout":
                k += 1
                while k < len(toks) and (toks[k][0].startswith("-") or re.match(r"^\d+(\.\d+)?[smhd]?$", toks[k][0])):
                    k += 1
            else:
                break
        if k >= len(toks):
            continue
        head = toks[k][0]
        hb = re.sub(r"\.exe$", "", _base(head).lower())
        rest = [_unquote(x[0]) for x in toks[k + 1:]]
        v = None
        if hb in SHELLS:
            if depth < 3:
                for r in rest:                        # bash -c 'payload' — 공백 포함 문자열 인자는 코드
                    if re.search(r"\s", r):
                        viol += _analyze(r, depth + 1)
                if hb == "eval" and rest and not any(re.search(r"\s", r) for r in rest):
                    viol += _analyze(" ".join(rest), depth + 1)
            continue
        if re.match(r"^(python[0-9.]*|py|pypy[0-9.]*)$", hb):
            for i, a in enumerate(rest):
                mod, srv = None, None
                if a == "-m" and i + 1 < len(rest):
                    mod, srv = rest[i + 1], rest[i + 2:]
                elif a.startswith("-m") and len(a) > 2 and not a.startswith("--"):
                    mod, srv = a[2:], rest[i + 1:]
                if mod is not None:
                    if mod in ("http.server", "SimpleHTTPServer"):
                        v = _check_bind(srv, ["--bind", "-b"], "python -m " + mod)
                    break
                if a == "-c" or (not a.startswith("-")):
                    break                             # 스크립트 파일/-c 코드 이후는 python 옵션이 아니다
        elif hb in ("http-server", "serve"):
            v = _check_pkg(hb, rest)
        elif hb in ("npx", "pnpx", "bunx") or (hb in ("pnpm", "yarn", "bun") and rest[:1] == ["dlx"]):
            r = rest[1:] if hb in ("pnpm", "yarn", "bun") else rest
            i = 0
            while i < len(r) and r[i].startswith("-"):
                i += 2 if r[i] in ("-p", "--package", "-c", "--call") else 1
            if i < len(r):
                v = _check_pkg(r[i], r[i + 1:])
        elif hb == "php":
            for i, a in enumerate(rest):
                if a == "-S" or (a.startswith("-S") and len(a) > 2):
                    addr = rest[i + 1] if a == "-S" and i + 1 < len(rest) else a[2:]
                    if not _loopback(addr):
                        v = "php -S 의 주소 %s 가 루프백이 아니다" % (addr or "(빈 값)")
                    break
        elif hb == "ruby" and "-run" in rest and "httpd" in rest:
            v = _check_bind(rest, ["--bind-address"], "ruby -run -e httpd")
        if v:
            viol.append(v)
    return viol


GUIDE = ("로컬 웹서버는 루프백에만 바인드하라(L-1311 — 0.0.0.0 바인드는 사내망에 작업 디렉터리를 노출한다). "
         "예: python3 -m http.server 8000 --bind 127.0.0.1 / npx http-server -a 127.0.0.1 / "
         "npx serve -l tcp://127.0.0.1:3000 / php -S 127.0.0.1:8000 / ruby -run -e httpd . --bind-address=127.0.0.1")


def main():
    try:
        data = json.loads(os.environ.get("HSB_INPUT") or "{}")
        ti = data.get("tool_input") or {}
        cmd = ti.get("command") or ti.get("cmd") or ""
        if not isinstance(cmd, str) or not cmd.strip():
            return
        viol = _analyze(cmd)
        if not viol:
            return
        text = "🚫 [F-HTTP-BIND] %s. %s" % ("; ".join(sorted(set(viol))), GUIDE)
        if MODE == "block":
            o = {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                        "permissionDecisionReason": text}}
        else:
            o = {"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": text}}
        sys.stdout.write(json.dumps(o, ensure_ascii=False))
    except Exception:
        return


main()
PY

# 의도된 fail-open — 판정 timeout·비정상 종료는 출력 없이 통과한다(가드 오작동이 전 셸 호출을 막지 않게. 에뮬레이터 가드와 같은 성격).
HSB_INPUT="$INPUT" timeout 4 python3 -I -c "$HSB_PY" 2>/dev/null
exit 0
