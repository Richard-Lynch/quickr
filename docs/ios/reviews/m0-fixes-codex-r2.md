# Codex review: M0 milestone fixes (round 2)

**APPROVE WITH MINORS**

- **Major `/push/test` race — RESOLVED.** `send_test` now uses `@writer_once` ([push.py:248](/Users/richie/code/quickr-worktrees/ios-m0-fixes/backend/app/services/push.py:248)). The wrapper acquires the feed lock, checks identity, delivers, and commits before releasing it. The new regression starts rotation during delivery and verifies it waits until delivery finishes.

- **Minor header read committing handler work — RESOLVED.** Middleware rolls back unfinished handler work before reading headers; `feed_identity` ends its read with rollback. New tests cover pending ORM changes, executed SQL writes, unhandled errors, and swallowed database errors.

- **Scheduler/VAPID side effect — no advisory-lock deadlock or missing commit found.** Scheduler calls `_ensure_vapid_keys` through `send_to_all`, without acquiring the feed lock. Feed writers never acquire the scheduler lock. Neither advisory-lock ordering exists. Contention on subscription/topic rows or first-use VAPID inserts can cause waits, but I found no reverse dependency forming a cycle. `tick` explicitly commits keys, subscription bookkeeping, and notification markers together at its end; exceptions roll back when its session closes. External deliveries remain nontransactional, so failure after delivery can permit duplicate notifications on a later tick.

- **Minor: lock duration.** Scheduler now retains its advisory lock across the complete tick, including first-use key creation. `/push/test` retains the global feed lock across sequential deliveries, blocking all feed writers. Its “a few seconds at most” comment is inaccurate: duration scales with subscriptions, network timeouts, and DNS latency. Correct the comment; consider bounded delivery time.

- **`writer_once` — correct.** One attempt includes commit failures; errors roll back and propagate without replay. Nesting inside a retried writer raises `WriterMisuse`. Both behaviors have regression tests.

**No new Blocker/Major found.** Static review only; tests were not rerun under read-only permissions.