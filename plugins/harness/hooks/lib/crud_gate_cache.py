#!/usr/bin/env python3
# F-CRUD-1 게이트(verify_crud_executed.py) 판정 결과를 "실제로 읽은 입력"의 지문으로 캐시하는 래퍼
#
# 배경 (사이클174 oi-fix-4, 2026-10-10 실측):
#   write_guard.sh 는 time_budget.sh 7.5s(closed) 안에서 돈다. 그런데 otest_done 판정(verify --final)은
#   단독 실행 30.4s(rc=0)였다. write_guard 내부 `timeout 20` 이 먼저 죽여 rc=124 → 차단,
#   바깥 예산 7.5s 도 초과 → "시스템 정체" 보류. 재시도해도 매번 처음부터 다시 돌아 ★영원히 통과 불가★였다.
#   time_budget 의 "판정은 백그라운드에서 계속" 경로는 늦은 결과를 로그로만 남기고 재사용하지 않는다.
#
# 해법 (검증을 없애지 않는다 — 같은 입력에 대한 같은 판정을 재사용할 뿐):
#   gate 모드: 캐시 적중이면 즉시 그 rc/출력. 아니면 detached 러너를 띄우고 --wait 초 기다린다.
#              그 안에 못 끝나면 rc=75(PENDING) — write_guard 가 "판정 진행 중, 재시도" 로 차단한다.
#   run  모드: verify 를 ★같은 프로세스★ 에서 실행하며 os.stat/os.lstat·open·listdir/scandir·git 호출을
#              가로채 실제로 본 경로의 (존재·mtime_ns·ctime_ns·size·ino) 를 ★접근 직전★ 에 기록한다.
#              git 은 해당 저장소의 index/HEAD/packed-refs/logs/HEAD/refs/heads 를 기록한다.
#   적중 조건: 같은 인자·환경 + TTL(900s) 이내 + 기록된 전 경로의 지문이 지금과 동일.
#   하나라도 다르면 미적중 → 재판정(안전 방향). git 외 subprocess·예외·시간초과 결과는 재사용하지 않는다.
#
# 사용법:
#   crud_gate_cache.py gate --script <verify.py> --cache-dir <dir> [--wait 4] -- <verify args...>
#   crud_gate_cache.py run  --script <verify.py> --cache-dir <dir> --key <k> -- <verify args...>   (내부용)
# 종료코드: verify 의 rc 그대로 / 75 = 판정 진행 중(PENDING) / 3 = 래퍼 사용법 오류

import hashlib
import io
import json
import os
import signal
import stat as _stat
import subprocess
import sys
import time

TTL_SEC = 900          # 캐시 유효 시간
RUN_LIMIT_SEC = 170    # 러너 1회 최대 실행 시간(초과 시 rc=124, 캐시 안 함)
RC_PENDING = 75

_ORIG_STAT = os.stat
_ORIG_LSTAT = os.lstat


def _sig(path):
    """경로 지문. 부재/오류도 지문의 일부다(생기거나 사라지면 미적중).

    [사이클196 oi-fix-1 (a)] 디렉터리는 "있다·디렉터리다"만 지문으로 삼는다(mtime·ctime·크기 제외).
      디렉터리 mtime 은 그 안에서 아무 파일이나 생기거나 지워지면 바뀐다 — evidence/ 는 다른 hook 이 매 턴
      askq_*·stop_last 를 갱신해 mtime 이 계속 바뀌었고, 판정과 무관한 그 변화 때문에 캐시가 매번 미적중해
      make_ok 기록이 4회 재시도됐다(10-23 10:21~10:23 otest-1 실측). 디렉터리 "내용"(목록)이 판정 입력이면
      listdir/scandir 경로(ls: 키, 이름 집합)와 glob 경로(glob: 키, 일치 결과)로 따로 지문을 남긴다."""
    if isinstance(path, str) and path.startswith(("ls:", "glob:")):
        return _content_sig(path)
    try:
        st = _ORIG_STAT(path)
    except FileNotFoundError:
        return ["absent"]
    except NotADirectoryError:
        return ["notdir"]
    except OSError as exc:
        return ["err", exc.errno]
    if _stat.S_ISDIR(st.st_mode):
        return ["dir"]
    return ["ok", st.st_mtime_ns, st.st_ctime_ns, st.st_size, st.st_ino, False]


