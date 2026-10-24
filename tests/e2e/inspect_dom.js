const { chromium } = require('playwright');

(async () => {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const page = await context.newPage();

  await page.goto('http://localhost:3000/#/login', { waitUntil: 'networkidle' });
  await page.waitForTimeout(3000);

  // Click on the email input area
  await page.mouse.click(1024, 310);
  await page.waitForTimeout(500);

  const elements = await page.evaluate(() => {
    const inputs = Array.from(document.querySelectorAll('input, textarea, [contenteditable]')).map(el => ({
      tag: el.tagName,
      type: el.type,
      id: el.id,
      className: el.className,
      value: el.value,
      rect: el.getBoundingClientRect()
    }));

    const glassPane = document.querySelector('flt-glass-pane');
    let shadowInputs = [];
    if (glassPane && glassPane.shadowRoot) {
      shadowInputs = Array.from(glassPane.shadowRoot.querySelectorAll('input, textarea, [contenteditable], flt-semantics, flt-semantics-placeholder')).map(el => ({
        tag: el.tagName,
        type: el.type,
        ariaLabel: el.getAttribute('aria-label'),
        rect: el.getBoundingClientRect()
      }));
    }

    return { inputs, shadowInputs };
  });

  console.log('DOM Elements found:', JSON.stringify(elements, null, 2));

  await browser.close();
})();
