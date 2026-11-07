# 하네스 임시 파일을 판정·승격·정리하는 단일 스크립트(dry-run 기본)
"""하네스 임시 파일 정리 + 영속 보관 승격.

범위(--scope)
  self      자기 세션(--uuid) — 재사용 산출물 승격(--promote) 후 임시 파일 정리
  sessions  죽은 세션(등록부 pid 생존 집합에 없음 + 트리 mtime --days 이상) 의 허용 목록 하위 항목
  repo      --project 저장소의 untracked 임시물(__pycache__, .claude/tmp_*, 선택: hooks/candidates)
  tmp       --tmp-dir 직속 하네스 산출물(pload_out*.txt, hook_tb.*) 7일 초과분
  all       sessions + repo + tmp (self 미포함)

--apply 가 없으면 dry-run 이다. dry-run 은 파일 시스템을 바꾸지 않는다(승격도 하지 않는다).
보고서(--report)·로그 파일(--log-file)만 쓴다.

판정 규칙은 모두 이 파일 안에 있다. 셸 명령은 repo 범위의 git status 하나뿐이다(shell=False).
타 세션 파일 내용은 읽지 않는다. 등록부(sessions/*.json)는 공용 레지스트리다.
"""

import argparse
import datetime
import fcntl
import fnmatch
import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time

# ─────────────────────────── 상수 ───────────────────────────
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")

# self 모드: 삭제를 허용하는 상태(첫 토큰). 그 밖의 상태·(ROOF|RALPH) 는 삭제 0건.  # ROOF-COMPAT(deprecation window 1주기 — 구 RALPH/oralph_active 인식 제거 예정)
SELF_DELETABLE_STATES = {"FINISH", "IDLE", ""}
SELF_EPHEMERAL_DIRS = ("ack", "teammate_turn", "scope_markers")
SELF_EPHEMERAL_SEC = 60 * 60
PREV_CYCLE_KEEP = 3
SELF_PLANS_DAYS = 7
SELF_GOAL_DAYS = 14

# sessions 모드 허용 목록(이 이름만 지운다 — 나머지는 무접촉)
SESS_DEL_DIRS = {"work", "ack", "teammate_turn", "scope_markers", "panes",
                 "compact", "agents", "agent_keep"}
SESS_DEL_DIR_RE = re.compile(r"^(c\d+_[A-Za-z0-9_]+|otest_c\d+[A-Za-z0-9_]*|evidence_c\d+_archive)$")
SESS_ROOT_FILE_GLOBS = ("goal_*_completed.json", "observation_checkpoint_count",
                        "sessionstart-hook-*.sh", "hook_debug.log")
SESS_EVIDENCE_KEEP = {"ok_started"}
SESS_LOG_KEEP_PREFIX = "askq_"

# repo 모드
REPO_HARD_EXCLUDE = (".claude/hooks/logs/", ".claude/hooks/backup/", ".claude/hooks/lib/", ".git/")
REPO_REPORT_ONLY = (".claude/hooks/backup/",)
REPO_TMP_DIR_RE = re.compile(r"^\.claude/tmp_[^/]+$")
REPO_CANDIDATE_RE = re.compile(r"^\.claude/hooks/candidates/([^/]+)$")
REPO_CANDIDATE_DAYS = 14

# tmp 모드
TMP_GLOBS = ("pload_out*.txt", "oload_out*.txt", "hook_tb.*")
TMP_EXCLUDE_PREFIX = ("cc-", "claude-", "tmux-")
TMP_DAYS = 7

# 승격
PROMOTE_MAX_BYTES = 512 * 1024
ARCHIVE_KINDS = ("plan", "dev", "test", "lesson", "request")

LOG_MAX_BYTES = 1024 * 1024
LOG_KEEP_BYTES = 200 * 1024
DAY = 86400


# ─────────────────────────── 공용 유틸 ───────────────────────────
class Budget:
    """time.monotonic 기반 시간 상한. 0 이하면 무제한."""

    def __init__(self, sec):
        self.sec = float(sec or 0)
        self.t0 = time.monotonic()
        self.hit = False

    def exceeded(self):
        if self.sec > 0 and (time.monotonic() - self.t0) >= self.sec:
            self.hit = True
        return self.hit


def iso(epoch):
    return datetime.datetime.fromtimestamp(epoch).astimezone().isoformat(timespec="seconds")


def inside(path, base):
    """realpath 기준으로 path 가 base 안(또는 같음)인지."""
    rp = os.path.realpath(path)
    rb = os.path.realpath(base)
    return rp == rb or rp.startswith(rb.rstrip(os.sep) + os.sep)


def parent_inside(path, base):
    """항목 자신은 symlink 일 수 있으므로 부모 디렉터리 realpath 로 base 안인지 본다."""
    return inside(os.path.dirname(os.path.abspath(path)), base)


