import { render, screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';

import { TopicGlyph } from './TopicGlyph';

describe('TopicGlyph', () => {
  it('renders the emoji as an image named after the topic', () => {
    render(
      <TopicGlyph
        appearance={{ color: 'teal', icon: { kind: 'emoji', value: '💧' }, tags: [] }}
        name="Water"
      />,
    );
    const glyph = screen.getByRole('img', { name: 'Water' });
    expect(glyph).toHaveTextContent('💧');
    expect(glyph).not.toHaveClass('bg-topic-tint');
  });

  it('renders the initial on the tint circle, themed from the appearance', () => {
    render(
      <TopicGlyph appearance={{ color: 'teal', icon: null, tags: [] }} name="Water" size={28} />,
    );
    const glyph = screen.getByRole('img', { name: 'Water' });
    expect(glyph).toHaveTextContent('W');
    expect(glyph).toHaveClass('bg-topic-tint', 'text-topic-on-tint', 'rounded-full');
    expect(glyph.style.getPropertyValue('--topic-tint')).toBe('var(--topic-teal-tint, #19786f)');
    expect(glyph.style.width).toBe('28px');
  });

  it('leaves the accent alone without a colour, and renders nothing without a name', () => {
    const { container, rerender } = render(<TopicGlyph appearance={null} name="Mood" />);
    const glyph = screen.getByRole('img', { name: 'Mood' });
    expect(glyph).toHaveTextContent('M');
    expect(glyph.style.getPropertyValue('--topic-tint')).toBe('');
    rerender(<TopicGlyph appearance={null} name="" />);
    expect(container).toBeEmptyDOMElement();
  });
});
