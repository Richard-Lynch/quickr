/** The active card's layout (active-surfaces.md §6.2) from its run and its controls. */
import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router';
import { afterEach, describe, expect, it, vi } from 'vitest';

import { outbox } from '../../lib/outbox/client';
import type { LocalRun } from '../../lib/runs/localView';
import type { OpenSegment } from '../../lib/runs/types';
import { lapTopic, reopens, seedStopped } from '../../test/resume';
import { renderRunApp, type Harness } from '../../test/runUi';
import {
  ActiveTopicCard,
  cardTint,
  isResuming,
  type CardControls,
  type CardTopic,
} from './ActiveTopicCard';

const topic = { id: '6f1c0000-0000-4000-8000-0000000000c1', slug: 'morning', name: 'Morning' };

/** A run started a minute ago, its open segment from 20 s in; paused from 30 s in if asked. */
function runOf(opts: { paused?: boolean; open?: OpenSegment | null } = {}): LocalRun {
  const start = Date.now() - 60_000;
  const open =
    opts.open === undefined
      ? {
          index: 1,
          kind: 'step' as const,
          step: 'shower',
          label: 'Shower',
          started_at: start + 20_000,
          lap_type: null,
        }
      : opts.open;
  return {
    id: '0b5e0000-0000-4000-8000-0000000000c1',
    topic_id: topic.id,
    topic: null,
    version: 1,
    status: opts.paused ? 'paused' : 'running',
    state: {
      status: opts.paused ? 'paused' : 'running',
      started_at: start,
      ended_at: null,
      open,
      next_step: 'breakfast',
      paused_since: opts.paused ? start + 30_000 : null,
      segments: [],
      skipped: [],
      pauses: [],
      effects: {},
      terminal_id: null,
      next_lap_type: null,
      lap_count: 0,
    },
    events: [],
    aliases: [],
    server: null,
    queued: [],
    steps: null,
    requires_answers: null,
    laps: null,
    resuming: false,
    has_entry: false,
  };
}

function controlsOf(over: Partial<CardControls> = {}): CardControls & {
  taps: ReturnType<typeof vi.fn>;
} {
  const taps = vi.fn();
  const button = (title: string, icon: 'chevronRight' | 'stop' | 'pause' | 'play') => ({
    title,
    label: `${title} · Morning`,
    icon,
    disabled: false,
    onTap: () => {
      taps(title);
    },
  });
  return {
    primary: button('Next: Breakfast', 'chevronRight'),
    stop: button('Stop', 'stop'),
    pauseResume: { ...button('Pause', 'pause'), paused: false },
    ...over,
    taps,
  };
}

function renderCard(
  run: LocalRun,
  controls: CardControls,
  of: CardTopic = topic,
  resuming = false,
) {
  render(
    <MemoryRouter>
      <ActiveTopicCard topic={of} run={run} timer={null} controls={controls} resuming={resuming} />
    </MemoryRouter>,
  );
  return screen.getByRole('article', { name: 'Morning' });
}

