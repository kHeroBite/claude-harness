---
name: otest_mobile
description: "Android(.NET MAUI 등) 모바일 앱 자동화 테스트 라우터 — adb devices 로 실기기 연결을 판별해 otest_mobile_phone(실기기) 또는 otest_mobile_emulator(에뮬레이터)로 보낸다. 공통 adb 명령·검증 패턴·계정 연쇄·증거 병합(apk_md5)·tapx 재시도·ANR 감시·테스트 데이터 표식/잔여 0·ack 프로토콜·영향 파일 신선도 규칙을 보유. otest_ui에서 호출하거나 단독 호출 가능."
invocation:
  user_callable: true
  pipeline_callable: true
  called_by: ["otest_ui", "otest"]
  calls: ["otest_mobile_phone", "otest_mobile_emulator"]
---

# otest_mobile — 모바일 테스트 라우터 + 공통 규칙

> 이 스킬 이름은 기존 호출부(otest_ui·otest 모바일 축 `otest-m-{N}`·INFRA.md 헤더 mobile_test_skill)가 그대로 쓴다.
> 이름을 바꾸지 마라. 기기별 절차는 하위 스킬 2개로 나뉘었다.

| 스킬 | 담당 |
|---|---|
| `otest_mobile` (이 파일) | 기기 판별·라우팅, 공통 adb 명령, 검증 패턴, 공통 규칙, 게이트·하네스 규칙, 공통 스크립트 |
| `otest_mobile_phone` | 실기기(USB/무선 adb) — 깨우기·stayon, 패키지 공존, 접힘/펼침/팝업창 폼팩터, wm size 원복, 실 푸시(FCM) 수신 |
| `otest_mobile_emulator` | 에뮬레이터 — AVD 기동, 폼팩터별 AVD, 다중 AVD 병렬, 메모리 4GB+, Release/AOT 측정, 대형 태블릿의 실제 성능·회전 체감 |

## 스크린샷 보고 절대 규칙 (API 400 재발방지)

- PNG/JPG 등 이미지 파일을 메인 응답에 직접 첨부 금지. 메인이 이미지 Read 시도 시 `image_read_block.sh` hook 이 차단한다.
- 허용 보고 형식: 파일 경로 텍스트, UI Dump XML 발췌, logcat 발췌, 자체 분석 텍스트.
- 1MB 이상이거나 1280×720 초과 캡처는 `mcp__oio__image_resize`(max 1280×720)로 `_small` 사본을 만든 뒤 그것만 읽는다.
  `scripts/madb.sh shot` 은 최대변 1100px 사본(`$OUT/small_<이름>.png`)을 자동 생성한다.

## 프로젝트 고유값 (인자·환경변수로만 받는다)

범용 스킬이다. 패키지·액티비티·APK·adb 경로·시리얼·AVD·계정·서버 포트는 **이 스킬에 적지 않는다.**
INFRA.md "테스트 역량" 절과 "모바일 테스트 호출 경로" 절에서 읽어 환경변수로 넘긴다.

| 환경변수 | 출처 키 (INFRA.md "테스트 역량" 절) | 의미 |
|---|---|---|
| `ADB` | `mobile_adb` | adb 실행 파일 (WSL 에서 Windows adb.exe 를 쓰면 파일 인자는 `wslpath -w` 변환) |
| `PKG` / `ACT` | `mobile_package` / `mobile_main_activity` | 대상 앱 |
| `APK` | `mobile_apk` | 설치할 APK (apk_md5 계산 대상) |
| `SERIAL` | 라우팅 결과 | 대상 기기 시리얼 — 이후 모든 adb 호출에 `-s "$SERIAL"` 필수 |
| `EMULATOR` | `mobile_emulator_exe` | 에뮬레이터 실행 파일 (emulator 스킬) |
| `PHONE_SERIAL` | `mobile_phone_serial` | 테스트 전용 실기기 시리얼 (지정 시 이 기기만 phone 대상) |
| `LOG_TAGS` | `mobile_log_tags` | 앱 logcat 태그 필터 |
| `OUT` | 세션 작업 디렉토리 | 스크립트 산출물 루트 (기본 `./otest_mobile_out`) |

## 라우팅 (Step 0 — 반드시 먼저)

```bash
DEV=$("$ADB" devices | tr -d '\r')
# 실기기 후보 — 하드웨어 시리얼(ro.serialno)로 대조하므로 USB 시리얼과 무선 IP:포트가 같은 기기로 잡힌다.
# PHONE_SERIAL(테스트 전용 기기의 ★하드웨어 시리얼★)이 있으면 그 기기만 인정 (사용자 개인 폰 오조작 방지)
REALS=$(bash scripts/dev_id.sh reals)
EMUS=$(echo "$DEV"  | awk 'NR>1 && $1 ~ /^emulator-/  && $2=="device" {print $1}')
UNAUTH=$(echo "$DEV" | awk 'NR>1 && $2=="unauthorized" {print $1}')
# adb -s 에 쓸 SERIAL — 같은 기기가 USB·무선 둘 다 붙어 있으면 USB 우선
[ -n "$PHONE_SERIAL" ] && SERIAL=$(bash scripts/dev_id.sh resolve "$PHONE_SERIAL")
# 사용권·원복 상태·원장의 기기 키는 하드웨어 시리얼: HWID=$(bash scripts/dev_id.sh hwid "$SERIAL")
```

