---
name: otest_make
description: "Backend 구현 검증 — oplan 검수조건(acceptance_criteria.json) 대조. REST API + DB 정합성 + 요청-결과 대조."
invocation:
  user_callable: false
  pipeline_callable: true
  called_by: ["otest(Phase 2)"]
  calls: []
---

# otest_make — Backend 구현 검증

<!-- L-466·L-476·L-477 적용 위치: scripts/verify_crud_executed.py — item_crud 구조화 필드 판정(183행~), crud_대상 부재를 none 으로 분리(1501~1519행), force-include·_assignment_unverifiable 대칭(2897~2998행) -->

## 역할

acceptance_criteria.json의 category=backend|api|db 항목을 검증한다.
REST API + DB 정합성 + 요청-결과 대조 로직을 통합한 Backend 전담 검증 스킬.

## 진입 시 UUID 결정

```bash
UUID=$PIPELINE_UUID
```

## 실행 절차

```yaml
Step_1_criteria_로드:
  파일: $HOME/.claude/session-env/${PIPELINE_UUID}/plans/acceptance_criteria.json
  필터: category in [backend, api, db]
  없을_경우: make_ok_skipped 증거 생성 후 종료 (검증 항목 없음)

Step_2_REST_API_검증:
  방법: curl 기반 자동 감지 + 엔드포인트 순차 테스트
  감지_순서:
    1. acceptance_criteria.json의 api 항목에서 엔드포인트 추출
    2. INFRA.md 또는 PROJECT.md의 API 명세 참조
    3. 감지 실패 시: 소스코드 Grep으로 [HttpGet]/[HttpPost] 등 어노테이션 탐색
  검증_항목:
    - HTTP 응답 코드 (200/201/400/404/500 등)
    - 응답 바디 구조 (JSON 스키마 일치 여부)
    - 필수 필드 존재 여부
  curl_규칙:
    - 각 엔드포인트를 별도 Bash 호출
    - timeout: 10초
    - 인증 필요 시: INFRA.md 의 auth_token 참조

Step_3_DB_정합성_검증:
  적용: acceptance_criteria.json category=db 항목 존재 시
  방법: 상시 연결이 아니므로 mcp-mysql 온디맨드 에이전트(팀원은 name·team_name 없는 일반 서브에이전트)를 띄우고, 그 서브에이전트 안에서 mcp__mysql__query 또는 mcp__mysql__execute 호출 (프롬프트 첫 줄에 호출자=otest)
  검증_항목:
    - 레코드 생성/수정/삭제 반영 여부
    - FK 제약 정합성
    - 트랜잭션 결과 일관성
  한글_쿼리: SET NAMES utf8 먼저 실행

Step_4_요청_결과_대조:
  목적: 요청(입력) → 처리 → 결과(출력) 일치 검증
  방법:
    1. acceptance_criteria.json의 input/expected_output 항목 로드
    2. 실제 API 응답 vs expected_output 비교
    3. DB 상태 vs 기대 DB 상태 비교
  판정:
    일치: PASS
    불일치: FAIL + 상세 diff 기록

Step_4_5_CRUD_실행증거_게이트 (절대 규칙 — make_ok 생성의 선행 조건):
  배경: 사이클30 이 T3 를 "전필드 DB일치 · PASS" 로 판정했으나 저장 경로를 실제로 태우지 않았다.
        삭제 가드(차단)만 확인하고 추가/수정은 "운영 데이터 보호"를 이유로 건너뛴 결과,
        반쪽 저장(정본만 저장되고 부가 축 누락)이 실사용에서 즉시 드러났다.
  원칙: ★차단 확인은 저장 검증이 아니다.★
        차단은 아무것도 일어나지 않는 것을 보는 것이고, 저장은 일어나는 것을 봐야 한다.
        "운영 데이터 보호"는 검증 면제 사유가 아니라 ★개발 DB 를 사용해야 할 사유★ 다.

  실행 (Step_5 판정 직전, make_ok 를 쓰기 전에 반드시 1회):
    mcp__oio__bash_exec:
      command: python3 .claude/skills/otest_make/scripts/verify_crud_executed.py --uuid ${PIPELINE_UUID}

  판정:
    exit 0: make_ok 생성 진행 허용
    exit 1 (MISSING_CRUD_EVIDENCE): ★make_ok 생성 금지★ — CRUD 항목을 PASS 로 마킹하지 않는다.
            스크립트 출력의 누락 항목을 개발 DB 에서 실제로 태운 뒤 재실행한다.
    exit 2 (INPUT_ERROR): 게이트가 돌지 않은 것이므로 통과가 아니다. 입력 경로를 고쳐 재실행한다.

  게이트가 요구하는 증거 (CRUD 항목당 ★둘 다★ 필수):
    ① 테스트 시각 이후의 저장 경로 실행 로그
       (evidence criteria_results 의 write_log / log_evidence 필드 또는 저장 완료 로그 인용)
    ② DB 상태 변화 실측 — 아래 셋 중 ★하나만★ 있으면 인정한다.
       ⒜ 행 집합/값 변화: rowset_before/rowset_after, value_before/value_after, row_diff, pk_diff
       ⒝ 갱신 시각 변화: modified_before / modified_after
       ⒞ COUNT 변화: count_before / count_after (등록·삭제형 검증에 유효)

  🔴 ★COUNT 불변 = 미실행 이 아니다★ (odev-1 지적, 2026-08-24 실측):
     cspms.t_ProjectCategory 저장은 ★전건 DELETE → 전건 재INSERT★ 구조다
     (1002:5693 DELETE / 1002:5705 foreach INSERT).
     같은 선택으로 저장하면 최종 COUNT 가 정확히 동일하다 — 저장은 정상 실행됐는데도 그렇다.
     ⇒ COUNT 단독으로 판정하면 ★정상 저장에 FAIL 이 나는 위양성★ 이 발생한다.
     ⇒ 이런 UPSERT형·전건재작성형 테이블은 ⒜(행 집합 diff) 또는 ⒝(갱신 시각)로 증거를 잡아라.
     ⇒ 같은 함정을 가진 테이블이 더 있을 수 있다 — "기존 삭제 후 재삽입" 패턴이면 전부 동일하다.

  미수행 항목 처리: PASS 로 올리지 않고 ★SKIP 으로 표기★ 한다. 미검증을 통과로 위장하지 않는다.

Step_5_판정:
  선행: Step_4_5 게이트 exit 0 (미통과 시 make_ok 생성 자체가 금지된다)
  must 전부 PASS + should 80%+ → make_ok 생성
  must 1건이라도 FAIL:
    실행_오류 (크래시, timeout, 500): odev 권고
    결과_불일치 (응답 내용 다름, 누락): oplan 권고
```

