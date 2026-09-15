---
name: oplan_simple
description: "o2 전용 축소 계획 수립 스킬 — Phase A(의도분석) + B(코드탐색) + G(TODO)만 수행. 산출물 30~50줄. Scout/Simulation/Review 없음. 범위 초과 시 o3 승격 보고."
invocation:
  user_callable: false
  pipeline_callable: true
  called_by: ["oplan(o2)"]
  calls: []
---
# oplan_simple — o2 전용 축소 계획 수립

> **ℹ️ Step 명명**: 이 파일은 oplan 프레임워크의 Phase A~J 대신 독자적인 Step 1~3을 사용합니다. oplan 프레임워크 Phase와 혼동하지 마세요.

o2(Simple) 파이프라인 전용 계획 수립. 독자적 실행 Phase A, B, G를 실행하여 경량 계획서를 생성한다.

## ogrill 5축 결손 판정 (oplan 내부 절차 — 절대 규칙)

> oplan_simple 팀에이전트는 Phase A(의도 분석) 진입 직전 5축(목표/범위/제약/완료기준/열린질문) 결손 카운트를 수행한다.
> 메인 에이전트는 이 판정을 수행하지 않는다 (CLAUDE.md "ogrill 호출 정책" 참조).
> 상세 절차: oplan/SKILL.md "ogrill 5축 결손 판정" 섹션 참조 (단일 출처).

## 실행 주체

```yaml
실행: 메인이 팀에이전트로 spawn (메인 직접 실행 금지)
모델: sonnet
이유: 메인 컨텍스트 보호 + 파이프라인 일관성 (모든 메인스킬은 팀에이전트 경유)
팀에이전트_추가_spawn_금지: 이 스킬 내에서 추가 팀에이전트 spawn 필요 시 메인에게 SPAWN_REQUEST 위임
```

## 트리거 조건

```yaml
수동_트리거: 사용자가 '/oplan_simple' 직접 호출 (드문 경우)
자동_트리거: oplan이 o2 판정 후 호출 시
```

## entry_tier 기록 (사용자 규칙3 — 수동 트리거 시)

```yaml
entry_tier_기록:
  적용: 수동_트리거(/oplan_simple 직접 호출) 시에만
  시점: 수동 호출 진입 직후
  명령: mcp__oio__session_state(uuid="${UUID}", key="entry_tier", value="OK")
  주의: 자동_트리거(oplan 경유) 시는 ok/SKILL.md가 이미 entry_tier=OK 기록 → 추가 기록 불필요
  상태: state 전이와 독립 (인스턴스 플랜 그룹과 동일 패턴)
```

## 실행 절차

```yaml
Step_1_의도분석:
  - 사용자 요청에서 핵심 의도 추출
  - 수정 대상 파일/함수 예측
  - 예상 수정 범위 산정 (줄 수, 파일 수)

Step_2_코드탐색:
  - 수정 대상 파일 읽기 (최대 3개)
  - 관련 심볼/의존성 파악
  - 기존 패턴 확인 (동일 파일 내 유사 코드)

Step_3_TODO:
  - 구현 TODO 리스트 작성 (체크박스 형식)
  - 파일별 수정 내용 명시
  - 예상 수정 줄 수 기재

수행_않음:
  - Step 4~6 (Scout, 대안 탐색, 시뮬레이션, 리뷰 등)
  - Step 7~9 (에이전트 할당, 병렬화 판정 등)
  - oplan_deep(+references/SIM_PROCEDURE.md), oplan_review
```

## 산출물

```yaml
형식: 마크다운 계획서
분량: 30~50줄
구조:
  ## 의도 분석
  - 핵심 요구사항: {1줄}
  - 수정 대상: {파일 목록}

  ## 코드 탐색 결과
  - {파일}: {현재 상태 요약}

  ## TODO
  - [ ] {파일}: {수정 내용} (~{N}줄)
  - [ ] {파일}: {수정 내용} (~{N}줄)

  ## 예상 규모
  - 파일 수: {N}개
  - 수정 줄 수: ~{N}줄
```

## 범위 초과 감지 및 승격

```yaml
승격_조건 (OR):
  - 예상 수정 줄 수 > 50줄
  - 수정 대상 파일 수 > 3개 (코드 파일 기준)
  - DB 스키마 변경 필요
  - 인터페이스 변경 필요
  - 새 패턴 도입 필요

승격_동작:
  - 계획서에 "⚠️ 범위 초과 — o3 승격 권고" 명시
  - 초과 사유 기재
  - 지금까지의 분석 결과는 o3(oplan_normal)에 상속
  - ok_pipeline에 승격 신호 반환

모델: sonnet
```