| 판정 | 라우팅 |
|---|---|
| `adb devices` 에 `emulator-*` 가 아닌 **`device` 상태** 실기기 1대 이상 | `Skill('otest_mobile_phone')` — SERIAL=실기기 |
| 실기기 없음(또는 unauthorized 만) | `Skill('otest_mobile_emulator')` — SERIAL=기동 중 에뮬 또는 AVD 기동. **에뮬레이터 시험은 기본적으로 `Skill('otest_mobile_emulator_bg')`(헤드리스 `-no-window`)로 한다** — 창 모드는 사용자 요청·헤드리스 실패 실측 시만 |
| 실기기 `unauthorized` | 사용자에게 1회 "USB 디버깅 허용(항상 허용)" 요청 후 5초×12회 재확인. 그래도 안 되면 에뮬 경로 |
| 둘 다 불가 | 즉시 실패 보고 |

- 실기기와 에뮬이 함께 `device` 여도 기본은 **phone**. 대형 태블릿 **레이아웃**은 앱이 창 폭(dp) 기준이면 실기기에서 dp 맞춤 재현(`otest_mobile_phone` 4-3절)으로 한다. 대형 태블릿의 **실제 성능·회전 체감**이 필요한 항목만 `otest_mobile_emulator` 를 **명시 호출**한다.
- 계획서(acceptance)가 기기 종류를 지정했으면(예: device_model 요구) 라우팅보다 계획서가 우선이다.
- 보고에는 항상 `TARGET_KIND(phone|emulator)`, `SERIAL`, `device_model`(`getprop ro.product.model`)을 적는다.

### 병렬 모드 — 실기기 + 에뮬 동시 (조건부, 기본은 실기기 단독)

실측 근거(같은 APK·계정·서버, L2): 에뮬은 실기기보다 화면 조작 4~6배·로그인→차트 8.7배·설치 10배 느리다.
같은 항목들을 속도비 r(에뮬/실기기)로 나눠 병렬로 돌려도 전체는 `실기기 단독 × r/(r+1)` — r=5 이면 17%, r=9 이면 10% 줄 뿐이고,
에뮬 쪽 준비(설치 1.5~4분 + 로그인 0.5~1.5분)·호스트 경합(에뮬 과부하 시 ANR·프레임 수초)이 그 이득을 쉽게 지운다.
⇒ **"공통 항목을 나눠 돌리기" 는 단축이 확실하지 않다. 단축이 확실한 경우는 아래 1)뿐이다.**

| 조건 | 판정 |
|---|---|
| 1) **에뮬 전용 항목**(대형 태블릿 성능·회전 체감, 다중 해상도 매트릭스 등 실기기로 못 하는 항목)이 있고, 실기기 항목도 있다 | **병렬** — 에뮬 전용 항목을 에뮬에서 동시에 돌린다. 단축 = min(실기기 항목 시간, 에뮬 전용 항목 시간) — 나누는 손실이 없다 |
| 2) 공통 항목만 있고, 실기기 단독 예상 ≥ 30분, 항목끼리 서버 상태를 공유하지 않으며, 아래 공통 전제를 모두 만족 | **선택적 병렬** — 첫 공통 항목을 양쪽에서 1회 재서 r 을 정하고, 에뮬에는 전체의 1/(r+1) 만 준다. 예상 단축이 에뮬 준비 시간보다 작으면 하지 않는다 |
| 그 밖(항목 적음·서버 상태 공유·공통 전제 불충족) | **실기기 단독** |

공통 전제(하나라도 아니면 병렬 금지):
- **호스트 여유**: 여유 메모리 ≥ 6GB(에뮬 게스트 4GB + 에뮬 자체), 에뮬 게스트 `uptime` load average < 게스트 vCPU 수. 빌드가 도는 중이면 빌드가 끝난 뒤.
- **기기별 계정 분리**: 같은 계정을 두 기기에 동시에 쓰지 않는다 — 서버가 회원 단위로 보내는 푸시·실시간 알림이 상대 기기에도 떠서 화면을 덮고(실측), 회원 단위 상태(목록 필터·읽음·토큰)가 섞인다. 계정 배정은 INFRA.md 를 따른다.
- **기기별 표식 분리**: 테스트 데이터 표식에 기기 꼬리표를 붙인다(예: `[cNNNtest-P]` / `[cNNNtest-E]`) — 정리·잔여 0 실측을 기기별로 한다.
- **기기별 사용권**: 두 기기 모두 `device_lease.sh acquire` — 한 에이전트가 두 기기를 쥐지 않는다. 에이전트는 기기마다 1개(자원 축당 1개). 라우터를 부른 쪽이 항목 목록을 둘로 나눠 각 에이전트에 준다.
- **같은 APK**: 두 기기의 설치 APK md5 가 같아야 한다(`test_ledger.py apk-check`). 다르면 병렬 결과를 합치지 않는다.

결과 병합·실패 처리:
- 증거는 항목마다 `TARGET_KIND·SERIAL·device_model·apk_md5` 를 남기고 `build_evidence.py` 로 합친다. 기기를 요구하는 항목(device_model 지정)은 그 기기 결과만 인정한다.
- 한쪽이 실패·중단(기기 분리·에뮬 ANR 반복)하면 그쪽 미완 항목을 `test_ledger.py` 로 넘겨 남은 기기에서 이어 한다 — 다른 쪽 결과는 버리지 않는다.
- 병렬 여부와 근거(호스트 여유 수치·r·예상 단축)를 보고서 첫 줄에 적는다.

