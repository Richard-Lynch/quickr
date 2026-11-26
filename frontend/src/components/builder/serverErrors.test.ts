import { describe, expect, it } from 'vitest';

import { draftFromTimer, emptyTopicDraft, newDraftQuestion, newDraftStep } from '../../lib/builder';
import { builderFieldFor } from './serverErrors';

describe('builderFieldFor', () => {
  const draft = {
    ...emptyTopicDraft(),
    questions: [newDraftQuestion('int'), newDraftQuestion('enum')],
  };

  it('maps top-level and question paths onto form fields', () => {
    expect(builderFieldFor('slug', draft)).toBe('slug');
    expect(builderFieldFor('questions.0.min', draft)).toBe('questions.0.min');
    expect(builderFieldFor('questions.1.options.0.value', draft)).toBe(
      'questions.1.options.0.value',
    );
    expect(builderFieldFor('questions.1.options', draft)).toBe('questions.1.options');
  });

  it('falls back to the question key, the list, or null', () => {
    expect(builderFieldFor('questions.0', draft)).toBe('questions.0.key');
    expect(builderFieldFor('questions.0.bogus', draft)).toBe('questions.0.key');
    expect(builderFieldFor('questions.9.min', draft)).toBe('questions');
    expect(builderFieldFor('meta.x', draft)).toBeNull();
  });

  it('maps timer step paths onto the steps (timers.md §2.1)', () => {
    const timed = { ...draft, timed: true, steps: [newDraftStep('Wash'), newDraftStep('Dry')] };
    expect(builderFieldFor('timer.steps.1.key', timed)).toBe('steps.1.key');
    expect(builderFieldFor('timer.steps.0.label', timed)).toBe('steps.0.label');
    expect(builderFieldFor('timer.steps.0', timed)).toBe('steps.0.label');
    expect(builderFieldFor('timer.steps.5.key', timed)).toBe('steps');
    expect(builderFieldFor('timer.steps', timed)).toBe('steps');
    expect(builderFieldFor('timer', draft)).toBeNull();
  });

  it('maps lap type, variable and alert paths (timers2.md §1.3)', () => {
    const timed = {
      ...draft,
      ...draftFromTimer({
        steps: [{ key: 'warm', label: 'Warm', alerts: [{ key: 'go', label: 'Go', at: '1m' }] }],
        laps: [{ key: 'run', label: 'Run', alerts: [{ key: 'half', label: 'Half', at: 't/2' }] }],
        variables: [{ name: 't', ms: 60_000 }],
      }),
    };
    expect(builderFieldFor('timer.laps', timed)).toBe('laps');
    expect(builderFieldFor('timer.laps.0.key', timed)).toBe('laps.0.key');
    expect(builderFieldFor('timer.laps.0.label', timed)).toBe('laps.0.label');
    expect(builderFieldFor('timer.laps.0', timed)).toBe('laps.0.label');
    expect(builderFieldFor('timer.laps.3.key', timed)).toBe('laps');
    expect(builderFieldFor('timer.variables', timed)).toBe('variables');
    expect(builderFieldFor('timer.variables.0.name', timed)).toBe('variables.0.name');
    expect(builderFieldFor('timer.variables.0.ms', timed)).toBe('variables.0.duration');
    expect(builderFieldFor('timer.variables.0', timed)).toBe('variables.0.name');
    expect(builderFieldFor('timer.variables.2.ms', timed)).toBe('variables');
    expect(builderFieldFor('timer.laps.0.alerts.0.at', timed)).toBe('laps.0.alerts.0.at');
    expect(builderFieldFor('timer.steps.0.alerts.0.key', timed)).toBe('steps.0.alerts.0.key');
    expect(builderFieldFor('timer.steps.0.alerts.0.label', timed)).toBe('steps.0.alerts.0.label');
    expect(builderFieldFor('timer.steps.0.alerts.0', timed)).toBe('steps.0.alerts.0.label');
    expect(builderFieldFor('timer.steps.0.alerts', timed)).toBe('steps.0.alerts');
    expect(builderFieldFor('timer.steps.0.alerts.4.at', timed)).toBe('steps.0.alerts');
    // Not timed: the form has no timer fields, so the banner shows it.
    expect(builderFieldFor('timer.laps.0.alerts.0.at', draft)).toBeNull();
  });
});
