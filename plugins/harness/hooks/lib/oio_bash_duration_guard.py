# 팀원 oio bash_exec 의 장시간 호출(>90초 추정)과 deny 목록 명령이 섞인 Monitor 호출을 미리 거르는 PreToolUse 판정 코어
"""
입력: stdin = PreToolUse hook JSON (tool_name = mcp__oio__bash_exec | Monitor)
env : OBDG_TEAMMATE=1|0(호출부가 PIPELINE_UUID 유무로 넘긴다), OBDG_LIMIT_SEC(기본 90), OBDG_MODE(block|warn)
      OBDG_DENY_CMDS(테스트용 — 공백 구분 deny 명령 목록. 미지정 시 settings.json permissions.deny 의 Bash(x:*) 를 읽는다)
출력: stdout 에 hookSpecificOutput JSON(deny 또는 additionalContext) 또는 무출력. 항상 exit 0(fail-open).

배경(2026-10-10 c174 실측 — ~/.cache/claude-cli-nodejs/-mnt-c-DATA-Project-Mars/mcp-logs-oio/):
  - Claude Code 는 MCP 도구 호출이 120초를 넘으면 백그라운드 task 로 넘긴다("is still running after 120s. It was moved
    to the background"). odev-10-2(01:16·01:18Z)·odev-10-4(01:28·01:31Z)에서 이렇게 넘어간 호출이 2건 남은 직후부터
    그 세션의 모든 oio 호출이 "Invalid request parameters"(mcp/shared/session.py:390, INVALID_PARAMS)로 즉시 실패했고,
    서버가 SIGKILL 될 때까지 회복되지 않았다(팀원 2명 손실).
  - 그 동안 팀원은 리드 메시지를 받지 못했다(긴 폴링 루프 — odev-10-5 는 1시간 지연).
  ⇒ 팀원의 한 번 호출을 90초 이내로 묶어 120초 자동 백그라운드 전환 자체가 일어나지 않게 한다.
판정 1 (mcp__oio__bash_exec, 팀원만):
  명령 문자열에서 소요 시간을 정적으로 추정한다.
    sleep N / Start-Sleep N / -MaxWaitSec N 류의 합 × 반복 횟수(seq·{a..b}·for /L) → 추정치
    while true / while : / until … sleep … (상한 없는 루프) → 무한
    timeout N 으로 감싸면 그 N 으로 상한
  추정치 > 한도 → deny(분할 안내). 분리 실행(setsid/nohup/단독 &)·#bg:daemon 은 즉시 반환되므로 제외.
  명시 timeout_ms > 100000 인데 추정이 안 되는 명령 → 경고만(additionalContext).
판정 2 (Monitor, 리드·팀원 공통):
  settings.json permissions.deny 의 Bash(cat:*) 등은 Monitor 명령에도 적용된다(실측: 거부 7건 전부 tail/ls/grep/awk/cat 포함,
  허용 건은 until/while+sleep+pgrep/test/echo 만 사용). 명령의 각 구간 첫 단어가 deny 목록이면 원인과 대안을 담아 deny 한다.
"""
import json
import os
import re
import sys

LIMIT = int(os.environ.get("OBDG_LIMIT_SEC", "90") or 90)
MODE = os.environ.get("OBDG_MODE", "block")
TEAMMATE = os.environ.get("OBDG_TEAMMATE", "0") == "1"
INF = float("inf")

_NUM = r"(\d+(?:\.\d+)?)([smh]?)"


def _sec(n, unit):
    v = float(n)
    return v * {"": 1, "s": 1, "m": 60, "h": 3600}[unit]


def _detached(cmd):
    if "#bg:daemon" in cmd:
        return True
    if re.search(r"(?:^|[\s;|&(])(?:setsid|nohup|disown)(?:\s|$)", cmd):
        return True
    return bool(re.search(r"(?<![&>|<])&(?![&>\d])\s*(?:$|[;)\n])", cmd, re.M))


