---
name: otest_ui
description: "Frontend 구현 검증 — oplan UI 검수조건 대조. 스크린샷 비교 + FlaUI/Playwright 자동화 통합."
invocation:
  user_callable: true
  pipeline_callable: true
  called_by: ["otest(Phase 2)"]
  calls: [otest_winforms, otest_playwright, otest_playwright_bg, otest_ux]
---

# otest_ui — Frontend 구현 검증

## 역할

acceptance_criteria.json의 category=frontend 항목을 검증한다.
otestuiwinforms (FlaUI/WinForms) + otestui (스크린샷+API) + otest_ui_rules 로직 통합.

## 진입 시 UUID 결정

```bash
UUID=$PIPELINE_UUID
```

## tier별 적용 조건

```yaml
o3: ui_touched.json.touched 우선 (부재 시 git diff 폴백)
o4: ui_touched.json.touched 우선 (부재 시 git diff 폴백)
o5: ui_touched.json.touched 우선 (부재 시 항상 필수 — 현행 유지)
     단, user_override=true면 무조건 실행

UI_파일_감지 (ui_touched.json 부재 시 폴백):
  대상: *.xaml, *Designer.cs, View*.cs, ViewModel*.cs, *.razor, *.vue, *.tsx
  방법: git diff HEAD -- {ui_file_patterns} 출력 존재 여부 확인
  o5: 파일 변경 여부 무관 항상 실행

ui_touched.json_우선_판단:
  경로: $HOME/.claude/session-env/${UUID}/evidence/ui_touched.json
  touched=true  → UI 테스트 실행 (git diff 무관)
  touched=false → UI 테스트 건너뜀 (ui_test_done_skipped 생성)
  부재          → 기존 git diff 폴백 사용
  user_override=true → 모든 tier 무조건 실행
```

## 자동화 도구 선택 (서브스킬 라우팅)

otest_ui는 프로젝트 유형에 따라 아래 4개 서브스킬 중 하나를 선택하여 호출:

| 프로젝트 유형 | 서브스킬 | 설명 |
|-------------|---------|------|
| WinForms/WPF | Skill('otest_winforms') | FlaUI/UIAutomation 자동화 |
| 웹 (Playwright) | Skill('otest_playwright') | 브라우저 자동화 |
| 웹 (백그라운드) | Skill('otest_playwright_bg') | Playwright 백그라운드 실행 |
| 모바일 (.NET MAUI Android) | Skill('otest_mobile') | ADB + 스크린샷 + UI dump + 좌표 클릭 |
| 범용 (스크린샷) | Skill('otest_ux') | 스크린샷 시각분석 + API + 로그 |

```yaml
도구_선택_순서:
  1순위: oinfra_{project}의 ui_test.tool 값 (프로젝트별 고정)
    otest_ui 진입 시 Skill('oinfra_{project}')에서 ui_test.tool 확인
    값이 있으면 해당 서브스킬 즉시 호출
  2순위: git diff 확장자 기반 자동 판정 (oinfra 미정의 시 fallback)
    *.Designer.cs, *.xaml → otest_winforms
    *.razor, *.vue, *.tsx → otest_playwright_bg
    그 외 → otest_ux

프로젝트별_고정_현황:
  각 프로젝트의 oinfra_{project} 스킬에 UI 테스트 도구를 명시한다.
  미정의 시 위 2순위(확장자 기반 자동 판정)로 폴백한다.
  예: C# WinForms → otest_winforms / 웹 프론트 → otest_playwright_bg / API 전용 → otest_ux

창_최소화:
  otest_playwright 호출 시: 창 최소화 자동 처리됨 (WSLg + xdotool)
  상세: otest_playwright/SKILL.md "창 최소화 패턴" 섹션 참조

otest_ui_rules: 이 스킬 본체에 흡수됨 (별도 스킬 미호출)
oss: 유틸리티로 독립 유지 (otest_ux 내부에서 호출)
```

## 실행 절차

