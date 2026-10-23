# Spec: client API levels and forced updates

**Status:** draft, revision 1, 2026-10-23. **Applies to:** the backend, the PWA
and the iOS app. **Replaces part of:**
[compatibility.md](../ios/specs/compatibility.md) (§7 here says how). **Needed
by:** [timers.md](timers.md), whose feed change is the first break shipped under
this policy.

## Purpose

quickR has one user. The user said it is fine to force an update rather than
keep old app builds working: "Ideally we'd have a mechanism for this where the
backend provides an api version on responses with information on minimum ui
version and if they're out of sync it prompts an update (react or iOS!)".

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
is the bundle's build time. **Neither is known when the breaking PR is
written**, so the PR can't set "minimum = the build that handles this".

An **API level** is a small integer in the repository. A breaking PR bumps it,
and every client built from that commit or later carries it. Build numbers are
still sent, for logs and for the update screen.

## 2. The source of truth

One file, `shared/api-level.json`:

```json
{ "api_level": 2, "min_client_level": { "ios": 2, "web": 2 } }
```

The values change over time. This mechanism ships as `api_level: 1` with
`min_client_level: {ios: 0, web: 1}`: the PWA is deployed with the server, so
its minimum can rise at once; the iOS minimum rises to 1 at the floor (§4.3).
Timed topics then raise all three to 2, as above.

| Reader  | How                                                                                                                         |
| ------- | --------------------------------------------------------------------------------------------------------------------------- |
| Backend | `backend/app/client_versions.py` loads it at import                                                                         |
| PWA     | `vite.config.ts` defines `__API_LEVEL__` from it                                                                            |
| iOS     | A build phase writes `QuickrAPILevel` into `Info.plist` from it (`ios/project.yml`); `QuickrCore.APILevel.current` reads it |

- `api_level` is the level of the API that this commit's server serves and this
  commit's clients speak.
- `min_client_level` is the lowest level the server accepts, per platform.
  `min_client_level ≤ api_level` always.
- An **emergency override**, `QUICKR_MIN_CLIENT_LEVEL_IOS` and
  `QUICKR_MIN_CLIENT_LEVEL_WEB` in the backend's environment, may only **raise**
  the minimum (a lower value is ignored with a warning). It exists to lock out a
  bad build without a release. It is not how a breaking change ships.

**When to bump.** A change that a client at the current `api_level` can't handle
(a removed or renamed field or operation, a narrower type, a new item kind the
client would fail on, changed semantics) sets `api_level += 1` and
`min_client_level.ios = min_client_level.web = api_level`. Additive changes bump
nothing. CI enforces this (§7).

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
- The iOS app's extensions (widgets, the NSE, intents) send it too, from the
  same `Info.plist` key.

### 3.2 The server sends

Every `/api/v1` response, errors and `/health` included, carries, next to the
identity headers of `backend/app/api/identity.py`:

```
X-QuickR-Api-Level: 2
X-QuickR-Min-Client-Level: ios=2, web=2
```

And one endpoint, which is never refused:

```
GET /api/v1/client-versions   (operationId getClientVersions)
→ { api_level: 2, min_client_level: { ios: 2, web: 2 },
    update_url: { ios: "itms-beta://" } }
```

`update_url.ios` comes from `QUICKR_IOS_UPDATE_URL`, default `itms-beta://` (it
opens TestFlight). The iOS app falls back to the same default.

### 3.3 Enforcement

A middleware beside the identity middleware decides each `/api/v1` request
**before the route runs**, so a refused request has no effect at all:

| Request                                                   | Client level                                                 |
| --------------------------------------------------------- | ------------------------------------------------------------ |
| Has `X-QuickR-Client`                                     | Its `level`. A malformed header is level 0.                  |
| No `X-QuickR-Client`, but `X-QuickR-Channel: ios` or `ui` | **0**: an iOS build or PWA bundle from before this mechanism |
| Neither header (curl, the notebook, tests, scripts)       | Not checked                                                  |

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
client that can still read may misread new shapes (the feed is the example in
[timers.md](timers.md)) and advance its cursor past data it dropped. The
exceptions are `/health` and `getClientVersions`.

A client **above** the server's `api_level` (a new build against a server that
hasn't been deployed yet) is not refused. Its requests fail or succeed on their
own merits, and the clients show a non-blocking "The quickR server needs
updating" note when they see `X-QuickR-Api-Level` below their own level.

### 3.4 APNs to outdated devices

`registerApnsDevice` stores the client level from `X-QuickR-Client` (0 when
absent). The reminder sender gives devices below the iOS minimum a
**display-only** reminder: no `quick_log`, no `category`, and the body "Time to
log · update quickR to log from here". Their action handlers would only be
refused, and this way the reminder is still useful. Live Activity pushes
([timers.md](timers.md) §10.3) are never sent to them.

## 4. iOS

### 4.1 The outdated state

