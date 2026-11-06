---
name: otest_mobileweb
description: "모바일 웹(모바일 앱과 동기화되는 웹 화면) 자동화 테스트 + 앱↔웹 동기화(parity) 검증 스킬. otest 웹 축 otest-w-{N} 이 읽는다. parity_check.py 로 화면 커버리지·짝 존재·변경 짝·API 동일성(앱이 호출하던 게이트웨이 API 를 웹도 그대로 사용)을 정적으로 판정하고, 앱 결과 JSON 과 웹 결과 JSON 을 대조한다. 웹 미구축이면 N/A 로 정직 보고(PASS 금지). 프로젝트 고유값은 INFRA.md 에서 읽는다."
invocation:
  user_callable: true
  pipeline_callable: true
  called_by: ["otest", "otest_ui"]
  calls: ["otest_playwright_bg", "otest_mobile"]
---

# otest_mobileweb — 모바일 웹 테스트 + 앱↔웹 동기화 검증

> 범용 스킬이다. 프로젝트명·경로·포트·계정은 이 파일에 적지 않는다.
> 모든 고유값은 INFRA.md "테스트 역량" 절(웹 축 키)과 "모바일 웹 테스트 호출 경로" 절에서 읽는다.
> `otest_mobile`(모바일 앱 축)과 같은 구조이며, 앱 축 규칙(증거 병합·표식/잔여 0·ack 프로토콜)은 그 스킬을 따른다.

## 축 이름·마커 (절대 규칙)

| 축 | 팀원 이름 | 시작 마커 | 완료 마커 |
|---|---|---|---|
| 데스크톱 | `otest-{N}` | `evidence/otest_started` | `evidence/otest_done` |
| 모바일 앱 | `otest-m-{N}` | `evidence/otest_m_started` | `evidence/otest_done_m` |
| **모바일 웹** | **`otest-w-{N}`** | **`evidence/otest_w_started`** | **`evidence/otest_done_w`** |

- 진입 즉시 `evidence/otest_w_started` 를 만든다(내용 = 시각 1줄, `date` 실측값). odone 게이트가 이것으로 웹 축 존재를 안다.
- 완료 마커는 `evidence/otest_done_w` 만 만든다. ★`otest_done`·`otest_done_m` 은 절대 만들지 않는다★ (다른 축 게이트를 거짓으로 연다).
- 웹 축 단독 spawn 이면 `otest-w-1` + `otest_done_w`.

## 3축 병렬과 공유 자원 조정

PC(데스크톱) · 모바일 앱 · 모바일 웹은 서로 독립 축이라 동시에 돌릴 수 있다. 단 물리 자원은 직렬이다.

| 자원 | 규칙 |
|---|---|
| 빌드(축별 산출물) | 빌드 축마다 1개 에이전트(obuild 위임). 웹 빌드와 앱 빌드를 한 에이전트가 동시에 쥐지 않는다 |
| 서버/게이트웨이 포트 | 같은 개발 서버를 세 축이 공유한다. 서버 재기동·재배포는 한 축만, 나머지는 대기 |
| 테스트 계정 | 축마다 다른 계정. 같은 계정을 두 축에 동시에 쓰지 않는다(서버가 회원 단위로 푸시·상태를 보낸다). 계정 배정은 `INFRA.md` |
| 테스트 데이터 | 표식에 축 꼬리표(예: `-W`/`-M`/`-P`). 정리·잔여 0 실측은 축별 |
| 브라우저 | 헤드리스 우선(`otest_playwright_bg`). 포그라운드 브라우저는 사용자 요청·실패 실측 시만 |
| 사용자 화면 | 사용자 테스트 중 에이전트 UI 조작 금지 — 헤드리스로 한다 |

## 프로젝트 고유값 (인자·환경변수로만)

| 환경변수 | 출처 키 (INFRA.md "테스트 역량" 절) | 의미 |
|---|---|---|
| `WEB_URL` | `mobileweb_url` | 모바일 웹 진입 URL |
| `WEB_BROWSER_SKILL` | `mobileweb_browser_skill` | 브라우저 자동화 스킬(기본 `otest_playwright_bg`) |
| `PARITY_JSON` | `mobileweb_parity_json` | 대응표 경로 |
| `REPO` | 저장소 루트 | parity 경로 해석 기준 |
| `OUT` | 세션 작업 디렉토리 | 산출물 루트 |

키가 없으면 "웹 미구축 또는 미설정" 으로 보고하고 아래 N/A 규칙을 따른다. 값을 추측하지 않는다.

