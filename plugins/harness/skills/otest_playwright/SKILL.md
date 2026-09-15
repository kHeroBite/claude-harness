---
name: otest_playwright
description: "Playwright 브라우저 자동화 테스트 (headed). otest_ui에서 호출. WSL 네이티브 Linux Chromium headed 모드 사용."
invocation:
  user_callable: false
  pipeline_callable: true
  called_by: ["otest_ui"]
  calls: []
---

# otest_playwright — WSL 네이티브 Linux Chromium 브라우저 자동화 (headed)

> ⚠️ **사용자 직접 호출 금지** — `/opw` alias 경유 필수 (alias가 팀에이전트 spawn 처리). otest_ui 파이프라인 내부 호출은 예외.

## 핵심 원칙

```yaml
실행_방식: WSL 네이티브 Node.js + playwright (node /tmp/pw_script.js)
브라우저: Linux Chromium headed (WSLg를 통해 사용자 데스크톱에 표시)
장점:
  - spawn 비용 ~50ms/회 (WSL 네이티브, 경계 통과 없음)
  - WSLg가 자동으로 Windows 데스크톱에 창을 띄움
  - 한글 폰트 정상 작동 (검증 완료 2026-04-30)
  - opwb(headless)와 동일 엔진 — launch 옵션만 다름
요구사항: WSLg 활성화 (DISPLAY 환경변수 자동 설정됨)
폐기:
  - Windows Chrome CDP 방식 — WSL2 네트워크 격리로 WebSocket 연결 불가
  - cmd.exe /c "playwright-cli ..." 방식 — spawn 비용 200~500ms/회로 느림 (2026-04-30 폐기)

playwright_경로: $HOME/.nvm/versions/node/v24.14.1/lib/node_modules/playwright
chromium_캐시: $HOME/.cache/ms-playwright/chromium-1217/
```

---

## otest_playwright vs otest_playwright_bg 차이 (단일 출처)

```yaml
otest_playwright (이 스킬, /opw):
  headless: false  # 사용자 화면에 창 표시
  용도: 디버깅, 수동 확인, 사용자 관찰 테스트

otest_playwright_bg (/opwb):
  headless: true   # 창 안 보임
  용도: 자동화 테스트, CI/CD, 스크린샷으로만 결과 확인

엔진은 동일: WSL 네이티브 Node.js + playwright
차이는 launch 옵션 1개: { headless: true | false }
```

---

## ⚡ 실행 패턴 (배치 — JS 파일 1개로 모든 조작)

### Step 1: oio file_write로 /tmp/pw_script.js 작성
### Step 2: node 1회 실행

```bash
node /tmp/pw_script.js
```

### 필수 boilerplate

```javascript
// /tmp/pw_script.js
const { chromium } = require(process.env.HOME + '/.nvm/versions/node/v24.14.1/lib/node_modules/playwright');

(async () => {
  const browser = await chromium.launch({
    headless: false,  // ← headed 모드 (창 보임)
    args: ['--no-sandbox']
  });
  const context = await browser.newContext({
    viewport: { width: 1280, height: 900 }
  });
  const page = await context.newPage();

  try {
    // --- 여기에 테스트 로직 ---
    await page.goto('https://example.com/login');
    await page.waitForLoadState('domcontentloaded');
    await page.fill('input[name=email]', 'admin');
    await page.fill('input[name=password]', '1234');
    await page.click('button[type=submit]');
    await page.waitForURL('**/dashboard');
    await page.screenshot({ path: '/tmp/test-dashboard.png' });
    console.log('OK:' + page.url());

    // 사용자 관찰 시간 (선택 — 디버깅 시)
    await new Promise(r => setTimeout(r, 15000));
  } catch (e) {
    await page.screenshot({ path: '/tmp/test-error.png' }).catch(() => {});
    console.error('FAIL:' + e.message);
    process.exit(1);
  } finally {
    await browser.close();
  }
})();
```

### 메뉴 순회 + 스크린샷 패턴

```javascript
const { chromium } = require(process.env.HOME + '/.nvm/versions/node/v24.14.1/lib/node_modules/playwright');

(async () => {
  const browser = await chromium.launch({ headless: false, args: ['--no-sandbox'] });
  const page = await (await browser.newContext({ viewport: { width: 1280, height: 900 } })).newPage();
  try {
    const menus = ['workspace', 'preprocess', 'dictionary'];
    for (const m of menus) {
      await page.goto(`https://example.com/${m}`);
      await page.waitForLoadState('domcontentloaded');
      await page.screenshot({ path: `/tmp/menu-${m}.png` });
      console.log(`OK:${m}`);
    }
  } finally {
    await browser.close();
  }
})();
```

---

## ⚡ 속도 최우선 원칙

```yaml
속도_우선순위:
  1순위: 단일 JS 파일에 모든 조작 묶기 (node 1회 실행)
  2순위: 헬퍼 함수로 반복 작업 추상화
  절대_금지: 각 조작마다 node 별도 spawn (50ms × N회 누적)

