---
name: oinsights
description: "세션 분석 + 토큰 최적화 + 자동 개선 통합 스킬. 과거 세션 마찰 분석, 컨텍스트 토큰 절감, LESSONS 정리, 잔여 정리를 일괄 수행. 수동 호출: '/oinsights'."
invocation:
  user_callable: true
  pipeline_callable: false
  called_by: [사용자]
  calls: []
---

# oinsights — 세션 분석 + 토큰 최적화 + 자동 개선 통합 스킬

> 과거 세션 데이터 분석 + 컨텍스트 토큰 최적화 + LESSONS 정리 + 잔여 정리를 일괄 수행.
> **수동 전용**: `/oinsights` 호출 시만 실행.

---

## 설계 원칙

```yaml
목적: 세션 마찰 분석 → 토큰 최적화 → 자동 개선을 단일 스킬로 통합
위치: 유틸리티 스킬 (파이프라인 외부, 독립 실행)
실행: 메인 에이전트가 직접 실행 (팀에이전트 불필요)
언어: 모든 출력 한국어
범용: 프로젝트 고유 경로/설정 없음. 모든 프로젝트에서 동일 동작.

핵심_차별점:
  /insights: 100개 세션 샘플링 → HTML 리포트 (읽기 전용)
  /oinsights: 전체 데이터 접근 → 패턴 분석 + 토큰 최적화 → 자동 수정
```

---

## 실행 흐름 요약

```
/oinsights
  │
  ├─ Phase 0: 백업 (CLAUDE/MEMORY/LESSONS/SKILL 안전 백업)
  │
  ├─ Phase 1: 데이터 수집 (4개 소스 병렬 집계)
  │   ├─ 1-1. session-meta 집계
  │   ├─ 1-2. facets 마찰 분석
  │   ├─ 1-3. LESSONS.md 반복 패턴 분석
  │   └─ 1-4. 트랜스크립트 마찰 검색 (선택적)
  │
  ├─ Phase 2: 패턴 분석 (5개 관점 교차 분석)
  │   ├─ A. 반복 마찰
  │   ├─ B. 미해결 교훈
  │   ├─ C. 도구 효율
  │   ├─ D. 성공 패턴 확대
  │   └─ E. 프로세스 개선
  │
  ├─ Phase 3: 토큰 최적화 분석 (4축)
  │   ├─ 축A: MEMORY→CLAUDE 이관 후보
  │   ├─ 축B: CLAUDE→스킬 흡수 후보
  │   ├─ 축C: SKILL.md 200줄+ 최적화 후보
  │   └─ 축D: LESSONS→CLAUDE/스킬/hook 이관 후보
  │
  ├─ Phase 4: 개선 항목 통합 + 자동 적용
  │   ├─ 4-0. 미구현 교훈 선처리 (심각도=높음 + 미반영 → hook/스킬 구현)
  │   ├─ 세션 마찰 → hook/스킬/CLAUDE.md
  │   ├─ 토큰 최적화 → MEMORY 이관, CLAUDE→스킬, SKILL 압축
  │   ├─ LESSONS 정리 → 규칙화/hook차단/미규칙화/1회성
  │   └─ COMPACT 태그 부착
  │
  ├─ Phase 5: 결과 보고
  │   ├─ 세션 분석 결과 테이블
  │   ├─ 토큰 절감 Before/After 비교표
  │   └─ 적용 조치 목록 + 성공/실패
  │
  ├─ Phase 5.5: LESSONS.md 정리/압축
  │   ├─ 5.5-0. LESSONS.md 경로 감지
  │   ├─ 5.5-1. 4가지 정리 대상 감지
  │   ├─ 5.5-2~4. 선택→실행→보고
  │   └─ 분석 스크립트: python3 scripts/analyze_lessons_cleanup.py
  │
  ├─ Phase 6: 잔여 작업 일괄 정리
  │   ├─ 6-1. 고아 팀 삭제
  │   ├─ 6-2. 고착 파이프라인 IDLE 리셋
  │   └─ 6-3. session-env 디렉토리 정리
  │
  ├─ Phase 7: Git 커밋 & Push
  │   └─ 프로젝트 + AI 원본 커밋/push
  │
  └─ Phase 8: /tmp 히스토리 프로세스 점검
      └─ 세션 히스토리 오류 패턴 분석 → references/PHASE8.md 참조
```

---

## Phase 0: 백업 (Phase 1 전 필수)

