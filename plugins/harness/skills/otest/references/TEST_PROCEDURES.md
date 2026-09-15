# TDD 및 에러 수집 상세

> otest SKILL.md에서 분리된 상세 참조 문서

## TDD 강제 규칙 (해당 시)

```yaml
적용_조건: 단위 테스트 프레임워크 존재 시 (xUnit, NUnit 등)
Iron_Law: 실패하는 테스트 없이 프로덕션 코드 작성 금지
절차:
  1. RED: 실패 테스트 작성 → 실행 → 실패 확인 (실패 이유 = 기능 미구현)
  2. GREEN: 최소 코드로 테스트 통과 → 실행 → 통과 확인
  3. REFACTOR: 코드 정리 (테스트 유지)
금지:
  - 코드 먼저 작성 후 테스트 (tests-after = 구현 편향)
  - 테스트 즉시 통과 (기존 동작 테스트 중 → 테스트 수정 필요)
  - GREEN 단계에서 테스트 외 기능 추가 (YAGNI)
합리화_차단:
  - "너무 간단해서 테스트 불필요" → 간단한 코드도 깨짐
  - "나중에 테스트" → 즉시 통과 테스트는 증명 안 함
  - "이미 수동 테스트" → Ad-hoc ≠ 체계적, 재실행 불가
프로젝트별_예외: xUnit 미사용 프로젝트는 otest_run_{project}의 검증 방법이 TDD 대체
```

## 오류 실시간 기록

```yaml
시점: 빌드/런타임 오류 발생 즉시
대상: $HOME/.claude/session-env/${UUID}/logs/error_{대화ID}.md (대화ID = cat $HOME/.claude/session-env/${UUID}/conv_id)
형식: |
  ## [otest-Phase{1|2|3}] $(date -Iseconds)
  - 오류: {에러 메시지}
  - 해결: {해결 방법 | 미해결}
```

## 실패 보고 (Phase 실패 시)

```yaml
시점: Phase 실패 확정 즉시 (자체 재시도 포함 최종 실패)
방법: SendMessage(to:"{리더명}", message:"otest 실패 — Phase:{1|2|3}\n원인:{원인 1줄 요약}\n라우팅 권고:{odev|oplan}\n상세:$HOME/.claude/session-env/${UUID}/logs/error_{대화ID}.md", summary:"otest 실패 Phase {N}")

라우팅_권고_기준:
  Phase 1 (빌드/배포) 실패 → odev (코드 수정 필요)
  Phase 2 (런타임) 실패 → odev (일반) 또는 oplan (설계 결함)
  Phase 3 (품질) 실패 → oplan (요구사항 재검토)

금지:
  - 실패 보고 없이 자체 재시도 무한 반복
  - 실패 보고 없이 idle 전환
  - 라우팅 권고 누락
```
