import { useMemo, useState } from 'react';
import { useFormContext, useWatch } from 'react-hook-form';

import { buildAnswerSchema } from '../../lib/answerSchema';
import { previewQuestion, type TopicDraft } from '../../lib/builder';
import { AnswerField } from '../answers/AnswerField';
import { Card } from '../ui/Card';

/** Live, interactive rendering of the form being built (validation included). */
export function FormPreview() {
  const { control } = useFormContext<TopicDraft>();
  const drafts = useWatch({ control, name: 'questions' });
  const name = useWatch({ control, name: 'name' });
  const questions = useMemo(() => drafts.map((d, i) => previewQuestion(d, i)), [drafts]);
  const [values, setValues] = useState<Record<string, string>>({});
  const [touched, setTouched] = useState<Set<string>>(new Set());
  const errors = useMemo(() => {
    const r = buildAnswerSchema(questions).safeParse(values);
    if (r.success) return {};
    return Object.fromEntries(r.error.issues.map((i) => [String(i.path[0]), i.message]));
  }, [questions, values]);

  return (
    <Card className="overflow-hidden">
      <div className="flex items-center gap-2 border-b border-dashed border-line bg-sunken/50 px-4 py-2.5">
        <span className="size-2 rounded-full bg-accent" />
        <span className="text-xs font-semibold tracking-wide text-muted uppercase">Preview</span>
        <span className="ml-auto truncate text-sm font-semibold">{name || 'Untitled topic'}</span>
      </div>
      <div className="flex flex-col divide-y divide-dashed divide-line">
        {questions.map((q, i) => {
          const k = drafts[i]?.uid ?? q.key;
          return (
            <div key={k} className="p-4">
              <AnswerField
                question={q}
                value={values[q.key] ?? ''}
                onChange={(v) => setValues((s) => ({ ...s, [q.key]: v }))}
                onBlur={() => setTouched((t) => new Set(t).add(q.key))}
                error={touched.has(q.key) ? errors[q.key] : undefined}
              />
            </div>
          );
        })}
      </div>
    </Card>
  );
}