## goal 체계 사이클 — 게이트 결과 → make_ok / make_partial 연결 (절대 규칙)

```yaml
배경: goal.json + 사이클 게이트 스크립트(goal_autoscript_run.sh 가 auto_script 를 실행) 방식에는
      make_ok 를 만드는 단계가 없었다. otest_done(F-CRUD-1 --final)은 CRUD 항목이 있으면 make_ok 를
      요구하므로 종료 마커가 구조적으로 막혔고, 사람이 PARTIAL 을 손으로 쓰고 게이트를 껐다.
적용: goal.json 이 있고 항목 판정을 게이트 스크립트로 하는 사이클 (acceptance_criteria.json 유무 무관)

실행 (otest 가 Step_4_5 대신 1회):
  mcp__oio__bash_exec:
    command: python3 .claude/skills/otest_make/scripts/verify_crud_executed.py --uuid ${PIPELINE_UUID} --emit-from-goal --before-stage odone
    # --before-stage odone 는 판정 시점을 odone 진입 전으로 고정하기 위해 명시한다.
    # 선택: --gate-timeout N(항목당 초, 기본 180) / --gate-cmd "<대체 실행부>"
  ⚠️ bash_exec 는 dash 다 — 위 명령은 python3 단일 호출이라 그대로 쓴다.

rc 해석 (FAIL 을 PASS 로 바꾸는 경로는 없다):
  0 → evidence/make_ok 확정. 조건: 게이트 rc=0 + 판정 행 전부 PASS + ★그 make_ok 후보가 CRUD 실행증거
      검사를 다시 통과★(item_crud:true 항목의 evidence 파일에 write_log + 상태변화 증거).
      잔존 make_partial 은 make_partial.superseded_<epoch> 로 보존 개명.
  1 → evidence/make_partial 기록(make_ok 는 쓰지 않음, 기존 make_ok 은 make_ok.superseded_<epoch> 로 보존 개명).
      FAIL/UNDET/NOSCRIPT/ALLBLOCKED/DEFERRED 가 있거나, 게이트는 PASS 인데 CRUD 증거가 없는 경우
      (MAKE_OK_REFUSED_CRUD — 그 CRUD 항목은 CRUD_EVIDENCE_MISSING 으로 미통과에 들어간다).
      ★실업무 행 스냅샷 선행(사이클172 C26, L-1200)★: PASS+CRUD 증거가 있는 item_crud:true 항목은
      snapshot_*.json(증거 "snapshot" 필드 또는 파일명 _ID_/"item":ID, rows=list)의 mtime 이 첫 쓰기 시각
      (증거 write_ts·first_write_ts·gw_log_ts 최소)보다 앞서야 한다. 미충족 → SNAPSHOT_MISSING/INVALID/
      WRITE_TS_MISSING/SNAPSHOT_AFTER_WRITE 로 미통과. [cNNNtest] 신규 행만 다루면 증거에 "live_rows": false 명시(표식 문구만으로는 면제 안 됨).
      수기 make_ok(main/--final 경로)에도 같은 검사가 적용된다(MISSING_SNAPSHOT_EVIDENCE → rc=1).
  3 → 판정 행 0건(게이트가 돌지 않음). 아무것도 쓰지 않는다 — 판정불가는 통과도 PARTIAL 도 아니다.

make_partial 이후 otest_done:
  - --final 은 make_ok 부재 + make_partial(result=PARTIAL, not_passed 1건 이상)일 때만 PARTIAL_ACKNOWLEDGED.
  - 미통과로 기록된 CRUD 항목만 "PARTIAL 로 기록됨"으로 인정한다. passed 로 적힌 CRUD 항목은 여전히
    write_log+상태변화 증거가 필요하고, make_partial 에 아예 없는 CRUD 항목은 거부한다(기록 누락).
  - otest_done 내용은 ★"PARTIAL" 로 시작★ 하고 미통과 id 를 나열한다. PASS 로 쓰지 마라.

AC 작성 규칙 (조회·정적 검증 항목 오분류 방지):
  - 검증형 항목은 item_crud:false + ★verify_kind:"inspection"★ 을 명시한다. 이 필드가 자연어 어휘
    판정(INSPECTION_HINTS)보다 우선한다 — 어휘 확장은 금지다.
  - verify_kind 선언도 경로 재대조를 받는다. CRUD 의심 파일이 바뀌었는데 AC 에 item_crud:true 항목이
    하나도 없으면 무효화된다(그 파일의 저장 증거를 질 항목이 없기 때문). item_crud:true 항목이 있으면
    그 항목들이 저장 증거를 지고 inspection 항목은 INSPECTION_KIND_PATH_COVERED 로 면제된다.
  - item_crud:true 와 verify_kind:"inspection" 을 함께 쓰면 CRUD 쪽이 이긴다.

file_assignment.json 판독 (다중 스키마 합집합):
  agents.<에이전트>.files / 최상위 <에이전트>.files / phases[]·batches[] 의 files·file_assignment·agents /
  file_assignment 한 겹 / 평면 files. 모르는 형식은 0개 → 종전대로 fail-closed.

회귀 테스트: python3 .claude/skills/otest_make/scripts/test_verify_crud_executed.py (rc=0 이어야 한다)
```

