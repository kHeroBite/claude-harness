---
name: otest_mobile
description: ".NET MAUI Android 모바일 앱 자동화 테스트 — 실기기 우선/에뮬레이터 폴백 자동 선택. ADB 기반 스크린샷·UI Dump·좌표 클릭·키 입력·스와이프·logcat 분석. otest_ui에서 호출하거나 단독 호출 가능."
invocation:
  user_callable: true
  pipeline_callable: true
  called_by: ["otest_ui"]
  calls: []
---

# otest_mobile — .NET MAUI Android 자동화 테스트

## 스크린샷 보고 절대 규칙 (API 400 재발방지)

- PNG/JPG/JPEG/WEBP/GIF/BMP/TIFF/HEIC 등 이미지 파일을 메인 응답에 직접 첨부 절대 금지
- 메인이 Read 도구로 이미지 파일 읽기 시도 시 `image_read_block.sh` hook이 즉시 block 응답 반환
- 허용 보고 형식:
  1. 파일 경로만 텍스트로 (`/mnt/c/.../emu_r7_team.png`)
  2. UI Dump XML 발췌 (`<node text="영업팀" bounds="..." />`)
  3. logcat 텍스트 발췌
  4. 자체 분석 텍스트 (예: "Row 6 X축 5팀 모두 표시, KPI 4.00/5.23/...")
- 위반 시 영향: API 400 오류 → 보고 누락 → 검증 실패 + 사용자 신뢰 손상
- 재발방지: hook이 물리 차단, 본 SKILL.md가 LLM 가이드

## 역할

.NET MAUI Android 앱을 **실기기 우선 / 에뮬레이터 폴백** 정책으로 자동 검증한다. 스크린샷 시각 분석 + UI 요소 좌표 추출 + 좌표 클릭 + 키 입력 + 스와이프 + logcat 에러 추출을 통합한다.

## 디바이스 선택 정책 (절대 규칙)

```yaml
원칙: 폰 있으면 폰만, 없으면 에뮬만 (배타적 분기 — 동시 실행 금지)

선택_순서:
  1. adb devices에서 실기기(emulator- 접두사 없는 시리얼) status=device 1개 이상 → TARGET=실기기
  2. 실기기 unauthorized 상태 → 60초 대기 루프 (5초×12회) → 권한 허용 시 TARGET=실기기
  3. 실기기 미연결 → TARGET=에뮬레이터 (이미 실행 중인 emulator-* 사용)
  4. 에뮬레이터도 미실행 → emulator -avd pixel_5_-_api_34_0 자동 부팅 → boot_completed 폴링 → TARGET=에뮬레이터
  5. 둘 다 불가 → 즉시 실패 보고

TARGET_SERIAL: 선택된 단일 시리얼 (이후 모든 adb 호출에 -s $TARGET_SERIAL 적용 필수)
복수_실기기: 첫 번째 시리얼 사용 (head -1)
```

## 진입 환경 확인

```yaml
도구: adb.exe (Windows Android SDK)
경로: /mnt/c/Program Files (x86)/Android/android-sdk/platform-tools/adb.exe
에뮬레이터(폴백): pixel_5_-_api_34_0 (API 34, 1080x2340)
패키지: com.example.myapp
MainActivity: crc6428e32fee54d832ef.MainActivity
화면 크기: 1080 (가로) × 2340 (세로) — 좌표 기준 (실기기는 해상도 다를 수 있음 → wm size 재확인)
```

## 핵심 명령 매핑 (정본)

```bash
ADB="/mnt/c/Program Files (x86)/Android/android-sdk/platform-tools/adb.exe"
PKG="com.example.myapp"
ACT="crc6428e32fee54d832ef.MainActivity"
# TARGET_SERIAL은 "디바이스 자동 선택" 단계에서 결정됨 (실기기 우선, 폰 미연결 시 에뮬레이터)
# 이후 모든 adb 호출은 "$ADB" -s "$TARGET_SERIAL" ... 형태로 사용
```

### 1. 디바이스 상태 확인

```bash
"$ADB" devices                                                  # 연결된 디바이스 목록
"$ADB" -s "$TARGET_SERIAL" shell getprop sys.boot_completed     # 부팅 완료 (=1)
"$ADB" -s "$TARGET_SERIAL" shell pidof "$PKG"                   # 앱 프로세스 PID
"$ADB" -s "$TARGET_SERIAL" shell "dumpsys activity activities | grep topResumedActivity"
```

