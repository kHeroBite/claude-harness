---
name: otest
description: "2단계 테스트 라우터 — Phase 1(인프라 검증) + Phase 2(구현 검증). 역라우팅 시 대기+diff 재검증."
invocation:
  user_callable: false
  pipeline_callable: true
  called_by: [ok_pipeline(TEST 단계)]
  calls: [otest_infra, otest_verify, otest_evidence]
---

## 절대규칙

```yaml
shutdown_즉답_절대규칙 (L-U5):
  - shutdown_request 수신 즉시 현재 작업 중단 후 shutdown_response 발송
  - 파일 저장/정리 등 후처리 후 응답하는 행위 절대 금지
  - 메인이 3회×5s=15초 내에 응답 없으면 pane 강제 종료 대상
```

## Generator/Evaluator 독립성 원칙 (Anthropic Engineering 권고)

> "Separating the agent doing the work from the agent judging it proves to be a strong lever."
> "Tuning a standalone evaluator to be skeptical turns out to be far more tractable than making a generator critical of its own work."

### otest Evaluator 페르소나 (절대 규칙)

otest는 독립적 평가자로서 다음 페르소나를 유지해야 한다:

**skeptical 검토자 행동 원칙**:
  - 구현이 "작동하는 것처럼 보인다"는 것과 "실제로 올바르게 작동한다"를 구별하라
  - 통과 편향(pass bias) 금지: 불확실한 경우 FAIL로 처리하라
  - odev의 구현 설명/요약/중간 보고를 평가 근거로 사용 금지
  - oplan 계획서 원본 + 실제 코드/로그만 참조하여 독립 평가하라

**참조 범위 제한 (P1 — Generator/Evaluator 독립성)**:
  - ✅ 허용: oplan 계획서 원본 (`plans/oplan_*.md`), 실제 소스 코드, 빌드/실행 로그
  - ❌ 금지: odev 완료 보고 메시지, odev 중간 출력, odev의 "이렇게 구현했습니다" 설명
  - 이유: odev 설명 참조 시 자기평가 편향과 동일한 효과 발생 (Anthropic 실증)

---

## 진입 시 UUID 결정 (필수 — 첫 번째 mcp__oio__bash_exec 명령)
> ⚠️ 모든 셸 명령은 `mcp__oio__bash_exec` 전용. Claude 내장 `Bash` 도구 사용 절대 금지 (write_guard.sh 차단)

```yaml
UUID_결정:
  UUID=$PIPELINE_UUID
  mcp__oio__bash_exec(command='mkdir -p $HOME/.claude/session-env/${UUID}/{logs,evidence,plans}')

팀에이전트_UUID_규칙: PIPELINE_UUID 환경변수 값을 그대로 사용. resolve_uuid() 호출 금지.
예: UUID=$PIPELINE_UUID (환경변수에서 직접 읽기)
```

## 진입 시 handoff/sprint_contract 참조 (N1+N2 — 테스트 전 필수)

```yaml
시점: UUID 결정 직후, Phase 1 시작 전
동작:
  1. sprint_contract.md 읽기:
     mcp__oio__file_read(path="$HOME/.claude/session-env/${UUID}/plans/sprint_contract.md")
     존재하면: 완료 기준을 Phase 2 평가 기준으로 사용
     없으면: oplan §TODO 항목을 대신 사용 (경고 출력)
  2. handoff_dev_to_test.md 읽기:
     mcp__oio__file_read(path="$HOME/.claude/session-env/${UUID}/plans/handoff_dev_to_test.md")
     존재하면: "otest 집중 영역" + "알려진 미완성 항목" 반영하여 테스트 우선순위 결정
     없으면: 스킵 (경고 없음)
금지: sprint_contract/handoff 없다고 테스트를 건너뛰거나 무조건 PASS 처리
```

## 재개 지원 (result.json 프로토콜)

