"""
oio MCP 서버 메인: FastMCP + stdio + 19개 도구 등록
"""
import sys
import os
import logging

# 레거시 데몬 제거됨 — BrokenPipeError + startup-janitor로 대체 (2026-04-15)

# FastMCP 로그 레벨 억제 (INFO 로그가 stderr로 나와 oio 로그와 섞임)
os.environ.setdefault("FASTMCP_LOG_LEVEL", "WARNING")

# 로깅 설정 (stderr로 출력 — stdio transport와 충돌 방지)
logging.basicConfig(
    stream=sys.stderr,
    level=logging.WARNING,
    format="%(asctime)s [oio] %(levelname)s %(message)s",
    datefmt="%H:%M:%S",
)

# 서버 디렉토리를 sys.path에 추가 (flat 모듈 임포트 지원)
_SERVER_DIR = os.path.dirname(os.path.abspath(__file__)) if "__file__" in dir() else os.getcwd()
if _SERVER_DIR not in sys.path:
    sys.path.insert(0, _SERVER_DIR)

# ═══════════════════════════════════════════════════════════
# startup path 검증 — 대소문자/symlink 경유 실행 거부
# 대소문자만 다른 중복 경로(대소문자 무시 파일시스템)나 symlink 경유 실행을 차단한다.
# 같은 서버가 서로 다른 경로 표기로 두 벌 떠서 Lock 이 갈라지는 사고를 막는다.
# ═══════════════════════════════════════════════════════════
_abs_path = os.path.abspath(__file__)
_real_path = os.path.realpath(__file__)
if _abs_path != _real_path:
    sys.stderr.write(
        f"[oio] FATAL: path case/symlink mismatch refused\n"
        f"  exec_path: {_abs_path}\n"
        f"  real_path: {_real_path}\n"
        f"  hint: launch oio via the canonical realpath only\n"
    )
    sys.exit(2)

# __pycache__ 자동 정리 (코드 변경 후 캐시 불일치 방지 — DEV 모드 전용)
if os.environ.get("OIO_DEV_MODE") == "1":
    import shutil as _shutil
    _cache_dir = os.path.join(_SERVER_DIR, "__pycache__")
    if os.path.isdir(_cache_dir):
        _shutil.rmtree(_cache_dir, ignore_errors=True)

import threading as _threading
import signal as _signal_mod
import select as _select
import time as _time

# 레거시 데몬 제거됨 — BrokenPipeError + startup-janitor로 대체 (2026-04-15)
# stdin EOF monitor 이벤트 선언 삭제: monitor 재도입 금지

# T5: 전역 shutdown Event (io_activity_watchdog + ppid_watchdog 공유)
_global_shutdown = _threading.Event()

# 레거시 데몬 제거됨 — BrokenPipeError + startup-janitor로 대체 (2026-04-15)

# T6: io_activity_watchdog — stdio 블로킹 감지
_last_tool_activity: float = 0.0
_IO_IDLE_TIMEOUT_DEFAULT: float = 120.0


def _update_last_activity() -> None:
    global _last_tool_activity
    _last_tool_activity = _time.time()


# 레거시 데몬 제거됨 — BrokenPipeError + startup-janitor로 대체 (2026-04-15)


# threadpool 포화 모니터링 (anyio max_workers=40 — 임계값 이상 시 경고)
# 상시 스레드: ppid-watchdog(1) + threadpool-monitor(1) + session-heartbeat(1)
#              + oio-bg-supervisor(0~1, lazy) + MainThread(1) = 최소 5개
_THREADPOOL_WARN_THRESHOLD = 35  # anyio 40 - margin 5
_BACKGROUND_THREADS = 2          # MainThread + lazy bg-supervisor (데몬 4개 제거됨)

# ═══════════════════════════════════════════════════════════════════
# ⚠⚠⚠ DO NOT ADD: stdin EOF monitor thread / shutdown event ⚠⚠⚠
# ═══════════════════════════════════════════════════════════════════
# 이 함수는 FastMCP stdio transport와 구조적으로 충돌합니다.
# 과거 버그: O_NONBLOCK peek read → 첫 메시지 도달 전 EOF 오판 → SIGINT 자폭
#           → "connecting..." 멈춤 현상.
# MCP 연결 끊김 감지는 FastMCP main 루프의 BrokenPipeError가 담당합니다.
# write_guard.sh가 이 함수의 재작성을 물리적으로 차단합니다.
# ═══════════════════════════════════════════════════════════════════


