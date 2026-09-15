---
name: goal
description: "파이프라인 계약 문서 — goal.json 스키마/템플릿/검증 로직 제공. oplan_normal Phase 0에서 자동 호출되어 ${SESSION_DIR}/goal.json을 생성. otest_evidence는 발견 시 1순위 대조 기준(soft hint)으로 사용. 파이프라인 전반 통합 완료 — oplan_deep/consult/debate soft hint, oralph/ofinish 조건부 hard gate, write_guard.sh locked 물리 보호."
invocation:
  user_callable: false
  pipeline_callable: true
  called_by: ["oplan_normal(Phase 0)"]
  calls: []
---
# goal — 파이프라인 계약 문서 생성

## §1 역할

`goal.json`은 파이프라인 계약 문서다. 사용자의 의도(intent), 범위(scope), 제약(constraints), 인수 기준(acceptance)을 단일 출처로 고정한다.

```yaml
목적:
  - oplan/odev/otest 단계가 동일한 "계약 문서"를 참조하여 해석 불일치를 줄인다.
  - acceptance 시드를 사전 정의하여 oplan Step_8(acceptance_criteria.json)의 품질을 높인다.
  - non_goals 명시로 scope creep를 예방한다.
핵심_불변식:
  - 단일 세션 1개 파일 (${SESSION_DIR}/goal.json)
  - 생성 주체: oplan_normal Phase 0 (o3) 또는 oto 1_5_목표계약_세팅 (o4/o5).
    o4/o5의 oplan_deep/consult/debate는 goal.json을 읽기만 하고 생성하지 않으므로
    oto가 직접 생성한다 (미생성 시 PreToolUse_oto_completion_guard.sh F-OTO-1이 차단).
  - locked 기본값은 false. lock_request=true 전달 시에만 true (§4 Phase_D).
    locked=true이면 write_guard.sh F-GOAL-1이 goal.json 수정을 물리 차단한다.
```

## §2 호출 시점

```yaml
호출자_1: oplan_normal (o3)
  시점: Step_1(의도분석) 진입 전, oplan_normal 로딩 직후 1회
  조건: 모든 o3 작업 (Quick/Deep 공통)
  lock_request: 없음 → locked=false

호출자_2: oto (o4/o5 포함 전 tier)
  시점: 1_5_목표계약_세팅 (auto 플래그 기록과 동일 시점, ok 로딩 직전)
  이유: o4/o5의 oplan_deep/oplan_consult/oplan_debate는 goal.json을 읽기만 하고
        생성하지 않는다. oto가 직접 만들지 않으면 계약 문서가 아예 없다.
  lock_request: true → locked=true (질문 없이 완주하는 모드이므로 계약을 잠근다)
  ⚠️ oto가 이미 locked=true로 생성한 뒤 oplan_normal이 재생성을 시도하면
     write_guard.sh F-GOAL-1이 차단한다. 이는 정상 동작이며 oto의 계약이 우선한다.
     oplan_normal은 기존 goal.json을 읽어 시드로만 쓰고 생성을 건너뛴다.

이전_계약_잔존_처리 (L-DEMO-1, 2026-09-05):
  증상: 동일 세션에서 2차 /oto 진입 시, 이전 사이클이 완료됐음에도 locked=true인
        goal.json이 그대로 남아 있으면 새 계약 생성이 F-GOAL-1에 의해 차단된다.
  판정: goal.json이 이미 존재하고 locked=true인 상태에서 새 계약 생성을 시도하기 전,
        아래 조건을 모두 만족하면 "완료된 이전 계약"으로 간주하고 보관 후 진행한다.
        1) 기존 goal.json의 acceptance 항목이 전부 status!=open이거나
           auto_script 실행 결과가 전부 PASS로 기록된 별도 증거(otest_done 등)가 있다.
        2) 세션의 conv_id가 goal.json 생성 시점의 대화ID와 다르다(새 사이클 진입 확정).
  절차: mcp__oio__file_move로 기존 goal.json을
        goal_{완료시각 또는 이전 conv_id}_completed.json 으로 보관한 뒤 신규 goal.json을 생성한다
        (덮어쓰기/삭제 금지 — 보관만).
  금지: locked 검사 없이 임의 삭제, 조건 미확인 상태에서 "그냥 지우고 새로 생성".

방법: Skill('goal') 직접 로딩 (별도 팀에이전트 spawn 없음)
결과: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/goal.json 생성
이후_흐름:
  - Step_1 의도분석: goal.intent를 시드로 사용
  - Step_8 acceptance_criteria.json: goal.acceptance를 시드로 확장
폴백: goal.json 생성 실패 시 경고 출력 후 Step_1 계속 진행 (PoC라 강제 차단 없음)
```

