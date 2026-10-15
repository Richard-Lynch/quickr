import { useQuery } from '@tanstack/react-query';
import { useState } from 'react';
import { Link } from 'react-router';

import { lastEntryOptions } from '../../api/entries';
import { useQuickLog } from '../../api/quickLog';
import type { TopicSummary } from '../../client';
import { getTopicOptions } from '../../client/@tanstack/react-query.gen';
import { formatAnswer } from '../../lib/answerDisplay';
import { formatRelative } from '../../lib/dates';
import { plural } from '../../lib/format';
import { inputHints } from '../../lib/answerSchema';
import { initialNumber, parseQuickNumber, quickLogFor, type QuickLog } from '../../lib/quickLog';
import { dueView, type DueView } from '../../lib/schedule';
import type { NumericQuestion } from '../../lib/questions';
import { NumberInput } from '../answers/AnswerField';
import { Badge } from '../ui/Card';
import { cn } from '../ui/cn';
import { Icon } from '../ui/Icon';

/** Topic details are prefetched per tile: they power quick-log and an instant record screen. */
const DETAIL_STALE_MS = 5 * 60_000;

/** Values typed into number tiles but not logged yet survive navigating away and back. */
const numberDrafts = new Map<string, string>();

const DUE_TONE: Record<DueView['tone'], string> = {
  overdue: 'bg-danger-soft text-danger',
  due: 'bg-accent-soft text-accent-strong',
  soon: 'bg-warn-soft text-warn',
  later: 'bg-sunken text-ink-soft',
  none: '',
};

export function DueBadge({ view, className }: { view: DueView; className?: string }) {
  if (view.tone === 'none') return null;
  return (
    <span
      className={cn(
        'inline-flex h-6 items-center gap-1 rounded-full px-2.5 text-xs font-semibold whitespace-nowrap',
        DUE_TONE[view.tone],
        className,
      )}
    >
      <Icon
        name={view.tone === 'overdue' || view.tone === 'due' ? 'bell' : 'clock'}
        className="size-3.5"
        strokeWidth={2.4}
      />
      {view.label}
    </span>
  );
}

export function TopicTile({ topic: t, now }: { topic: TopicSummary; now: Date }) {
  const archived = t.status === 'archived';
  const detail = useQuery({
    ...getTopicOptions({ path: { ref: t.slug } }),
    staleTime: DETAIL_STALE_MS,
    enabled: !archived,
  });
  // Only trust details that match the list's version (a publish elsewhere = refetch).
  const questions =
    detail.data?.current_version === t.current_version ? detail.data.questions : null;
  const quick = !archived && questions ? quickLogFor(questions) : null;
  // Quick tiles show (and number tiles start from) the last answer.
  const last = useQuery({
    ...lastEntryOptions(t.slug),
    staleTime: DETAIL_STALE_MS,
    enabled: quick !== null && t.entry_count > 0,
  });
  const lastAnswer = quick
    ? last.data?.items[0]?.answers.find((a) => a.key === quick.question.key)
    : undefined;
  const lastText = quick && lastAnswer ? formatAnswer(quick.question, lastAnswer) : null;
  const due = dueView(t.due, now);
  const isDue = due.tone === 'due' || due.tone === 'overdue';
  const base = `/t/${t.slug}`;

  return (
    <article
      className={cn(
        'group relative flex overflow-hidden rounded-card border bg-surface shadow-card transition-[border-color] hover:border-line-strong',
        isDue ? 'border-accent/45' : 'border-line',
      )}
      aria-label={t.name}
    >
      {isDue ? <span aria-hidden className="absolute inset-y-0 left-0 w-1 bg-accent" /> : null}
      <div className="flex min-w-0 flex-1 flex-col gap-2.5 py-3.5 pr-3 pl-4">
        <div className="flex min-w-0 flex-col gap-1">
          <h2 className="font-display text-[1.2rem] leading-tight font-semibold tracking-tight">
            {/* The whole tile opens the topic; controls sit above this overlay. */}
            <Link to={base} className="after:absolute after:inset-0 after:rounded-card">
              {t.name}
            </Link>
          </h2>
          <div className="flex flex-wrap items-center gap-x-2 gap-y-1 text-[0.8rem] text-muted">
            <DueBadge view={due} />
            {archived ? (
              <Badge tone="warn">
                <Icon name="archive" className="size-3.5" /> Archived
              </Badge>
            ) : null}
            <span>
              {t.entry_count === 0 ? (
                'No entries yet'
              ) : lastText ? (
                <>
                  Last <strong className="font-semibold text-ink-soft">{lastText}</strong> ·{' '}
                  {formatRelative(t.last_captured_at, now)}
                </>
              ) : (
                `${plural(t.entry_count, 'entry', 'entries')} · ${formatRelative(t.last_captured_at, now)}`
              )}
            </span>
          </div>
        </div>
        {quick ? <QuickArea topic={t} quick={quick} last={lastAnswer?.value} /> : null}
      </div>
      {!archived ? (
        <Link
          to={`${base}/record`}
          aria-label={`Log ${t.name}`}
          className={cn(
            // Full-height, thumb-side action. Due topics get the loud version.
            'relative z-10 flex w-[5.25rem] shrink-0 flex-col items-center justify-center gap-1 border-l text-[0.95rem] font-semibold transition-[background-color,transform] select-none active:scale-[0.97]',
            isDue
              ? 'border-accent-strong/30 bg-accent text-on-accent hover:bg-accent-strong'
              : 'border-line bg-accent-soft text-accent-strong hover:brightness-[0.97]',
          )}
        >
          <Icon name="plus" className="size-6" strokeWidth={2.6} />
          Log
        </Link>
      ) : null}
    </article>
  );
}

