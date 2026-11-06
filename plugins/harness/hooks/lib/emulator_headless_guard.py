# -no-window 없는 Android 에뮬레이터 실행(사용자 화면에 창 노출)을 막는 PreToolUse 판정 코어
"""
입력: stdin = PreToolUse hook JSON (tool_name = mcp__oio__bash_exec | Bash)
env : EHG_MODE=block|warn (기본 block), EHG_MARKER_DIRS(테스트용 — ':' 구분 세션 디렉터리 목록, 미지정 시 실환경에서 계산)
출력: stdout 에 hookSpecificOutput JSON(deny 또는 additionalContext) 또는 무출력. 항상 exit 0(fail-open).

판정(명령 문자열 정적 분석):
  1. 따옴표 안 텍스트·heredoc 본문·# 주석은 실행으로 보지 않는다(echo "emulator -avd x", git commit -m '…' 오탐 방지).
     단, bash|sh|dash|zsh|eval|cmd|powershell|pwsh|wsl 이 넘기는 문자열 인자는 재귀 분석한다(우회 방지, 깊이 3).
  2. 따옴표 밖의 ; | & 괄호 개행으로 구간을 나누고, 구간 첫 실행 토큰(env 대입·setsid·nohup·exec·time·timeout N·env·sudo 등 뒤)이
     emulator / emulator.exe / emulator64-* / qemu-system-* / $…EMULATOR… 변수이면 에뮬 실행 구간이다.
  3. 에뮬 실행 구간에 -avd·@avd 가 있고 -no-window 가 없으면 위반. -list-avds·-version·-help·-list-cameras·-webcam-list 는 통과.
  4. avd_boot.sh 구간에 --windowed 가 있으면 위반(창 모드 명시 기동).
  5. 세션 마커 session-env/<UUID>/emulator_windowed_ok 가 있으면 통과(사용자 요청이 있을 때만 리드가 둔다).
     UUID 는 env PIPELINE_UUID(팀원)와 입력 JSON 의 session_id(메인) 둘 다 본다.
한계: 변수 간접화(E=emulator; $E -avd x)·파일에 쓴 스크립트 안의 emulator 호출은 못 잡는다(스크립트 본문은 보지 않는다).
"""
import json
import os
import re
import sys

MODE = os.environ.get("EHG_MODE", "block")
ENV_ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
WRAPPERS = {"setsid", "nohup", "exec", "time", "env", "sudo", "nice", "stdbuf", "command", "ionice", "chrt", "xargs"}
SHELLS = {"bash", "sh", "dash", "zsh", "eval", "cmd", "cmd.exe", "powershell", "powershell.exe",
          "pwsh", "pwsh.exe", "wsl", "wsl.exe", "su", "python", "python3", "perl", "node", "ruby"}
SAFE_ARGS = {"-list-avds", "-version", "-help", "-list-cameras", "-webcam-list", "-help-all"}


def _base(tok):
    return re.split(r"[\\/]", tok.strip("\"'"))[-1]


def _is_emulator(tok):
    t = tok.strip("\"'")
    if re.match(r"^\$\{?[A-Za-z_]*EMULATOR[A-Za-z_]*\}?$", t, re.I):
        return True
    b = re.sub(r"\.exe$", "", _base(t).lower())
    return bool(re.match(r"^(emulator(64)?(-[a-z0-9_]+)*|qemu-system-[a-z0-9_\-]+)$", b))


def _strip_heredoc(cmd):
    out, lines, i = [], cmd.split("\n"), 0
    while i < len(lines):
        ln = lines[i]
        out.append(ln)
        i += 1
        m = re.search(r"<<-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?", ln)
        if m:
            body = []
            while i < len(lines) and lines[i].strip() != m.group(1):
                body.append(lines[i])
                i += 1
            i += 1
            if re.search(r"\b(bash|sh|dash|zsh)\b", ln):   # 셸에 넘기는 heredoc 은 본문이 코드다
                out.extend(body)
    return "\n".join(out)


def _tokenize(seg):
    """따옴표를 인식하는 토큰화. (토큰 원문, 따옴표 포함 여부) 목록."""
    toks, i, n = [], 0, len(seg)
    while i < n:
        if seg[i].isspace():
            i += 1
            continue
        buf, quoted = "", False
        while i < n and not seg[i].isspace():
            c = seg[i]
            if c in "\"'":
                j = i + 1
                while j < n and seg[j] != c:
                    if c == '"' and seg[j] == "\\" and j + 1 < n:
                        j += 1
                    j += 1
                buf += seg[i:j + 1]
                quoted = True
                i = j + 1
            else:
                buf += c
                i += 1
        toks.append((buf, quoted))
    return toks