## §3 goal.json 스키마 명세

| 필드 | 타입 | 필수/선택 | 설명 |
|------|------|----------|------|
| `goal_id` | string | 필수 | G-XXXXXXXX 형식 (8자리 랜덤 hex) |
| `intent` | string | 필수 | 1~2줄 사용자 의도 요약 |
| `scope_in` | string[] | 필수 | 포함 파일/모듈 절대경로 목록 |
| `scope_out` | string[] | 선택 | 제외 항목 (명시적 비범위) |
| `constraints` | string[] | 선택 | 기술/성능/운영 제약 조건 |
| `acceptance` | object[] | 필수 ≥1 | 인수 기준 목록 (§3.1 스키마 / §3.2 완주 불가 표현) |
| `non_goals` | string[] | 권장 | 명시적 비목표 (scope creep 방지) |
| `max_iterations` | integer | 선택 | oralph 최대 반복 (기본 5) |
| `locked` | boolean | 필수 | true 시 잠금 게이트 활성 (§4 Phase_D 참조) |
| `created_at` | string | 필수 | ISO 8601 생성 시각 (자동 기록) |

### §3.1 acceptance 항목 스키마

```yaml
acceptance_항목:
  id: "A1", "A2" ... (순번)
  kind: "behavior|build|test|ui|metric|file"
  desc: 자연어 설명 (한국어 권장)
  check: 사람이 읽는 검증 기술 (grep 패턴 / 셸 명령 / URL)
  auto_script: bash로 실행 가능한 명령. exit 0 = PASS, 그 외 = FAIL.
  depends_on: string[] — 이 항목이 입력으로 요구하는 다른 항목의 id 목록 (기본 [])
  status: "open" | "blocked" | "blocked_by" (기본 open)
  blocked_reason: status가 blocked/blocked_by일 때 필수 (§3.2 열거값)
  blocked_evidence: status가 blocked/blocked_by일 때 필수 (실측 근거)
  blocked_by_id: status=="blocked_by"일 때 권장 — 원인이 된 blocked 항목 id
  valid_after: 선택. "odone" 지정 시 done_gate(PreToolUse_done_gate.sh)의 DONE 전이
               판정에서 이 항목을 제외한다. 커밋 게이트처럼 정의상 odone 완료
               이후에만 충족 가능한 항목(예: "커밋되어 있고 작업트리가 clean")에
               사용한다 (L-DEMO-4, 2026-09-05). 미지정 시 기존과 동일하게
               DONE 전이 시점에 즉시 판정된다.
```

**`auto_script`는 기계 판정의 유일한 실행 필드다.** ofinish Step 3.5-0 게이트와
`PreToolUse_oto_completion_guard.sh`(F-OTO-2)는 `auto_script`만 읽으며 `check`는 읽지 않는다.
`check`만 있고 `auto_script`가 없는 항목은 "실행할 항목 0개"로 집계되어 **게이트가 조용히
통과된다(no-op)**. 게이트를 실제로 작동시키려면 blocked/blocked_by를 제외한 전 항목에
`auto_script`가 있어야 한다.

### §3.2 완주 불가 항목 표현 (status / depends_on)

> 배경: `/oto`가 완주 불가 항목 1건을 이유로, 그것에 의존하지 않는 가능 항목까지 묶어서
> 미루고 종료한 사고(2026-08-24). 불가 항목의 존재가 가능 항목을 끌고 가지 못하도록
> 의존 관계를 명시적으로 판정하게 한다.

