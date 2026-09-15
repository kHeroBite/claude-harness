---
name: oplan_debate
description: "이종 3분석가 × 이종 2비판가 토론 계획 수립. fable×2(아키텍처/리스크) + codex:rescue×1(구현)이 독립 분석 → 비판가 2인 동시(codex:adversarial-review + fable) critique_A/B 생성 → 3방향 debate → 3인 vote → sonnet 배심원 만장일치 → oplan-final(fable) → Codex 적대적 검증(조건부). o4(선택)/o5(필수) 작업에서 자동 실행. 수동 호출: '/oplan_debate'."
invocation:
  user_callable: true
  pipeline_callable: true
  called_by: ["ok_pipeline(o4 자율선택/o5 자율선택 기본값)"]
  calls: ["oplan"]
---
# oplan_debate — 이종 3분석가 × 이종 2비판가 토론 계획 수립

## ogrill 5축 결손 판정 (oplan 내부 절차 — 절대 규칙)

> oplan_debate 팀에이전트는 Phase A(의도 분석) 진입 직전 5축(목표/범위/제약/완료기준/열린질문) 결손 카운트를 수행한다.
> 메인 에이전트는 이 판정을 수행하지 않는다 (CLAUDE.md "ogrill 호출 정책" 참조).
> 상세 절차: oplan/SKILL.md "ogrill 5축 결손 판정" 섹션 참조 (단일 출처).

## 절대규칙

```yaml
shutdown_즉답_절대규칙 (L-U5):
  - shutdown_request 수신 즉시 현재 작업 중단 후 shutdown_response 발송
  - 파일 저장/정리 등 후처리 후 응답하는 행위 절대 금지
  - 메인이 3회×5s=15초 내에 응답 없으면 pane 강제 종료 대상
```

> ok의 o4(선택)/o5(필수) 파이프라인에서 기본 oplan 대신 실행되는 토론 기반 계획 수립 스킬.
> fable×2 + codex:rescue×1의 이종 분석가가 서로 다른 렌즈로 독립 분석 → 이종 비판가 2인이 동시에 맹점 발굴 → 교차 토론 합의 → 단일 최종안 도출.

## 트리거 조건

```yaml
자동_트리거: task_classification = O4(DEBATE_ROUTING 해당 시) 또는 O5(필수) (ok가 oplan 대신 이 스킬 경로로 분기)
수동_트리거: 사용자가 '/oplan_debate' 직접 호출
적용_시점: 복잡도 높은 설계, 다수 파일 변경, 아키텍처 결정이 필요한 작업
```

## 전체 흐름

```
oplan-1 (아키텍처 렌즈, fable)      ──┐
oplan-2 (리스크 렌즈,   fable)      ──┼→ [1.5단계] 비판가-A(codex:adversarial-review) → critique_A.md ─┐
oplan-3 (구현 렌즈,    codex:rescue)──┘             비판가-B(general-purpose fable) → critique_B.md ─┤
                                                                                                          ↓
                                                      debate(3인 교차 — critique_A+B 동시 참조)
                                                                    ↓
                                                      vote(3인 합의 — critique_A+B 동시 참조)
                                                                    ↓
                                                      배심원(sonnet 3명 만장일치)
                                                                    ↓
                                                      oplan-final (fable)
                                                                    ↓
                                            [조건부] Codex 적대적 검증 (codex:adversarial-review)
                                            SKIP: plan_codex.md AND critique_A.md 모두 존재 시
                                            실행: 둘 중 하나라도 실패(팅김/미참여) 시
                                                                    ↓
                                                      oplan_final.md (${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/plans/)
```

## 단계별 절차

### 0단계: TeamCreate + 메인 사전 탐색 (spawn 전 필수)

> 서브에이전트가 대용량 파일을 직접 읽지 않도록, 메인이 핵심 컨텍스트를 사전 추출하여 공유 파일로 저장.

```yaml
TeamCreate_필수 (oplan-1/2/3 spawn 전 최우선):
  조건: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/team_name 미존재 시
  절차:
    1. team_name 파일 확인:
       - team_name 파일 없음 → SendMessage(to="team-lead", message="team_name 미제공 — ok에서 재호출 필요", summary="team_name 없음") → 중단 (TeamDelete 금지)
       - team_name 파일 있음 → config.json 존재 확인만 수행 (TeamDelete 절대 금지)
    2. config.json 확인:
       test -f ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams/{팀명}/config.json || echo "⚠️ config.json 없음 — TeamCreate 필요"
       - config.json 없음: TeamCreate 실행
       - config.json 있음: 스킵 (팀 이미 생성됨)
    3. team_name 저장: mcp__oio__session_state(uuid="${UUID}", key="team_name", value="{팀명}")
  목적: oplan-1/2/3 spawn 전 팀 컨텍스트 확보 필수
  주의: 이미 ok에서 TeamCreate한 경우 team_name 파일이 존재 → 스킵
  금지: 팀에이전트 컨텍스트에서 TeamDelete 절대 금지 (팀에이전트는 메인의 팀 구성을 알 수 없음)
```

```yaml
실행_주체: 메인 (oplan-1/2/3 spawn 전)
목적: 서브에이전트 파일 읽기 최소화 → 컨텍스트 초과 방지

절차:
  1. 요구사항 관련 핵심 심볼 Grep (5~10개)
  2. 각 심볼 주변 20줄씩만 Read
  3. 프로젝트 핵심 정보 요약 (경로, 빌드 명령, 주요 패턴 — 3줄 이내)
  4. 추출 결과를 context_summary.md로 저장

저장_경로: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/plans/context_summary.md
형식:
  ## 프로젝트 핵심 정보
  - 경로: {프로젝트 루트}
  - 빌드: {빌드 명령}
  - 주요 패턴: {2줄 이내}

  ## 관련 코드 스니펫
  ### {파일명:줄번호}
  {관련 코드 20줄}
  ... (최대 5개 파일)

제한:
  - context_summary.md 전체 크기 목표: 200줄 이내
  - 파일 전체 복사 금지 — 핵심 스니펫만
  - 이미 메인이 읽은 파일은 재읽기 없이 결과 재사용
```