def _content_sig(key):
    """ls:<디렉터리> → 이름 집합 해시 / glob:<패턴> → 일치 경로 목록 해시(판정 입력 집합만)."""
    import glob as _g
    try:
        if key.startswith("ls:"):
            names = sorted(os.listdir(key[3:]))
        else:
            names = sorted(_g.glob(key[5:]))
    except FileNotFoundError:
        return ["absent"]
    except OSError as exc:
        return ["err", exc.errno]
    return ["set", hashlib.sha256("\0".join(names).encode("utf-8", "surrogateescape")).hexdigest()[:16], len(names)]


def _parse(argv):
    if len(argv) < 2 or argv[1] not in ("gate", "run"):
        return None
    mode, opts, rest, i = argv[1], {"wait": "4"}, [], 2
    while i < len(argv):
        a = argv[i]
        if a == "--":
            rest = argv[i + 1:]
            break
        if a in ("--script", "--cache-dir", "--wait", "--key") and i + 1 < len(argv):
            opts[a[2:]] = argv[i + 1]
            i += 2
            continue
        return None
    if "script" not in opts or "cache-dir" not in opts:
        return None
    return mode, opts, rest


def _key(script, args):
    material = json.dumps({
        "script": os.path.realpath(script),
        "script_sig": _sig(script),
        "self_sig": _sig(os.path.abspath(__file__)),
        "args": args,
        "config": os.environ.get("CLAUDE_CONFIG_DIR", ""),
        "project": os.environ.get("CLAUDE_PROJECT_DIR", ""),
        "cwd": os.getcwd(),
    }, ensure_ascii=False, sort_keys=True)
    return hashlib.sha256(material.encode("utf-8")).hexdigest()[:24]


def _load(path):
    try:
        with open(path, "r", encoding="utf-8") as fp:
            return json.load(fp)
    except (OSError, ValueError):
        return None


def _write_atomic(path, payload):
    tmp = f"{path}.tmp{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as fp:
        json.dump(payload, fp, ensure_ascii=False)
    os.replace(tmp, path)


def _valid(entry, key, since=None):
    """캐시 항목이 지금도 유효한가. since 가 있으면 nocache 항목도 그 시각 이후 것이면 1회 인정한다."""
    if not isinstance(entry, dict) or entry.get("key") != key:
        return False
    ts = entry.get("ts", 0)
    if entry.get("nocache"):
        return since is not None and ts >= since
    if time.time() - ts > TTL_SEC:
        return False
    sigs = entry.get("sigs")
    if not isinstance(sigs, dict) or not sigs:
        return False
    for p, s in sigs.items():
        if _sig(p) != s:
            return False
    return True


def _pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def _emit(entry, note):
    out = entry.get("out", "")
    sys.stdout.write(out)
    if out and not out.endswith("\n"):
        sys.stdout.write("\n")
    sys.stdout.write(note + "\n")
    sys.stdout.flush()
    return int(entry.get("rc", 1))


