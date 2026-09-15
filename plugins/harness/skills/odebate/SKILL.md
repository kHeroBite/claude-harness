---
name: odebate
description: "oplan_debate 래퍼 — '/odebate' 호출 시 oplan_debate을 실행. 3분석가(아키텍처/리스크/구현) × 비판가 1인 토론 + 배심원 만장일치 기반 계획 수립."
invocation:
  user_callable: true
  pipeline_callable: false
  called_by: [사용자]
  calls: [oplan_debate]
---
# odebate — oplan_debate 래퍼

사용자가 `/odebate` 호출 시 oplan_debate을 실행한다.

## 호출 분기

```yaml
사용자_직접_호출 (/odebate 슬래시 명령):
  판단_기준: system-reminder에 `💬 [IDLE 직접처리]` 또는 `⚡ [슬래시 명령] oi 바이패스 — /odebate` 컨텍스트
  동작: 팀에이전트 spawn (아래 절차)

내부_호출 (다른 스킬에서 Skill('odebate') 호출):
  동작: 해당 없음 — pipeline_callable=false이므로 내부 호출 없음
  비고: 이 분기 명시는 방어적 문서화 목적
```

## 동작

**항상 팀에이전트로 spawn하여 실행한다.** 뒤에 어떤 파라미터(분석/비교/설계 요청 등)가 있더라도 예외 없이 팀에이전트를 spawn한다.

## ⚠️ state 규칙 — PLAN state 미진입 (L-422)

```yaml
state_원칙:
  - /odebate는 인스턴스 플랜(정식 파이프라인 밖) — state=PLAN 설정 절대 금지
  - 실행 전/중/후 IDLE 상태 유지
  - 완료 후 ofinish(경량)가 TeamDelete + IDLE 복원 처리
  이유: PLAN state 잔류 시 후속 /ok, /o4 등이 oi_route_guard에 차단됨
```

## entry_tier 기록 (사용자 규칙3 — 인스턴스 플랜 그룹)

```yaml
entry_tier_기록:
  시점: /odebate 진입 직후, TeamCreate 전
  명령: mcp__oio__session_state(uuid="${UUID}", key="entry_tier", value="OK")
  주의: state 전이 절대 금지 (L-422 — IDLE 유지). entry_tier 기록만, state/classification 변경 없음.
  폴백: UUID 불명확 시 system-reminder의 🆔 [UUID] 값 사용
```

절차:
1. TeamCreate (무조건 — 새 세션이므로 항상 신규 팀 생성)
2. oplan-debate 팀에이전트 spawn:
   Agent(subagent_type="general-purpose", team_name="{팀명}", name="oplan-debate-1", mode="bypassPermissions",
     prompt="Skill('oplan_debate') 로딩. 사용자 요구사항: {원문}. PIPELINE_UUID={UUID}")
3. 완료 수신 → ofinish (경량 — Step 7.5 커밋 없음, TeamDelete + IDLE)

oplan_debate 내용:
  - 이종 3분석가(opus×2 아키텍처/리스크 + codex:rescue×1 구현) 독립 분석
  - 이종 2비판가 동시(codex:adversarial-review → critique_A.md + opus → critique_B.md)
  - → 3인 교차 debate → 3인 vote → sonnet 배심원 3명 만장일치
  - → oplan-final(opus) → Codex 적대적 검증(조건부 SKIP)

사용_예시:
  - /odebate 인증 모듈 설계해줘
  - /odebate 아키텍처 리팩토링 계획 세워줘
  - /odebate 이 방식과 저 방식을 비교분석해줘  ← 비교 요청도 팀에이전트 spawn
