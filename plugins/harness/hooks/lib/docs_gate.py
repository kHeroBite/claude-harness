#!/usr/bin/env python3
# 이번 사이클 변경 파일 대비 HISTORY/DATABASE/PROJECT 문서 반영 여부를 판정하는 문서 갱신 게이트 코어
"""PreToolUse_docs_update_gate.sh 가 호출하는 판정 코어.

사용: docs_gate.py check --session-dir <D> --cwd <C> --phase finish|idle
출력: stdout 한 줄 JSON {"decision":"pass|warn|block","messages":[...],"code":[...],"schema":[...],"structural":[...]}
종료 코드: 항상 0 (판정 불가는 pass + 경고 — fail-open)

판정 규칙 (계획서 §3.2~§3.6):
  - 변경 집합 = git diff --name-status -M <base> (커밋분+미커밋분) ∪ 사이클 시작 이후 생긴 미추적 파일
  - base = rollback_hash(HEAD 조상일 때) → 사이클 시작 시각 이전 마지막 커밋 → 없으면 판정 불가
  - 코드 변경 ∧ HISTORY 미반영 → mode_history(기본 block)
  - 스키마 변경 ∧ DATABASE 미반영 → mode_database(기본 warn)
  - 파일 신설·삭제·이동 ∧ PROJECT 미반영 → mode_project(기본 warn)
  - plan root(<루트>/<canon.plan_root|plan>) 폴더와 그 index.json 이 모두 있을 때만 PLAN 판정(lib/canon_root.py plan_active,
    canon_root 가 없거나 실패하면 종전대로 폴더만 본다. plan_root 절대경로·'..' 는 거부해 PLAN 판정을 건너뛴다)
    (mode_plan, 기본 tier = finish(O3~O5) 차단·idle(O1/O2) 경고):
      (1) 이번 사이클 계획서 plans/oplan_*.md 의 `## 정본 참조` → `- 반영 예정:` 에 적힌 경로가 변경 집합에 없음 → 경로별 위반
      (2) 반영 예정 줄이 없는데 코드·구조 변경이 있고 plan root 하위 변경 0 → 위반
      `반영 예정: 해당 없음(사유)` 은 정상 경로(위반 아님, 사유 10자 이상일 때만 — 미달은 줄 없음과 동일). 사유 키 `PLAN:`.
  - 사유 파일 session-env/<UUID>/docs_update_waiver 의 `KEY: 사유`(10자+, 사이클 시작 이후 mtime)는 해당 위반 해제
  - 사이클 시작 시각 < enforce_after_epoch 이면 block 을 warn 으로 강등
"""
import fnmatch
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CONFIG_PATH = os.path.join(HERE, "docs_gate_config.json")

기본_설정 = {
    "mode_history": "block",
    "mode_database": "warn",
    "mode_project": "warn",
    "mode_plan": "tier",
    "enforce_after_epoch": 0,
}
기본_정본 = {"plan_root": "plan", "test_root": "test", "tools_root": "tools"}
사유_키 = ("HISTORY", "DATABASE", "PROJECT", "PLAN")

기본_무시_glob = [
    "**/logs/**", "**/__pycache__/**", "**/__pycache__", "*.pyc", "**/bin/**", "**/obj/**",
    "**/node_modules/**", ".claude/hooks/candidates/**", ".claude/hooks/backup/**",
    "**/_tmp*/**", "INFRA.md",
]
코드_확장자 = {
    ".cs", ".py", ".sh", ".ps1", ".ts", ".tsx", ".js", ".jsx", ".java", ".kt", ".go",
    ".rs", ".c", ".cpp", ".h", ".sql", ".xaml", ".razor", ".vue", ".css", ".html",
    ".csproj", ".sln",
}
기본_스키마_glob = ["*.sql", "**/migrations/**", "**/Migrations/**", "**/*Migration*"]
기본_문서 = {"history": "HISTORY.md", "database": "DATABASE.md", "project": "PROJECT.md"}
GIT_TIMEOUT = 3
사유_최소_길이 = 10
목록_표시_상한 = 10


