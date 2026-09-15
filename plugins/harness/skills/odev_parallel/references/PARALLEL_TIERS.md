# odev_parallel — 병렬화 상세 참조

## 목차
- [병렬화 분리 기준 (3-Tier 계층적)](#병렬화-분리-기준-3-tier-계층적)
- [에이전트별 컨텍스트 프리로딩](#에이전트별-컨텍스트-프리로딩)
- [에이전트 수 정책 + Load Balancing](#에이전트-수-정책--load-balancing)
- [Common Mistakes](#common-mistakes)

## 병렬화 분리 기준 (3-Tier 계층적)

> **규모별 프로필 선택**: o2 = impl-form/impl-backend, o3/o4/o5 = 3-Tier 전문가 프로필 (agent_profiles 참조)

```yaml
규모별_분리_정책:
  o2:
    프로필: impl-form, impl-backend, impl-mobile (기존)
    분리: 레이어 2~3개 수준 (DB/Backend/Frontend)
  o3:
    프로필: 3-Tier 전문가 (data-*, be-*, fe-*)
    분리: 레이어 내 세분화 (예: be-csharp + be-gateway 분리)
  o4/o5:
    프로필: 3-Tier 전문가 + 최대 병렬
    분리: 전문가당 1 에이전트 원칙

판정_순서 (3-Tier Phase 순서):
  Phase_0: 공통모듈(Shared) 변경 포함?
    → be-interface 에이전트 선행 완료 후 나머지 병렬
    → 인터페이스/DTO/유틸 변경이 여기에 해당
  Phase_1: Data Layer (Phase 0 완료 후)
    → data-query (SQL 정의) + data-model (DTO 매핑) 병렬 실행
    → SQL/DTO 완료 후 Backend/Frontend가 참조 가능
  Phase_2: Backend + Frontend 병렬 (Phase 1 완료 후)
    → Backend: be-csharp, be-gateway, be-query (동시)
    → Frontend: fe-designer, fe-chart, fe-control, fe-mobile (동시)
    → Backend/Frontend 간 병렬 실행

Phase_스킵_규칙:
  - 해당 Phase에 수정할 파일이 없으면 스킵
  - Phase 0 불필요 시: Phase 1부터 시작
  - Phase 1 불필요 시: Phase 2 직접 시작
  - 모든 Phase 독립 시: 전체 병렬 (Phase 구분 없음)

레이어_분리 (3-Tier 세분화):
  Data: SQL 정의(Queries/*.cs), DTO/Entity(Models/*.cs)
  Backend: 비즈니스 로직, Gateway/API, 인터페이스/공통, Queries 호출부
  Frontend: WinForms Designer, LiveCharts2, 커스텀 컨트롤, Mobile

폼별_분리:
  원칙: 각 폼(.cs + .Designer.cs + .resx)은 독립 단위
  조건: 폼 간 직접 의존성 없음 (공통모듈 경유만)
  예시: "폼 3개 수정" → fe-designer 에이전트 3개 (디자이너 파일당 1개)

인터페이스_변경_판정:
  기존_인터페이스_내_변경: 완전 병렬 가능
  인터페이스/시그니처_변경: be-interface 선행 (Phase 0) → 나머지 병렬
  공통모듈_변경: Phase 0 선행 필수

Fail_Fast_순서:
  병렬이더라도 리스크 높은 레이어 먼저 시작:
  Shared(be-interface) > Data(data-query/model) > Backend(be-*) > Frontend(fe-*)

레이어_간_협업:
  방식: 기존 SendMessage 유지 (새 프로토콜 불필요)
  Phase_완료_통보: 각 Phase 완료 시 리더에게 SendMessage → 다음 Phase spawn
  크로스_레이어: data-query 결과를 be-query가 참조 → Phase 순서로 자연 해결
```

## 에이전트별 컨텍스트 프리로딩

```yaml
레이어별_자동_로딩:
  # o2 (기존 프로필)
  impl-form: ADVANCED.md + orules의 UI 규칙
  impl-backend: DATABASE.md + RESTAPI.md + orules의 Gateway/권한 규칙
  impl-mobile: orules의 모바일 규칙

  # 3-Tier Data Layer
  data-query: DATABASE.md + orules의 SQL 규칙
  data-model: DATABASE.md + PROJECT.md의 Models 섹션

  # 3-Tier Backend Layer
  be-csharp: ADVANCED.md + orules
  be-gateway: RESTAPI.md + orules의 Gateway 규칙
  be-interface: PROJECT.md의 Shared 섹션 + odev_impact
  be-query: DATABASE.md + orules의 SQL 규칙

  # 3-Tier Frontend Layer
  fe-designer: ADVANCED.md + domain-winforms + orules의 UI 규칙
  fe-chart: oskill_livecharts2
  fe-control: orules의 UI 규칙
  fe-mobile: orules의 모바일 규칙

프롬프트에_포함:
  - 해당 레이어 문서만 (전체 문서 금지 → context 효율)
  - 수정 허용 파일 목록
  - 읽기전용 참조 파일 목록
```

## 에이전트 수 정책 + Load Balancing

```yaml
에이전트_수_정책:
  단일_출처: Skill('oplan_parallel') — 에이전트 수 공식/파일 할당/Load Balancing의 유일 출처
  공식_요약: 파일 1~4개=1:1, 파일 5개+=max(4,ceil(파일수/3))
  상세: oplan_parallel SKILL.md 참조
```

## Common Mistakes

```yaml
❌ 너무_광범위: "모든 테스트 고쳐" → 에이전트 길 잃음
✅ 구체적: "agent-tool-abort.test.ts 고쳐"

❌ 컨텍스트_없음: "레이스 컨디션 고쳐"
✅ 컨텍스트: 에러 메시지와 테스트 이름 붙여넣기

❌ 제약사항_없음: 에이전트가 전부 리팩토링할 수 있음
✅ 제약사항: "프로덕션 코드 변경 금지"

❌ 모호한_출력: "고쳐"
✅ 구체적: "근본 원인과 변경사항 요약 반환"

❌ 파일_범위_미지정: 에이전트가 아무 파일이나 수정
✅ 파일_범위_명시: "수정 허용: [file1.cs], 읽기전용: [common.cs]"

❌ 레이어_문서_미포함: 에이전트가 규칙 모르고 구현
✅ 레이어_문서_포함: "DB 에이전트에 DATABASE.md + SQL 규칙 포함"
```
