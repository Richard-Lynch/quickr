import { beforeEach, describe, expect, it } from 'vitest';

import type { RunOut } from '../../client';
import { CTX, T0, ev, runEventResult, serverRun } from '../../test/runs';
import { OUTBOX_KINDS, type RunEventPayload } from '../outbox/kinds';
import { createOutbox } from '../outbox/outbox';
import { memoryOutboxStore } from '../outbox/store';
import type { OutboxItem } from '../outbox/types';
import { RunVersionMismatch, startRun, tapRun, type RunTapDeps } from './actions';
import { ackedItems, memoryAckedStore, setAckedStore } from './acked';
import { parseInstant } from './instant';

beforeEach(() => {
  setAckedStore(memoryAckedStore());
});

function setup(
  server: RunOut[] = [],
  clock = { now: T0, offset: 0 },
  fetch: typeof globalThis.fetch = () => Promise.reject(new Error('offline')),
) {
  const outbox = createOutbox({
    kinds: OUTBOX_KINDS,
    store: memoryOutboxStore(),
    channelName: null,
    fetch,
  });
  const deps: RunTapDeps = {
    outbox,
    serverRuns: () => server,
    now: () => clock.now,
    offset: () => clock.offset,
  };
  // In tap order: taps within one millisecond share `created_at`; their `at`s are clamped.
  const queued = async () =>
    ((await outbox.list()) as OutboxItem<RunEventPayload>[]).sort(
      (a, b) => atOf(a.payload.event) - atOf(b.payload.event),
    );
  const events = async () => (await queued()).map((i) => i.payload.event);
  return { outbox, deps, clock, queued, events };
}

const atOf = (e: { at: string }) => parseInstant(e.at);

describe('startRun', () => {
  it('enqueues a start, id = run id, stamped with the server offset', async () => {
    const { deps, queued, clock } = setup();
    clock.offset = -1500;
    const r = await startRun(deps, CTX, { id: 'R1' });
    expect(r).toEqual({ runId: 'r1', started: true });
    const [item] = await queued();
    expect(item?.id).toBe('r1');
    expect(item?.payload).toMatchObject({
      run_id: 'r1',
      topic: CTX.topic,
      steps: CTX.steps,
      makes_entry: false,
      event: { type: 'start', topic_id: 'topic-1', version: 1, at: '2026-10-24T07:59:58.500000Z' },
    });
  });

  it('never enqueues a second start: the tap routes to the open run', async () => {
    const { deps, queued } = setup();
    const first = await startRun(deps, CTX);
    expect(await startRun(deps, CTX)).toEqual({ runId: first.runId, started: false });
    expect(await queued()).toHaveLength(1);
  });

  it('two racing starts enqueue one', async () => {
    const { deps, queued } = setup();
    const [a, b] = await Promise.all([startRun(deps, CTX), startRun(deps, CTX)]);
    expect(await queued()).toHaveLength(1);
    expect(b.runId).toBe(a.runId);
  });

  it("routes to a server run of the topic (another device's)", async () => {
    const { deps, queued } = setup([serverRun('r0', [ev('r0', 'start', T0 - 5000)])]);
    expect(await startRun(deps, CTX)).toEqual({ runId: 'r0', started: false });
    expect(await queued()).toHaveLength(0);
  });

  it('a finishing run is not open: a new start is allowed', async () => {
    const finishing = serverRun('r0', [ev('r0', 'start', T0 - 5000), ev('s0', 'stop', T0 - 1000)], {
      status: 'finishing',
    });
    const { deps } = setup([finishing]);
    expect((await startRun(deps, CTX)).started).toBe(true);
  });
});

