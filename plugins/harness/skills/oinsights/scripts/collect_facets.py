import sys
import json, glob, os
from collections import Counter

facets_dir = os.path.expanduser("~/.claude/usage-data/facets/")
files = glob.glob(facets_dir + "*.json")
output_path = sys.argv[1] if len(sys.argv) > 1 else "$HOME/.claude/session-env/oinsights_facets_summary.json"

if not files:
    print("⚠️ facets 데이터 없음 — /insights를 먼저 실행하면 더 풍부한 분석 가능")
    with open(output_path, "w") as out:
        json.dump({"available": False}, out)
    exit(0)

friction_totals = Counter()
outcomes = Counter()
satisfaction = Counter()
session_types = Counter()
friction_details = []

for f in files:
    with open(f) as fh:
        d = json.load(fh)
    for ftype, cnt in d.get("friction_counts", {}).items():
        friction_totals[ftype] += cnt
    outcomes[d.get("outcome", "unknown")] += 1
    for stype, cnt in d.get("user_satisfaction_counts", {}).items():
        satisfaction[stype] += cnt
    session_types[d.get("session_type", "unknown")] += 1
    if d.get("friction_counts"):
        friction_details.append({
            "session": d.get("session_id", "")[:8],
            "friction": d["friction_counts"],
            "detail": d.get("friction_detail", "")[:300],
            "outcome": d.get("outcome", ""),
            "summary": d.get("brief_summary", "")[:200]
        })

summary = {
    "available": True,
    "total_facets": len(files),
    "friction_types": dict(friction_totals.most_common(10)),
    "outcomes": dict(outcomes),
    "satisfaction": dict(satisfaction),
    "session_types": dict(session_types),
    "friction_sessions": friction_details
}

with open(output_path, "w") as out:
    json.dump(summary, out, ensure_ascii=False, indent=2)
print(json.dumps(summary, ensure_ascii=False, indent=2))
