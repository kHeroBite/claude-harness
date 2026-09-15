---
name: oplan_parallel
description: "병렬 에이전트 수/할당/Phase 결정 — oplan Phase_I와 ok o1 작업이 공동 참조하는 단일 출처. 에이전트 수 공식, 파일 할당, 그룹화, Phase 순서, 페르소나 결정."
invocation:
  user_callable: false
  pipeline_callable: true
  called_by: ["oplan Phase_I", "ok(o1)"]
  calls: []
---

# oplan_parallel — 병렬 에이전트 수/할당/Phase 결정

> **단일 출처**: 에이전트 수 결정 공식 및 파일 할당 규칙의 유일한 출처.
> oplan Phase_I (o2~o5)와 ok o1 작업 모두 이 스킬을 참조.

## 호출 맥락

```yaml
oplan_에서_호출 (o2~o5):
  시점: Phase_I — 에이전트 수 결정 단계
  입력: 수정 파일 목록, 의존성 분석 결과
  출력: phases 배열 (에이전트별 파일/작업/페르소나/순서)

ok_o1_에서_호출:
  시점: odev spawn 직전 (oplan 없음)
  입력: 사용자 메시지의 수정 파일 목록
  출력: 에이전트 수 + 파일 할당 (Phase 없음 — 비코드 파일은 의존성 없음)
```

## 에이전트 수 결정 공식 (단일 출처)

```yaml
공식:
  파일_1~4개: 파일 수 = 에이전트 수 (1:1 매핑 — 충돌 가능성 0)
  파일_5개+:  max(4, ceil(파일수/3)) 개 spawn

예시:
  파일 1개  → 1개
  파일 2개  → 2개
  파일 3개  → 3개
  파일 4개  → 4개
  파일 5개  → max(4, ceil(5/3))  = max(4,2) = 4개
  파일 6개  → max(4, ceil(6/3))  = max(4,2) = 4개
  파일 9개  → max(4, ceil(9/3))  = max(4,3) = 4개
  파일 12개 → max(4, ceil(12/3)) = max(4,4) = 4개
  파일 13개 → max(4, ceil(13/3)) = max(4,5) = 5개

하한_이유: 최소 4개 동시 spawn으로 병렬 처리 속도 확보
상한_이유: 에이전트당 최대 3파일 제약 준수 (충돌 방지)
제약: 파일 할당 매트릭스 준수 (수정 파일 중복 = 0)
```

## 파일 할당 원칙

```yaml
원칙:
  - 1 파일 = 1 에이전트 (중복 금지)
  - 의존 관계 있는 파일 → 동일 에이전트로 그룹화
  - 작업량 균형 (Load Balancing ±30%)

의존성_판단:
  - A 파일이 B 파일의 인터페이스를 구현하면 → 같은 에이전트
  - A 파일이 B 파일의 결과를 참조해야 수정 가능하면 → 순차 Phase

파일_소유권_영속화:
  경로: $HOME/.claude/session-env/${UUID}/file_assignment.json
  시점: 매트릭스 확정 직후, odev spawn 직전
  생명주기: ofinish Step 6에서 삭제
```

## 그룹화 원칙

```yaml
같은_에이전트로_묶기:
  - 동일 폼 (.cs + .Designer.cs + .resx)
  - 인터페이스와 구현체
  - 의존성 있는 파일 쌍

다른_에이전트로_분리:
  - 독립 도메인 (UI/Backend/DB)
  - 파일 간 직접 의존성 없음

페르소나_매핑 (레이어 기반):
  Data Layer:    data-query (SQL), data-model (DTO)
  Backend:       be-csharp (비즈니스), be-gateway (API), be-interface (공통모듈)
  Frontend:      fe-designer (WinForms), fe-chart (LiveCharts2), fe-mobile (Mobile)
  문서/설정:     없음 (o1 전용)
```

## Phase 구조 결정

