/**
 * The forced update of an outdated bundle and the "server needs updating" note
 * (docs/specs/client-versions.md §5.2, §5.4, V10, V14).
 */
import { act, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';

import {
  API_LEVEL,
  FORCED_RELOAD_KEY,
  hasForcedReload,
  markClientOutdated,
  markForcedReload,
  observeResponse,
  resetClientVersion,
} from '../../api/clientVersion';
import { getClientVersions } from '../../client';
import { client } from '../../client/client.gen';
import { ToastProvider } from '../ui/Toast';
import { ClientOutdated, ServerBehindBanner, SERVER_BEHIND_DISMISSED_KEY } from './ClientVersion';
import { forceUpdate, type ForceUpdateDeps } from './forceUpdate';
import { awaitRegistration, setRegistration } from './swRegistration';
import { UpdatePrompt } from './UpdatePrompt';

const unsaved = vi.hoisted(() => ({ value: false }));
vi.mock('../../lib/unsavedChanges', () => ({ hasUnsavedChanges: () => unsaved.value }));
vi.mock('virtual:pwa-register/react', () => ({
  useRegisterSW: () => ({
    needRefresh: [true, vi.fn()],
    offlineReady: [false, vi.fn()],
    updateServiceWorker: vi.fn(),
  }),
}));

afterEach(() => {
  vi.useRealTimers();
  resetClientVersion();
  sessionStorage.clear();
  unsaved.value = false;
});

/** A worker: `SKIP_WAITING` makes it take control, as `sw.ts` does. */
class FakeWorker extends EventTarget {
  state = 'installing';
  postMessage = vi.fn((msg: unknown) => {
    if ((msg as { type?: string }).type === 'SKIP_WAITING') this.onSkip();
  });
  onSkip: () => void = () => undefined;
  install(reg: FakeRegistration) {
    this.state = 'installed';
    reg.installing = null;
    reg.waiting = this as unknown as ServiceWorker;
    this.dispatchEvent(new Event('statechange'));
  }
}

/** A registration with a Web Push subscription, which must survive the update. */
class FakeRegistration extends EventTarget {
  waiting: ServiceWorker | null = null;
  installing: ServiceWorker | null = null;
  update = vi.fn(() => Promise.resolve());
  unregister = vi.fn(() => Promise.resolve(true));
  subscription = { endpoint: 'https://push.test/1', unsubscribe: vi.fn() };
  pushManager = { getSubscription: () => Promise.resolve(this.subscription) };
}

function setup(over: Partial<ForceUpdateDeps> = {}) {
  const reg = new FakeRegistration();
  const container = new EventTarget();
  const reload = vi.fn();
  const deps: ForceUpdateDeps = {
    registration: reg as unknown as ServiceWorkerRegistration,
    container: container,
    reload,
    online: () => true,
    waitMs: 10_000,
    ...over,
  };
  return { reg, container, reload, deps };
}

async function expectPushKept(reg: FakeRegistration) {
  expect(reg.unregister).not.toHaveBeenCalled();
  expect(reg.subscription.unsubscribe).not.toHaveBeenCalled();
  expect(await reg.pushManager.getSubscription()).toBe(reg.subscription);
}

describe('forceUpdate (§5.2)', () => {
  it('a waiting worker: update(), SKIP_WAITING, reload on controllerchange', async () => {
    const { reg, container, reload, deps } = setup();
    const worker = new FakeWorker();
    worker.onSkip = () => container.dispatchEvent(new Event('controllerchange'));
    reg.waiting = worker as unknown as ServiceWorker;
    expect(await forceUpdate(deps)).toBe('reloading');
    expect(reg.update).toHaveBeenCalledOnce();
    expect(worker.postMessage).toHaveBeenCalledWith({ type: 'SKIP_WAITING' });
    expect(reload).toHaveBeenCalledOnce();
    expect(hasForcedReload()).toBe(true);
    await expectPushKept(reg);
  });

  it('a worker that becomes waiting within 10 s is activated', async () => {
    vi.useFakeTimers();
    const { reg, container, reload, deps } = setup();
    const worker = new FakeWorker();
    worker.onSkip = () => container.dispatchEvent(new Event('controllerchange'));
    const done = forceUpdate(deps);
    await vi.advanceTimersByTimeAsync(3_000);
    reg.installing = worker as unknown as ServiceWorker;
    reg.dispatchEvent(new Event('updatefound'));
    await vi.advanceTimersByTimeAsync(3_000);
    expect(reload).not.toHaveBeenCalled();
    worker.install(reg);
    expect(await done).toBe('reloading');
    expect(worker.postMessage).toHaveBeenCalledWith({ type: 'SKIP_WAITING' });
    expect(reload).toHaveBeenCalledOnce();
  });

  it('no new worker: reloads after 10 s without unregistering', async () => {
    vi.useFakeTimers();
    const { reg, reload, deps } = setup();
    const done = forceUpdate(deps);
    await vi.advanceTimersByTimeAsync(9_999);
    expect(reload).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(1);
    expect(await done).toBe('reloading');
    expect(reload).toHaveBeenCalledOnce();
    await expectPushKept(reg);
  });

  it('a second outdated load in the session does not reload again (loop guard)', async () => {
    markForcedReload();
    const { reg, reload, deps } = setup();
    expect(await forceUpdate(deps)).toBe('failed');
    expect(reg.update).not.toHaveBeenCalled();
    expect(reload).not.toHaveBeenCalled();
    // The Reload button: the user asked.
    expect(await forceUpdate({ ...deps, waitMs: 0, ignoreGuard: true })).toBe('reloading');
    expect(reload).toHaveBeenCalledOnce();
  });

  it('offline, or update() fails: no reload', async () => {
    const offline = setup({ online: () => false });
    expect(await forceUpdate(offline.deps)).toBe('failed');
    const failing = setup();
    failing.reg.update.mockRejectedValueOnce(new TypeError('Failed to fetch'));
    expect(await forceUpdate(failing.deps)).toBe('failed');
    expect(offline.reload).not.toHaveBeenCalled();
    expect(failing.reload).not.toHaveBeenCalled();
    expect(sessionStorage.getItem(FORCED_RELOAD_KEY)).toBeNull();
  });

  it('a 426 before the worker is registered still calls update() (cold start)', async () => {
    const { reg, container, reload, deps } = setup();
    const worker = new FakeWorker();
    worker.onSkip = () => container.dispatchEvent(new Event('controllerchange'));
    reg.waiting = worker as unknown as ServiceWorker;
    const findRegistration = vi.fn(() =>
      Promise.resolve(reg as unknown as ServiceWorkerRegistration),
    );
    expect(await forceUpdate({ ...deps, registration: null, findRegistration })).toBe('reloading');
    expect(findRegistration).toHaveBeenCalledWith(10_000);
    expect(reg.update).toHaveBeenCalledOnce();
    expect(worker.postMessage).toHaveBeenCalledWith({ type: 'SKIP_WAITING' });
    expect(reload).toHaveBeenCalledOnce();
  });

  it("awaitRegistration: the browser's, else the one UpdatePrompt sets in time, else null", async () => {
    const reg = new FakeRegistration() as unknown as ServiceWorkerRegistration;
    expect(await awaitRegistration(10, () => Promise.resolve(reg))).toBe(reg);
    vi.useFakeTimers();
    const none = awaitRegistration(10_000, () => Promise.resolve(undefined));
    await vi.advanceTimersByTimeAsync(10_000);
    expect(await none).toBeNull();
    const later = awaitRegistration(10_000, () => Promise.resolve(undefined));
    await vi.advanceTimersByTimeAsync(2_000);
    setRegistration(reg);
    expect(await later).toBe(reg);
  });

  it('without sessionStorage: no reload of its own (no loop), but Reload works', async () => {
    const setItem = vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => {
      throw new DOMException('blocked', 'SecurityError');
    });
    try {
      const { reload, deps } = setup({ registration: null, container: null });
      expect(await forceUpdate(deps)).toBe('failed');
      expect(reload).not.toHaveBeenCalled();
      expect(hasForcedReload()).toBe(true);
      expect(await forceUpdate({ ...deps, ignoreGuard: true })).toBe('reloading');
      expect(reload).toHaveBeenCalledOnce();
    } finally {
      setItem.mockRestore();
    }
  });

  it('without a service worker: reloads', async () => {
    const { reload, deps } = setup({ registration: null, container: null });
    expect(await forceUpdate(deps)).toBe('reloading');
    expect(reload).toHaveBeenCalledOnce();
  });
});

