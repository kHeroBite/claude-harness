---
name: odev_lock
description: "App-level 의도 Lock. 작업 단위 파일 목록 선점, 세션 간 충돌 방지, Stale Lock 자동 해제. Auto-activates when: multi-session conflicts."
invocation:
  user_callable: false
  pipeline_callable: true
  called_by: ["odev(진입/충돌)"]
  calls: []
---
# odev_lock — App-level 의도 Lock

> Type A(동일 세션 내 병렬 에이전트 충돌): odev_parallel 참조 (파일 할당 매트릭스가 유일 출처)

## 2계층 Lock 아키텍처

```yaml
App-level (이 스킬 — odev_lock):
  역할: 트랜잭션 관리자 — "이 파일들을 작업할 예정" 선언
  단위: 작업 전체 (TODO 파일 목록)
  생명주기: odev 진입 ~ odone 완료 (분~시간)
  저장: {프로젝트}/.claude/locks/intent_{세션ID}.json

Low-level (oio MCP):
  역할: 파일시스템 드라이버 — 단일 파일 수정 시 물리 Lock
  단위: 단일 파일
  생명주기: oio file_edit/write 호출 시 자동 acquire/release (초 단위)
  저장: oio 내부 File Mutex (lock_manager)
  도구: mcp__oio__lock_status로 현황 확인

관계: odev_lock(의도 선언) + oio MCP(물리 Lock) — 독립 2계층, 직접 호출 관계 없음
중복: 없음 — 계층이 다름 (의도 선언 vs 물리 Lock)
```

## tier별 적용

```yaml
| tier | odev_lock 적용 | 사유 |
|------|:---:|------|
| o2 | 스킵 | 단일 에이전트, 충돌 불가 |
| o3 | 조건부 | 에이전트 2+이거나 다중 세션 시 |
| o4 | 필수 | 다중 에이전트 + 아키텍처 변경 |
| o5 | 필수 | 대규모 병렬 수정 |
```

## 의도 Lock 사양

```yaml
저장소: {프로젝트}/.claude/locks/
파일명: intent_{세션ID}.json
공유: WSL ↔ Windows 모두 접근 가능 (같은 NTFS)

JSON_구조:
  {
    "session_id": "abc-123-def",
    "pid": 54321,
    "timestamp": 1739808000,
    "classification": "O4",
    "files": [
      "FormMain.cs",
      "FormMain.Designer.cs",
      "Utils/DataHelper.cs"
    ]
  }

필드:
  session_id: 세션 식별자 ($CLAUDE_SESSION_ID 환경변수)
  pid: 프로세스 ID (Stale 감지용)
  timestamp: Unix timestamp (TTL 계산용)
  classification: 작업 분류 (O1/O2/O3/O4/O5)
  files: 수정 예정 파일 상대경로 목록 (TODO에서 추출)
```

## Lock 생명주기

```
oplan 완료 ──충돌 사전 검사──→ odev 진입 ──의도 Lock 획득──→ 구현
                                                            │
                                                            ▼
                            odone 완료 ──의도 Lock 해제──← otest
```

```yaml
사전_검사: oplan 완료 후
  기존 의도 Lock JSON 파일 스캔 → 파일 목록 교집합 확인
  충돌 없음 → odev 진행
  충돌 있음 → 대기 또는 비충돌 파일만 진행

획득: odev 진입 시 첫 동작
  intent_{세션ID}.json 생성 (파일 목록 등록)

유지: odev → otest → odone 전체 구간
  otest 실패 → odev 복귀 시에도 Lock 유지 (재획득 불필요)

갱신: timestamp 주기적 갱신
  obuild 시작, otest_run 시작, odone 시작 시 갱신
  이유: 장시간 작업 시 Stale 오판 방지

해제: odone 완료 직후
  intent_{세션ID}.json 삭제
```

## 의도 Lock 획득 절차

```yaml
절차:
  1. 프로젝트 .claude/locks/ 디렉토리 존재 확인 (없으면 생성)
  2. 기존 의도 Lock JSON 파일 스캔
  3. 각 JSON의 files 배열과 내 파일 목록 교집합 확인
  4. 충돌 판정:
     충돌_없음: intent_{세션ID}.json 생성 → 진행
     부분_충돌: 비충돌 파일만 JSON에 등록 → 충돌 파일은 대기 목록
     전체_충돌: 대기 (아래 충돌 대응 참조)
  5. Stale 검사 (충돌 Lock에 대해):
     PID 사망: kill -0 $PID 실패 → Stale → 해당 JSON 삭제
     TTL 만료: (현재시간 - timestamp) > 7200초 (120분) → Stale → 삭제
     정상: 대기
```

## Stale Lock 자동 감지

```yaml
감지_조건 (OR — 하나라도 해당):
  PID_사망: kill -0 $PID → 실패 = 프로세스 종료
  TTL_만료: (현재시간 - timestamp) > 7200초 (120분)

처리:
  1. Stale 확정 → 해당 intent_{세션ID}.json 삭제
  2. 로그: "⚠️ Stale 의도 Lock 자동 해제: 세션 {ID}"
  3. Lock 획득 재시도

검사_시점:
  - odev 진입 시 (의도 Lock 획득 시)
  - 충돌 대기 중 재시도 시

TTL_차이:
  App-level: 120분 (작업 단위 — 장시간)
  Low-level: 60분 (파일 단위 — 단시간)
```

## Lock 충돌 시 대응

### 부분 충돌 (일부 파일만 겹침)

