# oinsights 스크립트 공용 경로 결정 헬퍼 (프로젝트 파일 탐색 + 출력 기본 경로)
import glob
import os
import re

_FALLBACK_GLOB = "/mnt/c/DATA/Project/*/{name}"


def _env_key(name):
    # LESSONS.md -> OINSIGHTS_LESSONS, CLAUDE.md -> OINSIGHTS_CLAUDE_MD 형태가 되도록 변환한다.
    base = name[:-3] if name.lower().endswith(".md") else name
    if name.lower() == "claude.md":
        base = "CLAUDE_MD"
    return "OINSIGHTS_" + re.sub(r"[^A-Za-z0-9]", "_", base).upper()


def _walk_up(start):
    # 홈 디렉토리와 / 에서 순회를 멈춘다 (홈의 LESSONS.md 오탐 방지).
    home = os.path.realpath(os.path.expanduser("~"))
    cur = os.path.realpath(start)
    while cur and cur != "/" and cur != home:
        yield cur
        parent = os.path.dirname(cur)
        if parent == cur:
            break
        cur = parent


def project_root(explicit_file=None):
    # 명시 파일이 있으면 그 부모, 없으면 CLAUDE_PROJECT_DIR, 없으면 cwd 상위에서 .claude 가 있는 디렉토리, 최후엔 cwd.
    if explicit_file:
        return os.path.dirname(os.path.abspath(os.path.expanduser(explicit_file)))
    env = os.environ.get("CLAUDE_PROJECT_DIR")
    if env and os.path.isdir(env):
        return os.path.abspath(env)
    for d in _walk_up(os.getcwd()):
        if os.path.isdir(os.path.join(d, ".claude")):
            return d
    return os.getcwd()


def resolve_project_file(name, explicit=None):
    # (경로|None, 출처) 반환. 순서: 명시 인자 > 환경변수 > CLAUDE_PROJECT_DIR > cwd 상위 > 폴백 glob.
    if explicit:
        return os.path.abspath(os.path.expanduser(explicit)), "explicit"
    env_val = os.environ.get(_env_key(name))
    if env_val:
        return os.path.abspath(os.path.expanduser(env_val)), "env:" + _env_key(name)
    proj = os.environ.get("CLAUDE_PROJECT_DIR")
    if proj:
        cand = os.path.join(os.path.expanduser(proj), name)
        if os.path.isfile(cand):
            return os.path.abspath(cand), "CLAUDE_PROJECT_DIR"
    for d in _walk_up(os.getcwd()):
        cand = os.path.join(d, name)
        if os.path.isfile(cand):
            return cand, "cwd"
    found = sorted(glob.glob(_FALLBACK_GLOB.format(name=name)))
    if found:
        return found[0], "fallback"
    return None, "not_found"


def default_output(filename, explicit=None):
    # 출력 경로 결정. 명시 없으면 session-env/<PIPELINE_UUID>/logs/<filename> (UUID 부재 시 session-env/oinsights/).
    if explicit:
        path = os.path.abspath(os.path.expanduser(explicit))
    else:
        cfg = os.path.expanduser(os.environ.get("CLAUDE_CONFIG_DIR") or "~/.claude")
        uuid = os.environ.get("PIPELINE_UUID")
        if uuid:
            base = os.path.join(cfg, "session-env", uuid, "logs")
        else:
            base = os.path.join(cfg, "session-env", "oinsights")
        path = os.path.join(base, filename)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    return path
