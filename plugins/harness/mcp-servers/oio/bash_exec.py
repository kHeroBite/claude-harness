"""
bash_exec 도구: 셸 명령 실행 (차단 목록 보안, 타임아웃).

Codex CR-4 supervisor pattern:
- 단일 supervisor thread(daemon=False)가 모든 BG child를 관리
- per-process daemon reaper 제거 → 서버 종료 시 exit status/children 유실 방지
- atexit로 모든 active child에게 SIGTERM→SIGKILL 순차 종료
"""
import atexit as _atexit
import os
import subprocess
import sys
import threading as _threading
import time

import security

MAX_TIMEOUT_MS = 600_000
DEFAULT_TIMEOUT_MS = 120_000

# FG 동시 실행 한도 (anyio threadpool 포화 방지 — Codex FIX-07)
# anyio 기본 max_workers=40, 상시 스레드(watchdog/monitor 등) 제외 후 20으로 제한
_fg_semaphore = _threading.Semaphore(20)  # 데몬 제거 + fail-fast 도입에 맞춰 보수적 축소

# D-state cooldown — 최근 D-state 감지 시각 기록 (원인 8)
# bash_exec 진입부에서 이 flag 확인 후 /mnt/c 경로면 fail-fast 반환
_last_dstate_detected_at = 0.0
_DSTATE_COOLDOWN_SEC = 30

# BG 프로세스 추적 registry (Codex CR-4).
# 구조: {pid: {"proc": Popen, "log_path": str, "cmd": str[:200], "started": float}}
_bg_registry: dict = {}
_bg_lock = _threading.Lock()

# Supervisor thread (단일, 모든 BG child 관리)
_supervisor_stop_event = _threading.Event()
_supervisor_thread = None

# BG 로그 TTL (초) — 7일. Codex HR-4: pid 사망 AND mtime 7일 AND registry 미참조 3조건 AND.
BG_LOG_TTL_SECONDS = 7 * 24 * 3600


def _bg_log_dir() -> str:
    """백그라운드 로그/임시파일 저장 디렉토리를 반환한다 (L-541 재발방지).

    /tmp 직하위 사용 금지 (CLAUDE.md 임시파일 위치 규칙 — 다중 세션 충돌 + NTFS Defender 무관 EXT4 격리).
    우선순위:
      1) OIO_BG_DIR 환경변수 (명시 지정 시)
      2) $CLAUDE_CONFIG_DIR/oio-bg (하네스 세션 config 루트 — EXT4, 세션군 격리)
      3) $HOME/.claude/oio-bg (폴백 — EXT4)
    디렉토리는 없으면 생성한다. 생성 실패 시 최후에만 /tmp 폴백(가용성 우선).
    """
    base = os.environ.get("OIO_BG_DIR")
    if not base:
        cfg = os.environ.get("CLAUDE_CONFIG_DIR")
        if cfg:
            base = os.path.join(cfg, "oio-bg")
        else:
            base = os.path.join(os.path.expanduser("~"), ".claude", "oio-bg")
    try:
        os.makedirs(base, exist_ok=True)
        return base
    except OSError:
        return "/tmp"  # 최후 폴백 (디렉토리 생성 불가 시 가용성 우선)


