# ofinish — 임시파일 삭제 목록 + ntfy 상세

> ofinish SKILL.md에서 분리된 참조 문서.

## Step 4 임시파일 삭제 목록

```yaml
보존_정책: |
  logs/, plans/ 하위는 7일간 보존 (UserPromptSubmit.sh 자동 정리)
  → errors.md, user_prompt.md, oplan_*.md 등 히스토리를 oinsights Phase 5에서 활용

  ★ 주의 (2026-04-05 재발방지): UserPromptSubmit.sh는 IDLE 세션 즉시 삭제가 기본.
  미완료 Phase Batch (phase_batches.json + current_phase_batch) 또는
  24시간 이내 작성된 oplan_final*.md가 있을 때만 삭제를 건너뜀.
  → 미완료 작업 plans/는 반드시 git 커밋하거나 24h 이내 재개해야 영구 보존됨
명령: |
  # 근거: bash rm 체인은 F-DESTROY-1 hook과 oio 위험명령 필터(security.py rm 패턴)에 차단되므로 oio 도구 사용 필수
  source "${HARNESS_HOOK_DIR}/lib/session_id.sh"
  resolve_uuid ""
  # 파이프라인 상태/플래그 파일만 삭제 (logs/, plans/ 보존)
  # 아래는 mcp__oio__file_delete(path=...) 개별 호출로 수행. 부재 파일은 오류를 반환하므로 부재 시 오류 무시.
  mcp__oio__file_delete(path="$HOME/.claude/session-env/${UUID}/skill_direct")
  mcp__oio__file_delete(path="$HOME/.claude/session-env/${UUID}/otest_done")
  mcp__oio__file_delete(path="$HOME/.claude/session-env/${UUID}/ui_test_done")
  mcp__oio__file_delete(path="$HOME/.claude/session-env/${UUID}/reroute_count")
  mcp__oio__file_delete(path="$HOME/.claude/session-env/${UUID}/classification")
  # team_name은 oralph_active 부재 시에만 삭제: 먼저 mcp__oio__file_info(path="$HOME/.claude/session-env/${UUID}/oralph_active")로 존재 확인 후,
  # 존재하지 않으면(oralph 미진행) mcp__oio__file_delete(path="$HOME/.claude/session-env/${UUID}/team_name") 호출. 존재하면(oralph 진행 중) 보존.
  # state 파일은 삭제 금지 — ofinish Step 8이 FINISH→IDLE 전이 검증에 사용
  mcp__oio__file_delete(path="$HOME/.claude/session-env/${UUID}/session_full")
  # conv_id는 보존 (SessionStart_compact.sh 복원 시 필요 — 삭제 금지)
  # ntfy_payload.json은 Step 8(ntfy 발송) 완료 후 삭제 (Step 8 내부에서 삭제 수행)
  mcp__oio__file_delete(path="$HOME/.claude/session-env/${UUID}/agent_stats.json")
  mcp__oio__file_delete(path="$HOME/.claude/session-env/${UUID}/checkpoint.jsonl")
  mcp__oio__dir_delete(path="$HOME/.claude/session-env/${UUID}/agents", recursive=true)
  mcp__oio__dir_delete(path="$HOME/.claude/session-env/${UUID}/evidence", recursive=true)
  mcp__oio__dir_delete(path="$HOME/.claude/session-env/${UUID}/panes", recursive=true)
  mcp__oio__dir_delete(path="$HOME/.claude/session-env/${UUID}/compact", recursive=true)
  mcp__oio__dir_delete(path="$HOME/.claude/session-env/${UUID}/work", recursive=true)
  # 팀별 개별 파일 (UUID 디렉토리 외부)
  # 보존: $HOME/.claude/session-env/${UUID}/logs/, $HOME/.claude/session-env/${UUID}/plans/ (7일 후 자동 정리)
  # $HOME/.claude/session-env/ 루트 전역 잔여물 (hook_debug.log, agent_hook_input_*.json, L-277):
  # oio file_delete는 session-env 직속(비-UUID) 경로를 INVALID_UUID로 거부함(실측 확인) → 삭제 불가. 무해하므로 방치.
```

## 중단 시 ntfy 즉시 발송 (예외)

```yaml
조건: Bypass 모드 중단 / 동일 오류 10회 / 외부 의존성 문제
설명: 중단 알림은 파이프라인이 정상 완료되지 않으므로 ofinish 정상 절차를 거치지 않음. 즉시 발송.
형식:
  echo '{"topic":"{ntfy_topic}","title":"⚠️ 작업 중단","message":"중단 사유","priority":5,"tags":["warning"]}' > $HOME/.claude/session-env/${UUID}/ntfy_payload.json
  PAYLOAD_CONTENT=$(cat $HOME/.claude/session-env/${UUID}/ntfy_payload.json 2>/dev/null)
  /mnt/c/Windows/System32/curl.exe -s -X POST https://ntfy.sh \
    -d "$PAYLOAD_CONTENT" -H "Content-Type: application/json"
금지: -H "Title:" 헤더 방식 (한글 깨짐)
```

## ntfy 페이로드 생성

```yaml
역할: odone_git 완료 후, ofinish step8 발송 전에 페이로드 JSON 파일 준비
방법:
  토픽: oinfra_{project} 프로젝트스킬의 ntfy 토픽 참조
  echo '{"topic":"{ntfy_topic}","title":"✅ 작업 완료","message":"작업 내용 요약","tags":["white_check_mark"]}' > $HOME/.claude/session-env/${UUID}/ntfy_payload.json
금지:
  - -H "Title:" 헤더 방식 (한글 깨짐)
```

## 교훈 참조 (LESSONS)

- **L-136**: shutdown_request가 기본 종료 프로토콜 (미발송 시 에이전트 영원히 idle)
- **L-138**: rm -rf → pane bash fallback 사고. TeamDelete 필수 + team_dir_guard.sh 물리 차단
- **L-139**: 즉시 shutdown + 잔류 pane kill PID 정리
- **L-140**: TeamDelete "active member" 오판 버그. rm -rf 우회 필수
- **L-145**: Step 1 생략 사고 — 구체 단계+코드 인라인 원칙 수립
- **L-152**: TeamDelete 전 멤버 생존 확인 — 4중 소스(L-196) + 전원 확인이 TeamDelete 전제조건
- **L-155**: 소멸 확인 → kill PID → orphan 기록 (판별 없이 정리 절대 금지)
- **L-191**: send-keys exit 전면 폐기 → kill PID 방식 대체. flock 30초+jitter 강화
- **L-193**: ok는 스킬(실행 지침)이므로 shutdown/pane 정리 안 함. 1차: 메인이 단계별 개별 shutdown. 2차: ofinish Step 1이 잔류 멤버 보충 shutdown + pane 정리
- **L-194**: kill(SIGTERM) → kill -9(SIGKILL) 2단계 escalation. 소속 확인된 pane만 대상 (L-213)
- **L-197**: Step 2~8 순차 실행 필수 (병렬 호출 → 연쇄 실패). 이전 세션 잔류 팀 rm -rf 금지 → /ofinish 독립 실행
- **L-204**: shutdown_request fire-and-forget — 발송만 하고 응답 대기 없이 즉시 물리적 pane 정리 진행. 메인 무한 대기 방지
- **L-213**: BEFORE diff pane 소속 불명 시 프로세스 종류 무관 절대 kill 금지 — 다른 세션 에이전트 종료 사고 재발 방지
