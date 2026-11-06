---
name: oresume
description: "파이프라인 재개·완주 유도 스킬. 중단된 ok 파이프라인을 checkpoint.jsonl 기반으로 정확한 지점부터 재개하고 ofinish_done까지 자동 완주를 시도. 수동 호출: /oresume. compact 후 자동 권고됨. oinit(정리/초기화)과 역할 분리 — 정리는 oinit, 재개·완주는 oresume."
invocation:
  user_callable: true
  pipeline_callable: false
  called_by: [사용자, SessionStart_compact.sh 권고]
  calls: [ok_pipeline]
---

# oresume — 파이프라인 재개·완주 유도

**실행 주체**: 메인 에이전트 전용 (수동 호출 — `/oresume`)
**목적**: 중단된 ok 파이프라인을 checkpoint 기반으로 정확한 지점부터 재개 + ofinish_done까지 자동 완주 유도
**사용 시점**: compact 후, 세션 복원 후, 비정상 종료 후, 메인이 작업 마무리를 못 하고 있을 때
**범위**: IDLE이 아닌 모든 파이프라인 상태 (PLAN/DEV/TEST/DONE/FINISH/EARLY_TERM/ERROR)

> **oinit과 역할 분리 (2026-05-11)**: 정리·초기화는 `/oinit` (강제모드 — IDLE 전이),
> 재개·완주는 `/oresume` (checkpoint 기반 — 끝까지 자동 완수).
> 헷갈리면: "다 멈추고 처음부터" → `/oinit`, "멈춘 지점부터 끝까지" → `/oresume`.
> **Phase B 변경**: stage에서 OK 제거됨 (8 stage). 기존 OK 진입 시점은 state=PLAN + classification="OK"로 통합 표기.
> oresume은 state=PLAN AND classification=OK 케이스를 "분류 직후 PLAN 진입" 시점으로 인식하여 PLAN부터 재개.

---

## 핵심 파일 경로

```yaml
파이프라인_상태: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/state
체크포인트: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/checkpoint.jsonl  # Append-Only JSONL
에이전트_결과: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/work/{에이전트명}_result.json
계획서: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/plans/oplan_*.md
파일_할당: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/file_assignment.json
에이전트_등록: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/agents/
증거: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/evidence/
```

## 이벤트 타입 (checkpoint.jsonl event 필드값)

```
OK_START, OK_CLASSIFY_DONE,
PLAN_START, PLAN_DONE,
DEV_START, DEV_AGENT_DONE, DEV_TODO_DONE, DEV_REVIEW_DONE, DEV_ALL_DONE,
TEST_START, TEST_PHASE1_DONE, TEST_PHASE2_DONE, TEST_PHASE3_DONE, TEST_ALL_DONE,
DONE_START, DONE_SUBSTEP, DONE_ALL_DONE,
FINISH_DONE, REROUTE
```

---

## 실행 파이프라인 (번호순 엄수 — 스킵 절대 금지)

```
/oresume 호출
  ↓
Step 1: UUID 탐색 — 비IDLE 파이프라인 검색
  ↓
Step 2: checkpoint.jsonl 파싱 — REROUTE 무효화 적용
  ↓
Step 3: 팀에이전트 실시간 상태 조회 — SendMessage 프로브
  ↓
Step 4: work/ 결과 파일 스캔 — 에이전트별 완료 판정
  ↓
Step 5: Stale 검증 — git SHA 비교 + 외부 변경 감지
  ↓
Step 6: 진행도 시각화 — 체크리스트 출력 (파일 + 실시간 교차 검증)
  ↓
Step 7: 재개 지점 결정 — 마지막 유효 이벤트 기반
  ↓
Step 8: 재개 실행 — 단계별 spawn + 파이프라인 복귀
```

---

## Step 1: UUID 탐색

