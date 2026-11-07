---
name: oqa
description: "질답 전용 팀에이전트를 spawn 하는 스킬. '/oqa 질문' 호출 시 메인은 질문을 직접 답하지 않고 질답 전용 팀원(oqa-N)에게 넘긴다. 이 팀원은 답변만 하고 파일·git·설치·서비스 변경 같은 작업은 team-lead 에게 [작업 위임] 으로 되돌린다. 답변을 위해서는 모든 도구와 메인·팀원과의 SendMessage 를 쓸 수 있다. 인자 없이 '/oqa' 만 호출하면 AskUserQuestion 으로 질문을 받는다. oi 의 C_질문에서도 Skill('oqa') 로 호출한다. 파이프라인 state 를 바꾸지 않고 어떤 state 에서도 동작한다."
---

# oqa — 질답 전용 팀에이전트

> 질문에는 답만 한다. 작업이 필요하면 직접 하지 않고 메인에게 되돌린다. 호출 순서는 `ointaug` → `oqa` 이다.

## 절대 규칙

```yaml
메인_금지:
  - 질문을 메인이 직접 처리 (탐색·분석·답변 모두)
  - spawn 이 실패했을 때 메인이 대신 답하는 폴백
  - 인자가 없는데 질문을 추측해 spawn
  - 질문을 텍스트로 하고 턴 종료 (반드시 AskUserQuestion 도구를 쓴다)
  - 질문이 사실은 변경 요청이면 oqa 에 넘기지 않는다. 메인이 oi 의 수정 명령 경로로 처리한다.
메인_허용:
  - 값 확인(state·team_name 읽기), no_kill 마커 쓰기·삭제, ListAgents, AskUserQuestion, Agent, SendMessage
```

## Step 1: 인자 판정

인자에서 앞뒤 공백을 지운다. 남은 내용이 있으면 그 원문을 질문으로 삼아 Step 3 으로 간다. 비어 있으면 Step 2 로 간다.

## Step 2: 인자가 없으면 묻는다

spawn 하지 않고 AskUserQuestion 을 호출한다. 질문은 사용자만 아는 값이므로 자율주행 무질문 방침의 예외다.

- header 는 `질문`, 질문 문구는 `질답 팀원에게 물어볼 내용을 입력해 주세요.` 로 한다.
- 옵션은 `직접 입력(Other 선택)`, `취소` 두 개이고 실제 내용은 Other 로 받는다.
- Other 입력이 있으면 그 원문으로 Step 3 으로 간다.
- `취소` 를 고르면 spawn 없이 1줄 보고하고 끝낸다.
- 내용 없이 `직접 입력(Other 선택)` 만 고르면 1회만 다시 묻고, 그래도 비어 있으면 spawn 없이 끝낸다.

## Step 3: spawn 값 확인

UUID 는 hook 메시지(system-reminder 의 `🆔 [UUID]`)의 36자 값이다. `$CLAUDE_SESSION_ID` 는 쓰지 않는다. UUID 를 정할 수 없으면 그 사실을 보고하고 멈춘다. 타 세션을 탐색해 찾지 않는다.

```yaml
CONFIG_DIR: 환경변수 CLAUDE_CONFIG_DIR 값. 비어 있으면 ${CLAUDE_CONFIG_DIR:-$HOME/.claude} 의 절대경로
STATE: ${CONFIG_DIR}/session-env/${UUID}/state 첫 단어. 파일이 없으면 IDLE 로 본다
TEAM_NAME: ${CONFIG_DIR}/session-env/${UUID}/team_name 내용. 없거나 비었으면 session-{UUID 앞 8자}. oi 경유로 팀이 없어도 같은 규칙을 쓴다
NAME: oqa-1. 이 세션에 아직 살아 있는 같은 이름이 있으면 oqa-2, oqa-3 순으로 쓴다
```

- 세션당 팀원 동시 생존 상한은 10개다. 넘기지 않는다.
- STATE 가 PLAN 또는 DEV 이면 ListAgents 를 먼저 1회 호출한다. 호출 전 Agent 는 F-PEER-GATE 가 막는다.

## Step 4: no_kill 마커

Agent 호출 전에 `mcp__oio__file_write` 로 `${CONFIG_DIR}/session-env/${UUID}/no_kill/${NAME}` 를 쓴다. 내용은 `oqa 질답 진행 중` 이다.

고아 에이전트 정리 hook 은 `oqa-*` 이름을 화이트리스트에 두지 않는다. 이 마커가 없으면 질답 중에 팀원이 정리될 수 있다. 이 단계를 건너뛰지 않으며, 다른 이름을 빌려 피하지 않는다.

## Step 4 spawn: 팀에이전트 띄우기

