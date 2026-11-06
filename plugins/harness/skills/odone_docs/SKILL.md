---
name: odone_docs
description: "프로젝트 문서 업데이트. 교훈 기록(LESSONS/MEMORY) + HISTORY/PROJECT/DATABASE/CLAUDE 점검."
invocation:
  user_callable: false
  pipeline_callable: true
  called_by: [odone]
  calls: []
---
# odone_docs — 프로젝트 문서 업데이트 + 교훈 기록

## 입력: $HOME/.claude/session-env/${UUID}/logs/review_actions.json

```yaml
소비_대상: actions 배열의 **모든 항목** (target 무관)
역할:
  1. 교훈_기록: 모든 교훈을 LESSONS.md에 기록 (target이 hook/skill이어도)
  2. Level_2_메모리: level == 2 항목은 MEMORY.md에도 기록
  3. 반영_추적: Level 3 항목은 LESSONS.md 반영 추적 테이블에 기록
  4. 프로젝트_문서: 기존 HISTORY/PROJECT/DATABASE/CLAUDE.md 업데이트

절차:
  1. $HOME/.claude/session-env/${UUID}/logs/review_actions.json 읽기
  2. 교훈 기록 (아래 "교훈 기록 절차" 참조)
  3. 프로젝트 문서 업데이트 (아래 "필수 점검 대상" 참조)
```

## 에러 기반 재발방지 (review JSON의 error_log 활용)

```yaml
입력: $HOME/.claude/session-env/${UUID}/logs/review_actions.json의 error_log 필드
목적: 세션 중 발생한 hook 차단/도구 오류에서 재발 패턴을 발견하고 교훈화

절차:
  1. error_log.errors 배열 확인
  2. 각 에러의 category별 재발 패턴 분석:
     - HOOK_BLOCK_* → 모델이 규칙을 위반한 패턴 → Level 2+ 교훈
     - PIPELINE_BLOCK_* → 파이프라인 순서 위반 → Level 1 교훈 (이미 hook이 차단)
     - BUILD_FAILED → 코드 오류 → Level 1 (빌드 오류는 수정으로 해결)
     - FILE_NOT_FOUND → 경로/파일 실수 → Level 1~2
  3. 해결됨 에러: "오류→해결" 쌍을 교훈으로 기록 (재발방지)
  4. 미해결 에러: 심각도 높음 → Level 2+ 필수, odone_hooks/skills에서 추가 조치
  5. 동일 category 2회+ 반복: 자동 Level 3 승격 (hook/skill 강화 대상)

교훈_기록_형식:
  LESSONS.md: "### L-NNN: [category 요약] — [재발방지 방법] (날짜)"
  MEMORY.md: Level 2+ 항목만 (매 세션 시작 시 자동 인지)

error_md_연동 (error md → LESSONS.md 변환):
  목적: error md의 미해결 ERR-N 중 반복 패턴(2회+)을 LESSONS.md 교훈 항목으로 변환
  절차:
    1. error md($HOME/.claude/session-env/${UUID}/logs/errors.md)의 전체 ERR-N 항목 스캔
    2. 동일 category 또는 동일 root_cause가 2회+ 반복된 ERR-N 추출
    3. 반복 패턴별 교훈 항목 생성: "### L-NNN: [ERR category] — [재발방지 방법] (날짜)"
    4. 원본 ERR-N 번호를 교훈 항목에 참조 기록 (예: "원본: ERR-3, ERR-7")
    5. 1회성 ERR-N은 변환하지 않음 (error md에만 잔류)
```

## 교훈 기록 절차

