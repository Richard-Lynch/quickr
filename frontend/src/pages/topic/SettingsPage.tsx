import { zodResolver } from '@hookform/resolvers/zod';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { useState } from 'react';
import { useForm } from 'react-hook-form';
import { useNavigate } from 'react-router';
import type { z } from 'zod';

import { applyFieldErrors, errorMessage, mapApiError } from '../../api/errors';
import { useSetTopicArchived, useUpdateTopicMeta } from '../../api/mutations';
import { invalidateTopicData } from '../../api/queryClient';
import { deleteTopicMutation, getTopicQueryKey } from '../../client/@tanstack/react-query.gen';
import type { TopicDetail } from '../../client';
import { Page, TopBar } from '../../components/AppShell';
import { Button } from '../../components/ui/Button';
import { Banner, Card, SectionTitle } from '../../components/ui/Card';
import { Field, Input, Textarea } from '../../components/ui/Field';
import { Icon } from '../../components/ui/Icon';
import { ConfirmSheet } from '../../components/ui/Sheet';
import { useToast } from '../../components/ui/Toast';
import { topicMetaSchema } from '../../lib/builder';
import { formatDateTime } from '../../lib/dates';
import { plural } from '../../lib/format';
import { useUnsavedChangesGuard } from '../../lib/unsavedChanges';
import { useTopic } from './TopicLayout';

type MetaValues = z.input<typeof topicMetaSchema>;
type MetaOutput = z.output<typeof topicMetaSchema>;

export function SettingsPage() {
  const topic = useTopic();
  return (
    <>
      <TopBar back={`/t/${topic.slug}`} title="Topic settings" />
      <Page className="mx-auto max-w-2xl gap-6">
        <MetaForm key={topic.updated_at} topic={topic} />
        <Lifecycle topic={topic} />
      </Page>
    </>
  );
}

function MetaForm({ topic }: { topic: TopicDetail }) {
  const navigate = useNavigate();
  const { toast } = useToast();
  const [banner, setBanner] = useState<string | null>(null);
  const update = useUpdateTopicMeta();
  const form = useForm<MetaValues, unknown, MetaOutput>({
    resolver: zodResolver(topicMetaSchema),
    defaultValues: { name: topic.name, slug: topic.slug, description: topic.description },
  });
  const e = form.formState.errors;
  const guard = useUnsavedChangesGuard(form.formState.isDirty);

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
      const updated = await update.mutateAsync({ path: { ref: topic.slug }, body });
      toast({ title: 'Saved' });
      // The form remounts with the saved values (keyed by updated_at).
      guard.allowNavigation();
      if (updated.slug !== topic.slug)
        void navigate(`/t/${updated.slug}/settings`, { replace: true });
    } catch (err) {
      const mapped = mapApiError(err);
      const rest = applyFieldErrors(
        mapped.fieldErrors,
        (p) => (p === 'name' || p === 'slug' || p === 'description' ? p : null),
        form.setError,
      );
      // Slug collisions come back as a 409 Problem without a loc.
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
          {({ id, describedBy }) => (
            <Textarea
              id={id}
              aria-describedby={describedBy}
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
            disabled={!form.formState.isDirty}
          >
            Save details
          </Button>
        </div>
      </form>
      {guard.dialog}
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
