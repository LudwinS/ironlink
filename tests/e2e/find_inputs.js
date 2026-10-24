const { chromium } = require('playwright');

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
  await page.waitForTimeout(1000);

  const inputsAndButtons = await page.evaluate(() => {
    const host = document.querySelector('flt-semantics-host');
    const all = Array.from(host.querySelectorAll('*'));
    return all.filter(el => {
      const tag = el.tagName.toLowerCase();
      const role = el.getAttribute('role');
      return tag === 'input' || tag === 'textarea' || role === 'button' || role === 'textbox' || role === 'checkbox';
    }).map(el => ({
      tag: el.tagName,
      type: el.type,
      role: el.getAttribute('role'),
      ariaLabel: el.getAttribute('aria-label'),
      text: el.innerText || el.textContent,
      rect: el.getBoundingClientRect()
    }));
  });

  console.log('Inputs and Buttons:', JSON.stringify(inputsAndButtons, null, 2));

  await browser.close();
})();
