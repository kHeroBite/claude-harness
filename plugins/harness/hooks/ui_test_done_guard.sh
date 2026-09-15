#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# ui_test_done_guard.sh — Phase 2.5 UI 테스트 완료 증거 검증 (PreToolUse:Agent)
# odone spawn 시 O4/O5 분류에서 프로젝트 유형별 UI 테스트 증거 파일 없으면 차단 (O3 제외)
trap 'exit 0' ERR

INPUT=$(timeout 5 cat 2>/dev/null) || INPUT=""
TEAM_NAME=$(echo "$INPUT" | jq -r '.tool_input.team_name // empty' 2>/dev/null || echo "")

# 팀에이전트 spawn이 아니면 패스
[[ -z "$TEAM_NAME" ]] && exit 0

# odone spawn인지 확인
AGENT_NAME=$(echo "$INPUT" | jq -r '.tool_input.name // ""' 2>/dev/null || echo "")
echo "$AGENT_NAME" | grep -qE "^odone" || exit 0

# UUID 결정
source "${HARNESS_HOOK_DIR}/lib/session_id.sh"
resolve_uuid "$INPUT" 2>/dev/null || UUID="${CLAUDE_SESSION_ID}"
[[ -z "$UUID" ]] && exit 0
SESSION_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}"
# HOME 폴백 경로: cc-prefix 와 $HOME/.claude 경로 분리 대응 (L-cc-prefix 사고)
HOME_SESSION_DIR="$HOME/.claude/session-env/${UUID}"
# 사이클46 축① — 반대편 base 미러
source "${HARNESS_HOOK_DIR}/lib/session_mirror.sh" 2>/dev/null
type _mirror_file >/dev/null 2>&1 || _mirror_file() { :; }

# O1/O2/O3 분류는 UI 테스트 불필요 -- 스킵
CLASSIFICATION=$(cat "${SESSION_DIR}/classification" 2>/dev/null || echo "")
# §(a) 준수: classification 빈값이어도 타 세션 UUID 역추적 금지 — fail-closed
# [P2-isolation] L-278 UUID 역추적 fallback 제거 (Fix 31, 2026-04-24)
# 이전 동작: find session-env -name team_name 전체 순회 → 타 세션 UUID 채택 (§(a)(c) 위반)
# 수정: PIPELINE_UUID가 올바르지 않으면 차단 불가 상태로 통과 (O1/O2/O3 판정과 동일)
case "$CLASSIFICATION" in
  O1|O2|O3|"") exit 0 ;;
esac

