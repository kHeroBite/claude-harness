#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# hook_test.sh — Hook Guard 최소 테스트 시나리오
# 용도: write_guard.sh 분리 전 핵심 차단 경로 회귀 테스트
# 실행: bash "${HARNESS_HOOK_DIR}/lib/hook_test.sh"
#
# 테스트 대상:
#   TC-01: P0 — Edit 도구 차단
#   TC-02: P0 — Write 도구 차단
#   TC-03: P1 — Bash mkdir 차단
#   TC-04: P1 — Bash rm 차단
#   TC-05: P1 — Bash cat 차단
#   TC-06: oio 탐색 — IDLE 상태 통과
#   TC-07: oi_route_guard — PLAN 상태에서 oi 미경유 차단
#   TC-08: ofinish_recurse_guard — FINISH 상태 ofinish 차단

HOOK_DIR="${HARNESS_HOOK_DIR:-$HOME/.claude/hooks}"
HOME_HOOKS="$HOME/.claude/hooks"
PASS=0
FAIL=0
SKIP=0

_run_test() {
  local TC_ID="$1"
  local TC_DESC="$2"
  local HOOK_PATH="$3"
  local INPUT_JSON="$4"
  local EXPECT_BLOCK="${5:-true}"  # true=차단 기대, false=통과 기대

  if [[ ! -f "$HOOK_PATH" ]]; then
    echo "  [SKIP] $TC_ID: $TC_DESC — hook 없음: $HOOK_PATH"
    SKIP=$((SKIP + 1))
    return
  fi

  local OUTPUT
  OUTPUT=$(echo "$INPUT_JSON" | bash "$HOOK_PATH" 2>/dev/null)
  local EXIT_CODE=$?

  if [[ "$EXPECT_BLOCK" == "true" ]]; then
    if echo "$OUTPUT" | grep -q '"decision":"block"' || [[ $EXIT_CODE -eq 2 ]]; then
      echo "  [PASS] $TC_ID: $TC_DESC"
      PASS=$((PASS + 1))
    else
      echo "  [FAIL] $TC_ID: $TC_DESC — 차단 기대했으나 통과됨 (exit=$EXIT_CODE)"
      echo "         output: $OUTPUT"
      FAIL=$((FAIL + 1))
    fi
  else
    if ! echo "$OUTPUT" | grep -q '"decision":"block"' && [[ $EXIT_CODE -ne 2 ]]; then
      echo "  [PASS] $TC_ID: $TC_DESC"
      PASS=$((PASS + 1))
    else
      echo "  [FAIL] $TC_ID: $TC_DESC — 통과 기대했으나 차단됨 (exit=$EXIT_CODE)"
      echo "         output: $OUTPUT"
      FAIL=$((FAIL + 1))
    fi
  fi
}

echo "=== Hook Guard 회귀 테스트 ==="
echo ""

# TC-01: P0 — Edit 도구 차단
_run_test "TC-01" "Edit 도구 전면 차단" \
  "$HOME_HOOKS/write_guard.sh" \
  '{"tool_name":"Edit","session_id":"test-session-01","tool_input":{"file_path":"/mnt/c/test.cs"}}' \
  true

# TC-02: P0 — Write 도구 차단
_run_test "TC-02" "Write 도구 전면 차단" \
  "$HOME_HOOKS/write_guard.sh" \
  '{"tool_name":"Write","session_id":"test-session-01","tool_input":{"file_path":"/mnt/c/test.txt"}}' \
  true

# TC-03: P1 — Bash mkdir 차단
_run_test "TC-03" "Bash mkdir → oio dir_create 차단" \
  "$HOME_HOOKS/write_guard.sh" \
  '{"tool_name":"Bash","session_id":"test-session-01","tool_input":{"command":"mkdir /mnt/c/newdir"}}' \
  true

# TC-04: P1 — Bash rm 차단
_run_test "TC-04" "Bash rm → oio file_delete 차단" \
  "$HOME_HOOKS/write_guard.sh" \
  '{"tool_name":"Bash","session_id":"test-session-01","tool_input":{"command":"rm -f /mnt/c/file.txt"}}' \
  true

# TC-05: P1 — Bash cat 차단
_run_test "TC-05" "Bash cat → oio file_read 차단" \
  "$HOME_HOOKS/write_guard.sh" \
  '{"tool_name":"Bash","session_id":"test-session-01","tool_input":{"command":"cat /mnt/c/file.txt"}}' \
  true

# TC-06: P1 — Bash grep 차단
_run_test "TC-06" "Bash grep → Grep 도구 차단" \
  "$HOME_HOOKS/write_guard.sh" \
  '{"tool_name":"Bash","session_id":"test-session-01","tool_input":{"command":"grep -r pattern /mnt/c/"}}' \
  true

