"""
디렉토리 작업 도구 5개: dir_create, dir_delete, dir_rename, dir_move, list_dir
"""
import concurrent.futures as _cf
import fnmatch
import os
import shutil
from datetime import datetime

import security
import session_mirror
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


def _ntfs_safe_op(fn, *args, timeout: float = 30.0, op_name: str = "op"):
    """NTFS blocking shutil 작업을 timeout으로 보호."""
    with _cf.ThreadPoolExecutor(max_workers=1) as ex:
        future = ex.submit(fn, *args)
        try:
            return future.result(timeout=timeout)
        except _cf.TimeoutError:
            raise OSError(f"[oio] {op_name} timeout ({timeout}s): {args[0]}")


def _check_orphan_guard(path: str):
    """고아 팀에이전트 가드 호출 래퍼 (2026-08-17).

    orphan_guard 모듈이 없거나 import 자체가 실패해도 None(통과)을 반환한다.
    가드 도입이 기존 파일 작업을 절대 막지 않도록 하는 최종 안전망이다.
    """
    try:
        import orphan_guard
        return orphan_guard.check_orphan_block(path)
    except Exception:
        return None


def _check_subtree_intent_locks(path: str) -> list:
    """path 하위 파일 중 다른 세션에 의해 Intent Lock 선점된 파일 목록 반환.
    session_manager의 mkdir 기반 Intent Lock 시스템을 직접 조회."""
    import session_manager as _sm
    abs_path = os.path.abspath(path)
    blocked = []
    my_pid = os.getpid()

    try:
        all_locks = _sm.get_all_intent_locks_snapshot()  # 조회 전용 — stale 정리 없이 스냅샷만
        for lock_info in all_locks:
            if lock_info.get("pid") == my_pid:
                continue
            if lock_info.get("stale"):
                continue
            for locked_file in lock_info.get("files", []):
                abs_locked = os.path.abspath(locked_file)
                if abs_locked.startswith(abs_path + os.sep) or abs_locked == abs_path:
                    blocked.append(locked_file)
    except Exception:
        pass

    return blocked


def dir_create(path: str, parents: bool = True) -> dict:
    err = security.validate_path(path)
    if err:
        return err

    try:
        with acquire_worker_slot(timeout=2.0) as acquired:
            if not acquired:
                return _concurrency_limit_error(path)

            try:
                os.makedirs(path, exist_ok=parents)
                return {"success": True, "path": path, "created": True}
            except FileExistsError:
                if not parents:
                    return {
                        "success": False,
                        "error": "DIR_EXISTS",
                        "message": f"디렉토리가 이미 존재합니다: {path}",
                        "path": path,
                    }
                return {"success": True, "path": path, "created": False}
            except Exception as e:
                return {
                    "success": False,
                    "error": "IO_ERROR",
                    "message": f"디렉토리 생성 실패: {e}",
                    "path": path,
                }
    except (BrokenPipeError, ConnectionResetError):
        raise
    except Exception as e:
        return _fs_error(path, e)


def dir_delete(path: str, recursive: bool = False) -> dict:
    err = security.validate_path(path)
    if err:
        return err

    # --- 고아 팀에이전트 가드 (2026-08-17) — hooks H-1 의 oio 직접호출 우회로 봉쇄 ---
    # session-env/<uuid>/(agents|panes) 삭제 시 해당 세션 팀에이전트 잔존 여부를 검사한다.
    # 범위 밖 경로는 정규식 1회로 즉시 통과하므로 오버헤드가 사실상 없다.
    # ★ fail-open: 판정 불가(스크립트 부재/오류/타임아웃/예외)는 전부 통과시킨다.
    #   oio 는 모든 파일 작업의 관문이라 여기서 잘못 막으면 전 프로젝트가 마비된다.
    _orphan_err = _check_orphan_guard(path)
    if _orphan_err:
        return _orphan_err

    try:
        with acquire_worker_slot(timeout=2.0) as acquired:
            if not acquired:
                return _concurrency_limit_error(path)
            return session_mirror.apply_dir(
                _dir_delete_impl(path, recursive), path, recursive, deleted=True
            )
    except (BrokenPipeError, ConnectionResetError):
        raise
    except Exception as e:
        return _fs_error(path, e)


