#!/usr/bin/env python3
# 리드가 남긴 중지(stop)/범위(scope) 마커를 팀원 도구 호출 직전에 전달·강제하는 PreToolUse 판정 코어 (L-1195)
"""stop_marker_gate.py — PreToolUse_stop_marker_gate.sh 가 호출한다.

마커 규약(정본 — 리드/메인이 쓴다):
  경로: session-env/<LEAD>/scope_markers/<팀원이름>.json   (특정 팀원)
        session-env/<LEAD>/scope_markers/_all.json         (팀 전체)
        session-env/<LEAD>/scope_markers/_user.json        (자동 — UserPromptSubmit 이 PLAN~DONE 중 사용자 입력 원문을
                                                            type=info 로 기록, lib/scope_marker_autowrite.py. info 는 1회 전달 후 통과)
  형식: {"type": "stop" | "scope", "message": "사용자 지시 원문/범위", "by": "team-lead", "created_at": "ISO8601"}
        JSON 파싱 실패·type 누락 → stop 으로 간주(리드가 의도적으로 쓴 파일이므로 fail-closed), message=원문.
  해제: 리드가 파일을 삭제한다. 내용을 바꾸면 팀원에게 다시 전달된다(sha1 기준).
  만료: info/scope 는 파일 mtime 이 SM_SCOPE_TTL_H(기본 24)시간을 넘으면 무시한다. stop 은 만료 없음.

판정 (env SM_SESSION_DIR=리드 세션 디렉토리, SM_AGENT=팀원 이름):
  1) 미확인 마커(ack 없음/내용 변경) → 내용 전달 + ack 기록. stop 이 섞여 있으면 1회 deny,
     info/scope 만이면 additionalContext 로 전달하고 통과(2026-10-10 — 신규 spawn 팀원 첫 호출 오류 제거)
       ack: scope_markers/.ack/<팀원>__<마커파일명>.sha1
  2) 확인된 stop 마커 → 읽기·보고 도구(ALLOW_ON_STOP)만 통과, 나머지(쓰기·셸·DB·UI·spawn) deny
  3) 확인된 scope 마커 → 통과 (내용은 1회 전달 완료)
  4) 팀원이 scope_markers 경로(셸은 변경 동사 동반 시) 또는 게이트 스위치(DISABLE_STOP_MARKER_GATE·
     DISABLE_SNAPSHOT_GATE·snapshot_gate_mode)를 건드리는 비읽기 도구 호출 → 항상 deny (마커 삭제·스위치 우회 차단)
     — 스위치는 사용자·리드 전용이다. 읽기 전용 셸 조회(_readonly_shell)는 통과, 그 밖은 deny.
출력: deny JSON 또는 무출력. 로그: <SM_SESSION_DIR>/logs/stop_marker_gate.log
내부 오류 → 무출력 (fail-open).
"""
import hashlib
import json
import os
import re
import shlex
import sys
import time

ALLOW_ON_STOP = {
    "Read", "Grep", "Glob", "LS", "ToolSearch", "SendMessage", "ListAgents",
    "TaskList", "TaskGet", "TaskOutput",
    "mcp__oio__file_read", "mcp__oio__find", "mcp__oio__list_dir", "mcp__oio__file_info",
    "mcp__oio__get_cwd", "mcp__oio__lock_status", "mcp__oio__session_state",
}
READ_TOOLS = ALLOW_ON_STOP - {"SendMessage"}
# info/scope 마커 유효 시간(시간). 지나면 전달하지 않는다. stop 은 무기한(리드가 삭제할 때 해제)
SCOPE_TTL = float(os.environ.get("SM_SCOPE_TTL_H", "24")) * 3600
# 팀원이 변경할 수 없는 경로/스위치 (첫 항목만 셸에서 변경 동사 동반 시로 완화)
PROTECTED = ("scope_markers", "DISABLE_STOP_MARKER_GATE", "DISABLE_SNAPSHOT_GATE", "snapshot_gate_mode")

