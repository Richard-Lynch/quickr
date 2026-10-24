import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useMemo, useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router';

import { ENTRY_NOT_SAVED, lastEntryOptions, useRecordEntry } from '../../api/entries';
import { useUndoLog } from '../../api/quickLog';
import type { TopicDetail, TopicVersionOut } from '../../client';
import { canGoBack, Page, TopBar } from '../../components/AppShell';
import { EntryForm, type EntryFormValues, type Prefill } from '../../components/answers/EntryForm';
import { OfflineNotice } from '../../components/pwa/Sync';
import {
  contextFor,
  timerOf,
  useRunContext,
  useTopicVersions,
} from '../../components/runs/context';
import { activeMs } from '../../components/runs/model';
import { RunDetailsForm } from '../../components/runs/RunDetailsForm';
import { RunPanel, RunStart } from '../../components/runs/RunPanel';
import { useRunActions, type FinishResult } from '../../components/runs/useRunActions';
import { ButtonLink } from '../../components/ui/Button';
import { Banner, VersionTag } from '../../components/ui/Card';
import { cn } from '../../components/ui/cn';
import { Icon } from '../../components/ui/Icon';
import { ConfirmSheet } from '../../components/ui/Sheet';
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
import {
  isEntryCreate,
  isRunEvent,
  type EntryCreatePayload,
  type RunEventPayload,
} from '../../lib/outbox/kinds';
import { initialNumber, quickLogFor } from '../../lib/quickLog';
import type { OutboxItem } from '../../lib/outbox/types';
import { useOutbox } from '../../lib/outbox/useOutbox';
import { fmtDuration } from '../../lib/runs/format';
import { isOpen, openRunOf, runById, type LocalRun } from '../../lib/runs/localView';
import { useRuns } from '../../lib/runs/useRuns';
import type { Question } from '../../lib/questions';
import {
  readStored,
  rememberedSource,
  rememberSource,
  STORAGE_PREFIX,
  writeStored,
} from '../../lib/storage';
import { UNDO_WINDOW_MS } from '../../lib/undo';
import { useTopic } from './TopicLayout';

/** A queued answers event the Fix flow can correct: a finish, or a stop that carries answers. */
function isAnswersItem(item: OutboxItem): item is OutboxItem<RunEventPayload> {
  if (!isRunEvent(item)) return false;
  const e = item.payload.event;
  return e.type === 'finish' || (e.type === 'stop' && e.answers != null);
}

