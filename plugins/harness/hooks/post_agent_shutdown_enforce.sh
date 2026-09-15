#!/bin/bash
# >>> harness preamble
_HP="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}"
[ -f "$_HP/hooks/harness_preamble.sh" ] && . "$_HP/hooks/harness_preamble.sh" 2>/dev/null || { [ -f "$_HP/harness_preamble.sh" ] && . "$_HP/harness_preamble.sh" 2>/dev/null; } || true
# <<< harness preamble
# post_agent_shutdown_enforce.sh — PostToolUse:Agent shutdown 누락 감지 + 자율 집행
#
# 역할:
#   - state ∈ {DEV, TEST, DONE}에서만 동작 (그 외 skip)
#   - agents/{NAME} 파일의 shutdown_sent=true 누락 탐지
#   - 5분(300s) age 가드 — 신규 spawn 제외
#   - G1 감지: 기존 그대로 (경고 + retry_queue 엔큐 + 로그 기록, 변경 없음)
#   - G2 집행(신규): 누락 확정 시 shutdown_due=true 마커 기록 (파괴성 없음)
#   - G3 강제(신규): G2 마커가 이미 있는 상태에서 재차 누락 확인(2틱 연속) 시
#     sendmessage_shutdown_sweep.sh와 동일한 pane_sweeper.sh 경로(kill_bash_pane)를 재사용해 물리 kill
#     4중 AND 안전조건 + self-pane 제외 + 킬스위치 + fail-open (사이클15 안건① — oplan_conv_178719426224)
#
# 등록: PostToolUse:Agent (timeout 10s)
#
# ── 25차 사이클 수정 (2026-09-07, conv_c25) ──────────────────────────────────
# 사유: 21~23차에서 팀에이전트 14기가 최장 8시간 방치됐다. 원인은 판정 버그 2건이다.
#   ① shutdown_sent= 키는 생산자가 0건이라 영구 빈 값 → 전원 "미발송"으로 오판.
#      ⇒ 판정 근거를 evidence/shutdown_sent/{NAME} 파일 존재로 교체(구 키는 정확일치 병행 인정).
#   ② is_bash_orphan 은 생존이 아니라 pane 기동 방식(bash 래퍼 유무)만 반영해 항상 false.
#      ⇒ 제거하고 tmux pane 실존 확인으로 교체. 단 bash pane(메인 %0 포함)이 후보로
#        들어오므로 오탐 방어 4중(no_kill/화이트리스트/self-pane 3중/dry-run)을 함께 넣었다.
# 안전: dry-run 이 기본값이다. 실집행은 OAGENT_SHUTDOWN_ENFORCE=1 명시 시에만 일어난다.
# 롤백: ① 즉시정지(재시작 불필요) → touch ~/.claude/hooks/.shutdown_enforce_off
#       ② 완전원복 → cp post_agent_shutdown_enforce.sh.bak-c25-20260907 post_agent_shutdown_enforce.sh
#       ③ 최후 → chmod -x post_agent_shutdown_enforce.sh
# ────────────────────────────────────────────────────────────────────────────

trap 'exit 0' ERR

INPUT=$(timeout 5 cat 2>/dev/null) || INPUT=""
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")

# --- UUID 결정 ---
source "${HARNESS_HOOK_DIR}/lib/session_id.sh" 2>/dev/null || true
if ! resolve_uuid "$INPUT" 2>/dev/null; then
  if [[ -n "$SESSION_ID" ]]; then
    UUID="$SESSION_ID"
  else
    exit 0
  fi
fi

SESSION_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}"
[[ -d "$SESSION_DIR" ]] || exit 0

# --- state 필터 ---
STATE_FILE="$SESSION_DIR/state"
[[ -f "$STATE_FILE" ]] || exit 0
CURRENT_STATE=$(state_read "$STATE_FILE" 2>/dev/null | awk '{print $1}')
case "$CURRENT_STATE" in
  DEV|TEST|DONE) ;;
  *) exit 0 ;;
esac

AGENTS_DIR="$SESSION_DIR/agents"
[[ -d "$AGENTS_DIR" ]] || exit 0

LOG_DIR="$SESSION_DIR/logs"
RETRY_DIR="$SESSION_DIR/retry_queue"
mkdir -p "$LOG_DIR" "$RETRY_DIR" 2>/dev/null || true
LOG_FILE="$LOG_DIR/shutdown_enforce.log"

