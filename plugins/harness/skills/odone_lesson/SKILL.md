---
name: odone_lesson
description: "교훈 수집 + 반영 — 문제 감지(trans) → 조치 결정(review) → 강제화(hooks/skills/docs). odone에서 1차로 호출."
invocation:
  user_callable: false
  pipeline_callable: true
  called_by: ["odone"]
  calls: ["odone_trans", "odone_review", "odone_hooks", "odone_skills", "odone_docs"]
---

# odone_lesson — 교훈 수집 + 반영

## 역할

교훈 수집 + 반영의 1차 라우터. odone에서 1단계로 호출되며, 내부적으로 trans→review→hooks→skills→docs를 순차 실행한다.

## 실행 순서 (순차 필수)

```yaml
실행_순서:
  # [P2-isolation] ⓪ cross-session 스캔 제거됨 (2026-04-24)
  # 이전: $HOME/.claude/session-env/*/errors.md 전체 순회 + 세션ID(앞8자) stdout 출력
  # 위반: §(a) 허가된 읽기 목록(state/team_name/heartbeat/config.json) 외 파일 읽기,
  #        §(c) 타 세션 UUID 접두어 stdout 노출 (앞8자도 UUID 노출에 해당)
  # 대안: 현재 세션($UUID)/errors.md 분석만 수행 (①~⑤ 단계가 이미 포함)

  ① Skill('odone_trans') — 문제 감지 (트랜스크립트 우회 패턴 수집)
  ② Skill('odone_review') — 조치 결정 (trans 결과 + 자체 분석 → review_actions.json)
     각 이슈에 target(hook/skill/docs) 배정
     판정 우선순위: hook(물리차단) > oio서버(파라미터별칭등) > skill(규칙유도) > CLAUDE.md(최후수단)
     ⚠️ Memory 업데이트는 재발방지 수단이 아님 (강제력 없음 — 절대 금지)
     ②-강화: 소스 C/D 교훈 추출
       review_actions.json의 user_feedback, model_errors 배열에서:
       - 반복 패턴(동일 피드백 2회+) → LESSONS.md에 반드시 기록 (Level 2 이상)
       - 역라우팅 원인(reroute_analysis) → 구체적 재발방지 조치 수립
       - 각 항목에 대해 Level(1/2/3) 분류 후 조치 실행:
         Level 1: 1회성 → LESSONS.md 참고 기록
         Level 2: 반복 가능성 → 스킬 규칙 강화
         Level 3: 2회+ 반복 → hook 물리 차단 또는 oio 서버 수정
  ③ Skill('odone_hooks') — target=="hook" 항목 처리 (hook 생성/수정)
  ④ Skill('odone_skills') — target=="skill" 항목 처리 (스킬 규칙 강화)
  ⑤ Skill('odone_docs') — target=="docs" 항목 + 전체 교훈 기록
     LESSONS.md + HISTORY.md + PROJECT.md + CLAUDE.md (재발방지 기록용, Memory 금지)
```

## tier별 적용

```yaml
o3_Fast:
  실행: ②⑤ 실행 (review→docs)
  조건부: ③④는 review_actions.json에 해당 target 항목 있을 때만 실행
  스킵: trans(①)는 Fast Path에서 항상 스킵 (②부터 시작)
  실제_순서: ② odone_review(간략) → ⑤ odone_docs (→ ③④는 review 결과에 따라)
  # [P2-isolation] ⓪ cross-session 스캔 제거됨 — §(a)§(c) 위반

o4_o5_Full:
  실행: ①②③④⑤ 전체 실행
  순서: odone_trans → odone_review → odone_hooks → odone_skills → odone_docs
  # [P2-isolation] ⓪ cross-session 스캔 제거됨 — §(a)§(c) 위반

o1_o2:
  해당없음: odone 자체 미실행 (ofinish Step 1.5 경량 교훈으로 대체)
```

## review_actions.json 형식

```json
[
  {
    "issue": "이슈 설명",
    "target": "hook|skill|docs",
    "action": "구체적 조치 내용",
    "priority": "P0|P1|P2"
  }
]
```

```yaml
저장_경로: $HOME/.claude/session-env/${UUID}/logs/review_actions.json
priority_기준:
  P0: 즉시 차단 필요 (hook 대상)
  P1: 규칙 강화 필요 (skill 대상)
  P2: 기록/공유 필요 (docs 대상)
```

<!-- [P2-isolation] unprocessed_sessions 필드 및 ⓪단계 관련 JSON 형식 제거됨 (2026-04-24)
§(a)§(c) 위반: 타 세션 errors.md 읽기 + 세션ID stdout 노출 -->


