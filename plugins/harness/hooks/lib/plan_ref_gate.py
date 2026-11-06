#!/usr/bin/env python3
# 계획서 '## 정본 참조' 절과 plan/index.json 읽기 기록을 판정하는 정본 참조 게이트 코어
"""plan_ref_gate — 정본 참조 게이트 코어.

사용:
    plan_ref_gate.py check --session-dir <D> --cwd <C>
    출력(stdout, rc 항상 0): {"decision":"pass|warn|block","tier":"O3","reasons":[...],"message":"..."}

판정 규칙:
    - 프로젝트 루트 = cwd 에서 위로 .claude/ 또는 .git 이 있는 첫 디렉터리, 없으면 cwd.
    - plan root = <루트>/.claude/docs_gate.json 의 canon.plan_root > "plan".
      plan root 디렉터리가 없으면 통과(정본 체계 미도입 프로젝트).
      plan root 는 있는데 index.json 이 없으면 경고만 한다(미초기화).
    - 계획서 = plans/oplan_<conv_id>.md 우선, 없으면 이름에 review 가 없는 plans/oplan_*.md 중 최신.
      사이클 시작(pipeline_start_time)보다 오래된 계획서는 없는 것으로 본다.
    - 위반: '## 정본 참조' 절 없음 / '- 색인:' 에 <plan_root>/index.json 인용 없음 /
      '- 관련:' 경로 부재(첫 ' — ' 앞만 경로로 본다. 뒤는 이유다) / 관련 0개인데 '- 관련 문서 없음: 사유' 10자 미만 /
      plan_reads.log 에 사이클 시작 이후 index.json 읽기 기록 없음.
    - '- 반영 예정: 해당 없음(사유)' 는 사유가 앞뒤 공백 제외 10자 이상일 때만 인정한다
      (미달이면 파서가 반영예정_해당없음=None, 즉 줄 없음과 같게 돌려준다).
      값이 '해당 없음' 으로 시작하면 뒤따르는 백틱은 사유이지 경로가 아니다.
    - 인정한 '관련 문서 없음'·'해당 없음' 은 logs/plan_ref_gate.log 에 사유와 함께 1줄씩 남긴다.
    - tier: O3~O5 → block, O2 → warn, 그 외 → pass.
    - [F-PLAN-REF-WT 2026-11-05] 경로 기준 루트는 cwd 루트 하나가 아니라 '같은 git 저장소의 주 작업트리 + 모든 worktree' 후보다.
      색인 인용·'- 관련:' 실재·읽기 기록은 후보 중 하나에서 맞으면 인정한다(원본에서 읽은 팀원 기록, 낡은 worktree cwd 교착 해소).
      plan root 이름(canon.plan_root)은 cwd 루트 설정을 쓴다. 다른 저장소·사이클 시작 이전 기록·다른 세션 기록은 종전대로 인정하지 않는다.

공개 함수(docs_gate.py 가 지연 import 한다):
    최신_계획서(session_dir) -> str|None
    정본참조_파싱(본문) -> dict|None
    반영예정_목록(본문) -> list[str]
    반영예정_해당없음(본문) -> bool
"""

import glob
import json
import os
import re
import sys
import time

태그 = "F-PLAN-REF"
절_제목 = re.compile(r"^##\s+정본\s*참조\s*$")
다음_절 = re.compile(r"^#{1,2}\s+\S")
항목_줄 = re.compile(r"^\s*[-*]\s*([^:：]+?)\s*[:：]\s*(.*)$")
백틱 = re.compile(r"`([^`]+)`")
사유_최소 = 10

# 항목 이름 → dict 키 (공백 차이 무시)
항목_키 = {
    "색인": "색인",
    "관련": "관련",
    "시험자산": "시험자산",
    "과거산출물": "과거산출물",
    "관련문서없음": "관련없음사유",
    "반영예정": "반영예정",
}


# ---------- 공개 함수 ----------

