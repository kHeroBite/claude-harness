---
name: odone_hooks
description: "반복 위반 hook 강제화. 물리 차단으로 위반율 0% 달성."
invocation:
  user_callable: false
  pipeline_callable: true
  called_by: [odone(조건부)]
  calls: []
---
# odone_hooks — 반복 위반 hook 강제화

## 역할

Review 단계에서 발견된 반복 위반을 **hook 스크립트로 물리적 차단**으로 승격합니다.
"텍스트 규칙으로 N회 위반" → "hook으로 0회 위반"으로 전환하는 자기 개선 루프.

## 입력: $HOME/.claude/session-env/${UUID}/logs/review_actions.json

```yaml
소비_대상: actions 배열에서 target == "hook" 인 항목만
소비_절차:
  1. $HOME/.claude/session-env/${UUID}/logs/review_actions.json 읽기
  2. target == "hook" 항목 필터링
  3. 항목 없으면 "✅ odone_hooks: hook 대상 없음" 출력 후 종료
  4. 항목 있으면 아래 구현 절차 실행

판단_기준 (review에서 이미 결정됨):
  - hook으로 물리 차단 가능 (도구 호출 시점에서 감지 가능)
  - 반복 횟수 무관: hook 가능하면 1회 위반이라도 즉시 hook 생성
```

## Hook 설계 원칙

```yaml
3-Layer 준수:
  - Layer 1 (Hooks): 물리적 차단. AI 재량 0%
  - Hook은 "규칙을 강제"하는 것이지 "가이드"하는 것이 아님
  - 차단 시 명확한 에러 메시지 필수 (왜 차단되었는지 + 어떻게 해결하는지)

Hook 유형:
  PreToolUse: 도구 호출 전 차단 (가장 효과적)
    - matcher: 차단할 도구명 (Edit|Write|Bash|Skill 등)
    - stdin: JSON (tool_input 포함)
    - block: stderr에 {"decision":"block","reason":"..."} + exit 2
  PostToolUse: 도구 호출 후 감시 (증거 수집용)
    - matcher: 감시할 도구명
    - stdin: JSON (stdout, tool_input 포함)

차단 출력 형식:
  echo '{"decision":"block","reason":"❌ [사유]"}'   # stdout 필수 — >&2 절대 금지
  exit 2

stderr_출력_규칙 (Claude Code hook error 방지):
  - Claude Code는 훅의 stderr 출력을 UI에서 "hook error"로 표시함
  - decision:block → 반드시 stdout (>&2 금지) — AI에 차단 이유가 전달됨
  - 정보성 로그(HOOK_EXEC_*) → stderr 출력 금지 (파일 기록만)
  - 실제 오류(HOOK_BLOCK_*, HOOK_CRASH_*) → write_error.sh의 log_hook_error가 처리
  - 직접 >&2 사용 금지 (log_hook_error의 BLOCK/CRASH 카테고리가 자동으로 stderr 출력)
```

## 구현 절차

