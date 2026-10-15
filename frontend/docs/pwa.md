# quickR as a PWA

How the installable/offline layer is put together, and the seams the feature work
(entries, schedules, push) plugs into. Primary target: **Chrome on iOS, added to the Home
Screen** — which is WebKit underneath, so everything that applies to iOS Safari applies.

| Concern                  | Where                                                                  |
| ------------------------ | ---------------------------------------------------------------------- |
| Manifest, SW build       | `vite.config.ts` (`vite-plugin-pwa`, `injectManifest`)                 |
| Service worker           | `src/sw.ts` (typechecked by `tsconfig.sw.json`, WebWorker lib)         |
| SW registration + update | `src/components/pwa/UpdatePrompt.tsx`                                  |
| Persisted query cache    | `src/api/persist.ts`, `src/api/queryClient.ts`                         |
| Mutation outbox          | `src/lib/outbox/*`, `src/api/outboxEffects.ts`, `src/api/entries.ts`   |
| Optimistic mutations     | `src/api/cache.ts`, `src/api/mutations.ts`, `src/lib/undo.ts`          |
| Push                     | `src/lib/push.ts`, `src/lib/pushPayload.ts`, `src/sw.ts`               |
| Badge (due count)        | `src/lib/badge.ts`, fed by `src/api/dueBadge.ts`                       |
| Quick-log + Undo         | `src/api/quickLog.ts`, `src/lib/quickLog.ts`, `components/topics/*`    |
| Install UX               | `src/lib/install.ts`, `src/lib/platform.ts`, `components/pwa/Install*` |
| Unsaved-changes guard    | `src/lib/unsavedChanges.tsx`                                           |
| Settings screen          | `src/pages/AppSettingsPage.tsx` (`/settings`)                          |
| Transport constants      | `src/api/constants.ts` (API prefix, channel header, SW cache name)     |

![Settings](screenshots/settings.png) ![Offline, waiting to sync](screenshots/offline-pending.png)
![Sync sheet](screenshots/sync-sheet.png) ![Install hint (Chrome on iOS)](screenshots/install-hint-ios-chrome.png)

## Icons and branding

`public/favicon.svg` is the source (a "q" with speed lines inside the maskable safe zone).
`pnpm gen:icons` regenerates `pwa-{64,192,512}`, `maskable-icon-512x512`,
`apple-touch-icon-180x180`, `favicon.ico` (`pwa-assets.config.ts`) and the monochrome
notification badge (`scripts/gen-badge.js`). Outputs are committed; builds don't need sharp.

## Service worker (`src/sw.ts`)

- Precaches the app shell (JS/CSS/HTML/icons + the latin font subsets) and serves
  `index.html` for navigations (denylist: `/api/`, `/mcp`, `/docs`, `/openapi.json`).
- `GET /api/v1/*` → **NetworkFirst**, 4 s timeout, cache `quickr-api`, 300 entries / 7 days.
  It's a fallback layer under the persisted query cache. Never cached: non-GET, `/mcp`,
  `*.csv`, `/api/v1/push/*`, `/api/v1/health`.
- Updates: `registerType: 'prompt'`. A new SW waits; the page shows "Update available —
  Reload" (asks first if any unsaved-changes guard is dirty). Checks for updates hourly and
  on resume. First install claims clients immediately so the first visit works offline.
- Background Sync tag `quickr-outbox` → flushes the outbox (Chromium only).
- `push` / `notificationclick` — see Push below.
- `nginx.conf` serves `/sw.js` and `/manifest.webmanifest` with `Cache-Control: no-cache` and
  the right MIME types. Service workers need HTTPS (or localhost).
- `PWA_DEV=1 pnpm dev` enables the SW in dev.

## Offline data

The TanStack Query cache is persisted to IndexedDB (`quickr-cache` DB) through an
`idb-keyval` persister (throttled 1 s, flushed on `pagehide`/hidden). Only successful queries
are stored (CSV export excluded). `maxAge` = `gcTime` = 7 days. **Buster** =
`<package version>+<hash of src/client/types.gen.ts>`, so regenerating the API client after a
backend change automatically drops cached data of the old shape.

Queries use `networkMode: 'offlineFirst'`: they still try the network (the SW may answer from
its cache); if that fails they pause and keep showing cached data. Mutations use
`networkMode: 'always'` — they fail fast offline with "Could not reach the server" instead
of hanging. Durable writes go through the outbox.

## Mutation outbox

A generic, durable queue in IndexedDB (`quickr-outbox` DB, `items` store). Item:

```ts
{ id /* client uuid */, kind, payload, created_at, updated_at,
  attempts, status: 'pending' | 'failed', next_attempt_at, last_error }
```

State machine (`src/lib/outbox/outbox.ts`, classification in `classify.ts`):