### 2. 앱 제어

```bash
"$ADB" shell am start -n "$PKG/$ACT"            # 앱 실행
"$ADB" shell am force-stop "$PKG"               # 앱 강제 종료
"$ADB" shell pm clear "$PKG"                    # 앱 데이터 초기화 (로그아웃 상태)
"$ADB" install -r /path/to/app.apk              # APK 재설치 (Windows 경로 필요)
```

### 3. 스크린샷 (시각 분석)

```bash
# 단일 캡처
"$ADB" exec-out screencap -p > /tmp/screen.png
ls -la /tmp/screen.png                           # 크기 확인 (>10KB 정상)

# Read 도구로 시각 분석:
#   Read(file_path="/tmp/screen.png")
#   Claude가 PNG를 시각적으로 인식하여 분석
```

### 3.1 스크린샷 자동 다운스케일 (필수)

> **배경**: Galaxy Z Fold 등 고해상도 디바이스(1080×2520+)는 PNG 1장이 1MB를 초과하여
> `mcp__oio__file_read`로 읽을 때 PreToolUse hook이 차단하고 Claude API 400 오류가 발생한다.
> ADB 스크린샷 직후 **반드시** 아래 기준으로 다운스케일 후 `_small` 버전을 사용하라.

**다운스케일 트리거 조건 (OR)**:
- 파일 크기 ≥ 1MB (1,048,576 bytes)
- 해상도가 1280×720 초과

**에이전트 적용 절차**:
1. `adb exec-out screencap -p > /tmp/screen.png` 직후 파일 크기 확인:
   ```bash
   FILE_SIZE=$(stat -c%s /tmp/screen.png 2>/dev/null) || FILE_SIZE=0
   ```
2. `FILE_SIZE ≥ 1048576` → `mcp__oio__image_resize` 도구 호출:
   - `path`: `/tmp/screen.png`
   - `output_path`: `/tmp/screen_small.png`
   - `max_width`: 1280
   - `max_height`: 720
3. 이후 이미지 Read / 컨텍스트 첨부는 반드시 `_small` 버전 사용:
   - ✅ `mcp__oio__file_read(path="/tmp/screen_small.png")`
   - ❌ `mcp__oio__file_read(path="/tmp/screen.png")` — 1MB+ 시 hook 차단

**다중 캡처 패턴 B 적용 시**: 각 `chart_${i}.png`마다 동일하게 크기 확인 후 다운스케일.
출력 파일명 규칙: 원본 파일명에 `_small` 접미사 (`screen.png` → `screen_small.png`).

### 4. UI 요소 좌표 추출 (uiautomator dump)

```bash
# 화면의 모든 UI 요소 → XML로 dump
"$ADB" shell uiautomator dump /sdcard/ui.xml
"$ADB" shell cat /sdcard/ui.xml > /tmp/ui.xml

# EditText/Button/TextView 추출 (bounds + text + resource-id)
grep -oE '(class="android.widget.EditText"|class="android.widget.Button"|class="android.widget.TextView")[^/]*bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"' /tmp/ui.xml

# 특정 텍스트로 요소 찾기 (예: "Sign in" 버튼)
grep -oE 'text="Sign in"[^/]*bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"' /tmp/ui.xml

# bounds=[X1,Y1][X2,Y2] → 중심 좌표 = ((X1+X2)/2, (Y1+Y2)/2)
```

### 5. 좌표 클릭

```bash
# 단일 탭
"$ADB" shell input tap X Y                       # 예: input tap 540 1988

# 길게 누르기 (long press)
"$ADB" shell input swipe X Y X Y 1000            # 1초 long press

# 더블 탭
"$ADB" shell input tap X Y && sleep 0.1 && "$ADB" shell input tap X Y
```

### 6. 키보드 입력

