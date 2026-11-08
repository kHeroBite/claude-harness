---
name: ofinish
description: "파이프라인 마무리. pane 진단 + 잔류 파일 정리 + 통계 출력 + ntfy 알림 발송 + 종료 배너. 팀 디렉토리는 세션 종료 시 Claude Code가 자동 정리하므로 ofinish가 건드리지 않음. 메인 에이전트에서 직접 실행. 독립 실행(/ofinish)으로 수동 정리도 가능. Auto-activates when: pipeline completed, team cleanup needed."
invocation:
  user_callable: true
  pipeline_callable: true
  called_by: [ok, ok_pipeline, 사용자]
  calls: [oinit]
---

# ofinish — 파이프라인 마무리

**실행 주체**: 메인 에이전트 전용
**실행 시점**: 마지막 팀에이전트 완료 보고 수신 즉시 (정상: odone 완료 후 / 조기 종료: 중단 결정 즉시) / 또는 /ofinish로 독립 실행
**파이프라인 구조**: `메인 → Skill('ok') → [oplan→odev→otest→odone](팀에이전트) → ofinish(메인)`
**인터럽트 무시**: ofinish 실행 중에는 사용자 인터럽트를 처리하지 않음. ofinish 완료 후 처리.

## 메인의 ofinish 진입 패턴 (L-204 — shutdown_request fire-and-forget)

```yaml
메인_진입_절차:
  1. 마지막 팀에이전트 완료 보고 수신
  2. 즉시 ofinish 절차 진행 (Skill('ofinish') 또는 직접 실행)
  주의: shutdown_request 일괄 발송은 Step 1(팀 정리)이 수행. 메인은 진입 전 일괄 발송 불필요.
  배경: 1차 shutdown(단계별 개별)은 이미 메인이 각 단계 완료 시 발송 완료. 잔류 멤버만 Step 1이 보충.

핵심_원칙 (L-204):
  - Step 1이 잔류(isActive=true) 멤버에 보충 shutdown_request 발송 (fire-and-forget)
  - 팀에이전트가 idle/bash/종료 상태이면 응답이 오지 않아 물리적 pane 정리로 대체
  - Step 1에서 물리적 pane 상태 확인으로 정리 수행
  - shutdown_response는 "오면 좋고, 안 오면 물리적 정리로 대체"

금지:
  - shutdown_request 후 shutdown_response 대기 루프
  - shutdown_response 미수신을 이유로 ofinish 진입 지연
  - "응답이 올 때까지 기다리겠습니다" 패턴
```

## 핵심 원칙 (L-136/L-155/L-191/L-193)

```yaml
shutdown_책임_통합 (L-193/L-214):
  배경: v3.2에서 ok는 스킬(실행 지침)이므로 팀 멤버가 아님
  구조: 메인이 단계별 개별 shutdown(1차) + ofinish Step 1이 잔류 멤버 보충 shutdown(2차)
  1차: 메인이 각 단계 완료 시 해당 에이전트에 즉시 shutdown_request 발송 (리소스 즉시 해제)
  2차: Step 1이 isActive=true인 잔류 멤버에만 보충 shutdown_request 발송 (이미 shutdown된 멤버 스킵)
  대상: oplan/odev/otest/odone 팀에이전트 전체
  보존_제외 (2026-11-08 사용자 지시 — oqa 상주):
    - session-env/${UUID}/no_kill/{이름} 마커가 있는 팀원과 oqa-* 팀원은 1차·2차 shutdown_request·pane kill·agents/ 정리 대상에서 뺀다.
    - oqa-N 은 사용자가 /oqa 로 직접 띄운 상주 질답 팀원이며, 사용자가 명시로 종료를 지시할 때만 종료한다. 파이프라인 종료는 종료 사유가 아니다.
    - no_kill/·agent_keep/ 의 oqa-* 마커도 지우지 않는다.

진입_조건:
  정상_경로: 마지막 팀에이전트(odone) 완료 보고 수신
  조기_종료_경로 (L-216): 중간 단계 에러/중단 결정 시 즉시 진입 가능
    - oplan만 spawn 후 결과 전달 완료 (계획 단독)
    - oplan 에스컬레이션 실패 (재spawn 2회)
    - odev/otest 실패 후 복구 불가
    - 사용자 명시적 중단 요청
  공통: shutdown 사전 확인 불필요 — ofinish가 직접 수행
  독립_실행 (/ofinish): 사용자 직접 호출 — 팀 정리 + 고아 pane만 (pipeline_state/임시파일 미변경)
```

---

## 실행 절차

### Step 0.5: pipeline_state → FINISH 전환

```yaml
도구: mcp__oio__session_state
파라미터: uuid="${UUID}", key="state", value="FINISH"
목적: ofinish 실행 중임을 표시. write_guard.sh hook이 FINISH 상태에서 rm -rf 허용.
주의: echo "FINISH ${UUID}" > state 직접 bash 쓰기 금지 — write_guard.sh F1이 차단.
      반드시 mcp__oio__session_state 도구 사용. force=False(기본)으로 DONE→FINISH 검증 포함.
문서_갱신_게이트 (PreToolUse_docs_update_gate.sh — 판정 규칙·사유 파일 형식은 odone_docs "문서 갱신 게이트" 절):
  - 이 호출에서 hook 이 tier(classification)를 docs_gate_tier 마커에 기록한다(모든 tier). O1/O2 는 Step 8 판정용 기록만 하고 여기서는 검사하지 않는다.
  - O3~O5 는 이 호출에서 검사한다. 코드 변경이 있는데 HISTORY.md 가 미변경이면 block, DATABASE/PROJECT 누락은 warn(진행).
  - block 시 state 는 DONE 그대로다. 복구는 ① odone_docs 재실행 → 누락 문서 갱신·커밋 → 이 호출 재시도, ② 생략이 정당하면
    session-env/${UUID}/docs_update_waiver 에 "HISTORY: 사유(10자+)" 를 쓰고 재시도. force=True 나 다른 도구로 state 를 쓰는 우회는 금지(L-597).
  - warn·WAIVED 내용은 Step 5 종료 배너에 1줄로 노출한다.
```

### Step 1: 팀 정리 — Skill('oinit') 위임

```yaml
절대_규칙 (L-320): "정리 대상이 없다"고 판단하여 Step 1 스킵 금지.
팀/pane이 0개여도 반드시 oinit을 실행해야 함.
사유: 수동 판단은 고아 pane/고착 파이프라인을 놓칠 수 있음.

실행:
  Skill('oinit')
  # oinit이 수행하는 내용 (oinit/SKILL.md 참조):
  #   Step 0~2: team-report.sh + --dry-run
  #   Step 3~5: --force + pane 잔류 재확인 + 잔류 팀에이전트 pane kill (teams/ 디렉토리는 미삭제 — 세션 종료 시 자동 정리)
  #   Step 6:   잔류 pane 정리 (teams/ 디렉토리는 미삭제)
  #   Step 7:   잔류 파일 정리 (agents/, evidence/, panes/, compact/)
  #   Step 8:   수량 리포팅 + ofinish_cleanup_done 마커 생성 + 결과 보고
  #   Step 9:   스킵 (ofinish 내 호출이므로 — ofinish가 이후 단계 담당)
  #   Step 10:  재발방지 (CASE 0건이어도 필수)

완료_확인:
  oinit이 evidence/ofinish_cleanup_done 마커를 생성함
  ofinish_cleanup_done 마커로 정리 완료 여부 확인 가능
```

<!-- 이하 Step 1-A~H 및 원칙은 oinit/SKILL.md로 이관됨 -->

<!-- Step 1-A~H 및 핵심 원칙은 oinit/SKILL.md로 이관됨. 상세 로직은 oinit 참조. -->

#### Step 1-D.5: shutdown 후 SIGKILL escalation (L-393)

**배경**: shutdown_request 송신 후에도 Claude Code 프로세스가 IDLE statusline으로 잔류하는 패턴 (L-393).
team-cleanup.sh에 이미 escalation 로직 포함: `kill → kill-9 → tmux kill-pane`.

**절차** (team-cleanup.sh L182~L207 + L-393 완료 키워드 매칭):
1. `_completed` 정규식(한국어+영문 키워드) 매칭 → 활성 출력 감지 우회
2. 빈 prompt(`^❯ *$`) + IDLE 토큰 표시 동시 → 강제 IDLE 판정
3. kill → 1초 대기 → kill -9 → 1초 대기 → tmux kill-pane (status off 상태)

**확인**: Step 1-D 실행 후 `tmux list-panes -a | grep <pane_id>` 로 잔류 여부 재검증.
미소멸 시 수동 kill escalation 즉시 실행 (L-362 — cleanup.sh exit code 믿지 말고 pane 실존 확인).

### 팀에이전트 강제 종료 에스컬레이션 (L-393)

팀에이전트가 완료 키워드 없이 활성 상태로 잔류할 경우:

