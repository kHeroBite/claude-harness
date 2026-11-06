#!/bin/bash
# 세션 롤 범위(+자기 영역 paths) 밖 파일 쓰기에 additionalContext 경고만 붙이는 PreToolUse hook (차단 없음)
#
# 계획 conv_179356702591 §6.5. 프로젝트 루트(cwd 에서 위로)에 .claude/role_paths.json 이 있을 때만 동작한다.
# - permissionDecision 을 내지 않는다(경고 전용). 항상 exit 0.
# - 롤 없음/all → 무출력. 판정은 role_lib check_path(shared→OK, 자기 롤·영역→OK, 다른 롤·영역→WARN, 미등재→OK).
# - 팀원은 PIPELINE_UUID(리드 세션) 롤을 상속한다. 경고는 자기(=리드 파이프라인) session-env logs/role_scope_warn.log 에 1줄.
INPUT=$(timeout 5 cat 2>/dev/null) || INPUT=""
[ -z "$INPUT" ] && exit 0

# 빠른 거름: role_paths.json 이 없으면 python 을 띄우지 않고 끝낸다.
_CWD=""
[[ "$INPUT" =~ \"cwd\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]] && _CWD="${BASH_REMATCH[1]}"
[ -z "$_CWD" ] && _CWD="$PWD"
_d="$_CWD"; _ROOT=""
while [ -n "$_d" ]; do
  if [ -f "$_d/.claude/role_paths.json" ]; then _ROOT="$_d"; break; fi
  [ "$_d" = "/" ] && break
  _d="${_d%/*}"; [ -z "$_d" ] && _d="/"
done
[ -z "$_ROOT" ] && exit 0

_HD="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
_LIB="$_HD/lib/role_lib.py"
[ -r "$_LIB" ] || _LIB="${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/role_lib.py"
[ -r "$_LIB" ] || exit 0

read -r -d '' _PY <<'PY'
import json, os, sys
LIB, ROOT = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.dirname(os.path.abspath(LIB)))
import role_lib as R


def main():
    try:
        d = json.loads(sys.stdin.read())
    except ValueError:
        return
    if not isinstance(d, dict):
        return
    sid = os.environ.get("PIPELINE_UUID", "").strip()
    if not R.UUID_RE.match(sid):
        sid = str(d.get("session_id") or "").strip()
    if not R.UUID_RE.match(sid):
        return
    sid = sid.lower()
    value = R.current_role(sid)
    rid, _ = R.split_value(value)
    if rid == "all":
        return
    tool = str(d.get("tool_name") or "")
    ti = d.get("tool_input") or {}
    if not isinstance(ti, dict):
        return
    cwd = d.get("cwd") or os.getcwd()
    paths = []
    for k in ("file_path", "path", "filepath", "notebook_path", "destination", "dest", "target"):
        v = ti.get(k)
        if isinstance(v, str) and v.strip():
            paths.append(v.strip())
    if tool.endswith("file_move") and isinstance(ti.get("source"), str):
        paths.append(ti["source"])
    if tool.endswith("file_rename") and isinstance(ti.get("new_name"), str) and isinstance(ti.get("path"), str):
        paths.append(os.path.join(os.path.dirname(ti["path"]), ti["new_name"]))
    warns, seen = [], set()
    for p in paths:
        ap = p if os.path.isabs(p) else os.path.join(cwd, p)
        ap = os.path.normpath(ap)
        if ap in seen:
            continue
        seen.add(ap)
        res = R.check_path(value, ROOT, ap)
        if res.startswith("WARN"):
            owner = res[4:].strip()
            rel = R.rel_to_root(ROOT, ap) or ap
            warns.append((rel, owner))
            R.log_line(sid, "role_scope_warn.log", "WARN role=%s tool=%s path=%s owner=%s" % (value, tool, rel, owner))
    if not warns:
        return
    lst = ", ".join("%s(%s 담당)" % (r, o) for r, o in warns)
    msg = ("⚠️ [롤 범위 밖] 내 롤 %s 의 담당 경로가 아니다: %s. 롤 밖 수정이면 직접 하지 말고 Skill('orole') 인계 절차로 넘기거나, "
           "사용자가 롤 밖 수행을 원하면 `/orole all` 로 바꾸도록 안내하라. (경고만 — 차단 아님)" % (value, lst))
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": msg}}, ensure_ascii=False))


try:
    main()
except Exception:
    pass
PY

printf '%s' "$INPUT" | timeout 4 python3 -B -I -c "$_PY" "$_LIB" "$_ROOT" 2>/dev/null || true
exit 0
