#!/usr/bin/env python3
# settings 등록 hook 과 pre-commit 진입점의 실행 비트(디스크·git index) 소실을 검사하는 검사기
"""등록 hook 실행 비트 검사기 (python3 stdlib 만 사용).

호출: python3 hook_exec_check.py [--mode session|staged] [--settings FILE ...]
        [--manifest FILE] [--repo DIR] [--registry FILE] [--fix] [--quick]
        [--quiet-ok] [--json]

종료코드: 0=정상 또는 경고만, 1=차단 대상 위반(staged 모드), 2=검사기 내부 오류.
출력: 위반 줄 `[hook-exec] <축> <경로> — <조치>`, 정상이면 무출력. --json 은 violations 배열을 항상 포함.
검사 축: disk(디스크 x 비트) / index(git index 100755) / staged(스테이지 모드) / entry-*(pre-commit 진입점).
"""
import argparse
import json
import os
import re
import shlex
import stat
import subprocess
import sys
import time

_GIT_ENV_KEYS = (
    "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_PREFIX", "GIT_COMMON_DIR",
    "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE",
)
_OPS = re.compile(r"^[();<>|&]+$")
_INTERP = re.compile(r"^(python[0-9.]*|bash|sh|dash|zsh|node|perl|ruby)$")
_HOME_RE = re.compile(r"\$\{HOME\}|\$HOME(?![A-Za-z0-9_])")


def _home():
    return os.environ.get("HOME") or os.path.expanduser("~")


def _genv(clean):
    e = dict(os.environ)
    if clean:
        for k in _GIT_ENV_KEYS:
            e.pop(k, None)
    return e


def git(args, cwd, clean=True):
    """git 실행 결과(CompletedProcess, bytes). 실패·시간초과는 None."""
    try:
        return subprocess.run(["git"] + args, cwd=cwd, env=_genv(clean),
                              capture_output=True, timeout=20)
    except Exception:
        return None


def find_top(p):
    """경로에서 위로 올라가며 .git(디렉터리 또는 파일)을 가진 폴더를 찾는다. 없으면 None."""
    d = p if os.path.isdir(p) else os.path.dirname(p)
    while d and not os.path.exists(d):
        nd = os.path.dirname(d)
        if nd == d:
            return None
        d = nd
    while True:
        if os.path.exists(os.path.join(d, ".git")):
            return d
        nd = os.path.dirname(d)
        if nd == d:
            return None
        d = nd


def common_dir(top, clean=True):
    r = git(["rev-parse", "--path-format=absolute", "--git-common-dir"], top, clean)
    if not r or r.returncode != 0:
        return None
    return os.path.realpath(r.stdout.decode("utf-8", "replace").strip())


def ls_modes(top, rels):
    """git ls-files -s 1회 호출로 {상대경로: 모드}. 비추적은 포함되지 않는다."""
    out = {}
    if not rels:
        return out
    r = git(["ls-files", "-s", "-z", "--"] + sorted(set(rels)), top)
    if not r or r.returncode != 0:
        return out
    for ent in r.stdout.split(b"\0"):
        if not ent or b"\t" not in ent:
            continue
        meta, path = ent.split(b"\t", 1)
        parts = meta.split()
        if len(parts) >= 3 and parts[2] == b"0":
            out[path.decode("utf-8", "replace")] = parts[0].decode()
    return out


# ───────────── 파서 ─────────────

def _expand(tok):
    t = _HOME_RE.sub(_home(), tok)
    if t == "~" or t.startswith("~/"):
        t = _home() + t[1:]
    return t


def parse_command(cmd):
    """command 문자열 → {kind, exec[], interp[], notes[]}. kind=direct|wrapper|interp|unresolved."""
    res = {"kind": "unresolved", "exec": [], "interp": [], "notes": []}
    if "`" in cmd:
        res["notes"].append("복합 셸 명령")
    try:
        lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        toks = list(lex)
    except ValueError:
        res["notes"].append("셸 파싱 실패")
        return res
    first = []
    for t in toks:
        if _OPS.match(t):
            res["notes"].append("복합 셸 명령")
            break
        first.append(t)
    if not first:
        res["notes"].append("빈 명령")
        return res
    t0 = _expand(first[0])
    base = os.path.basename(t0)
    if _INTERP.match(base):
        res["kind"] = "interp"
        script = None
        for a in first[1:]:
            if a in ("-c", "-m", "-e"):
                break
            if a.startswith("-"):
                continue
            script = _expand(a)
            break
        if script and os.path.isabs(script) and "$" not in script:
            res["interp"].append(script)
        else:
            res["notes"].append("해석기 인자 판정 불가")
        return res
    if "$" in t0 or not os.path.isabs(t0):
        res["notes"].append("상대경로/미정의 매크로")
        return res
    if base == "time_budget.sh":
        res["kind"] = "wrapper"
        res["exec"].append(t0)
        if len(first) > 3:
            tgt = _expand(first[3])
            if os.path.isabs(tgt) and "$" not in tgt:
                res["exec"].append(tgt)
            else:
                res["notes"].append("래퍼 대상 판정 불가")
        else:
            res["notes"].append("래퍼 인자 부족")
    else:
        res["kind"] = "direct"
        res["exec"].append(t0)
    return res


