#!/usr/bin/env python3
# 하네스 AI 루트(<프로젝트홈>/AI) 해석·facade 생성·프로젝트 루트 해석을 맡는 모듈 겸 CLI
"""AI 루트 모듈.

하위 명령
  resolve        [--ai-root P]                       AI 루트 절대경로 1줄 출력(rc=1 이면 해석 불가)
  ensure         --harness-home H --ai-root P [--plugin-active|--no-plugin-active] [--dry-run]
                                                      AI facade 생성·갱신(빈 폴더 또는 표식 있는 폴더만)
  projects-root  [--projects-root P] [--ai-root P]   프로젝트 루트 1줄 출력
  is-canon       --ai-root P                          정본(배포자) 머신이면 rc=0 + CANON, 아니면 rc=1

다른 스크립트(harness_update.py·ocopy_link.py)는 import 해서 resolve()·ensure()·projects_root()·is_canon() 을 쓴다.
자격증명 파일은 열지 않는다. settings.json 은 건드리지 않는다.
"""
import argparse
import datetime as _dt
import json
import os
import sys

MARKER_NAME = ".harness_ai_root.json"
# facade 가 관리하는 .claude 하위 링크 이름(플러그인 트리 안의 같은 이름을 가리킨다)
FACADE_DIRS = ("skills", "hooks", "scripts", "agents")
FACADE_FILES = ("statusline.py",)
# 빈 폴더 판정에서 무시하는 이름(HARNESS_HOME 이 AI 루트 안 .harness 이므로)
IGNORE_FOR_EMPTY = {".harness"}

RC_OK = 0
RC_FAIL = 1
RC_REFUSE = 3


def _home():
    return os.path.expanduser("~")


def config_dir():
    """Claude 설정 폴더(CLAUDE_CONFIG_DIR 우선, 없으면 ~/.claude)."""
    return os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(_home(), ".claude")


def project_home_file():
    """프로젝트홈 기록 파일 경로(~/.config/claude-harness/project_home)."""
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(_home(), ".config")
    return os.path.join(base, "claude-harness", "project_home")


def _read_first_line(path):
    """파일 첫 줄(UTF-8, 끝 공백 제거). 없거나 비면 None."""
    try:
        with open(path, encoding="utf-8") as f:
            line = f.readline()
    except OSError:
        return None
    line = line.rstrip()
    return line or None


def read_project_home():
    """프로젝트홈 기록 파일의 첫 줄을 돌려준다."""
    return _read_first_line(project_home_file())


def _abs(p):
    return os.path.abspath(os.path.expanduser(p))


def resolve(ai_root=None):
    """AI 루트를 정해진 순서로 해석한다. 못 찾으면 None.

    순서: 인자 > HARNESS_AI_ROOT > ${CLAUDE_CONFIG_DIR:-~/.claude}/harness_ai_root → ~/.claude/harness_ai_root
          > project_home 파일 + /AI > realpath(${HARNESS_HOME:-$HOME/.harness}/current/hooks) 가 <X>/.claude/hooks 이고 <X>/CLAUDE.md 존재 시 <X>
    """
    if ai_root:
        return _abs(ai_root)
    env = os.environ.get("HARNESS_AI_ROOT")
    if env:
        return _abs(env)
    candidates = [os.path.join(config_dir(), "harness_ai_root"),
                  os.path.join(_home(), ".claude", "harness_ai_root")]
    seen = set()
    for c in candidates:
        if c in seen:
            continue
        seen.add(c)
        v = _read_first_line(c)
        if v:
            return _abs(v)
    ph = read_project_home()
    if ph:
        return os.path.join(_abs(ph), "AI")
    hooks = os.path.join(_home(), ".claude", "hooks")
    if os.path.exists(hooks):
        real = os.path.realpath(hooks)
        parent = os.path.dirname(real)
        if os.path.basename(real) == "hooks" and os.path.basename(parent) == ".claude":
            x = os.path.dirname(parent)
            if os.path.isfile(os.path.join(x, "CLAUDE.md")):
                return x
    return None


def _infra_projects_root(ai_root):
    """AI 루트 INFRA.md 의 INFRA-FIELDS 블록에서 projects_root 값을 읽는다(값만, 다른 줄은 보지 않음)."""
    path = os.path.join(ai_root, "INFRA.md")
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                s = line.strip()
                if s.startswith("projects_root:"):
                    v = s.split(":", 1)[1].strip().strip('"').strip("'")
                    return v or None
    except OSError:
        return None
    return None


def projects_root(projects_root_arg=None, ai_root=None):
    """프로젝트 루트 해석.

    순서: 인자 > CLAUDE_PROJECT_ROOTS 첫 항목 > project_home 파일 > AI 루트 INFRA.md projects_root > AI 루트의 부모
    """
    if projects_root_arg:
        return _abs(projects_root_arg)
    env = os.environ.get("CLAUDE_PROJECT_ROOTS", "")
    first = env.split(":")[0].strip() if env else ""
    if first:
        return _abs(first)
    ph = read_project_home()
    if ph:
        return _abs(ph)
    root = resolve(ai_root)
    if root:
        v = _infra_projects_root(root)
        if v:
            return _abs(v)
        return os.path.dirname(root.rstrip("/"))
    return None


