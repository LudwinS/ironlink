const { chromium } = require('playwright');
const path = require('path');

const screenshotDir = '/Users/ludwin/.gemini/antigravity-cli/brain/f4100e48-d450-4d4b-b4a8-e78fae134a31/screenshots';

(async () => {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const page = await context.newPage();

  page.on('console', msg => console.log('BROWSER CONSOLE:', msg.text()));

  console.log('Navigating to http://localhost:3000/#/login...');
  await page.goto('http://localhost:3000/#/login', { waitUntil: 'networkidle' });
  await page.waitForTimeout(3000);

  // Enable semantics
  await page.evaluate(() => {
    const placeholder = document.querySelector('flt-semantics-placeholder');
    if (placeholder) placeholder.click();
  });
  await page.waitForTimeout(500);

  // Focus and fill email
  console.log('Filling email...');
  await page.evaluate(() => {
    const emailInput = document.querySelector('input[type="text"]');
    if (emailInput) {
      emailInput.focus();
      emailInput.value = 'tester_qa@ironlink.dev';
      emailInput.dispatchEvent(new Event('input', { bubbles: true }));
      emailInput.dispatchEvent(new Event('change', { bubbles: true }));
    }
  });

  // Also click and type to be 100% sure Flutter engine receives key events
  await page.mouse.click(1028, 272);
  await page.keyboard.press('Meta+A');
  await page.keyboard.type('tester_qa@ironlink.dev', { delay: 20 });
  await page.waitForTimeout(300);

  // Focus and fill password
  console.log('Filling password...');
  await page.mouse.click(1028, 368);
  await page.keyboard.press('Meta+A');
  await page.keyboard.type('Password123!', { delay: 20 });
  await page.waitForTimeout(300);

  await page.screenshot({ path: path.join(screenshotDir, '01d_login_ready.png'), fullPage: true });

  // Click login button at (1024, 479)
  console.log('Clicking Iniciar Sesión button at (1024, 479)...');
  await page.mouse.click(1024, 479);

  console.log('Waiting for login and dashboard transition...');
  await page.waitForTimeout(5000);

  console.log('URL after login:', page.url());
  await page.screenshot({ path: path.join(screenshotDir, '05_dashboard_home.png'), fullPage: true });

  await browser.close();
})();
