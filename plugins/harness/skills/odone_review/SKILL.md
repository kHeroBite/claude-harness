---
name: odone_review
description: "프로세스 개선 점검. 교훈 분석 + 조치 방향 결정 → $HOME/.claude/session-env/${UUID}/logs/review_actions.json 출력."
invocation:
  user_callable: false
  pipeline_callable: true
  called_by: [odone]
  calls: []
---
# odone_review — 프로세스 개선 (분석 전담)

매 작업 완료 시 프로세스 개선점을 점검하고, 조치 방향을 JSON으로 출력.
**review는 분석만 담당** — 실제 반영은 후속 스킬(hooks → skills → docs)이 수행.

## 🚨 핵심 원칙: review = 분석 + 분류만

```yaml
역할: 교훈 발견 → 5W1H 분석 → Level/조치방향 결정 → JSON 출력
금지:
  - LESSONS.md/MEMORY.md/CLAUDE.md 직접 수정
  - 스킬 파일 직접 수정
  - Hook 스크립트 직접 생성/수정
이유: 실제 반영은 교훈 반영 파이프라인(hooks → skills → docs)이 전담
```

## Step 0: 이전 교훈 미반영 점검 (Step 1 전)

```yaml
점검_절차:
  1. LESSONS.md 하단 반영 추적 테이블 확인
  2. ⬜(미확인) 항목 존재 시:
     - 해당 항목을 $HOME/.claude/session-env/${UUID}/logs/review_actions.json의 pending_items에 포함
  3. 미확인 항목 없으면 즉시 Step 0-B로 진행

조치_효과_검증 (Step 0-B):
  목적: 이전에 적용 완료(✅)된 조치가 실제로 재발을 방지하는지 검증
  절차:
    1. LESSONS.md 반영 추적 테이블에서 '적용 완료(✅)' 항목 목록 추출
    2. 이번 세션 error md($HOME/.claude/session-env/${UUID}/logs/errors.md)에서 동일 패턴 ERR 재발 여부 확인
    3. 재발 발견 시:
       - 해당 항목의 검증 상태를 '재발(🔄)'로 변경
       - 조치 강화 플래그 설정: $HOME/.claude/session-env/${UUID}/logs/review_actions.json의 reinforce_items에 추가
       - 기존 Level 유지 또는 상향 (Level 2 → Level 3 자동 승격)
    4. 재발 없으면 즉시 Step 1로 진행

소요_시간: 최대 30초 (테이블 존재 여부 확인 + 재발 대조)
```

## Step 0.5: 오류 추적 (6-소스 수집) — ⚠️ tier 무관 항상 필수

> 세션 중 발생한 모든 오류를 6개 소스(A~F)에서 수집 → Step 1 입력으로 활용. 상세: [ERROR_SOURCES.md](references/ERROR_SOURCES.md)