```yaml
# L-403/L-405: 타 세션 session-env/*/ 순회 금지(§(a)(c)) — 자기 UUID(SELF_UUID) 디렉터리만 조회하고 SELF_UUID 빈값은 fail-closed. 아래 스크립트가 그 구현이다.
방법: mcp__oio__bash_exec로 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${SELF_UUID}/state 조회(자기 세션만)
스크립트: |
  UUID=""
  CANDIDATES=()
  # §(a) 자기 세션 UUID 확정 (쓰기 경계 기준)
  # oresume은 자기 세션 파이프라인만 재개 가능 — 타 세션 state 쓰기는 §(a) 위반
  SELF_UUID=$(source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/session_id.sh" 2>/dev/null && resolve_uuid "" 2>/dev/null && echo "${UUID:-}" || echo "")
  # [P2-isolation §(a)(c)] Fix 35: SELF_UUID 빈값 → 타 세션 재개 위험 — fail-closed
  if [ -z "$SELF_UUID" ]; then
    echo "❌ SELF_UUID 결정 실패 — oresume 중단 (§(a) fail-closed, 타 세션 재개 금지)" >&2
    exit 1
  fi
  # [P2-isolation Fix 35+] session-env/*/ 글로브 제거 — 자기 UUID 직접 접근
  _dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${SELF_UUID}/"
  if [ -d "$_dir" ]; then
    # ★bash -c 래핑 필수 — bash_exec 셸은 /bin/sh(dash), dash 에는 source 가 없다.★
    #   미래핑 시 state_read rc=127 → 빈값 → IDLE 로 오폴백하여 ★중단된 파이프라인을 IDLE 로 오판★한다 (2026-08-26 실측).
    _state=$(bash -c 'source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/state_machine.sh" 2>/dev/null; state_read "'"${_dir}"'state"' 2>/dev/null | awk '{print $1}')
    _state="${_state:-IDLE}"
    # Phase B: stage에서 OK 제거 (PLAN/DEV/TEST/DONE/FINISH/EARLY_TERM/ERROR만 비IDLE)
    # state=PLAN AND classification=OK 케이스 = 기존 OK 진입 시점 (Step 7 OK_START 매핑 참조)
    case "$_state" in
      PLAN|DEV|TEST|DONE|FINISH|EARLY_TERM|ERROR)
        CANDIDATES+=("$SELF_UUID $_state")
        echo "발견: UUID=${SELF_UUID:0:8}... 상태=$_state"
        ;;
    esac
  fi
  echo "총 ${#CANDIDATES[@]}개 비IDLE 파이프라인 발견"

분기 (★질문 없음 — 2026-10-11 사용자 지시 "답변 요구로 자율주행을 막지 마라"★):
  0개: ★바로 종료하지 않는다.★ 아래 "재기동_복원" 을 먼저 실행한다.
       resume_restore.py --check 가 rc=3(보존본 없음·완료된 파이프라인)일 때만
       "✅ 재개할 파이프라인 없음. /oo로 새 작업을 시작하세요." 출력 후 종료한다.
       rc=4(보존본 파싱 실패)면 "⚠️ [재기동 복원 불가] {reason}" 1줄 출력 후 종료한다(현행 동작 이하로 나빠지지 않는다).
       rc=5(reason=state_checkpoint_mismatch)면 live state 나 완료 시각(finish_at) 이후 저장된 보존본은 진행 중(PLAN|DEV|TEST|DONE)인데 checkpoint 는 FINISH_DONE/ofinish_done 으로 닫힌 불일치다.
       ★자동 재개도, "재개할 파이프라인 없음(완료)" 판정도 하지 않는다.★ live_state·preserved_state·last_event 를 사용자에게 보고하고 state·checkpoint.jsonl 을 수동으로 확인한 뒤 종료한다.
  1개: 해당 UUID 자동 선택
  복수: 자기 UUID 만 조회하므로 구조상 발생하지 않는다. 발생하면 질문하지 않고 SELF_UUID 와 같은 것을 고른다
        (근거 1줄 출력). 타 세션 후보는 §(a) 에 따라 절대 고르지 않는다.

# ★재기동 복원 (계획 s10D — 2026-10-11 신설)★
재기동_복원:
  배경: |
    Windows 재기동·WSL 완전 종료·IO 정지 뒤에는 SessionStart.sh 의 boot-stale 정리가 state 를 IDLE 로 바꾸고
    classification·team_name·entry_tier·status 등을 지운다. 첫 입력에서 UserPromptSubmit.sh _reset_idle 이
    conv_id 도 새 값으로 바꾼다. 그래서 위 후보 조회는 0개가 된다.
    삭제 직전 lib/resume_preserve.sh 의 rp_save 가 resume_preserve/<epoch>_<reason>/ 에 사본과 latest.json 을 남기고,
    PostToolUse_agent_snapshot.sh(async)가 팀원별 상태를 agent_state/<name>.json 에 주기 저장한다.
    이 절차는 그 두 사본으로 파이프라인을 되살린다.
  정직_고지:
    - 메인 대화는 공식 resume(claude --resume / /resume)으로 이어진다.
    - ★팀원 대화 원본의 재개는 공식 미지원이다★ — https://code.claude.com/docs/en/agent-teams Limitations
      ("/resume and /rewind do not restore in-process teammates … tell the lead to spawn new teammates").
      그래서 저장된 요약 컨텍스트(spawn 원문·마지막 지시·마지막 보고·TODO·결과 파일)로 ★같은 이름을 재spawn★ 한다.
    - 서브에이전트는 같은 세션 resume 뒤 SendMessage(agentId)로 재개된다(https://code.claude.com/docs/en/sub-agents). (agentId 목록은 --plan 의 subagents[])
  절차 (사용자 확인 없이 진행한다):
    1. 판정 — bash -c 로 감싼다(bash_exec 는 dash):
       mcp__oio__bash_exec(command="bash -c 'S=$HOME/.claude/session-env/{SELF_UUID}; python3 ${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/resume_restore.py --check \"$S\"; echo rc=$?'")
       # {SELF_UUID} 는 위에서 확정한 값으로 치환한다. 경로 base 는 $HOME/.claude 다(CLAUDE_CONFIG_DIR 쪽은 /tmp 심볼릭링크).
       rc=3 → 위 "0개" 분기대로 종료. rc=4 → 1줄 출력 후 종료. rc=0 → 2번.
       rc=0 은 state_source=checkpoint 와 state_source=preserve_fallback 두 가지다. checkpoint 에 STATE_TRANSITION 만 있어도 보존 state 가 PLAN|DEV|TEST|DONE 이면 preserve_fallback 으로 rc=0 이 나온다.
       state_source=preserve_fallback 이면 last_event 가 비어 있으므로 Step 8 은 last_event 가 아니라 restore.state 단계의 시작부터 밟는다.
       rc=5 → state·checkpoint 불일치다. 자동 재개·완료 판정을 금지하고 "⚠️ [state·checkpoint 불일치] live={live_state} 보존본={preserved_state} 마지막={last_event} — 메타 수동 확인 필요" 를 사용자에게 보고한 뒤 종료한다.
    2. 계획 — 현재 메인 sessionId 를 알면 --lead-session 으로 넘긴다(재기동 뒤 팀 리드 sessionId 가 UUID 와 다를 수 있다):
       python3 ${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/resume_restore.py --plan "$S" [--lead-session <현재 sessionId>]
       출력 JSON: restore{state,classification,entry_tier,status,conv_id,team_name_current,auto,oroof_active_src,oroof_active_json_src,oroof_live_exists,goal_src,goal_live_exists,goal_locked,rollback_hash,roof_gate,auto_roof_mismatch}, boot_changed, last_event, state_source, agents[], subagents[], stale_agent_records[](boot_changed==true 일 때만)
       부산물: work/respawn/<name>.md (partial·missing 팀원만), agent_state/restore_log.jsonl
    3-0. 자율모드 부속 복원 (state·status 보다 먼저 — 아래 메타 복원보다 앞선다).
       (a) restore.goal_src 가 있고 restore.goal_live_exists==false 면 mcp__oio__file_copy(source=restore.goal_src, destination="$HOME/.claude/session-env/{SELF_UUID}/goal.json") 로 복원한다.
           근거: file_write 는 계약 시점 auto_script 실행으로 F-GOALAS-1 거짓 차단을 부른다. file_copy 는 P2 정적 전용이다. live goal 이 이미 있으면 새 계약이 우선이므로 덮어쓰지 않는다.
           차단되면 표현을 바꿔 재시도하지 않고(L-597) 보고에 "goal 미복원" 을 남긴다.
       (b) restore.oroof_active_src·restore.oroof_active_json_src 가 있고 restore.oroof_live_exists==false 면 각각 file_copy 한다(destination 파일명은 원래 이름 그대로).
       (c) restore.auto 가 비어 있지 않으면 mcp__oio__session_state(uuid=SELF_UUID, key="auto", value=restore.auto) 로 쓴다.
       (d) restore.rollback_hash 가 비어 있지 않으면 mcp__oio__session_state(uuid=SELF_UUID, key="rollback_hash", value=restore.rollback_hash) 로 쓴다.
       (e) restore.auto_roof_mismatch==true 면 보존본 자체가 깨진 oto 계약이다. oroof_active 나 ROOF 를 새로 만들지 않는다(위조 금지).
           "⚠️ [재기동 복원] auto=ON 인데 ROOF 게이트 보존본 없음 — oto_entry_guard F-OTO-0b 가 state 복원을 막는다" 를 보고하고 종료한다.
       (f) 옛 pane 기록 무효화 (boot_changed==true 일 때만, 팀원 재spawn 보다 먼저): plan.stale_agent_records 각 항목에 대해
           mcp__oio__file_read 로 agents/<name>(항목의 file 절대경로)을 읽은 뒤, mcp__oio__file_write(overwrite=true) 로 "원문 그대로 + 끝에 shutdown_sent=true 와 stale_boot=<restore 시각 epoch> 2줄" 을 덧붙여 쓴다.
           근거: 정규 파일을 공백 아닌 내용으로 덮어쓰는 것은 write_guard H-1 대상이 아니다(사이클194 (e)). shutdown_sent=true 는 full_task_team_guard L-DUP1 이 명시한 통과 경로이고, 재기동으로 옛 프로세스가 전부 죽었으므로 사실 표기다.
           금지: agents/<name> 삭제·copy·move·rename·이름 변경, <name>.failed 마커 위조, 팀원 이름 바꾸기 우회. 같은 이름 재spawn 이 정답이며 차단되면 L-597 로 보고하고 대기한다.
           boot_changed==false 이면 옛 pane 이 살아 있을 수 있으므로 무효화하지 않고 L-DUP1 판정을 그대로 받는다.
       status 는 아래 메타 복원이 보존 문자열(ROOF 포함, 구 세션의 RALPH 도 그대로 — ROOF-COMPAT)을 그대로 복원하므로 status_add 를 따로 부르지 않는다. 부른다면 bash -c 'source …state_machine.sh; status_add …' 로만 부른다(dash).
    3. 메타 복원 — 스크립트는 메타를 직접 쓰지 않는다(write_guard Fix 3·O7). 메인이 3-0 다음에 순서대로 적는다.
       mcp__oio__session_state(uuid=SELF_UUID, key="conv_id",        value=restore.conv_id,        force=True)
       mcp__oio__session_state(uuid=SELF_UUID, key="classification", value=restore.classification, force=True)  # 빈값이면 생략
       mcp__oio__session_state(uuid=SELF_UUID, key="entry_tier",     value=restore.entry_tier,     force=True)  # 빈값이면 생략
       mcp__oio__session_state(uuid=SELF_UUID, key="status",         value=restore.status,         force=True)  # 빈값이면 생략
       mcp__oio__session_state(uuid=SELF_UUID, key="team_name",      value=restore.team_name_current, force=True)
         # team_name_current 가 빈값이면(소유 팀 없음·모호) 쓰지 않는다 — §(b) fail-closed. Step 8 사전조건_2 가 팀을 새로 만든다.
       mcp__oio__session_state(uuid=SELF_UUID, key="state",          value=restore.state,          force=True)  # ★state 는 마지막★
       state 기록이 hook(oto/done_gate 등)에 막히면 직전 단계(DEV)로 기록하고 Step 8 이 그 단계부터 다시 밟는다.
    4. 출력(1줄): "🔁 [재기동 복원] conv_id={conv_id} state={state} last_event={last_event} 재spawn 대상 {n}명(완료 {m}명 제외) auto={restore.auto|-} goal={복원|유지|없음} 서브 {len(plan.subagents)}명"
    4-1. 서브에이전트 재개: plan.subagents 각 원소에 SendMessage(to=<agent_id>, message="재기동으로 중단됐다. 같은 지시로 이어서 진행하고 결과를 보고하라.") 를 보낸다.
       정직 고지: 프로세스 재시작(--continue) 뒤 agentId 로 재개가 되는지는 이 하네스에서 실측하지 않았다(추정). 실패하면 그 agent_id 와 transcript_hint 를 보고에 남기고, 그 서브에이전트의 일은 메인이 계획서 기준으로 다시 수행한다.
    5. CANDIDATES 에 "$SELF_UUID {state}" 를 넣고 Step 2 로 진행한다. --plan JSON 은 Step 3·4·8 에서 그대로 재사용한다.

# [P2-isolation §(a)(c)] Fix 35: SELF_UUID 빈값 → 모든 경우 fail-closed (후보 수 무관)
# 이전 fallback "1개 후보 + SELF_UUID 불명 시 해당 UUID 사용" 제거 — 그 1개가 타 세션일 수 있음
SELF_UUID_감지_실패_처리:
  모든_경우: SELF_UUID="" → "❌ SELF_UUID 결정 실패 — oresume 중단 (§(a) fail-closed)" 출력 후 exit 1
  이유: 후보가 1개여도 그것이 자기 세션임을 보장할 수 없음 — §(a)(c) 이중 위반 위험

# ★ 고착 파이프라인 자동 분류 (L-341 — 2026-04-09)
고착_파이프라인_사전_분류:
  목적: 비IDLE인데 에이전트 없음 = 고착. UUID 선택 전에 먼저 고착 여부 판별하여 재개 vs 정리 결정.
  판별_방법: |-
    각 후보 UUID에 대해:
      _agent_count=$(ls "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${_uuid}/agents/" 2>/dev/null | wc -l)
      _team_name=$(cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${_uuid}/team_name" 2>/dev/null || echo "")
      _team_member_count=0 (config.json members 중 team-lead 제외)
      _ofinish_done=$(ls "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${_uuid}/evidence/ofinish_done" 2>/dev/null)
      _last_event = checkpoint.jsonl 마지막 줄의 event 필드

  고착_판정 조건: agents=0 + team_members=0 + ofinish_done 없음
    → 고착 파이프라인 → 재개 지점을 last_event 기반으로 즉시 결정 (사용자 선택 불필요)

  고착_재개_지점_결정 (last_event 기준):
    DONE_ALL_DONE: → ofinish 직접 실행 (DEV/TEST/DONE 완료됨)
    TEST_ALL_DONE:  → DONE spawn
    DEV_ALL_DONE:   → TEST spawn
    PLAN_DONE:      → DEV spawn
    OK_START만 있음 (이벤트 1개): → 계획도 못 함 → IDLE 리셋 + 안내
    DEV_START(batch, detail에 "spawn_batch" 포함) + phase_batches.json 없음:
      → L-341-B 배치 고착 패턴 → DONE_ALL_DONE으로 소급 처리 → ofinish 실행

  # L-341-B: batch 모드 고착 패턴 (2026-04-09 발견)
  batch_고착_판별:
    증상: |
      - checkpoint 마지막 이벤트 = DEV_START, detail에 "spawn_batch{N}" 포함
      - phase_batches.json 파일 없음
      - agents/ 비어있음, 직전 유효 이벤트는 DONE_ALL_DONE
    원인: |
      - ok_pipeline이 batch N번째 DEV를 spawn하려다 컨텍스트 손실
      - phase_batches.json 없이 DEV_START만 기록된 상태로 고착
    처리: |
      DEV_START(batch) + phase_batches.json 없음이면:
        → batch 모드 비활성 간주 (단일 파이프라인)
        → 유효 last_event를 DEV_START 직전 이벤트(= DONE_ALL_DONE)로 재설정
        → "DONE_ALL_DONE → ofinish 실행" 경로로 라우팅
    재발방지: |
      - ok_pipeline이 batch spawn 직전 phase_batches.json 존재 확인 필수
      - DEV_START 이벤트 기록 시 phase_batch_mode 플래그 포함 권장
```