selector_우선순위:
  1. input[name=xxx] / #id / [data-testid=xxx]  ← 가장 안정
  2. button[type=submit] / a[href*=path]
  3. text=버튼텍스트 / :has-text("텍스트")
  4. nth-child / nth-of-type  ← 최후 수단
```

---

## 🪟 창 최소화 패턴 (WSLg + xdotool)

### 사전 요건

```bash
sudo apt install -y xdotool
```

```yaml
적용_조건: WSLg + xdotool 설치됨
미설치_시: try/catch로 최소화 스킵 — 테스트는 정상 진행
```

### 표준 코드 패턴

```javascript
// goto + waitForLoadState 이후 1.5초 대기 + 최소화
await page.goto('https://example.com');
await page.waitForLoadState('domcontentloaded');
await new Promise(r => setTimeout(r, 1500));

try {
  const wid = require('child_process')
    .execSync('xdotool search --class "chromium" 2>/dev/null', { encoding: 'utf8' })
    .trim().split('\n').filter(Boolean)[0];
  if (wid) require('child_process').execSync(`xdotool windowminimize ${wid}`);
} catch {}
```

### 검증 근거

```yaml
검증_환경: WSLg (2026-05-04 실측)
xdotool_검색: --class "chromium" 필수
  이유: WSLg는 X 창 이름을 root WM에 노출하지 않아 --name 검색 실패
  --class chromium은 정상 동작 확인됨
최소화_후_스크린샷:
  방식: Chromium DevTools Protocol (Page.captureScreenshot)
  원리: 페이지 렌더 트리를 직접 캡처 → OS 창 가시성과 무관
  결과: visible vs minimized PNG 시각적 동등, size ratio 1.022 (실측)
  DOM_텍스트_변경도_최소화_상태에서_정확히_캡처됨: 실측 확인
효과: 사용자 화면 점유 0%, 시각 검증 신뢰성 100% 유지
wmctrl_fallback: 불필요
```

---

## 디버깅: ref 확인이 필요할 때

WSL 네이티브 방식은 인터랙티브 snapshot이 없으므로 **DOM dump**로 대체:

```javascript
// /tmp/pw_inspect.js
const { chromium } = require(process.env.HOME + '/.nvm/versions/node/v24.14.1/lib/node_modules/playwright');

(async () => {
  const browser = await chromium.launch({ headless: false, args: ['--no-sandbox'] });
  const page = await (await browser.newContext()).newPage();
  await page.goto('https://example.com');
  await page.waitForLoadState('domcontentloaded');

  // 모든 input/button의 selector 후보 dump
  const elements = await page.$$eval('input, button, a', els =>
    els.map(e => ({
      tag: e.tagName,
      id: e.id,
      name: e.name,
      type: e.type,
      placeholder: e.placeholder,
      text: e.textContent?.trim().slice(0, 30)
    }))
  );
  console.log(JSON.stringify(elements, null, 2));

  await new Promise(r => setTimeout(r, 30000));  // 30초 동안 사용자가 직접 살펴봄
  await browser.close();
})();
```

---

## 주의사항

- **headless: false 필수**: opw는 사용자 관찰 목적 — false 명시 (true는 opwb에서)
- **--no-sandbox 권장**: WSL 환경에서 sandbox 권한 이슈 회피
- **WSLg 의존**: WSL2 + WSLg 활성 환경에서만 창 표시. 미활성 시 자동으로 창 안 보임 (오류 아님)
- **timeout 대비**: bash_exec timeout_ms 충분히 설정 (브라우저 launch + 페이지 로드 + 사용자 관찰 시간 합산, 최대 600000ms)
- **run_in_background 금지**: hook이 차단함 (L-303). foreground + timeout_ms 사용
- **세션 재사용 불가**: 매 node 실행마다 새 브라우저 launch — 세션 유지 필요 시 launch persistent context 사용
- **창 최소화 (WSLg)**: launch 후 xdotool로 최소화 권장 (사용자 화면 점유 방지). 미설치 시 try/catch로 스킵됨 (테스트 정상 진행). 상세: §창 최소화 패턴 섹션

## 환경 검증

```bash
# WSLg 활성 확인
echo "DISPLAY=$DISPLAY"     # :0 가 정상
ls /mnt/wslg               # 디렉토리 존재해야 함

# Linux Chromium 캐시 확인
ls $HOME/.cache/ms-playwright/chromium-1217/  # headed 브라우저 바이너리
```

## 상세 참조

- **opwb (headless 변형)**: otest_playwright_bg/SKILL.md
- **playwright API**: https://playwright.dev/docs/api/class-page
