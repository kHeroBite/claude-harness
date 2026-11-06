---
name: ok_pipeline
description: "코드 수정 오케스트레이션 파이프라인 (o2~o5 tier 기반). 팀 자동 생성(Agent team_name 지정), 에이전트 등록, 상태 전파, oplan/odev/otest/odone spawn 절차, 역라우팅 포함. Auto-activates when: 분류 == o2~o5일 때 ok 메인에서 Skill('ok_pipeline') 호출."
invocation:
  user_callable: false
  pipeline_callable: true
  called_by: [ok(o2~o5)]
  calls: [oplan계열, odev, otest, odone, otest_verify, ofinish]
---
# ok_pipeline — 코드 수정 오케스트레이션 파이프라인 (o2~o5 tier 기반)

> **호출 조건**: ok가 oplan 완료 후 tier를 수신한 뒤 Skill('ok_pipeline') 호출 — tier + oplan_output_path 파라미터 필수
> **v4.1 변경**: oplan은 ok가 직접 spawn/관리. ok_pipeline은 odev부터 시작 (oplan 단계 없음)
> **o1 작업 시**: 이 스킬 로딩 불필요 (odev + ofinish만 spawn)
> **포함 내용**: 에이전트 등록, 상태 전파, tier별 odev/otest/odone spawn 절차, 역라우팅, 제약사항

## 🚨 팀에이전트 전면 위임 정책 (절대 규칙)

```yaml
원칙: 모든 메인스킬(oplan/odev/otest/odone)은 반드시 팀에이전트로 spawn. 메인이 직접 실행 절대 금지.
목적: 메인 컨텍스트 보호 + 파이프라인 일관성

tier별_팀에이전트_spawn_매트릭스:
  o1:
    oplan: 없음 (o1은 oplan 미실행)
    odev: 팀에이전트 1개 (최소 보장)
    otest: 없음 (o1은 otest 미실행)
    odone: 없음 (ofinish Step 1.5 대체)
  o2:
    oplan_simple: 팀에이전트 1개 (/o2 직접 호출 시에도, /ok 경유 시에도 동일)
    odev: 팀에이전트 1~3개
    obr: 팀에이전트 1개
    odone: 없음 (ofinish Step 7.5 대체)
  o3:
    oplan_normal: 팀에이전트 1개
    odev: 팀에이전트 1~N개
    odev_review: 팀에이전트 1개
    otest: 자원 축당 팀에이전트 1개 (데스크톱 otest-N 1개 + 모바일 otest-m-N 1개 + 웹 otest-w-N 1개 병렬 허용 — 3단계 "otest 자원 축 병렬")
    odone: 팀에이전트 1개 (항상 1개만)
  o4:
    oplan_deep: 팀에이전트 1개
    odev: 팀에이전트 1~N개
    odev_review: 팀에이전트 1개
    odev_simplify: 팀에이전트 1개
    otest: 자원 축당 팀에이전트 1개 (데스크톱 otest-N 1개 + 모바일 otest-m-N 1개 + 웹 otest-w-N 1개 병렬 허용 — 3단계 "otest 자원 축 병렬")
    odone: 팀에이전트 1개 (항상 1개만)
  o5:
    oplan_debate: 팀에이전트 4개 (oplan-1 + oplan-2 + oplan-3 + oplan-final) — 기본
    oplan_consult: 팀에이전트 1개 (oplan-consult-1) + Codex 서브에이전트(내부) — oplan_debate 대안 선택 시
    odev: 팀에이전트 1~N개
    odev_review: 팀에이전트 1개
    odev_simplify: 팀에이전트 1개
    otest: 자원 축당 팀에이전트 1개 (데스크톱 otest-N 1개 + 모바일 otest-m-N 1개 + 웹 otest-w-N 1개 병렬 허용 — 3단계 "otest 자원 축 병렬")
    odone: 팀에이전트 1개 (항상 1개만)

서브에이전트_사용_위치: 팀에이전트 내부에서만 Agent tool로 생성
  예: odev 팀에이전트가 odev_parallel로 파일별 서브에이전트 spawn
  예: otest 팀에이전트가 otest_build/otest_run을 서브에이전트로 병렬 실행

팀에이전트_추가_spawn_금지:
  규칙: 팀에이전트는 새로운 팀에이전트를 직접 spawn할 수 없음 (flat team)
  필요_시: 메인에게 SPAWN_REQUEST 위임 (Spawn 위임 프로토콜 참조)
  해당_스킬: odev(odev_review/odev_simplify 필요 시), otest(odebug 필요 시), odone(서브스킬 병렬 시)

메인_직접_실행_유일한_예외: ofinish만 (팀 정리는 메인이 직접 수행)
```

## 🚫🚫🚫 팀에이전트 spawn 2대 절대 규칙 (위반 시 hook 물리 차단) 🚫🚫🚫

> **이 규칙은 파이프라인의 모든 단계(oplan/odev/otest/odone 및 모든 하위 에이전트)에 예외 없이 적용된다.**
> **fallback/대체/재spawn/2차시도 포함 — 단 한 번도 예외 없음.**

```
╔══════════════════════════════════════════════════════════════════════╗
║  규칙 1: 모든 팀에이전트는 반드시 팀에이전트로 spawn                 ║
║           → Agent(... team_name="{팀명}" ...) 필수                  ║
║                                                                      ║
║  규칙 2: subagent_type 반드시 명시                                   ║
║           → Agent(subagent_type="general-purpose" ...) 필수         ║
╠══════════════════════════════════════════════════════════════════════╣
║  ✅ 올바른 형식 (이 형식만 허용):                                    ║
║     Agent(                                                           ║
║       subagent_type="general-purpose",   ← 필수 (빈값 절대 금지)    ║
║       name="odev-1",                     ← 필수 (없으면 pane 미생성)║
║       team_name="{팀명}",               ← 필수 (없으면 hook 차단)  ║
║       mode="bypassPermissions",          ← 필수 (권한 대기 방지)    ║
║       ...                                                            ║
║     )                                                                ║
╠══════════════════════════════════════════════════════════════════════╣
║  ❌ 금지 형식 (hook이 즉시 block 반환):                              ║
║     Agent(name="odev-1", ...)            ← team_name 누락 → 차단   ║
║     Agent(team_name="...", name="...",)  ← subagent_type 누락 → 차단║
║     Agent(subagent_type="...", ...)      ← name/team_name 누락 → 차단║
╠══════════════════════════════════════════════════════════════════════╣
║  team_name 조회 방법:                                                ║
║     TEAM_NAME=$(cat $HOME/.claude/session-env/${UUID}/team_name)    ║
╚══════════════════════════════════════════════════════════════════════╝
```

> ⚠️ 런타임 실제 팀명은 `$CLAUDE_CONFIG_DIR/teams/session-*`(프로세스 시작 시 세션ID 기준)이며 `session-{UUID앞8자}`와 다를 수 있다(/clear·resume 후). Agent 도구의 team_name 파라미터 값은 런타임이 무시하지만(Deprecated), hook·스킬의 팀 추적 규약상 여전히 필수로 넘긴다. 파이프라인 진입 시 mcp__oio__session_state(uuid, key="team_name", value=<팀명>) 기록이 정본이다.

```yaml
물리_차단_hook:
  full_task_team_guard.sh: team_name 없는 Agent 호출 → "block" 즉시 반환
  no_team_agent_guard.sh: subagent_type 빈값 Agent 호출 → "block" 즉시 반환
  재발_이력: L-021 (subagent_type 누락 3회 재발), 규칙 1 위반 다수
```

## 인스턴스 플랜 수동 직접 호출 — PLAN state 미진입 원칙 (L-422)

> `/oplan_debate`, `/oplan_deep`, `/oplan_consult`, `/odebate`, `/odeep`, `/oconsult` 직접 호출 시:
> **ok 파이프라인을 경유하지 않으므로 state=PLAN 전파 금지. IDLE 상태 유지.**

```yaml
인스턴스_플랜_수동_호출_원칙:
  대상: /oplan_debate, /oplan_deep, /oplan_consult, /odebate, /odeep, /oconsult 직접 호출
  설명: 정식 파이프라인(/ok, /o4, /o5) 없이 계획 수립만 독립 실행하는 인스턴스 플랜
  state_규칙:
    - 진입 시 state=PLAN 설정 금지 (ok_pipeline 경유 시에만 PLAN 전파)
    - 실행 중 IDLE 상태 유지 (팀에이전트 spawn해도 메인 state 변경 없음)
    - 완료 후 ofinish(경량 — IDLE 복원, 팀은 세션 종료 시 자동 정리) 호출
  이유: PLAN state 잔류 시 후속 /o4 등 슬래시 명령이 oi_route_guard에 차단됨 (워크플로 중단)
  재발방지: ok_pipeline 상태 전파 매핑(아래)은 ok 경유 시에만 적용 — 수동 직접 호출은 제외
  교훈_등재: L-422 (conv_177742761168 사용자 명시 지적)
```

## tier별 파이프라인 분기

```yaml
tier_파이프라인_분기 (ok_pipeline 진입 시 tier 파라미터 기반):
  o2 (Simple):
    흐름: oplan_simple → odev → obr(팀에이전트) → ofinish(Step1.5+7.5)
    otest: 없음 (obr만 — 팀에이전트 spawn) | odone: 없음 | 토론: 없음
  o3 (Normal):
    흐름: oplan_normal → odev(xN) → otest(3단계: otest_infra→otest_verify→otest_evidence) → odone(Fast) → ofinish
    otest: 필수 | odone: Fast Path | 토론: 없음
  o4 (Heavy):
    흐름: oplan_deep(+선택 oplan_debate) → odev(xN) → otest(전체) → odone(Full) → ofinish
    otest: 필수(전체) | odone: Full Path | 토론: 선택(DEBATE_ROUTING)
  o5 (Massive):
    흐름: oplan_debate(필수) → odev(xN) → otest(전체+UI필수) → odone(Full+Gate) → ofinish
    otest: 필수(전체+UI) | odone: Full Path+Gate | 토론: 필수

모델_배정: ok_model/SKILL.md 참조 (단일 출처)
```

## o2 파이프라인 (otest 대신 obr, odone 없음)

> o2 = 코드 파일 1~3개 AND 수정 20~50줄. otest 대신 obr(빌드+실행) 필수.
> 흐름: oplan_simple → odev → obr → ofinish(Step1.5+7.5)

```yaml
o2_오케스트레이션:
  1단계_odev: odev×N 팀에이전트 spawn → 완료 수신
  2.5단계_obr: 팀에이전트 spawn으로 obr 실행 (메인 직접 실행 금지 — write_guard hook 차단됨)
    STATE: mcp__oio__session_state(uuid="${UUID}", key="state", value="TEST") (spawn 직전)
    spawn: Agent(subagent_type="general-purpose", name="otest-1", team_name="{팀명}", model="sonnet", mode="bypassPermissions", prompt="Skill('obr')... 완료 시 SendMessage(to:'team-lead', message:'obr 완료/실패', summary:'obr 결과 보고')")
    성공: ofinish 진입
    실패: odev 역라우팅 (빌드 오류 시 odev 재spawn)
    obr_2회_실패: o3으로 동적 승격
      승격_시_classification_갱신 (P0-3 — otest_done_guard 정합):
        mcp__oio__session_state(uuid="${UUID}", key="classification", value="O3")
        # classification이 O2로 남으면 otest_done_guard가 O2로 판정 → otest 스킵 → 승격 무의미
        배너_재출력: "🔄 o2→o3 동적 승격 — classification=O3으로 갱신 완료"
  evidence_경로: o2는 otest_evidence 미실행 — otest_done 마커 없음. ofinish는 o2에서 otest_done 마커를 검증하지 않음 (obr 결과로 대체).
  3단계_ofinish: 메인이 직접 실행 (Step 1.5 경량 교훈 + Step 7.5 경량 커밋)
```

## 코드 수정 오케스트레이션

> 메인이 4단계 파이프라인을 직접 수행. 팀에이전트를 같은 팀에 순차 spawn.

### 팀 생성(자동) + 에이전트 등록 + shutdown_sent

> 상세: [references/AGENT_OPS.md](references/AGENT_OPS.md) — 팀 자동 생성(L-221), 에이전트 등록(L-235), shutdown_sent(L-241)
> ⚠️ Claude Code v2.1.178+부터 TeamCreate/TeamDelete 제거됨. team_name은 Agent 호출 시 지정하면 tmux pane + teams/<팀>/config.json이 자동 생성된다. 세션 종료 시 자동 정리. (공식: code.claude.com/docs/en/agent-teams)

```yaml
핵심_요약:
  팀_생성: 별도 사전 생성 불필요. team_name은 Agent 호출 시 지정하면 자동 생성됨 (L-221).
  팀_생성_사전_precheck (2026-05-11 — 사이드이펙트 0 예방책):
    # 목적: in-process 잔존 마커가 있으면 spawn 전에 차단.
    # 자기 세션의 team_name 파일 정합성만 검사 (read-only, 타 세션 무영향).
    0. inprocess_stuck 마커 감지 (최우선):
       마커 경로: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/evidence/inprocess_stuck
       마커 존재 시:
         → echo "❌ [팀 spawn 차단] in-process 캐시 잔존 마커 감지"
         → echo "   마커 내용: $(cat ...evidence/inprocess_stuck)"
         → echo "   조치: /oinit 실행 또는 세션 재기동 후 재시도"
         → echo "   ⚠️ in-process 캐시 잔존 — /oinit 또는 세션 재기동 필요"
         → 파이프라인 중단 (사용자 /oinit 또는 세션 재기동 대기)
       마커 부재 시: 정상, 바로 Agent spawn 진입 (team_name 지정 시 자동 생성)
  팀_생성_원칙 (자동):
    - team_name은 Agent 호출 시 지정. 별도 사전 생성 불필요 (Agent 호출 시 자동 생성됨).
    - ⚠️ 활성 세션 중 teams/<팀>/ 디렉토리 수동 삭제 절대 금지 — Agent spawn이 전면 차단됨 (2026-06-18 실측).
    - 팀은 세션 종료 시 자동 정리. 명시적 삭제 불필요.
    - ⚠️ 런타임 실제 팀명은 `$CLAUDE_CONFIG_DIR/teams/session-*`(프로세스 시작 시 세션ID 기준)이며 `session-{UUID앞8자}`와 다를 수 있다(/clear·resume 후). 이 경우는 hook 차단 대상이 아니다.
  config.json_자동_생성 (L-340 — 2026-04-09 기준, v2.1.178+ 단순화):
    - team_name 지정한 Agent 호출 시 teams/{팀명}/config.json이 자동 생성됨.
    - 별도 사전 생성/재생성 불필요. 활성 세션 중 수동 삭제 금지.
  에이전트_등록: spawn 직후 agents/{에이전트명} 파일 확인 (hook 자동 + 수동 폴백)
  shutdown_sent: shutdown_request 발송 직후 agents/{에이전트명}에 플래그 기록
  shutdown_흐름:
    ① 메인: SendMessage(to: {name}, type="shutdown_request")
    ② 팀에이전트: shutdown_response 발송 후 종료
    ③ 메인: pane 소멸 확인 (최대 30초) → 미소멸 시 tmux kill-pane 강제 종료
```

### 파이프라인 상태 전파 (메인이 직접 수행 — 진입 기반)

```yaml
전파_시점: 각 단계의 팀에이전트 spawn 직전 (진입 기반 — 비정상종료 시 어느 단계에서 실패했는지 식별 가능)
전파_방법: mcp__oio__session_state(uuid="${UUID}", key="state", value="{단계}")
  주의: 세션별 파일 사용. UUID는 ok 로딩 시 결정된 값. 원자적 쓰기는 session_state가 처리.

전파_매핑 (spawn 직전 설정):
  oplan spawn 직전 → mcp__oio__session_state(uuid="${UUID}", key="state", value="PLAN")
  odev spawn 직전  → mcp__oio__session_state(uuid="${UUID}", key="state", value="DEV")
  otest spawn 직전 → mcp__oio__session_state(uuid="${UUID}", key="state", value="TEST")
  odone spawn 직전 → mcp__oio__session_state(uuid="${UUID}", key="state", value="DONE")

상태_의미: 해당 단계가 "현재 실행 중"임을 표시
  PLAN = oplan 실행 중 / DEV = odev 실행 중 / TEST = otest 실행 중 / DONE = odone 실행 중
```