---

## Step 2: checkpoint.jsonl 파싱

```yaml
방법: mcp__oio__file_read로 checkpoint.jsonl 전체 읽기
파싱_절차:
  1. 줄별 JSON 파싱 (파싱 실패 줄은 스킵 + 경고 출력)
  2. REROUTE 이벤트 감지 → invalidated_after 기준으로 무효 이벤트 필터링

REROUTE_무효화_규칙:
  원리: REROUTE 이벤트의 invalidated_after 필드값과 일치하는 event를 찾아,
        해당 이벤트 이후의 모든 이벤트를 무효 처리
  예외: DEV_AGENT_DONE은 무효화하지 않음 (완료된 에이전트 작업 보존)

  역라우팅_유형별:
    TEST→DEV: invalidated_after="DEV_ALL_DONE"
      → DEV_ALL_DONE 이후 이벤트 무효 (TEST 관련 전부)
      → 단, DEV_AGENT_DONE은 보존
    TEST→PLAN: invalidated_after="PLAN_DONE"
      → PLAN_DONE 이후 이벤트 전부 무효
      → 단, DEV_AGENT_DONE은 보존
    DONE→TEST: invalidated_after="TEST_ALL_DONE"
      → TEST_ALL_DONE 이후 이벤트 무효 (DONE 관련 전부)

  3. 유효 이벤트만 수집 → 진행도 맵 구성

checkpoint_미존재:
  처리: state 파일만으로 단계 판단 (서브스텝 정보 없음)
  결과: 해당 단계 처음부터 재시작

# v2 C-02 신규: current_phase_batch 읽기 (multi-phase batch 인식)
current_phase_batch_감지:
  경로: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/current_phase_batch
  phase_batches: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/phase_batches.json

  절차:
    1. current_phase_batch 파일 존재 확인 (mcp__oio__file_read)
       - 없음: 단일 batch 모드 (기존 로직) → 건너뜀
       - 있음: 값 읽기 → 공백 제거

    2. 값별 분기:
       값=정수 (예: "2"): current_batch=2 (Batch 2까지 완료, Batch 3 재진입 대상)
       값="ABORT": 사용자 /oabort로 중단됨 → ofinish 진입 안내
       값="PAUSE": PAUSED 상태 (컨텍스트 80%/PREPARE 실패) → /ocontinue 안내
       값="DONE": 모든 batch 완료 → FINISH 진입 안내

    3. phase_batches.json 존재 감지 (mcp__oio__file_read):
       - 없음: multi-phase 모드 비활성 → 단일 batch 모드로 fallback
       - 있음: batches[] 배열 + 각 batch의 depends_on_batch 추출
               → total_batches, current_batch, remaining_batches 계산

  결과_변수:
    - phase_batch_mode: true/false
    - current_batch: 정수 또는 특수값
    - total_batches: phase_batches.json의 batches[].length
    - depends_on_batch: {N: [...deps]} 매핑
```

