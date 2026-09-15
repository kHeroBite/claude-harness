---
name: oretro
description: "주간 회고. 커밋 이력 분석, 작업 패턴, 품질 트렌드. /oretro [7d|14d|30d|compare]"
invocation:
  user_callable: true
  pipeline_callable: false
  called_by: [사용자]
  calls: []
tools: mcp__oio__bash_exec
---

# oretro — 주간 엔지니어링 회고

> **읽기 전용** | **oio bash_exec 전용** | **AskUserQuestion 금지** | **한국어 출력**

---

## 호출 방법

```
/oretro           → 기본: 최근 7일
/oretro 14d       → 최근 14일
/oretro 30d       → 최근 30일
/oretro compare   → 현재 기간 vs 이전 동일 기간 비교
```

---

## 인수 처리 규칙

```yaml
형식: 숫자+d (예: 7d, 14d, 30d)
기본값: 7d (인수 없을 때)
날짜_기준: 자정 절대 날짜 (--since="YYYY-MM-DDT00:00:00")
compare: 현재 창 vs 이전 동일 길이 창
잘못된_인수: 사용법 출력 후 종료 (AskUserQuestion 금지 — 자동 판단)
```

---

## 실행 절차

### Step 0: 인수 파싱 및 날짜 범위 계산

- 입력 인수에서 숫자+d 형식 파싱 (기본 7d)
- `since` = 오늘 자정 기준 N일 전 (`date -d "N days ago" +%Y-%m-%dT00:00:00`)
- `until` = 오늘 자정 (`date +%Y-%m-%dT00:00:00`)
- compare 모드: 추가로 `prev_since` = since에서 N일 전, `prev_until` = since
- 잘못된 인수 시: 사용법 메시지 출력 후 즉시 종료

---

### Step 1: 원시 데이터 수집

**병렬 실행** — oio bash_exec 전용 (Claude 내장 Bash 절대 금지)

다음 커맨드를 병렬로 실행:

```bash
# 1a. 커밋 목록 (타임스탬프, 저자, 해시, 제목)
git log --since="${SINCE}" --until="${UNTIL}" \
  --format="%H|%ai|%an|%ae|%s" --no-merges

# 1b. 파일별 변경 통계 (numstat)
git log --since="${SINCE}" --until="${UNTIL}" \
  --numstat --format="" --no-merges

# 1c. 저자 목록
git log --since="${SINCE}" --until="${UNTIL}" \
  --format="%an" --no-merges | sort | uniq -c | sort -rn

# 1d. 시간대별 커밋 (로컬 시각 기준 시간만 추출)
git log --since="${SINCE}" --until="${UNTIL}" \
  --format="%ad" --date=format:"%H" --no-merges

# 1e. 현재 git 사용자
git config user.name
```

---

### Step 2: 지표 계산

수집한 원시 데이터로 다음 지표를 계산:

| 지표 | 계산 방법 |
|------|-----------|
| 커밋 수 | 1a 결과 라인 수 |
| 기여자 수 | 1c 유니크 저자 수 |
| 전체 삽입(LOC+) | 1b numstat 2열 합계 |
| 전체 삭제(LOC-) | 1b numstat 3열 합계 |
| 순 변경 LOC | 삽입 - 삭제 |
| 테스트 LOC 비율 | test/spec 포함 파일 LOC ÷ 전체 LOC × 100 |
| 활성 일수 | 커밋 날짜 유니크 개수 |
| 세션 수 | Step 4에서 계산 |

**테스트 파일 판별 패턴**: 경로에 `test`, `spec`, `Test`, `Spec` 포함

---

### Step 3: 커밋 시간 분포

1b 시간 데이터(0~23시)를 히스토그램으로 집계:

```
출력 형식:
00-05시 (심야)  : ██░░░░░░ N건
06-11시 (오전)  : ████████ N건
12-17시 (오후)  : ██████░░ N건
18-23시 (저녁)  : ████░░░░ N건
```

- **피크 시간대**: 가장 많은 커밋이 집중된 1시간 구간
- **심야 코딩 패턴**: 0~5시 커밋 비율 계산
- 심야 비율 30% 초과 시: `⚠️ 심야 작업 비중 높음` 표시

---

### Step 4: 작업 세션 감지

커밋 타임스탬프 기준으로 세션 분류:

```yaml
세션_기준:
  gap: 45분 (연속 커밋 간격이 45분 초과 시 새 세션)
  분류:
    심층_세션: 지속시간 50분 이상
    중간_세션: 20분 이상 ~ 50분 미만
    마이크로_세션: 20분 미만 (단일 커밋 포함)
```

출력:
```
세션 요약:
  총 세션: N개
  심층(50분+): N개
  중간(20-50분): N개
  마이크로(<20분): N개
  평균 세션 길이: N분
```

---

### Step 5: 커밋 유형 분류

Conventional Commit 접두어 기반 분류:

| 유형 | 패턴 | 의미 |
|------|------|------|
| feat | `✨`, `feat:`, `기능` | 새 기능 |
| fix | `🔧`, `fix:`, `수정`, `bugfix` | 버그 수정 |
| refactor | `♻️`, `refactor:`, `리팩` | 리팩토링 |
| test | `🧪`, `test:`, `테스트` | 테스트 |
| chore | `📝`, `chore:`, `docs:` | 유지보수/문서 |
| other | 그 외 | 미분류 |

**경고 조건**: fix 비율 50% 초과 시 `⚠️ 수정 비중 과다 — 사전 설계 검토 권장` 표시

---

### Step 6: 핫스팟 분석

1b numstat에서 파일별 변경 횟수 집계:

