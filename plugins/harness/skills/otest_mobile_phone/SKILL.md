---
name: otest_mobile_phone
description: "실기기(USB/무선 adb) 전용 Android 앱 테스트 — 기기 식별·화면 깨우기/stayon 원복·패키지 공존 설치·접힘/펼침/팝업창(창 폭)으로 폼팩터 검증·wm size 보조와 trap 원복·실 푸시(FCM) 3상태 수신 검증·테스트 데이터/알림/화면 설정 정리. otest_mobile 라우터가 실기기 연결 시 호출한다."
invocation:
  user_callable: true
  pipeline_callable: true
  called_by: ["otest_mobile"]
  calls: []
---

# otest_mobile_phone — 실기기 adb 테스트

> 공통 adb 명령·검증 패턴·계정 연쇄·증거 병합·ack 규칙은 `otest_mobile/SKILL.md` 가 정본이다. 여기는 **실기기에만 있는 절차**만 둔다.
> 프로젝트 고유값(패키지·액티비티·APK·adb 경로·테스트 전용 기기 시리얼)은 환경변수로 받는다(`ADB`·`SERIAL`·`PKG`·`ACT`·`APK`).

## 실기기가 맡는 것 / 맡지 않는 것

| 실기기가 정본 | 에뮬이 정본(`otest_mobile_emulator`) |
|---|---|
| 실제 성능·실제 렌더러·실제 푸시(FCM) 수신 | 대형 태블릿의 실제 성능·회전 체감(실물 태블릿 대용) |
| 폴더블 접힘↔펼침 전환·힌지·회전 | 해상도·화면비 매트릭스(다중 AVD 병렬) |
| 창 크기 변경(팝업창·분할 화면) 대응 | root 가 필요한 스택 샘플링(debuggerd) |
| 대형 태블릿 **레이아웃**(dp 맞춤 재현 — 4-3절) | |

`wm size`/`wm density` 로 실기기 해상도를 흉내 낼 수는 있으나 물리 화면비·DPI·힌지 동작은 재현하지 못한다 → 성능·체감의 정본 증거로 쓰지 않는다. 단, 앱이 **창 폭(dp) 기준**으로 배치를 고르면 dp 크기를 맞춘 재현은 **레이아웃 증거**로 쓸 수 있다(4-3절).

**에뮬과 병렬일 때(라우터 "병렬 모드" 조건을 만족한 경우만)** — 실기기 쪽이 지킬 것:
- 실기기 필수 항목(위 표 왼쪽)은 전부 실기기가 맡는다. 에뮬로 넘기지 않는다.
- 에뮬 쪽과 다른 계정·다른 표식 꼬리표를 쓴다 — 같은 계정이면 회원 단위 푸시·실시간 알림이 상대 기기 화면에도 떠서 측정을 방해한다.
- 측정 중 호스트에서 에뮬·빌드가 같이 돌면 실기기 시간 값에도 서버·네트워크 경합이 섞일 수 있다 — 성능 항목은 에뮬 쪽이 쉬는 구간에 잰다.
- 에뮬 쪽이 중단돼 넘어온 항목은 `test_ledger.py next --kind phone` 으로 받아 이어 한다.

## Step 1 — 기기 식별

```bash
"$ADB" devices -l | tr -d '\r'                         # serial · model · transport 확인
"$ADB" -s "$SERIAL" shell getprop ro.product.model     # device_model (증거에 기록)
"$ADB" -s "$SERIAL" shell getprop ro.build.version.release; getprop ro.build.version.sdk
"$ADB" -s "$SERIAL" shell wm size; wm density          # Physical + (있으면) Override
```

