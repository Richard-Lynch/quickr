# Spec: notifications (APNs, actions, local fallback)

**Status:** M0 draft, revision 2 (after the Codex spec review), 2026-10-17.
**Implements:** PLAN.md §2 (Reminders, Notification actions), §5 B6–B8, §6, and
§6a rules 8–11. **Companion specs:** [sync-protocol.md](sync-protocol.md) covers
stores, `server_id` and preconditions. [outbox.md](outbox.md) covers how an
action's write is delivered.

## Purpose

This spec defines everything needed to log from a reminder:

- the push payload and headers;
- the immutable category and action identifier scheme;
- how categories are registered and reconciled across processes;
- what the Notification Service Extension (NSE) and the action handler do;
- the badge;
- the APNs token lifecycle;
- Web Push compatibility;
- the rules that keep a future **on-device local-notification fallback**
  compatible without a redesign.

**Normative language.** **MUST**, **MUST NOT**, **SHOULD** and **MAY** follow
RFC 2119. **[server]** marks backend requirements (B6–B8). **[provisional]**
marks a default that is waiting on the user's answer in PLAN §10. PLAN rules 13–16 (the amendments from the M0 specs review, on
`ios/m0-foundations`) take precedence over rules 1–12.

## Glossary

| Term                    | Meaning                                                                                                                                                                                          |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Reminder**            | A `kind: "due"` notification for one topic slot. It is remote (APNs or Web Push) or, later, local.                                                                                               |
| **Slot**                | `(server_id, topic_id, due_since)`, with `due_since` in canonical form (§11.1). It identifies a reminder whatever its transport.                                                                 |
| **Descriptor**          | `quick_log` in the payload: what can be logged from this notification (§2.3).                                                                                                                    |
| **Action descriptor**   | The ordered list of actions rendered from a descriptor: identifier, title and kind (§4).                                                                                                         |
| **Category**            | A `UNNotificationCategory` with id `quickr.t.{topic_id}.{hash}`. It is immutable.                                                                                                                |
| **NSE**                 | `QuickRNotificationService`, the Notification Service Extension. It has about 30 s and 24 MB. It **only prepares the notification** and never flushes.                                           |
| **Handler**             | `userNotificationCenter(_:didReceive:withCompletionHandler:)` in the **app process**. iOS launches the app in the background to run it.                                                          |
| **Registry**            | The app-global `registry.sqlite` ([sync-protocol.md §8.1](sync-protocol.md#81-files)).                                                                                                           |
| **Active store**        | The store of the server the user selected, at its current generation.                                                                                                                            |
| **Before first unlock** | The period after a reboot and before the first passcode entry. Store and registry files (protection `completeUntilFirstUserAuthentication`) and `AfterFirstUnlock` Keychain items can't be read. |

## 1. Processes and responsibilities

| Process | Notification duties                                                                                                                                                                                                                   |
| ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| App     | Permission. The APNs token lifecycle (§9). Category registration after every sync, plus reconciliation on activation (§5). `willPresent` in the foreground. The handler (§7). The badge (§8). Later, local fallback scheduling (§11). |
| NSE     | Reconciling categories and upserting the one for the incoming push. Setting `categoryIdentifier`. Setting the badge from the active store. Cancelling local fallbacks. **No network calls and no outbox access.**                     |
| Widgets | None, apart from reading due state                                                                                                                                                                                                    |
| Server  | Payload and headers (§2, §3), and scheduler semantics (§3.1)                                                                                                                                                                          |

## 2. APNs payload contract **[server]**

### 2.1 Shape

```json
{
  "aps": {
    "alert": { "title": "Water", "body": "Time to log" },
    "sound": "default",
    "thread-id": "topic-6f1c…",
    "category": "quickr.t.6f1c….a1b2c3d4e5f60718",
    "mutable-content": 1,
    "relevance-score": 0.8
  },
  "quickr": {
    "v": 1,
    "kind": "due",
    "server_id": "0b9e…",
    "topic_id": "6f1c…",
    "topic_slug": "water",
    "version": 3,
    "due_since": "2026-10-17T08:00:00Z",
    "url": "/t/water/record",
    "quick_log": { "type": "enum", "key": "glasses", "label": "Glasses", "options": [ … ], "total_options": 5 }
  }
}
```

| Field                           | Rule                                                                                                                                                 |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `aps.alert.title`               | The topic name, truncated to 120 characters (Unicode scalars, with "…" counted).                                                                     |
| `aps.alert.body`                | `due_message()`, unchanged.                                                                                                                          |
| `aps.sound`                     | `"default"`                                                                                                                                          |
| `aps.thread-id`                 | `topic-{topic_id}`                                                                                                                                   |
| `aps.category`                  | The §4 category id, computed by the server with the shared algorithm. Omitted when `quick_log` is null. The NSE may override it (§6).                |
| `aps.mutable-content`           | Always `1`.                                                                                                                                          |
| `aps.relevance-score`           | `0.8`                                                                                                                                                |
| `aps.badge`                     | **MUST NOT be present.** The device owns the badge (§8).                                                                                             |
| `aps.content-available`         | Not set on reminders. The optional data-change push is `content-available: 1` with no alert and `quickr.kind = "sync"`.                              |
| `quickr.v`                      | `1`. Clients ignore unknown keys. When `v > 1`, the notification is display-only, with no category.                                                  |
| `quickr.kind`                   | `"due"`, `"test"` or `"sync"`                                                                                                                        |
| `quickr.server_id`              | **Required** (§6a rule 8).                                                                                                                           |
| `quickr.topic_id`, `topic_slug` | The topic. Handlers key on `topic_id`; the slug is for display and fallback links only.                                                              |
| `quickr.version`                | The topic's `current_version` when the push was built. Actions log against this version.                                                             |
| `quickr.due_since`              | The slot, in **canonical form: UTC truncated to whole seconds**, for example `2026-10-17T08:00:00Z` (§11.1).                                         |
| `quickr.url`                    | `/t/{slug}/record`                                                                                                                                   |
| `quickr.quick_log`              | A descriptor (§2.3), or `null` when the topic isn't quick-loggable. This uses the Python port of `quickLogFor`, verified by `quicklog-vectors.json`. |

**Test push** (`kind: "test"`): it has no `category`, no `quick_log` and no
`thread-id`. Its collapse id is `test`, its title "quickR" and its body "Test
notification".

### 2.2 Size

The whole JSON body MUST be **≤ 4096 bytes**. The server truncates before
serialising:

- titles to 120 characters;
- option labels, question labels and units to 64 characters, with "…".

A backend test builds the worst case and asserts the limit: a 200-character
name, 4 options with 63-character values and 200-character multi-byte labels, a
64-character key and a 32-character unit.

### 2.3 `quick_log` descriptor shapes

**Enum** (a single-select enum with 1–6 active options):

```json
{
  "type": "enum",
  "key": "mood",
  "label": "Mood",
  "options": [
    { "value": "good", "label": "Good" },
    { "value": "ok", "label": "OK" }
  ],
  "total_options": 5
}
```

- `options` holds **at most 4**, in display order.
- With ≤ 4 active options, all of them are listed, in the question's option
  order.
- With 5–6 active options, the **4 most-used** are listed, counted per key over
  the topic's entries. Ties go to option order. They are listed most-used first.
  **[provisional: Q4]**
- `total_options` is the number of active options.

**Number** (an int or double question):

```json
{
  "type": "double",
  "key": "hours",
  "label": "Sleep",
  "unit": "h",
  "min": 0,
  "max": 24,
  "decimals": 1,
  "last_value": 7.5
}
```

`last_value` is the latest entry's answer for `key`, by `captured_at`. It is
`null` when there is none, or when that value no longer validates against the
current question.

## 3. APNs request headers **[server]**

| Header             | Value                                                            |
| ------------------ | ---------------------------------------------------------------- |
| `apns-topic`       | `com.bahumia.quickr`                                             |
| `apns-push-type`   | `alert` for due and test pushes; `background` for `kind: "sync"` |
| `apns-priority`    | `10` for alerts; `5` for background                              |
| `apns-expiration`  | `now + 12 h` (the same TTL as Web Push); `0` for background      |
| `apns-collapse-id` | `due-{topic_id}` (≤ 64 bytes); `test`; absent for sync           |
| `authorization`    | `bearer <ES256 JWT>`, cached for 50 min                          |

`thread-id` goes in the payload. The client **does not rely** on the collapse id
becoming `UNNotificationRequest.identifier`. Every match uses `userInfo.quickr`.

### 3.1 Delivery semantics (§6a rule 10)

Delivery is **at least once per topic slot overall** (send, then mark), and
**best-effort per device**. There is no per-device retry ledger. Duplicates
collapse by collapse id and by the userInfo-based removal (§6, §7). The app's
due list and the badge are the safety net.

## 4. Categories and actions

### 4.1 Actions per descriptor

| Descriptor                            | Actions, in order                                                             |
| ------------------------------------- | ----------------------------------------------------------------------------- |
| `enum` with _n_ options (1 ≤ _n_ ≤ 4) | One action per option. The title is the label.                                |
| `int`/`double`, `last_value ≠ null`   | 1. "✓ {fmt(last)}", which logs `last_value`. 2. "Other value…", a text input. |
| `int`/`double`, `last_value = null`   | 1. "Other value…", a text input.                                              |
| `null`                                | No category. Tapping opens `url`.                                             |

All actions have these properties:

- **No `.foreground`.** Logging runs in the background.
- **No `.destructive`.**
- **No `.authenticationRequired`.** **[provisional: Q2]** If the user opts into
  authentication, the app sets `.authenticationRequired` on every log action at
  registration. That flag is not part of the hash (§4.3). Changing it
  re-registers the same ids, which is safe because their meaning is unchanged.

The text input action uses:

- `textInputButtonTitle`: "Log";
- `textInputPlaceholder`: "Value in {unit}", or "Value".

The **default action** (tapping the body) opens `url`. There is no separate
"Open" action.

**Two or four visible actions** (§6a rule 9). The first two actions are always
the most useful ones:

- for enums: the two most-used options (with 5–6 options), or the first two
  (with fewer);
- for numbers: "✓ last" and "Other value…".

Everything else is one tap away via the body. Checkpoint D counts how many
actions iOS actually shows.

### 4.2 Action identifier scheme (§6a rule 8)

```
q1|{server_id}|{topic_id}|{version}|{key}|{k}|{value}
```

| Part                    | Rule                                                                      |
| ----------------------- | ------------------------------------------------------------------------- |
| `q1`                    | The scheme version                                                        |
| `server_id`, `topic_id` | Lowercase canonical UUIDs                                                 |
| `version`               | A decimal integer, `quickr.version`                                       |
| `key`                   | The question key (`^[a-z][a-z0-9_]{0,62}$`)                               |
| `k`                     | `o` for an enum option, `n` for a fixed number, `i` for number text input |
| `value`                 | `o`: the option value. `n`: `fmt(last_value)` (§4.4). `i`: empty.         |

### 4.3 Category id and hash (§6a rule 9)

```
category_id = "quickr.t." + topic_id + "." + hex(sha256(H))[0:16]
H = "quickr-cat-v1"
    + for each action in order:
        "\u001E" + kind + "\u001F" + identifier + "\u001F" + title
        + (kind == "input" ? "\u001F" + textInputButtonTitle + "\u001F" + textInputPlaceholder : "")
```

- `kind` is `log` or `input`. Strings are NFC-normalised and UTF-8 encoded. Hex
  is lowercase.
- The hash covers the **complete ordered action descriptor**. A change of
  version, label, last value or order produces a new id, so **a category is
  never changed in place**. The one exception is the authentication flag (§4.1).
- Python (B7) and Swift MUST produce identical ids. The **category-id vectors**
  are added to `shared/fixtures/quicklog-vectors.json` **in M3, together with
  B7**. They cover:
  - enums with 1, 4 and 6 options;
  - int and double, with and without `last_value`;
  - a null unit and null decimals;
  - non-ASCII labels;
  - truncation.

  Until then the algorithm here is the contract. The M0 vectors don't include
  category ids.

### 4.4 Title and number formatting (normative, part of the hash)

- An enum title is the payload label, exactly as given.
- The number action title is
  `"✓ " + fmt(last_value) + (unit ? " " + unit : "")`.
- `fmt(x)`:
  - for `int`: base 10, with no grouping;
  - for `double` with `decimals = d`: fixed-point with `d` places, rounding half
    away from zero;
  - for `double` with `decimals = null`: the shortest round-trip decimal, with
    no exponent and no trailing zeros or dot.
- The decimal separator is always `.`. The `n` identifier value uses the same
  `fmt`.

## 5. Category registration

Rule 9 pruning is deferred (§5.1). This matches PLAN rule 16, in the amendments from the M0 specs review.

### 5.1 Table (registry, app-global, append-only)

```sql
CREATE TABLE notification_category (
  id            TEXT PRIMARY KEY,   -- quickr.t.{topic_id}.{hash}
  server_id     TEXT NOT NULL,
  topic_id      TEXT NOT NULL,
  actions_json  TEXT NOT NULL,      -- the rendered action descriptor
  created_at    REAL NOT NULL
);
```

- **The table is append-only, and v1 never prunes it.** Rows are only ever
  inserted. PLAN rule 9's "prune after 7 days" is deferred until growth has been
  measured. Growth is one row per distinct action descriptor: per topic, per version,
  per option ordering and, for number topics, per distinct last value. Number
  topics with continuously varying values can grow without bound, so **the growth
  rate is to be measured** (checkpoint D, D1, and again after M3 and M4).
- The table lives in the registry because `setNotificationCategories` replaces
  the **whole app's** set, for all servers.

### 5.2 Registration procedure

```
register(newRows):
  TX IMMEDIATE on registry:                         // registry write lock = the cross-process mutex
    INSERT OR IGNORE newRows
    rows = SELECT * FROM notification_category      // the full union
    center.setNotificationCategories(build(rows))   // synchronous call; no await inside the TX
  COMMIT
```

- **Always the union.** Every call registers every row ever inserted, so no
  process can register a set that is missing another process's category.
- **No awaits inside transactions.** `getDeliveredNotifications`,
  `getNotificationCategories` and `getNotificationSettings` are asynchronous.
  They are called **outside** any SQLite transaction, and their results are
  snapshotted before the transaction starts (sync-protocol.md §5.2 rule 3).
- `setNotificationCategories` is called while the registry write transaction is
  held, so two processes' calls don't interleave. Apple doesn't document a
  barrier proving the system has applied one replacement before the next
  arrives. Reconciliation (§5.3) covers that gap, and checkpoint D tests it.

**Callers:**

- **The app**, at launch, after every sync that changed topics, versions or
  entries, after a server switch, and after a reset. It inserts the current
  descriptor of every quick-loggable active topic in the active store, computed
  locally with the server's rules.
- **The NSE**, for the incoming push (§6).

Registering before notification permission has been granted is allowed.

### 5.3 Reconciliation

These run **on every app activation** and **at the start of every NSE run**:

```
reconcile():
  registered = await center.notificationCategories()   // outside any transaction
  ids = SELECT id FROM notification_category            // short read transaction
  if ids ⊄ registered.ids: register([])                 // re-register the full union
```

Reconciliation repairs a replacement that lost a race, a crash between the
insert and the call, and any loss on reboot.

### 5.4 Device test (checkpoint D)

Run concurrent replacement on a device, 100 times: the NSE registers {A, B}
while the app registers {A, C}, overlapping in time. Then check
`notificationCategories()` reports A, B and C, either immediately or after one
reconcile. If not, report it as part of the checkpoint D go/no-go.

## 6. NSE flow

The NSE has a target budget of **3 s**. Its hard limit is about 30 s, and
`serviceExtensionTimeWillExpire` delivers the best content prepared so far. Its
memory limit is 24 MB. The NSE never makes network calls and never writes the
outbox.

```
didReceive(request):
  best = request.content.mutableCopy()
  q = best.userInfo["quickr"]
  if q == nil or q.v != 1 or q.kind != "due": return deliver(best)              // test push, unknown → untouched
  cancelLocalFallback(q.server_id, q.topic_id, q.due_since)                     // §11.2 L1 (no store needed)
  if !protectedDataAvailable (the registry can't be opened because of file protection):
      return deliver(best)                                                      // BEFORE FIRST UNLOCK: untouched
  await reconcile()                                                             // §5.3, outside transactions
  if registry has no server q.server_id:
      best.categoryIdentifier = ""                                              // actions could only be dropped
      return deliver(best)
  if q.quick_log != nil:
      actions = render(q); cid = categoryId(q.topic_id, actions)                // §4
      if cid != best.categoryIdentifier: log("category drift", server: …, client: cid)
      register([row(cid, actions)])                                             // §5.2
      best.categoryIdentifier = cid
  if q.server_id == registry.active.server_id and the active store opens:
      if the view shows slot (topic_id, due_since) already satisfied by a local entry:
          best.body = "Already logged on this iPhone · syncing"; best.categoryIdentifier = ""
      best.badge = dueCount(activeStore.view)                                   // §8: actual derived state only
  // else: badge untouched
  remove delivered notifications matching (server_id, topic_id) with an older due_since   // snapshot outside TX
  deliver(best)
```

- **Before first unlock**, the content is left untouched (PLAN §6). If the
  server's category is still registered from before, iOS may show its actions.
  The handler then fails gracefully (§7.1, step 3). Checkpoint D checks this
  (open question 3).
- Registering a category from the NSE is common practice but isn't documented as
  taking effect before display. The app's registration after sync is the primary
  path, and the NSE upsert plus reconciliation is the backstop.

## 7. Action handler

### 7.1 Flow (app process, background launch)

```
didReceive(response, completion):
  beginBackgroundTask
  q = response.notification.request.content.userInfo["quickr"]
  default action → route(q.url); completion(); return
  dismiss action → completion(); return
  a = parse(response.actionIdentifier)              // §4.2; failure → fail("Couldn't log")
  1. VALIDATE against userInfo:
       a.server_id == q.server_id, a.topic_id == q.topic_id, a.version == q.version, a.key == q.quick_log.key
       k=o: a.value ∈ q.quick_log.options[].value
       k=n: q.quick_log.last_value != nil and fmt(last_value) == a.value
       k=i: parse(userText) per §7.3, else → tapToFix
     any mismatch → fail("Couldn't log — open quickR to log")
  2. STORE: registry.lookup(a.server_id)
       none → fail("This reminder came from a server you've removed from quickR")      // §6a rule 8
  3. OPEN that server's current-generation store (it may be inactive)
       protected data unavailable → fail("Unlock your iPhone, then tap to log", url = q.url)
  4. PRECONDITIONS from that store's view:
       topic tombstoned → fail("{topic} was deleted"); topic archived → fail("{topic} is archived")
  5. ONE IMMEDIATE TRANSACTION (check retired; if retired, reopen and retry once):
       enqueue entry.create { id: new uuid, topic: {id, slug, name}, body: {
           answers: {key: value}, version: q.version, captured_at: device now (RFC 3339 with offset),
           source: "ios.notification", notes: "", meta: {} } }  (outbox.md §8)
       recompute derived fields
  6. post Darwin db-changed
  7. REMOVE delivered notifications whose userInfo.quickr has (a.server_id, a.topic_id)
     cancel pending local requests "due-{topic_id}-{S}" for slots S now satisfied      // §11.2 L4
  8. BADGE: if the store is the active store: setBadgeCount(dueCount(view)); otherwise leave it   // §8
  9. Reload widget timelines only if the due state or last value changed
 10. FLUSH (outbox.md §10): only if the store is the active store; forced; 5 s budget
 11. completion(); endBackgroundTask
```

- `fail(msg)` posts a local notification with identifier
  `quickr.err.{topic_id}`, `thread-id: topic-{topic_id}` and no category.
  Tapping it opens `q.url`. Nothing is written.
- Durability never depends on the network: step 5 commits before any request.
- `version` comes from the payload, so it is still valid after a later publish.
- **[provisional: Q2]** Logging from the Lock Screen needs no authentication.

### 7.2 Foreground (`willPresent`)

- A reminder whose slot is already satisfied in the active store's view is
  suppressed (`[]`) and removed.
- A local fallback reminder for a slot that already has a delivered remote
  reminder is suppressed too (§11.2 L2).
- Anything else is shown with `[.banner, .list, .sound]`.

### 7.3 Number text input

1. Trim the text, and strip a trailing unit (case-insensitive).
2. Accept `,` or `.` as the decimal separator; only one is allowed, and grouping
   separators are rejected.
3. The parsed value must be finite.
4. Validate it as `parseQuickNumber` does:
   - `int` requires an integer;
   - `min ≤ x ≤ max`;
   - at most `decimals` fraction digits.
5. If the value is invalid, write nothing. Post a local notification:
   - title "Couldn't log {topic}";
   - body "“{raw}” isn't a valid value — tap to fix";
   - identifier `quickr.fix.{topic_id}`;
   - userInfo
     `{quickr: {v: 1, kind: "fix", server_id, topic_id, url, prefill: {key: raw}}}`.

   Tapping it opens the record screen with the raw text and the validation
   message.

## 8. Badge

- The badge is set **only on the device**. The payload never carries `badge`.
- **Value:** the number of topics in the **active store's** view with
  `status = active` and `due.is_due`, computed with `device_now + skew`. This is
  the PWA's `dueCount`. It is **never forced**. An incoming reminder's topic
  counts only if the active store's derived state says it is due. Inactive
  stores never contribute.
- **Writers:**
  - the NSE, through `content.badge`, only when the payload's server is the
    active one and the active store opens;
  - the app, through `setBadgeCount` after every recompute of derived fields;
  - the handler, only when it wrote into the active store.
- **If the active store can't be opened** (before first unlock, or during a
  reset), the badge is **not updated**.

## 9. APNs token lifecycle

### 9.1 Environment (explicit; never guessed)

1. Look for
   `Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")`.
   - **File absent:** this is an App Store or TestFlight distribution build,
     which Apple strips of the profile. The environment is `production`. This is
     the only inferred case, and it is documented behaviour.
2. File present: extract the XML plist, meaning the bytes from `<?xml` through
   the first `</plist>` inside the CMS envelope. Parse it with
   `PropertyListSerialization` and read `Entitlements["aps-environment"]`.
   - `development` → `sandbox`.
   - `production` → `production`.
   - **Any failure is an explicit error:** the markers aren't found, the plist
     doesn't parse, the `Entitlements` dictionary is missing, the key is
     missing, or the value is anything else. The client then:
     - **does not register**;
     - logs the error;
     - shows "Push setup error: the provisioning profile has no valid APNs
       environment" in Settings ▸ Notifications.
3. Simulator → `sandbox`. This is decided at compile time with
   `targetEnvironment(simulator)`.

### 9.2 Registration rules

All registration runs in the **app process only**. Every call is a mutation and
**carries `X-QuickR-Expect-Server-Id` and `X-QuickR-Expect-Epoch`**
([sync-protocol.md §1.4](sync-protocol.md#14-identity-and-epoch-what-the-client-sends-and-checks)).
**[server]** Endpoint names follow research 03 §1. The final paths come from B6.

| Event                                                                                                                                           | Action                                                                                                                                                                                                       |
| ----------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Permission granted                                                                                                                              | `registerForRemoteNotifications()`                                                                                                                                                                           |
| Cold launch, or `scenePhase → active` more than 24 h after the last registration, while authorized (`authorized`, `provisional` or `ephemeral`) | `registerForRemoteNotifications()`. Then `didRegister(token)` sends `POST /push/apns/devices {token (lowercase hex), environment, app_version, device_name}`. This is an upsert.                             |
| `didRegister` returns a token that differs from `registry.apns_token`                                                                           | Register the new token, then `POST /push/apns/devices/delete {old}`. Store the new token.                                                                                                                    |
| `authorizationStatus` becomes `denied`, checked on every activation                                                                             | `POST /push/apns/devices/delete {token}` and `apns_registered = false`. Register again when permission returns.                                                                                              |
| Server switch                                                                                                                                   | Delete the token on the old server, using **the old store's** server id and epoch. Then register on the new server ([sync-protocol.md §8.4](sync-protocol.md#84-switching-servers)).                         |
| 409 `epoch_mismatch` for the **active** store                                                                                                   | The coordinator rebuilds (sync-protocol.md §7), then the call is retried.                                                                                                                                    |
| 409 `epoch_mismatch` while unregistering from an **inactive or old** server                                                                     | The device registration belongs to the server, not to an epoch. Retry **once** with `X-QuickR-Expect-Epoch` set to the epoch from the response's `X-QuickR-Epoch` header. `Expect-Server-Id` stays the same. |
| 409 `server_mismatch`                                                                                                                           | Never retried against that URL. For the active store: identity mismatch (sync-protocol.md §8.3). For a pending unregistration: drop it, because the old server is gone from that URL.                        |
| A failed call (network error or 5xx)                                                                                                            | Retry at the next activation with the outbox backoff. Pending unregistrations live in `registry.pending_unregister` and are retried for up to 30 days.                                                       |
| APNs 410, or `BadDeviceToken` on the server side                                                                                                | The server deletes the device. The next launch registers again.                                                                                                                                              |
| "Test this device"                                                                                                                              | `POST /push/apns/devices/test {token}`. Online only.                                                                                                                                                         |
| Environment error (§9.1)                                                                                                                        | Nothing is registered. Settings shows the error.                                                                                                                                                             |

## 10. Web Push compatibility **[server]** (B7, B8)

- `PushPayload` keeps `title`, `body`, `url`, `tag` and `topic_slug`. It
  **gains** `v`, `kind`, `server_id`, `topic_id`, `version`, `due_since`
  (canonical form) and `quick_log`, with the §2 shapes.
- `tag` stays `due-{topic_id}`.
- **Chromium actions (B8):**
  - An enum shows the first `Notification.maxActions` options, as
    `{action: "log|o|" + value, title: label}`.
  - A number with `last_value` shows
    `{action: "log|n|" + fmt(last), title: "✓ …"}`.
  - There is no text input.
  - `notificationclick` validates the action against
    `notification.data.quick_log`, then enqueues `entry.create` into the
    IndexedDB outbox and flushes.
  - The PWA may send the Expect headers. They are optional for it.
- Safari and iOS web push have no actions, so those platforms are unchanged.

## 11. Local-fallback compatibility (§6a rule 11)

The fallback is **not built in v1**. These rules are binding now.

### 11.1 Identifiers and canonical slot

- **Canonical `due_since`:** RFC 3339 **UTC**, **truncated to whole seconds**,
  with a `Z` suffix. The server MUST emit `quickr.due_since` in this form. Both
  sides truncate, because interval schedules can produce sub-second instants.
- **Local request identifier:** `due-{topic_id}-{due_since}`.
- **Local content:** the same as the push. The category is computed locally. The
  payload adds `quickr.origin = "local"`.
- **Matching** always uses the slot key from `userInfo.quickr`. A request
  identifier is used only to cancel our own **pending local** requests.

### 11.2 Cancellation and de-duplication rules

| #   | Situation                                                                           | Rule                                                                                                                                                                                    |
| --- | ----------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| L1  | A push for slot S arrives (the NSE runs)                                            | `removePendingNotificationRequests(["due-{topic}-{S}"])`, and remove delivered local reminders with slot key S. No store is needed, so this also runs before first unlock.              |
| L2  | A local reminder for S fires after a remote one for S was delivered                 | In the foreground, `willPresent` suppresses it and removes it. In the background, the next NSE run or app activation de-duplicates and keeps the remote one.                            |
| L3  | The local reminder fired first, then the push arrives                               | L1 removes the delivered local reminder.                                                                                                                                                |
| L4  | An entry is logged in any process                                                   | After commit: remove delivered reminders for `(server_id, topic_id)`, and cancel pending `due-{topic}-{S}` for every slot S that is now satisfied. The scheduler re-arms the next slot. |
| L5  | The slot is satisfied elsewhere (a pull brings an entry)                            | After each page, apply L4 to every topic whose `due.is_due` became false.                                                                                                               |
| L6  | A push arrives for a slot that is satisfied locally (an offline log not yet synced) | The NSE changes the body to "Already logged on this iPhone · syncing" and clears the category. v1 doesn't use the filtering entitlement.                                                |
| L7  | A topic is archived, tombstoned or unscheduled, or its schedule is edited           | Cancel all pending `due-{topic}-*`. On tombstone or archive, also remove that topic's delivered reminders.                                                                              |
| L8  | Server switch or local reset                                                        | Cancel pending local reminders and remove delivered reminders whose `server_id` is not the active one.                                                                                  |
| L9  | Budget                                                                              | At most one pending request per topic, for the next slot. This stays well under iOS's limit of 64.                                                                                      |

The fallback's due computation is the Swift port of `schedule.py`, which uses
the same vectors and `device_now + skew`.

## 12. Tests

| #   | Test                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | Proves       |
| --- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------ |
| N1  | (M3, with B7) Python and Swift produce byte-identical action descriptors and category ids from the vectors.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | §4.3, §4.4   |
| N2  | The worst-case payload is ≤ 4096 bytes, has no `aps.badge`, and has `due_since` in canonical form.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | §2           |
| N3  | Action ids round-trip, and a tampered value is rejected.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | §4.2, §7.1   |
| N4  | Two processes (MP) insert and register at the same time, 100 times. The table holds the union, and the last `setNotificationCategories` call in each process received the full union.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | §5.2         |
| N5  | Reconciliation with a fake center that is missing a category re-registers the union. When nothing is missing, it makes no call.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | §5.3         |
| N6  | No transaction is open across `getDeliveredNotifications` or `notificationCategories()`. Asserted with a GRDB transaction observer in tests.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | §5.2         |
| N7  | The handler drops an action with an unknown `server_id` and posts the explanatory notification.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | §7.1, rule 8 |
| N8  | The handler writes into an inactive store, and **the badge does not change**.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         | §7.1, §8     |
| N9  | The NSE with a push from an inactive server leaves the badge unset. A push for an active-store topic that is satisfied locally is **not** counted.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | §6, §8       |
| N10 | Text input "7,5 h" logs 7.5. Input "abc" gets the tap-to-fix notification and nothing is written.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     | §7.3         |
| N11 | The environment parser: file absent → production; `development` → sandbox; `production` → production. **Garbage bytes, a missing `</plist>`, a missing `Entitlements`, a missing key, or the value `"staging"` each produce an explicit error and no registration.**                                                                                                                                                                                                                                                                                                                                                                                                                                  | §9.1         |
| N12 | Token rotation registers the new token and deletes the old. Denying permission deletes the token. Every call carries both Expect headers.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | §9.2         |
| N13 | Unregistering from an old server whose epoch rotated gets `epoch_mismatch`, retries once with the header's epoch, and succeeds. `server_mismatch` drops the pending unregistration.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | §9.2         |
| N14 | The handler logs against `q.version` after a newer version has been published.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | §7.1         |
| N15 | L1–L4 with a fake center: both arrival orders leave one reminder, and logging clears pending and delivered reminders.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | §11.2        |
| D1  | **Checkpoint D (device):** <br>• concurrent replacement as in §5.4; <br>• the visible action count (2 or 4); <br>• Lock Screen logging before first unlock; <br>• whether a category registered by the NSE takes effect before display; <br>• **category growth**: rows added per day, measured with real use of a number topic and an enum topic; <br>• **registration budget**: the wall time of `setNotificationCategories` plus the time until `notificationCategories()` reflects it, at 100, 1,000 and 5,000 categories, run in the NSE and in the app. If the NSE can't register within its 3 s target at the projected one-year row count, pruning (open question 5) becomes required for M3. | §5, §6       |

## Open questions

1. **Q2 [provisional]: authentication for Lock Screen logging.** The default is
   no authentication.
2. **Q4 [provisional]: topics with 5–6 options.** The default is the 4
   most-used, most-used first.
3. **Before first unlock.** Should the content stay untouched, which is the PLAN
   default, or should the NSE clear `categoryIdentifier` so that no action can
   fail? Decide at checkpoint D, once we know whether categories survive a
   reboot.
4. **A confirmation after a notification log.** Should the handler post a quiet
   "Logged ✓ · Undo"? The default is no: errors only.
5. **Category growth.** v1 never prunes (§5.1). Growth and the registration
   budget are measured in D1, and again after M3 and M4. Add pruning only if
   needed. That would restore rule 9's 7-day
   retention, computed from a snapshot of delivered notifications taken outside
   the transaction.

## Traceability

| Source                                                                                | Where it is addressed                                     |
| ------------------------------------------------------------------------------------- | --------------------------------------------------------- |
| PLAN §2 Reminders and Notification actions                                            | §2–§5, §7, §8                                             |
| §6a rule 8 (`server_id` in payloads and action ids)                                   | §2.1, §4.2, §7.1                                          |
| §6a rule 9 (serialised registration, full-descriptor hash, works with only 2 actions) | §4, §5. pruning deferred per PLAN rule 16                 |
| §6a rule 10 (delivery semantics)                                                      | §3.1                                                      |
| §6a rule 11 (local fallback)                                                          | §11                                                       |
| PLAN rule 16 (amends rule 9; amendments from the M0 specs review)                     | §5, §6, §8                                                |
| Codex round 2: category growth claim unsupported                                      | §5.1, D1                                                  |
| Codex spec review M8 (registration not established, awaits inside a transaction)      | §5.2 (union, no awaits), §5.3 reconciliation, §5.4 and D1 |
| Codex spec review M9 (inactive reminders corrupt the badge)                           | §6, §7.1 step 8, §8, N8, N9                               |
| Codex spec review M10 (N11 environment failures)                                      | §9.1, N11                                                 |
| Codex spec review B3 (APNs registration preconditions)                                | §9.2, N12, N13                                            |
| Codex spec review simplification (no NSE flush)                                       | Glossary, §1, §6                                          |
| Codex v1 M5, M7; v2 #4, #5; Fable B2, M7 and minors                                   | §4, §5, §8, §9, §11                                       |
