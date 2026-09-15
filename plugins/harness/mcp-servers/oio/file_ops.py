"""
파일 작업 도구 7개: file_read, file_write, file_edit, file_delete,
file_rename, file_move, file_copy
"""
import os
import shutil

import security
import lock_manager
import ntfs_handler
import session_manager
import session_mirror  # session-env 두 base 미러링 (사이클41 — 상세는 모듈 docstring)
from utils import acquire_worker_slot  # Layer 1 전역 worker slot (H-03)


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


def _resolve_symlink_for_write(path: str) -> str:
    """쓰기 대상이 심볼릭링크면 실체 경로로 치환한다 (링크 보존).

    배경: file_write/file_edit은 원자적 쓰기(tmpfile→os.replace)를 사용한다.
    os.replace는 링크가 아니라 링크 자체를 대체하므로, 심볼릭링크를 편집하면
    링크가 끊기고 일반 파일로 바뀐다. 정본을 공유하는 구조(CLAUDE.md 등)에서는
    해당 경로만 정본에서 조용히 분리되어 이후 정본 변경이 도달하지 않는다.

    조치: 쓰기 직전에 os.path.realpath로 실체 경로를 구해 그 경로에 쓴다.
    링크 자체는 건드리지 않으므로 mode 120000이 그대로 유지된다.

    안전장치:
    - 링크가 아니면 원본 경로를 그대로 반환한다 (동작 변화 없음).
    - 끊어진 링크(dangling)는 실체가 없으므로 원본 경로를 그대로 반환한다.
    - 예외가 나면 원본 경로를 반환한다 (fail-safe — 기존 동작 유지).
    """
    try:
        if not os.path.islink(path):
            return path
        resolved = os.path.realpath(path)
        # 끊어진 링크는 실체가 없다. 기존 동작(원본 경로 쓰기)을 유지한다.
        if not os.path.exists(resolved):
            return path
        return resolved
    except Exception:
        return path


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


def _check_intent_gate(file_path: str) -> dict | None:
    """
    Intent Lock 게이트.
    - Explicit 모드: 세션 소유권만 확인 + heartbeat 갱신
    - Implicit 모드: transient Intent Lock 자동 생성
    반환: None(통과) 또는 에러 dict
    """
    try:
        abs_path = os.path.abspath(file_path)

        # 주기적 stale Lock 정리 (M-3)
        session_manager.maybe_cleanup_stale()

        # fast-path 캐시 확인 (10초 이내 동일 파일 재확인 skip)
        if session_manager.is_cached_owner(abs_path):
            return None

        # Explicit 모드 검사: 현재 PID의 활성 세션이 해당 파일을 보유?
        owner_check = session_manager.check_ownership(abs_path, os.getpid())

        if owner_check == "OWNED":
            session_manager.heartbeat(abs_path)
            session_manager.cache_owner(abs_path)
            return None

        if owner_check == "NOT_LOCKED":
            result = session_manager.implicit_acquire(abs_path)
            if result["success"]:
                session_manager.cache_owner(abs_path)
                return None
            return result

        if owner_check == "OTHER_SESSION":
            return {
                "success": False,
                "error": "INTENT_BLOCKED",
                "message": f"다른 세션이 파일을 선점 중: {abs_path}",
                "path": file_path,
                "suggestion": "lock_status로 현황 확인 후 대기하거나 session_begin으로 대기열에 등록하세요",
            }

        return None  # fallback 허용
    except Exception as e:
        import logging
        logging.warning("_check_intent_gate 예외: %s", e)
        return {
            "success": False,
            "error": "INTENT_ERROR",
            "message": f"Intent Lock 검증 실패: {e}",
            "suggestion": "잠시 후 재시도하세요",
        }


def _release_implicit(file_path: str):
    """Implicit Lock 해제 (transient 세션이면)."""
    try:
        abs_path = os.path.abspath(file_path)
        session_manager.implicit_release(abs_path)
    except Exception:
        pass  # finally 블록 내 예외가 상위로 전파되지 않도록 보호


def _heartbeat_during_lock(file_path: str):
    """Lock 보유 중 heartbeat 갱신. try 블록 진입 직후 호출."""
    try:
        abs_path = os.path.abspath(file_path)
        session_manager.heartbeat(abs_path)
    except Exception:
        pass


