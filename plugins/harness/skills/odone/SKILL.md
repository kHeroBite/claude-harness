---
name: odone
description: "작업 마무리. 테스트 통과 후 실행. Auto-activates when: all tests passed, finalization needed."
invocation:
  user_callable: false
  pipeline_callable: true
  called_by: [ok_pipeline(o3~o5)]
  calls: [odone_lesson(→odone_trans→odone_review→odone_hooks→odone_skills→odone_docs), odone_cleanup, odone_git(→opush)]
---

## 절대규칙

```yaml
shutdown_즉답_절대규칙 (L-U5):
  - shutdown_request 수신 즉시 현재 작업 중단 후 shutdown_response 발송
  - 파일 저장/정리 등 후처리 후 응답하는 행위 절대 금지
  - 메인이 3회×5s=15초 내에 응답 없으면 pane 강제 종료 대상
```

## 진입 시 UUID 결정 (필수 — 첫 번째 mcp__oio__bash_exec 명령)
> ⚠️ 모든 셸 명령은 `mcp__oio__bash_exec` 전용. Claude 내장 `Bash` 도구 사용 절대 금지 (write_guard.sh 차단)

```yaml
UUID_결정:
  UUID=$PIPELINE_UUID
  mcp__oio__bash_exec(command='mkdir -p $HOME/.claude/session-env/${UUID}/{logs,evidence,plans}')

팀에이전트_UUID_규칙: PIPELINE_UUID 환경변수 값을 그대로 사용. resolve_uuid() 호출 금지.
예: UUID=$PIPELINE_UUID (환경변수에서 직접 읽기)
```

## ⚠️ 세션 디렉토리 경로 이중화 주의 (L-1063, 2026-09-14 사이클130b)

```yaml
사실: |
  이 팀은 $CLAUDE_CONFIG_DIR(예: /tmp/cc-*/session-env/) 와 $HOME/.claude/session-env/
  두 base 가 동시에 실존할 수 있고, 내용이 서로 다를 수 있다(hook/도구별로 어느 쪽에
  쓰는지가 갈린다). 실측(2026-09-14): otest 로그가 $CLAUDE_CONFIG_DIR 쪽에만 존재하고
  $HOME/.claude 쪽에는 없었다 — 후자만 조회했다면 "otest 미수행"으로 오판했을 것이다.

규칙 (절대):
  - odone 진입 시 산출물(계획서/odev·otest 로그/evidence)이 $HOME/.claude 쪽에 없다고
    "미수행"으로 단정하지 마라.
  - 부재 판정 전 반드시 $CLAUDE_CONFIG_DIR/session-env/${UUID}/ 도 함께 확인하라.
  - 팀리드/환경변수로 $CLAUDE_CONFIG_DIR 값이 주어졌으면 그 경로를 ★우선 정본★으로 취급한다.
  - 두 base 모두에 없을 때만 "미수행"으로 판정한다.

근거: LESSONS.md L-1063 (사이클130b) — 실제 이 판정 실수가 발생할 뻔했고 team-lead 확인으로 정정됨.
```

## 진입 시 git diff cross-check (ui_touched.json 보정)

```yaml
시점: UUID 결정 직후, 재개 지원 result.json 확인 전
목적: oplan 사전 판정과 실제 odev 변경 파일 비교 → false negative 차단
절차:
  1. ui_touched.json 읽기:
     mcp__oio__file_read(path="$HOME/.claude/session-env/${UUID}/evidence/ui_touched.json")
     부재 시: 본 단계 SKIP (oplan 미경유 상황 — 기존 동작)
  2. git diff 실행:
     mcp__oio__bash_exec(command='git -C {프로젝트} diff HEAD --name-only')
  3. 실제 변경 파일을 UI_PATTERN_REGEX로 매칭
  4. 매칭된 파일이 있는데 ui_touched.touched=false면 보정:
     - touched=true
     - matched_patterns 갱신 (실제 매칭된 패턴들)
     - decided_by="odone"
     - git_diff_verified=true
     - ts=<현재 시각>
     - mcp__oio__file_write로 덮어쓰기
     - 경고 로그: "⚠️ ui_touched 보정: oplan은 false 판정했으나 실제 변경 파일에 UI 패턴 매칭"
  5. 매칭 일치 시 git_diff_verified=true만 갱신 (보정 불필요)

실패_처리:
  - jq/git 실패 시 본 단계 SKIP, 기존 odone 흐름 진행 (안전 통과)
```

