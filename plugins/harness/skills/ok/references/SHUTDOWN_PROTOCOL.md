# SHUTDOWN_PROTOCOL.md — 팀에이전트 종료 프로토콜

> 출처: ok SKILL.md, ok_pipeline SKILL.md, ofinish SKILL.md

## 2단계 shutdown 구조

### 1차 shutdown (메인 — 단계별 개별 즉시)
- 시점: 각 단계 에이전트 완료 수신 직후
- 방법: SendMessage(type="shutdown_request", recipient="{에이전트명}")
- 목적: 리소스 즉시 해제

### 2차 shutdown (ofinish Step 1 — 잔류 보충)
- 시점: ofinish Step 1 (직접 실행)
- 대상: isActive=true인 잔류 멤버만 (1차 shutdown 완료 멤버 스킵)
- 방법: fire-and-forget (approve 대기 없음)

## grace period 원칙 (P4 — shutdown 전 작업 완료 유예)

shutdown_request 발송 전 절차:
1. 에이전트가 idle 상태이면 → grace period 없이 즉시 shutdown_request 발송
2. 에이전트가 작업 중이면 (pane이 활성 상태):
   a. 먼저 텍스트 메시지 발송: SendMessage(to="{에이전트명}", message="작업을 마무리하고 완료 보고 후 대기하라", summary="마무리 후 대기")
   b. 20초 대기 (에이전트가 현재 작업 완료할 시간)
   c. 그 후 shutdown_request 발송
3. idle 판정 기준: agents/{에이전트명} 파일에 "shutdown_sent=true" 또는 완료 보고 수신 시

## fire-and-forget 원칙 (L-204)
- shutdown_request 발송만 수행. shutdown_response(approve) 대기 안 함
- 발송 후 즉시 Step 3(물리적 pane 정리)로 진행
- sleep 2~3초 짧은 grace period만 허용 (응답 대기와는 다름)

## 3단계 pane kill escalation
1. SIGTERM (kill PID)
2. SIGKILL (kill -9 PID) — 1단계 실패 시
3. tmux kill-pane — status off 상태에서만, 2단계 실패 시 최후 수단 (L-195)

## shutdown_with_verify 절차

> ok_pipeline SKILL.md의 "odev/otest/odone 완료 후 shutdown_with_verify 실행" 지시가 이 절차를 가리킨다.

1. SendMessage({type: "shutdown_request"}) 발송
2. 최대 30초 pane 소멸 대기 (5초 간격 확인)
3. 30초 내 미소멸 시: bash_exec "tmux kill-pane -t {PANE_ID}" kill escalation
   - kill escalation 순서: SIGTERM(kill PID) → SIGKILL(kill -9 PID) → tmux kill-pane (status off 상태에서만)
4. kill 후에도 pane 존재 시: 경고 로그 후 다음 단계 진행 (블로킹 금지)

## 금지
- shutdown_response 대기 루프
- 미응답 시 shutdown_request 재시도 (물리적 정리로 대체)
- tmux kill-window (L-114 — segfault 위험)
- send-keys exit (kill PID 대체, L-191)
