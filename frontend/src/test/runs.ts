/** Builders for run tests: queued `run.event` items and server `RunOut`s. */
import type { RunOut } from '../client';
import { RUN_EVENT, type RunEventPayload } from '../lib/outbox/kinds';
import type { OutboxItem } from '../lib/outbox/types';
import type { RunContext } from '../lib/runs/actions';
import { fold, projectTiming, stateToWire, timingToWire } from '../lib/runs/fold';
import { formatInstant } from '../lib/runs/instant';
import type { FoldTimer, LapType, RunEvent, RunStatus, Timing, TimerStep } from '../lib/runs/types';

/** 2026-10-24T08:00:00Z. */
export const T0 = Date.UTC(2026, 9, 24, 8, 0, 0);

export const STEPS: TimerStep[] = [
  { key: 'shower', label: 'Shower' },
  { key: 'breakfast', label: 'Breakfast' },
];

export const TOPIC = { id: 'topic-1', slug: 'morning', name: 'Morning' };

export const CTX: RunContext = { topic: TOPIC, version: 1, steps: STEPS, requires_answers: false };

/** Lap types of the `tiktok` timer (timers2.md §3.1): laps cycle "Run 1, Rest 1, Run 2". */
export const LAPS: LapType[] = [
  { key: 'run', label: 'Run' },
  { key: 'rest', label: 'Rest' },
];

/** A context for a timer with no steps and the `tiktok` lap types. */
export const LAP_CTX: RunContext = {
  topic: TOPIC,
  version: 1,
  steps: [],
  laps: LAPS,
  requires_answers: false,
};

export type ItemSpec = Omit<Partial<RunEventPayload['event']>, 'at'> & {
  id: string;
  run: string;
  at: number;
  status?: OutboxItem['status'];
  attempts?: number;
  makes_entry?: boolean;
  requires_answers?: boolean;
  created?: number;
  /** The version's lap types, as the tap knew them (`RunEventPayload.laps`). */
  laps?: LapType[] | null;
  steps?: TimerStep[] | null;
  /** A reopen or remove enqueued from an entry (`RunEventPayload.entry`). */
  entry?: RunEventPayload['entry'];
};

/** A `RunEventResult` body for event `id`, its run reduced to what the outbox checks. */
export function runEventResult(
  id: string,
  effect: 'applied' | 'void' = 'applied',
  reason: string | null = null,
) {
  return {
    event: { id, effect, reason },
    run: {
      id: 'r1',
      topic_id: TOPIC.id,
      status: 'running',
      revision: 1,
      state: {},
      events: [],
      aliases: [] as string[],
    },
    entry: null,
  };
}

/** A queued `run.event` item. `created` defaults to its `at`. */
export function runItem(
  type: RunEventPayload['event']['type'],
  spec: ItemSpec,
): OutboxItem<RunEventPayload> {
  const {
    id,
    run,
    at,
    status,
    attempts,
    makes_entry,
    requires_answers,
    created,
    laps,
    steps,
    entry,
    ...rest
  } = spec;
  const ts = new Date(created ?? at).toISOString();
  return {
    id,
    kind: RUN_EVENT,
    payload: {
      topic: TOPIC,
      run_id: run,
      version: 1,
      steps: steps === undefined ? STEPS : steps,
      ...(laps !== undefined ? { laps } : {}),
      requires_answers: requires_answers ?? false,
      makes_entry: makes_entry ?? false,
      ...(entry !== undefined ? { entry } : {}),
      event: {
        type,
        at: formatInstant(at),
        ...(type === 'start' ? { topic_id: TOPIC.id, version: 1 } : {}),
        ...rest,
      },
    },
    created_at: ts,
    updated_at: ts,
    attempts: attempts ?? 0,
    status: status ?? 'pending',
    next_attempt_at: 0,
    last_error: null,
  };
}

export const ev = (
  id: string,
  type: RunEvent['type'],
  at: number,
  extra: Partial<RunEvent> = {},
): RunEvent => ({ id, type, at, seg: null, step: null, pause_id: null, ...extra });

/** A server run folded from `events` (arrival order), with the status the server gives it. */
export function serverRun(
  id: string,
  events: RunEvent[],
  opts: {
    status?: RunStatus;
    aliases?: string[];
    revision?: number;
    topic_id?: string;
    timer?: FoldTimer;
  } = {},
): RunOut {
  const state = fold(id, opts.timer ?? { steps: STEPS }, events);
  const status = opts.status ?? state.status;
  return {
    id,
    topic_id: opts.topic_id ?? TOPIC.id,
    version: 1,
    status,
    revision: opts.revision ?? events.length,
    started_at: formatInstant(state.started_at),
    ended_at: state.ended_at === null ? null : formatInstant(state.ended_at),
    edited: false,
    events: events.map((e, i) => ({
      id: e.id,
      type: e.type,
      at: formatInstant(e.at),
      seg: e.seg,
      step: e.step,
      pause_id: e.pause_id,
      target: e.target ?? null,
      arrival: i + 1,
      effect: state.effects[e.id]?.effect ?? 'applied',
      reason: state.effects[e.id]?.reason ?? null,
      source: 'ui',
    })),
    state: { ...stateToWire(state), status },
    aliases: opts.aliases ?? [],
  };
}

/** A stopped run's entry as the client knows it: its id, timing (folded) and revision. */
export function entryOf(
  id: string,
  events: RunEvent[],
  timer: FoldTimer = { steps: STEPS },
  revision = 1,
): { id: string; timing: Timing; revision: number } {
  return { id, timing: projectTiming(fold(id, timer, events), timer), revision };
}

/** `entryOf`'s timing as a payload carries it (`RunEventPayload.entry`). */
export function entryPayload(entry: { timing: Timing; revision: number }) {
  return { timing: timingToWire(entry.timing), revision: entry.revision };
}
