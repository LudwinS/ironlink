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

  console.log('2. Entering Chat Workspace from sidebar channel "# Laboratorio de Ingenieria"...');
  await page.mouse.click(109, 383);
  await page.waitForTimeout(2000);

  await page.screenshot({ path: path.join(screenshotDir, '08_nodo_chat_workspace.png'), fullPage: true });
  console.log('Saved 08_nodo_chat_workspace.png');

  // Inspect Chat Workspace elements
  await page.evaluate(() => {
    const placeholder = document.querySelector('flt-semantics-placeholder');
    if (placeholder) placeholder.click();
  });
  await page.waitForTimeout(500);

  const chatElements = await page.evaluate(() => {
    const host = document.querySelector('flt-semantics-host');
    if (!host) return [];
    return Array.from(host.querySelectorAll('*')).map(el => ({
      tag: el.tagName,
      role: el.getAttribute('role'),
      text: el.innerText || el.textContent,
      type: el.type,
      rect: el.getBoundingClientRect()
    })).filter(e => e.text || e.role || e.tag === 'INPUT' || e.tag === 'TEXTAREA');
  });

  console.log('Chat elements:', JSON.stringify(chatElements, null, 2));

  await browser.close();
})();
