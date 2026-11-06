#!/usr/bin/env python3
# 팀원의 실업무 DB UPDATE/DELETE 직전에 이번 세션 스냅샷 파일 존재를 요구하는 PreToolUse 판정 코어 (L-1200)
"""snapshot_gate.py — PreToolUse_snapshot_gate.sh 가 호출한다.

입력: stdin = PreToolUse hook JSON. env:
  SG_SESSION_DIR  리드 세션 디렉토리 (session-env/<LEAD>)  — 필수
  SG_AGENT        팀원 이름 (로그용)
  SG_MODE         block | warn  (기본 block)

판정 대상 텍스트:
  - mcp__mysql__execute / mcp__mysql__query : tool_input.sql|query 전체 (항상 DB 문맥)
  - Bash / mcp__oio__bash_exec : tool_input.command|cmd 본문
      + ★실행되는★ 스크립트 파일(python X.py / mysql < X.sql / source X.sql / bash|sh|source|. X.sh / ./X.sh)
        중 실존·512KB 이하인 것의 내용(1단계만).
        .py 는 줄 첫머리 import pymysql|MySQLdb|mysql(.connector) 가 있을 때만 DB 문맥으로 본다.
        .py 는 docstring·단독 문자열 문·# 주석을 지운 실행 코드만 검사한다(사이클194 C-24①, ast/tokenize).
        .py 가 시나리오 러너(본문에 delete_sql + 옆에 scenarios/*.json)면 시나리오 delete_sql 중 표식 조건
        (WHERE 가 %s·{marker}·{rid} 참조 + 표식이 WHERE/args 에 있음 + OR/NOT 없음)이 없는 DELETE 를 대상에 더한다(C-24②).
        (grep/cat 등 언급만 하는 명령·SQL 픽스처 문자열만 품은 테스트 파일 오차단 — 2026-10-08 실측 2건 — 방지)
        .sh 는 ★명령 위치의 mysql/mariadb 호출 줄★(앞에 따옴표·# 없음, 줄 첫머리 또는 | && ; $( 뒤)과
        그 줄이 여는 heredoc 본문만 추려 검사한다. 시험 하네스 .sh 의 JSON·따옴표 문자열 속 SQL 픽스처는
        따옴표 뒤라 제외된다(2026-10-08 오차단 회귀 방지).
    ⇒ DB 문맥 표식(pymysql·mysql.connector·MySqlConnector·mysql/mariadb CLI 옵션)이 하나라도 있어야 검사한다.
       (sqlite 등 로컬 DB·일반 문자열의 UPDATE 는 대상 아님 — 오차단 방지)
  - 문장 패턴: UPDATE <table> ... SET  /  DELETE FROM <table>  (대소문자 무시)

통과(오차단 금지):
  - INSERT / SELECT 만 있는 경우 (패턴 불일치)
  - 테스트 표식 행 한정 문장: 문장 창(문장 시작 ~ 다음 ';' 또는 '"' 또는 600자)에서 SQL 주석을 지운 뒤
    ★WHERE 구간★에 `= '…[cNNNtest]…'` 또는 `LIKE '…[cNNNtest]…'` 조건이 있고, WHERE 구간(문자열 리터럴 밖)에
    OR / XOR / NOT / || 가 하나도 없을 때만 면제한다. 주석·SET 값·WHERE 밖 문자열 속 표식은 인정하지 않는다.
    WHERE 없는 문장은 면제 불가.
  - 이번 세션 스냅샷 파일이 그 문장을 덮는 경우 (아래 규약)

스냅샷 규약(정본):
  경로: session-env/<LEAD>/evidence/snapshot_*.json   (리드 세션 = 이번 사이클)
  형식: {"table": "cspms.t_Ticket", "where": "TicketID=19772", "rows": [ {...}, ... ], "taken_at": "ISO8601"}
        - table    : 스키마.테이블 또는 테이블 (비교는 마지막 세그먼트·소문자)
        - rows     : list (대상 행 SELECT 결과. 0행이면 [] — "없었다"도 원값이다)
        - taken_at : ISO8601. 유효 범위 = [파이프라인 시작 시각, now+60s].
                     파이프라인 시작 시각 = session-env/<LEAD>/pipeline_start_time (epoch 정수). 없으면 now-6h.
        - where    : 실행할 문장의 WHERE 를 그대로 옮겨 적는다. 비교는 정규화(소문자·백틱 제거·공백 1칸·끝 ';' 제거·
                     ORDER BY / LIMIT 앞까지) 후 일치. "*" 는 테이블 전체 스냅샷(모든 문장을 덮음).
                     WHERE 없는 문장은 "*" 스냅샷만 덮는다.
  여러 테이블·여러 조건이면 파일을 문장마다 하나씩 둔다.

출력: 차단 시 hookSpecificOutput deny JSON (warn 모드는 additionalContext). 통과 시 무출력.
로그: <SG_SESSION_DIR>/logs/snapshot_gate.log 1줄.
내부 오류 → 무출력 exit 0 (fail-open — 활성 hook 이 전 세션을 막지 않도록).
"""
import ast
import datetime
import glob
import io
import json
import os
import re
import sys
import time
import tokenize

