/**
 * The run UI end to end against a fake server (timers-plan.md F-RUN acceptance): start →
 * Next → Skip → Pause → Resume → Stop → answers → Save, checking every request, and a
 * void reply's notice (§11.4).
 */
import { screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, describe, expect, it } from 'vitest';

import { HOW, renderRunApp, timedTopic, TOPIC_ID, type Harness } from '../../test/runUi';

let h: Harness | null = null;

afterEach(async () => {
  await h?.teardown();
  h = null;
});

const types = (hh: Harness) => hh.server.events().map((e) => e.type);

/** Wait until the server has seen `n` run events. */
async function sent(hh: Harness, n: number) {
  await waitFor(() => expect(hh.server.events()).toHaveLength(n), { timeout: 4000 });
}

describe('the run panel, scripted', () => {
  it('start → Next → Skip → Pause → Resume → Stop → answers → Save sends each tap', async () => {
    h = renderRunApp('/t/morning/record', timedTopic());
    const user = userEvent.setup();

    await user.click(await screen.findByRole('button', { name: 'Start' }));
    await sent(h, 1);
    const start = h.server.events()[0];
    expect(start).toMatchObject({ type: 'start', topic_id: TOPIC_ID, version: 1 });
    const runId = start?.id ?? '';

    await user.click(await screen.findByRole('button', { name: 'Next: Breakfast' }));
    await sent(h, 2);
    expect(await screen.findByTestId('segment-label')).toHaveTextContent('Breakfast');

    await user.click(screen.getByRole('button', { name: 'Skip Breakfast' }));
    await sent(h, 3);
    // Skip relabels the open segment: the time since the last mark is Teeth's (§4.2).
    await waitFor(() => expect(screen.getByTestId('segment-label')).toHaveTextContent('Teeth'));

    await user.click(screen.getByRole('button', { name: 'Pause' }));
    await sent(h, 4);
    await user.click(await screen.findByRole('button', { name: 'Resume' }));
    await sent(h, 5);

    // On the last step the primary button is Stop (§11.1).
    await screen.findByRole('button', { name: 'Pause' });
    expect(screen.queryByRole('button', { name: /^Next/ })).toBeNull();
    await user.click(screen.getByRole('button', { name: 'Stop' }));
    await sent(h, 6);

    // A required question: the run is finishing, and the answers form opens.
    expect(await screen.findByRole('heading', { name: 'Add details' })).toBeInTheDocument();
    expect(screen.getByTestId('where')).toHaveTextContent(`finish=${runId}`);
    expect(screen.queryByLabelText('Captured at')).toBeNull();
    await user.type(screen.getByRole('textbox', { name: new RegExp(HOW.label) }), 'Good');
    await user.click(screen.getByRole('button', { name: 'Save' }));
    await sent(h, 7);

    const events = h.server.events();
    expect(types(h)).toEqual(['start', 'next', 'skip', 'pause', 'resume', 'stop', 'finish']);
    const [, next, skip, pause, resume, stop, finish] = events;
    expect(next).toMatchObject({ seg: 0 });
    expect(skip).toMatchObject({ seg: 1, step: 'breakfast' });
    expect(resume?.pause_id).toBe(pause?.id);
    expect(stop?.answers ?? null).toBeNull();
    expect(finish).toMatchObject({ answers: { how: 'Good' } });
    // Every tap went to the run, in tap order.
    for (const r of h.server.requests.filter((x) => x.method === 'POST')) {
      expect(r.path).toBe(`/api/v1/runs/${runId}/events`);
    }
    const ats = events.slice(0, 6).map((e) => Date.parse(e.at));
    expect([...ats].sort((a, b) => a - b)).toEqual(ats);

    expect(await screen.findByText('Saved Morning')).toBeInTheDocument();
    const entry = h.server.entries[0];
    expect(entry?.id).toBe(runId);
    expect(entry?.timing?.segments.map((s) => s.label)).toEqual(['Shower', 'Teeth']);
    expect(entry?.timing?.skipped).toEqual(['breakfast']);
    expect(entry?.timing?.pauses).toHaveLength(1);
  });

  it('a topic without questions saves at Stop and says how long it took', async () => {
    h = renderRunApp('/t/morning/record', timedTopic({ steps: [], questions: [] }));
    const user = userEvent.setup();
    await user.click(await screen.findByRole('button', { name: 'Start' }));
    await sent(h, 1);
    // No steps: Lap and Stop (§11.1).
    await user.click(await screen.findByRole('button', { name: 'Lap' }));
    await sent(h, 2);
    await user.click(screen.getByRole('button', { name: 'Stop' }));
    await sent(h, 3);
    expect(await screen.findByText(/^Saved Morning: \d+:\d\d$/)).toBeInTheDocument();
    expect(types(h)).toEqual(['start', 'lap', 'stop']);
    expect(screen.queryByRole('heading', { name: /details/i })).toBeNull();
  });

  it('Discard asks first, then sends discard', async () => {
    h = renderRunApp('/t/morning/record', timedTopic());
    const user = userEvent.setup();
    await user.click(await screen.findByRole('button', { name: 'Start' }));
    await sent(h, 1);
    await user.click(await screen.findByRole('button', { name: 'Discard' }));
    const dialog = await screen.findByRole('dialog');
    expect(h.server.events()).toHaveLength(1);
    await user.click(within(dialog).getByRole('button', { name: 'Discard' }));
    await sent(h, 2);
    expect(types(h)).toEqual(['start', 'discard']);
  });
});

describe('void replies (§11.4)', () => {
  it('a Next that arrives after the stop says so', async () => {
    h = renderRunApp('/t/morning/record', timedTopic());
    const user = userEvent.setup();
    await user.click(await screen.findByRole('button', { name: 'Start' }));
    await sent(h, 1);
    // Another device stopped the run at 08:05; this Next lands after it.
    h.server.override = (body, server) => {
      if (body.type !== 'next') return undefined;
      const run = server.runOut(Array.from(server.runs.keys())[0] ?? '');
      const ended = { ...run, status: 'stopped' as const, ended_at: '2026-10-24T08:05:00Z' };
      return new Response(
        JSON.stringify({
          event: { id: body.id, effect: 'void', reason: 'after_stop' },
          run: ended,
          entry: null,
        }),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      );
    };
    await user.click(await screen.findByRole('button', { name: 'Next: Breakfast' }));
    await sent(h, 2);
    const time = new Date('2026-10-24T08:05:00Z').toLocaleTimeString([], {
      hour: 'numeric',
      minute: '2-digit',
    });
    await waitFor(() =>
      expect(
        screen.getByText(`Morning was already stopped at ${time}, so your Next wasn’t added.`),
      ).toBeInTheDocument(),
    );
  });

  it('a stale double tap is silent', async () => {
    h = renderRunApp('/t/morning/record', timedTopic());
    const user = userEvent.setup();
    await user.click(await screen.findByRole('button', { name: 'Start' }));
    await sent(h, 1);
    h.server.override = (body, server) => {
      if (body.type !== 'next') return undefined;
      const run = server.runOut(Array.from(server.runs.keys())[0] ?? '');
      return new Response(
        JSON.stringify({
          event: { id: body.id, effect: 'void', reason: 'stale' },
          run,
          entry: null,
        }),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      );
    };
    await user.click(await screen.findByRole('button', { name: 'Next: Breakfast' }));
    await sent(h, 2);
    await new Promise((r) => setTimeout(r, 50));
    expect(screen.queryByText(/already stopped|wasn’t added/)).toBeNull();
  });
});
