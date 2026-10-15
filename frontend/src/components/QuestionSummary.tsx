import { formatNumber } from '../lib/format';
import { TYPE_META, type Question } from '../lib/questions';
import { Badge } from './ui/Card';

/** One-line description of a question's constraints. */
export function constraintText(q: Question): string {
  switch (q.type) {
    case 'int':
    case 'double': {
      const parts: string[] = [];
      if (q.min !== null && q.max !== null)
        parts.push(`${formatNumber(q.min)}–${formatNumber(q.max)}`);
      else if (q.min !== null) parts.push(`≥ ${formatNumber(q.min)}`);
      else if (q.max !== null) parts.push(`≤ ${formatNumber(q.max)}`);
      if (q.unit) parts.push(q.unit);
      if (q.type === 'double' && q.decimals !== null) parts.push(`${q.decimals} dp`);
      return parts.join(' · ') || 'any value';
    }
    case 'str':
      return `${q.min_length}–${q.max_length} chars${q.multiline ? ' · multiline' : ''}`;
    case 'enum': {
      const active = q.options.filter((o) => !o.archived).length;
      const archived = q.options.length - active;
      return `${active} option${active === 1 ? '' : 's'}${archived ? ` · ${archived} archived` : ''}`;
    }
  }
}

export function QuestionSummaryList({ questions }: { questions: readonly Question[] }) {
  return (
    <ol className="flex flex-col divide-y divide-dashed divide-line">
      {questions.map((q, i) => (
        <li key={q.key} className="flex flex-col gap-1 py-2.5">
          <div className="flex items-start gap-2">
            <span className="w-5 shrink-0 pt-0.5 font-mono text-xs text-muted">{i + 1}</span>
            <div className="min-w-0 flex-1">
              <p className="font-medium">
                {q.label}
                {!q.required ? (
                  <span className="ml-1.5 text-xs font-normal text-muted">optional</span>
                ) : null}
              </p>
              <p className="font-mono text-xs text-muted">
                {q.key} · {constraintText(q)}
              </p>
              {q.type === 'enum' ? (
                <div className="mt-1.5 flex flex-wrap gap-1">
                  {q.options.map((o) => (
                    <Badge
                      key={o.value}
                      tone={o.archived ? 'warn' : 'neutral'}
                      className={o.archived ? 'line-through' : undefined}
                    >
                      {o.label}
                    </Badge>
                  ))}
                </div>
              ) : null}
            </div>
            <Badge tone="info">{TYPE_META[q.type].short}</Badge>
          </div>
        </li>
      ))}
    </ol>
  );
}