```yaml
Phase_필요_조건: 파일 간 선행 완료 의존성 존재
Phase_불필요: 모든 파일이 독립적 → 전체 병렬 (Phase 없음)

Phase_판정_순서:
  Phase_0 (선택): 공통모듈/인터페이스 변경 포함 시 선행
    → be-interface 에이전트 단독 실행 → 완료 후 다음 Phase
  Phase_1 (선택): Data Layer
    → data-query + data-model 병렬 → 완료 후 다음 Phase
  Phase_2: Backend + Frontend 병렬
    → be-csharp, be-gateway, fe-designer 등 동시

Phase_스킵_규칙:
  - 해당 Phase 수정 파일 없으면 스킵
  - 모든 파일 독립 시 Phase 구분 없이 전체 병렬

o1_작업_Phase: 없음 (비코드 파일은 의존성 없으므로 전체 병렬)
```

## 장기 개선: DAG resolver 자동화 (Argo Workflows 패턴)

> **현재**: oplan이 수동으로 파일 의존성 분석 → Wave 계산
> **개선**: TODO XML의 dependencies 태그를 파싱하여 자동 DAG 생성 → Wave 자동 계산

```yaml
설계_개념:
  입력: file_assignment.json + TODO XML의 <dependencies> 태그
  처리:
    1. 파일 간 의존성 그래프 구축 (인터페이스→구현, 공통→개별)
    2. 위상 정렬(topological sort)로 Wave 자동 계산
    3. 순환 의존성 감지 시 경고 + 수동 분리 요청
  출력: waves.json — Wave별 에이전트 목록 + 의존성 정보

  자동_Wave_트리거:
    현재: 메인이 Wave 1 완료 확인 → 수동으로 Wave 2 spawn
    개선: Wave 1 에이전트 반환 즉시 → 자동으로 READY 집합 계산 → Wave 2 spawn

  Argo_참조:
    - tasks[].dependencies 필드 → 의존성 선언
    - DAG executor가 의존성 충족된 task 자동 실행
    - 현재 ok의 Wave 개념과 1:1 대응

  우선순위: P2 (현재 수동 Wave 계산으로 충분, 에이전트 5개+ 시 자동화 가치 증가)
```

## Load Balancing

```yaml
목표: 에이전트 간 예상 소요 시간 차이 ±30% 이내
이유: 전체 소요 시간 = 가장 늦게 끝나는 에이전트

방법:
  1. 파일별 작업 복잡도 추정 (단순/보통/복잡)
  2. 에이전트별 합산 시간 비교
  3. 특정 에이전트가 2배+ 오래 걸리면:
     - 고비용 작업을 별도 에이전트로 분리
     - 또는 저비용 작업을 다른 에이전트로 이동

예시:
  Before: 에이전트A(8파일,8분) + 에이전트B(2파일,20분) → 전체 20분
  After:  에이전트A(8파일,8분) + B1(1파일,10분) + B2(1파일,10분) → 전체 10분
```

## 반환 형식

oplan이 메인에게 반환하는 phases 배열:

```yaml
반환_구조:
  규모_판정: o1 | o2 | o3 | o4 | o5
  총_에이전트_수: N
  phases:
    - phase: 0
      parallel: false          # 단독 실행
      agents:
        - name: "odev-1"
          persona: be-interface
          files: [Shared/IFoo.cs]
          tasks: ["인터페이스 메서드 추가"]
    - phase: 1
      parallel: true           # 동시 spawn 필수 (1개 메시지 내 다중 Agent() 호출 — 순차 개별 spawn 금지)
      agents:
        - name: "odev-2"
          persona: data-query
          files: [Queries/FooQuery.cs]
          tasks: ["SQL 추가"]
        - name: "odev-3"
          persona: fe-designer
          files: [Forms/FooForm.Designer.cs]
          tasks: ["UI 컨트롤 추가"]

o1_반환_구조 (Phase 없음):
  총_에이전트_수: N
  agents:
    - name: "odev-1"
      files: [README.md]
      tasks: ["섹션 추가"]
```
