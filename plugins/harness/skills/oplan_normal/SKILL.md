---
name: oplan_normal
description: "o3 전용 표준 계획 수립 스킬 — Step 1~10 전체 실행. Quick/Deep 모드 자율 결정. Quick: 파일 ≤3개, 패턴 반복. Deep: 파일 4개+, 새 패턴, 인터페이스 변경 시 oplan_deep+SIM_PROCEDURE(references/SIM_PROCEDURE.md)+oplan_review. 아키텍처 변경 필요 시 o4 승격."
invocation:
  user_callable: false
  pipeline_callable: true
  called_by: ["oplan(o3)"]
  calls: ["oplan_deep(Deep경로)"]
---
# oplan_normal — o3 전용 표준 계획 수립

> **ℹ️ Step 명명**: 이 파일은 oplan 프레임워크의 Phase A~J 대신 독자적인 Step 1~10을 사용합니다. Phase→Step 리네임 완료. oplan 프레임워크 Phase와 혼동하지 마세요.

o3(Normal) 파이프라인 전용 계획 수립. 독자적 실행 Phase A~J를 전체 실행하되, Quick/Deep 모드를 자율 판정하여 적정 수준의 계획서를 생성한다.

## ogrill 5축 결손 판정 (oplan 내부 절차 — 절대 규칙)

> oplan_normal 팀에이전트는 Phase A(의도 분석) 진입 직전 5축(목표/범위/제약/완료기준/열린질문) 결손 카운트를 수행한다.
> 메인 에이전트는 이 판정을 수행하지 않는다 (CLAUDE.md "ogrill 호출 정책" 참조).
> 상세 절차: oplan/SKILL.md "ogrill 5축 결손 판정" 섹션 참조 (단일 출처).

## 트리거 조건

```yaml
수동_트리거: 사용자가 '/oplan_normal' 직접 호출 (드문 경우)
자동_트리거: oplan이 o3 판정 후 호출 시
```

## entry_tier 기록 (사용자 규칙3 — 수동 트리거 시)

```yaml
entry_tier_기록:
  적용: 수동_트리거(/oplan_normal 직접 호출) 시에만
  시점: 수동 호출 진입 직후
  명령: mcp__oio__session_state(uuid="${UUID}", key="entry_tier", value="OK")
  주의: 자동_트리거(oplan 경유) 시는 ok/SKILL.md가 이미 entry_tier=OK 기록 → 추가 기록 불필요
  상태: state 전이와 독립 (인스턴스 플랜 그룹과 동일 패턴)
```

## Quick/Deep 판정 기준

```yaml
Quick_조건 (AND — 모두 충족 시):
  - 수정 대상 코드 파일 ≤ 3개
  - 기존 패턴 반복 (동일 파일 내 유사 코드 존재)
  - 영향도 제한적 (호출자/피호출자 변경 없음)
  - DB 스키마 변경 없음

Deep_조건 (OR — 하나라도 해당 시):
  - 수정 대상 코드 파일 ≥ 4개
  - 새로운 패턴 도입 (기존에 없는 구조)
  - 인터페이스 변경 (public API, DTO, 프로토콜)
  - DB 스키마 변경 포함
  - 비즈니스 로직 복잡도 높음
```

## Phase 0: goal.json 생성 (PoC — goal 스킬 연동)

