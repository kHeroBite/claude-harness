---
name: otest_mobile_emulator_bg
description: "모바일 에뮬레이터 시험의 기본값(헤드리스·백그라운드). Android 에뮬레이터를 -no-window 로 띄워 사용자 화면에 어떤 창도 노출하지 않고 adb 만으로 조작(input tap/text/keyevent, uiautomator dump, am start, logcat)·확인(exec-out screencap)한다. 별도 요청이 없으면 에뮬레이터 시험은 항상 이 스킬로 한다 — otest 모바일 축, odev 중간 실기 확인 모두 해당. 창 모드 에뮬레이터·GUI 도구는 사용자가 명시 요청했거나 헤드리스 실패를 실측한 경우에만 허용하고 사유를 증거에 남긴다. 실기기는 otest_mobile_phone, AVD 폼팩터·병렬·메모리 기준은 otest_mobile_emulator 를 함께 따른다."
invocation:
  user_callable: true
  pipeline_callable: true
  called_by: ["otest_mobile", "otest_mobile_emulator", "otest(모바일 축)", "odev(구현 중 모바일 실기 확인)"]
  calls: []
---

# otest_mobile_emulator_bg — 헤드리스 에뮬레이터 시험 (기본)

> 이 스킬은 **범용 가이드**다. 프로젝트 고유값(AVD 이름·패키지·액티비티·APK·emulator/adb 경로·딥링크)은 `{프로젝트 루트}/INFRA.md`(필요 절만)와 환경변수(`EMULATOR`·`ADB`·`AVD`·`PKG`·`ACT`·`APK`)에서 받는다.
> 공통 adb 패턴·계정 연쇄·증거 병합·tapx·ANR 감시·시험 데이터 표식은 `otest_mobile/SKILL.md`, AVD 폼팩터·병렬·게스트 메모리 4GB+ 는 `otest_mobile_emulator/SKILL.md` 가 정본이다. 여기는 **화면에 보이지 않게 하는 절차**만 둔다.

```yaml
원칙 (최상위):
  - 에뮬레이터는 ★-no-window★ 로만 띄운다. 사용자 화면에 에뮬레이터 창·시험 도구 창이 한 번도 뜨면 안 된다.
  - 조작은 adb 명령만, 확인은 screencap 파일만. 창·GUI 도구(Android Studio, Device Manager, scrcpy, 에뮬 창 클릭)는 쓰지 않는다.
  - 사용자 활동 중 화면 노출 UI 금지 제약이 상시 적용된다.
역할_분담:
  otest_mobile_emulator_bg (이 스킬, ★기본★): 헤드리스 에뮬 기동·조작·확인·정리
  otest_mobile_emulator: AVD 폼팩터·다중 AVD 병렬·메모리·Release/AOT 기준 (기동만 이 스킬의 -no-window 규칙을 덮어쓴다)
  otest_mobile_phone: 실기기(실제 푸시·실성능 결론)
```

## 1. 기동 (창 없이)

```bash
# 필수 플래그: -no-window -no-audio -no-boot-anim  (권장: -no-snapshot-save, -memory 4096 이상)
setsid nohup "$EMULATOR" -avd "$AVD" -port 5554 -memory 4096 \
  -no-window -no-audio -no-boot-anim -no-snapshot-save \
  > "$OUT/emu_5554.log" 2>&1 < /dev/null &
SERIAL=emulator-5554
"$ADB" -s "$SERIAL" wait-for-device
# 부팅 완료 폴링 (최대 240초, 5초 간격 — 호출 1회는 90초 이내로 끊어 여러 번 나눠 호출)
for i in $(seq 1 16); do
  [ "$("$ADB" -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && break
  /bin/sleep 5
done
```

- `otest_mobile_emulator/scripts/avd_boot.sh <AVD> 5554 4096` 은 기본이 헤드리스(`-no-window -no-audio`)다. 창 모드는 첫 인자 `--windowed` 로만 켜며 4절 조건을 만족할 때만 쓴다.
- emulator 를 직접 부를 때 `-no-window` 가 없으면 `PreToolUse_oio_bash_emulator_headless_guard.sh` hook 이 차단한다(`-list-avds`·`-version`·`adb emu kill` 은 제외). 4절 허용 조건이 성립하면 리드가 세션 마커 `emulator_windowed_ok` 를 둔다.
- 백그라운드 분리는 `setsid nohup … &` 로 한다. 도구의 run_in_background 에 의존하지 않고, 폴링 한 번이 90초를 넘지 않게 나눈다(셸 도구 시간 제한).
- 이미 `device` 인 같은 포트가 있으면 재기동하지 않는다. 그 에뮬이 창 모드이면 종료하지 말고 보고한다(내가 띄운 것만 종료).
- **Windows 의 emulator.exe 를 WSL 에서 부를 때**: 경로 인자(AVD 홈·`-datadir` 등)는 `wslpath -w` 로 변환한다. `cmd.exe /c start`·`powershell Start-Process` 로 띄우지 않는다(자식이 stdio 를 잡아 호출이 막힌다 — `agent_profiles` 의 L-022 금지 패턴). `.exe` 직접 호출에 `setsid nohup … &` 를 쓰고 stdin 은 `/dev/null` 로 닫는다. 부팅 판정은 `adb.exe`/`adb` 의 서버가 같은 것인지(Windows adb 와 WSL adb 가 둘 다 있으면 서버가 둘로 갈라진다) 먼저 `adb devices` 로 확인한다.
- 부팅 후 `wm size`·`wm density`·게스트 메모리를 증거에 기록한다. 게스트 4GB 미만 수치는 성능·ANR 결론에 쓰지 않는다.
- 헤드리스는 GPU 가속 설정이 달라 렌더가 느리거나 첫 프레임이 늦을 수 있다. 부팅이 안 되면 `-gpu swiftshader_indirect` 를 시도한다(여전히 `-no-window`).

