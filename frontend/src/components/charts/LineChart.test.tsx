/** The tooltip's numbers: a missing min or max reads "—", with or without a format. */
import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';

import type { SeriesPoint } from '../../client';
import { LineChart } from './LineChart';

const points: SeriesPoint[] = [
  {
    start: '2026-10-19T00:00:00Z',
    count: 2,
    mean: 90_000,
    min: null,
    max: null,
    option_counts: {},
  },
  {
    start: '2026-10-20T00:00:00Z',
    count: 1,
    mean: 120_000,
    min: 120_000,
    max: 120_000,
    option_counts: {},
  },
];

function tooltip(format?: (v: number) => string): string {
  render(
    <LineChart
      points={points}
      bucket="day"
      unit={null}
      label="Run time"
      {...(format ? { format } : {})}
    />,
  );
  fireEvent.pointerDown(screen.getByRole('img', { name: 'Run time: average per day' }), {
    clientX: 0,
  });
  return screen.getByText(/n=2/).textContent;
}

describe('LineChart tooltip', () => {
  it('shows "—" for a null min and max by default', () => {
    expect(tooltip()).toBe('—–— · n=2');
  });

  it('shows "—" for a null min and max with a format', () => {
    expect(tooltip((v) => `${String(v / 1000)}s`)).toBe('—–— · n=2');
  });
});
