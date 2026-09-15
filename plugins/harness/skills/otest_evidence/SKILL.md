---
name: otest_evidence
description: "최종 검수 — oplan 계획서/TODO/체크리스트 대조. 모든 요구사항 이행 확인. 통과 시만 odone 진입 허용."
invocation:
  user_callable: false
  pipeline_callable: true
  called_by: ["otest"]
  calls: []
---

# otest_evidence — 최종 검수

## 역할

"요구사항이 정말 전부 완료되었는가?" — 최종 검수관

otest_evidence는 "검수/감리/감수" 역할. oplan 산출물과 실제 결과를 1:1 대조.

## 합리화 방지

| 변명 | 현실 |
|------|------|
| "지금쯤 통할 거야" | 검수 커맨드 실행하라 |
| "자신 있어" | 자신감 ≠ 증거 |
| "이번 한 번만" | 예외 없음 |
| "빌드 통과됨" | 빌드 ≠ 요구사항 충족 |
| "에이전트가 성공 보고함" | 독립 검증하라 |
| "피곤함" | 피로 = 면제 사유 아님 |
| "부분 확인으로 충분" | 부분 = 증거 없음 |
| "다른 표현이니 규칙 적용 안 됨" | 정신 우선, 문자 차선 |

## 입력 (oplan 산출물)

1. 계획서: $HOME/.claude/session-env/${UUID}/plans/oplan_{대화ID}.md
2. TODO 체크리스트: 계획서 내 체크리스트 항목
3. acceptance_criteria.json: must/should/nice 항목
4. evidence 파일들: build_ok, make_ok, ui_test_done 등

## 일반적 실패 패턴

| 주장 | 필요한 증거 | 불충분한 것 |
|------|-----------|-----------|
| 테스트 통과 | 테스트 커맨드 출력: 0 실패 | 이전 실행, "통할 것" 추정 |
| 빌드 성공 | 빌드 커맨드: exit 0 | 린터 통과, 로그 좋아 보임 |
| 버그 수정 | 원래 증상 재테스트: 통과 | 코드 변경, 수정됐다고 가정 |
| 요구사항 충족 | 계획서 항목별 1:1 체크리스트 | 테스트 통과 |
| 에이전트 완료 | VCS diff에 변경 확인 | 에이전트 성공 보고 |
| 회귀 테스트 작동 | Red-Green 사이클 검증 | 테스트 1회 통과 |

## 검수 절차