def 정본참조_파싱(본문):
    """'## 정본 참조' 절을 dict 로 돌려준다. 절이 없으면 None."""
    if not isinstance(본문, str):
        return None
    줄들 = 본문.splitlines()
    시작 = None
    in_code = False
    for i, 줄 in enumerate(줄들):
        if 줄.strip().startswith("```"):
            in_code = not in_code
            continue
        if not in_code and 절_제목.match(줄.strip()):
            시작 = i + 1
            break
    if 시작 is None:
        return None
    결과 = {"색인": [], "관련": [], "시험자산": [], "과거산출물": [],
            "관련없음사유": None, "반영예정": [], "반영예정_해당없음": None}
    직전_키 = None
    for 줄 in 줄들[시작:]:
        if 다음_절.match(줄):
            break
        m = 항목_줄.match(줄)
        if not m:
            # 들여쓴 이어짐 줄은 직전 반영 예정에 붙인다(여러 줄 허용)
            if 직전_키 == "반영예정" and 줄.startswith((" ", "\t")) and 줄.strip():
                결과["반영예정"].extend(_경로들(줄))
            continue
        이름 = re.sub(r"\s+", "", m.group(1))
        값 = m.group(2).strip()
        키 = 항목_키.get(이름)
        직전_키 = 키
        if 키 is None:
            continue
        if 키 == "관련없음사유":
            결과[키] = 값
        elif 키 == "반영예정":
            경로 = [] if _해당없음_시작(값) else _경로들(값)
            # '해당 없음' 은 사유가 앞뒤 공백 제외 10자 이상일 때만 인정한다(미달이면 줄 없음과 같게 None)
            if not 경로 and 해당없음_사유(값) is not None:
                결과["반영예정_해당없음"] = 값
            결과["반영예정"].extend(경로)
        elif 키 in ("색인", "관련", "시험자산"):
            결과[키].extend(_경로들(_설명_앞(값) if 키 == "관련" else 값, 첫토큰_허용=True))
        else:
            결과[키].append(값)
    return 결과


def 반영예정_목록(본문):
    """반영 예정 줄의 백틱 경로 목록. '해당 없음' 이거나 절이 없으면 []."""
    p = 정본참조_파싱(본문)
    return list(p["반영예정"]) if p else []


def 반영예정_해당없음(본문):
    p = 정본참조_파싱(본문)
    return bool(p and p["반영예정_해당없음"] and not p["반영예정"])


def 최신_계획서(session_dir):
    plans = os.path.join(session_dir, "plans")
    try:
        with open(os.path.join(session_dir, "conv_id"), encoding="utf-8") as f:
            cid = f.readline().strip()
    except OSError:
        cid = ""
    if cid and re.fullmatch(r"[A-Za-z0-9_.-]+", cid):
        후보 = os.path.join(plans, "oplan_%s.md" % cid)
        if os.path.isfile(후보):
            return 후보
    목록 = [p for p in glob.glob(os.path.join(plans, "oplan_*.md"))
            if "review" not in os.path.basename(p).lower() and os.path.isfile(p)]
    if not 목록:
        return None
    return max(목록, key=lambda p: os.path.getmtime(p))


# ---------- 내부 ----------

def 해당없음_사유(값):
    """'해당 없음(사유)' 값에서 사유를 꺼낸다. '해당 없음' 이 없거나 사유가 앞뒤 공백 제외 10자 미만이면 None."""
    if not isinstance(값, str):
        return None
    v = 값.replace("해당없음", "해당 없음")
    if "해당 없음" not in v:
        return None
    s = v.replace("해당 없음", "", 1).strip().strip("()（）[]-—–:：,.· ").strip()
    return s if len(s) >= 사유_최소 else None


def _해당없음_시작(값):
    """값이 '해당 없음' 으로 시작하는가. 이때 뒤따르는 백틱은 경로가 아니라 사유다."""
    return 값.replace("해당없음", "해당 없음").startswith("해당 없음")


