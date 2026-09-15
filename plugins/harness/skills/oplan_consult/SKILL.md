---
name: oplan_consult
description: "Claude × Codex 이종 AI 병렬 계획 수립. opus + codex:rescue 2명 동시 독립 계획 → Claude oplan_deep(ultrathink) 통합. codex:rescue 실패 시 sonnet 대체. o5 기본/o4 조건부 실행. 수동 호출: '/oplan_consult'."
invocation:
  user_callable: true
  pipeline_callable: true
  called_by: ["ok_pipeline(o4 자율선택/o5 자율선택)"]
  calls: ["codex:codex-rescue", "oplan_deep"]
---
# oplan_consult — Claude × Codex 이종 AI 병렬 계획 수립

> opus과 Codex(codex:rescue)가 동시에 독립 계획서를 생성하고,
> Claude가 oplan_deep(ultrathink)으로 두 계획을 참조하여 최종 통합 계획을 도출한다.
> Claude가 최종 통합자.

## ogrill 5축 결손 판정 (oplan 내부 절차 — 절대 규칙)

> oplan_consult 팀에이전트는 Phase A(의도 분석) 진입 직전 5축(목표/범위/제약/완료기준/열린질문) 결손 카운트를 수행한다.
> 메인 에이전트는 이 판정을 수행하지 않는다 (CLAUDE.md "ogrill 호출 정책" 참조).
> 상세 절차: oplan/SKILL.md "ogrill 5축 결손 판정" 섹션 참조 (단일 출처).

## 트리거 조건

```yaml
자동_트리거 (ok_pipeline이 oplan_debate 대신 또는 추가로 선택):
  o5 기본: oplan_debate 대신 oplan_consult 선택 시 (아래 선택 기준 해당 시)
  o4 조건부: DEBATE_ROUTING 해당 AND 다음 중 하나:
    - 복잡한 알고리즘/아키텍처 결정이 필요한 경우
    - 다양한 관점이 필요한 경우 (트레이드오프, 기술 선택)
    - 설계 방향이 불명확하거나 여러 접근 가능한 경우
  Codex_폴백: Codex 사용 불가 시 oplan_debate로 자동 전환 (oplan_consult 취소)
수동_트리거: 사용자가 '/oplan_consult' 직접 호출
```

## Fallback

```yaml
codex_rescue_실패_시:
  대체: Agent(subagent_type="general-purpose", name="계획가-2-fallback", team_name="{팀명}", model="claude-sonnet-4-5", mode="bypassPermissions") spawn
  역할: 동일 — 독립 계획서 작성 (plan_codex.md)
  알림: "⚠️ codex:rescue 사용 불가 — sonnet으로 대체"
```

## 전체 흐름

```
[Phase 1 병렬 동시 실행]
  opus (Agent, plan_claude.md) ──────┐
                                           ├→ [Phase 2] Claude oplan_deep(ultrathink) merge → 최종안
  codex:rescue (plan_codex.md) ───────────┘
  (codex:rescue 실패 시 sonnet 대체)
```

> **우호적 협업**: 두 에이전트가 각자 최선의 계획을 독립 제시.
> Claude(oplan_deep)가 양쪽 장점을 참조하여 최종 통합.

---

## Step 0: TeamCreate (서브에이전트 spawn 전 필수)

```yaml
TeamCreate_필수 (Step 1 진입 전 최우선):
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
  목적: 서브에이전트 spawn 전 팀 컨텍스트 확보 필수
  주의: 이미 ok에서 TeamCreate한 경우 team_name 파일이 존재 → 스킵
  금지: 팀에이전트 컨텍스트에서 TeamDelete 절대 금지 (팀에이전트는 메인의 팀 구성을 알 수 없음)
```

## Step 1: 2명 병렬 계획가 동시 실행

두 에이전트를 **동시에** spawn한다 (순서 없음, 상호 영향 없음).

> **goal.json 양쪽 주입 (soft hint — 2차수 통합)**
> 계획가-1(opus)과 계획가-2(codex:rescue/sonnet) spawn 프롬프트 `<context>` 블록에
> goal.json 요약을 동일하게 주입하라.
>
> ```yaml
> 적용: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/goal.json 존재 시에만
> 주입_내용: goal.intent / goal.scope_in / goal.acceptance (3필드 요약, 5줄 이내)
> 위치: 각 계획가 spawn 프롬프트의 <context> 블록 첫 항목
> 부재_시: 주입 스킵, 기존 컨텍스트만으로 진행 (오류 아님)
> 목적: 양 계획가가 동일 계약 기준(acceptance)을 참조하여 계획 품질 향상
> ```

