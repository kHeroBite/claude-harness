---
name: opwb
description: "[alias] otest_playwright_bg spawn 강제 — 단독 호출 시 항상 팀에이전트 위임 (headless 백그라운드)"
invocation:
  user_callable: true
  pipeline_callable: true
  called_by: [otest_ui, 사용자]
  calls: []
---

# opwb — Playwright headless 백그라운드 테스트 팀에이전트 spawn alias

```yaml
절대_규칙: 메인 직접 실행 금지 — 사용자 단독 호출 시 항상 팀에이전트 spawn 위임

호출_경로_분기:
  사용자_단독_호출 (IDLE):
    절차:
      Step_1_인자_가드:
        ARGUMENTS 비었으면:
          - 출력: "🎭 어떤 페이지/시나리오를 headless로 테스트하시겠습니까? URL 또는 설명을 알려주세요."
          - 예시_출력: |
              예시:
              - /opwb https://example.com 로그인 페이지 헤드리스 스크린샷
              - /opwb http://localhost:3000 폼 제출 후 결과 캡처
              - /opwb know API 문서 페이지 자동화 검증
          - 즉시 종료 (TeamCreate/spawn 진행 안 함)

      Step_2_TeamCreate:
        team_name: "opwb-{unix timestamp 마지막 8자리}"
        description: "opwb 단독 실행 — Playwright headless 백그라운드 시나리오"
        충돌_시: TeamDelete 후 재시도

      Step_3_team_name_저장:
        mcp__oio__file_write:
          path: $HOME/.claude/session-env/${UUID}/team_name
          content: "{team_name}"

      Step_4_Agent_spawn:
        subagent_type: general-purpose
        name: opwb-runner
        team_name: "{team_name}"
        model: sonnet
        mode: bypassPermissions
        run_in_background: false
        prompt: |
          Skill('otest_playwright_bg') 호출 후 다음 시나리오 실행:
          {ARGUMENTS}

          절차:
          1. otest_playwright_bg SKILL.md 패턴대로 /tmp/pw_script.js 작성 (mcp__oio__file_write)
          2. mcp__oio__bash_exec로 node /tmp/pw_script.js 실행 (headless)
          3. 스크린샷 결과 확인 (/tmp/test-*.png 또는 사용자 지정 경로)

          보고:
          - team-lead에게 SendMessage로 결과 5줄 이내 요약 + 스크린샷 경로만 전달
          - 긴 콘솔 로그/DOM dump는 보고에 포함 금지
          - 에러 시 에러 메시지 + 스크린샷 경로만 보고

      Step_5_보고_수신:
        에이전트가 SendMessage로 결과 보고
        메인은 그대로 사용자에게 전달 (5줄 이내)

      Step_6_정리:
        - SendMessage(to=opwb-runner, message={type: "shutdown_request"})
        - shutdown_response 수신 후 TeamDelete()
        - state는 IDLE 유지 (파이프라인 미진입)

  파이프라인_경유 (otest_ui 호출):
    동작: otest_ui가 본체 Skill('otest_playwright_bg') 직접 호출 (alias 경유 안 함)
    이_alias_절차: 적용 안 됨
    이유: otest_ui/SKILL.md에서 본체명 직접 사용 확인

인자_없는_호출_가드:
  메시지: "🎭 어떤 페이지/시나리오를 headless로 테스트하시겠습니까? URL 또는 설명을 알려주세요."
  종료: TeamCreate/spawn 진행 안 함 (즉시 종료)
```
