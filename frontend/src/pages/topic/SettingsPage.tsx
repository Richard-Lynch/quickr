import { zodResolver } from '@hookform/resolvers/zod';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { useEffect, useMemo, useState } from 'react';
import { FormProvider, useForm, useWatch, type FieldPath } from 'react-hook-form';
import { useNavigate } from 'react-router';
import { z } from 'zod';

import { applyFieldErrors, errorMessage, mapApiError } from '../../api/errors';
import { useLimits } from '../../api/limits';
import {
  useSetTopicArchived,
  useUpdateTopicMeta,
  useUpdateTopicSchedule,
} from '../../api/mutations';
import { invalidateTopicData } from '../../api/queryClient';
import {
  deleteTopicMutation,
  getTopicOptions,
  getTopicQueryKey,
} from '../../client/@tanstack/react-query.gen';
import type { TopicDetail } from '../../client';
import { Page, TopBar } from '../../components/AppShell';
import { AppearanceFields } from '../../components/builder/AppearanceFields';
import { builderFieldFor } from '../../components/builder/serverErrors';
import { ScheduleEditor } from '../../components/schedule/ScheduleEditor';
import { Button } from '../../components/ui/Button';
import { Banner, Card, SectionTitle } from '../../components/ui/Card';
import { Field, Input, Textarea } from '../../components/ui/Field';
import { Icon } from '../../components/ui/Icon';
import { ConfirmSheet } from '../../components/ui/Sheet';
import { useToast } from '../../components/ui/Toast';
import {
  appearanceChanges,
  appearanceDraftOf,
  emptyTopicDraft,
  makeScheduleSchema,
  makeTopicMetaAppearanceSchema,
} from '../../lib/builder';
import { formatDateTime } from '../../lib/dates';
import { plural } from '../../lib/format';
import { draftFromSchedule, scheduleFieldFor, type ScheduleDraft } from '../../lib/schedule';
import { appearanceOf, type TopicUpdateBody } from '../../lib/topicAppearanceSeam';
import { useUnsavedChangesGuard } from '../../lib/unsavedChanges';
import { useTopic } from './TopicLayout';

type MetaSchema = ReturnType<typeof makeTopicMetaAppearanceSchema>;
type MetaValues = z.input<MetaSchema>;
type MetaOutput = z.output<MetaSchema>;

const META_FIELDS = new Set(['name', 'slug', 'description']);

/** The details form's fields, each compared on its own. */
const DETAIL_FIELDS = [
  'name',
  'slug',
  'description',
  'appearance.color',
  'appearance.icon',
  'appearance.tags',
] as const;
type DetailField = (typeof DETAIL_FIELDS)[number];

function fieldOf(v: MetaValues, f: DetailField): unknown {
  if (f === 'appearance.color') return v.appearance.color;
  if (f === 'appearance.icon') return v.appearance.icon;
  if (f === 'appearance.tags') return v.appearance.tags;
  return v[f];
}

const sameValue = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b);

/** The fields where `current` differs from `base` (what the user has edited). */
function editedFields(current: MetaValues, base: MetaValues): DetailField[] {
  return DETAIL_FIELDS.filter((f) => !sameValue(fieldOf(current, f), fieldOf(base, f)));
}

function changedAny(a: MetaValues, b: MetaValues, fields: readonly DetailField[]): boolean {
  return fields.some((f) => !sameValue(fieldOf(a, f), fieldOf(b, f)));
}

function pick(
  v: MetaValues,
  fields: readonly DetailField[],
): Partial<Record<DetailField, unknown>> {
  return Object.fromEntries(fields.map((f) => [f, fieldOf(v, f)]));
}

/** What the form shows: a topic's values, with the user's edits (`keep`) put back on top. */
interface Shown {
  topic: TopicDetail;
  keep: Partial<Record<DetailField, unknown>>;
}

/** The PATCH body for the form's (valid) values against `from`; `null` when nothing changed. */
function detailsChanges(from: TopicDetail, v: MetaOutput): TopicUpdateBody | null {
  const changed = appearanceChanges(appearanceOf(from), v.appearance);
  const body: TopicUpdateBody = {
    ...(v.name !== from.name ? { name: v.name } : {}),
    ...(v.slug !== from.slug ? { slug: v.slug } : {}),
    ...(v.description !== from.description ? { description: v.description } : {}),
    ...(changed ? { appearance: changed } : {}),
  };
  return Object.keys(body).length > 0 ? body : null;
}

