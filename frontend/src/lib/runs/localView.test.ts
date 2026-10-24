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