## 재개 지원 (result.json 프로토콜)

```yaml
재개_지원 (result.json 프로토콜):
  진입_시:
    1. work/ 디렉토리 생성: mcp__oio__bash_exec(command='mkdir -p $HOME/.claude/session-env/${UUID}/work')
    2. ★현재 conv_id 획득 (게이트 판정 기준 — 3번보다 먼저 수행한다):
       mcp__oio__bash_exec(command='cat $HOME/.claude/session-env/${UUID}/conv_id')
       ⚠️ conv_id 파일 자체도 옛 사이클 값이 잔류할 수 있다. 파이프라인이 주입한
          현재 대화ID(메인 프롬프트 명시값)가 있으면 그 값을 우선한다.
    3. 기존 result.json 확인: mcp__oio__file_read(path="$HOME/.claude/session-env/${UUID}/work/odone-1_result.json")
    4. ★conv_id 대조 게이트 (L-670 — 스킵 판정보다 먼저 통과해야 한다):
       저장된 conv_id == 현재 conv_id  → 같은 작업의 중단분이다. 5번 스킵 판정으로 진행한다.
       저장된 conv_id != 현재 conv_id  → ★옛 사이클 잔류물★이다. 파일 내용을 전부 무시하고
                                          substeps_completed 를 빈 목록으로 간주해 전 단계를 수행한다.
       conv_id 필드 부재 (구 스키마)   → ★잔류물로 간주★한다. 위와 동일하게 전 단계를 수행한다.
       ⚠️ 무시 판정 시 그 사실을 1줄로 출력한다 — 예: "⚠️ [잔류물 무시] odone-1_result.json
          conv_id={저장값|부재} ≠ 현재 {현재값} — 전 단계를 새로 수행한다."
       ⚠️ 판단이 서지 않으면 ★무시(전 단계 수행)★ 쪽으로 기운다. 중복 수행은 비용일 뿐이지만
          잘못된 스킵은 "하지 않은 일을 완료로 보고"하는 침묵 실패다.
    5. substeps_completed 확인 → 완료된 서브스텝 스킵 (4번 게이트를 통과한 경우에만)
       - "lesson" 포함 → odone_lesson 스킵
       - "cleanup" 포함 → odone_cleanup 스킵
       - "git" 포함 → odone_git 스킵 (이미 완료)

  각_서브스텝_완료_시:
    원칙: 디스크 먼저, SendMessage 나중 — result.json 저장 완료 후에만 완료 통보
    ★conv_id 필수 필드 — 매 저장마다 현재 대화ID를 반드시 포함한다. 누락하면 다음 사이클이
      이 파일을 구 스키마로 보고 무시하므로, 정상 중단 재개까지 불가능해진다.
    mcp__oio__file_write(path="$HOME/.claude/session-env/${UUID}/work/odone-1_result.json", overwrite=true, content=JSON)
    lesson 완료: { "agent":"odone-1", "conv_id":"{현재 대화ID}", "status":"partial", "substeps_completed":["lesson"] }
    cleanup 완료: { ..., "conv_id":"{현재 대화ID}", "substeps_completed":["lesson","cleanup"] }
    git 완료: { ..., "conv_id":"{현재 대화ID}", "status":"completed", "substeps_completed":["lesson","cleanup","git"], "commit_hash":"..." }

배경 (L-670 — 2026-08-23 사이클26 등재):
  사이클25 odone 진입 시 work/odone-1_result.json 에 ★사이클15 잔류물★이
  status:"completed" + substeps_completed 전항목으로 남아 있었다. 당시 재개 프로토콜은
  task 동일성을 검증하지 않고 substeps 만 읽어 스킵하도록 규정돼 있었으므로,
  규정대로 따랐다면 그 사이클 odone 의 전 단계를 스킵하고 "완료"를 보고할 뻔했다.
  ★이름과 경로가 같은 옛 산출물을 현재 것으로 오인하는 함정★이며, 위 게이트가 그것을 막는다.
```

