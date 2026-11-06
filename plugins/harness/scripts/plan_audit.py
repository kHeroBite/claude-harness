#!/usr/bin/env python3
# 프로젝트 plan/ 정본(index.json·문서)과 test/tools README 색인을 읽기 전용으로 감사하는 스크립트
"""plan_audit — plan/ 정본 감사기 (읽기 전용).

사용법:
    python3 -B plan_audit.py --project <루트> [--strict] [--json]

종료 코드:
    0 = 오류 0건 (경고는 있을 수 있음)
    1 = 오류 1건 이상
    2 = 프로젝트 루트·plan root·index.json 부재

경로 우선순위:
    <루트>/.claude/docs_gate.json 의 canon.{plan_root,test_root,tools_root}
    > plan/index.json 의 assets.{test_root,tools_root} > 기본값(plan, test, 없음).
    test_root 의 README.md 가 없으면 시험 색인 감사를 생략한다.
    tools_root 가 지정되지 않으면 <루트>/tools/README.md 가 실재할 때만 감사한다.

검사 항목:
    오류: index.json 파싱 실패·필수 키(project·updated·documents) 누락,
          documents 깨진 참조, plan 하위 자격증명(개인키 헤더·AWS/GitHub 토큰·password=값)
    경고: plan md 미등재 고아(--strict 면 오류), 300줄 초과 md, IPv4 주소,
          판 사본 이름(DUPNAME: _vN·_rN·_old·_bak·_copy·복사본),
          생성물(GENERATED: __pycache__·*.pyc·bin·obj·node_modules·빌드 산출물),
          1MB 초과(LARGE), active_docs 선언 문서 미등재(ACTIVE_MISSING),
          test/tools README 색인 고아(ASSET_ORPHAN)·재사용 이유 칸 공백(REASON_BLANK)·
          "대체됨" 미정리(REPLACED)·색인 경로 부재(ASSET_BROKEN)·자격증명 의심(SECRET_ASSET),
          감사 상한 도달(LIMIT)
    documents.open_questions 와 pending 이 같은 파일을 가리켜도 오류가 아니다.

한계: 기계는 구조적 신호만 잡는다. "다음에 쓸모가 있는가"라는 가치 판단과
      이유 칸 내용의 타당성은 판정하지 못한다.
"""
import argparse
import json
import os
import re
import sys
import time

최대_파일수 = 2000
최대_초 = 10.0
최대_줄수 = 300
최대_바이트 = 1024 * 1024
필수_키 = ("project", "updated", "documents")
텍스트_확장자 = {
    ".md", ".json", ".csv", ".txt", ".py", ".sh", ".yaml", ".yml", ".html",
    ".mmd", ".svg", ".ps1", ".js", ".ts", ".toml", ".ini", ".xml", ".cfg",
}
자산_확장자 = {".py", ".sh", ".ps1", ".js", ".ts", ".md", ".json", ".csv", ".yaml", ".yml", ".txt"}
# 조용히 건너뛰는 디렉터리(관리 영역) / 경고 후 건너뛰는 생성물 디렉터리
무시_디렉터리 = {".git", ".venv", "venv", ".mypy_cache", ".pytest_cache"}
생성물_디렉터리 = {"__pycache__", "bin", "obj", "node_modules", "dist", "build"}
생성물_확장자 = {".pyc", ".pyo", ".class", ".o", ".obj", ".dll", ".exe", ".pdb"}
판사본_패턴 = re.compile(
    r"(?i)(?:[_\-. ](?:v\d+|r\d+|old|bak|backup|copy)|복사본|\s*-\s*복사본|\s\(\d+\))$")
경로_패턴 = re.compile(r"^[^\s:*?\"<>|]+\.[A-Za-z0-9]{1,6}$|^[^\s:*?\"<>|]+/$")
코드_조각 = re.compile(r"`([^`]+)`")