---

## Step 3: 팀에이전트 실시간 상태 조회 (pane 물리 상태 기반 — L-331)

> **핵심 원칙 (L-331)**: SendMessage로 응답을 기다리는 방식 절대 금지. pane CMD + --agent-id 플래그 + evidence 파일 기반으로 즉시 판정.
> **사유**: SendMessage는 비동기 — 같은 턴에서 응답이 올 수 없음. 대기 시 영구 블로킹 발생.

```yaml
목적: 에이전트 등록 파일(agents/)과 tmux pane 물리 상태를 비교하여 생존/좀비/사망을 즉시 판정.
      SendMessage 없이 물리적 증거만으로 판단.

절차:
  1_에이전트_목록_수집:
    방법: ls ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/agents/
    결과: 에이전트명 → pane_id 매핑 수집
    없음: "등록된 에이전트 없음" → Step 4로 진행

  2_pane_물리_상태_즉시_판정 (L-331 — SendMessage 금지):
    방법: 각 에이전트 파일에서 pane_id 추출 → tmux display-message -t {pane_id} -p '#{pane_current_command}'
    판정_기준 (우선순위 순):
      a. pane 소멸 (pane 없음): 상태=사망 → 재spawn 대상
      b. pane CMD=bash: 상태=좀비 (claude 프로세스 크래시됨) → kill 후 재spawn 대상
      c. pane CMD=2.1.x/claude:
           → BASH_PID=$(tmux display-message -t {pane_id} -p '#{pane_pid}')
           → CHILD_PID=$(pgrep -P "$BASH_PID" 2>/dev/null | head -1)
           → AGENT_ID=$(ps -p "${CHILD_PID:-$BASH_PID}" -o args= 2>/dev/null | grep -o '\-\-agent-id [^ ]*' | cut -d' ' -f2)
           → AGENT_ID 있음 (팀에이전트 프로세스): 생존 상태=활성
           → AGENT_ID 없음 (메인 Claude): L-213 보호 — 절대 kill 금지

  3_물리_증거_기반_완료_판정 (L-331):
    생존(CMD=2.1.x + AGENT_ID 있음) 에이전트의 완료 여부 판단:
      근거_우선순위:
        ① evidence 파일 확인:
             ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/evidence/odev_done (odev 완료)
             ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/evidence/otest_done (otest 완료)
             ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/evidence/odone_done (odone 완료)
        ② work/ 결과 파일: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/work/{에이전트명}_result.json
             status="completed" → 완료 확정
             status="partial" → 미완료 (일부만 완료)
             미존재 → 상태 불명 (진행 중으로 간주)
      판정:
        evidence 있음 OR work result status="completed" → 상태=완료 (재spawn 불필요)
        evidence 없음 AND work result 미존재/partial → 상태=진행중 (계속 대기 OR 재spawn 판단)

  4_결과_통합_보고:
    형식: |
      ┌──────────────────────────────────────────────────┐
      │ 🔍 팀에이전트 물리 상태 조회 결과 (L-331)         │
      ├──────────────────────────────────────────────────┤
      │ {에이전트명}: {활성|좀비|사망|완료}                │
      │   pane: {pane_id} CMD={command}                   │
      │   --agent-id: {값 또는 "없음(메인Claude)"}        │
      │   근거: evidence={있음|없음} work={completed|partial|없음} │
      │ ...                                               │
      ├──────────────────────────────────────────────────┤
      │ 요약: 활성 {n}개 / 완료 {n}개 / 좀비 {n}개 / 사망 {n}개 │
      └──────────────────────────────────────────────────┘

  0_재기동_복원_경로 (Step 1 재기동_복원을 거친 경우 — 위 1~4 보다 먼저 본다):
    조건: --plan 출력의 boot_changed=true
    처리: ★tmux pane 조회를 건너뛰고 등록된 팀원 전원을 '사망' 으로 판정한다.★
          재기동 뒤 pane 번호(%N)는 다른 프로세스에 재사용될 수 있어 pane 조회 결과를 믿을 수 없다.
          완료 여부는 --plan 의 agents[].status(completed|partial|missing)를 그대로 쓴다.
          아래 "진행중 → 계속 대기" 판단은 이 경로에서 쓰지 않는다.
    boot_changed=false (같은 부팅 안의 비정상 종료): 기존 1~4 절차대로 pane 물리 상태를 본다.

  5_후속_판단 (★질문 없음 — 보수적 자율 판단★):
    전원_사망_또는_완료: checkpoint + work/ 파일 기반 재개 (Step 4~8)
    일부_활성_진행중:
      - 완료 판정된 에이전트 → 재spawn 불필요 (shutdown_request 발송)
      - 진행중(활성) 에이전트 → ★질문하지 않고 그대로 둔다(계속 대기).★ 살아 있는 팀원을 재spawn 하면
        같은 이름이 둘이 되고, 강제 정리는 진행 중 작업을 잃는다 — 둘 다 보수적이지 않다.
        근거 1줄 출력: "⏳ [oresume] {이름} 활성·진행중 — 재spawn·정리하지 않고 결과 보고를 기다린다."
      - 좀비 에이전트 → 즉시 kill 후 재spawn 대상
    전원_활성_진행중:
      "파이프라인이 아직 진행 중입니다. 대기 또는 /ofinish로 강제 정리하세요." 안내 후 종료

SendMessage_절대_금지_패턴 (L-331):
  ❌ SendMessage(to="{에이전트명}", message="현재 상태를 보고하라") 후 응답 대기
  ❌ "에이전트 응답을 기다립니다" 출력 후 멈춤
  ❌ 응답이 올 때까지 Step 4 진입 연기
  이유: SendMessage는 비동기 통신. 같은 턴에서 응답 불가. 대기 시 영구 블로킹.
```

---

## Step 4: work/ 결과 파일 스캔

