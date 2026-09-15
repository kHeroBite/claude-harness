---
name: odev_simplify
description: "코드 단순화/효율화. 재사용성, 불필요한 복잡도, 중복 코드 검증 + 수정. Auto-activates when: medium/full scale implementation completed."
invocation:
  user_callable: false
  pipeline_callable: true
  called_by: ["odev_review(o3+)"]
  calls: []
---
# odev_simplify — 코드 단순화/효율화

## 목적

구현 완료된 코드에서 **재사용성, 품질, 효율성** 문제를 발견하고 직접 수정합니다.
에이전트의 구조적 한계(컨텍스트 제한, 목표 지향 편향, 탐색 비용 회피)로 발생하는 비효율을 잡아냅니다.

## 발동 조건

```yaml
자동_발동:
  O3: 무조건 발동
  O4/O5: 무조건 발동
스킵:
  O1: 스킵
  O2: 스킵

판정_소스: $HOME/.claude/session-env/${UUID}/classification
  - "O3" 또는 "O4" 또는 "O5" → 발동
  - "O2" 또는 "O1" 또는 파일 없음 → 스킵
```

## 호출 위치

```yaml
호출자: odev_review (2-2 단계)
시점: 코드 리뷰 2단계(Code Quality) 완료 직후
순서: odev_review → odev_simplify → otest

조건_분기 (odev_review 내부):
  1. odev_review 2단계 검증 완료
  2. 분류 파일 확인: cat $HOME/.claude/session-env/${UUID}/classification
  3. O3|O4|O5 → odev_simplify 발동
  4. O2 또는 O1 또는 파일 없음 → 스킵, otest로 직행
```

## 실행 주체

```yaml
실행: 메인이 팀에이전트로 spawn (메인 직접 실행 금지)
이유: 메인 컨텍스트 보호 + 파이프라인 일관성
팀에이전트_추가_spawn_금지: 서브에이전트(Agent tool) 필요 시 팀에이전트 내부에서 직접 spawn. 추가 팀에이전트 필요 시 메인에게 SPAWN_REQUEST 위임.
```

## 에이전트 유형

```yaml
유형: general-purpose (코드 읽기 + 수정 필요)
모델: Sonnet
제약: 수정된 파일 범위 내에서만 변경 (새 파일 생성 금지)
```

## 검증 항목 (체크리스트 5항목)

```yaml
1_중복_코드:
  기준: 3줄+ 동일/유사 코드 블록 반복
  조치: 공통 메서드 추출 또는 기존 유틸리티 호출로 교체
  도구: diff 기반 패턴 매칭 + Serena find_symbol (기존 유틸 탐색)

2_불필요한_복잡도:
  기준: 메서드 50줄 초과, 중첩 depth 3 초과, 과도한 분기
  조치: 메서드 분리, early return, 조건 단순화
  주의: 분리가 오히려 복잡해지면 유지 (강제 분리 금지)

3_기존_유틸리티_재구현:
  기준: 프로젝트에 이미 존재하는 헬퍼/유틸을 모르고 새로 작성
  조치: 기존 유틸리티 호출로 교체
  도구: Serena find_symbol (프로젝트 내 유사 메서드 탐색)

4_미사용_코드:
  기준: 추가된 using, 변수, 메서드 중 참조 0건
  조치: 제거
  도구: Serena find_referencing_symbols

5_매직넘버_하드코딩:
  기준: 의미 불명확한 리터럴 값 (if x == 42, timeout = 5000)
  조치: 상수(const) 추출 + 의미 있는 이름 부여
  예외: 0, 1, -1, "", null 등 관용적 리터럴은 허용
```

## 실행 절차

```yaml
1_범위_확정:
  - 수정 파일 목록 수집: $HOME/.claude/session-env/${UUID}/file_assignment.json 또는 git diff --name-only
  - .cs 파일만 대상 (Designer.cs 제외)

2_diff_기반_경량_분석:
  - 각 파일의 변경된 부분만 읽기 (전체 파일 X)
  - 체크리스트 5항목 대조
  - 기존 유틸리티 탐색: 변경 파일이 속한 프로젝트의 Utils/Helpers/Common 경로 스캔

3_문제_수정:
  - 발견 즉시 직접 수정 (보고만 하고 끝내지 않음)
  - Serena 심볼 편집 우선, Fallback은 Claude Code Edit (NTFS rsync 절차 준수)
  - 수정 후 기존 동작 변경 없음 확인 (리팩토링만, 기능 변경 금지)

4_결과_기록:
  파일: $HOME/.claude/session-env/${UUID}/logs/odev_simplify_${CONV_ID}.md
  형식: |
    # Simplify 결과
    ## 판정: ✅ CLEAN (수정 없음) / 🔧 FIXED (N건 수정)
    ## 수정 내역
    | 파일 | 항목 | 수정 전 | 수정 후 |
    (수정 없으면 이 섹션 생략)

5_완료_통보:
  방법: SendMessage → 호출자(odev_review 또는 메인)
  내용: "odev_simplify 완료 — CLEAN 또는 FIXED N건 + 파일 경로"
```

## 금지 사항

```yaml
금지:
  - 기능 변경 (리팩토링/단순화만 허용)
  - 새 파일 생성
  - 수정 범위 외 파일 변경
  - 주석/문서 추가 (코드 단순화만)
  - 과도한 추상화 도입 (3회 미만 반복은 인라인 유지)
  - 전체 파일 읽기 (diff 범위만)
```

## 코딩 규칙 참조

```yaml
프로젝트_규칙: {project}/PROJECT.md "코딩 규칙" 섹션 참조 (on-demand)
공통:
  - 공유 라이브러리 Queries/*.cs = 쿼리 문자열만 (DB 로직 금지, 경로: {project}/PROJECT.md "코딩 규칙" 섹션)
  - SQL은 Queries 클래스에서만 정의
  - 전역 상태 직접 변경 금지
```
