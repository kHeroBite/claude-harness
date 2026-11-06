# ofinish — 임시파일 삭제 목록 + ntfy 상세

> ofinish SKILL.md에서 분리된 참조 문서.

## Step 4 임시파일 삭제 목록

```yaml
보존_정책: |
  판정은 전부 ${HARNESS_HOME:-$HOME/.harness}/current/scripts/harness_cleanup.py 한 곳에 있다(dry-run 기본, --apply 일 때만 변경).
  - 승격(4-0a): 재사용 산출물(plans/ 계획·user_prompt, work/*_result.json, goal 계열, errors.md·review_actions.json)을
    <프로젝트>/.claude/archive/{plan,dev,test,lesson,request}/YYYY-MM/ 로 복사하고 INDEX.jsonl 에 1줄씩 남긴다.
    보관 영역은 전역 git ignore 로 커밋되지 않으며 자동 삭제하지 않는다.
  - 확장 승격(kind test): 결과 전 고정한 판정 규칙 work/*rules*.md, 검증 스크립트 plans/*.py·*.sh, evidence/<하위>/*.py·*.sh 도 원본 그대로 보관한다. 판 사본(_vN·_rN·_old·_bak·_copy·복사본)·1회성 탐침(probe·탐침) 이름은 제외한다.
  - 경계: archive 는 세션 원본 보관이다. 커밋할 재사용 자산(test_root·tools_root·plan/)으로 옮기는 판단은 Skill('ocanon') 보존 판정을 거쳐 각 단계가 한다.
  - 자기 세션 plans/: mtime 7일 초과 + (승격 완료 또는 승격 대상 아님)인 파일만 지운다.
  - 자기 세션 logs/prev_cycle/: 최신 3개만 남긴다. logs/ 일반 파일은 남긴다.
  - 자기 세션이 진행 중(state 가 PLAN·DEV·TEST·DONE 이거나 status 에 ROOF·구 RALPH)이면 승격만 하고 삭제는 0건이다.
  - 죽은 세션(4-0b): 등록부 pid 생존 집합에 없음 + 트리 mtime 30일 이상인 세션의 허용 목록 하위 항목만 지운다.
    사용자가 dry-run 을 확인하고 승인한 뒤 생긴 표식 파일이 있을 때만 수행하며, 표식이 없으면 no-op 이다.
  → 과거 계획·교훈은 세션 디렉터리 대신 <프로젝트>/.claude/archive/INDEX.jsonl 을 Grep 해 참조한다.
명령: |
  # ── Step 4-0a: 승격 + 자기 세션 정리 (fail-open, 실행 예산 15초) ──
  # <프로젝트 루트> 는 메인이 git -C <cwd> rev-parse --show-toplevel 로 얻고, 실패하면 cwd 를 쓴다. ${UUID} 는 실제 값으로 치환한다.
  mcp__oio__bash_exec(command='python3 -B ${HARNESS_HOME:-$HOME/.harness}/current/scripts/harness_cleanup.py --scope self --uuid ${UUID} --project "<프로젝트 루트>" --promote --apply --budget 15 --fail-open', timeout_ms=30000)
  # ── Step 4-0b: 죽은 세션 자동 회수 (승인 표식 없으면 auto_disabled 로 no-op, 실행 예산 20초) ──
  mcp__oio__bash_exec(command='python3 -B ${HARNESS_HOME:-$HOME/.harness}/current/scripts/harness_cleanup.py --scope sessions --uuid ${UUID} --apply --auto --budget 20 --max-dirs 300 --fail-open', timeout_ms=40000)
  # 4-0a·4-0b 는 rc·timeout·스크립트 부재와 무관하게 아래 4-1 로 진행한다(파이프라인 차단 금지). 4-0a 가 work/ 를 승격한 뒤에 4-1 이 work/ 를 지우므로 순서를 바꾸지 않는다.
  # ── Step 4-1: 기존 삭제 목록 ──
  # 근거: bash rm 체인은 F-DESTROY-1 hook과 oio 위험명령 필터(security.py rm 패턴)에 차단되므로 oio 도구 사용 필수
  source ${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/session_id.sh
  resolve_uuid ""
  # 파이프라인 상태/플래그 파일만 삭제 (logs/, plans/ 보존)
  # 아래는 mcp__oio__file_delete(path=...) 개별 호출로 수행. 부재 파일은 오류를 반환하므로 부재 시 오류 무시.
  mcp__oio__file_delete(path="$HOME/.claude/session-env/${UUID}/skill_direct")
  mcp__oio__file_delete(path="$HOME/.claude/session-env/${UUID}/otest_done")
  mcp__oio__file_delete(path="$HOME/.claude/session-env/${UUID}/ui_test_done")
  mcp__oio__file_delete(path="$HOME/.claude/session-env/${UUID}/reroute_count")
  mcp__oio__file_delete(path="$HOME/.claude/session-env/${UUID}/classification")
  # team_name은 oroof_active·oralph_active(구 이름, ROOF-COMPAT) 모두 부재 시에만 삭제: 먼저 mcp__oio__file_info(path="$HOME/.claude/session-env/${UUID}/oroof_active")와 oroof_active.json, 구 oralph_active, 구 oralph_active.json 의 존재를 확인한 뒤,
  # 모두 존재하지 않으면(oroof 미진행) mcp__oio__file_delete(path="$HOME/.claude/session-env/${UUID}/team_name") 호출. 하나라도 존재하면(oroof 진행 중) 보존.
  # state 파일은 삭제 금지 — ofinish Step 8이 FINISH→IDLE 전이 검증에 사용
  mcp__oio__file_delete(path="$HOME/.claude/session-env/${UUID}/session_full")
  # conv_id는 보존 (SessionStart_compact.sh 복원 시 필요 — 삭제 금지)
  # ntfy_payload.json은 Step 8(ntfy 발송) 완료 후 삭제 (Step 8 내부에서 삭제 수행)
  mcp__oio__file_delete(path="$HOME/.claude/session-env/${UUID}/agent_stats.json")
  mcp__oio__file_delete(path="$HOME/.claude/session-env/${UUID}/checkpoint.jsonl")
  mcp__oio__file_delete(path="$HOME/.claude/session-env/${UUID}/.phase_batches.written")  # F9 1회 쓰기 표식 — 남으면 다음 사이클 phase_batches.json 쓰기가 막힌다(L-599). 누락돼도 다음 진입 때 PreToolUse_pipeline_entry_reset.sh 가 logs/prev_cycle/ 로 보관 이동한다
  mcp__oio__dir_delete(path="$HOME/.claude/session-env/${UUID}/agents", recursive=true)
  mcp__oio__dir_delete(path="$HOME/.claude/session-env/${UUID}/evidence", recursive=true)
  mcp__oio__dir_delete(path="$HOME/.claude/session-env/${UUID}/panes", recursive=true)
  mcp__oio__dir_delete(path="$HOME/.claude/session-env/${UUID}/compact", recursive=true)
  mcp__oio__dir_delete(path="$HOME/.claude/session-env/${UUID}/work", recursive=true)
  # agent_keep/ 는 oroof_active(.json)·구 oralph_active(.json) 모두 부재 시에만 삭제(이전 사이클 keep 사유가 같은 이름 새 팀원에게 붙는 오경고 방지 — teammate_idle_guard 는 keep 을 이름과 mtime 120분으로만 보고 joinedAt 은 보지 않는다). 먼저 mcp__oio__file_info(path="$HOME/.claude/session-env/${UUID}/oroof_active")와 구 oralph_active(및 각 .json)로 존재 확인 후, 모두 존재하지 않으면(oroof 미진행) 아래를 호출하고 하나라도 존재하면(oroof 진행 중) 보존한다. 부재 오류는 무시한다.
  mcp__oio__dir_delete(path="$HOME/.claude/session-env/${UUID}/agent_keep", recursive=true)
  # 팀별 개별 파일 (UUID 디렉토리 외부)
  # 보존: $HOME/.claude/session-env/${UUID}/logs/ (prev_cycle 은 최신 3개만), $HOME/.claude/session-env/${UUID}/plans/ (승격 뒤 7일 초과분만 4-0a 가 정리)
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
  토픽: 프로젝트 루트 INFRA.md 헤더 ntfy_topic 참조 (none 이면 토픽 없음 — 지어내지 않는다)
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
