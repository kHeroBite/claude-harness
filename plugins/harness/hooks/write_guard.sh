#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# write_guard.sh — ok 파이프라인 수정/탐색 도구 통합 가드
# 통합: ok_check.sh + ok_full_edit_guard.sh + ok_explore_guard.sh + team_dir_guard.sh
# PreToolUse 이중 matcher 등록:
#   수정 도구: Edit|Write|Notebookedit|serena_replace|insert|rename
#   탐색 도구: Grep|Glob|serena_find|find_referencing|find_symbol|get_symbols|search_for_pattern

# --- stdin JSON 읽기 (set -e 전에 수행 — 안전) ---
INPUT=$(timeout 2 cat 2>/dev/null) || INPUT=""
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || TOOL_NAME=""

# ═════════════════════════════════════════════════════════════════════════════
# [H-2 2026-08-17] shutdown 발신 후 미응답 조기 경고 — ★ 경고만. 차단 절대 없음.
#
# 배경: verify-1 / diag-1 / odev-2 3건이 작업 완료 후 SendMessage 미호출로 보고를 유실했다.
#       shutdown_request 2회에도 응답이 없었고, 메인은 유휴 알림만 보고 추측해야 했다.
#       H-1(SubagentStop_report_guard)이 발생을 막고, H-2 는 이미 발생한 상태를 빨리 알린다.
#
# ★ 이 블록은 stderr 로 경고만 출력하고 절대 exit 하지 않는다.
#   write_guard 는 모든 도구 호출을 거치는 경로다. 여기서 오동작하면 4개 프로젝트가 멈춘다.
#   그래서 판정 실패·라이브러리 부재·타임아웃은 전부 침묵 통과이고, decision:block 을 내지 않는다.
#
# 긴급 정지: lib/orphan_scan.sh 를 지우면 H-1 과 함께 이 경고도 동시에 무력화된다(기존 탈출구 유지).
# ═════════════════════════════════════════════════════════════════════════════
_H2_WARN_LIB="${HARNESS_HOOK_DIR}/lib/orphan_scan.sh"
if [[ -r "$_H2_WARN_LIB" ]]; then
  _H2_WARN_UUID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null) || _H2_WARN_UUID=""
  if [[ -n "$_H2_WARN_UUID" ]]; then
    _H2_STALE=$(timeout 2 bash -c "source '$_H2_WARN_LIB' 2>/dev/null; shutdown_stale_list '$_H2_WARN_UUID' 90" 2>/dev/null) || _H2_STALE=""
    if [[ -n "$_H2_STALE" ]]; then
      while read -r _h2_agent _h2_age; do
        [[ -n "$_h2_agent" ]] || continue
        case "$_h2_age" in ''|*[!0-9]*) continue ;; esac
        echo "⚠️ [H-2] ${_h2_agent} shutdown 발신 후 ${_h2_age}초 미응답 — 발신 누락 의심. pane 캡처 권고: tmux capture-pane -p -t %{pane}" >&2
      done <<< "$_H2_STALE"
    fi
  fi
fi
# --- H-2 끝 (exit 없음 — 아래 기존 흐름 그대로 진행) ---

# --- KQ_GATE 제거됨 (2026-04-03) ---
# IDLE: oi 스킵 (메인 직접 처리)
# 파이프라인 활성: UserPromptSubmit 소프트 메시지로 Skill('oi') 안내

