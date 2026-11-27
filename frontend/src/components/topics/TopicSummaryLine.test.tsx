import { render, screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';

import type { EntryOut, Timing } from '../../client';
import type { Question } from '../../lib/questions';
import { normalTimer } from '../../test/timer';
import { TopicSummaryLine } from './TopicSummaryLine';

const WEIGHT: Question = {
  key: 'weight',
  label: 'Weight',
  help_text: null,
  required: true,
  type: 'int',
  unit: 'kg',
  min: null,
  max: null,
};

const NOTE: Question = {
  key: 'note',
  label: 'Note',
  help_text: null,
  required: false,
  type: 'str',
  min_length: 0,
  max_length: 500,
  multiline: true,
};

const lap = (i: number) => ({
  kind: 'lap' as const,
  step: null,
  label: `Lap ${i}`,
  started_at: '2026-10-23T08:00:00Z',
  ended_at: '2026-10-23T08:01:00Z',
  active_ms: 60_000,
  paused_ms: 0,
  lap_type: null,
  event_id: null,
  opened_by: null,
});

const TIMING: Timing = {
  started_at: '2026-10-23T08:00:00Z',
  ended_at: '2026-10-23T08:12:40Z',
  active_ms: 760_000,
  paused_ms: 0,
  complete: true,
  edited: false,
  terminal_id: null,
  segments: [lap(1), lap(2), lap(3)],
  pauses: [],
  skipped: [],
};

function entry(over: Partial<EntryOut> = {}): EntryOut {
  return {
    id: 'e1',
    topic_id: 't1',
    version: 1,
    revision: 1,
    source: 'phone',
    channel: 'ui',
    captured_at: '2026-10-23T08:12:40Z',
    created_at: '2026-10-23T08:12:40Z',
    updated_at: '2026-10-23T08:12:40Z',
    notes: '',
    meta: {},
    answers: [{ key: 'weight', type: 'int', value: 72 }],
    timing: null,
    ...over,
  };
}

const FALLBACK = <span data-testid="fallback">4 entries · 4 days ago</span>;

describe('TopicSummaryLine', () => {
  it('shows the last entry’s summary line, one line and truncated', () => {
    render(
      <TopicSummaryLine
        entry={entry({ timing: TIMING })}
        questions={[WEIGHT]}
        timer={normalTimer({ steps: [] })}
        fallback={FALLBACK}
      />,
    );
    const line = screen.getByTestId('topic-summary');
    expect(line).toHaveTextContent('12:40 · 3 laps · Weight: 72 kg');
    expect(line).toHaveClass('truncate', 'text-ink-soft');
    expect(line).toHaveAttribute('title', '12:40 · 3 laps · Weight: 72 kg');
    expect(screen.queryByTestId('fallback')).toBeNull();
  });

  it('shows the fallback without an entry', () => {
    render(<TopicSummaryLine entry={null} questions={[WEIGHT]} timer={null} fallback={FALLBACK} />);
    expect(screen.getByTestId('fallback')).toHaveTextContent('4 entries · 4 days ago');
    expect(screen.queryByTestId('topic-summary')).toBeNull();
  });

  it('renders an empty line as nothing: the fallback, or nothing at all', () => {
    // A blank note is nothing to say (`''`).
    const blank = entry({ answers: [{ key: 'note', type: 'str', value: ' \n\t ' }] });
    const { container, rerender } = render(
      <TopicSummaryLine entry={blank} questions={[NOTE]} timer={null} fallback={FALLBACK} />,
    );
    expect(screen.queryByTestId('topic-summary')).toBeNull();
    expect(screen.getByTestId('fallback')).toBeInTheDocument();
    rerender(<TopicSummaryLine entry={blank} questions={[NOTE]} timer={null} fallback={null} />);
    expect(container).toBeEmptyDOMElement();
  });

  it('renders the timing part only while the questions load, then the fallback', () => {
    const { rerender } = render(
      <TopicSummaryLine
        entry={entry({ timing: TIMING })}
        questions={null}
        timer={normalTimer({ steps: [] })}
        fallback={FALLBACK}
      />,
    );
    expect(screen.getByTestId('topic-summary')).toHaveTextContent(/^12:40 · 3 laps$/);
    rerender(
      <TopicSummaryLine entry={entry()} questions={null} timer={null} fallback={FALLBACK} />,
    );
    expect(screen.queryByTestId('topic-summary')).toBeNull();
    expect(screen.getByTestId('fallback')).toBeInTheDocument();
  });
});