```yaml
1_review_JSON_읽기:
  - $HOME/.claude/session-env/${UUID}/logs/review_actions.json에서 target == "hook" 항목 추출
  - 각 항목의 target_file, proposed_rule 참조

2_기존_Hook_확인:
  - ls ~/.claude/hooks/ 로 현재 hook 목록 확인
  - 기존 hook에 조건 추가로 해결 가능한지 판단
  - 가능하면 기존 hook 수정 (신규 hook 최소화)

3_Hook_스크립트_작성:
  - 경로: ~/.claude/hooks/{descriptive_name}.sh
  - 실행 권한: chmod +x 필수
  - 🚨 CRLF 제거 필수: sed -i 's/\r$//' (L-020)
  - 🚨 log_hook_error 필수 (L-074): 모든 차단/경고/주요 이벤트 경로에 반드시 추가
  - 테스트: echo '{"tool_input":{...}}' | bash hook.sh 2>&1

log_hook_error_필수_규칙 (L-074):
  적용_경로:
    - exit 2 (차단): 반드시 log_hook_error 호출 후 exit 2
    - 경고(exit 0): echo >&2 경고 출력 시 함께 log_hook_error 호출
    - 주요 이벤트: HOOK_EXEC_* 카테고리로 정상 동작 기록 (선택적이나 권장)
  금지: exit 2 전 log_hook_error 생략 — error md 미기록으로 디버깅 불가
  예외: ERR trap 내부 (HOOK_CRASH_*)는 log_hook_error 2>/dev/null 유지 (ERR 재귀 방지)
  카테고리_명명_규칙:
    - 차단: HOOK_BLOCK_{GUARD명}  예: HOOK_BLOCK_OK_CHECK
    - 경고: HOOK_WARN_{GUARD명}   예: HOOK_WARN_TEAM_DUPLICATE
    - 정상: HOOK_EXEC_{GUARD명}   예: HOOK_EXEC_PREBUILD_SHUTDOWN
    - 오류: HOOK_CRASH_{GUARD명}  예: HOOK_CRASH_PREBUILD

  필수_템플릿 (차단 경로):
    source "${HARNESS_HOOK_DIR}/lib/write_error.sh" 2>/dev/null
    log_hook_error "HOOK_BLOCK_{NAME}" "도구명" "차단 사유" "$SESSION_ID"
    echo '{"decision":"block","reason":"❌ [사유]"}'
    exit 2

  필수_템플릿 (경고 경로):
    echo "⚠️ [경고 메시지]" >&2
    source "${HARNESS_HOOK_DIR}/lib/write_error.sh" 2>/dev/null
    log_hook_error "HOOK_WARN_{NAME}" "도구명" "경고 내용" "$SESSION_ID"

4_settings.json_등록:
  - ~/.claude/settings.json의 hooks 섹션에 추가
  - matcher 패턴 정확히 설정
  - timeout: 5 (기본)
  - 중복_등록_금지: 동일 hook이 이미 등록되어 있으면 추가하지 않음 (CLAUDE.md Hooks 공유 규칙 참조)

5_검증:
  - 의도적 위반 시도 → 차단 확인
  - 정상 동작 시도 → 통과 확인
  - 유틸리티 스킬 등 예외 케이스 확인

5.5_bash_문법검증_필수 (모든 hook 수정 후):
  - hook 생성/수정 후 반드시 bash -n 문법 검증 실행:
      bash -n ~/.claude/hooks/{수정한파일}.sh
      bash -n "${HARNESS_HOOK_DIR}/lib/{수정한파일}.sh"  # lib/ 하위 파일 포함
  - 검증 실패 시: 즉시 수정 후 재검증 (검증 없이 커밋 금지)
  - 검증 통과 시에만 NTFS 동기화 및 커밋 진행
  - 이 단계를 건너뛸 수 없음 — hook_lint와 함께 필수 게이트

6_hook_lint_필수실행 (L-074 강제화):
  - bash "${HARNESS_HOOK_DIR}/lib/hook_lint.sh" [수정한 hook 파일 경로]
  - 또는 전체 검사: bash "${HARNESS_HOOK_DIR}/lib/hook_lint.sh" ~/.claude/hooks/
  - 통과 시: "✅ 검사 통과" 출력 → 다음 단계 진행
  - 실패 시: 위반 파일:줄번호 출력 → 즉시 수정 후 재검증
  - 이 단계를 건너뛸 수 없음 — hook 배포 전 필수 게이트
```

## 기존 Hook 목록 (참조)

