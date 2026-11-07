#!/usr/bin/env python3
# 레거시 하네스 레이아웃(HARNESS_HOME/src·current→src/plugins/harness)을 <프로젝트홈>/AI/.harness 로 이전하는 pre 마이그레이션
"""m0001_legacy_layout (phase=pre, 멱등).

인자: --harness-home H --ai-root A [--dry-run] [--undo]

동작(레거시일 때만, 아니면 no-op)
  1. <A>/.harness/src 를 레거시 src 의 origin URL 로 clone(--reference 레거시 src --dissociate)
  2. <A>/.harness/install.json · ~/.config/claude-harness/project_home 기록(없을 때만)
  3. <A>/.harness/venv → 레거시 venv 링크(없을 때만)
  4. rc 표식 블록(# >>> harness PATH … # <<< harness PATH)이 든 ~/.bashrc·~/.profile·~/.bash_profile 를
     파일별로 <파일>.harness-bak.<UTC> 백업 후 HARNESS_HOME·HARNESS_AI_ROOT·CLAUDE_PROJECT_ROOTS 갱신,
     블록 안 레거시 bin 경로 리터럴(<레거시 home>/bin)은 <새 home>/active/bin 으로 교체.
     diff 는 -U0 로 <A>/.harness/logs/m0001_rc.diff 에만 누적한다.
  5. <A>/.harness/update_state.json 에 legacy_src·legacy_home·m0001.rc_backups 기록

출력은 파일별 'RC <파일> backup=<경로> changed_lines=<n> sha256=<12자>' 1줄과 상태 1줄(M0001 OK|SKIP|UNDO)뿐이다.
diff 본문·블록 값은 stdout·stderr 로 내지 않는다. 레거시 폴더(src·current·bin·venv)는 옮기지도 지우지도 않는다.
'# >>> harness project roots' 블록 등 다른 표식 블록은 건드리지 않는다.
"""
import argparse
import datetime as _dt
import difflib
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys

MIGRATION_ID = "m0001_legacy_layout"
SINCE = "1.3.0"
PHASE = "pre"

BLOCK_BEGIN = "# >>> harness PATH"
BLOCK_END = "# <<< harness PATH"
RC_FILES = (".bashrc", ".profile", ".bash_profile")
MANAGED_VARS = ("HARNESS_HOME", "HARNESS_AI_ROOT", "CLAUDE_PROJECT_ROOTS")


def _home():
    return os.path.expanduser("~")


def _utc_stamp():
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def _utc_iso():
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _real(p):
    return os.path.realpath(os.path.abspath(p))


def is_legacy_layout(h):
    """HARNESS_HOME 의 current 가 src/plugins/harness 를 가리키고 src 가 git 저장소면 레거시다."""
    cur = os.path.join(h, "current")
    src = os.path.join(h, "src")
    if not os.path.islink(cur) or not os.path.isdir(os.path.join(src, ".git")):
        return False
    if os.path.lexists(os.path.join(h, "active")):
        return False
    return _real(cur) == _real(os.path.join(src, "plugins", "harness"))


def _git(args, cwd=None):
    return subprocess.run(["git"] + args, cwd=cwd, capture_output=True, text=True, timeout=85)


def _load_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def _save_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp.%d" % os.getpid()
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, path)


def _block_value(line, var):
    """'export VAR="값"' 줄이면 값을 돌려준다."""
    s = line.strip()
    pre = "export %s=" % var
    if not s.startswith(pre):
        return None
    v = s[len(pre):]
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        v = v[1:-1]
    return v


def _swap_bin(line, legacy_bin, new_bin):
    """블록 안 줄의 레거시 BIN 경로 리터럴(<레거시 home>/bin)을 새 active bin 으로 바꾼다(경로 경계 일치만)."""
    if not legacy_bin:
        return line
    return re.sub(re.escape(legacy_bin) + r"(?=[:\"'\s*]|$)", lambda _m: new_bin, line)