def _설명_앞(값):
    """'- 관련:' 값에서 첫 ' — ' 앞만 돌려준다. 그 뒤는 이유이므로 경로로 읽지 않는다."""
    return 값.split(" — ", 1)[0]


def _경로들(값, 첫토큰_허용=False):
    경로 = [s.strip() for s in 백틱.findall(값) if s.strip()]
    if not 경로 and 첫토큰_허용 and 값:
        첫 = 값.split()[0].strip("\"'<>,")
        if "/" in 첫 or "." in 첫:
            경로 = [첫]
    return 경로


def 사이클_시작(session_dir):
    """pipeline_start_time(세션 루트 또는 evidence/) — 숫자면 epoch, 아니면 mtime. 없으면 None."""
    for f in (os.path.join(session_dir, "pipeline_start_time"),
              os.path.join(session_dir, "evidence", "pipeline_start_time")):
        if not os.path.isfile(f):
            continue
        try:
            with open(f, encoding="utf-8", errors="replace") as h:
                c = h.readline().strip()
            return int(c) if c.isdigit() else int(os.path.getmtime(f))
        except (OSError, ValueError):
            return None
    return None


def 프로젝트_루트(cwd):
    """cwd 에서 위로 올라가며 .claude/ 또는 .git 이 있는 첫 디렉터리(read_log hook 과 같은 규칙), 없으면 cwd."""
    if not cwd or not os.path.isdir(cwd):
        return None
    d = os.path.realpath(cwd)
    while True:
        if os.path.isdir(os.path.join(d, ".claude")) or os.path.exists(os.path.join(d, ".git")):
            return d
        부모 = os.path.dirname(d)
        if 부모 == d:
            return os.path.realpath(cwd)
        d = 부모


def 루트_후보(루트):
    """[F-PLAN-REF-WT] 경로 판정 기준 루트 후보 — cwd 루트 + 같은 git 저장소의 주 작업트리와 모든 worktree.
    <루트>/.git(디렉터리 또는 'gitdir:' 파일)·commondir·<common>/worktrees/*/gitdir 파일만 읽는다(git 실행 없음, 최대 64개).
    판정할 수 없으면 [루트] 만 돌려준다(종전과 같다)."""
    후보 = [루트]
    try:
        g = os.path.join(루트, ".git")
        common = None
        if os.path.isdir(g):
            common = g
        elif os.path.isfile(g):
            with open(g, encoding="utf-8", errors="replace") as f:
                첫 = f.readline().strip()
            if 첫.startswith("gitdir:"):
                gd = 첫[len("gitdir:"):].strip()
                gd = os.path.realpath(gd if os.path.isabs(gd) else os.path.join(루트, gd))
                cdf = os.path.join(gd, "commondir")
                if os.path.isfile(cdf):
                    with open(cdf, encoding="utf-8", errors="replace") as f:
                        c = f.readline().strip()
                    common = os.path.realpath(c if os.path.isabs(c) else os.path.join(gd, c))
                else:
                    common = os.path.realpath(os.path.join(gd, "..", ".."))
        if common and os.path.isdir(common):
            if os.path.basename(common) == ".git":
                후보.append(os.path.dirname(common))
            for w in sorted(glob.glob(os.path.join(common, "worktrees", "*", "gitdir")))[:64]:
                try:
                    with open(w, encoding="utf-8", errors="replace") as f:
                        p = f.readline().strip()
                except OSError:
                    continue
                d = os.path.dirname(os.path.realpath(p)) if p else ""
                if d and os.path.isdir(d):
                    후보.append(d)
    except OSError:
        pass
    결과 = []
    for c in 후보:
        r = os.path.realpath(c)
        if r not in 결과:
            결과.append(r)
    return 결과


def plan_root_이름(루트):
    try:
        with open(os.path.join(루트, ".claude", "docs_gate.json"), encoding="utf-8-sig") as f:
            canon = json.load(f).get("canon", {})
        v = canon.get("plan_root") if isinstance(canon, dict) else None
        if isinstance(v, str) and v.strip():
            return v.strip().rstrip("/")
    except (OSError, ValueError, AttributeError):
        pass
    return "plan"


