import sys, re, json, os, subprocess, glob, argparse
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _oi_paths import resolve_project_file, default_output, project_root
from _oi_lessons import parse_lessons
from _oi_refs import collect_referenced_lessons

parser = argparse.ArgumentParser()
parser.add_argument('output', nargs='?', default=None, help='출력 JSON 경로')
parser.add_argument('--output', dest='output_flag', default=None)
parser.add_argument('--lessons', default=None)
parser.add_argument('--claude-md', dest='claude_md', default=None)
args, _ = parser.parse_known_args()

output_path = default_output("oinsights_lessons_cleanup.json", args.output_flag or args.output)

# LESSONS.md 경로 감지
lessons_path, lessons_source = resolve_project_file("LESSONS.md", args.lessons)
if not lessons_path or not os.path.isfile(lessons_path):
    lessons_path = None
if not lessons_path:
    print("⚠️ LESSONS.md 미발견")
    exit(0)

with open(lessons_path, encoding="utf-8") as f:
    content = f.read()

# 교훈 항목 파싱 (공용 파서 — 모든 레벨/구분자/대괄호 헤더 지원)
sections, diag = parse_lessons(content)
lessons = []
for sec in sections:
    lid, title, date, body = sec["id"], sec["title"], sec["date"], sec["body"]
    # 핵심 키워드 추출
    keywords = set(re.findall(r"[a-zA-Z_]{4,}", body.lower()))
    keywords.update(re.findall(r"[가-힣]{2,}", body))
    severity = "높음" if re.search(r"심각도.*높음", body) else \
               "중간" if re.search(r"심각도.*중간", body) else "낮음"
    category = ""
    cat_m = re.search(r"카테고리\*\*:\s*(.+)", body)
    if cat_m:
        category = cat_m.group(1).strip()
    lessons.append({
        "id": lid, "title": title, "date": date, "line": sec["start_line"],
        "severity": severity, "category": category,
        "keywords": list(keywords)[:20],
        "body_preview": body.strip()[:200]
    })

# 스킬/hooks/CLAUDE.md에서 L-번호 참조 검색
proj_dir = project_root(lessons_path)
claude_md_path, claude_md_source = resolve_project_file("CLAUDE.md", args.claude_md)
if claude_md_source == "fallback":
    claude_md_candidates = sorted(glob.glob("/mnt/c/DATA/Project/*/CLAUDE.md"))
elif claude_md_path:
    claude_md_candidates = [claude_md_path]
else:
    claude_md_candidates = []

referenced_lessons = collect_referenced_lessons(proj_dir, claude_md_candidates)

# 분류
applied = []      # 적용 완료
unapplied = []    # 미적용

for lesson in lessons:
    lid = lesson["id"]
    if lid in referenced_lessons:
        applied.append(lesson)
    elif lesson["severity"] == "높음":
        unapplied.append(lesson)

# 키워드 기반 유사 그룹핑
keyword_groups = {}
for lesson in lessons:
    for kw in ["pane", "shutdown", "hook", "spawn", "pipeline", "config",
               "ntfs", "rsync", "commit", "encoding"]:
        if kw in " ".join(lesson["keywords"]).lower():
            keyword_groups.setdefault(kw, []).append(lesson["id"])

# 3개+ 항목이 있는 그룹만
similar_groups = {k: v for k, v in keyword_groups.items() if len(v) >= 3}

result = {
    "total_lessons": len(lessons),
    "applied_count": len(applied),
    "applied": [{"id": l["id"], "title": l["title"]} for l in applied],
    "unapplied_important": [{"id": l["id"], "title": l["title"], "severity": l["severity"]} for l in unapplied],
    "similar_groups": similar_groups,
    "lessons_path": lessons_path,
    "lessons_source": lessons_source,
    "claude_md_path": claude_md_path,
    "claude_md_source": claude_md_source,
    "header_count": diag["header_count"],
    "parsed_count": diag["parsed_count"],
    "unique_ids": diag["unique_ids"],
    "duplicate_ids": diag["duplicate_ids"],
    "unparsed_headers": diag["unparsed_headers"]
}

with open(output_path, "w") as out:
    json.dump(result, out, ensure_ascii=False, indent=2)
print(json.dumps(result, ensure_ascii=False, indent=2)[:2000])
