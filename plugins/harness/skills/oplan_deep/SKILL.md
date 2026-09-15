---
name: oplan_deep
description: "심층 설계 — Scout, 대안 탐색, Incremental Validation, YAGNI 검증"
invocation:
  user_callable: true
  pipeline_callable: true
  called_by: ["oplan(o4 자율선택 기본값)", "oplan(o5 자율선택 대안)", "oplan_normal(Deep)", "oplan_consult(Step 2 통합)"]
  calls: []
---
# oplan_deep — 심층 설계

## ogrill 5축 결손 판정 (oplan 내부 절차 — 절대 규칙)

> oplan_deep 팀에이전트는 Phase A(의도 분석) 진입 직전 5축(목표/범위/제약/완료기준/열린질문) 결손 카운트를 수행한다.
> 메인 에이전트는 이 판정을 수행하지 않는다 (CLAUDE.md "ogrill 호출 정책" 참조).
> 상세 절차: oplan/SKILL.md "ogrill 5축 결손 판정" 섹션 참조 (단일 출처).

## 적용 조건

- 새 기능/폼 생성
- 아키텍처 변경
- 다중 컴포넌트 수정
- 복잡도: 높음

## 설계 프로세스

### 0단계: goal.json 참조 (soft hint — 2차수 통합)

```yaml
적용: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/goal.json 존재 시에만
동작: |
  goal.intent → 설계 방향 시드 (1단계 아이디어 이해 강화)
  goal.scope_in → 탐색 대상 파일 우선순위 확정
  goal.constraints → 2단계 접근법 평가 시 제약 조건으로 활용
  goal.acceptance → 4단계 자아비판 체크리스트에 인수 기준 추가
부재_시: 본 단계 스킵, 기존 1단계부터 진행 (오류 아님, 폴백)
스키마: goal/SKILL.md "§3 goal.json 스키마 명세" 참조
```

### 1단계: 아이디어 이해

- 현재 프로젝트 상태 먼저 확인 (파일, 문서, 최근 커밋)
- **한 번에 한 질문씩** (다중 선택지 선호)
- 목적, 제약사항, 성공 기준에 집중

### 2단계: 접근법 탐색

```yaml
관점_전환_체크: (접근법 열거 전 수행)
  - [ ] 문제 정의가 올바른가? (1문장으로 기술)
  - [ ] 반대에서 보면? (제거↔추가, 호출자↔피호출자)
  - [ ] 범위가 적절한가? (확대: 시스템 / 축소: 변수)
  - [ ] 코드베이스 유사 패턴 있는가?
  교착 시: odebug Phase 3 교착 대응 모드

필수: 2-3개 다른 접근법 제시
각_접근법:
  - 장점/단점 명시
  - 트레이드오프 분석
  - 구현 난이도 / 소요 시간
추천: 이유와 함께 추천 옵션 먼저 제시

대안_평가: (접근법 열거 후 수행)
  형식: 실현가능성(1-5) × 가치(1-5) / 위험(1-5) = 점수
  차이 < 2.0 → 추가 분석 / 차이 >= 2.0 → 최고 점수 채택
```

### 3단계: Incremental Validation

```yaml
설계_제시_방식:
  - 200-300단어 섹션으로 분할
  - 각 섹션 후 내부 검증
  - 커버 항목:
    - 아키텍처
    - 컴포넌트
    - 데이터 플로우
    - 오류 처리
    - 테스트 전략
```

### 4단계: 자아비판 (Self-Critique)

> 검토/설계/계획 완료 후, 자기 산출물을 비판적으로 재검토.
> "내가 놓친 것은 없는가?" 관점에서 자체 검증.

```yaml
자아비판_체크리스트:
  구조적_검토:
    - [ ] 요구사항을 모두 반영했는가? (빠뜨린 항목 없는가?)
    - [ ] 설계가 과잉하지 않은가? (YAGNI 재확인)
    - [ ] 대안 중 더 단순한 방법이 있었는가?
  기술적_검토:
    - [ ] 영향도 분석에서 누락된 파일/심볼이 있는가?
    - [ ] 에지케이스를 충분히 고려했는가?
    - [ ] 하위 호환성을 깨뜨리는 변경이 있는가?
  실행_검토:
    - [ ] 에이전트 할당이 적절한가? (병목 없는가?)
    - [ ] 테스트 시나리오가 완료 기준을 커버하는가?
    - [ ] 의존성 순서가 올바른가?

자아비판_결과:
  문제_발견: 해당 섹션 수정 후 재검증
  문제_미발견: "자아비판 통과" 기록 후 다음 단계 진입

수행_시점: Step 10(검증) 완료 직후, 계획서 저장 직전
```

