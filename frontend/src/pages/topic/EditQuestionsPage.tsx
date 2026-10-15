import { zodResolver } from '@hookform/resolvers/zod';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { useMemo, useState } from 'react';
import { useForm } from 'react-hook-form';
import { useNavigate } from 'react-router';

import { applyFieldErrors, isConflict, mapApiError, type FieldError } from '../../api/errors';
import { useLimits } from '../../api/limits';
import { invalidateTopicData } from '../../api/queryClient';
import {
  checkTopicVersionMutation,
  getTopicOptions,
  getTopicQueryKey,
  publishTopicVersionMutation,
} from '../../client/@tanstack/react-query.gen';
import type { CompatibilityReport, TopicDetail } from '../../client';
import { Page, StickyActions, TopBar } from '../../components/AppShell';
import { CompatReport } from '../../components/builder/CompatReport';
import { builderFieldFor } from '../../components/builder/serverErrors';
import { TopicBuilder } from '../../components/builder/TopicBuilder';
import { Button } from '../../components/ui/Button';
import { Banner, VersionTag } from '../../components/ui/Card';
import { Field, Textarea } from '../../components/ui/Field';
import { Icon } from '../../components/ui/Icon';
import { Sheet } from '../../components/ui/Sheet';
import { useToast } from '../../components/ui/Toast';
import {
  draftFromTopic,
  makeVersionDraftSchema,
  type TopicDraft,
  type VersionDraftOutput,
} from '../../lib/builder';
import { useUnsavedChangesGuard } from '../../lib/unsavedChanges';
import { useTopic } from './TopicLayout';

const CLIENT_INVALID = 'Fix the highlighted fields';

export function EditQuestionsPage() {
  const topic = useTopic();
  // Remount the editor when the base changes (after "reload latest").
  const [base, setBase] = useState<TopicDetail>(topic);
  return <Editor key={base.current_version} base={base} onRebase={setBase} />;
}