1. **1단계**: `team-cleanup.sh --force` 실행 (SIGTERM)
2. **2단계 (10초 후 미종료)**: `kill -9 <pane_pid>` SIGKILL 강제 종료
3. **3단계**: tmux pane kill-pane 실행

team-cleanup.sh는 완료 키워드 화이트리스트로 완료 판정:
- 완료 보고 완료 / task done / all completed / report sent completed 등
- IDLE statusline (❯ + IDLE💭) 조합도 완료로 판정

### Step 1.5: o1/o2 경량 교훈 (tier=o1/o2에서만 실행)

```yaml
Step_1.5 (o1/o2 경량 교훈 — tier=o1/o2에서만 실행):
  tier_확인: tier=$(cat ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/classification 2>/dev/null || echo "")
  조건: tier가 O1 또는 O2일 때만 실행 (O3+ 해당 없음)
  방법: 위반 발생 시만 교훈 1줄 수집 (odone_lesson 미호출, 메인 직접 수행)
  위반_감지: odev가 SendMessage에 "위반" 또는 "오류" 키워드 포함 시
  수집_형식: "교훈: {위반내용} → {재발방지조치}" 1줄
  미위반_시: 이 단계 스킵
```

### Step 2: 에이전트 통계

> **순차 실행 필수 (L-197)**: Step 2~7은 반드시 **각각 별도 도구 호출**로 순차 실행. 병렬 호출 절대 금지.

```yaml
step2_에이전트_통계:
  도구: mcp__oio__file_read (단독 실행 — 실패 가능성 있음, 이후 Step과 병렬 금지)
  경로: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/agent_stats.json
  출력: "📊 에이전트 발동 통계 — team={n} sub={n} task={n}"
  실패_시: "통계 파일 없음" 출력 + 스킵

```

### Step 3: 잔여 Phase 자동 진행

```yaml
step3_잔여_Phase_Batch_안전망 (백업 — 주 루프는 ok_pipeline 4.5단계):
  배경: |
    주 Auto-Loop는 ok_pipeline 4.5단계에서 수행.
    이 Step 3은 비정상 경로로 ofinish에 진입했을 때의 백업 안전망.
    정상 경로에서는 이 단계에서 "다음 Phase 없음"으로 판정됨.

  auto_loop_active_skip_조건 (V3+V8):
    # ok_pipeline Auto-Loop 정상 진행 중이면 Step 3 백업 루프 skip (이중 진입 방지)
    if [ -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/auto_loop_active" ]; then
      echo "⏭️ Step 3 skip — ok_pipeline Auto-Loop 활성 중 (auto_loop_active 플래그 감지)"
      → Step 4 진행
    fi
    # 플래그 없으면 (비정상 경로) 아래 절차 계속 실행 (안전망 유지)

  시점: Step 1 완료 후
  절차:
    3.-1. Lock 획득 (stale 감지 + 탈취 가능):
       LOCK_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/phase_batch.lock"
       LOCK_PID_FILE="$LOCK_DIR/owner_pid"

       # stale 감지
       if [ -d "$LOCK_DIR" ]; then
         LOCK_AGE=$(( $(date +%s) - $(stat -c %Y "$LOCK_DIR" 2>/dev/null || echo 0) ))
         LOCK_OWNER=$(cat "$LOCK_PID_FILE" 2>/dev/null || echo "")
         if [ "$LOCK_AGE" -gt 1800 ] || { [ -n "$LOCK_OWNER" ] && ! kill -0 "$LOCK_OWNER" 2>/dev/null; }; then
           echo "🔓 stale Lock 탈취 (age=${LOCK_AGE}s) — 백업 루프 진행"
           rm -rf "$LOCK_DIR"
         fi
       fi

       if ! mkdir "$LOCK_DIR" 2>/dev/null; then
         echo "⚠️ ok_pipeline이 이미 루프 진행 중 (정상 상태) — 백업 루프 스킵"
         → Step 4 진행
       fi

       echo "$$" > "$LOCK_PID_FILE"
       trap 'if [ "$(cat $LOCK_PID_FILE 2>/dev/null)" = "$$" ]; then rm -rf "$LOCK_DIR"; fi' EXIT INT TERM

    1. phase_batches.json 존재 확인:
       mcp__oio__file_read(path="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/plans/phase_batches.json")
       미존재: → "다음 Phase 없음" → Step 4 (최종 마무리)
    2. current_phase_batch 확인:
       mcp__oio__bash_exec(command='cat ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/current_phase_batch 2>/dev/null || echo 1')
       current >= total: → "다음 Phase 없음" → Step 4

    3.0 재귀 깊이 체크 (mcp__oio__bash_exec로 실행 — EXT4($HOME)):
       mcp__oio__bash_exec(command='
         RECURSE_RAW=$(cat ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/ofinish_recurse_count 2>/dev/null | tr -d "[:space:]")
         if [[ ! "$RECURSE_RAW" =~ ^[0-9]+$ ]]; then
           RECURSE=0
           echo 0 > ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/ofinish_recurse_count
         else
           RECURSE="$RECURSE_RAW"
         fi
         if [ "$RECURSE" -ge 3 ]; then
           echo "RECURSE_EXCEEDED"
         else
           echo $((RECURSE + 1)) > ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/ofinish_recurse_count
           echo "RECURSE_OK:$RECURSE"
         fi
       ')
       결과가 RECURSE_EXCEEDED이면: → Step 4 강제 진입 (복구 시도 중단)

    3.1 batch 인덱스 증가 (Step 3 백업 루프 진입 시, mcp__oio__bash_exec로 실행):
       mcp__oio__bash_exec(command='
         CURRENT=$(cat ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/current_phase_batch)
         NEXT=$((CURRENT + 1))
         echo $NEXT > ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/current_phase_batch
         echo "BATCH_NEXT:$NEXT"
       ')
       # 이후 기존 3.a ~ 3.f 진행

    3. current < total (비정상 경로 — ok_pipeline 루프가 작동하지 않은 경우):
       a. 경고 출력: "⚠️ Auto-Loop가 ok_pipeline에서 작동하지 않아 ofinish 백업 루프 발동"
       a.+ 원인 로깅:
          mcp__oio__file_write(
            path="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/logs/step3_backup_trigger.log",
            content="{timestamp} ok_pipeline 4.5단계 Auto-Loop 미작동 — current_phase_batch={N}, total={M}, 가능 원인: [분석 필요]"
          )
          # LESSONS 자동 기록 권장 (odone_lesson이 수집)
       b. odev 재spawn 시 Agent(name=, team_name=) 호출로 팀/pane/config.json 자동 생성 (v2.1.178+ — TeamCreate 불필요)
          # 세션이 활성 중이면 teams/{name}/는 이전 호출에서 이미 존재하거나 Agent 호출 시 자동 생성됨
       c. 다음 batch의 file_assignment 로딩 (phase_batches.json에서 추출)
       d. state → DEV: mcp__oio__session_state(uuid="${UUID}", key="state", value="DEV")
       e. odev 재spawn → otest → odone → ofinish 반복
       f. ofinish 재진입 시 다시 Step 3에서 다음 batch 체크
    4. 다음 Phase 없음:
       → Step 4 (최종 마무리)

  목적: ok_pipeline 루프가 실패한 경우에도 작업을 끝까지 진행하는 이중 안전망
  주의: 정상 경로에서는 발동되지 않아야 함. 발동 시 ok_pipeline 루프 문제 조사 필요.

```

### Step 3.5: next_action.json autoloop (단발성 follow-up 자동 진행 — 2026-05-11 신규)

