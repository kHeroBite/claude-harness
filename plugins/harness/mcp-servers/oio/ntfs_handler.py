"""
파일 I/O 유틸리티: BOM/CRLF 보존, 원자적 쓰기.
모든 경로를 동일하게 처리 (NTFS/EXT4 구분 없음).
"""
import os
import tempfile


def is_ntfs_path(path: str) -> bool:
    """NTFS(WSL drvfs) 경로인지 확인."""
    return path.startswith("/mnt/") and len(path) > 6 and path[5].isalpha() and (
        len(path) == 6 or path[6] == "/"
    )


def get_environment(path: str) -> str:
    """경로의 환경 이름 반환."""
    if is_ntfs_path(path):
        return "NTFS_WSL"
    return "EXT4"





def detect_bom_and_encoding(data: bytes) -> tuple:
    """BOM 감지 및 인코딩 감지. (has_bom, encoding) 반환."""
    if data.startswith(b"\xef\xbb\xbf"):
        return True, "utf-8-sig"
    if data.startswith(b"\xff\xfe"):
        return True, "utf-16-le"
    if data.startswith(b"\xfe\xff"):
        return True, "utf-16-be"
    return False, "utf-8"


def detect_line_ending(data: bytes) -> str:
    """줄바꿈 스타일 감지. 'CRLF' 또는 'LF' 반환."""
    if b"\r\n" in data:
        return "CRLF"
    return "LF"





def read_file_binary(path: str) -> tuple:
    """파일 읽기 (바이너리). (data, error) 반환."""
    try:
        with open(path, "rb") as f:
            return f.read(), None
    except FileNotFoundError:
        return b"", {
            "success": False,
            "error": "FILE_NOT_FOUND",
            "message": f"파일을 찾을 수 없습니다: {path}",
            "path": path,
            "suggestion": "file_info로 존재 여부를 확인하세요",
        }
    except PermissionError:
        return b"", {
            "success": False,
            "error": "PERMISSION_DENIED",
            "message": f"파일 접근 권한이 없습니다: {path}",
            "path": path,
            "suggestion": "파일 권한을 확인하세요",
        }
    except Exception as e:
        return b"", {
            "success": False,
            "error": "IO_ERROR",
            "message": f"파일 읽기 실패: {e}",
            "path": path,
        }


def write_file_atomic(path: str, data: bytes):
    """원자적 파일 쓰기 (tmpfile → rename). 성공 시 None, 실패 시 에러 dict."""
    dir_path = os.path.dirname(os.path.abspath(path))
    os.makedirs(dir_path, exist_ok=True)

    # 기존 파일 권한 보존 (mkstemp는 0600으로 생성하므로)
    orig_mode = None
    if os.path.exists(path):
        try:
            orig_mode = os.stat(path).st_mode
        except Exception:
            pass

    tmp_path = None
    error = None
    try:
        fd, tmp_path = tempfile.mkstemp(dir=dir_path, prefix=".tmp_oio_")
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(data)
        except Exception:
            try:
                os.close(fd)
            except Exception:
                pass
            raise
        if orig_mode is not None:
            os.chmod(tmp_path, orig_mode)
        # P1-4: os.replace 재시도 (exponential backoff — NTFS 간헐적 PermissionError 대응, AV 소프트웨어 간섭 포함)
        _replace_delays = [0.05, 0.1, 0.3, 0.5, 1.0]
        _last_replace_exc = None
        for _attempt, _delay in enumerate(_replace_delays):
            try:
                os.replace(tmp_path, path)
                _last_replace_exc = None
                break
            except (OSError, PermissionError) as _exc:
                _last_replace_exc = _exc
                if _attempt < len(_replace_delays) - 1:
                    import time as _time
                    _time.sleep(_delay)
        if _last_replace_exc is not None:
            raise _last_replace_exc
        return None
    except Exception as e:
        error = {
            "success": False,
            "error": "IO_ERROR",
            "message": f"파일 쓰기 실패: {e}",
            "path": path,
        }
        return error
    finally:
        # tmpfile 잔류 방지: os.replace 성공 시 tmp_path는 이미 없으므로 안전
        if tmp_path:
            try:
                os.remove(tmp_path)
            except OSError:
                pass