# 스위치 이름이 들어 있어도 통과시키는 읽기 전용 셸 조회 (사이클203 — 판정은 보수적: 아니면 종전대로 deny)
#   조건(전부): 금지 구문 없음 · /dev/null·fd 복제 외 리다이렉션 없음 · 모든 세그먼트의 첫 단어가 읽기 전용 명령
READONLY_CMDS = {"grep", "egrep", "fgrep", "cat", "head", "tail", "wc", "ls", "stat", "test", "[",
                 "jq", "diff", "cmp", "sha256sum", "sha1sum", "md5sum", "file", "readlink", "realpath",
                 "basename", "dirname", "cut", "tr", "echo", "printf", "true", ":", "cd", "date"}
_RO_BAN = re.compile(r"\$\(|`|<\(|>\(|\$\{[^}]*[:=?]|\b(?:eval|exec|source|xargs)\b|--pre\b")
_RO_SAFE_REDIR = re.compile(r"&>\s*/dev/null|\d?>\s*/dev/null|\d?>&\d")
_RO_SEP = {";", "&&", "||", "|", "&", "(", ")", ";;", "|&"}


def _readonly_shell(cmd):
    if not cmd.strip() or _RO_BAN.search(cmd):
        return False
    c = _RO_SAFE_REDIR.sub(" ", cmd)
    if ">" in c:
        return False
    try:
        lx = shlex.shlex(c.replace("\n", " ; "), posix=True, punctuation_chars=True)
        lx.whitespace_split = True
        toks = list(lx)
    except ValueError:
        return False
    seg = []
    for t in toks + [";"]:
        if t in _RO_SEP:
            if t in ("(", ")"):
                return False
            words = [w for w in seg if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", w)] if seg else []
            if seg and words and words[0] not in READONLY_CMDS:
                return False
            seg = []
        else:
            seg.append(t)
    return True


def _log(sdir, line):
    try:
        os.makedirs(os.path.join(sdir, "logs"), exist_ok=True)
        with open(os.path.join(sdir, "logs", "stop_marker_gate.log"), "a", encoding="utf-8") as f:
            f.write("%s %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), line))
    except Exception:
        pass


def _deny(msg):
    sys.stdout.write(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse", "permissionDecision": "deny",
        "permissionDecisionReason": msg}}, ensure_ascii=False))


def _load(path):
    with open(path, "rb") as f:
        raw = f.read()
    sha = hashlib.sha1(raw).hexdigest()
    text = raw.decode("utf-8", errors="replace")
    try:
        d = json.loads(text)
        if not isinstance(d, dict):
            raise ValueError
    except Exception:
        d = {"type": "stop", "message": text.strip()}
    typ = str(d.get("type") or "stop").strip().lower()
    if typ not in ("stop", "scope", "info"):
        typ = "stop"
    return {"type": typ, "suspected": str(d.get("suspected") or ""),
            "message": str(d.get("message") or ""), "by": str(d.get("by") or "?"),
            "created_at": str(d.get("created_at") or ""), "sha": sha, "file": os.path.basename(path)}


_NULL_REDIR_RE = re.compile(
    r"&>>?[ \t]*/dev/null(?![\w./-])"          # &>/dev/null, &>>/dev/null
    r"|[0-9]*>>?[ \t]*/dev/null(?![\w./-])"   # >/dev/null, 2>/dev/null, 1>>/dev/null
    r"|[0-9]*>&[0-9]+(?![\w./-])"             # 2>&1, >&2
)


def _strip_null_redirects(cmd):
    """파일을 바꾸지 않는 리다이렉트만 지운 문자열(판정용). /dev/null 뒤에 경로 글자가 이어지면 지우지 않는다."""
    return _NULL_REDIR_RE.sub(" ", cmd)


