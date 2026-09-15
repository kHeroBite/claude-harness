"""
Intent Lock 관리자.
폴더/파일(mkdir 기반) Lock. 세션 단위 파일 선점, FIFO 대기열, Auto-Heartbeat.
2계층 Lock 구조의 Layer 1: 세션 수준 파일 선점 관리.
"""
import os
import sys
import time
import hashlib
import shutil
import signal
import atexit
import threading
import logging

def _claude_config_dir():
    """CLAUDE_CONFIG_DIR 환경변수 우선, 없으면 ~/.claude (multi-account 격리용)."""
    return os.environ.get('CLAUDE_CONFIG_DIR') or os.path.expanduser('~/.claude')

# 레거시 heartbeat 데몬 제거됨 — startup-janitor + SessionStart.sh로 대체 (2026-04-15)

# ── 상수 ──────────────────────────────────────────────────────────
# F7 (jury V4 C): .claude/hooks/lib/const.py 단일 출처 로드. 실패 시 하드코딩 fallback.
# 불변식: LOCK_STALE_TTL_SEC > UX_STALE_DISPLAY_SEC ("LOCK > UX")
try:
    _CONST_PATH = os.path.join(_claude_config_dir(), "hooks/lib/const.py")
    if os.path.isfile(_CONST_PATH):
        import importlib.util as _ilu
        _spec = _ilu.spec_from_file_location("_oio_const", _CONST_PATH)
        _const = _ilu.module_from_spec(_spec)
        _spec.loader.exec_module(_const)
        HEARTBEAT_TTL = _const.LOCK_STALE_TTL_SEC
        _IMPLICIT_TTL = _const.UX_STALE_DISPLAY_SEC
    else:
        HEARTBEAT_TTL = 600
        _IMPLICIT_TTL = 300
except Exception:
    HEARTBEAT_TTL = 600
    _IMPLICIT_TTL = 300
assert HEARTBEAT_TTL > _IMPLICIT_TTL, "F7 불변식 위반: LOCK > UX"
_IMPLICIT_PREFIX = "_implicit_"
_CACHE_TTL = 10.0  # 단일 세션 fast-path 캐시 TTL (초)

# Codex N2: lock store는 **ext4 전용** (~/.claude). DrvFs(/mnt/c/*)에 lock 생성 금지.
# 이유: WSL2 DrvFs는 rename atomicity 비보장, AV 간섭, 성능 저하.
_LOCK_BASE = os.path.join(_claude_config_dir(), "oio-locks")
_FILES_DIR = os.path.join(_LOCK_BASE, "files")
_SESSIONS_DIR = os.path.join(_LOCK_BASE, "sessions")

# ── 모듈 레벨 상태 ────────────────────────────────────────────────
_owner_cache: dict = {}  # {abs_path: last_verified_time}
_implicit_map: dict = {}  # {abs_path: (session_id, acquired_at)}
_IMPLICIT_MAP_TTL = 1800  # 30분 이상 된 implicit 항목 정리
_fs_lock = threading.RLock()  # 재진입 가능 Lock (signal handler 안전)

# 기본 디렉토리 생성
try:
    os.makedirs(_FILES_DIR, exist_ok=True)
    os.makedirs(_SESSIONS_DIR, exist_ok=True)
except PermissionError as e:
    logging.error("oio-locks 디렉토리 생성 실패 (권한 부족): %s", e)
    # 서버 시작은 계속 — Lock 기능만 비활성화

# 레거시 heartbeat 데몬 제거됨 — startup-janitor + SessionStart.sh로 대체 (2026-04-15)


# ══════════════════════════════════════════════════════════════════
#  경로 헬퍼
# ══════════════════════════════════════════════════════════════════

def _file_hash(abs_path: str) -> str:
    """파일 경로 → 16자 해시 (Lock 디렉토리명)."""
    normalized = os.path.abspath(abs_path)
    # NTFS 대소문자 무시 — 동일 파일에 동일 해시 보장
    if normalized.startswith("/mnt/") and len(normalized) > 6 and normalized[5].isalpha():
        normalized = normalized.lower()
    return hashlib.sha256(normalized.encode()).hexdigest()[:16]


def _lock_dir(fh: str) -> str:
    """Codex CR-1: lockdir 개념 제거 — 부모 디렉토리만 의미.
    _FILES_DIR/{fh}는 queue 등을 담는 parent dir로만 존재 (owner 파일과 queue 디렉토리 공존).
    """
    return os.path.join(_FILES_DIR, fh)


def _owner_path(fh: str) -> str:
    """단일 authoritative owner 파일 경로 (Codex CR-1).
    _FILES_DIR/{fh}/owner — 파일 자체 존재가 lock 획득을 의미.
    """
    return os.path.join(_FILES_DIR, fh, "owner")


def _queue_dir(fh: str) -> str:
    return os.path.join(_FILES_DIR, fh, "queue")


# Grace age: 빈/부분 파일을 stale로 오판하지 않는 보호 구간 (초)
# Codex CR-1: atomic write 도중 다른 경쟁자가 stale 오판 차단
_GRACE_AGE_SECONDS = 0.5


def _session_dir(sid: str) -> str:
    return os.path.join(_SESSIONS_DIR, sid)


def _session_files_path(sid: str) -> str:
    return os.path.join(_SESSIONS_DIR, sid, "files")


def _session_meta_path(sid: str) -> str:
    return os.path.join(_SESSIONS_DIR, sid, "meta")


# ══════════════════════════════════════════════════════════════════
#  파일 I/O 헬퍼
# ══════════════════════════════════════════════════════════════════

def _read_kv(path: str) -> dict | None:
    """key=value 형식 파일 읽기. 파일 없으면 None."""
    try:
        with open(path, "r") as f:
            data = {}
            for line in f:
                line = line.strip()
                if "=" in line:
                    k, v = line.split("=", 1)
                    data[k] = v
            return data
    except (FileNotFoundError, IOError, PermissionError):
        return None


def _write_kv(path: str, data: dict):
    """key=value 형식 파일 원자적 쓰기 (tmp→os.replace 패턴)."""
    import tempfile
    dir_ = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=dir_, prefix=".tmp_kv_")
    try:
        with os.fdopen(fd, "w") as f:
            for k, v in data.items():
                f.write(f"{k}={v}\n")
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except Exception:
            pass
        raise


def _read_owner(fh: str) -> dict | None:
    """owner 파일 읽기. Codex CR-1: 단일 authoritative 파일만 확인 (owner.tmp 개념 제거).
    빈/부분 파일은 grace age 내면 '쓰기 진행 중'으로 간주되므로 _cleanup_stale_lock에서 처리.
    """
    return _read_kv(_owner_path(fh))


