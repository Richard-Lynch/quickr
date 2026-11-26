import { act, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { useState } from 'react';
import { createMemoryRouter, Link, RouterProvider, useNavigate } from 'react-router';
import { describe, expect, it } from 'vitest';

import {
  hasUnsavedChanges,
  keepsPageState,
  shouldBlockNavigation,
  takeKeepsPage,
  useUnsavedChangesGuard,
} from './unsavedChanges';

describe('keepsPageState', () => {
  it('lets one navigation through, then never again (a later back to that entry is guarded)', () => {
    const state = keepsPageState();
    expect(takeKeepsPage(state)).toBe(true);
    expect(takeKeepsPage(state)).toBe(false);
    expect(takeKeepsPage({ keepsPage: 'made-up' })).toBe(false);
    expect(takeKeepsPage(null)).toBe(false);
  });
});

describe('shouldBlockNavigation', () => {
  const a = { pathname: '/a' };
  const b = { pathname: '/b' };
  it('blocks only dirty, unskipped, path-changing navigations', () => {
    expect(shouldBlockNavigation(true, false, a, b)).toBe(true);
    expect(shouldBlockNavigation(false, false, a, b)).toBe(false);
    expect(shouldBlockNavigation(true, true, a, b)).toBe(false);
    expect(shouldBlockNavigation(true, false, a, { pathname: '/a' })).toBe(false);
  });
});

function Form() {
  const [value, setValue] = useState('');
  const navigate = useNavigate();
  const guard = useUnsavedChangesGuard(value !== '');
  return (
    <>
      <input aria-label="field" value={value} onChange={(e) => setValue(e.target.value)} />
      <Link to="/other">leave</Link>
      <button
        type="button"
        onClick={() => {
          guard.allowNavigation();
          void navigate('/other');
        }}
      >
        save
      </button>
      {guard.dialog}
    </>
  );
}

function setup() {
  const router = createMemoryRouter(
    [
      { path: '/', element: <Form /> },
      { path: '/other', element: <p>other page</p> },
    ],
    { initialEntries: ['/'] },
  );
  render(<RouterProvider router={router} />);
  return { router, user: userEvent.setup() };
}

describe('useUnsavedChangesGuard', () => {
  it('lets clean forms navigate freely', async () => {
    const { user } = setup();
    await user.click(screen.getByText('leave'));
    expect(screen.getByText('other page')).toBeInTheDocument();
  });

  it('asks before leaving a dirty form; keep editing stays, discard leaves', async () => {
    const { user, router } = setup();
    await user.type(screen.getByLabelText('field'), 'x');
    expect(hasUnsavedChanges()).toBe(true);
    await user.click(screen.getByText('leave'));
    expect(screen.getByText('Discard unsaved changes?')).toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: 'Keep editing' }));
    expect(router.state.location.pathname).toBe('/');
    await user.click(screen.getByText('leave'));
    await user.click(screen.getByRole('button', { name: 'Discard' }));
    expect(screen.getByText('other page')).toBeInTheDocument();
    expect(hasUnsavedChanges()).toBe(false);
  });

  it('does not ask after a successful save', async () => {
    const { user } = setup();
    await user.type(screen.getByLabelText('field'), 'x');
    await user.click(screen.getByText('save'));
    expect(screen.getByText('other page')).toBeInTheDocument();
    expect(screen.queryByText('Discard unsaved changes?')).not.toBeInTheDocument();
  });

  it('prevents tab close while dirty', async () => {
    const { user } = setup();
    const clean = new Event('beforeunload', { cancelable: true });
    act(() => {
      window.dispatchEvent(clean);
    });
    expect(clean.defaultPrevented).toBe(false);
    await user.type(screen.getByLabelText('field'), 'x');
    const dirty = new Event('beforeunload', { cancelable: true });
    act(() => {
      window.dispatchEvent(dirty);
    });
    expect(dirty.defaultPrevented).toBe(true);
  });
});
