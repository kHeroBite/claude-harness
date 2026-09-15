# Wave 동적 spawn 상세

## Wave_동적_spawn (Phase 2-A)

```yaml
핵심_원칙:
  - odev 에이전트 수를 oplan 시점에 고정하지 않음
  - Wave 실행 직전 의존성 기반으로 READY 집합 동적 계산
  - Wave 내 에이전트 수 = len(READY)
  - Wave 내 동시 spawn은 선택이 아닌 필수: READY 집합 크기만큼 한 메시지에서 Agent() 호출을 동시에 발행해야 하며, 하나씩 순차 호출하는 것은 이 원칙 위반이다

실행_흐름:
  초기화: oplan TODO_*.md에서 tasks[] + dependencies[] 추출, 완료_집합 = {}
  Wave_루프:
    1. READY = {task | task.dependencies ⊆ 완료_집합}
    2. READY 비어있음 → 순환 의존 오류 → 조기 종료
    3. READY 각 task에 odev 동시 spawn (필수 — 1개 메시지 내 다중 Agent() 호출로 동시 발행. 순차 개별 spawn 금지)
    4. 전체 완료 대기 → shutdown + 완료_집합 += READY
    5. 다음 Wave 반복 → 전체 완료 시 otest 진입

예시:
  tasks: [A(무), B(무), C(A), D(A,B), E(C,D)]
  Wave 1: {A,B} → Wave 2: {C,D} → Wave 3: {E} → 총 5개

부분실패: 해당 에이전트만 재spawn (reroute_count 미증가)
재spawn_프롬프트: 실패 원인 + reroute_context.md + git diff + 타 에이전트 수정 파일 (M-05)
폴백: dependencies 없음 → 전체 병렬 (Wave 1개)
```