def _atomic_create_owner(fh: str, pid: int, sid: str,
                         abs_path: str = "", implicit: bool = False) -> bool:
    """O_CREAT|O_EXCL owner 파일 원자 생성. Codex CR-1: 획득+publish 단일 연산.
    반환: 성공=True, 이미 존재=False, 기타 에러는 raise.
    """
    data = {
        "pid": str(pid),
        "session": sid,
        "time": str(int(time.time())),
        "path": abs_path,
    }
    if implicit:
        data["implicit"] = "true"

    os.makedirs(_lock_dir(fh), exist_ok=True)
    owner_path = _owner_path(fh)
    fd = None
    try:
        fd = os.open(owner_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError:
        return False
    try:
        content = "".join(f"{k}={v}\n" for k, v in data.items()).encode("utf-8")
        os.write(fd, content)
        os.fsync(fd)
        return True
    except Exception:
        # cleanup ladder: 쓰기 실패 시 빈 파일 방치 금지
        try:
            os.remove(owner_path)
        except Exception:
            pass
        raise
    finally:
        if fd is not None:
            try:
                os.close(fd)
            except Exception:
                pass


def _write_owner(fh: str, pid: int, sid: str,
                 abs_path: str = "", implicit: bool = False):
    """owner 파일 교체 쓰기 (보유자 업데이트 용). Codex CR-1: atomic rename.
    원자 생성(_atomic_create_owner)과 달리 '이미 보유한' 상태에서 갱신 전용.
    """
    data = {
        "pid": str(pid),
        "session": sid,
        "time": str(int(time.time())),
        "path": abs_path,
    }
    if implicit:
        data["implicit"] = "true"
    owner_path = _owner_path(fh)
    tmp_path = owner_path + ".tmp"
    for attempt in range(2):
        try:
            os.makedirs(_lock_dir(fh), exist_ok=True)
            with open(tmp_path, "w") as f:
                for k, v in data.items():
                    f.write(f"{k}={v}\n")
            os.replace(tmp_path, owner_path)
            return
        except FileNotFoundError:
            if attempt == 0:
                continue  # 디렉토리 재생성 후 1회 재시도
            raise


def _read_session_meta(sid: str) -> dict | None:
    """세션 메타데이터 읽기."""
    return _read_kv(_session_meta_path(sid))


def _write_session_meta(sid: str, pid: int, classification: str = None):
    """세션 메타데이터 쓰기."""
    now = str(int(time.time()))
    data = {"pid": str(pid), "created_at": now, "heartbeat_at": now}
    if classification:
        data["classification"] = classification
    os.makedirs(_session_dir(sid), exist_ok=True)
    _write_kv(_session_meta_path(sid), data)


def _update_heartbeat_meta(sid: str):
    """세션 heartbeat 갱신."""
    meta = _read_session_meta(sid)
    if meta:
        meta["heartbeat_at"] = str(int(time.time()))
        _write_kv(_session_meta_path(sid), meta)


def _get_session_files(sid: str) -> list[tuple[str, str]]:
    """세션이 보유한 파일 목록. [(file_hash, abs_path), ...]"""
    path = _session_files_path(sid)
    result = []
    try:
        with open(path, "r") as f:
            for line in f:
                line = line.strip()
                if "\t" in line:
                    h, p = line.split("\t", 1)
                    result.append((h, p))
    except (FileNotFoundError, IOError):
        pass
    return result


def _add_session_file(sid: str, fh: str, abs_path: str):
    """세션 파일 목록에 추가 (원자적 쓰기 — tmp→os.replace 패턴)."""
    import tempfile
    existing = dict(_get_session_files(sid))
    existing[fh] = abs_path
    dest = _session_files_path(sid)
    dir_ = os.path.dirname(dest) or "."
    try:
        fd, tmp = tempfile.mkstemp(dir=dir_, prefix=".tmp_sf_")
        try:
            with os.fdopen(fd, "w") as f:
                for h, p in existing.items():
                    f.write(f"{h}\t{p}\n")
            os.replace(tmp, dest)
        except Exception:
            try:
                os.unlink(tmp)
            except Exception:
                pass
            raise
    except IOError as e:
        logging.warning("세션 파일 목록 추가 실패: %s", e)


def _remove_session_file(sid: str, fh: str):
    """세션 파일 목록에서 제거."""
    files = _get_session_files(sid)
    try:
        with open(_session_files_path(sid), "w") as f:
            for h, p in files:
                if h != fh:
                    f.write(f"{h}\t{p}\n")
    except (FileNotFoundError, IOError):
        pass


def _is_pid_alive(pid: int) -> bool:
    """PID 생존 확인. pid<=0은 특수값(전체/그룹)이라 죽은 것으로 간주."""
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except PermissionError:
        return True  # EPERM = 프로세스 존재 (다른 사용자 소유)
    except (ProcessLookupError, OSError):
        return False


def _error(code: str, message: str, **kwargs) -> dict:
    """에러 응답 생성 헬퍼."""
    result = {"success": False, "error": code, "message": message}
    result.update(kwargs)
    return result


# ══════════════════════════════════════════════════════════════════
#  Lock 기본 연산
# ══════════════════════════════════════════════════════════════════

def _try_acquire_lock(fh: str, sid: str, pid: int,
                      abs_path: str = "", implicit: bool = False) -> bool:
    """owner 파일 O_CREAT|O_EXCL 단일 원자 연산 (Codex CR-1).
    순수 획득 시도만 수행 (I/O 없음). 성공=True, 이미 존재=False.

    L-362: 이 함수는 _fs_lock 보유 중 호출 가능하도록 설계되었으므로
    내부에서 _cleanup_stale_lock 등 파일 I/O를 수행해서는 안 됨.
    stale 정리는 호출자가 _fs_lock 밖에서 먼저 수행해야 한다.

    이전 구조(mkdir+ownerfile 2단계)의 race window 제거:
    - 획득과 publish가 단일 O_CREAT|O_EXCL 호출로 통합됨
    - 다른 경쟁자는 owner 파일 존재만 보면 됨 (lock_dir 별도 불필요)
    """
    try:
        created = _atomic_create_owner(fh, pid, sid, abs_path, implicit)
    except OSError:
        # 권한/경로 문제 — 실패
        return False
    if created:
        # queue 디렉토리 준비 (owner 획득 이후 idempotent 생성)
        try:
            os.makedirs(_queue_dir(fh), exist_ok=True)
        except OSError:
            pass
        return True
    # 이미 존재 — stale 정리는 호출자 책임 (L-362: 여기서 I/O 금지)
    return False


def _release_lock(fh: str):
    """owner 파일만 unlink (Codex CR-1: 단일 authoritative object).
    queue 디렉토리와 부모 디렉토리는 유지 (다른 대기자가 있을 수 있음).
    """
    try:
        os.remove(_owner_path(fh))
    except FileNotFoundError:
        pass
    except OSError:
        pass


def _enqueue(fh: str, sid: str) -> int:
    """대기열에 추가. 반환: position (1-based)."""
    qdir = _queue_dir(fh)
    os.makedirs(qdir, exist_ok=True)

    try:
        entries = sorted(os.listdir(qdir))
    except FileNotFoundError:
        entries = []

    # 이미 등록됐는지 확인
    for i, entry in enumerate(entries):
        if "#" in entry and entry.split("#", 1)[1] == sid:
            return i + 1

    # 새 항목 추가
    entry_name = f"{int(time.time()):010d}#{sid}"
    try:
        with open(os.path.join(qdir, entry_name), "w") as f:
            f.write(f"enqueued_at={int(time.time())}\n")
    except IOError:
        pass

    return len(entries) + 1


def _dequeue(fh: str, sid: str):
    """대기열에서 제거."""
    qdir = _queue_dir(fh)
    try:
        for entry in os.listdir(qdir):
            if "#" in entry and entry.split("#", 1)[1] == sid:
                try:
                    os.remove(os.path.join(qdir, entry))
                except FileNotFoundError:
                    pass
                return
    except FileNotFoundError:
        pass


def _get_next_live_waiter(fh: str) -> tuple[str, int] | None:
    """살아있는 다음 대기자 반환. (session_id, pid) 또는 None."""
    qdir = _queue_dir(fh)
    try:
        entries = sorted(os.listdir(qdir))
    except FileNotFoundError:
        return None

    for entry in entries:
        if "#" not in entry:
            continue
        waiter_sid = entry.split("#", 1)[1]
        meta = _read_session_meta(waiter_sid)
        if meta:
            waiter_pid = int(meta.get("pid", -1))
            if _is_pid_alive(waiter_pid):
                return (waiter_sid, waiter_pid)
            else:
                # 죽은 대기자 제거
                try:
                    os.remove(os.path.join(qdir, entry))
                except OSError:
                    pass
        else:
            # 세션 메타 없음 — 깨진 항목 제거
            try:
                os.remove(os.path.join(qdir, entry))
            except OSError:
                pass

    return None


# ══════════════════════════════════════════════════════════════════
#  Stale 정리
# ══════════════════════════════════════════════════════════════════

def _cleanup_stale_lock(fh: str) -> bool:
    """단일 Lock Stale 확인 + 정리. 정리됐으면 True.
    Codex CR-1: grace age 방식 — owner 파일 mtime < 0.5s면 쓰기 진행 중 추정.
    """
    owner_path = _owner_path(fh)

    # grace age 검사 (빈/부분 owner 파일 보호)
    try:
        st = os.stat(owner_path)
        if (time.time() - st.st_mtime) < _GRACE_AGE_SECONDS:
            # 최근 생성 — 쓰기 진행 중 추정, 정리 스킵
            return False
    except FileNotFoundError:
        # owner 없음 → lock 미보유 (정리 필요 없음)
        return True
    except OSError:
        return False

    owner = _read_owner(fh)
    if owner is None:
        # 파일은 있지만 내용 비었거나 손상 — grace 지났으면 orphan
        try:
            os.remove(owner_path)
        except OSError:
            pass
        return True

    pid = int(owner.get("pid", -1))
    sid = owner.get("session", "")
    lock_time = int(owner.get("time", 0))
    now = int(time.time())

    is_stale = False

    # pid 우선 — 명시 세션은 pid 살아있으면 절대 stale 아님
    # (heartbeat 데몬 제거와 동반 — cross-session lock 도난 방지)
    if not _is_pid_alive(pid):
        is_stale = True
    elif sid.startswith(_IMPLICIT_PREFIX):
        # implicit 세션만 UX TTL 적용 (짧은 라이프사이클)
        meta = _read_session_meta(sid)
        hb = int(meta.get("heartbeat_at", lock_time)) if meta else lock_time
        if (now - hb) > _IMPLICIT_TTL:
            is_stale = True
    # 명시 세션(session_begin 호출)은 pid 살아있는 한 절대 stale 아님

    if is_stale:
        _force_release_lock(fh, sid)
        return True

    return False


def _cleanup_dead_waiters(fh: str):
    """대기열에서 죽은 waiter만 정리 (Lock 디렉토리는 건드리지 않음)."""
    qdir = _queue_dir(fh)
    try:
        for entry in os.listdir(qdir):
            if "#" not in entry:
                continue
            waiter_sid = entry.split("#", 1)[1]
            meta = _read_session_meta(waiter_sid)
            if not meta or not _is_pid_alive(int(meta.get("pid", -1))):
                try:
                    os.remove(os.path.join(qdir, entry))
                except FileNotFoundError:
                    pass
    except FileNotFoundError:
        pass


def _force_release_lock(fh: str, sid: str):
    """Lock 강제 해제 + FIFO 양도. waiter 양도 시 rmtree 대신 owner만 교체.

    L-362 주의: 이 함수는 _fs_lock 미보유 상태에서만 호출해야 한다.
    내부에서 os.stat/os.kill/os.remove/_add_session_file 등 파일 I/O를 수행하므로
    _fs_lock 보유 중 호출 시 L-362 위반이 발생한다.
    호출자: _cleanup_stale_lock (lock 밖에서 호출됨) — 확인됨.
    """
    owner = _read_owner(fh)
    abs_path = owner.get("path", "") if owner else ""

    _cleanup_dead_waiters(fh)

    waiter = _get_next_live_waiter(fh)
    if waiter:
        next_sid, next_pid = waiter
        _dequeue(fh, next_sid)
        _write_owner(fh, next_pid, next_sid, abs_path)
        # _add_session_file: Phase 1(FIX-02)에서 원자화됨 (tmp→os.replace)
        _add_session_file(next_sid, fh, abs_path)
    else:
        _release_lock(fh)

    _remove_session_file(sid, fh)


def _collect_stale_listdir_snapshot() -> tuple:
    """Phase A (lock 안): listdir 스냅샷만 수집. I/O는 listdir 1회/디렉토리.
    반환: (fh_dirs, sids) — 이후 lock 밖에서 _classify_stale_targets로 분류.
    """
    fh_dirs = []
    sids = []
    try:
        fh_dirs = list(os.listdir(_FILES_DIR))
    except FileNotFoundError:
        pass
    try:
        sids = list(os.listdir(_SESSIONS_DIR))
    except FileNotFoundError:
        pass
    return fh_dirs, sids


def _classify_stale_targets(fh_dirs: list, sids: list) -> tuple:
    """Phase B (lock 밖): meta read + stale 판정. 무거운 파일 I/O는 여기서만.
    반환: (stale_fh_list, stale_fh_dirs, stale_session_dirs)
      - stale_fh_list: owner 있는 stale fh 목록 (실제 _cleanup_stale_lock은 lock 밖에서)
      - stale_fh_dirs: owner 없는 빈 락 디렉토리 목록 (삭제 대상)
      - stale_session_dirs: 고아 세션 디렉토리 목록 (삭제 대상)
    L-362 원칙: 파일 I/O (meta read / owner 확인)는 lock 밖에서 수행.
    """
    stale_fh_list = []
    stale_fh_dirs = []
    stale_session_dirs = []

    # 1. 모든 Lock 확인 (owner 파일 existence + queue 확인)
    for fh in fh_dirs:
        fh_dir = os.path.join(_FILES_DIR, fh)
        if not os.path.isdir(fh_dir):
            continue
        if os.path.exists(_owner_path(fh)):
            # _cleanup_stale_lock 호출 대상 — 실제 호출은 이후 lock 밖에서
            stale_fh_list.append(fh)
        else:
            qdir = _queue_dir(fh)
            has_queue = os.path.isdir(qdir) and os.listdir(qdir)
            if not has_queue:
                stale_fh_dirs.append(fh_dir)

    # 2. 고아 세션 수집 (PID 사망 + Lock 없음) — meta read 포함
    for sid in sids:
        sdir = _session_dir(sid)
        if not os.path.isdir(sdir):
            continue
        meta = _read_session_meta(sid)
        if not meta or not _is_pid_alive(int(meta.get("pid", -1))):
            stale_session_dirs.append(sdir)

    return stale_fh_list, stale_fh_dirs, stale_session_dirs


def _cleanup_all_stale():
    """모든 Stale Lock + 고아 세션 + 빈 락 디렉토리 + TTL 만료 implicit_map 정리.
    주의: _fs_lock 보유 중 호출 금지 — 내부에서 lock을 획득하므로 데드락 발생.
    lock 밖에서 호출하거나 maybe_cleanup_stale 경유로 사용하라.
    """
    # Phase A (lock 안): listdir 스냅샷 + implicit_map TTL 판정 (v2 P5)
    with _fs_lock:
        fh_dirs, sids = _collect_stale_listdir_snapshot()

        # TTL 만료 implicit_map 항목 수집 (dict op만)
        now = time.time()
        stale_implicit_paths = [
            path for path, (_, acquired_at) in list(_implicit_map.items())
            if (now - acquired_at) > _IMPLICIT_MAP_TTL
        ]

    # Phase B (lock 밖): meta read + stale 분류 (무거운 I/O)
    stale_fh_list, stale_fh_dirs, stale_session_dirs = _classify_stale_targets(fh_dirs, sids)

    # stale lock 정리 (lock 밖에서 — _cleanup_stale_lock이 파일 I/O 수행)
    for fh in stale_fh_list:
        try:
            _cleanup_stale_lock(fh)
        except Exception:
            pass

    # 실제 삭제 (lock 밖에서 — shutil.rmtree가 lock 보유 중 실행되지 않도록)
    for fh_dir in stale_fh_dirs:
        try:
            shutil.rmtree(fh_dir, ignore_errors=True)
        except OSError:
            pass
    for sdir in stale_session_dirs:
        try:
            shutil.rmtree(sdir, ignore_errors=True)
        except OSError:
            pass

    # TTL 만료 implicit 세션 해제 (lock 밖에서 — implicit_release가 session_end 호출)
    for path in stale_implicit_paths:
        try:
            implicit_release(path)
        except Exception as e:
            logging.debug("stale implicit_map 정리 예외: %s", e)


# ══════════════════════════════════════════════════════════════════
#  주기적 Stale 정리 (time-based debounce)
# ══════════════════════════════════════════════════════════════════

_op_counter = 0
_CLEANUP_INTERVAL = 100
_last_cleanup_time: float = 0.0
_CLEANUP_DEBOUNCE_SECONDS = 60  # 60초 이내 중복 실행 방지


def maybe_cleanup_stale():
    """100회 연산마다 전체 stale 정리 실행. 60초 debounce로 과도한 정리 방지."""
    global _op_counter, _last_cleanup_time
    do_cleanup = False
    with _fs_lock:
        _op_counter += 1
        if _op_counter >= _CLEANUP_INTERVAL:
            _op_counter = 0
            now = time.time()
            if (now - _last_cleanup_time) >= _CLEANUP_DEBOUNCE_SECONDS:
                _last_cleanup_time = now
                do_cleanup = True
    # lock 밖에서 실행 (_cleanup_all_stale 내부에서 lock 획득)
    if do_cleanup:
        _cleanup_all_stale()


# ══════════════════════════════════════════════════════════════════
#  대기열 폴링
# ══════════════════════════════════════════════════════════════════

def _poll_queue(session_id: str, queued_files: list,
                deadline: float) -> tuple:
    """대기열 파일 획득 폴링. (acquired, still_queued) 반환."""
    acquired = []
    still_queued = list(queued_files)

    while still_queued and time.time() < deadline:
        remaining = deadline - time.time()
        if remaining <= 0:
            break
        time.sleep(min(0.2, remaining))

        # L-362: lock 밖에서 stale 정리 수행 (파일 I/O 포함)
        stale_candidates = list(still_queued)
        for fpath in stale_candidates:
            fh = _file_hash(fpath)
            try:
                _cleanup_stale_lock(fh)
            except Exception:
                pass

        # L-362: _try_acquire_lock은 순수 획득만 수행 (FIX-04 이후 I/O 없음).
        # _add_session_file은 파일 I/O이므로 lock 밖에서 실행해야 함.
        # 패턴: lock 안에서 획득 결과 목록 수집 → lock 밖에서 _add_session_file 일괄 처리
        # audit-whitelist: L718-poll-race — TODO: race 수용 — whitelist 정책
        # (v2 P4 INTENTIONAL 유지: stale cleanup 후 재확인 race window 허용)
        with _fs_lock:
            newly_acquired = []
            for fpath in still_queued:
                fh = _file_hash(fpath)
                # L-362: lock 안에서는 _read_owner 확인 + _try_acquire_lock(I/O 없음)만
                # stale 정리는 위에서 완료됨
                owner = _read_owner(fh)

                if owner is None:
                    # Lock 비어있음 — 직접 획득 시도 (_try_acquire_lock은 I/O 없음: FIX-04)
                    if _try_acquire_lock(fh, session_id, os.getpid(), fpath):
                        newly_acquired.append(fpath)
                elif owner.get("session") == session_id:
                    # 이미 양도받음
                    newly_acquired.append(fpath)

        # L-362: _add_session_file은 파일 I/O — lock 밖에서 수행
        for fpath in newly_acquired:
            fh = _file_hash(fpath)
            _add_session_file(session_id, fh, fpath)
            still_queued.remove(fpath)
            acquired.append(fpath)

    return acquired, still_queued


# ══════════════════════════════════════════════════════════════════
#  4.1 session_begin
# ══════════════════════════════════════════════════════════════════

def session_begin(session_id: str, files: list,
                  classification: str = None,
                  mode: str = "strict",
                  wait_seconds: int = 5) -> dict:
    """
    세션 시작 + 파일 Intent Lock 획득.

    Args:
        session_id: 세션 고유 ID (예: PIPELINE_UUID)
        files: 선점할 파일 경로 목록
        classification: "O1"~"O5" 또는 None
        mode: "strict" (전체 롤백) | "partial" (가용 파일만 획득)
        wait_seconds: 대기열 최대 대기 시간 (0 = 즉시 실패, 기본값 5초)

    Returns:
        성공/실패 dict (acquired, queued, conflicts 포함)
    """
    files = [os.path.abspath(f) for f in files]
    now = int(time.time())
    deadline = now + wait_seconds

    # stale 정리 (lock 밖에서 먼저 실행 — shutil.rmtree를 lock 안에서 실행하지 않기 위함)
    maybe_cleanup_stale()

    try:
        # ── Phase A: _fs_lock 안에서 상태 확인 + 획득/충돌 목록 수집만 ──────────
        # L-362: _write_session_meta/_update_heartbeat_meta/_add_session_file/_enqueue는
        # 파일 I/O이므로 lock 밖에서 실행해야 함. lock 안에서는 플래그/목록 수집만.
        _session_action = None   # "reentry" | "new" | "conflict_pid"
        _conflict_pid = -1
        _acquired_in_lock = []   # lock 안에서 _try_acquire_lock 성공 목록
        _already_owned = []      # 자기 세션이 이미 보유
        _to_enqueue = []         # (fh, fpath, holder_session, holder_pid) — lock 밖에서 _enqueue
        _stale_fh_list = []      # lock 밖에서 stale 정리 + 재시도

        # Phase A pre-snapshot (lock 밖, v2 P2): meta + owner N회를 lock 밖에서 read
        meta = _read_session_meta(session_id)
        if meta:
            existing_pid = int(meta.get("pid", -1))
            if existing_pid == os.getpid():
                _session_action = "reentry"
            else:
                _session_action = "conflict_pid"
                _conflict_pid = existing_pid
        else:
            _session_action = "new"

        if _session_action == "conflict_pid":
            # 다른 PID 세션 존재 — 즉시 반환 (I/O 불필요)
            return _error(
                "SESSION_EXISTS",
                f"동일 session_id로 이미 활성 세션 존재 (PID={_conflict_pid})",
                session_id=session_id,
                existing_pid=_conflict_pid,
            )

        # pre-snapshot: 각 파일의 owner를 lock 밖에서 미리 read
        _pre_file_hashes = {fpath: _file_hash(fpath) for fpath in files}
        _pre_owners = {
            fpath: _read_owner(_pre_file_hashes[fpath]) for fpath in files
        }

        with _fs_lock:
            # 2. 파일별 충돌 검사 — lock 안에서는 _try_acquire_lock(I/O 없음)만
            # TOCTOU: owner 스냅샷은 lock 밖에서 read, lock 안에서 _try_acquire_lock이
            # 실제 원자 획득을 수행. 획득 실패 시 stale 재시도 경로로 흘러가므로 안전.
            for fpath in files:
                fh = _pre_file_hashes[fpath]
                owner = _pre_owners.get(fpath)

                if owner is None:
                    # 비어있음 → 즉시 획득 시도 (_try_acquire_lock은 I/O 없음: FIX-04)
                    if _try_acquire_lock(fh, session_id, os.getpid(), fpath):
                        _acquired_in_lock.append((fh, fpath))
                    else:
                        # 경합 — stale 정리 후 재시도 목록 (L-362: lock 밖에서)
                        _stale_fh_list.append((fh, fpath))
                elif owner.get("session") == session_id:
                    # 자기 자신 → 이미 보유
                    _already_owned.append(fpath)
                else:
                    # 충돌 → lock 밖에서 _enqueue 실행할 목록 수집
                    _to_enqueue.append((
                        fh, fpath,
                        owner.get("session", "unknown"),
                        int(owner.get("pid", -1)),
                    ))

        # ── Phase B: lock 밖에서 파일 I/O 수행 ──────────────────────────────────
        # L-362: _write_session_meta/_update_heartbeat_meta/_add_session_file/_enqueue
        # 모두 파일 I/O — lock 해제 후 실행.

        # 1. 세션 메타 처리
        if _session_action == "reentry":
            _update_heartbeat_meta(session_id)
        else:
            # "new" — 세션 디렉토리 + 메타 생성
            _write_session_meta(session_id, os.getpid(), classification)

        # 2. 획득 파일 session_files 등록
        acquired = list(_already_owned)
        for fh, fpath in _acquired_in_lock:
            _add_session_file(session_id, fh, fpath)
            acquired.append(fpath)

        # 3. 충돌 파일 대기열 등록
        queued = []
        conflicts = []
        for fh, fpath, holder_sid, holder_pid in _to_enqueue:
            pos = _enqueue(fh, session_id)
            conflicts.append({
                "file": fpath,
                "holder_session": holder_sid,
                "holder_pid": holder_pid,
                "queue_position": pos,
            })
            queued.append(fpath)

        # 4. stale 재시도 — v2 P2' two-phase:
        # _cleanup_stale_lock (lock 밖 I/O) → owner pre-read (lock 밖) →
        # _try_acquire_lock만 lock 안에서 수행.
        stale_fh_list = _stale_fh_list  # 이름 통일
        for fh, fpath in stale_fh_list:
            cleaned = _cleanup_stale_lock(fh)
            # pre-snapshot owner (lock 밖, P2')
            _pre_retry_owner = None if cleaned else _read_owner(fh)
            _retry_acquired = False
            with _fs_lock:
                if cleaned:
                    _retry_acquired = _try_acquire_lock(fh, session_id, os.getpid(), fpath)
            if _retry_acquired:
                owner = None  # 획득 성공 — owner 확인 불필요
            else:
                owner = _pre_retry_owner
            # lock 밖에서 I/O 처리
            if _retry_acquired:
                _add_session_file(session_id, fh, fpath)
                acquired.append(fpath)
            elif owner and owner.get("session") == session_id:
                acquired.append(fpath)
            elif owner:
                pos = _enqueue(fh, session_id)
                conflicts.append({
                    "file": fpath,
                    "holder_session": owner.get("session", "unknown"),
                    "holder_pid": int(owner.get("pid", -1)),
                    "queue_position": pos,
                })
                queued.append(fpath)

        # 3. strict 모드 롤백
        if mode == "strict" and conflicts:
            for fpath in acquired:
                fh = _file_hash(fpath)
                _release_lock(fh)
                _remove_session_file(session_id, fh)
            for fpath in queued:
                fh = _file_hash(fpath)
                _dequeue(fh, session_id)
            if not _get_session_files(session_id):
                shutil.rmtree(_session_dir(session_id), ignore_errors=True)

            return _error(
                "INTENT_CONFLICT",
                "파일 충돌로 세션 시작 실패",
                session_id=session_id,
                acquired=[],
                queued=[],
                conflicts=conflicts,
                suggestion="mode='partial'로 비충돌 파일만 먼저 작업하거나 wait_seconds를 늘리세요",
            )

        # 4. 대기열 폴링 (_fs_lock 밖에서 실행)
        if queued and wait_seconds > 0:
            acquired_from_queue, still_queued = _poll_queue(
                session_id, queued, deadline
            )
            acquired.extend(acquired_from_queue)
            queued = still_queued
            conflicts = [c for c in conflicts if c["file"] in queued]

        return {
            "success": len(queued) == 0 if mode == "strict" else True,
            "session_id": session_id,
            "acquired": acquired,
            "queued": queued,
            "conflicts": conflicts,
        }

    except Exception as e:
        logging.warning("session_begin 오류: %s", e)
        return _error("FS_ERROR", f"파일시스템 오류: {e}")


# ══════════════════════════════════════════════════════════════════
#  4.2 session_end
# ══════════════════════════════════════════════════════════════════

def session_end(session_id: str) -> dict:
    """
    세션 종료 + Intent Lock 해제 + FIFO 양도.

    Args:
        session_id: 종료할 세션 ID

    Returns:
        성공 시 released_files + transferred 목록, 실패 시 에러
    """
    try:
        # ── Phase A: lock-free 스냅샷 (v2 P0 / L-362 준수) ──
        # TOCTOU는 Phase C owner 재확인으로 방어
        meta = _read_session_meta(session_id)
        if not meta:
            return _error(
                "SESSION_NOT_FOUND",
                "활성 세션을 찾을 수 없습니다",
                session_id=session_id,
            )

        session_pid = int(meta.get("pid", -1))
        if session_pid != os.getpid():
            return _error(
                "SESSION_NOT_OWNER",
                f"PID 불일치 (세션 PID={session_pid}, 현재 PID={os.getpid()})",
                session_id=session_id,
            )

        # 1. 보유 파일 조회 (lock 밖 snapshot — v2 P0)
        held = _get_session_files(session_id)

        # 3. 대기열 해제 대상 목록 수집 (lock 밖 snapshot, _dequeue는 이후 lock 밖 실행)
        try:
            all_fh_dirs = list(os.listdir(_FILES_DIR))
        except FileNotFoundError:
            all_fh_dirs = []

        # 세션 디렉토리 경로 저장 (rmtree는 lock 밖에서)
        session_dir_to_remove = _session_dir(session_id)

        # ── Phase B: lock 밖에서 파일 I/O + os.kill (N-02: _get_next_live_waiter) ──
        released_files = []
        fh_to_release = []   # (fh, fpath, waiter_or_None)
        for fh, fpath in held:
            owner = _read_owner(fh)
            if owner and owner.get("session") == session_id:
                released_files.append(fpath)
                waiter = _get_next_live_waiter(fh)  # 파일 읽기 + os.kill — lock 밖 OK
                fh_to_release.append((fh, fpath, waiter))

        # A-01: _dequeue는 lock 밖에서 실행
        for fh_dir in all_fh_dirs:
            if os.path.exists(_owner_path(fh_dir)):
                _dequeue(fh_dir, session_id)

        # ── Phase C: _fs_lock 재획득 후 원자적 소유권 이전 (v2 P1 INTENTIONAL 유지) ──
        # audit-whitelist: L992-atomicity — 양도 원자성 목적, lock 안 I/O 의도적 유지
        transferred = []
        _warn_threshold = int(os.getenv("OIO_PHASE_C_WARN_FILES", "10"))
        _phase_c_start = time.monotonic()
        if len(fh_to_release) >= _warn_threshold:
            logging.warning(
                "session_end Phase C 대량 양도 n=%d (원자성 lock 보유)",
                len(fh_to_release),
            )
        with _fs_lock:
            for fh, fpath, waiter in fh_to_release:
                # TOCTOU 방지: Phase B 사이 상태 변경 가능 → owner 재확인
                owner = _read_owner(fh)
                if owner and owner.get("session") == session_id:
                    if waiter:
                        next_sid, next_pid = waiter
                        _dequeue(fh, next_sid)
                        _write_owner(fh, next_pid, next_sid, fpath)
                        _add_session_file(next_sid, fh, fpath)
                        transferred.append({
                            "file": fpath,
                            "new_holder": next_sid,
                        })
                    else:
                        _release_lock(fh)
        _phase_c_elapsed = time.monotonic() - _phase_c_start
        _phase_c_timeout = float(os.getenv("OIO_PHASE_C_TIMEOUT_SEC", "1.0"))
        if _phase_c_elapsed > _phase_c_timeout:
            logging.warning(
                "session_end Phase C 타임아웃 초과 elapsed=%.3fs n=%d",
                _phase_c_elapsed,
                len(fh_to_release),
            )

        # rmtree는 _fs_lock 밖에서 실행 (L-362: lock 보유 중 blocking I/O 금지)
        if session_dir_to_remove:
            shutil.rmtree(session_dir_to_remove, ignore_errors=True)

        # 캐시 무효화
        for _, fpath in held:
            invalidate_cache(fpath)

        return {
            "success": True,
            "session_id": session_id,
            "released_files": released_files,
            "transferred": transferred,
        }

    except Exception as e:
        logging.warning("session_end 오류: %s", e)
        return _error("FS_ERROR", f"파일시스템 오류: {e}")


# ══════════════════════════════════════════════════════════════════
#  4.3 Intent Gate (check_ownership, heartbeat)
# ══════════════════════════════════════════════════════════════════

def check_ownership(abs_path: str, pid: int, session_id: str = None) -> str:
    """
    파일에 대한 소유권 확인.

    Args:
        abs_path: 정규화된 절대 경로
        pid: 확인할 프로세스 PID
        session_id: 세션 ID (명시 시 session+PID 모두 확인)

    Returns:
        "OWNED" — 현재 PID의 세션이 보유
        "NOT_LOCKED" — 아무도 잡고 있지 않음
        "OTHER_SESSION" — 다른 세션이 보유 중
    """
    try:
        fh = _file_hash(abs_path)

        # L-362: _cleanup_stale_lock은 os.stat/os.kill/os.remove 포함 — _fs_lock 밖에서 실행
        if os.path.exists(_owner_path(fh)):
            _cleanup_stale_lock(fh)

        # v2 P3 two-phase: pre-read (lock 밖) → lock 안 재확인
        # audit-whitelist: L1099-recheck — lock 안 _read_owner는 race window 방어용 재확인
        _pre_owner = _read_owner(fh)
        with _fs_lock:
            owner = _read_owner(fh) if _pre_owner is not None else None
            # _pre_owner가 None이었으면 아직 주인이 없는 상태로 판단
            # (hot path 최적화 — 동시성 race window에서 새 owner가 생겨도
            # 호출측은 NOT_LOCKED로 인식. 안전 우선.)
            if owner is None:
                return "NOT_LOCKED"

            owner_sid = owner.get("session", "")
            owner_pid = int(owner.get("pid", -1))

            if session_id:
                if owner_sid == session_id and owner_pid == pid:
                    return "OWNED"
                elif owner_pid == pid:
                    return "OTHER_SESSION"  # 같은 PID 다른 세션
            else:
                if owner_pid == pid:
                    return "OWNED"  # 하위호환

            return "OTHER_SESSION"

    except Exception:
        return "NOT_LOCKED"  # Lock 시스템 오류 시 허용 (안전 우선)


def heartbeat(abs_path: str):
    """
    파일 소유 세션의 heartbeat 갱신. file_edit/file_write 시 자동 호출.

    Args:
        abs_path: 정규화된 절대 경로
    """
    try:
        fh = _file_hash(abs_path)
        owner = _read_owner(fh)
        if owner and int(owner.get("pid", -1)) == os.getpid():
            _update_heartbeat_meta(owner.get("session", ""))
    except Exception as e:
        logging.debug("heartbeat 예외: %s", e)


# ══════════════════════════════════════════════════════════════════
#  4.7 단일 세션 Fast-Path 캐시
# ══════════════════════════════════════════════════════════════════

def is_cached_owner(abs_path: str) -> bool:
    """캐시에서 소유권 확인. TTL 내 재확인 skip."""
    with _fs_lock:
        ts = _owner_cache.get(abs_path)
        return bool(ts and (time.time() - ts) < _CACHE_TTL)


def cache_owner(abs_path: str):
    """소유권 확인 결과를 캐시에 등록."""
    with _fs_lock:
        _owner_cache[abs_path] = time.time()


def invalidate_cache(abs_path: str = None):
    """캐시 무효화. abs_path=None이면 전체 캐시 클리어."""
    with _fs_lock:
        if abs_path:
            _owner_cache.pop(abs_path, None)
        else:
            _owner_cache.clear()


# ══════════════════════════════════════════════════════════════════
#  4.9 Implicit 모드
# ══════════════════════════════════════════════════════════════════

def implicit_acquire(abs_path: str) -> dict:
    """
    Implicit transient Lock 생성. session_begin 없이 직접 file_edit 등 호출 시 사용.

    Args:
        abs_path: 정규화된 절대 경로

    Returns:
        {"success": True} 또는 에러 dict
    """
    session_id = f"{_IMPLICIT_PREFIX}{os.getpid()}_{hash(abs_path) & 0xFFFFFFFF:08x}"

    try:
        fh = _file_hash(abs_path)

        # L-362: _cleanup_stale_lock은 os.stat/os.kill/os.remove 포함 — _fs_lock 밖에서 실행
        if os.path.exists(_owner_path(fh)):
            _cleanup_stale_lock(fh)

        # L-362: _write_session_meta/_add_session_file은 파일 I/O.
        # lock 안에서는 상태 확인 + _try_acquire_lock(I/O 없음)만 수행.
        # 결과 플래그를 lock 밖에서 처리한다.
        _action = None  # "acquired" | "blocked" | "reentry" | "contention"
        _block_reason = None
        _implicit_session_dir_to_clean = None

        # v2 P3' 1st two-phase: pre-read owner (lock 밖)
        _pre_owner1 = _read_owner(fh)
        with _fs_lock:
            # lock 안에서는 _try_acquire_lock만 수행 (I/O 없음: FIX-04)
            if _pre_owner1:
                owner_sid = _pre_owner1.get("session", "")
                owner_pid = int(_pre_owner1.get("pid", -1))

                # 같은 PID의 재진입 (Implicit/Explicit 무관) — heartbeat 갱신 (lock 밖에서)
                if owner_pid == os.getpid():
                    _action = "reentry"
                else:
                    _action = "blocked"
                    _block_reason = {"holder_session": owner_sid}
            else:
                # 신규 Implicit 세션 — lock 안에서 획득 시도 (_try_acquire_lock은 I/O 없음: FIX-04)
                if _try_acquire_lock(fh, session_id, os.getpid(),
                                     abs_path, implicit=True):
                    _action = "acquired"
                else:
                    # Cross-process 경합 — lock 밖에서 대기 후 재확인
                    _action = "contention"
                    _implicit_session_dir_to_clean = _session_dir(session_id)

        # L-362: lock 밖에서 파일 I/O 수행
        if _action == "reentry":
            heartbeat(abs_path)
            return {"success": True}

        if _action == "blocked":
            return {
                "success": False,
                "error": "INTENT_BLOCKED",
                "message": f"다른 세션이 파일을 선점 중: {abs_path}",
                "holder_session": _block_reason["holder_session"],
            }

        if _action == "acquired":
            # lock 밖에서 메타/파일 목록 I/O 수행 (L-362)
            _write_session_meta(session_id, os.getpid())
            _add_session_file(session_id, fh, abs_path)
            with _fs_lock:
                _implicit_map[abs_path] = (session_id, time.time())
            return {"success": True}

        # _action == "contention": Cross-process 경합 — lock 밖에서 대기 후 재확인
        # _fs_lock 밖에서 rmtree (L-362: lock 보유 중 blocking I/O 금지 — NTFS 수백ms 블로킹)
        if _implicit_session_dir_to_clean:
            shutil.rmtree(_implicit_session_dir_to_clean, ignore_errors=True)

        # _fs_lock 밖에서 sleep (lock 보유 중 sleep 금지)
        time.sleep(0.05)  # 50ms — owner 쓰기 완료 대기

        # v2 P3' 2nd two-phase: pre-read owner (lock 밖)
        _pre_owner2 = _read_owner(fh)
        _action2 = None
        with _fs_lock:
            if _pre_owner2 is None:
                # Lock 사라짐 — 재획득 시도 (_try_acquire_lock은 I/O 없음: FIX-04)
                if _try_acquire_lock(fh, session_id, os.getpid(), abs_path, implicit=True):
                    _action2 = "acquired"
                else:
                    _action2 = "failed"
            elif int(_pre_owner2.get("pid", -1)) == os.getpid():
                _action2 = "already_owned"
            else:
                _action2 = "blocked2"
                _block_reason = {"holder_session": _pre_owner2.get("session", "unknown")}

        # lock 밖에서 파일 I/O (L-362)
        if _action2 == "acquired":
            _write_session_meta(session_id, os.getpid())
            _add_session_file(session_id, fh, abs_path)
            with _fs_lock:
                _implicit_map[abs_path] = (session_id, time.time())
            return {"success": True}
        if _action2 == "already_owned":
            return {"success": True}
        if _action2 == "failed":
            return {"success": False, "error": "INTENT_BLOCKED", "message": f"Lock 경합 — 재시도: {abs_path}"}
        return {"success": False, "error": "INTENT_BLOCKED", "message": f"다른 세션 선점 중: {abs_path}", "holder_session": _block_reason["holder_session"]}

    except Exception as e:
        logging.warning("implicit_acquire 예외 (허용 처리): %s", e)
        return {"success": True, "warning": f"Intent Lock 시스템 오류로 허용 처리됨: {e}"}


def implicit_release(abs_path: str):
    """
    Implicit Lock 해제. Explicit 세션이면 아무것도 안 함.

    Args:
        abs_path: 정규화된 절대 경로
    """
    entry = _implicit_map.pop(abs_path, None)
    session_id = entry[0] if entry else None
    if session_id:
        session_end(session_id)
    invalidate_cache(abs_path)


# ══════════════════════════════════════════════════════════════════
#  상태 조회 (lock_status 통합용)
# ══════════════════════════════════════════════════════════════════

def get_all_intent_locks_snapshot() -> list:
    """
    모든 활성 Intent Lock 스냅샷 조회 — 조회 전용.
    _cleanup_all_stale 호출 없이 현재 상태만 반환.
    lock_status 도구에서 사용 (초 단위 지연 방지).

    Returns:
        세션별 Intent Lock 정보 목록
    """
    try:
        # N-04: sid 목록만 _fs_lock 안에서 수집 — 파일 읽기는 lock 밖에서 수행 (L-362)
        with _fs_lock:
            try:
                sids = list(os.listdir(_SESSIONS_DIR))  # audit-whitelist: snapshot-only
            except FileNotFoundError:
                return []

        # _fs_lock 밖에서 각 세션 정보 수집 (meta 읽기 + _get_session_files — 파일 I/O)
        result = []
        now = int(time.time())
        for sid in sids:
            sdir = _session_dir(sid)
            if not os.path.isdir(sdir):
                continue
            meta = _read_session_meta(sid)
            if not meta:
                continue

            pid = int(meta.get("pid", -1))
            created_at = int(meta.get("created_at", 0))
            heartbeat_at = int(meta.get("heartbeat_at", 0))
            classification = meta.get("classification")

            files = [p for _, p in _get_session_files(sid)]

            is_stale = not _is_pid_alive(pid)
            # pid 우선 — HEARTBEAT_TTL 기반 stale 판정 제거 (heartbeat 데몬 삭제 동반)
            # implicit 세션만 UX TTL 적용
            if not is_stale and sid.startswith(_IMPLICIT_PREFIX) and (now - heartbeat_at) > _IMPLICIT_TTL:
                is_stale = True

            result.append({
                "session_id": sid,
                "pid": pid,
                "classification": classification,
                "created_at": time.strftime(
                    "%Y-%m-%dT%H:%M:%S",
                    time.localtime(created_at)),
                "heartbeat_at": time.strftime(
                    "%Y-%m-%dT%H:%M:%S",
                    time.localtime(heartbeat_at)),
                "age_minutes": (now - created_at) // 60,
                "stale": is_stale,
                "files": files,
            })

        return result

    except Exception:
        return []


def get_all_intent_locks() -> list:
    """
    모든 활성 Intent Lock 조회. lock_status 도구에서 호출.

    Returns:
        세션별 Intent Lock 정보 목록
    """
    # stale 정리 (lock 밖에서 먼저 실행)
    _cleanup_all_stale()

    try:
        # N-04: sid 목록만 _fs_lock 안에서 수집 — 파일 읽기는 lock 밖에서 수행 (L-362)
        with _fs_lock:
            try:
                sids = list(os.listdir(_SESSIONS_DIR))  # audit-whitelist: snapshot-only
            except FileNotFoundError:
                return []

        # _fs_lock 밖에서 각 세션 정보 수집 (meta 읽기 + _get_session_files — 파일 I/O)
        result = []
        now = int(time.time())
        for sid in sids:
            sdir = _session_dir(sid)
            if not os.path.isdir(sdir):
                continue
            meta = _read_session_meta(sid)
            if not meta:
                continue

            pid = int(meta.get("pid", -1))
            created_at = int(meta.get("created_at", 0))
            heartbeat_at = int(meta.get("heartbeat_at", 0))
            classification = meta.get("classification")

            files = [p for _, p in _get_session_files(sid)]

            is_stale = not _is_pid_alive(pid)
            # pid 우선 — HEARTBEAT_TTL 기반 stale 판정 제거 (heartbeat 데몬 삭제 동반)
            # implicit 세션만 UX TTL 적용
            if not is_stale and sid.startswith(_IMPLICIT_PREFIX) and (now - heartbeat_at) > _IMPLICIT_TTL:
                is_stale = True

            result.append({
                "session_id": sid,
                "pid": pid,
                "classification": classification,
                "created_at": time.strftime(
                    "%Y-%m-%dT%H:%M:%S",
                    time.localtime(created_at)),
                "heartbeat_at": time.strftime(
                    "%Y-%m-%dT%H:%M:%S",
                    time.localtime(heartbeat_at)),
                "age_minutes": (now - created_at) // 60,
                "stale": is_stale,
                "files": files,
            })

        return result

    except Exception:
        return []


def get_wait_queue(file_path: str = None) -> list:
    """
    대기열 조회.

    Args:
        file_path: 특정 파일 경로 (None이면 전체)

    Returns:
        대기열 항목 목록
    """
    result = []
    now = int(time.time())

    try:
        if file_path:
            abs_path = os.path.abspath(file_path)
            fh = _file_hash(abs_path)
            fh_list = [(fh, abs_path)]
        else:
            fh_list = []
            for fh in os.listdir(_FILES_DIR):
                if os.path.exists(_owner_path(fh)):
                    owner = _read_owner(fh)
                    fp = owner.get("path", fh) if owner else fh
                    fh_list.append((fh, fp))

        for fh, fp in fh_list:
            qdir = _queue_dir(fh)
            if not os.path.isdir(qdir):
                continue
            entries = sorted(os.listdir(qdir))
            for pos, entry in enumerate(entries, 1):
                if "#" not in entry:
                    continue
                ts_str, waiter_sid = entry.split("#", 1)
                enqueued_at = int(ts_str) if ts_str.isdigit() else 0
                result.append({
                    "file": fp,
                    "waiting_session": waiter_sid,
                    "position": pos,
                    "enqueued_at": time.strftime(
                        "%Y-%m-%dT%H:%M:%S",
                        time.localtime(enqueued_at)),
                    "wait_minutes": (
                        (now - enqueued_at) // 60 if enqueued_at else 0),
                })
    except FileNotFoundError:
        pass

    return result


# ══════════════════════════════════════════════════════════════════
#  atexit / signal 핸들러: Implicit 세션 정리
# ══════════════════════════════════════════════════════════════════

def _cleanup_on_exit():
    """프로세스 종료 시 Implicit 세션 정리."""
    for abs_path in list(_implicit_map.keys()):
        try:
            implicit_release(abs_path)
        except Exception as e:
            logging.debug("cleanup_on_exit 예외: %s", e)


atexit.register(_cleanup_on_exit)


# signal 등록은 server.py로 이관
