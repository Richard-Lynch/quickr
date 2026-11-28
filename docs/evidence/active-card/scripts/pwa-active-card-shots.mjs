// Active-card evidence (PWA), after docs/t2/evidence/M2/scripts/pwa-resume-shots.mjs: the app's
// fake server (src/test/fakeRunServer.ts) installed in the page, only /api/v1/ faked, system
// Chrome with a fresh profile, 390 px, localhost only.
// Usage: node pwa-active-card-shots.mjs <vite base url> <out dir> <prefix> [after]
// Shots: the home card with a running Morning in light, dark and large text (root font 175%);
// with "after", also the card's "…" sheet and the run page's "…", and the Pause/"…" frames.
import { chromium } from 'playwright';
const [BASE, out, prefix, after] = process.argv.slice(2);
const browser = await chromium.launch({
  executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
});

const HOLD = () => {
  let ready;
  window.__fake = new Promise((r) => (ready = r));
  window.__installFake = (f) => ready(f);
  const real = window.fetch.bind(window);
  window.fetch = async (input, init) => {
    const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
    if (new URL(url, location.href).pathname.startsWith('/api/v1/'))
      return (await window.__fake)(input, init);
    return real(input, init);
  };
};

// Morning, timed with four steps, its run open for 1:44 (Shower done, Dress running).
const INSTALL = async () => {
  const { fakeRunServer } = await import('/src/test/fakeRunServer.ts');
  const { normalTimer } = await import('/src/test/timer.ts');
  const T = Date.now();
  const iso = (s) => new Date(T - s * 1000).toISOString();
  const steps = ['Shower', 'Dress', 'Breakfast', 'Teeth'].map((label) => ({
    key: label.toLowerCase(), label,
  }));
  const timer = normalTimer({ steps });
  const topic = {
    id: '6f1c0000-0000-4000-8000-0000000000d1', slug: 'morning', name: 'Morning', description: '',
    status: 'active', current_version: 1, revision: 1, question_count: 0, entry_count: 3,
    last_captured_at: iso(86400), created_at: '2026-10-01T00:00:00Z', updated_at: '2026-10-01T00:00:00Z',
    archived_at: null, schedule: null, schedule_updated_at: null, due: null, timer, questions: [],
    last_entry: null, appearance: { color: null, icon: null, tags: [] },
  };
  const versions = [{ version: 1, questions: [], timer, change_note: '', created_at: '2026-10-01T00:00:00Z', entry_count: 3 }];
  const server = fakeRunServer(topic, versions);
  const rid = '7a2c0000-0000-4000-8000-0000000000d3';
  server.record(rid, { id: rid, type: 'start', at: iso(104), topic_id: topic.id, version: 1 });
  server.record(rid, { id: crypto.randomUUID(), type: 'next', at: iso(48), seg: 0 });
  const summary = { ...topic }; delete summary.questions;
  window.__installFake((input, init) => {
    const url = new URL(typeof input === 'string' ? input : input instanceof URL ? input.href : input.url, location.href);
    if (url.pathname === '/api/v1/topics')
      return Promise.resolve(new Response(JSON.stringify({ items: [summary], total: 1, limit: 50, offset: 0 }), { status: 200, headers: { 'Content-Type': 'application/json' } }));
    return server.fetch(input, init);
  });
};

async function open(scheme, path, big = false) {
  const ctx = await browser.newContext({
    viewport: { width: 390, height: 844 }, colorScheme: scheme, deviceScaleFactor: 2,
  });
  await ctx.addInitScript(HOLD);
  const page = await ctx.newPage();
  page.on('console', (m) => { if (m.type() === 'error') console.error('[page]', m.text()); });
  await page.goto(`${BASE}${path}`);
  if (big) await page.addStyleTag({ content: 'html { font-size: 175% !important; }' });
  await page.evaluate(INSTALL);
  return { ctx, page };
}

const settle = (page) => page.waitForTimeout(900);
const box = async (loc) => {
  const b = await loc.boundingBox();
  return b && `${Math.round(b.width)}x${Math.round(b.height)}`;
};

for (const [scheme, big, name] of [['light', false, 'light'], ['dark', false, 'dark'], ['light', true, 'large-text']]) {
  const { ctx, page } = await open(scheme, '/', big);
  const card = page.getByTestId('active-card');
  await card.waitFor();
  await page.getByTestId('card-pause').waitFor();
  await settle(page);
  await page.screenshot({ path: `${out}/${prefix}-${name}.png` });
  console.log(name, 'pause', await box(page.getByTestId('card-pause')),
    after ? `menu ${await box(page.getByTestId('card-menu'))}` : '');
  if (after && name === 'light') {
    await page.getByTestId('card-menu').click();
    await page.getByRole('list', { name: 'Topic pages' }).waitFor();
    await settle(page);
    await page.screenshot({ path: `${out}/${prefix}-menu.png` });
    await page.getByTestId('card-menu-entries').click();
    await page.waitForURL(/\/t\/morning\/entries$/);
    console.log('menu -> entries:', new URL(page.url()).pathname);
  }
  await ctx.close();
}
if (after) {
  const { ctx, page } = await open('light', '/t/morning/record');
  await page.getByTestId('run-stop').waitFor();
  await page.getByTestId('run-topic-menu').click();
  await page.getByRole('list', { name: 'Topic pages' }).waitFor();
  await settle(page);
  await page.screenshot({ path: `${out}/${prefix}-run-page-menu.png` });
  await page.getByTestId('run-topic-menu-settings').click();
  await page.waitForURL(/\/t\/morning\/settings$/);
  console.log('run page menu -> settings:', new URL(page.url()).pathname);
  await ctx.close();
}
await browser.close();
