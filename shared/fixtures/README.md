# Shared fixtures

Generated from the backend and checked by every platform (the Swift tests in
`ios/QuickrKit` bundle them as resources). **Never edit these by hand.** Run
`make vectors` (it needs the test database, like `make check`) and commit the
result.

| File                           | Generator                                                                     | Checked by                                                                                       |
| ------------------------------ | ----------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| `due-vectors.json`             | `backend/tests/test_due_vectors.py` (real `services/schedule.py`)             | pytest drift check; Swift `QuickrCore` due tests (M1)                                            |
| `quicklog-vectors.json`        | `backend/tests/test_quicklog_vectors.py` (`services/quicklog.py`)             | pytest drift check; `frontend/src/lib/quickLog.vectors.test.ts`; Swift (M1)                      |
| `answer-text-vectors.json`     | `backend/tests/test_answer_text_vectors.py` (`services/answers.py`)           | pytest drift check; `frontend/src/lib/answerText.vectors.test.ts`; Swift `AnswerTextVectorTests` |
| `jsnumber-vectors.json`        | `frontend/scripts/gen-jsnumber-vectors.js` (V8 `String(x)`, run once by hand) | Swift `JSNumberVectorTests`; pytest (`js_number_string` in `services/quicklog.py`)               |
| `notification-vectors.json`    | `backend/tests/test_notification_vectors.py` (`services/notification.py`)     | pytest drift check; Swift notification categories (M3, spec test N1)                             |
| `action-entry-id-vectors.json` | `backend/tests/test_action_entry_id_vectors.py` (`services/notification.py`)  | pytest drift check; `frontend/src/lib/pushActions.test.ts`; Swift action handler (M3)            |
| `home-vectors.json`            | `backend/tests/test_home_vectors.py` (`list_topics`, test database)           | pytest drift check; Swift home list ordering, status filter and search (M2)                      |
| `home-due-vectors.json`        | `frontend/src/lib/home.vectors.test.ts` (`dueParts`, `splitByDue`, vitest)    | vitest drift check; Swift home due pill and sections (M2)                                        |
| `entries-vectors.json`         | `backend/tests/test_entries_vectors.py` (`list_entries`, test database)       | pytest drift check; Swift topic entry list filters, order and sources (M2)                       |
| `entries-range-vectors.json`   | `frontend/src/lib/entries.vectors.test.ts` (`rangeStart`, `parseRange`)       | vitest drift check; Swift entries range filter (M2)                                              |
| `api/*.json`                   | `backend/tests/test_api_fixtures.py` (the app, via ASGI)                      | pytest drift check; Swift `QuickrData` decoding tests (M1)                                       |

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

## `answer-text-vectors.json`

- `meta.python_whitespace`: every code point Python's `str.strip()` removes (it
  differs from JS `trim()`: U+001C–U+001F and U+0085 strip, U+FEFF doesn't).