```bash
# ASCII 텍스트 입력 (영문/숫자/일부 기호)
"$ADB" shell input text "hello"                  # 공백은 %s로 인코딩
"$ADB" shell input text "hello%sworld"           # "hello world"

# 키 이벤트 (특수키)
"$ADB" shell input keyevent KEYCODE_ENTER        # 또는 66
"$ADB" shell input keyevent 4                    # BACK
"$ADB" shell input keyevent 61                   # TAB (다음 필드)
"$ADB" shell input keyevent KEYCODE_DEL          # 또는 67 (백스페이스)
"$ADB" shell input keyevent --longpress 67 67 67 67 67  # 5번 반복 백스페이스

# 한글 입력 (input text는 한글 미지원)
# 방법 1: 클립보드 경유
echo -n "한글" | "$ADB" shell "am broadcast -a clipper.set --es text \"$(cat)\""
"$ADB" shell input keyevent KEYCODE_PASTE        # 279
# 방법 2: ADBKeyboard IME 설치 후 (별도 설정)
"$ADB" shell ime set com.android.adbkeyboard/.AdbIME
"$ADB" shell am broadcast -a ADB_INPUT_TEXT --es msg "한글"

# 텍스트 클리어 (현재 필드 전체 선택 후 삭제)
"$ADB" shell input keyevent KEYCODE_MOVE_END     # 123 (커서 끝으로)
"$ADB" shell input keyevent --longpress 67 67 67 67 67 67 67 67 67 67  # 10회 백스페이스
```

### 7. 스와이프/스크롤

```bash
# 위로 스크롤 (아래 → 위)
"$ADB" shell input swipe 540 1800 540 600 500    # X1 Y1 X2 Y2 duration_ms

# 아래로 스크롤 (위 → 아래)
"$ADB" shell input swipe 540 600 540 1800 500

# 좌→우 스와이프 (탭 전환)
"$ADB" shell input swipe 100 1200 980 1200 300

# Fling (빠른 스와이프)
"$ADB" shell input swipe 540 1800 540 200 200
```

### 8. logcat 분석 (에러 추출)

```bash
# 최근 100줄 (덤프 모드, 무한 대기 아님)
"$ADB" logcat -d -t 100

# 앱 태그 + 런타임 에러만
"$ADB" logcat -d -s "MYAPP:*" "AndroidRuntime:E" "MonoDroid:*" 2>&1 | tail -100

# logcat 클리어
"$ADB" logcat -c

# 특정 패턴 검색 (Exception/Crash)
"$ADB" logcat -d 2>&1 | grep -iE "exception|fatal|crash|error" | head -20
```

### 9. 화면 메타 정보

```bash
"$ADB" shell wm size                             # 화면 해상도 (예: 1080x2340)
"$ADB" shell wm density                          # DPI
"$ADB" shell settings get system screen_off_timeout
```

## 표준 검증 패턴

### 패턴 A: 로그인 + 화면 도달 검증 (✅ 검증된 정본 — 2026-05-04)

> **전제**: Step 0의 디바이스 자동 선택이 완료되어 `$TARGET_SERIAL`이 결정된 상태.
> 아래 모든 명령은 `"$ADB" -s "$TARGET_SERIAL" ...` 로 실행해야 한다 (가독성을 위해 본문에서는 `-s "$TARGET_SERIAL"` 생략).
>
> **핵심 시퀀스 (반드시 준수)**: 사용자_명시 절차 — `Email tap → text → TAB → text → ENTER`
>
> 이 순서가 가장 안정적이며 다른 방법은 키보드 좌표 충돌로 잘못된 문자가 입력됨.