- 테스트 전용 기기 시리얼(`PHONE_SERIAL`)이 정해져 있으면 그 기기만 쓴다. 사용자 개인 폰은 자동화하지 않는다.
- **기존 Override 값을 사용자 설정으로 간주**한다(예: 화면 크기 조정으로 생긴 density Override). 무조건 `reset` 하면 사용자 설정을 지운다 → `phone_session.sh begin` 이 원래 값을 저장하고 `end` 가 그 값으로 되돌린다.
- 무선 adb (Android 11+, PC 와 휴대폰이 **같은 네트워크 대역**일 때만 — 다른 망·외출 중에는 불가):
  1. 사용자 1회: 개발자 옵션 → **무선 디버깅** 켜기 → "페어링 코드로 기기 페어링" 화면의 `IP:페어링포트`·6자리 코드를 알려 받는다(PIN 처럼 대신 입력하지 않는다).
  2. `adb pair <IP:페어링포트> <코드>` → 무선 디버깅 화면의 `IP:연결포트` 로 `adb connect <IP:연결포트>`. 이후 같은 망이면 `adb connect` 만(포트는 무선 디버깅을 껐다 켜면 바뀐다).
  3. 무선이면 adb 시리얼이 `IP:포트`(또는 mDNS 이름)로 바뀐다 — **`adb -s` 에는 그 값**, 사용권·원복 상태·원장의 **기기 키에는 하드웨어 시리얼**(`scripts/../../otest_mobile/scripts/dev_id.sh hwid`)을 쓴다. 라우터·`device_watch.sh`·`device_lease.sh`·`phone_session.sh` 는 이미 이렇게 대조한다.
  4. 화면 유지: `stayon usb` 는 USB 전원일 때만 듣는다 → 무선이면 `phone_session.sh begin` 이 `svc power stayon true`(충전 중일 때만 유효) + `screen_off_timeout` 30분을 적용하고, `end` 가 원값으로 되돌린다(원값은 begin 이 저장).
  5. 끊김: 화면 꺼짐·Wi-Fi 변경·무선 디버깅 자동 해제로 끊긴다 → `device_watch.sh` 가 PHONE_LOST 로 알린다. 큰 APK 설치는 Wi-Fi 속도에 따라 USB 보다 느릴 수 있다.
- 최초 1회 사용자 준비: 개발자 옵션 → USB 디버깅 ON → PC RSA 지문 "항상 허용". 테스트 전용 기기는 화면 잠금 "없음" 권장(PIN 자동 입력 금지).

## Step 2 — 화면 상태 확인·깨우기·stayon (세션 시작)

```bash
bash scripts/phone_session.sh begin      # 원래 값 저장 → KEYCODE_WAKEUP(꺼져 있을 때) → svc power stayon usb
# 단계 끝: bash scripts/phone_session.sh safe   (키보드·팝업창·wm·회전·stayon 원복 — 언제 뽑아도 정상 상태)
# 분리 후 재연결: bash scripts/phone_session.sh reconnect   (깨우기 → 보류 원복 → 이후 apk 대조·begin — otest_mobile L21 e)
trap 'bash scripts/phone_session.sh end' EXIT INT TERM    # 테스트 스크립트에서 begin 직후 반드시
```

- 화면 상태: `dumpsys power | grep mWakefulness` (Awake/Asleep/Dozing). 꺼져 있으면 `input keyevent KEYCODE_WAKEUP`.
- 잠금 화면이면 사용자에게 1회 해제 요청 — 자동으로 PIN/패턴을 넣지 않는다.
- `svc power stayon usb` 는 측정 중 화면 꺼짐 방지용. **끝나면 반드시 원래 값으로 원복**(`stay_on_while_plugged_in` 원값 확인).

## Step 3 — 설치와 패키지 공존

```bash
"$ADB" -s "$SERIAL" shell pm list packages | grep -i "<앱 식별어>"   # 같은 앱의 다른 패키지(스토어판 등) 공존 여부
"$ADB" -s "$SERIAL" install -r "$(wslpath -w "$APK")"
md5sum "$APK"                                                       # apk_md5 → 증거
"$ADB" -s "$SERIAL" shell dumpsys package "$PKG" | grep -E "versionName|versionCode|lastUpdateTime"
```

- 개발 빌드와 스토어 빌드의 패키지명이 다르면 공존한다 — **테스트는 반드시 `$PKG`(개발 패키지) 로만** 한다. 알림·딥링크가 어느 쪽 앱으로 가는지 증거에 패키지명을 함께 적는다.
- 서명이 달라 `INSTALL_FAILED_UPDATE_INCOMPATIBLE` 이면 `uninstall` 전에 사용자에게 알린다(기기 내 데이터 소실).

