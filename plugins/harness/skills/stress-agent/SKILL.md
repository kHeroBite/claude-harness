---
name: stress-agent
description: "echo/sleep/SendMessage/shutdown 응답 프로토콜로 동작하는 스트레스 테스트용 더미 에이전트."
invocation:
  user_callable: true
  pipeline_callable: false
  called_by: [사용자]
  calls: []
---
# stress-agent — 스트레스 테스트 에이전트 프로토콜

> 스트레스 테스트용 더미 에이전트. echo → sleep → SendMessage → shutdown 응답.
> 도구 제한: Bash + SendMessage만 사용. 다른 도구/스킬 절대 금지.

## 실행 프로토콜

```yaml
Step 0: 자가등록 (L-158 — config.json 경합 방어, 최우선 실행)
  1. Read ~/.claude/teams/{TEAM}/config.json
  2. 본인 이름(agent-{AGENT_ID})이 members에 있는지 확인
  3. 없으면 → flock + python3으로 원자적 자가등록:
     flock -w 10 /tmp/claude_config_lock_{TEAM}.lock python3 -c "
     import json, os
     path = os.path.expanduser('~/.claude/teams/{TEAM}/config.json')
     with open(path) as f:
         d = json.load(f)
     me = {'name': 'agent-{AGENT_ID}', 'agentId': 'agent-{AGENT_ID}@{TEAM}', 'isActive': True}
     if not any(m.get('name') == me['name'] for m in d.get('members', [])):
         d['members'].append(me)
         with open(path, 'w') as f:
             json.dump(d, f, indent=2)
         print(f'✅ {me[\"name\"]} 자가등록 완료')
     else:
         print(f'ℹ️ {me[\"name\"]} 이미 등록됨')
     "
  4. 등록 후 재확인: Read config.json → 본인 이름 존재 확인
  5. 실패 시 sleep 2 후 재시도 (최대 3회)
  6. 3회 실패 시 → 무시하고 계속 진행

Step 1: echo "Agent {AGENT_ID} started at $(date)"
Step 2: sleep {SLEEP_SEC:-30}
Step 3: SendMessage(type="message", recipient="{ORCHESTRATOR}", content="DONE agent {AGENT_ID}", summary="Agent {AGENT_ID} done")
  - isActive=false는 ofinish에서 일괄 전환
Step 4: shutdown_request 수신 시 → 즉시 shutdown_response(approve=true) 반환
```

## 파라미터

```yaml
AGENT_ID: 에이전트 번호 (1~N) — spawn 프롬프트에서 전달
TEAM: 팀명 — spawn 프롬프트에서 전달 (자가등록에 필요)
ORCHESTRATOR: 보고 대상 이름 — spawn 프롬프트에서 전달
SLEEP_SEC: 대기 시간 (기본 30초) — spawn 프롬프트에서 전달 (선택)
```

## 절대 금지

```yaml
금지_도구: Skill, Task, Edit, Write, Glob, Grep, WebFetch, WebSearch
허용_추가: Read (자가등록 시 config.json 확인용만 — L-158)
금지_행위:
  - odone, otest 등 어떤 스킬도 호출 금지
  - 메시지 분석/질문/거부 금지 — 지시된 4단계만 순서대로 실행
  - Step 1~3 순서 변경 금지
  - 추가 출력/분석/코멘트 최소화
```

## 모델 권장

```yaml
권장_모델: haiku
사유: echo+sleep+SendMessage만 수행하므로 haiku로 충분
```

## 사용 예시

```
Task(team_name="stress-v4", name="agent-3", model=haiku,
  prompt="/stress-agent 참조. AGENT_ID=3, TEAM=stress-v4, ORCHESTRATOR=ok-orchestrator, SLEEP_SEC=30")
```
