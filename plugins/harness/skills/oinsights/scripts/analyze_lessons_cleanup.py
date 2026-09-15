import sys, re, json, os, subprocess, glob

output_path = sys.argv[1] if len(sys.argv) > 1 else "$HOME/.claude/session-env/oinsights_lessons_cleanup.json"

# LESSONS.md 경로 감지
lessons_path = None
for candidate in glob.glob("/mnt/c/DATA/Project/*/LESSONS.md"):
    lessons_path = candidate
    break
if not lessons_path:
    print("⚠️ LESSONS.md 미발견")
    exit(0)

with open(lessons_path, encoding="utf-8") as f:
    content = f.read()

# 교훈 항목 파싱 (### L-NNN: 제목 패턴)
lesson_pattern = r"### (L-\d+): (.+?) \((\d{4}-\d{2}-\d{2})\)(.*?)(?=### L-|\Z)"
lessons = []
for m in re.finditer(lesson_pattern, content, re.DOTALL):
    lid, title, date, body = m.group(1), m.group(2), m.group(3), m.group(4)
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
        "id": lid, "title": title, "date": date,
        "severity": severity, "category": category,
        "keywords": list(keywords)[:20],
        "body_preview": body.strip()[:200]
    })

# 스킬/hooks/CLAUDE.md에서 L-번호 참조 검색
skill_dir = "/mnt/c/DATA/Project/AI/.claude/skills/"
hook_dirs = ["/mnt/c/DATA/Project/AI/.claude/hooks/", os.path.expanduser("~/.claude/hooks/")]
claude_md_candidates = glob.glob("/mnt/c/DATA/Project/*/CLAUDE.md")

referenced_lessons = set()
for search_dir in [skill_dir] + hook_dirs + claude_md_candidates:
    if os.path.isfile(search_dir):
        with open(search_dir, encoding="utf-8", errors="ignore") as f:
            txt = f.read()
        for lid in re.findall(r"L-\d+", txt):
            referenced_lessons.add(lid)
    elif os.path.isdir(search_dir):
        for root, dirs, files in os.walk(search_dir):
            for fname in files:
                if fname.endswith((".md", ".sh", ".json")):
                    fpath = os.path.join(root, fname)
                    try:
                        with open(fpath, encoding="utf-8", errors="ignore") as f:
                            txt = f.read()
                        for lid in re.findall(r"L-\d+", txt):
                            referenced_lessons.add(lid)
                    except:
                        pass

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
    "lessons_path": lessons_path
}

with open(output_path, "w") as out:
    json.dump(result, out, ensure_ascii=False, indent=2)
print(json.dumps(result, ensure_ascii=False, indent=2)[:2000])
