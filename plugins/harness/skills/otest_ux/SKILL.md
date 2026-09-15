---
name: otest_ux
description: "범용 UX 테스트 — 스크린샷 시각분석 + REST API 검증 + 로그 삼각검증. otest_ui에서 호출. 기존 otestui 흡수."
invocation:
  user_callable: true
  pipeline_callable: true
  called_by: ["otest_ui"]
  calls: ["oss"]
---

# otest_ux — 범용 UX 테스트 (삼각검증)

## 개요

스크린샷 시각 분석 + REST API 검증 + 로그 분석 삼각검증 스킬.
프로젝트별 경로/엔드포인트는 `oinfra_{project}`에서 주입받는다.

## 사전 준비 — 프로젝트 설정 확인

oinfra_{project} 로드 후 아래 값을 확인한다:

```yaml
필수_확인:
  screenshot_api: http://localhost:{port}/api/screenshot/download
  window_activate_api: http://localhost:{port}/api/window/activate
  log_path: {앱별 로그 경로}
  log_api: http://localhost:{port}/api/logs/latest
  curl_cmd: {플랫폼별 curl 경로}
```

oinfra 없을 경우 → 사용자에게 포트/경로 확인 요청.

## 스크린샷 캡처 모드

```yaml
일반_모드 (창 활성/포그라운드 상태):
  절차:
    1. {curl_cmd} -s -X POST {window_activate_api}   # 창 활성화
    2. sleep 1
    3. {curl_cmd} -s --max-time 30 -o "{path}" {screenshot_api}
  특징: CopyFromScreen — 실제 화면 그대로 캡처

noactivate_모드 (창 최소화/백그라운드 상태):
  절차:
    {curl_cmd} -s --max-time 30 -o "{path}" "{screenshot_api}?noactivate=1"
  특징:
    - window_activate 호출 불필요
    - SW_SHOWNOACTIVATE(4)로 포커스 없이 복원 → PrintWindow 캡처 → SW_MINIMIZE(6)로 재최소화
    - 캡처 후 창이 다시 최소화됨 (사용자 작업 방해 없음)
    - 스크린샷 API 를 제공하는 앱에서만 사용 가능 (앱 측 구현 필요)
  사용_시점:
    - 사용자가 다른 앱을 사용 중일 때
    - CI/자동화 환경에서 포그라운드 없이 테스트할 때
    - 창을 최소화한 채로 UI 상태 검증할 때
  주의:
    - 검은 화면/흰 화면이면 일반 모드로 fallback
    - 최소화 상태의 창 크기는 RestoreBounds 기준

자동_선택_로직:
  창_상태_확인: {curl_cmd} -s {base_url}/api/window/state
  minimized=true → noactivate=1 모드 사용
  minimized=false → 일반 모드 사용

playwright_연계:
  otest_playwright(opw) 경유 시: 창 최소화 자동 처리됨 (WSLg + xdotool)
  상세: otest_playwright/SKILL.md "창 최소화 패턴" 섹션 참조
  otest_ux 직접 호출 시: 해당 없음 (API 기반 캡처 사용)
```

## 삼각검증 절차

### 1단계: 스크린샷 시각 분석

```bash
# 방법 A: 일반 모드 (창 활성 상태)
{curl_cmd} -s -X POST {window_activate_api}
{curl_cmd} -s --max-time 30 -o "{screenshot_save_path}" {screenshot_api}

# 방법 B: noactivate 모드 (최소화/백그라운드 — 창 방해 없음)
{curl_cmd} -s --max-time 30 -o "{screenshot_save_path}" "{screenshot_api}?noactivate=1"
```

Skill('oss') 또는 Read 도구로 PNG 열어 시각 분석:

```yaml
판독_기록_형식:
  📸 스크린샷 판독 결과
  ├─ 촬영: {폼명/화면명}
  ├─ 체크리스트:
  │   ✅/❌ {항목}: {실제 관측값}
  ├─ 빈공간 탐색: {탐색 결과 — 없음/발견됨}
  └─ 종합 판정: PASS / FAIL (근거: {1줄})
```