## 동기화 검증 절차 (필수 — parity_check → 런타임 대조)

### 1단계 — 정적 판정 (`scripts/parity_check.py`)

```bash
python3 scripts/parity_check.py --parity "$PARITY_JSON" --repo "$REPO" --base "<git 기준>" --json
```

판정층(앞 층이 FAIL 이어도 전 층을 돌려 사유를 모은다):

| 층 | 내용 | FAIL 조건 |
|---|---|---|
| 1 커버리지 | `app_screen_globs` 로 잡힌 앱 화면 파일이 전부 `items[].app` 에 등재 | 미등재 파일 |
| 2 짝 존재 | `synced` 항목의 앱·웹 파일 실재 | 파일 없음, 웹 목록 비어 있음 |
| 3 변경 짝 | `git diff <base>`(작업트리+미추적)에서 synced 항목의 앱/웹 한쪽만 변경 | 사유(`change_exemption`) 없는 한쪽 변경 |
| 4 **API 동일성** | 앱 소스·웹 소스에서 `call_patterns` 로 게이트웨이 호출 식별자를 뽑아 집합 비교 | 웹에만/앱에만 있는 호출(사유 있는 `api_exemptions` 제외), `forbidden_web_patterns` 에 걸리는 웹의 별도 HTTP 직접 호출 |
| 5 런타임 대조 | 앱 결과 JSON vs 웹 결과 JSON 의 `runtime.fields` 비교 | 필드 값 불일치 (입력 없으면 N/A) |

- **API 동일성은 사용자 지시다**: 모바일 웹도 모바일 앱이 호출하던 API/엔드포인트를 그대로 동일하게 쓴다. 웹이 자기만의 REST 경로를 새로 부르면 FAIL 이다.
- 추출 규칙(`call_patterns`)·금지 패턴은 전부 `parity.json` 이 정한다. 스크립트에는 프로젝트 고유 이름이 없다.
- 예외는 사유가 있을 때만 통과한다. 사유 빈 문자열은 FAIL.
- 종료코드: `0` PASS · `1` FAIL · `2` INPUT(파일/정규식/git 기준 오류) · `3` N/A(웹 미구축, synced 0건) · `4` PARTIAL(정적 통과 + 런타임 입력 없음).

parity.json 스키마 정본은 `scripts/parity_check.py` 상단 docstring 이다. 스크립트 자체 시험: `python3 scripts/parity_selftest.py` (전 케이스 통과해야 판정기를 믿는다).

### 2단계 — 런타임 대조

1. 앱 축(`otest_mobile`)이 낸 결과 JSON 과 웹 축이 낸 결과 JSON 을 같은 계정·같은 입력으로 만든다.
2. `--app-result`/`--web-result` 로 1단계를 다시 돌려 5층을 판정한다.
3. 웹 시나리오는 `WEB_BROWSER_SKILL`(헤드리스 Playwright)로 실행하고, 화면 값·네트워크 요청 경로를 증거로 남긴다. 네트워크 요청이 앱 호출 집합 밖이면 4층 FAIL 과 같은 사유로 보고한다.

## N/A 정직 보고 규칙 (PASS 금지)

- 웹이 아직 없다(`synced` 0건, 또는 웹 URL/parity 키 미설정): 판정은 **N/A**(rc=3)다. `otest_done_w` 에는 `N/A: 웹 미구축` 으로 적고, 보고서에도 N/A 로 쓴다. PASS 로 바꿔 쓰지 않는다.
- 일부만 synced 이면 synced 항목만 판정하고 unsynced 목록과 사유를 그대로 보고한다.
- 정적만 통과하고 런타임 입력이 없으면 PARTIAL(rc=4)이다. PASS 로 쓰지 않는다.
- "0건" 은 측정값 0 인지 측정 안 함인지 구분해 적는다(호출 식별자 0건이면 추출 규칙 오류 의심).

## 증거·보고

항목마다 기록: 판정층별 결과, `parity_check.py` JSON 출력 경로, 웹 시나리오 증거 경로(스크린샷은 경로 텍스트로만 보고 — 이미지 직접 첨부 금지), 앱 쪽 `apk_md5`·웹 쪽 빌드 식별자. 보고서 첫 줄에 `AXIS=web`, `rc`, `synced 건수` 를 적는다.

## 금지

- `otest_done`/`otest_done_m` 생성, 사유 없는 예외 통과, 웹 미구축 PASS, 프로젝트 고유값 추측, parity.json 을 판정 통과용으로 임의 수정(대응표 변경은 구현 팀원 책임).