## 공통 adb 명령 (정본 — 모든 호출에 `-s "$SERIAL"`)

```bash
"$ADB" -s "$SERIAL" shell getprop sys.boot_completed          # 1 = 부팅 완료
"$ADB" -s "$SERIAL" shell pidof "$PKG"                        # 앱 PID
"$ADB" -s "$SERIAL" shell "dumpsys activity activities | grep topResumedActivity"
"$ADB" -s "$SERIAL" shell am start -n "$PKG/$ACT"             # 실행
"$ADB" -s "$SERIAL" shell am force-stop "$PKG"                # 강제 종료
"$ADB" -s "$SERIAL" shell pm clear "$PKG"                     # 데이터 초기화(로그아웃)
"$ADB" -s "$SERIAL" install -r "$(wslpath -w "$APK")"         # 설치 — Windows adb.exe 는 Windows 경로 필수
"$ADB" -s "$SERIAL" exec-out screencap -p > shot.png          # 캡처(>10KB 정상)
"$ADB" -s "$SERIAL" exec-out cat /sdcard/ui.xml > ui.xml      # 덤프 회수 — adb pull 로 /tmp 직접 불가(Windows adb)
"$ADB" -s "$SERIAL" shell input tap X Y | input text "abc" | input keyevent 66
"$ADB" -s "$SERIAL" shell input swipe X1 Y1 X2 Y2 500         # 스크롤 / X Y X Y 1000 = 길게 누르기
"$ADB" -s "$SERIAL" logcat -d -t 100                          # 덤프 모드만(-f/follow 금지)
"$ADB" -s "$SERIAL" shell wm size ; wm density                # 화면 메타
```

- 키: ENTER 66 · BACK 4 · TAB 61 · DEL 67 · ESC(IME 닫기) 111 · PASTE 279 · MOVE_END 123 · WAKEUP 224
- 한글은 `input text` 미지원 → 클립보드 경유(앱이 제공하는 경로) 또는 ADBKeyboard IME.
- 공백은 `input text "a%sb"`.

### 공통 스크립트 (`scripts/`)

| 파일 | 역할 |
|---|---|
| `madb.sh` | 단일 기기 조작 헬퍼 — `shot`(검은 프레임 재시도·축소본)·`dump`(빈 덤프 3회 재시도·ANR 대화상자 Wait)·`tap`·`text`·`key`·`swipe`·`start`·`stop`·`log`·`fatal`·`login` |
| `tapx.sh` | 정규식으로 노드를 찾아 탭 — uiautomator 빈 덤프 대비 N회 재덤프. 못 찾으면 rc=1 + `tapx_fail.log` |
| `acct_chain.sh` | 계정 TSV × 단계 목록을 **계정 단위 직렬**로 실행, 단계별 rc·소요를 `chain_summary.tsv` 에 기록 |
| `flow_chain.sh` | 화면 흐름 템플릿(헬퍼 T·dmp·xy·tapx·waitlog·fail) — 복사해서 흐름만 채운다 |
| `anr_catcher.sh` | ANR 창 감시 → 스택(debuggerd, root)·logcat·lastanr·/data/anr 목록 자동 수집, stop 파일로 종료 |
| `mainthread_sample.sh` | 메인 스레드 스택 N회 샘플링(정지 구간 프레임 포착, root). Mono 앱은 MONO_DEBUGGERD_GUARD 가 거부(rc=3) |
| `build_evidence.py` | 계정별 조각 JSON 병합 → 증거 JSON. **apk_md5 필수**, 항목별 영향 파일 신선도, 원자료 경로 실존 확인 |
| `dev_id.sh` | 실기기 식별을 하드웨어 시리얼(ro.serialno)로 통일 — `hwid`·`resolve`(USB 우선, 없으면 무선 IP:포트)·`reals`·`kind`. USB·무선을 같은 기기로 본다. `ADB_HWID_MAP` 으로 모의 |
| `device_lease.sh` | 공유 기기 사용권(acquire/release/status) + 단계 체크포인트(checkpoint/resume) — 교대·기기 전환·외출 후 이어하기(L11). 무선 시리얼이 와도 하드웨어 시리얼 키로 같은 사용권 |
| `device_watch.sh` | 매 단계·대기 주기 기기 재확인 → TARGET·EVENT(PHONE_LOST/PHONE_BACK/EMU_UP/DOWN)·ACTION 출력, 범위 마커 우선, `ADB_DEVICES_FILE` 로 분리 모의(L21) |
| `test_ledger.py` | 진행 원장 — 항목 상태·기기·apk_md5·계정, 다음 항목 결정(실기기 필수 항목은 에뮬에서 '실기기 대기'), 보류 원복 목록, apk 대조(L21) |
| `fcm_send_one.py` | FCM HTTP v1 으로 토큰 1개에만 직접 발송(제목 사이클 표식 필수, --dry-run) — 단말 수신 확인 전용(phone L12) |

기기별 스크립트는 각 하위 스킬 `scripts/` 에 있다(phone: `phone_session.sh`·`window_mode.sh`·`notif_capture.sh`, emulator: `avd_boot.sh`).

## 표준 검증 패턴

### 패턴 A — 로그인 + 첫 화면 도달
1. `am force-stop` → `logcat -c` → `am start` → 앱 초기화 대기(로그의 준비 완료 신호로 판정, 고정 sleep 은 하한만).
2. `madb.sh dump` 로 ID 필드 좌표 확보.
3. **ID 필드 탭 → text → TAB(61) → text → ENTER(66)**. 비밀번호 필드를 좌표로 누르지 않는다(IME 와 겹쳐 오입력 실측).
4. `madb.sh kbhide`(떠 있을 때만 BACK) — `madb.sh kb` = false 확인(L22). `madb.sh login` 은 끝에서 자동으로 한다.
5. 덤프에서 로그인 사용자 표식 텍스트 확인 + 캡처.