def main():
    sdir = os.environ.get("SM_SESSION_DIR", "")
    agent = os.environ.get("SM_AGENT", "")
    if not sdir or not agent:
        return
    try:
        data = json.loads(sys.stdin.read() or "{}")
    except Exception:
        data = {}
    tool = str(data.get("tool_name") or "")
    mdir = os.path.join(sdir, "scope_markers")

    # 4) 마커 경로 변조 차단 (마커 존재 여부 무관)
    #    파일 도구: 경로 인자에 /scope_markers/ — 셸: 명령에 scope_markers + 변경 동사/리다이렉션
    #    (파일 '내용'에 단어가 들어간 것만으로는 막지 않는다 — hook·문서 편집 오차단 방지)
    ti = data.get("tool_input") or {}
    tamper = False
    if tool not in READ_TOOLS and isinstance(ti, dict):
        paths = " ".join(str(ti.get(k) or "") for k in (
            "file_path", "path", "filepath", "old_path", "new_path", "src", "dst", "source",
            "destination", "target", "notebook_path"))
        if any(k in paths for k in PROTECTED):
            tamper = True
        cmd = str(ti.get("command") or ti.get("cmd") or "")
        if any(k in cmd for k in PROTECTED[1:]) and not _readonly_shell(cmd):
            tamper = True  # 게이트 스위치는 팀원이 셸로 만들거나 바꿀 수 없다(touch 포함). 읽기 전용 조회(grep 등)만 통과(사이클203)
        # 사이클206: 무해한 리다이렉트(2>/dev/null·>/dev/null·&>/dev/null·2>&1·>&2)는 파일을 바꾸지 않으므로 '>' 판정에서 뺀다.
        #   실측 과차단: `jq -c . <세션>/scope_markers/_user.json 2>/dev/null | head` 가 변조로 차단됐다(09:47).
        #   그 밖의 '>'(실제 파일 덮어쓰기·추가)와 rm·mv·tee 등은 그대로 막는다.
        if "scope_markers" in cmd and re.search(r"\b(?:rm|mv|cp|truncate|unlink|tee|ln|shred)\b|sed\s+-i|>",
                                                 _strip_null_redirects(cmd)):
            tamper = True
    if tamper:
        _log(sdir, "DENY agent=%s tool=%s reason=marker_tamper" % (agent, tool))
        _deny("🚫 [stop_marker_gate L-1195] 팀원은 scope_markers(리드의 중지·범위 지시)와 게이트 스위치(DISABLE_*·snapshot_gate_mode)를 변경·삭제할 수 없습니다. "
              "지시 해제는 team-lead 에게 SendMessage 로 요청하세요.")
        return

    markers = []
    now = time.time()
    for fn in (agent + ".json", "_all.json", "_user.json"):
        p = os.path.join(mdir, fn)
        if os.path.isfile(p):
            try:
                m = _load(p)
                # 만료(2026-10-10 c174): info/scope 는 파일 mtime 기준 SCOPE_TTL 이 지나면 무시한다.
                #   10-08 의 scope 마커가 이틀째 모든 신규 팀원에게 전달됐다. stop 은 만료하지 않는다(리드가 지워야 해제).
                if m["type"] in ("info", "scope") and now - os.path.getmtime(p) > SCOPE_TTL:
                    continue
                markers.append(m)
            except Exception:
                continue
    if not markers:
        return

    adir = os.path.join(mdir, ".ack")
    # 1) 미확인 마커 전달
    fresh = []
    for m in markers:
        ack = os.path.join(adir, "%s__%s.sha1" % (agent, m["file"]))
        try:
            with open(ack, "r", encoding="utf-8") as f:
                if f.read().strip() == m["sha"]:
                    continue
        except Exception:
            pass
        fresh.append((m, ack))
    if fresh:
        lines = ["📌 [stop_marker_gate L-1195] team-lead 의 사용자 지시 마커가 있습니다 — 이 호출은 확인용으로 1회 보류됐습니다."]
        for m, ack in fresh:
            tag = m["type"].upper() + ("(중지성 어휘 감지)" if m["suspected"] == "stop" else
                                       "(범위성 어휘 감지)" if m["suspected"] == "scope" else "")
            lines.append("- [%s] (%s, by %s %s) %s" % (tag, m["file"], m["by"], m["created_at"], m["message"]))
            try:
                os.makedirs(adir, exist_ok=True)
                with open(ack, "w", encoding="utf-8") as f:
                    f.write(m["sha"])
            except Exception:
                pass
        if any(m["type"] == "stop" for m, _ in fresh):
            lines.append("STOP: 즉시 쓰기·셸·DB·UI 조작을 멈추고 진행 상태를 team-lead 에게 SendMessage 로 보고하세요. 읽기·보고 도구만 허용됩니다.")
        elif any(m["type"] == "info" and m["suspected"] == "stop" for m, _ in fresh):
            lines.append("INFO(중지 의심): 사용자 입력에 중지성 어휘가 있습니다. 이 지시가 지금 작업의 중지라면 쓰기·DB·UI 조작을 "
                         "멈추고 team-lead 에게 SendMessage 로 확인을 받으세요. 무관하면 같은 호출을 다시 시도하세요(재시도는 통과).")
        elif any(m["type"] == "scope" or m["suspected"] == "scope" for m, _ in fresh):
            lines.append("SCOPE: 위 범위 지시를 따르도록 계획을 조정한 뒤 같은 호출을 다시 시도하세요(재시도는 통과합니다).")
        else:
            lines.append("INFO: 파이프라인 중 들어온 사용자 입력 원문입니다. 지금 작업과 충돌하면 team-lead 에게 확인하고, "
                         "무관하면 같은 호출을 다시 시도하세요(재시도는 통과합니다).")
        if any(m["type"] == "stop" for m, _ in fresh):
            # stop 만 물리 보류한다 — 쓰기를 멈추게 하는 것이 목적이므로 deny 가 맞다
            _log(sdir, "DELIVER agent=%s tool=%s markers=%s" % (agent, tool, ",".join(m["file"] for m, _ in fresh)))
            _deny("\n".join(lines))
            return
        # info/scope 는 deny 대신 additionalContext 로 전달하고 호출은 통과시킨다 (2026-10-10 c174).
        #   종전: ack 가 팀원 이름별이라 새로 spawn 된 팀원은 예외 없이 첫 호출이 "hook error" 로 보였다(하루 374건).
        #   공식 근거: PreToolUse hookSpecificOutput.additionalContext 는 system reminder 로 모델에 전달된다
        #   (code.claude.com/docs/en/hooks "Add context for Claude"). 내용 전달은 유지되고 오류만 사라진다.
        lines[0] = "📌 [stop_marker_gate L-1195] team-lead 의 사용자 지시 마커를 전달합니다(이 호출은 그대로 진행됩니다)."
        lines = [ln.replace("무관하면 같은 호출을 다시 시도하세요(재시도는 통과).", "무관하면 그대로 진행하세요.")
                   .replace("같은 호출을 다시 시도하세요(재시도는 통과합니다).", "그대로 진행하세요.") for ln in lines]
        _log(sdir, "INFORM agent=%s tool=%s markers=%s" % (agent, tool, ",".join(m["file"] for m, _ in fresh)))
        sys.stdout.write(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse", "additionalContext": "\n".join(lines)}}, ensure_ascii=False))
        return

    # 2) 확인된 stop → 허용 목록 외 차단
    stops = [m for m in markers if m["type"] == "stop"]
    if stops and tool not in ALLOW_ON_STOP:
        _log(sdir, "DENY agent=%s tool=%s reason=stop markers=%s" % (agent, tool, ",".join(m["file"] for m in stops)))
        _deny("🚫 [stop_marker_gate L-1195] 중지 지시 유효(%s): %s\n읽기·SendMessage 만 허용됩니다. 해제는 team-lead 가 마커를 삭제할 때입니다."
              % (stops[0]["file"], stops[0]["message"]))
        return
    # 3) scope 확인 완료 → 통과


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