# ─── L-395 self-verify (T1/T2) ──────────────────────────────────────────────

_MAX_FULL_VERIFY_SIZE = 5 * 1024 * 1024  # 5MB


def _self_verify_write(path: str, expected_content: str, encoding_used: str) -> "dict | None":
    """write 직후 read-back으로 실제 저장 여부 검증.
    일치하면 None 반환, 불일치/오류 시 error dict 반환.
    5MB 초과: head 128B + tail 128B + size 경량 검증 (skip 아님)."""
    import time
    max_retries = 2
    retry_interval = 0.1  # 100ms (Defender 스캔 대응)

    for attempt in range(max_retries):
        try:
            actual_size = os.path.getsize(path)
            expected_bytes = expected_content.encode(encoding_used or "utf-8")
            expected_size = len(expected_bytes)

            if actual_size != expected_size:
                if attempt < max_retries - 1:
                    time.sleep(retry_interval)
                    continue
                return {
                    "success": False,
                    "error": "WRITE_VERIFY_MISMATCH",
                    "message": f"크기 불일치: 기대 {expected_size}B ≠ 실제 {actual_size}B",
                    "path": path,
                }

            if actual_size <= _MAX_FULL_VERIFY_SIZE:
                with open(path, "rb") as f:
                    actual_data = f.read()
                actual_stripped = actual_data.lstrip(b"\xef\xbb\xbf")
                try:
                    actual_text = actual_stripped.decode(encoding_used or "utf-8", errors="replace")
                except Exception:
                    actual_text = actual_stripped.decode("utf-8", errors="replace")
                expected_norm = expected_content.replace("\r\n", "\n").replace("\r", "\n")
                actual_norm = actual_text.replace("\r\n", "\n").replace("\r", "\n")
                if expected_norm != actual_norm:
                    if attempt < max_retries - 1:
                        time.sleep(retry_interval)
                        continue
                    return {
                        "success": False,
                        "error": "WRITE_VERIFY_MISMATCH",
                        "message": f"내용 불일치: 기대 {len(expected_norm)}자 ≠ 실제 {len(actual_norm)}자",
                        "path": path,
                    }
            else:
                with open(path, "rb") as f:
                    actual_head = f.read(128)
                    f.seek(-128, 2)
                    actual_tail = f.read(128)
                if actual_head != expected_bytes[:128] or actual_tail != expected_bytes[-128:]:
                    if attempt < max_retries - 1:
                        time.sleep(retry_interval)
                        continue
                    return {
                        "success": False,
                        "error": "WRITE_VERIFY_MISMATCH",
                        "message": "head/tail 불일치 (경량 검증)",
                        "path": path,
                    }
            return None  # 검증 통과
        except Exception as e:
            if attempt < max_retries - 1:
                time.sleep(retry_interval)
                continue
            return {
                "success": False,
                "error": "WRITE_VERIFY_EXCEPTION",
                "message": f"검증 중 예외: {e}",
                "path": path,
            }
    return None  # 루프 정상 종료 (도달 불가이나 타입 안전성)


def _self_verify_edit(path: str, expected_full_content: str, encoding_used: str) -> "dict | None":
    """edit 직후 read-back — 교체 완료 후 전체 내용이 expected와 일치하는지 검증."""
    return _self_verify_write(path, expected_full_content, encoding_used)


