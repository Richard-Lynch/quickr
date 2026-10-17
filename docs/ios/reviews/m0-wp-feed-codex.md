# Codex review: M0 WP feed (round 1)

**Verdict: request changes — four Major findings and one Minor finding in `e81ad84...1169835`.**

### Major

- **`backend/app/services/changes.py:53` — Cross-kind UUID collisions silently lose entities.**  
  `latest` and `found` assume UUIDs are unique across topics, versions and entries, but the database enforces uniqueness separately and entry creation accepts arbitrary client UUIDs. Create an entry with `id = topic.id`: bootstrap deduplication drops the topic’s change, returns its entry, and advances the cursor past both. The UUID-only `deleted_ids` primary key also lets tombstones collide across kinds.  
  **Fix:** key materialisation and tombstones by `(kind, id)`, including tombstone lookups and conflict targets; alternatively enforce global identity allocation. Add a bootstrap/delete regression using an entry UUID equal to its topic UUID.

- **`backend/app/services/feed.py:63` — The decorator can commit mutations before taking the lock.**  
  `db.in_transaction()` does not establish that the transaction contains only reads. `commit()` unconditionally flushes pending ORM changes. Passing a session with an added, dirty or deleted entity therefore persists those changes before the advisory lock, potentially without a feed row. A nested decorated writer also commits the outer writer’s partial work and releases its lock. The preliminary commit sits outside the retry handler.  
  **Fix:** make one outer transaction owner acquire the lock before executing work; reject dirty/pre-existing write transactions and either explicitly reject nesting or support nesting without committing. Put the transaction’s commit inside the retry boundary. Test pending ORM writes and nested calls.

- **`backend/app/services/entries.py:121` — A deleted entry can return 404 instead of `409 entry_deleted`.**  
  `resolve_topic()` runs before the permanent tombstone check. After topic deletion has tombstoned its children, replaying one of those entry creates against the original topic returns 404. The added topic-deletion test explicitly expects this. That contradicts the promised create-after-delete outcome and bypasses the PWA’s new retirement classifier, leaving the operation as a terminal failure instead of retiring it.  
  **Fix:** under the writer lock, check a supplied entry ID’s tombstone before resolving its topic. Update the test to require `409 entry_deleted` for both REST and MCP replay.

- **`frontend/src/lib/outbox/outbox.ts:325` — Retirement becomes a false “saved on this device” result.**  
  The new retirement event resolves `sendNow()` as `discarded`. Its consumer, `recordEntry()` in `frontend/src/api/entries.ts`, maps `discarded` to `queued`. Consequently, a server-confirmed permanent rejection removes the durable item and optimistic overlay, but the quick-log UI reports that it was logged and “saved on this device, will sync.” It will never sync. The added tests stop at the outbox/effects layers and miss this consumer mismatch.  
  **Fix:** preserve a distinct retired result through `sendNow()` and `recordEntry()`, then display an appropriate deleted/undone outcome. Add an integration test covering `entry_deleted` through the user-facing result.

### Minor

- **`backend/app/services/changes.py:29` — Feed identity is outside the page’s snapshot.**  
  `feed_identity()` reads epoch/server identity, commits, and only then starts REPEATABLE READ for the page. An epoch rotation between those transactions produces a response pairing the old epoch with data and head from the new snapshot. It violates the single-snapshot response contract and can postpone restore detection until another request.  
  **Fix:** initialise missing settings separately, then read the stored identity inside the same read-only REPEATABLE READ transaction as head, log rows and entities. Add a controlled rotation between the initial identity read and page materialisation.

The ordering test **does overlap transactions**, but its fixed sleep does not prove B reached the database lock wait. A lock-wait handshake would make it deterministic. The retry test injects exceptions before performing mutations, so it does not verify rollback and replay of actual writes.

Static review only; tests were not executed. Amendment-13 header absence was excluded.