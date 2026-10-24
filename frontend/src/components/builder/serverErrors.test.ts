import { describe, expect, it } from 'vitest';

import { emptyTopicDraft, newDraftQuestion, newDraftStep } from '../../lib/builder';
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
});
