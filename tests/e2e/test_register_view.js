const { chromium } = require('playwright');
const path = require('path');
const fs = require('fs');

const screenshotDir = '/Users/ludwin/.gemini/antigravity-cli/brain/f4100e48-d450-4d4b-b4a8-e78fae134a31/screenshots';

(async () => {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const page = await context.newPage();

  page.on('console', msg => console.log('BROWSER CONSOLE:', msg.text()));

  console.log('Navigating to /register...');
  await page.goto('http://localhost:3000/#/register', { waitUntil: 'networkidle' });
  await page.waitForTimeout(3000);

  const screenshotPath = path.join(screenshotDir, '02_register_page.png');
  await page.screenshot({ path: screenshotPath, fullPage: true });
  console.log('Screenshot saved to:', screenshotPath);

  await browser.close();
})();