def has_marker(ai_root):
    return os.path.isfile(os.path.join(ai_root, MARKER_NAME))


def is_canon(ai_root):
    """표식이 없고 .claude/skills 가 실디렉터리면 정본(배포자) 머신이다."""
    if not ai_root or has_marker(ai_root):
        return False
    skills = os.path.join(ai_root, ".claude", "skills")
    return os.path.isdir(skills) and not os.path.islink(skills)


def plugin_active():
    """installed_plugins.json 에 harness 플러그인이 등록돼 있으면 True(키 이름만 본다)."""
    for base in (config_dir(), os.path.join(_home(), ".claude")):
        path = os.path.join(base, "plugins", "installed_plugins.json")
        try:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, ValueError):
            continue
        plugins = data.get("plugins", data) if isinstance(data, dict) else {}
        if isinstance(plugins, dict) and any(k.startswith("harness@") for k in plugins):
            return True
    return False


MARKER_TEXT_HEAD = "# AI (하네스 facade)"


def _is_our_mcp(path, harness_home):
    """facade 가 만든 .mcp.json(oio command 가 이 HARNESS_HOME venv)인지 본다. 사용자 파일은 지우지 않는다."""
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return False
    servers = data.get("mcpServers") if isinstance(data, dict) else None
    if not isinstance(servers, dict) or set(servers) != {"oio"}:
        return False
    cmd = str((servers.get("oio") or {}).get("command", ""))
    return cmd.startswith(os.path.join(_abs(harness_home), "venv"))


def _is_empty_for_facade(ai_root):
    try:
        names = [n for n in os.listdir(ai_root) if n not in IGNORE_FOR_EMPTY]
    except FileNotFoundError:
        return True
    return not names


def _link(path, target, dry_run, out):
    """링크를 만들거나 갱신한다. 실파일·실디렉터리는 건드리지 않는다."""
    if os.path.islink(path):
        if os.readlink(path) == target:
            out.append("FACADE KEEP %s" % path)
            return True
        if not dry_run:
            tmp = "%s.harness_tmp.%d" % (path, os.getpid())
            if os.path.lexists(tmp):
                os.unlink(tmp)
            os.symlink(target, tmp)
            os.replace(tmp, path)
        out.append("FACADE RELINK %s" % path)
        return True
    if os.path.exists(path):
        out.append("FACADE SKIP_REAL %s" % path)
        return False
    if not dry_run:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        os.symlink(target, path)
    out.append("FACADE LINK %s" % path)
    return True


def _write_text(path, text, dry_run, out, tag):
    if os.path.islink(path):
        if not dry_run:
            os.unlink(path)
    elif os.path.exists(path):
        try:
            with open(path, encoding="utf-8") as f:
                if f.read() == text:
                    out.append("FACADE KEEP %s" % path)
                    return
        except OSError:
            pass
    if not dry_run:
        tmp = path + ".harness_tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, path)
    out.append("FACADE %s %s" % (tag, path))