def file_read(
    path: str,
    offset: int = 0,
    limit: int = 2000,
    start_line: int | None = None,
    end_line: int | None = None,
) -> dict:
    err = security.validate_path(path)
    if err:
        return err

    try:
        with acquire_worker_slot(timeout=2.0) as acquired:
            if not acquired:
                return _concurrency_limit_error(path)

            data, err = ntfs_handler.read_file_binary(path)
            if err:
                return err

            has_bom, encoding = ntfs_handler.detect_bom_and_encoding(data)
            line_ending = ntfs_handler.detect_line_ending(data)
            environment = ntfs_handler.get_environment(path)

            # BOM 건너뛰고 디코딩
            bom_size = 3 if (has_bom and data.startswith(b"\xef\xbb\xbf")) else 0
            try:
                text = data[bom_size:].decode("utf-8")
            except Exception:
                text = data[bom_size:].decode("utf-8", errors="replace")

            lines = text.splitlines(keepends=True)
            total_lines = len(lines)

            # start_line/end_line 우선 (1-based, end_line 포함)
            if start_line is not None:
                s = max(0, start_line - 1)  # 1-based → 0-based
                e = end_line if end_line is not None else total_lines
                selected = lines[s:e]
            else:
                selected = lines[offset:offset + limit]

            content = "".join(selected)

            return {
                "success": True,
                "content": content,
                "lines": len(selected),
                "total_lines": total_lines,
                "encoding": encoding,
                "has_bom": has_bom,
                "line_ending": line_ending,
                "environment": environment,
                "path": path,
            }
    except (BrokenPipeError, ConnectionResetError):
        raise
    except Exception as e:
        return _fs_error(path, e)


def file_write(
    path: str,
    content: str,
    overwrite: bool = False,
    create_dirs: bool = True,
    encoding: str = "auto",
    line_ending: str = "auto",
) -> dict:
    err = security.validate_path(path)
    if err:
        return err

    # 심볼릭링크 보존: 링크면 실체 경로로 치환한다 (링크 끊김 방지).
    path = _resolve_symlink_for_write(path)

    try:
        with acquire_worker_slot(timeout=2.0) as acquired:
            if not acquired:
                return _concurrency_limit_error(path)
            # session-env 하위면 다른 base 에도 반영한다 (그 외 경로는 no-op).
            return session_mirror.apply(
                _file_write_impl(
                    path, content, overwrite, create_dirs, encoding, line_ending
                ),
                path,
            )
    except (BrokenPipeError, ConnectionResetError):
        raise
    except Exception as e:
        return _fs_error(path, e)


def _file_write_impl(
    path: str,
    content: str,
    overwrite: bool,
    create_dirs: bool,
    encoding: str,
    line_ending: str,
) -> dict:
    action = "created"
    existing_bom_bytes = b""
    existing_le = ""

    if os.path.exists(path):
        if not overwrite:
            return {
                "success": False,
                "error": "FILE_EXISTS",
                "message": f"파일이 이미 존재합니다: {path}",
                "path": path,
                "suggestion": "overwrite=true로 덮어쓰기하세요",
            }
        action = "overwritten"
        # 기존 BOM + 줄바꿈 감지
        existing_data, read_err = ntfs_handler.read_file_binary(path)
        if not read_err:
            has_bom, _ = ntfs_handler.detect_bom_and_encoding(existing_data)
            if has_bom and existing_data.startswith(b"\xef\xbb\xbf"):
                existing_bom_bytes = b"\xef\xbb\xbf"
            existing_le = ntfs_handler.detect_line_ending(existing_data)

    environment = ntfs_handler.get_environment(path)

    # 줄바꿈 결정
    if line_ending == "auto":
        target_le = existing_le if existing_le else "LF"
    else:
        target_le = "CRLF" if line_ending.lower() == "crlf" else "LF"

    # BOM 결정
    if encoding == "auto":
        use_bom = len(existing_bom_bytes) > 0
    elif encoding == "utf-8-sig":
        use_bom = True
    else:
        use_bom = False

    # 내용 인코딩 + 줄바꿈 정규화
    text_bytes = content.encode("utf-8")
    text_bytes = text_bytes.replace(b"\r\n", b"\n")
    if target_le == "CRLF":
        text_bytes = text_bytes.replace(b"\n", b"\r\n")

    bom = b"\xef\xbb\xbf" if use_bom else b""
    data = bom + text_bytes

    if create_dirs:
        dir_path = os.path.dirname(os.path.abspath(path))
        os.makedirs(dir_path, exist_ok=True)

    # Intent Gate (lock_manager.acquire 전)
    intent_err = _check_intent_gate(path)
    if intent_err:
        return intent_err

    try:
        lock_err = lock_manager.acquire(path)
        if lock_err:
            return lock_err

        try:
            _heartbeat_during_lock(path)
            err = ntfs_handler.write_file_atomic(path, data)
            if err:
                return err
        finally:
            lock_manager.release(path)
    finally:
        _release_implicit(path)

    # T3: self-verify (write 직후 read-back)
    verify_err = _self_verify_write(path, content, "utf-8")
    if verify_err:
        return verify_err

    return {
        "success": True,
        "path": path,
        "bytes_written": len(data),
        "environment": environment,
        "action": action,
    }