def _supervisor_loop():
    """BG child 감독 스레드 (1초 주기) — Codex CR-4.

    registry를 주기적으로 순회하며 종료된 child를 reap하고 stderr에 로그를 남긴다.
    서버 수명 동안 계속 살아있으며, _shutdown_supervisor에서만 정지한다.
    """
    while not _supervisor_stop_event.is_set():
        try:
            with _bg_lock:
                pids = list(_bg_registry.keys())
            for pid in pids:
                with _bg_lock:
                    entry = _bg_registry.get(pid)
                if entry is None:
                    continue
                proc = entry["proc"]
                if proc.poll() is not None:  # 종료됨
                    rc = proc.returncode
                    sys.stderr.write(
                        f"[oio] bg pid={pid} exited code={rc} cmd={entry['cmd'][:60]}\n"
                    )
                    sys.stderr.flush()
                    # .done 마커 파일 생성 — 에이전트가 sleep+cat 폴링 없이 완료 감지 가능
                    log_path = entry.get("log_path", "")
                    if log_path:
                        done_path = log_path + ".done"
                        try:
                            with open(done_path, "w") as f:
                                f.write(str(rc))
                        except OSError:
                            pass
                    with _bg_lock:
                        _bg_registry.pop(pid, None)
        except Exception as e:
            sys.stderr.write(f"[oio] supervisor error: {e}\n")
            sys.stderr.flush()
        # 1초 주기 (stop_event로 즉시 깨어날 수 있음)
        _supervisor_stop_event.wait(timeout=1.0)


def _ensure_supervisor():
    """첫 BG 요청 시 supervisor thread 시작 (lazy init) — Codex CR-4."""
    global _supervisor_thread
    if _supervisor_thread is None or not _supervisor_thread.is_alive():
        _supervisor_stop_event.clear()
        _supervisor_thread = _threading.Thread(
            target=_supervisor_loop,
            name="oio-bg-supervisor",
            daemon=True,  # Python 종료 시 자동 정리 (atexit에서 graceful shutdown 선행)
        )
        _supervisor_thread.start()


def _shutdown_supervisor():
    """프로세스 종료 시 모든 BG child 정리 — Codex CR-4.

    SIGTERM(2초) → SIGKILL 순차 종료, 이후 supervisor thread join.
    """
    import signal as _signal
    import time as _time
    with _bg_lock:
        entries = list(_bg_registry.items())
    # 1단계: 모든 child에게 SIGTERM (프로세스 그룹 전체)
    for pid, entry in entries:
        try:
            os.killpg(os.getpgid(pid), _signal.SIGTERM)
        except (ProcessLookupError, PermissionError, OSError):
            pass
    # 2단계: 2초 대기
    deadline = _time.time() + 2.0
    for pid, entry in entries:
        remaining = deadline - _time.time()
        if remaining <= 0:
            break
        try:
            entry["proc"].wait(timeout=remaining)
        except Exception:
            pass
    # 3단계: 여전히 살아있으면 SIGKILL
    with _bg_lock:
        remaining_entries = list(_bg_registry.items())
    for pid, entry in remaining_entries:
        if entry["proc"].poll() is None:
            try:
                os.killpg(os.getpgid(pid), _signal.SIGKILL)
            except (ProcessLookupError, PermissionError, OSError):
                pass
            try:
                entry["proc"].wait(timeout=10)
            except subprocess.TimeoutExpired:
                sys.stderr.write(f"[oio] bg pid={pid} still alive after SIGKILL (orphan)\n")
            except Exception:
                pass
            sys.stderr.write(f"[oio] bg pid={pid} killed on shutdown\n")
    # supervisor thread 종료
    _supervisor_stop_event.set()
    if _supervisor_thread and _supervisor_thread.is_alive():
        _supervisor_thread.join(timeout=3.0)
    sys.stderr.flush()


_atexit.register(_shutdown_supervisor)


def _log_d_state(pid: int, context: str) -> None:
    """FIX-FG-01b: FG timeout 경로에서 대상 프로세스의 /proc/{pid}/status를 읽어
    State=='D' (Disk Sleep, uninterruptible) 시 stderr 경고를 남긴다.

    - D-state는 보통 NTFS/stale I/O 대기 중으로, SIGTERM/SIGKILL에도 즉각 반응 불가.
    - raise/block 없음 — 진단 목적만. 실패(파일 부재, 권한 등)는 조용히 무시.
    - Rollback: 환경변수 OIO_BASH_D_STATE_LOG=0 설정 시 no-op.
    """
    if os.environ.get("OIO_BASH_D_STATE_LOG", "1") == "0":
        return
    try:
        status_path = f"/proc/{pid}/status"
        with open(status_path, "r") as _sf:
            for _line in _sf:
                if _line.startswith("State:"):
                    state_val = _line.split(":", 1)[1].strip()
                    if state_val.startswith("D"):
                        sys.stderr.write(
                            f"[oio] fg D-state detected pid={pid} state={state_val!r} context={context}\n"
                        )
                        sys.stderr.flush()
                        # flag 갱신 — 다음 bash_exec 진입 시 /mnt/c 경로면 fail-fast (원인 8)
                        globals()["_last_dstate_detected_at"] = time.time()
                    return
    except (OSError, ValueError):
        return


