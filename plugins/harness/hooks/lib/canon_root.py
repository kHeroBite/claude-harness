#!/usr/bin/env python3
# 경로에서 프로젝트 루트·정본 경로(plan/test/tools root)·PLAN 판정 시작 여부를 해석하는 공용 해석기
"""docs_gate.py · PreToolUse_plan_ref_gate.sh · PostToolUse_plan_read_log.sh 가 함께 쓰는 루트·설정 해석기.

사용(CLI): python3 canon_root.py --path <경로>
출력: stdout 한 줄 JSON
  {"project_root": <절대경로|null>, "plan_root": "<상대경로>", "plan_root_abs": <절대경로|null>,
   "plan_active": bool, "plan_root_invalid": bool, "test_root": "...", "tools_root": "...", "warnings": [...]}
종료 코드: 0(해석 결과가 null 이어도 0). 인자 오류만 2.

규칙:
  - 프로젝트 루트 = <경로>(파일이면 그 폴더)에서 위로 올라가며 표식을 가진 첫 디렉터리.
    표식은 `.git` 파일 또는 디렉터리(worktree 의 .git 은 파일이다), 또는 `.claude` 디렉터리다.
    $HOME 자체와 그 조상(/ 포함)은 루트가 아니다. 찾지 못하면 null.
  - plan_root = <루트>/.claude/docs_gate.json 의 canon.plan_root, 없으면 "plan".
    절대경로이거나 경로 조각에 '..' 가 있으면 거부한다(plan_root_invalid=true, plan_active=false, plan_root_abs=null).
    설정 파일이 없거나 파싱에 실패하면 기본값을 쓴다(파싱 실패는 warnings 에 남긴다).
  - plan_active = plan_root 폴더 AND plan_root/index.json 파일이 모두 있을 때만 true.
  - test_root·tools_root 는 같은 검증을 하되 거부 시 기본값(test·tools)으로 돌아간다.
import 사용: from canon_root import resolve; resolve(path) → 위 dict
"""
import json
import os
import sys

기본_정본 = {"plan_root": "plan", "test_root": "test", "tools_root": "tools"}


def _정규화(p):
    return os.path.normpath(os.path.abspath(os.path.expanduser(p)))


def _제외_집합():
    """$HOME 과 그 조상 전부(루트가 될 수 없는 디렉터리)."""
    home = os.environ.get("HOME") or ""
    제외 = set()
    if home:
        d = _정규화(home)
        while True:
            제외.add(d)
            부모 = os.path.dirname(d)
            if 부모 == d:
                break
            d = 부모
    else:
        제외.add("/")
    return 제외


def 프로젝트_루트(path):
    if not path:
        return None
    d = _정규화(path)
    if os.path.exists(d) and not os.path.isdir(d):
        d = os.path.dirname(d)
    제외 = _제외_집합()
    while True:
        if d not in 제외:
            if os.path.lexists(os.path.join(d, ".git")) or os.path.isdir(os.path.join(d, ".claude")):
                return d
        부모 = os.path.dirname(d)
        if 부모 == d:
            return None
        d = 부모


def _유효한_상대경로(v):
    if not isinstance(v, str):
        return None
    v = v.strip()
    if not v or os.path.isabs(v) or v.startswith("~"):
        return None
    if ".." in [x for x in v.replace("\\", "/").split("/")]:
        return None
    v = v.strip("/")
    return v or None


def resolve(path):
    결과 = {"project_root": None, "plan_root": 기본_정본["plan_root"], "plan_root_abs": None,
          "plan_active": False, "plan_root_invalid": False,
          "test_root": 기본_정본["test_root"], "tools_root": 기본_정본["tools_root"], "warnings": []}
    루트 = 프로젝트_루트(path)
    if not 루트:
        return 결과
    결과["project_root"] = 루트
    canon = {}
    설정 = os.path.join(루트, ".claude", "docs_gate.json")
    if os.path.isfile(설정):
        try:
            with open(설정, encoding="utf-8-sig") as f:
                d = json.load(f)
            c = d.get("canon") if isinstance(d, dict) else None
            if isinstance(c, dict):
                canon = c
        except (OSError, ValueError) as e:
            결과["warnings"].append("docs_gate.json 파싱 실패 — 기본값 사용 (%s)" % e)
    for k in ("test_root", "tools_root"):
        if k in canon:
            v = _유효한_상대경로(canon.get(k))
            if v:
                결과[k] = v
            else:
                결과["warnings"].append("canon.%s 거부(절대경로·'..'·빈값) — 기본값 사용" % k)
    if "plan_root" in canon:
        원값 = canon.get("plan_root")
        v = _유효한_상대경로(원값)
        if v is None:
            결과["plan_root_invalid"] = True
            결과["plan_root"] = 원값 if isinstance(원값, str) else 기본_정본["plan_root"]
            결과["warnings"].append("canon.plan_root 거부(절대경로·'..'·빈값): %r" % (원값,))
            return 결과
        결과["plan_root"] = v
    pa = os.path.join(루트, 결과["plan_root"])
    결과["plan_root_abs"] = pa
    결과["plan_active"] = os.path.isdir(pa) and os.path.isfile(os.path.join(pa, "index.json"))
    return 결과


def main(argv):
    경로 = None
    i = 0
    while i < len(argv):
        if argv[i] == "--path" and i + 1 < len(argv):
            경로 = argv[i + 1]
            i += 2
        elif argv[i].startswith("--path="):
            경로 = argv[i].split("=", 1)[1]
            i += 1
        else:
            i += 1
    if not 경로:
        sys.stderr.write("사용법: canon_root.py --path <경로>\n")
        return 2
    print(json.dumps(resolve(경로), ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