### 5단계: YAGNI 검증

```yaml
모든_설계_항목에:
  질문: "이것이 현재 요청에 실제로 필요한가?"
  제거: 미래 요구사항, "있으면 좋겠다", "나중에 필요할 수도"
  유지: 현재 요청의 핵심 기능만
```

### 6단계: Multi-Phase Batch 분할 판정

> YAGNI 검증 완료 후, TODO 최종 확정 전 수행.
> 대규모 작업을 독립 검증 가능한 batch로 분할하여 ok_pipeline Auto-Loop가 자동 실행.

```yaml
시점: YAGNI 검증 완료 후, 계획서 저장 전
목적: 대규모 작업을 독립 검증 가능한 batch로 분할

판정_기준:
  단일_사이클: 파일 ≤9개 AND 줄 ≤500 AND 순차의존 없음
  다단계_필요: 위 조건 미충족 (OR 하나라도)

다단계_분할_시:
  1. 의존성 계층 분석: DB → 공통모듈 → 백엔드 → 프론트엔드
  2. 각 계층을 독립 batch로 분할
  3. batch별 file_assignment + TODO 섹션 분리
  3.5. depends_on_batch DAG 구성 (순환 금지):
    각 batch의 depends_on_batch는 **이전 batch_id만 참조** (N은 N-1 이하만)
    순환 참조 절대 금지 (batch 2→3, 3→2 같은 형태)
    독립 batch는 depends_on_batch: null
    생성 후 자체 검증: 위상 정렬 가능한지 확인
  4. phase_batches.json 생성 (oplan SKILL.md "Phase Batch 출력 규격" 스키마 참조)
     ★ immutable guard 우회를 위해 작성 전후 플래그 관리 필수:
     (a) 쓰기 전: mcp__oio__file_write(${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${PIPELINE_UUID}/oplan_writing_phase_batches, "")
     (b) mcp__oio__file_write로 phase_batches.json 작성
     (c) 쓰기 완료 후: mcp__oio__file_delete(${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${PIPELINE_UUID}/oplan_writing_phase_batches)
     이 플래그 없이 쓰기 시 phase_batches_immutable_guard.sh가 hook으로 차단
  5. TODO 파일에 batch 구분 마커 추가:
     "## [Batch 1] 핵심 인프라" / "## [Batch 2] 기능 구현" 등
  6. 모든 batch의 TODO는 동일 수준의 구체성 필수

절대_금지:
  - batch 분할 후 "Phase 1만 상세화하고 나머지는 개요만" 작성
  - "후속 /oo로 실행" 문구 출력 — phase_batches.json이 Auto-Loop를 보장
  - batch 수가 10을 초과하는 분할 (ok_pipeline max_batches=10)
  - phase_batches.json 생성 후 수정 금지 (immutable)
  - current_batch 필드 생성 금지 (외부 파일 단독 관리)
```

### 7단계: Wave 기반 spawn 설계 (L-439, L-440)

> 다파일 코드 추가 시 Wave 단위로 의존성을 정리하여 병렬 spawn 충돌 0 달성.

```yaml
Wave_기반_spawn_패턴:
  목적: 다파일 코드 추가 시 의존성 사전 정리 → 병렬 spawn 충돌 0 달성
  적용_조건: 신규 파일 5개 이상 OR 인터페이스+구현체+호출자 3계층 구조

  Wave_구조:
    Wave1_타입_인터페이스: enum/interface/factory 시그니처/모델 클래스
      - 가장 먼저 단일 또는 소수 에이전트로 작성 (의존성 0)
      - 후속 Wave가 참조할 계약 확정
    Wave2_구현체_병렬: Wave1의 인터페이스를 구현하는 클래스들
      - 인터페이스가 이미 확정되어 있어 병렬 spawn 충돌 0
      - 각 구현체는 독립 파일이므로 N개 에이전트 동시 실행
    Wave3_통합: 호출자 ViewModel/Controller가 Factory로 구현체 선택
      - Wave1 인터페이스에 의존 → Wave2 구현체에 무관
      - 호출자 수정량 최소화

  인터페이스+팩토리_도입_기준 (L-440):
    조건: 동등한 분기 모드 2개 이상 (예: Legacy vs Unified, Local vs Remote)
    효과: 호출자(ViewModel)는 인터페이스+Factory만 의존 → 모드별 분기 코드 제거
    필수_요소:
      - 공통 인터페이스 (IXxxPipeline 등)
      - Factory (모드 enum → 구현체 인스턴스)
      - 호출자: _field 1개 + Factory.Create() 1회 + 이벤트 구독

  실증_사례 (2026-05-15):
    14파일 1110줄 (음성 파이프라인 2모드) — Wave 기반 spawn으로 역라우팅 0회
    Wave1: enum + interface + Factory (3개 에이전트 → 1차 완료)
    Wave2: Legacy + Unified + Sentiment + Cost + Hallucination (5개 에이전트 병렬)
    Wave3: ViewModel + XAML + App.xaml (3개 에이전트 통합)
```

