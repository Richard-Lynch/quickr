// M2-RESUME (PWA) evidence, after the F2-CONTROLS recipe: the app's fake server
// (src/test/fakeRunServer.ts) installed in the page, only /api/v1/ faked, system Chrome, 390 px.
// Run from a folder with playwright installed, against Vite on :5397 in frontend/.
// Modes: shots (4 states x light/dark into <out>), frames (stop -> Resume, PNG frames).
import { chromium } from 'playwright';
const [out, mode] = [process.argv[2], process.argv[3] ?? 'shots'];
const BASE = 'http://localhost:5397';
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

// seed: 'stopped' (a run stopped 12 s ago, 1:44 long) or 'running' (open for 1:44).
const INSTALL = async ({ seed, holdReopen }) => {
  const { fakeRunServer } = await import('/src/test/fakeRunServer.ts');
  const T = Date.now();
  const iso = (s) => new Date(T - s * 1000).toISOString();
  const topic = {
    id: '6f1c0000-0000-4000-8000-0000000000b2', slug: 'smoke', name: 'Smoke', description: '',
    status: 'active', current_version: 1, revision: 1, question_count: 0, entry_count: 3,
    last_captured_at: iso(12), created_at: '2026-10-01T00:00:00Z', updated_at: '2026-10-01T00:00:00Z',
    archived_at: null, schedule: null, schedule_updated_at: null, due: null, timer: { steps: [], laps: [], variables: [] }, questions: [],
  };
  const versions = [{ version: 1, questions: [], timer: { steps: [], laps: [], variables: [] }, change_note: '', created_at: '2026-10-01T00:00:00Z', entry_count: 3 }];
  const server = fakeRunServer(topic, versions);
  const rid = '7a2c0000-0000-4000-8000-0000000000c3';
  if (seed === 'stopped') {
    server.record(rid, { id: rid, type: 'start', at: iso(116), topic_id: topic.id, version: 1 });
    server.record(rid, { id: crypto.randomUUID(), type: 'lap', at: iso(60), seg: 0 });
    server.record(rid, { id: crypto.randomUUID(), type: 'stop', at: iso(12) });
  } else {
    server.record(rid, { id: rid, type: 'start', at: iso(104), topic_id: topic.id, version: 1 });
    server.record(rid, { id: crypto.randomUUID(), type: 'lap', at: iso(48), seg: 0 });
  }
  if (holdReopen)
    server.override = (body) => (body.type === 'reopen' ? new Response('{}', { status: 503 }) : undefined);
  const summary = { ...topic }; delete summary.questions;
  window.__installFake((input, init) => {
    const url = new URL(typeof input === 'string' ? input : input instanceof URL ? input.href : input.url, location.href);
    if (url.pathname === '/api/v1/topics')
      return Promise.resolve(new Response(JSON.stringify({ items: [summary], total: 1, limit: 50, offset: 0 }), { status: 200, headers: { 'Content-Type': 'application/json' } }));
    return server.fetch(input, init);
  });
};

async function open(scheme, path, opts) {
  const ctx = await browser.newContext({
    viewport: { width: 390, height: 844 }, colorScheme: scheme, deviceScaleFactor: 2,
  });
  await ctx.addInitScript(HOLD);
  const page = await ctx.newPage();
  page.on('console', (m) => { if (m.type() === 'error') console.error('[page]', m.text()); });
  await page.goto(`${BASE}${path}`);
  await page.evaluate(INSTALL, opts);
  return { ctx, page };
}

const settle = (page) => page.waitForTimeout(900);

if (mode === 'shots') {
  for (const scheme of ['light', 'dark']) {
    // 1. The idle tile with Resume.
    {
      const { ctx, page } = await open(scheme, '/', { seed: 'stopped' });
      await page.getByTestId('run-reopen').waitFor();
      await settle(page);
      await page.screenshot({ path: `${out}/pwa-tile-resume-${scheme}.png` });
      await ctx.close();
    }
    // 2. The run panel (idle) with Resume under Start.
    {
      const { ctx, page } = await open(scheme, '/t/smoke/record', { seed: 'stopped' });
      await page.getByTestId('run-reopen').waitFor();
      await settle(page);
      await page.screenshot({ path: `${out}/pwa-run-resume-${scheme}.png` });
      await ctx.close();
    }
    // 3. The stop toast with Resume.
    {
      const { ctx, page } = await open(scheme, '/t/smoke/record', { seed: 'running' });
      const stop = page.getByTestId('run-stop');
      await stop.waitFor();
      await page.waitForFunction(() => !document.querySelector('[data-testid=run-stop]')?.disabled);
      await stop.click();
      await page.getByRole('button', { name: 'Resume', exact: true }).waitFor();
      await settle(page);
      await page.screenshot({ path: `${out}/pwa-stop-toast-resume-${scheme}.png` });
      await ctx.close();
    }
    // 4. The Resuming card: the tile's Resume, its reopen not acked (503).
    {
      const { ctx, page } = await open(scheme, '/', { seed: 'stopped', holdReopen: true });
      const resume = page.getByTestId('run-reopen');
      await resume.waitFor();
      await resume.click();
      await page.getByText('Resuming…').waitFor();
      await settle(page);
      await page.screenshot({ path: `${out}/pwa-resuming-card-${scheme}.png` });
      await ctx.close();
    }
  }
} else {
  // stop -> toast -> Resume -> the open run again (the home card), a frame every ~150 ms.
  const { ctx, page } = await open('light', '/t/smoke/record', { seed: 'running' });
  const stop = page.getByTestId('run-stop');
  await stop.waitFor();
  await page.waitForFunction(() => !document.querySelector('[data-testid=run-stop]')?.disabled);
  let n = 0;
  let going = true;
  const shoot = (async () => {
    while (going) {
      await page.screenshot({ path: `${out}/frames/f${String(n++).padStart(4, '0')}.png`, scale: 'css' });
      await page.waitForTimeout(120);
    }
  })();
  await page.waitForTimeout(1200);
  await stop.click();
  const resume = page.getByRole('button', { name: 'Resume', exact: true });
  await resume.waitFor();
  await page.waitForTimeout(1500);
  await resume.click();
  await page.getByTestId('active-card').waitFor();
  await page.waitForTimeout(2200);
  going = false;
  await shoot;
  await ctx.close();
  console.log('frames', n);
}
await browser.close();
