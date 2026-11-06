# 스킬·hooks·CLAUDE.md 에 반영이 끝난 교훈 섹션을 LESSONS_ARCHIVE.md 로 이관하는 스크립트 (기본 dry-run)
import argparse
import datetime
import glob
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile

sys.dont_write_bytecode = True  # 로컬 모듈 import 시 __pycache__ 생성 방지
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _oi_paths import resolve_project_file, project_root
from _oi_lessons import parse_lessons
from _oi_refs import collect_referenced_lessons

ARCHIVE_NAME = "LESSONS_ARCHIVE.md"
NOTICE_BEGIN = "<!-- ARCHIVE-NOTICE:BEGIN (archive_applied_lessons.py 관리, 수동 수정 금지) -->\n"
NOTICE_END = "<!-- ARCHIVE-NOTICE:END -->\n"
NOTICE_LINES = [
    NOTICE_BEGIN,
    "> **📦 이관된 교훈**: 스킬·hooks·CLAUDE.md 에 반영이 끝난 교훈은 `LESSONS_ARCHIVE.md` 로 옮겼다(삭제 아님, 원문 동일).\n",
    "> L-번호가 이 파일에 없으면 `grep -n \"L-NNN\" LESSONS_ARCHIVE.md` 로 해당 섹션만 찾아 읽는다. **아카이브 전체 Read 금지**(컨텍스트 절약).\n",
    NOTICE_END,
    "\n",
]
NOTICE_INSERT_AFTER_LINE = 8  # 7행 '---' 와 그 뒤 빈 줄 다음에 삽입

ARCHIVE_HEADER = (
    "# LESSONS 아카이브\n"
    "\n"
    "> 이 파일은 `archive_applied_lessons.py` 가 관리한다. 수동 편집 금지.\n"
    ">\n"
    "> - 목적: 스킬·hooks·CLAUDE.md 에 L-번호가 참조되어 반영이 끝난 교훈 섹션을 LESSONS.md 에서 옮겨 보관한다.\n"
    "> - 원문 불변: 각 섹션은 `ARCHIVED` 메타 줄 다음에 원문 바이트 그대로 들어 있다. 삭제가 아니다.\n"
    "> - 읽는 법: 자동 로딩 금지. 전체를 Read 하지 말고 `grep -n \"L-NNN\" LESSONS_ARCHIVE.md` 로 필요한 섹션만 읽는다.\n"
    "> - 복원: `python3 archive_applied_lessons.py --verify --baseline <이관 전 백업>` 으로 원본 재구성을 검증한다.\n"
    "\n"
)

META_RE = re.compile(
    rb"^<!-- ARCHIVED id=(L-\d+) src_lines=(\d+)-(\d+) bytes=(\d+) sha256=([0-9a-f]{64}) at=(\S+?)(?: eol=(\d))? -->$"
)


def sha(b):
    return hashlib.sha256(b).hexdigest()


def config_dir():
    return os.path.expanduser(os.environ.get("CLAUDE_CONFIG_DIR") or "~/.claude")


def atomic_write(path, data):
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(prefix=".tmp_", dir=d)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        try:
            os.chmod(tmp, os.stat(path).st_mode & 0o777)
        except OSError:
            pass
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def split_lines(raw):
    text = raw.decode("utf-8")
    lines = text.splitlines(keepends=True)
    if "".join(lines).encode("utf-8") != raw:
        raise ValueError("splitlines 재결합이 원본과 다르다")
    return text, lines


def parse_archive(raw):
    """-> (records, body 위치 목록 오류). records: dict(id,start,end,bytes,sha,at,eol,body,ok)"""
    records = []
    pos = 0
    n = len(raw)
    while pos < n:
        eol = raw.find(b"\n", pos)
        if eol < 0:
            eol = n
        line = raw[pos:eol]
        m = META_RE.match(line)
        if m:
            size = int(m.group(4))
            body_start = eol + 1
            body = raw[body_start:body_start + size]
            nxt = body_start + size
            flag = int(m.group(7)) if m.group(7) is not None else 1
            if flag == 0 and raw[nxt:nxt + 1] == b"\n":
                nxt += 1
            records.append({
                "id": m.group(1).decode(), "start": int(m.group(2)), "end": int(m.group(3)),
                "bytes": size, "sha": m.group(5).decode(), "at": m.group(6).decode(),
                "eol": flag, "body": body,
                "ok": len(body) == size and sha(body) == m.group(5).decode(),
            })
            pos = nxt
        else:
            pos = eol + 1
    return records


