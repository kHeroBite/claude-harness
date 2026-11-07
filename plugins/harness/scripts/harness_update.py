#!/usr/bin/env python3
# oUpdate 엔진 — 배포 repo 의 최신 판을 HARNESS_HOME/releases 로 받아 active 링크를 원자 교체하고 연쇄 적용(requires·breaking·migrations·post_actions)을 처리한다
"""harness_update.py (py3.10, Tier3 범용 — 프로젝트명·경로 하드코딩 없음)

하위 명령
  status [--no-fetch]
  apply [--ref R] [--force] [--dry-run] [--accept-breaking] [--non-interactive] [--yes] [--no-sudo]
        [--skip-plugin-update] [--ai-root P]
  rollback
  verify
  selftest
  write-release --repo R --version V --summary S --source-commit C [--breaking] [--post-action KIND:TEXT]...
  lint-release F [--repo R]
공통: --harness-home H (생략 시 자기 위치 → HARNESS_HOME → rc 표식 블록 → install.json → ~/.harness)

종료코드: 0 OK·UP_TO_DATE / 1 FAIL(원복) / 2 전제 불충족 / 3 REFUSE / 4 LOCKED / 5 PARTIAL / 6 NEEDS / 7 BREAKING

apply 순서(고정): mktemp 추출 → 사전 검증 → requires → breaking → migrations(pre) → 대상 home releases/ 로 rename·copy
                → active 원자 교체(+링크·src ff·플러그인·venv·facade·current) → migrations(post) → 사후 검증 → post_actions·state 확정·prune
자격증명 파일은 열지 않는다. settings.json·실행 중 프로세스·tmux·current(이미 있으면)는 바꾸지 않는다.
"""
import argparse
import ast
import datetime as _dt
import fcntl
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

HERE = os.path.dirname(os.path.realpath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
try:
    import harness_ai_root as _air  # 같은 폴더 모듈
except ImportError:  # pragma: no cover - 배포 트리 손상 시
    _air = None

RC_OK, RC_FAIL, RC_PRE, RC_REFUSE, RC_LOCKED, RC_PARTIAL, RC_NEEDS, RC_BREAKING = 0, 1, 2, 3, 4, 5, 6, 7

PLUG = "plugins/harness"
PLUGIN_JSON = PLUG + "/.claude-plugin/plugin.json"
MARKET_JSON = ".claude-plugin/marketplace.json"
PLUGIN_ID = "harness@harness-marketplace"
MARKET_NAME = "harness-marketplace"
CODEX_PLUGIN_ID = "codex@openai-codex"
CODEX_CONNECT_CMD = "claude plugin marketplace add openai/codex-plugin-cc && claude plugin install codex@openai-codex"
BIN_NAMES = ("cc", "ccc", "lcc", "lccc", "claude-as", "cas")
RC_FILES = (".bashrc", ".bash_profile", ".bash_login", ".profile")
BLOCK_BEGIN = "# >>> harness PATH"
BLOCK_END = "# <<< harness PATH"
REQUIRED_TREE_FILES = (
    PLUG + "/skills/oUpdate/SKILL.md",
    PLUG + "/skills/ocopy/SKILL.md",
    PLUG + "/scripts/harness_update.py",
    PLUG + "/scripts/harness_ai_root.py",
    PLUG + "/scripts/ocopy_link.py",
    "install-online.sh",
    "requires.txt",
)
RELEASE_KEYS = {"schema": int, "version": str, "source_commit": str, "built_at": str, "summary": str,
                "breaking": bool, "requires": list, "migrations": list, "post_actions": list, "history": list}
POST_KINDS = ("new_shell", "restart_cc", "reload_plugin", "note")
NEEDS_KINDS = ("required", "optional")
HISTORY_MAX = 20
KEEP_RELEASES = 3
GIT_TIMEOUT = 85
PLUGIN_TIMEOUT = 90


# ───────────────────────── 공통 도우미 ─────────────────────────
def _now():
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _home():
    return os.path.expanduser("~")


def _p(*a):
    print(*a, flush=True)


def _trace(step):
    """시험용 단계 기록(HARNESS_UPDATE_TRACE 파일이 지정됐을 때만)."""
    path = os.environ.get("HARNESS_UPDATE_TRACE")
    if path:
        with open(path, "a", encoding="utf-8") as f:
            f.write(step + "\n")


def _fault(name):
    """시험용 고장 주입 — HARNESS_UPDATE_TEST=1 일 때만 읽는다."""
    if os.environ.get("HARNESS_UPDATE_TEST") != "1":
        return False
    return name in (os.environ.get("HARNESS_UPDATE_TEST_FAULT") or "").split(",")


def _redact(s):
    """URL 의 사용자정보(토큰) 부분을 지운다."""
    return re.sub(r"(https?://)[^/@\s]+@", r"\1", s or "")


def vtuple(v):
    """'1.3.0' → (1,3,0). 숫자가 아닌 조각은 0 으로 본다."""
    out = []
    for part in re.split(r"[.\-+]", str(v or "").lstrip("v")):
        m = re.match(r"\d+", part)
        out.append(int(m.group(0)) if m else 0)
    while len(out) < 3:
        out.append(0)
    return tuple(out)


def _load_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {} if default is None else default


def _save_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, path)


def git(args, cwd=None, timeout=GIT_TIMEOUT, binary=False):
    return subprocess.run(["git"] + args, cwd=cwd, capture_output=True, text=not binary, timeout=timeout)


def atomic_symlink(target, path):
    """임시 링크 + rename 으로 링크를 원자 교체한다."""
    tmp = "%s.tmp.%d" % (path, os.getpid())
    if os.path.lexists(tmp):
        os.unlink(tmp)
    os.symlink(target, tmp)
    os.replace(tmp, path)


def _abs_link_target(path):
    v = os.readlink(path)
    return v if os.path.isabs(v) else os.path.normpath(os.path.join(os.path.dirname(path), v))


def _inside(p, root):
    p = os.path.normpath(p)
    root = os.path.normpath(root)
    return p == root or p.startswith(root + os.sep)


def _is_interactive(args):
    return (not getattr(args, "non_interactive", False)) and sys.stdin.isatty()


# ───────────────────────── 경로 해석 ─────────────────────────
def rc_block_value(var):
    """rc 표식 블록에서 export 값을 읽는다."""
    for name in RC_FILES:
        path = os.path.join(_home(), name)
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                lines = f.read().splitlines()
        except OSError:
            continue
        inside, val = False, None
        for s in lines:
            if s == BLOCK_BEGIN:
                inside = True
                continue
            if s == BLOCK_END:
                inside = False
                continue
            m = re.match(r'^export %s="(.*)"$' % re.escape(var), s) if inside else None
            if m:
                val = m.group(1)
        if val:
            return val
    return None


def is_legacy_layout(h):
    """HARNESS_HOME/current 가 src/plugins/harness 를 가리키고 active 가 없으면 레거시."""
    cur = os.path.join(h, "current")
    src = os.path.join(h, "src")
    if os.path.lexists(os.path.join(h, "active")) or not os.path.islink(cur):
        return False
    if not os.path.isdir(os.path.join(src, ".git")):
        return False
    return os.path.realpath(cur) == os.path.realpath(os.path.join(src, PLUG))