def _bg_log_cleanup_once():
    """BG 로그 TTL 정리 — Codex HR-4 3조건 AND: registry 미참조 + mtime>7일 + (pid 사망 또는 미상).

    active child-log는 registry에서 추적되므로 여기서는 registry에 **없는** 로그만 검사.
    (registry에 있는 로그는 실행 중이거나 reap 중이므로 보존.)
    """
    try:
        tmp_dir = _bg_log_dir()
        now = time.time()
        # Codex CR-4: registry 구조 변경 ({pid: {...}}), lock 보호 필수
        with _bg_lock:
            active_logs = {e["log_path"] for e in _bg_registry.values()}
        for name in os.listdir(tmp_dir):
            if not (name.startswith("oio_bg_") and name.endswith(".log")):
                continue
            path = os.path.join(tmp_dir, name)
            # 조건 1: registry 참조 여부 (active child는 보존)
            if path in active_logs:
                continue
            try:
                st = os.stat(path)
            except OSError:
                continue
            # 조건 2: mtime 7일 초과
            if (now - st.st_mtime) <= BG_LOG_TTL_SECONDS:
                continue
            # 조건 3: 파일명에서 pid 추출은 oio_bg_XXXXXX 임시명이라 불가 → registry 부재로 대체
            # (registry에 없으면서 7일 이상된 로그는 orphan으로 간주)
            try:
                os.unlink(path)
                sys.stderr.write(f"[oio] bg log cleanup: {path} (age>{BG_LOG_TTL_SECONDS}s, orphan)\n")
                sys.stderr.flush()
            except OSError:
                pass
            # .done 마커 파일도 함께 정리
            done_path = path + ".done"
            try:
                if os.path.exists(done_path):
                    os.unlink(done_path)
            except OSError:
                pass
    except Exception as e:
        sys.stderr.write(f"[oio] bg log cleanup error: {e}\n")
        sys.stderr.flush()


# 모듈 import 시 1회 정리 (idempotent, 비용 낮음)
_bg_log_cleanup_once()


