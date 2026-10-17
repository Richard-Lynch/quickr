# Codex review: M0 milestone fixes (round 1)

**REQUEST CHANGES**

- **Pool starvation — RESOLVED.** [identity.py:90](backend/app/api/identity.py#L90) owns one session; `get_db` yields that same session. Header lookup therefore needs no second connection. The [bounded-pool test](backend/tests/test_identity.py#L357) is a valid regression: both session factories use one engine with `pool_size=1`, `max_overflow=0`; concurrent reads, errors and writes must return correct headers. Even one ordinary read would expose the original second-checkout failure. It does not test cancellation or streaming concurrency.

- **`/push/test` identity bypass — NOT RESOLVED completely; Major remains.** The route declares `ExpectIdentity`, and tests cover initial mismatches, zero deliveries/database changes, and rotation **before lock acquisition**. However, [send_test](backend/app/services/push.py#L242) calls `check_identity`, whose writer transaction commits and releases the lock, **then** sends notifications and commits subscription changes. Rotation can complete between these steps; effects then execute under an obsolete expected epoch, contrary to F10. The comment explicitly accepts this race without changing the contract. Hold coordination through delivery and commit using a transaction that never automatically replays external sends; add a regression that rotates after the check.

- **Fixture coverage — RESOLVED.** Missing JSON operations now have fixtures; [operation coverage](backend/tests/test_api_fixtures.py#L440) checks OpenAPI against committed files, explicitly excluding CSV with a reason.

- **`make check` parity — RESOLVED** for the cited omissions. [Makefile:74](Makefile#L74) now invokes OpenAPI freshness, generated-client freshness and Alembic checks alongside existing gates.

- **Fixture docstring — RESOLVED.** It distinguishes the frozen Python clock from normalized database timestamps.

- **`/api/v1` prefix matching — RESOLVED.** `_under` requires an exact path or slash boundary; `/api/v10` has regression coverage.

- **`seq` ordering note — RESOLVED.** Sync protocol §1.3 explicitly makes `seq` authoritative and explains transaction-start timestamps.

The shared-session design has one **new Minor**: [feed_identity](backend/app/services/feed.py#L161) unconditionally commits the handler’s session. Yes, this can flush and commit unfinished handler work, including work left before a handled exception. Existing mutation paths commit or roll back explicitly, so I found no current endpoint demonstrating a new Major. Separate header reading from transaction finalization; add pending-write/error regression coverage.

Unhandled exceptions before response start roll back before header lookup. After response start, failures propagate and session closure rolls back remaining work. CSV preserves its snapshot headers and transaction while streaming; ordinary READ COMMITTED lookups preserve “epoch never older than data.” Session ownership spans awaited response/background execution; no current background session sharing or leak found. MCP bypasses this middleware and retains independent sessions; other paths retain fallback ownership. Future concurrent background use of the shared session would require isolation.

**No new Blocker/Major found.** STATUS ignored as requested. Static review only; database tests were not rerun in this read-only environment.