# TC-07: ofinish_recurse_guard — FINISH 상태 ofinish 차단
# 실제 session-env 경로에 임시 상태 설정
_TC07_UUID="00000000-test-ofinish-recurse-$$"
_TC07_DIR="${HOME}/.claude/session-env/${_TC07_UUID}"
mkdir -p "$_TC07_DIR"
echo "FINISH $_TC07_UUID" > "$_TC07_DIR/state"

_run_test "TC-07" "FINISH 상태에서 ofinish 재귀 차단" \
  "$HOME_HOOKS/ofinish_recurse_guard.sh" \
  "{\"tool_name\":\"Skill\",\"session_id\":\"${_TC07_UUID}\",\"tool_input\":{\"skill\":\"ofinish\"}}" \
  true

rm -rf "$_TC07_DIR" 2>/dev/null

# TC-09: PLAN 상태 + 메인(PIPELINE_UUID 없음) + Grep NTFS 경로 → 차단 (Fix 1)
_TC09_UUID="00000000-test-fix1-plan-$$"
_TC09_DIR="${HOME}/.claude/session-env/${_TC09_UUID}"
mkdir -p "$_TC09_DIR"
echo "PLAN $_TC09_UUID" > "$_TC09_DIR/state"

_run_test "TC-09" "PLAN+메인+Grep NTFS 경로 차단 (Fix 1)" \
  "$HOME_HOOKS/write_guard.sh" \
  "{\"tool_name\":\"Grep\",\"session_id\":\"${_TC09_UUID}\",\"tool_input\":{\"pattern\":\"test\",\"path\":\"${CLAUDE_PROJECT_DIR:-/tmp/testproj}/src\"}}" \
  true

rm -rf "$_TC09_DIR" 2>/dev/null

# TC-10: bash_exec 체인 명령 + .claude/ 포함 → DEV 상태에서 차단 (Fix 2)
# DEV 상태 + PIPELINE_UUID 없는 메인 + .claude/ 포함 + 체인 명령 → 파이프라인 활성 차단
_TC10_UUID="00000000-test-fix2-dev-$$"
_TC10_DIR="${HOME}/.claude/session-env/${_TC10_UUID}"
mkdir -p "$_TC10_DIR"
echo "DEV $_TC10_UUID" > "$_TC10_DIR/state"

_run_test "TC-10" "bash_exec .claude/+체인 명령 DEV 상태 차단 (Fix 2)" \
  "$HOME_HOOKS/write_guard.sh" \
  "{\"tool_name\":\"mcp__oio__bash_exec\",\"session_id\":\"${_TC10_UUID}\",\"tool_input\":{\"command\":\"bash ~/.claude/scripts/team-report.sh && rm -rf /mnt/c/\"}}" \
  true

rm -rf "$_TC10_DIR" 2>/dev/null

# TC-11: oio file_write → session-env/UUID/state → 차단 (Fix 3)
_run_test "TC-11" "oio file_write session-env/state 직접 쓰기 차단 (Fix 3)" \
  "$HOME_HOOKS/write_guard.sh" \
  "{\"tool_name\":\"mcp__oio__file_write\",\"session_id\":\"test-session-11\",\"tool_input\":{\"path\":\"${HOME}/.claude/session-env/test-uuid-fix3/state\",\"content\":\"IDLE\"}}" \
  true

# TC-12: PLAN + 팀에이전트(PIPELINE_UUID 있음) + Grep NTFS → 통과 (회귀 방지)
_TC12_UUID="00000000-test-fix1-team-$$"
_TC12_DIR="${HOME}/.claude/session-env/${_TC12_UUID}"
mkdir -p "$_TC12_DIR"
echo "PLAN $_TC12_UUID" > "$_TC12_DIR/state"

PIPELINE_UUID="test-uuid-1234" _run_test "TC-12" "PLAN+팀에이전트(PIPELINE_UUID)+Grep NTFS 통과 (Fix 1 회귀)" \
  "$HOME_HOOKS/write_guard.sh" \
  "{\"tool_name\":\"Grep\",\"session_id\":\"${_TC12_UUID}\",\"tool_input\":{\"pattern\":\"test\",\"path\":\"${CLAUDE_PROJECT_DIR:-/tmp/testproj}/src\"}}" \
  false

rm -rf "$_TC12_DIR" 2>/dev/null

echo ""
echo "=== 결과: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ==="

if [[ $FAIL -gt 0 ]]; then
  echo "❌ 테스트 실패 — write_guard.sh 분리 착수 전 수정 필요"
  exit 1
else
  echo "✅ 모든 테스트 통과 — 분리 착수 가능"
  exit 0
fi
