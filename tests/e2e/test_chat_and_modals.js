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

  console.log('2. Entering Chat Workspace...');
  await page.mouse.click(109, 383);
  await page.waitForTimeout(2000);

  console.log('3. Typing chat message...');
  await page.mouse.click(620, 767);
  await page.waitForTimeout(300);
  await page.keyboard.type('¡Hola equipo! Probando el chat web persistente de IronLink en vivo.', { delay: 15 });
  await page.waitForTimeout(500);

  console.log('4. Sending chat message...');
  await page.mouse.click(1024, 764);
  await page.waitForTimeout(3000);

  await page.screenshot({ path: path.join(screenshotDir, '09_nodo_chat_message_sent.png'), fullPage: true });
  console.log('Saved 09_nodo_chat_message_sent.png');

  console.log('5. Opening Nodo Details / Settings dialog...');
  await page.mouse.click(984, 91);
  await page.waitForTimeout(2000);

  await page.screenshot({ path: path.join(screenshotDir, '10_nodo_details_dialog.png'), fullPage: true });
  console.log('Saved 10_nodo_details_dialog.png');

  // Close details dialog (clicking outside or close button)
  await page.keyboard.press('Escape');
  await page.waitForTimeout(1000);

  console.log('6. Opening Join Nodo dialog from sidebar...');
  await page.mouse.click(109, 209);
  await page.waitForTimeout(2000);

  await page.screenshot({ path: path.join(screenshotDir, '11_join_nodo_dialog.png'), fullPage: true });
  console.log('Saved 11_join_nodo_dialog.png');

  await browser.close();
})();
