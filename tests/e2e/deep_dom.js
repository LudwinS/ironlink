const { chromium } = require('playwright');

(async () => {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const page = await context.newPage();

  await page.goto('http://localhost:3000/#/login', { waitUntil: 'networkidle' });
  await page.waitForTimeout(3000);

  const info = await page.evaluate(() => {
    function getStructure(node) {
      const children = [];
      for (const child of node.childNodes) {
        if (child.nodeType === 1) {
          children.push(getStructure(child));
        }
      }
      if (node.shadowRoot) {
        for (const child of node.shadowRoot.childNodes) {
          if (child.nodeType === 1) {
            children.push({ shadow: true, ...getStructure(child) });
          }
        }
      }
      return {
        tag: node.tagName,
        id: node.id,
        className: node.className,
        children: children
      };
    }
    return getStructure(document.body);
  });

  console.log('DOM Structure:', JSON.stringify(info, null, 2));

  await browser.close();
})();
