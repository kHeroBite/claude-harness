# goal.json 새 항목의 판정기 작성 가정(HEAD 검사·바이너리 ASCII 단독 검색·근거 필드 누락)을 점검하는 lint (F-GOALAS-10)
#
# 사용: python3 -I goal_judge_lint.py <디스크 goal.json 경로> <세션 디렉터리>  (stdin = 새 goal.json 내용)
# 종료 코드: 0 = 통과(경고는 stdout 의 "WARN " 줄), 1 = 차단(stdout 에 사유 줄), 그 외 = lint 자체 오류(hook 은 경고만).
#
# 적용 범위(소급 금지): ★새로 추가되는 항목에만★ 적용한다.
#   - 디스크 goal.json 이 없으면 새 계약 → 전 항목이 새 항목이다.
#   - 디스크 goal.json 이 있으면 디스크 acceptance 에 없던 id 의 항목만 새 항목이다(잠김 여부 무관).
#     이미 기록된 항목(잠긴 계약의 기존 항목 포함)은 다시 보지 않는다.
#   - 디스크 goal.json 을 읽지 못하면(깨진 JSON 등) 새 항목을 가릴 수 없으므로 검사하지 않고 경고만 낸다.
#   - status 가 blocked·blocked_by 인 항목, auto_script 가 문자열이 아닌 항목은 보지 않는다.
#
# 규칙(사이클214 R4 — D-5·D-6·D-8·D-9 실측):
#   R-HEAD  auto_script 에 curl 의 HEAD 요청(-I·-sfI 류 묶음, --head, -X HEAD, --request HEAD)이 있으면
#           judge_basis(공백 제외 10자 이상 — 서버가 그 경로에 HEAD 를 지원한다는 실측 근거)가 있어야 한다.
#           D-6: 실측은 GET 이었는데 판정기를 HEAD 로 써서 의도한 구현으로도 PASS 불가였다.
#   R-BIN   auto_script 가 부르는 판정 스크립트(.py)가 .dll·.exe 를 대상으로 바이너리를 읽어(rb·read_bytes)
#           b"..." in 형태로 바이트 검색을 하는데 utf-16 병행이 없으면 차단한다.
#           D-9: .NET 문자열 상수는 UTF-16LE 로 저장되는데 ASCII 바이트로만 찾아 PASS 불가였다.
#           판정 스크립트를 찾지 못하거나 읽지 못하면 경고만 낸다.
#   R-REF   판정 스크립트 호출형(auto_script 에 "item <ID>" 또는 .dll·.exe 대상) 새 항목은
#           plan_ref(세션 기준 또는 절대 경로 "파일:행", 파일 실재·1 ≤ 행 ≤ 줄 수)와
#           pass_proof(세션 기준 또는 절대 경로, 파일 실재, 내용에 항목 id 와 "rc=0")가 있어야 한다.
#           D-5·D-8: 구현 형태·시그니처를 계획서 확인 없이 가정했다. 근거 위치와 의도한 구현 모의 PASS 기록을 남기게 한다.
#
# 한계(숨기지 않음): pass_proof 의 진위(모의를 실제로 돌렸는지)·시그니처 추측의 의미는 기계로 가리지 못한다.
#   셸 변수 간접화로 HEAD 플래그·스크립트 경로를 숨기면 문자열 판정은 놓친다.
import json
import os
import re
import shlex
import sys

BLOCKED_STATUS = ("blocked", "blocked_by")
BIN_EXT_RE = re.compile(r"\.(?:dll|exe)\b", re.I)
ITEM_CALL_RE = re.compile(r"(?:^|\s)item\s+[\"']?[A-Za-z][A-Za-z0-9_]*-?[0-9][A-Za-z0-9_-]*")
CURL_RE = re.compile(r"(?:^|[\s;&|(`])curl(?:\.exe)?(?=\s)")
HEAD_LONG_RE = re.compile(r"(?:^|\s)--head(?=\s|$)")
HEAD_REQ_RE = re.compile(r"(?:^|\s)(?:-X|--request)(?:\s+|=)[\"']?HEAD\b", re.I)
HEAD_SHORT_RE = re.compile(r"(?:^|\s)-[A-Za-z0-9]*I[A-Za-z0-9]*(?=\s|$)")
SESSION_VAR_RE = re.compile(r"\$\{GOAL_SESSION_DIR(?::-[^}]*)?\}|\$GOAL_SESSION_DIR\b")
BIN_READ_RE = re.compile(r"""open\s*\([^)]*['"][rwa+]*b[rwa+]*['"]|\.read_bytes\s*\(|mmap\.mmap\s*\(""")
BYTES_IN_RE = re.compile(r"""\b[bB][rR]?(?:"[^"\n]*"|'[^'\n]*')\s+(?:not\s+)?in\b""")
UTF16_RE = re.compile(r"utf[-_ ]?16", re.I)
PROOF_RC0_RE = re.compile(r"rc\s*=\s*0(?![0-9])")


