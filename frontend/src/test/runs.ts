/** Builders for run tests: queued `run.event` items and server `RunOut`s. */
import type { RunOut } from '../client';
import { RUN_EVENT, type RunEventPayload } from '../lib/outbox/kinds';
import type { OutboxItem } from '../lib/outbox/types';
import type { RunContext } from '../lib/runs/actions';
import { fold, stateToWire } from '../lib/runs/fold';
import { formatInstant } from '../lib/runs/instant';
import type { RunEvent, RunStatus, TimerStep } from '../lib/runs/types';

/** 2026-10-24T08:00:00Z. */
export const T0 = Date.UTC(2026, 9, 24, 8, 0, 0);

export const STEPS: TimerStep[] = [
  { key: 'shower', label: 'Shower' },
  { key: 'breakfast', label: 'Breakfast' },
];

export const TOPIC = { id: 'topic-1', slug: 'morning', name: 'Morning' };

export const CTX: RunContext = { topic: TOPIC, version: 1, steps: STEPS, requires_answers: false };

export type ItemSpec = Omit<Partial<RunEventPayload['event']>, 'at'> & {
  id: string;
  run: string;
  at: number;
  status?: OutboxItem['status'];
  attempts?: number;
  makes_entry?: boolean;
  requires_answers?: boolean;
  created?: number;
};

/** A queued `run.event` item. `created` defaults to its `at`. */
export function runItem(
  type: RunEventPayload['event']['type'],
  spec: ItemSpec,
): OutboxItem<RunEventPayload> {
  const { id, run, at, status, attempts, makes_entry, requires_answers, created, ...rest } = spec;
  const ts = new Date(created ?? at).toISOString();
  return {
    id,
    kind: RUN_EVENT,
    payload: {
      topic: TOPIC,
      run_id: run,
      version: 1,
      steps: STEPS,
      requires_answers: requires_answers ?? false,
      makes_entry: makes_entry ?? false,
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
  opts: { status?: RunStatus; aliases?: string[]; revision?: number; topic_id?: string } = {},
): RunOut {
  const state = fold(id, STEPS, events);
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
      arrival: i + 1,
      effect: state.effects[e.id]?.effect ?? 'applied',
      reason: state.effects[e.id]?.reason ?? null,
      source: 'ui',
    })),
    state: { ...stateToWire(state), status },
    aliases: opts.aliases ?? [],
  };
}
