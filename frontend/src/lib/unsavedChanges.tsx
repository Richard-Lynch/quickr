import { useCallback, useEffect, useRef, type ReactNode } from 'react';
import { useBlocker, useLocation, type BlockerFunction, type NavigateFunction } from 'react-router';

import { ConfirmSheet } from '../components/ui/Sheet';

/** Guards that currently hold unsaved changes (read by the update prompt). */
const dirtyGuards = new Set<symbol>();

export function hasUnsavedChanges(): boolean {
  return dirtyGuards.size > 0;
}

export interface UnsavedChangesGuard {
  /**
   * Let the next navigation through without asking — call it right before navigating
   * away after a successful save / publish (the form may still be "dirty" then).
   */
  allowNavigation: () => void;
  /** The confirm sheet; render it anywhere in the page. */
  dialog: ReactNode;
}

interface Options {
  title?: string;
  message?: ReactNode;
}

/** Navigations allowed through once (see `navigateKeepingPage`), by id. */
const pageKeepers = new Set<string>();

/**
 * Navigate (replacing the entry) to a URL that keeps the page and its forms mounted (the topic's
 * slug changed elsewhere and the route follows it): the guard lets this one navigation through.
 * The id is spent when it's over, so a later back/forward to that history entry is guarded as
 * usual, whether or not a guard looked at it this time.
 */
export async function navigateKeepingPage(navigate: NavigateFunction, to: string): Promise<void> {
  const id = `${String(Date.now())}-${String(Math.random())}`;
  pageKeepers.add(id);
  try {
    await navigate(to, { replace: true, state: { keepsPage: id } });
  } finally {
    pageKeepers.delete(id);
  }
}

/** Whether `state` is a `navigateKeepingPage` navigation's, still under way; uses it up. */
export function takeKeepsPage(state: unknown): boolean {
  return (
    typeof state === 'object' &&
    state !== null &&
    'keepsPage' in state &&
    typeof state.keepsPage === 'string' &&
    pageKeepers.delete(state.keepsPage)
  );
}

/** Pure part of the blocker decision (unit-tested). Search/hash-only changes pass. */
export function shouldBlockNavigation(
  isDirty: boolean,
  skip: boolean,
  current: { pathname: string },
  next: { pathname: string },
): boolean {
  return isDirty && !skip && current.pathname !== next.pathname;
}

/**
 * Ask before leaving a form with unsaved changes:
 * - in-app navigation (links, back button, `navigate()`) via React Router's `useBlocker`,
 *   with a confirm sheet;
 * - tab close / reload via `beforeunload` (browsers show their own generic prompt;
 *   iOS ignores it entirely).
 */
export function useUnsavedChangesGuard(
  isDirty: boolean,
  { title = 'Discard unsaved changes?', message }: Options = {},
): UnsavedChangesGuard {
  const skip = useRef(false);
  const location = useLocation();

  const shouldBlock = useCallback<BlockerFunction>(
    ({ currentLocation, nextLocation }) =>
      shouldBlockNavigation(isDirty, skip.current, currentLocation, nextLocation) &&
      !takeKeepsPage(nextLocation.state),
    [isDirty],
  );
  const blocker = useBlocker(shouldBlock);

  // A save that navigates within the same component re-arms the guard afterwards.
  useEffect(() => {
    skip.current = false;
  }, [location.key]);

  useEffect(() => {
    if (!isDirty) return;
    const id = Symbol('unsaved');
    dirtyGuards.add(id);
    const onBeforeUnload = (e: BeforeUnloadEvent) => {
      if (skip.current) return;
      e.preventDefault();
    };
    window.addEventListener('beforeunload', onBeforeUnload);
    return () => {
      dirtyGuards.delete(id);
      window.removeEventListener('beforeunload', onBeforeUnload);
    };
  }, [isDirty]);

  const allowNavigation = useCallback(() => {
    skip.current = true;
  }, []);

  const dialog = (
    <ConfirmSheet
      open={blocker.state === 'blocked'}
      onClose={() => {
        if (blocker.state === 'blocked') blocker.reset();
      }}
      onConfirm={() => {
        if (blocker.state === 'blocked') blocker.proceed();
      }}
      title={title}
      body={<p>{message ?? 'You have changes that haven’t been saved. Leave and lose them?'}</p>}
      cancelLabel="Keep editing"
      confirmLabel="Discard"
      danger
    />
  );

  return { allowNavigation, dialog };
}
