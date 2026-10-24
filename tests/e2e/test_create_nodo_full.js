const { chromium } = require('playwright');
const path = require('path');

const screenshotDir = '/Users/ludwin/.gemini/antigravity-cli/brain/f4100e48-d450-4d4b-b4a8-e78fae134a31/screenshots';

(async () => {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const page = await context.newPage();

  console.log('1. Logging in...');
  await page.goto('http://localhost:3000/#/login', { waitUntil: 'networkidle' });
  await page.waitForTimeout(3000);

  // Semantics & Login
  await page.evaluate(() => {
    const placeholder = document.querySelector('flt-semantics-placeholder');
    if (placeholder) placeholder.click();
  });
  await page.waitForTimeout(500);

  await page.mouse.click(1028, 272);
  await page.keyboard.press('Meta+A');
  await page.keyboard.type('tester_qa@ironlink.dev', { delay: 10 });
  await page.mouse.click(1028, 368);
  await page.keyboard.press('Meta+A');
  await page.keyboard.type('Password123!', { delay: 10 });
  await page.mouse.click(1024, 479);
  await page.waitForTimeout(4000);

  console.log('2. Opening Create Nodo dialog...');
  await page.evaluate(() => {
    const placeholder = document.querySelector('flt-semantics-placeholder');
    if (placeholder) placeholder.click();
  });
  await page.waitForTimeout(500);

  await page.mouse.click(750, 366);
  await page.waitForTimeout(1000);

  console.log('3. Filling Create Nodo Form...');
  // Fill Name
  await page.mouse.click(644, 355);
  await page.keyboard.type('Laboratorio de Ingenieria', { delay: 15 });
  await page.waitForTimeout(300);

  // Fill Description
  await page.mouse.click(644, 462);
  await page.keyboard.type('Espacio colaborativo de prueba IronLink Web', { delay: 15 });
  await page.waitForTimeout(300);

  // Click "Crear nodo" submit button
  console.log('4. Submitting Create Nodo...');
  await page.mouse.click(762, 544);
  await page.waitForTimeout(4000);

  await page.screenshot({ path: path.join(screenshotDir, '07_nodos_list_updated.png'), fullPage: true });
  console.log('Saved 07_nodos_list_updated.png');

  // Inspect Dashboard with the new node
  await page.evaluate(() => {
    const placeholder = document.querySelector('flt-semantics-placeholder');
    if (placeholder) placeholder.click();
  });
  await page.waitForTimeout(500);

  const elementsAfterCreate = await page.evaluate(() => {
    const host = document.querySelector('flt-semantics-host');
    if (!host) return [];
    return Array.from(host.querySelectorAll('*')).map(el => ({
      tag: el.tagName,
      role: el.getAttribute('role'),
      text: el.innerText || el.textContent,
      rect: el.getBoundingClientRect()
    })).filter(e => e.text || e.role);
  });

  console.log('Elements after create:', JSON.stringify(elementsAfterCreate, null, 2));

  await browser.close();
})();
