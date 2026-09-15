---
name: o2
description: "Simple(o2) 단계 라우팅 스킬 — '/o2' 호출 시 ok에 o2 단계로 진행하도록 라우팅. 코드 1~3개 AND 수정 20~50줄인 단순 작업에 사용. ok를 직접 호출하는 대신 단축 명령으로 사용 가능."
invocation:
  user_callable: true
  pipeline_callable: false
  called_by: [사용자]
  calls: [ok]
---
# o2 — Simple 단계 라우팅

사용자가 `/o2` 호출 시 ok에 o2(Simple) 단계로 라우팅한다.

## 절대 규칙

> **파이프라인 강제**: /o2 호출 시 내용과 무관하게 파이프라인 100% 실행 필수. 직접 답변 금지.

## 동작

```yaml
실행:
  Skill('ok') 로딩 후 아래 지시를 전달:
  "/ok o2 단계로 진행하라 — {사용자 원본 요청}"

o2_분류_조건: # (→ ok/SKILL.md 수정_작업_분류 섹션 참조 — 단일 출처)
  - 코드 파일 1~3개 AND 수정 20~50줄
  - 비코드 단독 수정도 가능
  - DB 스키마 변경 없음, 인터페이스 변경 없음
  - 새 모듈/폼 신설 없음, 아키텍처 변경 없음

파이프라인:
  /o2 직접 호출: oplan_simple → odev(1~3개) → obr(빌드+실행) → ofinish(Step 1.5 + Step 7.5)
  /ok 경유 o2 판정: oplan_simple → odev → obr → ofinish
  - oplan_simple 항상 실행 (/o2 직접/ok 경유 무관)
  - otest 대신 obr (빌드+실행만)
  - odone 없음 — ofinish Step 1.5 경량교훈이 대체

동적_승격:
  - oplan_simple 범위 초과(50줄+ 또는 파일 4개+) → o3 승격
  - obr 2회 실패 → o3 승격
  - odev 복잡도 초과 → o3 승격
  - 승격 시 기존 계획서/결과물 상속

모델: sonnet

사용_예시:
  - /o2 버튼 이벤트 핸들러 수정해줘
  - /o2 폼에 라벨 하나 추가해줘
  - /o2 상수값 변경해줘
  - /o2 유틸리티 함수 하나 추가해줘
```