```yaml
재개_지원 (result.json 프로토콜):
  진입_시:
    1. work/ 디렉토리 생성: mcp__oio__bash_exec(command='mkdir -p $HOME/.claude/session-env/${UUID}/work')
    2. ★현재 conv_id 획득 (게이트 판정 기준 — 3번보다 먼저 수행한다):
       mcp__oio__bash_exec(command='cat $HOME/.claude/session-env/${UUID}/conv_id')
       ⚠️ conv_id 파일 자체도 옛 사이클 값이 잔류할 수 있다. 파이프라인이 주입한
          현재 대화ID(프롬프트 명시값)가 있으면 그 값을 우선한다.
    3. 기존 result.json 확인: mcp__oio__file_read(path="$HOME/.claude/session-env/${UUID}/work/otest-1_result.json")
    4. ★conv_id 대조 게이트 (L-670 — Phase 스킵 판정보다 먼저 통과해야 한다):
       저장된 conv_id == 현재 conv_id  → 같은 작업의 중단분이다. 5번 스킵 판정으로 진행한다.
       저장된 conv_id != 현재 conv_id  → ★옛 사이클 잔류물★이다. 파일 내용을 전부 무시하고
                                          전 Phase를 새로 수행한다.
       conv_id 필드 부재 (구 스키마)   → ★잔류물로 간주★한다. 위와 동일하게 전 Phase를 수행한다.
       ⚠️ 무시 판정 시 그 사실을 1줄로 출력한다 — 예: "⚠️ [잔류물 무시] otest-1_result.json
          conv_id={저장값|부재} ≠ 현재 {현재값} — 전 Phase를 새로 수행한다."
       ⚠️ 옛 사이클의 "테스트 통과" 기록을 그대로 믿고 스킵하면 검증 없이 통과 판정이 나간다.
    5. phases_completed 확인 → 완료된 Phase 스킵
       - "phase1_infra" 포함 + evidence/build_ok mtime 유효 → Phase 1 스킵
       - "phase2_verify" 포함 → Phase 2 스킵
       - "phase3_evidence" 포함 → Phase 3 스킵 (이미 완료)
    6. evidence 파일 mtime 재검증: stale evidence 방지

  각_Phase_완료_시:
    원칙: 디스크 먼저, SendMessage 나중 — result.json 저장 완료 후에만 완료 통보
    ★conv_id 필수 필드 — 매 저장마다 현재 대화ID를 반드시 포함한다. 누락하면 다음 사이클이
      이 파일을 자기 것으로 오인해 검증을 통째로 스킵한다 (L-670 재발).
    mcp__oio__file_write(path="$HOME/.claude/session-env/${UUID}/work/otest-1_result.json", overwrite=true, content=JSON)
    Phase1 완료: { "agent":"otest-1", "conv_id":"{현재 대화ID}", "status":"partial", "phases_completed":["phase1_infra"], "phase_details":{"phase1_infra":{...}} }
    Phase2 완료: { ..., "conv_id":"{현재 대화ID}", "phases_completed":["phase1_infra","phase2_verify"], "phase_details":{...} }
    Phase3 완료: { ..., "conv_id":"{현재 대화ID}", "status":"completed", "phases_completed":["phase1_infra","phase2_verify","phase3_evidence"] }
```

# otest — 2단계 테스트 라우터

## 전체 구조

```
Phase 1 (인프라 검증): otest_build + otest_run + otest_log
  → "빌드되고 실행되나?"

Phase 2 (구현 검증): otest_make + otest_ui + otest_log
  → "계획대로 구현됐나?" (acceptance_criteria.json 대조)
```

## tier별 실행 범위

```yaml
o2 (obr alias): Phase 1만 — 빌드+배포+기동 확인
o3~o5:           Phase 1 + Phase 2 전체
```

## 실행 흐름 (3단계 — 순차 필수)

