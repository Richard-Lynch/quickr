/**
 * The answers form after Stop (timers.md §3.6, §11.2): the run's version's questions and
 * notes, sent as `finish`. It serves a finishing run ("Add details"), a stopped run whose
 * version has optional questions, and the Fix of a failed finish.
 */
import { useState } from 'react';

import type { RunEventPayload } from '../../lib/outbox/kinds';
import type { OutboxItem } from '../../lib/outbox/types';
import { answerValuesFromMap, compactAnswers, emptyAnswerValues } from '../../lib/answerSchema';
import { toLocalInputValue } from '../../lib/dates';
import type { RunContext } from '../../lib/runs/actions';
import type { Question } from '../../lib/questions';
import { EntryForm, type EntryFormValues } from '../answers/EntryForm';
import { Banner } from '../ui/Card';
import { Duration } from './RunClock';
import type { FinishResult, RunActions } from './useRunActions';

export function RunDetailsForm({
  runId,
  ctx,
  questions,
  finishing,
  totalMs,
  fixItem,
  actions,
  onDone,
}: {
  runId: string;
  ctx: RunContext;
  /** The run's version's questions. */
  questions: readonly Question[];
  /** The run is finishing: it has no entry until this form is saved. */
  finishing: boolean;
  /** The run's active time, when known. */
  totalMs: number | null;
  /** A failed finish to correct and send again. */
  fixItem?: OutboxItem<RunEventPayload> | null;
  actions: RunActions;
  /** Saved (with its result) or put off (`null`). The form allows navigation first. */
  onDone: (result: FinishResult | null) => void;
}) {
  const [defaults] = useState<EntryFormValues>(() => {
    const e = fixItem?.payload.event;
    return {
      answers: e?.answers
        ? answerValuesFromMap(questions, e.answers)
        : emptyAnswerValues(questions),
      // Hidden: a run's entry is captured at its stop, and its source is the start's.
      captured_at: toLocalInputValue(new Date()),
      source: 'ui',
      notes: e?.notes ?? '',
    };
  });

  return (
    <div className="flex flex-col gap-4">
      {fixItem ? (
        <Banner tone="info" title="These answers were not saved">
          The server rejected them. Correct them and save again, or discard them from the sync list.
        </Banner>
      ) : (
        <div className="flex items-baseline justify-between gap-3 px-1">
          <h2 className="font-display text-xl font-semibold tracking-tight">
            {finishing ? 'Add details' : 'Details'}
          </h2>
          {totalMs !== null ? (
            <span className="text-sm text-muted">
              Timed <Duration ms={totalMs} className="font-semibold text-ink" />
            </span>
          ) : null}
        </div>
      )}
      <EntryForm
        questions={questions}
        defaultValues={defaults}
        submitLabel={fixItem ? 'Save again' : 'Save'}
        initialError={fixItem?.last_error?.body ?? undefined}
        focusFirstEmpty={!fixItem}
        meta="notes"
        secondaryAction={({ allowNavigation }) =>
          fixItem ? null : (
            <button
              type="button"
              onClick={() => {
                allowNavigation();
                onDone(null);
              }}
              className="flex h-14 shrink-0 items-center rounded-full border border-line-strong bg-surface px-5 text-sm font-semibold text-ink-soft"
            >
              Later
            </button>
          )
        }
        onSubmit={async (v, { allowNavigation }) => {
          const result = await actions.finish(
            runId,
            ctx,
            { answers: compactAnswers(v.answers), notes: v.notes },
            { fixItemId: fixItem?.id },
          );
          allowNavigation();
          onDone(result);
        }}
      />
    </div>
  );
}
