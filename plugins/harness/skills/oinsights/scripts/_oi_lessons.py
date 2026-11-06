# oinsights LESSONS.md 헤더/섹션 공용 파서 (줄 기반, 코드펜스 미추적)
import re

L_HEADER = re.compile(r'^(#{1,6})[ \t]+\[?(L-\d+)\]?(.*)$')
BOLD_L_HEADER = re.compile(r'^\*\*(L-\d+): (.*)\*\*$')  # 굵은 글씨형 교훈 헤더(level 6 로 취급)
ANY_HEADER = re.compile(r'^(#{1,6})[ \t]+\S')
RAW_L_HEADER = re.compile(r'^#{1,6}[ \t]+\[?L-\d+')
DATE = re.compile(r'\d{4}-\d{2}-\d{2}')
_LEAD_SEP = re.compile(r'^[\s\]:：—–\-]+')
_TAIL_DATE_PAREN = re.compile(r'\s*\([^()]*\d{4}-\d{2}-\d{2}[^()]*\)\s*$')


def parse_lessons(content):
    """-> (sections, diag).

    sections: dict 리스트 {id,title,date,level,start_line,end_line,header,body,dup_index}
    섹션 끝은 다음 L 헤더(레벨 무관) 또는 레벨이 같거나 상위인 일반 헤더 직전이다.
    코드펜스 내부 헤더는 구분하지 않는다(줄 기반 판정).
    """
    lines = content.splitlines()
    total = len(lines)
    heads = []  # (idx, level, id, rest)
    raw_header_lines = []
    for i, line in enumerate(lines):
        if RAW_L_HEADER.match(line):
            raw_header_lines.append(i + 1)
        m = L_HEADER.match(line)
        if m:
            heads.append((i, len(m.group(1)), m.group(2), m.group(3)))
            continue
        bm = BOLD_L_HEADER.match(line)
        if bm:
            raw_header_lines.append(i + 1)
            heads.append((i, 6, bm.group(1), bm.group(2)))

    sections = []
    seen = {}
    dup_lines = {}
    for idx, level, lid, rest in heads:
        end = total  # 0-based 제외 경계
        for j in range(idx + 1, total):
            ln = lines[j]
            if L_HEADER.match(ln) or BOLD_L_HEADER.match(ln):
                end = j
                break
            gm = ANY_HEADER.match(ln)
            if gm and len(gm.group(1)) <= level:
                end = j
                break
        dm = DATE.search(rest)
        date = dm.group(0) if dm else ""
        title = _LEAD_SEP.sub('', rest)
        title = _TAIL_DATE_PAREN.sub('', title).strip()
        n = seen.get(lid, 0)
        seen[lid] = n + 1
        dup_lines.setdefault(lid, []).append(idx + 1)
        sections.append({
            "id": lid, "title": title, "date": date, "level": level,
            "start_line": idx + 1, "end_line": end,
            "header": lines[idx],
            "body": "\n".join(lines[idx + 1:end]),
            "dup_index": n,
        })

    parsed_lines = {s["start_line"] for s in sections}
    unparsed = [ln for ln in raw_header_lines if ln not in parsed_lines]
    diag = {
        "header_count": len(raw_header_lines),
        "parsed_count": len(sections),
        "unique_ids": len(seen),
        "duplicate_ids": {k: v for k, v in dup_lines.items() if len(v) > 1},
        "unparsed_headers": unparsed,
    }
    return sections, diag
