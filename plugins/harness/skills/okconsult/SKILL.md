---
name: okconsult
description: "ok 파이프라인 + oplan_consult 강제 — '/okconsult' 호출 시 forced_tier=o4(기본)/o5로 oplan을 spawn하고 oplan_consult(Claude×Codex 이종 AI) 사용을 hint. ok 전체 파이프라인 적용."
invocation:
  user_callable: true
  pipeline_callable: false
  called_by: [사용자]
  calls: [ok, oplan, oplan_consult]
---
# okconsult — ok + oplan_consult 강제

사용자가 `/okconsult` 호출 시 ok 파이프라인을 실행하되,
oplan spawn 시 `forced_tier=o4` + `hint_plan=oplan_consult`를 전달하여 oplan_consult depth를 우선 사용하게 한다.

## 설계 근거

oplan_consult는 oplan의 o4(조건부)/o5(기본) depth 파생 스킬이다.
oplan을 대체할 수 없음 — Phase A~J(탐색/의도파악/Scout/출력규격)는 oplan이 수행해야 한다.
o4부터 oplan_consult 실행 가능하므로 forced_tier=o4로 진입하여 oplan_consult를 hint한다.
작업 규모가 실제로 o5에 해당하면 oplan이 o5로 승격할 수 있다.

## 동작

1. Skill('ok') 로딩 (ok 오케스트레이션 지침 전체 적용)
2. oplan 팀에이전트 spawn 시 **forced_tier=o4** + **hint_plan=oplan_consult** 전달:
   - oplan이 Phase A+B 탐색 스킵 → o4 depth 진입
   - o4 depth에서 oplan_deep 대신 oplan_consult(Claude×Codex 이종 AI 협업) 선택
   - **fallback 절대 금지**: Codex 불가 등 어떠한 사유로도 oplan_consult 생략 불가
   - oplan_consult 실행 불가 시: 사용자에게 사유 보고 후 중단 (oplan_deep 등 다른 방식으로 대체 금지)
   - 작업 규모 o5 해당 시: oplan이 o5로 승격 가능 (동적 승격 허용)
3. oplan 이후: ok_pipeline 정상 흐름 (odev → otest → odone → ofinish)

## oplan spawn 프롬프트 (ok Step 1)

```
Skill('oplan') 호출. forced_tier=o4 — tier 결정 스킵, o4 depth로 즉시 실행.
hint_plan=oplan_consult — oplan_deep 대신 oplan_consult(Claude×Codex 이종 AI) 우선 사용.
사용자 요구사항: {원문}.
Skill('oinfra_{project}') 호출.
PIPELINE_UUID={UUID}. 대화ID: {CONV_ID}
```

## 주의

- forced_tier=o4이므로 o4 파이프라인 기본 적용 (o5로 승격 시 o5 필수 단계 추가)
- **hint_plan=oplan_consult는 강제** — oplan이 어떤 사유로도 oplan_deep 등 다른 방식으로 전환 불가
- oplan_consult 실행 불가 시: 계획 수립 중단 → 메인에 "oplan_consult 실행 불가: {사유}" 보고
- ok의 모든 나머지 규칙(TeamCreate, UUID, evidence, ofinish 등) 동일 적용

## 사용 예시

- /okconsult API 아키텍처 전면 개편해줘
- /okconsult 마이그레이션 구현해줘
