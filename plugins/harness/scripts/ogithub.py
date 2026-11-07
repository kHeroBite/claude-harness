#!/usr/bin/env python3
# 추적 중인 오픈소스의 직전 실행 이후 버전업과 새로 주목받는 저장소를 판정하고 원하면 레퍼런스를 다시 수집하는 도구
"""ogithub.py — 직전 실행 이후 바뀐 오픈소스를 찾는다.

판정 원천
  1순위 git ls-remote  — 한도 없음. 저장소마다 HEAD 커밋과 최신 태그를 본다.
  2순위 GitHub REST    — /rate_limit 잔여가 충분할 때만 별 수(/repos/{repo})와 신규 후보(/search/repositories)를 본다.
토큰은 쓰지 않는다. 받은 코드는 실행하지 않는다. 표준 라이브러리만 쓴다(python3.10 호환).

판정 종류
  BASELINE 첫 실행 — 값만 기록한다.
  UPDATED  track=release 는 최신 태그(태그가 없으면 HEAD), track=head 는 HEAD 커밋이 바뀜.
  SAME     변화 없음.
  NEW      추적 목록·이미 본 목록에 없고 min_stars 이상인 신규 저장소(직전 실행 이후 생성).
  PARTIAL  일부 조회 실패·API 예산 부족·재수집 실패. rc=3 이고 상태 파일(last_run 포함)을 갱신하지 않는다.

상태 기록: 첫 실행(BASELINE)과 --apply 실행만 상태 파일을 쓴다. 확인만 하는 실행은 보고만 하므로
  "먼저 확인 → 필요하면 --apply" 로 써도 UPDATED 가 사라지지 않는다. --apply 는 재수집에 성공한 저장소만 반영한다.

종료 코드: 0 OK·BASELINE · 2 인자·입력 오류 · 3 PARTIAL

시험용 대체
  OGITHUB_FIXTURE=<json>   네트워크 대신 쓴다. 형식:
    {"api": {"/rate_limit": {"status":200,"body":{...}}, "/repos/o/r": {...}, "search:<질의>": {...}},
     "ls_remote": {"<url>": {"HEAD":"<sha>", "refs/tags/v1":"<sha>"}}}
    search 는 날짜·별 조건을 붙이기 전 질의 원문으로 찾는다. 없는 키는 조회 실패로 본다.
  OGITHUB_FETCH_CMD=<명령> --apply 의 재수집 명령(기본: python3 -I <이 폴더>/fetch_ref.py). shlex 로 나눈다.
  OGITHUB_HOME=<폴더>   상태 폴더(기본 ~/.claude/ogithub).

옛 이름 호환(2026-11-07 개명)
  옛 환경변수 OGIT_FIXTURE·OGIT_FETCH_CMD·OGIT_HOME 은 새 이름이 없을 때만 읽는다.  # OGIT-COMPAT
  상태 폴더 환경변수가 둘 다 없고 새 상태 파일이 없으면 ~/.claude/ogit 의 옛 상태 파일을 읽는다. 쓰기는 새 위치만 한다.  # OGIT-COMPAT
  --watch 가 없고 <ref_root>/ogithub_watch.json 이 없으면 옛 ogit_watch.json 을 읽는다.  # OGIT-COMPAT
"""
import argparse
import datetime
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request

RC_정상 = 0
RC_인자 = 2
RC_부분 = 3

API_기본 = "https://api.github.com"
KST = datetime.timezone(datetime.timedelta(hours=9))
본_목록_상한 = 2000
불안정_태그 = re.compile(r"(alpha|beta|rc|pre|dev|nightly|canary|snapshot)", re.I)
확인_패턴 = r"\d{4}-\d{2}-\d{2} \d{2}:\d{2} KST 확인"
상태_폴더_기본 = "~/.claude/ogithub"
옛_상태_폴더 = "~/.claude/ogit"  # OGIT-COMPAT
옛_추적_파일 = "ogit_watch.json"  # OGIT-COMPAT
옛_재수집_표식 = "ogit 재수집"  # OGIT-COMPAT


def 환경값(새_키, 옛_키):
    """새 이름(OGITHUB_*)이 정본이다. 새 이름이 비어 있을 때만 옛 이름을 읽는다."""
    return os.environ.get(새_키) or os.environ.get(옛_키)  # OGIT-COMPAT 옛 환경변수 읽기 폴백