```yaml
시점: Phase 1 분석 시작 직전
대상:
  - CLAUDE.md (프로젝트 루트, NTFS → cp로 읽기)
  - MEMORY.md + topic 파일 전체 (ext4)
  - LESSONS.md (프로젝트 루트, NTFS → cp로 읽기)
  - 최적화 대상 SKILL.md 파일들
위치: ~/.claude/backups/
네이밍: {파일명}.{YYYYMMDD_HHMMSS}
보관: 동일 PREFIX별 최신 3세대, 초과분 자동 삭제
실패_시: 경고 출력 후 계속
```

> 상세: [OPTIMIZATION_TECHNIQUES.md](references/OPTIMIZATION_TECHNIQUES.md) — Phase 0 백업 스크립트

---

## Phase 1: 데이터 수집

> 4개 데이터 소스에서 분석용 데이터를 수집합니다.
> **컨텍스트 보호**: 원본 파일을 통째로 읽지 않고, 집계 스크립트로 요약만 추출합니다.

### 1-1. session-meta 집계

```yaml
경로: $HOME/.claude/usage-data/session-meta/*.json
수집_방법: Python 스크립트로 일괄 집계 (개별 파일 Read 금지)
집계_항목:
  - 총 세션 수, 기간 범위
  - tool_errors 상위 세션 (오류 5회 이상)
  - tool_error_categories 빈도 집계
  - 평균/최대 duration_minutes
  - 도구별 총 사용 횟수
  - lines_added/removed 총합
  - 세션당 평균 user_interruptions
출력: $HOME/.claude/session-env/${UUID}/logs/oinsights_session_meta_summary.json
```

**집계 스크립트:**
```bash
python3 scripts/collect_session_meta.py
```

### 1-2. facets 마찰 분석

```yaml
경로: $HOME/.claude/usage-data/facets/*.json
조건: facets 폴더가 비어있으면 이 단계 스킵 (경고 메시지 출력)
수집_방법: Python 스크립트로 일괄 집계
집계_항목:
  - friction_counts 유형별 빈도 (전체 합산)
  - outcome 분포 (fully/mostly/partially/not_achieved)
  - friction이 있는 세션의 friction_detail 전문
  - user_satisfaction_counts 분포
  - session_type 분포
출력: $HOME/.claude/session-env/${UUID}/logs/oinsights_facets_summary.json
```

**집계 스크립트:**
```bash
python3 scripts/collect_facets.py
```

### 1-3. LESSONS.md 반복 패턴 분석

```yaml
경로: {프로젝트_루트}/LESSONS.md
수집_방법: Grep으로 교훈 헤더 + 카테고리 + 심각도 추출
집계_항목:
  - 카테고리별 빈도 (계획/구현/테스트/문서화)
  - 심각도별 빈도 (높음/중간/낮음)
  - 최근 20개 교훈의 제목 + 날짜
  - 동일 키워드가 3회+ 반복되는 패턴 감지 (hook, pane, spawn, shutdown 등)
출력: $HOME/.claude/session-env/${UUID}/logs/oinsights_lessons_summary.json
```

**집계 스크립트:**
```bash
python3 scripts/collect_lessons.py
```

### 1-4. 트랜스크립트 마찰 검색 (선택적)

```yaml
경로: $HOME/.claude/projects/-mnt-c-DATA-Project-{project}/*.jsonl
조건: Phase 2에서 심층 분석이 필요한 세션만 대상 (전체 스캔 금지)
수집_방법: Grep으로 오류/마찰 키워드 히트 세션 필터 → 해당 세션만 부분 Read
키워드: "error", "blocked", "retry", "실패", "금지", "위반", "DENY", "exit code"
출력: $HOME/.claude/session-env/${UUID}/logs/oinsights_transcript_hits.json
제한: 최대 20개 세션, 세션당 히트 라인 ±5줄만 추출
```

**집계 스크립트:**
```bash
python3 scripts/collect_transcripts.py
```

---

## Phase 2: 패턴 분석 + 개선 항목 도출

> Phase 1의 4개 요약 JSON을 읽고, 교차 분석하여 개선 항목을 도출합니다.

### 2-1. 요약 파일 읽기

```yaml
필수: $HOME/.claude/session-env/${UUID}/logs/oinsights_session_meta_summary.json
필수: $HOME/.claude/session-env/${UUID}/logs/oinsights_lessons_summary.json
선택: $HOME/.claude/session-env/${UUID}/logs/oinsights_facets_summary.json (없으면 스킵)
선택: $HOME/.claude/session-env/${UUID}/logs/oinsights_transcript_hits.json (없으면 스킵)
```

### 2-2. 교차 분석 (에이전트가 직접 수행)

