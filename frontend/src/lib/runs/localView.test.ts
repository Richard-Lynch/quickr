import { describe, expect, it } from 'vitest';

import { STEPS, T0, ev, runItem, serverRun } from '../../test/runs';
import {
  localRuns,
  openPauseId,
  openRunOf,
  openRunTopics,
  optimisticEntries,
  runById,
} from './localView';
import { RUNS_POLL_MS, runsPollInterval } from './useRuns';

const S = 1000;
const start = ev('r1', 'start', T0);

describe('local run view (timers.md §8.3)', () => {
  it('a queued start makes an open run at once', () => {
    const [run] = localRuns([], [runItem('start', { id: 'r1', run: 'r1', at: T0 })]);
    expect(run).toMatchObject({ id: 'r1', topic_id: 'topic-1', status: 'running', server: null });
    expect(run?.state.open).toMatchObject({ index: 0, step: 'shower', label: 'Shower' });
    expect(run?.state.next_step).toBe('breakfast');
  });

  it('a start that doesn’t know its steps (a reminder’s, nothing cached) takes a later tap’s', () => {
    const blind = runItem('start', { id: 'r1', run: 'r1', at: T0 });
    blind.payload = { ...blind.payload, steps: null, requires_answers: null };
    // Alone, with no server run: a running run folded over no steps, with no step list.
    const [alone] = localRuns([], [blind]);
    expect(alone).toMatchObject({ id: 'r1', status: 'running', steps: null });
    expect(alone?.state.open).toMatchObject({ index: 0, kind: 'lap' });
    // A stray tap with no start of this device's makes no run.
    expect(localRuns([], [runItem('next', { id: 'n0', run: 'r9', at: T0, seg: 0 })])).toEqual([]);
    const next = runItem('next', { id: 'n1', run: 'r1', at: T0 + 60 * S, seg: 0 });
    const [run] = localRuns([], [blind, next]);
    expect(run?.steps).toEqual(STEPS);
    expect(run?.state.open).toMatchObject({ index: 1, step: 'breakfast' });
  });

  it("folds the queued taps over the server's events", () => {
    const server = serverRun('r1', [start, ev('n1', 'next', T0 + 60 * S, { seg: 0 })]);
    const items = [
      runItem('next', { id: 'n2', run: 'r1', at: T0 + 120 * S, seg: 1 }),
      runItem('pause', { id: 'p1', run: 'r1', at: T0 + 130 * S }),
    ];
    const [run] = localRuns([server], items);
    if (!run) throw new Error('no run');
    expect(run.status).toBe('paused');
    expect(run.state.segments.map((s) => s.step)).toEqual(['shower', 'breakfast']);
    expect(run.state.open).toMatchObject({ index: 2, kind: 'lap', label: 'Lap 1' });
    expect(run.events.map((e) => e.id)).toEqual(['r1', 'n1', 'n2', 'p1']);
    expect(openPauseId(run)).toBe('p1');
  });

  it("uses the server's state as is when nothing is queued", () => {
    const server = serverRun('r1', [start, ev('n1', 'next', T0 + 60 * S, { seg: 0 })]);
    const [run] = localRuns([server], []);
    expect(run?.state.segments).toHaveLength(1);
    expect(run?.steps).toBeNull();
    expect(run?.status).toBe('running');
  });

  it('leaves failed items out of the fold', () => {
    const items = [
      runItem('start', { id: 'r1', run: 'r1', at: T0 }),
      runItem('next', { id: 'n1', run: 'r1', at: T0 + S, seg: 0, status: 'failed' }),
    ];
    const [run] = localRuns([], items);
    expect(run?.state.open?.index).toBe(0);
    expect(run?.queued.map((i) => i.id)).toEqual(['r1']);
  });

  it('routes queued taps for an alias to the run it merged into', () => {
    const server = serverRun('r1', [start, ev('r2', 'start', T0 + S)], { aliases: ['r2'] });
    const items = [runItem('next', { id: 'n1', run: 'r2', at: T0 + 2 * S, seg: 0 })];
    const runs = localRuns([server], items);
    expect(runs).toHaveLength(1);
    expect(runs[0]?.state.open?.index).toBe(1);
    expect(runById(runs, 'R2')?.id).toBe('r1');
  });

  it('makes no run of queued late taps whose run is gone (the server decides them)', () => {
    expect(localRuns([], [runItem('next', { id: 'n1', run: 'r1', at: T0, seg: 0 })])).toEqual([]);
  });

  it('a queued discard closes the run', () => {
    const items = [
      runItem('start', { id: 'r1', run: 'r1', at: T0, attempts: 1 }),
      runItem('discard', { id: 'd1', run: 'r1', at: T0 + S }),
    ];
    expect(localRuns([], items)[0]?.status).toBe('discarded');
  });

  describe('stop', () => {
    const queuedStop = (
      extra: Parameters<typeof runItem>[1] extends infer S ? Partial<S> : never,
    ) => runItem('stop', { id: 's1', run: 'r1', at: T0 + 90 * S, ...extra });

    it('projects an optimistic entry, id = run id, when the stop makes one', () => {
      const server = serverRun('r1', [start, ev('n1', 'next', T0 + 60 * S, { seg: 0 })]);
      const runs = localRuns([server], [queuedStop({ makes_entry: true })]);
      expect(runs[0]?.status).toBe('stopped');
      const [entry] = optimisticEntries(runs);
      expect(entry).toMatchObject({
        id: 'r1',
        topic_id: 'topic-1',
        version: 1,
        captured_at: T0 + 90 * S,
        answers: {},
        sync_state: 'pending',
      });
      expect(entry?.timing).toMatchObject({
        started_at: T0,
        ended_at: T0 + 90 * S,
        active_ms: 90 * S,
      });
      expect(entry?.timing.segments.map((s) => s.step)).toEqual(['shower', 'breakfast']);
    });

    it('projects nothing when the stop leaves the run finishing', () => {
      const runs = localRuns(
        [serverRun('r1', [start])],
        [queuedStop({ requires_answers: true, makes_entry: false })],
      );
      expect(runs[0]?.status).toBe('finishing');
      expect(optimisticEntries(runs)).toEqual([]);
      expect(openRunTopics(runs).size).toBe(0);
    });

    it("a queued finish of a finishing run projects the entry with the finish's answers", () => {
      const server = serverRun('r1', [start, ev('s1', 'stop', T0 + 90 * S)], {
        status: 'finishing',
      });
      expect(localRuns([server], [])[0]?.status).toBe('finishing');
      const finish = runItem('finish', {
        id: 'f1',
        run: 'r1',
        at: T0 + 100 * S,
        answers: { mood: 4 },
        notes: 'ok',
        makes_entry: true,
      });
      const runs = localRuns([server], [finish]);
      expect(runs[0]?.status).toBe('stopped');
      expect(optimisticEntries(runs)[0]).toMatchObject({
        id: 'r1',
        answers: { mood: 4 },
        notes: 'ok',
        captured_at: T0 + 90 * S,
      });
    });

    it('a queued discard of a finishing run discards it', () => {
      const server = serverRun('r1', [start, ev('s1', 'stop', T0 + 90 * S)], {
        status: 'finishing',
      });
      const discard = runItem('discard', { id: 'd1', run: 'r1', at: T0 + 100 * S });
      expect(localRuns([server], [discard])[0]?.status).toBe('discarded');
    });
  });

  it('lists the topics with an open run, for dueCount', () => {
    const runs = localRuns(
      [
        serverRun('r1', [start]),
        serverRun('r9', [ev('r9', 'start', T0)], { topic_id: 'topic-9', status: 'finishing' }),
      ],
      [],
    );
    expect([...openRunTopics(runs)]).toEqual(['topic-1']);
    expect(openRunOf(runs, 'topic-1')?.id).toBe('r1');
    expect(openRunOf(runs, 'topic-9')).toBeUndefined();
  });

  it('agrees with the server when it alone taps', () => {
    // The same events, once queued and once acked, fold to the same state.
    const taps = [
      ev('r1', 'start', T0),
      ev('n1', 'next', T0 + 10 * S, { seg: 0 }),
      ev('k1', 'skip', T0 + 11 * S, { seg: 1, step: 'breakfast' }),
      ev('l1', 'lap', T0 + 20 * S, { seg: 1 }),
    ];
    const queued = taps.map((e) => runItem(e.type, { ...e, run: 'r1', at: e.at }));
    const local = localRuns([], queued)[0]?.state;
    const acked = localRuns([serverRun('r1', taps)], [])[0]?.state;
    expect(local).toEqual(acked);
    expect(STEPS).toHaveLength(2);
  });
});

