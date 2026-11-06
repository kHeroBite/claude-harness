#!/usr/bin/env python3
# 프로젝트에 plan/ 정본 골격을 프로파일별로 만들고 docs-map 에 색인 행을 넣는 초기화 스크립트
"""plan_init — plan/ 정본 골격 생성기.

사용법:
    python3 -B plan_init.py --project <루트> [--profile product|tool|small] [--test-root <상대>] [--apply]

동작:
    - 기본은 dry-run 이다(파일 변경 0). --apply 일 때만 쓴다.
    - 템플릿은 이 스크립트 실경로 기준 ../skills/ocanon/templates 에서 읽는다(스테이징·live 모두 동작).
    - {{PROJECT}}(루트 폴더 이름)·{{DATE}}(오늘 YYYY-MM-DD) 를 치환한다.
    - 이미 있는 파일은 건너뛴다(덮어쓰기 금지). 같은 명령을 다시 적용해도 트리가 바뀌지 않는다.
    - 프로파일별 생성 파일(plan/ 하위):
        product 7: README·index.json·요구 원문·요구사항정의서·결정대기·결정기록(ADR)·향후과제
        tool    4: README·index.json·요구 원문·결정기록(ADR)
        small   2: README·index.json (ADR 은 첫 결정 때 만든다)
    - <test_root>/ 디렉터리가 이미 있으면 README.md(시험 자산 색인)를, tools_root 가 지정되어 있고
      그 디렉터리가 있으면 README.md(도구 색인)를 없을 때만 만든다. 없는 디렉터리는 만들지 않는다.
    - <루트>/.claude/rules/docs-map.md 가 있으면 `plan/README.md` 행을 정확히 1줄 넣는다.
      <test_root>/README.md 가 실재(또는 이번에 생성)할 때만 그 행도 1줄 넣는다.
    - 경로 우선순위: --test-root > <루트>/.claude/docs_gate.json canon > 기본값(plan, test).
    - --profile 을 생략하면 저장소 모양으로 제안한다(DATABASE.md·화면/서버 흔적 → product,
      .claude/hooks·scripts 위주 → tool, 그 외 small).

종료 코드: 0 = 성공, 2 = 프로젝트 부재, 3 = 템플릿 부재.
"""
import argparse
import datetime
import json
import os
import sys

스크립트_경로 = os.path.realpath(__file__)
템플릿_루트 = os.path.normpath(os.path.join(os.path.dirname(스크립트_경로), "..", "skills", "ocanon", "templates"))

# 프로파일 → (템플릿 상대경로 목록, documents 키 → 경로, active_docs)
요구원문 = "00_요구사항/01_사용자요구사항_원문.md"
요구정의 = "00_요구사항/02_요구사항정의서.md"
결정대기 = "90_결정관리/01_결정대기_질문목록.md"
결정기록 = "90_결정관리/02_결정기록_ADR.md"
향후과제 = "90_결정관리/03_향후과제_TODO.md"
프로파일 = {
    "product": {
        "files": ["README.md", "index.json", 요구원문, 요구정의, 결정대기, 결정기록, 향후과제],
        "documents": {
            "requirements_raw": 요구원문,
            "requirements": 요구정의,
            "decisions": [결정기록],
            "pending": 결정대기,
            "open_questions": 결정대기,
            "todo": 향후과제,
        },
        "active_docs": ["requirements_raw", "requirements", "pending", "decisions", "todo"],
    },
    "tool": {
        "files": ["README.md", "index.json", 요구원문, 결정기록],
        "documents": {"requirements_raw": 요구원문, "decisions": [결정기록]},
        "active_docs": ["requirements_raw", "requirements", "architecture", "decisions",
                        "pending", "todo", "test_plan"],
    },
    "small": {
        "files": ["README.md", "index.json"],
        "documents": {},
        "active_docs": ["decisions"],
    },
}
DOCSMAP_PLAN_행 = "| `{plan}/README.md` | 정본 문서 색인(진입점 `{plan}/index.json`) — 요구·설계·계획·결정 | 계획 수립·작업 착수 전 |"
DOCSMAP_TEST_행 = "| `{test}/README.md` | 시험 자산 색인(재실행 스크립트·판정 규칙·픽스처) | 시험 계획·실행 전 |"