# 레거시 데몬 제거됨 — BrokenPipeError + startup-janitor로 대체 (2026-04-15)

from fastmcp import FastMCP
from typing import Optional

import file_ops
import dir_ops
import find_ops
import bash_exec as bash_module
import utils
import lock_manager
import session_manager
import session_ops

mcp = FastMCP(
    name="oio",
    instructions=(
        "파일 I/O MCP 서버. "
        "NTFS/EXT4 직접 쓰기(원자적 tmpfile→replace), "
        "2계층 Lock(Intent Lock + File Mutex) 자동 관리, BOM/CRLF 보존. "
        "20개 도구: session_begin/end/state, file_read/write/edit/delete/rename/move/copy, "
        "dir_create/delete/rename/move/list_dir, find, bash_exec, lock_status, file_info, get_cwd\n"
        "\n"
        "【필수 사용 규칙】Claude Code 내장 Bash/Read/Edit/Write 도구 대신 oio 도구만 사용:\n"
        "  파일읽기=file_read, 파일쓰기=file_write, 파일수정=file_edit\n"
        "  셸명령=bash_exec(command 파라미터만 허용), 디렉토리=dir_create/dir_delete\n"
        "  파일이동=file_move, 복사=file_copy, 삭제=file_delete, 탐색=list_dir/find"
    ),
)

# 레거시 데몬 제거됨 — BrokenPipeError + startup-janitor로 대체 (2026-04-15)
# _start_stdin_eof_monitor() — DISABLED: FastMCP stdio와 충돌하여 서버 조기 종료 유발.
# 원인: monitor가 stdin을 O_NONBLOCK으로 변경 후 peek read, Claude Code의 첫 메시지
# 도달 전 os.read()가 b""를 반환하면 EOF로 오판하여 SIGINT 자폭 → connecting… 멈춤.
# MCP 연결 끊김은 FastMCP의 BrokenPipeError/ConnectionResetError로 이미 감지됨 (main 루프).


# ─── 세션 도구 (3개) ──────────────────────────────────────────────────────

@mcp.tool()
def session_begin(
    session_id: Optional[str] = None,
    files: Optional[list] = None,
    classification: Optional[str] = None,
    mode: str = "strict",
    wait_seconds: int = 3,
    uuid: Optional[str] = None,
    sid: Optional[str] = None,
    agent_role: Optional[str] = None,
) -> dict:
    """세션 시작 + 파일 Intent Lock 획득. mode: strict|partial."""
    effective_sid = session_id or uuid or sid
    if not effective_sid:
        return {"success": False, "error": "MISSING_PARAM", "message": "session_id는 필수입니다 (uuid/sid도 허용)"}
    effective_files = files or []
    # agent_role은 참고 정보 — classification으로 전달 가능
    effective_classification = classification or agent_role
    return session_manager.session_begin(
        effective_sid, effective_files, effective_classification, mode, wait_seconds
    )


@mcp.tool()
def session_end(
    session_id: Optional[str] = None,
    uuid: Optional[str] = None,
    sid: Optional[str] = None,
) -> dict:
    """세션 종료 + Intent Lock 해제 + FIFO 양도."""
    effective_sid = session_id or uuid or sid
    if not effective_sid:
        return {"success": False, "error": "MISSING_PARAM", "message": "session_id는 필수입니다 (uuid/sid도 허용)"}
    return session_manager.session_end(effective_sid)


@mcp.tool()
def session_state(
    uuid: str,
    key: str,
    value: str,
    append: bool = False,
    force: bool = False,
) -> dict:
    """세션 상태 파일 원자적 쓰기. state 키는 '{value} {uuid}' 자동 포함. value='increment'는 flock 원자적 +1.
    force=True: 상태 전이 유효성 검증 건너뜀 (oresume/oclean 긴급 리셋 전용)."""
    return session_ops.session_state(uuid, key, value, append, force)


# ─── 파일 도구 (7개) ───────────────────────────────────────────────────────

