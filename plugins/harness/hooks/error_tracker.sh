#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# error_tracker.sh — 작업 중 오류 자동 감지 & 기록 + 해결 자동 추적
# PostToolUse(Bash|Edit|Write) — 오류 패턴 감지 시 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/logs/errors.md에 기록
# odone_review에서 이 파일을 참조하여 교훈 분석 수행
# 호환: WSL + Windows (Git Bash / MSYS2)
#
# ⚠️ 알려진 제약 (L-040): Claude Code는 Bash 도구 실패(exit code != 0) 시
#    PostToolUse hook을 호출하지 않음. 따라서 cp 실패, ls 실패 등 Bash 에러는
#    이 hook으로 감지 불가. odone_review Step 0.5 소스 B(트랜스크립트 스캔)로 보완.

trap 'exit 0' ERR
INPUT=$(timeout 5 cat 2>/dev/null) || INPUT=""
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || echo "")

# MCP 도구(mcp__*) 조기 스킵 — MCP 서버 내부에서 에러 처리
case "$TOOL_NAME" in
  mcp__*) exit 0 ;;
esac

STDOUT=$(echo "$INPUT" | jq -r '.tool_response.stdout // empty' 2>/dev/null || echo "")
STDERR=$(echo "$INPUT" | jq -r '.tool_response.stderr // empty' 2>/dev/null || echo "")
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")

# 세션 ID fallback: 환경변수 → PID 기반
if [ -z "$SESSION_ID" ] || [ "$SESSION_ID" = "null" ]; then
  SESSION_ID="${CLAUDE_SESSION_ID:-$$}"
fi
# UUID 결정 — 세션별 상태 파일 경로
source "${HARNESS_HOOK_DIR}/lib/session_id.sh"
resolve_uuid "$INPUT" || { UUID="nosid"; }
[[ -z "$UUID" ]] && exit 0
SID="$UUID"
SESSION_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}"
mkdir -p "${SESSION_DIR}/logs" 2>/dev/null

ERROR_LOG="${SESSION_DIR}/logs/errors.md"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# WSL2 전용 환경 — macOS 호환 코드 제거 (Phase 3 정리)

