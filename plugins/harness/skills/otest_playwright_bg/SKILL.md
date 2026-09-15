---
name: otest_playwright_bg
description: "Playwright 백그라운드 테스트. otest_ui에서 백그라운드 Agent로 실행. WSL 네이티브 Chromium headless 사용."
invocation:
  user_callable: false
  pipeline_callable: true
  called_by: ["otest_ui"]
  calls: ["otest_playwright"]
---

# otest_playwright_bg — WSL 네이티브 headless 브라우저 자동화

> ⚠️ **사용자 직접 호출 금지** — `/opwb` alias 경유 필수 (alias가 팀에이전트 spawn 처리). otest_ui 파이프라인 내부 호출은 예외.

> **otest_playwright(Windows playwright-cli)와 다름.**
> headless 전용 — WSL 네이티브 Node.js + Playwright로 실행. spawn 오버헤드 없음.

## otest_playwright vs otest_playwright_bg 차이

```yaml
otest_playwright:
  엔진: Windows playwright-cli (cmd.exe /c "playwright-cli ...")
  브라우저: Windows Chromium --headed (창 보임)
  spawn_비용: 200~500ms/회 (WSL→Windows 경계)
  용도: 디버깅, 수동 확인, 사용자 관찰 테스트

otest_playwright_bg:
  엔진: WSL 네이티브 Node.js + playwright (node /tmp/pw_script.js)
  브라우저: Linux Chromium headless (창 안 보임)
  spawn_비용: ~50ms/회 (WSL 네이티브, 경계 통과 없음)
  용도: 자동화 테스트, CI/CD, 스크린샷으로만 결과 확인

playwright_경로: $HOME/.nvm/versions/node/v24.14.1/lib/node_modules/playwright
chromium_캐시: $HOME/.cache/ms-playwright/chromium_headless_shell-1217/
```

## ⚡ 실행 패턴 (기본 — JS 파일 1개로 모든 조작 배치)

### JS 스크립트 작성 → node 1회 실행

```bash
# Step 1: oio file_write로 /tmp/pw_bg.js 작성
# Step 2: node 1회 실행
node /tmp/pw_bg.js
```

### 필수 boilerplate

```javascript
// /tmp/pw_bg.js
const { chromium } = require(process.env.HOME + '/.nvm/versions/node/v24.14.1/lib/node_modules/playwright');

(async () => {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext();
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
  } catch (e) {
    await page.screenshot({ path: '/tmp/test-error.png' });
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
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();

  // 로그인 (1회)
  await page.goto('https://example.com/login');
  await page.fill('input[name=email]', 'admin');
  await page.fill('input[name=password]', '1234');
  await page.click('button[type=submit]');
  await page.waitForURL('**/dashboard');

  // 메뉴 순회 (전부 배치 내에서 처리)
  const menus = ['workspace', 'preprocess', 'dictionary'];
  for (const m of menus) {
    await page.goto(`https://example.com/${m}`);
    await page.waitForLoadState('domcontentloaded');
    await page.screenshot({ path: `/tmp/test-${m}.png` });
    console.log(`OK:${m}`);
  }

  await browser.close();
})();
```

## 실행 방법

otest_ui 에이전트가 아래와 같이 spawn:

```yaml
Agent:
  description: "otest_playwright_bg UI 테스트"
  run_in_background: true
  prompt: |
    Skill('otest_playwright_bg') 로딩.
    oinfra_{project} 테스트 절차에 따라 UI 테스트 수행:
    1. oio file_write로 /tmp/pw_bg.js 작성 (boilerplate 기반)
    2. node /tmp/pw_bg.js 실행
    3. 스크린샷 결과 확인 (/tmp/test-*.png)
    4. 결과 요약 SendMessage
```

## 셀렉터 우선순위 (안정성 순)

```yaml
1순위: input[name=xxx] / #id / [data-testid=xxx]
2순위: button[type=submit] / a[href*=path]
3순위: text=버튼텍스트 / :has-text("텍스트")
4순위: nth-child / nth-of-type  ← 최후 수단
금지: playwright-cli ref (e17, e26 등) — 세션마다 변동, 재사용 불가
```

## 속도 체크리스트

```yaml
✅ 모든 조작(fill/click/goto/screenshot)을 JS 파일 1개에 담았는가?
✅ node 실행은 1회인가? (여러 번 node 실행 = 속도 손해)
✅ waitForLoadState('domcontentloaded') 사용 (networkidle보다 빠름)?
✅ 불필요한 sleep/timeout 없는가?
✅ headless: true 설정 확인했는가?
```

## 규칙

- **결과 보고**: 테스트 완료 시 SendMessage로 결과 요약 전달
- **스크린샷**: /tmp/test-{name}.png 저장 (증거)
- **에러 시**: 에러 스크린샷 저장 + 에러 내용 포함하여 SendMessage 보고 (파이프라인 차단 안 함)
- **headed 필요 시**: otest_playwright 스킬(Windows playwright-cli) 사용
