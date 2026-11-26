/**
 * A timed topic's home tile in each state (timers.md §11.1, §11.5), the running bar, and
 * the Fix of a failed finish from the sync sheet (§8.1).
 */
import { screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, describe, expect, it, vi } from 'vitest';

import { outbox } from '../../lib/outbox/client';
import { setRunTapCooldown } from './useRunActions';
import {
  RUN_ID,
  renderRunApp,
  seedRun,
  timedTopic,
  TOPIC_ID,
  type Harness,
} from '../../test/runUi';

let h: Harness | null = null;

afterEach(async () => {
  await h?.teardown();
  h = null;
});

/** The `flag` icon's path (`ui/Icon.tsx`): Lap's (§1.3). */
const FLAG_PATH = 'M5 21V4h12l-2.5 4L17 12H5';

const tile = async () => screen.findByRole('article', { name: 'Morning' });
const sent = async (hh: Harness, n: number) => {
  await waitFor(() => expect(hh.server.events()).toHaveLength(n), { timeout: 4000 });
};

describe('the home tile of a timed topic', () => {
  it('idle: Start, no Log and no quick answers; one tap starts a run', async () => {
    h = renderRunApp('/', timedTopic());
    const t = await tile();
    const start = await within(t).findByRole('button', { name: 'Start Morning' });
    expect(within(t).queryByRole('link', { name: 'Log Morning' })).toBeNull();
    await waitFor(() => expect(start).toBeEnabled());
    await userEvent.click(start);
    await sent(h, 1);
    expect(h.server.events()[0]).toMatchObject({ type: 'start', topic_id: TOPIC_ID, version: 1 });
    // The tile is running at once.
    expect(await within(t).findByText(/^Running/)).toBeInTheDocument();
  });

  it('running: "Running · m:ss", the segment, and Next', async () => {
    h = renderRunApp('/', timedTopic(), (s) => seedRun(s));
    const t = await tile();
    expect(await within(t).findByText(/^Running/)).toHaveTextContent(/Running · 1:0\d/);
    expect(within(t).getByText('Shower')).toBeInTheDocument();
    const next = within(t).getByRole('button', { name: 'Next: Breakfast · Morning' });
    await waitFor(() => expect(next).toBeEnabled());
    await userEvent.click(next);
    await sent(h, 1);
    expect(h.server.events()[0]).toMatchObject({ type: 'next', seg: 0 });
  });

  it('on the last step: Lap, never Stop (active-surfaces.md §1.2)', async () => {
    h = renderRunApp('/', timedTopic(), (s) =>
      seedRun(s, [
        { type: 'next', s: 10, seg: 0 },
        { type: 'next', s: 20, seg: 1 },
      ]),
    );
    const t = await tile();
    const lap = await within(t).findByRole('button', { name: 'Lap · Morning' });
    expect(within(t).queryByRole('button', { name: /^Stop/ })).toBeNull();
    await waitFor(() => expect(lap).toBeEnabled());
    await userEvent.click(lap);
    await sent(h, 1);
    expect(h.server.events()[0]).toMatchObject({ type: 'lap', seg: 2 });
  });

  it('paused: "Paused"', async () => {
    h = renderRunApp('/', timedTopic(), (s) => seedRun(s, [{ type: 'pause', s: 30 }]));
    const t = await tile();
    expect(await within(t).findByText(/^Paused/)).toHaveTextContent('Paused · 0:30');
  });

  it('finishing: "Add details", linking to the answers form', async () => {
    h = renderRunApp('/', timedTopic(), (s) => seedRun(s, [{ type: 'stop', s: 40 }]));
    const t = await tile();
    const link = await within(t).findByRole('link', { name: 'Add details to Morning' });
    expect(link).toHaveAttribute('href', `/t/morning/record?finish=${RUN_ID}&v=1`);
    await userEvent.click(link);
    expect(await screen.findByRole('heading', { name: 'Add details' })).toBeInTheDocument();
    expect(screen.getByText('0:40')).toBeInTheDocument();
  });
});

