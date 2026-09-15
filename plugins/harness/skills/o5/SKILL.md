---
name: o5
description: "Massive(o5) 단계 라우팅 스킬 — '/o5' 호출 시 ok에 o5 단계로 진행하도록 라우팅. 코드 제한없음, 1500줄+ 규모. oplan_debate(필수) + otest(전체+UI필수) + odone(Full+Gate) 포함. 아키텍처 전면 변경 필수."
invocation:
  user_callable: true
  pipeline_callable: false
  called_by: [사용자]
  calls: [ok]
---
# o5 — Massive 단계 라우팅

사용자가 `/o5` 호출 시 ok에 o5(Massive) 단계로 라우팅한다.

## 절대 규칙

> **파이프라인 강제**: /o5 호출 시 내용과 무관하게 파이프라인 100% 실행 필수. 직접 답변 금지.

## 동작

```yaml
실행:
  Skill('ok') 로딩 후 아래 지시를 전달:
  "/ok o5 단계로 진행하라 — {사용자 원본 요청}"

o5_분류_조건: # (→ ok/SKILL.md 수정_작업_분류 섹션 참조 — 단일 출처)
  - 1500줄+ OR 새 모듈 3개+ OR 아키 전면 변경
  - DB 스키마 변경 가능
  - 인터페이스 변경 가능
  - 새 모듈/폼 신설 필수포함
  - 아키텍처 변경 필수포함

파이프라인:
  ok(o5) → oplan(자율선택, opus) → odev(×N) → otest(전체+확장) → odone(Full+Gate) → ofinish
  - oplan 자율 선택 (oplan이 작업 특성 분석 후 결정):
    oplan_debate(기본값): 1500줄+, 아키 전면 변경 → 3분석가 토론 필수 (SIM_PROCEDURE(8회+) + oplan_review(opus))
    oplan_consult: 1500줄+ 이지만 알고리즘/기술 선택 중심인 경우 (이종AI 협업이 토론보다 효과적)
  - odev: 최대 에이전트, odev_impact(필수)
  - otest: Phase 0~4 전체 + UI 필수
    역라우팅: 예상-실제 비교 → 불일치 시 odev/oplan 복귀 (≤10회)
  - odone Full Path + Gate:
    review → trans → hooks → skills → cleanup → docs → git
    + 사용자 최종 승인 게이트 (Gate 판정)

동적_승격:
  - o5는 최상위 — 추가 승격 없음

모델:
  - ok 분류: opus
  - oplan_debate 토론: opus
  - oplan_final: opus
  - oplan Scout: haiku
  - odev: opus
  - otest: opus
  - odone: sonnet

사용_예시:
  - /o5 프로젝트 전체 아키텍처 재설계해줘
  - /o5 새 서비스 3개 + DB 마이그레이션 + API 전면 재작성
  - /o5 레거시 시스템 전면 현대화해줘
  - /o5 마이크로서비스 분리 구현해줘
```