def ensure(harness_home, ai_root, plugin_is_active=None, dry_run=False):
    """AI facade 를 생성·갱신한다. 반환 (rc, 출력 줄 목록).

    - 표식 없음 + .claude/skills 실디렉터리 → REFUSE_REAL_CANON rc=3
    - 표식 없음 + 비지 않은 폴더(.harness 제외) → REFUSE_NOT_EMPTY rc=3
    - 그 외: .claude/<x> → <H>/active/plugins/harness/<x> 링크, CLAUDE.md, 표식 기록
    """
    out = []
    harness_home = _abs(harness_home)
    ai_root = _abs(ai_root)
    if is_canon(ai_root):
        out.append("REFUSE_REAL_CANON %s — 이 머신은 정본(배포자)이다. 배포는 /oUpload 를 쓴다" % ai_root)
        return RC_REFUSE, out
    marker = os.path.join(ai_root, MARKER_NAME)
    if not os.path.isfile(marker) and not _is_empty_for_facade(ai_root):
        out.append("REFUSE_NOT_EMPTY %s — 표식(%s) 없는 비지 않은 폴더는 손대지 않는다" % (ai_root, MARKER_NAME))
        return RC_REFUSE, out
    if plugin_is_active is None:
        plugin_is_active = plugin_active()
    plug = os.path.join(harness_home, "active", "plugins", "harness")
    if not dry_run:
        os.makedirs(os.path.join(ai_root, ".claude"), exist_ok=True)
    for d in FACADE_DIRS:
        _link(os.path.join(ai_root, ".claude", d), os.path.join(plug, d), dry_run, out)
    for fn in FACADE_FILES:
        _link(os.path.join(ai_root, ".claude", fn), os.path.join(plug, fn), dry_run, out)
    # CLAUDE.md: 사용자 rules 에 harness.md 가 이미 적재되면 짧은 표식 파일(이중 적재 방지), 아니면 링크
    rules_md = os.path.join(_home(), ".claude", "rules", "harness.md")
    claude_md = os.path.join(ai_root, "CLAUDE.md")
    if os.path.exists(rules_md) or os.path.exists(os.path.join(config_dir(), "rules", "harness.md")):
        text = (MARKER_TEXT_HEAD + "\n\n"
                "하네스 규칙은 ~/.claude/rules/harness.md 로 이미 적재된다. 이 파일은 이중 적재를 막는 표식이다.\n"
                "갱신은 /oUpdate, 정본(배포자) 머신의 배포는 /oUpload 를 쓴다.\n")
        if os.path.islink(claude_md) or not os.path.exists(claude_md) or has_marker(ai_root):
            _write_text(claude_md, text, dry_run, out, "MARKER")
        else:
            out.append("FACADE SKIP_REAL %s" % claude_md)
    else:
        # 전에 쓴 표식 파일이면(rules 가 사라진 경우) 링크로 되돌린다
        if os.path.isfile(claude_md) and not os.path.islink(claude_md) and has_marker(ai_root):
            try:
                with open(claude_md, encoding="utf-8") as f:
                    ours = f.read().startswith(MARKER_TEXT_HEAD)
            except OSError:
                ours = False
            if ours and not dry_run:
                os.unlink(claude_md)
        _link(claude_md, os.path.join(plug, "rules", "harness.md"), dry_run, out)
    # .mcp.json: 플러그인이 활성이면 만들지 않고, 전에 facade 가 만든 것은 지운다(oio 이중 기동 방지)
    mcp = os.path.join(ai_root, ".mcp.json")
    if plugin_is_active:
        if os.path.lexists(mcp) and has_marker(ai_root) and _is_our_mcp(mcp, harness_home):
            if not dry_run:
                os.unlink(mcp)
            out.append("FACADE REMOVE_MCP %s (plugin-active)" % mcp)
        else:
            out.append("FACADE NO_MCP plugin-active")
    else:
        body = {"mcpServers": {"oio": {
            "command": os.path.join(harness_home, "venv", "oio", "bin", "python"),
            "args": [os.path.join(plug, "mcp-servers", "oio", "server.py")],
            "env": {"CLAUDE_PROJECT_DIR": "${CLAUDE_PROJECT_DIR}"}}}}
        text = json.dumps(body, ensure_ascii=False, indent=2) + "\n"
        if not os.path.exists(mcp) or os.path.isfile(marker):
            _write_text(mcp, text, dry_run, out, "MCP")
        else:
            out.append("FACADE SKIP_REAL %s" % mcp)
    now = _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    prev = {}
    try:
        with open(marker, encoding="utf-8") as f:
            prev = json.load(f)
    except (OSError, ValueError):
        prev = {}
    data = {"schema": 1, "harness_home": harness_home, "ai_root": ai_root,
            "created_at": prev.get("created_at", now), "updated_at": now,
            "managed": [".claude/%s" % d for d in FACADE_DIRS + FACADE_FILES] + ["CLAUDE.md", ".mcp.json"]}
    if not dry_run:
        tmp = marker + ".harness_tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.write("\n")
        os.replace(tmp, marker)
    out.append("ENSURE_OK %s" % ai_root)
    return RC_OK, out


def main(argv=None):
    ap = argparse.ArgumentParser(description="하네스 AI 루트 해석·facade")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("resolve")
    p.add_argument("--ai-root")
    p = sub.add_parser("ensure")
    p.add_argument("--harness-home", required=True)
    p.add_argument("--ai-root", required=True)
    g = p.add_mutually_exclusive_group()
    g.add_argument("--plugin-active", dest="plugin_active", action="store_const", const=True)
    g.add_argument("--no-plugin-active", dest="plugin_active", action="store_const", const=False)
    p.add_argument("--dry-run", action="store_true")
    p = sub.add_parser("projects-root")
    p.add_argument("--projects-root")
    p.add_argument("--ai-root")
    p = sub.add_parser("is-canon")
    p.add_argument("--ai-root")
    a = ap.parse_args(argv)
    if a.cmd == "resolve":
        r = resolve(a.ai_root)
        if not r:
            print("AI_ROOT_UNRESOLVED", file=sys.stderr)
            return RC_FAIL
        print(r)
        return RC_OK
    if a.cmd == "ensure":
        rc, out = ensure(a.harness_home, a.ai_root, a.plugin_active, a.dry_run)
        for line in out:
            print(line)
        return rc
    if a.cmd == "projects-root":
        r = projects_root(a.projects_root, a.ai_root)
        if not r:
            print("PROJECTS_ROOT_UNRESOLVED", file=sys.stderr)
            return RC_FAIL
        print(r)
        return RC_OK
    if a.cmd == "is-canon":
        r = resolve(a.ai_root)
        if r and is_canon(r):
            print("CANON %s" % r)
            return RC_OK
        print("NOT_CANON %s" % (r or "-"))
        return RC_FAIL
    return RC_FAIL


if __name__ == "__main__":
    sys.exit(main())