- `cases[]`: `{name, question, raw, expected}`. Strings are arrays of code
  points. `raw` is what the user typed (one string, or the picked values of a
  multi-select). `expected` is `{ok: true, value}` (what the server stores;
  `null` = unanswered) or `{ok: false, message}` (the clients' message).

## `jsnumber-vectors.json`

- `cases[]`: `{bits, string}`: a double as 16 big-endian hex digits and what JS
  `String(x)` prints for it. 5,000+ cases: edge values, powers of ten, random
  bit patterns and typed-looking decimals, from a seeded generator. Not
  regenerated by `make vectors` (it needs Node, not the backend): rerun
  `node frontend/scripts/gen-jsnumber-vectors.js` only to add cases.

## `notification-vectors.json`

What a reminder offers to log, and its notification category
([docs/ios/specs/notifications.md](../../docs/ios/specs/notifications.md) §2.3,
§4). The iOS app registers categories from its local store, so its port must
produce byte-identical descriptors, actions and category ids.

- `meta.semantics`: the rules in prose (descriptor, `last_value`, actions, hash
  input, category id, body suffix, `fmt`).
- `cases[]`:
  `{name, server_id, topic_id, version, questions, counts, last, expected}`.
  `counts` maps an option value to the number of entries that chose it, and
  `last` is the latest numeric answer for the key (any JSON value). `expected`
  is `{quick_log, actions[], hash_input, category_id, body_suffix}`, with
  `quick_log`, `hash_input` and `category_id` null and `actions` empty when the
  topic isn't quick-loggable. Each action is `{kind, identifier, title}`, plus
  `text_input_button_title` and `text_input_placeholder` for `kind: "input"`.
  `kind` is `log`, `input`, or `open` (the "More…" action, identifier `…|m|`).
  `hash_input` is already NFC-normalised, with U+001E and U+001F separators.
- `fmt[]`: `{kind, value, bits, expected}`: how numbers appear in action titles
  and identifiers: the shortest round-trip decimal, positional, never rounded to
  `decimals`. Doubles carry `bits` (IEEE 754, big-endian hex), so a port can
  build the exact value without trusting its JSON parser.

## `home-vectors.json`

The home list as the server orders, filters and searches it, for the iOS app's
offline port. The real `list_topics` runs against a fixed set of topics in the
test database, at a fixed `meta.now`.

- `meta`: `generator`, `version`, `now` (the instant due state is computed at)
  and `collation`: the test database's `datcollate`, informational only. The
  server runs `postgres:18-alpine`, whose musl `strcoll` compares bytes whatever
  `datcollate` says, so `ORDER BY lower(name)` is the lowercased name's UTF-8
  byte order, without normalisation. The `collation sample` topics pin that down:
  spaces and punctuation (`a b` < `a-c` < `a.b` < `ab`), case ties, accents after
  `z` (`zed` < `é b` < `éclair`) and an NFD `É` among the `e`s.
- `topics[]`: every topic as `GET /topics/{id}` returns it, with `due` computed
  at `meta.now`: active and archived, daily and interval schedules (due, due at
  the same instant, not due until later today, tomorrow or next week, satisfied
  by an entry, `schedule_updated_at` null), unscheduled topics with and without
  entries, an older topic version whose questions no longer count.
- `cases[]`: `{name, status, sort, q, expected}`. `expected` is the full ordered
  list of topic ids `list_topics(q, status, sort, now=meta.now)` returns. `q` is
  a string or `null`.

The rules the cases pin down:

- `status`: `active` or `archived` keeps that status; `all` keeps both.
- `q` is stripped of surrounding whitespace (a blank `q` matches everything) and
  matched as a case-insensitive substring (`ILIKE`, `%` and `_` literal) of the
  name, slug, description, or a current-version question's `key`, `label` or
  `help_text`. Questions only in older versions don't match. There is no accent
  folding (`cafe` doesn't find `Café`); non-ASCII case folding follows the
  database's `LC_CTYPE` (`CAFÉ` finds `Café` under `en_US.utf8`).
- `due`: due topics first, by `due.due_since` ascending; then other scheduled
  topics by `due.next_due_at` ascending (archived ones have none and sort last
  in this group); then unscheduled topics by activity (`last_captured_at`, else
  `updated_at`) descending. Each group breaks ties by id ascending.
- The other sorts order by `lower(name)`, `updated_at`, `created_at` or
  activity, ascending or (leading `-`) descending, then by id ascending, also
  for the descending sorts.

Timestamps are UTC ISO-8601; the server drops a zero fraction, so the topics'
instants have no fraction. Each case is one line.

## `home-due-vectors.json`

The home screen's due pill and sections, which the PWA computes client side
(`dueParts` in `frontend/src/lib/schedule.ts`, `splitByDue` in
`frontend/src/lib/home.ts`). Generated by vitest, not pytest: `make vectors`
runs it with `QUICKR_UPDATE_VECTORS=1`, and the frontend tests are its drift
check. The text is locale and time zone dependent, so the vectors hold the
decision, not the label.

- `meta`: `generator`, `version`, `timezone` (`Europe/London`: the generator
  pins `TZ` to it, and `day_offset` is in it), `fresh_due_ms` (a due slot reads
  "Due now" while younger than this, else "Overdue") and `soon_ms` ("Due in …"
  up to and including this wait).
- `due_view[]`: `{name, now, due, expected}`. `due` is the topic's `due` (or
  `null`). `expected` is `{tone, kind, when?, minutes?}`:
  - `tone`: `none`, `due`, `overdue`, `soon` or `later`.
  - `kind`: `none` (no label), `due_now` ("Due now"), `due_since` ("Due now ·
    since {when}"), `overdue_since` ("Overdue · since {when}"), `due_in` ("Due
    in {minutes} min", or "{round(minutes / 60)} h" from 60), `next` ("Next
    {time}": the slot is later today) or `when` (another day, capitalised:
    "Tomorrow 08:00", "Mon 08:00", "12 Oct").
  - `when`: `{at, day_offset}` for `due_since`, `overdue_since`, `next` and
    `when`. `at` is the instant (`due_since`, or the passed `next_due_at`, or
    the next slot), as given. `day_offset` is the number of local calendar days
    from `now`'s day to `at`'s day:
    `round((midnight(at) - midnight(now)) / 86400000 ms)`, so DST days still
    count as one. `formatWhen` shows 0 as the time, -1 as "yesterday {time}", 1
    as "tomorrow {time}", `|d| < 7` as "{weekday} {time}", else the date.
  - `minutes`: for `due_in`, `max(1, round(wait_ms / 60000))` with JS
    `Math.round` (halves round up).
- `split[]`: `{name, now, topics, expected}`. Each topic is
  `{id, status, scheduled, due}`. `expected` is `{due, upcoming, other}`, the
  ids in order: active topics that are due now (the server says `is_due`, or
  `next_due_at <= now`) in input order; other active scheduled topics, stably
  sorted by `next_due_at` (none counts as `9999-12-31`); everything else
  (including archived topics) in input order.

Timestamps are UTC ISO-8601, some with milliseconds. Each case is one line.

## `entries-range-vectors.json`

The entries page's date-range filter, which the PWA computes client side
(`rangeStart` in `frontend/src/lib/dates.ts`, sent as `captured_from` by
`filterQuery` in `frontend/src/lib/filters.ts`). Generated by vitest, like
`home-due-vectors.json`.

- `meta`: `generator`, `version`, `timezone` (`Europe/London`: the generator
  pins `TZ` to it, and `expected` is in it).
- `cases[]`: `{name, now, range, expected}`. `range` is `7d`, `30d`, `90d` or
  `all`. `expected` is the exact `captured_from` string: local midnight of
  `now`'s day minus `days - 1` calendar days (so "7 days" is today and the 6
  before), formatted `YYYY-MM-DDTHH:MM:SS±HH:MM` with the offset in force at
  that midnight, which can differ from `now`'s across a DST change. `all` gives
  `null` (no `captured_from` sent). The cases cover both sides of local
  midnight, BST and GMT, the 2026 DST start (29 Mar) and end (25 Oct) days as
  `now` and as the range start, the year boundary and the 2028 leap day.