```yaml
goal_json_공유 (soft hint — 2차수 통합):
  적용: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/goal.json 존재 시에만
  동작: |
    context_summary.md 생성 시 goal.json 요약 섹션을 상단에 포함.
    oplan-1/2/3(분석가) + 배심원(3인)이 동일 계약 컨텍스트를 공유.
  포함_내용: goal.intent / goal.scope_in / goal.acceptance (5줄 이내 요약)
  배심원_항목 (soft): goal.json locked==true 시 배심원 투표 체크리스트에
    "goal.acceptance 충족 여부" 1항목을 추가 권장 (locked=false/부재 시 스킵).
  부재_시: 본 블록 스킵, 기존 context_summary만 사용 (오류 아님)
```

### 1단계: 3방향 병렬 독립 분석 (이종 구성)

> ⚠️ **팀에이전트 spawn 절대 규칙 (P-TEAM — 재발방지 L-373)**:
> oplan_debate의 모든 하위 참가자(oplan-1/2/3, 비판가-A/B, 배심원 3인, oplan-final)는
> **반드시 팀에이전트로 spawn**해야 한다. 서브에이전트(name/team_name 없는 Agent 호출)는 절대 금지.
>
> **올바른 형식 (필수)**:
> ```
> Agent(
>   name="oplan-1",                 # 필수 — 없으면 pane 미생성 → SendMessage 라우팅 불가
>   team_name="{팀명}",             # 필수 — 파이프라인 활성 중 full_task_team_guard가 차단
>   subagent_type="general-purpose",
>   model="fable",
>   mode="bypassPermissions",       # 필수 — 권한 프롬프트 대기 방지
>   run_in_background=True,
>   prompt="..."
> )
> ```
>
> **잘못된 형식 (절대 금지)**:
> ```
> Agent(subagent_type="general-purpose", model="opus", prompt="...")  # ❌ name/team_name/mode 누락
> Task(subagent_type="...", prompt="...")                              # ❌ Task 도구 사용 금지
> ```
>
> **참가자 name 네이밍 규칙 (고정)**:
> - oplan-1 (아키텍처 렌즈), oplan-2 (리스크 렌즈), oplan-3 (구현 렌즈)
> - 비판가-A (codex:adversarial-review), 비판가-B (fable 심층 비판)
> - 배심원-1, 배심원-2, 배심원-3 (sonnet 만장일치)
> - oplan-final (fable 통합)
>
> **team_name 조회**: `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/team_name` 파일에서 읽기
> (Step 0에서 저장됨). 파일 없으면 SendMessage로 메인에 재호출 요청 후 중단.
>
> **위반 시**: `.claude/hooks/full_task_team_guard.sh`가 차단 (HOOK_BLOCK_NO_TEAM_AGENT / HOOK_BLOCK_NO_NAME_PARAM).
> Hook 차단은 안전망일 뿐 — 스스로 올바른 형식으로 호출하라.

