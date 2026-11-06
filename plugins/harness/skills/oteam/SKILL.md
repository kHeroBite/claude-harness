---
name: oteam
description: "사용자 요구사항을 팀에이전트에 강제 위임하는 스킬. '/oteam 요구사항' 호출 시 메인은 작업 크기와 무관하게 직접 처리하지 않고 반드시 팀에이전트를 spawn 해 맡긴 뒤 결과만 보고한다. 인자 없이 '/oteam' 만 호출하면 spawn 하지 않고 AskUserQuestion 으로 요구사항을 물은 뒤 그 답으로 spawn 한다. '/oteam', '팀에이전트 강제 위임', '팀에이전트로 처리해' 요청 시 사용. 모델을 고정하지 않고 파이프라인 state 를 바꾸지 않으며 어떤 state 에서도 동작한다."
---

# oteam — 팀에이전트 강제 위임

> 메인은 작업하지 않는다. 요구사항을 팀에이전트에게 넘기고 결과만 전달한다. 호출 순서는 `ointaug` → `oteam` 이다.

## 절대 규칙

```yaml
금지:
  - 메인이 요구사항을 직접 처리 (코드 수정·탐색·분석·답변 모두)
  - "작업이 작다", "한 줄이면 끝난다", "이미 답을 안다" 는 이유로 spawn 생략
  - spawn 이 실패했을 때 메인이 대신 처리하는 폴백
  - 인자가 없는데 요구사항을 추측해 spawn
  - 질문을 텍스트로 하고 턴 종료 (Stop_askq_guard 가 막는다. 반드시 AskUserQuestion 도구를 쓴다)
메인에게_허용된_행동:
  - 아래 절차의 값 확인(state·team_name 읽기), no_kill 마커 쓰기·삭제, ListAgents, AskUserQuestion, Agent, SendMessage
```

## Step 1: 인자 판정

인자에서 앞뒤 공백을 지운다. 남은 내용이 있으면 그 원문을 요구사항으로 삼아 Step 3 으로 간다. 비어 있으면 Step 2 로 간다.

## Step 2: 인자가 없으면 묻는다

spawn 하지 않고 AskUserQuestion 을 호출한다. 요구사항은 사용자만 아는 값이므로 자율주행 무질문 방침의 예외다.

- header 는 `요구사항`, 질문은 `팀에이전트에게 맡길 요구사항을 입력해 주세요.` 로 한다.
- 옵션은 `직접 입력(Other 선택)`, `취소` 두 개이고 실제 내용은 Other 로 받는다.
- Other 입력이 있으면 그 원문으로 Step 3 으로 간다.
- `취소` 를 고르면 spawn 없이 1줄 보고하고 끝낸다.
- 내용 없이 `직접 입력(Other 선택)` 만 고르면 1회만 다시 묻고, 그래도 비어 있으면 spawn 없이 끝낸다.

## Step 3: spawn 값 확인

UUID 는 hook 메시지(system-reminder 의 `🆔 [UUID]`)의 36자 값이다. `$CLAUDE_SESSION_ID` 는 쓰지 않는다. UUID 를 정할 수 없으면 그 사실을 보고하고 멈춘다. 타 세션을 탐색해 찾지 않는다.

```yaml
CONFIG_DIR: 환경변수 CLAUDE_CONFIG_DIR 값. 비어 있으면 $HOME/.claude 의 절대경로
STATE: ${CONFIG_DIR}/session-env/${UUID}/state 첫 단어. 파일이 없으면 IDLE 로 본다
TEAM_NAME: ${CONFIG_DIR}/session-env/${UUID}/team_name 내용. 없거나 비었으면 session-{UUID 앞 8자}
NAME: oteam-worker. 이 세션에 아직 살아 있는 같은 이름이 있으면 oteam-worker-2, -3 순으로 쓴다
```

STATE 가 PLAN 또는 DEV 이면 ListAgents 를 먼저 1회 호출한다. 호출 전 Agent 는 F-PEER-GATE 가 막는다.

## Step 4: no_kill 마커