### 패턴 B — 스크롤 다중 캡처
`for i in 1..N: shot → swipe(아래→위) → sleep` 후 캡처를 순차 확인. 캡처마다 축소본 사용.

### 패턴 C — 권한·역할별 분기
계정 목록을 `acct_chain.sh` 로 직렬 실행한다. 계정 전환은 앱의 로그아웃 경로 또는 `pm clear`.
- **정리 순서는 앱 로그아웃 → `pm clear` 다(반대 금지).** 서버의 푸시 토큰 해제는 앱 로그아웃이 기기 식별자(DeviceId 등 앱 저장값)를 실어 보낼 때만 일어난다. `pm clear` 를 먼저 하면 그 식별자가 사라져 서버 토큰 행이 남고, 다음 설치는 새 식별자로 행을 또 만든다.
  - 실측(Mars 사이클198): 순서를 거꾸로 해 개발 서버 토큰 표에 잔여 5행이 남았다. 시험 종료 시 토큰 표를 계정·기기로 조회해 이번 시험이 만든 행이 비활성인지 확인하고, 남았으면 보고한다.

### 패턴 D — logcat 오류
측정 전 `logcat -c`, 액션 후 `madb.sh fatal`(치명 줄 수) + `$LOG_TAGS` 필터 발췌. 0건이어야 PASS.

## 공통 규칙 (phone·emulator 모두)

```yaml
계정별_연쇄_실행:
  - 같은 기기에서 계정을 병렬로 돌리지 않는다(세션 충돌). acct_chain.sh 로 계정 단위 직렬.
  - 병렬이 필요하면 기기(AVD)를 나눈다 — 계정 분할 또는 폼팩터 분할 (emulator 스킬 "다중 AVD 병렬").
  - 필수 단계('!' 접두) 실패 시 그 계정의 남은 단계는 건너뛰고 다음 계정으로 간다(전체 중단 금지).

증거_병합:
  - 계정별 조각 JSON → build_evidence.py 로 1개 증거. 자기신고 대신 원자료(로그·덤프·캡처) 경로 병기.
  - apk_md5 필수 — 설치한 APK 파일의 md5 를 증거에 넣는다. "어느 빌드를 쟀는가"가 없으면 증거 무효.
  - device_serial·device_model 기록. 계획이 특정 기기를 요구하면 모델 문자열로 대조.

tapx_재시도:
  - uiautomator dump 는 메인 스레드가 바쁘거나 덤프 자체가 크래시하면 빈 파일을 낸다 → 좌표 못 찾음 ≠ 화면에 없음.
  - 기본 dump 는 활성 창 1개만 담는다 — 텍스트 선택 플로팅 메뉴(Cut·Copy·Paste)·팝업 등 PopupWindow 는 빠진다 → "메뉴 없음" 판정은 반드시 `uiautomator dump --windows` 로 한다(기본 dump 로 '안 뜸'이라 판정한 오진 사례 있음). 창 존재는 `dumpsys window windows | grep PopupWindow` 로 교차 확인.
  - WebView 접근성 텍스트는 붙여넣기 직후 갱신되지 않을 수 있다 — 삽입 판정은 앱 로그·포커스 재획득 후 재덤프로 한다.
  - 키보드 내리기는 판정(mInputShown) 먼저 — 키보드가 없을 때 ESC/BACK 을 보내면 화면이 뒤로 이탈한다.
  - adb 실행 파일은 하나로 — 모든 호출은 `$ADB`(INFRA.md 의 단일 경로)로만 하고 이름만으로 `adb` 를 부르지 않는다. 버전이 다른 adb 가 섞이면 서버(5037)가 서로 재시작돼 기기가 offline 으로 떨어질 수 있다. 확인: `adb version`·실행 중 adb.exe 경로가 하나인지.
  - 탭은 항상 tapx.sh(재덤프 3회) 경유. 못 찾으면 마지막 덤프를 남기고 실패로 기록.

ANR_감시:
  - 장시간 측정 동안 anr_catcher.sh 를 백그라운드로 띄운다(nohup ... & disown). 종료는 touch $OUT/anr_catcher.stop.
  - ANR 대화상자는 madb.sh dump 가 Wait 로 닫고 anr_wait.log 에 기록 — 그 건수를 증거에 함께 적는다(숨기지 않는다).
  - 트레이스 자동 pull: 에뮬(root)은 debuggerd 스택, 실기기는 `adb bugreport` 의 FS/data/anr/ 를 회수.
  - ⛔ `debuggerd -b` 는 Mono(.NET MAUI/Xamarin) 앱을 SIGABRT 로 종료시킨다(`mono-threads.c:223 mono_threads_suspend_begin_async_resume` 단언 실패, 에뮬 실측 — 프로젝트별 근거는 해당 프로젝트 INFRA.md 참조).
    두 스크립트의 MONO_DEBUGGERD_GUARD 가 대상 프로세스 maps → 설치 lib/*/libmonosgen* → APK 내부 lib/*/libmonosgen*(extractNativeLibs=false 대응) 순으로 판별한다. Mono 이거나 판별 근거가 없으면(unknown) 거부한다(mainthread_sample.sh rc=3, anr_catcher.sh 는 dropbox ANR 본문으로 대체 저장). 비 Mono 확정은 maps 를 읽었고 설치 lib 의 다른 .so 또는 APK 목록이라는 적극 근거가 있을 때만이다. 강행은 `MONO_DEBUGGERD_ALLOW=1`(앱이 죽어도 될 때만).
    Mono 앱의 메인 정체는 앱 정체 로그(logcat)·`/proc/<pid>/task/<pid>/stat`·`wchan`·ANR 뒤 `dumpsys dropbox --print data_app_anr`·/data/anr·`adb bugreport` 로 본다.

테스트_데이터_표식과_잔여_0:
  - 생성하는 모든 테스트 데이터 본문/제목에 사이클 표식(예: [cNNNtest] TAG)을 넣는다.
  - 종료 시 표식으로 DB·화면을 조회해 잔여 0 을 **실측**한다("지웠다"는 자기신고 금지).
    - 개발 환경은 2026-10-10 사용자 지시로 시험 데이터 삭제 의무 없음 — 남겨도 된다. 운영 데이터 연계 환경(QA·운영)은 예외 없이 원복한다.
  - 정리 목록은 단일 파일에 append 만(타 축 otest 와 공유).

실업무_행_사전_스냅샷:
  - 기존(실업무) 행을 수정·삭제할 수 있는 조작 전에는 대상 행 SELECT 스냅샷을 먼저 파일로 남긴다.
  - 가능하면 실업무 행은 건드리지 않고 테스트 전용 행만 만든다.

금지:
  - logcat -f(follow) 무한 대기, run_in_background 로 adb 장기 실행(nohup & disown 사용)
  - bash_exec 에 PNG base64 출력, timeout_ms 미설정(최소 10000, 캡처 15000)
  - 현재 화면 가정 — 매 액션 전후 덤프/캡처로 확인
  - -s "$SERIAL" 누락 (다중 기기 환경 오전달)
```