describe('tapRun', () => {
  it('fills seg, step and pause_id from the local view', async () => {
    const { deps, events, queued, clock } = setup();
    const { runId } = await startRun(deps, CTX);
    clock.now += 1000;
    await tapRun(deps, runId, CTX, 'next');
    await tapRun(deps, runId, CTX, 'skip');
    await tapRun(deps, runId, CTX, 'pause');
    await tapRun(deps, runId, CTX, 'resume');
    await tapRun(deps, runId, CTX, 'lap');
    const [, next, skip, pause, resume, lap] = await events();
    expect(next).toMatchObject({ type: 'next', seg: 0 });
    // On "breakfast" now: skipping it relabels the open segment (no seg change).
    expect(skip).toMatchObject({ type: 'skip', seg: 1, step: 'breakfast' });
    expect(pause?.type).toBe('pause');
    const pauseItem = (await queued())[3];
    expect(resume).toMatchObject({ type: 'resume', pause_id: pauseItem?.id });
    expect(lap).toMatchObject({ type: 'lap', seg: 1 });
  });

  it("clamps each tap to just after the run's latest at, even when the offset jumps back", async () => {
    const { deps, events, clock } = setup();
    const { runId } = await startRun(deps, CTX);
    // No time passes, then the offset jumps 10 s back.
    await tapRun(deps, runId, CTX, 'next');
    clock.offset = -10_000;
    await tapRun(deps, runId, CTX, 'lap');
    const ats = (await events()).map(atOf);
    expect(ats).toEqual([T0, T0 + 1, T0 + 2]);
  });

  it("clamps after the server's events too", async () => {
    const server = serverRun('r1', [
      ev('r1', 'start', T0),
      ev('n1', 'next', T0 + 5000, { seg: 0 }),
    ]);
    const { deps, events } = setup([server]);
    await tapRun(deps, 'r1', CTX, 'lap');
    expect((await events()).map(atOf)).toEqual([T0 + 5001]);
    expect((await events())[0]).toMatchObject({ seg: 1 });
  });

  it('returns null with nothing to target', async () => {
    const { deps, queued } = setup();
    expect(await tapRun(deps, 'nope', CTX, 'next')).toBeNull();
    const { runId } = await startRun(deps, CTX);
    expect(await tapRun(deps, runId, CTX, 'resume')).toBeNull(); // not paused
    expect(await tapRun(deps, runId, CTX, 'finish')).toBeNull(); // not stopped
    expect(await queued()).toHaveLength(1);
  });

  it('a finish of a run no longer in the view still goes to the run id (§3.6)', async () => {
    // A stopped run drops out of listRuns; its answers can still come from the form.
    const { deps, queued } = setup();
    const item = await tapRun(deps, 'R9', CTX, 'finish', { answers: { mood: 3 }, notes: 'ok' });
    expect(item?.payload).toMatchObject({
      run_id: 'r9',
      makes_entry: false,
      event: { type: 'finish', answers: { mood: 3 }, notes: 'ok' },
    });
    expect(await queued()).toHaveLength(1);
    // Other taps of an unknown run still do nothing.
    expect(await tapRun(deps, 'R9', CTX, 'stop')).toBeNull();
    expect(await queued()).toHaveLength(1);
  });

  it('a context for another version throws RunVersionMismatch', async () => {
    const { deps } = setup([serverRun('r1', [ev('r1', 'start', T0)])]);
    const err: unknown = await tapRun(deps, 'r1', { ...CTX, version: 2 }, 'lap').catch(
      (e: unknown) => e,
    );
    expect(err).toBeInstanceOf(RunVersionMismatch);
    expect(err).toMatchObject({ runId: 'r1', runVersion: 1 });
  });

  it('a stop makes the entry unless a required question is unanswered', async () => {
    const { deps, queued } = setup();
    const { runId } = await startRun(deps, CTX);
    await tapRun(deps, runId, CTX, 'stop');
    expect((await queued())[1]?.payload.makes_entry).toBe(true);

    const required = { ...CTX, requires_answers: true };
    const b = setup();
    const r = await startRun(b.deps, required);
    await tapRun(b.deps, r.runId, required, 'stop');
    const stop = (await b.queued())[1];
    expect(stop?.payload.makes_entry).toBe(false);
    // The run is finishing locally: the form's finish makes the entry.
    await tapRun(b.deps, r.runId, required, 'finish', { answers: { mood: 3 }, notes: 'n' });
    expect((await b.queued())[2]?.payload).toMatchObject({
      makes_entry: true,
      event: { type: 'finish', answers: { mood: 3 }, notes: 'n' },
    });
  });

  it('a discard of a run the server never saw leaves nothing queued (K6)', async () => {
    const { deps, queued } = setup();
    const { runId } = await startRun(deps, CTX);
    await tapRun(deps, runId, CTX, 'next');
    await tapRun(deps, runId, CTX, 'discard');
    expect(await queued()).toEqual([]);
  });
});

