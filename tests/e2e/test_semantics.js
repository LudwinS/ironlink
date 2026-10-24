const { chromium } = require('playwright');
const path = require('path');

const screenshotDir = '/Users/ludwin/.gemini/antigravity-cli/brain/f4100e48-d450-4d4b-b4a8-e78fae134a31/screenshots';

(async () => {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const page = await context.newPage();

  await page.goto('http://localhost:3000/#/login', { waitUntil: 'networkidle' });
  await page.waitForTimeout(3000);

  console.log('Enabling Flutter accessibility semantics...');
  await page.evaluate(() => {
    const placeholder = document.querySelector('flt-semantics-placeholder');
    if (placeholder) placeholder.click();
  });
  await page.waitForTimeout(1000);

  const semanticsInfo = await page.evaluate(() => {
    const host = document.querySelector('flt-semantics-host');
    if (!host) return { error: 'No host' };
    const elements = Array.from(host.querySelectorAll('*')).map(el => ({
      tag: el.tagName,
      ariaLabel: el.getAttribute('aria-label'),
      role: el.getAttribute('role'),
      text: el.innerText || el.textContent,
      type: el.type,
      value: el.value,
      rect: el.getBoundingClientRect()
    }));
    return { count: elements.length, elements };
  });

  console.log('Semantics count:', semanticsInfo.count);
  console.log('Sample elements:', semanticsInfo.elements.slice(0, 15));

  await browser.close();
})();
