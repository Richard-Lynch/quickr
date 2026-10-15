/**
 * Web Push client plumbing, on top of the generated SDK:
 *   getPushConfig            GET  /api/v1/push/config               → { public_key } (VAPID)
 *   createPushSubscription   POST /api/v1/push/subscriptions        subscription.toJSON() + UA
 *   deletePushSubscription   POST /api/v1/push/subscriptions/delete { endpoint }
 *   sendTestPush             POST /api/v1/push/test                 → { sent, failed }
 * A server without push (404/405/501, e.g. an older backend) surfaces as `not-configured`
 * / `null` rather than as an error.
 *
 * iOS: Web Push only exists in Home Screen apps (iOS 16.4+), and the permission prompt
 * must come straight from a user gesture — call `enablePush()` synchronously inside the
 * click handler (it calls `Notification.requestPermission()` before any other await).
 */
import { errorMessage } from '../api/errors';
import type { PushSubscriptionIn, PushTestResult } from '../client';
import {
  createPushSubscription,
  deletePushSubscription,
  getPushConfig,
  sendTestPush as sendTestPushRequest,
} from '../client/sdk.gen';
import { detectPlatform, isStandalone, type Platform } from './platform';

export type PushSupport =
  | { state: 'available'; permission: NotificationPermission }
  | { state: 'denied' }
  /** iOS/iPadOS browser tab: push exists only once added to the Home Screen. */
  | { state: 'needs-install' }
  | { state: 'unsupported'; reason: string };

export interface PushEnv {
  platform: Platform;
  standalone: boolean;
  secure: boolean;
  serviceWorker: boolean;
  pushManager: boolean;
  notification: boolean;
  permission: NotificationPermission | null;
}

export function currentPushEnv(): PushEnv {
  const w = typeof window === 'undefined' ? undefined : window;
  return {
    platform: detectPlatform(),
    standalone: isStandalone(),
    secure: w?.isSecureContext ?? false,
    serviceWorker: typeof navigator !== 'undefined' && 'serviceWorker' in navigator,
    pushManager: w !== undefined && 'PushManager' in w,
    notification: w !== undefined && 'Notification' in w,
    permission: w !== undefined && 'Notification' in w ? Notification.permission : null,
  };
}

/** Pure decision table (unit-tested). */
export function evaluatePushSupport(env: PushEnv): PushSupport {
  if (!env.secure) return { state: 'unsupported', reason: 'Notifications need HTTPS.' };
  if (env.platform.os === 'ios' && !env.standalone) return { state: 'needs-install' };
  if (!env.serviceWorker || !env.pushManager || !env.notification) {
    return {
      state: 'unsupported',
      reason:
        env.platform.os === 'ios'
          ? 'Notifications need iOS 16.4 or later.'
          : 'This browser does not support web push.',
    };
  }
  if (env.permission === 'denied') return { state: 'denied' };
  return { state: 'available', permission: env.permission ?? 'default' };
}

export function pushSupport(): PushSupport {
  return evaluatePushSupport(currentPushEnv());
}