def _split_and_commands(command: str) -> list:
    """&& 기준으로 명령 분리. 따옴표/서브셸/중괄호/heredoc 내부의 &&는 무시."""
    import re as _re
    _HEREDOC_RE = _re.compile(r'<<-?\s*[\'"]?(\w+)[\'"]?')

    # heredoc 블록이 포함된 경우 줄 단위 상태 머신으로 처리
    if '<<' in command:
        lines = command.split('\n')
        segments = []          # &&로 분리된 세그먼트 조각들
        current_lines = []
        in_heredoc = False
        heredoc_marker = None

        for line in lines:
            if in_heredoc:
                current_lines.append(line)
                # heredoc 종료 마커 감지 (앞뒤 공백 무시)
                if line.strip() == heredoc_marker:
                    in_heredoc = False
                    heredoc_marker = None
            else:
                # heredoc 시작 감지
                m = _HEREDOC_RE.search(line)
                if m:
                    in_heredoc = True
                    heredoc_marker = m.group(1)
                    current_lines.append(line)
                else:
                    # 이 줄에서 && 파싱 (문자 단위, 따옴표/괄호 추적)
                    in_single = False
                    in_double = False
                    paren_depth = 0
                    brace_depth = 0
                    j = 0
                    line_parts = []
                    line_buf = []
                    while j < len(line):
                        ch = line[j]
                        if ch == "'" and not in_double:
                            in_single = not in_single
                        elif ch == '"' and not in_single:
                            in_double = not in_double
                        elif not in_single and not in_double:
                            if ch == '(':
                                paren_depth += 1
                            elif ch == ')':
                                paren_depth = max(0, paren_depth - 1)
                            elif ch == '{':
                                brace_depth += 1
                            elif ch == '}':
                                brace_depth = max(0, brace_depth - 1)
                            elif ch == '&' and paren_depth == 0 and brace_depth == 0:
                                if j + 1 < len(line) and line[j + 1] == '&':
                                    line_parts.append(''.join(line_buf))
                                    line_buf = []
                                    j += 2
                                    continue
                        line_buf.append(ch)
                        j += 1
                    if line_buf or not line_parts:
                        line_parts.append(''.join(line_buf))

                    if len(line_parts) > 1:
                        # 첫 파트는 누적 중인 current_lines에 합류 → 분리
                        current_lines.append(line_parts[0])
                        segments.append('\n'.join(current_lines))
                        current_lines = []
                        for part in line_parts[1:-1]:
                            segments.append(part)
                        current_lines.append(line_parts[-1])
                    else:
                        current_lines.append(line_parts[0])

        if current_lines:
            segments.append('\n'.join(current_lines))

        return [s.strip() for s in segments if s.strip()]

    # heredoc 없는 일반 케이스: 기존 문자 단위 파싱 (성능 최적화)
    commands = []
    current = []
    in_single = False
    in_double = False
    paren_depth = 0
    brace_depth = 0
    i = 0
    while i < len(command):
        c = command[i]
        if c == "'" and not in_double:
            in_single = not in_single
        elif c == '"' and not in_single:
            in_double = not in_double
        elif not in_single and not in_double:
            if c == '(':
                paren_depth += 1
            elif c == ')':
                paren_depth = max(0, paren_depth - 1)
            elif c == '{':
                brace_depth += 1
            elif c == '}':
                brace_depth = max(0, brace_depth - 1)
            elif c == '&' and paren_depth == 0 and brace_depth == 0:
                if i + 1 < len(command) and command[i + 1] == '&':
                    commands.append(''.join(current))
                    current = []
                    i += 2
                    continue
        current.append(c)
        i += 1
    if current:
        commands.append(''.join(current))
    return [c for c in commands if c.strip()]


def _wrap_dotnet_via_cmd(command: str) -> str:
    """dotnet 명령을 cmd.exe /c dotnet으로 자동 래핑. 이미 cmd.exe로 래핑된 경우 스킵."""
    import re
    stripped = command.strip()
    # 이미 cmd.exe로 래핑된 경우 스킵
    if stripped.startswith("cmd.exe") or stripped.startswith("cmd "):
        return command
    # dotnet으로 시작하는 명령 → cmd.exe /c 래핑
    if re.match(r"^\s*dotnet\s", stripped):
        # 따옴표 이스케이프: 내부 따옴표를 \" 로 변환
        escaped = stripped.replace('"', '\\"')
        return f'cmd.exe /c "{escaped}"'
    return command


