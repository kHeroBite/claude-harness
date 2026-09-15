# Lock 메커니즘 상세

> domain-fileops SKILL.md에서 분리된 상세 참조 문서

## Lock 파일 사양

```yaml
위치: 대상 파일과 동일 폴더
이름: .{원파일명}.lock
보조: .{원파일명}.lockdir (원자적 생성용 디렉토리)

내용 (3줄):
  Line 1: 세션 ID
  Line 2: PID
  Line 3: Unix timestamp (Lock 생성 시각)

예시:
  대상: /mnt/c/work/MyApp/FormMain.cs
  Lock: /mnt/c/work/MyApp/.FormMain.cs.lock
  Dir:  /mnt/c/work/MyApp/.FormMain.cs.lockdir
```

## Lock 프로세스 (7단계)

```yaml
1_Lock_확인:
  동일 폴더에 .{원파일명}.lock 존재 여부 확인

2_Lock_존재_시_Stale_검사_및_대기:
  a. Lock 파일 내용 읽기 (세션ID, PID, timestamp)
  b. Stale 판정 (아래 조건 중 하나라도 해당):
     - PID가 더 이상 존재하지 않음 (kill -0 $PID 실패)
     - TTL 만료 (현재시간 - timestamp > 3600초 = 60분)
  c. Stale이면:
     - lockdir + lock 파일 강제 삭제
     - 경고 로그: "⚠️ Stale Lock 자동 해제: {파일} (세션: {ID})"
     - 3단계로 진행
  d. Stale 아니면:
     - 1초 간격 재확인 (최대 30회 = 30초)
  e. 30초 대기 후에도 Lock 존재:
     - 실패 반환 (상위 레이어에 위임)

3_Lock_생성_원자적:
  방법: mkdir ".{원파일명}.lockdir"
  원리: mkdir은 OS 레벨 원자적 연산 — POSIX 표준, NTFS(drvfs)에서도 보장
  성공:
    - Lock 파일(.{원파일명}.lock) 생성
    - 내용 기록: 세션ID + PID + timestamp (3줄)
  실패 (다른 세션이 먼저 생성):
    - 1단계로 돌아가 재시도
  lockdir: Lock 파일 기록 완료 후에도 유지 (Lock 존재 표시)

4_파일_수정:
  환경별 절차 자동 적용 (의사결정 매트릭스 참조)

5_Lock_제거:
  전제: 내 세션 소유 확인 (Lock 파일의 세션ID == 내 세션ID)
  절차:
    - Lock 파일(.{원파일명}.lock) 삭제
    - lockdir(.{원파일명}.lockdir) 삭제
  안전장치: 타 세션 Lock은 절대 삭제 금지

6_파일_삭제_시에도_Lock_적용:
  이유: 다른 세션이 동시에 해당 파일을 수정 중일 수 있음
  절차: 1~5단계 동일 적용 (수정 대신 삭제 수행)

7_파일_생성_시_Lock_불필요:
  이유: 신규 파일은 아직 다른 세션이 참조 불가
  예외: 동명 파일 재생성(삭제 후 생성)은 삭제 Lock 해제 후 진행
```

## 원자성 보장 (Race Condition 해결)

```yaml
문제: 세션A "Lock 없음" → 세션B "Lock 없음" → 둘 다 Lock 생성 시도

해결: mkdir 원자적 연산
  세션A: mkdir ".foo.cs.lockdir" → 성공 (OS가 원자성 보장)
  세션B: mkdir ".foo.cs.lockdir" → 실패 (이미 존재)
  세션B: 1단계로 돌아가 재시도

왜_mkdir:
  - noclobber (set -C; > file): bash 전용, 서브셸 간 비일관
  - mkdir: POSIX 표준, 모든 파일시스템에서 원자적
  - NTFS(drvfs)에서도 mkdir 원자성 보장
```

## Stale Lock 자동 해제

```yaml
판정_조건 (OR — 하나라도 해당):
  PID_사망: kill -0 $PID 2>/dev/null → 실패 = 프로세스 종료
  TTL_만료: (현재시간 - timestamp) > 3600초 (60분)

자동_해제_절차:
  1. Stale 확정
  2. lockdir + lock 파일 모두 삭제
  3. 경고 로그 출력
  4. 정상 Lock 생성으로 진행
```
