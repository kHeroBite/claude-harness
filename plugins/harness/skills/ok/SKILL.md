---
name: ok
description: "오케스트레이션 실행 지침. 메인이 /ok 명시 호출 시에만 Skill('ok')로 로딩. 1-way 분류(v4.2+ — /ok→무조건 oplan 경유) + 파이프라인 순서 + 팀에이전트 spawn 지침. 팀에이전트로 spawn 절대 금지(L-214). Auto-activates: 사용자가 /ok 명시 호출 시에만."
invocation:
  user_callable: true
  pipeline_callable: false
  called_by: [메인(1-way — /ok→무조건 oplan 경유)]
  calls: [ok_pipeline, ofinish]
---
# ok — 오케스트레이션 실행 지침 (v4.3)

> **메인 에이전트가 Skill('ok')로 로딩하는 실행 지침** (스킬).
> **팀에이전트로 spawn 절대 금지 (L-214)**: Claude Code는 flat team 구조 — 팀 멤버가 다른 팀 멤버를 spawn 불가.
> 메인이 이 지침에 따라 Agent(name=, team_name=) 호출만으로 oplan/odev/otest/odone을 직접 팀에이전트로 spawn + 오케스트레이션 (팀/pane 자동 생성, 사전 TeamCreate 불필요 — Claude Code v2.1.178+).

## 설계 원칙 (v3.2 핵심 변경)

```yaml
목적: 메인이 오케스트레이션 지침을 로딩하여 직접 팀에이전트 spawn + 관리
핵심: ok는 스킬(실행 지침)이지 팀에이전트가 아님. 메인이 직접 oplan/odev/otest/odone spawn
위치: 메인 컨텍스트에 Skill('ok')로 로딩
통신: 메인이 직접 팀에이전트와 SendMessage 소통

변경점 (v3.1→v3.2):
  v3.1: ko를 팀에이전트로 spawn → 하위 에이전트 spawn 시도 → flat team 제약으로 실패 → 직접 수정 fallback
  v3.2: ko를 스킬로 로딩 → 메인(리더)이 직접 팀에이전트 spawn → flat team 제약 없음

역할_범위 (v4.3):
  ok_담당: 수정 작업의 오케스트레이션 지침 제공 (o1 비소스 + 소스코드 oplan→o2~o5)
  ok_미담당: 분석/계획 단독 요청 → 메인이 oplan을 직접 spawn (ok 미경유)
  분류_방식: 1-way (/ok 호출 → 무조건 oplan 경유. /o1,/o2는 oplan 미경유 직접 진행)

금지: ok를 팀에이전트(Agent)로 spawn (L-214). 메인 직접 파일 수정 (팀에이전트에 위임)

팀에이전트_spawn_2대_절대규칙 (파이프라인 전 단계, 예외 없음):
  규칙1_팀에이전트_필수: 모든 Agent() 호출에 team_name="{팀명}" 반드시 포함
    - team_name 없으면 full_task_team_guard.sh가 즉시 block 반환
    - fallback/대체/재spawn/2차시도 포함 — 단 한 번도 예외 없음
    - team_name 조회: cat $HOME/.claude/session-env/${UUID}/team_name
    - ⚠️ 런타임 실제 팀명은 `$CLAUDE_CONFIG_DIR/teams/session-*` (프로세스 시작 시 세션ID 기준)이며, `session-{UUID앞8자}`와 다를 수 있다(/clear·resume 후). Agent 도구의 team_name 파라미터 값 자체는 런타임이 무시하지만(Deprecated), hook·스킬의 팀 추적 규약상 여전히 필수로 넘긴다.
  규칙2_subagent_type_필수: 모든 Agent() 호출에 subagent_type 반드시 명시
    - 빈값('') 절대 금지 — no_team_agent_guard.sh가 즉시 block 반환
    - 기본값: subagent_type="general-purpose"
  필수_4대_파라미터 (이 4개 없으면 hook 차단):
    subagent_type="general-purpose"   # 필수
    name="{에이전트명}"               # 필수 — 없으면 pane 미생성
    team_name="{팀명}"               # 필수 — 없으면 hook 차단
    mode="bypassPermissions"          # 필수 — 권한 대기 방지
  올바른_예시: Agent(subagent_type="general-purpose", name="odev-1", team_name="{팀명}", mode="bypassPermissions", ...)
  잘못된_예시: Agent(name="odev-1", ...)                    # ❌ team_name/subagent_type 누락
              Agent(subagent_type="...", team_name="...")   # ❌ name 누락
              Agent(model="opus", prompt="...")             # ❌ 3개 전부 누락
  규칙3_PIPELINE_UUID_첫줄_필수: 모든 Agent() prompt 첫 줄에 `PIPELINE_UUID=<full 36자 UUID>` 명시 강제
    - 형식: 정확히 `PIPELINE_UUID=<UUID>` (등호, 공백 없음, 36자 UUID)
    - 목적: hook이 prompt에서 PIPELINE_UUID 추출 시 정규식 매칭 안정화 (uuid_fallback.log 발동 조건)
    - 미준수 시: hook 폴백 발동 불가 → false-positive 차단 위험
    - 검증: hook의 resolve_uuid_from_prompt가 이 패턴을 추출하여 §(b) 소유권 증명 후 채택
  규칙4_CLAUDE_CONFIG_DIR_필수 (실측 근거 — team_agent_env_guard.sh 물리 차단):
    - prompt 첫 두 줄에 `PIPELINE_UUID=<36자 UUID>` 와 `CLAUDE_CONFIG_DIR=<절대경로>` 를 모두 명시해야 한다.
    - 누락 시 team_agent_env_guard.sh가 "팀에이전트 spawn prompt에 필수 환경변수 누락: CLAUDE_CONFIG_DIR"로 Agent spawn을 물리 차단한다.
    - 병렬 spawn 시 여러 호출이 한꺼번에 전부 차단되므로 병렬화를 직접 저해하는 요인이니 반드시 함께 기재한다.

파이프라인_강제 (절대 규칙):
  - /ok, /o1~o5 명시 호출 시 파이프라인 100% 실행 필수
  - "단순 질문/계산이라 파이프라인 불필요" 판단 금지
  - "코드 수정이 아니므로 파이프라인 대상이 아니다" 판단 금지
  - 사용자가 tier를 지정한 이상, 내용과 무관하게 해당 tier 파이프라인 실행
  - 직접 답변(텍스트만 출력)으로 대체하는 행위 절대 금지

스킬_로딩_원칙:
  메인: 수정 분류 시 Skill('ok') 호출 → 이 지침 로딩 → 지침에 따라 팀에이전트 spawn
  팀에이전트: 각자 Skill('{스킬명}') 호출로 자기 스킬 로딩
  프로젝트스킬: 팀에이전트가 각자 Skill('oinfra_{project}') 호출
```

## ok 로딩 시 메인 필수 절차

