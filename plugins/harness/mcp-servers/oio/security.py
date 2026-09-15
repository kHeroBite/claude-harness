"""
보안 모듈: ALLOWED_ROOTS + BLOCKED_PATHS 이중 방어, Bash 차단 목록, session-env UUID 검증
"""
import os
import re

# UUID v4 형식 (36자: 8-4-4-4-12)
_UUID_PATTERN = re.compile(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')

# 배포본 기본값: 개인 홈 경로를 하드코딩하지 않고 실행 사용자의 홈을 사용한다.
# .mcp.json 의 FILEOPS_ALLOWED_ROOTS 환경변수로 덮어쓸 수 있다.
_DEFAULT_ALLOWED_ROOTS = [
    "/mnt/c/DATA/Project",
    "/mnt/c/MCP-Servers",
    os.path.expanduser("~"),
    "/tmp",
]

_DEFAULT_BLOCKED_PATHS = [
    "/mnt/c/Windows",
    "/mnt/c/Program Files",
    "/mnt/c/Program Files (x86)",
    "/etc",
    "/usr",
    "/bin",
    "/sbin",
    "/proc",
    "/sys",
]

# 위험한 Bash 명령 차단 패턴
_BASH_BLOCK_PATTERNS = [
    # 루트/루트직속 삭제 (세그먼트 시작 rm + 옵션들 + 루트류 경로 + 경계) — L-oio-rm 정정
    r"(?:^|[;&|\n]|&&|\|\|)\s*rm\s+(?:-[a-zA-Z-]+\s+)*(/|/etc|/usr|/bin|/sbin|/proc|/sys|/var|/boot|/root|/mnt|/home|/media|/dev|/lib|/lib32|/lib64|/libx32|/opt|/srv|/run|/snap|/tmp)/?\*?(?=\s|$|;|&|\|)",
    # /mnt/<드라이브>, /home/<사용자> 등 2단계 최상위 경로 자체 삭제 (하위 경로는 통과)
    r"(?:^|[;&|\n]|&&|\|\|)\s*rm\s+(?:-[a-zA-Z-]+\s+)*(/(?:mnt|home|media)/[^/\s]+)/?(?=\s|$|;|&|\|)",
    r"rm\s+-[rRf]+\s+~",             # 홈 삭제
    r"rm\s+~",                        # 홈 삭제
    r"dd\s+.*if=",                    # 디스크 직접 I/O
    r"mkfs\.",                        # 파일시스템 포맷
    r":\(\)\s*\{",                    # 포크 폭탄
    r">\s*/dev/sd",                   # 장치 직접 쓰기
    r"curl[^|]*\|\s*(ba)?sh",         # 원격 스크립트 파이프
    r"wget[^|]*\|\s*(ba)?sh",
    r"git\s+push\s+.*--force.*main",  # force push to main
    # sudo 허용 (2026-03-30): 원격 서버 배포 등 정당한 용도 허용
    # r"^\s*sudo\b",                     # sudo 권한 상승
    # r";\s*sudo\b",                     # 체인된 sudo
    # r"\|\s*sudo\b",                    # 파이프된 sudo
]

# 민감한 환경변수 패턴 (경고만)
_SENSITIVE_ENV_PATTERNS = [
    r"\$ANTHROPIC_API_KEY",
    r"\$GITHUB_TOKEN",
    r"\$AWS_SECRET",
    r"\$OPENAI_API_KEY",
]


def _get_allowed_roots():
    env = os.environ.get("FILEOPS_ALLOWED_ROOTS", "")
    if env:
        return [r.strip() for r in env.split(",") if r.strip()]
    return _DEFAULT_ALLOWED_ROOTS


def _get_blocked_paths():
    env = os.environ.get("FILEOPS_BLOCKED_PATHS", "")
    if env:
        return [p.strip() for p in env.split(",") if p.strip()]
    return _DEFAULT_BLOCKED_PATHS


def validate_path(path: str):
    """경로 유효성 검사. 성공 시 None 반환, 실패 시 에러 dict 반환."""
    if "\x00" in path or "\0" in path:
        return {
            "success": False,
            "error": "INVALID_PATH",
            "message": "경로에 null byte가 포함되어 있습니다",
            "path": repr(path),
        }

    if ".." in path:
        return {
            "success": False,
            "error": "PATH_TRAVERSAL",
            "message": "경로에 '..'이 포함되어 있습니다",
            "path": path,
            "suggestion": "'..' 없는 절대 경로를 사용하세요",
        }

    if not os.path.isabs(path):
        return {
            "success": False,
            "error": "INVALID_PARAM",
            "message": "절대 경로가 필요합니다",
            "path": path,
            "suggestion": "절대 경로(/ 또는 /mnt/c/로 시작)를 사용하세요",
        }

    # 심볼릭링크 정규화 — 실제 경로 기준으로 allowed/blocked 검사
    try:
        resolved = os.path.realpath(path)
    except (OSError, ValueError):
        return {
            "success": False,
            "error": "INVALID_PATH",
            "message": f"경로 정규화 실패: {path}",
            "path": path,
            "suggestion": "유효한 절대 경로를 사용하세요",
        }

    # realpath 결과에 '..'이 남아있을 수 있음 (방어)
    if ".." in resolved:
        return {
            "success": False,
            "error": "PATH_TRAVERSAL",
            "message": f"정규화된 경로에 '..'이 포함되어 있습니다: {resolved}",
            "path": path,
            "suggestion": "'..' 없는 절대 경로를 사용하세요",
        }

    allowed_roots = _get_allowed_roots()
    in_allowed = any(
        resolved == root or resolved.startswith(root + "/")
        for root in allowed_roots
    )
    if not in_allowed:
        return {
            "success": False,
            "error": "PATH_NOT_ALLOWED",
            "message": f"허용되지 않는 경로입니다: {path} (해석: {resolved})",
            "path": path,
            "suggestion": f"ALLOWED_ROOTS 내 경로를 사용하세요: {', '.join(allowed_roots)}",
        }

    blocked_paths = _get_blocked_paths()
    for blocked in blocked_paths:
        if resolved == blocked or resolved.startswith(blocked + "/") or resolved.startswith(blocked + "\\"):
            return {
                "success": False,
                "error": "PATH_NOT_ALLOWED",
                "message": f"차단된 경로입니다: {path} (해석: {resolved})",
                "path": path,
                "suggestion": "시스템 경로는 수정할 수 없습니다",
            }

    # session-env 하위 경로 UUID 검증
    session_env_marker = "/session-env/"
    if session_env_marker in path:
        after = path.split(session_env_marker, 1)[1]
        first_segment = after.split("/")[0] if after else ""
        if first_segment and not _UUID_PATTERN.match(first_segment):
            return {
                "success": False,
                "error": "INVALID_UUID",
                "message": f"session-env 하위에는 36자 UUID만 허용됩니다: '{first_segment}'",
                "path": path,
                "suggestion": "올바른 UUID 형식(예: 6690d4cc-b90e-4a8b-8bd9-64e78b500249)을 사용하세요",
            }

    return None  # OK


def validate_session_mirror_path(uuid: str, tail: str = "") -> bool:
    """session-env 미러 대상의 경계를 검증한다 (사이클47 — 셸판 4종 등가화).

    셸 `hooks/lib/session_mirror.sh` `_mirror_peer_path()` 의 방어와 등가다.

      (b) `:96-97`  UUID 36자 hex-hyphen 정규형   → _UUID_PATTERN 재사용
      (f) `:101`    `..` 세그먼트 거부            → tail 검사
      (a) `:47-50`  절대경로 재진입 거부          → tail 선행 `/` · `//` 거부
      (b') `:53-55` `.lock`/`.tmp` 계열 미러 금지  → 확장자 검사

    ★왜 이 함수가 필요한가★:
      Python 측 두 경로(session_ops._mirror_state_bases · session_mirror._split_session_path)는
      각각 방어가 없거나(전자) `len(uuid) != 36` 길이만 봤다(후자).
      ⇒ 36자 비-hex, `..` 탈출, `.lock`/`.tmp` 미러가 전부 통과했다.
      ⇒ 특히 `os.path.abspath` 가 `..` 를 ★정규화해 탈출을 성립시킨다★ —
        `<uuid>/../<타uuid>/state` 가 실제 타 세션 경로가 된다.

    ★단일 출처★: 새 정규식을 만들지 않고 이 모듈의 `_UUID_PATTERN` 을 그대로 쓴다.
      셸판 case 글롭(소문자 hex 전용)과 동일 규칙이므로 대문자 UUID 는 양쪽 모두 거부한다.

    ★fail-closed★: 판정 불가면 False (미러하지 않는다). 미러 누락은 갈림을 만들지만
      잘못된 미러는 ★타 세션 오염★ 이다. 위험의 크기가 다르다.

    uuid: session-env 하위 첫 세그먼트
    tail: uuid 하위 상대경로 (빈 문자열이면 tail 검사를 건너뛴다 — uuid 만 검증)
    반환: 미러해도 되면 True, 아니면 False
    """
    # (b) UUID 36자 hex-hyphen 정규형 — 단일 출처 재사용
    if not uuid or not isinstance(uuid, str):
        return False
    if not _UUID_PATTERN.match(uuid):
        return False

    if not tail:
        return True                                  # uuid 단독 검증 모드

    if not isinstance(tail, str):
        return False

    # (a) 절대경로 재진입 · 중복 슬래시 거부
    if tail.startswith("/") or tail.startswith("\\") or "//" in tail:
        return False

    # (f) `..` 세그먼트 거부 — abspath 가 정규화해 UUID 경계를 벗어나게 한다
    if ".." in tail.replace("\\", "/").split("/"):
        return False

    # (b') 불변식 5 — .lock / .tmp 계열은 미러 금지 (셸판 :53-55 그대로)
    _leaf = tail.replace("\\", "/").rsplit("/", 1)[-1]
    for _suf in (".lock", ".tmp"):
        if _leaf.endswith(_suf) or (_suf + ".") in _leaf:
            return False
    if ".mig." in _leaf:
        return False

    return True


def validate_bash_command(command: str):
    """Bash 명령 유효성 검사. 위험 명령 차단. 성공 시 None, 실패 시 에러 dict."""
    for pattern in _BASH_BLOCK_PATTERNS:
        if re.search(pattern, command, re.IGNORECASE):
            return {
                "success": False,
                "error": "COMMAND_BLOCKED",
                "message": "위험한 명령이 감지되어 차단됩니다",
                "command": command[:100],
                "suggestion": "시스템 안전을 위해 해당 명령은 실행할 수 없습니다",
            }
    # playwright-cli run-code 인라인 복잡 JS 차단 (3중 이스케이프 깨짐 방지)
    if re.search(r"playwright-cli\s+run-code", command):
        if re.search(r"[{}()=>]", command):
            return {
                "success": False,
                "error": "PLAYWRIGHT_INLINE_BLOCKED",
                "message": "playwright-cli run-code에 복잡한 JS 인라인 금지 (3중 이스케이프 깨짐)",
                "command": command[:100],
                "suggestion": "file_write로 /tmp/pw_test.js에 저장 후 playwright-cli run-file /tmp/pw_test.js 사용",
            }
    return None  # OK


def check_sensitive_env(command: str):
    """민감한 환경변수 참조 감지 (경고용). 감지된 패턴 목록 반환."""
    warnings = []
    for pattern in _SENSITIVE_ENV_PATTERNS:
        if re.search(pattern, command):
            warnings.append(pattern)
    return warnings