자격증명_패턴 = [
    ("PRIVATE_KEY", re.compile(r"-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED |PGP )?PRIVATE KEY(?: BLOCK)?-----")),
    ("AWS_KEY", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b")),
    ("GITHUB_TOKEN", re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,})\b")),
]
비밀번호_패턴 = re.compile(r"(?i)\b(?:password|passwd|pwd)\s*[=:]\s*[\"']?([^\s\"'`,;|]+)")
자리표시_값 = re.compile(r"^(?:\*+|x+|<.*|\{.*|\$.*|%.*|\.\.\.|none|null|changeme|example|placeholder|값|비밀번호)$", re.I)
IPV4_패턴 = re.compile(r"(?<![\d.])(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?![\d.])")
IP_제외 = {"127.0.0.1", "0.0.0.0"}


class 감사결과:
    def __init__(self):
        self.오류 = []
        self.경고 = []
        self.정보 = {}

    def 오류추가(self, 코드, 경로, 내용):
        self.오류.append({"code": 코드, "path": 경로, "msg": 내용})

    def 경고추가(self, 코드, 경로, 내용):
        self.경고.append({"code": 코드, "path": 경로, "msg": 내용})


def json_읽기(경로):
    with open(경로, "r", encoding="utf-8-sig") as f:
        return json.load(f)


def 텍스트_읽기(경로):
    with open(경로, "r", encoding="utf-8-sig", errors="replace") as f:
        return f.read()


def canon_설정(루트):
    """<루트>/.claude/docs_gate.json 의 canon 블록(없으면 빈 dict)."""
    경로 = os.path.join(루트, ".claude", "docs_gate.json")
    try:
        값 = json_읽기(경로).get("canon", {})
        return 값 if isinstance(값, dict) else {}
    except (OSError, ValueError, AttributeError):
        return {}


def 경로_결정(canon, assets, 키, 기본):
    """canon > index.json assets > 기본값. 빈 문자열·null 은 미지정으로 본다."""
    for 출처 in (canon, assets):
        if isinstance(출처, dict):
            v = 출처.get(키)
            if isinstance(v, str) and v.strip():
                return v.strip().rstrip("/")
    return 기본


def 문자열_수집(값):
    """문자열·배열·중첩 객체에서 모든 문자열 값을 모은다."""
    if isinstance(값, str):
        yield 값
    elif isinstance(값, list):
        for v in 값:
            yield from 문자열_수집(v)
    elif isinstance(값, dict):
        for v in 값.values():
            yield from 문자열_수집(v)


def 경로_후보(문자열):
    s = 문자열.strip().split("#", 1)[0]
    if not s or "://" in s:
        return None
    return s if 경로_패턴.match(s) else None


class 상한감시:
    def __init__(self, 결과):
        self.시작 = time.monotonic()
        self.개수 = 0
        self.도달 = False
        self.결과 = 결과

    def 허용(self):
        if self.도달:
            return False
        self.개수 += 1
        if self.개수 > 최대_파일수 or time.monotonic() - self.시작 > 최대_초:
            self.도달 = True
            self.결과.경고추가("LIMIT", "", f"감사 상한 도달(파일 {최대_파일수}개 또는 {최대_초:.0f}초) — 이후 파일은 생략")
            return False
        return True


def 상대(경로, 기준):
    return os.path.relpath(경로, 기준).replace(os.sep, "/")


def 파일_순회(기준, 루트, 감시, 결과):
    """기준 이하 파일을 돈다. 생성물 디렉터리는 경고 후 건너뛴다."""
    for 상위, 디렉터리들, 파일들 in os.walk(기준):
        남길 = []
        for d in sorted(디렉터리들):
            if d in 무시_디렉터리:
                continue
            if d in 생성물_디렉터리:
                결과.경고추가("GENERATED", 상대(os.path.join(상위, d), 루트),
                          "생성물 디렉터리 — 커밋 대상 영역에 두지 않는다(재생성 가능)")
                continue
            남길.append(d)
        디렉터리들[:] = 남길
        for 이름 in sorted(파일들):
            if not 감시.허용():
                return
            yield os.path.join(상위, 이름)


