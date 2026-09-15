"""
find_ops.py — os.walk 기반 파일/디렉토리 검색 모듈
"""
import os
import time
import fnmatch
from datetime import datetime
from typing import Optional

from utils import acquire_worker_slot  # Layer 1 전역 worker slot (H-03)


def _concurrency_limit_error(path: str) -> dict:
    return {
        "success": False,
        "error": "CONCURRENCY_LIMIT",
        "message": "oio worker slot 포화 (OIO_WORKER_MAX 초과) — 잠시 후 재시도",
        "path": path,
    }


def _fs_error(path: str, exc: Exception) -> dict:
    return {
        "success": False,
        "error": "FS_ERROR",
        "message": str(exc),
        "path": path,
    }


def file_find(
    path: str,
    pattern: str = "*",
    file_type: str = "",
    max_depth: int = -1,
    min_size: int = -1,
    max_size: int = -1,
    modified_after: str = "",
    modified_before: str = "",
    exclude: list = None,
    max_results: int = 500,
    timeout_seconds: float = 30.0,
) -> dict:
    """
    파일/디렉토리 검색. os.walk + fnmatch + os.stat 기반.

    반환: dict — items(list), truncated(bool) 포함.
    - outer wrapper: worker slot (timeout=2.0) + catch-all (BrokenPipe/ConnectionReset raise, 기타 FS_ERROR).
    - 본체: walk 루프 outer + dirs inner + files inner 3개 지점에서 deadline 주기 체크 (U-2-4).
    """
    try:
        with acquire_worker_slot(timeout=2.0) as acquired:
            if not acquired:
                return _concurrency_limit_error(path)
            return _file_find_impl(
                path, pattern, file_type, max_depth,
                min_size, max_size, modified_after, modified_before,
                exclude, max_results, timeout_seconds,
            )
    except (BrokenPipeError, ConnectionResetError):
        raise
    except Exception as e:
        return _fs_error(path, e)


def _file_find_impl(
    path: str,
    pattern: str,
    file_type: str,
    max_depth: int,
    min_size: int,
    max_size: int,
    modified_after: str,
    modified_before: str,
    exclude: list,
    max_results: int,
    timeout_seconds: float,
) -> dict:
    results = []
    exclude = exclude or []
    exclude_set = set(exclude) if exclude else set()
    base_depth = path.rstrip(os.sep).count(os.sep)
    deadline = time.monotonic() + timeout_seconds

    # 날짜 파싱
    dt_after: Optional[datetime] = None
    dt_before: Optional[datetime] = None
    if modified_after:
        dt_after = datetime.fromisoformat(modified_after)
    if modified_before:
        dt_before = datetime.fromisoformat(modified_before)

    truncated = False
    for root, dirs, files in os.walk(path, topdown=True, followlinks=False):
        if time.monotonic() > deadline:
            truncated = True
            break

        # max_depth 적용: 현재 경로 깊이 계산
        current_depth = root.rstrip(os.sep).count(os.sep) - base_depth
        if max_depth >= 0 and current_depth >= max_depth:
            dirs[:] = []
        else:
            # exclude 디렉토리 가지치기
            dirs[:] = [d for d in dirs if d not in exclude_set]

        # 디렉토리 항목 처리
        if file_type in ("", "d"):
            for d in dirs:
                # U-2-4: inner loop 주기 timeout 체크 (대형 디렉토리 block 방지)
                if time.monotonic() > deadline:
                    truncated = True
                    return {"items": results, "truncated": truncated}
                if not fnmatch.fnmatch(d, pattern):
                    continue
                full_path = os.path.join(root, d)
                try:
                    st = os.stat(full_path)
                except OSError:
                    continue
                mtime = datetime.fromtimestamp(st.st_mtime)
                if dt_after and mtime < dt_after:
                    continue
                if dt_before and mtime > dt_before:
                    continue
                results.append({
                    "path": full_path,
                    "name": d,
                    "type": "d",
                    "size": 0,
                    "modified": mtime.isoformat(),
                })
                if len(results) >= max_results:
                    return {"items": results, "truncated": True}

        # 심볼릭링크 + 파일 항목 처리
        entries = files
        if file_type == "l":
            entries = [
                f for f in files
                if os.path.islink(os.path.join(root, f))
            ]
        elif file_type == "f":
            entries = [
                f for f in files
                if not os.path.islink(os.path.join(root, f))
            ]

        for fname in entries:
            # U-2-4: inner loop 주기 timeout 체크 (대형 디렉토리 block 방지)
            if time.monotonic() > deadline:
                truncated = True
                return {"items": results, "truncated": truncated}
            if not fnmatch.fnmatch(fname, pattern):
                continue
            full_path = os.path.join(root, fname)
            try:
                is_link = os.path.islink(full_path)
                st = os.lstat(full_path) if is_link else os.stat(full_path)
            except OSError:
                continue

            ftype = "l" if is_link else "f"
            if file_type and file_type != ftype:
                continue

            size = st.st_size
            mtime = datetime.fromtimestamp(st.st_mtime)

            if min_size >= 0 and size < min_size:
                continue
            if max_size >= 0 and size > max_size:
                continue
            if dt_after and mtime < dt_after:
                continue
            if dt_before and mtime > dt_before:
                continue

            results.append({
                "path": full_path,
                "name": fname,
                "type": ftype,
                "size": size,
                "modified": mtime.isoformat(),
            })
            if len(results) >= max_results:
                return {"items": results, "truncated": True}

    return {"items": results, "truncated": truncated}
