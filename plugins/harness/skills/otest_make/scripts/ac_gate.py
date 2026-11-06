#!/usr/bin/env python3
# 기준표(acceptance_criteria.json)의 record_contract 로 시험 기록(ac_records)을 판정·검증하는 단일 출처 판정기(사이클별 사본 금지)
"""
사용법 (세션 디렉터리 = --session DIR 또는 환경변수 GOAL_SESSION_DIR — plans/acceptance_criteria.json 이 있어야 한다)
  python3 ac_gate.py --session DIR item AC-001        # rc 0=PASS · 1=FAIL · 3=판정불가
  python3 ac_gate.py --session DIR all                # 전 항목 표(rc 는 최악값)
  python3 ac_gate.py --session DIR contract           # 시험 담당(생산자)에게 줄 기록 규약 원문 출력 — 프롬프트에 그대로 붙인다
  python3 ac_gate.py --session DIR stamp [--axes a,b] # 현재 산출물(build_sources) md5 로 build 객체 출력 — 기록 최상위 build 에 넣는다
  python3 ac_gate.py --session DIR validate-record PATH [--content-file F]   # 위치·형식 검증(rc 0 정상 · 1 위반 · 4 계약 없음)
  python3 ac_gate.py selftest                         # 판정기 자체 시험
  python3 ac_gate.py hook                             # PreToolUse hook 판정(stdin = hook 입력 JSON, rc 0 통과 · 2 차단)
  -v 를 붙이면 판정 근거를 stderr 로 낸다.

왜 이 파일이 있는가 (사이클196 oi-fix-1 RCA — 판정장치 반복 문제)
  - 판정기가 사이클마다 세션 디렉터리에 사본(cNNN_gate.py)으로 복제·수정됐다. 사이클 고유값(기록 위치·계약 시각·특수 AC)이
    코드 상수라 복사가 유일한 재사용 방법이었고, 사본마다 안내 문구가 어긋났다(c196 사본이 _tmp_c195 를 안내).
  - 기록 규약은 판정기 docstring·기준표 산문(record_rule)에만 있고 생산자 프롬프트에 전달되지 않았다. 규약 밖 위치에 쓴 기록은
    판정기가 조용히 무시해 "기록 없음 FAIL" 로만 드러났다.
  - "현재 판" 은 리드가 손으로 쓰는 current_build.json 과 대조했다 — 빌드 도구가 갱신하지 않아 재빌드마다 거짓이 됐다.
  - status 어휘가 PASS/FAIL/PARTIAL 뿐이라 "근거 있는 N/A" 를 PASS 로 접어 적었다.
  ⇒ 사이클 고유값은 기준표 최상위 record_contract 한 곳에서만 읽는다. 현재 판은 판정 시점에 산출물 md5 를 직접 계산한다.
    규약 밖 위치의 기록은 판정불가 + 경로로 낸다. NA 는 근거(na_basis)와 AC 의 na_allowed 가 있을 때만 통과로 센다.

record_contract (기준표 최상위 객체)
  root          : 절대경로. 기록 = <root>/<담당 이름>/ac_records_b<N>[_<태그>].json (또는 <root>/ 바로 아래)
  status_enum   : 허용 status (기본 PASS FAIL PARTIAL BLOCKED NA — 이 집합의 부분집합, PASS·FAIL 필수)
  build_sources : {축: 산출물 절대경로} — 그 파일 md5 가 그 축의 현재 판이다(선택. AC 가 build_axes 를 쓰면 필수)
  records_after : ISO 시각 — build_axes 없는 AC 는 이 시각 이후 mtime 기록만 인정(기본 기준표 created_at)
  orphan_scan   : 규약 밖 기록을 찾을 추가 디렉터리 목록(선택)
  evidence_bases: 증거 상대경로를 풀 추가 기준 디렉터리(선택)
기준표 항목(criteria[]) 필드
  id · batches(정수 배열, 없으면 batch 정수) · build_axes · gate_kind(record|canary|direct) · direct(criteria_copies_same|selftest)
  · item_crud(true 면 PASS 행에 write_log 실존 필수) · na_allowed(true 면 NA+na_basis 를 통과로 센다) · required_keys(PASS 행 필수 키)
기록 파일
  {"batch": N, "build": {축: md5}, "records": [{"id","status","evidence","files","shots","write_log","na_basis"}]}
  '.pre_' 가 든 파일명은 초안이라 판정에서 뺀다(위치 검사도 하지 않는다).
"""
import hashlib
import json
import os
import re
import sys
import tempfile
from datetime import datetime, timedelta, timezone

KST = timezone(timedelta(hours=9))
DEFAULT_STATUS = ("PASS", "FAIL", "PARTIAL", "BLOCKED", "NA")
EVID_EXT = (".json", ".jsonl", ".md", ".txt", ".out", ".log", ".png", ".jpg", ".csv", ".py", ".ps1", ".sh", ".xml", ".dmp")
NAME_RE = re.compile(r"^ac_records_b(\d+)(?:_[A-Za-z0-9-]+)?\.json$")
KV_TOKEN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=(.+)$")
SKIP_DIRS = {"bin", "obj", "node_modules", ".git", "__pycache__", ".vs", "packages"}
NA_BASIS_MIN = 8
VERBOSE = False