describe('review fixes', () => {
  it('stamps each tap when it was made, even behind a hanging send (H1)', async () => {
    let release: (r: Response) => void = () => undefined;
    const hanging = new Promise<Response>((r) => {
      release = r;
    });
    const { deps, outbox, clock, events } = setup([], { now: T0, offset: 0 }, () => hanging);
    const { runId } = await startRun(deps, CTX);
    const flushing = outbox.flush();
    clock.now = T0 + 1000;
    const lap1 = tapRun(deps, runId, CTX, 'next');
    clock.now = T0 + 2000;
    const lap2 = tapRun(deps, runId, CTX, 'lap');
    clock.now = T0 + 15_000;
    await Promise.all([lap1, lap2]);
    expect((await events()).map(atOf)).toEqual([T0, T0 + 1000, T0 + 2000]);
    release(new Response('{}', { status: 503 }));
    await flushing;
  });

  it('clamps after failed items of the run too (they may be retried)', async () => {
    const json = (status: number, body: unknown) =>
      new Response(JSON.stringify(body), {
        status,
        headers: { 'Content-Type': 'application/json' },
      });
    const respond = (_: RequestInfo | URL, init?: RequestInit) => {
      const body = JSON.parse(init?.body as string) as { id: string; type: string };
      return Promise.resolve(
        body.type === 'pause'
          ? json(422, { code: 'invalid_request', detail: 'no', errors: [] })
          : json(200, runEventResult(body.id)),
      );
    };
    const { deps, outbox, queued } = setup([], { now: T0, offset: 0 }, respond);
    deps.acked = ackedItems; // the start, once acked
    const { runId } = await startRun(deps, CTX);
    await tapRun(deps, runId, CTX, 'pause');
    await outbox.flush();
    expect((await queued()).map((i) => [i.payload.event.type, i.status])).toEqual([
      ['pause', 'failed'],
    ]);
    // Same device time: after the start (T0) and the failed pause (T0 + 1).
    const lap = await tapRun(deps, runId, CTX, 'lap');
    expect(lap && atOf(lap.payload.event)).toBe(T0 + 2);
  });

  it("a finish of a stopped run doesn't make the entry; of a finishing one it does", async () => {
    const stopped = serverRun('r1', [ev('r1', 'start', T0), ev('s1', 'stop', T0 + 5000)], {
      status: 'stopped',
    });
    const a = setup([stopped]);
    const onStopped = await tapRun(a.deps, 'r1', CTX, 'finish', { answers: { mood: 1 } });
    expect(onStopped?.payload.makes_entry).toBe(false);
    const finishing = { ...stopped, status: 'finishing' as const };
    const b = setup([finishing]);
    const onFinishing = await tapRun(b.deps, 'r1', CTX, 'finish', { answers: { mood: 1 } });
    expect(onFinishing?.payload.makes_entry).toBe(true);
  });

  it('a finish carries its run’s aliases, so it waits for a stop queued under one (M2)', async () => {
    const finishing = serverRun('r9', [ev('r9', 'start', T0), ev('s9', 'stop', T0 + 5000)], {
      status: 'finishing',
      aliases: ['r1'],
    });
    const { deps } = setup([finishing]);
    const finish = await tapRun(deps, 'r9', CTX, 'finish', { answers: { mood: 1 } });
    expect(finish?.payload).toMatchObject({ run_id: 'r9', run_aliases: ['r1'] });
  });

  it('a stop with answers makes the entry even with a required question', async () => {
    const required = { ...CTX, requires_answers: true };
    const { deps } = setup();
    const { runId } = await startRun(deps, required);
    const stop = await tapRun(deps, runId, required, 'stop', { answers: { mood: 2 } });
    expect(stop?.payload).toMatchObject({ makes_entry: true, event: { answers: { mood: 2 } } });
  });

  it('refuses a context for another version than the run is pinned to (M2)', async () => {
    const { deps } = setup([serverRun('r1', [ev('r1', 'start', T0)])]);
    await expect(tapRun(deps, 'r1', { ...CTX, version: 2 }, 'lap')).rejects.toThrow(/version 1/);
  });

  it('looks once more after a listRuns fetch when the run is missing (M1)', async () => {
    const server: RunOut[] = [];
    const { deps } = setup(server);
    let fetched = 0;
    deps.refresh = () => {
      fetched += 1;
      server.push(serverRun('r1', [ev('r1', 'start', T0)]));
      return Promise.resolve();
    };
    const lap = await tapRun(deps, 'r1', CTX, 'lap');
    expect(fetched).toBe(1);
    expect(lap?.payload.event).toMatchObject({ type: 'lap', seg: 0 });
  });

  it('a run only the acked record knows is still there: no second start (M1)', async () => {
    const { deps, queued } = setup();
    const { runId } = await startRun(deps, CTX);
    const [start] = await queued();
    if (!start) throw new Error('no start');
    // Acked: gone from the queue, not in listRuns yet.
    await deps.outbox.discard(start.id);
    deps.acked = () => Promise.resolve([start]);
    expect(await startRun(deps, CTX)).toEqual({ runId, started: false });
  });
});

