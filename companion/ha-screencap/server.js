// ha-screencap: renders a Home Assistant dashboard in headless Chromium and
// serves the latest screenshot as PNG. Companion service for the Basic Cable
// tvOS app's HA Dashboard channel (tvOS has no web engine).
const http = require('http');
const puppeteer = require('puppeteer-core');

const HA_URL = (process.env.HA_URL || '').replace(/\/$/, '');
const HA_TOKEN = process.env.HA_TOKEN || '';
// One or more dashboard paths (comma-separated DASH_PATHS, or the legacy
// singular DASH_PATH). With several, one page cycles through them and each
// is served at /latest/<index>.png; /latest.png stays the first.
const DASH_PATHS = (process.env.DASH_PATHS || process.env.DASH_PATH || '/lovelace/0')
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean);
const INTERVAL = Math.max(3, +(process.env.INTERVAL_SECONDS || 10));
const WIDTH = +(process.env.WIDTH || 1920);
const HEIGHT = +(process.env.HEIGHT || 1080);
const PORT = +(process.env.PORT || 8080);
const RELOAD_EVERY = Math.max(1, +(process.env.RELOAD_MINUTES || 60));
const DARK = (process.env.DARK_MODE || 'true') === 'true';

if (!HA_URL || !HA_TOKEN) {
  console.error('HA_URL and HA_TOKEN are required');
  process.exit(1);
}

const latests = DASH_PATHS.map(() => null);
const latestAts = DASH_PATHS.map(() => 0);
let consecutiveFailures = 0;
// Multi-dashboard refresh is bounded by navigation time, so allow for it
// before healthz calls a capture stale.
const STALE_SECONDS = (INTERVAL + (DASH_PATHS.length - 1) * 15) * 6;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function newPage(browser) {
  const page = await browser.newPage();
  await page.setViewport({ width: WIDTH, height: HEIGHT });
  if (DARK) {
    await page.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: 'dark' }]);
  }
  // Load the HA origin so localStorage is writable, then seed the auth the
  // same way hass-lovelace-kindle-screensaver does: a long-lived token in
  // hassTokens with a far-future expiry so the frontend never refreshes it.
  for (let attempt = 1; ; attempt++) {
    try {
      await page.goto(HA_URL + '/', { waitUntil: 'domcontentloaded', timeout: 30000 });
      break;
    } catch (e) {
      console.error(`HA unreachable (attempt ${attempt}): ${e.message}`);
      await sleep(Math.min(60000, attempt * 5000));
    }
  }
  await page.evaluate((tokens) => {
    localStorage.setItem('hassTokens', JSON.stringify(tokens));
  }, {
    access_token: HA_TOKEN,
    token_type: 'Bearer',
    expires_in: 1800,
    hassUrl: HA_URL,
    clientId: null,
    expires: 9999999999999,
    refresh_token: '',
  });
  await page.goto(HA_URL + DASH_PATHS[0], { waitUntil: 'networkidle2', timeout: 60000 });
  return page;
}

// Best-effort: hide the HA header + sidebar inside the shadow DOM so the
// capture is just the dashboard. Idempotent; silently skips on frontend
// structure changes (you just get the chrome back in frame).
async function hideChrome(page) {
  await page.evaluate(() => {
    try {
      const main = document
        .querySelector('home-assistant')
        .shadowRoot.querySelector('home-assistant-main');
      main.style.setProperty('--mdc-drawer-width', '0px');
      const drawer = main.shadowRoot.querySelector('ha-drawer');
      const sidebar = drawer && drawer.querySelector('ha-sidebar');
      if (sidebar) sidebar.style.display = 'none';
      const panel = main.shadowRoot
        .querySelector('partial-panel-resolver')
        .querySelector('ha-panel-lovelace');
      const root = panel.shadowRoot.querySelector('hui-root');
      if (root && !root.shadowRoot.querySelector('#screencap-style')) {
        const st = document.createElement('style');
        st.id = 'screencap-style';
        st.textContent =
          '.header{display:none!important}' +
          'hui-view-container{padding-top:0!important}' +
          '#view{padding-top:0!important;min-height:100vh!important}';
        root.shadowRoot.appendChild(st);
      }
    } catch (e) {
      /* frontend structure changed — capture with chrome visible */
    }
  });
}

