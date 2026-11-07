#!/usr/bin/env python3
# 다중 세션 git 정책(worktree 의무·단일 push 경로·정본 원격 판정)의 핵심 라이브러리·CLI
#
# 계획 conv_179358081232 §3~§5, §8.1. 모든 guard 판정은 경고(additionalContext)이며 block 은 0건이다.
# - permissionDecision 을 절대 내지 않는다. 강제 push 는 이 모듈이 쓰지 않는다.
# - 공용 자산이므로 프로젝트명·경로를 코드에 박지 않는다.
# 하위 명령: classify guard ensure link canonical push claim claim-check adopt doctor audit
import argparse
import datetime
import fcntl
import json
import os
import re
import secrets
import shlex
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SID_RE = re.compile(r"^[0-9a-fA-F-]{8,64}$")
EXCLUDE_LINE = "**/.claude/worktrees/"
CLAIM_TTL = 24 * 3600
GIT_TIMEOUT = 25

# rc 규약
RC_OK, RC_DIRTY, RC_CONFLICT, RC_NOREMOTE, RC_LOCK, RC_PUSHFAIL = 0, 2, 3, 4, 5, 6
RC_AHEAD = 7   # 원본 checkout 에서 push 했는데 원격보다 앞선 세션 worktree 가 있음
RC_BRANCH = 8  # 원본 checkout 의 현재 브랜치가 기본 브랜치가 아님


# ───────────────────────── 공통 ─────────────────────────

def cfg_base():
    return os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")


def now_iso():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def git_env():
    e = dict(os.environ)
    e["GIT_TERMINAL_PROMPT"] = "0"
    e["LC_ALL"] = "C"
    return e


def git(args, cwd=None, timeout=GIT_TIMEOUT):
    """git 실행. (rc, stdout, stderr). 시간 초과는 rc=124."""
    try:
        p = subprocess.run(["git", "-c", "core.quotePath=false"] + list(args), cwd=cwd, env=git_env(), capture_output=True,
                           text=True, timeout=timeout)
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"
    except (OSError, ValueError) as e:
        return 127, "", str(e)


def existing_dir(path):
    """path 또는 그 위쪽 중 실제 존재하는 디렉터리."""
    d = os.path.abspath(path)
    if os.path.isdir(d):
        return d
    d = os.path.dirname(d)
    while d and not os.path.isdir(d):
        nd = os.path.dirname(d)
        if nd == d:
            return None
        d = nd
    return d or None


def sid_of(given=None):
    s = (given or "").strip()
    return s.lower() if SID_RE.fullmatch(s) else ""


def session_dir(sid):
    return os.path.join(cfg_base(), "session-env", sid) if sid else ""


def read_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def _clean_stale_tmp(path):
    """강제 종료(timeout)로 남은 tmp 조각(60초 이상 지난 것)을 정리한다."""
    d, base = os.path.dirname(path), os.path.basename(path) + ".tmp."
    try:
        for n in os.listdir(d):
            if n.startswith(base):
                p = os.path.join(d, n)
                if time.time() - os.path.getmtime(p) > 60:
                    os.unlink(p)
    except OSError:
        pass