```bash
# Step 1: 앱 실행 + 로그인 화면 도달 확인
"$ADB" shell am force-stop "$PKG"
sleep 2
"$ADB" logcat -c
"$ADB" shell am start -n "$PKG/$ACT" > /dev/null
sleep 6  # MAUI 초기화 대기 (5초로는 부족)

# Step 2: UI 요소 dump → 좌표 추출 (키보드 닫힌 상태)
"$ADB" shell uiautomator dump /sdcard/ui.xml
# Windows 사용자명은 환경에서 동적으로 얻는다 (개인 계정명 하드코딩 금지)
WINUSER=$(cmd.exe /c "echo %USERNAME%" 2>/dev/null | tr -d '\r\n')
TMPDIR_WIN="C:\\Users\\${WINUSER}\\AppData\\Local\\Temp"
TMPDIR_WSL="/mnt/c/Users/${WINUSER}/AppData/Local/Temp"
"$ADB" pull /sdcard/ui.xml "${TMPDIR_WIN}\\ui.xml"  # ⚠ /tmp 직접 pull 불가 — Windows 경로 필수
cp "${TMPDIR_WSL}/ui.xml" /tmp/ui.xml

# Step 3: ✅ 정본 로그인 시퀀스 (Email tap → text → TAB → text → ENTER)
"$ADB" shell input tap {EMAIL_X} {EMAIL_Y}        # Email 필드 클릭
sleep 1
"$ADB" shell input text "5"                       # 사번 입력
sleep 1
"$ADB" shell input keyevent 61                    # TAB → Password 필드 자동 이동 (좌표 클릭 금지)
sleep 1
"$ADB" shell input text "5"                       # 비밀번호 입력
sleep 1
"$ADB" shell input keyevent 66                    # ENTER → Sign in 자동 트리거 (좌표 클릭 불필요)
sleep 8                                           # 로그인 처리 + 대시보드 진입 대기

# Step 4: 키보드 내리기 (로그인 후 필수 — ESC로 IME 닫기)
"$ADB" shell input keyevent 111   # KEYCODE_ESCAPE — IME 키보드 닫기
sleep 0.5
# 폴백: ESC 미작동 시 BACK 키(4)로 대체
# "$ADB" shell input keyevent 4   # KEYCODE_BACK — 키보드 닫기 폴백

# Step 5: 대시보드 캡처 (홈 탭 자동 진입됨)
sleep 3
"$ADB" shell uiautomator dump /sdcard/ui.xml
"$ADB" pull /sdcard/ui.xml "${TMPDIR_WIN}\\dashboard.xml"
cp "${TMPDIR_WSL}/dashboard.xml" /tmp/dashboard.xml
grep -oE 'text="안녕[^"]*"' /tmp/dashboard.xml   # 로그인 사용자명 확인
```

**⚠️ 절대 금지 (실측 실패 패턴)**:
- ❌ `Email tap → text → Password tap(좌표) → text` — Password 좌표가 키보드 영역과 겹쳐 'g' 등 오류 입력
- ❌ `input keyevent 4`로 키보드 닫기 후 좌표 클릭 — Y좌표가 변경되어 잘못된 위치 클릭
- ❌ 비밀번호에 KEYCODE_BACK 등 텍스트 외 키 입력 — 일부 키가 IME에서 텍스트로 변환됨
- ❌ `adb pull /sdcard/ui.xml /tmp/ui.xml` — adb.exe(Windows)는 WSL 경로 인식 못함 → Windows 경로(`C:\\Users\\...\\Temp`) 필수

**✅ 검증된 자동로그인 활용 (옵션)**:
- 첫 로그인 후 자동 로그인이 ON되어 있으면 `force-stop` + `am start`로 로그인 화면 우회 가능
- 다른 계정 로그인 필요 시 → More 탭 → 설정 → 로그아웃 → "예" 후 다시 로그인

### 패턴 B: 차트 렌더링 검증 (스크롤 + 다중 캡처)

```bash
# 대시보드에서 스크롤하며 모든 차트 영역 캡처
for i in 1 2 3 4; do
  "$ADB" exec-out screencap -p > "/tmp/chart_${i}.png"
  "$ADB" shell input swipe 540 1800 540 400 500
  sleep 2
done
# 4개 PNG를 순차 Read하여 차트 가시화 확인
```

### 패턴 C: 권한별 모드 분기 검증

```bash
# 같은 앱을 4개 계정(Admin/Sales/TeamLeader/General)으로 순회 로그인
ACCOUNTS=("admin admin" "sales sales" "leader leader" "user user")
for ACC in "${ACCOUNTS[@]}"; do
  EMAIL=$(echo $ACC | cut -d' ' -f1)
  PWD=$(echo $ACC | cut -d' ' -f2)
  
  "$ADB" shell pm clear "$PKG"                    # 로그아웃 상태로 초기화
  "$ADB" shell am start -n "$PKG/$ACT"
  sleep 5
  # 로그인 → 스크린샷 캡처 → 모드별 차트 개수 확인
done
```

### 패턴 D: logcat 에러 확인

