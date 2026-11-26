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
import { TopicLayout } from '../../pages/topic/TopicLayout';
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

const sameJson = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b);

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
      path: `/api/v1/topics/${topic.id}`,
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

  it('keeps a dirty form’s base when a newer topic changed the field being edited', async () => {
    const patches = stubServer(() =>
      json(409, { code: 'stale_revision', detail: 'Changed', errors: [] }),
    );
    const user = renderSettings();
    await user.click(await screen.findByRole('radio', { name: 'Blue' }));
    act(() =>
      refetch.set({ ...topic, revision: 8, appearance: { ...appearance, color: 'green' } }),
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
   * A server with the topic's revision, found by id or slug: every PATCH bumps it, and a details
   * PATCH whose `expected_revision` isn't current gets 409 `stale_revision`. `external` changes the
   * topic as another device would. `beforeDetails` queues one step per details PATCH, run before the
   * server handles it: another device's write in between, or a reply that replaces the server's.
   */
  function fakeServer() {
    let current: TopicDetail = { ...topic };
    const details: Record<string, unknown>[] = [];
    const paths: string[] = [];
    const steps: (() => Response | undefined)[] = [];
    const isCurrent = (path: string) =>
      path === `/api/v1/topics/${current.id}` || path === `/api/v1/topics/${current.slug}`;
    vi.stubGlobal(
      'fetch',
      vi.fn(async (input: Request) => {
        const text = await input.text();
        const body = text ? (JSON.parse(text) as Record<string, unknown>) : {};
        const path = new URL(input.url).pathname;
        paths.push(`${input.method} ${path}`);
        if (input.method === 'GET' && isCurrent(path)) return json(200, current);
        if (input.method !== 'PATCH' || !isCurrent(path))
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
        const replaced = steps.shift()?.();
        if (replaced) return replaced;
        if (body.expected_revision !== current.revision)
          return json(409, { code: 'stale_revision', detail: 'Changed elsewhere', errors: [] });
        const { appearance: a, ...meta } = body;
        delete meta.expected_revision;
        current = {
          ...current,
          ...(meta as Partial<TopicDetail>),
          revision: current.revision + 1,
          appearance: { ...current.appearance, ...(a as Partial<Appearance> | undefined) },
        };
        return json(200, current);
      }),
    );
    const external = (patch: Partial<TopicDetail>) => {
      current = { ...current, ...patch, revision: current.revision + 1 };
    };
    const beforeDetails = (...more: (() => Response | undefined)[]) => steps.push(...more);
    return { details, paths, external, beforeDetails };
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

  /** `layout: 'app'` uses the app's TopicLayout, which loads the topic by the route's slug. */
  function renderSettings({ layout }: { layout?: 'app' } = {}) {
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
    const router = createMemoryRouter(
      [
        {
          path: '/t/:ref',
          element: layout === 'app' ? <TopicLayout /> : <Layout />,
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
    return { user: userEvent.setup(), qc, router };
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

  it('refuses a details save over a concurrent change to the same field from elsewhere', async () => {
    const server = fakeServer();
    const { user, qc } = renderSettings();
    await user.click(await screen.findByRole('radio', { name: 'Blue' }));
    // Another device sets the colour too; a refetch brings it in while the form is dirty.
    server.external({ appearance: { ...appearance, color: 'green' } });
    await act(() => qc.refetchQueries());
    expect(screen.getByRole('radio', { name: 'Blue' })).toBeChecked();
    await user.click(screen.getByRole('button', { name: 'Save details' }));
    expect(await screen.findByText(/^Colour changed elsewhere/)).toBeInTheDocument();
    expect(server.details).toEqual([{ appearance: { color: 'blue' }, expected_revision: 7 }]);
  });

  it('takes another device’s rename into the form and keeps the colour edit', async () => {
    const server = fakeServer();
    const { user, qc } = renderSettings();
    await user.click(await screen.findByRole('radio', { name: 'Blue' }));
    server.external({ name: 'Lifting' });
    await act(() => qc.refetchQueries());
    await waitFor(() => expect(screen.getByLabelText('Name')).toHaveValue('Lifting'));
    expect(screen.getByRole('radio', { name: 'Blue' })).toBeChecked();
    await user.click(screen.getByRole('button', { name: 'Save details' }));
    expect(await screen.findByText('Saved')).toBeInTheDocument();
    expect(server.details).toEqual([{ appearance: { color: 'blue' }, expected_revision: 8 }]);
  });

  it('re-sends on the newer revision when an unseen change left the edits alone', async () => {
    const server = fakeServer();
    const { user } = renderSettings();
    await user.click(await screen.findByRole('radio', { name: 'Blue' }));
    server.external({ name: 'Lifting' }); // not fetched: the form still has revision 7
    await user.click(screen.getByRole('button', { name: 'Save details' }));
    expect(await screen.findByText('Saved')).toBeInTheDocument();
    expect(server.details).toEqual([
      { appearance: { color: 'blue' }, expected_revision: 7 },
      { appearance: { color: 'blue' }, expected_revision: 8 },
    ]);
    expect(screen.queryByText('Changed elsewhere')).toBeNull();
  });

  it('shows the conflict naming the field, then a second save overwrites it', async () => {
    const server = fakeServer();
    const { user } = renderSettings();
    await user.click(await screen.findByRole('radio', { name: 'Blue' }));
    // Unseen: another device sets the colour and renames the topic.
    server.external({ name: 'Lifting', appearance: { ...appearance, color: 'green' } });
    await user.click(screen.getByRole('button', { name: 'Save details' }));
    expect(
      await screen.findByText(
        'Colour changed elsewhere. Your edit is still here: save again to keep it.',
      ),
    ).toBeInTheDocument();
    expect(server.details).toEqual([{ appearance: { color: 'blue' }, expected_revision: 7 }]);
    // The form now stands on the other device's topic, with the colour edit on top.
    await waitFor(() => expect(screen.getByLabelText('Name')).toHaveValue('Lifting'));
    expect(screen.getByRole('radio', { name: 'Blue' })).toBeChecked();
    await user.click(screen.getByRole('button', { name: 'Save details' }));
    expect(await screen.findByText('Saved')).toBeInTheDocument();
    expect(server.details).toEqual([
      { appearance: { color: 'blue' }, expected_revision: 7 },
      { appearance: { color: 'blue' }, expected_revision: 8 },
    ]);
  });

  it('re-sends by id over a slug changed elsewhere while only the colour was edited', async () => {
    const server = fakeServer();
    const { user, router } = renderSettings();
    await user.click(await screen.findByRole('radio', { name: 'Blue' }));
    server.external({ slug: 'lifting' }); // unseen: /topics/gym is gone
    await user.click(screen.getByRole('button', { name: 'Save details' }));
    expect(await screen.findByText('Saved')).toBeInTheDocument();
    expect(server.details).toEqual([
      { appearance: { color: 'blue' }, expected_revision: 7 },
      { appearance: { color: 'blue' }, expected_revision: 8 },
    ]);
    const topicCalls = server.paths.filter((p) => p.startsWith('PATCH') || p.endsWith(topic.id));
    expect(topicCalls).toEqual([
      `PATCH /api/v1/topics/${topic.id}`,
      `GET /api/v1/topics/${topic.id}`,
      `PATCH /api/v1/topics/${topic.id}`,
    ]);
    expect(screen.queryByText(/changed elsewhere/i)).toBeNull();
    await waitFor(() => expect(router.state.location.pathname).toBe('/t/lifting/settings'));
  });

  it('follows a slug changed elsewhere in the app layout, keeping the form through a conflict', async () => {
    const server = fakeServer();
    const { user, router } = renderSettings({ layout: 'app' });
    await user.click(await screen.findByRole('radio', { name: 'Blue' }));
    // Another device renames the slug and sets the colour; the 409's invalidation refetches
    // /topics/gym, which is gone.
    server.external({ slug: 'lifting', appearance: { ...appearance, color: 'green' } });
    await user.click(screen.getByRole('button', { name: 'Save details' }));
    expect(await screen.findByText(/^Colour changed elsewhere/)).toBeInTheDocument();
    await waitFor(() => expect(router.state.location.pathname).toBe('/t/lifting/settings'));
    expect(screen.queryByText('Topic not found')).toBeNull();
    expect(screen.getByRole('radio', { name: 'Blue' })).toBeChecked();
    await waitFor(() => expect(screen.getByLabelText('URL slug')).toHaveValue('lifting'));
    await user.click(screen.getByRole('button', { name: 'Save details' }));
    expect(await screen.findByText('Saved')).toBeInTheDocument();
    expect(server.details).toEqual([
      { appearance: { color: 'blue' }, expected_revision: 7 },
      { appearance: { color: 'blue' }, expected_revision: 8 },
    ]);
  });

  it('keeps re-sending over two unrelated writes in a row', async () => {
    const server = fakeServer();
    const { user } = renderSettings();
    await user.click(await screen.findByRole('radio', { name: 'Blue' }));
    server.external({ name: 'Lifting' });
    server.beforeDetails(
      () => undefined,
      () => {
        server.external({ description: 'Twice a week' }); // after the refetch
        return undefined;
      },
    );
    await user.click(screen.getByRole('button', { name: 'Save details' }));
    expect(await screen.findByText('Saved')).toBeInTheDocument();
    expect(server.details.map((d) => d.expected_revision)).toEqual([7, 8, 9]);
    expect(server.details.every((d) => sameJson(d.appearance, { color: 'blue' }))).toBe(true);
    expect(screen.queryByText(/changed elsewhere/i)).toBeNull();
  });

  it('gives up after three attempts on a busy topic, with the busy error', async () => {
    const server = fakeServer();
    const { user } = renderSettings();
    await user.click(await screen.findByRole('radio', { name: 'Blue' }));
    const write = (n: number) => () => {
      server.external({ description: `Write ${String(n)}` });
      return undefined;
    };
    server.beforeDetails(write(1), write(2), write(3), write(4));
    await user.click(screen.getByRole('button', { name: 'Save details' }));
    expect(
      await screen.findByText('This topic is busy with other changes. Try again.'),
    ).toBeInTheDocument();
    expect(server.details.map((d) => d.expected_revision)).toEqual([7, 8, 9]);
    expect(screen.queryByText(/changed elsewhere/i)).toBeNull();
    expect(screen.getByRole('radio', { name: 'Blue' })).toBeChecked();
  });

  it('keeps tag text not added yet and the 422 field errors over a rebase', async () => {
    const server = fakeServer();
    const { user, qc } = renderSettings();
    await user.clear(await screen.findByLabelText('Name'));
    await user.type(screen.getByLabelText('Name'), 'Gymnasium');
    server.beforeDetails(() =>
      json(422, {
        code: 'invalid_request',
        detail: 'Invalid request',
        errors: [{ loc: ['body', 'name'], message: 'Value error, name is reserved' }],
      }),
    );
    await user.click(screen.getByRole('button', { name: 'Save details' }));
    expect(await screen.findByText('Name is reserved')).toBeInTheDocument();
    await user.type(tagInput(), 'yoga'); // typed, not added
    server.external({ description: 'Twice a week' });
    await act(() => qc.refetchQueries());
    await waitFor(() =>
      expect(screen.getByRole('textbox', { name: /^Description/ })).toHaveValue('Twice a week'),
    );
    expect(tagInput()).toHaveValue('yoga');
    expect(screen.getByLabelText('Name')).toHaveValue('Gymnasium');
    expect(screen.getByText('Name is reserved')).toBeInTheDocument();
    expect(screen.getByLabelText('Name')).toHaveAttribute('aria-invalid', 'true');
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