```yaml
실행: oplan-1, oplan-2, oplan-3 병렬 spawn (팀에이전트 형식 필수 — 위 P-TEAM 규칙 참조)
모델_배정 (이종 구성):
  oplan-1 (아키텍처 렌즈): fable
  oplan-2 (리스크 렌즈):   fable
  oplan-3 (구현 렌즈):     codex:rescue  ← 이종 AI (Claude 집단 편향 원천 차단)
이종_구성_이유: Claude 동질 편향 방지 + 비용 절감 (fable×3 → fable×2 + codex×1)

⚠️ 컨텍스트_절약_필수 (서브에이전트 팅김 방지):
  스킬_로딩_금지:
    - Skill('oplan') 호출 절대 금지 (SKILL.md 440줄 로딩 → 컨텍스트 폭발 원인)
    - Skill('oplan_debate') 호출 절대 금지 (재귀 로딩)
    - Skill('oinfra_*') 호출 절대 금지 (PROJECT.md + 참조 파일 연쇄 로딩)
    - 프로젝트 인프라 정보는 spawn 프롬프트의 context_summary.md에서만 참조
  파일_읽기_제한:
    - context_summary.md 이외 추가 파일 읽기: 최대 2개, 각 50줄 이내
    - 대용량 파일(100줄+) 전체 읽기 금지 — Grep으로 핵심 섹션만
  ultrathink_조건:
    - spawn 프롬프트 < 1,000 토큰 AND 추가 파일 읽기 < 2개인 경우에만 사용
    - 위 조건 미충족 시: ultrathink 생략, 일반 thinking으로 수행
  첫_행동_필수 (팅김_감지용):
    - 진입 직후 즉시: mcp__oio__session_state(uuid="${UUID}", key="agent_oplan{N}_status", value="started")
    - 타임스탬프: mcp__oio__session_state(uuid="${UUID}", key="agent_oplan{N}_start_ts", value="$(date +%s 실행 결과)")
    - 정상 완료 시: mcp__oio__session_state(uuid="${UUID}", key="agent_oplan{N}_status", value="done")

spawn_프롬프트_구조 (최대 1,500 토큰 목표):
  [1] 역할 선언: 렌즈명 + 핵심 질문 (2줄)
  [2] 요구사항: 원문 요약 (500자 이내)
  [3] 컨텍스트: context_summary.md 경로 ("이 파일 읽고 시작")
  [4] 임무: 렌즈 관점 분석 + 출력 파일 경로
  [5] 제약: 스킬 로딩 금지 / 파일 읽기 제한 / 첫 행동 필수 명시
  [6] 완료 보고: SendMessage 지시

  🚨 경로 표기 절대 규칙 (L-384 재발방지):
    - spawn 프롬프트의 모든 파일 경로는 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/... 절대 경로로 기재
    - 상대 경로 금지 (예: "plans/oplan_final_v2.md" ❌) — 팀에이전트의 CWD는 프로젝트 루트이므로 상대 경로는 session-env 격리 디렉토리가 아닌 프로젝트 루트로 해석됨
    - 올바른 예: "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${PIPELINE_UUID}/plans/oplan_final_v2.md" ✓
    - 단, 프로젝트 루트 내부 파일(.claude/hooks/*, MCP-Servers/* 등)을 가리킬 때는 상대 경로 허용 (CWD 기준)
    - 이 규칙은 oplan_debate뿐 아니라 odev/otest/odone 모든 팀에이전트 spawn에 공통 적용

렌즈_할당 (분석 관점 분리 — 이종 모델 배정):
  oplan-1 (아키텍처 렌즈) — fable:
    우선순위: 시스템 구조, 컴포넌트 경계, 확장성
    핵심 질문: "이 설계가 6개월 후에도 유효한가?"
    spawn_형식 (팀에이전트 필수 — P-TEAM):
      Agent(
        name="oplan-1",
        team_name="{팀명}",
        subagent_type="general-purpose",
        model="fable",
        mode="bypassPermissions",
        run_in_background=True,
        prompt="..."
      )
    출력: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/plans/plan_1.md

  oplan-2 (리스크 렌즈) — fable:
    우선순위: 실패 시나리오, 엣지케이스, 롤백 전략
    핵심 질문: "무엇이 잘못될 수 있는가?"
    spawn_형식 (팀에이전트 필수 — P-TEAM):
      Agent(
        name="oplan-2",
        team_name="{팀명}",
        subagent_type="general-purpose",
        model="fable",
        mode="bypassPermissions",
        run_in_background=True,
        prompt="..."
      )
    출력: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/plans/plan_2.md

  oplan-3 (구현 렌즈) — codex:rescue (이종 AI):
    우선순위: 실제 코드 변경 범위, 의존성, 실행 순서
    핵심 질문: "지금 당장 구현하면 무엇이 막히는가?"
    spawn_방법 (단계별 fallback — 모두 팀에이전트 형식 필수, P-TEAM):
      1차_시도: Agent(name="oplan-3", team_name="{팀명}", subagent_type="codex:codex-rescue", mode="bypassPermissions", run_in_background=False)
        # oplan-3 agents/ 수동 등록 (codex:rescue는 자동 등록 안 됨)
        spawn_직후_수동등록:
          AGENTS_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams/${TEAM_NAME}/agents"
          mkdir -p "$AGENTS_DIR"
          echo '{"name":"oplan-3","type":"codex:rescue","pane_id":null,"status":"active"}' > "$AGENTS_DIR/oplan-3.json"
        성공_판정: plan_3.md 생성 확인 (15분 이내)
      2차_fallback (1차 hook 차단 또는 팅김 시):
        Agent(name="oplan-3", team_name="{팀명}", subagent_type="general-purpose", model="sonnet", mode="bypassPermissions", run_in_background=True)
        + spawn 프롬프트에 추가 지시: |-
            이종 AI(Codex) 분석 fallback으로 실행 중. mcp__codex__codex 도구를 직접 호출하여
            구현 렌즈 분석을 수행하고, 그 결과를 통합하여 plan_3.md에 저장하라.
            mcp__codex__codex 호출 실패 시: 구현 렌즈 관점만으로 독립 분석 수행 후 저장.
        fallback_이유: codex:rescue가 파이프라인 활성(PLAN) 상태에서 full_task_team_guard.sh의
                       team_name 요구를 충족하지 못할 경우 대비. 이종 AI 분석 유지 목적.
      3차_fallback (2차도 실패 시):
        해당 렌즈 분석 생략 → opus로 구현 렌즈 재spawn (oplan-3-alt)
    이종_역할: Claude 2인과 다른 모델 아키텍처(GPT) 시각으로 구현 관점 분석
    출력: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/plans/plan_3.md (plan_codex.md 아님 — 구현 렌즈 역할)

지시_공통:
  - 상대방 분석 없이 완전 독립적으로 수행
  - 동일 요구사항을 각자의 렌즈 시각으로 분석
  - 렌즈 외 항목도 빠뜨리지 않되, 렌즈 관점을 우선 심화

팅김_감지_및_복구 (메인 담당):
  감지_방법: spawn 후 15분 내 plan_{N}.md 미생성 시 팅김으로 판정
  감지_보조: agent_oplan{N}_status가 "started" 상태로 10분 이상 경과 시
  복구_액션:
    1. "⚠️ oplan-{N} 팅김 감지 — 경량 모드로 재spawn" 출력
    2. 재spawn 프롬프트: 스킬 로딩 없음 + 파일 읽기 없음 + 요구사항 + context_summary.md만
    3. ultrathink 비활성화
  재시도_최대: 2회 → 2회 후에도 실패 시 해당 렌즈 분석 생략 + 나머지로 계속 진행

  codex_팅김_고아에이전트_처리 (oplan-3 codex:rescue 전용 — P0-C2):
    감지: spawn 후 60초 이내 응답 없음 (plan_3.md 미생성 AND agent_oplan3_status != "started")
    fallback_spawn_직전_필수_절차:
      1. failed 마커 생성:
         mcp__oio__file_write(${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/agents/oplan-3.failed,
           '{"status":"failed","reason":"codex_timeout","ts":"<ISO타임스탬프 — bash_exec로 date -u +%Y-%m-%dT%H:%M:%SZ 조회 후 삽입>"}')
      2. pane_id 조회: grep "^pane_id=" ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/agents/oplan-3 2>/dev/null | cut -d= -f2
         pane 존재 시: kill escalation (SIGTERM → SIGKILL → tmux kill-pane)
      3. 이후 general-purpose sonnet fallback spawn 진행 (기존 2차_fallback 절차)
    목적: 고아 에이전트(응답 없는 codex pane)가 리소스 점유 채로 방치되는 문제 방지

oplan-3_codex_팅김_주의:
  oplan-3는 codex:rescue이므로 일반 Agent와 spawn/완료 프로토콜이 다를 수 있음.
  완료_감지: plan_3.md 파일 생성 여부로 판정 (SendMessage 완료 보고와 병행)
  팅김_복구: 15분 내 plan_3.md 미생성 → opus로 재spawn (구현 렌즈 동일 임무)
```

