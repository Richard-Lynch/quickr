# Review of PLAN.md draft v1: Codex (codex-cli 0.163.0, read-only)

**Verdict: Not ready to execute. The sync contract can lose data or resurrect deleted entries, and required native logging paths depend on unproven fallbacks.**

1. **Blocker — The change-feed cursor is not lossless.**  
   **Claim:** B4 and §9: `(updated_at, id)` cursor, tombstones, “2-minute overlap re-read.”  
   **Evidence:** `research/03-backend.md` §4 pages entries by tuple but selects tombstones using only `deleted_at > :ts`. It never defines one bounded ordering across both collections: deletion-only pages, equal timestamps and separate limits can skip records. A transaction committing more than two minutes behind the watermark is permanently missed. Changing `entries.py:187` to transaction-start `now()` does not solve commit ordering.  
   **Fix:** Specify a commit-safe feed and snapshot/bootstrap protocol before M1. Use a serialized transactional revision mechanism or another proven design; a plain sequence also needs commit-order handling. Test concurrent commits, long transactions, deletion-only pages and interrupted backfills.

2. **Blocker — Undo cannot safely rely on expiring client leases.**  
   **Claim:** M1 outbox leases; research §3 uses 30-second leases and orders operations per entity.  
   **Evidence:** A suspended sender can outlive its lease. Another process can replay/create, then delete; the original POST may subsequently reach the server and recreate the entry. Current idempotency only checks live rows (`backend/app/services/entries.py:101–119`); deletion removes that protection (`:202–205`). CAS protects local bookkeeping, not server effects.  
   **Fix:** Persist operation identity and cancellation semantics server-side, or provide an explicit protocol preventing stale creates after deletion. Distinguish “never attempted” from “delivery uncertain”; uncertain creates cannot simply be discarded. Test lease expiry, lost responses, suspension and late POST completion after DELETE.

3. **Blocker — “Wipe-and-repull” can destroy offline work.**  
   **Claim:** M1: “A `resync_required` wipe-and-repull.”  
   **Evidence:** The mirror contains unsynced entries, edits, failed items and undo state. No preservation rule exists. Retention expiry is expected after prolonged offline use, directly implicating REQUIREMENTS.md:18.  
   **Fix:** Rebuild server-owned state separately, preserve the outbox and local overlays, then reconcile transactionally. Test resync with pending creates, updates, deletes and failed records.

4. **Major — “Local outbox wins” does not define eventual convergence.**  
   **Claim:** M1 tombstone merge rule.  
   **Evidence:** If a server deletion is skipped while an update is pending, the cursor still advances. PATCH then returns 404 (`entries.py:149–155`); discarding the failed mutation can leave a permanent local ghost. A topic tombstone must also invalidate dependent operations and versions.  
   **Fix:** Keep server state/tombstones beneath local overlays. Define acknowledgement, failure, discard and parent-deletion transitions; reconcile after each terminal transition. Test these transitions rather than only uncomplicated tombstone application.

