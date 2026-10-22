# Codex review: M0 WP specs (final check)

NOT READY

- **Identity header provenance — NOT RESOLVED (Major).** Sync §1.4 now requires headers from the serving transaction/snapshot and claims M0-feed implements this. However, backend `identity.py:39–43,76–82` reads identity through a **separate session after handling**. Rotation between lookup and header generation can still label an E1 result with E2. The new backend test rotates **before** lookup; it does not cover that remaining race. The original race is fixed, but transaction-bound provenance remains unimplemented.

- **Undecodable 2xx / cancellation safety — RESOLVED.** Outbox §§5.1–5.2 explicitly set `maybe_delivered = 1`, make an undecodable create response `uncertain`, and route Undo through standalone DELETE. Test 59 specifies committed POST → malformed 201 → Undo → DELETE → server entry absent; test 5 now preserves uncertainty.

- **F10 — RESOLVED.** Sync F10 now requires rejection “before any mutation effect” and explicitly permits checking under the feed advisory lock.

- **F8 — RESOLVED.** Sync F8 qualifies `next = head` with `after ≤ head`, and documents `after > head → next = after` plus the restore check.

- **Hold-release tests — RESOLVED.** Outbox tests 60–61 explicitly cover nonadjacent never-attempted creates and uncertain creates, including preservation during hold and DELETE-only release.

**NEW Blocker/Major:** None independently identified in these two commits. The provenance Major above remains; the new assertion that M0-feed implements transaction-bound headers is inaccurate.

These are specification/test-matrix checks; no tests were executed.