⚠️ 컨텍스트_절약_필수 (서브에이전트 팅김 방지 — oplan_debate 표준 규칙 동일 적용):
  스킬_로딩_금지:
    - Skill('oplan') 호출 절대 금지 (SKILL.md 440줄 로딩 → 컨텍스트 폭발 원인)
    - Skill('oplan_consult') 호출 절대 금지 (재귀 로딩)
    - Skill('oinfra_*') 호출 절대 금지 (PROJECT.md + 참조 파일 연쇄 로딩)
    - 프로젝트 인프라 정보는 spawn 프롬프트의 context 블록에서만 참조
  파일_읽기_제한:
    - spawn 프롬프트 이외 추가 파일 읽기: 최대 2개, 각 50줄 이내
    - 대용량 파일(100줄+) 전체 읽기 금지 — Grep으로 핵심 섹션만
  ultrathink_조건 (ok_model 표준 규칙 참조):
    - spawn 프롬프트 < 1,000 토큰 AND 추가 파일 읽기 < 2개인 경우에만 ultrathink 사용
    - 위 조건 미충족 시: ultrathink 생략, 일반 thinking으로 수행
    - 적용 대상: 계획가-1(opus), Step 2 oplan_deep 통합 단계(opus)


> ⚠️ **팀에이전트 spawn 절대 규칙 (P-TEAM — 재발방지 L-373)**:
> oplan_consult의 모든 계획가(계획가-1, 계획가-2)는 **반드시 팀에이전트로 spawn**해야 한다.
> 서브에이전트(name/team_name 없는 Agent 호출)는 full_task_team_guard가 차단한다.
>
> **name 네이밍 규칙 (고정)**:
> - 계획가-1 (opus 독립 계획)
> - 계획가-2 (codex:rescue 또는 sonnet fallback 독립 계획)
>
> **필수 파라미터**: name, team_name, subagent_type, model, mode="bypassPermissions", run_in_background, prompt
>
> **team_name 조회**: `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/team_name` 파일에서 읽기 (Step 0에서 저장됨)

### 계획가 1: opus

```yaml
실행 (팀에이전트 형식 필수 — P-TEAM):
  Agent:
    name: "계획가-1"
    team_name: "{팀명}"
    subagent_type: "general-purpose"
    model: "claude-opus-4-5"  # opus
    mode: "bypassPermissions"
    run_in_background: true
    prompt: |
      당신은 독립 계획가입니다. 아래 요구사항에 대한 기술 설계/구현 계획서를 작성하라.
      다른 AI(Codex)와 동시에 병렬로 계획을 수립 중이며, 나중에 두 계획을 통합한다.
      당신의 역할은 경쟁이 아닌, 독립적인 시각으로 최선의 계획을 제시하는 것이다.

      <task>
      {사용자 요구사항 원문}
      </task>

      <context>
      - 프로젝트: {PROJECT.md에서 추출한 핵심 정보}
      - 기술 스택: {프로젝트 기술 스택}
      - 현재 아키텍처: {관련 파일/모듈 구조 요약}
      </context>

      <constraints>
      - Codex와 다른 관점, 방법론, 우선순위를 가져도 좋다 (다름을 환영)
      - 특히 당신의 강점 영역에 집중하라:
        1. 프로젝트 맥락 및 기존 아키텍처 이해
        2. 한국어 규칙 및 프로젝트 규칙(CLAUDE.md) 준수
        3. 대안 탐색 및 트레이드오프 분석
      </constraints>

      <output_format>
      한국어로 작성. 다음 구조를 따르라:

      ## 1. 요구사항 분석
      - 핵심 목표, 성공 기준, 제약 조건

      ## 2. 아키텍처 설계
      - 접근 방법, 컴포넌트 구조, 데이터 흐름

      ## 3. 대안 분석
      - 대안 A vs B, 각각 장단점, 권장안 + 근거

      ## 4. 구현 계획
      - 수정 대상 파일 목록 (정확한 경로)
      - 파일별 변경 내용 요약
      - 의존 관계 및 실행 순서

      ## 5. 위험 요소
      - 기술적 위험, 엣지케이스, 완화 방안

      ## 6. 검증 방법
      - 테스트 시나리오, 성공 판정 기준
      </output_format>

      완료 후 결과를 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/plans/plan_claude.md 에 저장하라.

      완료 시: plan_claude.md 저장 후 반드시 메인에 SendMessage로 완료 보고 발송.
      SendMessage(to="team-lead", message="claude 계획 완료: plan_claude.md 저장됨", summary="claude 계획 완료")

출력_파일: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/plans/plan_claude.md
```

### 계획가 2: codex:rescue (실패 시 sonnet 대체)