def _split_segments(cmd):
    segs, cur, q, i = [], "", "", 0
    while i < len(cmd):
        c = cmd[i]
        if q:
            cur += c
            if c == q:
                q = ""
            elif c == "\\" and q == '"' and i + 1 < len(cmd):
                cur += cmd[i + 1]
                i += 1
        elif c in "\"'":
            q = c
            cur += c
        elif c in ";|&\n()":
            segs.append(cur)
            cur = ""
        else:
            cur += c
        i += 1
    segs.append(cur)
    return [s for s in segs if s.strip()]


def _unquote(t):
    return t[1:-1] if len(t) >= 2 and t[0] in "\"'" and t[-1] == t[0] else t


def _analyze(cmd, depth=0):
    """위반 설명 문자열 목록."""
    viol = []
    if depth == 0:
        cmd = _strip_heredoc(cmd)
    cmd = re.sub(r"(?m)(^|\s)#.*$", r"\1", cmd)
    cmd = cmd.replace('""', "").replace("''", "")          # emu""lator 같은 빈 따옴표 쪼개기 정규화
    for seg in _split_segments(cmd):
        toks = _tokenize(seg)
        k = 0
        while k < len(toks):
            t, qd = toks[k]
            b = _base(t)
            if ENV_ASSIGN.match(t) and not qd:
                k += 1
            elif b in WRAPPERS:
                k += 1
            elif b == "timeout":
                k += 1
                while k < len(toks) and (toks[k][0].startswith("-") or re.match(r"^\d+[smhd]?$", toks[k][0])):
                    k += 1
            else:
                break
        if k >= len(toks):
            continue
        head = toks[k][0]
        hb = _base(head).lower()
        rest = [_unquote(x[0]) for x in toks[k + 1:]]
        if hb in SHELLS:
            if depth < 3:
                for r in rest:                       # -c 'payload' 같은 공백 포함 문자열 인자는 코드로 본다
                    if re.search(r"\s", r):
                        viol += _analyze(r, depth + 1)
                if rest and not any(re.search(r"\s", r) for r in rest):
                    r2 = list(rest)
                    while r2 and re.match(r"^[/-][A-Za-z]{1,12}$", r2[0]):
                        r2.pop(0)                                 # /c -c -Command 같은 셸 옵션 제거
                    viol += _analyze(" ".join(r2), depth + 1)     # cmd /c emulator.exe -avd x 처럼 풀어 쓴 경우
            continue
        if _is_emulator(head):
            if any(a in SAFE_ARGS for a in rest):
                continue
            has_avd = any(a == "-avd" or a.startswith("@") or a.startswith("-avd=") for a in rest)
            if has_avd and "-no-window" not in rest:
                viol.append("emulator -avd 에 -no-window 가 없다")
        elif hb == "avd_boot.sh" and "--windowed" in rest:
            viol.append("avd_boot.sh --windowed (창 모드 기동)")
    return viol


def _marker_ok(data):
    dirs = os.environ.get("EHG_MARKER_DIRS")
    if dirs is not None:
        return any(os.path.isfile(os.path.join(d, "emulator_windowed_ok")) for d in dirs.split(":") if d)
    base = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
    for u in (os.environ.get("PIPELINE_UUID", ""), str(data.get("session_id", ""))):
        if u and re.match(r"^[0-9A-Za-z\-]+$", u) and \
                os.path.isfile(os.path.join(base, "session-env", u, "emulator_windowed_ok")):
            return True
    return False


GUIDE = ("사용자 화면에 에뮬레이터 창이 뜨는 실행은 금지다(상시 제약: 사용자 활동 중 화면 노출 UI 금지). "
         "-no-window -no-audio 를 붙이거나 scripts/avd_boot.sh(기본 헤드리스)를 써라 — Skill('otest_mobile_emulator_bg') 참조. "
         "사용자가 창 모드를 명시 요청했거나 헤드리스 실패를 실측했다면 SendMessage(to=\"team-lead\") 로 보고하고 "
         "리드가 세션 마커 emulator_windowed_ok 를 둔 뒤에만 진행한다.")


def _out(decision, text):
    if decision == "deny":
        o = {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                    "permissionDecisionReason": text}}
    else:
        o = {"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": text}}
    sys.stdout.write(json.dumps(o, ensure_ascii=False))


def main():
    try:
        data = json.loads(sys.stdin.read() or "{}")
        cmd = (data.get("tool_input") or {}).get("command") or ""
        if not isinstance(cmd, str) or not cmd.strip():
            return
        viol = _analyze(cmd)
        if not viol or _marker_ok(data):
            return
        text = "🚫 [EHG] %s. %s" % ("; ".join(sorted(set(viol))), GUIDE)
        _out("deny" if MODE == "block" else "warn", text)
    except Exception:
        return


if __name__ == "__main__":
    main()
    sys.exit(0)
