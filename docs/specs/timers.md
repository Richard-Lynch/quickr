# Spec: timed topics (runs, steps, laps and Live Activities)

**Status:** draft, revision 5, 2026-10-23 (server-time offset for run events). **Applies to:** the backend, the PWA,
the iOS app (app, widgets, Live Activity, intents, notifications) and the MCP
server. **Companion specs:** [sync-protocol.md](../ios/specs/sync-protocol.md),
[outbox.md](../ios/specs/outbox.md) and
[notifications.md](../ios/specs/notifications.md). This spec extends them; where
it doesn't say otherwise, their rules hold unchanged. **No compatibility with
older builds** (§12). **Plan:** [timers-plan.md](timers-plan.md).

## Purpose

The user's request, in short: a "timer" log that starts on one tap, stops on a
second, and can have checkpoints in between. The simple case is timing how long
it takes to empty the dishwasher. The complex case is timing each step of a
morning routine as one session.

These decisions were made by the user and are not reopened here:

- A topic can be **timed**. It has optional **named steps**, versioned like
  questions. During a run the user can **skip** a step and add unnamed **laps**.
- **Start → Next / Lap → Stop.** Stop saves the run as an entry with its start,
  end, total and per-segment times. The topic's questions, if any, are answered
  at Stop.
- A run is **stored on the server**, so it can be started on one surface and
  advanced or stopped on another. It is still **offline-tolerant**: each tap is
  timestamped on the device when it happens and synced later through the outbox.
- **One open run per topic.**
- Version 1 includes the iOS and PWA UI, a Live Activity with Next and Stop
  buttons, the Action button, widgets, Siri and Shortcuts, pause and resume,
  editing a past run's times, stats and MCP tools.
- Reminders apply to timed topics. The notification has a **Start** action that
  starts the run and the Live Activity.
- Timestamps are stored to the second or better. Durations are shown as m:ss.

**Normative language.** **MUST**, **MUST NOT**, **SHOULD** and **MAY** follow
RFC 2119. **[server]** marks a backend requirement, **[ios]** an iOS one and
**[pwa]** a PWA one. **OPEN** marks a question for the user, with a
recommendation; the spec assumes the recommendation until it is answered.

## Glossary

| Term              | Meaning                                                                                                                                                                        |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Timed topic**   | A topic whose **current version** has a non-null `timer` (§2.1).                                                                                                               |
| **Step**          | A named checkpoint defined in a version's `timer.steps`: `{key, label}`. Steps are timed in the order they are defined.                                                        |
| **Run**           | One timing session of a timed topic. It is a server entity with its own id, created by a `start` event, and it becomes an **entry with the same id** when it is finished (§1). |
| **Event**         | One tap: `start`, `next`, `lap`, `skip`, `pause`, `resume`, `stop`, `finish` or `discard`. Each has a client-generated UUID and a device timestamp `at` (§3).                  |
| **Segment**       | The time between two marks. A segment is either a **step segment** (it times one named step) or a **lap segment** (unnamed).                                                   |
| **Open segment**  | The segment that is currently being timed. Its **index** (`seg`) is the number of segments closed before it, starting at 0.                                                    |
| **Open run**      | A run whose status is `running` or `paused`. At most one per topic.                                                                                                            |
| **Finishing**     | A run whose clock has stopped but whose required answers are still missing (§3.6). It is not an open run, and not yet an entry.                                                |
| **Closed run**    | A run whose status is `stopped` (it has an entry) or `discarded`.                                                                                                              |
| **Fold**          | The pure function from a run's events to its state and timing (§4). Python is the reference; Swift and TypeScript ports are checked by shared vectors.                         |
| **Active time**   | Wall time minus paused time. Every duration in stats is active time unless it says otherwise.                                                                                  |
| **Alias**         | A run id that was merged into another open run of the same topic (§4.5). Events sent to an alias apply to its target.                                                          |
| **Timing**        | The `timing` object on a timed entry (§2.3): start, end, segments, skipped steps and pauses.                                                                                   |
| **Untimed entry** | An entry of a timed topic with `timing = null`. `createEntry` (and MCP `record_entry`) make these.                                                                             |

## 1. The model, and why

### 1.1 Decision: a separate run that becomes an entry at Stop

A run is its **own server entity** while it is open. Its events are stored as
they arrive. When it is stopped (and its required answers are given), the server
creates an **entry whose id is the run's id**, with the answers and a `timing`
projection. The run row stays on the server as the record of its events.

The alternative was an entry with a nullable `ended_at`. It was rejected:

| Concern                 | Separate run (chosen)                                                                             | Entry with nullable `ended_at`                                                                                                 |
| ----------------------- | ------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| Every reader of entries | Open runs aren't entries, so entry lists, CSV, stats and due state never see half-finished work.  | Every reader (PWA, iOS, MCP, CSV) must learn to hide or special-case an entry without an end.                                  |
| Due state and reminders | An entry exists only once the run is finished, so due state and the scheduler keep their meaning. | `captured_at` would be the start, and an open run would satisfy a reminder before the work is done.                            |
| Stats, CSV, entry lists | Unchanged: they read entries.                                                                     | Every query needs an "only finished" filter, and every client must learn it.                                                   |
| Offline merging         | Events are idempotent and folded deterministically (§4), so taps from two devices merge.          | Concurrent PATCHes of one entry are last-writer-wins (outbox.md §7.4). A Next on one device would overwrite a Next on another. |
| Required answers        | A run can wait in `finishing` until the answers come (§3.6).                                      | An entry missing required answers would be an invalid entry.                                                                   |

**One id space.** A run id is reserved in the entry id space, and an entry id in
the run id space. `createEntry` with the id of a run answers 409 `id_conflict`,
and so does a `start` with the id of an entry. Deletions reserve ids for good,
as for entries (sync-protocol.md F3).

### 1.2 What lives where

| Data                                      | Stored in                                  | In the change feed as |
| ----------------------------------------- | ------------------------------------------ | --------------------- |
| Whether a topic is timed, and its steps   | `topic_versions.timer` (§2.1)              | `version` items       |
| An open or finishing run, with its events | `runs`, `run_events`, `run_aliases` (§2.2) | `run` items (§7.1)    |
| A finished run's times                    | `entries.timing` (§2.3), plus the run row  | `entry` items         |
| A finished run's answers                  | `answers`, as for any entry                | `entry` items         |
| Live Activity push tokens                 | `live_activity_tokens` (§10.3)             | No                    |

## 2. Data model and migration **[server]**

One Alembic migration, `20261024_…_timed_topics.py`. Every change is additive.

### 2.1 `topic_versions.timer`

```sql
ALTER TABLE topic_versions ADD COLUMN timer JSONB NULL;   -- null: not timed
```

```
Timer = { steps: Step[] }                       // steps may be empty: a plain stopwatch
Step  = { key: QuestionKey, label: Label }      // same key regex and label limit as questions
```

- A topic is timed when its **current** version's `timer` is non-null. Timing is
  versioned like questions: publishing a version can add, rename, reorder or
  remove steps, or turn timing on or off.
- **Keys** follow the question key rule (`^[a-z][a-z0-9_]{0,62}$`). They are
  unique among the version's steps. They live in their own namespace, so a step
  and a question may share a key. A step keeps its key across versions when it
  is renamed, so stats join across versions by key (§9).
- A run is **pinned to the version it started on**. Publishing during a run
  doesn't change the running run.
- **`timer` is required in `publishTopicVersion`**: the new version's timer, or
  `null` for an untimed topic. Required, so no caller (the PWA, iOS, the MCP
  tool) can switch timing off by leaving it out. In `createTopic` it is optional
  and defaults to `null`.
- `TopicVersionOut` gains `timer: Timer | null`. `checkTopicVersion` ignores
  `timer`: past runs keep their own steps, so a step change never blocks a
  publish. It takes an optional `timer`, and with one a timer-only change is not
  "no changes" (as in publish).

### 2.2 Runs

