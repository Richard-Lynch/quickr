/**
 * The topics page's "Active now" section (active-surfaces.md §6.2): a topic with an open
 * run is listed there, first, and nowhere else; the due sections are a view of the same
 * listing, so `splitByDue` and its vectors don't change.
 */
import { screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, describe, expect, it } from 'vitest';

import type { TopicSummary } from '../client';
import { renderRunApp, seedRun, timedTopic, type Harness } from '../test/runUi';

let h: Harness | null = null;

afterEach(async () => {
  await h?.teardown();
  h = null;
});

/** An untimed topic that is due: it belongs in "Due now". */
const vitamins: TopicSummary = {
  id: '6f1c0000-0000-4000-8000-0000000000d1',
  slug: 'vitamins',
  name: 'Vitamins',
  description: '',
  status: 'active',
  current_version: 1,
  revision: 1,
  question_count: 1,
  entry_count: 0,
  last_captured_at: null,
  created_at: '2026-10-01T00:00:00Z',
  updated_at: '2026-10-01T00:00:00Z',
  archived_at: null,
  schedule: null,
  schedule_updated_at: null,
  due: {
    is_due: true,
    due_since: new Date(Date.now() - 3_600_000).toISOString(),
    next_due_at: null,
    last_entry_at: null,
  },
  timer: null,
};

/** A due timed topic, so an idle "Morning" would be in "Due now" too. */
function dueMorning(opts: Parameters<typeof timedTopic>[0] = {}) {
  const f = timedTopic(opts);
  f.topic.due = vitamins.due;
  return f;
}

const headings = () => screen.getAllByRole('heading', { level: 2 }).map((e) => e.id);
const section = (id: string) => screen.getByRole('region', { name: new RegExp(id) });
const morning = () => screen.getAllByRole('article', { name: 'Morning' });

