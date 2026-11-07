#!/usr/bin/env python3
# 셸 명령이 실행하는 스크립트 파일을 찾아 본문을 F-GAS-CACHE 판정용으로 넘기는 도우미(PreToolUse_gas_cache_guard.sh 가 호출, 사이클219 C4)
"""사용: printf '%s' "<명령>" | gas_cache_script_scan.py <cwd>

출력(JSON 1줄씩):
  {"kind":"py","path":P,"hit":true|false}     — python·perl·node·ruby·php 스크립트: 이 도우미가 직접 판정한다.
  {"kind":"sh","path":P,"body":B}              — 셸 스크립트: 전처리한 본문을 guard 의 셸 판정 함수가 다시 본다.
찾는 실행 꼴: bash|sh|dash|zsh|ksh|mksh [옵션] 파일 · source|. 파일 · python*|perl|node|nodejs|ruby|php [옵션] 파일 ·
  ./x · ../x · /abs/x 직접 실행(정규 파일+실행 권한, shebang 으로 종류 판별). -c 문자열은 명령으로 보고 그 안의 실행 꼴을 다시 찾는다.
  앞의 VAR=값·sudo·env·nohup·command·time·setsid·exec·nice·stdbuf·builtin·ionice·timeout [옵션] N 은 건너뛴다. `cd <리터럴>` 은 이후 기준 경로.
  [사이클221 R5] cd·pushd 옵션(-L·-P·--)·cd -·popd 스택·단순 명령 치환 대상($(echo X)·`echo X`)도 따라가고, 없는 디렉터리로의 cd 는 위치를 바꾸지 않는다.
깊이 2(본문 안의 실행까지), 파일 16개, 파일당 262144 바이트까지. NUL 이 든 파일·초과 파일·읽기 실패는 건너뛴다(잔존 한계).
허용 목록: 이 hooks 트리의 lib/goal_autoscript_run.sh(판정 CLI 자체가 gas_cache 를 쓴다)·tests/test_gas_*.sh(임시 gas_cache 를 쓰는 시험).
  [TODO-022] 같은 git 저장소의 다른 작업 트리(본 저장소 ↔ worktree)의 같은 파일도, 실제 작업 트리 최상위 + 같은 common dir + 추적 + HEAD 와 같을 때만 허용한다.
셸 본문 전처리: 주석 줄 제거 · here-document 본문 제거(머리 줄은 남긴다) · '>' 나 '\\n' 이 든 작은따옴표 문자열은 Q 로 바꾼다
  (다른 파일에 쓸 스크립트 문면을 printf·echo 로 찍는 경우 과차단 방지).
"""
import os, sys
if len(sys.argv) > 2 and sys.argv[2] == "--rec":
    # [사이클221 iter1] guard 의 `timeout` 프로세스 대신 여기서 2초 상한을 건다 — 무거운 import 보다 먼저. 초과 시 SIGALRM 기본 동작으로 즉시 종료하며
    #   출력은 끝에 한 번만 쓰므로 부분 출력이 없다 → guard 는 빈 결과(통과, 종전 fail-open 과 같음)로 본다.
    #   GAS_SCAN_TEST_ALARM_MS·GAS_SCAN_TEST_SLEEP 는 시험 전용(상한 발동 시 통과를 짧은 시간에 확인).
    import signal
    signal.setitimer(signal.ITIMER_REAL, int(os.environ.get("GAS_SCAN_TEST_ALARM_MS") or 2000) / 1000.0)
    if os.environ.get("GAS_SCAN_TEST_SLEEP"):
        import time
        time.sleep(float(os.environ["GAS_SCAN_TEST_SLEEP"]))
import re, shlex   # json 은 JSON 줄 출력일 때만 main 에서 가져온다([사이클221 iter1] --rec 경로의 기동 비용 절감)