class Undetermined(Exception):
    """판정불가(rc=3)"""


class NoContract(Exception):
    """기준표에 record_contract 가 없다(rc=4 — 이 판정기 대상 아님)"""


def log(msg):
    if VERBOSE:
        print(msg, file=sys.stderr)


# ── 계약 로드 ─────────────────────────────────────────────────────────
def criteria_path(sd):
    return os.path.join(sd, "plans", "acceptance_criteria.json")


def copies_same(sd):
    a = os.path.join(sd, "acceptance_criteria.json")
    b = criteria_path(sd)
    if not os.path.isfile(b):
        return False, f"plans 사본 부재: {b}"
    if os.path.isfile(a) and open(a, "rb").read() != open(b, "rb").read():
        return False, "세션 루트와 plans/ 의 acceptance_criteria.json 내용이 다르다(L-1342)"
    return True, "기준표 사본 일치(또는 루트 사본 없음)"


def _parse_ts(raw):
    ts = datetime.fromisoformat(str(raw))
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=KST)
    return ts.timestamp()


class Contract:
    def __init__(self, sd):
        self.sd = sd
        same, why = copies_same(sd)
        if not same:
            raise Undetermined(f"기준표 출처 불일치 — {why}")
        try:
            data = json.load(open(criteria_path(sd), encoding="utf-8"))
        except Exception as e:
            raise Undetermined(f"기준표 파싱 실패: {e}")
        rc = data.get("record_contract") if isinstance(data, dict) else None
        if not isinstance(rc, dict):
            raise NoContract("기준표에 record_contract 가 없다")
        root = rc.get("root")
        if not isinstance(root, str) or not os.path.isabs(root):
            raise Undetermined("record_contract.root 는 절대경로 문자열이어야 한다")
        self.root = os.path.realpath(root)
        enum = rc.get("status_enum") or list(DEFAULT_STATUS)
        enum = [str(s).upper() for s in enum]
        if not set(enum) <= set(DEFAULT_STATUS) or "PASS" not in enum or "FAIL" not in enum:
            raise Undetermined(f"record_contract.status_enum 은 {DEFAULT_STATUS} 의 부분집합이고 PASS·FAIL 을 포함해야 한다")
        self.enum = enum
        bs = rc.get("build_sources") or {}
        if not isinstance(bs, dict) or any(not isinstance(v, str) or not os.path.isabs(v) for v in bs.values()):
            raise Undetermined("record_contract.build_sources 는 {축: 절대경로} 여야 한다")
        self.build_sources = bs
        after = rc.get("records_after") or data.get("created_at")
        if not after:
            raise Undetermined("record_contract.records_after 또는 기준표 created_at 이 필요하다")
        try:
            self.cutoff = _parse_ts(after)
        except Exception:
            raise Undetermined(f"기록 인정 시작 시각 해석 실패: {after!r}")
        self.orphan_scan = [p for p in (rc.get("orphan_scan") or []) if isinstance(p, str) and os.path.isabs(p)]
        self.evidence_bases = [p for p in (rc.get("evidence_bases") or []) if isinstance(p, str) and os.path.isabs(p)]
        self.crit = {}
        for c in data.get("criteria") or []:
            if not isinstance(c, dict) or not isinstance(c.get("id"), str):
                continue
            batches = c.get("batches") or [c.get("batch") or 1]
            try:
                batches = [int(x) for x in batches]
            except Exception:
                raise Undetermined(f"{c['id']}: batches 해석 실패")
            self.crit[c["id"]] = {
                "batches": batches,
                "axes": [a for a in (c.get("build_axes") or [])],
                "kind": str(c.get("gate_kind") or "record").lower(),
                "direct": c.get("direct"),
                "crud": c.get("item_crud") is True,
                "na": c.get("na_allowed") is True,
                "req": [k for k in (c.get("required_keys") or []) if isinstance(k, str)],
            }
        self._cb = None
        self._orphans = None

    # 현재 판 — 판정 시점에 산출물 md5 를 계산한다(저장 파일 없음)
    def current_build(self, axis):
        if self._cb is None:
            self._cb = {}
        if axis not in self._cb:
            p = self.build_sources.get(axis)
            if not p:
                raise Undetermined(f"build_sources 에 {axis} 축이 없다 — 이 AC 는 build_axes 에 {axis} 를 요구한다")
            if not os.path.isfile(p):
                raise Undetermined(f"{axis} 축 산출물 부재: {p}")
            h = hashlib.md5()
            with open(p, "rb") as fp:
                for chunk in iter(lambda: fp.read(1 << 20), b""):
                    h.update(chunk)
            self._cb[axis] = h.hexdigest()
        return self._cb[axis]

    def record_files(self):
        out = []
        if not os.path.isdir(self.root):
            return out
        for e in os.scandir(self.root):
            if e.is_file() and NAME_RE.match(e.name):
                out.append(e.path)
            elif e.is_dir():
                for e2 in os.scandir(e.path):
                    if e2.is_file() and NAME_RE.match(e2.name):
                        out.append(e2.path)
        return sorted(set(os.path.realpath(f) for f in out))

    def in_root(self, path):
        d = os.path.dirname(os.path.realpath(path))
        return d == self.root or os.path.dirname(d) == self.root

    # 규약 밖 위치의 기록 — 같은 이름의 사이클 작업 폴더가 형제 프로젝트 아래 생긴 경우(상대경로 오해석)까지 찾는다
    def orphans(self):
        if self._orphans is not None:
            return self._orphans
        cyc = self.root
        if os.path.basename(cyc).lower().startswith("otest"):
            cyc = os.path.dirname(cyc)
        name = os.path.basename(cyc)
        scan = [cyc] + list(self.orphan_scan)
        base = os.path.dirname(cyc)
        try:
            for e in os.scandir(base):
                if e.is_dir() and not e.name.startswith("."):
                    cand = os.path.join(e.path, name)
                    if os.path.isdir(cand):
                        scan.append(cand)
        except OSError:
            pass
        found = []
        for top in dict.fromkeys(os.path.realpath(s) for s in scan):
            for dirpath, dirnames, filenames in _walk(top, 4):
                for fn in filenames:
                    if fn.startswith("ac_records") and fn.endswith(".json") and ".pre_" not in fn:
                        p = os.path.realpath(os.path.join(dirpath, fn))
                        if not (self.in_root(p) and NAME_RE.match(fn)):
                            found.append(p)
        self._orphans = sorted(set(found))
        return self._orphans


