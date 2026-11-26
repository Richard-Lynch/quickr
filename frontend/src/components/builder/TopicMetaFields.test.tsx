/**
 * The Appearance card of the new-topic form and topic settings (appearance.md §7): swatches, the
 * curated emoji grid plus free input, the tags editor, the create body, and the settings PATCH
 * (only the changed fields, with `expected_revision`; server 422 paths on the right field).
 */
import { zodResolver } from '@hookform/resolvers/zod';
import { QueryClient, QueryClientProvider, useQuery } from '@tanstack/react-query';
import { act, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { useEffect, useState } from 'react';
import { FormProvider, useForm } from 'react-hook-form';
import { createMemoryRouter, Outlet, RouterProvider } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import type { TopicDetail } from '../../client';
import { getTopicOptions } from '../../client/@tanstack/react-query.gen';
import { client } from '../../client/client.gen';
import { checkIcon, type Appearance } from '../../lib/appearance';
import {
  appearanceDraftOf,
  emptyTopicDraft,
  makeTopicDraftAppearanceSchema,
  type TopicDraft,
} from '../../lib/builder';
import type { TopicCreateBody } from '../../lib/topicAppearanceSeam';
import { emptyScheduleDraft } from '../../lib/schedule';
import { SettingsPage } from '../../pages/topic/SettingsPage';
import { ToastProvider } from '../ui/Toast';
import { CURATED_EMOJI } from './AppearanceFields';
import { TopicMetaFields } from './TopicMetaFields';

const appearance: Appearance = {
  color: 'red',
  icon: { kind: 'emoji', value: '🏃' },
  tags: ['sport', 'morning'],
};
const topic = {
  id: '6f1c0000-0000-4000-8000-000000000001',
  slug: 'gym',
  name: 'Gym',
  description: '',
  status: 'active',
  current_version: 1,
  revision: 7,
  question_count: 0,
  entry_count: 0,
  last_captured_at: null,
  created_at: '2026-10-01T00:00:00Z',
  updated_at: '2026-10-01T00:00:00Z',
  archived_at: null,
  schedule: null,
  schedule_updated_at: null,
  due: null,
  timer: null,
  questions: [],
  appearance,
} satisfies TopicDetail;

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

function withProviders(ui: React.ReactNode) {
  return (
    <QueryClientProvider
      client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}
    >
      <ToastProvider>{ui}</ToastProvider>
    </QueryClientProvider>
  );
}

/** The new-topic fields in a form validated by the create schema; `submitted` gets the body. */
function NewTopicForm({ onValid }: { onValid: (body: TopicCreateBody) => void }) {
  const form = useForm<TopicDraft, unknown, TopicCreateBody>({
    resolver: zodResolver(makeTopicDraftAppearanceSchema()),
    defaultValues: {
      ...emptyTopicDraft(),
      schedule: emptyScheduleDraft('UTC'),
      appearance: appearanceDraftOf(null),
    },
  });
  return (
    <FormProvider {...form}>
      <form noValidate onSubmit={(e) => void form.handleSubmit(onValid)(e)}>
        <TopicMetaFields />
        <button type="submit">Create</button>
      </form>
    </FormProvider>
  );
}

function renderNewTopic() {
  const onValid = vi.fn<(body: TopicCreateBody) => void>();
  render(withProviders(<NewTopicForm onValid={onValid} />));
  return { user: userEvent.setup(), onValid };
}

const tagInput = () => screen.getByRole('textbox', { name: /^Tags/ });
const emojiInput = () => screen.getByRole('textbox', { name: 'Type an emoji' });
const chips = () =>
  within(screen.getByRole('list', { name: 'Current tags' }))
    .getAllByRole('listitem')
    .map((li) => li.textContent);

describe('the curated emoji grid', () => {
  it('has the 24 emoji of appearance.md §7, each already in its stored form', () => {
    expect(CURATED_EMOJI).toHaveLength(24);
    expect(new Set(CURATED_EMOJI).size).toBe(24);
    for (const e of CURATED_EMOJI) expect(checkIcon(e)).toEqual({ ok: true, value: e });
  });
});

