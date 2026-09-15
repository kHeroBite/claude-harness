---
name: oi
description: "oi 파이프라인 활성 중 입력 라우터 — IDLE/슬래시명령 제외 모든 활성 상태에서 호출 (TEST/DONE/FINISH는 C질문만 즉시처리). 수정/명령은 팀에이전트 위임, 질문은 Q&A 에이전트 spawn. state 변경 없음."
invocation:
  user_callable: false
  pipeline_callable: false
  called_by: [UserPromptSubmit.sh → 메인에이전트 (PLAN/DEV 상태 한정)]
  calls: []
---

# oi — 파이프라인 활성 중 입력 라우터

> **IDLE 및 슬래시 명령 제외, 모든 파이프라인 상태에서 호출.**
> 팀에이전트(PIPELINE_UUID 존재)는 oi 미경유.

## 핵심 원칙

1. **상태별 호출 방식 차이** — IDLE·슬래시 명령은 oi 바이패스; 상태별 동작:
   - `PLAN/DEV`: `💬 [oi] 활성` → oi **완전 활성** (팀에이전트 위임)
   - `TEST/DONE`: 큐잉 **AND** oi 호출 (하이브리드 — 질문만 즉시처리)
   - `FINISH`: 큐잉만 (`📋 [큐잉]`) → oi **미호출**
   - Phase B: stage에서 OK 제거됨 — 기존 OK 진입 시점은 state=PLAN + classification=OK로 통합
2. **질문이면 모든 단계에서 즉시 답변** — 파이프라인 상태 무관
3. **작업은 상태에 따라**: PLAN/DEV → 팀에이전트 즉시 위임, TEST/DONE/FINISH → 큐잉
4. **state를 변경하지 않는다**
5. **항상 팀에이전트로 spawn** — 메인은 1문장 이내 즉시 답변만 직접 처리. 그 이상은 모두 팀에이전트(oi-qa/oi-worker)로 spawn. 팀 없을 때도 TeamCreate 후 spawn (직접 처리 폴백 금지).
6. **ok 흐름 정식 스킬은 oi 경유 면제** (Phase A 보강 — 2026-05-06):
   - **면제 대상**: `ok_pipeline`, `ofinish`, `oinit` (그 외 ok가 직접 호출하는 정식 흐름 스킬 포함)
   - **사유**: 이들은 ok 흐름의 정식 단계로, 메인이 PLAN/DEV/TEST/DONE 상태에서 직접 호출해도 oi 라우팅이 부적절
     - `ok_pipeline`: oplan 완료 후 odev/otest/odone 오케스트레이션 (정식 단계)
     - `ofinish`: 파이프라인 마무리 (정식 단계)
     - `oinit`: 정리 (ofinish 내부 호출)
   - **물리 차단**: `oi_route_guard.sh`의 화이트리스트에 위 스킬들이 등록됨 → oi 미경유 호출 시에도 통과
   - **본 oi 스킬의 책임**: 이들 스킬을 사용자 입력으로 받지 않음 (사용자 입력은 케이스 A/B/C로 분류, ok 흐름 자동 호출은 별도)

## 트리거 조건

- UserPromptSubmit hook이 IDLE/슬래시 명령 제외 모든 상태에서:
  - `💬 [oi] 활성({STATE}) — Skill('oi') 호출 필수`
- IDLE 상태: oi 바이패스 (메인이 직접 처리)
- 슬래시 명령(/ok, /o1~o5, /ox 등): hook이 oi 바이패스 처리
- PIPELINE_UUID 존재(팀에이전트): oi 미경유

## Step 0: UUID + 팀명 확인 (필수 선행 단계)

UUID는 hook 메시지(`💬 [oi] 활성(PLAN|DEV)`)에서 확인.
`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/team_name` 파일로 팀명 확인. 없으면 PLAN 진행 중.

## Step 0.5: oi_routed 마커 생성 (oi_route_guard 통과 허가 — 필수)

oi 스킬이 실행되었음을 oi_route_guard.sh에 알리는 마커 파일을 **Step 0 직후, Step 1 이전에** 반드시 생성한다.
oi_route_guard.sh는 이 마커의 타임스탬프(초)를 확인하여 10초 TTL 이내이면 oi가 이미 실행됐다고 판단하고 통과 허가한다.

```yaml
마커_생성:
  mcp__oio__file_write(
    path="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/oi_routed",
    content="$(date +%s)",
    overwrite=true
  )
생략_금지: oi_route_guard.sh 차단 방지를 위해 생략 불가
TTL: 마커 생성 후 10초 이내에만 유효 (oi_route_guard.sh 기준)
```

## Step 1: 입력 분류 및 처리