## 실패 판정 세분화

```yaml
odev_권고_조건:
  - REST API 500 에러 (서버 오류)
  - curl timeout (서버 미응답)
  - DB 연결 실패
  - 런타임 크래시

oplan_권고_조건:
  - API 응답 형식 불일치 (스키마 오류)
  - 필수 필드 누락
  - DB 레코드 내용 불일치
  - 요구사항 기능 미구현
```

## 증거파일 생성

```yaml
# 성공 시
mcp__oio__file_write:
  path: $HOME/.claude/session-env/${PIPELINE_UUID}/evidence/make_ok
  content: "PASS $(date -Iseconds)"
  overwrite: true
# 건너뜀 시 (항목 없음)
mcp__oio__file_write:
  path: $HOME/.claude/session-env/${PIPELINE_UUID}/evidence/make_ok_skipped
  content: "SKIPPED $(date -Iseconds)"
  overwrite: true
```

## auto_script 기반 검증 (에이전트 주관 배제)

```yaml
auto_script_실행_절차:
  1. acceptance_criteria.json 로드
  2. category=backend|api|db 항목 필터
  3. 각 must 항목의 auto_script 실행:
     - ★공용 CLI 로 실행 (bash_exec 는 dash — 직접 실행하면 $'\r' 등 bash 문법이 오판된다):
       bash "${HARNESS_HOME:-$HOME/.harness}/current/hooks/lib/goal_autoscript_run.sh" --criteria <acceptance_criteria.json> --timeout 600 [--id <ID>]
       출력 행 ID<TAB>PASS|FAIL|UNDET|NOSCRIPT<TAB>상세, rc 0=전부 PASS / 1=FAIL / 3=UNDET·NOSCRIPT·비정상(rc≠0 은 전부 미통과)
     - sandbox 환경: curl/jq/python3/grep/test만 허용
     - retry: 최대 2회 재시도 (1회 실패 시 3초 대기 후 재시도)
     - exit code 0 = PASS, 그 외 = FAIL
  4. should 항목: 동일 절차, 80%+ PASS 필수
  5. canary 항목: expected_result=FAIL 확인 → PASS 반환 시 전체 무효

evidence_make_ok_내용_필수:
  criteria_results: [{id, status, actual_output, auto_script_exit_code}]
  criteria_results_CRUD항목_추가필수 (Step_4_5 게이트 통과 조건):
    write_log: 저장 경로 실행 로그 인용 (테스트 시각 이후 — 예 "[PMS] 카테고리 저장 완료") — 필수
    + 아래 상태변화 증거 중 ★하나★ (테이블 성격에 맞는 것을 고른다):
      · count_before / count_after   — 등록·삭제형 (행수가 실제로 바뀌는 경우)
      · rowset_before / rowset_after — 전건 재작성형 (COUNT 불변이어도 집합이 바뀜)
      · value_before / value_after   — UPDATE 형 (특정 컬럼 값 변화)
      · modified_before / modified_after — 갱신 시각 컬럼 변화
    ⚠️ write_log + 상태변화 증거가 모두 없으면 verify_crud_executed.py 가 exit 1 로 PASS 마킹을 거부한다.
    ⚠️ 축 선택을 자의적으로 하지 마라 — 검수 항목에 어느 테이블의 무엇을 관측할지 미리 못박고,
       그 근거(테이블이 등록형인지 전건재작성형인지)를 evidence 에 함께 기재한다.
  curl_log_path: 실제 curl 출력 로그 파일 경로
  timestamp: $(date -Iseconds)
  canary_result: FAIL (정상) | PASS (비정상 → 전체 무효)
```