describe('TopicMetaFields appearance (new topic)', () => {
  it('offers None plus the twelve colours as one radio group, None chosen', () => {
    renderNewTopic();
    const group = screen.getByRole('radiogroup', { name: 'Colour' });
    const radios = within(group).getAllByRole('radio');
    expect(radios.map((r) => r.getAttribute('aria-label'))).toEqual([
      'None',
      'Red',
      'Orange',
      'Amber',
      'Yellow',
      'Lime',
      'Green',
      'Teal',
      'Cyan',
      'Blue',
      'Indigo',
      'Violet',
      'Pink',
    ]);
    expect(within(group).getByRole('radio', { name: 'None' })).toBeChecked();
  });

  it('sends the picked colour, emoji and tags in the create body', async () => {
    const { user, onValid } = renderNewTopic();
    await user.type(screen.getByLabelText('Name'), 'Gym');
    await user.click(screen.getByRole('radio', { name: 'Teal' }));
    await user.click(screen.getByRole('button', { name: '🏋️' }));
    expect(screen.getByRole('button', { name: '🏋️' })).toHaveAttribute('aria-pressed', 'true');
    expect(emojiInput()).toHaveValue('🏋️');
    await user.type(tagInput(), 'sport{Enter}early  morning,');
    expect(chips()).toEqual(['sport', 'early morning']);
    await user.click(screen.getByRole('button', { name: 'Create' }));
    await waitFor(() => expect(onValid).toHaveBeenCalledTimes(1));
    expect(onValid.mock.calls[0]?.[0]).toMatchObject({
      name: 'Gym',
      appearance: {
        color: 'teal',
        icon: { kind: 'emoji', value: '\u{1F3CB}\u{FE0F}' },
        tags: ['sport', 'early morning'],
      },
    });
  });

  it('sends no appearance for a topic left at the defaults', async () => {
    const { user, onValid } = renderNewTopic();
    await user.type(screen.getByLabelText('Name'), 'Plain');
    await user.click(screen.getByRole('button', { name: 'Create' }));
    await waitFor(() => expect(onValid).toHaveBeenCalledTimes(1));
    expect(onValid.mock.calls[0]?.[0]).not.toHaveProperty('appearance');
  });

  it('stores a typed text-presentation emoji with U+FE0F', async () => {
    const { user, onValid } = renderNewTopic();
    await user.type(screen.getByLabelText('Name'), 'Smile');
    await user.type(emojiInput(), '\u{263A}');
    await user.click(screen.getByRole('button', { name: 'Create' }));
    await waitFor(() => expect(onValid).toHaveBeenCalledTimes(1));
    expect(onValid.mock.calls[0]?.[0]?.appearance?.icon).toEqual({
      kind: 'emoji',
      value: '\u{263A}\u{FE0F}',
    });
  });

  it('refuses text in the emoji field on submit, under the field', async () => {
    const { user, onValid } = renderNewTopic();
    await user.type(screen.getByLabelText('Name'), 'Gym');
    await user.type(emojiInput(), 'ab');
    await user.click(screen.getByRole('button', { name: 'Create' }));
    expect(await screen.findByText('Enter a single emoji')).toBeInTheDocument();
    expect(emojiInput()).toHaveAttribute('aria-invalid', 'true');
    expect(onValid).not.toHaveBeenCalled();
  });

  it('toggles a grid emoji off, and clears a typed one', async () => {
    const { user } = renderNewTopic();
    const run = screen.getByRole('button', { name: '🏃' });
    await user.click(run);
    await user.click(run);
    expect(emojiInput()).toHaveValue('');
    await user.type(emojiInput(), '🎯');
    await user.click(screen.getByRole('button', { name: 'Remove emoji' }));
    expect(emojiInput()).toHaveValue('');
  });

  it('shows a duplicate tag inline and keeps the text, then removes a chip with its ✕', async () => {
    const { user } = renderNewTopic();
    await user.type(tagInput(), 'Gym{Enter}gym{Enter}');
    expect(screen.getByText('“gym” is already a tag')).toBeInTheDocument();
    expect(tagInput()).toHaveValue('gym');
    expect(chips()).toEqual(['Gym']);
    await user.click(screen.getByRole('button', { name: 'Remove tag Gym' }));
    expect(screen.queryByRole('list', { name: 'Current tags' })).toBeNull();
  });

  it('blocks Create while the tag input holds a tag it refused', async () => {
    const { user, onValid } = renderNewTopic();
    await user.type(screen.getByLabelText('Name'), 'Gym');
    await user.type(tagInput(), 'x'.repeat(30));
    await user.click(screen.getByRole('button', { name: 'Create' }));
    expect(await screen.findByText('At most 24 characters')).toBeInTheDocument();
    expect(onValid).not.toHaveBeenCalled();
    await user.clear(tagInput());
    await user.click(screen.getByRole('button', { name: 'Create' }));
    await waitFor(() => expect(onValid).toHaveBeenCalledTimes(1));
  });

  it('adds the typed tag when the field loses focus', async () => {
    const { user, onValid } = renderNewTopic();
    await user.type(screen.getByLabelText('Name'), 'Gym');
    await user.type(tagInput(), 'legs');
    await user.click(screen.getByRole('button', { name: 'Create' }));
    await waitFor(() => expect(onValid).toHaveBeenCalledTimes(1));
    expect(onValid.mock.calls[0]?.[0]?.appearance?.tags).toEqual(['legs']);
  });

  it('adds the complete parts of a pasted list and keeps the rest', async () => {
    const { user } = renderNewTopic();
    await user.click(tagInput());
    await user.paste('a, b, A, c');
    expect(chips()).toEqual(['a', 'b']);
    expect(tagInput()).toHaveValue(' A, c');
  });
});

