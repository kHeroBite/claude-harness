#!/usr/bin/env bash
# ListAgents 호출 직후 메인 세션에 peer_check_done 마커와 통지 대상(peer_targets.json)을 기록하는 PostToolUse hook
# 팀에이전트 호출은 기록하지 않는다(R1: /proc 조상 cmdline 에 --parent-session-id 있으면 팀에이전트). 항상 exit 0.
set -uo pipefail

INPUT="$(cat 2>/dev/null || true)"
[ -z "$INPUT" ] && exit 0

_PY='import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
k=sys.argv[1]
if k=="tool_name": print(d.get("tool_name") or "")
elif k=="sid": print(d.get("session_id") or "")'
TOOL="$(printf '%s' "$INPUT" | python3 -c "$_PY" tool_name 2>/dev/null)"
[ "$TOOL" != "ListAgents" ] && exit 0

# ── 메인/팀에이전트 판별 (C18 패턴) ──
_is_team() {
  if [ -n "${PEER_TEST_ROLE:-}" ]; then [ "$PEER_TEST_ROLE" = "team" ]; return; fi
  local pid=$$ depth=0 cmd
  while [ "$depth" -lt 10 ] && [ -n "$pid" ] && [ "$pid" != "0" ] && [ "$pid" != "1" ]; do
    cmd="$(tr '\0' ' ' 2>/dev/null < "/proc/${pid}/cmdline")"
    if [[ "$cmd" =~ --parent-session-id[[:space:]]+[0-9a-f-]{36} ]] || [[ "$cmd" =~ --agent-name[[:space:]]+[^[:space:]]+ ]]; then
      return 0
    fi
    pid="$(sed 's/^.*) //' "/proc/${pid}/stat" 2>/dev/null | awk '{print $2}')"
    [[ "$pid" =~ ^[0-9]+$ ]] || break
    depth=$((depth + 1))
  done
  return 1
}
_is_team && exit 0

UUID="$(printf '%s' "$INPUT" | python3 -c "$_PY" sid 2>/dev/null | tr -d '[:space:]')"
[[ "$UUID" =~ ^[0-9a-f-]{36}$ ]] || exit 0
SDIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/$UUID"
[ -d "$SDIR" ] || exit 0

date +%s > "$SDIR/peer_check_done" 2>/dev/null

# ── 통지 대상 산출(최선 노력) — 실패해도 마커는 이미 기록됨 ──
# tool_response 가 문자열/배열(content 블록)/dict 어느 형태여도 텍스트로 풀어 행 단위로 파싱한다.
# 프로젝트는 tmux 세션명 claude-<P>[-N] 에서 끝 -N 제거 후 소문자로 판별한다.
_PARSE='import sys,json,os,re,subprocess,datetime
def flat(o,out):
    if isinstance(o,str): out.append(o)
    elif isinstance(o,list):
        for x in o: flat(x,out)
    elif isinstance(o,dict):
        for v in o.values(): flat(v,out)
def to_text(r):
    if r is None: return ""
    if isinstance(r,str):
        s=r.strip()
        if s[:1] in ("[","{"):
            try: r=json.loads(s)
            except Exception: return r
        else: return r
    out=[]; flat(r,out)
    return "\n".join(out)
def norm(name):
    m=re.match(r"^claude-(.+)$",name or "")
    if not m: return None
    p=m.group(1); q=re.sub(r"-\d+$","",p)
    return (q or p).lower()
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
sdir=sys.argv[1]
raw=d.get("tool_response")
try:
    lg=os.path.join(sdir,"logs"); os.makedirs(lg,exist_ok=True)
    sp=os.path.join(lg,"peer_raw_sample.txt")
    if not os.path.exists(sp):
        with open(sp,"w",encoding="utf-8") as f:
            f.write("type=%s\n"%type(raw).__name__)
            f.write(json.dumps(raw,ensure_ascii=False)[:4096])
except Exception: pass
text=to_text(raw)
pane=os.environ.get("TMUX_PANE","")
own=os.environ.get("PEER_TEST_OWN_PROJECT","").strip().lower()
if not own and pane:
    try:
        s=subprocess.run(["tmux","display-message","-p","-t",pane,"#S"],capture_output=True,text=True,timeout=1).stdout.strip()
        own=norm(s) or ""
    except Exception: own=""
if not own:
    for c in (d.get("cwd"),os.environ.get("CLAUDE_PROJECT_DIR")):
        if c:
            own=os.path.basename(str(c).rstrip("/")).lower()
            if own: break
harness=os.environ.get("PEER_HARNESS_PROJECT","ai").strip().lower()
scope="all" if own==harness else "project"
row=re.compile(r"^\s*[-*•]?\s*(.+?)\s+\[[0-9A-Za-z]+\]\s+·\s+(.*)$")
sm=re.search(r"This session is\s+(.+?)\s+\[[0-9A-Za-z]+\]",text)
selfname=sm.group(1) if sm else ""
section=""; targets=[]; so=su=sr=0; rows=0
for ln in text.splitlines():
    h=ln.strip().lower()
    if h.startswith("teammates"): section="team"; continue
    if h.startswith("peer sessions"): section="peer"; continue
    m=row.match(ln)
    if not m: continue
    rows+=1
    name,rest=m.group(1),m.group(2)
    if section=="team" or "roster" in rest: continue
    low=rest.lower()
    if "remote control" in low or "offline" in low: sr+=1; continue
    t=re.search(r"tmux\s+([^:\s]+):@\d+\.%(\d+)",rest)
    if selfname and name==selfname: continue
    if scope=="all":
        targets.append(name); continue
    proj=norm(t.group(1)) if t else None
    if proj is None: su+=1
    elif proj==own: targets.append(name)
    else: so+=1
targets=sorted(set(targets))
res={"scope":scope,"project":own,"targets":targets,"skipped_other":so,"skipped_unknown":su,"skipped_remote":sr,
     "parse":("ok" if rows else "no_rows"),"ts":datetime.datetime.now().astimezone().isoformat(timespec="seconds")}
tp=os.path.join(sdir,"peer_targets.json")
with open(tp+".tmp","w",encoding="utf-8") as f: json.dump(res,f,ensure_ascii=False)
os.replace(tp+".tmp",tp)
with open(os.path.join(sdir,"peer_list"),"w",encoding="utf-8") as f:
    f.write("".join(n+"\n" for n in targets))'
printf '%s' "$INPUT" | python3 -c "$_PARSE" "$SDIR" >/dev/null 2>&1 || true
exit 0