function metaValuesOf(t: TopicDetail): MetaValues {
  return {
    name: t.name,
    slug: t.slug,
    description: t.description,
    appearance: appearanceDraftOf(appearanceOf(t)),
  };
}

interface DirtyProps {
  /** Report unsaved edits to the page's single unsaved-changes guard. */
  onDirty: (dirty: boolean) => void;
  allowNavigation: () => void;
}

export function SettingsPage() {
  const topic = useTopic();
  // One guard for the page (React Router allows a single active blocker).
  const [dirty, setDirty] = useState({ meta: false, schedule: false });
  const guard = useUnsavedChangesGuard(dirty.meta || dirty.schedule);
  return (
    <>
      <TopBar back={`/t/${topic.slug}`} title="Topic settings" />
      <Page className="mx-auto max-w-2xl gap-6">
        <MetaForm
          key={topic.id}
          topic={topic}
          onDirty={(meta) => setDirty((d) => (d.meta === meta ? d : { ...d, meta }))}
          allowNavigation={guard.allowNavigation}
        />
        <ScheduleForm
          key={topic.schedule_updated_at ?? 'none'}
          topic={topic}
          onDirty={(schedule) =>
            setDirty((d) => (d.schedule === schedule ? d : { ...d, schedule }))
          }
          allowNavigation={guard.allowNavigation}
        />
        <Lifecycle topic={topic} />
      </Page>
      {guard.dialog}
    </>
  );
}