describe('ClientOutdated', () => {
  it('shows the blocking "Updating quickR…" overlay and reloads', async () => {
    const { reload, deps } = setup({ registration: null, container: null });
    render(<ClientOutdated deps={() => deps} />);
    expect(screen.getByRole('alertdialog')).toHaveTextContent('Updating quickR…');
    await vi.waitFor(() => {
      expect(reload).toHaveBeenCalledOnce();
    });
  });

  it('after a forced reload: the overlay asks to reload, and Reload ignores the guard', async () => {
    markForcedReload();
    const { reload, deps } = setup({ registration: null, container: null });
    render(<ClientOutdated deps={() => deps} />);
    expect(screen.getByRole('alertdialog')).toHaveTextContent(
      'quickR needs an update. Connect to the internet and reload.',
    );
    expect(reload).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole('button', { name: 'Reload' }));
    await vi.waitFor(() => {
      expect(reload).toHaveBeenCalledOnce();
    });
  });

  it('failed after a forced reload: a newly deployed worker is taken at once', async () => {
    markForcedReload();
    const { reg, container, reload, deps } = setup();
    render(<ClientOutdated deps={() => deps} />);
    expect(await screen.findByText(/Connect to the internet and reload/)).toBeInTheDocument();
    expect(reload).not.toHaveBeenCalled();
    // The hourly or on-resume update() finds the new frontend.
    const worker = new FakeWorker();
    worker.onSkip = () => container.dispatchEvent(new Event('controllerchange'));
    reg.installing = worker as unknown as ServiceWorker;
    reg.dispatchEvent(new Event('updatefound'));
    act(() => {
      worker.install(reg);
    });
    await vi.waitFor(() => {
      expect(reload).toHaveBeenCalledOnce();
    });
    expect(worker.postMessage).toHaveBeenCalledWith({ type: 'SKIP_WAITING' });
    expect(reg.unregister).not.toHaveBeenCalled();
  });

  it('offline: the overlay asks to connect and reload', async () => {
    const { reload, deps } = setup({ online: () => false });
    render(<ClientOutdated deps={() => deps} />);
    expect(await screen.findByText(/Connect to the internet and reload/)).toBeInTheDocument();
    expect(reload).not.toHaveBeenCalled();
  });

  it('unsaved changes are asked about first; "Not now" leaves the page usable', async () => {
    unsaved.value = true;
    const { reload, deps } = setup({ registration: null, container: null });
    render(<ClientOutdated deps={() => deps} />);
    expect(screen.queryByRole('alertdialog')).toBeNull();
    fireEvent.click(await screen.findByRole('button', { name: 'Not now' }));
    expect(reload).not.toHaveBeenCalled();
    fireEvent.click(await screen.findByRole('button', { name: 'Update' }));
    fireEvent.click(await screen.findByRole('button', { name: 'Update now' }));
    await vi.waitFor(() => {
      expect(reload).toHaveBeenCalledOnce();
    });
  });
});