## 실측 교훈 — 절차·원복·판정 (모바일 테스트 공통)

> 각 항목은 **절차(명령) → 원복 → 판정 기준** 순서다. 사용자 지시 21(실기기↔에뮬 전환·복귀) = L21, 22(소프트 키보드) = L22. 실기기 전용 절차(화면 설정·폴더블·푸시·토큰·딥링크·서버 대상·자격증명)는 `otest_mobile_phone` "실측 교훈 — 실기기" 절에 있다.
> 프로젝트값(시리얼·density·adb 경로·빌드 스크립트·계측 태그·계정 역할·포트·메일 수신자)은 INFRA.md 에서 읽는다.

### L1. 기기 선택 — 실기기·에뮬 동시 연결
- 절차: `adb devices -l` 로 전부 본 뒤 라우팅으로 SERIAL 을 정한다. **모든 adb 호출에 `-s "$SERIAL"`**(madb.sh 의 `A()` 가 강제한다). 실기기 우선, 대형 태블릿의 성능·회전 체감 항목만 에뮬로 보낸다(레이아웃은 실기기 dp 맞춤 — phone 4-3절).
- 원복: 해당 없음.
- 판정: 보고서에 `TARGET_KIND·SERIAL·device_model` 3개가 있어야 한다. `-s` 없는 adb 호출이 스크립트에 1건이라도 있으면 다중 기기에서 오전달 — 실패로 본다.

### L2. 속도 근거 — 실기기를 기본으로 두는 이유
- 실측(같은 APK·계정·서버): 로그인→차트 **실기 3.65초 vs 에뮬 31.64초(약 8.7배)**, 108MB APK 설치 **8.9초 vs 89.6초(약 10배)**.
- 원인: 에뮬은 소프트웨어 렌더링이고, 게스트 메모리 4GB 미만이면 수십 초로 더 늘어난다(emulator 스킬 "메모리 4GB+").
- 판정: 에뮬에서 잰 시간 값은 성능 증거로 쓰지 않는다. 실기기가 없을 때 에뮬로 잰 값은 "에뮬 기준" 으로 표기한다.

### L8. fatal 판정 — E/F 레벨만
- 절차: 측정 전 `madb.sh logc`, 액션 후 `madb.sh fatal`(`logcat -d -v brief '*:E'`). 앱 태그 발췌는 `$LOG_TAGS`.
- 판정: E/F 레벨의 FATAL·AndroidRuntime 줄만 센다. **uiautomator 가 찍는 D/I 레벨 예외 문자열은 오탐**이다 — `grep -i exception` 같은 레벨 무시 검색으로 FAIL 판정 금지.

### L9. 성능 측정 위생
- 절차:
  1. 자동로그인이 켜져 있으면 **로그아웃(또는 pm clear) 후** 측정한다 — 자동로그인 구간이 섞이면 "로그인→첫 화면" 이 오염된다.
  2. **Release 빌드**(필요하면 AOT)로 잰다. Debug 값은 참고만.
  3. 같은 시나리오를 **3회 이상** 재서 최소~최대 범위를 기록한다(1회 값 단독 보고 금지).
  4. 구간 계측은 앱 로그 태그(프로젝트값)의 시각 차로 계산한다 — 스톱워치·캡처 시각 금지.
- 원복: 측정 때문에 로그아웃했으면 끝나고 원래 로그인 상태로 되돌리거나 그 사실을 보고한다.
- 판정: 증거에 `build(Release|Debug)·runs(≥3)·range` 가 없으면 성능 항목 무효.

