/**
 * Taps from the run surfaces: `startRun` and `tapRun` on the page's outbox, then a flush,
 * so an online tap reaches the server at once. A finish (the answers form) also waits for
 * the server's answer, like the record screen, so a rejected answer lands on its field.
 */
import { useQueryClient } from '@tanstack/react-query';
import { useMemo, useState, useSyncExternalStore } from 'react';

import { RECORD_WAIT_MS } from '../../api/entries';
import { invalidateOperations } from '../../api/queryClient';
import { runTapDeps } from '../../api/runs';
import { isOnline, kickOutbox, outbox } from '../../lib/outbox/client';
import type { RunEventPayload } from '../../lib/outbox/kinds';
import type { OutboxItem } from '../../lib/outbox/types';
import {
  RunVersionMismatch,
  startRun,
  tapRun,
  type RunContext,
  type StartResult,
  type TapBody,
  type TapExpect,
  type TapType,
} from '../../lib/runs/actions';
import { useToast } from '../ui/Toast';

/** A light haptic where the platform has one (Android Chrome; iOS ignores it). */
function buzz(): void {
  try {
    if ('vibrate' in navigator) navigator.vibrate(10);
  } catch {
    // not allowed here
  }
}

export type FinishResult =
  | { status: 'sent' }
  | { status: 'queued' }
  /** The run's topic was deleted (409 `run_deleted`): nothing will be saved. */
  | { status: 'retired' }
  /** Nothing was enqueued: the run had nothing to finish. */
  | { status: 'none' };

/**
 * After a tap on a topic's run controls (Start included), its other taps are ignored for
 * this long. The buttons change under the finger ("Next: Teeth" becomes Stop on the last
 * step, Stop becomes Start), so a double tap would otherwise be read as a second, different
 * action. Keyed by topic, not run: a Stop's run is gone by the time Start shows.
 */
export const RUN_TAP_COOLDOWN_MS = 450;

let cooldownMs = RUN_TAP_COOLDOWN_MS;
/**
 * Monotonic ms since the page loaded. Not `Date.now()`: a device clock set back would leave
 * every later tap inside the cooldown, and the controls dead, until it caught up (#188).
 */
const monotonic = () => performance.now();
let clock: () => number = monotonic;
/** When each topic's run controls were last tapped (`clock` ms), by lowercase topic id. */
const lastTap = new Map<string, number>();
/** Each cooling topic's timer that ends its cooldown, by lowercase topic id. */
const coolEnds = new Map<string, number>();

/** Who re-reads `isCooling`: told when a cooldown starts and when it ends. */
const coolListeners = new Set<() => void>();
const notifyCooling = () => {
  for (const l of coolListeners) l();
};

/**
 * Tests: another cooldown (0 turns it off), and forget earlier taps. `now` replaces the
 * clock, so a test's double tap is a fixed time apart however slow the machine is (#188);
 * after moving it, `runTapClockMoved` re-reads every cooldown, as its end timer would.
 */
export function setRunTapCooldown(ms: number, now: () => number = monotonic): void {
  cooldownMs = ms;
  clock = now;
  lastTap.clear();
  for (const t of coolEnds.values()) window.clearTimeout(t);
  coolEnds.clear();
  notifyCooling();
}

/** Tests: the clock given to `setRunTapCooldown` moved. */
export function runTapClockMoved(): void {
  notifyCooling();
}

/** How long `topicId`'s cooldown has left, in ms; 0 when it isn't cooling. */
function coolLeft(topicId: string): number {
  const last = lastTap.get(topicId.toLowerCase());
  if (last === undefined) return 0;
  const since = clock() - last;
  // A clock behind the tap (one that isn't monotonic) ends the cooldown, never extends it.
  return since >= 0 && since < cooldownMs ? cooldownMs - since : 0;
}

/** Whether `topicId`'s controls are inside a cooldown now. */
function isCooling(topicId: string): boolean {
  return coolLeft(topicId) > 0;
}

/**
 * Re-read the cooldowns when `id`'s ends. The timer runs on the clock's time: one that fires
 * a little early waits out the rest rather than leaving the controls off.
 */
function scheduleCoolEnd(id: string, after: number): void {
  window.clearTimeout(coolEnds.get(id));
  coolEnds.set(
    id,
    window.setTimeout(() => {
      coolEnds.delete(id);
      const left = coolLeft(id);
      if (left > 0) scheduleCoolEnd(id, left);
      else notifyCooling();
    }, after),
  );
}

/** Whether a tap on `topicId`'s controls now is inside its cooldown; if not, it starts one. */
function coolingDown(topicId: string): boolean {
  if (isCooling(topicId)) return true;
  const id = topicId.toLowerCase();
  lastTap.set(id, clock());
  if (cooldownMs > 0) {
    notifyCooling();
    scheduleCoolEnd(id, cooldownMs);
  }
  return false;
}

const subscribeCooling = (onChange: () => void) => {
  coolListeners.add(onChange);
  return () => {
    coolListeners.delete(onChange);
  };
};