def file_edit(
    path: str,
    old_string: str,
    new_string: str,
    replace_all: bool = False,
) -> dict:
    err = security.validate_path(path)
    if err:
        return err

    if not old_string:
        return {
            "success": False,
            "error": "INVALID_PARAM",
            "message": "old_string이 비어있습니다",
            "path": path,
            "suggestion": "교체할 문자열을 입력하세요",
        }

    if old_string == new_string:
        return {
            "success": False,
            "error": "EDIT_NO_CHANGE",
            "message": "old_string과 new_string이 동일합니다",
            "path": path,
            "suggestion": "수정할 내용을 확인하세요",
        }

    # 심볼릭링크 보존: 링크면 실체 경로로 치환한다 (링크 끊김 방지).
    path = _resolve_symlink_for_write(path)

    try:
        with acquire_worker_slot(timeout=2.0) as acquired:
            if not acquired:
                return _concurrency_limit_error(path)
            # session-env 하위면 다른 base 에도 반영한다 (그 외 경로는 no-op).
            return session_mirror.apply(
                _file_edit_impl(path, old_string, new_string, replace_all), path
            )
    except (BrokenPipeError, ConnectionResetError):
        raise
    except Exception as e:
        return _fs_error(path, e)


def _file_edit_impl(
    path: str,
    old_string: str,
    new_string: str,
    replace_all: bool,
) -> dict:
    environment = ntfs_handler.get_environment(path)

    # Intent Gate (lock_manager.acquire 전)
    intent_err = _check_intent_gate(path)
    if intent_err:
        return intent_err

    try:
        lock_err = lock_manager.acquire(path)
        if lock_err:
            return lock_err

        try:
            _heartbeat_during_lock(path)
            if not os.path.exists(path):
                return {
                    "success": False,
                    "error": "FILE_NOT_FOUND",
                    "message": f"파일을 찾을 수 없습니다: {path}",
                    "path": path,
                    "suggestion": "file_info로 존재 여부를 확인하세요",
                }

            # 파일 읽기
            data, read_err = ntfs_handler.read_file_binary(path)
            if read_err:
                return read_err

            # M-7: 바이너리 파일 감지
            if b"\x00" in data[:8192]:
                return {
                    "success": False,
                    "error": "BINARY_FILE",
                    "message": f"바이너리 파일은 file_edit으로 수정할 수 없습니다: {path}",
                    "path": path,
                    "suggestion": "file_write(overwrite=true)로 전체 교체하거나 전용 도구를 사용하세요",
                }

            has_bom, _ = ntfs_handler.detect_bom_and_encoding(data)
            line_ending = ntfs_handler.detect_line_ending(data)

            # BOM 분리
            bom_bytes = b""
            content_bytes = data
            if has_bom and data.startswith(b"\xef\xbb\xbf"):
                bom_bytes = b"\xef\xbb\xbf"
                content_bytes = data[3:]

            # 디코딩 (BOM 이후 영역)
            try:
                text = content_bytes.decode("utf-8")
            except Exception:
                text = content_bytes.decode("utf-8", errors="replace")

            # 매치 카운트 확인 (exact match 우선)
            count = text.count(old_string)
            use_normalized = False

            if count == 0:
                # 줄바꿈 정규화 후 재시도
                norm_text = text.replace("\r\n", "\n")
                norm_old = old_string.replace("\r\n", "\n")
                count = norm_text.count(norm_old)
                if count == 0:
                    return {
                        "success": False,
                        "error": "EDIT_NO_MATCH",
                        "message": "old_string을 찾을 수 없습니다",
                        "path": path,
                        "suggestion": "file_read로 내용을 재확인하세요",
                    }
                use_normalized = True

            if count > 1 and not replace_all:
                # 라인 번호 찾기
                line_numbers = []
                lines = text.splitlines()
                old_first = old_string.splitlines()[0] if old_string else old_string
                for i, line in enumerate(lines, 1):
                    if old_first in line:
                        line_numbers.append(i)
                return {
                    "success": False,
                    "error": "EDIT_MULTI_MATCH",
                    "message": f"old_string이 {count}회 발견됩니다",
                    "path": path,
                    "details": {"match_count": count, "line_numbers": line_numbers[:10]},
                    "suggestion": "더 많은 컨텍스트를 포함하거나 replace_all=true를 사용하세요",
                }

            # 교체
            if use_normalized:
                norm_text = text.replace("\r\n", "\n")
                norm_old = old_string.replace("\r\n", "\n")
                norm_new = new_string.replace("\r\n", "\n")
                if replace_all:
                    new_text = norm_text.replace(norm_old, norm_new)
                    replacements = count
                else:
                    new_text = norm_text.replace(norm_old, norm_new, 1)
                    replacements = 1
                # 원본 줄바꿈 스타일 복원
                if line_ending == "CRLF":
                    new_text = new_text.replace("\n", "\r\n")
            else:
                # exact match 경로: new_string의 줄바꿈을 파일 스타일에 맞게 보정 후 단일 교체
                effective_new = new_string
                if line_ending == "CRLF" and "\r\n" not in new_string and "\n" in new_string:
                    effective_new = new_string.replace("\n", "\r\n")
                if replace_all:
                    new_text = text.replace(old_string, effective_new)
                    replacements = count
                else:
                    new_text = text.replace(old_string, effective_new, 1)
                    replacements = 1

            new_bytes = new_text.encode("utf-8")
            final_data = bom_bytes + new_bytes

            # 파일 쓰기 (원본 경로에 직접)
            write_err = ntfs_handler.write_file_atomic(path, final_data)
            if write_err:
                return write_err

            # T4: self-verify (edit 직후 read-back)
            verify_err = _self_verify_edit(path, new_text, "utf-8")
            if verify_err:
                return verify_err

            return {
                "success": True,
                "path": path,
                "replacements": replacements,
                "environment": environment,
            }

        finally:
            lock_manager.release(path)
    finally:
        # Codex CR-5: Layer 1 release는 Layer 2와 독립 실행
        try:
            _release_implicit(path)
        except Exception as _e:
            import sys as _sys
            _sys.stderr.write(f"[oio] Layer 1 release error: {_e}\n")