```yaml
Step_0_goal_json_우선_대조 (PoC — soft hint):
  적용: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-env/${UUID}/goal.json 파일이 존재할 때만
  시점: Step_1(계획서_이행_확인) 진입 전, 1순위 대조 기준으로 활용
  동작:
    1. goal.json 로딩 (mcp__oio__file_read)
    2. goal.acceptance[] 항목별로 check 필드 확인
    3. acceptance_criteria.json must 항목과 ID 매핑 시도 (goal.acceptance.id ↔ AC-XXX)
    4. 미달 항목 발견 시: 경고 출력 ("⚠️ goal.acceptance[{id}] 미충족 가능성 — {check} 결과 검토 권장")
  판정_규칙:
    - goal.json 기반 경고만 출력. FAIL/PASS 판정은 변경 없음 (soft hint).
    - 최종 FAIL 판정은 기존 Step_3 (acceptance_criteria 대조)에서만 발생.
  PoC_제약:
    - goal.locked=true일 때 강제 차단 등 hard gate는 본 PoC 범위 외 (다음 차수)
    - hook 강제화는 다음 차수 예정
  부재_시: goal.json 없으면 본 Step_0 스킵, 기존 Step_1~6 그대로 진행

Step_1_계획서_이행_확인:
  방법: 계획서의 "수정 파일 목록" 전체를 git diff로 실제 변경 확인
  실패: 누락 파일 발견 → FAIL

Step_2_TODO_완료_확인:
  방법: 체크리스트 전 항목이 실제 구현에 반영되었는지 확인
  실패: 미완료 항목 발견 → FAIL

Step_3_acceptance_criteria_대조:
  must: 전부 PASS 필수 (evidence/make_ok criteria_results 확인)
  should: 80%+ PASS
  canary: expected FAIL = 실제 FAIL 확인

Step_3_5_CRUD_실행증거_게이트 (절대 규칙 — otest_done 생성의 선행 조건):
  원칙: ★차단 확인은 저장 검증이 아니다.★
        차단은 아무것도 일어나지 않는 것을 보는 것이고, 저장은 일어나는 것을 봐야 한다.
        "운영 데이터 보호"는 검증 면제 사유가 아니라 ★개발 DB 를 사용해야 할 사유★ 다.
  배경: 사이클30 이 T3 를 "전필드 DB일치 · PASS" 로 판정했으나 저장 경로를 태우지 않았다.
        삭제 가드만 확인하고 추가/수정을 건너뛴 결과 반쪽 저장이 실사용에서 즉시 드러났다.
        otest_make Step_4_5 와 ★이중 결속★ 이다 — make 를 우회해도 여기서 막힌다.

  실행 (Step_4 무결성 검사 전, otest_done 을 쓰기 전에 반드시 1회):
    mcp__oio__bash_exec:
      command: python3 .claude/skills/otest_make/scripts/verify_crud_executed.py --uuid ${PIPELINE_UUID}

  판정:
    exit 0: 다음 Step 진행 허용
    exit 1 (MISSING_CRUD_EVIDENCE): ★즉시 FAIL — otest_done 생성 금지★ + odev 역라우팅 권고.
            "저장을 태우지 않았다"는 미검증이지 통과가 아니다. PASS 로 승격하지 않는다.
    exit 2 (INPUT_ERROR): 게이트 미실행 = 통과 아님. 경로를 고쳐 재실행 후 판정한다.

  ⚠️ 이 게이트를 스킵하고 otest_done 을 생성하는 것은 evidence 조작에 해당한다 (아래 판정 섹션).

Step_3_6_회귀방어_대조군_게이트 (otest_done 생성의 선행 조건, 2026-09-15 사이클131/132 L-1067):
  원칙: ★"보존됐다"는 방어의 증명이 아니다.★
        원래 안 깨졌던 것과 구별하려면 대조군이 있어야 한다.
  배경: 사이클132n 이 `UpdateNoAi` 적용 후 AI 컬럼 보존을 확인했을 뿐 아니라, ★종전
        `Update`(전체열 SET)였다면 NULL 이 됐을 것까지 대조군으로 실측★했다. 이 대조군이
        없었다면 "보존됨"이 그 수정 때문인지, 애초에 안 건드려서인지 구별할 수 없었다.
        TDD red baseline(opt-in, 구현 전 시점)은 이 케이스를 덮지 못한다 — 회귀 방어의
        증명은 구현 ★후★에 구 경로를 일부러 태워야 하는, 시간축이 반대인 검증이다.

  적용_조건: acceptance_criteria.json 의 must 항목 중 criterion 이
    "보존|유지|덮어쓰지 않|NULL 방지|회귀 방어|가드" 중 하나를 포함할 때 (해당 없으면 스킵)

  실행 (항목마다 1회):
    1. 방어 ON 경로 실행 → 실제값 기록   (예: UpdateNoAi 적용 후 대상 컬럼 SELECT)
    2. ★방어 OFF 대조군 실행 → 실제값 기록★
       (구 경로 직접 호출 / 가드 비활성 하네스 별도 빌드 / HEAD baseline 빌드 중 1택)
    3. 두 값이 ★서로 달라야★ 한다

  evidence 필수 3필드: guard_on_value · guard_off_value · differs(true/false)
    → make_ok 의 해당 criteria_results 항목에 기록

  판정:
    differs=true            : PASS
    differs=false           : ★FAIL — otest_done 생성 금지★
                              (방어가 무효이거나, 애초에 안 깨지는 것을 방어라 부른 것)
    대조군 미실행(필드 부재) : ★미검증이지 통과가 아니다★ — PASS 승격 금지, odev 역라우팅 권고

  ⚠️ 대조군 실행 방법은 케이스마다 다르다(구 경로 호출 vs 별도 빌드)라 완전 스크립트화는
     어렵다. 단 evidence 3필드 부재 검사는 스크립트화 가능하므로, 여력이 있으면
     `verify_crud_executed.py` 에 필드 존재 검사를 추가하는 것을 권장(물리 차단에 가장 근접).

Step_4_evidence_무결성:
  build_ok: exit_code=0 필드
  make_ok: criteria_results 배열 + must 전부 PASS
  조건: 각 evidence 파일 존재 + mtime > pipeline_start_time
  CRUD_항목_추가조건: write_log + count_before + count_after 3필드 존재 (Step_3_5 게이트가 강제)

Step_5_spot_check:
  방법: auto_script 랜덤 2개 재실행
  실패: evidence 결과와 일치하지 않으면 FAIL

Step_6_raw_명령_출력_필수 (L-392 재발방지 — 절대 규칙):
  원칙: evidence에 기록되는 모든 수치/존재/크기/행수는 반드시 실제 셸 명령 출력의 raw 내용으로 뒷받침되어야 한다. LLM이 기억/추측/oplan 복사로 작성한 수치는 허위 evidence이며 Gate 신뢰성을 파괴한다 (L-392 참조).

  파일_존재_검증 (절대 규칙):
    - 금지: "파일 존재 + 실행권한" / "3639 bytes" 같은 수치를 명령 출력 없이 단독 기록
    - 필수: 반드시 oio bash_exec로 다음 명령 실행 후 출력을 evidence에 inline 복사
      ```bash
      for f in <파일1> <파일2> ...; do
        test -f "$f" && stat -c '%s %n' "$f" && wc -l "$f" || echo "MISSING: $f"
      done
      ```
    - evidence 기재 형식 (markdown):
      ```markdown
      #### T4: sendmessage_ack_write.sh 존재 검증
      ```
      $ test -f .claude/hooks/sendmessage_ack_write.sh && stat -c '%s %n' .claude/hooks/sendmessage_ack_write.sh && wc -l .claude/hooks/sendmessage_ack_write.sh
      3639 .claude/hooks/sendmessage_ack_write.sh
      75 .claude/hooks/sendmessage_ack_write.sh
      ```
      **판정**: PASS — 실재 파일 3639 bytes / 75줄
      ```
    - raw 출력 블록이 없는 수치는 evidence에 "UNVERIFIED" 표기 강제 (허위 기록보다 차라리 미검증 선언)

  hook_wire_검증 (필수):
    - 금지: "settings.json에 hook 등록됨" 단독 기재
    - 필수: `jq '.hooks.PostToolUse[] | select(.matcher=="...")' .claude/settings.json` 실행 후 출력 복사
    - 출력에 해당 hook 경로/matcher가 실제 존재해야 PASS

  파일_수정_검증 (필수):
    - 금지: "F6 state_read 치환됨" 단독 기재
    - 필수: `git diff <파일> | grep -E 'state_read|cat.*state.*awk'` 실행 후 변화량/치환 위치 inline 기록

  수치_기재_규칙:
    - bytes: `stat -c %s` 또는 `wc -c` raw 출력
    - lines: `wc -l` raw 출력
    - count: `grep -c` / `rg -c` raw 출력
    - 위 명령 없이 수치 기록 금지 (L-392 환각 재발 방지)

  Gate_판정_불가_조건:
    - evidence 파일에 raw 명령 출력 블록(```bash\n$ ...\n<출력>\n```)이 전무
    - "PASS"만 있고 근거 출력 없음 → 즉시 FAIL 판정 (L-392)
    - raw 출력과 판정 요약이 불일치 → 즉시 FAIL

Step_6_5_git_경로목록_quotepath_양방향_자기검증 (사이클128 재발방지 — 절대 규칙):
  원칙: ★raw 출력이 있어도 그 명령 자체가 틀린 수치를 낼 수 있다.★
        Step_6 은 "수치에 근거가 있는가"를 묻는다. 여기서는 ★그 근거 자체가 참인가★ 를 묻는다.
        git 은 core.quotepath 기본값 탓에 한글 경로를 8진 이스케이프+따옴표로 감싸 내보낸다.
        ⇒ 경로를 ★필터·비교·조인★ 에 쓰는 순간 조용히 누락된다. 오류도 경고도 나지 않는다.

  배경 (사이클127~128 실측):
    git ls-tree -r --name-only HEAD | grep -c '\.cs$'                        → 287
    git -c core.quotepath=false ls-tree -r --name-only HEAD | grep -c '\.cs$' → 406
    ⇒ ★119건(29.3%) 누락★. 이스케이프된 184건이 "..." 로 감싸여 필터를 빠져나간다.
    ★전체 개수(wc -l)는 2026 = 2026 으로 차이가 전혀 안 보인다★
      ⇒ 개수만 세는 검증은 이 결함을 ★절대★ 못 잡는다. 통과가 곧 무결의 증거가 아니다.
    사이클127 실사고: 이 결함이 코드 재집계에서 ★+97 차이★ 를 만들었다. 그대로 보고했다면
      ★존재하지 않는 회귀 97건으로 커밋을 막았다★ — 도구가 "없는 실패"를 만든 사례다(L-1021).

  적용 대상 (경로를 값으로 쓰는 모든 검증):
    - git ls-tree / ls-files 출력을 grep·comm·diff·sort·join·while read 에 투입
    - 작업트리 목록과 대조해 차이를 산출
    - 파일 목록을 evidence 의 수치 근거로 인용
    무해 (본 게이트 대상 아님): 개수만 세는 용법 (wc -l 단독)

  실행 (해당 검증마다 1회 — 생략 금지):
    같은 측정을 ★이스케이프 해제판★ 으로 한 번 더 돌려 두 값을 대조한다.
      기준판:  git ls-tree ... | <필터>
      대조판:  git -c core.quotepath=false ls-tree ... | <필터>
               (또는 git ls-tree -z ... | tr '\0' '\n' | <필터>)

  판정:
    두 값 일치: 해당 검증 결과 유효 → 진행
    ★불일치★:  그 검증 결과는 ★무효★ 다. 수치를 인용하지 말고 대조판 값으로 재측정한 뒤 판정한다.
               불일치를 발견하고도 기준판 수치로 FAIL/PASS 를 매기면 evidence 조작에 해당한다.
    대조 미실시: 해당 수치는 evidence 에 ★"UNVERIFIED"★ 표기 (Step_6 의 raw 출력 부재와 동일 취급)

  ★왜 hook 이 아니라 여기인가 (역할 분담 — 명시적 설계 결정)★:
    PreToolUse_Bash_git_quotepath_warn.sh 가 위험 용법을 감지해 경고하나 ★rc=0 경고형★ 이다.
    차단형으로 만들지 않은 이유:
      ① 무해 용법(wc -l)이 정당하게 존재하고, 파이프 뒤가 변수·서브셸일 수 있어
         ★명령 문자열만으로 필터인지 카운트인지 정적 완전판별이 불가능★ 하다.
      ② 불완전 판별로 rc=2 를 내면 사이클128 A·D 와 ★동형의 오차단 사고를 신규 생성★ 한다.
         이 프로젝트는 이미 그 사고를 2회 겪었다 — 세 번째를 재생산하지 않는다(L-1022).
    ⇒ hook 이 못 잡는 우회 경로가 구조적으로 남는다:
         변수 경유 `X=$(git ls-tree …); echo "$X" | grep` · 외부 스크립트 `bash foo.sh` · 파이프 뒤 서브셸
    ⇒ ★입력 측 차단이 불가능하므로 결과 측에서 회수한다. 그 책임이 여기(otest_evidence)에 있다.★
      hook 은 경고만 하고, ★최종 판정 책임은 otest 다.★ 경고가 없었다는 사실은 무결의 근거가 아니다.
```

