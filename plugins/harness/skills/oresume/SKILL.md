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
방법: mcp__oio__bash_exec로 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/*/state 순회
스크립트: |
  UUID=""
  CANDIDATES=()
  # §(a) 자기 세션 UUID 확정 (쓰기 경계 기준)
  # oresume은 자기 세션 파이프라인만 재개 가능 — 타 세션 state 쓰기는 §(a) 위반
  SELF_UUID=$(source "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/lib/session_id.sh" 2>/dev/null && resolve_uuid "" 2>/dev/null && echo "${UUID:-}" || echo "")
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
    _state=$(bash -c 'source "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/lib/state_machine.sh" 2>/dev/null; state_read "'"${_dir}"'state"' 2>/dev/null | awk '{print $1}')
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

분기:
  0개: "✅ 재개할 파이프라인 없음. /oo로 새 작업을 시작하세요." 출력 후 종료
  1개: 해당 UUID 자동 선택
  복수: AskUserQuestion으로 사용자에게 UUID 선택 요청
    형식: "재개할 파이프라인을 선택하세요:\n  1. UUID={uuid1} 상태={state1}\n  2. UUID={uuid2} 상태={state2}"

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

  5_후속_판단:
    전원_사망_또는_완료: checkpoint + work/ 파일 기반 재개 (Step 4~8)
    일부_활성_진행중:
      - 완료 판정된 에이전트 → 재spawn 불필요 (shutdown_request 발송)
      - 진행중 에이전트 → 사용자에게 선택지 제시 (계속 대기 vs /ofinish로 강제 정리)
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
  처리: AskUserQuestion으로 3가지 선택지 제시
    선택지:
      1. 리셋+재시작: checkpoint 삭제 + state→IDLE + "/oo로 새로 시작하세요" 안내
      2. 강제 재개: 외부 변경 무시하고 재개 (⚠️ 충돌 위험)
      3. 수동 확인: 사용자가 직접 코드 확인 후 결정 (/oresume 재호출 안내)

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
    - 활성 + 미완료 판정 → 사용자에게 "계속 대기 vs /ofinish 강제 정리" 선택지 제시
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
    plans/oplan_*.md 존재 + 파일 내용에 TODO/파일할당 포함:
      → PLAN_DONE으로 간주 가능
      → "계획서가 이미 존재합니다. PLAN 완료로 간주하고 DEV로 진행할까요?" AskUserQuestion
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
          프로젝트 컨텍스트: Skill('oinfra_{project}') 호출"

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
          프로젝트 컨텍스트: Skill('oinfra_{project}') 호출"

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
           타임아웃 시: "⚠️ phase_batch.lock이 해제되지 않습니다. 수동 확인 필요." AskUserQuestion

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
       스냅샷 없음 + fallback도 없음: "⚠️ file_assignment 손상" AskUserQuestion
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
  - STALE 상태에서 사용자 확인 없이 강제 재개
  - oresume을 팀에이전트로 spawn (메인 전용)
  - REROUTE 무효화 적용 없이 checkpoint 파싱

권장:
  - compact 후 항상 /oresume 실행
  - 재개 전 진행도 시각화로 현재 상태 확인
  - STALE 판정 시 리셋+재시작 권장 (강제 재개는 충돌 위험)
  - 복수 파이프라인 발견 시 오래된 것은 /ofinish로 정리 후 재개

역할_경계:
  oresume: 중단된 파이프라인을 checkpoint 기반으로 정확한 지점부터 재개
  ofinish: pane 진단 + 물리 정리 + TeamDelete (수동 정리: /ofinish 독립 실행)

  ocontext: 컨텍스트(CLAUDE.md/PROJECT.md) 새로고침 (파이프라인 재개 아님)
```