```yaml
otest_3단계_구조:
  1단계: Skill('otest_infra') — Phase 1 인프라 검증
    "빌드되고 실행되나?"
    otest_build → otest_run → otest_log
    FAIL → odev 역라우팅 (otest 대기)
    
  2단계: Skill('otest_verify') — Phase 2 구현 검증
    "계획대로 구현됐나?"
    otest_make + otest_ui + otest_log
    acceptance_criteria.json auto_script 실행
    FAIL → odev/oplan 역라우팅 (otest 대기)
    
  3단계: Skill('otest_evidence') — 최종 검수
    "요구사항이 전부 완료되었는가?"
    계획서/TODO/체크리스트 1:1 대조
    evidence 무결성 검증 + spot check
    FAIL → 역라우팅 (otest 대기)
    PASS → evidence/otest_done 생성 → 완료 보고

3단계 모두 PASS → odone 진입 가능
어느 단계든 FAIL → otest 대기 + 역라우팅 (RETEST 루프)

o2 예외: otest_infra만 실행 (obr 대체), otest_verify/otest_evidence 미실행
```

---

## Phase 1: 인프라 검증 ("빌드되고 실행되나?")

```yaml
Phase_1A_빌드:
  호출: Skill('otest_build')  # obuild 통합 빌드 스킬
  목적: 서버+클라이언트 병렬 빌드
  성공: build_ok 증거 생성
  실패: odev 역라우팅

Phase_1B_배포:
  호출: Skill('otest_run')    # orun 통합 실행/배포 스킬
  목적: 서버 우선 → 헬스체크 → 클라이언트 순차 배포
  성공: deploy_ok + run_ok 증거 생성
  실패: odev 역라우팅

Phase_1C_로그:
  호출: Skill('otest_log')
  목적: 기동 로그 ERROR/WARNING 검증
  성공: log_ok 증거 생성
  이상감지: odev 역라우팅
```

## Phase 2: 구현 검증 ("계획대로 구현됐나?")

```yaml
Phase_2A_Backend:
  호출: Skill('otest_make')
  목적: acceptance_criteria.json category=backend|api|db 항목 검증
  성공: make_ok 증거 생성
  실패:
    실행_오류: odev 권고
    결과_불일치: oplan 권고

Phase_2B_Frontend:
  호출: Skill('otest_ui')
  적용: ui_touched.json.touched 값 우선 (true=실행 / false=SKIP /
        user_override=true는 무조건 실행 / 부재 시 git diff 폴백)
  목적: acceptance_criteria.json category=frontend 항목 검증
  성공: ui_test_done 증거 생성
  실패:
    실행_오류: odev 권고
    결과_불일치: oplan 권고

Phase_2C_종합로그:
  호출: Skill('otest_log')
  목적: Phase 2 전체 실행 후 종합 로그 분석
  이상감지: odev 역라우팅
```

## otest_verify 외부 리뷰 (o4~o5 전용 — otest_verify 판정 전)

```yaml
otest_verify_외부리뷰 (o4~o5 전용):
  시점: otest_verify 판정 전 (Phase 2 완료 후)
  조건: tier가 o4 또는 o5일 때만 실행 (o3 이하 스킵)
  순서:
    1차: Skill('codex:adversarial-review') — 구현의 설계/접근방식 도전적 리뷰
    2차: Skill('codex:review') — 일반 품질/버그 리뷰
  출력: 두 리뷰 결과를 otest_verify 최종 판정에 반영
  목적: 이종 AI(GPT) 관점에서 구현 품질 이중 검증
```

---

## 역라우팅 시 otest 대기 프로토콜

```yaml
otest_FAIL_대기_진입:
  조건: Phase 1 또는 Phase 2 실패 → odev/oplan 역라우팅 발생
  동작:
    1. 종료하지 않고 대기 상태 진입 (idle 전환 금지)
    2. 현재 결과 스냅샷 저장
       경로: $HOME/.claude/session-env/${UUID}/evidence/test_snapshot_v{N}.json
       N = 역라우팅 카운터 현재값
    3. ok_pipeline이 odev/oplan 완료 후 SendMessage("RETEST") 전송 대기

RETEST_수신_프로토콜:
  트리거: ok_pipeline → SendMessage("RETEST")
  동작:
    1. 이전 스냅샷 (test_snapshot_v{N-1}.json) 로드
    2. Phase 1부터 재실행
    3. 신규 결과와 이전 스냅샷 diff 비교
    4. 분류:
       개선: 이전 실패 항목 → PASS 전환
       유지: 동일 실패 패턴 지속 (카운터 누적)
       회귀: 이전 PASS 항목 → FAIL 전환 (긴급)
    5. 회귀 감지 시: AskUserQuestion으로 즉시 사용자 보고 (자동 진행 금지)

스냅샷_누적:
  test_snapshot_v1.json: 1차 FAIL 시
  test_snapshot_v2.json: RETEST 후 FAIL 시
  ...
```