## 중단 신호 (Red Flags)

아래 중 하나라도 해당 시 즉시 중단, 검수 미통과:
- "should", "아마", "할 것 같다" 표현 사용
- 검증 전 만족 표현 (완료, 훌륭해, 완벽해 등)
- 커밋/PR 생성 전 검증 미수행
- 에이전트 성공 보고를 검증 없이 신뢰
- 부분 검증에 의존 (전체 커맨드 미실행)
- evidence 파일 mtime이 pipeline_start_time 이전
- acceptance_criteria must 항목 중 미확인 항목 존재
- CRUD 항목을 "차단됨을 확인했다"만으로 PASS 판정 (차단 확인 ≠ 저장 검증 — Step_3_5)
- "운영 데이터 보호"를 이유로 저장/수정 검증을 건너뛰고 PASS 판정 (개발 DB 를 쓰라는 뜻이지 면제가 아니다)
- verify_crud_executed.py 를 실행하지 않은 채 otest_done 생성

원칙: 검증 커맨드 실행 → 출력 읽기 → 그 후에만 결과 선언

## 판정

```yaml
전부_PASS:
  선행: Step_3_5 CRUD 실행증거 게이트 exit 0 (미통과 시 otest_done 생성 금지)
  동작: evidence/otest_done 생성 → "otest_evidence PASS" 반환

FAIL:
  동작: 실패 항목 목록 + 역라우팅 권고 반환 (otest_done 미생성)
  계획서_이행_실패 또는 TODO_미완료: odev 권고
  criteria_불일치 또는 설계_결함: oplan 권고
  evidence_조작_감지: 전체 FAIL + 긴급 역라우팅
```

