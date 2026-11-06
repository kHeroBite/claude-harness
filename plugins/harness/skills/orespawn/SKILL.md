---
name: orespawn
description: 팀에이전트 리스폰(교대) 스킬. 팀원이 실행하면 하던 작업을 안전한 지점에서 멈추고 인계 파일을 쓴 뒤 team-lead 에 [리스폰요청] 을 보내 새 인스턴스로 이어 가게 한다. 메인이 '/orespawn 팀원명' 으로 실행하면 그 팀원만 교대하고, 인자 없이 실행하면 전체 팀원의 CPU·메모리·실행 시간·시스템 부하를 점검해 과다한 팀원을 교대한다. '/orespawn', '리스폰', '팀원 교대', '팀원 재시작', 'CPU·메모리 과다', '팀원이 무거워' 요청 시 사용. 파이프라인 state 를 바꾸지 않는다.
---

# orespawn — 팀에이전트 리스폰(교대)

팀원은 Agent 도구가 없어서(flat team) 스스로 리스폰할 수 없다. 그래서 역할을 나눈다.
팀원은 인계 준비와 리스폰 요청까지만 하고, 실제 종료와 재spawn 은 메인이 한다.
파이프라인 state·classification 은 바꾸지 않는다.

## 모드 판정

```yaml
팀원_모드: 환경변수 PIPELINE_UUID 가 있다 (팀원은 spawn 프롬프트로 주입받는다)
메인_모드: PIPELINE_UUID 가 없다
  - 인자(팀원명) 있음 → 지정 교대
  - 인자 없음        → 점검 후 자동 교대
경로_기준: SE=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/<UUID>  (자기 세션만)
점검_스크립트: <이 스킬 폴더>/scripts/respawn_check.py
```

## 팀원 모드

1. **안전 지점에서 멈춤.** 지금 하던 도구 작업이 끝나면 다음 작업을 시작하지 않는다. 쓰던 파일은 저장한다. 파일이 반쯤 고쳐진 상태로 남으면 그 사실을 인계 파일 주의점에 적는다. 커밋은 하지 않는다.
2. **인계 파일 작성.** `$SE/work/<자기이름>_handoff.md` 를 `mcp__oio__file_write` 로 쓴다.

   ```markdown
   # 인계: <자기이름> → 새 인스턴스
   - 작성: <date '+%Y-%m-%d %H:%M:%S %Z' 실측> / 작성자: <자기이름> (메인 대필이면 "메인 대필" 표시)
   ## 원래 과업 요약
   ## 끝낸 단계
   ## 남은 단계 (실행할 명령 원문 포함)
   ## 수정 중인 파일과 미커밋 여부 (git status --short 결과)
   ## 커밋 해시 (이번 과업에서 만든 것)
   ## RUN_DIR·로그·결과 파일 경로
   ## 열린 질문과 리드 결정 (보낸 질문, 받은 결정 원문 요약, 답을 기다리는 질문)
   ## AC priority (맡은 AC 의 must·should 구분과 남은 항목)
   ## 도구 제약 (예: 실행기 --id 는 한 번에 하나, 대기는 Monitor until 루프나 file_read 로 하고 foreground sleep 금지)
   ## 주의점 (반쯤 고친 파일, 가드 차단 이력, 대기 중인 메시지 등)
   ```
3. **리스폰 요청.** `SendMessage(to="team-lead", summary="리스폰요청 <이름>")`. 첫 줄은 정확히 이 형식이다.
   `[리스폰요청] <이름> 인계파일=<절대경로> 사유=<사용자 요청|자가 판단>`
   otest 처럼 완료 게이트가 있는 역할이면 본문에 "완료 보고가 아님 — 완료 마커를 쓰지 않은 사유: <사유>" 를 1줄 넣는다.
4. **대기.** 새 작업을 시작하지 않고 shutdown_request 를 기다린다. 받으면 즉시 `{"type":"shutdown_response","request_id":"<받은 id>","approve":true}` 로 승인하고 종료한다.

## 메인 모드 — 팀원명 인자 있음 (지정 교대)

대상 팀원 `<이름>` 이 자기 팀(`teams/<팀>/config.json` 의 leadSessionId == 자기 UUID)의 멤버인지 먼저 확인한다. 아니면 중단한다.