DB_CTX = re.compile(r"pymysql|mysql\.connector|MySqlConnector|MySql\.Data|\b(?:mysql|mariadb)(?:\.exe)?\s+-", re.I)
STMT = re.compile(r"\b(?:UPDATE\s+(?:LOW_PRIORITY\s+|IGNORE\s+)*([`\w.]+)\s+(?:[`\w]+\s+)?SET\b|DELETE\s+(?:LOW_PRIORITY\s+|QUICK\s+|IGNORE\s+)*FROM\s+([`\w.]+))", re.I)
# 표식 조건: WHERE 구간 안의  = '…[cNNNtest]…'  또는  LIKE '…[cNNNtest]…'  ( != <= >= <> 는 제외)
MARK_COND = re.compile(r"(?:(?<![!<>])=|\bLIKE)\s*'[^']*\[c\d+test\][^']*'", re.I)
# WHERE 구간에서 표식 조건의 한정 효과를 무너뜨리는 연산자(문자열 리터럴 밖)
WEAKEN = re.compile(r"\b(?:OR|XOR|NOT)\b|\|\|", re.I)
SQL_COMMENT = re.compile(r"/\*.*?\*/|--[^\n]*|#[^\n]*", re.S)
SQL_LIT = re.compile(r"'(?:[^'\\]|\\.)*'")
WHERE_KW = re.compile(r"\bWHERE\b", re.I)
WHERE_END = re.compile(r"\b(?:ORDER\s+BY|LIMIT)\b", re.I)
# 스크립트 파일은 ★실행되는★ 것만 본다 — python <file.py> / mysql ... < file.sql / source file.sql
#   (grep·cat 처럼 파일을 언급만 하는 명령까지 스캔하면 SQL 픽스처를 품은 테스트 파일 조회가 막힌다 — 2026-10-08 실측)
EXEC_FILE = re.compile(r"\bpython[0-9.]*(?:\.exe)?\s+(?:-[A-Za-z]+\s+)*([\w./~-]+\.py)\b"
                       r"|<\s*([\w./~-]+\.sql)\b|\bsource\s+([\w./~-]+\.sql)\b"
                       r"|(?:\b(?:bash|sh|source)|(?:^|(?<=[\s;&|(]))\.)\s+(?:-[A-Za-z]+\s+)*([\w./~-]+\.sh)\b"
                       r"|(?:^|(?<=[;&|(\n]))\s*(\./[\w./~-]+\.sh)\b", re.M)
# 파일 내용의 DB 문맥은 ★줄 첫머리 import★ 또는 .sql 파일 자체로만 인정한다(문자열 픽스처 속 'pymysql' 오탐 방지)
DB_CTX_FILE = re.compile(r"^\s*(?:import|from)\s+(?:pymysql|MySQLdb|mysql\.connector|mysql)\b", re.M)
# .sh 안 명령 위치 mysql/mariadb 호출 줄(앞에 따옴표·# 없음)
SH_DB_LINE = re.compile(r"^\s*(?:[^#'\"\n]*?(?:\||&&|;|\$\()\s*)?(?:mysql|mariadb)(?:\.exe)?\s+-")
HEREDOC = re.compile(r"<<(-?)\s*['\"]?(\w+)['\"]?")
MAX_FILE = 512 * 1024
FALLBACK_AGE = 6 * 3600
FUTURE_SKEW = 60


