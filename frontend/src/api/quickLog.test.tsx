import 'fake-indexeddb/auto';

import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { act, renderHook, screen } from '@testing-library/react';
import type { ReactNode } from 'react';
import { afterEach, describe, expect, it, vi } from 'vitest';

import { ToastProvider } from '../components/ui/Toast';
import { outbox } from '../lib/outbox/client';
import { useQuickLog } from './quickLog';

const topic = { id: 't1', slug: 'sleep', name: 'Sleep', current_version: 1 };

function wrapper({ children }: { children: ReactNode }) {
  return (
    <QueryClientProvider client={new QueryClient()}>
      <ToastProvider>{children}</ToastProvider>
    </QueryClientProvider>
  );
}

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

afterEach(async () => {
  vi.unstubAllGlobals();
  await outbox.clear();
});

describe('quick log', () => {
  it('reports an entry the server retired (entry_deleted) as not saved, never as queued', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(() =>
        Promise.resolve(json(409, { code: 'entry_deleted', detail: 'deleted', errors: [] })),
      ),
    );
    const { result } = renderHook(() => useQuickLog(), { wrapper });
    let outcome: Awaited<ReturnType<typeof result.current>> | undefined;
    await act(async () => {
      outcome = await result.current(topic, { quality: 'ok' }, { label: 'OK' });
    });
    expect(outcome?.status).toBe('retired');
    expect(await outbox.list()).toEqual([]);
    expect(screen.getByRole('status')).toHaveTextContent('Not saved');
    expect(screen.queryByText(/will sync/)).toBeNull();
  });

  it('still reports a queued entry as saved on this device', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(() => Promise.reject(new TypeError('offline'))),
    );
    const { result } = renderHook(() => useQuickLog(), { wrapper });
    let outcome: Awaited<ReturnType<typeof result.current>> | undefined;
    await act(async () => {
      outcome = await result.current(topic, { quality: 'ok' }, { label: 'OK' });
    });
    expect(outcome?.status).toBe('queued');
    expect(screen.getByRole('status')).toHaveTextContent('will sync');
  });
});
