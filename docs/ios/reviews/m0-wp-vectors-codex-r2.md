# Codex review: M0 WP vectors (round 2)

Verdict: **Approve — both original Majors RESOLVED; no new Blocker/Major found.**

- **JS double semantics — RESOLVED.** In `backend/app/services/quicklog.py:103–106`, both bounds are converted to `float` before comparison, matching JavaScript’s JSON-number rounding. The added vectors cover positive and negative bounds around 2⁵³, including the original counterexample: `max=9007199254740995`, `last=9007199254740996`.

- **Timestamp normalisation — RESOLVED.** `backend/tests/test_api_fixtures.py:155–174` validates non-null timestamps before replacement and limits replacement to `created_at`, `updated_at`, and `schedule_updated_at` at the existing topic/entry/version response paths. Those paths cover single records, paginated items, and version arrays. Metadata is excluded. Computed `due_since`/`next_due_at`, `archived_at`, and captured timestamps remain unchanged; committed fixtures now preserve actual daily/interval scheduling values and examples with and without fractions.

**New Blocker/Major: none.** The `datetime` patches are function-scoped through pytest’s `monkeypatch`, which restores the module bindings even on failure. No patched service currently performs datetime type checks that the subclass would invalidate. The scheduler background loop is disabled in the test configuration.

Two limitations remain below Major severity:

- The clock freeze does not reach `schemas.api.check_captured_at()` or PostgreSQL `now()`. Current explicit captures are safely historical, and database-generated timestamps are validated and normalised at all current response paths. The initial create-topic response still computes due state using an unfrozen database schedule reference; subsequent scheduled reads use explicitly backdated references.
- Moving explicit `updated_at` assignments to server-side `now()` will change affected fixture values from the preserved frozen instant to `SERVER_TIME`, requiring deliberate fixture regeneration.

Validation: **23 tests passed**, covering quick-log vectors, due vectors, and normaliser checks. The database-backed API scenario was excluded; frontend parity execution was not rerun.