```yaml
적용: 모든 o3 작업 (Quick/Deep 공통)
시점: Step_1(의도분석) 진입 전, oplan_normal 로딩 직후 1회
방법: Skill('goal') 직접 로딩 (별도 팀에이전트 spawn 없음)
산출물: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/goal.json
스키마: goal/SKILL.md "goal.json 스키마 명세" 참조
이후_Phase:
  - Step_1 의도분석: goal.intent를 시드로 사용
  - Step_8 acceptance_criteria.json: goal.acceptance를 시드로 확장

동시_산출 (★사이클45 — 상류 처방★):
  - Phase 0 에서 acceptance_criteria.json 초안을 goal.acceptance 로부터 함께 내놓는다.
    경로: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/plans/acceptance_criteria.json
  - 목적: 부재가 사이클 중반(otest 관문)에 드러나는 일을 없앤다.
    관문(otest_make/scripts/verify_crud_executed.py)은 옳게 동작한다 — 고칠 대상이 아니다.
    늦게 드러나는 시점 쪽을 당긴다.
  - Step_8 은 이 초안을 확장·확정한다 (2단 구조).
    ★기존 Step_8 절차는 그대로 둔다★ — 14개 프로젝트 공용이라 하위호환을 깨지 않는다.
  - 초안이 이미 있으면 Phase 0 은 건너뛴다 (멱등).
  - goal.json 이 없으면 초안도 내놓지 않는다 — Step_8 이 종전대로 단독 수행한다 (폴백).
제약:
  - goal.locked는 false로 생성 (oplan_normal은 lock_request를 전달하지 않는다).
    locked=true는 oto가 자체 생성할 때만 사용한다 — goal/SKILL.md §4 Phase_D 참조.
    oto가 이미 locked=true로 만들어 두었으면 write_guard F-GOAL-1이 재생성을 차단하므로,
    기존 goal.json을 읽어 시드로만 쓰고 생성을 건너뛴다.
  - goal.json 부재 시 기존 동작 폴백 (오류 아님)
  - odeep/oconsult/odebate/oralph 통합, ofinish 게이트, hook 강제화는 본 PoC 범위 외
실패_처리: goal/SKILL.md 검증 실패 시 경고 출력 후 Step_1 계속 (PoC라 강제 차단 없음)
```

## Quick 모드 실행 절차