```yaml
status_값:
  open:       완주 대상. auto_script 실행 → pass/fail 판정.
  blocked:    이 세션의 에이전트 권한 밖. 판정 대상에서 제외(실행하지 않음).
  blocked_by: 선행 blocked 항목에 의존하여 함께 불가. 판정 대상에서 제외.

blocked_reason (열거값 — 이 5개 외 자유 서술 금지):
  "타세션_프로세스_재시작_필요"     # 타 세션/타 프로세스의 재시작·종료가 필요
  "사용자만_아는_값_필요"           # 자격증명·미공개 URL·계정·업무 규칙
  "물리장비_외부인력_필요"
  "도구_권한거부_로그_존재"         # hook block / 403 등 실제 로그가 있을 때만
  "선행_blocked_항목_의존"          # 전파 전용 — blocked_by에만 사용, 직접 지정 금지

  ⛔ 아래는 전부 열거값 밖이며 해당 항목은 완주 대상(open)이다:
     "시간/토큰/컨텍스트 부족" · "위험해 보임" · "사용자가 시점을 정해야 함"
     · "다음 사이클이 적절함" · "다른 항목이 불가라 함께 미룸" · "범위가 크다" · "확신이 없다"

blocked_evidence: 실측 근거만 인정한다.
  · 명령 출력 / 로그 경로 + 라인 / 도구가 반환한 에러 메시지 원문
  ⛔ "판단했다" "~로 보인다" "일반적으로 불가능하다"는 근거가 아니다.

depends_on 판정 질문 (단 하나만 묻는다):
  "X를 실행하지 않은 상태에서 이 항목의 auto_script를 지금 실행하면 FAIL하는가?"
  → YES 여야만 depends_on에 X를 넣는다. 실행해서 확인할 수 있으면 실행해서 확인하라.

  ⛔ depends_on이 될 수 없는 것 (의존은 오직 "산출물이 입력으로 필요한가" 하나다):
     · "X가 안 되면 전체가 완성되지 않으니까"   → 완성도는 의존이 아니다
     · "X 없이 이 항목만 해봐야 의미가 없으니까" → 의미는 의존이 아니다
     · "X와 같은 단계/같은 문서에 묶여 있으니까" → 서술 순서는 의존이 아니다
     · "X 이후에 하는 게 자연스러우니까"         → 선호는 의존이 아니다

  순환 금지: depends_on은 자신보다 앞선 id만 참조한다 (A5는 A1~A4만).
             oplan_deep의 depends_on_batch DAG 규칙과 동일하다.

blocked_전파 (goal.json 생성 시 1회 계산, 이후 고정):
  1. status=="blocked" 항목의 id 집합 = BLOCKED
  2. depends_on이 BLOCKED의 원소를 하나라도 포함하는 항목 → status="blocked_by",
     blocked_reason="선행_blocked_항목_의존", blocked_by_id=해당 선행 id
  3. 2를 변화가 없을 때까지 반복 (전이적 폐포)
  4. 그 외 전부 open → 완주 대상. 예외 없음.

  🚫 전염 금지: blocked는 depends_on 그래프를 타고서만 번진다.
     "같은 기능의 일부" "같은 문서의 다음 절"로는 절대 번지지 않는다.

blocked_등록_시점_제약 (자기기만 차단의 핵심):
  status:"blocked"는 goal.json 최초 생성 시점에만 기입할 수 있다.
  locked=true 이후에는 write_guard.sh F-GOAL-1이 goal.json 수정을 물리 차단하므로
  검증 루프 도중 open → blocked 승격은 물리적으로 불가능하다.
  "해보니 안 되네, 불가로 빼자"는 blocked 사유가 아니라 fail이며 루프가 다시 돈다.
  → 회피 동기가 발생하기 전(작업 착수 전)으로 판정 시점을 밀어내는 것이 목적이다.

hook_검증 (PreToolUse_oto_completion_guard.sh — auto=ON 세션에서만):
  F-OTO-3: blocked/blocked_by에 blocked_reason 또는 blocked_evidence 누락 → block
  F-OTO-4: blocked_reason이 위 열거값 5개 밖 → block
  F-OTO-5: depends_on이 존재하지 않는 id를 참조 → block
  F-OTO-6: blocked_by인데 depends_on에 실제 blocked id가 없음(전파 위조) → block
  ⚠️ 한계: "실제로는 독립인데 depends_on에 넣는" 허위 기입은 hook이 판정할 수 없다.
     그래프 정합성만 검사할 뿐 의존의 실재성은 검사하지 못한다.
```

