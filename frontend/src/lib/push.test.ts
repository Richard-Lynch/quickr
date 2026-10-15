import { afterEach, describe, expect, it, vi } from 'vitest';

import { detectPlatform } from './platform';
import {
  evaluatePushSupport,
  fetchPushConfig,
  sendTestPush,
  urlBase64ToUint8Array,
  type PushEnv,
} from './push';
import { isNavigateMessage, parsePushPayload, safeInAppPath } from './pushPayload';

const UA = {
  iosSafari:
    'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1',
  iosChrome:
    'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/130.0.6723.90 Mobile/15E148 Safari/604.1',
  ipadOS:
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15',
  android:
    'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36',
  mac: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36',
};

describe('detectPlatform', () => {
  it('tells iOS browsers apart (all WebKit)', () => {
    expect(detectPlatform(UA.iosSafari, 5)).toEqual({ os: 'ios', browser: 'safari' });
    expect(detectPlatform(UA.iosChrome, 5)).toEqual({ os: 'ios', browser: 'chrome' });
  });
  it('detects iPadOS posing as a Mac via touch points', () => {
    expect(detectPlatform(UA.ipadOS, 5)).toEqual({ os: 'ios', browser: 'safari' });
    expect(detectPlatform(UA.mac, 0)).toEqual({ os: 'desktop' });
  });
  it('detects Android', () => {
    expect(detectPlatform(UA.android, 5)).toEqual({ os: 'android' });
  });
});

const env = (patch: Partial<PushEnv>): PushEnv => ({
  platform: { os: 'android' },
  standalone: false,
  secure: true,
  serviceWorker: true,
  pushManager: true,
  notification: true,
  permission: 'default',
  ...patch,
});

describe('evaluatePushSupport', () => {
  it('is available on a capable browser', () => {
    expect(evaluatePushSupport(env({}))).toEqual({ state: 'available', permission: 'default' });
  });
  it('asks iOS users to install first (no PushManager in a tab)', () => {
    const ios = { os: 'ios', browser: 'chrome' } as const;
    expect(evaluatePushSupport(env({ platform: ios, pushManager: false }))).toEqual({
      state: 'needs-install',
    });
    expect(evaluatePushSupport(env({ platform: ios, standalone: true }))).toMatchObject({
      state: 'available',
    });
    expect(
      evaluatePushSupport(env({ platform: ios, standalone: true, pushManager: false })),
    ).toMatchObject({ state: 'unsupported', reason: expect.stringContaining('16.4') as string });
  });
  it('reports blocked permission and insecure origins', () => {
    expect(evaluatePushSupport(env({ permission: 'denied' }))).toEqual({ state: 'denied' });
    expect(evaluatePushSupport(env({ secure: false }))).toMatchObject({ state: 'unsupported' });
    expect(evaluatePushSupport(env({ serviceWorker: false }))).toMatchObject({
      state: 'unsupported',
    });
  });
});

describe('urlBase64ToUint8Array', () => {
  it('decodes unpadded base64url', () => {
    expect([...urlBase64ToUint8Array('AQID-_8')]).toEqual([1, 2, 3, 251, 255]);
  });
});

describe('push API helpers', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('treats a missing endpoint (404) as "not configured" instead of an error', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(() => Promise.resolve(new Response('', { status: 404 }))),
    );
    expect(await fetchPushConfig()).toBeNull();
    expect(await sendTestPush()).toBe(false);
  });

  it('returns the VAPID key and sends the channel header', async () => {
    const fetchMock = vi.fn(() =>
      Promise.resolve(
        new Response(JSON.stringify({ public_key: 'abc' }), {
          headers: { 'Content-Type': 'application/json' },
        }),
      ),
    );
    vi.stubGlobal('fetch', fetchMock);
    expect(await fetchPushConfig()).toEqual({ public_key: 'abc' });
    const [url, init] = (fetchMock.mock.calls[0] ?? []) as unknown as [string, RequestInit];
    expect(url).toBe('/api/v1/push/config');
    expect(init.headers).toMatchObject({ 'X-Quicker-Channel': 'ui' });
  });

  it('surfaces real server errors', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(() =>
        Promise.resolve(new Response(JSON.stringify({ detail: 'boom' }), { status: 500 })),
      ),
    );
    await expect(fetchPushConfig()).rejects.toThrow('boom');
  });
});

describe('push payload', () => {
  it('parses the contract and fills gaps', () => {
    expect(
      parsePushPayload({
        title: 'Time to log',
        body: 'Sleep',
        url: '/t/sleep/record',
        tag: 'due-sleep',
        topic_slug: 'sleep',
      }),
    ).toEqual({
      title: 'Time to log',
      body: 'Sleep',
      url: '/t/sleep/record',
      tag: 'due-sleep',
      topic_slug: 'sleep',
    });
    expect(parsePushPayload({ topic_slug: 'water' })).toMatchObject({
      title: 'quickR',
      url: '/t/water/record',
    });
    expect(parsePushPayload('not json')).toMatchObject({ title: 'quickR', body: 'not json' });
    expect(parsePushPayload(undefined)).toMatchObject({ url: '/' });
  });

  it('never opens other origins', () => {
    expect(safeInAppPath('https://evil.example/x')).toBe('/');
    expect(safeInAppPath('//evil.example')).toBe('/');
    expect(safeInAppPath('/t/a/record')).toBe('/t/a/record');
  });

  it('recognises navigate messages', () => {
    expect(isNavigateMessage({ type: 'quickr:navigate', url: '/x' })).toBe(true);
    expect(isNavigateMessage({ type: 'other' })).toBe(false);
    expect(isNavigateMessage(null)).toBe(false);
  });
});