describe('SettingsPage appearance PATCH', () => {
  interface Sent {
    method: string;
    path: string;
    body: unknown;
  }
  /** PATCH answers with `reply(body)`; everything else 404s. */
  function stubServer(reply: (body: Record<string, unknown>) => Response) {
    const sent: Sent[] = [];
    vi.stubGlobal(
      'fetch',
      vi.fn(async (input: Request) => {
        const path = new URL(input.url).pathname;
        const text = await input.text();
        const body = text ? (JSON.parse(text) as Record<string, unknown>) : {};
        sent.push({ method: input.method, path, body });
        if (input.method === 'PATCH') return reply(body);
        return json(404, { code: 'not_found', detail: 'not found', errors: [] });
      }),
    );
    return () => sent.filter((r) => r.method === 'PATCH');
  }

  /** `refetch.set` stands in for a refetch that brings a newer topic (changed on another device). */
  const refetch: { set: (t: TopicDetail) => void } = { set: () => undefined };
  function Layout() {
    const [current, set] = useState<TopicDetail>(topic);
    useEffect(() => {
      refetch.set = set;
    }, []);
    return <Outlet context={{ topic: current }} />;
  }

  function renderSettings() {
    const router = createMemoryRouter(
      [
        {
          path: '/t/:ref',
          element: <Layout />,
          children: [{ path: 'settings', element: <SettingsPage /> }],
        },
      ],
      { initialEntries: ['/t/gym/settings'] },
    );
    render(withProviders(<RouterProvider router={router} />));
    return userEvent.setup();
  }

  beforeEach(() => {
    client.setConfig({ baseUrl: 'http://quickr.test' });
  });

  afterEach(() => {
    client.setConfig({ baseUrl: '' });
    vi.unstubAllGlobals();
  });

  it('starts from the topic’s appearance', async () => {
    stubServer(() => json(500, {}));
    renderSettings();
    expect(await screen.findByRole('radio', { name: 'Red' })).toBeChecked();
    expect(emojiInput()).toHaveValue('🏃');
    expect(chips()).toEqual(['sport', 'morning']);
  });

  it('sends only the changed appearance fields, with expected_revision', async () => {
    const patches = stubServer((body) =>
      json(200, {
        ...topic,
        revision: 8,
        appearance: { ...appearance, ...(body.appearance as object) },
      }),
    );
    const user = renderSettings();
    await user.click(await screen.findByRole('radio', { name: 'Blue' }));
    await user.click(screen.getByRole('button', { name: 'Remove tag morning' }));
    await user.click(screen.getByRole('button', { name: 'Save details' }));
    await waitFor(() => expect(patches()).toHaveLength(1));
    expect(patches()[0]).toEqual({
      method: 'PATCH',
      path: '/api/v1/topics/gym',
      body: { appearance: { color: 'blue', tags: ['sport'] }, expected_revision: 7 },
    });
  });

  it('clears the emoji with icon: null', async () => {
    const patches = stubServer(() => json(200, { ...topic, revision: 8 }));
    const user = renderSettings();
    await user.click(await screen.findByRole('button', { name: 'Remove emoji' }));
    await user.click(screen.getByRole('button', { name: 'Save details' }));
    await waitFor(() => expect(patches()).toHaveLength(1));
    expect(patches()[0]?.body).toEqual({ appearance: { icon: null }, expected_revision: 7 });
  });

  it('takes a newer topic into a clean form', async () => {
    stubServer(() => json(500, {}));
    renderSettings();
    expect(await screen.findByRole('radio', { name: 'Red' })).toBeChecked();
    act(() =>
      refetch.set({ ...topic, revision: 8, appearance: { ...appearance, color: 'green' } }),
    );
    await waitFor(() => expect(screen.getByRole('radio', { name: 'Green' })).toBeChecked());
  });

  it('keeps a dirty form’s base: only its own edits, with the revision it started from', async () => {
    const patches = stubServer(() =>
      json(409, { code: 'stale_revision', detail: 'Changed', errors: [] }),
    );
    const user = renderSettings();
    await user.click(await screen.findByRole('radio', { name: 'Blue' }));
    act(() =>
      refetch.set({
        ...topic,
        revision: 8,
        name: 'Lifting',
        appearance: { ...appearance, tags: [] },
      }),
    );
    expect(screen.getByRole('radio', { name: 'Blue' })).toBeChecked();
    await user.click(screen.getByRole('button', { name: 'Save details' }));
    await waitFor(() => expect(patches()).toHaveLength(1));
    expect(patches()[0]?.body).toEqual({ appearance: { color: 'blue' }, expected_revision: 7 });
    expect(await screen.findByText('Changed')).toBeInTheDocument();
  });

  it('puts the server’s 422 paths on the matching field', async () => {
    stubServer(() =>
      json(422, {
        code: 'invalid_request',
        detail: 'Invalid request',
        errors: [
          { loc: ['body', 'appearance', 'tags', 1], message: 'Value error, tag too long' },
          { loc: ['body', 'appearance', 'icon', 'value'], message: 'Value error, not an emoji' },
        ],
      }),
    );
    const user = renderSettings();
    await user.type(tagInput(), 'evening{Enter}');
    await user.click(screen.getByRole('button', { name: 'Save details' }));
    expect(await screen.findByText('Tag too long')).toBeInTheDocument();
    expect(screen.getByText('Not an emoji')).toBeInTheDocument();
    expect(emojiInput()).toHaveAttribute('aria-invalid', 'true');
    // Both landed on fields, so no banner repeats them.
    expect(screen.queryByText(/Some fields need attention/)).toBeNull();
  });
});