### 파이프라인 이벤트 로그 (Temporal 영감)

```yaml
파이프라인_이벤트_로그:
  파일: $HOME/.claude/session-env/${UUID}/logs/pipeline_events.jsonl
  형식: 각 줄 = JSON 객체 (append-only)
  예시: {"ts":"2026-03-27T14:30:00","event":"PLAN_START","agent":"oplan-1","detail":"sonnet spawn"}
  기록_시점:
    - 각 단계 spawn 직후: {event: "{STAGE}_START", agent: "{에이전트명}"}
    - 각 단계 완료 수신: {event: "{STAGE}_DONE", agent: "{에이전트명}", result: "success|fail"}
    - 역라우팅 발생: {event: "REROUTE", from: "{단계}", to: "{단계}", count: N}
    - 조기 종료: {event: "EARLY_TERM", reason: "{사유}"}
  용도: 디버깅, 사후 분석, odone_review 교훈 소스
```

> 팀에이전트 관리: 본 문서 내 해당 섹션 참조

### 1단계: oplan 산출물 검증 (v4.1 — oplan은 ok가 이미 완료)

> **v4.1 변경**: oplan spawn/관리는 ok가 직접 수행. ok_pipeline 진입 시 oplan은 이미 완료 상태.
> ok_pipeline은 ok로부터 tier + oplan_output_path를 수신하여 검증 후 odev로 진행.

```yaml
입력 (ok로부터 수신):
  tier: O2|O3|O4|O5 (oplan이 결정한 값 — classification 파일 저장값은 대문자)
  oplan_output_path: $HOME/.claude/session-env/${UUID}/plans/oplan_{대화ID}.md
  파일_할당_매트릭스: $HOME/.claude/session-env/${UUID}/file_assignment.json

oplan_산출물_검증 (ok_pipeline 진입 직후):
  1. 필수 필드 검증: tier, 파일_할당_매트릭스 존재 확인
     검증_실패_시: ok에 보고 → ok가 oplan 재spawn → ok_pipeline 재호출
  2. 구조_검증_4종 (비용 0 — 메인 직접 수행):
     검증_1_파일_경로_존재: test -f (신규 create 제외)
     검증_2_매트릭스_중복_검사: 동일 파일 2개+ 에이전트 할당 확인
     검증_3_작업_파일_매핑_완전성: 모든 파일이 매트릭스에 존재
     검증_4_에이전트_파일_수_정합성: 에이전트당 ≤3개
     종합: 전체 PASS → odev 진입 | FAIL → ok에 보고
  3. 조건부_oplan_review_spawn:
     o2: 스킵 | o3_Quick: 스킵 | o3_Deep/o4/o5: 필수
     spawn: Agent(subagent_type="general-purpose", team_name="{팀명}", name="oplan_review-1", model="fable", mode="bypassPermissions", ...)
     PASS → odev 진입 | FAIL → ok에 보고
  4. 규모판정 기록: mcp__oio__session_state(uuid="${UUID}", key="classification", value="O{N}")
  5. 체크포인트 검증: bash ${HARNESS_HOME:-$HOME/.harness}/current/hooks/checkpoint_verify.sh "{팀명}" 1 "PLAN완료→DEV진입" "${UUID}"
  5.5. checkpoint_기록: mcp__oio__bash_exec(command='bash ${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/checkpoint_write.sh "${UUID}" "PLAN_DONE" "PLAN" "" "" ""')
  6. file_assignment 버전 관리 (역라우팅 대비)
     - 역라우팅·oi 수정·사이클 연장마다 file_assignment.json 을 다시 쓴다(version +1). 기준은 git status 와 각 work/*_result.json 의 files_modified 다.
     - 삭제·원복된 파일은 빼고, 새로 생긴 파일은 넣는다. 파일은 마지막 수정자 1명이 소유한다.
     - 배정표를 갱신하지 않으면 F-CRUD-1 판정기가 FAIL 한다(L-581, conv_179163042411 역라우팅 #3).
  6.5. phase_batches 초기화 (Multi-Phase Auto-Loop 준비):
     6.5.0 tier 사전 체크:
       tier=$(cat $HOME/.claude/session-env/${UUID}/classification 2>/dev/null || echo "unknown")
       if [[ "$tier" != "O4" && "$tier" != "O5" ]]; then
         echo "⏭️ tier=$tier — Multi-Phase Batch 미적용 (O4/O5 전용)"
         → phase_batches.json 초기화 스킵, 단일 사이클 진행
         exit (6.5단계 종료)
       fi
       # tier가 O4/O5일 때만 6.5.1 DAG 검증 + 6.5.2 초기화 진행

     6.5.1 DAG 순환 검증 (실패 시 oplan 재spawn):
       목적: depends_on_batch 순환 참조 감지 → 무한 대기 방지
       구현:
         DAG_RESULT=$(python3 -c "
         import json, sys
         try:
           data = json.load(open('$HOME/.claude/session-env/${UUID}/plans/phase_batches.json'))
           deps = {b['batch_id']: b.get('depends_on_batch') for b in data['batches']}
           for start in deps:
             path = []
             cur = start
             while cur and cur not in path:
               path.append(cur)
               cur = deps.get(cur)
             if cur in path:
               print('CYCLE'); sys.exit(1)
           print('OK')
         except Exception as e:
           print('ERROR:' + str(e)); sys.exit(2)
         " 2>/dev/null)

         case "$DAG_RESULT" in
           "OK")
             echo "✅ DAG 검증 통과"
             ;;
           "CYCLE")
             echo "❌ depends_on_batch 순환 참조 감지 — oplan 재spawn 필요"
             → phase_batches.json 삭제 + oplan 재spawn (상위 오케스트레이션)
             → 단일 사이클 폴백 (ofinish 진입)
             ;;
           *)
             echo "❌ DAG 검증 실패: $DAG_RESULT — 단일 사이클 폴백"
             → ofinish
             ;;
         esac

     6.5.2 phase_batches 초기화 (DAG 검증 통과 후):
     phase_batches.json 존재 확인: mcp__oio__file_read(path="$HOME/.claude/session-env/${UUID}/plans/phase_batches.json")
     존재_시:
       - current_phase_batch=1 초기화: mcp__oio__file_write(path="$HOME/.claude/session-env/${UUID}/current_phase_batch", content="1", overwrite=true)
       - 첫 진행 집합 = 4.5단계 "3.5 독립 batch 병렬 집합 계산"(DONE=∅ — 선행 없는 batch 들 중 파일 비중첩 집합)
         집합 크기 1: 기존대로 batch 1 의 file_assignment 로딩 → file_assignment.json 갱신
         집합 크기 ≥2: active_phase_batches.json 기록 + 집합 batch 들의 file_assignment 를 batches[] 형식으로 합쳐 file_assignment.json 갱신 → 7단계에서 집합 전체 odev 동시 spawn
       - 배너 출력: "🔄 Multi-Phase Batch 감지: {total_batches}개 batch, 첫 진행 집합 {집합}"
     미존재_시: 단일 사이클 — 기존 동작 유지 (변경 없음)
  7. odev×N spawn (2단계 — DEV 상태 전파는 2단계 spawn_직전에서 수행)
```

## o4 DEBATE_ROUTING (조건부 oplan_debate 추가 실행)

> o4에서 oplan_deep 완료 후, 아래 조건 ANY 해당 시 oplan_debate 추가 실행.
> o5는 oplan_debate 필수이므로 이 블록 불필요.
> DEBATE_ROUTING은 ok_pipeline에 인라인됨.

```yaml
DEBATE_ROUTING_조건 (ANY 해당 시 oplan_debate 추가 실행):
  - 수정 줄 수 500줄+
  - 아키텍처 변경 (새 모듈 신설, 계층 구조 변경)
  - 새 모듈/폼 3개+
  - 기술 선택 트레이드오프 존재 (A vs B 접근법)

DEBATE_ROUTING_판정_시점: oplan_deep 완료 수신 직후
DEBATE_ROUTING_해당_시:
  1. oplan_debate 추가 실행 (oplan_deep 결과를 입력으로 제공)
  2. oplan_debate: 4단계 토론 (독립분석→debate→vote→final merge)
  3. 최종 계획서: oplan_debate 결과 우선 채택
DEBATE_ROUTING_미해당_시:
  oplan_deep 결과만으로 충분 — oplan_debate 스킵
```

## o5 oplan_debate 토론 (필수)

> o5는 oplan_debate 4단계 토론 필수.
> 대안: oplan_consult (Claude vs Codex 이종 AI)

```yaml
o5_토론_절차:
  기본: oplan_debate (Claude A × Claude B 이중 토론)
  대안: oplan_consult (Claude × Codex 이종 AI 협업)

  oplan_consult_선택_기준 (ANY 해당 시):
    - 복잡한 알고리즘/아키텍처 결정이 필요한 경우
    - 기술 선택 트레이드오프 분석이 필요한 경우
    - 이종 AI 시각이 도움이 될 경우 (다양한 외부 관점)
    - Codex 플러그인(codex:rescue) 사용 가능 상태일 때
  oplan_consult_폴백: Codex 사용 불가 시 oplan_debate로 자동 전환

  oplan_debate_spawn_절차:
    1. oplan-1 spawn (fable): 독립 분석 #1
       Agent(subagent_type="general-purpose", team_name="{팀명}", name="oplan-1", model="fable",
             mode="bypassPermissions", prompt="Skill('oplan_debate') 로딩 — 1단계 독립 분석 수행...")
    2. oplan-2 spawn (fable): 독립 분석 #2 (oplan-1과 병렬)
       Agent(subagent_type="general-purpose", team_name="{팀명}", name="oplan-2", model="fable",
             mode="bypassPermissions", prompt="Skill('oplan_debate') 로딩 — 1단계 독립 분석 수행...")
    2.5. oplan-3 spawn (fable): 독립 분석 #3 — 구현 렌즈 (oplan-1, oplan-2와 병렬)
       Agent(subagent_type="general-purpose", team_name="{팀명}", name="oplan-3", model="fable",
             mode="bypassPermissions", prompt="Skill('oplan_debate') 로딩 — 1단계 독립 분석 수행. 구현 렌즈: 실제 코드 변경 범위, 의존성, 실행 순서 우선. ...")
    3. 셋 다 완료 후 → oplan_debate 2단계(debate), 3단계(vote), 3.5단계(배심원 투표) 진행
       (oplan-1, oplan-2, oplan-3가 메인과 SendMessage 교환으로 순차 진행)
    4. oplan-final spawn (fable): 통합 최종 계획서
       Agent(subagent_type="general-purpose", team_name="{팀명}", name="oplan-final", model="fable",
             mode="bypassPermissions", prompt="Skill('oplan_debate') 로딩 — 4단계 final merge 수행...")

  oplan_consult_spawn_절차:
    1. oplan-consult-1 spawn (sonnet): oplan_consult 실행
       Agent(subagent_type="general-purpose", team_name="{팀명}", name="oplan-consult-1", model="sonnet",
             mode="bypassPermissions", prompt="Skill('oplan_consult') 로딩 — o5 이종 AI 협업 계획 수립.
             Codex 불가 시 oplan_deep으로 폴백. PIPELINE_UUID={UUID}. 사용자 요구사항: {원문}.")
    2. 완료 수신: oplan_consult_final.md 경로 + 표준 oplan 출력 형식 확인
    3. odev spawn으로 진행 (oplan_debate와 동일한 이후 흐름)

  oplan_deep references/SIM_PROCEDURE.md: 8회+ 시뮬레이션 (o4보다 강화)
  oplan_review: fable 필수

  # L-319: oplan_debate ↔ ok_pipeline 상호 참조 검증 (Level 2 — 스킬 규칙)
  # oplan_debate/SKILL.md 또는 이 섹션 변경 시 반드시 양쪽을 함께 확인하여 정합성 유지
  # 단일 출처 원칙: 토론 구조(oplan-1/2/3/final 역할)는 oplan_debate/SKILL.md가 정의,
  # 이 섹션은 spawn 절차(Agent 호출 방식)만 기술. 역할 정의 중복 기재 금지.
```

### 2단계: odev 팀에이전트 spawn

> 🚨 **L-030 필수**: Agent(odev) 호출 직전 반드시 STATE=DEV 설정. 미설정 시 pipeline_order_guard.sh 차단.
> STATE=PLAN 상태에서 DEV spawn 시도 → HOOK_BLOCK. 아래 spawn_직전 단계 절대 생략 금지.