class 입력오류(Exception):
    pass


def 지금(인자_now):
    if 인자_now:
        try:
            값 = datetime.datetime.fromisoformat(인자_now.replace("Z", "+00:00"))
        except ValueError:
            raise 입력오류("--now 형식 오류: %s" % 인자_now)
        if 값.tzinfo is None:
            값 = 값.replace(tzinfo=datetime.timezone.utc)
        return 값.astimezone(datetime.timezone.utc)
    return datetime.datetime.now(datetime.timezone.utc)


def iso(값):
    return 값.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def iso_읽기(문자):
    try:
        값 = datetime.datetime.fromisoformat(str(문자).replace("Z", "+00:00"))
    except ValueError:
        return None
    return 값 if 값.tzinfo else 값.replace(tzinfo=datetime.timezone.utc)


def json_파일(경로):
    with open(경로, encoding="utf-8") as 파일:
        return json.load(파일)


def 원자적_쓰기(경로, 내용):
    폴더 = os.path.dirname(os.path.abspath(경로))
    os.makedirs(폴더, exist_ok=True)
    핸들, 임시 = tempfile.mkstemp(dir=폴더, prefix=".tmp-ogithub-")
    try:
        with os.fdopen(핸들, "w", encoding="utf-8", newline="\n") as 파일:
            파일.write(내용)
        os.chmod(임시, 0o644)
        os.replace(임시, 경로)
    except BaseException:
        if os.path.exists(임시):
            os.unlink(임시)
        raise


def 깃_환경():
    환경 = dict(os.environ)
    for 키 in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"):
        환경.pop(키, None)
    환경["GIT_TERMINAL_PROMPT"] = "0"
    환경["GIT_ALLOW_PROTOCOL"] = "file:git:http:https:ssh"
    return 환경


def 프로젝트_루트(지정):
    if 지정:
        경로 = os.path.realpath(지정)
        if not os.path.isdir(경로):
            raise 입력오류("프로젝트 경로가 없음: %s" % 지정)
        return 경로
    try:
        결과 = subprocess.run(["git", "rev-parse", "--show-toplevel"], stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, universal_newlines=True, timeout=30, env=깃_환경())
    except (OSError, subprocess.TimeoutExpired):
        결과 = None
    if not 결과 or 결과.returncode != 0 or not 결과.stdout.strip():
        raise 입력오류("git 저장소 안에서 실행하거나 --project 를 지정한다")
    return os.path.realpath(결과.stdout.strip())


def 프로젝트_이름(루트, 매니페스트, 지정):
    if 지정:
        return 지정
    if isinstance(매니페스트, dict) and isinstance(매니페스트.get("project"), str) and 매니페스트["project"]:
        return 매니페스트["project"]
    return os.path.basename(루트)


# ---------------------------------------------------------------- 조회 계층