describe('runsPollInterval (timers.md §7.3)', () => {
  it('polls every 10 s while a run is open or a timed page is visible', () => {
    expect(runsPollInterval([], [], false)).toBe(false);
    expect(runsPollInterval([], [], true)).toBe(RUNS_POLL_MS);
    expect(runsPollInterval([serverRun('r1', [start])], [], false)).toBe(RUNS_POLL_MS);
    expect(runsPollInterval([], [runItem('start', { id: 'r1', run: 'r1', at: T0 })], false)).toBe(
      RUNS_POLL_MS,
    );
    const finishing = serverRun('r1', [start, ev('s1', 'stop', T0 + S)], { status: 'finishing' });
    expect(runsPollInterval([finishing], [], false)).toBe(false);
  });
});

describe('review fixes', () => {
  it("folds a server run over its pinned version's steps only (M2)", () => {
    const server = serverRun('r1', [start]);
    const otherVersion = runItem('next', { id: 'n1', run: 'r1', at: T0 + S, seg: 0 });
    otherVersion.payload = { ...otherVersion.payload, version: 2, steps: [] };
    const [run] = localRuns([server], [otherVersion]);
    // No payload for version 1: the server's state stands.
    expect(run?.state.open).toMatchObject({ index: 0, step: 'shower' });
    expect(run?.steps).toBeNull();
  });

  it('a stop with answers on a required-question version makes the entry (M28)', () => {
    const stop = runItem('stop', {
      id: 's1',
      run: 'r1',
      at: T0 + 90 * S,
      requires_answers: true,
      answers: { mood: 2 },
      makes_entry: true,
    });
    const runs = localRuns([serverRun('r1', [start])], [stop]);
    expect(runs[0]?.status).toBe('stopped');
    expect(optimisticEntries(runs)[0]?.answers).toEqual({ mood: 2 });
  });

  it('keeps an acked run in the view until listRuns has it, with no optimistic entry (M1)', () => {
    const ackedStart = runItem('start', { id: 'r1', run: 'r1', at: T0 });
    const ackedStop = runItem('stop', { id: 's1', run: 'r1', at: T0 + S, makes_entry: true });
    const open = localRuns([], [], [ackedStart]);
    expect(open[0]).toMatchObject({ id: 'r1', status: 'running', queued: [] });
    const queuedNext = runItem('next', { id: 'n1', run: 'r1', at: T0 + S, seg: 0 });
    expect(localRuns([], [queuedNext], [ackedStart])[0]?.state.open?.index).toBe(1);
    const closed = localRuns([], [], [ackedStart, ackedStop]);
    expect(closed[0]?.status).toBe('stopped');
    expect(optimisticEntries(closed)).toEqual([]);
    // Once the server has it, its events count once.
    const both = localRuns([serverRun('r1', [start])], [], [ackedStart]);
    expect(both[0]?.events.map((e) => e.id)).toEqual(['r1', 'r1']);
    expect(both[0]?.state.open?.index).toBe(0);
  });

  describe('a server run whose pinned version’s steps aren’t known here (M3)', () => {
    const blind = (item: ReturnType<typeof runItem>) => {
      item.payload = { ...item.payload, steps: null, requires_answers: null };
      return item;
    };
    const server = serverRun('r1', [start, ev('n1', 'next', T0 + 60 * S, { seg: 0 })]);

    it('an offline Pause, then Resume, show over the server’s labels', () => {
      const pause = blind(runItem('pause', { id: 'p1', run: 'r1', at: T0 + 90 * S }));
      const [paused] = localRuns([server], [pause]);
      expect(paused).toMatchObject({ status: 'paused', steps: null });
      expect(paused?.state.open).toMatchObject({ index: 1, step: 'breakfast', label: 'Breakfast' });
      expect(paused?.state.paused_since).toBe(T0 + 90 * S);
      const resume = blind(
        runItem('resume', { id: 'u1', run: 'r1', at: T0 + 100 * S, pause_id: 'p1' }),
      );
      const [running] = localRuns([server], [pause, resume]);
      expect(running?.status).toBe('running');
      expect(running?.state.pauses).toEqual([{ start: T0 + 90 * S, end: T0 + 100 * S }]);
    });

    it('an offline Stop closes it; a Next waits for the server', () => {
      const next = blind(runItem('next', { id: 'n2', run: 'r1', at: T0 + 80 * S, seg: 1 }));
      const stop = blind(runItem('stop', { id: 's1', run: 'r1', at: T0 + 120 * S }));
      const [run] = localRuns([server], [next, stop]);
      expect(run?.status).toBe('stopped');
      expect(run?.state.open).toBeNull();
      expect(run?.state.ended_at).toBe(T0 + 120 * S);
      expect(run?.state.segments.map((x) => [x.label, x.active_ms])).toEqual([
        ['Shower', 60 * S],
        ['Breakfast', 60 * S],
      ]);
      expect(run?.state.effects.n2).toBeUndefined();
      expect(run?.state.effects.s1).toEqual({ effect: 'applied', reason: null });
    });

    it('a Lap opens a lap segment; a Discard discards; taps after the close are void', () => {
      const lap = blind(runItem('lap', { id: 'l1', run: 'r1', at: T0 + 70 * S, seg: 1 }));
      const [lapped] = localRuns([server], [lap]);
      expect(lapped?.state.open).toMatchObject({ index: 2, kind: 'lap', label: 'Lap 1' });
      const discard = blind(runItem('discard', { id: 'd1', run: 'r1', at: T0 + 80 * S }));
      const late = blind(runItem('pause', { id: 'p2', run: 'r1', at: T0 + 90 * S }));
      const [gone] = localRuns([server], [discard, late]);
      expect(gone?.status).toBe('discarded');
      expect(gone?.state.effects.p2).toEqual({ effect: 'void', reason: 'after_stop' });
    });

    it('a stop, pause or lap before the server’s open segment began is stale (#76)', () => {
      // The server's open segment (Breakfast) began at T0 + 60 s.
      const early = (type: 'stop' | 'pause' | 'lap', id: string) =>
        blind(
          runItem(type, { id, run: 'r1', at: T0 + 50 * S, ...(type === 'lap' ? { seg: 1 } : {}) }),
        );
      for (const [type, id] of [
        ['stop', 's0'],
        ['pause', 'p0'],
        ['lap', 'l0'],
      ] as const) {
        const [run] = localRuns([server], [early(type, id)]);
        expect(run?.status).toBe('running');
        expect(run?.state.effects[id]).toEqual({ effect: 'void', reason: 'stale' });
        expect(run?.state.segments.every((x) => x.active_ms >= 0)).toBe(true);
      }
    });

    it('orders taps by (at, id), and voids those after the stop, whatever the outbox order', () => {
      // Enqueued (created) in another order than tapped (at): stop, pause, lap, resume, pause.
      const stop = blind(
        runItem('stop', { id: 's1', run: 'r1', at: T0 + 120 * S, created: T0 + 200 * S }),
      );
      const lap = blind(
        runItem('lap', { id: 'l1', run: 'r1', at: T0 + 90 * S, seg: 1, created: T0 + 202 * S }),
      );
      const pause = blind(
        runItem('pause', { id: 'p1', run: 'r1', at: T0 + 130 * S, created: T0 + 201 * S }),
      );
      const resume = blind(
        runItem('resume', {
          id: 'u1',
          run: 'r1',
          at: T0 + 80 * S,
          pause_id: 'p0',
          created: T0 + 203 * S,
        }),
      );
      const early = blind(
        runItem('pause', { id: 'p0', run: 'r1', at: T0 + 70 * S, created: T0 + 204 * S }),
      );
      const [run] = localRuns([server], [stop, pause, lap, resume, early]);
      expect(run?.status).toBe('stopped');
      expect(run?.state.effects.p1).toEqual({ effect: 'void', reason: 'after_stop' });
      expect(run?.state.effects.l1).toEqual({ effect: 'applied', reason: null });
      expect(run?.state.effects.u1).toEqual({ effect: 'applied', reason: null });
      expect(run?.state.pauses).toEqual([{ start: T0 + 70 * S, end: T0 + 80 * S }]);
      expect(run?.state.segments.map((x) => [x.label, x.active_ms])).toEqual([
        ['Shower', 60 * S],
        ['Breakfast', 20 * S],
        ['Lap 1', 30 * S],
      ]);
    });

    it('a resume stamped before its pause began is stale: no negative pause', () => {
      const listed = serverRun('r1', [start, ev('p1', 'pause', T0 + 30 * S)]);
      const resume = blind(
        runItem('resume', { id: 'u1', run: 'r1', at: T0 + 20 * S, pause_id: 'p1' }),
      );
      const [run] = localRuns([listed], [resume]);
      expect(run?.status).toBe('paused');
      expect(run?.state.effects.u1).toEqual({ effect: 'void', reason: 'stale' });
      expect(run?.state.pauses).toEqual([]);
    });

    it('a tap the server lists already isn’t applied twice', () => {
      const listed = serverRun('r1', [start, ev('p1', 'pause', T0 + 30 * S)]);
      const pause = blind(runItem('pause', { id: 'p1', run: 'r1', at: T0 + 30 * S }));
      const resume = blind(
        runItem('resume', { id: 'u1', run: 'r1', at: T0 + 40 * S, pause_id: 'p1' }),
      );
      const [run] = localRuns([listed], [], [pause]);
      expect(run?.status).toBe('paused');
      const [resumed] = localRuns([listed], [resume], [pause]);
      expect(resumed?.status).toBe('running');
      expect(resumed?.state.pauses).toEqual([{ start: T0 + 30 * S, end: T0 + 40 * S }]);
    });
  });
});