function MetaForm({ topic, onDirty, allowNavigation }: { topic: TopicDetail } & DirtyProps) {
  const navigate = useNavigate();
  const { toast } = useToast();
  const limits = useLimits();
  const schema = useMemo(() => makeTopicMetaAppearanceSchema(limits), [limits]);
  const qc = useQueryClient();
  const [banner, setBanner] = useState<string | null>(null);
  const update = useUpdateTopicMeta();
  const form = useForm<MetaValues, unknown, MetaOutput>({
    resolver: zodResolver(schema),
    defaultValues: metaValuesOf(topic),
  });
  const e = form.formState.errors;
  const { isDirty, isSubmitting } = form.formState;
  useEffect(() => onDirty(isDirty), [isDirty, onDirty]);
  // `base` is the topic a save diffs against and whose revision it sends. A newer topic (this
  // client's own schedule or archive save, a refetch, the feed) becomes the base unless it changed
  // a field the user is editing: the fields they haven't touched take its values and their edits
  // stay. Only an edit that a newer topic also changed keeps the old base, so the save gets 409
  // instead of overwriting the other change. The form isn't keyed by the topic's values: the
  // optimistic patch would remount it mid-save, and a failure would lose the edits and the 422's
  // field errors.
  const values = useWatch({ control: form.control }) as MetaValues;
  const [base, setBase] = useState(topic);
  const [shown, setShown] = useState<Shown>({ topic, keep: {} });
  if (topic !== base && !isSubmitting) {
    const edited = editedFields(values, metaValuesOf(base));
    if (!changedAny(metaValuesOf(base), metaValuesOf(topic), edited)) {
      setBase(topic);
      setShown({ topic, keep: pick(values, edited) });
    }
  }
  useEffect(() => {
    form.reset(metaValuesOf(shown.topic));
    for (const [f, v] of Object.entries(shown.keep))
      form.setValue(f as DetailField, v as never, { shouldDirty: true });
  }, [shown, form]);

  const onSubmit = form.handleSubmit(async (v) => {
    setBanner(null);
    const body = detailsChanges(base, v);
    if (!body) {
      toast({ title: 'Nothing to save', tone: 'info' });
      return;
    }
    const save = (from: TopicDetail) =>
      update.mutateAsync({
        path: { ref: topic.slug },
        body: { ...body, expected_revision: from.revision },
      });
    try {
      let updated: TopicDetail;
      try {
        updated = await save(base);
      } catch (err) {
        // A change this form hasn't seen (another device, before the feed brought it): when it
        // left the edited fields alone, send the same edits on its revision, once.
        if (mapApiError(err).code !== 'stale_revision') throw err;
        let fresh: TopicDetail;
        try {
          fresh = await qc.query({
            ...getTopicOptions({ path: { ref: topic.slug } }),
            staleTime: 0,
          });
        } catch {
          throw err; // no fresh copy to check against: report the conflict as it is
        }
        const sent = editedFields(form.getValues(), metaValuesOf(base));
        if (changedAny(metaValuesOf(base), metaValuesOf(fresh), sent)) throw err;
        updated = await save(fresh);
      }
      toast({ title: 'Saved' });
      setBase(updated);
      setShown({ topic: updated, keep: {} });
      onDirty(false);
      allowNavigation();
      if (updated.slug !== base.slug)
        void navigate(`/t/${updated.slug}/settings`, { replace: true });
    } catch (err) {
      const mapped = mapApiError(err);
      // builderFieldFor maps the meta and `appearance.*` paths (a meta PATCH sends no others).
      const draft = { ...emptyTopicDraft(), appearance: form.getValues('appearance') };
      const rest = applyFieldErrors(
        mapped.fieldErrors,
        (p) => {
          const f = builderFieldFor(p, draft);
          return f && (META_FIELDS.has(f) || f.startsWith('appearance.'))
            ? (f as FieldPath<MetaValues>)
            : null;
        },
        form.setError,
      );
      if (mapped.fieldErrors.length > 0 && rest.length === 0) return;
      // Older servers report slug collisions as a 409 without a loc.
      if (mapped.code === 'conflict' && /slug/i.test(mapped.message))
        form.setError('slug', { message: mapped.message });
      else setBanner([mapped.message, ...rest.map((r) => r.message)].join(' — '));
    }
  });

  return (
    <Card className="p-4 sm:p-5">
      <form onSubmit={(ev) => void onSubmit(ev)} noValidate className="flex flex-col gap-4">
        <SectionTitle>Details</SectionTitle>
        {banner ? <Banner title={banner} /> : null}
        {/* Read-only while saving: the reply resets the form, which would drop edits made meanwhile. */}
        <fieldset disabled={isSubmitting} className="contents">
          <Field label="Name" error={e.name?.message}>
            {({ id, describedBy, invalid }) => (
              <Input
                id={id}
                aria-describedby={describedBy}
                aria-invalid={invalid || undefined}
                {...form.register('name')}
              />
            )}
          </Field>
          <Field
            label="URL slug"
            hint="Changing it breaks old links to this topic"
            error={e.slug?.message}
          >
            {({ id, describedBy, invalid }) => (
              <Input
                id={id}
                aria-describedby={describedBy}
                aria-invalid={invalid || undefined}
                autoCapitalize="none"
                spellCheck={false}
                className="font-mono"
                {...form.register('slug')}
              />
            )}
          </Field>
          <Field label="Description" optional error={e.description?.message}>
            {({ id, describedBy, invalid }) => (
              <Textarea
                id={id}
                aria-describedby={describedBy}
                aria-invalid={invalid || undefined}
                rows={3}
                {...form.register('description')}
              />
            )}
          </Field>
          <FormProvider {...form}>
            <div className="border-t border-line pt-4">
              <AppearanceFields />
            </div>
          </FormProvider>
        </fieldset>
        <p className="text-xs text-muted">Questions are edited by publishing a new version.</p>
        <div className="flex justify-end">
          <Button
            type="submit"
            variant="primary"
            loading={form.formState.isSubmitting}
            disabled={!isDirty}
          >
            Save details
          </Button>
        </div>
      </form>
    </Card>
  );
}

interface ScheduleValues {
  schedule: ScheduleDraft;
}

