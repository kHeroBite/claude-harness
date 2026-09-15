---
name: odev_review
description: "코드 리뷰. 구현 결과물 검증, 파일 소유권, 코드 품질, 에이전트 간 일관성. Auto-activates when: multiple agents completed implementation."
invocation:
  user_callable: false
  pipeline_callable: true
  called_by: ["odev(에이전트 2개+ 완료)"]
  calls: ["odev_simplify"]
---
# odev_review — 코드 리뷰

## 목적

다수의 구현 에이전트가 완료된 후, **리더 대신** 각 에이전트의 결과물을 검증합니다.
리더의 context 부담을 줄이고, 구현 품질을 보장합니다.

## 실행 주체

```yaml
실행: 메인이 팀에이전트로 spawn (메인 직접 실행 금지)
이유: 메인 컨텍스트 보호 + 파이프라인 일관성
팀에이전트_추가_spawn_금지: 서브에이전트(Agent tool) 필요 시 팀에이전트 내부에서 직접 spawn. 추가 팀에이전트 필요 시 메인에게 SPAWN_REQUEST 위임.
```

## 활성화 조건

```yaml
필수: 구현 에이전트 2개 이상 완료 시
에이전트_1개: 팀에이전트 1개 spawn하여 검증 위임 (메인 직접 검증 금지)
```

## 에이전트 유형

```yaml
유형: general-purpose (코드 읽기 + 분석 필요)
모델: Sonnet
제약: 파일 수정 금지 — 읽기/분석만 (문제 발견 시 메인에게 보고)
```

## 검증 항목

```yaml
1_계획_준수:
  - TODO 체크리스트 항목이 모두 구현되었는가
  - 누락된 요구사항 없는가

2_파일_소유권:
  - 파일 할당 매트릭스 대비 실제 수정 파일 일치 확인
  - 매트릭스 외 파일 수정 여부 (위반 감지)

3_코드_품질:
  - 코딩 규칙 준수 ({project}/PROJECT.md "코딩 규칙" 섹션 기준)
  - null 체크, 예외 처리
  - 코드 스타일 일관성

4_에이전트_간_일관성:
  - 에이전트 A의 변경이 에이전트 B의 변경과 호환되는가
  - 공통 인터페이스 사용이 일관적인가
  - 네이밍 규칙 통일

5_빌드_가능성:
  - 명백한 컴파일 오류 (미선언 변수, 타입 불일치 등)
  - using 누락

6_일괄_안전패턴_전수_검증 (L-409 — 동일 패턴 일괄 적용 시 필수):
  - Task.Run 래핑 등 동일 안전패턴을 여러 메서드에 일괄 적용한 작업이면,
    적용 대상 시그니처(예: GetAwaiter().GetResult())를 프로젝트 전체 재grep하여 잔여 미적용 건 0개 확인
  - 위반_사례: 91375a97에서 Task.Run 일괄 적용 시 ExecuteQuery/BeginTransaction 2건 연속 누락 (L-409)
  - 완료_선언_전_필수: grep 결과가 0건(또는 의도된 예외만 남음)임을 명시
```

## 실행 절차

```yaml
1_Reviewer_디스패치:
  시점: 모든 구현 에이전트 완료 후
  방법: 메인이 팀에이전트로 spawn (ok_pipeline 팀에이전트 전면 위임 정책). 내부 서브에이전트 필요 시 Agent tool로 직접 spawn. 추가 팀에이전트 필요 시 메인에게 SPAWN_REQUEST 위임.
  프롬프트: |
    아래 에이전트들의 구현 결과물을 검증하라:

    [에이전트별 수정 파일 목록]
    [원본 TODO/계획 요약]
    [파일 할당 매트릭스]
    [프로젝트 코딩 규칙 요약]

    검증 항목: 계획 준수, 파일 소유권, 코드 품질, 일관성, 빌드 가능성

    결과 파일: {scratchpad}/review_report.md
    반환: 통과/불합격 + 요약 5줄 + 파일 경로

2_영향도_분석과_병렬_실행:
  Reviewer와 Impact Analyzer를 동시에 디스패치
  둘 다 읽기 전용이므로 충돌 없음

3_결과_처리:
  통과: otest 단계로 진행
  불합격: 리더가 문제 에이전트에 수정 지시 → 재검증
```

## 결과 형식