def _self_home():
    """이 스크립트가 <H>/releases/<r>/plugins/harness/scripts/ 안에 있으면 H."""
    d = HERE
    for _ in range(3):
        d = os.path.dirname(d)
    if os.path.basename(os.path.dirname(d)) == "releases":
        return os.path.dirname(os.path.dirname(d))
    return None


def resolve_home(arg=None, ai_root=None):
    cands = [arg, _self_home(), os.environ.get("HARNESS_HOME"), rc_block_value("HARNESS_HOME")]
    ph = _air.read_project_home() if _air else None
    if ph:
        h = os.path.join(os.path.abspath(ph), "AI", ".harness")
        if os.path.exists(os.path.join(h, "install.json")) or os.path.exists(os.path.join(h, "update_state.json")):
            cands.append(h)
    cands.append(os.path.join(_home(), ".harness"))
    home = next(os.path.abspath(os.path.expanduser(c)) for c in cands if c)
    # 레거시 home 이 이미 새 home 으로 이전됐으면 새 home 을 쓴다
    if not arg:
        roots = [ai_root] if ai_root else []
        if ph:
            roots.append(os.path.join(os.path.abspath(ph), "AI"))
        for r in roots:
            nh = os.path.join(r, ".harness")
            st = _load_json(os.path.join(nh, "update_state.json"))
            if st.get("legacy_home") and os.path.realpath(st["legacy_home"]) == os.path.realpath(home):
                return nh
    return home


def resolve_ai_root(arg, home):
    if arg:
        return os.path.abspath(os.path.expanduser(arg))
    inst = _load_json(os.path.join(home, "install.json"))
    if inst.get("ai_root"):
        return inst["ai_root"]
    # <AI>/.harness 구조면 부모 폴더의 facade 표식으로 AI 루트를 안다
    parent = os.path.dirname(os.path.abspath(home))
    if _air and _air.has_marker(parent):
        mk = _load_json(os.path.join(parent, _air.MARKER_NAME))
        if os.path.realpath(mk.get("harness_home") or "") == os.path.realpath(home):
            return parent
    if _air:
        return _air.resolve()
    return None


# ───────────────────────── 상태 ─────────────────────────
def state_path(home):
    return os.path.join(home, "update_state.json")


def load_state(home):
    st = _load_json(state_path(home))
    for k, v in (("schema", 1), ("current", None), ("previous", None), ("pending", None), ("plugin", None)):
        st.setdefault(k, v)
    st.setdefault("migrations_done", [])
    st.setdefault("history", [])
    return st


def save_state(home, st):
    st["history"] = (st.get("history") or [])[-HISTORY_MAX:]
    _save_json(state_path(home), st)


