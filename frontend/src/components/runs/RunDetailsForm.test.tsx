/** The answers form shows the server's refusal (a 409 `run_open` on finish, §3.6). */
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { createMemoryRouter, RouterProvider } from 'react-router';
import { describe, expect, it, vi } from 'vitest';

import { CTX } from '../../test/runs';
import { HOW } from '../../test/runUi';
import { RunDetailsForm } from './RunDetailsForm';
import type { RunActions } from './useRunActions';

describe('RunDetailsForm', () => {
  it('a run_open refusal shows on the form, and nothing is reported done', async () => {
    Element.prototype.scrollIntoView = () => undefined;
    const problem = { code: 'run_open', detail: 'The run is still open', errors: [] };
    const actions: RunActions = {
      busy: false,
      start: vi.fn(),
      tap: vi.fn(),
      // The Problem body, as `useRunActions` throws it for the form.
      finish: vi.fn(() => {
        const body: unknown = problem;
        throw body;
      }),
    };
    const onDone = vi.fn();
    const router = createMemoryRouter(
      [
        {
          path: '/',
          element: (
            <RunDetailsForm
              runId="r1"
              ctx={CTX}
              questions={[HOW]}
              finishing
              totalMs={42_000}
              actions={actions}
              onDone={onDone}
            />
          ),
        },
      ],
      { initialEntries: ['/'] },
    );
    render(
      <QueryClientProvider client={new QueryClient()}>
        <RouterProvider router={router} />
      </QueryClientProvider>,
    );
    await userEvent.type(screen.getByRole('textbox', { name: /How did it go/ }), 'Fine');
    await userEvent.click(screen.getByRole('button', { name: 'Save' }));
    expect(await screen.findByRole('alert')).toHaveTextContent('The run is still open');
    expect(actions.finish).toHaveBeenCalledWith(
      'r1',
      CTX,
      { answers: { how: 'Fine' }, notes: '' },
      {},
    );
    expect(onDone).not.toHaveBeenCalled();
  });
});