Agent 호출 전에 `mcp__oio__file_write` 로 `${CONFIG_DIR}/session-env/${UUID}/no_kill/${NAME}` 를 쓴다. 내용은 `oteam 위임 작업 진행 중` 이다.

`Stop_orphan_agent_sweep.sh` 는 `oteam-*` 이름을 정리 대상에서 뺀다. 마커는 `oteam-worker` 계열이 아닌 이름을 쓰게 됐을 때의 안전망이다. 이 단계를 건너뛰지 않으며, 다른 이름을 빌려 피하지 않는다.

## Step 5: 팀에이전트 spawn

```python
Agent(
  description="oteam 위임 작업",
  name=NAME,                      # 필수. 없으면 팀원이 아니라 서브에이전트로 돈다
  subagent_type="general-purpose",
  team_name=TEAM_NAME,            # STATE 가 IDLE 이면 생략
  prompt="""
PIPELINE_UUID={UUID}
CLAUDE_CONFIG_DIR={CONFIG_DIR}

사용자 요구사항 원문:
{원문 그대로}

당신은 oteam 이 띄운 위임 팀에이전트입니다. 위 요구사항을 끝까지 처리하세요.
- 프로젝트의 CLAUDE.md 규칙과 도구 정책을 따릅니다.
- 하위 Agent 는 spawn 하지 않습니다. 필요하면 리드에게 요청합니다.
- 가드에 막히면 표현을 바꿔 우회하지 말고 차단 문구 그대로 리드에게 보고합니다.
- 결과는 사용자가 바로 이해할 수 있게 정리하고, 파일은 절대 전체경로로 씁니다.
- 끝나면 SendMessage(to="team-lead") 로 결과를 보고합니다. 그 수신자가 없다는 오류가 나면 to="main" 으로 보냅니다.
"""
)
```

- STATE 가 IDLE 이면 prompt 의 `PIPELINE_UUID`·`CLAUDE_CONFIG_DIR` 두 줄도 뺀다. 그 외 state 에서는 두 줄이 prompt 첫머리에 반드시 있어야 하며 빠지면 `team_agent_env_guard.sh` 가 막는다.
- 모델은 사용자가 요구사항에서 지정했을 때만 `model` 로 넘긴다. 나머지는 기본값을 쓴다.
- 요구사항 문구에 서로 독립인 일이 명시돼 있으면 같은 메시지에서 여러 팀원을 동시에 spawn 해도 된다. 이를 가리려고 메인이 코드를 탐색하지 않는다.
- spawn 이 차단·실패하면 차단 문구를 읽고 빠진 값을 채워 같은 도구로 다시 호출한다. 그래도 안 되면 사유를 사용자에게 보고하고 멈춘다. 메인이 대신 처리하지 않는다.
- PostToolUse 가 F-AGENT-2(in-process 서브에이전트로 실행됨)를 알리면 그 사실을 결과 보고에 함께 적는다.

`/oteam` 슬래시 입력 뒤에는 F-OTEAM 게이트가 spawn 전까지 위 허용 행동 밖의 도구를 막고, spawn 없이 턴을 끝내려 하면 2회 막는다. 막히면 표현을 바꾸지 말고 차단 문구를 사용자에게 보고한다.

## Step 6: 결과 전달과 정리

1. spawn 직후 맡긴 사실을 1줄 알리고 턴을 끝낸다. 결과를 기다리며 같은 일을 시작하지 않는다.
2. 팀원 보고가 오면 내용을 가공하지 않고 사용자에게 그대로 전달한다.
3. 추가 요청이 있으면 그 팀원에게 SendMessage 로 넘긴다. 메인이 처리하지 않는다.
4. 작업이 끝나면 `SendMessage(to=NAME, message={"type":"shutdown_request"})` 를 보내고, `mcp__oio__file_delete` 로 no_kill 마커를 지운다.

## 사용 예

- `/oteam 이 함수에 null 처리 추가해줘`
- `/oteam 빌드 로그에서 경고 원인 정리해줘`
- `/oteam` → 요구사항을 묻고 답으로 spawn 한다.