# ─────────────────────────────── gate ───────────────────────────────
def gate(opts, args):
    script, cdir = opts["script"], opts["cache-dir"]
    try:
        wait = max(0.0, float(opts.get("wait", "4")))
    except ValueError:
        wait = 4.0
    # 세션 디렉토리(cache-dir 의 조부모 = session-env/<UUID>)가 없으면 캐시 없이 종전처럼 직접 실행한다.
    if not os.path.isdir(os.path.dirname(os.path.dirname(os.path.abspath(cdir)))):
        return subprocess.run([sys.executable, script] + args).returncode
    os.makedirs(cdir, exist_ok=True)
    key = _key(script, args)
    cf, lf = os.path.join(cdir, f"{key}.json"), os.path.join(cdir, f"{key}.running")

    entry = _load(cf)
    if _valid(entry, key):
        age = int(time.time() - entry.get("ts", 0))
        return _emit(entry, f"CRUD_GATE_CACHE: 적중(판정 {age}s 전, 입력 지문 {len(entry.get('sigs', {}))}개 불변)")

    since = time.time()
    lock = _load(lf)
    running = isinstance(lock, dict) and isinstance(lock.get("pid"), int) and _pid_alive(lock["pid"]) \
        and time.time() - lock.get("ts", 0) < RUN_LIMIT_SEC + 30
    if running:
        since = lock.get("ts", since)
    else:
        try:
            os.remove(lf)
        except OSError:
            pass
        try:
            fd = os.open(lf, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            os.write(fd, json.dumps({"pid": os.getpid(), "ts": since}).encode())
            os.close(fd)
            child = subprocess.Popen(
                [sys.executable, os.path.abspath(__file__), "run", "--script", script,
                 "--cache-dir", cdir, "--key", key, "--"] + args,
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                start_new_session=True, close_fds=True)
            _write_atomic(lf, {"pid": child.pid, "ts": since})
        except FileExistsError:
            pass  # 동시 gate 가 방금 띄웠다 — 그 결과를 기다린다

    deadline = time.time() + wait
    while True:
        entry = _load(cf)
        if _valid(entry, key, since=since - 1):
            return _emit(entry, "CRUD_GATE_CACHE: 신규 판정")
        if time.time() >= deadline:
            break
        time.sleep(0.25)
    lock = _load(lf) or {}
    started = int(time.time() - lock.get("ts", since))
    print(f"CRUD_GATE_PENDING: CRUD 실행증거 판정이 백그라운드에서 진행 중입니다(시작 {started}s 전, "
          f"실측 통상 30~60s). 판정이 끝나면 결과가 입력 지문으로 캐시되어 같은 호출을 다시 하면 즉시 판정됩니다.")
    return RC_PENDING


# ─────────────────────────────── run ───────────────────────────────
def run(opts, args):
    script, cdir, key = opts["script"], opts["cache-dir"], opts.get("key", "")
    cf, lf = os.path.join(cdir, f"{key}.json"), os.path.join(cdir, f"{key}.running")
    cdir_real = os.path.realpath(cdir)
    sigs, state = {}, {"busy": False, "nocache": None}

    def record(p):
        if state["busy"]:
            return
        try:
            if isinstance(p, int):
                return
            p = os.fsdecode(os.fspath(p))
        except TypeError:
            return
        ap = os.path.abspath(p)
        if ap in sigs or ap == cdir_real or ap.startswith(cdir_real + os.sep):
            return
        state["busy"] = True
        try:
            sigs[ap] = _sig(ap)
        finally:
            state["busy"] = False

    def record_git(d):
        state["busy"] = True
        try:
            d = os.path.abspath(d)
            while True:
                dotgit = os.path.join(d, ".git")
                s = _sig(dotgit)
                if s[0] == "ok":
                    gd = dotgit
                    if not s[5]:
                        try:
                            with open(dotgit, "r", encoding="utf-8") as fp:
                                line = fp.read().strip()
                            if line.startswith("gitdir:"):
                                gd = os.path.join(d, line[7:].strip())
                        except OSError:
                            state["nocache"] = "gitdir 판독 실패"
                    sigs[dotgit] = s
                    for sub in ("index", "HEAD", "packed-refs", os.path.join("logs", "HEAD"),
                                os.path.join("refs", "heads"), "commondir"):
                        p = os.path.abspath(os.path.join(gd, sub))
                        sigs.setdefault(p, _sig(p))
                    return
                parent = os.path.dirname(d)
                if parent == d:
                    return
                d = parent
        finally:
            state["busy"] = False

    def record_key(k):
        # [사이클196 oi-fix-1 (a)] 내용 지문 키(ls:·glob:) — 디렉터리 mtime 대신 판정이 실제로 본 목록만
        if state["busy"] or k in sigs:
            return
        state["busy"] = True
        try:
            sigs[k] = _content_sig(k)
        finally:
            state["busy"] = False

    def audit(event, a):
        if state["busy"]:
            return
        if event == "open":
            record(a[0])
        elif event in ("os.listdir", "os.scandir"):
            p = a[0] if a and a[0] is not None else "."
            if isinstance(p, int):
                return
            try:
                ap = os.path.abspath(os.fsdecode(os.fspath(p)))
            except TypeError:
                return
            if ap == cdir_real or ap.startswith(cdir_real + os.sep):
                return
            record_key("ls:" + ap)
        elif event == "subprocess.Popen":
            exe, argv, cwd = a[0], a[1], a[2]
            first = argv[0] if isinstance(argv, (list, tuple)) and argv else (argv or exe or "")
            name = os.path.basename(os.fsdecode(first)) if not isinstance(first, int) else ""
            if name != "git":
                state["nocache"] = f"git 외 subprocess({name})"
                return
            dirs = [os.fsdecode(cwd) if cwd else os.getcwd()]
            if isinstance(argv, (list, tuple)):
                for i, v in enumerate(argv[:-1]):
                    if v == "-C":
                        dirs.append(os.fsdecode(argv[i + 1]))
            for d in dirs:
                record_git(d)

    def p_stat(path, *a, **kw):
        if not kw.get("dir_fd"):
            record(path)
        return _ORIG_STAT(path, *a, **kw)

    def p_lstat(path, *a, **kw):
        if not kw.get("dir_fd"):
            record(path)
        return _ORIG_LSTAT(path, *a, **kw)

    # [사이클196 oi-fix-1 (a)] glob 은 디렉터리 전체를 훑지만 판정 입력은 "패턴에 맞는 결과"뿐이다.
    #   훑는 동안 개별 기록을 멈추고(busy) glob:<패턴> 결과 집합만 지문으로 남긴다. 일치한 파일을 판정기가 열면
    #   그 파일 지문은 open 경로로 따로 남는다. 키워드 인자(root_dir·recursive 등)가 있으면 종전 방식(개별 기록)으로 둔다.
    import glob as _glob_mod
    _orig_glob, _orig_iglob = _glob_mod.glob, _glob_mod.iglob

    def p_glob(pathname, *a, **kw):
        if a or kw or not isinstance(pathname, str):
            return _orig_glob(pathname, *a, **kw)
        was = state["busy"]
        state["busy"] = True
        try:
            res = _orig_glob(pathname)
        finally:
            state["busy"] = was
        record_key("glob:" + os.path.abspath(pathname))
        return res

    def p_iglob(pathname, *a, **kw):
        if a or kw or not isinstance(pathname, str):
            return _orig_iglob(pathname, *a, **kw)
        return iter(p_glob(pathname))

    # stdout/stderr 를 따로 받아 "stderr → stdout" 순으로 합친다. 종전 `python3 verify 2>&1` 를 파이프로 받으면
    # stdout 은 블록 버퍼라 종료 시 뒤에 붙었다 — 차단 사유(head -c 500)에 같은 앞부분이 실리도록 순서를 맞춘다.
    buf, ebuf = io.StringIO(), io.StringIO()
    rc, t0 = 1, time.time()

    def on_alarm(_s, _f):
        raise TimeoutError("crud_gate_cache 실행 한도 초과")

    signal.signal(signal.SIGALRM, on_alarm)
    signal.alarm(RUN_LIMIT_SEC)
    old_out, old_err, old_argv = sys.stdout, sys.stderr, sys.argv
    try:
        import runpy
        sys.argv = [script] + args
        sys.path.insert(0, os.path.dirname(os.path.abspath(script)))
        sys.stdout, sys.stderr = buf, ebuf
        os.stat, os.lstat = p_stat, p_lstat
        _glob_mod.glob, _glob_mod.iglob = p_glob, p_iglob
        sys.addaudithook(audit)
        try:
            runpy.run_path(script, run_name="__main__")
            rc = 0
        except SystemExit as exc:
            if exc.code is None:
                rc = 0
            elif isinstance(exc.code, int):
                rc = exc.code
            else:
                ebuf.write(str(exc.code) + "\n")
                rc = 1
    except TimeoutError as exc:
        rc, state["nocache"] = 124, str(exc)
    except BaseException as exc:  # noqa: BLE001 — 판정기 예외는 캐시하지 않는다
        ebuf.write(f"CRUD_GATE_WRAPPER_EXCEPTION: {type(exc).__name__}: {exc}\n")
        rc, state["nocache"] = 1, f"예외 {type(exc).__name__}"
    finally:
        signal.alarm(0)
        state["busy"] = True
        os.stat, os.lstat = _ORIG_STAT, _ORIG_LSTAT
        _glob_mod.glob, _glob_mod.iglob = _orig_glob, _orig_iglob
        sys.stdout, sys.stderr, sys.argv = old_out, old_err, old_argv

    entry = {"v": 1, "key": key, "rc": rc, "out": (ebuf.getvalue() + buf.getvalue())[:20000], "ts": t0,
             "elapsed": round(time.time() - t0, 2), "sigs": sigs}
    if state["nocache"]:
        entry["nocache"] = state["nocache"]
    try:
        _write_atomic(cf, entry)
    finally:
        lock = _load(lf)
        if isinstance(lock, dict) and lock.get("pid") == os.getpid():
            try:
                os.remove(lf)
            except OSError:
                pass
    return rc


def main():
    parsed = _parse(sys.argv)
    if parsed is None:
        print("사용법: crud_gate_cache.py gate|run --script <verify.py> --cache-dir <dir> [--wait N] [--key K] -- <args>",
              file=sys.stderr)
        return 3
    mode, opts, args = parsed
    return gate(opts, args) if mode == "gate" else run(opts, args)


if __name__ == "__main__":
    sys.exit(main())
