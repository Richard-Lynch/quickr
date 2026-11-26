import { useInfiniteQuery, useQuery } from '@tanstack/react-query';
import { useMemo } from 'react';
import { Link, useNavigate } from 'react-router';

import { errorMessage } from '../../api/errors';
import {
  getTopicStatsOptions,
  listEntriesInfiniteOptions,
  listTopicVersionsOptions,
} from '../../client/@tanstack/react-query.gen';
import type { EntryOut, Timer, TopicDetail, TopicVersionOut } from '../../client';
import { ChannelBadge } from '../../components/ChannelBadge';
import { FilterBar } from '../../components/FilterBar';
import { pendingTimedEntries } from '../../components/runs/model';
import { Button, buttonClass, ButtonLink } from '../../components/ui/Button';
import { Badge, Banner, Card, EmptyState, VersionTag } from '../../components/ui/Card';
import { Icon } from '../../components/ui/Icon';
import { Skeleton } from '../../components/ui/Spinner';
import { formatDateTime, formatRelative } from '../../lib/dates';
import { csvHref, filterQuery, useEntryFilters } from '../../lib/filters';
import { answerLabels, formatAnswer } from '../../lib/answerDisplay';
import { entrySummary } from '../../lib/entrySummary';
import { timingChip } from '../../lib/entryTiming';
import { plural } from '../../lib/format';
import { isEntryCreate, type EntryCreatePayload } from '../../lib/outbox/kinds';
import type { OutboxItem } from '../../lib/outbox/types';
import { useOutbox } from '../../lib/outbox/useOutbox';
import type { Question } from '../../lib/questions';
import { timingToWire } from '../../lib/runs/fold';
import { formatInstant } from '../../lib/runs/instant';
import { useRuns } from '../../lib/runs/useRuns';
import { useTopic } from './TopicLayout';

const PAGE = 25;

interface Column {
  key: string;
  label: string;
  question: Question;
}

/** Current questions first, then historic keys (latest definition wins). */
function columnsFor(
  current: readonly Question[],
  versions: readonly TopicVersionOut[] | undefined,
): Column[] {
  const cols = new Map<string, Column>();
  for (const q of current) cols.set(q.key, { key: q.key, label: q.label, question: q });
  const sorted = [...(versions ?? [])].sort((a, b) => b.version - a.version);
  for (const v of sorted) {
    for (const q of v.questions) {
      if (!cols.has(q.key)) cols.set(q.key, { key: q.key, label: q.label, question: q });
    }
  }
  return [...cols.values()];
}

/**
 * Each version's questions, for the summary line (content-display.md §1.2: labels come from
 * the entry's own version). A version not listed yet reads the topic's current questions.
 */
function questionsByVersion(
  topic: TopicDetail,
  versions: readonly TopicVersionOut[] | undefined,
): (version: number) => readonly Question[] {
  const byVersion = new Map((versions ?? []).map((v) => [v.version, v.questions]));
  return (version) => byVersion.get(version) ?? topic.questions;
}

/** What a row shows of the entry besides its answers: the summary line and the timing chip. */
interface RowText {
  questionsOf: (version: number) => readonly Question[];
  timer: Timer | null;
}

/** The entry's summary line (§3.1): one line, truncated; nothing when it is empty. */
function SummaryLine({ entry, text }: { entry: EntryOut; text: RowText }) {
  const summary = entrySummary(
    entry.answers,
    entry.timing,
    text.questionsOf(entry.version),
    text.timer,
  );
  if (!summary) return null;
  return (
    <p
      className="mb-2 truncate text-[0.95rem] font-medium"
      data-testid="entry-summary"
      title={summary}
    >
      {summary}
    </p>
  );
}

/**
 * A timed entry's chip, "12:40 · 3 laps", read as "12 minutes 40 seconds, 3 laps"; nothing for
 * an untimed entry (timers.md §11.1), an untimed entry of a timed topic too.
 */
function TimingChip({ entry, timer }: { entry: EntryOut; timer: Timer | null }) {
  const chip = timingChip(entry.timing, timer);
  if (!chip) return null;
  return (
    <span role="img" aria-label={chip.label} data-testid="entry-timing" className="inline-flex">
      <Badge tone="accent">
        <Icon name="timer" className="size-3.5" />
        <span className="tabular">{chip.text}</span>
      </Badge>
    </span>
  );
}

/** The chip on a phone card, spaced above the answers. */
function RowChip({ entry, timer }: { entry: EntryOut; timer: Timer | null }) {
  if (!entry.timing) return null;
  return (
    <div className="mb-3">
      <TimingChip entry={entry} timer={timer} />
    </div>
  );
}

function display(col: Column, s: EntryOut): string | null {
  const a = s.answers.find((x) => x.key === col.key);
  return a ? formatAnswer(col.question, a) : null;
}

