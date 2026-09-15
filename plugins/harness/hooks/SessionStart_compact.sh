#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# Notification(Start) — compact 완료 후 체크포인트 복원 (Phase 2 — L-111/L-112)
# stdout이 system-reminder로 모델에게 전달됨

# ── UUID 결정 (세션 격리 v4) ──
trap 'exit 0' ERR
INPUT=$(timeout 5 cat 2>/dev/null) || INPUT=""
MY_SID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
[[ -z "$MY_SID" ]] && exit 0
MY_UUID="$MY_SID"
[[ -z "$MY_UUID" ]] && exit 0

# PIPELINE_UUID 환경변수 기반 메인/팀 판별
if [[ -n "${PIPELINE_UUID:-}" && "${PIPELINE_UUID:-}" != "$MY_UUID" ]]; then
  IS_TEAM="true"
  UUID="${PIPELINE_UUID}"
else
  IS_TEAM="false"
  UUID="$MY_UUID"
fi
SID="$UUID"
export SID UUID
SESSION_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}"

# 사이클46 축① — 반대편 base 미러 (compact 복원분이 한쪽에만 남지 않도록)
source "${HARNESS_HOOK_DIR}/lib/session_mirror.sh" 2>/dev/null
type _mirror_file >/dev/null 2>&1 || _mirror_file() { :; }
# 사이클46 삭제 미러 — 원본 삭제 시 반대편 잔존(S-1) 방지
type _mirror_delete >/dev/null 2>&1 || _mirror_delete() { :; }

# state_read/state_write 함수 로드 (flock 기반 원자적 읽기/쓰기)
# shellcheck source=/dev/null
source "${HARNESS_HOOK_DIR}/lib/session_id.sh" 2>/dev/null || true

# ── 체크포인트 파일 결정 ──
if [[ "$IS_TEAM" = "true" ]]; then
  SAVE_FILE="${SESSION_DIR}/compact/state_${MY_UUID}.txt"
else
  SAVE_FILE="${SESSION_DIR}/compact/state.txt"
fi