def _load_json(text):
    try:
        return json.loads(text)
    except Exception:
        return None


def _items(doc):
    acc = doc.get("acceptance") if isinstance(doc, dict) else None
    if not isinstance(acc, list):
        return []
    return [x for x in acc if isinstance(x, dict)]


def _sub_session_var(s, sd):
    """${GOAL_SESSION_DIR}·$GOAL_SESSION_DIR·폴백형 ${GOAL_SESSION_DIR:-${CLAUDE_CONFIG_DIR:-…}/…} (중첩 중괄호)를 sd 로 바꾼다."""
    out, i, key = [], 0, "${GOAL_SESSION_DIR"
    while True:
        j = s.find(key, i)
        if j < 0:
            out.append(s[i:])
            break
        out.append(s[i:j])
        k, depth = j + 2, 1          # '${' 다음부터 짝 맞는 '}' 까지
        while k < len(s) and depth:
            if s.startswith("${", k):
                depth += 1
                k += 2
                continue
            if s[k] == "}":
                depth -= 1
            k += 1
        if depth:                     # 짝이 안 맞으면 원문 유지
            out.append(s[j:])
            break
        out.append(sd)
        i = k
    return SESSION_VAR_RE.sub(lambda _m: sd, "".join(out))


def _resolve(path, sd):
    """세션 변수 치환 + 상대 경로는 세션 디렉터리 기준."""
    p = _sub_session_var(path, sd)
    p = os.path.expanduser(p)
    if not os.path.isabs(p):
        p = os.path.join(sd, p)
    return os.path.normpath(p)


def _uses_head(script):
    if not CURL_RE.search(" " + script):
        return False
    return bool(HEAD_LONG_RE.search(script) or HEAD_REQ_RE.search(script) or HEAD_SHORT_RE.search(script))


_PY_INTERP_RE = re.compile(r"^python[0-9.]*$")
_SH_INTERP_RE = re.compile(r"^(ba|da|z)?sh$")
_CMD_SEP = (";", "&&", "||", "|", "&", "(", "{", "!")


def _judge_scripts(script, sd):
    """auto_script 가 실제로 실행하는 .py 판정 스크립트 경로(해석 후) 목록.

    python 해석기 바로 뒤(옵션 제외)의 첫 인자와 명령 위치의 .py 만 판정 스크립트로 본다.
    판정 스크립트에 넘기는 인자(--target x.py 등)의 .py 는 제외한다. sh -c '...' 는 안쪽 문자열을 다시 푼다.
    """
    try:
        toks = shlex.split(script, posix=True)
    except ValueError:
        toks = re.findall(r"""[^\s"']+\.py\b|"[^"]+\.py"|'[^']+\.py'""", script)
        toks = [t.strip("\"'") for t in toks]
        return [_resolve(t, sd) for t in toks if t.endswith(".py")]
    out = []
    at_cmd = True
    for i, t in enumerate(toks):
        if t in _CMD_SEP:
            at_cmd = True
            continue
        base = os.path.basename(t)
        if _PY_INTERP_RE.match(base):
            j = i + 1
            while j < len(toks) and toks[j] not in _CMD_SEP:
                a = toks[j]
                if a in ("-c", "-m"):
                    break
                if a in ("-W", "-X"):
                    j += 2
                    continue
                if a.startswith("-"):
                    j += 1
                    continue
                if a.endswith(".py"):
                    out.append(_resolve(a, sd))
                break
        elif _SH_INTERP_RE.match(base):
            for k in range(i + 1, len(toks) - 1):
                if toks[k] in _CMD_SEP:
                    break
                if toks[k] == "-c":
                    out.extend(_judge_scripts(toks[k + 1], sd))
                    break
        elif at_cmd and t.endswith(".py"):
            out.append(_resolve(t, sd))
        at_cmd = False
    return out


def _bin_ascii_only(text):
    """바이너리를 읽어 바이트 리터럴로 in 검색을 하는데 utf-16 병행이 없는가."""
    return bool(BIN_READ_RE.search(text) and BYTES_IN_RE.search(text) and not UTF16_RE.search(text))