def rewrite_block(text, new_values, legacy_bin=None, new_bin=None):
    """표식 블록 안의 관리 변수 줄과 레거시 bin 경로 리터럴만 바꾼 새 본문을 돌려준다. 블록이 없으면 None."""
    lines = text.splitlines(keepends=True)
    begin = end = None
    for i, line in enumerate(lines):
        s = line.rstrip("\r\n")
        if begin is None and s == BLOCK_BEGIN:
            begin = i
        elif begin is not None and s == BLOCK_END:
            end = i
            break
    if begin is None or end is None:
        return None
    body = lines[begin + 1:end]
    old = {}
    kept = []
    for line in body:
        hit = False
        for var in MANAGED_VARS:
            v = _block_value(line, var)
            if v is not None:
                old[var] = v
                hit = True
                break
        if not hit:
            kept.append(_swap_bin(line, legacy_bin, new_bin))
    vals = dict(new_values)
    # CLAUDE_PROJECT_ROOTS 는 기존 루트를 보존하고 프로젝트홈을 맨 앞에 둔다
    roots_old = old.get("CLAUDE_PROJECT_ROOTS", "")
    ph = vals.get("CLAUDE_PROJECT_ROOTS", "")
    parts = [p for p in roots_old.split(":") if p and p != ph]
    vals["CLAUDE_PROJECT_ROOTS"] = ":".join([ph] + parts) if ph else roots_old
    nl = "\r\n" if lines[begin].endswith("\r\n") else "\n"
    managed = ['export %s="%s"%s' % (var, vals[var], nl) for var in MANAGED_VARS if vals.get(var)]
    new_lines = lines[:begin + 1] + managed + kept + lines[end:]
    return "".join(new_lines)


def _rc_paths():
    return [os.path.join(_home(), n) for n in RC_FILES]


def update_rc_files(new_home, ai_root, project_home, dry_run, log_diff, legacy_home=None):
    """rc 파일별 백업·갱신. 반환 (출력 줄, {파일: 백업경로})."""
    out, backups = [], {}
    values = {"HARNESS_HOME": new_home, "HARNESS_AI_ROOT": ai_root, "CLAUDE_PROJECT_ROOTS": project_home}
    legacy_bin = os.path.join(legacy_home, "bin") if legacy_home else None
    new_bin = os.path.join(new_home, "active", "bin")
    stamp = _utc_stamp()
    for path in _rc_paths():
        if not os.path.isfile(path):
            continue
        with open(path, encoding="utf-8", errors="surrogateescape") as f:
            text = f.read()
        new = rewrite_block(text, values, legacy_bin, new_bin)
        if new is None:
            continue  # 표식 블록 없는 파일은 건너뛴다
        sha = hashlib.sha256(new.encode("utf-8", "surrogateescape")).hexdigest()[:12]
        if new == text:
            out.append("RC %s backup=- changed_lines=0 sha256=%s" % (path, sha))
            continue
        diff = list(difflib.unified_diff(text.splitlines(keepends=True), new.splitlines(keepends=True),
                                         fromfile=path + ".harness-bak." + stamp, tofile=path, n=0))
        changed = sum(1 for d in diff if d[:1] in "+-" and not d.startswith(("+++", "---")))
        if dry_run:
            out.append("RC %s backup=(dry-run) changed_lines=%d sha256=%s" % (path, changed, sha))
            continue
        bak = "%s.harness-bak.%s" % (path, stamp)
        shutil.copy2(path, bak)
        st = os.stat(path)
        tmp = path + ".harness_tmp"
        with open(tmp, "w", encoding="utf-8", errors="surrogateescape") as f:
            f.write(new)
        os.chmod(tmp, st.st_mode & 0o7777)
        os.replace(tmp, path)
        os.makedirs(os.path.dirname(log_diff), exist_ok=True)
        with open(log_diff, "a", encoding="utf-8", errors="surrogateescape") as f:
            f.writelines(d if d.endswith("\n") else d + "\n" for d in diff)
        backups[path] = bak
        out.append("RC %s backup=%s changed_lines=%d sha256=%s" % (path, bak, changed, sha))
    return out, backups