def _walk(top, depth):
    base = top.rstrip(os.sep).count(os.sep)
    for dirpath, dirnames, filenames in os.walk(top):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and not d.startswith(".")]
        if dirpath.count(os.sep) - base >= depth:
            dirnames[:] = []
        yield dirpath, dirnames, filenames


def session_dir(arg=None):
    sd = arg or os.environ.get("GOAL_SESSION_DIR")
    if not sd:
        raise Undetermined("세션 디렉터리를 모른다 — --session DIR 또는 GOAL_SESSION_DIR")
    if not os.path.isfile(criteria_path(sd)):
        raise Undetermined(f"기준표 없음: {criteria_path(sd)}")
    return sd


# ── 기록 해석 ─────────────────────────────────────────────────────────
def load_record(path):
    try:
        d = json.load(open(path, encoding="utf-8"))
    except Exception as e:
        raise Undetermined(f"기록 파싱 실패: {path}: {e}")
    return d


def hash_match(a, b):
    a, b = str(a).strip().lower(), str(b).strip().lower()
    n = min(len(a), len(b))
    if n < 8:
        raise Undetermined(f"해시 8자 미만 비교 불가({a!r} ↔ {b!r})")
    return a[:n] == b[:n]


def evidence_paths(row):
    toks = []
    ev = row.get("evidence")
    if isinstance(ev, list):
        ev = " ".join(str(x) for x in ev)
    if isinstance(ev, str):
        for t in re.split(r"[\s,;()\[\]{}'\"`·—]+", ev):
            t = t.strip().rstrip(".:")
            # L-1364: 'C196_CRITERIA=<경로>' 처럼 KEY= 가 붙은 토큰은 값 부분만 경로 후보로 본다(실존 검사는 그대로).
            m = KV_TOKEN_RE.match(t)
            if m:
                t = m.group(1)
            if "/" in t and t.lower().endswith(EVID_EXT) and len(t) > 4:
                toks.append(t)
    for key in ("files", "shots"):
        v = row.get(key)
        if isinstance(v, list):
            toks += [str(x) for x in v if str(x).strip()]
    return toks


def resolve(tok, rec_path, ct):
    if os.path.isabs(tok):
        return os.path.exists(tok)
    d = os.path.dirname(rec_path)
    for base in [d, os.path.dirname(d), ct.root, os.path.dirname(ct.root)] + ct.evidence_bases:
        if os.path.exists(os.path.join(base, tok)):
            return True
    return False


