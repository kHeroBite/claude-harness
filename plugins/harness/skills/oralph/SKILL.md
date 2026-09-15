---
name: oralph
description: "ok 파이프라인으로 구현 후 자체 반복 검증 루프로 자동 완수를 보장하는 독립 스킬. 호출 순서: ointaug → oralph → ok → 내장 검증 루프. '/oralph <요청>' 형태로 호출. ok(oplan→odev→otest→odone→ofinish) 완료 후 oralph 자체 검증 루프가 합격/최대반복까지 FINISH→DEV 재실행을 오케스트레이션. ofinish Step 8 gate가 oralph_active 플래그를 감지하여 IDLE 전환 보류."
invocation:
  user_callable: true
  pipeline_callable: false
  called_by: [사용자, ointaug 이후]
  calls: [ok]
---
# oralph — ointaug → ok → 내장 검증 루프 독립 스킬 (v4.0)

> **목적**: ok 파이프라인으로 구현을 완료한 뒤, oralph 자체 검증 루프로 자동 완수를 보장한다.
> **v4.0 변경**: ralph-loop 의존 제거. 반복 검증을 oralph 내부에서 직접 수행하여 세션 격리를 확실히 한다.
> **호출 순서**: ointaug(질의 확장) → oralph(초기화) → ok(구현) → oralph 내장 검증 루프
> **연동**: ofinish Step 8 gate가 oralph_active 플래그를 감지하여 IDLE 전환 보류 → 내장 검증 루프 진입.

## 호출 분기

```yaml
사용자_직접_호출 (/oralph 슬래시 명령):
  판단_기준: system-reminder에 `💬 [IDLE 직접처리]` 또는 `⚡ [슬래시 명령] oi 바이패스 — /oralph` 컨텍스트
  동작: 팀에이전트 spawn → 팀에이전트가 Phase 0/1/2 전체 실행
  절차:
    1. entry_tier=OK 기록 (IDLE 유지)
       mcp__oio__session_state(uuid="${UUID}", key="entry_tier", value="OK")
    2. TeamCreate (oralph 내부에서 ok 파이프라인이 다시 TeamCreate를 시도할 수 있으나, oralph-worker가 별도 팀으로 격리)
    3. Agent 팀에이전트 spawn:
       Agent(subagent_type="general-purpose", team_name="{팀명}", name="oralph-worker",
             mode="bypassPermissions",
             prompt="Skill('oralph') 로딩. 내부_호출=true. Phase 0/1/2 전체 실행.
                     사용자 요구사항: {원문}. PIPELINE_UUID={UUID}")
    4. 팀에이전트가 완료(합격/최대반복/실패) 보고 → 결과를 사용자에게 그대로 전달
    5. 완료 후 ofinish(경량 — TeamDelete + IDLE 복원)
  주의:
    - 팀에이전트 spawn 시 PIPELINE_UUID 전달 필수 (Phase 0 UUID 결정에 사용)
    - 팀에이전트 내부에서는 내부_호출=true 플래그로 Phase 0/1/2를 직접 실행
    - 메인은 ok 파이프라인을 직접 실행하지 않음 — 팀에이전트가 ok를 호출
  state_원칙: IDLE 유지 (state=PLAN/DEV/TEST 설정 절대 금지)

내부_호출 (내부_호출=true 플래그 수신 시 또는 다른 스킬에서 Skill('oralph') 호출 시):
  동작: Phase 0/1/2 직접 실행 (기존 프로세스 그대로)
  비고: 현재 oralph를 내부 호출하는 스킬은 없음 (방어적 분기). 팀에이전트가 자기 컨텍스트에서 직접 ok 호출 + 검증 루프 수행.
```

## 프로세스 개요

```
사용자: /oralph <요청>
  │
  ▼ (UserPromptSubmit.sh → ointaug 발동)
[ointaug] 질의 확장 → Skill('oralph') 호출
  │
  ▼
[Phase 0] oralph 초기화
  - 검증 기준 도출 (사용자 요청에서)
  - oralph_active 플래그 파일 작성
  │
  ▼
[Phase 1] ok 파이프라인 실행
  Skill('ok') 로딩 → oplan → odev → otest → odone → ofinish
  ofinish Step 8 gate 감지 → IDLE 전환 보류 → 검증 루프 진입 안내
  │
  ▼
[Phase 2] oralph 내장 검증 루프 (ralph-loop 의존 없음)
  ok 파이프라인 완료 직후 oralph가 직접 검증 수행
  검증 조건 확인 (criteria_detail vs 실제 빌드/테스트/기능 결과)
  ├─ 합격 → oralph_active 삭제 → state → IDLE → 완료 배너
  └─ 불합격 + 잔여 iteration → current_iteration++ → FINISH→DEV → odev→otest→odone→ofinish → gate 재진입
  └─ 불합격 + max 도달 → oralph_active 삭제 → state → IDLE → 미완료 보고
```

