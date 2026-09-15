---
name: ohaiku
description: "Haiku 4.5 모델로 팀에이전트를 spawn하여 사용자 요청을 위임 처리. 사용자가 '/ohaiku' 호출 시 메인은 절대 직접 처리하지 않고 Haiku 모델 팀에이전트가 작업 수행 후 결과만 메인에 보고. 빠른 답변/간단 탐색/요약/단순 작업 등 경량 작업에 사용. 파이프라인 상태(IDLE/OK/PLAN/DEV/TEST/DONE/FINISH) 무관 동작."
invocation:
  user_callable: true
  pipeline_callable: true
  called_by: [사용자]
  calls: []
---

# ohaiku — Haiku 4.5 모델 팀에이전트 위임

> 메인은 작업하지 않는다. 사용자 요청을 Haiku 모델 팀에이전트에게 위임하고 결과만 받는다.

## 동작 원칙 (절대 규칙)

```yaml
금지:
  - 메인이 사용자 요청을 직접 처리 (코드 수정/탐색/분석/답변 모두 금지)
  - subagent_type 외 다른 모델 spawn (반드시 model="haiku")
  - 결과 가공 (팀에이전트 출력을 그대로 사용자에게 전달)

필수:
  - Agent 도구로 model="haiku" 팀에이전트 1개 spawn
  - 사용자 원문 요청 그대로 프롬프트에 주입
  - 팀에이전트 결과를 사용자에게 그대로 전달
```

## Step 1: 팀에이전트 Spawn

```python
Agent(
  name="ohaiku-worker",
  subagent_type="general-purpose",
  model="haiku",
  mode="bypassPermissions",
  prompt="""
사용자 요청: {원문}

당신은 Haiku 4.5 모델로 작동하는 위임 팀에이전트입니다.
위 사용자 요청을 처리하세요.

규칙:
- 작업/테스트/질문/분석/기획/설계/개발/수정 등 무엇이든 수행
- 코드 수정 필요 시 oio MCP 도구 사용 (file_edit/file_write/bash_exec)
- 결과는 사용자가 바로 이해할 수 있는 형식으로 정리
- 간결한 답변 우선 (Haiku는 빠른 처리 모델)
- 완료 시 SendMessage(to="main", message="작업 완료 + 결과 요약") 발송

파이프라인 상태 무관 — 어떤 state든 작업 수행하세요.
"""
)
```

## Step 2: 결과 전달

팀에이전트 SendMessage 수신 시:
- 결과를 사용자에게 그대로 전달
- 메인 추가 가공 금지
- 추가 작업 요청 시 Step 1 재실행

## 파이프라인 상태 처리

```yaml
IDLE: 정상 spawn
OK/PLAN/DEV/TEST/DONE/FINISH: 정상 spawn (write_guard 통과 — Agent 도구 자체는 차단되지 않음)
주의: 팀에이전트는 PIPELINE_UUID 자동 주입되어 write_guard.sh의 P4 분기로 통과
```

## 사용 예시

- `/ohaiku 이 파일 줄 수 알려줘`
- `/ohaiku 간단한 문법 질문 답해줘`
- `/ohaiku 이 함수 한 줄로 요약해줘`
- `/ohaiku grep으로 패턴 찾아줘`

## 모델 선택 가이드 (참고)

| 스킬 | 모델 | 용도 |
|------|------|------|
| /oopus | Opus 4.7 | 복잡한 분석/설계/디버깅 |
| /osonnet | Sonnet 4.6 | 일반 작업 |
| /ohaiku | Haiku 4.5 | 빠른 작업 (이 스킬) |