@mcp.tool()
def file_read(
    path: Optional[str] = None,
    file_path: Optional[str] = None,
    filepath: Optional[str] = None,
    offset: int = 0,
    limit: int = 2000,
    start_line: int | None = None,
    end_line: int | None = None,
) -> dict:
    """파일 읽기. offset/limit 또는 start_line/end_line으로 부분 읽기 지원. BOM/CRLF/환경 정보 포함."""
    effective_path = path or file_path or filepath
    if not effective_path:
        return {"success": False, "error": "MISSING_PARAM", "message": "path는 필수입니다 (file_path도 허용)"}
    return file_ops.file_read(effective_path, offset, limit, start_line, end_line)


@mcp.tool()
def file_write(
    path: Optional[str] = None,
    file_path: Optional[str] = None,
    content: Optional[str] = None,
    new_text: Optional[str] = None,
    text: Optional[str] = None,
    data: Optional[str] = None,
    body: Optional[str] = None,
    new_content: Optional[str] = None,
    overwrite: bool = False,
    force: Optional[bool] = None,
    create_dirs: bool = True,
    encoding: str = "auto",
    line_ending: str = "auto",
) -> dict:
    """파일 생성/전체 덮어쓰기. 원자적 쓰기(tmpfile→replace). overwrite=false가 기본(안전).
    BOM/CRLF 자동 보존(auto). .sh 파일은 LF 자동 강제(line_ending=auto). NTFS 경로 안전."""
    effective_path = path or file_path
    if not effective_path:
        return {"success": False, "error": "MISSING_PARAM", "message": "path는 필수입니다 (file_path도 허용)"}
    effective_content = content or new_text or text or data or body or new_content
    if effective_content is None:
        return {"success": False, "error": "MISSING_PARAM", "message": "content는 필수입니다 (new_text/text/data/body도 허용)"}
    effective_overwrite = force if force is not None else overwrite
    return file_ops.file_write(effective_path, effective_content, effective_overwrite, create_dirs, encoding, line_ending)


@mcp.tool()
def file_edit(
    path: Optional[str] = None,
    file_path: Optional[str] = None,
    filepath: Optional[str] = None,
    old_string: Optional[str] = None,
    new_string: Optional[str] = None,
    old_text: Optional[str] = None,
    new_text: Optional[str] = None,
    old_content: Optional[str] = None,
    new_content: Optional[str] = None,
    old: Optional[str] = None,
    new: Optional[str] = None,
    search: Optional[str] = None,
    replace: Optional[str] = None,
    replace_all: bool = False,
    global_replace: Optional[bool] = None,
) -> dict:
    """부분 수정(old→new). Claude Code Edit과 100% 호환. Lock 자동. NTFS 안전."""
    effective_path = path or file_path or filepath
    if not effective_path:
        return {"success": False, "error": "MISSING_PARAM", "message": "path는 필수입니다 (file_path/filepath도 허용)"}
    effective_old = old_string if old_string is not None else (old_text if old_text is not None else (old_content if old_content is not None else (old if old is not None else search)))
    effective_new = new_string if new_string is not None else (new_text if new_text is not None else (new_content if new_content is not None else (new if new is not None else replace)))
    if effective_old is None or effective_new is None:
        return {"success": False, "error": "MISSING_PARAM", "message": "old_string과 new_string은 필수입니다 (old_text/new_text/old/new도 허용)"}
    effective_replace_all = global_replace if global_replace is not None else replace_all
    return file_ops.file_edit(effective_path, effective_old, effective_new, effective_replace_all)


@mcp.tool()
def file_delete(path: Optional[str] = None, file_path: Optional[str] = None) -> dict:
    """파일 삭제. Lock 자동 확인."""
    effective_path = path or file_path
    if not effective_path:
        return {"success": False, "error": "MISSING_PARAM", "message": "path는 필수입니다 (file_path도 허용)"}
    return file_ops.file_delete(effective_path)


@mcp.tool()
def file_rename(
    path: Optional[str] = None, file_path: Optional[str] = None,
    new_name: Optional[str] = None,
    name: Optional[str] = None, to: Optional[str] = None, new_path: Optional[str] = None,
) -> dict:
    """파일명 변경 (이름만, 디렉토리 이동 아님)."""
    effective_path = path or file_path
    if not effective_path:
        return {"success": False, "error": "MISSING_PARAM", "message": "path는 필수입니다 (file_path도 허용)"}
    effective_name = new_name or name or to or new_path
    if not effective_name:
        return {"success": False, "error": "MISSING_PARAM", "message": "new_name은 필수입니다 (name/to도 허용)"}
    return file_ops.file_rename(effective_path, effective_name)


