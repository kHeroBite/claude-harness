# PIPELINE_OVERVIEW.md — o시리즈 파이프라인 한 장 요약 (v4.3)

## 5-tier 분류 기준 (단일 출처: ok SKILL.md)

| Tier | 이름 | 조건 | oplan | otest | odone |
|------|------|------|-------|-------|-------|
| o1 | Instant | 비코드 파일만 (.md/.json/.sh 등) OR 소규모 코드(≤20줄, ≤2파일) | 없음 | 없음 | 없음 |
| o2 | Simple | 코드 1~3파일 AND 50줄 이하 | oplan_simple | 없음 (obr만) | 없음 |
| o3 | Normal | 코드 500줄 이하 | oplan_normal | 필수 | 필수 |
| o4 | Heavy | 500줄 초과 OR 아키텍처 변경 | oplan_deep | 필수 | 필수 |
| o5 | Massive | 대규모 (1500줄+ OR 모듈 3개+) | oplan_debate | 필수 | 필수 |

## 호출 경로

```
/ok  → ok 의도분석(텍스트) → oplan에 hint_tier 전달 → oplan이 o2~o5 확정
/o1  → oplan 없음 → odev → ofinish (즉시 처리)
/o2  → oplan 없음 → odev → obr → ofinish (간단 처리)
/o3  → oplan에 forced_tier=o3 전달 → oplan_normal → odev → otest → odone → ofinish
/o4  → oplan에 forced_tier=o4 전달 → oplan_deep → odev → otest → odone → ofinish
/o5  → oplan에 forced_tier=o5 전달 → oplan_debate → odev → otest → odone → ofinish
```

## 파이프라인 흐름

```
사용자 요청
    ↓
메인 7-way 분류 (질문/계획/o1/o2/o3/o4/o5)
    ├─ 질문 → 직접 응답 (ok 미경유)
    ├─ 계획 → oplan 직접 spawn (ok 미경유)
    └─ 수정 → Skill('ok') 로딩
                ↓
           분류 판정 (1-way: /ok → oplan 경유)
           ├─ o1: odev → ofinish
           ├─ o2: odev → obr → ofinish
           ├─ o3: oplan_normal → odev → otest → odone → ofinish
           ├─ o4: oplan_deep → odev×N → otest → odone → ofinish
           └─ o5: oplan_debate → odev×N → otest → odone → ofinish
```

## 에이전트 역할 요약

| 에이전트 | 역할 | 담당 |
|---------|------|------|
| oplan | 계획 수립 | TODO 작성, 파일 할당 (depth: simple/normal/deep/dual) |
| odev | 코드 구현 | 파일 수정, Lock 관리 |
| otest | 테스트 | 빌드, 배포, 품질 검증 |
| odone | 마무리 | 교훈, git 커밋 |
| ofinish | 팀 정리 | shutdown, TeamDelete, IDLE 전환 |

## 파이프라인 상태 전이

```
IDLE → OK → PLAN → DEV → TEST → DONE → FINISH → IDLE
```

## 역라우팅 허용 경로

| From | To | 조건 |
|------|----|------|
| TEST | DEV | 구현 오류 발견 |
| TEST | PLAN | 설계 재검토 필요 |
| DEV | PLAN | TODO 불명확 |

## 핵심 Hook 4개

| Hook | 역할 |
|------|------|
| pipeline_order_guard | 파이프라인 순서 강제 |
| write_guard | NTFS 직접 수정 차단 + 메인 직접 수정 차단 |
| otest_done_guard | otest 없이 odone 진입 차단 (o1/o2 제외) |
| phase_guard | Skill 호출 후 단계 검증 |

## 참조 문서

- ok/SKILL.md: 7-way 분류 기준, 오케스트레이션 지침
- ok_pipeline/SKILL.md: o3~o5 파이프라인 상세
- ok/references/SHUTDOWN_PROTOCOL.md: 종료 프로토콜