```yaml
방법: mcp__oio__bash_exec로 ls work/*_result.json → 각 파일 mcp__oio__file_read

★conv_id 대조 게이트 (L-670 — 에이전트별_판정보다 먼저 전 파일에 적용한다):
  현재_conv_id_획득: mcp__oio__bash_exec(command='cat $HOME/.claude/session-env/${UUID}/conv_id')
  판정:
    저장된 conv_id == 현재 conv_id  → 유효한 결과다. 아래 에이전트별_판정으로 진행한다.
    저장된 conv_id != 현재 conv_id  → ★옛 사이클 잔류물★이다. 그 파일을 ★result 미존재★로
                                       취급한다(전체 재할당).
    conv_id 필드 부재 (구 스키마)   → ★잔류물로 간주★한다. 위와 동일하게 미존재 취급한다.
  출력: 무시한 파일마다 1줄로 남긴다 —
        "⚠️ [잔류물 무시] {파일명} conv_id={저장값|부재} ≠ 현재 {현재값} — 미존재로 취급한다."
  원칙: 판단이 서지 않으면 ★미존재(재수행)★ 쪽으로 기운다. 중복 수행은 비용일 뿐이지만
        잘못된 스킵은 "하지 않은 일을 완료로 보고"하는 침묵 실패다.
  재기동_복원_뒤: 재기동 복원 뒤 현재 conv_id 는 보존 conv_id 로 되돌려져 있다. 되돌리기 전이라면 Step 1 복원을 먼저 하라.
        (되돌리기 전 새 conv_id 로 이 게이트를 돌리면 완료된 결과까지 전부 잔류물로 버려진다. 게이트 기준은 그대로 둔다.)
  배경: work/ 는 사이클을 넘어 누적되므로 이름·경로가 같은 옛 산출물이 그대로 남는다.
        사이클25 odone 진입 시 사이클15 잔류물(status:"completed")이 실제로 발견됐다.

에이전트별_판정:
  result 존재 + status="completed":
    판정: ✅ 완료 (재spawn 불필요)
    추출: todos_completed, phases_completed, substeps_completed 등 세부 정보

  result 존재 + status="partial":
    판정: ⏳ 미완료 (나머지만 재할당)
    추출: todos_completed 목록 → 미완료 TODO 식별

  result 미존재:
    판정: ❌ 전체 재할당
    처리: 해당 에이전트 전체 작업 재spawn

결과_맵_구성:
  에이전트명 → {status, todos_completed[], phases_completed[], substeps_completed[]}
```

---

## Step 5: Stale 검증

```yaml
방법: checkpoint.jsonl 마지막 유효 이벤트의 git_sha vs git rev-parse --short HEAD

FRESH (SHA 동일):
  판정: 안전하게 재개
  처리: Step 5로 진행

COMPATIBLE:
  판정_방법: |
    mcp__oio__bash_exec("git diff --name-only {checkpoint_sha}..HEAD")
    → 변경 파일 목록과 파이프라인 수정 대상 파일(file_assignment.json) 교집합 확인
  조건: 교집합 없음 (파이프라인이 수정하려는 파일이 외부에서 변경되지 않음)
  처리: "⚠️ git SHA 불일치이나 수정 대상 파일은 변경 없음 — 재개 진행" 경고 후 Step 5로 진행

STALE:
  판정_방법: 교집합 있음 (파이프라인이 수정하려는 파일이 외부에서 변경됨)
  처리 (★질문 없음 — 보수적 자율 판단, 2026-10-11 사용자 지시★):
    선택: "재개 + 교집합 파일 재검토" 로 진행한다. checkpoint 삭제·리셋(파괴적)도, 외부 변경 무시(충돌 위험)도 하지 않는다.
    절차:
      1. 교집합 파일을 담당한 팀원은 Step 4 판정이 completed 여도 ★partial 로 강등★한다(재검토 대상).
      2. 그 팀원의 재spawn 프롬프트에 "외부 변경 파일: {목록} — 현재 내용을 다시 읽고, 이미 한 수정이
         남아 있는지 확인한 뒤 이어서 작업하라. 외부 변경을 되돌리지 마라." 를 덧붙인다.
      3. 근거 1줄 출력: "⚠️ [STALE 자율재개] 외부 변경 {n}파일 — 담당 {이름들} 재검토로 재개한다(리셋·강제 재개 안 함)."
    리셋이 필요하다고 판단되면(교집합이 계획서 수정 대상의 절반 이상 등) 리셋하지 말고 PLAN 재개로 돌린다
    (계획을 현재 코드 기준으로 다시 세운다 — checkpoint 는 보존).

git_sha_미존재 (checkpoint에 git_sha 필드 없음):
  처리: COMPATIBLE로 간주 + 경고 출력
```

---

## Step 6: 진행도 시각화

```yaml
형식: 체크리스트 (텍스트 출력)
데이터_소스: checkpoint(Step 2) + 실시간 조회(Step 3) + work/ 결과(Step 4) 교차 검증
우선순위: 실시간 응답 > work/ 결과 > checkpoint (가장 최신 정보 우선)

출력_예시: |
  ┌──────────────────────────────────────┐
  │ ✅ OK: 분류 완료 (O3)                │
  │ ✅ PLAN: 계획서 작성 완료             │
  │ ✅ DEV: odev-1 완료 (TODO 1,2,3)     │
  │ ⏳ DEV: odev-2 미완료 (TODO 4,5)     │
  │ ⬚ TEST: 미시작                       │
  │ ⬚ DONE: 미시작                       │
  │ ⬚ FINISH: 미시작                     │
  └──────────────────────────────────────┘

구성_로직:
  OK:
    OK_CLASSIFY_DONE 있음 → ✅ OK: 분류 완료 ({tier})
    OK_START만 있음 → ⏳ OK: 분류 진행 중
    없음 → ⬚ OK: 미시작

  PLAN:
    PLAN_DONE 있음 → ✅ PLAN: 계획서 작성 완료
    PLAN_START만 있음 → ⏳ PLAN: 계획 수립 중
    없음 → ⬚ PLAN: 미시작

  DEV:
    DEV_ALL_DONE 있음 → ✅ DEV: 전체 완료
    DEV_AGENT_DONE 개수별:
      → 각 에이전트 ✅/⏳ 표시
      → work/ result.json에서 todos_completed 세부 정보 추출
    DEV_START만 있음 → ⏳ DEV: 구현 진행 중
    없음 → ⬚ DEV: 미시작

  TEST:
    TEST_ALL_DONE 있음 → ✅ TEST: 전체 통과
    TEST_PHASE{N}_DONE 개수별:
      → 각 Phase ✅/⏳ 표시
    TEST_START만 있음 → ⏳ TEST: 테스트 진행 중
    없음 → ⬚ TEST: 미시작

  DONE:
    DONE_ALL_DONE 있음 → ✅ DONE: 마무리 완료
    DONE_SUBSTEP 개수별:
      → 완료된 서브스텝 목록 표시
    DONE_START만 있음 → ⏳ DONE: 마무리 진행 중
    없음 → ⬚ DONE: 미시작

  FINISH:
    FINISH_DONE 있음 → ✅ FINISH: 완료
    없음 → ⬚ FINISH: 미시작

# v2 C-02 신규: Phase Batch 레인 (multi-phase batch 진행도)
Phase_Batch_레인_출력:
  조건: Step 2에서 phase_batch_mode=true인 경우에만 출력
  위치: 기존 체크리스트 상단 또는 별도 블록

  출력_예시: |
    🔄 현재 진행 상황:
       단계: DEV (3/5)
       Phase Batch: 2/12 ▓▓░░░░░░░░░░ (Batch 2 완료, Batch 3 진행 중)
       deps: batch 3 depends on [1, 2]

  progress_bar_생성:
    - 완료칸(▓) = current_batch 개수
    - 미완료칸(░) = (total_batches - current_batch) 개수
    - 전체 너비 = total_batches (최대 20칸, 초과 시 스케일 다운)

  상태_라벨:
    current_batch < total_batches → "Batch {N} 완료, Batch {N+1} 진행 중"
    current_batch == total_batches → "모든 Batch 완료"
    값="PAUSE" → "⏸️ PAUSED (Batch {N}에서 일시중지, /ocontinue 대기)"
    값="ABORT" → "❌ ABORTED (사용자 중단, ofinish 필요)"

  deps_표시:
    - phase_batches.json의 batches[current_batch+1].depends_on_batch 추출
    - 형식: "deps: batch {N+1} depends on [{dep1}, {dep2}]"
    - 의존성 미충족 시 ⚠️ 경고 병기
```

