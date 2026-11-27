// T2-WIRE-F evidence, after the M2 recipe (docs/t2/evidence/M2/scripts/pwa-resume-shots.mjs): the
// app's fake run server (src/test/fakeRunServer.ts) installed in the page, only /api/v1/ faked,
// system Chrome, headless, a fresh profile, 390 px, against Vite on localhost in frontend/.
// Topics: Morning (timed, blue ☀️, tag Daily), Mood (teal 🙂, four tags, a latest entry), Workout
// (no appearance). Usage: node pwa-wire-shots.mjs <out dir> <prefix> <port>
import { chromium } from 'playwright-core';

const [out, prefix, port] = [process.argv[2], process.argv[3] ?? 'pwa-', process.argv[4] ?? '5398'];
const BASE = `http://localhost:${port}`;
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

const INSTALL = async ({ seed }) => {
  const { fakeRunServer } = await import('/src/test/fakeRunServer.ts');
  const T = Date.now();
  const iso = (s) => new Date(T - s * 1000).toISOString();
  const base = {
    description: '', status: 'active', current_version: 1, revision: 1, created_at: '2026-10-01T00:00:00Z',
    updated_at: '2026-10-01T00:00:00Z', archived_at: null, schedule: null, schedule_updated_at: null, due: null,
  };
  const moodQ = [{ key: 'mood', label: 'Mood', type: 'enum', required: true, help_text: null, multiple: false,
    min_selected: null, max_selected: null,
    options: [{ value: 'good', label: 'Good', archived: false }, { value: 'ok', label: 'OK', archived: false },
      { value: 'bad', label: 'Bad', archived: false }] }];
  const steps = ['Shower', 'Dress', 'Breakfast', 'Teeth'].map((l) => ({ key: l.toLowerCase(), label: l, alerts: [] }));
  const timer = { steps, laps: [], variables: [] };
  const morning = {
    ...base, id: '6f1c0000-0000-4000-8000-0000000000a1', slug: 'morning', name: 'Morning', question_count: 1,
    entry_count: 0, last_captured_at: null, timer, last_entry: null,
    appearance: { color: 'blue', icon: { kind: 'emoji', value: '☀️' }, tags: ['Daily'] }, questions: moodQ,
  };
  const moodEntry = {
    id: '0d6c0000-0000-4000-8000-0000000000e9', topic_id: '6f1c0000-0000-4000-8000-0000000000c2', version: 1,
    captured_at: iso(3600), created_at: iso(3600), updated_at: iso(3600),
    answers: [{ key: 'mood', type: 'enum', value: 'good' }], notes: '', meta: {}, timing: null, revision: 1, source: 'pwa', channel: 'ui',
  };
  const mood = {
    ...base, id: '6f1c0000-0000-4000-8000-0000000000c2', slug: 'mood', name: 'Mood', question_count: 1,
    entry_count: 4, last_captured_at: iso(3600), timer: null, last_entry: moodEntry,
    appearance: { color: 'teal', icon: { kind: 'emoji', value: '🙂' }, tags: ['Daily', 'Health', 'Home', 'Evening'] },
    questions: moodQ,
  };
  const workout = {
    ...base, id: '6f1c0000-0000-4000-8000-0000000000c1', slug: 'workout', name: 'Workout', question_count: 0,
    entry_count: 0, last_captured_at: null, timer: null, last_entry: null,
    appearance: { color: null, icon: null, tags: [] }, questions: [],
  };
  const versions = [{ version: 1, questions: moodQ, timer, change_note: '', created_at: '2026-10-01T00:00:00Z', entry_count: 0 }];
  const server = fakeRunServer(morning, versions);
  if (seed === 'running') {
    const rid = '7a2c0000-0000-4000-8000-0000000000c3';
    server.record(rid, { id: rid, type: 'start', at: iso(104), topic_id: morning.id, version: 1 });
  }
  const summary = (t) => { const s = { ...t }; delete s.questions; return s; };
  const json = (b) => Promise.resolve(new Response(JSON.stringify(b), { status: 200, headers: { 'Content-Type': 'application/json' } }));
  window.__installFake((input, init) => {
    const url = new URL(typeof input === 'string' ? input : input instanceof URL ? input.href : input.url, location.href);
    if (url.pathname === '/api/v1/topics') {
      const tag = url.searchParams.get('tag');
      const items = [morning, mood, workout].filter((t) => !tag || t.appearance.tags.includes(tag)).map(summary);
      return json({ items, total: items.length, limit: 50, offset: 0 });
    }
    for (const t of [mood, workout]) {
      if (url.pathname === `/api/v1/topics/${t.slug}` || url.pathname === `/api/v1/topics/${t.id}`) return json(t);
      if (url.pathname === `/api/v1/topics/${t.slug}/entries` || url.pathname === `/api/v1/topics/${t.id}/entries`)
        return json({ items: t.last_entry ? [t.last_entry] : [], total: t.entry_count, limit: 25, offset: 0 });
    }
    return server.fetch(input, init);
  });
};

async function shot(scheme, path, seed, name, ready) {
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, colorScheme: scheme, deviceScaleFactor: 2 });
  await ctx.addInitScript(HOLD);
  const page = await ctx.newPage();
  page.on('console', (m) => { if (m.type() === 'error') console.error('[page]', m.text().slice(0, 200)); });
  page.on('pageerror', (e) => console.error('[err]', e.message.slice(0, 300)));
  await page.goto(`${BASE}${path}`);
  await page.evaluate(INSTALL, { seed });
  try {
    await ready(page);
  } catch (e) {
    await page.screenshot({ path: `${out}/FAIL-${name}-${scheme}.png` });
    throw e;
  }
  await page.waitForTimeout(900);
  await page.screenshot({ path: `${out}/${prefix}${name}-${scheme}.png` });
  await ctx.close();
}

for (const scheme of ['light', 'dark']) {
  await shot(scheme, '/', 'idle', 'home-tiles', (p) => p.getByRole('article', { name: 'Mood' }).waitFor());
  await shot(scheme, '/?tag=Daily', 'idle', 'home-tag-filter', (p) => p.getByRole('article', { name: 'Mood' }).waitFor());
  await shot(scheme, '/', 'running', 'active-card', (p) => p.getByTestId('active-card').waitFor());
  await shot(scheme, '/t/morning/record', 'running', 'run-panel', (p) => p.getByTestId('run-primary').waitFor());
  await shot(scheme, '/t/mood', 'running', 'running-bar', (p) => p.getByTestId('bar-primary').waitFor());
}
await browser.close();
console.log('done');