---

## Phase 0: oralph 초기화

```yaml
실행_시점: Skill('oralph') 로딩 직후, Skill('ok') 호출 전

# ⚠️ ointaug 호환 주의: oralph는 슬래시 명령이지만 ointaug가 발동된다. ointaug 확장 후 Skill('oralph')가 즉시 호출되므로 Phase 0 실행 후 바로 Skill('ok')를 호출 가능하다.
# bash_exec 사용 금지 (ointaug 규칙 충돌 우회 — UUID는 system-reminder에서 직접 읽음). 단, 내부_호출=true 컨텍스트(팀에이전트)에서는 bash_exec 사용 가능.

절차:
  0. IDLE 상태 확인 (선행 필수):
     UUID = system-reminder의 `🆔 [UUID]` 값 (직접 읽기 — bash_exec 금지)
     STATE = system-reminder의 `✅ [ok 활성] 파이프라인 {STATE}` 또는 `💬 [IDLE 직접처리]` 텍스트로 판독
     비IDLE(OK/PLAN/DEV/TEST/DONE/FINISH) 이면:
       출력: "⛔ [oralph] 파이프라인 활성 중(${STATE}) — oralph는 IDLE 상태에서만 시작 가능합니다."
             "현재 파이프라인을 종료(ofinish/oinit) 후 다시 호출하세요."
       즉시 종료 (Skill('ok') 호출 금지)

  1. UUID 확인:
     system-reminder의 `🆔 [UUID] {값}` 텍스트에서 직접 추출
     (bash_exec 불필요 — UserPromptSubmit.sh가 매 메시지마다 UUID를 system-reminder로 출력함)

  2. 검증 기준 도출 (사용자 요청 텍스트에서):
     - 빌드 성공 여부 (소스코드 변경 시 기본 포함)
     - 테스트 통과 여부 (테스트가 있는 경우)
     - 사용자 요청의 핵심 기능 동작 확인 (기능 명세에서 추출)

  3. oralph_active 플래그 파일 작성:
     mcp__oio__file_write(
       path="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/oralph_active",
       content='{
         "session_uuid": "{UUID}",
         "criteria": "{검증 기준 1줄 요약}",
         "criteria_detail": [
           "{조건 1}",
           "{조건 2}",
           "{조건 3}"
         ],
         "max_iterations": 5,
         "current_iteration": 0,
         "original_request": "{사용자 원문 요청}"
       }',
       overwrite=true
     )
     # session_uuid 필드: cross-session 오염 방지용 무결성 체크. Phase 2에서 system-reminder UUID와 대조.
     # [deprecation] oralph_active 파일은 1주기 폴백 유지. 정식 플래그는 status=RALPH (status_add/status_has/status_remove).

     # status 축에 RALPH 등록 (정식 방식 — deprecation window 동안 oralph_active 파일과 병행)
     bash -c 'source ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/lib/state_machine.sh; status_add "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/status" RALPH'

  4. 출력:
     🔁 [oralph] 초기화 완료
        UUID: {UUID}
        검증 기준: {criteria}
        최대 반복: 5회
        → ok 파이프라인 시작
```

---

## Phase 1: ok 파이프라인 실행

```yaml
절차:
  Skill('ok')  # ok/SKILL.md 전체 절차 실행

주의:
  - ok 파이프라인의 tier 결정(o2~o5)은 ok가 자율적으로 판단한다
  - oralph는 ok 파이프라인에 개입하지 않는다
  - ofinish Step 8에서 oralph_active 감지 시 IDLE 전환 보류 + 검증 루프 안내 출력
  - entry_tier=OK는 ok 진입 시 ok/SKILL.md pipeline_state_설정에서 자동 기록됨 — oralph 별도 처리 불필요

ok_차단_절대_금지:
  - ok가 "⚠️ 파이프라인 진행 중 차단" 출력 시 → oralph 전체 중단 (Phase 0 IDLE 체크 실패가 원인)
  - "ok 파이프라인이 이미 활성 중이므로 직접 분석 진행" 같은 임의 판단 절대 금지
  - ok 차단 시 oralph_active 삭제 후 사용자에게 IDLE 상태에서 재호출 안내 출력
  - ok를 건너뛰고 분석/구현을 직접 수행하는 행위는 oralph 설계 위반

ofinish_gate_출력_예시:
  ⏳ [oralph] ofinish 완료 — oralph 내장 검증 루프 진입
     검증 기준: {criteria}
     Iteration: {current_iteration + 1} / {max_iterations}
  → oralph Phase 2 (내장 검증 루프) 즉시 수행

  # 이 메시지를 보면 즉시 아래 Phase 2(oralph 내장 검증 루프)를 실행한다
```