def _dir_delete_impl(path: str, recursive: bool) -> dict:
    if recursive:
        blocked = _check_subtree_intent_locks(path)
        if blocked:
            return {
                "success": False,
                "error": "INTENT_BLOCKED",
                "message": f"하위 파일이 다른 세션에 의해 선점 중: {blocked}",
                "path": path,
                "suggestion": "lock_status로 확인 후 해당 세션 종료를 기다리세요",
            }

    if not os.path.exists(path):
        return {"success": True, "path": path, "deleted": True, "files_removed": 0}

    if not os.path.isdir(path):
        return {
            "success": False,
            "error": "INVALID_PARAM",
            "message": f"경로가 디렉토리가 아닙니다: {path}",
            "path": path,
        }

    # 비어있는지 확인
    entries = list(os.scandir(path))
    if entries and not recursive:
        return {
            "success": False,
            "error": "DIR_NOT_EMPTY",
            "message": f"디렉토리가 비어있지 않습니다: {path}",
            "path": path,
            "suggestion": "recursive=true로 내용물 포함 삭제하세요",
        }

    try:
        if recursive:
            total = sum(
                len(files) + len(subdirs)
                for _, subdirs, files in os.walk(path)
            )
            _ntfs_safe_op(shutil.rmtree, path, op_name="shutil.rmtree")
            files_removed = total
        else:
            os.rmdir(path)
            files_removed = 0
        return {"success": True, "path": path, "deleted": True, "files_removed": files_removed}
    except Exception as e:
        return {
            "success": False,
            "error": "IO_ERROR",
            "message": f"디렉토리 삭제 실패: {e}",
            "path": path,
        }


def dir_rename(path: str, new_name: str) -> dict:
    err = security.validate_path(path)
    if err:
        return err

    # 고아 가드 — agents/ 를 다른 이름으로 옮기는 것도 추적 근거 소멸이므로 동일 취급한다.
    _orphan_err = _check_orphan_guard(path)
    if _orphan_err:
        return _orphan_err

    try:
        with acquire_worker_slot(timeout=2.0) as acquired:
            if not acquired:
                return _concurrency_limit_error(path)
            return _dir_rename_impl(path, new_name)
    except (BrokenPipeError, ConnectionResetError):
        raise
    except Exception as e:
        return _fs_error(path, e)


def _dir_rename_impl(path: str, new_name: str) -> dict:
    blocked = _check_subtree_intent_locks(path)
    if blocked:
        return {
            "success": False,
            "error": "INTENT_BLOCKED",
            "message": f"하위 파일이 다른 세션에 의해 선점 중: {blocked}",
            "path": path,
            "suggestion": "lock_status로 확인 후 해당 세션 종료를 기다리세요",
        }

    if not os.path.exists(path):
        return {
            "success": False,
            "error": "FILE_NOT_FOUND",
            "message": f"디렉토리를 찾을 수 없습니다: {path}",
            "path": path,
        }

    parent = os.path.dirname(path)
    new_path = os.path.join(parent, new_name)

    new_err = security.validate_path(new_path)
    if new_err:
        return new_err

    try:
        os.rename(path, new_path)
        return {"success": True, "old_path": path, "new_path": new_path}
    except Exception as e:
        return {
            "success": False,
            "error": "IO_ERROR",
            "message": f"디렉토리 이름 변경 실패: {e}",
            "path": path,
        }


def dir_move(source: str, destination: str) -> dict:
    for p in [source, destination]:
        err = security.validate_path(p)
        if err:
            return err

    # 고아 가드 — source 가 agents/ 이면 이동 역시 추적 근거 소멸이므로 삭제와 동일 취급한다.
    _orphan_err = _check_orphan_guard(source)
    if _orphan_err:
        return _orphan_err

    try:
        with acquire_worker_slot(timeout=2.0) as acquired:
            if not acquired:
                return _concurrency_limit_error(source)
            return _dir_move_impl(source, destination)
    except (BrokenPipeError, ConnectionResetError):
        raise
    except Exception as e:
        return _fs_error(source, e)