class 조회기:
    """네트워크 또는 픽스처에서 ls-remote·API 결과를 가져온다. 실패는 None·(0, None) 으로 돌려준다."""

    def __init__(self):
        self.픽스처 = None
        경로 = 환경값("OGITHUB_FIXTURE", "OGIT_FIXTURE")  # OGIT-COMPAT
        if 경로:
            try:
                self.픽스처 = json_파일(경로)
            except (OSError, ValueError) as 오류:
                raise 입력오류("OGITHUB_FIXTURE 를 읽을 수 없음: %s" % 오류)
            if not isinstance(self.픽스처, dict):
                raise 입력오류("OGITHUB_FIXTURE 형식 오류")

    def ls_remote(self, url, 가지=""):
        if self.픽스처 is not None:
            값 = (self.픽스처.get("ls_remote") or {}).get(url)
            return dict(값) if isinstance(값, dict) else None
        if url.startswith("-") or not re.match(r"(https?|git|ssh)://", url):
            return None
        try:
            결과 = subprocess.run(
                ["git", "-c", "protocol.ext.allow=never", "-c", "core.hooksPath=/dev/null",
                 "ls-remote", "--", url, "HEAD", "refs/tags/*"] + (["refs/heads/" + 가지] if 가지 else []),
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, timeout=60, env=깃_환경())
        except (OSError, subprocess.TimeoutExpired):
            return None
        if 결과.returncode != 0:
            return None
        참조 = {}
        for 줄 in 결과.stdout.splitlines():
            칸 = 줄.split("\t")
            if len(칸) == 2 and re.fullmatch(r"[0-9a-f]{40,64}", 칸[0]):
                참조[칸[1]] = 칸[0]
        return 참조

    def api(self, 경로, 질의=None, 픽스처_키=None):
        """(status, body) 를 돌려준다. 네트워크 실패는 (0, None)."""
        if self.픽스처 is not None:
            값 = (self.픽스처.get("api") or {}).get(픽스처_키 or 경로)
            if not isinstance(값, dict):
                return 0, None
            return int(값.get("status", 200)), 값.get("body")
        주소 = API_기본 + 경로
        if 질의:
            주소 += "?" + urllib.parse.urlencode(질의)
        요청 = urllib.request.Request(주소, headers={
            "Accept": "application/vnd.github+json", "User-Agent": "ogithub-harness",
            "X-GitHub-Api-Version": "2022-11-28"})
        try:
            with urllib.request.urlopen(요청, timeout=20) as 응답:
                return 응답.status, json.loads(응답.read().decode("utf-8"))
        except urllib.error.HTTPError as 오류:
            return 오류.code, None
        except (urllib.error.URLError, OSError, ValueError):
            return 0, None


def 버전_키(이름):
    return ([int(조각) for 조각 in re.findall(r"\d+", 이름)], 이름)


def 최신_태그(참조):
    """ls-remote 결과에서 버전 순으로 가장 큰 태그와 그 커밋(벗긴 ^{} 값 우선)을 고른다."""
    태그 = {}
    for 이름, 해시 in 참조.items():
        if not 이름.startswith("refs/tags/"):
            continue
        짧은 = 이름[len("refs/tags/"):]
        if 짧은.endswith("^{}"):
            태그[짧은[:-3]] = 해시
        else:
            태그.setdefault(짧은, 해시)
    if not 태그:
        return None, None
    안정 = [이름 for 이름 in 태그 if not 불안정_태그.search(이름) and re.search(r"\d", 이름)]
    고른 = max(안정 or list(태그), key=버전_키)
    return 고른, 태그[고른]


# ---------------------------------------------------------------- 입력·상태