def file_delete(path: str) -> dict:
    err = security.validate_path(path)
    if err:
        return err

    # --- 고아 팀에이전트 가드 (2026-08-17) — hooks H-1 의 oio 직접호출 우회로 봉쇄 ---
    # agents/ 하위 등록 파일 개별 삭제도 추적 근거 소멸이므로 동일 취급한다.
    # ★ fail-open: 판정 불가 시 전부 통과. 상세는 orphan_guard.py 참조.
    _orphan_err = _check_orphan_guard(path)
    if _orphan_err:
        return _orphan_err

    try:
        with acquire_worker_slot(timeout=2.0) as acquired:
            if not acquired:
                return _concurrency_limit_error(path)
            # 삭제도 미러한다 — 안 하면 지운 파일이 반대편에 되살아난 상태가 된다.
            return session_mirror.apply(_file_delete_impl(path), path, deleted=True)
    except (BrokenPipeError, ConnectionResetError):
        raise
    except Exception as e:
        return _fs_error(path, e)


def _file_delete_impl(path: str) -> dict:
    if not os.path.exists(path):
        return {
            "success": False,
            "error": "FILE_NOT_FOUND",
            "message": f"파일을 찾을 수 없습니다: {path}",
            "path": path,
        }

    # Intent Gate (lock_manager.acquire 전)
    intent_err = _check_intent_gate(path)
    if intent_err:
        return intent_err

    try:
        lock_err = lock_manager.acquire(path)
        if lock_err:
            return lock_err

        try:
            _heartbeat_during_lock(path)
            os.remove(path)
            return {"success": True, "path": path, "deleted": True}
        except Exception as e:
            return {
                "success": False,
                "error": "IO_ERROR",
                "message": f"파일 삭제 실패: {e}",
                "path": path,
            }
        finally:
            lock_manager.release(path)
    finally:
        _release_implicit(path)


