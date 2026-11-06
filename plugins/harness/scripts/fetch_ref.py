#!/usr/bin/env python3
# 외부 레퍼런스 원본을 에이전트 지시 파일 제외·무실행으로 수집하고 2층 색인을 관리·점검하는 공용 도구
"""fetch_ref.py — 색인 층(<프로젝트>/<ref_root>/)과 원본 층(${REF_STORE:-~/ref-store}/<프로젝트>/<id>@<커밋 12자>/)을 관리한다.

받은 코드는 실행·설치·빌드하지 않는다. 이 도구는 git 으로 받아 파일을 펼치기만 한다.
표준 라이브러리만 쓰므로 `python3 -I` 로 실행할 수 있다.
"""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

RC_정상 = 0
RC_점검_위반 = 1   # --verify 가 문제를 찾음
RC_인자 = 2
RC_수집_실패 = 3   # git 실패·시간 초과
RC_용량 = 4        # 여유·상한 초과 또는 판정 불가
RC_금지파일 = 5    # 사후 검사에서 금지 파일 발견 — 항목은 불완전으로 표시된다

# 필수 제외 9종의 단일 출처. LICENSE·NOTICE·COPYING 은 넣지 않는다(라이선스 판단 근거다).
제외_목록 = [
    "CLAUDE.md", "AGENTS.md", "GEMINI.md",
    ".claude/", ".agents/", ".cursor/",
    ".cursorrules", ".mcp.json",
    ".github/copilot-instructions.md",
]
금지_이름 = {항목.rstrip("/").lower() for 항목 in 제외_목록 if "/" not in 항목.rstrip("/")}
금지_꼬리 = [항목.lower().split("/") for 항목 in 제외_목록 if "/" in 항목.rstrip("/")]

기본_상한 = {"limit_gb": 8.0, "warn_gb": 6.0, "item_gb": 1.5, "index_mb": 5.0, "min_free_gb": 20.0}
가상디스크_파일시스템 = {"ext4", "xfs", "btrfs"}
잠금_파일 = ".fetch.lock"
임시_접두 = ".tmp-"
GB = 1024 ** 3
MB = 1024 ** 2

도움말_꼬리 = """\
구조:
  색인 층(git 추적)  <프로젝트>/<ref_root>/{README.md, manifest.json, analysis/<id>.md}
  원본 층(저장소 밖)  ${REF_STORE:-~/ref-store}/<프로젝트>/<id>@<커밋 12자>/
  편의 링크          <ref_root>/src (--link, 추적 안 함)

ref_root 우선순위: --ref-root → .claude/docs_gate.json canon.ref_root → plan/index.json assets.ref_root → ref

용량 기본값(옵션 → .claude/docs_gate.json canon.ref_limits → 아래 값 순으로 적용):
  --limit-gb      프로젝트당 상한 8GB      (ref_limits.limit_gb)
  --warn-gb       프로젝트당 경고 6GB      (ref_limits.warn_gb)
  --item-limit-gb 항목당 상한 1.5GB        (ref_limits.item_gb)
  --index-limit-mb 색인 층 상한 5MB        (ref_limits.index_mb)
  --min-free-gb   여유 20GB 미만이면 중단  (ref_limits.min_free_gb)

여유 판정:
  --free-path 를 주면 그 경로의 디스크를 본다.
  없으면 원본 층이 실제로 놓인 디스크를 본다(심볼릭 링크를 따라간 뒤 가장 가까운 존재 경로).
  WSL 에서 원본 층이 가상 디스크(ext4 등) 위면 그 디스크가 보여 주는 여유는 호스트 드라이브의
  실제 여유가 아니다. 그래서 /mnt/c 여유도 함께 보고 더 작은 값으로 판정한다. 가상 디스크
  파일이 다른 드라이브에 있으면 --free-path 로 그 드라이브를 지정한다.

WSL 가상 디스크 주의:
  가상 디스크 파일은 안에서 파일을 지워도 호스트에서 자동으로 줄어들지 않는다. 원본을 지워도
  호스트 드라이브 여유는 그대로일 수 있다. 회수는 별도 압축 절차가 필요하며 이 도구는 하지 않는다.
  이 도구는 wsl --shutdown 을 자동 실행하지 않는다.

종료 코드: 0 정상 · 1 --verify 위반 · 2 인자 오류 · 3 git 실패·파일 등록 실패 · 4 용량 · 5 금지 파일 발견(항목 불완전)

로컬 파일 등록(--file, git 이 아닌 배포물):
  파일을 읽어 sha256 을 계산하고 커밋 자리에 기록한다. 실행·압축 해제·설치는 하지 않는다.
  원본 층의 <id>@<sha256 12자>/ 아래에 그대로 복사한다. --url 은 출처 기록용이며 접속하지 않는다.
  --ref 는 버전 표기로 쓴다. --verify 는 sha256 을 다시 계산해 대조하고 다르면 HASH_MISMATCH 로 실패한다.
  압축 파일의 내부는 풀지 않으므로 제외·사후 검사가 내부 파일에는 적용되지 않는다.

문서만 수집(--docs-only, kind=docs_only):
  받지 않고 URL·라이선스·취득 근거만 색인한다. 원본 층 폴더를 만들지 않는다. --id --url(http/https) --license --basis 가
  모두 필요하며 미확인·미기재는 거부한다. manifest 의 commit 은 빈 값이고 acquired_at 이 기록된다. README 이름 칸은
  `<id>@docs` 로 적는다(커밋 12자 자리에 docs). --verify 는 url·acquired_at·license·basis 가 실제 값인지 보고, 빈 commit 이어도
  kind 가 docs_only 가 아니면 MANIFEST_INVALID 다. 원본 대조 대상이 아니므로 "원본 대조 미실행" 에 세지 않는다.

프로젝트 폴더 이름(--project-name):
  원본 층 폴더는 원본 저장소 이름이다. 그 이름의 폴더가 없고 대소문자만 다른 폴더가 정확히 1개면 그 폴더를 쓰고 경고를 낸다.
  여러 개면 STORE_NAME_AMBIGUOUS(--verify rc=1, 수집 rc=2)다. --project-name 을 주면 그 이름만 쓴다.

--verify 의 원본 대조 미실행:
  원본 층에 항목 폴더가 없으면 SOURCE_MISSING 참고로 남기고 rc 는 바꾸지 않는다(다른 환경에서는 정상일 수 있다).
  대신 마지막 줄에 "원본 대조 미실행 N건" 을 내고 문제가 없어도 VERIFY OK 가 아니라 VERIFY PARTIAL 로 표기한다.

제외 대상(9종): CLAUDE.md AGENTS.md GEMINI.md .claude/ .agents/ .cursor/ .cursorrules .mcp.json
  .github/copilot-instructions.md — sparse-checkout 음수 패턴으로 빼고, 수집 직후 상대경로를
  소문자로 비교해 다시 검사한다. 대소문자가 다른 변형은 패턴을 지나칠 수 있으므로 사후 검사가
  잡아 rc=5 로 보고한다. LICENSE·NOTICE·COPYING 은 제외하지 않는다.

예:
  fetch_ref.py --id sample --url https://example.org/sample.git --license MIT --basis "공개 저장소"
  fetch_ref.py --id sample --url https://example.org/sample.git --commit <40자 커밋>
  fetch_ref.py --id app --file ./app-1.2.bin --ref 1.2 --url https://example.org/app --license EULA --basis "약관 3조 허용"
  fetch_ref.py --docs-only --id pgdocs --url https://www.postgresql.org/docs/ --license PostgreSQL --basis "공개 문서 열람"
  fetch_ref.py --verify
"""