def is_empty_lock(entry, st):
    """크기 0 인 정규 파일 *.lock 여부."""
    return entry.name.endswith(".lock") and st.st_size == 0 and entry.is_file(follow_symlinks=False)


def walk_max_mtime(path, cutoff):
    """트리(자신 포함) 최대 mtime. cutoff 보다 새것을 만나면 즉시 그 값을 돌려준다. symlink 미추적.
    하위의 0바이트 *.lock 파일은 산정에서 제외한다."""
    try:
        st = os.lstat(path)
    except OSError:
        return 0.0
    best = st.st_mtime
    if best > cutoff:
        return best
    if not os.path.isdir(path) or os.path.islink(path):
        return best
    stack = [path]
    while stack:
        cur = stack.pop()
        try:
            it = os.scandir(cur)
        except OSError:
            continue
        with it:
            for e in it:
                try:
                    est = e.stat(follow_symlinks=False)
                except OSError:
                    continue
                if is_empty_lock(e, est):
                    continue  # 0바이트 *.lock 은 활동 신호가 아니다(flock·일괄 touch 로 갱신됨)
                m = est.st_mtime
                if m > best:
                    best = m
                    if best > cutoff:
                        return best
                try:
                    if e.is_dir(follow_symlinks=False):
                        stack.append(e.path)
                except OSError:
                    pass
    return best


def tree_bytes(path):
    """트리 겉보기 용량 합(lstat st_size). symlink 미추적."""
    try:
        st = os.lstat(path)
    except OSError:
        return 0
    total = st.st_size
    if os.path.islink(path) or not os.path.isdir(path):
        return total
    stack = [path]
    while stack:
        cur = stack.pop()
        try:
            it = os.scandir(cur)
        except OSError:
            continue
        with it:
            for e in it:
                try:
                    total += e.stat(follow_symlinks=False).st_size
                    if e.is_dir(follow_symlinks=False):
                        stack.append(e.path)
                except OSError:
                    pass
    return total


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def lmtime(path):
    try:
        return os.lstat(path).st_mtime
    except OSError:
        return 0.0