### L10. 빌드 — 같은 APK·비밀 주입·공유 자산 대조
- 절차:
  1. 푸시 설정 파일이 필요한 앱은 **비밀 주입 빌드 스크립트로만** 빌드한다(경로는 프로젝트값). 일반 `dotnet build` 는 푸시 설정이 빠져 푸시 초기화가 실패한다.
  2. 설치 전 APK 안의 공유 자산(예: 편집기 html)을 원본과 md5 대조한다 — `python3 -c "import zipfile,hashlib;print(hashlib.md5(zipfile.ZipFile('$APK').read('assets/<경로>')).hexdigest())"`.
  3. 공유 기기에는 **최신 소스로 다시 빌드한 APK** 를 깐다 — 오래된 APK 를 깔면 다른 담당이 방금 검증한 변경을 되돌린다.
  4. 같은 기기를 여러 담당이 쓰면 같은 APK(apk_md5)를 쓴다. 다른 APK 로 바꾸면 그 사실을 보유자에게 먼저 알린다(L11).
- 판정: 증거의 apk_md5 = 설치한 파일 md5, 공유 자산 md5 = 원본 md5.

### L11. 공유 기기 교대 · 기기 전환 · 중단 후 이어하기
- 절차:
  ```bash
  bash scripts/device_lease.sh status                                   # 누가 쓰고 있는가
  bash scripts/device_lease.sh acquire "$SERIAL" <담당> "<작업 요지>"     # rc=1 이면 보유자에게 메시지로 순서 합의
  bash scripts/device_lease.sh checkpoint <담당> <단계ID> "<메모>"        # 단계마다 진행 위치 기록
  bash scripts/device_lease.sh release "$SERIAL" <담당>                  # 끝나면 반드시
  ```
  - 기기를 쓰기 시작할 때와 끝낼 때 각각 "사용 시작 / 사용 가능" 1줄 메시지를 보낸다. 재설치(install -r)·pm clear·wm 변경 전에는 **현재 사용 중인 담당에게 먼저 통지**한다.
  - **실기기↔에뮬 전환**(예: 실기기 주인이 기기를 들고 외출): 진행 중인 단계에서 checkpoint 를 남기고 → 실기기 원복(phone_session.sh end)·release → 라우팅을 다시 돌려 에뮬로 이어 간다. 돌아오면 같은 방법으로 실기기로 되돌린다. 단계 ID 는 계정×화면 단위로 잡아 어느 기기에서도 그 단계부터 다시 시작할 수 있게 한다.
  - 기기를 바꾸면 증거의 TARGET_KIND·SERIAL·apk_md5 가 단계별로 달라진다 — 단계별로 기록하고, 성능 항목은 같은 기기의 값끼리만 비교한다.
- 원복: release 전에 그 기기의 화면 설정·로그인·알림·창 모드를 원래대로(phone "정리" 절).
- 판정: lease 파일 없이 기기를 조작한 기록이 있으면 절차 위반. stale(2시간+) lease 는 자동으로 풀지 않고 보유자에게 묻는다.

### L17. 외부 부작용 — 실발송 메일·알림
- 절차: 테스트 중 실제로 발송되는 메일·알림의 수신자는 **테스트 소유 계정으로 치환**한다(치환 계정은 프로젝트값). 수신자 해석 로직은 실제 발송 없이 별도로 검증한다(해석 결과만 로그·DB 로 확인).
- 원복: 치환 설정을 테스트 후 원래대로.
- 판정: 실제 동료에게 간 발송 0건. 발송 로그의 수신자 목록을 증거에 남긴다.

### L18. ANR — 회전·폼팩터 전환
- 절차: `anr_catcher.sh` 를 켠 상태에서 회전과 폼팩터 전환을 **각각 5회 이상** 수행하고, 마지막 전환 뒤 ANR 0 을 확인한다.
- 판정: 에뮬에서만 재현되고 실기기에서 0 이면 "소프트웨어 렌더링·메모리 기인(에뮬)" 으로 기록하고 **실기기 결과로 판정**한다. 실기기에서도 나면 결함이다.

### L19. 대기 루프와 ack (아래 "팀원_메시지_ack_프로토콜" 강화)
- 빌드·부팅·측정 대기는 ≤60초 단위로 끊고, 매 주기 메시지와 relay 파일을 확인한다.
- 리드 지시는 다음 도구 호출 전에 ack 1줄 — 예외 없음. 장시간 루프 안에서도 같다.

### L20. 명령 안전 — bash -c 한 덩어리 + 절대경로
- 절차: 변수와 cd 를 쓰는 다단계 명령은 `bash -c '...'` **한 덩어리**로 보내고 경로는 **절대경로**로 쓴다. 도구 셸이 dash 이거나 명령을 `&&`·`;` 로 나눠 따로 실행하면 앞에서 만든 변수가 뒤 명령에서 비고 cwd 가 엉뚱한 곳일 수 있다.
- 실사고: `&&` 로 나뉜 명령에서 압축 해제 대상 디렉토리 변수가 비어 **홈 디렉토리에 tar 가 풀렸다**.
- 판정: 파괴적 명령(rm·tar -x·mv)은 실행 전 대상 경로를 echo 로 찍고, 빈 변수면 중단(`: "${X:?빈 값}"`).

