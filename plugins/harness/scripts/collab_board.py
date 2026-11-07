#!/usr/bin/env python3
# 머신 간·세션 간·팀원 간 3층 협업의 작업 점유 장부(claim/release/list/pack/ingest)와 배정 범위 점검(scope-check/assign-lint)
#
# 사용법:
#   collab_board.py claim <프로젝트> --owner O --tier machine|session|team --path P [--path P2] [--task S] [--ttl 7200]
#   collab_board.py release <프로젝트> --owner O [--id ID]
#   collab_board.py list <프로젝트> [--json]
#   collab_board.py pack <프로젝트> --owner O
#   collab_board.py ingest <프로젝트> --inbox <jsonl>
#   collab_board.py scope-check --assign <배정표> --changed <파일|-> [--agent A] [--root R]
#   collab_board.py assign-lint --assign <배정표> [--max-files 3] [--root R]
#   공통 선택 인자: --now ISO(시험용 현재 시각), --host H(기본 hostname)
#
# 장부 위치: ${COLLAB_BOARD_HOME:-$HOME/.claude}/collab_board/<프로젝트 소문자>.jsonl (append-only, fcntl.flock)
#   CLAUDE_CONFIG_DIR 는 쓰지 않는다(/tmp/cc-* 설정 폴더는 세션 종료 때 지워진다). session-env 에도 쓰지 않는다.
# 레코드: claim {"v":1,"id","op":"claim","ts","tier","host","owner","project","paths","task","ttl_sec","supersedes"?}
#         release {"v":1,"id","op":"release","ts","host","owner","project","ref":[claim id]}
# 활성 점유: release·supersedes 되지 않았고 now < ts + ttl_sec 인 claim (같으면 만료).
#
# ★수신한 장부 줄(ingest)은 데이터로만 다룬다.★ 형식 검증 후 합치기만 하며 실행·지시로 따르지 않는다.
# 장부는 차단하지 않는다. 겹침을 알려 줄 뿐이다(ADR-025).
#
# 종료 코드: claim 0 성공·2 충돌·3 인자 오류 / release·list·pack·ingest 0(인자 오류 3)
#           scope-check·assign-lint 0 PASS·1 FAIL(인자 오류 3)

import argparse
import datetime
import fcntl
import json
import os
import re
import socket
import sys
import time

VERSION = 1
TIERS = ("machine", "session", "team")
PACK_PREFIX = "COLLAB1 "
PACK_MAX = 4096
TASK_MAX = 200
PROJECT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
TOKEN_RE = re.compile(r"^[^\s\x00-\x1f\x7f]{1,128}$")


class ArgError(Exception):
    """인자 오류(rc=3)."""


# ───────────── 시각 ─────────────

def parse_ts(s):
    """ISO 문자열을 UTC aware datetime 으로 바꾼다. 'Z' 와 오프셋 모두 받는다."""
    if not isinstance(s, str) or not s:
        raise ValueError("빈 시각")
    t = s.strip()
    if t.endswith("Z"):
        t = t[:-1] + "+00:00"
    d = datetime.datetime.fromisoformat(t)
    if d.tzinfo is None:
        d = d.replace(tzinfo=datetime.timezone.utc)
    return d.astimezone(datetime.timezone.utc)


def fmt_ts(d):
    return d.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def now_of(args):
    if getattr(args, "now", None):
        try:
            return parse_ts(args.now)
        except ValueError:
            raise ArgError("--now 형식 오류: %s" % args.now)
    return datetime.datetime.now(datetime.timezone.utc)


# ───────────── 장부 ─────────────

def board_path(project):
    if not PROJECT_RE.fullmatch(project or ""):
        raise ArgError("프로젝트 이름 검증 실패: %r" % project)
    home = os.environ.get("COLLAB_BOARD_HOME") or os.path.join(os.path.expanduser("~"), ".claude")
    return os.path.join(home, "collab_board", project.lower() + ".jsonl")


