---
name: okdebate
description: "ok 파이프라인 + oplan_debate 강제 — '/okdebate' 호출 시 tier는 oplan이 실규모로 결정하되, 계획 방식은 oplan_debate를 hint로 강제. o3 작업도 oplan_debate로 계획 수립."
invocation:
  user_callable: true
  pipeline_callable: false
  called_by: [사용자]
  calls: [ok, oplan, oplan_debate]
---
# okdebate — ok + oplan_debate 강제

사용자가 `/okdebate` 호출 시 ok 파이프라인을 실행하되,
oplan spawn 시 `hint_plan=oplan_debate`를 전달하여 tier와 무관하게 oplan_debate를 계획 방식으로 강제한다.

## 설계 근거

- **tier는 실제 작업 규모대로**: oplan이 Phase A+B 탐색 후 o2~o5 중 실규모에 맞게 결정
- **계획 방식만 강제**: o3 작업이라도 oplan_debate(3분석가 토론 + 배심원)로 계획 수립
- okconsult와 동일 패턴 (okconsult는 oplan_consult 강제, okdebate는 oplan_debate 강제)

## 동작

1. Skill('ok') 로딩 (ok 오케스트레이션 지침 전체 적용)
2. oplan 팀에이전트 spawn 시 **hint_plan=oplan_debate** 전달:
   - oplan이 Phase A+B 탐색으로 실규모 tier 결정 (o2~o5)
   - tier 결정 후 계획 수립 단계에서 oplan_debate 우선 사용
   - oplan_debate: 3분석가(아키텍처/리스크/구현) × 비판가 × 배심원 만장일치
   - **fallback 절대 금지**: Codex 불가 등 어떠한 사유로도 oplan_debate 생략 불가
   - oplan_debate 실행 불가 시: 사용자에게 사유 보고 후 중단 (다른 계획 방식으로 대체 금지)
3. oplan 이후: ok_pipeline 정상 흐름 (odev → otest → odone → ofinish)
   - tier에 맞는 파이프라인 적용 (o3이면 o3 파이프라인, o5이면 o5 파이프라인)

## oplan spawn 프롬프트 (ok Step 1)

```
Skill('oplan') 호출. hint_plan=oplan_debate — tier는 탐색 후 실규모로 결정, 계획 방식은 oplan_debate 우선 사용.
사용자 요구사항: {원문}.
Skill('oinfra_{project}') 호출.
PIPELINE_UUID={UUID}. 대화ID: {CONV_ID}
```

## 주의

- tier는 oplan이 결정 — o3으로 판정되면 o3 파이프라인 적용 (o5 필수 단계 미적용)
- **hint_plan=oplan_debate는 강제** — oplan이 어떤 사유로도 다른 계획 방식으로 전환 불가
- oplan_debate 실행 불가 시: 계획 수립 중단 → 메인에 "oplan_debate 실행 불가: {사유}" 보고
- ok의 모든 나머지 규칙(TeamCreate, UUID, evidence, ofinish 등) 동일 적용

## 사용 예시

- /okdebate 인증 모듈 리팩토링해줘   ← o3 규모라도 oplan_debate로 계획
- /okdebate 새 결제 시스템 설계 및 구현   ← o5 규모면 o5 파이프라인 적용
