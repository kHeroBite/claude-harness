#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# 팀에이전트가 SendMessage 없이 턴을 끝내는 것을 판정하는 공용 라이브러리 (판정 단일 출처)
#
# 배경: 2026-08-17 팀에이전트 보고 유실 3건(verify-1 / diag-1 / odev-2).
#   세 에이전트 모두 보고 내용을 "화면 텍스트"로만 출력하고 SendMessage 도구를
#   호출하지 않은 채 턴을 종료했다. 화면 텍스트는 team-lead에게 전달되지 않으므로
#   메인은 보고를 영영 받지 못했다.
#   증적: .claude/evidence/c3_report_hook_20260817.md
#
# 설계 원칙:
#   1. L-457 단일 출처 — 판정 로직은 이 파일에만 둔다.
#      호출부(SubagentStop_report_guard.sh)는 stdin 파싱 + 호출 + 출력만 담당한다.
#   2. fail-open 엄격 — 의심스러우면 통과시킨다. 예외/파싱실패/미지원 형식은 전부 UNKNOWN.
#      과잉 차단은 원래 문제(보고 유실)보다 피해가 크다. 4개 프로젝트 공유 자산이다.
#   3. set -e 금지 — 중간 실패가 곧 차단이 되어서는 안 된다. set -u 만 사용한다.
#   4. 정상 종료 5형태를 반드시 통과시킨다(실측 근거).
#      shutdown_request 수신 / 사용자 중단 / 로컬 명령(/exit) / 첫 턴 / TaskOutput 계열.
#      이 예외를 빼면 shutdown 받은 에이전트가 전부 block되어 파이프라인이 마비된다.
#
# 긴급 정지 스위치 (의도적 설계 — orphan_scan.sh 와 동일 양식):
#   이 파일을 삭제/이동하면 호출부가 fail-open 되어 아무 것도 차단하지 않는다.
#     touch ~/.claude/hooks/DISABLE_REPORT_GUARD          # ① 가장 빠름 (settings 무수정)
#     mv report_guard.sh report_guard.sh.disabled         # ② 판정 불능 → 전량 통과
#     mv report_guard.sh.disabled report_guard.sh         # ② 복구
#   ①② 모두 settings.json 을 건드리지 않는다 (2026-05-02 활성 세션 캐시 사고 회피).
#
# 제공 함수 / CLI:
#   report_guard_verdict <transcript_path>  — 판정 결과 1줄을 stdout 출력
#   CLI: bash report_guard.sh verdict <transcript_path>
#
# 출력 규약 (호출부 fail-open 계약):
#   위반 : BLOCK <턴번호> <도구수> <도구명 콤마목록>
#   정상 : PASS
#   불명 : UNKNOWN            ← 호출부는 "BLOCK " 접두 정확 일치일 때만 차단한다
#

[[ -n "${_REPORT_GUARD_LOADED:-}" ]] && return 0 2>/dev/null
_REPORT_GUARD_LOADED=1

set -u

