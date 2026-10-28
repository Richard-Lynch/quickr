# Spec: client API levels and forced updates

**Status:** draft, revision 5, 2026-10-28 (reviewed against `main` after the
timers milestone, v0.3.0). **Milestone CV, a follow-on after the timers
milestone (T)**; not a prerequisite for it. **Applies to:** the backend, the PWA
and the iOS app. **Replaces part of:**
[compatibility.md](../ios/specs/compatibility.md) (§7 here says how).

**Changes in revision 3.** The level is copied into each component, since the
backend and frontend images are built from their own directories and can't read
`shared/` (§2). A 426 carries the identity and server-time headers (§3.3). Live
Activity and APNs token registrations are covered, and so are run events (§3.4,
§4.1). The PWA hold is a new outbox outcome, and it hooks `timedFetch` (§5). The
"server needs updating" warning is specified and tested on both clients (§3.3,
§4.5, §5.4, V13, V14). The floor WP and the level-0 store migration are gone.
Builds from before CV are unsupported, so both minimums stay at 0 until the
first breaking change raises them (§4.2, §4.3).

**Changes in revision 4 (review of revision 3).**

- The level is stored on the Live Activity token itself, so a user who denied
  notifications still gets Live Activity pushes (§3.4).
- The emergency override is clamped to `api_level` (§2).
- The PWA reloads without unregistering its service worker, so the Web Push
  subscription is kept (§5.2), and it sends nothing while it knows it's
  outdated (§5.3).
- The request goldens use a fixed placeholder, and the header is checked only
  on this commit's goldens. The 426 fixture is kept out of `shared/fixtures/api`
  (§6).
- Owed APNs deletions don't age while outdated (§4.1). The level headers are
  added to the CORS `expose_headers` (§3.2). `timedFetch` merges the header into
  a `Request` (§3.1).

**Changes in revision 5.**

- The goldens' header assertion moves to CV-IOS-DATA. The replay fills in
  `<level>` and `<build>` (§6).
- The PWA's outdated state is in memory only (§5.3).
- Clearing the flag resets owed deletions' `firstAttemptAt` (§4.1).

## Purpose

quickR has one user. The user said it is fine to force an update rather than
keep old app builds working: "Ideally we'd have a mechanism for this where the
backend provides an api version on responses with information on minimum ui
version and if they're out of sync it prompts an update (react or iOS!)". For
the timers release they went further: "No build compatibility for this version!"

This spec defines that mechanism:

- the server says which API level it speaks and the minimum level each client
  platform needs;
- each client says which level it was built for;
- the server refuses a client below the minimum before any effect, so a stale
  build can't corrupt data;
- the client then stops syncing, keeps its unsent data, and asks the user to
  update.

Before this, compatibility meant "the server keeps every listed build working"
(compatibility.md §1). After it, a breaking change is allowed if it raises the
minimum in the same PR.

**Normative language.** **MUST**, **MUST NOT**, **SHOULD** and **MAY** follow
RFC 2119.

## 1. Why an API level, not a build number

The user suggested comparing build numbers. iOS build numbers are the UTC time
of the TestFlight upload (`ios/scripts/testflight.sh`), and the PWA's build id
is the bundle's build time (`__BUILD_TIME__`). **Neither is known when the
breaking PR is written**, so the PR can't set "minimum = the build that handles
this".

An **API level** is a small integer in the repository. A breaking PR bumps it,
and every client built from that commit or later carries it. Build numbers are
still sent, for logs and for the update screen.

## 2. The source of truth

One file, `shared/api-level.json`:

```json
{ "api_level": 2, "min_client_level": { "ios": 2, "web": 2 } }
```

The values change over time. This mechanism ships as `api_level: 1` with
`min_client_level: {ios: 0, web: 0}` (§4.3 says why both stay at 0). The first
breaking change after CV raises all three, as described below.

The backend and frontend images are built with their own directory as the Docker
context (`.github/workflows/release.yml`, `docker-compose.yml`), so neither can
read `shared/` at build or run time. Like the generated client, each component
gets a **committed, generated copy**. `make api-level` writes them, and CI fails
when one is stale (§7, V12):

| Reader  | Copy                                                                                                                                                                                                      |
| ------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Backend | `backend/app/api_level.json`, loaded at import by `backend/app/client_versions.py`                                                                                                                        |
| PWA     | `frontend/src/api/apiLevel.json`, imported by `vite.config.ts`, which defines `__API_LEVEL__`                                                                                                             |
| iOS     | `ios/QuickrKit/Sources/QuickrCore/APILevel.swift`, a generated `APILevel.current` constant. The app and every extension link QuickrCore, so every process has it with no `Info.plist` key or build phase. |

