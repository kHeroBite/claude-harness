# 프로젝트 md 문서와 문서지도 등재 상태를 대조하는 감사 스크립트
"""md_audit.py — 프로젝트 루트 md 와 `.claude/rules/docs-map.md` 등재 상태를 대조한다(읽기 전용).

사용법:
    python3 -B md_audit.py --project <프로젝트 루트>
    python3 -B md_audit.py --all            # 공용 링크 범위 18개 고정 목록

판정:
    고아       = 루트 *.md(및 .claude/skills/oinfra_<프로젝트>/ 의 SKILL.md 외 md) 중
                 docs-map 의 "## 현행 문서" / "## 보관 문서" 표에 없는 파일
    깨진 참조  = docs-map 표가 가리키는데 실재하지 않는 경로
    제외       = CLAUDE.md, AGENTS.md, GEMINI.md, CLAUDE.local.md (타 도구 진입점)

종료 코드:
    0 = 고아·깨진 참조 0
    1 = 고아 또는 깨진 참조 있음
    2 = docs-map 부재(또는 대상 디렉터리 부재)
"""
import argparse
import os
import re
import sys

전체_프로젝트 = [
    ((os.environ.get("HARNESS_HOME") or os.path.expanduser("~/.harness")) + "/current"),
    "/mnt/c/DATA/Project/D4",
    "/mnt/c/DATA/Project/Dfast",
    "/mnt/c/DATA/Project/Jarvis",
    "/mnt/c/DATA/Project/Mars",
    "/mnt/c/DATA/Project/Workflow",
    "/mnt/c/DATA/Project/bill",
    "/mnt/c/DATA/Project/card",
    "/mnt/c/DATA/Project/demo",
    "/mnt/c/DATA/Project/ff",
    "/mnt/c/DATA/Project/know",
    "/mnt/c/DATA/Project/mAIx",
    "/mnt/c/DATA/Project/meTube",
    "/mnt/c/DATA/Project/mic",
    "/mnt/c/DATA/Project/present",
    "/mnt/c/DATA/Project/rtx5070",
    "/mnt/c/DATA/Project/tmuxMon",
    "/mnt/c/DATA/Project/uplus",
]

제외_파일 = {"CLAUDE.md", "AGENTS.md", "GEMINI.md", "CLAUDE.local.md"}
문서지도_상대경로 = os.path.join(".claude", "rules", "docs-map.md")
등재_절 = ("## 현행 문서", "## 보관 문서")
백틱_경로 = re.compile(r"^\|\s*`([^`]+)`\s*\|")


def 대상_md_수집(루트):
    """루트 *.md 와 자기 프로젝트 oinfra 부속 md 를 루트 상대경로 집합으로 돌려준다."""
    결과 = set()
    for 이름 in os.listdir(루트):
        경로 = os.path.join(루트, 이름)
        if not 이름.endswith(".md") or 이름 in 제외_파일:
            continue
        if os.path.isfile(경로) or os.path.islink(경로):
            결과.add(이름)
    # 공용 skills 링크라 모든 oinfra_* 가 보이므로 자기 프로젝트 이름의 디렉터리만 본다.
    부속 = os.path.join(루트, ".claude", "skills", "oinfra_" + os.path.basename(루트.rstrip("/")).lower())
    if os.path.isdir(부속):
        for 상위, _, 파일들 in os.walk(부속):
            for 이름 in 파일들:
                if 이름.endswith(".md") and 이름 != "SKILL.md":
                    결과.add(os.path.relpath(os.path.join(상위, 이름), 루트))
    return 결과


def 문서지도_등재_추출(문서지도):
    """docs-map 의 현행/보관 표 첫 칸 백틱 경로를 집합으로 돌려준다."""
    등재 = set()
    현재_절 = None
    with open(문서지도, encoding="utf-8-sig", errors="replace") as f:
        for 줄 in f:
            줄 = 줄.rstrip("\r\n")
            if 줄.startswith("## "):
                현재_절 = 줄.strip() if 줄.strip() in 등재_절 else None
                continue
            if 현재_절 is None:
                continue
            일치 = 백틱_경로.match(줄.strip())
            if 일치:
                등재.add(os.path.normpath(일치.group(1).strip()))
    return 등재


def 프로젝트_감사(루트):
    """한 프로젝트를 감사해 (종료코드, 출력줄 목록)을 돌려준다."""
    루트 = os.path.abspath(루트)
    if not os.path.isdir(루트):
        return 2, [f"[{루트}] 대상 디렉터리 부재"]
    문서지도 = os.path.join(루트, 문서지도_상대경로)
    if not os.path.isfile(문서지도):
        return 2, [f"[{루트}] docs-map 부재: {문서지도}"]
    수집 = 대상_md_수집(루트)
    등재 = 문서지도_등재_추출(문서지도)
    고아 = sorted(수집 - 등재)
    깨짐 = sorted(p for p in 등재 if not os.path.lexists(os.path.join(루트, p)))
    출력 = [f"[{루트}] 수집 {len(수집)} · 등재 {len(등재)} · 고아 {len(고아)} · 깨진 참조 {len(깨짐)}"]
    출력 += [f"  고아: {p}" for p in 고아]
    출력 += [f"  깨진 참조: {p}" for p in 깨짐]
    return (1 if 고아 or 깨짐 else 0), 출력


def main():
    파서 = argparse.ArgumentParser(description="프로젝트 md 문서와 문서지도 등재 상태 대조(읽기 전용)")
    그룹 = 파서.add_mutually_exclusive_group(required=True)
    그룹.add_argument("--project", help="감사할 프로젝트 루트")
    그룹.add_argument("--all", action="store_true", help="공용 링크 범위 18개 고정 목록 전체 감사")
    인자 = 파서.parse_args()

    대상 = 전체_프로젝트 if 인자.all else [인자.project]
    최종 = 0
    for 루트 in 대상:
        코드, 줄들 = 프로젝트_감사(루트)
        print("\n".join(줄들))
        최종 = max(최종, 코드)
    print(f"md_audit rc={최종}")
    return 최종


if __name__ == "__main__":
    sys.exit(main())