/** Queued answers (`{key: value}`) as stored answers, typed by the topic's questions. */
function answersOut(
  topic: TopicDetail,
  map: Readonly<Record<string, unknown>>,
): EntryOut['answers'] {
  const types = new Map(topic.questions.map((q) => [q.key, q.type]));
  return Object.entries(map).flatMap(([key, value]) => {
    const type = types.get(key);
    if (!type || value === null) return [];
    return [{ key, type: type === 'enum' && Array.isArray(value) ? 'enum_list' : type, value }];
  }) as EntryOut['answers'];
}

/** A queued (not yet synced) entry, shaped like a stored one so it renders the same way. */
function pendingAsEntry(item: OutboxItem<EntryCreatePayload>, topic: TopicDetail): EntryOut {
  const b = item.payload.body;
  const answers = answersOut(topic, b.answers);
  return {
    id: item.id,
    topic_id: topic.id,
    version: b.version ?? topic.current_version,
    revision: 0, // not on the server yet
    source: b.source ?? 'ui',
    channel: 'ui',
    captured_at: b.captured_at ?? item.created_at,
    created_at: item.created_at,
    updated_at: item.updated_at,
    notes: b.notes ?? '',
    meta: b.meta ?? {},
    answers,
    timing: null, // createEntry makes untimed entries
  };
}

/** The fields `AnswerGrid` doesn't read, for an entry that exists only on this device. */
function pendingAsEntryShape(topic: TopicDetail, id: string): EntryOut {
  const now = new Date().toISOString();
  return {
    id,
    topic_id: topic.id,
    version: topic.current_version,
    revision: 0,
    source: 'ui',
    channel: 'ui',
    captured_at: now,
    created_at: now,
    updated_at: now,
    notes: '',
    meta: {},
    answers: [],
    timing: null,
  };
}

function AnswerGrid({ columns, entry }: { columns: Column[]; entry: EntryOut }) {
  return (
    <dl className="grid grid-cols-2 gap-x-4 gap-y-2">
      {columns.map((c) => {
        const v = display(c, entry);
        if (v === null) return null;
        const a = entry.answers.find((x) => x.key === c.key);
        if (a && Array.isArray(a.value)) {
          return (
            <div key={c.key} className="col-span-2">
              <dt className="truncate text-xs text-muted">{c.label}</dt>
              <dd className="mt-0.5 flex flex-wrap gap-1">
                {answerLabels(c.question, a).map((l) => (
                  <Badge key={l} tone="accent">
                    {l}
                  </Badge>
                ))}
              </dd>
            </div>
          );
        }
        return (
          <div key={c.key} className={c.question.type === 'str' ? 'col-span-2' : undefined}>
            <dt className="truncate text-xs text-muted">{c.label}</dt>
            <dd
              className={
                c.question.type === 'str'
                  ? 'line-clamp-2 text-sm'
                  : c.question.type === 'enum'
                    ? 'text-[0.95rem] font-semibold'
                    : 'font-mono text-[0.95rem] font-semibold tabular'
              }
            >
              {v}
            </dd>
          </div>
        );
      })}
    </dl>
  );
}

/**
 * Entries recorded on this device that the server hasn't confirmed yet: queued creates,
 * and the entries queued Stops will make (timers.md §8.3). A run's optimistic entry has
 * the run's id, so it is dropped as soon as the server's entry with that id is listed.
 */
