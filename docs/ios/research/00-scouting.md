# Scouting: findings from the first pass (2026-10-17)

These are condensed from two read-only scouting agents. File references are
relative to the repo root.

## Backend and API

- **API shape.** REST under `/api/v1` (`backend/app/api/routes.py`), OpenAPI 3.1
  at `openapi.json`, no `servers` block.
  - Topic `{ref}` can be a UUID or a slug.
  - List responses are `{items,total,limit,offset}` with offset pagination.
    There are no cursors, no `updated_since` filter, and no tombstones for
    deletions.
  - Errors use a Problem body `{code, detail, errors:[{loc,message}]}`. The
    codes are `invalid_request`/`invalid_answers`/`incompatible_version` (422),
    `not_found` (404), `conflict`/`topic_archived` (409) and `bad_request`
    (400).
- **Question types.** Questions are a oneOf on `type`:
  - int: min, max, unit
  - double: min, max, decimals
  - str: min/max_length, multiline
  - enum: options `{value,label,archived}`, with `multiple`, `min_selected` and
    `max_selected`
  - All questions also have `key`, `label`, `help_text` and `required`.
- **Schedules.** A schedule is a oneOf on `kind`:
  - daily: `{times, days, timezone, notify}`
  - interval: `{every_minutes 15..129600, timezone, notify}`
- **Entries.**
  - `EntryCreate`:
    `{id?, answers: map key→int|number|string|[string]|null, source?, captured_at?, notes, meta, version?}`.
  - `EntryOut`: answers come back as a **list** of `{key,type,value}` (type
    int|double|str|enum|enum_list).
  - `PATCH` merges answers into the stored ones. Sending `null` clears an
    answer. It validates against the entry's pinned version and has no ETag.
- **Channel.** The enum is `ui|api|mcp` (the Postgres enum `entry_channel`),
  sent via the `X-QuickR-Channel` header. It **has no `ios` value**. `source` is
  free text.
- **Idempotency.**
  - A client-supplied entry `id` replayed on the same topic returns the stored
    entry with 201. The body is not compared, and this still works on an
    archived topic.
  - The same id under a different topic returns 409.
  - Replaying the id of a _deleted_ entry recreates it, so the outbox must never
    replay after an undo-delete.
  - Terminal failures: 409 `topic_archived`, 404, and 422. Retryable: network
    errors and 5xx.
- **captured_at.** Must be timezone-aware, on or after 2000-01-01, and no more
  than now+24h. Queued entries must always send it.
- **Versions.** Every entry is pinned to a version. `GET /topics/{ref}/versions`
  returns every version with its questions.
  - A question's type never changes for a given key.
  - Enum options are only archived, never removed.
  - Publishing needs `base_version`; a mismatch returns 409.
- **Due logic.** Pure functions in `backend/app/services/schedule.py` (`_daily`
  :93, `_interval` :114, `compute_due` :129).
  - Daily: a slot is satisfied by any entry at or after `slot − min(2h, gap/2)`.
  - DST gap times map forward; ambiguous times use their first occurrence.
  - Slots before `schedule_updated_at` are ignored.
  - Interval: `max(last_entry, since) + every`.
  - The logic is deterministic and could be replicated on device.
- **Push today.** Web Push only, through pywebpush
  (`backend/app/services/push.py`).
  - Table
    `push_subscriptions(endpoint UNIQUE, p256dh, auth, user_agent, last_success_at, failure_count)`.
  - `send_to_all` sends to every subscription. There is no per-device targeting.
  - Scheduler (`services/scheduler.py`): a 60 s tick under a Postgres advisory
    lock, deduped per topic via `topics.last_notified_due_since`. Sends happen
    inside the transaction.
  - Payload
    `{title, body, url:"/t/{slug}/record", tag:"due-{topic id}", topic_slug}`.
  - SSRF guard is in `push_guard.py`.
  - There is no APNs dependency: no `h2`, no `aioapns`. `cryptography` and
    `pyjwt` are present transitively.
- **Swift codegen hazards.**
  - The `answers` map uses `patternProperties`/`propertyNames` without
    `additionalProperties`, so swift-openapi-generator would drop it.
  - The answer value is an `anyOf` of int/number/string/array/null with
    overlapping branches.
  - Pydantic splits schemas into `-Input`/`-Output` pairs
    (`json_schema_serialization_defaults_required=True` at
    `schemas/base.py:26`).
  - Nullable discriminated unions are expressed as `anyOf[oneOf, null]`.
  - Discriminators are written as `const`.
  - Date-times have fractional seconds, which need a custom transcoder.