### 정밀 판독 원칙

```yaml
금지_판정:
  - "있어 보임" / "정상인 것 같음" / "전체적으로 괜찮음" → FAIL (추측 기반)
  - 스크린샷 Read 후 "정상입니다"만 출력
  - 수치값 없이 판정

필수_판정:
  - 숫자값: 실제 값 읽어 기록 (예: "X.X억")
  - 레이아웃: "오른쪽 끝까지 채워짐 확인" 명시
  - 텍스트: 실제 내용 문자 단위로 기록

빈_공간_적극_탐색 (필수):
  탐색_대상: 행/열 마지막 요소 오른쪽, 위젯/차트 여백, 그리드 마지막 셀 이후
  발견 → FAIL / 없음 → 명시 후 PASS

구역별_독립_검증:
  1. UI를 논리 구역으로 분할 (상단헤더/중앙메인/하단푸터 등)
  2. 각 구역 독립 PASS/FAIL 판정
  3. 변경 구역 집중 검증
  결과_표:
    | 구역 | 변경여부 | 판정 | 근거 |
    |------|---------|------|------|

수치_일관성_검증 (데이터 변경 시):
  1. 스크린샷 수치 기록: "화면명: 금년={X.X억}, 작년={X.X억}"
  2. REST API 응답값 대조: "API: data.value={X.X}, 화면={X.X} → 일치/불일치"
  3. PASS기준: ±1만원 이내 (반올림 오차 허용)
```

### 2단계: REST API 검증

```bash
# 헬스 체크
{curl_cmd} -s --max-time 10 {base_url}/api/health

# 기능별 엔드포인트
{curl_cmd} -s --max-time 10 {base_url}/api/{endpoint}
```

```yaml
통과_조건:
  - HTTP 200
  - 응답 데이터 기대값 일치
실패_시: 응답 본문 + 상태코드 기록
```

### 3단계: 로그 분석

```bash
# API 경유 (권장)
{curl_cmd} -s --max-time 10 "{log_api}?lines=100"

# 직접 파일 읽기 (fallback)
# Read {log_path}
```

```yaml
통과_조건:
  - ERROR / Exception 0건
  - 예상 동작 로그 존재
```

## 판정 기준

```yaml
PASS: 3단계 모두 통과
WARN: 경미한 레이아웃 이슈 (기능 정상)
FAIL: 2단계 이상 실패 또는 ERROR 로그 존재
```

## 스마트 라우팅 (실패 시)

```yaml
스크린샷_FAIL → UI 렌더링 버그 → odebug 호출
API_FAIL      → 백엔드 오류 → 로그 확인 후 odebug
로그_ERROR    → 예외 추적 → odebug (스택트레이스 포함 전달)
```

## 프로젝트별 세부 설정

모든 프로젝트 설정은 `oinfra_{project}` 스킬의 `test_env` 섹션에서 로드한다.
프로젝트별 별도 references 파일 없음.

프로젝트별 기본 동작:
- 데스크톱 UI 프로젝트: otest_ux 항상 실행 (o2), o3/o4/o5는 otest_ux+otest_winforms
- 스크린샷 API 제공 프로젝트: otest_ux 사용 (oinfra_{project} 에 포트·엔드포인트 명시)
- 스크린샷 API 없는 프로젝트: REST API 검증만 수행

## 완료 증거파일 생성 (필수 — L-240)

otest_ux 완료 시 반드시 실행:
```bash
UUID=$PIPELINE_UUID
touch $HOME/.claude/session-env/${UUID}/evidence/ui_test_done  # EXT4($HOME) — oio 불필요
echo "✅ otest_ux 증거파일 생성: $HOME/.claude/session-env/${UUID}/evidence/ui_test_done"
```
이 명령 없이 o3/o4/o5 작업에서 odone으로 진입 시 ui_test_done_guard.sh hook에 의해 차단됨.