function PendingEntries({
  topic,
  columns,
  serverIds,
  text,
}: {
  topic: TopicDetail;
  columns: Column[];
  serverIds: ReadonlySet<string>;
  text: RowText;
}) {
  const { items } = useOutbox();
  const { runs } = useRuns();
  const mine = items.filter(
    (i): i is OutboxItem<EntryCreatePayload> => isEntryCreate(i) && i.payload.topic.id === topic.id,
  );
  const timed = pendingTimedEntries(runs, topic.id, serverIds);
  if (mine.length === 0 && timed.length === 0) return null;
  return (
    <ul className="flex flex-col gap-3" aria-label="Not yet synced">
      {timed.map((e) => {
        const entry: EntryOut = {
          ...pendingAsEntryShape(topic, e.id),
          version: e.version,
          answers: answersOut(topic, e.answers),
          // The local fold's timing, in the server's wire shape.
          timing: { ...timingToWire(e.timing), skipped: [...e.timing.skipped] },
        };
        return (
          <li key={e.id}>
            <Card className="relative border-dashed border-line-strong p-4">
              <div className="mb-3 flex items-center gap-2">
                <span className="min-w-0 flex-1 truncate font-semibold">
                  {formatDateTime(formatInstant(e.captured_at))}
                </span>
                <Badge tone="info">
                  <Icon name="clock" className="size-3.5" /> Waiting to sync
                </Badge>
              </div>
              <SummaryLine entry={entry} text={text} />
              <RowChip entry={entry} timer={text.timer} />
              <AnswerGrid columns={columns} entry={entry} />
            </Card>
          </li>
        );
      })}
      {mine.map((item) => {
        const s = pendingAsEntry(item, topic);
        const failed = item.status === 'failed';
        return (
          <li key={item.id}>
            <Card
              className={
                failed
                  ? 'relative border-danger/40 bg-danger-soft/30 p-4'
                  : 'relative border-dashed border-line-strong p-4'
              }
            >
              <div className="mb-3 flex items-center gap-2">
                {failed ? (
                  <Link
                    to={`/t/${topic.slug}/record?fix=${encodeURIComponent(item.id)}`}
                    className="min-w-0 flex-1 truncate font-semibold after:absolute after:inset-0"
                  >
                    {formatDateTime(s.captured_at)}
                  </Link>
                ) : (
                  <span className="min-w-0 flex-1 truncate font-semibold">
                    {formatDateTime(s.captured_at)}
                  </span>
                )}
                {failed ? (
                  <Badge tone="danger">
                    <Icon name="alert" className="size-3.5" /> Failed — tap to fix
                  </Badge>
                ) : (
                  <Badge tone="info">
                    <Icon name="clock" className="size-3.5" /> Waiting to sync
                  </Badge>
                )}
              </div>
              <SummaryLine entry={s} text={text} />
              <AnswerGrid columns={columns} entry={s} />
              {failed && item.last_error ? (
                <p className="mt-3 border-t border-dashed border-danger/30 pt-2 text-sm text-danger">
                  {item.last_error.message}
                </p>
              ) : null}
            </Card>
          </li>
        );
      })}
    </ul>
  );
}

