# 파일 내용 검색(rg 우선, 파이썬 대체) 모듈 — oio search 도구의 본체
"""
search_ops.py — 내용 검색. rg 가 있으면 rg, 없으면 os.walk + re 로 대체한다.

- 기본 제외: .git bin obj node_modules __pycache__ .vs dist
- 결과 수(max_results)와 시간(timeout_seconds)에 상한을 둔다. 초과하면 truncated=True.
- 바이너리 파일은 건너뛴다. 읽기 전용이며 데몬·스레드를 만들지 않는다.
- 엔진 선택: 환경변수 OIO_SEARCH_ENGINE(rg|python) > ~/.local/bin/rg > PATH 의 rg > python
"""
import fnmatch
import os
import re
import shutil
import subprocess
import time
from typing import Optional

from utils import acquire_worker_slot  # 전역 worker slot (find_ops 와 동일 규약)

DEFAULT_EXCLUDES = [".git", "bin", "obj", "node_modules", "__pycache__", ".vs", "dist"]
_MAX_LINE_CHARS = 300
_MAX_FILE_BYTES = 5 * 1024 * 1024


def _find_rg() -> Optional[str]:
    local = os.path.expanduser("~/.local/bin/rg")
    if os.path.isfile(local) and os.access(local, os.X_OK):
        return local
    return shutil.which("rg")


def pick_engine(engine: str = "") -> str:
    want = (engine or os.environ.get("OIO_SEARCH_ENGINE", "")).strip().lower()
    if want == "python":
        return "python"
    if want == "rg":
        return "rg" if _find_rg() else "python"
    return "rg" if _find_rg() else "python"


def _err(code: str, msg: str, path: str = "") -> dict:
    return {"success": False, "error": code, "message": msg, "path": path}


def _search_rg(path, pattern, glob, ignore_case, fixed_string, max_results,
               deadline, include_ignored):
    rg = _find_rg()
    cmd = [rg, "--null", "--with-filename", "--line-number", "--no-heading", "--color", "never",
           "--hidden", "--max-columns", str(_MAX_LINE_CHARS), "--max-columns-preview",
           "--max-filesize", str(_MAX_FILE_BYTES)]
    if ignore_case:
        cmd.append("-i")
    if fixed_string:
        cmd.append("-F")
    if include_ignored:
        cmd.append("--no-ignore")
    for d in DEFAULT_EXCLUDES:
        cmd += ["--glob", "!%s/**" % d, "--glob", "!**/%s/**" % d]
    if glob:
        cmd += ["--glob", glob]
    cmd += ["-e", pattern, "--", path]
    matches, truncated = [], False
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        for raw in proc.stdout:
            if time.monotonic() > deadline or len(matches) >= max_results:
                truncated = True
                break
            line = raw.decode("utf-8", "replace").rstrip("\n")
            fpath, sep, rest = line.partition("\0")
            if not sep:
                continue
            lno, _, text = rest.partition(":")
            try:
                lno = int(lno)
            except ValueError:
                continue
            matches.append({"path": fpath, "line": lno, "text": text})
    finally:
        if proc.poll() is None:
            proc.kill()
        try:
            proc.stdout.close()
        except Exception:
            pass
        proc.wait()
    return matches, truncated


def _is_binary(fp: str) -> bool:
    try:
        with open(fp, "rb") as f:
            return b"\0" in f.read(4096)
    except OSError:
        return True


def _search_python(path, pattern, glob, ignore_case, fixed_string, max_results,
                   deadline, include_ignored):
    flags = re.IGNORECASE if ignore_case else 0
    rx = re.compile(re.escape(pattern) if fixed_string else pattern, flags)
    skip = set(DEFAULT_EXCLUDES)
    matches, truncated = [], False

    def one_file(fp):
        nonlocal truncated
        try:
            if os.path.getsize(fp) > _MAX_FILE_BYTES or _is_binary(fp):
                return
            with open(fp, "r", encoding="utf-8", errors="replace") as f:
                for i, ln in enumerate(f, 1):
                    if rx.search(ln):
                        if len(matches) >= max_results or time.monotonic() > deadline:
                            truncated = True
                            return
                        matches.append({"path": fp, "line": i,
                                        "text": ln.rstrip("\r\n")[:_MAX_LINE_CHARS]})
        except OSError:
            return

    if os.path.isfile(path):
        one_file(path)
        return matches, truncated
    for root, dirs, files in os.walk(path):
        dirs[:] = [d for d in dirs if d not in skip]
        for name in files:
            if truncated or time.monotonic() > deadline:
                return matches, True
            fp = os.path.join(root, name)
            if glob and not (fnmatch.fnmatch(name, glob) or fnmatch.fnmatch(fp, glob)):
                continue
            one_file(fp)
        if truncated:
            break
    return matches, truncated


def content_search(path: str, pattern: str, glob: str = "", ignore_case: bool = False,
                   fixed_string: bool = False, max_results: int = 200,
                   timeout_seconds: float = 30.0, include_ignored: bool = False,
                   engine: str = "") -> dict:
    """내용 검색. 반환: matches[{path,line,text}], engine, truncated."""
    if not pattern:
        return _err("INVALID_ARGUMENT", "pattern 이 비어 있음", path)
    if not os.path.exists(path):
        return _err("NOT_FOUND", "경로 없음", path)
    max_results = max(1, min(int(max_results), 5000))
    timeout_seconds = max(1.0, min(float(timeout_seconds), 120.0))
    eng = pick_engine(engine)
    try:
        with acquire_worker_slot(timeout=2.0) as acquired:
            if not acquired:
                return _err("CONCURRENCY_LIMIT", "oio worker slot 포화 — 잠시 후 재시도", path)
            deadline = time.monotonic() + timeout_seconds
            fn = _search_rg if eng == "rg" else _search_python
            matches, truncated = fn(path, pattern, glob, ignore_case, fixed_string,
                                    max_results, deadline, include_ignored)
    except (BrokenPipeError, ConnectionResetError):
        raise
    except re.error as e:
        return _err("INVALID_PATTERN", str(e), path)
    except Exception as e:
        return _err("FS_ERROR", str(e), path)
    if time.monotonic() > deadline:
        truncated = True
    return {"matches": matches, "engine": eng, "truncated": truncated}


# 판정기(AC-007) 호환 별칭
search = content_search