/**
 * Whether `topicId`'s run controls are inside the tap cooldown, from whichever surface tapped
 * (a tile's Start, then the panel): the run panel shows its controls disabled meanwhile
 * (active-surfaces.md §2.2, §9).
 */
export function useRunCooldown(topicId: string): boolean {
  return useSyncExternalStore(subscribeCooling, () => isCooling(topicId));
}

export interface RunActions {
  /** A tap is being enqueued. */
  busy: boolean;
  start: (ctx: RunContext, opts?: Parameters<typeof startRun>[2]) => Promise<StartResult | null>;
  /**
   * One tap on a run's controls. `expect` is what the control showed (see `TapExpect`); a
   * tap inside the topic's cooldown, or whose target has moved, does nothing (null).
   */
  tap: (
    runId: string,
    ctx: RunContext,
    type: TapType,
    body?: TapBody,
    expect?: TapExpect,
  ) => Promise<OutboxItem<RunEventPayload> | null>;
  /**
   * Send the run's answers as `finish` (§3.6) and wait briefly for the server. Throws the
   * Problem body when it refuses them (the new item is dropped, as a rejected new entry
   * is). `fixItemId` re-sends a failed finish with new answers instead.
   */
  finish: (
    runId: string,
    ctx: RunContext,
    body: TapBody,
    opts?: { fixItemId?: string | undefined },
  ) => Promise<FinishResult>;
}

export function useRunActions(): RunActions {
  const qc = useQueryClient();
  const { toast } = useToast();
  const [busy, setBusy] = useState(false);

  return useMemo(() => {
    const deps = runTapDeps(qc);
    const mismatch = () => {
      // The run is pinned to another version than the screen knew: reload the steps.
      void invalidateOperations(qc, ['listTopicVersions']);
      toast({
        title: 'This run uses another version',
        description: 'Its steps are being reloaded. Tap again in a moment.',
        tone: 'danger',
      });
    };
    const guarded = async <T>(fn: () => Promise<T | null>): Promise<T | null> => {
      setBusy(true);
      try {
        const out = await fn();
        if (out !== null) {
          buzz();
          void kickOutbox(true);
        }
        return out;
      } catch (err) {
        if (err instanceof RunVersionMismatch) mismatch();
        else {
          console.error('[runs] tap failed', err);
          toast({ title: 'That tap wasn’t saved', description: String(err), tone: 'danger' });
        }
        return null;
      } finally {
        setBusy(false);
      }
    };

    const send = async (
      runId: string,
      ctx: RunContext,
      body: TapBody,
      fixItemId: string | undefined,
    ): Promise<FinishResult> => {
      let item: OutboxItem<RunEventPayload> | null | undefined;
      if (fixItemId) {
        const existing = (await outbox.list()).find((i) => i.id === fixItemId) as
          OutboxItem<RunEventPayload> | undefined;
        if (existing) {
          const { answers, notes } = body;
          const event = {
            ...existing.payload.event,
            answers: answers ?? null,
            notes: notes ?? null,
          };
          item = await outbox.update(existing.id, { ...existing.payload, event });
        }
      }
      item ??= await tapRun(deps, runId, ctx, 'finish', body);
      if (!item) return { status: 'none' };
      if (!isOnline()) return { status: 'queued' };
      const r = await outbox.sendNow(item.id, RECORD_WAIT_MS);
      if (r.status === 'sent') return { status: 'sent' };
      if (r.status === 'retired') return { status: 'retired' };
      if (r.status === 'failed') {
        if (!fixItemId) await outbox.discard(item.id);
        // The Problem body, for the form to put on its fields (as `recordEntry` does).
        const error: unknown =
          r.item.last_error?.body ?? new Error(r.item.last_error?.message ?? 'Request failed');
        throw error;
      }
      return { status: 'queued' };
    };

    /** As `guarded`, except that the server's refusal reaches the form (it throws). */
    const finish: RunActions['finish'] = async (runId, ctx, body, opts = {}) => {
      setBusy(true);
      try {
        return await send(runId, ctx, body, opts.fixItemId);
      } catch (err) {
        if (!(err instanceof RunVersionMismatch)) throw err;
        mismatch();
        return { status: 'none' };
      } finally {
        setBusy(false);
      }
    };

    return {
      busy,
      // The cooldown starts at the tap, before the await: Start becomes Next under the finger.
      start: (ctx, startOpts) =>
        coolingDown(ctx.topic.id)
          ? Promise.resolve(null)
          : guarded(() => startRun(deps, ctx, startOpts)),
      // A discard is confirmed in a sheet first: no double tap to guard (as on iOS).
      tap: (runId, ctx, type, body, expect) =>
        type !== 'discard' && coolingDown(ctx.topic.id)
          ? Promise.resolve(null)
          : guarded(() => tapRun(deps, runId, ctx, type, body, expect ? { expect } : {})),
      finish,
    };
  }, [qc, toast, busy]);
}
