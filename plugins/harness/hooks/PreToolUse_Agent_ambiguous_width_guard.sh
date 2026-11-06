#!/bin/bash
# Agent 호출의 description·name 에 폭 모호(East Asian Ambiguous) 기호가 공백 없이 붙어 있으면 차단하고 보정본을 안내하는 PreToolUse hook
# [2026-10-11 도입] 팀원 pane 제목 "승인 채널→자동검증 게이트 계획" 에서 → 뒤 글자 '자' 가 겹쳐 그려졌다(사용자 보고).
#   → ★ ※ 등은 폭 A(Ambiguous) 라 1칸으로 세는 tmux/Claude Code 와 2칸으로 그리는 터미널이 어긋난다.
#   기호 뒤에 공백 1칸이 있으면 겹치는 자리가 공백이 되어 글자가 가려지지 않는다. 판정·보정은 lib/ambiguous_width.py 단일 출처.
# ★ 역할 분담 (2026-10-18) ★
#   description 은 inject hook(PreToolUse_Agent_sendmessage_toolsearch_inject.sh)이 자동 보정한다.
#   입력 교체 필드(hookSpecificOutput 의 updated-Input)를 내는 hook 은 inject 1개뿐이어야 하므로(tests/test_c172_spawn_inject.sh AC-007)
#   이 hook 은 그 필드를 내지 않고, description 은 검사하지 않는다.
#   name 은 SendMessage 주소라 보정하지 않고 deny 한다. deny 는 문서상 최우선(deny > defer > ask > allow)이며
#   사유는 에이전트에게 전달되어 스스로 재호출할 수 있다.
# name 은 SendMessage 주소라 보정본으로 바꾸면 안 된다 — 기호 없는 이름으로 다시 정하라고 안내한다.
# 실패 경로(python3 부재·파싱 실패·대상 아님)는 전부 무출력 exit 0(fail-open).
set -u
command -v python3 >/dev/null 2>&1 || exit 0
INPUT=$(timeout 5 cat 2>/dev/null) || exit 0
[ -n "$INPUT" ] || exit 0
_D="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || exit 0
[ -f "$_D/lib/ambiguous_width.py" ] || exit 0

printf '%s' "$INPUT" | AW_LIB="$_D/lib" python3 -c '
import json, os, sys
sys.path.insert(0, os.environ["AW_LIB"])
try:
    from ambiguous_width import is_ambiguous_symbol
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(d, dict) or d.get("tool_name") != "Agent":
    sys.exit(0)
ti = d.get("tool_input")
if not isinstance(ti, dict):
    sys.exit(0)
name = ti.get("name")
msgs = []
name_syms = []
if isinstance(name, str):
    for c in name:
        if is_ambiguous_symbol(c) and c not in name_syms:
            name_syms.append(c)
if name_syms:
    msgs.append(
        "name 에 폭 모호 기호(%s)가 있습니다. name 은 SendMessage 주소라 공백 보정 대상이 아닙니다. "
        "기호 없이 영문·숫자·하이픈으로 된 name 으로 바꿔 다시 호출하십시오."
        % " ".join(name_syms)
    )
if not msgs:
    sys.exit(0)
reason = "[ambiguous_width_guard] " + " / ".join(msgs)
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
      "permissionDecision": "deny", "permissionDecisionReason": reason}}, ensure_ascii=False))
' 2>/dev/null
exit 0
