---
name: oconsult
description: "oplan_consult 래퍼 — '/oconsult' 호출 시 oplan_consult을 실행. Claude × Codex 이종 AI 협업 계획 수립 (순차/병렬 모드, 비판가 검토 포함)."
invocation:
  user_callable: true
  pipeline_callable: false
  called_by: [사용자]
  calls: [oplan_consult]
---
# oconsult — oplan_consult 래퍼

사용자가 `/oconsult` 호출 시 oplan_consult을 실행한다.

## 호출 분기

```yaml
사용자_직접_호출 (/oconsult 슬래시 명령):
  판단_기준: system-reminder에 `💬 [IDLE 직접처리]` 또는 `⚡ [슬래시 명령] oi 바이패스 — /oconsult` 컨텍스트
  동작: 팀에이전트 spawn (아래 절차)

내부_호출 (다른 스킬에서 Skill('oconsult') 호출):
  동작: 해당 없음 — pipeline_callable=false이므로 내부 호출 없음
  비고: 이 분기 명시는 방어적 문서화 목적
```

## 동작

**항상 팀에이전트로 spawn하여 실행한다.** 뒤에 어떤 파라미터(자문/설계/비교 요청 등)가 있더라도 예외 없이 팀에이전트를 spawn한다.

## ⚠️ state 규칙 — PLAN state 미진입 (L-422)

```yaml
state_원칙:
  - /oconsult는 인스턴스 플랜(정식 파이프라인 밖) — state=PLAN 설정 절대 금지
  - 실행 전/중/후 IDLE 상태 유지
  - 완료 후 ofinish(경량)가 TeamDelete + IDLE 복원 처리
  이유: PLAN state 잔류 시 후속 /ok, /o4 등이 oi_route_guard에 차단됨
```

## entry_tier 기록 (사용자 규칙3 — 인스턴스 플랜 그룹)

```yaml
entry_tier_기록:
  시점: /oconsult 진입 직후, TeamCreate 전
  명령: mcp__oio__session_state(uuid="${UUID}", key="entry_tier", value="OK")
  주의: state 전이 절대 금지 (L-422 — IDLE 유지). entry_tier 기록만, state/classification 변경 없음.
  폴백: UUID 불명확 시 system-reminder의 🆔 [UUID] 값 사용
```

절차:
1. TeamCreate (무조건 — 새 세션이므로 항상 신규 팀 생성)
2. oplan-consult 팀에이전트 spawn:
   Agent(subagent_type="general-purpose", team_name="{팀명}", name="oplan-consult-1", mode="bypassPermissions",
     prompt="Skill('oplan_consult') 로딩. 사용자 요구사항: {원문}. PIPELINE_UUID={UUID}")
3. 완료 수신 → ofinish (경량 — Step 7.5 커밋 없음, TeamDelete + IDLE)

oplan_consult 내용:
  - Codex(GPT)가 독립 계획 수립 → 이종 AI 비판가(공통 맹점 발굴) → Claude oplan_deep(ultrathink)이 참조+반영하여 최종 통합
  - 순차 모드(기본): Codex 먼저 → 비판가 → Claude 통합
  - 병렬 모드: Claude+Codex 동시 독립 실행 → 비판가 → Claude merge
  - Fallback: codex-rescue → codex MCP → Claude 단독(oplan_deep)
  - Claude가 최종 통합자 (프로젝트 규칙/맥락 이해 우위)

사용_예시:
  - /oconsult API 설계 자문 받고 싶어
  - /oconsult 마이그레이션 전략 검토해줘
  - /oconsult 이 접근법이 좋은가 비교해줘  ← 비교 요청도 팀에이전트 spawn
