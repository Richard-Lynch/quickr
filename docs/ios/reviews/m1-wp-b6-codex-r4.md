# Codex review: M1 WP B6 (round 4, approved)

**APPROVE**

**TTL Major: RESOLVED.** In `scheduler.py`, `active` is built from the complete `due_topics` list, computed before delivery. It therefore includes topics deferred when the budget breaks the delivery loop. `_record_progress()` prunes expired rows only when their `(topic_id, due_since)` pair is absent from that active set; completed topics’ progress is deleted separately.

Evidence:

- The new active-slot regression ages progress beyond the TTL, runs a tick with no delivery budget, verifies progress survives, then completes delivery and checks each target received exactly one send.
- The abandoned-slot regression verifies progress survives before expiry and is pruned afterward.
- `NOT IN` has no NULL hazard: both database columns are non-null primary-key columns, and active pairs contain a topic ID and explicitly checked non-null `due_since`.
- An empty active set correctly permits cleanup of all expired progress.

**No new Blocker/Major identified.** The tuple exclusion grows with due-topic count and could warrant optimization at large scale; no evidence establishes a Major performance regression here.

Validation: source, migration, and regression-test inspection; tests were not executed.