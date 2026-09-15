#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# ui_test_guard.sh — XAML/Designer.cs 수정 시 otestuiwinforms 강제 검증
# PreToolUse: SendMessage hook — otest 완료 보고 차단

# 내부 오류 발생 시 안전하게 allow로 종료
trap 'exit 0' ERR

# 입력에서 tool 정보 읽기
INPUT=$(timeout 5 cat 2>/dev/null) || INPUT=""

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || echo "")

# SendMessage만 검사
[ "$TOOL_NAME" != "SendMessage" ] && exit 0

# message 타입 + "완료" 키워드 포함 시만 검사
MSG_TYPE=$(echo "$INPUT" | jq -r '.tool_input.type // empty' 2>/dev/null || echo "")
MSG_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty' 2>/dev/null || echo "")

# L-NEW: 옵션 B — SendMessage 메시지 본문 false positive 제거 (직전 사고 conv_177833472436 회귀)
# tool_input.message 필드가 있으면 팀에이전트 작업 보고/지시 메시지 → 차단 대상 아님
MSG_TEXT=$(echo "$INPUT" | jq -r '.tool_input.message // empty' 2>/dev/null || echo "")
if [ -n "$MSG_TEXT" ]; then
  exit 0
fi

[ "$MSG_TYPE" != "message" ] && exit 0
echo "$MSG_CONTENT" | grep -qE "(완료|PASS|통과|success)" || exit 0

# RETEST/진행보고 메시지인 경우 UI 완료 보고 아님 → 통과
if echo "$MSG_CONTENT" | grep -qE "(RETEST|재테스트|재검증|역라우팅|재검증 시작|작업 보고|진행 중)"; then
  exit 0
fi

# UUID 결정
source "${HARNESS_HOOK_DIR}/lib/session_id.sh" 2>/dev/null
resolve_uuid "$INPUT" 2>/dev/null || UUID="${CLAUDE_SESSION_ID}"
[[ -z "$UUID" ]] && exit 0

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SESSION_DIR="${CLAUDE_DIR}/session-env/${UUID}"

# F-B2 수정 (2026-08-20, otest-1 역라우팅 CONFIRMED): PIPELINE_UUID 환경변수는 hook 자식
# 프로세스에 전달되지 않는다(F-COMMIT-1과 동일 원인) → 팀에이전트가 UI 테스트 완료 메시지를
# 보낼 때 아래 조건이 항상 unset이라 evidence 검증이 통째로 스킵됐다.
# 조상 프로세스에서 --parent-session-id를 파싱해 실제 파이프라인 UUID를 얻는다
# (F-COMMIT-1/full_task_team_guard.sh에서 검증된 방식 재사용).
_UITG_PIPELINE_UUID="${PIPELINE_UUID:-}"
if [[ -z "$_UITG_PIPELINE_UUID" ]]; then
  _UITG_PID_WALK=$$
  _UITG_DEPTH_WALK=0
  while [[ $_UITG_DEPTH_WALK -lt 10 && -n "$_UITG_PID_WALK" && "$_UITG_PID_WALK" != "1" ]]; do
    _UITG_CMDLINE_WALK=$(tr '\0' ' ' < "/proc/${_UITG_PID_WALK}/cmdline" 2>/dev/null)
    if [[ "$_UITG_CMDLINE_WALK" =~ --parent-session-id[[:space:]]+([0-9a-f-]{36}) ]]; then
      _UITG_PIPELINE_UUID="${BASH_REMATCH[1]}"
      break
    fi
    _UITG_PID_WALK=$(awk '{print $4}' "/proc/${_UITG_PID_WALK}/stat" 2>/dev/null)
    (( _UITG_DEPTH_WALK++ )) || true
  done
fi

# §(c) 준수: 자기 세션만 evidence 검색 (타 세션 스캔 금지)
SESSION_DIR_CANDIDATES=()
if [[ -n "$_UITG_PIPELINE_UUID" ]] && [[ -d "${CLAUDE_DIR}/session-env/${_UITG_PIPELINE_UUID}/evidence" ]]; then
  SESSION_DIR_CANDIDATES+=("${CLAUDE_DIR}/session-env/${_UITG_PIPELINE_UUID}")
