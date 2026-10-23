/**
 * The generated request validators (`src/client/zod.gen.ts`) count text lengths in code
 * points, like the server, iOS and `lib/text.ts`: an emoji is one character, not two UTF-16
 * units. zod 4.6's `z.string().min/max/length` measure strings in code points, so the
 * generated `.max(5000)` is already right; these tests pin that through the real request
 * paths in case a zod upgrade or generator change ever goes back to `.length`.
 */
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ZodError } from 'zod';

import { createTopic, publishTopicVersion, updateEntry } from '../client';
import { convertDraftQuestion, newDraftQuestion } from '../lib/builder';
import { charCount } from '../lib/text';
import { recordEntry } from './entries';

const enqueue = vi.hoisted(() => vi.fn());
vi.mock('../lib/outbox/client', () => ({
  isOnline: () => false,
  outbox: { enqueue, update: vi.fn() },
}));

/** `n` characters, each one code point and two UTF-16 units. */
const emoji = (n: number) => '😀'.repeat(n);

const topic = { id: 't1', slug: 'sleep', name: 'Sleep' };
const question = { type: 'int', key: 'hours', label: 'Hours' } as const;

/** SDK options sending to a stub that answers 503; `fetch` records what was sent. */
function stubbed() {
  const fetch = vi.fn<typeof globalThis.fetch>(() =>
    Promise.resolve(new Response(null, { status: 503 })),
  );
  return { baseUrl: 'http://quickr.test', fetch };
}

/** `'invalid'` when request validation failed (the SDK returns the ZodError), else `'sent'`. */
async function outcome(call: Promise<{ error?: unknown }>): Promise<'invalid' | 'sent'> {
  const { error } = await call;
  return error instanceof ZodError ? 'invalid' : 'sent';
}

beforeEach(() => {
  enqueue.mockReset();
  enqueue.mockImplementation((kind: string, payload: unknown) =>
    Promise.resolve({ id: 'e1', kind, payload }),
  );
});

describe('recordEntry (zEntryCreate)', () => {
  it('accepts emoji notes and source at the limit', async () => {
    const body = { answers: { hours: 7 }, source: emoji(100), notes: emoji(5000) };
    expect(body.notes.length).toBe(10_000); // UTF-16 units: twice the limit
    expect(charCount(body.notes)).toBe(5000);

    await expect(recordEntry(topic, body)).resolves.toEqual({ status: 'queued', itemId: 'e1' });
    expect(enqueue).toHaveBeenCalledOnce();
  });

  it.each([
    ['notes', { notes: emoji(5001) }],
    ['source', { source: emoji(101) }],
  ])('rejects %s one character over, before queueing', async (_, extra) => {
    await expect(recordEntry(topic, { answers: { hours: 7 }, ...extra })).rejects.toThrow(ZodError);
    expect(enqueue).not.toHaveBeenCalled();
  });

  it('still rejects an empty source', async () => {
    await expect(recordEntry(topic, { answers: {}, source: '' })).rejects.toThrow(ZodError);
  });
});

describe('SDK request validation', () => {
  it('createTopic sends an emoji name, description and question at the limit', async () => {
    const opts = stubbed();
    const body = {
      name: emoji(200),
      description: emoji(5000),
      questions: [{ ...question, label: emoji(200), help_text: emoji(1000) }],
    };
    expect(await outcome(createTopic({ body, ...opts }))).toBe('sent');
    expect(opts.fetch).toHaveBeenCalledOnce();
    const sent = opts.fetch.mock.calls[0]?.[0];
    expect(sent).toBeInstanceOf(Request);
    expect(await (sent as Request).json()).toMatchObject(body);
  });

  it.each([
    ['name', { name: emoji(201) }],
    ['description', { description: emoji(5001) }],
    ['question label', { questions: [{ ...question, label: emoji(201) }] }],
  ])('createTopic rejects a %s one character over, without sending', async (_, extra) => {
    const opts = stubbed();
    const call = createTopic({ body: { name: 'Sleep', questions: [question], ...extra }, ...opts });
    expect(await outcome(call)).toBe('invalid');
    expect(opts.fetch).not.toHaveBeenCalled();
  });

  it.each([
    [2000, 'sent'],
    [2001, 'invalid'],
  ])('publishTopicVersion with a %i-emoji change note: %s', async (n, expected) => {
    const call = publishTopicVersion({
      path: { ref: 'sleep' },
      body: { questions: [question], base_version: 1, change_note: emoji(n), timer: null },
      ...stubbed(),
    });
    expect(await outcome(call)).toBe(expected);
  });

  it.each([
    [5000, 'sent'],
    [5001, 'invalid'],
  ])('updateEntry with %i-emoji notes: %s', async (n, expected) => {
    const call = updateEntry({
      path: { entry_id: '00000000-0000-4000-8000-000000000001' },
      body: { notes: emoji(n) },
      ...stubbed(),
    });
    expect(await outcome(call)).toBe(expected);
  });
});

describe('builder (generated question schemas)', () => {
  it('accepts an emoji label, help text and unit at the limit', () => {
    const d = {
      ...newDraftQuestion('int'),
      key: 'hours',
      label: emoji(200),
      help_text: emoji(1000),
      unit: emoji(32),
    };
    expect(convertDraftQuestion(d)).toMatchObject({ ok: true });
  });

  it('rejects an emoji label one character over', () => {
    const d = { ...newDraftQuestion('int'), key: 'hours', label: emoji(201) };
    expect(convertDraftQuestion(d)).toMatchObject({
      ok: false,
      issues: [{ path: ['label'] }],
    });
  });
});