```yaml
2단계_Wave_동적_spawn:
  > 상세: [references/WAVE_SPAWN.md](references/WAVE_SPAWN.md)
  핵심: 의존성 기반 READY 집합 동적 계산 → Wave별 순차 spawn
  폴백: dependencies 없음 → 전체 병렬 (Wave 1개)
  부분실패: 해당 에이전트만 재spawn (reroute_count 미증가)

# [L-030] spawn_직전은 Agent 호출 직전 반드시 실행 (생략 시 STATE=PLAN → HOOK_BLOCK_PIPELINE_ORDER)
spawn_직전 (진입 기반 — L-030 절대 생략 금지):
  1. 상태 전파: mcp__oio__session_state(uuid="${UUID}", key="state", value="DEV")
  2. 작업 폴더 확보 (다중 세션 git 정책 — 메인, 첫 odev spawn 직전 1회):
     - 대상 저장소가 정책 적용 대상(git 저장소 + 커밋 1개 이상 + 저장소 루트에 .claude/ + INFRA-FIELDS git_worktree 가 off 아님)이고 추적 파일을 고칠 작업이면, 메인이 공식 EnterWorktree(name=<세션명>) 를 호출한다. 세션명은 tmux 세션명에서 claude- 접두어를 뗀 값이며 없으면 6자 임의 값이다.
     - 이미 worktree 안이면 재호출하지 않는다. 사이클마다 같은 worktree 를 재사용한다.
     - 호출 뒤 odev 프롬프트에 "작업 폴더: <worktree 경로> — 저장소 파일은 이 폴더 기준 절대경로로 읽고 쓰며, bash_exec 는 working_dir 를 이 폴더로 한다" 를 포함한다(훅이 [WT_INJECT] 줄을 주입하면 그 값을 따른다).
     - 커밋 0개 저장소 등 EnterWorktree 가 실패하면 정책 비적용으로 보고 기존 절차로 진행한다.
     - 가드는 원본 폴더 쓰기에 경고만 붙이고 차단하지 않는다. 경고를 보면 이 절차로 돌아간다.
     - push 는 wt_lib push 단일 경로로만 한다(odone_git·opush·ofinish 소관). 결과의 live_applied 가 false 면 원본은 옛 코드이므로 warnings 를 보고한다.
     - isolation=worktree 팀원은 호출 결과가 알려 준 worktree 경로만 믿는다. 변경 없이 끝난 팀원의 worktree 는 자동 삭제되므로 후속 지시 전 `git worktree list` 로 실재를 확인한다. 없는 경로에 mkdir 하지 않는다(껍데기 폴더는 커밋되지 않는다). 후속 작업은 새 spawn 으로 한다.
     - 착수 전 `python3 <hooks>/lib/wt_lib.py audit --repo <저장소>` 로 잔류 worktree 의 미커밋(tracked·untracked)·unique_commits·shells 를 확인한다. 값이 있으면 보고만 하고 지우지 않는다.

실행: Agent(subagent_type="general-purpose", team_name="{팀명}", name="odev-{N}", model="sonnet", mode="bypassPermissions", prompt="...")
# ⚠️ 필수: team_name= 파라미터 반드시 포함. 누락 시 hook 차단됨. 팀은 첫 Agent 호출 시 자동 생성되며 소멸하지 않으므로 별도 사전 생성 불필요.
checkpoint_기록_DEV_START: mcp__oio__bash_exec(command='bash ${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/checkpoint_write.sh "${UUID}" "DEV_START" "DEV" "" "odev-{N}" "spawn"')

spawn_후_검증 (방법1 — Agent 반환 직후 필수):
  목적: spawn 성공 반환이 실제 pane 생성을 보장하지 않음 — agents/ 파일 + bash 빠짐 여부까지 확인
  절차: |
    # spawn 직후 최대 30초(10회×3초) agents/{에이전트명} 파일 생성 대기
    AGENT_REGISTERED=false
    for i in $(seq 1 10); do
      sleep 3
      if [ -f "$HOME/.claude/session-env/${UUID}/agents/{에이전트명}" ]; then
        echo "✅ {에이전트명} 에이전트 등록 확인 (${i}회차)"
        AGENT_REGISTERED=true
        break
      fi
      echo "⏳ {에이전트명} 등록 대기 중... (${i}/10)"
    done
    if [ "$AGENT_REGISTERED" = "false" ]; then
      echo "❌ {에이전트명} 등록 실패 — pane 미생성. 재spawn 필요."
      # → 재spawn 1회 시도 (동일 프롬프트, reroute_count +1)
    else
      # [L-NEW] bash 빠짐 감지 (CASE-4 재발방지 — 2026-04-25)
      # agents/ 파일 등록 후에도 pane이 bash 상태로 떨어진 경우 감지
      PANE_ID=$(grep "^pane_id=" "$HOME/.claude/session-env/${UUID}/agents/{에이전트명}" 2>/dev/null | cut -d= -f2)
      if [ -n "$PANE_ID" ]; then
        PANE_CMD=$(tmux display-message -t "$PANE_ID" -p '#{pane_current_command}' 2>/dev/null)
        if [ "$PANE_CMD" = "bash" ]; then
          echo "⚠️ CASE-4 감지: {에이전트명} pane($PANE_ID)이 bash 상태 — Claude Code 미기동"
          echo "   원인 후보: agent-id 중복/바이너리 충돌/WSL 타이밍 이슈"
          echo "   → pane kill 후 재spawn 필요 (reroute_count +1)"
          # 재spawn 전 pane 정리 (메인이 직접 수행 허용 — 팀에이전트 미기동 상태)
          BASH_PID=$(tmux display-message -t "$PANE_ID" -p '#{pane_pid}' 2>/dev/null)
          tmux set -g status off 2>/dev/null
          tmux kill-pane -t "$PANE_ID" 2>/dev/null
          tmux set -g status on 2>/dev/null
          rm -f "$HOME/.claude/session-env/${UUID}/agents/{에이전트명}"
          echo "✅ bash pane 정리 완료 — 재spawn 진행"
          # → 재spawn 1회 시도 (동일 프롬프트)
        fi
      fi
    fi
  bash_빠짐_원인_후보 (CASE-4 진단 참조):
    원인1_agent_id_중복: compact 이전 에이전트 레지스트리 잔류 → 동일 agent-id 재spawn 시 즉시 종료
    원인2_WSL_타이밍: compact 직후 tmux 환경 미복원 상태에서 spawn → Claude Code 즉시 종료
    원인3_메모리_부족: WSL2 메모리 압박 → 프로세스 즉시 종료
    예방_조치: compact 후 충분한 대기 후 재spawn (team_name 지정 시 자동 재생성. 활성 세션 중 팀 디렉토리 수동 삭제 금지)
  적용범위: odev 전체 + oplan + otest + odone (모든 팀에이전트 spawn 직후)
sprint_contract (odev spawn 전 필수 — N1):
  목적: odev-otest 간 "완료 정의" 사전 합의 → otest 평가 기준 명확화
  생성_시점: odev spawn 직전
  경로: $HOME/.claude/session-env/${UUID}/plans/sprint_contract.md
  내용_형식: |
    # Sprint Contract
    ## 완료 기준 (otest가 이 기준으로만 평가)
    {oplan §TODO 항목별 체크 가능한 완료 기준}
    ## 평가 방법
    {각 기준의 검증 방법 (코드 확인/실행 확인/로그 확인)}
  otest_전달: otest spawn 프롬프트에 sprint_contract.md 경로 포함

에이전트_프롬프트_구성:
  # 아래 항목들은 팀에이전트 prompt= 문자열에 포함시킬 텍스트다. 메인이 직접 실행하는 것이 아님.
  0. PIPELINE_UUID: "PIPELINE_UUID={UUID}"
  0.5. 도구 규칙: "Skill('agent_profiles') 로딩 후 [필수 규칙] 블록 준수 — 모든 셸 명령은 mcp__oio__bash_exec, 파일 I/O는 mcp__oio__file_* (내장 Bash/Read/Edit/Write 사용 시 write_guard 차단)"
  1. 스킬 로딩: "Skill('odev') 호출하여 스킬 로딩 후 실행"
  2. 페르소나, 담당 파일, 단위작업, TODO 경로
  3. 계획서_경로: "$HOME/.claude/session-env/${UUID}/plans/oplan_final.md (또는 plan_1.md)"
  4. 파일_할당_매트릭스_경로: "$HOME/.claude/session-env/${UUID}/file_assignment.json"
  5. 프로젝트 컨텍스트: "프로젝트 인프라는 INFRA.md 참조(경로는 프롬프트의 [INFRA_INJECT] 줄)"  # 팀에이전트가 실행할 텍스트
  6. 대화ID: "대화ID: {CONV_ID}"
  7. oi_queue_포함 (spawn 직전 메인이 확인 후 포함 — P1):
     # spawn 프롬프트 조립 전 oi_queue 파일 확인
     OI_QUEUE="$HOME/.claude/session-env/${UUID}/oi_queue"
     if [[ -s "$OI_QUEUE" ]]; then
       # oi_queue 내용을 프롬프트의 "추가 수정 요청:" 섹션으로 포함
       OI_QUEUE_CONTENT=$(cat "$OI_QUEUE")
       # spawn 프롬프트에 아래 섹션 추가:
       # "## 추가 수정 요청 (oi_queue):\n{OI_QUEUE_CONTENT}"
       # 포함 후 oi_queue 초기화:
       > "$OI_QUEUE"
     fi
대기: 모든 odev 완료 (각 Agent 도구 반환 대기)
비정상_반환_처리: 개별 Agent 반환 시 완료 보고 없으면 → 재spawn 1회 시도 (reroute_count +1)

다중_odev_완료_판단:
  원칙: 모든 odev 에이전트의 Agent 도구 반환을 수신한 후에만 otest spawn 허용
  판단_기준 (에이전트 유형별 분리 — P1-C3):
    - Agent(팀에이전트) 방식: SendMessage에 완료 키워드("완료", "done", "completed") 포함 여부로 완료 판정
    - Task(서브에이전트) 방식: Agent 도구 반환값 존재 시 자동 완료 (SendMessage 불필요)
    - 혼용 시: 두 조건 중 하나라도 충족하면 해당 에이전트 완료로 판정
  판단_분기:
    - 정상 완료: N개 odev 모두 완료 판정 → otest 진입
    - 부분 비정상: 일부 odev 비정상 반환 → 비정상 odev만 재spawn (카운터 공유) → 전체 완료 후 otest
    - 전체 비정상: 카운터 초과 → 조기 종료 + ofinish
  금지: 일부 odev 미반환 상태에서 otest spawn (절대 금지)

odev 완료 후:
  0. checkpoint_기록_odev_완료: mcp__oio__bash_exec(command='bash ${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/checkpoint_write.sh "${UUID}" "DEV_AGENT_DONE" "DEV" "" "odev-{N}" "완료"')
  1. 각 odev에 shutdown_with_verify 실행 (ok/references/SHUTDOWN_PROTOCOL.md "shutdown_with_verify 절차" 참조 — ok SKILL.md "shutdown_with_verify"에도 동일 정의)
  2. shutdown_sent 플래그 기록: 각 odev 에이전트 파일에 echo "shutdown_sent=true" >> $HOME/.claude/session-env/${UUID}/agents/odev-{N}
  2.7. pane 소멸 확인 + kill escalation (★ 필수 — L-362 — 2026-04-11):
    시점: shutdown_request 발송 후 최대 30초 대기
    원인: shutdown 후에도 pane이 살아있는 채로 방치되어 ostatus에서 수동 처리 필요 (2026-04-11 실제 발생)
    절차: |
      for AGENT_NAME in {odev 에이전트명 목록}; do
        PANE_ID=$(grep "^pane_id=" $HOME/.claude/session-env/${UUID}/agents/${AGENT_NAME} 2>/dev/null | cut -d= -f2)
        [ -z "$PANE_ID" ] && continue  # Agent tool 방식 — pane 없음 정상
        for i in $(seq 1 10); do
          sleep 3
          tmux display-message -t "$PANE_ID" -p '#{pane_id}' 2>/dev/null | grep -q '%' || { echo "✅ ${AGENT_NAME} pane 소멸 확인"; break; }
          echo "⏳ ${AGENT_NAME} pane 소멸 대기 중... (${i}/10)"
        done
        # pane 여전히 존재 시 kill escalation
        if tmux display-message -t "$PANE_ID" -p '#{pane_id}' 2>/dev/null | grep -q '%'; then
          echo "⚠️ ${AGENT_NAME} pane 잔류 — kill escalation 실행"
          BASH_PID=$(tmux display-message -t "$PANE_ID" -p '#{pane_pid}' 2>/dev/null)
          CHILD_PID=$(pgrep -P "$BASH_PID" 2>/dev/null | head -1)
          kill "${CHILD_PID:-$BASH_PID}" 2>/dev/null; sleep 1
          kill -9 "${CHILD_PID:-$BASH_PID}" 2>/dev/null; kill -9 "$BASH_PID" 2>/dev/null; sleep 1
          tmux set -g status off 2>/dev/null
          tmux kill-pane -t "$PANE_ID" 2>/dev/null
          tmux set -g status on 2>/dev/null
          echo "✅ ${AGENT_NAME} pane kill escalation 완료"
        fi
      done
    Agent_tool_방식_예외: pane_id 없는 에이전트 → 이 절차 스킵 (pane 없음이 정상)
  2.5. checkpoint_기록_DEV_ALL_DONE: mcp__oio__bash_exec(command='bash ${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/checkpoint_write.sh "${UUID}" "DEV_ALL_DONE" "DEV" "" "" ""')
  3. 체크포인트 검증: bash ${HARNESS_HOME:-$HOME/.harness}/current/hooks/checkpoint_verify.sh "{팀명}" {odev수} "DEV완료→TEST진입" "${UUID}"
  4. otest spawn (3단계 — TEST 상태 전파는 3단계 spawn_직전에서 수행)
```

### 3단계: otest 팀에이전트 spawn (o3~o5만 — o2는 obr)

```yaml
otest_3단계_구조 (v4.3):
  otest 에이전트가 내부에서 3단계 순차 실행:
    1단계: Skill('otest_infra') — 인프라 검증 (빌드+배포+로그)
    2단계: Skill('otest_verify') — 구현 검증 (acceptance_criteria 대조)
    3단계: Skill('otest_evidence') — 최종 검수 (계획서/TODO/체크리스트 1:1 대조)

  3단계 모두 PASS → evidence/otest_done 생성 → ok_pipeline에 완료 보고
  FAIL → otest 대기 (종료 안 함) → 역라우팅 → RETEST

  ok_pipeline 역할:
    - otest spawn + 완료 대기
    - otest FAIL 시: odev/oplan 역라우팅 spawn → RETEST 발송
    - otest PASS 후: otest_done_guard.sh(hook)가 odone spawn 허용 여부 최종 확인
    - Evidence Gate(hook)는 ok_pipeline이 관리 — otest 외부

otest_done_guard.sh (Evidence Gate — ok_pipeline 관리):
  시점: odone spawn 직전 (hook이 자동 발동)
  검증: evidence/otest_done 존재 + mtime > pipeline_start_time
  역할: otest_evidence가 otest_done을 생성하지 않았으면 odone spawn 물리 차단
  위치: otest 외부 (hook) — 에이전트가 우회 불가
```