def file_rename(path: str, new_name: str) -> dict:
    err = security.validate_path(path)
    if err:
        return err

    try:
        with acquire_worker_slot(timeout=2.0) as acquired:
            if not acquired:
                return _concurrency_limit_error(path)
            # rename 은 양쪽을 다 봐야 한다 — 원본은 사라지고 새 이름이 생긴다.
            # 한쪽만 미러하면 반대편에 옛 이름이 남아 갈림이 된다.
            _r = _file_rename_impl(path, new_name)
            _r = session_mirror.apply(_r, path, deleted=True)
            if isinstance(_r, dict) and _r.get("new_path"):
                _r = session_mirror.apply(_r, _r["new_path"])
            return _r
    except (BrokenPipeError, ConnectionResetError):
        raise
    except Exception as e:
        return _fs_error(path, e)


def _file_rename_impl(path: str, new_name: str) -> dict:
    if not os.path.exists(path):
        return {
            "success": False,
            "error": "FILE_NOT_FOUND",
            "message": f"파일을 찾을 수 없습니다: {path}",
            "path": path,
        }

    dir_path = os.path.dirname(path)
    new_path = os.path.join(dir_path, new_name)

    new_err = security.validate_path(new_path)
    if new_err:
        return new_err

    # Intent Gate (lock_manager.acquire 전)
    intent_err = _check_intent_gate(path)
    if intent_err:
        return intent_err

    try:
        lock_err = lock_manager.acquire(path)
        if lock_err:
            return lock_err

        try:
            _heartbeat_during_lock(path)
            os.rename(path, new_path)
            return {"success": True, "old_path": path, "new_path": new_path}
        except Exception as e:
            return {
                "success": False,
                "error": "IO_ERROR",
                "message": f"파일 이름 변경 실패: {e}",
                "path": path,
            }
        finally:
            lock_manager.release(path)
    finally:
        _release_implicit(path)


def file_symlink(target: str, link_path: str) -> dict:
    err = security.validate_path(link_path)
    if err:
        return err

    # 고아 가드 (4차 보강) — link_path 가 보호 경로면 심볼릭 링크로 원본을 치환할 수 있다.
    _orphan_err = _check_orphan_guard(link_path)
    if _orphan_err:
        return _orphan_err

    try:
        with acquire_worker_slot(timeout=2.0) as acquired:
            if not acquired:
                return _concurrency_limit_error(link_path)

            if os.path.exists(link_path) or os.path.islink(link_path):
                return {
                    "success": False,
                    "error": "FILE_EXISTS",
                    "message": f"링크 경로가 이미 존재합니다: {link_path}",
                    "path": link_path,
                    "suggestion": "file_delete로 기존 파일 삭제 후 재시도하세요",
                }

            link_dir = os.path.dirname(os.path.abspath(link_path))
            os.makedirs(link_dir, exist_ok=True)

            try:
                os.symlink(target, link_path)
                return {
                    "success": True,
                    "target": target,
                    "link_path": link_path,
                    "is_relative": not os.path.isabs(target),
                }
            except Exception as e:
                return {
                    "success": False,
                    "error": "IO_ERROR",
                    "message": f"심볼릭링크 생성 실패: {e}",
                    "path": link_path,
                }
    except (BrokenPipeError, ConnectionResetError):
        raise
    except Exception as e:
        return _fs_error(link_path, e)


def file_move(source: str, destination: str, overwrite: bool = False) -> dict:
    for p in [source, destination]:
        err = security.validate_path(p)
        if err:
            return err

    try:
        with acquire_worker_slot(timeout=2.0) as acquired:
            if not acquired:
                return _concurrency_limit_error(source)
            # move 도 rename 과 같다 — source 소멸 + destination 생성을 둘 다 미러한다.
            _r = _file_move_impl(source, destination, overwrite)
            _r = session_mirror.apply(_r, source, deleted=True)
            return session_mirror.apply(_r, destination)
    except (BrokenPipeError, ConnectionResetError):
        raise
    except Exception as e:
        return _fs_error(source, e)