```yaml
세션당_1회_제한 (최우선 — 가장 먼저 실행):
  1. 파이프라인 활성 상태 확인: $HOME/.claude/session-env/${UUID}/state 읽기
     활성(OK/PLAN/DEV/TEST/DONE/FINISH)이면 → "⚠️ 파이프라인 진행 중 — /ok 중복 호출 차단" 출력 후 즉시 종료
  2. mcp__oio__session_state에서 key "ok_loaded" 읽기
     확인: $HOME/.claude/session-env/${UUID}/ok_loaded 파일 존재 여부
  3. 값이 "true" 이면 → ok 지침은 이미 컨텍스트에 로딩됨. ok_loaded 파일 삭제 후 파이프라인 재시작:
     mcp__oio__file_delete(path="$HOME/.claude/session-env/${UUID}/ok_loaded")
     → "ℹ️ ok 지침 재활용 — ok_loaded 초기화 후 새 파이프라인 시작" 출력 후 아래 전체 절차 계속
  4. 아니면 → 아래 전체 절차 실행 후 마지막 단계(ofinish 완료)에서 저장:
     mcp__oio__session_state(uuid="${UUID}", key="ok_loaded", value="true")
  목적: 파이프라인 활성 중 충돌 방지. 완료 후 재호출은 컨텍스트 재활용으로 허용.
  초기화: evidence_초기화 시 ok_loaded도 함께 초기화 (새 파이프라인 시작 허용)

이전_팀_정리 (ok 진입 시 자동 — v2.1.178+ 단순화):
  배경: Claude Code v2.1.178부터 TeamCreate/TeamDelete 도구가 제거됨 (현재 2.1.181).
        팀/pane은 Agent(name=, team_name=) 호출만으로 자동 생성되며, 세션 종료 시 자동 정리됨.
  절차:
    1. 별도 사전 팀 정리 단계 불필요. team_name은 Agent 호출 시 지정하면 됨.
    2. ⚠️ 절대 금지 (실측 교훈): 활성 세션 중 teams/<name>/ 디렉토리를 수동 dir_delete/rm 하면
       "team file not found"로 Agent 호출이 전면 차단됨.
       정리는 세션 종료 시 자동 정리에 위임한다. 활성 세션 중에는 팀 디렉토리 삭제 금지.
  목적: 활성 세션 중 팀 디렉토리 파괴로 인한 Agent 차단 방지.

다른_파이프라인_충돌_감지 (방법2 — UUID 결정 직후):
  시점: UUID 결정 직후, pipeline_state 설정 전
  격리_원칙: |
    모든 파이프라인 상태는 session-env/${UUID}/ 하위에 격리됨.
    다른 세션은 다른 UUID → 경로 자체가 겹치지 않음 → 실제 충돌 없음.
    따라서 다른 세션이 활성이어도 멈추거나 사용자에게 판단을 요청하지 않고 즉시 진행한다.
  절차: |
    # [P2-isolation] 타 세션 UUID/STATE/TEAM 정보를 stdout으로 노출하지 않는다.
    # CLAUDE.md §세션 격리 불변식 §(c) 정보_노출_금지 준수.
    # 다른 세션의 상태 탐색(session-env/*/ 루프) 자체를 수행하지 않는다.
    # 자기 세션(${UUID})만 state 설정 후 즉시 진행한다.
  처리: 즉시 다음 단계 진행 (타 세션 탐색/출력 없음)

UUID_결정:
  방법: |
    UUID는 UserPromptSubmit.sh(UserPromptSubmit)가 출력한 `🆔 [UUID] {값}` 또는
    SessionStart_compact.sh(SessionStart:compact)가 출력한 `- UUID: {값}` 에서 확인.
    이 값이 system-reminder 컨텍스트에 이미 존재하므로 그대로 사용한다.
  Bash_확인 (system-reminder에서 확인 불가 시 보조 fallback):
    UUID로 활용 가능한 후보:
    1순위: PIPELINE_UUID 환경변수 (팀에이전트 프롬프트에서 전달됨)
    # [P2-isolation] session-env/*/ 루프로 타 세션 UUID를 추출하는 2순위 방식 제거.
    # system-reminder의 🆔 [UUID]가 항상 존재하므로 fallback 불필요.
    # 만약 UUID를 결정할 수 없으면 오류 출력 후 중단 (타 세션 탐색 금지).
  시점: Skill('ok') 로딩 직후
  주의: |
    $CLAUDE_SESSION_ID 환경변수는 메인 에이전트에서 빈 문자열일 수 있으므로 사용 금지.
    system-reminder의 `🆔 [UUID]` 값을 1차 소스로 사용.
    UUID 미결정 시: 오류("❌ UUID를 결정할 수 없습니다. system-reminder를 확인하세요.") 출력 후 중단.
  UUID_길이_규칙 (절대):
    - UUID는 반드시 36자 full session_id 사용 (예: 6690d4cc-b90e-4a8b-8bd9-64e78b500249)
    - 팀에이전트 프롬프트의 PIPELINE_UUID도 반드시 36자 UUID 전달
    - UUID 길이 확인: echo ${#UUID} → 36 이어야 함

checkpoint_재개_감지 (UUID 결정 직후):
  확인: test -f $HOME/.claude/session-env/${UUID}/checkpoint.jsonl
  존재_시: "⚠️ 이전 파이프라인 체크포인트 발견. /oresume으로 재개 가능합니다." 출력
  목적: 사용자가 /ok를 새로 호출했지만 이전 작업이 남아있을 때 안내

checkpoint_기록_OK_START: mcp__oio__bash_exec(command='bash ${HARNESS_HOOK_DIR}/lib/checkpoint_write.sh "${UUID}" "OK_START" "OK" "" "" ""')

# ─────────────────────────────────────────────────────────────────
# 파이프라인 3축 구성: level(o0~o5) / stage(IDLE~ERROR) / status(NONE/RALPH/PAUSE/ABORT, set).
# 본 섹션은 stage 축 정의. status 축은 CLAUDE.md "파이프라인 플래그 3축" 섹션 참조.
# ─────────────────────────────────────────────────────────────────

pipeline_state_설정:
  시점: UUID 결정 직후
  명령: |
    mcp__oio__dir_create(path="$HOME/.claude/session-env/${UUID}")
    mcp__oio__session_state(uuid="${UUID}", key="state", value="PLAN")
    mcp__oio__session_state(uuid="${UUID}", key="classification", value="OK")
    mcp__oio__session_state(uuid="${UUID}", key="entry_tier", value="OK")  # ← 신규 (사용자 규칙1 — ok 진입 흔적)
    mcp__oio__session_state(uuid="${UUID}", key="reroute_count", value="0")
    mcp__oio__bash_exec(command="touch ~/.claude/session-env/${UUID}/heartbeat")  # EXT4($HOME) — oio bash_exec 경유지만 touch 자체는 허용
    mcp__oio__bash_exec(command="mkdir -p ~/.claude/session-env/${UUID}/evidence && date +%s > ~/.claude/session-env/${UUID}/evidence/ok_started")  # ok skill 진입 마커 — Stop.sh가 이 마커 보고 정상 진입 인지
  주의: |
    state=PLAN + classification=OK 동시 기록 직후 반드시 heartbeat 터치 필수 (2026-04-15, L-431 Phase B).
    이전: state=OK 단일 기록 → 현재: state=PLAN + classification=OK (level OK = tier 미정 신호)
    이유: ok 파이프라인 중단 시 heartbeat age 기반 stale 감지가 즉시 작동하려면
          heartbeat 파일이 state 기록 시점과 동기화되어야 함.
    세션별 디렉토리 $HOME/.claude/session-env/${UUID}/ 기반 (전역 파일 없음).
    파이프라인 후속 단계(DEV/TEST/DONE)에서 classification은 oplan이 확정한 tier로 업데이트:
      mcp__oio__session_state(uuid="${UUID}", key="classification", value="O{N}")
      mcp__oio__session_state(uuid="${UUID}", key="state", value="DEV")
      mcp__oio__session_state(uuid="${UUID}", key="state", value="DEV")
      mcp__oio__session_state(uuid="${UUID}", key="state", value="TEST")
      mcp__oio__session_state(uuid="${UUID}", key="state", value="DONE")
    역라우팅 카운터도 0으로 초기화.

classification_기록 (statusline tier 표시용):
  시점: tier 확정 직후 (o1/o2 직접호출 시 즉시, /ok 경유 시 oplan 반환 후)
  명령: mcp__oio__session_state(uuid="${UUID}", key="classification", value="${TIER}")
  경로: $HOME/.claude/session-env/${UUID}/classification
  값: O1, O2, O3, O4, O5 중 하나
  목적: statusline.py의 get_pipeline_info()가 tier 읽어 "O4:DEV" 형식 표시
  멀티세션: UUID 기반 경로이므로 세션 간 충돌 없음
  정리: ofinish Step 4 임시파일 삭제에서 자동 삭제됨 (기존 classification 삭제 규칙)
  주의: oplan이 tier 결정 시 classification만 갱신 — entry_tier는 그대로 유지 (규칙5 의미 일관성)

entry_tier_기록 (ok 진입 흔적 추적 — 사용자 규칙1):
  경로: $HOME/.claude/session-env/${UUID}/entry_tier
  값: "OK" (한 줄)
  기록_시점: pipeline_state_설정 시 classification과 동시 기록
  유지: 파이프라인 전 단계 동안 유지 (oplan이 classification 갱신해도 entry_tier 불변)
  정리: ofinish pre_cleanup에서 classification과 함께 삭제
  폴백: 파일 부재 시 NONE (다른 세션 영향 0 — entry_tier 없는 /o1~/o5 경유 세션)

evidence_초기화 (P0 — 잔류 증거 방지):
  시점: pipeline_state 설정 직후 (ok 로딩 즉시)
  명령: |
    # 이전 파이프라인 증거 초기화 (oio 사용)
    mcp__oio__dir_delete(path="$HOME/.claude/session-env/${UUID}/evidence")
    mcp__oio__dir_create(path="$HOME/.claude/session-env/${UUID}/evidence")
    # Lock + 재귀 카운터 초기화 (추가 — Auto-Loop stale 방지)
    mcp__oio__dir_delete(path="$HOME/.claude/session-env/${UUID}/phase_batch.lock")
    mcp__oio__file_delete(path="$HOME/.claude/session-env/${UUID}/ofinish_recurse_count")
    mcp__oio__file_delete(path="$HOME/.claude/session-env/${UUID}/current_phase_batch")
    # ok_loaded 초기화 (새 파이프라인 시작 허용 — 이 파이프라인 완료 후 재설정됨)
    mcp__oio__file_delete(path="$HOME/.claude/session-env/${UUID}/ok_loaded")
    # 파이프라인 시작 시각 기록
    date +%s > $HOME/.claude/session-env/${UUID}/pipeline_start_time
  목적:
    - 이전 파이프라인의 evidence 잔류 방지
    - 이전 파이프라인의 stale Lock 잔류 방지 (Auto-Loop 영구 차단 방어)
    - 이전 파이프라인의 재귀 카운터 오염 방지
  검증: otest_done_guard.sh가 evidence mtime > pipeline_start_time 검증
```

## OK level + PLAN 상태 금지 행동 (절대 규칙)