```yaml
모든_항목 → LESSONS.md:
  - actions 배열의 모든 항목을 LESSONS.md에 추가
  - error_log의 에러 기반 교훈도 함께 기록
  - 형식: "### L-NNN: [what] (날짜)"
  - lessons_entry 필드 참조

Level_2_항목 → MEMORY.md 추가:
  - level == 2 항목은 MEMORY.md 해당 섹션에 주의사항 추가
  - 효과: 매 세션 시작 시 자동 인지

MEMORY.md_점검_필수 (매 odone마다 — 사용자 요청):
  목적: 이번 세션의 교훈 중 다른 세션에서도 참조해야 할 항목을 MEMORY.md에 반영
  절차:
    1. LESSONS.md에 기록된 이번 세션 교훈 전체 검토
    2. 아래 기준으로 MEMORY.md 반영 여부 판단:
       반영_대상: 중요하거나 빈번하게 재현되는 패턴 (Level 2+)
         - 모델이 반복적으로 저지르는 실수 패턴
         - 프로젝트 고유 제약 (아키텍처, 외부 시스템 특성 등)
         - 한 번 위반하면 복구 어려운 규칙
       제외_대상: hook/스킬에서 물리 차단으로 처리된 항목 (이미 강제됨)
    3. 반영 대상 있으면: MEMORY.md 해당 섹션에 추가 또는 기존 섹션 보강
    4. 반영 대상 없으면: "MEMORY.md 반영 없음 — 이번 세션 교훈은 hook/스킬 처리 완료 또는 1회성 실수" 1줄 기록
  금지: 점검 단계 생략 (단순 작업, 교훈 없음 등 어떤 이유도 예외 없음)

Level_3_항목 → 반영 추적 테이블:
  - LESSONS.md 하단 반영 추적 테이블에 기록
  - 테이블_형식:
    | 교훈 ID | 교훈 요약 | 반영 대상 | 반영 위치 | 반영일 | 검증 |
    |---------|-----------|-----------|-----------|--------|------|
  - target == "hook"이면 odone_hooks에서 이미 반영됨 → 검증 ✅
  - target == "skill"이면 odone_skills에서 이미 반영됨 → 검증 ✅

pending_items 처리:
  - review가 발견한 이전 미반영 항목
  - odone_hooks/odone_skills에서 이미 반영되었으면 → ✅로 변경
  - 아직 미반영이면 → 이번 세션의 actions에 추가되어 처리됨
```

## Step 0.5: diff 기반 문서 동기화 예비 분류

```yaml
절차:
  1. git diff HEAD~1..HEAD --name-only로 변경 파일 목록 확인
  2. 변경 분류:
     신규_기능: 새 파일, 새 클래스/메서드 추가
     변경_동작: 기존 파일 로직 수정
     제거_기능: 파일 삭제, 메서드 제거
     인프라: 빌드 설정, 테스트 인프라

  3. 자동_업데이트 (즉시 수행 — 사용자 확인 불필요):
     - 파일 경로/카운트 수정
     - 테이블/목록에 항목 추가
     - 버전 숫자 업데이트
     - 오래된 상호참조 수정

  4. 메인_판단_위임 (리포트 후 진행 — 직접 수정 금지):
     - 철학/설계 근거 변경 서술
     - 보안 모델 변경 서술
     - 한 섹션 10줄+ 대규모 재작성

  5. 변경_요약_출력:
     각 수정 문서별 "파일명: [구체적으로 변경한 내용]"
     예: "PROJECT.md: 신규 파일 3개 추가, 파일 수 카운트 갱신"

  6. 문서_쓰기_도구:
     - 문서(HISTORY.md·LESSONS.md 등) 갱신은 mcp__oio__file_edit 로 한다.
     - 본문에 승격 경로 구성요소 이름이 든 python3 인라인·sed -i 셸 쓰기는 F-GUARD-PROMOTE 가 설계상 막는다(쓰기 대상을 정적으로 확정할 수 없다).
     - 셸이 꼭 필요하면 heredoc·printf 리다이렉트 꼴은 통과한다.

절대_금지:
  - HISTORY.md를 Write 도구로 덮어쓰기 (Edit 전용)
  - 문서 섹션 전체 제거
  - diff와 무관한 내용 수정
```

## 필수 점검 대상 (매 작업마다)

> **원칙**: 작업 이력을 바탕으로 변경/수정/구조 변경 내용을 해당 문서에 반드시 반영.
> 조건이 불명확하면 **반영하는 방향으로 판단** (생략 금지).

