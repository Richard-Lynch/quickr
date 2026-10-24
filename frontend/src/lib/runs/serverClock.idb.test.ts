/**
 * The server-time offset's IndexedDB copy (timers.md §5.1, §10.2): the page records samples,
 * and the service worker, which has no `localStorage`, loads the latest before stamping a
 * reminder's Start. The two contexts are two module instances over one fake IndexedDB.
 */
import { IDBFactory } from 'fake-indexeddb';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import type * as serverClock from './serverClock';

type ServerClock = typeof serverClock;

/** A fresh copy of the module: another context's memory. */
async function context(): Promise<ServerClock> {
  vi.resetModules();
  return import('./serverClock');
}

beforeEach(() => {
  vi.stubGlobal('indexedDB', new IDBFactory());
});

afterEach(() => {
  vi.unstubAllGlobals();
  localStorage.clear();
});

describe('the server offset in IndexedDB', () => {
  it('a page sample reaches the service worker, which has no localStorage', async () => {
    const page = await context();
    expect(page.recordServerTime('10500', 10_000, 10_200)).toBe(400);

    vi.stubGlobal('localStorage', undefined);
    const sw = await context();
    expect(sw.serverOffset()).toBe(0); // before loading: memory only
    await vi.waitFor(async () => {
      expect(await sw.loadServerOffset()).toBe(400);
    });
    expect(sw.serverOffset()).toBe(400);
  });

  it('a response without a qualifying sample leaves the stored copy alone', async () => {
    const page = await context();
    await page.persistServerOffset(400);
    vi.stubGlobal('localStorage', undefined);
    const sw = await context(); // memory 0, not loaded yet
    sw.recordServerTime(null, 10_000, 10_100);
    sw.recordServerTime('99999', 10_000, 15_001); // too slow
    await new Promise((r) => setTimeout(r, 10));
    expect(await (await context()).loadServerOffset()).toBe(400);
  });

  it('ignores a stored offset of more than a day either way', async () => {
    const page = await context();
    await page.persistServerOffset(400);
    vi.stubGlobal('localStorage', undefined);
    const sw = await context();
    expect(await sw.loadServerOffset()).toBe(400);
    await page.persistServerOffset(24 * 60 * 60 * 1000 + 1);
    expect(await sw.loadServerOffset()).toBe(400); // memory kept
    await page.persistServerOffset(-(24 * 60 * 60 * 1000));
    expect(await sw.loadServerOffset()).toBe(-(24 * 60 * 60 * 1000));
  });

  it('the latest sample of any context wins', async () => {
    const page = await context();
    await page.persistServerOffset(400);
    await page.persistServerOffset(-1250);
    vi.stubGlobal('localStorage', undefined);
    const sw = await context();
    expect(await sw.loadServerOffset()).toBe(-1250);
  });

  it('without IndexedDB, or with nothing stored, the offset is what memory has', async () => {
    vi.stubGlobal('localStorage', undefined);
    const empty = await context();
    expect(await empty.loadServerOffset()).toBe(0);
    vi.stubGlobal('indexedDB', undefined);
    const none = await context();
    none.recordServerTime('10500', 10_000, 10_200);
    await none.persistServerOffset(999);
    expect(await none.loadServerOffset()).toBe(400);
  });
});
