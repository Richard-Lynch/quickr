/**
 * The run UI end to end against a fake server (timers-plan.md F-RUN acceptance): start →
 * Next → Skip → Pause → Resume → Stop → answers → Save, checking every request, and a
 * void reply's notice (§11.4). The taps go through `RunControls` (active-surfaces.md §6.1):
 * the primary, Stop and Pause/Resume beside it, Skip and Discard in "More".
 */
import { act, fireEvent, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, describe, expect, it, vi } from 'vitest';

import { getRunNotices, pushRunNotice } from '../../lib/runs/notices';

import {
  HOW,
  renderRunApp,
  seedRun,
  STEPS3,
  timedTopic,
  TOPIC_ID,
  type Harness,
} from '../../test/runUi';
import { RUN_TAP_COOLDOWN_MS, setRunTapCooldown } from './useRunActions';

let h: Harness | null = null;

afterEach(async () => {
  await h?.teardown();
  h = null;
});

const types = (hh: Harness) => hh.server.events().map((e) => e.type);

/** Open the panel's "More" sheet and tap `name` in it. */
async function fromMore(user: ReturnType<typeof userEvent.setup>, name: string) {
  await user.click(screen.getByRole('button', { name: 'More' }));
  const list = await screen.findByRole('list', { name: 'More run actions' });
  await user.click(within(list).getByRole('button', { name }));
}

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

    await fromMore(user, 'Skip Breakfast');
    await sent(h, 3);
    // Skip relabels the open segment: the time since the last mark is Teeth's (§4.2).
    await waitFor(() => expect(screen.getByTestId('segment-label')).toHaveTextContent('Teeth'));

    await user.click(screen.getByRole('button', { name: 'Pause' }));
    await sent(h, 4);
    await user.click(await screen.findByRole('button', { name: 'Resume' }));
    await sent(h, 5);

    // On the last step the primary is Lap, and Stop is a secondary (active-surfaces.md §1.2).
    await screen.findByRole('button', { name: 'Pause' });
    expect(screen.queryByRole('button', { name: /^Next/ })).toBeNull();
    expect(screen.getByTestId('run-primary')).toHaveAccessibleName('Lap');
    expect(screen.getByTestId('run-stop')).toHaveAccessibleName('Stop Morning');
    // The table has no buttons (D-3).
    expect(within(screen.getByRole('list', { name: 'Steps' })).queryAllByRole('button')).toEqual(
      [],
    );
    await user.click(screen.getByRole('button', { name: 'Stop Morning' }));
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
    // No steps (a lap topic): Lap is the primary, Stop beside it (active-surfaces.md §1.2).
    const primary = await screen.findByTestId('run-primary');
    expect(primary).toHaveAccessibleName('Lap');
    await user.click(primary);
    await sent(h, 2);
    await user.click(screen.getByRole('button', { name: 'Stop Morning' }));
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
    await screen.findByTestId('run-primary');
    await fromMore(user, 'Discard run');
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

  it('a toasted notice is gone from the sheet; one that came while hidden is listed, then dismissed', async () => {
    h = renderRunApp('/t/morning/record', timedTopic());
    const user = userEvent.setup();
    await screen.findByRole('button', { name: 'Start' });
    act(() => {
      pushRunNotice({ id: 'seen', text: 'Morning was already stopped.' });
    });
    expect(await screen.findByText('Morning was already stopped.')).toBeInTheDocument();
    expect(getRunNotices()).toEqual([]);

    const hidden = vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('hidden');
    act(() => {
      pushRunNotice({ id: 'unseen', text: 'Morning’s run was deleted.' });
    });
    hidden.mockRestore();
    expect(screen.queryByText('Morning’s run was deleted.')).toBeNull();
    await user.click(await screen.findByRole('button', { name: '1 notice' }));
    const list = await screen.findByRole('list', { name: 'Notices' });
    expect(within(list).getByText('Morning’s run was deleted.')).toBeInTheDocument();
    await user.click(within(list).getByRole('button', { name: 'Dismiss' }));
    expect(screen.queryByText('Morning’s run was deleted.')).toBeNull();
    expect(getRunNotices()).toEqual([]);
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

/**
 * Two clicks before React re-renders, so both run the handler the first render made (a real
 * double tap is ~80–120 ms, faster than the queued tap reaches the screen).
 */
function doubleTap(el: HTMLElement) {
  act(() => {
    el.click();
    el.click();
  });
}

/** Let any further sends happen. */
const settle = () => new Promise((r) => setTimeout(r, 300));

describe('double taps, within one render (review H1): `expect` only, cooldown off', () => {
  it('Next twice advances once', async () => {
    h = renderRunApp('/t/morning/record', timedTopic());
    await userEvent.click(await screen.findByRole('button', { name: 'Start' }));
    await sent(h, 1);
    doubleTap(await screen.findByRole('button', { name: 'Next: Breakfast' }));
    await sent(h, 2);
    await settle();
    expect(types(h)).toEqual(['start', 'next']);
    expect(await screen.findByRole('button', { name: 'Next: Teeth' })).toBeInTheDocument();
  });

  it('"Next" on the step before the last never becomes a Stop', async () => {
    h = renderRunApp('/t/morning/record', timedTopic({ steps: STEPS3.slice(0, 2) }));
    await userEvent.click(await screen.findByRole('button', { name: 'Start' }));
    await sent(h, 1);
    doubleTap(await screen.findByRole('button', { name: 'Next: Breakfast' }));
    await sent(h, 2);
    await settle();
    expect(types(h)).toEqual(['start', 'next']);
  });

  it('(cooldown on) a Lap that replaced Next under the finger is disabled and ignored, then accepted', async () => {
    h = renderRunApp('/t/morning/record', timedTopic({ steps: STEPS3.slice(0, 2) }));
    await userEvent.click(await screen.findByRole('button', { name: 'Start' }));
    await sent(h, 1);
    setRunTapCooldown(RUN_TAP_COOLDOWN_MS);
    fireEvent.click(await screen.findByRole('button', { name: 'Next: Breakfast' }));
    // The screen caught up: the same button now says Lap (the last step), and every control
    // is disabled while the cooldown lasts (active-surfaces.md §2.2, §9). A tap is ignored.
    await waitFor(() => {
      expect(screen.queryByRole('button', { name: /^Next/ })).toBeNull();
      expect(screen.getByTestId('run-primary')).toHaveAccessibleName('Lap');
    });
    const controls = screen.getByRole('group', { name: 'Run controls' });
    for (const b of within(controls).getAllByRole('button')) expect(b).toBeDisabled();
    fireEvent.click(screen.getByTestId('run-primary'));
    await sent(h, 2);
    await settle();
    expect(types(h)).toEqual(['start', 'next']);
    await waitFor(() => expect(screen.getByTestId('run-primary')).toBeEnabled(), {
      timeout: RUN_TAP_COOLDOWN_MS * 2,
    });
    fireEvent.click(screen.getByTestId('run-primary'));
    await sent(h, 3);
    expect(types(h)).toEqual(['start', 'next', 'lap']);
  });

  it('Pause twice pauses once (no resume)', async () => {
    h = renderRunApp('/t/morning/record', timedTopic());
    await userEvent.click(await screen.findByRole('button', { name: 'Start' }));
    await sent(h, 1);
    doubleTap(await screen.findByRole('button', { name: 'Pause' }));
    await sent(h, 2);
    await settle();
    expect(types(h)).toEqual(['start', 'pause']);
    expect(await screen.findByRole('button', { name: 'Resume' })).toBeInTheDocument();
  });
});

/** A real double tap: two clicks ~100 ms apart, the screen re-rendered in between. */
const GAP_MS = 100;
const gap = () => new Promise((r) => setTimeout(r, GAP_MS));

describe('double taps, ~100 ms apart (review H1): the cooldown', () => {
  it('Next twice advances once', async () => {
    h = renderRunApp('/t/morning/record', timedTopic());
    await userEvent.click(await screen.findByRole('button', { name: 'Start' }));
    await sent(h, 1);
    setRunTapCooldown(RUN_TAP_COOLDOWN_MS);
    await userEvent.click(await screen.findByRole('button', { name: 'Next: Breakfast' }));
    await gap();
    // The button has moved on; the second tap of the pair lands on it.
    await userEvent.click(await screen.findByRole('button', { name: 'Next: Teeth' }));
    await settle();
    expect(types(h)).toEqual(['start', 'next']);
  });

  it('the last Next twice doesn’t add a lap', async () => {
    h = renderRunApp('/t/morning/record', timedTopic({ steps: STEPS3.slice(0, 2) }));
    await userEvent.click(await screen.findByRole('button', { name: 'Start' }));
    await sent(h, 1);
    setRunTapCooldown(RUN_TAP_COOLDOWN_MS);
    await userEvent.click(await screen.findByRole('button', { name: 'Next: Breakfast' }));
    await gap();
    // The primary under the finger is Lap now; Stop is never there (§1.2).
    await userEvent.click(await screen.findByRole('button', { name: 'Lap' }));
    await settle();
    expect(types(h)).toEqual(['start', 'next']);
  });

  it('Pause twice pauses once', async () => {
    h = renderRunApp('/t/morning/record', timedTopic());
    await userEvent.click(await screen.findByRole('button', { name: 'Start' }));
    await sent(h, 1);
    setRunTapCooldown(RUN_TAP_COOLDOWN_MS);
    await userEvent.click(await screen.findByRole('button', { name: 'Pause' }));
    await gap();
    await userEvent.click(await screen.findByRole('button', { name: 'Resume' }));
    await settle();
    expect(types(h)).toEqual(['start', 'pause']);
  });

  it('Start then a quick tap on the Next that replaced it starts only', async () => {
    h = renderRunApp('/t/morning/record', timedTopic());
    setRunTapCooldown(RUN_TAP_COOLDOWN_MS);
    await userEvent.click(await screen.findByRole('button', { name: 'Start' }));
    await gap();
    await userEvent.click(await screen.findByRole('button', { name: 'Next: Breakfast' }));
    await settle();
    expect(types(h)).toEqual(['start']);
  });

  it('Stop twice on a tile without questions doesn’t start a new run', async () => {
    h = renderRunApp('/', timedTopic({ steps: [], questions: [] }));
    const t = await screen.findByRole('article', { name: 'Morning' });
    const start = await within(t).findByRole('button', { name: 'Start Morning' });
    await waitFor(() => expect(start).toBeEnabled());
    await userEvent.click(start);
    await sent(h, 1);
    setRunTapCooldown(RUN_TAP_COOLDOWN_MS);
    await userEvent.click(await within(t).findByRole('button', { name: 'Stop · Morning' }));
    await gap();
    // The run is saved at Stop: Start replaces it under the finger.
    await userEvent.click(await within(t).findByRole('button', { name: 'Start Morning' }));
    await settle();
    expect(types(h)).toEqual(['start', 'stop']);
  });
});

describe('the cooldown across surfaces', () => {
  it('a tap on the running bar leaves the panel disabled until its cooldown ends', async () => {
    h = renderRunApp('/t/morning', timedTopic(), (s) => seedRun(s));
    // The bar is re-created as the topic page loads: look it up afresh.
    const bar = () => screen.getByRole('region', { name: 'Running' });
    await screen.findByText('Morning', { selector: '[aria-label="Running"] strong' });
    const next = within(bar()).getByRole('button', { name: 'Next: Breakfast · Morning' });
    await waitFor(() => expect(next).toBeEnabled());
    setRunTapCooldown(RUN_TAP_COOLDOWN_MS);
    fireEvent.click(next);
    // Straight to the panel, inside the bar's cooldown: its controls say so.
    fireEvent.click(within(bar()).getByRole('link'));
    const primary = await screen.findByTestId('run-primary');
    expect(primary).toBeDisabled();
    await sent(h, 1);
    await waitFor(() => expect(screen.getByTestId('run-primary')).toBeEnabled(), {
      timeout: RUN_TAP_COOLDOWN_MS * 2,
    });
  });
});

describe('the panel’s controls', () => {
  it('no steps: no Skip, and More holds only Discard run', async () => {
    h = renderRunApp('/t/morning/record', timedTopic({ steps: [], questions: [] }));
    const user = userEvent.setup();
    await user.click(await screen.findByRole('button', { name: 'Start' }));
    await sent(h, 1);
    await waitFor(() => expect(screen.getByRole('button', { name: 'Lap' })).toBeEnabled());
    expect(screen.queryByRole('button', { name: /^Skip/ })).toBeNull();
    await user.click(screen.getByRole('button', { name: 'More' }));
    const list = await screen.findByRole('list', { name: 'More run actions' });
    expect(
      within(list)
        .getAllByRole('button')
        .map((b) => b.getAttribute('aria-label')),
    ).toEqual(['Discard run']);
  });

  it('each control renders once, and the table has none', async () => {
    h = renderRunApp('/t/morning/record', timedTopic());
    const user = userEvent.setup();
    await user.click(await screen.findByRole('button', { name: 'Start' }));
    await sent(h, 1);
    const panel = await screen.findByRole('group', { name: 'Run controls' });
    await waitFor(() => expect(within(panel).getByTestId('run-primary')).toBeEnabled());
    expect(
      within(panel)
        .getAllByRole('button')
        .map((b) => b.getAttribute('aria-label')),
    ).toEqual(['Next: Breakfast', 'Stop Morning', 'Pause', 'More']);
    expect(screen.queryByRole('button', { name: 'Lap' })).toBeNull();
    expect(screen.queryByRole('button', { name: /^Discard/ })).toBeNull();
    expect(within(screen.getByRole('list', { name: 'Steps' })).queryAllByRole('button')).toEqual(
      [],
    );
  });

  it('a stopped run’s optional details form has no Discard', async () => {
    h = renderRunApp('/t/morning/record', timedTopic({ questions: [{ ...HOW, required: false }] }));
    await userEvent.click(await screen.findByRole('button', { name: 'Start' }));
    await sent(h, 1);
    // Wait out the start's ack before the stop, so the run is stopped, not finishing.
    await userEvent.click(await screen.findByRole('button', { name: 'Stop Morning' }));
    await sent(h, 2);
    expect(await screen.findByRole('heading', { name: 'Details' })).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Discard run' })).toBeNull();
    expect(h.server.entries).toHaveLength(1);
  });
});