export function EntriesPage() {
  const topic = useTopic();
  const navigate = useNavigate();
  const [filters, setFilters] = useEntryFilters();
  const fq = filterQuery(filters);
  const versions = useQuery(listTopicVersionsOptions({ path: { ref: topic.slug } }));
  const stats = useQuery(getTopicStatsOptions({ path: { ref: topic.slug } }));
  const entries = useInfiniteQuery({
    ...listEntriesInfiniteOptions({
      path: { ref: topic.slug },
      query: { ...fq, limit: PAGE, order: '-captured_at' },
    }),
    initialPageParam: 0,
    getNextPageParam: (last) =>
      last.offset + last.items.length < last.total ? last.offset + last.items.length : undefined,
  });

  const columns = useMemo(
    () => columnsFor(topic.questions, versions.data),
    [topic.questions, versions.data],
  );
  const text = useMemo<RowText>(
    () => ({ questionsOf: questionsByVersion(topic, versions.data), timer: topic.timer }),
    [topic, versions.data],
  );
  const items = entries.data?.pages.flatMap((p) => p.items) ?? [];
  const serverIds = new Set(items.map((e) => e.id.toLowerCase()));
  const total = entries.data?.pages[0]?.total ?? 0;
  const outbox = useOutbox();
  const queuedHere = outbox.items.filter(
    (i) => isEntryCreate(i) && i.payload.topic.id === topic.id,
  ).length;
  const base = `/t/${topic.slug}`;
  const open = (s: EntryOut) => void navigate(`${base}/entries/${s.id}`);

  return (
    <>
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <FilterBar
          filters={filters}
          onChange={setFilters}
          versions={versions.data?.map((v) => v.version).sort((a, b) => b - a) ?? []}
          sources={stats.data?.sources.map((s) => s.value) ?? []}
        />
        <a
          href={csvHref(topic.slug, filters)}
          download
          className={buttonClass('secondary', 'sm', 'self-start')}
        >
          <Icon name="download" className="size-4" />
          Export CSV
        </a>
      </div>

      <p className="-mt-2 text-sm text-muted" aria-live="polite">
        {entries.isSuccess
          ? `${plural(total, 'entry', 'entries')}${queuedHere ? ` · ${queuedHere} not synced yet` : ''}`
          : ' '}
      </p>

      <PendingEntries topic={topic} columns={columns} serverIds={serverIds} text={text} />

      {entries.isError ? (
        <Banner title="Could not load entries">{errorMessage(entries.error)}</Banner>
      ) : entries.isPending ? (
        <div className="flex flex-col gap-3">
          {Array.from({ length: 4 }, (_, i) => (
            <Skeleton key={i} className="h-28 rounded-card" />
          ))}
        </div>
      ) : items.length === 0 && queuedHere > 0 ? null : items.length === 0 ? (
        <EmptyState
          title={topic.entry_count === 0 ? 'No entries yet' : 'No entries match'}
          action={
            topic.status === 'active' ? (
              <ButtonLink to={`${base}/record`} variant="primary" icon={<Icon name="plus" />}>
                Log one
              </ButtonLink>
            ) : null
          }
        >
          {topic.entry_count === 0
            ? 'Entries you log show up here.'
            : 'Try a wider date range or clear the filters.'}
        </EmptyState>
      ) : (
        <>
          {/* phones: cards */}
          <ul className="flex flex-col gap-3 md:hidden">
            {items.map((s) => (
              <li key={s.id}>
                <Card className="relative p-4 active:scale-[0.99]">
                  <div className="mb-3 flex items-center gap-2">
                    <Link
                      to={`${base}/entries/${s.id}`}
                      className="min-w-0 flex-1 truncate font-semibold after:absolute after:inset-0"
                    >
                      {formatDateTime(s.captured_at)}
                    </Link>
                    {s.version !== topic.current_version ? (
                      <VersionTag version={s.version} />
                    ) : null}
                    <Icon name="chevronRight" className="size-4 text-muted" />
                  </div>
                  <SummaryLine entry={s} text={text} />
                  <RowChip entry={s} timer={text.timer} />
                  <AnswerGrid columns={columns} entry={s} />
                  {s.notes ? (
                    <p className="mt-3 line-clamp-2 border-t border-dashed border-line pt-2 text-sm text-ink-soft">
                      {s.notes}
                    </p>
                  ) : null}
                  <div className="mt-3 flex items-center gap-2 text-xs text-muted">
                    <Badge>{s.source}</Badge>
                    <ChannelBadge channel={s.channel} showUi={false} />
                    <span>{formatRelative(s.captured_at)}</span>
                  </div>
                </Card>
              </li>
            ))}
          </ul>

          {/* tablet / desktop: table */}
          <Card className="hidden overflow-x-auto md:block">
            <table className="w-full text-left text-sm">
              <thead className="border-b border-line text-xs tracking-wide text-muted uppercase">
                <tr>
                  <th scope="col" className="px-4 py-3 font-semibold whitespace-nowrap">
                    Captured
                  </th>
                  <th scope="col" className="px-3 py-3 font-semibold whitespace-nowrap">
                    Timing
                  </th>
                  {columns.map((c) => (
                    <th
                      key={c.key}
                      scope="col"
                      className="max-w-48 truncate px-3 py-3 font-semibold"
                      title={c.label}
                    >
                      {c.label}
                    </th>
                  ))}
                  <th scope="col" className="px-3 py-3 font-semibold">
                    Source
                  </th>
                  <th scope="col" className="px-3 py-3 font-semibold">
                    v
                  </th>
                  <th scope="col" className="w-10">
                    <span className="sr-only">Edit</span>
                  </th>
                </tr>
              </thead>
              <tbody className="divide-y divide-line">
                {items.map((s) => (
                  <tr
                    key={s.id}
                    className="cursor-pointer transition-colors hover:bg-sunken/60"
                    onClick={() => open(s)}
                  >
                    <td className="px-4 py-3 whitespace-nowrap">{formatDateTime(s.captured_at)}</td>
                    <td className="px-3 py-3 whitespace-nowrap">
                      {s.timing ? (
                        <TimingChip entry={s} timer={text.timer} />
                      ) : (
                        <span className="text-muted/60">—</span>
                      )}
                    </td>
                    {columns.map((c) => {
                      const v = display(c, s);
                      return (
                        <td
                          key={c.key}
                          className={
                            c.question.type === 'str'
                              ? 'max-w-56 truncate px-3 py-3'
                              : c.question.type === 'enum'
                                ? 'px-3 py-3 font-medium whitespace-nowrap'
                                : 'px-3 py-3 font-mono font-semibold whitespace-nowrap tabular'
                          }
                          title={v ?? undefined}
                        >
                          {v ?? <span className="text-muted/60">—</span>}
                        </td>
                      );
                    })}
                    <td className="px-3 py-3 text-muted">
                      <span className="inline-flex items-center gap-1.5">
                        {s.source}
                        <ChannelBadge channel={s.channel} showUi={false} />
                      </span>
                    </td>
                    <td className="px-3 py-3 font-mono text-muted">{s.version}</td>
                    <td className="pr-3">
                      <Link
                        to={`${base}/entries/${s.id}`}
                        onClick={(e) => e.stopPropagation()}
                        className="grid size-8 place-items-center rounded-full text-muted hover:bg-surface hover:text-ink"
                        aria-label={`Edit entry from ${formatDateTime(s.captured_at)}`}
                      >
                        <Icon name="edit" className="size-4" />
                      </Link>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </Card>

          {entries.hasNextPage ? (
            <div className="flex justify-center">
              <Button
                onClick={() => void entries.fetchNextPage()}
                loading={entries.isFetchingNextPage}
              >
                Load more
              </Button>
            </div>
          ) : null}
        </>
      )}
    </>
  );
}