```yaml
절차:
  1. 비충돌 파일 → 의도 Lock에 등록 → 즉시 작업 시작
  2. 충돌 파일 → 대기 목록에 기록
  3. 비충돌 파일 작업 완료 후 → 충돌 파일 재시도
  4. 재시도: 30초 간격, 최대 10회 (5분)
  5. Lock 획득 성공 시 → 🚨 재검토 필수 (아래 참조)
  6. 10회 초과 → ntfy 알림 + 사용자 보고
```

### 전체 충돌 (모든 대상 파일 겹침)

```yaml
절차:
  1. ntfy 알림 (priority:5, "전체 파일 Lock 충돌")
  2. 60초 간격 polling (최대 10회, 10분)
  3. 10회 초과 → 사용자에게 알림 후 대기
```

### 대기 중 사용자 보고 (Lock 획득 대기 시)

```yaml
대기_중_사용자_보고:
  주기: 5분마다
  내용: "⏳ Lock 대기 중 — {충돌 파일} ({경과 시간}분 경과). /odev_lock 중단하려면 알려주세요."
  TTL: 120분 초과 시 Stale 판정 → 자동 해제 (기존 규칙 유지)
  사용자_중단: 사용자 명시 요청 시 Lock 해제 + 파이프라인 중단
```

### 재검토 절차 (blocked 파일 Lock 획득 후 필수)

```yaml
원칙: |
  다른 세션이 Lock을 해제했다 = 해당 파일을 수정 완료했다.
  우리 세션의 계획은 수정 전 코드 기반으로 작성되었으므로,
  변경된 코드 위에서 계획이 여전히 유효한지 반드시 검토해야 한다.

재검토_절차:
  1. git diff로 다른 세션의 변경 내용 확인
     - git diff HEAD -- {blocked_file}
  2. 변경 영향도 판정:
     무관: 다른 세션 변경이 우리 수정 영역과 겹치지 않음
       → 그대로 진행
     호환: 겹치지만 우리 계획과 충돌하지 않음 (추가/보강 관계)
       → 변경 내용 반영하여 우리 수정 조정 후 진행
     충돌: 다른 세션 변경이 우리 계획과 직접 충돌
       → oplan 복귀 (해당 파일 관련 계획 재수립)
     무효화: 다른 세션이 우리가 하려던 작업을 이미 완료
       → 해당 파일 작업 목록에서 제외

재검토_금지사항:
  - 변경 확인 없이 수정 시작
  - git diff 없이 "아마 괜찮겠지" 판단
  - 충돌 발견 후 무시하고 덮어쓰기
```

## 병렬 에이전트 + 다중 세션 복합 시나리오

```yaml
시나리오: 팀에이전트(3명) 실행 중 + 다른 세션(1개) 존재

대응_절차:
  1. 다른 세션의 의도 Lock JSON 확인
  2. 충돌 파일을 파일 할당 매트릭스에서 제외
  3. 비충돌 파일만 팀원에게 할당
  4. 충돌 파일은 다른 세션 Lock 해제 후:
     a. git diff로 변경 확인 (재검토)
     b. 계획 유효성 판정
     c. 유효하면 순차 처리
```

## Wave 내 에이전트 간 잠금 경합 해소 (H-06)

```yaml
원칙:
  - 동일 Wave 내 에이전트는 동일 파일을 수정 대상으로 가질 수 없음 (oplan_parallel이 보장)
  - 읽기 전용 참조(reference)는 잠금 불필요
  - 잠금 획득 순서: 에이전트 번호 오름차순 (odev-1 → odev-2 → ...)
  - 교착 방지: flock -w 60 (60초 타임아웃) + 타임아웃 시 에이전트 비정상 반환

경합_시나리오_방지:
  oplan_parallel_보장: 파일 할당 매트릭스에서 동일 파일을 2개+ 에이전트에 수정 할당 금지 (ok_pipeline 구조 검증 4종 #2)
  만약_발생_시: 후순위 에이전트가 flock 타임아웃 → 메인에 비정상 보고 → 메인이 파일 재할당 후 재spawn
```

## 빌드 단계 충돌

```yaml
핵심_원칙: 다른 세션 파일의 빌드 오류는 수정하지 않고 대기

현재_다른_세션_판단:
  현재_세션: git diff --name-only 또는 이 세션에서 Edit/Write로 수정한 파일
  다른_세션: 위에 해당하지 않는 파일

다른_세션_파일_오류_시:
  절대_금지:
    - 다른 세션 작업 파일 수정
    - 임시 수정 후 원복
    - 오류 무시하고 진행
  필수_절차:
    1. 로그: "⏳ 다른 세션 파일 오류 - 대기 중: {파일명}"
    2. 대기: sleep 10 (10초 간격)
    3. 재시도: dotnet build 재실행 (최대 30회)
    4. 타임아웃: 5분 초과 시 ntfy 알림 후 사용자 보고

현재_세션_파일_오류_시: 즉시 수정 후 재빌드 (odev 복귀)
```

## 세션 비정상 종료 대비

```yaml
시나리오: odev~odone 사이에서 세션 비정상 종료

문제: 의도 Lock JSON 잔류 → 다른 세션이 해당 파일 작업 불가

대비:
  1. Stale 감지 (PID + TTL 120분)로 자동 해제
  2. 다른 세션에서 Lock 획득 시 PID 체크 → 죽은 프로세스면 즉시 해제
  3. 수동 해제: rm -f {프로젝트}/.claude/locks/intent_*.json
```

## 로그 경로

```yaml
의도_Lock: {프로젝트}/.claude/locks/intent_{세션ID}.json
수동_전체해제: rm -f {프로젝트}/.claude/locks/intent_*.json
```