```yaml
HISTORY.md:
  조건: 항상 (매 작업, 예외 없음)
  내용: 날짜, 작업 내용, 변경 파일, 커밋 해시

PROJECT.md:
  조건: 아래 중 하나라도 해당하면 필수 반영
    - 파일 추가/삭제
    - 파일 역할/책임 변경
    - 아키텍처/구조 변경 (클래스, 네임스페이스, 의존 관계)
    - 새 기능/모듈 추가
    - 기존 기능 수정/제거
  내용: 파일 인벤토리 + 변경된 구조/역할 반영

DATABASE.md:
  조건: 아래 중 하나라도 해당하면 필수 반영
    - 테이블/컬럼 추가/삭제/변경
    - 인덱스/FK 변경
    - 쿼리 로직/집계 방식 변경
    - 새 데이터 흐름 추가
  내용: 스키마 + 쿼리 변경 내역 반영

ADVANCED.md:
  조건: 아래 중 하나라도 해당하면 필수 반영
    - UI/폼/컨트롤 추가/변경/제거
    - 메뉴/권한/MDI 구조 변경
    - 새 UI 패턴 또는 WinForms 규칙 도입
    - 레이아웃/디자인 규칙 변경
  내용: 화면 구성, 패턴, 규칙 변경 내역 반영

INFRA.md:
  조건: 아래 중 하나라도 해당하면 필수 반영
    - 서버·포트·접속 정보 변경
    - 빌드/배포/기동/중지 명령 변경
    - 계정 변경
    - 테스트 역량 변경 (INFRA-FIELDS 헤더 ui_test 등 포함 — 헤더 형식은 바꾸지 않는다)
  내용: 해당 절 갱신
  주의: 커밋 금지 파일이다. `git -C <git 루트> check-ignore -q INFRA.md` rc=0 을 확인한다 (git 저장소일 때).

.claude/rules/docs-map.md:
  조건: md 추가·이동·보관 시 필수 반영
  내용: 현행 문서 / 보관 문서 표에 경로·역할·읽을 시점 등재 (수명 끝난 md 는 삭제하지 않고 docs/archive/ 로 이동 후 보관 표 등재)

CLAUDE.md:
  조건: 프로세스/규칙/정책 변경 시
  내용: 해당 섹션 업데이트
```

### 정본(plan/) 반영 — Skill('ocanon') 규칙

정본 체계의 정의·카탈로그·`## 정본 참조` 절 규격은 ocanon 스킬이 정본이다. 이 단계는 마무리 반영만 한다.

```yaml
적용_범위:
  O1: 수행하지 않는다.
  O2: 이번 사이클에 확정된 결정이 있을 때만 ADR 1건을 남긴다. plan root 가 없으면 생략한다.
  O3~O5: 아래 절차 전부를 수행한다.
plan_root: <루트>/.claude/docs_gate.json 의 canon.plan_root > 기본값 plan

절차 (O3~O5):
  1. plan_root 부재 시 주문형 초기화:
     - python3 -B ${HARNESS_HOME:-$HOME/.harness}/current/scripts/plan_init.py --project <git 루트> 로 dry-run 결과와 제안 프로파일을 확인한다.
     - 이어서 같은 명령에 --profile <제안값 또는 지정값> --apply 를 붙여 생성한다(멱등, 기존 파일 덮어쓰기 없음).
     - 생성된 파일과 docs-map 행은 이번 사이클 커밋에 포함한다.
  2. 반영 예정 대조:
     - 이번 사이클 계획서(plans/oplan_*.md) `## 정본 참조` 절의 `반영 예정` 항목을 읽는다.
     - 적힌 문서마다 실제 갱신 여부를 확인하고, 빠진 것은 지금 갱신한다.
     - `해당 없음(사유)` 이면 정상 경로다. 문서를 새로 만들지 않는다.
  3. 갱신 대상 (반영 예정·이번 사이클 사실이 있을 때만):
     - 결정: 확정 결정은 `decisions`(ADR)에 새 번호로 추가한다. 결정이 바뀌면 옛 ADR 을 고치지 않고 새 ADR 을 쓴 뒤 옛 상태를 "대체됨→ADR-x" 로 바꾼다.
     - 미결: `pending` 항목의 상태를 갱신한다(해소되면 해소일과 ADR 번호).
     - 과제: 미뤄진 일과 감사 경고 정리 항목은 `todo` 에 올린다.
     - 진척: 활성 문서면 `wbs` 의 이번 사이클 WBS-ID 상태·진척률, `schedule` 마일스톤 실제일, `requirements`·`features` 상태를 갱신한다.
     - 색인: 문서를 추가·이동·보관했으면 `index.json` documents·archived 와 README 폴더 지도를 갱신한다. 수명이 끝난 문서는 `98_보관/` 로 옮긴다(삭제 금지).
     - 변경이력은 plan 에 두지 않는다. 루트 HISTORY.md 가 정본이다.
  4. 감사:
     - python3 -B ${HARNESS_HOME:-$HOME/.harness}/current/scripts/plan_audit.py --project <git 루트> 를 실행한다.
     - rc=0 이어야 한다. rc=1(오류)이면 원인을 고치고 다시 돌린다. rc=2 는 plan root·index.json 부재이므로 1단계를 다시 확인한다.
     - 경고(판 사본·고아·생성물·대체됨 미정리·이유 칸 공란)는 이번에 고치거나 `todo` 에 정리 항목으로 올린다.
