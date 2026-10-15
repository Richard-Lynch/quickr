import { useMemo, useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router';

import { useRecordEntry } from '../../api/entries';
import type { TopicDetail } from '../../client';
import { Page, TopBar } from '../../components/AppShell';
import { SessionForm, type SessionFormValues } from '../../components/answers/SessionForm';
import { OfflineNotice } from '../../components/pwa/Sync';
import { ButtonLink } from '../../components/ui/Button';
import { Banner, VersionTag } from '../../components/ui/Card';
import { PageSpinner } from '../../components/ui/Spinner';
import { useToast } from '../../components/ui/Toast';
import { answerValuesFromMap, compactAnswers, emptyAnswerValues } from '../../lib/answerSchema';
import { toLocalInputValue } from '../../lib/dates';
import { isEntryCreate, type EntryCreatePayload } from '../../lib/outbox/kinds';
import type { OutboxItem } from '../../lib/outbox/types';
import { useOutbox } from '../../lib/outbox/useOutbox';
import { rememberedSource, rememberSource } from '../../lib/storage';
import { useTopic } from './TopicLayout';

export function RecordPage() {
  const topic = useTopic();
  const [params] = useSearchParams();
  const fixId = params.get('fix');
  const { items, loaded } = useOutbox();
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

  if (fixId) {
    if (!loaded) return <PageSpinner />;
    const item = items.find((i) => i.id === fixId);
    if (!item || !isEntryCreate(item)) {
      return (
        <>
          <TopBar back={`${base}/sessions`} title="Fix entry" />
          <Page>
            <Banner
              tone="info"
              title="Nothing to fix"
              action={
                <ButtonLink to={`${base}/sessions`} size="sm">
                  Entries
                </ButtonLink>
              }
            >
              This entry has already been synced or discarded.
            </Banner>
          </Page>
        </>
      );
    }
    return <RecordForm key={item.id} topic={topic} fixItem={item} />;
  }

  return <RecordForm key="new" topic={topic} fixItem={null} />;
}

function RecordForm({
  topic,
  fixItem,
}: {
  topic: TopicDetail;
  fixItem: OutboxItem<EntryCreatePayload> | null;
}) {
  const navigate = useNavigate();
  const { toast } = useToast();
  const record = useRecordEntry();
  const [count, setCount] = useState(0);
  const base = `/t/${topic.slug}`;

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
  const [defaults] = useState<SessionFormValues>(() => {
    if (!fixItem) return freshValues(rememberedSource());
    const b = fixItem.payload.body;
    return {
      answers: answerValuesFromMap(topic.questions, b.answers),
      captured_at: toLocalInputValue(new Date(b.captured_at ?? fixItem.created_at)),
      source: b.source ?? rememberedSource(),
      notes: b.notes ?? '',
    };
  });

  return (
    <>
      <TopBar
        back={fixItem ? `${base}/sessions` : base}
        title={
          <span className="flex items-center gap-2">
            <span className="truncate">{fixItem ? `Fix entry · ${topic.name}` : topic.name}</span>
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
        <OfflineNotice />
        {fixItem ? (
          <Banner tone="info" title="This entry was not saved">
            The server rejected it. Correct it and save again, or discard it from the sync list.
          </Banner>
        ) : null}
        <SessionForm
          questions={topic.questions}
          defaultValues={defaults}
          submitLabel={fixItem ? 'Save again' : 'Save entry'}
          initialError={fixItem?.last_error?.body ?? undefined}
          {...(fixItem ? {} : { resetOnSuccess: (v) => freshValues(v.source) })}
          onSubmit={async (v, { allowNavigation }) => {
            const result = await record(
              { id: topic.id, slug: topic.slug, name: topic.name },
              {
                answers: compactAnswers(v.answers),
                captured_at: v.captured_at,
                source: v.source,
                notes: v.notes,
                version: topic.current_version,
              },
              { fixItemId: fixItem?.id },
            );
            // Rejected (4xx): SessionForm maps the Problem onto the fields.
            if (result.status === 'failed') throw result.error;

            rememberSource(v.source);
            const view = { label: 'View', onClick: () => void navigate(`${base}/sessions`) };
            const saved =
              result.status === 'sent'
                ? { title: 'Entry saved', description: 'Ready for the next one.' }
                : {
                    title: 'Saved on this device',
                    description: 'It will sync automatically when you’re back online.',
                    tone: 'info' as const,
                  };
            if (fixItem) {
              allowNavigation();
              toast({ ...saved, description: undefined });
              void navigate(`${base}/sessions`);
              return;
            }
            setCount((c) => c + 1);
            window.scrollTo({ top: 0, behavior: 'smooth' });
            toast({ ...saved, action: view });
          }}
        />
      </Page>
    </>
  );
}
