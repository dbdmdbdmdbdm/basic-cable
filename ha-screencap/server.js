// ha-screencap: renders a Home Assistant dashboard in headless Chromium and
// serves the latest screenshot as PNG. Companion service for the Basic Cable
// tvOS app's HA Dashboard channel (tvOS has no web engine).
const http = require('http');
const puppeteer = require('puppeteer-core');

// Process-level safety nets: never let a stray rejection/exception take the
// process down silently. Log clearly and keep serving.
process.on('unhandledRejection', (e) => console.error('unhandledRejection', e));
process.on('uncaughtException', (e) => console.error('uncaughtException', e));

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
// Two listeners on two internal ports:
//   PORT (8080)        — the ingress-facing port. HA's authenticated ingress
//                        proxies to it; it is NOT published to the LAN, so it
//                        is the only place the admin config UI is reachable.
//   PUBLIC_PORT (8099) — published to the LAN (host :8090). Serves ONLY the
//                        public app routes (snapshots, /appconfig, /appbackup,
//                        /healthz); every admin route 403s here.
// Gating admin on *which socket the request arrived on* can't be spoofed with
// a forged X-Ingress-Path header the way a single shared listener could be.
const PORT = +(process.env.PORT || 8080);
const PUBLIC_PORT = +(process.env.PUBLIC_PORT || 8099);
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

// Optional app config: when running as the HA add-on, the add-on options
// (cameras, weather sensors, media players, ticker) are served at
// /appconfig so the Basic Cable app can be configured from HA instead of
// on-device. Plain-docker users can point APP_CONFIG_FILE at a JSON file.
const OPTIONS_PATH = process.env.APP_CONFIG_FILE || '/data/options.json';

// Options may be YAML lists (pre-1.3 schema) or comma-separated strings
// (current schema — renders label-first in the HA config UI).
const toList = (value) =>
  Array.isArray(value)
    ? value
    : String(value || '').split(',').map((s) => s.trim()).filter(Boolean);

function readOptions() {
  return JSON.parse(require('fs').readFileSync(OPTIONS_PATH, 'utf8'));
}

function buildAppConfig(opts) {
  if (!opts.app_config_enabled) return null;
  const dashNames = toList(opts.dash_names);
  return {
    // The dashboards this add-on captures become the app's dashboard
    // channels: index maps to /latest/<index>.png on this same origin,
    // names come from the parallel dash_names option.
    dashboards: DASH_PATHS.map((path, index) => ({
      index,
      name: dashNames[index] || '',
    })),
    cameras: toList(opts.cameras),
    weather_sensors: toList(opts.weather_sensors),
    weather_entity: String(opts.weather_entity || '').trim() || null,
    media_players: toList(opts.media_players),
    ticker: {
      scroll: !!opts.ticker_scroll,
      entities: (opts.ticker_entities || []).map((e) => ({
        entity: e.entity,
        name: e.name || null,
        show_when: e.show_when || null,
        color: e.color || null,
        icon: e.icon || null,
        display: e.display || null,
      })),
    },
  };
}

let appConfig = null;
try {
  appConfig = buildAppConfig(readOptions());
  if (appConfig) console.log('serving app config at /appconfig');
} catch (_) {
  /* no options file — snapshot-only mode */
}

async function newPage(browser) {
  // The whole setup retries as one unit: HA can be unreachable, and its
  // frontend can navigate (auth redirect) mid-setup, which destroys the
  // execution context under the localStorage seeding — never fatal.
  for (let attempt = 1; ; attempt++) {
    const page = await browser.newPage();
    try {
      await page.setViewport({ width: WIDTH, height: HEIGHT });
      if (DARK) {
        await page.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: 'dark' }]);
      }
      // Load the HA origin so localStorage is writable, then seed the auth
      // the same way hass-lovelace-kindle-screensaver does: a long-lived
      // token in hassTokens with a far-future expiry so the frontend never
      // refreshes it. The short settle lets any auth redirect land first.
      await page.goto(HA_URL + '/', { waitUntil: 'domcontentloaded', timeout: 30000 });
      await sleep(1500);
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
      // domcontentloaded, not networkidle2: dashboards with live camera
      // cards stream continuously and never reach network idle, so the old
      // networkidle2 wait would hit the 60s timeout. waitForReady() is what
      // actually gates the screenshot on rendered content.
      await page.goto(HA_URL + DASH_PATHS[0], { waitUntil: 'domcontentloaded', timeout: 60000 });
      await waitForReady(page);
      return page;
    } catch (e) {
      console.error(`page setup failed (attempt ${attempt}): ${e.message}`);
      try { await page.close(); } catch (_) { /* already gone */ }
      // If the *browser process* itself has died/disconnected, retrying a
      // dead handle here would loop forever and never relaunch Chromium.
      // Rethrow so control returns to captureLoop, whose `finally` closes
      // the browser and the outer `for(;;)` launches a fresh one. Transient
      // page-level errors (browser still alive) keep retrying as before.
      if (!browserConnected(browser)) {
        throw new Error(`browser disconnected during page setup: ${e.message}`);
      }
      await sleep(Math.min(60000, attempt * 5000));
    }
  }
}

