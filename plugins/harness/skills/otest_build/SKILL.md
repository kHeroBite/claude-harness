---
name: otest_build
description: "빌드 실행 본체. otest_infra에서 호출. 프로젝트별 oinfra_{project} 빌드 섹션 참조."
invocation:
  user_callable: false
  pipeline_callable: true
  called_by: ["otest_infra", "obr"]
  calls: ["oinfra_{project}"]
---
# otest_build — 빌드 실행 본체

> **프로젝트별 빌드 명령**: `oinfra_{project} "빌드 방법" 섹션` 참조

## UUID 결정 (첫 번째 mcp__oio__bash_exec 명령)
> ⚠️ 모든 셸 명령은 `mcp__oio__bash_exec` 전용. Claude 내장 `Bash` 도구 사용 절대 금지 (write_guard.sh 차단)

```bash
UUID="${PIPELINE_UUID}"
mcp__oio__bash_exec(command='mkdir -p "$HOME/.claude/session-env/${UUID}/evidence" "$HOME/.claude/session-env/${UUID}/logs"')
```

## 프로젝트 감지 (절대 규칙 — 스킵 금지)

```yaml
방법: CWD 기반 프로젝트 판별 (대화 맥락이 아닌 CWD만 신뢰)
명령: |
  CWD=$(pwd)
  PROJECT=$(basename "$CWD" | tr '[:upper:]' '[:lower:]')
  echo "📦 빌드 대상: $PROJECT (CWD=$CWD)"
금지: 최근 작업 맥락이나 수정한 파일 경로로 프로젝트를 추측하는 행위
```

## 프로젝트별 자동 로딩

```yaml
방법: oinfra_{PROJECT} "빌드 방법" 섹션 참조 (PROJECT = 위 감지 결과)
  - otest_build는 oinfra_{PROJECT}의 빌드 방법 섹션을 참조하여 빌드 명령 실행
```

## 빌드 절차

```yaml
1_프로세스_종료:
  자동화: prebuild_shutdown.sh Hook이 dotnet build 감지 시 자동 shutdown+taskkill
  수동_Fallback: oinfra_{project}의 shutdown 명령 참조

2_빌드_실행:
  명령: oinfra_{project} "빌드 방법" 섹션 참조
  포그라운드/백그라운드: oinfra_{project} 설정 따름
  성공_감지: "Build succeeded"
  실패_감지: "Build FAILED"

3_증거_파일_생성:
  시점: "Build succeeded" 확인 직후
  명령: touch "$HOME/.claude/session-env/${UUID}/evidence/build_ok"  # mcp__oio__bash_exec 사용
  확인: ls "$HOME/.claude/session-env/${UUID}/evidence/"
```

## 증거파일 검증 규칙

```yaml
규칙: evidence mtime > pipeline_start_time
  - 증거 파일의 수정 시간이 파이프라인 시작 시간보다 이후여야 유효
  - 오래된 증거 파일(이전 세션 생성) 무효 처리

적용_대상: otest_build, otest_run 모든 증거 파일

UUID_규칙 (팀에이전트):
  사용: PIPELINE_UUID 환경변수만 사용
  금지: resolve_uuid() 호출 (팀에이전트 세션 ID ≠ 메인 UUID)
  변수: UUID="${PIPELINE_UUID}" 로 설정 후 사용
  경로: $HOME/.claude/session-env/${PIPELINE_UUID}/evidence/
```

## 빌드 대상 자동 감지

```yaml
방법: git diff --name-only HEAD → 변경 파일의 최상위 폴더 → oinfra_{project} 빌드 섹션 매핑 테이블 참조
공유_라이브러리_수정: 참조 프로젝트 전체 빌드 (oinfra_{project} 빌드 섹션 참조)
비코드_파일만_변경: 빌드 스킵 (증거 파일 없이 통과)
```

## 빌드 오류 대응

```yaml
현재_세션_수정_파일: 즉시 수정 후 재빌드
다른_세션_파일: odev_lock (수정 금지, 대기)
최종_실패: odev 역라우팅 권고
```

## background 빌드 증거 수집 주의

```yaml
문제: run_in_background 빌드는 PostToolUse에 stdout 비어있음
자동_캡처: tail/cat(Bash)으로 결과 읽으면 evidence_gate 자동 감지
Fallback: Read 도구로 결과 읽은 경우 → 수동 touch 필수
  touch "$HOME/.claude/session-env/${UUID}/evidence/build_ok"  # mcp__oio__bash_exec 사용
```

## 완료 보고 (파이프라인 내 호출 시)

```yaml
방법: SendMessage(to:"{리더명}", message:"otest_build 완료\n{빌드 대상 목록}\n증거: evidence/build_ok", summary:"otest_build 빌드 완료")
실패_시: SendMessage(to:"{리더명}", message:"otest_build 실패\n원인:{1줄}\n권고: odev 역라우팅", summary:"otest_build 빌드 실패")
```