```yaml
실행_조건: tier 무관 항상 실행 (o1/o2/o3/o4/o5 모두 필수)
금지: "o1이라서 스킵", "오류 없어 보여서 스킵" 등 조건부 생략
이유: error_log 필드 누락 시 review_actions.json 스키마 불완전 → 교훈 분석 노이즈 유발
출력: review_actions.json의 error_log 필드 (필수 필드 — 오류 없으면 빈 구조로 기록)

HOOK_BLOCK_분류:
  정의: write_guard.sh 등 hook이 금지 도구 사용을 차단한 에러
  판정: "정상 차단(방어 성공)" — 미해결 에러 카운트에서 제외
  표시: error_log.errors 배열에 포함하되 category="HOOK_BLOCK_OK" 태그 부여
  집계:
    - total: 전체 오류 수 (HOOK_BLOCK 포함)
    - unresolved: 미해결 오류 수 (HOOK_BLOCK 제외)
    - resolved: 해결된 오류 수 (HOOK_BLOCK 제외)
    - hook_blocked: HOOK_BLOCK 정상 차단 수 (별도 집계)
  이유: HOOK_BLOCK은 방어 체계가 정상 작동한 증거이며, "미해결 에러"로 분류하면 교훈 분석에 노이즈 주입

소스_C_USER_FEEDBACK_수집:
  대상: errors.md에 기록된 USER_FEEDBACK 항목 (UserPromptSubmit.sh가 실시간 기록)
  절차:
    1. errors.md에서 "### ERR-N: USER_FEEDBACK" 항목 추출
    2. 각 항목의 matched_pattern으로 피드백 유형 분류:
       - 다시_요청/반복_불만/반복_지시 → 모델이 이전 지시를 제대로 수행하지 못함
       - 잘못_지적/부정_지적 → 모델의 판단/해석 오류
       - 누락_지적/미완료_지적 → 작업 범위 누락
       - 금지_요청/변경_요청 → 모델의 접근 방식이 사용자 의도와 불일치
    3. 동일 유형 2회+ 반복 시 자동 Level 3 승격
    4. error_log.errors에 source:"user_feedback" 포함
  보완_스캔 (메커니즘 2 — 누락 방지):
    시점: USER_FEEDBACK 0건일 때도 트랜스크립트 사후 스캔 실행
    패턴: "다시|또|잘못|왜 안|아니|그게 아니|안 됐|빠졌|누락" (type:"human" 메시지)
    제외: 슬래시 명령, 순수 추가 요청, 질문, 긍정 피드백
    누락 발견 시: UFBK-N ID 부여 → error_log.errors에 추가
  상세_수행_방법 (소스 C):
    맥락_파악: 각 피드백의 발생 단계(oplan/odev/otest) + 수정 요청 사유 기록
    패턴_분류: 반복 요청(동일 피드백 2회+ → 재발 가능성 高) vs 일회성
    수집_결과_기록: review_actions.json의 "user_feedback" 배열에 기록
      형식: { "id": "UFBK-N", "stage": "{발생단계}", "pattern": "{matched_pattern}",
              "detail": "{피드백 내용 요약}", "repeated": true|false, "count": N }

소스_D_모델오류_수집 (트랜스크립트 사후 분석):
  대상: 모델의 환각/판단오류 — 실시간 hook 감지 원천 불가, 사후 분석 전용
  절차:
    1. 트랜스크립트에서 사용자→모델 정정 패턴 검색:
       - Grep: type="human" 메시지에서 "아니|그게 아니|잘못" 감지
       - 직전 모델 응답 확인 → 모델이 무엇을 잘못했는지 파악
    2. 도구 에러 후 모델 전환 패턴 검색:
       - "not found|No such file|ENOENT" → 모델이 존재하지 않는 파일/함수 참조
       - 직후 모델이 "대신|다른|대안" 등으로 전환
    3. odev 에이전트 잘못된 접근 → 사용자 수정 요청 흐름 감지:
       - pipeline_events.jsonl에서 REROUTE 이벤트 확인 → 역라우팅 원인 추출
       - reroute_context.md 파일 존재 시 역라우팅 사유 상세 분석
       - errors.md에서 AGENT_ERROR 카테고리 항목 검색
    4. 발견 시: error_log.errors에 MERR-N 추가
       { "id": "MERR-1", "source": "model_error",
         "category": "hallucination|misjudgment|info_gap",
         "detail": "모델이 X를 Y로 잘못 판단", "status": "해결됨" }
    5. 미발견 시: 소스 D 정상 스킵 (기록 불필요)
  root_cause 분류:
    - hallucination: 존재하지 않는 파일/함수/경로 참조
    - misjudgment: 잘못된 판단/해석 (사용자가 "아니" "그게 아니"로 정정)
    - info_gap: 정보 부족으로 인한 오류 (컨텍스트 미확인 후 행동)
  수집_결과_기록: review_actions.json의 "model_errors" 배열에 기록
    형식: { "id": "MERR-N", "source": "model_error", "category": "{root_cause}",
            "detail": "{상세}", "status": "해결됨|미해결", "reroute_related": true|false }
  역라우팅_분석_기록: review_actions.json의 "reroute_analysis" 객체에 기록
    형식: { "total_reroutes": N, "causes": [{"from": "{단계}", "to": "{단계}", "reason": "{사유}"}],
            "pattern": "반복|단발", "root_cause_summary": "{근본 원인 요약}" }

소스_F_결과파일_교차분석:
  대상: oplan/odev/otest 단계별 결과 파일 교차 대조
  절차:
    1. glob으로 결과 파일 탐색:
       - $HOME/.claude/session-env/${UUID}/plans/oplan_*.md (계획서)
       - $HOME/.claude/session-env/${UUID}/logs/odev_*.md (구현 결과)
       - $HOME/.claude/session-env/${UUID}/logs/otest_*.md (테스트 결과)
    2. 각 파일에서 "오류|미해결|FAIL|실패|누락" 키워드 검색
    3. oplan vs odev 대조: 계획 대비 실제 구현 차이 확인
       - 계획에 있으나 구현에 없는 항목 → 누락 교훈
       - 계획에 없으나 구현에 있는 항목 → 범위 초과 교훈
    4. odev vs otest 대조: 구현 내용과 테스트 결과 차이
    5. oplan acceptance_criteria vs otest_evidence 체크리스트 대조:
       - oplan 계획서의 acceptance_criteria 항목 추출
       - otest_evidence가 생성한 검증 체크리스트와 실제 통과 항목 비교
       - 누락/불일치 항목 식별
    6. 기존 소스 A~E와 중복 제거 후 error_log에 추가
    7. 파일 미존재 시 해당 소스 스킵 (오류 없이 진행)
  활용: 5W1H 분석의 "Where/When" 정밀화에 사용
  수집_결과_기록: review_actions.json의 "verification_gaps" 배열에 기록
    형식: { "id": "VGAP-N", "type": "missing|mismatch|scope_overflow",
            "plan_item": "{계획서 항목}", "actual": "{실제 구현/테스트 결과}",
            "gap_detail": "{불일치 상세}" }
```

