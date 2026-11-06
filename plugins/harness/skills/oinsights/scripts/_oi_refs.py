# oinsights 스킬·hooks·CLAUDE.md 에서 L-번호 참조를 수집하는 공용 헬퍼
import os
import re

_L_ID = re.compile(r"L-\d+")


def collect_referenced_lessons(proj_dir, claude_md_candidates):
    """프로젝트 스킬 디렉토리, hooks 디렉토리 2곳, CLAUDE.md 후보에서 L-번호를 모아 set 으로 반환한다.

    analyze_lessons_cleanup.py 의 참조 수집 로직을 그대로 옮긴 것이다(동작 동일).
    디렉토리는 .md/.sh/.json 파일만 읽고, 읽기 오류는 무시한다.
    """
    skill_dir = os.path.join(proj_dir, ".claude", "skills") + "/"
    hook_dirs = [os.path.join(proj_dir, ".claude", "hooks") + "/", os.path.expanduser(((os.environ.get("HARNESS_HOME") or os.path.expanduser("~/.harness")) + "/current" + '/hooks/'))]

    referenced = set()
    for search_dir in [skill_dir] + hook_dirs + list(claude_md_candidates):
        if os.path.isfile(search_dir):
            with open(search_dir, encoding="utf-8", errors="ignore") as f:
                txt = f.read()
            for lid in _L_ID.findall(txt):
                referenced.add(lid)
        elif os.path.isdir(search_dir):
            for root, dirs, files in os.walk(search_dir):
                for fname in files:
                    if fname.endswith((".md", ".sh", ".json")):
                        fpath = os.path.join(root, fname)
                        try:
                            with open(fpath, encoding="utf-8", errors="ignore") as f:
                                txt = f.read()
                            for lid in _L_ID.findall(txt):
                                referenced.add(lid)
                        except Exception:
                            pass
    return referenced