# --- G3 킬스위치 3값 (25차) — 0=완전우회 / dry=판정+로그만(기본) / 1=실집행 ---
#   기본이 dry 인 이유: 7개 프로젝트가 이 hook 을 공유하며, kill 경로는 한 번도 실행된 적이 없다.
#   파일 킬스위치는 env 와 달리 세션 재시작 없이 즉시 반영된다(사고 시 1순위 정지 수단).
G3_ENABLED=1
G3_MODE="${OAGENT_SHUTDOWN_ENFORCE:-dry}"
[[ "$G3_MODE" == "0" ]] && G3_ENABLED=0
[[ -f "$HOME/.claude/hooks/.shutdown_enforce_off" ]] && G3_ENABLED=0

# --- G3 재사용 라이브러리 (fail-open: 로드 실패 시 G3 자동 비활성) ---
if [[ "$G3_ENABLED" == "1" ]]; then
  source "${HARNESS_HOOK_DIR}/lib/pane_sweeper.sh" 2>/dev/null || G3_ENABLED=0
fi
if [[ "$G3_ENABLED" == "1" ]]; then
  source "${HARNESS_HOOK_DIR}/lib/state_machine.sh" 2>/dev/null || G3_ENABLED=0
fi

# --- status 축 조회 (RALPH/PAUSE/ABORT 제외 판정용 — fail-open: 실패 시 G3 미발동) ---
STATUS_FILE="$SESSION_DIR/status"
CURRENT_STATUS=""
if [[ "$G3_ENABLED" == "1" ]]; then
  if declare -f status_read >/dev/null 2>&1; then
    CURRENT_STATUS=$(status_read "$STATUS_FILE" 2>/dev/null)
    [[ "$CURRENT_STATUS" == "__LOCK_FAIL__" ]] && G3_ENABLED=0
  else
    G3_ENABLED=0
  fi
fi

NOW=$(date +%s)
AGE_THRESHOLD=300  # 5분 age 가드