describe('a topic with a finishing run and a newer open one (L3)', () => {
  it('the tile shows the open run, whatever the order they’re listed in', async () => {
    const OPEN_ID = '0b5e0000-0000-4000-8000-0000000000b2';
    h = renderRunApp('/', timedTopic(), (s) => {
      // Listed first: the open run, started after the other's stop.
      s.record(OPEN_ID, {
        id: OPEN_ID,
        type: 'start',
        at: new Date(Date.now() - 10_000).toISOString(),
        topic_id: TOPIC_ID,
        version: 1,
      });
      seedRun(s, [{ type: 'stop', s: 40 }]);
    });
    const t = await tile();
    expect(await within(t).findByText(/^Running/)).toBeInTheDocument();
    expect(within(t).queryByRole('link', { name: 'Add details to Morning' })).toBeNull();
  });
});

describe('a run whose steps aren’t known here (T-PUSH: a reminder’s Start, nothing cached)', () => {
  const unknownSteps = (s: Parameters<typeof seedRun>[0]) => {
    s.versionsDown = true;
    seedRun(s);
  };

  it('the panel shows the clock, Next, Stop and Pause, but no step list, no Lap and no Skip', async () => {
    h = renderRunApp('/t/morning/record', timedTopic(), unknownSteps);
    // Steps unknown (active-surfaces.md §1.2 row 9): a plain Next primary, no Lap, no Skip.
    const next = await screen.findByTestId('run-primary');
    expect(next).toHaveAccessibleName('Next');
    await waitFor(() => expect(next).toBeEnabled());
    expect(screen.getByRole('button', { name: 'Stop Morning' })).toBeEnabled();
    expect(screen.getByRole('button', { name: 'Pause' })).toBeEnabled();
    expect(screen.queryByRole('button', { name: /^Lap/ })).toBeNull();
    await userEvent.click(screen.getByRole('button', { name: 'More' }));
    const more = await screen.findByRole('list', { name: 'More run actions' });
    expect(
      within(more)
        .getAllByRole('button')
        .map((b) => b.getAttribute('aria-label')),
    ).toEqual(['Discard run']);
    await userEvent.click(screen.getByRole('button', { name: 'Close' }));
    // The total clock runs (its screen-reader label is "Total").
    expect(screen.getByText('Total').parentElement).toHaveTextContent(/^Total 1:0\d$/);
    expect(screen.queryByText('Breakfast')).toBeNull();
    await userEvent.click(next);
    await sent(h, 1);
    expect(h.server.events()[0]).toMatchObject({ type: 'next', seg: 0 });
    expect(h.server.events()[0]?.step ?? null).toBeNull();
  });

  it('the tile offers Next', async () => {
    h = renderRunApp('/', timedTopic(), unknownSteps);
    const t = await tile();
    const next = await within(t).findByRole('button', { name: 'Next · Morning' });
    await waitFor(() => expect(next).toBeEnabled());
  });
});

describe('a due timed topic', () => {
  const due = () => {
    const f = timedTopic();
    const since = new Date(Date.now() - 3_600_000).toISOString();
    f.topic.due = { is_due: true, due_since: since, next_due_at: null, last_entry_at: null };
    return f;
  };
  // The tile moves between sections as the runs load: look it up afresh.
  const current = () => screen.getByRole('article', { name: 'Morning' });

  it('is loud and due while idle', async () => {
    h = renderRunApp('/', due());
    await screen.findByRole('button', { name: 'Start Morning' });
    expect(current().className).toContain('border-accent/45');
    expect(within(current()).getByText(/^(Due|Overdue)/)).toBeInTheDocument();
  });

  it('is neither loud nor due with an open run, and not counted', async () => {
    h = renderRunApp('/', due(), (s) => seedRun(s));
    await waitFor(() => expect(within(current()).getByText(/^Running/)).toBeInTheDocument());
    expect(current().className).not.toContain('border-accent/45');
    expect(within(current()).queryByText(/^(Due|Overdue)/)).toBeNull();
    expect(screen.getByRole('heading', { name: /Due now/ })).toHaveTextContent('0');
  });
});