```yaml
분석_관점:
  A_반복_마찰:
    정의: facets friction_types + LESSONS 반복 키워드가 겹치는 패턴
    기준: 동일 유형 3회+ 출현
    출력: 반복 마찰 목록 (유형, 빈도, 관련 교훈 ID, 조치 상태)

  B_미해결_교훈:
    정의: LESSONS.md에 기록되었지만 hook/스킬로 물리 차단 미구현
    판별: LESSONS "수정" 키워드 있으나 hook 파일에 대응 로직 없음
    출력: 미해결 교훈 목록 (교훈 ID, 제목, 권장 조치)

  C_도구_효율:
    정의: session-meta에서 특정 도구의 오류율이 비정상적으로 높음
    기준: tool_errors / tool_calls > 10%
    출력: 비효율 도구 목록 (도구명, 호출수, 오류수, 오류율)

  D_성공_패턴_확대:
    정의: facets에서 primary_success가 반복되는 강점 영역
    출력: 확대 가능 성공 패턴 (유형, 빈도, 관련 도구)

  E_프로세스_개선:
    정의: 세션 평균 시간 / 인터럽트 / 오류 트렌드
    출력: 추세 요약 (개선/악화/안정)
```

### 2-3. 개선 항목 생성

```yaml
각 분석 관점에서 상위 항목을 추출하여 최대 8개 개선 항목 생성:
  형식:
    id: I-001
    카테고리: 반복마찰 | 미해결교훈 | 도구효율 | 성공확대 | 프로세스
    제목: 1줄 요약
    상세: 2-3줄 설명 (데이터 근거 포함)
    권장_조치: hook 추가 | 스킬 규칙 강화 | CLAUDE.md 정책 | MEMORY 기록 | 스킬 신규
    예상_효과: 마찰 N% 감소 | 재발 방지 | 효율 향상
    난이도: 낮음 | 중간 | 높음

출력: $HOME/.claude/session-env/${UUID}/logs/oinsights_improvements.json
```

---

## Phase 3: 토큰 최적화 분석

> CLAUDE.md + MEMORY.md + SKILL.md 토큰 현황을 분석하고 최적화 후보를 식별합니다.

### 3-1. 토큰 현황 분석

```yaml
분석_방법: wc -w × 1.3 (토큰 추정)
출력:
  CLAUDE_MEMORY_테이블: |
    | 파일 | 섹션 | 줄 수 | 토큰(추정) | 비율 |
  SKILL_테이블: |
    | 순위 | 스킬 | 줄 수 | 토큰(추정) | 비고 |
    (줄 수 내림차순, 200줄+ 강조)
  LESSONS_테이블: |
    | 교훈 ID | 요약 | 상태 | 비고 |
    (상태: 규칙화됨/hook차단됨/미규칙화/1회성)
```

> 상세: [OPTIMIZATION_TECHNIQUES.md](references/OPTIMIZATION_TECHNIQUES.md) — Phase 1 분석 bash 스크립트

### 축 A: MEMORY→CLAUDE 이관 후보 감지

```yaml
A1_CLAUDE_통합:
  설명: MEMORY.md 내용을 CLAUDE.md 해당 섹션으로 병합
  방법: MEMORY 항목을 CLAUDE.md 관련 섹션에 추가, MEMORY에서 삭제
  기준: CLAUDE.md에 이미 관련 섹션 존재 → 거기에 병합

A2_topic_파일_흡수:
  설명: MEMORY topic 파일을 CLAUDE.md/스킬/프로젝트문서로 흡수
  방법: 각 topic 내용을 적절한 목적지로 분배 후 topic 파일 삭제

A3_MEMORY_비우기:
  설명: 이관 완료 후 MEMORY.md 최소화 또는 비우기
  방법: 이관 불가 항목만 잔류, 나머지 삭제
```

### 축 B: CLAUDE→스킬 흡수 후보 감지

```yaml
B1_스킬_전용_상세_이관:
  설명: CLAUDE.md에서 특정 스킬에만 해당하는 규칙을 해당 SKILL.md로 이동
  방법: 해당 스킬에서만 참조하는 규칙 → 스킬 파일로 이동 + CLAUDE.md에서 삭제

B2_중복_제거:
  설명: CLAUDE.md ↔ SKILL.md 간 동일 내용 제거
  방법: SKILL.md에 이미 존재하면 CLAUDE.md에서 삭제 (SKILL.md 우선)
```

### 축 C: SKILL.md 200줄+ 대형 파일 최적화 후보

> 상세: [OPTIMIZATION_TECHNIQUES.md](references/OPTIMIZATION_TECHNIQUES.md) — C1~C5 기법 (코드블록 압축, 산문 구조화, deprecated 정리, 조건부 로딩 분리, 반복 패턴 통합)

### 축 D: LESSONS→CLAUDE/스킬/hook 이관 후보

