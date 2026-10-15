import { describe, expect, it } from 'vitest';

import { emptyTopicDraft, newDraftQuestion } from '../../lib/builder';
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
});