def validate(ct, path, d):
    """기록 파일 하나의 위치·형식 위반 목록. d=파싱된 내용(dict 기대)."""
    errs = []
    name = os.path.basename(path)
    m = NAME_RE.match(name)
    if not ct.in_root(path):
        errs.append(f"위치 위반: {path} — 기록은 {ct.root}/<담당 이름>/ac_records_b<N>.json 이어야 한다")
    if not m:
        errs.append(f"파일명 위반: {name} — ac_records_b<N>.json 또는 ac_records_b<N>_<태그>.json")
    if not isinstance(d, dict):
        errs.append("최상위가 객체가 아니다 — {\"batch\": N, \"build\": {...}, \"records\": [...]}")
        return errs
    b = d.get("batch")
    if not isinstance(b, int) or isinstance(b, bool) or b < 1:
        errs.append("최상위 batch 는 1 이상 정수여야 한다")
    elif m and int(m.group(1)) != b:
        errs.append(f"batch 불일치(최상위 {b} ≠ 파일명 {m.group(1)})")
    rows = d.get("records")
    if not isinstance(rows, list) or not rows:
        errs.append("records 는 비지 않은 배열이어야 한다")
        return errs
    top_build = d.get("build") if isinstance(d.get("build"), dict) else {}
    for i, r in enumerate(rows):
        if not isinstance(r, dict):
            errs.append(f"records[{i}] 가 객체가 아니다")
            continue
        rid = r.get("id")
        if rid not in ct.crit:
            errs.append(f"records[{i}].id={rid!r} 는 기준표에 없는 id 다(정확히 일치해야 한다)")
            continue
        c = ct.crit[rid]
        st = str(r.get("status", "")).strip().upper()
        if st not in ct.enum:
            errs.append(f"{rid}: status={r.get('status')!r} 는 허용 어휘 {ct.enum} 밖이다(조건부·괄호 표기 금지 — 근거 있는 N/A 는 NA+na_basis)")
        if st == "NA":
            if not c["na"]:
                errs.append(f"{rid}: 이 AC 는 na_allowed 가 아니다 — NA 를 쓸 수 없다")
            nb = r.get("na_basis")
            if not isinstance(nb, str) or len(nb.strip()) < NA_BASIS_MIN:
                errs.append(f"{rid}: NA 는 na_basis(근거 {NA_BASIS_MIN}자 이상)가 필요하다")
        if st == "PASS" and c["crud"]:
            wl = r.get("write_log")
            if not wl:
                errs.append(f"{rid}: item_crud 항목 PASS 는 write_log(원천 쓰기 로그 경로)가 필요하다")
        if c["axes"]:
            bd = r.get("build") if isinstance(r.get("build"), dict) else top_build
            for ax in c["axes"]:
                v = str((bd or {}).get(ax) or "")
                if not re.fullmatch(r"[0-9a-fA-F]{8,64}", v):
                    errs.append(f"{rid}: build.{ax} 해시 없음·형식 오류 — 'ac_gate.py stamp' 출력을 최상위 build 에 넣는다")
    return errs