## RLHF 연동

```yaml
reroute_history:
  저장: $HOME/.claude/session-env/${UUID}/evidence/reroute_history.json
  기록: 실패 항목

에스컬레이션:
  동일항목_2연속: oplan 에스컬레이션
  1~2회: odev
  3~4회: oplan
  5회+: 사용자 AskUserQuestion
  10회: 강제 중단
```

---

## TDD red-first 모드 (선택적)

> 출처: tdd (mattpocock/skills, MIT) — 영감. red-green-refactor 사이클을 우리 파이프라인에 통합.

### 트리거 조건

```yaml
활성화_조건 (OR — 하나라도 해당 시 활성화):
  - oplan acceptance_criteria.json의 최상위에 tdd_mode=true 플래그 존재
  - 사용자가 명시적으로 "TDD로 진행", "red-first", "테스트부터 작성" 요청
  - oplan이 PRD 출력 모드에서 must 항목을 자동화 가능 verify 명령으로 모두 작성한 경우

권장_tier:
  o3+: 권장 (acceptance_criteria 자동화 ROI 충분)
  o4/o5: 강력 권장 (회귀 위험 큼)
  o1/o2: 비권장 (오버헤드 > 이득 — 단일 파일/<20줄 작업)

비활성화 시 동작:
  기존 검수 절차(Step 1~6) 그대로 적용 — 본 모드는 추가 옵션
```