## Phase 2: oralph 내장 검증 루프 (독립 구현, ralph-loop 의존 없음)

ofinish Step 8 gate 출력 직후 메인 에이전트가 직접 수행한다. 외부 스킬(ralph-loop) 호출 금지.

```yaml
진입_조건: ofinish가 "→ oralph Phase 2 (내장 검증 루프) 즉시 수행" 출력 후

설계_원칙:
  - oralph는 독립 스킬. 외부 반복 루프(ralph-loop 등) 호출 금지
  - 모든 상태 파일은 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/ 하위에만 저장 (세션 격리)
  - 다른 세션의 UUID 탐색/재사용 절대 금지 — cross-session 오염 방지
  - 현재 세션 UUID는 system-reminder `🆔 [UUID]` 값 또는 oralph_active.session_uuid에서 확정

절차:
  # Step 1: 상태 로드 (현재 세션 UUID 전용)
  UUID = system-reminder의 `🆔 [UUID]` 값 (직접 읽기)
  oralph_data = mcp__oio__file_read(path="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/oralph_active")
  criteria_detail = oralph_data["criteria_detail"]
  current_iter = oralph_data["current_iteration"]
  max_iter = oralph_data["max_iterations"]

  # Step 1.5: goal.json 조건부 hard gate (locked=true 시 acceptance 전수 PASS 게이트)
  # 조건: goal.json 존재 AND locked==true 일 때만 강제. 그 외 → 기존 criteria_detail만 사용.
  goal_gate:
    _GOAL_PATH = "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/goal.json"
    if file_exists(_GOAL_PATH):
      _LOCKED = bash_exec(f"jq -r '.locked // false' {_GOAL_PATH} 2>/dev/null || echo false")
      if _LOCKED == "true":
        _ACCEPTANCE = bash_exec(f"jq -c '.acceptance[]' {_GOAL_PATH} 2>/dev/null")
        # goal.acceptance[] 전수를 criteria_detail에 append (기존 항목 유지)
        for item in _ACCEPTANCE:
          if item not in criteria_detail:
            criteria_detail.append(f"[goal.acceptance] {item.get('check', str(item))}")
        # 이후 Step 2에서 통합된 criteria_detail 기준으로 판정 수행
    # goal.json 부재 또는 locked=false → criteria_detail 무변경 (기존 동작 100% 보존)

  # Step 2: 검증 수행 (criteria_detail 항목별 판정)
  검증_방법:
    - 빌드 성공 여부: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/evidence/build_result 또는 otest_build 로그 확인
    - 테스트 통과 여부: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/evidence/test_result 또는 otest_verify 산출물 확인
    - 사용자 요청 핵심 기능: 해당 기능 트리거 + 결과 로그/응답 확인 (HTTP 요청, CLI 실행, UI 상태 등)

    각 항목 판정 결과를 pass/fail로 수집:
      results = []
      for item in criteria_detail:
        status = "pass" if <조건 충족> else "fail"
        results.append({"item": item, "status": status, "evidence": "..."})

  # Step 3: 분기
  모두_pass:
    1. mcp__oio__file_delete(path="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/oralph_active")
    2. bash -c 'source ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/lib/state_machine.sh; status_remove "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/status" RALPH'
    3. mcp__oio__session_state(uuid="${UUID}", key="state", value="IDLE")
    4. 출력:
       ✅ [oralph] 검증 합격 (Iteration {current_iter + 1} / {max_iter})
          합격 항목: {results 요약}
          → state=IDLE 복귀, 작업 완료

  일부_fail AND (current_iter + 1) < max_iter:
    1. current_iter += 1
    2. mcp__oio__file_write(
         path="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/oralph_active",
         content=json.dumps({...oralph_data, "current_iteration": current_iter}),
         overwrite=true
       )
    3. mcp__oio__session_state(uuid="${UUID}", key="state", value="DEV")
    4. 재진입 프롬프트 구성:
       retry_prompt = f"""
       oralph 검증 실패 — {current_iter + 1}/{max_iter}회차 재시도.
       원본 요청: {oralph_data['original_request']}
       실패 항목: {[r for r in results if r['status'] == 'fail']}
       → odev로 실패 항목 수정 후 otest → odone → ofinish 재진입
       """
    5. Skill('ok_pipeline') 재호출 또는 odev 팀에이전트 재spawn
       (ok_pipeline이 tier/계획서/team_name을 재활용하므로 가장 안전)

  모두_fail OR (current_iter + 1) >= max_iter:
    1. mcp__oio__file_delete(path="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/oralph_active")
    2. bash -c 'source ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/lib/state_machine.sh; status_remove "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/status" RALPH'
    3. mcp__oio__session_state(uuid="${UUID}", key="state", value="IDLE")
    4. 출력:
       ⚠️ [oralph] 최대 반복({max_iter}) 도달 — 미완료 보고
          실패 항목: {fail 항목들 + 마지막 evidence}
          → state=IDLE 복귀, 수동 개입 필요

금지_사항:
  - Skill('ralph-loop:ralph-loop') 호출 절대 금지 (독립 스킬화 완료, v4.0)
  - setup-ralph-loop.sh 스크립트 참조 금지
  - CLAUDE_CODE_SESSION_ID 환경변수 의존 금지 (UUID는 system-reminder/oralph_active에서 직접 획득)
  - 다른 세션의 session-env/{타UUID}/ 디렉토리 스캔 금지
```