```markdown
# 구현 리뷰 보고서

## 판정: ✅ 통과 / ❌ 불합격

## 에이전트별 검증 결과
| 에이전트 | 파일 소유권 | 계획 준수 | 코드 품질 | 판정 |
|----------|-----------|----------|----------|------|

## 발견된 문제 (불합격 시)
- [심각도] (신뢰도 N/10) [에이전트] [파일:라인] — [문제 설명]

## 에이전트 간 일관성
- [호환성 문제 또는 "문제 없음"]
```

## 2단계 리뷰 (spec → quality)

```yaml
1단계_Spec_Compliance:
  목적: TODO 요구사항 100% 반영 여부
  검증: 각 TODO 항목 vs 실제 구현 대조
  스코프_드리프트_감지:
    방법: |
      1. TODO/계획서의 의도(intent) 요약
      2. 파일 할당 매트릭스 대비 실제 수정 파일 목록 대조
      3. 판정:
         - CLEAN: 계획과 구현 일치
         - SCOPE_CREEP: 계획 외 파일/기능 수정 발견 → 경고
         - MISSING: 계획 항목 중 미구현 발견 → 경고

    계획서_크로스레퍼런스:
      1. oplan 산출물(TODO_*.md, file_assignment.json) 읽기
      2. 각 계획 항목 분류:
         DONE: diff에 명확한 증거
         PARTIAL: 일부 구현, 엣지 케이스 누락
         NOT_DONE: diff에 증거 없음
         CHANGED: 다른 방법으로 같은 목표 달성

      3. NOT_DONE 항목 이유 조사:
         범위_축소: 의도적 제거 증거 (revert 커밋, 제거된 TODO)
         컨텍스트_소진: 작업 시작 후 중단 (부분 구현)
         요구사항_오해: 계획과 다른 방향으로 구현
         망각: 시도 흔적 없음

      4. 자동_판단 (사용자 확인 불필요):
         완료율 >= 80%: CLEAN으로 계속 진행
         완료율 < 80%: REQUIREMENTS MISSING으로 blocking 보고
         CHANGED 우세: 보고만 하고 계속 진행

    심각도: 정보성 (blocking 아님, 리더에게 보고)

    출력:
      스코프_체크: [CLEAN / DRIFT DETECTED / REQUIREMENTS MISSING]
      의도: 요청된 내용 1줄 요약
      전달: diff 실제 내용 1줄 요약
      계획_항목: N DONE, M PARTIAL, K NOT DONE
      [NOT DONE 항목: 조사 결과 + IMPACT]

  결과: PASS → 2단계 진행 / FAIL → 구현 에이전트 수정 후 재검증

Pre-Quality_패턴_스캔 (앵커링_편향_방지):
  원칙: |
    Quality 리뷰 시작 전, 코드를 읽기 전에 Grep으로 안티패턴 스캔 실행.
    코드를 먼저 읽으면 기존 구현을 "합리적"으로 수용하는 앵커링 편향 발생.
    패턴 스캔 결과를 확보한 후 코드 리뷰 진행.

  C#_안티패턴_3도메인 (기존):
    1_DB_쿼리:
      패턴: 'string\.Format.*SELECT|$".*SELECT|"SELECT.*"\s*\+'
      탐지: N+1 쿼리 (loop 안 DB 호출), SELECT *, 파라미터 미사용
    2_메모리_리소스:
      패턴: 'new\s+(SqlConnection|HttpClient|StreamReader)'  # using 없이
      탐지: IDisposable without using, string += in loop (StringBuilder 미사용)
    3_동시성:
      패턴: '\.Result[;\s]|\.Wait\(\)|async\s+void'
      탐지: Task.Result/.Wait() 데드락, async void fire-and-forget, lock 없는 공유 상태

  확장_12도메인 (신규):
    4_인증_인가:
      패턴: '\[AllowAnonymous\]|\.MapGet\(|\.MapPost\('
      탐지: [Authorize] 누락 엔드포인트, AllowAnonymous 남용
    5_입력_검증:
      패턴: 'Request\[|Request\.Query|Request\.Form'
      탐지: 비검증 사용자 입력 → SQL/커맨드/LDAP 주입
    6_암호화:
      패턴: 'MD5\.Create|SHA1\.Create|"password"|"secret"'
      탐지: MD5/SHA1 사용, 하드코딩 암호화 키/비밀번호
    7_에러_처리:
      패턴: 'catch\s*\{|catch\s*\(\s*\)|\.StackTrace'
      탐지: 빈 catch (예외 삼킴), 스택트레이스 직접 노출
    8_직렬화:
      패턴: 'BinaryFormatter|SoapFormatter|ObjectStateFormatter'
      탐지: 안전하지 않은 역직렬화 (CRITICAL)
    9_로깅:
      패턴: '\.Log.*(password|비밀번호|token|secret)'
      탐지: PII/비밀번호 로깅, 인증 실패 미로깅
    10_SSRF:
      패턴: 'new\s+Uri\(.*\+|HttpClient.*\+.*url'
      탐지: URL 구성에 사용자 입력 유입
    11_CORS:
      패턴: 'AllowAnyOrigin|WithOrigins\("\*"'
      탐지: 와일드카드 오리진 프로덕션 설정
    12_Enum_완전성:
      패턴: 'enum\s+\w+|switch\s*\('
      탐지: switch에서 새 enum 값 누락
    13_nullable:
      패턴: '\?\.\w+\.\w+|!\.|\bnull\b.*return'
      탐지: nullable 미체크 후 .Member 접근
    14_dead_code:
      패턴: '//\s*(TODO|HACK|FIXME|XXX)|#if\s+false'
      탐지: 미사용 메서드/변수 (정보성)
    15_LLM_신뢰경계:
      패턴: 'eval\(|exec\(|Process\.Start.*\+|ProcessStartInfo.*\+'
      탐지: eval()/exec()로 AI 출력 처리, 동적 명령 생성

  절차:
    1. 수정된 파일 대상으로 15도메인 패턴 Grep 실행
    2. 매치 발견 시에만 해당 라인 주변 5줄 컨텍스트 읽기
    3. 실제 문제 확인 후 finding에 추가

2단계_Code_Quality:
  목적: 코드 품질 (보안/동시성/데이터안전/유지보수성)

  신뢰도_보정 (Confidence Calibration):
    모든_발견사항: 반드시 신뢰도(1-10) 포함
    형식: "🔴 (신뢰도 N/10) 파일:라인 — 설명"
    기준:
      9-10: 코드 읽고 확인된 명확한 버그
      7-8: 높은 신뢰도 패턴 매치 — 정상 표시
      5-6: 중간 — "확인 권장" 주석 추가
      3-4: 낮음 — 💡 suggestion 전용 (blocking 아님)
      1-2: 매우 낮음 — 부록에만 포함
    블로킹_기준: 신뢰도 7+ 항목만 blocking (🔴) 처리
    보정_학습: |
      신뢰도 < 7로 보고한 항목이 실제 문제로 확인되면,
      해당 패턴의 기본 신뢰도를 향후 +1 상향 조정.

  Pass_1_CRITICAL:
    SQL_데이터_안전:
      - string.Format/문자열 보간으로 SQL 조립 → 파라미터화 필수
      - DELETE/UPDATE without WHERE → 전체 테이블 영향
      - 트랜잭션 없는 다중 DB 작업
    동시성_경합:
      - lock 없는 공유 상태 접근
      - async void (fire-and-forget 위험)
      - Task.Result / .Wait() (데드락 위험)
    인증_인가:
      - "[Authorize] 누락된 엔드포인트"
      - 권한 검사 누락
    null_참조:
      - nullable 타입 미체크
      - null 반환 후 .Member 접근
    Enum_완전성:
      - diff에서 새 enum/상수 추가 시:
        1. Grep으로 해당 enum 타입의 모든 사용처 검색
        2. switch/case에서 새 값 처리 여부 확인
        3. 누락 시 blocking 이슈로 보고

  Pass_2_INFORMATIONAL:
    조건부_사이드이펙트:
      - if 분기 안에서 DB 쓰기/파일 삭제 등 비가역 작업
      - 로깅 없는 catch (삼키는 예외)
    매직_넘버_결합:
      - 하드코딩 문자열/숫자가 여러 파일에 중복
      - 상수 정의 없이 직접 사용
    성능:
      - N+1 쿼리, 루프 내 DB 호출
      - 대용량 List/Array 불필요 복사
    데드_코드:
      - 사용되지 않는 변수/메서드
    네이밍_일관성:
      - 프로젝트 코딩 규칙(PROJECT.md "코딩 규칙" 섹션) 대비 일탈

  결과: PASS → 리뷰 완료 / FAIL → 구현 에이전트 수정 후 재검증

순서: 반드시 spec 통과 후 quality (동시 실행 금지)
```

