/** Resume fixtures (active-surfaces.md §2.4, §3.3, §6.3): a stopped run with its saved entry. */
import { formatInstant } from '../lib/runs/instant';
import type { FakeRunServer } from './fakeRunServer';
import { RUN_ID, timedTopic, TOPIC_ID } from './runUi';

/** The seeded run's stop: its entry's `timing.terminal_id`. */
export const STOP_ID = '0b5e0000-0000-4000-8000-0000000000e1';

/** A run of the topic from another session: started `from` ms ago, stopped `to` ms ago. */
export function seedStopped(server: FakeRunServer, from: number, to: number): void {
  const now = Date.now();
  server.record(RUN_ID, {
    id: RUN_ID,
    type: 'start',
    at: formatInstant(now - from),
    topic_id: TOPIC_ID,
    version: 1,
  });
  server.record(RUN_ID, { id: STOP_ID, type: 'stop', at: formatInstant(now - to) });
}

/** No questions, so a stop saves the entry; no steps (a lap topic); one entry so far. */
export function lapTopic(): ReturnType<typeof timedTopic> {
  const fixture = timedTopic({ steps: [], questions: [] });
  return { ...fixture, topic: { ...fixture.topic, entry_count: 1 } };
}

/** The server's reopen events, in order. */
export const reopens = (server: FakeRunServer) =>
  server.events().filter((e) => e.type === 'reopen');

/**
 * OQ-1's Resume window, 15 minutes, written out rather than imported: a change to
 * `REOPEN_WINDOW_MS` must fail the tests that pin the spec's window.
 */
export const WINDOW_MS = 15 * 60_000;