def 이름_검사(경로, 표시, 결과):
    """판 사본 이름·생성물 확장자·1MB 초과. 1MB 초과면 False(본문 스캔 생략)."""
    줄기, 확장자 = os.path.splitext(os.path.basename(경로))
    if 판사본_패턴.search(줄기):
        결과.경고추가("DUPNAME", 표시, "판 사본 이름(_vN·_rN·_old·_bak·_copy·복사본) — 기존 파일을 고치고 최종판 1개만 둔다")
    if 확장자.lower() in 생성물_확장자:
        결과.경고추가("GENERATED", 표시, "생성물 파일 — 커밋 대상 영역에 두지 않는다")
    try:
        크기 = os.path.getsize(경로)
    except OSError:
        return False
    if 크기 > 최대_바이트:
        결과.경고추가("LARGE", 표시, f"1MB 초과({크기} bytes) — 원본 텍스트에서 재생성하거나 archive 로 보낸다")
        return False
    return True


def 자격증명_검사(경로, 표시, 결과, 엄격=True):
    """엄격=True(plan): 자격증명 오류 + IP 경고 / False(test·tools): 자격증명 경고만."""
    if os.path.splitext(경로)[1].lower() not in 텍스트_확장자:
        return
    try:
        본문 = 텍스트_읽기(경로)
    except OSError:
        return
    for 줄번호, 줄 in enumerate(본문.splitlines(), 1):
        위치 = f"{표시}:{줄번호}"
        발견 = [코드 for 코드, 패턴 in 자격증명_패턴 if 패턴.search(줄)]
        m = 비밀번호_패턴.search(줄)
        if m and len(m.group(1)) >= 4 and not 자리표시_값.match(m.group(1)):
            발견.append("PASSWORD")
        for 코드 in 발견:
            if 엄격:
                결과.오류추가("SECRET", 위치, f"자격증명 의심({코드})")
            else:
                결과.경고추가("SECRET_ASSET", 위치, f"자격증명 의심({코드}) — 환경변수·INFRA 참조로 바꾼다")
        if not 엄격:
            continue
        for ip in IPV4_패턴.finditer(줄):
            주소 = ip.group(0)
            if 주소 in IP_제외 or any(int(o) > 255 for o in ip.groups()):
                continue
            결과.경고추가("IPV4", 위치, f"IP 주소 {주소} — 서버값은 INFRA.md 참조로만 적는다")


def 색인표_행(본문):
    """README 의 마크다운 표 중 '경로' 열이 있는 표의 데이터 행을 (머리 목록, 칸 목록) 으로 낸다."""
    머리 = None
    for 줄 in 본문.splitlines():
        s = 줄.strip()
        if not s.startswith("|"):
            머리 = None
            continue
        칸 = [c.strip() for c in s.strip("|").split("|")]
        if 머리 is None:
            머리 = 칸 if any(c.startswith("경로") for c in 칸) else []
            continue
        if not 머리 or all(re.fullmatch(r":?-{2,}:?", c or "--") for c in 칸):
            continue
        yield 머리, 칸


