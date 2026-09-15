---
name: odone_skills
description: "스킬 파일 업데이트. 규칙 강화, 서브스킬 신규 생성."
invocation:
  user_callable: false
  pipeline_callable: true
  called_by: [odone(조건부)]
  calls: []
---
# odone_skills — 스킬 파일 업데이트

## 역할

작업 중 발견된 중요 패턴, 규칙, 교훈을 스킬 파일(.claude/skills/)에 직접 반영.

## 입력: $HOME/.claude/session-env/${UUID}/logs/review_actions.json

```yaml
소비_대상: actions 배열에서 target == "skill" 인 항목만
소비_절차:
  1. $HOME/.claude/session-env/${UUID}/logs/review_actions.json 읽기
  2. target == "skill" 항목 필터링
  3. 항목 없으면 "✅ odone_skills: 스킬 수정 대상 없음" 출력 후 종료
  4. 항목 있으면 아래 업데이트 분류 및 수정 절차 실행
  5. 각 항목의 target_file, target_section, proposed_rule 참조하여 수정

판단_기준 (review에서 이미 결정됨):
  - hook으로 감지 불가능한 판단/맥락 기반 규칙
  - 스킬 규칙 강화로 예방 가능한 패턴
```

## 추가 트리거 (review JSON 외)

```yaml
트리거_조건 (OR — review JSON과 별도로 발동):
  - 작업 중 기존 스킬 규칙 위반 직접 발견 → 규칙 강화/명확화
  - 새로운 패턴/규칙 발견 → 해당 스킬에 추가
  - 스킬 간 정보 불일치/중복 발견 → 정합성 수정
  - 새 서브스킬/유틸리티 스킬 생성 필요

스킵_조건:
  - review JSON에 skill 항목 없고, 추가 트리거도 해당 없음
```

## 업데이트 분류 및 대상

```yaml
Level_1_참고 (스킬 미수정):
  - 1회성 이슈, 재발 가능성 낮음
  - LESSONS.md에만 기록 (odone_review 담당)

Level_2_스킬_강화:
  - 기존 스킬의 규칙 명확화, 체크리스트 항목 추가
  - 예: odone Gate에 새 체크 항목 추가
  - 예: obuild에 특정 빌드 옵션 추가
  - 해당 스킬 SKILL.md 직접 수정

Level_3_스킬_신규:
  - 새로운 서브스킬/유틸리티 스킬 필요
  - 예: 새 프로젝트스킬, 새 도메인 스킬
  - SKILL.md 생성 + odone/SKILL.md 순서 반영 + CLAUDE.md 목록 추가
```

## 수정 대상 매핑

```yaml
스킬_파일_수정_시_연쇄_업데이트:
  서브스킬_수정:
    - 해당 SKILL.md 수정
    - 상위 메인스킬에 영향 있으면 메인스킬도 수정

  새_서브스킬_생성:
    - SKILL.md 생성 (.claude/skills/{스킬명}/SKILL.md)
    - 상위 메인스킬 SKILL.md에 실행 순서 반영
    - CLAUDE.md 서브스킬 목록에 추가
    - ok SKILL.md 서브스킬 목록에 추가

  메인스킬_수정:
    - 해당 메인스킬 SKILL.md 수정
    - CLAUDE.md에 영향 있으면 CLAUDE.md도 수정

Tier_준수 (절대 규칙):
  - 메인/서브스킬에 프로젝트 고유 경로/설정 금지
  - 프로젝트 고유 → 프로젝트스킬(_{project})에만 기재
```

## 수정 절차

```yaml
1_판단: 이번 작업에서 스킬 업데이트 필요 여부 확인
2_분류: Level 2(강화) 또는 Level 3(신규) 판정
3_수정:
  - NTFS rsync 방식 준수 (cp → Edit → rsync)
  - Tier 분리 원칙 준수
4_연쇄: 상위 스킬/CLAUDE.md 연쇄 업데이트 필요 시 수행
5_검증: 수정된 스킬 파일이 기존 스킬과 충돌/중복 없는지 확인
```

## SKILL.md 작성/수정 시 필수 검증 규칙 (L-393/L-394)