def json_읽기(경로):
    try:
        with open(경로, "r", encoding="utf-8-sig") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def canon_설정(루트):
    값 = json_읽기(os.path.join(루트, ".claude", "docs_gate.json"))
    값 = 값.get("canon") if isinstance(값, dict) else None
    return 값 if isinstance(값, dict) else {}


def 문자열값(사전, 키):
    v = 사전.get(키) if isinstance(사전, dict) else None
    return v.strip().rstrip("/") if isinstance(v, str) and v.strip() else None


def 프로파일_제안(루트):
    if os.path.isfile(os.path.join(루트, "DATABASE.md")):
        return "product", "DATABASE.md 실재"
    for 흔적 in ("src", "server", "web", "app", "frontend", "backend", "package.json"):
        if os.path.exists(os.path.join(루트, 흔적)):
            return "product", f"{흔적} 실재"
    if any(f.endswith((".sln", ".csproj")) for f in os.listdir(루트)):
        return "product", "솔루션·프로젝트 파일 실재"
    for 흔적 in (".claude/hooks", ".claude/scripts", "scripts", "tools"):
        if os.path.isdir(os.path.join(루트, 흔적)):
            return "tool", f"{흔적} 실재"
    return "small", "제품·도구 흔적 없음"


def 템플릿_읽기(상대, 치환):
    with open(os.path.join(템플릿_루트, 상대), "r", encoding="utf-8") as f:
        본문 = f.read()
    for k, v in 치환.items():
        본문 = 본문.replace(k, v)
    return 본문


def index_만들기(치환, 설정, test_root, tools_root):
    """템플릿 index.json 을 읽어 프로파일 값으로 덮어쓴다."""
    색인 = json.loads(템플릿_읽기(os.path.join("plan", "index.json"), 치환))
    색인["profile"] = 설정["이름"]
    색인["active_docs"] = list(설정["active_docs"])
    색인["documents"] = json.loads(json.dumps(설정["documents"]))
    assets = 색인.get("assets") if isinstance(색인.get("assets"), dict) else {}
    assets["test_root"] = test_root
    assets["tools_root"] = tools_root
    색인["assets"] = assets
    return json.dumps(색인, ensure_ascii=False, indent=2) + "\n"


def 쓰기(경로, 본문):
    os.makedirs(os.path.dirname(경로), exist_ok=True)
    with open(경로, "x", encoding="utf-8", newline="\n") as f:  # 'x' = 이미 있으면 실패(덮어쓰기 금지)
        f.write(본문)


def docsmap_계획(docsmap, 행들):
    """docs-map 에 넣을 행(아직 없는 것만)과 새 본문. 현행 문서 표 마지막 행 뒤에 넣는다."""
    with open(docsmap, "r", encoding="utf-8") as f:
        본문 = f.read()
    줄들 = 본문.split("\n")
    추가 = []
    for 표식, 행 in 행들:
        if not any(표식 in 줄 for 줄 in 줄들):
            추가.append(행)
    if not 추가:
        return [], 본문
    # 위치: '현행' 이 들어간 절의 첫 표 마지막 행 뒤. 없으면 첫 표 마지막 행 뒤, 표가 없으면 끝.
    시작 = next((i for i, 줄 in enumerate(줄들) if 줄.startswith("#") and "현행" in 줄), 0)
    마지막 = None
    for i in range(시작, len(줄들)):
        if 줄들[i].lstrip().startswith("|"):
            마지막 = i
        elif 마지막 is not None:
            break
    if 마지막 is None:
        끝 = 본문.rstrip("\n")
        새본문 = 끝 + "\n\n" + "\n".join(추가) + "\n"
    else:
        새본문 = "\n".join(줄들[:마지막 + 1] + 추가 + 줄들[마지막 + 1:])
    return 추가, 새본문