### Red-Green-Refactor 사이클

#### Red 단계 (otest_evidence 담당)

```yaml
입력: acceptance_criteria.json의 must 항목 (verify 명령 + expected 값)
동작:
  1. acceptance_criteria.json의 must 항목 전체 순회
  2. 각 항목의 verify 셸 명령을 실행 가능한 테스트 스크립트로 변환
     (이미 verify에 명령이 있으므로 별도 테스트 코드 작성 불필요한 경우 다수)
  3. 각 verify 명령을 oio bash_exec로 실행
  4. expected 불일치 = FAIL → red 상태 확인
  5. 모든 must 항목이 FAIL이어야 정상 진입 (구현 전이므로 모두 실패가 정상)
  6. 일부 항목이 이미 PASS → 경고 출력 (이미 구현되었거나 verify가 너무 약함)

저장: $HOME/.claude/session-env/${UUID}/evidence/tdd_red_baseline.json
형식: |
  {
    "phase": "red",
    "ts": "{ISO8601}",
    "must_items": [
      {"id": "AC-001", "verify": "...", "expected": "...", "actual": "...", "status": "FAIL"},
      ...
    ],
    "all_failed": true,
    "preexisting_passes": []  # 빈 배열이 정상
  }

출력: "Red 단계 완료 — {N}개 must 항목, 전부 FAIL ({M}개 이미 PASS — 검토 권고)"
```

#### Green 단계 (odev 담당)

```yaml
입력: tdd_red_baseline.json + acceptance_criteria.json
동작:
  1. 실패한 must 항목을 통과시키는 최소 구현
  2. 과도한 일반화/추상화 금지 — verify 명령을 통과시키는 것만이 목표
  3. 한 번에 1개 항목씩 PASS로 전환 권장 (점진적 green)
  4. 전체 must 항목 PASS 확인 후 odev 완료 보고

저장: $HOME/.claude/session-env/${UUID}/evidence/tdd_green_run.json
형식: |
  {
    "phase": "green",
    "ts": "{ISO8601}",
    "must_items": [
      {"id": "AC-001", "verify": "...", "actual": "...", "status": "PASS"},
      ...
    ],
    "all_passed": true
  }

출력: "Green 단계 완료 — {N}개 must 항목 PASS"
주의: should/nice는 green 단계에서 강제하지 않음 — must만 강제
```

#### Refactor 단계 (odev_simplify 담당, 선택)