```yaml
1차_시도 (팀에이전트 형식 필수 — P-TEAM):
  실행:
    Agent:
      name: "계획가-2"
      team_name: "{팀명}"
      subagent_type: "codex:codex-rescue"
      mode: "bypassPermissions"
      run_in_background: true
      prompt: |
        {CODEX_PLAN_PROMPT}  # 아래 프롬프트 템플릿 참조

  실패_판정: Agent spawn 실패 | Codex CLI 미설치 | 인증 실패 | 응답 없음(120초)
  실패_시: 2차 sonnet으로 전환

2차_sonnet_대체 (1차 실패 시 — 팀에이전트 형식 유지):
  실행:
    Agent:
      name: "계획가-2"
      team_name: "{팀명}"
      subagent_type: "general-purpose"
      model: "claude-sonnet-4-5"
      mode: "bypassPermissions"
      run_in_background: true
      prompt: |
        당신은 독립 계획가입니다. Codex 관점을 모사하여 아래 요구사항에 대한
        기술 설계/구현 계획서를 작성하라.

        <task>
        {사용자 요구사항 원문}
        </task>

        <context>
        - 프로젝트: {PROJECT.md에서 추출한 핵심 정보}
        - 기술 스택: {프로젝트 기술 스택}
        - 현재 아키텍처: {관련 파일/모듈 구조 요약}
        </context>

        <constraints>
        - 다른 AI(opus)와 다른 관점으로 분석하라
        - 특히 다음에 집중하라:
          1. 코드 품질 및 최신 패턴
          2. 엣지케이스와 실패 시나리오
          3. 성능/보안/확장성
          4. opus가 놓칠 수 있는 구현 세부사항
        </constraints>

        {CODEX_PLAN_PROMPT output_format 동일 적용}

        완료 후 결과를 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/plans/plan_codex.md 에 저장하라.

  알림: "⚠️ codex:rescue 사용 불가 — sonnet으로 대체"

출력_파일: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/plans/plan_codex.md
```

### CODEX_PLAN_PROMPT 템플릿

```yaml
프롬프트_조립_규칙:
  - gpt-5-4-prompting 스킬의 XML 블록 구조 활용
  - <task>, <context>, <constraints>, <output_format> 블록 필수
  - 프로젝트 컨텍스트 (PROJECT.md 핵심 발췌) 포함
  - 파일 수정 허용 (--write): 계획서 MD 파일 생성 가능
```

```
당신(Codex/GPT-5.4)은 Claude(opus)와 병렬로 동시에 이 요구사항을 분석하고 있다.
Claude는 별도로 자체 계획을 세우고 있으며, 나중에 두 계획을 합친다.
당신의 역할은 경쟁이 아닌, 독립적인 시각으로 최선의 계획을 제시하는 것이다.

<task>
{사용자 요구사항 원문}
</task>

<context>
- 프로젝트: {PROJECT.md에서 추출한 핵심 정보}
- 기술 스택: {프로젝트 기술 스택}
- 현재 아키텍처: {관련 파일/모듈 구조 요약}
</context>

<constraints>
- Claude와 다른 관점, 방법론, 우선순위를 가져도 좋다 (다름을 환영)
- 비판 없음 — 당신의 최선을 보여라
- 특히 당신의 강점 영역에 집중하라:
  1. 코드 품질 및 최신 패턴
  2. 엣지케이스와 실패 시나리오
  3. 성능/보안/확장성
  4. Claude가 놓칠 수 있는 외부 시각
</constraints>

<output_format>
한국어로 작성. 다음 구조를 따르라:

## 1. 요구사항 분석
- 핵심 목표, 성공 기준, 제약 조건

## 2. 아키텍처 설계
- 접근 방법, 컴포넌트 구조, 데이터 흐름

## 3. 대안 분석
- 대안 A vs B (+ 추가), 각각 장단점, 권장안 + 근거

## 4. 구현 계획
- 수정 대상 파일 목록 (정확한 경로)
- 파일별 변경 내용 요약
- 의존 관계 및 실행 순서

## 5. 위험 요소
- 기술적 위험, 엣지케이스, 완화 방안

## 6. 검증 방법
- 테스트 시나리오, 성공 판정 기준
</output_format>

완료 후 결과를 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/plans/plan_codex.md 에 저장하라.
```

## Step 2: 두 계획 수집 후 Claude oplan_deep (ultrathink) 통합

두 에이전트(opus, codex:rescue 또는 sonnet) 완료 대기 후 진행.

```yaml
완료_감지 (P11 — 이중 감지):
  방법_1 (SendMessage 수신): opus 에이전트로부터 "claude 계획 완료: plan_claude.md 저장됨" 메시지 수신
  방법_2 (파일 폴링 — 타임아웃 안전망):
    최대_대기: 5분 (300초)
    폴링_간격: 30초
    확인_파일: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/plans/plan_claude.md
    절차: |-
      for i in $(seq 1 10); do
        sleep 30
        [ -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/plans/plan_claude.md" ] && \
          echo "✅ plan_claude.md 생성 확인 (${i}회차)" && break
        echo "⏳ plan_claude.md 대기 중... (${i}/10)"
      done
  두_조건_중_먼저_충족하는_것으로_완료_판정
  타임아웃_시: "⚠️ opus 에이전트 완료 보고 없음 — plan_claude.md 미생성. 재spawn 1회 시도." 출력
```

