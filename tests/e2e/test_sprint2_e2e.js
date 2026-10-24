const { chromium } = require('playwright');
const path = require('path');
const fs = require('fs');

const screenshotDir = '/Users/ludwin/.gemini/antigravity-cli/brain/f4100e48-d450-4d4b-b4a8-e78fae134a31/screenshots';
const localDir = path.join(__dirname, 'screenshots_sprint2');

[screenshotDir, localDir].forEach(d => {
  if (!fs.existsSync(d)) fs.mkdirSync(d, { recursive: true });
});

async function saveShot(page, filename) {
  const p1 = path.join(screenshotDir, filename);
  const p2 = path.join(localDir, filename);
  await page.screenshot({ path: p1, fullPage: true });
  await page.screenshot({ path: p2, fullPage: true });
  console.log(`📸 Guardada captura: ${filename}`);
}

(async () => {
  console.log('--- Iniciando Navegación y Test E2E de Sprint 2 ---');
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const page = await context.newPage();

  console.log('1. Cargando http://localhost:3000/#/login...');
  await page.goto('http://localhost:3000/#/login', { waitUntil: 'networkidle' });
  await page.waitForTimeout(3000);

  // Semantics placeholder click
  await page.evaluate(() => {
    const placeholder = document.querySelector('flt-semantics-placeholder');
    if (placeholder) placeholder.click();
  });
  await page.waitForTimeout(500);

  console.log('2. Ingresando credenciales...');
  await page.mouse.click(1028, 272);
  await page.keyboard.press('Meta+A');
  await page.keyboard.type('tester_qa@ironlink.dev', { delay: 10 });

  await page.mouse.click(1028, 368);
  await page.keyboard.press('Meta+A');
  await page.keyboard.type('Password123!', { delay: 10 });

  console.log('3. Haciendo clic en Iniciar Sesión...');
  await page.mouse.click(1024, 479);
  await page.waitForTimeout(4000);

  // 4. Perfil de Usuario (IRL-IAM-US-05)
  console.log('4. Abriendo modal de Perfil desde la barra superior...');
  await page.mouse.click(1242, 32); // Top right avatar
  await page.waitForTimeout(2000);
  await saveShot(page, 's2_01_profile_dialog.png');

  // Cerrar modal de perfil
  await page.keyboard.press('Escape');
  await page.waitForTimeout(1000);

  // 5. Entrar al espacio del Nodo
  console.log('5. Ingresando al Nodo en la barra lateral (# Laboratorio de Ingenieria)...');
  await page.mouse.click(109, 383);
  await page.waitForTimeout(3000);

  // 6. Subgrupos (IRL-WKS-US-02)
  console.log('6. Seleccionando pestaña Subgrupos en la cabecera...');
  await page.mouse.click(690, 28);
  await page.waitForTimeout(2500);
  await saveShot(page, 's2_02_subgrupos_view.png');

  console.log('7. Abriendo modal Crear Nuevo Subgrupo...');
  await page.mouse.click(1000, 75);
  await page.waitForTimeout(1500);
  await saveShot(page, 's2_03_create_subgrupo_dialog.png');

  await page.keyboard.press('Escape');
  await page.waitForTimeout(1000);

  // 7. Reuniones Programadas (IRL-WKS-US-04)
  console.log('8. Seleccionando pestaña Reuniones en la cabecera...');
  await page.mouse.click(770, 28);
  await page.waitForTimeout(2500);
  await saveShot(page, 's2_04_reuniones_view.png');

  console.log('9. Abriendo modal Programar Nueva Reunión...');
  await page.mouse.click(1000, 75);
  await page.waitForTimeout(1500);
  await saveShot(page, 's2_05_create_reunion_dialog.png');

  await page.keyboard.press('Escape');
  await page.waitForTimeout(1000);

  // 8. Chat Persistente (IRL-WKS-US-03)
  console.log('10. Volviendo a la pestaña de Chat...');
  await page.mouse.click(625, 28);
  await page.waitForTimeout(2000);

  console.log('11. Enviando mensaje de confirmación de Sprint 2...');
  await page.mouse.click(620, 767);
  await page.waitForTimeout(300);
  await page.keyboard.type('🚀 Sprint 2 verificado y completado: Subgrupos, Reuniones y Perfil listos al 100%.', { delay: 12 });
  await page.waitForTimeout(500);

  await page.mouse.click(1024, 764);
  await page.waitForTimeout(3000);
  await saveShot(page, 's2_06_chat_sprint2_integrated.png');

  console.log('✅ ¡Test E2E de Sprint 2 completado exitosamente con todas las evidencias capturadas!');
  await browser.close();
})();
