---
name: otest_verify
description: "Phase 2 구현 검증 라우터 — otest_make + otest_ui + otest_log. acceptance_criteria 대조. otest에서 2차로 호출."
invocation:
  user_callable: false
  pipeline_callable: true
  called_by: ["otest"]
  calls: ["otest_make", "otest_ui", "otest_log"]
---
# otest_verify — Phase 2 구현 검증 라우터

> Phase 2 전용 — otest 에이전트에서 2차로 호출 (otest_infra 이후)

## 역할 (v4.3 — Phase 2 구현 검증 라우터)

otest_verify는 "계획대로 구현됐나?"를 검증하는 Phase 2 라우터.
기존 "otest→odone 전환 게이트" 역할은 otest_evidence로 이관됨.

```yaml
실행_순서:
  1. acceptance_criteria.json 로드 (oplan이 생성, immutable)
  2. Skill('otest_make') — Backend 검증
     category=backend|api|db 항목 auto_script 실행
     증거: evidence/make_ok
     ★goal 사이클(goal.json locked + cNNN_gate.py)★: 종료 마커 전에 반드시 1회 실행(otest_make SKILL "goal 체계 사이클" 절)
       python3 .claude/skills/otest_make/scripts/verify_crud_executed.py --uuid ${PIPELINE_UUID} --emit-from-goal --before-stage odone
       (--before-stage odone 는 판정 시점을 odone 진입 전으로 고정하기 위해 명시한다.)
       rc 0=make_ok(PASS) / 1=make_partial(→ otest_done 은 "PARTIAL"+미통과 id) / 3=판정불가(마커 금지·재실행)
  3. Skill('otest_ui') — Frontend 검증 (UI 변경 시)
     category=frontend 항목
     otest_winforms_bg(WinForms 기본) / otest_playwright / otest_ux 중 선택
     증거: evidence/ui_test_done
  4. Skill('otest_log') — 런타임 로그 분석 [2차]
     증거: evidence/log_analysis_ok
  5. 스냅샷 저장: test_snapshot_v{N}.json
  6. auto/ROOF 잔여 계약 검증 (§ "auto/ROOF DONE 전 잔여 계약 검증" 참조 — 1~5 전부 PASS 후에만 수행)

결과:
  전부 PASS → "otest_verify PASS" 반환
  FAIL → 실패 상세 + 역라우팅 권고 반환

tier별:
  o2: 미실행 (obr만)
  o3: 필수
  o4: 필수
  o5: 필수 (otest_ui 강제)
```

## 철칙

```
신선한 검증 증거 없이 완료 주장 금지
검증 명령어 실행 안 했으면 통과 주장 불가
```

## Gate Function 5단계

```
상태 주장 또는 완료 표현 전:

1. IDENTIFY: 이 주장을 증명하는 명령어는?
2. RUN: 전체 명령어 실행 (신선하게, 완전히)
3. READ: 전체 출력, 종료 코드 확인, 실패 수 세기
4. VERIFY: 출력이 주장 확인하나?
   - NO → 증거와 함께 실제 상태 진술
   - YES → 증거와 함께 주장 진술
5. CLAIM: 그런 다음에만 주장하기

단계 건너뛰기 = 검증 아님
```

## Red-Green Cycle

```yaml
필수_순서:
  1. 수정 전 실패 상태 확인 (Red)
  2. 수정 적용
  3. 수정 후 성공 상태 확인 (Green)
  4. 양쪽 증거 모두 필수
```

## 검증 필요 항목

| 주장 | 필요한 증거 | 불충분한 것 |
|------|-----------|-----------|
| 테스트 통과 | 테스트 출력: 실패 0 | "통과해야 함" |
| 빌드 성공 | 빌드 출력: 종료 0 | "린터 통과" |
| 버그 수정 | 원본 증상 테스트 통과 | "코드 변경함" |
| 요구사항 충족 | 줄별 체크리스트 각각 검증 | "테스트 통과" |
| 에이전트 완료 | VCS diff 확인 + 변경 검증 | 에이전트 "성공" 보고 |