## 단일 판정기 ac_gate.py — 시험 기록(ac_records) 계약 (사이클196 판정장치 RCA)

```yaml
원칙: 판정기를 사이클마다 세션 디렉터리에 복사(cNNN_gate.py)하지 않는다. scripts/ac_gate.py 하나를 쓰고, 사이클 고유값은
      기준표 최상위 record_contract(root·status_enum·build_sources·records_after·orphan_scan·evidence_bases)에만 둔다.
계획(oplan): record_contract 를 기준표에 넣고, goal.json auto_script 는
      python3 <skills>/otest_make/scripts/ac_gate.py --session "${GOAL_SESSION_DIR:-<세션>}" item <AC-ID> 로 쓴다.
      (record_contract 가 있는 세션에서 세션 사본 판정기를 가리키는 goal.json 은 PreToolUse_ac_records_guard 가 막는다)
리드(spawn): otest 프롬프트에 `ac_gate.py --session <세션> contract` 출력을 그대로 붙인다(위치는 절대경로로 나온다).
시험 담당(otest):
  - 기록 위치·형식은 contract 출력대로. status 는 어휘 안에서만(조건부·괄호 표기 금지). 근거 있는 N/A 는 NA + na_basis.
  - build 는 `ac_gate.py --session <세션> stamp` 출력(산출물 md5 — 손으로 쓰는 current_build.json 은 쓰지 않는다).
  - 쓰기 직후 `ac_gate.py --session <세션> validate-record <경로>` rc 0 확인. 위반 기록은 쓰는 순간 hook 이 막는다.
판정: 규약 밖 위치·이름의 기록이 그 AC 를 담고 있으면 "기록 없음" 이 아니라 판정불가(rc 3) + 경로로 나온다 — 옮기면 된다.
```

## 결과 보고 형식

```yaml
보고_시점: Step 5 판정 직후
전달_대상: otest 메인 (호출자)
형식:
  PASS: "make_ok — must:{N}건 PASS / should:{N}건 PASS({비율}%)"
  FAIL: "make_FAIL — 실패:{N}건\n{항목명}: {expected} → {actual}\n권고:{odev|oplan}"
  SKIP: "make_skipped — acceptance_criteria.json에 backend/api/db 항목 없음"
```

## Bash 규칙

> ⚠️ **필수**: 모든 셸 명령은 `mcp__oio__bash_exec` 전용. Claude 내장 `Bash` 도구 사용 절대 금지 (write_guard.sh 차단)

```yaml
도구: mcp__oio__bash_exec (유일한 허용 도구 — Claude 내장 Bash 금지)
절대_금지: "&&", "||", ";", "|" 연산자 사용한 명령어 체이닝
각_명령어: 별도 mcp__oio__bash_exec 호출로 분리
timeout_작업: run_in_background: true
```