## observations.md 연결 (상시 관찰 → L- 승격, 2026-08-24 신설)

`otask_observer` 스킬은 세션 중 `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/logs/observations.md` 에 상시 관찰 기록(OBS-NNN, 미검증)을 남긴다. odone 도달 전에 소실되던 세션 중간 교정을 여기서 회수한다.

```yaml
연결_절차 (② odone_review 직후 ~ ⑤ odone_docs 이전):
  1. observations.md 존재 여부 확인
     - 파일 부재 시 조용히 건너뛴다 (fail-soft — otask_observer 미사용 세션은 오류 아님)
  2. 존재 시 OPEN 상태 OBS 항목만 읽는다 (이미 승격 표시된 항목은 제외)
  3. 각 OPEN 항목에 대해 L- 승격 후보 여부 판정
  4. 승격 판정 기준 (아래 중 2개 이상 충족 시 승격):
     - 재현성 확인됨 (이번 세션 또는 과거 세션에서 동일 패턴 반복 관측)
     - 물리 조치 가능 (hook/oio서버/skill 규칙 중 하나로 강제화 가능)
     - 이번 파이프라인 사이클과 직접 관련 있음 (무관한 과거 관찰은 보류)
  5. 승격 시:
     - LESSONS.md에 신규 L-NNN 항목으로 기록 (⑤ odone_docs 단계에 위임)
     - observations.md 원본 OBS 항목에 승격 표시를 남겨 중복 승격 방지
       (예: "[승격→L-NNN]" 태그를 상태 필드에 추가)
  6. 승격 보류 항목은 OPEN 상태 그대로 둔다 (다음 odone 사이클에서 재검토)

네임스페이스: OBS-NNN(관찰, 미검증) ≠ L-NNN(확정 교훈) — 혼용 금지
```

## 완료 조건

```yaml
완료_기준: ①~⑤ 모든 해당 단계 완료 (tier에 따라 생략 가능한 단계 제외)
반환값: "odone_lesson 완료"
```

## 재발방지 완벽 검증 절차 (2026-04-12 신규)

### Step A: 우회 경로 분석 의무
조치 적용 후 아래 5가지 우회 경로를 전수 점검하고 각각 차단 여부를 명시:
1. Hook 미호출 경로 (hook 자체가 발동 안 하는 조건)
2. Script 호출 생략 경로 (LLM이 스크립트 호출 안 해도 되는 경로)
3. Skill 규칙 무시 경로 (SKILL.md 문구를 LLM이 읽지 않는 경로)
4. 문서만 남고 실행 없음 경로 (Memory/LESSONS만 업데이트된 경우)
5. 재시작/재로드 시 리셋되는 경로 (휘발성 상태)

### Step B: 물리 차단 점수 매트릭스 (각 0~10점)
| 항목 | 점수 | 기준 |
|------|------|------|
| 물리 차단 강도 | 0~10 | Hook>Script>Skill>문서 순 10/8/5/2 |
| LLM 의지 독립성 | 0~10 | LLM 없이 발동되면 10, LLM 호출 필수면 3 |
| 원인 차단 (vs 사후 청소) | 0~10 | 발생 자체 차단 10, 사후 정리만 3 |
| 시나리오 커버리지 | 0~10 | 확인된 모든 case 차단 10, 대표 case만 5 |
| 자동 회귀 테스트 | 0~10 | 단위 테스트 존재 10, 없음 0 |
| **종합 (평균)** | **8/10 미달 시 추가 조치 강제** |

### Step C: Hook 1순위 미적용 사유 명시 의무
Hook을 1순위로 쓰지 못한 이유를 반드시 명시:
- 예: "cleanup.sh는 외부 스크립트라 Hook 메커니즘 불가 → Script 1순위로 대체"
- 예: "Hook에서 실행 불가한 작업(외부 API 호출 등) → Script로 대체"
- **Hook 1순위 회피가 정당화되지 않으면 재조치 강제**

### Step D: 완료 조건
- 점수 총합 40/50 (8/10 평균) 이상 + 우회 경로 5건 전부 차단 + Hook 미적용 사유 문서화
- 미달 시 재발방지 **실패** 선언 → 추가 조치 강제

### Step E: 보고 형식
```
🔒 재발방지 완벽 검증 (Step A~D)
- 우회 경로 차단: {N/5}
- 물리 차단 점수: {총합}/50 ({평균}/10)
- Hook 1순위: {적용/미적용 — 사유}
- 완료 조건: {PASS/FAIL}
```


