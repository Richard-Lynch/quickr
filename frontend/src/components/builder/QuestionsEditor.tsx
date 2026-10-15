import { useState } from 'react';
import { useFieldArray, useFormContext } from 'react-hook-form';

import { newDraftQuestion, type TopicDraft } from '../../lib/builder';
import { QUESTION_TYPES, TYPE_META, type QuestionType } from '../../lib/questions';
import { Button } from '../ui/Button';
import { Icon } from '../ui/Icon';
import { Sheet } from '../ui/Sheet';
import { fieldError } from './fieldError';
import { QuestionCard, TypeChip } from './QuestionCard';

/** Ordered list of question cards + "add question" type picker. */
export function QuestionsEditor({ defaultExpanded }: { defaultExpanded: 'all' | 'new' }) {
  const { control, formState } = useFormContext<TopicDraft>();
  const { fields, append, remove, move } = useFieldArray({
    control,
    name: 'questions',
    keyName: 'fieldId',
  });
  const [expanded, setExpanded] = useState<Set<string>>(
    () => new Set(defaultExpanded === 'all' ? fields.map((f) => f.uid) : []),
  );
  const [picking, setPicking] = useState(false);
  const listError = fieldError(formState.errors, 'questions');

  const add = (type: QuestionType) => {
    const q = newDraftQuestion(type);
    append(q, { shouldFocus: false });
    setExpanded((s) => new Set(s).add(q.uid));
    setPicking(false);
    window.setTimeout(() => {
      const el = document.getElementById(`q-${q.uid}`);
      el?.scrollIntoView({ behavior: 'smooth', block: 'start' });
      el?.querySelector<HTMLInputElement>('input')?.focus({ preventScroll: true });
    }, 50);
  };

  const toggle = (uid: string) =>
    setExpanded((s) => {
      const next = new Set(s);
      if (next.has(uid)) next.delete(uid);
      else next.add(uid);
      return next;
    });

  return (
    <section className="flex flex-col gap-3" aria-label="Questions">
      <div className="flex items-end justify-between">
        <h2 className="font-display text-lg font-semibold tracking-tight">
          Questions{' '}
          <span className="font-mono text-sm font-normal text-muted">{fields.length}</span>
        </h2>
        {fields.length > 1 ? (
          <button
            type="button"
            className="text-sm font-semibold text-muted hover:text-ink"
            onClick={() =>
              setExpanded((s) =>
                s.size >= fields.length ? new Set() : new Set(fields.map((f) => f.uid)),
              )
            }
          >
            {expanded.size >= fields.length ? 'Collapse all' : 'Expand all'}
          </button>
        ) : null}
      </div>

      <ol className="flex flex-col gap-2.5">
        {fields.map((f, i) => (
          <li key={f.fieldId} id={`q-${f.uid}`} className="scroll-mt-20">
            <QuestionCard
              index={i}
              count={fields.length}
              expanded={expanded.has(f.uid) || hasError(formState.errors, i)}
              onToggle={() => toggle(f.uid)}
              onMove={(to) => move(i, to)}
              onRemove={() => remove(i)}
            />
          </li>
        ))}
      </ol>

      {listError ? (
        <p role="alert" className="text-sm font-medium text-danger">
          {listError}
        </p>
      ) : null}

      <Button
        size="lg"
        onClick={() => setPicking(true)}
        className="border-dashed"
        icon={<Icon name="plus" />}
        disabled={fields.length >= 100}
      >
        Add question
      </Button>

      <Sheet
        open={picking}
        onClose={() => setPicking(false)}
        title="Add a question"
        description="Pick what kind of answer it takes."
      >
        <ul className="grid grid-cols-2 gap-2 pb-2">
          {QUESTION_TYPES.map((t) => (
            <li key={t}>
              <button
                type="button"
                onClick={() => add(t)}
                className="flex h-full w-full flex-col items-start gap-2 rounded-2xl border border-line-strong bg-paper/40 p-4 text-left transition-colors hover:border-accent active:scale-[0.98]"
              >
                <TypeChip type={t} />
                <span className="font-semibold">{TYPE_META[t].label}</span>
                <span className="text-xs text-muted">{TYPE_META[t].hint}</span>
              </button>
            </li>
          ))}
        </ul>
      </Sheet>
    </section>
  );
}

function hasError(errors: unknown, index: number): boolean {
  const qs = (errors as { questions?: Record<number, unknown> } | undefined)?.questions;
  return Boolean(qs && typeof qs === 'object' && qs[index]);
}