```yaml
# settings.json 등록 hook (실제 settings.json 기준)
UserPromptSubmit:
  UserPromptSubmit.sh: 세션/파이프라인 상태 리셋 + 7-way 분류 프롬프트
PreToolUse:
  Skill: rollback_checkpoint.sh — odev 진입 시 git checkpoint 자동 생성
  mcp__mysql: mysql_korean_guard.sh — MCP MySQL SQL 한글 차단
  Edit|Write|Serena: write_guard.sh — ok 미발동 차단 + NTFS 직접 수정 차단 + 메인 직접 수정 차단 + PLAN 읽기전용 (ok_check.sh 흡수)
  Edit|Write|Serena: inline_sql_guard.sh — 인라인 SQL 한글 차단
  Grep|Glob|Serena읽기: write_guard.sh — 읽기 도구에서도 NTFS 보호 적용
  Bash: prebuild_shutdown.sh — dotnet build 전 자동 shutdown
  Bash: ext4_freshness_guard.sh — cp NTFS→ext4 신선도 검증
  Bash: session_guard.sh — 세션 유효성 검증 (PIPELINE_UUID 기반)
  Edit|Write|Bash: self_edit_allow.sh — 자기 파일 수정 허용 정책
  Agent: full_task_team_guard.sh — Agent 도구 팀에이전트 위임 정책 강제
  Agent: pipeline_order_guard.sh — 파이프라인 순서 위반 차단 (oplan→odev→otest→odone)
  Agent: otest_done_guard.sh — otest 완료 여부 검증 후 odone spawn 허용
  Agent: ui_test_done_guard.sh — UI 테스트 완료 여부 검증
  Agent: agent_lifecycle.sh — 에이전트 spawn 전 생명주기 관리
  TeamCreate: team_create_guard.sh — 팀 생성 가드
PostToolUse:
  Skill: phase_guard.sh — ok/oinfra 스킬 호출 시 state 전환 관리
  Bash: build_diagnosis.sh — dotnet build 실패 시 에러 자동 진단
  Bash: postbuild_restart.sh — dotnet build 성공 후 자동 재시작
  Agent: agent_lifecycle.sh — 에이전트 완료 후 생명주기 관리
  TeamCreate: agent_lifecycle.sh — 팀 생성 후 생명주기 관리
  TeamDelete: team_delete_sweep.sh — TeamDelete 후 잔류 bash pane 정리
  전체: error_tracker.sh — 오류 자동 감지 & 기록 + 해결 추적
PreCompact:
  PreCompact.sh: compact 전 체크포인트 저장
SessionStart:
  compact: SessionStart_compact.sh — compact 후 체크포인트 복원
# 비활성화 (파일 보존, settings.json에서만 제거)
#  ok_full_edit_guard.sh, agent_plan_mode_guard.sh
#  team_dir_guard.sh — write_guard.sh에 rm -rf 차단 로직 흡수 (Bash matcher 미등록 상태)
# 유틸리티 (미등록, 수동/스크립트 호출)
  lib/session_id.sh, lib/write_error.sh, lib/hook_lint.sh
  hook_healthcheck.sh, checkpoint_verify.sh
```

## 사례

```yaml
사례_1_NTFS_직접_Edit:
  위반: /mnt/c/ 경로에 Edit 도구 직접 사용 (3회 반복)
  hook: write_guard.sh에 경로 검사 추가
  차단: "❌ NTFS 직접 Edit 금지. rsync 방식 사용하세요"

사례_2_otest_누락:
  위반: obuild만 완료 후 odone 진입 (5회 반복)
  hook: pipeline_order_guard.sh — 파이프라인 순서 강제
  차단: "❌ 파이프라인 순서 위반! 현재 상태=TEST에서 DONE spawn 불가"

사례_3_파이프라인_점프:
  위반: IDLE에서 odev 직접 호출 (5회 반복)
  hook: pipeline_order_guard.sh 상태 전이 규칙
  차단: "❌ 파이프라인 순서 위반! 현재 상태=IDLE에서 DEV spawn 불가"

사례_4_MCP_MySQL_한글 (L-024):
  위반: SELECT alias에 한글 사용 → latin1에서 구문 오류 (1회)
  hook: mysql_korean_guard.sh — SQL 텍스트에서 한글 감지
  차단: "BLOCKED: MCP MySQL SQL에 한글이 포함되어 있습니다"
  판단: hook 가능 → 스킬 중복 기재 불필요
```

## 절대 금지

- Hook에서 복잡한 비즈니스 로직 구현 (hook은 단순 gate만)
- Hook timeout 5초 초과 (차단 지연 → UX 저하)
- 기존 hook 삭제 (비활성화만 허용 — settings.json에서 제거)
- CRLF 미제거 상태로 배포 (L-020)