def make_record(sec, lines, at):
    body = "".join(lines[sec["start_line"] - 1:sec["end_line"]]).encode("utf-8")
    flag = 1 if body.endswith((b"\n", b"\r")) else 0
    meta = "<!-- ARCHIVED id=%s src_lines=%d-%d bytes=%d sha256=%s at=%s%s -->\n" % (
        sec["id"], sec["start_line"], sec["end_line"], len(body), sha(body), at,
        "" if flag else " eol=0")
    out = meta.encode("utf-8") + body + (b"" if flag else b"\n")
    return {"id": sec["id"], "sha": sha(body), "bytes": len(body), "lines": sec["end_line"] - sec["start_line"] + 1,
            "blob": out, "sec": sec}


def find_notice(lines):
    b = e = None
    for i, ln in enumerate(lines):
        if ln == NOTICE_BEGIN and b is None:
            b = i
        elif ln == NOTICE_END and b is not None:
            e = i
            break
    return b, e


def strip_notice(lines):
    b, e = find_notice(lines)
    if b is None or e is None:
        return list(lines)
    end = e + 1
    if end < len(lines) and lines[end] == "\n":
        end += 1
    return lines[:b] + lines[end:]


def resolve_inputs(args):
    lessons_path, source = resolve_project_file("LESSONS.md", args.lessons)
    if not lessons_path or not os.path.isfile(lessons_path):
        print("⚠️ LESSONS.md 미발견")
        sys.exit(2)
    claude_md_path, claude_md_source = resolve_project_file("CLAUDE.md", args.claude_md)
    if claude_md_source == "fallback":
        candidates = sorted(glob.glob(os.path.join(os.path.dirname(os.path.dirname(lessons_path)), "*", "CLAUDE.md")))
    elif claude_md_path:
        candidates = [claude_md_path]
    else:
        candidates = []
    return lessons_path, source, candidates


def compute_targets(raw, lessons_path, claude_md_candidates, limit_ids):
    text, lines = split_lines(raw)
    sections, diag = parse_lessons(text)
    if len(lines) != len(text.splitlines()):
        raise ValueError("줄 수 불일치")
    refs = collect_referenced_lessons(project_root(lessons_path), claude_md_candidates)
    targets = [s for s in sections if s["id"] in refs and (not limit_ids or s["id"] in limit_ids)]
    return text, lines, sections, diag, targets


def simulate_reinsert(remaining_lines, records_sorted):
    out = []
    ri = 0
    for rec in records_sorted:
        while len(out) < rec["start"] - 1 and ri < len(remaining_lines):
            out.append(remaining_lines[ri])
            ri += 1
        out.extend(rec["body"].decode("utf-8").splitlines(keepends=True))
    out.extend(remaining_lines[ri:])
    return "".join(out).encode("utf-8")