describe('the running bar', () => {
  it('lists the open run with its timer and primary button, linking to its panel', async () => {
    h = renderRunApp('/t/morning', timedTopic(), (s) => seedRun(s));
    // The bar is re-created as the topic page loads: look it up afresh.
    const bar = () => screen.getByRole('region', { name: 'Running' });
    expect(
      await screen.findByText('Morning', { selector: '[aria-label="Running"] strong' }),
    ).toBeInTheDocument();
    expect(within(bar()).getByText(/1:0\d/)).toBeInTheDocument();
    const next = within(bar()).getByRole('button', { name: 'Next: Breakfast · Morning' });
    await waitFor(() => expect(next).toBeEnabled());
    await userEvent.click(next);
    await sent(h, 1);
    expect(h.server.events()[0]).toMatchObject({ type: 'next', seg: 0 });
    await userEvent.click(within(bar()).getByRole('link'));
    await waitFor(() => expect(screen.getByTestId('where')).toHaveTextContent('/t/morning/record'));
    // On the run's own panel the bar leaves it out.
    expect(await screen.findByRole('button', { name: 'Next: Teeth' })).toBeInTheDocument();
    expect(screen.queryByRole('region', { name: 'Running' })).toBeNull();
  });

  it('is absent with no open run', async () => {
    h = renderRunApp('/t/morning', timedTopic());
    expect(await screen.findByText('Topic overview')).toBeInTheDocument();
    expect(screen.queryByRole('region', { name: 'Running' })).toBeNull();
  });

  it('on the last step: Lap with its flag, never Stop; a tap laps (§6.3)', async () => {
    h = renderRunApp('/t/morning', timedTopic(), (s) =>
      seedRun(s, [
        { type: 'next', s: 10, seg: 0 },
        { type: 'next', s: 20, seg: 1 },
      ]),
    );
    const lap = await screen.findByTestId('bar-primary');
    expect(lap).toHaveAccessibleName('Lap · Morning');
    expect(lap).toHaveTextContent(/^Lap$/);
    expect(lap.querySelector('path')).toHaveAttribute('d', FLAG_PATH);
    const bar = screen.getByRole('region', { name: 'Running' });
    expect(within(bar).queryByRole('button', { name: /Stop/ })).toBeNull();
    await waitFor(() => expect(lap).toBeEnabled());
    await userEvent.click(lap);
    await sent(h, 1);
    expect(h.server.events()[0]).toMatchObject({ type: 'lap', seg: 2 });
  });

  it('is off while the topic’s tap cooldown runs, as the panel is', async () => {
    h = renderRunApp('/t/morning', timedTopic(), (s) => seedRun(s));
    const next = await screen.findByTestId('bar-primary');
    await waitFor(() => expect(next).toBeEnabled());
    setRunTapCooldown(60_000);
    await userEvent.click(next);
    await sent(h, 1);
    // The primary under the finger is the next step's now, and off until the cooldown ends.
    await waitFor(() =>
      expect(screen.getByTestId('bar-primary')).toHaveAccessibleName('Next: Teeth · Morning'),
    );
    expect(screen.getByTestId('bar-primary')).toBeDisabled();
  });
});

/**
 * The acceptance of F2-BAR (docs/t2/M2-plan.md): the bar's button is the run screen's primary,
 * state by state (active-surfaces.md §1.2 rows 4–9). Each state is rendered twice, the bar on
 * the topic page and the panel on the record page, and the two titles and icons compared; then
 * the bar's tap sends the primary's event.
 */
describe('the running bar’s primary is the run panel’s', () => {
  type Fixture = ReturnType<typeof timedTopic>;
  const cases: {
    name: string;
    fixture: () => Fixture;
    seed: (s: Parameters<typeof seedRun>[0]) => void;
    title: string;
  }[] = [
    {
      name: 'row 4: a step open, a step left',
      fixture: () => timedTopic(),
      seed: (s) => seedRun(s),
      title: 'Next: Breakfast',
    },
    {
      name: 'row 6: the last step open',
      fixture: () => timedTopic(),
      seed: (s) =>
        seedRun(s, [
          { type: 'next', s: 10, seg: 0 },
          { type: 'next', s: 20, seg: 1 },
        ]),
      title: 'Lap',
    },
    {
      name: 'row 5: a lap open',
      fixture: () => timedTopic(),
      seed: (s) =>
        seedRun(s, [
          { type: 'next', s: 10, seg: 0 },
          { type: 'next', s: 20, seg: 1 },
          { type: 'next', s: 30, seg: 2 },
        ]),
      title: 'Lap',
    },
    {
      name: 'row 7: no steps (the stopwatch)',
      fixture: () => timedTopic({ steps: [] }),
      seed: (s) => seedRun(s),
      title: 'Lap',
    },
    {
      name: 'row 8: paused',
      fixture: () => timedTopic(),
      seed: (s) => seedRun(s, [{ type: 'pause', s: 30 }]),
      title: 'Next: Breakfast',
    },
    {
      name: 'row 9: steps unknown',
      fixture: () => timedTopic(),
      seed: (s) => {
        s.versionsDown = true;
        seedRun(s);
      },
      title: 'Next',
    },
  ];

  const shown = (el: HTMLElement) => ({
    title: el.textContent,
    icon: el.querySelector('path')?.getAttribute('d'),
    enabled: !(el as HTMLButtonElement).disabled,
  });

  it.each(cases)('$name: $title', async ({ fixture, seed, title }) => {
    h = renderRunApp('/t/morning/record', fixture(), seed);
    const panel = await screen.findByTestId('run-primary');
    await waitFor(() => expect(panel).toBeEnabled());
    const onPanel = shown(panel);
    await h.teardown();

    h = renderRunApp('/t/morning', fixture(), seed);
    const bar = await screen.findByTestId('bar-primary');
    await waitFor(() => expect(bar).toBeEnabled());
    expect(shown(bar)).toEqual(onPanel);
    expect(onPanel.title).toBe(title);
    // And the bar's tap is the primary's.
    await userEvent.click(bar);
    await sent(h, 1);
    expect(h.server.events()[0]?.type).toBe(title.startsWith('Lap') ? 'lap' : 'next');
  });
});