def main(argv=None):
    ap = argparse.ArgumentParser(description="plan/ 정본 골격 생성(기본 dry-run)")
    ap.add_argument("--project", required=True, help="프로젝트 루트")
    ap.add_argument("--profile", choices=sorted(프로파일), help="product|tool|small (생략 시 제안값)")
    ap.add_argument("--test-root", help="시험 자산 루트(프로젝트 기준 상대경로)")
    ap.add_argument("--apply", action="store_true", help="실제로 쓴다(없으면 dry-run)")
    a = ap.parse_args(argv)

    루트 = os.path.abspath(a.project)
    if not os.path.isdir(루트):
        print(f"plan_init: 프로젝트 부재 — {루트}", file=sys.stderr)
        return 2
    if not os.path.isdir(템플릿_루트):
        print(f"plan_init: 템플릿 부재 — {템플릿_루트}", file=sys.stderr)
        return 3

    canon = canon_설정(루트)
    plan_이름 = 문자열값(canon, "plan_root") or "plan"
    test_이름 = (a.test_root.strip().rstrip("/") if a.test_root and a.test_root.strip() else None) \
        or 문자열값(canon, "test_root") or "test"
    tools_이름 = 문자열값(canon, "tools_root")
    if a.profile:
        프로파일명, 근거 = a.profile, "지정"
    else:
        프로파일명, 근거 = 프로파일_제안(루트)
    설정 = dict(프로파일[프로파일명], 이름=프로파일명)
    치환 = {"{{PROJECT}}": os.path.basename(루트.rstrip(os.sep)) or 루트,
            "{{DATE}}": datetime.date.today().isoformat()}

    모드 = "apply" if a.apply else "dry-run"
    print(f"plan_init: 모드={모드} 프로젝트={루트} 프로파일={프로파일명}({근거}) plan_root={plan_이름} test_root={test_이름} tools_root={tools_이름}")

    # 1) 생성 대상 계산
    대상 = []  # (절대경로, 본문 생성 함수)
    plan_root = os.path.join(루트, plan_이름)
    for 상대 in 설정["files"]:
        if not os.path.isfile(os.path.join(템플릿_루트, "plan", 상대)):
            print(f"plan_init: 템플릿 파일 부재 — plan/{상대}", file=sys.stderr)
            return 3
        경로 = os.path.join(plan_root, 상대)
        if 상대 == "index.json":
            대상.append((경로, lambda: index_만들기(치환, 설정, test_이름, tools_이름)))
        else:
            대상.append((경로, lambda 상대=상대: 템플릿_읽기(os.path.join("plan", 상대), 치환)))
    test_dir = os.path.join(루트, test_이름)
    test_readme = os.path.join(test_dir, "README.md")
    if os.path.isdir(test_dir):
        대상.append((test_readme, lambda: 템플릿_읽기(os.path.join("test", "README.md"), 치환)))
    if tools_이름 and os.path.isdir(os.path.join(루트, tools_이름)):
        대상.append((os.path.join(루트, tools_이름, "README.md"),
                   lambda: 템플릿_읽기(os.path.join("tools", "README.md"), 치환)))

    생성 = 건너뜀 = 0
    for 경로, 생성기 in 대상:
        표시 = os.path.relpath(경로, 루트)
        if os.path.exists(경로):
            건너뜀 += 1
            print(f"  건너뜀(존재) {표시}")
            continue
        본문 = 생성기()
        if a.apply:
            쓰기(경로, 본문)
            print(f"  생성 {표시}")
        else:
            print(f"  생성 예정 {표시}")
        생성 += 1

    # 2) docs-map 행
    docsmap = os.path.join(루트, ".claude", "rules", "docs-map.md")
    docsmap_추가 = 0
    if os.path.isfile(docsmap):
        행들 = [(f"`{plan_이름}/README.md`", DOCSMAP_PLAN_행.format(plan=plan_이름))]
        test_readme_있음 = os.path.isfile(test_readme) or (not a.apply and os.path.isdir(test_dir))
        if test_readme_있음:
            행들.append((f"`{test_이름}/README.md`", DOCSMAP_TEST_행.format(test=test_이름)))
        추가, 새본문 = docsmap_계획(docsmap, 행들)
        docsmap_추가 = len(추가)
        for 행 in 추가:
            print(f"  docs-map {'추가' if a.apply else '추가 예정'}: {행}")
        if 추가 and a.apply:
            임시 = docsmap + ".plan_init.tmp"
            with open(임시, "w", encoding="utf-8", newline="\n") as f:
                f.write(새본문)
            os.replace(임시, docsmap)
        if not 추가:
            print("  docs-map 행 이미 있음")
    else:
        print("  docs-map 부재 — 행 추가 생략")

    print(f"plan_init: rc=0 {'생성' if a.apply else '생성 예정'}={생성} 건너뜀={건너뜀} docs-map={docsmap_추가}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