---

## Step 7: 재개 지점 결정

```yaml
로직: 마지막 유효 이벤트 기준

재개_매핑:
  # Phase B: OK_START 이벤트 이름은 호환성 유지하되, 실제 매핑은 PLAN+classification=OK 시점으로 (stage OK 폐지)
  OK_START:              → PLAN부터 재개 (state=PLAN + classification=OK 시점으로 복원, 이벤트 이름 보존)
  OK_CLASSIFY_DONE:      → PLAN부터 재개 (분류 완료 직후 — state=PLAN + classification 확정 상태)
  PLAN_START:            → PLAN 재시작 (PLAN_DONE 없음 = 미완료)
  PLAN_DONE:             → DEV부터 재개
  DEV_START:             → DEV 부분 재개 (완료 에이전트 제외)
  DEV_AGENT_DONE:        → DEV 부분 재개 (미완료 에이전트만 재spawn)
  DEV_TODO_DONE:         → DEV 부분 재개
  DEV_REVIEW_DONE:       → DEV 부분 재개
  DEV_ALL_DONE:          → TEST부터 재개
  TEST_START:            → TEST 부분 재개 (완료 Phase 제외)
  TEST_PHASE1_DONE:      → TEST Phase 2부터 재개
  TEST_PHASE2_DONE:      → TEST Phase 3부터 재개
  TEST_PHASE3_DONE:      → TEST 종합 판정부터 재개
  TEST_ALL_DONE:         → DONE부터 재개
  DONE_START:            → DONE 부분 재개 (완료 서브스텝 제외)
  DONE_SUBSTEP:          → DONE 부분 재개 (미완료 서브스텝부터)
  DONE_ALL_DONE:         → FINISH 실행
  FINISH_DONE:           → "✅ 이미 완료된 파이프라인. /oo로 새 작업을 시작하세요."
  REROUTE:               → invalidated_after가 가리키는 단계부터 재개
  # v2 C-02 신규 항목 (Phase Batch Auto-Loop 재개 매핑)
  BATCH_NEXT:            → 4.5단계 batch N+1 재진입 (odev 재spawn, Step 8 "BATCH 재개" 섹션 참조)
  BATCH_PAUSE:           → PAUSED 상태 진입 (/ocontinue 대기 안내 출력 후 종료)
  BATCH_ABORT:           → ofinish 진입 (사용자 /oabort 감지 시)

batch_우선순위_규칙:
  조건: phase_batch_mode=true이고 current_phase_batch 값이 유효한 경우
  처리: 기존 단계 매핑보다 batch 매핑을 우선 적용
    - current_phase_batch 값이 정수 N이고 N < total_batches → BATCH_NEXT
    - current_phase_batch == "PAUSE" → BATCH_PAUSE
    - current_phase_batch == "ABORT" → BATCH_ABORT
    - current_phase_batch == "DONE" or N == total_batches → FINISH 진입

재개_지점_출력:
  형식: "🔄 재개 지점: {단계명} (마지막 이벤트: {event} at {timestamp})"
```

---

## Step 8: 재개 실행

### 사전 조건

```yaml
사전조건_1_팀에이전트_상태_확인 (L-331 — pane 물리 상태 기반):
  방법: Step 3(pane 물리 상태 조회) 결과 재활용
  절차:
    - Step 3에서 수집한 에이전트별 물리 상태(활성/좀비/사망/완료) 참조
    - 활성 + evidence/work 완료 판정 → shutdown_request 발송 후 재개
    - 활성 + 미완료 판정 → 질문하지 않고 계속 대기한다(Step 3 5_후속_판단과 같은 보수적 판단 — 재spawn·강제 정리 안 함)
    - boot_changed=true(재기동 복원) → pane 조회 없이 전원 사망으로 보고 --plan 의 status 로 재spawn 대상을 정한다
    - 좀비(CMD=bash)/사망(pane 소멸)/CASE-8(--agent-id 있는 claude 고아) → 재spawn 대상으로 분류
  절대_금지: SendMessage로 응답 대기 (L-331)

사전조건_2_팀_상태_확인:
  팀_존재:
    확인: mcp__oio__bash_exec("cat ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/team_name")
    존재 → 팀 재사용 (TeamCreate 스킵)
  팀_소멸:
    처리: TeamCreate 새로 생성
    설정: team_name 파일에 기록
```

### 단계별 재개

#### PLAN 재개

```yaml
PLAN_재개:
  원칙: PLAN은 증분 불가 → oplan 재spawn

  사전_확인:
    plans/oplan_*.md 존재 + 파일 내용에 TODO/파일할당 포함 + 그 계획서가 마지막 PLAN_START 이후에 수정됨:
      → ★질문 없이★ PLAN_DONE 으로 간주하고 DEV 로 진행한다.
      → 근거 1줄 출력: "📋 [oresume] 계획서 {파일} 에 TODO·파일할당 존재 — PLAN 완료로 보고 DEV 로 진행한다."
    위 세 조건 중 하나라도 확인되지 않음(판단이 서지 않음):
      → 보수적으로 oplan 재spawn (계획을 다시 세우는 쪽이 낡은 계획으로 구현하는 쪽보다 안전하다)
    plans/ 미존재 또는 내용 불완전:
      → oplan 재spawn 필수

  실행:
    1. mcp__oio__session_state(uuid="${UUID}", key="state", value="PLAN", force=True)
       # force=True 필수: oresume은 임의 중단 상태에서 재진입하므로 ALLOWED_TRANSITIONS 검증 bypass
    2. tier 확인: classification 파일에서 O2/O3/O4/O5 읽기
    3. tier별 oplan 스킬 결정:
       O2 → oplan_simple | O3 → oplan_normal | O4 → oplan_deep | O5 → oplan_debate
    4. Agent spawn (ok_pipeline 프롬프트 규격 준수)
    5. oplan 완료 후 → DEV 재개로 진행
```

#### DEV 재개 (가장 복잡)

