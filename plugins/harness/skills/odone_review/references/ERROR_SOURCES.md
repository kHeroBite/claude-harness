# Step 0.5: 오류 추적 (6-소스 수집)

```yaml
목적: 세션 중 발생한 모든 오류를 빠짐없이 수집하여 Step 1 점검의 입력으로 활용

오류_6분류:
  소스_A (자동감지): hook 차단 로그 — 시스템이 자동 기록
  소스_B (자동감지): Bash 실패 — 트랜스크립트에서 exit code 스캔
  소스_C (사용자지적): 사용자 피드백 — 모델이 스스로 감지 못한 오류 (가장 중요)

⚠️ 알려진_제약 (L-040):
  - Claude Code PostToolUse hook은 Bash 도구 실패(exit code != 0) 시 호출되지 않음
  - 따라서 error_tracker.sh는 Bash 에러(cp 실패, ls 실패 등)를 감지할 수 없음
  - 보완: 소스 B(트랜스크립트 스캔)로 누락된 Bash 에러를 반드시 수집

소스_A: error_tracker.sh 로그 (PostToolUse hook — 성공한 도구에서 감지한 오류)
  파일: $HOME/.claude/session-env/${UUID}/errors.md (세션별 파일, 와일드카드 탐색)
  절차:
    1. $HOME/.claude/session-env/${UUID}/errors.md 파일 존재 여부 확인
    2. 존재 시: 전체 내용 읽기 → 미해결/해결됨 항목 분류
    3. 미해결 항목: Step 1의 "1_도구_오류" 점검에 자동 포함 (YES 처리)
    4. 해결됨 항목: 오류→해결 쌍으로 묶어 Step 2 분석 대상에 포함

소스_B: 트랜스크립트 에러 스캔 (Bash 실패 보완 — 필수)
  ⚠️ Claude Code 제약: Bash exit≠0 시 PostToolUse 미호출 → 이 소스가 유일한 Bash 실패 감지 경로
  파일: 현재 세션의 transcript_path (.jsonl)
  절차:
    1. Grep으로 트랜스크립트에서 "Exit code" 패턴 검색
       Grep pattern="Exit code [1-9]" path="{transcript_path}" output_mode="content" -C=2
    2. 또는 Bash: grep -c "Exit code [1-9]" "{transcript_path}" 로 실패 횟수 확인
    3. 실패 항목 발견 시: 명령어와 에러 메시지 추출 → error_log에 추가
    4. 소스 A와 중복 제거 (동일 명령+동일 에러 = 1건으로 합산)
  감지_패턴:
    - "Exit code [1-9]" — Bash 도구 실패
    - "Error:" — 도구 에러 응답
    - "cannot stat", "No such file", "permission denied" — 파일 작업 실패
  제외_패턴 (의도적 실패):
    - tasklist.exe, grep (프로세스 존재 확인용 — exit code 1이 정상)
    - 2>/dev/null 포함 명령 (에러 무시 의도)

소스_C: 사용자 피드백 (모델 미감지 오류 — 최우선, 2중 메커니즘)
  중요도: 소스 A/B보다 높음 — 모델이 스스로 감지 못한 오류이므로 교훈 가치 최대
  원칙: 사용자의 모든 지적/수정 요청은 반드시 error md에 기록되어야 함

  메커니즘_1_실시간_기록 (발생 즉시):
    시점: 사용자 메시지 수신 시점 (오케스트레이터가 분류할 때)
    조건: 사용자 메시지가 아래 피드백 패턴에 해당
    동작: write_error.sh의 log_hook_error 호출하여 error md에 즉시 기록
      category: USER_FEEDBACK
      tool_name: 해당 작업 단계 (ok/odev/otest 등)
      reason: 사용자 원문 + 모델이 한 행동 요약
    ID_형식: UFBK-N (User FeedBacK)
    효과: error md에 실시간 누적 → odone_review에서 자동 수집됨

  메커니즘_2_사후_보완_스캔 (odone_review 시점 — 누락 방지):
    시점: odone_review Step 0.5
    파일: 현재 세션의 transcript_path (.jsonl)
    목적: 메커니즘 1에서 누락된 피드백 보완 수집
    절차:
      1. 트랜스크립트에서 사용자 메시지(type: "human") 추출
      2. 피드백 패턴 매칭으로 지적 항목 식별
      3. error md에 이미 UFBK로 기록된 항목은 스킵 (중복 제거)
      4. 누락 항목만 UFBK-N으로 추가

  감지_패턴:
    불만/지적: "다시", "또", "잘못", "왜 안", "아니", "그게 아니", "안 됐", "빠졌", "누락"
    수정_요청: "~하지 말고", "~로 바꿔", "이미 말했", "방금 말한", "아까"
    반복_지시: 동일 요청 2회+ (첫 번째 실행이 불충분했다는 의미)
  제외_패턴:
    - 순수 추가 요청: "추가로 ~도 해라" (불만이 아닌 새 요구)
    - 질문: "이거 뭐야?", "~인가?" (정보 요청)
    - 긍정 피드백: "좋다", "됐다", "오케이"
  분석_항목 (각 UFBK):
    what: 사용자가 지적한 내용 (원문 인용)
    model_action: 지적 직전 모델이 한 행동
    root_cause: 왜 모델이 잘못했는가 (판단오류/규칙미숙지/정보부족 등)
    severity: 높음(2회+ 반복지적) / 중간(1회 지적, 핵심기능) / 낮음(1회 지적, 사소)

소스_D: 모델 오류 감지 (환각/잘못된 판단 — 자동 감지 불가, 트랜스크립트 사후 분석)
  중요도: 자동 도구로 감지 불가 — 트랜스크립트 전체 흐름 분석으로만 식별 가능
  감지_패턴:
    - 사용자 지적 후 정정: 모델이 틀린 답/행동 → 사용자 "아니" → 모델 정정
    - 존재하지 않는 경로/함수 참조 후 에러: 모델이 없는 파일/메서드를 언급 → 도구 호출 시 에러
    - 도구 호출 결과와 이전 설명 불일치: 모델이 "A가 있다"고 설명 → 실제 도구 결과는 B
  절차:
    1. 트랜스크립트에서 모델 응답 → 도구 에러 → 모델 정정 패턴 탐색
    2. 사용자 지적("아니", "그게 아니라") 직전 모델 응답 분석
    3. 발견 시: MERR-N ID 부여 (Model ERRor)
    4. root_cause 분류: 환각(hallucination) / 판단오류(misjudgment) / 정보부족(info_gap)
  ID_형식: MERR-N (Model ERRor)

소스_E: errors.md 통합 분석
  파일: $HOME/.claude/session-env/${UUID}/logs/errors.md
  절차:
    1. 파일 존재 여부 확인 (없으면 소스_E 스킵)
    2. 존재 시: 전체 내용 읽기
    3. [oplan]/[odev]/[otest] 섹션별 오류 파악
    4. 미해결 오류 → "도구_오류" 점검 항목에 포함
    5. 해결됨 오류 → 재발방지 교훈 후보로 분류
    6. 기존 소스(A/B/C/D)와 중복 제거 후 통합

소스_F: 단계별 결과 파일 교차 분석
  파일들:
    - $HOME/.claude/session-env/${UUID}/plans/oplan_{대화ID}.md (계획서 + 맥락노트 + TODO)
    - $HOME/.claude/session-env/${UUID}/logs/odev_{대화ID}.md (수정파일 + 이유 + 방법)
    - $HOME/.claude/session-env/${UUID}/logs/otest_{대화ID}.md (빌드/런타임/품질 검증)
  절차:
    1. 각 파일 glob으로 탐색 (파일 없으면 해당 소스 스킵)
    2. 각 파일의 "오류" 또는 "미해결" 키워드 검색
    3. 기존 소스 A~E와 교차 대조 → 미수집 오류 보완
    4. 계획 대비 실제 구현 차이 분석 (oplan vs odev 파일 대조)
    5. 발견된 차이점/문제점 → 교훈 분석 입력 데이터로 활용
  활용: 5W1H 분석의 "Where/When" 정밀화에 사용
  주의: 파일 미존재 시 해당 소스 스킵 (오류 없이 진행)

통합_절차:
  1. 소스 A 수집 (error_tracker.sh 로그)
  2. 소스 B 수집 (트랜스크립트 스캔)
  3. 소스 C 수집 (사용자 피드백 스캔)
  4. 소스 D 수집 (모델 오류 감지)
  5. 소스 E 수집 (error_{대화ID}.md)
  6. 소스 F 수집 (단계별 결과 파일 교차 분석)
  7. 중복 제거 후 통합
  8. $HOME/.claude/session-env/${UUID}/logs/review_actions.json의 error_log 필드에 포함
  9. 오류 0건이면 즉시 Step 1로 진행

활용:
  미해결_항목: "아직 해결 안 된 오류가 있다" → 심각도 높음
  해결됨_항목: "오류 발생 → 해결 패턴" → 재발방지 교훈 후보
  오류_없음: Step 0.5 즉시 완료, Step 1로 진행

error_log_JSON_필드:
  {
    "error_log_file": "$HOME/.claude/session-env/${UUID}/errors.md",
    "transcript_errors": 2,
    "user_feedback_errors": 1,
    "total_errors": 6,
    "unresolved": 1,
    "resolved": 5,
    "errors": [
      {
        "id": "ERR-1",
        "source": "hook",
        "category": "BUILD_FAILED",
        "status": "해결됨",
        "resolution": "빌드 오류 수정 후 재빌드 성공"
      },
      {
        "id": "TERR-1",
        "source": "transcript",
        "category": "FILE_NOT_FOUND",
        "command": "cp HISTORY.md ...",
        "status": "미해결",
        "detail": "No such file or directory"
      },
      {
        "id": "UFBK-1",
        "source": "user_feedback",
        "category": "USER_FEEDBACK",
        "user_said": "아니 그게 아니라 ~해야지",
        "model_action": "사용자 요청을 잘못 해석하여 다른 파일 수정",
        "root_cause": "요구사항 해석 오류",
        "status": "해결됨",
        "severity": "중간"
      }
    ]
  }

세션_종료_시: odone_git에서 커밋 후 push 전에 error log 포함 모든 세션 임시파일 일괄 삭제 (odone_git "세션 임시파일 삭제" 섹션 참조)
```