```python
Agent(
  description="oqa 질답",
  name=NAME,                      # 필수. 없으면 팀원이 아니라 서브에이전트로 돈다
  subagent_type="general-purpose",
  team_name=TEAM_NAME,            # STATE 가 IDLE 이면 생략
  prompt="""
PIPELINE_UUID={UUID}
CLAUDE_CONFIG_DIR={CONFIG_DIR}

사용자 질문 원문:
{원문 그대로}

당신은 oqa 가 띄운 질답 전용 팀에이전트입니다. 답변만 합니다.

[허용]
- 답변을 위한 모든 도구를 쓸 수 있습니다. 파일 읽기, 검색, WebSearch, WebFetch, 상태를 바꾸지 않는 셸 조회, ListAgents 가 해당합니다.
- 답변에 필요한 사실은 SendMessage 로 team-lead(없으면 main)와 다른 팀원에게 물어볼 수 있습니다.

[금지]
- 파일 생성·수정·삭제·이동·이름 변경을 하지 않습니다.
- git 커밋·push·브랜치 변경을 하지 않습니다.
- 패키지·도구 설치를 하지 않습니다.
- 서비스·프로세스 기동·중지·설정 변경을 하지 않습니다.
- DB 쓰기(INSERT·UPDATE·DELETE·DDL)를 하지 않습니다.
- 다른 에이전트를 spawn 하지 않습니다.
- 다른 팀원에게 변경 작업을 지시하지 않습니다.

[작업이 필요한 요청을 받으면]
직접 하지 않고 SendMessage(to="team-lead") 로 아래 형식의 [작업 위임] 을 보냅니다. 수행 여부는 메인이 판단합니다.
[작업 위임]
- 요청 요지: ...
- 대상 파일·명령: ...
- 이유: ...
- 근거: ...

[답변 방식]
- 답변 본문은 SendMessage(to="team-lead") 로 보냅니다. 그 수신자가 없다는 오류가 나면 to="main" 으로 보냅니다.
- 사용자가 바로 읽을 수 있게 정리하고, 파일은 절대 전체경로로 씁니다.
- 직접 확인한 사실만 단정합니다. 확인하지 못한 것은 "확실하지 않음" 이라고 쓰고, 추정은 "추정" 이라고 씁니다.
- 웹 검색·조회 결과를 쓰면 출처 URL 을 함께 씁니다.
- 가드에 막히면 표현을 바꾸거나 다른 도구로 우회하지 말고 차단 문구 그대로 team-lead 에 보고합니다.
- 답변 후에도 세션을 유지하고 후속 질문을 받습니다. shutdown_request 를 받으면 즉시 승인 응답을 보냅니다.
"""
)
```

- STATE 가 IDLE 이면 prompt 의 `PIPELINE_UUID`·`CLAUDE_CONFIG_DIR` 두 줄도 뺀다. 그 외 state 에서는 두 줄이 prompt 첫머리에 반드시 있어야 하며 빠지면 `team_agent_env_guard.sh` 가 막는다.
- 모델은 사용자가 지정했을 때만 `model` 로 넘긴다. 나머지는 기본값을 쓴다.
- spawn 이 차단·실패하면 차단 문구를 읽고 빠진 값을 채워 같은 도구로 다시 호출한다. 그래도 안 되면 사유를 사용자에게 보고하고 멈춘다. 메인이 대신 답하지 않는다.
- Agent 호출 직후 ofinish 가 누락 없이 정리하도록 `mcp__oio__file_write` 로 `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/agents/${NAME}` 를 방어적으로 등록한다. 내용은 `${NAME}` 이다.
- PostToolUse 가 F-AGENT-2(in-process 서브에이전트로 실행됨)를 알리면 그 사실을 결과 보고에 함께 적는다.

## Step 5: 결과 전달과 정리

1. spawn 직후 질답 팀원에게 맡긴 사실을 1줄 알리고 턴을 끝낸다. 결과를 기다리며 같은 질문을 직접 조사하지 않는다.
2. 팀원 답변이 오면 가공하지 않고 사용자에게 그대로 전달한다.
3. 후속 질문은 같은 팀원에게 SendMessage 로 넘긴다. 메인이 처리하지 않는다.
4. 팀원이 [작업 위임] 을 보내면 메인이 수행 여부를 판단하고, 수행한다면 oi 의 수정 명령 경로나 파이프라인으로 처리한다. 질답 팀원에게 되돌려 시키지 않는다.
5. 질답이 끝나면 `SendMessage(to=NAME, message={"type":"shutdown_request"})` 를 보내고, `mcp__oio__file_delete` 로 no_kill 마커를 지운다. agents/ 등록 파일은 ofinish 정리에 맡긴다.

## 자율 준수 한계

이 스킬의 제약은 팀원 지시문 규칙뿐이다. 차단 hook 을 두지 않았다.

- 질답 팀원은 general-purpose 라 Edit·Write 도구를 가진다. 지시문을 어겨도 물리적으로 막지 못한다.
- 위반은 team-lead 가 사후 관찰로만 알 수 있다. 위반을 발견하면 결과를 되돌리고 사용자에게 보고한다.
- 지시문이 유일한 방어선이며, 준수는 통계적으로도 보증되지 않는다.

## oi 와의 관계

oi 의 C_질문은 `Skill('oqa')` 를 호출해 이 절차를 따른다. spawn 프롬프트와 절차는 oqa 가 단일 출처다. 팀이 없을 때의 처리와 직접 처리 폴백 금지 원칙은 oi 가 유지한다.

## 사용 예

- `/oqa 이 훅은 어느 이벤트에서 호출돼?`
- `/oqa 최근 커밋에서 바뀐 스킬이 뭐야?`
- `/oqa` → 질문을 묻고 답으로 spawn 한다.
