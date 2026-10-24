/** The §11.4 notices for void taps. */
import { describe, expect, it } from 'vitest';

import { T0, ev, runItem, serverRun } from '../../test/runs';
import type { VoidReason } from './types';
import { noticeFor } from './notices';

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
