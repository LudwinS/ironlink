const { chromium } = require('playwright');
const path = require('path');

const screenshotDir = '/Users/ludwin/.gemini/antigravity-cli/brain/f4100e48-d450-4d4b-b4a8-e78fae134a31/screenshots';

(async () => {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const page = await context.newPage();

  page.on('console', msg => console.log('BROWSER CONSOLE:', msg.text()));
  page.on('pageerror', err => console.error('BROWSER ERROR:', err.message));

  console.log('Navigating to http://localhost:3000/#/login...');
  await page.goto('http://localhost:3000/#/login', { waitUntil: 'networkidle' });
  await page.waitForTimeout(4000);

  // Click email field (approx x=800, y=336)
  console.log('Clicking email input field...');
  await page.mouse.click(800, 336);
  await page.waitForTimeout(500);
  console.log('Typing email...');
  await page.keyboard.type('tester_qa@ironlink.dev', { delay: 50 });

  // Click password field (approx x=800, y=456)
  console.log('Clicking password input field...');
  await page.mouse.click(800, 456);
  await page.waitForTimeout(500);
  console.log('Typing password...');
  await page.keyboard.type('Password123!', { delay: 50 });

  // Screenshot filled form
  await page.screenshot({ path: path.join(screenshotDir, '01b_login_filled.png'), fullPage: true });

  // Click "Iniciar sesión" button (approx x=800, y=600)
  console.log('Clicking "Iniciar sesión" button...');
  await page.mouse.click(800, 600);

  console.log('Waiting for login response and redirect...');
  await page.waitForTimeout(5000);

  const currentUrl = page.url();
  console.log('Current URL after login:', currentUrl);

  const screenshotPath = path.join(screenshotDir, '05_dashboard_home.png');
  await page.screenshot({ path: screenshotPath, fullPage: true });
  console.log('Screenshot saved to:', screenshotPath);

  await browser.close();
})();