5. **Major — Notification actions have unstable meaning across versions.**  
   **Claim:** §2/M5: category `quickr.topic.{id}`, replaced after sync or by the NSE.  
   **Evidence:** An old delivered notification pins version N, while the mutable category can contain labels/actions from N+1. Concurrent app/NSE read-modify-write registration can also overwrite categories; registration replaces a set, rather than providing an atomic upsert. Available action presentation varies by context. [Apple category documentation](https://developer.apple.com/documentation/UserNotifications/UNNotificationCategory?language=objc).  
   **Fix:** Version categories and action identifiers by descriptor shape, validate responses against the notification’s pinned descriptor, retain categories needed by delivered notifications, and test publish/rename/archive races.

6. **Major — The M5 fallback drops a binding requirement.**  
   **Claim:** §9: fall back to generic category with “Open.”  
   **Evidence:** Opening the app does not satisfy “log from a notification” (REQUIREMENTS.md:14). The go/no-go occurs only after four substantial milestones; notification feasibility affects the shared store and action model.  
   **Fix:** Move the device spike immediately after provisioning. Define an answer-capable fallback or explicitly identify the unsupported cases as infeasible, with a requirement decision before proceeding.

7. **Major — Matching identifiers does not establish fallback deduplication.**  
   **Claim:** §2: future local notifications “dedupe for free.”  
   **Evidence:** APNs collapse identifiers merge remote notifications; this alone does not prove cancellation/replacement of a pending local request, particularly if it fires after the remote arrives. [Apple APNs contract](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns).  
   **Fix:** Retain compatible identifiers, but specify explicit local cancellation and slot reconciliation. Test both arrival orders, offline delivery and a reminder satisfied elsewhere.

8. **Major — GRDB safety is deferred beyond the architecture decision.**  
   **Claim:** §2/§9: shared `DatabasePool`, app-only migrations, Darwin notifications and fallback JSONL.  
   **Evidence:** Single-process in-memory tests in research §2 cannot prove WAL locking, coordinated migration or suspension safety. JSONL introduces another concurrent persistence protocol without atomic append, recovery or deduplication rules. Darwin signals are not durable. [GRDB sharing guidance](https://github.com/groue/GRDB.swift/blob/master/Documentation/SharingADatabase.md).  
   **Fix:** Add file-backed multi-process tests in M1; coordinate migration against existing connections, reconcile observations on activation, and define crash-safe fallback ingestion. Test process termination while holding locks and extension launch before app migration.

9. **Major — Widget writes lack a reliable delivery contract.**  
   **Claim:** M6: widgets write the shared outbox and reload after writes/background refresh.  
   **Evidence:** No bounded extension flush, expiration handling or visible “queued” state is specified. `BGAppRefreshTask` does not guarantee prompt execution. Widget reloads are also budgeted, so local timelines cannot promise timely awareness of web changes. [Apple WidgetKit guidance](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date).  
   **Fix:** Define execution host and flush behavior for each intent, durable enqueue before completion, opportunistic sending, and pending/stale presentation. Test killed-app logging with unavailable networking and without subsequent foreground launch.

10. **Major — Scheduler validation promises an impossible “exactly once.”**  
    **Claim:** M5: scheduler fans out to web and APNs “exactly once.”  
    **Evidence:** Sending and committing are separate effects (`scheduler.py:78–89`). Commit failure causes duplicates; marking a slot after partial failures can lose delivery to failed targets. Research explicitly retains send-then-mark.  
    **Fix:** Define best-effort or at-least-once semantics. If retries matter, persist per-device/slot delivery state. Test partial failures, tick cancellation, commit failure and late device registration.

11. **Major — Backend deployment is missing from milestone dependencies.**  
    **Claim:** §4: backend changes ride the final M7 merge; meanwhile milestones ship usable increments.  
    **Evidence:** The phone needs B3/B4 from M1 onward. Image publishing follows `main` CI or version tags (`.github/workflows/publish.yml:3–9`), not integration-branch merges. Device `localhost` also cannot reach the Mac’s Docker stack.  
    **Fix:** Specify a reachable development deployment, LAN addressing, local-network permission and HTTP/ATS policy in M2. Either deploy feature images explicitly or agree additive backend PRs into `main` before their consumers.

12. **Major — Validation does not establish full parity.**  
    **Claim:** M1–M4 checklists and §8 gates.  
    **Evidence:** Fixture decoding proves neither request encoding nor endpoint coverage. A chart screenshot does not establish bucketing/timezone correctness. M1’s required integration validation conflicts with its “none” human blockers and CI-first development; integration remains opt-in.  
    **Fix:** Add a requirement-to-test matrix, request contract tests, deterministic chart assertions, automated backend integration, and minimum-iOS testing. Make unavailable validation block completion explicitly.

13. **Minor — The workflow adds integration overhead without isolation rules.**  
    **Claim:** §4: mandatory WP worktrees, merge commits and multiple reviews.  
    **Evidence:** Separate files still share schemas, generated clients, Docker ports and test databases. `Makefile` supplies no worktree-specific isolation. M0/M1 also cannot provide the required screenshots/videos/GIFs.  
    **Fix:** Parallelize only independent work; isolate database/ports, assign generated-file ownership, integrate sequentially, and explicitly exempt non-UI milestones from media requirements.

**Missing items**

- Server-URL changes must partition/reset mirrors, cursors, outboxes and APNs registrations; otherwise queued private data can reach another server.
- Keychain accessibility compatible with locked notification actions, plus behavior before first unlock.
- Repeat-last semantics when required fields change, options retire, no previous entry exists, or the topic is archived; reconcile §2 with Q3.
- APNs token rotation, unregister/notification-disable behavior, expiry and stale reminder actions.
- Pagination of the complete topic list: the supporting recipe fetches only 200, the API’s page maximum (`backend/app/api/routes.py:140`).
- Retention cleanup when APNs/Web Push scheduling is disabled, database backup/restore cursor invalidation, and local reset with pending writes.