# Wave 동적 spawn 상세

## Wave_동적_spawn (Phase 2-A)

```yaml
핵심_원칙:
  - odev 에이전트 수를 oplan 시점에 고정하지 않음
  - Wave 실행 직전 의존성 기반으로 READY 집합 동적 계산
  - Wave 내 에이전트 수 = min(len(READY), 남은 슬롯) — 남은 슬롯 = 세션 동시 생존 팀원 상한 9(max_live_teammates, 메인 포함 10) − 현재 생존 팀원 수. 넘치는 READY 는 대기열에 둔다.
  - Wave 내 동시 spawn은 선택이 아닌 필수: READY 집합 크기만큼 한 메시지에서 Agent() 호출을 동시에 발행해야 하며, 하나씩 순차 호출하는 것은 이 원칙 위반이다

실행_흐름:
  초기화: oplan TODO_*.md에서 tasks[] + dependencies[] 추출, 완료_집합 = {}
  Wave_루프:
    1. READY = {task | task.dependencies ⊆ 완료_집합}
    2. READY 비어있음 → 순환 의존 오류 → 조기 종료
    3. READY 각 task에 odev 동시 spawn (필수 — 1개 메시지 내 다중 Agent() 호출로 동시 발행. 순차 개별 spawn 금지). 남은 슬롯을 넘는 READY 는 대기열에 둔다(F-AGENT-CAP 이 초과 spawn 을 차단한다).
    4. 완료 보고가 올 때마다 완료_집합 += 그 task → 보고 끝난 팀원 즉시 shutdown → READY 재계산 → 대기열과 새로 READY 가 된 미spawn task 를 남은 슬롯만큼 즉시 spawn
       (Wave 전체 완료를 기다리는 장벽을 두지 않는다 — 2026-10-10 자동 병렬 기본. 직렬 사유는 odev_parallel "병렬 판정 체크리스트")
    4-1. 상한 도달 시 회수 절차(2026-10-11 사용자 지시): F-AGENT-CAP 차단 안내의 "회수 후보" 를 1순위(완료 보고 후 유휴) → 2순위(agent_keep 역라우팅·재작업 대기, result.json 완료) 순으로 골라 shutdown_request → pane 소멸 실측 → 같은 spawn 재시도. 작업 중 팀원은 후보에 오르지 않으며 회수하지 않는다.
         hook 은 SendMessage 를 보낼 수 없으므로 종료는 메인이 한다. 회수한 keep 팀원은 다시 필요할 때 work/<이름>_result.json 을 근거로 같은 역할을 재spawn 한다(agent_keep/<이름> 은 회수 시 지운다).
    5. 전 task 완료 시 otest 진입
  물리_강제: hooks/PreToolUse_Agent_parallel_spawn_guard.sh — 같은 그룹·파일 비중첩 형제를 60초 이상 지나 따로 spawn 하면 S1 경고(세션 모드 block 시 1회 보류)

예시:
  tasks: [A(무), B(무), C(A), D(A,B), E(C,D)]
  Wave 1: {A,B} → Wave 2: {C,D} → Wave 3: {E} → 총 5개

부분실패: 해당 에이전트만 재spawn (reroute_count 미증가)
재spawn_프롬프트: 실패 원인 + reroute_context.md + git diff + 타 에이전트 수정 파일 (M-05)
폴백: dependencies 없음 → 전체 병렬 (Wave 1개)
```