class Lock:
    """HARNESS_HOME/.update.lock flock(비차단)."""

    def __init__(self, home, path=None):
        self.path = path or os.path.join(home, ".update.lock")
        self.fd = None

    def acquire(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        self.fd = os.open(self.path, os.O_RDWR | os.O_CREAT, 0o644)
        try:
            fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(self.fd)
            self.fd = None
            return False
        return True

    def release(self):
        if self.fd is not None:
            fcntl.flock(self.fd, fcntl.LOCK_UN)
            os.close(self.fd)
            self.fd = None


# ───────────────────────── 메타(RELEASE.json·requires) ─────────────────────────
def parse_requires(text):
    """requires.txt → [{name,min,need,install{...}}]."""
    out = []
    for raw in text.splitlines():
        s = raw.strip()
        if not s or s.startswith("#"):
            continue
        parts = s.split("|")
        item = {"name": parts[0].strip(), "min": (parts[1].strip() if len(parts) > 1 else ""),
                "need": (parts[2].strip() if len(parts) > 2 and parts[2].strip() else "required")}
        inst = {}
        for p in parts[3:]:
            if "=" in p:
                k, v = p.split("=", 1)
                inst[k.strip()] = v.strip()
        if inst:
            item["install"] = inst
        out.append(item)
    return out


def tree_version(root):
    rel = _load_json(os.path.join(root, "RELEASE.json"))
    if rel.get("version"):
        return rel["version"]
    return _load_json(os.path.join(root, PLUGIN_JSON)).get("version")


def _migration_decl(path):
    """마이그레이션 스크립트의 MIGRATION_ID·SINCE·PHASE 상수를 ast 로 읽는다(실행하지 않음)."""
    try:
        with open(path, encoding="utf-8") as f:
            tree = ast.parse(f.read(), path)
    except (OSError, SyntaxError):
        return {}
    out = {}
    for node in tree.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            if isinstance(node.value, ast.Constant) and isinstance(node.value.value, str):
                out[node.targets[0].id] = node.value.value
    return out


def lint_release(path, repo=None):
    """RELEASE.json 스키마 검사. 반환: 오류 목록(빈 목록이면 통과)."""
    errs = []
    try:
        with open(path, encoding="utf-8") as f:
            rel = json.load(f)
    except (OSError, ValueError) as e:
        return ["읽기/JSON 실패: %s" % e.__class__.__name__]
    if not isinstance(rel, dict):
        return ["최상위가 객체가 아님"]
    repo = repo or os.path.dirname(os.path.abspath(path))
    for k, t in RELEASE_KEYS.items():
        if k not in rel:
            errs.append("필수 키 없음: %s" % k)
        elif not isinstance(rel[k], t) or (t is int and isinstance(rel[k], bool)):
            errs.append("타입 오류: %s" % k)
    if errs:
        return errs
    if rel["schema"] != 1:
        errs.append("schema 는 1 이어야 함")
    ver = rel["version"]
    if not re.match(r"^\d+\.\d+\.\d+$", ver):
        errs.append("version 형식 오류: %s" % ver)
    pj = os.path.join(repo, PLUGIN_JSON)
    if os.path.exists(pj) and _load_json(pj).get("version") != ver:
        errs.append("plugin.json version 불일치")
    mj = os.path.join(repo, MARKET_JSON)
    if os.path.exists(mj):
        mv = [p.get("version") for p in _load_json(mj).get("plugins", []) if p.get("name") == "harness"]
        if mv and mv[0] != ver:
            errs.append("marketplace.json version 불일치")
    for i, r in enumerate(rel["requires"]):
        if not isinstance(r, dict) or not r.get("name") or r.get("need") not in NEEDS_KINDS \
                or not isinstance(r.get("min", ""), str):
            errs.append("requires[%d] 형식 오류" % i)
    ids = set()
    for i, m in enumerate(rel["migrations"]):
        if not isinstance(m, dict) or not all(isinstance(m.get(k), str) and m.get(k) for k in ("id", "since", "phase", "script")):
            errs.append("migrations[%d] 형식 오류" % i)
            continue
        if m["phase"] not in ("pre", "post"):
            errs.append("migrations[%d] phase 오류" % i)
        if m["id"] in ids:
            errs.append("migrations id 중복: %s" % m["id"])
        ids.add(m["id"])
        if not os.path.isfile(os.path.join(repo, m["script"])):
            errs.append("migration 스크립트 없음: %s" % m["script"])
    for i, a in enumerate(rel["post_actions"]):
        if not isinstance(a, dict) or a.get("kind") not in POST_KINDS or not isinstance(a.get("text"), str):
            errs.append("post_actions[%d] 형식 오류" % i)
    prev = None
    for i, h in enumerate(rel["history"]):
        if not isinstance(h, dict) or not isinstance(h.get("version"), str):
            errs.append("history[%d] 형식 오류" % i)
            continue
        if prev is not None and vtuple(h["version"]) <= vtuple(prev):
            errs.append("history 가 단조 증가가 아님(%s 뒤 %s)" % (prev, h["version"]))
        prev = h["version"]
    if prev is not None and vtuple(prev) >= vtuple(ver):
        errs.append("history 마지막 판(%s)이 version 이상" % prev)
    if len(rel["history"]) > HISTORY_MAX:
        errs.append("history 가 %d 건 초과" % HISTORY_MAX)
    return errs


def cmd_lint_release(a):
    errs = lint_release(a.file, a.repo)
    if errs:
        _p("LINT FAIL %s" % a.file)
        for e in errs:
            _p("  - " + e)
        return RC_FAIL
    _p("LINT OK %s" % a.file)
    return RC_OK


def cmd_write_release(a):
    repo = os.path.abspath(a.repo)
    path = os.path.join(repo, "RELEASE.json")
    old = _load_json(path)
    history = list(old.get("history") or [])
    if old.get("version") and vtuple(old["version"]) < vtuple(a.version):
        history.append({"version": old["version"], "breaking": bool(old.get("breaking")),
                        "summary": old.get("summary", ""), "post_actions": old.get("post_actions") or []})
    history = [h for h in history if vtuple(h.get("version")) < vtuple(a.version)][-HISTORY_MAX:]
    migrations = [m for m in (old.get("migrations") or []) if isinstance(m, dict) and m.get("id")]
    known = {m["id"] for m in migrations}
    mdir = os.path.join(repo, PLUG, "scripts", "migrations")
    if os.path.isdir(mdir):
        for fn in sorted(os.listdir(mdir)):
            if not re.match(r"^m\d{4}_.*\.py$", fn):
                continue
            d = _migration_decl(os.path.join(mdir, fn))
            mid = d.get("MIGRATION_ID") or fn[:-3]
            if mid in known:
                continue
            migrations.append({"id": mid, "since": d.get("SINCE") or a.version, "phase": d.get("PHASE") or "pre",
                               "script": "%s/scripts/migrations/%s" % (PLUG, fn)})
            known.add(mid)
    req_path = os.path.join(repo, "requires.txt")
    requires = []
    if os.path.exists(req_path):
        with open(req_path, encoding="utf-8") as f:
            requires = parse_requires(f.read())
    post = []
    for spec in a.post_action or []:
        kind, _, text = spec.partition(":")
        post.append({"kind": kind.strip(), "text": text.strip()})
    rel = {"schema": 1, "version": a.version, "source_commit": a.source_commit, "built_at": _now(),
           "summary": a.summary, "breaking": bool(a.breaking), "requires": requires,
           "migrations": migrations, "post_actions": post, "history": history}
    _save_json(path, rel)
    errs = lint_release(path, repo)
    if errs:
        _p("WRITE_RELEASE LINT_FAIL %s" % path)
        for e in errs:
            _p("  - " + e)
        return RC_FAIL
    _p("WRITE_RELEASE OK %s version=%s migrations=%d history=%d" % (path, a.version, len(migrations), len(history)))
    return RC_OK


# ───────────────────────── git 대상 결정·추출 ─────────────────────────
def latest_target(src, ref=None):
    """대상 sha 와 라벨. ref > 최신 v* 태그 > 원격 기본 브랜치 HEAD."""
    if ref:
        for cand in (ref, "origin/" + ref):
            r = git(["-C", src, "rev-parse", "--verify", "-q", cand + "^{commit}"])
            if r.returncode == 0:
                return r.stdout.strip(), ref
        return None, ref
    tags = [t for t in git(["-C", src, "tag", "-l", "v*"]).stdout.split() if re.match(r"^v\d+\.\d+\.\d+$", t)]
    if tags:
        t = max(tags, key=vtuple)
        r = git(["-C", src, "rev-parse", "--verify", "-q", t + "^{commit}"])
        if r.returncode == 0:
            return r.stdout.strip(), t
    for cand in ("origin/HEAD", "origin/main", "origin/master", "HEAD"):
        r = git(["-C", src, "rev-parse", "--verify", "-q", cand + "^{commit}"])
        if r.returncode == 0:
            return r.stdout.strip(), cand
    return None, None


def meta_at(src, sha):
    """대상 커밋의 RELEASE.json(없으면 plugin.json version 만)."""
    r = git(["-C", src, "show", "%s:RELEASE.json" % sha])
    if r.returncode == 0:
        try:
            rel = json.loads(r.stdout)
            if isinstance(rel, dict) and rel.get("version"):
                return rel
        except ValueError:
            pass
    r = git(["-C", src, "show", "%s:%s" % (sha, PLUGIN_JSON)])
    ver = None
    if r.returncode == 0:
        try:
            ver = json.loads(r.stdout).get("version")
        except ValueError:
            ver = None
    return {"version": ver or "0.0.0", "history": [], "migrations": [], "post_actions": [], "breaking": False,
            "summary": ""}


def extract_tree(src, sha, dest):
    """git archive 결과를 dest 에 푼다(tar 명령 없이 tarfile)."""
    r = git(["-C", src, "archive", "--format=tar", sha], binary=True)
    if r.returncode != 0:
        raise RuntimeError("git archive 실패")
    os.makedirs(dest, exist_ok=True)
    with tarfile.open(fileobj=io.BytesIO(r.stdout)) as tf:
        try:
            tf.extractall(dest, filter="tar")
        except TypeError:  # filter 미지원 파이썬
            tf.extractall(dest)


def pre_verify(tree):
    """사전 검증. 반환: 오류 목록."""
    errs = []
    if os.path.exists(os.path.join(tree, "RELEASE.json")):
        errs += ["RELEASE: " + e for e in lint_release(os.path.join(tree, "RELEASE.json"), tree)]
        for f in REQUIRED_TREE_FILES:
            if not os.path.exists(os.path.join(tree, f)):
                errs.append("필수 파일 없음: " + f)
    vers = [tree_version(tree), _load_json(os.path.join(tree, PLUGIN_JSON)).get("version")]
    mv = [p.get("version") for p in _load_json(os.path.join(tree, MARKET_JSON)).get("plugins", [])
          if p.get("name") == "harness"]
    if mv:
        vers.append(mv[0])
    if not vers[1]:
        errs.append("plugin.json 없음")
    elif len(set(vers)) != 1:
        errs.append("version 불일치 %s" % "/".join(str(v) for v in vers))
    hooks_dir = os.path.join(tree, PLUG, "hooks")
    hj = os.path.join(hooks_dir, "hooks.json")
    if os.path.exists(hj):
        try:
            with open(hj, encoding="utf-8") as f:
                json.load(f)
        except ValueError:
            errs.append("hooks.json JSON 오류")
    if os.path.isdir(hooks_dir):
        for fn in sorted(os.listdir(hooks_dir)):
            if fn.endswith(".sh"):
                r = subprocess.run(["bash", "-n", os.path.join(hooks_dir, fn)], capture_output=True, timeout=30)
                if r.returncode != 0:
                    errs.append("bash -n 실패: hooks/" + fn)
    sdir = os.path.join(tree, PLUG, "scripts")
    for d in (sdir, os.path.join(sdir, "migrations")):
        if not os.path.isdir(d):
            continue
        for fn in sorted(os.listdir(d)):
            if fn.endswith(".py"):
                try:
                    with open(os.path.join(d, fn), encoding="utf-8") as f:
                        ast.parse(f.read(), fn)
                except (SyntaxError, ValueError, UnicodeDecodeError):
                    errs.append("파이썬 문법 오류: " + os.path.relpath(os.path.join(d, fn), tree))
    return errs


# ───────────────────────── 연쇄 범위·플러그인·링크 ─────────────────────────
def chain_range(meta, cur_ver):
    """현재 < v ≤ 대상 범위의 판 메타 목록(오래된 순)."""
    items = []
    for h in meta.get("history") or []:
        if cur_ver is None or vtuple(h.get("version")) > vtuple(cur_ver):
            items.append(h)
    # 같은 판 재적용(--force)·--ref 하향은 대상 판 자신을 범위에 넣지 않는다
    if cur_ver is None or vtuple(meta.get("version")) > vtuple(cur_ver):
        items.append({"version": meta.get("version"), "breaking": bool(meta.get("breaking")),
                      "summary": meta.get("summary", ""), "post_actions": meta.get("post_actions") or []})
    return items


def _installed_plugins():
    bases = ([_air.config_dir()] if _air else []) + [os.path.join(_home(), ".claude")]
    for base in bases:
        data = _load_json(os.path.join(base, "plugins", "installed_plugins.json"))
        plugins = data.get("plugins", data) if isinstance(data, dict) else {}
        if isinstance(plugins, dict) and plugins:
            return plugins
    return {}


def _plugin_version(plugins, pid):
    v = plugins.get(pid)
    if isinstance(v, list) and v:
        v = v[0]
    return v.get("version") if isinstance(v, dict) else None


def _claude_bin():
    c = shutil.which("claude")
    if c:
        return c
    c = os.path.join(_home(), ".local", "bin", "claude")
    return c if os.access(c, os.X_OK) else None


def plugin_update(skip):
    """반환 'n/a' | 'updated' | 'partial'."""
    plugins = _installed_plugins()
    if not any(k.startswith("harness@") for k in plugins):
        return "n/a"
    if skip:
        return "partial"
    claude = _claude_bin()
    if not claude:
        return "partial"
    for cmd in ([claude, "plugin", "marketplace", "update", MARKET_NAME], [claude, "plugin", "update", PLUGIN_ID]):
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=PLUGIN_TIMEOUT)
        except (OSError, subprocess.TimeoutExpired):
            return "partial"
        if r.returncode != 0:
            return "partial"
    return "updated"