/** Schedule + per-topic notify toggle; saved with PATCH (optimistic). */
function ScheduleForm({ topic, onDirty, allowNavigation }: { topic: TopicDetail } & DirtyProps) {
  const { toast } = useToast();
  const limits = useLimits();
  const schema = useMemo(() => z.object({ schedule: makeScheduleSchema(limits) }), [limits]);
  const update = useUpdateTopicSchedule();
  const [banner, setBanner] = useState<string | null>(null);
  const form = useForm<ScheduleValues, unknown, z.output<typeof schema>>({
    resolver: zodResolver(schema),
    defaultValues: { schedule: draftFromSchedule(topic.schedule) },
    reValidateMode: 'onChange',
  });
  const { isDirty } = form.formState;
  useEffect(() => onDirty(isDirty), [isDirty, onDirty]);
  const archived = topic.status === 'archived';

  const onSubmit = form.handleSubmit(async ({ schedule }) => {
    setBanner(null);
    try {
      await update.mutateAsync({
        path: { ref: topic.slug },
        body: { schedule },
      });
      toast({ title: schedule ? 'Schedule saved' : 'Schedule removed' });
      onDirty(false);
      allowNavigation();
      form.reset({ schedule: form.getValues('schedule') });
    } catch (err) {
      const mapped = mapApiError(err);
      const rest = applyFieldErrors(
        mapped.fieldErrors,
        (p) => scheduleFieldFor(p) as 'schedule.kind' | null,
        form.setError,
      );
      if (rest.length > 0 || mapped.fieldErrors.length === 0)
        setBanner([mapped.message, ...rest.map((r) => r.message)].join(' — '));
    }
  });

  return (
    <Card className="p-4 sm:p-5">
      <FormProvider {...form}>
        <form onSubmit={(ev) => void onSubmit(ev)} noValidate className="flex flex-col gap-4">
          <SectionTitle>Schedule</SectionTitle>
          {banner ? <Banner title={banner} /> : null}
          {archived ? <p className="text-sm text-muted">Archived topics are never due.</p> : null}
          <ScheduleEditor />
          <div className="flex justify-end gap-2">
            {isDirty ? (
              <Button variant="ghost" onClick={() => form.reset()}>
                Reset
              </Button>
            ) : null}
            <Button
              type="submit"
              variant="primary"
              loading={form.formState.isSubmitting}
              disabled={!isDirty}
            >
              Save schedule
            </Button>
          </div>
        </form>
      </FormProvider>
    </Card>
  );
}
function Lifecycle({ topic }: { topic: TopicDetail }) {
  const qc = useQueryClient();
  const navigate = useNavigate();
  const { toast } = useToast();
  const [confirm, setConfirm] = useState<'delete' | null>(null);
  const setArchived = useSetTopicArchived();
  const remove = useMutation(deleteTopicMutation());
  const archived = topic.status === 'archived';

  /** Applied instantly (optimistic); archive offers Undo instead of a confirm. */
  const change = (to: boolean, undoable: boolean) => {
    setArchived.run(topic, to).then(
      () => {
        toast({
          title: to ? 'Topic archived' : 'Topic unarchived',
          ...(undoable
            ? {
                description: 'Hidden from the list; no new entries.',
                action: { label: 'Undo', onClick: () => change(!to, false) },
              }
            : {}),
        });
      },
      (err: unknown) => toast({ title: 'Failed', description: errorMessage(err), tone: 'danger' }),
    );
  };

  return (
    <Card className="flex flex-col gap-4 p-4 sm:p-5">
      <SectionTitle>Lifecycle</SectionTitle>
      <p className="text-sm text-muted">
        Created {formatDateTime(topic.created_at)} · {plural(topic.entry_count, 'entry', 'entries')}
        {topic.archived_at ? ` · archived ${formatDateTime(topic.archived_at)}` : ''}
      </p>
      {archived ? (
        <div className="flex flex-col gap-3 sm:flex-row">
          <Button icon={<Icon name="restore" />} onClick={() => change(false, false)}>
            Unarchive
          </Button>
          <Button
            variant="quiet-danger"
            icon={<Icon name="trash" />}
            onClick={() => setConfirm('delete')}
          >
            Delete permanently
          </Button>
        </div>
      ) : (
        <div className="flex flex-col gap-2">
          <Button
            className="self-start"
            icon={<Icon name="archive" />}
            onClick={() => change(true, true)}
          >
            Archive topic
          </Button>
          <p className="text-xs text-muted">
            Archived topics are hidden and stop accepting entries. Only archived topics can be
            deleted.
          </p>
        </div>
      )}

      <ConfirmSheet
        open={confirm === 'delete'}
        onClose={() => setConfirm(null)}
        title="Delete forever?"
        danger
        typeToConfirm={topic.slug}
        body={
          <p>
            This permanently deletes <strong className="text-ink">{topic.name}</strong>, all{' '}
            {plural(topic.entry_count, 'entry', 'entries')} and every version. There is no undo.
          </p>
        }
        confirmLabel="Delete topic"
        busy={remove.isPending}
        onConfirm={() =>
          remove.mutate(
            { path: { ref: topic.slug } },
            {
              onSuccess: () => {
                setConfirm(null);
                qc.removeQueries({ queryKey: getTopicQueryKey({ path: { ref: topic.slug } }) });
                void invalidateTopicData(qc);
                toast({ title: 'Topic deleted' });
                void navigate('/', { replace: true });
              },
              onError: (err) =>
                toast({ title: 'Delete failed', description: errorMessage(err), tone: 'danger' }),
            },
          )
        }
      />
    </Card>
  );
}
