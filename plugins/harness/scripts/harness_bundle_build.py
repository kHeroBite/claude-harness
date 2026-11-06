#!/usr/bin/env python3
# AI 하네스 소스를 플러그인 배포본(claude-harness)으로 빌드하고 경로 이식 변환·이식성 검사(lint)를 하는 도구
"""하네스 배포본 빌드 도구.

사용법:
  python3 -B harness_bundle_build.py --src <AI 루트> --out <claude-harness 루트>
        [--manifest <설정 json>] [--dry-run | --check] [--allow-dirty] [--report <json>]

  (옵션 없음)  빌드 → out 반영 → out 에 lint 실행. lint 실패면 rc=1.
  --dry-run    임시 폴더에만 빌드하고 바뀔 목록·lint 결과만 출력한다(out 무변경).
  --check      빌드 없이 out 에 lint(a·a2·b·c·d·e·f)만 실행한다(읽기 전용).
  --allow-dirty  out 저장소에 미커밋 변경이 있어도 덮어쓴다(재빌드용. 기본은 거부).
  --report     판정 상세를 json 으로 저장한다(값이 아니라 파일:줄·규칙만 담는다).

종료 코드: 0 정상 / 1 lint 실패 / 2 사용법·설정·원본 오류 / 3 out 미커밋 변경으로 거부.

원칙:
  - 소스(--src)는 읽기만 한다. 변환은 배포 사본에만 적용한다.
  - out 에서는 manifest include 가 가리키는 위치(관리 영역)만 쓰고 지운다. 그 밖(install.sh·README·
    .claude-plugin·rules·scripts/ 등)은 건드리지 않는다. preserve 목록은 관리 영역 안이어도 지우지 않는다.
  - 결과는 결정적이다(정렬된 순회, 고정 권한 0755/0644, 타임스탬프 미기록).
  - 자격증명 값은 출력하지 않는다. lint 출력은 파일:줄과 걸린 규칙·토큰만 보인다.
"""
import argparse
import ast
import fnmatch
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import tokenize

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_MANIFEST = os.path.join(HERE, "harness_bundle_manifest.json")

RC_OK, RC_LINT, RC_CONFIG, RC_DIRTY = 0, 1, 2, 3
INTERPRETERS = {"python3", "python", "bash", "sh", "node", "env", "dash", "zsh"}
PY_BASES = {
    "harness_current": '(os.environ.get("HARNESS_HOME") or os.path.expanduser("~/.harness")) + "/current"',
    "harness_home": '(os.environ.get("HARNESS_HOME") or os.path.expanduser("~/.harness"))',
    "config": '(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"))',
    "home": 'os.path.expanduser("~")',
}
PLUGIN_TOKEN_RE = re.compile(r"\$\{CLAUDE_PLUGIN_ROOT\}/([^\s\"'\\;|&)<>]+)")
MAX_SHOW = 40


class ConfigError(Exception):
    """manifest·원본 구성 오류 (rc=2)."""


class Report:
    """빌드·lint 결과 모음. 값이 아니라 위치·규칙만 담는다."""

    def __init__(self):
        self.errors = []          # 구성 오류 문자열
        self.warnings = []        # 경고 문자열
        self.lint = {}            # 코드 -> [항목]
        self.lint_warn = {}       # 코드 -> [항목] (실패 아님)
        self.dropped_hooks = []   # hooks.json 에서 뺀 항목
        self.skipped_skills = []  # exclude_skills 로 뺀 스킬
        self.untracked_skipped = 0
        self.changes = {"add": [], "mod": [], "del": []}
        self.py_unconverted = []  # py 변환 실패·보류

    def add_lint(self, code, item):
        self.lint.setdefault(code, []).append(item)

    def add_lint_warn(self, code, item):
        self.lint_warn.setdefault(code, []).append(item)

    def to_json(self):
        return {
            "errors": self.errors, "warnings": self.warnings, "lint": self.lint,
            "lint_warn": self.lint_warn, "dropped_hooks": self.dropped_hooks,
            "skipped_skills": self.skipped_skills, "untracked_skipped": self.untracked_skipped,
            "changes": self.changes, "py_unconverted": self.py_unconverted,
        }

# ─────────────────────────────── 공통 ───────────────────────────────

def load_manifest(path):
    try:
        with open(path, encoding="utf-8") as f:
            m = json.load(f)
    except (OSError, ValueError) as e:
        raise ConfigError(f"manifest 를 읽을 수 없음: {path} ({e.__class__.__name__})")
    for key in ("plugin_dir", "include", "exclude_globs", "exclude_skills", "rewrite", "lint"):
        if key not in m:
            raise ConfigError(f"manifest 필수 키 누락: {key}")
    for key, lst in (("wsl_only_allow", m.get("wsl_only_allow", [])), ("keep_out", m.get("keep_out", [])),
                     ("lint.e_allow", m.get("lint", {}).get("e_allow", []))):
        for ent in lst:
            if len(str(ent.get("reason", "")).strip()) < 10:
                raise ConfigError(f"{key} 사유는 10자 이상이어야 함: {ent.get('path')}")
    return m


