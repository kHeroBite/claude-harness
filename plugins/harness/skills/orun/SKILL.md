---
name: orun
description: "[alias] otest_run 래퍼"
invocation:
  user_callable: true
  pipeline_callable: true
  called_by: [otest, obr, 사용자]
  calls: []
---
# orun — 실행/배포

> **alias**: orun은 단독 호출 편의용. 실제 배포/구동 로직은 otest_run이 보유.
> 파이프라인 내에서는 otest_infra가 직접 Skill('otest_run') 호출.
> /orun 단독 호출 시: Skill('otest_run') 위임.

> **프로젝트별 배포 설정**: `oinfra_{project} "배포 설정" 섹션` 참조

## UUID 결정 (첫 번째 mcp__oio__bash_exec 명령)
> ⚠️ 모든 셸 명령은 `mcp__oio__bash_exec` 전용. Claude 내장 `Bash` 도구 사용 절대 금지 (write_guard.sh 차단)

```bash
source "${HARNESS_HOOK_DIR}/lib/session_id.sh"
resolve_uuid ""
mcp__oio__bash_exec(command='mkdir -p "$HOME/.claude/session-env/${UUID}/evidence"')
```

## 실행 절차

```yaml
전제: obuild 완료(evidence/build_ok 존재) 확인 후 진행

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

3_증거_파일_생성:
  시점: 헬스체크/상태 확인 통과 직후
  명령: touch "$HOME/.claude/session-env/${UUID}/evidence/deploy_ok"  # EXT4($HOME) — oio 불필요
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
  source "${HARNESS_HOOK_DIR}/lib/session_id.sh"
  resolve_uuid ""
  touch "$HOME/.claude/session-env/${UUID}/evidence/deploy_ok"  # EXT4($HOME) — oio 불필요

금지: 자신의 SESSION_ID로 SID 계산 후 증거 파일 생성
확인: 증거 파일 생성 후 ls $HOME/.claude/session-env/${UUID}/evidence/ 로 검증
```

## 완료 보고 (파이프라인 내 호출 시)

```yaml
방법: SendMessage(to:"{리더명}", message:"orun 완료\n{배포 대상 목록}\n증거: evidence/deploy_ok", summary:"orun 배포 완료")
실패_시: SendMessage(to:"{리더명}", message:"orun 실패\n원인:{1줄}\n권고: odev 역라우팅", summary:"orun 배포 실패")
```