### L21. 테스트 도중 실기기↔에뮬 전환·복귀 (외출·재연결)
- **a) 기기 감시** — 시작 때 1회만 확인하지 않는다. 대기 루프와 **각 단계 시작마다** `scripts/device_watch.sh once` 를 돌린다.
  - `EVENT=PHONE_LOST ACTION=switch_to_emulator` → 진행 중 항목을 `test_ledger.py wait-phone <id>` 로 돌려놓고 에뮬로 이어 간다. 에뮬이 없으면 `ACTION=boot_emulator`(`--auto-boot` + `EMU_AVD` 면 스크립트가 기동).
  - `EVENT=PHONE_BACK ACTION=reconnect_phone` → 아래 e) 재연결 절차 후 실기기로 돌아온다.
  - 보조 신호(사용자 발화): 사용자가 "휴대폰 뺀다 / 다시 연결했다" 라고 말하면 **메인이** 세션 범위 마커에 기록한다. 팀원은 마커를 쓰지 않고 마커 gate 로 받는다.
  - **메인 기록 형식** — `${SESSION_DIR}/scope_markers/_all.json` 에 레코드 1개를 추가한다:
    ```json
    {"type": "SCOPE|INFO", "phone": "away|back", "ts": "<ISO 시각>", "by": "team-lead", "message": "[사용자 지시 HH:MM] <원문>"}
    ```
    - `phone` 키가 판정의 정본이다. 마커 gate 는 `message` 만 전달하므로 **팀원 화면에는 문장만 보인다** — 스크립트는 gate 출력이 아니라 **마커 파일 JSON 을 직접 읽는다**.
  - **판정 순서** (`device_watch.sh` 에 `SCOPE_MARKER=<마커 디렉토리 또는 파일>`)
    1. 마커 파일 JSON 의 `phone` 키 — 가장 최근(ts) 값. `away` 면 연결돼 있어도 실기기를 쓰지 않는다.
    2. `phone` 키가 없으면 `_all.json`·`_user.json` 의 `message` 문구 — "뺀다/제거/분리/외출" = away, "연결했다/다시 연결/재연결" = back. **"휴대폰·폰·fold·실기기" 같은 기기 단어와 함께 있을 때만** 인정한다(예: "x 를 제거하라" 는 무시).
    3. 둘 다 없으면 `adb devices`.
  - 실측(2026-10-08): 14:15 away·14:16 back 마커가 phone 키로 기록됐고, 팀원 gate 에는 문장만 도달했다 → 위 1번(파일 직접 읽기)으로 판정한다.
- **b) 휴대 안전 상태(핵심)** — 사용자는 예고 없이 케이블을 뽑는다. 뽑힌 뒤에는 기기 설정을 되돌릴 방법이 없다.
  - **단계가 끝날 때마다** `bash ../otest_mobile_phone/scripts/phone_session.sh safe` — 키보드 내림 → 팝업창 해제 → wm size/density·회전·stayon 원값 → 확인. 다음 단계는 `phone_session.sh begin` 으로 다시 시작한다.
  - 단계와 단계 사이에는 **언제 뽑아도 사용자가 그대로 쓸 수 있는 상태**를 유지한다. 장시간 변형(예: 태블릿 dp 재현)은 그 단계 안에서만 쓰고 끝나면 바로 되돌린다.
- **c) 보류 원복** — 원복 전에 분리되면 `phone_session.sh end/safe` 가 rc=3 과 함께 `$OUT/pending_revert_<SERIAL>.env`(되돌릴 원값 목록)를 남긴다. 원장에도 `test_ledger.py pending-revert add <serial> <키> <값>` 으로 적는다. 재연결 시 **가장 먼저** 처리한다.
- **d) 진행 원장** — `scripts/test_ledger.py` 로 항목 단위 상태(대기/진행/완료/실기기 대기)·수행 기기(kind·serial·model)·apk_md5·계정을 기록한다.
  - 전환이 일어나도 처음부터 다시 하지 않는다 — `test_ledger.py next --kind <phone|emulator>` 가 다음 항목을 고른다.
  - **실기기 필수 항목은 에뮬에서 대신 하지 않는다**(증거 기준이 실기기). `requires_phone:true` 항목은 에뮬에서 `next` 가 "실기기 대기" 로 표시하고 건너뛴다. 예: 실제 푸시 수신, 실기기 성능, 접힘/펼침 전환.
- **e) 재연결 절차** (순서 고정)
  1. `phone_session.sh reconnect` — 깨우기 → 보류 원복 목록 처리(원값으로 되돌리고 확인).
  2. 설치된 APK md5 를 원장과 대조: `test_ledger.py apk-check <serial> <md5>` rc=1 이면 재설치(공유 기기는 보유자 통지 — L11).
  3. 로그인 상태·서버 선택을 덤프/로그로 확인.
  4. `phone_session.sh begin` — 원값을 다시 저장하고 stayon 재적용.
  5. `test_ledger.py next --kind phone` — "실기기 대기" 항목부터 재개.
- **f) 에뮬 대기 기동** — 실기기로 테스트하는 동안에도 에뮬을 미리 띄워 두고(또는 quick-boot 스냅샷) **같은 APK** 를 설치해 둔다. 전환이 수십 초 안에 끝난다. 게스트 메모리 4GB+.
- **g) 증거** — 모든 증거 JSON 에 device_model·serial(프로젝트값은 인자)·apk_md5. 같은 항목을 두 기기에서 했으면 둘 다(원장 `runs[]` 를 그대로 옮긴다).
- 판정: 단계 사이 `phone_session.sh safe` rc=0 기록, 원장 status 와 증거의 기기 기록 일치, "실기기 대기" 0건으로 종료(남으면 PARTIAL 보고).