## 역라우팅 에스컬레이션 (RLHF Evidence-Gate — o3+ 전용)

```yaml
적용: o3~o5만 (o2는 obr만)

에스컬레이션_정책:
  1~2회: odev 자동 역라우팅 (구현 버그)
  동일항목_2연속: oplan 에스컬레이션 (설계 재검토)
  3~4회: oplan 역라우팅
  5회~: 사용자 AskUserQuestion (자동 진행 금지)
  10회: 강제 중단 (EARLY_TERM)

Evidence_Gate (odone 진입 전 hook 물리 차단):
  Layer_1 (hook — otest_done_guard.sh):
    - evidence/build_ok: exit_code=0 필드 존재
    - evidence/make_ok: criteria_results 배열 + must 전부 PASS
    - evidence/ui_test_done: UI 변경 시 필수
    - evidence/otest_done: 전체 완료 마커
    - 미충족 시: odone spawn 물리 차단 (exit 2)
  Layer_2 (otest_verify):
    - auto_script 재실행으로 결과 재확인
    - curl_log_path 파일 존재 + expected 대조
    - 미충족 시: 역라우팅 신호

auto_script_프레임워크:
  실행: acceptance_criteria.json의 각 must 항목 auto_script를 Bash로 실행
  sandbox: curl, jq, python3, grep, test 만 허용
  retry: 2회 재시도 후 FAIL 확정 (환경 노이즈 대응)
  결과: exit code 0 = PASS, 그 외 = FAIL (에이전트 주관 배제)
  coverage: must 항목 중 auto_script 보유율 80%+ 필수

Canary_Test:
  목적: 에이전트의 기계적 PASS 처리 감지
  방법: acceptance_criteria에 "expected_result=FAIL"인 항목 1개 포함
  판정: canary가 PASS 반환 → 에이전트가 실제 검증 안 하고 전부 PASS 처리한 것 → 전체 FAIL + 역라우팅

실패_추적 (reroute_history.json):
  저장: $HOME/.claude/session-env/${UUID}/evidence/reroute_history.json
  형식: [{"round":1, "failed":["AC-001","AC-003"], "category":"logic_error", "action":"odev"}]
  동일_판정: 같은 criteria ID + 같은 에러 카테고리 = "동일 항목"
  2연속_동일: oplan 에스컬레이션

evidence_write_path:
  원칙: evidence/ 경로는 otest 서브스킬(otest_build/otest_run/otest_make/otest_ui)만 쓰기 허용
  odev/oplan 에이전트가 evidence/ 직접 생성 시 무효 처리

acceptance_criteria_immutable:
  원칙: oplan 생성 후 acceptance_criteria.json 수정 금지
  보호: oio intent lock으로 잠금
```

---

## 수정 대상 자동 감지

```yaml
단일_프로젝트_수정: 해당 프로젝트만 빌드&배포&테스트
공유_라이브러리_수정:
  범위: 공유 라이브러리 참조하는 모든 프로젝트 (전체 대상)
  Phase_1: 전체 프로젝트 빌드 필수
  Phase_2: 영향받는 모든 프로젝트 검증 필수
    - 빌드 성공 ≠ 런타임 정상 (시그니처 호환이어도 동작 변경 가능)
  공유라이브러리_영향도_판정:
    매핑_위치: PROJECT.md의 dependencies 또는 oinfra_{project}의 library_references
    판정_절차: git diff HEAD → 공유 라이브러리 파일 감지 → 영향받는 프로젝트 목록 결정
복수_프로젝트_수정: 해당 프로젝트들 모두
감지_방법: git diff로 변경 파일 경로 → oinfra_{project} 프로젝트 매핑
```