export function RecordPage() {
  const topic = useTopic();
  const [params] = useSearchParams();
  const fixId = params.get('fix');
  const { items, loaded } = useOutbox();
  const { runs } = useRuns();
  const versions = useTopicVersions(topic.id);
  const base = `/t/${topic.slug}`;
  // This topic's open or finishing run: it is shown whatever else is true.
  const run = runs.find((r) => r.topic_id === topic.id && (isOpen(r) || r.status === 'finishing'));

  if (topic.status === 'archived' && !run && !fixId) {
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
    if (item && isAnswersItem(item)) return <RunFix key={item.id} topic={topic} item={item} />;
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

  const timer = timerOf(versions.data, topic.current_version);
  if (!params.has('untimed') && (timer || run || params.has('finish'))) {
    return <TimedRecord topic={topic} versions={versions.data} />;
  }
  // Timed or not isn't known yet: wait for the versions, unless they can't come (offline).
  if (timer === undefined && versions.isPending && versions.fetchStatus === 'fetching') {
    return <PageSpinner />;
  }
  return <RecordForm key="new" topic={topic} fixItem={null} />;
}

function useLeave() {
  const navigate = useNavigate();
  return () => {
    if (canGoBack()) void navigate(-1);
    else void navigate('/', { replace: true });
  };
}

function questionsOf(
  topic: TopicDetail,
  versions: readonly TopicVersionOut[] | undefined,
  version: number,
): readonly Question[] | null {
  const v = versions?.find((x) => x.version === version);
  if (v) return v.questions;
  return version === topic.current_version ? topic.questions : null;
}

/**
 * A timed topic's Record page: the run panel while a run is open, the answers form after
 * Stop (`?finish={run id}&v={version}`) or for a finishing run ("Add details"), and Start
 * otherwise (timers.md §11.5).
 */
function TimedRecord({
  topic,
  versions,
}: {
  topic: TopicDetail;
  versions: readonly TopicVersionOut[] | undefined;
}) {
  const { runs } = useRuns({ timedPageVisible: true });
  const actions = useRunActions();
  const { toast } = useToast();
  const leave = useLeave();
  const [params, setParams] = useSearchParams();
  const ref = { id: topic.id, slug: topic.slug, name: topic.name };
  const finishId = params.get('finish');
  const finishVersion = Number(params.get('v') ?? topic.current_version);
  const open = openRunOf(runs, topic.id);
  const finishing = runs.find((r) => r.topic_id === topic.id && r.status === 'finishing');
  // The answers form: for the run Stop just ended, or for a finishing run. It stays up
  // while its finish is queued, when the local view already says the run is stopped.
  const wanted = finishId
    ? { id: finishId, version: finishVersion }
    : !open && finishing
      ? { id: finishing.id, version: finishing.version }
      : null;
  const [pinned, setPinned] = useState(wanted);
  if (wanted && wanted.id !== pinned?.id) setPinned(wanted);
  const target = wanted ?? (open ? null : pinned);
  const asked = target ? runById(runs, target.id) : undefined;
  const details =
    target && !(asked && isOpen(asked))
      ? { id: asked?.id ?? target.id, run: asked, version: asked?.version ?? target.version }
      : null;
  const shown: LocalRun | undefined = details ? details.run : open;
  const runCtx = useRunContext(shown, ref);
  const [confirmDiscard, setConfirmDiscard] = useState(false);

  const title = (
    <span className="flex items-center gap-2">
      <span className="truncate">{topic.name}</span>
      <VersionTag version={shown?.version ?? topic.current_version} className="max-sm:hidden" />
    </span>
  );

  const finished = (result: FinishResult | null) => {
    if (result?.status === 'sent') toast({ title: `Saved ${topic.name}` });
    else if (result?.status === 'queued') {
      toast({
        title: 'Saved on this device',
        description: 'It will sync automatically when you’re back online.',
        tone: 'info',
      });
    } else if (result?.status === 'retired') toast(ENTRY_NOT_SAVED);
    leave();
  };

  let content: React.ReactNode;
  if (details) {
    const ctx = runCtx ?? contextFor(ref, versions, details.version);
    const questions = questionsOf(topic, versions, details.version);
    const run = details.run;
    content =
      ctx && questions ? (
        <>
          <RunDetailsForm
            key={details.id}
            runId={details.id}
            ctx={ctx}
            questions={questions}
            finishing={run?.status === 'finishing'}
            totalMs={run?.state.ended_at != null ? activeMs(run.state, run.state.ended_at) : null}
            actions={actions}
            onDone={finished}
          />
          {run?.status === 'finishing' ? (
            <button
              type="button"
              onClick={() => setConfirmDiscard(true)}
              className="self-center text-sm font-semibold text-danger underline-offset-2 hover:underline"
            >
              Discard run
            </button>
          ) : null}
          <ConfirmSheet
            open={confirmDiscard}
            onClose={() => setConfirmDiscard(false)}
            onConfirm={() => {
              void actions.tap(details.id, ctx, 'discard').then((item) => {
                setConfirmDiscard(false);
                if (item) leave();
              });
            }}
            title="Discard this run?"
            body="Its times and answers won’t be saved. This can’t be undone."
            confirmLabel="Discard"
            cancelLabel="Keep"
            danger
            busy={actions.busy}
          />
        </>
      ) : (
        <PageSpinner label="Loading the run’s questions" />
      );
  } else if (open) {
    content = (
      <RunPanel
        run={open}
        ctx={runCtx}
        actions={actions}
        onStopped={(run, _item, totalMs) => {
          // Questions not known yet: open the form, which waits for them (as the tile does).
          const questions = questionsOf(topic, versions, run.version);
          if (questions === null || questions.length > 0) {
            setParams({ finish: run.id, v: String(run.version) }, { replace: true });
            return;
          }
          toast({ title: `Saved ${topic.name}: ${fmtDuration(totalMs)}` });
          leave();
        }}
        onDiscarded={() => {
          toast({ title: 'Run discarded', tone: 'info' });
          leave();
        }}
      />
    );
  } else {
    const ctx = contextFor(ref, versions, topic.current_version);
    const archived = topic.status === 'archived';
    content = (
      <RunStart
        steps={ctx?.steps ?? []}
        disabled={ctx === null || archived}
        busy={actions.busy}
        onStart={() => {
          if (ctx) void actions.start(ctx);
        }}
        note={
          ctx === null && !archived ? (
            <p className="text-center text-sm text-muted">
              This topic’s steps aren’t on this device yet. Start works once they’ve loaded.
            </p>
          ) : (
            <ButtonLink
              to={{ search: '?untimed=1' }}
              variant="ghost"
              size="sm"
              className="self-center"
            >
              Log without the timer
            </ButtonLink>
          )
        }
      />
    );
  }

  return (
    <>
      <TopBar back title={title} />
      <Page className="mx-auto max-w-2xl gap-4">
        <OfflineNotice what="Taps" />
        {content}
      </Page>
    </>
  );
}

/** Correct a failed finish (or stop with answers) from the sync sheet, and send it again. */
function RunFix({ topic, item }: { topic: TopicDetail; item: OutboxItem<RunEventPayload> }) {
  const versions = useTopicVersions(topic.id);
  const actions = useRunActions();
  const navigate = useNavigate();
  const { toast } = useToast();
  const p = item.payload;
  const ctx = {
    topic: p.topic,
    version: p.version,
    steps: p.steps,
    requires_answers: p.requires_answers,
  };
  const questions = questionsOf(topic, versions.data, p.version);
  const base = `/t/${topic.slug}`;
  return (
    <>
      <TopBar back={base} title={`Fix details · ${topic.name}`} />
      <Page className="mx-auto max-w-2xl gap-4">
        <OfflineNotice />
        {questions ? (
          <RunDetailsForm
            runId={p.run_id}
            ctx={ctx}
            questions={questions}
            finishing={false}
            totalMs={null}
            fixItem={item}
            actions={actions}
            onDone={(result) => {
              if (result?.status === 'sent') toast({ title: `Saved ${topic.name}` });
              void navigate(base);
            }}
          />
        ) : (
          <PageSpinner label="Loading the run’s questions" />
        )}
      </Page>
    </>
  );
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