## Step 4 — 폼팩터 검증 (폴더블 1대로 phone·fold·소형 tablet)

### 4-0. 선행 확인 — 앱 반응형 판정이 "창 폭" 기준인가 (필수, 코드로 확인)

- 앱 코드에서 레이아웃 모드 판정 입력을 찾는다: 페이지/창 크기(SizeChanged·창 Width dp) 기준인지, 기기 종류(Idiom·화면 전체 크기) 기준인지.
- **창 폭 기준일 때만** 팝업창·분할 화면으로 phone 레이아웃을 검증할 수 있다. 기기 종류 기준이면 이 방법은 무효 → 에뮬 AVD 로 간다.
- 판정 임계값(dp)과 판정 로그 문자열을 INFRA.md 에 적어 두고, 측정 때 앱 로그의 판정 결과로 교차 확인한다.

### 4-1. 매핑

| 기기 상태 | 검증 폼팩터 | 방법 |
|---|---|---|
| 접힘(커버 화면) | phone | 사용자 1회 접기 또는 기기 상태 확인 `cmd device_state state` |
| 펼침 전체 화면 | fold / 소형 tablet | 기본 |
| 펼침 + 팝업창(freeform) 좁게 | phone 폭 | `scripts/window_mode.sh popup L T R B` (자동화 실측 가능) |
| 펼침 + 분할 화면(2앱) | phone 폭 | adb 표준 진입 명령 미확인 → **사용자 1회 수동 배치** |
| 회전 | 가로/세로 | `settings put system accelerometer_rotation 0` + `user_rotation 0~3` (종료 시 원복) |

```bash
bash scripts/window_mode.sh popup 50 150 910 2050   # 펼친 화면에서 폭 860px 창 → 앱이 받는 폭(dp)을 bounds 로 확인
bash scripts/window_mode.sh bounds                  # mode=freeform · sw/w/h dp
bash scripts/window_mode.sh full                    # 해제(force-stop 후 전체 화면 재기동 — 실측상 이 방법만 복귀됨)
```

- 실측(Android 16 폴더블): `am start --windowingMode 5` → freeform, `am task resize <TASK_ID> L T R B` 로 경계 지정 성공. `--windowingMode 1` 재기동으로는 기존 태스크가 복귀하지 않았고 force-stop 후 재기동해야 fullscreen.
- 전환 직후 레이아웃 재구성 지연·ANR 이 날 수 있으므로 `anr_catcher.sh` 를 켠 상태에서 전환한다.

### 4-2. wm size / wm density — 보조 수단

- 정본 증거가 아니다. 쓰는 경우 **반드시 trap 으로 종료 시 원복**한다: `phone_session.sh end` 가 `wm size reset`(원래 Override 가 있었으면 그 값) · density 원값 · 회전 · stayon 을 되돌리고 Physical 일치를 확인한다.
- 원복 확인: `wm size` 출력에 Override 가 남아 있지 않아야 한다(원래 없었던 경우). 남았으면 rc=1 로 실패.

### 4-3. 대형 태블릿 dp 맞춤 재현 — 레이아웃 증거 전용

앱이 레이아웃을 **창 폭(dp)** 으로 고르면(4-0 확인), 맞춰야 하는 것은 가로세로 **비율이 아니라 dp 크기**다. 실기기에서 `wm size` + `wm density` 로 대상 태블릿의 dp 크기를 그대로 만들 수 있다.

**계산식** — `dp = px ÷ (density / 160)` (px·density 는 `wm size`·`wm density` 가 보고하는 값)

```bash
# ① 현재 값 저장(세션 시작 시 phone_session.sh begin 이 저장한다 — 원래 density Override 가 있으면 그것이 기준이다)
"$ADB" -s "$SERIAL" shell wm size        # Physical size: PWxPH  (+ Override size: …)
"$ADB" -s "$SERIAL" shell wm density     # Physical density: PD  (+ Override density: OD)
# ② 지금 앱이 받는 dp — 적용 중인 값(Override 가 있으면 Override)으로 계산
#    예) 1600x2400, density 400 → 1600/(400/160)=640dp × 2400/(400/160)=960dp  (기기별 실제 값은 INFRA.md)
W=<px폭> H=<px높이> D=<density>; python3 -c "w,h,d=$W,$H,$D; print(round(w/(d/160)), round(h/(d/160)))"
```