def relink_local_bin(home, legacy_home, changes, out):
    """~/.local/bin 링크: 없으면 생성, 이 home·legacy home 안을 가리키면 재링크, 남의 것은 SKIP."""
    lb = os.path.join(_home(), ".local", "bin")
    for b in BIN_NAMES:
        target = os.path.join(home, "active", "bin", b)
        if not os.path.lexists(target):
            continue
        path = os.path.join(lb, b)
        if os.path.islink(path):
            old = os.readlink(path)
            if old == target:
                continue
            at = _abs_link_target(path)
            if _inside(at, home) or (legacy_home and _inside(at, legacy_home)):
                atomic_symlink(target, path)
                changes.append((path, old))
                out.append("링크 재연결: %s" % path)
            else:
                out.append("링크 SKIP(남의 링크): %s" % path)
        elif os.path.exists(path):
            out.append("링크 SKIP(실파일): %s" % path)
        else:
            os.makedirs(lb, exist_ok=True)
            os.symlink(target, path)
            changes.append((path, None))
            out.append("링크 생성: %s" % path)


def revert_links(changes):
    for path, old in reversed(changes):
        try:
            if old is None:
                if os.path.islink(path):
                    os.unlink(path)
            else:
                atomic_symlink(old, path)
        except OSError:
            pass


def snapshot_links(legacy_home):
    """~/.local/bin 6종과 legacy HARNESS_HOME/bin/* 의 링크 값을 기록한다."""
    links = {}
    lb = os.path.join(_home(), ".local", "bin")
    for n in BIN_NAMES:
        p = os.path.join(lb, n)
        if os.path.islink(p):
            links[p] = os.readlink(p)
    bd = os.path.join(legacy_home, "bin") if legacy_home else None
    if bd and os.path.isdir(bd):
        for n in sorted(os.listdir(bd)):
            p = os.path.join(bd, n)
            if os.path.islink(p):
                links[p] = os.readlink(p)
    return links


def ff_src(src, sha, out, label):
    """src 작업 트리를 대상 sha 로 fast-forward(실패는 경고만)."""
    if not os.path.isdir(os.path.join(src, ".git")):
        return
    if git(["-C", src, "cat-file", "-e", sha + "^{commit}"]).returncode != 0:
        git(["-C", src, "fetch", "--quiet", "origin", "--tags"])
    head = git(["-C", src, "rev-parse", "HEAD"]).stdout.strip()
    if head == sha:
        return
    r = git(["-C", src, "merge", "--ff-only", "--quiet", sha])
    out.append("%s ff: %s" % (label, "OK" if r.returncode == 0 else "건너뜀(ff 불가)"))


def prune(home, st):
    """최신 3개 + current·previous 판만 남긴다."""
    rd = os.path.join(home, "releases")
    if not os.path.isdir(rd):
        return []
    keep = set()
    for k in ("current", "previous"):
        r = (st.get(k) or {}).get("release")
        if r:
            keep.add(r)
    names = [n for n in os.listdir(rd) if os.path.isdir(os.path.join(rd, n))]
    names.sort(key=lambda n: (vtuple(n.split("_")[0]), os.path.getmtime(os.path.join(rd, n))), reverse=True)
    keep.update(names[:KEEP_RELEASES])
    removed = []
    for n in names:
        if n not in keep:
            shutil.rmtree(os.path.join(rd, n), ignore_errors=True)
            removed.append(n)
    return removed


MIGRATION_TIMEOUT = 600  # clone 이 들어가는 마이그레이션(m0001)을 고려한 상한
_SKIP_RE = re.compile(r"^\S+ SKIP\b")


def _mig_timeout():
    """마이그레이션 시간 상한(시험 모드에서만 HARNESS_UPDATE_TEST_MIG_TIMEOUT 로 줄일 수 있다)."""
    v = os.environ.get("HARNESS_UPDATE_TEST_MIG_TIMEOUT") if os.environ.get("HARNESS_UPDATE_TEST") == "1" else None
    return int(v) if v and v.isdigit() else MIGRATION_TIMEOUT


def _last_line(text):
    """stderr 마지막 비지 않은 줄(200자, URL 토큰 제거). 값·diff 본문을 내지 않도록 1줄만 쓴다."""
    lines = [l.strip() for l in (text or "").splitlines() if l.strip()]
    return _redact(lines[-1])[:200] if lines else ""