## Bash 명령어 실행 규칙

> **유일 출처**: 빌드/배포/테스트 시 Bash 실행 규칙은 이 섹션에서만 정의.
> ⚠️ **필수**: 모든 셸 명령은 `mcp__oio__bash_exec` 전용. Claude 내장 `Bash` 도구 사용 시 `write_guard.sh`가 즉시 차단.

```yaml
도구_규칙:
  셸_명령: mcp__oio__bash_exec (유일한 허용 도구)
  파일_읽기: mcp__oio__file_read
  파일_수정: mcp__oio__file_edit / mcp__oio__file_write
  금지: Claude 내장 Bash/Read/Edit/Write 도구 — write_guard.sh 물리 차단

절대_금지: "&&", "||", ";", "|" 연산자 사용한 명령어 체이닝
규칙:
  - 각 명령어를 별도 mcp__oio__bash_exec 호출로 분리
  - 독립 작업은 동일 메시지 내 병렬 호출
  - 순차 작업은 별도 메시지로 분리
  - 1분+ 작업: run_in_background: true

spawn_후_sleep_금지 (L-143/L-I004):
  - 에이전트 spawn(Task 도구) 후 sleep 명령 절대 금지
  - spawn 후 텍스트 출력만 → 턴 종료 → 메시지 자동 배달
  - spawn 후 pane 상태 폴링도 금지 (완료는 SendMessage로 수신)

JSON_파싱 (L-I002):
  - jq 사용 시 반드시 single quote로 필터 감싸기
  - jq 첫 시도 실패 시 즉시 python3 fallback 전환
  - 복잡한 JSON 변환은 처음부터 python3 사용

단일턴_내_병렬_도구_호출_주의 (I-007):
  - 의존 관계가 있는 도구 호출은 반드시 순차 실행
  - 안전한 병렬: Read+Read, Grep+Grep (읽기 전용)
  - 위험한 병렬: Edit+Edit(같은 파일), Bash(hook 차단 가능)+Edit
```

---

## TDD 강제 규칙 (해당 시)

> 상세: [references/TEST_PROCEDURES.md](references/TEST_PROCEDURES.md) — TDD RED/GREEN/REFACTOR 절차, 합리화 차단, 에러 수집/실패 보고

```yaml
적용_조건: 단위 테스트 프레임워크 존재 시 (xUnit, NUnit 등)
Iron_Law: 실패하는 테스트 없이 프로덕션 코드 작성 금지
프로젝트별_예외: xUnit 미사용 프로젝트는 otest_run_{project}의 검증 방법이 TDD 대체
```

## 오류 실시간 기록

```yaml
시점: 빌드/런타임 오류 발생 즉시
대상: $HOME/.claude/session-env/${UUID}/logs/error_{대화ID}.md (대화ID = cat $HOME/.claude/session-env/${UUID}/conv_id)
형식: |
  ## [otest-Phase{1|2}] $(date -Iseconds)
  - 오류: {에러 메시지}
  - 해결: {해결 방법 | 미해결}
```

## 결과 파일 저장

```yaml
시점: 메인에게 완료 통보 직전
파일명: $HOME/.claude/session-env/${UUID}/logs/otest_{대화ID}.md
대화ID 획득: cat $HOME/.claude/session-env/${UUID}/conv_id

포함_내용:
  - Phase 1 결과: 빌드 성공/실패 + 오류 목록 + 기동 확인
  - Phase 2 결과: Backend 검증 (otest_make) + Frontend 검증 (otest_ui) + 종합 로그
  - 스냅샷 비교 기록: diff 결과 (RETEST 수행 시)
```

## 완료 통보 (절대 생략 금지)