describe('the running bar on the topics page', () => {
  it('leaves out a run whose primary the page lists, so it shows once', async () => {
    h = renderRunApp('/', timedTopic(), (s) => seedRun(s));
    await tile();
    expect(await screen.findAllByRole('button', { name: /^Next: Breakfast/ })).toHaveLength(1);
    expect(screen.queryByRole('region', { name: 'Running' })).toBeNull();
  });

  it('keeps a run whose topic the page doesn’t list (a search)', async () => {
    h = renderRunApp('/', timedTopic(), (s) => seedRun(s));
    await tile();
    // The server finds nothing for the search: the tile goes, and with it the run's primary.
    const listed = globalThis.fetch;
    vi.stubGlobal('fetch', (input: RequestInfo | URL, init?: RequestInit) => {
      const url = new URL(input instanceof Request ? input.url : String(input), 'https://q.test');
      return url.pathname === '/api/v1/topics' && url.searchParams.has('q')
        ? Promise.resolve(
            new Response(JSON.stringify({ items: [], total: 0, limit: 50, offset: 0 }), {
              status: 200,
              headers: { 'Content-Type': 'application/json' },
            }),
          )
        : listed(input, init);
    });
    await userEvent.type(screen.getByRole('searchbox'), 'zzz');
    expect(await screen.findByText('No matches')).toBeInTheDocument();
    const bar = await screen.findByRole('region', { name: 'Running' });
    expect(within(bar).getByTestId('bar-primary')).toHaveAccessibleName(
      'Next: Breakfast · Morning',
    );
    // Clearing the search lists the topic again: the bar leaves the run out once more.
    await userEvent.clear(screen.getByRole('searchbox'));
    await tile();
    await waitFor(() => expect(screen.queryByRole('region', { name: 'Running' })).toBeNull());
  });
});