def _dir_move_impl(source: str, destination: str) -> dict:
    blocked = _check_subtree_intent_locks(source)
    if blocked:
        return {
            "success": False,
            "error": "INTENT_BLOCKED",
            "message": f"하위 파일이 다른 세션에 의해 선점 중: {blocked}",
            "path": source,
            "suggestion": "lock_status로 확인 후 해당 세션 종료를 기다리세요",
        }

    if not os.path.exists(source):
        return {
            "success": False,
            "error": "FILE_NOT_FOUND",
            "message": f"디렉토리를 찾을 수 없습니다: {source}",
            "path": source,
        }

    try:
        _ntfs_safe_op(shutil.move, source, destination, op_name="shutil.move")
        return {"success": True, "old_path": source, "new_path": destination}
    except Exception as e:
        return {
            "success": False,
            "error": "IO_ERROR",
            "message": f"디렉토리 이동 실패: {e}",
            "path": source,
        }


def list_dir(
    path: str,
    pattern: str = None,
    recursive: bool = False,
    include_hidden: bool = False,
    limit: int = 500,
) -> dict:
    err = security.validate_path(path)
    if err:
        return err

    try:
        with acquire_worker_slot(timeout=2.0) as acquired:
            if not acquired:
                return _concurrency_limit_error(path)
            return _list_dir_impl(path, pattern, recursive, include_hidden, limit)
    except (BrokenPipeError, ConnectionResetError):
        raise
    except Exception as e:
        return _fs_error(path, e)


def _list_dir_impl(
    path: str,
    pattern: str,
    recursive: bool,
    include_hidden: bool,
    limit: int,
) -> dict:
    if not os.path.exists(path):
        return {
            "success": False,
            "error": "FILE_NOT_FOUND",
            "message": f"디렉토리를 찾을 수 없습니다: {path}",
            "path": path,
        }

    if not os.path.isdir(path):
        return {
            "success": False,
            "error": "INVALID_PARAM",
            "message": f"경로가 디렉토리가 아닙니다: {path}",
            "path": path,
        }

    entries = []

    if recursive:
        # BFS 스택(iterative) 방식 — RecursionError 방지 (1000단계 이상 트리 대응)
        stack = [path]
        while stack and len(entries) < limit:
            current_dir = stack.pop()
            try:
                scanned = sorted(os.scandir(current_dir), key=lambda e: e.name)
            except PermissionError:
                continue
            subdirs = []
            for entry in scanned:
                if len(entries) >= limit:
                    break
                if not include_hidden and entry.name.startswith("."):
                    continue
                is_dir = entry.is_dir(follow_symlinks=False)
                if pattern and not is_dir and not fnmatch.fnmatch(entry.name, pattern):
                    if is_dir:
                        subdirs.append(entry.path)
                    continue
                try:
                    stat = entry.stat()
                    info = {
                        "name": entry.name,
                        "path": entry.path,
                        "type": "dir" if is_dir else "file",
                        "modified": datetime.fromtimestamp(stat.st_mtime).isoformat(),
                    }
                    if not is_dir:
                        info["size"] = stat.st_size
                    entries.append(info)
                except Exception:
                    entries.append({
                        "name": entry.name,
                        "path": entry.path,
                        "type": "dir" if is_dir else "file",
                    })
                if is_dir:
                    subdirs.append(entry.path)
            # 역순 push하여 알파벳 순 처리 유지
            stack.extend(reversed(subdirs))
    else:
        # 비재귀: 단일 디렉토리 스캔
        try:
            for entry in sorted(os.scandir(path), key=lambda e: e.name):
                if len(entries) >= limit:
                    break
                if not include_hidden and entry.name.startswith("."):
                    continue
                is_dir = entry.is_dir(follow_symlinks=False)
                if pattern and not is_dir and not fnmatch.fnmatch(entry.name, pattern):
                    continue
                try:
                    stat = entry.stat()
                    info = {
                        "name": entry.name,
                        "path": entry.path,
                        "type": "dir" if is_dir else "file",
                        "modified": datetime.fromtimestamp(stat.st_mtime).isoformat(),
                    }
                    if not is_dir:
                        info["size"] = stat.st_size
                    entries.append(info)
                except Exception:
                    entries.append({
                        "name": entry.name,
                        "path": entry.path,
                        "type": "dir" if is_dir else "file",
                    })
        except PermissionError:
            pass

    return {
        "success": True,
        "path": path,
        "total": len(entries),
        "entries": entries,
    }