def do_verify(lessons_path, archive_path, baseline):
    ok = True
    raw = open(lessons_path, "rb").read()
    text, lines = split_lines(raw)
    sections, diag = parse_lessons(text)
    if not os.path.isfile(archive_path):
        print("VERIFY FAIL: 아카이브 없음")
        return 3
    araw = open(archive_path, "rb").read()
    records = parse_archive(araw)
    bad = [r["id"] for r in records if not r["ok"]]
    asecs, adiag = parse_lessons(araw.decode("utf-8"))
    rec_ids = {r["id"] for r in records}
    arch_ids = {s["id"] for s in asecs}
    total_bytes = sum(r["bytes"] for r in records)
    total_lines = sum(r["end"] - r["start"] + 1 for r in records)
    print("records=%d ids=%d lines=%d bytes=%d" % (len(records), len(rec_ids), total_lines, total_bytes))
    print("sha256_mismatch=%d %s" % (len(bad), bad[:5]))
    if bad:
        ok = False
    print("archive_parsed=%d archive_header=%d archive_unparsed=%s" % (
        adiag["parsed_count"], adiag["header_count"], adiag["unparsed_headers"]))
    if adiag["parsed_count"] != len(records) or adiag["unparsed_headers"]:
        ok = False
    missing = sorted(rec_ids - arch_ids)
    print("ids_missing_in_archive=%d %s" % (len(missing), missing[:5]))
    if missing:
        ok = False
    print("lessons_parsed=%d lessons_header=%d lessons_unparsed=%s" % (
        diag["parsed_count"], diag["header_count"], diag["unparsed_headers"]))
    if diag["parsed_count"] != diag["header_count"] or diag["unparsed_headers"]:
        ok = False
    nb = sum(1 for ln in lines if ln == NOTICE_BEGIN)
    print("notice_blocks=%d" % nb)
    if nb != 1:
        ok = False
    if baseline:
        braw = open(baseline, "rb").read()
        btext, blines = split_lines(braw)
        matched = []
        for r in records:
            seg = "".join(blines[r["start"] - 1:r["end"]]).encode("utf-8")
            if sha(seg) == r["sha"]:
                matched.append(r)
        matched.sort(key=lambda r: r["start"])
        # 기준선 이후 추가된 섹션(기준선에 없는 L-id)은 LESSONS.md 에서만 허용하고 재구성에서 제외한다.
        bsecs, _bdiag = parse_lessons(btext)
        # 파서가 인식하지 못하는 굵은 글씨형 헤더(**L-N: ...**)도 섹션 경계로 본다.
        hdr_re = re.compile(r"^(?:#{1,4}\s*\[?|\*\*\[?)(L-\d+)(?::|\])")
        any_hdr = re.compile(r"^#{1,4}\s")
        base_ids = {s["id"] for s in bsecs}
        for ln in blines:
            m = hdr_re.match(ln)
            if m:
                base_ids.add(m.group(1))
        hdr_idx = [i for i, ln in enumerate(lines) if hdr_re.match(ln)]
        added_ids = []
        drop = set()
        for i in hdr_idx:
            sid = hdr_re.match(lines[i]).group(1)
            if sid in base_ids:
                continue
            j = i + 1
            while j < len(lines) and not hdr_re.match(lines[j]) and not any_hdr.match(lines[j]):
                j += 1
            while j > i + 1 and lines[j - 1].strip() == "":
                j -= 1
            start = i - 1 if i > 0 and lines[i - 1].strip() == "" else i
            drop.update(range(start, j))
            added_ids.append(sid)
        kept_lines = [ln for i, ln in enumerate(lines) if i not in drop]
        rebuilt = simulate_reinsert(strip_notice(kept_lines), matched)
        same = rebuilt == braw
        print("baseline_records_matched=%d/%d rebuilt_equals_baseline=%s baseline_sha=%s" % (
            len(matched), len(records), same, sha(braw)[:16]))
        print("post_baseline_additions=%d %s" % (len(added_ids), added_ids[:10]))
        arch_hdr_ids = set(arch_ids)
        for ln in araw.decode("utf-8").splitlines():
            m = hdr_re.match(ln)
            if m:
                arch_hdr_ids.add(m.group(1))
        polluted = sorted(arch_hdr_ids - base_ids)
        print("archive_not_in_baseline=%d %s" % (len(polluted), polluted[:5]))
        if polluted:
            ok = False
        if not same:
            ok = False
    print("VERIFY %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 3


def main():
    ap = argparse.ArgumentParser(description="적용완료 교훈을 LESSONS_ARCHIVE.md 로 이관한다 (기본 dry-run)")
    ap.add_argument("--lessons", default=None)
    ap.add_argument("--claude-md", dest="claude_md", default=None)
    ap.add_argument("--apply", action="store_true", help="실제로 이관한다")
    ap.add_argument("--verify", action="store_true", help="읽기 전용 사후 검증")
    ap.add_argument("--baseline", default=None, help="--verify 시 이관 전 백업 파일(바이트 비교용)")
    ap.add_argument("--compare-json", dest="compare_json", default=None, help="analyze 결과 JSON 과 (id,title) 비교")
    ap.add_argument("--limit-ids", dest="limit_ids", default=None, help="쉼표 구분 L-id 로 대상 제한")
    args = ap.parse_args()

    lessons_path, source, candidates = resolve_inputs(args)
    archive_path = os.path.join(os.path.dirname(os.path.abspath(lessons_path)), ARCHIVE_NAME)

    if args.verify:
        sys.exit(do_verify(lessons_path, archive_path, args.baseline))

    if source == "fallback":
        print("중단: LESSONS.md 출처가 fallback(%s)이다. --lessons 로 정본을 명시하라." % lessons_path)
        sys.exit(2)

    limit_ids = set(x.strip() for x in args.limit_ids.split(",")) if args.limit_ids else None
    raw = open(lessons_path, "rb").read()
    raw_sha = sha(raw)
    text, lines, sections, diag, targets = compute_targets(raw, lessons_path, candidates, limit_ids)

    existing = parse_archive(open(archive_path, "rb").read()) if os.path.isfile(archive_path) else []
    have = {(r["id"], r["sha"]) for r in existing}
    at = datetime.datetime.now().astimezone().strftime("%Y-%m-%dT%H:%M:%S%z")
    recs = [make_record(s, lines, at) for s in targets]
    new_recs = [r for r in recs if (r["id"], r["sha"]) not in have]
    already = len(recs) - len(new_recs)

    t_lines = sum(r["lines"] for r in recs)
    t_bytes = sum(r["bytes"] for r in recs)
    t_ids = len({r["id"] for r in recs})
    remaining = len(lines) - t_lines
    print("source=%s path=%s" % (source, lessons_path))
    print("lessons_sha256=%s bytes=%d lines=%d headers=%d parsed=%d unique_ids=%d" % (
        raw_sha, len(raw), len(lines), diag["header_count"], diag["parsed_count"], diag["unique_ids"]))
    print("targets sections=%d ids=%d lines=%d bytes=%d" % (len(recs), t_ids, t_lines, t_bytes))
    print("already_archived=%d appended=%d" % (already, len(new_recs)))

    # 보존 검증 시뮬레이션: 제거 줄 + 기록 본문으로 원본 재구성
    removed = set()
    for s in targets:
        removed.update(range(s["start_line"] - 1, s["end_line"]))
    remaining_lines = [ln for i, ln in enumerate(lines) if i not in removed]
    sim_recs = sorted(
        [{"start": s["start_line"], "body": "".join(lines[s["start_line"] - 1:s["end_line"]]).encode("utf-8")} for s in targets],
        key=lambda r: r["start"])
    preserve = simulate_reinsert(remaining_lines, sim_recs) == raw
    overlap = len(removed) != t_lines
    print("preserve_check=%s overlap=%s" % ("PASS" if preserve and not overlap else "FAIL", overlap))
    print("expected_lessons_lines_after=%d (안내 블록 %d줄 포함)" % (
        remaining + (0 if find_notice(lines)[0] is not None else len(NOTICE_LINES)), len(NOTICE_LINES)))

    if args.compare_json:
        try:
            data = json.load(open(args.compare_json, encoding="utf-8"))
            a = {(x["id"], x["title"]) for x in data.get("applied", [])}
            b = {(s["id"], s["title"]) for s in targets}
            print("compare_json applied=%d targets=%d only_json=%d only_targets=%d" % (
                len(a), len(b), len(a - b), len(b - a)))
        except Exception as e:
            print("compare_json 실패: %s" % e)

    if not preserve or overlap:
        print("중단: 보존 검증 실패")
        sys.exit(3)
    if not args.apply:
        print("DRY-RUN 완료 (파일 변경 없음)")
        return

    if not targets:
        print("이관 대상 없음")
        return

    # --apply
    if sha(open(lessons_path, "rb").read()) != raw_sha:
        print("중단: LESSONS.md 가 읽은 뒤 변경되었다(다른 세션 수정 의심)")
        sys.exit(2)
    backup_dir = os.path.join(config_dir(), "backups")
    os.makedirs(backup_dir, exist_ok=True)
    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    backup = os.path.join(backup_dir, "LESSONS.md.%s" % ts)
    shutil.copy2(lessons_path, backup)
    if sha(open(backup, "rb").read()) != raw_sha:
        print("중단: 백업 해시 불일치")
        sys.exit(2)
    print("backup=%s" % backup)

    # 아카이브 쓰기 (기존 + 신규)
    if os.path.isfile(archive_path):
        base = open(archive_path, "rb").read()
        if not base.endswith(b"\n"):
            base += b"\n"
    else:
        base = ARCHIVE_HEADER.encode("utf-8")
    blob = base + b"".join(r["blob"] for r in new_recs)
    atomic_write(archive_path, blob)

    # 쓰기 직전 재확인 후 LESSONS 교체
    if sha(open(lessons_path, "rb").read()) != raw_sha:
        print("중단: LESSONS.md 쓰기 직전 변경 감지. LESSONS 는 건드리지 않았다(재실행 시 중복 방지로 복구)")
        sys.exit(2)
    new_lines = list(remaining_lines)
    if find_notice(new_lines)[0] is None:
        new_lines[NOTICE_INSERT_AFTER_LINE:NOTICE_INSERT_AFTER_LINE] = NOTICE_LINES
    new_raw = "".join(new_lines).encode("utf-8")
    if sha(open(lessons_path, "rb").read()) != raw_sha:
        print("중단: LESSONS.md 교체 직전 변경 감지")
        sys.exit(2)
    atomic_write(lessons_path, new_raw)
    print("applied: archive_records_added=%d lessons_bytes %d -> %d" % (len(new_recs), len(raw), len(new_raw)))
    sys.exit(do_verify(lessons_path, archive_path, backup))


if __name__ == "__main__":
    main()
