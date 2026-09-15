---
name: obr
description: "빌드+실행 동시 호출 — Skill('otest_build') + Skill('otest_run') 동시 실행."
invocation:
  user_callable: true
  pipeline_callable: true
  called_by: [ok_pipeline(o2), 사용자]
  calls: [otest_build, otest_run]
---
# obr — 빌드 + 실행

> otest_build + otest_run 동시 호출. 빌드+실행을 한 번에 수행.

## 실행 주체 (호출 경로별 분기) — 절대 규칙

```yaml
사용자_직접_호출 (/obr):
  실행: 메인이 직접 oio bash_exec로 실행
  이유: 파이프라인 비활성(IDLE) → write_guard 통과
  완료_보고: 불필요 (메인 자신이 결과 확인)
  팀에이전트_spawn: 절대 금지 (IDLE 상태에서 spawn은 낭비 + 오동작)

파이프라인_내_호출 (ok/o2):
  실행: 팀에이전트 spawn → Agent(name="otest-1", prompt="Skill('obr')...")
  이유: 파이프라인 활성(TEST) → write_guard가 메인 직접 실행 차단
  완료_보고: SendMessage 필수 (아래 참조)

write_guard_차단_대응 (절대 규칙):
  상황: 사용자 직접 /obr 호출 중 write_guard가 차단한 경우
  올바른_대응:
    1. 파이프라인 상태 확인 (write_guard 메시지의 상태명 확인)
    2. IDLE인데 차단됐으면: 상태 불일치 원인을 사용자에게 보고
    3. OK/PLAN/DEV 등 활성 상태이면: 파이프라인 내 호출로 간주 → 팀에이전트 spawn
  절대_금지: write_guard 차단 메시지만 보고 무조건 팀에이전트 spawn
```

## 절차

```yaml
Step_minus1_TeamCreate (otest 팀에이전트 spawn 전 필수):
  조건: $HOME/.claude/session-env/${UUID}/team_name 미존재 시
  절차:
    1. TeamDelete 시도 (이전 팀 잔류 정리) → 실패 시 무시하고 계속
    2. TeamCreate 실행
    3. team_name 저장: mcp__oio__session_state(uuid="${UUID}", key="team_name", value="{팀명}")
  주의: 이미 ok에서 TeamCreate한 경우 team_name 파일이 존재 → 스킵
```

```yaml
Step0_프로젝트_감지 (절대 규칙 — 스킵 금지):
  방법: CWD의 PROJECT.md 또는 *.sln 또는 main.py 등으로 현재 프로젝트 판별
  명령: |
    CWD=$(pwd)
    PROJECT=$(basename "$CWD" | tr '[:upper:]' '[:lower:]')
    echo "📦 프로젝트 감지: $PROJECT (CWD=$CWD)"
  적용: Skill('oinfra_{PROJECT}') 로딩 → oinfra_{PROJECT} 빌드/배포 섹션 자동 선택
  금지: 최근 작업 맥락이나 대화 내용으로 프로젝트를 추측하는 행위 (CWD만 신뢰)

Step0.5_인프라_로딩 (절대 규칙 — 스킵 금지):
  실행: Skill('oinfra_{PROJECT}') 호출
  목적: 빌드/배포 명령, 경로, 환경변수 등 프로젝트 고유 설정 로딩
  실패_시: oinfra_{PROJECT} 스킬이 없으면 경고 출력 후 otest_build/otest_run 기본 동작으로 진행

Step1_빌드_배포:
  Skill('otest_build') + Skill('otest_run') 동시 호출
  otest_build 실패 시: otest_run 중단
```

## 완료 보고 (파이프라인 내 호출 시)

```yaml
방법: SendMessage(to:"{리더명}", message:"obr 완료\notest_build + otest_run 동시 실행 성공", summary:"obr 빌드+배포 성공")
실패_시: SendMessage(to:"{리더명}", message:"obr 실패 — {실패 단계} 단계에서 오류\n{오류 요약}", summary:"obr 실패 {단계명}")

주의:
  - message가 문자열이면 summary 필수 (누락 시 즉시 오류)
  - structured message(shutdown_request 등)는 broadcast(to:"*") 불가 → 개별 전송만
```