# ═══════════════════════════════════════════════════════════
# 오류 기록 함수
# ═══════════════════════════════════════════════════════════
write_error() {
  local category="$1"
  local cmd_summary="$2"
  local detail="$3"

  # 에러 ID 생성 (순번)
  local err_count=0
  if [ -f "$ERROR_LOG" ]; then
    err_count=$(grep -c '^### ERR-' "$ERROR_LOG" 2>/dev/null || echo "0")
  fi
  local err_id=$((err_count + 1))

  # 파일 없으면 헤더 생성
  if [ ! -f "$ERROR_LOG" ]; then
    cat > "$ERROR_LOG" << HEADER
# 오류 추적 로그
- 세션: ${UUID}
- 생성: ${TIMESTAMP}

---

HEADER
  fi

  # HOOK_BLOCK 카테고리는 "정상 차단(방어 성공)"이므로 즉시 해결 처리
  local status="**미해결**"
  local resolution="(자동 추적 대기)"
  if [[ "$category" == HOOK_BLOCK* ]]; then
    status="**해결됨(정상차단)**"
    resolution="hook이 위반 시도를 정상 차단 (${TIMESTAMP})"
  fi

  cat >> "$ERROR_LOG" << ENTRY
### ERR-${err_id}: ${category}
- 시각: ${TIMESTAMP}
- 도구: ${TOOL_NAME}
- 명령: \`$(echo "$cmd_summary" | head -c 200)\`
- 상세:
\`\`\`
$(echo "$detail" | head -c 500)
\`\`\`
- 상태: ${status}
- 해결방법: ${resolution}

---

ENTRY

}

# ═══════════════════════════════════════════════════════════
# Bash 오류 감지
# ═══════════════════════════════════════════════════════════
detect_bash_error() {
  [ "$TOOL_NAME" = "Bash" ] || return 1

  # 1. dotnet build 실패
  if echo "$COMMAND" | grep -q "dotnet build"; then
    if echo "$STDOUT" | grep -q "Build FAILED"; then
      local detail
      detail=$(echo "$STDOUT" | grep -oP 'error CS\d+:.*' 2>/dev/null | head -5)
      [ -z "$detail" ] && detail=$(echo "$STDOUT" | grep -i "error" | head -5)
      write_error "BUILD_FAILED" "$COMMAND" "$detail"
      return 0
    fi
  fi

  # 2. REST API 에러 (4xx/5xx)
  if echo "$STDOUT" | grep -q '"statusCode":[45]'; then
    local detail
    detail=$(echo "$STDOUT" | head -10)
    write_error "RESTAPI_ERROR" "$COMMAND" "$detail"
    return 0
  fi

  # 3. curl 연결 실패
  if echo "$COMMAND" | grep -q "curl"; then
    if echo "$STDOUT$STDERR" | grep -qi "Connection refused\|Failed to connect\|Could not resolve\|timed out"; then
      local detail
      detail=$(echo "$STDOUT$STDERR" | grep -i "connect\|resolve\|timed" | head -2)
      write_error "CONNECTION_FAILED" "$COMMAND" "$detail"
      return 0
    fi
  fi

  # 4. 로그에서 Exception/FATAL 발견
  if echo "$COMMAND" | grep -qiE "api/logs|/logs/"; then
    if echo "$STDOUT" | grep -qi "Exception\|FATAL"; then
      local detail
      detail=$(echo "$STDOUT" | grep -i "Exception\|FATAL" | head -3)
      write_error "RUNTIME_EXCEPTION" "$COMMAND" "$detail"
      return 0
    fi
  fi

  # 5. rsync/cp 실패
  if echo "$COMMAND" | grep -q "rsync\|cp "; then
    if echo "$STDOUT$STDERR" | grep -qi "error\|failed\|No such file"; then
      local detail
      detail=$(echo "$STDOUT$STDERR" | grep -i "error\|failed\|No such" | head -2)
      write_error "FILE_SYNC_ERROR" "$COMMAND" "$detail"
      return 0
    fi
  fi

  # 6. dotnet 런타임 에러 (build 외)
  if echo "$COMMAND" | grep -q "dotnet"; then
    if echo "$STDOUT" | grep -qi "Unhandled exception\|error NU\|error MSB"; then
      local detail
      detail=$(echo "$STDOUT" | grep -i "exception\|error" | head -3)
      write_error "DOTNET_ERROR" "$COMMAND" "$detail"
      return 0
    fi
  fi

  # 7. git 오류
  if echo "$COMMAND" | grep -q "git "; then
    if echo "$STDOUT$STDERR" | grep -qi "fatal:\|error:\|CONFLICT"; then
      local detail
      detail=$(echo "$STDOUT$STDERR" | grep -i "fatal\|error\|CONFLICT" | head -3)
      write_error "GIT_ERROR" "$COMMAND" "$detail"
      return 0
    fi
  fi

  # 8. otest 실패 감지 (Phase 실패 패턴)
  if echo "$STDOUT" | grep -qiE "FAIL|실패|❌.*Phase|테스트.*실패|Test Run Failed"; then
    if echo "$COMMAND" | grep -qiE "otest|dotnet test|playwright|npm test"; then
      local detail
      detail=$(echo "$STDOUT" | grep -iE "FAIL|실패|❌|error|Failed" | head -5)
      write_error "OTEST_FAIL" "$COMMAND" "$detail"
      return 0
    fi
  fi

  # 9. PowerShell 오류
  if echo "$COMMAND" | grep -qi "powershell\|pwsh"; then
    if echo "$STDOUT$STDERR" | grep -qi "FullyQualifiedErrorId\|CommandNotFoundException\|Cannot find"; then
      local detail
      detail=$(echo "$STDOUT$STDERR" | grep -i "Error\|Cannot\|Exception" | head -3)
      write_error "POWERSHELL_ERROR" "$COMMAND" "$detail"
      return 0
    fi
  fi

  return 1
}

# ═══════════════════════════════════════════════════════════
# Edit/Write 오류 감지
# ═══════════════════════════════════════════════════════════
detect_edit_error() {
  [ "$TOOL_NAME" = "Edit" ] || [ "$TOOL_NAME" = "Write" ] || return 1

  local file_path
  file_path=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || echo "")

  # Edit/Write 실패 감지: stderr에 에러 메시지
  if [ -n "$STDERR" ] && echo "$STDERR" | grep -qi "error\|failed\|ENOENT\|permission denied"; then
    write_error "EDIT_WRITE_FAILED" "${TOOL_NAME}: ${file_path}" "$STDERR"
    return 0
  fi

  # stdout에 에러 메시지 (일부 에러는 stdout으로 나옴)
  if [ -n "$STDOUT" ] && echo "$STDOUT" | grep -qi "old_string not found\|not unique\|ENOENT"; then
    write_error "EDIT_WRITE_FAILED" "${TOOL_NAME}: ${file_path}" "$STDOUT"
    return 0
  fi

  return 1
}

# ═══════════════════════════════════════════════════════════
# 해결 자동 감지
# ═══════════════════════════════════════════════════════════
detect_resolution() {
  [ -f "$ERROR_LOG" ] || return 0
  grep -q '상태: \*\*미해결\*\*' "$ERROR_LOG" || return 0

  # HOOK_BLOCK 카테고리: write_error() 시점에 이미 **해결됨(정상차단)** 마킹됨
  # → detect_resolution()에서 별도 처리 불필요

  # 빌드 성공 → 미해결 BUILD_FAILED 해결
  if echo "$STDOUT" | grep -q "Build succeeded"; then
    if grep -q 'BUILD_FAILED' "$ERROR_LOG"; then
      sed -i '/BUILD_FAILED/,/^---/{
        s/상태: \*\*미해결\*\*/상태: **해결됨**/
        s|해결방법: (자동 추적 대기)|해결방법: 빌드 오류 수정 후 재빌드 성공 ('"$TIMESTAMP"')|
      }' "$ERROR_LOG"
    fi
  fi

  # 헬스체크 성공 → 미해결 CONNECTION_FAILED 해결
  if echo "$COMMAND" | grep -q "api/health"; then
    if echo "$STDOUT" | grep -qi "healthy\|ok\|running"; then
      if grep -q 'CONNECTION_FAILED' "$ERROR_LOG"; then
        sed -i '/CONNECTION_FAILED/,/^---/{
          s/상태: \*\*미해결\*\*/상태: **해결됨**/
          s|해결방법: (자동 추적 대기)|해결방법: 서비스 재시작 후 연결 복구 ('"$TIMESTAMP"')|
        }' "$ERROR_LOG"
      fi
    fi
  fi

  # otest 재통과 → 미해결 OTEST_FAIL 해결
  if echo "$STDOUT" | grep -qiE "PASS|통과|✅.*Phase|테스트.*성공|Test Run Successful|Build succeeded"; then
    if grep -q 'OTEST_FAIL' "$ERROR_LOG" 2>/dev/null; then
      sed -i '/OTEST_FAIL/,/^---/{
        s/상태: \*\*미해결\*\*/상태: **해결됨**/
        s|해결방법: (자동 추적 대기)|해결방법: 테스트 재실행 후 통과 ('"$TIMESTAMP"')|
      }' "$ERROR_LOG"
    fi
  fi

  # REST API 정상 응답 → 미해결 RESTAPI_ERROR 해결
  if echo "$COMMAND" | grep -q "api/"; then
    if ! echo "$COMMAND" | grep -q "api/health\|api/shutdown"; then
      if echo "$STDOUT" | grep -q '"statusCode":200\|"success":true\|"data"'; then
        if grep -q 'RESTAPI_ERROR' "$ERROR_LOG"; then
          sed -i '/RESTAPI_ERROR/,/^---/{
            s/상태: \*\*미해결\*\*/상태: **해결됨**/
            s|해결방법: (자동 추적 대기)|해결방법: API 오류 수정 후 정상 응답 확인 ('"$TIMESTAMP"')|
          }' "$ERROR_LOG"
        fi
      fi
    fi
  fi
}

# ═══════════════════════════════════════════════════════════
# 범용 도구 오류 감지 (Bash/Edit/Write 이외의 모든 도구)
# ═══════════════════════════════════════════════════════════
detect_general_error() {
  # Bash/Edit/Write는 전용 함수에서 처리
  case "$TOOL_NAME" in
    Bash|Edit|Write) return 1 ;;
  esac

  # stderr에 에러 패턴
  if [ -n "$STDERR" ]; then
    # 정상 출력에서 흔한 "error" 제외 (grep 결과, 로그 표시 등)
    if echo "$STDERR" | grep -qiE '(^Error:|^error:|failed to|Exception:|ENOENT|Permission denied|not found|connection refused|timed out|FATAL)'; then
      local category="${TOOL_NAME}_ERROR"
      local summary
      summary=$(echo "$STDERR" | grep -iE '(Error|failed|Exception|ENOENT|Permission|not found|refused|timed out|FATAL)' | head -3)
      write_error "$category" "$TOOL_NAME" "$summary"
      return 0
    fi
  fi

  # stdout에 에러 패턴 (일부 도구는 stderr 대신 stdout으로 에러 반환)
  if [ -n "$STDOUT" ]; then
    if echo "$STDOUT" | grep -qiE '(^Error:|^error:|failed to|Exception:|ENOENT|Permission denied|No such file|ToolError|tool_use_error)'; then
      local category="${TOOL_NAME}_ERROR"
      local summary
      summary=$(echo "$STDOUT" | grep -iE '(Error|failed|Exception|ENOENT|Permission|No such file|ToolError|tool_use_error)' | head -3)
      write_error "$category" "$TOOL_NAME" "$summary"
      return 0
    fi
  fi

  return 1
}

# ═══════════════════════════════════════════════════════════
# otest FAIL 감지 (evidence 기반)
# ═══════════════════════════════════════════════════════════
detect_otest_fail() {
  local evidence_dir="${SESSION_DIR}/evidence"
  local otest_fail_marker="${evidence_dir}/otest_fail_detail"

  # otest_fail_detail 파일 존재 시 errors.md에 기록 (표준 포맷 — write_error 활용)
  if [ -f "$otest_fail_marker" ]; then
    local fail_detail
    fail_detail=$(cat "$otest_fail_marker" 2>/dev/null | head -c 500)

    # 이미 기록됐는지 확인 (중복 방지)
    local marker_hash
    marker_hash=$(md5sum "$otest_fail_marker" 2>/dev/null | cut -c1-8)
    if ! grep -q "otest_fail_hash:${marker_hash}" "$ERROR_LOG" 2>/dev/null; then
      write_error "OTEST_FAIL" "otest_fail_detail" "${fail_detail} (otest_fail_hash:${marker_hash})"
      echo "📝 [error_tracker] otest FAIL → errors.md 기록"
    fi
  fi
}

# otest PASS 시 해결 마킹 (otest_done evidence가 생성될 때)
resolve_otest_fail() {
  [ ! -f "$ERROR_LOG" ] && return 0

  # 미처리 OTEST_FAIL을 해결로 마킹
  if grep -q "OTEST_FAIL" "$ERROR_LOG" 2>/dev/null; then
    sed -i '/### ERR-[0-9]*: OTEST_FAIL/,/^---/{
      s/상태: \*\*미해결\*\*/상태: **해결됨(otest PASS)**/
    }' "$ERROR_LOG" 2>/dev/null
    echo "✅ [error_tracker] OTEST_FAIL 해결 마킹 완료"
  fi
}

# ═══════════════════════════════════════════════════════════
# 실행: 해결 감지 먼저 → 오류 감지 → otest 감지
# ═══════════════════════════════════════════════════════════
detect_resolution
detect_bash_error || detect_edit_error || detect_general_error

# otest evidence 기반 감지
detect_otest_fail

# otest PASS 시 해결 마킹 (otest_done evidence 존재 시)
if [ -f "${SESSION_DIR}/evidence/otest_done" ]; then
  resolve_otest_fail
fi

exit 0