```yaml
적용_시점: Skill('ok') 로딩 직후 ~ oplan spawn 완료 전 (state=PLAN AND classification=OK 구간 — Phase B 마이그레이션 후 의미 보존)

금지_행동 (write_guard.sh 물리 차단 — state=PLAN + classification=OK 구간):
  - 탐색_도구: Glob, Grep
  - Serena_탐색: mcp__plugin_serena_serena__find_file / find_symbol /
                  get_symbols_overview / search_for_pattern /
                  find_referencing_symbols / list_dir
  - oio_도구: mcp__oio__bash_exec (탐색/수정 모두 포함, ls/find만이 아님)
  - "규모 파악", "전체 목록 확인", "매핑 전략 수립" 등 이유로 oplan spawn 전 조사 금지
  - hint_tier 정확도 향상 목적의 선행 탐색 금지

이유: 규모 파악은 oplan의 역할
  - 메인(ok)은 사용자 요청 텍스트에서 키워드만 추출하여 hint_tier 판정 (0초, 텍스트 기반)
  - 실제 코드 탐색 + 규모 확정은 oplan 팀에이전트가 수행
  - 메인이 선행 탐색하면 write_guard.sh가 PLAN+classification=OK 위반으로 차단 (정상 동작 — L-248 의미 보존)

상태별_메인_도구_정책 (참조용 — 단일 출처: write_guard.sh):
  IDLE:
    허용: oio 전체 (file_read/file_edit/file_write/bash_exec 등)
    금지: Edit/Write/Bash (Claude 내장 도구 P0/P1 전면 차단)
    참조: CLAUDE.md "oio MCP 독점" 섹션
  PLAN+classification=OK (구 OK 단계 — Phase B 마이그레이션 등가):
    허용: oio file_read, session_state, dir_create (오케스트레이션 준비 한정)
    금지: Glob/Grep/Serena 탐색, oio bash_exec, oio 수정 도구
    설명: oplan spawn 완료 전 구간 — 분류+spawn만 수행 (state=PLAN AND classification=OK 동시 만족)
  PLAN(classification=O1~O5)/DEV/TEST/DONE:
    허용: 없음 (팀에이전트가 모든 탐색/수정 수행)
    금지: Glob/Grep NTFS 경로 탐색, oio 수정/실행 도구 직접 사용 (팀에이전트 위임 필수)
    강화: write_guard.sh Fix 1 — PLAN/DEV/TEST/DONE에서 메인의 NTFS Grep/Glob 물리 차단
    참조: ok_pipeline/SKILL.md "팀에이전트 전면 위임 정책"

상태전환_spawn_강제 (절대 규칙 — L-NEW):
  원칙: 상태를 PLAN/DEV/TEST/DONE으로 전환한 직후 반드시 즉시 팀에이전트를 spawn해야 함
  금지_패턴:
    - 상태를 PLAN으로 전환 후 → Grep/Glob으로 코드 탐색 → oplan spawn 패턴 절대 금지
    - 상태를 DEV로 전환 후 → oio 파일 읽기/탐색 → odev spawn 패턴 절대 금지
    - 상태를 TEST로 전환 후 → bash_exec 테스트 실행 → otest spawn 패턴 절대 금지
  올바른_패턴:
    - PLAN 전환 → 즉시 oplan spawn (탐색은 oplan 내부에서)
    - DEV 전환 → 즉시 odev spawn (읽기는 odev 내부에서)
    - TEST 전환 → 즉시 otest spawn (실행은 otest 내부에서)
  이유: write_guard.sh가 상태전환 직후 메인의 NTFS 탐색/실행을 물리 차단. 우회 시도 자체가 설계 위반.
  강화: Fix 1 (write_guard.sh) — PLAN/DEV/TEST/DONE에서 메인의 NTFS Grep/Glob 물리 차단
  FINISH:
    허용: oio 전체 (ofinish 실행 중 특수 허용)
    금지: Edit/Write/Bash (Claude 내장 도구 전면 차단 유지)
    설명: ofinish가 정리/IDLE 전환을 직접 수행하는 특수 상태 (팀 디렉토리는 세션 종료 시 자동 정리)

올바른_순서:
  1. Skill('ok') 로딩
  2. 텍스트 기반 hint_tier 초벌 판정 (탐색 없이)
  3. UUID 결정 → pipeline_state=PLAN + classification=OK (사전 팀 정리 단계 불필요 — v2.1.178+)
  4. oplan 팀에이전트 spawn (Agent(name=, team_name=) 호출 시 팀/pane 자동 생성, hint_tier 전달)
  5. oplan이 탐색 + tier 확정 후 반환
```

## 완료 보고 수신 후 검증 위임 패턴 (절대 규칙)

```yaml
적용_상태: PLAN / DEV / TEST / DONE (모든 활성 파이프라인 상태)
트리거: 팀에이전트로부터 완료 보고 메시지(SendMessage) 수신

메인의_본능_카탈로그 (즉시 차단해야 하는 4가지):
  - "git diff로 변경 확인하겠다" → 차단
  - "grep으로 패턴/라인 검증하겠다" → 차단
  - "파일 라인수/내용 직접 확인하겠다" → 차단
  - "빌드/실행 결과 직접 확인하겠다" → 차단

올바른_행동 (우선순위 순):
  1순위 — SendMessage 위임:
    SendMessage(to="{보고_에이전트}", message="검증 요청: {명령} 실행 후 결과 보고")
    예시: SendMessage(to="odev-1", message="검증 요청: git diff --stat 실행 후 결과 보고")
  2순위 — 임시 에이전트 위임 (보고 에이전트가 이미 shutdown된 경우):
    동일 팀 내 임시 에이전트 spawn 후 위임

예외_허용:
  - oio file_read: 순수 읽기 목적(비검증) 한정 허용
    단, "직접 확인하겠다" 의도가 있으면 SendMessage 위임 권장

hook_차단_대응:
  - write_guard.sh block 메시지를 받았다면 이미 늦음
  - 다음 번엔 SendMessage를 첫 번째 선택으로 사용하라
  - 같은 명령 재시도 절대 금지
```

## 일회성 진단/검증 에이전트 재사용 원칙 (FleetView 누적 방지)

```yaml
배경 (2026-06-18 실측):
  - Claude Code v2.1.178+에서 종료된 팀에이전트가 FleetView 목록에서 자동 제거되지 않음
    (알려진 버그 — GitHub Issue #27639). 우리가 UI 목록을 직접 정리할 수단은 없다.
  - 따라서 spawn 개수 자체를 줄이는 것이 유일한 통제 수단이다.
  - 사고 사례: 진단/검증을 위해 pane-probe / verify-final / recover-probe2 등
    일회성 에이전트를 매번 새 이름으로 5개 spawn → FleetView 목록 누적.

원칙 (메인 의무):
  1. 진단/검증/실측용 일회성 에이전트는 "매번 새로 spawn"하지 말고 하나를 재사용한다.
     - 같은 목적의 후속 질의는 기존 에이전트에 SendMessage로 보낸다 (새 Agent 호출 금지).
     - 에이전트가 이미 shutdown됐으면, 동일 이름으로 1개만 재spawn하여 계속 사용한다.
  2. 진단용 임시 에이전트는 작업 묶음을 한 프롬프트에 모아 1회 spawn으로 끝낸다.
     - "pane 확인 → 또 다른 확인 → 또 검증"을 각각 따로 spawn하지 말 것.
     - 가능하면 메인이 직접 oio file_read/bash_exec(읽기)로 확인하고, spawn은 최소화한다.
  3. 파이프라인 에이전트(oplan/odev/otest/odone)는 단계당 1개 원칙을 그대로 유지한다.
     역라우팅 시에도 동일 이름으로 재spawn (새 이름 난발 금지).

금지:
  - 동일 목적의 일회성 에이전트를 이름만 바꿔 반복 spawn (probe → probe2 → probe3 …)
  - 메인이 직접 읽기로 끝낼 수 있는 단순 확인을 위해 에이전트 spawn

적용_범위_구분 (병렬 극대화 원칙과의 경계 — 절대 혼동 금지):
  이 절제 원칙은 일회성 진단/검증(probe류) 에이전트에만 적용된다.
  파이프라인 정규 에이전트(oplan/odev/otest/odone)가 동일 Wave 안에서 여러 개 동시 spawn되는 것은
  절제 대상이 아니며 오히려 필수다. 두 원칙은 상충하지 않는다.

재사용_필요_판단_기준 + 즉시종료_원칙 (절대 규칙):
  팀에이전트는 담당 작업 완료 보고 직후 재사용 필요성을 판정한다.
  재사용 불필요로 판정되면 ofinish를 기다리지 말고 즉시 shutdown_request를 발송한다.
  재사용 "필요" 판정 기준 (이 경우에만 유지):
    - 직후 단계에서 역라우팅 대상이 될 수 있는 에이전트 (예: otest FAIL 시 재작업할 odev)
    - 후속 검증 질의를 받을 예정인 에이전트 (완료 보고 검증 위임 대상)
    - 동일 Wave의 다음 배치를 이어받을 에이전트
  위 3개에 해당하지 않으면 전부 즉시 종료 대상이다.
  특히 oplan은 tier/계획 수령 즉시, odone은 커밋 완료 즉시 종료한다.
  shutdown 발송 후 pane 소멸을 확인하고, 미소멸 시 기존 절차(post_agent_shutdown_enforce.sh / oi-rescue 위임)를 따른다.
  shutdown_response 또는 teammate_terminated 수신은 pane 소멸의 증거가 아니다 — 반드시 tmux list-panes -a로 해당 pane_id 소멸을 실측 확인한다.
  동일 이름 재spawn은 이전 인스턴스의 pane 소멸을 실측 확인한 뒤에만 허용한다. 미확인 상태에서는 다른 이름을 쓰거나 SendMessage로 기존 인스턴스를 재사용한다.
  근거(2026-08-22 실측): agents/{이름} 파일이 이름 단일 키로 덮어쓰기되어 1차 인스턴스의 pane 추적 정보가 소실됨 — SendMessage/shutdown_request가 2차 인스턴스로만 라우팅되고 1차 pane이 추적 불능 상태로 남았다.

정리:
  - 누적된 FleetView 목록은 세션 재시작으로만 비워진다 (활성 중 teams/ 수동 삭제 금지 — L 실측).
  - 연관: [[claude-code-2178-team-model]] (teams/ 수동 삭제 시 Agent 전면 차단)
```