```yaml
otest_자원_축_병렬 (2026-10-04 — "otest 1개" 원칙의 목적을 자원 축 단위로 재정의):
  목적: 같은 자원을 두 otest 가 동시에 건드리지 않게 한다. "개수 1"은 수단이었고 목적이 아니다.
  자원_축:
    데스크톱: 데스크톱 앱 실행본, 빌드 산출물(bin/obj), 사용자 데스크톱 화면·입력
    모바일:   에뮬레이터·실기기, adb, APK 빌드 산출물
    웹:       헤드리스 브라우저, 웹 빌드 산출물, 웹 테스트 URL(웹은 앱과 같은 게이트웨이 프로토콜을 쓴다)
  규칙:
    - 축이 다르면 동시 실행 허용 (데스크톱 otest 1개 + 모바일 otest 1개 + 웹 otest 1개)
    - 같은 축 otest 2개는 금지 (기존 원칙 그대로)
  이름_규약 (단일 출처: hooks/lib/otest_axis.sh — hook 이 이 이름으로 축을 판정한다):
    데스크톱: otest-{N}      (기존 이름 그대로 — otest-1, otest-2 …)
    모바일:   otest-m-{N}    (otest-m-1, otest-m-2 … / 별칭 otest-mobile-{N})
              접미 변형도 모바일로 판정: otest-{임의}-m, otest-{임의}-mobile (예: otest-c1-m)
    웹:       otest-w-{N}    (otest-w-1, otest-w-2 … / 별칭 otest-web-{N})
              접미 변형도 웹으로 판정: otest-{임의}-w, otest-{임의}-web (예: otest-c1-w)
    ⚠️ 데스크톱 otest 이름은 '-m' 또는 '-mobile' 로 끝나면 안 된다 — hook 이 모바일 축으로 판정한다.
    ⚠️ 데스크톱·모바일 otest 이름은 '-w' 또는 '-web' 으로 끝나도 안 된다 — hook 이 웹 축으로 판정한다. 'otest-m-w' 같은 혼합 이름 금지.
  축별_완료_마커 (evidence/ 하위 — 서로의 마커를 만들지 말 것):
    데스크톱 otest: otest_done
    모바일 otest:   otest_done_m  (+ 진입 즉시 otest_m_started 생성)
    웹 otest:       otest_done_w  (+ 진입 즉시 otest_w_started 생성)
  spawn_판정 (메인):
    - 변경 범위에 데스크톱과 모바일이 둘 다 있으면 → otest 2개를 같은 메시지에서 병렬 spawn
        Agent(name="otest-1", ...)  — 데스크톱 축만 담당
        Agent(name="otest-m-1", ...) — 모바일 축만 담당
      spawn 직전 evidence/otest_axes 에 "desktop mobile" 기록 (mcp__oio__file_write, overwrite=true)
    - 변경 범위에 웹이 있으면 웹 축 otest-w-1 을 같은 메시지에서 함께 병렬 spawn (3축 동시 spawn: 데스크톱 + 모바일 + 웹)
        Agent(name="otest-w-1", ...) — 웹 축만 담당 (헤드리스 브라우저)
      spawn 직전 evidence/otest_axes 에 해당 축을 모두 기록 (예: "desktop mobile web")
    - 웹만 → otest-w-1 1개 + evidence/otest_axes 에 "web" 기록
        (이 기록이 있어야 otest_done_guard 가 otest_done 대신 otest_done_w 를 요구한다 — 웹이 데스크톱 마커를 대체하지는 않는다)
    - 데스크톱만 → 기존과 동일 (otest-1 1개, otest_axes 기록 불필요)
    - 모바일만 → otest-m-1 1개 + evidence/otest_axes 에 "mobile" 기록
        (이 기록이 있어야 otest_done_guard 가 otest_done 대신 otest_done_m 을 요구한다)
    - 각 프롬프트에 "담당 축: 데스크톱|모바일|웹 — 다른 축 자원(빌드·기동·디바이스·화면)에 손대지 말 것" 명시
  물리_게이트 (otest_done_guard.sh — odone spawn 시):
    - 이번 파이프라인에 모바일 흔적(otest_axes 의 mobile / otest_m_started / agents/otest-m-*)이 있으면
      otest_done_m 도 필수 → 데스크톱이 먼저 끝나도 모바일 완료 전에는 odone 진입이 차단된다.
    - 웹 흔적(otest_axes 의 web / otest_w_started / agents/otest-w-*)이 있으면 otest_done_w 도 필수 — 동일 방식으로 차단된다.
    - 웹 축은 헤드리스 브라우저 사용이 기본이며 사용자 화면에 창을 띄우지 않는다.
    - 같은 축 2개 동시 spawn 을 막는 hook 은 없다(동일 이름 재spawn 차단 L-DUP1 만 존재) — 위 이름 규약 준수는 메인 책임.
  공유_자원_조정 (두 otest 사이 — 축이 달라도 겹치는 것):
    테스트_데이터_정리:
      - 정리(삭제) 목록은 하나만 둔다: evidence/test_data_cleanup.list 에 각 축 otest 가 각자 생성한 키를
        "축 키" 형식으로 append 만 한다 (덮어쓰기 금지).
      - 실제 정리 실행은 데스크톱 otest 1곳에서, 모바일·웹 otest 완료 보고를 메인 경유로 확인한 뒤 1회 수행한다.
        (데스크톱이 없으면 남은 축 중 1곳이 수행 — 모바일 단독이면 모바일 otest, 웹 단독이면 웹 otest)
      - 한 otest 가 상대 축이 만든 데이터를 지우거나 고치는 것 금지.
    공용_서버(백엔드·게이트웨이·DB 스키마 등 두 클라이언트가 함께 붙는 서버):
      - 웹은 앱과 같은 게이트웨이 프로토콜을 쓰므로 이 규칙은 웹 otest 에도 동일하게 적용된다 (공용 서버 재기동·재배포 금지).
      - 어느 otest 도 단독으로 재기동·재배포·설정 변경하지 않는다.
      - 필요하면 메인(team-lead)에 SendMessage 로 요청 → 메인이 다른 otest 진행 상황을 확인·통지한 뒤 1회 수행.
      - 서버 측 빌드·배포가 이번 변경에 포함되면 데스크톱 otest 가 Phase 1 에서 1회 수행하고,
        모바일·웹 otest 는 그 완료 통지(메인 경유)를 받은 뒤 서버 의존 검증을 시작한다.
    공용_DB_행: 같은 레코드를 둘 이상의 otest 가 동시에 수정하는 시나리오 금지 — 축별로 다른 테스트 레코드를 쓴다.
  완료_처리 (메인):
    - spawn 한 모든 축 otest 의 Agent 반환/완료 보고를 모두 받은 뒤에만 TEST_ALL_DONE 기록·odone 진행
    - 한쪽 FAIL 이면 그 축만 역라우팅(RETEST 는 FAIL 난 축 otest 에만 발송). PASS 한 쪽은 대기 유지.
    - shutdown·shutdown_sent 기록은 두 에이전트 각각, checkpoint_verify 예상 멤버 수 = spawn 한 축 수(1~3)

적용: o3~o5만 (o2는 2.5단계 obr으로 대체)

spawn_직전 (진입 기반):
  1. 상태 전파: mcp__oio__session_state(uuid="${UUID}", key="state", value="TEST")

실행:
  o3/o4: Agent(subagent_type="general-purpose", team_name="{팀명}", name="otest-1", model="sonnet", mode="bypassPermissions", prompt="...")
  o5:    Agent(subagent_type="general-purpose", team_name="{팀명}", name="otest-1", model="fable", mode="bypassPermissions", prompt="...")
# ⚠️ 필수: team_name= 파라미터 반드시 포함. 누락 시 hook 차단됨. 팀은 첫 Agent 호출 시 자동 생성되며 소멸하지 않으므로 별도 사전 생성 불필요.
checkpoint_기록_TEST_START: mcp__oio__bash_exec(command='bash ${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/checkpoint_write.sh "${UUID}" "TEST_START" "TEST" "" "otest-1" "spawn"')
에이전트_프롬프트_구성:
  # 아래 항목들은 팀에이전트 prompt= 문자열에 포함시킬 텍스트다. 메인이 직접 실행하는 것이 아님.
  0. PIPELINE_UUID: "PIPELINE_UUID={UUID}"
  0.5. 도구 규칙: "Skill('agent_profiles') 로딩 후 [필수 규칙] 블록 준수 — 모든 셸 명령은 mcp__oio__bash_exec, 파일 I/O는 mcp__oio__file_* (내장 Bash/Read/Edit/Write 사용 시 write_guard 차단)"
  0.7. 실행_명령_작성_금지 (L-022/L-110/구조적_위임): "
    ⛔ spawn 프롬프트에 다음을 직접 작성 절대 금지:
      - Windows .exe 실행 명령 (앱 직접 구동류)
      - 앱 경로 직접 지정 (C:\\..\\*.exe, /mnt/c/.../*.exe 등)
      - 빌드+구동+배포 절차 자유 서술 (Phase 1 인프라 명세 직접 작성)
    ✅ 대신 반드시: Skill('otest_run') 위임으로 고정 — 실행 책임은 스킬이 진다.
    이유: LLM이 실행 명령을 작성하는 동기 자체를 제거 (hook 차단보다 근본적)"
  1. 스킬 로딩: "Skill('otest') 호출하여 스킬 로딩 후 실행"
  1.5. 인프라_검증_위임 (Phase 1 — 구조적 고정): "
    Phase 1 (인프라 검증)은 Skill('otest_run') 호출로 위임한다.
    빌드+배포+헬스체크는 otest_run 스킬 내부에서 처리.
    이 프롬프트에 빌드/배포/구동 명령을 직접 작성하지 말 것.
    → Skill('otest_infra') 호출 시 otest_run이 자동 경유됨."
  2. 수정 파일 목록, 검증 체크리스트 (L-047 필수)
  3. 프로젝트 컨텍스트: "프로젝트 인프라는 INFRA.md 참조(경로는 프롬프트의 [INFRA_INJECT] 줄)"  # 팀에이전트가 실행할 텍스트
  4. 대화ID: "대화ID: {CONV_ID}"
  5. UI_테스트_필수 (L-240): UI 파일(.xaml/Designer.cs/View*.cs/ViewModel*.cs) 변경 포함 시
       - o3/o4: "Skill('otestuiwinforms') 필수 실행"
       - o5: "Skill('otestuiwinforms') + Skill('otestui') 필수 실행" (UI 테스트 필수)
대기: otest 완료 (3단계: otest_infra → otest_verify → otest_evidence) — Agent 도구 반환 대기
비정상_반환_처리: Agent 반환 시 완료 보고 없으면 → 재spawn 1회 시도 (reroute_count +1)
실패_시: odebug 호출 → 수정 → otest 재실행. 빌드 실패 시 odev 역라우팅 (→ 역라우팅 섹션 참조)
otest 완료 후:
  0. checkpoint_기록_TEST_ALL_DONE: mcp__oio__bash_exec(command='bash ${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/checkpoint_write.sh "${UUID}" "TEST_ALL_DONE" "TEST" "" "" ""')
  0.5. auto/ROOF 잔여 계약 보고 확인 (otest_verify "auto/ROOF DONE 전 잔여 계약 검증" 절차 결과 —
       신규 2026-08-29, otest_verify/SKILL.md 참조):
       otest가 "[otest] auto/ROOF 잔여 계약 미충족" 메시지를 보냈으면 (auto=ON 또는
       status에 ROOF(구 RALPH 포함 — ROOF-COMPAT) 없는 세션은 이 메시지 자체가 발생하지 않음 — 무조건 통과):
         a. mcp__oio__session_state(uuid="${UUID}", key="state", value="PLAN")
         b. oroof_active(또는 oroof_active.json; 구 세션은 oralph_active(.json) — ROOF-COMPAT, deprecation window 1주기) current_iteration을 +1 하여 재기록
            (mcp__oio__file_read로 기존 JSON 읽은 뒤 current_iteration만 갱신,
             mcp__oio__file_write overwrite=true — 신규 카운터 생성 금지)
         c. oplan 팀에이전트 재spawn (Agent name="oplan-{N}", team_name="{팀명}", model="sonnet",
            mode="bypassPermissions", prompt에 아래 반드시 포함):
              "PIPELINE_UUID={UUID}"
              "Skill('oplan_normal') 로딩 전에 mcp__oio__file_read로
               ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/plans/plan_resume_context.json 을 읽어라.
               fail_items 목록만을 대상으로 보완 계획을 세워라. 기존 oplan_*.md와 goal.json은
               이미 유효하므로 전체 재계획 금지."
         d. oplan 완료 대기 후 odev→otest 정상 재진입 (본 문서 1~3단계 반복,
            state 전파는 기존 매핑 그대로: odev spawn 직전 state=DEV)
         e. 위 a~d 완료 후 4번(otest_done_guard hook 검증) 스킵하고 이번 라운드 종료
            (state가 이미 PLAN이므로 DONE 관련 hook 검증 자체가 무의미)
       otest로부터 해당 메시지가 없으면 4번으로 정상 진행
  1. otest에 shutdown_with_verify 실행 (ok/references/SHUTDOWN_PROTOCOL.md "shutdown_with_verify 절차" 참조)
  2. shutdown_sent 플래그 기록: echo "shutdown_sent=true" >> $HOME/.claude/session-env/${UUID}/agents/otest-1
  3. 체크포인트 검증: bash ${HARNESS_HOME:-$HOME/.harness}/current/hooks/checkpoint_verify.sh "{팀명}" 1 "TEST완료→DONE진입" "${UUID}"
  4. otest_done_guard hook 검증 (3.5단계) → 통과 시 odone spawn, 실패 시 otest 재spawn
     (PreToolUse_done_gate.sh는 0.5를 건너뛰고 곧바로 state=DONE을 쓰려는 비정상 경로에서만
      발동하는 최종 안전망 — 정상 경로에서는 0.5가 먼저 처리하므로 발동하지 않는다)
```

### 3단계 보강: QA 단계 축 (QA 선언 프로젝트 한정)

원문 지시: "앞으로도 qa서버까지는 테스트를 진행하도록 하라. 다만 운영db와 연계되어있으므로 조심하고 최소한의 테스트만 진행하고 테스트전으로 완벽하게 되돌릴수있는 테스트만 진행하여야한다."(사용자 지시, 2026-10-10)

- 프로젝트에 `.claude/qa_tier.json`(QA 선언, enabled=true, applies_tiers 에 현재 tier 포함)이 있으면 otest 축에 **QA 축(서버·DB 스냅샷 소유자 1명)**을 추가한다. 선언이 없으면 이 절은 적용하지 않는다.
- 리드는 QA 배포가 끝난 뒤 QA 축 담당을 spawn 한다. 데스크톱·모바일 축과 병렬로 돌리되, 스냅샷(before/after)과 원복 쓰기는 QA 축 1명만 소유한다.
- 원복 불가 항목은 **계획 단계에서 판정표로 걸러 낸다**. 시험 대상은 시험 전 상태로 완전 원복할 수 있는 최소 항목뿐이며, 판정표에 없는 항목은 시험하지 않는다.
- 시험 순서는 스냅샷(before) → 시험 표식 → 삭제·원복 → 스냅샷(after) → 전후 대조이다.
- QA 축 spawn 전에 계획서의 원복 시나리오(qa_reversibility_draft.json 등)가 있는지 확인한다. 없으면 oplan 으로 되돌린다.
- 완료 시 `${SESSION_DIR}/evidence/qa_test_done` 마커를 쓴다. 첫 줄은 `PASS|PARTIAL|SKIPPED <ISO8601>`, PASS·PARTIAL 은 `before=`·`after=`·`compare=` 경로 줄, SKIPPED 는 `reason=` 줄(선언의 skip_reason_min_len 이상)을 포함한다.
- 전후 state 가 불일치하면 DONE 전이는 done_gate 가 차단한다. 면제(SKIPPED)는 사용자에게 묻지 않고 리드·otest 가 판단해 쓴다 — 앱·서버 소스 변경이 없거나 QA 시험이 해당되지 않을 때만, reason= 에 근거를 남긴다(감사 기록, 사용자 지시 2026-10-27 15:53). 운영 배포 승인은 별도 유지다.

### 3.5단계: otest_verify (otest→odone 전환 게이트)

> **v4.3에서 이관됨**: 이 역할은 **otest_evidence**로 이관됨. otest 에이전트 내부에서 3단계로 실행. ok_pipeline은 hook(otest_done_guard)만 관리.

```yaml
3.5단계_otest_verify (otest→odone 전환 게이트):
  이관_완료: v4.3에서 otest_evidence로 이관됨. hook(otest_done_guard.sh)이 담당.
  # otest 에이전트 내부 3단계(otest_infra → otest_verify → otest_evidence)에서 검증 수행.
  # ok_pipeline은 otest_done_guard hook 결과만 확인하여 odone spawn 여부 결정.
```

### 4단계: odone 팀에이전트 spawn (o3~o5만 — o1/o2는 odone 미실행)

```yaml
적용: o3~o5만 (o1/o2는 odone 미실행 — ofinish Step 1.5가 경량 교훈 대체)

spawn_직전 (진입 기반):
  1. 상태 전파: mcp__oio__session_state(uuid="${UUID}", key="state", value="DONE")

실행: Agent(subagent_type="general-purpose", team_name="{팀명}", name="odone-1", model="sonnet", mode="bypassPermissions", prompt="...")
# ⚠️ 필수: team_name= 파라미터 반드시 포함. 누락 시 hook 차단됨. 팀은 첫 Agent 호출 시 자동 생성되며 소멸하지 않으므로 별도 사전 생성 불필요.
checkpoint_기록_DONE_START: mcp__oio__bash_exec(command='bash ${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/checkpoint_write.sh "${UUID}" "DONE_START" "DONE" "" "odone-1" "spawn"')
에이전트_프롬프트_구성:
  # 아래 항목들은 팀에이전트 prompt= 문자열에 포함시킬 텍스트다. 메인이 직접 실행하는 것이 아님.
  0. PIPELINE_UUID: "PIPELINE_UUID={UUID}"
  0.5. 도구 규칙: "Skill('agent_profiles') 로딩 후 [필수 규칙] 블록 준수 — 모든 셸 명령은 mcp__oio__bash_exec, 파일 I/O는 mcp__oio__file_* (내장 Bash/Read/Edit/Write 사용 시 write_guard 차단)"
  1. 스킬 로딩: "Skill('odone') 호출하여 스킬 로딩 후 실행"
  2. 경로 지정 + 수정 파일 목록
  3. 프로젝트 컨텍스트: "프로젝트 인프라는 INFRA.md 참조(경로는 프롬프트의 [INFRA_INJECT] 줄)"  # 팀에이전트가 실행할 텍스트
  4. 대화ID: "대화ID: {CONV_ID}"
경로 (tier별 분기):
  o3: Fast Path (odone_review → odone_docs → odone_git)
  o4: Full Path (odone_trans → odone_review → odone_hooks → odone_skills → odone_cleanup → odone_docs → odone_git)
  o5: Full Path (odone_trans → odone_review → odone_hooks → odone_skills → odone_cleanup → odone_docs → odone_git)
대기: odone 완료 (git commit+push 확인) — Agent 도구 반환 대기
비정상_반환_처리: Agent 반환 시 완료 보고 없으면 → 재spawn 1회 시도 (reroute_count +1)

절대_규칙 (L-044 — o3~o5):
  - o3~o5에서 odone은 절대 생략/스킵 불가
  - odone 미수행 = git commit 없음 = 작업 미반영 = 실패
  - 최소 보장: git commit + push + notify
  - o1/o2: odone 미실행 (ofinish Step 1.5 경량 교훈 + Step 7.5 경량 커밋으로 대체)

odone 완료 후:
  0. checkpoint_기록_DONE_ALL_DONE: mcp__oio__bash_exec(command='bash ${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/checkpoint_write.sh "${UUID}" "DONE_ALL_DONE" "DONE" "" "" ""')
  1. odone에 shutdown_with_verify 실행 (ok/references/SHUTDOWN_PROTOCOL.md "shutdown_with_verify 절차" 참조)
  2. shutdown_sent 플래그 기록: echo "shutdown_sent=true" >> $HOME/.claude/session-env/${UUID}/agents/odone-1
  3. 체크포인트 검증: bash ${HARNESS_HOME:-$HOME/.harness}/current/hooks/checkpoint_verify.sh "{팀명}" 0 "DONE완료→FINISH" "${UUID}"
  3. ofinish 실행 (pane 정리 + 팀 삭제 — FINISH 상태 전파는 ofinish Step 0.5에서 수행)
```

### 4.5단계: Phase Batch Auto-Loop (다단계 자동 진행)

> **목적**: oplan이 multi-phase batch 계획을 세운 경우, 모든 batch를 자동으로 끝까지 실행.
> **병렬 기본 (2026-10-10)**: 선행이 충족되고 파일이 겹치지 않는 독립 batch 는 동시에 진행한다 — 아래 "3.5 독립 batch 병렬 집합 계산". 판정 체크리스트 단일 출처는 odev_parallel "병렬 판정 체크리스트".
> **트리거**: odone 완료 보고 수신 직후 (ofinish 진입 전).
> **조건**: phase_batches.json 존재 AND current_batch < total_batches.
> **하위 호환**: phase_batches.json 미존재 시 기존 단일 사이클 동작 (이 단계 스킵 → ofinish 진입).