def _절대(루트, p):
    p = os.path.expanduser(p)
    return os.path.realpath(p if os.path.isabs(p) else os.path.join(루트, p))


def 읽기_기록_있음(session_dir, index_절대, pst):
    try:
        with open(os.path.join(session_dir, "plan_reads.log"), encoding="utf-8", errors="replace") as f:
            for 줄 in f:
                칸 = 줄.rstrip("\n").split("\t")
                if len(칸) < 2 or not 칸[0].strip().isdigit():
                    continue
                if pst is not None and int(칸[0]) < pst:
                    continue
                대상 = {index_절대} if isinstance(index_절대, str) else index_절대   # [F-PLAN-REF-WT] 후보 집합 허용
                if os.path.realpath(칸[1].strip()) in 대상:
                    return True
    except OSError:
        pass
    return False


def 등급(session_dir):
    try:
        with open(os.path.join(session_dir, "classification"), encoding="utf-8") as f:
            c = f.readline().strip().upper()
    except OSError:
        c = ""
    if c in ("O3", "O4", "O5"):
        return c, "block"
    if c == "O2":
        return c, "warn"
    return c or "없음", "pass"


def 판정(session_dir, cwd):
    tier, 강도 = 등급(session_dir)
    결과 = {"decision": "pass", "tier": tier, "reasons": [], "message": "", "notes": []}
    if 강도 == "pass":
        결과["message"] = "classification=%s — 정본 참조 검사 대상 아님" % tier
        return 결과
    루트 = 프로젝트_루트(cwd)
    if not 루트:
        결과["message"] = "cwd 판정 불가 — 통과"
        return 결과
    pr_이름 = plan_root_이름(루트)
    pr = _절대(루트, pr_이름)
    if not os.path.isdir(pr):
        결과["message"] = "plan root(%s) 없음 — 정본 체계 미도입 프로젝트라 통과" % pr_이름
        return 결과
    index_상대 = "%s/index.json" % pr_이름
    index_절대 = os.path.join(pr, "index.json")
    if not os.path.isfile(index_절대):
        결과["decision"] = "warn"
        결과["reasons"].append("%s 이 없습니다(정본 미초기화). plan_init.py --project %s 로 골격을 만드세요." % (index_상대, 루트))
        결과["message"] = _문구(결과, index_상대, pr_이름)
        return 결과

    # [F-PLAN-REF-WT] 같은 저장소의 주 작업트리·worktree 를 경로 기준 후보로 쓴다(plan root 이름은 cwd 루트 설정)
    후보들 = 루트_후보(루트)
    index_후보 = {os.path.realpath(index_절대)}
    for c in 후보들:
        index_후보.add(os.path.join(_절대(c, pr_이름), "index.json"))
    pst = 사이클_시작(session_dir)
    계획서 = 최신_계획서(session_dir)
    if 계획서 and pst is not None and int(os.path.getmtime(계획서)) < pst:
        계획서 = None
    사유 = 결과["reasons"]
    if not 계획서:
        사유.append("이번 사이클 계획서(plans/oplan_<대화ID>.md)가 없습니다.")
    else:
        try:
            with open(계획서, encoding="utf-8-sig", errors="replace") as f:
                본문 = f.read()
        except OSError:
            본문 = ""
        p = 정본참조_파싱(본문)
        if p is None:
            사유.append("계획서 %s 에 '## 정본 참조' 절이 없습니다." % os.path.basename(계획서))
        else:
            if not any(_절대(c, x) in index_후보 for c in 후보들 for x in p["색인"]):
                사유.append("'- 색인:' 줄에 `%s` 인용이 없습니다." % index_상대)
            없는 = [x for x in p["관련"] if not any(os.path.exists(_절대(c, x)) for c in 후보들)]
            for x in 없는:
                사유.append("'- 관련:' 경로 `%s` 가 실재하지 않습니다." % x)
            if not p["관련"]:
                s = (p["관련없음사유"] or "").strip()
                if len(s) < 사유_최소:
                    사유.append("관련 문서가 0개인데 '- 관련 문서 없음: <사유 %d자 이상>' 이 없습니다." % 사유_최소)
                else:
                    결과["notes"].append("RELATED_NONE_ACCEPTED 사유=%s" % s)
            if p["반영예정_해당없음"] and not p["반영예정"]:
                결과["notes"].append("APPLY_NONE_ACCEPTED 사유=%s" % 해당없음_사유(p["반영예정_해당없음"]))
    if not 읽기_기록_있음(session_dir, index_후보, pst):
        사유.append("이번 사이클에 %s 를 읽은 기록(plan_reads.log)이 없습니다." % index_상대)

    if 사유:
        결과["decision"] = 강도
    결과["message"] = _문구(결과, index_상대, pr_이름)
    return 결과