def read_small(path, limit=4096):
    """자기 세션 파일 판독 전용(내용 일부)."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read(limit)
    except OSError:
        return None


def remove_path(path):
    """symlink·파일은 unlink, 실 디렉터리는 rmtree. 대상 symlink 는 따라가지 않는다."""
    if os.path.islink(path) or not os.path.isdir(path):
        os.unlink(path)
    else:
        shutil.rmtree(path)


def rmdir_if_empty(path):
    try:
        if os.path.isdir(path) and not os.path.islink(path) and not os.listdir(path):
            os.rmdir(path)
            return True
    except OSError:
        pass
    return False


# ─────────────────────────── 실행 컨텍스트 ───────────────────────────
class Ctx:
    def __init__(self, args):
        self.args = args
        self.apply = bool(args.apply)
        self.now = float(args.now) if args.now is not None else time.time()
        self.budget = Budget(args.budget)
        self.report = {
            "version": 1,
            "mode": "apply" if self.apply else "dry-run",
            "scopes": [],
            "started": iso(self.now),
            "elapsed_sec": 0.0,
            "candidates": [],
            "promoted": [],
            "skipped": [],
            "totals": {},
            "budget_exceeded": False,
            "auto_disabled": False,
            "errors": [],
        }

    def add(self, scope, path, kind, nbytes, mtime, reason, action):
        item = {"scope": scope, "path": path, "kind": kind, "bytes": int(nbytes),
                "mtime": iso(mtime) if mtime else "", "reason": reason, "action": action,
                "applied": False}
        self.report["candidates"].append(item)
        key = scope if action == "delete" else action
        t = self.report["totals"].setdefault(key, {"count": 0, "bytes": 0})
        t["count"] += 1
        t["bytes"] += int(nbytes)
        return item

    def tally(self, key, nbytes):
        t = self.report["totals"].setdefault(key, {"count": 0, "bytes": 0})
        t["count"] += 1
        t["bytes"] += int(nbytes)

    def skip(self, path, reason):
        self.report["skipped"].append({"path": path, "reason": reason})

    def err(self, msg):
        self.report["errors"].append(msg)

    def out_of_time(self):
        if self.budget.exceeded():
            self.report["budget_exceeded"] = True
            return True
        return False

    def delete(self, item, base):
        """dry-run 이면 아무것도 하지 않는다. apply 이면 base 안 확인 후 삭제."""
        if not self.apply:
            return False
        p = item["path"]
        if not parent_inside(p, base):
            self.err("outside_base: %s" % p)
            return False
        try:
            remove_path(p)
            item["applied"] = True
            return True
        except OSError as e:
            self.err("delete_failed: %s: %s" % (p, e))
            return False


# ─────────────────────────── 생존 판정 ───────────────────────────
def proc_starttime(pid):
    """/proc/<pid>/stat 의 22번째 필드(starttime). 실패 시 None."""
    try:
        with open("/proc/%d/stat" % pid, "r") as f:
            s = f.read()
        return s[s.rindex(")") + 2:].split()[19]
    except (OSError, ValueError, IndexError):
        return None


def pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except PermissionError:
        return True
    except (OSError, OverflowError, ValueError):
        return False


def live_session_ids(registry_dirs):
    """등록부의 pid 생존(+procStart 일치) 세션 id 집합. 읽은 디렉터리가 0개면 None(fail-closed)."""
    live = set()
    read_dirs = 0
    for d in registry_dirs:
        try:
            names = os.listdir(d)
        except OSError:
            continue
        read_dirs += 1
        for n in names:
            if not n.endswith(".json"):
                continue
            try:
                with open(os.path.join(d, n), "r", encoding="utf-8") as f:
                    data = json.load(f)
                pid = int(data.get("pid"))
                sid = str(data.get("sessionId") or "")
            except (OSError, ValueError, TypeError, AttributeError):
                continue
            if pid <= 0 or not sid or not pid_alive(pid):
                continue
            ps = data.get("procStart")
            if ps not in (None, ""):
                cur = proc_starttime(pid)
                if cur is not None and str(cur) != str(ps).strip():
                    continue  # pid 재사용
            live.add(sid)
    return live if read_dirs > 0 else None


def default_registry_dirs(args):
    dirs = [os.path.join(os.path.expanduser("~"), ".claude", "sessions")]
    cfg = os.environ.get("CLAUDE_CONFIG_DIR")
    if cfg:
        dirs.append(os.path.join(cfg, "sessions"))
    dirs.extend(glob.glob(os.path.join(args.profile_glob, "sessions")))
    seen, out = set(), []
    for d in dirs:
        k = os.path.abspath(d)
        if k not in seen:
            seen.add(k)
            out.append(d)
    return out


def profile_link_targets(args):
    """프로필 session-env 의 symlink 이름·대상 basename 집합."""
    roots = []
    cfg = os.environ.get("CLAUDE_CONFIG_DIR")
    if cfg:
        roots.append(os.path.join(cfg, "session-env"))
    roots.extend(glob.glob(os.path.join(args.profile_glob, "session-env")))
    names = set()
    for r in roots:
        try:
            it = os.scandir(r)
        except OSError:
            continue
        with it:
            for e in it:
                if e.is_symlink():
                    names.add(e.name)
                    try:
                        names.add(os.path.basename(os.readlink(e.path).rstrip("/")))
                    except OSError:
                        pass
    return names


# ─────────────────────────── 프로젝트·보관 영역 ───────────────────────────
def find_git_root(start):
    cur = os.path.abspath(start)
    while True:
        if os.path.exists(os.path.join(cur, ".git")):
            return cur
        nxt = os.path.dirname(cur)
        if nxt == cur:
            return None
        cur = nxt


def resolve_project(args):
    if args.project:
        return os.path.abspath(args.project)
    cwd = os.getcwd()
    return find_git_root(cwd) or cwd


def archive_root(project):
    """<project>/.claude/archive. .claude realpath 가 project 밖이면 None."""
    cdir = os.path.join(project, ".claude")
    if not inside(cdir, project):
        return None
    return os.path.join(os.path.realpath(cdir), "archive")


def load_index_shas(index_path):
    shas = set()
    try:
        with open(index_path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    s = json.loads(line).get("sha256")
                except (ValueError, AttributeError):
                    continue
                if s:
                    shas.add(s)
    except OSError:
        pass
    return shas


def append_index(index_path, rec):
    os.makedirs(os.path.dirname(index_path), exist_ok=True)
    with open(index_path, "a", encoding="utf-8") as f:
        fcntl.flock(f.fileno(), fcntl.LOCK_EX)
        try:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
            f.flush()
        finally:
            fcntl.flock(f.fileno(), fcntl.LOCK_UN)


# 재사용 후보에서 빼는 이름: 판 사본(_v1·_r2·_old·_bak·_copy·복사본)과 1회성 탐침(probe·탐침)
_판사본_패턴 = re.compile(r"(_v\d+|_r\d+|_old|_bak|_copy|복사본)$", re.IGNORECASE)
_탐침_패턴 = re.compile(r"(probe|탐침)", re.IGNORECASE)


def reusable_excluded(name):
    """재사용 후보 스크립트·규칙 이름이 판 사본·1회성 탐침이면 True."""
    stem = os.path.splitext(name)[0]
    return bool(_판사본_패턴.search(stem) or _탐침_패턴.search(stem))


def _script_kind(name):
    """재사용 후보 스크립트(.py·.sh)면 'test', 아니면 None."""
    if (name.endswith(".py") or name.endswith(".sh")) and not reusable_excluded(name):
        return "test"
    return None


def promote_kind(rel):
    """세션 디렉터리 기준 상대경로 → 보관 분류. 매핑에 없으면 None."""
    parts = rel.split("/")
    name = parts[-1]
    if len(parts) == 1:
        if name in ("file_assignment.json", "goal.json") or fnmatch.fnmatch(name, "goal_*_completed.json"):
            return "plan"
        return None
    if len(parts) == 3:
        # evidence/<하위>/*.py|*.sh — 재사용 후보 검증 스크립트(보관만, 커밋 아님)
        if parts[0] == "evidence":
            return _script_kind(name)
        return None
    if len(parts) != 2:
        return None
    top = parts[0]
    if top == "plans":
        if name == "user_prompt.md":
            return "request"
        if name.startswith("pass_proof_"):
            return "test"
        if name == "errors.md":
            return "lesson"
        if name.endswith(".md") or name.endswith(".json"):
            return "plan"
        return _script_kind(name)
    if top == "work":
        if fnmatch.fnmatch(name, "otest*_result.json"):
            return "test"
        if name.endswith("_result.json"):
            return "dev"
        # 결과 전 고정한 판정·측정 규칙(work/*rules*.md)
        if name.endswith(".md") and "rules" in name and not reusable_excluded(name):
            return "test"
        return None
    if top == "logs" and name in ("errors.md", "review_actions.json"):
        return "lesson"
    return None


def safe_token(s, default):
    s = re.sub(r"[^A-Za-z0-9_.-]", "_", (s or "").strip())[:60]
    return s or default


# ─────────────────────────── self 모드 ───────────────────────────
def run_self(ctx):
    a = ctx.args
    base = a.session_base
    sdir = os.path.join(base, a.uuid)
    if not os.path.isdir(sdir):
        ctx.skip(sdir, "self_dir_missing")
        return
    if not inside(sdir, base):
        ctx.err("self_dir_outside_base: %s" % sdir)
        return

    project = resolve_project(a)
    aroot = archive_root(project)
    index_path = os.path.join(aroot, "INDEX.jsonl") if aroot else None
    index_shas = load_index_shas(index_path) if index_path else set()
    planned_shas = set()

    # 1) 승격 후보
    promote_items = []
    rels = []
    scan_subs = ["", "plans", "work", "logs"]
    # evidence/<하위>/ 1단계 아래까지 스크립트 후보를 찾는다(symlink 하위는 따라가지 않음)
    try:
        with os.scandir(os.path.join(sdir, "evidence")) as ev:
            scan_subs += sorted("evidence/" + e.name for e in ev if e.is_dir(follow_symlinks=False))
    except OSError:
        pass
    for sub in scan_subs:
        d = os.path.join(sdir, sub) if sub else sdir
        try:
            it = os.scandir(d)
        except OSError:
            continue
        with it:
            for e in it:
                if not e.is_file(follow_symlinks=False):
                    continue
                rel = (sub + "/" + e.name) if sub else e.name
                k = promote_kind(rel)
                if k:
                    rels.append((rel, k))
    if a.promote:
        if aroot is None:
            ctx.skip(os.path.join(project, ".claude"), "claude_dir_outside_project")
        else:
            conv = safe_token(read_small(os.path.join(sdir, "conv_id"), 200), "noconv")
            tier_raw = read_small(os.path.join(sdir, "classification"), 200) or ""
            tier = safe_token(tier_raw.split()[0] if tier_raw.split() else "", "")
            for rel, kind in sorted(rels):
                if ctx.out_of_time():
                    break
                src = os.path.join(sdir, rel)
                try:
                    st = os.lstat(src)
                except OSError:
                    continue
                if st.st_size > PROMOTE_MAX_BYTES:
                    ctx.skip(src, "too_large")
                    continue
                try:
                    digest = sha256(src)
                except OSError as e:
                    ctx.err("sha_failed: %s: %s" % (src, e))
                    continue
                if digest in index_shas or digest in planned_shas:
                    continue
                t = datetime.datetime.fromtimestamp(st.st_mtime)
                fname = "%s_%s_%s" % (t.strftime("%Y%m%d-%H%M"), conv, os.path.basename(rel))
                relpath = "%s/%s/%s" % (kind, t.strftime("%Y-%m"), fname)
                dst = os.path.join(aroot, relpath)
                if os.path.lexists(dst):
                    root_, ext = os.path.splitext(fname)
                    fname = "%s_%s%s" % (root_, digest[:8], ext)
                    relpath = "%s/%s/%s" % (kind, t.strftime("%Y-%m"), fname)
                    dst = os.path.join(aroot, relpath)
                item = ctx.add("self", src, kind, st.st_size, st.st_mtime, "promote_map", "promote")
                planned_shas.add(digest)
                promote_items.append(item)
                if not ctx.apply:
                    continue
                try:
                    os.makedirs(os.path.dirname(dst), exist_ok=True)
                    shutil.copy2(src, dst)
                    if sha256(dst) != digest:
                        os.unlink(dst)
                        ctx.err("promote_sha_mismatch: %s" % src)
                        continue
                    rec = {"ts": iso(time.time()), "uuid8": a.uuid[:8], "conv_id": conv,
                           "tier": tier, "kind": kind, "src": rel, "path": relpath,
                           "sha256": digest, "bytes": st.st_size}
                    append_index(index_path, rec)
                    index_shas.add(digest)
                    item["applied"] = True
                    ctx.report["promoted"].append(rec)
                except OSError as e:
                    ctx.err("promote_failed: %s: %s" % (src, e))

    # dry-run 에서는 승격 예정분을 INDEX 등재로 간주해 삭제 예상치를 보인다.
    known_shas = index_shas | (planned_shas if not ctx.apply else set())

    # 2) 진행 중 보호
    state_raw = read_small(os.path.join(sdir, "state"), 200)
    state_tok = (state_raw.split()[0] if state_raw and state_raw.split() else "").upper()
    status_raw = (read_small(os.path.join(sdir, "status"), 200) or "").upper()
    # ROOF-COMPAT(deprecation window 1주기 — 구 RALPH/oralph_active 인식 제거 예정): (ROOF|RALPH) 병기
    _루프활성 = "ROOF" in status_raw or "RALPH" in status_raw
    if state_tok not in SELF_DELETABLE_STATES or _루프활성:
        ctx.skip(sdir, "in_progress_protect(state=%s%s)" % (state_tok or "-", ",ROOF" if _루프활성 else ""))
        return

    # 3) 삭제 후보
    items = []
    eph_cut = ctx.now - SELF_EPHEMERAL_SEC
    for sub in SELF_EPHEMERAL_DIRS:
        d = os.path.join(sdir, sub)
        try:
            entries = sorted(os.scandir(d), key=lambda e: e.name)
        except OSError:
            continue
        for e in entries:
            if walk_max_mtime(e.path, eph_cut) <= eph_cut:
                items.append((e.path, "ephemeral_" + sub, "older_than_60m"))

    pc = os.path.join(sdir, "logs", "prev_cycle")
    try:
        subs = sorted([e for e in os.scandir(pc) if e.is_dir(follow_symlinks=False)],
                      key=lambda e: e.name, reverse=True)
    except OSError:
        subs = []
    for e in subs[PREV_CYCLE_KEEP:]:
        items.append((e.path, "prev_cycle", "keep_latest_%d" % PREV_CYCLE_KEEP))

    plans_cut = ctx.now - SELF_PLANS_DAYS * DAY
    pd = os.path.join(sdir, "plans")
    try:
        pents = sorted(os.scandir(pd), key=lambda e: e.name)
    except OSError:
        pents = []
    for e in pents:
        if not e.is_file(follow_symlinks=False):
            continue
        if lmtime(e.path) > plans_cut:
            continue
        if promote_kind("plans/" + e.name) is None:
            items.append((e.path, "plans", "older_than_7d_unmapped"))
            continue
        try:
            if sha256(e.path) in known_shas:
                items.append((e.path, "plans", "older_than_7d_archived"))
        except OSError:
            pass

    goal_cut = ctx.now - SELF_GOAL_DAYS * DAY
    for p in sorted(glob.glob(os.path.join(glob.escape(sdir), "goal_*_completed.json"))):
        if os.path.islink(p) or not os.path.isfile(p) or lmtime(p) > goal_cut:
            continue
        try:
            if sha256(p) in known_shas:
                items.append((p, "goal_completed", "older_than_14d_archived"))
        except OSError:
            pass

    for path, kind, reason in items:
        if ctx.out_of_time():
            break
        item = ctx.add("self", path, kind, tree_bytes(path), lmtime(path), reason, "delete")
        ctx.delete(item, sdir)


# ─────────────────────────── sessions 모드 ───────────────────────────
def session_deletables(sdir, purge_plans):
    """죽은 세션 1개에서 허용 목록에 든 하위 항목 (path, kind) 목록. 내용은 읽지 않는다."""
    out = []
    try:
        top = sorted(os.scandir(sdir), key=lambda e: e.name)
    except OSError:
        return out, None
    plans_path = None
    for e in top:
        name = e.name
        is_link = e.is_symlink()
        is_dir = e.is_dir(follow_symlinks=False)
        is_file = e.is_file(follow_symlinks=False)
        if is_dir or is_link:
            if name in SESS_DEL_DIRS or SESS_DEL_DIR_RE.fullmatch(name):
                out.append((e.path, name if name in SESS_DEL_DIRS else "cycle_dir"))
                continue
            if name == "plans":
                if purge_plans:
                    out.append((e.path, "plans"))
                elif is_dir:
                    plans_path = e.path
                continue
        if is_dir and name == "evidence":
            try:
                for c in sorted(os.scandir(e.path), key=lambda x: x.name):
                    if c.name not in SESS_EVIDENCE_KEEP:
                        out.append((c.path, "evidence"))
            except OSError:
                pass
            continue
        if is_dir and name == "logs":
            try:
                for c in sorted(os.scandir(e.path), key=lambda x: x.name):
                    if c.name == "prev_cycle" and (c.is_dir(follow_symlinks=False) or c.is_symlink()):
                        out.append((c.path, "prev_cycle"))
                    elif c.is_file(follow_symlinks=False) and not c.name.startswith(SESS_LOG_KEEP_PREFIX):
                        out.append((c.path, "logs_file"))
            except OSError:
                pass
            continue
        if is_file and any(fnmatch.fnmatch(name, g) for g in SESS_ROOT_FILE_GLOBS):
            out.append((e.path, "root_file"))
    return out, plans_path


def run_sessions(ctx):
    a = ctx.args
    if a.auto and not os.path.isfile(a.marker):
        ctx.report["auto_disabled"] = True
        return
    reg_dirs = a.registry_dir if a.registry_dir else default_registry_dirs(a)
    live = live_session_ids(reg_dirs)
    if live is None:
        ctx.err("registry_unreadable: sessions scope aborted (fail-closed) dirs=%s" % reg_dirs)
        return
    links = profile_link_targets(a)
    base = a.session_base
    if not os.path.isdir(base):
        ctx.skip(base, "session_base_missing")
        return
    cutoff = ctx.now - a.days * DAY
    try:
        entries = sorted(os.scandir(base), key=lambda e: e.name)
    except OSError as e:
        ctx.err("session_base_unreadable: %s" % e)
        return
    processed = 0
    for e in entries:
        if ctx.out_of_time():
            break
        if a.max_dirs and processed >= a.max_dirs:
            break
        name = e.name
        if not UUID_RE.fullmatch(name):
            continue
        if e.is_symlink() or not e.is_dir(follow_symlinks=False):
            continue
        if name in live or name == a.uuid or name in links:
            continue
        if not inside(e.path, base):
            continue
        dels, plans_path = session_deletables(e.path, a.purge_plans)
        if not dels:
            continue
        if walk_max_mtime(e.path, cutoff) > cutoff:
            continue
        processed += 1
        if plans_path:
            ctx.tally("sessions_plans_kept", tree_bytes(plans_path))
        for path, kind in dels:
            if ctx.out_of_time():
                break
            item = ctx.add("sessions", path, kind, tree_bytes(path), lmtime(path),
                           "dead_session_%dd" % a.days, "delete")
            ctx.delete(item, e.path)
        if ctx.apply:
            for sub in ("evidence", "logs"):
                rmdir_if_empty(os.path.join(e.path, sub))
            rmdir_if_empty(e.path)


# ─────────────────────────── repo 모드 ───────────────────────────
def git_untracked(project):
    r = subprocess.run(["git", "-C", project, "status", "--porcelain=v1", "-z", "--untracked-files=normal"],
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60, shell=False)
    if r.returncode != 0:
        return None
    out = []
    for rec in r.stdout.decode("utf-8", "surrogateescape").split("\0"):
        if rec.startswith("?? "):
            out.append(rec[3:])
    return out


def hard_excluded(rel):
    r = rel if rel.endswith("/") else rel + "/"
    return any(r.startswith(p) for p in REPO_HARD_EXCLUDE)


def run_repo(ctx):
    a = ctx.args
    project = resolve_project(a)
    if not os.path.exists(os.path.join(project, ".git")):
        ctx.skip(project, "not_git")
        return
    try:
        untracked = git_untracked(project)
    except (OSError, subprocess.SubprocessError) as e:
        ctx.err("git_status_failed: %s" % e)
        return
    if untracked is None:
        ctx.skip(project, "not_git")
        return
    gp_text = None
    if a.include_candidates:
        try:
            with open(os.path.join(project, ".claude", "hooks", "lib", "guard_promote.json"),
                      "r", encoding="utf-8") as f:
                gp_text = f.read()
        except OSError:
            gp_text = ""  # 등록부 없음 = 핀 없음
    cand_cut = ctx.now - REPO_CANDIDATE_DAYS * DAY
    found = []  # (abs, kind, reason, action)

    for rel in sorted(untracked):
        if ctx.out_of_time():
            break
        relc = rel.rstrip("/")
        absp = os.path.join(project, relc)
        if any((relc + "/").startswith(p) for p in REPO_REPORT_ONLY):
            found.append((absp, "backup", "untracked_backup", "report_only"))
            continue
        if hard_excluded(relc):
            continue
        m = REPO_CANDIDATE_RE.fullmatch(relc)
        if m and rel.endswith("/"):
            if a.include_candidates:
                cid = m.group(1)
                if gp_text is not None and cid in gp_text:
                    ctx.skip(absp, "candidate_pinned")
                elif walk_max_mtime(absp, cand_cut) > cand_cut:
                    ctx.skip(absp, "candidate_young")
                else:
                    found.append((absp, "candidate", "untracked_candidate_14d", "delete"))
                    continue
            # 포함하지 않으면 아래에서 __pycache__ 만 찾는다
        if os.path.islink(absp) or not os.path.isdir(absp):
            continue
        if os.path.basename(relc) == "__pycache__":
            found.append((absp, "pycache", "untracked_pycache", "delete"))
            continue
        if REPO_TMP_DIR_RE.fullmatch(relc):
            found.append((absp, "tmp_dir", "untracked_claude_tmp", "delete"))
            continue
        # 통째로 untracked 인 디렉터리 안을 훑는다(내부도 전부 untracked)
        stack = [absp]
        while stack:
            if ctx.out_of_time():
                break
            cur = stack.pop()
            try:
                it = os.scandir(cur)
            except OSError:
                continue
            with it:
                for e in it:
                    if not e.is_dir(follow_symlinks=False):
                        continue
                    sub_rel = os.path.relpath(e.path, project)
                    if hard_excluded(sub_rel) or e.name == ".git":
                        continue
                    if e.name == "__pycache__":
                        found.append((e.path, "pycache", "untracked_pycache", "delete"))
                    elif REPO_TMP_DIR_RE.fullmatch(sub_rel):
                        found.append((e.path, "tmp_dir", "untracked_claude_tmp", "delete"))
                    else:
                        stack.append(e.path)

    for absp, kind, reason, action in found:
        if ctx.out_of_time():
            break
        if not parent_inside(absp, project):
            continue
        item = ctx.add("repo", absp, kind, tree_bytes(absp), lmtime(absp), reason, action)
        if action == "delete":
            ctx.delete(item, project)


# ─────────────────────────── tmp 모드 ───────────────────────────
def run_tmp(ctx):
    a = ctx.args
    d = a.tmp_dir
    cutoff = ctx.now - TMP_DAYS * DAY
    try:
        entries = sorted(os.scandir(d), key=lambda e: e.name)
    except OSError as e:
        ctx.skip(d, "tmp_unreadable")
        return
    for e in entries:
        if ctx.out_of_time():
            break
        if e.name.startswith(TMP_EXCLUDE_PREFIX):
            continue
        if not e.is_file(follow_symlinks=False):
            continue
        if not any(fnmatch.fnmatch(e.name, g) for g in TMP_GLOBS):
            continue
        st = e.stat(follow_symlinks=False)
        if st.st_mtime > cutoff:
            continue
        item = ctx.add("tmp", e.path, "tmp_file", st.st_size, st.st_mtime, "older_than_7d", "delete")
        ctx.delete(item, d)


# ─────────────────────────── 출력·로그 ───────────────────────────
def human(n):
    n = float(n)
    for u in ("B", "K", "M", "G"):
        if n < 1024 or u == "G":
            return ("%d%s" % (n, u)) if u == "B" else ("%.1f%s" % (n, u))
        n /= 1024.0


def print_summary(ctx):
    r = ctx.report
    print("[harness_cleanup] mode=%s scopes=%s elapsed=%.2fs budget_exceeded=%s auto_disabled=%s errors=%d"
          % (r["mode"], ",".join(r["scopes"]), r["elapsed_sec"], r["budget_exceeded"],
             r["auto_disabled"], len(r["errors"])))
    print("%-22s %8s %10s" % ("분류", "건수", "용량"))
    for k in sorted(r["totals"]):
        t = r["totals"][k]
        print("%-22s %8d %10s" % (k, t["count"], human(t["bytes"])))
    top = sorted(r["candidates"], key=lambda c: c["bytes"], reverse=True)[:20]
    if top:
        print("상위 %d건:" % len(top))
        for c in top:
            print("  %-11s %-8s %9s  %s" % (c["action"], c["scope"], human(c["bytes"]), c["path"]))
    for s in r["skipped"][:10]:
        print("  skip %s: %s" % (s["reason"], s["path"]))
    for e in r["errors"][:10]:
        print("  error %s" % e)


def write_log(path, ctx, rc):
    r = ctx.report
    cnt = sum(1 for c in r["candidates"] if c["action"] == "delete")
    byt = sum(c["bytes"] for c in r["candidates"] if c["action"] == "delete")
    line = "%s %s %s %d %d %.2f %d\n" % (iso(time.time()), r["mode"], ",".join(r["scopes"]) or "-",
                                       cnt, byt, r["elapsed_sec"], rc)
    try:
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        with open(path, "a", encoding="utf-8") as f:
            f.write(line)
        if os.path.getsize(path) > LOG_MAX_BYTES:
            with open(path, "rb") as f:
                f.seek(-LOG_KEEP_BYTES, os.SEEK_END)
                tail = f.read()
            nl = tail.find(b"\n")
            if nl >= 0:
                tail = tail[nl + 1:]
            tmp = path + ".tmp"
            with open(tmp, "wb") as f:
                f.write(tail)
            os.replace(tmp, path)
    except OSError:
        pass


# ─────────────────────────── 인자 ───────────────────────────
def build_parser():
    home = os.path.expanduser("~")
    p = argparse.ArgumentParser(description="하네스 임시 파일 판정·승격·정리(dry-run 기본)")
    p.add_argument("--scope", required=True, choices=["self", "sessions", "repo", "tmp", "all"])
    p.add_argument("--uuid")
    p.add_argument("--project")
    p.add_argument("--promote", action="store_true")
    p.add_argument("--apply", action="store_true")
    p.add_argument("--auto", action="store_true")
    p.add_argument("--enable-auto", action="store_true")
    p.add_argument("--days", type=int, default=30)
    p.add_argument("--budget", type=float, default=0.0)
    p.add_argument("--max-dirs", type=int, default=0)
    p.add_argument("--include-candidates", action="store_true")
    p.add_argument("--purge-plans", action="store_true")
    p.add_argument("--report")
    p.add_argument("--fail-open", action="store_true")
    p.add_argument("--session-base", default=os.path.join(home, ".claude", "session-env"))
    p.add_argument("--registry-dir", action="append")
    p.add_argument("--profile-glob", default="/tmp/cc-*")
    p.add_argument("--tmp-dir", default="/tmp")
    p.add_argument("--marker", default=os.path.join(home, ".claude", "logs", "harness_cleanup_auto.enabled"))
    p.add_argument("--log-file", default=os.path.join(home, ".claude", "logs", "harness_cleanup.log"))
    p.add_argument("--now", type=float)
    return p


def validate(p, a):
    if a.uuid is not None and not UUID_RE.fullmatch(a.uuid):
        p.error("--uuid 형식이 UUID 가 아닙니다")
    if a.scope == "self" and not a.uuid:
        p.error("--scope self 는 --uuid 가 필요합니다")
    if a.days < 1:
        p.error("--days 는 1 이상이어야 합니다")
    if a.max_dirs < 0 or a.budget < 0:
        p.error("--max-dirs/--budget 은 0 이상이어야 합니다")


def run(ctx):
    a = ctx.args
    scopes = ["sessions", "repo", "tmp"] if a.scope == "all" else [a.scope]
    ctx.report["scopes"] = scopes
    fns = {"self": run_self, "sessions": run_sessions, "repo": run_repo, "tmp": run_tmp}
    for s in scopes:
        if ctx.out_of_time():
            break
        fns[s](ctx)
    if a.enable_auto and ctx.apply and not ctx.report["errors"]:
        os.makedirs(os.path.dirname(a.marker) or ".", exist_ok=True)
        with open(a.marker, "w", encoding="utf-8") as f:
            f.write(iso(time.time()) + "\n")
        ctx.report["auto_enabled"] = True


def main(argv=None):
    p = build_parser()
    a = p.parse_args(argv)
    validate(p, a)
    a.session_base = os.path.abspath(a.session_base)
    ctx = Ctx(a)
    rc = 0
    t0 = time.monotonic()
    try:
        run(ctx)
    except Exception as e:  # noqa: BLE001 — fail-open 경로에서 전부 잡는다
        ctx.err("exception: %s: %s" % (type(e).__name__, e))
        rc = 0 if a.fail_open else 1
    ctx.report["elapsed_sec"] = round(time.monotonic() - t0, 3)
    ctx.report["budget_exceeded"] = ctx.report["budget_exceeded"] or ctx.budget.hit
    if a.report:
        try:
            os.makedirs(os.path.dirname(os.path.abspath(a.report)), exist_ok=True)
            with open(a.report, "w", encoding="utf-8") as f:
                json.dump(ctx.report, f, ensure_ascii=False, indent=1)
        except OSError as e:
            ctx.err("report_write_failed: %s" % e)
            if not a.fail_open:
                rc = rc or 1
    try:
        print_summary(ctx)
    except Exception:  # noqa: BLE001
        pass
    write_log(a.log_file, ctx, rc)
    return rc


if __name__ == "__main__":
    sys.exit(main())