async function captureLoop() {
  const browser = await puppeteer.launch({
    executablePath: process.env.CHROME_PATH || '/usr/bin/chromium',
    args: ['--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu', '--hide-scrollbars'],
  });
  let page = await newPage(browser);
  let shotsSinceReload = 0;
  let current = 0;
  const shotsPerReload = Math.ceil((RELOAD_EVERY * 60) / INTERVAL);
  console.log(`capturing ${DASH_PATHS.map((p) => HA_URL + p).join(', ')} @ ${WIDTH}x${HEIGHT} every ${INTERVAL}s`);

  for (;;) {
    try {
      if (DASH_PATHS.length > 1) {
        // Cycle dashboards on one page (a page per dashboard costs
        // hundreds of MB of Chromium each). Each navigation is a fresh
        // render, so the periodic reload only matters single-path.
        await page.goto(HA_URL + DASH_PATHS[current], { waitUntil: 'networkidle2', timeout: 60000 });
        await sleep(1500); // let cards settle after the route change
      }
      await hideChrome(page);
      latests[current] = await page.screenshot({ type: 'png' });
      latestAts[current] = Date.now();
      consecutiveFailures = 0;
      if (DASH_PATHS.length === 1) {
        shotsSinceReload++;
        if (shotsSinceReload >= shotsPerReload) {
          await page.reload({ waitUntil: 'networkidle2', timeout: 60000 });
          shotsSinceReload = 0;
        }
      }
    } catch (e) {
      consecutiveFailures++;
      console.error(`capture failed (${consecutiveFailures}): ${e.message}`);
      if (consecutiveFailures >= 3) {
        try { await page.close(); } catch (_) {}
        page = await newPage(browser);
        shotsSinceReload = 0;
        consecutiveFailures = 0;
      }
    }
    current = (current + 1) % DASH_PATHS.length;
    // Full pass complete — idle until the next round.
    if (current === 0) await sleep(INTERVAL * 1000);
  }
}

http
  .createServer((req, res) => {
    if (req.url.startsWith('/healthz')) {
      const dashboards = DASH_PATHS.map((path, i) => ({
        path,
        ageSeconds: latests[i] ? (Date.now() - latestAts[i]) / 1000 : null,
      }));
      const ok = dashboards.every((d) => d.ageSeconds !== null && d.ageSeconds < STALE_SECONDS);
      res.writeHead(ok ? 200 : 503, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok, dashboards }));
      return;
    }
    // /latest.png (first dashboard) or /latest/<index>.png; the bare root
    // serves the first dashboard too, so the server address alone works.
    const path = req.url === '/' || req.url.startsWith('/?') ? '/latest' : req.url;
    const match = path.match(/^\/latest(?:\/(\d+))?(?:\.png)?(?:\?|$)/);
    if (match) {
      const index = +(match[1] || 0);
      const image = latests[index];
      if (!image) {
        res.writeHead(index < DASH_PATHS.length ? 503 : 404, { 'Content-Type': 'text/plain' });
        res.end(index < DASH_PATHS.length ? 'no screenshot yet' : 'no such dashboard');
        return;
      }
      res.writeHead(200, {
        'Content-Type': 'image/png',
        'Cache-Control': 'no-store',
        'X-Captured-At': new Date(latestAts[index]).toISOString(),
      });
      res.end(image);
      return;
    }
    res.writeHead(404);
    res.end();
  })
  .listen(PORT, () => console.log(`serving on :${PORT}`));

captureLoop().catch((e) => {
  console.error(`fatal: ${e.stack || e}`);
  process.exit(1); // docker restart policy brings us back
});