```yaml
step3_5_next_action_autoloop:
  배경: |
    Step 3은 oplan이 미리 생성한 phase_batches.json이 있어야만 작동.
    단발성 작업에서 마무리 시점에 메인이 "follow-up 필요"를 발견한 경우는
    phase_batches.json이 없어 Step 3이 통과돼버려 사용자에게 "다음 권장" 텍스트만 출력하고 IDLE 복귀.
    → 사용자가 같은 권장을 매번 수동 호출해야 하는 불편 해소를 위한 autoloop.

  메인_정책 (작성 책임):
    - ofinish 호출 직전에 follow-up이 명확하면 next_action.json 작성
    - 작성 조건: (a) 슬래시 명령이 명확 (b) 작업 설명이 1줄 이상 (c) 자동 진행해도 안전하다고 메인이 판단
    - 모호하거나 사용자 확인이 필요하면 작성하지 않음 (기존 동작 — IDLE 복귀)

  auto_ON_세션_정합 (oto 자율모드 — 계획 §2-8, 완주 가드 F-OTO-2·F-OTO-9 와 동일 규칙):
    - auto=ON(oto) 세션의 next_action.json 은 "handoff_kind":"blocked_only"(goal 의 blocked·blocked_by 항목 id 만 담은 blocked_ids) 또는 "carryover"(open 잔여 id 를 담은 carry_ids) 둘뿐이다. 그 밖의 인계는 write_guard·완주 가드가 차단한다.
    - auto=ON 세션의 next_action(blocked_only·carryover)은 ofinish 가 소비하지 않는다. carryover 는 다음 /oto 진입부(0_잔업_이어받기)가 소비하고, oto 는 ROOF 경로라 next_action 이 Phase 2 이후에 생긴다.
    - open FAIL·UNDET 는 oto 검증 루프(FINISH→DEV 재진입)가 먼저 처리하고, 남으면 carryover 로 이월해 곧바로 다음 사이클을 착수한다. 체인 상한(cycle_cap)·진전 없음(no_progress)·EARLY_TERM 에 닿았을 때만 oto_incomplete.json({fail_ids, reason, iteration, max_iterations, detail})으로 '미완료'를 정직하게 보고한다.
    - auto=OFF 세션은 아래 기존 동작 그대로다.

  파일: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/next_action.json
  스키마:
    {
      "slash_command": "/o3" | "/o2" | "/o1" | "/o4" | "/o5" | "/ok" | "/oroof" | ...,
      "task_description": "한 줄 작업 설명 — 슬래시 명령 뒤에 붙는 인자가 됨",
      "reason": "왜 follow-up이 필요한지 한 줄",
      "created_at": "ISO timestamp"
    }

  ofinish_동작 (자동 감지·소비):
    0. goal.json 조건부 hard gate 체크:
       # 조건: goal.json 존재 AND locked==true 일 때만 강제. 그 외 → 1번으로 진행.
       _GOAL="${SESSION_DIR}/goal.json"
       if [ -f "$_GOAL" ] && [ "$(jq -r '.locked // false' "$_GOAL" 2>/dev/null)" = "true" ]; then
         # goal.acceptance 판정은 공용 CLI 한 곳에서만 한다 (세션 경로 재매핑·UNDET 처리 포함)
         # CLI 가 GOAL_SESSION_DIR(goal.json 디렉터리)·GOAL_UUID 를 auto_script 에 넘긴다
         # ofinish 는 odone 이후이므로 --before-stage 없이 valid_after:"odone" 항목까지 전부 판정한다 (otest_verify 는 --before-stage odone)
         bash "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/goal_autoscript_run.sh" --goal "$_GOAL"; _GRC=$?
         # rc 가 0 이 아니면 전부 미통과 (1=미달, 3=판정불가·비정상, 127=lib 부재, 그 외=비정상)
         # rc=0 은 전 항목 PASS, 또는 open 0건에 전부 blocked(ALLBLOCKED)일 때다.
         if [ "$_GRC" -ne 0 ]; then
           echo "⛔ goal.acceptance 미통과(rc=$_GRC) — PASS 로 간주하지 않음, autoloop 진입 차단, next_action.json 보존됨"
           → Step 4 진행 (autoloop 미진입)
         fi
       fi
       # 위 게이트 통과 또는 goal.json 부재/locked=false → 기존 1번으로 진행

    1. next_action.json 존재 확인:
       mcp__oio__file_read(path="${SESSION_DIR}/next_action.json")
       부재: → Step 4 진행 (정상 종료)

    2. 재귀 카운터 체크 (Step 3과 동일 ofinish_recurse_count 재활용):
       mcp__oio__bash_exec(command='
         RECURSE=$(cat ${SESSION_DIR}/ofinish_recurse_count 2>/dev/null | tr -d "[:space:]")
         [[ ! "$RECURSE" =~ ^[0-9]+$ ]] && RECURSE=0
         if [ "$RECURSE" -ge 3 ]; then
           echo "AUTOLOOP_EXCEEDED"
         else
           echo $((RECURSE + 1)) > ${SESSION_DIR}/ofinish_recurse_count
           echo "AUTOLOOP_OK:$RECURSE"
         fi
       ')
       AUTOLOOP_EXCEEDED: → next_action.json을 logs/autoloop_exceeded_${timestamp}.json으로 이동 후 Step 4 진행
                          + 사용자에게 "⚠️ autoloop 3회 초과 — 자동 진행 중단, next_action.json 보존됨" 출력

    3. status 축 확인 (ABORT/PAUSE 시 즉시 중단):
       STATUS=$(cat ${SESSION_DIR}/status 2>/dev/null || echo "NONE")
       if [[ "$STATUS" == *"ABORT"* ]] || [[ "$STATUS" == *"PAUSE"* ]]; then
         echo "⚠️ status=${STATUS} 감지 — autoloop 중단, next_action.json 보존됨"
         → Step 4 진행
       fi

    4. next_action.json 내용 파싱:
       SLASH=$(jq -r '.slash_command' next_action.json)
       DESC=$(jq -r '.task_description' next_action.json)
       REASON=$(jq -r '.reason' next_action.json)

    5. 슬래시 명령 유효성 검증 (whitelist):
       유효: /ox /o1 /o2 /o3 /o4 /o5 /ok /oto /oroof /oresume /oconsult /odebate /odeep /onormal /osimple /okconsult /okdebate /okdeep
       무효 (예: /oinit, /ofinish 등 메타): → next_action.json을 evidence/rejected_autoloop.json으로 이동 + Step 4
       # /oto (자율모드): 미등재 시 rejected_autoloop으로 거부되어 자율 완주가 끊긴다.
       #   대체로 /ok를 쓰면 autoloop은 돌지만 Step 8에서 auto 플래그가 삭제되어
       #   2번째 사이클부터 일반 모드로 강등된다 → 반드시 /oto 그대로 유지할 것.

    6. 소비 처리 (재실행 방지):
       mcp__oio__bash_exec(command='mv ${SESSION_DIR}/next_action.json ${SESSION_DIR}/logs/consumed_autoloop_$(date +%Y%m%d_%H%M%S).json')

    7. 메인에게 autoloop 진입 통지:
       출력 (반드시 마지막 출력으로):
         ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
         🔁 ofinish autoloop 발동 (사이클 ${RECURSE}/3)
         ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
         다음 명령: ${SLASH} ${DESC}
         사유: ${REASON}

         ⚠️ 메인 강제 진행 규칙 (CLAUDE.md "ofinish autoloop"):
            사용자 입력 대기 없이 즉시 위 슬래시 명령으로 다음 사이클 진입.
            ABORT/PAUSE 토큰 또는 사용자 명시 /oinit 시에만 중단.
         ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    8. Step 4~8 정상 진행 (state IDLE 전이 포함) → ofinish 종료
       메인은 IDLE 상태에서 위 출력을 보고 ${SLASH} 슬래시 명령을 즉시 실행 (사용자 입력 없이)

  안전망:
    - max 3회 재귀 (ofinish_recurse_count로 카운트)
    - status=ABORT|PAUSE 시 즉시 중단
    - 무효 슬래시 명령 자동 거부 (whitelist)
    - 동일 task_description 2회 연속 감지 시 무한 루프 방지 (consumed_autoloop_*.json grep)
    - 사용자가 /oinit 호출 시 즉시 중단 (UserPromptSubmit hook 또는 메인 판단)
```

### Step 4: 임시 파일 삭제

```yaml
step4_임시파일_삭제:
  도구: mcp__oio__bash_exec
  # → 삭제 목록 전체: [references/CLEANUP_FILES.md](references/CLEANUP_FILES.md) "Step 4 임시파일 삭제 목록"
  요약: Step 4-0a harness_cleanup.py 승격+자기 세션 정리, 4-0b 죽은 세션 자동 회수(승인 표식 있을 때만, 없으면 no-op), 4-1 기존 삭제 목록(상태/플래그 파일+agents/evidence/panes/compact/work) — 상세 CLEANUP_FILES.md
  순서: 4-0a → 4-0b → 4-1 을 순차 실행한다. 4-0a·4-0b 는 --fail-open 이며 rc·timeout 과 무관하게 4-1 로 진행한다.

```

### Step 5: 종료 배너

```yaml
step5_종료_배너:
  형식: |
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    🎉 **작업 완료**
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    | 항목            | 값                   |
    |-----------------|----------------------|
    | 커밋 해시       | {git rev-parse HEAD} |
    | 변경 파일 수    | {git diff --stat}    |
    | 파이프라인 상태 | FINISH (IDLE 전환은 Step 8에서 완료) |
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  데이터_수집:
    커밋: git rev-parse --short HEAD
    변경: git diff HEAD~1 --stat | tail -1

```

### Step 6: checkpoint + evidence 마커

```yaml
step6_pipeline_마커:
  주의: 각 도구를 개별 호출 (bash 체인 금지)
  순서:
    1. checkpoint 기록: mcp__oio__bash_exec(command='bash ${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/checkpoint_write.sh "${UUID}" "FINISH_DONE" "FINISH" "" "" ""')
    2. evidence 마커: mcp__oio__file_write(path="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/evidence/ofinish_done", content=타임스탬프)
  # state → IDLE은 Step 8(최후 단계)에서 수행. 여기서 변경하면 ntfy/커밋이 IDLE 상태로 실행되어 hook 충돌 위험.

```