def run_migrations(meta, phase, done, tree, mig_home, ai_root):
    """미실행 마이그레이션 실행. 반환 (성공여부, 실행 id, 건너뜀 id).

    스크립트가 '<이름> SKIP …' 줄을 내면 대상 아님으로 보고 기록만 한다(요약의 실행 목록에서 뺀다).
    실패·시간 초과면 --undo 를 시도하고 실패를 돌려준다(엔진이 rc=1 로 원복).
    """
    ran, skipped = [], []
    for m in meta.get("migrations") or []:
        if m.get("phase") != phase or m.get("id") in done:
            continue
        script = os.path.join(tree, m.get("script", ""))
        if not os.path.isfile(script):
            _p("  마이그레이션 스크립트 없음: %s" % m.get("id"))
            return False, ran, skipped
        cmd = [sys.executable, "-B", script, "--harness-home", mig_home, "--ai-root", ai_root]
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=_mig_timeout())
            rc, out, err = r.returncode, r.stdout or "", r.stderr or ""
        except subprocess.TimeoutExpired:
            rc, out, err = -1, "", "시간 초과(%d초)" % _mig_timeout()
        for line in out.splitlines():
            _p("  " + line)
        if rc != 0:
            reason = _last_line(err)
            _p("  마이그레이션 실패: %s rc=%d%s" % (m.get("id"), rc, (" 사유: " + reason) if reason else ""))
            try:
                u = subprocess.run(cmd + ["--undo"], capture_output=True, text=True, timeout=MIGRATION_TIMEOUT)
                for line in (u.stdout or "").splitlines():
                    _p("  " + line)
            except subprocess.TimeoutExpired:
                _p("  마이그레이션 undo 시간 초과: %s" % m.get("id"))
            return False, ran, skipped
        if any(_SKIP_RE.match(l) for l in out.splitlines()):
            skipped.append(m.get("id"))
        else:
            ran.append(m.get("id"))
    return True, ran, skipped


def run_requires(tree, args):
    """대상 트리 install-online.sh --deps-only 위임. 반환 (rc, 출력)."""
    sh = os.path.join(tree, "install-online.sh")
    req = os.path.join(tree, "requires.txt")
    if not os.path.isfile(sh) or not os.path.isfile(req):
        return 0, "install-online.sh·requires.txt 없음 — 건너뜀"
    inter = _is_interactive(args)
    cmd = ["sh", sh, "--deps-only", "--requires", req]
    if not inter:
        cmd.append("--non-interactive")
    if args.yes:
        cmd.append("--yes")
    if args.no_sudo:
        cmd.append("--no-sudo")
    try:
        r = subprocess.run(cmd, stdin=None if inter else subprocess.DEVNULL,
                           capture_output=not inter, text=True, timeout=600)
    except subprocess.TimeoutExpired:
        return 3, "install-online --deps-only 시간 초과"
    return r.returncode, ((r.stdout or "") + (r.stderr or "")).strip()


def legacy_lock_path(home, ai_root):
    """레거시 home 은 무변경 원칙이라 lock 을 그 밖에 둔다. 일반 home 이면 None(기본 위치).

    새 home(<AI>/.harness)이 이미 있으면 그 안, 없으면 ${XDG_RUNTIME_DIR:-$HOME/.cache}/claude-harness/update.lock.
    """
    if not is_legacy_layout(home):
        return None
    if not ai_root and _air:
        pr = _air.projects_root()
        ai_root = os.path.join(pr, "AI") if pr else None
    if ai_root:
        nh = os.path.join(ai_root, ".harness")
        if os.path.realpath(nh) != os.path.realpath(home) and os.path.isdir(nh):
            return os.path.join(nh, ".update.lock")
    base = os.environ.get("XDG_RUNTIME_DIR") or os.path.join(_home(), ".cache")
    return os.path.join(base, "claude-harness", "update.lock")


_TMP_DIRS = []  # 이번 실행이 만든 mkdtemp 폴더(종료 시 반드시 정리)


def ensure_facade(home, ai_root, plugin_is_active=None):
    """AI facade·current 링크를 멱등 갱신하고 바뀐 항목 설명을 돌려준다."""
    notes = []
    if not os.path.islink(os.path.join(home, "active")):
        return notes
    if ai_root and _air:
        if plugin_is_active is None:
            plugin_is_active = _air.plugin_active()
        _frc, flines = _air.ensure(home, ai_root, plugin_is_active)
        notes.extend(l for l in flines if not l.startswith("FACADE KEEP"))
    cur_link = os.path.join(home, "current")
    if not os.path.lexists(cur_link):
        os.symlink(os.path.join(home, "active", PLUG), cur_link)
        notes.append("current 생성: %s" % cur_link)
    return notes


def deps_summary(text):
    """install-online --deps-only 출력의 'DEP <이름> <단계> …' 줄을 '이름=단계' 로 요약한다."""
    items = []
    for line in (text or "").splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[0] == "DEP":
            items.append("%s=%s" % (parts[1], parts[2]))
    if items:
        return " ".join(items)
    lines = [l.strip() for l in (text or "").splitlines() if l.strip()]
    return lines[-1] if lines else "OK"


def _cleanup(path):
    if path and os.path.isdir(path):
        shutil.rmtree(path, ignore_errors=True)


# ───────────────────────── apply ─────────────────────────
def cmd_apply(a):
    ai_arg = os.path.abspath(a.ai_root) if a.ai_root else None
    home = resolve_home(a.harness_home, ai_arg)
    ai_root = resolve_ai_root(a.ai_root, home)
    if ai_root and _air and _air.is_canon(ai_root):
        _p("OUPDATE REFUSE — 이 머신은 정본(배포자)이다. 배포는 /oUpload 를 쓴다 (ai_root=%s)" % ai_root)
        return RC_REFUSE
    src = os.path.join(home, "src")
    if git(["-C", src, "rev-parse", "--git-dir"]).returncode != 0:
        _p("OUPDATE FAIL 전제: %s 에 git clone 이 없다" % src)
        return RC_PRE
    act = os.path.join(home, "active")
    if os.path.exists(act) and not os.path.islink(act):
        _p("OUPDATE REFUSE — %s 가 링크가 아닌 실경로다" % act)
        return RC_REFUSE
    lock = Lock(home, legacy_lock_path(home, ai_root))
    if not lock.acquire():
        _p("OUPDATE LOCKED — 다른 oUpdate 가 실행 중이다 (%s)" % lock.path)
        return RC_LOCKED
    try:
        return _apply_locked(a, home, ai_root, src)
    finally:
        while _TMP_DIRS:
            _cleanup(_TMP_DIRS.pop())
        lock.release()


