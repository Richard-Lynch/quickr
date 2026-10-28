/**
 * The page outbox against a server that refuses this bundle, or is behind it
 * (client-versions.md §5.3, §5.4, V10, V14).
 */
import 'fake-indexeddb/auto';

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import {
  API_LEVEL,
  isClientOutdated,
  isServerBehind,
  markClientOutdated,
  observeResponse,
  resetClientVersion,
} from '../../api/clientVersion';
import { fakeQuickrServer, type FakeQuickrServer } from '../../test/fakeQuickrServer';
import { T0, TOPIC as RUN_TOPIC, runItem } from '../../test/runs';
import { memoryAckedStore, setAckedStore } from '../runs/acked';
import { kickOutbox, outbox, startOutbox } from './client';
import { ENTRY_CREATE, RUN_EVENT, type EntryCreatePayload } from './kinds';

const SERVER = '0b9e0000-0000-4000-8000-0000000000aa';
const TOPIC = '6f1c0000-0000-4000-8000-000000000001';
const ENTRY = '7a000000-0000-4000-8000-000000000001';

const entry: EntryCreatePayload = {
  topic: { id: TOPIC, slug: 'mood', name: 'Mood' },
  body: { answers: { mood: 'ok' } },
};

let server: FakeQuickrServer;

beforeEach(async () => {
  setAckedStore(memoryAckedStore());
  server = fakeQuickrServer(SERVER, [TOPIC, RUN_TOPIC.id]);
  vi.stubGlobal('fetch', server.fetch);
  const start = runItem('start', { id: 'r1', run: 'r1', at: T0 });
  await outbox.enqueue(ENTRY_CREATE, entry, { id: ENTRY });
  await outbox.enqueue(RUN_EVENT, start.payload, { id: 'r1' });
});

afterEach(async () => {
  resetClientVersion();
  await outbox.clear();
  vi.unstubAllGlobals();
});

describe('page outbox, outdated (V10)', () => {
  it('holds an entry and a run event, sends nothing more, and sends them once updated', async () => {
    server.minWebLevel = API_LEVEL + 1;
    const before = await outbox.list();
    const r = await outbox.flush({ force: true });
    expect(r).toMatchObject({ sent: 0, failed: 0, retrying: 0, remaining: 2 });
    expect(isClientOutdated()).toBe(true);
    expect(server.requests).toHaveLength(1);
    // Held, not failed: both exactly as they were.
    expect(await outbox.list()).toEqual(before);

    // Known outdated: nothing is sent, flush or sendNow.
    await outbox.flush({ force: true });
    expect(await outbox.sendNow(ENTRY, 60_000)).toMatchObject({ status: 'queued' });
    expect(server.requests).toHaveLength(1);

    // The updated bundle (a reload: the state is in memory only) sends both.
    server.minWebLevel = 0;
    resetClientVersion();
    expect(await outbox.flush({ force: true })).toMatchObject({ sent: 2, remaining: 0 });
    expect(server.entries.size).toBe(1);
    expect([...server.runs.keys()]).toEqual(['r1']);
  });
});

describe('page outbox, server behind (V14)', () => {
  it('still sends, and nothing is held', async () => {
    server.apiLevel = 0;
    expect(await outbox.flush({ force: true })).toMatchObject({ sent: 2, remaining: 0 });
    expect(await outbox.list()).toEqual([]);
    expect(isServerBehind()).toBe(true);
    expect(isClientOutdated()).toBe(false);
  });
});

describe('page outbox scheduling while outdated', () => {
  it('arms no timer while outdated, and is kicked when the minimum drops', async () => {
    markClientOutdated();
    const nextDueAt = vi.spyOn(outbox, 'nextDueAt');
    const stop = startOutbox();
    await kickOutbox(true);
    expect(nextDueAt).not.toHaveBeenCalled();
    expect(server.requests).toEqual([]);

    await observeResponse(
      new Response('{}', { headers: { 'X-QuickR-Min-Client-Level': 'ios=0, web=0' } }),
    );
    await vi.waitFor(() => {
      expect(server.entries.size).toBe(1);
    });
    stop();
    nextDueAt.mockRestore();
  });
});