def _check_plan_ref(v, sd):
    refs = v if isinstance(v, list) else [v]
    if not refs or not all(isinstance(r, str) and r.strip() for r in refs):
        return "plan_ref 없음"
    for r in refs:
        m = re.match(r"^(.+):(\d+)\s*$", r.strip())
        if not m:
            return "plan_ref 형식이 '파일:행' 이 아님(%s)" % r
        p, ln = _resolve(m.group(1), sd), int(m.group(2))
        if not os.path.isfile(p):
            return "plan_ref 파일 없음(%s)" % p
        try:
            with open(p, encoding="utf-8", errors="replace") as f:
                n = sum(1 for _ in f)
        except OSError as e:
            return "plan_ref 파일 읽기 실패(%s: %s)" % (p, e)
        if not 1 <= ln <= n:
            return "plan_ref 행 번호 범위 밖(%s:%d, 파일 %d줄)" % (p, ln, n)
    return None


def _check_pass_proof(v, iid, sd):
    if not isinstance(v, str) or not v.strip():
        return "pass_proof 없음"
    p = _resolve(v.strip(), sd)
    if not os.path.isfile(p):
        return "pass_proof 파일 없음(%s)" % p
    try:
        with open(p, encoding="utf-8", errors="replace") as f:
            body = f.read(1 << 20)
    except OSError as e:
        return "pass_proof 파일 읽기 실패(%s: %s)" % (p, e)
    if iid not in body:
        return "pass_proof 에 항목 id(%s) 기재 없음(%s)" % (iid, p)
    if not PROOF_RC0_RE.search(body):
        return "pass_proof 에 'rc=0' 기재 없음(%s)" % p
    return None


def main():
    disk_path, sd = sys.argv[1], sys.argv[2]
    new_doc = _load_json(sys.stdin.read())
    if not isinstance(new_doc, dict):
        return 0
    if os.path.exists(disk_path) and os.path.getsize(disk_path) > 0:
        try:
            with open(disk_path, encoding="utf-8") as f:
                old_doc = json.load(f)
        except Exception:
            print("WARN 디스크 goal.json 을 읽지 못해 새 항목을 가릴 수 없음 — F-GOALAS-10 검사 생략")
            return 0
        old_ids = {str(x.get("id")) for x in _items(old_doc)}
        targets = [x for x in _items(new_doc) if str(x.get("id")) not in old_ids]
    else:
        targets = _items(new_doc)

    blocks, warns = [], []
    for it in targets:
        iid = str(it.get("id", "?"))
        if str(it.get("status", "open")) in BLOCKED_STATUS:
            continue
        script = it.get("auto_script")
        if not isinstance(script, str) or not script.strip():
            continue
        # R-HEAD
        if _uses_head(script):
            jb = it.get("judge_basis")
            if not (isinstance(jb, str) and len(re.sub(r"\s", "", jb)) >= 10):
                blocks.append("%s: curl HEAD 요청(-I·--head 류)인데 judge_basis 없음 → judge_basis 에 그 경로가 HEAD 를 "
                              "지원한다는 실측 근거(10자 이상)를 적거나, 실측과 같은 GET 으로 판정하십시오" % iid)
        # R-BIN
        targets_bin = bool(BIN_EXT_RE.search(script))
        for sp in _judge_scripts(script, sd):
            try:
                with open(sp, encoding="utf-8", errors="replace") as f:
                    body = f.read()
            except OSError:
                warns.append("%s: 판정 스크립트를 읽지 못해 바이너리 인코딩 점검 생략(%s)" % (iid, sp))
                continue
            if (targets_bin or BIN_EXT_RE.search(body)) and _bin_ascii_only(body):
                blocks.append("%s: 판정 스크립트(%s)가 .dll·.exe 를 바이트로 읽어 ASCII 리터럴(b\"…\" in)로만 검색함 → "
                              ".NET 문자열 상수는 UTF-16LE 로 저장됩니다. s.encode(\"utf-16-le\") 검색을 병행하십시오" % (iid, sp))
        # R-REF
        if ITEM_CALL_RE.search(script) or targets_bin:
            why = [w for w in (_check_plan_ref(it.get("plan_ref"), sd), _check_pass_proof(it.get("pass_proof"), iid, sd)) if w]
            if why:
                blocks.append("%s: 판정 스크립트 호출형 항목의 근거 필드 결함 — %s → plan_ref 에 계획서 근거 '파일:행', "
                              "pass_proof 에 '%s … rc=0'(의도한 구현 모의에서 PASS)을 적은 파일 경로를 넣으십시오"
                              % (iid, "; ".join(why), iid))

    for w in warns:
        print("WARN " + w)
    if blocks:
        for b in blocks:
            print("BLOCK " + b)
        return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception as e:  # lint 자체 오류 — hook 은 경고만 내고 통과시킨다(fail-open)
        print("ERROR goal_judge_lint 내부 오류: %r" % (e,))
        sys.exit(3)