def _file_move_impl(source: str, destination: str, overwrite: bool) -> dict:
    if not os.path.exists(source):
        return {
            "success": False,
            "error": "FILE_NOT_FOUND",
            "message": f"파일을 찾을 수 없습니다: {source}",
            "path": source,
        }

    if os.path.exists(destination) and not overwrite:
        return {
            "success": False,
            "error": "FILE_EXISTS",
            "message": f"대상 파일이 이미 존재합니다: {destination}",
            "path": destination,
            "suggestion": "overwrite=true로 덮어쓰기하세요",
        }

    dest_dir = os.path.dirname(os.path.abspath(destination))
    os.makedirs(dest_dir, exist_ok=True)

    # Intent Gate (lock_manager.acquire 전)
    intent_err = _check_intent_gate(source)
    if intent_err:
        return intent_err

    try:
        lock_err = lock_manager.acquire(source)
        if lock_err:
            return lock_err

        try:
            _heartbeat_during_lock(source)
            shutil.move(source, destination)
            return {"success": True, "old_path": source, "new_path": destination}
        except Exception as e:
            return {
                "success": False,
                "error": "IO_ERROR",
                "message": f"파일 이동 실패: {e}",
                "path": source,
            }
        finally:
            lock_manager.release(source)
    finally:
        _release_implicit(source)


def file_copy(source: str, destination: str, overwrite: bool = False) -> dict:
    for p in [source, destination]:
        err = security.validate_path(p)
        if err:
            return err

    # 고아 가드 (4차 보강) — destination 이 보호 경로면 overwrite 로 파괴 가능하다.
    # 삭제만 막고 덮어쓰기를 열어두면 우회로가 된다.
    _orphan_err = _check_orphan_guard(destination)
    if _orphan_err:
        return _orphan_err

    try:
        with acquire_worker_slot(timeout=2.0) as acquired:
            if not acquired:
                return _concurrency_limit_error(source)
            # ★file_copy 는 destination 만 미러한다 (source 는 그대로 남으므로 무변경).★
            # 판단 근거: copy 의 부작용은 "destination 에 파일이 생긴다" 뿐이다.
            #   ofinish pre_cleanup_3c 가 goal.json → goal_{id}_completed.json 을
            #   copy 로 만드는데, 이때 사본이 한쪽 base 에만 생기면 그 자체가 새 갈림이 된다.
            #   (증적 보관이 목적인 작업이 갈림을 만드는 것은 자기모순이다.)
            # source 를 미러하지 않는 이유: copy 는 source 를 읽기만 한다. 미러하면
            #   "읽었을 뿐인데 반대편이 덮어써지는" 예기치 않은 쓰기가 된다.
            return session_mirror.apply(
                _file_copy_impl(source, destination, overwrite), destination
            )
    except (BrokenPipeError, ConnectionResetError):
        raise
    except Exception as e:
        return _fs_error(source, e)


def _file_copy_impl(source: str, destination: str, overwrite: bool) -> dict:
    if not os.path.exists(source):
        return {
            "success": False,
            "error": "FILE_NOT_FOUND",
            "message": f"파일을 찾을 수 없습니다: {source}",
            "path": source,
        }

    if os.path.exists(destination) and not overwrite:
        return {
            "success": False,
            "error": "FILE_EXISTS",
            "message": f"대상 파일이 이미 존재합니다: {destination}",
            "path": destination,
            "suggestion": "overwrite=true로 덮어쓰기하세요",
        }

    dest_dir = os.path.dirname(os.path.abspath(destination))
    os.makedirs(dest_dir, exist_ok=True)

    # Intent Gate (다른 쓰기 작업과 동일하게 적용)
    intent_err = _check_intent_gate(source)
    if intent_err:
        return intent_err

    try:
        lock_err = lock_manager.acquire(source)
        if lock_err:
            return lock_err

        try:
            _heartbeat_during_lock(source)
            shutil.copy2(source, destination)
            bytes_copied = os.path.getsize(destination)
            return {
                "success": True,
                "source": source,
                "destination": destination,
                "bytes_copied": bytes_copied,
            }
        except Exception as e:
            return {
                "success": False,
                "error": "IO_ERROR",
                "message": f"파일 복사 실패: {e}",
                "path": source,
            }
        finally:
            lock_manager.release(source)
    finally:
        _release_implicit(source)