### 1.5단계: 이종 비판가 2인 동시 검토

> plan_1/2/3.md 완료 후 즉시, 이종 비판가 2인을 **동시에** spawn하여 서로 다른 관점으로 맹점을 발굴.
> critique_A.md(adversarial) + critique_B.md(fable) 2개가 생성되며, merge 없이 이후 debate/vote/oplan-final에 **직접 전달**.
> 비판가 자체의 맹점도 상호 보완되는 구조.

```yaml
트리거: plan_1/2/3.md 모두 완료 후 즉시 (병렬 가능)
실행: 비판가-A + 비판가-B 동시 spawn (기다리지 않음)

비판가-A (codex:adversarial-review) — 이종 AI 공격적 검토:
  spawn (팀에이전트 형식 필수 — P-TEAM):
    Agent(
      name="비판가-A",
      team_name="{팀명}",
      subagent_type="codex:codex-rescue",
      mode="bypassPermissions",
      run_in_background=True,
      prompt="..."
    )
    ⚠ Skill('codex:adversarial-review') 직접 호출 금지 — 팀에이전트로 spawn해야 pane 추적 가능
  역할: "악마의 변호인 — 이종 AI 시각에서 공격적 검토"
  입력: plan_1.md + plan_2.md + plan_3.md
  임무:
    §1. 공통 맹점: 모든 안에서 공통으로 놓친 사각지대 (Claude 집단 편향 포함)
    §2. 안별 치명적 가정: 각 안의 가장 위험한 가정 1개씩 지목
    §3. 모두 놓친 대안: 이종 AI(GPT) 시각에서 Claude가 놓친 접근법
    §4. 상호 모순: 안들끼리 충돌하는 항목 목록화
    §5. adversarial 권장안: 어느 안이 가장 강건한가 + 이유
  출력: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/plans/critique_A.md
  실패_시: critique_A.md 미생성 처리 (5단계 조건부 실행 트리거)

비판가-B (general-purpose fable) — Claude 관점 심층 비판:
  spawn (팀에이전트 형식 필수 — P-TEAM):
    Agent(
      name="비판가-B",
      team_name="{팀명}",
      subagent_type="general-purpose",
      model="fable",
      mode="bypassPermissions",
      run_in_background=True,
      prompt="..."
    )
  역할: "심층 비판가 — Claude 관점에서 논리적 허점 발굴"
  입력: plan_1.md + plan_2.md + plan_3.md
  임무:
    §1. 논리적 허점: 각 안의 추론 과정에서 근거 없는 가정
    §2. 안별 치명적 약점: 각 안이 가장 취약한 지점 1개씩
    §3. 아키텍처/리스크/구현 렌즈 간 충돌: 세 렌즈가 암묵적으로 충돌하는 항목
    §4. 프로젝트 규칙 위반: CLAUDE.md/PROJECT.md 기준 위반 가능 항목
    §5. fable 권장안: 어느 안의 어떤 요소를 우선 채택할지 + 이유
  출력: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/plans/critique_B.md
  실패_시: fable fallback 불필요 (비판가-B 자체가 이미 fable — 재spawn만)

비판가_공통_금지:
  - 긍정적 평가 중심 금지 (비판에 집중)
  - "좋은 계획이지만" 식의 완충 표현 금지
  - 단순 요약 금지
  - critique 상호 참조 금지 (독립 비판 보장)

비판가-A_타임아웃_처리 (P10 — 고아 에이전트 방지):
  감지: 비판가-A(codex:adversarial-review) spawn 후 60초 이내 critique_A.md 미생성
  처리_절차 (oplan-3 codex P0-C2 고아 처리와 동일):
    1. ostatus 확인:
       mcp__oio__bash_exec(command="bash ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/lib/ostatus_check.sh ${UUID} 비판가-A")
    2. 고아 감지 시 강제 종료:
       - pane_id 조회: grep "^pane_id=" ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/agents/비판가-A 2>/dev/null | cut -d= -f2
       - kill escalation: SIGTERM → SIGKILL → tmux kill-pane (status off 상태에서만)
       - failed 마커 생성:
         mcp__oio__file_write(${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/agents/비판가-A.failed,
           '{"status":"failed","reason":"timeout_60s","ts":"<ISO타임스탬프 — bash_exec로 date -u +%Y-%m-%dT%H:%M:%SZ 조회 후 삽입>"}')
    3. fallback — general-purpose 에이전트로 재spawn:
       Agent(
         name: "비판가-A-fallback",
         team_name: "{TEAM_NAME}",
         subagent_type: "general-purpose",
         model: "sonnet",
         mode: "bypassPermissions",
         run_in_background: false,
         prompt: "비판가-A(codex:adversarial-review) fallback으로 실행. plan_1.md + plan_2.md + plan_3.md 읽고 §1~§5 형식으로 adversarial 비판 수행 후 critique_A.md 생성."
       )
    4. critique_A.md 생성 보장: fallback 완료 후 파일 존재 확인 필수

산출물: critique_A.md + critique_B.md (2개 — merge 없이 debate에 직접 전달)
전파: critique_A.md + critique_B.md → debate(2단계) → vote(3단계) → oplan-final(4단계) → 5단계 조건 판정
```