## UUID 일치 사전 진단 (2순위 안전망)

```yaml
UUID_일치_사전_진단:
  시점: ok 첫 spawn(oplan-1) 완료 직후 (oplan 결과 수신 후)
  목적: hook이 보는 input.session_id와 메인 PIPELINE_UUID 일치 여부 추적
  절차:
    1. mcp__oio__file_read(path="$HOME/.claude/session-env/${UUID}/logs/hook_input_session_id.log")
    2. 첫 줄 또는 최근 줄에서 `input_session_id=<UUID>` 추출
    3. PIPELINE_UUID와 비교
    4. 불일치 시: "⚠️ hook session_id 불일치 감지 (input=${INPUT_SID}, main=${UUID}) — 1순위 폴백 동작 중" 출력
  중요: 이 단계는 차단이 아닌 경고만. 1순위 폴백이 이미 처리하므로 진행 차단 금지.
```

## 프로젝트 설정 로딩

```yaml
로딩_시: Skill('oinfra_{project}') 호출 (메인이 직접)
내용: 솔루션 경로, API 포트, 로그/스크린샷 경로, ntfy 토픽, 관련 문서
코딩_규칙: {project}/PROJECT.md "코딩 규칙" 섹션 참조
```

## 분류별 처리 흐름

> 메인이 /ok 호출 시 이 지침을 로딩하여 오케스트레이션 수행.
> **v4.2+ 핵심**: ok는 분류하지 않음 — 무조건 oplan 경유. /o1,/o2는 사용자가 직접 호출. v4.3에서 ok가 텍스트 기반 초벌 판정 후 hint_tier 전달 → oplan이 탐색 후 확정.

### 모델_지정_매트릭스

> → ok_model/SKILL.md 참조 (단일 출처 — tier별 모델 배정 매트릭스)

```yaml
수정_작업_분류 (v4.3 — 1-way 분류):
  /o1 호출: oplan 없음 → odev → ofinish (즉시 처리)
  /o2 호출: oplan_simple → odev → obr → ofinish (간단 처리)
  /ok 호출: ok가 의도분석(텍스트)으로 초벌 tier 판정 → oplan에 hint_tier 전달 → oplan이 탐색 후 확정
  /o3~/o5 호출: oplan에 forced_tier 전달 (현행 유지)

  설계_배경 (v4.2→v4.3):
    문제_v4.2: 기존 의도분석(Glob/Grep 탐색)이 WSL2+NTFS에서 10~51초 소요 → 경량이 아님
    해결_v4.3: ok가 의도분석(텍스트 키워드)으로 초벌 tier 판정(0초) → oplan에 hint_tier 전달 → oplan이 탐색 후 확정/보정
    이점: 분류 지연 0초 + oplan이 실제 탐색으로 정확도 보장

  의도분석_초벌_판정 (텍스트 기반 — 0초):
    방법: 사용자 요청 텍스트에서 키워드/규모 힌트 추출
    o5_힌트: "전면 리팩토링", "새 모듈", "아키텍처 전환", "시스템 전체", "대규모 마이그레이션"
    o4_힌트: "아키텍처 변경", "대규모 수정", "전체 구조", "모듈 신설"
    o3_힌트: "여러 파일", "DB 변경", "인터페이스 수정", "비즈니스 로직", "복수 화면"
    o2_기본: 위 모두 미해당 (단순 수정, 버그 수정, 소규모)
    주의: 초벌 판정일 뿐 — oplan이 탐색 후 최종 확정. 오분류 허용.
    전달: oplan spawn 시 hint_tier=o{N} 파라미터로 전달 (forced_tier와 구별)

  tier_정의 (oplan이 탐색 후 결정 — 참조용):
    o2 (Simple): 코드 1~3개 AND 20~50줄, DB/인터페이스 변경 없음
    o3 (Normal): 코드 4개+ OR 50~500줄 OR DB/인터페이스/비즈니스로직 변경
    o4 (Heavy): 500줄+ OR 아키텍처 변경
    o5 (Massive): 1500줄+ OR 새 모듈 3개+ OR 아키 전면 변경

  tier별_파이프라인 (oplan tier 결정 후 적용):
    o2: oplan_simple depth → odev → obr → ofinish(Step1.5+7.5)
    o3: oplan_normal depth → odev(xN) → otest → odone(Fast) → ofinish
    o4: oplan_deep depth → odev(xN) → otest → odone(Full) → ofinish
    o5: oplan_debate depth → odev(xN) → otest(+UI필수) → odone(Full+Gate) → ofinish

동적_승격 (일방향 — 강등 금지):
  o1 → 소스: odev에서 소스 코드 수정 필요 감지 → oplan spawn으로 전환
  oplan_내부: oplan이 탐색 중 상위 tier 필요 감지 시 자체 승격 (oplan SKILL.md 참조)
  원칙: 기존 계획서 결과는 상위 계층으로 상속 (재작업 최소화)

분류_결과_배너 (사용자에게 출력):
  시점_o1: ok가 비소스 판정 직후 즉시 출력
  시점_o2~o5: oplan이 tier를 반환한 직후 ok가 출력 (oplan 탐색 완료 후)
  형식: |
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    📋 분류: o{N} ({Instant|Simple|Normal|Heavy|Massive})
       작업: {작업 요약 1줄}
       파일: {파일 수}개 ({파일명 목록, 3개 초과 시 "외 N개"})
       에이전트: {예상 에이전트 수}개 ({에이전트 목록})
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  o1_예시: "📋 분류: o1 (Instant)\n   작업: SKILL.md 규칙 추가\n   파일: 1개 (ok/SKILL.md)\n   에이전트: 1개 (odev)"
  o2~o5_예시: oplan 반환 데이터(규모, 파일목록, 에이전트수)로 채워서 출력

o1_작업 (Instant — 비소스 파일만):
  트리거: /o1 명시 호출 시만 (ok에서 o1으로 분류하지 않음)
  메인이 팀에이전트 spawn하여 처리:
    0. 에이전트_수_결정: Skill('oplan_parallel') 참조 — 파일 1~4개=1:1, 5개+=max(4,ceil(파일수/3))
    1. 팀명 결정 (L-221): team_name은 Agent 호출 시 지정 (팀/pane 자동 생성, 사전 생성 불필요). $HOME/.claude/session-env/${UUID}/team_name 존재 시 파일에서 복원
     - 파이프라인 진입 시 mcp__oio__session_state(uuid, key="team_name", value=<팀명>)로 team_name 파일 기록이 필수다(agent_lifecycle 등록의 기준. 헬퍼가 자동 보정하지만 명시 기록이 정본).
    2. odev 팀에이전트 spawn (파일 수정 — oplan_parallel 할당 매트릭스 기반)
    3. ofinish 실행 (Step 1.5 경량 교훈 + Step 7.5 경량 커밋)
  참조: "o1 작업 상세" 섹션

oplan_경유_작업 (v4.3 — /ok 호출 시 무조건):
  트리거: /ok 호출 (무조건) 또는 /o2~/o5 명시
  흐름:
    1. 팀명 결정 (L-221 — team_name은 Agent 호출 시 지정, 사전 생성 불필요)
    2. oplan 팀에이전트 spawn (tier 미정 — oplan이 결정)
       - /o2 명시 시: oplan에 forced_tier=o2 전달 → oplan_simple depth로 즉시 실행
       - /o3~/o5 명시 시: oplan에 forced_tier 전달 → oplan tier 결정 스킵, 해당 depth로 즉시 실행
       - /ok 경유 시: oplan이 Phase A+B 탐색 후 tier 자체 결정
    3. oplan 완료 수신: tier + 계획서 + 파일할당매트릭스
    4. 배너 출력: oplan이 반환한 tier로 분류_결과_배너 출력
    4.5 classification 기록: mcp__oio__session_state(uuid="${UUID}", key="classification", value="${oplan반환tier}")
       # 주의: oplan은 대문자 O2|O3|O4|O5를 반환해야 함 (oplan SKILL.md 반환_필수_필드 참조)
    5. Skill('ok_pipeline') 호출: tier=oplan반환값, oplan 산출물 경로 전달
       ok_pipeline은 odev부터 시작 (oplan은 이미 완료)
  참조: "코드 수정 오케스트레이션" 섹션
```

---

## o1 작업 상세

> o1 = 비코드 파일만 수정 또는 소규모 코드(≤20줄, ≤2파일). oplan 없음, otest 없음, odone 없음.
> 코드 복잡도 초과 시 o3으로 동적 승격.

