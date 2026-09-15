# Scout 상세

> oplan_deep SKILL.md에서 분리된 상세 참조 문서

## Scout 조사 범위

```yaml
코드_탐색:
  - 기존 유사 기능의 구현 패턴 (참조할 코드)
  - 수정 대상 심볼의 참조 추적 (find_referencing_symbols)
  - 관련 클래스/메서드의 시그니처 및 의존성

DB_확인:
  - 관련 테이블 스키마 (MCP mysql 조회)
  - 기존 쿼리 패턴 탐색
  - FK/인덱스 구조

문서_수집:
  - 관련 프로젝트 문서 (ADVANCED.md, DATABASE.md 등)
  - 기존 코딩 규칙 ({project}/PROJECT.md "코딩 규칙" 섹션)
```

## Scout 실행 절차

```yaml
1_Scout_디스패치:
  시점: Deep 진입 직후
  방법: Task(Explore) 서브에이전트 생성 (v3.2 flat team — TeamCreate 금지)
  결과: scratchpad 파일에 저장 → 요약 5줄 + 파일 경로 반환

2_리더는_설계_진행:
  Scout 결과 대기하지 않고 즉시 설계 시작
  Scout 결과 도착 시 참조하여 설계 보완

3_Scout_결과_활용:
  리더가 scout_report.md 읽고 설계에 반영
  필요 시 추가 조사 요청 (최대 1회)

제한:
  읽기_전용: 파일 수정/생성 절대 금지
  scratchpad_필수: 결과를 반환 메시지에 전체 포함 금지
  context_보호: 에이전트 1개당 탐색 파일 최대 10개
  에이전트_수: 최대 4개 (분석 작업 제한)
```

## 에이전트 역할별 유형

```yaml
# ── 탐색 계열 (Explore, Haiku) ──
scout-code:      코드 탐색 — 유사 패턴, 심볼 참조, 클래스 구조
scout-db:        DB 탐색 — 테이블 스키마, 쿼리 패턴, FK/인덱스
scout-docs:      문서 탐색 — 프로젝트 문서, 코딩 규칙, API 문서
scout-deps:      의존성 탐색 — NuGet 패키지, 외부 라이브러리 버전

# ── 분석 계열 (Explore/Plan, Sonnet) ──
analyzer-impact: 영향도 분석 — 변경 심볼 참조 추적, 파급 범위
analyzer-perf:   성능 분석 — 병목, N+1, 대용량 시나리오
analyzer-risk:   위험도 분석 — 사이드 이펙트, 호환성 파손

# ── 설계 계열 (Plan, Opus/Sonnet) ──
architect-alt:   대안 설계 — 접근법 2-3개 비교 분석
architect-proto: 프로토타입 설계 — 핵심 로직 구조 초안
planner-task:    Task 분해 — TODO 항목을 bite-sized 단위로 분할

# ── 검증 계열 (Explore, Haiku/Sonnet) ──
simulator-edge:  엣지케이스 시뮬레이션 — 계획의 경계값/예외 검증
reviewer-plan:   계획 리뷰 — 요구사항 준수 + 기술 타당성
verifier-exist:  존재 검증 — API/함수/테이블이 실제 존재하는지 확인
```

## 프리셋 조합 (빈출 패턴)

```yaml
새_기능_설계:
  에이전트: [scout-code, scout-db, analyzer-impact]
  리더: architect-alt 역할 직접 수행

대규모_리팩토링_설계:
  에이전트: [scout-code, analyzer-impact, analyzer-risk]
  리더: planner-task 역할 직접 수행

DB_스키마_변경_설계:
  에이전트: [scout-db, analyzer-impact]
  리더: architect-alt 역할 직접 수행

크로스_레이어_변경:
  에이전트: [scout-code, scout-db, scout-docs, analyzer-impact]
  리더: architect-proto 역할 직접 수행
```