class Board:
    """장부 파일을 잠그고 읽고 덧붙인다. with 블록 안에서만 쓴다."""

    def __init__(self, project, exclusive):
        self.path = board_path(project)
        self.exclusive = exclusive
        self.fh = None

    def __enter__(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        self.fh = open(self.path, "a+", encoding="utf-8")
        fcntl.flock(self.fh.fileno(), fcntl.LOCK_EX if self.exclusive else fcntl.LOCK_SH)
        return self

    def __exit__(self, *exc):
        try:
            fcntl.flock(self.fh.fileno(), fcntl.LOCK_UN)
        finally:
            self.fh.close()

    def records(self):
        self.fh.seek(0)
        out = []
        for line in self.fh.read().splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
            except ValueError:
                continue  # 깨진 줄은 건너뛴다(append-only 라 다른 줄은 온전하다)
            if isinstance(o, dict):
                out.append(o)
        return out

    def append(self, recs):
        self.fh.seek(0, os.SEEK_END)
        for r in recs:
            self.fh.write(json.dumps(r, ensure_ascii=False, sort_keys=True) + "\n")
        self.fh.flush()
        os.fsync(self.fh.fileno())


def expires_at(rec):
    return parse_ts(rec["ts"]) + datetime.timedelta(seconds=int(rec["ttl_sec"]))


def active_claims(records, now):
    """release·supersedes 를 반영한 활성 claim 목록(기록 순서 유지)."""
    dead = set()
    for r in records:
        if r.get("op") == "release":
            dead.update(x for x in r.get("ref", []) if isinstance(x, str))
        elif r.get("op") == "claim":
            dead.update(x for x in r.get("supersedes", []) if isinstance(x, str))
    out = []
    for r in records:
        if r.get("op") != "claim" or r.get("id") in dead:
            continue
        try:
            if now < expires_at(r):
                out.append(r)
        except (KeyError, ValueError, TypeError):
            continue
    return out


def new_id(host, owner):
    return "%s:%s:%d" % (host, owner, time.time_ns())


# ───────────── 경로 ─────────────

def check_rel_path(p):
    """장부 경로 검증: 빈 값·절대경로·'..' 금지. 정규화한 상대경로를 돌려준다."""
    if not isinstance(p, str) or not p.strip():
        raise ArgError("빈 경로")
    p = p.strip().replace("\\", "/")
    if p.startswith("/") or re.match(r"^[A-Za-z]:", p):
        raise ArgError("절대경로 금지: %s" % p)
    parts = [x for x in p.split("/") if x not in ("", ".")]
    if not parts or ".." in parts:
        raise ArgError("'..' 또는 빈 경로 금지: %s" % p)
    return "/".join(parts)


def overlaps(a, b):
    """같은 경로이거나 한쪽이 다른 쪽의 상위 디렉터리면 겹친다."""
    return a == b or a.startswith(b + "/") or b.startswith(a + "/")


# ───────────── claim / release / list / pack / ingest ─────────────

def cmd_claim(args):
    if not TOKEN_RE.fullmatch(args.owner or ""):
        raise ArgError("--owner 검증 실패")
    if args.tier not in TIERS:
        raise ArgError("--tier 는 %s 중 하나" % "|".join(TIERS))
    if not args.path:
        raise ArgError("--path 가 하나 이상 필요")
    if args.ttl <= 0:
        raise ArgError("--ttl 은 양수")
    paths = sorted(set(check_rel_path(p) for p in args.path))
    task = (args.task or "")[:TASK_MAX]
    now = now_of(args)
    host = args.host or socket.gethostname()
    with Board(args.project, exclusive=True) as b:
        act = active_claims(b.records(), now)
        conflicts = []
        mine = []
        for r in act:
            if r.get("owner") == args.owner and r.get("host") == host:
                mine.append(r)
                continue
            for p in paths:
                for q in r.get("paths", []):
                    if overlaps(p, q):
                        conflicts.append((p, r))
        if conflicts:
            for p, r in conflicts:
                print("CONFLICT %s %s %s %s" % (p, r.get("owner"), r.get("host"), fmt_ts(expires_at(r))))
            return 2
        rec = {"v": VERSION, "id": new_id(host, args.owner), "op": "claim", "ts": fmt_ts(now),
               "tier": args.tier, "host": host, "owner": args.owner, "project": args.project,
               "paths": paths, "task": task, "ttl_sec": int(args.ttl)}
        # 같은 owner 재점유는 갱신: 경로가 겹치는 기존 점유를 대체한다
        sup = [r["id"] for r in mine if any(overlaps(p, q) for p in paths for q in r.get("paths", []))]
        if sup:
            rec["supersedes"] = sup
        b.append([rec])
    print("CLAIMED %s%s" % (rec["id"], " (갱신 %d건)" % len(sup) if sup else ""))
    return 0


def cmd_release(args):
    if not TOKEN_RE.fullmatch(args.owner or ""):
        raise ArgError("--owner 검증 실패")
    now = now_of(args)
    host = args.host or socket.gethostname()
    with Board(args.project, exclusive=True) as b:
        act = [r for r in active_claims(b.records(), now)
               if r.get("owner") == args.owner and r.get("host") == host
               and (not args.id or r.get("id") == args.id)]
        if not act:
            print("NOTHING")
            return 0
        rec = {"v": VERSION, "id": new_id(host, args.owner), "op": "release", "ts": fmt_ts(now),
               "host": host, "owner": args.owner, "project": args.project,
               "ref": [r["id"] for r in act]}
        b.append([rec])
    print("RELEASED %d" % len(act))
    return 0


def cmd_list(args):
    now = now_of(args)
    with Board(args.project, exclusive=False) as b:
        act = active_claims(b.records(), now)
    if args.json:
        print(json.dumps(act, ensure_ascii=False))
        return 0
    if not act:
        print("EMPTY")
        return 0
    for r in act:
        print("\t".join([r.get("id", ""), r.get("tier", ""), r.get("owner", ""), r.get("host", ""),
                         fmt_ts(expires_at(r)), ",".join(r.get("paths", [])), r.get("task", "")]))
    return 0


def pack_lines(project, claims):
    """claim 목록을 COLLAB1 줄로 만든다. 한 줄이 PACK_MAX 바이트를 넘지 않게 나눈다."""
    lines, cur = [], []

    def render(items):
        return PACK_PREFIX + json.dumps({"v": VERSION, "project": project, "claims": items},
                                        ensure_ascii=False, sort_keys=True, separators=(",", ":"))

    for c in claims:
        trial = render(cur + [c])
        if cur and len(trial.encode("utf-8")) > PACK_MAX:
            lines.append(render(cur))
            cur = [c]
        else:
            cur.append(c)
    if cur:
        lines.append(render(cur))
    return lines


def cmd_pack(args):
    if not TOKEN_RE.fullmatch(args.owner or ""):
        raise ArgError("--owner 검증 실패")
    now = now_of(args)
    host = args.host or socket.gethostname()
    with Board(args.project, exclusive=False) as b:
        act = [r for r in active_claims(b.records(), now)
               if r.get("owner") == args.owner and r.get("host") == host]
    for line in pack_lines(args.project, act):
        print(line)
    return 0


def valid_claim(c, project):
    """ingest 스키마 검증. 통과하면 정규화한 claim, 아니면 None."""
    if not isinstance(c, dict) or c.get("v") != VERSION or c.get("op") != "claim":
        return None
    for k in ("id", "host", "owner", "project", "ts"):
        if not isinstance(c.get(k), str) or not TOKEN_RE.fullmatch(c[k]):
            return None
    if c["project"].lower() != project.lower() or c.get("tier") not in TIERS:
        return None
    ttl = c.get("ttl_sec")
    if not isinstance(ttl, int) or isinstance(ttl, bool) or ttl <= 0:
        return None
    try:
        parse_ts(c["ts"])
        paths = sorted(set(check_rel_path(p) for p in c.get("paths") or []))
    except (ValueError, ArgError):
        return None
    if not paths:
        return None
    task = c.get("task", "")
    if not isinstance(task, str):
        return None
    return {"v": VERSION, "id": c["id"], "op": "claim", "ts": c["ts"], "tier": c["tier"],
            "host": c["host"], "owner": c["owner"], "project": c["project"], "paths": paths,
            "task": task[:TASK_MAX], "ttl_sec": ttl, "via": "ingest"}


def cmd_ingest(args):
    board_path(args.project)  # 프로젝트 검증
    try:
        with open(args.inbox, encoding="utf-8", errors="replace") as f:
            raw = f.read().splitlines()
    except OSError as e:
        raise ArgError("inbox 읽기 실패: %s" % e)
    cands, skipped = [], 0
    for line in raw:
        line = line.strip()
        if not line:
            continue
        try:
            o = json.loads(line)
        except ValueError:
            skipped += 1
            continue
        body = o.get("body") if isinstance(o, dict) else None
        if not isinstance(body, str):
            skipped += 1
            continue
        hit = False
        for bl in body.splitlines():
            if not bl.startswith(PACK_PREFIX):
                continue
            hit = True
            try:
                pk = json.loads(bl[len(PACK_PREFIX):])
            except ValueError:
                skipped += 1
                continue
            if not isinstance(pk, dict) or pk.get("v") != VERSION or not isinstance(pk.get("claims"), list):
                skipped += 1
                continue
            for c in pk["claims"]:
                v = valid_claim(c, args.project)
                if v is None:
                    skipped += 1
                else:
                    cands.append(v)
        if not hit:
            skipped += 1
    added = 0
    with Board(args.project, exclusive=True) as b:
        seen = set(r.get("id") for r in b.records())
        new = []
        for c in cands:
            if c["id"] in seen:
                continue
            seen.add(c["id"])
            new.append(c)
        if new:
            b.append(new)
        added = len(new)
    print("INGESTED %d" % added)
    print("SKIPPED %d" % skipped)
    return 0


# ───────────── 배정표 ─────────────

def load_assign(path):
    """배정표 3형식을 [(배치키, {에이전트: [파일...]})] 로 읽는다. 실패하면 ValueError."""
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        raise ValueError("배정표 파싱 실패: %s" % e)
    if not isinstance(data, dict):
        raise ValueError("배정표 최상위가 객체가 아니다")

    def agents_of(d):
        out = {}
        for name, v in d.items():
            if isinstance(v, dict) and "files" in v:
                fl = v["files"]
                if not isinstance(fl, list):
                    raise ValueError("%s.files 가 목록이 아니다" % name)
                files = []
                for x in fl:
                    if isinstance(x, dict):
                        x = x.get("path")
                    if not isinstance(x, str):
                        raise ValueError("%s.files 에 문자열이 아닌 항목" % name)
                    files.append(x)
                out[name] = files
        return out

    groups = []
    if isinstance(data.get("batches"), list):
        for i, bt in enumerate(data["batches"]):
            fa = bt.get("file_assignment") if isinstance(bt, dict) else None
            if isinstance(fa, dict):
                inner = fa.get("agents") if isinstance(fa.get("agents"), dict) else fa
                groups.append(("batch%s" % (bt.get("batch", i + 1)), agents_of(inner)))
    elif isinstance(data.get("agents"), dict):
        groups.append(("main", agents_of(data["agents"])))
    else:
        groups.append(("main", agents_of(data)))
    if not any(g for _, g in groups):
        raise ValueError("배정표에 에이전트가 없다")
    return data, groups


def resolve_root(args, data):
    if getattr(args, "root", None):
        return os.path.abspath(args.root)
    wt = data.get("worktree") if isinstance(data, dict) else None
    if isinstance(wt, str) and wt.startswith("/"):
        return os.path.abspath(wt)
    return os.getcwd()


def norm_file(p, root):
    """배정·변경 경로를 root 기준 상대경로로 정규화. (정규화값, 디렉터리 표기 여부)."""
    s = p.strip().replace("\\", "/")
    is_dir = s.endswith("/")
    full = s if s.startswith("/") else os.path.join(root, s)
    full = os.path.normpath(full)
    if os.path.isdir(full):
        is_dir = True
    rel = os.path.relpath(full, root)
    if rel.startswith(".."):
        rel = full  # root 밖은 절대경로 그대로 둔다(배정과 맞을 일이 없다)
    return rel, is_dir


def owner_map(groups, root):
    m, dirs = {}, []
    for _, g in groups:
        for agent, files in g.items():
            for f in files:
                rel, is_dir = norm_file(f, root)
                if is_dir:
                    dirs.append((agent, f))
                m.setdefault(rel, set()).add(agent)
    return m, dirs


def cmd_scope_check(args):
    fails = []
    try:
        data, groups = load_assign(args.assign)
    except ValueError as e:
        print("FAIL %s" % e)
        return 1
    root = resolve_root(args, data)
    try:
        if args.changed == "-":
            raw = sys.stdin.read().splitlines()
        else:
            with open(args.changed, encoding="utf-8") as f:
                raw = f.read().splitlines()
    except OSError as e:
        print("FAIL 변경 목록 읽기 실패: %s" % e)
        return 1
    changed = [x.strip() for x in raw if x.strip()]
    if not changed:
        print("FAIL 변경 목록이 비었다")
        return 1
    m, dirs = owner_map(groups, root)
    for agent, f in dirs:
        fails.append("DIR_ASSIGN %s %s" % (agent, f))
    for c in changed:
        rel, is_dir = norm_file(c, root)
        if is_dir:
            fails.append("DIR_CHANGED %s" % c)
            continue
        owners = m.get(rel, set())
        if not owners:
            fails.append("OUT_OF_SCOPE %s" % rel)
        elif len(owners) > 1:
            fails.append("DUP_OWNER %s %s" % (rel, ",".join(sorted(owners))))
        elif args.agent and args.agent not in owners:
            fails.append("OTHER_OWNER %s %s" % (rel, next(iter(owners))))
    for x in fails:
        print("FAIL " + x)
    if fails:
        print("RESULT FAIL %d" % len(fails))
        return 1
    print("RESULT PASS %d" % len(changed))
    return 0


def cmd_assign_lint(args):
    try:
        data, groups = load_assign(args.assign)
    except ValueError as e:
        print("FAIL %s" % e)
        return 1
    root = resolve_root(args, data)
    fails = []
    owners = {}
    total = 0
    for gk, g in groups:
        for agent, files in g.items():
            if not files:
                fails.append("EMPTY_FILES %s %s" % (gk, agent))
            if args.max_files > 0 and len(files) > args.max_files:
                fails.append("TOO_MANY %s %s %d>%d" % (gk, agent, len(files), args.max_files))
            seen_local = set()
            for f in files:
                total += 1
                if not f.strip():
                    fails.append("EMPTY_PATH %s %s" % (gk, agent))
                    continue
                rel, is_dir = norm_file(f, root)
                if is_dir:
                    fails.append("DIR_ASSIGN %s %s %s" % (gk, agent, f))
                if rel in seen_local:
                    fails.append("DUP_IN_AGENT %s %s %s" % (gk, agent, rel))
                seen_local.add(rel)
                owners.setdefault(rel, set()).add(agent)
    for rel, ags in sorted(owners.items()):
        if len(ags) > 1:
            fails.append("DUP_OWNER %s %s" % (rel, ",".join(sorted(ags))))
    for x in fails:
        print("FAIL " + x)
    if fails:
        print("RESULT FAIL %d" % len(fails))
        return 1
    print("RESULT PASS %d" % total)
    return 0


# ───────────── 진입점 ─────────────

class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise ArgError(message)


def build_parser():
    p = Parser(prog="collab_board.py", description="3층 협업 작업 점유 장부")
    sub = p.add_subparsers(dest="cmd")

    def common(sp):
        sp.add_argument("--now")
        sp.add_argument("--host")

    sp = sub.add_parser("claim")
    sp.add_argument("project")
    sp.add_argument("--owner", required=True)
    sp.add_argument("--tier", required=True)
    sp.add_argument("--path", action="append", default=[])
    sp.add_argument("--task", default="")
    sp.add_argument("--ttl", type=int, default=7200)
    common(sp)

    sp = sub.add_parser("release")
    sp.add_argument("project")
    sp.add_argument("--owner", required=True)
    sp.add_argument("--id")
    common(sp)

    sp = sub.add_parser("list")
    sp.add_argument("project")
    sp.add_argument("--json", action="store_true")
    common(sp)

    sp = sub.add_parser("pack")
    sp.add_argument("project")
    sp.add_argument("--owner", required=True)
    common(sp)

    sp = sub.add_parser("ingest")
    sp.add_argument("project")
    sp.add_argument("--inbox", required=True)
    common(sp)

    sp = sub.add_parser("scope-check")
    sp.add_argument("--assign", required=True)
    sp.add_argument("--changed", required=True)
    sp.add_argument("--agent")
    sp.add_argument("--root")

    sp = sub.add_parser("assign-lint")
    sp.add_argument("--assign", required=True)
    sp.add_argument("--max-files", type=int, default=3)
    sp.add_argument("--root")
    return p


CMDS = {"claim": cmd_claim, "release": cmd_release, "list": cmd_list, "pack": cmd_pack,
        "ingest": cmd_ingest, "scope-check": cmd_scope_check, "assign-lint": cmd_assign_lint}


def main(argv=None):
    try:
        args = build_parser().parse_args(argv)
        if not args.cmd:
            raise ArgError("하위 명령이 필요하다: " + "|".join(CMDS))
        return CMDS[args.cmd](args)
    except ArgError as e:
        sys.stderr.write("collab_board: %s\n" % e)
        return 3


if __name__ == "__main__":
    sys.exit(main())