def estimate(cmd):
    """(추정 초, 근거 문자열). 추정 불가이면 (0, '')"""
    sleeps = 0.0
    why = []
    for m in re.finditer(r"(?:^|[\s;|&(`'\"])sleep\s+" + _NUM + r"\b", cmd):
        sleeps += _sec(m.group(1), m.group(2))
    for m in re.finditer(r"Start-Sleep\s+(?:-Seconds\s+|-s\s+)?(\d+)", cmd, re.I):
        sleeps += float(m.group(1))
    for m in re.finditer(r"Start-Sleep\s+-Milliseconds\s+(\d+)", cmd, re.I):
        sleeps += float(m.group(1)) / 1000.0
    waits = 0.0
    for m in re.finditer(r"-(?:Max)?(?:Wait|Timeout|Duration)(?:Sec|Seconds|S)\s+(\d+)", cmd, re.I):
        waits = max(waits, float(m.group(1)))
    iters = 1
    for m in re.finditer(r"\bseq\s+(\d+)(?:\s+(\d+))?(?:\s+(\d+))?", cmd):
        a, b, c = m.group(1), m.group(2), m.group(3)
        if c:
            n = (int(c) - int(a)) // max(1, int(b)) + 1
        elif b:
            n = int(b) - int(a) + 1
        else:
            n = int(a)
        iters = max(iters, n)
    for m in re.finditer(r"\{(\d+)\.\.(\d+)\}", cmd):
        iters = max(iters, int(m.group(2)) - int(m.group(1)) + 1)
    for m in re.finditer(r"\bfor\s*\(\(\s*\w+\s*=\s*(\d+)\s*;\s*\w+\s*<=?\s*(\d+)", cmd):
        iters = max(iters, int(m.group(2)) - int(m.group(1)) + 1)
    unbounded = bool(re.search(r"\b(?:while\s+(?:true|:|\[\s*1\s*\])|until\b|while\s+!|while\s+\[)", cmd)) and (sleeps > 0 or "sleep" in cmd)
    if unbounded and iters == 1:
        est = INF
        why.append("상한 없는 while/until 루프 + sleep")
    else:
        est = sleeps * iters
        if sleeps:
            why.append("sleep 합 %gs × 반복 %d" % (sleeps, iters))
    if waits:
        est = max(est, waits)
        why.append("대기 인자 %gs" % waits)
    caps = [_sec(m.group(1), m.group(2)) for m in re.finditer(r"(?:^|[\s;|&(])timeout\s+(?:-[a-zA-Z]+\s+\S+\s+|--?\w[\w-]*(?:=\S+)?\s+)*" + _NUM + r"\s", cmd)]
    if caps and est > 0:
        cap = max(caps)
        if cap < est:
            why.append("timeout %gs 로 상한" % cap)
            est = cap
    return est, ", ".join(why)


def _deny_cmds():
    env = os.environ.get("OBDG_DENY_CMDS")
    if env is not None:
        return set(env.split())
    out = set()
    home = os.path.expanduser("~")
    for p in {os.path.join(os.environ.get("CLAUDE_CONFIG_DIR", "") or os.path.join(home, ".claude"), "settings.json"),
              os.path.join(home, ".claude", "settings.json")}:
        try:
            with open(p, encoding="utf-8") as f:
                d = json.load(f)
        except Exception:
            continue
        for r in ((d.get("permissions") or {}).get("deny") or []):
            m = re.match(r"^Bash\(([\w.-]+)(?::\*|\s\*)?\)$", str(r))
            if m:
                out.add(m.group(1))
    return out


_KW = {"do", "then", "else", "elif", "!", "until", "while", "if", "time", "{", "(", "exec", "command", "sudo", "nice", "xargs"}


def monitor_hits(cmd, deny):
    hits = []
    for seg in re.split(r"\|\||&&|[;|\n]|\$\(|`|\(", cmd):
        toks = seg.strip().split()
        while toks and (toks[0] in _KW or re.match(r"^[A-Za-z_]\w*=", toks[0])):
            toks = toks[1:]
        if toks:
            w = os.path.basename(toks[0].strip("\"'"))
            if w in deny and w not in hits:
                hits.append(w)
    return hits


def _out(decision, text):
    if decision == "deny":
        o = {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                    "permissionDecisionReason": text}}
    else:
        o = {"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": text}}
    sys.stdout.write(json.dumps(o, ensure_ascii=False))