```bash
# 검증 시작 전 logcat 클리어
"$ADB" logcat -c

# 사용자 액션 수행 (탭/입력/스와이프)
"$ADB" shell input tap 540 1988

# 액션 후 에러 확인
ERRORS=$("$ADB" logcat -d -s "MYAPP:*" "AndroidRuntime:E" "MonoDroid:*" 2>&1 | grep -iE "exception|fatal" | head -10)
if [ -n "$ERRORS" ]; then
  echo "❌ 런타임 에러 감지:"
  echo "$ERRORS"
fi
```

## 디바이스 자동 선택 절차 (단일 진입, 배타적 분기)

> **정책**: 폰 있으면 폰만, 없으면 에뮬만. 동시 실행 금지. 선택된 단일 TARGET_SERIAL로만 모든 검증 수행.

### Step 0: 디바이스 자동 선택 (반드시 패턴 A~D 진입 전 실행)

```bash
ADB="/mnt/c/Program Files (x86)/Android/android-sdk/platform-tools/adb.exe"

# S0-1. 디바이스 목록 조회 + 분류
DEVICES=$("$ADB" devices | tr -d '\r')  # Windows adb.exe CRLF 제거
REALS=$(echo "$DEVICES" | awk '!/^emulator-/ && !/^List/ && /\tdevice$/ {print $1}')
EMUS=$(echo "$DEVICES" | awk '/^emulator-/ && /\tdevice$/ {print $1}')
UNAUTH=$(echo "$DEVICES" | awk '/unauthorized/ {print $1}')

# S0-2. 실기기 unauthorized 처리 (60초 대기)
if [ -z "$REALS" ] && [ -n "$UNAUTH" ]; then
    echo "📱 폰에서 USB 디버깅 허용 팝업을 확인하고 '이 컴퓨터에서 항상 허용' + 허용을 탭하세요"
    for i in {1..12}; do
        sleep 5
        REALS=$("$ADB" devices | tr -d '\r' | awk '!/^emulator-/ && !/^List/ && /\tdevice$/ {print $1}')
        [ -n "$REALS" ] && break
    done
fi

# S0-3. 분기 — 실기기 우선, 폴백 에뮬레이터
if [ -n "$REALS" ]; then
    TARGET_SERIAL=$(echo "$REALS" | head -1)
    TARGET_KIND="real"
    echo "📱 실기기 선택: $TARGET_SERIAL (에뮬 검증 스킵)"

    # 실기기 사전 체크
    SDK_VER=$("$ADB" -s "$TARGET_SERIAL" shell getprop ro.build.version.sdk | tr -d '\r')
    [ "$SDK_VER" -lt 34 ] && echo "⚠️ API $SDK_VER < 34 — 호환성 주의" || echo "✅ API $SDK_VER OK"
elif [ -n "$EMUS" ]; then
    TARGET_SERIAL=$(echo "$EMUS" | head -1)
    TARGET_KIND="emulator"
    echo "🖥️ 에뮬레이터 선택: $TARGET_SERIAL (폰 미연결 폴백)"
else
    # S0-4. 에뮬레이터도 없음 → 자동 부팅
    echo "🖥️ 디바이스 없음 — 에뮬레이터 pixel_5_-_api_34_0 자동 부팅"
    EMU_BIN="/mnt/c/Program Files (x86)/Android/android-sdk/emulator/emulator.exe"
    nohup "$EMU_BIN" -avd pixel_5_-_api_34_0 > /tmp/emu_boot.log 2>&1 &
    disown
    # boot_completed 폴링 (최대 120초)
    for i in {1..24}; do
        sleep 5
        BOOTED=$("$ADB" devices | tr -d '\r' | awk '/^emulator-/ && /\tdevice$/ {print $1}' | head -1)
        if [ -n "$BOOTED" ]; then
            COMPLETED=$("$ADB" -s "$BOOTED" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
            [ "$COMPLETED" = "1" ] && TARGET_SERIAL="$BOOTED" && break
        fi
    done
    if [ -z "$TARGET_SERIAL" ]; then
        echo "🚫 에뮬레이터 부팅 실패 — 즉시 실패 보고"
        exit 1
    fi
    TARGET_KIND="emulator"
    echo "✅ 에뮬레이터 부팅 완료: $TARGET_SERIAL"
fi

# S0-5. APK 설치 (선택된 단일 디바이스에만)
APK_PATH_WIN=$(wslpath -w "/mnt/c/DATA/Project/MyApp/MyApp.Mobile/bin/Release/net10.0-android/publish/com.example.myapp-Signed.apk")
"$ADB" -s "$TARGET_SERIAL" install -r "$APK_PATH_WIN"

# 이후 모든 패턴 A~D는 "$ADB" -s "$TARGET_SERIAL" 기준으로 실행
```