# ───────────── settings 로더 ─────────────

def _walk(node, out):
    if isinstance(node, dict):
        c = node.get("command")
        if isinstance(c, str) and node.get("type", "command") == "command":
            out.append(c)
        for v in node.values():
            _walk(v, out)
    elif isinstance(node, list):
        for v in node:
            _walk(v, out)


def load_commands(paths):
    cmds = []
    for p in paths:
        try:
            with open(p, "r", encoding="utf-8") as f:
                data = json.load(f)
        except FileNotFoundError:
            continue
        except (OSError, ValueError) as e:
            sys.stderr.write("[hook-exec] settings 읽기 실패 %s: %s\n" % (p, e))
            continue
        if not isinstance(data, dict):
            continue
        _walk(data.get("hooks"), cmds)
        sl = data.get("statusLine")
        if isinstance(sl, dict) and isinstance(sl.get("command"), str):
            cmds.append(sl["command"])
    return cmds


# ───────────── 보호 대상(승격 등록부) ─────────────

def protected_set(registry_files):
    prot = set()
    for rf in registry_files:
        try:
            with open(rf, "r", encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, ValueError):
            continue
        base = os.path.dirname(os.path.dirname(os.path.realpath(rf)))
        tg = data.get("targets") if isinstance(data, dict) else None
        if not isinstance(tg, dict):
            continue
        for v in tg.values():
            live = v.get("live") if isinstance(v, dict) else None
            if isinstance(live, str):
                prot.add(os.path.realpath(os.path.join(base, live)))
    return prot


# ───────────── 본체 ─────────────

class Report:
    def __init__(self):
        self.violations, self.warnings, self.unresolved = [], [], []
        self.skipped, self.fixed = [], []

    def viol(self, axis, path, action, blocking=False):
        self.violations.append({"axis": axis, "path": path, "action": action, "blocking": blocking})


def _chmod_x(real):
    m = os.stat(real).st_mode
    os.chmod(real, (m & 0o7777) | ((m & 0o444) >> 2))


def fix_allowed(real, orig, top, mode, prot):
    """--fix 안전 조건 5개. (가능 여부, 거부 사유)."""
    if mode != "100755":
        return False, "index 모드 %s (의도 미확인)" % (mode or "비추적")
    try:
        st = os.stat(real)
    except OSError:
        return False, "stat 실패"
    if st.st_uid != os.getuid():
        return False, "소유자 불일치"
    if not stat.S_ISREG(st.st_mode):
        return False, "일반 파일 아님"
    if top is None:
        return False, "저장소 밖"
    if orig and os.path.islink(orig):
        if find_top(real) != find_top(os.path.realpath(os.path.dirname(orig))):
            return False, "링크가 다른 저장소를 가리킴"
    if real in prot:
        return False, "보호 대상(승격 경로로 복구)"
    return True, ""


def collect_targets(cmds, rep):
    """실경로 → {orig, role}. role: exec | interp."""
    targets = {}
    for c in cmds:
        r = parse_command(c)
        for n in r["notes"]:
            rep.unresolved.append({"command": c, "reason": n})
        for role, lst in (("exec", r["exec"]), ("interp", r["interp"])):
            for p in lst:
                real = os.path.realpath(p)
                cur = targets.get(real)
                if cur is None or (role == "exec" and cur["role"] != "exec"):
                    targets[real] = {"orig": p, "role": role}
    return targets