- `api_level` is the level of the API that this commit's server serves and this
  commit's clients speak.
- `min_client_level` is the lowest level the server accepts, per platform.
  `min_client_level ≤ api_level` always.
- An **emergency override**, `QUICKR_MIN_CLIENT_LEVEL_IOS` and
  `QUICKR_MIN_CLIENT_LEVEL_WEB` in the backend's environment, may only **raise**
  the minimum (a lower value is ignored with a warning). It is clamped to
  `api_level`: a higher value is used as `api_level`, with a warning, because no
  client could ever meet it. It exists to refuse every build below level N
  without a release. It can't single out one build, since builds at the same
  level are indistinguishable to it. It is not how a breaking change ships.

**When to bump.** Some changes are ones that a client at the current `api_level`
can't handle. They set `api_level += 1` and
`min_client_level.ios = min_client_level.web = api_level`. Such a change can be
in the API, such as a removed or renamed field or operation, a narrower type, a
new item kind the client would fail on, or changed semantics. It can also be in
a **push payload**: the APNs reminder (`apns-payload-vectors.json`) or the Live
Activity content state and attributes (`live-activity-vectors.json`,
`CONTENT_STATE_VERSION`), which the OpenAPI check can't see. Additive changes
bump nothing. CI enforces the API part (§7). Push payloads stay pinned by their
vectors and the `old clients` job.

## 3. On the wire

### 3.1 Clients send

Every `/api/v1` request from the PWA and the iOS app carries:

```
X-QuickR-Client: <platform>; level=<int>; build=<string>
```

- `platform` is `ios` or `web`.
- `level` is the client's built-in `api_level`.
- `build` is `CFBundleVersion` on iOS (for example `20261022.005113`, or `1` in
  a local build) and `__BUILD_TIME__` for the PWA. The server only logs it.
- On iOS, every request goes through `APIClient` over the one `Transport`. That
  covers the app, the widget extension (widgets, Controls, App Intents, the
  Action button and Live Activity buttons) and token registration, so the header
  is added in one place, next to `X-QuickR-Channel`. The NSE makes no requests.
- On the PWA, every request goes through `timedFetch`
  (`frontend/src/lib/runs/serverClock.ts`). That covers the generated client,
  the page's outbox and the service worker's outbox (`sw.ts`), so the header is
  added there too, next to `CHANNEL_HEADERS`. The generated client calls it with
  a `Request` (`client.gen.ts`, `_fetch(request)`), and the outbox calls it with
  a URL and an `init`. `timedFetch` merges the header into whichever one it
  gets, and never drops headers that are already there.

### 3.2 The server sends

Every `/api/v1` response carries these headers, errors and `/health` included.
They sit next to the identity and server-time headers of
`backend/app/api/identity.py`:

```
X-QuickR-Api-Level: 2
X-QuickR-Min-Client-Level: ios=2, web=2
```

They are static, so `IdentityHeadersMiddleware` adds them in
`send_with_identity`, on the same path as `X-QuickR-Server-Time`. That way its
own 500 answers carry them as well. Both are added to the CORS `expose_headers`
in `backend/app/main.py`, beside the identity and server-time headers.

And one endpoint, which is never refused:

```
GET /api/v1/client-versions   (operationId getClientVersions)
→ { api_level: 2, min_client_level: { ios: 2, web: 2 },
    update_url: { ios: "itms-beta://" } }
```

`update_url.ios` comes from `QUICKR_IOS_UPDATE_URL`, default `itms-beta://` (it
opens TestFlight). The iOS app falls back to the same default.

### 3.3 Enforcement

A middleware decides each `/api/v1` request **before the route runs**, so a
refused request has no effect at all. It is registered **inside**
`IdentityHeadersMiddleware` (added before it in `backend/app/main.py`), so a 426
carries `X-QuickR-Server-Id`, `X-QuickR-Epoch` and `X-QuickR-Server-Time` like
any other response. The iOS classifier decodes a Problem only from a response
whose identity headers match (sync-protocol.md §1.4). A clock sample still comes
from it (timers.md §5.1). `OPTIONS` requests are not checked.

| Request                                                   | Client level                                                 |
| --------------------------------------------------------- | ------------------------------------------------------------ |
| Has `X-QuickR-Client`                                     | Its `level`. A malformed header is level 0.                  |
| No `X-QuickR-Client`, but `X-QuickR-Channel: ios` or `ui` | **0**: an iOS build or PWA bundle from before this mechanism |
| Neither header (curl, the notebook, tests, scripts)       | Not checked                                                  |

