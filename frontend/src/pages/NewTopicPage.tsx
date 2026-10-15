import { zodResolver } from '@hookform/resolvers/zod';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { useMemo, useState } from 'react';
import { useForm } from 'react-hook-form';
import { useNavigate } from 'react-router';

import { applyFieldErrors, mapApiError, type FieldError } from '../api/errors';
import { useLimits } from '../api/limits';
import { invalidateOperations } from '../api/queryClient';
import { createTopicMutation, getTopicQueryKey } from '../client/@tanstack/react-query.gen';
import { Page, StickyActions, TopBar } from '../components/AppShell';
import { builderFieldFor } from '../components/builder/serverErrors';
import { TopicBuilder } from '../components/builder/TopicBuilder';
import { TopicMetaFields } from '../components/builder/TopicMetaFields';
import { ScheduleEditor } from '../components/schedule/ScheduleEditor';
import { Button } from '../components/ui/Button';
import { Banner, Card } from '../components/ui/Card';
import { Icon } from '../components/ui/Icon';
import { useToast } from '../components/ui/Toast';
import {
  emptyTopicDraft,
  makeTopicDraftSchema,
  type TopicDraft,
  type TopicDraftOutput,
} from '../lib/builder';
import { useUnsavedChangesGuard } from '../lib/unsavedChanges';

const CLIENT_INVALID = 'Fix the highlighted fields';

export function NewTopicPage() {
  const navigate = useNavigate();
  const qc = useQueryClient();
  const { toast } = useToast();
  const [banner, setBanner] = useState<{ message: string; extra: FieldError[] } | null>(null);
  const create = useMutation(createTopicMutation());
  const limits = useLimits();
  const schema = useMemo(() => makeTopicDraftSchema(limits), [limits]);
  const form = useForm<TopicDraft, unknown, TopicDraftOutput>({
    resolver: zodResolver(schema),
    defaultValues: emptyTopicDraft(),
    mode: 'onSubmit',
    reValidateMode: 'onChange',
  });
  const guard = useUnsavedChangesGuard(form.formState.isDirty, {
    message: 'This topic hasn’t been created yet. Leave and lose it?',
  });

  const onSubmit = form.handleSubmit(
    async (body) => {
      setBanner(null);
      try {
        const topic = await create.mutateAsync({ body });
        qc.setQueryData(getTopicQueryKey({ path: { ref: topic.slug } }), topic);
        void invalidateOperations(qc, ['listTopics']);
        toast({ title: 'Topic created', description: 'Log your first entry.' });
        guard.allowNavigation();
        void navigate(`/t/${topic.slug}/record`, { replace: true });
      } catch (err) {
        const mapped = mapApiError(err);
        const draft = form.getValues();
        const extra = applyFieldErrors(
          mapped.fieldErrors,
          (p) => builderFieldFor(p, draft),
          form.setError,
        );
        setBanner({ message: mapped.message, extra });
        window.scrollTo({ top: 0, behavior: 'smooth' });
      }
    },
    () => setBanner({ message: CLIENT_INVALID, extra: [] }),
  );

  return (
    <>
      <TopBar back="/" title="New topic" />
      <Page>
        <TopicBuilder
          form={form}
          defaultExpanded="all"
          onSubmit={(e) => void onSubmit(e)}
          header={
            <>
              {banner &&
              (banner.message !== CLIENT_INVALID ||
                Object.keys(form.formState.errors).length > 0) ? (
                <Banner title={banner.message}>
                  {banner.extra.length > 0 ? (
                    <ul className="list-disc pl-4">
                      {banner.extra.map((x) => (
                        <li key={x.path + x.message}>{x.message}</li>
                      ))}
                    </ul>
                  ) : null}
                </Banner>
              ) : null}
              <Card className="p-4 sm:p-5">
                <TopicMetaFields />
              </Card>
            </>
          }
          footer={
            <section className="flex flex-col gap-3" aria-label="Schedule">
              <h2 className="font-display text-lg font-semibold tracking-tight">
                Schedule <span className="text-sm font-normal text-muted">optional</span>
              </h2>
              <Card className="p-4 sm:p-5">
                <ScheduleEditor />
              </Card>
            </section>
          }
          actions={
            <StickyActions>
              <Button
                type="submit"
                variant="primary"
                size="lg"
                className="flex-1 sm:flex-none"
                loading={form.formState.isSubmitting}
                icon={<Icon name="check" strokeWidth={2.6} />}
              >
                Create topic
              </Button>
            </StickyActions>
          }
        />
      </Page>
      {guard.dialog}
    </>
  );
}
