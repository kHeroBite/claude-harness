#!/bin/bash
# shutdown_guard.sh — 빌드/배포 외 상황에서 shutdown/taskkill 차단 (L-036)
#                    + state=DEV 팀에이전트의 Mars.exe 기동 차단 (L-C158-D/F-MARS-START, 사이클159)
# PreToolUse:Bash|mcp__oio__bash_exec hook
# 원본: prebuild_shutdown.sh에서 L-036 가드만 분리 (dotnet build 전처리 로직 제거 — oio bash_exec 전환으로 도달 불가)
# 2026-09-22(사이클159): matcher를 Bash 단독→Bash|mcp__oio__bash_exec 로 확장(Mars settings.json) —
#   기존 로직은 Claude 내장 Bash 도구에만 등록돼 있어 CLAUDE.md 강제 도구인 mcp__oio__bash_exec
#   호출에는 전혀 발동하지 않는 죽은 hook 상태였다(write_guard.sh F-OTO-7B 주석의 동형 사례 재확인).

trap 'exit 0' ERR
INPUT=$(timeout 5 cat 2>/dev/null) || INPUT=""
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // .tool_input.cmd // empty' 2>/dev/null || echo "")
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")

[ -z "$COMMAND" ] && exit 0

# ═════════════════════════════════════════════════════════════════════════
# F-MARS-START: 사이클159 — state=DEV 팀에이전트의 Mars.exe 기동 차단
#   (L-C158-D 위반 재발방지 — odev는 코드 수정만, 기동은 obuild/otest_run(state=TEST) 전용)
#   우회 5경로 판정표는 handoff_dev_to_test_odev1.md 참조.
# ═════════════════════════════════════════════════════════════════════════
if [[ ! -f "${HARNESS_HOME:-$HOME/.harness}/current/hooks/DISABLE_MARS_START_GUARD" ]] && ! echo "$COMMAND" | grep -q "dotnet build"; then
  _MARS_START_HIT=0
  if echo "$COMMAND" | grep -qiE '(^|[^A-Za-z])start[[:space:]]+.*[Mm][Aa][Rr][Ss]\.[Ee][Xx][Ee]'; then
    _MARS_START_HIT=1
  elif echo "$COMMAND" | grep -qiE 'start-process[^|&]*[Mm][Aa][Rr][Ss]\.[Ee][Xx][Ee]'; then
    _MARS_START_HIT=1
  elif echo "$COMMAND" | grep -qiE 'invoke-item[^|&]*[Mm][Aa][Rr][Ss]\.[Ee][Xx][Ee]'; then
    _MARS_START_HIT=1
  elif echo "$COMMAND" | grep -qiE '&[[:space:]]*["'"'"']?[^|&]*[Mm][Aa][Rr][Ss]\.[Ee][Xx][Ee]'; then
    _MARS_START_HIT=1
  elif echo "$COMMAND" | grep -qiE '(subprocess\.(popen|call|run)|os\.(system|startfile))' && echo "$COMMAND" | grep -qiE '[Mm][Aa][Rr][Ss]\.[Ee][Xx][Ee]'; then
    _MARS_START_HIT=1
  fi

  # 2차 검사: .ps1/.cmd/.bat/.py 파일을 실행 인자로 참조하면 그 내용까지 grep
  # (파일 부재/읽기 실패 = fail-closed 아님 — 경고 후 통과, team-lead 명시 결정)
  if [[ "$_MARS_START_HIT" -eq 0 ]]; then
    _SCRIPT_PATH=$(echo "$COMMAND" | grep -oiE '[^"'"'"'[:space:]]+\.(ps1|cmd|bat|py)' | tail -1)
    if [[ -n "$_SCRIPT_PATH" ]]; then
      if [[ "$_SCRIPT_PATH" =~ ^[A-Za-z]: ]]; then
        _WSL_SCRIPT_PATH=$(wslpath -u "$_SCRIPT_PATH" 2>/dev/null || echo "")
      else
        _WSL_SCRIPT_PATH="$_SCRIPT_PATH"
      fi
      if [[ -n "$_WSL_SCRIPT_PATH" && -r "$_WSL_SCRIPT_PATH" ]]; then
        if grep -qiE '(start[[:space:]]+.*mars\.exe|start-process[^|&]*mars\.exe|invoke-item[^|&]*mars\.exe|&[[:space:]]*["'"'"']?[^|&]*mars\.exe|(subprocess\.(popen|call|run)|os\.(system|startfile)).*mars\.exe)' "$_WSL_SCRIPT_PATH" 2>/dev/null; then
          _MARS_START_HIT=1
        fi
      else
        echo "⚠️ [F-MARS-START 2차검사] 스크립트 파일 접근 실패(부재/읽기불가) — 경고 후 통과: $_SCRIPT_PATH" >&2
      fi
    fi
  fi

  if [[ "$_MARS_START_HIT" -eq 1 && -n "${PIPELINE_UUID:-}" ]]; then
    source ${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/session_id.sh 2>/dev/null || true
    _MS_STATE=$(state_read "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${PIPELINE_UUID}/state" | awk '{print $1}')
    _MS_STATE=${_MS_STATE:-IDLE}
    if [[ "$_MS_STATE" == "DEV" ]]; then
      source ${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/write_error.sh 2>/dev/null || true
      declare -f log_hook_error >/dev/null 2>&1 && log_hook_error "HOOK_BLOCK_MARS_START" "mcp__oio__bash_exec" "state=DEV 팀에이전트가 Mars.exe 기동 시도" "$SESSION_ID"
      echo '{"decision":"block","reason":"🚫 [L-C158-D/F-MARS-START] state=DEV 구간에서 Mars.exe 기동 명령이 차단되었습니다. odev 는 코드 수정만 담당하며 기동·재기동은 obuild/otest_run(state=TEST) 전용입니다. 조사 목적으로 기동이 필요하면 team-lead 에게 SendMessage 로 요청하십시오. 비상 시 hooks/DISABLE_MARS_START_GUARD 로 우회 가능."}' | tee /dev/stderr
      exit 2
    fi
  fi
fi
# --- F-MARS-START 끝 ---

# shutdown/taskkill 명령인지 확인
if ! echo "$COMMAND" | grep -qiE "api/shutdown|taskkill.*/IM\s"; then
  exit 0
fi

# dotnet build와 함께 실행되는 경우 허용 (빌드 전 정리)
if echo "$COMMAND" | grep -q "dotnet build"; then
  exit 0
fi

# UUID 기반 세션별 state 파일에서 확인
source ${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/session_id.sh 2>/dev/null || true
resolve_uuid "$INPUT" 2>/dev/null || UUID="${SESSION_ID}"
[[ -z "$UUID" ]] && exit 0
STATE=$(state_read "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/state" | awk '{print $1}')
STATE=${STATE:-IDLE}

# DEV/TEST/IDLE에서 허용. PLAN/DONE/FINISH에서는 차단 (Phase B: state=OK 제거 — L-431)
if [[ "$STATE" != "DEV" && "$STATE" != "TEST" && "$STATE" != "IDLE" ]]; then
  source ${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/write_error.sh
  log_hook_error "HOOK_BLOCK_SHUTDOWN_L036" "Bash" "빌드 외 상황에서 shutdown/taskkill 시도 (파이프라인: $STATE)" "$SESSION_ID"
  echo '{"decision":"block","reason":"🚫 [L-036] shutdown/taskkill은 빌드/배포 단계에서만 허용됩니다."}' | tee /dev/stderr
  exit 2
fi

exit 0