# odone — 작업 마무리

## 🚨 전제조건 (L-008)

otest 전체 통과 완료 필수 (Phase 0~4). 파이프라인 순서 상세: ok 참조.
**적용 계층**: o3~o5만. o1/o2는 odone 미실행 (ofinish Step 1.5 경량 교훈으로 대체).
**참고**: ofinish Step 1.5(경량 교훈)/Step 7.5(경량 커밋)는 o1/o2 전용. o3~o5에서는 odone이 교훈+커밋을 담당.

## 서브스킬 실행 순서 (v4.3 — 3단계 구조)

```yaml
odone_3단계_구조:
  1단계: Skill('odone_lesson') — 교훈 수집 + 반영
    ① odone_trans: 문제 감지 (우회 패턴 수집)
    ② odone_review: 조치 결정 (target: hook/skill/docs)
    ③ odone_hooks: hook 강제화 (target=="hook")
    ④ odone_skills: 스킬 규칙 강화 (target=="skill")
    ⑤ odone_docs: 문서 업데이트 (target=="docs" + 전체 교훈)
    
  2단계: Skill('odone_cleanup') — 코드 정리
    디버그 코드 제거, Lock 해제
    
  3단계: Skill('odone_git') — 커밋 & 푸시
    → Skill('opush') 내부 호출

⛔ odone_git까지 완료해야 "작업 완료" 선언 가능 (ntfy 발송/통계/배너는 ofinish가 담당)

odone_lesson 내부에서 관리됨 — 상세: odone_lesson SKILL.md 참조
```

## 서브단계별 추가 에이전트 (메인 위임 spawn)

> odone의 각 서브단계는 필요 시 메인에게 SPAWN_REQUEST를 보내 추가 에이전트를 위임 spawn한다.
> spawn된 에이전트는 odone에게 직접 DM으로 결과 보고. 메인은 spawn만 담당.
> 프로토콜 상세: ok_pipeline SKILL.md "Spawn 위임 프로토콜" 섹션 참조.

```yaml
odone_review:
  리뷰_에이전트: SPAWN_REQUEST ×1~2 (프로세스 분석 + 조치 방향 병렬) — model="opus"
  목적: 교훈 분석 + $HOME/.claude/session-env/${UUID}/logs/review_actions.json 생성

odone_trans:
  탐지_에이전트: SPAWN_REQUEST ×1 (트랜스크립트 우회 패턴 감지) — model="sonnet"

odone_cleanup:
  정리_에이전트: SPAWN_REQUEST ×1~N (파일별 디버그 코드 정리 병렬) — model="haiku"
  목적: 수정 파일별 독립 정리 병렬화
  디버그코드_정의:
    대상: Debug2.WriteLine, Console.WriteLine, //TEMP 주석, //DEBUG 주석, //TODO (임시) 주석
    예외_유지: 오류 로그(log.Error), 진행 상태 로깅(log.Info), 기능 필수 출력
    범위: 수정된 파일 + 새로 생성된 파일 모두 포함

odone_docs:
  문서_에이전트: SPAWN_REQUEST ×1~N (HISTORY + LESSONS + PROJECT + DATABASE 병렬 업데이트) — model="sonnet"
  목적: 여러 문서 동시 업데이트

odone_skills:
  스킬_에이전트: SPAWN_REQUEST ×1~2 (규칙 강화 + 신규 서브스킬 병렬) — model="sonnet"
  목적: review 결과 반영 스킬 수정

odone_hooks:
  Hook_에이전트: SPAWN_REQUEST ×1~2 (물리 차단 설계 + 구현 병렬) — model="sonnet"
  목적: hook 설계와 구현 병렬화

odone_git:
  Git_에이전트: SPAWN_REQUEST ×1 (커밋 + 푸시 — 순차, 병렬화 불가) — model="haiku"

단계_누적_상한: 없음
Fallback: 메인 무응답 또는 spawn 실패 시 → Skill() 직접 로딩으로 순차 수행

# [L-035] SPAWN_REQUEST 위임 필수 — odone-1은 팀에이전트이므로 직접 Agent() spawn 불가
# odone-1이 직접 Agent()로 spawn 시도 시: pipeline_order_guard.sh 차단 (IDLE 상태에서 DEV/TEST spawn 불허)
# 올바른 방법: SendMessage(to:"team-lead", "SPAWN_REQUEST: ...")로 메인에게 위임 후 Skill() 직접 로딩으로 서브스킬 실행
```