MAXB, MAXF, MAXD = 262144, 16, 2
# [TODO-038] 앞이 식별자 문자가 아닐 때만 — test_gas_cache_guard.sh 같은 파일명은 대상이 아니다(logs/gas_cache·"gas_cache" 는 맞음)
GC = re.compile(r"(?<![A-Za-z0-9_])gas_(c|[*?\[])")
# [TODO-022] 쓰기 표지 이름 뒤에 단어 경계를 둔다 — 종전 부분 문자열 비교는 json.dumps(문자열 반환)를 'dump' 로 잡아 읽기 전용 스크립트를 막았다.
#   경계는 "소문자·숫자가 이어지면 다른 단어"로만 본다 — dumps·removed·writes·truncated 는 빠지고,
#   대문자·밑줄로 이어지는 쓰기 호출(writeFileSync·removeFileIfExists·write_atomic·copy_file)은 종전처럼 잡는다.
#   소문자로 이어지는 쓰기 변형(writelines·writerow·copytree·removedirs·renames 등)은 목록에 적어 종전 범위를 유지한다.
#   앞쪽은 종전처럼 열어 둔다(fwrite·ftruncate·binwrite 처럼 앞에 글자가 붙는 쓰기 호출).
# [TODO-038] 호출 꼴만 쓰기로 센다 — 이름 뒤 '(' (대문자·밑줄로 잇는 변형 허용), 괄호 없는 perl 꼴(unlink $f·unlink "…"), open(…, w|a|x|+).
#   write_guard.sh 같은 파일명·errors="replace" 같은 인자 문자열은 쓰기가 아니다(c7_gate.py 과차단 실측).
WR = re.compile(r"(?:write|writelines|writev|writerow|writerows|writestr|write_text|write_bytes|writeFile|writeFileSync|"
                r"appendFile|appendFileSync|truncate|unlink|unlinkSync|remove|removedirs|rename|renames|replace|rmtree|move|"
                r"copyfile|copyfileobj|copy2|copy|copytree|copymode|copystat|symlink|chmod|dump|file_put_contents|fwrite)(?:[A-Z_]\w*)?\s*\(|"
                r"(?<![A-Za-z0-9_])(?:unlink|rename|truncate|chmod|symlink|remove|rmtree|move|copy)\s+[$@'\"]|"
                r"open\s*\([^)]*,\s*['\"]?[wax+]")
SHELLS = {"bash", "sh", "dash", "zsh", "ksh", "mksh"}
INTERP = re.compile(r"^(python[0-9.]*|perl|node|nodejs|ruby|php)$")
SKIP = {"sudo", "env", "nohup", "command", "time", "setsid", "exec", "nice", "stdbuf", "builtin", "ionice", "!", "{", "then", "do", "else", "elif", "if", "while", "until"}
HK = os.path.realpath(os.path.join(os.path.dirname(os.path.realpath(__file__)), ".."))
ALLOW = re.compile(r"^(lib/goal_autoscript_run\.sh|tests/test_gas_[A-Za-z0-9_]*\.sh)$")
seen, out = set(), []


WT_RE = re.compile(r"^(/.+)/\.claude/hooks/(lib/goal_autoscript_run\.sh|tests/test_gas_[A-Za-z0-9_]*\.sh)$")
_wt_memo, _hk_cmn = {}, []


def _git(root, *args):
    # GIT_* 환경을 지우고 root 에서 git 을 1회 실행한다 → (rc, stdout). 실패·시간 초과는 rc=1
    import subprocess
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    try:
        r = subprocess.run(["git", "-C", root] + list(args), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           text=True, env=env, timeout=1)
        return r.returncode, r.stdout
    except Exception:
        return 1, ""


def allowed_wt(p):
    # [TODO-022] 이 hooks 트리와 같은 git 저장소의 다른 작업 트리(본 저장소 또는 git worktree)에 있는 허용 파일.
    #   조건: 경로 꼴 <루트>/.claude/hooks/<허용 이름> · <루트>가 실제 작업 트리 최상위 · git common dir 이 이 hooks 트리 저장소와 같음 ·
    #         추적 파일 · HEAD 와 내용이 같음(작업 트리·색인 모두). 하나라도 아니면 허용하지 않는다(종전처럼 본문을 검사한다).
    #   worktrees 아래 가짜 디렉터리는 최상위 판정에서, 별도 git init 저장소는 common dir 판정에서, 수정한 사본은 HEAD 대조에서 걸린다.
    m = WT_RE.fullmatch(p)
    if not m:
        return False
    root, rel = os.path.realpath(m.group(1)), ".claude/hooks/" + m.group(2)
    if p in _wt_memo:
        return _wt_memo[p]
    ok = False
    if not _hk_cmn:
        rc, o = _git(os.path.dirname(os.path.dirname(HK)), "rev-parse", "--path-format=absolute", "--git-common-dir")
        _hk_cmn.append(os.path.realpath(o.strip()) if rc == 0 and o.strip() else "")
    if _hk_cmn[0]:
        rc, o = _git(root, "rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir")
        ls = o.splitlines()
        if rc == 0 and len(ls) == 2 and os.path.realpath(ls[0]) == root and os.path.realpath(ls[1]) == _hk_cmn[0]:
            if _git(root, "ls-files", "--error-unmatch", "--", rel)[0] == 0:
                ok = _git(root, "diff", "--quiet", "HEAD", "--", rel)[0] == 0
    _wt_memo[p] = ok
    return ok


