# ok — Shutdown 절차 상세 (v3.2)

> ok SKILL.md의 shutdown 관련 상세 절차를 분리한 문서.
> 핵심 원칙은 ok SKILL.md에 유지, 이 문서는 구체 절차만 기술.
> **v3.2**: ok는 스킬(실행 지침) — 메인이 직접 shutdown 발송. pane 물리적 정리는 ofinish Step 1이 수행.
> **L-191**: send-keys exit 전면 폐기 → kill PID 방식으로 대체.

---

## 2단계 shutdown 구조 (v3.2 — L-204/L-205)

```yaml
구조:
  1차_개별_shutdown (메인 직접):
    시점: 각 파이프라인 단계 완료 시
    주체: 메인 (ok 지침에 따라)
    방식: SendMessage(type="shutdown_request") → fire-and-forget (응답 대기 안 함)
    목적: 완료된 에이전트 즉시 리소스 해제
    예시: oplan 완료 → oplan-1에 shutdown_request → odev spawn 진행

  2차_보충_shutdown (ofinish Step 1):
    시점: ofinish Step 1 (파이프라인 최종)
    주체: ofinish Step 1
    대상: agents/ 잔류 파일 보유 멤버만 (1차에서 이미 shutdown된 멤버 스킵)
    방식: 보충 shutdown_request + pane 물리적 정리 (kill PID)
    목적: 1차 누락/실패 보완

역할_분리:
  메인: shutdown_request 발송만 (fire-and-forget). pane 소멸 확인/kill PID 수행 금지.
  ofinish Step 1: pane 물리적 정리(소멸 확인 + kill PID + orphan 기록) 전담.
```

---

## 메인의 개별 shutdown 절차 (1차 — L-205)

각 파이프라인 단계 완료 시:

```yaml
각_단계_완료_시:
  1. 팀에이전트 완료 보고 수신 (SendMessage)
  2. 즉시 SendMessage(type="shutdown_request", recipient="{에이전트명}") 발송
  3. 응답 대기 안 함 (fire-and-forget — L-204)
  4. 즉시 다음 단계 진입
  주의: pane 소멸 확인/kill PID는 메인이 수행하지 않음 → ofinish Step 1이 최종 정리
```

---

## 일괄 shutdown 운영 규칙

```yaml
shutdown_즉시_처리 (최우선 행동 규칙):
  - 매 턴 시작 시 미처리 완료 보고가 있는지 inbox 전체 스캔
  - 완료 보고가 있으면 다른 모든 작업보다 shutdown_request 발송을 최우선 처리
  - "대기 중" 텍스트 출력 후 턴 종료 금지 — 할 일이 있으면 반드시 처리 후 종료

일괄_shutdown_패턴:
  - 한 턴에 수신된 완료 보고 전부에 대해 shutdown_request를 병렬로 발송
  - SendMessage(shutdown_request)를 여러 개 한 턴에 호출 가능
  - 예: odev-1, odev-2 동시 완료 → 같은 턴에 shutdown_request 2개 발송
```

---

## ofinish Step 1의 pane 정리 절차 (2차 — L-191/L-155)

> 상세: ofinish SKILL.md Step 1 참조 (실제 정리 수행 주체)

```yaml
pane_정리_요약:
  1. agents/ 디렉토리에서 잔류 파일 보유 멤버 식별
  2. 잔류 멤버에 보충 shutdown_request 발송 (fire-and-forget)
  3. pane 물리적 정리:
     a. 소멸 확인: tmux display-message -t {paneId} -p '#{pane_id}' 2>/dev/null
        - 실패 → 소멸 (완료)
        - 성공 → 잔류 → kill PID 정리
     b. kill PID 강제 정리 (미소멸 pane 전용):
        tmux set -g status off
        kill "$PANE_PID" → sleep 2 → kill -9 → tmux kill-pane (3단계 escalation)
        tmux set -g status on
     c. 미소멸 시 재시도 (최대 3회)
     d. 3회 후 미소멸 → orphan 기록
  4. BEFORE 스냅샷 diff 기반 미등록 pane 감지 + 정리
  5. TeamDelete

금지:
  - 소멸 확인 없이 pane 정리 (L-155)
  - tmux kill-window (segfault 위험 — L-114)
  - send-keys exit (L-191: kill PID 방식으로 대체)
  - BEFORE diff 새 pane 중 소속 불명 pane kill (L-213: 다른 세션 에이전트 보호)
```

---

## 팀에이전트 측 shutdown 프로토콜

```yaml
에이전트_지시 (spawn 프롬프트에 포함):
  - "작업 완료 후 SendMessage로 메인(team-lead)에 보고"
  - "shutdown_request 수신 시 즉시 approve"
  - shutdown_response 후 Claude Code가 프로세스 종료 → pane은 bash 상태로 잔류 가능
  - bash 잔류 pane은 ofinish Step 1이 kill PID로 정리
```

---

## 참조

- **L-136**: shutdown_request가 기본 종료 프로토콜 (미발송 시 에이전트 영원히 idle)
- **L-155**: 소멸 확인 → kill PID → orphan 기록 (판별 없이 정리 절대 금지)
- **L-191**: send-keys exit 전면 폐기 → kill PID 방식 대체
- **L-204**: shutdown_request fire-and-forget — 발송만 하고 응답 대기 없이 다음 진행
- **L-205**: 완료 즉시 shutdown_request — idle 방치 금지
- **L-213**: BEFORE diff pane 소속 불명 시 절대 kill 금지