def 자산_감사(루트, 영역, 이름, 감시, 결과):
    """test/tools 영역: README 색인 대조·이유 칸·대체됨·판 사본·생성물·크기·자격증명(경고)."""
    영역_루트 = os.path.normpath(os.path.join(루트, 이름))
    readme = os.path.join(영역_루트, "README.md")
    readme_표시 = 상대(readme, 루트)
    if not os.path.isfile(readme):
        결과.정보[f"{영역}_audit"] = "생략(README 부재)"
        return
    결과.정보[f"{영역}_audit"] = readme_표시
    try:
        색인문 = 텍스트_읽기(readme)
    except OSError:
        색인문 = ""
    for 머리, 칸 in 색인표_행(색인문):
        행 = dict(zip(머리, 칸 + [""] * (len(머리) - len(칸))))
        경로칸 = next((v for k, v in 행.items() if k.startswith("경로")), "")
        if "(예시)" in 경로칸:
            continue
        이유_키 = next((k for k in 머리 if "재사용 이유" in k or k.startswith("이유")), None)
        if 이유_키 is None:  # 계층 설명표 등 색인표가 아닌 표는 건너뛴다
            continue
        if not 행.get(이유_키, "").strip():
            결과.경고추가("REASON_BLANK", readme_표시, f"색인 행 {경로칸 or '(경로 없음)'} 의 재사용 이유 칸이 비었다(K 번호와 한 줄 이유)")
        상태 = next((v for k, v in 행.items() if k.startswith("상태")), "")
        if "대체됨" in 상태:
            결과.경고추가("REPLACED", readme_표시, f"색인 행 {경로칸} 상태 '대체됨' — 다음 정리 때 archive/ 로 옮긴다")
        for 조각 in 코드_조각.findall(경로칸):
            후보 = 조각.strip()
            if not 경로_후보(후보) or 후보.startswith("archive/"):
                continue
            if not (os.path.exists(os.path.join(영역_루트, 후보)) or os.path.exists(os.path.join(루트, 후보))):
                결과.경고추가("ASSET_BROKEN", readme_표시, f"색인 경로 부재: {후보}")
    for 경로 in 파일_순회(영역_루트, 루트, 감시, 결과):
        if os.path.normpath(경로) == os.path.normpath(readme):
            continue
        표시 = 상대(경로, 루트)
        if 이름_검사(경로, 표시, 결과):
            자격증명_검사(경로, 표시, 결과, 엄격=False)
        if os.path.splitext(경로)[1].lower() not in 자산_확장자:
            continue
        rel = 상대(경로, 영역_루트)
        if rel.startswith("archive/"):
            continue
        if rel not in 색인문 and 표시 not in 색인문 and os.path.basename(경로) not in 색인문:
            결과.경고추가("ASSET_ORPHAN", 표시, f"{영역} 영역 README 색인 미등재")