## Step 1.5: 외부 AI 리뷰 (o4~o5 Full Path 전용)

```yaml
Step_1.5_외부AI_리뷰 (O4~O5 Full Path 전용):
  조건: tier가 O4 또는 O5일 때만 실행 (O3 이하 스킵, classification 파일 값 기준)
  순서:
    1차: Skill('code-review:code-review') — 코드 품질 리뷰
    2차: Skill('codex:adversarial-review') — 적대적 설계/보안/로직 리뷰
  출력: 두 결과를 Step 2 상세 분석 입력으로 활용
  목적: 이종 AI(GPT) 관점의 도전적 검증으로 Claude 편향 보완
```

## Step 1: 자동 점검 (항상 실행)

```yaml
점검_항목:
  1_도구_오류: "Serena/MCP/Build 등 도구에서 예상치 못한 오류가 발생했는가?"
    → Step 0.5 소스 A(hook 로그) + 소스 B(트랜스크립트) 양쪽 결과를 통합 반영
  2_프로세스_위반: "odev 배치 빌드, 병렬화 정책, 파일 수정 절차 등을 위반했는가?"
  3_사전_분석_누락: "DB 스키마, 기존 코드 구조 등 사전 확인 없이 작업을 진행했는가?"
  4_병렬화_기회_놓침: "병렬화 조건 충족했으나 순차 처리했는가?"
  5_역라우팅_발생:
    확인: mcp__oio__file_read path=$HOME/.claude/session-env/${UUID}/reroute_count → 파일 없으면 "0" 가정
    조건: 값 > 0
    행동: Step 2 분석에서 "역라우팅 N회 발생 — 원인 분석 필요" 항목으로 포함
    Level_판정: 역라우팅 1회 = Level 1, 2회 이상 = Level 2 (반복 패턴 가능성)
    원인_분석 (reroute_log + checkpoint.jsonl 활용):
      1. $HOME/.claude/session-env/${UUID}/reroute_log 파일 존재 시 읽기
         - 형식: [timestamp] from:agent_name to:target reason:detail
         - 각 역라우팅의 구체적 원인 파악 (빌드 실패/테스트 실패/설계 결함 등)
      2. reroute_log 미존재 시: checkpoint.jsonl에서 REROUTE 이벤트 검색
         - Grep: "REROUTE" in $HOME/.claude/session-env/${UUID}/checkpoint.jsonl
         - detail 필드에서 "from→to: 사유" 추출
      3. evidence/reroute_history.json 존재 시: 동일 항목 반복 여부 확인
         - 같은 acceptance criteria + 같은 에러 카테고리 = 설계 결함 가능성
      4. 원인별 교훈 분류:
         - 빌드 실패 → Level 1 (코드 오류, 수정으로 해결)
         - 동일 항목 2연속 → Level 2+ (설계 재검토 필요)
         - 5회+ → Level 3 (파이프라인 구조 문제 가능성)

판정:
  모두_아니오:
    출력: "✅ odone_review: 문제 없음"
    → $HOME/.claude/session-env/${UUID}/logs/review_actions.json에 빈 actions 배열 저장
    → 종료
  하나라도_예:
    → Step 2 진행
```

## Step 2: 상세 분석

```yaml
분석_절차:
  1. 5W1H_분석:
    - What: 무엇이 잘못되었는가?
    - Why: 근본 원인은? (필요 시 5 Whys)
    - When: 어느 단계에서 발생했는가?
    - Where: 어떤 파일/도구에서?
    - Who: 어떤 판단이 원인이었는가?
    - How: 어떻게 방지할 수 있는가?

  2. 심각도_판단:
    낮음: 1회 발생, 비정형, 특수 상황
    중간: 도구/환경 제한으로 재발 가능성 높음
    높음: 2회+ 반복 발생, 규칙화 가능

  3. Level_결정 + 조치_방향_결정: → Step 3으로
```