```yaml
Step_1_의도분석:
  - 핵심 의도 추출 + 수정 범위 산정
  - goal.json이 존재하면 goal.intent를 시드로 사용 (PoC — Phase 0 생성 결과 참조)

Step_2_코드탐색:
  - 수정 대상 파일 읽기
  - 관련 심볼/의존성 파악

Step_3_영향도:
  - 수정 파일의 참조 관계 확인
  - 사이드이펙트 예측

Step_4_설계:
  - 수정 방향 결정
  - 기존 패턴 준수 확인

Step_5_YAGNI:
  - 과잉 설계 여부 점검

Step_6_대안:
  - 대안 1개 이상 검토 (간략)

Step_7_TODO:
  - 구현 TODO 리스트 (체크박스)
  - 파일별 수정 내용 + 예상 줄 수

Step_7.5_Multi_Phase_Batch_판정:
  조건: Deep 모드 AND (파일 6개+ OR 줄 300줄+)
  동작: oplan_deep "6단계: Multi-Phase Batch 분할 판정" 참조하여 phase_batches.json 생성
  Quick_모드: 항상 단일 사이클 (batch 분할 불필요 — phase_batches.json 미생성)

Step_8_테스트_검수조건:
  - 테스트 시나리오 목록
  - acceptance_criteria.json 생성 (o3~o5 필수 — ★물리 강제됨★):
    저장: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/plans/acceptance_criteria.json
    형식: {"criteria": [{"id":"AC-001", "category":"backend|frontend|db|api", "description":"...", "method":"...", "expected":"...", "priority":"must|should|nice"}]}
    ⚠️ 계획서 본문 표로만 쓰고 이 파일을 빠뜨리면 안 된다 (사이클31 실측 사고):
       CRUD 실행증거 게이트(verify_crud_executed.py)가 이 파일을 입력으로 읽는다.
       파일이 없으면 게이트가 무력화되므로, o3~o5 에서 부재 시 게이트가 exit 1 로 차단하고
       write_guard.sh F-CRUD-1 이 otest_done/make_ok 쓰기를 물리 차단한다.
       ⇒ 이 파일을 생성하지 않으면 파이프라인이 otest 에서 진행 불가하다.
    ★CRUD 항목 필수 표기★ (저장/등록/수정/삭제를 다루는 검수 항목):
       category 를 "crud" 또는 "db" 로 두거나 criterion 에 저장/등록/수정/삭제 동사를 남긴다.
       그리고 검증 방법에 ① 저장 경로 실행 로그 ② DB 전후 COUNT 실측 을 명시한다.
       "차단됨을 확인" 만으로 끝나는 검수문은 쓰지 마라 — 차단 확인은 저장 검증이 아니다.
       (evidence 기록 시 write_log / count_before / count_after 3필드가 요구된다)
    must: 전부 PASS 필수 (1개 FAIL → 역라우팅)
    should: 80%+ PASS (미달 시 경고)
    nice: 참고용
  - acceptance_criteria.json에 auto_script 필드 추가 (must 항목 80%+ 필수):
    형식 확장: {"criteria": [{"id":"AC-001", ..., "auto_script":"curl -s -o /dev/null -w '%{http_code}' http://localhost:5000/api/users | grep -q 200"}]}
    auto_script 작성 규칙:
      - sandbox 허용 명령만: curl, jq, python3, grep, test
      - exit code 0 = PASS, 그 외 = FAIL
      - 에이전트 주관 개입 없이 자동 판정
    canary_test (필수 1개):
      - expected_result=FAIL인 항목 포함 (예: 존재하지 않는 엔드포인트 404 확인)
      - 목적: 기계적 PASS 처리 감지
    immutable: oplan 생성 후 acceptance_criteria.json 수정 금지 (oio intent lock)
  - UI 변경 포함 시: UI_테스트_시나리오 항목 추가 (category=frontend)
  - goal.json이 존재하면 goal.acceptance를 acceptance_criteria.json의 시드로 확장 (PoC — soft 연동)
  - ★비-CRUD 작업(hook/스크립트/인프라 수정 등 REST API·DB CRUD가 구조적으로 없는 작업) 필수 규칙★
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

Step_8.5_ui_touched_판정:
  적용: o3~o5 모두 (oplan_normal/oplan_simple/oplan_deep 공통 단계)
  시점: Step_8(테스트 검수조건) 완료 후, Step_9(에이전트 할당) 진입 전
  목적: §4 파일 할당 매트릭스의 수정 대상 파일을 UI 패턴으로 매칭하여
        otest_ui 강제 여부를 사전 판정 (UI 미접촉 작업 false negative 차단)
  절차:
    1. §4 파일 할당 매트릭스에서 모든 file path 수집 → checked_files 배열
    2. 각 path에 대해 UI_PATTERN_REGEX 매칭:
       UI_PATTERN_REGEX='\.(Designer\.cs|xaml|xaml\.cs|axaml|tsx|jsx|razor|css|html|vue)$|(^|/)Form[^/]*\.cs$|(^|/)Page[^/]*\.cs$|.*Control\.cs$|(^|/)View[^/]*\.cs$|(^|/)ViewModel[^/]*\.cs$'
    3. 매칭된 패턴들 → matched_patterns 배열
    4. matched_patterns 비어있으면 touched=false, 아니면 touched=true
    5. ui_touched.json 작성:
       경로: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/evidence/ui_touched.json
       내용: {"version":"1.0","touched":{true|false},"checked_files":[...],
              "matched_patterns":[...],"decided_by":"oplan",
              "ts":"<ISO8601>","git_diff_verified":false,"user_override":false}
    6. 작성 도구: mcp__oio__file_write (overwrite=true)
  실패_처리:
    - 매트릭스 비어있으면 (예: 분석 단독 모드) ui_touched.json 미작성 → 기존 동작 폴백
    - 작성 실패 시 경고 로그만 출력하고 진행 (계획 자체는 성공)

Step_9_에이전트:
  - odev 에이전트 수 결정 (1~3개)
  - 파일 할당

Step_10_검증:
  - 계획 자체 검증 (요구사항 커버리지)

수행_않음 (Quick):
  - oplan_deep (Scout 없음)
  - oplan_deep references/SIM_PROCEDURE.md (시뮬레이션 없음)
  - oplan_review (별도 검증 없음)
```

## Deep 모드 실행 절차

```yaml
Step_1~10: Quick과 동일하게 전체 실행

추가_실행:
  oplan_deep (Skill('oplan_deep') 직접 로딩으로 호출):
    - Scout 에이전트 ×1~3 (haiku) — 코드베이스 탐색
    - 대안 탐색 (2개 이상)
    - Incremental Validation
    - YAGNI 심층 검증

  oplan_deep references/SIM_PROCEDURE.md:
    - 시뮬레이션 검증 (정상/예외/엣지케이스)
    - 시나리오 수: 상황에 따라 자율 결정

  oplan_review:
    - 요구사항 준수 검증
    - 기술적 타당성 검증
```

