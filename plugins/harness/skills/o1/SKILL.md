---
name: o1
description: "Instant(o1) 단계 라우팅 스킬 — '/o1' 호출 시 ok에 o1 단계로 진행하도록 라우팅. 비코드 파일만 수정 또는 코드 0~2개, ≤20줄인 즉시 처리 작업에 사용. ok를 직접 호출하는 대신 단축 명령으로 사용 가능."
invocation:
  user_callable: true
  pipeline_callable: false
  called_by: [사용자]
  calls: [ok]
---
# o1 — Instant 단계 라우팅

사용자가 `/o1` 호출 시 ok에 o1(Instant) 단계로 라우팅한다.

## 절대 규칙

> **파이프라인 강제**: /o1 호출 시 내용과 무관하게 파이프라인 100% 실행 필수. 직접 답변 금지.

## 동작

```yaml
실행:
  Skill('ok') 로딩 후 아래 지시를 전달:
  "/ok o1 단계로 진행하라 — {사용자 원본 요청}"

o1_분류_조건:
  - 비코드 파일(.md/.json/.yaml/.sh/.xml 등)만 수정 가능
  - 코드 파일 0~2개, 수정 ≤20줄
  - DB 스키마 변경 없음, 인터페이스 변경 없음
  - 새 모듈/폼 신설 없음, 아키텍처 변경 없음

파이프라인:
  ok(o1) → odev(1개, sonnet) → ofinish(Step 1.5 + Step 7.5)
  - oplan 없음, otest 없음, odone 없음
  - ofinish Step 1.5: 경량 교훈 수집
  - ofinish Step 7.5: 경량 커밋

동적_승격:
  - odev 복잡도 초과 시 → o3로 승격
  - 승격 시 기존 결과물 상속 (재작업 최소화)

모델: sonnet

사용_예시:
  - /o1 SKILL.md에 규칙 추가해줘
  - /o1 CLAUDE.md 내용 수정
  - /o1 settings.json 업데이트
  - /o1 상수값 하나만 바꿔줘
  - /o1 주석 수정해줘
```