## 2. 조작 (adb 만)

```bash
A() { "$ADB" -s "$SERIAL" "$@"; }
A shell input tap X Y                      # 좌표 탭
A shell input swipe X1 Y1 X2 Y2 300        # 스와이프
A shell input text 'abc'                   # 영문/숫자 (공백은 %s, 한글은 직접 입력 불가 → 앱 내 시험 입력 경로나 클립보드 대신 REST/딥링크 사용)
A shell input keyevent KEYCODE_BACK        # 키 (KEYCODE_ENTER, KEYCODE_HOME …)
A shell am start -W -n "$PKG/$ACT"         # 앱 기동
A shell am start -a android.intent.action.VIEW -d "<딥링크>" "$PKG"   # 딥링크 진입
A shell am force-stop "$PKG"               # 상태 초기화
# 요소 좌표: uiautomator dump → 노드의 bounds 중심 계산
A shell uiautomator dump /sdcard/ui.xml >/dev/null && A exec-out cat /sdcard/ui.xml > "$OUT/ui.xml"
# 로그: 시험 시작 직전에 비우고, 태그·패키지로 필터
A logcat -c ; A logcat -d -v time | grep -E "$PKG|AndroidRuntime|ANR" > "$OUT/logcat.txt"
```

- 탭 좌표는 `uiautomator dump` 의 `bounds="[x1,y1][x2,y2]"` 에서 구한다. 메인 스레드가 바쁘면 빈 덤프가 나오므로 `otest_mobile/scripts/tapx.sh` 재시도 경유를 쓴다.
- 매 단계 `dumpsys activity activities | grep topResumedActivity` 로 대상 앱이 앞인지 확인한다(검색앱 가로채기 방지).
- 화면 크기 변경(`wm size`)을 썼으면 끝에 `wm size reset`·`wm density reset`.

## 3. 확인 (파일로만)

```bash
A exec-out screencap -p > "$OUT/step_01.png"      # 검은 프레임이면 1~2초 뒤 재시도(최대 4회)
```

- 캡처 파일은 `Read` 계열 도구(oio file_read / image)로 열어 본다. 화면에 띄우는 뷰어·scrcpy·에뮬 창은 쓰지 않는다.
- 증거에는 `mode=headless`, `SERIAL`, `avd`, `memory`, `apk_md5`, 빌드 구성(Debug/Release)을 적는다.

## 4. 예외 — 창 모드·실기기 (엄격)

```yaml
허용_조건 (둘 중 하나만):
  - 사용자가 창 모드 또는 실기기를 ★명시 요청★ 했다(요청 원문 인용).
  - 헤드리스로 ★실패가 실측★ 됐다(기동 로그·adb 출력·재시도 횟수를 증거로 보존, -gpu 대안까지 시도한 뒤).
절차:
  - 창 모드 전: 리드에게 사전 통지한다. 사용자 유휴를 기다리지 않는다(10-19 사용자 지시 — 유휴 대기 제거, 유휴 값은 기록만).
  - 증거에 mode=windowed|device, 사유(요청 원문 또는 실패 로그 경로)를 반드시 기록한다.
  - 실기기 필수 항목(실제 푸시, 폴더블 실물, 실성능)은 원래 otest_mobile_phone 소관이라 위 허락과 무관하게 phone 으로 간다.
금지: "그냥 창이 편해서", "디버깅 편의" 는 사유가 아니다.
```

## 5. 종료·정리

```bash
A emu kill                                  # 내가 띄운 AVD 만 (다른 세션이 쓰는 에뮬 종료 금지)
"$ADB" devices                              # 사라졌는지 확인
```

- 빌드 서버(dotnet build-server·gradle daemon 등)는 시험 후 `dotnet build-server shutdown` 등으로 내려 메모리를 반환한다(에뮬 게스트 4GB + 호스트 경합 방지).
- 시험 데이터는 표식(꼬리표)으로 만들고 끝에 삭제해 잔여 0 을 실측한다(`otest_mobile` 규칙). 운영 DB에 닿는 시험은 스냅샷→표식→삭제→전후 동일 실측.
- 임시 파일(`/sdcard/ui.xml` 등)과 `$OUT` 의 대용량 캡처는 증거로 필요한 것만 남긴다.

## 6. 폴백

| 상황 | 처리 |
|---|---|
| 실기기 연결됨 | 기본 라우팅대로 `otest_mobile_phone` (이 스킬은 실기기 부재 시·에뮬 전용 항목) |
| 실기기 없음 | 이 스킬로 헤드리스 에뮬 |
| 헤드리스 부팅 실패 | `-gpu swiftshader_indirect`, 메모리 상향, 콜드 부팅(-no-snapshot-load) 순 재시도 → 로그·횟수 기록 |
| 그래도 실패 | 사유를 증거에 기록하고 해당 모바일 항목을 **PARTIAL** 로 보고(사용자 요청이 없는 한 창 모드로 내려가지 않는다. 필요 시 4절 절차로 리드에 에스컬레이션) |

## 절대 금지

1. `-no-window` 없는 emulator 실행(4절 허용 조건 외)
2. 에뮬 창·scrcpy·Android Studio 등 GUI 도구로 조작/확인
3. 내가 띄우지 않은 에뮬 종료
4. `cmd.exe /c start`·`powershell Start-Process` 로 emulator 기동
5. 헤드리스 실패 사실을 기록하지 않고 창 모드로 전환
