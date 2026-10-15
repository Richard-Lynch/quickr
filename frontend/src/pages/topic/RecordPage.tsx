import { useMutation, useQueryClient } from '@tanstack/react-query';
import { useMemo, useState } from 'react';
import { useNavigate } from 'react-router';

import { invalidateSessionData } from '../../api/queryClient';
import { createSessionMutation } from '../../client/@tanstack/react-query.gen';
import { Page, TopBar } from '../../components/AppShell';
import { SessionForm, type SessionFormValues } from '../../components/answers/SessionForm';
import { ButtonLink } from '../../components/ui/Button';
import { Banner, VersionTag } from '../../components/ui/Card';
import { useToast } from '../../components/ui/Toast';
import { compactAnswers, emptyAnswerValues } from '../../lib/answerSchema';
import { toLocalInputValue } from '../../lib/dates';
import { rememberedSource, rememberSource } from '../../lib/storage';
import { useTopic } from './TopicLayout';

export function RecordPage() {
  const topic = useTopic();
  const qc = useQueryClient();
  const navigate = useNavigate();
  const { toast } = useToast();
  const [count, setCount] = useState(0);
  const create = useMutation(createSessionMutation());

  const freshValues = useMemo(
    () =>
      (source: string): SessionFormValues => ({
        answers: emptyAnswerValues(topic.questions),
        captured_at: toLocalInputValue(new Date()),
        source,
        notes: '',
      }),
    [topic.questions],
  );
  const [defaults] = useState(() => freshValues(rememberedSource()));
  const base = `/t/${topic.slug}`;

  if (topic.status === 'archived') {
    return (
      <>
        <TopBar back={base} title={topic.name} />
        <Page>
          <Banner
            tone="warn"
            title="This topic is archived"
            action={
              <ButtonLink to={`${base}/settings`} size="sm">
                Settings
              </ButtonLink>
            }
          >
            Unarchive it to record new entries.
          </Banner>
        </Page>
      </>
    );
  }

  return (
    <>
      <TopBar
        back={base}
        title={
          <span className="flex items-center gap-2">
            <span className="truncate">{topic.name}</span>
            <VersionTag version={topic.current_version} className="max-sm:hidden" />
          </span>
        }
        actions={
          count > 0 ? (
            <span className="mr-2 rounded-full bg-ok-soft px-2.5 py-1 font-mono text-xs font-semibold text-ok">
              +{count}
            </span>
          ) : null
        }
      />
      <Page className="mx-auto max-w-2xl">
        <SessionForm
          questions={topic.questions}
          defaultValues={defaults}
          submitLabel="Save entry"
          resetOnSuccess={(v) => freshValues(v.source)}
          onSubmit={async (v) => {
            await create.mutateAsync({
              path: { ref: topic.slug },
              body: {
                answers: compactAnswers(v.answers),
                captured_at: v.captured_at,
                source: v.source,
                notes: v.notes,
                version: topic.current_version,
              },
            });
            rememberSource(v.source);
            setCount((c) => c + 1);
            void invalidateSessionData(qc);
            window.scrollTo({ top: 0, behavior: 'smooth' });
            toast({
              title: 'Entry saved',
              description: 'Ready for the next one.',
              action: { label: 'View', onClick: () => void navigate(`${base}/sessions`) },
            });
          }}
        />
      </Page>
    </>
  );
}
