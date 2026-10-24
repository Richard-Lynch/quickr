import type { FieldPath } from 'react-hook-form';

import type { TopicDraft } from '../../lib/builder';
import { scheduleFieldFor } from '../../lib/schedule';

const TOP = new Set(['name', 'slug', 'description', 'change_note']);

/**
 * Map a server error path onto a builder form field. Unknown sub-fields fall
 * back to the question itself so the card lights up; anything else is null
 * (goes to the banner).
 */
export function builderFieldFor(path: string, draft: TopicDraft): FieldPath<TopicDraft> | null {
  if (TOP.has(path)) return path as FieldPath<TopicDraft>;
  if (path === 'schedule' || path.startsWith('schedule.')) {
    const f = scheduleFieldFor(path);
    if (!f) return null;
    const t = /^schedule\.times\.(\d+)\.value$/.exec(f);
    // A time index the draft doesn't have (shouldn't happen) lights up the list.
    if (t && !draft.schedule.times[Number(t[1])]) return 'schedule.times';
    return f as FieldPath<TopicDraft>;
  }
  if (path === 'questions') return 'questions';
  // The server says `timer.steps.N.…`; the draft keeps the steps at the top level.
  if (path === 'timer' || path === 'timer.steps') return draft.timed ? 'steps' : null;
  const st = /^timer\.steps\.(\d+)(?:\.(key|label))?/.exec(path);
  if (st) {
    const i = Number(st[1]);
    if (!draft.steps[i]) return 'steps';
    return `steps.${i}.${st[2] === 'key' ? 'key' : 'label'}`;
  }
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
