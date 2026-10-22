/** The builder with no questions: a new topic starts empty, and the last question can go. */
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import type { ReactNode } from 'react';
import { FormProvider, useForm } from 'react-hook-form';
import { describe, expect, it } from 'vitest';

import {
  emptyTopicDraft,
  newDraftQuestion,
  questionListIssues,
  type TopicDraft,
} from '../../lib/builder';
import { QuestionsEditor } from './QuestionsEditor';

function Form({ draft, children }: { draft: TopicDraft; children: ReactNode }) {
  const form = useForm<TopicDraft>({ defaultValues: draft });
  return <FormProvider {...form}>{children}</FormProvider>;
}

describe('the builder without questions', () => {
  it('starts a new topic with no questions, which is valid', () => {
    expect(emptyTopicDraft().questions).toEqual([]);
    expect(questionListIssues([])).toEqual([]);
  });

  it('says what no questions means', () => {
    render(
      <Form draft={emptyTopicDraft()}>
        <QuestionsEditor defaultExpanded="new" />
      </Form>,
    );
    expect(screen.getByText('No questions: tapping this topic logs it.')).toBeInTheDocument();
  });

  it('removes the last question, which leaves it with none', async () => {
    const draft = {
      ...emptyTopicDraft(),
      questions: [{ ...newDraftQuestion('int'), label: 'Glasses' }],
    };
    render(
      <Form draft={draft}>
        <QuestionsEditor defaultExpanded="new" />
      </Form>,
    );
    expect(screen.queryByText('No questions: tapping this topic logs it.')).toBeNull();
    const remove = screen.getByRole('button', { name: 'Remove question' });
    expect(remove).toBeEnabled();
    await userEvent.click(remove);
    expect(screen.getByText('No questions: tapping this topic logs it.')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Remove question' })).toBeNull();
  });
});