// Puppeteer exposes connectivity as a `connected` getter on newer builds and
// an `isConnected()` method on older ones — check whichever exists.
function browserConnected(browser) {
  if (typeof browser.connected === 'boolean') return browser.connected;
  if (typeof browser.isConnected === 'function') return browser.isConnected();
  return true; // unknown API shape — assume alive rather than thrash
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
      // Modern HA (2024+) renders the drawer as `.sidebar-shell` (a fixed
      // 256px column) beside `.app-content`, whose `padding-left:256px` is
      // what leaves the empty band once the sidebar is hidden. Older builds
      // used mwc-drawer (`.mdc-drawer` + `.mdc-drawer-app-content` margin).
      // Zero both, inside the drawer's shadow root, so the dashboard fills
      // the frame regardless of frontend version.
      if (drawer && drawer.shadowRoot &&
          !drawer.shadowRoot.querySelector('#screencap-drawer-style')) {
        const ds = document.createElement('style');
        ds.id = 'screencap-drawer-style';
        ds.textContent =
          '.sidebar-shell{display:none!important}' +
          '.app-content{padding-left:0!important;padding-inline-start:0!important}' +
          '.mdc-drawer{display:none!important}' +
          '.mdc-drawer-app-content{margin-left:0!important;margin-inline-start:0!important}';
        drawer.shadowRoot.appendChild(ds);
      }
      // Legacy fallback: some builds slot ha-sidebar directly in ha-drawer.
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

// Wait until the dashboard is actually rendered — not just present in the
// DOM as skeleton cards — so we never screenshot a mid-hydration frame
// (blank, "Loading…", raw unformatted values, a lone spinner). We require:
//   * the HA websocket connected and entity states populated (hass ready),
//   * the lovelace view has children,
//   * no loading spinner anywhere in the lovelace subtree, and
//   * the rendered content has stopped changing between two polls (custom
//     cards like button-card paint a tick after states arrive).
// Bounded by maxMs so a genuinely stuck dashboard still yields *a* frame
// (cold Chromium after a restart can take a while to warm, hence 30s).
async function waitForReady(page, maxMs = 30000) {
  const deadline = Date.now() + maxMs;
  let lastSig = null;
  let stableHits = 0;
  for (;;) {
    let s = null;
    try {
      s = await page.evaluate(() => {
        try {
          const ha = document.querySelector('home-assistant');
          const hass = ha && ha.hass;
          if (!hass || !hass.connected) return { ok: false };
          const nStates = hass.states ? Object.keys(hass.states).length : 0;
          if (nStates < 5) return { ok: false };
          const main = ha.shadowRoot.querySelector('home-assistant-main');
          const panel = main.shadowRoot
            .querySelector('partial-panel-resolver')
            .querySelector('ha-panel-lovelace');
          const root = panel.shadowRoot.querySelector('hui-root');
          const view = root.shadowRoot.querySelector('#view');
          if (!view || view.children.length === 0) return { ok: false };
          const hasSpinner = (r, d) => {
            if (d > 10 || !r || !r.querySelector) return false;
            if (r.querySelector('ha-circular-progress, ha-spinner, paper-spinner, mwc-circular-progress, .spinner')) return true;
            for (const el of r.querySelectorAll('*')) {
              if (el.shadowRoot && hasSpinner(el.shadowRoot, d + 1)) return true;
            }
            return false;
          };
          if (hasSpinner(panel.shadowRoot, 0)) return { ok: false };
          // Signature to detect a settled render (content stopped changing).
          return { ok: true, sig: view.innerHTML.length + ':' + nStates };
        } catch (e) {
          return { ok: false }; // structure not built yet — keep waiting
        }
      });
    } catch (e) {
      // evaluate can throw mid-navigation; treat as not-ready and retry.
    }
    if (s && s.ok) {
      stableHits = s.sig === lastSig ? stableHits + 1 : 0;
      lastSig = s.sig;
      if (stableHits >= 1) return; // ready + unchanged for one extra poll
    } else {
      stableHits = 0;
      lastSig = null;
    }
    if (Date.now() >= deadline) return;
    await sleep(500);
  }
}

async function captureLoop() {
  const browser = await puppeteer.launch({
    executablePath: process.env.CHROME_PATH || '/usr/bin/chromium',
    args: ['--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu', '--hide-scrollbars'],
  });
  try {
    await captureWith(browser);
  } finally {
    try { await browser.close(); } catch (_) { /* already dead */ }
  }
}

async function captureWith(browser) {
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
        await page.goto(HA_URL + DASH_PATHS[current], { waitUntil: 'domcontentloaded', timeout: 60000 });
      }
      await waitForReady(page); // don't capture a mid-load spinner
      await hideChrome(page);
      latests[current] = await page.screenshot({ type: 'png' });
      latestAts[current] = Date.now();
      consecutiveFailures = 0;
      if (DASH_PATHS.length === 1) {
        shotsSinceReload++;
        if (shotsSinceReload >= shotsPerReload) {
          await page.reload({ waitUntil: 'domcontentloaded', timeout: 60000 });
          await waitForReady(page);
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

// ---- /config: entity-picker page for the app options ----
// The HA add-on options page can only render entity lists as text (no
// entity selectors in Supervisor schemas), so the add-on serves its own
// picker UI: searchable dropdowns fed from /api/states, saved through the
// Supervisor API (self options + restart). SUPERVISOR_TOKEN only exists
// when running as an add-on; plain-docker gets a read-only view.
const SUPERVISOR_TOKEN = process.env.SUPERVISOR_TOKEN || '';

async function fetchEntities() {
  const res = await fetch(HA_URL + '/api/states', {
    headers: { Authorization: `Bearer ${HA_TOKEN}` },
  });
  if (!res.ok) throw new Error(`HA /api/states ${res.status}`);
  const states = await res.json();
  return states.map((s) => ({
    id: s.entity_id,
    name: (s.attributes && s.attributes.friendly_name) || s.entity_id,
    domain: s.entity_id.split('.')[0],
  }));
}

async function supervisorPost(path, body) {
  const res = await fetch('http://supervisor' + path, {
    method: 'POST',
    headers: { Authorization: `Bearer ${SUPERVISOR_TOKEN}`, 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!res.ok) throw new Error(`Supervisor ${path} ${res.status}: ${await res.text()}`);
}

async function saveConfig(edit) {
  const isEntity = (v) => typeof v === 'string' && /^[a-z_]+\.[a-z0-9_]+$/.test(v);
  const listOf = (v) => (Array.isArray(v) ? v.filter(isEntity).join(',') : undefined);
  // Fresh read so edits made in the classic options page since boot survive.
  const options = readOptions();
  for (const key of ['cameras', 'weather_sensors', 'media_players']) {
    const value = listOf(edit[key]);
    if (value !== undefined) options[key] = value;
  }
  if (typeof edit.weather_entity === 'string') {
    options.weather_entity = isEntity(edit.weather_entity) ? edit.weather_entity : '';
  }
  if (typeof edit.app_config_enabled === 'boolean') {
    options.app_config_enabled = edit.app_config_enabled;
  }
  await supervisorPost('/addons/self/options', { options });
  // Options only apply on restart; reply reaches the browser first.
  setTimeout(() => {
    supervisorPost('/addons/self/restart').catch((e) => console.error(`restart failed: ${e.message}`));
  }, 1500);
}

const CONFIG_FIELDS = [
  { key: 'cameras', title: 'CAMERAS', domains: ['camera'], multi: true,
    hint: 'Security-cameras channel — list order is the grid order.' },
  { key: 'weather_sensors', title: 'WEATHER SENSORS', domains: ['sensor'], multi: true,
    hint: 'Extra "around the house" readings on the weather channel.' },
  { key: 'weather_entity', title: 'WEATHER FORECAST ENTITY', domains: ['weather'], multi: false,
    hint: 'Forecast source for the weather channel — replaces Open-Meteo.' },
  { key: 'media_players', title: 'MEDIA PLAYERS', domains: ['media_player'], multi: true,
    hint: 'Now-playing sources for the ticker.' },
];

const CONFIG_PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Basic Cable · App Config</title>
<style>
 body{background:#0a0a16;color:#eee;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;margin:0 auto;padding:26px;max-width:860px;-webkit-text-size-adjust:100%}
 h1{font-size:20px;letter-spacing:3px;margin:0 0 4px}
 p.lead{color:#889;font-size:12px;margin:0 0 18px}
 .card{background:#131327;border:1px solid #2b2b4d;border-radius:10px;padding:14px 16px;margin:14px 0}
 .card h2{font-size:13px;letter-spacing:2px;margin:0 0 2px;color:#8fb4ff}
 .hint{color:#778;font-size:11px;margin:0 0 8px}
 .chips{display:flex;flex-wrap:wrap;gap:8px;margin:8px 0}
 .chip{background:#20204a;border:1px solid #3c3c72;border-radius:8px;padding:8px 10px;font-size:13px;display:flex;gap:4px;align-items:center;max-width:100%}
 .chip>span{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
 .chip small{color:#778}
 /* Touch targets: 40px+ hit areas so fingers land reliably. */
 .chip button{background:none;border:none;color:#99a;cursor:pointer;font:inherit;font-size:15px;padding:6px 8px;margin:-6px -2px;min-width:32px}
 .chip button:hover{color:#fff}
 .menu{position:relative}
 /* 16px inputs: anything smaller makes iOS Safari zoom in on focus. */
 input[type=text]{width:100%;box-sizing:border-box;background:#0d0d1e;border:1px solid #3c3c72;border-radius:8px;color:#eee;padding:12px;font:inherit;font-size:16px}
 .opts{position:absolute;left:0;right:0;top:100%;background:#10102a;border:1px solid #3c3c72;border-radius:8px;max-height:min(260px,45vh);overflow:auto;z-index:9;display:none}
 .opts div{padding:11px 12px;cursor:pointer;font-size:14px;border-bottom:1px solid #1c1c38}
 .opts div:hover{background:#22224e}
 .opts .eid{color:#778;font-size:11px}
 label.toggle{display:flex;gap:12px;align-items:flex-start;font-size:12px;margin:14px 0;cursor:pointer;line-height:1.5}
 label.toggle input{width:20px;height:20px;flex:none;margin:0}
 #save{background:#c22;border:none;color:#fff;font:inherit;font-size:15px;letter-spacing:2px;padding:14px 26px;border-radius:8px;cursor:pointer}
 #save:disabled{background:#444;cursor:default}
 #status{margin-left:12px;font-size:12px;color:#8e8;display:inline-block;margin-top:8px}
 .ro{color:#c96;font-size:12px;margin:10px 0}
 @media (max-width:640px){
  body{padding:14px}
  h1{font-size:16px;letter-spacing:2px}
  .card{padding:12px;margin:12px 0}
  .chip small{display:none} /* friendly name only — ids don't fit a phone */
  #save{width:100%;padding:16px}
 }
</style></head><body>
<h1>BASIC CABLE · APP CONFIG</h1>
<p class="lead">Entity pickers for the app options — the classic add-on configuration page can only show these as text. Saving updates the add-on options and restarts the add-on (snapshots pause a few seconds). Dashboards, capture and ticker-chip settings stay on the classic page.</p>
<div id="fields"></div>
<label class="toggle"><input type="checkbox" id="enabled"> SERVE THIS CONFIG TO THE APP (the app's own settings are overridden while enabled)</label>
<div class="ro" id="readonly" style="display:none">READ-ONLY: not running as a Home Assistant add-on, so options can't be saved from here. Edit the container env / config file instead.</div>
<button id="save">SAVE &amp; RESTART</button><span id="status"></span>
<script>
const FIELDS = __FIELDS__;
let entities = [], sel = {}, canSave = false;
// Entity friendly-names come from HA and are rendered via innerHTML below;
// escape them so a crafted name can't inject markup into this admin page.
const esc = (s) => String(s).replace(/[&<>"']/g, (c) =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

function chipRow(key, id, multi, index, count) {
  const e = entities.find((x) => x.id === id);
  const chip = document.createElement('div'); chip.className = 'chip';
  chip.innerHTML = '<span>' + esc(e ? e.name : id) + ' <small>' + esc(id) + '</small></span>';
  if (multi && count > 1) {
    for (const [glyph, delta] of [['\\u2039', -1], ['\\u203a', 1]]) {
      const move = document.createElement('button'); move.textContent = glyph;
      move.title = 'Reorder'; move.onclick = () => {
        const j = index + delta;
        if (j < 0 || j >= count) return;
        [sel[key][index], sel[key][j]] = [sel[key][j], sel[key][index]];
        render();
      };
      chip.appendChild(move);
    }
  }
  const del = document.createElement('button'); del.textContent = '\\u2715';
  del.onclick = () => { sel[key].splice(index, 1); render(); };
  chip.appendChild(del);
  return chip;
}

function render() {
  for (const f of FIELDS) {
    const box = document.getElementById('chips-' + f.key);
    box.innerHTML = '';
    sel[f.key].forEach((id, i) => box.appendChild(chipRow(f.key, id, f.multi, i, sel[f.key].length)));
    if (!sel[f.key].length) box.innerHTML = '<span class="hint">none</span>';
  }
}

function attachSearch(f) {
  const input = document.getElementById('search-' + f.key);
  const menu = document.getElementById('opts-' + f.key);
  const show = () => {
    const q = input.value.toLowerCase();
    const hits = entities.filter((e) => f.domains.includes(e.domain)
      && !sel[f.key].includes(e.id)
      && (e.id.toLowerCase().includes(q) || e.name.toLowerCase().includes(q))).slice(0, 25);
    menu.innerHTML = '';
    for (const e of hits) {
      const row = document.createElement('div');
      row.innerHTML = esc(e.name) + ' <span class="eid">' + esc(e.id) + '</span>';
      row.onpointerdown = () => {
        if (f.multi) sel[f.key].push(e.id); else sel[f.key] = [e.id];
        input.value = ''; menu.style.display = 'none'; render();
      };
      menu.appendChild(row);
    }
    menu.style.display = hits.length ? 'block' : 'none';
  };
  input.oninput = show;
  input.onfocus = show;
  input.onblur = () => setTimeout(() => { menu.style.display = 'none'; }, 150);
}

async function init() {
  const holder = document.getElementById('fields');
  for (const f of FIELDS) {
    const card = document.createElement('div'); card.className = 'card';
    card.innerHTML = '<h2>' + f.title + '</h2><p class="hint">' + f.hint + '</p>'
      + '<div class="chips" id="chips-' + f.key + '"></div>'
      + '<div class="menu"><input type="text" id="search-' + f.key
      + '" placeholder="Search ' + f.domains.join('.') + '.* entities\\u2026" autocomplete="off">'
      + '<div class="opts" id="opts-' + f.key + '"></div></div>';
    holder.appendChild(card);
  }
  const current = await (await fetch('config/current')).json();
  canSave = current.can_save;
  for (const f of FIELDS) sel[f.key] = current[f.key] || [];
  document.getElementById('enabled').checked = !!current.app_config_enabled;
  if (!canSave) {
    document.getElementById('readonly').style.display = 'block';
    document.getElementById('save').disabled = true;
  }
  entities = await (await fetch('config/entities')).json();
  for (const f of FIELDS) attachSearch(f);
  render();
}

document.getElementById('save').onclick = async () => {
  const status = document.getElementById('status');
  const body = { app_config_enabled: document.getElementById('enabled').checked };
  for (const f of FIELDS) body[f.key] = sel[f.key];
  body.weather_entity = (sel.weather_entity && sel.weather_entity[0]) || '';
  status.textContent = 'SAVING\\u2026';
  const res = await fetch('config/save', { method: 'POST',
    headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  if (!res.ok) { status.textContent = 'SAVE FAILED: ' + await res.text(); return; }
  status.textContent = 'SAVED \\u2014 RESTARTING ADD-ON\\u2026';
  // The add-on restarts to apply options; wait for it to come back.
  await new Promise((r) => setTimeout(r, 6000));
  for (let i = 0; i < 30; i++) {
    try { if ((await fetch('healthz')).status < 500) break; } catch (_) {}
    await new Promise((r) => setTimeout(r, 3000));
  }
  status.textContent = 'SAVED \\u2713';
};

init();
</script></body></html>`.replace('__FIELDS__', JSON.stringify(CONFIG_FIELDS));

// Anti-DNS-rebinding Host allowlist. A malicious web page can point its own
// domain (attacker.com) at this add-on's LAN IP:port and have the victim's
// browser make same-origin requests to us. Blocking that is a matter of
// rejecting any Host header that is a real DNS name: legitimate access is
// either through HA ingress (authenticated — carries X-Ingress-Path) or
// direct to a literal IP / localhost / *.local address.
function hostAllowed(req) {
  // Ingress requests are already authenticated by HA — always allow.
  if (req.headers['x-ingress-path']) return true;
  const host = req.headers.host;
  if (!host) return true; // no Host header — nothing to rebind
  // Strip the :port. Bracketed IPv6 (`[::1]:8090`) keeps its colons inside
  // the brackets, so only split on the final `]:` or a lone trailing `:port`.
  let hostname = host;
  if (host[0] === '[') {
    hostname = host.slice(1, host.indexOf(']')); // literal IPv6 in brackets
  } else if (host.indexOf(':') !== -1 && host.indexOf(':') === host.lastIndexOf(':')) {
    hostname = host.slice(0, host.lastIndexOf(':')); // hostname:port
  }
  hostname = hostname.toLowerCase();
  if (hostname === 'localhost' || hostname.endsWith('.local')) return true;
  if (/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(hostname)) return true; // IPv4
  if (hostname.indexOf(':') !== -1) return true; // bare/literal IPv6
  return false; // a real DNS name — reject (rebinding defense)
}

// True when a request arrived through HA's authenticated ingress (the
// Supervisor injects X-Ingress-Path). The human admin picker UI is gated on
// this so it can't be reached on the raw mapped port.
function ingressOnly(req) {
  return !!req.headers['x-ingress-path'];
}

// allowAdmin is true only for the ingress listener (PORT). The published LAN
// listener (PUBLIC_PORT) passes false, so admin routes 403 there regardless of
// any headers a LAN client sets.
function handleRequest(req, res, allowAdmin) {
    const adminOK = allowAdmin && ingressOnly(req);
    const denyAdmin = () => {
      res.writeHead(403, { 'Content-Type': 'text/plain' });
      res.end('admin UI is only available through the Home Assistant sidebar');
    };
    // Reject DNS-rebinding attempts before doing anything else.
    if (!hostAllowed(req)) {
      res.writeHead(403, { 'Content-Type': 'text/plain' });
      res.end('forbidden host');
      return;
    }
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
    if (req.url === '/config' || req.url.startsWith('/config?')) {
      if (!adminOK) { denyAdmin(); return; }
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
      res.end(CONFIG_PAGE);
      return;
    }
    if (req.url.startsWith('/config/entities')) {
      if (!adminOK) { denyAdmin(); return; }
      fetchEntities()
        .then((list) => {
          res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
          res.end(JSON.stringify(list));
        })
        .catch((e) => {
          res.writeHead(502, { 'Content-Type': 'text/plain' });
          res.end(e.message);
        });
      return;
    }
    if (req.url.startsWith('/config/current')) {
      if (!adminOK) { denyAdmin(); return; }
      let opts = {};
      try { opts = readOptions(); } catch (_) { /* no options file */ }
      res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
      res.end(JSON.stringify({
        cameras: toList(opts.cameras),
        weather_sensors: toList(opts.weather_sensors),
        media_players: toList(opts.media_players),
        weather_entity: toList(opts.weather_entity),
        app_config_enabled: !!opts.app_config_enabled,
        can_save: !!SUPERVISOR_TOKEN,
      }));
      return;
    }
    // App settings backup: the Basic Cable app POSTs its full on-device
    // settings here and can GET them back to restore. One file under
    // /data, which HA's own backups include. LAN-trust model, same as
    // the rest of this server — the payload carries the HA token the app
    // was already configured with.
    if (req.url.startsWith('/config/appbackup')) {
      const fs = require('fs');
      const backupPath = process.env.APP_BACKUP_FILE || '/data/app-settings-backup.json';
      if (req.method === 'POST') {
        let body = '';
        req.on('data', (chunk) => {
          body += chunk;
          if (body.length > 262144) req.destroy(); // settings are tiny
        });
        req.on('end', () => {
          try {
            const parsed = JSON.parse(body);
            // This endpoint is unauthenticated on the LAN and the blob is
            // served back on GET, so never let a plaintext credential be
            // stored here: the app must encrypt haToken/immichKey (enc:v1:
            // envelope) before backing up. Reject anything that isn't, so a
            // plaintext token can never sit in /data or be read off the LAN.
            const s = (parsed && parsed.settings) || {};
            for (const k of ['haToken', 'immichKey']) {
              if (s[k] && !String(s[k]).startsWith('enc:v1:')) {
                res.writeHead(400, { 'Content-Type': 'text/plain' });
                res.end(`refusing to store an unencrypted ${k}`);
                return;
              }
            }
            fs.writeFileSync(backupPath, body);
            console.log(`app settings backup stored (${body.length} bytes)`);
            res.writeHead(200, { 'Content-Type': 'text/plain' });
            res.end('ok');
          } catch (e) {
            res.writeHead(400, { 'Content-Type': 'text/plain' });
            res.end(`bad backup payload: ${e.message}`);
          }
        });
        return;
      }
      try {
        const data = fs.readFileSync(backupPath);
        res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
        res.end(data);
      } catch (_) {
        res.writeHead(404, { 'Content-Type': 'text/plain' });
        res.end('no backup stored');
      }
      return;
    }
    if (req.url.startsWith('/config/save') && req.method === 'POST') {
      if (!adminOK) { denyAdmin(); return; }
      if (!SUPERVISOR_TOKEN) {
        res.writeHead(403, { 'Content-Type': 'text/plain' });
        res.end('not running as a Home Assistant add-on');
        return;
      }
      let body = '';
      req.on('data', (chunk) => {
        body += chunk;
        if (body.length > 262144) req.destroy(); // options payload is tiny
      });
      req.on('end', () => {
        Promise.resolve()
          .then(() => saveConfig(JSON.parse(body)))
          .then(() => {
            res.writeHead(200, { 'Content-Type': 'text/plain' });
            res.end('ok');
          })
          .catch((e) => {
            console.error(`config save failed: ${e.message}`);
            res.writeHead(500, { 'Content-Type': 'text/plain' });
            res.end(e.message);
          });
      });
      return;
    }
    if (req.url.startsWith('/appconfig')) {
      if (!appConfig) {
        res.writeHead(404, { 'Content-Type': 'text/plain' });
        res.end('app config not enabled');
        return;
      }
      res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
      res.end(JSON.stringify(appConfig));
      return;
    }
    // Through HA Ingress the add-on's root IS the config page — that's
    // what the sidebar entry opens, with HA's own auth in front. Direct
    // hits on the mapped port keep serving the first snapshot so
    // existing app/tile configs don't break.
    if ((req.url === '/' || req.url.startsWith('/?')) && adminOK) {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
      res.end(CONFIG_PAGE);
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
}

// Ingress-facing listener (admin + public routes). Not published to the LAN.
http
  .createServer((req, res) => handleRequest(req, res, true))
  .on('error', (e) => { console.error('server error', e); process.exit(1); })
  .listen(PORT, () => console.log(`serving on :${PORT} (ingress/admin)`));

// Published LAN listener (public routes only — admin routes 403 here). Skip it
// only if it would collide with the ingress port.
if (PUBLIC_PORT && PUBLIC_PORT !== PORT) {
  http
    .createServer((req, res) => handleRequest(req, res, false))
    .on('error', (e) => { console.error('public server error', e); process.exit(1); })
    .listen(PUBLIC_PORT, () => console.log(`serving on :${PUBLIC_PORT} (public)`));
}

// Never die: the HTTP server keeps serving (healthz goes 503, stale
// frames stay available) while the capture loop rebuilds itself.
(async () => {
  for (;;) {
    try {
      await captureLoop();
    } catch (e) {
      console.error(`capture loop crashed, restarting in 30s: ${e.stack || e}`);
      await sleep(30000);
    }
  }
})();
