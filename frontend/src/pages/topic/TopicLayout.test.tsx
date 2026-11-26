/**
 * The topic header's appearance (appearance.md §6.3, §5, §4.3): the glyph before the name, the tag
 * chips under the version tag, and the tint. A topic with no appearance renders exactly as before.
 */
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { render, screen, within } from '@testing-library/react';
import { createMemoryRouter, Outlet, RouterProvider } from 'react-router';
import { describe, expect, it } from 'vitest';

import type { TopicDetail } from '../../client';
import { TopicTabs } from './TopicLayout';

const base: TopicDetail = {
  id: '6f1c0000-0000-4000-8000-000000000002',
  slug: 'running',
  name: 'Running',
  description: '',
  status: 'active',
  current_version: 3,
  revision: 1,
  question_count: 0,
  entry_count: 4,
  last_captured_at: null,
  created_at: '2026-10-01T00:00:00Z',
  updated_at: '2026-10-01T00:00:00Z',
  archived_at: null,
  schedule: null,
  schedule_updated_at: null,
  due: null,
  timer: null,
  questions: [],
  // What the server sends for a topic nobody has styled (§1.1: always normalised).
  appearance: { color: null, icon: null, tags: [] },
};

type Appearance = TopicDetail['appearance'];
const withAppearance = (appearance: Appearance): TopicDetail => ({ ...base, appearance });

const EMOJI_TAGS: Appearance = {
  color: null,
  icon: { kind: 'emoji', value: '🏃' },
  tags: ['Health', 'Outdoors'],
};

function renderHeader(topic: TopicDetail) {
  const router = createMemoryRouter(
    [
      {
        path: '/t/:ref',
        element: <Outlet context={{ topic }} />,
        children: [{ element: <TopicTabs />, children: [{ index: true, element: null }] }],
      },
    ],
    { initialEntries: ['/t/running'] },
  );
  return render(
    <QueryClientProvider client={new QueryClient()}>
      <RouterProvider router={router} />
    </QueryClientProvider>,
  );
}

function present<T>(el: T | null | undefined): T {
  if (el == null) throw new Error('expected an element');
  return el;
}

const header = () => present(screen.getByRole('heading', { level: 1 }).closest('section'));
const tabs = () => screen.getByRole('navigation', { name: 'Topic sections' });
const activeTab = () => within(tabs()).getByRole('link', { name: 'Overview' });
const glyph = () => screen.queryByTestId('topic-glyph');

describe('TopicTabs header: no appearance', () => {
  it('renders as on main for the empty appearance', () => {
    renderHeader(base);
    expect(glyph()).toBeNull();
    expect(screen.queryByRole('list', { name: 'Tags' })).toBeNull();
    expect(header().hasAttribute('style')).toBe(false);
    expect(tabs().hasAttribute('style')).toBe(false);
    expect(activeTab()).toHaveClass('after:bg-accent');
    expect(activeTab()).not.toHaveClass('after:bg-topic-tint');
    expect(screen.getByRole('heading', { level: 1 })).toHaveTextContent(/^Running$/);
    // The section holds exactly main's rows: the version row, then the title row.
    expect(Array.from(header().children, (c) => c.tagName)).toEqual(['DIV', 'DIV']);
  });
});

describe('TopicTabs header: no colour', () => {
  it('shows the emoji and neutral chips under the version tag, with no tint', () => {
    renderHeader(withAppearance(EMOJI_TAGS));
    const g = glyph();
    expect(g).not.toBeNull();
    expect(g).toHaveAttribute('aria-hidden', 'true');
    const img = within(present(g)).getByRole('img', { hidden: true });
    expect(img).toHaveTextContent('🏃');
    expect(img).not.toHaveClass('rounded-full');
    // The glyph is decorative: the heading's name is the topic's name alone.
    expect(screen.getByRole('heading', { level: 1, name: 'Running' })).toContainElement(g);

    const chips = within(screen.getByRole('list', { name: 'Tags' })).getAllByRole('listitem');
    expect(chips.map((c) => c.textContent)).toEqual(['Health', 'Outdoors']);
    for (const chip of chips)
      expect(chip.firstElementChild).toHaveClass('bg-sunken', 'text-ink-soft');
    // Under the version tag's row.
    const versionRow = present(screen.getByText('v3').parentElement);
    expect(versionRow.nextElementSibling).toBe(screen.getByRole('list', { name: 'Tags' }));

    expect(header().hasAttribute('style')).toBe(false);
    expect(tabs().hasAttribute('style')).toBe(false);
    expect(activeTab()).toHaveClass('after:bg-accent');
  });

  it('shows chips but no glyph (no initial circle) for tags alone', () => {
    renderHeader(withAppearance({ color: null, icon: null, tags: ['Gym'] }));
    expect(glyph()).toBeNull();
    expect(screen.getByRole('list', { name: 'Tags' })).toHaveTextContent('Gym');
    expect(header().hasAttribute('style')).toBe(false);
  });

  it('shows the emoji with no chips row when there are no tags', () => {
    renderHeader(withAppearance({ ...EMOJI_TAGS, tags: [] }));
    expect(glyph()).toHaveTextContent('🏃');
    expect(screen.queryByRole('list', { name: 'Tags' })).toBeNull();
  });
});

describe('TopicTabs header: a colour', () => {
  it('tints the header and the active tab, and shows the emoji', () => {
    renderHeader(withAppearance({ ...EMOJI_TAGS, color: 'teal' }));
    for (const el of [header(), tabs()]) {
      expect(el.style.getPropertyValue('--topic-tint')).toBe('var(--topic-teal-tint, #19786f)');
      expect(el.style.getPropertyValue('--topic-on-tint')).toBe('var(--topic-teal-on, #ffffff)');
    }
    expect(activeTab()).toHaveClass('after:bg-topic-tint');
    expect(activeTab()).not.toHaveClass('after:bg-accent');
    const img = within(present(glyph())).getByRole('img', { hidden: true });
    expect(img).toHaveTextContent('🏃');
    expect(img).not.toHaveClass('rounded-full');
    expect(screen.getByRole('list', { name: 'Tags' })).toHaveTextContent('HealthOutdoors');
  });

  it('shows the initial on the tint circle when there is no emoji', () => {
    renderHeader(withAppearance({ color: 'pink', icon: null, tags: [] }));
    const img = within(present(glyph())).getByRole('img', { hidden: true });
    expect(img).toHaveTextContent(/^R$/);
    expect(img).toHaveClass('rounded-full', 'bg-topic-tint', 'text-topic-on-tint');
    expect(img.style.getPropertyValue('--topic-tint')).toBe('var(--topic-pink-tint, #b8386e)');
    expect(header().style.getPropertyValue('--topic-tint')).toBe('var(--topic-pink-tint, #b8386e)');
    expect(screen.getByRole('heading', { level: 1, name: 'Running' })).toBeInTheDocument();
  });
});