Both clients already send `X-QuickR-Channel` on every request (`APIClient`; the
PWA's `clientConfig.ts`, outbox and service worker). That is what makes a pre-CV
build detectable at all.

The MCP server calls services in process, not over `/api/v1`, so it isn't
checked either.

A checked request whose level is below `min_client_level[platform]` gets:

```
426 Upgrade Required
Content-Type: application/problem+json
{ "type": "…/client_outdated", "code": "client_outdated", "status": 426,
  "title": "Update quickR",
  "detail": "This version of quickR is too old for the server. Update it from TestFlight (or reload the web app) to keep syncing. Nothing on this device has been lost.",
  "min_client_level": 2, "client_level": 1 }
```

**Reads and writes are both refused.** It is simpler, and safer: an outdated
client that can still read may misread new shapes and advance its cursor past
data it dropped (a new item kind in the change feed, say). The exceptions are
`/health` and `getClientVersions`.

**A client above the server's level is only warned.** This is a new build
against a server that hasn't been deployed yet. The user decided: "Just warning
I think, so the app will keep working if the api change is forwards compatible,
but I know it needs a bump for whatever reason". So:

- the server never refuses a client for being **above** its `api_level`;
- the clients keep syncing and flushing, and each request fails or succeeds on
  its own merits (a request the old server doesn't know, a new run event type
  say, fails the way any refused request does);
- when a response's `X-QuickR-Api-Level` is below the client's own level, the
  client shows a **non-blocking** note: "The quickR server is older than this
  app. It keeps working, but deploy the server to finish the update." It goes
  away as soon as a response reports a level at or above the client's (iOS §4.5,
  PWA §5.4).

### 3.4 Pushes to outdated devices

`registerApnsDevice` stores the client level from `X-QuickR-Client` in a new
`apns_devices.client_level` column (0 when the header is absent). The device
re-registers on every launch, so the column follows updates.

- **Reminders.** A device below the iOS minimum gets a **display-only**
  reminder: no `quick_log`, no `category` (so no Start action for a timed topic
  either, timers.md §10.2), and the body "Time to log · update quickR to log
  from here". Its action handlers would only be refused, and this way the
  reminder is still useful.
- **Live Activities.** `registerLiveActivity` stores the client level from
  `X-QuickR-Client` on the token itself, in a new
  `live_activity_tokens.client_level` column (0 when the header is absent). The
  level doesn't come from the `apns_devices` row: a user who denied
  notifications has no such row, because `PushRegistration` deletes it, but
  their Live Activity tokens still work. `push/live_activity.py` `_plan` sends
  nothing (no push-to-start, `update` or `end`) to a token whose `client_level`
  is below the iOS minimum. Its content state may have changed shape, and its
  buttons can't sync anyway. The app re-registers its tokens after an update,
  which refreshes the level. That device's own activity keeps updating locally
  (timers.md §10.3).
- **Web Push** is not gated. A PWA learns that it's outdated on its next request
  and reloads itself (§5.2). Until then, a notification action handled by its
  old service worker is held, not lost (§5.3).

## 4. iOS

### 4.1 The outdated state

The store's `sync_state` gains `client_outdated_min` (null, or the minimum the
server demanded). It is set by any of:

- a 426 `client_outdated` response, in any process. `APIClassifier` gains a row
  for it: a 426 with matching identity headers and code `client_outdated` is
  `APIOutcome.clientOutdated(min:)`, checked before "any other 4xx". A 426
  without identity headers stays `retryable(.unexpectedResponse)`;
- a response whose `X-QuickR-Min-Client-Level` for `ios` is above
  `APILevel.current`, checked with the identity headers (sync-protocol.md §1.4).

It is cleared when `APILevel.current ≥ client_outdated_min`, which is true at
the first launch after an update. It is also cleared when a response's minimum
is at or below the current level again (the server rolled back). The flag is per
store, so switching servers starts clean.

While it is set, in every process:

| Part                                                                     | Behaviour                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| ------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| App UI                                                                   | A blocking full-screen **"Update required"** view over everything else: "quickR needs an update to keep syncing with your server. Your unsynced changes (_N_) are safe on this iPhone." Buttons: **Open TestFlight** (`update_url.ios`) and **Check again** (`getClientVersions`, also called on every foreground). Settings ▸ Server stays reachable from it, so the user can switch servers.                                                                                                                                                                                           |
| Coordinator                                                              | Doesn't pull. `client_outdated_min` is checked before any request, like `identity_mismatch` (sync-protocol.md §5.4). Online-only reads (sync-protocol.md §11: stats, timing, export) aren't made either.                                                                                                                                                                                                                                                                                                                                                                                 |
| Outbox                                                                   | Claims are refused (a new condition in outbox.md §6.2). **Enqueue still works.** A `clientOutdated` outcome restores the item's pre-claim state and clears its claim fields, like 409 `epoch_mismatch` (outbox.md §5.2): the server refused it before any effect. Then the flusher releases `flush`. This holds for every kind, `run.event` included. A held start keeps its run's later events waiting by the ordering rule (timers.md §8.1), and each event keeps the `at` it was stamped with, so the run replays as tapped.                                                          |
| Widgets, Controls, App Intents, the Action button, Live Activity buttons | Enqueue as usual, so the tap is kept, and don't flush. The result says "Saved on this iPhone. Update quickR to sync." Widgets show a small "Update quickR" line. The Live Activity keeps updating from the local view of the run.                                                                                                                                                                                                                                                                                                                                                        |
| Notification actions                                                     | The handler enqueues as usual and doesn't flush. It posts "Saved on this iPhone. Update quickR to sync." once per launch.                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| NSE                                                                      | No change: it makes no requests.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| APNs and Live Activity token registration                                | Paused, like any other request, and a `clientOutdated` outcome is **not settled**: the registration or deletion stays owed, so the updated build sends it. `LiveActivityTokens.Dependencies.api`'s `settled` already throws on any outcome that isn't `.success`, `.terminal` or `.notFound`, so the new case needs no change there. `PushRegistration`'s register `default:` branch MUST owe it. Owed APNs deletions don't age towards `pendingLifetime` while outdated: when `client_outdated_min` clears, every owed row's `firstAttemptAt` is reset to now, in the same transaction. |

**Nothing queued is lost.** Items stay `pending` or `uncertain` and are sent by
the updated build, which reads the same store file. A store migration in a later
build that changes the outbox schema MUST migrate them.

### 4.2 Builds before the mechanism (level 0)

Every build before CV (the timers build included) doesn't send
`X-QuickR-Client`, so the server sees it as level 0. Because the user doesn't
need old builds supported, nothing is built for them. CV ships with
`min_client_level.ios = 0` (§4.3), so a pre-CV build keeps working against the
CV server, which is purely additive for it. It is refused only by the first
breaking change after CV. If the user is still on a pre-CV build then, it
doesn't know the 426:

- **Sync:** each pull fails, and the sync pill shows "Sync error". Nothing is
  applied, so the local store keeps the last good state.
- **Outbox:** 426 is "any other 4xx" to it (outbox.md §5.1), so each item it
  sends becomes `failed/rejected` with the Problem's `detail` as its message.
  The message tells the user to update. The item is **kept**, not dropped, so
  its data survives, and the user can retry it from the sync sheet after
  updating.
- **Reminders:** display-only (§3.4).

There is no store migration to revive these items. The case needs the user to
skip every CV-or-later TestFlight build until a breaking release, and a manual
retry covers it.

### 4.3 No floor step

Revision 2 had a separate floor step (CV-FLOOR). It waited until the first CV
build was installed, then raised `min_client_level.ios` to 1, so that level-0
builds were refused only once a build that shows the prompt was on the phone.
With no old builds to support, it isn't needed:

- CV is additive for every existing client, so there is nothing to refuse level
  0 for. Both minimums ship at 0.
- The first breaking change after CV raises both minimums to its new `api_level`
  (≥ 2) anyway. That refuses level-0 and level-1 builds alike, with no separate
  PR and no "confirm it's installed" step.
- The cost is §4.2's fallback, for a user who skipped every CV build.

The forced-update path is therefore first exercised in production by the first
breaking change. Until then, V6–V10 and V13–V14 cover it.

### 4.4 Tolerant decoding, from the CV build on

The CV build also stops failing a feed page on an unknown item or deletion kind:
it skips them (sync-protocol.md §2.2 "Every row decodes" is amended to say so).
This doesn't replace bumping the level for a kind a build must understand, but
it means a purely optional new kind no longer forces an update.

### 4.5 The "server needs updating" note