def rel_norm(p):
    return p.replace(os.sep, "/")


def is_within(path, base):
    path, base = os.path.realpath(path), os.path.realpath(base)
    return path == base or path.startswith(base.rstrip("/") + "/")


def is_excluded(rel, globs):
    """'/' 없는 패턴은 모든 마디, '/' 있는 패턴은 상대경로(하위 포함)에 맞춘다."""
    parts = rel.split("/")
    for g in globs:
        if "/" in g:
            g2 = g.rstrip("/")
            if fnmatch.fnmatchcase(rel, g2) or fnmatch.fnmatchcase(rel, g2 + "/*"):
                return True
        elif any(fnmatch.fnmatchcase(p, g) for p in parts):
            return True
    return False

def git_toplevel_is(path):
    try:
        r = subprocess.run(["git", "-C", path, "rev-parse", "--show-toplevel"],
                           capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return False
    return r.returncode == 0 and os.path.realpath(r.stdout.strip()) == os.path.realpath(path)


def git_tracked(src):
    if not git_toplevel_is(src):
        return None
    try:
        r = subprocess.run(["git", "-C", src, "ls-files", "-z"], capture_output=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0:
        return None
    return {p.decode("utf-8", "surrogateescape") for p in r.stdout.split(b"\0") if p}

def file_kind(rel, text):
    """규칙 적용 범위 판정용 종류: py·sh·md·json·conf·awk·other."""
    base = rel.rsplit("/", 1)[-1]
    ext = os.path.splitext(base)[1].lower()
    if ext == ".py":
        return "py"
    if ext in (".sh", ".bash"):
        return "sh"
    if ext == ".md":
        return "md"
    if ext == ".json":
        return "json"
    if ext == ".conf" or base in ("tmux.conf", ".tmux.conf"):
        return "conf"
    if ext == ".awk":
        return "awk"
    if ext == "" and text is not None:
        first = text.split("\n", 1)[0]
        if first.startswith("#!"):
            if "python" in first:
                return "py"
            if re.search(r"\b(ba|da|z)?sh\b", first):
                return "sh"
    return "other"

# ─────────────────────────────── 변환 ───────────────────────────────

def general_rewrite(text, kind, rules):
    """순서 있는 치환표를 위에서부터 적용한다(긴 접두사 우선은 표 순서가 보장)."""
    for r in rules:
        only = r.get("only_kinds")
        if only and kind not in only:
            continue
        if r.get("regex"):
            text = re.sub(r["from"], r["to"], text)
        elif r["from"] in text:
            text = text.replace(r["from"], r["to"])
    return text


def _any_rule_hits(text, rules):
    return any((re.search(r["from"], text) if r.get("regex") else r["from"] in text) for r in rules)


def _boundary_ok(value, j):
    return j >= len(value) or not (value[j].isalnum() or value[j] in "_-.")


def _py_expr(value, rules, bases):
    """문자열 값 안의 접두사를 환경변수 식으로 바꾼 파이썬 식을 만든다. 일치 없으면 None."""
    pieces, buf, i, hit = [], "", 0, False
    while i < len(value):
        for r in rules:
            p = r["prefix"]
            if value.startswith(p, i) and _boundary_ok(value, i + len(p)):
                if buf:
                    pieces.append(repr(buf))
                pieces.append(bases[r["base"]])
                buf = r.get("suffix", "")
                i += len(p)
                hit = True
                break
        else:
            buf += value[i]
            i += 1
    if not hit:
        return None
    if buf:
        pieces.append(repr(buf))
    return "(" + " + ".join(pieces) + ")"


def py_transform(rel, text, manifest, report):
    """.py: 문자열 리터럴은 os.environ 식으로, 주석·독스트링은 일반 치환표로 바꾼다."""
    rules = manifest.get("py_rewrite", [])
    needles = [r["prefix"] for r in rules] + [manifest.get("src_user_home", (os.path.expanduser("~")))]
    if not any(n in text for n in needles):
        return general_rewrite_comments_only(rel, text, manifest, report)
    bases = dict(PY_BASES)
    if not re.search(r"^import\s+(?:[\w.]+\s*,\s*)*os\b", text, re.M):
        bases = {k: v.replace("os.", '__import__("os").') for k, v in bases.items()}
    try:
        toks = list(tokenize.generate_tokens(io.StringIO(text).readline))
    except (tokenize.TokenError, SyntaxError):
        report.py_unconverted.append(f"{rel}: 토큰 분석 실패 — 변환 보류")
        return text
    skip_types = {tokenize.COMMENT, tokenize.NL, tokenize.ENCODING}
    fs_start = getattr(tokenize, "FSTRING_START", None)
    fs_end = getattr(tokenize, "FSTRING_END", None)
    fs_mid = getattr(tokenize, "FSTRING_MIDDLE", None)
    str_like = {tokenize.STRING, fs_start, fs_end} - {None}
    repls = []

    def neighbor(i, step):
        j = i + step
        while 0 <= j < len(toks) and toks[j].type in skip_types:
            j += step
        return toks[j] if 0 <= j < len(toks) else None

    i = 0
    while i < len(toks):
        t = toks[i]
        if t.type == tokenize.COMMENT:
            new = general_rewrite(t.string, "py", manifest["rewrite"])
            if new != t.string:
                repls.append((t.start, t.end, new))
        elif fs_start is not None and t.type == fs_start:
            j, bad = i, False
            while j < len(toks) and toks[j].type != fs_end:
                if toks[j].type == fs_mid and any(n in toks[j].string for n in needles):
                    bad = True
                j += 1
            if bad:
                report.py_unconverted.append(f"{rel}:{t.start[0]}: f-string 안 경로 — 수작업 판단 필요")
            i = j
        elif t.type == tokenize.STRING and any(n in t.string for n in needles):
            prev, nxt = neighbor(i, -1), neighbor(i, 1)
            is_doc = (prev is None or prev.type in (tokenize.NEWLINE, tokenize.INDENT, tokenize.DEDENT)
                      or (prev.type == tokenize.OP and prev.string == ":")) \
                and (nxt is None or nxt.type in (tokenize.NEWLINE, tokenize.ENDMARKER))
            pfx = re.match(r"[A-Za-z]*", t.string).group().lower()
            if is_doc:
                new = general_rewrite(t.string, "py", manifest["rewrite"])
                if new != t.string:
                    repls.append((t.start, t.end, new))
            elif "b" in pfx or "f" in pfx:
                report.py_unconverted.append(f"{rel}:{t.start[0]}: bytes/f 문자열 — 수작업 판단 필요")
            elif (prev is not None and prev.type in str_like) or (nxt is not None and nxt.type in str_like):
                # 암묵 연결 묶음("a" "b" …) 전체를 값 하나로 합쳐 식 1개로 바꾼다(의미 보존).
                a = i
                while a > 0 and (toks[a - 1].type in skip_types or toks[a - 1].type == tokenize.STRING):
                    a -= 1
                while toks[a].type != tokenize.STRING:
                    a += 1
                b = i
                while b + 1 < len(toks) and (toks[b + 1].type in skip_types or toks[b + 1].type == tokenize.STRING):
                    b += 1
                while toks[b].type != tokenize.STRING:
                    b -= 1
                group = toks[a:b + 1]
                ok = all(g.type in (tokenize.STRING, tokenize.NL) for g in group) and not any(
                    g.type in str_like - {tokenize.STRING} for g in (neighbor(a, -1), neighbor(b, 1)) if g is not None)
                value = None
                if ok:
                    try:
                        parts = [ast.literal_eval(g.string) for g in group if g.type == tokenize.STRING]
                        if all(isinstance(p, str) for p in parts) and not any(
                                re.match(r"[A-Za-z]*", g.string).group().lower().count("f")
                                for g in group if g.type == tokenize.STRING):
                            value = "".join(parts)
                    except (ValueError, SyntaxError):
                        value = None
                expr = _py_expr(value, rules, bases) if value is not None else None
                if expr:
                    repls = [r for r in repls if not (group[0].start <= r[0] <= group[-1].end)]
                    repls.append((group[0].start, group[-1].end, expr))
                    i = b
                else:
                    report.py_unconverted.append(f"{rel}:{t.start[0]}: 암묵 문자열 연결(주석·f-string 섞임) — 수작업 판단 필요")
            else:
                try:
                    value = ast.literal_eval(t.string)
                except (ValueError, SyntaxError):
                    value = None
                expr = _py_expr(value, rules, bases) if isinstance(value, str) else None
                if expr:
                    repls.append((t.start, t.end, expr))
        i += 1
    if not repls:
        return text
    lines = text.splitlines(keepends=True)
    offs = [0]
    for ln in lines:
        offs.append(offs[-1] + len(ln))
    out = text
    for (sr, sc), (er, ec), new in sorted(repls, key=lambda x: x[0], reverse=True):
        a, b = offs[sr - 1] + sc, offs[er - 1] + ec
        out = out[:a] + new + out[b:]
    try:
        compile(out, rel, "exec")
    except SyntaxError as e:
        report.py_unconverted.append(f"{rel}: 변환 후 문법 오류({e.lineno}행) — 원문 유지")
        return text
    return out


def general_rewrite_comments_only(rel, text, manifest, report):
    """경로 접두사가 없는 .py 라도 주석 안 일반 표기(${HARNESS_HOME:-$HOME/.harness}/current/hooks 등)는 치환한다."""
    if not _any_rule_hits(text, manifest["rewrite"]):
        return text
    try:
        toks = list(tokenize.generate_tokens(io.StringIO(text).readline))
    except (tokenize.TokenError, SyntaxError):
        return text
    lines = text.splitlines(keepends=True)
    offs = [0]
    for ln in lines:
        offs.append(offs[-1] + len(ln))
    out = text
    for t in reversed(toks):
        if t.type == tokenize.COMMENT:
            new = general_rewrite(t.string, "py", manifest["rewrite"])
            if new != t.string:
                a, b = offs[t.start[0] - 1] + t.start[1], offs[t.end[0] - 1] + t.end[1]
                out = out[:a] + new + out[b:]
    return out


def prepend_after_header(text, add_lines):
    """shebang 과 맨 앞 주석 묶음 바로 뒤에 줄을 넣는다. 이미 있으면 그대로 둔다(멱등)."""
    if all(ln in text for ln in add_lines):
        return text
    lines = text.split("\n")
    idx = 1 if lines and lines[0].startswith("#!") else 0
    while idx < len(lines) and lines[idx].startswith("#"):
        idx += 1
    return "\n".join(lines[:idx] + list(add_lines) + lines[idx:])


def transform(dst_rel, data, manifest, report):
    """배포 사본 1개에 규칙을 적용한다. 텍스트가 아니면 그대로 둔다."""
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return data
    kind = file_kind(dst_rel, text)
    rules = [r for r in manifest.get("file_rules", []) if fnmatch.fnmatchcase(dst_rel, r["match"])]
    exclusive = any(r.get("exclusive") for r in rules)
    for r in rules:
        for rw in r.get("rewrite", []):
            text = text.replace(rw["from"], rw["to"])
    if not exclusive:
        if kind == "py":
            text = py_transform(dst_rel, text, manifest, report)
        else:
            text = general_rewrite(text, kind, manifest["rewrite"])
    for r in rules:
        if r.get("prepend_after_header"):
            text = prepend_after_header(text, r["prepend_after_header"])
    return text.encode("utf-8")

# ─────────────────────────────── 수집 ───────────────────────────────

def _mode_of(st_mode):
    return 0o755 if st_mode & 0o111 else 0o644


def _link_entry(src_abs, base_dir, report, rel):
    """symlink 처리: 같은 include 안을 가리키는 상대 링크는 보존, 그 밖은 실파일 복사."""
    target = os.readlink(src_abs)
    real = os.path.realpath(src_abs)
    if not os.path.isabs(target) and is_within(real, base_dir) and os.path.exists(real):
        return {"type": "link", "target": target}
    if os.path.isfile(real):
        with open(real, "rb") as f:
            return {"type": "file", "data": f.read(), "mode": _mode_of(os.stat(real).st_mode)}
    report.warnings.append(f"링크 대상이 파일이 아니어서 제외: {rel}")
    return None


def collect(src, manifest, report):
    """include 를 따라 배포 사본 목록 {dst_rel: entry} 를 만든다(변환 적용 전 원문)."""
    tracked = git_tracked(src) if manifest.get("tracked_only", True) else None
    required = set(manifest.get("required", []))
    globs = manifest["exclude_globs"]
    ex_skills = set(manifest["exclude_skills"])
    entries, src_of = {}, {}

    def take(srel, dst_rel, base_dir):
        if is_excluded(srel, globs):
            return
        if tracked is not None and srel not in tracked and srel not in required:
            report.untracked_skipped += 1
            return
        sabs = os.path.join(src, srel)
        if os.path.islink(sabs):
            ent = _link_entry(sabs, base_dir, report, srel)
        elif os.path.isfile(sabs):
            with open(sabs, "rb") as f:
                ent = {"type": "file", "data": f.read(), "mode": _mode_of(os.stat(sabs).st_mode)}
        else:
            return
        if ent is None:
            return
        entries[dst_rel] = ent
        src_of[dst_rel] = srel

    for inc in manifest["include"]:
        srel, drel, typ = inc["src"].strip("/"), inc["dst"].strip("/"), inc.get("type", "dir")
        sabs = os.path.join(src, srel)
        if not os.path.lexists(sabs):
            report.warnings.append(f"include 원본 없음: {srel}")
            continue
        if typ == "file":
            take(srel, drel, os.path.dirname(sabs))
            continue
        pat = inc.get("glob")
        for root, dirs, files in os.walk(sabs):
            dirs.sort()
            rrel = rel_norm(os.path.relpath(root, src))
            if typ == "skills" and os.path.realpath(root) == os.path.realpath(sabs):
                for d in list(dirs):
                    if d in ex_skills:
                        report.skipped_skills.append(d)
                        dirs.remove(d)
            keep = []
            for d in dirs:
                dabs = os.path.join(root, d)
                if os.path.islink(dabs):   # 디렉터리 링크: 내부 상대 링크만 링크로 보존
                    files.append(d)
                elif not is_excluded(f"{rrel}/{d}", globs):
                    keep.append(d)
            dirs[:] = keep
            for fn in sorted(files):
                if pat and not fnmatch.fnmatchcase(fn, pat):
                    continue
                frel = f"{rrel}/{fn}"
                sub = frel[len(srel):].lstrip("/")
                take(frel, f"{drel}/{sub}", sabs)
    missing = [r for r in sorted(required) if r not in src_of.values()]
    if missing:
        raise ConfigError("필수 포함(required) 파일이 빌드에 들어가지 않음: " + ", ".join(missing))
    return entries, src_of


def build_hooks_json(src, manifest, entries, report):
    """settings 의 hooks 키만 읽어 플러그인 hooks.json 을 만든다. 없는 대상 hook 은 뺀다."""
    hcfg = manifest.get("hooks") or {}
    data = None
    for cand in hcfg.get("sources", []):
        p = os.path.join(src, cand)
        if not os.path.isfile(p):
            continue
        try:
            with open(p, encoding="utf-8") as f:
                d = json.load(f)
        except (OSError, ValueError):
            raise ConfigError(f"hooks 원본 json 을 읽을 수 없음: {cand}")
        if isinstance(d, dict) and isinstance(d.get("hooks"), dict):
            data = d["hooks"]
            break
    if data is None:
        raise ConfigError("hooks 원본(sources) 중 'hooks' 키가 있는 파일이 없음")
    plugin_dir = manifest["plugin_dir"].strip("/")
    out = {}
    for ev, groups in data.items():
        new_groups = []
        for g in groups:
            new_hooks = []
            for h in g.get("hooks", []):
                h2 = dict(h)
                if h.get("type") == "command" and isinstance(h.get("command"), str):
                    cmd = h["command"]
                    for pre in hcfg.get("path_prefixes", []):
                        cmd = cmd.replace(pre, "${CLAUDE_PLUGIN_ROOT}/hooks/")
                    h2["command"] = cmd
                    miss = [t for t in PLUGIN_TOKEN_RE.findall(cmd) if f"{plugin_dir}/{t}" not in entries]
                    if miss:
                        report.dropped_hooks.append(f"{ev}[{g.get('matcher', '')}] 대상 없음: {', '.join(miss)}")
                        continue
                new_hooks.append(h2)
            if new_hooks:
                g2 = dict(g)
                g2["hooks"] = new_hooks
                new_groups.append(g2)
        if new_groups:
            out[ev] = new_groups
    pre = hcfg.get("prepend")
    if pre:
        cmds = pre.get("commands") or [{"command": pre["command"], "timeout": pre.get("timeout", 5)}]
        grp = {"matcher": "", "hooks": [{"type": "command", "command": c["command"],
                                         "timeout": c.get("timeout", 5)} for c in cmds]}
        out.setdefault(pre["event"], []).insert(0, grp)
    body = json.dumps({"description": "harness_bundle_build.py 가 settings hooks 에서 생성한 파일이다. 직접 고치지 않는다.",
                       "hooks": out}, ensure_ascii=False, indent=2) + "\n"
    return body.encode("utf-8")


def build_entries(src, manifest, report):
    raw, src_of = collect(src, manifest, report)
    built = {}
    for dst in sorted(raw):
        ent = raw[dst]
        if any(fnmatch.fnmatchcase(dst, k["path"]) for k in manifest.get("keep_out", [])):
            report.warnings.append(f"keep_out — 배포본 쪽 파일을 유지하고 소스로 덮어쓰지 않음: {dst}")
            continue
        if ent["type"] == "file":
            ent = dict(ent, data=transform(dst, ent["data"], manifest, report))
        built[dst] = ent
    hout = (manifest.get("hooks") or {}).get("out")
    if hout:
        built[hout] = {"type": "file", "data": build_hooks_json(src, manifest, built, report), "mode": 0o644}
    return built, src_of

# ─────────────────────────────── 반영 ───────────────────────────────

def managed_roots(manifest):
    roots = [inc["dst"].strip("/") for inc in manifest["include"]]
    hout = (manifest.get("hooks") or {}).get("out")
    if hout:
        roots.append(hout)
    return sorted(set(roots))


def is_preserved(rel, manifest):
    return any(fnmatch.fnmatchcase(rel, p["path"])
               for p in manifest.get("preserve", []) + manifest.get("keep_out", []))


def _existing(out, roots):
    found = {}
    for r in roots:
        a = os.path.join(out, r)
        if os.path.islink(a) or os.path.isfile(a):
            found[r] = a
        elif os.path.isdir(a):
            for root, dirs, files in os.walk(a):
                dirs.sort()
                for d in list(dirs):
                    if os.path.islink(os.path.join(root, d)):
                        files.append(d)
                        dirs.remove(d)
                for fn in files:
                    p = os.path.join(root, fn)
                    found[rel_norm(os.path.relpath(p, out))] = p
    return found


def _same(path, ent):
    if ent["type"] == "link":
        return os.path.islink(path) and os.readlink(path) == ent["target"]
    if os.path.islink(path) or not os.path.isfile(path):
        return False
    if (os.stat(path).st_mode & 0o777) != ent["mode"]:
        return False
    with open(path, "rb") as f:
        return f.read() == ent["data"]


def sync(out, entries, manifest, report):
    """관리 영역만 entries 와 같게 맞춘다. preserve 와 관리 영역 밖은 건드리지 않는다."""
    roots = managed_roots(manifest)
    existing = _existing(out, roots)
    for rel in sorted(set(existing) - set(entries)):
        if is_preserved(rel, manifest):
            continue
        os.remove(existing[rel])
        report.changes["del"].append(rel)
    for rel in sorted(entries):
        ent, path = entries[rel], os.path.join(out, rel)
        if os.path.lexists(path) and _same(path, ent):
            continue
        report.changes["mod" if os.path.lexists(path) else "add"].append(rel)
        if os.path.isdir(path) and not os.path.islink(path):
            shutil.rmtree(path)
        elif os.path.lexists(path):
            os.remove(path)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if ent["type"] == "link":
            os.symlink(ent["target"], path)
        else:
            with open(path, "wb") as f:
                f.write(ent["data"])
            os.chmod(path, ent["mode"])
    for r in roots:   # 비게 된 하위 폴더 정리(관리 루트 자체는 남긴다)
        a = os.path.join(out, r)
        if os.path.isdir(a) and not os.path.islink(a):
            for root, dirs, files in os.walk(a, topdown=False):
                if root != a and not os.listdir(root):
                    os.rmdir(root)


def dirty_paths(out, manifest):
    """out 이 git 저장소면 관리 영역 안 미커밋 변경(추적·미추적) 목록을 돌려준다."""
    if not os.path.isdir(out) or not git_toplevel_is(out):
        return []
    roots = [r for r in managed_roots(manifest) if os.path.lexists(os.path.join(out, r))]
    if not roots:
        return []
    r = subprocess.run(["git", "-C", out, "status", "--porcelain", "--"] + roots,
                       capture_output=True, text=True, timeout=60)
    return [ln for ln in r.stdout.splitlines() if ln.strip()]

# ─────────────────────────────── lint ───────────────────────────────

def _iter_files(root, scope):
    for s in scope:
        a = os.path.join(root, s)
        if os.path.isfile(a) or os.path.islink(a):
            yield s, a
        elif os.path.isdir(a):
            for r, dirs, files in os.walk(a):
                dirs[:] = sorted(d for d in dirs if d != ".git")
                for d in dirs:
                    if os.path.islink(os.path.join(r, d)):
                        files.append(d)
                for fn in sorted(files):
                    p = os.path.join(r, fn)
                    yield rel_norm(os.path.relpath(p, root)), p


def _read_text(p):
    try:
        with open(p, "rb") as f:
            return f.read().decode("utf-8")
    except (OSError, UnicodeDecodeError):
        return None


def lint(out, manifest, report):
    L = manifest["lint"]
    home = manifest.get("src_user_home", (os.path.expanduser("~")))
    plugin_dir = manifest["plugin_dir"].strip("/")
    a2 = [re.compile(p) for p in L.get("a2_patterns", [])]
    wsl = [re.compile(p) for p in L.get("wsl_patterns", [])]
    guards = [re.compile(p) for p in L.get("guard_patterns", [])]
    cur = re.compile(L["current_ref_pattern"])
    allow = manifest.get("wsl_only_allow", [])
    e_allow = L.get("e_allow", [])
    code_kinds = set(L.get("code_kinds", []))
    cred_names = {".credentials.json", "claude-credentials.json", ".claude.json", ".mcp.json", "INFRA.md"}
    for rel, p in _iter_files(out, L.get("scope", [])):
        if os.path.islink(p):
            t = os.readlink(p)
            if os.path.isabs(t) or not is_within(os.path.join(os.path.dirname(p), t), out):
                code = "D" if os.path.basename(t) in cred_names else "LINK_OUT"
                report.add_lint(code, f"{rel} -> 배포본 밖을 가리키는 링크")
            continue
        text = _read_text(p)
        if text is None:
            continue
        kind = file_kind(rel, text)
        lines = text.split("\n")
        guarded = any(g.search(text) for g in guards)
        allowed = [a for a in allow if fnmatch.fnmatchcase(rel, a["path"])]
        for n, ln in enumerate(lines, 1):
            if home in ln:
                report.add_lint("a", f"{rel}:{n}")
            for rx in a2:
                if rx.search(ln):
                    report.add_lint("a2", f"{rel}:{n} [{rx.pattern}]")
                    break
            # (b)·(e) 는 실행되는 줄만 본다. 셸·py·conf·awk 의 '#' 주석 줄은 실행되지 않는다.
            if kind in ("sh", "py", "conf", "awk") and ln.lstrip().startswith("#"):
                continue
            if kind in code_kinds and not guarded:
                for rx in wsl:
                    if rx.search(ln):
                        if not any(not a.get("pattern") or re.search(a["pattern"], ln) for a in allowed):
                            report.add_lint("b", f"{rel}:{n} [{rx.pattern}]")
                        break
            for m in cur.finditer(ln):
                ref = m.group(1)
                nxt = ln[m.end():m.end() + 1]
                if nxt and nxt in "$*{<[?":
                    ref = ref.rsplit("/", 1)[0] if "/" in ref else ""
                ref = ref.rstrip(".,:;")
                if not ref or any(fnmatch.fnmatchcase(ref, a["path"]) for a in e_allow):
                    continue
                if not os.path.lexists(os.path.join(out, plugin_dir, ref)):
                    item = f"{rel}:{n} current/{ref}"
                    if kind in code_kinds:
                        report.add_lint("e", item)
                    else:
                        report.add_lint_warn("e", item)
    # (c) hooks.json 대상 실재·실행 비트
    hout = (manifest.get("hooks") or {}).get("out")
    hp = os.path.join(out, hout) if hout else None
    if hp and os.path.isfile(hp):
        try:
            with open(hp, encoding="utf-8") as f:
                hj = json.load(f).get("hooks", {})
        except (OSError, ValueError):
            hj = None
            report.add_lint("c", f"{hout}: json 파싱 실패")
        for ev, groups in (hj or {}).items():
            for g in groups:
                for h in g.get("hooks", []):
                    c = h.get("command")
                    if h.get("type") != "command" or c is None:
                        continue
                    cmd = " ".join(c) if isinstance(c, list) else c
                    for t in PLUGIN_TOKEN_RE.findall(cmd):
                        if not os.path.exists(os.path.join(out, plugin_dir, t)):
                            report.add_lint("c", f"{ev}: 대상 없음 {t}")
                    first = c[0] if isinstance(c, list) else (cmd.split() or [""])[0].strip("\"'")
                    if "${CLAUDE_PLUGIN_ROOT}/" in first:
                        f = os.path.join(out, plugin_dir, first.split("${CLAUDE_PLUGIN_ROOT}/", 1)[1])
                        if os.path.exists(f) and not os.access(f, os.X_OK):
                            report.add_lint("c", f"{ev}: 실행 비트 없음 {first}")
                    elif first and first not in INTERPRETERS and not first.startswith(("mkdir", "ln")):
                        report.add_lint_warn("c", f"{ev}: 플러그인 밖 명령 {first}")
    elif hp:
        report.add_lint("c", f"{hout} 없음")
    # (f) bin 하드코딩 프로필 루트
    forb = L.get("bin_profile_forbidden")
    for b in L.get("bin_profile_files", []):
        t = _read_text(os.path.join(out, b))
        if t is not None and forb and forb in t:
            report.add_lint("f", f"{b}: {forb} 잔존")
    # (d) 자격증명 스캔
    cs = os.path.join(out, L.get("credential_scan", "scripts/credential_scan.sh"))
    if not os.path.isfile(cs):
        report.add_lint("d", f"{L.get('credential_scan')} 없음")
    else:
        try:
            r = subprocess.run(["bash", cs, out], capture_output=True, text=True, timeout=80)
            if r.returncode != 0:
                tail = [ln for ln in (r.stdout + r.stderr).splitlines() if ln.strip()][-MAX_SHOW:]
                report.add_lint("d", f"credential_scan rc={r.returncode}")
                for ln in tail:
                    report.add_lint("d", "  " + ln[:200])
        except subprocess.TimeoutExpired:
            report.add_lint("d", "credential_scan 시간 초과(80초)")

# ─────────────────────────────── 출력 ───────────────────────────────

def skill_counts(src, out, manifest):
    sk_src = os.path.join(src, ".claude/skills") if src else None
    sk_out_rel = next((i["dst"].strip("/") for i in manifest["include"] if i.get("type") == "skills"), None)

    def names(d):
        if not d or not os.path.isdir(d):
            return set()
        return {n for n in os.listdir(d) if os.path.isfile(os.path.join(d, n, "SKILL.md"))}

    s = names(sk_src)
    o = names(os.path.join(out, sk_out_rel)) if sk_out_rel else set()
    ex = s & set(manifest["exclude_skills"])
    pres = {n for n in o - s if is_preserved(f"{sk_out_rel}/{n}/SKILL.md", manifest)}
    return len(s), len(ex), len(pres), len(o), sorted(pres)


def print_report(report, title):
    print(f"── {title} ──")
    for w in report.warnings:
        print(f"  [경고] {w}")
    if report.py_unconverted:
        print(f"  [py 변환 보류] {len(report.py_unconverted)}건")
        for x in report.py_unconverted[:MAX_SHOW]:
            print(f"    {x}")
    total = 0
    for code in ("a", "a2", "b", "c", "d", "e", "f", "LINK_OUT"):
        items = report.lint.get(code, [])
        total += len(items)
        print(f"  lint ({code}) {'통과' if not items else f'실패 {len(items)}건'}")
        for x in items[:MAX_SHOW]:
            print(f"    {x}")
        if len(items) > MAX_SHOW:
            print(f"    … 외 {len(items) - MAX_SHOW}건 (--report 로 전체 확인)")
    for code, items in sorted(report.lint_warn.items()):
        print(f"  lint 경고 ({code}) {len(items)}건 (실패 아님)")
        for x in items[:10]:
            print(f"    {x}")
    return total


def main(argv=None):
    ap = argparse.ArgumentParser(description="AI 하네스 → 플러그인 배포본 빌드·lint")
    ap.add_argument("--src", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--manifest", default=DEFAULT_MANIFEST)
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--dry-run", action="store_true")
    g.add_argument("--check", action="store_true")
    ap.add_argument("--allow-dirty", action="store_true")
    ap.add_argument("--report")
    a = ap.parse_args(argv)
    src, out = os.path.abspath(a.src), os.path.abspath(a.out)
    report = Report()
    tmp = None
    try:
        manifest = load_manifest(a.manifest)
        if a.check:
            if not os.path.isdir(out):
                raise ConfigError(f"out 이 없음: {out}")
            lint(out, manifest, report)
            target = out
        else:
            if not os.path.isdir(src):
                raise ConfigError(f"src 가 없음: {src}")
            if is_within(out, src) and os.path.realpath(out) == os.path.realpath(src):
                raise ConfigError("src 와 out 이 같음")
            entries, _ = build_entries(src, manifest, report)
            if a.dry_run:
                tmp = tempfile.mkdtemp(prefix="harness_bundle_dry_")
                target = os.path.join(tmp, "out")
                if os.path.isdir(out):
                    shutil.copytree(out, target, symlinks=True, ignore=shutil.ignore_patterns(".git"))
                else:
                    os.makedirs(target)
            else:
                dirty = dirty_paths(out, manifest)
                if dirty and not a.allow_dirty:
                    print(f"[거부] out 관리 영역에 미커밋 변경 {len(dirty)}건 — 커밋하거나 --allow-dirty 로 재실행")
                    for ln in dirty[:MAX_SHOW]:
                        print(f"  {ln}")
                    return RC_DIRTY
                os.makedirs(out, exist_ok=True)
                target = out
            sync(target, entries, manifest, report)
            lint(target, manifest, report)
            n_s, n_ex, n_p, n_o, pres = skill_counts(src, target, manifest)
            print(f"[빌드] {'dry-run(out 무변경)' if a.dry_run else '반영'} — 배포 사본 {len(entries)}개, "
                  f"미추적 제외 {report.untracked_skipped}개")
            print(f"[스킬] 소스 {n_s} − 제외 {n_ex} + 보존(preserve) {n_p} = 배포 {n_o}"
                  f"{' (일치)' if n_s - n_ex + n_p == n_o else ' (불일치!)'}"
                  f"{' — 보존: ' + ', '.join(pres) if pres else ''}")
            print(f"[변경] 추가 {len(report.changes['add'])} · 수정 {len(report.changes['mod'])} · "
                  f"삭제 {len(report.changes['del'])}")
            if a.dry_run:
                for k in ("add", "mod", "del"):
                    for x in report.changes[k][:MAX_SHOW]:
                        print(f"  {k} {x}")
            print(f"[hooks.json] 빠진 항목 {len(report.dropped_hooks)}건")
            for x in report.dropped_hooks:
                print(f"  {x}")
        fails = print_report(report, f"lint 대상 {target if not tmp else '(dry-run 임시 사본)'}")
        rc = RC_LINT if fails else RC_OK
        print(f"[결과] rc={rc}")
        return rc
    except ConfigError as e:
        report.errors.append(str(e))
        print(f"[오류] {e}")
        return RC_CONFIG
    finally:
        if a.report:
            try:
                with open(a.report, "w", encoding="utf-8") as f:
                    json.dump(report.to_json(), f, ensure_ascii=False, indent=2)
            except OSError:
                pass
        if tmp:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