## Red Flags — 중단

- "해야", "아마", "~처럼 보임" 사용
- 검증 전 만족 표현 ("훌륭!", "완벽!", "완료!")
- 검증 없이 커밋/푸시 시도
- 에이전트 성공 보고 맹목 신뢰
- "딱 이번만" 생각

## 합리화 방지

| 변명 | 현실 |
|------|------|
| "이제 통할 거야" | 검증 실행하라 |
| "확신해" | 확신 ≠ 증거 |
| "딱 이번만" | 예외 없음 |
| "에이전트가 성공이래" | 독립적으로 검증 |
| "피곤해" | 피로 ≠ 변명 |

## Layer 2 강화검증 (v4.2)

> **기존 역할 이관**: "otest→odone 전환 게이트" 역할은 **otest_evidence**로 이관됨. 이 섹션은 Phase 2 구현 검증 내 강화 검증임.

```yaml
Layer_2_강화검증 (v4.2):
  1. evidence/make_ok 내용 검증:
     - criteria_results 배열 존재
     - must 항목 전부 status=PASS
     - auto_script_exit_code 전부 0
     - canary_result = FAIL (정상)
  2. evidence/build_ok 내용 검증:
     - exit_code=0
     - build_log_hash 존재 (실제 빌드 수행 증거)
  3. auto_script 재실행 (spot check):
     - must 항목 중 랜덤 2개 선택 → auto_script 재실행
     - evidence의 결과와 일치하지 않으면 → 전체 FAIL + 역라우팅
  4. Evidence Freshness:
     - 각 evidence 파일 mtime > 해당 phase 시작 시각
     - 이전 역라우팅 사이클의 잔류 evidence 재사용 감지

검증_실패_시:
  Layer_2 FAIL → otest에 FAIL 보고 → 역라우팅 (otest 대기 유지)
```

## auto/ROOF DONE 전 잔여 계약 검증 (신규 — 2026-08-29)

> 사용자 요청: "done단계 진입할때 auto나 ralph인지를 체크하고... 남은작업이 있다면
> 다시 plan단계로 되돌려서 마무리 될수있도록". 이 섹션은 실행_순서 6번 항목의 상세다.
> 대상 밖(auto/ROOF 아닌 일반 세션)은 아래 절차 전체가 무조건 즉시 스킵되며
> 기존 otest_verify 동작에 영향이 없다.
>
> 물리 안전망: `PreToolUse_done_gate.sh`(hook)가 이 절차를 건너뛰고 바로
> state=DONE을 쓰는 비정상 경로를 최종 차단한다. 정상 경로는 이 섹션이 먼저 잡는다.