### Step 7: ntfy 발송

```yaml
step7_ntfy_발송:
  도구: mcp__oio__bash_exec (Step 6 완료 후 단독 실행 — 파이프라인 최종 단계)
  설명: |
    발송은 공용 스크립트 hooks/lib/ntfy_send.sh 한 곳에서만 한다(curl 직접 호출 금지).
    odone 이 쓴 ntfy_payload.json 을 쓰고, 없으면 odone 로그의 "## ntfy 페이로드" 절 → git HEAD 제목으로 다시 만든다.
    토픽은 NTFY_TOPIC → 페이로드 topic → 프로젝트 루트 INFRA.md 헤더 ntfy_topic 순으로 찾고, 없으면 지어내지 않는다.
    모든 팀 정리/통계/배너 완료 후 발송하여 정확한 완료 시점을 알린다.
  명령: |
    # {UUID}·{프로젝트_경로} 는 메인이 실제 값으로 치환한다(bash_exec 는 dash — source 금지, bash 로 직접 실행)
    bash "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/ntfy_send.sh" --session-dir "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}" --project-dir "{프로젝트_경로}"; echo "NTFY_RC=$?"
  결과_처리:
    rc=0: "✅ ntfy 발송 완료 topic=..." 그대로 보고 (페이로드 파일은 스크립트가 삭제)
    rc=3 (NTFY_NO_TOPIC): 배너에 "⚠️ ntfy 토픽 미정 — 발송 불가(사용자 지정 필요)" 를 그대로 표기한다. 조용히 스킵 금지.
    rc=1 (NTFY_SEND_FAIL): "⚠️ ntfy 발송 실패" 표기 + 페이로드 보존 (파이프라인 중단 사유 아님)
    rc=2: 사용법 오류(세션 디렉터리 부재·jq 부재) — 출력 그대로 표기
  시험: bash "${HARNESS_HOME:-$HOME/.harness}/current/hooks/tests/test_ntfy_send.sh" (dry-run 만, 실제 발송 없음)
```

<!-- L-324: Step 7.5 정의 위치(o1/o2 경량 커밋) -->
### Step 7.5: o1/o2 경량 커밋 (tier=o1/o2에서만 실행)

```yaml
Step_7.5 (o1/o2 경량 커밋 — tier=o1/o2에서만 실행):
  tier_확인: Step 1.5에서 읽은 tier 재사용 (또는 cat ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/classification)
  조건: tier가 O1 또는 O2일 때만 실행 (O3+는 odone_git이 담당)
  짝: Step 1.5(o1/o2 경량 교훈)와 짝을 이루는 커밋 단계
  방법: mcp__oio__bash_exec로 직접 수행 (odone_git 미호출)
  HISTORY_1줄_기록 (git add 직전 — Step 8 문서 갱신 게이트가 이 기록을 검증한다):
    대상: 프로젝트 git 루트의 HISTORY.md (git rev-parse --show-toplevel 기준)
    부재_시: 생략하고 "HISTORY.md 없음 — 1줄 기록 생략" 을 출력·logs/docs_gate.log 에 1줄 남긴다(게이트도 해당 검사를 생략한다).
    위치: 파일의 첫 `---` 구분선 바로 다음 (최신 이력이 위로 오게)
    방법: mcp__oio__file_edit 로 삽입 (Write 덮어쓰기 금지)
    형식: |
      ## [YYYY-MM-DD] {작업 요약} (o1|o2, {conv_id})

      **수정**: {변경 파일 목록}

      ---
    의도적_생략: 기록이 정말 불필요하면 session-env/${UUID}/docs_update_waiver 에 "HISTORY: 사유(10자+)" 를 쓴다.
  명령: |
    WT=$(python3 <hooks>/lib/wt_lib.py ensure --repo {프로젝트_경로} --sid <UUID> | python3 -c 'import sys,json; print(json.load(sys.stdin)["worktree"])')   # ensure 출력 JSON 의 worktree 키. 원본에서 add/commit 하지 않는다. <UUID> 는 36자 full UUID(메인=🆔 [UUID] 또는 compact 복원 `- UUID:`, 팀원=PIPELINE_UUID)
    : "${WT:?worktree 확보 실패}"   # WT 가 비면 중단. 위 WT=… 와 이후 명령은 같은 셸 호출 안에서 실행한다(&& 로 이어 쓰면 다른 셸에서 실행돼 WT 가 빈다)
    # 변경이 이미 원본에 있으면 add 전에 adopt 로 옮긴다: python3 <hooks>/lib/wt_lib.py adopt --sid <UUID> --paths <파일...> (경로 지정 필수, 디렉터리·일괄 거부 rc=2, 원본 불변, 선행 ensure 필요. push 후 되돌림·ff 는 사전조건(원본이 기본 브랜치·채택 외 추적 변경 없음·gated 면 --apply-permit)이 확실할 때만이며 결과 JSON adopt 의 kept(ff 불가: 사유)=원본에 새 판 유지·ff 만 건너뜀→git status 로 원본 확인 후 사유 해소하고 push 재실행(타 변경 삭제 금지), mismatch=원본 변경 보존·보고, cleared·restored 는 정보)
    git -C "$WT" add {이번 작업에서 수정한 파일 + HISTORY.md 를 경로로 명시}  # git add -u/-A/. 금지 (L-457, 타 세션 변경 흡수 방지)
    git -C "$WT" commit -m "$(cat <<'EOF'
    🔧 {작업 요약} by {모델계열}
    EOF
    )"
    python3 <hooks>/lib/wt_lib.py push --sid <UUID> --repo "$WT"   # 유일한 push 경로. --sid 필수(메인=hook 이 알린 세션 UUID, 팀원=PIPELINE_UUID; 메인 셸에는 세션 ID 환경변수가 없다). 게이트 대상 저장소는 --apply-permit 또는 WT_APPLY_PERMIT=1
  push_rc_대응: 0 성공(결과 JSON 보고) / 2 추적 변경 남음(커밋 후 재실행) / 3 rebase 충돌(즉시 중단·conflicts 보고, 자동 해결·강제 push 금지) / 4 정본 원격 판정 실패(push 안 함·보고) / 5 잠금 대기 초과(1회 재실행 후 보고) / 6 push 거절(보고; "원격이 앞섬 — worktree 에서 push 하라" 면 --sid 로 worktree 에서 재실행) / 7 원본에서 push 했는데 앞선 세션 worktree 존재(결과 JSON ahead_worktrees 참조, --sid 누락·재실행, 성공 간주 금지; 원본에서 push 할 때 sid 의 worktree 기록이 전혀 없으면 세션명과 무관하게 앞선 worktree 를 모두 내 것으로 보고 거부되므로 push 전에 ensure 를 먼저 하고 `--repo <세션 worktree>` 지정 또는 `--sid` 재실행, 기록이 있을 때만 타 세션 worktree 는 warnings 에만 실림) / 8 원본 현재 브랜치가 기본 브랜치 아님(push 안 함·worktree 경유로 전환)
  push_금지: git 명령으로 직접 올리기, 강제 push, 원격/브랜치 하드코딩
  전환기_호환: wt_lib.py 가 없는 구 배포본에서만 기존 방식으로 폴백하고 그 사실을 보고한다.
  커밋_메시지: 한국어+이모지 + 마지막에 "by {모델계열}" 태그 필수
  o3+_동작: 이 Step 스킵 (o3+는 odone_git이 커밋 담당)
```

### Step 8: oroof gate → state → IDLE + 재귀 카운터 정리 (최후 단계 — 절대 이전으로 이동 금지)

게이트_생략_감사 (Step 8 진입 직후 1회, 실패해도 진행): `python3 -B "${HARNESS_HOME:-$HOME/.harness}/current/scripts/gate_skip_audit.py" --session "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}"` 를 실행하고 rc=1 이면 출력(상태 전이 판정 hook 의 시간 초과 생략·탈출·늦은 차단)을 최종 보고에 그대로 적는다. 이미 지나간 전이를 되돌리지 못하는 재검사·기록 수단이다.