describe('the active card', () => {
  it('shows the status with the headline, the segment clock big and the total beside it', () => {
    const card = renderCard(runOf(), controlsOf());
    expect(within(card).getByTestId('card-status')).toHaveTextContent('Running · Shower');
    // The segment is the big clock: 0:40 in (from 20 s of a 60 s run); the total is 1:00.
    const segment = within(card).getByText('Segment').parentElement;
    expect(segment).toHaveTextContent(/^Segment 0:4\d$/);
    expect(segment).toHaveClass('text-5xl');
    expect(within(card).getByTestId('card-total')).toHaveTextContent(/^total Total 1:0\d$/);
    // No alerts before M1's alert line: the row collapses.
    expect(within(card).queryByTestId('card-alert')).toBeNull();
  });

  it('paused: "Paused", Resume in the title row, the clocks stopped and dimmed', () => {
    const controls = controlsOf({
      pauseResume: {
        title: 'Resume',
        label: 'Resume Morning',
        icon: 'play',
        disabled: false,
        onTap: () => undefined,
        paused: true,
      },
    });
    const card = renderCard(runOf({ paused: true }), controls);
    expect(within(card).getByTestId('card-status')).toHaveTextContent('Paused · Shower');
    const segment = within(card).getByText('Segment').parentElement;
    expect(segment).toHaveTextContent('Segment 0:10');
    expect(segment).toHaveClass('text-muted');
    expect(within(card).getByTestId('card-total')).toHaveTextContent('0:30');
    expect(within(card).getByTestId('card-resume')).toHaveAccessibleName('Resume Morning');
    expect(within(card).queryByTestId('card-pause')).toBeNull();
  });

  it('renders the primary, Stop and Pause once each, and taps them', async () => {
    const controls = controlsOf();
    const card = renderCard(runOf(), controls);
    const primary = within(card).getByTestId('card-primary');
    expect(primary).toHaveAccessibleName('Next: Breakfast · Morning');
    expect(primary).toHaveClass('min-h-14');
    expect(primary).toHaveTextContent('Next: Breakfast');
    expect(within(card).getByTestId('card-stop')).toHaveAccessibleName('Stop · Morning');
    expect(within(card).getByTestId('card-pause')).toHaveAccessibleName('Pause · Morning');
    // Screen readers meet them in the order primary, Stop, Pause (§7), after the clocks.
    expect(
      within(card)
        .getAllByRole('button')
        .map((b) => b.dataset.testid),
    ).toEqual(['card-primary', 'card-stop', 'card-pause', 'card-menu']);
    const status = within(card).getByTestId('card-status');
    expect(status.compareDocumentPosition(primary) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    await userEvent.click(primary);
    await userEvent.click(within(card).getByTestId('card-stop'));
    await userEvent.click(within(card).getByTestId('card-pause'));
    expect(controls.taps.mock.calls).toEqual([['Next: Breakfast'], ['Stop'], ['Pause']]);
  });

  it('leaves out an empty slot: no second Stop beside a Stop primary', () => {
    const controls = controlsOf();
    const card = renderCard(runOf(), { ...controls, primary: controls.stop, stop: null });
    expect(within(card).getByTestId('card-primary')).toHaveTextContent('Stop');
    expect(within(card).queryByTestId('card-stop')).toBeNull();
    expect(within(card).getAllByRole('button', { name: /^Stop/ })).toHaveLength(1);
  });

  it('a disabled control still takes the tap: it never falls through to the card’s link', () => {
    const controls = controlsOf();
    const card = renderCard(runOf(), {
      ...controls,
      primary: controls.primary && { ...controls.primary, disabled: true },
    });
    const primary = within(card).getByTestId('card-primary');
    expect(primary.className).not.toMatch(/pointer-events-none/);
    // A long unbroken label breaks inside the button rather than being clipped.
    expect(within(primary).getByText('Next: Breakfast')).toHaveClass('[overflow-wrap:anywhere]');
  });

  it('shows no controls row without controls, only the topic pages', () => {
    const card = renderCard(runOf(), { primary: null, stop: null, pauseResume: null });
    expect(
      within(card)
        .getAllByRole('button')
        .map((b) => b.dataset.testid),
    ).toEqual(['card-menu']);
  });

  it('Pause is a real button: an outlined capsule with a 44 px target, like Stop', () => {
    const card = renderCard(runOf(), controlsOf());
    const pause = within(card).getByRole('button', { name: 'Pause · Morning' });
    expect(pause).toHaveAttribute('data-testid', 'card-pause');
    expect(pause.tagName).toBe('BUTTON');
    // jsdom has no layout: the classes are the frame (min-h-11 is 44 px) and the outline.
    expect(pause).toHaveClass(
      'min-h-11',
      'rounded-full',
      'border',
      'border-line-strong',
      'bg-surface',
    );
    expect(within(card).getByTestId('card-menu')).toHaveClass('size-11', 'border');
  });

  it('the "…" lists the topic’s stats, entries, builder and settings', async () => {
    const card = renderCard(runOf(), controlsOf());
    const menu = within(card).getByRole('button', { name: 'Morning: topic pages' });
    expect(screen.queryByRole('list', { name: 'Topic pages' })).toBeNull();
    await userEvent.click(menu);
    // The sheet is a dialog named after the topic.
    expect(screen.getByRole('dialog', { name: 'Morning' })).toBeInTheDocument();
    const pages = screen.getByRole('list', { name: 'Topic pages' });
    expect(
      within(pages)
        .getAllByRole('link')
        .map((a) => [a.textContent, a.getAttribute('href')]),
    ).toEqual([
      ['Stats', '/t/morning'],
      ['Entries', '/t/morning/entries'],
      ['Edit questions', '/t/morning/edit'],
      ['Topic settings', '/t/morning/settings'],
    ]);
  });

  it('disables a control its source disables', () => {
    const controls = controlsOf();
    const card = renderCard(runOf(), {
      ...controls,
      primary: controls.primary && { ...controls.primary, disabled: true },
    });
    expect(within(card).getByTestId('card-primary')).toBeDisabled();
    expect(within(card).getByTestId('card-stop')).toBeEnabled();
  });

  it('with nothing open: the total is the big clock and the status has no headline', () => {
    const card = renderCard(runOf({ open: null }), controlsOf());
    expect(within(card).getByTestId('card-status')).toHaveTextContent(/^Running$/);
    expect(within(card).getByText('Total').parentElement).toHaveClass('text-5xl');
    expect(within(card).queryByTestId('card-total')).toBeNull();
  });

  it('opens the run panel from anywhere else: one link, to the record page', () => {
    const card = renderCard(runOf(), controlsOf());
    const links = within(card).getAllByRole('link');
    expect(links).toHaveLength(1);
    expect(links[0]).toHaveAccessibleName('Morning');
    expect(links[0]).toHaveAttribute('href', '/t/morning/record');
  });

  it('is the brand accent for a topic without a colour, with its initial', () => {
    const card = renderCard(runOf(), controlsOf());
    expect(card).toHaveClass('border-topic-tint/45', 'bg-topic-tint-soft');
    expect(card.getAttribute('style')).toBeNull();
    expect(card.querySelector('span[aria-hidden].bg-topic-tint')).not.toBeNull();
    expect(within(card).getByTestId('card-primary')).toHaveClass(
      'bg-topic-tint',
      'text-topic-on-tint',
    );
    // The glyph is decoration here: the name is the card's (and its link's) name.
    expect(card.querySelector('[aria-hidden] [role="img"]')).toHaveTextContent('M');
    expect(within(card).queryByRole('img')).toBeNull();
  });

  it('is tinted with the topic’s colour and shows its emoji (appearance.md §4.2)', () => {
    const themed: CardTopic = {
      ...topic,
      appearance: { color: 'green', icon: { kind: 'emoji', value: '🌅' }, tags: [] },
    };
    const card = renderCard(runOf(), controlsOf(), themed);
    expect(card.style.getPropertyValue('--topic-tint')).toMatch(/^var\(--topic-green-tint, /);
    expect(card.style.getPropertyValue('--topic-tint-soft')).toMatch(/^var\(--topic-green-soft, /);
    expect(card).toHaveTextContent('🌅');
    expect(cardTint(themed).card).toBe('border-topic-tint/45 bg-topic-tint-soft');
  });

  it('resuming (a queued reopen, not acked): "Resuming…" and no controls until the ack', () => {
    const card = renderCard(runOf(), controlsOf(), topic, true);
    expect(within(card).getByTestId('card-status')).toHaveTextContent(/^Resuming… · Shower$/);
    // No run controls; the topic's pages stay reachable.
    expect(
      within(card)
        .getAllByRole('button')
        .map((b) => b.dataset.testid),
    ).toEqual(['card-menu']);
    // The clocks still run, and the card still opens the run panel.
    expect(within(card).getByTestId('card-total')).toHaveTextContent(/1:0\d/);
    expect(within(card).getByRole('link', { name: 'Morning' })).toBeInTheDocument();
  });

  it('isResuming reads the local view’s "resuming" projection (timers2.md §5.3)', () => {
    expect(isResuming(runOf())).toBe(false);
    expect(isResuming({ ...runOf(), resuming: true })).toBe(true);
  });

  it('reads M1’s headline: the open segment’s label, nothing extra with nothing open', () => {
    expect(within(renderCard(runOf(), controlsOf())).getByTestId('card-status')).toHaveTextContent(
      /^Running · Shower$/,
    );
  });
});

describe('the Resuming card on the topics page (§3.3, §6.3; timers2.md §5.3)', () => {
  let h: Harness | null = null;
  /** The harness's fake server (the test has rendered the app). */
  const server = () => {
    if (!h) throw new Error('no harness');
    return h.server;
  };
  afterEach(async () => {
    await h?.teardown();
    h = null;
  });

  it('a tile’s Resume, not acked yet: "Resuming…" and no controls row, then the open layout on the ack', async () => {
    let hold = true;
    h = renderRunApp('/', lapTopic(), (s) => seedStopped(s, 114_000, 10_000));
    server().override = (body) =>
      body.type === 'reopen' && hold ? new Response('{}', { status: 503 }) : undefined;
    const user = userEvent.setup();
    await user.click(await screen.findByTestId('run-reopen'));

    const card = await screen.findByTestId('active-card');
    await waitFor(() =>
      expect(within(card).getByTestId('card-status')).toHaveTextContent(/^Resuming…/),
    );
    expect(
      within(card)
        .getAllByRole('button')
        .map((b) => b.dataset.testid),
    ).toEqual(['card-menu']);
    expect(screen.queryByTestId('run-reopen')).toBeNull();

    hold = false;
    const item = (await outbox.list()).find((i) => i.status === 'pending');
    await outbox.retry(item?.id ?? '');
    expect(await screen.findByTestId('card-primary')).toBeInTheDocument();
    expect(screen.getByTestId('card-stop')).toBeInTheDocument();
    expect(screen.getByTestId('card-status')).toHaveTextContent(/^Running/);
  });

  it('the card’s stop toast offers Resume, aimed at that stop', async () => {
    h = renderRunApp('/', lapTopic());
    const user = userEvent.setup();
    await user.click(await screen.findByRole('button', { name: 'Start Morning' }));
    await user.click(await screen.findByTestId('card-stop'));
    const saved = await screen.findByText(/^Saved Morning: \d+:\d\d$/);
    await waitFor(() => expect(server().events()).toHaveLength(2));
    const stop = server().events()[1];
    await user.click(
      within(saved.closest<HTMLElement>('[role]') ?? saved).getByRole('button', { name: 'Resume' }),
    );
    await waitFor(() => expect(reopens(server())).toHaveLength(1), { timeout: 4000 });
    expect(reopens(server())[0]?.target).toBe(stop?.id);
    expect(await screen.findByTestId('active-card')).toBeInTheDocument();
  });
});

describe('the topic’s pages while its run is open (active-surfaces.md §3.2, §6.2)', () => {
  let h: Harness | null = null;
  afterEach(async () => {
    await h?.teardown();
    h = null;
  });

  /** Morning started from its tile: its "Active now" card is up. */
  async function started() {
    h = renderRunApp('/', lapTopic());
    const user = userEvent.setup();
    await user.click(await screen.findByRole('button', { name: 'Start Morning' }));
    expect(await screen.findByTestId('active-card')).toBeInTheDocument();
    return user;
  }

  /** Opens the `menu` "…" and follows its `page` link. */
  async function follow(user: ReturnType<typeof userEvent.setup>, menu: string, page: string) {
    await user.click(await screen.findByTestId(menu));
    await user.click(await screen.findByTestId(`${menu}-${page}`));
  }

  it.each([
    ['entries', '/t/morning/entries', 'Topic entries'],
    ['stats', '/t/morning', 'Topic overview'],
    ['edit', '/t/morning/edit', 'Topic builder'],
    ['settings', '/t/morning/settings', 'Topic settings'],
  ])('the card’s "…" opens the topic’s %s', async (page, path, text) => {
    const user = await started();
    await follow(user, 'card-menu', page);
    await waitFor(() =>
      expect(screen.getByTestId('where')).toHaveTextContent(new RegExp(`^${path}$`)),
    );
    expect(await screen.findByText(text)).toBeInTheDocument();
  });

  it('the run panel’s "…" opens the topic’s entries and settings too', async () => {
    const user = await started();
    // The card itself still opens the run panel.
    await user.click(screen.getByRole('link', { name: 'Morning' }));
    await waitFor(() =>
      expect(screen.getByTestId('where')).toHaveTextContent(/^\/t\/morning\/record$/),
    );
    expect(await screen.findByTestId('run-stop')).toBeInTheDocument();
    await follow(user, 'run-topic-menu', 'entries');
    await waitFor(() =>
      expect(screen.getByTestId('where')).toHaveTextContent(/^\/t\/morning\/entries$/),
    );
    expect(await screen.findByText('Topic entries')).toBeInTheDocument();
  });

  it('the run panel’s "…" reaches the settings', async () => {
    const user = await started();
    await user.click(screen.getByRole('link', { name: 'Morning' }));
    expect(await screen.findByTestId('run-stop')).toBeInTheDocument();
    await follow(user, 'run-topic-menu', 'settings');
    await waitFor(() =>
      expect(screen.getByTestId('where')).toHaveTextContent(/^\/t\/morning\/settings$/),
    );
  });
});