```yaml
0_대상_판정 (최우선 — 해당 없으면 즉시 스킵):
  SESSION_DIR = "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}"
  AUTO_ON  = SESSION_DIR/auto 파일 존재 AND 내용 == "ON"
  ROOF_ON = SESSION_DIR/status 파일에 "ROOF" 토큰 존재 (생성값은 ROOF. 검사는 구 "RALPH" 토큰도 인식 — ROOF-COMPAT, deprecation window 1주기)
             (bash -c 'source ${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/state_machine.sh;
                       status_has "${SESSION_DIR}/status" ROOF' — rc 확인 필수, 2>/dev/null 금지.
              status_has 는 ROOF/RALPH 별칭 양쪽 인식. ROOF-COMPAT)
  AUTO_ON == false AND ROOF_ON == false → 이 섹션 전체 스킵, 기존 흐름대로 진행

1_goal_json_판정 (F-OTO-2/oroof Phase 2와 동일 알고리즘 재사용):
  GOAL = SESSION_DIR/goal.json
  GOAL 부재 → 이 단계 스킵(계약 문서 없음. F-OTO-1이 별도로 세션 종료 시 차단함)
  GOAL 존재 + locked==false → 이 단계 스킵(계약 미확정)
  GOAL 존재 + locked==true:
    - acceptance[] 중 status가 blocked/blocked_by가 아닌 항목만 대상
      (blocked/blocked_by는 fail로 세지 않는다 — goal/SKILL.md §3.2, oto와 동일 원칙)
    - auto_script 있는 항목: 공용 CLI 로 실행한다 (직접 bash -c/eval 금지 — 세션 경로 재매핑·UNDET 처리 내장):
        bash "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/goal_autoscript_run.sh" --goal "$GOAL" --before-stage odone; _GRC=$?
        (실행부가 GOAL_SESSION_DIR·GOAL_UUID 를 넘긴다)
        --before-stage odone: DONE 이전 판정이므로 valid_after:"odone" 항목(커밋·릴리스 등 odone 이후에야 생기는 산출물)은 판정 대상에서 뺀다. ofinish 는 odone 이후라 이 옵션 없이 전부 판정한다.
        --before-stage 로 1건 이상 제외한 뒤 남은 판정 대상과 blocked 가 모두 0건이면 `DEFERRED N건` 1행을 출력하고 rc=0 이다 (미룬 항목은 ofinish 가 다시 전수 판정한다 — PASS 가 아니라 판정 유예다).
        rc 가 0 이 아니면 전부 미통과 (1=FAIL, 3=UNDET, 127=lib 부재 포함). 전 항목 blocked 로 open 0건이면 rc=0.
        PASS 행만 pass 이고, FAIL 행은 fail_items 에 실측 사유로,
        UNDET 행(및 rc=3·127 의 비정상)은 fail_items 에 "판정불가" 사유로 넣는다 (PASS 로 취급 금지).
    - auto_script 없는 항목: 기계 판정 불가 — criteria_detail(2_roof_판정)에서 자연어로 흡수

2_roof_판정 (oroof_active 존재 시 — ROOF_ON인 경우):
  OROOF_FLAG = SESSION_DIR/oroof_active (또는 oroof_active.json 폴백 — ofinish Step 8과 동일 규칙)
  ROOF-COMPAT(deprecation window 1주기): 구 세션은 oralph_active / oralph_active.json 도 같은 플래그로 인식한다 (생성은 oroof_active 만)
  criteria_detail[] 각 항목을 LLM이 직접 판정 (빌드/테스트/기능 동작 증거 확인 —
  otest_verify가 이미 수행한 otest_make/otest_ui/otest_log 결과를 재사용 가능)

3_종합_판정:
  fail_items = (1의 auto_script fail 항목) + (2의 criteria_detail fail 항목)
  fail_items가 비어있음 → "DONE 진입 허용" (아래 4~6 스킵, 정상 종료)
  fail_items가 1개 이상 → 아래 4~6 수행 (DONE 진입 차단 + PLAN 재진입 요청)

4_무한루프_방지 (신규 카운터 금지 — oroof_active 재사용):
  current_iteration = OROOF_FLAG.current_iteration (없으면 0)
  max_iterations   = OROOF_FLAG.max_iterations (없으면 5)
  current_iteration >= max_iterations 인 경우:
    → "DONE 진입 허용"으로 전환 (더 이상 되돌리지 않음)
    → 단, otest에 "⚠️ 최대 반복 도달 — 잔여 fail 항목 있으나 강제 진행" 경고와
       fail_items 목록을 함께 전달 (odone이 최종 보고에 반영할 수 있도록)
    → next_action.json 작성은 otest가 아니라 ofinish 직전(odone 이후) 메인 책임 —
       oto SKILL.md "완주 불가 항목 처리"와 동일 원칙 재사용 (신규 로직 아님)
  current_iteration < max_iterations 인 경우: → 5로 진행

5_잔여_항목_컨텍스트_생성 (PLAN 재진입 시 "전체 재계획"이 아닌 "잔여 항목 보완"임을 명시):
  경로: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/plans/plan_resume_context.json
  내용:
    {
      "trigger": "done_gate_residual",
      "iteration": {current_iteration + 1},
      "max_iterations": {max_iterations},
      "fail_items": [
        {"id": "...", "desc": "...", "evidence": "실측 실패 근거(auto_script 출력 또는 판정 사유)"}
      ],
      "instruction": "goal.json/oplan 원본 계획을 처음부터 다시 세우지 말고,
                       위 fail_items만 대상으로 보완 계획을 수립하라.
                       기존 계획서(oplan_*.md)와 goal.json은 그대로 유효하다."
    }
  쓰기_도구: mcp__oio__file_write (overwrite=true)
  이유: oplan_normal Phase 0이 기존 goal.json을 시드로만 쓰고 재생성을 건너뛰므로
        (goal/SKILL.md §2 호출자_1 — locked=true 시 write_guard.sh F-GOAL-1이 재생성
        자체를 물리 차단) 계획 전체가 재수립될 위험은 없다. 이 파일은 oplan에게
        "무엇이 남았는지"만 추가로 알려주는 보조 컨텍스트다.

6_evidence_마커_처리 (다음 라운드 otest 건너뛰기 방지):
  대상: SESSION_DIR/evidence/otest_done, evidence/make_ok, evidence/ui_test_done,
        evidence/log_analysis_ok (이번 라운드에서 생성된 것들)
  방침: 삭제한다 (보존하지 않는다).
  이유: 남겨두면 otest_done_guard.sh가 "이미 otest 실행됨"으로 오판해
        다음 PLAN→DEV→TEST 라운드에서 otest를 건너뛰고 odone으로 직행할 위험이 있다
        (otest_done_guard.sh는 evidence 존재 여부만 보고 mtime이 pipeline_start_time
        이후인지만 검사하므로, 삭제하지 않으면 "잔류 evidence" 오판정을 유발한다).
        이력 손실 우려는 test_snapshot_v{N}.json(스냅샷, 삭제 대상 아님)이 상쇄한다 —
        몇 번째 라운드에 무엇이 실패했는지는 스냅샷 + plan_resume_context.json으로 추적 가능.
  삭제_도구: mcp__oio__file_delete (개별 파일별로— 존재하지 않는 파일 삭제 시도는 실패해도 무시)

7_보고 (otest → ok_pipeline/메인 — otest는 state를 직접 못 바꾼다):
  otest가 SendMessage(to: "team-lead", message: "...")로 보고:
    "⛔ [otest] auto/ROOF 잔여 계약 미충족 — DONE 진입 보류, PLAN 재진입 필요.
     실패 항목: {fail_items 요약}
     Iteration: {current_iteration + 1}/{max_iterations}
     plan_resume_context.json 작성 완료 — oplan 재spawn 시 이 파일을 프롬프트에 포함할 것."
  ok_pipeline(메인) 처리 (본 문서가 아닌 ok_pipeline/SKILL.md "otest 완료 후" 절차가 담당):
    1. mcp__oio__session_state(uuid, key="state", value="PLAN")
    2. current_iteration += 1을 oroof_active(or oroof_active.json, 구 세션은 oralph_active(.json) — ROOF-COMPAT)에 반영
    3. oplan 재spawn — 프롬프트에 plan_resume_context.json 경로 포함
       ("Skill('oplan_normal') 로딩 전 plan_resume_context.json을 읽고
         fail_items만 대상으로 보완 계획을 세워라. 전체 재계획 금지.")
    4. oplan 완료 후 odev→otest 정상 재진입 (ok_pipeline 기존 흐름)

금지_사항:
  - otest가 직접 mcp__oio__session_state로 state를 PLAN으로 바꾸는 행위
    (state 관리는 메인 전용 — phase_guard.sh L-268 원칙과 동일)
  - fail_items가 있는데도 "otest_verify PASS"를 반환하는 행위
  - blocked/blocked_by 항목을 fail_items에 포함시키는 행위 (루프가 끝나지 않음)
  - 신규 반복 카운터 생성 (oroof_active.current_iteration/max_iterations만 사용)
```

