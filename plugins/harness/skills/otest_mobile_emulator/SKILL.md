---
name: otest_mobile_emulator
description: "에뮬레이터 전용 Android 앱 테스트 — AVD 기동·폼팩터별 AVD(phone/fold/대형 tablet)·다중 AVD 병렬(계정·폼팩터 분할)·게스트 메모리 4GB+ 기준·Release/AOT 측정 옵션·대형 태블릿의 실제 성능·회전 체감. otest_mobile 라우터가 실기기 미연결 시, 또는 대형 태블릿 성능·회전 체감 항목에 명시 호출한다(대형 태블릿 레이아웃만이면 실기기 dp 맞춤 재현 — otest_mobile_phone 4-3절)."
invocation:
  user_callable: true
  pipeline_callable: true
  called_by: ["otest_mobile"]
  calls: []
---

# otest_mobile_emulator — 에뮬레이터 테스트

> 공통 adb 명령·검증 패턴 A~D·계정 연쇄·증거 병합·tapx·ANR 감시·ack 규칙은 `otest_mobile/SKILL.md` 가 정본이다. 여기는 **에뮬에만 있는 절차**만 둔다.
> 프로젝트 고유값(AVD 이름·패키지·APK·emulator/adb 경로)은 환경변수로 받는다(`EMULATOR`·`ADB`·`PKG`·`ACT`·`APK`).

> **기본값**: 에뮬레이터는 항상 헤드리스(`-no-window -no-audio`)로 기동·조작한다 — 상세는 `Skill('otest_mobile_emulator_bg')`. 아래 `avd_boot.sh` 는 기본이 헤드리스이며, 창 모드는 첫 인자 `--windowed` 로만 켠다(사용자 명시 요청·헤드리스 실패 실측 시). hook(`PreToolUse_oio_bash_emulator_headless_guard.sh`)이 `-no-window` 없는 emulator 직접 실행을 차단한다.

## 에뮬이 정본인 것

- **대형 태블릿(10~12인치)의 실제 성능·회전 체감·실물 화면비 캡처** — 실기기 dp 맞춤 재현으로는 성능·체감이 실물과 달라 증거가 되지 않는다. 라우터가 실기기를 골랐어도 이 항목은 이 스킬을 명시 호출한다. 레이아웃(열 수·폭·줄바꿈)만 볼 때는 앱이 창 폭(dp) 기준이면 실기기 dp 맞춤 재현(otest_mobile_phone 4-3절)으로 충분하다.
- 해상도·화면비 매트릭스 — 폼팩터별 AVD 를 병렬로 돌린다.
- root 필요 진단 — `debuggerd -b` 스택(anr_catcher·mainthread_sample)은 Google APIs(userdebug) 이미지에서 된다.

에뮬은 소프트웨어 렌더·호스트 자원 경합 영향이 있다 → **성능·실제 푸시 수신 결론은 실기기(`otest_mobile_phone`)로 낸다.** 실측 차이(같은 APK·계정·서버): 로그인→차트 실기 3.65초 vs 에뮬 31.64초(약 8.7배), 108MB 설치 8.9초 vs 89.6초(약 10배) — otest_mobile L2.
실기기를 쓰다가 기기가 빠지면(외출 등) 이 스킬로 이어 가고, 돌아오면 실기기로 되돌린다 — otest_mobile L21(`device_watch.sh`·`test_ledger.py`). 실기기 필수 항목은 여기서 대신 하지 않고 '실기기 대기' 로 둔다.
**대기 기동** — 실기기로 테스트하는 동안에도 이 에뮬을 미리 띄워 두고(quick-boot 스냅샷 허용) 같은 APK 를 설치해 둔다. 전환이 수십 초 안에 끝난다. 에뮬에서만 나는 ANR/지연은 "에뮬 한정" 으로 분류하고 실기기 재현을 시도한 뒤 우선순위를 정한다.

## Step 1 — AVD 기동

```bash
bash scripts/avd_boot.sh --list                       # 사용 가능한 AVD
bash scripts/avd_boot.sh <AVD> 5554 4096              # 포트 5554 → SERIAL=emulator-5554, 게스트 메모리 4GB
```

- 이미 `device` 인 같은 포트가 있으면 재기동하지 않는다(다른 세션이 쓰는 중일 수 있음 — 종료 금지).
- 부팅 판정은 `getprop sys.boot_completed == 1`. 그 뒤 `wm size`/`wm density` 를 기록한다.
- 백그라운드 기동은 `nohup ... & disown` (run_in_background 금지).

## Step 2 — 폼팩터별 AVD

| 폼팩터 | 권장 해상도@dpi (예) | 비고 |
|---|---|---|
| phone | 1080×2340@440 | 기본 회귀 |
| fold(펼침) | <폴더블 내부 화면 px>@<dpi> | 소형 tablet 겸용, 폴더블 AVD 는 접힘/펼침 전환 가능 — 실제 값은 INFRA.md "테스트 역량" 절 `mobile_avds` |
| 대형 tablet | 2560×1600@320 | 성능·회전 체감은 **에뮬 정본**, 레이아웃은 실기기 dp 맞춤 재현 가능 |