**대상 dp 재현** — 대형 태블릿 세로 800×1280dp · 가로 1280×800dp(실물 기준 px 2560×1600, density 320)

```bash
# 방법 A(권장) — 물리 화면 안에 들어가는 density 를 골라 레터박스 축소를 줄인다
#   d = floor(160 × min(PW/800, PH/1280)),  px = (800×d/160) × (1280×d/160)   ※ 세로(natural) 방향 기준
PW=<Physical 폭px> PH=<Physical 높이px>
python3 -c "PW,PH=$PW,$PH; d=int(160*min(PW/800,PH/1280)); print(d, round(800*d/160), round(1280*d/160))"
#   → 출력 "d W H" 를 그대로 쓴다(예: Physical 1600x2400 → 300 1500 2400 ⇒ wm size 1500x2400 · wm density 300 = 800×1280dp)
"$ADB" -s "$SERIAL" shell wm size <W>x<H>
"$ADB" -s "$SERIAL" shell wm density <d>

# 방법 B — 실물 수치 그대로(물리 화면보다 크면 축소 표시된다)
"$ADB" -s "$SERIAL" shell wm size 1600x2560
"$ADB" -s "$SERIAL" shell wm density 320

# 가로(1280×800dp) — wm size 는 natural 방향 값이다. 크기는 그대로 두고 회전으로 전환한다
"$ADB" -s "$SERIAL" shell settings put system accelerometer_rotation 0
"$ADB" -s "$SERIAL" shell settings put system user_rotation 1      # 1=90° (0=세로 복귀)

# 적용 확인 — 앱을 재기동해야 기동 시 레이아웃 판정이 새 값으로 다시 돈다(실행 중 변경만으로 완료 처리 금지)
"$ADB" -s "$SERIAL" shell am force-stop "$PKG"; "$ADB" -s "$SERIAL" shell am start -n "$PKG/$ACT"
bash scripts/window_mode.sh bounds        # 앱 창의 w/h dp 가 대상(800×1280 또는 1280×800)과 같은지 기록
```

- 앱 로그의 레이아웃 판정 결과(임계값·판정 문자열은 INFRA.md)로 교차 확인한다. dp 가 맞아도 판정 로그가 다르면 재현 실패로 본다.

**원복 의무 (trap — 생략 금지)**

```bash
bash scripts/phone_session.sh begin
trap 'bash scripts/phone_session.sh end' EXIT INT TERM
```

- `wm size` 는 **reset**(원래 Override 가 있었으면 그 값으로).
- `wm density` 는 원래 **Override 가 있으면 그 값으로 되돌린다 — reset 하지 않는다**(사용자 화면 크기 설정이다). 원래 Override 가 **없을 때만** reset.
- 회전(`accelerometer_rotation`·`user_rotation`)은 원래 값으로.
- `phone_session.sh end` 가 위 세 가지를 하고 Physical 일치를 확인한다. rc≠0 이면 원복 실패로 보고한다.

**한계와 증거 사용 범위**

| 항목 | 내용 |
|---|---|
| 화면 | 물리 화면비와 달라 **레터박스**가 생기고(방법 B 는 축소까지) 실물보다 작게 보인다 |
| 터치 | 좌표 변환으로 **터치 정확도가 떨어진다** — 좌표 탭 결과는 판정 근거로 약하다(UI 트리·로그로 확인) |
| 성능 | 렌더 해상도·밀도가 실물과 달라 **성능 수치는 증거로 쓰지 않는다** |
| 증거로 쓰는 것 | **레이아웃만** — 열 수·간트 폭·줄바꿈·Wide/Compact 판정 결과 |
| 에뮬이 필요한 경우 | 실제 태블릿 성능, 회전 체감(전환 지연·ANR 재현), 실물 화면비 화면 캡처 → `otest_mobile_emulator` |

## Step 5 — 실기기 푸시(FCM) 실수신 검증