def glob_일치(경로, 패턴):
    """fnmatch 기반 glob 판정. '**/' 접두는 루트 직속도 포함한다."""
    if fnmatch.fnmatch(경로, 패턴):
        return True
    if 패턴.startswith("**/") and fnmatch.fnmatch(경로, 패턴[3:]):
        return True
    return False


def 아무거나_일치(경로, 패턴들):
    return any(glob_일치(경로, p) for p in 패턴들)


def git(root, *args):
    """git 명령 실행. 실패·시간 초과 시 None."""
    try:
        r = subprocess.run(
            ["git", "-C", root, "-c", "core.quotepath=false"] + list(args),
            capture_output=True, timeout=GIT_TIMEOUT,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0:
        return None
    return r.stdout.decode("utf-8", "replace")


def 설정_로드(경고):
    설정 = dict(기본_설정)
    경로 = os.environ.get("DOCS_GATE_CONFIG") or DEFAULT_CONFIG_PATH
    try:
        with open(경로, encoding="utf-8") as f:
            d = json.load(f)
        if isinstance(d, dict):
            for k in 기본_설정:
                if k in d:
                    설정[k] = d[k]
    except FileNotFoundError:
        경고.append("게이트 설정 파일이 없어 기본값으로 판정합니다: " + 경로)
    except (OSError, ValueError) as e:
        경고.append("게이트 설정 파일 파싱 실패 — 기본값으로 판정합니다: %s (%s)" % (경로, e))
    for k in ("mode_history", "mode_database", "mode_project"):
        if 설정[k] not in ("block", "warn", "off"):
            설정[k] = 기본_설정[k]
    # mode_plan 은 tier(finish=O3~O5 차단, idle=O1/O2 경고)도 허용한다
    if 설정["mode_plan"] not in ("block", "warn", "off", "tier"):
        설정["mode_plan"] = 기본_설정["mode_plan"]
    try:
        설정["enforce_after_epoch"] = int(설정["enforce_after_epoch"])
    except (TypeError, ValueError):
        설정["enforce_after_epoch"] = 0
    return 설정


def 프로젝트_설정_로드(root, 경고):
    """<루트>/.claude/docs_gate.json — 배열은 기본값에 추가, enabled:false 면 전체 통과."""
    p = {"enabled": True, "code_globs": [], "schema_globs": [], "ignore_globs": [], "docs": dict(기본_문서),
         "canon": dict(기본_정본)}
    경로 = os.path.join(root, ".claude", "docs_gate.json")
    if not os.path.isfile(경로):
        return p
    try:
        with open(경로, encoding="utf-8") as f:
            d = json.load(f)
        if not isinstance(d, dict):
            raise ValueError("객체가 아님")
    except (OSError, ValueError) as e:
        경고.append("프로젝트 설정 .claude/docs_gate.json 파싱 실패 — 덮어쓰기를 무시합니다 (%s)" % e)
        return p
    if d.get("enabled") is False:
        p["enabled"] = False
    for k in ("code_globs", "schema_globs", "ignore_globs"):
        v = d.get(k)
        if isinstance(v, list):
            p[k] = [str(x) for x in v if isinstance(x, str)]
    docs = d.get("docs")
    if isinstance(docs, dict):
        for k in 기본_문서:
            if isinstance(docs.get(k), str) and docs[k].strip():
                p["docs"][k] = docs[k].strip()
    canon = d.get("canon")
    if isinstance(canon, dict):
        for k in 기본_정본:
            v = canon.get(k)
            if isinstance(v, str) and v.strip() and not os.path.isabs(v.strip()) and ".." not in v.split("/"):
                p["canon"][k] = v.strip().strip("/")
    return p


def 사이클_시작_시각(session_dir):
    for 이름 in ("pipeline_start_time", os.path.join("evidence", "pipeline_start_time")):
        f = os.path.join(session_dir, 이름)
        if not os.path.isfile(f):
            continue
        try:
            with open(f, encoding="utf-8") as fh:
                c = fh.readline().strip()
            if c.isdigit():
                return int(c)
            return int(os.stat(f).st_mtime)
        except OSError:
            continue
    return None


def 기준_커밋(root, session_dir, pst):
    rh = os.path.join(session_dir, "rollback_hash")
    if os.path.isfile(rh):
        try:
            with open(rh, encoding="utf-8") as fh:
                h = fh.readline().strip()
        except OSError:
            h = ""
        if h and git(root, "cat-file", "-e", h + "^{commit}") is not None \
                and git(root, "merge-base", "--is-ancestor", h, "HEAD") is not None:
            return h, "rollback_hash"
    out = git(root, "rev-list", "-1", "--before=@%d" % pst, "HEAD")
    if out and out.strip():
        return out.strip(), "time"
    return None, ""


def 변경_집합(root, base, pst):
    """[(상태문자, 경로)] — R 은 새 경로, 미추적은 A."""
    out = git(root, "diff", "--name-status", "-z", "-M", base)
    if out is None:
        return None
    toks = out.split("\0")
    결과 = []
    i = 0
    while i < len(toks):
        st = toks[i]
        if not st:
            i += 1
            continue
        c = st[0]
        if c in ("R", "C"):
            if i + 2 >= len(toks):
                break
            결과.append((c, toks[i + 2]))
            i += 3
        else:
            if i + 1 >= len(toks):
                break
            결과.append((c, toks[i + 1]))
            i += 2
    unt = git(root, "ls-files", "-o", "--exclude-standard", "-z")
    if unt:
        for p in unt.split("\0"):
            if not p:
                continue
            try:
                if os.stat(os.path.join(root, p)).st_mtime >= pst:
                    결과.append(("A", p))
            except OSError:
                continue
    return 결과


def 분류(변경, 프로젝트):
    무시 = 기본_무시_glob + 프로젝트["ignore_globs"]
    스키마_glob = 기본_스키마_glob + 프로젝트["schema_globs"]
    문서_경로 = set(프로젝트["docs"].values())
    code, schema, structural, 전체 = [], [], [], set()
    for st, p in 변경:
        전체.add(p)
        if 아무거나_일치(p, 무시):
            continue
        if p in 문서_경로:
            continue
        if 아무거나_일치(p, 프로젝트["code_globs"]) or os.path.splitext(p)[1].lower() in 코드_확장자:
            is_doc = False
            code.append(p)
        else:
            is_doc = p.lower().endswith(".md")
        if 아무거나_일치(p, 스키마_glob):
            schema.append(p)
        if st in ("A", "D", "R") and not is_doc:
            structural.append(p)
    return code, schema, structural, 전체


def 사유_로드(session_dir, pst, 경고):
    f = os.path.join(session_dir, "docs_update_waiver")
    if not os.path.isfile(f):
        return {}
    try:
        if os.stat(f).st_mtime < pst:
            경고.append("사유 파일 docs_update_waiver 가 이번 사이클 시작 이전 것이라 무시합니다(이전 사이클 사유 재사용 금지).")
            return {}
        with open(f, encoding="utf-8", errors="replace") as fh:
            줄들 = fh.read().splitlines()
    except OSError:
        return {}
    사유 = {}
    무효 = 0
    for 줄 in 줄들:
        if ":" not in 줄:
            if 줄.strip():
                무효 += 1
            continue
        k, v = 줄.split(":", 1)
        k = k.strip().upper()
        v = v.strip()
        if k in 사유_키 and len(v) >= 사유_최소_길이:
            사유[k] = v
        else:
            무효 += 1
    if 무효:
        경고.append("사유 파일 형식 무효 줄 %d개(키는 %s, 사유 %d자 이상)." % (무효, "/".join(사유_키), 사유_최소_길이))
    return 사유


def _정본참조_모듈():
    """같은 lib 의 plan_ref_gate 를 지연 import 한다. 실패하면 None(자체 파서로 대체)."""
    try:
        if HERE not in sys.path:
            sys.path.insert(0, HERE)
        import plan_ref_gate as m
        if callable(getattr(m, "최신_계획서", None)) and callable(getattr(m, "정본참조_파싱", None)):
            return m
    except Exception:  # import 실패는 자체 파서로 대체(fail-open)
        pass
    return None


def _canon_root_모듈():
    """같은 lib 의 canon_root(공용 루트·정본 해석기)를 지연 import 한다. 심볼릭 링크로 실행되면 실제 위치도 본다.
    실패하면 None(종전 폴백 — plan root 폴더만으로 판정)."""
    for d in (HERE, os.path.dirname(os.path.realpath(__file__))):
        if not os.path.isfile(os.path.join(d, "canon_root.py")):
            continue
        try:
            if d not in sys.path:
                sys.path.insert(0, d)
            import canon_root as m
            if callable(getattr(m, "resolve", None)):
                return m
        except Exception:  # import 실패는 종전 폴백(fail-open)
            pass
        return None
    return None


def 이번_계획서(session_dir, pst):
    """이번 사이클(mtime ≥ 시작 시각) 계획서 경로. oplan_<conv_id>.md 우선, review 제외. 없으면 None."""
    m = _정본참조_모듈()
    f = None
    if m is not None:
        try:
            f = m.최신_계획서(session_dir)
        except Exception:
            f = None
    if f is None:
        d = os.path.join(session_dir, "plans")
        cid = ""
        try:
            with open(os.path.join(session_dir, "conv_id"), encoding="utf-8") as fh:
                cid = fh.readline().strip()
        except OSError:
            pass
        if cid and "/" not in cid and os.path.isfile(os.path.join(d, "oplan_%s.md" % cid)):
            f = os.path.join(d, "oplan_%s.md" % cid)
        else:
            try:
                후보 = [os.path.join(d, n) for n in os.listdir(d)
                      if n.startswith("oplan_") and n.endswith(".md") and "review" not in n.lower()]
            except OSError:
                후보 = []
            최신_시각 = -1
            for c in 후보:
                try:
                    t = os.stat(c).st_mtime
                except OSError:
                    continue
                if t > 최신_시각:
                    f, 최신_시각 = c, t
    if not f:
        return None
    try:
        if os.stat(f).st_mtime < pst:
            return None
    except OSError:
        return None
    return f


def _경로_정규화(p):
    p = p.strip()
    while p.startswith("./"):
        p = p[2:]
    return p.rstrip("/")


해당없음_사유_최소 = 10


def 해당없음_사유(값):
    """`해당 없음(사유)` 값에서 사유를 뽑는다. 사유가 10자 미만이면 None(해당 없음 미인정 = 줄 없음과 동일).

    공용 plan_ref_gate.해당없음_사유 가 있으면 그것을 쓰고, 없으면 같은 규칙(‘해당 없음’ 1회 제거 →
    앞뒤 괄호·대시·콜론·구두점·공백 제거 → 10자 이상)으로 직접 판정한다.
    """
    m = _정본참조_모듈()
    f = getattr(m, "해당없음_사유", None) if m is not None else None
    if callable(f):
        try:
            return f(값)
        except Exception:
            pass  # 공용 함수 예외 → 아래 같은 규칙
    if not isinstance(값, str):
        return None
    v = 값.replace("해당없음", "해당 없음")
    if "해당 없음" not in v:
        return None
    s = v.replace("해당 없음", "", 1).strip().strip("()（）[]-—–:：,.· ").strip()
    return s if len(s) >= 해당없음_사유_최소 else None


def 반영_예정_추출(계획서):
    """`## 정본 참조` 절의 `- 반영 예정:` 줄을 해석한다.

    반환: None(줄 없음) | ("none", 원문)(해당 없음) | ("paths", [경로…])
    """
    if not 계획서:
        return None
    try:
        with open(계획서, encoding="utf-8", errors="replace") as fh:
            본문 = fh.read()
    except OSError:
        return None
    m = _정본참조_모듈()
    if m is not None:
        try:
            d = m.정본참조_파싱(본문)
            if d is None:
                return None
            경로 = [_경로_정규화(p) for p in (d.get("반영예정") or []) if isinstance(p, str) and p.strip()]
            경로 = [p for p in 경로 if p and " " not in p]
            if 경로:
                return ("paths", 경로)
            if d.get("반영예정_해당없음") and 해당없음_사유(d["반영예정_해당없음"]):
                return ("none", 해당없음_사유(d["반영예정_해당없음"]))
            return None
        except Exception:
            pass  # 공용 파서 예외 → 자체 파서
    줄들 = 본문.splitlines()
    절_안 = False
    for 줄 in 줄들:
        s = 줄.strip()
        if s.startswith("## "):
            절_안 = s[3:].strip().startswith("정본 참조")
            continue
        if not 절_안:
            continue
        본문 = s.lstrip("-* ").strip()
        if not 본문.startswith("반영 예정"):
            continue
        값 = 본문[len("반영 예정"):].lstrip(" :：").strip()
        경로 = []
        # 값이 '해당 없음' 으로 시작하면 뒤따르는 백틱은 사유이지 경로가 아니다(공용 파서와 같은 규칙)
        조각 = [] if 값.replace("해당없음", "해당 없음").startswith("해당 없음") else 값.split("`")
        for i in range(1, len(조각), 2):
            p = 조각[i].strip()
            while p.startswith("./"):
                p = p[2:]
            if p and " " not in p:
                경로.append(p.rstrip("/"))
        if 경로:
            return ("paths", 경로)
        if 해당없음_사유(값):
            return ("none", 해당없음_사유(값))
        return None
    return None


def 실효_모드(모드, phase):
    if 모드 == "tier":
        return "block" if phase == "finish" else "warn"
    return 모드


def 로그(session_dir, 문장):
    if not session_dir or not os.path.isdir(session_dir):
        return
    try:
        d = os.path.join(session_dir, "logs")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "docs_gate.log"), "a", encoding="utf-8") as fh:
            fh.write("%s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S%z"), 문장))
    except OSError:
        pass