### L22. 소프트 키보드 — 입력이 끝나면 내린다
- 판정 함수: `madb.sh kb` → `true|false|unknown`. `dumpsys input_method` 의 키 이름이 기기마다 달라 `mInputShown → mIsInputViewShown → isInputViewShown → mDecorViewVisible` 순서로 흡수한다.
- 내리기: `madb.sh kbhide` — **판정이 true 일 때만** ESC(111)를 보내고 다시 판정, 남아 있으면 BACK(4) 1회 후 재판정한다. 그래도 남으면 `$OUT/kb_warn.log` 에 경고. **키보드가 없을 때 BACK 을 보내지 않는다**(화면 이탈).
- `madb.sh login` 은 ENTER 뒤 2초 기다렸다 kbhide 를 한다 — 로그인 직후 캡처가 키보드에 가리던 실측(캡처 5장) 대응.
- 자동 적용: `madb.sh text`·`login` 이 끝날 때, `madb.sh shot`·`tap` 직전(가드), 단계 마무리(`phone_session.sh safe`). `tapx.sh` 는 `madb.sh tap` 을 쓰므로 함께 적용된다.
  - 입력창을 탭해 키보드를 띄우는 단계나 키보드 자체를 찍는 단계만 `KB_KEEP=1` 로 끈다.
- 증거 무효: 키보드가 하단을 가린 상태의 캡처·하단 좌표 탭 결과는 증거로 쓰지 않는다(`kb_warn.log` 에 기록이 있으면 그 이후 캡처를 다시 찍는다).
- 판정: 각 캡처 직전 `madb.sh kb` = false, 세션 마무리 때도 false.

## 게이트·하네스 규칙

```yaml
신선도_게이트_영향_파일_기준:
  - 증거 신선도는 "모바일 소스 전체 mtime" 이 아니라 **항목별 영향 파일 집합**으로 판정한다.
  - 영향 파일 = 계획 단계에서 항목마다 적은 정적 의존 목록(화면 XAML·ViewModel·서비스·공유 로직 등).
    판정 시점의 판단으로 늘리거나 줄이지 않는다 — 목록에 없는 파일 변경은 그 항목을 무효화하지 않는다.
  - build_evidence.py --impact <항목별 영향파일.json> 로 계산 → stale 항목만 재측정(1줄 수정에 전 화면 재측정 방지).
  - apk_md5 는 영향 파일과 별개로 항상 필수 — 영향 파일이 바뀌었는데 같은 apk_md5 면 재빌드 누락이다.

팀원_메시지_ack_프로토콜:
  - 리드 지시(SendMessage)를 받으면 다음 도구 호출 전에 ack 를 보낸다: "ack <지시 요지 1줄>". 리드 지시는 ack 의무.
  - 장시간 측정·빌드 대기 중에도 같다 — 대기를 끊어 메시지를 확인하고 ack 한다(지시를 묻어 둔 채 루프를 계속하지 않는다).
  - 대기 루프(빌드·부팅·측정 대기)는 1회 sleep 을 길게 잡지 말고 짧게 나눈다(≤60초 단위).
    각 턴 사이에 메시지가 배달되므로 긴 단일 대기는 그 동안의 지시를 묻어 둔다.
  - 보낸 쪽은 ack 가 없으면 1회 재발신 후, 그래도 없으면 지시 파일 중계로 전환하고 사용자/리드에 보고한다.

지시_파일_중계_표준:
  - 경로: ${SESSION_DIR}/relay/TO_<수신자>_<YYYYMMDDHHMMSS>.md (발신자가 작성, 수신자만 읽음)
  - 첫 줄: "FROM <발신자> · <시각> · <요지>". 본문은 지시 원문.
  - 수신자는 읽은 즉시 같은 디렉토리에 ACK_<원본파일명> 을 쓴다(내용: 수신 시각 + 처리 계획 1줄).
  - 발신자는 SendMessage 와 파일을 함께 보낸다 — SendMessage 는 "relay 파일 경로" 를 첫 줄에 적는다.
  - 대기 루프는 매 주기 relay/TO_<자기 이름>_* 신규 파일을 확인한다.
```

## otest_ui·otest 통합

```yaml
호출_경로:
  - otest_ui / otest 모바일 축(otest-m-{N})이 INFRA.md 헤더 mobile_test_skill 을 읽는다
  - 값 "otest_mobile" → Skill('otest_mobile') → 위 라우팅으로 phone/emulator 하위 스킬 진입
  - 완료 마커는 evidence/otest_done_m (데스크톱 otest_done 과 분리)
  - 데스크톱 앱 빌드·기동·화면 조작은 하지 않는다. 공용 서버 재기동·재배포 금지(메인 경유 요청).
```

## 보고 형식

```
🤖 otest_mobile 결과
대상: {TARGET_KIND} {SERIAL} ({device_model}) · apk_md5 {md5}
라우팅 사유: 실기기 연결 / 실기기 없음 → 에뮬 / 항목 지정(대형 태블릿 성능·회전 체감=에뮬, 레이아웃=실기기 dp 맞춤)

| 항목 | 계정 | 액션 | 결과 | 원자료 |
|---|---|---|---|---|

ANR 대화상자 Wait 처리 {n}건 · logcat 치명 {n}건 · 테스트 데이터 잔여 {n}건 · stale 항목 {n}건
종합: PASS / FAIL / PARTIAL
```