```yaml
o1_요약 (메인이 직접 실행):
  1. 팀명 결정 (L-221) + 에이전트 등록 디렉토리 생성 (L-235)
     - team_name은 Agent 호출 시 지정. 별도 사전 생성(TeamCreate) 단계 불필요 (v2.1.178+).
     - team_name 파일($HOME/.claude/session-env/${UUID}/team_name) 존재 시 파일에서 팀명 복원:
       mcp__oio__file_read(path=team_name_file)
       → compact 후 재개여도 파일 기반으로 복원 (기억/추정으로 팀명 사용 금지)
       → 복원한 팀명을 이후 모든 Agent(team_name=...) 호출에 사용
     - 파일 없음 시: session-${UUID:0:8} 패턴으로 팀명 생성 (UUID 앞 8자 — Agent 자동 생성 팀명과 동일) → Agent 호출 시 team_name으로 지정 (호출 후 팀/pane 자동 생성)
       ⚠️ 임의 팀명(프로젝트명·기능명 등) 사용 금지 — v2.1.178+에서 팀은 session-{UUID앞8자} 패턴으로만 자동 생성됨. 임의 팀명 지정 시 hook 차단(HOOK_BLOCK_TEAM_NOT_EXIST) 발생. 단, 런타임 실제 팀명(`$CLAUDE_CONFIG_DIR/teams/session-*`)은 차단 대상이 아니다.
     - ⚠️ 절대 금지 (실측 교훈): 활성 세션 중 oio dir_delete로 teams/<name>/ 디렉토리 직접 삭제
       → "team file not found"로 Agent 호출 전면 차단. 정리는 세션 종료 자동 정리에 위임.
     1.5 classification 기록: mcp__oio__session_state(uuid="${UUID}", key="classification", value="O1")
  2. odev spawn (파일 수정) → 완료 → 에이전트 파일 등록 → shutdown_request
  3. ofinish 실행 (경량 모드 — Step 1.5 교훈 + Step 7.5 커밋)
     ofinish가 모든 정리를 담당 (pane 소멸 확인, agents/ 삭제, IDLE 전환 — 팀 디렉토리는 세션 종료 시 자동 정리)
     o1~o5 공통 — ofinish가 단일 출처
```

---

## 코드 수정 오케스트레이션 (v4.3 — ok가 oplan 직접 spawn)

> **소스코드 수정 시**: ok가 oplan을 직접 팀에이전트로 spawn → oplan이 tier 결정 + 계획 수립 완료 → ok가 tier 배너 출력 → Skill('ok_pipeline') 호출 (odev부터)
> **o1**: 이 블록 불필요 (odev + ofinish만 spawn)

```yaml
소스코드_수정_오케스트레이션 (ok 직접 수행):
  0. 팀명 결정 (L-221 — team_name은 Agent 호출 시 지정, 사전 생성 단계 불필요 v2.1.178+)
     # L-221 상세 절차 (compact 후 재개 포함):
     #   1) team_name 파일 존재 여부 확인:
     #        TEAM_NAME_FILE="$HOME/.claude/session-env/${UUID}/team_name"
     #   2) 파일 존재 시: 파일에서 팀명 읽기
     #        TEAM_NAME=$(mcp__oio__file_read($TEAM_NAME_FILE))
     #        ← 이 값을 이후 모든 Agent(team_name=...) 호출에 반드시 사용
     #        ← compact 후 재개 시 컨텍스트 소실과 무관하게 파일 기반으로 복원
     #   3) 파일 없음 시: TEAM_NAME="session-${UUID:0:8}" 으로 설정 후 Agent 호출 시 team_name으로 지정
     #      ⚠️ 임의 팀명(프로젝트명·기능명 등) 사용 금지 — hook 차단(HOOK_BLOCK_TEAM_NOT_EXIST) 원인
     #        → Agent 호출 후 teams/<팀명>/config.json + inboxes/ 자동 생성됨
     #      ⚠️ 런타임 실제 팀명은 `$CLAUDE_CONFIG_DIR/teams/session-*` 기준이며 session-{UUID앞8자}와 다를 수 있다(/clear·resume 후). 이 경우는 hook 차단 대상이 아니다.
     # 핵심 원칙: 팀명은 항상 파일에서 읽는다. 기억/추정으로 팀명을 사용하지 말 것.
     #   → 파이프라인 진입 시 mcp__oio__session_state(uuid, key="team_name", value=<팀명>) 기록이 정본이다.
  1. oplan 팀에이전트 spawn:
     상태_전파: mcp__oio__session_state(uuid="${UUID}", key="state", value="PLAN")
     /ok_경유 (hint_tier 전달):
       Agent(subagent_type="general-purpose", team_name="{팀명}", name="oplan-1", model="sonnet", mode="bypassPermissions",
         prompt="Skill('oplan') 호출. hint_tier=o{N} — ok 의도분석 초벌 판정. 탐색 후 보정 가능.
                 사용자 요구사항: {원문}. Skill('oinfra_{project}') 호출.
                 PIPELINE_UUID={UUID}. 대화ID: {CONV_ID}")
     /o3~/o5_명시 (tier 강제):
       Agent(subagent_type="general-purpose", team_name="{팀명}", name="oplan-1", model="{tier별 매트릭스}", mode="bypassPermissions",
         prompt="Skill('oplan') 호출. forced_tier=o{N} — tier 결정 스킵, 해당 depth로 즉시 실행.
                 사용자 요구사항: {원문}. Skill('oinfra_{project}') 호출.
                 PIPELINE_UUID={UUID}. 대화ID: {CONV_ID}")
     대기: oplan 완료까지 (Agent 도구 반환 대기)
  1.5 런타임_세션_교착_감지 (L-NEW2 — 2026-07-10 재발방지, 절대 규칙):
     증상: Agent spawn이 아래 중 하나로 실패:
       - "Internal error: team file for \"session-<XXX>\" not found. The session team should have been initialized at startup."
       - 이때 <XXX>가 현재 PIPELINE_UUID 앞 8자와 다른 값이면 = 런타임이 옛 세션 ID에 바인딩된 교착.
     원인: Claude Code Agent 런타임 내부 세션 바인딩이 startup 시 옛 세션에 고착 → 팀 자동 생성 불가.
           hook/파일/session_state로 해소 불가 (런타임 내부 영역).
     금지 (절대): 동일/다른 team_name으로 3회 이상 spawn 재시도. team_name 파일 임의 조작. 무한 재시도.
       → 두 team_name(session-{UUID앞8자} vs 런타임 요구 옛ID)이 상호 배타라 어느 쪽도 성공 불가.
     조치 (즉시):
       a) 재시도 2회까지만 (팀명은 반드시 session-{PIPELINE_UUID앞8자} — hook 정본 준수).
       b) 2회 실패 시 무한 재시도 중단 + 사용자에게 명확 안내:
          "⚠️ Agent 런타임이 옛 세션(session-<XXX>)에 바인딩되어 팀 생성 불가. hook/파일/oinit로 해소 불가한 런타임 교착입니다.
           → **/clear 또는 Claude Code 재시작**이 유일 해법 (L-540 실측: /oinit으로도 안 풀림 — 파일/pane 정리해도 in-process 바인딩 잔존).
           → 급하면 '메인 직접 구현'으로 팀 우회 진행 가능(파이프라인 검증 단계는 축소됨). 직전 여러 작업이 이 방식으로 정상 완수됨."
       c) 사용자 선택 대기 (자율 재시도 금지).
     진단: hook full_task_team_guard.sh가 session_bind_mismatch.log에 자동 기록 (L-NEW2 조기 감지).
  2. oplan 결과 수신:
     필수_필드: tier(o2|o3|o4|o5), 파일_할당_매트릭스, 수정_파일_목록
     검증_실패_시: oplan 재spawn 1회 → 재실패 시 조기 종료
  3. 배너 출력: oplan이 반환한 tier로 분류_결과_배너 출력
  4. oplan shutdown: SendMessage(type="shutdown_request") → shutdown_sent 플래그
  5. checkpoint_기록_OK_CLASSIFY_DONE: mcp__oio__bash_exec(command='bash ${HARNESS_HOOK_DIR}/lib/checkpoint_write.sh "${UUID}" "OK_CLASSIFY_DONE" "OK" "" "" "tier=${oplan반환tier}"')
  6. Skill('ok_pipeline') 호출:
     tier: oplan 반환값
     oplan_output_path: $HOME/.claude/session-env/${UUID}/plans/oplan_{대화ID}.md
     ok_pipeline은 odev부터 시작 (oplan 이미 완료)
```

> → 에이전트 무응답 fallback, 에스컬레이션, 조기 종료: ok_pipeline/SKILL.md 참조

---

## Multi-Phase 완수 의무 (절대 규칙)

```yaml
auto_loop_완수_의무:
  원칙: oplan이 multi-phase batch 계획을 세운 경우, 모든 batch를 끝까지 자동 실행해야 함
  메커니즘: ok_pipeline 4.5단계 Auto-Loop + ofinish Step 3 백업 루프

  금지_패턴 (감지 즉시 중단 + 루프 계속):
    - "남은 Phase는 후속 /ok로 실행 가능합니다" → 자동 루프로 계속 실행
    - "Phase 1 완료. Phase 2~N은 별도 요청 필요" → 자동 루프로 계속 실행
    - "컨텍스트 부족으로 여기서 중단" → checkpoint 기록 + oresume 안내 (작업 포기 금지)
    - "나머지 Phase는 간단하므로 사용자가 직접" → 자동 루프로 끝까지 실행
    - Phase 1만 상세 실행하고 나머지는 "개요만 작성" → oplan이 모든 batch 동일 상세도로 계획

  허용_중단_사유 (이것만 허용):
    - 사용자 명시적 "중단" / "멈춰" / "stop" 요청
    - max_batches(10) 초과
    - odev/otest 역라우팅 2회 초과 실패 (복구 불가)
    - 컨텍스트 한계 도달 → checkpoint + ofinish + oresume 안내 (작업 포기가 아닌 중단+재개)

  evidence: ok_pipeline이 각 batch 완료 시 evidence/batch_{N}_done 마커 생성
```

## 파이프라인 단계별 체크리스트 (절대 규칙)