```yaml
전제:
  - 기기의 푸시 토큰이 서버(개발 DB 등)에 등록됐는지 먼저 조회 — 등록 시각이 이번 설치 이후인지 확인.
  - 발송 전에 같은 대상에 토큰을 가진 다른 단말(다른 테스트 기기·사용자 개인 폰)이 있는지 목록을 뽑아 사용자에게 사전 고지.
  - 알림 본문에 사이클 표식을 넣는다.

3상태 (상태마다 같은 절차 반복):
  1. 포그라운드: 앱 화면을 띄운 채 발송
  2. 백그라운드: HOME(keyevent 3) 으로 앱을 뒤로 보낸 뒤 발송
  3. 프로세스 종료: 최근 앱 화면에서 스와이프 제거 또는 `am kill $PKG`(백그라운드 상태에서) 후 발송
     — `am force-stop` 은 쓰지 않는다(force-stop 상태 앱은 안드로이드가 푸시 전달을 막는다 → 앱 결함과 구분 불가)

캡처:
  - bash scripts/notif_capture.sh <이름> "<표식 정규식>"
    (cmd statusbar expand-notifications → screencap → dumpsys notification 에서 $PKG 알림 텍스트 → collapse)

수신_경로_구분 (증거에 반드시 기록):
  - in_app_socket: 앱이 살아 있는 동안 앱 자체 연결(소켓·폴링)로 받은 앱 내 팝업 — 알림 패널에 없음
  - fcm_notification: 시스템 알림 패널의 알림(dumpsys notification 에 pkg=$PKG 레코드)
  - 판정 근거: 앱 로그의 수신 처리 로그 줄 + notif_capture 결과를 함께 남긴다. 한쪽만으로 판정 금지.
  - 같은 공지를 계정마다 반복 발송하지 않는다 — 1회 발송 후 상태·경로별로 확인(프로젝트 규칙은 INFRA.md).
```

## Step 6 — 정리 (세션 종료, 생략 금지)

```yaml
테스트_데이터: 사이클 표식으로 서버 데이터 잔여 0 실측 (otest_mobile 공통 규칙)
# 개발 환경은 2026-10-10 사용자 지시로 시험 데이터 삭제 의무 없음 — 남겨도 된다. 운영 데이터 연계 환경(QA·운영)은 예외 없이 원복한다.
알림: 알림 패널의 테스트 알림 삭제 — cmd notification 또는 패널에서 지우기, 남은 $PKG 알림 0 확인
로그인: 테스트 계정 로그아웃 또는 pm clear $PKG (다음 사람이 이전 계정으로 들어가지 않게)
화면_설정: phone_session.sh end — wm size/density·회전·stayon 원복 + Physical 일치 확인 (rc=0 이어야 종료)
네트워크: phone_session.sh begin 이 비행기 모드·wifi_on·Wi-Fi SSID 원값을 저장하고 end 가 비행기 모드·Wi-Fi 를 원값으로 되돌린 뒤 SSID 를 대조한다.
  SSID 가 다르면 end 가 rc=1 — 사용자에게 원래 네트워크로 전환을 요청한다(비밀번호를 adb 로 입력하지 않는다).
  네트워크 끊김 시험은 비행기 모드가 아니라 Wi-Fi 끄고 켜기(svc wifi disable/enable)로 한다 — 비행기 모드 해제 뒤 기기가
  다른 저장 네트워크(사용자 개인 핫스팟 등)에 붙어 서버에 닿지 않고 사용자 데이터를 쓴 실사고가 있다. 시험 전후 SSID 를 출력해 남긴다.
창_모드: window_mode.sh full — freeform 잔존 0
보고: 원복 결과 1줄을 보고서에 포함 (예: "stayon 0 원복 · wm Override 없음 · 회전 원값")
```

## 실측 교훈 — 실기기 (절차·원복·판정)

> 공통 교훈(L1 기기 선택·L2 속도·L8 fatal·L9 성능 위생·L10 빌드·L11 교대·L17 외부 부작용·L18 ANR·L19 ack·L20 명령 안전·L21 실기기↔에뮬 전환·복귀·L22 키보드)은 `otest_mobile` 에 있다.
> **휴대 안전 상태(L21 b)** — 단계마다 `scripts/phone_session.sh safe` 로 원값 복귀 후 다음 단계에서 begin. 분리돼 원복을 못 하면 rc=3 + 보류 원복 목록, 재연결은 `phone_session.sh reconnect` 부터.