## §4 산출 절차

```yaml
Phase_A_파싱:
  - 사용자 요구사항 텍스트에서 핵심 동사/명사 추출
  - intent 1~2줄로 압축

Phase_B_범위_추출:
  - 계획서 수정 대상 파일 목록 → scope_in
  - 사용자 명시 제외 항목 → scope_out
  - constraints: 기술 스택 제약, 성능 요구사항, 운영 제약 수집

Phase_C_acceptance_시드:
  - 사용자 요구사항 핵심 항목 → acceptance[] 초안
  - kind는 요구사항 유형에 따라 자동 분류
  - check 필드: 사람이 읽는 검증 기술
  - auto_script 필드: bash 실행 가능 명령 (exit 0 = PASS). blocked/blocked_by 제외 전 항목 필수.
    auto_script가 없으면 게이트가 no-op이 된다 (§3.1 참조).
  - status/depends_on/blocked_* : §3.2 절차에 따라 판정 후 기입.
    · 각 항목에 §3.2 판정 질문을 적용하여 depends_on 확정
    · 권한 밖 항목만 status:"blocked" + 열거값 blocked_reason + 실측 blocked_evidence
    · blocked_전파 규칙을 1회 계산하여 blocked_by 확정
    · 나머지는 전부 open (완주 대상)
  - non_goals: 요청에 없는 항목 중 혼동 가능한 것 명시

Phase_D_저장:
  - goal_id: G- + python3 secrets.token_hex(4).upper() (8자리)
  - locked: 호출자가 lock_request=true를 전달하면 true, 그 외 false (기본)
    lock_request=true 조건: 호출자가 "질문 없이 완주"를 계약하는 경우 (oto)
    locked=true의 효과 (전부 구현 완료 — 켜기만 하면 작동):
      · write_guard.sh F-GOAL-1: goal.json 수정/삭제 물리 block
      · ofinish Step 3.5-0: acceptance[].auto_script 전수 실행,
        FAIL>0 시 autoloop 진입 차단 + next_action.json 보존
      · oralph/oto 검증 루프 Step 1.5: acceptance 전수를 criteria_detail에 append
      · oplan_debate: 배심원 체크리스트에 goal.acceptance 충족 항목 추가
      · PreToolUse_oto_completion_guard.sh: F-OTO-1~6 전수 검사
    ⚠️ status:"blocked"·"blocked_by" 항목은 위 게이트 전부에서 실행·판정 대상에서 제외한다.
       권한 밖 항목을 fail로 세면 검증 루프가 영원히 끝나지 않는다.
  - created_at: ISO 8601 현재 시각
  - 저장 도구: mcp__oio__file_write (overwrite=true)
```

## §5 검증 로직

```yaml
필수_검증 (저장 전):
  - goal_id: "G-" 접두사 + 8자리 hex
  - intent: 비어있지 않음
  - acceptance: 1개 이상
  - created_at: ISO 8601 형식
  - locked: boolean

필수_검증 (locked=true로 저장할 때 추가):
  - acceptance[].auto_script: blocked/blocked_by를 제외한 전 항목에 존재
    (없으면 게이트가 no-op이 되므로 locked의 의미가 사라진다 — §3.1 참조)
  - blocked/blocked_by 항목: blocked_reason(§3.2 열거값 5개) + blocked_evidence 모두 존재
  - depends_on: 참조 id가 같은 goal.json 안에 실존 + 자신보다 앞선 id만 참조(순환 금지)
  - blocked_by 항목: depends_on에 실제 status=="blocked" 항목이 1개 이상 존재
  ⚠️ 위 4건은 PreToolUse_oto_completion_guard.sh의 F-OTO-2~6과 동일 기준이다.
     저장 전에 self-check 하지 않으면 세션 종료 시점에 hook이 차단한다.

권장_검증:
  - non_goals: 비어있으면 경고 (scope creep 위험 증가)
  - scope_in: 절대경로 형식 권장 (/mnt/c/... 또는 ${...} 변수)

검증_실패_처리:
  - 필수 필드 누락: 경고 출력 후 기본값으로 보완하여 저장 (PoC라 강제 차단 없음)
  - 잘못된 형식: 로그 출력 후 계속 (Step_1 진행 우선)
```