# --- F-CRUD-1: otest_done / make_ok 쓰기 전 CRUD 실행증거 게이트 (사이클31) ---
# 배경: 사이클30 otest 가 T3 를 "전필드 DB일치 · PASS" 로 판정했으나 저장 경로를 태우지 않았다.
#       삭제 가드(차단)만 확인하고 추가/수정은 "운영 데이터 보호"를 이유로 건너뛴 결과,
#       반쪽 저장(정본만 저장되고 부가 축 누락)이 실사용에서 즉시 드러났다.
# 원칙: 차단 확인은 저장 검증이 아니다. "운영 데이터 보호"는 면제 사유가 아니라 개발 DB 사용 사유다.
# 위치: ★모든 조기 exit 0 보다 앞★ — evidence/ 는 session-env(=.claude/) 하위라
#       ".claude/ 하위 oio 전역 허용"(P4 이후 섹션)과 팀에이전트 우회(P4)에 먼저 걸려 통과해 버린다.
#       실측으로 확인함: 뒤에 두었을 때 rc=0 으로 게이트가 무력화됐다 (L-718: 코드 실재 ≠ 실행).
# 범위: evidence/otest_done 또는 evidence/make_ok 쓰기 한정 (좁게 — 그 외 경로는 일절 건드리지 않음).
# 실패 안전: 스크립트 부재 시에는 통과시킨다 (게이트 부재가 파이프라인을 세우면 안 된다).
if [[ "$TOOL_NAME" == "mcp__oio__file_write" || "$TOOL_NAME" == "mcp__oio__file_edit" ]]; then
  _CRUD_PATH=$(echo "$INPUT" | jq -r '.tool_input.path // .tool_input.file_path // empty' 2>/dev/null || echo "")
  if [[ "$_CRUD_PATH" == */evidence/otest_done || "$_CRUD_PATH" == */evidence/make_ok ]]; then
    # 대상 UUID 는 경로에서 직접 추출한다 (세션 변수보다 신뢰도가 높다).
    _CRUD_UUID=$(echo "$_CRUD_PATH" | sed -n 's#.*/session-env/\([^/]*\)/evidence/.*#\1#p')
    _CRUD_UUID="${_CRUD_UUID:-${PIPELINE_UUID:-}}"
    _CRUD_SCRIPT=""
    for _c in \
      "${CLAUDE_PROJECT_DIR:-}/.claude/skills/otest_make/scripts/verify_crud_executed.py" \
      "${CLAUDE_PLUGIN_ROOT:-}/skills/otest_make/scripts/verify_crud_executed.py"
    do
      if [[ -n "$_c" && -f "$_c" ]]; then _CRUD_SCRIPT="$_c"; break; fi
    done
    # otest_done(최종 마킹)은 --final 로 검사한다 — evidence 부재를 통과시키지 않는다.
    # make_ok(중간 기록)은 부트스트랩상 최초 부재가 정상이므로 --final 을 주지 않는다.
    _CRUD_FINAL=""
    [[ "$_CRUD_PATH" == */evidence/otest_done ]] && _CRUD_FINAL="--final"
    if [[ -n "$_CRUD_SCRIPT" && -n "$_CRUD_UUID" ]]; then
      _CRUD_OUT=$(CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" \
                  timeout 20 python3 "$_CRUD_SCRIPT" --uuid "$_CRUD_UUID" $_CRUD_FINAL 2>&1) && _CRUD_RC=0 || _CRUD_RC=$?
      if [[ "$_CRUD_RC" -ne 0 ]]; then
        source "${HARNESS_HOOK_DIR}/lib/write_error.sh" 2>/dev/null || true
        type log_hook_error >/dev/null 2>&1 && \
          log_hook_error "HOOK_BLOCK_CRUD_EVIDENCE" "$TOOL_NAME" "CRUD 실행증거 게이트 미통과(rc=${_CRUD_RC}) — ${_CRUD_PATH}" "$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null)"
        _CRUD_MSG=$(echo "$_CRUD_OUT" | head -c 500 | tr '\n' ' ' | tr '"\\' "''")
        echo "{\"decision\":\"block\",\"reason\":\"🚫 [F-CRUD-1] CRUD 실행증거 미확보 — ${_CRUD_PATH##*/} 마킹 거부. 차단 확인은 저장 검증이 아니다. 개발 DB 에서 실제로 저장을 태우고 evidence 의 해당 항목에 write_log + 상태변화 증거(count/rowset/value/modified 전후 중 하나)를 기록한 뒤 재시도하라. COUNT 불변 = 미실행 이 아니다 — 전건 재작성형 테이블은 rowset 으로 잡아라. (rc=${_CRUD_RC}) ${_CRUD_MSG}\"}"
        exit 2
      fi
    fi
  fi
fi

# --- 탐색 도구 조기 통과 (Grep/Glob/Serena 탐색) ---
# 읽기 전용 도구는 최소한의 OK 상태 체크만 수행 (복잡한 처리 불필요)
case "$TOOL_NAME" in
  Read|Grep|Glob|mcp__oio__file_read|mcp__oio__find|mcp__oio__list_dir|\
  mcp__plugin_serena_serena__find_file|mcp__plugin_serena_serena__find_symbol|\
  mcp__plugin_serena_serena__get_symbols_overview|mcp__plugin_serena_serena__search_for_pattern|\
  mcp__plugin_serena_serena__find_referencing_symbols|mcp__plugin_serena_serena__list_dir|\
  mcp__plugin_serena_serena__read_file|\
  mcp__serena__find_file|mcp__serena__find_symbol|\
  mcp__serena__get_symbols_overview|mcp__serena__search_for_pattern|\
  mcp__serena__find_referencing_symbols|mcp__serena__list_dir|\
  mcp__serena__read_file)
    # OK 상태에서만 메인 세션 탐색 차단 (L-248) — 나머지는 즉시 통과
    _UUID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null) || _UUID=""
    if [[ -n "$_UUID" ]]; then
      _STATE_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${_UUID}/state"
      # Fix 4: state_read (flock) 통일 — cat|awk 직접 읽기는 race condition 유발
      source "${HARNESS_HOOK_DIR}/lib/session_id.sh" 2>/dev/null || true
      _STATE=$(state_read "$_STATE_FILE" 2>/dev/null | awk '{print $1}') || _STATE=""
      # Fix 11 (L-NEW): __LOCK_FAIL__ — 탐색 도구는 읽기 전용이므로 fail-open (통과)
      if [[ "$_STATE" == "__LOCK_FAIL__" ]]; then
        exit 0
      fi
      # Phase B (L-431): state OK 제거 → state=PLAN AND classification=OK 차단으로 등가 변환
      # 의미 보존: ok 단계(분류 미확정) 진입 직후의 코드 탐색 차단 (L-248)
      _CLASSIFICATION=$(cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${_UUID}/classification" 2>/dev/null | tr -d '\r\n' || echo "")
      if [[ "$_STATE" == "PLAN" && "$_CLASSIFICATION" == "OK" ]]; then
        # PIPELINE_UUID 있으면 팀에이전트 → 통과
        # 2026-09-07 사이클90: 아래 Fix 1 과 동일 사유로 프로세스 트리 판별 보강.
        # (PIPELINE_UUID 는 hook 자식 프로세스에 전달되지 않아 단독 판정 시 항상 unset — 396행 실측 주석 참조)
        _OK_IS_TEAM_AGENT="${PIPELINE_UUID:-}"
        if [[ -z "$_OK_IS_TEAM_AGENT" ]]; then
          _OK_PID_WALK=$$
          _OK_DEPTH_WALK=0
          while [[ $_OK_DEPTH_WALK -lt 10 && -n "$_OK_PID_WALK" && "$_OK_PID_WALK" != "1" ]]; do
            _OK_CMDLINE_WALK=$(tr '\0' ' ' < "/proc/${_OK_PID_WALK}/cmdline" 2>/dev/null)
            if [[ "$_OK_CMDLINE_WALK" =~ --parent-session-id[[:space:]]+([0-9a-f-]{36}) ]]; then
              _OK_IS_TEAM_AGENT="${BASH_REMATCH[1]}"
              break
            fi
            # PPid 는 /proc/PID/status 에서 읽는다. /proc/PID/stat 의 $4 는 comm 필드가
            # "(bash)" 처럼 괄호/공백을 포함하면 컬럼이 밀려 잘못된 값을 준다
            # (실측: $4 가 상태문자 "S" 로 잡혀 /proc/S/cmdline 참조 → 조기 이탈).
            _OK_PID_WALK=$(awk '/^PPid:/{print $2}' "/proc/${_OK_PID_WALK}/status" 2>/dev/null)
            _OK_DEPTH_WALK=$((_OK_DEPTH_WALK + 1))
          done
        fi
        if [[ -n "$_OK_IS_TEAM_AGENT" ]]; then
          exit 0
        fi
        # L-NEW (6차 감사): session-env 경로는 OK 상태 탐색 허용 — 오케스트레이션 인프라
        # 이유: UUID fallback 탐색, stale 감지 등 ok 절차 자체가 session-env/ 읽기 필요
        _OK_EXPLORE_PATH=$(echo "$INPUT" | jq -r ".tool_input.path // .tool_input.file_path // .tool_input.filepath // .tool_input.pattern // empty" 2>/dev/null || echo "")
        if echo "$_OK_EXPLORE_PATH" | grep -qP "\.claude/session-env/|\.claude/hooks/"; then
          exit 0
        fi
        echo "{\"decision\":\"block\",\"reason\":\"❌ [L-248] ok 단계에서 코드 탐색 금지! ok는 분류+spawn만 수행합니다. 코드 탐색은 oplan에 위임하세요.\"}"
        exit 2
      fi
      # Fix 1 (L-NEW): PLAN/DEV/TEST/DONE 상태에서 메인의 NTFS 경로 탐색 차단
      # 팀에이전트(PIPELINE_UUID 있음)는 통과. .claude/ 경로도 통과.
      #
      # ── ★2026-09-07 사이클90 — 팀에이전트 판별을 프로세스 트리로 보강★ ──────────
      # 문제: 이 블록은 팀에이전트 면제를 ${PIPELINE_UUID} 환경변수 단독으로 판정했다.
      #   그런데 ★같은 파일 396~397행이 이미 실측으로 기록해 두었다★ —
      #   "PIPELINE_UUID 환경변수는 실측 결과 hook 자식 프로세스에 전달되지 않는다
      #    (env/printenv 에 PIPELINE_UUID 자체가 없음)."
      #   ⇒ 이 값은 사실상 항상 unset 이므로 ★면제 분기가 도달 불가능한 사문(dead code)★ 이었고,
      #     모든 팀에이전트가 "메인"으로 판정되어 NTFS 탐색이 전면 차단됐다.
      #   실사고(2026-09-07): oplan 이 프로젝트 파일을 한 줄도 읽지 못해 계획 수립 실패.
      #   위임받은 서브에이전트 4명(Explore 2 + general-purpose 2)도 전원 동일 차단.
      #   ⇒ hook 이 "팀에이전트에 위임하라"고 안내하는데 그 위임 대상도 차단되는 순환 교착이었다.
      #
      # 조치: 396~412행의 _COMMIT_UUID_EARLY 와 ★동일한 검증된 패턴★ 을 적용한다 —
      #   프로세스 트리 조상에서 `--parent-session-id <36자 UUID>` 를 파싱한다.
      #   그 주석이 명시한 대로 이것이 "실측상 신뢰 가능한 유일한 경로"다.
      #   메인 에이전트는 이 플래그가 없으므로 차단이 그대로 유지된다(보호 범위 불변).
      _WG_IS_TEAM_AGENT="${PIPELINE_UUID:-}"
      if [[ -z "$_WG_IS_TEAM_AGENT" ]]; then
        _WG_PID_WALK=$$
        _WG_DEPTH_WALK=0
        while [[ $_WG_DEPTH_WALK -lt 10 && -n "$_WG_PID_WALK" && "$_WG_PID_WALK" != "1" ]]; do
          _WG_CMDLINE_WALK=$(tr '\0' ' ' < "/proc/${_WG_PID_WALK}/cmdline" 2>/dev/null)
          if [[ "$_WG_CMDLINE_WALK" =~ --parent-session-id[[:space:]]+([0-9a-f-]{36}) ]]; then
            _WG_IS_TEAM_AGENT="${BASH_REMATCH[1]}"
            break
          fi
          # PPid 는 /proc/PID/status 에서 읽는다 (위 _OK_PID_WALK 주석 참조 — stat $4 컬럼 밀림 버그 회피).
          _WG_PID_WALK=$(awk '/^PPid:/{print $2}' "/proc/${_WG_PID_WALK}/status" 2>/dev/null)
          _WG_DEPTH_WALK=$((_WG_DEPTH_WALK + 1))
        done
      fi
      if [[ "$_STATE" =~ ^(PLAN|DEV|TEST|DONE)$ ]] && [[ -z "$_WG_IS_TEAM_AGENT" ]]; then
        _EXPLORE_PATH=$(echo "$INPUT" | jq -r '.tool_input.path // .tool_input.file_path // .tool_input.filepath // .tool_input.pattern // empty' 2>/dev/null || echo "")
        # .claude/ 경로는 허용 (오케스트레이션 메타 탐색)
        # F-NEW-1: symlink traversal 방어 — .claude/ 경로라도 realpath가 NTFS면 허용 불가
        # F-NEW-1-EXC (2026-08-01): CLAUDE_CONFIG_DIR가 세션 임시 디렉토리(/tmp/cc-*)인 구성에서
        # projects/*/memory/ 하위(MEMORY.md 등 자동메모리)는 정당한 NTFS symlink이므로 예외 허용
        _CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
        if [[ "$_EXPLORE_PATH" == "$_CLAUDE_DIR"/*/memory/*.md ]]; then
          exit 0
        fi
        if [[ "$_EXPLORE_PATH" == "$_CLAUDE_DIR"/* || "$_EXPLORE_PATH" == /home/*/.claude/* ]]; then
          _RESOLVED_EXPLORE=$(realpath -m "$_EXPLORE_PATH" 2>/dev/null || echo "$_EXPLORE_PATH")
          if echo "$_RESOLVED_EXPLORE" | grep -qP '^/mnt/[c-z]/'; then
            echo "{\"decision\":\"block\",\"reason\":\"❌ [F-NEW-1] .claude/ 심볼릭링크가 NTFS 경로를 가리킵니다 — symlink traversal 탐색 차단.\"}"
            exit 2
          fi
          : # .claude/ 탐색 허용 (symlink 해석 후 NTFS 아님)
        elif echo "$_EXPLORE_PATH" | grep -qP '/mnt/[c-z]/'; then
          echo "{\"decision\":\"block\",\"reason\":\"❌ [Fix 1/L-NEW] ${_STATE} 상태에서 메인의 NTFS 경로 탐색 금지! 팀에이전트에 위임 필수. (path: $(echo "$_EXPLORE_PATH" | head -c 60))\"}"
          exit 2
        fi
      fi
    fi
    exit 0
    ;;
esac

# --- oio 도구 조기 분기 (IDLE/FINISH만 메인 허용) ---
# --- F10: L-303 run_in_background 전역 차단 (bash_exec — 팀/.claude 바이패스 선행) ---
# oio bash_exec의 run_in_background=true는 무한 블로킹 버그 유발 (2026-04-09 실사고).
# 팀에이전트/.claude 경로 무관 전역 차단. bash_exec.py 서버측이 2차 방어선 (F10 이중 차단).
if [[ "$TOOL_NAME" == "mcp__oio__bash_exec" ]]; then
  _RUN_BG_EARLY=$(echo "$INPUT" | jq -r '.tool_input.run_in_background // empty' 2>/dev/null || echo "")
  if [[ "$_RUN_BG_EARLY" == "true" ]]; then
    echo '{"decision":"block","reason":"🚫 [L-303/F10] bash_exec run_in_background=true 금지 — 무한 블로킹 버그 유발. foreground + timeout_ms 사용."}'
    exit 2
  fi
fi

# --- F10-2: L-531 git stash 전역 차단 (멀티에이전트 작업트리 오염 방지) ---
# git stash는 작업트리 전체(모든 에이전트의 미커밋 변경분)를 대상으로 하므로
# 멀티에이전트 환경에서 타 에이전트 파일까지 함께 stash되는 사고를 유발한다 (2026-08-18 실사고).
# 팀/메인 구분 없이 전역 차단. 대안: 개별 파일 검증은 git diff/status로, 전체 되돌리기는 사용 금지.
if [[ "$TOOL_NAME" == "mcp__oio__bash_exec" ]]; then
  _STASH_CMD_EARLY=$(echo "$INPUT" | jq -r '.tool_input.command // .tool_input.cmd // empty' 2>/dev/null || echo "")
  if [[ "$_STASH_CMD_EARLY" =~ git[[:space:]]+stash ]]; then
    echo '{"decision":"block","reason":"🚫 [L-531/F10-2] git stash 금지 — 작업트리 전체가 대상이라 멀티에이전트 환경에서 타 에이전트 파일까지 함께 담기는 사고 유발. 개별 파일 확인은 git diff/status 사용."}'
    exit 2
  fi
fi

# --- F10-3: 사이클41 — 물리 좌표 클릭 직접 호출 차단 (safe_click.ps1 경유 강제) ---
# 배경: tmp_stepC.ps1 이 SetCursorPos(5600,100) 을 하드코딩했다. VirtualScreen 은
#       X=-2560 W=7040 (Right=4480) 이므로 5600 은 1120px 초과한 ★존재하지 않는 좌표★였다.
#       원인은 대상 창을 한 번도 조회하지 않고 좌표를 추정 기입한 것이다.
#       당시 스크립트에 WindowFromPoint 검사가 이미 있었으나 ★출력만 하고 중단하지 않아★
#       무용지물이었다 (L-791 동형 — "반응했다" 와 "결과가 달라졌다" 는 다르다).
# 조치: 물리 커서/클릭 API 직접 호출을 차단하고 .claude/scripts/safe_click.ps1 경유를 강제한다.
#       safe_click.ps1 은 좌표계·창소유권·DPI 3축을 검증하고 실패 시 throw 한다.
# 설계: ① safe_click.ps1 자신을 호출하는 명령은 반드시 통과시킨다(자기 차단 방지).
#       ② 정의(DllImport 선언)가 아니라 ★실제 호출★ 패턴만 잡는다.
#       ③ 판정 불가 시 fail-open — 무관한 명령을 막지 않는다.
if [[ "$TOOL_NAME" == "mcp__oio__bash_exec" ]] && [[ ! -f "$HOME/.claude/hooks/DISABLE_SAFECLICK_GUARD" ]]; then
  _SC_CMD=$(echo "$INPUT" | jq -r '.tool_input.command // .tool_input.cmd // empty' 2>/dev/null || echo "")
  # ① safe_click.ps1 경유는 허용 (이 가드가 강제하는 정본 경로다)
  if ! echo "$_SC_CMD" | grep -q 'safe_click\.ps1'; then
    # ② 실제 호출 패턴: [클래스]::SetCursorPos( / ::mouse_event( / ::SendInput(
    if echo "$_SC_CMD" | grep -qP '::\s*(SetCursorPos|mouse_event|SendInput)\s*\('; then
      echo '{"decision":"block","reason":"🚫 [사이클41/F10-3] 물리 좌표 클릭 직접 호출 금지 — SetCursorPos/mouse_event/SendInput 을 직접 부르지 마라. 좌표계·창소유권·DPI 3축을 검증하는 .claude/scripts/safe_click.ps1 을 경유하라 (실패 시 throw). 예: powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\\DATA\\Project\\<프로젝트>\\.claude\\scripts\\safe_click.ps1 -ImageX <x> -ImageY <y> -ExpectedProcessId <PID>  [검증만: -NoClick]. 원칙적으로 좌표 클릭 자체가 금지이며 UIAutomation(AutomationId/Name)이 정본이다 — otest_winforms SKILL.md 참조."}'
      exit 2
    fi
  fi
fi

# --- F-OTO-7B: 사이클39 — bash_exec 로 state=IDLE 직접 쓰기 시 RALPH 게이트 사멸 차단 ---
# 배경: PreToolUse_oto_completion_guard.sh 의 F-OTO-7 은 mcp__oio__session_state 매처 전용이다.
#       따라서 bash_exec 로 state 파일에 직접 IDLE 을 쓰면 그 검사를 통째로 우회한다(우회경로 #2).
#       기존 F1(:737)이 있으나 `if [[ "$TOOL_NAME" == "Bash" ]]` 블록 안에 있어
#       CLAUDE.md 가 강제하는 mcp__oio__bash_exec 에는 ★한 번도 발동하지 않는다★ (실측 확인).
# 조건: auto=ON AND status 에 RALPH 없음 AND oralph_active/.json 둘 다 부재 AND state 에 IDLE 쓰기 시도
# 설계: auto 미설정 세션 무영향(최우선). DISABLE_OTO_GUARD 비상 스위치 존중. 그 외 예외는 fail-open.
if [[ "$TOOL_NAME" == "mcp__oio__bash_exec" ]] && [[ ! -f "$HOME/.claude/hooks/DISABLE_OTO_GUARD" ]]; then
  _O7_CMD=$(echo "$INPUT" | jq -r '.tool_input.command // .tool_input.cmd // empty' 2>/dev/null || echo "")
  # state 파일 쓰기 + IDLE 토큰이 함께 있을 때만 검사 (조회/그 외 명령 무영향)
  if echo "$_O7_CMD" | grep -qP 'session-env/[^/]+/state\b' \
     && echo "$_O7_CMD" | grep -qP '\bIDLE\b' \
     && echo "$_O7_CMD" | grep -qP '(>\s*["'"'"']?[^|&<]*session-env/[^/]+/state|tee\s+.*session-env/[^/]+/state|sed\s+.*-i.*session-env/[^/]+/state|state_write|state_transition)'; then
    # 대상 UUID: 명령문에서 추출 (자기 세션 판정 — 세션 격리 §(a) 읽기 전용)
    _O7_UUID=$(echo "$_O7_CMD" | grep -oP 'session-env/\K[^/]+' | head -1)
    if [[ -n "$_O7_UUID" ]]; then
      _O7_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${_O7_UUID}"
      [[ ! -f "${_O7_DIR}/auto" && -f "$HOME/.claude/session-env/${_O7_UUID}/auto" ]] \
        && _O7_DIR="$HOME/.claude/session-env/${_O7_UUID}"
      if [[ -f "${_O7_DIR}/auto" ]] && [[ "$(tr -d '[:space:]' < "${_O7_DIR}/auto" 2>/dev/null)" == "ON" ]]; then
        _O7_RALPH=0
        [[ -f "${_O7_DIR}/status" ]] && grep -qE '(^|\|)RALPH(\||$)' "${_O7_DIR}/status" 2>/dev/null && _O7_RALPH=1
        if [[ "$_O7_RALPH" -eq 0 && ! -f "${_O7_DIR}/oralph_active" ]]; then
          if [[ -f "${_O7_DIR}/oralph_active.json" ]]; then
            # (a) 파일명 어긋남 — 사이클38 실사고와 동일 형태
            echo '{"decision":"block","reason":"🚫 [F-OTO-7Ba] auto=ON 세션인데 RALPH 게이트가 발동하지 않는 상태로 state=IDLE 을 직접 쓰려 합니다. oralph_active.json 은 있으나 ofinish Step 8 은 확장자 없는 oralph_active 를 봅니다 — 폴백이 원리적으로 매칭되지 않아 검증 루프가 통째로 건너뛰어집니다(사이클38 실사고). → 파일명을 oralph_active 로 맞추고 status_add RALPH 를 수행하십시오. 비상 시 hooks/DISABLE_OTO_GUARD 로 우회 가능."}'
          else
            # (b) 둘 다 없음 — oto 1_5 세팅 누락
            echo '{"decision":"block","reason":"🚫 [F-OTO-7Bb] auto=ON 세션인데 RALPH 게이트가 죽은 채로 state=IDLE 을 직접 쓰려 합니다. status 에 RALPH 가 없고 oralph_active 파일도 없어, ofinish Step 8 이 검증 루프를 통째로 건너뛴 상태입니다(사이클38 실사고 재현). → oralph_active 파일과 status_add RALPH 를 먼저 세팅하거나, 정당한 종료라면 mcp__oio__session_state 경유로 전환해 F-OTO-7 검사를 받으십시오. 비상 시 hooks/DISABLE_OTO_GUARD 로 우회 가능."}'
          fi
          exit 2
        fi
      fi
    fi
  fi
fi

# --- F-COMMIT-1: L-567 사이클14 파이프라인 이탈 재발방지 (state DEV/TEST 중 git commit 차단) ---
# 배경: 사이클14 실사고 — odone(state=DONE) 미경유 상태에서 git commit이 실행됨.
# CLAUDE.md에 "커밋은 odone_git/ofinish 전용" 규칙이 있었으나 문서만으로는 미준수(L-567).
# 정당 경로 4종은 state가 DONE(odone_git)/FINISH(ofinish Step7.5)/IDLE(/opush 단독·사용자 직접)이므로
# DEV/TEST에서만 커밋을 걸어도 전부 통과한다. PLAN은 이번 지시 범위 밖(oplan 판정)이라 조건에 넣지 않는다.
# state 판별은 기존 state_read(flock) 인프라를 그대로 재사용 — 새 방식을 만들지 않는다.
if [[ "$TOOL_NAME" == "mcp__oio__bash_exec" ]]; then
  _COMMIT_CMD_EARLY=$(echo "$INPUT" | jq -r '.tool_input.command // .tool_input.cmd // empty' 2>/dev/null || echo "")
  # F-4 설계전환 (2026-08-20, otest-1 역라우팅 3회차 — 신규 우회 6건):
  #   중첩 bash -c / env / eval / stdin파이프|bash / --git-dir=--work-tree= 결합 / 절대경로 git / xargs
  #   → 개별 우회 패턴을 정규식으로 하나씩 막는 방식(F-2/F-3)이 한계에 도달.
  # ★ 사용자 승인 설계 전환: "git·commit 토큰이 둘 다 있으면 넓게 차단 + 오탐은 whitelist로 예외"
  #   (1회차에 반려됐던 c안 — 신규 우회 6건 실증 후 3회차에 승인됨)
  # 판정 순서:
  #   1) git/commit 토큰이 둘 다 없으면 무해 (조기 통과)
  #   2) git alias.<name>에 commit이 담기는 정의는 서브커맨드 판정 전에 위험으로 확정(alias 간접우회 차단)
  #   3) git 뒤 옵션들을 건너뛴 첫 서브커맨드가 read-only whitelist(log/show/diff/status/rev-parse/
  #      rev-list/cherry/describe/blame/bisect/help/shortlog/reflog/ls-files/ls-tree/cat-file/grep/
  #      branch/tag/remote/whatchanged)면 통과
  #   4) 순수 echo(파이프 없음)/주석 라인은 텍스트 출력일 뿐 실행이 아니므로 통과
  #   전체 문자열 자체를 먼저 검사(파이프는 분리하지 않음 — 앞부분만 안전해도 뒤에서 실행될 수 있음),
  #   그 다음 ;/&&/||로만 분리한 각 세그먼트를 독립 검사(alias 정의→실행 체인 등 개별 판정 위함).
  # F-5 수정 (2026-08-20, otest-1 역라우팅 4회차 — alias 문자열 분할 우회):
  #   git config alias.cm '!bash -c "git add -A; git c""ommit -m test"' → 셸이 "c""ommit"을
  #   "commit"으로 결합한 뒤에야 실제 서브커맨드가 되므로, hook이 보는 실행 전 텍스트에는
  #   \bcommit\b 리터럴이 없어 _commit_is_alias_def를 통과했다(실제 커밋 54fd64e6 발생, otest-1 확인).
  #   ★ 사용자 결정: whitelist에서 config를 제거해 "git config ..." 전체를 state DEV/TEST에서
  #   원천 차단한다. alias 정의문 안의 "commit" 문자열을 정규식으로 잡으려는 시도는 문자열 결합/
  #   변수치환/base64 등으로 무한 우회 가능하므로, 텍스트 판정이 아니라 진입 자체를 막는다.
  #   트레이드오프(git config --get/--list 읽기도 함께 막힘)는 사용자가 인지하고 승인함
  #   ("실제 워크플로우에서 git config는 드물게 쓰임"). --get만 예외로 뚫는 시도는 절대 금지
  #   (--get 뒤에 무엇이 오는지 다시 텍스트로 판정해야 하며, 그게 이번에 실패한 접근과 동일하다).
  #   _commit_is_alias_def는 삭제하지 않음 — config가 차단되어 도달 빈도는 줄지만, 다른 경로로
  #   alias 정의가 유입될 가능성에 대비한 이중 방어로 유지.
  _COMMIT_READONLY_SUBCMDS_EARLY='log|show|diff|status|rev-parse|rev-list|cherry|describe|blame|bisect|help|shortlog|reflog|ls-files|ls-tree|cat-file|grep|branch|tag|remote|whatchanged'
  _commit_has_tokens() {
    echo "$1" | grep -qP '\bgit\b' || return 1
    echo "$1" | grep -qP '\bcommit\b' || return 1
    return 0
  }
  # F-5 추가 (2026-08-20): git config 서브커맨드 자체를 commit 토큰 유무와 무관하게 판별.
  # 이유: "git config alias.cm '!... git c""ommit ...'" 처럼 문자열이 셸에서만 결합되는 경우
  # hook이 보는 실행 전 텍스트에는 \bcommit\b 리터럴이 없어 _commit_has_tokens 단계에서부터
  # 조기 통과된다 — whitelist에서 config를 빼는 것만으로는 이 케이스에 도달조차 못 한다.
  # 따라서 git 뒤 첫 서브커맨드가 config이면 commit 토큰 유무와 무관하게 즉시 위험 확정한다.
  _commit_is_git_config_call() {
    local _sub
    _sub=$(echo "$1" | grep -oP '\bgit\b(\s+(-[cC]\s+\S+|--?\S+))*\s+\K[a-z-]+' | head -1)
    [[ "$_sub" == "config" ]]
  }
  _commit_is_alias_def() {
    echo "$1" | grep -qP '\bgit\s+config\s+(--\S+\s+)*alias\.\S+\s+.*\bcommit\b'
  }
  _commit_is_readonly() {
    local _sub
    _sub=$(echo "$1" | grep -oP '\bgit\b(\s+(-[cC]\s+\S+|--?\S+))*\s+\K[a-z-]+' | head -1)
    [[ -z "$_sub" ]] && return 1
    echo "$_sub" | grep -qP "^(${_COMMIT_READONLY_SUBCMDS_EARLY})$"
  }
  _commit_is_pure_echo_or_comment() {
    if echo "$1" | grep -qP '^\s*echo\b' && ! echo "$1" | grep -qP '\|'; then
      return 0
    fi
    echo "$1" | grep -qP '^\s*#'
  }
  # F-6 수정 (2026-08-20, otest-1-2 역라우팅 — F-5 결함A와 동형 재발):
  #   git con"fig" alias.x diff / git c'onf'ig --get alias.y / g"it" config --get alias.z 등
  #   따옴표로 리터럴 토큰(git/config/commit)을 쪼개면 _commit_is_git_config_call 등이 요구하는
  #   \bconfig\b, \bgit\b, \bcommit\b 리터럴이 판정 시점 텍스트에 존재하지 않아 전부 통과했다
  #   (실증: git con"fig" alias.probe "diff" 실행 시 .git/config에 실제 alias 등록됨).
  # ★ 사용자 결정: 판정 직전에 " / ' / \ 를 제거한 정규화 사본을 만들어 그 사본으로만 판정한다.
  #   con"fig" → config, c'onf'ig → config, g"it" → git, c""ommit → commit 으로 정규화되어 잡힌다.
  #   원본 문자열(_seg)은 차단 메시지/로그용으로 그대로 보존 — 판정 입력만 정규화본으로 교체하는
  #   최소 변경. 기존 판정 함수(_commit_has_tokens 등)는 손대지 않는다.
  #   한계(사용자 인지·승인됨): 변수치환(C=config; git $C)/base64/$'c'$'onfig' 등은 여전히 남는다.
  _commit_normalize() {
    echo "$1" | tr -d '"'"'"'\\'
  }
  # F-8 수정 (2026-08-20, otest-2 역라우팅 9회차 — 위치 앵커 화이트리스트가 13건 뚫림):
  #   F-7(8회차)의 "명령 위치 화이트리스트"(env/eval/xargs/bash -c/sh -c 등 열거)가
  #   sudo/nohup/time/nice/command/exec/서브셸()/그룹{}/명령치환$()·``/if/for/timeout/
  #   setsid/stdbuf/env -i 등 열거 안 된 래퍼 13건+에 전부 뚫렸다(otest-2 확인).
  #   이건 사이클 세 번째 동형 실패: 1~3회차(패턴 화이트리스트) → 6회차(config 리터럴 매칭)
  #   → 8회차(위치 앵커 화이트리스트) — 매번 "인정 목록 방식"이 미열거 변형에 뚫렸다.
  # ★ 사용자 결정: 열거(제외 아닌 인정) 방식을 폐기하고 "제외 방식"으로 전환한다.
  #   기본은 F-6(넓게: git·commit 토큰 있으면 위험)로 복귀하되, otest-2가 확정한 오탐 8건
  #   (전부 grep/rg/sed/awk/cat/python3처럼 git이 "따옴표 안"에 있거나 "하이픈결합 파일명"인
  #   경우)만 명시적으로 제외한다.
  # 판정 3단계 (전부 "위험 확정" 조건 — 하나라도 참이면 위험, 전부 거짓이면 무해):
  #   A) unquoted 뷰(따옴표 " '로 감싸진 구간을 공백치환)에서 git이 독립토큰(standalone)으로
  #      존재 — 세그먼트 시작/파이프뒤/서브셸(/명령치환$(/백틱`/절대경로(슬래시) 등 문자열 어디든
  #      "따옴표 밖"에서 실행 위치에 있으면 확정 위험. 하이픈결합(git-commit-guide.md)은
  #      standalone 판정 자체가 "git 뒤가 공백/끝"을 요구해 자동 배제됨(실측 확인).
  #   B) normalize 뷰(따옴표 완전제거)에서 git이 "세그먼트 시작 위치"에 있으면 위험
  #      (g"it" config 처럼 따옴표가 명령 토큰 자체를 쪼개는 경우 — 6회차 alias 사고와 동형).
  #      "시작"만 보므로 grep -r git commit . 처럼 git이 3번째 단어인 경우는 안 걸림 → 오탐 재발 없음.
  #   C) 인용부호 안 내용이 "셸/원격셸/지연실행으로 그대로 넘겨지는 것으로 알려진" 소수 명령
  #      (bash -c/sh -c/eval/파이프투셸/ssh/trap) 뒤에 오는 경우만 normalize 뷰 전체에서
  #      standalone git 재확인(중첩 bash -c 등 세그먼트 시작이 아닌 내부 위치 커버).
  #      ⚠ C를 무조건 실행하면 grep -r "git commit" . 오탐이 재발함을 실측 확인
  #      (normalize하면 git이 공백 사이에 놓여 A/B 없이도 standalone으로 오판정) — 그래서
  #      "셸에 그대로 넘어가는 것으로 알려진 극소수 사례"에만 한정한다. 이건 8회차의 "명령
  #      위치를 인정하는 화이트리스트"와는 성격이 다르다 — 기본 판정(A/B)은 이미 넓게
  #      걸려 있고, C는 "인용부호 안으로 숨은 git을 되살릴지"만 판단하는 좁은 보조 로직이다.
  _commit_strip_quoted() {
    echo "$1" | sed -E 's/"[^"]*"/ /g; s/'"'"'[^'"'"']*'"'"'/ /g'
  }
  _commit_has_standalone_git() {
    echo "$1" | grep -qP '(^|[[:space:]/(`]|\$\()git([[:space:]]|$|\))'
  }
  _commit_has_git_at_segment_start() {
    echo "$1" | grep -qP '^\s*(\S*/)?git(\s|$)'
  }
  _commit_has_shell_handoff_context() {
    echo "$1" | grep -qP '\b(bash|sh)\s+(-c|--command)\b|\beval\b|\|\s*(\S*/)?\b(bash|sh)\b\s*$|\bssh\b|\btrap\b'
  }
  _commit_git_in_dangerous_position() {
    local _seg="$1" _unq _norm
    _unq=$(_commit_strip_quoted "$_seg")
    _commit_has_standalone_git "$_unq" && return 0
    _norm=$(_commit_normalize "$_seg")
    _commit_has_git_at_segment_start "$_norm" && return 0
    if _commit_has_shell_handoff_context "$_seg"; then
      _commit_has_standalone_git "$_norm" && return 0
    fi
    return 1
  }
  _commit_check_segment() {
    local _seg="$1"
    local _norm
    _norm=$(_commit_normalize "$_seg")
    # git이 실행 위치(따옴표 밖 standalone / 정규화 후 세그먼트 시작 / 셸핸드오프 내부)에
    # 없으면 무해 확정 (grep -r "git commit" . 처럼 인자·파일명·문자열 안은 여기서 배제)
    _commit_git_in_dangerous_position "$_seg" || { echo 0; return; }
    # git config는 commit 토큰 유무와 무관하게 먼저 판별 (문자열분할 우회 원천 차단)
    echo "$_norm" | grep -qP '\bgit\b' && _commit_is_git_config_call "$_norm" && { echo 1; return; }
    _commit_has_tokens "$_norm" || { echo 0; return; }
    _commit_is_alias_def "$_norm" && { echo 1; return; }
    _commit_is_readonly "$_norm" && { echo 0; return; }
    _commit_is_pure_echo_or_comment "$_norm" && { echo 0; return; }
    echo 1
  }
  _COMMIT_MATCHED_EARLY=0
  if [[ "$(_commit_check_segment "$_COMMIT_CMD_EARLY")" == "1" ]]; then
    _COMMIT_MATCHED_EARLY=1
  else
    _COMMIT_NORMALIZED_EARLY=$(echo "$_COMMIT_CMD_EARLY" | sed -E 's/(&&|\|\||;)/\n/g')
    while IFS= read -r _commit_seg_early; do
      [[ -z "$_commit_seg_early" ]] && continue
      if [[ "$(_commit_check_segment "$_commit_seg_early")" == "1" ]]; then
        _COMMIT_MATCHED_EARLY=1
        break
      fi
    done <<< "$_COMMIT_NORMALIZED_EARLY"
  fi
  if [[ "$_COMMIT_MATCHED_EARLY" == "1" ]]; then
    # F-2 수정 (2026-08-19): PIPELINE_UUID 환경변수는 실측 결과 hook 자식 프로세스에 전달되지 않는다
    # (otest-1 실측 + 본 재검증 공통 확인 — env/printenv에 PIPELINE_UUID 자체가 없음).
    # .session_id만 쓰면 팀에이전트에서는 자기 개별 세션ID가 나와 state 경로가 항상 빈 곳을 가리켜
    # IDLE로 폴백 → 차단이 무력화된다(실측 재현됨).
    # 우선순위: ① PIPELINE_UUID 환경변수(주입되는 향후 버전 대비, 현재는 대개 unset)
    #           ② 프로세스 트리 조상에서 --parent-session-id 파싱(실측상 신뢰 가능한 유일한 경로)
    #           ③ .session_id(메인 전용 — 팀에이전트면 ②가 먼저 잡히므로 도달 안 함)
    _COMMIT_UUID_EARLY="${PIPELINE_UUID:-}"
    if [[ -z "$_COMMIT_UUID_EARLY" ]]; then
      _COMMIT_PID_WALK=$$
      _COMMIT_DEPTH_WALK=0
      while [[ $_COMMIT_DEPTH_WALK -lt 10 && -n "$_COMMIT_PID_WALK" && "$_COMMIT_PID_WALK" != "1" ]]; do
        _COMMIT_CMDLINE_WALK=$(tr '\0' ' ' < "/proc/${_COMMIT_PID_WALK}/cmdline" 2>/dev/null)
        if [[ "$_COMMIT_CMDLINE_WALK" =~ --parent-session-id[[:space:]]+([0-9a-f-]{36}) ]]; then
          _COMMIT_UUID_EARLY="${BASH_REMATCH[1]}"
          break
        fi
        _COMMIT_PID_WALK=$(awk '{print $4}' "/proc/${_COMMIT_PID_WALK}/stat" 2>/dev/null)
        (( _COMMIT_DEPTH_WALK++ )) || true
      done
    fi
    [[ -z "$_COMMIT_UUID_EARLY" ]] && _COMMIT_UUID_EARLY=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null) || true
    if [[ -n "$_COMMIT_UUID_EARLY" ]]; then
      source "${HARNESS_HOOK_DIR}/lib/session_id.sh" 2>/dev/null || true
      _COMMIT_STATE_EARLY=$(state_read "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${_COMMIT_UUID_EARLY}/state" 2>/dev/null | awk '{print $1}') || _COMMIT_STATE_EARLY=""
      if [[ "$_COMMIT_STATE_EARLY" == "DEV" || "$_COMMIT_STATE_EARLY" == "TEST" ]]; then
        echo "{\"decision\":\"block\",\"reason\":\"❌ [F-COMMIT-1] state=${_COMMIT_STATE_EARLY} 에서 git commit 금지. 커밋은 odone_git(state=DONE) 또는 ofinish Step7.5(state=FINISH) 전용입니다. → odone 을 먼저 호출하세요. (L-228 · 사이클14 파이프라인 이탈 재발방지)\"}"
        exit 2
      fi
    fi
  fi
