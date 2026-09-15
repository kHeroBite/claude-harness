import sys, re, json, os, argparse
from collections import Counter

# argparse로 올바른 인수 처리
parser = argparse.ArgumentParser()
parser.add_argument('output', nargs='?', default=None, help='출력 JSON 경로')
parser.add_argument('--output', dest='output_flag', default=None)
parser.add_argument('--lessons', default=None)
args, _ = parser.parse_known_args()

output_path = args.output_flag or args.output or os.path.expanduser("~/.claude/session-env/oinsights_lessons_summary.json")

# LESSONS.md 경로 자동 감지
lessons_path = args.lessons
if not lessons_path:
    # cwd 기준 LESSONS.md 를 우선 탐색하고, 없으면 상위 디렉토리로 거슬러 올라간다.
    candidates = []
    _cur = os.getcwd()
    while True:
        candidates.append(os.path.join(_cur, "LESSONS.md"))
        _parent = os.path.dirname(_cur)
        if _parent == _cur:
            break
        _cur = _parent
    for candidate in candidates:
        if os.path.exists(candidate):
            lessons_path = candidate
            break

if not lessons_path:
    print("⚠️ LESSONS.md 미발견")
    with open(output_path, "w") as out:
        json.dump({"available": False}, out)
    exit(0)

with open(lessons_path, encoding="utf-8") as f:
    content = f.read()

# 교훈 헤더 추출
headers = re.findall(r"### (L-\d+): (.+?) \((\d{4}-\d{2}-\d{2})\)", content)
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
    "total_lessons": len(headers),
    "categories": dict(cat_counter),
    "severities": dict(sev_counter),
    "recent_20": [{"id": h[0], "title": h[1], "date": h[2]} for h in recent_20],
    "repeated_keywords": dict(sorted(keyword_freq.items(), key=lambda x: -x[1]))
}

with open(output_path, "w") as out:
    json.dump(summary, out, ensure_ascii=False, indent=2)
print(json.dumps(summary, ensure_ascii=False, indent=2))