describe('SettingsPage saves on one topic', () => {
  /**
   * A server with the topic's revision: every PATCH bumps it, and a details PATCH whose
   * `expected_revision` isn't current gets 409 `stale_revision`. `external` changes the topic as
   * another device would.
   */
  function fakeServer() {
    let current: TopicDetail = { ...topic };
    const details: Record<string, unknown>[] = [];
    vi.stubGlobal(
      'fetch',
      vi.fn(async (input: Request) => {
        const text = await input.text();
        const body = text ? (JSON.parse(text) as Record<string, unknown>) : {};
        if (input.method === 'GET' && new URL(input.url).pathname === '/api/v1/topics/gym')
          return json(200, current);
        if (input.method !== 'PATCH')
          return json(404, { code: 'not_found', detail: 'not found', errors: [] });
        if ('schedule' in body) {
          const sch = body.schedule as { times: string[]; timezone: string };
          current = {
            ...current,
            revision: current.revision + 1,
            schedule: {
              kind: 'daily',
              times: sch.times,
              days: [1, 2, 3, 4, 5, 6, 7],
              timezone: sch.timezone,
              notify: true,
            },
            schedule_updated_at: '2026-11-26T08:00:00Z',
            due: { is_due: false, due_since: null, next_due_at: null, last_entry_at: null },
          };
          return json(200, current);
        }
        details.push(body);
        if (body.expected_revision !== current.revision)
          return json(409, { code: 'stale_revision', detail: 'Changed elsewhere', errors: [] });
        const a = (body.appearance ?? {}) as Partial<Appearance>;
        current = {
          ...current,
          revision: current.revision + 1,
          appearance: { ...current.appearance, ...a },
        };
        return json(200, current);
      }),
    );
    const external = (patch: Partial<TopicDetail>) => {
      current = { ...current, ...patch, revision: current.revision + 1 };
    };
    return { details, external };
  }

  /** The topic comes from the query cache, as in TopicLayout, so this page's own saves reach it. */
  function Layout() {
    const q = useQuery({
      ...getTopicOptions({ path: { ref: 'gym' } }),
      initialData: topic,
      staleTime: Infinity,
    });
    return <Outlet context={{ topic: q.data }} />;
  }

  function renderSettings() {
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
    const router = createMemoryRouter(
      [
        {
          path: '/t/:ref',
          element: <Layout />,
          children: [{ path: 'settings', element: <SettingsPage /> }],
        },
      ],
      { initialEntries: ['/t/gym/settings'] },
    );
    render(
      <QueryClientProvider client={qc}>
        <ToastProvider>
          <RouterProvider router={router} />
        </ToastProvider>
      </QueryClientProvider>,
    );
    return { user: userEvent.setup(), qc };
  }

  async function saveSchedule(user: ReturnType<typeof userEvent.setup>) {
    await user.click(screen.getByRole('radio', { name: 'Daily' }));
    await user.click(screen.getByRole('button', { name: 'Save schedule' }));
    expect(await screen.findByText('Schedule saved')).toBeInTheDocument();
  }

  beforeEach(() => {
    client.setConfig({ baseUrl: 'http://quickr.test' });
  });

  afterEach(() => {
    client.setConfig({ baseUrl: '' });
    vi.unstubAllGlobals();
  });

  it('saves the details after a schedule save without a conflict, keeping the unsaved edit', async () => {
    const server = fakeServer();
    const { user } = renderSettings();
    await user.click(await screen.findByRole('radio', { name: 'Blue' }));
    await saveSchedule(user);
    expect(screen.getByRole('radio', { name: 'Blue' })).toBeChecked();
    await user.click(screen.getByRole('button', { name: 'Save details' }));
    expect(await screen.findByText('Saved')).toBeInTheDocument();
    expect(server.details).toEqual([{ appearance: { color: 'blue' }, expected_revision: 8 }]);
    expect(screen.queryByText('Changed elsewhere')).toBeNull();
  });

  it('saves the details after a schedule save made before the edit, too', async () => {
    const server = fakeServer();
    const { user } = renderSettings();
    await saveSchedule(user);
    await user.click(screen.getByRole('radio', { name: 'Blue' }));
    await user.click(screen.getByRole('button', { name: 'Save details' }));
    expect(await screen.findByText('Saved')).toBeInTheDocument();
    expect(server.details).toEqual([{ appearance: { color: 'blue' }, expected_revision: 8 }]);
  });

  it('refuses a details save over a concurrent change to the details from elsewhere', async () => {
    const server = fakeServer();
    const { user, qc } = renderSettings();
    await user.click(await screen.findByRole('radio', { name: 'Blue' }));
    // Another device renames the topic; a refetch brings it in while the form is dirty.
    server.external({ name: 'Lifting' });
    await act(() => qc.refetchQueries());
    expect(screen.getByRole('radio', { name: 'Blue' })).toBeChecked();
    await user.click(screen.getByRole('button', { name: 'Save details' }));
    expect(await screen.findByText('Changed elsewhere')).toBeInTheDocument();
    expect(server.details).toEqual([{ appearance: { color: 'blue' }, expected_revision: 7 }]);
  });

  it('rebases over a change from elsewhere that leaves the details alone', async () => {
    const server = fakeServer();
    const { user, qc } = renderSettings();
    await user.click(await screen.findByRole('radio', { name: 'Blue' }));
    server.external({ status: 'archived', archived_at: '2026-11-26T08:00:00Z' });
    await act(() => qc.refetchQueries());
    await user.click(screen.getByRole('button', { name: 'Save details' }));
    expect(await screen.findByText('Saved')).toBeInTheDocument();
    expect(server.details).toEqual([{ appearance: { color: 'blue' }, expected_revision: 8 }]);
  });
});
