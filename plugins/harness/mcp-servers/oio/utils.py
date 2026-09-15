"""
유틸리티 도구: file_info, lock_status
전역 worker 동시성 제어: _oio_worker_semaphore + acquire_worker_slot (H-03 수용)
"""
import json
import os
import sys
import threading
import time
from contextlib import contextmanager
from datetime import datetime

import security
import lock_manager
import ntfs_handler
import session_manager

# threadpool 포화 경고 임계값 (anyio max_workers=40 기준)
_THREADPOOL_WARN_THRESHOLD = 30

# ---------------------------------------------------------------------------
# 전역 worker semaphore (oplan_final_v2 §6.3 / H-03 수용)
# ---------------------------------------------------------------------------
# bash_exec FG 경로와 file_ops/dir_ops/find_ops 경로가 동일 anyio worker pool을
# 공유하므로 카운터를 분리하지 않고 단일 slot pool로 통합한다.
#   - anyio threadpool total_tokens = 40 (Phase 0 P0-2 실측 기준)
#   - 35 = 40 - 5 margin (background thread 여유분)
#   - OIO_WORKER_MAX=0 시 비활성 (사실상 무제한, 10**6 슬롯)
# bash_exec의 _fg_semaphore(30)는 유지하되 Layer2로 재해석되며,
# 이 모듈의 _oio_worker_semaphore가 Layer1(전역)이다.
_OIO_WORKER_MAX = int(os.environ.get("OIO_WORKER_MAX", "35"))
if _OIO_WORKER_MAX <= 0:
    _oio_worker_semaphore = threading.Semaphore(10 ** 6)
else:
    _oio_worker_semaphore = threading.Semaphore(_OIO_WORKER_MAX)


@contextmanager
def acquire_worker_slot(timeout: float = 2.0):
    """전역 worker semaphore 획득 context manager.

    timeout 내 slot 확보 실패 시 yield 값은 False — 호출자는 즉시
    CONCURRENCY_LIMIT fail-fast 응답을 반환해야 한다.
    """
    acquired = _oio_worker_semaphore.acquire(timeout=timeout)
    try:
        yield acquired
    finally:
        if acquired:
            _oio_worker_semaphore.release()


__all__ = [
    "file_info",
    "get_cwd",
    "lock_status",
    "acquire_worker_slot",
    "_oio_worker_semaphore",
]


def file_info(path: str) -> dict:
    err = security.validate_path(path)
    if err:
        return err

    environment = ntfs_handler.get_environment(path)
    exists = os.path.exists(path)

    if not exists:
        return {
            "exists": False,
            "is_file": False,
            "is_dir": False,
            "path": path,
            "environment": environment,
        }

    is_file = os.path.isfile(path)
    is_dir = os.path.isdir(path)

    result = {
        "exists": True,
        "is_file": is_file,
        "is_dir": is_dir,
        "path": path,
        "environment": environment,
    }

    try:
        stat = os.stat(path)
        result["size"] = stat.st_size
        result["mtime"] = datetime.fromtimestamp(stat.st_mtime).isoformat()
    except Exception:
        pass

    # 텍스트 파일 메타데이터 (파일인 경우만, 최대 4KB 읽기)
    if is_file:
        try:
            with open(path, "rb") as f:
                sample = f.read(4096)
            has_bom, encoding = ntfs_handler.detect_bom_and_encoding(sample)
            line_ending = ntfs_handler.detect_line_ending(sample)
            result["encoding"] = encoding
            result["has_bom"] = has_bom
            result["line_ending"] = line_ending
        except Exception:
            pass

    return result


def get_cwd() -> dict:
    """현재 작업 디렉토리 반환."""
    return {"cwd": os.getcwd()}


def lock_status(path: str = None) -> dict:
    """Lock 현황 조회 (Intent Lock + File Lock + Wait Queue 통합).

    _cleanup_all_stale을 호출하지 않고 현재 스냅샷만 반환.
    (stale 정리는 별도 경로에서만 수행 — threadpool 직렬화 방지)
    """
    # threadpool 포화 모니터링
    active_threads = threading.active_count()
    if active_threads >= _THREADPOOL_WARN_THRESHOLD:
        sys.stderr.write(
            f"[oio] WARNING: threadpool saturation risk — active_threads={active_threads}\n"
        )
        sys.stderr.flush()

    # File Mutex (기존)
    file_locks = lock_manager.get_all_locks(directory=path)

    # Intent Lock — 스냅샷만 반환 (stale 정리 없음)
    intent_locks = session_manager.get_all_intent_locks_snapshot()

    # Wait Queue
    wait_queue = session_manager.get_wait_queue(file_path=path)

    return {
        "intent_locks": intent_locks,
        "file_locks": file_locks,
        "wait_queue": wait_queue,
        "active_threads": active_threads,
    }
