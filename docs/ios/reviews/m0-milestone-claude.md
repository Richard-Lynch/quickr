# Claude review: M0 milestone

**Verdict:** SHIP WITH MINORS. No Blockers or Majors.

This is a condensed record of the review. The reviewer had no shell access; it read the files directly and did not re-run any gates.

**Checked and holding after integration:**
- The writer lock is the first statement in every transaction, and seq is allocated after it.
- The `/changes` page is a REPEATABLE READ snapshot.
- Callers into the writer are correct: MCP, `rotate_epoch`, and nested writers.
- Retry covers commit-time deadlocks and serialization failures.
- Tombstones are written before the foreign-key cascade.
- The tombstone check runs before the topic is resolved.
- A page emits each entity once, at its latest seq.
- Identity headers come from the snapshot on `/changes` and CSV.
- Middleware order is CORS, then Identity, then GZip.
- Migration downgrades are tested.
- The PWA marks an item retired only on 409 `entry_deleted`.
- CI runs the openapi, alembic and pytest drift checks.
- The scaffold's gitignore and pinned actions are correct.

**Minors:**

1. **`test_api_fixtures.py` docstring is wrong about the frozen clock.** It claims more is frozen than really is. → Fixed in WP m0-fixes.
2. **DB `now()` is the transaction start.** A writer that queued on the lock can therefore carry a slightly earlier timestamp than one that committed before it. → Documented: seq is the only ordering authority (m0-fixes).
3. **The identity middleware opens a second connection per response.** → Treated as Major per Codex; redesigned in m0-fixes.
4. **The `/api/v1` prefix also matches `/api/v10`.** → Fixed in m0-fixes.

**Design note:** a feed topic's `entry_count`, `last_captured_at` and `due` go stale after entry changes. Clients must derive them locally, as the spec requires. M1 must follow this.