금지:
  - 반영 예정이 `해당 없음` 인데 형식만 맞추려고 문서를 새로 만드는 것
  - 같은 주제의 판 사본(_v2·_old 등) 생성
  - plan 문서에 자격증명·서버 주소·포트·계정 기록(INFRA.md 참조로만)
```

### 문서 갱신 게이트 (PreToolUse_docs_update_gate.sh)

위 점검 중 HISTORY·DATABASE·PROJECT 3종은 hook 이 다시 확인한다. 이 스킬에서 빠뜨리면 ofinish 가 멈춘다.

```yaml
판정_시점:
  O3~O5: ofinish Step 0.5 의 FINISH 진입(session_state state=FINISH) 호출
  O1/O2: ofinish Step 8 의 FINISH→IDLE 호출 (Step 7.5 의 HISTORY 1줄 기록 이후)
  대상: 메인 호출만 검사한다. 팀에이전트·서브에이전트 호출은 통과한다.
변경_집합: 이번 사이클 기준 커밋(rollback_hash, 없으면 사이클 시작 시각) 대비 git diff + 사이클 중 생긴 미추적 파일 (cwd 의 git 저장소만)
판정 (해당 문서가 프로젝트 루트에 있을 때만):
  HISTORY.md:  코드 파일 변경 ≥1 인데 HISTORY.md 미변경 → block
  DATABASE.md: 스키마 파일(*.sql·migrations 등) 변경 ≥1 인데 DATABASE.md 미변경 → warn
  PROJECT.md:  파일 추가·삭제·이름변경 ≥1 인데 PROJECT.md 미변경 → warn
  문서만·무시 대상만 변경, 또는 판정 불가(git 실패 등) → 통과(판정 불가는 경고와 로그를 남긴다)
분류_규칙: 범용 기본값은 hook 코어에 있고, 프로젝트별 추가 규칙은 `<프로젝트>/.claude/docs_gate.json` 에 둔다.
의도적_생략 (사유 파일):
  경로: $HOME/.claude/session-env/${UUID}/docs_update_waiver
  형식: 줄마다 "HISTORY: 사유" / "DATABASE: 사유" / "PROJECT: 사유" (키 대소문자 무시, 사유 10자 이상 — 미달 줄은 무효)
  신선도: 이번 사이클 시작 이후에 쓴 파일만 인정한다. 이전 사이클 사유는 재사용되지 않는다.
  기록: 인정된 항목은 logs/docs_gate.log 에 "WAIVED <키> <사유>" 로 남고 ofinish 보고에 노출된다.
  원칙: 갱신이 맞으면 갱신한다. 사유 파일은 문서 갱신이 실제로 불필요할 때만 쓴다.
차단_시_복구:
  - state 는 DONE(O1/O2 는 FINISH)으로 남는다. 상태를 강제로 바꾸지 않는다.
  - 1순위: 이 스킬(odone_docs)을 다시 실행해 누락 문서를 갱신하고 커밋한 뒤 같은 session_state 호출을 재시도한다.
  - 2순위: 생략이 정당하면 사유 파일을 쓴 뒤 재시도한다.
  - 표현을 바꾸거나 다른 도구로 상태를 쓰는 우회는 금지한다(L-597).