> 상세: [OPTIMIZATION_TECHNIQUES.md](references/OPTIMIZATION_TECHNIQUES.md) — D1~D5 기법 (규칙화 완료 삭제, hook 차단 완료 삭제, 미규칙화 이관, 1회성 삭제, LESSONS 비우기)

LESSONS.md 분석은 각 교훈(L-NNN)별로 아래 상태를 판정:
- **규칙화됨**: CLAUDE.md 또는 SKILL.md에 이미 해당 규칙이 존재 → 삭제 대상
- **hook차단됨**: hook 스크립트로 물리 차단 완료 → 삭제 대상
- **미규칙화**: 아직 규칙/hook으로 반영 안 됨 → 이관 대상 (CLAUDE.md 또는 SKILL.md로)
- **1회성**: 특수 상황, 규칙화 불가 → 삭제 대상

---

## Phase 4: 개선 항목 통합 + 자동 적용

> Phase 2(세션 마찰) + Phase 3(토큰 최적화)의 개선 항목을 통합하여 자동 순차 적용합니다.

### 4-0. 미구현 교훈 선처리 (Phase 1 분석 전 우선 처리)

```yaml
목적: LESSONS.md D_미적용(심각도=높음) 항목을 Phase 4 자동 적용 전에 hook/스킬로 구현
원칙: oinsights 실행 후 미구현 교훈이 남지 않도록 한번에 처리

절차:
  1. LESSONS.md에서 심각도=높음 + 반영추적 테이블 미등록(❌) 항목 식별
  2. 각 항목별 구현 대상 판별:
     - hook 수정 대상: .claude/hooks/*.sh
     - 스킬 수정 대상: .claude/skills/*/SKILL.md
     - CLAUDE.md 정책: CLAUDE.md
  3. Phase 2 분석 결과(B_미해결_교훈)와 교차 확인 후 우선순위 정렬
  4. /ok 파이프라인 경유 구현 (oplan_debate 검증 포함 — 아래 참조)
  5. LESSONS.md 반영 추적 테이블 업데이트 ✅

oplan_debate_연계:
  조건: 미구현 항목이 3개 이상 OR hook/스킬 핵심 로직 변경 포함
  방법: /o5 호출 → oplan_debate가 충분히 검증 후 구현
  기본: 미구현 항목 1~2개 단순 수정 → /o3 이상으로 처리
  목적: 검증 없이 hook을 수정하면 파이프라인 오작동 위험 존재

자동처리_제한:
  - oinsights 자체는 분석+문서 조작 도구 — 복잡한 hook 로직은 직접 구현 금지
  - 단순 방어코드(빈값 체크, 케이스 추가 등)만 Phase 4-0에서 직접 처리
  - 복잡한 로직 변경(알고리즘 수정, 신규 상태 추가 등)은 /ok 파이프라인으로 위임
```

### 4-1. 통합 적용 대상

```yaml
세션_마찰_개선:
  - hook 추가/수정
  - 스킬 규칙 강화
  - CLAUDE.md 정책 추가
  - MEMORY 기록
  - 스킬 신규 생성

토큰_최적화_개선:
  - MEMORY→CLAUDE 이관 (축A)
  - CLAUDE→스킬 흡수 (축B)
  - SKILL.md 압축 (축C)
  - LESSONS 이관/삭제 (축D)
```

### 4-2. 적용 절차

```yaml
방식: 전체 제안을 자동 순차 적용 (사용자 확인 없이 진행)
순서: 우선순위 높은 순서로 실행
로그: 각 적용 결과를 터미널에 출력
실패_항목: $HOME/.claude/session-env/${UUID}/logs/oinsights_deferred.json에 저장

조치_유형:
  hook_추가:    {대상: ~/.claude/hooks/, NTFS_주의: AI/.claude/hooks/ 원본 수정}
  스킬_강화:    {대상: skills/{스킬명}/SKILL.md}
  CLAUDE_md:   {대상: CLAUDE.md}
  MEMORY_기록: {대상: memory/MEMORY.md, 방법: 패턴기록}
  스킬_신규:   {대상: skills/{스킬명}/SKILL.md, 방법: 디렉토리+SKILL.md생성}

검증: 각 조치 후 수정파일목록 기록 + 요약1줄 출력 + 실패시 수동조치안내
```

### 4-3. COMPACT 태그 부착

```yaml
시점: CLAUDE.md에 규칙 이관 시
기준: compact 후 위반 빈도가 높은 핵심 규칙에만 부착
형식: 해당 규칙 줄 끝에 " [COMPACT]" 추가
용도: PostCompact hook이 grep '[COMPACT]'로 자동 추출하여 compact 후 리마인더에 포함
주의: 과도한 태그 부착 금지 (6~10개 이내 유지)
```

### 4-4. 참조 링크 형식