def _apply_locked(a, home, ai_root, src):
    st = load_state(home)
    legacy = is_legacy_layout(home)
    if legacy and not ai_root and _air:
        pr = _air.projects_root()
        ai_root = os.path.join(pr, "AI") if pr else None
    if legacy and not ai_root:
        _p("OUPDATE FAIL 전제: 레거시 이전 대상 AI 루트를 정할 수 없다(--ai-root 필요)")
        return RC_PRE
    # pending 복구: 중단된 적용 흔적이 있으면 active 를 current 판으로 되돌린다
    if st.get("pending"):
        cur_rel = (st.get("current") or {}).get("release")
        if cur_rel and os.path.isdir(os.path.join(home, "releases", cur_rel)):
            atomic_symlink(os.path.join("releases", cur_rel), os.path.join(home, "active"))
        _p("PENDING 복구: 중단된 적용(%s)을 정리했다" % (st["pending"].get("to") or "?"))
        st["pending"] = None
        save_state(home, st)
    # 1. fetch·대상 결정
    r = git(["-C", src, "fetch", "--quiet", "origin", "--tags"])
    if r.returncode != 0:
        _p("OUPDATE FAIL 전제: git fetch 실패 (%s)" % _redact(r.stderr.strip()[:200]))
        return RC_PRE
    sha, label = latest_target(src, a.ref)
    if not sha:
        _p("OUPDATE FAIL 전제: 대상(%s)을 찾지 못했다" % (a.ref or "최신"))
        return RC_PRE
    meta = meta_at(src, sha)
    tver = meta.get("version")
    cur = st.get("current")
    legacy_prev = None
    if cur:
        cur_ver, cur_sha = cur.get("version"), cur.get("sha")
    elif legacy:
        cur_ver = _load_json(os.path.join(src, PLUGIN_JSON)).get("version")
        cur_sha = git(["-C", src, "rev-parse", "HEAD"]).stdout.strip()
        legacy_prev = {"version": cur_ver, "sha": cur_sha, "legacy": True, "legacy_home": home,
                       "legacy_src": src, "links": snapshot_links(home)}
    else:
        cur_ver = cur_sha = None
    if cur_ver and not a.force:
        # 레거시는 같은 sha 여도 이전이 남아 있으므로 UP_TO_DATE 로 끝내지 않는다
        if not legacy and (cur_sha == sha or vtuple(tver) == vtuple(cur_ver)):
            for n in ensure_facade(home, ai_root):  # 멱등 — 플러그인·rules 가 뒤에 생긴 경우를 반영
                _p("  · " + n)
            _p("OUPDATE UP_TO_DATE %s (%s)" % (cur_ver, (cur_sha or sha)[:12]))
            return RC_OK
        if vtuple(tver) < vtuple(cur_ver) and not a.ref:
            _p("OUPDATE REFUSE_DOWNGRADE 대상 %s < 현재 %s — 되돌리려면 --ref 를 지정한다" % (tver, cur_ver))
            return RC_PRE
    # 2. 임시 위치 추출(어느 home 과도 무관) — 예외로 끝나도 cmd_apply 의 finally 가 지운다
    tmp = tempfile.mkdtemp(prefix="oupdate.")
    _TMP_DIRS.append(tmp)
    tree = os.path.join(tmp, "tree")
    try:
        extract_tree(src, sha, tree)
    except (RuntimeError, OSError, tarfile.TarError) as e:
        _cleanup(tmp)
        _p("OUPDATE FAIL 전제: 추출 실패 (%s)" % e.__class__.__name__)
        return RC_PRE
    _trace("extract")
    # 3. 사전 검증
    errs = pre_verify(tree)
    _trace("preverify")
    if errs:
        _cleanup(tmp)
        _p("OUPDATE FAIL 사전 검증 — 현행 유지")
        for e in errs[:20]:
            _p("  - " + e)
        return RC_FAIL
    rng = chain_range(meta, cur_ver)
    if a.dry_run:
        _cleanup(tmp)
        _p("OUPDATE DRY-RUN %s → %s (%s) 사전검증=PASS 범위=%s" % (cur_ver or "-", tver, sha[:12],
                                                                ",".join(str(i["version"]) for i in rng)))
        return RC_OK
    # 4. requires
    rq_rc, rq_out = run_requires(tree, a)
    _trace("requires")
    if rq_rc not in (0, 3, 4):  # install-online --deps-only: 3 누락·4 python 미달 외는 인자·실행 오류
        _cleanup(tmp)
        _p("OUPDATE FAIL 전제: install-online.sh --deps-only rc=%d (현행 유지)" % rq_rc)
        for line in rq_out.splitlines()[-10:]:
            _p("  " + line)
        return RC_PRE
    if rq_rc != 0:
        _cleanup(tmp)
        _p("OUPDATE NEEDS — 필수 도구가 모자라 적용하지 않았다(현행 유지)")
        for line in rq_out.splitlines()[-30:]:
            _p("  " + line)
        _p("  설치한 뒤 /oUpdate 를 다시 실행한다(사용자 공간 설치만 자동: --yes --no-sudo)")
        return RC_NEEDS
    # 5. breaking — 새 설치(현재 판 없음)는 깨질 것이 없으므로 묻지 않는다
    brk = [i for i in rng if i.get("breaking")] if cur_ver else []
    _trace("breaking")
    if brk:
        for i in brk:
            _p("⚠️ 큰 변경: %s %s" % (i.get("version"), i.get("summary", "")))
        if not a.accept_breaking:
            ok = False
            if _is_interactive(a):
                try:
                    ok = input("큰 변경을 적용할까요? [y/N] ").strip().lower() in ("y", "yes")
                except EOFError:
                    ok = False
            if not ok:
                _cleanup(tmp)
                _p("OUPDATE BREAKING — 확인이 필요하다. 내용을 읽고 --accept-breaking 으로 다시 실행한다(현행 유지)")
                return RC_BREAKING
    # 6. migrations(pre) — 대상 트리(임시 위치)의 스크립트로 실행
    done = list(st.get("migrations_done") or [])
    mig_ai = ai_root or os.path.dirname(home)
    ok, ran_pre, skip_pre = run_migrations(meta, "pre", done, tree, home, mig_ai)
    _trace("migrate_pre")
    if not ok:
        _cleanup(tmp)
        _p("OUPDATE FAIL 마이그레이션(pre) — 원복했다(현행 유지)")
        return RC_FAIL
    # 대상 home 결정: 레거시 이전이 일어났으면 새 home
    target_home = home
    if legacy and ai_root:
        nh = os.path.join(ai_root, ".harness")
        if os.path.realpath(nh) != os.path.realpath(home) and os.path.isdir(os.path.join(nh, "src", ".git")):
            target_home = nh
    if target_home != home:
        nst = load_state(target_home)
        for k in ("legacy_src", "legacy_home", "m0001"):
            if k in nst:
                st[k] = nst[k]
        st["legacy_src"] = st.get("legacy_src") or src
        st["legacy_home"] = st.get("legacy_home") or home
    if legacy_prev is not None:
        legacy_prev["rc_backup"] = (st.get("m0001") or {}).get("rc_backups") or {}
    legacy_home = st.get("legacy_home")
    rel_name = "%s_%s" % (tver, sha[:12])
    rel_dir = os.path.join(target_home, "releases", rel_name)
    os.makedirs(os.path.dirname(rel_dir), exist_ok=True)
    rel_created = not os.path.isdir(rel_dir)
    if rel_created:
        try:
            os.rename(tree, rel_dir)
        except OSError:
            shutil.copytree(tree, rel_dir, symlinks=True)
    _cleanup(tmp)
    _trace("release")
    # 7. pending → active 원자 교체 → 링크·src·플러그인·venv·facade·current
    act = os.path.join(target_home, "active")
    prev_active = os.readlink(act) if os.path.islink(act) else None
    st["pending"] = {"to": tver, "sha": sha, "release": rel_name, "at": _now()}
    save_state(target_home, st)
    atomic_symlink(os.path.join("releases", rel_name), act)
    _trace("active")
    changes, notes = [], []

    def restore(reason):
        if prev_active:
            atomic_symlink(prev_active, act)
        elif os.path.islink(act):
            os.unlink(act)
        revert_links(changes)
        if rel_created:  # 이번 실행에서 만든 판 폴더는 남기지 않는다
            _cleanup(rel_dir)
        st["pending"] = None
        save_state(target_home, st)
        _p("OUPDATE FAIL %s — active·링크를 원복했다" % reason)
        return RC_FAIL

    relink_local_bin(target_home, legacy_home, changes, notes)
    ff_src(os.path.join(target_home, "src"), sha, notes, "src")
    lsrc = st.get("legacy_src")
    if lsrc and os.path.realpath(lsrc) != os.path.realpath(os.path.join(target_home, "src")):
        ff_src(lsrc, sha, notes, "legacy_src")
    plugin = plugin_update(a.skip_plugin_update)
    hv = os.path.join(_home(), ".harness")
    if os.path.realpath(target_home) != os.path.realpath(hv) and os.path.isdir(os.path.join(target_home, "venv", "oio")):
        compat = os.path.join(hv, "venv", "oio")
        if not os.path.lexists(compat):
            os.makedirs(os.path.dirname(compat), exist_ok=True)
            os.symlink(os.path.join(target_home, "venv", "oio"), compat)
            notes.append("venv 호환 링크: %s" % compat)
    notes.extend(ensure_facade(target_home, ai_root, plugin != "n/a" or (_air.plugin_active() if _air else False)))
    # 8. migrations(post) — 새 판 트리의 스크립트로 실행
    ok, ran_post, skip_post = run_migrations(meta, "post", done + ran_pre + skip_pre, rel_dir, target_home, mig_ai)
    _trace("migrate_post")
    if not ok:
        return restore("마이그레이션(post)")
    # 9. 사후 검증
    verr = []
    if os.readlink(act) != os.path.join("releases", rel_name):
        verr.append("active 링크 불일치")
    if tree_version(act) != tver:
        verr.append("active version 불일치")
    eng = os.path.join(act, PLUG, "scripts", "harness_update.py")
    if os.path.isfile(eng):
        r = subprocess.run([sys.executable, "-B", eng, "selftest"], capture_output=True, text=True, timeout=60)
        if r.returncode != 0:
            verr.append("selftest 실패")
    if _fault("postverify"):
        verr.append("시험 고장 주입(postverify)")
    _trace("postverify")
    if verr:
        return restore("사후 검증(%s)" % ", ".join(verr))
    if plugin == "updated" and _plugin_version(_installed_plugins(), PLUGIN_ID) not in (None, tver):
        plugin = "partial"
    # 10. post_actions(안내만)·state 확정·prune
    actions, seen = [], set()
    for item in rng:
        for pa in item.get("post_actions") or []:
            key = (pa.get("kind"), pa.get("text"))
            if key not in seen:
                seen.add(key)
                actions.append(pa)
    if CODEX_PLUGIN_ID not in _installed_plugins():
        actions.append({"kind": "note", "text": "codex 플러그인 연결: " + CODEX_CONNECT_CMD})
    if plugin == "updated":  # 공식 문서: 실행 중 세션은 적재한 판을 유지, /reload-plugins 또는 다음 기동에 새 판
        actions.append({"kind": "reload_plugin", "text": "실행 중 세션은 /reload-plugins 로 새 hook·스킬을 적재한다(새 세션은 자동)"})
    if plugin == "partial":
        actions.append({"kind": "reload_plugin", "text": "플러그인 갱신 재시도: claude plugin marketplace update %s && claude plugin update %s"
                        % (MARKET_NAME, PLUGIN_ID)})
    _trace("post_actions")
    if legacy_prev is not None:
        st["previous"] = legacy_prev
    elif not (cur and cur.get("release") == rel_name):  # 같은 판 재적용(--force)은 previous 를 유지한다
        st["previous"] = cur
    st["current"] = {"version": tver, "sha": sha, "release": rel_name, "at": _now()}
    st["pending"] = None
    st["plugin"] = plugin
    st["migrations_done"] = done + [i for i in ran_pre + skip_pre + ran_post + skip_post if i not in done]
    result = "PARTIAL" if plugin == "partial" else "OK"
    st["history"].append({"from": cur_ver, "to": tver, "at": _now(), "breaking": bool(brk),
                          "post_actions": actions, "result": result})
    save_state(target_home, st)
    removed = prune(target_home, st)
    # 요약(서버 E2E 증거)
    for i in brk:
        _p("⚠️ 큰 변경: %s %s" % (i.get("version"), i.get("summary", "")))
    _p("OUPDATE %s %s → %s (%s) verify=PASS plugin=%s ai_root=%s"
       % (result, cur_ver or "-", tver, sha[:12], plugin, ai_root or "-"))
    for i in rng:
        if i.get("summary"):
            _p("변경: %s %s" % (i.get("version"), i.get("summary")))
    _p("요구 도구: %s" % deps_summary(rq_out))
    _p("마이그레이션: %s" % (" ".join(ran_pre + ran_post) or "없음"))
    for pa in actions:
        _p("해야 할 일: [%s] %s" % (pa.get("kind"), pa.get("text")))
    for n in notes:
        _p("  · " + n)
    if removed:
        _p("  · 정리한 판: %s" % " ".join(removed))
    return RC_PARTIAL if plugin == "partial" else RC_OK