/** VAPID keys are base64url; `pushManager.subscribe` wants bytes. */
export function urlBase64ToUint8Array(base64url: string): Uint8Array<ArrayBuffer> {
  const padded = base64url.padEnd(base64url.length + ((4 - (base64url.length % 4)) % 4), '=');
  const bin = atob(padded.replace(/-/g, '+').replace(/_/g, '/'));
  const out = new Uint8Array(new ArrayBuffer(bin.length));
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export function subscriptionBody(sub: PushSubscription): PushSubscriptionIn {
  const json = sub.toJSON();
  return {
    endpoint: sub.endpoint,
    keys: { p256dh: json.keys?.p256dh ?? '', auth: json.keys?.auth ?? '' },
    user_agent: navigator.userAgent.slice(0, 500),
  };
}

/** Thrown for unexpected API failures (not for "endpoint not there"). */
export class PushApiError extends Error {
  readonly status: number | null;
  constructor(message: string, status: number | null) {
    super(message);
    this.name = 'PushApiError';
    this.status = status;
  }
}

const NOT_READY = new Set([404, 405, 501]);

interface SdkResult<T> {
  data?: T | undefined;
  error?: unknown;
  response?: Response | undefined;
}

/** Unwrap an SDK result: data, `null` when the server has no push, else throw. */
async function unwrap<T>(call: Promise<SdkResult<T>>): Promise<T | null> {
  let r: SdkResult<T>;
  try {
    r = await call;
  } catch (err) {
    // Request/response validation (ZodError) or a network failure.
    throw new PushApiError(errorMessage(err), null);
  }
  const status = r.response?.status ?? null;
  if (status !== null && NOT_READY.has(status)) return null;
  if (r.error !== undefined || status === null || !r.response?.ok) {
    throw new PushApiError(
      status === null ? 'Could not reach the server' : errorMessage(r.error ?? `HTTP ${status}`),
      status,
    );
  }
  return r.data ?? null;
}

const noStore = { cache: 'no-store' } as const;

/** VAPID public key, or null when the backend has no push support. */
export async function fetchPushConfig(): Promise<{ public_key: string } | null> {
  const c = await unwrap(getPushConfig(noStore));
  return c?.public_key ? { public_key: c.public_key } : null;
}

async function registration(): Promise<ServiceWorkerRegistration | null> {
  if (!('serviceWorker' in navigator)) return null;
  return (await navigator.serviceWorker.getRegistration()) ?? null;
}

export async function getPushSubscription(): Promise<PushSubscription | null> {
  try {
    const reg = await registration();
    return (await reg?.pushManager.getSubscription()) ?? null;
  } catch {
    return null;
  }
}

function sameKey(sub: PushSubscription, key: Uint8Array): boolean {
  const current = sub.options.applicationServerKey;
  if (!current) return false;
  const a = new Uint8Array(current);
  return a.length === key.length && a.every((b, i) => b === key[i]);
}

export type EnablePushResult =
  | { ok: true }
  | { ok: false; reason: 'denied' | 'dismissed' | 'not-configured' | 'no-service-worker' };

/**
 * Ask for permission, subscribe, register the subscription with the API.
 * Call it directly from a click/tap handler. `publicKey` can be prefetched with
 * `fetchPushConfig()` so nothing slow happens before the permission prompt.
 */
export async function enablePush(publicKey?: string): Promise<EnablePushResult> {
  const permission = await Notification.requestPermission();
  if (permission !== 'granted') {
    return { ok: false, reason: permission === 'denied' ? 'denied' : 'dismissed' };
  }
  const key = publicKey ?? (await fetchPushConfig())?.public_key;
  if (!key) return { ok: false, reason: 'not-configured' };
  const reg = await registration();
  if (!reg) return { ok: false, reason: 'no-service-worker' };

  const keyBytes = urlBase64ToUint8Array(key);
  let sub = await reg.pushManager.getSubscription();
  if (sub && !sameKey(sub, keyBytes)) {
    // Server rotated its VAPID key: the old subscription can't receive our pushes.
    await sub.unsubscribe();
    sub = null;
  }
  sub ??= await reg.pushManager.subscribe({
    userVisibleOnly: true,
    applicationServerKey: keyBytes,
  });

  let saved: unknown;
  try {
    saved = await unwrap(createPushSubscription({ body: subscriptionBody(sub) }));
  } catch (err) {
    await sub.unsubscribe().catch(() => undefined);
    throw err;
  }
  if (saved === null) {
    await sub.unsubscribe().catch(() => undefined);
    return { ok: false, reason: 'not-configured' };
  }
  return { ok: true };
}

/** Unsubscribe locally and tell the API (best effort). */
export async function disablePush(): Promise<void> {
  const sub = await getPushSubscription();
  if (!sub) return;
  const { endpoint } = sub;
  await sub.unsubscribe().catch(() => undefined);
  await unwrap(deletePushSubscription({ body: { endpoint } })).catch((err: unknown) => {
    console.warn('[push] could not remove the subscription on the server', err);
  });
}

/**
 * Ask the API to push a test notification to every subscription.
 * `null` when the server has no push support.
 */
export async function sendTestPush(): Promise<PushTestResult | null> {
  return unwrap(sendTestPushRequest(noStore));
}