def allowed(p):
    if p.startswith(HK + "/") and ALLOW.fullmatch(p[len(HK) + 1:]):
        return True
    return allowed_wt(p)


def segments(cmd):
    # 따옴표 밖의 ; && || | & 개행 $( ` ( ) 로 자른다
    segs, cur, q, i = [], [], None, 0
    while i < len(cmd):
        ch = cmd[i]
        if q:
            cur.append(ch)
            if ch == q:
                q = None
            elif ch == "\\" and q == '"' and i + 1 < len(cmd):
                cur.append(cmd[i + 1]); i += 1
        elif ch in "'\"":
            q = ch; cur.append(ch)
        elif ch == "\\" and i + 1 < len(cmd):
            cur.append(ch); cur.append(cmd[i + 1]); i += 1
        elif ch in ";|&\n`()" or (ch == "$" and i + 1 < len(cmd) and cmd[i + 1] == "("):
            segs.append("".join(cur)); cur = []
            if ch == "$":
                i += 1
        else:
            cur.append(ch)
        i += 1
    segs.append("".join(cur))
    return [s for s in segs if s.strip()]


def words(seg):
    try:
        return shlex.split(seg, comments=True)
    except ValueError:
        return seg.split()


def kind_of(path):
    try:
        with open(path, "rb") as f:
            head = f.read(128)
    except OSError:
        return None
    first = head.split(b"\n", 1)[0].decode("utf-8", "replace")
    if first.startswith("#!"):
        if re.search(r"(python|perl|node|ruby|php)", first):
            return "py"
        return "sh"
    return "py" if path.endswith((".py", ".pl", ".js", ".rb", ".php")) else "sh"


def read_text(path):
    try:
        if not os.path.isfile(path) or os.path.getsize(path) > MAXB:
            return None
        with open(path, "rb") as f:
            b = f.read()
    except OSError:
        return None
    if b"\0" in b:
        return None
    return b.decode("utf-8", "replace")


def py_hit(text):
    gvars = set()
    for line in text.splitlines():
        # 경로를 담는 변수만 추적한다 — 값에 gas_cache 가 있고, 파일 내용을 읽어 담는 꼴(open(·read·load()은 제외
        m = re.match(r"\s*([A-Za-z_]\w*)\s*[:]?=(?!=)(.*)$", line)
        if m and GC.search(m.group(2)) and not re.search(r"(open\s*\(|\.read|read_text|read_bytes|load\s*\(|readFile)", m.group(2)):
            gvars.add(m.group(1))
    for line in text.splitlines():
        s = line.split("#", 1)[0] if not line.lstrip().startswith(("'", '"')) else line
        if not WR.search(s):
            continue
        if GC.search(s):
            return True
        for v in gvars:
            if re.search(r"(?<![\w.])" + re.escape(v) + r"(?!\w)", s):
                return True
    return False


# ── [사이클220 D2] 문자열 조립 우회 탐지: 파생 본문(변수 풀이·escape 해독·문자열 결합)을 한 번 더 판정에 넘긴다 ──
ESC = re.compile(r"\\(x[0-9a-fA-F]{2}|u[0-9a-fA-F]{4}|[0-7]{3})")
B64DEC = re.compile(r"base64\s+(?:-[a-zA-Z]*d[a-zA-Z]*|--decode)\b")
B64RUN = re.compile(r"(\|\s*(?:sudo\s+)?(?:bash|sh|dash|zsh|ksh|mksh)\b|\beval\b|\b(?:bash|sh|dash|zsh|ksh|mksh)\s+-c\b|(?:\bsource|^\s*\.|[;&|]\s*\.)\s+<\()")
B64LIT = re.compile(r"[A-Za-z0-9+/]{8,}={0,2}")


