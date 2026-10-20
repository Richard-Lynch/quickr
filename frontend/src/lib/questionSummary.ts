import { formatNumber } from './format';
import type { Question } from './questions';

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