## 산출물

```yaml
형식: 마크다운 계획서
분량: 100~300줄
구조:
  ## 의도 분석
  - 핵심 요구사항
  - 수정 범위

  ## 코드 탐색 결과
  - 파일별 현재 상태

  ## 영향도 분석
  - 참조 관계
  - 사이드이펙트

  ## 설계 결정
  - 수정 방향
  - [Deep 시] 대안 비교표

  ## TODO
  - [ ] 파일: 수정 내용 (~N줄)
  ...

  ## 테스트 시나리오
  - 시나리오 목록

  ## 에이전트 할당
  - 에이전트 수: N개
  - 파일 할당표

  ## 예상 규모
  - 파일 수: N개
  - 수정 줄 수: ~N줄
  - 모드: Quick / Deep
```

## WPF 레이아웃 설계 필수 규칙 (L-424)

```yaml
ItemsControl_가변높이_패턴:
  표준_패턴: ItemsControl + ItemsPanelTemplate(StackPanel) + ItemTemplate(Border Height={Binding DisplayHeight})
  표준_구현:
    - ViewModel이 항목 추가 시 전체 DisplayHeight 재계산 (RecalculateXxxHeights 메서드)
    - DisplayHeight = durationSeconds * 상수 (예: 1.5) → ViewModel 프로퍼티에 저장
    - XAML: Border Height={Binding DisplayHeight} — 단순 직접 바인딩
  장점: 구조 단순, WPF 표준, 추가 우회 코드 불필요

  안티패턴 (즉시 기각):
    - ItemsPanelTemplate=Grid + 코드비하인드 RowDefinition 동적 생성
    - 이유: 3중 우회 필요 — ItemContainerGenerator(비동기) + CollectionChanged 수동 구독 + Grid.SetRow 명령형 호출
    - 증상: 겹침(모든 아이템 동일 위치), 레이아웃 갱신 안 됨, CollectionChanged 미연결 등
    - 판정: oplan 설계 단계에서 이 패턴을 제안하는 경우 즉시 StackPanel+DisplayHeight 패턴으로 전환

  설계_체크포인트:
    1. ItemsControl에서 가변 높이가 필요한가? → StackPanel + ViewModel.DisplayHeight 바인딩
    2. ItemsPanelTemplate에 Grid를 쓰려는가? → 안티패턴 → 기각 → StackPanel으로 대체
    3. 코드비하인드에서 RowDefinition을 동적 생성하려는가? → 동일 안티패턴 → 기각

2모드_레이아웃_토글_패턴 (L-450):
  트리거: "가로/세로 전환", "방향 토글" 등 동일 콘텐츠 2가지 레이아웃 요구
  증상_진단: 토글 무반응 신고 = 토글 바인딩은 정상이나 '반응할 레이아웃 미구현'인 경우가 많음
            → 바인딩보다 "반응할 레이아웃 존재 여부" 먼저 확인

  표준_패턴 (Option B):
    - 모드별 ItemsControl 2개를 별도 컨테이너에 배치
    - 기존 마크업은 한 모드(예: 세로)로 byte-identical 보존 (래핑만, 내부 무수정)
    - 신규 모드(예: 가로)는 ScrollViewer + ItemsControl(StackPanel Orientation + Border Width=DisplayWidth)
    - 두 컨테이너 Visibility를 StringEqualsToVisibilityConverter 등으로 모드 프로퍼티 토글
    - L-389(ItemsPanel.LoadContent 미사용) + L-424(ItemsPanel=StackPanel+Orientation만) 절대 준수

  안티패턴 (즉시 기각):
    - 단일 ItemsControl의 ItemsPanel을 런타임에 LoadContent로 교체 (L-389 위반)
    - 기존 마크업을 양 모드 공용으로 개조 → 기존(보존 1순위) 모드 회귀 위험

  설계_체크포인트:
    1. 2모드 토글 요구인가? → Option B(2 컨테이너 Visibility 토글) 채택
    2. 기존 레이아웃이 1순위 보존 대상인가? → 해당 마크업 byte-identical 래핑만
    3. 시간비례 가변 폭 필요 시 → DisplayWidth 미러 프로퍼티 + Recalculate에 폭 계산 추가
```

