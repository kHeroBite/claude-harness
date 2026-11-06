import sys, re, json, os, argparse
from collections import Counter

# argparse로 올바른 인수 처리
parser = argparse.ArgumentParser()
parser.add_argument('output', nargs='?', default=None, help='출력 JSON 경로')
parser.add_argument('--output', dest='output_flag', default=None)
parser.add_argument('--lessons', default=None)
args, _ = parser.parse_known_args()

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _oi_paths import resolve_project_file, default_output
from _oi_lessons import parse_lessons

output_path = default_output("oinsights_lessons_summary.json", args.output_flag or args.output)

# LESSONS.md 경로 자동 감지
lessons_path, lessons_source = resolve_project_file("LESSONS.md", args.lessons)
if lessons_path and not os.path.isfile(lessons_path):
    lessons_path = None

if not lessons_path:
    print("⚠️ LESSONS.md 미발견")
    with open(output_path, "w") as out:
        json.dump({"available": False, "lessons_path": None, "lessons_source": lessons_source}, out)
    exit(0)

with open(lessons_path, encoding="utf-8") as f:
    content = f.read()

# 교훈 헤더 추출
sections, diag = parse_lessons(content)
headers = [(s["id"], s["title"], s["date"]) for s in sections]
categories = re.findall(r"\*\*카테고리\*\*:\s*(.+)", content)
severities = re.findall(r"\*\*심각도\*\*:\s*(.+)", content)

cat_counter = Counter(c.strip() for c in categories)
sev_counter = Counter(s.strip() for s in severities)

# 키워드 반복 패턴 감지
keywords = ["hook", "pane", "spawn", "shutdown", "pipeline", "guard",
            "SendMessage", "tmux", "config.json", "NTFS", "rsync",
            "jq", "facets", "commit", "encoding", "BOM"]
keyword_freq = {}
for kw in keywords:
    count = len(re.findall(kw, content, re.IGNORECASE))
    if count >= 3:
        keyword_freq[kw] = count

recent_20 = headers[-20:]

summary = {
    "available": True,
    "lessons_path": lessons_path,
    "lessons_source": lessons_source,
    "total_lessons": len(headers),
    "categories": dict(cat_counter),
    "severities": dict(sev_counter),
    "recent_20": [{"id": h[0], "title": h[1], "date": h[2]} for h in recent_20],
    "repeated_keywords": dict(sorted(keyword_freq.items(), key=lambda x: -x[1])),
    "header_count": diag["header_count"],
    "parsed_count": diag["parsed_count"],
    "unique_ids": diag["unique_ids"],
    "duplicate_ids": diag["duplicate_ids"],
    "unparsed_headers": diag["unparsed_headers"]
}

with open(output_path, "w") as out:
    json.dump(summary, out, ensure_ascii=False, indent=2)
print(json.dumps(summary, ensure_ascii=False, indent=2))