```yaml
원칙: 이관 시 원본에 참조 링크 필수 삽입 (정보 손실 방지)
형식:
  CLAUDE_md: "> 상세: [파일명](./파일명)"
  MEMORY_md: "> 상세: [topic-name.md](./topic-name.md)"
  SKILL_md_서브파일: "> 상세: [DETAIL.md](./DETAIL.md)"
  프로젝트문서: "→ [ADVANCED.md](./ADVANCED.md) 참조"

금지:
  - 참조 링크 없이 내용 삭제 (정보 손실)
  - 모호한 참조 ("스킬 파일 참조" → 구체 파일명+경로 필수)
```

---

## Phase 5: 결과 보고

```yaml
보고_형식: 터미널 마크다운 테이블
내용:
  세션_분석:
    - 분석대상: session-meta N개 / facets N개 / LESSONS N개 / 트랜스크립트 N개
    - 발견패턴: 반복마찰 N개 / 미해결교훈 N개 / 비효율도구 N개
  토큰_절감:
    - Before/After 비교표: | 파일 | Before(토큰) | After(토큰) | 절감 | 절감% |
    - 참조 무결성: 이관 파일 존재 + 참조 링크 대상 내용 존재 + 깨진 링크 0건
  적용_조치:
    - 파일별 변경내용 + 성공/실패
    - 미적용: oinsights_deferred.json 저장
  롤백_안내: |
    Phase 0에서 백업한 원본으로 복원 가능:
      NTFS 파일: cp ~/.claude/backups/{파일명}.{TS} → rsync
      ext4 파일: cp ~/.claude/backups/{파일명}.{TS} {원본경로}
  권장사항: "N일 후 재실행" / "facets 없으면 /insights 먼저"
```

---

## Phase 5.5: LESSONS.md 정리/압축

> **독립 실행 가능**: `/oinsights lessons` 명령으로 이 Phase만 단독 실행 가능.

### 5.5-0. LESSONS.md 경로 감지

```yaml
후보: [{프로젝트_루트}/LESSONS.md, Glob("**/LESSONS.md") fallback]
없으면: "⚠️ 미발견 — Phase 5.5 스킵" 후 Phase 6
```

### 5.5-1. 분석: 4가지 정리 대상 감지

```yaml
출력: $HOME/.claude/session-env/${UUID}/logs/oinsights_lessons_cleanup.json
대상:
  A_적용완료: L-번호가 스킬/hooks/CLAUDE.md에 참조됨 → 제거 후보
  B_중복:     교훈 간 키워드 겹침 50%+ → 중복 그룹 (대표 1개 유지)
  C_유사통합: 같은 키워드(pane/shutdown/hook/spawn 등) 공유 3개+ → 통합 후보
  D_미적용:   심각도=높음 AND 스킬/hooks/CLAUDE.md 미반영 → 적용 제안
```

**분석 스크립트:**
```bash
python3 scripts/analyze_lessons_cleanup.py
```

### 5.5-2~4. 선택 → 실행 → 보고

```yaml
적용_형식: 전체 자동 적용 (사용자 확인 없이 순차 실행)
옵션:
  - "적용완료 N개 제거" — 스킬/hooks/CLAUDE.md 반영 항목 삭제
  - "중복 N개 제거" — 키워드 겹침 50%+ 항목 중 최신/상세 1개 유지
  - "유사 N그룹 통합" — 공유 키워드 항목을 최저번호로 통합
  - "미적용 N개 적용" — 규칙 추가 후 LESSONS.md 제거

실행_검증:
  적용완료_제거: ### L-NNN 섹션 전체 삭제 → 헤더수 확인
  통합: 핵심내용 재작성 → 원본삭제+통합삽입 → 전후 항목수 비교
  미적용: 스킬/hook/CLAUDE.md에 규칙추가 → 파일 존재 확인
  NTFS_주의: oio 도구 사용 (자동 rsync)

결과_보고_테이블: [정리전→후교훈수, 제거ID+사유, 적용ID+위치, 카테고리별분포]
```

---

## Phase 6: 잔여 작업 일괄 정리

> **자동 수행** — 사용자 승인 불필요.
> **3단계 정리**: 고아 팀 삭제 → 고착 파이프라인 IDLE 리셋 → session-env 디렉토리 정리
>
> **[P2-isolation] §(a)(b)(d) 격리 원칙**: 자기 세션(MY_UUID) 소유 대상만 정리.
> 타 세션 session-env/ 쓰기/삭제 금지. 타 세션 팀 정리는 lazy orphan cleanup(team-cleanup.sh) 담당.

### 6-1. 고아 팀 삭제

