# Shared fixtures

Generated from the backend and checked by every platform (the Swift tests in
`ios/QuickrKit` bundle them as resources). **Never edit these by
hand.** Run `make vectors` (it needs the test database, like `make check`) and
commit the result.

| File                    | Generator                                                         | Checked by                                                                  |
| ----------------------- | ----------------------------------------------------------------- | --------------------------------------------------------------------------- |
| `due-vectors.json`      | `backend/tests/test_due_vectors.py` (real `services/schedule.py`) | pytest drift check; Swift `QuickrCore` due tests (M1)                       |
| `quicklog-vectors.json` | `backend/tests/test_quicklog_vectors.py` (`services/quicklog.py`) | pytest drift check; `frontend/src/lib/quickLog.vectors.test.ts`; Swift (M1) |
| `api/*.json`            | `backend/tests/test_api_fixtures.py` (the app, via ASGI)          | pytest drift check; Swift `QuickrData` decoding tests (M1)                  |

## Drift checks

Each generator rebuilds its output on every `pytest` run. With
`QUICKR_UPDATE_VECTORS=1` (what `make vectors` sets) it writes the files;
otherwise the test fails when a committed file differs ("… is stale - run 'make
vectors'"). So `make check` and CI fail when the logic or the API changes and
the fixtures don't. Review the regenerated diff: it is the behaviour change that
the Swift port has to follow.

## `due-vectors.json`

- `meta`: generator version, the tzdata release used (informational only: not
  compared, because CI and macOS ship different releases; the 2026 rules are the
  same in all of them), `early_window_max_seconds`, `lookback_days`,
  `lookahead_days`, and `semantics`: the rules in prose, including PEP 495
  `fold=0` (a time in a spring-forward gap uses the pre-gap offset, so it lands
  after the gap; an ambiguous time uses its first occurrence).
- `schedules`: `id -> schedule` (the API's JSON shape). Cases refer to them by
  id.
- `slots[]`: `{name, schedule, start, end, expected[]}`: `daily_slots` over
  `[start, end]`.
- `due[]`:
  `{name, schedule, now, last_entry_at, schedule_since, archived, expected: {is_due, due_since, next_due_at, last_entry_at}}`:
  `compute_due`.
- `messages[]`: `{name, timezone, due_since, now, expected}`: `due_message`.
  `%a`/`%b` are C-locale English abbreviations.

Every timestamp is UTC ISO-8601 at second precision with a `Z` suffix. Each case
is one line, so diffs stay readable.

## `quicklog-vectors.json`

- `eligibility[]`: `{name, questions, expected}`. `expected` is `null`,
  `{kind: "chips", key, options: [{value, label}]}` (active options in order) or
  `{kind: "number", key}`.
- `initial[]`: `{name, question, last, expected}`: the text a number quick-log
  starts with. `last` is any JSON value. Numbers print as JS `String(n)` would
  (`7.0` gives `"7"`, `1e21` gives `"1e+21"`).

## `api/*.json`

There is one file per recorded call, named `<operationId>[.<variant>].json`:

```json
{
  "operation_id": "createEntry",
  "request": { "method": "POST", "path": "/api/v1/…", "body": {} },
  "status": 201,
  "body": {}
}
```

They cover every operation in `openapi.json` except `exportEntriesCsv` (a CSV
download, not JSON). `test_every_operation_has_a_fixture` enforces this: an
operation without a fixture fails unless it is in `UNCOVERED_OPERATIONS`, with
its reason. They also cover every question type (including multi-select enums
and `enum_list` answers), daily and interval due state, a feed entry deletion
and topic deletion, and problem bodies: 422 `invalid_answers` (with `loc`), 422
`invalid_request`, 404, and 409 `conflict` (including deleting an unarchived
topic), `topic_archived` and id conflict. A 204 has `"body": null`. Push
delivery is mocked (every send succeeds), so `sendTestPush` is deterministic.

The application clock is frozen at `2026-03-04T12:00:00.5Z`. Entries carry fixed
`captured_at` values and schedules are backdated to `2026-01-01T00:00:00Z`. So
`due_since`, `next_due_at`, `archived_at` and a defaulted `captured_at` are real
server output.

What can't be frozen is normalised, but only at known response paths: topics,
entries and versions, the records wrapped in `/changes` items, and `/changes`
deletions. It is never applied inside `meta` or answers. The generator first checks
that the original is a timezone-aware ISO-8601 datetime and fails otherwise:

- The Postgres `now()` fields `created_at`, `updated_at`, `schedule_updated_at`,
  `archived_at`, `deleted_at` and the feed's `server_time` become
  `2026-06-01T12:00:00.123456Z`, unless they hold one of the pinned instants
  above.
- Server-generated UUIDs become `00000000-0000-4000-8000-<n>`, numbered in order
  of first appearance. This includes the feed's `epoch` and `server_id`.
  Client-supplied entry ids are kept. Feed `seq`, `head` and `next` are real: the
  test database restarts its sequences.
- The VAPID public key is replaced with a fixed one, after checking its format.

Every other `*_at`, `due_since` and `start` value in a response body is
format-checked too. The server sends microseconds and drops the fraction when it
is zero. The fixtures contain both forms (for example the normalised `.123456`
timestamps, and `captured_at` and the due instants without a fraction), so
decoders must accept both.

To add an endpoint, add one `rec(...)` call to `scenario()`.