The store's `sync_state` gains `client_outdated_min` (null, or the minimum the
server demanded). It is set by any of:

- a 426 `client_outdated` response, in any process;
- a response whose `X-QuickR-Min-Client-Level` for `ios` is above
  `APILevel.current` (checked with the identity headers, sync-protocol.md §1.4).

It is cleared when `APILevel.current ≥ client_outdated_min`, which is true at
the first launch after an update, or when a response's minimum is at or below
the current level again (the server rolled back).

While it is set, in every process:

| Part                                                                     | Behaviour                                                                                                                                                                                                                                                                                                                                                     |
| ------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| App UI                                                                   | A blocking full-screen **"Update required"** view over everything else: "quickR needs an update to keep syncing with your server. Your unsynced changes (_N_) are safe on this iPhone." Buttons: **Open TestFlight** (`update_url.ios`) and **Check again** (`getClientVersions`). Settings ▸ Server stays reachable from it, so the user can switch servers. |
| Coordinator                                                              | Doesn't pull. `client_outdated_min` is checked before any request, like `identity_mismatch` (sync-protocol.md §5.4).                                                                                                                                                                                                                                          |
| Outbox                                                                   | Claims are refused (a new condition in outbox.md §6.2). **Enqueue still works.** A 426 `client_outdated` outcome restores the item's pre-claim state and clears its claim fields, like 409 `epoch_mismatch` (outbox.md §5.2): the server refused it before any effect. Then the flusher releases `flush`.                                                     |
| Widgets, Controls, App Intents, the Action button, Live Activity buttons | Enqueue as usual, so the tap is kept, and don't flush. The result says "Saved on this iPhone. Update quickR to sync." Widgets show a small "Update quickR" line.                                                                                                                                                                                              |
| Notification actions                                                     | The handler enqueues as usual and doesn't flush. It posts "Saved on this iPhone. Update quickR to sync." once per launch.                                                                                                                                                                                                                                     |
| NSE                                                                      | No change: it makes no requests.                                                                                                                                                                                                                                                                                                                              |
| APNs registration                                                        | Paused, like any other request.                                                                                                                                                                                                                                                                                                                               |

**Nothing queued is lost.** Items stay `pending` or `uncertain` and are sent by
the updated build, which reads the same store file. A store migration in a later
build that changes the outbox schema MUST migrate them.

### 4.2 Builds before the mechanism (level 0)

The two listed TestFlight builds, and any older one, don't send
`X-QuickR-Client`, so they are level 0 and get 426 on every request. They don't
know the code:

- **Sync:** each pull fails; the sync pill shows "Sync error". Nothing is
  applied, so the local store keeps the last good state.
- **Outbox:** 426 is "any other 4xx" to them (outbox.md §5.1), so each item they
  send becomes `failed/rejected` with the Problem's `detail` as its message,
  which tells the user to update. The item is **kept**, not dropped, so its data
  survives.
- **Recovery after the update.** The first build with the mechanism migrates the
  store once: every `failed` item whose `last_error_json` has status 426 becomes
  `pending` (or `uncertain` if `maybe_delivered`), with its deadline cleared.
  The server refused those before any effect, so resending is safe.
- **Reminders:** display-only (§3.4).

The user is told on the channel they already watch: the sync sheet's messages
and the reminder body.

### 4.3 The floor

The first TestFlight build with this mechanism is the **floor**. It ships at
level 1. Once it is installed, `min_client_level.ios` is raised to 1 in a small
PR, so level-0 builds are refused from then on. Raising the minimum before the
floor build is on the user's phone would leave them on a build that can't show
the prompt; the plan orders it after (timers-plan.md, CV-FLOOR).

### 4.4 Tolerant decoding, from the floor build on

The floor build also stops failing a feed page on an unknown item or deletion
kind: it skips them (sync-protocol.md §2.2 is amended to say so). This doesn't
replace bumping the level for a kind a build must understand, but it means a
purely optional new kind no longer forces an update.

## 5. PWA

### 5.1 Detecting

`frontend/src/api/clientConfig.ts` adds `X-QuickR-Client: web; level=…; build=…`
to every request, and a response hook reads `X-QuickR-Min-Client-Level`. The app
is **outdated** when the `web` minimum is above `__API_LEVEL__`, or a response
is 426 `client_outdated`.

### 5.2 The update path

The PWA is deployed with the server, so a newer bundle is already on the server
when the minimum rises. The existing `UpdatePrompt`
(`frontend/src/components/pwa/UpdatePrompt.tsx`) checks hourly and on resume,
and shows a dismissable "Update available" card. When outdated:

1. Call `registration.update()` at once.
2. If a worker is waiting, or becomes waiting within 10 s, post `SKIP_WAITING`
   (`sw.ts` already handles it), and reload when `controllerchange` fires.
3. If no new worker appears (the browser cached the old `sw.js`, or there is no
   registration), unregister the service worker and do `location.reload()`. The
   next load fetches the new bundle from the network.