| Response                                      | Result                                                              |
| --------------------------------------------- | ------------------------------------------------------------------- |
| 2xx with JSON (or empty)                      | removed, `sent` event with the response body                        |
| network error / timeout (15 s) / 5xx          | stays `pending`, `attempts++`, backoff 2 s·2ⁿ ±20% (cap 5 min)      |
| 401, 403, 408, 425, 429, redirects, HTML 200s | retryable (auth proxy / captive portal / rate limit)                |
| other 4xx (400, 404, 409, 422 …)              | **terminal** → `failed`, needs the user (fix / retry as is/discard) |

A network error stops the current pass (the rest would fail the same way). Flushes are
coalesced in-page and serialised across tabs and the SW with a Web Lock
(`navigator.locks`, `quickr-outbox`). Post-send bookkeeping is compare-and-set on
`updated_at`, so a user's edit/discard during an in-flight send wins. Events
(`enqueued/updated/sent/retrying/failed/discarded/cleared`) are mirrored to other tabs and
from the SW via `BroadcastChannel('quickr-outbox')`.

Flush triggers (`src/lib/outbox/client.ts`). **WebKit has no Background Sync**, so the
in-page triggers are the primary mechanism:

- app start (after the persisted cache is restored), `online`, `visibilitychange → visible`,
  `pageshow` from bfcache — these ignore backoff (iOS freezes timers in the background);
- a timer armed for the next item's backoff deadline (≤ 60 s) while anything is pending;
- `registration.sync.register('quickr-outbox')` when an item is queued offline or a send
  fails retryably (Android/desktop Chrome: the SW flushes even with the app closed).

### Using it (`useOutbox()`)

```ts
const {
  items,
  pending,
  failed,
  pendingCount,
  failedCount,
  online,
  enqueue,
  sendNow,
  update,
  retry,
  discard,
  syncNow,
} = useOutbox();
```

No provider needed. UI already wired: header pill (`SyncIndicator`: "Offline",
"2 waiting to sync", "1 failed") → sync sheet (`OutboxPanel`: retry / fix / discard per item),
offline banner on the record screen, pending/failed cards at the top of a topic's entries,
the Settings screen.

### Adding a kind (seam for the feature agent)

1. **`src/lib/outbox/kinds.ts`** — payload type + `toRequest(item)` (+ `classify` if, say,
   404 on delete means done). Pure: it is bundled into the SW. Requests are built at _send_
   time, so changing `toRequest` also fixes items already queued.
2. **`src/api/outboxEffects.ts`** — `onEnqueue` (optimistic patch), `onSent` (reconcile with
   the server response + invalidate), `onFailed` / `onDiscard` (roll back).
3. **`src/components/pwa/Sync.tsx` → `describeOutboxItem`** — title / time / fix URL.
4. Enqueue: `const item = await outbox.enqueue(kind, payload)` then `outbox.sendNow(item.id)`
   (see `recordEntry` in `src/api/entries.ts` for the online-wait / offline-return flow).

### Entry creation (v2)

`entry.create` posts to `POST /api/v1/topics/{topic id}/entries` with
`{ ...payload.body, id: item.id }` (`entryCreateBody` in `kinds.ts`). The outbox
item id **is** the entry id, which has two effects:

- Creation is idempotent. A retry after a lost response gets the stored entry
  back (201) instead of creating a duplicate, so every retry is safe.
- An entry can be addressed before the server has seen it. Undo discards the
  item while it is queued, or sends `DELETE /entries/{id}` once it has synced
  (`useUndoLog` in `src/api/quickLog.ts`).

`recordEntry()` (`src/api/entries.ts`) checks the body against the generated
`zEntryCreate` before anything becomes durable. `outboxEffects.ts` parses
`EntryOut`, prepends it to the cached entry lists, and on enqueue bumps the
topic's counts and **clears its due state** (`dueAfterLogging`), so a logged
topic leaves "Due now" at once.

## Optimistic updates

`src/api/cache.ts` has typed helpers on the generated query keys
(`cancelOperations`, `snapshotOperations`, `restoreSnapshot`, `patchTopics`,
`patchEntries`, `prependEntry`). `src/api/mutations.ts` uses them:

- `useUpdateEntry`: patch list + detail, roll back on error, reconcile with the
  response.
- `useDeleteEntryWithUndo`: removes the entry at once and shows an **Undo**
  toast (6 s). The DELETE is only sent when the undo window closes (or the page
  is hidden, `src/lib/undo.ts`). A failure restores the entry.
- `useSetTopicArchived`: archive/unarchive flips at once. Archive has an Undo
  toast instead of a confirm. Deleting a topic keeps the typed confirm.
- `useUpdateTopicMeta`: name/description show at once (slug changes aren't
  optimistic).
- `useUpdateTopicSchedule`: the new schedule shows at once and the topic stops
  being due (a changed schedule is never due right away). The server's `due`
  replaces it on success.
- Logging (record screen and quick-log tiles): counts, last activity and due
  state change on enqueue. The entry shows as "Waiting to sync" until confirmed,
  then the server's row replaces it without flicker.

## Push

`src/lib/push.ts` uses the generated SDK (`getPushConfig`,
`createPushSubscription`, `deletePushSubscription`, `sendTestPush`):

