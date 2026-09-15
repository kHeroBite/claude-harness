# oinsights — Phase 8: /tmp 히스토리 기반 프로세스 점검

> oinsights SKILL.md Phase 8에서 분리된 상세 절차.

### Step 8-1: 히스토리 수집

현재 세션의 UUID 디렉토리를 탐색하여 보존된 파일 인벤토리 생성:

```bash
# [P2-isolation §(c)] Fix 36: find session-env/* 전체 순회 → 자기 세션(CURRENT_UUID)만으로 제한
# 타 세션 UUID를 echo로 stdout 출력하면 §(c) 위반이므로 UUID 출력 없이 파일 통계만 표시
source "${HARNESS_HOOK_DIR}/lib/session_id.sh"
resolve_uuid ""
CURRENT_UUID="${UUID:-}"
if [ -z "$CURRENT_UUID" ]; then
  echo "⚠️ UUID 결정 실패 — Step 8-1 스킵"
else
  DIR="$HOME/.claude/session-env/${CURRENT_UUID}"
  echo "=== 현재 세션 히스토리 ==="
  # 오류 로그
  ERRORS="$DIR/logs/errors.md"
  [ -f "$ERRORS" ] && echo "  errors.md: $(grep -c '^### ERR' "$ERRORS" 2>/dev/null)건"
  # 사용자 발화
  PROMPT="$DIR/plans/user_prompt.md"
  [ -f "$PROMPT" ] && echo "  user_prompt: $(head -1 "$PROMPT" | cut -c1-80)"
  # oplan 계획서
  PLANS=$(ls "$DIR/plans/oplan_"*.md 2>/dev/null | wc -l)
  [ "$PLANS" -gt 0 ] && echo "  oplan_*.md: ${PLANS}개"
  # 트랜스크립트
  TRANSCRIPTS=$(ls "$DIR/logs/otest_conv_"*.md 2>/dev/null | wc -l)
  [ "$TRANSCRIPTS" -gt 0 ] && echo "  otest_conv_*.md: ${TRANSCRIPTS}개"
  # review_actions
  REVIEW="$DIR/logs/review_actions.json"
  [ -f "$REVIEW" ] && echo "  review_actions.json: $(python3 -c \"import json; d=json.load(open('$REVIEW')); print(len(d.get('actions',[])), '액션')\" 2>/dev/null)"
fi
```

### Step 8-2: 6-소스 통합 분석

각 파일 유형별 분석 항목:

```yaml
소스A_errors.md:
  - 오류 빈도: 동일 카테고리 2회+ → 반복 패턴
  - 오탐 감지: 성공 로그(✅)가 오류로 기록된 경우 → error_tracker.sh 패턴 수정 필요
  - 미해결 항목: 상태 "미해결" + LESSONS.md 미반영 → 즉시 반영 필요

소스B_user_prompt.md:
  - 사용자 요청 패턴: 반복 요청 유형 분석 (hook 수정 / 스킬 개선 / 버그 수정 등)
  - 요청→오류 연계: 어떤 발화가 어떤 오류를 유발했는지 추적

소스C_oplan_계획서:
  - 계획 품질: oplan_final.md 존재 여부 (o4/o5 단계 토론 완료 여부)
  - 계획 대비 실제: 계획된 파일 수 vs 실제 수정 파일 수 비교 (odone_git 결과와 대조)
  - 반복 설계 오류: 동일 모듈 재설계 패턴 감지

소스D_트랜스크립트(otest_conv_*.md):
  - 빌드 실패 패턴: BUILD_FAILED 반복 키워드 추출
  - 역라우팅 빈도: TEST→DEV / TEST→PLAN 역라우팅 횟수
  - 에이전트 오류: 모델 오류 / 비정상종료 패턴

소스E_review_actions.json:
  - Level 3 미처리: actions[]에서 level=3이지만 실행 기록 없는 항목
  - pending_items: 다음 세션으로 넘겨진 항목 누적 여부
  - error_log: 반복 오류 패턴 → 자동 LESSONS 승격 후보

출력_형식: |
  | UUID | 발화요약 | 오류수 | 오탐 | 계획완성도 | review액션 | 비고 |
  |-----|----------|--------|------|------------|------------|------|
```

### Step 8-3: 개선 제안 생성

```yaml
제안_기준:
  errors.md: 동일 카테고리 2회+ → LESSONS.md L-3 자동 승격 제안
  errors.md: 오탐 감지 → error_tracker.sh 패턴 수정 제안
  user_prompt.md: 반복 발화 유형 → 자동화/스킬화 제안
  oplan: 계획 vs 실제 괴리 큼 → oplan_review 강화 제안
  트랜스크립트: 역라우팅 2회+ → 해당 단계 설계 재검토 제안
  review_actions: Level 3 미처리 누적 → 즉시 처리 강제 제안

제안_형식: 전체 자동 적용 (사용자 확인 없이 순차 실행)
  옵션_예시:
    - "[오류패턴] FILE_SYNC_ERROR 3회 → LESSONS.md L-3 승격"
    - "[오탐수정] error_tracker.sh 성공로그 오감지 패턴 제거"
    - "[자동화] 동일 hook 수정 요청 3회 → odone_hooks 물리 차단 추가"
    - "[계획품질] oplan 계획 파일수 vs 실제 괴리 → oplan_review 체크 강화"
    - "[역라우팅] TEST→DEV 반복 → 해당 모듈 oplan_deep 적용"
    - "[미처리] review_actions Level3 2건 미처리 → 즉시 반영"
```

### Step 8-4: 승인 항목 실행

```yaml
실행_대상:
  LESSONS_추가: odone_docs 절차에 따라 LESSONS.md 교훈 추가
  hook_수정: error_tracker.sh 오탐 패턴 수정 (odone_hooks 절차)
  스킬_수정: odone_review ERROR_SOURCES.md 소스 강화
  즉시반영: review_actions Level3 미처리 항목 → odone_hooks/odone_skills 즉시 실행

실행_불가_시: "다음 odone 시점에 반영 예정" 메모만 남기고 스킵
```

### Step 8-5: session-env 정리

> **[P2-isolation] §(a)(c)(d) 위반으로 제거됨 (2026-04-24)**
>
> 이전 구현: `session-env/*/` 전체 순회 후 IDLE 세션 `rm -rf` → 타 세션 삭제 (§(a) 쓰기 경계 위반),
> 타 UUID 전체 stdout 노출 (§(c) 정보 노출 금지 위반), 타 세션 stale 회수 (§(d) stale 회수 모델 위반).
>
> **대안**: session-env 정리는 각 세션의 SessionStart.sh가 자기 세션만 처리.
> oinsights는 분석/개선 반영(Step 8-1~8-4)만 수행. 디스크 정리는 담당하지 않음.
