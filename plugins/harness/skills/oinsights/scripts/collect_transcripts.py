import sys, argparse
import subprocess, json, os, glob

# argparse로 올바른 인수 처리
parser = argparse.ArgumentParser()
parser.add_argument('output', nargs='?', default=None)
parser.add_argument('--output', dest='output_flag', default=None)
parser.add_argument('--project', default=None, help='프로젝트명 (미지정 시 cwd 의 basename)')
args, _ = parser.parse_known_args()

output_path = args.output_flag or args.output or os.path.expanduser("~/.claude/session-env/oinsights_transcript_hits.json")

# 프로젝트 트랜스크립트 디렉토리 자동 감지
project = args.project or os.path.basename(os.getcwd())
transcript_dir = os.path.expanduser(f"~/.claude/projects/-mnt-c-DATA-Project-{project}/")
if not os.path.isdir(transcript_dir):
    # fallback: cwd 절대경로를 Claude Code 트랜스크립트 디렉토리 규칙으로 변환
    _slug = os.getcwd().replace("/", "-")
    transcript_dir = os.path.expanduser(f"~/.claude/projects/{_slug}/")

patterns = ["blocked", "DENY", "exit code 1", "실패", "위반", "retry.*fail", "hook.*error"]
combined_pattern = "|".join(patterns)

# grep으로 히트 파일 찾기 (최대 20개)
result = subprocess.run(
    ["grep", "-rl", "-E", combined_pattern, transcript_dir],
    capture_output=True, text=True, timeout=30
)
hit_files = result.stdout.strip().split("\n")[:20]
hit_files = [f for f in hit_files if f.endswith(".jsonl")]

hits = []
for fpath in hit_files:
    sid = os.path.basename(fpath).replace(".jsonl", "")[:8]
    # 히트 라인만 추출 (최대 5개)
    result2 = subprocess.run(
        ["grep", "-E", combined_pattern, fpath],
        capture_output=True, text=True, timeout=10
    )
    matched_lines = result2.stdout.strip().split("\n")[:5]
    excerpts = []
    for line in matched_lines:
        try:
            obj = json.loads(line)
            msg = obj.get("message", {})
            content = ""
            if isinstance(msg.get("content"), str):
                content = msg["content"][:200]
            elif isinstance(msg.get("content"), list):
                for c in msg["content"]:
                    if isinstance(c, dict) and c.get("type") == "text":
                        content = c.get("text", "")[:200]
                        break
            if content:
                excerpts.append(content)
        except:
            pass
    if excerpts:
        hits.append({"session": sid, "excerpts": excerpts})

with open(output_path, "w") as out:
    json.dump(hits, out, ensure_ascii=False, indent=2)
print(f"트랜스크립트 히트: {len(hits)}개 세션")
