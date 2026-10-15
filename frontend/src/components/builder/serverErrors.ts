import type { FieldPath } from 'react-hook-form';

import type { TopicDraft } from '../../lib/builder';

const TOP = new Set(['name', 'slug', 'description', 'change_note']);

/**
 * Map a server error path onto a builder form field. Unknown sub-fields fall
 * back to the question itself so the card lights up; anything else is null
 * (goes to the banner).
 */
export function builderFieldFor(path: string, draft: TopicDraft): FieldPath<TopicDraft> | null {
  if (TOP.has(path)) return path as FieldPath<TopicDraft>;
  if (path === 'questions') return 'questions';
  const m = /^questions\.(\d+)(?:\.(.+))?$/.exec(path);
  if (!m) return null;
  const i = Number(m[1]);
  const q = draft.questions[i];
  if (!q) return 'questions';
  const rest = m[2];
  if (rest) {
    const o = /^options\.(\d+)\.(value|label)$/.exec(rest);
    if (o && q.options[Number(o[1])])
      return `questions.${i}.options.${Number(o[1])}.${o[2] as 'value' | 'label'}`;
    if (rest === 'options') return `questions.${i}.options`;
    if (rest in q && rest !== 'uid' && rest !== 'options') return `questions.${i}.${rest as 'key'}`;
  }
  return `questions.${i}.key`;
}