class 중단(Exception):
    def __init__(self, 코드, 내용):
        super().__init__(내용)
        self.코드 = 코드


def 깃_환경():
    환경 = dict(os.environ)
    for 키 in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_COMMON_DIR", "GIT_PREFIX"):
        환경.pop(키, None)
    환경["GIT_TERMINAL_PROMPT"] = "0"
    환경["GIT_LFS_SKIP_SMUDGE"] = "1"
    환경["GIT_ALLOW_PROTOCOL"] = "file:git:http:https:ssh"
    return 환경


안전_옵션 = [
    "core.hooksPath=/dev/null",
    "core.symlinks=false",
    "submodule.recurse=false",
    "fetch.recurseSubmodules=false",
    "protocol.ext.allow=never",
    "advice.detachedHead=false",
]


def 깃(인자, 위치=None, 제한초=120, 입력=None):
    명령 = ["git"]
    for 옵션 in 안전_옵션:
        명령 += ["-c", 옵션]
    try:
        결과 = subprocess.run(명령 + 인자, cwd=위치, env=깃_환경(), input=입력, timeout=제한초,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
    except subprocess.TimeoutExpired:
        raise 중단(RC_수집_실패, "git 시간 초과(%s초): git %s" % (제한초, 인자[0]))
    except OSError as 오류:
        raise 중단(RC_수집_실패, "git 실행 불가: %s" % 오류)
    if 결과.returncode != 0:
        raise 중단(RC_수집_실패, "git %s 실패 rc=%s: %s" % (인자[0], 결과.returncode, 결과.stderr.strip()[-500:]))
    return 결과.stdout.strip()


def 조회(인자, 위치):
    # 프로젝트 판별용 — 실패해도 예외를 내지 않는다
    try:
        return 깃(인자, 위치, 30)
    except 중단:
        return ""


def json_읽기(경로):
    try:
        with open(경로, encoding="utf-8") as 파일:
            값 = json.load(파일)
        return 값 if isinstance(값, dict) else {}
    except (OSError, ValueError):
        return {}


def 원자적_쓰기(경로, 내용):
    os.makedirs(os.path.dirname(경로), exist_ok=True)
    핸들, 임시 = tempfile.mkstemp(dir=os.path.dirname(경로), prefix=".tmp-write-")
    try:
        with os.fdopen(핸들, "w", encoding="utf-8", newline="\n") as 파일:
            파일.write(내용)
        os.chmod(임시, 0o644)
        os.replace(임시, 경로)
    except BaseException:
        if os.path.exists(임시):
            os.unlink(임시)
        raise


def 프로젝트_루트(지정):
    if 지정:
        경로 = os.path.realpath(지정)
        if not os.path.isdir(경로):
            raise 중단(RC_인자, "프로젝트 경로가 없음: %s" % 지정)
        return 경로
    최상위 = 조회(["rev-parse", "--show-toplevel"], os.getcwd())
    if not 최상위:
        raise 중단(RC_인자, "git 저장소 안에서 실행하거나 --project 를 지정한다")
    return os.path.realpath(최상위)


def 공통_저장소(루트):
    # worktree 면 원본 checkout 을 가리킨다. git 이 아니면 빈 문자열
    공통 = 조회(["rev-parse", "--path-format=absolute", "--git-common-dir"], 루트)
    return os.path.realpath(공통) if 공통 else ""


def 프로젝트_이름(루트):
    # worktree 폴더 이름이 아니라 원본 저장소 이름으로 원본 층을 공유한다
    공통 = 공통_저장소(루트)
    if 공통:
        if os.path.basename(공통) == ".git":
            return os.path.basename(os.path.dirname(공통))
        return re.sub(r"\.git$", "", os.path.basename(공통))
    return os.path.basename(루트)


def 설정_읽기(루트):
    게이트 = json_읽기(os.path.join(루트, ".claude", "docs_gate.json"))
    정본 = 게이트.get("canon")
    return 정본 if isinstance(정본, dict) else {}


def 색인_위치(루트, 지정):
    정본 = 설정_읽기(루트)
    값 = 지정 or 정본.get("ref_root")
    if not 값:
        계획 = 정본.get("plan_root") or "plan"
        자산 = json_읽기(os.path.join(루트, str(계획), "index.json")).get("assets")
        값 = 자산.get("ref_root") if isinstance(자산, dict) else None
    값 = 값 or "ref"
    if not isinstance(값, str) or os.path.isabs(값) or ".." in 값.split("/"):
        raise 중단(RC_인자, "ref_root 는 프로젝트 안 상대경로여야 함: %s" % 값)
    return os.path.join(루트, 값)


def 상한_결정(루트, 인자):
    설정 = 설정_읽기(루트).get("ref_limits")
    설정 = 설정 if isinstance(설정, dict) else {}
    결과 = {}
    for 키, 지정 in (("limit_gb", 인자.limit_gb), ("warn_gb", 인자.warn_gb), ("item_gb", 인자.item_limit_gb),
                   ("index_mb", 인자.index_limit_mb), ("min_free_gb", 인자.min_free_gb)):
        값 = 지정 if 지정 is not None else 설정.get(키, 기본_상한[키])
        if isinstance(값, bool) or not isinstance(값, (int, float)) or 값 < 0:
            raise 중단(RC_인자, "%s 값이 올바르지 않음: %s" % (키, 값))
        결과[키] = float(값)
    return 결과


def 원본_루트():
    return os.path.abspath(os.path.expanduser(os.environ.get("REF_STORE") or "~/ref-store"))


def 원본_폴더_결정(원본, 이름, 명시):
    # 돌려주는 값: (프로젝트 원본 폴더, 경고 목록, 모호함 메시지 또는 None)
    # 폴더 이름은 대소문자를 구분하므로 worktree 의 저장소 이름과 원본 층 폴더가 대소문자만 달라도 어긋난다
    정확 = os.path.join(원본, 이름)
    if 명시 or os.path.isdir(정확) or not os.path.isdir(원본):
        return 정확, [], None
    후보 = sorted(n for n in os.listdir(원본) if n != 이름 and n.lower() == 이름.lower() and os.path.isdir(os.path.join(원본, n)))
    if len(후보) == 1:
        return os.path.join(원본, 후보[0]), ["경고: 원본 층 폴더 %s 를 프로젝트 %s 의 원본으로 쓴다(대소문자만 다름). 이름을 고정하려면 --project-name 을 준다" % (후보[0], 이름)], None
    if len(후보) > 1:
        return 정확, [], "STORE_NAME_AMBIGUOUS 프로젝트 %s 와 대소문자만 다른 원본 폴더가 %d개: %s (--project-name 으로 지정한다)" % (이름, len(후보), ", ".join(후보))
    return 정확, [], None


def 프로젝트_이름_결정(루트, 인자):
    명시 = getattr(인자, "project_name", None)
    if 명시 is not None and not 항목_id_유효(명시):
        raise 중단(RC_인자, "--project-name 은 영문·숫자·. _ - 만 쓴다: %s" % 명시)
    return 명시 or 프로젝트_이름(루트), bool(명시)


def 포함되는가(바깥, 안):
    바깥 = os.path.realpath(바깥)
    안 = os.path.realpath(안)
    return 안 == 바깥 or 안.startswith(바깥 + os.sep)


def 저장소_밖_확인(원본, 루트):
    후보 = [루트]
    공통 = 공통_저장소(루트)
    if 공통 and os.path.basename(공통) == ".git":
        후보.append(os.path.dirname(공통))
    for 대상 in 후보:
        if 포함되는가(대상, 원본):
            raise 중단(RC_인자, "원본 층은 저장소 밖이어야 함: REF_STORE=%s" % 원본)


def 존재하는_조상(경로):
    현재 = os.path.realpath(경로)
    while not os.path.exists(현재):
        부모 = os.path.dirname(현재)
        if 부모 == 현재:
            break
        현재 = 부모
    return 현재


def 마운트_종류(경로):
    찾은_길이 = -1
    종류 = ""
    try:
        with open("/proc/self/mountinfo", encoding="utf-8", errors="replace") as 파일:
            for 줄 in 파일:
                왼쪽, _, 오른쪽 = 줄.partition(" - ")
                왼쪽칸 = 왼쪽.split()
                오른쪽칸 = 오른쪽.split()
                if len(왼쪽칸) < 5 or not 오른쪽칸:
                    continue
                지점 = re.sub(r"\\([0-7]{3})", lambda 일치: chr(int(일치.group(1), 8)), 왼쪽칸[4])
                if (경로 == 지점 or 경로.startswith(지점.rstrip("/") + "/")) and len(지점) > 찾은_길이:
                    찾은_길이, 종류 = len(지점), 오른쪽칸[0]
    except OSError:
        return ""
    return 종류


def WSL인가():
    if os.environ.get("WSL_DISTRO_NAME"):
        return True
    try:
        with open("/proc/sys/kernel/osrelease", encoding="utf-8") as 파일:
            return "microsoft" in 파일.read().lower()
    except OSError:
        return False


def 여유_판정_대상(원본, 지정):
    if 지정:
        return [(지정, "--free-path")]
    기준 = 존재하는_조상(원본)
    대상 = [(기준, "원본 층 디스크")]
    if WSL인가() and 마운트_종류(기준) in 가상디스크_파일시스템 and os.path.ismount("/mnt/c"):
        대상.append(("/mnt/c", "WSL 가상 디스크의 호스트 드라이브로 추정(다르면 --free-path)"))
    return 대상


def 여유_확인(원본, 지정, 최소_GB):
    for 경로, 설명 in 여유_판정_대상(원본, 지정):
        try:
            여유 = shutil.disk_usage(경로).free
        except OSError as 오류:
            raise 중단(RC_용량, "여유 판정 불가 %s: %s — --free-path 로 경로를 지정한다" % (경로, 오류))
        print("여유 판정: %s 여유 %.1fGB (%s)" % (경로, 여유 / GB, 설명))
        if 여유 < 최소_GB * GB:
            raise 중단(RC_용량, "여유 부족으로 수집 중단: %s 여유 %.1fGB < 기준 %.1fGB" % (경로, 여유 / GB, 최소_GB))


def 디렉터리_크기(경로, 제외=()):
    합계 = 0
    for 현재, 폴더들, 파일들 in os.walk(경로):
        if 현재 == 경로:
            폴더들[:] = [이름 for 이름 in 폴더들 if 이름 not in 제외]
            파일들 = [이름 for 이름 in 파일들 if 이름 not in 제외]
        for 이름 in 파일들:
            try:
                합계 += os.lstat(os.path.join(현재, 이름)).st_size
            except OSError:
                pass
    return 합계


def 금지_경로인가(상대경로):
    # 대소문자 무시 비교 — sparse 음수 패턴이 놓친 변형(예: Claude.md)을 여기서 잡는다
    조각 = 상대경로.replace(os.sep, "/").lower().split("/")
    if any(이름 in 금지_이름 for 이름 in 조각):
        return True
    return any(조각[-len(꼬리):] == 꼬리 for 꼬리 in 금지_꼬리)


def 금지_파일_검사(뿌리):
    발견 = []
    for 현재, 폴더들, 파일들 in os.walk(뿌리):
        if 현재 == 뿌리 and ".git" in 폴더들:
            폴더들.remove(".git")
        남길_폴더 = []
        for 이름 in 폴더들:
            상대 = os.path.relpath(os.path.join(현재, 이름), 뿌리)
            if 금지_경로인가(상대):
                발견.append(상대 + "/")
            else:
                남길_폴더.append(이름)
        폴더들[:] = 남길_폴더
        for 이름 in 파일들:
            상대 = os.path.relpath(os.path.join(현재, 이름), 뿌리)
            if 금지_경로인가(상대):
                발견.append(상대)
    return sorted(발견)


def sparse_패턴():
    # 슬래시가 없는 패턴은 모든 깊이에서 맞는다. 안쪽 슬래시가 있는 패턴은 **/ 를 붙여 깊이를 무시한다
    줄 = ["/*"]
    for 항목 in 제외_목록:
        줄.append("!" + ("**/" + 항목 if "/" in 항목.rstrip("/") else 항목))
    return "\n".join(줄) + "\n"


def 라이선스_파일(뿌리):
    try:
        이름들 = os.listdir(뿌리)
    except OSError:
        return []
    return sorted(이름 for 이름 in 이름들 if re.match(r"(licen[cs]e|notice|copying)", 이름, re.I))


def 받기(인자, 작업폴더):
    명령 = ["clone", "--depth", "1", "--no-tags", "--single-branch", "--no-checkout", "--template="]
    if 인자.ref:
        명령 += ["--branch", 인자.ref]
    깃(명령 + ["--", 인자.url, 작업폴더], None, 인자.timeout_sec)
    # 복제본 설정에도 남겨 이후 이 원본에서 git 을 돌려도 같은 조건이 유지되게 한다
    for 키, 값 in (("core.hooksPath", "/dev/null"), ("core.symlinks", "false"), ("submodule.recurse", "false")):
        깃(["config", 키, 값], 작업폴더)
    if 인자.commit:
        현재 = 깃(["rev-parse", "HEAD^{commit}"], 작업폴더)
        if 현재.lower() != 인자.commit.lower():
            깃(["fetch", "--depth", "1", "--no-tags", "origin", 인자.commit], 작업폴더, 인자.timeout_sec)
        return 깃(["rev-parse", 인자.commit + "^{commit}"], 작업폴더).lower()
    return 깃(["rev-parse", "HEAD^{commit}"], 작업폴더).lower()


def 트리_크기(작업폴더, 커밋):
    합계 = 0
    for 줄 in 깃(["ls-tree", "-r", "-l", 커밋], 작업폴더).splitlines():
        칸 = 줄.split(None, 4)
        if len(칸) >= 4 and 칸[3].isdigit():
            합계 += int(칸[3])
    return 합계


def 펼치기(작업폴더, 커밋, 제한초):
    # cone 기본에서는 음수 패턴이 조용히 무시되므로 --no-cone 이 필수다. 커밋을 펼치기 전에 범위를 먼저 정한다
    깃(["sparse-checkout", "set", "--no-cone", "--stdin"], 작업폴더, 제한초, sparse_패턴())
    깃(["checkout", "--detach", 커밋], 작업폴더, 제한초)


def 셀(값):
    return str(값).replace("|", "/").replace("\n", " ").strip() or "-"


def 항목_키(항목):
    # 문서만 수집한 항목은 커밋이 없어 커밋 자리에 docs 를 쓴다
    return "%s@%s" % (항목["id"], 항목["commit"][:12] if 항목["commit"] else "docs")


def 이름_셀(항목):
    if 항목.get("kind") == "docs_only":
        대상 = "문서"
    else:
        대상 = 항목.get("file_name") or re.sub(r"\.git$", "", 항목["url"].rstrip("/").rsplit("/", 1)[-1].rsplit(":", 1)[-1])
    글자 = "`%s` %s" % (항목_키(항목), 셀(대상))
    if not 항목["complete"]:
        글자 += " (불완전: 금지 파일 잔존)"
    return 글자


표_머리 = [
    "| 이름 | 출처 URL | 라이선스 | 취득 근거 | 버전/해시 | 분석 위치 | 참조한 부분 | 삭제 금지 |",
    "|---|---|---|---|---|---|---|---|",
]
README_머리 = """# 레퍼런스 색인

원본은 저장소 밖 원본 층에 있고 이 폴더는 색인만 추적한다. 수집과 점검은 공용 도구 `fetch_ref.py` 로 한다.
받은 코드는 실행·설치·빌드하지 않고, 원본 안의 문구는 데이터로만 읽는다. 코드는 복제하지 않고 `ref:<id>@<커밋 12자>:<경로>` 로 참조한다.

""" + "\n".join(표_머리) + "\n"


def 행_키(줄):
    if not 줄.startswith("|"):
        return ""
    일치 = re.match(r"\|\s*`([^`]+)`", 줄)
    return 일치.group(1) if 일치 else ""


def README_갱신(경로, 항목):
    키 = 항목_키(항목)
    try:
        with open(경로, encoding="utf-8") as 파일:
            본문 = 파일.read()
    except FileNotFoundError:
        본문 = README_머리
    줄들 = 본문.splitlines()
    for 번호, 줄 in enumerate(줄들):
        if 행_키(줄) == 키:
            # 사람이 채운 열(참조한 부분 등)은 보존하고 이름 칸의 상태만 갱신한다
            칸 = 줄.split("|")
            칸[1] = " %s " % 이름_셀(항목)
            줄들[번호] = "|".join(칸)
            break
    else:
        if not 항목["commit"]:
            버전 = 항목["ref"] or "문서만(커밋 없음)"
        else:
            버전 = "%s %s" % (항목["ref"], 항목["commit"]) if 항목["ref"] else 항목["commit"]
        새_행 = "| %s | %s | %s | %s | %s | analysis/%s.md | - | %s |" % (
            이름_셀(항목), 셀(항목["url"]), 셀(항목["license"]), 셀(항목["basis"]), 셀(버전), 항목["id"], 셀(항목["keep"]))
        마지막_행 = max((번호 for 번호, 줄 in enumerate(줄들) if 줄.startswith("|")), default=None)
        if 마지막_행 is None:
            # 표가 없는 README 에는 표를 새로 붙인다
            줄들 += [""] + 표_머리 + [새_행]
        else:
            줄들.insert(마지막_행 + 1, 새_행)
    원자적_쓰기(경로, "\n".join(줄들) + "\n")


def 분석_메모_확보(경로, 항목_id):
    if os.path.exists(경로):
        return
    원자적_쓰기(경로, "# %s 분석 메모\n\n경로·심볼·구조만 적는다. 코드는 옮기지 않는다. 참조 표기는 `ref:%s@<커밋 12자>:<경로>` 다.\n" % (항목_id, 항목_id))


def 색인_갱신(색인, 프로젝트, 항목):
    매니페스트_경로 = os.path.join(색인, "manifest.json")
    if os.path.exists(매니페스트_경로):
        try:
            with open(매니페스트_경로, encoding="utf-8") as 파일:
                기록 = json.load(파일)
            if not isinstance(기록, dict) or not isinstance(기록.get("items"), list):
                raise ValueError("items 없음")
        except (OSError, ValueError) as 오류:
            # 깨진 색인을 덮어쓰면 기록이 사라지므로 멈춘다
            raise 중단(RC_수집_실패, "manifest.json 을 읽을 수 없음: %s" % 오류)
    else:
        기록 = {"schema": 1, "project": 프로젝트, "items": []}
    항목들 = [기존 for 기존 in 기록["items"] if not (기존.get("id") == 항목["id"] and 기존.get("commit") == 항목["commit"])]
    항목들.append(항목)
    기록["items"] = sorted(항목들, key=lambda 값: (값.get("id", ""), 값.get("acquired_at", "")))
    원자적_쓰기(매니페스트_경로, json.dumps(기록, ensure_ascii=False, indent=2) + "\n")
    README_갱신(os.path.join(색인, "README.md"), 항목)
    분석_메모_확보(os.path.join(색인, "analysis", 항목["id"] + ".md"), 항목["id"])


def 링크_확보(루트, 색인, 프로젝트_원본):
    링크 = os.path.join(색인, "src")
    if os.path.islink(링크):
        os.unlink(링크)
    elif os.path.exists(링크):
        print("경고: %s 가 이미 있어 편의 링크를 만들지 않음" % 링크, file=sys.stderr)
        return
    os.symlink(프로젝트_원본, 링크)
    제외파일 = 조회(["rev-parse", "--git-path", "info/exclude"], 루트)
    if not 제외파일:
        return
    제외파일 = os.path.join(루트, 제외파일)
    줄 = "/" + os.path.relpath(링크, 루트)
    try:
        with open(제외파일, encoding="utf-8") as 파일:
            기존 = 파일.read().splitlines()
    except OSError:
        기존 = []
    if 줄 not in 기존:
        os.makedirs(os.path.dirname(제외파일), exist_ok=True)
        with open(제외파일, "a", encoding="utf-8") as 파일:
            파일.write(줄 + "\n")


def 항목_id_유효(값):
    return isinstance(값, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", 값) is not None


def 수집_인자_확인(인자):
    if 인자.docs_only:
        # 문서만 수집: 받지 않고 출처·라이선스 판단·근거만 기록한다. 판단 근거가 비면 기록하지 않는다
        if not 인자.id or not 인자.url or not 인자.license or not 인자.basis:
            raise 중단(RC_인자, "--docs-only 에는 --id --url --license --basis 가 모두 필요하다")
        if 인자.file or 인자.commit or 인자.ref or 인자.keep or 인자.link:
            raise 중단(RC_인자, "--docs-only 는 --file --commit --ref --keep --link 와 함께 쓰지 않는다")
        if not 항목_id_유효(인자.id):
            raise 중단(RC_인자, "--id 는 영문·숫자·. _ - 만 쓴다: %s" % 인자.id)
        if not re.fullmatch(r"https?://[^\s@]+", 인자.url):
            raise 중단(RC_인자, "--docs-only 의 --url 은 자격증명 없는 http(s) 문서 주소여야 한다: %s" % 인자.url)
        if 인자.license.strip() in ("", "미확인") or 인자.basis.strip() in ("", "미기재"):
            raise 중단(RC_인자, "--license·--basis 에 미확인·미기재를 쓸 수 없다")
        return
    if not 인자.id or not (인자.url or 인자.file):
        raise 중단(RC_인자, "수집에는 --id 와 --url(또는 --file)이 필요하다")
    if not 항목_id_유효(인자.id):
        raise 중단(RC_인자, "--id 는 영문·숫자·. _ - 만 쓴다: %s" % 인자.id)
    if 인자.file:
        if 인자.commit:
            raise 중단(RC_인자, "--file 에는 --commit 을 쓰지 않는다. sha256 이 커밋 자리에 기록된다")
        if not os.path.isfile(인자.file):
            raise 중단(RC_인자, "--file 은 존재하는 일반 파일이어야 한다: %s" % 인자.file)
    if 인자.url and (인자.url.startswith("-") or os.path.exists(인자.url)):
        raise 중단(RC_인자, "--url 은 원격 주소여야 한다. 로컬 저장소는 --depth 가 무시되므로 file:// 로 준다: %s" % 인자.url)
    if 인자.url and (re.match(r"https?://[^/]*@", 인자.url) or re.match(r"[a-z+]+://[^/@]*:[^/@]*@", 인자.url)):
        raise 중단(RC_인자, "--url 에 자격증명을 넣지 않는다. manifest 가 git 에 추적된다")
    if 인자.ref and (인자.ref.startswith("-") or re.search(r"\s", 인자.ref)):
        raise 중단(RC_인자, "--ref 값이 올바르지 않음: %s" % 인자.ref)
    if 인자.commit and not re.fullmatch(r"[0-9a-fA-F]{40}|[0-9a-fA-F]{64}", 인자.commit):
        raise 중단(RC_인자, "--commit 은 전체 해시여야 한다: %s" % 인자.commit)


def 파일_해시(경로):
    해시 = hashlib.sha256()
    with open(경로, "rb") as 파일:
        for 조각 in iter(lambda: 파일.read(1024 * 1024), b""):
            해시.update(조각)
    return 해시.hexdigest()


def 파일_등록(인자, 프로젝트_원본, 기존_사용량, 상한):
    # 파일은 읽기만 한다. 실행·압축 해제·설치를 하지 않고, 복사본에 실행 권한을 주지 않는다
    이름 = os.path.basename(os.path.abspath(인자.file))
    크기 = os.path.getsize(인자.file)
    if 크기 > 상한["item_gb"] * GB:
        raise 중단(RC_용량, "항목 상한 초과: %.3fGB > %.3fGB" % (크기 / GB, 상한["item_gb"]))
    임시 = tempfile.mkdtemp(prefix=임시_접두 + 인자.id + "-", dir=프로젝트_원본)
    try:
        작업폴더 = os.path.join(임시, "item")
        os.makedirs(작업폴더)
        복사본 = os.path.join(작업폴더, 이름)
        해시 = hashlib.sha256()
        try:
            with open(인자.file, "rb") as 입력, open(복사본, "wb") as 출력:
                for 조각 in iter(lambda: 입력.read(1024 * 1024), b""):
                    해시.update(조각)
                    출력.write(조각)
        except OSError as 오류:
            raise 중단(RC_수집_실패, "파일을 읽거나 복사하지 못함: %s" % 오류)
        값 = 해시.hexdigest()
        최종 = os.path.join(프로젝트_원본, "%s@%s" % (인자.id, 값[:12]))
        if os.path.exists(최종):
            기존 = os.path.join(최종, 이름)
            if not os.path.isfile(기존) or 파일_해시(기존) != 값:
                raise 중단(RC_수집_실패, "기존 원본이 이 파일과 다름(변조 또는 다른 파일 이름): %s" % 최종)
            print("기존 원본 재사용: %s" % 최종)
        else:
            if 기존_사용량 + 크기 > 상한["limit_gb"] * GB:
                raise 중단(RC_용량, "프로젝트 상한 초과: %.3fGB > %.3fGB" % ((기존_사용량 + 크기) / GB, 상한["limit_gb"]))
            try:
                os.rename(작업폴더, 최종)
            except OSError as 오류:
                raise 중단(RC_수집_실패, "원본 층으로 옮기지 못함: %s" % 오류)
    finally:
        shutil.rmtree(임시, ignore_errors=True)
    return 값, 최종, 이름


def 저장소_받기(인자, 프로젝트_원본, 기존_사용량, 상한):
    임시 = tempfile.mkdtemp(prefix=임시_접두 + 인자.id + "-", dir=프로젝트_원본)
    try:
        작업폴더 = os.path.join(임시, "repo")
        커밋 = 받기(인자, 작업폴더)
        최종 = os.path.join(프로젝트_원본, "%s@%s" % (인자.id, 커밋[:12]))
        if os.path.exists(최종):
            print("기존 원본 재사용: %s" % 최종)
        else:
            예상 = 디렉터리_크기(작업폴더) + 트리_크기(작업폴더, 커밋)
            if 예상 > 상한["item_gb"] * GB:
                raise 중단(RC_용량, "항목 상한 초과 예상으로 펼치지 않음: %.3fGB > %.3fGB" % (예상 / GB, 상한["item_gb"]))
            펼치기(작업폴더, 커밋, 인자.timeout_sec)
            새_크기 = 디렉터리_크기(작업폴더)
            if 새_크기 > 상한["item_gb"] * GB:
                raise 중단(RC_용량, "항목 상한 초과: %.3fGB > %.3fGB" % (새_크기 / GB, 상한["item_gb"]))
            if 기존_사용량 + 새_크기 > 상한["limit_gb"] * GB:
                raise 중단(RC_용량, "프로젝트 상한 초과: %.3fGB > %.3fGB" % ((기존_사용량 + 새_크기) / GB, 상한["limit_gb"]))
            try:
                os.rename(작업폴더, 최종)
            except OSError as 오류:
                raise 중단(RC_수집_실패, "원본 층으로 옮기지 못함: %s" % 오류)
    finally:
        shutil.rmtree(임시, ignore_errors=True)
    return 커밋, 최종


def 문서_등록(인자, 루트, 색인, 프로젝트, 프로젝트_원본):
    # 문서만 수집한 항목: 원본 층 폴더를 만들지 않고 색인만 갱신한다. 잠금만 원본 층 프로젝트 폴더에 둔다
    항목 = {
        "id": 인자.id, "kind": "docs_only", "url": 인자.url, "ref": "", "commit": "", "store_dir": "",
        "license": 인자.license, "license_files": [], "basis": 인자.basis, "keep": "아니오",
        "acquired_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "bytes": 0, "excluded": [], "forbidden_found": [], "quarantine": False, "complete": True,
    }
    os.makedirs(프로젝트_원본, exist_ok=True)
    with open(os.path.join(프로젝트_원본, 잠금_파일), "a") as 잠금:
        fcntl.flock(잠금, fcntl.LOCK_EX)
        색인_갱신(색인, 프로젝트, 항목)
    print("DOCS_ONLY %s 색인=%s" % (인자.id, 색인))
    return RC_정상


def 수집(인자):
    수집_인자_확인(인자)
    루트 = 프로젝트_루트(인자.project)
    색인 = 색인_위치(루트, 인자.ref_root)
    상한 = 상한_결정(루트, 인자)
    원본 = 원본_루트()
    저장소_밖_확인(원본, 루트)
    프로젝트, 이름_명시 = 프로젝트_이름_결정(루트, 인자)
    프로젝트_원본, 경고들, 모호 = 원본_폴더_결정(원본, 프로젝트, 이름_명시)
    if 모호:
        raise 중단(RC_인자, 모호)
    for 줄 in 경고들:
        print(줄, file=sys.stderr)
    저장_이름 = os.path.basename(프로젝트_원본)

    if 인자.docs_only:
        return 문서_등록(인자, 루트, 색인, 프로젝트, 프로젝트_원본)

    여유_확인(원본, 인자.free_path, 상한["min_free_gb"])
    os.makedirs(프로젝트_원본, exist_ok=True)
    기존_사용량 = 디렉터리_크기(프로젝트_원본, (잠금_파일,))
    if 기존_사용량 >= 상한["limit_gb"] * GB:
        raise 중단(RC_용량, "프로젝트 상한 도달: %.2fGB >= %.2fGB" % (기존_사용량 / GB, 상한["limit_gb"]))

    파일_이름 = None
    if 인자.file:
        커밋, 최종, 파일_이름 = 파일_등록(인자, 프로젝트_원본, 기존_사용량, 상한)
    else:
        커밋, 최종 = 저장소_받기(인자, 프로젝트_원본, 기존_사용량, 상한)

    크기 = 디렉터리_크기(최종)
    발견 = 금지_파일_검사(최종)
    항목 = {
        "id": 인자.id, "url": 인자.url or "미기재", "ref": 인자.ref or "", "commit": 커밋,
        "store_dir": "%s/%s@%s" % (저장_이름, 인자.id, 커밋[:12]),
        "license": 인자.license or "미확인", "license_files": 라이선스_파일(최종),
        "basis": 인자.basis or "미기재", "keep": ("예: " + 인자.keep) if 인자.keep else "아니오",
        "acquired_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "bytes": 크기, "excluded": 제외_목록, "forbidden_found": 발견,
        "quarantine": bool(발견), "complete": not 발견,
    }
    if 파일_이름:
        # sparse 제외는 git 수집에만 적용되므로 빈 목록으로 남긴다. 사후 검사는 위에서 같은 규칙으로 돌았다
        항목.update({"kind": "file", "file_name": 파일_이름, "excluded": []})
    with open(os.path.join(프로젝트_원본, 잠금_파일), "a") as 잠금:
        fcntl.flock(잠금, fcntl.LOCK_EX)
        색인_갱신(색인, 프로젝트, 항목)
        if 인자.link:
            링크_확보(루트, 색인, 프로젝트_원본)

    사용량 = 디렉터리_크기(프로젝트_원본, (잠금_파일,))
    if 사용량 > 상한["warn_gb"] * GB:
        print("경고: 프로젝트 사용량 %.2fGB 가 경고값 %.2fGB 를 넘음" % (사용량 / GB, 상한["warn_gb"]), file=sys.stderr)
    if 항목["license"] == "미확인":
        print("경고: 라이선스 미기재 — --license 로 확인한 값을 적는다(발견 파일: %s)" % (", ".join(항목["license_files"]) or "없음"), file=sys.stderr)
    print("FETCHED %s@%s bytes=%d 원본=%s" % (인자.id, 커밋[:12], 크기, 최종))
    if 발견:
        for 경로 in 발견:
            print("FORBIDDEN %s" % 경로, file=sys.stderr)
        print("항목을 불완전으로 표시했다: 금지 파일 %d건" % len(발견), file=sys.stderr)
        return RC_금지파일
    색인_크기 = 디렉터리_크기(색인, ("src",))
    if 색인_크기 > 상한["index_mb"] * MB:
        print("INDEX_OVER 색인 %.2fMB > 상한 %.2fMB" % (색인_크기 / MB, 상한["index_mb"]), file=sys.stderr)
        return RC_용량
    return RC_정상


def 등록_파일_점검(항목, 키, 경로):
    # sha256 을 다시 계산해 변조를 찾는다. manifest 의 파일 이름이 폴더 밖을 가리키면 읽지 않는다
    이름 = 항목.get("file_name")
    if not isinstance(이름, str) or not 이름 or 이름 in (".", "..") or os.path.basename(이름) != 이름:
        return ["MANIFEST_INVALID file_name %s" % 키]
    문제 = []
    대상 = os.path.join(경로, 이름)
    if not os.path.isfile(대상):
        문제.append("FILE_MISSING %s:%s" % (키, 이름))
    else:
        try:
            if 파일_해시(대상) != 항목.get("commit"):
                문제.append("HASH_MISMATCH %s:%s" % (키, 이름))
        except OSError as 오류:
            문제.append("HASH_UNREADABLE %s:%s %s" % (키, 이름, 오류))
    for 다른 in sorted(set(os.listdir(경로)) - {이름}):
        문제.append("UNEXPECTED %s:%s" % (키, 다른))
    return 문제


def 점검(인자):
    루트 = 프로젝트_루트(인자.project)
    색인 = 색인_위치(루트, 인자.ref_root)
    상한 = 상한_결정(루트, 인자)
    프로젝트, 이름_명시 = 프로젝트_이름_결정(루트, 인자)
    프로젝트_원본, 경고들, 모호 = 원본_폴더_결정(원본_루트(), 프로젝트, 이름_명시)
    문제 = []
    참고 = []
    미실행 = 0
    if 모호:
        문제.append(모호)
    for 줄 in 경고들:
        print(줄)

    매니페스트_경로 = os.path.join(색인, "manifest.json")
    항목들 = []
    if os.path.exists(매니페스트_경로):
        try:
            with open(매니페스트_경로, encoding="utf-8") as 파일:
                항목들 = json.load(파일)["items"]
            if not isinstance(항목들, list):
                raise ValueError("items 가 목록이 아님")
        except (OSError, ValueError, KeyError, TypeError) as 오류:
            문제.append("MANIFEST_INVALID %s" % 오류)
            항목들 = []
    else:
        참고.append("NO_INDEX %s" % 색인)

    README_경로 = os.path.join(색인, "README.md")
    행들 = set()
    if os.path.exists(README_경로):
        with open(README_경로, encoding="utf-8") as 파일:
            행들 = {행_키(줄) for 줄 in 파일 if 행_키(줄)}
    elif 항목들:
        문제.append("MISSING_README %s" % README_경로)

    색인된_id = set()
    색인된_키 = set()
    저장된_키 = set()
    for 항목 in 항목들:
        항목_id = 항목.get("id") if isinstance(항목, dict) else None
        커밋 = 항목.get("commit") if isinstance(항목, dict) else None
        문서만 = isinstance(항목, dict) and 항목.get("kind") == "docs_only"
        if 문서만:
            # 커밋은 비어 있어야 하고, 출처·취득 시각·라이선스·근거가 모두 실제 값이어야 한다
            유효 = 항목_id_유효(항목_id) and 커밋 == "" and all(
                isinstance(항목.get(필드), str) and 항목[필드].strip() not in ("", "미기재", "미확인")
                for 필드 in ("url", "acquired_at", "license", "basis"))
        else:
            유효 = 항목_id_유효(항목_id) and isinstance(커밋, str) and re.fullmatch(r"[0-9a-f]{40,64}", 커밋) is not None
        if not 유효:
            문제.append("MANIFEST_INVALID 항목 %s" % json.dumps(항목, ensure_ascii=False)[:120])
            continue
        키 = "%s@%s" % (항목_id, "docs" if 문서만 else 커밋[:12])
        색인된_id.add(항목_id)
        색인된_키.add(키)
        if not 문서만:
            저장된_키.add(키)
        if 키 not in 행들:
            문제.append("MISSING_ROW %s" % 키)
        if not os.path.isfile(os.path.join(색인, "analysis", 항목_id + ".md")):
            문제.append("MISSING_ANALYSIS %s" % 항목_id)
        if 항목.get("quarantine") or not 항목.get("complete", False):
            문제.append("INCOMPLETE %s" % 키)
        경로 = os.path.join(프로젝트_원본, 키)
        if 문서만:
            continue
        if os.path.isdir(경로):
            for 상대 in 금지_파일_검사(경로):
                문제.append("FORBIDDEN %s:%s" % (키, 상대))
            if 항목.get("kind") == "file":
                문제.extend(등록_파일_점검(항목, 키, 경로))
        else:
            참고.append("SOURCE_MISSING %s (색인은 유지, 원본만 없음)" % 키)
            미실행 += 1
    for 키 in sorted(행들 - 색인된_키):
        문제.append("ORPHAN_ROW %s" % 키)
    분석_폴더 = os.path.join(색인, "analysis")
    if os.path.isdir(분석_폴더):
        for 이름 in sorted(os.listdir(분석_폴더)):
            if 이름.endswith(".md") and 이름[:-3] not in 색인된_id:
                문제.append("ORPHAN_ANALYSIS %s" % 이름)

    if os.path.isdir(프로젝트_원본):
        for 이름 in sorted(os.listdir(프로젝트_원본)):
            if 이름 == 잠금_파일:
                continue
            if 이름.startswith(임시_접두):
                참고.append("TMP_LEFTOVER %s (수집 중이 아니면 잔여물)" % 이름)
            elif 이름 not in 저장된_키:
                문제.append("UNINDEXED %s" % 이름)
        사용량 = 디렉터리_크기(프로젝트_원본, (잠금_파일,))
        if 사용량 > 상한["limit_gb"] * GB:
            문제.append("STORE_OVER %.2fGB > %.2fGB" % (사용량 / GB, 상한["limit_gb"]))
        elif 사용량 > 상한["warn_gb"] * GB:
            참고.append("STORE_WARN %.2fGB > %.2fGB" % (사용량 / GB, 상한["warn_gb"]))
    if os.path.isdir(색인):
        색인_크기 = 디렉터리_크기(색인, ("src",))
        if 색인_크기 > 상한["index_mb"] * MB:
            문제.append("INDEX_OVER %.2fMB > %.2fMB" % (색인_크기 / MB, 상한["index_mb"]))

    for 줄 in 참고:
        print("참고: " + 줄)
    for 줄 in 문제:
        print(줄)
    # 원본 층이 없어 대조하지 못한 항목이 있으면 OK 라고 쓰지 않는다. 다른 환경에서는 정상일 수 있어 rc 는 바꾸지 않는다
    꼬리 = " 원본 대조 미실행 %d건" % 미실행 if 미실행 else ""
    상태 = "FAIL" if 문제 else ("PARTIAL" if 미실행 else "OK")
    print("VERIFY %s 항목=%d 문제=%d%s" % (상태, len(항목들), len(문제), 꼬리))
    return RC_점검_위반 if 문제 else RC_정상


def 파서():
    p = argparse.ArgumentParser(
        prog="fetch_ref.py", description="외부 레퍼런스 원본 수집과 색인 점검. 받은 코드는 실행·설치·빌드하지 않는다.",
        epilog=도움말_꼬리, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--verify", action="store_true", help="manifest·README·analysis 대응과 원본 금지 파일·색인 밖 원본을 점검한다")
    p.add_argument("--id", help="항목 id (영문·숫자·. _ -)")
    p.add_argument("--url", help="원격 저장소 주소. 로컬 저장소는 file:// 로 준다. --file 이면 출처 기록용(접속하지 않음)")
    p.add_argument("--file", help="git 이 아닌 배포물 파일을 등록한다. sha256 만 계산해 복사하고 실행·압축 해제·설치는 하지 않는다")
    p.add_argument("--ref", help="받을 브랜치·태그(기본은 원격 기본 브랜치). --file 이면 버전 표기")
    p.add_argument("--commit", help="고정할 전체 커밋 해시")
    p.add_argument("--license", help="확인한 라이선스 이름(미지정 시 미확인으로 기록)")
    p.add_argument("--basis", help="취득 근거")
    p.add_argument("--keep", help="원본까지 보존해야 하는 사유(README 삭제 금지 열)")
    p.add_argument("--link", action="store_true", help="<ref_root>/src 편의 링크를 만들고 추적에서 뺀다")
    p.add_argument("--docs-only", action="store_true", help="문서만 수집한 항목을 기록한다(kind=docs_only). 받지 않으며 --id --url --license --basis 가 모두 필요하다")
    p.add_argument("--project-name", help="원본 층 프로젝트 폴더 이름을 고정한다(기본: 원본 저장소 이름, 대소문자만 다른 폴더가 정확히 1개면 그 폴더)")
    p.add_argument("--project", help="프로젝트 루트(기본: 현재 위치의 git 최상위)")
    p.add_argument("--ref-root", help="색인 위치(프로젝트 기준 상대경로)")
    p.add_argument("--limit-gb", type=float, help="프로젝트당 상한 GB")
    p.add_argument("--warn-gb", type=float, help="프로젝트당 경고 GB")
    p.add_argument("--item-limit-gb", type=float, help="항목당 상한 GB")
    p.add_argument("--index-limit-mb", type=float, help="색인 층 상한 MB")
    p.add_argument("--min-free-gb", type=float, help="이 값 미만이면 수집을 중단하는 여유 GB")
    p.add_argument("--free-path", help="여유 판정에 쓸 경로(기본은 원본 층이 실제로 사는 디스크)")
    p.add_argument("--timeout-sec", type=int, default=600, help="git 명령 하나의 제한 시간(초, 기본 600)")
    return p


def main():
    인자 = 파서().parse_args()
    try:
        return 점검(인자) if 인자.verify else 수집(인자)
    except 중단 as 오류:
        print("오류: %s" % 오류, file=sys.stderr)
        return 오류.코드


if __name__ == "__main__":
    sys.exit(main())
