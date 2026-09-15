---
name: ok_model
description: "tier별 모델 배정 매트릭스 (단일 출처). 메인(ok)이 참조하여 팀에이전트 spawn 시 모델값을 프롬프트에 직접 주입. 팀에이전트가 Skill() 로딩하지 않음."
invocation:
  user_callable: false
  pipeline_callable: false
  called_by: ["ok(메인 참조 전용)"]
---
# ok_model — tier별 모델 배정 매트릭스

> **단일 출처**: 메인(ok)이 이 파일을 읽어 tier별 모델값을 결정한 후, 팀에이전트 spawn 프롬프트에 직접 명시.
> **팀에이전트 Skill() 로딩 금지** — 컨텍스트 오버헤드 방지.

## 모델_설정_규칙 (실증 확인됨, 2026-04-28)

```yaml
Agent_도구_model_파라미터 (실측):
  허용_값: ["sonnet", "opus", "haiku", "fable"]만 (enum 엄격)
  거절_예시: "opus[1m]", "claude-opus-4-7[1m]", "opus-1m" → InputValidationError

서브에이전트_default_동작 (실측):
  model="opus" → Opus 4.7 with 1M context (1M 자동 적용, 별도 명시 불필요)
  model="sonnet" → Sonnet 4.6 (200K context default)
  model="haiku" → Haiku 4.5 (default)
  model="fable" → Claude Fable 5.1 (claude-fable-5-1), Opus 상위 Mythos 티어, adaptive thinking 기본

서브에이전트_effortLevel (실측 — 변경 불가):
  default: "medium" 고정
  영향_없음:
    - 글로벌 settings.json effortLevel 변경
    - Agent 도구 effort/effortLevel 평면 파라미터 추가
    - 메인 세션 /model UI에서 xHigh 직접 선택
    - .claude/agents/*.md frontmatter의 effort 필드
  보강_수단: opus 에이전트의 ultrathink 지시문 (사실상 유일)

매트릭스_표기_규칙:
  - opus 표기는 사용 금지 (Agent 도구가 거절). "opus"로 통일.
  - "1M context 의도"는 별도 표기 불필요 — model="opus"만으로 자동 적용
```

## 모델_지정_매트릭스 (5-tier)

```yaml
  | 역할 | o1 | o2 | o3 | o4 | o5 |
  |------|:---:|:---:|:---:|:---:|:---:|
  | ok 1-way | 메인 | - | - | - | - |
  | oplan (tier결정+계획) | - | sonnet | fable | fable | fable |
  | oplan | - | sonnet | fable | fable | fable |
  | oplan_debate 토론 | - | - | - | fable(선택) | fable |
  | oplan_debate 비판가 | - | - | - | codex→fable | codex→fable |
  | oplan_debate 배심원 | - | - | - | sonnet×3 | sonnet×3 |
  | oplan_final | - | - | - | fable | fable |
  | oplan-3 (구현렌즈) | - | - | - | fable(선택) | fable |
  | oplan Scout | - | - | haiku/sonnet(복잡) | haiku/sonnet(복잡) | haiku/sonnet(복잡) |
  | odev | sonnet | sonnet | sonnet | opus | opus |
  | otest | - | - | sonnet | sonnet | fable |
  | odone | - | - | sonnet | sonnet | sonnet |
  | ofinish | 메인 | 메인 | 메인 | 메인 | 메인 |
```
> otest o3/o4는 판단 성격 약해 sonnet 유지(과승격 방지). o5 열만 fable.

## Ultrathink 지시 (opus/fable 전용, 조건부)