def _norm(t):
    t = (t or "").replace("`", "").strip().lower()
    return t.rsplit(".", 1)[-1]


def _norm_where(w):
    w = (w or "").replace("`", "").lower()
    m = WHERE_END.search(w)
    if m:
        w = w[:m.start()]
    w = re.sub(r"\s+", " ", w).strip()
    while w.endswith(";"):
        w = w[:-1].rstrip()
    return w


def _sh_db_lines(text):
    """.sh 내용에서 명령 위치 mysql/mariadb 호출 줄 + 그 줄이 여는 heredoc 본문만 추린다."""
    lines = text.splitlines()
    out = []
    i = 0
    while i < len(lines):
        ln = lines[i]
        i += 1
        if not SH_DB_LINE.match(ln):
            continue
        out.append(ln)
        h = HEREDOC.search(ln)
        if not h:
            continue
        strip_tabs, term = h.group(1) == "-", h.group(2)
        while i < len(lines):
            body = lines[i]
            i += 1
            if (body.lstrip("\t") if strip_tabs else body) == term:
                break
            out.append(body)
    return "\n".join(out)


def _py_code_only(body):
    """[사이클194 C-24①] .py 본문에서 docstring·단독 문자열 문(ast Expr(str))과 # 주석을 지운 실행 코드만 돌려준다.
    설명문 속 'DELETE FROM …' 예시가 실행 DELETE 로 오인돼 차단되던 것을 막는다. 문법 오류면 원문 그대로(fail-closed)."""
    try:
        tree = ast.parse(body)
    except Exception:
        return body
    lines = body.splitlines(keepends=True)
    kill = set()
    for n in ast.walk(tree):
        if isinstance(n, ast.Expr) and isinstance(getattr(n, "value", None), ast.Constant) \
                and isinstance(n.value.value, str):
            kill.update(range(n.lineno, (getattr(n, "end_lineno", None) or n.lineno) + 1))
    cuts = {}
    try:
        for tok in tokenize.generate_tokens(io.StringIO(body).readline):
            if tok.type == tokenize.COMMENT:
                cuts[tok.start[0]] = tok.start[1]
    except Exception:
        pass
    out = []
    for i, ln in enumerate(lines, 1):
        if i in kill:
            out.append("\n")
        elif i in cuts:
            out.append(ln[:cuts[i]] + "\n")
        else:
            out.append(ln)
    return "".join(out)


SCEN_DEL = re.compile(r"\bDELETE\s+(?:LOW_PRIORITY\s+|QUICK\s+|IGNORE\s+)*(?:[`\w]+\s+)?FROM\s+([`\w.]+)", re.I)
MARK_REF = re.compile(r"\{(?:marker|rid)\}")


def _scenario_deletes(py_path, body, cmd):
    """[사이클194 C-24②] 실행되는 .py 가 시나리오 JSON 의 delete_sql 을 변수로 실행하는 러너면(본문에 'delete_sql' + 옆에 scenarios/*.json)
    시나리오의 delete_sql 중 ★표식 조건이 없는★ 것을 (테이블, 정규화 WHERE) 대상으로 돌려준다.
    표식 조건 = WHERE 가 있고, WHERE 가 자리표시자(%s) 또는 {marker}/{rid} 를 참조하며, 표식({marker}/{rid})이 WHERE 나 args 에 있고,
    WHERE(리터럴 밖)에 OR/XOR/NOT/|| 가 없다. 명령에 시나리오 이름(파일명 줄기)이 있으면 그 시나리오만, 없으면 전부 본다."""
    if "delete_sql" not in body:
        return []
    files = sorted(glob.glob(os.path.join(os.path.dirname(os.path.abspath(py_path)), "scenarios", "*.json")))
    if not files:
        return []
    picked = [f for f in files if re.search(r"(?<![\w-])%s(?![\w-])" % re.escape(os.path.splitext(os.path.basename(f))[0]), cmd)]
    res = []

    def walk(o):
        if isinstance(o, dict):
            ds = o.get("delete_sql")
            if isinstance(ds, str) and ds.strip():
                yield ds, o.get("args")
            for v in o.values():
                yield from walk(v)
        elif isinstance(o, list):
            for v in o:
                yield from walk(v)

    for f in picked or files:
        try:
            with open(f, "r", encoding="utf-8") as fh:
                d = json.load(fh)
        except Exception:
            continue
        for ds, args in walk(d):
            m = SCEN_DEL.search(ds)
            if not m:
                continue
            wr, wm = _where_part(_strip_comments(ds))
            marked = (wr is not None and not WEAKEN.search(wm)
                      and ("%s" in wr or MARK_REF.search(wr))
                      and (MARK_REF.search(wr) or MARK_REF.search(json.dumps(args or [], ensure_ascii=False))))
            if not marked:
                res.append((_norm(m.group(1)), _norm_where(wr) if wr is not None else None))
    return res