def decode_esc(s):
    def f(m):
        g = m.group(1)
        try:
            return chr(int(g[1:], 16)) if g[0] in "xu" else chr(int(g, 8))
        except ValueError:
            return m.group(0)
    return ESC.sub(f, s)


def _sh_val(v, env):
    """대입 값 → 문자열(모르면 None). 따옴표 벗김 · $(printf 'X') · $(echo [-e] X) · `…` 단순형 · 알려진 변수 풀이"""
    v = v.strip()
    m = re.fullmatch(r"^(?:\$\(|`)\s*(?:printf|echo(?:\s+-[neE]+)*)\s+(.*?)\s*(?:\)|`)$", v)
    if m:
        if re.search(r"[|;&<>`]|\$\(", re.sub(r"'[^']*'|\"[^\"]*\"", "", m.group(1))):
            return None   # 파이프·리다이렉트·중첩 치환이 붙은 명령 치환은 값을 알 수 없다
        w = words(m.group(1))
        if not w:
            return None
        v = w[0]
    elif v[:1] in "'\"":
        w = words(v)
        v = w[0] if len(w) == 1 else None
        if v is None:
            return None
    elif re.search(r"\s", v) or "$(" in v or "`" in v:
        return None
    v = re.sub(r"\$\{([A-Za-z_]\w*)\}|\$([A-Za-z_]\w*)", lambda mm: env.get(mm.group(1) or mm.group(2), mm.group(0)), v)
    return None if "$" in v else v


def sh_derive(body):
    """줄 순서대로 NAME=값 을 기억해 뒤 줄의 $NAME·${NAME} 을 값으로 바꾸고, \\xHH·\\NNN·\\uHHHH 를 해독한 본문"""
    env, out_l = {}, []
    for ln in body.splitlines():
        parts = re.split(r"(;|&&|\|\||&)", ln)   # 구간 순서대로: 앞 구간의 대입을 같은 줄 뒤 구간에 푼다
        for i in range(0, len(parts), 2):
            seg = parts[i]
            if env:
                seg = re.sub(r"\$\{([A-Za-z_]\w*)\}|\$([A-Za-z_]\w*)", lambda mm: env.get(mm.group(1) or mm.group(2), mm.group(0)), seg)
                parts[i] = seg
            m = re.match(r"^\s*(?:export\s+|local\s+|readonly\s+|declare\s+(?:-\w+\s+)?)?([A-Za-z_]\w*)=(.*)$", seg)  # fullmatch-scan: ok — 탐지·수집 쪽은 match 유지가 더 엄격(D-5)
            if m:
                val = _sh_val(decode_esc(m.group(2)), env)
                if val is None:
                    env.pop(m.group(1), None)
                else:
                    env[m.group(1)] = val
        out_l.append("".join(parts))
    return decode_esc("\n".join(out_l))


def b64_payloads(body):
    """base64 해독 결과를 셸로 실행하는 줄(… | base64 -d | sh · eval \"$(… base64 -d)\" · sh -c · source <(…))의 해독문"""
    import base64
    res = []
    for ln in body.splitlines():
        if not (B64DEC.search(ln) and B64RUN.search(ln)):
            continue
        for lit in B64LIT.findall(ln):
            try:
                t = base64.b64decode(lit + "=" * (-len(lit) % 4), validate=True).decode("utf-8")
            except Exception:
                continue
            if t.strip() and all(c.isprintable() or c in "\n\t" for c in t):
                res.append(t)
    return res


def py_norm(text):
    """escape 해독 + 문자열 결합("a"+"b" · "a" "b") + 단일 리터럴 변수(n="gas_")를 + 결합에 풀어 넣은 본문"""
    t = decode_esc(text)
    lits = {}
    for m in re.finditer(r"(?m)^\s*([A-Za-z_]\w*)\s*=\s*(\"[^\"\n]*\"|'[^'\n]*')\s*(?:#.*)?$", t):
        lits[m.group(1)] = m.group(2)[1:-1]
    for n, v in lits.items():
        t = re.sub(r"(?<![\w.\"'])" + re.escape(n) + r"(?=\s*\+)|(?<=\+)(\s*)" + re.escape(n) + r"(?![\w(\"'])",
                   lambda mm: (mm.group(1) or "") + '"' + v.replace("\\", "\\\\") + '"', t)
    for _ in range(8):
        t2 = re.sub(r"\"\s*\+\s*\"|'\s*\+\s*'|\"[ \t]+\"|'[ \t]+'", "", t)
        if t2 == t:
            break
        t = t2
    return t