fi
# --- F-COMMIT-1 끝 ---

# --- F-DESTROY-1: 사이클65 — cwd 의존 파괴 명령 차단 (상대경로 대상 금지) ---
# 배경: 사이클65 실사고 — 한 프로젝트의 작업트리 전체 + .git 이 소실됐다.
#       oio dir_delete 가 PATH_NOT_ALLOWED, `rm -rf` 가 COMMAND_BLOCKED 로 각각 막히자
#       에이전트가 ★기능적 등가물★ `find . -type f -delete` 를 찾아냈고,
#       cd 실패(대상 이미 소멸) + `2>/dev/null` 은폐 + oio bash_exec 의 cwd 유지 특성이 겹쳐
#       셸이 프로젝트 루트에 있는 채로 `.` 을 지웠다. `.git/objects` 0개 — 로컬 복구 불가.
#
# ★설계 원칙 — 열거하지 않는다★
#   `rm -rf` 를 막으면 `find -delete` 가 나오고, 그것도 막으면 `xargs rm` 이 나온다.
#   금지어 목록은 열거하지 않은 등가물에서 반드시 뚫린다(사고 당사자·조사자 공통 결론).
#   ⇒ 판정 축을 하나로 세운다: ★파괴 명령의 대상이 절대경로인가★
#     - 절대경로면 통과 — 무엇을 지우는지 명령문에 명시돼 있어 cwd 와 무관하다.
#     - 상대경로/`.`/누락이면 차단 — 대상이 cwd 에 따라 달라지는데,
#       oio bash_exec 는 호출 간 cwd 를 유지하므로 ★에이전트가 자기 cwd 를 모르는 것이 정상★이다.
#   이 축은 rm / find -delete / find -exec rm / xargs rm / 인터프리터 unlink 를 한 번에 덮는다.
#
# ★한계 (알고 있어야 한다 — 완전 차단이 아니다)★
#   ① 변수·치환 대상(`rm -rf "$DIR"`)은 정적 판정 불가 → fail-open 통과시킨다.
#   ② base64/eval 로 난독화한 명령은 텍스트 판정을 원리적으로 우회한다.
#   ③ 절대경로여도 그 경로 자체가 틀리면(`rm -rf <프로젝트 루트>`) 막지 못한다.
#      이 축이 막는 것은 "의도하지 않은 대상"이지 "잘못 지정한 대상"이 아니다.
#   ④ `cd /abs && rm -rf ./x` 처럼 cd 가 성공하면 안전한 경우도 함께 막는다(과차단).
#      대안이 명확하므로(절대경로로 쓰면 됨) 이 과차단은 수용한다.
#   ⇒ ①~③ 의 잔여 위험은 이 hook 이 아니라 oio 서버측 ALLOWED_ROOTS 가 담당한다(이중 방어).
#
# 설계: ⓐ 이 hook 자신을 다루는 명령은 항상 통과(자기 차단 방지).
#       ⓑ 순수 echo/printf/주석은 텍스트 출력이므로 면제(F-COMMIT-1 동일 선례). 파이프 있으면 면제 안 함.
#       ⓒ find 의 ★읽기 용도★(-print/-exec grep/| head)는 절대 막지 않는다 — 탐색이 죽으면 안 된다.
#       ⓓ 판정 불가 시 fail-open.
# 비상 스위치: hooks/DISABLE_DESTROY_GUARD 생성 시 무력화 (기존 가드 관례 동일).
if [[ "$TOOL_NAME" == "mcp__oio__bash_exec" ]] && [[ ! -f "$HOME/.claude/hooks/DISABLE_DESTROY_GUARD" ]]; then
  _DS_CMD=$(echo "$INPUT" | jq -r '.tool_input.command // .tool_input.cmd // empty' 2>/dev/null || echo "")

  # ⓐ 이 hook 자신을 읽고/고치는 명령은 무조건 통과 (자기 차단 금지)
  if [[ -n "$_DS_CMD" ]] && ! echo "$_DS_CMD" | grep -q 'write_guard\.sh'; then
    _DS_REASON=""

    # (D) 인터프리터 원라이너 파괴 — ★분리 전 전체 명령 대상★
    #   `python3 -c "import shutil; shutil.rmtree('.')"` 는 ; 로 쪼개면 -c 와 rmtree 가
    #   서로 다른 조각으로 찢어져 판정이 무력화된다. 그래서 분리보다 먼저 본다.
    if echo "$_DS_CMD" | grep -qP '(^|[^-[:alnum:]_./])(perl|python3?|ruby|node)\b' \
       && echo "$_DS_CMD" | grep -qP '(unlink|os\.remove|os\.unlink|os\.rmdir|shutil\.rmtree|rmtree|fs\.unlinkSync|fs\.rmSync|fs\.unlink|File\.delete|FileUtils\.rm)'; then
      _DS_REASON="인터프리터 원라이너 파괴 호출(unlink/rmtree 등) — 대상이 코드 문자열 안에 있어 정적 판정이 불가능합니다"
    fi

    if [[ -z "$_DS_REASON" ]]; then
      # ; && || | 개행 으로 분리해 각 절을 독립 판정
      while IFS= read -r _ds_seg; do
        [[ -n "$_ds_seg" ]] || continue

        # ⓑ 순수 echo/printf/주석 → 텍스트 출력일 뿐 실행이 아니다. 파이프 있으면 면제 안 함.
        if echo "$_ds_seg" | grep -qP '^\s*(#|echo\b|printf\b)' && ! echo "$_ds_seg" | grep -qP '\|'; then
          continue
        fi

        # (A) find + 파괴 액션 — 대상(첫 비옵션 인자)이 절대경로가 아니면 차단.
        #     ⓒ -print / -exec grep / | head 등 ★읽기 용도 find 는 여기 걸리지 않는다★.
        if echo "$_ds_seg" | grep -qP '(^|[^-[:alnum:]_./])find\b' \
           && echo "$_ds_seg" | grep -qP '(-delete\b|-exec\s+(rm|unlink|truncate|shred|mv)\b|-execdir\s+(rm|unlink|truncate|shred|mv)\b|-ok\s+rm\b)'; then
          _DS_TGT=$(echo "$_ds_seg" | sed -n 's/.*\bfind[[:space:]]\+//p' \
                    | awk '{for(i=1;i<=NF;i++){if($i=="-H"||$i=="-L"||$i=="-P"||$i=="-xdev"||$i=="-mount"){continue}; print $i; exit}}')
          case "$_DS_TGT" in
            /*) : ;;
            -*|"") _DS_REASON="find 의 탐색 대상 경로가 없습니다(=cwd 를 암묵 대상으로 삼음)"; break ;;
            *)     _DS_REASON="find 의 탐색 대상이 상대경로입니다: '${_DS_TGT}'"; break ;;
          esac
        fi

        # (B) xargs 로 파괴 — 대상이 표준입력이라 명령문만으로는 무엇을 지우는지 알 수 없다.
        if echo "$_ds_seg" | grep -qP '\bxargs\b(\s+-\S+(\s+\S+)?)*\s+(sudo\s+)?(rm|unlink|shred|truncate)\b'; then
          _DS_REASON="xargs 로 파괴 명령을 실행합니다 — 대상이 표준입력이라 정적 판정이 불가능합니다"
          break
        fi

        # (C) rm / unlink / shred 의 피연산자가 상대경로
        # 2026-09-06 정정: 세그먼트 "명령 위치"(선행 sudo 허용)일 때만 매칭하도록 앵커링.
        # 종전 정규식은 세그먼트 어디든(문자열/인자 안 포함) rm 토큰이 있으면 매칭돼
        # `git commit -m "...rm 패턴을..."`, `sed -i 's|...rm 패턴...|...'`,
        # `grep -qP 'rm\s+/'` 같은 rm 리터럴을 삭제 명령으로 오인 차단했다.
        if echo "$_ds_seg" | grep -qP '^\s*(?:sudo\s+)?(rm|unlink|shred)\b'; then
          _DS_OPS=$(echo "$_ds_seg" | grep -oP '^\s*(?:sudo\s+)?(?:rm|unlink|shred)\s+\K.*$')
          _DS_BAD=""
          # ★set -f 로 글로브 확장을 끈다★ — 끄지 않으면 `rm -rf *` 의 * 가
          #   hook 프로세스의 실제 cwd 파일명으로 확장돼 판정이 파일 유무에 좌우된다.
          set -f
          for _ds_o in $_DS_OPS; do
            case "$_ds_o" in
              -*) continue ;;
              /*) continue ;;                 # 절대경로 → 안전
              \$*|\"\$*|\'\$*) continue ;;    # 변수 — 정적 판정 불가, fail-open (한계 ①)
              '{}'|';'|'+') continue ;;       # find -exec 잔여 토큰
              [0-9]\>*|\>*|\>\>*|\<*|\&\>*) continue ;;   # 리다이렉션 토큰 — 삭제 대상 아님
              *) _DS_BAD="$_ds_o"; break ;;
            esac
          done
          set +f
          if [[ -n "$_DS_BAD" ]]; then
            _DS_REASON="rm/unlink/shred 의 삭제 대상이 상대경로입니다: '${_DS_BAD}'"
            break
          fi
        fi
      done <<< "$(echo "$_DS_CMD" | awk '{
        # quote-aware 마스킹: 따옴표(작/큰) 안의 ; | & 는 세그먼트 구분자가 아니다.
        # 예: sed -i "s|rm 패턴|x|" 의 | 는 sed 구분자이지 셸 파이프가 아님(2026-09-06).
        # 따옴표 밖의 ; | & 는 그대로 두어 실제 파이프/체인 분리를 보존한다(fail-open 방지).
        out=""; sq=0; dq=0
        for (i=1;i<=length($0);i++) { c=substr($0,i,1)
          if (c=="\x27" && dq==0) sq=!sq
          else if (c=="\"" && sq==0) dq=!dq
          if ((sq||dq) && (c==";"||c=="|"||c=="&")) c="\x01"
          out=out c
        }
        print out
      }' | tr ';|&\n' '\n\n\n\n')"
    fi

    if [[ -n "$_DS_REASON" ]]; then
      echo "{\"decision\":\"block\",\"reason\":\"🚫 [사이클65/F-DESTROY-1] cwd 의존 파괴 명령 차단 — ${_DS_REASON}. oio bash_exec 는 호출 간 working directory 를 유지하므로 지금 셸이 어느 디렉토리에 있는지 확신할 수 없습니다. 사이클65 에서 정확히 이 형태(cd 실패 후 find . -type f -delete)로 작업트리와 .git 이 통째로 삭제됐습니다(로컬 복구 불가). → 삭제 대상을 ★절대경로★로 명시하십시오. 예: rm -rf <프로젝트 루트>/tmp/x · find <프로젝트 루트> -name '*.tmp' -delete. 더 나은 경로는 mcp__oio__file_delete / dir_delete 입니다(ALLOWED_ROOTS 검증 포함). 임시 산출물은 처음부터 프로젝트 루트 이하에 만드십시오. 비상 시 hooks/DISABLE_DESTROY_GUARD 로 우회 가능.\"}"
      exit 2
    fi
  fi
fi
# --- F-DESTROY-1 끝 ---

# --- F11: L-362 AST lint (session_manager.py 수정 감지 → lib/l362_lint.sh 호출) ---
# oio file_edit/file_write 대상이 session_manager.py(또는 oio-mcp-server/*.py)인 경우,
# 편집 시점의 파일 현재 상태를 AST 정적 분석. `with _fs_lock:` 내부 blocking I/O 검출.
# 현재 파일 상태 기반 pre-check — 팀/메인 구분 없이 전역 적용 (L-362 물리 차단 의무).
case "$TOOL_NAME" in
  mcp__oio__file_edit|mcp__oio__file_write)
    _L362_PATH=$(echo "$INPUT" | jq -r '.tool_input.path // .tool_input.file_path // empty' 2>/dev/null || echo "")
    if [[ "$_L362_PATH" =~ session_manager\.py$ ]] || [[ "$_L362_PATH" =~ oio-mcp-server/.*\.py$ ]]; then
      if [[ -f "$_L362_PATH" && -x "${HARNESS_HOOK_DIR}/lib/l362_lint.sh" ]]; then
        _L362_OUT=$("${HARNESS_HOOK_DIR}/lib/l362_lint.sh" "$_L362_PATH" 2>&1)
        _L362_RC=$?
        if [[ "$_L362_RC" -eq 1 ]]; then
          _L362_SUMMARY=$(echo "$_L362_OUT" | head -c 300 | tr '\"\\' "'/" | tr '\n' ' ')
          echo "{\"decision\":\"block\",\"reason\":\"❌ [L-362/F11] _fs_lock 컨텍스트 내부 blocking I/O 감지 — 저장 거부. ${_L362_SUMMARY}\"}"
          exit 2
        fi
      fi
    fi
    ;;
esac

# --- stdin_eof_monitor 재작성 차단 (원인 4) ---
# server.py에 _start_stdin_eof_monitor를 다시 추가하는 시도를 물리 차단
# 이유: FastMCP stdio 충돌로 서버 자폭 유발
case "$TOOL_NAME" in
  mcp__oio__file_edit|mcp__oio__file_write)
    _GUARD_TARGET_PATH=$(echo "$INPUT" | jq -r '.tool_input.path // .tool_input.file_path // empty' 2>/dev/null || echo "")
    if [[ "$_GUARD_TARGET_PATH" =~ oio-mcp-server/server\.py$ ]]; then
      _GUARD_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.new_text // .tool_input.new_string // .tool_input.content // empty' 2>/dev/null || echo "")
      if echo "$_GUARD_CONTENT" | grep -qE '_start_stdin_eof_monitor|_stdin_eof_monitor_shutdown|def _start_stdin_eof'; then
        echo '{"decision":"block","reason":"🚫 stdin_eof_monitor 재작성 금지 — FastMCP stdio 충돌로 서버 자폭. 재작성 시도는 물리 차단됩니다. (원인 4)"}'
        exit 2
      fi
    fi
    ;;
esac

case "$TOOL_NAME" in
  mcp__oio__file_edit|mcp__oio__file_write|mcp__oio__file_delete|\
  mcp__oio__file_rename|mcp__oio__file_move|mcp__oio__file_copy|\
  mcp__oio__file_symlink|\
  mcp__oio__dir_create|mcp__oio__dir_delete|mcp__oio__dir_move|\
  mcp__oio__dir_rename|mcp__oio__bash_exec|\
  mcp__plugin_serena_serena__replace_content|mcp__plugin_serena_serena__replace_symbol_body|\
  mcp__plugin_serena_serena__insert_after_symbol|mcp__plugin_serena_serena__insert_before_symbol|\
  mcp__plugin_serena_serena__safe_delete_symbol|mcp__plugin_serena_serena__rename_symbol|\
  mcp__plugin_serena_serena__create_text_file|\
  mcp__serena__replace_content|mcp__serena__replace_symbol_body|\
  mcp__serena__insert_after_symbol|mcp__serena__insert_before_symbol|\
  mcp__serena__safe_delete_symbol|mcp__serena__rename_symbol|\
  mcp__serena__create_text_file)
    # --- F-GOAL-1: goal.json locked=true 물리 보호 (자기 세션 격리 §(a) 준수) ---
    # 대상: 자기 UUID의 session-env/${UUID}/goal.json 만. 다른 세션/경로 영향 0.
    # locked=true 일 때 수정/삭제/이동 시도를 물리 차단. locked=false/부재 시 무영향.
    #
    # ─────────────────────────────────────────────────────────────────────
    # [c41-odev4] 2건 동시 반영
    #
    # (A) ★현존 구멍 차단★ — 종전 안쪽 case 에 mcp__oio__bash_exec 가 빠져 있었다.
    #     실측(2026-08-26): locked=true 인데 `sed -i` / `rm -f` 가 ★rc=0 통과★ 했다
    #     (같은 조건에서 file_edit 은 rc=2 차단 — 양성 통제). 계약 문서가 셸로는 무방비였다.
    #     ⇒ bash_exec 는 명령 문자열에 goal.json 경로 + 쓰기성 동사가 함께 있으면 차단한다.
    #
    # (B) ★의도 무구분 해소★ — 종전에는 "이행완료 unlock" 과 "계약 변조" 를 구분하지 못해
    #     ofinish Step 3c(copy→unlock→delete)의 정당한 unlock 까지 막혔다.
    #     ⇒ 아래 ★3조건 AND★ 를 모두 만족할 때만 unlock 을 허용한다:
    #        ① 같은 디렉토리에 goal_{goal_id}_completed.json 사본 존재 (copy 선행 실증)
    #        ② state == FINISH                                        (종료 시점 한정)
    #        ③ edit 이 locked:true→false ★단일 필드★ 변경           (내용 검증 — 핵심)
    #     ③이 "unlock 을 빌미로 acceptance 를 함께 고치는 우회" 를 막는다.
    #
    # ★못 잡는 것 (게이트 자기 사각지대 — 사이클40 A2 교훈)★
    #   1. bash_exec 판정은 ★명령 문자열 매칭★ 이다. 변수 치환($G)·따옴표 분할·base64·
    #      python -c 로 경로를 조립하면 문자열에 goal.json 이 안 보여 통과한다.
    #      ⇒ 정면 우회는 막지만 ★작정한 우회는 못 막는다★ (그건 F-GOAL-1 의 범위 밖).
    #   2. 사본(①)은 존재 + ★내용 동일(cmp)★ 까지 본다. 다만 ★같은 계약을 두 번 unlock★
    #      하는 것은 막지 못한다(사본이 원본과 같으면 몇 번이든 통과). state=FINISH 와
    #      묶여 있어 실사용상 문제는 없으나, ①은 "보관했다" 의 증명이지 "1회성" 보장은 아니다.
    #   3. ③은 jq 로 두 JSON 을 비교한다. jq 부재 시 ★차단 유지★(fail-closed) — 안전 측.
    #   4. 타 세션 goal.json 은 애초에 검사 대상이 아니다(§(a) 격리) — 보호도 안 된다.
    #   5. 자기 세션이라도 CLAUDE_CONFIG_DIR 밖 경로에 둔 goal.json 은 대상 밖이다.
    # ─────────────────────────────────────────────────────────────────────

    # (A) bash_exec 경유 goal.json 쓰기/삭제 차단 — 안쪽 case 진입 전에 선처리한다.
    if [[ "$TOOL_NAME" == "mcp__oio__bash_exec" ]]; then
      _BE_CMD=$(echo "$INPUT" | jq -r '.tool_input.command // .tool_input.cmd // empty' 2>/dev/null || echo "")
      if echo "$_BE_CMD" | grep -qP 'session-env/[^/ ]+/goal\.json'; then
        # 쓰기성 동사가 함께 있을 때만 차단 (cat/grep/jq 조회는 통과 — false positive 방지)
        if echo "$_BE_CMD" | grep -qP '(\bsed\b[^|]*-i|\brm\b|\bmv\b|\bcp\b|\btruncate\b|\btee\b|>\s*[^ |]*goal\.json|\bjq\b[^|]*(-i|--in-place)|\bpython3?\b[^|]*\bw\b)'; then
          _BE_UUID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
          [[ -z "$_BE_UUID" && -n "${PIPELINE_UUID:-}" ]] && _BE_UUID="$PIPELINE_UUID"
          _BE_GOAL="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${_BE_UUID}/goal.json"
          if [[ -n "$_BE_UUID" && -f "$_BE_GOAL" ]]; then
            _BE_LOCKED=$(jq -r '.locked // false' "$_BE_GOAL" 2>/dev/null || echo "false")
            if [[ "$_BE_LOCKED" == "true" ]]; then
              echo '{"decision":"block","reason":"🔒 [F-GOAL-1/bash] goal.json locked=true — 셸 명령(sed/rm/mv/tee 등)으로 계약 문서를 변경·삭제할 수 없습니다. 이행완료 정리는 ofinish Step 3c 절차(copy → file_edit 로 locked만 false → delete)를 사용하세요."}'
              exit 2
            fi
          fi
        fi
      fi
    fi

    case "$TOOL_NAME" in
      mcp__oio__file_edit|mcp__oio__file_write|mcp__oio__file_delete|mcp__oio__file_move|mcp__oio__file_rename)
        _GOAL_PATH=$(echo "$INPUT" | jq -r '.tool_input.path // .tool_input.file_path // .tool_input.src // empty' 2>/dev/null || echo "")
        # session-env/<uuid>/goal.json 형태만 매칭 (정확한 경로 — 와일드카드 오작동 방지)
        if echo "$_GOAL_PATH" | grep -qP 'session-env/[^/]+/goal\.json$'; then
          # 자기 세션 UUID 추출 (session_id JSON 필드 — write_guard 표준 방식)
          _GUARD_UUID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
          [[ -z "$_GUARD_UUID" && -n "${PIPELINE_UUID:-}" ]] && _GUARD_UUID="$PIPELINE_UUID"
          _SELF_GOAL="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${_GUARD_UUID}/goal.json"
          # 대상이 정확히 "자기 세션 goal.json"일 때만 검사 (타 세션 경로는 검사 안 함 → 격리 §(a))
          if [[ -n "$_GUARD_UUID" && "$_GOAL_PATH" == "$_SELF_GOAL" && -f "$_SELF_GOAL" ]]; then
            _GOAL_LOCKED=$(jq -r '.locked // false' "$_SELF_GOAL" 2>/dev/null || echo "false")
            if [[ "$_GOAL_LOCKED" == "true" ]]; then
              # [c41-odev4] ★이행완료 unlock 예외 — 3조건 AND★ (file_edit 에만 적용)
              _UNLOCK_OK=0
              if [[ "$TOOL_NAME" == "mcp__oio__file_edit" ]]; then
                _G_DIR=$(dirname "$_SELF_GOAL")
                _G_ID=$(jq -r '.goal_id // empty' "$_SELF_GOAL" 2>/dev/null || echo "")
                # ① copy 선행 실증 — goal_{goal_id}_completed.json 사본이 존재하고
                #    ★그 내용이 지금 unlock 하려는 원본과 동일해야 한다★.
                #    [c41-odev4 라이브 회귀] 존재만 보면 ★직전 사이클의 낡은 사본★ 이 남아 있을 때
                #    조건①이 공짜로 통과한다(실측: 사이클40 사본 Aug26 15:29 잔존 → rc=0 오통과).
                #    ⇒ 내용 일치까지 봐야 "이번 계약을 방금 보관했다" 가 실증된다.
                _C1=0
                if [[ -n "$_G_ID" && -f "${_G_DIR}/goal_${_G_ID}_completed.json" ]]; then
                  if cmp -s "$_SELF_GOAL" "${_G_DIR}/goal_${_G_ID}_completed.json"; then
                    _C1=1
                  fi
                fi
                # ② state == FINISH (종료 시점 한정)
                _C2=0
                _ST=$(awk '{print $1}' "${_G_DIR}/state" 2>/dev/null || echo "")
                [[ "$_ST" == "FINISH" ]] && _C2=1
                # ③ 내용 검증 — locked:true→false ★단일 필드★ 변경인가
                #    편집 결과를 메모리에서 재현해 원본과 diff. jq 부재/실패 시 fail-closed(0).
                _C3=0
                _OLD=$(echo "$INPUT" | jq -r '.tool_input.old_string // .tool_input.old // .tool_input.old_text // empty' 2>/dev/null || echo "")
                _NEW=$(echo "$INPUT" | jq -r '.tool_input.new_string // .tool_input.new // .tool_input.new_text // empty' 2>/dev/null || echo "")
                if [[ -n "$_OLD" && -n "$_NEW" ]] && command -v python3 >/dev/null 2>&1; then
                  _C3=$(OLD="$_OLD" NEW="$_NEW" GOAL="$_SELF_GOAL" timeout 3 python3 -c '
import json,os,sys
try:
    src=open(os.environ["GOAL"],encoding="utf-8").read()
    old,new=os.environ["OLD"],os.environ["NEW"]
    if src.count(old)!=1: print(0); sys.exit()
    a=json.loads(src); b=json.loads(src.replace(old,new,1))
    # locked 만 true->false 로 바뀌고 나머지 키/값은 완전 동일해야 한다
    if a.get("locked") is not True or b.get("locked") is not False: print(0); sys.exit()
    a.pop("locked",None); b.pop("locked",None)
    print(1 if a==b else 0)
except Exception: print(0)
' 2>/dev/null || echo 0)
                fi
                [[ "$_C1" == "1" && "$_C2" == "1" && "$_C3" == "1" ]] && _UNLOCK_OK=1
              fi

              if [[ "$_UNLOCK_OK" != "1" ]]; then
                echo '{"decision":"block","reason":"🔒 [F-GOAL-1] goal.json locked=true — 파이프라인 계약 문서는 잠금 상태입니다. 이행완료 정리라면 ofinish Step 3c 순서를 지키세요: ① goal_{goal_id}_completed.json 로 copy ② state=FINISH ③ locked 필드만 true→false 로 file_edit. 세 조건이 모두 충족될 때만 unlock 이 허용됩니다(다른 필드를 함께 바꾸면 차단됩니다)."}'
                exit 2
              fi
            fi
          fi
        fi
        ;;
    esac
    # --- F-GOAL-1 끝 ---

    # --- F-AC-1: acceptance_criteria.json 고정 파일명 덮어쓰기 물리 차단 (L-906) ---
    # 배경(실사고): 사이클56 의 acceptance_criteria.json 이 다음 사이클 쓰기에 덮여 ★실제로 소실★됐다.
    #   사본이 없어 복구 불가로 종결됐다. 원인은 파일명이 고정이라 매 사이클 같은 경로에 쓰이는 것이다.
    #   이 파일은 oplan 이 사이클당 1회 생성하고 그 뒤로는 immutable 이 원칙이다(otest/otest_verify 가 대조 기준으로 읽는다).
    #   ⇒ 정당한 덮어쓰기는 오직 "새 사이클 시작" 뿐이며, 그때는 ★이전 사이클분이 보존되어 있어야★ 한다.
    #
    # 판정(차단 조건 — AND):
    #   ① 대상이 session-env/<uuid>/{plans/,}acceptance_criteria.json 이다.
    #   ② 그 파일이 ★이미 존재★ 한다 (신규 생성은 항상 통과 — 첫 사이클/새 세션 무영향).
    #   ③ 기존 파일의 사이클 식별자 != 현재 세션의 식별자 (같으면 같은 사이클 갱신이므로 통과).
    #   ④ 기존 파일과 ★내용이 동일한 사본★ 이 같은 디렉토리에 없다 (있으면 이미 보존됨 → 통과).
    #
    # ④가 탈출구다. 새 사이클을 시작하려면 file_copy 한 번으로 보존하면 통과한다.
    #   사본 인정 이름: acceptance_criteria_*.json (기존 관행 — _prev_/_conv_/타임스탬프 접미 전부 포함)
    #   ★존재만이 아니라 cmp 로 내용 일치까지 본다★ — 낡은 사본이 남아 공짜 통과하는 F-GOAL-1 ①의
    #   라이브 회귀(사이클41 실측)와 동형 결함을 처음부터 배제한다.
    #
    # 식별자 추출: conv_id > cycle 순. 둘 다 없으면 "" (미상).
    #   ★미상은 현재 식별자와 불일치로 취급한다(fail-safe)★ — 구 스키마 파일일수록 보존 가치가 크고,
    #   탈출구(④ 사본 1회)가 저렴하므로 데이터를 지키는 쪽으로 판정한다.
    #
    # ★못 잡는 것 (자기 사각지대 — 명시)★
    #   1. bash_exec 판정은 명령 문자열 매칭이다. 변수 치환·base64·python 경로 조립은 통과한다
    #      (F-GOAL-1 (A) 와 동일한 한계 — 정면 우회는 막지만 작정한 우회는 못 막는다).
    #   2. 타 세션 경로는 검사 대상이 아니다(세션 격리 §(a)) — 보호도 안 된다.
    #   3. 사본을 만든 뒤 그 사본을 지우면 다시 차단으로 돌아간다(보존 실패로 간주 — 의도된 동작).

    # (A) bash_exec 우회 경로 차단 — sed -i / tee / cp / mv / truncate / 리다이렉션 / python open(w)
    if [[ "$TOOL_NAME" == "mcp__oio__bash_exec" ]]; then
      _AC_CMD=$(echo "$INPUT" | jq -r '.tool_input.command // .tool_input.cmd // empty' 2>/dev/null || echo "")
      if echo "$_AC_CMD" | grep -qP 'session-env/[^ ]*acceptance_criteria\.json'; then
        if echo "$_AC_CMD" | grep -qP '(\bsed\b[^|]*-i|\brm\b|\bmv\b|\bcp\b|\btruncate\b|\btee\b|>\s*[^ |]*acceptance_criteria\.json|\bjq\b[^|]*(-i|--in-place)|\bpython3?\b)'; then
          # cp/mv 는 ★목적지가 acceptance_criteria.json 일 때만★ 위험하다.
          # 보존 목적(원본 → 사본)의 cp 는 반드시 통과시켜야 한다 — 탈출구를 막으면 게이트가 교착한다.
          _AC_SAFE_COPY=0
          if echo "$_AC_CMD" | grep -qP '\b(cp|mv)\b[^|]*acceptance_criteria\.json\s+[^ |]*acceptance_criteria_[^ |]*\.json\s*$'; then
            _AC_SAFE_COPY=1
          fi
          if [[ "$_AC_SAFE_COPY" != "1" ]]; then
            echo '{"decision":"block","reason":"🔒 [F-AC-1/bash] acceptance_criteria.json 은 셸 명령(sed -i/tee/cp/mv/rm/python 등)으로 덮어쓰거나 삭제할 수 없습니다 — 사이클56 소실 사고(L-906) 재발 방지. 새 사이클을 시작하려면 먼저 mcp__oio__file_copy 로 acceptance_criteria_{식별자}.json 사본을 만든 뒤 file_write 하세요."}'
            exit 2
          fi
        fi
      fi
    fi

    # (B) 구조적 도구 경유 차단 — file_write/file_edit/file_delete/file_move/file_rename/file_copy(덮어쓰기)
    case "$TOOL_NAME" in
      mcp__oio__file_edit|mcp__oio__file_write|mcp__oio__file_delete|mcp__oio__file_move|mcp__oio__file_rename|mcp__oio__file_copy)
        # ★대상 판정★ — file_copy/file_move 는 ★목적지★ 가 피해 대상이다(H-1 과 동일 원칙).
        _AC_PATH=$(echo "$INPUT" | jq -r '[.tool_input.destination, .tool_input.dest, .tool_input.path, .tool_input.file_path, .tool_input.filepath] | map(select(. != null and . != "")) | .[0] // empty' 2>/dev/null || echo "")
        # file_delete/file_move/file_rename 는 ★원본 소실이 곧 피해★ 이므로 source 도 함께 본다.
        # ★file_copy 는 제외한다★ — copy 의 source 는 '읽히는 쪽'이라 소실되지 않는다.
        #   여기에 file_copy 를 포함하면 ★탈출구(원본→사본 보존) 자체가 차단되어 게이트가 교착★ 한다.
        #   (실측: 음성테스트 케이스19 에서 이 결함이 잡혔다 — 양방향 검증이 아니었으면 놓쳤을 자리다.)
        _AC_SRC=""
        case "$TOOL_NAME" in
          mcp__oio__file_delete|mcp__oio__file_move|mcp__oio__file_rename)
            _AC_SRC=$(echo "$INPUT" | jq -r '[.tool_input.path, .tool_input.file_path, .tool_input.source, .tool_input.src] | map(select(. != null and . != "")) | .[0] // empty' 2>/dev/null || echo "") ;;
        esac
        for _AC_T in "$_AC_PATH" "$_AC_SRC"; do
          [[ -z "$_AC_T" ]] && continue
          echo "$_AC_T" | grep -qP 'session-env/[^/]+/(plans/)?acceptance_criteria\.json$' || continue
          # ② 이미 존재할 때만 검사 (신규 생성은 통과)
          [[ -f "$_AC_T" ]] || continue
          # file_copy 로 ★사본을 만드는★ 정당 경로는 목적지가 acceptance_criteria_*.json 이므로
          # 위 grep(고정명 정확 일치)에 애초에 걸리지 않는다 — 별도 예외 불필요.

          _AC_DIR=$(dirname "$_AC_T")
          # ③ 식별자 대조 — 기존 파일 vs 현재 세션
          _AC_OLD_ID=$(timeout 3 python3 -c '
import json,sys
try:
    d=json.load(open(sys.argv[1],encoding="utf-8"))
    v=d.get("conv_id") or d.get("cycle") or ""
    print(str(v).strip())
except Exception: print("")
' "$_AC_T" 2>/dev/null || echo "")
          _AC_CUR_ID=$(cat "${_AC_DIR}/conv_id" 2>/dev/null || cat "${_AC_DIR}/../conv_id" 2>/dev/null || echo "")
          _AC_CUR_ID=$(echo "$_AC_CUR_ID" | tr -d '[:space:]')
          if [[ -n "$_AC_OLD_ID" && -n "$_AC_CUR_ID" && "$_AC_OLD_ID" == "$_AC_CUR_ID" ]]; then
            continue   # 같은 사이클 갱신 — 통과
          fi
          # ④ 내용 동일 사본이 이미 있으면 통과 (보존 실증)
          _AC_ARCHIVED=0
          for _AC_C in "${_AC_DIR}"/acceptance_criteria_*.json; do
            [[ -f "$_AC_C" ]] || continue
            if cmp -s "$_AC_T" "$_AC_C"; then _AC_ARCHIVED=1; break; fi
          done
          [[ "$_AC_ARCHIVED" == "1" ]] && continue

          echo "{\"decision\":\"block\",\"reason\":\"🔒 [F-AC-1] acceptance_criteria.json 덮어쓰기 차단 — 기존 파일은 다른 사이클(식별자: '${_AC_OLD_ID:-미상}') 산출물이고 현재는 '${_AC_CUR_ID:-미상}' 입니다. 사이클56 에서 이 파일이 덮여 실제로 소실됐습니다(L-906). 먼저 mcp__oio__file_copy 로 같은 디렉토리에 acceptance_criteria_${_AC_OLD_ID:-prev}.json 사본을 만드세요. 사본이 원본과 내용 일치하면 이 쓰기가 허용됩니다.\"}"
          exit 2
        done
        ;;
    esac
    # --- F-AC-1 끝 ---

    # --- H-1: agents/ · panes 삭제 전 잔존 팀에이전트 0건 강제 (2026-08-17) ---
    # 배경: 고아 팀에이전트 5개 사고. 종료가 완결되지 않았는데 agents/ 가 삭제되어
    #       추적 근거가 영구 소멸했다. 증적: .claude/evidence/agent_orphan_cleanup_20260817.md
    # 위치 근거: ★ 아래 "팀에이전트 → 항상 허용" 조기 exit 0 보다 반드시 앞에 있어야 한다.
    #           뒤에 두면 팀에이전트(PIPELINE_UUID 보유)가 전부 우회로가 되어 hook 이 무력해진다.
    #           실제로 agents/ 를 지우는 주체가 팀에이전트/ofinish 경로이므로 이 순서가 성패를 가른다.
    # 정책: 검사 실패(라이브러리 부재/오류) → 통과(fail-open). 검사 성공 + 잔존>0 → 차단(fail-closed).
    #       hook 자체의 오류로 세션이 멈추는 것이 고아 잔존보다 큰 사고이기 때문이다.
    # 긴급 정지: lib/orphan_scan.sh 를 지우거나 이름을 바꾸면 이 블록은 즉시 무력화된다(의도된 탈출구).
    # [3차 보강 2026-08-17] 판정 로직을 lib/orphan_scan.sh 로 완전 이관했다.
    #   1차 구현은 여기에 자체 정규식을 두어 oio 측과 **동일 결함을 공유**했고,
    #   그 결과 B1(상위 디렉토리)/B2(./)/B4(../) 가 두 계층을 동시에 통과했다(otest-1 실측).
    #   이제 경로 정규화·대상 판정·삭제성 판정 전부 check-path 한 곳에서만 수행한다.
    _H1_LIB="${HARNESS_HOOK_DIR}/lib/orphan_scan.sh"
    if [[ -r "$_H1_LIB" ]]; then
      # ★ B13 해소 — 도구별 실제 파라미터명을 모두 읽는다.
      #   1차 구현은 path/file_path/command 만 읽어 dir_move(source,destination) 를 영구 미검사했다.
      #   4차 보강: file_copy(destination) / file_symlink(link_path) 누락분 추가.
      #   ★ destination·link_path 를 **먼저** 본다 — 복사/링크는 '덮어써지는 쪽'이 피해 대상이다.
      #     (source 를 먼저 보면 agents 로 덮어쓰는 시도를 놓친다.)
      _H1_TARGET=$(echo "$INPUT" | jq -r '[.tool_input.destination, .tool_input.dest, .tool_input.link_path, .tool_input.path, .tool_input.file_path, .tool_input.filepath, .tool_input.source, .tool_input.src, .tool_input.target] | map(select(. != null and . != "")) | .[0] // empty' 2>/dev/null || echo "")
      # 보조 대상 — destination 이 무해해도 source 쪽이 보호 경로면 함께 검사한다(move/rename 대응).
      _H1_TARGET2=$(echo "$INPUT" | jq -r '[.tool_input.path, .tool_input.file_path, .tool_input.source, .tool_input.src] | map(select(. != null and . != "")) | .[0] // empty' 2>/dev/null || echo "")
      _H1_CMD=$(echo "$INPUT" | jq -r '.tool_input.command // .tool_input.cmd // empty' 2>/dev/null || echo "")

      # 삭제성 도구인지 먼저 본다(읽기/생성은 무관 — 오버헤드 0).
      _H1_APPLY=0
      case "$TOOL_NAME" in
        mcp__oio__dir_delete|mcp__oio__file_delete|mcp__oio__dir_move|mcp__oio__file_move|\
        mcp__oio__dir_rename|mcp__oio__file_rename|\
        mcp__oio__file_copy|mcp__oio__file_symlink|mcp__oio__file_write)
          # 4차 보강: file_copy(overwrite) / file_symlink(경로 치환) / file_write(내용 덮어쓰기)도
          # agents/ 를 파괴할 수 있다. 삭제만 막고 덮어쓰기를 열어두면 우회로가 된다.
          _H1_APPLY=1 ;;
        mcp__oio__bash_exec)
          _H1_APPLY=2 ;;   # 명령 문자열을 함께 넘겨 삭제성 여부까지 판정시킨다
      esac

      if [[ "$_H1_APPLY" != "0" ]]; then
        # bash_exec 은 명령 문자열 자체가 경로를 품고 있으므로 그대로 넘긴다.
        if [[ "$_H1_APPLY" == "2" ]]; then
          # 명령에서 보호 경로 후보를 추출 (없으면 검사 자체 불필요)
          _H1_TARGET=$(echo "$_H1_CMD" | grep -oE '[^[:space:]"'"'"']*session-env/[^[:space:]"'"'"']*' | head -1)
        fi
        if [[ -n "$_H1_TARGET" || -n "$_H1_TARGET2" ]]; then
          # ★ T3g 해소 — 타임아웃 2초(oio 측과 동일). 라이브러리가 매달려도 세션을 막지 않는다.
          _H1_VERDICT="PASS"
          if [[ -n "$_H1_TARGET" ]]; then
            _H1_VERDICT=$(timeout 2 bash "$_H1_LIB" check-path "$_H1_TARGET" "$_H1_CMD" 2>/dev/null) || _H1_VERDICT="UNKNOWN"
          fi
          # destination 이 무해하면 source 쪽도 확인 (move/rename 은 source 가 사라진다)
          if [[ "$_H1_VERDICT" != BLOCK\ * && -n "$_H1_TARGET2" && "$_H1_TARGET2" != "$_H1_TARGET" ]]; then
            _H1_VERDICT=$(timeout 2 bash "$_H1_LIB" check-path "$_H1_TARGET2" "$_H1_CMD" 2>/dev/null) || _H1_VERDICT="UNKNOWN"
          fi
          # fail-open: UNKNOWN/빈값/타임아웃(rc=124) 전부 통과
          if [[ "$_H1_VERDICT" == BLOCK\ * ]]; then
            _H1_UUID=$(echo "$_H1_VERDICT" | awk '{print $2}')
            _H1_CNT=$(echo "$_H1_VERDICT" | awk '{print $3}')
            if [[ "$_H1_UUID" == "__ALWAYS__" ]]; then
              # 최상위 경로(session-env 자체 / ~/.claude) — 고아 유무 무관 무조건 차단
              echo "{\"decision\":\"block\",\"reason\":\"🚫 [H-1] 전체 세션 추적 근거(session-env 또는 .claude 통째)를 삭제·치환하려 합니다. 모든 세션의 고아 추적이 영구 불가능해집니다. 개별 세션은 session-env/<uuid> 단위로 정리하세요.\"}"
            else
              _H1_LIST=$(timeout 2 bash -c "source '$_H1_LIB'; orphan_scan_detail '$_H1_UUID'" 2>/dev/null | head -5 | tr '\t' ' ' | tr '\n' ';' | tr -d '"\\' | head -c 260)
              echo "{\"decision\":\"block\",\"reason\":\"🚫 [H-1] 팀에이전트 ${_H1_CNT}건이 아직 살아있는데 세션 추적 근거(agents/panes 또는 session-env)를 삭제하려 합니다. 지금 지우면 고아가 영구 미탐지됩니다. 먼저 종료를 완결하세요(oinit). 잔존: ${_H1_LIST}\"}"
            fi
            exit 2
          fi
        fi
      fi
    fi
    # --- H-1 끝 ---

    # 팀에이전트 → 항상 허용
    # F-ISO-2 (세션 격리 §(a) 강화): 대상 경로가 session-env/<UUID>/ 패턴이면 그 UUID가
    # 자기 세션(PIPELINE_UUID)일 때만 이 조기 exit 0을 적용한다. 경로에 session-env 세그먼트가
    # 없는 공용 .claude/ 경로(hooks/skills/scripts 등)는 종전대로 무조건 허용 (정책 변경 없음).
    # 타 세션 session-env/<다른UUID>/ 는 여기서 exit 0 하지 않고 아래 일반 검사로 흘려보낸다.
    if [[ -n "${PIPELINE_UUID:-}" ]]; then
      _ISO2_PATH=$(echo "$INPUT" | jq -r '.tool_input.path // .tool_input.file_path // .tool_input.filepath // empty' 2>/dev/null || echo "")
      _ISO2_TARGET_UUID=$(echo "$_ISO2_PATH" | grep -oP 'session-env/\K[^/]+' | head -1)
      # L-014 재발방지: session-env 세그먼트가 없다고 무조건 허용하면 안 된다 —
      # NTFS 프로젝트 경로(/mnt/[c-z]/)도 session-env 세그먼트가 없어 여기서 같이 새어나가
      # 팀에이전트 NTFS 직접 수정 차단(L-014)이 무력화됐다(실측 확인).
      # fall-through 시 도달하는 하단 state 체크는 _UUID를 자기 session_id로 조회하므로
      # 팀에이전트 자신의 session-env에는 state 파일이 없어 기본값 IDLE로 오판·통과한다
      # (실측 확인) — 따라서 여기서 즉시 명시적으로 차단한다(fall-through 의존 금지).
      if echo "$_ISO2_PATH" | grep -qP '^/mnt/[c-z]/'; then
        echo "{\"decision\":\"block\",\"reason\":\"🚨 [L-014] NTFS 직접 수정 금지! 팀에이전트도 rsync 방식 필수. 대상: ${_ISO2_PATH}\"}"
        exit 2
      elif [[ -z "$_ISO2_TARGET_UUID" || "$_ISO2_TARGET_UUID" == "$PIPELINE_UUID" ]]; then
        exit 0
      fi
      # session-env 세그먼트가 있고 자기 세션과 다름 → fall-through (아래 일반 검사로 차단 판정 위임)
    fi
    # Fix 3 (L-NEW): session-env 파이프라인 메타 파일 직접 쓰기 보호
    # PIPELINE_UUID 없는 메인이 oio file_write/file_edit으로 state/classification/team_name 덮어쓰기 차단
    # mcp__oio__session_state 도구는 다른 도구이므로 영향 없음
    # Finding 5 (L-NEW): mcp__oio__session_state는 write_guard 매처 밖(의도적 탈출 경로)
    # → OK 고착 시 메인이 IDLE로 리셋할 수 있는 유일한 수단 (Fix 12 abort path 활성화 전제)
    if [[ "$TOOL_NAME" == "mcp__oio__file_write" || "$TOOL_NAME" == "mcp__oio__file_edit" ]]; then
      _META_PATH=$(echo "$INPUT" | jq -r '.tool_input.path // empty' 2>/dev/null || echo "")
      if echo "$_META_PATH" | grep -qP 'session-env/[^/]+/(state|classification|team_name|status|entry_tier)$'; then
        echo '{"decision":"block","reason":"🚫 [Fix 3/L-NEW] session-env 메타 파일 직접 쓰기 금지 — state/classification/team_name/status/entry_tier는 mcp__oio__session_state 도구 또는 state_machine.sh 경유 필수"}'
        exit 2
      fi
    fi
    # .claude/ 하위 경로 → 파이프라인 상태 무관 항상 허용
    # F-NEW-1 (symlink traversal 방어): .claude/ 경로라도 symlink 해석 결과가 NTFS(/mnt/)면 허용 불가
    _OIO_PATH=$(echo "$INPUT" | jq -r '.tool_input.path // empty' 2>/dev/null || echo "")
    _CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    # F-NEW-1-EXC (2026-08-01): CLAUDE_CONFIG_DIR가 세션 임시 디렉토리(/tmp/cc-*)인 구성에서
    # projects/*/memory/ 하위(MEMORY.md 등 자동메모리)는 정당한 NTFS symlink이므로 예외 허용
    if [[ "$_OIO_PATH" == "$_CLAUDE_DIR"/*/memory/*.md ]]; then
      exit 0
    fi
    if [[ "$_OIO_PATH" == "$_CLAUDE_DIR"/* || "$_OIO_PATH" == /home/*/.claude/* ]]; then
      # symlink 해석: .claude/ 경로가 NTFS를 가리키면 차단
      _RESOLVED_PATH=$(realpath -m "$_OIO_PATH" 2>/dev/null || echo "$_OIO_PATH")
      if echo "$_RESOLVED_PATH" | grep -qP '^/mnt/[c-z]/'; then
        echo '{"decision":"block","reason":"🚫 [F-NEW-1] .claude/ 심볼릭링크가 NTFS 경로를 가리킵니다 — symlink traversal 차단. 직접 NTFS 경로를 사용하세요."}'
        exit 2
      fi
      # F-ISO-3 (세션 격리 §(a) 강화): session-env/<UUID>/ 세그먼트가 있으면 그 UUID가
      # 자기 세션일 때만 통과. session-env 아닌 공용 .claude/ 경로는 종전대로 허용 (정책 변경 없음).
      #
      # ★[2026-09-13 사이클128 T-E] 팀에이전트 오차단 수정 — 격리는 유지하고 증명을 추가한다★
      #   문제: PIPELINE_UUID 는 ★환경변수★ 인데 팀에이전트는 그 값을 ★프롬프트 텍스트★ 로 받는다.
      #        hook 프로세스 환경에는 없다(실측 PIPELINE_UUID=<unset>). 그래서 폴백인
      #        stdin session_id(=팀에이전트 자신의 UUID)가 쓰였고, 파이프라인 UUID 와 달라
      #        ★자기 팀 산출물 경로가 "타 세션"으로 오판★ 됐다(oplan-128 계획서 쓰기 차단).
      #
      #   ⚠️ 비대칭이 핵심이었다: 정당한 쓰기는 막으면서, scratchpad→cp 우회는 못 막았다.
      #      (oplan 이 실제로 우회해 같은 경로에 썼다.) 보호 효과는 낮고 방해만 컸다.
      #
      #   조치 방향: ★차단을 푸는 것이 아니라 자기 세션임을 올바로 증명하는 것★.
      #   증명 수단 조사 결과(실제 stdin JSON 덤프 실측):
      #     - JSON 필드: session_id / transcript_path / cwd / agent_type / permission_mode /
      #                  hook_event_name / tool_name / tool_input / tool_use_id / scratchpad_dir
      #       ⇒ ★parent_session_id·team_name·agent_name 모두 부재.★ JSON 만으로는 증명 불가.
      #     - teams/<name>/config.json members 는 agentId·name 으로만 식별되고
      #       ★session_id 가 어디에도 없다★(전수 grep 0건) ⇒ 역추적 불가.
      #     - ★유효한 유일 수단: 프로세스 계보의 argv `--parent-session-id`★
      #       팀에이전트 프로세스는 `--agent-id X@session-Y --parent-session-id <파이프라인UUID>`
      #       로 기동된다(실측). argv 와 PPID 체인은 ★커널 소유★ 라 LLM 이 도구 호출로 위조할 수
      #       없다 — 프롬프트 텍스트보다 강한 증거다. MEMORY 「Agent spawn "성공"은 팀에이전트의
      #       증거가 아니다」도 판별 기준을 `--parent-session-id` 로 못박고 있다(동일 기준 재사용).
      #
      #   fail-closed 유지: 증명에 실패하면 종전대로 ★차단★ 한다. 애매하면 막는다.
      #   비용: 계보 탐색은 ★차단 직전에만★ 수행한다(정상 경로는 종전과 동일 비용).
      _ISO3_TARGET_UUID=$(echo "$_OIO_PATH" | grep -oP 'session-env/\K[^/]+' | head -1)
      if [[ -n "$_ISO3_TARGET_UUID" ]]; then
        _ISO3_SELF_UUID="${PIPELINE_UUID:-}"
        if [[ -z "$_ISO3_SELF_UUID" ]]; then
          _ISO3_SELF_UUID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
        fi
        if [[ -n "$_ISO3_SELF_UUID" && "$_ISO3_TARGET_UUID" != "$_ISO3_SELF_UUID" ]]; then
          # ── 소유권 증명 시도: 조상 프로세스 argv 의 --parent-session-id 가 대상 UUID 와 같은가
          _ISO3_PARENT=""
          _ISO3_P=$$
          _ISO3_I=0
          while [[ -n "$_ISO3_P" && "$_ISO3_P" != "1" && $_ISO3_I -lt 12 ]]; do
            _ISO3_ARGV=$(tr '\0' ' ' < "/proc/${_ISO3_P}/cmdline" 2>/dev/null)
            _ISO3_PARENT=$(printf '%s' "$_ISO3_ARGV" \
              | grep -oP -- '--parent-session-id \K[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
              | head -1)
            [[ -n "$_ISO3_PARENT" ]] && break
            _ISO3_P=$(awk '{print $4}' "/proc/${_ISO3_P}/stat" 2>/dev/null)
            _ISO3_I=$((_ISO3_I + 1))
          done
          if [[ -n "$_ISO3_PARENT" && "$_ISO3_PARENT" == "$_ISO3_TARGET_UUID" ]]; then
            # 증명 성공: 나는 이 파이프라인이 spawn 한 팀에이전트다 → 자기 세션 영역이므로 허용
            exit 0
          fi
          echo "{\"decision\":\"block\",\"reason\":\"🚫 [F-ISO-3] 타 세션 session-env 경로 쓰기 차단 — 세션 격리 불변식 §(a) 위반. 대상 UUID(${_ISO3_TARGET_UUID})가 자기 UUID(${_ISO3_SELF_UUID})와 다릅니다. 팀에이전트라면 조상 프로세스의 --parent-session-id 가 대상 UUID 와 일치해야 하나 증명되지 않았습니다(검출값: ${_ISO3_PARENT:-없음}).\"}"
          exit 2
        fi
      fi
      exit 0  # .claude/ 하위 oio 전역 허용 (session-env는 자기 UUID 한정)
    fi
    # /tmp/ 하위 경로 → 파이프라인 상태 무관 허용 (스크린샷 등 메타 도구)
    # L-NEW-ALLOW: oss 스크린샷, 임시 파일 작업 등 /tmp/ 경유 메타 도구 지원
    if [[ "$_OIO_PATH" == /tmp/* ]]; then
      exit 0
    fi
    # bash_exec: 메인 오케스트레이션 명령 허용 (파이프라인 상태 무관)
    if [[ "$TOOL_NAME" == "mcp__oio__bash_exec" ]]; then
      # (L-303 run_in_background 차단은 case 진입 전 선행 매처에서 전역 처리됨 — F10)
      _BASH_CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")
      # A) .claude/ 또는 session-env 참조 + NTFS 프로젝트 경로(/mnt/[c-z]/) 미참조 + 명령치환 없음 → 오케스트레이션 허용
      # Fix 2 (L-NEW): 체인 명령(&&, ||, ;)은 .claude/ 전용 시 허용 — oinit Step 0 등 조건 체크 명령 지원
      # Fix 2-ext: 명령치환($(...) 또는 백틱)만 차단 — bash ~/.claude/x.sh $(...hidden_ntfs...) 우회 방지 (F-NEW-2)
      # L-NEW-ALLOW: oinit/oi/oresume/ointaug 등 메타 제어 명령은 파이프라인 상태 무관 허용
      if echo "$_BASH_CMD" | grep -qP '(\.claude/|session-env/)'; then
        if ! echo "$_BASH_CMD" | grep -qP '/mnt/[c-z]/'; then
          if ! echo "$_BASH_CMD" | grep -qP '(\$\(|`)'; then
            exit 0  # .claude/ 전용 bash 명령 (체인 포함 허용) → 메인 오케스트레이션 허용
          fi
          # 명령치환 포함 → fall-through (허용 조건 미충족으로 처리)
        fi
      fi
      # B) 읽기 전용 오케스트레이션: tmux 상태 조회 (팀 pane 관리에 필수)
      #    조건: tmux 읽기 명령 존재 + 위험 tmux 없음 + NTFS 프로젝트 경로 없음
      if echo "$_BASH_CMD" | grep -qP 'tmux\s+(list-panes|display-message|list-sessions|list-windows|show-options)'; then
        if ! echo "$_BASH_CMD" | grep -qP 'tmux\s+(kill|send-keys|new-window|split|respawn|swap|move|break|join)'; then
          if ! echo "$_BASH_CMD" | grep -qP '/mnt/[c-z]/'; then
            exit 0  # tmux 읽기 전용 + NTFS 프로젝트 경로 없음 → 메인 오케스트레이션 허용
          fi
        fi
      fi
      # C) 읽기 전용 유틸 명령: 파일시스템 무변경 + NTFS 프로젝트 경로 무접근
      #    date, echo, sleep, wc, test, whoami, hostname, uname, env, printenv
      if echo "$_BASH_CMD" | grep -qP '^(date|echo|sleep|wc|test|whoami|hostname|uname|env|printenv)(\s|$)'; then
        if ! echo "$_BASH_CMD" | grep -qP '/mnt/[c-z]/'; then
          exit 0  # 읽기 전용 유틸 + NTFS 프로젝트 경로 없음 → 허용
        fi
      fi
      # D) /tmp/ 전용 명령 (NTFS 미참조) → 메타 도구 허용 (oss 스크린샷, 임시 파일 처리)
      # L-NEW-ALLOW: /tmp/ 경유 명령은 NTFS 프로젝트 경로 미포함 시 항상 허용
      if echo "$_BASH_CMD" | grep -qP '/tmp/'; then
        if ! echo "$_BASH_CMD" | grep -qP '/mnt/[c-z]/'; then
          exit 0  # /tmp/ 전용 + NTFS 프로젝트 경로 없음 → 메타 도구 허용
        fi
      fi
    fi
    # 메인: 상태 확인
    _UUID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null) || _UUID=""
    if [[ -n "$_UUID" ]]; then
      # Fix 9 (L-NEW): cat 직접 읽기 → state_read(flock) 통일 — race condition 방지
      source "${HARNESS_HOOK_DIR}/lib/session_id.sh" 2>/dev/null || true
      _STATE=$(state_read "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${_UUID}/state" 2>/dev/null | awk '{print $1}') || _STATE=""
    fi
    _STATE="${_STATE:-IDLE}"
    # Fix 9 (L-NEW): __LOCK_FAIL__ 명시 감지 — fail-closed (차단 우선)
    if [[ "$_STATE" == "__LOCK_FAIL__" ]]; then
      echo '{"decision":"block","reason":"❌ [Fix 9/L-NEW] state 파일 lock 경쟁 중 — 안전을 위해 차단 (fail-closed). 잠시 후 재시도하세요."}'
      exit 2
    fi
    # IDLE/FINISH 상태: 메인 직접 수정 허용 (파이프라인 마무리 단계 포함)
    if [[ "$_STATE" == "IDLE" || "$_STATE" == "FINISH" ]]; then
      exit 0
    fi
    # F-OEXIT-1 (L-NEW): oinit/oresume 복구 경로 — session-env/${UUID}/ 하위 정리 허용
    #   (분기명 F-OEXIT-1은 hook 역사성 유지 — 옛 스킬명 oexit(→oclean→oinit)에서 유래. 현재는 oinit이 모든 종료/강제 초기화 담당.)
    # 이유: oinit 정리/IDLE 강제 전이는 PLAN/DEV/TEST/DONE 상태에서 호출되어야 하는데 (Phase B: stage OK 제거됨),
    #       기존 가드는 활성 상태의 메인 직접 file_delete/dir_delete를 무조건 차단 → 무한 락 유발
    # 허용 범위: session-env/${UUID}/ 하위 메타 파일 삭제만 (state 파일 자체는 별도 차단 — F1)
    if [[ "$TOOL_NAME" == "mcp__oio__file_delete" || "$TOOL_NAME" == "mcp__oio__dir_delete" ]]; then
      _OEXIT_PATH=$(echo "$INPUT" | jq -r '.tool_input.path // .tool_input.file_path // empty' 2>/dev/null || echo "")
      _OEXIT_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
      # session-env/${_UUID}/ 하위만 허용 (다른 세션 침범 차단 — 세션 격리 불변식)
      if [[ -n "$_UUID" && -n "$_OEXIT_PATH" ]]; then
        _ALLOWED_PREFIX="${_OEXIT_CONFIG_DIR}/session-env/${_UUID}/"
        if [[ "$_OEXIT_PATH" == "$_ALLOWED_PREFIX"* ]]; then
          # state 파일 자체는 별도 보호 (F1) — file_edit/file_write에서 차단됨, file_delete는 비정상이므로 차단
          if [[ "$_OEXIT_PATH" == "${_ALLOWED_PREFIX}state" ]]; then
            echo '{"decision":"block","reason":"🚫 [F1/F-OEXIT-1] state 파일 직접 삭제 금지 — state_machine.sh 경유 또는 mcp__oio__session_state(force=true) 사용"}'
            exit 2
          fi
          exit 0  # session-env/${UUID}/ 하위 정리 허용 (oinit Step 7 + Step 9)
        fi
      fi
    fi
    # 파이프라인 활성(PLAN/DEV/TEST/DONE) → 메인 차단 (FINISH는 위에서 이미 exit 0)
    # (Phase B: stage OK 제거 — state=OK 잔존 케이스는 위 case 분기에서 PLAN으로 fallback)
    _BLOCKED_INFO=""
    if [[ "$TOOL_NAME" == "mcp__oio__bash_exec" ]]; then
      _BLOCKED_INFO=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null | head -c 80 | tr '"\\' "'/" | tr '\n' ' ' || echo "")
    else
      _BLOCKED_INFO=$(echo "$INPUT" | jq -r '.tool_input.path // empty' 2>/dev/null | tr '"\\' "'/" || echo "")
    fi
    _MAIN_BLOCK_REASON="❌ 파이프라인 활성(${_STATE}) 중 메인 직접 oio 수정 금지! 도구: ${TOOL_NAME} | 대상: ${_BLOCKED_INFO}  | ▶ 대안: SendMessage로 기존 팀에이전트에 위임하거나 새 팀에이전트를 spawn하세요."
    if echo "$_BLOCKED_INFO" | grep -qF '/plans/'; then
      _MAIN_BLOCK_REASON="${_MAIN_BLOCK_REASON} → 산출물은 session-env/${_UUID}/plans/ 에 작성하세요."
    fi
    echo "{\"decision\":\"block\",\"reason\":\"${_MAIN_BLOCK_REASON}\"}"
    exit 2
    ;;
esac

# --- 이하 수정 도구 전용 경로 (set -euo pipefail 적용) ---
set -euo pipefail
trap 'echo "{\"decision\":\"block\",\"reason\":\"❌ write_guard.sh 내부 오류 — Hook CRLF 오염 가능성. 안전을 위해 차단\"}"; exit 2' ERR

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null || echo "unknown")

# --- P0: Edit/Write/NotebookEdit 전면 차단 (UUID 무관 — 최우선) ---
# oio MCP가 모든 파일 작업을 처리하므로 네이티브 도구는 무조건 차단
case "$TOOL_NAME" in
  Edit|Write|Notebookedit)
    FILE_PATH_P0=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || echo "")
    echo "{\"decision\":\"block\",\"reason\":\"🚨 Edit/Write 금지! mcp__oio__file_edit/file_write 사용 (${FILE_PATH_P0})\"}" ; true
    exit 2
    ;;
esac

# --- P1: Bash 파일시스템 변경 명령 차단 (oio 독점 강제) ---
# Edit/Write 차단(P0) 직후, UUID 결정 전에 삽입
# (UUID 무관하게 모든 Bash 파일 변경을 차단)

if [[ "$TOOL_NAME" == "Bash" ]]; then
  BASH_CMD_P1=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")

  _is_whitelisted() {
    local cmd="$1"
    # 체인 명령(&&, ||, ;) → 무조건 거부 (bash_exec가 분리 실행)
    echo "$cmd" | grep -qP '(&&|\|\||;)' && return 1
    # 리다이렉트(> file)가 보호 경로 외이면 거부 (echo > /mnt/c/file 우회 방지)
    if echo "$cmd" | grep -qP '(>|>>)'; then
      echo "$cmd" | grep -qP '(>|>>)\s*/tmp/' && return 0
      echo "$cmd" | grep -qP 'session-env/[^/]+/' && return 0
      # Finding 2 (High) 수정: .claude/ 리다이렉트 체크에 /mnt/ 제외 추가
      #   이전: /\.claude/ 매칭만 → "echo x > $HOME/.claude/../../../mnt/c/DATA/file" 통과
      #   수정: .claude/ 포함 AND /mnt/[c-z]/ 미포함 조건으로 NTFS 경로 우회 차단
      if echo "$cmd" | grep -qP '/\.claude/'; then
        echo "$cmd" | grep -qP '/mnt/[c-z]/' && return 1  # NTFS 경로 리다이렉트 → 차단
        return 0  # .claude/ 전용 리다이렉트 허용
      fi
      return 1  # 비보호 경로 리다이렉트 → bash_exec 필수
    fi
    # session-env 상태 파일 쓰기 (파이프라인 상태 전파 — 리다이렉트 없는 명령도 허용)
    echo "$cmd" | grep -qP 'session-env/[^/]+/(state|classification|team_name|status|skill_direct|reroute_count|pipeline_start_time|entry_tier)' && return 0
    # ~/.claude/ 내부 (인프라 관리 — oio 대상 아님) — NTFS 경로 포함 시 차단
    # Finding 2 (High) 수정: /mnt/[c-z]/ 포함 명령은 .claude/ 일치해도 거부
    if echo "$cmd" | grep -qP '/\.claude/'; then
      echo "$cmd" | grep -qP '/mnt/[c-z]/' && return 1  # NTFS 포함 → 차단
      return 0
    fi
    # 셸 빌트인만 허용 (외부 명령은 모두 bash_exec 경유)
    # Finding 1 (High) 수정: eval/exec/command/builtin 제거 — 임의 명령 실행 우회 가능
    #   eval "rm -rf /mnt/c/..." 패턴이 화이트리스트 통과하여 NTFS 쓰기 가능했음
    #   command/builtin도 제거 — 외부 명령 래퍼로 우회 가능
    echo "$cmd" | grep -qP '^\s*(echo|printf|test|true|false|exit|return|export|unset|set|shopt|alias|hash|declare|local|readonly|trap|wait|jobs|bg|fg)\s' && return 0
    return 1
  }

  _has_fs_mutation() {
    local cmd="$1"
    # 디렉토리 조작: mkdir, rmdir
    echo "$cmd" | grep -qP '\b(mkdir|rmdir)\b' && return 0
    # 파일 삭제: rm (rm -f, rm -rf 등)
    echo "$cmd" | grep -qP '\brm\s+(-\S+\s+)*[^|&;]' && return 0
    # 파일/디렉토리 이동/복사: mv, cp
    echo "$cmd" | grep -qP '\b(mv|cp)\s+(-\S+\s+)*\S+\s+\S+' && return 0
    # 파일 생성/수정: touch, truncate
    echo "$cmd" | grep -qP '\b(touch|truncate)\b' && return 0
    # 리다이렉트 쓰기: > file, >> file (단, /tmp/ 및 session-env 제외 — 화이트리스트)
    echo "$cmd" | grep -qP '(^|[;&|])\s*[^#]*\s+>\s*[^/]' && return 0
    echo "$cmd" | grep -qP '>\s*/mnt/' && return 0
    echo "$cmd" | grep -qP '>\s*/home/[^/]+/(?!\.claude/)' && return 0
    # in-place 편집: sed -i, perl -i
    echo "$cmd" | grep -qP '\b(sed|perl)\s+.*-i\b' && return 0
    # tee (쓰기)
    echo "$cmd" | grep -qP '\btee\s+(-a\s+)?\S+' && return 0
    # rsync (파일 동기화/쓰기)
    echo "$cmd" | grep -qP '\brsync\b' && return 0
    # dd (블록 쓰기: dd of=file)
    echo "$cmd" | grep -qP '\bdd\b' && return 0
    # ln (링크 생성)
    echo "$cmd" | grep -qP '\bln\s' && return 0
    # patch (파일 수정)
    echo "$cmd" | grep -qP '\bpatch\b' && return 0
    # install (파일 복사+권한)
    echo "$cmd" | grep -qP '\binstall\s' && return 0
    return 1
  }

  # --- F1: state 파일 직접 쓰기 차단 (state_machine.sh 경유 강제) ---
  # session-env/*/state 파일에 대한 모든 직접 쓰기(echo>, printf>, >, tee, sed -i 등)를 차단.
  # 우회 수단: state_machine.sh의 state_transition() 함수 경유 (CAS + flock + checkpoint).
  # state_machine.sh/session_id.sh의 state_write는 source된 함수 호출이므로 Bash 매처가 아닌 bash_exec 내부 실행 → write_guard는 통과.
  if echo "$BASH_CMD_P1" | grep -qP 'session-env/[^/]+/state\b' && \
     echo "$BASH_CMD_P1" | grep -qP '(>\s*["'\'']?[^|&<]*session-env/[^/]+/state|tee\s+.*session-env/[^/]+/state|sed\s+.*-i.*session-env/[^/]+/state|mv\s+[^|]*session-env/[^/]+/state|cp\s+[^|]*session-env/[^/]+/state)'; then
    echo '{"decision":"block","reason":"🚨 [F1] state 파일 직접 쓰기 금지 — state_machine.sh의 state_transition() 경유 필수 (CAS + flock + checkpoint)."}' ; true
    exit 2
  fi

  # --- P1-A: 파일 I/O 명령 차단 (체인 인식 — &&/||/; 뒤 명령도 검사) ---
  # 체인 프리픽스: 줄 시작 또는 &&/||/; 뒤
  _CP='(^|\s*&&\s*|\s*\|\|\s*|\s*;\s*)'
  # 쓰기 도구
  _FILE_WRITE_CMDS='(touch|dd|patch|truncate|install|tee|nano|vi|vim)'
  if echo "$BASH_CMD_P1" | grep -qP "${_CP}${_FILE_WRITE_CMDS}(\s|$)"; then
    echo '{"decision":"block","reason":"🚨 Bash 파일쓰기 금지→oio"}' ; true
    exit 2
  fi
  # 디렉토리 생성/삭제 → oio 전용 도구 (P1-A에서 whitelist 도달 전 차단)
  if echo "$BASH_CMD_P1" | grep -qP "${_CP}mkdir(\s|$)"; then
    echo '{"decision":"block","reason":"🚨 Bash mkdir→oio dir_create"}' ; true
    exit 2
  fi
  if echo "$BASH_CMD_P1" | grep -qP "${_CP}rmdir(\s|$)"; then
    echo '{"decision":"block","reason":"🚨 Bash rmdir→oio dir_delete"}' ; true
    exit 2
  fi
  if echo "$BASH_CMD_P1" | grep -qP "${_CP}rm(\s|$)"; then
    echo '{"decision":"block","reason":"🚨 Bash rm→oio file_delete/dir_delete"}' ; true
    exit 2
  fi
  if echo "$BASH_CMD_P1" | grep -qP "${_CP}(mv|cp)(\s|$)"; then
    echo '{"decision":"block","reason":"🚨 Bash mv/cp→oio file_move/file_copy"}' ; true
    exit 2
  fi
  # sed/perl: -i 플래그 → 쓰기, 없으면 → 읽기
  if echo "$BASH_CMD_P1" | grep -qP "${_CP}(sed|perl)(\s|$)"; then
    if echo "$BASH_CMD_P1" | grep -qP '\b(sed|perl)\s+.*-i\b'; then
      echo '{"decision":"block","reason":"🚨 sed -i→oio file_edit"}' ; true
    else
      echo '{"decision":"block","reason":"🚨 sed/perl→oio bash_exec"}' ; true
    fi
    exit 2
  fi
  # 읽기/검색 도구
  _FILE_READ_CMDS='(cat|head|tail|tac|less|more|nl|xxd|od|strings|rev|fold|fmt|column|paste|comm|base64)'
  if echo "$BASH_CMD_P1" | grep -qP "${_CP}${_FILE_READ_CMDS}(\s|$)"; then
    # 파일 쓰기 리다이렉션만 매칭 (fd/stderr 리다이렉션 제외):
    #   매칭 O: `> file`, `>> file`, `<<EOF` (heredoc)
    #   매칭 X: `2>/dev/null`, `2>&1`, `&>`, `1>&2`, `3>`, `<<<` (here-string)
    # 앞에 숫자 fd나 '&'가 없고, 뒤에 '&'(fd 복사)가 아닌 '>' 만 실제 파일 쓰기로 간주
    if echo "$BASH_CMD_P1" | grep -qP '(^|[^0-9&])>{1,2}(?!&)|(?<!<)<<(?!<)'; then
      echo '{"decision":"block","reason":"🚨 Bash write→oio file_write"}' ; true
    else
      echo '{"decision":"block","reason":"🚨 Bash cat→oio file_read"}' ; true
    fi
    exit 2
  fi
  # 검색/패턴 도구 → Grep 도구 사용
  _FILE_SEARCH_CMDS='(grep|egrep|fgrep|rg|ag)'
  if echo "$BASH_CMD_P1" | grep -qP "${_CP}${_FILE_SEARCH_CMDS}(\s|$)"; then
    echo '{"decision":"block","reason":"🚨 Bash grep→Grep도구/oio bash_exec"}' ; true
    exit 2
  fi
  # 텍스트 처리 도구 (파일 인자 접근)
  _FILE_PROC_CMDS='(awk|gawk|mawk|sort|cut|uniq|tr|wc)'
  if echo "$BASH_CMD_P1" | grep -qP "${_CP}${_FILE_PROC_CMDS}(\s|$)"; then
    echo '{"decision":"block","reason":"🚨 Bash awk/sort→oio bash_exec"}' ; true
    exit 2
  fi
  # 파일 비교/검증
  _FILE_CMP_CMDS='(diff|cmp|md5sum|sha256sum|sha1sum|sha512sum|cksum)'
  if echo "$BASH_CMD_P1" | grep -qP "${_CP}${_FILE_CMP_CMDS}(\s|$)"; then
    echo '{"decision":"block","reason":"🚨 Bash diff/md5→oio bash_exec"}' ; true
    exit 2
  fi

  # ls → mcp__oio__list_dir 내재화 (2026-03-31 /oio 일괄 내재화)
  if echo "$BASH_CMD_P1" | grep -qP "${_CP}ls(\s|$)"; then
    echo '{"decision":"block","reason":"🚨 Bash ls→oio list_dir"}' ; true
    exit 2
  fi
  # stat/file → mcp__oio__file_info 내재화 (2026-03-31 /oio 일괄 내재화)
  if echo "$BASH_CMD_P1" | grep -qP "${_CP}(stat|file)(\s|$)"; then
    echo '{"decision":"block","reason":"🚨 Bash stat→oio file_info"}' ; true
    exit 2
  fi
  # rename → mcp__oio__file_rename / dir_rename 내재화 (2026-03-31 /oio 일괄 내재화)
  if echo "$BASH_CMD_P1" | grep -qP "${_CP}rename(\s|$)"; then
    echo '{"decision":"block","reason":"🚨 Bash rename→oio file_rename"}' ; true
    exit 2
  fi

  # bash → oio bash_exec 강제 (2026-03-31 /oio bash)
  if echo "$BASH_CMD_P1" | grep -qP "${_CP}bash(\s|$)"; then
    echo '{"decision":"block","reason":"🚨 Bash bash→oio bash_exec"}' ; true
    exit 2
  fi

  # git → oio bash_exec 강제 (2026-03-30 /oio git)
  if echo "$BASH_CMD_P1" | grep -qP "${_CP}git(\s|$)"; then
    echo '{"decision":"block","reason":"🚨 Bash git→oio bash_exec"}' ; true
    exit 2
  fi

  # find 명령 차단 — mcp__oio__find 사용 강제
  if echo "$BASH_CMD_P1" | grep -qP "${_CP}find(\s|$)"; then
    echo '{"decision":"block","reason":"🚨 Bash find→Glob/oio list_dir"}'
    exit 2
  fi

  # dotnet / cmd.exe → oio bash_exec 강제
  if echo "$BASH_CMD_P1" | grep -qP "${_CP}dotnet(\s|$)"; then
    echo '{"decision":"block","reason":"🚨 Bash dotnet→oio bash_exec"}' ; true
    exit 2
  fi
  if echo "$BASH_CMD_P1" | grep -qP "${_CP}cmd\.exe(\s|$)"; then
    echo '{"decision":"block","reason":"🚨 Bash cmd.exe→oio bash_exec"}' ; true
    exit 2
  fi

  # python3/python → oio bash_exec 강제 (2026-03-31 /oio python3)
  if echo "$BASH_CMD_P1" | grep -qP "${_CP}python[23]?(\s|$)"; then
    echo '{"decision":"block","reason":"🚨 Bash python→oio bash_exec"}' ; true
    exit 2
  fi

  # tmux → oio bash_exec 강제 (2026-04-01 오케스트레이션 교착 방지)
  if echo "$BASH_CMD_P1" | grep -qP "${_CP}tmux(\s|$)"; then
    echo '{"decision":"block","reason":"🚨 Bash tmux→oio bash_exec"}' ; true
    exit 2
  fi

  # source/. → oio bash_exec 강제 (2026-04-01 /oio source)
  if echo "$BASH_CMD_P1" | grep -qP "${_CP}(source|\.)\s+"; then
    echo '{"decision":"block","reason":"🚨 Bash source→oio bash_exec"}' ; true
    exit 2
  fi

  if ! _is_whitelisted "$BASH_CMD_P1"; then
    # P1-B: fs mutation은 구체적 oio 도구 안내
    if _has_fs_mutation "$BASH_CMD_P1"; then
      SUGGESTION="oio 도구를 사용하세요:"
      echo "$BASH_CMD_P1" | grep -qP '\bmkdir\b' && SUGGESTION="$SUGGESTION mcp__oio__dir_create"
      echo "$BASH_CMD_P1" | grep -qP '\brmdir\b' && SUGGESTION="$SUGGESTION mcp__oio__dir_delete"
      echo "$BASH_CMD_P1" | grep -qP '\brm\b' && SUGGESTION="$SUGGESTION mcp__oio__file_delete / dir_delete(recursive=true)"
      echo "$BASH_CMD_P1" | grep -qP '\bmv\b' && SUGGESTION="$SUGGESTION mcp__oio__file_move / dir_move"
      echo "$BASH_CMD_P1" | grep -qP '\bcp\b' && SUGGESTION="$SUGGESTION mcp__oio__file_copy"
      echo "$BASH_CMD_P1" | grep -qP '\btouch\b' && SUGGESTION="$SUGGESTION mcp__oio__file_write"
      echo "$BASH_CMD_P1" | grep -qP '(sed|perl).*-i' && SUGGESTION="$SUGGESTION mcp__oio__file_edit"
      echo "$BASH_CMD_P1" | grep -qP '(>|>>|tee)' && SUGGESTION="$SUGGESTION mcp__oio__file_write / file_edit"
      echo "$BASH_CMD_P1" | grep -qP '\bln\b' && SUGGESTION="$SUGGESTION mcp__oio__file_symlink"
      echo "$BASH_CMD_P1" | grep -qP '\brsync\b' && SUGGESTION="$SUGGESTION mcp__oio__file_write / file_edit (rsync 불필요 — oio가 직접 처리)"
      echo "$BASH_CMD_P1" | grep -qP '\bcat\b.*<<' && SUGGESTION="$SUGGESTION mcp__oio__file_write (heredoc → file_write content 파라미터 사용)"

      echo "{\"decision\":\"block\",\"reason\":\"🚨 Bash FS변경→oio ($SUGGESTION)\"}" ; true
      exit 2
    fi
    # P1-Z: catch-all — 화이트리스트 미통과 + P1-A/B 미매칭 → bash_exec 강제
    echo '{"decision":"block","reason":"🚨 Bash→oio bash_exec"}' ; true
    exit 2
  fi
