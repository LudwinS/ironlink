const { chromium } = require('playwright');
const path = require('path');

const screenshotDir = '/Users/ludwin/.gemini/antigravity-cli/brain/f4100e48-d450-4d4b-b4a8-e78fae134a31/screenshots';

(async () => {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const page = await context.newPage();

  page.on('console', msg => console.log('BROWSER:', msg.text()));

  console.log('1. Navigating to login...');
  await page.goto('http://localhost:3000/#/login', { waitUntil: 'networkidle' });
  await page.waitForTimeout(3000);

  // Enable semantics
  await page.evaluate(() => {
    const placeholder = document.querySelector('flt-semantics-placeholder');
    if (placeholder) placeholder.click();
  });
  await page.waitForTimeout(500);

  console.log('2. Entering credentials...');
  // Click text input for email
  await page.mouse.click(1028, 272);
  await page.keyboard.press('Meta+A');
  await page.keyboard.press('Backspace');
  await page.keyboard.type('tester_qa@ironlink.dev', { delay: 20 });
  await page.waitForTimeout(300);

  // Click password input
  await page.mouse.click(1028, 368);
  await page.keyboard.press('Meta+A');
  await page.keyboard.press('Backspace');
  await page.keyboard.type('Password123!', { delay: 20 });
  await page.waitForTimeout(300);

  // Click Recuérdame
  await page.mouse.click(847, 415);
  await page.waitForTimeout(200);

  // Click Iniciar sesión
  console.log('3. Clicking Iniciar sesión...');
  await page.mouse.click(1024, 479);
  await page.waitForTimeout(5000);

  console.log('Current URL:', page.url());
  await page.screenshot({ path: path.join(screenshotDir, '05b_dashboard_logged.png'), fullPage: true });

  // Re-enable semantics on Dashboard
  await page.evaluate(() => {
    const placeholder = document.querySelector('flt-semantics-placeholder');
    if (placeholder) placeholder.click();
  });
  await page.waitForTimeout(500);

  // Click on the channel "# Laboratorio de Ingenieria" in the sidebar
  // Earlier semantics showed it at: y=362 to 405, x=0 to 219. Center is (109, 383)
  console.log('4. Entering Chat Workspace...');
  await page.mouse.click(109, 383);
  await page.waitForTimeout(3000);

  await page.screenshot({ path: path.join(screenshotDir, '08_nodo_chat_workspace.png'), fullPage: true });
  console.log('Saved 08_nodo_chat_workspace.png');

  // Inspect Chat Workspace
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

  console.log('Chat workspace elements:', JSON.stringify(chatElements, null, 2));

  await browser.close();
})();