@mcp.tool()
def file_symlink(
    target: Optional[str] = None, link_path: Optional[str] = None,
    src: Optional[str] = None, source: Optional[str] = None,
    path: Optional[str] = None, dest: Optional[str] = None, link: Optional[str] = None,
) -> dict:
    """심볼릭링크 생성. target=원본 경로, link_path=링크 경로. 상대/절대 모두 지원."""
    effective_target = target or src or source
    effective_link = link_path or path or dest or link
    if not effective_target or not effective_link:
        return {"success": False, "error": "MISSING_PARAM", "message": "target과 link_path는 필수입니다 (src/source, path/dest/link도 허용)"}
    return file_ops.file_symlink(effective_target, effective_link)


@mcp.tool()
def file_move(
    source: Optional[str] = None, destination: Optional[str] = None, overwrite: bool = False,
    src: Optional[str] = None, dest: Optional[str] = None, dst: Optional[str] = None,
    path: Optional[str] = None, to: Optional[str] = None, target: Optional[str] = None,
) -> dict:
    """파일 이동. overwrite=false가 기본."""
    effective_src = source or src or path
    effective_dst = destination or dest or dst or to or target
    if not effective_src or not effective_dst:
        return {"success": False, "error": "MISSING_PARAM", "message": "source와 destination은 필수입니다 (src/dest/path/to도 허용)"}
    return file_ops.file_move(effective_src, effective_dst, overwrite)


@mcp.tool()
def file_copy(
    source: Optional[str] = None, destination: Optional[str] = None, overwrite: bool = False,
    src: Optional[str] = None, dest: Optional[str] = None, dst: Optional[str] = None,
    path: Optional[str] = None, to: Optional[str] = None, target: Optional[str] = None,
) -> dict:
    """파일 복사. BOM/메타데이터 보존. overwrite=false가 기본."""
    effective_src = source or src or path
    effective_dst = destination or dest or dst or to or target
    if not effective_src or not effective_dst:
        return {"success": False, "error": "MISSING_PARAM", "message": "source와 destination은 필수입니다 (src/dest/path/to도 허용)"}
    return file_ops.file_copy(effective_src, effective_dst, overwrite)


# ─── 검색 도구 (1개) ──────────────────────────────────────────────────────