def sh_prep(text):
    lines, out_l, i = text.splitlines(), [], 0
    while i < len(lines):
        ln = lines[i]
        if ln.lstrip().startswith("#"):
            i += 1; continue
        m = re.search(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1", ln)
        ln2 = re.sub(r"'([^']*)'", lambda mm: "Q" if (">" in mm.group(1) or "\\n" in mm.group(1)) else mm.group(0), ln)
        out_l.append(ln2)
        i += 1
        if m:
            tag = m.group(2)
            while i < len(lines) and lines[i].strip() != tag:
                i += 1
            i += 1
    return "\n".join(out_l)


def add(path, kind, depth):
    rp = os.path.realpath(path)
    if rp in seen or len(seen) >= MAXF or allowed(rp) or allowed(os.path.abspath(path)):
        return
    text = read_text(rp)
    if text is None:
        return
    seen.add(rp)
    if kind is None:
        kind = kind_of(rp)
    if kind == "py":
        out.append({"kind": "py", "path": rp, "hit": py_hit(text) or py_hit(py_norm(text))})
    else:
        body = sh_prep(text)
        out.append({"kind": "sh", "path": rp, "body": body})
        der = sh_derive(body)   # [사이클220 D2] 변수 분할·hex 해독 본문
        if der != body:
            out.append({"kind": "sh", "path": rp, "body": der})
        for k, t in enumerate(b64_payloads(der)[:4]):   # [사이클220 D2] base64 -d | sh 실행문
            pb = sh_prep(t)
            out.append({"kind": "sh", "path": "%s(base64#%d)" % (rp, k + 1), "body": pb})
            out.append({"kind": "sh", "path": "%s(base64#%d)" % (rp, k + 1), "body": sh_derive(pb)})
            if depth < MAXD:
                scan(pb, os.path.dirname(rp), depth + 1)
        if depth < MAXD:
            scan(der, os.path.dirname(rp), depth + 1)


# [사이클221 R5] cd·pushd 대상의 단순 명령 치환($(echo X)·`echo X`·$(printf X))을 리터럴로 푼다 — segments 가 $( 에서 잘라 cd 인자가 비는 것을 막는다
CDSUB = re.compile(r"(?<![\w./-])(cd|pushd)(\s+(?:--\s+|-[LPe@]+\s+)*)(\$\([^()`]*\)|`[^`]*`)")


def cd_subst(cmd):
    def f(m):
        v = _sh_val(m.group(3), {})
        return m.group(0) if v is None else m.group(1) + m.group(2) + shlex.quote(v)
    return CDSUB.sub(f, cmd)


def scan(cmd, cwd, depth):
    base = cwd
    prev, stack = None, []   # [사이클221 R5] cd - 의 직전 위치 · pushd/popd 스택
    cmd = cd_subst(cmd)
    for seg in segments(cmd):
        w = words(seg)
        i = 0
        while i < len(w):
            x = w[i]
            if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", x) or x in SKIP:
                i += 1; continue
            if x == "timeout":
                i += 1
                while i < len(w) and w[i].startswith("-"):
                    i += 1
                i += 1; continue
            break
        if i >= len(w):
            continue
        v = w[i]; vb = os.path.basename(v); rest = w[i + 1:]
        def res(p):
            return p if os.path.isabs(p) else os.path.join(base, p)
        # [사이클221 R5] cd·pushd·popd 로 바뀌는 기준 위치를 따라간다.
        #   옵션(-L·-P·-e·-@·--)을 건너뛰고, cd - 는 직전 위치, 인자 없는 cd 는 홈, pushd 는 스택에 쌓고 popd 는 되돌린다.
        #   실제로 있는 디렉터리일 때만 옮긴다 — 없는 곳으로의 cd 는 셸에서도 실패해 위치가 그대로이므로(뒤의 ; 구간은 원래 위치에서 돈다).
        #   $·` 가 남은(풀리지 않은) 대상은 종전처럼 무시한다.
        if vb in ("cd", "pushd", "popd"):
            if vb == "popd":
                if stack:
                    prev, base = base, stack.pop()
                continue
            a, opts = list(rest), []
            while a and a[0] != "-" and a[0].startswith("-"):
                o = a.pop(0)
                if o == "--":
                    break
                opts.append(o)
            if vb == "pushd" and (not a or re.fullmatch(r"^[+-]\d+$", a[0]) or any("n" in o for o in opts)):
                continue   # 스택 회전형·-n(위치 안 바꿈) pushd 는 따라가지 않는다(잔존 한계)
            t = a[0] if a else ("~" if vb == "cd" else None)
            if t == "-":
                t = prev
            if t is None or "$" in t or "`" in t:
                continue
            nb = res(os.path.expanduser(t))
            if os.path.isdir(nb):
                if vb == "pushd":
                    stack.append(base)
                prev, base = base, nb
            continue
        if vb in SHELLS or INTERP.match(vb):  # fullmatch-scan: ok — 탐지·수집 쪽은 match 유지가 더 엄격(D-5)
            j, cstr = 0, None
            code_opts = ("-c",) if vb in SHELLS else ("-c", "-e", "-E", "-r")
            while j < len(rest) and rest[j].startswith("-"):
                if rest[j] in code_opts and j + 1 < len(rest):
                    cstr = rest[j + 1]; break
                if vb not in SHELLS and rest[j] == "-m":
                    cstr = ""; break
                if vb in SHELLS and rest[j] in ("-o", "+o") and j + 1 < len(rest):
                    j += 1
                if vb in SHELLS and re.fullmatch(r"^-[a-zA-Z]*n[a-zA-Z]*$", rest[j]):
                    cstr = ""; break   # [사이클220] bash -n 은 문법 검사만 한다(실행 아님) — 본문을 보지 않는다
                j += 1
            if cstr is not None:
                if cstr and vb in SHELLS and depth < MAXD + 1:
                    scan(cstr, base, depth)
                elif cstr and vb not in SHELLS and py_hit(py_norm(cstr)):   # [사이클220 D5] python -c 의 문자열 결합
                    out.append({"kind": "py", "path": "(명령 %s -c 결합 풀이)" % vb, "hit": True})
                continue
            if j < len(rest) and "$" not in rest[j]:
                add(res(rest[j]), "sh" if vb in SHELLS else "py", depth)
            continue
        if vb in ("source", ".") and rest and "$" not in rest[0]:
            add(res(rest[0]), "sh", depth); continue
        if "/" in v and "$" not in v:
            p = res(v)
            if os.path.isfile(p) and os.access(p, os.X_OK):
                add(p, None, depth)


def main():
    cwd = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else os.getcwd()
    cmd = sys.stdin.read()
    scan(cmd, cwd, 1)
    # [사이클220 D5] 명령 문자열 자체의 조립(변수 분할·escape·base64 실행)도 파생 본문으로 내보낸다
    pc = sh_prep(cmd)
    der = sh_derive(pc)
    if der != pc:
        out.append({"kind": "sh", "path": "(명령 문자열 조립 풀이)", "body": der})
        scan(der, cwd, 1)
    for k, t in enumerate(b64_payloads(der)[:4]):
        pb = sh_prep(t)
        out.append({"kind": "sh", "path": "(명령 base64 실행문 #%d)" % (k + 1), "body": pb})
        out.append({"kind": "sh", "path": "(명령 base64 실행문 #%d)" % (k + 1), "body": sh_derive(pb)})
        scan(pb, cwd, 2)
    if len(sys.argv) > 2 and sys.argv[2] == "--rec":
        # [사이클221 iter1] guard 가 jq 없이 읽도록 레코드로 낸다 — 결과마다 kind·path·hit(1|0)·body 를 NUL 로 끝맺은 4칸(NUL 은 값에서 제거)
        def f(v):
            return ("" if v is None or v is False else str(v)).replace("\0", "")
        recs = "".join("%s\0%s\0%s\0%s\0" % (f(o.get("kind")), f(o.get("path")), "1" if o.get("hit") is True else "0", f(o.get("body"))) for o in out)
        sys.stdout.buffer.write(recs.encode("utf-8", "replace"))
        sys.stdout.flush()
        return 0
    import json
    for o in out:
        print(json.dumps(o, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)