def 줄임(목록):
    s = ", ".join(목록[:목록_표시_상한])
    if len(목록) > 목록_표시_상한:
        s += " 외 %d개" % (len(목록) - 목록_표시_상한)
    return s


def 판정(session_dir, cwd, phase):
    경고 = []
    결과 = {"decision": "pass", "messages": 경고, "code": [], "schema": [], "structural": []}

    def 통과(사유코드, 문장=None):
        if 문장:
            경고.append(문장)
        로그(session_dir, "PASS phase=%s %s" % (phase, 사유코드))
        결과["decision"] = "warn" if 문장 else "pass"
        return 결과

    설정 = 설정_로드(경고)
    top = git(cwd, "rev-parse", "--show-toplevel") if os.path.isdir(cwd) else None
    if not top:
        return 통과("NO_GIT")
    root = top.strip()
    프로젝트 = 프로젝트_설정_로드(root, 경고)
    if not 프로젝트["enabled"]:
        return 통과("DISABLED_BY_PROJECT")
    pst = 사이클_시작_시각(session_dir)
    if pst is None:
        return 통과("NO_PST", "[docs_gate] 사이클 시작 시각 파일이 없어 문서 갱신 판정을 건너뜁니다.")
    base, base_src = 기준_커밋(root, session_dir, pst)
    if not base:
        return 통과("NO_BASE", "[docs_gate] 사이클 기준 커밋을 찾지 못해 문서 갱신 판정을 건너뜁니다.")
    변경 = 변경_집합(root, base, pst)
    if 변경 is None:
        return 통과("GIT_DIFF_FAIL", "[docs_gate] git diff 실패로 문서 갱신 판정을 건너뜁니다.")
    code, schema, structural, 전체 = 분류(변경, 프로젝트)
    결과.update(code=code, schema=schema, structural=structural)

    점검 = [
        ("HISTORY", "history", code, "코드", 설정["mode_history"]),
        ("DATABASE", "database", schema, "스키마", 설정["mode_database"]),
        ("PROJECT", "project", structural, "파일 신설·삭제·이동", 설정["mode_project"]),
    ]
    사유 = None
    위반 = []
    for 키, 문서키, 대상, 이름, 모드 in 점검:
        if not 대상 or 모드 == "off":
            continue
        문서 = 프로젝트["docs"][문서키]
        if not os.path.isfile(os.path.join(root, 문서)):
            continue
        if 문서 in 전체:
            continue
        if 사유 is None:
            사유 = 사유_로드(session_dir, pst, 경고)
        if 키 in 사유:
            로그(session_dir, "WAIVED %s %s" % (키, 사유[키]))
            경고.append("[docs_gate] %s 미반영을 사유 파일로 인정했습니다: %s" % (문서, 사유[키]))
            continue
        위반.append((키, 문서, 대상, 이름, 모드, None))

    # PLAN: plan root 정본 갱신 누락 (plan root 가 있을 때만)
    plan_root = 프로젝트["canon"]["plan_root"]
    plan_모드 = 실효_모드(설정["mode_plan"], phase)
    # [K6 TODO-004] 시작 조건 = canon_root.plan_active(plan root 폴더 AND index.json). 해석기 없음·실패는 종전(폴더만)
    plan_시작 = os.path.isdir(os.path.join(root, plan_root))
    cr = _canon_root_모듈() if plan_모드 != "off" else None
    if cr is not None:
        try:
            해석 = cr.resolve(root)
            if 해석.get("plan_root_invalid"):
                경고.append("[docs_gate] canon.plan_root 설정(%s)을 거부했습니다(절대경로·'..') — PLAN 판정을 건너뜁니다."
                          % 해석.get("plan_root"))
            plan_시작 = bool(해석.get("plan_active"))
            로그(session_dir, "CANON_ROOT plan_active=%s invalid=%s" % (plan_시작, bool(해석.get("plan_root_invalid"))))
        except Exception as e:  # 해석 실패는 종전 폴백
            로그(session_dir, "CANON_ROOT_FAIL %r" % (e,))
    if plan_모드 != "off" and plan_시작:
        plan_변경 = [p for p in 전체 if p == plan_root or p.startswith(plan_root + "/")]
        계획서 = 이번_계획서(session_dir, pst)
        예정 = 반영_예정_추출(계획서)
        plan_위반 = None
        if 예정 and 예정[0] == "none":
            로그(session_dir, "PLAN_NONE_DECLARED 사유=%s 계획서=%s" % (예정[1], 계획서))
        if 예정 and 예정[0] == "paths":
            누락 = [e for e in 예정[1] if not any(p == e or p.startswith(e + "/") for p in 전체)]
            if 누락:
                plan_위반 = (누락, "[docs_gate] 계획서 `반영 예정` 문서 %d개(%s)가 이번 사이클에 갱신되지 않았습니다(<표시>). 계획서: %s"
                            % (len(누락), 줄임(누락), 계획서))
        elif 예정 is None and (code or structural) and not plan_변경:
            대상 = sorted(set(code + structural))
            plan_위반 = (대상, "[docs_gate] 코드·구조 변경 %d개(%s)가 있는데 계획서에 `반영 예정` 이 없고 %s/ 정본도 갱신되지 않았습니다(<표시>)."
                        % (len(대상), 줄임(대상), plan_root))
        if plan_위반:
            if 사유 is None:
                사유 = 사유_로드(session_dir, pst, 경고)
            if "PLAN" in 사유:
                로그(session_dir, "WAIVED PLAN %s" % 사유["PLAN"])
                경고.append("[docs_gate] %s/ 정본 미반영을 사유 파일로 인정했습니다: %s" % (plan_root, 사유["PLAN"]))
            else:
                위반.append(("PLAN", plan_root + "/", plan_위반[0], "정본", plan_모드, plan_위반[1]))

    강등 = pst < 설정["enforce_after_epoch"]
    차단 = False
    차단_키 = []
    for 키, 문서, 대상, 이름, 모드, 문장 in 위반:
        실효 = "warn" if (모드 == "block" and 강등) else 모드
        if 실효 == "block":
            차단 = True
            차단_키.append(키)
        표시 = "차단" if 실효 == "block" else "경고"
        if 문장:
            경고.append(문장.replace("<표시>", 표시))
        else:
            경고.append("[docs_gate] %s 변경 %d개(%s)가 있는데 %s 이(가) 이번 사이클에 반영되지 않았습니다(%s)."
                      % (이름, len(대상), 줄임(대상), 문서, 표시))
        로그(session_dir, "VIOLATION phase=%s key=%s mode=%s effective=%s n=%d base=%s(%s)"
             % (phase, 키, 모드, 실효, len(대상), base[:10], base_src))
    if 위반 and 강등 and any(v[4] == "block" for v in 위반):
        경고.append("[docs_gate] 이 사이클은 게이트 적용 시각 이전에 시작해 차단을 경고로 강등했습니다.")
    if 차단:
        waiver = os.path.join(session_dir, "docs_update_waiver")
        if [k for k in 차단_키 if k != "PLAN"]:
            경고.append("해소: odone_docs 로 해당 문서를 갱신하거나, 의도적 생략이면 %s 에 `HISTORY: 사유`(10자 이상) 형식으로 적은 뒤 다시 전이하세요. 우회 금지."
                      % waiver)
        if "PLAN" in 차단_키:
            경고.append("해소(PLAN): odone_docs 로 계획서 `반영 예정` 문서(또는 %s/ 하위 정본·index.json)를 갱신하거나, "
                      "갱신이 불필요하면 계획서 `## 정본 참조` 에 `- 반영 예정: 해당 없음(사유)` 를 적거나 %s 에 "
                      "`PLAN: 사유`(10자 이상) 한 줄을 적은 뒤 다시 전이하세요. 우회 금지." % (plan_root, waiver))
        결과["decision"] = "block"
    elif 위반 or 경고:
        결과["decision"] = "warn"
    else:
        결과["decision"] = "pass"
    로그(session_dir, "RESULT phase=%s decision=%s code=%d schema=%d structural=%d"
         % (phase, 결과["decision"], len(code), len(schema), len(structural)))
    return 결과


def main(argv):
    인자 = {"--session-dir": "", "--cwd": "", "--phase": "finish"}
    if not argv or argv[0] != "check":
        print(json.dumps({"decision": "pass", "messages": ["사용법: docs_gate.py check --session-dir D --cwd C --phase finish|idle"]}, ensure_ascii=False))
        return 0
    i = 1
    while i < len(argv):
        if argv[i] in 인자 and i + 1 < len(argv):
            인자[argv[i]] = argv[i + 1]
            i += 2
        else:
            i += 1
    try:
        결과 = 판정(인자["--session-dir"], 인자["--cwd"] or os.getcwd(), 인자["--phase"])
    except Exception as e:  # 판정 불가는 fail-open
        결과 = {"decision": "warn", "messages": ["[docs_gate] 판정 중 예외로 통과시킵니다: %r" % (e,)],
              "code": [], "schema": [], "structural": []}
        로그(인자["--session-dir"], "EXCEPTION %r" % (e,))
    print(json.dumps(결과, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