### P3. 화면 상태 — 깨우기·stayon
- 절차: `dumpsys power | grep mWakefulness` → `Asleep`/`Dozing` 이면 `input keyevent KEYCODE_WAKEUP`(224). 측정 중 꺼짐 방지는 `svc power stayon usb` — **먼저 `settings get global stay_on_while_plugged_in` 원값을 저장**한다(phone_session.sh begin).
- 원복: 종료 시 원값으로 `settings put global stay_on_while_plugged_in <원값>`(phone_session.sh end).
- 판정: 각 캡처 직전 `mWakefulness=Awake`. 세션 끝 원값 일치 1줄을 보고에 넣는다.

### P4. 화면 설정 원복 — trap 필수
- 절차: `phone_session.sh begin` 직후 `trap 'bash scripts/phone_session.sh end' EXIT INT TERM`. wm·회전 변경은 trap 이 걸린 셸 안에서만 한다.
- 원복: `wm size` 는 reset(원래 Override 가 있었으면 그 값). `wm density` 는 **원래 Override 가 있으면 그 값으로 되돌리고 reset 하지 않는다**(사용자 화면 크기 설정) — Override 가 없었을 때만 reset. 회전은 원값.
- 판정: `phone_session.sh end` rc=0(Physical/Override 가 시작 때와 같음). rc≠0 이면 원복 실패로 보고한다.

### P5. 폴더블·다중 디스플레이 캡처
- 절차: `madb.sh shot` 을 쓴다 — `dumpsys display` 의 활성 뷰포트 `local:<id>` 를 찾아 `screencap -p -d <id>` 로 찍는다(강제 지정은 `SHOT_DISPLAY`). **-d 없이 찍으면 경고문이 PNG 앞에 섞여 파일이 깨진다.**
- 검은 프레임이 나오면 **wm size 를 흔들지 말고** 잠깐 기다렸다가 다시 찍는다(madb.sh 가 최대 4회 재시도).
- 판정: PNG 시그니처 정상·10KB 초과·검은 프레임 아님.

### P6. 폼팩터 — 창 폭 기준 확인 후 팝업창
- 절차: 4-0(앱 판정이 창 폭 dp 기준인지 코드 확인) → phone 폭은 팝업창 `am start --windowingMode 5` + `am task resize <TASK_ID> L T R B`(window_mode.sh popup) → 두 앱 분할 화면은 adb 진입이 미확인이라 필요하면 **사용자 1회 수동 배치**.
- 원복: `window_mode.sh full`(force-stop 후 fullscreen 재기동 — 실측상 이 방법만 복귀됨).
- 판정: `window_mode.sh bounds` 의 w dp 와 앱 로그의 레이아웃 판정이 둘 다 기대값.

### P7. 태블릿 재현 — 비율이 아니라 dp
- 4-3절이 정본이다. 요약: `dp = px ÷ (density/160)`, 대형 태블릿 800×1280dp / 1280×800dp 를 wm size + wm density(+ 회전)로 만든다. **레이아웃 증거 전용** — 레터박스·터치 정확도 저하 때문에 성능·좌표 탭 결과는 쓰지 않는다.

### P12. 푸시(FCM) 실수신 — 경로를 나눠 검증한다
- 사실: 토큰은 **회원 단위**다. 같은 계정으로 로그인한 다른 단말(개인 폰 등)에도 알림이 간다.
- 절차:
  1. 발송 전 대상 회원의 활성 토큰 목록을 조회해 다른 단말이 있으면 사용자에게 고지한다. 서버가 토큰을 캐시하는지(발송 시 DB 를 다시 읽는지) 코드·로그로 먼저 확인한다.
  2. **단말 수신만 확인** — `scripts/fcm_send_one.py --key <키> --token <대상 토큰 1개> --title "[cNNNtest] …"` 로 그 토큰에만 직접 보낸다(서버 경로를 타지 않는다).
  3. **서버 발송 경로까지 확인** — 같은 회원의 다른 토큰을 일시 비활성화한다: 사전 스냅샷(ID·IsActive·UpdatedAt 포함) → 비활성화 → 발송 → **trap 으로 원복** → 행을 스냅샷과 대조(UpdatedAt 까지 같은지, 다르면 원복 사실을 보고).
  4. 3상태 각각 — 포그라운드 / 백그라운드(HOME) / 프로세스 종료(최근 앱 스와이프 또는 백그라운드에서 `am kill`; **force-stop 금지**) — 에서 `notif_capture.sh` 로 알림창 캡처, 수신 경로(앱 내 소켓 팝업 `in_app_socket` / 시스템 알림 `fcm_notification`)를 구분해 기록한다.