```yaml
step8_oroof_gate:
  주의: ntfy 발송(Step 7) + o1/o2 커밋(Step 7.5) 완료 후 가장 먼저 oroof 활성 여부 확인
  # [ROOF-COMPAT] status_has ROOF 를 우선 검사하고 구 RALPH 토큰도 함께 인식한다 → 둘 다 음성이면 oroof_active(.json) 파일, 이어서 구 oralph_active(.json) 파일 순으로 폴백
  # 구 RALPH 토큰·oralph_active 폴백은 deprecation window 1주기 한시 운용 (다음 release window 후 제거 예정)
  절차: |
    STATUS_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/status"
    OROOF_FLAG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/oroof_active"
    # [사이클39 L-77x] 파일명 양쪽 허용 — oroof_active 우선, 없으면 oroof_active.json 폴백.
    # 배경: 사이클38 실사고 — oto가 oralph_active.json 을 만들었는데 여기서는 확장자 없는
    #       이름만 봐서 2순위 폴백이 원리적으로 매칭 불가 → 검증 루프가 통째로 스킵됐다.
    #       기존 세션 호환을 위해 정본을 바꾸지 않고 양쪽을 모두 인정한다.
    if [ ! -f "${OROOF_FLAG}" ] && [ -f "${OROOF_FLAG}.json" ]; then
      OROOF_FLAG="${OROOF_FLAG}.json"
      echo "⚠️ [oroof gate] oroof_active.json 감지 — 파일명 폴백 적용 (정본은 확장자 없는 oroof_active)"
    fi
    # [ROOF-COMPAT] 구 이름 oralph_active(.json) 도 인식 — 신 이름 파일이 없을 때만 채택
    OLD_FLAG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/oralph_active"
    if [ ! -f "${OROOF_FLAG}" ]; then
      if [ -f "${OLD_FLAG}" ]; then
        OROOF_FLAG="${OLD_FLAG}"
        echo "⚠️ [oroof gate] 구 oralph_active 감지 — ROOF-COMPAT 폴백 적용"
      elif [ -f "${OLD_FLAG}.json" ]; then
        OROOF_FLAG="${OLD_FLAG}.json"
        echo "⚠️ [oroof gate] 구 oralph_active.json 감지 — ROOF-COMPAT 폴백 적용"
      fi
    fi

    # 1순위: status_has ROOF 검사 (신규 status 파일 기반) — 미양성 시 구 RALPH 토큰도 검사 (ROOF-COMPAT)
    # ★[사이클39] bash -c 래핑 필수 — bash_exec 의 셸은 /bin/sh(dash) 다.★
    #   dash 에는 source 가 없어 `source ...; status_has ...` 를 그대로 쓰면
    #   rc=127 로 조용히 죽고 status_has 가 항상 음성이 된다.
    #   ⇒ status 에 RALPH(현 ROOF) 가 ★실재해도★ ROOF_ACTIVE=false 로 떨어져 검증 루프가 스킵된다.
    #   (2026-08-26 실측 재현: status=[RALPH] 인데 RALPH_ACTIVE=false)
    #   dash 에서는 source 외에 [[ ]] · 배열 · ${PIPESTATUS} · 중괄호확장도 쓸 수 없다.
    ROOF_ACTIVE=false
    OROOF_DATA="{}"
    if bash -c 'source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/state_machine.sh" 2>/dev/null; status_has "'"${STATUS_FILE}"'" ROOF || status_has "'"${STATUS_FILE}"'" RALPH' 2>/dev/null; then
      ROOF_ACTIVE=true
      # status 파일에서 ROOF(또는 구 RALPH) 활성 — oroof_active 파일로 criteria/iter/max 보조 조회
      OROOF_DATA=$(cat "${OROOF_FLAG}" 2>/dev/null || echo "{}")
    # 2순위 폴백: oroof_active 파일 또는 구 oralph_active 파일 (deprecation window — 1주기 한시 운용)
    elif [ -f "${OROOF_FLAG}" ]; then
      ROOF_ACTIVE=true
      OROOF_DATA=$(cat "${OROOF_FLAG}" 2>/dev/null || echo "{}")
      echo "⚠️ [oroof gate] status=ROOF 미감지, oroof_active(구 oralph_active 포함) 파일로 폴백 (deprecation 경로)"
    fi

    if [ "${ROOF_ACTIVE}" = "true" ]; then
      CRITERIA=$(echo "${OROOF_DATA}" | jq -r '.criteria // "검증 기준 없음"' 2>/dev/null)
      ITER=$(echo "${OROOF_DATA}" | jq -r '.current_iteration // 0' 2>/dev/null)
      MAX=$(echo "${OROOF_DATA}" | jq -r '.max_iterations // 5' 2>/dev/null)
      echo "⏳ [oroof] ofinish 완료 — 검증 루프 진입"
      echo "   검증 기준: ${CRITERIA}"
      echo "   Iteration: $((ITER + 1)) / ${MAX}"
      echo "→ oroof Phase 2 (내장 검증 루프) 즉시 수행"
      # 재귀 카운터만 정리 (IDLE 전환 금지)
      mcp__oio__file_delete(path="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/ofinish_recurse_count")
      return  # IDLE 전환 스킵
    fi
    # oroof 없으면 아래 일반 종료 실행

  oroof_활성_시_금지:
    - state → IDLE 전환 절대 금지 (FINISH 상태 유지 필수 — FINISH→DEV 재실행 경로 유지)
    - oroof_active 파일 삭제 금지 (Phase 2 검증 완료 후 oroof가 직접 삭제. 구 oralph_active 도 동일)
    - ROOF status 토큰 삭제 금지 (oroof가 직접 status_remove ROOF 책임. 구 RALPH 토큰도 동일 — ROOF-COMPAT)

step8_peer_finish_notify (동일 프로젝트 타 세션 종료 통지 — 일반 IDLE 전환 분기 직전, ROOF 분기에서는 미발송):
  적용_조건: status_has ROOF(또는 구 RALPH) 음성 AND oroof_active(또는 구 oralph_active) 없음 (ROOF 중 FINISH 유지 시 오발송 방지). 메인이 수행.
  순서:
    1. session-env/${UUID}/peer_notified.json 읽기 (없으면 시작 통지 미수행 → 대상 파일이 없거나 비면 생략)
    2. ListAgents 재조회 (시작 후 새로 생긴 세션 포함). 후처리 hook 이 갱신한 자기 세션 session-env/${UUID}/peer_targets.json 을 대상으로 쓴다.
       파일이 없거나 오래됐으면 재조회한 ListAgents 출력에 ok 스킬과 같은 규칙(정본=활성 로컬 전원, 그 외=같은 프로젝트만, RC·offline·팀원·자기 제외)을 적용해 직접 산출한다.
       규칙으로 판별이 안 되는 세션(tmux 밖 등)은 한계 조항대로 처리하고 logs/peer_notify.log 에 1줄 기록한다 (무조건 전체 발송 폴백 금지).
    3. 대상별 SendMessage: "[작업종료][프로젝트:<프로젝트명>] <세션명> 작업 종료 — 변경 파일 N개(상위 10개 나열), 커밋: <해시>"
       타 세션 UUID/team_name/state 포함 금지.
    4. session-env/${UUID}/peer_finish_done 마커 기록
    5. 머신 간 통지 (ListAgents 통지와 별개로 추가 수행): 프로젝트 INFRA.md 의 INFRA-FIELDS 블록에서 `peer_ssh` 값을 읽는다.
       - 값이 ssh 별칭이면 3번과 같은 [작업종료] 본문을 stdin 으로 넘겨 `bash <프로젝트 루트>/.claude/scripts/peer_ssh_notify.sh send <peer_ssh값> <프로젝트명> 작업종료` 를 실행한다.
       - 값이 `outbox` 이면 `bash <프로젝트 루트>/.claude/scripts/peer_ssh_notify.sh send --outbox <프로젝트명> 작업종료` 를 실행한다.
       - 키가 없으면 이 단계를 생략한다.
       - 프로젝트 토큰은 INFRA-FIELDS project 값 그대로 쓴다(파일명 소문자 정규화는 스크립트가 한다).
       인계 통지([인계] 태그)를 보낼 때도 같은 분기를 쓰며 태그 인자만 `인계` 로 바꾼다. 타 세션 UUID/team_name/state 와 이메일은 포함 금지.
       실패(rc≠0 포함)는 logs/peer_notify.log 에 한 줄 기록 후 진행한다 (차단 금지).
    6. 대화 공유: 자동 대화 공유는 기본으로 하지 않는다(2026-11-07 사용자 결정). 대화를 보내려면 사용자가 /osync 를 부른다.
  실패_허용: 실패는 logs/peer_notify.log 에 한 줄 기록 후 계속 진행 (IDLE 전환 차단 금지)

step8_pre_cleanup (L-431 — 잔류 team_name 기반 다음 파이프라인 차단 재발방지 핵심):
  적용_조건: 일반_종료 진입 직전 (status_has ROOF·구 RALPH 음성 AND oroof_active·구 oralph_active 없음)
  목적: |
    Phase A 가설 (d) 해결 — ofinish가 명시적으로 session-env 하위 team_name 파일 정리 책임을 가져
    이전 _reset_idle 위임 모델의 /resume 시나리오 빈 team_name 잔존 버그 차단.
    state IDLE 전환 직전 오프닝 정리. teams/{name}/ 디렉토리는 건드리지 않음 (v2.1.178+ 세션 종료 시 자동 정리).
  순서:
    1. team_name 파일 비우기 (재발방지 핵심):
       mcp__oio__file_delete(path="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/team_name")
       # team_create_guard.sh가 빈/없는 team_name을 LIVE: 케이스로 오인하지 않도록 명시 삭제
    1b. team_name session_state 백엔드 빈값 기록 (file_delete 보강):
       mcp__oio__session_state(uuid="${UUID}", key="team_name", value="")
       # file_delete만 했을 때 session_state 백엔드 캐시에 team_name이 잔존하여
       # 다음 ok 진입 시 team_create_guard가 옛 team_name 보고 차단하는 사고 방지.
       # 빈값 기록은 fail-soft (실패 시 경고만 출력 후 계속 진행).
    2. teams/{name}/ 디렉토리 정리 금지 (v2.1.178+ — 세션 종료 시 Claude Code가 자동 정리):
       # ⚠️ 실측: 세션 활성 중 teams/{name}/를 수동 dir_delete/rm 하면 "team file not found"로
       #   이후 모든 Agent 호출이 전면 차단됨. 따라서 ofinish는 teams/ 디렉토리를 건드리지 않는다.
       # in-process 팀 정리 도구(TeamDelete)는 v2.1.178부터 제거됨 — 세션 종료 시 자동 정리에 위임.
       # 잔류 팀에이전트 pane은 Step 1(oinit)에서 tmux kill-pane(팀에이전트 pane만, 메인 %0 금지 — L-304)으로 처리.
    3. classification 파일 정리 (Phase B — level OK가 stage에서 분리되었으므로 세션 종료 시 명시 삭제):
       mcp__oio__file_delete(path="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/classification")
    3b. entry_tier 파일 정리 (신규 — ok 진입 흔적, 세션 종료 시 삭제):
       mcp__oio__file_delete(path="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/entry_tier")
    3c. goal.json 이행완료 보관 (L-548 — 잔류 goal.json이 다음 /oto 계약 생성을 차단하는 재발방지):
       조건: "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/goal.json" 존재
       동작: 삭제가 아니라 copy-first 3단계로 보관 (rename-first 대신 채택 — 실패 시 손실 최소화):
             1. copy: mcp__oio__file_copy(src="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/goal.json",
                dst="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/goal_{goal_id}_completed.json")
                # goal_id는 사전에 mcp__oio__file_read로 goal.json의 "goal_id" 필드 파싱 (G-XXXXXXXX 형식)
                # file_copy는 write_guard.sh F-GOAL-1 내부 case(file_edit|file_write|file_delete|
                # file_move|file_rename)에 없어 locked=true여도 차단되지 않는다 (비파괴이므로 허용된 경로).
             2. unlock: copy 성공이 확인된 경우에만, ★state=FINISH 인 동안★ 진행 (IDLE 전환 뒤에는 F-GOAL-1 이 막는다) —
                mcp__oio__file_edit로 원본 goal.json의 "locked" 필드를 true→false로 변경
                # 이 단계가 빠져 잠긴 옛 계약이 남아도, 다음 사이클 PLAN 에서 메인·oplan 팀원이 새 goal_id 계약을 file_write 하면
                # write_guard F-GOAL-1 의 "완료 보관된 옛 계약 교체" 예외가 통과시킨다(사본 내용 동일 + 사본이 그 파이프라인 시작 이전 — 사이클196 P5).
                (계약 재협상이 아니라 삭제를 위한 보관 목적 한정)
             3. delete: mcp__oio__file_delete(path="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/goal.json")
                # locked=false로 바뀌었으므로 F-GOAL-1에 걸리지 않고 통과
       이유: · 증적 보존 (계약 이행 기록을 세션 종료 후에도 확인 가능)
             · goal_id를 파일명에 포함해 어느 계약이었는지 구분 (사이클33 수동 처리 선례 확장)
             · 다음 사이클(oplan_normal Phase 0)이 새 계약(goal.json)을 생성할 수 있게 경로를 비움
             · copy-first 순서 채택 이유: 원래 검토했던 "unlock→rename" 2단계 순서는 1단계(unlock)만
               성공하고 2단계(rename)가 실패하면 증적도 없이 물리 보호만 풀리는 최악의 실패 모드가
               있었다. copy를 가장 먼저(locked=true 상태 그대로, 비파괴) 수행하면 그 실패 모드가 사라진다.
       단계별_실패_분기 (L-548 — 추정이 아니라 각 단계 실패 시 실제 상태를 명시):
         1(copy) 실패 → 중단. 원본 goal.json은 locked=true 그대로 무손상. 경고 출력. IDLE 전환은 계속.
         2(unlock) 실패 → 중단. 사본(goal_{goal_id}_completed.json)은 이미 존재하고 원본도 locked=true로
           보호 상태 유지 — 무해. 경고 출력. IDLE 전환은 계속.
         3(delete) 실패 → 경고 + 사실 기록. 원본 goal.json이 locked=false로 잔존.
           영향: oplan_normal Phase 0은 기존 goal.json이 있으면 시드로만 쓰고 생성을 건너뛴다
           (goal/SKILL.md L45) — 따라서 즉각적인 데이터 손실이나 덮어쓰기는 없다. 다만 이행 완료된
           계약이 물리 보호 없이 다음 사이클의 시드로 재사용될 위험이 남으므로, 경고 문구에
           "goal.json locked=false 잔존 — 다음 사이클 진입 전 확인 필요"를 남겨 다음 사이클이
           감지할 수 있게 한다. 사본은 이미 확보돼 있으므로 증적 손실은 0.
       실패_허용: 위 단계별 분기 모두 "중단/경고만" — IDLE 전환은 계속 진행 (다른 pre_cleanup과 동일)
  Hook_1순위_미적용_사유 (CLAUDE.md 재발방지 정책 요구 — L-548):
    goal.json 정리는 "acceptance 평가 결과(이행 완료 여부)를 참조하는 조건부 이동"이라
    순수 물리차단(hook)으로는 구현 불가 — hook은 무조건 차단/허용만 판단하고 파일 내용 기반
    조건부 copy→unlock→delete 순서 로직을 수행할 수 없다. 따라서 ofinish 절차 단계(2순위 Script)로 강제한다.
    3d. 타 세션 통지 마커 정리 (자기 UUID 경로만, 종료 통지 단계(step8_peer_finish_notify) 이후 수행):
       mcp__oio__file_delete 로 session-env/${UUID}/ 하위 peer_notified.json, peer_check_done, peer_finish_done 삭제 (없으면 건너뜀)
  실패_허용: 각 단계 실패 시 경고만 출력 후 계속 진행 (state IDLE 전환 차단 금지)
  금지:
    - pre_cleanup 누락 후 state IDLE 전환 (재발방지 무력화)
    - teams/{name}/ 디렉토리 수동 dir_delete/rm (세션 활성 중 삭제 시 Agent 호출 전면 차단 — v2.1.178+)
    - 다른 세션 team_name 정리 (세션 격리 §(b) 위반)
    - goal.json locked=true 상태에서 file_delete로 직접 삭제 시도 (F-GOAL-1 차단 — 반드시 copy→unlock→delete 순서 준수)
    - unlock(2단계) 전에 copy(1단계) 성공 확인 생략 (copy 실패 시 원본을 unlock하면 증적 없이 보호만 풀림)

step8_pipeline_종료:
  적용_조건: status_has ROOF·구 RALPH 음성 AND oroof_active·구 oralph_active 파일 없을 때만 (일반 파이프라인 종료)
  주의: ntfy 발송(Step 7) + o1/o2 커밋(Step 7.5) + step8_pre_cleanup 완료 후 마지막으로 실행
  문서_갱신_게이트 (O1/O2 — 순서 2 의 IDLE 호출에서 판정, 검토 필수-1):
    - tier 원천: hook 은 Step 0.5 FINISH 진입 때 기록한 session-env/${UUID}/docs_gate_tier 만 읽는다(classification 은 쓰지 않는다).
      pre_cleanup_3 이 classification 을 먼저 지워도 판정이 살아 있는 이유다. 따라서 docs_gate_tier 는 pre_cleanup 에서 지우지 않는다(IDLE 전이 전 삭제 금지).
    - 코드 변경이 있는데 HISTORY.md 가 미변경이면 IDLE 호출이 block 되고 state 는 FINISH 로 남는다.
      복구: Step 7.5 HISTORY 1줄 기록 → 커밋 후 IDLE 재시도, 또는 docs_update_waiver 에 "HISTORY: 사유(10자+)" 를 쓰고 재시도. 우회 금지(L-597).
    - docs_gate_tier 정리: IDLE 판정 직후 hook 이 직접 지운다. 순서 4b 는 IDLE 전환 이후의 안전망이다.
      잔존해도 hook 이 state=FINISH 와 마커 mtime ≥ 사이클 시작 시각을 함께 확인하므로 다음 사이클에 영향이 없다.
  순서:
    1. status_clear (★bash -c 래핑 필수 — bash_exec 셸은 dash 라 source 없이는 rc=127★):
       bash -c 'source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/state_machine.sh"; status_clear "'"${STATUS_FILE}"'"'
       # ROOF 외 잔류 토큰(PAUSE/ABORT) 정리 — ROOF(구 RALPH)는 oroof 책임이므로 이 시점엔 이미 비워짐
       # ⚠️ 미래핑 시 rc=127 로 조용히 실패하고 PAUSE/ABORT 가 그대로 잔류한다 (2026-08-26 실측)
    2. state → IDLE: mcp__oio__session_state(uuid="${UUID}", key="state", value="IDLE")  ← bash echo 대신 MCP 도구 단독 호출 (필수)
    3. ok_loaded 저장: mcp__oio__session_state(uuid="${UUID}", key="ok_loaded", value="true")  # ok/SKILL.md 세션당_1회_제한 명세
    4. 재귀 카운터 정리: mcp__oio__file_delete(path="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/ofinish_recurse_count")
    4b. 문서 게이트 tier 마커 안전망 정리 (hook 이 IDLE 판정 직후 직접 지우므로 대개 이미 없다. IDLE 전이 전에 지우지 말 것 — 앞에서 지우면 O1/O2 판정이 사문화된다):
       mcp__oio__file_delete(path="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/docs_gate_tier")  # 없으면 건너뜀
  금지:
    - echo "IDLE" > state를 bash 체인 내에서 실행 (경합으로 FINISH 잔류 위험)
    - Step 6/7/7.5 이전에 IDLE 전환 (ntfy/커밋이 IDLE 상태로 실행되어 hook 충돌)
    - oroof 활성 중(ROOF 또는 구 RALPH 양성) status_clear 호출 (ROOF/RALPH 토큰 임의 삭제 금지)
    - state OK 분기 잔존 (Phase B — stage에서 OK 제거됨, FINISH→IDLE 직선 전이만 허용)
  # ofinish_done 마커는 Step 6에서 미리 생성됨
  # ABORT/PAUSE는 oinit/context_usage_check 별도 책임 — status_clear가 이를 정리하는 부수 효과는 허용
  # state OK 분기는 Phase B 마이그레이션으로 stage에서 제거됨 — DONE→FINISH→IDLE 직선 전이

```

