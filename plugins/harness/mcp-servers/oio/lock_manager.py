"""
Low-level 파일 Lock 관리자.
O_CREAT|O_EXCL 기반 단일 authoritative lock file, Stale 감지(PID/starttime/boot_id/TTL),
try/finally 자동 해제.

Codex CR-1: 기존 2단계(os.mkdir + _write_lock_file) race window 제거.
           단일 파일 원자 생성(O_CREAT|O_EXCL)으로 획득+publish 통합.
Codex H6 : pid_starttime + boot_id 핑거프린트 추가 (pid 재사용/재부팅 방지).
"""
import os
import time
import atexit
import uuid
import errno
import logging

# 현재 세션 ID (서버 시작 시 생성)
SESSION_ID = str(uuid.uuid4())

# Lock TTL (초) — 60분
FILE_LOCK_TTL_SECONDS = 3600

# Lock 획득 기본 최대 대기 시간(초). 10초 기본값 유지 (D-6: 단축 금지).
# 환경변수 `OIO_LOCK_MAX_WAIT`으로 override 가능. max(1, ...)로 0 이하 값은 1 클램프.
try:
    _MAX_WAIT = max(1, int(os.getenv("OIO_LOCK_MAX_WAIT", "10")))
except (TypeError, ValueError):
    _MAX_WAIT = 10

# Grace age: 빈/부분 파일이 "쓰기 중"으로 간주되는 최대 경과 시간 (초)
# Codex CR-1: race window에서 부분 쓰기 상태 파일을 stale 오판하지 않도록 보호
_GRACE_AGE_SECONDS = 1.0

# 활성 Lock 추적 (atexit/signal 정리용)
_active_locks: set = set()


# Codex N2: lock store는 **ext4 전용** (/tmp). DrvFs(/mnt/c/*)에 lock 생성 금지.
# 이유: WSL2 DrvFs는 Plan9/virtio 계층으로 rename atomicity 비보장, AV 간섭 가능.
_LOCK_BASE_DIR = "/tmp/oio-locks"


def _ensure_lock_base():
    """Lock 기본 디렉토리 생성 (ext4에 위치 — 모든 경로에서 안정적)."""
    os.makedirs(_LOCK_BASE_DIR, exist_ok=True)  # /tmp/oio-locks


def _path_hash(file_path: str) -> str:
    """파일 경로를 해시로 변환. session_manager와 동일한 SHA256[:16] 사용."""
    import hashlib
    abs_path = os.path.abspath(file_path)
    # NTFS 대소문자 무시 정규화
    if abs_path.startswith("/mnt/") and len(abs_path) > 6 and abs_path[5].isalpha():
        abs_path = abs_path.lower()
    return hashlib.sha256(abs_path.encode()).hexdigest()[:16]


def _lock_file_path(file_path: str) -> str:
    """단일 authoritative lock 파일 경로 (Codex CR-1: lockdir 제거)."""
    _ensure_lock_base()
    return os.path.join(_LOCK_BASE_DIR, f"{_path_hash(file_path)}.lock")


# ══════════════════════════════════════════════════════════════════
#  H6 핑거프린트 헬퍼 (pid_starttime + boot_id)
# ══════════════════════════════════════════════════════════════════

_BOOT_ID_CACHE: str | None = None


def _get_boot_id() -> str:
    """/proc/sys/kernel/random/boot_id 캐시 조회. Codex H6: 재부팅 감지용."""
    global _BOOT_ID_CACHE
    if _BOOT_ID_CACHE is None:
        try:
            with open("/proc/sys/kernel/random/boot_id", "r") as f:
                _BOOT_ID_CACHE = f.read().strip()
        except Exception:
            _BOOT_ID_CACHE = ""
    return _BOOT_ID_CACHE


def _get_pid_starttime(pid: int) -> str:
    """/proc/{pid}/stat 22번째 필드(btime jiffies). Codex H6: pid 재사용 감지."""
    try:
        with open(f"/proc/{pid}/stat", "r") as f:
            data = f.read()
        # comm 필드(괄호 안)에 공백이 들어갈 수 있으므로 ')' 기준 split
        rparen = data.rfind(")")
        if rparen < 0:
            return ""
        rest = data[rparen + 1:].strip().split()
        # stat: pid(1) comm(2) state(3) ... starttime(22) — ')' 이후는 state부터 시작
        # 즉 rest[0]=state(3), rest[19]=starttime(22)
        if len(rest) >= 20:
            return rest[19]
    except Exception:
        pass
    return ""


# ══════════════════════════════════════════════════════════════════
#  Lock 파일 I/O (단일 파일 원자 쓰기)
# ══════════════════════════════════════════════════════════════════