# [사이클206 NEW] python -c 인라인 코드 분리 — 셸 명령 전체에 DB_CTX 를 걸면 python -c 코드 안 ★문자열 리터럴★의
#   "mysql -e …"·"pymysql" 언급과 시험용 SQL("UPDATE t_user SET pw=1")이 실제 DB 쓰기로 오인됐다(2026-10-25 odev-6 실측 BLOCK).
#   인라인 코드는 .py 파일과 같은 기준으로 본다: docstring·주석을 지운 코드에 줄 첫머리 import pymysql|MySQLdb|mysql(.connector)
#   가 있거나, 프로세스 실행(subprocess·os.system·os.popen·os.exec*·pty.spawn)과 mysql/mariadb CLI 표지가 함께 있을 때만 DB 문맥.
#   ★셸 쪽(코드를 뺀 나머지)에 DB 표지가 있으면 코드도 종전대로 항상 DB 문맥★(python -c 'print("UPDATE …")' | mysql … 생성 SQL 파이프).
#   코드 경계를 확실히 못 찾으면(shlex 실패·원문에서 따옴표 감싼 코드를 못 찾음) 종전대로 명령 전체를 DB_CTX 로 본다(fail-closed).
PY_EXEC_CALL = re.compile(r"\b(?:subprocess|os\.system|os\.popen|os\.exec\w*|os\.spawn\w*|pty\.spawn|commands\.)")
PY_BIN = re.compile(r"^python[0-9.]*(?:\.exe)?$")


class _PyInlineCtx:
    """python -c 코드용 DB 문맥 판정자 — re 패턴처럼 .search(text) 만 제공한다."""
    @staticmethod
    def search(code):
        if DB_CTX_FILE.search(code):
            return True
        return bool(PY_EXEC_CALL.search(code) and DB_CTX.search(code))


def _split_py_inline(cmd):
    """[(검사 텍스트, 문맥)] — python -c 코드를 셸 나머지와 분리한다. 분리 불확실하면 [(cmd, DB_CTX)] (종전)."""
    if "-c" not in cmd or "python" not in cmd:
        return [(cmd, DB_CTX)]
    try:
        import shlex
        toks = shlex.split(cmd, comments=False, posix=True)
    except Exception:
        return [(cmd, DB_CTX)]
    codes = []
    i = 0
    while i < len(toks):
        if PY_BIN.match(os.path.basename(toks[i])):
            j = i + 1
            while j < len(toks) and toks[j].startswith("-") and toks[j] != "-c" and not toks[j].startswith("-c"):
                j += 1
            if j < len(toks) and toks[j] == "-c" and j + 1 < len(toks):
                codes.append(toks[j + 1])
                i = j + 2
                continue
        i += 1
    if not codes:
        return [(cmd, DB_CTX)]
    rest = cmd
    for code in codes:
        hit = False
        for q in ("'", '"'):
            if q == '"' and any(ch in code for ch in '"\\$`'):
                continue
            if q == "'" and "'" in code:
                continue
            raw = q + code + q
            if raw in rest:
                rest = rest.replace(raw, " __PY_INLINE__ ", 1)
                hit = True
                break
        if not hit:
            return [(cmd, DB_CTX)]
    shell_db = bool(DB_CTX.search(rest))
    out = [(rest, DB_CTX)]
    for code in codes:
        body = _py_code_only(code)
        out.append((body, None if shell_db else _PyInlineCtx))
    return out