## 심각도 분류

```yaml
이모지: 🔴 blocking | 🟡 important | 🟢 nit | 💡 suggestion | 🎉 praise
blocking: 머지 전 필수 수정
important: 수정 권장 (반대 시 논의)
nit: 선택 사항
발견사항_형식: "[이모지] (신뢰도 N/10) 파일:라인 — 설명"
```

## 리뷰 루프

```yaml
규칙: 리뷰 이슈 발견 → 동일 구현 에이전트가 수정 → 재리뷰
반복: 이슈 0건까지 (최대 2회, 이후 리더 개입)
금지: 수정 후 재리뷰 스킵
```

## 질문 접근법

```yaml
원칙: 명령 대신 질문으로 유도
❌: "에러 처리 필요" → ✅: "API 호출 실패 시 어떻게 동작해야 하나요?"
❌: "비효율적" → ✅: "10만 건에서 성능 영향 고려했나요?"
```

## 체크리스트

```yaml
Security: 인증/인가, 입력 검증, SQL 파라미터화, XSS
Performance: N+1 쿼리, 인덱싱, 페이지네이션, 블로킹 I/O
Testing: Happy path, Edge cases, Error cases, 결정론적 테스트
```

## 3단계 적대적 리뷰 (조건부 자동 발동)

```yaml
발동_조건 (OR — 하나라도 충족 시 자동 발동):
  조건_A: DIFF_LINES > 200 (git diff --stat 줄 수 기준)
  조건_B: classification이 O4 또는 O5
  조건_C: Pass 1에서 CRITICAL 발견사항 1개 이상
자동_판단: 사용자 확인 불필요 — 조건 충족 시 즉시 실행
스킵_조건: DIFF_LINES <= 200 AND classification이 O2/O3 AND CRITICAL 없음

판단: mcp__oio__file_read($HOME/.claude/session-env/${UUID}/classification) → O4 또는 O5 확인
DIFF확인: mcp__oio__bash_exec("git diff --stat | tail -1") → 변경 줄 수 추출

방법: |
  odev_review 팀에이전트 내부에서 서브에이전트(Agent tool)를 spawn하여 적대적 관점에서 리뷰:
  "이 코드가 프로덕션에서 실패할 방법을 찾아라.
   엣지 케이스, 레이스 컨디션, 리소스 누수,
   조용한 데이터 손상 경로를 찾아라.
   칭찬 없이 문제만 보고하라."

결과_처리:
  - FIXABLE: 구현 에이전트에 수정 지시
  - INVESTIGATE: 리더에게 판단 위임

주의:
  - 기존 2단계 리뷰와 중복 finding은 제거
  - 2단계 Quality PASS 후, odev_simplify 전에 실행
```