def _문구(결과, index_상대, pr_이름):
    if 결과["decision"] == "pass":
        return "정본 참조 확인 완료"
    머리 = "⛔ [%s] %s 의 DEV 전이 차단" % (태그, 결과["tier"]) if 결과["decision"] == "block" \
        else "⚠️ [%s] %s 정본 참조 경고" % (태그, 결과["tier"])
    해소 = (
        " 해소 절차: (1) mcp__oio__file_read(또는 Read)로 `%s` 를 1회 열어 읽기 기록을 남긴다"
        "(셸 cat 은 기록되지 않는다). (2) 계획서 plans/oplan_<대화ID>.md 에 '## 정본 참조' 절을 쓴다 — "
        "'- 색인: `%s`', '- 관련: `<%s/실재 문서>` — 이유'(관련이 없으면 '- 관련 문서 없음: <사유 10자 이상>'), "
        "'- 반영 예정: `<경로>` | 해당 없음(사유)'. (3) state=DEV 전이를 다시 시도한다."
        " 비상 시 hooks/DISABLE_PLAN_REF_GATE 파일을 만들면 120분간 통과한다(사용자 판단)."
    ) % (index_상대, index_상대, pr_이름)
    return "%s — %s%s" % (머리, " ".join(결과["reasons"]), 해소)


def 로그(session_dir, 결과):
    try:
        d = os.path.join(session_dir, "logs")
        os.makedirs(d, exist_ok=True)
        시각 = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        with open(os.path.join(d, "plan_ref_gate.log"), "a", encoding="utf-8") as f:
            f.write("%s %s tier=%s %s\n" % (시각, 결과["decision"].upper(), 결과["tier"],
                                            " | ".join(결과["reasons"]) or "-"))
            # 인정한 '관련 문서 없음'·'반영 예정: 해당 없음' 은 사유와 함께 1줄씩 남긴다
            for n in 결과.get("notes") or []:
                f.write("%s %s tier=%s\n" % (시각, n.replace("\n", " "), 결과["tier"]))
    except OSError:
        pass


def main(argv):
    인자 = {"--session-dir": "", "--cwd": ""}
    if not argv or argv[0] != "check":
        print(json.dumps({"decision": "pass", "tier": "", "reasons": [],
                          "message": "사용법: plan_ref_gate.py check --session-dir D --cwd C"}, ensure_ascii=False))
        return 0
    i = 1
    while i < len(argv):
        if argv[i] in 인자 and i + 1 < len(argv):
            인자[argv[i]] = argv[i + 1]
            i += 2
        else:
            i += 1
    sd = 인자["--session-dir"]
    try:
        if not sd or not os.path.isdir(sd):
            결과 = {"decision": "pass", "tier": "", "reasons": [], "message": "세션 디렉터리 없음 — 통과"}
        else:
            결과 = 판정(sd, 인자["--cwd"] or os.getcwd())
            로그(sd, 결과)
    except Exception as e:  # 판정 불가는 fail-open
        결과 = {"decision": "pass", "tier": "", "reasons": [], "message": "판정 오류로 통과: %s" % e}
    print(json.dumps(결과, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