### 2단계: 1차 debate (3인 교차 검토)

```yaml
트리거: plan_1/2/3.md + critique_A.md + critique_B.md 모두 완료 후
병렬_수행: 3개 동시 실행 가능

교차_검토:
  oplan-1: plan_2.md + plan_3.md + critique_A.md + critique_B.md 읽고 → debate_1.md 작성
  oplan-2: plan_1.md + plan_3.md + critique_A.md + critique_B.md 읽고 → debate_2.md 작성
  oplan-3: plan_1.md + plan_2.md + critique_A.md + critique_B.md 읽고 → debate_3.md 작성

debate_작성_지침:
  - 상대 계획의 장점 인정 (선택적 채택 표기)
  - 상대 계획의 위험/누락/오류 지적
  - 자신의 계획 중 수정이 필요한 부분 반영
  - critique_A.md §1(공통 맹점)에 대한 자신의 해결책 명시 필수
  - critique_B.md §1(논리적 허점)에 대한 자신의 입장 명시 필수
  - critique_A.md §4(상호 모순) + critique_B.md §3(렌즈 간 충돌)에서 자신의 입장 명시 필수
  - 두 비판가 의견이 충돌하는 경우: 어느 쪽이 타당한지 자신의 판단 명시
  - 출력: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/plans/debate_{1,2,3}.md
```

### 3단계: 2차 vote (3인 합의)

```yaml
트리거: debate_1/2/3.md 모두 완료 후
병렬_수행: 3개 동시 실행 가능

실행:
  oplan-1: debate_2.md + debate_3.md + critique_A.md + critique_B.md → vote_1.md 작성
  oplan-2: debate_1.md + debate_3.md + critique_A.md + critique_B.md → vote_2.md 작성
  oplan-3: debate_1.md + debate_2.md + critique_A.md + critique_B.md → vote_3.md 작성

vote_작성_지침:
  - 최종 채택/폐기 판정 (항목별)
  - 절대 조건 위반 항목은 투표 없이 폐기
  - 통합 우선순위 결정
  - critique_A.md §3(모두 놓친 대안) 채택 여부 투표
  - critique_B.md §3(렌즈 간 충돌) 해소 방안 투표
  - critique_A.md §5(adversarial 권장안) 동의 여부 표명
  - critique_B.md §5(fable 권장안) 동의 여부 표명
  - 두 비판가 권장안이 충돌할 경우 우선순위 투표
  - 출력: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/plans/vote_{1,2,3}.md
```

### 3.5단계: 배심원 투표 (Jury Vote)

> 3명의 토론자가 합의한 항목별 결정에 대해, 3명의 배심원단이 독립 투표.
> 만장일치(3/3) 통과 필요. 미달 시 토론자에게 반환하여 개선안 재토론.

```yaml
배심원_구성:
  단일_배심원단: 3명 팀에이전트 (sonnet 모델, 병렬 spawn)
  총 투표인원: 3명

배심원_spawn_형식 (팀에이전트 필수 — P-TEAM):
  각 배심원은 반드시 아래 형식으로 spawn:
    Agent(
      name="배심원-1",   # 배심원-1, 배심원-2, 배심원-3 (고정)
      team_name="{팀명}",
      subagent_type="general-purpose",
      model="sonnet",
      mode="bypassPermissions",
      run_in_background=True,
      prompt="..."
    )
  ⚠ 서브에이전트(name/team_name 없이) spawn 절대 금지

투표_절차:
  1. vote_1/2/3.md + critique_A.md + critique_B.md의 항목별 합의안을 각 배심원에게 전달
  2. 각 배심원: 항목별 찬성/반대 투표 (근거 1줄 필수)
  3. 항목별 집계: 3명 전원 찬성 = PASS (만장일치)
  4. 1명이라도 반대 = FAIL

추가_투표_항목:
  - "critique_A.md §1(공통 맹점)이 합의안에서 해소되었는가?"
    FAIL 시: critique_A.md §1을 토론자에게 반환하여 해소 강제
  - "critique_B.md §1(논리적 허점)이 합의안에서 해소되었는가?"
    FAIL 시: critique_B.md §1을 토론자에게 반환하여 해소 강제

PASS_조건 (AND — 모든 항목에서 충족):
  - 3명 전원 찬성 (만장일치)
  - 전 항목 PASS → 4단계(oplan-final) 진입

FAIL_시 (한 항목이라도 만장일치 미달):
  1. 미달 항목 목록 + 반대 근거를 토론자(oplan-1/2/3)에게 반환
  2. 토론자: 개선안 재토론 (2차 debate 형식)
  3. 개선안 도출 후 배심원 재투표
  4. 반복 최대 3회 → 3회 후에도 미달 시 사용자 확인(AskUserQuestion)

투표_결과_저장:
  경로: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/plans/jury_vote_v{N}.json
  형식: {"items": [{"id": "항목명", "votes": {"for": 3, "against": 0}, "pass": true}]}
```

### 4단계: oplan-final (TRUE merge)

