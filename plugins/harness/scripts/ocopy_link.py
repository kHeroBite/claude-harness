#!/usr/bin/env python3
# 새 프로젝트 폴더에 AI 루트의 공용 파일·폴더를 절대경로 심볼릭링크로 연결하는 ocopy 실행기
"""ocopy_link.py <이름|절대경로> [--ai-root P] [--projects-root P] [--dry-run]

출력 형식:
  줄마다 `<코드> <대상 경로> -> <링크 값>` 1줄을 낸다. 코드는 LINK_OK·SKIP_EXISTS·SKIP_NOSRC·MKDIR·ERR 이다.
  마지막 줄은 JSON 요약이다. 키는 ai_root·target·dry_run·counts·rc 이다.
종료코드: 0 성공(ERR 없음) / 1 ERR 1건 이상 / 2 인자·해석 실패

규칙:
  - 링크 값은 해석된 AI 루트의 절대경로다. 상대경로 링크는 만들지 않는다.
  - 이미 있는 파일·폴더·링크는 덮어쓰지 않는다(SKIP_EXISTS).
  - 원본이 없으면 건너뛴다(SKIP_NOSRC).
  - 대상이 AI 루트 자신이거나 그 안이면 거부한다(ERR).
"""
import argparse
import json
import os
import subprocess
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))

# (대상 상대경로, 원본 상대경로) — 원본은 AI 루트 기준이다
_LINKS = [
    ("CLAUDE.md", "CLAUDE.md"),
    ("AGENTS.md", "CLAUDE.md"),
    (".mcp.json", ".mcp.json"),
    (".claude/settings.json", ".claude/settings.json"),
    (".claude/settings.local.json", ".claude/settings.local.json"),
    (".claude/commands", ".claude/commands"),
    (".claude/skills", ".claude/skills"),
]


def _ai_root_module():
    """같은 폴더의 harness_ai_root 모듈을 불러온다. 없으면 None 이다."""
    if _HERE not in sys.path:
        sys.path.insert(0, _HERE)
    try:
        import harness_ai_root  # noqa: WPS433
        return harness_ai_root
    except Exception:
        return None


def _cli(sub, extra):
    """harness_ai_root.py CLI 를 실행해 stdout 첫 줄을 돌려준다. 실패하면 None 이다."""
    script = os.path.join(_HERE, "harness_ai_root.py")
    if not os.path.isfile(script):
        return None
    try:
        out = subprocess.run(
            [sys.executable, "-B", script, sub] + extra,
            capture_output=True, text=True, timeout=30,
        )
    except Exception:
        return None
    if out.returncode != 0:
        return None
    line = (out.stdout or "").strip().splitlines()
    return line[0].strip() if line else None


def _call_module(name, *args):
    """harness_ai_root 모듈 함수를 위치 인자로 호출한다. 없거나 실패하면 None 이다."""
    mod = _ai_root_module()
    fn = getattr(mod, name, None) if mod is not None else None
    if callable(fn):
        try:
            val = fn(*args)
        except Exception:
            return None
        return str(val) if val else None
    return None


def resolve_ai_root(explicit):
    """AI 루트를 정한다. 인자 > harness_ai_root 모듈 > harness_ai_root.py CLI 순서다."""
    if explicit:
        return os.path.abspath(os.path.expanduser(explicit))
    val = _call_module("resolve", None)
    if not val:
        val = _cli("resolve", [])
    return os.path.abspath(val) if val else None


def resolve_projects_root(explicit, ai_root):
    """프로젝트 루트를 정한다. 인자 > 모듈 > CLI > AI 루트의 부모 순서다."""
    if explicit:
        return os.path.abspath(os.path.expanduser(explicit))
    val = _call_module("projects_root", None, ai_root)
    if not val:
        extra = ["--ai-root", ai_root] if ai_root else []
        val = _cli("projects-root", extra)
    if not val and ai_root:
        val = os.path.dirname(ai_root.rstrip("/"))
    return os.path.abspath(val) if val else None


def resolve_target(arg, projects_root):
    """인자를 대상 절대경로로 바꾼다. 이름이면 프로젝트 루트 아래에서 찾는다."""
    if arg.startswith("/") or arg.startswith("~"):
        return os.path.abspath(os.path.expanduser(arg))
    if "/" in arg or arg in (".", ".."):
        return None
    exact = os.path.join(projects_root, arg)
    if os.path.exists(exact):
        return exact
    # 정확히 일치하는 폴더가 없으면 대소문자 무시로 1건만 찾는다
    try:
        hits = [n for n in os.listdir(projects_root)
                if n.lower() == arg.lower() and os.path.isdir(os.path.join(projects_root, n))]
    except OSError:
        hits = []
    if len(hits) == 1:
        return os.path.join(projects_root, hits[0])
    return exact


