import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { useState } from 'react';
import { describe, expect, it } from 'vitest';

import type { Question } from '../../lib/questions';
import { AnswerField } from './AnswerField';

const mood: Question = {
  key: 'mood',
  label: 'Mood',
  help_text: 'How was today?',
  required: false,
  type: 'enum',
  options: [
    { value: 'good', label: 'Good', archived: false },
    { value: 'bad', label: 'Bad', archived: false },
    { value: 'old', label: 'Old', archived: true },
  ],
  multiple: false,
  min_selected: null,
  max_selected: null,
};

const water: Question = {
  key: 'water',
  label: 'Water',
  help_text: null,
  required: true,
  type: 'int',
  min: 0,
  max: 3,
  unit: 'glasses',
};

function Harness({ question, initial = '' }: { question: Question; initial?: string }) {
  const [value, setValue] = useState(initial);
  return (
    <>
      <AnswerField question={question} value={value} onChange={setValue} />
      <output data-testid="value">{value}</output>
    </>
  );
}

describe('AnswerField', () => {
  it('renders enum options as radio chips, hiding archived ones, and toggles optional answers', async () => {
    const user = userEvent.setup();
    render(<Harness question={mood} />);
    expect(screen.getByRole('radiogroup', { name: /Mood/ })).toBeInTheDocument();
    expect(screen.getAllByRole('radio').map((r) => r.textContent)).toEqual(['Good', 'Bad']);
    await user.click(screen.getByRole('radio', { name: 'Good' }));
    expect(screen.getByTestId('value')).toHaveTextContent('good');
    expect(screen.getByRole('radio', { name: 'Good' })).toHaveAttribute('aria-checked', 'true');
    // tapping again clears an optional answer
    await user.click(screen.getByRole('radio', { name: 'Good' }));
    expect(screen.getByTestId('value')).toHaveTextContent('');
  });

  it('keeps an archived value selectable when editing an entry that holds it', () => {
    render(<AnswerField question={mood} value="old" onChange={() => undefined} keepValue="old" />);
    expect(screen.getByRole('radio', { name: /Old \(retired\)/ })).toHaveAttribute(
      'aria-checked',
      'true',
    );
  });

  it('steps numbers within bounds', async () => {
    const user = userEvent.setup();
    render(<Harness question={water} initial="2" />);
    const plus = screen.getByRole('button', { name: 'Increase' });
    await user.click(plus);
    expect(screen.getByLabelText('Water')).toHaveValue('3');
    expect(plus).toBeDisabled();
    await user.click(screen.getByRole('button', { name: 'Decrease' }));
    expect(screen.getByLabelText('Water')).toHaveValue('2');
  });
});