```yaml
시점: 결과 파일 저장 직후
방법: SendMessage(to:"{리더명}", message:"otest 완료 — $HOME/.claude/session-env/${UUID}/logs/otest_{대화ID}.md\n{요약 3줄}", summary:"otest 검증 완료")
마지막_줄: "📊 spawn_stats: team=N sub=N task=N"

금지:
  - 결과 파일 없이 완료 통보
  - 완료 통보 없이 idle 전환
```

## 실패 보고 (Phase 실패 시 — 절대 생략 금지)

```yaml
시점: Phase 실패 확정 즉시 (자체 재시도 포함 최종 실패)
방법: SendMessage(to:"{리더명}", message:"otest 실패 — Phase:{1|2}\n원인:{원인 1줄 요약}\n라우팅 권고:{odev|oplan}\n상세:$HOME/.claude/session-env/${UUID}/logs/error_{대화ID}.md", summary:"otest 실패 Phase {N}")

라우팅_권고_기준:
  Phase 1 (인프라) 실패 → odev (빌드/배포 수정 필요)
  Phase 2 (구현) 실패 세분화:
    실행_오류 (크래시, 500 에러, timeout): odev (구현 버그)
    결과_불일치 (기능 누락, 설계 오류): oplan (요구사항 재검토)
    회귀_감지: AskUserQuestion 즉시 (자동 진행 금지)

금지:
  - 실패 보고 없이 자체 재시도 무한 반복
  - 실패 보고 없이 idle 전환
  - 라우팅 권고 누락
```

## Rate Limit Fallback 절차 (L-306)

```yaml
적용_조건: otest 팀에이전트 spawn 시 API rate limit으로 spawn 불가

fallback_절차:
  1. 팀에이전트 spawn 실패 확인 (rate limit 오류 메시지 확인)
  2. 메인이 직접 grep/cat 검증 수행 (otest_log 상당 역할)
     - 빌드 로그: grep -E "error|warning" {빌드_로그_경로}
     - 런타임 로그: grep -E "ERROR|FATAL|Exception" {런타임_로그_경로}
     - 구현 검증: grep -rn "{검증_패턴}" {대상_경로}
  3. 검증 결과를 evidence 파일로 직접 생성
  4. otest_done 생성 후 완료 처리

제약:
  - rate limit fallback은 팀에이전트 spawn 완전 불가 시만 허용
  - 가능하면 팀에이전트 spawn 우선 (fallback은 최후 수단)
  - fallback 사용 시 완료 통보에 "rate limit fallback 적용" 명시

금지:
  - rate limit 여부 미확인 상태에서 fallback 먼저 시도
  - fallback 결과를 정식 otest_verify 결과와 동등하게 취급 (검증 범위 축소 인지)
```

## Python/스크립트 기반 프로젝트 otest 예외 처리 (L-321)

```yaml
적용_조건: Python, 쉘 스크립트, MCP 서버 등 .NET 빌드 파이프라인이 없는 프로젝트

문제:
  - otest_done_guard.sh는 evidence/otest_done 파일 존재를 요구
  - .NET 빌드 파이프라인이 없으면 otest_infra(build/run/log)가 정의되지 않아 증거 생성 불가
  - L-290 교훈으로 기록됐으나 강제화 없어 재발(L-321)

처리_방침 (team-lead 판단 기반):
  방법1_smoke_test (권장):
    - Python: python3 -c "import {모듈명}" 임포트 검증
    - MCP 서버: 프로세스 기동 확인 (ps aux | grep {서버명})
    - tool 호출 smoke test: 핵심 도구 1~2개 직접 호출 + 정상 응답 확인
    - 검증 완료 시 team-lead가 직접 evidence 파일 생성:
        mcp__oio__file_write(path="$HOME/.claude/session-env/${UUID}/evidence/otest_done", content="python-smoke-test: PASS")
    - 이후 정상 odone 진입 가능

  방법2_team-lead_승인 (방법1 불가 시):
    - team-lead가 "Python 프로젝트 otest 생략 승인" 명시
    - 직접 evidence 파일 생성 후 odone 진입

금지:
  - otest 단계 없이 DONE 진입 시도 (otest_done_guard가 차단)
  - smoke test 없이 "Python이므로 otest 해당 없음" 선언 후 진입

기록: L-290(2026-03-29) + L-321(2026-04-08)
```