```yaml
# [P2-isolation] §(b) 소유권 증명: leadSessionId == MY_UUID 확인 후 삭제만 허용.
# 타 세션 소유 팀(leadSessionId != MY_UUID) 삭제 절대 금지.
대상: ~/.claude/teams/ 하위 중 leadSessionId == MY_UUID인 팀만 (default 제외)
판정: 1) config.json.leadSessionId == MY_UUID  2) 해당 팀의 모든 멤버 pane이 tmux에서 소멸
방법: |
  MY_UUID="${UUID}"
  for team_dir in ~/.claude/teams/*/; do
    team=$(basename "$team_dir")
    [ "$team" = "default" ] && continue
    cfg="${team_dir}config.json"
    [ -f "$cfg" ] || continue
    # §(b): leadSessionId 검증 — 내 세션 소유가 아니면 스킵
    lead_id=$(python3 -c "import json,sys; d=json.load(open('$cfg')); print(d.get('leadSessionId',''))" 2>/dev/null || echo "")
    if [ "$lead_id" != "$MY_UUID" ]; then
      continue  # 타 세션 소유 팀 — 건드리지 않음
    fi
    ALL_DEAD=true
    for pane in $(python3 -c "import json;d=json.load(open('$cfg'));[print(m.get('tmuxPaneId','')) for m in d.get('members',[])]" 2>/dev/null); do
      [ -z "$pane" ] && continue
      tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qF "$pane" && ALL_DEAD=false
    done
    if $ALL_DEAD; then
      rm -rf "$team_dir" "$HOME/.claude/tasks/$team/" 2>/dev/null
      echo "✅ 내 세션 고아 팀 삭제: $team (leadSessionId=${MY_UUID:0:8}...)"
    fi
  done
```

### 6-2. 고착 파이프라인 IDLE 리셋

```yaml
# [P2-isolation] §(a)+(d): 자기 세션(MY_UUID) 만 대상.
# 타 세션 state 쓰기 금지 — §(d) "자기 세션만 boot-stale/heartbeat-stale 회수" 원칙.
# 타 세션 고착 회수는 각 세션의 SessionStart.sh 담당 (lazy orphan cleanup).
대상: 현재 세션(MY_UUID)이 비-IDLE 상태이고 agents/ pane 전수 소멸된 경우만
방법: |
  python3 << 'PYEOF'
  import os, subprocess, sys

  SESSION_BASE = os.path.expanduser("~/.claude/session-env")
  MY_UUID = os.environ.get("MY_UUID", "")
  if not MY_UUID:
    print("⚠️ MY_UUID 미설정 — 스킵")
    sys.exit(0)

  SESSION_OPS = "/mnt/c/DATA/Project/AI/MCP-Servers/oio-mcp-server/session_ops.py"
  sys.path.insert(0, os.path.dirname(SESSION_OPS))
  from session_ops import session_state

  # [P2-isolation] 자기 세션만 처리 (타 세션 uuid 루프 제거)
  dir_path = os.path.join(SESSION_BASE, MY_UUID)
  if not os.path.isdir(dir_path):
    print(f"⚠️ 자기 세션 디렉토리 없음: {MY_UUID[:8]}...")
    sys.exit(0)

  state_file = os.path.join(dir_path, "state")
  try:
    state = open(state_file).read().split()[0]
  except Exception:
    state = "IDLE"

  if state in ("IDLE", ""):
    print("✅ 이미 IDLE 상태 — 리셋 불필요")
    sys.exit(0)

  agents_dir = os.path.join(dir_path, "agents")
  agent_files = [f for f in os.listdir(agents_dir)] if os.path.isdir(agents_dir) else []

  if agent_files:
    all_dead = True
    tmux_panes = subprocess.run(
      ["tmux", "list-panes", "-a", "-F", "#{pane_id}"],
      capture_output=True, text=True
    ).stdout.splitlines()
    for fname in agent_files:
      fpath = os.path.join(agents_dir, fname)
      pane_id = ""
      try:
        for line in open(fpath):
          if line.startswith("pane_id="):
            pane_id = line.strip().split("=", 1)[1]
            break
      except Exception:
        pass
      if pane_id and pane_id in tmux_panes:
        all_dead = False
        break
    if all_dead:
      import shutil
      shutil.rmtree(agents_dir, ignore_errors=True)
      result = session_state(uuid=MY_UUID, key="state", value="IDLE", force=True)
      print(f"✅ 자기 세션 고착 파이프라인 IDLE 리셋 (agent 전수 소멸): {MY_UUID[:8]}...")
    else:
      print(f"ℹ️ 자기 세션 agent pane 생존 — 리셋 스킵 ({state})")
  else:
    result = session_state(uuid=MY_UUID, key="state", value="IDLE", force=True)
    print(f"✅ 자기 세션 고착 파이프라인 IDLE 리셋 (agent 없음): {MY_UUID[:8]}...")
  PYEOF
```