## §5.1 게이트 작성 규칙 (auto_script 4항)

```yaml
1_착수_전_1회_실행:
  규칙: auto_script 는 게이트 작성 직후 1회 실행해 rc 를 확인한다.
  이유: 작성만 하고 실행하지 않으면 그 게이트가 상시-참인지 상시-거짓인지 알 수 없다.
        rc 를 눈으로 확인하기 전까지 게이트는 "있다"일 뿐 "작동한다"가 아니다.
  근거: 사이클42 A2 — auto_script 의 bash -c 따옴표 중첩이 조용히 깨져 판정이 무효화됐다.
        같은 함정이 사이클40~42 에 3회 반복됐고, 3회 모두 1회 실행으로 즉시 드러났을 것이다.

2_경로_TFM_인덱스_하드코딩_금지:
  규칙: 경로·TFM(net10.0-windows 등)·배열 인덱스는 게이트 본문에 박지 않는다.
        탐색으로 얻거나 인자로 받는다.
  이유: 하드코딩된 값이 바뀌면 게이트는 오류를 내지 않고 조용히 대상을 잃는다.
  근거: 사이클42 A1 — TFM 을 게이트에 하드코딩해 경로가 바뀐 뒤 아무것도 검사하지 않았다.

3_부재는_통과가_아니다:
  규칙: 대상 파일·기준값이 부재하면 exit 2(판정 불가)로 끝낸다. exit 0(통과) 금지.
        예외는 "부재를 보고하는 것 자체가 목적"인 존재검사(exists)뿐이며,
        이 경우 부재는 1(불합격)이지 2 가 아니다.
  이유: "파일이 없으면 통과"는 게이트를 no-op 으로 만든다. 대상이 사라진 순간부터
        그 게이트는 무엇을 검사하든 항상 합격을 돌려준다.
  근거: 사이클42 A12 — 없는 경로를 대상으로 삼은 게이트가 상시-참으로 굳어 있었다.

4_검증_시점_명시:
  규칙: 실행 시점에 따라 결과가 달라지는 게이트는 desc 에 유효 시점을 적는다.
        예 — git-clean/new-commit 류는 "유효 시점: odone 커밋 후".
  이유: 시점을 적지 않으면 odev 단계의 정상적인 FAIL 을 결함으로 오판하고,
        반대로 이른 PASS 를 완료 근거로 오용한다.
  근거: 사이클42 A11 — 커밋 전 게이트의 FAIL 이 결함으로 보고돼 원인 추적에 시간을 썼다.

권장_구현_형태:
  판정 로직은 별도 스크립트 파일로 분리하고 auto_script 는 `python3 <파일> <mode> <인자>`
  한 줄로 둔다. bash -c 안의 인용이 3중으로 겹치는 것을 구조적으로 없앨 수 있다(1항·2항 동시 충족).
  실물 사례: .claude/evidence/c43_gate_check.py (사이클43).
```

## §6 저장 위치

```yaml
경로: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/goal.json
쓰기_도구: mcp__oio__file_write (overwrite=true)
읽기_도구: mcp__oio__file_read
세션_격리: UUID별 독립 파일 (§(a) 자기 세션 격리 준수)
템플릿_경로: .claude/skills/goal/template/goal.template.json
```

## §7 템플릿 경로

```yaml
위치: /mnt/c/DATA/Project/AI/.claude/skills/goal/template/goal.template.json
용도: Phase_D 저장 전 구조 참조용 (직접 복사하지 않고 스키마 확인용)
```