def run(h, a, dry_run=False):
    h = os.path.abspath(h)
    a = os.path.abspath(a)
    new_home = os.path.join(a, ".harness")
    if _real(h) == _real(new_home) or not is_legacy_layout(h):
        print("M0001 SKIP 대상 아님")
        return 0
    legacy_src = os.path.join(h, "src")
    project_home = os.path.dirname(a.rstrip("/"))
    if not project_home:
        env = os.environ.get("CLAUDE_PROJECT_ROOTS", "")
        project_home = env.split(":")[0] if env else ""
    url = _git(["-C", legacy_src, "remote", "get-url", "origin"])
    if url.returncode != 0 or not url.stdout.strip():
        print("M0001 FAIL 레거시 src origin 없음", file=sys.stderr)
        return 1
    url = url.stdout.strip()
    new_src = os.path.join(new_home, "src")
    if dry_run:
        out, _ = update_rc_files(new_home, a, project_home, True, "", h)
        for line in out:
            print(line)
        print("M0001 DRY-RUN")
        return 0
    os.makedirs(new_home, exist_ok=True)
    if not os.path.isdir(os.path.join(new_src, ".git")):
        r = _git(["clone", "--quiet", "--reference", legacy_src, "--dissociate", url, new_src])
        if r.returncode != 0:
            print("M0001 FAIL clone rc=%d" % r.returncode, file=sys.stderr)
            return 1
    inst = os.path.join(new_home, "install.json")
    if not os.path.exists(inst):
        _save_json(inst, {"project_home": project_home, "ai_root": a, "installed_at": _utc_iso(),
                          "installer_rev": MIGRATION_ID, "migrated_from": h})
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(_home(), ".config")
    ph_file = os.path.join(base, "claude-harness", "project_home")
    if project_home and not os.path.exists(ph_file):
        os.makedirs(os.path.dirname(ph_file), exist_ok=True)
        with open(ph_file, "w", encoding="utf-8") as f:
            f.write(project_home + "\n")
    legacy_venv = os.path.join(h, "venv")
    new_venv = os.path.join(new_home, "venv")
    if os.path.exists(legacy_venv) and not os.path.lexists(new_venv):
        os.symlink(legacy_venv, new_venv)
    state_path = os.path.join(new_home, "update_state.json")
    state = _load_json(state_path)
    prev_m = state.get("m0001") or {}
    out, backups = update_rc_files(new_home, a, project_home, False,
                                   os.path.join(new_home, "logs", "m0001_rc.diff"), h)
    for line in out:
        print(line)
    merged = dict(prev_m.get("rc_backups") or {})
    for k, v in backups.items():
        merged.setdefault(k, v)  # 최초 백업(이전 직전 원본)을 보존한다
    state["legacy_src"] = legacy_src
    state["legacy_home"] = h
    state["m0001"] = {"rc_backups": merged, "at": prev_m.get("at") or _utc_iso()}
    _save_json(state_path, state)
    # 비로그인 셸용 환경 파일을 새 home 값으로 갱신(출력은 키 이름만)
    try:
        sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.realpath(__file__))))
        import harness_ai_root
        res = harness_ai_root.write_env_file(new_home, a).split()
        print("M0001 %s %s %s" % (res[0], res[1], res[-1]))  # 예: M0001 ENV WRITE keys=HARNESS_HOME,…
    except ImportError:
        print("M0001 NOTE 환경 파일은 엔진의 facade 단계가 기록한다")
    print("M0001 OK")
    return 0


def undo(h, a):
    a = os.path.abspath(a)
    new_home = os.path.join(a, ".harness")
    state = _load_json(os.path.join(new_home, "update_state.json"))
    backups = (state.get("m0001") or {}).get("rc_backups") or {}
    for path, bak in sorted(backups.items()):
        if os.path.isfile(bak):
            shutil.copy2(bak, path)
            print("UNDO RC %s restored" % path)
    if os.path.isfile(os.path.join(new_home, "install.json")):
        print("UNDO NOTE 새 HARNESS_HOME 은 삭제하지 않는다(보고만)")
    print("M0001 UNDO")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=MIGRATION_ID)
    ap.add_argument("--harness-home", required=True)
    ap.add_argument("--ai-root", required=True)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--undo", action="store_true")
    a = ap.parse_args(argv)
    if a.undo:
        return undo(a.harness_home, a.ai_root)
    return run(a.harness_home, a.ai_root, a.dry_run)


if __name__ == "__main__":
    sys.exit(main())
