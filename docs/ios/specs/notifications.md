# Spec: notifications (APNs, actions, local fallback)

**Status:** M0 draft, 2026-10-17. **Implements:** PLAN.md §2 (Reminders,
Notification actions), §5 B6–B8, §6, and §6a rules 8–11. **Companion specs:**
[sync-protocol.md](sync-protocol.md) covers stores and `server_id`, and
[outbox.md](outbox.md) covers how an action's write is delivered.

## Purpose

This spec defines everything needed to log from a reminder:

- the push payload and headers the server sends;
- the immutable category and action identifier scheme;
- how categories are registered safely across processes;
- what the Notification Service Extension (NSE) and the action handler do;
- the badge;
- the APNs token lifecycle;
- Web Push compatibility;
- the rules that keep a future **on-device local-notification fallback**
  compatible without a redesign.

**Normative language.** **MUST**, **MUST NOT**, **SHOULD** and **MAY** are used
as in RFC 2119. **[server]** marks backend requirements (B6, B7 and B8).
**[provisional]** marks a default that is waiting for the user's answer in PLAN
§10.

## Glossary

| Term                    | Meaning                                                                                                                                                                                          |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Reminder**            | A `kind: "due"` notification for one topic slot. It is remote (APNs or Web Push) or, later, local.                                                                                               |
| **Slot**                | `(server_id, topic_id, due_since)`. It identifies a reminder independently of the transport. `due_since` is in canonical form (§11.1).                                                           |
| **Descriptor**          | `quick_log` in the payload: what can be logged from this notification (§2.3).                                                                                                                    |
| **Action descriptor**   | The ordered list of actions rendered from a descriptor: identifier, title and kind (§4.2).                                                                                                       |
| **Category**            | A `UNNotificationCategory` with id `quickr.t.{topic_id}.{hash}`. It is immutable once registered.                                                                                                |
| **NSE**                 | `QuickRNotificationService`, the Notification Service Extension. It runs for pushes with `mutable-content: 1`. Its budget is about 30 s and about 24 MB.                                         |
| **Handler**             | `UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:)` in the **app process**. The system launches the app in the background for non-foreground actions. |
| **Registry**            | The app-global `registry.sqlite` ([sync-protocol.md §8.1](sync-protocol.md#81-files)).                                                                                                           |
| **Before first unlock** | After a reboot, until the first passcode entry. Files with `completeUntilFirstUserAuthentication` protection and `AfterFirstUnlock` Keychain items can't be read.                                |

## 1. Processes and responsibilities

| Process | Notification duties                                                                                                                                                                                            |
| ------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| App     | Permission; the APNs token lifecycle (§9); category registration after every sync and pruning (§5); `willPresent` for the foreground; the handler (§7); the badge (§8); local fallback scheduling, later (§11) |
| NSE     | Category upsert for the incoming push; `categoryIdentifier`; the badge; local-fallback cancellation; an optional 2 s flush (§6)                                                                                |
| Widgets | None, beyond reading the due state                                                                                                                                                                             |
| Server  | Payload and headers (§2, §3); scheduler semantics (§3.1)                                                                                                                                                       |

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

| Field                           | Rule                                                                                                                                                    |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `aps.alert.title`               | The topic name, truncated to 120 characters (Unicode scalars, with "…" counted).                                                                        |
| `aps.alert.body`                | `due_message()` (unchanged: "Time to log" or "Overdue since 08:00").                                                                                    |
| `aps.sound`                     | `"default"`                                                                                                                                             |
| `aps.thread-id`                 | `topic-{topic_id}`                                                                                                                                      |
| `aps.category`                  | The category id from §4, computed by the server with the shared algorithm. It is **omitted** when `quick_log` is null. The NSE may override it (§6).    |
| `aps.mutable-content`           | Always `1`, so the NSE runs.                                                                                                                            |
| `aps.relevance-score`           | `0.8`                                                                                                                                                   |
| `aps.badge`                     | **MUST NOT be present.** The device owns the badge (§8).                                                                                                |
| `aps.content-available`         | Not set on reminders. A separate optional data-change push (PLAN B7) is `content-available: 1` with no alert and `quickr.kind = "sync"`.                |
| `quickr.v`                      | `1`. Clients MUST ignore unknown keys. A client that sees `v > 1` treats the payload as display-only: no category and no actions.                       |
| `quickr.kind`                   | `"due"`, `"test"`, or `"sync"` (silent)                                                                                                                 |
| `quickr.server_id`              | **Required** (§6a rule 8). The server's `server_id`.                                                                                                    |
| `quickr.topic_id`, `topic_slug` | The topic. The slug is for display and deep-link fallback only. Handlers key on `topic_id`.                                                             |
| `quickr.version`                | The topic's `current_version` when the push was built. Actions log against this version, even if a newer one is published later (entries pin versions). |
| `quickr.due_since`              | The slot, in canonical form (§11.1).                                                                                                                    |
| `quickr.url`                    | `/t/{slug}/record`, an in-app path, as in Web Push.                                                                                                     |
| `quickr.quick_log`              | A descriptor (§2.3), or `null` when the topic isn't quick-loggable (this is the Python port of `quickLogFor`, checked against `quicklog-vectors.json`). |

**Test push** (`kind: "test"`): it has no `category`, no `quick_log`, the
collapse id `test` and no `thread-id`. Its title is "quickR" and its body is
"Test notification".

### 2.2 Size

The whole JSON body MUST be **≤ 4096 bytes**. The server truncates strings
before serialising:

- titles to 120 characters;
- option labels, the question label and the unit to 64 characters (with "…");
- the slug is already at most 64.

A backend test builds the worst case and asserts ≤ 4096: a 200-character name, 4
options with 63-character values and 200-character multi-byte labels, a
64-character key, and a 32-character unit.

### 2.3 `quick_log` descriptor shapes

**Enum** (a single-select enum with 1–6 active options; `multiple` is false):

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
  - If there are ≤ 4 active options: all of them, in the question's option
    order.
  - If there are 5 or 6: the **4 most-used**, measured by count over the topic's
    entries for that key. Ties are broken by option order. The 4 are listed
    most-used first. **[provisional: Q4]**
- `total_options` is the number of active options, so a client can say "+1 more
  in the app".

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

- `type` is `"int"` or `"double"`.
- `unit`, `min`, `max` and `decimals` are copied from the question, and are null
  when unset.
- `last_value` is the latest entry's answer for `key` (by `captured_at`), or
  `null`. It is also null when the stored value no longer validates against the
  current question.

## 3. APNs request headers **[server]**

| Header             | Value                                                                     |
| ------------------ | ------------------------------------------------------------------------- |
| `apns-topic`       | `com.bahumia.quickr`                                                      |
| `apns-push-type`   | `alert` for due and test pushes; `background` for `kind: "sync"`          |
| `apns-priority`    | `10` for alerts; `5` for background                                       |
| `apns-expiration`  | `now + 12 h` (the same TTL as Web Push, `push.py`); `0` for background    |
| `apns-collapse-id` | `due-{topic_id}` (≤ 64 bytes). `test` for the test push. Absent for sync. |
| `authorization`    | `bearer <ES256 JWT>`, cached for 50 min (research 03 §1)                  |

`thread-id` is in the payload (`aps.thread-id`), not in a header. The client
**does not rely** on the collapse id becoming
`UNNotificationRequest.identifier`. Every match uses `userInfo.quickr` (§7,
§11).

### 3.1 Delivery semantics (§6a rule 10)

Delivery is **at least once per topic slot overall** (send, then mark), and
**best-effort per device**. There is no per-device retry ledger. On the device:

- duplicates for one slot collapse by collapse id, and by the userInfo-based
  removal in §6 and §7;
- a device that missed a push gets no retry;
- the app's due list and badge are the safety net.

## 4. Categories and actions

### 4.1 Actions per descriptor

| Descriptor                             | Actions, in order                                                                                           |
| -------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `enum` with _n_ options (1 ≤ _n_ ≤ 4)  | One `UNNotificationAction` per option. The title is the option label.                                       |
| `int` or `double`, `last_value ≠ null` | 1. "✓ {formatted last}" (logs `last_value`). 2. "Other value…", which is a `UNTextInputNotificationAction`. |
| `int` or `double`, `last_value = null` | 1. "Other value…" (text input)                                                                              |
| `null`                                 | No category, so no actions. Tapping the notification opens `url`.                                           |

Every action has these properties:

- **No `.foreground`.** Logging runs in the background.
- **No `.destructive`.**
- **No `.authenticationRequired` [provisional: Q2].** The default lets you log
  from the Lock Screen without Face ID, in 2 taps. If the user chooses
  authentication, the app sets `.authenticationRequired` on every log action at
  registration time. That option is **not** part of the hash (§4.3), so changing
  it re-registers the same ids in place. That is safe, because the meaning of
  the actions doesn't change.

The text input action is configured like this:

- `textInputButtonTitle` is "Log";
- `textInputPlaceholder` is "Value in {unit}", or "Value" when there is no unit;
- the keyboard type can't be set, so parsing is lenient (§7.3).

The **default action** (tapping the body) opens `url`, which is the record
screen. No "Open" action is added (PLAN §2).

**Two or four visible actions** (§6a rule 9). iOS shows up to 4 actions when a
notification is expanded, and only the **first 2** in some presentations, such
as a compact banner or a constrained Lock Screen context. The design guarantees
that the first two actions are the most useful ones:

- for enums, the two most-used options (with 5–6 options), or the first two in
  option order;
- for numbers, "✓ last" and "Other value…".

Anything else is one tap away through the body, which opens the record screen.
Checkpoint D measures the actual counts. The protocol doesn't change with the
result.

### 4.2 Action identifier scheme (§6a rule 8)

```
q1|{server_id}|{topic_id}|{version}|{key}|{k}|{value}
```

| Part                    | Rule                                                                                             |
| ----------------------- | ------------------------------------------------------------------------------------------------ |
| `q1`                    | The scheme version                                                                               |
| `server_id`, `topic_id` | Lowercase canonical UUIDs                                                                        |
| `version`               | A decimal integer, from `quickr.version`                                                         |
| `key`                   | The question key (`^[a-z][a-z0-9_]{0,62}$`, so it never contains `\|`)                           |
| `k`                     | `o` for an enum option, `n` for a fixed number, `i` for number text input                        |
| `value`                 | For `o`: the option value (a key pattern). For `n`: the canonical number (§4.4). For `i`: empty. |

Examples:

- `q1|0b9e…|6f1c…|3|mood|o|good`
- `q1|0b9e…|6f1c…|7|hours|n|7.5`
- `q1|0b9e…|6f1c…|7|hours|i|`

The identifiers are unique across all categories, as Apple requires, because
they include the topic and the server.

### 4.3 Category id and hash (§6a rule 9)

```
category_id = "quickr.t." + topic_id + "." + hex(sha256(H))[0:16]
H = "quickr-cat-v1"
    + for each action in order:
        "\u001E" + kind + "\u001F" + identifier + "\u001F" + title
        + (kind == "input" ? "\u001F" + textInputButtonTitle + "\u001F" + textInputPlaceholder : "")
```

- `kind` is `log` or `input`. Strings are NFC-normalised UTF-8. The hex is
  lowercase.
- The hash covers the **complete ordered action descriptor**: identifiers (which
  include the server, topic, version, key and value), titles, kinds and order.
  Any change, such as a new version, a renamed option, a new last value or a
  reordering, gives a new category id. **A category is never changed in place**,
  except for the authentication option in §4.1.
- The server (B7, in Python) and the client (in Swift) MUST produce identical
  ids. `shared/fixtures/quicklog-vectors.json` gains cases of the form
  `{server_id, topic_id, version, descriptor} → {actions, category_id}`
  covering:
  - enum with 1, 4 and 6 options;
  - int and double, with and without `last_value`;
  - a null unit and null decimals;
  - non-ASCII labels;
  - truncation.

### 4.4 Title and number formatting (part of the hash, so it is normative)

- An enum title is the option label exactly as it appears in the payload
  (already truncated by the server).
- "✓ {formatted last}" is `"✓ " + fmt(last_value) + (unit ? " " + unit : "")`.
- `fmt(x)`:
  - for `int`, the integer in base 10 with no grouping;
  - for `double` with `decimals = d`, fixed-point with `d` places, rounded half
    away from zero;
  - for `double` with `decimals = null`, the shortest round-trip decimal without
    an exponent, with no trailing zeros, and no trailing `.` (for example `7.5`,
    `12`, `0.001`).
- The `n` identifier value uses the same `fmt`, so the logged value is exactly
  the value shown.
- Formatting is locale-independent: the decimal separator is always `.`.

## 5. Category registration

### 5.1 Table (in the registry, app-global)

```sql
CREATE TABLE notification_category (
  id               TEXT PRIMARY KEY,     -- quickr.t.{topic_id}.{hash}
  server_id        TEXT NOT NULL,
  topic_id         TEXT NOT NULL,
  actions_json     TEXT NOT NULL,        -- the rendered action descriptor (ids, titles, kinds, input texts)
  created_at       REAL NOT NULL,
  last_used_at     REAL NOT NULL,        -- bumped when a push or sync references it
  prunable         INTEGER NOT NULL DEFAULT 0   -- set by topic tombstones / server removal
);
```

The table is **append-only**: rows are inserted, never updated (except
`last_used_at` and `prunable`), and only deleted by pruning. It lives in the
registry, because `setNotificationCategories` replaces the **whole app's**
category set across all servers.

### 5.2 Serialised registration procedure

Every process that registers MUST do this, and MUST NOT call
`setNotificationCategories` in any other way:

```
register(newRows):
  TX IMMEDIATE on registry:                       // the cross-process mutex (§6a rule 9)
    INSERT OR IGNORE newRows; bump last_used_at for referenced ids
    if caller is the app: prune()                 // §5.3
    rows = SELECT * FROM notification_category
    center.setNotificationCategories(build(rows)) // called INSIDE the transaction
  COMMIT
```

Because the call to `setNotificationCategories` happens while the `IMMEDIATE`
transaction is held, two processes can't interleave a read of the whole set with
a replace. This closes the {A} / {A,B} / {A} race. A process that crashes
mid-procedure leaves the table as the source of truth, and the next registration
repairs the set.

The callers are:

- **the app**, after every sync that changed topics, versions or entries (the
  last values), at launch, after a server switch, and after a reset. It
  registers the current descriptor of every quick-loggable active topic in the
  active store, as computed **locally** with the same rules as the server (top-4
  counts come from the local view);
- **the NSE**, for the incoming push (§6).

Registering before notification permission is granted is allowed and harmless.

### 5.3 Retention and pruning (app only)

A row is deleted only if **all** of these hold:

1. `created_at < now − 7 days`, or `prunable = 1`;
2. its id is not the `categoryIdentifier` of any **delivered** notification
   (`getDeliveredNotifications`, read inside the transaction);
3. it is not the current descriptor of any topic in any store that the app just
   registered.

Rule 2 applies **even when `prunable = 1`**. A delivered notification always
keeps its actions until it is dismissed or removed. Its handler then drops the
action safely (§7.1).

## 6. NSE flow

Budget: finish within **5 s** of the target. The system allows about 30 s, and
`serviceExtensionTimeWillExpire` delivers the best content prepared so far.
Memory is capped at 24 MB, so the NSE MUST NOT load images or open more than one
store.

```
didReceive(request):
  best = request.content.mutableCopy()
  q = best.userInfo["quickr"]
  if q == nil or q.v != 1 or q.kind != "due": return deliver(best)              // test push, unknown → untouched
  cancelLocalFallback(q.server_id, q.topic_id, q.due_since)                     // §11.2 L1 (no store needed)
  if !protectedDataAvailable (open of registry fails with a file-protection error):
      return deliver(best)                                                      // BEFORE FIRST UNLOCK: untouched
  if registry has no server q.server_id:
      best.categoryIdentifier = ""                                              // actions could only be dropped
      return deliver(best)
  if q.quick_log != nil:
      actions = render(q)                                                       // §4.1–4.4
      cid = categoryId(q.topic_id, actions)
      if cid != best.categoryIdentifier: log("category drift", server: …, client: cid)
      register([row(cid, actions)])                                             // §5.2
      best.categoryIdentifier = cid
  store = open(q.server_id)                                                     // read-only use, plus an optional flush
  if store.view says slot (topic_id, due_since) is already satisfied by a local entry:
      best.body = "Already logged on this iPhone · syncing"; best.categoryIdentifier = ""
  best.badge = dueCount(store.view ∪ {q.topic_id is due})                       // §8
  removeDelivered(where userInfo.quickr matches (server_id, topic_id) and due_since < q.due_since)
  optionally flush(budget: 2 s, in parallel; never delays deliver beyond 2 s)  // outbox.md §10
  deliver(best)
```

Notes:

- **Before first unlock**, the content is delivered untouched (PLAN §6). If the
  server's `aps.category` is already registered from earlier, iOS may still show
  its actions. Tapping one reaches the handler, which can't open the store
  either, and falls back as described in §7.1 step 3. Checkpoint D verifies what
  is shown.
- `register` in the NSE is a common practice, but Apple doesn't document that a
  category registered there takes effect before display. The app's registration
  after every sync is the primary path, and the NSE upsert is the backstop for
  topics the device hasn't synced yet. Checkpoint D measures this (PLAN D).
- The NSE never deletes notification categories and never prunes.

## 7. Action handler

### 7.1 Flow (app process, background launch)

```
didReceive(response, completion):
  beginBackgroundTask
  q = response.notification.request.content.userInfo["quickr"]
  switch response.actionIdentifier:
    case UNNotificationDefaultActionIdentifier: route(q.url); return completion()     // opens the app
    case UNNotificationDismissActionIdentifier: return completion()
  a = parse(response.actionIdentifier)            // §4.2; failure → fail("Couldn't log")
  1. VALIDATE against userInfo (never against current local state alone):
       a.server_id == q.server_id, a.topic_id == q.topic_id, a.version == q.version, a.key == q.quick_log.key
       k=o: a.value ∈ q.quick_log.options[].value
       k=n: q.quick_log.last_value != nil and fmt(last_value) == a.value
       k=i: parse(userText) per §7.3, else → tapToFix
     any mismatch → fail("Couldn't log — open quickR to log")
  2. STORE: registry.lookup(a.server_id)
       none → fail("This reminder came from a server you've removed from quickR")      // §6a rule 8
  3. OPEN that store (it may be inactive)
       protected data unavailable → fail("Unlock your iPhone, then tap to log", url=q.url)
  4. PRECONDITIONS from the store's view:
       topic tombstoned → fail("{topic} was deleted")
       topic archived   → fail("{topic} is archived")
  5. ONE IMMEDIATE TRANSACTION (outbox.md §8, origin = notification):
       enqueue entry.create { id: new uuid, topic: {id, slug, name}, body: {
           answers: {key: value}, version: q.version, captured_at: device now (RFC 3339 with offset),
           source: "ios.notification", notes: "", meta: {} } }
       recompute derived fields                                                         // sync-protocol §3.2
  6. post Darwin db-changed
  7. REMOVE delivered notifications whose userInfo.quickr.server_id == a.server_id and topic_id == a.topic_id
     cancel pending local requests "due-{topic_id}-*" whose slot is now satisfied        // §11.2 L4
  8. BADGE: setBadgeCount(dueCount(view))                                                // §8
  9. WidgetCenter.reloadTimelines(ofKind:) only if the due state or last value changed
 10. FLUSH (outbox.md §10): forced, budget 5 s, only if the store is the active one
 11. completion(); endBackgroundTask
```

Where:

- `fail(msg)` posts a local notification with the identifier
  `quickr.err.{topic_id}`, `thread-id: topic-{topic_id}`, and no category.
  Tapping it opens `q.url`. Nothing is written.
- **Durability never depends on the network.** Step 5 commits before any request
  is made.
- `version` comes from the payload, not from the current local version. A
  notification that is still on screen after a publish logs against the version
  it was sent with, which is valid because entries pin versions (PLAN M3
  validation 5).
- **Q2 [provisional]:** logging works from the Lock Screen without
  authentication. The store and the Keychain are readable after first unlock
  (`AfterFirstUnlock`, and `completeUntilFirstUserAuthentication`).

### 7.2 Foreground behaviour (`willPresent`)

- A reminder for a topic whose slot is already satisfied in the view is
  presented with `[]`, which suppresses it, and is then removed.
- A local fallback reminder whose slot already has a delivered remote reminder
  is also suppressed (§11.2 L2).
- Otherwise the reminder is presented with `[.banner, .list, .sound]`.

### 7.3 Number text input

The input goes through these steps:

1. Trim whitespace. Strip a trailing unit that matches `unit`, ignoring case.
2. Accept either `,` or `.` as the decimal separator (only one, and no
   grouping).
3. Parse the result. It must be finite.
4. Validate it with the question's rules from the descriptor:
   - `int` requires an integer;
   - `min ≤ x ≤ max` when those are set;
   - for a `double` with `decimals = d`, the value must have at most `d`
     fraction digits.

   These are the same messages as `parseQuickNumber` and `answerSchema` (ported
   in M1).

5. If the input is valid, log `x` as in §7.1.
6. If it is invalid, write nothing. Post a local notification:
   - title "Couldn't log {topic}";
   - body "“{raw}” isn't a valid value — tap to fix";
   - identifier `quickr.fix.{topic_id}`;
   - userInfo
     `{quickr: {v: 1, kind: "fix", server_id, topic_id, url, prefill: {key: raw}}}`.

   Tapping it opens the record screen with the raw text in the field and the
   validation message showing.

## 8. Badge

- The badge is set **only on the device**. The payload has no `badge` (PLAN §2).
- Its value is the number of view topics in the active store with
  `status = active` and `due.is_due`. This is the PWA's `dueCount` semantics,
  computed with `device_now + skew`.
- These set it:
  - the NSE, through `content.badge` (§6);
  - the app, with `setBadgeCount` after every recompute of derived fields (sync,
    enqueue, ack and activation);
  - the handler (§7.1 step 8).
- Inactive stores never contribute.

## 9. APNs token lifecycle

### 9.1 Environment

The environment is read from `embedded.mobileprovision`, never from `#if DEBUG`:

1. Load
   `Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")`.
2. If it is absent, the build is App Store distribution: the environment is
   **`production`**.
3. Otherwise, extract the XML plist (the bytes from `<?xml` to `</plist>` inside
   the CMS envelope; there is no need to verify the signature) and read
   `Entitlements["aps-environment"]`:
   - `development` gives **`sandbox`**;
   - `production` gives **`production`**.
4. On the simulator, the environment is `sandbox`.

### 9.2 Registration rules

All registration runs **in the app process only**, against the **active**
store's server. **[server]** The endpoints are named as in research 03 §1. The
final paths come from B6's OpenAPI.

| Event                                                                                                                                                                    | Action                                                                                                                                                                                                              |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Permission granted (from the explainer in onboarding or Settings)                                                                                                        | Call `registerForRemoteNotifications()`                                                                                                                                                                             |
| Every cold launch, and every `scenePhase → active` that is more than 24 h after the last registration, with `authorizationStatus ∈ {authorized, provisional, ephemeral}` | Call `registerForRemoteNotifications()`. Then `didRegister(token)` sends `POST /push/apns/devices {token: lowercase hex, environment, app_version, device_name}`. This is an upsert, and it resets `failure_count`. |
| `didRegister` with a token **different** from `registry.apns_token`                                                                                                      | Register the new token. Then `POST /push/apns/devices/delete {token: old}`, best-effort. Store the new token.                                                                                                       |
| `authorizationStatus` becomes `denied` (checked on every activation)                                                                                                     | Send `POST /push/apns/devices/delete {token}` and set `registry.apns_registered = false`. When permission comes back, register again.                                                                               |
| Server switch                                                                                                                                                            | [sync-protocol.md §8.4](sync-protocol.md#84-switching-servers): delete on the old server (queued in `pending_unregister` if it fails), then register on the new one                                                 |
| Registration request fails                                                                                                                                               | Retry with the outbox backoff at the next activation. Registration is not an outbox item, because it is idempotent and has no undo.                                                                                 |
| APNs 410 / `BadDeviceToken` (server side)                                                                                                                                | The server deletes the device. The next launch registers it again, which also fixes a token sent with the wrong environment.                                                                                        |
| "Test this device" (Settings)                                                                                                                                            | `POST /push/apns/devices/test {token}`. This is online-only.                                                                                                                                                        |

## 10. Web Push compatibility **[server]** (B7, B8)

- `PushPayload` keeps `title`, `body`, `url`, `tag` and `topic_slug` unchanged.
  It **gains optional fields**: `v`, `kind`, `server_id`, `topic_id`, `version`,
  `due_since` and `quick_log`. These have the same shapes as §2.
- `tag` stays `due-{topic_id}`.
- The old `parsePushPayload` ignores unknown keys, so cached PWA builds keep
  working.
- **Chromium actions (B8)** follow these rules:
  - An enum descriptor gets
    `actions = options.slice(0, Notification.maxActions).map(o => ({action: "log|o|" + o.value, title: o.label}))`.
  - A number descriptor with `last_value ≠ null` and `maxActions ≥ 1` gets
    `[{action: "log|n|" + fmt(last_value), title: "✓ …"}]`.
  - There is no text input on the web.
  - These web action ids don't need `server_id`, because the service worker is
    bound to its origin's server.
  - `notificationclick` validates the action against
    `notification.data.quick_log`. It then enqueues `entry.create` (with
    `version` from the payload) into the IndexedDB outbox, flushes, and
    registers Background Sync.
- Safari and iOS web push don't support actions. Those clients are unchanged,
  and log in 2 taps.

## 11. Local-fallback compatibility (§6a rule 11)

A local fallback is **not built in v1**. These rules are binding now, so it can
be added later without changing identifiers, payloads or handlers.

### 11.1 Identifiers and canonical slot

- `due_since` canonical form: an RFC 3339 **UTC** timestamp, **truncated to
  whole seconds**, with the suffix `Z`, for example `2026-10-17T08:00:00Z`.
  - The server MUST emit it in this form in `quickr.due_since`.
  - Interval schedules can produce sub-second instants
    (`last entry + interval`), so both sides truncate.
- A local reminder's request identifier is `due-{topic_id}-{due_since}`.
- A local reminder's content is the same as a push: the same title, body,
  category (computed locally, §4), `thread-id` and `userInfo.quickr`. It adds
  `quickr.origin = "local"`, where a push has `"remote"` or omits it.
- **Every match uses the slot key from `userInfo.quickr`**:
  `(server_id, topic_id, due_since)`. Request identifiers are used only to
  cancel **pending local** requests, which we name ourselves.

### 11.2 Cancellation and de-duplication rules

| #   | Situation                                                                                       | Rule                                                                                                                                                                                                                                                                             |
| --- | ----------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| L1  | A push for slot S arrives, so the NSE runs                                                      | `removePendingNotificationRequests(["due-{topic}-{S}"])`, and remove any **delivered local** notification with the slot key S. This needs no store, so it also runs before first unlock.                                                                                         |
| L2  | A local reminder for S fires while a remote reminder for S has been delivered                   | In the foreground, `willPresent` suppresses the local one and removes it. In the background, no code runs. The next NSE run or app activation **de-duplicates**: for each slot key with both a local and a remote reminder delivered, it removes the local one.                  |
| L3  | A local reminder fired first, then the push arrives                                             | Same as L1: the NSE removes the delivered local reminder. The collapse id isn't relied on.                                                                                                                                                                                       |
| L4  | An entry is logged in any process (app, widget, action, Siri)                                   | After commit: remove **delivered** notifications (remote and local) for that `(server_id, topic_id)`, and cancel **pending** local requests `due-{topic}-{S}` for every slot S that the new derived `due` shows as satisfied. The fallback scheduler then re-arms the next slot. |
| L5  | A reminder is satisfied elsewhere (a pull brings a web or MCP entry)                            | After each page, for topics whose `due.is_due` became false, apply L4.                                                                                                                                                                                                           |
| L6  | A push arrives for a slot the device has already satisfied locally (offline log not yet synced) | The NSE changes the body to "Already logged on this iPhone · syncing" and clears the category (§6). Alerts can't be suppressed without the filtering entitlement, which v1 doesn't request.                                                                                      |
| L7  | A topic is archived, tombstoned or unscheduled, or its schedule is edited                       | Cancel all pending `due-{topic}-*`. On a tombstone or archive, also remove delivered reminders for the topic.                                                                                                                                                                    |
| L8  | Server switch or local reset                                                                    | Cancel pending local reminders and remove delivered reminders whose `server_id` is not the active store's ([sync-protocol.md §8.4](sync-protocol.md#84-switching-servers)).                                                                                                      |
| L9  | Budget                                                                                          | The fallback schedules at most **one pending request per topic**, for the next slot. This keeps it well within iOS's limit of 64 pending requests.                                                                                                                               |

Due computation for the fallback is the Swift port of `schedule.py`, which uses
the same vectors and `device_now + skew`. That is why the slot keys from the
server and the device agree.

## 12. Tests (minimum, in M1 and M3)

| #           | Test                                                                                                                      | Proves       |
| ----------- | ------------------------------------------------------------------------------------------------------------------------- | ------------ |
| N1          | The vectors give byte-identical action descriptors and category ids from Python and Swift                                 | §4.3, §4.4   |
| N2          | The worst-case payload is ≤ 4096 bytes and has no `aps.badge`                                                             | §2.2         |
| N3          | Parsing an action id round-trips, and fails on a tampered value (the value isn't in the options, or `last` doesn't match) | §4.2, §7.1   |
| N4          | Two processes (MP) register {A} and {A,B} at the same time 100 times. The final set always ⊇ the table.                   | §5.2         |
| N5          | Pruning never removes a category referenced by a delivered notification (fake center), even when it is `prunable`         | §5.3         |
| N6          | The handler with an unknown `server_id` writes nothing and posts the explanatory local notification                       | §7.1, rule 8 |
| N7          | The handler for an inactive store writes into that store, not the active one                                              | §6a rule 8   |
| N8          | Text input "7,5 h" with unit "h" and decimals 1 logs 7.5. "abc" posts the tap-to-fix notification and writes nothing.     | §7.3         |
| N9          | The handler logs against `q.version` after a newer version is published locally                                           | §7.1         |
| N10         | L1–L4 with a fake center: both arrival orders leave one reminder, and logging clears pending and delivered                | §11.2        |
| N11         | The environment parser: an absent file gives production, development gives sandbox, production gives production           | §9.1         |
| N12         | A token change registers the new token and deletes the old one. Denying permission deletes the token.                     | §9.2         |
| Device (M3) | The PLAN M3 checklist, plus counting the visible actions (2 or 4), plus a Lock Screen log before first unlock             | Checkpoint D |

## Open questions

1. **Q2 [provisional]: authentication for Lock Screen logging.** The default is
   no authentication (§4.1, §7.1). The user's answer is still needed.
2. **Q4 [provisional]: 5–6 options.** The default shows the 4 most-used,
   most-used first (§2.3). The user's answer is still needed.
3. **Before first unlock.** §6 leaves the content untouched, as PLAN §6 says. If
   iOS still shows actions from a category registered earlier, those actions
   fail gracefully (§7.1 step 3). The alternative is for the NSE to clear
   `categoryIdentifier` when protected data is unavailable, which hides actions
   that can't work. Decide at checkpoint D, once it is known whether categories
   persist across reboot.
4. **A confirmation after a notification log.** Should a successful action post
   a quiet "Logged ✓ · Undo" notification? The default is no: only errors
   notify.
   [outbox.md §9.1](outbox.md#91-undo-a-log-the-toast-after-quick-log-a-notification-action-a-widget-or-siri)
   already supports Undo until the next activation.

## Traceability

| Source                                                                                              | Where it is addressed                    |
| --------------------------------------------------------------------------------------------------- | ---------------------------------------- |
| PLAN §2 Reminders: collapse id, thread-id, userInfo removal, no badge                               | §2, §3, §7.1 step 7, §8                  |
| PLAN §2 Notification actions: ≤ 4, number actions, immutable categories, table                      | §4, §5                                   |
| PLAN §6 notifications spec list                                                                     | §2–§11                                   |
| §6a rule 8, `server_id` in payloads and action ids; drop when the store is gone                     | §2.1, §4.2, §7.1 step 2                  |
| §6a rule 9, serialised registration, append-only, 7-day pruning, full-descriptor hash, works with 2 | §4.1, §4.3, §5                           |
| §6a rule 10, at least once overall, best-effort per device                                          | §3.1                                     |
| §6a rule 11, local fallback identifiers and cancellation                                            | §11                                      |
| Codex v1 M5, category meaning across versions                                                       | §4.3 (immutable, versioned), §7.1 step 1 |
| Codex v1 M7 and v2 #5 (fallback dedupe; registration race)                                          | §11.2, §5.2                              |
| Codex v2 #4, notification provenance                                                                | §2.1, §4.2, §7.1                         |
| Fable B2, 4-action ceiling                                                                          | §4.1                                     |
| Fable M7, badge has no data source                                                                  | §8                                       |
| Fable minors: environment from `embedded.mobileprovision`; collapse-id lore                         | §9.1, §3                                 |
| Codex v1 "missing": token rotation, unregistering, stale actions                                    | §9.2, §7.1                               |
| Fable "missing": NSE limits and behaviour before first unlock                                       | §6                                       |