describe('Fix of a failed finish (§8.1, L5)', () => {
  it('the sync sheet opens the answers form; Save again re-sends the same item', async () => {
    h = renderRunApp('/t/morning/record', timedTopic(), (s) =>
      seedRun(s, [{ type: 'stop', s: 40 }]),
    );
    const user = userEvent.setup();
    let reject = true;
    h.server.override = (body) =>
      body.type === 'finish' && reject
        ? new Response(
            JSON.stringify({
              code: 'invalid_answers',
              detail: 'Invalid answers',
              errors: [{ loc: ['answers', 'how'], message: 'Too vague' }],
            }),
            { status: 422, headers: { 'Content-Type': 'application/json' } },
          )
        : undefined;
    // Queue the finish offline, so it fails later in the background, as from another screen.
    const form = await screen.findByRole('heading', { name: 'Add details' });
    expect(form).toBeInTheDocument();
    await user.type(screen.getByRole('textbox', { name: /How did it go/ }), 'Meh');
    await user.click(screen.getByRole('button', { name: 'Save' }));
    // A rejected new finish puts the server's errors on the form.
    expect(await screen.findByText('Too vague')).toBeInTheDocument();
    expect(await outbox.list()).toHaveLength(0);

    // The same answers, failed in the background: the sync sheet's Fix opens the form.
    await outbox.enqueue('run.event', {
      topic: { id: TOPIC_ID, slug: 'morning', name: 'Morning' },
      run_id: RUN_ID,
      version: 1,
      steps: [],
      requires_answers: true,
      makes_entry: true,
      event: { type: 'finish', at: new Date().toISOString(), answers: { how: 'Meh' } },
    });
    await waitFor(async () => expect((await outbox.list())[0]?.status).toBe('failed'), {
      timeout: 4000,
    });
    await user.click(await screen.findByRole('button', { name: /1 failed/ }));
    await user.click(await screen.findByRole('button', { name: 'Fix' }));
    expect(await screen.findByText('These answers were not saved')).toBeInTheDocument();
    const field = screen.getByRole('textbox', { name: /How did it go/ });
    expect(field).toHaveValue('Meh');
    expect(screen.getByText('Too vague')).toBeInTheDocument();

    reject = false;
    await user.clear(field);
    await user.type(field, 'Great');
    const item = (await outbox.list())[0];
    await user.click(screen.getByRole('button', { name: 'Save again' }));
    await waitFor(async () => expect(await outbox.list()).toHaveLength(0), { timeout: 4000 });
    const finishes = h.server.events().filter((e) => e.type === 'finish');
    expect(finishes.at(-1)).toMatchObject({ id: item?.id, answers: { how: 'Great' } });
    expect(h.server.entries[0]?.answers).toEqual([{ key: 'how', type: 'str', value: 'Great' }]);
  });

  it('a finish refused other than with a 422 has nothing to fix (#59)', async () => {
    const FIX_ID = '6f1c0000-0000-4000-8000-0000000000f1';
    h = renderRunApp(`/t/morning/record?fix=${FIX_ID}`, timedTopic(), (s) =>
      seedRun(s, [{ type: 'stop', s: 40 }]),
    );
    h.server.override = (body) =>
      body.type === 'finish'
        ? new Response(JSON.stringify({ code: 'run_open', detail: 'The run is still open' }), {
            status: 409,
            headers: { 'Content-Type': 'application/json' },
          })
        : undefined;
    await outbox.enqueue(
      'run.event',
      {
        topic: { id: TOPIC_ID, slug: 'morning', name: 'Morning' },
        run_id: RUN_ID,
        version: 1,
        steps: [],
        requires_answers: true,
        makes_entry: true,
        event: { type: 'finish', at: new Date().toISOString(), answers: { how: 'Meh' } },
      },
      { id: FIX_ID },
    );
    await waitFor(async () => expect((await outbox.list())[0]?.status).toBe('failed'), {
      timeout: 4000,
    });
    expect(await screen.findByText('Nothing to fix')).toBeInTheDocument();
    expect(screen.queryByText('These answers were not saved')).toBeNull();
    await userEvent.click(await screen.findByRole('button', { name: /1 failed/ }));
    expect(await screen.findByRole('button', { name: 'Discard' })).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Fix' })).toBeNull();
  });

  it('a 422 after an attempt that may have landed has nothing to fix (M-1)', async () => {
    const FIX_ID = '6f1c0000-0000-4000-8000-0000000000f2';
    h = renderRunApp(`/t/morning/record?fix=${FIX_ID}`, timedTopic(), (s) =>
      seedRun(s, [{ type: 'stop', s: 40 }]),
    );
    let first = true;
    h.server.override = (body) => {
      if (body.type !== 'finish') return undefined;
      if (first) {
        first = false;
        return new Response('{}', { status: 503 });
      }
      return new Response(JSON.stringify({ code: 'invalid_answers', detail: 'Invalid answers' }), {
        status: 422,
        headers: { 'Content-Type': 'application/json' },
      });
    };
    await outbox.enqueue(
      'run.event',
      {
        topic: { id: TOPIC_ID, slug: 'morning', name: 'Morning' },
        run_id: RUN_ID,
        version: 1,
        steps: [],
        requires_answers: true,
        makes_entry: true,
        event: { type: 'finish', at: new Date().toISOString(), answers: { how: 'Meh' } },
      },
      { id: FIX_ID },
    );
    await waitFor(async () => expect((await outbox.list())[0]?.attempts).toBe(1), {
      timeout: 4000,
    });
    await outbox.retry(FIX_ID);
    await waitFor(
      async () =>
        expect((await outbox.list())[0]).toMatchObject({
          status: 'failed',
          maybe_delivered: true,
          last_error: { status: 422 },
        }),
      { timeout: 4000 },
    );
    expect(await screen.findByText('Nothing to fix')).toBeInTheDocument();
    expect(screen.queryByText('These answers were not saved')).toBeNull();
  });
});
