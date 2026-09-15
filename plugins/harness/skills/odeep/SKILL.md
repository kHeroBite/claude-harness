---
name: odeep
description: "oplan_deep 직접 호출 래퍼 — '/odeep' 호출 시 ok 없이 oplan_deep만 실행. 심층 설계가 필요한 단계에서 계획 수립만 수행."
invocation:
  user_callable: true
  pipeline_callable: false
  called_by: [사용자]
  calls: [oplan_deep]
---
# odeep — oplan_deep 직접 래퍼

사용자가 `/odeep` 호출 시 ok 파이프라인 없이 `oplan_deep`을 직접 실행한다.
계획 수립(설계)만 수행하며, 이후 파이프라인(odev/otest/odone)은 별도로 진행해야 한다.

## 설계 근거

ok 파이프라인 없이 계획만 빠르게 심층 설계하고 싶을 때 사용.
oplan_deep은 Scout, 대안 탐색, Incremental Validation, YAGNI 검증을 포함한 심층 설계 스킬이다.

## 호출 분기

```yaml
사용자_직접_호출 (/odeep 슬래시 명령):
  판단_기준: system-reminder에 `💬 [IDLE 직접처리]` 또는 `⚡ [슬래시 명령] oi 바이패스 — /odeep` 컨텍스트
  동작: 팀에이전트 spawn (아래 직접_호출_절차)

내부_호출 (다른 스킬에서 Skill('odeep') 호출):
  동작: Skill('oplan_deep') 직접 실행 (기존 동작 유지 — 변경 없음)
  비고: 다른 스킬이 본 스킬을 내부 호출할 경우 spawn 강제하지 않음 (이중 spawn 방지)
```

## ⚠️ state 규칙 — IDLE 유지 (L-422)

```yaml
state_원칙:
  - /odeep는 인스턴스 플랜(정식 파이프라인 밖) — state=PLAN 설정 절대 금지
  - 실행 전/중/후 IDLE 상태 유지
  - 직접 호출 시: 완료 후 ofinish(경량 — TeamDelete + IDLE 복원)
  이유: PLAN state 잔류 시 후속 /ok, /o4 등이 oi_route_guard에 차단됨
```

## entry_tier 기록 (인스턴스 플랜 그룹)

```yaml
entry_tier_기록:
  시점: /odeep 진입 직후, 직접_호출 시 TeamCreate 전 또는 내부_호출 시 Skill 호출 전
  명령: mcp__oio__session_state(uuid="${UUID}", key="entry_tier", value="OK")
  주의: state 전이 절대 금지 (IDLE 유지). entry_tier 기록만, state/classification 변경 없음.
  폴백: UUID 불명확 시 system-reminder의 🆔 [UUID] 값 사용
```

## 직접_호출_절차 (사용자 슬래시 호출 시)

1. entry_tier=OK 기록 (IDLE 유지 — state 전이 없음)
2. TeamCreate (무조건 — 새 세션이므로 항상 신규 팀 생성)
3. Agent 팀에이전트 spawn:
   ```
   Agent(subagent_type="general-purpose", team_name="{팀명}", name="odeep-worker",
         mode="bypassPermissions",
         prompt="Skill('oplan_deep') 호출. 사용자 요구사항: {원문}. PIPELINE_UUID={UUID}")
   ```
4. 완료 수신 → ofinish (경량 — Step 7.5 커밋 없음, TeamDelete + IDLE)

## 내부_호출_절차 (다른 스킬에서 Skill('odeep') 호출 시)

기존 동작 유지: Skill('oplan_deep') 직접 호출.

## oplan_deep 호출 프롬프트

```
Skill('oplan_deep') 호출.
사용자 요구사항: {원문}.
Skill('oinfra_{project}') 호출.
```

## 주의

- ok 파이프라인 미적용 — odev/otest/odone은 별도 호출 필요
- 순수 계획 수립 용도로만 사용
- 심층 설계 full 프로세스 (Scout + 대안 탐색 + YAGNI 검증 포함)

## 사용 예시

- /odeep 새 결제 모듈 아키텍처 설계해줘
- /odeep 인증 시스템 전면 개편 계획 수립해줘