```yaml
트리거: 3.5단계 배심원 투표 전 항목 PASS 후 (FAIL 시 토론자 재토론 → 재투표 루프 완료 후)
spawn (팀에이전트 형식 필수 — P-TEAM):
  Agent(
    name="oplan-final",
    team_name="{팀명}",
    subagent_type="general-purpose",
    model="fable",           # fable — 다수 파일 통합 시 1M 컨텍스트 필수
    mode="bypassPermissions",
    run_in_background=False,
    prompt="..."
  )
주의: Skill('oplan') 로딩 금지 — oplan-final은 plan/debate/vote 파일만 읽고 통합 수행

입력:
  o4/o5 공통: plan_1/2/3.md + debate_1/2/3.md + vote_1/2/3.md + critique_A.md + critique_B.md

통합_지침:
  - 한쪽 선택 금지 — 세 계획의 정수를 통합
  - vote 결과 기반 우선순위 반영
  - critique_A.md §1(공통 맹점) 해소 방안 명시
  - critique_B.md §1(논리적 허점) 해소 방안 명시
  - critique_A.md §3(모두 놓친 대안) 채택/폐기 명시 (근거 포함)
  - 두 비판가 권장안(§5) 반영 사항 명시
  - 3렌즈(아키텍처/리스크/구현) 각각 반영 확인
  - 누락된 엣지케이스 보완
  - 표준 oplan 출력 형식 준수

출력: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/plans/oplan_final.md
반환: 메인에 최종 계획서 요약 + 파일 경로
```

### 5단계: Codex 적대적 검증 (조건부)

> oplan-final을 codex:adversarial-review가 최종 공격적 검토.
> **조건부 실행**: 1단계 + 1.5단계에서 Codex가 이미 2회 참여했다면 SKIP (수익 체감 방지).
> Codex 참여 이력이 불완전한 경우에만 실행 — 누락된 이종 시각 보완.

```yaml
실행_판정 (oplan_final.md 완성 직후):
  확인:
    - plan_3.md 존재 여부 (1단계 oplan-3 codex:rescue 성공 여부)
    - critique_A.md 존재 여부 (1.5단계 codex:adversarial-review 성공 여부)

  SKIP_조건 (AND 모두 충족 시):
    - plan_3.md 존재 (codex:rescue가 구현 렌즈 분석 완료)
    - critique_A.md 존재 (adversarial-review가 비판 완료)
    → "✅ Codex 2회 참여 확인 (1단계 구현 분석 + 1.5단계 adversarial 비판) — 5단계 SKIP" 출력

  실행_조건 (OR — 하나라도 해당 시):
    - plan_3.md 미존재 (1단계 codex:rescue 팅김/실패)
    - critique_A.md 미존재 (1.5단계 adversarial-review 실패)
    → 아래 절차 실행

절차 (실행_조건 해당 시):
  1. Codex 적대적 비판 요청:
     방법_1차: Skill('codex:adversarial-review') 호출
       초점: 계획서의 기술적 허점, 누락 엣지케이스, 실행 불가 항목, 위험 요소
       대상: oplan_final.md
       지시: |-
         이전 비판가(critique_A.md, critique_B.md)가 지적한 항목의 oplan-final 반영 충실도를 검증하라.
         그 다음, critique_A/B.md에서 지적하지 못한 새로운 약점을 추가 발굴하라.
       전달 파일: oplan_final.md + critique_A.md + critique_B.md
     방법_2차 (1차 실패 시): Agent(name="oplan-5-codex", team_name="{팀명}", subagent_type="codex:codex-rescue", mode="bypassPermissions") spawn  # name+team_name 필수 (F8: unnamed Agent 차단 대응)
     방법_3차 (2차도 실패 시): mcp__codex__codex 도구 직접 호출
     방법_4차 (전부 실패 시): 이 단계 스킵, "⚠️ Codex 적대적 검증 불가 — 생략" 출력
  2. Codex 비판 보고서 수신
     저장: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/plans/codex_critique.md
  3. Claude(메인) 수용/반박 결정
     수용: oplan_final.md 해당 항목 업데이트
     반박: 근거 명시 후 유지
     결과: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/plans/codex_response.md
  4. 재수정 루프 (수용 항목이 있는 경우):
     oplan_final.md 업데이트 후 Codex에 재검증 요청
     최대 3회 루프 — 초과 시 현재 최선안으로 확정
     루프 카운터: codex_critique_v{N}.md (N = 1~3)
  5. 최종 확정: oplan_final.md (Codex 검증 반영 최종본)

루프_제한: 최대 3회. 초과 시 "Codex 적대적 검증 3회 완료 — 현재 최선안으로 확정" 출력 후 종료.
```

### 6단계: 검수조건 산출물 (acceptance_criteria.json)

> otest Phase 2에서 구현 검증 기준으로 사용.
> oplan_debate는 5단계 완료 후(결과를 읽지 않는 독립 단계) acceptance_criteria.json을 반드시 생성해야 한다.
> 주의: oplan_normal/oplan_deep의 Skill() 호출은 재귀 로딩 금지 규칙(위 "스킬_재귀_금지" 참조)에 위배되므로,
> 아래 절차는 oplan_debate 안에서 직접 수행한다 (Skill() 참조로 대체 불가).