# Phase 2.5 증거 파일 확인 -- O4/O5만 해당 (O3 제외)
case "$CLASSIFICATION" in
  O4|O5)
    # ui_touched.json 우선 분기 (false negative 차단)
    UI_TOUCHED_JSON_PRIMARY="${SESSION_DIR}/evidence/ui_touched.json"
    UI_TOUCHED_JSON_HOME="${HOME_SESSION_DIR}/evidence/ui_touched.json"
    UI_TOUCHED_JSON=""
    if [ -f "$UI_TOUCHED_JSON_PRIMARY" ]; then
      UI_TOUCHED_JSON="$UI_TOUCHED_JSON_PRIMARY"
    elif [ -f "$UI_TOUCHED_JSON_HOME" ]; then
      UI_TOUCHED_JSON="$UI_TOUCHED_JSON_HOME"
    fi
    if [ -n "$UI_TOUCHED_JSON" ]; then
      UI_TOUCHED=$(jq -r 'if has("touched") then .touched|tostring else "absent" end' "$UI_TOUCHED_JSON" 2>/dev/null || echo "absent")
      USER_OVERRIDE=$(jq -r 'if has("user_override") then .user_override|tostring else "false" end' "$UI_TOUCHED_JSON" 2>/dev/null || echo "false")
      # user_override=true면 기존 흐름 강제 (touched=true와 동등)
      if [ "$USER_OVERRIDE" != "true" ] && [ "$UI_TOUCHED" = "false" ]; then
        # touched=false면 ui_test_done 부재 무관 통과
        exit 0
      fi
    fi
    # (기존 흐름 계속 — ui_test_not_required → ui_test_done 검사)

    # UI 테스트 불필요 마커 있으면 스킵 (UI 파일 변경 없는 작업 -- L-273)
    # ui_test_not_required도 HOME 폴백 탐색
    if [[ ! -f "${SESSION_DIR}/evidence/ui_test_not_required" && \
          -f "${HOME_SESSION_DIR}/evidence/ui_test_not_required" ]]; then
      exit 0
    fi
    [[ -f "${SESSION_DIR}/evidence/ui_test_not_required" ]] && exit 0

    # HOME 경로 폴백: SESSION_DIR가 /tmp/cc-... 이면 $HOME/.claude에서 evidence 탐색
    if [[ ! -f "${SESSION_DIR}/evidence/ui_test_done" && \
          -f "${HOME_SESSION_DIR}/evidence/ui_test_done" ]]; then
      mkdir -p "${HOME_SESSION_DIR}/logs"
      echo "$(date '+%Y-%m-%d %H:%M:%S') [ui_test_done_guard] HOME 경로 폴백 채택 (cc-prefix 분리 감지) uuid=${UUID}" \
        >> "${HOME_SESSION_DIR}/logs/path_fallback.log"
      _mirror_file "${HOME_SESSION_DIR}/logs/path_fallback.log"
      SESSION_DIR="${HOME_SESSION_DIR}"
    fi

    # 공통: ui_test_done 없으면 폴백 후 차단
    if [[ ! -f "${SESSION_DIR}/evidence/ui_test_done" ]]; then
      # 2차: prompt UUID 폴백 시도 (§(b) 소유권 증명 통과 시만 채택)
      UI_FALLBACK_UUID=$(resolve_uuid_from_prompt "$INPUT") || true
      if [[ -n "$UI_FALLBACK_UUID" && "$UI_FALLBACK_UUID" != "$UUID" ]]; then
        UI_FALLBACK_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UI_FALLBACK_UUID}"
        if [[ -f "${UI_FALLBACK_DIR}/evidence/ui_test_done" ]]; then
          # 폴백 성공: SESSION_DIR 교체 + uuid_fallback.log 기록
          mkdir -p "${UI_FALLBACK_DIR}/logs"
          echo "$(date '+%Y-%m-%d %H:%M:%S') [ui_test_done_guard] uuid_fallback adopted=${UI_FALLBACK_UUID} input_sid=${UUID} agent=${AGENT_NAME} team=${TEAM_NAME}" \
            >> "${UI_FALLBACK_DIR}/logs/uuid_fallback.log"
          SESSION_DIR="$UI_FALLBACK_DIR"
          UUID="$UI_FALLBACK_UUID"
        fi
      fi
    fi
    # 폴백 후에도 ui_test_done 없으면 차단
    if [[ ! -f "${SESSION_DIR}/evidence/ui_test_done" ]]; then
      # 프로젝트 유형 감지 후 맞춤 오류 메시지
      PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
      PROJECT_TYPE=$(cat "${SESSION_DIR}/project_type" 2>/dev/null || echo "")

      if [[ -z "$PROJECT_TYPE" ]] && [[ -n "$PROJECT_ROOT" ]]; then
        if find "$PROJECT_ROOT" -maxdepth 3 -name "*.csproj" -quit 2>/dev/null | grep -q .; then
          PROJECT_TYPE="csharp"
        elif find "$PROJECT_ROOT" -maxdepth 2 \( -name "package.json" -o -name "*.html" \) -quit 2>/dev/null | grep -q .; then
          PROJECT_TYPE="web"
        fi
      fi

      case "$PROJECT_TYPE" in
        csharp)
          REASON="❌ Phase 2.5 UI 테스트 미수행! C# 프로젝트 — otestuiwinforms(otest_winforms) 실행 필수. evidence/ui_test_done + winforms_test_done 없음."
          ;;
        web)
          REASON="❌ Phase 2.5 UI 테스트 미수행! 웹 프로젝트 — otestui(otest_playwright) 실행 필수. evidence/ui_test_done + web_test_done 없음."
          ;;
        *)
          REASON="❌ Phase 2.5 UI 테스트 미수행! O4/O5 분류에서는 otestui(웹) 또는 otestuiwinforms(C#) 중 해당 테스트 완료 필수. evidence/ui_test_done 없음."
          ;;
      esac
      BLOCK_MSG=$(printf '{"decision":"block","reason":"%s"}' "$REASON")
      echo "$BLOCK_MSG" | tee /dev/stderr
      exit 2
    fi

    # ui_test_done 있어도 프로젝트 유형 불일치 시 차단
    PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    PROJECT_TYPE=$(cat "${SESSION_DIR}/project_type" 2>/dev/null || echo "")

    if [[ -z "$PROJECT_TYPE" ]] && [[ -n "$PROJECT_ROOT" ]]; then
      if find "$PROJECT_ROOT" -maxdepth 3 -name "*.csproj" -quit 2>/dev/null | grep -q .; then
        PROJECT_TYPE="csharp"
      elif find "$PROJECT_ROOT" -maxdepth 2 \( -name "package.json" -o -name "*.html" \) -quit 2>/dev/null | grep -q .; then
        PROJECT_TYPE="web"
      fi
    fi

    case "$PROJECT_TYPE" in
      csharp)
        if [[ ! -f "${SESSION_DIR}/evidence/winforms_test_done" ]]; then
          REASON="❌ Phase 2.5 UI 테스트 불일치! C# 프로젝트인데 otest_winforms 미실행. winforms_test_done 없음. otestuiwinforms 실행 필수."
          BLOCK_MSG=$(printf '{"decision":"block","reason":"%s"}' "$REASON")
          echo "$BLOCK_MSG" | tee /dev/stderr
          exit 2
        fi
        ;;
      web)
        if [[ ! -f "${SESSION_DIR}/evidence/web_test_done" ]]; then
          REASON="❌ Phase 2.5 UI 테스트 불일치! 웹 프로젝트인데 otest_ui/otest_playwright 미실행. web_test_done 없음. otestui 실행 필수."
          BLOCK_MSG=$(printf '{"decision":"block","reason":"%s"}' "$REASON")
          echo "$BLOCK_MSG" | tee /dev/stderr
          exit 2
        fi
        ;;
      # 유형 불명: ui_test_done만 있어도 통과 (폴백)
    esac
    ;;
esac

exit 0