## 에이전트 발동 통계 수집 (ofinish로 이관)

> 통계 수집/출력은 ofinish step2에서 수행. odone은 통계 파일만 생성.

```yaml
수집_시점: odone_git 완료 직후 (odone 마지막 단계)
수집_방법:
  팀에이전트_반환_형식 (필수):
    - 반환 메시지 마지막 줄에 아래 형식 필수 포함:
    - "📊 spawn_stats: team={N}"
    - 예: "📊 spawn_stats: team=2"
  영속화:
    - 통계를 $HOME/.claude/session-env/${UUID}/agent_stats.json에 저장
  출력: ofinish step2에서 읽어서 출력 (odone은 파일 생성만)
```

## 경로별 구성 (tier 기반 — o1/o2는 odone 미실행)

```yaml
o1/o2 (odone 미실행 — ofinish Step 1.5/7.5는 o1/o2 전용):
  o1/o2는 odone 자체를 실행하지 않음.
  ofinish Step 1.5 경량 교훈 + Step 7.5 경량 커밋으로 대체 (o1/o2 전용).
  o3~o5에서는 odone이 교훈(odone_lesson) + 커밋(odone_git)을 직접 담당.
  이유: 소규모 작업에서 odone Full/Fast 절차는 과도

Fast_Path (o3 — Normal):
  구성: odone_lesson(간략: review→docs만) → Intent Lock 해제(인라인) → odone_git (cleanup 스킵)
  참고: Fast Path에서 odone_trans는 항상 스킵됨
  Intent_Lock_해제 (cleanup 스킵 시 필수 — 인라인 수행):
    odone_cleanup 스킵 시에도 Intent Lock 해제는 반드시 수행
    방법: mcp__oio__file_delete(path='{프로젝트}/.claude/locks/intent_${CLAUDE_SESSION_ID}.json')
    시점: odone_lesson 완료 후, odone_git 진입 전
  에이전트:
    odone_review: 간략 리뷰 에이전트 1개 (Full Path 대비 축약)
    odone_docs: 교훈 기록 에이전트 1개 (LESSONS.md + MEMORY.md 점검 — 생략 금지)
    odone_git: 1개 (순차, 병렬화 불가)
  생략_절대_금지: odone_review (간략이어도 필수 — 생략 시 파이프라인 위반), odone_docs (교훈 단계 — 생략 시 파이프라인 위반)
  스킵_조건:
    odone_hooks: review 결과 JSON에 target=="hook" 항목 없으면 스킵 가능
    odone_skills: review 결과 JSON에 target=="skill" 항목 없으면 스킵 가능
    odone_trans: Fast Path에서 항상 스킵
    odone_cleanup: Fast Path에서 항상 스킵
  참고: ntfy 발송/통계 출력/종료 배너는 ofinish에서 수행

Full_Path (o4/o5 — Heavy/Massive):
  구성: odone_lesson(전체) → odone_cleanup → odone_git
  에이전트:
    odone_review: 리뷰 에이전트 권장 2개, 최대 없음
    odone_cleanup: 정리 에이전트 최대 N개 (파일별 병렬), 최대 없음
    odone_docs: 문서 에이전트 최대 N개 (병렬), 최대 없음
    odone_skills: 스킬 에이전트 권장 2개, 최대 없음
    odone_hooks: Hook 에이전트 권장 2개, 최대 없음
    odone_git: 1개 (순차, 병렬화 불가)
  참고: ntfy 발송/통계 출력/종료 배너는 ofinish에서 수행

o5_Gate: 제거됨 (v4.2)
  사유: 완전자동화 목적 — 중간 인터럽트 금지. git revert로 복원 가능.
  o5도 Full Path와 동일하게 odone_cleanup → odone_docs → odone_git 직행.

단계_누적_상한: 없음
```