```yaml
DEV_재개:
  절차:
    1. file_assignment.json 읽기 (mcp__oio__file_read)
       → 에이전트별 담당 파일/TODO 매핑 확인

    2. work/odev-*_result.json 읽기 (mcp__oio__file_read)
       → 에이전트별 완료 상태 확인

    3. 완료 에이전트 식별:
       status="completed" → ✅ 재spawn 불필요
       status="partial" → ⏳ 나머지 TODO만 재할당
       result 미존재 → ❌ 전체 재할당

    4. 미완료 에이전트만 재spawn:
       프롬프트_구성: |
         "PIPELINE_UUID={UUID}
          Skill('odev') 호출하여 스킬 로딩 후 실행.
          ★ 재개 모드: 이미 완료된 TODO: [{todos_completed 목록}].
          나머지 TODO [{미완료 목록}]만 구현하라.
          계획서: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/plans/oplan_*.md
          파일 할당: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/file_assignment.json"

    5. 상태 설정:
       mcp__oio__session_state(uuid="${UUID}", key="state", value="DEV", force=True)
       # force=True 필수: oresume은 임의 중단 상태에서 재진입하므로 ALLOWED_TRANSITIONS 검증 bypass

    6. Agent spawn (미완료 에이전트 수만큼)

    7. 모든 odev 완료 → TEST 재개로 진행 (ok_pipeline 로직 재활용)

  재기동_복원_경로 (Step 1 재기동_복원을 거친 경우 — DEV/TEST/DONE 공통, 위 3~6 을 대신한다):
    근거: resume_restore.py --plan 출력의 agents[] (Step 1 에서 받은 JSON 을 그대로 쓴다)
    판정별_처리:
      completed → 재spawn 하지 않는다 (work/respawn/<name>.md 도 만들어지지 않는다)
      partial   → ★같은 이름★으로 재spawn. 프롬프트 = work/respawn/<name>.md 전문
      missing   → ★같은 이름★으로 재spawn. 프롬프트 = work/respawn/<name>.md 전문
    프롬프트: work/respawn/<name>.md 는 spawn 원문 + "## 재기동 복원 컨텍스트"(마지막 지시·마지막 보고·
              완료 TODO(재수행 금지)·남은 TODO·files_modified·원본 트랜스크립트 경로·"질문 없이 이어서 진행하라")다.
              메인이 내용을 요약·재작성하지 않고 file_read 로 읽어 그대로 Agent(name=<name>, prompt=...) 에 넣는다.
              (팀원 대화 원본 재개는 공식 미지원 — https://code.claude.com/docs/en/agent-teams — 이 요약이 유일한 연속성 수단이다.)
    같은_이름_재spawn: 이전 인스턴스는 재기동으로 사라졌다. 같은 이름 재spawn 의 유휴 가드 오판은 10B B-5(teammate_idle_guard)가 해소한다.

    ★상한 처리 (팀원 9 = 메인 포함 10, 2026-10-11 사용자 지시)★:
      재spawn 이 F-AGENT-CAP("이 세션의 동시 생존 팀에이전트가 상한 9개에 도달했습니다")에 걸리면
      질문하지 않고 차단 안내에 붙은 "회수 후보" 목록을 그 순서대로 회수한 뒤 같은 spawn 을 다시 보낸다.
        1순위(완료 보고 후 유휴) → 먼저 회수한다.
        2순위(agent_keep 역라우팅·재작업 대기, result.json 완료) → 1순위로 모자랄 때 회수한다.
              회수했다면 agent_keep/<이름> 을 지우고, 필요할 때 work/<이름>_result.json 을 근거로 같은 역할을 다시 spawn 한다.
        작업 중 팀원 → ★절대 회수하지 않는다★ (후보 목록에도 오르지 않는다).
      회수 방법: 후보에게 SendMessage(to=<이름>, message={"type":"shutdown_request"}) → pane 소멸 확인 → 재시도.
      "회수 후보 없음" 이면: 남은 재spawn 은 대기열로 두고, 팀원이 끝날 때마다 하나씩 보낸다(순서 = agents[] 순서).
      근거 1줄 출력: "🚦 [oresume 상한] 회수 {이름들} → 재spawn {이름}" 또는 "🚦 [oresume 대기열] {남은 이름들}"

    출력(재spawn 마다 1줄): "🔁 [재spawn] {name} ({status}) ← work/respawn/{name}.md"
```

#### TEST 재개

```yaml
TEST_재개:
  절차:
    1. work/otest-1_result.json 읽기 (mcp__oio__file_read)
       → phases_completed 확인

    2. 미완료 Phase 식별:
       Phase1(인프라) 완료 → Phase2부터
       Phase2(구현검증) 완료 → Phase3부터
       전부 미완료 → Phase1부터

    3. otest 에이전트 재spawn:
       프롬프트_구성: |
         "PIPELINE_UUID={UUID}
          Skill('otest') 호출하여 스킬 로딩 후 실행.
          ★ 재개 모드: Phase {N-1}까지 완료됨. Phase {N}부터 시작.
          완료된 Phase: [{phases_completed 목록}]
          프로젝트 컨텍스트: 프로젝트 인프라는 INFRA.md 참조(경로는 프롬프트의 [INFRA_INJECT] 줄)"

    4. 상태 설정:
       mcp__oio__session_state(uuid="${UUID}", key="state", value="TEST", force=True)
       # force=True 필수: oresume은 임의 중단 상태에서 재진입하므로 ALLOWED_TRANSITIONS 검증 bypass

    5. Agent spawn

    6. otest 완료 → DONE 재개로 진행
```

#### DONE 재개

```yaml
DONE_재개:
  절차:
    1. work/odone-1_result.json 읽기 (mcp__oio__file_read)
       → ★Step 4 의 conv_id 대조 게이트를 먼저 적용한다 (L-670).
         conv_id 불일치 또는 부재면 잔류물이므로 substeps_completed 를 빈 목록으로 간주하고
         odone 전 서브스텝을 처음부터 수행한다.
       → 게이트 통과 시에만 substeps_completed 확인

    2. 미완료 서브스텝 식별:
       예: lesson 완료 → cleanup부터
           cleanup 완료 → docs부터
           docs 완료 → git부터

    3. odone 에이전트 재spawn:
       프롬프트_구성: |
         "PIPELINE_UUID={UUID}
          Skill('odone') 호출하여 스킬 로딩 후 실행.
          ★ 재개 모드: 완료된 서브스텝: [{substeps_completed 목록}].
          {미완료 서브스텝}부터 시작하라.
          프로젝트 컨텍스트: 프로젝트 인프라는 INFRA.md 참조(경로는 프롬프트의 [INFRA_INJECT] 줄)"

    4. 상태 설정:
       mcp__oio__session_state(uuid="${UUID}", key="state", value="DONE", force=True)
       # force=True 필수: oresume은 임의 중단 상태에서 재진입하므로 ALLOWED_TRANSITIONS 검증 bypass

    5. Agent spawn

    6. odone 완료 → FINISH 실행
```

#### FINISH 실행

```yaml
FINISH_실행:
  원칙: 메인이 직접 수행 (팀에이전트 spawn 아님)
  방법: Skill('ofinish') 직접 로딩
  절차:
    1. Skill('ofinish') 호출
    2. ofinish가 팀 정리 + 통계 + 배너 + IDLE 전환 수행
```

#### BATCH 재개 (v2 C-02 신설 — multi-phase batch 전용)