---

---

## 호출 예시

```
/oralph LoginForm 유효성 검사 기능을 추가하라. 이메일 형식 체크 + 비어있으면 오류 표시.
```

내부 동작:
1. Phase 0: oralph_active 작성 (criteria: "빌드 성공 + LoginForm 이메일 유효성 검사 동작 확인")
2. Phase 1: Skill('ok') → oplan(o3) → odev → otest → odone → ofinish
3. ofinish Step 8 gate: oralph_active 감지 → IDLE 보류 → 검증 루프 안내
4. Phase 2: 조건 확인 → 합격 시 IDLE / 실패 시 FINISH→DEV 재실행

---

## 세션 격리 원칙 (충돌 없음 — 멈추거나 우회 금지)

```yaml
완전_격리_보장:
  근거: 모든 파이프라인 상태 파일이 session-env/${UUID}/ 하위에 격리됨
  대상_파일: state, oralph_active, evidence/, plans/, checkpoint.jsonl, team_name 등
  다른_세션: 별도 UUID → 경로 자체가 겹치지 않음 → 파일 충돌 불가

  절대_금지_판단:
    - "다른 세션이 활성 중이라 멈추겠습니다" → 금지
    - "다른 파이프라인과 충돌 우려로 우회합니다" → 금지
    - "다른 세션 DEV 상태라 테스트를 건너뜁니다" → 금지

  필수_행동:
    - system-reminder에 다른 UUID의 활성 파이프라인이 보여도 oralph는 독립적으로 전 단계 실행
    - 충돌 경고 출력 후 진행 여부를 사용자에게 묻는 행위 금지
    - Phase 0 → Phase 1 → Phase 2 전 단계를 멈춤 없이 완전 실행
```

## 주의 사항

```yaml
절대_금지:
  - Phase 0(초기화) 없이 Skill('ok') 호출 (oralph_active 없으면 gate 미작동)
  - Phase 2 실행 전 state → IDLE 전환 (FINISH 유지 필수)
  - 검증 없이 합격 선언
  - oralph_active 삭제를 ofinish가 수행 (Phase 2-PASS/FAIL만 삭제 권한 보유)

oralph_active_파일_형식:
  경로: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/oralph_active
  형식: JSON
  필드:
    session_uuid: 이 oralph 세션의 UUID (Phase 2에서 무결성 체크용 — 현재 세션 UUID와 대조)
    criteria: 검증 기준 1줄 요약 (ofinish gate 출력용)
    criteria_detail: 조건별 상세 목록 (Phase 2 검증용)
    max_iterations: 최대 반복 횟수 (기본 5)
    current_iteration: 현재 반복 회차 (0부터 시작)
    original_request: 사용자 원문 요청 (odev 재spawn 프롬프트용)

취소:
  - /oinit: ok 파이프라인 + oralph 루프 전체 중단
  - 수동 종료 후 state 잔류 시: mcp__oio__session_state로 IDLE 강제 설정
            + oralph_active 수동 삭제
```