def _texts(tool, ti, extra=None):
    """[(검사 텍스트, DB 문맥 정규식 또는 None=항상 DB 문맥)] — extra 가 주어지면 시나리오 delete_sql 무표식 대상을 덧붙인다(C-24②)"""
    if tool.startswith("mcp__mysql__"):
        return [(str(ti.get("sql") or ti.get("query") or ""), None)]
    cmd = str(ti.get("command") or ti.get("cmd") or "")
    out = _split_py_inline(cmd)
    cwd = ti.get("working_dir") or ti.get("workdir") or ti.get("cwd") or os.environ.get("CLAUDE_PROJECT_DIR") or ""
    for m in EXEC_FILE.finditer(cmd):
        tok = m.group(1) or m.group(2) or m.group(3) or m.group(4) or m.group(5)
        if not tok:
            continue
        p = os.path.expanduser(tok)
        if not os.path.isabs(p) and cwd:
            p = os.path.join(cwd, p)
        try:
            if os.path.isfile(p) and os.path.getsize(p) <= MAX_FILE:
                with open(p, "r", encoding="utf-8", errors="replace") as f:
                    body = f.read()
                if tok.endswith(".sh"):
                    out.append((_sh_db_lines(body), None))
                elif tok.endswith(".py"):
                    code = _py_code_only(body)
                    out.append((code, DB_CTX_FILE))
                    if extra is not None and DB_CTX_FILE.search(code):
                        extra.extend(_scenario_deletes(p, code, cmd))
                else:
                    out.append((body, None))
        except Exception:
            pass
    return out


def _where_part(win):
    """주석 제거된 문장 창에서 WHERE 구간(원문, 마스킹본)을 돌려준다. WHERE 없으면 (None, None)."""
    masked = SQL_LIT.sub(lambda m: "'" + "_" * (len(m.group(0)) - 2) + "'", win)
    m = WHERE_KW.search(masked)
    if not m:
        return None, None
    s = m.end()
    e = len(win)
    me = WHERE_END.search(masked, s)
    if me:
        e = me.start()
    return win[s:e], masked[s:e]


def _strip_comments(win):
    # 리터럴 안의 -- # 는 보존하고 리터럴 밖 주석만 지운다
    parts = []
    pos = 0
    for m in SQL_LIT.finditer(win):
        parts.append(SQL_COMMENT.sub(" ", win[pos:m.start()]))
        parts.append(m.group(0))
        pos = m.end()
    parts.append(SQL_COMMENT.sub(" ", win[pos:]))
    return "".join(parts)


def _marked(where_raw, where_masked):
    if where_raw is None:
        return False
    if WEAKEN.search(where_masked):
        return False
    return bool(MARK_COND.search(where_raw))


def _targets(texts):
    """[(테이블, 정규화 WHERE 또는 None)]"""
    res = []
    for tx, ctx in texts:
        if ctx is not None and not ctx.search(tx):
            continue
        for m in STMT.finditer(tx):
            tail = tx[m.start():m.start() + 600]
            cut = len(tail)
            for ch in (";", '"'):
                i = tail.find(ch, 1)
                if i != -1:
                    cut = min(cut, i)
            win = _strip_comments(tail[:cut])
            wr, wm = _where_part(win)
            if _marked(wr, wm):
                continue
            t = _norm(m.group(1) or m.group(2))
            if t:
                res.append((t, _norm_where(wr) if wr is not None else None))
    return sorted(set(res), key=lambda x: (x[0], x[1] or ""))


def _start_epoch(sdir, now):
    try:
        with open(os.path.join(sdir, "pipeline_start_time"), "r", encoding="utf-8") as f:
            v = int(float(f.read().strip()))
        if v > 0:
            return v
    except Exception:
        pass
    return now - FALLBACK_AGE


def _parse_ts(s):
    s = str(s or "").strip()
    if not s:
        return None
    if s.endswith("Z") or s.endswith("z"):
        s = s[:-1] + "+00:00"
    dt = datetime.datetime.fromisoformat(s)
    return dt.timestamp()  # naive 는 로컬 시각으로 해석