@mcp.tool()
def find(
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
    """파일/디렉토리 검색. os.walk 기반 네이티브 구현. timeout_seconds 초과 시 조기 종료(truncated=True).
    ⚠ max_depth=-1은 무제한 탐색. NTFS /mnt/c/ 루트에서는 max_depth=3 이하 권장 (timeout 30s 보호됨)."""
    if max_depth == -1 and path.startswith("/mnt/"):
        sys.stderr.write(f"[oio] WARNING: find on NTFS path with max_depth=-1: {path}\n")
        sys.stderr.flush()
    outcome = find_ops.file_find(
        path=path,
        pattern=pattern,
        file_type=file_type,
        max_depth=max_depth,
        min_size=min_size,
        max_size=max_size,
        modified_after=modified_after,
        modified_before=modified_before,
        exclude=exclude or [],
        max_results=max_results,
        timeout_seconds=timeout_seconds,
    )
    return {"result": outcome["items"], "truncated": outcome["truncated"]}


# ─── 디렉토리 도구 (5개) ──────────────────────────────────────────────────

@mcp.tool()
def dir_create(path: Optional[str] = None, file_path: Optional[str] = None, parents: bool = True, recursive: Optional[bool] = None, exist_ok: Optional[bool] = None) -> dict:
    """디렉토리 생성 (mkdir -p 기본)."""
    effective_path = path or file_path
    if not effective_path:
        return {"success": False, "error": "MISSING_PARAM", "message": "path는 필수입니다 (file_path도 허용)"}
    effective_parents = recursive if recursive is not None else (exist_ok if exist_ok is not None else parents)
    return dir_ops.dir_create(effective_path, effective_parents)


@mcp.tool()
def dir_delete(path: Optional[str] = None, file_path: Optional[str] = None, recursive: bool = False, force: Optional[bool] = None) -> dict:
    """디렉토리 삭제. recursive=false는 빈 디렉토리만 삭제 (안전)."""
    effective_path = path or file_path
    if not effective_path:
        return {"success": False, "error": "MISSING_PARAM", "message": "path는 필수입니다 (file_path도 허용)"}
    effective_recursive = force if force is not None else recursive
    return dir_ops.dir_delete(effective_path, effective_recursive)


@mcp.tool()
def dir_rename(path: Optional[str] = None, file_path: Optional[str] = None, new_name: Optional[str] = None, name: Optional[str] = None, to: Optional[str] = None) -> dict:
    """디렉토리명 변경."""
    effective_path = path or file_path
    if not effective_path:
        return {"success": False, "error": "MISSING_PARAM", "message": "path는 필수입니다 (file_path도 허용)"}
    effective_name = new_name or name or to
    if not effective_name:
        return {"success": False, "error": "MISSING_PARAM", "message": "new_name은 필수입니다 (name/to도 허용)"}
    return dir_ops.dir_rename(effective_path, effective_name)


@mcp.tool()
def dir_move(
    source: Optional[str] = None, destination: Optional[str] = None,
    src: Optional[str] = None, dest: Optional[str] = None, dst: Optional[str] = None,
    path: Optional[str] = None, to: Optional[str] = None, target: Optional[str] = None,
) -> dict:
    """디렉토리 이동."""
    effective_src = source or src or path
    effective_dst = destination or dest or dst or to or target
    if not effective_src or not effective_dst:
        return {"success": False, "error": "MISSING_PARAM", "message": "source와 destination은 필수입니다 (src/dest/path/to도 허용)"}
    return dir_ops.dir_move(effective_src, effective_dst)


@mcp.tool()
def list_dir(
    path: Optional[str] = None,
    file_path: Optional[str] = None,
    pattern: Optional[str] = None,
    recursive: bool = False,
    include_hidden: bool = False,
    limit: int = 500,
) -> dict:
    """디렉토리 목록 조회. glob 패턴(*.cs 등) 지원. recursive=false가 기본."""
    effective_path = path or file_path
    if not effective_path:
        return {"success": False, "error": "MISSING_PARAM", "message": "path는 필수입니다 (file_path도 허용)"}
    return dir_ops.list_dir(effective_path, pattern, recursive, include_hidden, limit)


# ─── 실행 도구 (1개) ──────────────────────────────────────────────────────

@mcp.tool()
def bash_exec(
    command: Optional[str] = None,
    cmd: Optional[str] = None,
    timeout_ms: int = 120_000,
    timeout: Optional[int] = None,
    working_dir: Optional[str] = None,
    workdir: Optional[str] = None,
    cwd: Optional[str] = None,
    env: Optional[dict] = None,
    environment: Optional[dict] = None,
    environ: Optional[dict] = None,
    run_in_background: bool = False,
) -> dict:
    """셸 명령 실행. 차단 목록 보안. 기본 타임아웃 120초, 최대 600초. run_in_background=true 시 백그라운드 실행.
    허용 파라미터: command(필수, cmd도 허용), timeout_ms, working_dir(workdir/cwd도 허용), env, run_in_background.
    ⚠ pattern/path/output_mode/-n 등 Grep 파라미터 혼용 금지 — bash_exec는 셸 명령만 실행."""
    effective_command = command if command is not None else cmd
    if effective_command is None:
        return {"success": False, "error": "MISSING_PARAM", "message": "command는 필수입니다 (cmd도 허용)"}
    effective_timeout = timeout if timeout is not None else timeout_ms
    effective_workdir = working_dir or workdir or cwd
    effective_env = env or environment or environ
    return bash_module.bash_exec(effective_command, effective_timeout, effective_workdir, effective_env, run_in_background)


# ─── 유틸리티 도구 (2개) ─────────────────────────────────────────────────

@mcp.tool()
def get_cwd() -> dict:
    """현재 작업 디렉토리 반환. pwd 대체."""
    return utils.get_cwd()


@mcp.tool()
def lock_status(path: Optional[str] = None) -> dict:
    """Lock 현황 조회 (Intent Lock + File Lock 양쪽)."""
    return utils.lock_status(path)


@mcp.tool()
def file_info(path: Optional[str] = None, file_path: Optional[str] = None) -> dict:
    """파일 메타데이터 조회 (존재 여부, 크기, BOM, CRLF, 환경)."""
    effective_path = path or file_path
    if not effective_path:
        return {"success": False, "error": "MISSING_PARAM", "message": "path는 필수입니다 (file_path도 허용)"}
    return utils.file_info(effective_path)


@mcp.tool()
def image_resize(
    path: Optional[str] = None,
    output_path: Optional[str] = None,
    max_width: int = 1280,
    max_height: int = 720,
    quality: int = 85,
) -> dict:
    """이미지 리사이즈 도구 — Claude API 400 "Could not process image" 방지용.

    Read 도구로 1MB 이상 이미지 열기 시 Claude API 400 오류 발생.
    이 도구로 먼저 리사이즈 후 Read 하라.

    파라미터:
        path: 원본 이미지 경로 (.png/.jpg/.jpeg/.webp)
        output_path: 출력 경로 (생략 시 원본명_small.확장자)
        max_width: 최대 가로 픽셀 (기본 1280)
        max_height: 최대 세로 픽셀 (기본 720)
        quality: JPEG/WebP 압축 품질 0-100 (기본 85, PNG는 무시)

    반환: {success, output_path, original_size_mb, output_size_mb, original_wh, output_wh}
    """
    try:
        from PIL import Image
        import os as _os

        if not path:
            return {"success": False, "error": "MISSING_PARAM", "message": "path는 필수입니다"}

        if not _os.path.isfile(path):
            return {"success": False, "error": "NOT_FOUND", "message": f"파일 없음: {path}"}

        # 지원 확장자 검증
        lower = path.lower()
        if not any(lower.endswith(ext) for ext in (".png", ".jpg", ".jpeg", ".webp", ".gif")):
            return {"success": False, "error": "UNSUPPORTED_FORMAT", "message": "지원 포맷: png/jpg/jpeg/webp/gif"}

        # 출력 경로 자동 생성
        if not output_path:
            base = _os.path.basename(path)
            dir_ = _os.path.dirname(path)
            name, ext = _os.path.splitext(base)
            output_path = _os.path.join(dir_, f"{name}_small{ext}")

        # 원본 정보
        original_size_bytes = _os.path.getsize(path)
        img = Image.open(path)
        original_wh = img.size  # (width, height)

        # 리사이즈 (thumbnail은 비율 유지하며 max_width x max_height 이내로 축소)
        img.thumbnail((max_width, max_height), Image.LANCZOS)
        output_wh = img.size

        # 저장
        save_kwargs = {}
        lower_out = output_path.lower()
        if lower_out.endswith(".jpg") or lower_out.endswith(".jpeg"):
            save_kwargs = {"quality": quality, "optimize": True}
        elif lower_out.endswith(".webp"):
            save_kwargs = {"quality": quality}
        elif lower_out.endswith(".png"):
            save_kwargs = {"optimize": True}

        img.save(output_path, **save_kwargs)
        output_size_bytes = _os.path.getsize(output_path)

        return {
            "success": True,
            "output_path": output_path,
            "original_size_mb": round(original_size_bytes / 1048576, 2),
            "output_size_mb": round(output_size_bytes / 1048576, 2),
            "original_wh": list(original_wh),
            "output_wh": list(output_wh),
            "message": f"리사이즈 완료: {original_wh} → {output_wh}, {round(original_size_bytes/1048576,2)}MB → {round(output_size_bytes/1048576,2)}MB",
        }
    except ImportError:
        return {"success": False, "error": "PILLOW_MISSING", "message": "pip install Pillow 필요"}
    except Exception as e:
        return {"success": False, "error": "IMAGE_RESIZE_ERROR", "message": str(e)}


import atexit as _atexit


# 레거시 데몬 제거됨 — BrokenPipeError + startup-janitor로 대체 (2026-04-15)
def _log_exit():
    sys.stderr.write("[oio] atexit: process terminating\n")
    sys.stderr.flush()


_atexit.register(_log_exit)


# SIGPIPE는 프로세스 레벨에서 ignore 유지 — stdio write 시 EPIPE→BrokenPipeError로 승격
if hasattr(_signal_mod, 'SIGPIPE'):
    _signal_mod.signal(_signal_mod.SIGPIPE, _signal_mod.SIG_IGN)


# SIGTERM → SIGINT 브리지: FastMCP(anyio)는 asyncio event loop에서 SIGINT만 graceful 처리.
# SIGTERM은 asyncio가 hook하지 않아 default terminate(-15). 따라서 프로세스 레벨에서 SIGTERM을
# 받아 자신에게 SIGINT를 다시 발사하여 anyio graceful shutdown 경로로 우회시킨다.
# 레거시 데몬 제거됨 — BrokenPipeError + startup-janitor로 대체 (2026-04-15)
def _sigterm_to_sigint(signum: int, frame: object) -> None:
    # stdin EOF monitor 이벤트 참조 삭제됨 (재도입 금지)
    sys.stderr.write("[oio] received SIGTERM, converting to SIGINT\n")
    sys.stderr.flush()
    try:
        import asyncio
        loop = asyncio.get_running_loop()
        loop.call_soon_threadsafe(
            lambda: os.kill(os.getpid(), _signal_mod.SIGINT)
        )
    except RuntimeError:
        os.kill(os.getpid(), _signal_mod.SIGINT)


# 주의: signal.signal()은 anyio.run() 시작 시 asyncio loop가 override할 수 있음.
# 하지만 asyncio는 SIGTERM을 default로 hook하지 않으므로 우리 등록이 살아남음 (Python 3.12 확인).
_signal_mod.signal(_signal_mod.SIGTERM, _sigterm_to_sigint)


def _startup_janitor():
    """기동 시 orphan 정리 (Codex CR-3: crash-only 설계 대응).

    OOM/SIGKILL/WSL2 VM 종료 시 atexit/signal handler 무력 → 재기동 시 복구.

    정리 대상:
    1. /tmp/oio-locks/*.lock — pid 사망 + grace 지남 orphan (Layer 2)
    2. /tmp/oio-locks/*.lockdir — 레거시 디렉토리 잔재 (CR-1 전환 전)
    3. /tmp/oio_bg_*.log — 7일 경과 orphan BG 로그
    4. ~/.claude/oio-locks/files/*/owner — pid 사망 시 unlink (Layer 1 Intent)

    원칙: 10초 grace 유지, 실패는 조용히 무시 (최선 노력).
    """
    import glob
    import shutil as _shutil
    import time as _time
    now = _time.time()
    cleaned = {"l2_locks": 0, "l2_lockdirs": 0, "bg_logs": 0, "l1_owners": 0}

    # 1. Layer 2 orphan .lock 파일
    for path in glob.glob("/tmp/oio-locks/*.lock"):
        try:
            st = os.stat(path)
            if (now - st.st_mtime) < 10:
                continue  # grace
            with open(path, "r", encoding="utf-8") as f:
                lines = f.read().strip().splitlines()
            alive = False
            if len(lines) >= 2:
                try:
                    pid = int(lines[1])
                    if pid > 0:
                        os.kill(pid, 0)
                        alive = True
                except (ValueError, ProcessLookupError, PermissionError, OSError):
                    pass
            if not alive:
                os.unlink(path)
                cleaned["l2_locks"] += 1
        except OSError:
            continue

    # 2. 레거시 .lockdir 디렉토리 (CR-1 전환 잔재)
    for path in glob.glob("/tmp/oio-locks/*.lockdir"):
        try:
            st = os.stat(path)
            if (now - st.st_mtime) < 10:
                continue
            _shutil.rmtree(path, ignore_errors=True)
            cleaned["l2_lockdirs"] += 1
        except OSError:
            continue

    # 3. BG log 7일 orphan
    for path in glob.glob("/tmp/oio_bg_*.log"):
        try:
            st = os.stat(path)
            if (now - st.st_mtime) < 7 * 24 * 3600:
                continue
            os.unlink(path)
            cleaned["bg_logs"] += 1
        except OSError:
            continue

    # 4. Layer 1 Intent Lock orphan (key=value 형식)
    home_files = os.path.expanduser("~/.claude/oio-locks/files")
    if os.path.isdir(home_files):
        for owner_path in glob.glob(os.path.join(home_files, "*", "owner")):
            try:
                st = os.stat(owner_path)
                if (now - st.st_mtime) < 10:
                    continue
                # key=value 파싱해서 pid 추출
                with open(owner_path, "r", encoding="utf-8") as f:
                    data = {}
                    for line in f:
                        line = line.strip()
                        if "=" in line:
                            k, v = line.split("=", 1)
                            data[k] = v
                alive = False
                try:
                    pid = int(data.get("pid", -1))
                    if pid > 0:  # -1/0은 특수값(모든 프로세스/프로세스그룹) — 오판 방지
                        os.kill(pid, 0)
                        alive = True
                except (ValueError, ProcessLookupError, PermissionError, OSError):
                    pass
                if not alive:
                    os.unlink(owner_path)
                    cleaned["l1_owners"] += 1
            except OSError:
                continue

    # 5. Orphan oio/fio 프로세스 정리 (원인 2 대응)
    #    - fio-mcp-server: 더 이상 사용하지 않음 → 무조건 SIGTERM
    #    - oio-mcp-server: ppid 조건 검사 (ppid=1 OR 사망 OR cmdline에 claude 없음)
    #    비정규 경로(대소문자 불일치/symlink 경유) 실행은 기동 시점의 startup path 검증이
    #    담당하므로 여기서 별도로 다루지 않는다.
    target_cmds = ("oio-mcp-server/server.py", "fio-mcp-server/server.py")
    my_pid = os.getpid()
    for cmdline_path in glob.glob("/proc/*/cmdline"):
        try:
            pid = int(cmdline_path.split("/")[2])
        except (ValueError, IndexError):
            continue
        if pid == my_pid:
            continue
        try:
            cmdline = open(cmdline_path, "rb").read().decode(errors="replace")
            if not any(tc in cmdline for tc in target_cmds):
                continue

            # fio는 더 이상 사용 안 함 → 무조건 SIGTERM
            if "fio-mcp-server/server.py" in cmdline:
                try:
                    os.kill(pid, _signal_mod.SIGTERM)
                    cleaned["fio_deprecated"] = cleaned.get("fio_deprecated", 0) + 1
                except (ProcessLookupError, PermissionError):
                    pass
                continue

            # oio: ppid 조건 검사
            status_text = open(f"/proc/{pid}/status").read()
            ppid_line = [l for l in status_text.splitlines() if l.startswith("PPid:")][0]
            ppid = int(ppid_line.split()[1])

            should_kill = False
            if ppid == 1:
                # 이미 orphan
                should_kill = True
            else:
                # 부모 생존 확인
                try:
                    os.kill(ppid, 0)
                    parent_alive = True
                except (ProcessLookupError, PermissionError):
                    parent_alive = False

                if not parent_alive:
                    should_kill = True
                else:
                    # 부모가 claude 프로세스인지 확인
                    try:
                        parent_cmdline = open(f"/proc/{ppid}/cmdline", "rb").read().decode(errors="replace")
                        if "claude" not in parent_cmdline:
                            should_kill = True
                    except (FileNotFoundError, PermissionError):
                        should_kill = True

            if should_kill:
                os.kill(pid, _signal_mod.SIGTERM)
                cleaned["orphan_procs"] = cleaned.get("orphan_procs", 0) + 1
                # SIGTERM 후 1초 대기, 여전히 살아있으면 SIGKILL
                import time as _t
                _t.sleep(1.0)
                try:
                    os.kill(pid, 0)
                    os.kill(pid, _signal_mod.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
        except (FileNotFoundError, ProcessLookupError, IndexError, PermissionError):
            continue

    if any(cleaned.values()):
        sys.stderr.write(f"[oio] startup janitor: {cleaned}\n")
        sys.stderr.flush()


def main():
    # janitor는 루프 밖에서 1회만 실행
    _janitor_thread = _threading.Thread(
        target=_startup_janitor,
        daemon=True,
        name="startup-janitor"
    )
    _janitor_thread.start()

    _max_restarts = 3
    for attempt in range(_max_restarts):
        try:
            mcp.run(transport="stdio", show_banner=False)
            break
        except KeyboardInterrupt:
            sys.stderr.write("[oio] EXIT reason=KeyboardInterrupt\n")
            break
        except (BrokenPipeError, ConnectionResetError) as e:
            sys.stderr.write(f"[oio] EXIT reason=client_disconnected ({type(e).__name__})\n")
            break
        except Exception as e:
            if attempt < _max_restarts - 1:
                sys.stderr.write(f"[oio] RESTART attempt {attempt+1}/{_max_restarts}: {e}\n")
                sys.stderr.flush()
                _threading.Event().wait(timeout=1.0)
            else:
                logging.exception("[oio] EXIT reason=unexpected_exception (max restarts)")
    sys.stderr.flush()


if __name__ == "__main__":
    main()
