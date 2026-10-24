const { chromium } = require('playwright');
const path = require('path');

const screenshotDir = '/Users/ludwin/.gemini/antigravity-cli/brain/f4100e48-d450-4d4b-b4a8-e78fae134a31/screenshots';

(async () => {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const page = await context.newPage();

  await page.goto('http://localhost:3000/#/login', { waitUntil: 'networkidle' });
  await page.waitForTimeout(3000);

  // Enable semantics
  await page.evaluate(() => {
    const placeholder = document.querySelector('flt-semantics-placeholder');
    if (placeholder) placeholder.click();
  });
  await page.waitForTimeout(500);

  // Login
  await page.mouse.click(1028, 272);
  await page.keyboard.press('Meta+A');
  await page.keyboard.type('tester_qa@ironlink.dev', { delay: 10 });
  await page.mouse.click(1028, 368);
  await page.keyboard.press('Meta+A');
  await page.keyboard.type('Password123!', { delay: 10 });
  await page.mouse.click(1024, 479);

  await page.waitForTimeout(4000);

  // Re-enable semantics on dashboard
  await page.evaluate(() => {
    const placeholder = document.querySelector('flt-semantics-placeholder');
    if (placeholder) placeholder.click();
  });
  await page.waitForTimeout(500);

  // Get elements on Dashboard
  const dashElements = await page.evaluate(() => {
    const host = document.querySelector('flt-semantics-host');
    if (!host) return [];
    return Array.from(host.querySelectorAll('*')).map(el => ({
      tag: el.tagName,
      role: el.getAttribute('role'),
      text: el.innerText || el.textContent,
      ariaLabel: el.getAttribute('aria-label'),
      rect: el.getBoundingClientRect()
    })).filter(e => e.text || e.role || e.ariaLabel);
  });

  console.log('Dashboard elements:', JSON.stringify(dashElements, null, 2));

  await browser.close();
})();