```yaml
입력: tdd_green_run.json
동작:
  1. green 유지하며 코드 정리 (중복 제거, 명명 개선, 추상화 도입)
  2. 매 리팩터 시도 후 verify 명령 재실행 → 여전히 PASS 확인
  3. 1개 verify라도 FAIL → 즉시 해당 리팩터 되돌리기

저장: $HOME/.claude/session-env/${UUID}/evidence/tdd_refactor_run.json
출력: "Refactor 단계 완료 — must 전부 PASS 유지, 리팩터 {N}건 적용"
스킵_조건: o3 이하 또는 코드 변경 없는 작업 (스킬/문서 변경)
```

### TDD 모드 vs 기존 모드 비교

| 단계 | 기존 모드 | TDD red-first 모드 |
|---|---|---|
| 1 | oplan: acceptance_criteria 정의 | oplan: acceptance_criteria 정의 + tdd_mode=true |
| 2 | odev: 코드 구현 | otest_evidence: red 베이스라인 측정 (verify 일괄 실행, 모두 FAIL 확인) |
| 3 | otest: 검수 (Step 1~6) | odev: must 통과 최소 구현 (green) |
| 4 | (없음) | odev_simplify: 리팩터 (green 유지) |
| 5 | (없음) | otest_evidence: green 최종 검수 (Step 1~6 그대로 적용) |

### TDD 모드 활성화 시 ok_pipeline 흐름

```yaml
활성화_시_파이프라인:
  oplan → otest_evidence(red) → odev(green) → odev_simplify(refactor) → otest(verify) → otest_evidence(final) → odone

상태_파일:
  $HOME/.claude/session-env/${UUID}/state/tdd_phase
  값: "red" | "green" | "refactor" | "final" | "" (비활성)
  쓰기: 각 단계 진입 시 해당 페이즈 기록
  읽기: hook 및 후속 스킬이 현 단계 판단

ok_pipeline_연동:
  ok_pipeline이 oplan 직후 acceptance_criteria.json을 읽어 tdd_mode 확인
  tdd_mode=true → odev 직전에 otest_evidence(red) 1회 우선 실행
  red 베이스라인이 "모두 FAIL"이 아닐 경우 사용자 경고 후 진행 여부 결정
```

### TDD 모드 acceptance_criteria 형식

acceptance_criteria.json의 must 항목은 기존 형식을 그대로 사용하되, 자동화 가능한 verify 명령을 필수로 한다.

```json
{
  "task_name": "...",
  "tdd_mode": true,
  "must": [
    {
      "id": "AC-001",
      "criterion": "ogrill SKILL.md 220줄 이상",
      "verify": "wc -l <프로젝트 루트>/.claude/skills/ogrill/SKILL.md | awk '{print $1}'",
      "expected": ">= 100",
      "red_first": true
    }
  ]
}
```

```yaml
필수_필드:
  id: "AC-XXX" 형식
  criterion: 한국어 자연어 설명
  verify: 실행 가능한 셸 명령 (oio bash_exec로 실행)
  expected: 비교 가능한 값 또는 표현식 (예: "exit 0", ">= 100", "≥ 3 매치")
  red_first (선택): true 시 red 단계에서 우선 검증

자동화_불가_항목 처리:
  - UI 시각 검증, 사용자 인지 검증 등 → tdd_mode 적용 X
  - acceptance_criteria.json에 "manual": true 플래그로 표시 → red/green 단계에서 스킵
```

### 주의사항

```yaml
적용_제한:
  - 모든 검증을 자동화 가능한 것은 아님 — UI/시각/사용자 경험 검증은 기존 모드 유지
  - TDD 모드는 명시적 옵트인 (자동 강제 X)
  - 첫 도입 시 학습곡선 있음 — verify 명령 작성 능력 필요

verify_명령_품질:
  - 너무 약한 verify (예: 파일 존재만 확인) → green이 쉬워지나 회귀 보장 약함
  - 너무 강한 verify (예: 정확한 라인 수치) → green이 어렵고 리팩터 시 false negative
  - 권장: 외부 관찰 가능한 동작 또는 핵심 라인 패턴 검사

기존_검수와의_관계:
  - red/green/refactor는 must 항목만 다룸
  - should/nice/canary는 final 단계의 기존 Step 1~6에서 검수
  - 즉, TDD 모드는 must 검수의 시점을 앞당기는 것이 핵심 차이
```

### 출처

- tdd (mattpocock/skills, MIT 라이선스)
- Kent Beck의 Test-Driven Development: By Example (red-green-refactor 사이클)