## 사용자 인터럽트 대응

```yaml
사용자_인터럽트_대응:
  원칙: otest 단계는 완주 우선 — 현재 Phase 완료 후 ok로 에스컬레이션
  A_질문: 직접 답변 (otest 중단하지 않음)
  B_수정요구: 현재 Phase 완료 후 ok로 에스컬레이션 (역라우팅 또는 새 파이프라인)
  C_새작업: otest 완료 후 ok로 에스컬레이션
```

## shutdown_request 수신 시 행동

> shutdown_request 수신 즉시 approve 응답 + 작업 중단. 상세: ok SKILL.md 참조.

---

## 증거파일 생성 책임 매트릭스 (M-03)

| 증거파일 | 생성 주체 | 생성 시점 | 내용 |
|---------|----------|----------|------|
| build_ok | otest_build | 빌드 성공 직후 | 빌드 로그 경로 + 타임스탬프 |
| deploy_ok | otest_run | 배포 성공 직후 | 배포 대상 + 타임스탬프 |
| run_ok | otest_run | 기동 확인 직후 | 헬스체크 결과 |
| log_ok | otest_log | 로그 분석 완료 직후 | ERROR 건수 + 이상 여부 |
| make_ok | otest_make | Backend 검증 통과 직후 | API/DB 검증 결과 요약 |
| ui_test_done | otest_ui | Frontend 검증 완료 직후 | 스크린샷 경로 + 비교 결과 |
| otest_done | otest (메인) | 모든 서브 증거 확인 후 | 전체 테스트 결과 종합 |

```yaml
원칙:
  - 각 서브스킬이 자기 증거를 직접 생성 (메인이 대리 생성 금지)
  - otest 메인은 서브 증거 존재 확인 → otest_done 생성
  - 증거파일 미생성 시 해당 서브스킬 재실행 (메인이 판정)
  - 증거파일 경로: $HOME/.claude/session-env/${PIPELINE_UUID}/evidence/
```

## otest 완료 증거파일 생성 (필수 — L-241)

### ⚠️ 필수: otest 완료 전 evidence 마커 생성 (물리 차단 적용)

SendMessage로 완료 보고 **전에** 반드시 evidence/otest_done 마커를 생성해야 함.
미생성 시 PreToolUse:SendMessage hook(`PreToolUse_SendMessage_otest.sh`)이 물리 차단.

```python
mcp__oio__file_write(
  path="$HOME/.claude/session-env/${PIPELINE_UUID}/evidence/otest_done",
  content="PASS {ISO타임스탬프}",
  overwrite=True
)
```

- 시점: Phase 1 완료 후(o2) 또는 Phase 2 완료 후(o3~o5), 완료 보고(@team-lead SendMessage) 직전
- 목적: otest_done_guard.sh hook이 이 파일(evidence/otest_done)로 otest 수행 여부 검증
- 미생성 시: odone spawn 시 hook에 의해 물리 차단됨 + 완료 SendMessage도 차단됨
- o2_분류: Phase 1만 실행 → Phase 1 완료 후 otest_done 생성 (Phase 2 불필요)

⚠️ otest_done 마커 — 절대 스킵 금지:
  - 검증 PASS 직후(o2: Phase 1 완료, o3~o5: Phase 2 완료) 즉시 생성이 마지막 필수 step
  - 마커 미생성 시: odone spawn이 hook(otest_done_guard.sh 류)에 의해 물리 차단됨
  - 마커 미생성 시: 완료 SendMessage도 PreToolUse_SendMessage_otest.sh hook에 의해 물리 차단됨
  - 어떤 이유로도 스킵 금지 — 마커 생성 실패 시 오류 보고 후 재시도 (PASS 메시지 발송보다 우선)

---

## 외부 의존성 단절 시 PARTIAL_PASS 절차 (L-RTX5070-36 — 2026-05-23)