def 추적_목록(경로):
    try:
        값 = json_파일(경로)
    except (OSError, ValueError) as 오류:
        raise 입력오류("추적 목록을 읽을 수 없음 %s: %s" % (경로, 오류))
    저장소들 = 값.get("repos") if isinstance(값, dict) else None
    if not isinstance(저장소들, list):
        raise 입력오류("추적 목록에 repos 목록이 없음: %s" % 경로)
    결과 = []
    본_id = set()
    for 항목 in 저장소들:
        if not isinstance(항목, dict):
            raise 입력오류("repos 항목 형식 오류: %r" % (항목,))
        항목_id, 저장소, 주소 = 항목.get("id"), 항목.get("repo"), 항목.get("url")
        if not (isinstance(항목_id, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", 항목_id)):
            raise 입력오류("id 형식 오류: %r" % (항목_id,))
        if not (isinstance(저장소, str) and re.fullmatch(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+", 저장소)):
            raise 입력오류("repo 형식 오류(owner/name): %r" % (저장소,))
        if 항목_id in 본_id:
            raise 입력오류("id 중복: %s" % 항목_id)
        본_id.add(항목_id)
        주소 = 주소 if isinstance(주소, str) and 주소 else "https://github.com/%s" % 저장소
        추적 = 항목.get("track") or "head"
        if 추적 not in ("release", "head"):
            raise 입력오류("track 은 release|head: %s" % 추적)
        # branch 는 head 비교 대상 브랜치다. 없으면 원격 기본 브랜치(HEAD)를 본다. 그 밖의 모르는 키는 무시한다
        가지 = 항목.get("branch") or ""
        if 가지 and not (isinstance(가지, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]*", 가지) and ".." not in 가지):
            raise 입력오류("branch 형식 오류: %r" % (가지,))
        결과.append({"id": 항목_id, "repo": 저장소, "url": 주소, "track": 추적, "branch": 가지})
    탐색 = 값.get("discover") if isinstance(값.get("discover"), dict) else {}
    try:
        설정 = {
            "queries": [q for q in (탐색.get("queries") or []) if isinstance(q, str) and q.strip()],
            "min_stars": int(탐색.get("min_stars", 1000)),
            "window_days": int(탐색.get("window_days", 30)),
            "max_results": max(1, min(100, int(탐색.get("max_results", 10)))),
        }
    except (TypeError, ValueError):
        raise 입력오류("discover 숫자 값 형식 오류")
    return 결과, 설정


def 상태_읽기(경로):
    if not os.path.exists(경로):
        return None, []
    try:
        값 = json_파일(경로)
        if not isinstance(값, dict) or not isinstance(값.get("repos"), dict):
            raise ValueError("repos 없음")
        return 값, []
    except (OSError, ValueError) as 오류:
        return None, ["경고: 상태 파일이 깨져 기준선을 다시 만든다: %s (%s)" % (경로, 오류)]


# ---------------------------------------------------------------- 판정

def 판정(저장소들, 탐색, 상태, 현재, 조회):
    첫실행 = 상태 is None
    이전 = (상태 or {}).get("repos", {})
    본 = set(s.lower() for s in (상태 or {}).get("seen", []) if isinstance(s, str))
    결과 = {"updates": [], "new": [], "same": [], "baseline": [], "partial": [], "repos": {}}

    # 1) ls-remote — 한도가 없으므로 항상 먼저 본다
    for 항목 in 저장소들:
        참조 = 조회.ls_remote(항목["url"], 항목["branch"])
        옛 = 이전.get(항목["id"]) if isinstance(이전.get(항목["id"]), dict) else {}
        머리_참조 = "refs/heads/" + 항목["branch"] if 항목["branch"] else "HEAD"
        if 참조 is None or not 참조.get(머리_참조):
            결과["partial"].append("ls-remote 실패 %s(%s)" % (항목["id"], 머리_참조))
            if 옛:
                결과["repos"][항목["id"]] = dict(옛)
            continue
        머리 = 참조[머리_참조]
        태그, 태그_해시 = 최신_태그(참조)
        새 = {"head": 머리, "tag": 태그 or "", "tag_commit": 태그_해시 or "", "stars": 옛.get("stars")}
        결과["repos"][항목["id"]] = 새
        if 첫실행 or not 옛:
            결과["baseline"].append({"id": 항목["id"], "tag": 새["tag"], "head": 머리})
            continue
        기준 = "tag" if 항목["track"] == "release" and 태그 else "head"
        if (옛.get(기준) or "") != 새[기준]:
            결과["updates"].append({"id": 항목["id"], "repo": 항목["repo"], "url": 항목["url"], "kind": 기준,
                                 "old": 옛.get(기준) or "", "new": 새[기준],
                                 "commit": (태그_해시 if 기준 == "tag" else 머리) or 머리,
                                 "ref": 태그 if 기준 == "tag" else ""})
        else:
            결과["same"].append(항목["id"])

    # 2) API 예산 — /rate_limit 은 잔여를 차감하지 않는다
    상태코드, 한도 = 조회.api("/rate_limit")
    if 상태코드 != 200 or not isinstance(한도, dict):
        결과["partial"].append("rate_limit 조회 실패(status=%s) — 별 수·신규 후보 판정 생략" % 상태코드)
        return 결과, 첫실행, 본
    자원 = 한도.get("resources") or {}
    try:
        핵심_잔여 = int((자원.get("core") or {}).get("remaining", 0))
        검색_잔여 = int((자원.get("search") or {}).get("remaining", 0))
    except (TypeError, ValueError):
        핵심_잔여 = 검색_잔여 = 0

    if 핵심_잔여 >= len(저장소들):
        for 항목 in 저장소들:
            코드, 본문 = 조회.api("/repos/%s" % 항목["repo"])
            if 코드 == 200 and isinstance(본문, dict) and isinstance(본문.get("stargazers_count"), int):
                if 항목["id"] in 결과["repos"]:
                    결과["repos"][항목["id"]]["stars"] = 본문["stargazers_count"]
            else:
                결과["partial"].append("별 수 조회 실패 %s(status=%s)" % (항목["repo"], 코드))
    else:
        결과["partial"].append("API 예산 부족 core 잔여 %d < 필요 %d — 별 수 생략" % (핵심_잔여, len(저장소들)))

    if not 탐색["queries"]:
        return 결과, 첫실행, 본
    if 검색_잔여 < len(탐색["queries"]):
        결과["partial"].append("API 예산 부족 search 잔여 %d < 필요 %d — 신규 후보 생략" % (검색_잔여, len(탐색["queries"])))
        return 결과, 첫실행, 본

    마지막 = None if 첫실행 else iso_읽기((상태 or {}).get("last_run", ""))
    시작 = 마지막 or (현재 - datetime.timedelta(days=탐색["window_days"]))
    시작_날짜 = 시작.replace(hour=0, minute=0, second=0, microsecond=0)
    추적_이름 = set(항목["repo"].lower() for 항목 in 저장소들)
    후보 = {}
    for 질의 in 탐색["queries"]:
        q = "%s created:>=%s stars:>=%d" % (질의, 시작.strftime("%Y-%m-%d"), 탐색["min_stars"])
        코드, 본문 = 조회.api("/search/repositories",
                          {"q": q, "sort": "stars", "order": "desc", "per_page": 탐색["max_results"]},
                          픽스처_키="search:" + 질의)
        if 코드 != 200 or not isinstance(본문, dict) or not isinstance(본문.get("items"), list):
            결과["partial"].append("신규 후보 검색 실패 '%s'(status=%s)" % (질의, 코드))
            continue
        for 저장소 in 본문["items"]:
            if not isinstance(저장소, dict) or not isinstance(저장소.get("full_name"), str):
                continue
            이름 = 저장소["full_name"]
            별 = 저장소.get("stargazers_count") if isinstance(저장소.get("stargazers_count"), int) else 0
            생성 = iso_읽기(저장소.get("created_at", ""))
            # 검색 조건을 코드에서도 다시 확인한다(근사 검색 결과를 그대로 믿지 않는다)
            if 별 < 탐색["min_stars"] or (생성 is not None and 생성 < 시작_날짜):
                continue
            if 이름.lower() in 추적_이름 or 이름.lower() in 본:
                continue
            후보[이름.lower()] = {"repo": 이름, "stars": 별, "created_at": 저장소.get("created_at", ""),
                               "url": 저장소.get("html_url") or "https://github.com/%s" % 이름,
                               "description": str(저장소.get("description") or "")[:160]}
    for 키 in sorted(후보, key=lambda 이름: -후보[이름]["stars"]):
        본.add(키)
        if not 첫실행:
            결과["new"].append(후보[키])
    return 결과, 첫실행, 본


# ---------------------------------------------------------------- 재수집·색인 갱신

def 근거_갱신(근거, 현재, 별):
    근거 = str(근거 or "")
    새_확인 = 현재.astimezone(KST).strftime("%Y-%m-%d %H:%M KST 확인")
    if re.search(확인_패턴, 근거):
        근거 = re.sub(확인_패턴, 새_확인, 근거, count=1)
    else:
        근거 = (근거 + " · " if 근거 and 근거 != "미기재" else "") + 새_확인
    if isinstance(별, int):
        근거 = re.sub(r"별 [\d,]+", "별 {:,}".format(별), 근거, count=1)
    근거 = 근거.replace(옛_재수집_표식, "ogithub 재수집")  # OGIT-COMPAT 옛 표식은 새 표식으로 바꾼다
    if "ogithub 재수집" not in 근거:
        근거 += " · ogithub 재수집"
    return 근거


def 셀(값):
    return str(값).replace("|", "/").replace("\n", " ").strip() or "-"


def 매니페스트_항목(색인, 항목_id):
    try:
        기록 = json_파일(os.path.join(색인, "manifest.json"))
        return [값 for 값 in 기록.get("items", []) if isinstance(값, dict) and 값.get("id") == 항목_id]
    except (OSError, ValueError, AttributeError):
        return []


def 색인_갱신(색인, 항목_id, 새_커밋, 태그, 현재, 별, 이전_항목):
    """재수집 뒤 manifest·README 의 커밋·라이선스·확인 시각을 맞춘다.
    fetch_ref.py 는 같은 id 를 다시 받을 때 원본만 재사용하고 이 열들을 갱신하지 않으므로 여기서 한다."""
    매니페스트_경로 = os.path.join(색인, "manifest.json")
    기록 = json_파일(매니페스트_경로)
    항목들 = 기록.get("items") if isinstance(기록, dict) else None
    if not isinstance(항목들, list):
        raise 입력오류("manifest.json items 없음")
    대상 = [값 for 값 in 항목들 if isinstance(값, dict) and 값.get("id") == 항목_id and 값.get("commit") == 새_커밋]
    if not 대상:
        raise 입력오류("재수집 뒤 manifest 에 %s@%s 항목이 없음" % (항목_id, 새_커밋[:12]))
    항목 = 대상[0]
    if 이전_항목 and 항목.get("license") in (None, "", "미확인"):
        항목["license"] = 이전_항목.get("license") or "미확인"
    항목["basis"] = 근거_갱신((이전_항목 or 항목).get("basis"), 현재, 별)
    if 태그:
        항목["ref"] = 태그
    항목["checked_at"] = iso(현재)
    원자적_쓰기(매니페스트_경로, json.dumps(기록, ensure_ascii=False, indent=2) + "\n")

    README_경로 = os.path.join(색인, "README.md")
    try:
        with open(README_경로, encoding="utf-8") as 파일:
            줄들 = 파일.read().splitlines()
    except OSError:
        raise 입력오류("README.md 를 읽을 수 없음: %s" % README_경로)
    새_키 = "%s@%s" % (항목_id, 새_커밋[:12])
    옛_키 = "%s@%s" % (항목_id, str(이전_항목.get("commit", ""))[:12]) if 이전_항목 else ""
    옛_칸 = None
    for 줄 in 줄들:
        일치 = re.match(r"\|\s*`([^`]+)`", 줄)
        if 일치 and 일치.group(1) == 옛_키:
            옛_칸 = 줄.split("|")
    버전 = ("%s %s" % (태그, 새_커밋)) if 태그 else 새_커밋
    이름 = re.sub(r"\.git$", "", str(항목.get("url", "")).rstrip("/").rsplit("/", 1)[-1]) or 항목_id
    새_칸 = ["", " `%s` %s " % (새_키, 셀(이름)), " %s " % 셀(항목.get("url", "")), " %s " % 셀(항목["license"]),
           " %s " % 셀(항목["basis"]), " %s " % 셀(버전), " analysis/%s.md " % 항목_id, " - ", " 아니오 ", ""]
    if 옛_칸 and len(옛_칸) == len(새_칸):
        # 사람이 채운 열(분석 위치·참조한 부분·삭제 금지)은 이전 행에서 이어받는다
        새_칸[6], 새_칸[7], 새_칸[8] = 옛_칸[6], 옛_칸[7], 옛_칸[8]
    새_줄 = "|".join(새_칸)
    for 번호, 줄 in enumerate(줄들):
        일치 = re.match(r"\|\s*`([^`]+)`", 줄)
        if 일치 and 일치.group(1) == 새_키:
            줄들[번호] = 새_줄
            break
    else:
        마지막 = max((번호 for 번호, 줄 in enumerate(줄들) if 줄.startswith("|")), default=len(줄들) - 1)
        줄들.insert(마지막 + 1, 새_줄)
    원자적_쓰기(README_경로, "\n".join(줄들) + "\n")


def 재수집(루트, 색인, 프로젝트, 갱신, 현재, 별):
    """돌려주는 값: (성공 여부, 메시지)."""
    항목들 = 매니페스트_항목(색인, 갱신["id"])
    이전 = max(항목들, key=lambda 값: str(값.get("acquired_at", ""))) if 항목들 else None
    라이선스 = (이전 or {}).get("license") or "미확인"
    근거 = 근거_갱신((이전 or {}).get("basis"), 현재, 별)
    기본 = [sys.executable, "-I", os.path.join(os.path.dirname(os.path.abspath(__file__)), "fetch_ref.py")]
    지정_명령 = 환경값("OGITHUB_FETCH_CMD", "OGIT_FETCH_CMD")  # OGIT-COMPAT
    명령 = shlex.split(지정_명령) if 지정_명령 else 기본
    명령 = 명령 + ["--project", 루트, "--project-name", 프로젝트, "--id", 갱신["id"], "--url", 갱신["url"],
                 "--license", 라이선스, "--basis", 근거]
    if 갱신["ref"]:
        명령 += ["--ref", 갱신["ref"]]
    try:
        결과 = subprocess.run(명령, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, timeout=900)
    except (OSError, subprocess.TimeoutExpired) as 오류:
        return False, "재수집 실행 실패 %s: %s" % (갱신["id"], 오류)
    if 결과.returncode != 0:
        return False, "재수집 실패 %s rc=%d: %s" % (갱신["id"], 결과.returncode, 결과.stderr.strip()[-300:])
    # 받은 커밋은 fetch_ref 출력(FETCHED id@커밋12자)이 정본이고, 없으면 ls-remote 값을 쓴다
    새_커밋 = 갱신["commit"]
    일치 = re.search(r"FETCHED\s+\S+@([0-9a-f]{12})", 결과.stdout)
    if 일치:
        후보 = [str(값.get("commit", "")) for 값 in 매니페스트_항목(색인, 갱신["id"])
              if str(값.get("commit", "")).startswith(일치.group(1))]
        if 후보:
            새_커밋 = 후보[0]
    try:
        색인_갱신(색인, 갱신["id"], 새_커밋, 갱신["ref"], 현재, 별, 이전)
    except (입력오류, OSError, ValueError) as 오류:
        return False, "색인 갱신 실패 %s: %s" % (갱신["id"], 오류)
    return True, "%s@%s" % (갱신["id"], 새_커밋[:12])


# ---------------------------------------------------------------- 실행

def 검사(인자):
    현재 = 지금(인자.now)
    루트 = 프로젝트_루트(인자.project)
    색인 = os.path.join(루트, 인자.ref_root)
    try:
        매니페스트 = json_파일(os.path.join(색인, "manifest.json"))
    except (OSError, ValueError):
        매니페스트 = {}
    프로젝트 = 프로젝트_이름(루트, 매니페스트, 인자.project_name)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", 프로젝트):
        raise 입력오류("프로젝트 이름 형식 오류: %s" % 프로젝트)
    추적_경로 = 인자.watch or os.path.join(색인, "ogithub_watch.json")
    if not 인자.watch and not os.path.exists(추적_경로) and os.path.exists(os.path.join(색인, 옛_추적_파일)):  # OGIT-COMPAT
        추적_경로 = os.path.join(색인, 옛_추적_파일)  # OGIT-COMPAT
    저장소들, 탐색 = 추적_목록(추적_경로)
    지정_폴더 = 환경값("OGITHUB_HOME", "OGIT_HOME")  # OGIT-COMPAT
    상태_폴더 = os.path.expanduser(지정_폴더 or 상태_폴더_기본)
    상태_경로 = os.path.join(상태_폴더, "state-%s.json" % 프로젝트.lower())
    # 쓰기는 항상 상태_경로(새 위치)만 한다. 옛 파일은 읽기만 하고 지우지 않는다
    읽기_경로 = 상태_경로
    옛_상태_경로 = os.path.join(os.path.expanduser(옛_상태_폴더), "state-%s.json" % 프로젝트.lower())  # OGIT-COMPAT
    if not 지정_폴더 and not os.path.exists(상태_경로) and os.path.exists(옛_상태_경로):  # OGIT-COMPAT
        읽기_경로 = 옛_상태_경로  # OGIT-COMPAT
    상태, 경고 = 상태_읽기(읽기_경로)
    for 줄 in 경고:
        print(줄, file=sys.stderr)

    결과, 첫실행, 본 = 판정(저장소들, 탐색, 상태, 현재, 조회기())

    적용 = []
    if 인자.apply:
        for 갱신 in 결과["updates"]:
            별 = (결과["repos"].get(갱신["id"]) or {}).get("stars")
            성공, 메시지 = 재수집(루트, 색인, 프로젝트, 갱신, 현재, 별)
            if 성공:
                적용.append(메시지)
            else:
                결과["partial"].append(메시지)

    부분 = bool(결과["partial"])
    상태값 = "PARTIAL" if 부분 else ("BASELINE" if 첫실행 else "OK")

    # 확인만 하는 실행은 상태를 쓰지 않는다(먼저 확인 → 다음에 --apply 해도 UPDATED 가 남는다).
    # 첫 실행(BASELINE)과 --apply 실행만 기록하며, --apply 는 재수집에 성공한 저장소만 새 값으로 반영한다
    기록 = not 부분 and (첫실행 or 인자.apply)
    if 기록:
        성공_id = set(값.split("@", 1)[0] for 값 in 적용)
        옛_저장소 = (상태 or {}).get("repos", {})
        저장소_값 = {}
        for 항목_id, 값 in 결과["repos"].items():
            갱신됨 = any(갱신["id"] == 항목_id for 갱신 in 결과["updates"])
            if 갱신됨 and 항목_id not in 성공_id and 항목_id in 옛_저장소:
                저장소_값[항목_id] = 옛_저장소[항목_id]
            else:
                저장소_값[항목_id] = 값
        새_상태 = {"schema": 1, "project": 프로젝트, "last_run": iso(현재), "repos": 저장소_값,
                 "seen": sorted(본)[-본_목록_상한:]}
        원자적_쓰기(상태_경로, json.dumps(새_상태, ensure_ascii=False, indent=2) + "\n")

    if 인자.json:
        print(json.dumps({"status": 상태값, "state": 상태_경로, "last_run_updated": 기록,
                          "updates": 결과["updates"], "new": 결과["new"], "same": 결과["same"],
                          "baseline": [값["id"] for 값 in 결과["baseline"]], "partial": 결과["partial"],
                          "applied": 적용}, ensure_ascii=False, indent=2))
    else:
        for 값 in 결과["baseline"]:
            print("BASELINE %s tag=%s head=%s" % (값["id"], 값["tag"] or "-", (값["head"] or "-")[:12]))
        for 값 in 결과["updates"]:
            print("UPDATED %s %s %s -> %s" % (값["id"], 값["kind"], (값["old"] or "-")[:40], (값["new"] or "-")[:40]))
        for 값 in 결과["same"]:
            print("SAME %s" % 값)
        for 값 in 결과["new"]:
            print("NEW %s stars=%d created=%s %s" % (값["repo"], 값["stars"], 값["created_at"], 값["url"]))
        for 값 in 적용:
            print("APPLIED %s" % 값)
        for 값 in 결과["partial"]:
            print("PARTIAL %s" % 값)
        if 첫실행 and not 부분:
            print("갱신 없음(기준선)")
        print("OGITHUB %s updated=%d new=%d same=%d applied=%d last_run=%s" % (
            상태값, len(결과["updates"]), len(결과["new"]), len(결과["same"]), len(적용),
            "갱신" if 기록 else "유지"))
    return RC_부분 if 부분 else RC_정상


def 파서():
    p = argparse.ArgumentParser(prog="ogithub.py", description="추적 오픈소스의 직전 실행 이후 버전업·신규 주목 저장소 판정",
                                epilog=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    하위 = p.add_subparsers(dest="명령")
    c = 하위.add_parser("check", help="판정을 실행한다")
    c.add_argument("--project", help="프로젝트 루트(기본: 현재 위치의 git 최상위)")
    c.add_argument("--project-name", help="상태 파일·원본 층 프로젝트 이름(기본: manifest 의 project)")
    c.add_argument("--ref-root", default="ref", help="색인 위치(프로젝트 기준 상대경로, 기본 ref)")
    c.add_argument("--watch", help="추적 목록 파일(기본: <ref_root>/ogithub_watch.json)")
    c.add_argument("--apply", action="store_true", help="버전업 항목을 fetch_ref.py 로 다시 수집하고 색인을 맞춘다")
    c.add_argument("--json", action="store_true", help="결과를 JSON 으로 출력")
    c.add_argument("--now", help="현재 시각 대체(ISO, 시험용)")
    return p


def main():
    p = 파서()
    인자 = p.parse_args()
    if 인자.명령 != "check":
        p.print_help()
        return RC_인자
    if os.path.isabs(인자.ref_root) or ".." in 인자.ref_root.split("/"):
        print("오류: --ref-root 는 프로젝트 안 상대경로여야 한다", file=sys.stderr)
        return RC_인자
    try:
        return 검사(인자)
    except 입력오류 as 오류:
        print("오류: %s" % 오류, file=sys.stderr)
        return RC_인자


if __name__ == "__main__":
    sys.exit(main())