### 통과 기준 (실기기/에뮬 동일)
- APK 설치 성공
- Pattern A 로그인 성공 + 대시보드 도달
- (변경 범위에 따라) Pattern B 차트 / Pattern C 모드 분기 검증 PASS
- logcat 에러 0건 (Pattern D)

### 자동 흐름
```
otest_mobile 진입
  ↓
Step 0: 디바이스 자동 선택
  ├─ 실기기 감지 → TARGET=실기기 (에뮬 무시)
  ├─ 실기기 unauthorized → 60초 대기 → 실기기 또는 에뮬 폴백
  ├─ 실기기 미연결 + 에뮬 실행 중 → TARGET=에뮬레이터
  └─ 둘 다 없음 → 에뮬 자동 부팅 → TARGET=에뮬레이터 (실패 시 exit)
  ↓
APK 설치 (선택된 단일 디바이스)
  ↓
Pattern A/B/C/D 적용 ($ADB -s $TARGET_SERIAL 기준)
  ↓
종합 보고 (TARGET_KIND 명시)
```

### otest_ui 라우팅
otest_ui가 git diff에서 모바일 프로젝트(*.Mobile/*) 변경 감지 → Skill('otest_mobile') 호출.
otest_mobile이 Step 0에서 디바이스를 자동 선택하여 단일 경로로 진행 (별도 호출 불필요).

## otest_ui와의 통합

```yaml
호출_경로:
  1. otest_ui가 oinfra_{project}.test_capabilities.mobile_test_skill을 확인
  2. 값이 "otest_mobile"이면 → Skill('otest_mobile') 호출
  3. otest_mobile이 acceptance_criteria.json의 mobile/android 카테고리 항목 검증

oinfra_{project}_등록 (참조용):
  test_capabilities:
    ui_test: true
    ui_automation: true
    ui_test_skill: otest_winforms      # WinForms (PC)
    mobile_test_skill: otest_mobile    # MAUI Android (모바일) — 신설
    mobile_target: net10.0-android
    mobile_avd: pixel_5_-_api_34_0
    mobile_package: com.example.myapp
    mobile_main_activity: crc6428e32fee54d832ef.MainActivity
```

## 절차 (otest_ui 진입 시)

```yaml
Step_0_디바이스_자동_선택:
  - 위 "디바이스 자동 선택 절차" Step 0 (S0-1~S0-5) 실행
  - 결과: TARGET_SERIAL + TARGET_KIND(real/emulator) 결정 + APK 설치 완료
  - 폰 연결 시 폰만, 미연결 시 에뮬만 (배타적)

Step_1_logcat_클리어:
  - "$ADB" -s "$TARGET_SERIAL" logcat -c

Step_2_앱_재시작:
  - "$ADB" -s "$TARGET_SERIAL" shell am force-stop "$PKG"
  - "$ADB" -s "$TARGET_SERIAL" shell am start -n "$PKG/$ACT"
  - sleep 5 (스플래시 + 권한 다이얼로그 대기)

Step_3_acceptance_criteria_로드:
  - mobile/android 카테고리 필터
  - 각 항목의 검증 단계(액션 + 기대결과) 추출

Step_4_각_항목_실행:
  - 액션 (tap/input/swipe)
  - 결과 캡처 (screencap)
  - 시각 분석 (Read PNG)
  - logcat 에러 확인
  - PASS/FAIL 기록

Step_5_evidence_저장:
  - 스크린샷: $HOME/.claude/session-env/${UUID}/evidence/screenshots/
  - 결과: $HOME/.claude/session-env/${UUID}/evidence/mobile_test_done

Step_6_보고:
  - PASS/FAIL 표 + 스크린샷 경로
```

## 좌표 매핑 헬퍼 (Python 일회용)

```python
# uiautomator dump XML에서 모든 EditText/Button bounds 추출
import re, sys
xml = open(sys.argv[1]).read()
pattern = r'class="(android\.widget\.\w+)"[^/]*?text="([^"]*)"[^/]*?bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"'
for m in re.finditer(pattern, xml):
    cls, txt, x1, y1, x2, y2 = m.groups()
    cx, cy = (int(x1)+int(x2))//2, (int(y1)+int(y2))//2
    print(f"{cls:30s} text=\"{txt}\" center=({cx},{cy})")
```

## 제약 + 주의사항

```yaml
oio_MCP_경유:
  - 모든 셸 명령은 mcp__oio__bash_exec 사용
  - 파일 I/O는 mcp__oio__file_read / file_write
  - run_in_background=true 절대 금지 (L-303)
  - 백그라운드 필요 시 nohup ... & disown 패턴

WSL_경로_변환:
  - adb.exe는 Windows 프로세스 → WSL 경로(/mnt/c/...) 인식 불가
  - 파일 인자가 필요하면 wslpath -w로 변환:
    APK_PATH_WIN=$(wslpath -w "$APK_PATH")
    "$ADB" install -r "$APK_PATH_WIN"

스크린샷_파일_위치:
  - 임시: /tmp/*.png (WSL 측 — Read 도구로 시각 분석)
  - 영구: $HOME/.claude/session-env/${UUID}/evidence/screenshots/

UI_dump_지연:
  - uiautomator dump는 1~3초 소요 (버튼이 한참 떠 있으면 사용)
  - 빠른 검증은 좌표 직접 사용 (사전 매핑된 좌표)

좌표_정확도:
  - 화면 회전/IME 표시 여부에 따라 좌표 변동 가능
  - 핵심 요소는 매번 uiautomator dump → grep으로 재확인 권장

키보드_상태:
  - 로그인 후 키보드 닫기: keyevent 111 (KEYCODE_ESCAPE) + sleep 0.5 — 패턴 A Step 4
  - ESC 미작동 시 폴백: BACK 키(keyevent 4) 사용
  - 다음 탭/입력 전 키보드 상태 확인

로그인_초기화:
  - 깨끗한 상태 검증 위해 pm clear 권장 (로그인 정보 삭제)
  - Remember me 체크된 상태가 필요하면 pm clear 생략

격리:
  - 다른 세션과 충돌 없음 (TARGET_SERIAL 단일 선택 후 모든 adb 호출에 -s 명시)
  - 폰+에뮬 동시 device 상태여도 실기기 1개만 사용 (배타적 분기)
  - 복수 실기기 연결 시 첫 번째 시리얼 사용 (head -1)
```

## 절대 금지

1. **adb logcat -f (follow) 무한 대기 모드** — `-d` (덤프)만 사용
2. **run_in_background=true** — L-303 무한 블로킹 버그
3. **bash_exec에 PNG 직접 base64 출력 시도** — 토큰 폭주. 항상 파일 저장 후 Read 도구
4. **timeout_ms 미설정** — 디바이스 응답 느림. 최소 10000ms, 캡처는 15000ms
5. **현재 화면 가정 금지** — 매번 screencap → Read로 실제 화면 확인 후 다음 액션
6. **다중 디바이스 동시 검증 금지** — 폰+에뮬이 모두 device로 보여도 TARGET_SERIAL 1개만 선택해 진행 (실기기 우선). 양쪽 모두에 install/test 절대 금지
7. **`-s $TARGET_SERIAL` 누락 금지** — Step 0 이후 모든 adb 호출은 시리얼 명시 필수 (다중 디바이스 환경에서 잘못된 디바이스로 명령 전달 방지)

## 보고 형식

```
🤖 otest_mobile 결과
대상 디바이스: {TARGET_KIND} ({TARGET_SERIAL})
선택 사유: 실기기 우선 / 폰 미연결 폴백 / 에뮬 자동 부팅

| 검증 항목 | 액션 | 결과 | 스크린샷 |
|---------|------|------|---------|
| 로그인 화면 도달 | am start | PASS | login.png |
| ryo/ryo 로그인 | input text + tap | PASS | dash.png |
| 차트 6개 렌더링 (Admin) | swipe + capture×4 | PASS | chart_1~4.png |
| logcat 에러 | logcat -d | 0건 | - |

종합: PASS / FAIL / PARTIAL
```

※ 위 이력의 `ryo/ryo`는 당시 사용한 계정이다. 현재는 폐기됐고 PC·모바일 모두 `77/77`로 통일한다.
