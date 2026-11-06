# oguard 매뉴얼 린트 — 필수 6절 누락과 `## 검증` 절의 실행 주체 모순(호출자 vs codex)을 검사한다
# 사용: python3 -I -B manual_lint.py <매뉴얼.md> [...]   (끝 줄 `합계 FAIL=n`, 하나라도 실패하면 rc=1)
import re
import sys

REQUIRED = ("목적", "대상 파일", "변경 내용", "검증", "되돌리기", "금지")

NEG = re.compile(r"않|말고|금지|하지 ?말|제외|안 ?한다|아니다|못한다")
RUN = re.compile(r"실행|돌린|돌려|수행")
CODEX = re.compile(r"codex\s*(?:가|는|도|만|에서)", re.I)
CALLER = re.compile(r"(?:호출자|에이전트|메인|리드|team-lead|팀원)\s*(?:가|는|이|도|만|에서)?")
# codex 가 맡아도 되는 좁은 범위(패치 스크립트·compile(·bash -n·grep) 밖의 검증 대상 어휘
VERIFYISH = re.compile(r"verify|하류|회귀|시험|test_|검증 명령|검증을|검증은", re.I)
RERUN = re.compile(r"다시|재실행|별개|독립")  # 호출자의 독립 재검증은 실행 주체 선언이 아니다
ALLOWED_ONLY = re.compile(r"패치 스크립트|compile\(|bash -n|grep")
# "codex 가 실행할 검증 명령은 아래 N개가 전부다"·"codex 가 실행하는 확인은 다음과 같다" — 범위 한정·목록 도입 문장. 구체 검증 대상(verify·하류·회귀·test_)이 없을 때만 실행 선언으로 보지 않는다
LIMITED = re.compile(r"전부|아래\s*\d+\s*개|뿐|다음과 같다")
SPECIFIC = re.compile(r"verify|하류|회귀|test_", re.I)


def sections(text):
    """`## 제목` 단위로 절 본문을 나눈다. 코드 펜스 안의 `## ` 는 제목으로 보지 않는다."""
    out, cur, fence = {}, None, False
    for line in text.splitlines():
        if line.lstrip().startswith("```"):
            fence = not fence
        m = None if fence else re.match(r"^##\s+(.+?)\s*$", line)
        if m:
            cur = m.group(1)
            out.setdefault(cur, [])
        elif cur is not None:
            out[cur].append(line)
    return {k: "\n".join(v) for k, v in out.items()}


def sentences(body):
    """인라인 코드(`…`)를 가리고 줄·'다.' 단위로 문장을 나눈다(verify.py 의 마침표는 자르지 않는다)."""
    body = re.sub(r"`[^`\n]*`", " ", body)
    out = []
    for line in body.splitlines():
        out.extend(p for p in re.split(r"(?<=다)\.\s*", line) if p.strip())
    return out


def objects(s):
    """문장이 가리키는 검증 대상 키 집합. 대상을 못 찾으면 전체(any)로 본다."""
    k = set()
    if re.search(r"verify", s, re.I):
        k.add("verify")
    if re.search(r"하류|회귀|고정 시험|시험|test_", s):
        k.add("regress")
    return k or {"any"}


def overlap(a, b):
    return "any" in a or "any" in b or bool(a & b)


def verify_actor_errors(body):
    caller, codex, errs = [], [], []
    for s in sentences(body):
        has_codex = CODEX.search(s)
        has_caller = CALLER.search(s)
        run = RUN.search(s)
        neg = NEG.search(s)
        if not run:
            continue
        if has_codex and has_caller and not neg:
            errs.append("한 문장에 호출자와 codex 가 함께 실행 주체로 적혔다: " + s.strip()[:80])
        elif has_codex and neg:
            caller.append((s, {"any"}))  # "codex 는 실행하지 않는다" = 호출자 실행 선언
        elif has_codex and LIMITED.search(s) and not SPECIFIC.search(s):
            continue
        elif has_codex:
            if VERIFYISH.search(s) or not ALLOWED_ONLY.search(s):
                codex.append((s, objects(s)))
        elif has_caller and not neg and not RERUN.search(s):
            caller.append((s, objects(s)))
    for cs, ck in caller:
        for xs, xk in codex:
            if overlap(ck, xk):
                errs.append(
                    "검증 실행 주체 모순: 호출자 실행 문장(%r)과 codex 실행 문장(%r)이 같은 대상을 가리킨다"
                    % (cs.strip()[:50], xs.strip()[:50])
                )
                return errs
    return errs


def lint(path):
    try:
        text = open(path, encoding="utf-8").read()
    except OSError as e:
        return ["읽을 수 없음: %s" % e]
    secs = sections(text)
    errs = ["필수 절 누락: ## %s" % n for n in REQUIRED if n not in secs]
    if "검증" in secs:
        if not secs["검증"].strip():
            errs.append("## 검증 절이 비어 있다")
        else:
            errs.extend(verify_actor_errors(secs["검증"]))
            # py_compile 은 .pyc 를 만들어 codex 의 대상 밖 생성 금지와 충돌한다(L-1486). 금지 문맥(NEG)이 아니면 오류
            for line in secs["검증"].splitlines():
                if "py_compile" in line and not NEG.search(line):
                    errs.append("WARN:## 검증 절에 py_compile 사용(.pyc 생성 충돌, compile( 로 대체): " + line.strip()[:80])
    return errs


def main(argv):
    if not argv:
        print("사용: manual_lint.py <매뉴얼.md> [...]", file=sys.stderr)
        return 2
    fail = 0
    for p in argv:
        allerrs = lint(p)
        errs = [e for e in allerrs if not e.startswith("WARN:")]
        for e in allerrs:
            if e.startswith("WARN:"):
                print("LINT_WARN %s: %s" % (p, e[5:]))  # 경고는 rc 에 영향이 없다
        if errs:
            fail += 1
            for e in errs:
                print("LINT_FAIL %s: %s" % (p, e))
        else:
            print("LINT_OK %s" % p)
    print("합계 FAIL=%d" % fail)
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