def bash_exec(
    command: str,
    timeout_ms: int = DEFAULT_TIMEOUT_MS,
    working_dir: str = None,
    env: dict = None,
    run_in_background: bool = False,
) -> dict:
    # ═══════════════════════════════════════════════════════════
    # Fail-fast #1: threadpool 포화 (원인 7)
    # 데몬 제거 후 threadpool_monitor가 없으므로 호출 시점 1회 체크
    # ═══════════════════════════════════════════════════════════
    # ═══════════════════════════════════════════════════════════
    # Fail-fast #0: 고아 팀에이전트 가드 (3차 보강 2026-08-17)
    # bash_exec 로 session-env/<uuid>/(agents|panes) 또는 상위를 삭제하려는 시도를 막는다.
    # hook(H-1)이 1차 방어, 본 체크가 2차(서버) 방어 — L-303 과 동일한 이중 차단 구조.
    # ★ fail-open: 판정 불가 시 전부 통과. 상세는 orphan_guard.py 참조.
    # ★ 범위 최소화: 명령 문자열에 "session-env" 가 없으면 검사 자체를 건너뛴다(오버헤드 0).
    # ═══════════════════════════════════════════════════════════
    try:
        if command and "session-env" in str(command):
            import re as _re
            import orphan_guard as _og
            _m = _re.search(r'[^\s"\']*session-env[^\s"\']*', str(command))
            if _m:
                _blk = _og.check_orphan_block(_m.group(0), str(command))
                if _blk:
                    return {
                        "success": False,
                        "error": _blk.get("error", "ORPHAN_AGENTS_ALIVE"),
                        "message": _blk.get("message", ""),
                        "exit_code": -1,
                        "suggestion": _blk.get("suggestion", ""),
                    }
    except Exception:
        pass  # 어떤 예외도 명령 실행을 막지 않는다 — fail-open

    active = _threading.active_count()
    if active >= 35:
        return {
            "success": False,
            "error": "THREADPOOL_SATURATION",
            "message": f"threadpool 포화 ({active}/40) — 이전 BG 작업 완료 후 재시도",
            "exit_code": -1,
            "suggestion": "run_in_background=true 호출 감소 또는 대기 후 재시도",
        }

    # ═══════════════════════════════════════════════════════════
    # Fail-fast #2: NTFS D-state 최근 감지 (원인 8)
    # 최근 _DSTATE_COOLDOWN_SEC 내 D-state 감지된 적 있고,
    # 이번 명령이 /mnt/c/ 경로를 다룬다면 즉시 에러 반환
    # ═══════════════════════════════════════════════════════════
    if (time.time() - _last_dstate_detected_at) < _DSTATE_COOLDOWN_SEC:
        _workdir = working_dir or ""
        _cmd_str = command if command is not None else ""
        if "/mnt/c" in str(_cmd_str) or (_workdir and str(_workdir).startswith("/mnt/c")):
            return {
                "success": False,
                "error": "NTFS_DSTATE_BLOCK",
                "message": "NTFS I/O 블로킹 (최근 D-state 감지) — Windows AV 또는 DrvFs 지연",
                "exit_code": -1,
                "suggestion": "Windows Defender 제외 등록 또는 30초 후 재시도",
            }

    # L-303 재발방지 (F10 이중 차단): LLM이 명시적으로 run_in_background=true를 보내면 에러 반환.
    # (자동 감지(_LONG_RUNNING_PATTERNS)만 허용 — LLM 의도적 background 요청은 블로킹 버그 유발)
    # write_guard.sh가 1차 방어, 본 체크가 2차(서버) 방어.
    if run_in_background:
        return {
            "success": False,
            "error": (
                "🚫 [L-303] run_in_background=true 금지 — oio bash_exec 무한 블로킹 버그 유발. "
                "대신 foreground + timeout_ms 사용. 장시간 명령은 자동 감지(_LONG_RUNNING_PATTERNS)로만 background 전환 허용."
            ),
            "exit_code": -1,
            "l303_violation": True,
        }

    # dotnet → cmd.exe 자동 래핑 (WSL에서 dotnet 직접 실행 금지)
    command = _wrap_dotnet_via_cmd(command)

    # 차단 목록 검사
    block_err = security.validate_bash_command(command)
    if block_err:
        return block_err

    # 민감 환경변수 경고 감지
    sensitive = security.check_sensitive_env(command)

    # 장시간 명령 자동 감지 → 백그라운드 자동 전환
    _LONG_RUNNING_PATTERNS = [
        "docker compose up", "docker compose build", "docker compose restart",
        "docker build", "docker-compose up", "docker-compose build",
        "pip install", "npm install", "yarn install",
        "make -j", "cargo build", "dotnet build", "dotnet publish",
        "npm run dev", "dotnet run",
        # tail 변형 (대소문자)
        "tail -f", "tail -F",
        # 무한 루프 TUI
        "watch ", "top", "htop", "less ", "more ",
        # 저널/로그 팔로우
        "journalctl -f", "journalctl --follow",
        # sleep 명령 (장시간 대기)
        "sleep ",
        # 네트워크 대기
        "ssh ", "nc -l", "netcat -l",
        # dotnet 추가
        "dotnet test",
        # npm 추가
        "npm run build", "npm run test", "npm test",
        # python 변형
        "pytest", "python3 -m pytest", "python -m http.server",
        # 서버 프레임워크
        "uvicorn", "flask run",
        # 패키지 설치 / 대형 레포 clone
        "apt ", "apt-get ", "git clone ",
    ]
    if not run_in_background:
        import re as _re
        # 명령 시작 또는 &&/;/| 이후에서만 매칭 (부분 문자열 방지)
        cmd_lower = command.lower().strip()
        # 괄호 제거 버전: (cd /path && dotnet test) 형태 내부 명령 매칭용
        cmd_stripped = _re.sub(r'[\(\)]', ' ', cmd_lower)
        for pattern in _LONG_RUNNING_PATTERNS:
            escaped = _re.escape(pattern)
            if (_re.match(rf'^{escaped}\b', cmd_lower) or
                _re.search(rf'(?:&&|;|\|)\s*{escaped}\b', cmd_lower) or
                _re.search(rf'(?:&&|;|\|)\s*{escaped}\b', cmd_stripped)):
                run_in_background = True
                break

    # 백그라운드 실행: start_new_session + supervisor pattern (Codex CR-4)
    if run_in_background:
        import tempfile as _tempfile

        exec_env = os.environ.copy()
        if env:
            exec_env.update({str(k): str(v) for k, v in env.items()})
        try:
            log_fd, log_path = _tempfile.mkstemp(prefix="oio_bg_", suffix=".log", dir=_bg_log_dir())
            os.close(log_fd)

            # shell=False + start_new_session=True (nohup 대체, 정확한 PID)
            with open(log_path, "w") as log_file:
                proc = subprocess.Popen(
                    ["bash", "-c", command],
                    stdin=subprocess.DEVNULL,
                    stdout=log_file,
                    stderr=subprocess.STDOUT,
                    cwd=working_dir,
                    env=exec_env,
                    start_new_session=True,
                )

            # Codex CR-4: 단일 supervisor thread가 모든 BG child 관리
            # (per-process daemon reaper 제거 → 서버 종료 시 상태 유실 방지)
            with _bg_lock:
                _bg_registry[proc.pid] = {
                    "proc": proc,
                    "log_path": log_path,
                    "cmd": command[:200],
                    "started": time.time(),
                }
            _ensure_supervisor()

            done_path = log_path + ".done"
            return {
                "success": True,
                "pid": proc.pid,
                "background": True,
                "log_file": log_path,
                "done_file": done_path,
                "message": f"백그라운드 실행 시작 (PID: {proc.pid}, 로그: {log_path}, 완료신호: {done_path})",
                "hint": f"완료 확인: test -f {done_path} && cat {log_path}",
                "command": command[:200],
            }
        except Exception as e:
            return {
                "success": False,
                "error": "BG_EXEC_ERROR",
                "message": f"백그라운드 실행 실패: {e}",
                "background": True,
            }

    # FG 동시 실행 한도 체크 (FIX-07: anyio threadpool 포화 방지)
    # 백그라운드 실행은 즉시 반환하므로 세마포어 불필요 — 여기는 FG 전용
    _fg_acquired = _fg_semaphore.acquire(blocking=False)
    if not _fg_acquired:
        return {
            "success": False,
            "error": "CONCURRENCY_LIMIT",
            "message": "bash_exec 동시 실행 한도(30) 초과 — 잠시 후 재시도하세요",
            "exit_code": -1,
        }

    try:
        return _bash_exec_fg(command, timeout_ms, working_dir, env, sensitive)
    finally:
        _fg_semaphore.release()