- `parse[]`: `{raw, expected}`: the `?range=` URL param (`parseRange`). An
  exact preset is kept; anything else (missing, empty, other case, padded,
  unknown) is the default `30d`.

`now` is UTC ISO-8601 with a `Z` suffix, some with milliseconds. Each case is
one line.

## `entries-vectors.json`

A topic's entry list as the server filters and orders it, for the iOS app's
offline port. The real `list_entries` (`order="-captured_at"`) runs against one
topic with three versions and 20 entries in the test database.

- `meta`: `generator` and `version`.
- `topic`: the topic as `GET /topics/{id}` returns it.
- `entries[]`: every entry of the topic as `GET /topics/{ref}/entries` returns
  it, in no particular order (not sorted by time or id).
- `cases[]`: `{name, filters, expected}`. `filters` is
  `{captured_from, version, source}`, each `null` when unset; `captured_from` is
  the query string as a client sends it (ISO-8601 with `Z` or an offset such as
  `+02:00` or `-05:00`, one with a fraction). `expected` is the full ordered
  list of entry ids `list_entries` returns.
- `sources[]`: `{value, count}`, `topic_stats(...).sources` without filters.

The rules the cases pin down:

- `captured_from` keeps entries with `captured_at >= captured_from`
  (inclusive), compared as instants: the offset only changes how the instant is
  written. Entries sit exactly on the boundaries and 1 s before them.
- `version` and `source` are exact matches (`source` is case-sensitive: `UI`
  matches nothing). Filters combine with AND.
- Order: `captured_at` descending, then id ascending. Several entries share a
  `captured_at`, with ids neither in insertion order nor descending, so only
  the id tie-break gives `expected`.
- `sources`: by count descending. The server has no tie-break between equal
  counts (the SQL order is undefined there), so the data has no count ties.

Timestamps are UTC ISO-8601 without a fraction. Each case is one line.

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

Only the Python clock used for due computation is frozen, at
`2026-03-04T12:00:00.5Z`, and schedules are backdated to `2026-01-01T00:00:00Z`.
So `due_since` and `next_due_at` are real server output. Every recorded entry
sends a fixed `captured_at`; a defaulted one would come from the database clock.

What can't be frozen is normalised, but only at known response paths: topics,
entries, versions and push subscriptions, the records wrapped in `/changes`
items, and `/changes` deletions. It is never applied inside `meta` or answers.
The generator first checks that the original is a timezone-aware ISO-8601
datetime and fails otherwise:

- The Postgres `now()` fields `created_at`, `updated_at`, `schedule_updated_at`,
  `archived_at`, `deleted_at` and the feed's `server_time` become
  `2026-06-01T12:00:00.123456Z`, unless they hold one of the pinned instants
  above.
- Server-generated UUIDs become `00000000-0000-4000-8000-<n>`, numbered in order
  of first appearance. This includes the feed's `epoch` and `server_id`.
  Client-supplied entry ids are kept. Feed `seq`, `head` and `next` are real:
  the test database restarts its sequences.
- The VAPID public key is replaced with a fixed one, after checking its format.

Every other `*_at`, `due_since` and `start` value in a response body is
format-checked too. The server sends microseconds and drops the fraction when it
is zero. The fixtures contain both forms (for example the normalised `.123456`
timestamps, and `captured_at` and the due instants without a fraction), so
decoders must accept both.

To add an endpoint, add one `rec(...)` call to `scenario()`.

## `action-entry-id-vectors.json`

- `cases[]`: `{name, server_id, topic_id, due_since, expected}`: the id every
  client gives the entry a reminder action logs (notifications.md §7.4).
- `meta.semantics`: the exact bytes hashed. Both ids are lowercased;
  `due_since` is used exactly as the payload carries it, so the non-canonical
  cases give different ids on purpose.