## Step 3: 조치 방향 결정 + JSON 출력

### Level 분류 기준

| Level | 조치 방향 | 강도 | 판단 기준 | 담당 스킬 |
|-------|-----------|------|-----------|-----------|
| 1 | LESSONS.md 기록 | 참고용 | 1회, 비정형, 규칙화 어려움 | odone_docs |
| 2 | LESSONS.md + CLAUDE.md/스킬 규칙 강화 | 인지강화 | 도구/환경 제한, 재발 높음 | odone_skills |
| 3-hook | LESSONS.md + Hook 물리 차단 | 강제 | hook 감지 가능 + 반복 위반 | odone_hooks |
| 3-oio | LESSONS.md + oio 서버 수정 | 강제 | 파라미터 별칭/자동변환 가능 | odone_hooks |
| 3-skill | LESSONS.md + 스킬/CLAUDE.md 규칙 강화 | 강제 | hook 불가 + 판단 기반 규칙 | odone_skills |

> ⚠️ Memory 업데이트는 재발방지 수단이 아님. 재발방지 = hook > oio서버 > skill > CLAUDE.md (물리적 강제 우선)

### 조치 방향 판단 흐름 (Level 3)

```yaml
판단_흐름:
  1. hook으로 차단 가능한가? (도구 호출 시점에서 입력값/상태로 판별 가능)
     → YES: target = "hook" → odone_hooks가 처리
     → NO: 2번으로

  2. 스킬 규칙 강화로 예방 가능한가? (사전 인지로 실수 방지)
     → YES: target = "skill" → odone_skills가 처리
     → NO: Level 1 또는 2로 하향 → odone_docs가 처리

핵심: hook과 skill은 중복 금지 (하나만 선택)
```

### JSON 출력 형식

```yaml
파일: $HOME/.claude/session-env/${UUID}/logs/review_actions.json
생성: Step 1 완료 후 항상 생성 (문제 없으면 빈 배열)

구조:
  {
    "timestamp": "2026-02-15T22:00:00",
    "summary": "N건 발견",
    "pending_items": [...],   // Step 0에서 발견한 미반영 항목
    "user_feedback": [],      // 소스 C 수집 결과 — UFBK-N 항목 배열
    "model_errors": [],       // 소스 D 수집 결과 — MERR-N 항목 배열
    "reroute_analysis": {},   // 소스 D 역라우팅 원인 분석 (total_reroutes, causes, pattern, root_cause_summary)
    "verification_gaps": [],  // 소스 F 불일치 항목 — VGAP-N 항목 배열
    "error_log": {            // Step 0.5에서 수집 (⚠️ 필수 필드 — 누락 금지, 오류 없으면 빈 구조)
      "file": "$HOME/.claude/session-env/${UUID}/errors.md",
      "total": 3,             // 전체 오류 수 (HOOK_BLOCK 포함)
      "unresolved": 1,        // 미해결 오류 수 (HOOK_BLOCK 제외)
      "resolved": 2,          // 해결된 오류 수 (HOOK_BLOCK 제외)
      "hook_blocked": 0,      // HOOK_BLOCK 정상 차단 수 (별도 집계, 미해결에 미포함)
      "errors": [...]         // 각 항목에 category 필드 포함 ("ERR" | "HOOK_BLOCK_OK")
    },
    "actions": [
      {
        "id": "L-035",
        "what": "otest_run 절차 생략",
        "why": "빌드 성공 후 바로 odone 진입",
        "severity": "높음",
        "level": 3,
        "target": "hook",     // "hook" | "skill" | "docs"
        "target_file": "write_guard.sh",
        "target_section": "otest 증거 검증",
        "proposed_rule": "otest 3 Phase 증거 파일 모두 존재해야 odone 진입 허용",
        "lessons_entry": "L-035: otest_run 절차 생략 금지 — REST API/스크린샷/로그 전부 검증 필수"
      }
    ]
  }

target 값별 담당:
  "hook"  → odone_hooks가 소비 (hook 생성/수정)
  "skill" → odone_skills가 소비 (스킬 규칙 강화/추가)
  "docs"  → odone_docs가 소비 (LESSONS/MEMORY 기록)
  모든_항목: odone_docs가 LESSONS.md에 기록 (target 무관)

error_log 필수 규칙:
  - error_log는 필수 필드 — 오류 없을 때도 반드시 포함
  - 오류 없을 때 기본값:
    "error_log": {
      "file": "$HOME/.claude/session-env/${UUID}/errors.md",
      "total": 0,
      "unresolved": 0,
      "resolved": 0,
      "hook_blocked": 0,
      "errors": []
    }
  - HOOK_BLOCK 에러 항목 예시:
    { "source": "A", "message": "write_guard.sh: Bash 도구 차단", "category": "HOOK_BLOCK_OK", "resolved": true }
  - category 값: "ERR" (일반 에러) | "HOOK_BLOCK_OK" (정상 차단 — 방어 성공)
```