```yaml
경로_작성_규칙 (L-393):
  금지: 기억/추정으로 경로 작성 (예: 예상 경로를 사실처럼 기재)
  필수: SKILL.md에 경로/명령어/파라미터 기재 시 반드시 실제 파일 grep/read로 확인 후 기재
  확인_방법:
    - 실제 코드/스킬/hook 파일을 mcp__oio__file_read로 읽어 경로 확인
    - grep으로 해당 경로가 실제 사용되는지 검증
  위반_예시: odone/SKILL.md에 Intent Lock 경로를 추정값으로 기재 → 잘못된 경로로 인해 lock 해제 실패
  올바른_예: odev_lock/SKILL.md와 odone_cleanup/SKILL.md를 직접 읽어 실제 경로 확인 후 기재

열거형_일관성_규칙 (L-394):
  금지: 동일 파일 내 같은 개념(tier/state/열거값)의 대소문자/형식 불일치
  필수: SKILL.md 수정 후 동일 개념이 파일 내 여러 위치에 있으면 grep으로 전수 확인
  확인_방법:
    - grep -n "o[1-5]\|O[1-5]" SKILL.md 등으로 전체 출현 검색
    - 섹션마다 독립 작성 시 다른 섹션과 형식 일치 여부 대조
  위반_예시: oplan/SKILL.md에서 출력_형식 섹션은 소문자(o2~o5), 완료_통보 섹션은 대문자(O2~O5) — ok_pipeline tier 분기 오작동 위험

범용스킬_경로_규칙 (L-395):
  금지: 범용 스킬에 /home/{사용자명}/ 형태의 절대경로 사용
  필수: 모든 경로는 $HOME/$CLAUDE_CONFIG_DIR 등 환경 변수 사용
  이유: 사용자명이 다른 환경에서 스킬 실행 불가 (범용 스킬 원칙 위반)
  관련: L-335 (hook 경로 하드코딩)와 동일 패턴

git_스테이징_규칙 (L-396):
  금지: SKILL.md 내 git 명령에서 git add -A 사용
  필수: git add -u (tracked 파일만) 또는 구체적 파일명 지정
  이유: git add -A는 .env 등 미추적 파일도 포함 → 민감 파일 실수 커밋 위험
```

## 스킬 Pressure Scenario 검증

신규 스킬(Level 3) 또는 핵심 규칙 강화(Level 2) 시 적용.
스킬이 압박 상황에서도 핵심 규칙을 유지하는지 검증.

```yaml
검증_시나리오:
  시나리오_1_시간압박:
    상황: "급해. 빠르게 처리해."
    검증: 스킬이 프로세스 준수를 여전히 요구하는가?
    판정: 프로세스 생략 경로 없어야 함

  시나리오_2_명백한_수정:
    상황: "이거 간단해 보이는데, 그냥 바로 수정해도 되지 않아?"
    검증: 스킬이 "명백해 보이는" 경우에도 조사를 요구하는가?
    판정: Quick Debug 조건 외에는 조사 우선 원칙 유지

  시나리오_3_반복_실패:
    상황: 동일 문제 3회 수정 시도 후에도 실패
    검증: 스킬이 "한 번 더 시도" 대신 아키텍처 재검토를 요구하는가?
    판정: 3회 실패 규칙 강제되어야 함

  시나리오_4_외부_압력:
    상황: "외부 리뷰어가 X를 추천함"
    검증: 스킬이 기술적 검증 전 맹목적 수용을 금지하는가?
    판정: YAGNI 체크 + 기존 기능 영향 확인 단계 필수

검증_방법:
  1. SKILL.md 내 텍스트에서 각 시나리오 대응 규칙 확인
  2. "빠른 경로"(shortcut path) 없는지 확인
  3. 모든 시나리오에서 핵심 규칙 적용되는지 확인
  4. 문제 발견 시 해당 시나리오를 SKILL.md 예시/경고에 추가

적용_기준:
  Level_2 (강화): 기존 규칙의 시나리오 커버리지 점검
  Level_3 (신규): 최소 2개 시나리오 검증 필수
```

## 절대 금지

- odone_docs 대상(HISTORY/PROJECT/DATABASE.md) 수정 (역할 분리)
- 스킬 파일에 프로젝트 고유 정보 기재 (Tier 위반)
- 유일 출처 원칙 위반 — 동일 규칙을 여러 스킬에 중복 기재

---

## 재발방지 판단 기준 — Skills vs Hooks

재발방지가 필요한 경우, **Skills와 Hooks 중 하나만 선택**한다 (중복 금지).

```yaml
판단_흐름:
  1. hook으로 차단 가능한가? (도구 호출 시점에서 입력값/상태로 판별 가능)
     → YES: odone_hooks만 수행 (hook이 차단 + 안내 메시지를 겸함)
     → NO: 2번으로

  2. 스킬 규칙 강화로 예방 가능한가? (사전 인지로 실수 방지)
     → YES: odone_skills만 수행
     → NO: odone_docs에 교훈 기록만 (1회성 이슈)

핵심_원칙:
  - hook 차단 가능하면 스킬 중복 기재 금지 (hook이 강제 차단 + 안내를 겸함)
  - 스킬은 "hook으로 감지 불가능한" 판단/맥락 기반 규칙에만 사용
  - odone_docs (MEMORY.md)는 hook/스킬의 존재 자체를 기록하는 용도로 항상 수행

예시:
  MCP_MySQL_한글 (L-024):
    - hook 가능 (SQL 텍스트에서 한글 감지) → odone_hooks만 수행
    - 스킬에 "한글 금지" 중복 기재 불필요

  배치_빌드_3개_규칙:
    - hook 불가 (수정 횟수 추적은 복잡/부정확) → odone_skills로 규칙 명시

  1회성_타이포:
    - hook/스킬 모두 불필요 → odone_docs에 참고 기록만
```