## §8 통합 현황 및 한계 (정보 정직성 원칙 준수)

```yaml
통합_완료:
  - oplan_deep soft hint: 0단계 goal.json 참조 블록 삽입 (oplan_deep/SKILL.md)
  - oplan_consult soft hint: Step 1 양쪽 계획가 spawn 프롬프트에 goal.json 주입 지시 삽입
  - oplan_debate soft hint: 0단계 context_summary.md에 goal.json 공유 + 배심원 항목 삽입
  - oralph 조건부 hard gate: Phase 2 Step 1.5 goal.acceptance 전수 검증 삽입 (locked=true 시만)
  - ofinish 조건부 hard gate: Step 3.5 autoloop 진입 전 goal.acceptance sandbox 게이트 삽입
  - hook 강제화: write_guard.sh F-GOAL-1 locked=true 물리 보호 분기 (odev-2 담당)

  - 완주 불가 3분류 (§3.2): status/depends_on/blocked_reason enum + blocked 전파 규칙
  - locked 하드코딩 해제 (§4 Phase_D): lock_request=true 시 locked=true 생성
  - oto 완주 게이트: PreToolUse_oto_completion_guard.sh F-OTO-1~6 (auto=ON 세션 한정)

현재_동작:
  - otest_evidence: goal.json 존재 시 soft hint로만 활용 (경고 출력, FAIL 미적용)
  - locked=true 시: write_guard.sh가 수정/삭제 물리 차단 + oralph/ofinish/oto 게이트 작동
  - goal.json 부재: 기존 파이프라인 폴백 (오류 없음). 단 auto=ON 세션은 F-OTO-1이 차단.

남은_한계 (정직 고지):
  - auto_script 없는 open 항목은 게이트에서 fail-open 통과한다.
    기계 판정이 불가능한 항목을 fail로 세면 기존 goal.json이 전부 차단되기 때문이다.
    → auto_script를 빠뜨리면 그 항목은 사실상 검증되지 않는다.
  - depends_on 허위 기입("실제로는 독립인데 의존한다고 적기")은 hook이 판정할 수 없다.
    F-OTO-5/6은 그래프 정합성만 검사하며 의존의 실재성은 검사하지 못한다.
    → §3.2의 판정 질문("X 없이 지금 실행하면 FAIL하는가")을 실제로 실행해 확인하라.
  - otest_evidence는 여전히 soft hint다 (locked=true여도 FAIL 미적용).
```

## §9 차수 이력

```yaml
1차수 (PoC — 완료):
  - goal/SKILL.md + template/goal.template.json 생성
  - oplan_normal Phase 0 soft 연동
  - otest_evidence Step_0 soft hint

2차수 (완료 — rest 차수):
  - 실제 oplan_normal Phase 0 실행 검증 (goal.json 실제 생성 확인)
  - otest_evidence Step_0 동작 검증 (soft hint 경고 출력 확인)
  - locked=true 진입 시 oralph/ofinish 조건부 hard gate 구현 완료

3차수 (완료 — rest 차수):
  - hook 강제화 (write_guard.sh F-GOAL-1: goal.json locked=true 물리 보호)
  - oplan_deep/consult/debate soft hint 통합 완료

4차수 (완료 — 2026-08-24, oto 완주 이탈 재발방지):
  - §3.1 스키마 확장: auto_script / depends_on / status / blocked_reason / blocked_evidence
  - §3.2 완주 불가 3분류 + blocked 전파 규칙 + 등록 시점 제약 신설
  - §4 Phase_D locked 하드코딩 해제 (lock_request=true → locked=true)
  - §2 호출자에 oto 추가 (o4/o5는 oplan이 goal.json을 생성하지 않으므로)
  - PreToolUse_oto_completion_guard.sh F-OTO-1~6 신설 (auto=ON 세션 완주 게이트)
  계기: /oto가 완주 불가 항목 1건을 이유로 그것에 의존하지 않는 가능 항목까지
        묶어서 미루고 조용히 종료한 사고. 문서 규칙으로 막을 수 없어 Hook으로 물리 강제.
```