```yaml
생성_시점: oplan_final.md 확정 후, 산출물 저장 전
저장: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/plans/acceptance_criteria.json
형식: {"criteria": [{"id":"AC-001", "category":"backend|frontend|db|api", "description":"...", "method":"...", "expected":"...", "priority":"must|should|nice"}]}

★비-CRUD 작업(hook/스크립트/인프라 수정 등 REST API·DB CRUD가 구조적으로 없는 작업) 필수 규칙★
(L-465 재발방지 — F-CRUD-1 게이트가 tier=O3~O5에서 파일 부재를 무조건 차단하므로,
CRUD 항목이 0건이어도 acceptance_criteria.json 파일 자체는 반드시 생성한다. 스킵 금지):
  최상위_필드_스키마: {"crud_대상": true|false, "crud_미해당_사유": "...", "작업유형": "...", "criteria": [...]}
    - crud_대상: 이 작업에 저장/등록/수정/삭제를 요구하는 검수 항목이 있는가 (false = 비-CRUD)
    - crud_미해당_사유: crud_대상=false일 때 필수. 빈 문자열이면 게이트가 면제를 거부한다(fail-closed)
    - 작업유형: 예) "hook_infra", "script", "config" 등 자유 서술
  비-CRUD_검수_항목_작성_지침 (method/verify/then/expected 중 하나에 아래 어휘 포함 — verify_crud_executed.py의
  INSPECTION_HINTS 상수와 동일 어휘. 저장을 요구하는 동사(저장/등록/입력/생성/삽입/반영/커밋 등)가 섞이면
  CRUD로 간주되어 면제가 무효화되므로 절대 섞지 말 것):
    사용_가능_어휘: grep / git diff / diff / 코드상 / 코드 상 / 소스 / 정적 / 존재하지 않는다 / 없음 /
                    무변경 / 변경되지 않 / 빌드 로그 / 로그에 / 판정 근거 / 스크린샷 / 커버리지 / 표기 / 구분 표
    예시_criterion: "hook 스크립트가 bash -n 문법 검증을 통과하고 CRLF가 혼입되지 않는다"
    예시_method: "bash -n 으로 문법 확인 후 grep 으로 CR 문자 없음을 코드상 확인"

★item_crud 필드 필수화 (criteria[] 원소마다 — 상류 처방)★:
  배경: F-CRUD-1 게이트가 기존에는 AC 본문의 자연어(동사/부정어 패턴)로 CRUD 여부를 판정하다가
        3회 연속 오판(부정어로 회피 통과 / 검증형 문구를 CRUD로 오탐)했다. 이제 게이트는
        criteria[] 원소마다 명시된 item_crud 값을 1순위 판정 근거로 그대로 따른다.
  정의: criteria[] 원소(각 AC 항목)마다 "item_crud" (boolean) 필드를 필수 기재한다.
    - item_crud: true  — 이 항목은 실제 데이터 생성/수정/삭제/조회를 요구한다 (CRUD 실행 증거 필요).
    - item_crud: false — 이 항목은 코드/문서/설정 검증만 요구한다 (CRUD 증거 불필요).
  판정_기준: "이 항목을 충족하려면 실제로 데이터가 저장·변경·삭제되어야 하는가?"
    → YES면 true. 코드를 읽거나 파일을 비교하는 것으로 끝나면 false.
  ⚠️ item_crud는 일반적으로 판정을 결정하므로 작성자는 이 필드를 정확히 기재해야 한다: 게이트는
     item_crud 값을 그대로 따르므로, item_crud를 실제 사실과 다르게(회피 목적으로 false, 또는
     부주의로 누락) 기재하지 않는 것이 작성자(oplan)의 책임이다.
     단, crud_대상=false 파일 레벨 선언의 타당성 검증에서는 AC 본문과 실제 변경 파일이 함께
     대조되며, 선언이 실제와 모순되면 item_crud 값과 무관하게 차단된다. 즉 "필드만 맞추면
     무엇을 쓰든 된다"는 뜻이 아니다.

crud_대상_과_item_crud_관계 (파일_레벨_vs_항목_레벨 — 혼동 금지):
  - crud_대상: acceptance_criteria.json **전체**가 비-CRUD 작업인지 판정하는 파일 레벨 필드.
  - item_crud: **개별 AC 항목**이 CRUD 실행 증거를 요구하는지 판정하는 항목 레벨 필드.
  - crud_대상=false인 파일도 criteria[] 원소마다 item_crud(보통 전부 false)를 반드시 기재해야 한다.

  완성된_JSON_예시 (CRUD 항목 true + 검증형 항목 false 대비 포함 — 그대로 필드 구조를 복붙하여 값만 교체):
    {"crud_대상": true, "crud_미해당_사유": "", "작업유형": "backend_api",
     "criteria": [
       {"id":"AC-001", "item_crud":true, "category":"backend", "description":"사용자 저장 API가 DB에 실제 반영된다",
        "method":"POST /api/users 호출 후 DB COUNT 전후 비교 및 write_log 확인",
        "expected":"count_after = count_before + 1", "priority":"must"},
       {"id":"AC-002", "item_crud":false, "category":"infra", "description":"기존 저장 로직 코드가 변경되지 않았다",
        "method":"git diff 로 save 함수 무변경을 코드상 확인",
        "expected":"diff 없음", "priority":"must"}
     ]}
    비-CRUD 전용 파일 예시:
    {"crud_대상": false, "crud_미해당_사유": "hook 셸 스크립트 수정 작업으로 REST API·DB 변경이 없다",
     "작업유형": "hook_infra",
     "criteria": [{"id":"AC-001", "item_crud":false, "category":"infra", "description":"hook 문법 무결성",
                    "method":"bash -n 으로 문법 검증, grep 으로 CRLF 혼입 여부 코드상 확인",
                    "expected":"문법 오류 없음, CR_COUNT=0", "priority":"must"}]}

immutable_잠금:
  - oplan 생성 후 acceptance_criteria.json은 수정 금지
  - odev/otest 에이전트가 criteria를 조작하는 것을 원천 차단
  - 보호 방법: oio intent lock
```

## 산출물 경로

