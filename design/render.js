// SVG → 1024er PNG (Playwright aus cashclaw, wie bei Tanken)
const { chromium } = require("/root/cashclaw/node_modules/playwright-core");
const fs = require("fs");
(async () => {
  const b = await chromium.launch({ executablePath: "/root/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome" });
  const p = await b.newPage({ viewport: { width: 1024, height: 1024 } });
  await p.setContent(`<body style="margin:0">${fs.readFileSync(__dirname + "/icon.svg", "utf8")}</body>`);
  await p.locator("svg").screenshot({ path: process.argv[2] });
  await b.close();
})();