def _bash_exec_fg(
    command: str,
    timeout_ms: int,
    working_dir: str,
    env: dict,
    sensitive: list,
) -> dict:
    """포어그라운드 bash 실행 본체 (세마포어 보호 하에서 호출됨)."""
    # 타임아웃 범위 제한
    timeout_ms = max(1000, min(timeout_ms, MAX_TIMEOUT_MS))
    timeout_sec = timeout_ms / 1000.0

    # 작업 디렉토리 검증
    if working_dir:
        err = security.validate_path(working_dir)
        if err:
            return err
        if not os.path.isdir(working_dir):
            return {
                "success": False,
                "error": "INVALID_PARAM",
                "message": f"작업 디렉토리가 존재하지 않습니다: {working_dir}",
                "path": working_dir,
            }

    # 환경변수 구성
    exec_env = os.environ.copy()
    if env:
        exec_env.update({str(k): str(v) for k, v in env.items()})

    start_time = time.time()

    try:
        # && 분리 실행: 각 명령을 개별 실행, 이전 명령 실패 시 중단
        commands = _split_and_commands(command)

        all_stdout = []
        all_stderr = []
        last_exit_code = 0

        for i, cmd in enumerate(commands):
            cmd = cmd.strip()
            if not cmd:
                continue

            remaining_timeout = timeout_sec - (time.time() - start_time)
            if remaining_timeout <= 0:
                return {
                    "success": False,
                    "error": "TIMEOUT",
                    "message": f"명령 {i+1}/{len(commands)}에서 전체 타임아웃 초과",
                    "stdout": "\n".join(all_stdout),
                    "stderr": "\n".join(all_stderr),
                    "exit_code": -1,
                    "duration_ms": int((time.time() - start_time) * 1000),
                    "timed_out": True,
                    "commands_completed": i,
                    "commands_total": len(commands),
                }

            try:
                import signal
                import tempfile as _tempfile
                # PIPE 버퍼 데드락 방지: tempfile 리다이렉트 + proc.wait(timeout)
                # communicate(timeout=) 은 WSL2 PIPE 버퍼 가득 찰 시 timeout 미발동 버그 있음
                _out_fd, _out_path = _tempfile.mkstemp(suffix='.stdout', dir=_bg_log_dir())
                _err_fd, _err_path = _tempfile.mkstemp(suffix='.stderr', dir=_bg_log_dir())
                try:
                    import contextlib as _contextlib
                    with _contextlib.ExitStack() as _stack:
                        _out_f = _stack.enter_context(os.fdopen(_out_fd, 'w'))
                        _err_f = _stack.enter_context(os.fdopen(_err_fd, 'w'))
                        proc = subprocess.Popen(
                            cmd,
                            shell=True,
                            stdin=subprocess.DEVNULL,
                            stdout=_out_f,
                            stderr=_err_f,
                            cwd=working_dir,
                            env=exec_env,
                            start_new_session=True,
                        )
                    # ExitStack 종료 시 _out_f/_err_f 자동 close (Popen 실패 시도 포함)
                    try:
                        proc.wait(timeout=min(remaining_timeout, timeout_sec))
                    except subprocess.TimeoutExpired:
                        # FIX-FG-01b: timeout 시 D-state(Disk Sleep) 여부 진단 로깅
                        _log_d_state(proc.pid, "fg_timeout_pre_sigterm")
                        # 프로세스 그룹 전체 종료 (손자 프로세스 포함)
                        try:
                            os.killpg(proc.pid, signal.SIGTERM)
                        except (ProcessLookupError, PermissionError, OSError):
                            pass
                        try:
                            proc.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            try:
                                os.killpg(proc.pid, signal.SIGKILL)
                            except (ProcessLookupError, PermissionError, OSError):
                                pass
                            try:
                                proc.wait(timeout=5)
                            except subprocess.TimeoutExpired:
                                # FIX-FG-01b: SIGKILL 후에도 살아있는 orphan은 D-state일 가능성이 매우 높음
                                _log_d_state(proc.pid, "fg_orphan_post_sigkill")
                                sys.stderr.write(f"[oio] fg pid={proc.pid} still alive after SIGKILL (orphan)\n")
                                sys.stderr.flush()
                                return {
                                    "success": False,
                                    "error": "ORPHAN_TIMEOUT",
                                    "message": f"명령 타임아웃 후 프로세스가 SIGKILL에도 종료되지 않았습니다 (orphan, pid={proc.pid}). 5초 내 미종료.",
                                    "stdout": "",
                                    "stderr": f"[oio] Command timed out and process is orphaned (pid={proc.pid}). SIGKILL did not terminate within 5s.",
                                    "exit_code": -1,
                                    "timed_out": True,
                                    "failed_command": cmd[:200],
                                    "commands_completed": i,
                                    "commands_total": len(commands),
                                }
                        with open(_out_path, 'r', errors='replace') as _f:
                            _partial_out = _f.read()
                        with open(_err_path, 'r', errors='replace') as _f:
                            _partial_err = _f.read()
                        return {
                            "success": False,
                            "error": "TIMEOUT",
                            "message": f"명령 {i+1}/{len(commands)} 타임아웃: {cmd[:80]}",
                            "stdout": "\n".join(all_stdout + [_partial_out]),
                            "stderr": "\n".join(all_stderr + [_partial_err]),
                            "exit_code": -1,
                            "duration_ms": int((time.time() - start_time) * 1000),
                            "timed_out": True,
                            "failed_command": cmd[:200],
                            "commands_completed": i,
                            "commands_total": len(commands),
                        }
                    with open(_out_path, 'r', errors='replace') as _f:
                        stdout = _f.read()
                    with open(_err_path, 'r', errors='replace') as _f:
                        stderr = _f.read()
                finally:
                    try:
                        os.unlink(_out_path)
                    except OSError:
                        pass
                    try:
                        os.unlink(_err_path)
                    except OSError:
                        pass

                # subprocess.run 호환 결과 구성
                class _Result:
                    pass
                result = _Result()
                result.stdout = stdout
                result.stderr = stderr
                result.returncode = proc.returncode
            except subprocess.TimeoutExpired:
                raise  # 내부 communicate timeout은 위에서 처리됨
            except OSError as e:
                return {
                    "success": False,
                    "error": "EXEC_ERROR",
                    "message": f"명령 실행 실패: {e}",
                    "duration_ms": int((time.time() - start_time) * 1000),
                    "timed_out": False,
                }

            all_stdout.append(result.stdout)
            all_stderr.append(result.stderr)
            last_exit_code = result.returncode

            # && 의미론: 이전 명령 실패(exit != 0) → 중단
            if result.returncode != 0:
                break

        duration_ms = int((time.time() - start_time) * 1000)

        response = {
            "success": last_exit_code == 0,
            "stdout": "\n".join(all_stdout),
            "stderr": "\n".join(all_stderr),
            "exit_code": last_exit_code,
            "duration_ms": duration_ms,
            "timed_out": False,
            "commands_total": len(commands),
        }

        if sensitive:
            response["warnings"] = [
                f"민감한 환경변수 참조 감지: {p}" for p in sensitive
            ]

        # ── 출력 필터 훅 (1~2단계: 항상 no-op) — orphan_guard 호출부와 동일한 fail-open 패턴 ──
        try:
            import output_filter as _output_filter
            response = _output_filter.maybe_apply(command, response)
        except Exception:
            pass  # 필터 실패는 명령 결과를 훼손하지 않는다 — fail-open

        return response

    except Exception as e:
        duration_ms = int((time.time() - start_time) * 1000)
        return {
            "success": False,
            "error": "EXEC_ERROR",
            "message": f"명령 실행 실패: {e}",
            "duration_ms": duration_ms,
            "timed_out": False,
        }