`sync_state` gains `server_api_level` (null, or the `X-QuickR-Api-Level` of the
latest response with matching identity headers), written by any process. When it
is below `APILevel.current`, the app shows the non-blocking note of §3.3. The
note is a banner at the top of Home, which the user can dismiss for that launch,
and a line in Settings ▸ Server. Nothing else changes: the coordinator pulls,
the outbox flushes, and widgets and intents behave as usual. The note goes away
when `server_api_level` is at or above `APILevel.current`.

## 5. PWA

### 5.1 Detecting

`timedFetch` (§3.1) adds `X-QuickR-Client: web; level=…; build=…` to every
request and reads `X-QuickR-Api-Level` and `X-QuickR-Min-Client-Level` from
every response. It ignores responses the service worker or an HTTP cache served
(`X-QuickR-From-Cache`, `Age`): their headers are old, as for the server-time
sample. The app is **outdated** when the `web` minimum is above `__API_LEVEL__`,
or when a response is 426 `client_outdated`. The service worker learns the same
from its own sends and posts it to the open pages.

### 5.2 The update path

Release builds both images from the same `v*` tag, so a newer bundle is normally
on the server when the minimum rises. The existing `UpdatePrompt`
(`frontend/src/components/pwa/UpdatePrompt.tsx`) checks hourly and on resume,
and shows a dismissable "Update available" card. When outdated:

1. Call `registration.update()` at once.
2. If a worker is waiting, or becomes waiting within 10 s, post `SKIP_WAITING`
   (`sw.ts` already handles it), and reload when `controllerchange` fires.
3. If no new worker appears, do `location.reload()`. The service worker is
   **not** unregistered: unregistering deletes the Web Push subscription, and
   `push.ts` doesn't subscribe again. nginx serves `sw.js` with `no-cache`, so
   `update()` sees a new worker whenever one has been deployed.
4. **No reload loop.** A forced reload is recorded in `sessionStorage`. If the
   bundle that loads after one is still outdated, the frontend image is behind
   the backend (or the override locked this bundle out). The app then doesn't
   reload again, and shows the blocking overlay with a Reload button. Any fresh,
   not-cached response that doesn't say outdated clears the mark.
5. Meanwhile a **blocking** "Updating quickR…" overlay replaces the dismissable
   card. If the update can't complete (offline, or step 4), the overlay says
   "quickR needs an update. Connect to the internet and reload." with a Reload
   button.
6. Unsaved form changes: the existing `hasUnsavedChanges` confirm runs first,
   and the user can copy their text out. Their **outbox** isn't at risk: it
   lives in IndexedDB.

### 5.3 The outbox and the service worker

- The PWA's `Outcome` (`frontend/src/lib/outbox/types.ts`) gains `'held'`.
  `classifyStatus` itself is unchanged. The outbox checks for 426
  `client_outdated` before a kind's `classify` hook, because the code is in the
  body. A held item is restored to `pending` with its attempt not counted and no
  backoff, `maybeDelivered` unchanged, and the pass stops. The updated bundle
  sends it. This covers every kind, `run.event` included (timers.md §8.2).
- **Nothing is sent while outdated is known**, by the page or by the service
  worker. Each records the state when it sees it (§5.1) and stops flushing. The
  state is kept **in memory only**, so a reload or a service worker restart
  checks again with its next request. A persisted flag could never clear once
  the server's minimum dropped, since nothing would be sent to find out. A
  Background Sync event that finds the app outdated **resolves** rather than
  rejects, so the browser doesn't retry it on its own.
- A notification click handled by an old service worker enqueues as usual. Its
  send is held, and the item is kept for the new bundle.
- outbox.md §5.1's base table, which is byte-compatible with the PWA's
  `classifyStatus`, gains the same row: on both clients, 426 `client_outdated`
  holds the item and never fails it.

### 5.4 The "server needs updating" note

When a response's `X-QuickR-Api-Level` is below `__API_LEVEL__`, the app shows
the note of §3.3 as a dismissable banner, which stays dismissed for the session.
It doesn't block, reload or hold anything. It goes away when a response reports
a level at or above `__API_LEVEL__`.

## 6. Tests