```yaml
실행: Skill('oplan_deep')
ultrathink: 조건부 — spawn 프롬프트 < 1,000 토큰 AND 추가 파일 읽기 < 2개 충족 시에만 "ultrathink" 포함 (ok_model 표준). 조건 미충족 시 일반 thinking.

프롬프트_추가: |
  ## 독립 계획가 1 (opus) 분석 결과 (참조용)

  아래는 동일 요구사항에 대해 opus이 독립적으로 분석한 계획서이다.
  이 계획서를 참조하되, 당신의 분석을 우선하라.

  ### 활용 지침:
  - opus가 발견한 위험/엣지케이스 중 당신이 놓친 것이 있으면 반영
  - opus의 대안 접근법 중 가치있는 아이디어가 있으면 검토
  - 충돌 시 → 프로젝트 규칙(CLAUDE.md/PROJECT.md) 기준으로 판정

  ---
  {plan_claude.md 전문}
  ---

  ## 독립 계획가 2 (Codex/sonnet) 분석 결과 (참조용)

  아래는 동일 요구사항에 대해 Codex(또는 sonnet 대체)가 독립적으로 분석한 계획서이다.

  ### 활용 지침:
  - Codex가 발견한 위험/엣지케이스 중 당신이 놓친 것이 있으면 반영
  - Codex의 대안 접근법 중 가치있는 아이디어가 있으면 검토
  - Codex 계획을 그대로 채택하지 말 것 — 반드시 자체 판단 경유
  - 충돌 시 → 프로젝트 규칙(CLAUDE.md/PROJECT.md) 기준으로 판정

  ---
  {plan_codex.md 전문}
  ---

통합_원칙:
  공통점: 두 계획 모두 제시한 항목 → 확정 채택 (신뢰도 높음)
  독창적_인사이트: 한 쪽에만 있는 아이디어 → 검토 후 선택적 채택
  충돌: 프로젝트 규칙(CLAUDE.md/PROJECT.md) 기준 판정
  강점_상호보완:
    - opus 강점: 프로젝트 맥락, 한국어 규칙, 기존 아키텍처 이해
    - Codex 강점: 코드 패턴, 최신 라이브러리, 엣지케이스, 외부 시각
  최종_통합자: Claude (oplan_deep, ultrathink)
  최종_출력: 표준 oplan 출력 형식 준수
```

## 산출물

```yaml
중간_파일: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/plans/
  - plan_claude.md    # Step 1: opus 독립 계획
  - plan_codex.md     # Step 1: codex:rescue(또는 sonnet 대체) 독립 계획
최종_파일: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/plans/oplan_consult_final.md
  # = oplan_deep 최종 출력 (양쪽 계획 참조 + 통합)
```

## 출력 형식

표준 oplan 출력 형식 준수 (oplan SKILL.md "출력물 규격" 참조):
- tier, 에이전트 수, 파일 할당 매트릭스, 수정 파일 목록, 단위작업 목록
- 추가 섹션:
  - "계획가 참조 사항": 두 독립 계획에서 채택/변형한 아이디어 명시

## 원칙

```yaml
모드: 병렬 단일 모드 (순차 모드 없음)

계획가_구성:
  1번: opus Agent (general-purpose, model=claude-opus-4-5)
  2번: codex:rescue Agent → 실패 시 sonnet(claude-sonnet-4-5) 대체

ultrathink: Claude(oplan_deep) 프롬프트에 조건부 포함 — ok_model 표준 조건(<1,000토큰 AND <2파일) 충족 시에만 활성화

우호적_협업:
  성격: 두 에이전트가 각자 최선의 계획을 독립 제시
  원칙: Claude가 양쪽 장점을 참조하여 합침. 경쟁이 아닌 상호 보완

최종_통합자: Claude (oplan_deep, ultrathink — 프로젝트 규칙/맥락 이해 우위)
비판가: 없음
배심원: 없음

Fallback:
  codex:rescue 실패 → sonnet 대체 (단일 단계)
  양쪽_에이전트_모두_실패: "⚠️ 모든 계획가 실패 — oplan_deep 단독 실행" 후 Skill('oplan_deep')

프롬프트_품질: gpt-5-4-prompting 스킬 활용하여 Codex 프롬프트 최적화
파일_생성: 계획가들은 plan_*.md 생성 가능
제한: 각 계획가 호출 1회 (실패 시 대체, 재시도 없음)
```