- `pushSupport()` / `evaluatePushSupport(env)` →
  `available | denied | needs-install | unsupported`.
- `fetchPushConfig()` → `{public_key}`; a server without push (404/405/501) →
  `null`.
- `enablePush(publicKey?)`: **call it synchronously from the tap handler.** It
  calls `Notification.requestPermission()` first, then
  `pushManager.subscribe({userVisibleOnly: true, applicationServerKey})`
  (re-subscribing if the VAPID key rotated), then registers
  `{endpoint, keys:{p256dh, auth}, user_agent}`.
- `disablePush()` → unsubscribe + delete on the server.
- `sendTestPush()` → `{sent, failed}`. Settings shows the counts ("To 1 device",
  or "No device received it").

Payload contract (backend `PushPayload`): `{title, body, url, tag, topic_slug}`.
A due reminder has `url: "/t/{slug}/record"` and `tag: "due-{topic id}"`. In the
SW, `push` parses the payload (`parsePushPayload`). It is tolerant: a malformed
push still shows a notification, as `userVisibleOnly` requires. The notification
gets the icon/badge and its `tag` for de-dupe. On `notificationclick`, the SW
focuses an existing window and posts `{type:'quickr:navigate', url}` so the SPA
routes in place (state kept, unsaved guard respected), or opens a new window at
`url`. Only same-origin paths are honoured. A reminder therefore opens the
record screen directly. For pick-only topics, the chip tap there saves (2 taps
from the lock screen). For a single number, the value is prefilled.

Verified end to end in Chromium against the v2 backend: the subscription was
created via FCM, `POST /push/test` returned `{sent: 1}`, and the SW displayed
the notification. The scheduler's due reminder arrived with
`url: /t/water/record`.

Settings → Notifications shows the toggle and "Send a test notification". In an
iOS browser tab it shows Home Screen instructions instead. Per-topic
notification is the **Notify me when it's due** switch in the schedule editor.

**Badge:** `connectDueBadge(queryClient)` (`src/api/dueBadge.ts`, wired in
`main.tsx`) recomputes the number of due topics whenever an unfiltered topic
list changes (fetch, refetch, optimistic patch), plus once a minute. It calls
`setAppBadge(n)` and clears the badge at 0. On iOS the badge needs notification
permission.

## Install UX

`captureInstallPrompt()` (called in `main.tsx` before render) keeps `beforeinstallprompt` for
an "Install app" button (Android/desktop Chrome). On iOS a one-time dismissible card explains
_Chrome on iOS: Share icon in the address bar → Add to Home Screen_ / _Safari: Share → Add to
Home Screen_. Dismissal is remembered (`quickr.installHintDismissed`); never shown when
installed. Settings always shows install status.

## Unsaved-changes guard

```ts
const guard = useUnsavedChangesGuard(form.formState.isDirty, { message? });
// after a successful save, before navigating:
guard.allowNavigation();
// render once:
{guard.dialog}
```

`useBlocker` for in-app navigation (search/hash-only changes pass) with a confirm sheet, plus
`beforeunload`. Applied to: new topic, edit questions, topic details, record (only once
something is entered), entry edit, topic schedule (`EntryForm` has it built in; `onSubmit` and a function
`secondaryAction` receive `{ allowNavigation }`). `hasUnsavedChanges()` is used by the update
prompt.

## Standalone polish

- `viewport-fit=cover`; top bar height = 3.5 rem + `safe-area-inset-top`; page bottom padding,
  sticky actions, FABs and the update card respect `safe-area-inset-bottom`; left/right
  insets on the shell.
- `overscroll-behavior: none` (no pull-to-refresh / rubber-band), `touch-action:
manipulation` on controls, no text selection / callout on buttons, inputs ≥ 16 px.
- Every screen has an in-app back: `TopBar back` everywhere but the topic list; `back={true}`
  falls back to `/` when there's no history (deep link from a notification).
- `apple-mobile-web-app-status-bar-style` is `default` (legible in light and dark). Layout
  already pads for `black-translucent` if you prefer content under the status bar.

## iOS caveats

- All iOS browsers are WebKit: no Background Sync, no `beforeinstallprompt`, no
  `beforeunload` prompt. In-page flush triggers do the work; the outbox survives app kills.
- Web Push needs iOS/iPadOS 16.4+ and the app opened from the Home Screen; permission must be
  requested from a tap. Chrome on iOS can add to the Home Screen since iOS 16.4 — the
  installed app is the same WebKit web app either way.
- iOS may evict IndexedDB/Cache Storage for sites not used for a while (~7 days) **unless
  installed to the Home Screen** — installing matters for the offline queue.
- Timers stop in the background; anything pending is flushed on resume (`visibilitychange`).
- A Home Screen app has its own storage, separate from the browser tab's.

## Channel header

`X-QuickR-Channel: ui` is defined once in `src/api/constants.ts`. The SDK client config
(and therefore push), the outbox and the service worker all use it, so the server records
`channel: ui` for everything the app sends.