- **Auth and hosting.** There is no auth in the app server. Images are published
  to `ghcr.io/<owner>/quickr-{backend,frontend}`, but there is no deploy target
  in the repo.
- **CI** (`.github/workflows/ci.yml`): ruff, format, strict mypy, OpenAPI drift
  check, `alembic check`, pytest, and the frontend checks including that the
  generated client is up to date.
  - Tests run against real Postgres (`quickr_test`), are migrated with Alembic,
    and TRUNCATE between tests.
  - The scheduler is disabled in tests; they call `tick()` directly.
- **Stats and CSV.**
  - `TopicStats` includes historic questions.
  - Series points are `{start,count,mean?,min?,max?,option_counts}`, bucketed in
    the requested `tz`.
  - CSV columns are the fixed ones, then current keys, then historic keys.
    Multi-select values are joined with `;`.

## The PWA: what parity means

- **Screens** (`frontend/src/router.tsx`):
  - Home `/`: due-first, with "Due now", "Coming up" and "Topics" sections,
    search, filter and sort, infinite scroll, and a 60 s refresh.
  - Record `/t/:ref/record`: "Same as last time", details (captured_at, source,
    notes), a sticky Save, a "Log another" toggle, and a `?fix=` mode for failed
    outbox items.
  - Entries `/t/:ref/entries`: filters, CSV, pending and failed items shown
    first.
  - Edit entry: renders the entry's own version and keeps retired options.
  - Overview/stats `/t/:ref`, Versions, Edit questions (builder, compatibility
    report, publish, conflict handling).
  - New topic, Topic settings (details, schedule editor, archive with undo,
    delete with typed confirm).
  - App settings (notifications plus test push, sync, local data).
- **Tap-count bar to meet or beat** (`frontend/docs/design-loop.md`):

  | Case                      | Taps                                       |
  | ------------------------- | ------------------------------------------ |
  | Single-enum topic         | 1 (chip on the tile)                       |
  | Single-number topic       | 1 (✓ with the last value), 2 when adjusted |
  | Four-question mixed topic | 4 + typing                                 |
  | Same as last time         | 3                                          |
  | From a notification       | 2                                          |
  | Undo                      | 1                                          |
  | Offline                   | 1                                          |

- **Quick-log tiles.** A topic gets inline quick-log only when it has exactly
  one _required_ question:
  - A single-select enum with 1–6 active options shows chips.
  - An int or double shows a −/value/+ stepper with ✓, starting from the last
    valid value or `min≥0`.
- **Toasts.** Undo toasts last 6 s; there are no confirmation dialogs in any
  logging flow.
- **Record screen behaviour.**
  - A topic with only one single-select question auto-saves when a chip is
    tapped.
  - Focus and keyboard rules: focus goes to the first unanswered field, chips
    are never focused, choosing a chip moves focus to the next empty field, and
    Enter goes to the next field.
- **Question widgets.**
  - int/double: a large mono field with 52 px ± buttons, clamped, with the unit
    shown.
  - str: an input or a textarea.
  - Single enum: chips when there are 6 or fewer options, otherwise a picker.
  - Multi enum: checkbox chips with "pick 1–3" style rules, and dimmed chips
    once the maximum is reached.
- **Offline UX.**
  - Outbox items are pending or failed. Retries back off 2 s·2ⁿ, capped at 5
    min.
  - A sync pill shows "Offline", "N waiting to sync" or "N failed". The sync
    sheet offers retry, fix and discard.
  - Updates are optimistic, and due state is cleared when the entry satisfies
    the current slot.
  - The app badge shows the due count.
- **Charts.** Hand-rolled SVG (in Swift this becomes Swift Charts):
  - numeric: mean, the stats grid, a histogram, and a mean line with a min–max
    band
  - enum: option bars and stacked bars over time
  - text: the most common values and recent answers
- **Brand** (`frontend/src/index.css`): "field notebook" theme with a dot-grid
  background.
  - Light: paper `#f3efe6`, surface `#fffdf8`, ink `#1b1915`, accent `#e8590c`.
  - Dark: paper `#141210`, accent `#ff7a2e`.
  - Plus ok/warn/danger/info colours and their soft variants, and six series
    colours.
  - Corner radius 18 px on cards. Tap targets are at least 44 px, chips at least
    52 px.
  - Icons are 30 hand-drawn stroke icons.
  - The app icon source is `frontend/public/favicon.svg`.
- **Size.** About 13k lines of non-generated TypeScript. 13 test files with
  about 128 cases.