> 각 tier별 **필수 단계를 건너뛸 수 없다**. 선택 단계는 조건 충족 시만 실행.
> 메인은 각 단계 완료 시 evidence 마커를 생성하여 단계 이행을 증명해야 한다.
> **IDLE 전환 조건**: ofinish 완료 마커(`evidence/ofinish_done`)가 존재해야 함.

### evidence 마커 규칙

```yaml
마커_경로: $HOME/.claude/session-env/${UUID}/evidence/{단계명}_done
생성_시점: 각 단계 완료 직후
생성_방법: mcp__oio__file_write(path=마커경로, content=타임스탬프)
검증_시점: 다음 단계 진입 전 + IDLE 전환 시
```

### o1 (Instant) 체크리스트

```
┌────┬───────────────────────┬──────┬──────────┬─────────────────────────┐
│ #  │ 단계                  │ 필수 │ 실행주체  │ 비고                    │
├────┼───────────────────────┼──────┼──────────┼─────────────────────────┤
│  1 │ 팀명 결정             │ ✅   │ 메인     │ Agent 호출 시 자동생성  │
│  2 │ state → DEV           │ ✅   │ 메인     │                         │
│  3 │ odev spawn            │ ✅   │ 메인     │ 파일 수정               │
│  4 │ odev 완료 확인        │ ✅   │ 메인     │ SendMessage 수신        │
│  5 │ odev shutdown         │ ✅   │ 메인     │ pane 소멸 확인          │
│  6 │ ofinish               │ ✅   │ 메인     │ Step1.5 교훈 + 7.5 커밋 │
│    │  ├ 교훈 수집           │ 선택 │ ofinish  │ 위반 발생 시만          │
│    │  ├ git commit+push    │ ✅   │ ofinish  │                         │
│    │  ├ 팀 자동정리         │ —    │ 세션종료 │ 세션 종료 시 자동       │
│    │  └ state → IDLE       │ ✅   │ ofinish  │ ofinish_done 마커 생성  │
└────┴───────────────────────┴──────┴──────────┴─────────────────────────┘
```

### o2 (Simple) 체크리스트

```
┌────┬───────────────────────┬──────┬──────────┬──────────────────────────────┐
│ #  │ 단계                  │ 필수 │ 실행주체  │ 비고                         │
├────┼───────────────────────┼──────┼──────────┼──────────────────────────────┤
│  1 │ 팀명 결정             │ ✅   │ 메인     │ Agent 호출 시 자동생성       │
│  2 │ state → PLAN          │ ✅   │ 메인     │                              │
│  3 │ oplan spawn           │ ✅   │ 메인     │ oplan_simple depth           │
│  4 │ oplan 완료 → tier 확정│ ✅   │ 메인     │ 배너 출력                    │
│  5 │ oplan shutdown        │ ✅   │ 메인     │                              │
│  6 │ state → DEV           │ ✅   │ 메인     │                              │
│  7 │ odev spawn            │ ✅   │ 메인     │ 코드 구현                    │
│  8 │ odev 완료 확인        │ ✅   │ 메인     │ SendMessage 수신             │
│  9 │ odev shutdown         │ ✅   │ 메인     │ pane 소멸 확인               │
│ 10 │ obr (빌드+실행)       │ ✅   │ 메인     │ Skill('obr') — 메인 직접 git/grep 금지│
│ 11 │ 서버 재시작           │ 선택 │ 메인     │ *.py 수정 시 필수            │
│ 12 │ ofinish               │ ✅   │ 메인     │ Step1.5 교훈 + 7.5 커밋      │
│    │  ├ 교훈 수집           │ 선택 │ ofinish  │ 위반 발생 시만               │
│    │  ├ git commit+push    │ ✅   │ ofinish  │                              │
│    │  ├ 팀 자동정리         │ —    │ 세션종료 │ 세션 종료 시 자동            │
│    │  └ state → IDLE       │ ✅   │ ofinish  │ ofinish_done 마커 생성       │
└────┴───────────────────────┴──────┴──────────┴──────────────────────────────┘
```

> **(PoC) goal 스킬 연동**: o3 분기에서 oplan_normal Phase 0이 자동으로 `Skill('goal')`을 호출하여 `${SESSION_DIR}/goal.json`을 생성한다. 메인의 별도 액션 불필요. 자세한 동작은 `oplan_normal/SKILL.md` "Phase 0" + `goal/SKILL.md` 참조.

### o3 (Normal) 체크리스트

```
┌────┬───────────────────────┬──────┬──────────┬──────────────────────────────┐
│ #  │ 단계                  │ 필수 │ 실행주체  │ 비고                         │
├────┼───────────────────────┼──────┼──────────┼──────────────────────────────┤
│  1 │ 팀명 결정             │ ✅   │ 메인     │ Agent 호출 시 자동생성       │
│  2 │ state → PLAN          │ ✅   │ 메인     │                              │
│  3 │ oplan spawn           │ ✅   │ 메인     │ oplan_normal depth (sonnet)  │
│  4 │ oplan 완료 → tier 확정│ ✅   │ 메인     │ 배너 출력                    │
│  5 │ oplan shutdown        │ ✅   │ 메인     │                              │
│  6 │ state → DEV           │ ✅   │ 메인     │                              │
│  7 │ odev spawn (xN)       │ ✅   │ 메인     │ 병렬 가능                    │
│  8 │ odev 전원 완료 확인   │ ✅   │ 메인     │ 모든 에이전트 SendMessage    │
│  9 │ odev 전원 shutdown    │ ✅   │ 메인     │ pane 소멸 확인               │
│ 10 │ state → TEST          │ ✅   │ 메인     │                              │
│ 11 │ 서버 재시작           │ ✅   │ 메인     │ startup.sh (*.py 수정)       │
│ 12 │ otest spawn           │ ✅   │ 메인     │ Phase1+Phase2 — 메인 직접 git/grep 금지│
│ 13 │ otest 완료 확인       │ ✅   │ 메인     │ PASS/FAIL 수신               │
│    │  └ FAIL 시 역라우팅   │ 선택 │ 메인     │ odev 재spawn                 │
│ 14 │ otest shutdown        │ ✅   │ 메인     │                              │
│ 15 │ state → DONE          │ ✅   │ 메인     │                              │
│ 16 │ odone spawn (Fast)    │ ✅   │ 메인     │ 교훈+문서+커밋               │
│    │  ├ odone_lesson        │ ✅   │ odone    │ 교훈 수집                    │
│    │  ├ odone_docs          │ 선택 │ odone    │ PROJECT/HISTORY 업데이트     │
│    │  ├ odone_git           │ ✅   │ odone    │ 커밋+푸시                    │
│    │  └ odone_cleanup       │ 선택 │ odone    │ 디버그 코드 정리 (Fast Path 스킵) │
│ 17 │ odone 완료 확인       │ ✅   │ 메인     │                              │
│ 18 │ odone shutdown        │ ✅   │ 메인     │                              │
│ 19 │ ofinish               │ ✅   │ 메인     │ 팀 정리+통계+알림+IDLE       │
│    │  ├ 팀 멤버 전원 shutdown│ ✅  │ ofinish  │                              │
│    │  ├ pane 정리           │ ✅   │ ofinish  │ 고아 pane 감지               │
│    │  ├ 팀 자동정리         │ —    │ 세션종료 │ 세션 종료 시 자동            │
│    │  ├ ntfy 알림           │ ✅   │ ofinish  │                              │
│    │  └ state → IDLE       │ ✅   │ ofinish  │ ofinish_done 마커 생성       │
└────┴───────────────────────┴──────┴──────────┴──────────────────────────────┘
```

### o4 (Heavy) 체크리스트

