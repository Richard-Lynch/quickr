import { zodResolver } from '@hookform/resolvers/zod';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { useEffect, useMemo, useState } from 'react';
import { FormProvider, useForm } from 'react-hook-form';
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
import { deleteTopicMutation, getTopicQueryKey } from '../../client/@tanstack/react-query.gen';
import type { TopicDetail } from '../../client';
import { Page, TopBar } from '../../components/AppShell';
import { ScheduleEditor } from '../../components/schedule/ScheduleEditor';
import { Button } from '../../components/ui/Button';
import { Banner, Card, SectionTitle } from '../../components/ui/Card';
import { Field, Input, Textarea } from '../../components/ui/Field';
import { Icon } from '../../components/ui/Icon';
import { ConfirmSheet } from '../../components/ui/Sheet';
import { useToast } from '../../components/ui/Toast';
import { makeScheduleSchema, makeTopicMetaSchema } from '../../lib/builder';
import { formatDateTime } from '../../lib/dates';
import { plural } from '../../lib/format';
import { draftFromSchedule, scheduleFieldFor, type ScheduleDraft } from '../../lib/schedule';
import { useUnsavedChangesGuard } from '../../lib/unsavedChanges';
import { useTopic } from './TopicLayout';

type MetaSchema = ReturnType<typeof makeTopicMetaSchema>;
type MetaValues = z.input<MetaSchema>;
type MetaOutput = z.output<MetaSchema>;

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
          key={`${topic.name}\n${topic.slug}\n${topic.description}`}
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
  const schema = useMemo(() => makeTopicMetaSchema(limits), [limits]);
  const [banner, setBanner] = useState<string | null>(null);
  const update = useUpdateTopicMeta();
  const form = useForm<MetaValues, unknown, MetaOutput>({
    resolver: zodResolver(schema),
    defaultValues: {
      name: topic.name,
      slug: topic.slug,
      description: topic.description,
    },
  });
  const e = form.formState.errors;
  const { isDirty } = form.formState;
  useEffect(() => onDirty(isDirty), [isDirty, onDirty]);

  const onSubmit = form.handleSubmit(async (v) => {
    setBanner(null);
    const body = {
      ...(v.name !== topic.name ? { name: v.name } : {}),
      ...(v.slug !== topic.slug ? { slug: v.slug } : {}),
      ...(v.description !== topic.description ? { description: v.description } : {}),
    };
    if (Object.keys(body).length === 0) {
      toast({ title: 'Nothing to save', tone: 'info' });
      return;
    }
    try {
      const updated = await update.mutateAsync({
        path: { ref: topic.slug },
        body,
      });
      toast({ title: 'Saved' });
      // The form remounts with the saved values (keyed by them).
      onDirty(false);
      allowNavigation();
      if (updated.slug !== topic.slug)
        void navigate(`/t/${updated.slug}/settings`, { replace: true });
    } catch (err) {
      const mapped = mapApiError(err);
      const rest = applyFieldErrors(
        mapped.fieldErrors,
        (p) => (p === 'name' || p === 'slug' || p === 'description' ? p : null),
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