def write_json(path, obj):
    """원자적 쓰기(tmp → replace). 실패 시 tmp 를 지운다."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    _clean_stale_tmp(path)
    tmp = "%s.tmp.%d" % (path, os.getpid())
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(obj, f, ensure_ascii=False, indent=1)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def log_line(sid, name, text):
    if not sid:
        return
    try:
        d = os.path.join(session_dir(sid), "logs")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, name), "a", encoding="utf-8") as f:
            f.write("%s %s\n" % (now_iso(), text))
    except OSError:
        pass


# ───────────────────────── 저장소 판정 ─────────────────────────

_RI = {}  # 프로세스 내 메모: 디렉터리 → rev-parse 1회 결과


def repo_info(path):
    """git rev-parse 1회로 common dir·git dir·toplevel 을 묶어 얻는다(프로세스 내 메모)."""
    d = existing_dir(path)
    if not d:
        return None
    if d in _RI:
        return _RI[d]
    info = None
    rc, out, _ = git(["rev-parse", "--path-format=absolute", "--git-common-dir", "--git-dir", "--show-toplevel"], cwd=d)
    ls = out.splitlines()
    if rc == 0 and len(ls) >= 3:
        info = {"common": ls[0], "gitdir": ls[1], "top": ls[2]}
    else:
        rc, out, _ = git(["rev-parse", "--path-format=absolute", "--git-common-dir", "--git-dir"], cwd=d)
        ls = out.splitlines()
        if rc == 0 and len(ls) >= 2:
            info = {"common": ls[0], "gitdir": ls[1], "top": None}
    _RI[d] = info
    return info


def common_dir(path):
    i = repo_info(path)
    return i["common"] if i else None


def toplevel(path):
    i = repo_info(path)
    return i["top"] if i else None


def is_linked(path):
    i = repo_info(path)
    return bool(i) and os.path.realpath(i["gitdir"]) != os.path.realpath(i["common"])


def main_checkout(path):
    """원본 checkout 루트(linked worktree 에서도 원본을 돌려준다)."""
    cd = common_dir(path)
    if not cd:
        return None
    if os.path.basename(cd) == ".git":
        return os.path.dirname(cd)
    return toplevel(path)


# ── 세션 캐시(wt_cache.json, 자기 세션 경로에만 쓴다) ──
CACHE_TTL = 600
_CACHE_SID = ""


def _mt(p):
    """lstat 서명 + symlink 면 대상 파일(stat) 서명도 포함."""
    try:
        st = os.lstat(p)
        s = "%d:%d" % (st.st_mtime_ns, st.st_size)
        if os.path.islink(p):
            try:
                t = os.stat(p)
                s += ">%d:%d" % (t.st_mtime_ns, t.st_size)
            except OSError:
                s += ">-"
        return s
    except OSError:
        return "-"


def _tree_sig(root, limit=300):
    """refs/heads 하위(중첩 브랜치 포함) 재귀 서명."""
    out, n = [], 0
    for dp, dns, fns in os.walk(root):
        out.append(_mt(dp))
        for fn in fns:
            out.append(_mt(os.path.join(dp, fn)))
            n += 1
        if n > limit:
            break
    return ",".join(out)


def _sig(main_root, cd):
    """무효화 서명: HEAD·refs/heads(재귀)·worktrees·config·INFRA.md(symlink 는 대상 기준)·.claude 의 변경."""
    return "|".join([_mt(p) for p in (
        os.path.join(cd, "HEAD"), os.path.join(cd, "packed-refs"), os.path.join(cd, "worktrees"),
        os.path.join(cd, "config"), os.path.join(main_root, "INFRA.md"), os.path.join(main_root, ".claude"))]
        + [_tree_sig(os.path.join(cd, "refs", "heads"))])


def cache_get(kind, main_root, cd):
    if not _CACHE_SID or not main_root or not cd:
        return None
    data = read_json(os.path.join(session_dir(_CACHE_SID), "wt_cache.json"), {})
    e = data.get(kind + "|" + main_root) if isinstance(data, dict) else None
    if isinstance(e, dict) and time.time() - e.get("t", 0) < CACHE_TTL and e.get("sig") == _sig(main_root, cd):
        return e.get("val")
    return None


def cache_put(kind, main_root, cd, val):
    if not _CACHE_SID or not main_root or not cd:
        return
    p = os.path.join(session_dir(_CACHE_SID), "wt_cache.json")
    data = read_json(p, {})
    if not isinstance(data, dict):
        data = {}
    now = time.time()
    data = {k: v for k, v in data.items() if isinstance(v, dict) and now - v.get("t", 0) < CACHE_TTL}
    data[kind + "|" + main_root] = {"t": now, "sig": _sig(main_root, cd), "val": val}
    try:
        write_json(p, data)
    except OSError:
        pass


def repo_rel(path):
    """path 의 저장소(worktree) 루트 기준 상대경로."""
    ap = os.path.abspath(path)
    top = toplevel(ap)
    if not top:
        return None
    r = os.path.relpath(os.path.realpath(ap), os.path.realpath(top))
    return r.replace(os.sep, "/")


def has_commit(repo):
    return git(["rev-parse", "-q", "--verify", "HEAD"], cwd=repo)[0] == 0


def infra_fields(main_root):
    """INFRA.md 의 INFRA-FIELDS 블록 key: value 사전."""
    out = {}
    try:
        with open(os.path.join(main_root, "INFRA.md"), encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError:
        return out
    m = re.search(r"<!--\s*INFRA-FIELDS[^>]*-->(.*?)<!--\s*/INFRA-FIELDS\s*-->", text, re.S)
    if not m:
        return out
    for ln in m.group(1).splitlines():
        mm = re.fullmatch(r"^\s*([A-Za-z0-9_]+)\s*:\s*(.*?)\s*$", ln)
        if mm:
            out[mm.group(1)] = mm.group(2).strip().strip("'\"")
    return out


def remotes_of(repo):
    rc, out, _ = git(["remote"], cwd=repo)
    return out.split() if rc == 0 and out else []


def canonical_remote(repo):
    """정본 원격 판정: INFRA git_canonical > gitea/gitlab 이름 > origin. 도달성은 보지 않는다."""
    main = main_checkout(repo) or repo
    cd = common_dir(main)
    hit = cache_get("canon", main, cd)
    if hit:
        return dict(hit)
    res = _canonical_remote(main)
    cache_put("canon", main, cd, res)
    return res


def _canonical_remote(main):
    names = remotes_of(main)
    infra = infra_fields(main).get("git_canonical", "")
    if infra:
        if infra in names:
            return {"remote": infra, "source": "infra"}
        return {"remote": None, "source": "infra", "error": "git_canonical=%s 원격이 설정돼 있지 않다" % infra}
    for n in ("gitea", "gitlab"):
        if n in names:
            return {"remote": n, "source": "name"}
    if "origin" in names:
        return {"remote": "origin", "source": "origin"}
    return {"remote": None, "source": None}


def default_branch(repo, remote):
    """기본 브랜치: refs/remotes/R/HEAD > ls-remote --symref(5초) > 원본 현재 브랜치. 하드코딩 없음."""
    if remote:
        rc, out, _ = git(["symbolic-ref", "-q", "refs/remotes/%s/HEAD" % remote], cwd=repo)
        if rc == 0 and out.startswith("refs/remotes/%s/" % remote):
            return out[len("refs/remotes/%s/" % remote):]
        rc, out, _ = git(["ls-remote", "--symref", remote, "HEAD"], cwd=repo, timeout=5)
        if rc == 0:
            m = re.search(r"^ref:\s+refs/heads/(\S+)\s+HEAD", out, re.M)
            if m:
                return m.group(1)
    main = main_checkout(repo) or repo
    rc, out, _ = git(["symbolic-ref", "--short", "-q", "HEAD"], cwd=main)
    return out if rc == 0 and out else None


def canonical(repo):
    c = canonical_remote(repo)
    c["default_branch"] = default_branch(repo, c.get("remote")) if c.get("remote") else None
    return c


def policy_applies(main_root):
    """적용 대상: git + 커밋 1개 이상 + 루트 .claude 디렉터리(비 symlink) + git_worktree 가 off 아님."""
    if not main_root:
        return False
    cl = os.path.join(main_root, ".claude")
    if not os.path.isdir(cl) or os.path.islink(cl):
        return False
    cd = common_dir(main_root)
    hit = cache_get("policy", main_root, cd)
    if hit is not None:
        return bool(hit)
    res = has_commit(main_root) and infra_fields(main_root).get("git_worktree", "").lower() != "off"
    cache_put("policy", main_root, cd, bool(res))
    return bool(res)


def classify(path, sid="", cwd=None):
    ap = path if os.path.isabs(path) else os.path.join(cwd or os.getcwd(), path)
    ap = os.path.normpath(ap)
    res = {"policy": False, "repo_common": None, "main_root": None, "worktree_root": None,
           "rel": None, "ignored": False, "in_main": False}
    d = existing_dir(ap)
    if not d:
        return res
    cd = common_dir(d)
    if not cd:
        return res
    main = main_checkout(d)
    top = toplevel(d)
    res["repo_common"], res["main_root"] = cd, main
    res["policy"] = policy_applies(main)
    if not top:
        return res
    rel = os.path.relpath(os.path.realpath(ap), os.path.realpath(top)).replace(os.sep, "/")
    res["rel"] = None if rel.startswith("..") else rel
    res["in_main"] = os.path.realpath(top) == os.path.realpath(main or "")
    if is_linked(d):
        res["worktree_root"] = top
    else:
        res["worktree_root"] = session_worktree(sid, cd)
    if res["rel"] is not None:
        res["ignored"] = git(["check-ignore", "-q", "--", rel], cwd=top)[0] == 0
    return res


# ───────────────────────── 세션 worktree 기록 ─────────────────────────

WT_SEG = "/.claude/worktrees/"


def is_real_worktree(w, repo_common=None):
    """w 가 실제 linked worktree 루트인가(.git 이 파일 + 같은 저장소). 삭제 뒤 mkdir 로 생긴 껍데기는 False."""
    if not w or not os.path.isfile(os.path.join(w, ".git")):
        return False
    if not is_linked(w) or os.path.realpath(toplevel(w) or "") != os.path.realpath(w):
        return False
    return not repo_common or os.path.realpath(common_dir(w) or "") == os.path.realpath(repo_common)


def ghost_worktree(path):
    """path 가 <저장소>/.claude/worktrees/ 아래인데 실제 worktree 안이 아니면 그 폴더, 아니면 None.
    여기는 exclude 로 ignored 이고 git 은 위쪽 원본으로 풀리므로, 쓰면 커밋되지 않거나 원본에 들어간다."""
    ap = os.path.normpath(os.path.abspath(path))
    i = ap.find(WT_SEG)
    if i < 0:
        return None
    base = ap[:i]
    if not os.path.exists(os.path.join(base, ".git")):
        return None
    cur, first = base + WT_SEG.rstrip("/"), None
    for seg in ap[i + len(WT_SEG):].split(os.sep):
        cur = os.path.join(cur, seg)
        first = first or cur
        if os.path.isfile(os.path.join(cur, ".git")):
            return None if is_real_worktree(cur) else cur
        if not os.path.isdir(cur):
            break
    return first


def default_ref(main):
    """정본 원격의 기본 브랜치 추적 ref(네트워크 없음). 판정 불가면 None."""
    r = canonical_remote(main).get("remote")
    if not r:
        return None
    rc, out, _ = git(["symbolic-ref", "-q", "refs/remotes/%s/HEAD" % r], cwd=main)
    if rc == 0 and out.startswith("refs/remotes/"):
        return out[len("refs/remotes/"):]
    cur = git(["symbolic-ref", "--short", "-q", "HEAD"], cwd=main)[1]
    ref = "%s/%s" % (r, cur) if cur else None
    return ref if ref and git(["rev-parse", "-q", "--verify", "refs/remotes/" + ref], cwd=main)[0] == 0 else None


def status_entries(cwd):
    """git status 추적 변경의 (XY, 경로) 목록. rename 은 양쪽 경로를 모두 넣는다."""
    out, i = [], 0
    parts = git_bytes(["status", "--porcelain", "-z", "--untracked-files=no"], cwd)[1].decode("utf-8", "replace").split("\0")
    while i < len(parts):
        ent = parts[i]
        i += 1
        if len(ent) < 4:
            continue
        out.append((ent[:2], ent[3:]))
        if ent[0] in "RC" or ent[1] in "RC":
            if i < len(parts) and parts[i]:
                out.append((ent[:2], parts[i]))
            i += 1
    return out


def wt_loss(wt, ref):
    """지우면 잃는 것: 추적 변경 수·untracked 수·기본 브랜치에 패치가 없는 커밋 수(ref 없으면 None)."""
    rc, out, _ = git(["status", "--porcelain"], cwd=wt)
    ls = out.splitlines() if rc == 0 else []
    uc = None
    if ref:
        rc, o2, _ = git(["cherry", ref, "HEAD"], cwd=wt)
        if rc == 0:
            uc = sum(1 for x in o2.splitlines() if x.startswith("+"))
    return {"tracked": sum(1 for x in ls if not x.startswith("??")), "untracked": sum(1 for x in ls if x.startswith("??")), "unique_commits": uc}


def registered_worktrees(main):
    """git worktree list --porcelain 을 사전 목록으로(첫 항목은 원본)."""
    rc, out, _ = git(["worktree", "list", "--porcelain"], cwd=main)
    res, cur = [], None
    for ln in (out.splitlines() if rc == 0 else []) + [""]:
        if ln.startswith("worktree "):
            cur = {"path": ln[9:], "branch": "", "locked": None}
        elif cur is not None and ln.startswith("branch "):
            cur["branch"] = ln[7:].replace("refs/heads/", "")
        elif cur is not None and ln.startswith("locked"):
            cur["locked"] = ln[6:].strip() or "locked"
        elif ln == "" and cur:
            res.append(cur)
            cur = None
    return res


def wt_delete_warn(path, warns):
    """지워지면 미커밋·미반영 커밋을 잃는 worktree 가 path 안에 있으면 ⛔ 경고(차단 아님)."""
    d = existing_dir(path)
    main = main_checkout(d) if d else None
    if not main:
        return
    target = os.path.realpath(path)
    ref = default_ref(main)
    for w in registered_worktrees(main)[1:]:
        rp = os.path.realpath(w["path"])
        if rp != target and not rp.startswith(target + os.sep):
            continue
        loss = wt_loss(rp, ref) if os.path.isdir(rp) else None
        if loss and (loss["tracked"] or loss["untracked"] or loss["unique_commits"]):
            warns.append("⛔ [wt 미커밋 삭제] worktree %s 를 지우려 한다. 추적 변경 %d·untracked %d·미반영 커밋 %s 건을 잃는다. 커밋·push 뒤 지우고, 주인이 있으면 먼저 확인하라(경고만 — 차단 아님)."
                         % (rp, loss["tracked"], loss["untracked"], loss["unique_commits"]))


def wt_record_path(sid):
    return os.path.join(session_dir(sid), "worktrees.json") if sid else ""


def session_record(sid):
    p = wt_record_path(sid)
    d = read_json(p, {}) if p else {}
    return d if isinstance(d, dict) else {}


def session_worktree(sid, repo_common):
    """세션 worktrees.json 에서 저장소 common dir 에 해당하는 worktree 경로(존재할 때만)."""
    if not sid or not repo_common:
        return None
    rec = session_record(sid)
    key = os.path.realpath(repo_common)
    for k, v in rec.items():
        if os.path.realpath(k) == key and isinstance(v, dict):
            w = v.get("worktree")
            if w and is_real_worktree(w, repo_common):
                return w
    return None


def record_worktree(sid, worktree, name=None):
    if not sid or not worktree:
        return
    cd = common_dir(worktree)
    if not cd:
        return
    rc, br, _ = git(["symbolic-ref", "--short", "-q", "HEAD"], cwd=worktree)
    rec = session_record(sid)
    rec[os.path.realpath(cd)] = {"worktree": os.path.realpath(worktree), "branch": br if rc == 0 else "",
                                 "name": name or os.path.basename(worktree),
                                 "main_root": main_checkout(worktree)}
    try:
        write_json(wt_record_path(sid), rec)
    except OSError:
        pass


def session_name(known_only=False):
    """tmux 세션명에서 claude- 접두어를 뗀 값, 없으면 6자 임의(known_only 면 빈 문자열)."""
    n = os.environ.get("WT_SESSION_NAME", "")
    if not n and os.environ.get("TMUX"):
        try:
            p = subprocess.run(["tmux", "display-message", "-p", "#S"], capture_output=True, text=True, timeout=2)
            n = p.stdout.strip() if p.returncode == 0 else ""
        except (OSError, subprocess.SubprocessError):
            n = ""
    n = re.sub(r"^claude-", "", n)
    n = re.sub(r"[^A-Za-z0-9._-]", "", n)[:20]
    if known_only:
        return n
    return n or secrets.token_hex(3)


# ───────────────────────── ensure / link / exclude / hook ─────────────────────────

LINK_ITEMS = ["CLAUDE.md", "AGENTS.md", ".mcp.json", "INFRA.md",
              ".claude/hooks", ".claude/skills", ".claude/commands",
              ".claude/settings.json", ".claude/settings.local.json", ".claude/role_paths.json"]


def ensure_exclude(cd):
    """.git/info/exclude 에 worktrees 줄을 멱등 등록. 이미 같은 뜻의 줄이 있으면 추가하지 않는다."""
    p = os.path.join(cd, "info", "exclude")
    try:
        with open(p, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        text = ""
    for ln in text.splitlines():
        s = ln.strip().rstrip("/")
        if s in (".claude/worktrees", "/.claude/worktrees", "**/.claude/worktrees") or s.endswith("/.claude/worktrees"):
            return False
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "a", encoding="utf-8") as f:
        if text and not text.endswith("\n"):
            f.write("\n")
        f.write(EXCLUDE_LINE + "\n")
    return True


COMMIT_MSG_HOOK = """#!/bin/sh
# 다중 세션 git 정책: worktree-* 브랜치 커밋에 Session 트레일러(UUID 없음)를 덧붙인다
f="$1"
b=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
case "$b" in
  worktree-*) grep -q '^Session:' "$f" 2>/dev/null || printf '\\nSession: %s\\n' "$b" >> "$f" ;;
