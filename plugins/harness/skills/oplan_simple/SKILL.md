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

## 레퍼런스 조사 (계획 수립 전)

- Stage_0_레퍼런스_조사: 요청에 벤치마킹·레퍼런스·경쟁 솔루션 분석이 있으면 tier 와 무관하게 Phase A 진입 전에 `Skill('oplan_research')` 의 Phase_R0(REA 필요시 판정표)를 거친다. 같은 사이클에서 이미 거쳤으면 그 결과를 재사용한다.
- ref_root(`Skill('ocanon')` §1)가 있으면 plan root 유무와 무관하게 `<ref_root>/README.md` 색인을 읽고, 참조할 항목은 `ref:<id>@<커밋 12자>:<경로>` 표기로 계획서에 남긴다.

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

## QA 원복 시나리오 선행 수립 (QA 선언 프로젝트 한정)

> 사용자 원문(2026-10-10): "개발서버에서는 테스트데이터를 지우지 않아도 된다. 하지만 앞으로 qa서버에서는 데이터 원복을 위한 시나리오부터 계획하도록 하라."

- 프로젝트가 QA(운영 데이터 연계) 단계를 선언(`.claude/qa_tier.json`)했으면, 계획서는 시험 항목보다 먼저 "원복 시나리오"를 세운다.
- 항목마다 다음을 적는다. 대상 표·행 범위, 시험 전 스냅샷 방법, 시험 표식, 삭제·원복 절차, AUTO_INCREMENT·휘발 열 처리, 원복 불가 판정과 제외 사유.
- 원복 시나리오가 판정을 통과한 항목만 QA 시험 목록에 올린다. 판정표에 없는 항목은 QA 에서 시험하지 않는다.
- 예시 산출물은 세션 plans 디렉토리의 `qa_reversibility_draft.json` 이다.
- 선언이 없으면 이 절은 적용하지 않는다.

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

  ## 정본 참조
  - 색인: `plan/index.json`
  - 관련: {정본 문서 경로 | 없음(사유)}
  - 반영 예정: {문서 | 해당 없음(사유)}
  # o2 는 1~2줄(게이트 경고만). plan root 가 없으면 "plan root 없음" 1줄. 절차·규격은 Skill('oplan') "정본 참조" 절과 Skill('ocanon') 참조.

  ## TODO
  - [ ] {파일}: {수정 내용} (~{N}줄)
  - [ ] {파일}: {수정 내용} (~{N}줄)

  ## 예상 규모
  - 파일 수: {N}개
  - 수정 줄 수: ~{N}줄
```

### file_assignment.json 생성 (필수 — 계획서 외 별도 산출물)

```yaml
경로: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/file_assignment.json
시점: TODO 확정 직후 (odev spawn 전)
스키마: {"tier":"O2","agents":{"odev-1":{"persona":"{페르소나}","files":["{절대경로}"],"tasks":["{작업}"]}}}
근거: 검수 게이트 F-CRUD-1(verify_crud_executed.py)이 변경 파일 교차검증 입력으로 읽는다.
      부재 시 게이트가 git 폴백 또는 fail-closed로 떨어진다 (2026-10-06 사례).
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
