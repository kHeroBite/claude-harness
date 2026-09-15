---
name: o3
description: "Normal(o3) 단계 라우팅 스킬 — '/o3' 호출 시 ok에 o3 단계로 진행하도록 라우팅. 코드 4개+ OR 50~500줄인 일반 작업에 사용. oplan_normal + otest + odone(Fast) 포함."
invocation:
  user_callable: true
  pipeline_callable: false
  called_by: [사용자]
  calls: [ok]
---
# o3 — Normal 단계 라우팅

사용자가 `/o3` 호출 시 ok에 o3(Normal) 단계로 라우팅한다.

## 절대 규칙

> **파이프라인 강제**: /o3 호출 시 내용과 무관하게 파이프라인 100% 실행 필수. 직접 답변 금지.

## 동작

```yaml
실행:
  Skill('ok') 로딩 후 아래 지시를 전달:
  "/ok o3 단계로 진행하라 — {사용자 원본 요청}"

o3_분류_조건: # (→ ok/SKILL.md 수정_작업_분류 섹션 참조 — 단일 출처)
  - 코드 파일 4개+ OR 수정 50~500줄 OR DB/인터페이스/비즈니스로직 변경
  - DB 스키마 변경 선택적 허용
  - 인터페이스 변경 선택적 허용
  - 새 모듈/폼 신설 없음, 아키텍처 변경 없음

파이프라인:
  ok(o3) → oplan_normal(opus) → odev(×N, Wave) → otest(Phase 0~4) → odone(Fast) → ofinish
  - oplan_normal: Phase A~J 전체, Quick/Deep 자율 결정
    Quick: 파일 3개 이하, 패턴 반복, 영향도 제한적
    Deep: 파일 4개+, 새 패턴, 인터페이스 변경 → oplan_deep(+references/SIM_PROCEDURE.md) + oplan_review
  - otest: Phase 0(예상)→1(빌드)→2(테스트)→3(품질)→4(비교)
    역라우팅: 예상-실제 비교 → 불일치 시 odev/oplan 복귀 (≤10회)
  - odone Fast Path: review → docs → git

동적_승격:
  - oplan_normal 아키텍처 변경 필요 시 → o4 승격
  - 승격 시 기존 계획서/결과물 상속

모델: oplan=opus, odev/otest/odone=sonnet

사용_예시:
  - /o3 신규 API 엔드포인트 추가해줘
  - /o3 데이터 모델에 필드 추가하고 관련 로직 수정해줘
  - /o3 폼 전체 레이아웃 변경해줘
  - /o3 DB 테이블에 컬럼 추가하고 CRUD 수정해줘
```