```yaml
분류_기준:
  A_즉시처리:
    - 간단한 상황 확인, 진행상황 문의 (1문장 답변 가능)
    행동: 메인이 직접 답변. 파이프라인 계속 진행.

  B_수정_명령 (팀에이전트 위임 — 절대 규칙):
    - 현재 진행 중인 작업 방향 변경
    - 요구사항 추가/수정
    - 현재 파이프라인과 무관한 수정 (스킬/hook/도구/다른 기능 파일 등)
    행동: |
      # [절대 규칙] 수정 요청은 종류/관련성 불문 무조건 팀에이전트에 위임
      # 메인이 직접 수정하는 행위 절대 금지 (write_guard가 DEV 상태에서 차단)

      # Step B-1: 담당 에이전트 및 파일 관련성 판별
      1. file_assignment.json 확인:
         mcp__oio__file_read("${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/file_assignment.json")
         → 요청 파일이 현재 에이전트 할당 매트릭스에 존재하는지 확인

      2. agents/ 디렉토리에서 활성 에이전트 목록 확인:
         ls "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/agents/" 2>/dev/null

      # Step B-2: 케이스별 처리

      케이스_A (파이프라인 관련 + 같은 파일 담당 에이전트 실행 중):
        판단: 요청 파일이 file_assignment.json에 있고, 해당 파일 담당 에이전트가 agents/에 존재
        행동: SendMessage(to="{담당에이전트명}", message="사용자 수정 요청: {내용}", summary="수정 요청")
        안내: "{담당에이전트명}에게 수정 요청을 전달했습니다."

      케이스_B (파이프라인 관련 + 담당 에이전트 없음 — PLAN 단계 등):
        판단: 요청 파일이 file_assignment.json에 있으나 해당 에이전트 미실행
        행동: |
          echo "[수정요청] {내용}" >> "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/oi_queue"
          → DEV 단계 시작 시 odev에 자동 전달
        안내: "수정 요청을 큐잉했습니다. DEV 단계 시작 시 반영됩니다."

      케이스_C (현재 파이프라인과 무관한 수정):
        판단: 요청 파일이 file_assignment.json에 없거나, 파이프라인 도구/스킬/hook 수정 등
        행동: |
          # 무조건 새 팀에이전트 spawn — oi_queue 기록 절대 금지
          Agent(
            name: "oi-fix-1",
            team_name: "{TEAM_NAME}",
            subagent_type: "general-purpose",
            mode: "bypassPermissions",
            run_in_background: true,
            prompt: """
            PIPELINE_UUID={UUID}
            당신은 oi-fix-1 에이전트입니다. 파이프라인과 무관한 독립 수정 요청을 처리합니다.
            수정 요청: {사용자_요청_내용}
            oio MCP 도구(file_read/file_edit/file_write)로 직접 수정 후
            SendMessage(to="team-lead@{TEAM_NAME}", message="[oi-fix-1] 수정 완료: {요약}", summary="수정 완료")
            """
          )
          mcp__oio__file_write(
            path="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/agents/oi-fix-1",
            content="oi-fix-1"
          )
        안내: "독립 수정 요청을 oi-fix-1 에이전트가 처리합니다."
        정리: oi-fix-1은 ofinish 단계에서 다른 팀에이전트와 함께 shutdown됨

  C_질문 (Q&A 에이전트 spawn):
    - 기술적 질문, 설명 요청, 분석 의뢰
    - 단순 즉시처리로 부족한 깊이 있는 질문
    행동: |
      # Step 0에서 확인한 TEAM_NAME 사용
      1. 팀명 없으면:
           팀_없음_처리:
             TeamCreate(team_name="oi-temp-{UUID 앞 8자}") 실행 후 oi-qa spawn
             (직접 처리 폴백 금지)

      2. Q&A 에이전트 spawn (기존 팀에 합류):
         Agent(
           name: "oi-qa",
           team_name: "{TEAM_NAME}",
           subagent_type: "general-purpose",
           mode: "bypassPermissions",
           run_in_background: true,
           prompt: """
           PIPELINE_UUID={UUID}
           당신은 oi-qa 에이전트입니다. 파이프라인 진행 중 사용자 질문에 답변하는 전담 에이전트입니다.
           첫 번째 질문: {사용자_질문}

           ## 역할
           - 질문에 상세히 답변 (Read/Grep/Glob/Bash 읽기 전용 사용 가능)
           - 답변 후 다음 질문을 기다림 (세션 유지 — 종료 명령 받을 때까지)
           - 파일 수정 금지

           ## 종료 조건
           메인으로부터 shutdown_request 수신 시 정상 종료.
           (ofinish 단계에서 메인이 shutdown 발송)

           ## 답변 후
           SendMessage(to="team-lead@{TEAM_NAME}", message="[oi-qa] 답변 완료: {요약}", summary="qa 답변 완료")
           """
         )

      3. oi-qa agents/ 등록 (ofinish가 누락 없이 정리할 수 있도록 방어적 등록):
         mcp__oio__file_write(
           path="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/agents/oi-qa",
           content="oi-qa"
         )

      4. 사용자에게: "질문을 oi-qa 에이전트가 처리합니다. 답변을 기다려주세요."
      5. oi-qa는 ofinish 단계에서 다른 팀에이전트와 함께 shutdown됨
         (ofinish → team-cleanup.sh → TeamDelete 순서로 팀 전체 정리)
```

## 주의사항

- oi는 **state를 변경하지 않는다**
- oi는 ok를 호출하지 않음
- IDLE 상태에서는 oi가 호출되지 않음
- 슬래시 명령(/ox 포함)은 hook이 oi 바이패스 처리 — oi가 개입하지 않음
- Q&A 에이전트(oi-qa)는 agents/ 디렉토리에 방어적 등록 + Agent 도구가 팀 config에 자동 등록 → ofinish가 누락 없이 정리