```yaml
4.5단계_Phase_Batch_Auto_Loop:
  트리거: odone 완료 보고 수신 직후 (4단계 완료)
  
  절차:
    -1. auto_loop_active 플래그 생성 (V8 — ofinish Step 3 이중 진입 방지):
       touch $HOME/.claude/session-env/${UUID}/auto_loop_active
       # 이 플래그가 존재하는 동안 ofinish Step 3 백업 루프는 skip됨
       # 반드시 루프 정상 종료 또는 실패 시 rm -f로 제거

    0. tier 체크 (고속 경로):
       tier=$(cat $HOME/.claude/session-env/${UUID}/classification 2>/dev/null || echo "unknown")
       if [[ "$tier" != "O4" && "$tier" != "O5" ]]; then
         rm -f $HOME/.claude/session-env/${UUID}/auto_loop_active
         → "단일 사이클 완료" → ofinish 진입 (4.5단계 탈출)
       fi
       # O4/O5인 경우만 절차 1 이하 수행

    0.5. Lock 획득 (stale 감지 + PID 기록):
       LOCK_DIR="$HOME/.claude/session-env/${UUID}/phase_batch.lock"
       LOCK_PID_FILE="$LOCK_DIR/owner_pid"
       LOCK_TIMEOUT_SECONDS=1800  # 30분 stale 임계

       # stale Lock 감지 및 자동 해제
       if [ -d "$LOCK_DIR" ]; then
         LOCK_AGE=$(( $(date +%s) - $(stat -c %Y "$LOCK_DIR" 2>/dev/null || echo 0) ))
         LOCK_OWNER=$(cat "$LOCK_PID_FILE" 2>/dev/null || echo "")

         # 조건 1: 30분 초과 → stale
         # 조건 2: owner PID 프로세스가 이미 종료 → stale
         if [ "$LOCK_AGE" -gt "$LOCK_TIMEOUT_SECONDS" ] || \
            { [ -n "$LOCK_OWNER" ] && ! kill -0 "$LOCK_OWNER" 2>/dev/null; }; then
           echo "🔓 stale Lock 감지 (age=${LOCK_AGE}s, owner=${LOCK_OWNER}) — 자동 해제"
           rm -rf "$LOCK_DIR"
         fi
       fi

       # Lock 획득 시도
       if ! mkdir "$LOCK_DIR" 2>/dev/null; then
         echo "⚠️ 다른 프로세스가 phase_batch 조작 중 — 4.5단계 스킵, ofinish 진입"
         rm -f $HOME/.claude/session-env/${UUID}/auto_loop_active
         → ofinish 진입 (4.5단계 탈출)
       fi

       # PID 기록 (stale 감지용)
       echo "$$" > "$LOCK_PID_FILE"

       # 종료 시 자동 해제 (trap)
       # v2 C-07 hotfix: PID 소유권 검증 후에만 Lock 삭제 (trap 재획득 race 방지)
       trap 'if [ "$(cat $LOCK_PID_FILE 2>/dev/null)" = "$$" ]; then rm -rf "$LOCK_DIR"; fi' EXIT INT TERM

    1. phase_batches.json 읽기:
       도구: mcp__oio__file_read(path="$HOME/.claude/session-env/${UUID}/plans/phase_batches.json")
       미존재: → 단일 사이클 완료 → "전체 완료 시" 절차 → ofinish 진입 (기존 동작)

    1.1 유효성 검증 (타입 + 범위):
       total=$(python3 -c "
import json, sys
try:
  d = json.load(open('$HOME/.claude/session-env/${UUID}/plans/phase_batches.json'))
  v = d.get('total_batches')
  if not isinstance(v, int):
    print('INVALID_TYPE'); sys.exit(0)
  print(v)
except Exception as e:
  print('PARSE_ERROR')
" 2>/dev/null)

       case "$total" in
         "INVALID_TYPE"|"PARSE_ERROR"|"")
           echo "❌ total_batches 파싱 실패: $total — 단일 사이클 폴백"
           rm -f $HOME/.claude/session-env/${UUID}/auto_loop_active
           → "다음 Phase 없음" → ofinish
       esac

       if [ "$total" -le 0 ] 2>/dev/null; then
         echo "❌ total_batches=$total (≤0) — 폴백"
         rm -f $HOME/.claude/session-env/${UUID}/auto_loop_active
         → ofinish
       fi

       if [ "$total" -gt 10 ] 2>/dev/null; then
         echo "❌ total_batches=$total (>10) — max_batches 초과"
         rm -f $HOME/.claude/session-env/${UUID}/auto_loop_active
         → ofinish
       fi

    2. current_batch 확인:
       도구: mcp__oio__bash_exec(command='cat $HOME/.claude/session-env/${UUID}/current_phase_batch 2>/dev/null || echo 1')

    2.5. 특수값 감지 (숫자 비교 이전 필수, mcp__oio__bash_exec로 실행 — EXT4($HOME)):
       mcp__oio__bash_exec(command='
         raw=$(cat $HOME/.claude/session-env/${UUID}/current_phase_batch 2>/dev/null)
         case "$raw" in
           "ABORT")
             rm -f $HOME/.claude/session-env/${UUID}/auto_loop_active
             echo "ABORT"
             ;;
           "PAUSE")
             rm -f $HOME/.claude/session-env/${UUID}/auto_loop_active
             echo "PAUSE"
             ;;
           "")
             echo 1 > $HOME/.claude/session-env/${UUID}/current_phase_batch
             echo "FIXED_BLANK"
             ;;
           "0")
             echo 1 > $HOME/.claude/session-env/${UUID}/current_phase_batch
             echo "FIXED_ZERO"
             ;;
           *[!0-9]*)
             rm -f $HOME/.claude/session-env/${UUID}/auto_loop_active
             echo "INVALID:$raw"
             ;;
           *)
             echo "OK:$raw"
             ;;
         esac
       ')
       결과가 ABORT → ofinish 진입 (4.5단계 탈출)
       결과가 PAUSE → ofinish 진입 + "나머지 batch는 /oresume으로 재개 가능" 출력
       결과가 INVALID:* → 강제 ofinish 진입
       결과가 FIXED_BLANK/FIXED_ZERO → 계속 진행

       # 추가 validation: 숫자이지만 범위 검증
       if [ "$raw" -gt 10 ] 2>/dev/null; then
         echo "❌ current_phase_batch=$raw > 10 (상한 초과) — 강제 ofinish"
         rm -f $HOME/.claude/session-env/${UUID}/auto_loop_active
         → ofinish 진입
       fi

    3. 분기 판정:
       current_batch >= total_batches:
         → 전체 batch 완료 → "전체 완료 시" 절차 → ofinish 진입
       current_batch < total_batches:
         → 3.5 독립 batch 병렬 집합 계산 → 집합 크기 1 이면 아래 4번(기존 직렬 2PC), 2 이상이면 3.6(병렬 집합 진행)

    3.5. 독립 batch 병렬 집합 계산 (2026-10-10 — 사용자 지시 "병렬 가능한 작업은 자동 병렬"):
       입력: phase_batches.json(불변) + 완료 집합 DONE = {N | evidence/batch_N_done 존재} ∪ active_phase_batches.json.done
       READY = { b | b ∉ DONE, b 미착수, depends_on_batch 와 extra_depends_on 전부 ∈ DONE(null/빈 목록은 충족) }
       병렬 집합 선택 (batch_id 오름차순 탐욕):
         busy = ∅
         for b in sorted(READY):
           files(b) = b.file_assignment 의 모든 files (소문자·끝 슬래시 제거 정규화)
           files(b) ∩ busy ≠ ∅ → 이번 집합에서 제외(다음 회차 후보)
           odev_parallel "직렬_사유" 4·5(같은 프로젝트 빌드·같은 DB 객체 DDL·같은 기기/포트)에 걸리면 → 제외
           그 외 → 집합에 추가, busy |= files(b)
       계산 스니펫 (mcp__oio__bash_exec — 판정만, 쓰기 없음):
         python3 -c "
import json,os
S=os.environ.get('CLAUDE_CONFIG_DIR',os.path.expanduser('~/.claude'))+'/session-env/${UUID}'
d=json.load(open(S+'/plans/phase_batches.json'))
done={int(n[6:-5]) for n in os.listdir(S+'/evidence') if n.startswith('batch_') and n.endswith('_done') and n[6:-5].isdigit()}
F=lambda b:{f.lower().rstrip('/') for a in (b.get('file_assignment') or {}).values() for f in a.get('files',[])}
busy=set();pick=[]
for b in sorted(d['batches'],key=lambda x:x['batch_id']):
  i=b['batch_id']; deps=[x for x in [b.get('depends_on_batch')]+list(b.get('extra_depends_on') or []) if isinstance(x,int)]
  if i in done or not all(x in done for x in deps): continue
  if F(b)&busy: continue
  pick.append(i); busy|=F(b)
print(json.dumps(pick))"
       기록: active_phase_batches.json (아래 "루프_상태_파일" 참조) — phase_batch.lock(0.5단계) 보유 중에만 쓴다.

    3.6. 병렬 집합 진행 (집합 크기 ≥ 2):
       a. 진행 배너: "🔄 Phase Batch {집합} 병렬 진행 ({완료}/{total})" + 직렬로 미룬 READY batch 와 사유 번호 1줄
       b. file_assignment.json = 집합 batch 들의 file_assignment 를 batches[] 형식으로 합쳐 쓴다(에이전트 이름은 batch 별 고유 — 예 odev-{batch}-{n})
       c. state → DEV, 집합 전체의 odev 를 한 응답에서 동시 spawn (한 메시지 최대 4개, 초과분은 다음 응답에서 즉시 — 완료 대기 금지. + 세션 동시 생존 팀원 ≤9(메인 포함 10) 상한(F-AGENT-CAP) — 남은 슬롯만큼만 보내고 나머지는 팀원 종료 시 즉시)
          상한에 걸리면 차단 안내의 회수 후보(1순위 완료 후 유휴 → 2순위 agent_keep 대기, 작업 중 제외)에게 메인이 shutdown_request → pane 소멸 실측 → 재spawn (hook 은 SendMessage 불가). 회수한 keep 팀원은 필요 시 work/<이름>_result.json 으로 같은 역할 재spawn — 상세 WAVE_SPAWN.md 4-1
          프롬프트에 "Phase Batch {b}/{total} (병렬 집합 {집합})" 명시
       d. odev 전원 완료 대기 → otest 는 자원 축당 1개로 집합 전체 변경을 한 번에 검증 → odone 1회
       e. 성공: 집합의 각 batch 에 evidence/batch_{b}_done 기록 + checkpoint BATCH_NEXT(batch=b) 1줄씩
          active_phase_batches.json.done 에 추가, active 비움, current_phase_batch = (미완료 batch 최소값, 없으면 total) — 레거시 호환
          (batch_transition.py 2PC 는 from→to 단일 전이용이므로 병렬 집합에는 쓰지 않는다. 원자성은 phase_batch.lock + 파일 단위 원자 쓰기로 대신한다)
       f. 실패: 실패 batch 만 reroute_count_batch_{b} +1 → 역라우팅(해당 batch odev 재spawn). 성공한 batch 는 done 처리 유지
       g. 4.5단계 절차 2번으로 재진입 → 3.5 재계산(새로 READY 가 된 batch 포함)

    4. 다음 batch 자동 진행 (2PC 트랜잭션 — v2 B-1 — 병렬 집합 크기 1 일 때):
       0. [사전 교차 불변식 검증] (AC-25/26/27/33):
          VERIFY=$(python3 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/lib/batch_transition.py verify \
            --uuid "${UUID}" --session-id "${SESSION_ID}" --owner-lock "${LOCK_ID}")
          echo "$VERIFY" | jq -e '.valid == true' >/dev/null || {
            echo "⚠️ 교차 불변식 위반 감지: $VERIFY"
            # auto-abort 수행 후에도 violations 남아있으면 ofinish 진입
            echo "$VERIFY" | jq -r '.violations[]'
            rm -f $HOME/.claude/session-env/${UUID}/auto_loop_active
            → ofinish 진입
          }

       a. [PREPARE 단계] 2PC PREPARE 이벤트 기록:
          # batch_transition.py 존재 확인
          if [[ ! -f "$HOME/.claude/lib/batch_transition.py" ]]; then
            echo "⚠️ batch_transition.py 미존재 — simple increment 폴백"
            # 2PC 없이 batch_index를 직접 +1하는 폴백 로직
            BATCH_INDEX=$(( ${current_batch:-0} + 1 ))
            mcp__oio__file_write(path="$HOME/.claude/session-env/${UUID}/current_phase_batch", content="${BATCH_INDEX}", overwrite=true)
            # phase_batches.json에서 다음 batch file_assignment 직접 읽기
            python3 -c "
import json, sys
try:
  data = json.load(open('$HOME/.claude/session-env/${UUID}/plans/phase_batches.json'))
  batch = data['batches'][${BATCH_INDEX}-1]
  print(json.dumps(batch.get('file_assignment', {})))
except Exception as e:
  print('{}'); sys.exit(0)
" 2>/dev/null
          fi
          next_batch=$((current_batch + 1))
          TX_ID=$(python3 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/lib/batch_transition.py prepare \
            --uuid "${UUID}" --session-id "${SESSION_ID}" \
            --owner-lock "${LOCK_ID}" --from "${current_batch}" --to "${next_batch}")
          # 실패 시 AC-11/25/33 reject → ofinish 진입
          if [ -z "$TX_ID" ]; then
            echo "❌ PREPARE 실패 — ofinish 진입"
            rm -f $HOME/.claude/session-env/${UUID}/auto_loop_active
            → ofinish 진입
          fi
          echo "🔐 PREPARE tx_id=${TX_ID} (current=${current_batch}→pending=${next_batch})"

       b. 배치 파일 준비 (pending 단계):
          # 1) 다음 batch file_assignment 로딩
          phase_batches.json의 batches[next_batch-1].file_assignment 추출
          mcp__oio__file_write(path="$HOME/.claude/session-env/${UUID}/file_assignment.json", content=다음batch할당, overwrite=true)
          # 2) 현재 batch evidence 마커 생성
          mcp__oio__file_write(path="$HOME/.claude/session-env/${UUID}/evidence/batch_${current_batch}_done", content=타임스탬프)
          # 3) file_assignment 스냅샷
          cp file_assignment.json file_assignment_batch_${current_batch}.json
          # 4) 진행 배너
          ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
          🔄 Phase Batch {next_batch}/{total_batches} 자동 진행 [tx=${TX_ID:0:8}]
             {batch.description}
             파일: {파일 수}개
          ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
          # 5) 멱등성 체크 (이미 완료된 batch 스킵)
          if [ -f "$HOME/.claude/session-env/${UUID}/evidence/batch_${next_batch}_done" ]; then
            echo "⏭️ batch ${next_batch} 이미 완료됨 — ABORT + 다음 batch로 건너뜀"
            python3 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/lib/batch_transition.py abort \
              --tx-id "$TX_ID" --uuid "${UUID}" --session-id "${SESSION_ID}" \
              --owner-lock "${LOCK_ID}" --reason "idempotent_skip"
            next_batch=$((next_batch + 1))
            # 루프 재시작: 4.5단계 절차 2번(current_batch 확인)으로 goto
            # current_batch 파일을 next_batch로 갱신 후 4.5단계 전체 재진입
            mcp__oio__file_write(path="$HOME/.claude/session-env/${UUID}/current_phase_batch", content="${next_batch}", overwrite=true)
            → 4.5단계 절차 2번(current_batch 확인)으로 재진입 (이하 단계 c~h 스킵)
          fi

       c. odone shutdown (현재 batch의 odone):
          SendMessage(shutdown_request) → shutdown_sent 플래그

       c-1. odone pane 소멸 확인 (최대 30초, 5초 간격 — P1-B4):
          절차: |\
            PANE_ID=$(grep "^pane_id=" $HOME/.claude/session-env/${UUID}/agents/odone-1 2>/dev/null | cut -d= -f2)
            if [ -n "$PANE_ID" ]; then
              for i in $(seq 1 6); do
                sleep 5
                tmux display-message -t "$PANE_ID" -p '#{pane_id}' 2>/dev/null | grep -q '%' || {
                  echo "✅ odone pane 소멸 확인 (${i}회차)"
                  break
                }
                echo "⏳ odone pane 소멸 대기 중... (${i}/6)"
              done
              # 30초 내 미소멸 시 kill escalation
              if tmux display-message -t "$PANE_ID" -p '#{pane_id}' 2>/dev/null | grep -q '%'; then
                echo "⚠️ odone pane 잔류 30초 초과 — kill escalation 실행"
                BASH_PID=$(tmux display-message -t "$PANE_ID" -p '#{pane_pid}' 2>/dev/null)
                kill "$BASH_PID" 2>/dev/null; sleep 1
                kill -9 "$BASH_PID" 2>/dev/null; sleep 1
                tmux set -g status off 2>/dev/null
                tmux kill-pane -t "$PANE_ID" 2>/dev/null
                tmux set -g status on 2>/dev/null
                echo "✅ odone pane kill escalation 완료"
              fi
            fi
            # pane_id 없는 에이전트(Agent tool 방식) → 이 절차 스킵
          목적: odone pane 소멸 확인 후 d단계 진행 — pane 잔류 채로 odev 재spawn 방지

       d. state → DEV + odev 재spawn (다음 batch):
          # team_name은 Agent 호출 시 지정. 팀은 첫 spawn 시 자동 생성되어 세션 내내 유지되므로 별도 사전 생성 불필요.
          # ⚠️ 활성 세션 중 teams/{팀명}/ 디렉토리 수동 삭제 금지 (Agent spawn 전면 차단됨).
          mcp__oio__session_state(uuid="${UUID}", key="state", value="DEV")
          기존 2단계 odev spawn 로직과 동일하되, 다음 batch의 file_assignment 사용
          프롬프트에 "Phase Batch {next_batch}/{total_batches} [tx=${TX_ID}]" 명시

       e. odev 완료 대기 (기존 대기 로직 재사용)

       f. [COMMIT 또는 ABORT 단계] (AC-11/12):
          odev 성공:
            python3 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/lib/batch_transition.py commit \
              --tx-id "$TX_ID" --uuid "${UUID}" --session-id "${SESSION_ID}" \
              --owner-lock "${LOCK_ID}"
            # 성공 시 current_batch가 next_batch로 원자 승격 (AC-11)
            echo "✅ COMMIT tx=${TX_ID:0:8} (current=${next_batch})"

          odev 실패:
            python3 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/lib/batch_transition.py abort \
              --tx-id "$TX_ID" --uuid "${UUID}" --session-id "${SESSION_ID}" \
              --owner-lock "${LOCK_ID}" --reason "odev_fail"
            # AC-12: pending 삭제, current_batch 유지
            echo "❌ ABORT tx=${TX_ID:0:8} — 역라우팅 또는 ofinish 결정"
            → 역라우팅 로직 진입 (reroute_limit 체크)

       g. checkpoint 기록 (COMMIT 성공 시):
          mcp__oio__bash_exec(command='bash ${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/checkpoint_write.sh "${UUID}" "BATCH_NEXT" "DEV" "" "" "batch=${next_batch}/${total_batches} tx=${TX_ID}"')
          # current_phase_batch 파일도 갱신 (레거시 호환)
          mcp__oio__file_write(path="$HOME/.claude/session-env/${UUID}/current_phase_batch", content="${next_batch}", overwrite=true)

       h. otest → odone → 4.5단계 재진입 (루프)

  안전장치:
    max_batches: tier별 동적 로딩 (v2 C-06)
      로딩_로직:
        ```bash
        tier=$(cat $HOME/.claude/session-env/${UUID}/classification 2>/dev/null || echo "O3")
        max_batches=$(jq -r ".overrides.\"${UUID}\".max_batches // .tier_defaults.${tier}.max_batches" $HOME/.claude/config/batch_limits.json)
        reroute_limit=$(jq -r ".overrides.\"${UUID}\".global_reroute_limit // .tier_defaults.${tier}.global_reroute_limit" $HOME/.claude/config/batch_limits.json)
        # tier별 기본값: O3=5/10, O4=8/15, O5=15/20
        # 우선순위: overrides.{UUID} > tier_defaults.{tier}
        ```
      초과_시_폴백 (odone 강제 → 커밋 보장):
        Step 1: "⚠️ tier=${tier} max_batches=${max_batches} 초과 — odone 강제 실행 (커밋 보장)"
        Step 2: odone 강제 실행 (odone_git 포함한 Full Path)
        Step 3: git log 확인 (커밋 해시 검증)
          HASH=$(cd $(git rev-parse --show-toplevel) && git log -1 --format="%H" 2>/dev/null)
          if [ -z "$HASH" ]; then
            Step 4: 커밋 실패 → 원인 1줄 기록 후 odone_git 1회 재시도, 그래도 실패면 최종 보고 보류 목록에 남기고 ofinish 진입 (사람 대기 없음)
          else
            echo "✅ 커밋 확인: ${HASH:0:8}"
          fi
        Step 4.5: auto_loop_active 플래그 제거 (실패 경로 cleanup):
          rm -f $HOME/.claude/session-env/${UUID}/auto_loop_active
        Step 5: ofinish 진입

    사용자_인터럽트:
      방법: 파이프라인 활성 중 사용자 "중단" 감지 (oi는 IDLE 전용이므로 파이프라인 직접 처리)
      동작: current_phase_batch에 "ABORT" 기록 → 4.5단계에서 감지 → ofinish 진입
      cleanup: ofinish 진입 전 rm -f $HOME/.claude/session-env/${UUID}/auto_loop_active

    컨텍스트_한계_도달 (Context Anxiety 대응):
      감지: /compact 트리거 또는 context window 80%+ 사용
      감지_신호: 모델이 "컨텍스트가 부족합니다", "여기서 중단합니다" 패턴 출력 시
      즉시_조치: 작업 포기 금지 — 아래 순서로 처리
        1. 현재까지 완료된 Phase를 checkpoint에 기록 (BATCH_PAUSE, 현재 batch 번호)
        2. ofinish 실행 (경량 — 커밋만)
        3. "⚠️ Context 한계 도달. /oresume 으로 재개 가능합니다." 출력
      금지: "컨텍스트 부족으로 중단합니다" 출력 후 그냥 종료

    빌드_실패_연쇄 (batch별 독립 카운터):
      파일: $HOME/.claude/session-env/${UUID}/reroute_count_batch_{N}

      batch N의 otest 실패 → 역라우팅(odev 재spawn):
        COUNT=$(cat reroute_count_batch_${N} 2>/dev/null || echo 0)
        COUNT=$((COUNT + 1))
        echo $COUNT > reroute_count_batch_${N}
        if [ "$COUNT" -ge 2 ]; then
          "해당 batch에서 중단 → 이전 batch까지 커밋 → ofinish"
        fi

      전역 상한 (모든 batch 합계):
        shopt -s nullglob  # glob 실패 시 빈 배열
        REROUTE_FILES=("$HOME/.claude/session-env/${UUID}"/reroute_count_batch_*)
        shopt -u nullglob

        TOTAL_REROUTE=0
        for _f in "${REROUTE_FILES[@]}"; do
          _n=$(cat "$_f" 2>/dev/null || echo 0)
          [[ "$_n" =~ ^[0-9]+$ ]] && TOTAL_REROUTE=$((TOTAL_REROUTE + _n))
        done

        if [ "$TOTAL_REROUTE" -ge "$reroute_limit" ] 2>/dev/null; then
          echo "⚠️ tier=${tier} 전역 역라우팅 ${reroute_limit}회 초과 — odone 강제 실행 (커밋 보장)"
          # max_batches 초과와 동일한 폴백 절차:
          # Step 1: odone 강제 실행 (Full Path, odone_git 포함)
          # Step 2: git log -1 --format="%H" 로 커밋 해시 검증
          # Step 3: 해시 없으면 odone_git 1회 재시도 → 실패 시 보류 목록 기록 후 진행 (사람 대기 없음)
          # Step 4: ofinish 진입
        fi

      batch 전환 시: reroute_count_batch_{이전N}은 삭제하지 않음 (감사 추적용)
      사유: 후행 batch가 선행 batch에 의존하므로 실패 전파 방지

  루프_상태_파일 (단일 Source of Truth):
    ★ 외부 파일 = 유일한 Source of Truth:
      $HOME/.claude/session-env/${UUID}/current_phase_batch
      내용: 현재 batch 번호 (정수) 또는 ABORT/PAUSE
      갱신: ok_pipeline만 권한 있음
      초기값: 1 (ok_pipeline 1단계 6.5에서 생성)
      특수값: "ABORT" (사용자 중단), "PAUSE" (컨텍스트 한계)

    phase_batches.json:
      내용: oplan이 생성한 immutable 계획
      current_batch 필드: 무시 (외부 파일을 Source of Truth로 사용)
      수정 금지: odev/otest/odone 모두 읽기 전용

    주의: phase_batches.json의 current_batch 필드는 레거시 호환용이며 실제 로직에서 참조 금지.

    active_phase_batches.json (병렬 집합 표현 — 2026-10-10):
      경로: $HOME/.claude/session-env/${UUID}/active_phase_batches.json
      스키마: {"active":[2,3], "done":[1], "deferred":[{"batch":5,"reason":"직렬_사유1 공용 파일 중첩(batch 2)"}], "updated_at":"ISO"}
      갱신: ok_pipeline 만(phase_batch.lock 보유 중). 부재 시 = 직렬 모드(current_phase_batch 단독) — 하위 호환
      current_phase_batch 와의 관계: current_phase_batch 는 "미완료 batch 최소값"(레거시·autoloop_bypass_guard·oresume 호환)으로 유지하고,
        실제 진행 집합의 정본은 active_phase_batches.json.active 다. ABORT/PAUSE 특수값은 current_phase_batch 에만 쓴다.
      완료 판정 정본: evidence/batch_{N}_done (병렬 가드 hook 도 이 파일로 선행 충족을 판정한다)
```

