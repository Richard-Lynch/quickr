/** The §11.4 notices for void taps. */
import { beforeEach, describe, expect, it } from 'vitest';

import { T0, ev, runItem, serverRun } from '../../test/runs';
import type { RunEventResult } from '../../client';
import {
  dismissRunNotice,
  getRunNotices,
  loadRunNotices,
  memoryNoticeStore,
  noticeFor,
  pushRunNotice,
  setNoticeStore,
  subscribeNoticeArrivals,
} from './notices';

const run = serverRun('r1', [ev('r1', 'start', T0), ev('x', 'stop', T0 + 300_000)]);
const reply = (reason: RunEventResult['event']['reason'], effect: 'applied' | 'void' = 'void') => ({
  event: { id: 'n1', effect, reason },
  run,
});
const tap = (type: 'next' | 'lap' | 'stop') =>
  runItem(type, { id: 'n1', run: 'r1', at: T0 + 400_000, seg: 0 });

describe('noticeFor', () => {
  it('after_stop names the stop time and the tap', () => {
    const time = new Date(T0 + 300_000).toLocaleTimeString([], {
      hour: 'numeric',
      minute: '2-digit',
    });
    expect(noticeFor(tap('lap'), reply('after_stop'))).toEqual({
      id: 'n1',
      text: `Morning was already stopped at ${time}, so your Lap wasn’t added.`,
    });
  });

  it.each([
    ['run_edited', 'Morning’s times were edited, so your Next wasn’t added.'],
    ['entry_deleted', 'Morning’s run was deleted.'],
    ['already_closed', 'Morning was already stopped.'],
  ] as const)('%s', (reason, text) => {
    expect(noticeFor(tap('next'), reply(reason))?.text).toBe(text);
  });

  it.each(['stale', 'merged', 'already_paused', 'not_paused', 'no_step'] as const)(
    '%s is silent',
    (reason) => {
      expect(noticeFor(tap('next'), reply(reason))).toBeNull();
    },
  );

  it('an applied tap says nothing', () => {
    expect(noticeFor(tap('next'), reply(null, 'applied'))).toBeNull();
  });
});

describe('noticeFor: reopen and remove (timers2.md §9.3)', () => {
  const S = 1000;
  const start = ev('r1', 'start', T0);
  const stop = ev('s1', 'stop', T0 + 300 * S);
  const reopenEv = ev('o1', 'reopen', T0 + 400 * S, { target: 's1' });
  const reopen = runItem('reopen', { id: 'o1', run: 'r1', at: T0 + 400 * S, target: 's1' });
  const remove = runItem('remove', { id: 'x1', run: 'r1', at: T0 + 400 * S, target: 'p1' });
  const voidOf = (
    item: ReturnType<typeof runItem>,
    reason: RunEventResult['event']['reason'],
    r = run,
  ) => ({ event: { id: item.id, effect: 'void' as const, reason }, run: r });
  const mine = (...ids: string[]) => ({ mine: (id: string) => ids.includes(id) });

  it("reverted: shown when another device's discard undid this device's resume", () => {
    const reverted = serverRun('r1', [start, stop, reopenEv, ev('d9', 'discard', T0 + 500 * S)], {
      status: 'stopped',
    });
    expect(noticeFor(reopen, voidOf(reopen, 'reverted', reverted))).toEqual({
      id: 'o1',
      text: 'Morning’s resume was undone by a discard elsewhere.',
    });
    // The discard was this device's own (an Undo resume): nothing to say.
    expect(noticeFor(reopen, voidOf(reopen, 'reverted', reverted), mine('o1', 'd9'))).toBeNull();
  });

  it('deleted is silent (the removed tap was deleted on purpose)', () => {
    expect(noticeFor(tap('lap'), reply('deleted'))).toBeNull();
  });

  it('not_stopped: silent on a double tap (this device reopened it), else said', () => {
    const open = serverRun('r1', [
      start,
      stop,
      ev('o0', 'reopen', T0 + 350 * S, { target: 's1' }),
      reopenEv,
    ]);
    expect(noticeFor(reopen, voidOf(reopen, 'not_stopped', open), mine('o0', 'o1'))).toBeNull();
    // Reopened elsewhere first, or discarded: the user should know.
    expect(noticeFor(reopen, voidOf(reopen, 'not_stopped', open), mine('o1'))?.text).toBe(
      'Morning isn’t stopped, so there was nothing to resume.',
    );
    const discarded = serverRun('r1', [start, ev('d1', 'discard', T0 + 300 * S), reopenEv], {
      status: 'discarded',
    });
    expect(noticeFor(reopen, voidOf(reopen, 'not_stopped', discarded))?.text).toBe(
      'Morning isn’t stopped, so there was nothing to resume.',
    );
  });

  it('no_target names what could not be done', () => {
    expect(noticeFor(reopen, voidOf(reopen, 'no_target'))?.text).toBe(
      'Couldn’t resume: Morning’s run changed.',
    );
    expect(noticeFor(remove, voidOf(remove, 'no_target'))?.text).toBe(
      'Couldn’t remove that: Morning’s run changed.',
    );
  });
});

describe('the notices store', () => {
  let store = memoryNoticeStore();
  beforeEach(() => {
    store = memoryNoticeStore();
    setNoticeStore(store);
  });

  it('keeps a notice in storage until it is dismissed', async () => {
    pushRunNotice({ id: 'n1', text: 'one' });
    pushRunNotice({ id: 'n1', text: 'one' });
    expect(getRunNotices()).toHaveLength(1);
    expect(await store.all()).toEqual([{ id: 'n1', text: 'one' }]);
    dismissRunNotice('n1');
    expect(getRunNotices()).toEqual([]);
    await Promise.resolve();
    expect(await store.all()).toEqual([]);
  });

  it('loads stored notices for the sheet without announcing them again', async () => {
    await store.put({ id: 'n2', text: 'from before' });
    const heard: string[] = [];
    const off = subscribeNoticeArrivals((n) => heard.push(n.id));
    await loadRunNotices();
    pushRunNotice({ id: 'n3', text: 'new' });
    off();
    expect(getRunNotices().map((n) => n.id)).toEqual(['n2', 'n3']);
    expect(heard).toEqual(['n3']);
  });
});
