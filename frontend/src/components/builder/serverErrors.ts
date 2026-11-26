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
  if (path === 'timer' || path.startsWith('timer.'))
    return draft.timed ? timerFieldFor(path, draft) : null;
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

/**
 * A `timer.…` path (timers2.md §1.3) onto the draft, which keeps the timer's lists at the top
 * level: `timer.steps.N.key` -> `steps.N.key`, `timer.laps.N.alerts.M.at` ->
 * `laps.N.alerts.M.at`, `timer.variables.N.ms` -> `variables.N.duration` (the draft types a
 * duration). An index the draft doesn't have lights up the list; another sub-field, the label
 * (a variable's name).
 */
function timerFieldFor(path: string, draft: TopicDraft): FieldPath<TopicDraft> {
  if (path === 'timer' || path === 'timer.steps') return 'steps';
  if (path === 'timer.laps') return 'laps';
  if (path === 'timer.variables') return 'variables';
  const v = /^timer\.variables\.(\d+)(?:\.(\w+))?/.exec(path);
  if (v) {
    const i = Number(v[1]);
    if (!draft.variables[i]) return 'variables';
    return `variables.${i}.${v[2] === 'ms' ? 'duration' : 'name'}`;
  }
  const o = /^timer\.(steps|laps)\.(\d+)(?:\.(\w+))?(?:\.(\d+))?(?:\.(\w+))?/.exec(path);
  if (!o) return 'steps';
  const owner = o[1] === 'laps' ? 'laps' : 'steps';
  const i = Number(o[2]);
  const item = draft[owner][i];
  if (!item) return owner;
  if (o[3] === 'key') return `${owner}.${i}.key`;
  if (o[3] !== 'alerts') return `${owner}.${i}.label`;
  if (o[4] === undefined) return `${owner}.${i}.alerts`;
  const j = Number(o[4]);
  if (!item.alerts[j]) return `${owner}.${i}.alerts`;
  const field = o[5] === 'key' || o[5] === 'at' ? o[5] : o[5] === 'at_ms' ? 'at' : 'label';
  return `${owner}.${i}.alerts.${j}.${field}`;
}