## Full_Path 외부 리뷰 (o4~o5 전용)

```yaml
odone_lesson_외부리뷰 (O4~O5 전용):
  방식: 기존 odone_lesson + codex:adversarial-review 병렬 spawn
  조건: tier가 O4 또는 O5일 때만 실행 (classification 파일 값 기준)
  codex_역할: GPT 관점에서 "왜 이렇게 구현했나?" 도전 → 교훈 추출
  취합: Claude가 양쪽 결과를 merge하여 최종 교훈 작성
  시점: odone_lesson 실행 시 병렬로 codex:adversarial-review spawn

odone_review_외부리뷰 (O4~O5 전용):
  조건: tier가 O4 또는 O5일 때만 실행 (classification 파일 값 기준)
  순서:
    1차: Skill('code-review:code-review') — Claude PR 리뷰
    2차: Skill('codex:adversarial-review') — GPT 도전적 프로세스 리뷰
  취합: 이종 AI 이중 검증 결과를 프로세스 개선에 반영
  시점: odone_review 내 Step 2 분석 후, JSON 출력 전
```

## 🚨 odone 강제 완주 규칙 (절대 규칙)

```yaml
원칙: odev/otest 완료 후 odone을 반드시 끝까지 완주해야 "작업 완료"
금지:
  - otest 통과 후 odone 진입 없이 세션 종료
  - odone 일부 서브스킬만 실행 후 중단
  - "빌드 성공했으므로 완료" 선언 (odone 미완주)
  - 커밋/푸시 없이 "작업 완료" 응답

odone_미완주_방지:
  체크포인트: otest 통과 직후 "odone 진입" 명시적 선언
  검증: odone_git 실행 완료 여부로 판단
  위반_시: 사용자에게 "odone 미완주" 경고 후 즉시 재개

컨텍스트_부족_시:
  1. odone 서브스킬 진행 중 컨텍스트 20% 이하 감지
  2. 즉시 /compact 실행
  3. compact 후 파이프라인 위치 재확인 ("odone 진행 중, 다음: odone_xxx")
  4. 남은 서브스킬부터 이어서 실행
  5. odone_git까지 반드시 완료 (ntfy/배너는 ofinish)
  금지: compact 후 odone 위치를 잊고 새 작업 시작

세션_종료_임박_시:
  규칙: 컨텍스트가 극도로 부족하더라도 최소 odone_git(커밋/푸시)는 완료
  최소_보장: odone_git (스킵 절대 금지 — ntfy/배너는 ofinish 담당)
  이유: 구현+테스트 완료 후 커밋 없이 세션 종료 = 모든 작업 소실
```

## 🚨 교훈 단계 강제 실행 (절대 규칙 — L-042)

> **질문/탐색 외 모든 분류에서 교훈 단계(odone_review → odone_docs) 필수 실행.**
> 상세 절차/트리거: odone_review SKILL.md "교훈 기록 절차" 섹션 참조

## 교훈 단계 (M-07 명확화)

```yaml
교훈_단계 (M-07 명확화):
  원칙: 교훈 단계(odone_review)는 o3~o5 코드 수정 작업에서 항상 실행
  Fast Path(o3)에서도: odone_review 실행 → 결과물 0개일 수 있음 (정상)
  금지: "교훈 해당 없어서 odone_review 스킵" — 항상 실행 후 결과를 판정
  o1/o2: odone 미실행이므로 해당 없음 (ofinish Step 1.5가 경량 교훈 수집)
```

