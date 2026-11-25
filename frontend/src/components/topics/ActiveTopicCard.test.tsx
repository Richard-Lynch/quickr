/** The active card's layout (active-surfaces.md §6.2) from its run and its controls. */
import { render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router';
import { describe, expect, it, vi } from 'vitest';

import type { LocalRun } from '../../lib/runs/localView';
import type { OpenSegment } from '../../lib/runs/types';
import { ActiveTopicCard, cardHeadline, cardTint, type CardControls } from './ActiveTopicCard';

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
    },
    events: [],
    aliases: [],
    server: null,
    queued: [],
    steps: null,
    requires_answers: null,
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

function renderCard(run: LocalRun, controls: CardControls) {
  render(
    <MemoryRouter>
      <ActiveTopicCard topic={topic} run={run} controls={controls} />
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
    expect(primary).toHaveTextContent('Next: Breakfast');
    expect(within(card).getByTestId('card-stop')).toHaveAccessibleName('Stop · Morning');
    expect(within(card).getByTestId('card-pause')).toHaveAccessibleName('Pause · Morning');
    expect(within(card).getAllByRole('button')).toHaveLength(3);
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

  it('shows no controls row without controls', () => {
    const card = renderCard(runOf(), { primary: null, stop: null, pauseResume: null });
    expect(within(card).queryAllByRole('button')).toEqual([]);
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

  it('is tinted with the accent until the topic theme lands (one seam)', () => {
    const card = renderCard(runOf(), controlsOf());
    expect(card).toHaveClass('border-accent/45', 'bg-accent-soft');
    expect(card.getAttribute('style')).toBeNull();
    expect(card.querySelector('span[aria-hidden].bg-accent')).not.toBeNull();
    expect(cardTint(topic)).toEqual({
      style: undefined,
      card: 'border-accent/45 bg-accent-soft',
      bar: 'bg-accent',
    });
  });

  it('headline: the open segment’s label until M1’s headline lands', () => {
    expect(cardHeadline(runOf())).toBe('Shower');
    expect(cardHeadline(runOf({ open: null }))).toBeNull();
  });
});