## UI 요구사항 해석 분기 규칙 (L-426)

```yaml
단일_최신_표시_요구_해석:
  트리거: 요구사항에 "단일", "최신", "마지막", "하나만", "1건" 등 포함
  경고: 이 키워드는 2가지 해석이 가능하므로 반드시 명확화 필요

  해석_A_누적유지+최신강조:
    의미: 이전 이력 유지 + 가장 최근 항목 강조 표시
    예: "마지막 요약이 눈에 잘 보이도록", "최신 항목 상단 표시"

  해석_B_이전완전숨김:
    의미: 최신 1개만 표시 + 이전 항목 숨김/제거
    예: "이전 목록 없애고 최신 1개만", "누적 말고 현재것만"

  oplan_처리_규칙:
    1. 요구사항에 단일/최신/1건 키워드 발견 시 → 해석 A/B 명시
    2. 맥락으로 판별 불가 시 → 계획서에 2가지 해석 열거 후 사용자 확인 요청
    3. 확인 없이 구현하면 역라우팅 1순위 원인 (UFBK-1 패턴)
    4. 맥락상 명확히 누적 유지(기존 목록에서 부가UI만 제거)이면 해석 A 기본 적용

  예시_올바른_처리:
    계획서_기재: "요구사항 '최신 1건만 표시'는 (A) 누적 유지+최신 강조 OR (B) 이전 완전 숨김으로 해석 가능. 맥락상 A로 판단하여 구현 진행. 다르면 알려주세요."
```

## 역라우팅 반복 대응 규칙 (L-427)

```yaml
역라우팅_반복_대응:
  규칙: 동일 증상으로 역라우팅 2회 발생 시 3번째 우회 시도 금지
  동일_증상_판정: 동일 acceptance_criteria + 동일 에러 카테고리 + 동일 사용자 지적

  2회_역라우팅_시_의무_절차:
    1. 기존 구조의 한계 명시 (왜 우회 방식이 계속 실패하는지)
    2. 사용자에게 2가지 옵션 명시 제시:
       - 옵션 A: 기존 구조 유지 + 추가 우회 시도 (위험: 또 실패 가능)
       - 옵션 B: 근본 설계 변경 (더 단순/안전한 WPF 표준 패턴 채택)
    3. 사용자 결정 후 진행

  금지: 사용자에게 옵션 제시 없이 3번째 우회 방법을 자체 결정하고 시도
  이유: 설계 한계에 부딪힌 경우 추가 우회 시도는 시간 낭비 + 사용자 마찰 증가
  관련: L-421 (동일 기능 2회 ok 미해결 시 재설계 권한 위임) — L-427은 역라우팅 단위로 적용
```

## 범위 초과 감지 및 승격

```yaml
승격_조건 (OR):
  - 아키텍처 변경 필요 (기존 구조로 불가능)
  - 새 모듈/폼 신설 필요
  - 예상 수정 줄 수 > 500줄
  - 기술 선택 트레이드오프 존재 (토론 필요)

승격_동작:
  - 계획서에 "⚠️ 범위 초과 — o4 승격 권고" 명시
  - 초과 사유 기재
  - 지금까지의 분석 결과는 o4(oplan_deep)에 상속
  - ok_pipeline에 승격 신호 반환

모델: opus
```

## Wave 기반 spawn 패턴 검토 (L-439)

```yaml
적용_조건: o3 작업이라도 신규 파일 4~9개 + 인터페이스+구현체 구조면 Wave 패턴 검토 권장
상세: oplan_deep/SKILL.md "7단계: Wave 기반 spawn 설계" 참조
Quick_모드_적용: 파일 ≤3개 작업은 Wave 분할 불필요 (병렬 spawn 충돌 가능성 낮음)
Deep_모드_적용: 파일 4개+ + 의존성 계층 명확 시 Wave 적용 검토
```