def _compose_owner_content(now: int | None = None) -> str:
    """5줄 포맷: session_id, pid, pid_starttime, boot_id, timestamp (Codex H6)."""
    if now is None:
        now = int(time.time())
    pid = os.getpid()
    starttime = _get_pid_starttime(pid)
    boot_id = _get_boot_id()
    return f"{SESSION_ID}\n{pid}\n{starttime}\n{boot_id}\n{now}\n"


def _read_lock_file(lock_file: str):
    """Lock 파일 읽기.
    반환: (session_id, pid, starttime, boot_id, timestamp) 또는 None.
    하위 호환: 구 3줄 포맷(session_id, pid, timestamp)도 파싱.
    """
    try:
        with open(lock_file, "r", encoding="utf-8") as f:
            raw = f.read()
    except Exception:
        return None
    if not raw.strip():
        # 빈 파일 — 쓰기 진행 중 가능성
        return None
    lines = raw.strip().splitlines()
    try:
        if len(lines) >= 5:
            # 신규 5줄 포맷 (H6)
            return (lines[0], int(lines[1]), lines[2], lines[3], int(lines[4]))
        if len(lines) >= 3:
            # 구 3줄 포맷 (하위 호환): starttime/boot_id를 빈 문자열로 채움
            return (lines[0], int(lines[1]), "", "", int(lines[2]))
    except (ValueError, IndexError):
        return None
    return None


def _is_stale(session_id: str, pid: int, starttime: str,
              boot_id: str, timestamp: int) -> bool:
    """Lock이 Stale인지 확인 (PID 사망 / starttime 불일치 / boot_id 불일치 / TTL)."""
    # 동일 세션/PID면 재진입 허용.
    if session_id == SESSION_ID and pid == os.getpid():
        return False

    # Codex H6: boot_id 불일치 → 재부팅 이후 stale 확정
    current_boot = _get_boot_id()
    if boot_id and current_boot and boot_id != current_boot:
        return True

    # PID 생존 확인 (pid<=0은 특수값 — 죽은 것으로 간주)
    if pid <= 0:
        pid_alive = False
    else:
        try:
            os.kill(pid, 0)
            pid_alive = True
        except (ProcessLookupError, PermissionError, OSError):
            pid_alive = False

    if not pid_alive:
        return True

    # Codex H6: pid 살아있어도 starttime 불일치면 pid 재사용 → stale
    if starttime:
        current_starttime = _get_pid_starttime(pid)
        if current_starttime and current_starttime != starttime:
            return True

    # TTL 확인
    age = int(time.time()) - timestamp
    if age > FILE_LOCK_TTL_SECONDS:
        return True

    return False


def _remove_lock(file_path: str):
    """Lock 파일 삭제 (best-effort). Codex CR-1: 단일 파일 unlink."""
    lock_file = _lock_file_path(file_path)
    try:
        os.remove(lock_file)
    except Exception:
        pass
    _active_locks.discard(file_path)


