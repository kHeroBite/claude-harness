---
name: o4
description: "Heavy(o4) 단계 라우팅 스킬 — '/o4' 호출 시 ok에 o4 단계로 진행하도록 라우팅. 500줄+ OR 아키텍처 변경 규모. oplan_deep + otest(전체) + odone(Full) 포함. 아키텍처 변경 가능."
invocation:
  user_callable: true
  pipeline_callable: false
  called_by: [사용자]
  calls: [ok]
---
# o4 — Heavy 단계 라우팅

사용자가 `/o4` 호출 시 ok에 o4(Heavy) 단계로 라우팅한다.

## 절대 규칙

> **파이프라인 강제**: /o4 호출 시 내용과 무관하게 파이프라인 100% 실행 필수. 직접 답변 금지.

## 동작

```yaml
실행:
  Skill('ok') 로딩 후 아래 지시를 전달:
  "/ok o4 단계로 진행하라 — {사용자 원본 요청}"

o4_분류_조건: # (→ ok/SKILL.md 수정_작업_분류 섹션 참조 — 단일 출처)
  - 500줄+ OR 아키텍처 변경
  - DB 스키마 변경 가능
  - 인터페이스 변경 가능
  - 새 모듈/폼 신설 가능
  - 아키텍처 변경 가능

파이프라인:
  ok(o4) → oplan(자율선택, opus) → odev(×N) → otest(전체) → odone(Full) → ofinish
  - oplan 자율 선택 (oplan이 작업 특성 분석 후 결정):
    oplan_consult: 복잡한 알고리즘/기술 선택 트레이드오프, 다양한 외부 시각 필요
    oplan_debate: 아키텍처 전면 변경 OR 500줄+, 새 모듈 3개+ OR 이해관계자 충돌 가능성
    oplan_deep: 위 조건 미해당 시 기본값 (Scout ×1~3 + 대안 + YAGNI + SIM_PROCEDURE(5회) + oplan_review)
  - otest: Phase 0~4 전체 + UI(조건부)
    역라우팅: 예상-실제 비교 → 불일치 시 odev/oplan 복귀 (≤10회)
  - odone Full Path: review → trans → hooks → skills → cleanup → docs → git

동적_승격:
  - oplan_deep 1500줄+ 감지 시 → o5 승격
  - 승격 시 기존 계획서/결과물 상속

모델:
  - ok 분류: opus
  - oplan: opus
  - oplan_debate 토론: opus (선택적)
  - odev: opus
  - otest: sonnet
  - odone: sonnet

사용_예시:
  - /o4 새 모듈 하나 신설해줘
  - /o4 기존 서비스 레이어 전면 리팩토링해줘
  - /o4 인증 시스템 교체해줘
  - /o4 대규모 DB 스키마 마이그레이션 해줘
```
