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
  await page.waitForTimeout(4000);

  // Center of right panel is 768 + 256 = 1024
  console.log('Clicking Email at (1024, 336)...');
  await page.mouse.click(1024, 336);
  await page.waitForTimeout(600);
  console.log('Typing email...');
  await page.keyboard.type('tester_qa@ironlink.dev', { delay: 40 });
  await page.waitForTimeout(600);

  console.log('Clicking Password at (1024, 456)...');
  await page.mouse.click(1024, 456);
  await page.waitForTimeout(600);
  console.log('Typing password...');
  await page.keyboard.type('Password123!', { delay: 40 });
  await page.waitForTimeout(600);

  await page.screenshot({ path: path.join(screenshotDir, '01c_login_typed.png'), fullPage: true });

  console.log('Clicking Iniciar Sesión button at (1024, 600)...');
  await page.mouse.click(1024, 600);

  console.log('Waiting for login redirect...');
  await page.waitForTimeout(5000);

  console.log('Current URL:', page.url());
  await page.screenshot({ path: path.join(screenshotDir, '05_dashboard_home.png'), fullPage: true });

  await browser.close();
})();