### 전체 완료 시

```yaml
시점: odone 완료 후 → 4.5단계 batch 체크 → 모든 batch 완료 확인 후
핵심_절차:
  1. 4.5단계 Phase Batch Auto-Loop 실행 (phase_batches.json 존재 시)
     - 잔여 batch 있음 → odev 재spawn (ofinish 미진입)
     - 잔여 batch 없음 → 아래 2~3 진행
  1.5. auto_loop_active 플래그 제거 (V8 — Auto-Loop 정상 종료):
     rm -f $HOME/.claude/session-env/${UUID}/auto_loop_active
  2. 체크포인트 검증 (checkpoint_verify.sh)
  3. ofinish 실행 (FINISH 상태 전파는 ofinish Step 0.5에서 수행)
  주의: 각 단계 완료 시 이미 shutdown_request 발송됨. pane 물리적 정리만 ofinish가 수행
```

---

## 병렬 극대화 체크리스트 (리드 — 배정·spawn·대기 관리, L-1202)

리드는 배정 메시지를 보내기 전과 대기 중 팀원이 생길 때마다 아래 8항목을 확인한다.

| # | 항목 | 리드 행동 | 물리 장치 |
|---|---|---|---|
| 1 | 독립 과업 분리 | 서로 다른 파일을 건드리는 과업은 팀원을 따로 두고 같은 응답에서 동시에 spawn 한다. 한 메시지에 "추가 배정 N건"으로 몰지 않는다. 순서 의존(앞 결과를 뒤가 쓰는) 과업만 한 팀원에게 묶는다. | `PreToolUse_multi_task_assign_guard.sh`(경고) |
| 2 | 파일 소유자 1명 | 파일마다 담당 팀원은 1명이다. 재배정할 때는 기존 담당에게 먼저 "그 파일을 멈춰라"를 보내고 회신을 받은 뒤 새 담당에게 넘긴다. 메시지가 늦게 도착할 수 있으니 두 사람이 같은 파일을 동시에 가진 시간을 만들지 않는다. | — |
| 3 | 대기 팀원 선행 배정 | "입력이 오면 하겠다"며 쉬는 팀원에게는 지금 할 수 있는 부분 작업(부분 병합·초안·검증 스크립트·도착한 산출물 선처리)을 준다. | `teammate_idle_guard` P 규칙(경고) |
| 4 | 90초 호출 상한 | 팀원 지시에 "bash_exec 한 번은 90초 이내"를 넣는다. 120초를 넘긴 MCP 호출은 자동으로 백그라운드로 넘어가고, 그런 호출이 남은 세션은 이후 oio 호출이 모두 "Invalid request parameters"로 실패할 수 있다. | `PreToolUse_oio_bash_duration_guard.sh`(팀원 차단) |
| 5 | 폴링은 짧게 끊고 메시지 확인 | 긴 대기는 `setsid nohup … &` 로 분리하고 `timeout 85 bash -c 'until <조건>; do sleep 10; done'` 를 반복 호출해 확인한다. 호출 사이에 도착한 메시지를 먼저 처리한다. Monitor 에는 test·`[ ]`·pgrep·sleep·echo·date·true·false 와 그것만으로 된 `until`/`while` 대기 루프, `;`·`&&`·`||` 사슬이 통과한다. cat·tail·grep·ls·awk 등 permissions.deny 명령이 섞이거나 리다이렉트·명령 치환·파이프·그 밖의 명령이 섞이면 막힌다. bash_exec 는 긴 명령을 자동으로 백그라운드로 넘기므로 `…; sleep N` 꼴 대기를 쓰지 않고, 결과 내용은 끝난 뒤 oio 로 읽는다. | 같은 hook(Monitor 선검사) + `bg_job_guard` |
| 6 | 물리 자원만 직렬 | 직렬로 돌리는 것은 단일 인스턴스 앱·실기기·같은 프로젝트 빌드·phase_batches 의 내부 스테이지 순서뿐이다. 그 밖의 독립 과업은 병렬이 기본이다. | `PreToolUse_Agent_parallel_spawn_guard.sh`(stage 인식) |
| 7 | 적극 병렬 + 세션 동시 생존 팀원 ≤9(메인 포함 10) | 이 세션에서 동시에 살아 있는 팀원(oplan·odev·otest 등 전부 합산)은 `max_live_teammates`(9) 이하로 둔다. 메인을 포함하면 10개다. 초과분은 대기열에 두고, 보고를 끝낸 팀원을 즉시 shutdown 한 뒤 다음 spawn 을 보낸다. 상한에 걸리면 차단 안내의 회수 후보(1순위 유휴 → 2순위 keep 대기, 작업 중 제외)를 메인이 shutdown → pane 소멸 실측 → spawn 한다. | `PreToolUse_Agent_cap.sh`(7.5 closed — 정체 시에도 확정) + 구 경로 `PreToolUse_Agent_parallel_spawn_guard.sh` → `lib/agent_cap.py`(F-AGENT-CAP 차단·회수 후보) |
| 8 | 부하 대기 기준(사용자 지시, L-600) | 무거운 시험이나 비가역 1회 실행 앞에서 부하 때문에 기다릴 때는 `load` 1분 평균 **50 이하**를 사전 거름으로 쓴다. 실행 가능 여부는 절대 부하값이 아니라 **같은 시간 상한의 직전 리허설 PASS 실측**으로 판정한다. 근거 없는 낮은 임계값(예: 10)으로 무기한 대기하는 것은 금지다. 다른 세션이 작업 중이면 부하는 50을 넘기 쉽다. 이 원칙은 다음 작업에도 자동 적용된다. | **물리 장치 없음(문서 규칙)** — 리드의 대기 판단을 강제할 hook 수단이 없다. 리드의 자율 준수에 달려 있다. |

### 부하 정체 중 spawn 절차 (F-LOAD-STAGGER · spawn_ack_watch, 위 7·8항과 정합)

- `load` 1분 평균이 50 이하이면 평소처럼 병렬 spawn 한다(8항의 사전 거름 기준과 같다).
- 50을 넘으면 `PreToolUse_Agent_load_stagger.sh` 가 최근 20초 안 3번째 팀원 spawn 부터 보류한다. 2개씩 20초 간격으로 나눠 spawn 하고, 보류 안내의 "N초 뒤 재시도"를 지킨다. 7항의 동시 생존 상한(9)은 그대로 적용된다.
- 이 hook 은 동시 기동 수를 줄여 소실 확률을 낮추는 완화책이다. 팀원 프로세스가 사라지는 원인 자체는 하네스 밖이라 고치지 못한다.
- 소실 시 복구는 `TaskStop("<이름>")` 으로 남은 작업 항목을 정리한 뒤, 같은 역할을 다른 이름(예: odev-A6 → odev-A6b)으로 재spawn 하는 것이다. 같은 이름은 in-process 레지스트리 잔존으로 막힐 수 있다.
- `spawn_ack_watch`(PostToolUse Agent, asyncRewake) 경보 해석은 이렇다.
  - 기한(기본 150초) 안에 첫 지시 소비(ack)가 관측되지 않으면 "미소비" 경보가 온다. 먼저 SendMessage 로 재송신해 보고, 프로세스가 없으면 TaskStop 후 재spawn 한다.
  - ack 뒤 연속 2회 프로세스가 없고 inbox 에 shutdown_request 도 없으면 "소실" 경보가 온다. 리드가 TaskStop 으로 의도적으로 멈춘 팀원이면 무시한다.
  - 판정 불가는 조용히 끝난다(fail-open).