4. Meanwhile a **blocking** "Updating quickR…" overlay replaces the dismissable
   card. If the update can't complete (offline), the overlay says "quickR needs
   an update. Connect to the internet and reload." with a Reload button.
5. Unsaved form changes: the existing `hasUnsavedChanges` confirm runs first,
   and the user can copy their text out. Their **outbox** isn't at risk: it
   lives in IndexedDB.

### 5.3 The outbox and the service worker

- The IndexedDB outbox treats 426 `client_outdated` like a precondition refusal:
  the item is restored, not failed, and the pass stops. The updated bundle sends
  it.
- A notification click handled by an old service worker enqueues as usual. Its
  send is refused and the item is kept for the new bundle.
- The base classification table stays byte-compatible with iOS: both treat 426
  `client_outdated` the same way.

## 6. Tests

| #   | Case                                                                                                                                                                                        | Where     |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- |
| V1  | Every `/api/v1` response (2xx, 4xx, 5xx, `/health`) carries both new headers.                                                                                                               | pytest    |
| V2  | Below the minimum: a POST, a PATCH, a DELETE and a GET each answer 426 `client_outdated`, and **nothing is written** (row counts, change log, `deleted_ids` unchanged).                     | pytest    |
| V3  | Channel `ios` or `ui` without `X-QuickR-Client` is level 0. No headers at all is not checked. `getClientVersions` and `/health` are never refused.                                          | pytest    |
| V4  | The env override raises the minimum and is ignored (with a warning) when it would lower it.                                                                                                 | pytest    |
| V5  | `registerApnsDevice` stores the level; the reminder for a level-0 device has no category and no `quick_log`.                                                                                | pytest    |
| V6  | iOS outbox: a 426 restores the pre-claim state, sets `client_outdated_min`, and refuses later claims; enqueue still works; a launch at a higher level clears the flag and the item is sent. | host      |
| V7  | iOS migration: `failed` items with a 426 `last_error_json` become `pending` or `uncertain`; other failed items are untouched.                                                               | host      |
| V8  | Widget and notification-action writes while outdated: the item is durable, no request is made, and the result text is the update message.                                                   | host (MP) |
| V9  | The "Update required" view appears when a response's minimum is above the build's level, and leaves on **Check again** after the server's minimum drops.                                    | sim (UI)  |
| V10 | PWA: an outdated response triggers `update()`, then `SKIP_WAITING` and a reload; with no new worker it unregisters and reloads; the outbox item survives.                                   | vitest    |
| V11 | CI checks (§7): a fixture repo where `openapi.json` breaks against the tag fails unless `api_level` and both minimums were raised.                                                          | pytest    |
| V12 | The `api-level.json` values match what the PWA bundle defines and what the iOS `Info.plist` contains.                                                                                       | CI        |

The request goldens (`shared/fixtures/requests`) gain the `X-QuickR-Client`
header on every request, and `test_request_goldens.py` checks it.

## 7. The compatibility gate under this policy

compatibility.md stays, with these changes (one PR, CV-COMPAT):

1. **The rule (§1).** The server MUST stay compatible with every listed build
   **whose API level is at least the server's `min_client_level.ios`**. Builds
   below it are refused by the server and are not checked.
2. **`compat/supported-clients.json`.** Each client gains `"api_level"`. The two
   current builds are level 0. `client_fixtures.py` lists only the clients at or
   above the minimum in `shared/api-level.json`, and prints the ones it skips. A
   listed client below the minimum MAY be removed in the same PR that raises it.
3. **`openapi breaking` (§2).**
   - Against each **supported** listed client: unchanged. A break against one of
     them fails, because raising the minimum above that client is the only way
     to break it, and that removes it from the comparison.
   - Against the **newest `v*` tag**, which stands for the deployed PWA and any
     unlisted build: a break at ERR level passes **only if** this PR raises
     `api_level` and sets both minimums to it, compared with the tag's
     `shared/api-level.json`. Otherwise it fails with "a breaking change must
     bump shared/api-level.json". `openapi-break-approvals.txt` stays for breaks
     that are deliberately not breaking for any client (for example a field no
     client reads), but bumping is the normal path.
4. **A new check (`api level`, ubuntu, every PR).**
   `min_client_level ≤ api_level`; neither went down compared with the base
   branch; and the PWA and iOS readers get the same numbers (V12).
5. **Fallbacks (§3).** The `fallbacks` mechanism stays for the rare additive
   change that an old supported build reads differently. Timed topics need none.

**Deploying a bump.** A `v*` tag deploys the server and uploads a TestFlight
build from the same commit (compatibility.md §5). Between the deploy and the
user installing the new build, the app shows "Update required" and keeps its
queued writes. That window is the cost of this policy, and the user accepted it.

## Open questions

None. The user decided the policy; the choices above (API level over build
number, refusing reads too, one shared file) are recommendations made here and
can be revisited in review.