describe('a reminder’s Start (timers.md §10.2)', () => {
  /** A Start with nothing cached: the version's steps and questions are unknown. */
  const BLIND = { ...CTX, steps: null, requires_answers: null };

  it('a page Start after a reminder Start that knew no steps enqueues nothing', async () => {
    const { deps, queued } = setup();
    await startRun(deps, BLIND, { id: 'slot-1', reminder: true });
    expect(await startRun(deps, CTX)).toEqual({ runId: 'slot-1', started: false });
    expect((await queued()).map((i) => i.id)).toEqual(['slot-1']);
  });

  it('a run started with no steps can be stopped offline', async () => {
    const { deps, events } = setup();
    await startRun(deps, BLIND, { id: 'slot-1', reminder: true });
    expect(await tapRun(deps, 'slot-1', CTX, 'stop')).not.toBeNull();
    expect((await events()).map((e) => e.type)).toEqual(['start', 'stop']);
  });

  it('a pending stop closes the run: the next slot’s Start is a new run', async () => {
    const { deps, clock, queued } = setup();
    await startRun(deps, BLIND, { id: 'slot-1', reminder: true });
    clock.now += 60_000;
    await tapRun(deps, 'slot-1', CTX, 'stop'); // in the app, offline
    clock.now += 60_000;
    expect(await startRun(deps, BLIND, { id: 'slot-2', reminder: true })).toEqual({
      runId: 'slot-2',
      started: true,
    });
    expect(
      (await queued()).filter((i) => i.payload.event.type === 'start').map((i) => i.id),
    ).toEqual(['slot-1', 'slot-2']);
  });

  it('a pending discard closes it too', async () => {
    const { deps, outbox, clock } = setup();
    await startRun(deps, BLIND, { id: 'slot-1', reminder: true });
    await outbox.flush({ force: true }); // attempted (offline): K6 no longer drops it
    clock.now += 60_000;
    expect((await tapRun(deps, 'slot-1', CTX, 'discard'))?.payload.event.type).toBe('discard');
    expect((await startRun(deps, BLIND, { id: 'slot-2', reminder: true })).started).toBe(true);
  });

  it('a failed start doesn’t block a new Start, but is never replaced', async () => {
    const refuse = () =>
      Promise.resolve(
        new Response(JSON.stringify({ code: 'topic_archived', detail: 'archived', errors: [] }), {
          status: 409,
          headers: { 'Content-Type': 'application/json' },
        }),
      );
    const { deps, outbox, clock, queued } = setup([], { now: T0, offset: 0 }, refuse);
    await startRun(deps, BLIND, { id: 'slot-1', reminder: true });
    await outbox.flush({ force: true });
    const [failed] = await queued();
    expect(failed?.status).toBe('failed');
    clock.now += 60_000;
    expect((await startRun(deps, BLIND, { id: 'slot-1', reminder: true })).started).toBe(false);
    expect((await queued())[0]).toEqual(failed);
    expect((await startRun(deps, BLIND, { id: 'slot-2', reminder: true })).started).toBe(true);
  });
});