elif [[ -n "$UUID" ]] && [[ -d "${CLAUDE_DIR}/session-env/${UUID}/evidence" ]]; then
  SESSION_DIR_CANDIDATES+=("${CLAUDE_DIR}/session-env/${UUID}")
fi

# SESSION_DIR_CANDIDATES가 비어있으면 UUID 결정 불가 → 안전하게 통과 (false positive 차단 방지)
[ ${#SESSION_DIR_CANDIDATES[@]} -eq 0 ] && exit 0

# ui_touched.json 우선 분기 (false negative 차단)
for sd in "${SESSION_DIR_CANDIDATES[@]}"; do
  UI_TOUCHED_JSON="${sd}/evidence/ui_touched.json"
  if [ -f "$UI_TOUCHED_JSON" ]; then
    UI_TOUCHED=$(jq -r 'if has("touched") then .touched|tostring else "absent" end' "$UI_TOUCHED_JSON" 2>/dev/null || echo "absent")
    USER_OVERRIDE=$(jq -r '.user_override // false' "$UI_TOUCHED_JSON" 2>/dev/null || echo "false")
    # user_override=true면 강제 실행 흐름 유지 (touched 무시 → 아래 git diff 검사 진행)
    if [ "$USER_OVERRIDE" = "true" ]; then
      break
    fi
    # touched=false면 차단 없이 즉시 통과
    if [ "$UI_TOUCHED" = "false" ]; then
      echo "✅ [ui_test_guard] ui_touched.json: touched=false → 통과 (UI 미접촉 작업)"
      exit 0
    fi
    break
  fi
done
# (기존 흐름 계속 — PROJECT_ROOT 결정, git diff 검사 등)

# oinfra에서 ui_test 여부 확인
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
[ -z "$PROJECT_ROOT" ] && exit 0

UI_TEST=$(grep -r "ui_test:" "$PROJECT_ROOT/.claude/skills/" 2>/dev/null | grep "true" | head -1)
[ -z "$UI_TEST" ] && exit 0

# XAML/Designer.cs 수정 여부 확인
XAML_CHANGED=$(git -C "$PROJECT_ROOT" diff HEAD --name-only 2>/dev/null | grep -E "\.(xaml|axaml|Designer\.cs)$" | head -1)
[ -z "$XAML_CHANGED" ] && exit 0

# 앱 재시작 증거 확인 — 모든 SESSION_DIR 후보 탐색 (L-039)
RESTART_OK=0
for sd in "${SESSION_DIR_CANDIDATES[@]}"; do
  if [ -f "${sd}/evidence/app_restarted" ] || [ -f "${sd}/oapp_restarted" ]; then
    RESTART_OK=1
    break
  fi
done

if [ "$RESTART_OK" -eq 0 ]; then
  echo '{"decision":"block","reason":"🚫 XAML/Designer.cs 수정 감지. 앱 재시작 증거 파일 없음. otest_deploy에서 재시작 후 evidence/app_restarted 또는 oapp_restarted 생성 필요."}' | tee /dev/stderr
  exit 2
fi

# UI 테스트 증거 파일 확인 — 모든 SESSION_DIR 후보 탐색 (L-039)
UITEST_OK=0
for sd in "${SESSION_DIR_CANDIDATES[@]}"; do
  if [ -f "${sd}/evidence/ui_test_done" ]; then
    UITEST_OK=1
    break
  fi
done

if [ "$UITEST_OK" -eq 0 ]; then
  echo '{"decision":"block","reason":"🚫 XAML/Designer.cs 수정 감지. otestuiwinforms 미실행 — 완료 보고 차단. 증거 파일 없음. otestuiwinforms 먼저 실행 후 재시도하세요."}' | tee /dev/stderr
  exit 2
fi

echo "✅ [ui_test_guard] otestuiwinforms 실행 확인됨 → 완료 보고 허용"
exit 0