# ── 판정 ──────────────────────────────────────────────────────────────
def judge(ct, ac):
    if ac not in ct.crit:
        raise Undetermined(f"알 수 없는 AC id: {ac}")
    c = ct.crit[ac]
    if c["kind"] == "canary":
        return 1, "FAIL — 카나리(항상 FAIL 이어야 정상)"
    if c["kind"] == "direct":
        if c["direct"] == "criteria_copies_same":
            same, why = copies_same(ct.sd)
            return (0, "PASS — " + why) if same else (1, "FAIL — " + why)
        if c["direct"] == "selftest":
            return (0, "PASS — selftest 통과") if selftest(quiet=True) == 0 else (1, "FAIL — selftest 실패")
        raise Undetermined(f"direct 판정 종류 미지원: {c['direct']!r}")
    orph = []
    for p in ct.orphans():
        try:
            txt = open(p, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        if re.search(r'"id"\s*:\s*"' + re.escape(ac) + r'"', txt):
            orph.append(p)
    if orph:
        raise Undetermined(f"규약 밖 위치·이름의 기록에 {ac} 가 있다: {', '.join(orph[:3])} — {ct.root}/<담당 이름>/ac_records_b<N>.json 으로 옮겨라")
    maxb = max(c["batches"])
    cands = []
    for f in ct.record_files():
        d = load_record(f)
        rows = d.get("records") if isinstance(d, dict) and isinstance(d.get("records"), list) else []
        hits = [r for r in rows if isinstance(r, dict) and r.get("id") == ac]
        if not hits:
            continue
        errs = [e for e in validate(ct, f, d) if e.startswith(ac + ":") or not re.match(r"^[A-Za-z]+-\S*:", e)]
        if errs:
            cands.append((os.path.getmtime(f), f, None, errs))
            continue
        b = d["batch"]
        mt = os.path.getmtime(f)
        kept = []
        for r in hits:
            if c["axes"]:
                bd = r.get("build") if isinstance(r.get("build"), dict) else d.get("build", {})
                bad = [f"{ax}={str(bd.get(ax))[:8]}≠{ct.current_build(ax)[:8]}" for ax in c["axes"]
                       if not hash_match(bd.get(ax), ct.current_build(ax))]
                ok = not bad
                log(f"  {f}: {'현재 판' if ok else '현재 판 아님(' + ', '.join(bad) + ')'}")
            else:
                ok = mt >= ct.cutoff
                log(f"  {f}: {'기록 인정 시각 이후' if ok else '기록 인정 시각 이전'}")
            if ok:
                kept.append(r)
        if kept and b >= maxb:
            cands.append((mt, f, kept, None))
    if not cands:
        return 1, f"FAIL — B{maxb} 이상 배치의 유효 기록 없음(batches={c['batches']}, axes={c['axes']}, 기록 위치 {ct.root}/<담당>/)"
    mt, f, kept, errs = max(cands, key=lambda x: x[0])
    if errs:
        return 1, f"FAIL — 기록 형식 위반({os.path.basename(f)}): {'; '.join(errs[:3])}"
    labels = []
    for r in kept:
        st = str(r.get("status", "")).strip().upper()
        if st == "PASS":
            labels.append("PASS")
        elif st == "NA" and c["na"] and isinstance(r.get("na_basis"), str) and len(r["na_basis"].strip()) >= NA_BASIS_MIN:
            labels.append("NA")
        else:
            labels.append(st or "EMPTY")
    if any(l not in ("PASS", "NA") for l in labels):
        return 1, f"FAIL — 최근 판정 {'/'.join(labels)} ({os.path.basename(f)})"
    missing = sorted(set(t for r in kept for t in evidence_paths(r) if not resolve(t, f, ct)))
    if missing:
        return 1, f"FAIL — 증거 경로 부재: {', '.join(missing[:5])} ({os.path.basename(f)})"
    if c["crud"]:
        bad = []
        for r in kept:
            if str(r.get("status")).upper() != "PASS":
                continue
            v = r.get("write_log")
            toks = [str(t).strip() for t in (v if isinstance(v, list) else [v]) if t and str(t).strip()]
            if not toks:
                bad.append(f"{ac}:write_log 없음")
            bad += [f"{ac}:{t}" for t in toks if not resolve(t, f, ct)]
        if bad:
            return 1, f"FAIL — item_crud 항목 원천 쓰기 로그(write_log) 없음·부재: {bad[:4]} ({os.path.basename(f)})"
    if c["req"]:
        bad = [f"{k}" for r in kept for k in c["req"] if r.get(k) in (None, "", [], {})]
        if bad:
            return 1, f"FAIL — 필수 키 없음: {sorted(set(bad))} ({os.path.basename(f)})"
    if "NA" in labels:
        return 0, f"PASS(N/A) — {os.path.basename(f)} · 근거: {kept[labels.index('NA')]['na_basis'][:80]}"
    return 0, f"PASS — {os.path.basename(f)}"


def contract_text(ct):
    me = os.path.realpath(__file__)
    axes = ", ".join(f"{k}={v}" for k, v in ct.build_sources.items()) or "(없음)"
    return "\n".join([
        "[시험 기록 규약 — 판정기 ac_gate.py 가 이 규약으로만 PASS 를 읽는다]",
        f"- 위치: {ct.root}/<당신의 이름>/ac_records_b<배치번호>.json  (절대경로. 상대경로로 풀지 마라)",
        "- 형식: {\"batch\": <정수>, \"build\": <stamp 출력>, \"records\": [{\"id\": \"<기준표 id 그대로>\", \"status\": \"<어휘>\", "
        "\"evidence\": \"<증거 경로 포함 설명>\", \"files\": [...], \"write_log\": [...], \"na_basis\": \"...\"}]}",
        f"- status 어휘: {' · '.join(ct.enum)} (그 밖의 표기·괄호·'조건부' 금지)",
        "- 근거 있는 N/A 는 status \"NA\" + na_basis(근거 문장) — 기준표에 na_allowed:true 인 AC 만 통과로 센다",
        "- item_crud:true AC 의 PASS 행은 write_log(원천 쓰기 로그·전후 스냅샷 경로)가 실존해야 한다",
        f"- build: python3 {me} --session {ct.sd} stamp 출력을 최상위 build 에 넣는다(현재 산출물 md5 — {axes})",
        f"- 쓰기 직후 확인: python3 {me} --session {ct.sd} validate-record <기록 경로>  (rc 0 이어야 한다)",
        f"- 판정: python3 {me} --session {ct.sd} item <AC-ID>",
        "- 초안은 파일명에 '.pre_' 를 넣는다(판정·위치 검사에서 빠진다)",
    ])


# ── hook (PreToolUse) ─────────────────────────────────────────────────
WRITE_TOOLS = {"mcp__oio__file_write", "mcp__oio__file_edit", "mcp__oio__file_copy", "mcp__oio__file_move",
               "mcp__oio__file_rename", "Write", "Edit"}
LOCAL_GATE_RE = re.compile(r"(?:session-env/[^\s\"'/]+|\$\{GOAL_SESSION_DIR(?::-[^}\s]*)?\}|\$GOAL_SESSION_DIR)/[^\s\"'/]*gate[^\s\"'/]*\.py")


def _lead_uuid(inp):
    """리드 세션 UUID — 가장 가까운 조상의 --parent-session-id(팀원), 없으면 hook 입력 session_id(메인).
    첫 claude 실행 파일 프로세스에서 멈춘다(그 위 조상의 인자를 집지 않게)."""
    pid = os.getpid()
    for _ in range(10):
        try:
            argv = open(f"/proc/{pid}/cmdline", "rb").read().split(b"\0")
        except OSError:
            break
        for i, a in enumerate(argv):
            if a == b"--parent-session-id" and i + 1 < len(argv):
                v = argv[i + 1].decode("utf-8", "replace")
                if re.fullmatch(r"[0-9a-f-]{36}", v):
                    return v
        a0 = argv[0].decode("utf-8", "replace") if argv else ""
        if "/claude/versions/" in a0 or os.path.basename(a0) == "claude":
            break
        try:
            stat = open(f"/proc/{pid}/stat").read()
            pid = int(stat.rsplit(") ", 1)[1].split()[1])
        except Exception:
            break
        if pid <= 1:
            break
    s = inp.get("session_id")
    return s if isinstance(s, str) and re.fullmatch(r"[0-9a-f-]{36}", s) else None


def _cfg():
    return os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")


def _new_content(inp, target):
    """도구 실행 뒤 대상 파일 내용(문자열) — 판독 불가면 None."""
    t = inp.get("tool_name")
    ti = inp.get("tool_input") or {}
    if t in ("mcp__oio__file_write", "Write"):
        for k in ("content", "body", "data", "text", "new_content", "new_text"):
            if isinstance(ti.get(k), str):
                return ti[k]
        return None
    if t in ("mcp__oio__file_edit", "Edit"):
        old = ti.get("old_string") or ti.get("old") or ""
        new = ti.get("new_string") or ti.get("new") or ""
        try:
            src = open(target, encoding="utf-8").read()
        except OSError:
            return None
        if ti.get("replace_all"):
            return src.replace(old, new)
        return src.replace(old, new, 1)
    src = ti.get("source") or ti.get("src") or ti.get("path")
    if t == "mcp__oio__file_rename":
        src = ti.get("path") or ti.get("source")
    try:
        return open(src, encoding="utf-8").read()
    except (OSError, TypeError):
        return None


def _targets(inp):
    t = inp.get("tool_name")
    ti = inp.get("tool_input") or {}
    out = []
    if t in ("mcp__oio__file_copy", "mcp__oio__file_move"):
        v = ti.get("destination") or ti.get("dest") or ti.get("dst")
        if isinstance(v, str):
            out.append(v)
    elif t == "mcp__oio__file_rename":
        p = ti.get("path") or ti.get("source") or ""
        n = ti.get("new_name") or ""
        if n:
            out.append(n if n.startswith("/") else os.path.join(os.path.dirname(p), n))
    else:
        for k in ("path", "file_path", "filepath"):
            if isinstance(ti.get(k), str):
                out.append(ti[k])
                break
    return out


def _block(reason):
    print(json.dumps({"decision": "block", "reason": reason}, ensure_ascii=False))
    return 2


def _hook_log(sd, line):
    try:
        os.makedirs(os.path.join(sd, "logs"), exist_ok=True)
        with open(os.path.join(sd, "logs", "ac_records_guard.log"), "a", encoding="utf-8") as fp:
            fp.write(datetime.now(KST).strftime("%Y-%m-%dT%H:%M:%S%z") + " " + line + "\n")
    except OSError:
        pass


def hook_main(raw):
    try:
        inp = json.loads(raw)
    except Exception:
        return 0
    if inp.get("tool_name") not in WRITE_TOOLS:
        return 0
    targets = _targets(inp)
    if not targets:
        return 0
    lead = _lead_uuid(inp)
    if not lead:
        return 0
    sd = os.path.join(_cfg(), "session-env", lead)
    if not os.path.isfile(criteria_path(sd)):
        return 0
    try:
        ct = Contract(sd)
    except NoContract:
        return 0  # record_contract 없는 기준표 — 무동작(진행 중 사이클 무영향)
    except Undetermined as e:
        name_hit = any(os.path.basename(x).startswith("ac_records") for x in targets)
        if name_hit:
            return _block(f"🚫 [AC-RECORD] 기준표 record_contract 판독 불가 — {e}. 해소: 리드가 기준표의 record_contract 를 고친다.")
        return 0
    for tgt in targets:
        base = os.path.basename(tgt)
        # P1-H: 시험 기록 쓰기 — 쓰는 순간 위치·형식을 검사한다
        if base.startswith("ac_records") and base.endswith(".json") and ".pre_" not in base:
            content = _new_content(inp, tgt)
            try:
                d = json.loads(content) if content is not None else None
            except Exception:
                d = "unparsable"
            errs = validate(ct, tgt, d) if d != "unparsable" else ["JSON 이 아니다"]
            if d is None:
                errs = ["새 내용을 판독할 수 없다(도구 입력에 content 없음)"] + [e for e in errs if e.startswith("위치") or e.startswith("파일명")]
            if errs:
                _hook_log(sd, f"BLOCK target={tgt} errs={len(errs)} first={errs[0][:120]}")
                return _block("🚫 [AC-RECORD] 시험 기록이 기준표 record_contract 와 맞지 않는다 — " + " | ".join(errs[:6])
                              + f"\n해소: 아래 규약대로 고쳐 다시 쓴다(초안이면 파일명에 '.pre_').\n{contract_text(ct)}")
            _hook_log(sd, f"ALLOW target={tgt}")
        # P1-G(b): 계약 세션 디렉터리에 사본 판정기(*gate*.py)를 새로 만들지 못하게 한다(복사·수정 재사용 차단)
        in_sess = f"/session-env/{lead}/" in os.path.realpath(os.path.dirname(tgt)) + "/"
        if in_sess and re.fullmatch(r"[^/]*gate[^/]*\.py", base):
            _hook_log(sd, f"BLOCK session_gate_copy target={tgt}")
            return _block(f"🚫 [AC-GATE-COPY] record_contract 를 쓰는 세션 디렉터리에 사본 판정기({base})를 만들 수 없다 — 판정기는 단일 출처다."
                          f"\n해소: 사이클 고유값은 기준표 record_contract 에 넣고 python3 {os.path.realpath(__file__)} --session <세션> item <AC-ID> 를 쓴다."
                          " 판정 규칙을 바꿔야 하면 단일 판정기를 고치고 selftest·회귀 시험을 통과시킨다.")
        # P1-G: 새 계약(goal.json)이 세션 사본 판정기를 가리키지 못하게 한다
        if base == "goal.json" and f"/session-env/{lead}/" in os.path.realpath(tgt) + "/":
            content = _new_content(inp, tgt)
            try:
                g = json.loads(content) if content else None
            except Exception:
                g = None
            if not isinstance(g, dict):
                continue
            bad = []
            for a in g.get("acceptance") or []:
                s = a.get("auto_script") if isinstance(a, dict) else None
                if isinstance(s, str) and LOCAL_GATE_RE.search(s):
                    bad.append(f"{a.get('id')}: {LOCAL_GATE_RE.search(s).group(0)}")
            if bad:
                _hook_log(sd, f"BLOCK goal_local_gate n={len(bad)}")
                return _block("🚫 [AC-GATE-COPY] record_contract 를 쓰는 사이클의 계약(goal.json) auto_script 가 세션 디렉터리의 사본 판정기를 가리킨다: "
                              + "; ".join(bad[:5]) + f"\n해소: auto_script 를 단일 판정기로 바꾼다 — python3 {os.path.realpath(__file__)} --session \"${{GOAL_SESSION_DIR:-{sd}}}\" item <AC-ID>")
    return 0


# ── selftest ──────────────────────────────────────────────────────────
def selftest(quiet=False):
    cases = []
    full = "f744566bf24a735586b552070b7a716d"
    cases.append(("해시 8↔32 일치", hash_match("f744566b", full) is True))
    cases.append(("해시 불일치", hash_match("d7b57f32", full) is False))
    try:
        hash_match("f74456", full)
        cases.append(("해시 6자 판정불가", False))
    except Undetermined:
        cases.append(("해시 6자 판정불가", True))
    cases.append(("테이블.열 토큰은 경로 아님", evidence_paths({"evidence": "db.t_x.ID 136 · t_y.json"}) == []))
    cases.append(("구분자 있는 경로는 경로", evidence_paths({"evidence": "근거 _tmp/otest1/x.json 참조"}) == ["_tmp/otest1/x.json"]))
    with tempfile.TemporaryDirectory() as kd:
        kv_real = os.path.join(kd, "acceptance_criteria_prev.json")
        open(kv_real, "w").write("{}")
        kv_ct = type("KvCt", (), {"root": kd, "evidence_bases": []})()
        kv_ok = evidence_paths({"evidence": f"기준표 C196_CRITERIA={kv_real} 대조"})
        cases.append(("KEY=<실존 경로> → 값만 추출·실존 PASS",
                      kv_ok == [kv_real] and all(resolve(t, os.path.join(kd, "r.json"), kv_ct) for t in kv_ok)))
        kv_bad = evidence_paths({"evidence": "C196_CRITERIA=/nonexistent/acg_selftest/criteria.json"})
        cases.append(("KEY=<부재 경로> → 값만 추출·부재 FAIL",
                      kv_bad == ["/nonexistent/acg_selftest/criteria.json"]
                      and not any(resolve(t, os.path.join(kd, "r.json"), kv_ct) for t in kv_bad)))
    cases.append(("파일명 규약", bool(NAME_RE.match("ac_records_b2.json")) and bool(NAME_RE.match("ac_records_b2_blocked.json"))
                  and not NAME_RE.match("ac_records.json") and not NAME_RE.match("ac_records_b1.pre_x.json")))
    with tempfile.TemporaryDirectory() as td:
        sd = os.path.join(td, "sess")
        root = os.path.join(td, "cyc", "otest")
        os.makedirs(os.path.join(sd, "plans"))
        os.makedirs(os.path.join(root, "otest-1"))
        art = os.path.join(td, "app.bin")
        open(art, "wb").write(b"v1")
        crit = {"created_at": "2000-01-01T00:00:00+09:00",
                "record_contract": {"root": root, "build_sources": {"server": art}},
                "criteria": [{"id": "AC-001", "batches": [1]},
                             {"id": "AC-002", "batches": [1], "na_allowed": True},
                             {"id": "AC-003", "batches": [1], "build_axes": ["server"]},
                             {"id": "AC-004", "batches": [1], "item_crud": True},
                             {"id": "AC-005", "batches": [1], "gate_kind": "canary"}]}
        json.dump(crit, open(criteria_path(sd), "w"))
        ct = Contract(sd)
        ev = os.path.join(root, "otest-1", "e.txt")
        open(ev, "w").write("x")
        md5 = hashlib.md5(b"v1").hexdigest()
        rec = {"batch": 1, "build": {"server": md5}, "records": [
            {"id": "AC-001", "status": "PASS", "evidence": f"근거 {ev}"},
            {"id": "AC-002", "status": "NA", "na_basis": "같은 시각 원문 실행 결과 차집합 0", "evidence": "x"},
            {"id": "AC-003", "status": "PASS", "evidence": "x"},
            {"id": "AC-004", "status": "PASS", "write_log": [ev], "evidence": "x"}]}
        rp = os.path.join(root, "otest-1", "ac_records_b1.json")
        json.dump(rec, open(rp, "w"))
        cases.append(("규약 위치·형식 기록 PASS", judge(ct, "AC-001")[0] == 0))
        r2 = judge(ct, "AC-002")
        cases.append(("NA+근거+na_allowed → PASS(N/A)", r2[0] == 0 and r2[1].startswith("PASS(N/A)")))
        cases.append(("현재 판(산출물 md5 실시간) 일치 PASS", judge(ct, "AC-003")[0] == 0))
        cases.append(("item_crud write_log 실존 PASS", judge(ct, "AC-004")[0] == 0))
        cases.append(("카나리 FAIL", judge(ct, "AC-005")[0] == 1))
        open(art, "wb").write(b"v2")
        ct2 = Contract(sd)
        cases.append(("산출물 재빌드 → 옛 기록 현재 판 아님", judge(ct2, "AC-003")[0] == 1))
        cases.append(("validate 정상 기록 위반 0", validate(ct, rp, rec) == []))
        bad = json.loads(json.dumps(rec))
        bad["records"][0]["status"] = "조건부 PASS"
        cases.append(("'조건부 PASS' status 위반", any("허용 어휘" in e for e in validate(ct, rp, bad))))
        bad2 = json.loads(json.dumps(rec))
        bad2["records"][1]["na_basis"] = ""
        cases.append(("NA 근거 없음 위반", any("na_basis" in e for e in validate(ct, rp, bad2))))
        cases.append(("규약 밖 위치 위반", any("위치 위반" in e for e in validate(ct, os.path.join(td, "x", "ac_records_b1.json"), rec))))
        sib = os.path.join(td, "proj", "cyc")
        os.makedirs(sib)
        json.dump({"batch": 1, "records": [{"id": "AC-001", "status": "FAIL"}]}, open(os.path.join(sib, "ac_records_b1.json"), "w"))
        ct3 = Contract(sd)
        try:
            judge(ct3, "AC-001")
            cases.append(("형제 프로젝트 아래 같은 이름 폴더의 기록 → 판정불가", False))
        except Undetermined as e:
            cases.append(("형제 프로젝트 아래 같은 이름 폴더의 기록 → 판정불가", "규약 밖" in str(e)))
        json.dump({"criteria": []}, open(criteria_path(sd), "w"))
        try:
            Contract(sd)
            cases.append(("record_contract 없음 → NoContract", False))
        except NoContract:
            cases.append(("record_contract 없음 → NoContract", True))
    cases.append(("사본 판정기 auto_script 탐지",
                  bool(LOCAL_GATE_RE.search('python3 "${GOAL_SESSION_DIR:-/x}/c196_gate.py" item AC-1'))
                  and bool(LOCAL_GATE_RE.search("python3 /h/.claude/session-env/abc/c195_gate.py item AC-1"))
                  and not LOCAL_GATE_RE.search("python3 /p/.claude/skills/otest_make/scripts/ac_gate.py --session x item AC-1")))
    for name, ok in cases:
        if not quiet:
            print(f"{'PASS' if ok else 'FAIL'}\t{name}")
    return 0 if all(ok for _, ok in cases) else 1


def main(argv):
    global VERBOSE
    if "-v" in argv:
        VERBOSE = True
        argv = [a for a in argv if a != "-v"]
    sess = None
    if "--session" in argv:
        i = argv.index("--session")
        if i + 1 >= len(argv):
            print("--session 값 없음", file=sys.stderr)
            return 3
        sess = argv[i + 1]
        argv = argv[:i] + argv[i + 2:]
    if not argv:
        print(__doc__, file=sys.stderr)
        return 3
    cmd = argv[0]
    if cmd == "selftest":
        return selftest()
    if cmd == "hook":
        try:
            return hook_main(sys.stdin.read())
        except Exception as e:  # hook 자체 오류는 통과(판정 시점 검증이 남는다) — 기록만
            print(f"[ac_gate hook] 내부 오류 {type(e).__name__}: {e}", file=sys.stderr)
            return 0
    try:
        ct = Contract(session_dir(sess))
        if cmd == "item" and len(argv) >= 2:
            rc, msg = judge(ct, argv[1].strip())
            print(f"{argv[1].strip()}\t{msg}")
            return rc
        if cmd == "all":
            worst = 0
            for ac in sorted(ct.crit):
                try:
                    rc, msg = judge(ct, ac)
                except Undetermined as e:
                    rc, msg = 3, f"판정불가 — {e}"
                print(f"{ac}\t{msg}")
                worst = max(worst, rc)
            return worst
        if cmd == "contract":
            print(contract_text(ct))
            return 0
        if cmd == "stamp":
            axes = list(ct.build_sources)
            if "--axes" in argv:
                axes = [a for a in argv[argv.index("--axes") + 1].split(",") if a]
            print(json.dumps({a: ct.current_build(a) for a in axes}, ensure_ascii=False))
            return 0
        if cmd == "validate-record" and len(argv) >= 2:
            path = argv[1]
            src = path
            if "--content-file" in argv:
                src = argv[argv.index("--content-file") + 1]
            try:
                d = json.load(open(src, encoding="utf-8"))
            except Exception as e:
                print(f"위반\tJSON 판독 실패: {e}")
                return 1
            errs = validate(ct, path, d)
            for e in errs:
                print(f"위반\t{e}")
            if not errs:
                print("정상")
            return 1 if errs else 0
        print("사용법은 파일 머리말 참조", file=sys.stderr)
        return 3
    except NoContract as e:
        print(f"계약 없음: {e} — 이 기준표는 ac_gate 대상이 아니다", file=sys.stderr)
        return 4
    except Undetermined as e:
        print(f"판정불가: {e}", file=sys.stderr)
        return 3


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