# 판정 본체. 실패 시 어떤 경우에도 UNKNOWN 을 출력하고 rc 0 으로 끝난다.
report_guard_verdict() {
    local tp="${1:-}"

    [[ -z "$tp" ]] && { echo "UNKNOWN"; return 0; }
    [[ -r "$tp" ]] || { echo "UNKNOWN"; return 0; }
    command -v python3 >/dev/null 2>&1 || { echo "UNKNOWN"; return 0; }

    local out
    out="$(python3 - "$tp" <<'PYEOF' 2>/dev/null
import sys, json

# 마지막 턴만 필요하므로 꼬리 일부만 읽는다. 17MB 실측 파일 대비 성능 상한.
MAX_LINES = 3000

def out(s):
    print(s)
    sys.exit(0)

try:
    path = sys.argv[1]
except Exception:
    out("UNKNOWN")

try:
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        lines = f.readlines()
except Exception:
    out("UNKNOWN")

if not lines:
    out("UNKNOWN")

# 상한 초과 시 꼬리만 취한다(역방향 스캔과 동등 효과).
truncated = len(lines) > MAX_LINES
if truncated:
    lines = lines[-MAX_LINES:]

rows = []
for ln in lines:
    ln = ln.strip()
    if not ln:
        continue
    try:
        rows.append(json.loads(ln))   # 쓰기 중 부분 행은 조용히 skip
    except Exception:
        continue

if not rows:
    out("UNKNOWN")


def content_of(row):
    """message.content 를 반환. 문자열 / 리스트 / None 전부 가능."""
    try:
        msg = row.get("message")
        if not isinstance(msg, dict):
            return None
        return msg.get("content")
    except Exception:
        return None


def content_text(row):
    """content 를 검색 가능한 하나의 문자열로 평탄화한다."""
    c = content_of(row)
    if c is None:
        return ""
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        parts = []
        for it in c:
            if isinstance(it, str):
                parts.append(it)
            elif isinstance(it, dict):
                t = it.get("text")
                if isinstance(t, str):
                    parts.append(t)
                ty = it.get("type")
                if isinstance(ty, str):
                    parts.append(ty)
        return "\n".join(parts)
    return ""


def is_turn_boundary(row):
    """새 사용자 턴의 시작인가.

    type=="user" AND isMeta 아님 AND content 가 tool_result 전용이 아닌 행.
    tool_result 만 있는 user 행은 도구 응답이지 새 턴이 아니다.
    이 구분이 없으면 턴 수가 폭증해 첫 턴 판정(E2)이 깨진다.
    """
    if row.get("type") != "user":
        return False
    if row.get("isMeta"):
        return False
    c = content_of(row)
    if isinstance(c, str):
        return c.strip() != ""
    if isinstance(c, list):
        if not c:
            return False
        # 전부 tool_result 이면 턴 경계가 아니다.
        for it in c:
            if not (isinstance(it, dict) and it.get("type") == "tool_result"):
                return True
        return False
    return False


# --- 턴 경계 계수 + 마지막 경계 위치 ---
turn_count = 0
last_idx = -1
for i, r in enumerate(rows):
    if is_turn_boundary(r):
        turn_count += 1
        last_idx = i

if last_idx < 0:
    out("UNKNOWN")

# E2 — 첫 턴 예외. 단 꼬리만 읽은 경우 턴 수를 신뢰할 수 없으므로 적용하지 않는다.
if turn_count <= 1 and not truncated:
    out("PASS")

last_turn_text = content_text(rows[last_idx])

# E3 — shutdown_request 수신 후 종료 (실측 3건: 06c71844 / 26f2a4a3 / 6d8eff5e)
if '"type":"shutdown_request"' in last_turn_text.replace(" ", "") \
        or "shutdown_request" in last_turn_text:
    out("PASS")

# E4 — 사용자 중단 (실측 1건: 89cbcd9d)
if "[Request interrupted by user]" in last_turn_text:
    out("PASS")

# E5 — 로컬 명령 종료 (실측 1건: 2801f4a4 — /exit → Goodbye!)
if "<local-command-stdout>" in last_turn_text or "<command-name>" in last_turn_text:
    out("PASS")

# --- 마지막 턴 경계 이후의 assistant 도구 호출 수집 ---
tools = []
for r in rows[last_idx + 1:]:
    if r.get("type") != "assistant":
        continue
    c = content_of(r)
    if not isinstance(c, list):
        continue
    for it in c:
        if isinstance(it, dict) and it.get("type") == "tool_use":
            n = it.get("name")
            if isinstance(n, str) and n:
                tools.append(n)

# E6 — TaskOutput 계열로 반환한 경우
for t in tools:
    if t in ("TaskOutput", "EndConversation"):
        out("PASS")

# 도구를 하나도 안 쓴 턴은 순수 대화 응답일 수 있어 위험 대비 이득이 낮다.
if not tools:
    out("PASS")

# 정상 — 보고를 발신했다.
if "SendMessage" in tools:
    out("PASS")

# --- 위반 확정 ---
# L-478 — 원 정보를 가리지 않는다. 에이전트가 자기가 방금 무엇을 했는지 볼 수 있어야 한다.
uniq = []
for t in tools:
    if t not in uniq:
        uniq.append(t)
names = ",".join(uniq[:15])
out("BLOCK %d %d %s" % (turn_count, len(tools), names))
PYEOF
)"

    # 파이썬이 죽었거나 빈 출력이면 통과시킨다.
    if [[ -z "$out" ]]; then
        echo "UNKNOWN"
        return 0
    fi

    # 규격 외 문자열은 전부 통과 (호출부도 BLOCK 정확 일치만 차단하지만 이중 방어).
    case "$out" in
        BLOCK\ *|PASS|UNKNOWN) echo "$out" ;;
        *)                     echo "UNKNOWN" ;;
    esac
    return 0
}

# CLI 진입점 — 직접 실행된 경우에만 동작한다 (source 시에는 함수만 제공).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        verdict) report_guard_verdict "${2:-}" ;;
        *)       echo "UNKNOWN" ;;
    esac
    exit 0
fi