```
┌────┬───────────────────────┬──────┬──────────┬──────────────────────────────┐
│ #  │ 단계                  │ 필수 │ 실행주체  │ 비고                         │
├────┼───────────────────────┼──────┼──────────┼──────────────────────────────┤
│  1 │ 팀명 결정             │ ✅   │ 메인     │ Agent 호출 시 자동생성       │
│  2 │ state → PLAN          │ ✅   │ 메인     │                              │
│  3 │ oplan spawn           │ ✅   │ 메인     │ oplan_deep depth (opus)      │
│  4 │ oplan_deep 완료 수신  │ ✅   │ 메인     │ 계획서 검증 (L-305 주의)     │
│  5 │ oplan_debate 추가 실행│ 선택 │ 메인     │ DEBATE_ROUTING 조건 시만     │
│    │  └ (oplan_deep 결과   │      │          │ 를 입력으로 debate 실행)     │
│    │ OR oplan_consult      │ 선택 │ 메인     │ 이종 AI 필요 시 대안 선택   │
│  6 │ tier 확정 → 배너 출력 │ ✅   │ 메인     │ oplan_debate 결과 또는       │
│    │    (oplan shutdown)   │      │          │ oplan_deep 결과 기반         │
│  7 │ state → DEV           │ ✅   │ 메인     │                              │
│  8 │ odev spawn (xN)       │ ✅   │ 메인     │ 병렬 (opus)                  │
│  9 │ odev_review           │ 선택 │ 메인     │ 에이전트 2개+ 시             │
│ 10 │ odev_simplify         │ 선택 │ 메인     │ 구현 완료 후                 │
│ 11 │ odev 전원 완료+shutdown│ ✅  │ 메인     │ pane 소멸 확인               │
│ 12 │ state → TEST          │ ✅   │ 메인     │                              │
│ 13 │ 서버 재시작           │ ✅   │ 메인     │ startup.sh                   │
│ 14 │ otest spawn           │ ✅   │ 메인     │ Phase1+Phase2 전체 — 메인 직접 git/grep 금지│
│ 15 │ otest 완료 확인       │ ✅   │ 메인     │ PASS/FAIL                    │
│    │  └ FAIL 시 역라우팅   │ 선택 │ 메인     │ odev 재spawn                 │
│ 16 │ otest shutdown        │ ✅   │ 메인     │                              │
│ 17 │ state → DONE          │ ✅   │ 메인     │                              │
│ 18 │ odone spawn (Full)    │ ✅   │ 메인     │ 교훈+문서+스킬+커밋          │
│    │  ├ odone_lesson        │ ✅   │ odone    │ 교훈 수집+반영               │
│    │  ├ odone_review        │ ✅   │ odone    │ 프로세스 개선 점검           │
│    │  ├ odone_docs          │ ✅   │ odone    │ PROJECT/HISTORY/LESSONS      │
│    │  ├ odone_skills        │ 선택 │ odone    │ 스킬 강화 필요 시            │
│    │  ├ odone_hooks         │ 선택 │ odone    │ 반복 위반 감지 시            │
│    │  ├ odone_git           │ ✅   │ odone    │ 커밋+푸시                    │
│    │  └ odone_cleanup       │ ✅   │ odone    │ 디버그 코드+Lock 해제        │
│ 19 │ odone 완료+shutdown   │ ✅   │ 메인     │                              │
│ 20 │ ofinish               │ ✅   │ 메인     │ 팀 정리+통계+알림+IDLE       │
│    │  ├ 팀 멤버 전원 shutdown│ ✅  │ ofinish  │                              │
│    │  ├ pane 정리           │ ✅   │ ofinish  │                              │
│    │  ├ 팀 자동정리         │ —    │ 세션종료 │ 세션 종료 시 자동            │
│    │  ├ 통계 출력           │ ✅   │ ofinish  │                              │
│    │  ├ ntfy 알림           │ ✅   │ ofinish  │                              │
│    │  └ state → IDLE       │ ✅   │ ofinish  │ ofinish_done 마커 생성       │
└────┴───────────────────────┴──────┴──────────┴──────────────────────────────┘
```

### o5 (Massive) 체크리스트

```
┌────┬────────────────────────┬──────┬──────────┬──────────────────────────────┐
│ #  │ 단계                   │ 필수 │ 실행주체  │ 비고                         │
├────┼────────────────────────┼──────┼──────────┼──────────────────────────────┤
│  1 │ 팀명 결정              │ ✅   │ 메인     │ Agent 호출 시 자동생성       │
│  2 │ state → PLAN           │ ✅   │ 메인     │                              │
│  3 │ oplan_debate spawn     │ ✅   │ 메인     │ o5 필수 (opus, 3에이전트)    │
│    │  OR oplan_consult      │ 선택 │ 메인     │ 이종 AI 필요 시 대안 선택   │
│  4 │ 토론 완료 → tier 확정  │ ✅   │ 메인     │ 배너 출력                    │
│  5 │ oplan shutdown         │ ✅   │ 메인     │ oplan_debate 또는 oplan_consult│
│  6 │ state → DEV            │ ✅   │ 메인     │                              │
│  7 │ odev spawn (xN)        │ ✅   │ 메인     │ 병렬 (opus)                  │
│  8 │ odev_review            │ ✅   │ 메인     │ o5 필수                      │
│  9 │ odev_simplify          │ ✅   │ 메인     │ o5 필수                      │
│ 10 │ odev 전원 완료+shutdown│ ✅   │ 메인     │ pane 소멸 확인               │
│ 11 │ state → TEST           │ ✅   │ 메인     │                              │
│ 12 │ 서버 재시작            │ ✅   │ 메인     │ startup.sh                   │
│ 13 │ otest spawn            │ ✅   │ 메인     │ 전체+UI 필수 (opus)          │
│ 14 │ otest 완료 확인        │ ✅   │ 메인     │ PASS/FAIL                    │
│    │  └ FAIL 시 역라우팅    │ 선택 │ 메인     │ odev 재spawn                 │
│ 15 │ otest shutdown         │ ✅   │ 메인     │                              │
│ 16 │ state → DONE           │ ✅   │ 메인     │                              │
│ 17 │ odone spawn (Full+Gate)│ ✅   │ 메인     │ 교훈+문서+스킬+커밋+게이트   │
│    │  ├ odone_trans          │ ✅   │ odone    │ 우회 패턴 감지               │
│    │  ├ odone_lesson         │ ✅   │ odone    │ 교훈 수집+반영               │
│    │  ├ odone_review         │ ✅   │ odone    │ 프로세스 개선 점검           │
│    │  ├ odone_docs           │ ✅   │ odone    │ 전체 문서 업데이트           │
│    │  ├ odone_skills         │ ✅   │ odone    │ o5는 필수                    │
│    │  ├ odone_hooks          │ 선택 │ odone    │ 반복 위반 감지 시            │
│    │  ├ odone_git            │ ✅   │ odone    │ 커밋+푸시                    │
│    │  └ odone_cleanup        │ ✅   │ odone    │ 디버그 코드+Lock 해제        │
│ 18 │ odone 완료+shutdown    │ ✅   │ 메인     │                              │
│ 19 │ ofinish                │ ✅   │ 메인     │ 팀 정리+통계+알림+IDLE       │
│    │  ├ 팀 멤버 전원 shutdown│ ✅   │ ofinish  │                              │
│    │  ├ pane 정리            │ ✅   │ ofinish  │                              │
│    │  ├ 팀 자동정리          │ —    │ 세션종료 │ 세션 종료 시 자동            │
│    │  ├ 통계 출력            │ ✅   │ ofinish  │                              │
│    │  ├ ntfy 알림            │ ✅   │ ofinish  │ o5는 필수                    │
│    │  └ state → IDLE        │ ✅   │ ofinish  │ ofinish_done 마커 생성       │
└────┴────────────────────────┴──────┴──────────┴──────────────────────────────┘
```

### 단계 누락 방지 규칙

```yaml
강제_규칙:
  1. state 전환은 반드시 순서대로 (PLAN→DEV→TEST→DONE→FINISH→IDLE) — Phase B 이후 OK는 stage가 아닌 classification(level) 값
  2. IDLE 전환 전 ofinish_done 마커 필수 존재
  3. 메인이 직접 state→IDLE 쓰기 금지 — ofinish만 IDLE 전환 권한
  4. ofinish 미실행 시: 커밋 누락, 교훈 미수집 (팀 디렉토리는 세션 종료 시 자동 정리)

공통_필수_단계 (o1~o5 전부):
  - 팀명 결정 (Agent 호출 시 자동 팀 생성 — 사전 TeamCreate 불필요)
  - odev (구현)
  - ofinish (마무리 — IDLE 전환 유일 경로)

tier별_추가_필수:
  o2+: oplan (계획)
  o3+: otest (테스트) + odone (마무리)
  o4+: odone Full (교훈+문서+스킬)
  o5:  oplan_debate + odev_review + odev_simplify + odone_trans + otest_evidence(Gate)
```

---

## Bash 명령 작성 금지 패턴

- **UUID는 system-reminder에서 직접 읽기**: 매 메시지 system-reminder에 `🆔 [UUID] {값}` 형식으로 제공됨. `cat current_uuid`, `ls session-env | grep UUID` 등 파일/명령어로 UUID를 탐색하는 행위 절대 금지.

- **유니코드 말줄임표(`…`, U+2026) 절대 금지**: Bash 명령 내 파일명/경로/인자에 `…` 사용 시 `Invalid tool parameters` 오류 발생
  - 올바른 예: 완전한 경로 작성. 생략이 필요하면 `# 생략` 주석 사용
  - 원인: macOS/일부 환경에서 `...` → `…` 자동변환 + Bash 파싱 실패

## 에이전트 운영 규칙