```sql
CREATE TYPE run_status AS ENUM ('running', 'paused', 'finishing', 'stopped', 'discarded');
CREATE TYPE run_event_type AS ENUM ('start','next','lap','skip','pause','resume','stop','finish','discard');

CREATE TABLE runs (
  id                UUID PRIMARY KEY,                      -- client-generated; == start event id; == entry id later
  topic_id          UUID NOT NULL REFERENCES topics(id) ON DELETE CASCADE,
  topic_version_id  UUID NOT NULL REFERENCES topic_versions(id) ON DELETE CASCADE,
  version           INTEGER NOT NULL,
  status            run_status NOT NULL,
  started_at        TIMESTAMPTZ NOT NULL,
  ended_at          TIMESTAMPTZ NULL,                      -- set by stop
  edited            BOOLEAN NOT NULL DEFAULT false,        -- timing edited after stop (§3.8)
  entry_id          UUID NULL,                             -- == id once the entry exists; null again if it is deleted
  state             JSONB NOT NULL,                        -- the fold's output (§4), cached
  source            VARCHAR(100) NOT NULL,                 -- from the start event
  channel           entry_channel NOT NULL,
  revision          INTEGER NOT NULL DEFAULT 1,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX ux_runs_one_open ON runs(topic_id) WHERE status IN ('running', 'paused');

CREATE TABLE run_events (
  id          UUID PRIMARY KEY,                            -- client-generated, idempotency key
  run_id      UUID NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
  arrival     BIGSERIAL NOT NULL,                          -- server arrival order (§4.1)
  type        run_event_type NOT NULL,
  at          TIMESTAMPTZ NOT NULL,                        -- device time of the tap
  seg         INTEGER NULL,                                -- next, lap, skip (§3.2)
  step        VARCHAR(64) NULL,                            -- skip: the step being skipped (required)
  pause_id    UUID NULL,                                   -- resume: the pause event it ends (required)
  payload     JSONB NOT NULL DEFAULT '{}',                 -- stop/finish: answers, notes, meta; start: version
  source      VARCHAR(100) NOT NULL,
  received_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_run_events_run ON run_events(run_id, arrival);

CREATE TABLE run_aliases (
  id      UUID PRIMARY KEY,                                -- the losing start's run id (§4.5)
  run_id  UUID NOT NULL REFERENCES runs(id) ON DELETE CASCADE
);
```

- An event's **effect** (applied or void, §4) is not stored: it is part of the
  fold's output, because a later arrival can change it.
- `revision` starts at 1 and increases by 1 with every change to the run: each
  new event (applied or void) and each status change. It follows
  sync-protocol.md F4.
- **Topic deletion** adds every run id and alias id of the topic to
  `deleted_ids` (kind `run`) **before** the cascade, as F3 requires for entries.

### 2.3 `entries.timing`

```sql
ALTER TABLE entries ADD COLUMN timing JSONB NULL;          -- null: untimed entry
```

```
Timing = {
  started_at:  datetime,
  ended_at:    datetime,              // == entry.captured_at (invariant T1)
  active_ms:   int,                   // ended − started − paused_ms
  paused_ms:   int,
  complete:    bool,                  // no steps, or every step has a segment and none skipped (§9.1)
  edited:      bool,
  segments:    Segment[],             // in time order
  skipped:     StepKey[],             // in step order
  pauses:      { start: datetime, end: datetime }[]
}
Segment = { kind: "step" | "lap", step: StepKey | null, label: string,
            started_at: datetime, ended_at: datetime, active_ms: int, paused_ms: int }
```