- 폼팩터마다 **별도 AVD** 를 두는 것이 정본이다(앱이 기동 시 화면 정보로 초기 모드를 정하는 경우가 있어, 실행 중 `wm size` 변경은 기동 시점 판정을 재현하지 못한다).
- 단일 AVD 에 `wm size`/`wm density` 로 흉내 낼 때는 **앱을 새로 기동**하고, 끝나면 `wm size reset`·`wm density reset` 을 한다(에뮬도 원복 의무 — 다음 측정 오염 방지).
- 실제 AVD 이름·해상도는 INFRA.md "테스트 역량" 절의 `mobile_avds` 에 적는다.

## Step 3 — 다중 AVD 병렬

```bash
bash scripts/avd_boot.sh <phone_avd>  5554 4096 &
bash scripts/avd_boot.sh <tablet_avd> 5556 4096 &
wait
# 기기마다 SERIAL·OUT 을 분리해서 acct_chain.sh 를 각각 실행
SERIAL=emulator-5554 OUT=$W/phone  bash ../otest_mobile/scripts/acct_chain.sh acc_A.tsv steps.txt &
SERIAL=emulator-5556 OUT=$W/tablet bash ../otest_mobile/scripts/acct_chain.sh acc_B.tsv steps.txt &
wait
```

- 분할 기준: **계정 분할**(계정 4개 → 2대×2개) 또는 **폼팩터 분할**(phone AVD·tablet AVD). 한 기기 안에서는 계정 직렬(공통 규칙).
- 같은 서버 계정을 두 기기에서 동시에 로그인하지 않는다(세션 충돌·단일 세션 정책).
- 호스트 메모리: AVD 당 게스트 4GB + 에뮬 프로세스 오버헤드. 동시 대수는 호스트 여유 메모리로 정한다 — 부족하면 병렬 이득보다 스왑 지연이 크다.
- 증거는 기기별 조각을 `build_evidence.py` 로 합친다(조각에 serial 기록).

**실기기와 병렬일 때(라우터 "병렬 모드" 조건을 만족한 경우만)** — 에뮬 쪽이 지킬 것:
- 받는 항목은 ① 에뮬 전용 항목, 또는 ② 라우터가 속도비로 나눠 준 몫뿐이다. 실기기 필수 항목(실제 푸시·폴더블·실제 성능)은 받지 않는다.
- 에뮬 시간 값은 "에뮬 기준" 으로만 적는다(실기기 성능 증거로 쓰지 않는다).
- 기동 전 호스트 여유(메모리 ≥ 6GB)를 재고, 실행 중 게스트 load average 가 vCPU 수를 넘거나 ANR 이 반복되면 남은 항목을 원장(`test_ledger.py`)으로 돌려 실기기 쪽에 넘기고 멈춘다.
- 실기기 쪽과 다른 계정·다른 표식 꼬리표를 쓴다.

## Step 4 — 게스트 메모리 4GB+ 기준

- AVD `hw.ramSize` 또는 `-memory 4096` 이상으로 기동한다. `avd_boot.sh` 는 4096 미만이면 경고한다.
- 근거(실측): 게스트 1.5~2GB 에서 화면 전환 51~55초·ANR 3건, 4GB 에서 같은 전환 7초·ANR 0건. 저메모리 측정값은 앱 결함과 구분되지 않는다.
- 측정 보고에 게스트 메모리 값을 함께 적는다.

## Step 5 — Release/AOT 측정 옵션

- 성능·체감 속도 측정은 **Release(AOT/트리밍 적용) 빌드**를 우선 검토한다. Debug(인터프리터·디버거 훅) 빌드의 지연은 실사용과 다르다.
- 기능 검증만이면 Debug 빌드도 허용하되, 증거에 빌드 구성(Debug/Release)과 apk_md5 를 반드시 적는다.
- Release 빌드는 디버그 로그가 빠질 수 있다 → 로그 신호로 판정하는 흐름(waitlog)이 Release 에서도 남는 로그인지 먼저 확인.

## 에뮬 고유 주의

```yaml
검은_캡처: 에뮬 screencap 이 간헐적으로 검은 프레임 — madb.sh shot 이 기기 설정(wm size 등)은 건드리지 않고 잠깐 기다렸다 다시 찍는다(최대 4회)
root_진단: anr_catcher.sh 의 debuggerd 스택은 userdebug 이미지에서만 — Play Store 이미지는 불가
빈_덤프: 메인 스레드가 바쁘면 uiautomator 빈 덤프 — tapx.sh 경유 필수
종료: 이 스킬이 기동한 AVD 만 종료한다(adb -s <serial> emu kill). 다른 세션 AVD 종료 금지
검색앱_가로채기: 하드웨어 키보드 모드 에뮬은 Gboard 가 하단 얇은 띠(약 132px)로 떠 있어 kb 판정이 늘 true 이고, 로그인·탭 도중 띠의 검색 버튼이 눌려 구글 검색 앱(com.google.android.googlequicksearchbox)이 앞으로 튀어나와 조작을 가로챈다(2026-10-08 실측 4회). 매 단계 topResumedActivity 가 대상 앱인지 확인하고, 반복되면 승인 후 에뮬에서만 pm disable-user → 끝나면 pm enable + pm list packages -d 로 원복 확인
```

## 절대 금지

1. 게스트 메모리 4GB 미만에서 낸 성능·ANR 수치를 결론으로 보고
2. 에뮬 단독 결과로 실기기 성능·푸시 수신 결론
3. 실행 중 `wm size` 변경만으로 "태블릿 기동 레이아웃 검증" 완료 처리(앱 재기동 없이)
4. 한 AVD 에서 계정 병렬 로그인
5. 내가 띄우지 않은 에뮬 종료