## 출력 형식

```
📋 odone_review 결과:
- 발견 건수: N건
- [Level X → target] 항목명: 간단 설명
- JSON 저장: $HOME/.claude/session-env/${UUID}/logs/review_actions.json
```

문제 없을 경우:
```
✅ odone_review: 문제 없음 (빈 actions 저장됨)
```

---

## 교훈 기록 절차 (odone에서 이관)

### 교훈 강제 실행 상세 (L-042)

```yaml
적용_범위:
  필수: o1/o2/o3/o4/o5 — 모든 코드 수정 작업
  예외: 질문/탐색만 (파이프라인 미진입 → odone 자체 미실행)

강제_대상_서브스킬:
  - odone_review: 교훈 분석 + 조치 방향 결정 → $HOME/.claude/session-env/${UUID}/logs/review_actions.json
  - odone_hooks: review 결과 중 hook 필요 항목 처리
  - odone_skills: review 결과 중 스킬 수정 필요 항목 처리
  - odone_docs: review 결과 문서 기록 + HISTORY/PROJECT/DATABASE 업데이트

금지:
  - "o1이라서 교훈 없음" → o1도 반드시 실행
  - "변경이 단순해서 스킵" → 단순 변경도 반드시 실행
  - odone_git만 실행하고 "완료" 선언 → 절대 금지
  - 교훈 단계 없이 커밋 진행 → 절대 금지

o1_작업_교훈_절차:
  odone_review: 간략 점검 (변경 내용 + 프로세스 이슈 유무)
  odone_hooks/skills: review 결과 해당 없으면 "해당 없음" 선언 후 스킵 가능
  odone_docs: 교훈 기록 해당 없으면 HISTORY만 업데이트 후 통과

위반_사례:
  - L-042 원인: o1 작업에서 odone_review~odone_docs 전체 생략하고 git+notify만 실행
  - 재발방지: 이 규칙으로 모든 분류에서 교훈 단계 강제화
```

### 교훈 기록 트리거 (사후 대응 — 추가 강화)

> 위 강제 실행과 별개로, **사용자 피드백 기반 사후 대응**도 유지.

```yaml
트리거_조건 (모두 충족 시):
  키워드_감지: "다시", "누락", "빠졌", "왜 안", "또", "안 됐", "고쳐"
  컨텍스트: 완료 응답 후 같은 작업에 대한 추가 요청 발생
  같은_작업_판단: 동일 파일/기능, 30분 이내

수행_절차:
  1. 원인 분석 (심각도 높음은 5 Whys)
  2. 개선안 도출
  3. Level 분류 후 해당 문서에 기록:
    - Level 1 (참고): LESSONS.md만 — 1회, 비정형
    - Level 2 (인지): LESSONS.md + CLAUDE.md/스킬 규칙 강화 — 도구/환경 제한, 재발 높음
    - Level 3 (강제): LESSONS.md + CLAUDE.md/스킬/hook — 2회+ 반복, 규칙화 가능

심각도:
  높음: 3회+ 반복 또는 핵심 기능 누락
  중간: 2회 반복 또는 부가 기능 누락
  낮음: 1회 지적 또는 사소한 누락
```

## 교훈 졸업 프로세스 (월 1회 선택적 실행)

```yaml
졸업_조건: 규칙/Hook에 완전 흡수된 L-NNN 교훈
졸업_판단:
  1. 해당 교훈이 스킬 규칙 또는 Hook 코드로 물리 강제되어 있는가?
  2. 교훈 없이도 해당 위반이 자동 차단되는가?
  → 둘 다 예: 졸업 대상
졸업_처리:
  - LESSONS.md 해당 항목에 "✅ 졸업 {날짜} — {흡수된 규칙/Hook 위치}" 마킹
  - 스킬 파일의 해당 L-NNN 레퍼런스를 인라인 설명으로 전환 (삭제 금지)
  - 예: "(L-171: 메인 직접 수정 금지 — write_guard.sh 물리 차단)" 형식
금지: 졸업 처리 없이 L-NNN 삭제 금지
```