1. **요청.** `SendMessage(to="<이름>", message="Skill('orespawn') 을 실행하라 — 사유: 메인 지정 교대")`.
2. **인계 수신.** `[리스폰요청]` 과 인계 파일을 기다린다. 3분 안에 응답이 없으면 메인이 `$SE/work/<이름>_result.json`·`git status --short`·`git log --oneline -5`·원래 spawn 프롬프트로 인계 파일을 대신 쓰고 맨 위에 `메인 대필(팀원 무응답)` 을 표시한다.
3. **종료 요청.** `SendMessage(to="<이름>", message={"type":"shutdown_request","reason":"orespawn 교대"})`.
4. **pane 소멸 실측.** pane id 는 `$SE/agents/<이름>` 의 `pane_id=` 또는 팀 config 의 `tmuxPaneId` 다.
   `timeout 30 bash -c 'while tmux list-panes -a -F "#{pane_id}" | grep -qx "<pane_id>"; do sleep 3; done'; echo rc=$?`
   rc≠0(30초 안에 소멸하지 않음)이면 그 팀원의 백그라운드 task 를 `TaskStop` 으로 멈추고 다시 실측한다.
5. **새 이름으로 spawn.** 이름은 번호를 올린다(`odev-49` → `odev-49r1`, 이미 있으면 `r2` …). 같은 이름은 이전 pane 소멸을 실측한 뒤에만 쓸 수 있다.

   ```yaml
   Agent:
     subagent_type: <원래와 같은 값>      # 예: general-purpose
     name: <새 이름>
     team_name: <자기 팀명>                # $SE/team_name
     mode: <원래와 같은 값>
     model: <원래 팀원의 model>            # 팀 config members[].model
     run_in_background: true
     prompt: |
       PIPELINE_UUID=<UUID>
       CLAUDE_CONFIG_DIR=<값>
       당신은 <새 이름> 이다. <옛 이름> 의 작업을 이어받는다.
       인계 파일: <인계 파일 절대경로> — 먼저 읽고, 인계 파일의 남은 단계부터 이어서 하라.
       <원래 과업 프롬프트의 제약(작업 폴더·담당 파일·금지 사항·커밋 규칙·보고 경로)을 그대로 다시 넣는다>
       결과 파일은 $SE/work/<새 이름>_result.json 에 쓴다.
   ```
6. **소유자 갱신.** `$SE/file_assignment.json` 에서 옛 이름이 소유한 파일의 소유자를 새 이름으로 바꾸고 version 을 +1 한다.

## 메인 모드 — 인자 없음 (점검 후 자동 교대)

1. **점검.**
   `python3 -B <스킬폴더>/scripts/respawn_check.py --uuid <UUID> [--rss-mb 2000] [--cpu-idle 30] [--age-min 90] [--load 50]`
   - 읽기 전용이다. 팀원 본체(argv `--agent-id 이름@팀`, `--parent-session-id == UUID`)의 프로세스 트리를 statusline 과 같은 방식으로 잰다.
   - RSS 는 팀원 본체와 MCP 자식 등 프로세스 트리 합계다. 갓 뜬 팀원도 약 1GB 라서 기본 기준을 2000MB 로 둔다(2026-11-05 실측).
   - 판정: RSS 초과·실행 분 초과·유휴(isActive=false)인데 CPU 초과 중 하나면 RESPAWN 이다. 1분 load 가 기준을 넘으면 CPU 최대 팀원 1명을 사유 `load` 로 더한다. 측정 실패는 UNKNOWN 이고 교대하지 않는다. 경계값과 같으면 KEEP 이다.
   - 종료 코드: 대상 있음 10, 없음 0, 오류 2. 오류면 원문을 보고하고 멈춘다.
2. **교대.** RESPAWN 팀원마다 위 지정 교대 1~6 을 한다. 바쁜 팀원(`busy=true`, 즉 isActive=true 이거나 지금 도구 실행 중)은 "현재 단계가 끝나면 교대" 로 표시만 하고, 그 팀원의 완료 보고를 받은 뒤 교대한다.
3. **대상 없음.** 점검 표를 출력하고 끝낸다.

## 금지

- 같은 이름 즉시 재사용 금지. 이전 pane 소멸을 실측하기 전에는 같은 이름을 쓰지 않는다(agents/<이름> 파일이 덮어써져 추적을 잃는다).
- 다른 세션의 팀원·session-env 대상 금지. 읽지도 쓰지도 않는다.
- 바쁜 팀원 강제 종료 금지. 사용자가 팀원명을 명시한 경우만 예외다.
- 인계 파일 없이 재spawn 금지(무응답이면 메인 대필 표시 후 진행).
- 점검 스크립트는 kill 하지 않는다. 프로세스 종료는 shutdown_request → 실측 → TaskStop 순서로만 한다.
- 팀원 모드에서 커밋·push 금지.