## QA 단계 검증 (선언 프로젝트)

> 사용자 지시(2026-10-10): "앞으로도 qa서버까지는 테스트를 진행하도록 하라. 다만 운영db와 연계되어있으므로 조심하고 최소한의 테스트만 진행하고 테스트전으로 완벽하게 되돌릴수있는 테스트만 진행하여야한다."

```yaml
적용_조건: 프로젝트에 `.claude/qa_tier.json`(QA 운영 데이터 연계 단계 선언)이 있을 때만. 없으면 건너뛴다.
원칙: 개발 PASS 뒤 QA 까지 시험한다. 최소화(핵심 경로 1회, 쓰기 없는 증명 우선) + 시험 전 상태로 완전 원복 가능한 시험만.
마커: ${SESSION_DIR}/evidence/qa_test_done
  형식:
    1행: <PASS|PARTIAL|SKIPPED> <ISO8601>  (FAIL 등 다른 값은 게이트가 차단한다)
      ISO8601 은 `T시:분` 까지 있어야 한다(날짜만 쓰면 차단). 예: `PASS 2026-10-10T15:30:00+09:00`
      키=값 행은 줄 맨 앞에서 시작한다(첫 줄에 이어 쓰거나 들여쓰면 인식하지 못한다).
      before=·after= 는 절대경로를 권장한다(상대경로는 프로젝트 디렉터리 기준으로 풀린다).
    이하 키=값 행:
      게이트 필수(PASS/PARTIAL): before=<전 스냅샷 JSON 경로> / after=<후 스냅샷 JSON 경로>
        - 두 파일은 실존하는 JSON 이고 .state 키가 있어야 한다.
        - .state 의 전후가 같아야 하고, after mtime ≥ before mtime ≥ pipeline_start_time 이어야 한다.
      게이트 필수(SKIPPED): reason=<면제 사유 10자 이상>
      선택(게이트는 읽지 않음, 남겨도 됨): compare=<비교 결과 경로> / excluded=<제외 항목 ID 목록>
  판정:
    PASS: 모든 계획 항목을 시험했고 전후 COUNT·행해시(+허용 표 AUTO_INCREMENT)가 동일하다.
    PARTIAL: 일부 항목 미수행 또는 전후 불일치. 원인을 남긴다. 불일치 PARTIAL(.state 전후 상이)은 DONE 이 차단된다.
    SKIPPED: 시험을 하지 않은 근거를 reason= 에 적는다. 면제는 사용자에게 묻지 않고 판단해 기록한다 — 앱·서버 소스 변경이 없거나 QA 시험이 해당되지 않을 때 쓴다(사용자 지시 2026-10-27 15:53). reason 이 감사 기록이다.
검증_절차:
  1. 선언 파일 존재 확인 → 있으면 마커 존재 확인 (없으면 FAIL, DONE 진입 불가)
  2. before·after·compare 파일이 실재하고 compare 가 일치(match=true)인지 직접 읽어 확인한다 (마커 문구만 믿지 않는다)
  3. 원복 판정표(제외·원복 불가 항목과 사유)가 있는지 확인한다
  4. 시험 표식 잔존 0 (시험 행이 남아 있지 않음)을 확인한다
  5. 공유 설정·실업무 행·타 직원 계정을 쓰지 않았는지 시험 로그로 대조한다
주의: 위 형식은 게이트 스크립트(qa_tier_check)와 동일하며 게이트가 정본이다.
```

## 적용 시기

**항상 전에:**
- 성공/완료 주장
- 커밋, PR 생성, 작업 완료
- 다음 작업으로 이동
- 에이전트 위임 결과 수락

**핵심**: 명령어 실행 → 출력 읽기 → 결과 주장. 협상 불가.