## MCP 연동

```yaml
Sequential_Thinking: 복잡한 의사결정 분해
vibe-check-mcp: 계획 메타인지 검증
  - 가정 식별
  - 터널 비전 방지
  - 연쇄 오류 예방
odebug Phase 3: 교착 대응 (교착 시)
```

## 사전 조사 (Scout)

Deep 진입 시 **리더와 병렬로** 코드베이스를 탐색하여, 리더가 설계에 집중할 수 있도록 조사 부담을 위임합니다.

```yaml
활성화: Deep 진입 시 (복잡도 중간 이상)
불필요: Quick 시 (단순 작업은 리더가 직접 탐색)

에이전트_유형: Explore (읽기 전용, 저비용)
모델: Haiku (단순 탐색) 또는 Sonnet (복잡 분석)
제약: 파일 수정 절대 금지 — 읽기/탐색만
```

> Scout 조사 범위, 실행 절차, 에이전트 역할별 유형, 프리셋 조합 상세: [references/SCOUT_DETAILS.md](references/SCOUT_DETAILS.md)

```yaml
Scout_요약:
  활성화: Deep 진입 시 (복잡도 중간 이상)
  에이전트: Explore 유형, Haiku/Sonnet 모델
  역할: scout-code/db/docs/deps, analyzer-impact/perf/risk, architect-alt/proto, planner-task, simulator-edge, reviewer-plan, verifier-exist
  제한: 읽기 전용, 최대 4에이전트, 파일당 10개
```

## 대안 탐색 (중간/높은 복잡도)

```yaml
규칙: 계획 작성 전 2-3가지 접근법 비교
형식: 각 접근법별 장단점 + 추천안 명시
스킵: 낮은 복잡도 (단일 파일, 명확한 패턴)
기록: TODO_*.md에 "## 접근법 비교" 섹션 추가
```

## 반복 검토

### 검토 체크리스트 (매 검토마다 전체 확인)

```yaml
논리적_완전성:
  - [ ] 모든 요구사항 반영됨
  - [ ] 단계 순서 논리적
  - [ ] 전제조건 명시됨
  - [ ] 대안 접근법 검토됨 (중간/높은 복잡도)

기술적_타당성:
  - [ ] API/함수 존재 확인
  - [ ] 데이터 타입 호환
  - [ ] 성능 이슈 없음
  - [ ] YAGNI: 범위 외 불필요 기능 없음

호환성_영향도:
  - [ ] 사이드 이펙트 없음
  - [ ] DB 영향 검토 완료
  - [ ] 다른 기능 영향 없음

이전_수정_확인 (2차부터):
  - [ ] 지적사항 반영 완료
  - [ ] 새 문제 발생 없음
```

### 반복 로직

```yaml
검토_최대_횟수 (복잡도별 차등):
  낮음: 1회 고정 (Quick 경로)
  중간: 최대 3회
  높음: 최대 5회
```

```
연속_무결 = 0
MAX = 복잡도별_최대_횟수

WHILE (검토횟수 < MAX):
  검토 실행 (체크리스트 전체)
  IF 문제점 > 0 OR 의미있는_개선안 > 0:
    회귀_단계 = 회귀_판단(문제점)
    IF 회귀_단계 < 4:
      해당 단계부터 재실행 (1→2→3→4)
    ELSE:
      4단계 내에서 수정 적용
    연속_무결 = 0 → 검토횟수++ → CONTINUE
  ELSE:
    연속_무결++ → 검토횟수++
    IF 연속_무결 >= 2:
      BREAK (종료)

IF 검토횟수 == MAX:
  LOG "⚠️ MAX회 검토 도달, 현재 상태로 진행"
```

### 회귀 판단 로직

검토에서 문제 발견 시, 문제 유형에 따라 돌아갈 단계를 판단:

```yaml
→ 1단계(탐색)로 회귀:
  - API/함수/메서드가 실제로 존재하는지 불확실
  - DB 스키마(테이블명, 컬럼명, 타입) 불일치 의심
  - 파일 경로/클래스 구조가 실제와 다를 수 있음
  - 전제조건의 근거가 추측(코드 확인 안 됨)
  판단기준: "이 정보를 코드/DB에서 직접 확인했는가?" → No면 1단계

→ 2단계(TODO 재작성)로 회귀:
  - Task 순서/의존관계 논리 오류
  - 파일 경로/줄번호 틀림 (탐색은 정확하나 반영 오류)
  - 누락된 Step 발견 (기존 탐색으로 보완 가능)
  판단기준: "탐색 결과는 맞는데 TODO 구성이 잘못" → 2단계

→ 3단계(대안 탐색)로 회귀:
  - 현재 접근법의 근본적 한계 발견
  - 더 나은 패턴/라이브러리 존재 가능성
  - 성능/복잡도 문제로 접근법 자체 재검토 필요
  판단기준: "접근법을 바꿔야 하는가?" → Yes면 3단계

→ 4단계(검토 내 수정):
  - 오타, 표현 수정, 미세 조정
  - 체크리스트 항목 보완 (정보는 충분)
  판단기준: "가지고 있는 정보로 수정 가능한가?" → Yes면 4단계
```

### 종료 조건

- ✅ 연속 2회 문제점 == 0 AND 의미있는_개선안 == 0
- 최소 2회, 최대 MAX회 (복잡도별 차등: 낮=1, 중=3, 고=5)
- 회귀 발생 시 검토횟수 리셋하지 않음 (최대 MAX회 유지)

### 개선안 판단 기준

- 의미 있음: 버그 예방, 50%+ 간소화, 필수 누락 보완
- 의미 없음: 취향 차이, 10% 미만 개선, 범위 밖 기능

## 검수조건 산출물 (acceptance_criteria.json)

> otest Phase 2에서 구현 검증 기준으로 사용.
> oplan_deep은 acceptance_criteria.json을 반드시 생성해야 한다.