def _hooks_source(ai_root):
    """hooks 링크 값을 정한다. ${HARNESS_HOME:-$HOME/.harness}/current/hooks 가 있으면 그것, 없으면 AI 루트의 hooks 다."""
    home_hooks = os.path.join(os.path.expanduser("~"), ".claude", "hooks")
    if os.path.lexists(home_hooks):
        return home_hooks
    return os.path.join(ai_root, ".claude", "hooks")


def _inside(path, root):
    path = os.path.realpath(path)
    root = os.path.realpath(root)
    return path == root or path.startswith(root.rstrip("/") + "/")


def run(target, ai_root, dry_run):
    """링크를 만든다. (출력 줄 목록, counts) 를 돌려준다."""
    lines = []
    counts = {"LINK_OK": 0, "SKIP_EXISTS": 0, "SKIP_NOSRC": 0, "MKDIR": 0, "ERR": 0}

    def emit(code, dst, src=""):
        counts[code] += 1
        suffix = " (dry-run)" if dry_run and code in ("LINK_OK", "MKDIR") else ""
        lines.append(f"{code} {dst}" + (f" -> {src}" if src else "") + suffix)

    if _inside(target, ai_root):
        emit("ERR", target, "대상이 AI 루트 자신이거나 그 안이다")
        return lines, counts

    for d in (target, os.path.join(target, ".claude")):
        if not os.path.isdir(d):
            if os.path.lexists(d):
                emit("ERR", d, "폴더 자리에 파일이 있다")
                return lines, counts
            if not dry_run:
                try:
                    os.makedirs(d, exist_ok=True)
                except OSError as exc:
                    emit("ERR", d, f"폴더 생성 실패: {exc.strerror}")
                    return lines, counts
            emit("MKDIR", d)

    pairs = [(rel, os.path.join(ai_root, src)) for rel, src in _LINKS]
    pairs.append((".claude/hooks", _hooks_source(ai_root)))

    for rel, src in pairs:
        dst = os.path.join(target, rel)
        if os.path.lexists(dst):
            emit("SKIP_EXISTS", dst, os.readlink(dst) if os.path.islink(dst) else "")
            continue
        if not os.path.exists(src):
            emit("SKIP_NOSRC", dst, src)
            continue
        if not dry_run:
            try:
                os.symlink(src, dst)
            except OSError as exc:
                emit("ERR", dst, f"{src} ({exc.strerror})")
                continue
        emit("LINK_OK", dst, src)

    locks = os.path.join(target, ".claude", "locks")
    if not os.path.isdir(locks):
        if os.path.lexists(locks):
            emit("SKIP_EXISTS", locks)
        else:
            if not dry_run:
                try:
                    os.makedirs(locks, exist_ok=True)
                except OSError as exc:
                    emit("ERR", locks, f"폴더 생성 실패: {exc.strerror}")
                    return lines, counts
            emit("MKDIR", locks)
    return lines, counts


def main(argv=None):
    ap = argparse.ArgumentParser(description="AI 루트 공용 파일을 새 프로젝트에 심볼릭링크로 연결한다")
    ap.add_argument("project", help="프로젝트 이름(프로젝트 루트 아래) 또는 절대경로")
    ap.add_argument("--ai-root", default=None, help="AI 루트 절대경로(생략하면 harness_ai_root 로 해석)")
    ap.add_argument("--projects-root", default=None, help="프로젝트 루트(생략하면 harness_ai_root 로 해석)")
    ap.add_argument("--dry-run", action="store_true", help="아무것도 만들지 않고 계획만 출력")
    args = ap.parse_args(argv)

    summary = {"ai_root": None, "target": None, "dry_run": args.dry_run, "counts": {}, "rc": 2}

    ai_root = resolve_ai_root(args.ai_root)
    if not ai_root or not os.path.isfile(os.path.join(ai_root, "CLAUDE.md")):
        print(f"ERR AI 루트를 해석하지 못했다: {ai_root or '(없음)'}")
        print(json.dumps(summary, ensure_ascii=False))
        return 2
    summary["ai_root"] = ai_root

    projects_root = resolve_projects_root(args.projects_root, ai_root)
    target = resolve_target(args.project, projects_root or "")
    if not target or not os.path.isabs(target):
        print(f"ERR 대상 경로를 해석하지 못했다: {args.project}")
        print(json.dumps(summary, ensure_ascii=False))
        return 2
    summary["target"] = target

    lines, counts = run(target, ai_root, args.dry_run)
    for ln in lines:
        print(ln)
    rc = 1 if counts["ERR"] else 0
    summary["counts"] = counts
    summary["rc"] = rc
    print(json.dumps(summary, ensure_ascii=False))
    return rc


if __name__ == "__main__":
    sys.exit(main())