```yaml
Step_1_criteria_로드:
  파일: $HOME/.claude/session-env/${PIPELINE_UUID}/plans/acceptance_criteria.json
  필터: category = frontend
  없을_경우: ui_test_done_skipped 증거 생성 후 종료

Step_1.5_ui_touched_확인:
  시점: Step_1(criteria 로드) 완료 후, Step_2(UI 변경 감지) 진입 전
  절차:
    1. ui_touched.json 읽기:
       mcp__oio__file_read(path="$HOME/.claude/session-env/${UUID}/evidence/ui_touched.json")
    2. 사용자 override 우선:
       user_override=true 또는 USER_FORCE_UI=1 환경변수 → Step_3으로 직진
    3. touched=false → ui_test_done_skipped 생성 후 종료:
       mcp__oio__file_write(path=".../evidence/ui_test_done_skipped",
         content="ui_touched.json: touched=false (decided_by={oplan|odone})")
    4. touched=true 또는 ui_touched.json 부재 → Step_2 진행 (기존 흐름)

Step_2_UI_변경_감지 (o3/o4):
  방법: git diff HEAD -- *.xaml *Designer.cs View*.cs ViewModel*.cs *.razor *.vue *.tsx
  변경_없음: ui_test_done_skipped 생성 후 종료
  변경_있음: Step_3 진행
  o5: 이 단계 스킵, Step_3 직행

Step_3_화면_조작_재현:
  acceptance_criteria.json의 ui_flow (조작 순서) 로드
  각 화면별:
    1. 화면 열기 (선택된 서브스킬(otest_winforms/otest_playwright/otest_ux)로 위임)
    2. 입력값 설정
    3. 버튼 클릭 / 이벤트 발생
    4. 결과 상태 캡처

Step_4_스크린샷_비교:
  기준: acceptance_criteria.json의 expected_screenshot 또는 expected_state
  실제: oss로 현재 화면 캡처 (Skill('oss'))
  비교:
    Claude 시각 분석: 레이아웃/컨트롤 배치/텍스트 일치
    자동화: 컨트롤 속성값 비교 (FlaUI AutomationElement)
  판정:
    일치: PASS
    불일치: 스크린샷 저장 + diff 기록

Step_5_UX_품질_검증:
  항목:
    - 컨트롤 활성화/비활성화 상태
    - 에러 메시지 표시 여부
    - 로딩 상태 처리
    - 반응형 레이아웃 (해당 시)
  기준: acceptance_criteria.json의 ux_quality 항목

Step_6_판정:
  must 전부 PASS → ui_test_done 생성
  must 1건이라도 FAIL:
    실행_오류 (자동화 실패, 화면 미표시): odev 권고
    결과_불일치 (UI 상태 다름, UX 기준 미충족): oplan 권고
```

## 실패 판정 세분화

```yaml
odev_권고_조건:
  - FlaUI/Playwright 자동화 실행 오류
  - 화면이 열리지 않음
  - 컨트롤 미발견 (AutomationId 없음)
  - 런타임 예외

oplan_권고_조건:
  - UI 레이아웃 기준 불일치
  - 컨트롤 배치/텍스트 오류
  - UX 품질 기준 미충족
  - 요구사항 UI 기능 미구현
```

## 증거파일 생성

```bash
UUID=$PIPELINE_UUID
# 성공 시
touch "$HOME/.claude/session-env/${UUID}/evidence/ui_test_done"    # EXT4($HOME) — oio 불필요
touch "$HOME/.claude/session-env/${UUID}/evidence/web_test_done"   # EXT4($HOME) — 웹 프로젝트 판별용
# 스크린샷 저장
# 스크린샷 저장 — mcp__oio__file_copy(source, destination) 사용 (Bash cp 금지)
# 건너뜀 시
touch "$HOME/.claude/session-env/${UUID}/evidence/ui_test_done_skipped"  # EXT4($HOME) — oio 불필요
```

## 스크린샷 캡처 방법 (우선순위)

```yaml
1순위_noactivate_모드 (창 방해 없음):
  명령: {curl_cmd} -s --max-time 30 -o "{save_path}" "http://localhost:5959/api/screenshot/download?noactivate=1"
  장점: 창 활성화/포커스 변경 없이 캡처 가능 (최소화/백그라운드 상태 포함)
  동작: SW_SHOWNOACTIVATE → PrintWindow → SW_MINIMIZE (캡처 후 원상 복구)
  실패_시: 흰/검은 화면 → 2순위로 fallback

2순위_일반_모드 (window/activate 선행):
  명령:
    {curl_cmd} -s -X POST http://localhost:5959/api/window/activate -H "Content-Type: application/json" -d "{\"handle\":-1}"
    {curl_cmd} -s --max-time 30 -o "{save_path}" http://localhost:5959/api/screenshot/download

3순위_oss (API 없는 환경):
  Skill('oss') — WSL2 클립보드 기반 캡처

자동_선택:
  파이프라인 테스트: 1순위 noactivate 우선 시도
  사용자 직접 검증: 2순위 일반 모드 (현재 화면 정확히 캡처)
```

## 스크린샷 저장 규칙

```yaml
저장_경로: $HOME/.claude/session-env/${UUID}/evidence/
파일명: screenshot_{화면명}_{timestamp}.png
비교_저장: expected_{화면명}.png vs actual_{화면명}.png 쌍으로 저장
도구: 위 "스크린샷 캡처 방법" 1~3순위 참조
```

## 결과 보고 형식

```yaml
보고_시점: Step 6 판정 직후
전달_대상: otest 메인 (호출자)
형식:
  PASS: "ui_test_done — must:{N}건 PASS / 스크린샷:{N}장 저장"
  FAIL: "ui_FAIL — 실패:{N}건\n{화면명}: {expected} → {actual}\n스크린샷:{경로}\n권고:{odev|oplan}"
  SKIP: "ui_test_skipped — UI 변경 없음 / frontend 항목 없음"
```

## Bash 규칙

```yaml
절대_금지: "&&", "||", ";", "|" 연산자 사용한 명령어 체이닝
각_명령어: 별도 Bash 호출로 분리
timeout_작업: run_in_background: true
```