```yaml
팀에이전트_spawn_절대_원칙 (절대 규칙):
  모든 에이전트는 반드시 팀에이전트로 spawn해야 한다. 서브에이전트(team_name 없이 Agent 호출) 절대 금지.
  이유: 서브에이전트는 tmux pane을 생성하지 않음 → pane 추적 불가 → SendMessage 라우팅 불가 → 파이프라인 제어 불가
  적용: o1~o5 전 tier, 전 단계 (oplan/odev/otest/odone/ofinish) 예외 없음
  위반_형태:
    - Agent(subagent_type=...) 호출 시 team_name 누락
    - Agent(name=...) 호출 시 team_name 누락
  처리: full_task_team_guard.sh hook이 물리 차단 (team_name 없는 Agent 호출 자체를 block)

spawn_필수_파라미터 (절대 규칙 — full_task_team_guard.sh 물리 차단):
  - 팀에이전트 spawn 시 name + team_name 둘 다 필수
  - name 없이 team_name만 있으면 서브에이전트로 실행됨 (tmux pane 미생성 → pane 추적 불가 → SendMessage 라우팅 불가)
  - 위반 시 full_task_team_guard.sh hook이 Agent 호출을 물리 차단 (파이프라인 활성 중)
  올바른_호출_형식:
    Agent(name="oplan-1", team_name="{팀명}", subagent_type="general-purpose", model="sonnet", mode="bypassPermissions", prompt="...")
  잘못된_호출_형식:
    Agent(team_name="{팀명}", subagent_type="general-purpose", ...)  # name 없음 → 서브에이전트 → hook 차단

팀에이전트_공통:
  - shutdown_request 수신 시 즉시 응답. SendMessage hook 차단 절대 금지 (L-172)
  shutdown_즉답_절대규칙 (L-U5):
    - shutdown_request 수신 즉시 현재 작업 중단 후 shutdown_response 발송
    - 파일 저장/정리 등 후처리 후 응답하는 행위 절대 금지
    - 메인이 3회×5s=15초 내에 응답 없으면 pane 강제 종료 대상
  - shutdown_with_verify (shutdown_request 발송 + 종료 확인):
    프로토콜: SendMessage(shutdown_request) 발송 후 pane 소멸 대기 (최대 30초)
    shutdown_response 또는 teammate_terminated 메시지 수신 = pane 소멸의 증거 아님. 반드시 tmux list-panes -a로 해당 pane_id 실측 확인.
    pane 미소멸 시: tmux kill-pane 강제 종료 (최후 수단)
    원칙: ofinish를 기다리지 않고 메인이 직접 수행 (ofinish 도달 전 정리)
    팀에이전트_즉답_규칙: 팀에이전트는 shutdown_request 수신 즉시 응답, 실질 5초 이내 완료 기대
  - 에이전트 반환 메시지: 요약 5줄 이내 + 파일 경로만 (컨텍스트 보호)
  - SendMessage 호출 시 summary 파라미터 필수 (미포함 시 'summary is required' 오류 발생)
  - 에이전트 1개당 담당 파일 최대 3개. DB SELECT는 상위 5행만
  - 스킬 호출 선언 필수: 스킬 로딩 시 "Skill('{스킬명}') 로딩 — {목적}" 형식으로 선언
  - odev는 구현(파일 수정)만 담당. git commit/push 절대 금지 — 커밋은 odone 전용 (L-228)
  - 팀에이전트는 정상완료/스킵/이미완료 등 모든 종료 경로에서 SendMessage 완료 보고 필수 (L-228)
spawn_위임_처리 (메인 의무):
  - 팀에이전트로부터 "SPAWN_REQUEST:" 메시지 수신 시 즉시 Agent spawn 실행
  - spawn 프롬프트에 "완료 시 {요청_에이전트명}에게 SendMessage로 결과 보고" 포함
  - "SHUTDOWN_SUB:" 메시지 수신 시 해당 에이전트에 shutdown_request 발송
  - 프로토콜 상세: ok_pipeline SKILL.md "Spawn 위임 프로토콜" 참조
무응답_타임아웃 (L-315 — 절대 규칙):
  원칙: "대기합니다" 선언 후 무한 대기 절대 금지. 다음 턴이 곧 타임아웃이다.
  절차:
    1. 에이전트에 SendMessage 발송 (상태 질의 또는 완료 대기)
    2. 다음 사용자 턴(또는 system 턴)까지 응답 없음 → 즉시 CASE-4 판정
    2.5 tmux kill-pane 시도:
      - pane ID 확인: tmux list-panes -a -F '#{pane_id} #{pane_title}'
      - hook 차단 없으면: tmux kill-pane -t {PANE_ID}
      - hook 차단 시: oi-rescue 에이전트 spawn으로 위임 (hook_차단_시_대안 참조)
    3. 강제 shutdown_request → 재spawn (동일 프롬프트)
    4. "응답을 대기합니다"라고 쓰면서 실제 행동 안 하는 것이 위반
  hook_차단_시_대안 (tmux kill-pane hook 차단 시):
    원인: write_guard.sh가 DEV 상태에서 메인의 직접 tmux 명령 차단
    해결: 새 팀에이전트를 spawn하여 tmux kill-pane 위임
    ⚠️ 주의 (L-304): 메인이 직접 tmux kill-pane 실행 시 Claude Code 세션 전체 종료 위험
      - tmux pane이 Claude Code 세션과 공유되므로 kill-pane = Claude Code 종료
      - 반드시 oi-rescue 에이전트를 통해 위임할 것
    절차:
      1. Agent spawn (team_name=현재팀, name="oi-rescue")
         prompt: "tmux kill-pane -t {PANE_ID} 실행 후 완료 보고"
         ⚠️ run_in_background=true 절대 금지 (L-303 — 무한 블로킹 버그)
      2. oi-rescue가 kill-pane 실행 → 완료 보고
      3. 메인이 동일 프롬프트로 해당 에이전트 재spawn
    적용: 무응답 에이전트 pane ID는 tmux list-panes로 확인
  적용 범위:
    - ofinish 상태 질의 후 무응답
    - odev/otest/odone 완료 보고 미수신 + idle 2회 연속
    - 어떤 SendMessage든 다음 턴에 응답 없으면 타임아웃

shutdown_보류_예외_마커 (G4 — 2026-08-23, %51/otest-1 사고 재발방지):
  배경: sendmessage_shutdown_sweep.sh(hook)가 shutdown_request 발송 후 ACK 미수신 +
        임계치(AGENT_TYPE별 기본 타임아웃 × 5) 초과 + capture-pane 30초 간격 2회 무변화 시
        자동으로 pane을 강제종료(kill)한다. 이 조건은 "정당하게 응답이 늦는 경우"까지는
        구분하지 못하므로, 사용자가 명시적으로 종료를 보류시킨 팀에이전트는 별도 마커로
        기계에 알려야 한다.
  트리거: 사용자가 특정 팀에이전트에 대해 "종료하지 말라" / "그대로 두라" / "답변만 하라"
          취지의 지시를 하면, 메인은 **즉시** 아래 마커를 생성해야 한다.
  경로: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/no_kill/{agent_name}
  내용: 사유 1줄 + ISO 타임스탬프 (참고용 — 판정은 파일 존재 여부만 확인)
  효과: 이 마커가 존재하는 동안 G4 자동 kill 로직은 조건 판정 전 최우선으로 마커 존재를
        확인하고, 존재하면 어떤 조건이 충족돼도 kill하지 않는다.
  주의: 마커는 메인 에이전트만 생성한다. hook은 읽기만 하며 생성/삭제하지 않는다.
        이 마커가 없으면 해당 팀에이전트는 자동 강제종료 대상이 될 수 있다.
중단_조건: 동일 오류 10회 반복 / 외부 의존성 문제 → ntfy 알림

effortLevel_정책 (실증 확인됨, 2026-04-28):
  서브에이전트_default: 항상 "medium" 고정 — 외부 설정으로 변경 불가 (실측 4가지 시도 모두 실패)
    - 글로벌 settings.json effortLevel 변경 → 영향 없음
    - Agent 도구 effort/effortLevel 평면 파라미터 → 무시됨
    - 메인 세션 /model UI에서 xHigh 직접 선택 → 상속 안 됨
    - .claude/agents/*.md frontmatter effort 필드 → 무시됨
  메인_세션: settings.json effortLevel은 메인에만 적용 (서브에이전트 비상속)
  보강_수단: opus 에이전트의 ultrathink 지시문이 사실상 유일 (ok_model SKILL.md 참조)
  spawn_규칙: Agent spawn 시 effortLevel 파라미터 명시 불필요 (어차피 무시됨)

oplan_결과_검증 (L-305):
  시점: oplan 완료 수신 직후 (step 4 — odev 진입 전 필수)
  원칙: oplan이 사용자 원래 요구사항을 임의 변경하거나 범위를 확장할 수 있음
  검증_절차:
    1. oplan 계획서의 구현 목표와 사용자 원래 요구사항 대조
    2. 범위 초과/목적 변경/요구사항 누락 여부 확인
    3. 불일치 발견 시 odev 진입 전 사용자에게 확인 또는 oplan 재수행 지시
  금지: oplan 계획서 그대로 odev 진입 (메인 검증 없이)
  이유: oplan 결과물이 항상 사용자 의도와 일치한다는 보장 없음

oio_bash_exec_금지규칙 (L-303):
  run_in_background: 절대 금지
  원인: bash_exec.py가 background 모드에서 프로세스 종료를 기다리는 버그 → 팀에이전트 무한 블로킹
  증상: 팀에이전트가 응답 없이 멈춤 (oi-rescue 필요 사태 발생)
  적용: bash_exec.py 수정 완료 여부와 무관하게 예방 규칙 영구 유지

MCP_MySQL_역할_분리 (L-284/L-285):
  메인(ok): MySQL 도구 사용 절대 금지 (SELECT 포함)
  oplan: SELECT만 허용 (현황 파악용)
  odev: DDL/DML 전담 (CREATE/INSERT/UPDATE/DROP 모두)
  팀에이전트_UUID: PIPELINE_UUID 환경변수만 사용. resolve_uuid 호출 금지.
```

## 파이프라인 활성 중 질의 처리

> 파이프라인 활성 중(PLAN/DEV/TEST/DONE 등) 사용자 입력은 각 파이프라인 스킬이 직접 처리. oi는 IDLE 전용.

## ok 경로 강제화 (프로젝트 훅)

`/.claude/settings.json`의 `PreToolUse`에서 `/.claude/hooks/write_guard.sh`를 실행하여 아래를 하드 차단:

- NTFS(`/mnt/c/`) 직접 수정 시도 (Edit/Write 도구)
- `~/.claude/teams/` 보호 (팀 디렉토리 직접 수정 금지)
- `/ok` 명시 없이 메인이 직접 파일 수정 시도 (단위 스킬 직접 호출 경로는 허용)
- `question` 분류에서 파일 수정 시도