```yaml
대상: model="opus" 또는 model="fable"로 spawn되는 모든 팀에이전트
  - o3 oplan(fable), o4/o5 oplan, odev(opus), otest, oplan_debate(분석가/비판가-B/oplan-final), oplan_consult(계획가-1) 등 전체
  - sonnet/haiku에는 절대 적용 금지
  - 주의: fable은 adaptive thinking이 기본 적용되므로 ultrathink 지시문의 효과가 제한적일 수 있음

ultrathink_조건 (표준 — 모든 opus spawn 지점 공통):
  - spawn 프롬프트 < 1,000 토큰 AND 추가 파일 읽기 < 2개인 경우에만 ultrathink 사용
  - 위 조건 미충족 시: ultrathink 생략, 일반 thinking으로 수행
  - 목적: 컨텍스트 초과로 인한 서브에이전트 팅김 방지 (oplan_debate 표준 규칙 기반)

방법: 조건 충족 시 spawn 프롬프트 첫 줄에 아래 지시문 삽입
지시문: |
  [THINKING] 이 작업은 심층 분석이 필요합니다. 충분한 시간을 들여 깊이 생각하고,
  모든 가능성을 탐색한 후 최선의 결론을 도출하세요. 단계별로 논리를 전개하세요.

목적: effortLevel이 medium이어도 opus 에이전트가 extended thinking을 최대한 활용하도록 유도.
제약: 프롬프트/파일읽기 조건 미충족 시 ultrathink 생략 — 팅김 리스크 회피 우선.
```

## 역할별 모델 선택 가이드

```yaml
작업_복잡도_신호:
  haiku_적합:
    - 단일 파일, 명확한 스펙
    - 기계적 구현 (보일러플레이트, 단순 변환)
    - Scout 탐색 (파일 목록, 패턴 검색)
    - 정형화된 반복 작업

  sonnet_적합:
    - 다중 파일 조정, 통합 관심사
    - 패턴 매칭, 디버깅 작업
    - 리뷰 및 문서화
    - 기본 판단이 필요한 작업

  opus_적합:
    - 아키텍처, 설계, 복잡한 리뷰
    - 광범위한 코드베이스 이해 필요
    - 복잡한 트레이드오프 분석
    - o4/o5 핵심 계획/구현

비용_최적화_원칙:
  - 스펙이 잘 정의된 경우 → 더 저렴한 모델 우선
  - 통합/판단 작업 → sonnet
  - 아키텍처/설계 → opus
  - "의심스러우면" → 한 단계 위 모델

Ultrathink_재확인:
  - opus / opus spawn 시 조건부 Ultrathink 적용 (프롬프트 <1,000토큰 AND 추가읽기 <2개)
  - 조건 미충족 시 ultrathink 생략 (팅김 방지 우선)
  - sonnet/haiku에는 절대 적용 금지
```

## 참조 방법

메인(ok)이 tier 결정 후 spawn 프롬프트에 직접 명시:
  예: Agent(..., model="fable", ...)  ← o4/o5 oplan, oplan_debate 계획/비판/통합 (+ ultrathink 지시문 포함)
  예: Agent(..., model="opus", ...)  ← o4/o5 odev (+ ultrathink 지시문 포함)
  예: Agent(..., model="sonnet", ...) ← o2/o3 oplan, odev, odone
팀에이전트는 이 파일을 직접 로딩하지 않음.

## 하네스 재평가 정책 (Assumption Audit)

> Anthropic Engineering 원칙: "Every component in a harness encodes an assumption about what the model can't do alone. Worth stress testing whenever the model improves."

마지막_검토일: 2026-09-06 (claude-sonnet-4-6 / claude-opus-4-6 / claude-fable-5-1 기준)

재평가_트리거_조건 (아래 중 하나 해당 시 /oretro 또는 /oaudit 실행):
  - 새 Claude 모델 출시 (Opus/Sonnet/Haiku 버전 업)
  - 현재 tier 파이프라인에서 반복적 오류/비효율 패턴 감지
  - 3개월 이상 검토 미실시

재평가_항목:
  - oplan: 이 tier에서 oplan이 여전히 필요한가? (모델이 직접 판단 가능해졌는가?)
  - otest: 현재 모델이 self-evaluation 편향 없이 검증 가능해졌는가?
  - advisor: 현재 Opus가 Sonnet과 충분히 차별화된 리뷰를 제공하는가?
  - 각 hook: 모델이 스스로 준수할 수 있게 됐다면 hook 제거 검토