```yaml
BATCH_재개:
  적용_조건: Step 2에서 phase_batch_mode=true 판정
  목적: compact/중단으로 손실된 batch 진행을 정확히 이어받아 남은 batch 자동 완수

  핵심_원칙:
    - oresume은 current_phase_batch 파일을 직접 수정하지 않는다 (ok_pipeline의 Source of Truth 보호)
    - oresume은 checkpoint.jsonl에서 마지막 완료된 batch 번호를 읽고, file_assignment를 복원한 후 ok_pipeline을 재시작하여 복귀한다
    - ok_pipeline이 current_phase_batch를 읽어 자동으로 해당 batch부터 Auto-Loop를 재개함
    - 2PC 트랜잭션 충돌 방지: oresume은 phase_batch.lock이 존재하면 Lock 해제 대기 또는 stale Lock 감지 후 해제

  절차:
    0. phase_batch.lock 2PC 충돌 방지:
       lock_path: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/phase_batch.lock
       확인: mcp__oio__file_read(lock_path) — 존재 여부 + 생성 시각 확인
       분기:
         미존재 → Step 1로 진행
         존재 + 30분 이상 경과(stale) → 강제 해제 (mcp__oio__file_delete) + 경고 출력
           출력: "⚠️ stale phase_batch.lock 감지 ({age}분 경과). 강제 해제 후 진행합니다."
         존재 + 30분 미만 → Lock 해제 대기 (5초 간격, 최대 60초)
           타임아웃 시(질문 없음): 살아 있는 Lock 을 강제 해제하지 않는다(2PC 보호).
             "⏳ [oresume] phase_batch.lock 보유 중 — 이번 재개는 Batch 재진입을 건너뛴다. 30분 경과 시 stale 로 해제된다." 출력 후
             BATCH 재개만 중단하고 나머지 재개 절차는 계속한다.

    1. checkpoint.jsonl에서 마지막 BATCH_NEXT 이벤트의 batch 번호 추출:
       mcp__oio__bash_exec("grep BATCH_NEXT ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/checkpoint.jsonl | tail -1")
       → last_completed_batch = 해당 이벤트의 batch 번호 (N)
       BATCH_NEXT 이벤트 없음 → Batch 0 완료로 간주 (next_batch = 1)

    2. current_phase_batch 파일 값 확인 (ok_pipeline Source of Truth):
       mcp__oio__file_read(${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/current_phase_batch)
       → 파일값과 checkpoint 추출값 교차 검증
       불일치 시: checkpoint.jsonl 기준으로 판단 (current_phase_batch는 수정하지 않음 — ok_pipeline이 관리)

    3. phase_batches.json 로드:
       mcp__oio__file_read(${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/phase_batches.json)
       → total_batches, batches[].depends_on_batch 추출

    4. 재개 대상 batch 결정:
       next_batch = N + 1
       next_batch > total_batches → FINISH 실행으로 위임
       next_batch <= total_batches → 해당 batch 재진입 준비

    5. file_assignment 스냅샷 복원:
       경로_우선순위:
         ① ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/file_assignment_batch_${next_batch}.json (batch별 스냅샷)
         ② ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/file_assignment.json (fallback)
       스냅샷 없음 + fallback도 없음(질문 없음): 계획서(plans/oplan_*.md)의 배정 표 또는 agent_state/<name>.json 의
         files_owned 로 대신한다. 둘 다 없으면 보수적으로 PLAN 재개로 돌린다(배정을 추측하지 않는다).
         출력: "⚠️ [oresume] file_assignment 손상 — {대체 출처} 로 대신한다."
       복원 방법: batch별 스냅샷을 file_assignment.json으로 복사 (ok_pipeline이 읽는 경로)

    6. depends_on_batch 의존성 검증:
       for dep in batches[next_batch].depends_on_batch:
         evidence: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/evidence/batch_${dep}_summary.json 존재 확인
         미존재 → "⚠️ Batch {next_batch}는 Batch {dep}에 의존하나 summary 없음" 출력
         전부_존재 → 의존성 충족 → 재진입 허용

    7. ok_pipeline 재진입 (Auto-Loop 복귀):
       원칙: odev를 직접 spawn하지 않고, ok_pipeline을 재시작하여 4.5단계 Auto-Loop가 current_phase_batch 기준으로 자동 재개하도록 위임
       상태 설정: mcp__oio__session_state(uuid="${UUID}", key="state", value="DEV", force=True)
       # force=True 필수: oresume은 임의 중단 상태에서 재진입하므로 ALLOWED_TRANSITIONS 검증 bypass
       # current_phase_batch는 ok_pipeline/batch_transition.py가 관리 (oresume은 읽기만)
       실행: Skill('ok_pipeline') 재로딩 → 4.5단계 Auto-Loop가 current_phase_batch(=N) 기준으로 Batch N+1부터 자동 진행
       ok_pipeline 복귀 후: Auto-Loop가 남은 batch를 순차 실행 → 모든 batch 완료 시 ofinish 자동 호출

  특수값_처리:
    current_phase_batch == "PAUSE":
      출력: "⏸️ PAUSED 상태 감지. Batch {last_known}에서 일시중지됨. /ocontinue로 재개하세요."
      실행: 재개 중단 (oresume 종료)

    current_phase_batch == "ABORT":
      출력: "❌ ABORT 상태 감지. 사용자 중단됨. ofinish로 파이프라인 정리합니다."
      실행: Skill('ofinish') 직접 호출

    current_phase_batch == "DONE" or N >= total_batches:
      출력: "✅ 모든 Batch 완료. ofinish 진입."
      실행: Skill('ofinish') 직접 호출
```

### 재개 후 파이프라인 복귀

```yaml
복귀_원칙:
  - 재개된 단계 완료 후 ok_pipeline의 다음 단계로 자연스럽게 진행
  - checkpoint 기록은 기존 ok_pipeline 로직이 처리 (이미 내장됨)
  - 역라우팅도 기존 ok_pipeline 로직 그대로 적용

복귀_흐름:
  PLAN 재개 완료 → DEV spawn (ok_pipeline 2단계)
  DEV 재개 완료  → TEST spawn (ok_pipeline 3단계)
  TEST 재개 완료 → DONE spawn (ok_pipeline 4단계)
  DONE 재개 완료 → FINISH 실행
  FINISH 실행    → IDLE 전환 + 종료

ok_pipeline_로딩:
  DEV 이후 단계 재개 시: Skill('ok_pipeline') 로딩하여 나머지 파이프라인 위임
  PLAN 재개 시: oplan 완료 후 Skill('ok_pipeline') 로딩
  FINISH 재개 시: Skill('ofinish') 직접 로딩
```

---

## 주의사항

```yaml
절대_금지:
  - checkpoint 없이 중간 단계 재개 (state만으로는 서브스텝 식별 불가 → 해당 단계 처음부터)
  - 완료된 에이전트 재spawn (리소스 낭비 + 중복 작업)
  - STALE 상태에서 외부 변경을 무시한 강제 재개 (교집합 담당 팀원 재검토 강등 없이 재개 — Step 5 참조)
  - 사용자에게 답변을 요구해 재개를 멈추는 것 (AskUserQuestion — 2026-10-11 사용자 지시. 판단은 보수적 자율로 한다)
  - 재기동 복원 전에 Step 4 conv_id 게이트 실행 (새 conv_id 로 완료 결과가 전부 버려진다)
  - resume_restore.py 결과 없이 재기동 뒤 팀원을 '활성' 으로 판정 (pane 번호 재사용 — boot_changed=true 면 전원 사망)
  - oresume을 팀에이전트로 spawn (메인 전용)
  - REROUTE 무효화 적용 없이 checkpoint 파싱

권장:
  - compact 후 항상 /oresume 실행
  - 재개 전 진행도 시각화로 현재 상태 확인
  - STALE 판정 시 교집합 담당 팀원 재검토로 재개 (리셋은 checkpoint 를 잃고, 무시한 강제 재개는 충돌 위험)
  - 재기동·WSL 종료 뒤에는 메인 첫 행동으로 /oresume (SessionStart 가 "🔁 [재기동 복원 가능]" 을 출력한다)
  - 복수 파이프라인 발견 시 오래된 것은 /ofinish로 정리 후 재개

역할_경계:
  oresume: 중단된 파이프라인을 checkpoint 기반으로 정확한 지점부터 재개
  ofinish: pane 진단 + 물리 정리 + TeamDelete (수동 정리: /ofinish 독립 실행)

  ocontext: 컨텍스트(CLAUDE.md/PROJECT.md) 새로고침 (파이프라인 재개 아님)
```