```yaml
중간_파일: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/plans/
  - plan_1.md, plan_2.md, plan_3.md   # 1단계: 독립 분석 (아키텍처/리스크/구현 렌즈)
  - critique_A.md                      # 1.5단계: codex:adversarial-review 비판
  - critique_B.md                      # 1.5단계: general-purpose fable 비판
  - debate_1.md, debate_2.md, debate_3.md  # 2단계: 3인 교차 검토
  - vote_1.md, vote_2.md, vote_3.md    # 3단계: 3인 합의
  - jury_vote_v{N}.json                # 3.5단계: 배심원 투표 결과
  - codex_critique.md                  # 5단계: Codex 비판 보고서 (조건부 — plan_3.md 또는 critique_A.md 실패 시만)
  - codex_response.md                  # 5단계: Claude 수용/반박 결정 (조건부)
  - acceptance_criteria.json           # 6단계: 검수조건 산출물 (o4/o5 필수 — ★물리 강제됨★)
최종_파일: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/plans/oplan_final.md
```

## 원칙

```yaml
독립성: 각 에이전트는 상대 분석 결과를 받기 전까지 완전 독립 수행
렌즈_분리: oplan-1(아키텍처) / oplan-2(리스크) / oplan-3(구현) — 관점 다양성 보장
비판가_시점: 1단계 완료 직후 (계획 초기에 맹점 발견 → debate에 이미 반영)
critique_전파: critique.md는 debate → vote → oplan-final → Codex 검증까지 전달
합의: 한쪽 선택이 아닌 진정한 통합 (TRUE merge)
폐기_조건: 절대 조건 위반 항목은 투표 없이 폐기
역할_경계: oplan-final은 계획 수립만 — odev spawn은 메인 역할
모델:
  oplan-1 (아키텍처): fable
  oplan-2 (리스크): fable
  oplan-3 (구현): codex:rescue (이종 AI — Claude 집단 편향 원천 차단)
  비판가-A: codex:adversarial-review (이종 AI 공격적 검토)
  비판가-B: general-purpose fable
  배심원: sonnet 3명 만장일치 (품질 우선)
  oplan-final: fable (다수 파일 통합 — 1M 컨텍스트 필수)
분석가_수: 3명 (oplan-1/2/3 — o4/o5 공통, 이종 구성)
제한: 토론 최대 2라운드 (debate + vote), 배심원 재투표 최대 3회, Codex 검증 루프 최대 3회

컨텍스트_절약_원칙 (서브에이전트 팅김 방지 — 핵심):
  경량_우선: 서브에이전트는 경량으로, 지능은 메인이 보유한다
  스킬_재귀_금지: oplan-1/2/3/final은 Skill() 호출 일절 금지 (스킬 재귀 로딩 = 팅김 원인)
  oinfra_금지: oplan-1/2/3은 Skill('oinfra_*') 호출 금지 (연쇄 로딩 방지)
  사전탐색_의무: 메인이 0단계에서 context_summary.md 생성 후 spawn — 서브에이전트 파일 읽기 최소화
  ultrathink_조건부: 프롬프트 < 1,000 토큰 + 추가 파일 < 2개인 경우에만 사용
  팅김_복구: 15분 타임아웃 + 경량 재spawn(최대 2회) + 실패 시 해당 렌즈 생략 후 계속
```

---

## 토론 프로토콜 (oplan에서 이관)

### 1차 분석 절차

```yaml
1차_분석:
  - 독립적으로 계획 수립 후 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/plans/plan_{N}.md 저장
  - 자신의 렌즈(아키텍처/리스크/구현)를 우선 심화하되 다른 관점도 포함
  - 메인에 완료 보고 (SendMessage)
```

### 2차 debate 절차

```yaml
2차_debate (메인이 상대 계획서 2개 + critique_A.md + critique_B.md 경로 전달 후):
  - 상대 계획서 2개 + critique_A.md + critique_B.md 완전히 읽기
  - §1(상대 요약) §2(동의) §3(반대+근거+대안) §4(자기 수정) §5(합의안 초안)
  - critique_A.md §1(공통 맹점) 해결책 명시 필수
  - critique_B.md §1(논리적 허점) 자신의 입장 명시 필수
  - critique_A.md §4(상호 모순) + critique_B.md §3(렌즈 간 충돌) 자신의 입장 명시 필수
  - 두 비판가 의견이 충돌하는 경우: 어느 쪽이 타당한지 자신의 판단 명시
  - ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/plans/debate_{N}.md 저장
  - 반대 시 반드시 근거와 대안 제시 (단순 반대 금지)
```

### 3차 vote 절차

```yaml
3차_vote (메인이 상대 debate 2개 + critique_A.md + critique_B.md 전달 후):
  - 항목별 찬반 투표 테이블 (항목|찬/반|근거|대안)
  - critique_A.md §3(모두 놓친 대안) 채택 여부 명시
  - critique_B.md §3(렌즈 간 충돌) 해소 방안 투표
  - critique_A.md §5(adversarial 권장안) 동의/반대 표명
  - critique_B.md §5(fable 권장안) 동의/반대 표명
  - 두 비판가 권장안 충돌 시 우선순위 투표
  - 최종 통합안 (전원 발견 사항 merge)
  - ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/plans/vote_{N}.md 저장
```

### 절대 금지 / 원칙

```yaml
절대_금지:
  - /tmp/ 루트에 파일 생성 — 반드시 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/plans/ 사용
  - 계획 수립 외 행동 (odev spawn, 파일 수정 등)

원칙:
  - 합의 = 전원 최적 조합 (한쪽 전면 채택 금지)
  - 반대 시 대안 필수
  - 상대 발견 중 놓친 항목 명시 인정
  - critique_A.md + critique_B.md는 읽기 전용 참조 — 비판가에게 재질문 금지
```
