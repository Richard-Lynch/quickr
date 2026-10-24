import { describe, expect, it } from 'vitest';

import type { RunOut } from '../../client';
import { CTX, T0, ev, serverRun } from '../../test/runs';
import { OUTBOX_KINDS, type RunEventPayload } from '../outbox/kinds';
import { createOutbox } from '../outbox/outbox';
import { memoryOutboxStore } from '../outbox/store';
import type { OutboxItem } from '../outbox/types';
import { startRun, tapRun, type RunTapDeps } from './actions';
import { parseInstant } from './instant';

function setup(server: RunOut[] = [], clock = { now: T0, offset: 0 }) {
  const outbox = createOutbox({
    kinds: OUTBOX_KINDS,
    store: memoryOutboxStore(),
    channelName: null,
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