### 6-3. session-env 디렉토리 정리

```yaml
# [P2-isolation] §(a): 자기 세션(MY_UUID) 디렉토리는 보존.
# 타 세션 session-env/{other}/ 삭제 금지 — §(d) lazy orphan cleanup 원칙.
# 타 세션 정리는 각 세션의 SessionStart.sh가 자기 부팅 시 자기 디렉토리만 처리.
대상: 자기 세션(MY_UUID)의 7일+ 경과 logs/plans 빈 임시 파일 정리만 수행
보존: 현재 세션 전체 보존 (삭제 금지)
방법: |
  python3 << 'PYEOF'
  import os, time
  base = os.path.expanduser('~/.claude/session-env')
  my_uuid = '${MY_UUID}'
  now = time.time()
  # [P2-isolation] 자기 세션 내부 임시 파일(compact/ 하위 7일+ 경과)만 정리
  my_dir = os.path.join(base, my_uuid)
  if os.path.isdir(my_dir):
    compact_dir = os.path.join(my_dir, 'compact')
    if os.path.isdir(compact_dir):
      for f in os.listdir(compact_dir):
        fp = os.path.join(compact_dir, f)
        if os.path.isfile(fp) and (now - os.stat(fp).st_mtime) > 7*86400:
          os.remove(fp)
          print(f'🗑 compact 임시파일 정리: {f}')
  # 타 세션 디렉토리 삭제 완전 제거 — §(a) 준수
  # (과거 코드: 타 세션 IDLE+빈 디렉토리 shutil.rmtree → §(a) 위반으로 제거됨)
  print('✅ session-env 자기 세션 내부 정리 완료 (타 세션 불간섭)')
  PYEOF
```

---

## Phase 7: Git 커밋 & Push

> Phase 4 + Phase 5.5에서 수정된 파일을 커밋하고 push합니다.

```yaml
조건: Phase 4 또는 Phase 5.5에서 1개 이상 파일이 수정된 경우에만 실행
스킵: 적용 항목 모두 0개면 Phase 7 전체 스킵

수정_파일_위치_판별:
  프로젝트_파일: CLAUDE.md, LESSONS.md 등 → 현재 프로젝트 git
  스킬_hook_파일: .claude/skills/*, .claude/hooks/* → AI 원본 프로젝트 git
    경로: /mnt/c/DATA/Project/AI/ (심볼릭링크 원본)
  MEMORY_파일: ~/.claude/projects/*/memory/ → git 미추적 (커밋 불필요)

커밋_절차:
  1. 현재 프로젝트:
     git add {수정된 프로젝트 파일}
     git commit -m "🔧 oinsights 자동 개선 적용 — {적용 항목 수}개 by {모델버전}"
     git push

  2. AI 원본 프로젝트 (스킬/hook 수정 시):
     cd /mnt/c/DATA/Project/AI
     git add {수정된 스킬/hook 파일}
     git commit -m "🔧 oinsights 자동 개선 — {수정 대상 요약} by {모델버전}"
     git push

커밋_메시지_규칙:
  - 한국어 + 이모지 (CLAUDE.md 커밋 정책 준수)
  - 제목 마지막에 "by {모델버전}" 추가
  - Co-Authored-By 태그 포함

주의:
  - AI 프로젝트 push 시 다른 프로젝트에서 심볼릭링크로 자동 반영
  - MEMORY.md는 git 미추적이므로 커밋/push 불필요
```

---

## Phase 8: /tmp 히스토리 프로세스 점검

> **목적**: ofinish에서 보존된 세션 히스토리를 전체 분석하여 오류 패턴 + 프로세스 개선점 식별.
> **실행 시점**: /oinsights 호출 시 Phase 1~7과 독립적으로 선택 실행 가능.
> **상세**: [PHASE8.md](references/PHASE8.md) 참조 (Step 8-1~8-4 절차, Step 8-5는 §(a)(d) 위반으로 제거됨)

---

## 설정 및 경로

