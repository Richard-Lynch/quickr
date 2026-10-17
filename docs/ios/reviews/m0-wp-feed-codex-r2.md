# Codex review: M0 WP feed (round 2)

**Verdict: request changes — two Majors remain in `1169835...HEAD`; no new Blocker found.**

Round-1 findings:

1. **Cross-kind UUID collisions — PARTIAL.** `changes.py` now keys materialisation and tombstone lookups by `(kind, id)`; the model, deletion checks, and conflict target agree. Fresh databases are fixed, with collision regression coverage. Existing databases at revision `f6d7e8f9a0b1` remain broken because the migration was edited in place; see below.

2. **Writer transaction ownership — RESOLVED.** `feed.py:73–98` rejects pending ORM work and open transactions, acquires the lock before executing services, and commits inside the retry boundary. Nested writers share the outer transaction. Added tests cover rejection, nested rollback, and rollback/replay of actual writes. Commit-time retry lacks a dedicated regression, but the implementation includes it.

3. **Deleted entry returning 404 — RESOLVED.** `entries.py:124–126` checks the entry tombstone under the writer lock before resolving the topic, so deleted-topic replay reaches `entry_deleted`.

4. **Retirement reported as queued — RESOLVED.** The distinct `retired` result survives `sendNow()` → `recordEntry()` → quick-log/form consumers. Quick-log displays “Not saved”; tile consumers suppress success confirmation. `quickLog.test.tsx` covers an actual `409 entry_deleted` through the user-facing toast and verifies an empty outbox.

5. **Page identity outside snapshot — RESOLVED.** `changes.py:31–43` initialises settings separately, then reads identity inside the page’s REPEATABLE READ transaction. Controlled rotation tests cover rotation before and during page materialisation. Response-header consistency remains an issue below.

New Majors:

- **Epoch preconditions are not atomic with mutation.** [identity.py:102](/Users/richie/code/quickr-worktrees/ios-m0-feed/backend/app/api/identity.py:102) checks middleware-cached identity, read before the writer lock. `rotate_epoch()` neither acquires that lock nor coordinates with the check. Reproduction: request reads epoch A, waits for the feed lock; rotation commits B; request acquires the lock and mutates successfully using expected epoch A. Even moving the dependency check immediately before the service leaves this race. **Fix:** rotation must acquire the feed lock, and mutation preconditions must be re-read and checked inside the same locked transaction, including retries. Apply equivalent coordination to subscription mutations, which currently own separate transactions. Also derive `/changes` identity headers from its snapshot: rotation between middleware and page reads can currently produce header A with body B.

- **Already-migrated databases have no schema upgrade path.** [migration:48](/Users/richie/code/quickr-worktrees/ios-m0-feed/backend/alembic/versions/20261017_f6d7e8f9a0b1_change_feed.py:48) changes the primary key without advancing the revision. A database migrated using round-1 code stays UUID-keyed after `alembic upgrade head`; new `ON CONFLICT (kind,id)` tombstone inserts then fail because no matching unique constraint exists. **Fix:** add a forward migration replacing the primary key, and test upgrading the original schema. This matters wherever the earlier revision has already run.

Caller/middleware audit: REST and MCP writers receive fresh sessions; seed now ends its preliminary read. Scheduler and push retain their existing transaction ownership and do not call decorated feed writers. Streaming bodies are forwarded without buffering; failures after response start are re-raised. Pre-start 500s receive identity headers, but bypass inner CORS processing. Every API request also adds two identity SELECT transactions/commits, including health and preflight; no performance measurements were supplied.

Static review only; tests were not executed in this read-only environment.