```bash
# 자주 변경된 상위 10개 파일 추출
git log --since="${SINCE}" --until="${UNTIL}" \
  --name-only --format="" --no-merges | \
  sort | uniq -c | sort -rn | head -10
```

출력 형식:
```
핫스팟 파일 (상위 10):
  🔥 src/Core/Engine.cs        (변경 12회) ← 5회+ 핫스팟
  📄 src/UI/MainForm.cs        (변경 4회)
  ...
```

- **5회 이상 변경**: 🔥 핫스팟 마크 표시
- 핫스팟이 특정 디렉토리에 집중 시 `📍 집중 영역: {디렉토리}` 표시

---

### Step 7: 기여자별 분석

현재 git 사용자(`git config user.name`)는 **나** 레이블로 표시:

```
기여자별 분석:
  👤 홍길동 (나)
     커밋: N건  |  삽입: N  |  삭제: N
     주요 활동 영역: src/Core, src/UI
     활성 시간대: 14~18시

  👤 김철수
     커밋: N건  |  삽입: N  |  삭제: N
     주요 활동 영역: src/API
     활성 시간대: 09~12시
```

기여자가 1명이면 팀 비교 섹션 생략.

---

### Step 8: 주간 최고성과 (Ship of the Week)

가장 많은 LOC 변경을 가져온 작업 자동 식별:

```bash
# 파일 그룹(세션)별 변경 LOC 합계
git log --since="${SINCE}" --until="${UNTIL}" \
  --numstat --format="%H %s" --no-merges
```

출력:
```
🏆 주간 최고성과 (Ship of the Week)
  커밋: {해시 앞 7자}
  제목: {커밋 메시지}
  변경: +{삽입} / -{삭제} LOC
  추정 의미: {커밋 메시지에서 자동 추론}
```

커밋이 0건이면 "이번 기간 커밋 없음" 출력.

---

### Step 9: 비교 모드 (compare 인수 시에만 실행)

Step 1~8을 현재 기간과 이전 기간 양쪽으로 실행 후 비교:

```yaml
현재_기간: since ~ until
이전_기간: prev_since ~ prev_until (동일 길이)
```

비교 테이블:
```
                    현재 기간    이전 기간    변화
커밋 수             N           N           ▲N (+X%)
기여자 수           N           N           →
전체 LOC 변경       N           N           ▼N (-X%)
활성 일수           N           N           ▲N
세션 수             N           N           ▲N
테스트 비율         N%          N%          ▲N%
fix 비율            N%          N%          ▼N%
```

트렌드 기호: `▲` 증가 / `▼` 감소 / `→` 동일

---

### Step 10: 엔트로피 점검 — 스킬/Hook Drift 감지 (P2)

> OpenAI Codex 원칙: 작업 간 누적된 drift를 주기적으로 독립 에이전트가 점검

점검_항목:
  1. 스킬 파일 vs 실제 구현 Drift:
     - SKILL.md에 명시된 규칙이 실제 코드/hook에 반영되었는가?
     - 스킬이 참조하는 파일 경로/함수명이 여전히 유효한가?
  2. LESSONS.md 미반영 항목:
     - LESSONS.md의 각 교훈 중 SKILL.md/hook에 아직 반영되지 않은 항목 목록 출력
     - 미반영 항목이 있으면 odone_lesson/odone_hooks 실행 권고
  3. Hook 중복/무효화:
     - 동일 목적의 hook이 중복 존재하는가?
     - 비활성 또는 항상 통과하는 guard가 있는가?

출력_형식:
  - Drift 항목 목록 (파일명 + 불일치 내용)
  - LESSONS.md 미반영 항목 수
  - 권고 조치

---

### Step 11: 하네스 가정 감사 (N3 — Assumption Audit)

> Anthropic Engineering: "Each component encodes an assumption about what the model can't do alone."

신모델_도입_시_점검 (트리거: ok_model/SKILL.md의 재평가_트리거_조건 해당 시):
  - oplan 가정: "모델이 혼자 tier를 결정할 수 없다" — 현재도 유효한가?
  - otest 가정: "독립 평가자 없이 자기평가 편향이 발생한다" — 현재 모델에도 유효한가?
  - advisor 가정: "Opus가 Sonnet보다 의미있게 더 나은 리뷰를 제공한다" — 여전히 유효한가?
  - 각 hook 가정: "모델이 스스로 이 규칙을 지키지 못한다" — 현재도 유효한가?

판정_기준:
  - 가정이 여전히 유효: 컴포넌트 유지
  - 가정이 무효화됨: 컴포넌트 제거 또는 단순화 검토 → odone_review에 반영

---

## 최종 리포트 출력 형식

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📊 엔지니어링 회고 — {YYYY-MM-DD} ~ {YYYY-MM-DD} ({N}일)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## 핵심 지표
| 지표            | 값      |
|-----------------|---------|
| 커밋 수         | N       |
| 기여자          | N명     |
| 삽입 LOC        | +N      |
| 삭제 LOC        | -N      |
| 테스트 LOC 비율 | N%      |
| 활성 일수       | N일     |
| 세션 수         | N개     |

## 커밋 시간 분포
...

## 작업 세션
...

## 커밋 유형 분포
...

## 핫스팟 파일
...

## 기여자별 분석
...

## 주간 최고성과
...

## [비교 모드 시] 기간 비교
...

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## 절대 규칙

```yaml
읽기_전용: 파일 생성/수정/삭제 금지
AskUserQuestion_금지: 모든 판단 자동 처리
도구_전용: oio bash_exec만 사용 (Claude 내장 Bash 금지)
언어: 한국어 (기술 용어/명령어 제외)
출력_저장_금지: 파일로 저장 없음, 화면 출력만
```