> GPU 서버 단절, Docker 무응답, 원격 환경 접근 불가 등 외부 의존성 단절 상황에서의 표준 처리 절차.

### 상황 분류

```yaml
테스트_분류:
  로컬_정적: AST 검사, Pydantic schema, import 검증, argparse 구조 — 환경 독립
  로컬_동적: 로컬 unittest/pytest — 로컬 환경만 필요
  원격_환경_의존: Docker build/run, GPU 실물 실행, Playwright UI(원격 서버) — 외부 의존
```

### 옵션 매트릭스 (외부 의존성 단절 발생 시 사용자에게 제시)

```yaml
옵션_A (복구 대기):
  설명: GPU/Docker 복구 대기 후 전체 테스트 실행
  권장: 복구 시간 < 1시간, 사용자 대기 가능
  마커: otest_done 미생성 (복구 후 생성)

옵션_B (정적 검증 + deferred):
  설명: 로컬 정적/동적 테스트 PASS + 원격/환경 의존 항목 deferred 명시
  권장: 복구 시간 불명확, 코드 변경이 원격 환경과 독립적
  마커: otest_done PARTIAL + deferred 항목 기록
  필수: ui_test_done PARTIAL (Playwright 미실행 시)

옵션_C (EARLY_TERM):
  설명: 테스트 불가로 파이프라인 중단
  권장: 원격 환경이 핵심 기능 검증에 필수적이고 대기 불가

옵션_D (절충):
  설명: 옵션 B + Gate 단계에서 사용자 재확인
  권장: 대부분의 실용적 상황 — 정적 PASS 충분 + deferred 후속 처리
```

### PARTIAL_PASS 처리 절차

```yaml
1. 로컬_테스트_완전_실행:
   - 정적 검증 전체 실행 (AST, import, schema)
   - 로컬 unittest/pytest 전체 실행
   - 결과 증거 수집 (logs/otest_phase2.log)

2. deferred_항목_명시_기록:
   파일: $HOME/.claude/session-env/${UUID}/evidence/otest_deferred.md
   내용 예시:
     # otest DEFERRED 항목 (GPU 서버 단절)
     ## 원인: SSH 무응답 / Docker 단절 / ...
     ## Deferred 테스트
     - Phase 1: Docker build + 컨테이너 기동
     - Phase 2 B그룹: sklearn 실물 KMeans 실행
     - Phase 4: Playwright UI
     ## 복구 후 RETEST 필요

3. otest_done 마커 PARTIAL 생성:
   content: "PARTIAL {ISO타임스탬프} deferred={항목수}"
   (PASS 대신 PARTIAL — hook이 odone 진입 허용하되 Gate에서 사용자 확인)

4. ui_test_done 마커 PARTIAL 생성 (UI 미실행 시):
   content: "PARTIAL {ISO타임스탬프} reason=external_dependency_disconnected"

5. 완료_보고_시_PARTIAL_명시:
   SendMessage to team-lead:
     "otest PARTIAL_PASS — 정적 검증 PASS + deferred {N}건 (GPU 단절)"
     deferred 항목 목록 포함
```

### 절대 금지 (안티 패턴)

```yaml
금지_1: 외부 의존성 단절을 "PASS"로 거짓 보고 — 파이프라인 신뢰 붕괴
금지_2: PARTIAL_PASS 상태에서 deferred 항목 미기록 — 후속 사이클에서 망각
금지_3: Gate 없이 자동 commit/push — 사용자가 deferred 사실 모른 채 배포
금지_4: 로컬 테스트도 실행 안 하고 PARTIAL_PASS 선언 — 최소 정적 검증은 필수
```

### otest_done PARTIAL 마커와 Gate

- PARTIAL 마커는 odone 진입을 허용하나 o5 Gate 단계에서 사용자 최종 승인 필수
- Gate 요청 시 deferred 항목 전체 명시 + 옵션 A/B/C/D 재제시
- Gate 후 commit/push 결정은 사용자 권한 (odone_git은 승인 후 실행)