```yaml
데이터_소스:
  session_meta: $HOME/.claude/usage-data/session-meta/
  facets: $HOME/.claude/usage-data/facets/
  transcripts: $HOME/.claude/projects/-mnt-c-DATA-Project-{project}/
  lessons: {프로젝트_루트}/LESSONS.md
  memory: $HOME/.claude/projects/-mnt-c-DATA-Project-{project}/memory/MEMORY.md

임시_파일:
  - $HOME/.claude/session-env/${UUID}/logs/oinsights_session_meta_summary.json
  - $HOME/.claude/session-env/${UUID}/logs/oinsights_facets_summary.json
  - $HOME/.claude/session-env/${UUID}/logs/oinsights_lessons_summary.json
  - $HOME/.claude/session-env/${UUID}/logs/oinsights_transcript_hits.json
  - $HOME/.claude/session-env/${UUID}/logs/oinsights_improvements.json
  - $HOME/.claude/session-env/${UUID}/logs/oinsights_deferred.json
  - $HOME/.claude/session-env/${UUID}/logs/oinsights_lessons_cleanup.json

정리: 스킬 종료 시 oinsights_*.json 삭제하지 않음 (다음 실행 시 참조용)
```

---

## 제약 사항

```yaml
금지:
  - session-meta/facets 개별 파일을 Read 도구로 하나씩 읽기 (Python 집계만 허용)
  - 트랜스크립트 전체 파일 Read (Grep 히트 부분만)
  - LESSONS.md 전체 Read (Grep 키워드 → 해당 섹션만)

컨텍스트_보호:
  - Phase 1 출력은 JSON 요약만 (원본 데이터 컨텍스트 유입 금지)
  - 각 Phase 결과를 /tmp/ 파일로 저장하여 컨텍스트 재사용
  - 트랜스크립트 분석은 서브에이전트 위임 가능 (대규모 시)

NTFS_안전:
  - CLAUDE.md, SKILL.md는 /mnt/c/ 경로 → oio 도구 사용 (자동 rsync)
  - Edit/Write 직접 사용 금지 (drvfs 캐시 문제)

MEMORY_200줄_제한:
  - MEMORY.md는 200줄 이후 truncation
  - 최적화 후에도 200줄 이내 유지 확인

SKILL_서브파일_규칙:
  - 같은 스킬 디렉토리에 배치 (예: oinsights/references/PHASE8.md)
  - Skill() 호출은 SKILL.md만 로드 → 서브파일은 에이전트가 Read로 필요 시 로드
  - 서브파일명: 의미 있는 이름 (PHASE8.md, OPTIMIZATION_TECHNIQUES.md 등)

정보_품질:
  - 핵심 동작 규칙/흐름도는 절대 삭제 금지
  - "절대 규칙", "금지" 등 강제 규칙은 보존
  - 삭제 = 반드시 이관 대상 확인 후
  - 참조 링크 검증 필수
  - 의심스러우면 삭제하지 않고 이관만
```

---

## 실행 예시

```
$ /oinsights

📦 Phase 0: 백업 생성 중...
  ✅ CLAUDE.md, MEMORY.md, LESSONS.md 백업 완료

📊 Phase 1: 데이터 수집 중...
  ✅ session-meta: 371개 세션 (2026-02-25 ~ 2026-02-27)
  ✅ facets: 100개 세션 (마찰 10건 감지)
  ✅ LESSONS: 150개 교훈 (반복 키워드 12개)
  ✅ 트랜스크립트: 8개 세션에서 마찰 히트

🔍 Phase 2: 패턴 분석 중...
  반복 마찰: 3개 패턴 감지
  미해결 교훈: 2개 발견
  도구 효율: 1개 경고
  성공 패턴: 2개 확대 가능

📐 Phase 3: 토큰 최적화 분석 중...
  CLAUDE.md: 1,200 토큰 | MEMORY: 800 토큰 | SKILL 합계: 15,000 토큰
  축A 이관 후보: 3개 | 축B 흡수 후보: 2개 | 축C 200줄+: 5개 | 축D 이관: 8개

🔧 Phase 4: 개선 항목 통합 + 자동 적용 중...
  ✅ [1] pipeline_state_guard.sh 조건 수정 완료
  ✅ [2] CLAUDE.md Shell 규칙 추가 완료
  ✅ [3] MEMORY→CLAUDE 3개 항목 이관 완료
  ✅ [4] LESSONS 5개 교훈 규칙화+삭제 완료

📋 Phase 5: 결과 보고
  | 파일 | Before | After | 절감 | 절감% |
  |------|--------|-------|------|-------|
  | CLAUDE.md | 1,200 | 1,150 | -50 | -4% |
  | MEMORY.md | 800 | 200 | -600 | -75% |

🧹 Phase 5.5: LESSONS.md 정리
  적용완료 12개 제거 | 중복 3개 제거 | 통합 2그룹

🗑️ Phase 6: 잔여 정리
  고아 팀 2개 삭제 | IDLE 리셋 1개 | session-env 5개 정리

📝 Phase 7: Git 커밋 & Push
  ✅ 프로젝트 커밋 완료 | ✅ AI 원본 커밋 완료

🔎 Phase 8: 히스토리 점검
  오류 패턴 2개 감지 → LESSONS 승격 완료
```