- 원복: 비활성화한 토큰 원복, 테스트 공지·알림 삭제, 알림 패널 정리.
- 판정: 상태 3개 × 경로 기록 + 스냅샷 대조 일치 + 표식 공지 잔여 0.

### P13. 토큰 등록 검증
- 절차: 사전 스냅샷 → (a) 신규 설치·첫 로그인에서 **신규 행** 생성 확인(등록 시각이 설치 이후) → (b) 같은 기기로 재로그인 시 **갱신만**(행 수 불변, UpdatedAt 변경) → (c) 계정 전환 시 이전 계정 행 비활성·새 계정 행 활성 **토글** 확인.
- 오로그 점검: 등록이 실패해도 "등록 완료" 류 로그가 찍히는 경로가 있는지 앱 코드에서 확인하고, 실패 주입(네트워크 차단 등)으로 실패 로그가 나오는지 본다.
- 원복: 테스트로 생긴 행은 스냅샷 후 정리(실사용 단말 행은 건드리지 않는다).
- 판정: 행 ID·기기명·등록/갱신 시각을 증거에 적는다 — "아무 토큰 1건" 으로 통과시키지 않는다.

### P14. 딥링크 — 알림 탭 2상태
- 절차: 알림 탭을 **백그라운드 상태**와 **프로세스 종료 상태** 각각에서 검증한다. 종료 상태는 앱이 자동로그인과 딥링크 이동을 동시에 처리하므로 **순서 경합**(로그인 전에 이동 시도 → 로그인 화면에 머묾)을 따로 본다.
- 판정: 탭 후 최종 화면(topResumedActivity·덤프의 화면 표식)이 목적지. 상태별 캡처 2장.

### P15. 서버 대상 검증 — 개발/운영
- 절차: 신규 설치(`pm clear`) 직후 기본 접속 대상이 기대값인지 확인한다. **운영 서버는 정상 로그인 시 토큰 등의 쓰기가 생기므로 틀린 비밀번호로 로그인 시도**해 서버 로그에 그 기기의 시도가 찍히는지로 대상만 입증한다.
- 원복: 접속 대상을 원래 값으로.
- 판정: 서버 로그 기록 + **운영 쓰기 0**(토큰 행·세션 행 증가 없음).

### P16. 사용자 자격증명이 필요한 검증
- 절차: 비밀번호를 채팅으로 받지 않는다. 기기를 해당 화면까지 준비해 두고 **사용자가 1회 직접 입력**하게 한 뒤, 서버 로그(인증 성공·경로)로 판정한다.
- 판정: 서버 로그 1줄 + 화면 캡처. 입력값은 어디에도 기록하지 않는다.

## 절대 금지

1. 사용자 개인 폰 자동화(테스트 전용 기기 시리얼로만)
2. 화면 설정 원복 없이 종료 — trap 없이 `wm size`/`wm density`/회전 변경
   · density Override 가 있던 기기에서 `wm density reset` (사용자 화면 크기 설정 소실)
3. 기존 Override 를 확인 없이 `reset` (사용자 설정 소실)
4. PIN/패턴 자동 입력, 잠금 해제 우회
5. 푸시 "프로세스 종료" 상태를 `am force-stop` 으로 만들기
6. 수신 경로(in_app_socket / fcm_notification) 구분 없이 "수신됨" 보고
7. 네트워크 끊김 시험에 비행기 모드 사용, SSID 기록 없이 Wi-Fi 상태 변경, Wi-Fi 비밀번호를 adb 로 입력