esac
exit 0
"""


def install_commit_msg(cd):
    """설치 결과 문자열: installed|exists|skipped(...)."""
    wd = os.path.dirname(cd) if os.path.basename(cd) == ".git" else cd
    rc, hp, _ = git(["config", "--get", "core.hooksPath"], cwd=wd)
    if rc == 0 and hp:
        return "skipped(core.hooksPath)"
    hd = os.path.join(cd, "hooks")
    p = os.path.join(hd, "commit-msg")
    if os.path.exists(p):
        try:
            with open(p, encoding="utf-8", errors="replace") as f:
                return "exists" if "다중 세션 git 정책" in f.read() else "skipped(existing hook)"
        except OSError:
            return "skipped(existing hook)"
    os.makedirs(hd, exist_ok=True)
    with open(p, "w", encoding="utf-8") as f:
        f.write(COMMIT_MSG_HOOK)
    os.chmod(p, 0o755)
    return "installed"


def link_worktree(wt):
    """원본의 ignored symlink·INFRA.md 를 worktree 에 symlink 한다(복사 금지). 만든 항목 목록."""
    main = main_checkout(wt)
    made = []
    if not main or os.path.realpath(main) == os.path.realpath(wt):
        return made
    for item in LINK_ITEMS:
        src = os.path.join(main, item)
        dst = os.path.join(wt, item)
        if not os.path.lexists(src) or os.path.lexists(dst):
            continue
        if git(["ls-files", "--error-unmatch", "--", item], cwd=main)[0] == 0:
            continue  # 추적 파일이면 worktree 에 이미 있다
        try:
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            os.symlink(src, dst)
            made.append(item)
        except OSError:
            pass
    return made


def ensure(repo, name=None, sid=""):
    main = main_checkout(repo)
    if not main:
        return {"ok": False, "error": "git 저장소가 아니다", "rc": 1}
    cd = common_dir(repo)
    if os.path.islink(os.path.join(main, ".claude")):
        return {"ok": False, "error": ".claude 가 symlink 라 비적용", "rc": 1}
    if not has_commit(main):
        return {"ok": False, "error": "커밋이 없어 비적용", "rc": 1}
    sid0 = sid_of(sid) or sid_of(os.environ.get("PIPELINE_UUID"))
    if not name:
        # 이름 없는 호출은 이 세션이 이미 쓰는 worktree 를 돌려준다. tmux 이름이 다르거나 없으면 커밋 폴더가 갈라졌다.
        w0 = session_worktree(sid0, cd)
        if w0:
            return {"ok": True, "worktree": w0, "branch": git(["symbolic-ref", "--short", "-q", "HEAD"], cwd=w0)[1],
                    "name": os.path.basename(w0), "created": False, "reused": True, "exclude_added": ensure_exclude(cd),
                    "commit_msg_hook": install_commit_msg(cd), "linked": link_worktree(w0), "rc": 0}
    name = re.sub(r"[^A-Za-z0-9._-]", "", name or "") or session_name()
    wt = os.path.join(main, ".claude", "worktrees", name)
    if os.path.isdir(wt) and not is_real_worktree(wt, cd):
        # 껍데기 폴더: 빈 폴더만 치운다. 안에 파일이 있으면 지우지 않고 멈춘다(그 파일은 어느 커밋에도 없다).
        try:
            os.rmdir(wt)
            _RI.pop(wt, None)
        except OSError:
            return {"ok": False, "error": "%s 는 worktree 가 아닌 껍데기 폴더이고 파일이 있다. 파일을 옮긴 뒤 다시 실행하라" % wt, "rc": 1}
    if not os.path.isdir(wt) and any(os.path.realpath(x["path"]) == os.path.realpath(wt) for x in registered_worktrees(main)):
        git(["worktree", "prune"], cwd=main)  # 폴더만 사라진 등록 잔류. prune 은 폴더 없는 항목의 메타데이터만 지운다(브랜치·커밋 보존)
    inherited = None
    if os.path.isdir(wt) and session_worktree(sid0, cd) != os.path.realpath(wt):
        _l = wt_loss(wt, default_ref(main))
        if _l["tracked"] or _l["untracked"] or _l["unique_commits"]:
            inherited = _l
    branch = "worktree-" + name
    excl = ensure_exclude(cd)
    hook = install_commit_msg(cd)
    created = False
    if not os.path.isdir(wt):
        os.makedirs(os.path.dirname(wt), exist_ok=True)
        c = canonical_remote(main)
        base = None
        if c.get("remote"):
            d = default_branch(main, c["remote"])
            if d:
                git(["fetch", c["remote"], d], cwd=main, timeout=5)  # 낡은 추적 ref 에서 시작하지 않게 한다. 실패·시간 초과는 그대로 진행
            if d and git(["rev-parse", "-q", "--verify", "refs/remotes/%s/%s" % (c["remote"], d)], cwd=main)[0] == 0:
                base = "%s/%s" % (c["remote"], d)
        if git(["rev-parse", "-q", "--verify", "refs/heads/" + branch], cwd=main)[0] == 0:
            rc, _, err = git(["worktree", "add", wt, branch], cwd=main, timeout=60)
        else:
            rc, _, err = git(["worktree", "add", "-b", branch, wt, base or "HEAD"], cwd=main, timeout=60)
        if rc != 0:
            return {"ok": False, "error": "worktree add 실패: " + err, "rc": 1}
        created = True
    linked = link_worktree(wt)
    record_worktree(sid0, wt, name)
    res = {"ok": True, "worktree": wt, "branch": branch, "name": name, "created": created,
           "exclude_added": excl, "commit_msg_hook": hook, "linked": linked, "rc": 0}
    if inherited:
        res["inherited"] = inherited  # 다른 세션의 미커밋·미반영 커밋을 이어받았다. 지우지 않고 알린다
    return res


# ───────────────────────── claim ─────────────────────────

def claims_path(cd):
    return os.path.join(cd, "harness-claims.json")


def _with_claims(cd, fn):
    p = claims_path(cd)
    os.makedirs(cd, exist_ok=True)
    with open(p + ".lock", "a") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        data = read_json(p, {})
        if not isinstance(data, dict):
            data = {}
        now = time.time()
        for k in list(data):
            v = data[k]
            if not isinstance(v, dict) or now - v.get("t", 0) > CLAIM_TTL or not os.path.isdir(v.get("worktree", "")):
                del data[k]
        res = fn(data)
        write_json(p, data)
        return res


def claim_live(rel, cur):
    """선점 기록이 아직 유효한가: 그 worktree 에 rel 의 미커밋이 있거나, 기본 브랜치에 패치가 없는 커밋이 rel 을 건드린다.
    PreToolUse 는 쓰기 직전에 돌므로 새 기록은 유예한다. 판정 불가면 유효로 본다(경고를 잃지 않는 쪽)."""
    try:
        grace = float(os.environ.get("WT_CLAIM_GRACE", "120"))
    except ValueError:
        grace = 120.0
    if time.time() - cur.get("t", 0) < grace:
        return True
    w = cur.get("worktree", "")
    if not is_real_worktree(w):
        return False
    if git(["status", "--porcelain", "--", rel], cwd=w)[1]:
        return True
    ref = default_ref(main_checkout(w) or w)
    if not ref:
        return True
    rc, out, _ = git(["log", "--cherry-pick", "--right-only", "--format=%h", "%s...HEAD" % ref, "--", rel], cwd=w)
    return rc != 0 or bool(out)


def claim(cd, rel, branch, name, worktree):
    """쓰기 순간 자동 claim(상대경로·브랜치·세션명, UUID 없음). 다른 브랜치가 먼저 잡았으면 그 목록을 돌려준다."""
    def fn(data):
        others = []
        cur = data.get(rel)
        if cur and cur.get("branch") != branch and claim_live(rel, cur):
            others.append({"branch": cur.get("branch"), "name": cur.get("name")})
        else:
            data[rel] = {"branch": branch, "name": name, "worktree": worktree, "t": time.time()}
        return others
    return _with_claims(cd, fn)


def release_claims(cd, branch):
    """push 성공 후 해당 브랜치의 claim 을 해제한다."""
    def fn(data):
        for k in [k for k, v in data.items() if v.get("branch") == branch]:
            del data[k]
    _with_claims(cd, fn)


def ahead_worktrees(repo, ref):
    """ref(원격/기본 브랜치)보다 앞선 커밋을 가진 다른 linked worktree 경로 목록."""
    rc, out, _ = git(["worktree", "list", "--porcelain"], cwd=repo)
    res, cur = [], None
    for ln in (out.splitlines() if rc == 0 else []) + [""]:
        if ln.startswith("worktree "):
            cur = ln[9:]
        elif ln == "" and cur:
            if os.path.realpath(cur) != os.path.realpath(repo):
                rc2, n, _ = git(["rev-list", "--count", "%s..HEAD" % ref], cwd=cur)
                if rc2 == 0 and n.isdigit() and int(n) > 0:
                    res.append(cur)
            cur = None
    return res


def claim_check(cd, rel, branch=""):
    def fn(data):
        cur = data.get(rel)
        if cur and cur.get("branch") != branch and claim_live(rel, cur):
            return [{"branch": cur.get("branch"), "name": cur.get("name")}]
        return []
    return _with_claims(cd, fn)


# ───────────────────────── push ─────────────────────────

def resolve_push_repo(repo, sid):
    """push 대상 worktree 해석: --repo 가 원본이고 세션 기록에 worktree 가 있으면 그것, 없으면 --repo 자체.
    --repo 없으면 세션 worktrees.json(단일 항목)으로. cwd 는 마지막 폴백으로만 쓴다."""
    if repo:
        g = ghost_worktree(repo)
        if g:
            return None, "%s 는 실제 worktree 가 아니다(삭제 뒤 남은 껍데기 등). 여기서 push 하면 원본 HEAD 가 올라간다 — ensure 후 재실행하라" % g
        cd = common_dir(repo)
        w = session_worktree(sid, cd) if cd else None
        if w and not is_linked(repo):
            return w, None
        return toplevel(repo) or repo, None
    rec = session_record(sid)
    recorded = [v["worktree"] for v in rec.values() if isinstance(v, dict) and v.get("worktree")]
    alive = [w for w in recorded if is_real_worktree(w)]
    if len(alive) == 1:
        return alive[0], None
    if len(alive) > 1:
        return None, "세션 worktree 가 여러 개다 — --repo 를 지정하라: " + ", ".join(alive)
    if recorded:
        return None, "세션 기록의 worktree 가 실제 worktree 가 아니다: %s — cwd 로 대신 push 하지 않는다. ensure 후 재실행하라" % ", ".join(recorded)
    t = toplevel(os.getcwd())
    return (t, None) if t else (None, "저장소를 찾지 못했다 — --repo 를 지정하라")


def acquire_lock(path, timeout):
    f = open(path, "a")
    end = time.time() + timeout
    while True:
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return f
        except OSError:
            if time.time() >= end:
                f.close()
                return None
            time.sleep(0.2)


def same_as_commit(main, sha, rel):
    """원본의 rel 내용이 커밋 sha 의 내용과 바이트까지 같은가(둘 다 없음 포함)."""
    rc, blob = git_bytes(["show", "%s:%s" % (sha, rel)], main)
    pf = os.path.join(main, rel)
    if rc != 0:
        return not os.path.lexists(pf)
    try:
        with open(pf, "rb") as f:
            return f.read() == blob
    except OSError:
        return False


def ff_main(main, wt, branch_d, sha, permit):
    """push 성공 후 원본 ff. 결과 문자열. 미커밋을 지우는 동작은 없다: 겹치면 보고만 한다."""
    if os.path.realpath(main) == os.path.realpath(wt):
        return "same(원본에서 push)"
    rc, cur, _ = git(["symbolic-ref", "--short", "-q", "HEAD"], cwd=main)
    if rc != 0 or cur != branch_d:
        return "skipped(원본이 %s 브랜치가 아님)" % branch_d
    if infra_fields(main).get("git_live_apply", "").lower() == "gated" and not permit:
        return "deferred(gated — 적용허가 없음)"
    inc = {x for x in git_bytes(["diff", "--name-only", "-z", "HEAD", sha], main)[1].decode("utf-8", "replace").split("\0") if x}
    overlap = sorted({p for _, p in status_entries(main)} & inc)
    differ = [r for r in overlap if not same_as_commit(main, sha, r)]
    if differ:
        return "skipped(원본 추적 변경이 ff 대상과 겹침 — dirty: %s)" % ", ".join(differ[:3])
    # 겹치지만 내용이 같은 경로(승격기 적용본 등)는 색인에 올린다. 파일을 건드리지 않고, 그 사이 내용이 바뀌면 git 이 거부한다.
    for r in overlap:
        git(["add", "--", r] if os.path.lexists(os.path.join(main, r)) else ["rm", "--cached", "-q", "--", r], cwd=main)
    keep_x = []
    if git(["config", "--get", "core.fileMode"], cwd=main)[1].lower() == "false":
        # fileMode=false 면 색인이 100644 여도 디스크는 755 일 수 있고, ff 가 파일을 다시 쓰면 비트가 사라진다(실측 f272e9c).
        keep_x = [r for r in inc if os.path.isfile(os.path.join(main, r)) and os.access(os.path.join(main, r), os.X_OK)]
    rc, err = 1, ""
    for attempt in range(3):
        # --no-overwrite-ignore: 기본값은 원본의 ignored 파일을 말없이 덮어쓴다
        rc, _, err = git(["merge", "--ff-only", "--no-overwrite-ignore", sha], cwd=main, timeout=60)
        if rc == 0 or "index.lock" not in err:
            break
        time.sleep(1 + attempt)
    if rc != 0:
        if overlap:
            git(["reset", "-q", "--"] + overlap, cwd=main)  # 색인만 되돌린다. 작업 트리는 그대로다
        return "failed(%s)" % err[:120]
    for r in keep_x:
        p = os.path.join(main, r)
        try:
            if os.path.isfile(p) and not os.access(p, os.X_OK):
                os.chmod(p, os.stat(p).st_mode | 0o111)
        except OSError:
            pass
    return "ff"


def mode_warnings(wt, before, sha):
    """fileMode=false 로 색인에 100644 로 들어간 실행 파일 경고. 작업 트리가 실행 가능한데 색인이 644 인 경로만 본다."""
    if not before:
        return []
    names = [x for x in git_bytes(["diff", "--name-only", "-z", "--diff-filter=AM", before, sha], wt)[1].decode("utf-8", "replace").split("\0") if x][:200]
    if not names:
        return []
    bad = []
    for ln in git(["ls-files", "-s", "--"] + names, cwd=wt)[1].splitlines():
        head, _, rel = ln.partition("\t")
        if head.startswith("100644") and os.path.isfile(os.path.join(wt, rel)) and os.access(os.path.join(wt, rel), os.X_OK):
            bad.append(rel)
    if not bad:
        return []
    return ["⚠️ [wt 실행 비트] 작업 폴더는 실행 가능한데 커밋은 100644 다: %s. 원본·다른 worktree 에서 비트가 사라진다. `git update-index --chmod=+x <경로>` 후 커밋하라." % ", ".join(bad[:5])]


def push(repo=None, sid="", permit=False):
    t0 = time.time()
    sid = sid_of(sid) or sid_of(os.environ.get("PIPELINE_UUID"))
    wt, err = resolve_push_repo(repo, sid)
    if err or not wt:
        return {"ok": False, "rc": RC_DIRTY, "error": err}, RC_DIRTY
    main = main_checkout(wt)
    warnings = []
    if not is_linked(wt):
        warnings.append("원본 checkout 에서 push 한다 — worktree 에서 작업하는 것이 정책이다(경고만, 진행)")
    if git(["status", "--porcelain", "--untracked-files=no"], cwd=wt)[1]:
        return {"ok": False, "rc": RC_DIRTY, "error": "추적 변경이 남아 있다 — 먼저 커밋하라", "warnings": warnings}, RC_DIRTY
    c = canonical(wt)
    R, D = c.get("remote"), c.get("default_branch")
    if not R or not D:
        return {"ok": False, "rc": RC_NOREMOTE, "error": c.get("error") or "정본 원격 또는 기본 브랜치를 판정하지 못했다",
                "canonical": c, "warnings": warnings}, RC_NOREMOTE
    linked = is_linked(wt)
    if not linked:
        cur = git(["symbolic-ref", "--short", "-q", "HEAD"], cwd=wt)[1]
        if cur != D:
            return {"ok": False, "rc": RC_BRANCH, "error": "원본 checkout 의 현재 브랜치(%s)가 기본 브랜치(%s)가 아니라 push 하지 않는다" % (cur or "detached", D),
                    "warnings": warnings}, RC_BRANCH
    cd = common_dir(wt)
    lock_timeout = float(os.environ.get("WT_LOCK_TIMEOUT", "60"))
    lk = acquire_lock(os.path.join(cd, "harness-push.lock"), lock_timeout)
    if lk is None:
        return {"ok": False, "rc": RC_LOCK, "error": "push 잠금 대기 시간 초과", "warnings": warnings}, RC_LOCK
    last_err = ""
    try:
        for attempt in range(1, 4):
            if time.time() - t0 > 80:
                break
            rc, _, e = git(["fetch", R, D], cwd=wt, timeout=25)
            remote_empty = rc != 0 and "find remote ref" in e
            if rc != 0 and not remote_empty:
                last_err = "fetch 실패: " + e
                time.sleep(2 * attempt)
                continue
            if not remote_empty and linked:
                rc, _, e = git(["rebase", "%s/%s" % (R, D)], cwd=wt, timeout=40)
                if rc != 0:
                    files = [x for x in git_bytes(["diff", "--name-only", "-z", "--diff-filter=U"], wt)[1].decode("utf-8", "replace").split("\0") if x]
                    saved = rescue_before_abort(wt)
                    arc = git(["rebase", "--abort"], cwd=wt)[0]
                    restored = restore_after_abort(wt, saved)
                    out = {"ok": False, "rc": RC_CONFLICT, "error": "rebase 충돌 — 자동 해결 없음" if files else "rebase 를 시작·진행하지 못했다(충돌 아님 — detail 참조)",
                           "conflicts": files, "against": "%s/%s" % (R, D), "detail": e[:400], "warnings": warnings}
                    if saved and saved.get("files"):
                        out["rescued"] = {"dir": saved["dir"], "restored": restored}
                    if arc != 0 and saved is not None:
                        out["warnings"] = warnings + ["⛔ rebase --abort 실패 — %s 가 rebase 중이다. 직접 확인하라" % wt]
                    return out, RC_CONFLICT
            elif not remote_empty:
                # 원본 checkout 에서는 rebase 하지 않는다. 원격보다 앞선 세션 worktree 가 있으면 거부하고 안내한다.
                # --sid 가 있으면: 이 세션 것(기록 브랜치 또는 worktree-<세션명>)이 앞서 있을 때만 거부, 타 세션 것은 warnings 에 목록만 싣는다
                ahead = ahead_worktrees(wt, "%s/%s" % (R, D))
                mine, others = [], []
                if sid:
                    # 이 저장소(common dir)에 대한 이 sid 의 기록만 증거로 본다(다른 저장소 기록은 무관)
                    rec_one = session_record(sid).get(os.path.realpath(cd))
                    rec_all = {"this": rec_one} if isinstance(rec_one, dict) else {}
                    mine_br = {v.get("branch") for v in rec_all.values()}
                    sname = session_name(known_only=True)
                    if sname:
                        mine_br.add("worktree-" + sname)
                    for pth in ahead:
                        if not rec_all:
                            mine.append(pth)  # 이 sid 의 worktree 기록이 전혀 없으면 내 것이 아니라고 증명할 수 없다 → 전부 내 것으로 보고 거부
                        elif git(["symbolic-ref", "--short", "-q", "HEAD"], cwd=pth)[1] in mine_br:
                            mine.append(pth)
                        else:
                            others.append(pth)  # 기록이 있을 때만 타 세션 것으로 돌린다
                    if others:
                        wmsg = "원격보다 앞선 타 세션 worktree(참고, push 대상 아님): " + ", ".join(others)
                        if wmsg not in warnings:
                            warnings.append(wmsg)
                else:
                    mine = ahead
                if mine:
                    return {"ok": False, "rc": RC_AHEAD, "error": "원본 checkout 에서 push 할 수 없다 — 원격보다 앞선 worktree 가 있다. "
                            "--sid <세션 UUID> 필수, 세션 worktree 가 없으면 `wt_lib.py ensure --repo <원본> --sid <UUID>` 후 재실행하라. "
                            "ensure 로 이 세션의 기록을 만든 뒤 재실행하거나, 자기 worktree 를 알면 `--repo <그 worktree>` 로 지정하라"
                            "(이 sid 의 worktree 기록이 없으면 앞선 worktree 를 내 것이 아니라고 증명할 수 없어 거부한다)",
                            "ahead_worktrees": mine, "warnings": warnings}, RC_AHEAD
            before = git(["rev-parse", "-q", "--verify", "refs/remotes/%s/%s" % (R, D)], cwd=wt)[1]
            rc, _, e = git(["push", R, "HEAD:refs/heads/" + D], cwd=wt, timeout=25)
            if rc != 0 and not linked and not remote_empty and \
                    (git(["rev-list", "--count", "HEAD..%s/%s" % (R, D)], cwd=wt)[1] or "0") not in ("0", ""):
                return {"ok": False, "rc": RC_PUSHFAIL, "error": "원격이 앞섬 — 원본에는 rebase 하지 않는다. worktree 에서 push 하라",
                        "warnings": warnings}, RC_PUSHFAIL
            if rc == 0:
                sha = git(["rev-parse", "HEAD"], cwd=wt)[1]
                adopt_report, ff = adopt_and_ff(sid, main, wt, D, sha, permit) if linked else ({}, None)
                if ff is None:
                    ff = ff_main(main, wt, D, sha, permit)
                live = ff == "ff" or ff.startswith("same")
                if not live:
                    warnings.append("⚠️ [wt 원본 미반영] 원격에는 올라갔지만 원본 폴더는 옛 코드다(%s). 사유를 해소한 뒤 `git -C %s merge --ff-only %s` 또는 push 재실행. 미커밋은 지우지 말라." % (ff, main, sha[:10]))
                warnings.extend(mode_warnings(wt, before, sha))
                res = {"ok": True, "rc": 0, "remote": R, "branch": D, "sha": sha, "ff": ff, "live_applied": live, "attempts": attempt,
                       "warnings": warnings}
                if adopt_report:
                    res["adopt"] = adopt_report
                if linked:
                    br = git(["symbolic-ref", "--short", "-q", "HEAD"], cwd=wt)[1]
                    try:
                        release_claims(cd, br)
                    except OSError:
                        pass
                log_line(sid, "git_push.log", "push ok remote=%s branch=%s sha=%s ff=%s" % (R, D, sha[:10], ff))
                return res, 0
            last_err = "push 거절/실패: " + e[:200]
            time.sleep(2 * attempt)
    finally:
        fcntl.flock(lk, fcntl.LOCK_UN)
        lk.close()
    log_line(sid, "git_push.log", "push fail " + last_err)
    return {"ok": False, "rc": RC_PUSHFAIL, "error": last_err or "시간 초과", "warnings": warnings}, RC_PUSHFAIL


def rescue_before_abort(wt):
    """rebase --abort 는 작업 트리를 되돌려 도중에 같은 폴더에 쓰인 변경을 지운다. 지우기 전에 <git dir>/harness-rescue 에 복사한다."""
    gd = git(["rev-parse", "--absolute-git-dir"], cwd=wt)[1]
    if not gd or not (os.path.isdir(os.path.join(gd, "rebase-merge")) or os.path.isdir(os.path.join(gd, "rebase-apply"))):
        return None
    d = os.path.join(gd, "harness-rescue", time.strftime("%Y%m%d-%H%M%S"))
    files = {}
    for xy, rel in status_entries(wt):
        src = os.path.join(wt, rel)
        if xy[1] != "M" or xy[0] == "U" or not os.path.isfile(src):
            continue
        try:
            import shutil
            os.makedirs(os.path.dirname(os.path.join(d, rel)), exist_ok=True)
            shutil.copy2(src, os.path.join(d, rel))
            files[rel] = xy
        except OSError:
            pass
    return {"dir": d, "files": files}


def restore_after_abort(wt, saved):
    """abort 뒤, 색인에 올라가지 않았던(작업 트리 전용) 변경만 되돌려 놓는다. 그 외는 구조 폴더에 남긴다."""
    done = []
    for rel, xy in ((saved or {}).get("files") or {}).items():
        if xy[0] != " ":
            continue
        try:
            import shutil
            shutil.copy2(os.path.join(saved["dir"], rel), os.path.join(wt, rel))
            done.append(rel)
        except OSError:
            pass
    return done


# ───────────────────────── adopt (원본의 기존 변경을 세션 worktree 로 옮김) ─────────────────────────

def adopt_path(sid):
    return os.path.join(session_dir(sid), "adopt.json")


def git_bytes(args, cwd):
    try:
        p = subprocess.run(["git", "-c", "core.quotePath=false"] + list(args), cwd=cwd, env=git_env(), capture_output=True,
                           timeout=GIT_TIMEOUT)
        return p.returncode, p.stdout
    except (subprocess.SubprocessError, OSError):
        return 127, b""


def adopt(sid, paths, repo=None):
    """지정한 경로만 원본에서 세션 worktree 로 복사한다(원본 무변경, 일괄 처리 금지)."""
    sid = sid_of(sid) or sid_of(os.environ.get("PIPELINE_UUID"))
    if not sid:
        return {"ok": False, "rc": RC_DIRTY, "error": "--sid <세션 UUID> 필수"}, RC_DIRTY
    if not paths:
        return {"ok": False, "rc": RC_DIRTY, "error": "--paths 로 옮길 경로를 명시해야 한다(경로 없는 일괄 처리 금지)"}, RC_DIRTY
    if repo:
        cd0 = common_dir(repo)
        wt = session_worktree(sid, cd0) if cd0 else None
    else:
        rec = session_record(sid)
        alive = [v["worktree"] for v in rec.values() if isinstance(v, dict) and v.get("worktree") and is_real_worktree(v["worktree"])]
        wt = alive[0] if len(alive) == 1 else None
    if not wt:
        return {"ok": False, "rc": RC_DIRTY, "error": "세션 worktree 를 찾지 못했다 — `wt_lib.py ensure --repo <원본> --sid <UUID>` 후 재실행하라"}, RC_DIRTY
    main = main_checkout(wt)
    copied, deleted, skipped = [], [], {}
    ents = {}
    for p in paths:
        ap = os.path.realpath(p if os.path.isabs(p) else os.path.join(main, p))
        rel = os.path.relpath(ap, os.path.realpath(main)).replace(os.sep, "/")
        if rel.startswith("..") or rel == ".":
            skipped[p] = "원본 저장소 밖"
            continue
        if os.path.isdir(ap):
            skipped[p] = "디렉터리는 불가 — 파일 경로를 하나씩 지정하라"
            continue
        if git(["check-ignore", "-q", "--", rel], cwd=main)[0] == 0:
            skipped[p] = "ignored 파일"
            continue
        if git(["status", "--porcelain", "--", rel], cwd=wt)[1]:
            skipped[p] = "worktree 에 이미 변경이 있음"
            continue
        dst = os.path.join(wt, rel)
        if os.path.isfile(ap):
            import shutil
            if os.path.realpath(dst) == ap:
                skipped[p] = "worktree 쪽 경로가 원본과 같은 파일(상위 symlink) — 건너뜀"
                continue
            try:
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                shutil.copy2(ap, dst)
            except (shutil.SameFileError, OSError) as e:
                skipped[p] = "복사 실패: %s" % e
                continue
            copied.append(rel)
            ents[rel] = "copy"
        elif git(["ls-files", "--error-unmatch", "--", rel], cwd=main)[0] == 0:
            pd = os.path.realpath(os.path.dirname(dst))
            if pd != os.path.realpath(wt) and not pd.startswith(os.path.realpath(wt) + os.sep):
                skipped[p] = "worktree 쪽 상위 경로가 worktree 밖을 가리킴(symlink) — 건너뜀"
                continue
            if os.path.lexists(dst):
                os.unlink(dst)
            deleted.append(rel)
            ents[rel] = "deleted"
        else:
            skipped[p] = "원본에 없음"
    if ents:
        data = read_json(adopt_path(sid), {})
        if not isinstance(data, dict):
            data = {}
        data.setdefault(os.path.realpath(main), {}).update(ents)
        try:
            write_json(adopt_path(sid), data)
        except OSError:
            pass
    return {"ok": True, "rc": 0, "worktree": wt, "copied": copied, "deleted": deleted, "skipped": skipped,
            "note": "worktree 에서 커밋 후 push 하면, 원본 내용이 push 된 내용과 같은 경로만 원본에서 되돌리고 ff 한다"}, 0


def adopt_scan(main, sha, ents):
    """채택 목록을 원본 현재 상태와 대조: rel → {kind, same(원본 == push 내용), tracked, blob}."""
    rows = {}
    for rel, kind in ents.items():
        pf = os.path.join(main, rel)
        rc, blob = git_bytes(["show", "%s:%s" % (sha, rel)], main)
        tracked = git(["ls-files", "--error-unmatch", "--", rel], cwd=main)[0] == 0
        if kind == "deleted":
            same = rc != 0 and not os.path.lexists(pf)
        else:
            try:
                with open(pf, "rb") as f:
                    same = rc == 0 and f.read() == blob
            except OSError:
                same = False
        rows[rel] = {"kind": kind, "same": same, "tracked": tracked, "blob": blob if rc == 0 else None}
    return rows


def ff_blockers(main, branch_d, permit, allowed):
    """원본 ff 사전조건. 막는 사유(문자열) 또는 None. allowed: 되돌릴 예정인 채택 경로 집합."""
    rc, cur, _ = git(["symbolic-ref", "--short", "-q", "HEAD"], cwd=main)
    if rc != 0 or cur != branch_d:
        return "원본이 %s 브랜치가 아님" % branch_d
    changed = set()
    parts = git_bytes(["status", "--porcelain", "-z", "--untracked-files=no"], main)[1].decode("utf-8", "replace").split("\0")
    i = 0
    while i < len(parts):
        ent = parts[i]
        i += 1
        if len(ent) < 4:
            continue
        changed.add(ent[3:])
        if ent[0] in "RC" or ent[1] in "RC":  # rename/copy: 다음 항목이 원래 경로
            if i < len(parts) and parts[i]:
                changed.add(parts[i])
            i += 1
    other = sorted(changed - set(allowed))
    if other:
        return "채택 대상 외 추적 변경이 있음(%s)" % ", ".join(other[:3])
    if infra_fields(main).get("git_live_apply", "").lower() == "gated" and not permit:
        return "gated — 적용허가 없음"
    return None


def adopt_and_ff(sid, main, wt, branch_d, sha, permit):
    """push 성공 후 채택 파일 처리 + 원본 ff. (report, ff|None). ff 가 확실할 때만 되돌리고, 실패하면 push 된 내용으로 복원한다."""
    if not sid or not main:
        return {}, None
    data = read_json(adopt_path(sid), {})
    key = os.path.realpath(main)
    ents = data.get(key) if isinstance(data, dict) else None
    if not ents:
        return {}, None
    rows = adopt_scan(main, sha, ents)
    report = {}
    mism = [r for r, v in rows.items() if not v["same"]]
    blk = "원본 내용이 push 내용과 다른 채택 파일이 있음" if mism else ff_blockers(main, branch_d, permit, set(rows))
    ff = "skipped(%s)" % blk if blk else None
    if blk is None:
        reverted = []
        for rel, v in rows.items():
            pf = os.path.join(main, rel)
            if v["kind"] == "deleted" or v["tracked"]:
                ok = git(["checkout", "--", rel], cwd=main)[0] == 0
            else:
                try:
                    os.unlink(pf)
                    ok = True
                except OSError:
                    ok = False
            report[rel] = "reverted" if ok else "revert-failed"
            if ok:
                reverted.append(rel)
        ff = ff_main(main, wt, branch_d, sha, permit)
        if ff != "ff":
            for rel in reverted:  # ff 실패 → push 된 내용으로 원본을 다시 써서 새 판을 유지한다
                v = rows[rel]
                pf = os.path.join(main, rel)
                try:
                    if v["kind"] == "deleted":
                        if os.path.lexists(pf):
                            os.unlink(pf)
                    elif v["blob"] is not None:
                        os.makedirs(os.path.dirname(pf), exist_ok=True)
                        with open(pf, "wb") as f:
                            f.write(v["blob"])
                    report[rel] = "restored(ff 실패 — 원본을 push 내용으로 유지)"
                except OSError:
                    report[rel] = "restore-failed"
        else:
            for rel in reverted:
                ents.pop(rel, None)
    else:
        for rel, v in rows.items():
            if v["same"]:
                report[rel] = "kept(ff 불가: %s — 원본 내용 = push 내용)" % blk
            elif git(["diff", "--quiet", "HEAD", "--", rel], cwd=main)[0] == 0 and v["tracked"]:
                report[rel] = "cleared(원본에 남은 변경 없음)"
                ents.pop(rel, None)
            else:
                report[rel] = "mismatch(원본 내용이 push 된 내용과 다름 — 건드리지 않음)"
    data[key] = ents
    try:
        write_json(adopt_path(sid), data)
    except OSError:
        pass
    return report, ff


# ───────────────────────── doctor ─────────────────────────

def doctor(repo):
    main = main_checkout(repo)
    issues, info = [], {}
    if not main:
        return {"ok": False, "issues": ["git 저장소가 아니다"]}
    info["main_root"] = main
    cl = os.path.join(main, ".claude")
    if os.path.islink(cl):
        issues.append(".claude 가 symlink — 정책 비적용")
    elif not os.path.isdir(cl):
        issues.append(".claude 디렉터리 없음 — 정책 비적용")
    if not has_commit(main):
        issues.append("커밋이 없음 — 정책 비적용")
    cd = common_dir(main)
    try:
        with open(os.path.join(cd, "info", "exclude"), encoding="utf-8") as f:
            info["exclude_registered"] = any(ln.strip().rstrip("/").endswith(".claude/worktrees") for ln in f.read().splitlines())
    except OSError:
        info["exclude_registered"] = False
    c = canonical(main)
    info["canonical"] = c
    if not c.get("remote"):
        issues.append("정본 원격 판정 불가: %s" % (c.get("error") or "원격 없음"))
    rc, hp, _ = git(["config", "--get", "core.hooksPath"], cwd=main)
    info["hooksPath"] = hp if rc == 0 else None
    info["policy"] = policy_applies(main)
    fm = git(["config", "--get", "core.fileMode"], cwd=main)[1].lower()
    info["fileMode"] = fm or "default"
    if fm == "false":
        info["fileMode_note"] = "core.fileMode=false: 실행 비트 변경이 커밋에 잡히지 않는다. 새 실행 파일은 git update-index --chmod=+x 가 필요하다"
    return {"ok": not issues, "issues": issues, "info": info}


def audit(repo):
    """읽기 전용 점검: 잔류 worktree 의 미커밋·미반영 커밋, 껍데기 폴더, 폴더만 사라진 등록, ignored 링크 누락."""
    main = main_checkout(repo)
    if not main:
        return {"ok": False, "error": "git 저장소가 아니다"}
    ref = default_ref(main)
    wts, regs = [], registered_worktrees(main)
    missing_dir = []
    for w in regs[1:]:
        p = w["path"]
        if not os.path.isdir(p):
            missing_dir.append(p)
            continue
        loss = wt_loss(p, ref)
        behind = git(["rev-list", "--count", "HEAD..%s" % ref], cwd=p)[1] if ref else None
        lock_alive = None
        m = re.search(r"pid (\d+)", w["locked"] or "")
        if m:
            lock_alive = os.path.exists("/proc/" + m.group(1))
        miss = [i for i in LINK_ITEMS if os.path.lexists(os.path.join(main, i)) and not os.path.lexists(os.path.join(p, i))
                and git(["ls-files", "--error-unmatch", "--", i], cwd=main)[0] != 0]
        wts.append(dict(loss, path=p, branch=w["branch"], locked=w["locked"], lock_alive=lock_alive, behind=int(behind) if behind and behind.isdigit() else None,
                        missing_links=miss))
    shells = []
    root = os.path.join(main, ".claude", "worktrees")
    known = [os.path.realpath(w["path"]) for w in regs]
    try:
        for n in sorted(os.listdir(root)):
            p = os.path.join(root, n)
            rp = os.path.realpath(p)
            if os.path.isdir(p) and rp not in known and not any(k.startswith(rp + os.sep) for k in known):
                shells.append({"path": p, "files": sum(len(fs) for _, _, fs in os.walk(p))})
    except OSError:
        pass
    return {"ok": True, "ref": ref, "worktrees": wts, "shells": shells, "missing_dirs": missing_dir}


# ───────────────────────── guard (경고 전용) ─────────────────────────

WRITE_TOOLS = ("file_write", "file_edit", "file_delete", "file_rename", "file_move", "file_symlink",
               "dir_create", "dir_delete", "dir_move", "dir_rename", "file_copy")
BUILTIN_WRITE = ("Edit", "Write", "NotebookEdit", "MultiEdit")
WRAPPERS = {"env", "command", "nohup", "sudo", "time", "exec", "setsid", "builtin", "nice", "timeout"}
KEYWORDS = {"if", "then", "else", "elif", "do", "while", "until", "!", "{", "}", "fi", "done", "for", "case", "esac"}
HARMLESS_HEADS = {"echo", "printf", "grep", "rg", "cat", "ls", "find", "which", "type", "man", "head", "tail", "sed",
                  "awk", "less", "wc", "test", "[", "diff", "cut", "sort", "tr", "xargs-n"}
GIT_WRITE = {"commit", "add", "rm", "mv", "reset", "checkout", "switch", "restore", "clean", "stash", "merge",
             "rebase", "cherry-pick", "revert", "am", "apply", "update-ref", "pull"}


def _split_newlines(cmd):
    """따옴표 밖 줄바꿈을 ';' 로 바꾼다."""
    out, q, i = [], None, 0
    while i < len(cmd):
        ch = cmd[i]
        if q:
            if ch == "\\" and q == '"' and i + 1 < len(cmd):
                out.append(ch + cmd[i + 1])
                i += 2
                continue
            if ch == q:
                q = None
        elif ch in ("'", '"'):
            q = ch
        elif ch == "\\" and i + 1 < len(cmd):
            out.append(ch + cmd[i + 1])
            i += 2
            continue
        elif ch == "#" and (i == 0 or cmd[i - 1] in " \t\n;&|("):
            # 단어 시작의 '#' 은 줄 끝까지 주석 — 개행은 남겨 다음 명령을 보존한다
            while i < len(cmd) and cmd[i] != "\n":
                i += 1
            continue
        elif ch == "\n":
            ch = " ; "
        out.append(ch)
        i += 1
    return "".join(out)


def tokenize(cmd):
    lex = shlex.shlex(_split_newlines(cmd), posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    lex.commenters = ""
    return list(lex)


def _is_op(t):
    return bool(t) and set(t) <= set(";&|()<>")


def _segments(tokens):
    seg = []
    for t in tokens:
        if _is_op(t):
            if seg:
                yield seg
            seg = []
            continue
        seg.append(t)
    if seg:
        yield seg


def _join(base, d):
    d = os.path.expanduser(d)
    return os.path.normpath(d if os.path.isabs(d) else os.path.join(base, d))


def parse_git(seg, cur):
    """git 세그먼트 → (sub, args, eff_dir) 또는 None."""
    toks = list(seg)
    if not toks or os.path.basename(toks[0]) != "git":
        return None
    eff, i, n = cur, 1, len(toks)
    while i < n and toks[i].startswith("-"):
        t = toks[i]
        if t == "-C" and i + 1 < n:
            eff = _join(eff, toks[i + 1])
            i += 2
        elif t == "-c" and i + 1 < n:
            i += 2
        elif t.startswith("--work-tree="):
            eff = _join(eff, t.split("=", 1)[1])
            i += 1
        elif t == "--work-tree" and i + 1 < n:
            eff = _join(eff, toks[i + 1])
            i += 2
        elif t in ("--git-dir", "--namespace", "--exec-path") and i + 1 < n:
            i += 2
        else:
            i += 1
    if i >= n:
        return None
    return toks[i], toks[i + 1:], eff


def push_strength(args, canon_remote):
    """push 인자의 위험 요소 목록(강제·+refspec·mirror·delete·비정본)."""
    risky, pos = [], []
    for a in args:
        if a in ("--force", "--force-with-lease", "--force-if-includes") or a.startswith("--force-with-lease=") or \
                (a.startswith("-") and not a.startswith("--") and "f" in a[1:]):
            risky.append("강제 push")
        elif a == "--mirror":
            risky.append("--mirror")
        elif a in ("--delete", "-d"):
            risky.append("--delete")
        elif a.startswith("-"):
            continue
        else:
            pos.append(a)
    for a in pos[1:]:
        if a.startswith("+"):
            risky.append("+refspec 강제")
        elif a.startswith(":"):
            risky.append("원격 ref 삭제")
    if pos and canon_remote and pos[0] != canon_remote and not pos[0].startswith(("+", ":")):
        risky.append("비정본 원격(%s) — 미러는 서버가 담당" % pos[0])
    return risky


def role_warnings(sid, repo_main, path_abs, tool, rel):
    """role_lib.check_path 와 같은 경고 문구. 판정 경로는 원본 checkout 기준으로 정규화한다."""
    try:
        sys.path.insert(0, HERE)
        import role_lib as R
    except Exception:
        return None
    try:
        if not sid or not R.UUID_RE.match(sid):
            return None
        value = R.current_role(sid)
        rid, _ = R.split_value(value)
        if rid == "all":
            return None
        root = R.find_root(os.path.dirname(path_abs)) or (repo_main if repo_main and os.path.isfile(
            os.path.join(repo_main, ".claude", "role_paths.json")) else None)
        if not root:
            return None
        ap = path_abs
        if rel and repo_main and os.path.realpath(root) == os.path.realpath(repo_main):
            ap = os.path.join(repo_main, rel)
        res = R.check_path(value, root, ap)
        if not res.startswith("WARN"):
            return None
        owner = res[4:].strip()
        rel = R.rel_to_root(root, ap) or ap  # live role_scope_warn 과 같은 방식: role_paths.json 루트 기준 상대경로
        R.log_line(sid, "role_scope_warn.log", "WARN role=%s tool=%s path=%s owner=%s" % (value, tool, rel, owner))
        return ("⚠️ [롤 범위 밖] 내 롤 %s 의 담당 경로가 아니다: %s(%s 담당). 롤 밖 수정이면 직접 하지 말고 Skill('orole') 인계 절차로 넘기거나, "
                "사용자가 롤 밖 수행을 원하면 `/orole all` 로 바꾸도록 안내하라. (경고만 — 차단 아님)" % (value, rel, owner))
    except Exception:
        return None


def _strs(ti, keys):
    return [ti[k].strip() for k in keys if isinstance(ti.get(k), str) and ti[k].strip()]


def write_paths(tool, ti):
    """쓰기 대상 경로 목록(읽기 원천은 제외). oio 스키마 별칭을 모두 받는다."""
    bt = tool.split("__")[-1]
    dsts = ("destination", "dest", "dst", "to", "target_path", "new_path")
    if bt == "file_copy":
        return _strs(ti, dsts)  # path/source/src 는 읽기 원천
    if bt == "file_move":
        return _strs(ti, ("path", "source", "src", "from") + dsts)
    if bt == "file_symlink":
        return _strs(ti, ("link_path", "link", "path") + dsts)  # target 은 링크가 가리키는 곳(읽기)
    paths = _strs(ti, ("path", "file_path", "filepath", "notebook_path") + dsts + ("target",))
    if bt in ("file_rename", "dir_rename"):
        base = (_strs(ti, ("path", "file_path", "filepath")) or [""])[0]
        nn = ti.get("new_name")
        if base and isinstance(nn, str) and nn:
            paths.append(os.path.join(os.path.dirname(base), nn))
    return paths


def guard_write(sid, cwd, tool, ti, warns):
    cands = []
    main_of_cwd = main_checkout(cwd) if cwd else None
    for p in write_paths(tool, ti):
        if os.path.isabs(p):
            cands.append(os.path.normpath(p))
        else:
            cands.append(os.path.normpath(os.path.join(cwd, p)))
            # oio 는 서버 cwd(원본) 기준으로 상대경로를 풀 수 있다 — 보수적으로 원본 기준도 본다
            if main_of_cwd and os.path.realpath(main_of_cwd) != os.path.realpath(cwd):
                cands.append(os.path.normpath(os.path.join(main_of_cwd, p)))
    seen = set()
    cwd_common = common_dir(cwd) if cwd else None
    for ap in cands:
        if ap in seen:
            continue
        seen.add(ap)
        bt = tool.split("__")[-1]
        if bt in ("dir_delete", "dir_move", "dir_rename"):
            wt_delete_warn(ap, warns)
        ghost = ghost_worktree(ap)
        if ghost and bt != "dir_delete":
            warns.append("⛔ [wt 껍데기 폴더] %s 는 등록된 worktree 가 아니다(자동 삭제된 팀원 폴더 등). 여기 쓴 파일은 어느 커밋에도 들어가지 않고, 이 폴더의 git 명령은 원본에 적용된다. "
                         "`git worktree list` 로 실제 폴더를 확인하고 그 경로로 쓰라(경고만 — 차단 아님)." % ghost)
            continue
        c = classify(ap, sid, cwd)
        if not c["repo_common"] or not c["policy"]:
            # 정책 비적용(비 git·git_worktree: off 포함)이어도 롤 경고는 수행한다
            rw = role_warnings(sid, c.get("main_root"), ap, tool, c.get("rel"))
            if rw:
                warns.append(rw)
            continue
        if c["worktree_root"] and not c["in_main"]:
            branch = git(["symbolic-ref", "--short", "-q", "HEAD"], cwd=c["worktree_root"])[1]
            if sid and cwd and not _NO_RECORD and is_linked(cwd):
                note_worktree(sid, cwd)
            if c["rel"] and not c["ignored"] and branch:
                others = claim(c["repo_common"], c["rel"], branch, os.path.basename(c["worktree_root"]), c["worktree_root"])
                if others:
                    o = others[0]
                    warns.append("⚠️ [wt 선점] %s 는 다른 worktree(브랜치 %s, 세션 %s)가 먼저 수정 중이다. 겹치면 [작업시작] 회신 규칙으로 조율하라(경고만)."
                                 % (c["rel"], o.get("branch"), o.get("name")))
        if c["in_main"] and not c["ignored"] and c["rel"] is not None:
            same_repo = bool(cwd_common) and os.path.realpath(cwd_common) == os.path.realpath(c["repo_common"])
            wtp = session_worktree(sid, c["repo_common"])
            if wtp:
                warns.append("⚠️ [wt 원본 쓰기] 원본 폴더의 추적 파일 %s 를 직접 쓰고 있다. 이 세션 worktree 의 `%s` 를 대신 쓰라(경고만 — 차단 아님)."
                             % (c["rel"], os.path.join(wtp, c["rel"])))
            elif same_repo:
                warns.append("⚠️ [wt 원본 쓰기] 원본 폴더의 추적 파일 %s 를 직접 쓰고 있다. EnterWorktree(name=<세션명>) 후 `<worktree>/%s` 로 쓰라. "
                             "팀원은 프롬프트의 [WT_INJECT] 경로를 쓰라(경고만 — 차단 아님)." % (c["rel"], c["rel"]))
            else:
                warns.append("⚠️ [wt 다른 저장소] %s 는 다른 저장소의 원본 추적 파일이다. `python3 <hooks>/lib/wt_lib.py ensure --repo %s` 로 worktree 를 만든 뒤 "
                             "그 경로로 쓰라(경고만 — 차단 아님)." % (c["rel"], c["main_root"]))
        rw = role_warnings(sid, c["main_root"], ap, tool, c["rel"])
        if rw:
            warns.append(rw)


def judge_git(sub, args, eff, sid, warns, unverified=False):
    if "$" in eff or "`" in eff:
        warns.append("⚠️ [wt 파싱 불확실] git 의 작업 폴더가 변수·치환(%s)이라 해석하지 못했다 — 원본에서 실행되는지 직접 확인하라(경고만)." % eff)
        return
    c = classify(eff, sid, eff)
    if not c["repo_common"] or not c["policy"]:
        return
    in_main = c["in_main"]
    linked = bool(c["worktree_root"]) and not in_main
    own = session_record(sid).get(os.path.realpath(c["repo_common"]), {}) if sid else {}
    if sub == "push":
        cr = canonical_remote(c["main_root"]).get("remote")
        risky = push_strength(args, cr)
        if risky:
            warns.append("⛔ [wt push 위험] git push 에 %s 가 있다. 강제·미러·삭제·비정본 push 는 하지 말라. 정본 원격(%s)으로는 "
                         "`python3 <hooks>/lib/wt_lib.py push` 단일 경로만 쓴다(경고만 — 차단 아님)." % (", ".join(sorted(set(risky))), cr))
        else:
            warns.append("⚠️ [wt push] 직접 git push 대신 `python3 <hooks>/lib/wt_lib.py push` 를 쓰라(잠금+fetch+rebase+ff push+재시도, 경고만).")
        return
    if sub == "stash":
        if args and args[0] in ("list", "show"):
            return
        warns.append("⚠️ [wt stash] refs/stash 는 모든 worktree 가 공유한다 — pop 이 남의 stash 를 꺼낼 수 있다. 임시 보관은 커밋(WIP)으로 하라(경고만).")
        return
    if sub == "worktree" and args:
        op = args[0]
        if op in ("remove", "prune"):
            tgt = [a for a in args[1:] if not a.startswith("-")]
            if op == "remove" and tgt and any(a in ("-f", "--force") for a in args[1:]):
                wt_delete_warn(_join(eff, tgt[0]), warns)  # 자기 worktree 라도 --force 는 미커밋을 지운다
            mine = own.get("worktree")
            if op == "prune" or not mine or not tgt or os.path.realpath(_join(eff, tgt[0])) != os.path.realpath(mine):
                warns.append("⚠️ [wt 남의 worktree] `git worktree %s` 가 이 세션 소유가 아닌 worktree 를 지울 수 있다. 자기 worktree 만 정리하라(경고만)." % op)
        return
    if sub == "branch":
        flags = [a for a in args if a.startswith("-")]
        if any(f in ("-d", "-D", "-f", "--delete", "--force", "-m", "-M") for f in flags):
            names = [a for a in args if not a.startswith("-")]
            mine = own.get("branch", "")
            if any(n.startswith("worktree-") and n != mine for n in names):
                warns.append("⚠️ [wt 남의 브랜치] worktree-* 브랜치를 이 세션 것이 아닌데 삭제·변경하려 한다(경고만).")
            elif in_main:
                warns.append("⚠️ [wt 원본 git 쓰기] 원본 폴더에서 git branch 변경을 한다. worktree 에서 하라(경고만).")
        return
    if sub in GIT_WRITE:
        if in_main:
            warns.append("⚠️ [wt 원본 git 쓰기] 원본 폴더에서 `git %s` 를 실행한다. 원본은 읽기용 기준 사본이다 — 자기 worktree 에서 하라(경고만 — 차단 아님)." % sub)
        elif linked:
            if unverified:
                warns.append("⚠️ [wt 실행 위치 미확인] `git %s` 의 입력 cwd 는 worktree 지만 working_dir 가 없다. 주입(AC-010 미실측)이 적용되지 않으면 "
                             "원본 폴더에서 실행된다 — pwd 로 확인하고 working_dir 를 직접 명시하라(경고만)." % sub)
            danger = (sub == "reset" and "--hard" in args) or \
                     (sub == "clean" and any(a.startswith("-") and not a.startswith("--") and "f" in a for a in args)) or \
                     (sub == "checkout" and "--" in args and "." in args) or \
                     (sub == "add" and any(a in ("-A", "--all", ".", "-u", "--update") for a in args)) or \
                     (sub == "commit" and any(a == "-a" or (a.startswith("-") and not a.startswith("--") and "a" in a[1:]) for a in args))
            if danger:
                warns.append("⚠️ [wt 일괄 변경] 자기 worktree 의 `git %s` 는 이 worktree 의 변경만 영향을 준다. 의도한 범위인지 확인하라(허용, 경고만)." % sub)


def strip_prefix(s):
    """변수 대입·구문 키워드·래퍼(timeout/nice/sudo/env 등)와 그 옵션을 걷어낸 세그먼트."""
    s = list(s)
    while s:
        h = os.path.basename(s[0])
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", s[0]) or h in KEYWORDS:
            s = s[1:]
        elif h in WRAPPERS:
            s = s[1:]
            valued = {"timeout": ("-k", "-s", "--kill-after", "--signal"), "nice": ("-n", "--adjustment"),
                      "sudo": ("-u", "-g", "-h", "-p", "-C", "-U", "-r", "-t", "-D"), "env": ("-u", "-C", "-S")}.get(h, ())
            while s and s[0].startswith("-") and len(s[0]) > 1:
                s = s[2:] if s[0] in valued else s[1:]
            if h == "timeout" and s:
                s = s[1:]  # 시간 값
            while h == "env" and s and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", s[0]):
                s = s[1:]
        else:
            break
    return s


def analyze_command(cmd, base_dir, sid, warns, depth=0, unverified=False):
    try:
        toks = tokenize(cmd)
    except ValueError:
        if re.search(r"\bgit\b", cmd or ""):
            warns.append("⚠️ [wt 명령 파싱 실패] git 명령을 해석하지 못해 판정하지 못했다(경고만, 과차단 방지).")
        return
    cur = base_dir
    for seg in _segments(toks):
        s = strip_prefix(seg)
        if not s:
            continue
        head = os.path.basename(s[0])
        if head == "cd" and len(s) > 1:
            cur = _join(cur, s[1])
            continue
        if head == "rm" and any(a == "--recursive" or re.match(r"^-[A-Za-z]*[rR]", a) for a in s[1:]):
            for t in s[1:]:
                if not t.startswith("-") and "$" not in t and "`" not in t:
                    wt_delete_warn(_join(cur, t), warns)
            continue
        if head in ("bash", "sh", "dash", "zsh") and depth < 3:
            flags = [i for i, a in enumerate(s[1:], 1) if re.match(r"^-[A-Za-z]*c$", a)]  # fullmatch-scan: ok — 탐지·수집 쪽은 match 유지가 더 엄격(D-5)
            if flags and flags[0] + 1 < len(s):
                analyze_command(s[flags[0] + 1], cur, sid, warns, depth + 1, unverified)
                continue
        g = parse_git(s, cur)
        if g:
            judge_git(g[0], g[1], g[2], sid, warns, unverified)
        elif head not in HARMLESS_HEADS and "git" in s[1:]:
            warns.append("⚠️ [wt 파싱 불확실] `%s` 뒤의 git 호출을 해석하지 못했다 — 원본·강제 push 여부를 직접 확인하라(경고만)." % head)


_NO_RECORD = False


def note_worktree(sid, cwd):
    """메인 세션 cwd 를 기록하고, 처음 보는 worktree 면 ignored 링크(INFRA.md 등)를 만든다. 공식 EnterWorktree 는 ensure 를 거치지 않는다."""
    top = toplevel(cwd)
    first = session_worktree(sid, common_dir(cwd)) != os.path.realpath(top or "")
    record_worktree(sid, top)
    if first:
        link_worktree(top)


def guard(stdin_text):
    """hook JSON → 출력할 사전 또는 None. 어떤 경우에도 permissionDecision 을 내지 않는다."""
    try:
        d = json.loads(stdin_text)
    except ValueError:
        return None
    if not isinstance(d, dict):
        return None
    tool = str(d.get("tool_name") or "")
    ti = d.get("tool_input") or {}
    if not isinstance(ti, dict):
        return None
    cwd = d.get("cwd") or os.getcwd()
    sid = sid_of(os.environ.get("PIPELINE_UUID")) or sid_of(str(d.get("session_id") or ""))
    global _CACHE_SID, _NO_RECORD
    _CACHE_SID = sid
    # in-process 서브에이전트는 session_id 가 메인과 같고, PIPELINE_UUID 보유 팀원은 sid 가 메인이다.
    # 이들의 cwd 를 기록하면 저장소당 1칸인 메인 기록을 덮어써 다음 spawn 의 WT_INJECT 가 다른 팀원 폴더를 주입한다.
    _NO_RECORD = bool(d.get("agent_id")) or bool(sid_of(os.environ.get("PIPELINE_UUID")))
    warns = []
    out = {"hookEventName": "PreToolUse"}
    base_tool = tool.split("__")[-1]
    if tool in BUILTIN_WRITE or base_tool in WRITE_TOOLS:
        guard_write(sid, cwd, tool, ti, warns)
    elif tool == "Bash" or base_tool == "bash_exec":
        cmd = next((ti[k] for k in ("command", "cmd") if isinstance(ti.get(k), str)), None)
        if isinstance(cmd, str) and cmd.strip():
            c0 = classify(cwd, sid, cwd) if cwd else {}
            wd = next((ti[k] for k in ("working_dir", "workdir", "cwd") if isinstance(ti.get(k), str) and ti[k]), None)
            if sid and cwd and not _NO_RECORD and c0.get("policy") and is_linked(cwd):
                note_worktree(sid, cwd)
            inject = None
            if base_tool == "bash_exec" and not wd and c0.get("policy"):
                # 메인: 입력 cwd 가 linked worktree 일 때 / 팀원(PIPELINE_UUID): 파이프라인 기록이 있을 때
                is_team = bool(sid_of(os.environ.get("PIPELINE_UUID")))
                if c0.get("worktree_root") and os.path.isdir(c0["worktree_root"]) and (is_linked(cwd) or is_team):
                    inject = c0["worktree_root"]
            # 판정 기준 폴더는 주입 여부와 무관하게 명시 working_dir > 입력 cwd (주입이 안 먹어도 원본 git 쓰기 경고가 남게)
            base = wd if isinstance(wd, str) and wd else cwd
            unverified = not wd and bool(cwd) and is_linked(cwd)
            analyze_command(cmd, os.path.abspath(base), sid, warns, 0, unverified)
            if inject:
                ni = dict(ti)
                ni["working_dir"] = inject
                out["updatedInput"] = ni
                # MCP 도구에 updatedInput 이 적용되는지 미실측(AC-010) — 경고를 함께 내 유일한 강제 수단을 유지한다
                warns.append("ℹ️ [wt 작업 폴더 주입] working_dir 를 worktree(%s)로 주입을 시도했다. 주입이 적용되지 않으면 명령이 원본 폴더에서 "
                             "실행된다 — 실제 실행 위치(pwd)를 확인하고 필요하면 working_dir 를 직접 명시하라(경고만 — 차단 아님)." % inject)
    if not warns and "updatedInput" not in out:
        return None
    if warns:
        uniq = list(dict.fromkeys(warns))
        out["additionalContext"] = "\n".join(uniq)
        log_line(sid, "wt_guard.log", "WARN tool=%s %s" % (tool, uniq[0][:120].replace("\n", " ")))
    return {"hookSpecificOutput": out}


# ───────────────────────── CLI ─────────────────────────

def main(argv=None):
    ap = argparse.ArgumentParser(prog="wt_lib.py")
    sp = ap.add_subparsers(dest="cmd", required=True)
    p = sp.add_parser("classify"); p.add_argument("--path", required=True); p.add_argument("--sid", default=""); p.add_argument("--cwd", default=None)
    sp.add_parser("guard")
    p = sp.add_parser("ensure"); p.add_argument("--repo", required=True); p.add_argument("--name", default=None); p.add_argument("--sid", default="")
    p = sp.add_parser("link"); p.add_argument("--worktree", required=True)
    p = sp.add_parser("canonical"); p.add_argument("--repo", required=True)
    p = sp.add_parser("push"); p.add_argument("--repo", default=None); p.add_argument("--sid", default=""); p.add_argument("--apply-permit", action="store_true")
    p = sp.add_parser("claim"); p.add_argument("--repo", required=True); p.add_argument("--rel", required=True); p.add_argument("--branch", required=True); p.add_argument("--name", default="")
    p = sp.add_parser("claim-check"); p.add_argument("--rel", required=True); p.add_argument("--repo", default=None); p.add_argument("--branch", default="")
    p = sp.add_parser("adopt"); p.add_argument("--sid", default=""); p.add_argument("--repo", default=None); p.add_argument("--paths", nargs="+", default=[])
    p = sp.add_parser("doctor"); p.add_argument("--repo", required=True)
    p = sp.add_parser("audit"); p.add_argument("--repo", required=True)
    a = ap.parse_args(argv)

    def emit(o):
        print(json.dumps(o, ensure_ascii=False))

    if a.cmd == "classify":
        emit(classify(a.path, sid_of(a.sid) or sid_of(os.environ.get("PIPELINE_UUID")), a.cwd)); return 0
    if a.cmd == "guard":
        try:
            r = guard(sys.stdin.read())
        except Exception:
            r = None
        if r:
            emit(r)
        return 0
    if a.cmd == "ensure":
        r = ensure(a.repo, a.name, a.sid); emit(r); return r.get("rc", 0)
    if a.cmd == "link":
        emit({"linked": link_worktree(a.worktree)}); return 0
    if a.cmd == "canonical":
        c = canonical(a.repo); emit(c); return 0 if c.get("remote") else RC_NOREMOTE
    if a.cmd == "push":
        r, rc = push(a.repo, a.sid, a.apply_permit or os.environ.get("WT_APPLY_PERMIT") == "1"); emit(r); return rc
    if a.cmd in ("claim", "claim-check"):
        cd = common_dir(a.repo or os.getcwd())
        if not cd:
            emit({"error": "저장소 아님"}); return 1
        if a.cmd == "claim":
            emit({"others": claim(cd, a.rel, a.branch, a.name, toplevel(a.repo) or a.repo)})
        else:
            emit({"others": claim_check(cd, a.rel, a.branch)})
        return 0
    if a.cmd == "adopt":
        r, rc = adopt(a.sid, a.paths, a.repo); emit(r); return rc
    if a.cmd == "audit":
        r = audit(a.repo); emit(r); return 0 if r.get("ok") else 1
    if a.cmd == "doctor":
        r = doctor(a.repo); emit(r); return 0 if r.get("ok") else 1
    return 1


if __name__ == "__main__":
    sys.exit(main())