def run_session(args, rep, targets, prot, fix):
    items = []  # (real, info, top, rel)
    for real, info in sorted(targets.items()):
        if real.startswith("/mnt/"):
            rep.skipped.append({"path": real, "reason": "NTFS 경로(모드 비트 의미 없음)"})
            continue
        if not os.path.isfile(real):
            rep.warnings.append({"axis": "missing", "path": real, "action": "등록됐지만 파일이 없음"})
            continue
        top = find_top(real)
        rel = os.path.relpath(real, top) if top else None
        items.append((real, info, top, rel))

    disk_bad = [(real, info, top, rel) for real, info, top, rel in items
                if info["role"] == "exec" and not os.access(real, os.X_OK)]

    modes = {}  # (top, rel) -> mode
    need = disk_bad if args.quick else [i for i in items if i[1]["role"] == "exec"]
    if args.quick and not fix:
        need = []
    by_top = {}
    for real, info, top, rel in need:
        if top:
            by_top.setdefault(top, []).append(rel)
    for top, rels in by_top.items():
        for rel, m in ls_modes(top, rels).items():
            modes[(top, rel)] = m

    def handle_disk(axis, real, info, top, rel, allow_fix=True):
        mode = modes.get((top, rel)) if top else None
        act = "chmod +x %s" % real
        if mode and mode != "100755":
            act += " && git -C %s update-index --chmod=+x %s" % (top, rel)
        if fix and allow_fix:
            ok, why = fix_allowed(real, info.get("orig"), top, mode, prot)
            if ok:
                try:
                    _chmod_x(real)
                    rep.fixed.append({"axis": axis, "path": real, "action": "chmod 복구 완료 (index 100755 일치)"})
                    return
                except OSError as e:
                    why = "chmod 실패: %s" % e
            act += " (자동 복구 보류: %s)" % why
        rep.viol(axis, real, act)

    for real, info, top, rel in disk_bad:
        handle_disk("disk", real, info, top, rel)

    if not args.quick:
        for real, info, top, rel in items:
            if info["role"] != "exec" or not top:
                continue
            m = modes.get((top, rel))
            if m is not None and m != "100755":
                rep.viol("index", real, "git -C %s update-index --chmod=+x %s" % (top, rel))
        run_entry(args, rep, prot, fix, handle_disk)


def run_entry(args, rep, prot, fix, handle_disk):
    """pre-commit 진입점(.git/hooks/pre-commit 또는 core.hooksPath)과 별도 저장소 claude-harness 점검."""
    top = args.repo or _cwd_top(True)
    if not top:
        return
    cdir = common_dir(top)
    if not cdir:
        return
    hp = git(["config", "--get", "core.hooksPath"], top)
    hooks_dir = os.path.join(cdir, "hooks")
    if hp and hp.returncode == 0 and hp.stdout.strip():
        v = os.path.expanduser(hp.stdout.decode("utf-8", "replace").strip())
        hooks_dir = v if os.path.isabs(v) else os.path.join(top, v)
    pre = os.path.join(hooks_dir, "pre-commit")
    if os.path.lexists(pre):
        real = os.path.realpath(pre)
        if not os.path.isfile(real):
            rep.viol("entry-disk", pre, "링크 대상이 없음: %s — 진입점을 다시 연결" % real)
        else:
            t = find_top(real)
            rel = os.path.relpath(real, t) if t else None
            mode = ls_modes(t, [rel]).get(rel) if t else None
            info = {"orig": pre, "role": "exec"}
            if not os.access(real, os.X_OK):
                _entry_disk(rep, real, info, t, rel, mode, prot, fix)
            if mode is not None and mode != "100755":
                rep.viol("entry-index", real, "git -C %s update-index --chmod=+x %s" % (t, rel))
    main_top = os.path.dirname(cdir) if os.path.basename(cdir) == ".git" else top
    ch = os.path.join(main_top, "claude-harness")
    chp = os.path.join(ch, ".git", "hooks", "pre-commit")
    if os.path.isdir(os.path.join(ch, ".git")) and os.path.lexists(chp):
        real = os.path.realpath(chp)
        if not os.path.isfile(real):
            rep.viol("harness-entry", chp, "별도 저장소(수정 금지) — 링크 대상 없음: %s" % real)
        elif not os.access(real, os.X_OK):
            rep.viol("harness-entry", real, "별도 저장소(자동 복구 안 함) — 배포 경로에서 chmod +x 확인")


def _entry_disk(rep, real, info, top, rel, mode, prot, fix):
    act = "chmod +x %s" % real
    if mode and mode != "100755":
        act += " && git -C %s update-index --chmod=+x %s" % (top, rel)
    if fix:
        ok, why = fix_allowed(real, info.get("orig"), top, mode, prot)
        if ok:
            try:
                _chmod_x(real)
                rep.fixed.append({"axis": "entry-disk", "path": real, "action": "chmod 복구 완료 (index 100755 일치)"})
                return
            except OSError as e:
                why = "chmod 실패: %s" % e
        act += " (자동 복구 보류: %s)" % why
    rep.viol("entry-disk", real, act)