---

## 실행 순서 (v4.5 — 엄수)

```yaml
전제: 마지막 팀에이전트 완료 보고 수신 (또는 /ofinish 독립 실행)

Step 0.5: state → FINISH
  mcp__oio__session_state(uuid="${UUID}", key="state", value="FINISH")
  # echo "FINISH ${UUID}" > state 금지 — write_guard.sh F1 차단됨

Step 1: 팀 정리 + serena 정리 — Skill('oinit') 위임
  Skill('oinit')  # 상세 로직: oinit/SKILL.md 참조

Step 1.5: o1/o2 경량 교훈 (tier=O1/O2만)
  tier=$(cat ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/classification 2>/dev/null || echo "")
  위반 발생 시만 교훈 1줄 수집 (odone_lesson 미호출)

Step 2: 에이전트 통계 출력
  agent_stats.json 읽기 → 출력 (없으면 스킵)

Step 3: 잔여 Phase Batch 안전망 (백업 — 주 루프는 ok_pipeline 4.5단계)
  phase_batches.json 존재 + current < total (비정상 경로):
    → 경고 출력 + odev 재spawn (Agent team_name 지정 → 팀/config.json 자동 생성, 백업 루프)
  phase_batches.json 미존재 OR current >= total:
    → "다음 Phase 없음" → Step 4로 진행 (최종 마무리)

Step 4: 임시 파일 삭제
  CLEANUP_FILES.md 참조 — 4-0a harness_cleanup.py 승격+자기 세션 정리 → 4-0b 죽은 세션 자동 회수(승인 표식 있을 때만) → 4-1 기존 삭제 목록

Step 5: 종료 배너
  커밋 해시 + 변경 파일 수 + IDLE

Step 6: checkpoint 기록 + ofinish_done 마커 생성
  주의: 각 도구를 개별 호출 (bash 체인 금지)
  1. checkpoint_기록_FINISH_DONE: mcp__oio__bash_exec(command='bash ${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/checkpoint_write.sh "${UUID}" "FINISH_DONE" "FINISH" "" "" ""')
  2. mcp__oio__file_write(path="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/evidence/ofinish_done", content=타임스탬프)
  # ofinish_done 마커는 Stop hook(ofinish_guard.sh)이 검증 — 미생성 시 경고
  # state → IDLE은 Step 8에서 수행 (ntfy/커밋 완료 후)

Step 7: ntfy 발송
  bash hooks/lib/ntfy_send.sh --session-dir … --project-dir … (페이로드 없으면 재구성, 토픽 없으면 rc=3 배너 표기)
  없으면 스킵

Step 7.5: o1/o2 경량 커밋 (tier=O1/O2만)
  Step 1.5(경량 교훈)와 짝을 이루는 커밋 단계
  git add 직전 프로젝트 git 루트 HISTORY.md 첫 `---` 다음에 1줄 이력 기록 (없으면 생략·로그 — 상세는 Step 7.5 정의)
  mcp__oio__bash_exec로 세션 worktree 에서 경로 지정 git add + commit 직접 수행 후 wt_lib push 로 push (odone_git 미호출)
  O3+는 이 Step 스킵 (odone_git이 담당)

Step 8: oroof gate → pre_cleanup → state → IDLE + 재귀 카운터 정리 (최후 단계 — 절대 이전으로 이동 금지)
  # [oroof gate] IDLE 전환 전에 oroof 활성 여부 확인 (status_has ROOF 우선 → oroof_active 파일 폴백)
  # [ROOF-COMPAT] 구 RALPH status 토큰과 구 oralph_active(.json) 파일도 함께 인식한다. 구 이름 폴백은 deprecation window 1주기 한시 운용
  # [pre_cleanup] L-431 재발방지 — team_name/classification 명시 삭제 (state IDLE 전환 직전). teams/{name}/ 디렉토리는 미삭제 (v2.1.178+ 자동 정리)
  oroof_gate_확인:
    STATUS_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/status"
    OROOF_FLAG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/oroof_active"
    # [사이클39] 파일명 양쪽 허용 — ${OROOF_FLAG} 부재 시 ${OROOF_FLAG}.json 을 폴백으로 채택
    #   (사이클38 실사고: oto가 .json 으로 써서 폴백이 원리적으로 매칭 불가 → 루프 통째 스킵)
    # 1순위: status_has ROOF (또는 구 RALPH) (신규 status 파일 기반)
    # 2순위 폴백: oroof_active·oroof_active.json, 또는 구 oralph_active·oralph_active.json 파일 존재 (deprecation window — 1주기 한시)
    ROOF_ACTIVE = status_has ROOF(또는 구 RALPH) 양성 OR (oroof_active·oroof_active.json·구 oralph_active·구 oralph_active.json) 파일 존재
    ROOF_ACTIVE=true_시:
      - IDLE 전환 절대 금지 — state = FINISH 유지
      - ofinish_recurse_count 삭제만 수행
      - 출력:
          ⏳ [oroof] ofinish 완료 — 검증 루프 진입
          검증 기준: {oroof_active 파일의 criteria 필드 또는 "검증 기준 없음"}
          Iteration: {current_iteration + 1} / {max_iterations}
          → 지금 즉시 oroof Phase 2 검증을 수행하라
      - 이후: oroof Phase 2 (내장 검증 루프)를 즉시 수행하라 — ralph-loop 외부 호출 금지 (v4.0)
    ROOF_ACTIVE=false_시 (둘 다 음성):
      - 아래 일반 IDLE 전환 실행

  일반_종료 (status_has ROOF·구 RALPH 음성 AND oroof_active·구 oralph_active 없을 때만):
  # [Step 8 pre_cleanup — L-431 재발방지 핵심] state IDLE 전환 직전 오프닝 정리
  pre_cleanup_0. ★agents/ + inboxes 양쪽 base 정리 (F-ROSTER-1 — 2026-09-13 신설)★
    mcp__oio__bash_exec(command='bash -c "export ROSTER_EMIT_TASKSTOP=1; source ${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/agent_roster_cleanup.sh; cleanup_agent_roster \"${UUID}\" \"${TEAM_NAME}\""')
    # 배경: 사이클123 은 "roster 는 in-memory 라 못 지운다"(Issue #27639)로 결론냈으나 절반만 맞았다.
    #   사이클125 실측 — pane 0 / 프로세스 0 / config.json isActive 전부 false 인데도
    #   ★$HOME 쪽 agents/ 에 21건 잔존★(사이클123 것까지 섞여 세션 재시작으로도 안 지워졌다).
    #   원인은 ★경로 이중화★ — ofinish 가 ${CLAUDE_CONFIG_DIR} 쪽만 비우고 $HOME 쪽을 빠뜨렸다.
    # 이 헬퍼는 양쪽 base 를 모두 돌며 ★프로세스 실존으로만★ 판정해 죽은 것만 지운다
    #   (agents/ 파일 존재는 생존의 증거가 아니다 — 10시간 잔존 실측 이력).
    # ⚠️ teams/<name>/ 디렉토리와 config.json 은 건드리지 않는다(삭제 시 Agent 전면 차단).
    #   inboxes/*.json 개별 파일만 정리하며 team-lead 메일함은 보존한다.
    # 목록 정리 (2026-10-16 실측 정정): FleetView/roster 가 "세션 재시작으로만 비워진다"는 서술은 틀렸다.
    #   · 정상 종료 팀원은 shutdown_approved 로 목록에서 자동 제거된다.
    #   · 비정상 종료(프로세스만 사라진) 팀원은 메인이 TaskStop 으로 정리할 수 있다 (아래 pre_cleanup_0b).
    #   디스크 정리는 이 헬퍼가, 목록 표시 정리는 TaskStop 이 맡는다.
  pre_cleanup_0b. ★프로세스 없는 팀원 TaskStop 정리 (2026-10-16 신설 — 메인만 호출 가능, hook 불가)★
    입력: 1차는 위 헬퍼가 항상 기록하는 `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/logs/taskstop_pending.txt` (한 줄에 팀원 이름 1개) 이다. `ROSTER_EMIT_TASKSTOP=1` 일 때만 출력되는 `TASKSTOP_PENDING n: …` 줄은 보조다.
    절차: 파일이 있으면 각 이름에 대해 TaskStop(task_id=<이름>) 호출 → ListAgents 로 소멸 확인(또는 TaskStop 오류 메시지의 Running teammates 목록에 없음을 확인).
    판정: 대상은 `--agent-id <name>@<팀>` 프로세스가 ★없는★ 팀원으로 한정한다. 살아서 작업 중인 팀원에게 호출하면 그 작업이 중단되므로 절대 금지다.
    무해 케이스: "No task found with ID: ... Running teammates: ..." 오류는 이미 정상 종료/제거된 이름이라는 뜻이며 무해하다 (실측 2026-10-16).
    실패 허용: 파일 부재·TaskStop 오류가 Step 8 진행을 막지 않는다. 처리 후 taskstop_pending.txt 는 자기 세션 logs 에서 삭제한다.
  pre_cleanup_1. mcp__oio__file_delete(path="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/team_name")  # 빈 team_name 잔존 차단
  pre_cleanup_1b. mcp__oio__session_state(uuid="${UUID}", key="team_name", value="")  # 백엔드 캐시 동기화 (file_delete 보강 — team_create_guard 오인 차단)
  # pre_cleanup_2 제거 (v2.1.178+): teams/{name}/ 디렉토리는 ofinish가 건드리지 않음 — 세션 종료 시 Claude Code 자동 정리. 잔류 pane은 Step 1(oinit) tmux kill-pane 처리.
  pre_cleanup_3. mcp__oio__file_delete(path="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/classification")  # Phase B level OK 잔존 정리
  pre_cleanup_3b. mcp__oio__file_delete(path="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/entry_tier")  # 신규 — ok 진입 흔적 정리
  pre_cleanup_3c. goal.json 존재 시 copy→unlock→delete 3단계로 goal_{goal_id}_completed.json 보관 (L-548 — 삭제 아님, copy는 locked=true 상태에서도 F-GOAL-1 미차단. 단계별 실패 분기: 상세는 step8_pre_cleanup 정의 참조)
  # ─── 일반_종료 ───
  0. status_clear (★bash -c 래핑 필수 — dash 에는 source 가 없다★):
     bash -c 'source "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/state_machine.sh"; status_clear "'"${STATUS_FILE}"'"'
     # 잔류 토큰(PAUSE/ABORT 등) 정리 — ROOF(구 RALPH)는 이 시점 이미 비워짐 (oroof 책임)
  1. mcp__oio__session_state(uuid="${UUID}", key="state", value="IDLE")  ← 단독 호출 필수
     # O1/O2 는 이 호출에서 문서 갱신 게이트가 판정한다(tier 원천은 docs_gate_tier 만 — pre_cleanup_3 이후여도 유효). block 시 FINISH 유지 → Step 7.5 HISTORY 1줄 또는 사유 파일 후 재시도.
  2. mcp__oio__session_state(uuid="${UUID}", key="ok_loaded", value="true")  # ok_loaded 저장 (ok/SKILL.md 세션당_1회_제한 명세)
  3. mcp__oio__file_delete(path="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/ofinish_recurse_count")
  3b. mcp__oio__file_delete(path="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/docs_gate_tier")  # 문서 게이트 tier 마커 안전망(hook 이 IDLE 판정 직후 직접 삭제) — IDLE 전이 전에 지우지 말 것, 없으면 건너뜀
  4. auto 플래그 정리 (oto 자율모드 — autoloop 계속 시에는 보존):
     조건: Step 3.5에서 autoloop 통지를 출력했으면 삭제 금지 (다음 사이클이 자율모드를 이어받아야 함).
           미소비 carryover(next_action.json 의 handoff_kind:"carryover")가 존재하면 삭제 금지(보존).
           autoloop 미발동(next_action.json 부재/거부/3회 초과/ABORT·PAUSE)이고 미소비 carryover 도 없으면 삭제.
     삭제: mcp__oio__file_delete(path="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/auto")
     이유: 여기서 무조건 삭제하면 autoloop 2번째 사이클부터 일반 모드로 강등되어
           /oto의 "끝까지 무정지 완주"가 깨진다. 반대로 최종 종료 시 미삭제하면
           다음 파이프라인이 의도치 않게 자율모드로 동작한다 (양방향 누출 방지).
  # 이 단계가 ofinish의 진짜 마지막. IDLE 전환 후 hook이 새 사용자 입력을 IDLE 모드로 처리.
  # state OK 분기는 Phase B에서 제거됨 — DONE→FINISH→IDLE 직선 전이만 허용

  # [batch_3 placeholder] force_idle_unlock 조건부 내재화 위치 — V2 구현 후 IDLE 고착 재발 시 활성화
```