describe('"Active now" on the topics page', () => {
  it('lists an open run’s topic first, once, and nowhere else', async () => {
    h = renderRunApp('/', dueMorning(), (s) => seedRun(s), [vitamins]);
    const active = await screen.findByRole('region', { name: /Active now/ });
    expect(active).toHaveTextContent(/Active now\s*1/);
    expect(within(active).getByRole('article', { name: 'Morning' })).toHaveAttribute(
      'data-testid',
      'active-card',
    );
    expect(headings().filter((id) => id.startsWith('section-'))).toEqual([
      'section-active-now',
      'section-due-now',
    ]);
    expect(morning()).toHaveLength(1);
    // The due list keeps the other topic, and doesn't count the running one.
    const due = section('Due now');
    expect(due).toHaveTextContent(/Due now\s*1/);
    expect(within(due).getByRole('article', { name: 'Vitamins' })).toBeInTheDocument();
    expect(within(due).queryByRole('article', { name: 'Morning' })).toBeNull();
  });

  it('is absent with no open run: the topic stays in its own section', async () => {
    h = renderRunApp('/', dueMorning(), undefined, [vitamins]);
    await screen.findByRole('button', { name: 'Start Morning' });
    expect(screen.queryByRole('region', { name: /Active now/ })).toBeNull();
    expect(
      within(section('Due now')).getByRole('article', { name: 'Morning' }),
    ).toBeInTheDocument();
    expect(morning()).toHaveLength(1);
  });

  it('counts a paused run as active', async () => {
    h = renderRunApp('/', dueMorning(), (s) => seedRun(s, [{ type: 'pause', s: 30 }]), [vitamins]);
    const active = await screen.findByRole('region', { name: /Active now/ });
    expect(within(active).getByTestId('card-status')).toHaveTextContent('Paused · Shower');
    expect(morning()).toHaveLength(1);
  });

  it('leaves a finishing run where it was, with "Add details"', async () => {
    h = renderRunApp('/', dueMorning(), (s) => seedRun(s, [{ type: 'stop', s: 40 }]), [vitamins]);
    await screen.findByRole('link', { name: 'Add details to Morning' });
    expect(screen.queryByRole('region', { name: /Active now/ })).toBeNull();
    expect(screen.queryByTestId('active-card')).toBeNull();
    expect(morning()).toHaveLength(1);
  });

  it('a search keeps the section first, above the unsectioned list', async () => {
    h = renderRunApp('/', dueMorning(), (s) => seedRun(s), [vitamins]);
    await screen.findByRole('region', { name: /Active now/ });
    await userEvent.type(screen.getByRole('searchbox', { name: 'Search topics' }), 'm');
    await waitFor(() =>
      expect(screen.getByRole('heading', { level: 1 })).toHaveTextContent('All topics'),
    );
    expect(screen.queryByRole('region', { name: /Due now/ })).toBeNull();
    const active = section('Active now');
    expect(within(active).getByRole('article', { name: 'Morning' })).toBeInTheDocument();
    expect(morning()).toHaveLength(1);
    // The rest follow, the active topic left out.
    const list = screen.getByRole('article', { name: 'Vitamins' });
    expect(active.compareDocumentPosition(list) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
  });

  it('on the last step the primary is Lap (Stop beside it), and a tap laps', async () => {
    h = renderRunApp(
      '/',
      dueMorning(),
      (s) =>
        seedRun(s, [
          { type: 'next', s: 10, seg: 0 },
          { type: 'next', s: 20, seg: 1 },
        ]),
      [vitamins],
    );
    const active = await screen.findByRole('region', { name: /Active now/ });
    const lap = within(active).getByTestId('card-primary');
    expect(lap).toHaveAccessibleName('Lap');
    expect(within(active).getByTestId('card-stop')).toHaveAccessibleName('Stop Morning');
    expect(within(active).getByTestId('card-pause')).toHaveAccessibleName('Pause');
    await waitFor(() => expect(lap).toBeEnabled());
    await userEvent.click(lap);
    await waitFor(() => expect(h?.server.events()).toHaveLength(1), { timeout: 4000 });
    expect(h.server.events()[0]).toMatchObject({ type: 'lap', seg: 2 });
  });

  it('pauses and resumes from the title row', async () => {
    h = renderRunApp('/', dueMorning(), (s) => seedRun(s), [vitamins]);
    const active = await screen.findByRole('region', { name: /Active now/ });
    const pause = within(active).getByTestId('card-pause');
    await waitFor(() => expect(pause).toBeEnabled());
    await userEvent.click(pause);
    await waitFor(() => expect(h?.server.events()).toHaveLength(1), { timeout: 4000 });
    expect(h.server.events()[0]).toMatchObject({ type: 'pause' });
    const resume = await within(section('Active now')).findByTestId('card-resume');
    expect(within(section('Active now')).getByTestId('card-status')).toHaveTextContent('Paused');
    await waitFor(() => expect(resume).toBeEnabled());
    await userEvent.click(resume);
    await waitFor(() => expect(h?.server.events()).toHaveLength(2), { timeout: 4000 });
    expect(h.server.events()[1]).toMatchObject({ type: 'resume' });
  });

  it('goes when the run stops: the tile is idle again in its section', async () => {
    h = renderRunApp('/', dueMorning({ steps: [], questions: [] }), (s) => seedRun(s), [vitamins]);
    const active = await screen.findByRole('region', { name: /Active now/ });
    // Stop is never the primary (timers2.md §10): it is the card's secondary.
    const stop = within(active).getByTestId('card-stop');
    expect(stop).toHaveAccessibleName('Stop Morning');
    await waitFor(() => expect(stop).toBeEnabled());
    await userEvent.click(stop);
    expect(await screen.findByText(/^Saved Morning: 1:0\d$/)).toBeInTheDocument();
    await waitFor(() => expect(screen.queryByRole('region', { name: /Active now/ })).toBeNull());
    expect(
      await within(section('Due now')).findByRole('button', { name: 'Start Morning' }),
    ).toBeInTheDocument();
    expect(morning()).toHaveLength(1);
  });
});
