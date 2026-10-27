/**
 * A timed topic's home tile in each state (timers.md §11.1, §11.5), the running bar, and
 * the Fix of a failed finish from the sync sheet (§8.1).
 */
import { screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, describe, expect, it } from 'vitest';

import { outbox } from '../../lib/outbox/client';
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

  it('on the last step: Stop, then the answers form for a version with questions', async () => {
    h = renderRunApp('/', timedTopic(), (s) =>
      seedRun(s, [
        { type: 'next', s: 10, seg: 0 },
        { type: 'next', s: 20, seg: 1 },
      ]),
    );
    const t = await tile();
    const stop = await within(t).findByRole('button', { name: 'Stop · Morning' });
    await waitFor(() => expect(stop).toBeEnabled());
    await userEvent.click(stop);
    await sent(h, 1);
    expect(h.server.events()[0]).toMatchObject({ type: 'stop' });
    await waitFor(() =>
      expect(screen.getByTestId('where')).toHaveTextContent(
        `/t/morning/record?finish=${RUN_ID}&v=1`,
      ),
    );
    expect(await screen.findByRole('heading', { name: 'Add details' })).toBeInTheDocument();
  });

  it('a version without questions saves at Stop, with its time', async () => {
    h = renderRunApp('/', timedTopic({ steps: [], questions: [] }), (s) => seedRun(s));
    const t = await tile();
    const stop = await within(t).findByRole('button', { name: 'Stop · Morning' });
    await waitFor(() => expect(stop).toBeEnabled());
    await userEvent.click(stop);
    expect(await screen.findByText(/^Saved Morning: 1:0\d$/)).toBeInTheDocument();
    expect(screen.getByTestId('where')).toHaveTextContent(/^\/$/);
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

  it('the panel shows the clock, Next, Stop, Lap and Pause, but no step list and no Skip', async () => {
    h = renderRunApp('/t/morning/record', timedTopic(), unknownSteps);
    const next = await screen.findByRole('button', { name: 'Next' });
    await waitFor(() => expect(next).toBeEnabled());
    expect(screen.getByRole('button', { name: 'Stop' })).toBeEnabled();
    expect(screen.getByRole('button', { name: 'Lap' })).toBeEnabled();
    expect(screen.getByRole('button', { name: 'Pause' })).toBeEnabled();
    expect(screen.getByRole('button', { name: 'Skip' })).toBeDisabled();
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
});