## odev_simplify 연계 (2단계 Quality 통과 후)

```yaml
시점: 2단계 Code Quality PASS 직후, otest 진행 전
조건:
  1. 분류 파일 확인: mcp__oio__file_read($HOME/.claude/session-env/${UUID}/classification)
  2. O3|O4|O5 → odev_simplify 발동 (무조건)
  3. O2 또는 파일 없음 → 스킵, otest로 직행

발동_방법:
  항상: 메인이 odev_simplify를 팀에이전트로 spawn (메인 직접 실행 금지)

순서: odev_review (읽기 전용) → odev_simplify (수정 가능) → otest
주의: odev_review 자체는 읽기 전용 유지. simplify는 별도 에이전트가 수정 수행.
```

## 제한사항

```yaml
읽기_전용: 파일 수정 절대 금지 (문제 발견 시 보고만)
scratchpad_필수: 결과를 반환 메시지에 전체 포함 금지
최대_재검증: 1회 (2회 이상 불합격 시 리더가 직접 개입)

performative_agreement_금지:
  금지_응답_패턴:
    - "맞습니다!", "훌륭합니다!", "좋은 지적입니다!"
    - "지금 바로 적용하겠습니다" (검증 전)
    - 기술적 확인 없는 수락
  허용_응답_패턴:
    - 기술적 요건 재진술
    - "수정됨. [변경 내용 간략히]"
    - 기술적 이유 있는 반박
  YAGNI_체크:
    "제대로 구현하라" 제안 수신 시:
      1. 코드베이스에서 실제 사용처 Grep
      2. 미사용: "이 엔드포인트가 호출되지 않습니다. 제거? (YAGNI)"
      3. 사용됨: 정상 구현 진행
```