```

## 점검 체크리스트

```yaml
- [ ] 에러: review JSON의 error_log 에러 기반 재발방지 교훈 기록됨
- [ ] 교훈: review JSON의 모든 actions → LESSONS.md 기록됨
- [ ] 교훈: Level 2 항목 → MEMORY.md 기록됨
- [ ] 교훈: Level 3 항목 → 반영 추적 테이블 기록됨
- [ ] **MEMORY.md 점검 수행됨** (반영 또는 "반영 없음" 판정 중 하나 — 생략 절대 금지)
- [ ] HISTORY.md에 작업 이력 추가됨 (필수, 매번 — 코드 변경 시 누락하면 문서 갱신 게이트가 FINISH 진입을 block)
- [ ] PROJECT.md — 파일/구조/역할 변경이 있었으면 업데이트됨 (파일 추가·삭제·이름변경 시 누락하면 게이트 warn)
- [ ] DATABASE.md — DB/쿼리 변경이 있었으면 업데이트됨 (스키마 파일 변경 시 누락하면 게이트 warn)
- [ ] 의도적으로 생략한 문서가 있으면 `docs_update_waiver` 에 "키: 사유(10자+)" 를 기록함
- [ ] ADVANCED.md — UI/폼/메뉴/권한/패턴 변경이 있었으면 업데이트됨
- [ ] 프로세스/규칙 변경이 있었으면 CLAUDE.md 업데이트됨
- [ ] INFRA.md — 서버·포트·빌드/배포 명령·계정·테스트 역량 변경이 있었으면 반영됨 (커밋 금지 확인)
- [ ] docs-map.md — md 추가·이동·보관이 있었으면 반영됨
- [ ] (O3~O5) 정본 반영 — plan root 부재 시 `plan_init.py` 로 생성, `반영 예정` 대조·ADR·색인·WBS·일정 갱신, `plan_audit.py --project <git 루트>` rc=0
- [ ] `python3 -B ${HARNESS_HOME:-$HOME/.harness}/current/scripts/md_audit.py --project <git 루트>` rc=0 (고아·깨진 참조 0)
- [ ] settings.json에 등록된 hook 파일이 실제로 모두 존재하는지 확인 (L-052)
```

## 병렬 업데이트 (대규모 시)

```yaml
Case_A_단순 (1-2개 문서):
  Sonnet 메인 직접 수정

Case_B_대규모 (3개+ 문서):
  Task(general-purpose, model: sonnet) #1: PROJECT.md + HISTORY.md + ADVANCED.md
  Task(general-purpose, model: sonnet) #2: DATABASE.md + CLAUDE.md + LESSONS.md + MEMORY.md
  (v3.2 flat team — TeamCreate 금지, Task 서브에이전트만 사용)
```

## 즉시 반영 원칙 (절대 규칙 — L-051/L-042)

> **교훈은 기록이 목적이 아니다 — 즉각적인 재발방지가 목적이다.**

```yaml
원칙: 교훈 발견 → 이번 odone에서 즉시 해당 스킬/hook/코드에 반영
금지: "LESSONS.md에 기록했으니 완료" 판단

즉시_반영_절차:
  1. 교훈 식별 (review JSON 또는 error_log)
  2. Level 판정:
     Level_1: LESSONS.md 기록만 (단순 1회 실수)
     Level_2: LESSONS.md + MEMORY.md (패턴 반복 위험)
     Level_3: LESSONS.md + CLAUDE.md/스킬/hook 즉시 수정 (이번 odone에서 처리)
  3. Level 3 발견 시:
     - target == "skill" → odone_skills에 즉시 위임하여 이번 odone에서 처리
     - target == "hook" → odone_hooks에 즉시 위임하여 이번 odone에서 처리
     - 미반영이면 odone 완료로 처리하지 않음

판정_기준 (심각도 자동 상향):
  - 이번 세션에서 2회 이상 같은 유형 오류 → 자동 Level 3
  - 사용자가 지적한 오류 → 자동 Level 3
  - 이전 LESSONS.md 또는 LESSONS_ARCHIVE.md에 같은 교훈이 이미 있음(두 파일을 키워드·L-번호로 grep 하여 히트 줄만 확인, 전체 Read 금지) → 자동 Level 3 (재발)
  - hook이 차단한 오류(HOOK_BLOCK_*) → 자동 Level 2+ (모델이 규칙 위반)
  - 미존재 파일/누락 파일로 인한 hook 오류 → 자동 Level 3 (즉시 파일 생성/제거)

o1_작업_적용:
  - o1/o2 작업도 동일 원칙 적용 (L-042 재확인)
  - 오류 발생 시 error md 저장 후 교훈 즉시 반영
  - "Fast Path = 교훈 생략" 해석 절대 금지
```

## 절대 금지

- HISTORY.md 이력 추가 없이 마무리 완료
- 파일/구조 변경 후 PROJECT.md 미반영
- DB/쿼리 변경 후 DATABASE.md 미반영
- UI/폼/패턴 변경 후 ADVANCED.md 미반영
- review JSON의 교훈을 LESSONS.md에 기록하지 않고 넘어감
- "변경이 작아서 문서 생략" 판단 — 작업 이력 기반 반영은 규모 무관 필수
- **Level 3 교훈을 LESSONS.md에만 기록하고 스킬/hook 반영 없이 odone 완료 선언**
- **"다음에 반영"으로 미루기 — 즉시 반영이 원칙**