function QuickArea({
  topic,
  quick,
  last,
}: {
  topic: TopicSummary;
  quick: QuickLog;
  last: unknown;
}) {
  return quick.kind === 'chips' ? (
    <QuickChips topic={topic} quick={quick} last={typeof last === 'string' ? last : null} />
  ) : (
    <QuickNumber topic={topic} question={quick.question} last={last} />
  );
}

/** How long a tapped chip stays lit as confirmation (the Undo toast has the details). */
const CONFIRM_MS = 1_600;

function QuickChips({
  topic,
  quick,
  last,
}: {
  topic: TopicSummary;
  quick: Extract<QuickLog, { kind: 'chips' }>;
  last: string | null;
}) {
  const log = useQuickLog();
  const [busy, setBusy] = useState<string | null>(null);
  const [logged, setLogged] = useState<string | null>(null);
  const n = quick.options.length;
  return (
    <div
      role="group"
      aria-label={`Log ${quick.question.label}`}
      className={cn(
        'relative z-10 grid gap-1.5',
        n === 1 ? 'grid-cols-1' : n % 3 === 0 && n > 3 ? 'grid-cols-3' : 'grid-cols-2',
      )}
    >
      {quick.options.map((o) => {
        const lit = logged === o.value;
        return (
          <button
            key={o.value}
            type="button"
            disabled={busy !== null}
            aria-busy={busy === o.value || undefined}
            aria-label={`Log ${o.label}${last === o.value ? ' (same as last time)' : ''}`}
            onClick={() => {
              setBusy(o.value);
              void log(topic, { [quick.question.key]: o.value }, { label: o.label })
                .then((r) => {
                  if (r.status === 'failed') return;
                  setLogged(o.value);
                  window.setTimeout(() => setLogged(null), CONFIRM_MS);
                })
                .finally(() => setBusy(null));
            }}
            className={cn(
              'relative flex min-h-11 items-center justify-center gap-1.5 rounded-xl border-2 px-2 py-1.5 text-[0.9rem] leading-tight font-semibold transition-[transform,background-color,border-color,color] active:scale-[0.96] active:border-accent active:bg-accent active:text-on-accent disabled:cursor-wait',
              lit
                ? 'border-ok bg-ok text-white'
                : 'border-line-strong bg-paper/60 text-ink hover:border-ink/40',
            )}
          >
            {lit ? <Icon name="check" className="size-4" strokeWidth={3} /> : null}
            {o.label}
            {last === o.value && !lit ? (
              <span
                aria-hidden
                title="Last time"
                className="absolute top-1 right-1 size-1.5 rounded-full bg-accent"
              />
            ) : null}
          </button>
        );
      })}
    </div>
  );
}

function QuickNumber({
  topic,
  question: q,
  last,
}: {
  topic: TopicSummary;
  question: NumericQuestion;
  last: unknown;
}) {
  const log = useQuickLog();
  const [typed, setTyped] = useState<string | null>(() => numberDrafts.get(topic.id) ?? null);
  const value = typed ?? initialNumber(q, last);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const hints = inputHints(q);
  const unit = q.unit ? q.unit : null;
  const setValue = (v: string) => {
    setTyped(v);
    numberDrafts.set(topic.id, v);
    setError(null);
  };

  const submit = () => {
    const parsed = parseQuickNumber(q, value);
    if (!parsed.ok) {
      setError(parsed.message);
      return;
    }
    setBusy(true);
    const label = `${value}${unit ? ` ${unit}` : ''}`;
    void log(topic, { [q.key]: parsed.value }, { label })
      .then((r) => {
        if (r.status !== 'failed') {
          numberDrafts.delete(topic.id);
          setTyped(null);
        }
      })
      .finally(() => setBusy(false));
  };

  return (
    <form
      className="relative z-10 flex flex-col gap-1"
      onSubmit={(e) => {
        e.preventDefault();
        submit();
      }}
      noValidate
    >
      <label htmlFor={`quick-${topic.id}`} className="text-xs font-medium text-muted">
        {q.label}
        {unit && unit.toLowerCase() !== q.label.toLowerCase() ? ` (${unit})` : ''}
      </label>
      <div className="flex items-stretch gap-1.5">
        <div className="min-w-0 flex-1 [&_button]:w-11 [&_input]:h-11 [&_input]:text-lg">
          <NumberInput
            id={`quick-${topic.id}`}
            value={value}
            onChange={setValue}
            step={hints.kind === 'number' ? hints.step : '1'}
            min={q.min ?? undefined}
            max={q.max ?? undefined}
            inputMode={hints.kind === 'number' ? hints.inputMode : 'decimal'}
            unit={null}
            invalid={error !== null}
            describedBy={error ? `quick-${topic.id}-err` : undefined}
            disabled={busy}
            integer={q.type === 'int'}
            inputRef={undefined}
            enterKeyHint="done"
          />
        </div>
        <button
          type="submit"
          disabled={busy || value.trim() === ''}
          aria-label={`Log ${value || q.label}${unit ? ` ${unit}` : ''}`}
          className="grid w-12 shrink-0 place-items-center rounded-xl bg-ink text-paper transition-transform active:scale-95 disabled:opacity-40"
        >
          <Icon name="check" className="size-5" strokeWidth={3} />
        </button>
      </div>
      {error ? (
        <p id={`quick-${topic.id}-err`} role="alert" className="text-xs font-medium text-danger">
          {error}
        </p>
      ) : null}
    </form>
  );
}