## 성능 최적화 작업 시 측정 우선 원칙 (L-360)

```yaml
적용_조건: 성능 개선/최적화 요청 시 (예: "느림", "로딩 느림", "응답 빠르게")

필수_절차:
  1. 측정_계획_수립: oplan 단계에서 Stopwatch/#if DEBUG 측정 로그 삽입 위치를 계획에 명시
  2. 실측_먼저: 구현 전 또는 구현 초기에 측정 로그로 각 단계 실행 시간 수집
  3. 병목_식별: 실측 데이터 기반 병목 구간 특정 (사용자 보고 증상 ≠ 실제 병목)
  4. 최적화_결정: 병목 구간에만 최적화 적용 (추측 최적화 금지)

금지:
  - "사용자 보고 증상 == 최적화 대상" 추측으로 최적화 방향 결정
  - 측정 없이 "차트 느림 → 차트 렌더링 최적화" 같은 직관 기반 방향 결정
  - GW WhenAll 병렬화를 측정 없이 "무조건 적용"

GW_WhenAll_적용_기준 (L-358):
  - 유효: 작은 SQL(<100ms) 그룹 → WhenAll으로 5~6배 단축 가능
  - 무효: 무거운 단일 패킷(~수초) → SemaphoreSlim(1,1) 직렬화로 WhenAll 효과 없음 (역효과 가능)
  - 판단: Stopwatch 실측 후 결정

실측_예시:
  사용자_보고: "홈 차트 로딩 느림" → 추측: 차트 렌더링 최적화
  실측_결과: LoadUserProfile 2624ms(50.5%), GetDashboardChartsAsync 2137ms(41.1%), 차트 렌더링 미미
  올바른_방향: GW 쿼리 병렬화 (차트 렌더링 최적화 ✕)

BLOB_컬럼_진단_절차 (L-NEW1/L-NEW4):
  BLOB 컬럼(Photo, Image 등) 포함 쿼리가 병목 의심 시:
    1. DB 실측: SELECT AVG(LENGTH(컬럼)), MAX(LENGTH(컬럼)) FROM 테이블 → 평균 10KB+ 이면 분리 검토
    2. Stopwatch: BLOB 포함 쿼리 vs BLOB 제외 쿼리 시간 비교 측정
    3. 분리_결정: 평균 10KB+ + 측정 차이 유의 → lazy load(fire-and-forget) 또는 별도 엔드포인트 분리
    4. 패턴: UserProfileLight enum (BLOB 제외 경량 쿼리) + GetUserPhotoAsync(BLOB 전용, fire-and-forget)
  판단_근거: BLOB는 GW QueryResponse JSON 직렬화 + TCP 전송 + Base64 디코드 누적 — SQL 튜닝으로 해결 불가

관련_교훈: L-360 (측정 우선), L-358 (GW WhenAll 직렬화 의존성), L-NEW1 (BLOB 직렬화 병목), L-NEW4 (BLOB 분리 실측 절차)

N:M_매핑_정합성_점검 (L-375):
  적용_조건: 대규모 마이그레이션(PC↔GW↔Mobile 계층 간 메서드 매핑) 계획 수립 시 필수
  절차:
    1. 원본 메서드 수 grep 확인:
       grep -c "UpdateChart\|BuildAsync\|GetChart" <대상파일> 로 정확한 수 확인
    2. 대상 계층 메서드 수 대조 — N:M 불일치 발견 시 추가 구현 범위 명시
    3. ChartBundle/DTO 필드 수 검증 — 메서드 수와 필드 수 일치 여부 확인
    4. 구현 범위에 N:M 추가분 포함하여 wave 계획 재수립

  사례 (L-375):
    PC 21 UpdateChart* vs GW 12 Build*Async → 불일치 발견 → GW +11 Build*Async 추가
    → ChartBundle 12 필드 확장 + ChartDataBuilder.cs +800~1100줄 추가

  금지:
    - N:M 매핑 정합성 없이 "PC 메서드 수 = GW 메서드 수" 전제 계획 수립
    - oplan_debate 이후 oplan-fix에서 사후 발견(비용 크고 Wave 재구성 필요)
```
