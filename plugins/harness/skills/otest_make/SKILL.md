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
    2. oinfra_{project} 또는 PROJECT.md의 API 명세 참조
    3. 감지 실패 시: 소스코드 Grep으로 [HttpGet]/[HttpPost] 등 어노테이션 탐색
  검증_항목:
    - HTTP 응답 코드 (200/201/400/404/500 등)
    - 응답 바디 구조 (JSON 스키마 일치 여부)
    - 필수 필드 존재 여부
  curl_규칙:
    - 각 엔드포인트를 별도 Bash 호출
    - timeout: 10초
    - 인증 필요 시: oinfra_{project}의 auth_token 참조

Step_3_DB_정합성_검증:
  적용: acceptance_criteria.json category=db 항목 존재 시
  방법: mcp__mysql__query 또는 mcp__mysql__execute 직접 호출
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
     일부 테이블의 저장은 ★전건 DELETE → 전건 재INSERT★ 구조일 수 있다
     (저장 루틴에서 DELETE 후 foreach INSERT 하는 패턴).
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