describe('ServerBehindBanner (§5.4, V14)', () => {
  const levels = (level: number, min = 0) =>
    act(() =>
      observeResponse(
        new Response('{}', {
          headers: {
            'X-QuickR-Api-Level': String(level),
            'X-QuickR-Min-Client-Level': `ios=0, web=${String(min)}`,
          },
        }),
      ),
    );

  it('shows while the server is behind, without an overlay, and goes when it catches up', async () => {
    render(<ServerBehindBanner />);
    expect(screen.queryByRole('status')).toBeNull();
    await levels(API_LEVEL - 1);
    expect(screen.getByRole('status')).toHaveTextContent(
      'The quickR server is older than this app. It keeps working, but deploy the server to finish the update.',
    );
    expect(screen.queryByRole('alertdialog')).toBeNull();
    expect(hasForcedReload()).toBe(false);
    await levels(API_LEVEL);
    expect(screen.queryByRole('status')).toBeNull();
  });

  it('stays dismissed for the session', async () => {
    await levels(API_LEVEL - 1);
    const { unmount } = render(<ServerBehindBanner />);
    fireEvent.click(screen.getByRole('button', { name: 'Dismiss' }));
    expect(screen.queryByRole('status')).toBeNull();
    expect(sessionStorage.getItem(SERVER_BEHIND_DISMISSED_KEY)).not.toBeNull();
    unmount();
    render(<ServerBehindBanner />);
    expect(screen.queryByRole('status')).toBeNull();
  });

  it('gives way to the forced update when the bundle is also outdated', async () => {
    await levels(API_LEVEL - 1);
    render(<ServerBehindBanner />);
    act(() => {
      markClientOutdated();
    });
    expect(screen.queryByRole('status')).toBeNull();
  });
});

describe('UpdatePrompt, outdated (V10)', () => {
  afterEach(() => {
    client.setConfig({ baseUrl: '' });
    vi.unstubAllGlobals();
  });

  it('an outdated answer to the generated client replaces the card and runs update()', async () => {
    // Its 10 s wait for a new worker never fires (afterEach drops fake timers).
    vi.useFakeTimers();
    const { reg } = setup();
    setRegistration(reg as unknown as ServiceWorkerRegistration);
    render(
      <ToastProvider>
        <UpdatePrompt />
      </ToastProvider>,
    );
    expect(screen.getByText('Update available')).toBeInTheDocument();
    client.setConfig({ baseUrl: 'http://localhost' });
    vi.stubGlobal(
      'fetch',
      vi.fn(() =>
        Promise.resolve(
          new Response('{}', {
            headers: {
              'X-QuickR-Api-Level': String(API_LEVEL + 1),
              'X-QuickR-Min-Client-Level': `ios=0, web=${String(API_LEVEL + 1)}`,
            },
          }),
        ),
      ),
    );
    await act(() => getClientVersions());
    expect(screen.getByRole('alertdialog')).toHaveTextContent('Updating quickR…');
    expect(screen.queryByText('Update available')).toBeNull();
    expect(reg.update).toHaveBeenCalledOnce();
  });
});