def _cwd_top(clean):
    r = git(["rev-parse", "--show-toplevel"], os.getcwd(), clean)
    if not r or r.returncode != 0:
        return None
    return r.stdout.decode("utf-8", "replace").strip() or None


def run_staged(args, rep, targets):
    clean = bool(args.repo)
    top = args.repo or _cwd_top(False)
    if not top:
        return
    my_common = common_dir(top, clean)
    if not my_common:
        return
    reg = set()
    cache = {}
    for real, info in targets.items():
        if info["role"] != "exec" or real.startswith("/mnt/"):
            continue
        t = find_top(real)
        if not t:
            continue
        if t not in cache:
            cache[t] = common_dir(t)
        if cache[t] == my_common:
            reg.add(os.path.relpath(real, t))
    if not reg:
        return
    r = git(["diff", "--cached", "--raw", "-z", "--no-renames"], top, clean)
    if not r or r.returncode != 0:
        raise RuntimeError("git diff --cached 실패")
    parts = r.stdout.split(b"\0")
    i = 0
    while i < len(parts):
        meta = parts[i]
        if not meta.startswith(b":") or i + 1 >= len(parts):
            i += 1
            continue
        f = meta[1:].split()
        path = parts[i + 1].decode("utf-8", "replace")
        i += 2
        if len(f) < 2:
            continue
        newmode = f[1].decode()
        if path in reg and newmode not in ("100755", "000000"):
            rep.viol("staged", path, "git update-index --chmod=+x %s (스테이지 모드 %s)" % (path, newmode), True)


def main(argv=None):
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--mode", choices=("session", "staged"), default="session")
    ap.add_argument("--settings", action="append", default=[])
    ap.add_argument("--manifest")
    ap.add_argument("--repo")
    ap.add_argument("--registry")
    ap.add_argument("--fix", action="store_true")
    ap.add_argument("--quick", action="store_true")
    ap.add_argument("--quiet-ok", action="store_true")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)

    t0 = time.perf_counter()
    fix = args.fix and os.environ.get("HOOK_EXEC_CHECK_FIX", "1") != "0" and args.mode == "session"
    rep = Report()

    srcs = list(args.settings)
    if not srcs:
        srcs.append(os.path.join(_home(), ".claude", "settings.json"))
        ccd = os.environ.get("CLAUDE_CONFIG_DIR")
        if ccd:
            srcs.append(os.path.join(ccd, "settings.json"))
    manifest = args.manifest
    if not manifest and args.mode == "staged":
        t = args.repo or _cwd_top(bool(args.repo))
        if t:
            manifest = os.path.join(t, ".claude", "settings_hooks_manifest.json")
    if manifest:
        srcs.append(manifest)
    seen, uniq = set(), []
    for s in srcs:
        k = os.path.realpath(s)
        if k not in seen:
            seen.add(k)
            uniq.append(s)

    targets = collect_targets(load_commands(uniq), rep)

    regs = []
    if args.registry:
        regs.append(args.registry)
    else:
        regs.append(os.path.join(_home(), ".claude", "hooks", "lib", "guard_promote.json"))
        tops = {find_top(r) for r in targets}
        for t in tops:
            if t:
                regs.append(os.path.join(t, ".claude", "hooks", "lib", "guard_promote.json"))
    prot = protected_set(regs)

    if args.mode == "staged":
        run_staged(args, rep, targets)
    else:
        run_session(args, rep, targets, prot, fix)

    elapsed = int((time.perf_counter() - t0) * 1000)
    if args.json:
        print(json.dumps({
            "violations": rep.violations, "warnings": rep.warnings, "unresolved": rep.unresolved,
            "skipped": rep.skipped, "fixed": rep.fixed, "checked": len(targets), "elapsed_ms": elapsed,
        }, ensure_ascii=False))
    else:
        for v in rep.violations:
            print("[hook-exec] %s %s — %s" % (v["axis"], v["path"], v["action"]))
        for v in rep.fixed:
            print("[hook-exec] fixed %s — %s" % (v["path"], v["action"]))
        for v in rep.warnings:
            print("[hook-exec] %s %s — %s" % (v["axis"], v["path"], v["action"]))
    return 1 if any(v["blocking"] for v in rep.violations) else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception as e:  # 검사기 내부 오류는 rc 2 (호출 지점이 fail-open 처리)
        sys.stderr.write("[hook-exec] 내부 오류: %s\n" % e)
        sys.exit(2)