| #   | Case                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     | Where           |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------- |
| V1  | Every `/api/v1` response (2xx, 4xx, 426, an unhandled 500, `/health`) carries both new headers. A 426 also carries the identity and server-time headers.                                                                                                                                                                                                                                                                                                                                                                                                                 | pytest          |
| V2  | Below the minimum: a POST, a PATCH, a DELETE, a GET and a `recordRunEvent` each answer 426 `client_outdated`, and **nothing is written** (row counts, run events, change log, `deleted_ids` unchanged).                                                                                                                                                                                                                                                                                                                                                                  | pytest          |
| V3  | Channel `ios` or `ui` without `X-QuickR-Client` is level 0. No headers at all is not checked. `OPTIONS`, `getClientVersions` and `/health` are never refused. A level above `api_level` is not refused.                                                                                                                                                                                                                                                                                                                                                                  | pytest          |
| V4  | The env override raises the minimum and is ignored (with a warning) when it would lower it. An override above `api_level` is clamped to `api_level`, with a warning.                                                                                                                                                                                                                                                                                                                                                                                                     | pytest          |
| V5  | `registerApnsDevice` and `registerLiveActivity` store the level. The reminder for a device below the minimum has no category and no `quick_log`. The Live Activity planner sends no start, update or end to a token below the minimum, and still sends to one at the minimum, including a token whose device has no `apns_devices` row (notifications denied).                                                                                                                                                                                                           | pytest          |
| V6  | iOS outbox: a 426 restores the pre-claim state, sets `client_outdated_min`, and refuses later claims. Enqueue still works. A launch at a higher level clears the flag and the item is sent. Covered for an `entry.create` and a `run.event` start with a queued lap.                                                                                                                                                                                                                                                                                                     | host            |
| V7  | iOS classifier and registrations: 426 `client_outdated` with matching identity headers is `clientOutdated`, and without them is retryable. An APNs or Live Activity token registration refused with it stays owed, and clearing the flag resets owed deletions' `firstAttemptAt`. `APIClient` sends `X-QuickR-Client` with `level=APILevel.current`.                                                                                                                                                                                                                     | host            |
| V8  | Widget, intent, Live Activity button and notification-action writes while outdated: the item is durable, no request is made, and the result text is the update message.                                                                                                                                                                                                                                                                                                                                                                                                  | host (MP)       |
| V9  | The "Update required" view appears when a response's minimum is above the build's level, and leaves on **Check again** after the server's minimum drops.                                                                                                                                                                                                                                                                                                                                                                                                                 | sim (UI)        |
| V10 | PWA: an outdated response, through the generated client (a `Request`) or the outbox, triggers `update()`, then `SKIP_WAITING` and a reload. With no new worker it reloads without unregistering, and the push subscription survives. A second outdated load doesn't reload again, and a fresh response that isn't outdated clears the guard. While outdated, neither the page nor the service worker sends, and a Background Sync event resolves. The outbox item (an entry and a run event) is held, not failed, and survives. A cached response's headers are ignored. | vitest          |
| V11 | CI checks (§7): a fixture repo where `openapi.json` breaks against the tag fails unless `api_level` and both minimums were raised.                                                                                                                                                                                                                                                                                                                                                                                                                                       | pytest          |
| V12 | The generated copies (§2) match `shared/api-level.json`: `backend/app/api_level.json`, `frontend/src/api/apiLevel.json` and `APILevel.swift`.                                                                                                                                                                                                                                                                                                                                                                                                                            | CI              |
| V13 | iOS, server behind: a response with `X-QuickR-Api-Level` below `APILevel.current` sets `server_api_level` and shows the Home banner and the Settings line. The coordinator still pulls and the outbox still flushes. A later response at the level removes the note.                                                                                                                                                                                                                                                                                                     | host + sim (UI) |
| V14 | PWA, server behind: a response with `X-QuickR-Api-Level` below `__API_LEVEL__` shows the dismissable banner. No overlay, no reload, and the outbox still sends. A later response at the level removes it.                                                                                                                                                                                                                                                                                                                                                                | vitest          |

The request goldens (`shared/fixtures/requests`) gain the `X-QuickR-Client`
header on every request. They are rendered by iOS `RequestGoldenTests`
(`goldensMatchCommitted`) from the real `APIClient` and compared byte for byte,
so the test renders a fixed placeholder, `ios; level=<level>; build=<build>`.
A bump and the build number, which changes with every upload, therefore don't
change the goldens. Because of the placeholder, V7 also checks with a one-line
unit test that `APIClient` sends `APILevel.current`.

