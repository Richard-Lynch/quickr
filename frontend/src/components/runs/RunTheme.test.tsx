/**
 * T2-WIRE-F (appearance.md §6.1, §6.4, §4.3; #286): the run surfaces in the topic's theme. A topic
 * with a colour fills the run panel's hero primary, the running bar's primary and the tile's
 * action with its tint; a topic without one keeps the accent classes exactly, with no variables.
 */
import { screen, within } from '@testing-library/react';
import { afterEach, describe, expect, it } from 'vitest';

import { renderRunApp, seedRun, timedTopic, type Harness } from '../../test/runUi';

let h: Harness | null = null;

afterEach(async () => {
  await h?.teardown();
  h = null;
});

/** The ancestor matching `selector`; fails the test when there's none. */
function closest(el: HTMLElement, selector: string): HTMLElement {
  const found = el.closest<HTMLElement>(selector);
  if (!found) throw new Error(`no ${selector} around the element`);
  return found;
}

function themed(color: 'teal' | null) {
  const f = timedTopic();
  f.topic.appearance = { color, icon: color ? { kind: 'emoji', value: '☀️' } : null, tags: [] };
  return f;
}

describe('the run panel in the topic’s theme', () => {
  it('a topic with a colour: the hero primary and the Running dot are its tint', async () => {
    h = renderRunApp('/t/morning/record', themed('teal'), (s) => seedRun(s));
    const primary = await screen.findByTestId('run-primary');
    expect(primary).toHaveClass('bg-topic-tint', 'text-topic-on-tint');
    expect(primary).not.toHaveClass('bg-accent');
    const card = closest(primary, '[aria-label="Run"]');
    expect(card.style.getPropertyValue('--topic-tint')).toContain('--topic-teal-tint');
    expect(screen.getByTestId('run-dot')).toHaveClass('bg-topic-tint');
  });

  it('a topic without one keeps the accent primary, and sets no variables', async () => {
    h = renderRunApp('/t/morning/record', themed(null), (s) => seedRun(s));
    const primary = await screen.findByTestId('run-primary');
    expect(primary).toHaveClass('bg-accent', 'text-on-accent');
    expect(primary).not.toHaveClass('bg-topic-tint');
    const card = closest(primary, '[aria-label="Run"]');
    expect(card.style.getPropertyValue('--topic-tint')).toBe('');
    expect(screen.getByTestId('run-dot')).toHaveClass('bg-accent');
  });

  it('idle: Start is the tint', async () => {
    h = renderRunApp('/t/morning/record', themed('teal'));
    const start = await screen.findByRole('button', { name: 'Start' });
    expect(start).toHaveClass('bg-topic-tint');
  });
});

describe('the running bar in the topic’s theme', () => {
  it('a themed run’s row carries its tint; its primary fills with it', async () => {
    h = renderRunApp('/t/morning', themed('teal'), (s) => seedRun(s));
    const primary = await screen.findByTestId('bar-primary');
    await expect.poll(() => primary.className).toContain('bg-topic-tint');
    const row = closest(primary, '[data-testid="bar-run"]');
    expect(row.style.getPropertyValue('--topic-tint')).toContain('--topic-teal-tint');
  });

  it('an untinted run’s primary stays the accent', async () => {
    h = renderRunApp('/t/morning', themed(null), (s) => seedRun(s));
    const primary = await screen.findByTestId('bar-primary');
    expect(primary).toHaveClass('bg-accent', 'text-on-accent');
  });
});

describe('the tile in the topic’s theme', () => {
  it('a coloured idle tile: its bar at rest, Start in the tint, the glyph before the name', async () => {
    h = renderRunApp('/', themed('teal'));
    const tile = await screen.findByRole('article', { name: 'Morning' });
    expect(tile.style.getPropertyValue('--topic-tint')).toContain('--topic-teal-tint');
    expect(tile.querySelector('.bg-topic-tint.w-1')).not.toBeNull();
    expect(within(tile).getByRole('button', { name: 'Start Morning' })).toHaveClass(
      'bg-topic-tint-soft',
    );
    expect(within(tile).getByRole('heading', { level: 2 })).toHaveTextContent('☀️');
  });

  it('an untinted idle tile: no bar at rest, the accent Start, no glyph', async () => {
    h = renderRunApp('/', themed(null));
    const tile = await screen.findByRole('article', { name: 'Morning' });
    expect(tile.style.getPropertyValue('--topic-tint')).toBe('');
    expect(tile.querySelector('.w-1.absolute')).toBeNull();
    expect(within(tile).getByRole('button', { name: 'Start Morning' })).toHaveClass(
      'bg-accent-soft',
    );
    expect(within(tile).queryByRole('img')).toBeNull();
  });
});