## Gate 판정 리포팅 (odone_review 내 실행)

> o4/o5 Full Path에서만 실행. 상세: [GATE_REPORT.md](references/GATE_REPORT.md)

## 공용 리소스 동기화 검증 (odone_cleanup 내 실행)

> 공용 리소스 변경 시 3개 프로젝트 동기화 검증. 상세: [SYNC_VERIFY.md](references/SYNC_VERIFY.md)

## 최종 완료 풀배너 (ofinish로 이관)

> 종료 배너/풀배너는 ofinish step7에서 출력. odone은 배너를 출력하지 않음.

```yaml
이관_대상: ofinish step7_종료_배너
이유: odone 완료 후 ofinish가 팀 정리/통계/ntfy 등 후속 처리를 수행하므로, 최종 배너는 ofinish에서 출력이 정확함
```

## 결과 파일 저장 및 완료 통보 (필수 — 절대 생략 금지)

### 결과 파일 저장

```yaml
시점: odone_git 완료 직후 (Git Push 성공 후)
파일명: $HOME/.claude/session-env/${UUID}/logs/odone_{대화ID}.md
대화ID 획득: cat $HOME/.claude/session-env/${UUID}/conv_id

포함_내용:
  - 리뷰 결과 요약 (교훈 항목 수 + 주요 교훈)
  - Hook/Skills 변경 여부 (생성/수정된 hook·skill 파일 목록)
  - 커밋 해시 + 커밋 메시지
  - 공용 리소스 동기화 검증 결과 (해당 시)
```

### 완료 통보 (절대 생략 금지)

```yaml
시점: 결과 파일 저장 직후
방법: SendMessage(to:"{리더명}", message:"odone 완료 — $HOME/.claude/session-env/${UUID}/logs/odone_{대화ID}.md\n{요약 3줄}", summary:"odone 마무리 완료")
마지막_줄: "📊 spawn_stats: team=N sub=N task=N"

보고_수치_실측_원칙 (L-407 — 절대 규칙):
  원칙: 완료 보고에 개수/줄수/건수 등 수치를 인용할 때는 grep/wc 등으로 직접 실측 후 기재
  금지: 이전 사이클 요약이나 기억 기반 수치를 재확인 없이 재인용
  위반_사례: "UI Invoke 핸들러 13개"로 보고했으나 실측 결과 26곳(고유 15개)으로 판명 (L-407)
  검증_방법: 보고 직전 grep -c 또는 grep -n | wc -l 로 재확인 후 수치 기재

hook_차단_오류_보고 (L-267 — 절대 규칙):
  원칙: 작업 중 hook이 차단한 도구 호출이 있으면 완료 보고에 반드시 포함
  형식: "⚠️ hook 차단 발생: {hook명} — {차단된 도구} ({원인 요약})"
  예시: "⚠️ hook 차단: write_guard.sh — Edit(LESSONS.md) (L-171 메인 직접 수정 금지)"
  목적: 메인이 차단 오류를 인지하여 재발방지 조치 가능
  금지: hook 차단을 우회 완료 후 오류 보고 없이 숨김

금지:
  - 결과 파일 없이 완료 통보
  - 완료 통보 없이 idle 전환
  - Git Push 완료 전 "완료 요약" 출력
  - hook 차단 오류를 완료 보고에서 누락 (L-267)
```

## 사용자 인터럽트 대응

```yaml
사용자_인터럽트_대응:
  원칙: odone 단계는 완주 우선 — 현재 단계 완료 후 ok로 에스컬레이션
  A_질문: 직접 답변 (odone 중단하지 않음)
  B_수정요구: odone 완료 후 ok로 에스컬레이션 (새 파이프라인)
  C_새작업: odone 완료 후 ok로 에스컬레이션
```

## shutdown_request 수신 시 행동

> shutdown_request 수신 즉시 approve 응답 + 작업 중단. 단, odone_git 진행 중이면 git 명령 완료 후 approve (데이터 손실 방지). 상세: ok SKILL.md 참조.