## 팀원 생명주기 관리 (보고 후 대기·완료 즉시 shutdown·비정상 복구)

> 팀원 pane 상태 점(`@agent_state`)은 팀원 hook(`pane_state_dot.sh`)과 판정기(`hooks/lib/teammate_turn_report.py`)가 정한다.
> 리드는 아래 표의 상태를 보고 행동한다. 리드 가드(`hooks/lib/teammate_idle_guard.py`) 규칙 D/E/F 가 이 행동을 강제한다.

### 상태 범례와 리드 행동

| 상태 | 표시 | 의미 | 리드 행동 |
|---|---|---|---|
| run | ◜◝◞◟ 스피너 — 연한 배경 1초마다 빨강 colour217 → 초록 157 → 노랑 229 → 파랑 153 순환, 글자 검정 colour16 (테두리 선 colour203) | 작업 중 | 대기한다. |
| idle | 빈 원 ◯ — 글자 green (선 green) | 보고 후 대기(정상, 중간 보고 있음) | 보고를 읽고 다음 지시 또는 shutdown 을 보낸다. |
| silent | 빈 원 ◯ — 글자 magenta(자홍) (선 magenta) | 무보고 대기(이번 턴에 team-lead 보고 없음) | 즉시 상태를 묻는다. 장기화(기본 10분)되면 가드 D 가 차단하므로 아래 복구 절차를 수행한다. |
| keep | 가득 찬 원 ⬤ — 글자 colour39(파랑) (선 colour39) | 재사용 대기(완료 보고 + 유효한 agent_keep) | 재사용할 작업을 지시한다. 만료되면 done 으로 바뀐다. |
| done | 가득 찬 원 ⬤ — 글자 colour240(회색) (선 colour240) | 완료 보고 후 대기 = 정리 대상 | 즉시 shutdown_request 를 보낸다. 방치하면 가드 F 가 차단한다(기본 5분). |
| 신호 종료 | 가득 찬 원 ⬤ — 글자 colour240(회색) | pane_dead(신호 또는 정상 종료 0) | shutdown 을 보내지 않았다면 비정상 종료다. 아래 복구 절차를 수행한다. 보냈다면 죽은 pane 을 정리한다. |
| 오류 종료 | 가득 찬 원 ⬤ — 글자 yellow | pane_dead(0 이 아닌 종료 코드) | 아래 복구 절차를 수행한다. |

우선순위는 pane_dead > done > keep > silent > idle > run 이다.

원 모양 — 빈 원 ◯ = 살아서 다음 지시를 기다림(idle·silent), 가득 찬 원 ⬤ = 완료·종료로 리드 정리 대상(keep·done·pane 종료). 배경색은 동작 중(run)에만 쓴다.

### 보고 후 대기 규칙 (팀원 측 강제)

- 팀원은 매 턴 끝에 SendMessage(to="team-lead", summary 필수)로 진행·결과·막힌 점을 보고한 뒤 대기한다. 보고할 것이 없으면 "대기 — 사유" 한 줄이라도 보고한다.
- `TeammateIdle_report_guard.sh`(TeammateIdle hook)가 이번 턴 무보고를 감지하면 exit 2 로 턴을 이어가게 한다. 같은 턴에서 최대 2회(`TRG_MAX_BLOCKS`) 차단한 뒤에는 silent 로 기록하고 놓아준다(무한 루프 방지).
- 기록 파일은 `session-env/${UUID}/teammate_turn/{이름}.json` 이다. 스위치는 전역 `touch ${HARNESS_HOME:-$HOME/.harness}/current/hooks/.teammate_report_guard_off`, 세션 `session-env/${UUID}/teammate_report_guard_mode`(off|warn|block) 이다.

### 완료 = 즉시 shutdown 원칙

- 완료 보고를 받으면 **바로** 그 팀원에게 shutdown_request 를 보낸다. "나중에 쓸지도 모른다"는 이유로 남겨두지 않는다.
- 재사용할 예정일 때만 `session-env/${UUID}/agent_keep/{이름}` 에 사유를 5자 이상 기록한다. 유효 시간은 120분(`TIG_KEEP_TTL_MIN`)이며, 그동안 상태가 keep(파랑 ◯)으로 표시된다.
- 사유 없는 done 잔존과 신호 종료 잔존은 정리 대상이다. 가드 F(사유 없는 done)와 E(pane_dead)가 리드의 다른 도구 사용을 차단한다.

### 사용자 중지·범위 지시 전파 / 실업무 쓰기 스냅샷 (사이클172 gate)

- **중지·범위 지시(L-1195)**: 사용자 중지·범위 지시를 받으면 리드는 SendMessage 와 **함께** `mcp__oio__file_write` 로 `session-env/${UUID}/scope_markers/{팀원이름}.json`(팀 전체는 `_all.json`)에 `{"type":"stop|scope","message":"사용자 지시 원문","by":"team-lead","created_at":"ISO8601"}` 를 쓴다. `PreToolUse_stop_marker_gate.sh` 가 팀원의 다음 도구 호출을 1회 보류하며 원문을 전달하고, stop 이면 이후 읽기·SendMessage 외 도구를 차단한다. 해제는 리드가 파일을 삭제한다(팀원은 마커를 지울 수 없다). 비상 해제는 `hooks/DISABLE_STOP_MARKER_GATE` 이다. 또 PLAN~DONE 중 사용자 입력은 `UserPromptSubmit.sh` 가 `scope_markers/_user.json`(type=info, 중지성 어휘면 suspected=stop)에 자동 기록해 팀원에게 1회 전달한다. info 는 지속 차단하지 않으므로 **진짜 중지는 리드가 stop 마커를 써야 지속 차단된다**.
- **실업무 행 스냅샷(L-1200)**: 팀원이 MySQL 실업무 테이블에 UPDATE/DELETE 하려면 먼저 `session-env/${UUID}/evidence/snapshot_{테이블}_{HHMMSS}.json` 에 `{"table","where","rows":[SELECT 결과],"taken_at"}` 를 남겨야 한다(`PreToolUse_snapshot_gate.sh`). `[cNNNtest]` 표식 행 한정 쓰기와 INSERT 는 통과한다. 앱(UI→GW) 경유 쓰기는 hook 이 감지하지 못하므로 그 경우도 같은 파일을 먼저 남긴다. 사후 게이트로 `verify_crud_executed.py --emit-from-goal` 이 item_crud:true 항목의 스냅샷 mtime < 첫 쓰기(write_ts/gw_log_ts)를 요구하며, 못 맞추면 make_ok 대신 make_partial 이다(표식 신규 행만이면 증거에 `"live_rows": false`).

### 복구 절차 (pane_dead / 무보고 장기화 / API Connection lost)

사례: 2026-10-08 09:38 oplan-1 이 API Connection lost 로 무보고 중단됐다. 사용자가 pane 을 보고서야 알았다.
차단 중에도 아래 ①~③ 도구는 가드가 허용한다.

1. **① pane 캡처**: `tmux capture-pane -p -t %N -S -300` 을 단독 명령으로 실행하고, 결과를 `mcp__oio__file_write` 로 `session-env/${UUID}/evidence/pane_capture_{이름}_{HHMMSS}.txt` 에 저장한다.
2. **② 죽은 pane 정리**: 팀 config members 에서 그 팀원의 tmuxPaneId 를 확인한다(자기 팀 pane 만 대상). 확인 후 `tmux kill-pane -t %N` 을 단독 명령으로 실행한다. 타 세션 pane 은 건드리지 않는다.
3. **③ 같은 역할 재spawn**: 이름은 `{역할}-{N+1}` 로 하고, model 과 team_name 은 원래와 같게 한다. 프롬프트에는 다음을 반드시 넣는다.
   - (a) 원 spawn 프롬프트 요지
   - (b) 마지막 handoff 파일 경로(`plans/handoff_*.md`)
   - (c) ①의 캡처 파일 경로
   - (d) 마지막으로 수신한 보고 원문
   - (e) 완료·미완 항목 목록과 "중단 지점부터 재개, 완료분 재실행 금지" 지시
4. **④ reroute_count 미증가**: 인프라 장애이므로 역라우팅 횟수에 넣지 않는다. 같은 역할이 연속 2회 실패하면 조기 종료하고 사용자에게 보고한다(기존 fallback 과 같다).
5. **⑤ 교훈 위임**: 같은 원인이 2회 이상 반복되면 odone 이 LESSONS 에 교훈을 기록한다.

### 팀원 교대 절차 (장기 팀원 메모리 누적 방지)

- 기본 원칙은 **작업 1건 = 팀원 1개**다. 보고 후 즉시 shutdown 하며(위 "완료 = 즉시 shutdown 원칙"), 같은 팀원에 작업을 계속 얹지 않는다.
- 장기 팀원(생존 90분 이상 또는 RSS 1200MB 이상)은 교대를 권고한다. 순서는 다음과 같다.
  1. **인계 파일 작성**: 선임이 `session-env/${UUID}/plans/handoff_{이름}.md` 에 완료·미완 항목, 수정 파일, 막힌 점, 다음 단계를 남긴다.
  2. **후임 spawn**: 이름은 `{역할}-{N+1}`, model·team_name 은 선임과 같게 하고 프롬프트에 인계 파일 경로와 "완료분 재실행 금지"를 넣는다.
  3. **선임 shutdown**: 후임의 첫 보고를 확인한 뒤 선임에게 shutdown_request 를 보낸다.
- `teammate_reaper`·`Stop_teammate_reaper` 는 사후 회수(유휴·고착 정리) 안전망이고, 이 절차는 그 전에 리더가 계획적으로 바꾸는 선제 교대다.

### 한계

- hook 은 Agent 를 호출할 수 없다. 따라서 자동 재spawn 은 불가하다. 리드 가드 E/D 차단으로 리드에게 복구를 강제한다.
- in-process 모드 팀원은 TeammateIdle 가드 대상이 아니다(`--agent-id` 경로 식별 불가).
- 이미 기동한 세션은 settings hooks 를 시작 시 캐시하므로, TeammateIdle 가드 등록은 새로 시작한 세션부터 적용된다.

---

## Handoff Artifact (단계간 컨텍스트 전달 — N2)

```yaml
handoff_artifact:
  목적: 에이전트 컨텍스트 리셋 후에도 이전 단계 핵심 정보 보존
  oplan→odev: $HOME/.claude/session-env/${UUID}/plans/handoff_plan_to_dev.md
    내용: 구현 우선순위, 핵심 제약사항, 주의 파일 목록
  odev→otest: $HOME/.claude/session-env/${UUID}/plans/handoff_dev_to_test.md
    내용: 수정된 파일 목록, 알려진 미완성 항목, 테스트 집중 영역
  otest→odone: $HOME/.claude/session-env/${UUID}/plans/handoff_test_to_done.md
    내용: PASS/FAIL 결과, 잔여 이슈, 커밋 메시지 초안
  생성_의무: 각 단계 완료 보고 전 handoff.md 생성 필수
```

## 파이프라인 순서 엄수

```yaml
순서: oplan산출물검증(1) → odev(2) → otest(3) → odone(4) → 완료보고
참고: oplan spawn/완료는 ok가 관리. ok_pipeline은 산출물 검증부터 시작.
규칙:
  - oplan 산출물 검증 전 odev spawn 금지
  - odev 전체 완료 전 otest 진입 금지
  - otest 전체 통과 전 odone 진입 금지
  - odone 완료 전 완료 보고 금지

단계_건너뛰기_방지:
  절대_원칙:
    - 각 단계(oplan/odev/otest/odone)는 반드시 팀에이전트로 spawn — 메인이 직접 수행 절대 금지
    - 이전 단계 완료 보고(Agent 도구 반환 + 완료 키워드) 수신 전 다음 단계 spawn 금지
    - o1이라도 odev는 팀에이전트 spawn 필수
    - [L-030] Agent spawn 직전 반드시 해당 STATE 설정 (spawn_직전 단계) — 생략 시 HOOK_BLOCK_PIPELINE_ORDER 발생
      예: odev spawn 전 → STATE=DEV, otest spawn 전 → STATE=TEST, odone spawn 전 → STATE=DONE
  위반_패턴 (감지 즉시 중단):
    - "oplan 결과 받자마자 검증 없이 즉시 odev spawn" → 필수 필드 검증 누락
    - "odev 1개 완료됐으니 otest 먼저 spawn" → 나머지 odev 미완료
    - "간단하니까 메인이 직접 수정" → L-171 위반
    - "o2니까 obr을 메인이 직접 실행" → write_guard 차단됨. 팀에이전트로 spawn 필수
    - "otest 생략하고 odone으로 진행" → o3 이상은 otest 필수
```

> 모델 배정: tier별 매트릭스 참조 (상단 "tier별 파이프라인 분기" 섹션)

## 실패 시 역라우팅

> 역라우팅 절차: 본 문서 내 아래 yaml 블록 참조