```yaml
생성_시점: 설계 완료 후, 계획서 저장 전
저장: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/plans/acceptance_criteria.json
형식: {"criteria": [{"id":"AC-001", "category":"backend|frontend|db|api", "description":"...", "method":"curl/screenshot/query", "expected":"...", "priority":"must|should|nice"}]}

검수_조건_작성_지침:
  - must: 요구사항에서 명시된 핵심 기능 (누락 시 실패)
  - should: 품질/사용성 기준 (80% 미달 시 경고)
  - nice: 추가 개선 사항 (FAIL이어도 통과)
  - method: 구체적 검증 방법 (curl 명령, 스크린샷 비교, SQL 쿼리 등)
  - expected: 측정 가능한 기대 결과 (HTTP 200, 특정 필드 존재 등)

  auto_script (must 항목 80%+ 필수):
    - 각 must/should 항목에 자동 검증 스크립트 포함
    - sandbox: curl, jq, python3, grep, test만 허용
    - exit code 0 = PASS, 그 외 = FAIL
    - 예시:
      method: "GET /api/users → 200"
      auto_script: "curl -s -o /dev/null -w '%{http_code}' http://localhost:5000/api/users | grep -q 200"

  canary_test (필수 1개):
    - criteria에 expected_result=FAIL 항목 포함
    - 예시: {"id":"CANARY-001", "expected_result":"FAIL", "auto_script":"curl -s http://localhost:5000/api/nonexistent | grep -q 404", "priority":"must"}
    - 목적: otest 에이전트가 실제 검증 없이 전부 PASS 처리하는 것을 감지

  immutable_잠금:
    - oplan 생성 후 acceptance_criteria.json은 수정 금지
    - odev/otest 에이전트가 criteria를 조작하는 것을 원천 차단
    - 보호 방법: oio intent lock

  ★비-CRUD 작업(hook/스크립트/인프라 수정 등 REST API·DB CRUD가 구조적으로 없는 작업) 필수 규칙★
  (L-465 재발방지 — F-CRUD-1 게이트가 tier=O3~O5에서 파일 부재를 무조건 차단하므로,
  CRUD 항목이 0건이어도 acceptance_criteria.json 파일 자체는 반드시 생성한다. 스킵 금지):
    최상위_필드_스키마: {"crud_대상": true|false, "crud_미해당_사유": "...", "작업유형": "...", "criteria": [...]}
      - crud_대상: 이 작업에 저장/등록/수정/삭제를 요구하는 검수 항목이 있는가 (false = 비-CRUD)
      - crud_미해당_사유: crud_대상=false일 때 필수. 빈 문자열이면 게이트가 면제를 거부한다(fail-closed)
      - 작업유형: 예) "hook_infra", "script", "config" 등 자유 서술
    비-CRUD_검수_항목_작성_지침 (method/verify/then/expected 중 하나에 아래 어휘 포함 — verify_crud_executed.py의
    INSPECTION_HINTS 상수와 동일 어휘. 저장을 요구하는 동사(저장/등록/입력/생성/삽입/반영/커밋 등)가 섞이면
    CRUD로 간주되어 면제가 무효화되므로 절대 섞지 말 것):
      사용_가능_어휘: grep / git diff / diff / 코드상 / 코드 상 / 소스 / 정적 / 존재하지 않는다 / 없음 /
                      무변경 / 변경되지 않 / 빌드 로그 / 로그에 / 판정 근거 / 스크린샷 / 커버리지 / 표기 / 구분 표
      예시_criterion: "hook 스크립트가 bash -n 문법 검증을 통과하고 CRLF가 혼입되지 않는다"
      예시_method: "bash -n 으로 문법 확인 후 grep 으로 CR 문자 없음을 코드상 확인"

  ★item_crud 필드 필수화 (criteria[] 원소마다 — 상류 처방)★:
    배경: F-CRUD-1 게이트가 기존에는 AC 본문의 자연어(동사/부정어 패턴)로 CRUD 여부를 판정하다가
          3회 연속 오판(부정어로 회피 통과 / 검증형 문구를 CRUD로 오탐)했다. 이제 게이트는
          criteria[] 원소마다 명시된 item_crud 값을 1순위 판정 근거로 그대로 따른다.
    정의: criteria[] 원소(각 AC 항목)마다 "item_crud" (boolean) 필드를 필수 기재한다.
      - item_crud: true  — 이 항목은 실제 데이터 생성/수정/삭제/조회를 요구한다 (CRUD 실행 증거 필요).
      - item_crud: false — 이 항목은 코드/문서/설정 검증만 요구한다 (CRUD 증거 불필요).
    판정_기준: "이 항목을 충족하려면 실제로 데이터가 저장·변경·삭제되어야 하는가?"
      → YES면 true. 코드를 읽거나 파일을 비교하는 것으로 끝나면 false.
    ⚠️ item_crud는 일반적으로 판정을 결정하므로 작성자는 이 필드를 정확히 기재해야 한다: 게이트는
       item_crud 값을 그대로 따르므로, item_crud를 실제 사실과 다르게(회피 목적으로 false, 또는
       부주의로 누락) 기재하지 않는 것이 작성자(oplan)의 책임이다.
       단, crud_대상=false 파일 레벨 선언의 타당성 검증에서는 AC 본문과 실제 변경 파일이 함께
       대조되며, 선언이 실제와 모순되면 item_crud 값과 무관하게 차단된다. 즉 "필드만 맞추면
       무엇을 쓰든 된다"는 뜻이 아니다.

  crud_대상_과_item_crud_관계 (파일_레벨_vs_항목_레벨 — 혼동 금지):
    - crud_대상: acceptance_criteria.json **전체**가 비-CRUD 작업인지 판정하는 파일 레벨 필드.
    - item_crud: **개별 AC 항목**이 CRUD 실행 증거를 요구하는지 판정하는 항목 레벨 필드.
    - crud_대상=false인 파일도 criteria[] 원소마다 item_crud(보통 전부 false)를 반드시 기재해야 한다.

    완성된_JSON_예시 (CRUD 항목 true + 검증형 항목 false 대비 포함 — 그대로 필드 구조를 복붙하여 값만 교체):
      {"crud_대상": true, "crud_미해당_사유": "", "작업유형": "backend_api",
       "criteria": [
         {"id":"AC-001", "item_crud":true, "category":"backend", "description":"사용자 저장 API가 DB에 실제 반영된다",
          "method":"POST /api/users 호출 후 DB COUNT 전후 비교 및 write_log 확인",
          "expected":"count_after = count_before + 1", "priority":"must"},
         {"id":"AC-002", "item_crud":false, "category":"infra", "description":"기존 저장 로직 코드가 변경되지 않았다",
          "method":"git diff 로 save 함수 무변경을 코드상 확인",
          "expected":"diff 없음", "priority":"must"}
       ]}
      비-CRUD 전용 파일 예시:
      {"crud_대상": false, "crud_미해당_사유": "hook 셸 스크립트 수정 작업으로 REST API·DB 변경이 없다",
       "작업유형": "hook_infra",
       "criteria": [{"id":"AC-001", "item_crud":false, "category":"infra", "description":"hook 문법 무결성",
                      "method":"bash -n 으로 문법 검증, grep 으로 CRLF 혼입 여부 코드상 확인",
                      "expected":"문법 오류 없음, CR_COUNT=0", "priority":"must"}]}
```