function Editor({ base, onRebase }: { base: TopicDetail; onRebase: (t: TopicDetail) => void }) {
  const navigate = useNavigate();
  const qc = useQueryClient();
  const { toast } = useToast();
  const limits = useLimits();
  const schema = useMemo(() => makeVersionDraftSchema(limits), [limits]);
  const form = useForm<TopicDraft, unknown, VersionDraftOutput>({
    resolver: zodResolver(schema),
    defaultValues: draftFromTopic(base),
    mode: 'onSubmit',
    reValidateMode: 'onChange',
  });
  const guard = useUnsavedChangesGuard(form.formState.isDirty, {
    message: 'Your question changes haven’t been published. Leave and lose them?',
  });
  const check = useMutation(checkTopicVersionMutation());
  const publish = useMutation(publishTopicVersionMutation());
  const [review, setReview] = useState<{
    report: CompatibilityReport;
    draft: VersionDraftOutput;
  } | null>(null);
  const [banner, setBanner] = useState<{ message: string; extra: FieldError[] } | null>(null);
  const [conflict, setConflict] = useState(false);
  const [reloading, setReloading] = useState(false);
  const topicPath = `/t/${base.slug}`;

  const labelFor = (key: string) =>
    form.getValues('questions').find((q) => q.key === key)?.label ||
    base.questions.find((q) => q.key === key)?.label ||
    key;

  const handleError = (err: unknown) => {
    if (isConflict(err)) {
      setReview(null);
      setConflict(true);
      return;
    }
    const mapped = mapApiError(err);
    const draft = form.getValues();
    const extra = applyFieldErrors(
      mapped.fieldErrors,
      (p) => builderFieldFor(p, draft),
      form.setError,
    );
    setReview(null);
    setBanner({ message: mapped.message, extra });
    window.scrollTo({ top: 0, behavior: 'smooth' });
  };

  const onReview = form.handleSubmit(
    async (draft) => {
      setBanner(null);
      try {
        const report = await check.mutateAsync({
          path: { ref: base.slug },
          body: { questions: draft.questions, base_version: base.current_version },
        });
        // Light up questions with blocking issues.
        const drafts = form.getValues('questions');
        for (const i of report.issues) {
          if (i.level !== 'error' || !i.question_key) continue;
          const idx = drafts.findIndex((d) => d.key === i.question_key);
          if (idx >= 0)
            form.setError(`questions.${idx}.key`, { type: 'compat', message: i.message });
        }
        setReview({ report, draft });
      } catch (err) {
        handleError(err);
      }
    },
    () => setBanner({ message: CLIENT_INVALID, extra: [] }),
  );

  const onPublish = async () => {
    if (!review) return;
    const note = form.getValues('change_note').trim();
    try {
      const updated = await publish.mutateAsync({
        path: { ref: base.slug },
        body: {
          questions: review.draft.questions,
          base_version: base.current_version,
          change_note: note,
        },
      });
      qc.setQueryData(getTopicQueryKey({ path: { ref: updated.slug } }), updated);
      void invalidateTopicData(qc);
      setReview(null);
      toast({ title: `Published v${updated.current_version}` });
      guard.allowNavigation();
      void navigate(`${topicPath}/versions`);
    } catch (err) {
      handleError(err);
    }
  };

  const reloadLatest = async () => {
    setReloading(true);
    try {
      const fresh = await qc.query({
        ...getTopicOptions({ path: { ref: base.slug } }),
        staleTime: 0,
      });
      void invalidateTopicData(qc);
      setConflict(false);
      onRebase(fresh);
      toast({
        title: `Loaded v${fresh.current_version}`,
        description: 'Your unsaved edits were discarded.',
        tone: 'info',
      });
    } catch (err) {
      toast({ title: 'Could not reload', description: mapApiError(err).message, tone: 'danger' });
    } finally {
      setReloading(false);
    }
  };

  return (
    <>
      <TopBar
        back={topicPath}
        title={
          <span className="flex items-center gap-2">
            <span className="truncate">Edit questions</span>
            <VersionTag version={base.current_version} />
          </span>
        }
      />
      <Page>
        <TopicBuilder
          form={form}
          defaultExpanded="new"
          onSubmit={(e) => void onReview(e)}
          header={
            <>
              <p className="text-sm text-muted">
                Publishing creates <strong className="text-ink">v{base.current_version + 1}</strong>{' '}
                of <strong className="text-ink">{base.name}</strong>. Published keys and types are
                fixed; enum options can be archived but not removed. Existing entries keep their
                original version.
              </p>
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
            </>
          }
          actions={
            <StickyActions>
              <Button
                type="submit"
                variant="primary"
                size="lg"
                className="flex-1 sm:flex-none"
                loading={check.isPending}
                icon={<Icon name="eye" />}
              >
                Review changes
              </Button>
            </StickyActions>
          }
        />
      </Page>

      <Sheet
        open={review !== null}
        onClose={() => setReview(null)}
        wide
        title="Review changes"
        description={`Compared with v${base.current_version}`}
        footer={
          <>
            <Button
              size="lg"
              className="sm:h-11 sm:px-5 sm:text-[0.95rem]"
              onClick={() => setReview(null)}
            >
              Keep editing
            </Button>
            <Button
              variant="primary"
              size="lg"
              className="sm:h-11 sm:px-5 sm:text-[0.95rem]"
              disabled={!review?.report.ok}
              loading={publish.isPending}
              onClick={() => void onPublish()}
            >
              Publish v{review?.report.next_version}
            </Button>
          </>
        }
      >
        {review ? (
          <div className="flex flex-col gap-5">
            <CompatReport report={review.report} labelFor={labelFor} />
            {review.report.ok ? (
              <Field
                label="Change note"
                optional
                error={form.formState.errors.change_note?.message}
              >
                {({ id, describedBy }) => (
                  <Textarea
                    id={id}
                    aria-describedby={describedBy}
                    rows={2}
                    maxLength={2000}
                    placeholder="What changed and why?"
                    {...form.register('change_note')}
                  />
                )}
              </Field>
            ) : null}
          </div>
        ) : null}
      </Sheet>

      <Sheet
        open={conflict}
        onClose={() => setConflict(false)}
        title="Someone else published first"
        description="This topic got a new version while you were editing."
        footer={
          <>
            <Button
              size="lg"
              className="sm:h-11 sm:px-5 sm:text-[0.95rem]"
              onClick={() => setConflict(false)}
            >
              Keep my draft
            </Button>
            <Button
              variant="primary"
              size="lg"
              className="sm:h-11 sm:px-5 sm:text-[0.95rem]"
              loading={reloading}
              onClick={() => void reloadLatest()}
            >
              Load latest version
            </Button>
          </>
        }
      >
        <p className="text-[0.95rem] text-ink-soft">
          Your edits were based on v{base.current_version}. Load the latest version to start again
          from it (your unsaved edits will be discarded), or keep your draft open to copy anything
          you need first.
        </p>
      </Sheet>
      {guard.dialog}
    </>
  );
}