```yaml
원칙: 각 단계 실패 시 메인이 이전 단계 상태를 설정(진입 기반) 후 해당 단계 재spawn
카운터: $HOME/.claude/session-env/${UUID}/reroute_count (0→+1, 20 초과 시 조기 종료)

reroute_count_원자적_증가:
  방법: mcp__oio__session_state(uuid="${UUID}", key="reroute_count", value="increment")
  처리: flock 기반 원자적 +1 (session_ops.py 내장)
  checkpoint_기록_REROUTE: mcp__oio__bash_exec(command='bash ${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/checkpoint_write.sh "${UUID}" "REROUTE" "{from_stage}" "" "" "{from}→{to}: {사유}"')
  reroute_log_기록 (교훈 분석용 — 필수):
    시점: 역라우팅 결정 직후, 재spawn 직전
    방법: mcp__oio__bash_exec(command='echo "[$(date +%Y-%m-%dT%H:%M:%S)] from:{에이전트명} to:{대상단계} reason:{구체적사유}" >> $HOME/.claude/session-env/${UUID}/reroute_log')
    필수_필드:
      - from: 역라우팅을 트리거한 에이전트 (예: otest-1)
      - to: 역라우팅 대상 단계 (예: DEV, PLAN)
      - reason: 구체적 사유 (예: "BUILD_FAILED: error CS1061 — Member does not exist")
    활용: odone_review Step 1 역라우팅 원인 분석에서 reroute_log 파일 읽기

  역라우팅_원인_기록 (절대 필수 — reroute_log와 병행):
    시점: 역라우팅(odev/otest 재spawn) 발생 즉시
    목적: odone_review 소스 D/F에서 역라우팅 원인을 정밀 분석할 수 있도록 구조화된 기록 제공

    1_reroute_context_md_기록:
      파일: $HOME/.claude/session-env/${UUID}/logs/reroute_context.md
      방법: |
        mcp__oio__bash_exec(command='cat >> $HOME/.claude/session-env/${UUID}/logs/reroute_context.md << EOF
        ## [$(date "+%Y-%m-%d %H:%M:%S")] 역라우팅 #${REROUTE_COUNT}
        - **단계**: ${CURRENT_STAGE} → ${TARGET_STAGE}
        - **원인**: ${REROUTE_REASON}
        - **에이전트**: ${AGENT_NAME}
        - **파일**: ${AFFECTED_FILES}
        EOF')
      필수_필드:
        - REROUTE_COUNT: 현재 역라우팅 회차 (reroute_count 값)
        - CURRENT_STAGE: 실패 발생 단계 (TEST, DEV 등)
        - TARGET_STAGE: 역라우팅 대상 단계 (DEV, PLAN 등)
        - REROUTE_REASON: 구체적 실패 사유 (빌드 에러 메시지, 테스트 실패 항목 등)
        - AGENT_NAME: 실패를 트리거한 에이전트 (otest-1, odev-2 등)
        - AFFECTED_FILES: 영향받은 파일 목록

    2_pipeline_events_REROUTE_기록:
      파일: $HOME/.claude/session-env/${UUID}/logs/pipeline_events.jsonl
      방법: |
        mcp__oio__bash_exec(command='echo "{\"ts\":\"$(date -Iseconds)\",\"event\":\"REROUTE\",\"from\":\"${CURRENT_STAGE}\",\"to\":\"${TARGET_STAGE}\",\"count\":${REROUTE_COUNT},\"reason\":\"${REROUTE_REASON}\",\"agent\":\"${AGENT_NAME}\"}" >> $HOME/.claude/session-env/${UUID}/logs/pipeline_events.jsonl')
      주의: reason 필드에 큰따옴표 포함 시 이스케이프 처리 필수

    3_reroute_count_증가:
      방법: mcp__oio__session_state(uuid="${UUID}", key="reroute_count", value="increment")
      (위 reroute_count_원자적_증가와 동일 — 중복 증가 방지, 한 번만 실행)

    실행_순서: 1→2→3 순차 (모두 완료 후 재spawn 진행)
    검증: odone_review가 reroute_context.md + pipeline_events.jsonl 양쪽에서 REROUTE 이벤트 교차 확인

허용: DEV→PLAN, TEST→DEV, TEST→PLAN, DONE→TEST (최대 20회)
  TEST→PLAN 조건: otest에서 근본 원인이 설계/계획 단계 재검토를 요구할 때만 (단순 버그 수정은 TEST→DEV)
제한: 증거파일 초기화 필수, 팀 재사용(L-221)

에스컬레이션_정책_통합 (v4.2 — RLHF Evidence-Gate):
  적용: o3~o5 (o2는 obr만)

  역라우팅_판정_기준:
    1~2회: odev 자동 (구현 버그 — 실행 에러/크래시)
    동일항목_2연속: oplan 에스컬레이션 (설계 재검토)
    3~4회: oplan (설계 결함)
    5회+: 메인 자율 판정 — advisor 조언(메인 한정) 후 이전과 다른 접근법 강제 (사람 대기 없음)
    20회: EARLY_TERM (강제 중단)

  reroute_history 기반 자동 판정:
    파일: $HOME/.claude/session-env/${UUID}/evidence/reroute_history.json
    동일_항목_정의: 같은 acceptance criteria ID + 같은 에러 카테고리
    동일_2연속_감지_시: TEST→PLAN 강제 전환 (TEST→DEV 금지)

  otest_대기_프로토콜 (v4.3 — heartbeat 파일 기반 타임아웃):
    기존: otest FAIL → shutdown → odev/oplan → otest 재spawn
    변경: otest FAIL → 대기 → odev/oplan → RETEST → diff 비교
    타임아웃: 30분 (초과 시 otest 종료 → 재spawn) — 물리적 heartbeat 파일로 강제
    otest_shutdown: 최종 PASS 또는 EARLY_TERM 시에만

  otest_heartbeat_타임아웃 (물리적 강제 — LLM 의지 비의존):
    RETEST_대기_진입_시 (otest가 FAIL 보고 후 대기 시작):
      mcp__oio__bash_exec(command='echo $(date +%s) > $HOME/.claude/session-env/${UUID}/evidence/otest_retest_heartbeat')
    odev_수정_시작_시 (역라우팅 odev가 작업 시작할 때):
      mcp__oio__bash_exec(command='echo $(date +%s) > $HOME/.claude/session-env/${UUID}/evidence/otest_retest_heartbeat')
    odev_수정_완료_시 (역라우팅 odev가 완료 보고할 때):
      mcp__oio__bash_exec(command='echo $(date +%s) > $HOME/.claude/session-env/${UUID}/evidence/otest_retest_heartbeat')
    타임아웃_확인 (RETEST 메시지 수신 전 ok_pipeline이 대기 중):
      mcp__oio__bash_exec(command='
        HB=$HOME/.claude/session-env/${UUID}/evidence/otest_retest_heartbeat
        if [ -f "$HB" ]; then
          LAST=$(cat "$HB")
          NOW=$(date +%s)
          ELAPSED=$((NOW - LAST))
          if [ $ELAPSED -gt 1800 ]; then
            echo "TIMEOUT: ${ELAPSED}초 경과 (30분 초과)"
            exit 1
          fi
          echo "OK: ${ELAPSED}초 경과"
        else
          echo "NO_HEARTBEAT"
          exit 1
        fi
      ')
      exit_code=1 시: otest 종료 요청 → otest 재spawn (reroute_count +1)

otest_역라우팅_상세_절차:
  절차:
    1. otest FAIL 보고 수신 (종료하지 않음)
    2. odev 또는 oplan 역라우팅 spawn
    3. 역라우팅 완료 보고 수신
    4. SendMessage(to: "otest-1", message: "RETEST: 역라우팅 완료, 재검증 시작", summary: "RETEST 재검증 시작")
    5. otest diff 비교 재검증 결과 수신
    6. PASS → odone / FAIL → 재역라우팅 또는 조기 종료

DONE→TEST_역라우팅_상세_절차 (odone 실패 시 — otest 재spawn 필요):
  # DONE→TEST 시 otest는 이미 PASS 후 종료된 상태이므로 RETEST 프로토콜 사용 불가
  # 반드시 otest-1을 재spawn해야 함
  절차:
    1. odone 실패 보고 수신 (odone 에이전트에 shutdown_request 발송)
    2. state_전파: mcp__oio__session_state(uuid="${UUID}", key="state", value="TEST")
    3. reroute_count +1 (원자적 증가)
    4. 역라우팅_원인_기록: reroute_context.md + pipeline_events.jsonl 기록 (사유: odone 실패)
    5. otest-1 재spawn (새 에이전트 — 기존 RETEST 프로토콜 아님)
       Agent(subagent_type="general-purpose", team_name="{팀명}", name="otest-1",
             model="sonnet", mode="bypassPermissions",
             prompt="PIPELINE_UUID={UUID}. Skill('otest') 로딩. [DONE→TEST 역라우팅] odone 실패로 인한 재검증. reroute_context.md 참조: ...")
    6. otest 완료 대기 → PASS 시 odone 재spawn / FAIL 시 odev/oplan 역라우팅

reroute_context_생성 (역라우팅 결정 시 즉시):
  파일: $HOME/.claude/session-env/${UUID}/logs/reroute_context.md
  내용: 실패 단계, 원인, 영향 파일, 시도한 접근법, 권고 수정 방향
  목적: (1) 재spawn 에이전트에 실패 맥락 전달 → 동일 실패 반복 방지 (2) odone_review 소스D/F 교훈 분석 입력
  ⚠️ 상세 기록 절차: 위 "역라우팅_원인_기록" 섹션 참조 (reroute_log + reroute_context.md + pipeline_events.jsonl 병행)
  생성_절차: |
    mcp__oio__dir_create(path="$HOME/.claude/session-env/${UUID}/logs")
    cat > $HOME/.claude/session-env/${UUID}/logs/reroute_context.md <<EOF
    # 역라우팅 맥락
    - 실패 단계: {PLAN|DEV|TEST|DONE}
    - 실패 원인: {요약}
    - 영향 파일: {파일 목록}
    - 시도한 접근법: {설명}
    - 권고 수정 방향: {설명}
    EOF

재spawn_프롬프트_필수_포함:
  - 실패 원인 요약
  - 영향받은 파일 목록
  - 시도한 접근법
  - reroute_context.md 경로: $HOME/.claude/session-env/${UUID}/logs/reroute_context.md

역라우팅_state_전파 (진입 기반 원칙 유지): # M-04
  TEST→DEV: mcp__oio__session_state(uuid="${UUID}", key="state", value="DEV") (DEV 재진입)
  TEST→PLAN: mcp__oio__session_state(uuid="${UUID}", key="state", value="PLAN") (PLAN 재진입)
  DEV→PLAN: mcp__oio__session_state(uuid="${UUID}", key="state", value="PLAN") (PLAN 재진입)
  DONE→TEST: mcp__oio__session_state(uuid="${UUID}", key="state", value="TEST") (TEST 재진입)
  # FINISH→PLAN/DEV 전환 허용: ofinish Step 3 백업 Auto-Loop 전용
  # pipeline_order_guard.sh가 이 전환을 허용하도록 설정되어 있음
  원칙: 역라우팅 = 해당 단계 재진입이므로 진입 기반 state 전파와 동일

동일_경로_서브리밋 (P0):
  감지: reroute_context.md에서 최근 3회 역라우팅 경로 비교
  조건: 동일 경로(예: TEST→DEV) 3회 연속 반복 시
  처리: 자동 에스컬레이션 — TEST→PLAN 강제 전환
  근거: 동일 패턴 반복은 근본 원인이 다른 곳에 있음을 의미

점진적_backoff (역라우팅 단계별 전략):
  1-3회: 즉시 역라우팅 (동일 경로 3연속 시 에스컬레이션)
  4-7회: reroute_context.md 필수 확인 + 이전과 다른 접근법 강제
  8-20회: 메인 자율 판정 — reroute_context.md 대조 + 접근법 전환 강제 (사람 대기 없음)
  20회_초과: 조기 종료 (EARLY_TERM)
```

## 조기 종료 (Early Termination) # H-03

```yaml
트리거_조건 (ANY 충족 시 즉시 발동):
  1. reroute_count 20회 초과
  2. 동일 에이전트 비정상 반환 연속 3회
  3. 외부 의존성 장애 (DB 연결 불가, 빌드 도구 미설치 등)
  4. 사용자 명시적 중단 요청
  5. 파이프라인 교착 감지 (파이프라인 시작 후 wall-clock 120분 경과 AND DONE 미도달) — 역라우팅에 의한 state 전환은 교착 해제로 간주하지 않음

처리_절차:
  1. 현재 활성 에이전트에 shutdown_request 일괄 발송
  2. 현재 단계의 산출물 보존 (evidence/ 디렉토리 유지)
  3. mcp__oio__session_state(uuid="${UUID}", key="state", value="EARLY_TERM")
  4. ofinish 즉시 실행 (경량 모드: 팀 정리 + 사용자 보고만)
  5. 사용자에게 중단 사유 + 진행 상태 + 재시작 가이드 보고

경량_ofinish: 통계 수집 생략, ntfy "조기 종료" 알림, pane 정리만 수행 (팀 디렉토리는 세션 종료 시 자동 정리)
```

## 장기 개선: desired/actual state 분리 (K8s Operator 패턴)

> **현재 상태**: state 파일이 단일 값(예: "DEV UUID")으로 현재 단계만 표현
> **개선 방향**: desired state와 actual state를 분리하여 reconciliation loop 구현 가능

```yaml
설계_개념:
  현재: echo "DEV ${UUID}" > state  # 단일 상태
  개선:
    desired_state: "DEV"  # 메인이 설정 (목표)
    actual_state:         # 실시간 업데이트
      odev-1: "running"   # 에이전트별 상태
      odev-2: "completed"
      odev-3: "failed"

  reconciliation_loop:
    주기: 각 에이전트 반환 시 actual_state 업데이트
    동작: desired != actual → 차이 해소 (재spawn/에스컬레이션)
    이점:
      - compact 후 정확한 상태 복원 (에이전트별 진행도 보존)
      - 부분 실패 시 실패 에이전트만 재시도
      - ostatus 진단 정확도 향상

  구현_파일:
    $HOME/.claude/session-env/${UUID}/desired_state.json
    $HOME/.claude/session-env/${UUID}/actual_state.json

  우선순위: P2 (현재 단일 state로 충분히 동작, 복잡도 대비 ROI 검토 필요)
```

## Spawn 위임 프로토콜 (팀에이전트 → 메인)

```yaml
> Claude Code는 flat team 구조 — 팀에이전트가 하위 팀에이전트를 직접 spawn할 수 없음.
> 팀에이전트가 병렬 서브에이전트가 필요한 경우, 메인에게 spawn을 위임한다.

프로토콜:
  1_요청: 팀에이전트 → 메인 SendMessage
    형식: "SPAWN_REQUEST: {에이전트명} {model} {스킬} {프롬프트요약}"
    예시: "SPAWN_REQUEST: odone_git-1 haiku odone_git 커밋+푸시 수행"
    복수_요청: 한 메시지에 여러 SPAWN_REQUEST 가능 (줄바꿈 구분)

  2_처리: 메인이 수신 즉시 Agent spawn
    team_name: 현재 팀 유지
    name: 요청된 에이전트명
    model: 요청된 모델
    프롬프트: 요청 팀에이전트가 제공한 프롬프트 + "완료 시 {요청_에이전트명}에게 SendMessage로 결과 보고"

  3_결과_전달: spawn된 에이전트 → 요청 팀에이전트 직접 DM
    형식: SendMessage(to: "{요청_에이전트명}", message: "완료 보고 + 결과 요약", summary: "서브에이전트 완료 보고")
    메인_경유_불필요: 팀에이전트 간 직접 통신 (같은 팀 소속)

  4_종료: spawn된 에이전트 완료 후
    요청_에이전트가 SendMessage(to: "team-lead", message: "SHUTDOWN_SUB: {에이전트명}", summary: "서브에이전트 종료 요청")
    메인이 해당 에이전트에 shutdown_request 발송

메인_의무:
  - SPAWN_REQUEST 수신 시 즉시 처리 (지연 금지)
  - spawn 실패 시 요청 에이전트에 실패 사유 전달
  - spawn된 에이전트의 idle/완료 메시지는 무시 (요청 에이전트가 관리)

팀에이전트_의무:
  - spawn 필요 시 반드시 메인에게 위임 (직접 Agent 호출 금지)
  - spawn된 에이전트의 완료를 직접 수신하여 다음 단계 진행
  - 모든 서브에이전트 완료 후 메인에게 SHUTDOWN_SUB 요청

Fallback (spawn 위임 실패 시):
  - 메인 무응답 30초 → 팀에이전트가 Skill() 직접 로딩으로 순차 수행
  - spawn 자체 불가 → Skill() 직접 로딩으로 fallback
```

## 제약 사항

```yaml
금지:
  - ok를 팀에이전트(Agent)로 spawn (L-214 — 절대 금지)
  - 메인 직접 코드 탐색/수정 (팀에이전트에 위임)
  - 에이전트 수 인위적 축소 / 파일 할당 매트릭스 없이 odev spawn
  - odone 미수행 상태에서 ofinish 실행 — 단, 조기 종료(L-216) 시 경량 모드 허용
  - 팀에이전트 spawn 프롬프트에 배포 명령 직접 하드코딩 (L-110)
  - 완료된 팀에이전트에 shutdown_request 미발송 (L-205: 즉시 발송 필수)
  - 메인에서 pane 소멸 확인/oill PID 수행 (ofinish에 위임)
  - otest 에이전트 spawn 프롬프트에 "사용자 수동 테스트 예정", "배포 스킵", "런타임 스킵" 등 테스트 단계 생략 지시 금지 (L-232: 모든 프로젝트에서 otest가 직접 build→deploy→run→quality 전 단계 수행)
  - UI 파일 변경 포함 시 otestuiwinforms 누락 (L-240: o3/o4=otestuiwinforms 필수, o5=otestuiwinforms+otestui 필수)
  - ok 로딩 후 oplan spawn 전 코드 탐색 (L-248 — serena/Grep/Glob/Read 등 탐색 도구 사용 금지. ok는 분류+spawn만 수행, 코드 탐색은 oplan 역할)
```

파이프라인_동시_실행_경고:
  # [P2-isolation] CLAUDE.md §세션 격리 불변식 §(c) 정보_노출_금지 준수.
  # 타 세션 UUID/STATE를 hook stdout으로 노출하지 않는다.
  # session-env/*/ 루프 탐색 금지. 자기 세션(${UUID})만 독립적으로 진행한다.
  같은_프로젝트_세션_확인·통지: ok/SKILL.md 시작 통지 절차와 ofinish 종료 통지가 담당한다 (공식 ListAgents/SendMessage 경유 — CLAUDE.md 「타 세션 통지 정책」)
  차단_여부: 차단하지 않음 — 통지만 하고 파이프라인은 자기 세션 기준으로 진행한다
```

> 에이전트 무응답 fallback: 비정상 반환 시 재spawn 1회 → 재실패 시 조기 종료(ofinish 경량 모드) + 사용자 보고
