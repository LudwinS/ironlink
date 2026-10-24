const { chromium } = require('playwright');
const path = require('path');

const screenshotDir = '/Users/ludwin/.gemini/antigravity-cli/brain/f4100e48-d450-4d4b-b4a8-e78fae134a31/screenshots';

(async () => {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const page = await context.newPage();

  console.log('Navigating to /verification...');
  await page.goto('http://localhost:3000/#/verification?email=test_web@ironlink.dev', { waitUntil: 'networkidle' });
  await page.waitForTimeout(3000);
  await page.screenshot({ path: path.join(screenshotDir, '03_verification_page.png'), fullPage: true });

  console.log('Navigating to /verification-success...');
  await page.goto('http://localhost:3000/#/verification-success', { waitUntil: 'networkidle' });
  await page.waitForTimeout(3000);
  await page.screenshot({ path: path.join(screenshotDir, '04_verification_success_page.png'), fullPage: true });

  await browser.close();
  console.log('Screenshots saved!');
})();
