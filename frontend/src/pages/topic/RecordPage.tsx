import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useMemo, useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router';

import { ENTRY_NOT_SAVED, lastEntryOptions, useRecordEntry } from '../../api/entries';
import { useUndoLog } from '../../api/quickLog';
import type { TopicDetail } from '../../client';
import { canGoBack, Page, TopBar } from '../../components/AppShell';
import { EntryForm, type EntryFormValues, type Prefill } from '../../components/answers/EntryForm';
import { OfflineNotice } from '../../components/pwa/Sync';
import { ButtonLink } from '../../components/ui/Button';
import { Banner, VersionTag } from '../../components/ui/Card';
import { cn } from '../../components/ui/cn';
import { Icon } from '../../components/ui/Icon';
import { PageSpinner } from '../../components/ui/Spinner';
import { useToast } from '../../components/ui/Toast';
import { formatAnswer } from '../../lib/answerDisplay';
import {
  answerValuesFromMap,
  compactAnswers,
  emptyAnswerValues,
  hasInput,
  reusableValuesFromEntry,
} from '../../lib/answerSchema';
import { toLocalInputValue } from '../../lib/dates';
import { isEntryCreate, type EntryCreatePayload } from '../../lib/outbox/kinds';
import { initialNumber, quickLogFor } from '../../lib/quickLog';
import type { OutboxItem } from '../../lib/outbox/types';
import { useOutbox } from '../../lib/outbox/useOutbox';
import {
  readStored,
  rememberedSource,
  rememberSource,
  STORAGE_PREFIX,
  writeStored,
} from '../../lib/storage';
import { UNDO_WINDOW_MS } from '../../lib/undo';
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
            Unarchive it to log new entries.
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
          <TopBar back={`${base}/entries`} title="Fix entry" />
          <Page>
            <Banner
              tone="info"
              title="Nothing to fix"
              action={
                <ButtonLink to={`${base}/entries`} size="sm">
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

/** After saving: back to where you came from (default), or stay for another entry. */
const AFTER_LOG_KEY = `${STORAGE_PREFIX}logAnother`;

function RecordForm({
  topic,
  fixItem,
}: {
  topic: TopicDetail;
  fixItem: OutboxItem<EntryCreatePayload> | null;
}) {
  const qc = useQueryClient();
  const navigate = useNavigate();
  const { toast } = useToast();
  const record = useRecordEntry();
  const undo = useUndoLog();
  const [count, setCount] = useState(0);
  const [another, setAnother] = useState(() => readStored(AFTER_LOG_KEY) === '1');
  const base = `/t/${topic.slug}`;

  // The latest entry, for "Same as last time" (shared with the number tiles' prefill).
  const last = useQuery({
    ...lastEntryOptions(topic.slug),
    enabled: fixItem === null,
  });
  const prefill = useMemo((): Prefill | null => {
    const entry = last.data?.items[0];
    if (!entry || fixItem) return null;
    const values = reusableValuesFromEntry(topic.questions, entry.answers);
    if (!topic.questions.some((q) => hasInput(values[q.key]))) return null;
    const summary = topic.questions
      .flatMap((q) => {
        const a = entry.answers.find((x) => x.key === q.key);
        const text = a ? formatAnswer(q, a) : null;
        return text && hasInput(values[q.key]) ? [text] : [];
      })
      .join(' · ');
    return { values, capturedAt: entry.captured_at, summary };
  }, [last.data, topic.questions, fixItem]);

  const freshValues = useMemo(
    () =>
      (source: string): EntryFormValues => ({
        answers: emptyAnswerValues(topic.questions),
        captured_at: toLocalInputValue(new Date()),
        source,
        notes: '',
      }),
    [topic.questions],
  );
  const [defaults] = useState<EntryFormValues>(() => {
    if (!fixItem) {
      const fresh = freshValues(rememberedSource());
      // A single-number topic starts from the last value, like its tile does: from a
      // notification that's one tap (Save) when nothing changed.
      const quick = topic.questions.length === 1 ? quickLogFor(topic.questions) : null;
      if (quick?.kind === 'number') {
        const cached = qc.getQueryData(lastEntryOptions(topic.slug).queryKey);
        const v = cached?.items[0]?.answers.find((a) => a.key === quick.question.key)?.value;
        const start = initialNumber(quick.question, v);
        if (start) fresh.answers[quick.question.key] = start;
      }
      return fresh;
    }
    const b = fixItem.payload.body;
    return {
      answers: answerValuesFromMap(topic.questions, b.answers),
      captured_at: toLocalInputValue(new Date(b.captured_at ?? fixItem.created_at)),
      source: b.source ?? rememberedSource(),
      notes: b.notes ?? '',
    };
  });

  // A single-select-only topic: the pick is the whole entry, so it saves on tap.
  const only = topic.questions.length === 1 ? topic.questions[0] : undefined;
  const pickKey =
    !fixItem && only && quickLogFor(topic.questions)?.kind === 'chips' ? only.key : undefined;

  const leave = () => {
    if (canGoBack()) void navigate(-1);
    else void navigate('/', { replace: true });
  };

  return (
    <>
      <TopBar
        back={fixItem ? `${base}/entries` : true}
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
      <Page className="mx-auto max-w-2xl gap-4">
        <OfflineNotice />
        {fixItem ? (
          <Banner tone="info" title="This entry was not saved">
            The server rejected it. Correct it and save again, or discard it from the sync list.
          </Banner>
        ) : null}
        <EntryForm
          questions={topic.questions}
          defaultValues={defaults}
          submitLabel={fixItem ? 'Save again' : 'Save'}
          initialError={fixItem?.last_error?.body ?? undefined}
          prefill={prefill}
          focusFirstEmpty={!fixItem}
          submitOnPick={pickKey}
          {...(fixItem || !another ? {} : { resetOnSuccess: (v) => freshValues(v.source) })}
          secondaryAction={
            fixItem ? null : (
              <button
                type="button"
                aria-pressed={another}
                onClick={() => {
                  setAnother((a) => {
                    writeStored(AFTER_LOG_KEY, a ? '0' : '1');
                    return !a;
                  });
                }}
                className={cn(
                  'flex h-14 shrink-0 items-center gap-2 rounded-full border px-4 text-sm font-semibold transition-colors',
                  another
                    ? 'border-ink bg-ink text-paper'
                    : 'border-line-strong bg-surface text-ink-soft',
                )}
                title="Stay on this screen after saving"
              >
                <span
                  aria-hidden
                  className={cn(
                    'grid size-5 place-items-center rounded-md border-2',
                    another ? 'border-paper bg-paper text-ink' : 'border-line-strong',
                  )}
                >
                  {another ? <Icon name="check" className="size-3.5" strokeWidth={3.2} /> : null}
                </span>
                Log another
              </button>
            )
          }
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
            // Rejected (4xx): EntryForm maps the Problem onto the fields.
            if (result.status === 'failed') throw result.error;
            if (result.status === 'retired') {
              allowNavigation();
              toast(ENTRY_NOT_SAVED);
              if (fixItem) void navigate(`${base}/entries`);
              else leave();
              return;
            }

            rememberSource(v.source);
            const saved =
              result.status === 'sent'
                ? { title: `Logged ${topic.name}` }
                : {
                    title: 'Saved on this device',
                    description: 'It will sync automatically when you’re back online.',
                    tone: 'info' as const,
                  };
            if (fixItem) {
              allowNavigation();
              toast(saved);
              void navigate(`${base}/entries`);
              return;
            }
            toast({
              ...saved,
              duration: UNDO_WINDOW_MS,
              action: {
                label: 'Undo',
                onClick: () => void undo(result.itemId, topic),
              },
            });
            if (another) {
              setCount((c) => c + 1);
              window.scrollTo({ top: 0, behavior: 'smooth' });
              return;
            }
            allowNavigation();
            leave();
          }}
        />
      </Page>
    </>
  );
}