def 감사(루트, strict=False):
    결과 = 감사결과()
    루트 = os.path.abspath(루트)
    if not os.path.isdir(루트):
        결과.오류추가("NO_PROJECT", 루트, "프로젝트 루트 부재")
        return 결과, 2
    canon = canon_설정(루트)
    plan_이름 = 경로_결정(canon, None, "plan_root", "plan")
    plan_root = os.path.normpath(os.path.join(루트, plan_이름))
    index_경로 = os.path.join(plan_root, "index.json")
    index_표시 = f"{plan_이름}/index.json"
    결과.정보.update({"project": 루트, "plan_root": plan_이름})
    if not os.path.isdir(plan_root):
        결과.오류추가("NO_PLAN_ROOT", plan_이름, "plan root 부재")
        return 결과, 2
    if not os.path.isfile(index_경로):
        결과.오류추가("NO_INDEX", index_표시, "index.json 부재")
        return 결과, 2

    # 1) index.json 스키마
    색인 = None
    try:
        색인 = json_읽기(index_경로)
    except (OSError, ValueError) as e:
        결과.오류추가("INDEX_PARSE", index_표시, f"파싱 실패: {e}")
    if 색인 is not None and not isinstance(색인, dict):
        결과.오류추가("INDEX_SCHEMA", index_표시, "최상위가 객체가 아님")
        색인 = None
    참조_집합 = set()
    if isinstance(색인, dict):
        for 키 in 필수_키:
            if 키 not in 색인:
                결과.오류추가("INDEX_KEY", index_표시, f"필수 키 누락: {키}")
        # 2) documents 깨진 참조 (archived 는 등재로만 인정). 같은 파일을 여러 키가 가리켜도 된다.
        for 출처 in ("documents", "archived"):
            for s in 문자열_수집(색인.get(출처, {})):
                p = 경로_후보(s)
                if not p:
                    continue
                절대 = os.path.normpath(p if os.path.isabs(p) else os.path.join(plan_root, p))
                if os.path.exists(절대):
                    참조_집합.add(절대)
                elif 출처 == "documents":
                    결과.오류추가("BROKEN_REF", index_표시, f"documents 깨진 참조: {p}")
        # 3) active_docs 선언 대비 documents 부재
        문서 = 색인.get("documents", {})
        active = 색인.get("active_docs", [])
        if isinstance(active, list) and isinstance(문서, dict):
            for 키 in active:
                if isinstance(키, str) and not 문서.get(키):
                    결과.경고추가("ACTIVE_MISSING", index_표시, f"active_docs 선언 문서 미등재: {키} (필요해지면 생성·등재)")

    # 4) plan 하위 파일: 이름·생성물·크기·자격증명·고아·300줄
    감시 = 상한감시(결과)
    md_수 = 0
    for 경로 in 파일_순회(plan_root, 루트, 감시, 결과):
        표시 = 상대(경로, 루트)
        if 이름_검사(경로, 표시, 결과):
            자격증명_검사(경로, 표시, 결과, 엄격=True)
        if not 경로.lower().endswith(".md"):
            continue
        md_수 += 1
        if os.path.basename(경로).lower() != "readme.md":
            정규 = os.path.normpath(경로)
            등재 = 정규 in 참조_집합 or any(
                os.path.isdir(r) and 정규.startswith(r + os.sep) for r in 참조_집합)
            if not 등재:
                if strict:
                    결과.오류추가("ORPHAN", 표시, "index.json documents 미등재 (--strict)")
                else:
                    결과.경고추가("ORPHAN", 표시, "index.json documents 미등재")
        try:
            줄수 = len(텍스트_읽기(경로).splitlines())
        except OSError:
            continue
        if 줄수 > 최대_줄수:
            결과.경고추가("LONG", 표시, f"{줄수}줄 — {최대_줄수}줄 초과(부록 분리 권장)")

    # 5) test/tools 색인 감사
    assets = 색인.get("assets", {}) if isinstance(색인, dict) else {}
    test_이름 = 경로_결정(canon, assets, "test_root", "test")
    tools_이름 = 경로_결정(canon, assets, "tools_root", None)
    if tools_이름 is None and os.path.isfile(os.path.join(루트, "tools", "README.md")):
        tools_이름 = "tools"
    결과.정보.update({"test_root": test_이름, "tools_root": tools_이름, "md_files": md_수})
    자산_감사(루트, "test", test_이름, 감시, 결과)
    if tools_이름 is None:
        결과.정보["tools_audit"] = "생략(tools_root 미지정·tools/README.md 부재)"
    elif os.path.normpath(os.path.join(루트, tools_이름)) != os.path.normpath(os.path.join(루트, test_이름)):
        자산_감사(루트, "tools", tools_이름, 감시, 결과)
    return 결과, (1 if 결과.오류 else 0)


def main(argv=None):
    ap = argparse.ArgumentParser(description="plan/ 정본 감사(읽기 전용)")
    ap.add_argument("--project", required=True, help="프로젝트 루트")
    ap.add_argument("--strict", action="store_true", help="고아 문서를 오류로 판정")
    ap.add_argument("--json", action="store_true", help="JSON 으로 출력")
    a = ap.parse_args(argv)
    결과, rc = 감사(a.project, a.strict)
    if a.json:
        print(json.dumps({"rc": rc, "errors": 결과.오류, "warnings": 결과.경고, "info": 결과.정보},
                         ensure_ascii=False, indent=1))
    else:
        for 항목 in 결과.오류:
            print(f"ERROR {항목['code']} {항목['path']}: {항목['msg']}")
        for 항목 in 결과.경고:
            print(f"WARN  {항목['code']} {항목['path']}: {항목['msg']}")
        print(f"plan_audit: rc={rc} errors={len(결과.오류)} warnings={len(결과.경고)}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