fi

# --- UUID 결정 ---
source "${HARNESS_HOOK_DIR}/lib/session_id.sh"
if ! resolve_uuid "$INPUT" 2>/dev/null; then
  # UUID 결정 불가 시 안전 통과 (세션 연결 전 도구 호출 등 edge case)
  exit 0
fi
[[ -z "$UUID" ]] && exit 0
# P8: PIPELINE_UUID 환경에서 MY_UUID 미설정 보완 — resolve_uuid가 PIPELINE_UUID 브랜치에서 MY_UUID를 설정하지 않으므로
# session_id JSON 필드에서 직접 추출하여 MY_UUID 보장
if [[ -z "${MY_UUID:-}" ]]; then
  _RAW_SID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null | tr -d '[:space:]')
  if [[ -n "$_RAW_SID" ]]; then
    MY_UUID="$_RAW_SID"
    export MY_UUID
  fi
fi

# --- 헬퍼: 방안C 메인 세션 판별 (session_id vs state UUID 비교) ---
# state 파일에 기록된 UUID와 현재 세션 UUID 비교하여 메인 여부 판별
# 팀에이전트는 session_id가 state 소유자(메인)와 다르므로 false 반환
_is_main_by_state_sid() {
  local _STATE_FILE="${1:-}"
  if [[ -z "$_STATE_FILE" || ! -f "$_STATE_FILE" ]]; then
    # 2차 판별: 자기 UUID 디렉토리에 state 파일도 없으면 서브에이전트 (L-269)
    if [[ ! -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${MY_UUID}/state" ]]; then
      return 1  # 서브에이전트 확정 → 수정 허용
    fi
    return 0  # 판별 불가 → 메인 간주
  fi
  local _STATE_SID
  _STATE_SID=$(awk '{print $2}' "$_STATE_FILE" 2>/dev/null | tr -d '\r' || echo "")
  local _RAW_SESSION="$MY_UUID"
  # UUID가 비어있으면 추가 판별
  if [[ -z "$_RAW_SESSION" ]]; then return 0; fi  # UUID 결정 실패 → fail-closed (메인 간주, 차단 우선)
  if [[ -z "$_STATE_SID" ]]; then
    # state 파일에 UUID 미기록 → MY_UUID 디렉토리가 state 파일 소유자인지 확인
    # state 파일이 session-env/${MY_UUID}/state가 아니면 → 팀에이전트
    local _MY_STATE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${MY_UUID}/state"
    if [[ "$_STATE_FILE" != "$_MY_STATE" ]]; then
      return 1  # 팀에이전트 (state 파일 소유자 ≠ 나)
    fi
    return 0  # state 파일이 내 디렉토리 → 메인 간주
  fi
  # full UUID 매칭: 같으면 메인(0), 다르면 팀에이전트(1)
  if [[ "$_RAW_SESSION" == "$_STATE_SID"* ]] || [[ "$_STATE_SID" == "$_RAW_SESSION"* ]]; then
    return 0  # 메인
  fi
  return 1  # 팀에이전트
}

# --- P4: PIPELINE_UUID 환경변수 기반 팀에이전트 우회 ---
# 팀에이전트 프롬프트에 PIPELINE_UUID={UUID}가 주입되면 환경변수로 전파됨
# PIPELINE_UUID가 있고 현재 세션과 다르면 → 팀에이전트 확정 → 수정 허용
if [[ -n "${PIPELINE_UUID:-}" && "${PIPELINE_UUID:-}" != "$MY_UUID" ]]; then
  # PIPELINE_UUID가 존재하고 내 UUID와 다름 → 팀에이전트 확정
  UUID="$PIPELINE_UUID"
  SID="$UUID"  # 하위 호환
  export UUID SID
  # 탐색 도구는 상단 조기 통과에서 이미 처리됨 → 여기는 수정 도구만 도달
  # 팀에이전트도 NTFS 직접 수정은 차단 (L-014)
  # path 파라미터 보강: mcp__oio__file_write/file_edit 등의 실제 파라미터명은 path이며
  # file_path만 읽으면 이 블록을 우회할 수 있었다(실측 확인) — F-ISO-2와 동일 관용구로 통일.
  FILE_PATH_TEAM=$(echo "$INPUT" | jq -r '.tool_input.path // .tool_input.file_path // .tool_input.filepath // empty' 2>/dev/null || echo "")
  # Fix 3 (L-NEW): Serena relative_path도 NTFS 경로 체크 (file_path 체크만으론 우회 가능)
  _REL_PATH_TEAM=$(echo "$INPUT" | jq -r '.tool_input.relative_path // empty' 2>/dev/null || echo "")
  if echo "$FILE_PATH_TEAM" | grep -qP '^/mnt/[c-z]/' || \
     echo "$_REL_PATH_TEAM" | grep -qP '^/mnt/[c-z]/'; then
    source "${HARNESS_HOOK_DIR}/lib/write_error.sh"
    _BLOCKED_PATH="${FILE_PATH_TEAM:-$_REL_PATH_TEAM}"
    log_hook_error "HOOK_BLOCK_NTFS_DIRECT" "$TOOL_NAME" "팀에이전트 NTFS 직접 수정 시도($_BLOCKED_PATH)" "$SESSION_ID"
    _NTFS_REASON="🚨 NTFS 직접 수정 금지! 팀에이전트도 rsync 방식 필수 (L-014)."
    if echo "$_BLOCKED_PATH" | grep -qF '/plans/'; then
      _NTFS_REASON="${_NTFS_REASON} → 산출물은 session-env/${PIPELINE_UUID:-UUID}/plans/ 에 작성하세요."
    fi
    echo "{\"decision\":\"block\",\"reason\":\"${_NTFS_REASON}\"}" ; true
    exit 2
  fi
  exit 0  # NTFS 아니면 허용
fi

# (탐색 도구 분기는 상단 조기 통과로 이동됨 — Grep/Glob/Serena 탐색은 여기 도달 불가)

# ===== 수정 도구 분기 (ok_check + ok_full_edit_guard + team_dir_guard 기능) =====

# --- 0. .claude/ 하위 경로 전역 허용 (파이프라인/에이전트 무관) ---
# .claude/ 하위는 파이프라인 상태, 메인/팀에이전트 구분 없이 항상 oio 허용
# teams/ rm -rf 보호(아래 1번)만 예외로 별도 차단
# F-NEW-1: symlink traversal 방어 — .claude/ 경로라도 NTFS 가리키면 차단
if [[ "$TOOL_NAME" == mcp__oio__* ]]; then
  _CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  _OIO_PATH=$(echo "$INPUT" | jq -r '.tool_input.path // empty' 2>/dev/null || echo "")
  # F-NEW-1-EXC (2026-08-01): CLAUDE_CONFIG_DIR가 세션 임시 디렉토리(/tmp/cc-*)인 구성에서
  # projects/*/memory/ 하위(MEMORY.md 등 자동메모리)는 정당한 NTFS symlink이므로 예외 허용
  if [[ "$_OIO_PATH" == "$_CLAUDE_DIR"/*/memory/*.md ]]; then
    exit 0
  fi
  if [[ "$_OIO_PATH" == "$_CLAUDE_DIR"/* || "$_OIO_PATH" == /home/*/.claude/* ]]; then
    _RESOLVED_PATH2=$(realpath -m "$_OIO_PATH" 2>/dev/null || echo "$_OIO_PATH")
    if echo "$_RESOLVED_PATH2" | grep -qP '^/mnt/[c-z]/'; then
      echo '{"decision":"block","reason":"🚫 [F-NEW-1] .claude/ 심볼릭링크가 NTFS 경로를 가리킵니다 — symlink traversal 차단 (P4 이후 섹션)."}'
      exit 2
    fi
    # F-ISO-1 (세션 격리 §(a) 강화): session-env/<UUID>/ 세그먼트가 있으면 그 UUID가
    # 자기 UUID(MY_UUID)일 때만 통과. session-env 아닌 공용 .claude/ 경로는 종전대로 허용.
    # base(CLAUDE_CONFIG_DIR/HOME) 무관하게 경로 문자열의 session-env/<UUID>/ 세그먼트만 본다.
    _ISO_TARGET_UUID=$(echo "$_OIO_PATH" | grep -oP 'session-env/\K[^/]+' | head -1)
    if [[ -n "$_ISO_TARGET_UUID" && -n "${MY_UUID:-}" && "$_ISO_TARGET_UUID" != "$MY_UUID" ]]; then
      echo "{\"decision\":\"block\",\"reason\":\"🚫 [F-ISO-1] 타 세션 session-env 경로 쓰기 차단 — 세션 격리 불변식 §(a) 위반. 대상 UUID(${_ISO_TARGET_UUID})가 자기 UUID(${MY_UUID:-미상})와 다릅니다.\"}"
      exit 2
    fi
    exit 0  # .claude/ 하위 oio 전역 허용 (session-env는 자기 UUID 한정)
  fi
fi

# --- 1. ~/.claude/teams/ 보호 (team_dir_guard 기능 흡수) ---
COMMAND_CHECK=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")
# Bash 도구는 이 matcher에 걸리지 않으나 안전장치로 검사
if [[ -n "$COMMAND_CHECK" ]]; then
  if echo "$COMMAND_CHECK" | tr ';' '\n' | grep -vE '^\s*(#|echo\s|printf\s|grep\s|cat\s|read\s)' | grep -qP '\brm\s+(-\S+\s+)*\S*\.claude/(teams|tasks)/'; then
    STATE_WORD=$(state_read "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/state" | awk '{print $1}')  # C-01: flock 보호
    STATE_WORD=${STATE_WORD:-IDLE}
    # Fix 10 (L-NEW): __LOCK_FAIL__ → fail-closed (비IDLE 간주하여 차단)
    [[ "$STATE_WORD" == "__LOCK_FAIL__" ]] && STATE_WORD="ACTIVE_UNKNOWN"
    if [[ "$STATE_WORD" != "IDLE" ]]; then
      source "${HARNESS_HOOK_DIR}/lib/write_error.sh"
      log_hook_error "HOOK_BLOCK_TEAM_DIR_RM" "Bash" "L-138: 팀/태스크 디렉토리 rm -rf 시도 (state=${STATE_WORD})" "$SESSION_ID"
      echo "{\"decision\":\"block\",\"reason\":\"팀/태스크 디렉토리 rm -rf 차단 (L-138). state=${STATE_WORD} (IDLE 아님). ofinish에서는 TeamDelete를 사용하세요.\"}" ; true
      exit 2
    fi
  fi
fi

# --- 2. 파이프라인 활성 상태 판단 ---
STATE_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/state"
PIPELINE_STATE="IDLE"
SESSION_STATE=$(state_read "$STATE_FILE" | awk '{print $1}')  # C-01: flock 보호
SESSION_STATE=${SESSION_STATE:-IDLE}
# Fix 10 개선 (L-NEW): __LOCK_FAIL__ 재시도 → 3회 실패 시 IDLE fallback (OK 강제 금지)
# 이유: lock 파일 잔류로 flock 타임아웃 발생 시 OK 강제 전환이 전체 oio 도구를 영구 차단하는 버그 (2026-04-15)
# 변경: fail-closed(OK) → 재시도 3회 후 fail-open(IDLE)으로 전환
if [[ "$SESSION_STATE" == "__LOCK_FAIL__" ]]; then
  _RETRY=0
  while [[ "$SESSION_STATE" == "__LOCK_FAIL__" && "$_RETRY" -lt 3 ]]; do
    sleep 0.3
    SESSION_STATE=$(state_read "$STATE_FILE" | awk '{print $1}')
    SESSION_STATE=${SESSION_STATE:-IDLE}
    (( _RETRY++ )) || true
  done
  # 3회 재시도 후에도 LOCK_FAIL → IDLE fallback (OK 강제 금지)
  if [[ "$SESSION_STATE" == "__LOCK_FAIL__" ]]; then
    SESSION_STATE="IDLE"
  fi
fi

case "$SESSION_STATE" in
  PLAN|DEV|TEST)
    # Phase B (L-431): stage OK 제거 — PLAN+classification=OK가 ok 진입 단계 표현
    PIPELINE_STATE="$SESSION_STATE"
    ;;
  OK)
    # Phase B 호환성 fallback: state=OK 잔존 시 PLAN과 동일 처리 (회귀 보호)
    # 다른 활성 세션이 마이그레이션 전 상태로 남아 있을 경우의 안전망
    PIPELINE_STATE="PLAN"
    ;;
  DONE|FINISH)
    PIPELINE_STATE="$SESSION_STATE"
    ;;
  EARLY_TERM|ERROR)
    # Finding 4 (L-NEW): EARLY_TERM/ERROR는 의도적으로 IDLE로 fall-through
    # → 복구 경로에서 메인이 직접 상태 파일 접근 가능 (팀에이전트 미할당 상태)
    # PIPELINE_STATE는 IDLE 유지 (변경 없음)
    ;;
  # IDLE은 파이프라인 비활성 (PIPELINE_STATE=IDLE 유지)
esac

if [[ "$PIPELINE_STATE" != "IDLE" ]]; then
  # --- F-ESCAPE-1 (L-971): 계약·마커 "생성" 경로는 어느 상태에서도 통과한다 ---
  # 배경 (2026-09-06 사이클87 실사고):
  #   ok 로딩 직후 state=PLAN + classification=OK 가 되자 아래 L-171 차단이 메인의 쓰기를
  #   전면 봉쇄했다. 그런데 그 차단을 푸는 데 필요한 것이 바로 evidence/ok_started 마커였다.
  #   ⇒ 게이트가 요구하는 증거를, 그 게이트가 막은 수단으로만 만들 수 있는 ★닫힌 고리★.
  #   결과: 마커를 못 써 Stop.sh 가 PLAN→IDLE 로 롤백(11:51:55).
  # 원칙: 게이트는 "자기가 요구하는 증거의 생성 수단"을 절대 막아서는 안 된다.
  #   L-969("탈출로를 먼저 확보하고 가드를 걸어라")의 같은 형태 재발이다.
  # 범위: 자기 세션 session-env/<UUID>/ 하위의 evidence·work·logs·plans + goal.json 만.
  #   ★state/classification/team_name/status/entry_tier 메타 파일은 제외★ —
  #   그건 line 897 Fix 3 이 담당하며 session_state/state_machine.sh 경유가 정본이다.
  #   NTFS(/mnt/[c-z]/) 경로는 심볼릭 우회 방지를 위해 예외에서 제외한다.
  _ESC_PATH=$(echo "$INPUT" | jq -r '.tool_input.path // .tool_input.file_path // .tool_input.filepath // empty' 2>/dev/null || echo "")
  if [[ -n "$_ESC_PATH" && -n "${UUID:-}" ]]; then
    if ! echo "$_ESC_PATH" | grep -qP '/mnt/[c-z]/'; then
      if echo "$_ESC_PATH" | grep -qP "session-env/${UUID}/(evidence|work|logs|plans)/|session-env/${UUID}/goal\.json$"; then
        exit 0
      fi
    fi
  fi

  # L-171: 메인(팀 리더) 세션에서 직접 Edit/Write 차단
  # (Bash 허용 블록 제거: P1에서 이미 전면 차단되므로 도달 불가 — 죽은 코드)
  # state가 IDLE이 아니면 메인 직접 수정 전면 차단
  if _is_main_by_state_sid "$STATE_FILE"; then
    source "${HARNESS_HOOK_DIR}/lib/write_error.sh"
    log_hook_error "HOOK_BLOCK_MAIN_DIRECT_EDIT" "$TOOL_NAME" "L-171: 파이프라인 활성(${PIPELINE_STATE}) 중 메인 직접 수정 시도" "$SESSION_ID"
    echo '{"decision":"block","reason":"❌ [L-171] 파이프라인 활성 중 — 메인 직접 파일 수정 금지! 팀에이전트에 위임하세요."}' ; true
    exit 2
  fi

  # ok 에이전트 직접 수정 차단 (ok_full_edit_guard 기능 — 안전장치)
  # classification 값: v4.3 기준 O1~O5 (구 medium/full 폐기)
  AGENT_NAME=$(echo "$INPUT" | jq -r '.agent_name // empty' 2>/dev/null || echo "")
  if echo "$AGENT_NAME" | grep -qi "^ok"; then
    CLASSIFICATION=$(cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/classification" 2>/dev/null || echo "")
    if [[ "$CLASSIFICATION" =~ ^O[345]$ ]]; then
      source "${HARNESS_HOOK_DIR}/lib/write_error.sh"
      log_hook_error "HOOK_BLOCK_OK_DIRECT_EDIT" "$TOOL_NAME" "ok가 ${CLASSIFICATION} 스케일에서 직접 $TOOL_NAME 호출 (agent: $AGENT_NAME)" "$SESSION_ID"
      echo "{\"decision\":\"block\",\"reason\":\"❌ ok 에이전트 직접 수정 금지: O3/O4/O5 스케일 작업입니다. 팀에이전트(odev)에 위임하세요. (v4.3: ok는 스킬이므로 이 차단은 안전장치)\"}" ; true
      exit 2
    fi
  fi

  # 파이프라인 활성 + 팀에이전트 → 허용
  :
fi

# --- 3. Edit/Write 전면 차단 — oio MCP 사용 강제 (L-292) ---
# oio MCP가 NTFS rsync, Lock, BOM/CRLF를 모두 내부 처리하므로
# Claude Code 네이티브 Edit/Write/Notebookedit는 모든 경로에서 차단
case "$TOOL_NAME" in
  Edit|Write|Notebookedit)
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || echo "")
    source "${HARNESS_HOOK_DIR}/lib/write_error.sh"
    log_hook_error "HOOK_BLOCK_EDIT_WRITE_ALL" "$TOOL_NAME" "Edit/Write 전면 차단 → oio 사용 필수 ($FILE_PATH)" "$SESSION_ID"
    echo '{"decision":"block","reason":"🚨 Edit/Write→oio file_edit/file_write"}' ; true
    exit 2
    ;;
esac

# --- 4. 팀에이전트 위임 강제 (v4.3: O3/O4/O5 = 팀에이전트 필수) ---
# classification 값: v4.3 기준 O1~O5 (구 medium/full 폐기)
CLASSIFICATION=$(cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/classification" 2>/dev/null || echo "unknown")
if [[ "$CLASSIFICATION" =~ ^O[345]$ ]]; then
  if [[ ! -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/team_name" ]]; then
    source "${HARNESS_HOOK_DIR}/lib/write_error.sh"
    log_hook_error "HOOK_BLOCK_NO_AGENT" "$TOOL_NAME" "${CLASSIFICATION} 작업에서 팀에이전트 미생성 상태로 메인 직접 수정 시도" "$SESSION_ID"
    echo "{\"decision\":\"block\",\"reason\":\"❌ ${CLASSIFICATION} 작업은 팀에이전트 위임 필수! TeamCreate 먼저 실행하세요. 메인이 직접 Edit/Write 금지.\"}" ; true
    exit 2
  fi
fi

exit 0
