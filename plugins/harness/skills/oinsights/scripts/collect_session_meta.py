import sys
import json, glob, os
from collections import Counter, defaultdict
from datetime import datetime

meta_dir = os.path.expanduser("~/.claude/usage-data/session-meta/")
files = glob.glob(meta_dir + "*.json")

total = len(files)
durations = []
tool_totals = Counter()
error_categories = Counter()
high_error_sessions = []
total_lines_added = 0
total_lines_removed = 0
total_interruptions = 0
dates = []

for f in files:
    with open(f) as fh:
        d = json.load(fh)
    dur = d.get("duration_minutes", 0)
    durations.append(dur)
    for tool, cnt in d.get("tool_counts", {}).items():
        tool_totals[tool] += cnt
    for cat, cnt in d.get("tool_error_categories", {}).items():
        error_categories[cat] += cnt
    errs = d.get("tool_errors", 0)
    if errs >= 5:
        high_error_sessions.append({"session": d["session_id"][:8], "errors": errs, "duration": dur})
    total_lines_added += d.get("lines_added", 0)
    total_lines_removed += d.get("lines_removed", 0)
    total_interruptions += d.get("user_interruptions", 0)
    st = d.get("start_time", "")
    if st:
        dates.append(st[:10])

dates.sort()
summary = {
    "total_sessions": total,
    "date_range": f"{dates[0]} ~ {dates[-1]}" if dates else "N/A",
    "avg_duration_min": round(sum(durations)/max(len(durations),1), 1),
    "max_duration_min": max(durations) if durations else 0,
    "tool_usage_top10": dict(tool_totals.most_common(10)),
    "error_categories": dict(error_categories.most_common(10)),
    "high_error_sessions": sorted(high_error_sessions, key=lambda x: -x["errors"])[:10],
    "total_lines": {"added": total_lines_added, "removed": total_lines_removed},
    "total_interruptions": total_interruptions,
    "avg_interruptions_per_session": round(total_interruptions/max(total,1), 2)
}

output_path = sys.argv[1] if len(sys.argv) > 1 else "$HOME/.claude/session-env/oinsights_session_meta_summary.json"
with open(output_path, "w") as out:
    json.dump(summary, out, ensure_ascii=False, indent=2)
print(json.dumps(summary, ensure_ascii=False, indent=2))