# ───────────────────────── status·verify·rollback·selftest ─────────────────────────
def cmd_status(a):
    home = resolve_home(a.harness_home, a.ai_root)
    ai_root = resolve_ai_root(a.ai_root, home)
    if ai_root and _air and _air.is_canon(ai_root):
        _p("STATUS MODE=canon ai_root=%s — 정본(배포자) 머신이다. 배포는 /oUpload 를 쓴다" % ai_root)
        return RC_OK
    st = load_state(home)
    src = os.path.join(home, "src")
    _p("STATUS home=%s ai_root=%s" % (home, ai_root or "-"))
    cur = st.get("current")
    if cur:
        _p("현재: %s (%s) release=%s" % (cur.get("version"), (cur.get("sha") or "")[:12], cur.get("release")))
    elif is_legacy_layout(home):
        _p("현재: 레거시 %s" % _load_json(os.path.join(src, PLUGIN_JSON)).get("version"))
    else:
        _p("현재: 미설치")
    if st.get("previous"):
        pv = st["previous"]
        _p("이전: %s (%s)%s" % (pv.get("version"), (pv.get("sha") or "")[:12], " legacy" if pv.get("legacy") else ""))
    if st.get("pending"):
        _p("중단된 적용: %s" % st["pending"].get("to"))
    _p("플러그인: %s" % (st.get("plugin") or "-"))
    if git(["-C", src, "rev-parse", "--git-dir"]).returncode != 0:
        _p("판정: NO_SRC")
        return RC_PRE
    if not a.no_fetch:
        git(["-C", src, "fetch", "--quiet", "origin", "--tags"])
    sha, label = latest_target(src, None)
    if not sha:
        _p("판정: NO_TARGET")
        return RC_PRE
    meta = meta_at(src, sha)
    _p("대상: %s (%s) %s" % (meta.get("version"), sha[:12], label))
    if cur and cur.get("sha") == sha:
        _p("판정: UP_TO_DATE")
    else:
        rng = chain_range(meta, (cur or {}).get("version"))
        big = cur and any(i.get("breaking") for i in rng)
        _p("판정: UPDATE_AVAILABLE%s" % (" (큰 변경 포함 — --accept-breaking 필요)" if big else ""))
    return RC_OK