# ── 저장 상태 복원 ──
if [[ -f "$SAVE_FILE" ]]; then
  SAVED_STATE=$(grep "pipeline_state=" "$SAVE_FILE" 2>/dev/null | cut -d= -f2)

  # 활성 팀에이전트 감지 (state + reroute_count 스킵 판단에 공용)
  ACTIVE_COUNT=0
  if [ -d "${SESSION_DIR}/agents" ]; then
    for AGENT_FILE in "${SESSION_DIR}/agents"/*; do
      [ -f "$AGENT_FILE" ] || continue
      AGENT_NAME=$(basename "$AGENT_FILE")
      [ "$AGENT_NAME" = "team-lead" ] && continue
      if ! grep -q "shutdown_sent=true" "$AGENT_FILE" 2>/dev/null; then
        MPANE=$(grep "pane_id=" "$AGENT_FILE" 2>/dev/null | cut -d= -f2)
        if [[ -n "$MPANE" ]] && tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qF "$MPANE"; then  # H-01
          ACTIVE_COUNT=$((ACTIVE_COUNT + 1))
        fi
      fi
    done
  fi

  # state 복원 — 활성 에이전트 없을 때만 (L-232)
  if [[ -n "$SAVED_STATE" ]]; then
    if [[ "$ACTIVE_COUNT" -gt 0 ]]; then
      echo "⚠️ [compact_restore] 활성 팀에이전트 ${ACTIVE_COUNT}개 — state/reroute 복원 스킵 (L-232)"
    else
      state_write "${SESSION_DIR}/state" "$SAVED_STATE"
    fi
  fi

  # classification 복원 — 항상 수행 (메인 전용 불변 값, write_guard.sh 판별에 필요)
  SAVED_CLASS=$(grep "task_classification=" "$SAVE_FILE" 2>/dev/null | cut -d= -f2)
  if [[ -n "$SAVED_CLASS" && "$SAVED_CLASS" != "unknown" ]]; then
    echo "$SAVED_CLASS" > "${SESSION_DIR}/classification"
    _mirror_file "${SESSION_DIR}/classification"
  fi

  # team_name 복원 — 실제 값 복원 (L-278)
  if grep -q "team_created=true" "$SAVE_FILE"; then
    SAVED_TEAM_NAME=$(grep "team_name_value=" "$SAVE_FILE" 2>/dev/null | cut -d= -f2)
    if [[ ! -f "${SESSION_DIR}/team_name" ]]; then
      if [[ -n "$SAVED_TEAM_NAME" ]]; then
        echo "$SAVED_TEAM_NAME" > "${SESSION_DIR}/team_name"
        _mirror_file "${SESSION_DIR}/team_name"
      else
        touch "${SESSION_DIR}/team_name"
        _mirror_file "${SESSION_DIR}/team_name"
      fi
    fi
  fi

  # conv_id 복원
  SAVED_CONV=$(grep "conv_id=" "$SAVE_FILE" 2>/dev/null | cut -d= -f2)
  if [[ -n "$SAVED_CONV" ]]; then
    echo "$SAVED_CONV" > "${SESSION_DIR}/conv_id"
    _mirror_file "${SESSION_DIR}/conv_id"
  fi

  # reroute_count 복원 — 활성 에이전트 없을 때만 (L-278) + 0이면 명시적 삭제
  if [[ "$ACTIVE_COUNT" -eq 0 ]]; then
    SAVED_REROUTE=$(grep "reroute_counter=" "$SAVE_FILE" 2>/dev/null | cut -d= -f2)
    if [[ -n "$SAVED_REROUTE" && "$SAVED_REROUTE" != "0" ]]; then
      echo "$SAVED_REROUTE" > "${SESSION_DIR}/reroute_count"
      _mirror_file "${SESSION_DIR}/reroute_count"
    elif [[ "$SAVED_REROUTE" == "0" ]]; then
      rm -f "${SESSION_DIR}/reroute_count"
      _mirror_delete "${SESSION_DIR}/reroute_count"
    fi
  fi
fi

# ── stdout 출력 (system-reminder로 모델에게 전달) ──

echo "[Compact 후 필수 규칙 복원]"
echo "- UUID: ${UUID}"
echo "0. ⚠️ /ocontext 즉시 실행 필수: Skill('ocontext')를 호출하여 CLAUDE.md, PROJECT.md, 변경 스킬을 다시 읽어라."
echo "N. 파이프라인 위치 재확인: 어디까지 완료했는지 확인 후 다음 단계부터 재개"

# 체크포인트가 있으면 상세 복원 가이드 출력
if [[ -f "$SAVE_FILE" ]]; then
  PHASE=$(grep "pipeline_state=" "$SAVE_FILE" | cut -d= -f2 | awk '{print $1}')
  PHASE="${PHASE:-IDLE}"
  CLASSIFICATION=$(grep "task_classification=" "$SAVE_FILE" | cut -d= -f2)
  CONV_ID=$(grep "conv_id=" "$SAVE_FILE" | cut -d= -f2)
  USER_REQ=$(grep "user_request=" "$SAVE_FILE" | cut -d= -f2)
  TEAM_CREATED=$(grep "team_created=" "$SAVE_FILE" | cut -d= -f2)
  OPLAN_RESULT=$(grep "oplan_result=" "$SAVE_FILE" | cut -d= -f2)
  EV_BUILD=$(grep "evidence_build=" "$SAVE_FILE" | cut -d= -f2)
  EV_DEPLOY=$(grep "evidence_deploy=" "$SAVE_FILE" | cut -d= -f2)
  EV_RUN=$(grep "evidence_run=" "$SAVE_FILE" | cut -d= -f2)
  EV_QUALITY=$(grep "evidence_quality=" "$SAVE_FILE" | cut -d= -f2)

  if [[ "$IS_TEAM" = "true" ]]; then
    cat << TEAM_EOF

[팀에이전트 체크포인트 복원]
- 파이프라인: ${PHASE}
- 대화ID: ${CONV_ID:-없음}
- 역할추정: $(echo "$PHASE" | sed 's/PLAN/oplan/;s/DEV/odev/;s/TEST/otest/;s/DONE/odone/;s/FINISH/ofinish 진행 중 — 정리 완료 대기/;s/OK/ok 오케스트레이션 진행 중 — 파이프라인 재개/')

[즉시 행동]
TODO 파일 또는 spawn 프롬프트의 지시사항을 재확인하고 미완료 작업부터 재개하라.
결과 파일은 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/logs/ 에 저장 후 SendMessage로 리더에게 통보하라.
TEAM_EOF

  else
    cat << MAIN_EOF

[파이프라인 체크포인트]
- 상태: ${PHASE}
- 분류: ${CLASSIFICATION:-unknown}
- 대화ID: ${CONV_ID:-없음}
- 요청: ${USER_REQ:-기록 없음}
- oplan결과: ${OPLAN_RESULT:-없음}
- 팀활성: ${TEAM_CREATED:-false}
- 증거: build=${EV_BUILD:-N} deploy=${EV_DEPLOY:-N} run=${EV_RUN:-N} quality=${EV_QUALITY:-N}
MAIN_EOF

    # 팀에이전트 상태 감지 (compact ≠ 세션 종료)
    if [[ "$TEAM_CREATED" = "true" && "$PHASE" != "IDLE" && "$PHASE" != "FINISH" ]]; then
      LIVE=0; GONE=""
      if [ -d "${SESSION_DIR}/agents" ]; then
        for AF in "${SESSION_DIR}/agents"/*; do
          [ -f "$AF" ] || continue; AN=$(basename "$AF"); [ "$AN" = "team-lead" ] && continue
          grep -q "shutdown_sent=true" "$AF" 2>/dev/null && continue
          MP=$(grep "pane_id=" "$AF" 2>/dev/null | cut -d= -f2)
          if [[ -n "$MP" ]] && tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qF "$MP"; then
            LIVE=$((LIVE + 1))
          else
            GONE="${GONE:+${GONE}, }${AN}"
          fi
        done
      fi
      if [ $LIVE -gt 0 ]; then
        echo -e "\n[즉시 행동] 활성 멤버 ${LIVE}개 SendMessage status_check 발송 → 완료 확인 → 다음 단계"
      elif [ -n "$GONE" ]; then
        echo -e "\n[⚠️ STALE PIPELINE] ${PHASE}, 소멸: ${GONE} → Skill('ofinish') 즉시 실행"
      fi
    fi

    # ── checkpoint 기반 세밀한 진행도 ──
    CKPT_EXISTS=$(grep "checkpoint_exists=" "$SAVE_FILE" 2>/dev/null | cut -d= -f2)
    if [[ "$CKPT_EXISTS" = "true" ]]; then
      CKPT_LAST_EVENT=$(grep "checkpoint_last_event=" "$SAVE_FILE" 2>/dev/null | cut -d= -f2)
      CKPT_LAST_STAGE=$(grep "checkpoint_last_stage=" "$SAVE_FILE" 2>/dev/null | cut -d= -f2)
      WORK_RESULTS=$(grep "work_results=" "$SAVE_FILE" 2>/dev/null | cut -d= -f2)

      echo -e "\n[세밀한 진행도 (checkpoint)]"
      echo "  마지막 이벤트: ${CKPT_LAST_EVENT:-unknown} (${CKPT_LAST_STAGE:-unknown} 단계)"
      if [[ -n "$WORK_RESULTS" ]]; then
        echo "  에이전트 결과 보존: ${WORK_RESULTS}"
      fi
      echo -e "\n[즉시 행동] Skill('oresume') 호출하여 중단 지점부터 재개 가능 (/oresume)"
    else
      # checkpoint 없는 경우 기존 1줄 가이드
      case "$PHASE" in
        IDLE) echo -e "\n[즉시 행동] IDLE — 사용자 명령 대기" ;;
        OK|PLAN|DEV|TEST|DONE) echo -e "\n[즉시 행동] ${PHASE} 재개 — 활성 멤버 status_check, 소멸 멤버 재spawn, 완료 시 다음 단계" ;;
        FINISH) echo -e "\n[즉시 행동] Skill('ofinish') 즉시 실행 → IDLE 전환" ;;
        *) echo -e "\n[즉시 행동] ${PHASE} 확인 후 재개" ;;
      esac
    fi
  fi
fi
