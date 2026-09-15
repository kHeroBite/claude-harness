---
name: otest_run
description: "배포+구동+헬스체크 본체. otest_infra에서 호출. 프로젝트별 oinfra_{project} 배포 섹션 참조."
invocation:
  user_callable: false
  pipeline_callable: true
  called_by: ["otest_infra", "obr"]
  calls: ["oinfra_{project}"]
---
# otest_run — 배포+구동+헬스체크 본체

> **프로젝트별 배포 설정**: `oinfra_{project} "배포 설정" 섹션` 참조

## UUID 결정 (첫 번째 mcp__oio__bash_exec 명령)
> ⚠️ 모든 셸 명령은 `mcp__oio__bash_exec` 전용. Claude 내장 `Bash` 도구 사용 절대 금지 (write_guard.sh 차단)

```bash
UUID="${PIPELINE_UUID}"
mcp__oio__bash_exec(command='mkdir -p "$HOME/.claude/session-env/${UUID}/evidence"')
```

## 프로젝트 감지 (절대 규칙 — 스킵 금지)

```yaml
방법: CWD 기반 프로젝트 판별 (대화 맥락이 아닌 CWD만 신뢰)
명령: |
  CWD=$(pwd)
  PROJECT=$(basename "$CWD" | tr '[:upper:]' '[:lower:]')
  echo "📦 배포 대상: $PROJECT (CWD=$CWD)"
금지: 최근 작업 맥락이나 수정한 파일 경로로 프로젝트를 추측하는 행위
```

## 프로젝트별 자동 로딩

```yaml
방법: oinfra_{PROJECT} "배포 설정" 섹션 참조 (PROJECT = 위 감지 결과)
  - otest_run은 oinfra_{PROJECT}의 배포 설정 섹션을 참조하여 배포/구동 명령 실행
```

## 실행 절차

```yaml
전제: otest_build 완료(evidence/build_ok 존재) 확인 후 진행

1_배포_유형_결정:
  프로젝트별: oinfra_{project} "배포 설정" 섹션 매핑 테이블 참조
  대상_없음: 스킵 (비코드 파일만 변경)

2_배포_실행:
  로컬_실행:
    - 기존 프로세스 종료 (oinfra_{project} shutdown 명령)
    - 빌드된 바이너리 실행
    - 헬스체크 확인 (oinfra_{project} 헬스체크 참조)

  모바일_배포:
    - 에뮬레이터/디바이스 확인
    - APK 설치 (oinfra_{project} "배포 설정" 섹션 참조)
    - 앱 실행 및 로그 확인

  원격_서버_배포:
    - 배포 스크립트 실행 (oinfra_{project} "배포 설정" 섹션 참조)
    - 서비스 상태 확인

2.5_배포후_바이너리_검증 (원격 서버 배포 시 필수 — L-346/L-348):
  대상: self-contained 단일파일 ELF를 원격 서버에 배포한 경우
  목적: 배포 직후 실행 바이너리가 실제로 갱신됐는지 물리 검증. DB/SQL PASS만으로는 불충분.
  변수: 원격 접속·경로는 oinfra_{project} "배포 설정" 섹션의 값을 사용한다.
        ${REMOTE} = 원격 접속 대상(user@host), ${REMOTE_BIN} = 원격 실행 바이너리 경로,
        ${LOCAL_BIN} = 로컬 publish 산출물 경로, ${REMOTE_PID} = 원격 pid 파일 경로.
  절차:
    pid_기반_exe_확인: |
      PID=$(ssh ${REMOTE} "cat ${REMOTE_PID}")
      ssh ${REMOTE} "readlink /proc/${PID}/exe"
      # 결과가 ${REMOTE_BIN} 이어야 함 (단일파일이면 tmpdir 경로일 수 있음)
    md5_대조: |
      LOCAL_MD5=$(md5sum ${LOCAL_BIN} | awk '{print $1}')
      REMOTE_MD5=$(ssh ${REMOTE} "md5sum ${REMOTE_BIN}" | awk '{print $1}')
      # 반드시 LOCAL_MD5 == REMOTE_MD5 이어야 배포 유효
    심볼_grep: |
      ssh ${REMOTE} "strings ${REMOTE_BIN} | grep -c '이번_수정_핵심_함수명_또는_문자열'"
      # 결과가 0이면 FAIL — 이번 수정이 바이너리에 미포함
  통과_기준: md5 일치 AND grep count > 0
  실패_시: 재배포 수행 또는 odev 역라우팅 (FAIL로 처리)
  절대_금지: SQL/DB 헬스체크 통과만으로 배포 완료 선언. 바이너리 검증 없는 PASS 인정 불가.

3_증거_파일_생성:
  시점: 헬스체크/상태 확인 통과 직후
  deploy_ok: touch "$HOME/.claude/session-env/${UUID}/evidence/deploy_ok"  # EXT4($HOME) — oio 불필요
  run_ok: touch "$HOME/.claude/session-env/${UUID}/evidence/run_ok"  # EXT4($HOME) — oio 불필요
  ui_automation=true 프로젝트: touch "$HOME/.claude/session-env/${UUID}/evidence/app_restarted"  # EXT4($HOME) — oio 불필요
  확인: ls "$HOME/.claude/session-env/${UUID}/evidence/"
```

## 선택적 실행 규칙

```yaml
원칙: 빌드한 프로젝트만 재시작. 미빌드 프로세스 보호.
매핑: oinfra_{project} "배포 설정" 섹션의 배포_대상_매핑 테이블 참조
병렬: 복수 프로젝트 배포는 동시 실행
```

## 배포 실행 원칙

```yaml
핵심_원칙: 빌드 완료 즉시 배포 (빌드와 배포가 하나의 단위)
  - 각 프로젝트별로 빌드 → 배포를 연속 실행
  - 다른 프로젝트의 빌드 완료를 기다리지 않음

병렬_실행_예시:
  서버_프로젝트: 빌드 완료 → 즉시 원격 서버 배포
  클라이언트_프로젝트: 빌드 완료 → 즉시 프로세스 교체 (종료 → 실행)
  모바일_프로젝트: 빌드 완료 → 즉시 에뮬레이터/디바이스 설치
  상세: oinfra_{project} "배포 설정" 섹션 참조
```

## 팀에이전트 증거 UUID 규칙 (L-166)

```yaml
문제: 팀에이전트는 별도 세션에서 실행 → 자신의 SESSION_ID ≠ 파이프라인 소유자(메인) SESSION_ID
결과: 자신의 SESSION_ID 기반으로 파일 생성 시 메인이 찾는 경로와 불일치 → odone 영구 차단

필수_절차 (팀에이전트로 실행될 때):
  UUID="${PIPELINE_UUID}"
  touch "$HOME/.claude/session-env/${UUID}/evidence/deploy_ok"  # EXT4($HOME) — oio 불필요
  touch "$HOME/.claude/session-env/${UUID}/evidence/run_ok"  # EXT4($HOME) — oio 불필요

금지: 자신의 SESSION_ID로 SID 계산 후 증거 파일 생성
확인: 증거 파일 생성 후 ls $HOME/.claude/session-env/${UUID}/evidence/ 로 검증
```

## 완료 보고 (파이프라인 내 호출 시)

```yaml
방법: SendMessage(to:"{리더명}", message:"otest_run 완료\n{배포 대상 목록}\n증거: evidence/deploy_ok, evidence/run_ok", summary:"otest_run 배포 완료")
실패_시: SendMessage(to:"{리더명}", message:"otest_run 실패\n원인:{1줄}\n권고: odev 역라우팅", summary:"otest_run 배포 실패")
```