def cmd_verify(a):
    home = resolve_home(a.harness_home, a.ai_root)
    st = load_state(home)
    errs = []
    act = os.path.join(home, "active")
    cur = st.get("current") or {}
    if not os.path.islink(act):
        errs.append("active 링크 없음")
    else:
        if cur.get("release") and os.readlink(act) != os.path.join("releases", cur["release"]):
            errs.append("active 가 current 판을 가리키지 않음")
        if not os.path.isdir(act):
            errs.append("active 대상 없음")
        elif tree_version(act) != cur.get("version"):
            errs.append("active version 불일치")
        for f in (PLUGIN_JSON, PLUG + "/scripts/harness_update.py"):
            if not os.path.exists(os.path.join(act, f)):
                errs.append("파일 없음: " + f)
    lb = os.path.join(_home(), ".local", "bin")
    for b in BIN_NAMES:
        p = os.path.join(lb, b)
        if os.path.islink(p) and _inside(_abs_link_target(p), home) and not os.path.exists(p):
            errs.append("깨진 링크: " + p)
    if st.get("pending"):
        errs.append("중단된 적용 흔적(pending)")
    if errs:
        _p("VERIFY FAIL")
        for e in errs:
            _p("  - " + e)
        return RC_FAIL
    _p("VERIFY PASS %s (%s)" % (cur.get("version"), (cur.get("sha") or "")[:12]))
    return RC_OK


def cmd_rollback(a):
    home = resolve_home(a.harness_home, a.ai_root)
    ai_root = resolve_ai_root(a.ai_root, home)
    if ai_root and _air and _air.is_canon(ai_root):
        _p("OUPDATE REFUSE — 이 머신은 정본(배포자)이다")
        return RC_REFUSE
    lock = Lock(home, legacy_lock_path(home, ai_root))
    if not lock.acquire():
        _p("OUPDATE LOCKED")
        return RC_LOCKED
    try:
        st = load_state(home)
        prev, cur = st.get("previous"), st.get("current")
        if not prev:
            _p("ROLLBACK FAIL 전제: 되돌릴 이전 판이 없다")
            return RC_PRE
        if prev.get("legacy"):
            lsrc = prev.get("legacy_src") or st.get("legacy_src")
            r = git(["-C", lsrc, "reset", "--keep", "--quiet", prev["sha"]])
            if r.returncode != 0:
                _p("ROLLBACK FAIL 레거시 src reset --keep 실패")
                return RC_FAIL
            for p, v in sorted((prev.get("links") or {}).items()):
                if os.path.islink(p) or not os.path.exists(p):
                    atomic_symlink(v, p)
            backups = prev.get("rc_backup") or (st.get("m0001") or {}).get("rc_backups") or {}
            for p, bak in sorted(backups.items()):
                if os.path.isfile(bak):
                    shutil.copy2(bak, p)
            st["previous"], st["current"] = cur, prev
            st["history"].append({"from": (cur or {}).get("version"), "to": prev.get("version"), "at": _now(),
                                  "breaking": False, "post_actions": [], "result": "ROLLBACK_LEGACY"})
            save_state(home, st)
            _p("OUPDATE ROLLBACK %s → %s (레거시 %s) 링크·rc 복원"
               % ((cur or {}).get("version"), prev.get("version"), prev["sha"][:12]))
            _p("해야 할 일: [new_shell] 새 셸을 연다(exec $SHELL -l)")
            return RC_OK
        rel = prev.get("release")
        if not rel or not os.path.isdir(os.path.join(home, "releases", rel)):
            _p("ROLLBACK FAIL 이전 판 폴더가 없다(%s)" % rel)
            return RC_PRE
        atomic_symlink(os.path.join("releases", rel), os.path.join(home, "active"))
        st["previous"], st["current"] = cur, prev
        st["history"].append({"from": (cur or {}).get("version"), "to": prev.get("version"), "at": _now(),
                              "breaking": False, "post_actions": [], "result": "ROLLBACK"})
        save_state(home, st)
        _p("OUPDATE ROLLBACK %s → %s (%s)" % ((cur or {}).get("version"), prev.get("version"), (prev.get("sha") or "")[:12]))
        return RC_OK
    finally:
        lock.release()


def cmd_selftest(_a):
    errs = []
    if vtuple("1.10.0") <= vtuple("1.9.9") or vtuple("v1.3.0") != (1, 3, 0):
        errs.append("vtuple")
    if parse_requires("git|2.0|required|apt=git\n# c\nx||optional")[1]["need"] != "optional":
        errs.append("parse_requires")
    rng = chain_range({"version": "1.0.2", "history": [{"version": "1.0.0"}, {"version": "1.0.1", "breaking": True}],
                       "breaking": False}, "1.0.0")
    if [i["version"] for i in rng] != ["1.0.1", "1.0.2"]:
        errs.append("chain_range")
    # 자격증명 스캔이 이메일로 오판하지 않도록 시험 URL 을 나눠 조립한다
    if _redact("https://" + "tok" + "@" + "github" + ".com/x") != "https://github" + ".com/x":
        errs.append("redact")
    if _air is None:
        errs.append("harness_ai_root import")
    for fn in ("harness_ai_root.py", "ocopy_link.py"):
        p = os.path.join(HERE, fn)
        if os.path.exists(p):
            try:
                with open(p, encoding="utf-8") as f:
                    ast.parse(f.read(), p)
            except SyntaxError:
                errs.append("문법: " + fn)
    if errs:
        _p("SELFTEST FAIL " + ",".join(errs))
        return RC_FAIL
    _p("SELFTEST PASS")
    return RC_OK


def main(argv=None):
    ap = argparse.ArgumentParser(description="oUpdate 엔진")
    ap.add_argument("--harness-home")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("status")
    p.add_argument("--no-fetch", action="store_true")
    p.add_argument("--ai-root")
    p = sub.add_parser("apply")
    p.add_argument("--ref")
    p.add_argument("--force", action="store_true")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--accept-breaking", action="store_true")
    p.add_argument("--non-interactive", action="store_true")
    p.add_argument("--yes", action="store_true")
    p.add_argument("--no-sudo", action="store_true")
    p.add_argument("--skip-plugin-update", action="store_true")
    p.add_argument("--ai-root")
    for name in ("rollback", "verify"):
        p = sub.add_parser(name)
        p.add_argument("--ai-root")
    sub.add_parser("selftest")
    p = sub.add_parser("write-release")
    p.add_argument("--repo", required=True)
    p.add_argument("--version", required=True)
    p.add_argument("--summary", required=True)
    p.add_argument("--source-commit", required=True)
    p.add_argument("--breaking", action="store_true")
    p.add_argument("--post-action", action="append")
    p = sub.add_parser("lint-release")
    p.add_argument("file")
    p.add_argument("--repo")
    a = ap.parse_args(argv)
    if not hasattr(a, "ai_root"):
        a.ai_root = None
    fn = {"status": cmd_status, "apply": cmd_apply, "rollback": cmd_rollback, "verify": cmd_verify,
          "selftest": cmd_selftest, "write-release": cmd_write_release, "lint-release": cmd_lint_release}[a.cmd]
    return fn(a)


if __name__ == "__main__":
    sys.exit(main())
