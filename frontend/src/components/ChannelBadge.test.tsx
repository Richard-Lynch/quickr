import { render, screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';

import { ChannelBadge, channelLabel } from './ChannelBadge';

describe('ChannelBadge', () => {
  it('labels every channel', () => {
    expect(['ui', 'api', 'mcp', 'ios'].map((c) => channelLabel(c as 'ui'))).toEqual([
      'Web',
      'API',
      'MCP',
      'iOS',
    ]);
  });

  it('shows iOS entries in the list, and hides web ones there', () => {
    const { container, rerender } = render(<ChannelBadge channel="ios" showUi={false} />);
    expect(screen.getByText('iOS')).toBeInTheDocument();
    rerender(<ChannelBadge channel="ui" showUi={false} />);
    expect(container).toBeEmptyDOMElement();
    rerender(<ChannelBadge channel="ui" />);
    expect(screen.getByText('Web')).toBeInTheDocument();
  });
});