for af in "$AGENTS_DIR"/*; do
  [[ -f "$af" ]] || continue
  NAME=$(basename "$af")

  # 에이전트 파일 mtime 기준 age
  #   ※ G2 마커를 >> 로 append 하면 mtime 이 현재로 갱신되어 age 가 리셋된다(25차b 실측).
  #     그러면 이미 누락이 확정된 에이전트가 다음 틱에서 age 가드에 걸려 G3 에 영원히 도달하지
  #     못한다. 마커가 있다는 것은 이전 틱에 age 가드를 이미 통과했다는 뜻이므로 재검사하지 않는다.
  #     (age 가드의 목적은 "신규 spawn 제외"이지 "확정된 누락의 재유예"가 아니다.)
  MTIME=$(stat -c '%Y' "$af" 2>/dev/null || echo 0)
  AGE=$((NOW - MTIME))
  _DUE_AT=$(grep '^shutdown_due_at=' "$af" 2>/dev/null | tail -1 | cut -d= -f2 | tr -cd '0-9')
  if [[ -n "$_DUE_AT" ]]; then
    AGE=$((NOW - _DUE_AT + AGE_THRESHOLD))  # 마커 존재 = age 가드 통과 확정, 경과시간은 마커 기준
  else
    (( AGE < AGE_THRESHOLD )) && continue  # 신규 spawn skip
  fi

  # --- 발송 여부 판정 (25차 변경1) ---
  #   1순위: evidence/shutdown_sent/{NAME} 파일 존재 — SendMessage(shutdown_request) 를
  #          실제로 호출해야만 orphan_scan.sh:shutdown_marker_write() 가 만든다.
  #          LLM 이 "발송했다"고 텍스트로 선언하는 것만으로는 생기지 않는 실체 증거다.
  #   2순위: 구 키 shutdown_sent=true 를 정확 일치로 병행 인정 — 향후 생산자가 생기면 자연 호환된다.
  #          (grep -x 이므로 shutdown_sent_at= 에 오매칭되지 않는다.)
  #   ※ 마커는 응답 수신 시 shutdown_marker_clear() 가 지운다. 즉 마커 부재는 "미발송"과
  #     "발송 후 정상 종료"를 구분하지 못한다. 후자는 pane 도 함께 소멸하므로
  #     아래 pane 실존 확인(변경2)이 그 모호성을 흡수한다.
  SHUTDOWN_EVIDENCE="$SESSION_DIR/evidence/shutdown_sent/${NAME}"
  LEGACY_SENT=$(grep -x 'shutdown_sent=true' "$af" 2>/dev/null | head -1)
  if [[ ! -f "$SHUTDOWN_EVIDENCE" && -z "$LEGACY_SENT" ]]; then
    TS=$(date '+%Y-%m-%d %H:%M:%S')
    # G1: stdout 경고 (차단 아님, 기존 그대로)
    echo "⚠️ [shutdown enforce] agent=${NAME} (age=${AGE}s) — shutdown_request 누락"
    # G1: retry queue 엔큐 (기존 그대로)
    echo "$TS name=${NAME} age=${AGE}s state=${CURRENT_STATE}" > "$RETRY_DIR/${NAME}.shutdown" 2>/dev/null || true
    # G1: 로그 기록 (기존 그대로)
    echo "[${TS}] MISSING shutdown_sent name=${NAME} age=${AGE}s state=${CURRENT_STATE}" >> "$LOG_FILE" 2>/dev/null || true

    # --- G2: shutdown_due 마커 기록 (파괴성 없음) ---
    ALREADY_DUE=$(grep '^shutdown_due=' "$af" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
    if [[ "$ALREADY_DUE" != "true" ]]; then
      {
        echo "shutdown_due=true"
        echo "shutdown_due_at=${NOW}"
      } >> "$af" 2>/dev/null || true
      echo "[${TS}] G2_MARKED name=${NAME} age=${AGE}s" >> "$LOG_FILE" 2>/dev/null || true
      # 이번 틱에 처음 마커를 찍었으므로 G3(2틱 연속 조건)는 이번 틱엔 발동하지 않음
      continue
    fi

    # --- G3: 2틱 연속 누락 확정 상태 — 4중 AND + self-pane 제외 + fail-open ---
    [[ "$G3_ENABLED" == "1" ]] || continue

    # 조건4: status 축에 PAUSE/ABORT/RALPH 없음
    #   RALPH: oralph/oto 루프 중 재사용 예정 에이전트를 죽이면 회귀(oplan 명시 엣지케이스) — 제외
    #   PAUSE/ABORT: 일시정지/긴급중단 중 물리 개입 금지
    case "$CURRENT_STATUS" in
      *PAUSE*|*ABORT*|*RALPH*)
        echo "[${TS}] G3_SKIP_STATUS name=${NAME} status=${CURRENT_STATUS}" >> "$LOG_FILE" 2>/dev/null || true
        continue
        ;;
    esac

    # 조건3: pane_id 등록 확인
    PANE_ID=$(grep '^pane_id=' "$af" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
    if [[ -z "$PANE_ID" ]]; then
      echo "[${TS}] G3_SKIP_NO_PANE name=${NAME}" >> "$LOG_FILE" 2>/dev/null || true
      continue
    fi

    # ── 조건5 (25차): no_kill 마커 — 최우선. 존재하면 어떤 조건에서도 kill 하지 않는다 ──
    #   경로 규약은 ok/SKILL.md G4 (session-env/${UUID}/no_kill/{name}).
    #   이 hook 은 24차까지 이 마커를 전혀 보지 않았다(미구현). 25차에서 추가한다.
    if [[ -f "$SESSION_DIR/no_kill/${NAME}" ]]; then
      echo "[${TS}] G3_SKIP_NO_KILL name=${NAME}" >> "$LOG_FILE" 2>/dev/null || true
      continue
    fi

    # ── 조건6 (25차): 이름 기반 명시 제외 — 오래 살아 있는 것이 정상인 에이전트 ──
    #   oi-*  : oi-qa 등 사용자 입력을 장시간 대기한다(실측 age=1684s 로 kill 대상이 될 뻔했다).
    #   obuild*: 빌드 전담. 빌드 자체가 300s 를 쉽게 넘긴다.
    #   team-lead: 리드를 죽이면 팀 전체가 정지한다.
    case "$NAME" in
      oi|oi-*|obuild*|team-lead)
        echo "[${TS}] G3_SKIP_WHITELIST name=${NAME}" >> "$LOG_FILE" 2>/dev/null || true
        continue
        ;;
    esac

    # ── 조건7 (25차): self/메인 pane 3중 방어 (L-304 재현 방지) ──
    #   L-304: 메인 pane 을 kill 하면 세션 전체가 종료된다.
    #   1순위 $TMUX_PANE — 실제 자기 pane. display-message 는 %0(메인/oio 서버 pane)을
    #   반환해 자기 자신을 오인하므로 단독으로는 신뢰할 수 없다(25차 실측).
    if [[ -n "${TMUX_PANE:-}" && "$PANE_ID" == "$TMUX_PANE" ]]; then
      echo "[${TS}] G3_SKIP_SELF_ENV name=${NAME} pane=${PANE_ID}" >> "$LOG_FILE" 2>/dev/null || true
      continue
    fi
    #   2순위 display-message 결과 병행 — 실측상 %0 을 반환하므로 사실상 메인 pane 보호로 작동한다.
    _MY_PANE=$(tmux display-message -p '#{pane_id}' 2>/dev/null || echo "")
    if [[ -n "$_MY_PANE" && "$PANE_ID" == "$_MY_PANE" ]]; then
      echo "[${TS}] G3_SKIP_SELF_DM name=${NAME} pane=${PANE_ID}" >> "$LOG_FILE" 2>/dev/null || true
      continue
    fi
    #   3순위 구조적 화이트리스트 — 이 루프는 agents/ 파일에서만 PANE_ID 를 읽으므로
    #   agents 에 등록되지 않은 pane 은 애초에 후보가 되지 않는다(추가 코드 없이 성립).
    #   기존 assert_not_self_pane 도 있으면 병행 호출한다(있는 방어를 빼지 않는다).
    if declare -f assert_not_self_pane >/dev/null 2>&1; then
      if ! assert_not_self_pane "$PANE_ID" 2>/dev/null; then
        echo "[${TS}] G3_SKIP_SELF_PANE name=${NAME} pane=${PANE_ID}" >> "$LOG_FILE" 2>/dev/null || true
        continue
      fi
    fi

    # ── 변경2 (25차): is_bash_orphan 제거 → tmux pane 실존 확인 ──
    #   is_bash_orphan 은 pane 을 어떻게 띄웠는가(bash 래퍼 유무)만 반영해 에이전트 생존과 무관하다.
    #   실존하지 않는 pane 은 이미 정상 종료된 것이므로 잔여 파일만 정리하고 넘어간다.
    #   grep -qxF 는 정확 일치다 — %8 이 %85 에 부분매칭되는 사고를 차단한다.
    if ! declare -f kill_bash_pane >/dev/null 2>&1; then
      continue  # fail-open: kill 함수 부재 시 아무것도 하지 않는다
    fi
    if ! tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qxF "$PANE_ID"; then
      echo "[${TS}] G3_SKIP_PANE_GONE name=${NAME} pane=${PANE_ID}" >> "$LOG_FILE" 2>/dev/null || true
      rm -f "$af" "$RETRY_DIR/${NAME}.shutdown" 2>/dev/null || true
      continue
    fi

    # ── 조건8 (25차): dry-run 단계배포 — 실집행은 OAGENT_SHUTDOWN_ENFORCE=1 일 때만 ──
    if [[ "$G3_MODE" != "1" ]]; then
      echo "[${TS}] G3_DRYRUN_WOULD_KILL name=${NAME} pane=${PANE_ID} age=${AGE}s" >> "$LOG_FILE" 2>/dev/null || true
      continue
    fi

    if kill_bash_pane "$PANE_ID" "post_agent_shutdown_enforce(name=${NAME},2tick)" 2>/dev/null; then
      echo "[${TS}] G3_KILL_OK name=${NAME} pane=${PANE_ID}" >> "$LOG_FILE" 2>/dev/null || true
      rm -f "$af" 2>/dev/null || true
      rm -f "$RETRY_DIR/${NAME}.shutdown" 2>/dev/null || true
    else
      echo "[${TS}] G3_KILL_FAILED name=${NAME} pane=${PANE_ID}" >> "$LOG_FILE" 2>/dev/null || true
    fi
  fi
done

exit 0