def _atomic_create_and_write(lock_file: str) -> bool:
    """O_CREAT|O_EXCL 파일 생성 + owner 정보 write + fsync + close.
    Codex CR-1: 획득과 publish를 단일 파일 원자 연산으로 통합.
    성공=True, 이미 존재=False, 기타 에러는 raise.
    """
    fd = None
    try:
        fd = os.open(lock_file, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError:
        return False
    try:
        content = _compose_owner_content().encode("utf-8")
        os.write(fd, content)
        os.fsync(fd)
        return True
    except Exception:
        # 쓰기 실패 — cleanup ladder (빈/부분 파일 방치 방지)
        try:
            os.remove(lock_file)
        except Exception:
            pass
        raise
    finally:
        if fd is not None:
            try:
                os.close(fd)
            except Exception:
                pass


def _wait_grace_or_stale(lock_file: str) -> str:
    """경쟁 시 파일 상태 판정.
    반환: "grace" (쓰기 중 — 대기), "stale" (청소 가능), "alive" (정상 보유).
    """
    try:
        st = os.stat(lock_file)
    except FileNotFoundError:
        return "stale"  # 파일 사라짐 → 재시도 가능
    except OSError:
        return "alive"

    lock_info = _read_lock_file(lock_file)
    if lock_info is None:
        # 파일은 있지만 내용이 비었거나 부분 쓰기 — grace age 검사
        age = time.time() - st.st_mtime
        if age < _GRACE_AGE_SECONDS:
            return "grace"  # 쓰기 진행 중 추정 — 잠시 대기
        return "stale"  # grace 초과 → 유기된 부분 파일

    session_id, pid, starttime, boot_id, timestamp = lock_info
    if _is_stale(session_id, pid, starttime, boot_id, timestamp):
        return "stale"
    return "alive"


# ══════════════════════════════════════════════════════════════════
#  Public API
# ══════════════════════════════════════════════════════════════════

def acquire(file_path: str, max_wait_seconds: int | None = None):
    """파일 Lock 획득 (단일 파일 O_CREAT|O_EXCL). 성공 시 None, 실패 시 에러 dict.

    max_wait_seconds=None이면 module-level `_MAX_WAIT` (env OIO_LOCK_MAX_WAIT, default 10) 사용.
    """
    if max_wait_seconds is None:
        max_wait_seconds = _MAX_WAIT
    lock_file = _lock_file_path(file_path)
    deadline = time.time() + max_wait_seconds

    while True:
        try:
            created = _atomic_create_and_write(lock_file)
        except OSError as e:
            # 권한/경로 문제 — 에러 반환 (삼키지 않음)
            return {
                "success": False,
                "error": "LOCK_CREATE_FAILED",
                "message": f"Lock 파일 생성 불가: {lock_file}",
                "path": file_path,
                "details": {"os_error": str(e), "errno": e.errno},
                "suggestion": "파일 경로와 권한을 확인하세요",
            }

        if created:
            _active_locks.add(file_path)
            return None  # OK

        # 이미 존재 — 상태 판정
        state = _wait_grace_or_stale(lock_file)

        if state == "stale":
            # Stale → 제거 후 재시도
            try:
                os.remove(lock_file)
            except FileNotFoundError:
                pass
            except OSError:
                pass
            continue

        if state == "grace":
            # 쓰기 진행 중 추정 — grace 내 짧은 대기 후 재시도
            remaining = deadline - time.time()
            if remaining <= 0:
                return _locked_error(file_path, lock_file)
            time.sleep(min(0.1, remaining))  # 0.5초 고정 → 0.1초 + deadline 정밀화
            continue

        # alive — 정상 holder 존재
        if time.time() >= deadline:
            return _locked_error(file_path, lock_file)

        time.sleep(0.3)


def _locked_error(file_path: str, lock_file: str) -> dict:
    """FILE_LOCKED 에러 응답 생성."""
    lock_info = _read_lock_file(lock_file)
    holder = lock_info[0] if lock_info else "unknown"
    return {
        "success": False,
        "error": "FILE_LOCKED",
        "message": f"파일이 다른 세션에 의해 잠겨 있습니다: {file_path}",
        "path": file_path,
        "details": {"holder_session": holder},
        "suggestion": "30초 후 재시도하거나 lock_status로 Lock 현황을 확인하세요",
    }


def release(file_path: str):
    """Lock 해제 (소유권 확인: session_id + PID + starttime 일치해야 해제)."""
    lock_file = _lock_file_path(file_path)
    lock_info = _read_lock_file(lock_file)
    if lock_info:
        session_id, pid, starttime, _boot_id, _ts = lock_info
        # 동일 세션 + 동일 PID + (가능하면) 동일 starttime일 때만 해제
        current_starttime = _get_pid_starttime(os.getpid()) if starttime else ""
        owner_match = (session_id == SESSION_ID and pid == os.getpid())
        starttime_match = (not starttime) or (starttime == current_starttime)
        if owner_match and starttime_match:
            _remove_lock(file_path)
        else:
            # S-03: 소유권 불일치 시에도 _active_locks에서 제거 — atexit 잔류 방지
            _active_locks.discard(file_path)
    else:
        # Lock 파일 비었거나 읽기 실패 — _active_locks 정리만 수행
        _active_locks.discard(file_path)


def get_all_locks(directory: str = None) -> list:
    """현재 활성 Lock 목록 조회. /tmp/oio-locks/ 직접 스캔 (단일 .lock 파일만)."""
    result = []
    try:
        for entry in os.scandir(_LOCK_BASE_DIR):
            if entry.name.endswith(".lock") and entry.is_file():
                hash_name = entry.name[:-5]  # "{hash}.lock" → "{hash}"
                lock_info = _read_lock_file(entry.path)
                if lock_info:
                    session_id, pid, starttime, boot_id, timestamp = lock_info
                    age_minutes = (int(time.time()) - timestamp) // 60
                    stale = _is_stale(session_id, pid, starttime, boot_id, timestamp)
                    result.append({
                        "hash": hash_name,
                        "session_id": session_id,
                        "pid": pid,
                        "age_minutes": age_minutes,
                        "stale": stale,
                        "ttl_remaining_sec": max(0, FILE_LOCK_TTL_SECONDS - (int(time.time()) - timestamp)),
                    })
    except FileNotFoundError:
        pass

    return result


def _cleanup():
    """atexit/signal 핸들러: 모든 활성 Lock 해제."""
    for file_path in list(_active_locks):
        try:
            release(file_path)
        except Exception:
            pass


atexit.register(_cleanup)


# signal 등록은 server.py로 이관