The goldens gain the header in CV-IOS-DATA, so that WP also adds the
assertion: `test_request_goldens.py` checks that every golden of this commit
carries `X-QuickR-Client` with the placeholder. It skips the check when
`QUICKR_REQUEST_GOLDENS_DIR` is set: `compat/old-requests.sh` replays a listed
client's goldens through the same contract test, and a pre-CV build's goldens
(such as `20261026.143027`, once #73 merges) have no header. Asserting it there
would turn the `old requests` gate red. CV-SERVER asserts nothing about the
header in the goldens, which don't have it yet.

The replay's `Substituting` transport replaces `<level>` and `<build>` in
`X-QuickR-Client` along with its other placeholders. `<level>` is the
`api_level` of `shared/api-level.json`, or, when replaying a listed client, its
`api_level` in `compat/supported-clients.json`. `<build>` is any fixed string.
Without this, every replay would get a 426 after the first bump.

The 426 `client_outdated` Problem is **not** added to `shared/fixtures/api`.
An old client's `FixtureCoverageTests` run in the `old clients` job, and they
would fail on a fixture they don't know. It is tested with an inline body
instead.

## 7. The compatibility gate under this policy

compatibility.md stays, with these changes (one PR, CV-COMPAT):

1. **The rule (§1).** The server MUST stay compatible with every listed build
   **whose API level is at least the server's `min_client_level.ios`**. Builds
   below it are refused by the server and are not checked.
2. **`compat/supported-clients.json`.** Each client gains `"api_level"`. A
   client without one, such as the timers build listed by the open record PR #73
   (`20261026.143027`), is level 0. `client_fixtures.py` lists only the clients
   at or above the minimum in `shared/api-level.json`, and prints the ones it
   skips. `client_fixtures.py add` (the TestFlight `record` job and manual adds)
   writes the `api_level` from `shared/api-level.json` at the build's sha. A
   listed client below the minimum MAY be removed in the same PR that raises it.
3. **`openapi breaking` (§2).**
   - Against each **supported** listed client: unchanged. A break against one of
     them fails. The only way to break such a client is to raise the minimum
     above it, and that removes it from the comparison.
   - Against the **newest `v*` tag**, which stands for the deployed PWA and any
     unlisted build: a break at ERR level passes **only if** this PR raises
     `api_level` and sets both minimums to it, compared with the tag's
     `shared/api-level.json`. Otherwise it fails with "a breaking change must
     bump shared/api-level.json". A tag older than CV has no file, which counts
     as `{api_level: 0, min: 0}`. `openapi-break-approvals.txt` stays for breaks
     that are deliberately not breaking for any client (for example a field no
     client reads), but bumping is the normal path.
4. **A new check (`api level`, ubuntu, every PR).**
   `min_client_level ≤ api_level`, and neither went down compared with the base
   branch. The generated copies are fresh (V12).
5. **Fallbacks (§3).** The `fallbacks` mechanism stays for the rare additive
   change that an old supported build reads differently.

**Deploying a bump.** A `v*` tag publishes both images and uploads a TestFlight
build from the same commit (compatibility.md §5). Between the deploy and the
user installing the new build, the app shows "Update required" and keeps its
queued writes. That window is the cost of this policy, and the user accepted it.

## 8. Plan (milestone CV, after T)

Branch `feat/client-versions`, cut from `main` (T merged as v0.3.0). The scope
guard and conventions of [timers-plan.md](timers-plan.md) apply, with issues
labelled `cv-followup`. `compat/supported-clients.json` is empty on `main`.
Record PR #73 would list the timers build, at level 0 under §7. Either way, the
gate passes, since CV is additive.

### CV-SERVER · API level, headers and enforcement · be · M

- **Scope:** `shared/api-level.json` at
  `{api_level: 1, min_client_level: {ios: 0, web: 0}}`, `make api-level` and the
  backend copy (§2); `backend/app/client_versions.py`; the response headers in
  `IdentityHeadersMiddleware` and the enforcing middleware inside it
  (client-versions.md §3.2–§3.3), including the 426 `client_outdated` Problem;
  `getClientVersions`; the env overrides and `QUICKR_IOS_UPDATE_URL`;
  `client_level` on `apns_devices` and `live_activity_tokens`, display-only
  reminders and no Live Activity pushes below the iOS minimum (§3.4); the
  CORS `expose_headers`; the `Substituting` transport fills in
  `X-QuickR-Client` when a golden has it (§6). It asserts nothing about the
  header, since the goldens gain it in CV-IOS-DATA.
- **Areas:** `shared/api-level.json`, `Makefile`, `backend/app/api_level.json`
  (generated), `backend/app/client_versions.py` (new),
  `backend/app/api/identity.py` (or a sibling middleware module),
  `backend/app/main.py`, `backend/app/config.py`, `backend/app/models.py`,
  `backend/app/services/push/` (`apns.py`, `live_activity.py`),
  `backend/app/services/scheduler.py`, `backend/alembic/versions/` (the two
  level columns), `shared/fixtures/`, `openapi.json`, `frontend/src/client`
  (regenerated client only).
- **Depends on:** nothing.
- **Acceptance:** client-versions.md V1–V5; every existing test passes (they
  send no client headers, so they aren't checked).
- **Tests:** V1–V5.

### CV-COMPAT · the gate under the new policy · be · S

- **Scope:** client-versions.md §7: `api_level` on each listed client (missing
  means 0); `client_fixtures.py` checks only clients at or above the minimum,
  and `add` records the level; the `openapi breaking` tag rule (a break needs a
  bump); the new `api level` check (V12 included); compatibility.md updated to
  match.
- **Areas:** `compat/`, `.github/workflows/compat.yml`,
  `.github/workflows/testflight.yml` (only if the `record` step needs it),
  `docs/ios/specs/compatibility.md`.
- **Depends on:** CV-SERVER.
- **Acceptance:** client-versions.md V11 and V12; the gate passes with the
  current list.
- **Tests:** V11 against fixture repos; the workflow runs green on the PR.

### CV-IOS-DATA · client header, outdated state, held queue · host · M

- **Scope:** the generated `APILevel.swift`; `X-QuickR-Client` in `APIClient`;
  `APIOutcome.clientOutdated` in `APIClassifier`; `client_outdated_min` and
  `server_api_level` in `sync_state`; the coordinator and claim guards; the
  outbox's restore on `clientOutdated` (never fail), for every kind; APNs and
  Live Activity token registrations kept owed on it (§4.1); tolerant feed
  decoding (§4.4); result texts for widgets, intents, Live Activity buttons and
  notification actions (§4.1). The request goldens gain `X-QuickR-Client`,
  rendered as the fixed placeholder of §6 by `RequestGoldenTests`, and the
  `test_request_goldens.py` assertion that this commit's goldens carry it
  (skipped under `QUICKR_REQUEST_GOLDENS_DIR`, §6). The 426
  Problem is tested inline, not added to `shared/fixtures/api` (§6). The
  one-paragraph amendments to sync-protocol.md §2.2 and §3.1, and to outbox.md
  §5.1, §5.2 and §6.2.
- **Areas:** `ios/QuickrKit/Sources/QuickrCore/`,
  `ios/QuickrKit/Sources/QuickrData/API/`, `Contracts/`, `Store/`, `Sync/`,
  `Outbox/`, `Intents/`, `LiveActivity/`, `Notifications/`, `docs/ios/specs/`,
  `shared/fixtures/requests/`, `backend/tests/test_request_goldens.py`.
- **Depends on:** CV-SERVER.
- **Acceptance:** client-versions.md V6–V8 and the host part of V13; an unknown
  feed kind is skipped, not a page failure; every existing outbox, sync and Live
  Activity test passes.
- **Tests:** V6–V8, V13 (host); a decode test with an unknown item and deletion
  kind.

### CV-IOS-UI · the "Update required" screen and the server note · sim · S

- **Scope:** the blocking view, Open TestFlight, Check again, the server-switch
  escape, the widget line, and the "server needs updating" banner and Settings
  line (§4.1, §4.5).
- **Areas:** `ios/App/` (root view, Home, Settings), `ios/Widgets/`,
  `QuickrUI/`.
- **Depends on:** CV-IOS-DATA.
- **Acceptance:** client-versions.md V9 and the UI part of V13.
- **Tests:** V9 and V13 as UI tests against a fake transport.

### CV-PWA · header, detection, forced reload and the server note · fe · S

- **Scope:** the frontend copy of the level and `__API_LEVEL__` (§2);
  `X-QuickR-Client` and detection in `timedFetch` (§5.1); the update path of
  §5.2 with the blocking overlay and the loop guard; the `'held'` outcome
  (§5.3); the "server needs updating" banner (§5.4). `min_client_level.web`
  stays 0 (§4.3).
- **Areas:** `frontend/src/api/`, `frontend/src/lib/runs/serverClock.ts`,
  `frontend/src/components/pwa/`, `frontend/src/lib/outbox/`,
  `frontend/src/sw.ts`, `frontend/vite.config.ts`.
- **Depends on:** CV-SERVER.
- **Acceptance:** client-versions.md V10 and V14; the outbox parity tests pass.
- **Tests:** V10, V14.

## Open questions

None. The user decided the policy: forced updates are fine, no old builds are
supported, and a server behind the client is only a warning. The other choices
are recommendations made here and can be revisited in review: an API level over
a build number, refusing reads too, one shared file with generated copies, and
both minimums at 0 until the first breaking change.
