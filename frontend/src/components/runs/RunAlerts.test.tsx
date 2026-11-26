/**
 * The PWA's run alerts while open (timers2.md §9.2, M1 F1-ALERTS), with fake timers: one
 * `setTimeout` to the next alert; a toast, vibration, a tone and (when granted) a
 * notification; mute; nothing while hidden; the 30 s late drop.
 */
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { act, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { fold } from '../../lib/runs/fold';
import type { LocalRun } from '../../lib/runs/localView';
import { resetServerOffset, SERVER_OFFSET_KEY } from '../../lib/runs/serverClock';
import type { RunEvent, Timer } from '../../lib/runs/types';
import { ev, T0 } from '../../test/runs';
import { setRegistration } from '../pwa/swRegistration';
import { ToastProvider } from '../ui/Toast';
import { topicVersionsOptions } from './context';
import { RunAlerts, RunAlertsFor, resetFiredAlerts, type AlertSource } from './RunAlerts';
import { ALERTS_MUTED_KEY, resetRunAudio, setAlertsMuted } from './useRunAudio';

const S = 1000;

const TIMER: Timer = {
  steps: [],
  laps: [
    { key: 'run', label: 'Run', alerts: [] },
    {
      key: 'rest',
      label: 'Rest',
      alerts: [
        { key: 'half', label: 'Half way', at: 't/2', at_ms: 30 * S },
        { key: 'done', label: 'Done', at: 't', at_ms: 60 * S },
      ],
    },
  ],
  variables: [{ name: 't', ms: 60 * S }],
};
const TOPIC = { id: 'topic-1', slug: 'intervals', name: 'Intervals' };

const start = ev('r1', 'start', T0);
/** `Rest 1` opens at REST_AT. */
const REST_AT = T0 + 5 * S;
const lap = ev('l1', 'lap', REST_AT, { seg: 0 });

function source(events: RunEvent[]): AlertSource {
  const state = fold('r1', TIMER, events);
  return {
    run: { id: 'r1', aliases: [], state },
    timer: TIMER,
    topic: TOPIC,
  };
}

// ---- the platform: vibrate, Web Audio, notifications, visibility -------------------------

const vibrate = vi.fn<(pattern: VibratePattern) => boolean>(() => true);
let tones = 0;

class FakeAudioContext {
  state: AudioContextState = 'suspended';
  currentTime = 0;
  destination = {};
  resume() {
    this.state = 'running';
    return Promise.resolve();
  }
  createOscillator() {
    return {
      type: 'sine',
      frequency: { value: 0, setValueAtTime: vi.fn() },
      connect: vi.fn(),
      start: () => {
        tones += 1;
      },
      stop: vi.fn(),
    };
  }
  createGain() {
    return {
      gain: {
        value: 0,
        setValueAtTime: vi.fn(),
        linearRampToValueAtTime: vi.fn(),
        exponentialRampToValueAtTime: vi.fn(),
      },
      connect: vi.fn(),
    };
  }
  createBuffer() {
    return {};
  }
  createBufferSource() {
    return { buffer: null, connect: vi.fn(), start: vi.fn() };
  }
}

let visibility: DocumentVisibilityState = 'visible';
function setVisibility(v: DocumentVisibilityState) {
  visibility = v;
  act(() => {
    document.dispatchEvent(new Event('visibilitychange'));
  });
}

const showNotification = vi.fn<(title: string, opts?: NotificationOptions) => Promise<void>>(() =>
  Promise.resolve(),
);
let permission: NotificationPermission = 'default';

beforeEach(() => {
  vi.useFakeTimers();
  vi.setSystemTime(REST_AT);
  resetServerOffset();
  resetFiredAlerts();
  resetRunAudio();
  localStorage.removeItem(ALERTS_MUTED_KEY);
  tones = 0;
  vibrate.mockClear();
  showNotification.mockClear();
  permission = 'default';
  visibility = 'visible';
  Object.defineProperty(navigator, 'vibrate', { value: vibrate, configurable: true });
  vi.stubGlobal('AudioContext', FakeAudioContext);
  vi.stubGlobal('Notification', {
    get permission() {
      return permission;
    },
  });
  Object.defineProperty(document, 'visibilityState', {
    configurable: true,
    get: () => visibility,
  });
  setRegistration({ showNotification } as unknown as ServiceWorkerRegistration);
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
  localStorage.removeItem(SERVER_OFFSET_KEY);
});

function mount(src: AlertSource) {
  const ui = (s: AlertSource) => (
    <ToastProvider>
      <RunAlertsFor sources={[s]} />
    </ToastProvider>
  );
  const view = render(ui(src));
  return { ...view, update: (s: AlertSource) => view.rerender(ui(s)) };
}

const advance = (ms: number) =>
  act(() => {
    vi.advanceTimersByTime(ms);
  });
const toastShown = (text: string) => screen.queryByText(text) !== null;

describe('RunAlerts', () => {
  it('fires a 60 s rest lap’s alerts at 30 s and 60 s, with one timeout pending', () => {
    mount(source([start, lap]));
    expect(vi.getTimerCount()).toBe(1);
    advance(30 * S - 1);
    expect(toastShown('Half way · Rest 1')).toBe(false);
    advance(1);
    expect(toastShown('Half way · Rest 1')).toBe(true);
    expect(vibrate).toHaveBeenCalledWith([200, 100, 200]);
    expect(tones).toBeGreaterThan(0);
    advance(30 * S - 1);
    expect(toastShown('Done · Rest 1')).toBe(false);
    advance(1);
    expect(toastShown('Done · Rest 1')).toBe(true);
    expect(vibrate).toHaveBeenCalledTimes(2);
  });

  it('shifts by a 10 s pause, and nothing fires while paused', () => {
    // Paused 25 s into Rest 1 for 10 s, across the 30 s mark.
    const pause = ev('p1', 'pause', REST_AT + 25 * S);
    const resume = ev('u1', 'resume', REST_AT + 35 * S, { pause_id: 'p1' });
    const view = mount(source([start, lap]));
    advance(25 * S);
    view.update(source([start, lap, pause]));
    expect(vi.getTimerCount()).toBe(0);
    advance(10 * S); // 35 s since the lap, 25 s active
    expect(toastShown('Half way · Rest 1')).toBe(false);
    view.update(source([start, lap, pause, resume]));
    advance(5 * S - 1);
    expect(toastShown('Half way · Rest 1')).toBe(false);
    advance(1); // 40 s since the lap = 30 s active
    expect(toastShown('Half way · Rest 1')).toBe(true);
    advance(30 * S - 1);
    expect(toastShown('Done · Rest 1')).toBe(false);
    advance(1); // 70 s = 60 s active
    expect(toastShown('Done · Rest 1')).toBe(true);
  });

  it('cancels on stop', () => {
    const view = mount(source([start, lap]));
    advance(10 * S);
    view.update(source([start, lap, ev('x', 'stop', REST_AT + 10 * S)]));
    expect(vi.getTimerCount()).toBe(0);
    advance(120 * S);
    expect(toastShown('Half way · Rest 1')).toBe(false);
    expect(vibrate).not.toHaveBeenCalled();
    expect(tones).toBe(0);
  });

  it('cancels on unmount', () => {
    const view = mount(source([start, lap]));
    view.unmount();
    expect(vi.getTimerCount()).toBe(0);
  });

  it('mute suppresses the sound and vibration but not the toast', () => {
    localStorage.setItem(ALERTS_MUTED_KEY, '1');
    mount(source([start, lap]));
    advance(30 * S);
    expect(toastShown('Half way · Rest 1')).toBe(true);
    expect(vibrate).not.toHaveBeenCalled();
    expect(tones).toBe(0);
  });

  it('follows the settings toggle between alerts', () => {
    mount(source([start, lap]));
    advance(30 * S);
    expect(vibrate).toHaveBeenCalledTimes(1);
    setAlertsMuted(true);
    advance(30 * S);
    expect(toastShown('Done · Rest 1')).toBe(true);
    expect(vibrate).toHaveBeenCalledTimes(1);
    setAlertsMuted(false);
    expect(localStorage.getItem(ALERTS_MUTED_KEY)).toBeNull();
  });

  it('fires nothing while hidden, and the tab resumes with the pending alert', () => {
    mount(source([start, lap]));
    advance(10 * S);
    setVisibility('hidden');
    expect(vi.getTimerCount()).toBe(0);
    advance(35 * S); // 45 s: "Half way" passed 15 s ago, unseen
    expect(toastShown('Half way · Rest 1')).toBe(false);
    expect(vibrate).not.toHaveBeenCalled();
    expect(showNotification).not.toHaveBeenCalled();
    setVisibility('visible');
    expect(toastShown('Half way · Rest 1')).toBe(true);
    advance(15 * S); // 60 s: the next one is on its timeout again
    expect(toastShown('Done · Rest 1')).toBe(true);
  });

  it('drops an alert more than 30 s late on return; one less late shows at once', () => {
    mount(source([start, lap]));
    advance(10 * S);
    setVisibility('hidden');
    advance(55 * S); // 65 s: "Half way" 35 s late, "Done" 5 s late
    setVisibility('visible');
    expect(toastShown('Half way · Rest 1')).toBe(false);
    expect(toastShown('Done · Rest 1')).toBe(true);
    expect(vibrate).toHaveBeenCalledTimes(1);
  });

  it('fires a timeout that comes due while hidden only on return', () => {
    mount(source([start, lap]));
    advance(29 * S);
    // Hidden without the event reaching us first (a frozen tab): the timeout must not fire.
    visibility = 'hidden';
    advance(2 * S);
    expect(toastShown('Half way · Rest 1')).toBe(false);
    setVisibility('visible');
    expect(toastShown('Half way · Rest 1')).toBe(true);
  });

  it('fires an alert once, though the runs change after it', () => {
    const view = mount(source([start, lap]));
    advance(30 * S);
    expect(vibrate).toHaveBeenCalledTimes(1);
    view.update(source([start, lap]));
    setVisibility('hidden');
    setVisibility('visible');
    expect(vibrate).toHaveBeenCalledTimes(1);
  });

  it('times alerts on the server clock', () => {
    // The server is 5 s ahead: its REST_AT + 30 s is this device's REST_AT + 25 s.
    localStorage.setItem(SERVER_OFFSET_KEY, String(5 * S));
    mount(source([start, lap]));
    advance(25 * S - 1);
    expect(toastShown('Half way · Rest 1')).toBe(false);
    advance(1);
    expect(toastShown('Half way · Rest 1')).toBe(true);
  });

  it('shows a notification when permission is granted', () => {
    permission = 'granted';
    mount(source([start, lap]));
    advance(30 * S);
    expect(showNotification).toHaveBeenCalledTimes(1);
    expect(showNotification).toHaveBeenCalledWith(
      'Intervals',
      expect.objectContaining({
        body: 'Half way · Rest 1',
        tag: 'quickr.alert.r1.1.half',
        data: { url: '/t/intervals/record' },
        silent: false,
      }),
    );
  });

  it('shows no notification without permission', () => {
    permission = 'denied';
    mount(source([start, lap]));
    advance(30 * S);
    expect(toastShown('Half way · Rest 1')).toBe(true);
    expect(showNotification).not.toHaveBeenCalled();
  });

  it('a muted notification is silent', () => {
    permission = 'granted';
    localStorage.setItem(ALERTS_MUTED_KEY, '1');
    mount(source([start, lap]));
    advance(30 * S);
    expect(showNotification).toHaveBeenCalledWith(
      'Intervals',
      expect.objectContaining({ silent: true }),
    );
  });

  it('unlocks the audio on a tap, so a later alert can sound', () => {
    const made: FakeAudioContext[] = [];
    vi.stubGlobal(
      'AudioContext',
      class extends FakeAudioContext {
        constructor() {
          super();
          made.push(this);
        }
      },
    );
    mount(source([start, lap]));
    fireEvent.click(document.body);
    expect(made).toHaveLength(1);
    expect(made[0]?.state).toBe('running');
  });
});

// ---- mounted: the local view and the topic's versions ----------------------------------

const runsMock = vi.hoisted(() => ({ runs: [] as LocalRun[] }));
vi.mock('../../lib/runs/useRuns', () => ({
  useRuns: () => ({ runs: runsMock.runs }),
}));

describe('RunAlerts (mounted)', () => {
  it('plans from the run’s pinned version and names the topic', () => {
    const state = fold('r1', TIMER, [start, lap]);
    runsMock.runs = [
      {
        id: 'r1',
        topic_id: TOPIC.id,
        topic: TOPIC,
        version: 1,
        status: state.status,
        state,
        events: [start, lap],
        aliases: [],
        server: null,
        queued: [],
        steps: [],
        requires_answers: false,
        laps: [],
        resuming: false,
        has_entry: false,
      },
    ];
    const qc = new QueryClient();
    qc.setQueryData(topicVersionsOptions(TOPIC.id).queryKey, [
      {
        version: 1,
        questions: [],
        timer: TIMER,
        change_note: '',
        created_at: '2026-10-01T00:00:00Z',
        entry_count: 0,
      },
    ] as never);
    render(
      <QueryClientProvider client={qc}>
        <ToastProvider>
          <RunAlerts />
        </ToastProvider>
      </QueryClientProvider>,
    );
    advance(30 * S);
    expect(toastShown('Half way · Rest 1')).toBe(true);
    runsMock.runs = [];
  });
});