def _snapshots(sdir):
    """{테이블: set(정규화 where | '*')} — 신선도·형식이 유효한 것만"""
    now = time.time()
    lo, hi = _start_epoch(sdir, now), now + FUTURE_SKEW
    have = {}
    for p in glob.glob(os.path.join(sdir, "evidence", "snapshot_*.json")):
        try:
            with open(p, "r", encoding="utf-8") as f:
                d = json.load(f)
            if not (isinstance(d, dict) and isinstance(d.get("rows"), list) and d.get("table")):
                continue
            ts = _parse_ts(d.get("taken_at"))
            if ts is None or ts < lo or ts > hi:
                continue
            w = str(d.get("where") or "").strip()
            if not w:
                continue
            w = "*" if w == "*" else _norm_where(w)
            have.setdefault(_norm(str(d["table"])), set()).add(w)
        except Exception:
            continue
    return have


def _covered(have, table, where):
    ws = have.get(table) or set()
    if "*" in ws:
        return True
    return where is not None and where in ws


def main():
    sdir = os.environ.get("SG_SESSION_DIR", "")
    if not sdir or not os.path.isdir(sdir):
        return
    try:
        data = json.loads(sys.stdin.read() or "{}")
    except Exception:
        return
    tool = str(data.get("tool_name") or "")
    ti = data.get("tool_input") or {}
    if not isinstance(ti, dict):
        return
    extra = []
    targets = sorted(set(_targets(_texts(tool, ti, extra)) + extra), key=lambda x: (x[0], x[1] or ""))
    if not targets:
        return
    have = _snapshots(sdir)
    missing = ["%s(where=%s)" % (t, w if w is not None else "없음") for t, w in targets if not _covered(have, t, w)]
    tables = sorted(set(t for t, _ in targets))
    mode = os.environ.get("SG_MODE", "block")
    agent = os.environ.get("SG_AGENT", "?")
    try:
        os.makedirs(os.path.join(sdir, "logs"), exist_ok=True)
        with open(os.path.join(sdir, "logs", "snapshot_gate.log"), "a", encoding="utf-8") as f:
            f.write("%s [%s] agent=%s tool=%s tables=%s missing=%s\n" % (
                time.strftime("%Y-%m-%d %H:%M:%S"), "PASS" if not missing else mode.upper(),
                agent, tool, ",".join(tables), ",".join(missing)))
    except Exception:
        pass
    if not missing:
        return
    ev = os.path.join(sdir, "evidence")
    msg = (
        ('🚫 [snapshot_gate L-1200] 실업무 테이블 UPDATE/DELETE 전 스냅샷이 없습니다: %s\n먼저 대상 행을 SELECT 해 다음 규약 파일로 저장한 뒤 다시 실행하세요.\n  경로: %s/snapshot_<테이블>_<HHMMSS>.json\n  형식: {"table":"스키마.테이블","where":"조건","rows":[SELECT 결과 행...],"taken_at":"ISO8601"}\n  where 는 실행할 문장의 WHERE 를 그대로 옮겨 적는다(대소문자·백틱·공백·끝 \';\'·ORDER BY/LIMIT 은 무시). "*" 는 테이블 전체 스냅샷이며 WHERE 없는 문장은 "*" 만 덮는다.\n  신선도 기준: taken_at 이 이번 파이프라인 시작 이후(시작 기록이 없으면 최근 6시간)이고 현재+60초 이내여야 한다.\n테스트 표식 행만 대상이면 WHERE 에 = 또는 LIKE \'…[c<사이클>test]…\' 조건을 넣고 OR/NOT 을 쓰지 않으면 통과합니다(주석·SET 값 속 표식은 불인정, INSERT 는 대상 아님).\n오탐이면 근거를 team-lead 에 보고한다 — 메인이 판정해 비상 스위치를 쓴다(사람 승인 절차 없음): touch ' + (os.environ.get("HARNESS_HOME") or os.path.expanduser("~/.harness")) + "/current" + '/hooks/DISABLE_SNAPSHOT_GATE')
    ) % (", ".join(missing), ev)
    if mode == "warn":
        out = {"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": msg}}
    else:
        out = {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                      "permissionDecisionReason": msg}}
    sys.stdout.write(json.dumps(out, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