GUIDE = ("대안: ① 한 번 호출을 %d초 이내로 쪼개라 — 예: mcp__oio__bash_exec(timeout_ms=100000) 로 "
         "timeout 85 bash -c 'until <끝났는지 조건>; do sleep 10; done'; echo rc=$? 를 반복 호출(조건 예: test -f 완료파일, "
         "! pgrep -f \"[r]un.sh\" — 첫 글자를 [ ] 로 감싸야 자기 자신에 매칭되지 않는다). 호출 사이에 도착한 리드 메시지가 처리된다. "
         "② 긴 작업은 setsid nohup … & 로 분리하고 위 ① 로 완료를 확인한 뒤 SendMessage(to=\"team-lead\") 로 보고하라"
         "(띄우는 호출과 기다리는 호출은 나눠라 — 한 호출에 묶으면 바깥 셸 argv 에 경로가 남아 pgrep 이 영원히 참이 된다). "
         "③ sleep 은 'do sleep N' 처럼 do 바로 뒤에 둬라 — '…; sleep N' 꼴은 oio 가 자동 백그라운드로 넘겨 대기가 되지 않는다(bash_exec.py _LONG_RUNNING_PATTERNS).")


def main():
    try:
        inp = json.loads(sys.stdin.read() or "{}")
    except Exception:
        return
    tool = inp.get("tool_name")
    ti = inp.get("tool_input") or {}
    if tool == "mcp__oio__bash_exec" and ti.get("timeout") is not None:
        # timeout 별칭은 서버에서 ms 로 해석돼 90 → 1초로 절단된다(2026-10-28 v2.2.23 배포 중 실측). 메인·팀원 공통 차단.
        _out("deny", "⛔ timeout 은 ms 로 해석된다. 초 단위로 적은 값(예: timeout=900)은 약 1초로 잘려 명령이 중단된다. "
             "별칭 timeout 을 빼고 timeout_ms=<밀리초> 를 써라 (예: 90초 = timeout_ms=90000). 팀원은 90초(90000) 이내로 쓴다.")
        return
    cmd = str(ti.get("command") or ti.get("cmd") or "")
    if not cmd:
        return
    if tool == "Monitor":
        hits = monitor_hits(cmd, _deny_cmds())
        if hits:
            _out("deny", "⛔ [Monitor deny 목록 선검사] 이 Monitor 명령에 permissions.deny 로 막힌 명령(%s)이 들어 있어 "
                 "'Permission to use Bash … denied' 로 거부된다(리드·팀원 공통 — settings.json permissions.deny 의 Bash(%s:*)). "
                 "Monitor 명령은 test -f · pgrep · sleep · echo · date 만으로 '끝났다' 신호만 내고, 결과 내용은 끝난 뒤 "
                 "mcp__oio__file_read / mcp__oio__bash_exec 로 읽어라. 예: until test -f <완료파일>; do sleep 10; done; echo DONE"
                 % (", ".join(hits), hits[0]))
        return
    if tool != "mcp__oio__bash_exec" or not TEAMMATE:
        return
    if _detached(cmd):
        return
    est, why = estimate(cmd)
    if est > LIMIT:
        txt = ("⛔ [oio 장시간 호출 차단] 이 bash_exec 는 약 %s 걸릴 것으로 추정된다(%s). 팀원의 oio 호출은 %d초 이내여야 한다. "
               "120초를 넘기면 Claude Code 가 호출을 백그라운드로 넘기고, 그런 호출이 남은 세션은 이후 모든 oio 호출이 "
               "'Invalid request parameters' 로 실패했다(2026-10-10 odev-10-2·odev-10-4 실측, 팀원 교체). 긴 대기 중에는 리드 메시지도 처리되지 않는다. "
               % ("무한" if est == INF else "%d초" % est, why, LIMIT)) + GUIDE % LIMIT
        _out("deny" if MODE == "block" else "ctx", txt)
        return
    tmo = ti.get("timeout_ms", ti.get("timeout"))
    try:
        tmo = int(tmo) if tmo is not None else 0
    except (TypeError, ValueError):
        tmo = 0
    if tmo > 100000 and est == 0:
        _out("ctx", "⚠️ [oio 장시간 호출 주의] timeout_ms=%d 로 100초를 넘게 기다릴 수 있다. 120초를 넘기면 Claude Code 가 백그라운드로 "
             "넘기고 그 뒤 이 세션의 oio 가 'Invalid request parameters' 로 고장 날 수 있다(2026-10-10 실측). "
             "끝이 늦을 수 있는 명령(PowerShell·빌드·측정)은 setsid nohup … & 로 분리하고 85초 이내 호출로 완료를 확인하라." % tmo)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
