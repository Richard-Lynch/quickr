/** The §11.4 notices for void taps. */
import { beforeEach, describe, expect, it } from 'vitest';

import { T0, ev, runItem, serverRun } from '../../test/runs';
import type { VoidReason } from './types';
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
const reply = (reason: VoidReason | null, effect: 'applied' | 'void' = 'void') => ({
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
