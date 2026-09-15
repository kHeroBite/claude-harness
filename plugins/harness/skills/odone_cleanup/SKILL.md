---
name: odone_cleanup
description: "코드 정리. 디버그 코드 변환, 테스트 코드 제거, Lock 해제."
invocation:
  user_callable: false
  pipeline_callable: true
  called_by: [odone(Full o4/o5)]
  calls: []
---
# odone_cleanup — 코드 정리

## 정리 항목

### 1. 디버그 코드 변환

```yaml
절차: oinfra_{project} 프로젝트스킬의 디버그 변환 규칙 참조
예시: Debug → Debug2, Trace 비활성화 등 (프로젝트마다 다름)
```

### 2. 테스트용 코드 제거

```yaml
대상:
  - 임시 하드코딩 값
  - 테스트용 주석
  - 디버깅용 Console.WriteLine
```

### 3. 로그 파일 삭제

```yaml
경로: oinfra_{project} 프로젝트스킬의 로그 경로 참조
```

### 4. TODO 파일 삭제

```yaml
명령어: mcp__oio__file_delete (TODO_*.md 패턴 glob, 또는 대상 파일별 순차 호출)
```

### 5. 프로그램 종료 및 재실행

```yaml
절차: oinfra_{project} 프로젝트스킬의 실행/종료 명령 참조
```

### 6. 의도 Lock 해제 (cleanup 마지막 동작 — 필수)

```yaml
절차:
  1. 의도 Lock 해제: mcp__oio__file_delete path={프로젝트}/.claude/locks/intent_{세션ID}.json
  2. 해제 확인: ls {프로젝트}/.claude/locks/ 에서 현재 세션 Lock JSON 없음 확인

시점: odone_cleanup의 모든 코드 정리 완료 후, odone_docs 진입 전
이유: odone_cleanup이 .cs 파일을 수정하는 마지막 단계
이후: odone_docs(MD만), odone_git(읽기만), ofinish(수정없음) → Lock 불필요
참고: Low-level Lock(.lock/.lockdir)은 domain-fileops가 파일 수정 직후 자동 해제
```

### 7. [이관됨] tmux 잔류 pane 정리 — ofinish 전담 (odone_cleanup에서 수행 금지)

```yaml
이관_이유: odone_cleanup의 pane 정리 책임은 ofinish로 이관됨 (L-126)
금지: tmux kill-pane 사용 절대 금지 (L-114: WSL2 tmux segfault → 모든 세션 소멸)
금지: kill {pane_pid} 사용 절대 금지 (동일 segfault 유발)
팀에이전트_종료: Claude Code 기본 동작으로 자연 종료 — 메인 개입 불필요
```

### 8. 에러 추적 파일 정리

```yaml
odone_cleanup 담당:
  - 프로젝트 내 에러 추적/디버그 로그 파일 삭제 (work/ 디렉토리 등)
  - 임시 작업 파일 정리

세션 디렉토리 정리는 ofinish에서 수행 (M-12 책임 분리):
  - $HOME/.claude/session-env/${UUID}/ 디렉토리 및 하위 파일 (team_name, classification 등)
  - → ofinish 전용 (odone_cleanup에서 삭제 금지)

시점: odone 마지막 (Lock 해제 후)
```

## odone_cleanup ↔ ofinish 책임 분리 (M-12)

```yaml
odone_cleanup 담당 (odone 단계):
  - 디버그 코드 변환 (Console.WriteLine → Logger 등)
  - 테스트용 임시 코드 제거
  - odev_lock 해제
  - 임시 파일 정리 (work/ 디렉토리 내 작업 파일)

ofinish 담당 (ofinish 단계):
  - 팀에이전트 pane 물리적 정리 (shutdown → kill → TeamDelete)
  - 세션 디렉토리 삭제 ($HOME/.claude/session-env/${UUID}/)
  - evidence/ 파일 최종 보존/삭제

금지_중복:
  - odone_cleanup에서 evidence/ 파일 삭제 금지 (ofinish 통계에서 참조)
  - odone_cleanup에서 세션 디렉토리 삭제 금지 (ofinish 전용)
  - ofinish에서 코드 정리 시도 금지 (odone_cleanup 전용)
```