- `label` is a snapshot: the step's label in the run's version, or "Lap _n_"
  (numbered among the run's lap segments). Clients may relabel step segments
  with the latest version's label for display, matching by key.
- **Invariants**, checked on every write: **T1**
  `captured_at = timing.ended_at`; **T2** segments are contiguous: the first
  starts at `started_at`, each starts where the previous ended, and the last
  ends at `ended_at`; **T3** pauses are sorted, don't overlap, and lie within
  `[started_at, ended_at]`; **T4** each step key appears at most once across
  `segments` and `skipped`; **T5** `active_ms` and `paused_ms` add up over
  segments. Pauses stay whole; each segment's `paused_ms` is its overlap with
  them.
- **Every instant is a whole millisecond.** The server truncates each event's
  `at` (and every edited instant) to milliseconds when it stores it, and clients
  truncate before they enqueue. Durations are then exact integer differences,
  so T5 holds exactly (no per-segment rounding). The Swift and TypeScript fold
  ports parse wire strings to integer epoch milliseconds and never go through
  `Date` or a floating-point value (§13.1).
- `EntryOut` gains `timing: Timing | null`. `channel` and `source` come from the
  run's start event.

### 2.4 The change log

- `feed_kind` gains the value `run` (`ALTER TYPE feed_kind ADD VALUE 'run'`).
- A run upsert logs `(kind run, op upsert)` when it is created and on every
  change while it is open or finishing.
- When a run **closes** (stopped or discarded) the server logs
  `(kind run, op delete)` and inserts the run id into `deleted_ids`. In the
  feed, "deleted" means "no longer open". A stopped run's data arrives as its
  entry. Late events are still accepted after the close (§4.4) and change the
  **entry**, never the run item.
- Stopping logs the new entry `(kind entry, op upsert)` before the run's delete,
  in the same transaction. The feed's emission rule that makes this visible to
  clients is in §7.1.

## 3. API **[server]**

Every mutation below accepts the F10 precondition headers and answers with the
F9 identity headers (sync-protocol.md §1.3). Date-times use the wire profile of
sync-protocol.md §1.5.

### 3.1 Endpoints

| operationId              | Method and path                                  | Purpose                                                                 |
| ------------------------ | ------------------------------------------------ | ----------------------------------------------------------------------- |
| `recordRunEvent`         | `POST /api/v1/runs/{run_id}/events`              | Every tap: start, next, lap, skip, pause, resume, stop, finish, discard |
| `getRun`                 | `GET /api/v1/runs/{run_id}`                      | One run, in any status, with its events and effects. An alias resolves. |
| `listRuns`               | `GET /api/v1/runs?status=open\|finishing&topic=` | Open and finishing runs (the PWA's source of runs)                      |
| `listChanges` (changed)  | `GET /api/v1/changes`                            | Gains the `run` item and deletion kinds (§7.1). **Breaking.**           |
| `getTopicTiming`         | `GET /api/v1/topics/{ref}/timing?from=&to=`      | Timing stats (§9)                                                       |
| `updateEntry` (extended) | `PATCH /api/v1/entries/{id}`                     | Gains an optional `timing` field: edit a past run's times (§3.8)        |
| `registerLiveActivity`   | `POST /api/v1/push/apns/live-activities`         | Register a push-to-start token or an activity's update token (§10.3)    |
| `deleteLiveActivity`     | `POST /api/v1/push/apns/live-activities/delete`  | Unregister one                                                          |

### 3.2 `recordRunEvent`

Request:

```
RunEventIn {
  id:      UUID                  // the event id, client-generated; for start it MUST equal {run_id}
  type:    "start" | "next" | "lap" | "skip" | "pause" | "resume" | "stop" | "finish" | "discard"
  at:      datetime              // the tap, on the server's clock as the device estimates it (§5.1)
  seg:     int ≥ 0 | null        // required for next, lap and skip; the open segment the device saw
  step:    StepKey | null        // required for skip: the step the device saw as being skipped
  pause_id: UUID | null          // required for resume: the id of the pause event it ends
  topic_id: UUID | null          // start only, required
  version: int | null            // start only, required
  answers: Answers | null        // stop and finish only (§3.6)
  notes:   string | null         // stop and finish only
  meta:    {string: string} | null
  source:  string | null         // as for EntryCreate; defaults by channel
  device:  { apns_token: hex, live_activity: bool } | null   // every event from iOS (§10.3)
}
```

Response, `200` (or `201` when the call created the run):

```
RunEventResult {
  event:  { id, effect: "applied" | "void", reason: VoidReason | null }
  run:    RunOut                 // the target run (it differs from {run_id} after a merge)
  entry:  EntryOut | null        // when the run is stopped and its entry exists
}

RunOut {
  id, topic_id, version, status, revision,
  started_at, ended_at | null, edited,
  events: { id, type, at, seg, step, arrival, effect, reason, source }[]   // in arrival order
  state:  RunState               // the fold's output (§4.3)
  aliases: UUID[]
}
```

- **Idempotent by event id.** A replay with the same id and the same content
  returns the current `RunEventResult` with `200`. The same id with different
  content (type, `at`, `seg`, `step`, `pause_id`, `topic_id`) answers 409
  `event_conflict`. `at` is compared after truncation to milliseconds (§2.3).
- **Void is not an error.** An event that the fold voids (a double tap, a lap
  after Stop, §4.2) is stored and answered with `200` and `effect: "void"`.
  Clients ack it like any success.
- **The path id may be an alias** (§4.5). The event is applied to the target,
  and the response's `run.id` is the target's id.

### 3.3 Start

A `start` with run id R for topic T:

| Situation                                                    | Result                                                                                                    |
| ------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------- |
| R is a known run or alias                                    | Replay (§3.2)                                                                                             |
| R is in `deleted_ids` as a run                               | 409 `run_deleted`                                                                                         |
| R is the id of an entry                                      | 409 `id_conflict` (new code, §3.9)                                                                        |
| T doesn't exist                                              | 404                                                                                                       |
| T is archived                                                | 409 `topic_archived`                                                                                      |
| Version `version` of T doesn't exist, or its `timer` is null | 409 `topic_not_timed`                                                                                     |
| T has an open run R1                                         | **Merge:** R becomes an alias of R1 (§4.5). `201`, `effect: "void"`, `reason: "merged"`, and `run` is R1. |
| Otherwise                                                    | Create R: status `running`, `started_at = at`, pinned to `version`. `201`, `effect: "applied"`.           |

### 3.4 Next, lap, skip, pause and resume

These are applied through the fold (§4). The request is rejected only for these
reasons:

| Situation                                                                      | Response                  |
| ------------------------------------------------------------------------------ | ------------------------- |
| The run (or alias) doesn't exist                                               | 404                       |
| The run id is in `deleted_ids` and the run row is gone (topic deleted)         | 409 `run_deleted`         |
| `seg` is missing for next, lap or skip; `step` for skip; `pause_id` for resume | 422                       |
| The run already has 1,000 events                                               | 422 `run_too_many_events` |
| `at` fails the time bounds (§5)                                                | 422                       |

Anything else is stored and folded, even when the run is closed: the fold
decides whether it applies (§4.4).

### 3.5 Stop

Stop ends the clock at `at`. It is terminal (§4.1). A stop with `at` before the
run's `started_at` answers 422 `before_start` and is not stored: it would make a
negative segment. Otherwise:

| Answers in the request | The version's questions        | Result                                                                                                                          |
| ---------------------- | ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------- |
| Present                | Any                            | Validated as `createEntry` validates them (422 `invalid_answers` on failure, and nothing is stored). Then the entry is created. |
| Absent                 | No required question           | The entry is created with `answers: {}`.                                                                                        |
| Absent                 | At least one required question | The run becomes **`finishing`**. No entry yet.                                                                                  |

Creating the entry: `id = run.id`, `version = run.version`,
`captured_at = ended_at`, `timing` from the fold, `source` and `channel` from
the start event, `notes` and `meta` from the stop. It is checked as a
`createEntry` would be, **except that an archived topic doesn't block it**: the
run began before the archive, and refusing would lose the timing. The run
becomes `stopped`, with `entry_id = id`. Both are logged (§2.4).

A **second stop** that carries answers (another device stopped first) is not
lost: its answers are applied as a `finish` (§3.6). A second stop without
answers is void (`already_closed`).

### 3.6 Finish

`finish` carries the run's answers (and notes). It is valid in two states:

| Run status                            | Effect                                                                                                                                                                                                |
| ------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `finishing`                           | The answers are validated against the run's version, required questions enforced (422 on failure, nothing stored). The entry is created as in §3.5; the run becomes `stopped`.                        |
| `stopped`                             | The answers and notes are applied to the existing entry as a PATCH would apply them (answers merge by key), validated with required questions enforced on the result. The entry's revision increases. |
| `discarded`, or the entry was deleted | Void (`already_closed` or `entry_deleted`)                                                                                                                                                            |
| `running` or `paused`                 | 409 `run_open`, nothing stored: the client keeps the answers and sends them again once its stop is in                                                                                                 |

**Why it works this way.** The Live Activity, widgets, the Action button and
Siri can't ask questions, but their Stop must end the clock at the tap. So
**every client sends `stop` at the tap, without answers, and every form sends
its answers as `finish`**, whether the stop made an entry (no required
questions) or left the run `finishing`. There is one path for answers, and it
is a run event, so it needs no cross-kind outbox ordering (§8.1). A finishing
run shows as "Add details" on every client (§11).

### 3.7 Discard

`discard` throws an open or **finishing** run away. The run becomes
`discarded`, and it is logged as a delete (§2.4). A finishing run's stop is
already its terminal event, so the fold would void a later discard: the server
handles a discard of a finishing run outside the fold, as it handles `finish`,
and records the event as applied. A discard of a stopped run is void
(`already_closed`): delete its entry instead.

### 3.8 Editing a past run's times

`PATCH /entries/{id}` (`EntryUpdate`) gains an optional field:

```
TimingEdit = {
  started_at: datetime,
  segments:   { kind: "step" | "lap", step: StepKey | null, ended_at: datetime }[],   // in order
  skipped:    StepKey[],
  pauses:     { start: datetime, end: datetime }[]
}
```

- The server rebuilds the full `Timing` from the edit. The last segment's
  `ended_at` is the run's `ended_at`, and `captured_at` is set to it (T1). The
  result must satisfy T2–T5. Segments must have non-negative length, step keys
  must belong to the run's version, and the run must be at most 7 days long. A
  failure answers 422 with a field path.
- `expected_revision` is required with `timing`, as with every PATCH (outbox.md
  §7.3).
- The edit sets `timing.edited = true` and `runs.edited = true`. From then on,
  late events for that run are void (`run_edited`, §4.4).
- `timing` together with `captured_at` in one request answers 422.
- `captured_at` without `timing` on a timed entry answers 422 ("edit the run's
  times instead"): `captured_at` is derived from `timing` (T1).
- `timing: null` on a timed entry answers 422. Turning a timed entry into an
  untimed one is not supported.
- Only stopped runs can be edited. An open run's times are corrected by stopping
  it and editing the entry.

### 3.9 Problem codes (new)

| Status | Code                  | When                                                                                                                                                                                      |
| ------ | --------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 409    | `topic_not_timed`     | `start` against a version without a `timer`                                                                                                                                               |
| 409    | `id_conflict`         | `start` with an entry's id; `createEntry` with the id of an open or finishing run or of an alias. (`createEntry` with a stopped run's id is the existing idempotent replay of its entry.) |
| 422    | `before_start`        | A stop with `at` before the run's `started_at` (§3.5)                                                                                                                                     |
| 409    | `event_conflict`      | An event id was reused with different content                                                                                                                                             |
| 409    | `run_open`            | A `finish` on a run that hasn't stopped yet (§3.6); nothing is stored                                                                                                                     |
| 409    | `run_deleted`         | The run's topic was deleted                                                                                                                                                               |
| 422    | `run_too_long`        | A stop or edit that would make the run longer than 7 days (§5)                                                                                                                            |
| 422    | `run_too_many_events` | Over 1,000 events                                                                                                                                                                         |

`conflict`, `topic_archived`, `invalid_answers` and `invalid_request` keep their
meaning (`backend/app/errors.py`).

## 4. The fold (state machine)

### 4.1 Inputs and the two orders

The fold takes the run's version steps and its events **in arrival order**. It
uses two orders on purpose:

- **Arrival order** decides only **terminal** events. The first `stop` or
  `discard` to arrive closes the run. A later-arriving `stop` or `discard` is
  void (`already_closed`), whatever its `at`. Closing creates or drops an entry,
  so it must never be undone by a replay.
- **Time order** decides everything else. Non-terminal events are replayed by
  `(at, id)`, ascending, with ids compared as lowercase strings, except that a
  resume with the same `at` as the pause it names is ordered right after that
  pause. A tap made offline at 08:05 that arrives at 08:20 lands at 08:05.

Arrival order on the server is `run_events.arrival`. A client folding its local
view uses the server's events in their arrival order, then its own queued events
in outbox `seq` order (§8.3).

### 4.2 Replay

```
fold(steps, events_in_arrival_order):
  seen = {}; terminal = null; accepted = []
  for e in events_in_arrival_order:                       // pass 1: arrival
    if e.id in seen: continue                             // idempotent
    seen += e.id
    if e.type == start:
      if e.id == run.id: start = e else void(e, merged)  // a merged start (§4.5)
      continue
    if e.type in {stop, discard}:
      if terminal: void(e, already_closed) else terminal = e
      continue
    if e.type == finish: continue                         // the server decides it (§3.6)
    accepted += e

  st = { open: Seg(label = pop(pending = steps), start = start.at, index = 0),
         paused_since: null, segments: [], skipped: [], pauses: [] }
  end = terminal ? terminal.at : +∞
  for e in sort(accepted, by (at, id)):                   // pass 2: time; a resume at its pause's `at` right after it
    if e.at < start.at:  void(e, before_start); continue
    if e.at > end:       void(e, after_stop);   continue  // also covers a terminal that arrived first
    if e.at > start.at + 7 days: void(e, too_long); continue   // §5
    case e.type:
      next, lap:
        if e.seg != st.open.index: void(e, stale); continue
        close(st.open, e.at)                              // pushes it to segments; paused_ms = overlap with pauses
        st.open = Seg(label = e.type == next ? pop(pending) : lap, start = e.at, index + 1)
      skip:
        if e.seg != st.open.index: void(e, stale); continue
        if st.open.label is a step s:
          if e.step != s: void(e, stale); continue
          st.skipped += s; st.open.label = pop(pending)   // relabel: no time is lost or created
        else:
          if pending is empty: void(e, no_step); continue
          if e.step != head(pending): void(e, stale); continue
          st.skipped += pop(pending)
      pause:  if st.paused_since: void(e, already_paused) else st.paused_since = e.at; st.pause_id = e.id
      resume: if !st.paused_since: void(e, not_paused); continue
              if e.pause_id != st.pause_id: void(e, stale); continue    // a resume of an older pause
              st.pauses += [paused_since, e.at); paused_since = null
  if terminal:
    if terminal.type == stop:
      if paused_since: st.pauses += [paused_since, terminal.at)
      close(st.open, terminal.at); status = stopped (or finishing, §3.5)
    else: status = discarded
  else: status = paused_since ? paused : running
  pop(empty pending) = lap                                 // after the last step, segments are laps
```

- **Void reasons** (`VoidReason`): `merged`, `already_closed`, `run_edited`,
  `entry_deleted`, `before_start`, `after_stop`, `too_long`, `stale`,
  `no_step`, `already_paused` and `not_paused`. The server decides
  `run_edited` and `entry_deleted` outside the fold (§4.4), and `finish` and a
  finishing run's `discard` (§3.6, §3.7).
- **An edited run is never folded again.** Its timing is the edit (§3.8). An
  event that arrives after the edit is stored as void (`run_edited`) and the
  run's state and entry are left as they are; events that arrived before the
  edit keep their recorded effects. A `finish`, or a `stop` with answers, still
  applies its answers (§4.4).
- **Skip names its step and resume names its pause**, so a double-tapped skip
  can't skip two steps, and an offline resume of an earlier pause can't end a
  later one (both `stale`).
- **Next after the last step** opens a lap segment. Clients don't offer Next
  there: they offer Lap and Stop (§10, §11). The rule only makes stray taps
  well-defined.
- **Skip relabels the open segment.** If the user is on "Shower" and skips it,
  the time since the last mark becomes "Breakfast" time. That matches what
  happened: they moved on. Skip never closes a segment, so it doesn't change
  `seg`.
- **Taps while paused are allowed.** Next while paused closes the segment at the
  tap, and the new segment starts paused. Durations are always wall time minus
  the overlap with pauses, so no case needs special handling.
- **Stop while paused** ends the pause at the stop.
- **A stop before the start, or more than 7 days after it, is not a
  terminal.** It is void (`before_start`, `too_long`) whenever it arrives, as
  the server refuses it (§3.5, §5).
- **`stale` makes double taps safe.** Two devices that both saw segment 3 and
  both tapped Next produce one advance: the earlier tap by time applies, and the
  later is void. An offline device that tapped through several steps applies
  each of its taps that still matches the segment it targeted, in time order.

### 4.3 Output

```
RunState {
  status, open: { index, kind, step, label, started_at } | null,
  next_step: StepKey | null,               // head of pending
  paused_since: datetime | null,
  segments: Segment[], skipped: StepKey[], pauses: Pause[],    // closed so far
  effects: { event_id: { effect, reason } }
}
```

For a stopped run, `segments`, `skipped` and `pauses` are exactly the entry's
`timing` (§2.3), and `ended_at` is the terminal's `at`.

### 4.4 Events after the run closes (late merges)

A run is often closed on one device while another still has queued taps. The
rules:

| Late event (arrives after the close)                                                                                                           | Effect                                                                                                                                                                           |
| ---------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `next`, `lap`, `skip`, `pause`, `resume` with `at ≤ ended_at`, run stopped and not edited, entry not deleted                                   | **Merged.** The fold runs again with it. The entry's `timing` is replaced, `captured_at` stays `ended_at`, and the entry's revision increases (it is logged as an entry upsert). |
| The same, with `at > ended_at`                                                                                                                 | Void, `after_stop`                                                                                                                                                               |
| Any event arriving after an **edit**, except `finish` and a `stop` with answers (they carry answers, not times, and apply as a `finish`, §3.6) | Void, `run_edited`, with no refold. The user's edit wins.                                                                                                                        |
| Any event on a run whose entry was **deleted**                                                                                                 | Void, `entry_deleted`                                                                                                                                                            |
| Any event on a **discarded** run                                                                                                               | Void, `already_closed`                                                                                                                                                           |
| Any event on a `finishing` run with `at ≤ ended_at`                                                                                            | Merged into the run (no entry yet)                                                                                                                                               |
| `stop` without answers                                                                                                                         | Void, `already_closed`. With answers: applied as a `finish` (§3.5).                                                                                                              |
| `discard` on a `finishing` run                                                                                                                 | Applied: the run is discarded (§3.7)                                                                                                                                             |
| `discard` on a stopped run                                                                                                                     | Void, `already_closed`                                                                                                                                                           |

A merge can turn an earlier applied event void (for example, a late Next at
08:04 makes the 08:05 Next stale). The fold is re-run from all events, so this
is deterministic. Responses always carry every event's current effect.

### 4.5 Two starts for one topic (merging)

There is one open run per topic. When a `start` arrives for a topic that already
has an open run R1 (two devices started offline, or the reminder's Start was
tapped after a start from the app):

1. The new id R2 becomes an **alias** of R1 (`run_aliases`). R2's start is
   recorded on R1 as a void event with reason `merged`. **R1's start time is
   kept**, even when R2's `at` is earlier.
2. Every later event sent to R2 is applied to R1 as if it had been sent there.
   R2's queued taps therefore merge into R1 by the rules above.
3. R2 is reserved: it can't be used as an entry or run id again. `getRun(R2)`
   returns R1.

**A device never makes its own duplicate.** A client whose own view already
shows an open run for the topic doesn't enqueue a start: the tap routes to the
existing run. Aliases therefore only arise between devices.

A start that arrives when the topic has **no open run** creates a new run, even
if its `at` falls inside a run that has since closed. That can leave two
overlapping entries. It needs two devices to time the same session while one of
them is offline the whole time, which is rare, and either entry can be deleted.

## 5. Validation and limits **[server]**

| Rule                         | Limit                                                                                                                                                                                                     |
| ---------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Steps per version            | 0–30. Keys unique; key and label rules as for questions.                                                                                                                                                  |
| `at` bounds (every event)    | `2000-01-01 ≤ at ≤ server_now + 24 h`, the `captured_at` rule (sync-protocol.md §10). Otherwise 422.                                                                                                      |
| Start `at`                   | Additionally `at ≥ server_now − 7 days`                                                                                                                                                                   |
| Run length                   | At most 7 days from `started_at`. A stop later than that answers 422 `run_too_long`; the run must be discarded or the stop sent with an earlier `at`. Other events later than that are void (`too_long`). |
| Events per run               | 1,000, including void events                                                                                                                                                                              |
| Open runs per topic          | 1 (`running` or `paused`), enforced by the partial unique index as well as by the merge rule                                                                                                              |
| Answers, notes, meta, source | As for `createEntry`                                                                                                                                                                                      |
| Timing edit                  | §3.8; the same length limit                                                                                                                                                                               |

**Precision.** Instants are whole milliseconds (§2.3), stored as `timestamptz`.
Durations are integer milliseconds. A stop before the start is refused
(§3.5).

### 5.1 Run-event time: server clock, monotonic per device

1. **Server time on every response [server].** Every `/api/v1` response, errors
   included, carries `X-QuickR-Server-Time`: the server's current time in Unix
   epoch **milliseconds** (an integer). The HTTP `Date` header has whole-second
   resolution, so it isn't used.
2. **One offset per client [ios] [pwa].** A client keeps
   `offset_ms = server_time − (t_send + t_recv) / 2` from the **latest**
   response whose round trip took at most 5 s (the simpler option: no median, no
   smoothing). iOS stores it per store in `sync_state.server_offset_ms`, any
   process may update it; the PWA keeps it in memory and `localStorage`. Before
   the first sample it is 0.
3. **Stamping.** Every run event's `at` is `device_now + offset_ms`, truncated to
   whole milliseconds (§2.3). Online, that is effectively server time; offline,
   it uses the last known offset.
4. **Monotonic per device.** A client never enqueues an event for a run with an
   `at` at or before the latest `at` among that run's events in its local view
   (its own queued ones and the server's); it clamps up to that latest `at` + 1 ms
   (`max(at, latest + 1)`, on iOS and the PWA alike). Strictly after, because an
   equal `at` would let the fold's id tie-break (§4.1) reorder the device's own
   taps. A device's own segments are therefore always ordered, even if the offset
   or the device clock jumps.
5. **Defensive checks stay.** The server keeps 422 `before_start` (§3.5) and the
   fold's `before_start`, `after_stop` and `stale` voids. With 1–4 they should
   be practically impossible from one device; they remain so a bad clock or
   client can never write a negative segment.
6. **Residual case, accepted.** Two devices both offline, each tapping the same
   run with its own last offset, can still interleave slightly wrongly. The fold
   (§4) already makes that deterministic; there is no new machinery.

`captured_at` of ordinary entries is unchanged (device time, sync-protocol.md
§10).

## 6. Concurrency and idempotency **[server]**

- Every `recordRunEvent` runs inside the feed writer (`services/feed.py`
  `writer`), which serialises all writes. Two devices' taps on one run therefore
  never interleave inside a transaction.
- The transaction: resolve an alias; insert the event if its id is new (or
  compare it, §3.2); load all events; fold; update `runs` (status, state,
  `ended_at`, revision); create or update the entry; write change-log rows;
  commit. Push work (§10.3) never runs in this transaction: it is a background
  task started after the response is sent, which reads the run's latest state
  and does its token bookkeeping in its own short transaction. A tap's flush
  budget (4 s, outbox.md §10) therefore never waits on APNs.
- A run is folded from scratch on every event. The cap of 1,000 events keeps
  that cheap.
- The client-generated event id is the idempotency key, as the entry id is for
  `createEntry`. The run id is the start event's id, so a start is idempotent
  too. A reminder's Start uses an id derived from the slot (§10.1), so the same
  reminder started on two devices starts one run.

## 7. Sync

### 7.1 The feed **[server]**

`listChanges` gains, with the same F1–F11 contract (sync-protocol.md §1.3):

- an item kind `{ kind: "run", seq, run: RunOut }` for runs that are open or
  finishing in the page's snapshot;
- a deletion kind `run` for runs that closed or were deleted.

Bootstrap pages (`after = 0`) carry only open and finishing runs as items.
Closed runs reach clients as entries. A bootstrap also emits a `run` deletion
for every closed run ever (F3); for one user that is a small list, and it is
accepted.

**Emission rule for runs.** `services/changes.py` emits a vanished entity as a
deletion at its latest seq on the page. A run that closed after the page's
first row of it would then be deleted on this page while its entry's row is on
the next. So: **a closed run is emitted as a deletion only when its own delete
row is on the page; otherwise it is skipped**, as F2 skips entities whose delete
comes later. The entry's row precedes the run's delete row (§2.4), so a page
that deletes a stopped run always also carries its entry, or an earlier page
did.

Builds from before this milestone fail a page on the new kinds. No
compatibility is kept (§12).

### 7.2 iOS store **[ios]**

- **Server layer:** a `run` table holding `RunOut` rows and
  `run_alias(id, run_id)`. The upsert guards of sync-protocol.md §4.2 apply
  (fence, tombstone, revision). A `run` deletion inserts a tombstone of kind
  `run` and deletes the row.
- Epoch rebuilds stage runs like other kinds. Fences and leases are unchanged.
- The local **topic tombstone cascade** (sync-protocol.md §4.3 step 2) also
  deletes the topic's `run` and `run_alias` rows and tombstones them.
- Tombstone dependents (sync-protocol.md §4.3) for a run tombstone: **queued
  `run.event` items are kept and sent**. A closed run still accepts late merges
  (§4.4), and the server decides. A topic tombstone fails them as
  `deleted_elsewhere`, as for entries.

### 7.3 PWA **[pwa]**

The PWA has no change feed. It reads `listRuns(status=open|finishing)`:

- on load and on focus;
- every 10 s while any run is open or a timed topic's page is visible;
- after each of its own events (it uses the response directly).

## 8. Outbox

### 8.1 iOS: the `run.event` kind **[ios]**

| Kind        | Entity         | Request                                                | Payload                                                |
| ----------- | -------------- | ------------------------------------------------------ | ------------------------------------------------------ |
| `run.event` | `run:{run_id}` | `POST /api/v1/runs/{run_id}/events`, body `RunEventIn` | `{topic: {id, slug, name}, run_id, event: RunEventIn}` |

- **The item id is the event id.** For a start it is the run id.
- **Ordering (outbox.md §7.1), extended:** a `run.event` waits only for its
  run's unresolved **start** item and for `topic.*` items of its topic. Events
  are idempotent and folded by time (§4), so they don't need to wait for each
  other. A failed non-start event never blocks the run; a failed start blocks
  its run's events until it is retried or discarded (discarding it discards
  them). Entries need no new rule: answers go as `finish` (§3.6).
- **Coalescing (outbox.md §8), one new rule, K6:** when a `discard` is enqueued
  and every item of its run is `pending` and never attempted, including the
  `start`, all of them and the discard are dropped. Nothing is sent: the server
  never saw the run. Otherwise the discard is appended. No other coalescing
  applies to run events. Each is a distinct tap with its own timestamp.
- **Classification (outbox.md §5.2), additions:**

  | Response                                                                      | Outcome                                                                                                                                                                                   |
  | ----------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
  | 2xx that decodes as `RunEventResult`                                          | **Ack.** Upsert `run` (and `entry`, when present) under the guards. If `run.id ≠ run_id`, insert `run_alias(run_id → run.id)`. If `run.status` is closed, apply the run deletion locally. |
  | 2xx with `effect: "void"`                                                     | Ack as above. If the reason is `after_stop`, `run_edited`, `entry_deleted` or `already_closed`, and the event was a user tap from this device, show the notice in §11.4.                  |
  | 404 for a non-start event                                                     | `failed/deleted_elsewhere`, and trigger a pull                                                                                                                                            |
  | 409 `run_deleted`                                                             | Retire, and trigger a pull                                                                                                                                                                |
  | 409 `topic_not_timed`, `topic_archived`, `id_conflict`, `event_conflict`; 422 | `failed/rejected`. A 422 on `finish` or `stop` with answers offers Fix (the answers sheet).                                                                                               |

- **Undo** for run events is not offered, except that discarding a never-sent
  run removes it without a trace (K6).
- The **request golden** for each event type lives in
  `shared/fixtures/requests/recordRunEvent.*.json` (gate G1/G2).

### 8.2 PWA **[pwa]**

The IndexedDB outbox (`frontend/src/lib/outbox`) has only `entry.create` today
(`kinds.ts`) and no per-entity ordering: a pass skips a retrying item and sends
later ones (`outbox.ts` `pass`). It gains the `run.event` kind with **one**
ordering rule, "wait for this run's start", plus K6 and the classification
above. PWA entry edits stay online mutations; no other ordering is added. Its
base classification stays byte-compatible with iOS.

### 8.3 The local view of a run

A client's view of a run is the fold (§4) of:

1. the server-layer run's events, in their server arrival order; then
2. its own active `run.event` items for that run (and for its aliases), in
   outbox `seq` order.

Failed items are left out of the fold and listed in the sync sheet. Because the
fold is the same function everywhere (§13.1), a device that is the only one
tapping sees exactly the state the server will reach. A device that wasn't alone
converges at its next pull.

A queued **start** makes a local open run at once, so every surface on the
device (Live Activity, widget, Action button, Siri) can advance it before the
start reaches the server.

A queued **stop** that the client knows will produce an entry (the run's
version has no required question) projects an **optimistic entry** with id =
run id, the folded timing and `sync_state = pending`. The entry list, due
state, the badge and widgets then update at once, offline too. The server's
entry replaces it on ack or pull, as for any create. A stop that will leave the
run finishing projects nothing; the run shows "Add details".

## 9. Stats

### 9.1 Definitions

All durations are **active time** (paused time excluded) in integer
milliseconds. Only **timed entries** in the range count. Untimed entries of a
timed topic count toward `getTopicStats` as before, but never toward timing.

| Statistic               | Definition                                                                                                                                                                                                                                |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Run total**           | `timing.active_ms`. Includes step segments and lap segments.                                                                                                                                                                              |
| **Complete run**        | A run of a version **without steps**, or a run in which every step of its version has a segment and none was skipped. A run stopped before its last step is not complete.                                                                 |
| **Best** and **median** | Over the **complete** runs in range (OPEN 2). Median of an even count is `floor((a + b) / 2)` of the two middle values. Null when there are none.                                                                                         |
| **Mean**                | `floor(sum / n)`, same population                                                                                                                                                                                                         |
| **Per step**            | For each step key seen in range: `done` (runs where the step has a segment), `skipped` (runs where it is in `skipped`), and best, median and mean over the **done** segments' `active_ms`. Skipped steps contribute nothing to durations. |
| **Laps**                | Lap segments are never attributed to a step. Per run, `lap_ms` is their sum. Stats report `lap_ms` median and mean over runs that have laps.                                                                                              |
| **Paused**              | `paused_ms` per run, reported separately; never part of a duration above. `runs_with_pauses` counts runs with `paused_ms > 0`, so a zero-length pause doesn't count.                                                                      |
| **Series**              | One point per timed entry, by `captured_at` (the end), with `active_ms`, `paused_ms`, `complete`, and `steps: {key: active_ms}`                                                                                                           |
| **Step labels**         | The latest version's label for a key; a key no longer in the current version keeps its last label and is listed after current steps                                                                                                       |

### 9.2 `getTopicTiming` **[server]**

```
TopicTiming {
  runs: int, complete_runs: int,
  total: { best_ms, median_ms, mean_ms } (nullable fields),
  steps: { key, label, current: bool, done: int, skipped: int, best_ms, median_ms, mean_ms }[],   // current steps in step order, then the rest
  laps:  { runs_with_laps: int, median_ms, mean_ms },
  paused: { runs_with_pauses: int, median_ms },
  series: { entry_id, captured_at, started_at, active_ms, paused_ms, complete, steps: {key: active_ms} }[]   // by captured_at
}
```

`from` and `to` filter on `captured_at`, as `getTopicStats` does. A topic that
isn't timed and has no timed entries answers with zero counts, not an error.

## 10. Notifications and Live Activities

### 10.1 Reminders for timed topics **[server]**

- **Descriptor.** For a timed topic, `quick_log` is `{ "type": "timed" }`. The
  action needs nothing more.
- **Action.** One action, kind `start`, title "Start", identifier
  `q1|{server_id}|{topic_id}|{version}||t|` (the `k` value `t`, empty key and
  value; notifications.md §4.2). No `.foreground`.
- **Category id.** The algorithm of notifications.md §4.3, with `kind = start`
  hashed like any other kind. New vectors are added to
  `notification-vectors.json`.
- **The scheduler skips a timed topic that has an open run**, without marking
  the slot as sent. Someone timing it doesn't need a reminder. If the run is
  then discarded, the slot is still due and the reminder fires at the next tick;
  that is intended. Finishing runs don't suppress reminders.
- **Web Push** carries the same descriptor. Chromium shows one action,
  `{action: "log|t|", title: "Start"}`, following the `log|k|` convention of
  `frontend/src/lib/pushActions.ts`.

### 10.2 The Start action **[ios]** **[pwa]**

The handler follows notifications.md §7.1 with these changes:

- **Validate:** `k = t` requires `quick_log.type == "timed"`.
- **Ids:** the run id is `actionEntryId(server_id, topic_id, due_since)`
  (notifications.md §7.4). It is used as the run id **and** the start event id.
  Starting the same reminder twice, on any device or the PWA, starts one run,
  and the run's entry has the id that reminder would have logged.
- **Write:** enqueue a `run.event` start with `at` = now and
  `version = q.version`. A queued or known run with that id means the reminder
  was already started: write nothing.
- **Live Activity:** the app requests one locally (§10.3). If iOS refuses (the
  app is in the background), the server's push-to-start shows it once the start
  reaches the server. The start's `device` field says which happened.
- The PWA's service worker does the same with its outbox and Web Lock
  (notifications.md §10).

### 10.3 The Live Activity **[ios]** **[server]**

**Identity.** One Live Activity per **(server, topic)** with an open run: not
per run id, so a merge (§4.5) never leaves two. The attributes are
`{server_id, topic_id, topic_name}`, with `topic_name` truncated to 64
characters. There is no step list in the attributes: it could be the wrong
version's after a merge, and with 30 labels of up to 200 characters
(`MAX_LABEL_LENGTH`) it could push a push-to-start payload over 4 KB. The
content state carries what is shown.

**Content state** (Codable; part of the push contract, so fields are only ever
added as optional):

```
RunActivityState {
  v: 1, run_id, revision,
  status: "running" | "paused",
  started_at: Double,                 // Unix seconds; never Date (ActivityKit decodes Date from 2001)
  seg: Int, seg_started_at: Double,
  label: String, step_index: Int?, step_count: Int,       // "Step 2 of 5 · Shower"; labels ≤ 64 chars
  next_label: String?,                // what Next will start; null on the last step; ≤ 64 chars
  paused_at: Double?, paused_ms_before_seg: Int, paused_ms_in_seg: Int
}
```

**Presentation.**

| Place                    | Content                                                                                                                                                                                                                                           |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Lock Screen and banner   | Topic name; step label and "2 of 5"; the segment timer (large) and total timer, both `Text(timerInterval:pauseTime:)` so they tick without updates; buttons **Next** (or **Lap** without steps, and on the last step), **Pause/Resume**, **Stop** |
| Dynamic Island, compact  | Leading: step index or a timer glyph. Trailing: the segment timer.                                                                                                                                                                                |
| Dynamic Island, minimal  | The segment timer                                                                                                                                                                                                                                 |
| Dynamic Island, expanded | Step label, both timers, **Next** (or **Lap**) and **Stop**                                                                                                                                                                                       |
| Paused                   | Timers frozen at the pause; Resume replaces Pause                                                                                                                                                                                                 |
| Ended                    | "Saved · 7:42" (or "Add details" when finishing), dismissed after 15 minutes                                                                                                                                                                      |

**Buttons** are `LiveActivityIntent`s. iOS runs them in the **app process**,
launching it in the background if it was killed. Each one enqueues a `run.event`
with `at` = the tap time and `seg` from the content state, updates the activity
locally at once, and flushes with the 4 s intent budget (outbox.md §10). A tap
whose `seg` is stale is void on the server and does nothing harmful (§4.2).

**Updates: local first, push for other devices.**

- **Local.** The device that taps updates or ends its activity immediately.
  Each local update sets `staleDate` to 4 hours ahead, so an orphaned activity
  shows as stale instead of ticking silently to the 8-hour limit.
- **Push [server].** After every committed change to an open run, the
  background task (§6) sends a Live Activity push (`apns-push-type:
liveactivity`, topic `com.bahumia.quickr.push-type.liveactivity`, priority
  10): `event: update` with the content state, or `event: end` with a final
  state and a dismissal date when the run closes. Rules:
  - The content is the run's **latest state when the push is sent**, not the
    state of the event that triggered it. Sends are **serialised per topic**
    (one in flight at a time; a newer change replaces a queued one), so a later
    state never goes out before an earlier one.
  - The originating device's tokens are **excluded**: every iOS event carries
    `device` (§3.2), and that device already updated locally. Its own echo
    can't overwrite a newer local state.
  - APNs `timestamp` has whole-second resolution, and iOS applies pushes
    without the app, so the spec makes **no revision-ordering claim** on the
    device. Correctness comes from the rules above plus reconciliation.
- **Push-to-start [server].** When a run is created, the server sends
  `event: start` to every push-to-start token, except the originating device's
  when its start says `live_activity: true` (it started one locally). This is
  how a run started on the PWA, by MCP, or by a reminder action in the
  background appears on the phone.
- **Tokens.** One table, separate from `apns_devices`:

  ```sql
  CREATE TABLE live_activity_tokens (
    token        TEXT PRIMARY KEY,                -- lowercase hex
    kind         TEXT NOT NULL,                   -- 'start' | 'update'
    device_token TEXT NOT NULL,                   -- the APNs device token of the phone that owns it
    environment  TEXT NOT NULL,                   -- 'sandbox' | 'production'
    topic_id     UUID NULL,                       -- update tokens
    run_id       UUID NULL,                       -- update tokens: the run it was registered for
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
  );
  ```

  The app registers its push-to-start token
  (`Activity<RunActivityAttributes>.pushToStartTokenUpdates`) and each
  activity's update token through `registerLiveActivity`. Both are online-only
  and best-effort, with the retry rules of notifications.md §9.2.

- **Token failures [server].** Live Activity sends do **not** use
  `services/push` `deliver()`, which deletes the APNs device on `PushGone`
  (`backend/app/services/push/__init__.py`, `apns.py` `_failure`). A 410 or
  `BadDeviceToken` for a Live Activity token deletes **only that token row**. It
  never touches `apns_devices` and never counts toward its `failure_count`.
- **Ending a run [server].** After sending `end`, the server drops the update
  tokens **registered for that run id**. A token registered for a newer run of
  the same topic, in the gap, is kept.
- **Broadcast channels** (iOS 18) were considered and not used: one user's
  token table is simpler than managing a channel per topic.

**Reconciliation [ios].** On every app activation, after every sync, and when a
push wakes the app:

- end every activity whose topic has no open run in the view (stopped elsewhere
  while this device was offline, or a missed `end` push);
- end duplicates for the same (server, topic), keeping the most recently
  updated;
- update an activity whose displayed content differs from the view's state.

**When the app is killed.** The activity stays, and its timers keep ticking
because they are rendered by the system. Its buttons launch the app in the
background. A run stopped elsewhere ends it by push, or at the next
reconciliation. iOS ends any activity after 8 hours; the run itself stays open
and is shown in the app.

**Limits.** A device shows at most as many activities as iOS allows. A refused
request is logged, and the run works without one. Settings ▸ Notifications gets
a "Live Activities" switch, on by default.

### 10.4 Live Activity payload contract

- The Live Activity payloads (`start`, `update`, `end`) are pinned in
  `shared/fixtures/live-activity-vectors.json`, decoded by a new Swift suite
  `LiveActivityVectorTests`. The vectors pin the full `aps` keys:
  `timestamp`, `event`, `content-state`, `stale-date`, `dismissal-date`, and
  for `start` also `attributes-type`, `attributes`, `alert` and
  `input-push-token`. T-LAPUSH checks each key against Apple's current
  ActivityKit push documentation and cites it in the generator.

## 11. Client surfaces

### 11.1 Shared rules

- **Duration format** (`fmtDuration(ms)`), everywhere: `m:ss` below one hour,
  `h:mm:ss` from one hour. The value is **truncated** to whole seconds, so a
  running timer and the saved value agree. Negative input is clamped to `0:00`.
  Pinned by `duration-format-vectors.json`.
- **Primary button labels:** "Start", "Next: {next step}", "Lap", "Skip {step}",
  "Pause", "Resume", "Stop", "Discard". On the last step the primary button is
  **Stop**, with Lap secondary.
- **"Auto" advance** (the Action button, a small widget, Siri "next"): idle →
  Start; a named step remains → Next; otherwise → Stop. The dishwasher is then
  one press to start and one to stop.
- **Home and badge.** A timed topic with an open run shows "Running · 4:12"
  instead of its due state, and is not counted as due. A finishing run shows
  "Add details". These sit above derived due state; the due port itself
  (`due-vectors.json`) doesn't change. **One helper per platform** computes the
  count, and every writer uses it: on iOS a `QuickrCore` `dueCount(view)` used
  by the app badge, the NSE badge (notifications.md §6, §8), the home due
  section and the widgets; on the PWA one `dueCount` in `lib/home.ts` used by
  the home screen and the `badge.ts` caller.
- **Timed entries hide `captured_at`** on the entry edit screens (iOS and PWA).
  The time is changed through Edit times; a `captured_at` PATCH would be
  refused (§3.8).
- **Untimed entries** of a timed topic are listed normally, with no timing
  section.

### 11.2 iOS app **[ios]**

- **Tile (home):** idle shows a Start button. Running shows the segment label, a
  ticking timer and a "Next: …" or "Stop" button. One tap starts a run, with a
  haptic.
- **Run screen** (from the tile, the Live Activity or a link
  `quickr://t/{topic_id}/run`): total and segment timers; the step checklist
  with done, skipped and upcoming states and each done step's time; the primary
  button; Lap, Skip, Pause/Resume; Stop; Discard in a menu with a confirmation.
- **Stop:** sends `stop` at once. Then, if the version has questions, the
  answers sheet opens (the existing form engine), and Save sends `finish`
  (§3.6). Dismissing the sheet leaves a finishing run as "Add details" on home;
  a run without required questions is already an entry.
- **Entry details:** a timing section with the segments, skipped steps and
  pauses, and **Edit times**: each boundary is a time field with seconds, plus
  add and remove pause. It sends `entry.update` with `timing`.
- **Stats:** a Timing section on the Overview: best, median and runs; total over
  time (a line of `active_ms` by end time); per-step median bars with best
  marked; skipped counts.
- **Builder:** a "Timed" switch and a steps editor (add, rename, reorder,
  remove), published with the version.

### 11.3 Widgets, Controls, the Action button and Siri **[ios]**

| Surface                               | Behaviour                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Topic widget (timed topic)            | Idle: Start. Running: label, ticking timer, Next (or Lap) and Stop; small size shows one Auto button. Buttons are `LiveActivityIntent`s, so they run in the app process and can start or update the Live Activity.                                                                                                                                                                                                                                                                                                                                                                    |
| Control (Control Centre, Lock Screen) | A button control "Timer: {topic}" running Auto. Its intent is a `LiveActivityIntent`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| Action button                         | The App Intent `AdvanceRunIntent(topic, action: auto)`, offered in the Shortcuts gallery. It is a `LiveActivityIntent`.                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| Siri and Shortcuts                    | **One** App Shortcut, `RunActionIntent(action, topic)`, a `LiveActivityIntent`, with phrases such as "\(action) \(topic) in quickR" (action: start, next, stop, pause, resume). The app has 5 App Shortcuts (`ios/App/Intents/QuickRAppIntents.swift`), so this makes 6 of the 10 allowed. Without a topic it uses the only open run, and asks when there are several. Spoken results: "Started Morning routine. First: Shower." / "Shower took 4:12. Next: Breakfast." / "Saved Dishwasher: 7:42." When the stop leaves the run finishing: "Saved 7:42. Open quickR to add details." |

All of them write through the outbox with `origin` widget or siri, the same as
existing intents.

### 11.4 Notices

A void tap that the user made on this device shows a notice when the app is in
the foreground, and an entry in the sync sheet otherwise:

| Reason           | Text                                                                      |
| ---------------- | ------------------------------------------------------------------------- |
| `after_stop`     | "{topic} was already stopped at {time}, so your {Next/Lap} wasn't added." |
| `run_edited`     | "{topic}'s times were edited, so your {tap} wasn't added."                |
| `entry_deleted`  | "{topic}'s run was deleted."                                              |
| `already_closed` | "{topic} was already stopped."                                            |

`stale`, `merged`, `already_paused` and `not_paused` are silent: they are double
taps that did what the user wanted.

### 11.5 PWA **[pwa]**

- **Home tile:** as on iOS (Start; running label and timer; Next or Stop).
- **Running bar:** a strip above the content listing every open run, each with
  its timer and primary button. It links to the run panel.
- **Run panel** on the topic's Record page: the same layout and controls as the
  iOS run screen. Stop sends `stop`, then shows the answers form as on iOS.
- **Entry edit page:** the timing section and Edit times form.
- **Overview page:** the Timing section, with the existing chart components
  (`LineChart`, `StackedBars`).
- **Builder:** the Timed switch and steps editor.

### 11.6 MCP **[server]**

| Tool                                                   | Does                                                                                                                                                           |
| ------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `start_run(ref, at?)`                                  | A start with a new id; `at` defaults to server now                                                                                                             |
| `run_action(run_id, action, at?, answers?, notes?)`    | next, lap, skip, pause, resume, stop, finish or discard. `seg`, `step` and `pause_id` are filled from the current state, so the tool acts on what is open now. |
| `list_runs(status?)`                                   | Open and finishing runs, with their state                                                                                                                      |
| `edit_run_timing(entry_id, timing, expected_revision)` | §3.8                                                                                                                                                           |

`publish_topic_version` gains the required `timer` and `create_topic` the
optional one (§2.1). `record_entry` on a timed topic still makes an untimed
entry.

## 12. Compatibility

None. The user decided: "No build compatibility for this version!" The server,
the PWA and the iOS app are updated together, and builds from before this
milestone are not supported against its server. The only compatibility work is
mechanical: T-UNGATE (timers-plan.md) empties the compat gate's client list and
records the milestone's intentional breaks, so CI doesn't block them. The
forced-update mechanism for later releases is a separate, follow-on milestone
([client-versions.md](client-versions.md)).

## 13. Tests

### 13.1 Shared vectors (the `shared/fixtures` pattern)

Generated by `make vectors`, checked for drift by pytest, and never edited by
hand (`shared/fixtures/README.md` gains a row for each).

| File                                    | Generator (Python reference)                                              | Checked by                                                                | Cases (at least)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| --------------------------------------- | ------------------------------------------------------------------------- | ------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `run-fold-vectors.json`                 | `backend/tests/test_run_fold_vectors.py` (`services/run_fold.py`)         | Swift `RunFoldVectorTests` (QuickrCore); vitest `runFold.vectors.test.ts` | Instants with sub-millisecond digits (truncated; segment sums equal the total exactly); no steps start/stop; laps; 3 steps all done; Next after the last step; skip on a step; skip from a lap; a double-tapped skip (one `stale`); pause/resume; a resume naming an older pause (`stale`); Next while paused; stop while paused; double Next from two devices (one `stale`); offline taps arriving after Stop (merge, and `after_stop`); a late merge that turns an earlier Next stale; edited run with late taps; two stops (`already_closed`); discard then stop; equal `at` tie-break by id; events before start; `too_long` |
| `timing-stats-vectors.json`             | `backend/tests/test_timing_stats_vectors.py` (`services/timing_stats.py`) | Swift stats models; vitest chart models                                   | Empty; one run; even and odd medians; skipped steps; laps; pauses; renamed and removed steps across versions; untimed entries ignored                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `duration-format-vectors.json`          | `backend/tests/test_duration_vectors.py`                                  | Swift and vitest `fmtDuration`                                            | 0, 999, 1000, 59 999, 60 000, 3 599 999, 3 600 000, 86 400 000, negative                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `notification-vectors.json` (new cases) | existing generator                                                        | existing                                                                  | Timed with and without steps; the `start` kind in the hash                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| `apns-payload-vectors.json` (new cases) | existing generator                                                        | existing                                                                  | A timed reminder                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `live-activity-vectors.json`            | `backend/tests/test_live_activity_vectors.py` (`push/live_activity.py`)   | Swift `LiveActivityVectorTests`                                           | start, update (running, paused, last step, no steps), end (stopped, finishing, discarded); size ≤ 4 KB                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `api/*.json` (new)                      | `test_api_fixtures.py`                                                    | Swift decoding; G1                                                        | `recordRunEvent` (start, merged, next, void, stop with entry, finishing, finish), `getRun`, `listRuns`, `listChanges` (bootstrap with an open run, a run deletion with its entry), `recordRunEvent.finish_stopped`, `recordRunEvent.discard_finishing`, `getTopicTiming`, `updateEntry.timing`, `registerLiveActivity`, `deleteLiveActivity`                                                                                                                                                                                                                                                                                     |
| `requests/*.json` (new)                 | Swift golden generator                                                    | `test_request_goldens.py` (G2)                                            | `recordRunEvent.{start,next,lap,skip,pause,resume,stop,stop_answers,finish,discard}`, `updateEntry.timing`, `registerLiveActivity.start`, `registerLiveActivity.update`                                                                                                                                                                                                                                                                                                                                                                                                                                                          |

### 13.2 Backend

| #   | Case                                                                                                                                                                                                                                                                                                          |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| T1  | Every fold vector, through the real endpoint, gives the same `RunState` and effects as the pure fold.                                                                                                                                                                                                         |
| T2  | Two concurrent `next` requests with the same `seg` (two tasks, one database): one applied, one `stale`, one advance.                                                                                                                                                                                          |
| T3  | Two concurrent `start`s for one topic with different ids: one run, one alias, and later events to the alias apply to the run.                                                                                                                                                                                 |
| T4  | Replaying any event returns the same result. Reusing an event id with another `at` answers 409 `event_conflict`. An `at` with microseconds is stored truncated to milliseconds.                                                                                                                               |
| T5  | Stop without answers: no required questions gives an entry; required questions give `finishing`; `finish` with bad answers answers 422 and stores nothing. A stop before the start answers 422 `before_start`.                                                                                                |
| T6  | A late Next merged after Stop bumps the entry revision and logs an entry upsert, never a run upsert.                                                                                                                                                                                                          |
| T7  | `listChanges` bootstrap carries open and finishing runs as items and no closed ones; an incremental page carries run upserts and run deletions.                                                                                                                                                               |
| T8  | `listChanges` page contents, with `limit` cutting between a run's first row and its delete row: the run's deletion is not on the page that lacks its delete row, and every page that deletes a stopped run carries its entry or follows one that did.                                                         |
| T9  | Topic delete with an open run: run ids and aliases are in `deleted_ids`, and a later event answers 409 `run_deleted`.                                                                                                                                                                                         |
| T10 | PATCH of `captured_at` without `timing` on a timed entry answers 422 and changes nothing.                                                                                                                                                                                                                     |
| T11 | Publish without `timer` answers 422; with `null` turns timing off; a run started on the old version still stops against it.                                                                                                                                                                                   |
| T12 | The scheduler sends no reminder for a topic with an open run and doesn't mark the slot; after a discard the reminder goes out; a topic with only a finishing run gets its reminder.                                                                                                                           |
| T13 | `start` with an entry's id, and `createEntry` with an open or finishing run's id or an alias, answer 409 `id_conflict`; `createEntry` with a stopped run's id replays its entry.                                                                                                                              |
| T14 | Live Activity sender: latest state at send time; one in flight per topic; the originating device's tokens excluded; `end` drops only that run's update tokens; a 410 drops only that token and leaves `apns_devices` (and its `failure_count`) unchanged; push work never runs inside the writer transaction. |
| T15 | Discarding a finishing run: applied, the run is discarded and logged as a delete; discarding a stopped run is void.                                                                                                                                                                                           |
| T16 | `finish` on a stopped run patches the entry's answers and bumps its revision; a second stop with answers is applied as a finish; an edited run ignores later events without refolding.                                                                                                                        |
| T17 | Every `/api/v1` response, including errors and `/health`, carries `X-QuickR-Server-Time` as integer epoch milliseconds within a few ms of the server clock.                                                                                                                                                   |

### 13.3 iOS

| #   | Case                                                                                                                                                                                                                                                                           | Class   |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------- |
| R1  | Fold, stats and format vectors, with instants parsed to integer milliseconds (no `Date`)                                                                                                                                                                                       | host    |
| R2  | `listChanges` decode and apply: run items and run deletions, live and staged; a topic tombstone clears its runs and aliases                                                                                                                                                    | host    |
| R3  | Outbox `run.event`: waits only for its start; a failed Next doesn't block Stop; K6 drops a never-sent start…discard; classification table (§8.1)                                                                                                                               | host    |
| R4  | Local view: queued start → open run at once; queued Next folds over server events; an alias response re-keys the local run; a queued stop projects an optimistic entry; a start for a topic with a local open run enqueues nothing                                             | host    |
| R5  | (MP) The widget's Next and the app's Next for one segment, enqueued in the same instant: both queued, the server applies one                                                                                                                                                   | host MP |
| R6  | (INT) Device A starts and steps; device B, offline, taps Next twice and Lap; A stops; B flushes: the entry's timing equals the fold vector for that history                                                                                                                    | INT     |
| R7  | (INT) A reminder Start tapped on iOS and in the PWA: one run, whose id is the action entry id                                                                                                                                                                                  | INT     |
| R8  | Live Activity reconciliation with a fake activity centre: ends orphaned and duplicate activities; updates one whose content differs from the view                                                                                                                              | host    |
| R9  | UI test: start, Next ×2, Skip, Pause, Resume, Stop, answer, Save; the entry shows the expected segments                                                                                                                                                                        | sim     |
| R10 | UI test: Edit times on a finished run, then the stats screen shows the new median                                                                                                                                                                                              | sim     |
| R11 | `dueCount` is the one helper behind the app badge, the NSE badge, home and widgets: a topic with an open run isn't counted by any of them                                                                                                                                      | host    |
| R12 | Offset and clamp: the offset comes from the latest response with a round trip ≤ 5 s; `at` = device now + offset; an event whose stamp would be at or before the run's latest local `at` is clamped to that `at` + 1 ms (both platforms); offline stamping uses the last offset | host    |

### 13.4 PWA

Vitest for the fold port, `fmtDuration`, the server-time offset and the clamp
(as R12), the outbox kind (start ordering, K6,
classification), `dueCount`, and the components (tile states, run panel,
answers flow, timing editor validation, `captured_at` hidden on timed
entries). The existing `classifyStatus` parity test covers the new
kind's base classification.

### 13.5 Device validation (not automatable)

1. A notification Start with the app killed: the run starts; the Live Activity
   appears (locally if iOS allows it, otherwise by push-to-start); record which.
2. Live Activity Next and Stop with the app killed and with the phone locked.
3. Start on the PWA: the phone's Live Activity appears by push-to-start, and
   follows Next and Stop.
4. A run open past 8 hours: the activity ends; the app still shows the run.
5. The Action button, the Control and Siri, each for start, next and stop.
6. Before first unlock: Live Activity buttons fail gracefully (the store can't
   be opened), with a notice that asks the user to unlock.

## Open questions

Both are **taken as decided by the lead**, pending the user's final word.

1. **OPEN 1: what a lap means in a run with steps.** This spec makes a lap close
   the current segment and open an **unnamed** segment; the next Next then
   starts the next step. The alternative is to split the current step into
   sub-laps that all count toward it. **Recommendation: unnamed segment**, as
   specified. It keeps per-step stats clean, and it is what "something extra
   happened between steps" usually means. It also gives the no-steps case (laps
   of the dishwasher) the same rule.
2. **OPEN 2: which runs count for best and median.** This spec uses **complete
   runs only** (no skipped step) when the topic has steps, so a morning without
   the shower doesn't become the "best" routine. The series and the per-step
   stats still use every run. **Recommendation: complete runs only**, with a
   "complete runs" note under the numbers.

## Traceability

| User request or decision                                            | Where                    |
| ------------------------------------------------------------------- | ------------------------ |
| Start on one tap, capture the end on the second                     | §3.3, §3.5, §11.1 (Auto) |
| Optional internal checkpoints; named steps, skip, ad-hoc laps       | §2.1, §4.2, OPEN 1       |
| Versioned steps                                                     | §2.1                     |
| Stop saves start, end, total and per-segment times; answers at Stop | §2.3, §3.5, §3.6         |
| Stored server-side; any surface advances it; offline-tolerant       | §1, §4.1, §7, §8         |
| One open run per topic                                              | §2.2 (index), §4.5       |
| iOS and PWA UI                                                      | §11.2, §11.5             |
| Live Activity with Next and Stop as App Intents                     | §10.3                    |
| Action button, widget, Siri and Shortcuts                           | §11.3                    |
| Pause and resume                                                    | §4.2                     |
| Editing a past run's times                                          | §3.8                     |
| Stats: total over time, per step, median and best                   | §9, OPEN 2               |
| MCP tools                                                           | §11.6                    |
| Reminders with a Start action                                       | §10.1, §10.2             |
| Precision to the second or better; m:ss                             | §2.3, §5, §11.1          |
| No build compatibility for this version                             | §12                      |