---

## ntfy 발송 상세

> → 중단 시 ntfy 즉시 발송 + ntfy 페이로드 생성: [references/CLEANUP_FILES.md](references/CLEANUP_FILES.md)

---

## 에러 처리

```yaml
팀_정리: ofinish 미수행 — 세션 종료 시 Claude Code 자동 정리 (v2.1.178+). 잔류 pane은 Step 1(oinit) tmux kill-pane 처리.
통계_파일_없음: "통계 파일 없음" + 스킵
Git_실패: "커밋 없음" / "변경 파일 없음" 표시
```

---

## 금지 사항

1. **팀에이전트에서 ofinish 실행 금지** — 메인 전용
2. **odone 이전 실행 금지** — hook: write_guard.sh + phase_guard.sh가 파이프라인 상태 강제
3. **프로젝트 고유 경로 사용 금지** — 범용 스킬 원칙
4. **pipeline_state 강제 변경 금지** — IDLE로만 리셋
5. **ofinish 건너뛰기 금지** — IDLE 전환 시 ofinish 절차 필수
6. **tmux kill-window 금지** — segfault 위험 (L-114). kill-pane은 status off + kill/kill-9 실패 시 3단계 최후 수단으로만 허용 (L-195)
7. **정상 경로에서 odone 미완료 상태로 ofinish 진입 금지** — 단, 조기 종료(L-216) 시 중단 결정 즉시 진입 허용
8. **teams/ 디렉토리 rm -rf / dir_delete 전면 금지 (ofinish 내부 포함)** — 세션 활성 중 삭제 시 Agent 호출 전면 차단 (v2.1.178+). 세션 종료 시 Claude Code 자동 정리. team_dir_guard.sh hook 물리 차단 (L-138)
9. **send-keys exit 전면 금지** — kill PID 방식으로 대체 (L-191)
10. **소멸 확인 없이 pane 정리 금지** — 소멸 확인 → kill PID → orphan 기록 (L-155)
11. **Step 2~7 병렬 도구 호출 금지** — 각 Step 순차 실행 필수 (L-197: 실패 가능 명령 연쇄 실패 방지)
12. **이전 세션 잔류 팀 rm -rf 금지** — leadSessionId 불일치 팀은 건드리지 않음. 수동 정리는 /ofinish 독립 실행 (L-197)
13. **Step 1(oinit) 스킵 금지** — L-320: 팀/pane 0개여도 반드시 Skill('oinit') 실행

---

## 반환 메시지 형식

```
✅ ofinish 완료

- 에이전트 발동 통계: team=4 sub=0 task=12
- pipeline_state: IDLE

📊 spawn_stats: team=0 sub=0 task=0
```

---

## 참조

- **교훈 참조**: [references/CLEANUP_FILES.md](references/CLEANUP_FILES.md) "교훈 참조" 섹션 (L-136~L-213)
