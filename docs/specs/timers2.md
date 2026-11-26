# Spec: timers v2 (lap types, alerts, reopen and remove)

**Status:** draft (revision 3, 2026-11-25, after review round 2). **Applies
to:** the backend, the PWA, the iOS app (app, widgets, Live Activity, intents,
notifications) and the MCP server. **Companion specs:** [timers.md](timers.md)
(v1: this spec changes it **by reference**; v1 stays as history with a banner
pointing here), [sync-protocol.md](../ios/specs/sync-protocol.md),
[outbox.md](../ios/specs/outbox.md),
[notifications.md](../ios/specs/notifications.md) and
[client-versions.md](client-versions.md). Where this spec is silent, timers.md
holds unchanged. **Plan:** [t2-plan.md](t2-plan.md) (milestone M1 of programme
T2).

**Normative language.** **MUST**, **MUST NOT**, **SHOULD** and **MAY** follow
RFC 2119. **[server]** marks a backend requirement, **[ios]** an iOS one and
**[pwa]** a PWA one. A rule marked **[deviation]** departs from the M0 design
brief because the code made the brief's wording unworkable; each is listed in
§13.

### What changes from v1

| timers.md (v1)                      | Change in v2                                                                                                                                                                                                                        | Here           |
| ----------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------- |
| §2.1 `Timer = {steps}`              | `Timer` gains `laps` (lap types), `variables` and per-step/per-lap-type `alerts`; output normalised; six new limits                                                                                                                 | §1, §7         |
| §2.3 `Segment` / `Timing`           | `Segment` gains `lap_type`; lap labels follow the lap-type rule ("Run 2", "Rest 2") instead of always "Lap n"; `Timing` carries event ids (`terminal_id`, `segments[].event_id`, `pauses[].id`) so clients can target a stopped run | §3.2, §3.3, §7 |
| §2.4 the change log                 | A **stop no longer tombstones** the run id; only a discard (and a topic delete) writes `deleted_ids(kind=run)`. A run may come back after a run deletion                                                                            | §4, §5         |
| §3.2 `RunEventIn`                   | Two event types, `reopen` and `remove`, with a `target`                                                                                                                                                                             | §3, §7         |
| §3.5 Stop, §3.7 Discard             | A stopped run can be reopened; a discard of a reopened run **reverts** the reopen (OQ-2)                                                                                                                                            | §3.4, §4.1     |
| §4 the fold                         | Fold **v4**: input `timer` instead of `steps`; reopen (gap pause), remove (deleted boundaries, the `seg` ghost rule); four new void reasons                                                                                         | §3             |
| §4.4 late merges                    | `reopen` and `remove` are exempt from `after_stop`; a remove on a stopped unedited run is a late merge                                                                                                                              | §3.6           |
| §7.1 feed, §7.2 iOS store, §7.3 PWA | Resurrection rule: a `run` deletion is not permanent on clients; `FeedDeletion.revision` is the durable fence; iOS keeps `run_closed` markers instead of run tombstones; `changes.py` emits a stop's deletion from its log row      | §5             |
| §8 outbox                           | `reopen`/`remove` are `run.event` items that wait for the run's start **and for the queued item their `target` names**; events enqueued after a pending `reopen` wait for it; K6 never drops a queued reopen                        | §5.5           |
| §9 stats                            | `TopicTiming.lap_types` and `SeriesPoint.lap_types` (M4 consumes)                                                                                                                                                                   | §7.4           |
| §10.3 Live Activity content state   | Optional fields `lap_type`, `lap_count`, `alert_at`, `alert_label`, `terminal_id`; `next_label` also for laps; push-to-start on reopen                                                                                              | §8             |
| §11.1 primary button                | Lap is the primary for lap-driven runs; `actions(run, timer, now)` is M1's model, M2 lays it out                                                                                                                                    | §10            |
| §11.4 notices                       | Notices for `reverted`, `deleted`, `not_stopped`, `no_target`                                                                                                                                                                       | §9.3           |
| §11.6 MCP                           | `run_action` gains `reopen` and `remove`; topic tools take the v2 `Timer`                                                                                                                                                           | §7.3           |
| §12 compatibility                   | `api_level 1 → 2`, `min_client_level = 2` on both platforms                                                                                                                                                                         | §11            |
| (new)                               | Alerts: expression grammar, iOS local-notification scheduling, PWA in-page alerts                                                                                                                                                   | §2, §9         |

## Purpose

The user's words (`requirements.md`), for the items this spec covers:

1. _"Rename 'lap' to something else"_ (the user times cigarettes with laps).
2. _"Resume a session (in case I stop it by accident)"_, clarified: _"Should
   work as a pause … and if I want to remove that pause I should be able to just
   delete the pause. The same goes for laps in general: I should be able to
   delete one and push its time into the one before or after as appropriate
   (normally before?)"_
3. _"configure laps so that they 'tik-tok' between two labels/types (eg run vs
   rest!)"_ (item 4).
4. _"a 'reminder' beep or whatever at some time interval (configurable per lap
   type!) … relative to a variable T. Eg 't \* 0.5', 't/2', 't+30s', '(t/2)+30s'
   … multiple variables … T=60s, then Alert1=T/2 and Alert2=T"_ (item 5). Alerts
   _"fire on iOS even when the phone is locked"_; _"the PWA alerts only while it
   is open"_.

Deletion clarification (settled in the brief): **a deleted entry is gone for
good.** Reopening applies to a stopped run whose entry still exists (or to a
finishing run); deleting the entry stays the way to throw a finished run away.

Items 3, 6, 7 (controls and home layout) are `active-surfaces.md` (M2); items 8
and 9 are `content-display.md` (M4) and `appearance.md` (M3). This spec owns the
**model and data** they build on.

## Glossary additions

| Term                 | Meaning                                                                                                                                                                                                                                                                                                                                                |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Lap type**         | A named kind of lap in `timer.laps`: `{key, label, alerts}`. Laps cycle through the version's lap types in order; with none, laps are untyped ("Lap _n_", v1).                                                                                                                                                                                         |
| **Variable**         | A named duration in `timer.variables` (`{name, ms}`) that alert expressions refer to (`t`, `rest`).                                                                                                                                                                                                                                                    |
| **Alert**            | `{key, label, at}` on a step or lap type: a cue that fires when the segment's **active** time reaches `at_ms` (the evaluated expression). Paused time doesn't count.                                                                                                                                                                                   |
| **Reopen**           | The event `reopen(target = the terminal stop's id)`: it un-terminates a stopped (or finishing) run. The gap between the stop and the reopen is a **gap pause**.                                                                                                                                                                                        |
| **Remove**           | The event `remove(target)`: it voids a pause (its time becomes active), a lap boundary (the lap merges into the previous segment) or a reopened stop (the gap pause goes).                                                                                                                                                                             |
| **Gap pause**        | The pause from a reopened stop's `at` to its reopen's `at`. It is a `Pause` like any other once folded, so T3/T5 hold and stats count it as paused time.                                                                                                                                                                                               |
| **Revert**           | A `discard` on a run whose terminal was cleared by a reopen: the reopen becomes void `reverted`, the stop is the terminal again. The way out of an accidental reopen.                                                                                                                                                                                  |
| **Resumable**        | An entry a client offers "Resume run" for: a timed entry whose run is the topic's latest stop and whose times are **unedited** (`run.edited == false`, i.e. `timing.edited` false; answers, notes and meta changes don't count), within 15 minutes of the stop on tiles and toasts (OQ-1), and from the entry detail within 7 days of the run's start. |
| **Terminal id**      | `RunState.terminal_id` and `Timing.terminal_id`: the id of the applied stop that closed the run (null in `RunState` while open or discarded). A reopen names it.                                                                                                                                                                                       |
| **Ghost boundary**   | A removed lap boundary, which still counts toward the expected `seg` of taps made between the lap and its removal (§3.5).                                                                                                                                                                                                                              |
| **Closed / deleted** | The two kinds of `run` feed deletion (§5.1): a **closed** run left the live set (stopped; its row stays, no tombstone; a `reopen` brings it back), a **deleted** run is gone (discarded or with its topic; tombstoned, final).                                                                                                                         |
| **Resuming**         | A client-local run state: a `reopen` queued from an entry with no run row locally projects a run built from the entry's timing until the ack (§5.3). A `remove` queued the same way projects no run: the entry stays, re-projected, with a pending mark.                                                                                               |

## 1. Timer config v2 **[server]**

### 1.1 Schema

Still on `topic_versions.timer`, still versioned and pinned per run (timers.md
§2.1): lap types change what a run's segments mean, so one config path, no
second PATCH surface. No column change.

```
Timer    = { steps: Step[], laps: LapType[], variables: Variable[] }
Step     = { key: QuestionKey, label: Label, alerts: Alert[] }           // ≤ 30 steps (v1)
LapType  = { key: QuestionKey, label: ShortLabel, alerts: Alert[] }      // ≤ 8 lap types
Variable = { name: VarName, ms: int }                                    // ≤ 16; 0 ≤ ms ≤ 7 days
Alert    = { key: QuestionKey, label: ShortLabel, at: Expr, at_ms: int } // ≤ 8 per step or lap type

QuestionKey = ^[a-z][a-z0-9_]{0,62}$          (limits.py:7, as v1)
Label       = 1..200 chars                     (questions.py:74, as v1)
ShortLabel  = 1..64 chars                      (the Live Activity label cap, live_activity.py:75)
VarName     = ^[a-z][a-z0-9_]{0,15}$           (stored lowercase; input case-insensitive; not a unit name)
Expr        = 1..64 chars, grammar §2
```

- **Reserved variable names:** `ms`, `s`, `m` and `h` are the units of §2.1 and
  are refused as variable names (422 at `variables.{i}.name`); otherwise `2m`
  (two minutes) and `2*m` (twice a variable) would read alike.

- `laps = []` means untyped laps labelled "Lap _n_" (v1 behaviour). One lap type
  renames laps ("Cig 1, Cig 2"); two or more cycle ("Run 1, Rest 1, Run 2, Rest
  2"). **Items 1 and 4 are one concept.**
- **Keys of steps and lap types share one namespace** within a timer: unique
  across both lists, so a `Segment` is identified by `step` **or** `lap_type`
  without ambiguity. Variable names are a separate namespace. Alert keys are
  unique within their step or lap type.
- `at_ms` is **server-computed, output only**: the evaluation of `at` over
  `variables` (§2). A client MAY send it; the server ignores the sent value and
  fills its own.
- Alerts on steps use the same schema and editor as alerts on lap types (OQ-4,
  default yes).

### 1.2 Limits

New constants in `backend/app/schemas/limits.py` and rows in `Limits`
(`GET /limits`, api.py `Limits`): `max_steps 30` (exists, now exposed),
`max_lap_types 8`, `max_variables 16`, `max_alerts 8`, `max_expr_length 64`,
`max_var_name_length 16`, and `max_short_label_length 64` (lap-type and alert
labels; **[addition]** to the brief's list, needed because `ShortLabel` has no
existing constant). Mirrors: PWA `src/api/limits.ts` `FALLBACK_LIMITS`, iOS
`Limits.serverDefaults` (`QuickrCore/Models/ServerInfo.swift`),
`shared/fixtures/api/getLimits.json` (regenerated).

### 1.3 Validation and error paths

422 `invalid_request` with dotted paths, as v1's `steps.{i}.key`
(questions.py:259-264). Checked in this order within `Timer`:

| Path                                 | Rule                                                                                                 |
| ------------------------------------ | ---------------------------------------------------------------------------------------------------- |
| `steps`                              | ≤ 30                                                                                                 |
| `laps`                               | ≤ 8                                                                                                  |
| `variables`                          | ≤ 16                                                                                                 |
| `steps.{i}.key`, `laps.{i}.key`      | pattern; unique across steps and lap types ("duplicate key '…' (also a step)" when it crosses lists) |
| `laps.{i}.label`                     | 1..64                                                                                                |
| `variables.{i}.name`                 | pattern (after lowercasing); not `ms`, `s`, `m` or `h`; unique (case-insensitive)                    |
| `variables.{i}.ms`                   | 0 ≤ ms ≤ 604 800 000                                                                                 |
| `{steps\|laps}.{i}.alerts`           | ≤ 8                                                                                                  |
| `{steps\|laps}.{i}.alerts.{j}.key`   | pattern; unique within the owner                                                                     |
| `{steps\|laps}.{i}.alerts.{j}.label` | 1..64                                                                                                |
| `{steps\|laps}.{i}.alerts.{j}.at`    | 1..64 chars, then evaluates without error (§2); the message is `"{code} at {pos}: {detail}"`         |

Pinned in `builder-vectors.json` `timers[]` (generator
`GENERATOR_VERSION 3 → 4`), new cases: `laps-one-type`, `laps-two-types`,
`laps-max`, `laps-too-many`, `lap-key-collides-with-step`, `lap-label-65`,
`variables-max`, `variables-too-many`, `variable-name-uppercase-normalised`,
`variable-name-duplicate-case`, `variable-name-reserved-unit` (`m`),
`variable-ms-negative`, `variable-ms-over-7d`, `alerts-max`, `alerts-too-many`,
`alert-key-duplicate`, `alert-expr-syntax`, `alert-expr-unknown-variable`,
`alert-expr-type`, `alert-expr-65-chars`, `alert-on-step`, `v1-shape-accepted`,
`output-normalised`.

### 1.4 Normalisation and stored timers

- **Output is normalised**: `laps`, `variables` and every `alerts` list are
  always present (`[]` when empty), `at_ms` filled, variable names lowercase.
  This holds for `TopicSummary.timer`, `TopicDetail.timer`,
  `TopicVersionOut.timer`, the `topic` and `version` feed items and MCP.
- **Input accepts the v1 shape** `{steps: [{key, label}]}`: missing lists and
  alerts default to `[]`. Stored v1 timers parse with the defaults
  (`parse_timer`, `topics.py:61-66`, `context={"stored": True}`); no data
  migration of `topic_versions.timer`.
- `publishTopicVersion` still requires `timer` (v1 §2.1); `checkTopicVersion`
  still ignores it for compatibility and accepts the v2 shape.

### 1.5 Why versioned (rationale)

A lap type key is the identity of its laps across versions, as a step key is for
steps (stats join by key, §7.4). A run is pinned to its version, so publishing
new lap types during a run doesn't relabel it. The alternative (a topic-level,
PATCHable timer) would need a second write path with its own revision rules and
would let a running run's segments change meaning under it.

### 1.6 Builder rules (both clients)

- **Lap types list** under the steps list, shown when "Timed" is on: add,
  rename, reorder, remove; each row shows its key badge (published / new) as
  steps do. Keys derive from the label as step keys do (`stepKeyFor`,
  `StepKeys`), avoiding step keys and historic lap-type keys of the topic. A
  published lap type keeps its key when renamed.
- **Variables list**: name and a duration field (`m:ss` or `h:mm:ss` entry,
  stored as ms); names are lowercased on entry.
- **Alerts** per step and per lap type: label, expression; the editor evaluates
  the expression live with the draft's variables and shows the result
  (`fmtDuration(at_ms)`) or the error at its position. A step or lap type with
  alerts shows a count badge in its collapsed row.
- Server errors map by their dotted path to the field (`builderFieldFor`,
  `DraftValidation`).
- Review sheet "Timing" section lists lap-type, variable and alert changes
  (`timerChanges` v2: added/removed/renamed lap types, variables, alerts).
- `builder-ui-vectors.json` (vitest generator, consumed by iOS
  `BuilderUIVectorTests`) gains sections `new_lap_type`, `lap_type_label`,
  `variable`, `alert_expr` (draft → evaluation text or error text), and v2
  versions of `timer_output` (normalised `Timer`) and `timer_changes`.

## 2. Expression grammar (`Expr`)

### 2.1 Grammar (EBNF)

```
expr     := term { ('+' | '-') term }
term     := factor { ('*' | '/') factor }
factor   := duration | number | ident | '(' expr ')' | '-' factor
duration := number unit
unit     := 'ms' | 's' | 'm' | 'h'
number   := digit { digit } [ '.' digit { digit } ]
ident    := letter { letter | digit | '_' }          // matched case-insensitively against variables
```

Whitespace between tokens is ignored. Tokens are matched longest-first (`ms`
before `m`). A unit MUST follow its number without a space (`30 s` is a `syntax`
error at the `s`). `+`/`-` and `*`/`/` are left-associative; `*`/`/` bind
tighter; unary minus binds tightest (`-t/2` is `(-t)/2`).

Whitespace is space, tab, CR and LF; letters and digits are ASCII. A number
takes a fraction only when a digit follows the `.`; the unit is the longest of
`ms`, `s`, `m`, `h` that directly follows; whatever comes next starts a new
token (`30sec` is `30s` then `ec`: `syntax` 3).

### 2.2 Types

Two types: **number** (a scalar) and **duration** (ms). Variables are durations.

| Operation           | Result   |                                                                                      |
| ------------------- | -------- | ------------------------------------------------------------------------------------ |
| duration ± duration | duration |                                                                                      |
| duration × number   | duration | and number × duration                                                                |
| duration ÷ number   | duration |                                                                                      |
| number op number    | number   | `+ - * /`                                                                            |
| −duration, −number  | same     |                                                                                      |
| duration + number   | `type`   | and the symmetric cases, duration × duration, number ÷ duration, duration ÷ duration |

The whole expression MUST evaluate to a **duration** (a bare number is OQ-5:
default **error** `type` "add a unit"). The result MUST be ≥ 0 (`negative`) and
≤ 7 days (`too_long`).

### 2.3 Errors

`{error: code, pos}` where `pos` is the 0-based character offset of the token
the error is reported at (the whole expression: 0).

| Code               | When                                                                                                                  | `pos`                                    |
| ------------------ | --------------------------------------------------------------------------------------------------------------------- | ---------------------------------------- |
| `syntax`           | Unexpected token or end, unknown character, unknown unit, empty input                                                 | the offending character                  |
| `unknown_variable` | An identifier that is not a variable                                                                                  | the identifier                           |
| `type`             | A type rule in §2.2 fails, or the result is a number                                                                  | the operator; 0 for a bare-number result |
| `div_zero`         | Division by a number that evaluates to 0                                                                              | the `/`                                  |
| `negative`         | The result is below 0                                                                                                 | 0                                        |
| `too_long`         | The text is longer than 64 characters (`pos` 64), or the result or any intermediate duration exceeds 7 days (`pos` 0) |

Errors are reported in this order: text length; then the whole parse (the first
syntax error, by position; an unexpected token is reported at its first
character); then evaluation, first error in evaluation order (left operand,
right operand, then the operator's checks: `type`, `div_zero`, then `too_long`
if a duration's magnitude exceeds 7 days; literals and variables are checked as
read); finally a number result is `type` 0 and a result below 0 is `negative` 0.
Numbers have no bound. `pos` and the 64-character limit count Unicode code
points.

### 2.4 Evaluation

Numbers and durations are IEEE doubles during evaluation (ms for durations:
`1.5m` = 1.5 × 60 000); the three implementations perform the same operations in
the same order, so results are bit-identical. The final duration is **truncated
toward zero to whole ms** (`int()`, `Math.trunc`, `Int()`). Intermediate values
are never rounded. A unit literal is `number × factor` with factors 1, 1 000, 60
000, 3 600 000.
Every check uses the untruncated double (`0s-0.5ms` is `negative`;
`168h+0.5ms` is `too_long`).

### 2.5 Implementations and vectors

Reference `backend/app/services/timer_expr.py`
(`evaluate(text, variables) -> int`, raising `ExprError(code, pos)`); ports
`frontend/src/lib/runs/timerExpr.ts` and
`ios/QuickrKit/Sources/QuickrCore/Runs/TimerExpr.swift`. Vectors
`shared/fixtures/timer-expr-vectors.json`, generator
`backend/tests/test_timer_expr_vectors.py` (`GENERATOR_VERSION 1`):

```
{ meta: { generator, generator_version, max_ms: 604800000, max_length: 64, semantics: [...] },
  cases: [ { name, expr, variables: {name: ms}, expected: {ms} | {error, pos} } ] }
```

Cases (at least): `plain_seconds` (`30s`), `minutes_fraction` (`1.5m` → 90000),
`hours` (`1h`), `ms_unit` (`1500ms`), `user_half` (`t*0.5`, t=60000 → 30000),
`user_half_spaced` (`t * 0.5`, the user's spelling), `user_alert1_uppercase`
(`T/2` with the variable declared as `t`, T=60s → 30000),
`user_alert2_uppercase` (`T` → 60000), `user_div` (`t/2`), `user_plus` (`t+30s`
→ 90000), `user_parens` (`(t/2)+30s` → 60000), `user_alert2` (`t` → 60000),
`precedence_mul_before_add` (`t+2*10s`), `precedence_parens` (`(t+10s)*2`),
`left_assoc_minus` (`t-10s-10s`), `number_times_duration` (`2*t`),
`division_truncates` (`t/3` with t = 1000 → 333), `fractional_ms_truncates`
(`0.0015s` → 1), `unary_minus_double` (`--t`), `unary_minus_negative` (`-t` →
`negative`), `case_insensitive_variable` (`T/2` with `t`),
`unit_uppercase_is_syntax` (units are lowercase only: `30S` → `syntax` 2),
`whitespace_ignored` (`t + 30s`), `bare_number` (`30` → `type` 0),
`duration_plus_number` (`t+30` → `type` 1), `duration_times_duration` (`t*t` →
`type` 1), `number_div_duration` (`2/t` → `type` 1), `unknown_variable` (`x/2` →
0), `div_zero` (`t/0`), `div_zero_expression` (`t/(1-1)`), `too_long_text` (65
chars), `too_long_value` (`t*2000` with t = 1h), `too_long_intermediate`
(`t*10000-t*10000`), `syntax_trailing` (`t+`), `syntax_unknown_unit` (`30d`),
`syntax_space_before_unit` (`30 s`), `syntax_empty` (``), `nested_parens`
(`((t))`), `two_variables` (`work+rest`), `zero_allowed` (`t-t` → 0).

## 3. Fold v4

Reference `backend/app/services/run_fold.py`; ports
`frontend/src/lib/runs/fold.ts` and `QuickrCore/Runs/RunFold.swift`; contract
`run-fold-vectors.json` (`GENERATOR_VERSION 3 → 4`). Everything in timers.md §4
holds unless changed below.

### 3.1 Inputs

`fold(run_id, timer, events, *, frozen)` takes the version's **`timer`** (steps
and lap types; variables and alerts are not fold inputs) instead of `steps`. In
the vectors, `step_sets` becomes `timer_sets`: `none` (`{steps: [], laps: []}`),
`two`, `three` (v1's steps, no lap types), `renamed` (no steps, one lap type
`cig` "Cig"), `tiktok` (no steps, `run` "Run" and `rest` "Rest"), `three_types`
(one step `warmup`, lap types `run`, `rest`, `walk`).

### 3.2 Lap labelling

Let `n = |timer.laps|`. Lap _i_ (1-based, counting lap segments of the run in
time order, closed ones then the open one) has

- `lap_type = laps[(i − 1) mod n].key` and
  `label = "{laps[(i−1) mod n].label} {((i − 1) div n) + 1}"` when `n > 0`
  (per-type ordinal, OQ-3);
- `lap_type = null` and `label = "Lap i"` when `n = 0` (v1).

Step segments have `lap_type = null` and the step's label, as v1. Examples:

| Timer         | Lap segments in order                              |
| ------------- | -------------------------------------------------- |
| `none`        | Lap 1, Lap 2, Lap 3                                |
| `renamed`     | Cig 1, Cig 2, Cig 3                                |
| `tiktok`      | Run 1, Rest 1, Run 2, Rest 2, Run 3                |
| `three_types` | (Warmup step) Run 1, Rest 1, Walk 1, Run 2, Rest 2 |

Removing a lap boundary renumbers later laps and so flips their types in a
cycle. That is intended: removing a double-tapped lap restores the run/rest
rhythm (§6, example 4). `TimingEdit` and `_segments` relabel the same way.

### 3.3 Output additions (additive on the wire)

- `Segment`, `OpenSegment`, `TimingSegment`: `lap_type: key | null`.
- `RunState`: `terminal_id: UUID | null` (the applied terminal **stop**'s id;
  null while open, after a reopen, and for a discarded run);
  `next_lap_type: key | null` (the type of the lap a `lap` tap would open now:
  lap number `lap_count + (open.kind == lap ? 1 : 0) + 1`; null when untyped or
  the run isn't open); `lap_count: int` (closed lap segments).
- **Event ids in `Timing` and `RunState`** (additive), so a client can target a
  stopped run from its entry, offline, after a relaunch or on another device:
  `Timing.terminal_id: UUID | null` (the applied stop),
  `TimingSegment.event_id: UUID | null` (the `next` or `lap` event that
  **opened** the segment; null for the first segment, which the start opened),
  `TimingSegment.opened_by: "start" | "next" | "lap" | "skip" | null` (the type
  of the event named by `event_id`; `"start"` for the first segment; `"skip"`
  never opens a segment in v2 and is reserved), `TimingPause.id: UUID | null`
  (the `pause` event's id; a gap pause carries its stop's id).
  `RunState.segments`/`pauses` carry the same. **All four are null only on
  pre-v2 stored timings** (nothing backfills `entries.timing`; `entry_out`
  validates stored JSON straight into the schema, `entries.py:103`, so every
  field is nullable) **and after a `TimingEdit`** for the segment and pause
  fields (`terminal_id` is kept; an edited run can't be reopened or removed from
  anyway, §3.6). A Resume from a pre-v2 entry sends `target: null`, which §4.2
  resolves. iOS decodes all four as plain optionals (no `@RequiredKey`).
  Consumers: the tile/toast Resume uses `entry.timing.terminal_id`
  (active-surfaces.md); the entry detail's Remove uses `segment.event_id` /
  `pause.id` and disables Remove on a lap row whose `opened_by` is `"next"` (a
  `remove` of a `next` is `no_target`) (content-display.md §3.2). Vectors
  `timing-carries-event-ids`, `timing-pre-v2-null-ids`; API fixture
  `getEntry.v1_timing` (a stored v1 timing served unchanged).
- New `VoidReason`s: `reverted`, `not_stopped`, `deleted`, `no_target` (§3.4).
- `Event` gains `target: id | null`.

### 3.4 Replay (full pseudocode)

```
fold(timer, events_in_arrival_order):
  // Effects are outputs of THIS fold only: `effects` starts empty and nothing is retained
  // between folds (the server refolds every run from scratch on every event, v1 §6).
  steps = timer.steps; laps = timer.laps
  effects = {}; seen = {}; terminal = null; accepted = []
  open_reopen = null            // the (stop S, reopen R) whose reopen cleared the CURRENT terminal
  roles = []                    // every applied (S, R) pair, for pass 2's gap pause/resume roles
  removed = {}                  // target id → the remove event that applied
  for e in events_in_arrival_order:                       // pass 1: arrival
    if e.id in seen: continue                             // idempotent
    seen += e.id
    if frozen and index(e) ≥ frozen.after: void(e, frozen.reason); continue
    if e.type == start:
      if e.id == run.id: start = e else void(e, merged); continue
    if e.type == finish: continue                         // the server decides it (v1 §3.6)
    if e.type == stop:
      if e.at < start.at: void(e, before_start)           // never a terminal (v1 §4.2)
      elif e.at > start.at + 7 days: void(e, too_long)
      elif terminal: void(e, already_closed)
      else: terminal = e; open_reopen = null              // a new terminal ends the reopen transaction
      continue
    if e.type == discard:
      if terminal: void(e, already_closed); continue
      if open_reopen:                                     // the terminal was cleared by a reopen: REVERT (OQ-2)
        (S, R) = open_reopen; open_reopen = null
        void(R, reverted); terminal = S; roles -= (S, R)
        if S.id in removed:                               // the gap pause had been removed: S is a terminal again
          apply(S); void(removed[S.id], no_target); removed -= S.id
        apply(e)                                          // the discard closed what the reopen opened
      else: terminal = e
      continue
    if e.type == reopen:
      t = seen stop with id == e.target
      if !t: void(e, no_target)
      elif terminal is a discard: void(e, already_closed)
      elif terminal == null or terminal.id != e.target: void(e, not_stopped)   // not the current terminal
      elif e.at ≤ t.at: void(e, stale)
      elif e.at > start.at + 7 days: void(e, too_long)
      else: apply(e); open_reopen = (t, e); roles += (t, e); terminal = null
      continue
    if e.type == remove:
      t = seen event with id == e.target
      eligible = t and t.id ∉ removed and e.at > t.at and
                 (t.type ∈ {pause, lap} or (t.type == stop and (t, _) ∈ roles))
      if !eligible: void(e, no_target); continue
      apply(e); removed[t.id] = e
      if t.type == stop: void(t, deleted)                 // the gap pause goes; its reopen stays applied
      continue
    accepted += e                                         // next, lap, skip, pause, resume

  // pass 2: time. Reopened stops and reopens take part as synthetic roles that carry their
  // events' ids: gap_pause(S) is a pause with id S.id at S.at; gap_resume(R) is a resume with
  // id R.id at R.at naming S.id. Their recorded effects are pass 1's and are not changed here.
  gaps = [ gap_pause(S) for (S, R) in roles if S.id ∉ removed ] + [ gap_resume(R) for (S, R) in roles ]
  st = { open: Seg(step = pop(pending = steps), start = start.at, index = 0),
         paused_since: null, pause_id: null, segments: [], skipped: [], pauses: [] }
  ghosts = []                                             // (lap.at, remove.at) of removed lap boundaries
  end = terminal ? terminal.at : +∞
  expected_seg(e) = len(st.segments) + |{ g ∈ ghosts : g.at < e.at < g.removed_at }|
  rank(e) = gap_pause ? 0 : gap_resume ? 2 : 1            // at equal `at`: gap pauses first, gap resumes last
  id(e)   = gap_pause(S) ? S.id : gap_resume(R) ? R.id : e.id
  order(e) = (e.at, rank(e), id(e))                       // total; within rank 1 v1's rule still holds:
                                                          // a resume at its named pause's `at` sorts right after that pause
  for e in sort(accepted + gaps, by order):
    if e is a role:                                       // never recorded; skipped outside the run
      if e.at < start.at or e.at > end: continue
      gap_pause(S):  if !st.paused_since: st.paused_since = S.at
                     st.pause_id = S.id                   // the gap OWNS the open pause: a user resume inside it is stale
      gap_resume(R): if st.paused_since: st.pauses += [st.paused_since, R.at); st.paused_since = st.pause_id = null   // ends WHATEVER pause is open
      continue
    if e.at < start.at: void(e, before_start); continue
    if e.at > end:      void(e, after_stop);   continue
    if e.at > start.at + 7 days: void(e, too_long); continue
    if e.id in removed:                                   // a deleted boundary or pause
      if e.type == lap and e.seg == expected_seg(e): ghosts += (e.at, removed[e.id].at)
      void(e, deleted); continue
    case e.type:
      next, lap:
        if e.seg != expected_seg(e): void(e, stale); continue
        close(st.open, e.at)
        st.open = Seg(step = e.type == next ? pop(pending) : lap, start = e.at, index + 1)
      skip:
        if e.seg != expected_seg(e): void(e, stale); continue
        (as v1 §4.2)
      pause:  if st.paused_since: void(e, already_paused) else st.paused_since = e.at; st.pause_id = e.id
      resume: if e.pause_id in removed: void(e, deleted); continue
              if !st.paused_since: void(e, not_paused); continue
              if e.pause_id != st.pause_id: void(e, stale); continue
              st.pauses += [paused_since, e.at); paused_since = null
  if terminal:
    if terminal.type == stop:
      if paused_since: st.pauses += [paused_since, terminal.at)
      close(st.open, terminal.at); status = stopped (or finishing, server); terminal_id = terminal.id
    else: status = discarded
  else: status = paused_since ? paused : running
  label every lap segment by §3.2; lap_count = closed laps; next_lap_type by §3.3
```

Notes on the rules:

- **A reopened stop does not close the open segment.** The segment spans the
  gap; the gap is its `paused_ms`. Only the current terminal closes a segment.
- **A reopen means "the run is running again": it ends whatever pause is open at
  `R.at`.** With the gap pause present that is the gap; with a user pause open
  at the stop (stop while paused), that pause continues through the gap and ends
  at the reopen; with the gap pause removed and an offline user pause inside the
  gap, that pause ends at the reopen too (its later `resume` is `not_paused`,
  silent). Vectors `reopen-while-paused-ends-pause`,
  `reopen-gap-removed-user-pause-inside-gap`.
- **The gap owns the open pause.** `gap_pause(S)` sets `pause_id = S.id` whether
  or not a pause was already open, so an offline user `resume` whose `at` lies
  inside an un-removed gap names a pause the gap took over and is `stale`
  (silent): stopped time never counts as active. With the gap pause removed
  there is no takeover and such a resume applies (the user asked for the gap to
  be active time). Vector `resume-inside-gap-stale`.
- **Equal-time ordering with roles.** Roles carry their events' ids and a rank:
  at the same `at`, a gap pause sorts before every user event and a gap resume
  after every user event; among user events v1's rule holds (a resume at the
  same `at` as the pause it names sorts right after it). So a user `resume` at
  exactly `S.at` is `stale` (the gap already owns the pause), never
  `not_paused`; a user `pause` at exactly `R.at` is `already_paused` with the
  gap present, and with the gap removed it applies and the gap resume ends it at
  once (a zero-length pause, T3 allows it). The sort key is **`(at, rank, id)`**
  with `id = S.id` for a gap pause and `R.id` for a gap resume, so the order is
  total: two reopened stops at the same `at` (an offline stop at the same
  instant as a reopened one, itself reopened later) sort by `S.id`, the later
  one takes over `pause_id`, and each gap resume ends whatever pause is open at
  its `R.at`. Every port sorts alike. Vectors
  `gap-pause-equal-time-user-resume`, `gap-resume-equal-time-user-pause`,
  `two-gap-pauses-equal-time`.
- **Effects are recomputed from scratch on every fold.** Nothing carries over:
  after a revert restored a removed stop (its remove `no_target`), the same stop
  is eligible for a new `remove` once a new reopen clears it again, and a later
  revert voids that remove in turn. Vector
  `stop-reopen-remove-gap-revert-reopen-remove-gap-revert`.
- **A reopen's effect is pass 1's.** Its resume role is a no-op when no pause is
  open at `R.at` (the gap pause was removed). **[deviation]** The brief voids
  such a reopen `not_paused`, which would contradict its pass-1 `applied` effect
  and re-terminate the run; the role is silent instead.
- **One reopen transaction at a time.** `open_reopen` is the reopen that cleared
  the current terminal; a later stop that becomes the terminal ends the
  transaction, so a discard then is `already_closed`, never a revert of an older
  reopen. Vector `stop-reopen-stop-reopen-discard-discard` (the first discard
  reverts the second reopen; the second is `already_closed`).
- **A removed reopened stop is void `deleted`** in pass 1 (its gap pause goes,
  its reopen stays applied). A revert restores it to `applied` (it is the
  terminal again) and voids the remove `no_target`.
- **A later stop becomes the new terminal.** Including a stop whose `at` lies
  before the reopen (another device's offline stop): the run is then stopped at
  that `at`, the gap pause is cut there by the stop-while-paused rule, and taps
  after it are `after_stop`. A reopen targeting that stop recovers them. Rare,
  deterministic, accepted.
- **`remove` eligibility** is by type and identity only, not by the target's
  pass-2 effect: a remove of a `stale` lap applies and marks it `deleted`, which
  changes nothing. A `resume` naming a removed pause is `deleted`. Removing a
  pause that was itself void (`already_paused`) changes only the reason of its
  resume (`stale` → `deleted`: it never named the open pause), not the state
  (vector `remove-void-pause-noop`); removing an **applied** pause can change
  which later pause applies (a later pause that was `already_paused` under it
  becomes applied, and its resume with it), which is the intended effect of the
  removal (vector `remove-pause-changes-which-pause-applies`). The fold
  recomputes everything; nothing is patched in place. Clients only offer Remove
  on applied boundaries.
- **`remove` has no 7-day bound** (review C-S1 #6, rejected). A remove is an
  edit of a stored run, like `TimingEdit` (v1 §3.8), which has no bound on
  _when_ it is made; its only temporal rule is `at > target.at`. The 7-day cap
  bounds the run's **length**, which a remove never changes. `reopen` keeps the
  run-length bound because its `at` lies inside the run.
- **Determinism (the M1-FOLD property).** Given the same relative arrival order
  of terminals (`stop`, `discard`), `reopen`s and `remove`s with respect to one
  another and to their targets, every arrival order of the other events (`next`,
  `lap`, `skip`, `pause`, `resume`) gives the same state: they commute. A reopen
  or remove that arrives before its target is `no_target` for good, and a
  discard before versus after a reopen is a terminal versus a revert, so the
  property test generates arrival orders under those constraints.
- **A reopen or remove before its target in arrival order** (review round 2
  C-S2, rejected as a supported divergence): another device can learn a target
  id only from the server, where the target is already stored, so server-side a
  remove or reopen always arrives after its target. The only place a target can
  be "not yet seen" is the issuing device's own local view while its target is
  still queued, and §5.5's target wait prevents that. The fold rule
  (`no_target`) exists for local-view determinism; no causal versioning is
  carried.

### 3.5 The `seg` guard with removed laps

For an event `e` with a `seg`, the expected value is
`len(closed_at(e.at)) + |{removed lap boundaries L : L.at < e.at < remove(L).at}|`:
a boundary the tapping device still saw counts. A removed lap is a ghost only if
it would have been a boundary itself (`L.seg == expected_seg(L)` at its turn),
so a removed double tap that was already `stale` adds nothing. Monotonic
stamping (v1 §5.1) guarantees `remove.at > L.at` on the removing device; a
remove with `at ≤ L.at` from another device is `no_target`. **Product
contract:** a tap made offline after `remove.at` by a device that had not yet
seen the remove can be `stale` (it counted the removed boundary); the user
re-taps. Wall-clock order stands in for "had seen", clock skew included; this is
the same class as v1's cross-device double taps, and no causal version travels
with taps.

### 3.6 Late merges (v1 §4.4 updated)

| Late event (arrives after the close)                                                            | Effect                                                                                                                                                                                                                                                |
| ----------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `next`, `lap`, `skip`, `pause`, `resume` with `at ≤ ended_at`, stopped, unedited, entry present | Merged (v1): entry `timing` replaced, revision + 1, entry upsert                                                                                                                                                                                      |
| The same with `at > ended_at`                                                                   | Void `after_stop`                                                                                                                                                                                                                                     |
| **`reopen`** naming the terminal stop, `at > stop.at`, run stopped (entry present) or finishing | **Applied**: the run is open again (§4.1). Exempt from `after_stop` and from `_check_stop_at`                                                                                                                                                         |
| **`remove`** of a pause, lap or reopened stop, run stopped, unedited, entry present             | **Late merge**: timing replaced, entry revision + 1, **`edited` stays false**, late taps keep working. Exempt from `after_stop`                                                                                                                       |
| `remove` on a finishing run                                                                     | Merged into the run (run upsert)                                                                                                                                                                                                                      |
| `reopen` or `remove` on an **edited** run                                                       | Void `run_edited` (the edit wins; an edited run can't be reopened). **Edited means `run.edited`**, set only by a `TimingEdit` (v1 §3.8): a `finish`, a stop with answers, or a `PATCH /entries/{id}` without `timing` never blocks a reopen or remove |
| `reopen` or `remove` on a run whose entry was **deleted**                                       | Void `entry_deleted` (delete = gone for good)                                                                                                                                                                                                         |
| `reopen` or `remove` on a **discarded** run                                                     | Void `already_closed`                                                                                                                                                                                                                                 |
| Any event after an edit, except `finish`/stop-with-answers                                      | Void `run_edited`, no refold (v1)                                                                                                                                                                                                                     |
| `stop` without answers on a stopped run                                                         | Void `already_closed`; with answers: applied as a `finish` (v1)                                                                                                                                                                                       |
| `discard` on a stopped run (terminal present)                                                   | Void `already_closed` (v1); on a **reopened** run: revert (§3.4, §4.1)                                                                                                                                                                                |
| `discard` on a finishing run                                                                    | Applied by the server (v1 §3.7)                                                                                                                                                                                                                       |

**Precedence** (unchanged order, `runs.py:378-398` `_decide`): discarded →
`already_closed`; stopped with entry deleted → `entry_deleted`; stopped and
edited → `run_edited` (except answers); then the fold. The server adds one check
before storing a `reopen` (§4.2: another open run → 409 `conflict`).

## 4. Server write path **[server]**

### 4.1 `_apply_folded` (`runs.py:462-480`) new branches

Let `before = run.status` and `after = fold.status`,
`has_entry = run.entry_id is not None`.

| `before`             | `after`                               | Branch                                                                                                                                                                                                                                                                                                                                                      |
| -------------------- | ------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| open                 | running / paused                      | v1: status follows, run upsert                                                                                                                                                                                                                                                                                                                              |
| open, `!has_entry`   | stopped                               | v1 `_stopped`: `finishing` or `_create_entry` (entry upsert, then `_close`)                                                                                                                                                                                                                                                                                 |
| open, `has_entry`    | stopped, body is a `stop`             | **Re-stop**: entry `timing` = projection, `captured_at = ended_at` (T1), answers/notes/meta from the stop merged as a `finish` would (`update_entry` path, required questions enforced; 422 stores nothing), entry `revision += 1`, entry upsert; run `stopped`, `ended_at` set, `_close` (run delete, **no tombstone**). Never `finishing`: answers exist. |
| open, `has_entry`    | stopped, body is a `discard` (revert) | **Revert**: run `stopped`, `ended_at = fold.ended_at` (the restored stop), `_close`; `_merge_into_entry` (entry upsert only if its timing changed, normally not)                                                                                                                                                                                            |
| open, `!has_entry`   | stopped, body is a `discard` (revert) | A reopened finishing run is thrown away as v1 §3.7 does for a finishing one: `status = discarded`, `_discard` (run delete + tombstone)                                                                                                                                                                                                                      |
| open                 | discarded                             | v1: `discarded`, `_discard`                                                                                                                                                                                                                                                                                                                                 |
| stopped, `has_entry` | running / paused                      | **Reopen**: `status` follows the fold, `ended_at = NULL`, run upsert (the `record_event` revision bump, `runs.py:227`, is enough; the upsert carries it). **The entry stays** (id = run id, timing as of the last stop); nothing is logged for it.                                                                                                          |
| finishing            | running / paused                      | **Reopen** of a finishing run: as above; there is no entry                                                                                                                                                                                                                                                                                                  |
| stopped              | stopped                               | v1 `_merge_into_entry` (covers `remove` late merges)                                                                                                                                                                                                                                                                                                        |
| finishing            | stopped                               | v1: run upsert                                                                                                                                                                                                                                                                                                                                              |

`_close` logs `(run, delete)` only. A new `_discard` logs the delete **and**
tombstones. `_terminal_stop` (`runs.py:533-539`) returns the stop whose id is
`state.terminal_id`.

### 4.2 `record_event` additions

- `remove` requires `target` (`_REQUIRED_FOR`). For `reopen`, `target` MAY be
  null: the server resolves a null target to the run's current terminal stop
  (`state.terminal_id`) and stores the **resolved** id in
  `run_events.target_id`, so the fold always sees an explicit target; with no
  terminal (the run is open or discarded) it stores null and the fold voids the
  reopen `no_target`. Clients send the explicit id whenever they have it
  (`RunState.terminal_id` or `entry.timing.terminal_id`): the ordering rule
  (§5.5) keys on it.
- Before storing a `reopen` on a run that is not open: if the topic has another
  run in `running`/`paused` (`ux_runs_one_open`, models.py:226-234) → 409
  `conflict` ("another run of this topic is open"), nothing stored. Terminal on
  both clients already. The check runs whether or not the fold would apply it.
- `_check_stop_at` applies to stops only (v1); a re-stop more than 7 days after
  `started_at` is 422 `run_too_long` as before: the way out is the revert.
- A `reopen` is accepted on `stopped` and `finishing` runs; on an open run it
  reaches the fold and is `not_stopped`.

### 4.3 Tombstones and the data migration

- `deleted_ids(kind=run)` is written only by a **discard** that leaves the run
  `discarded` and by a topic delete (`topics.py:395-409`, unchanged). A stop
  never tombstones. The run row keeps reserving the id: `is_run_id`
  (`entries.py:147-156`) reads `runs`, `run_aliases` and `deleted_ids`, so
  `createEntry` with a stopped run's id still replays its entry and `start` with
  it is still `event_conflict`.
- Alembic `20261126_e6f3a9b4c215_timers_v2` (down `d5e2f8a3c104`): enum values
  `reopen`, `remove` added to `run_event_type` in an `autocommit_block` (the
  `bb9d821fe436` pattern);
  `ALTER TABLE run_events ADD COLUMN target_id UUID NULL`; data:
  `DELETE FROM deleted_ids WHERE kind = 'run' AND id IN (SELECT id FROM runs WHERE status = 'stopped')`.
  Downgrade drops `target_id` and leaves the enum values in place (Postgres
  can't drop them; the migration says so).
- `changes.py:101-128` changes as §5.1 specifies: a `(run, delete)` log row on
  the page is emitted as a deletion from the log row
  (`deleted_at = ChangeLog.at`) when the run row is closed, and from the
  tombstone when the row is missing. Today the stop's tombstone is what makes
  `_page` emit it; without it the deletion would be dropped (`vanished` without
  a tombstone, changes.py:117-128). **[addition]** to the brief, which lists no
  `changes.py` change.

### 4.4 What is logged per event (research backend.md §2.7 updated)

| Event / outcome                                                        | change_log rows                                                                               | deleted_ids                              |
| ---------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- | ---------------------------------------- |
| start (new run)                                                        | `(run, upsert)`                                                                               | —                                        |
| start merged into the open run                                         | `(run, upsert)` on the target                                                                 | —                                        |
| next/lap/skip/pause/resume/**remove** on an open run (applied or void) | `(run, upsert)`                                                                               | —                                        |
| stop → entry created                                                   | `(entry, upsert)` then `(run, delete)`                                                        | **—** (changed)                          |
| stop → finishing                                                       | `(run, upsert)`                                                                               | —                                        |
| finish / stop-with-answers on finishing                                | `(entry, upsert)` then `(run, delete)`                                                        | —                                        |
| finish / stop-with-answers on stopped                                  | `(entry, upsert)` via `update_entry`                                                          | —                                        |
| discard on open or finishing (no reopen pending)                       | `(run, delete)`                                                                               | `(run, id)`                              |
| **reopen** applied on stopped or finishing                             | `(run, upsert)` (status open, `ended_at` null)                                                | —                                        |
| reopen void on stopped                                                 | nothing (unless the refold changed timing → `(entry, upsert)`); on finishing: `(run, upsert)` | —                                        |
| **re-stop** (stop after a reopen, entry present)                       | `(entry, upsert)` then `(run, delete)`                                                        | —                                        |
| **revert** (discard after a reopen), entry present                     | `(run, delete)`; `(entry, upsert)` only if its timing changed                                 | —                                        |
| revert, no entry (reopened finishing run)                              | `(run, delete)`                                                                               | `(run, id)`                              |
| remove on a stopped unedited run (late merge)                          | `(entry, upsert)`, entry `revision += 1`, `edited` unchanged                                  | —                                        |
| late event void (any reason)                                           | open/finishing: `(run, upsert)`; stopped: nothing                                             | —                                        |
| replay (same id, same content)                                         | nothing                                                                                       | —                                        |
| topic delete                                                           | one `(topic, delete)`                                                                         | all children incl. runs and aliases (v1) |

### 4.5 Entry revision rules

The entry's `revision` increases on: the re-stop; a late merge (`remove` or a v1
late tap) that changes `timing`; `finish`/answers; a revert whose timing changed
(it normally doesn't). It does not change on the reopen itself. `captured_at`
always equals `timing.ended_at` (T1): after a re-stop it moves to the new end.
`runs.edited` is set only by `TimingEdit` (v1 §3.8) and never by `remove`.

### 4.6 `after_run_event` for reopen

An applied, non-replayed `reopen` calls
`live_activity.notify(run_id, topic_id, device, created=True)`: push-to-start
tokens get a `start` (the activity was ended and its update tokens dropped at
the stop, `live_activity.py:348-358`), except the originating device's when its
`device.live_activity` is true (it requested its activity locally, as for a
start). Re-stop and revert push `end` as any close.

## 5. Feed and the clients' stores

### 5.1 Two kinds of run deletion

A `run` feed deletion has **always** meant "the run left the live set" ("no
longer open or finishing", v1 §2.4, api.py `FeedDeletion`), never entity
deletion. v1 happened to tombstone on both; v2 names the two and keeps the
permanent tombstone only for the second:

| Kind        | When                                                           | Server row                | `change_log`                            | `deleted_ids`         | Reversible                                                                    |
| ----------- | -------------------------------------------------------------- | ------------------------- | --------------------------------------- | --------------------- | ----------------------------------------------------------------------------- |
| **closed**  | A stop made an entry (or a re-stop, or a revert with an entry) | stays, `status = stopped` | `(run, delete)`                         | none                  | yes: a `reopen` logs `(run, upsert)` with a later seq and a higher `revision` |
| **deleted** | A discard, or a topic delete                                   | stays `discarded` / gone  | `(run, delete)` / one `(topic, delete)` | `(run, id)` permanent | no: the server never upserts it again                                         |

The wire doesn't distinguish them (both are `FeedDeletion {kind: run}`); the
guarantee clients rely on is that a **deleted** run never upserts again, while a
**closed** one may.

**Feed emission (`changes.py`).** A `(run, delete)` log row on the page is
emitted as a deletion when the run row exists and is not live (`stopped` or
`discarded`: from the log row, `deleted_at = ChangeLog.at`), or when the row is
missing **and** tombstoned (topic delete: from the tombstone, at the run's
latest row on the page, v1 §7.1). A missing, untombstoned run row cannot occur:
`delete_topic` tombstones every child before the cascade (`topics.py:395-409`).
A closed run without its own delete row on the page is skipped, as v1 §7.1
requires, so its entry's row is never behind its deletion. A `run` deletion
carries **`revision`** (§5.2). **Topic cascade:** one topic deletion; clients
cascade locally and tombstone the runs (they are deleted, not closed).

**Paginated replay (current state at read time).** `_page` emits by the run's
state **in the snapshot**, never its state at each log row
(`changes.py:101-109`): the latest row for a run on the page decides whether the
run is on the page, the run's current row decides _as what_. A page whose latest
row for a run is an upsert while the run is now closed emits nothing (the run is
`closed` and skipped; its delete row is on a later page). A page whose latest
row is a delete row while the run is now open again emits the **item**, at its
current revision. No historical state is needed: later pages carry the final
state, and both outcomes are idempotent for the client (an item for a run that
is open, a deletion for one that is closed). T27 pins both cuts: stop → reopen →
re-stop split every way (the middle page emits nothing), and stop → reopen split
with the run open at read time (the first page emits the item).

**sync-protocol.md F2/F3 (docs commit in M1-FEED's scope).** The shipped rows
(`sync-protocol.md:114-115`) are replaced by these sentences, copied verbatim:

> **F2** An entity that no longer exists in the snapshot is emitted in `deleted`
> **only if its id is in `deleted_ids`**; otherwise it is skipped, because its
> own delete row comes later (§6a rule 4). **Exception, runs:** a run whose row
> still exists but is not live (`stopped` or `discarded`) is emitted in
> `deleted` when its own `(run, delete)` row is on the page, from that log row.
> A `run` deletion therefore means **closed** ("no longer open or finishing"),
> not that the id is gone; a later `run` upsert of the same id (a `reopen`,
> timers2.md §5) is valid and clients MUST apply it under the revision rules of
> timers2.md §5.2.
>
> **F3** Every deleted entity of every kind (entry, topic, version and run) is
> in `deleted_ids` permanently, **except a run that merely stopped**: only a
> discarded run, or a run deleted with its topic, is tombstoned; a stopped run
> keeps its row, which still reserves its id (`is_run_id`). A topic delete puts
> its child entries, versions and runs into `deleted_ids` **before** the
> foreign-key cascade (§6a rule 3), so their ids stay reserved; the runs' alias
> ids are reserved too, under kind `run`, but an alias has no change-log row of
> its own, so it is never emitted. A `run` deletion carries **`revision`**: the
> run's revision in the page's snapshot, or null when the row is gone (topic
> cascade). **Incremental** pages emit only the topic's own deletion, and the
> client cascades to the children locally (§4.3 step 2). A **bootstrap** from
> `after=0` emits every child deletion explicitly, a `run` deletion (with
> `revision`) for every closed run whose latest log row is its delete row, and
> an item for every run that is open or finishing in the snapshot, whatever its
> history.

Consumer tests named by that commit: backend T27 (bootstrap and incremental
deletions carry `revision`; a topic-cascade run deletion carries null; the two
page cuts); iOS R25 (apply order: deletion then upsert across pages, bootstrap
deletion fences a delayed upsert) and R14 (the §4.2 upsert guards with markers);
the PWA has no feed consumer (its `listRuns` path is §5.2's [pwa] paragraph).
sync-protocol.md's own test table gains one row per sentence above.

### 5.2 Resurrection rule and the durable fence (every client)

**The fence: `FeedDeletion.revision: int | null`** (additive, §7.1). For a `run`
deletion emitted from a log row it is **the run's `revision` in the page's
snapshot**: `_page` runs in one REPEATABLE READ snapshot (`changes.py:50-56`)
and reads the run row from it. It is not a stored "revision at close" (the log
row stores none, and a stopped run's revision keeps rising with late events and
removes, `runs.py:227`); it is whatever the row says at read time, which is at
least the revision at close. It is null for a topic-cascade run deletion (the
row is gone) and for every other kind. Bootstrap pages carry it too. A client
needs no local row to fence a deletion against delayed upserts.

**Why the snapshot revision bounds every upsert the client can still receive.**
Every stored event bumps `run.revision` by exactly one (`runs.py:227`, `:345`),
closes included; `change_log.seq` order is commit order (area B §1, `feed.py`);
so revision is monotonic in time for one run, and a higher revision is always a
newer state. Then: (i) a feed upsert on an **earlier** page carries the run as
of that page's snapshot, whose revision is ≤ the later page's snapshot revision,
and strictly less when the run closed in between (the close bumped it); (ii) an
**ack** of an event processed **before** the close carries a revision < the
close's revision ≤ the snapshot revision; (iii) an ack processed **after** the
close either carries a closed state (a late merge on a stopped run) or is an
applied `reopen` with a revision above the fence: the first only raises the
fence, the second is the resurrection the fence must let through. Late events on
a stopped run raising `run.revision` therefore only ever **raise** the fence: a
deletion emitted later (another page, a bootstrap) carries a higher revision and
still bounds everything older.

**Markers.** A client MUST NOT keep a permanent tombstone for a `run` deletion.
It deletes the row and the run's alias rows and keeps a **non-permanent,
revision-aware marker** `run_closed(id, revision)`:

| Source of the close                                                     | `marker.revision`                                                                                               |
| ----------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| a feed `run` deletion with `revision`                                   | that revision                                                                                                   |
| a feed `run` deletion with `revision: null` (topic cascade)             | ∞ (permanent; the topic tombstone covers it as well)                                                            |
| an ack whose `RunOut.status` is closed (stop, re-stop, discard, revert) | `response.run.revision`                                                                                         |
| the run's aliases (`run.aliases`, at every close)                       | ∞ (an alias never becomes a run of its own; a resurrected run's `aliases` re-insert alias **rows**, never runs) |

**Apply rules: revision ordering applies to every run state from every source,
closed states included.** Let `local` be the run's local row, or its marker when
it has none.

- An **upsert** (a feed item, or an ack whose `RunOut.status` is open or
  finishing) applies iff `run.revision > local.revision`; against a **marker**
  an ack additionally requires that the acked event is an applied `reopen` (a
  delayed ack of an older tap can never reopen a run). Applying an upsert clears
  the marker. Once a row exists this is the revision guard of sync-protocol.md
  §4.2.
- A **close** (a feed `run` deletion, or an ack whose `RunOut.status` is
  `stopped` or `discarded`) against a **row** applies, deleting the row and
  writing the marker, iff `close.revision > row.revision`; otherwise it is a
  no-op apart from acking the item (the local row is newer: a reopen already
  happened, and a delayed stop ack or an older feed page must not erase it).
- A close against a **marker** raises it to `max(marker, close.revision)`.
  **Every marker write is `max(existing, new)`: a marker is only ever raised,
  never lowered**, whatever its source (feed deletion, closing ack, migration,
  alias rule).
- Markers prune after **30 days** (the ∞ ones too: they are redundant with the
  topic tombstone and with the server never upserting an alias id as a run).

Tests pin both arrival orders: a delayed stop ack after a reopen upsert (no-op,
the run stays open) and an older feed deletion applied after a newer ack (no-op)
(R24, R25, §12.4).

**Lifetime invariant (why migrated 0 markers, pruning and rebuilds are safe).**
Three mechanisms already in the iOS contract, cited exactly:

1. **Fence check.** Every transaction that applies a network outcome begins with
   the fence check of sync-protocol.md §5.5:
   `sync_state.layer_gen = ctx.layer_gen` for everything that writes the server
   layer or outbox state, and for outbox outcomes a valid `flush` lease with a
   matching `claim_token`. "If the fence fails, the outcome is **discarded
   entirely**." The `t2m1_run_closed` migration **increments
   `sync_state.layer_gen`** in its own transaction, so no response to a request
   claimed or started before the migration is ever applied after it (a page in
   flight across the migration is discarded and re-pulled). An epoch rebuild's
   swap increments `layer_gen` as well (sync-protocol.md glossary, "Layer
   generation"), with the same effect.
2. **Request lifetime.** An outbox request times out after **15 s** (outbox.md
   §4, "Timeout is 15 s per request, capped by the remaining budget"); a feed
   page request after **30 s** (sync-protocol.md §1.1, "The request timeout is
   30 s"). Both run under leases: `flush` TTL 30 s, renewed per claim (outbox.md
   §6.1), `sync` TTL 60 s (sync-protocol.md §5.3).
3. **Relaunch.** Lease time is `(boot_id, ct)`; a different boot id means the
   deadline has passed (outbox.md §4, "Lease time"). Expiry recovery moves every
   `in_flight` item to `uncertain` with `maybe_delivered = 1` and clears its
   claim fields, "so the old holder's sender check now fails" (outbox.md §6.3).
   The re-sent request is an idempotent replay (v1 §3.2) whose response reflects
   the server's **current** state, which the revision rules above order
   correctly.

Therefore: (a) a 0 marker written by the migration for a run under a live topic
can only be beaten by an upsert applied after the migration, which by (1) was
issued after it and by (3) reflects current state: an open run with revision ≥ 1
(a real reopen) or a closed one (which raises the marker); (b) pruning a marker
after 30 days is safe: by (2) and (3) no outcome older than a lease TTL plus a
request timeout (≤ 90 s) is ever applied, and any upsert that arrives after the
prune reflects current state; (c) an epoch rebuild replaces the marker set from
the staged bootstrap's deletions (which carry `revision`) and discards, by (1),
every outcome from the previous layer generation. The PWA has no generations or
leases and no migration (its markers are in-memory per session); it relies on
the revision ordering alone, which the bound above guarantees.

**Migration `t2m1_run_closed`** (new file `StoreSchema+T2M1.swift`; registration
line added at merge time), one transaction:
`CREATE TABLE run_closed (id TEXT PRIMARY KEY, revision INTEGER NOT NULL, closed_at TEXT NOT NULL)`
plus its `stage_` copy; every existing `tombstone` row of kind `run` is
**converted** to a marker and deleted: revision **∞** when the row's `topic_id`
is itself tombstoned (kind `topic`: deleted with its topic, permanent), else
revision **0** (a legitimate reopen upsert carries revision ≥ 1 and wins; the
server never upserts a discarded run or an alias id as a run, so a 0 marker on
one of those is harmless); the same on the `stage_` tables; then
`UPDATE sync_state SET layer_gen = layer_gen + 1` (invariant 1). Tombstone rows
do not record whether an id was an alias, so alias ids of live topics get 0 like
runs; that is safe for the reason just given.

The topic cascade still **tombstones** the topic's runs (they are deleted, not
closed); `upsert(run:)` also checks the topic tombstone
(`ServerLayer.swift:78-81`).

- **[ios]** `ServerLayer.applyDeletion(.run)` (`ServerLayer.swift:182-192`)
  writes the marker from `deletion.revision` (∞ when null) for the run id and ∞
  for its aliases instead of tombstones, and deletes the `run` and `run_alias`
  rows; `upsert(run:)` applies the marker rules and re-inserts the aliases from
  `run.aliases`; the ack path (`ServerLayer.apply(runEvent:)`,
  `ServerLayer.swift:108-124`) writes the marker from `response.run.revision` on
  a close and passes the acked event's type and effect on an upsert. Epoch
  rebuilds stage markers like other tables. Dependent-items rule unchanged:
  queued `run.event` items of a closed run are kept and sent (v1 §7.2).
- **[pwa]** The PWA has no feed; it learns a close from its own responses and
  `src/api/runs.ts` already keeps the closing revision (`tombstones` by
  revision, `buried` compares `>=`, runs.ts:26-45). M1 adds the ack rule
  (`upsertServerRun` un-buries an id only for an applied `reopen` response) and
  the resurrection tests, and keeps the alias rule (`Infinity`).

Tests: R24 (delayed pre-close ack; a delayed stop ack after a reopen upsert),
R25 (feed delete then reopen upsert across pages; an older feed deletion after a
newer ack; bootstrap with `revision`), R27 (migration conversion; `layer_gen`
bump fences a request started before the migration; epoch rebuild).

### 5.3 "Entry hidden while its run is open" (OQ-14 default)

An entry whose id is a **locally open or finishing run** is not shown as an
entry; the run represents it. **[ios]** `StoreView.entries(...)` and
`latestEntry` exclude ids in `openRuns ∪ finishingRuns` of the local view;
**[pwa]** `EntriesPage`/`lastEntry` filter by `localRuns`. Counts
(`entry_count`), due state, stats and CSV are **unchanged**: the entry exists
and its timing is valid as of its last stop; the re-stop corrects it. The
reopened run's optimistic entry (v1 §8.3) is not projected again: the server
entry already exists.

`createEntry` with a reopened run's id: `_existing` (`entries.py:134-144`)
replays the entry, unchanged.

**Offline, from an entry.** A `reopen` or `remove` enqueued from an entry when
no run row is local (after a relaunch, on another device, or on the PWA past the
10-minute acked window) takes its `target` from the entry's `timing`
(`terminal_id`, `segments[].event_id`, `pauses[].id`, §3.3; `target: null` from
a pre-v2 timing).

- A **`reopen`** projects a local run in state **resuming**, built from the
  entry's timing: closed segments = the timing's segments, pauses = its pauses,
  status `running`, the last segment open again from its start, and the gap
  from the stop to the reopen a pause carrying the stop's id, as the fold makes
  it (so the projection does not jump when the ack lands). The entry is hidden
  as above. Clients MAY show "Resuming…"
  without controls until the ack replaces the projection with the server's
  `RunOut`.
- A **`remove`** projects **no run**: the entry stays visible with its timing
  re-projected (the boundary or pause dropped, laps renumbered), its `revision`
  unchanged, and a pending mark until the ack replaces it with the server's
  entry.

The ack paths are unchanged. **Resume is hidden while the topic has a locally
open run** (the server would answer 409 `conflict`, terminal on both outboxes,
and the intent would be lost without a notice).

**Revert of a reopened finishing run, locally.** The fold says `stopped` (the
terminal is restored) while the server discards (§4.1). Clients special-case a
`discard` queued after a `reopen` on a run that has no entry (`statusOf` on the
PWA, `RunOverlay` on iOS): the run is shown as discarded and **no optimistic
entry** is projected (R15, §12.4).

### 5.4 Bootstrap

Bootstrap pages still emit a `run` deletion for every closed run whose latest
log row is its delete row; harmless. A run that is open at the snapshot is an
item, whatever its history (stopped, reopened).

### 5.5 Outbox: ordering and replay

`reopen` and `remove` are `run.event` items. **Ordering rule (decision):** each
waits for the run's start (through aliases, as every event does) **and for the
queued item whose id equals its `target`**, when one is still pending: a reopen
waits for its stop as a finish waits for the run's stops (v1 §8.1), a remove
waits for the pause or lap it names. A failed target doesn't hold them (the
server answers `no_target`). **And an event enqueued after a pending `reopen` of
the same run waits for that reopen** (the precedent is a finish waiting for the
run's stops, `kinds.ts:160-169`): otherwise a retrying reopen would let a later
lap reach a still-stopped server run and come back `after_stop` with a notice,
only to flip to applied when the reopen lands. **A reopen also waits for its
run's pending `finish` enqueued before it**, so a retrying finish is not
overtaken and refused with 409 `run_open` (milestone review P2-1). Both outboxes
implement these rules: the PWA in `kinds.ts` `waitsFor` (`kinds.ts:142-170`), iOS as two more
cases of the outbox.md §7.1 extension in v1 §8.1. Cases
`lap-waits-for-pending-reopen` on both (R16, §12.4). No new coalescing. A
`target` is the id of an event in the local view (queued or acked) or in the
entry's `timing` (§3.3, §5.3). Classification is v1 §8.1's; the new void reasons
are acks with notices (§9.3). **K6 MUST NOT apply when the run's queued items
contain a `reopen`:** that discard is a revert (§3.4), and dropping the queue
would also drop the stop the user chose to keep and its optimistic entry; the
discard is appended and sent. K6 otherwise still drops a never-sent run as a
whole, remove items included. Cases `k6-not-on-revert` on both outboxes (R16,
§12.4). Request goldens `recordRunEvent.reopen.json`,
`recordRunEvent.remove.json` (G2).

## 6. Worked examples

Times are offsets from `T0 = 2026-11-25T10:00:00Z`; ids are short names. The
timer is `none` unless stated. "Feed" lists change_log rows in seq order.

### 6.1 Accidental stop (reopen, re-stop)

| #   | id  | type   | at   | target / seg | effect                     |
| --- | --- | ------ | ---- | ------------ | -------------------------- |
| 1   | R   | start  | 0:00 | —            | applied                    |
| 2   | e1  | lap    | 1:00 | seg 0        | applied                    |
| 3   | e2  | stop   | 1:30 | —            | applied (terminal until 5) |
| 4   | f1  | finish | 1:35 | answers      | applied (server-decided)   |
| 5   | e3  | reopen | 1:50 | target e2    | applied                    |
| 6   | e4  | lap    | 2:30 | seg 1        | applied                    |
| 7   | e5  | stop   | 3:00 | —            | applied (terminal)         |

After #3: segments `Lap 1 0:00–1:00`, `Lap 2 1:00–1:30`; entry `R` revision 1,
`captured_at 1:30`, `active_ms 90 000`. #4 (the answers sheet) patches the
entry's answers: revision 2, `run.edited` still false, so #5 is still accepted
(§3.6: only a `TimingEdit` blocks a reopen). After #5: status `running`,
`open = Lap 2 (index 1, started 1:00)`, `paused_since` null, `terminal_id` null,
`pauses = [1:30–1:50]` (the gap resume role ran at 1:50). After #7:
`Lap 1 0:00–1:00 (60 000)`, `Lap 2 1:00–2:30 (active 70 000, paused 20 000)`,
`Lap 3 2:30–3:00 (30 000)`; `pauses [1:30–1:50]`; entry revision **3**,
`captured_at 3:00`, `active_ms 160 000`, `paused_ms 20 000`, answers from #4
kept. With timer `renamed` the labels are Cig 1..3.

Feed: #3 `(entry R upsert)`, `(run R delete)`; #4 `(entry R upsert)`; #5
`(run R upsert)`; #6 `(run R upsert)`; #7 `(entry R upsert)`, `(run R delete)`.
`deleted_ids`: nothing.

Clients: at #3 the tile shows "Saved 1:30" with **Resume** (resumable, OQ-1),
still offered after #4; at #5 the run is open again (entry R hidden), the Live
Activity returns (locally on the device that tapped, push-to-start elsewhere);
at #7 entry R reappears with the new times.

### 6.2 Reopen then revert by discard

| #   | id  | type    | at   | target / seg | effect                        |
| --- | --- | ------- | ---- | ------------ | ----------------------------- |
| 1   | R   | start   | 0:00 | —            | applied                       |
| 2   | e1  | stop    | 1:30 | —            | applied (terminal)            |
| 3   | e2  | reopen  | 1:50 | target e1    | applied → **reverted** at 5   |
| 4   | e3  | lap     | 2:10 | seg 0        | applied → **after_stop** at 5 |
| 5   | e4  | discard | 2:30 | —            | applied (revert)              |

After #5: `terminal = e1`, status `stopped`, `ended_at 1:30`, segments
`Lap 1 0:00–1:30`; entry revision stays **1** (timing unchanged). Feed: #2 entry
upsert, run delete; #3 run upsert; #4 run upsert; #5 `(run R delete)`. No
tombstone: the run is `stopped`, not discarded, and can be reopened again.
Clients: "Saved 1:30" again; the entry is visible. The `reverted` notice (§9.3)
is shown on the device that made the reopen when the discard came from another
device; the discarding device shows nothing (it did what it asked). Both actors
are covered by a two-device notice test (R16, §12.4).

### 6.3 Remove a pause; remove the gap pause after a reopen

(a) Open run: `start 0:00`, `p1 pause 1:00`, `r1 resume 1:20 (pause_id p1)`,
`e1 lap 2:00 (seg 0)`, `x1 remove 2:10 (target p1)`. After `x1`: `p1` and `r1`
are void `deleted`, `pauses []`, `Lap 1 0:00–2:00 active 120 000`. Run upsert
each time.

(b) `start 0:00`, `S stop 1:00`, `R1 reopen 1:30 (target S)`,
`x2 remove 1:40 (target S)`. After `x2`: `S` void `deleted` (pass 1, §3.4; the
stop stays reopened: `R1` applied, terminal null), no gap pause, the open
segment runs since 0:00 with `paused_ms 0`; the clock shows 1:40 at 1:40. A
later `stop 2:00` closes `Lap 1 0:00–2:00 (120 000)` with no pauses; entry
revision 2. Had a `discard 1:50` come instead, the revert restores `S` to
`applied` (terminal, `ended_at 1:00`) and voids `x2` `no_target`.

### 6.4 Remove a double-tapped lap in a run/rest cycle (timer `tiktok`)

| #   | id  | type   | at     | target / seg | effect                  |
| --- | --- | ------ | ------ | ------------ | ----------------------- |
| 1   | R   | start  | 0:00   | —            | applied                 |
| 2   | e1  | lap    | 1:00   | seg 0        | applied                 |
| 3   | e2  | lap    | 1:00.4 | seg 1        | applied → **deleted**   |
| 4   | e3  | lap    | 2:00   | seg 2        | applied (stays applied) |
| 5   | x1  | remove | 2:05   | target e2    | applied                 |
| 6   | e4  | lap    | 2:30   | seg 2        | applied                 |

Before #5: `Run 1 0:00–1:00`, `Rest 1 1:00–1:00.4`, `Run 2 1:00.4–2:00`, open
`Rest 2`. After #5: `e2` is a ghost `(1:00.4, 2:05)` (at its turn closed = 1 and
its seg 1 matched); `e3` expected seg = 1 + 1 = 2 ✓; segments `Run 1 0:00–1:00`,
`Rest 1 1:00–2:00`, open `Run 2` (lap 3 → type `laps[2 mod 2] = run`, ordinal
2), `next_lap_type = rest`, `lap_count 2`. #6: the device saw two closed laps →
seg 2; expected = 2 + 0 ✓ → opens `Rest 2`. The rhythm is restored.

### 6.5 Remove a lap on a stopped run from the entry (timer `renamed`)

Stopped run, entry revision 1: `Cig 1 0:00–1:00`, `Cig 2 1:00–1:05`
(accidental), `Cig 3 1:05–3:00`, `stop 3:00`. From the entry detail the user
removes `Cig 2` "into the previous": the client sends `remove(target = e1)` (the
lap at 1:00 that **opened** Cig 2) at 3:40. The run is stopped, unedited, with
its entry → late merge: `Cig 1 0:00–1:05`, `Cig 2 1:05–3:00`; `timing` replaced,
`captured_at` unchanged (3:00), entry revision **2**, `edited` **false**,
`(entry, upsert)`, no run row. Re-derived with §3.4: `e1` is removed; at its
turn `closed = 0` and its `seg 0` matches → ghost `(1:00, 3:40)`, void
`deleted`; `e2` (1:05, `seg 1`) expects `0 + 1 = 1` ✓ → closes Cig 1 at 1:05. A
late lap `b1` from another device at 2:00 with `seg 2` then arrives at 3:50:
expected = 1 closed + ghost(1:00 < 2:00 < 3:40) = 2 ✓ → applied, a further late
merge: `Cig 1 0:00–1:05 (65 000)`, `Cig 2 1:05–2:00 (55 000)`,
`Cig 3 2:00–3:00 (60 000)`, `captured_at 3:00`, entry revision **3**. Vector
`remove-lap-after-stop-then-late-lap`. "Into the next" would have sent
`remove(target = e2)` (the lap at 1:05).

### 6.6 Two devices: offline lap inside the gap

A: `start 0:00`, `a1 lap 1:00 (seg 0)`, `a2 stop 2:00` → entry revision 1,
`Lap 1 0:00–1:00`, `Lap 2 1:00–2:00`. B, offline, tapped `b1 lap 2:10 (seg 1)`;
it arrives at 2:20 → `after_stop`, nothing logged (void on a stopped run). A
reopens at 2:30 (`a3 reopen, target a2`) → refold: `end = ∞`; `b1` at 2:10 has
expected seg 1 ✓ → applied: closes `Lap 2` at 2:10 (paused 2:00–2:10 inside it),
opens `Lap 3` at 2:10 (paused until 2:30). `b1`'s effect flips from void to
applied in `RunOut.events`; `(run, upsert)`. A re-stops at 3:00:
`Lap 1 0:00–1:00 (60 000)`, `Lap 2 1:00–2:10 (active 60 000, paused 10 000)`,
`Lap 3 2:10–3:00 (active 30 000, paused 20 000)`, `pauses [2:00–2:30]`, entry
revision 2. B's notice for `after_stop` was shown at 2:20 and is not retracted.

### 6.7 Offline replay: reopen behind a blocked start

Device offline: queued `R start 0:00`, `s1 stop 1:00`,
`r1 reopen 1:20 (target s1)`, `l1 lap 1:40 (seg 0)`. The local view folds all
four: an open run since 0:00 with a gap pause 1:00–1:20. (a) The start is
refused on first contact (409 `topic_archived`) → `failed/rejected`; `s1`, `r1`,
`l1` wait for it (`waitsFor` = the start) and nothing is sent. Discarding the
failed start discards them (`discardedWith`); retrying it after unarchiving
sends all four in seq order: start 201, stop 200 (entry), reopen 200 applied
(run upsert), lap 200 applied. (b) The start succeeds but `s1` is retrying
(5xx): `r1` waits for `s1` (its `target`, §5.5) and `l1` waits for `r1` (it was
enqueued after a pending reopen, §5.5), so nothing of this run goes until `s1`
is acked; then `r1`, then `l1`, each applied, and no other device ever sees the
lap without the gap. Items of other runs and topics are unaffected. A tap
enqueued **before** the reopen (none here) would go ahead as in v1. (c) `s1` is
refused 422 `before_start` (a clock jump) → `s1` failed; a failed target holds
nothing, so `r1` goes: `no_target` (no such stop) → notice "nothing to resume".
The server's run is open since 0:00 with no gap; the local view, which leaves
failed items out of the fold (v1 §8.3), shows the same.

## 7. API **[server]**

### 7.1 Schema diffs

```
RunEventIn.type  : + "reopen" | "remove"
RunEventIn.target: UUID | null      // required for remove; for reopen null = "the current terminal" (§4.2)
RunEventOut      : + target: UUID | null   // the resolved id
VoidReason       : + "reverted" | "not_stopped" | "deleted" | "no_target"
RunOpenSegment   : + lap_type: str | null
TimingSegment    : + lap_type: str | null, event_id: UUID | null,  // the event that opened it (§3.3)
                     opened_by: "start" | "next" | "lap" | "skip" | null
TimingPause      : + id: UUID | null                               // the pause event; a gap pause: the stop's id
Timing           : + terminal_id: UUID | null                      // null only on pre-v2 stored timings (§3.3)
RunState         : + terminal_id: UUID | null, next_lap_type: str | null, lap_count: int
FeedDeletion     : + revision: int | null                          // run: the revision at close; null for topic-cascade and other kinds (§5.2)
Timer            : + laps: LapType[], variables: Variable[]; Step + alerts: Alert[]   (§1.1)
Limits           : + max_steps, max_lap_types, max_variables, max_alerts, max_expr_length,
                     max_var_name_length, max_short_label_length
TopicTiming      : + lap_types: [{key, label, laps, best_ms, median_ms, mean_ms}]
TimingSeriesPoint: + lap_types: {key: active_ms}
```

`RunEventIn`'s validator: `answers`/`notes` only on stop and finish (v1);
`target` only on reopen and remove (422 otherwise), required for remove.
`run_events.target_id` stores the resolved id. `timing_json`/`timing_from_json`
and `TimingEdit`'s rebuild carry the ids (null after an edit, §3.3).

### 7.2 Errors

| Status | Code              | When                                                                                                                                                                                                                      |
| ------ | ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 409    | `conflict`        | `reopen` while the topic has another open run (nothing stored); `PATCH /entries/{id}` with `timing` while the entry's run is `running`, `paused` or `finishing` (the reopened run owns its times; edit after the re-stop) |
| 422    | `invalid_request` | `target` missing for remove, or present on a type other than reopen/remove; v2 `Timer` validation (§1.3, dotted paths)                                                                                                    |
| 422    | `run_too_long`    | A re-stop more than 7 days after `started_at` (v1 rule; the revert is the way out)                                                                                                                                        |
| 422    | `before_start`    | A re-stop before `started_at` (v1)                                                                                                                                                                                        |

No new codes. `no_target`, `not_stopped`, `reverted`, `deleted` are void reasons
(200), not errors.

### 7.3 MCP

| Tool                                     | Change                                                                                                                                                  |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `run_action(run_id, action, …, target?)` | `action` gains `reopen` (`target` defaults to `state.terminal_id`; `InvalidRequest` "the run isn't stopped" when null) and `remove` (`target` required) |
| `create_topic`, `publish_topic_version`  | accept the v2 `Timer`                                                                                                                                   |
| `check_topic_version`                    | gains `timer: Timer                                                                                                                                     | None`(passed through as REST's`with_timer`) |
| `get_run` (new, small)                   | `getRun` by id, so an agent can read `terminal_id` of a stopped run (`list_runs` lists open/finishing only). **[addition]**                             |

`INSTRUCTIONS` (mcp_server.py:61-86), replace the timer paragraphs with:

> A topic is timed when its current version has a `timer`:
> `{steps: [{key, label, alerts}], laps: [{key, label, alerts}], variables: [{name, ms}]}`.
> No steps is a plain stopwatch. `laps` names lap types: one renames laps ("Cig
> 1, Cig 2"), two or more cycle ("Run 1, Rest 1, Run 2"). An alert fires when a
> step's or lap's active time reaches `at`, an expression over the variables
> (`t/2`, `t+30s`); the server fills `at_ms`. `publish_topic_version` requires
> `timer`: pass the current version's to keep it, or null for untimed.
>
> Timing: `start_run`, then `run_action` for each tap (next, lap, skip, pause,
> resume, stop), acting on what is open now. A stop makes the entry, or leaves
> the run `finishing` when required questions are unanswered: `run_action`
> finish with the answers then makes it. A stopped run can be resumed with
> `run_action` reopen (the gap becomes a pause); `run_action` remove with the id
> of a pause or lap event deletes it (a lap merges into the previous segment);
> discard after a reopen reverts it. `list_runs` shows open and finishing runs;
> `get_run` any run. A stopped run's times can also be replaced with
> `edit_run_timing`, after which late taps are ignored.

### 7.4 `getTopicTiming` additions

`lap_types[]`: one row per lap-type key seen in range (current version's types
in order, then historic ones), `label` from the latest version that has the key,
`laps` = count of lap segments of that type over every timed run,
`best/median/mean_ms` over those segments' `active_ms` (floor rules of v1 §9.1).
`laps` (the v1 single bucket) is unchanged. `series[].lap_types` sums
`active_ms` per type per run. Untyped laps (`lap_type` null) contribute only to
`laps`. `lap_types[]` and `steps[]` are keyed **separately**: the shared key
namespace of §1.1 is per timer, not per topic, so a lap-type key equal to a
historic step key of an older version does not join that step's bucket (and vice
versa). `timing-stats-vectors.json` `GENERATOR_VERSION 2 → 3`, new cases
`lap_types_one`, `lap_types_cycle`, `lap_types_renamed_across_versions`,
`lap_types_untyped_mixed`, `lap_types_in_series`. M4 consumes these.

## 8. Live Activity **[ios]** **[server]**

### 8.1 Content state additions (`CONTENT_STATE_VERSION` stays 1)

All optional, so an installed build decodes a v2 push:

```
lap_type:    String?    // the open (or last) segment's lap type key
lap_count:   Int?       // closed laps
next_label:  String?    // v1 field, now also set in a lap: the next lap type's label (null if untyped)
alert_at:    Double?    // next alert instant (server clock, seconds) for the open segment; null while paused or when none remain
alert_label: String?    // its label (≤ 64)
```

No `terminal_id` in the content state: Resume is never offered from the activity
(active-surfaces.md §4.4), so the field would have no consumer.

`alert_at = seg_started_at + paused_ms_in_seg + a.at_ms` for the first alert `a`
of the open segment's step or lap type with `a.at_ms > active_in_seg_now` (at
send time), ordered by `at_ms` then position; null when paused, when the segment
has no alerts, or when all have passed. The Live Activity shows
`Text(timerInterval: now...alert_at, countsDown: true)` and `alert_label`; it
cannot sound.

### 8.2 Vectors

`live-activity-vectors.json` `GENERATOR_VERSION 2 → 3`; `step_sets` →
`timer_sets` (as §3.1 plus `long`). New cases: `update_tiktok_lap`,
`update_alert_pending`, `update_alert_paused`, `start_renamed_laps`,
`update_reopened` (an `update` for a run whose events include stop + reopen:
`paused_ms_in_seg` includes the gap). `update_tiktok_lap` MUST pin a typed lap
with `next_label` set ("Rest") and `step_index` null: `RunActivityDisplay` can
no longer derive "this is a lap" from `next_label == nil`; it reads
`step_index == nil` (and `lap_type`).

**Byte budget on the encoded body [server].** The payload carries no step or
lap-type list (v1 §10.3), only one `label`, one `next_label`, one `alert_label`
and `attributes.topic_name`, each ≤ 64 characters; but character limits do not
bound bytes (a 64-character label can be 256 UTF-8 bytes, and JSON escapes for
`"`, `\` and control characters grow it further). So the server enforces the
limit on the **encoded** APNs body (`encode`, `live_activity.py:199-205`): if it
exceeds 4 096 bytes it truncates, one field at a time and in this order,
`alert_label`, then `next_label`, then `label`, then `attributes.topic_name`,
each to 32 characters, re-encoding after each step and stopping as soon as the
body fits. **Terminal step:** if the body still exceeds 4 096 bytes with all
four at 32 characters (only with pathological content: every character a 4-byte
code point or a 6-byte `\uXXXX` escape), set `next_label` and `alert_label` to
null and `attributes.topic_name` to `""`; the body is then bounded by the fixed
fields. Worst case of what remains, for a `start` (the largest event): every key
and separator (~620 bytes), three 36-character UUIDs (`run_id`, `topic_id`,
`server_id`), `revision` and the five ms counters at 10 digits, three Doubles at
17 characters, `status` ≤ 10, `lap_type` ≤ 63 ASCII, `label` ≤ 32 × 6 = 192
bytes and `alert.body` (= `label`) another 192: **under 1 800 bytes**, so the
fit is guaranteed with a 2 KB margin; the generator computes the exact figure
and asserts it. M3's `attributes.appearance` counts against the same budget and
MUST fit in that margin (appearance.md states its cap and re-runs both vectors
with it set). Vectors: `start_longest_labels` v2 (all four at 64 multibyte
characters, fits without truncation), `payload_budget_truncation` (all four at
64 four-byte code points plus JSON-escaped characters: the expected truncation
steps and the final body ≤ 4 096 bytes) and `payload_budget_terminal` (every
character a `\u001f` escape: the terminal step fires and the asserted
fixed-field size holds).

### 8.3 Push-to-start on reopen

§4.6: an applied reopen is a `start` push to push-to-start tokens (except the
originating device with `live_activity: true`). `register`
(`live_activity.py:225-264`) keeps an update token for a run that is open again.
`RunActivityPlan` requests an activity locally for a reopen this device made
(`startFor`), as for a start.

## 9. Alerts

### 9.1 iOS **[ios]**

`QuickrData/Notifications/RunAlerts.swift`: a pure planner plus a scheduler.

- **Plan**
  `RunAlertPlan.requests(run: LocalRun, timer: TopicTimer, now: Date) -> [LocalNotificationRequest]`:
  for the **open segment** only, the alerts of its step or lap type whose
  instant `seg_started_at + paused_overlap_so_far + at_ms` is in the future;
  none while paused (`paused_since` set). At most the next **8** per run (iOS
  caps pending requests at 64). Identifier
  `quickr.alert.{run_id}.{seg}.{alert.key}` (lowercase run id); thread
  `topic-{topic_id}`; title the topic name; body
  `"{alert.label} · {segment label}"`; `sound: true`;
  `interruptionLevel: .timeSensitive` (OQ-6, entitlement
  `com.apple.developer.usernotifications.time-sensitive` in `project.yml`);
  `quickr` info `kind: alert`, `origin: local`.
- **Time Sensitive provisioning (OQ-6 rider).** The capability must also be on
  the App ID and in the provisioning profile that `testflight.yml` /
  `.github/actions/testflight-setup` sign with. M1's alerts WP verifies the
  signing path **first** (automatic provisioning with the App Store Connect API
  key, or manual profiles). If the capability can't be added without the user's
  Apple Developer portal access, the scheduler ships with `.active`, the portal
  step goes on `docs/t2/device-checklist.md`, and the M1 lead tells the
  orchestrator at once. **A TestFlight build MUST never fail on the
  entitlement**: the entitlement and the `.timeSensitive` level are added
  together, only once the profile carries the capability.
- **Scheduler** computes the desired set and compares it with the pending
  `quickr.alert.*` requests on **identifier, `fireAt` and content**: it adds
  missing ones, removes stale ones and **replaces** changed ones (a pause,
  resume or corrected time moves `fireAt` without changing the identifier).
  Triggers: every local-run change (`observeLocalRuns`, which covers this
  device's taps and sync applying a page) and the app becoming active. A Live
  Activity push runs no app code and is **not** a trigger (OQ-11). Cancels all
  `quickr.alert.{run_id}.*` on stop, discard, and when the run leaves the local
  view. Requests whose instant is already past are not scheduled (an alert
  missed while the app was dead is missed; the Live Activity countdown covered
  it). An alert whose `at_ms` is 0 (its instant is the segment start) is never
  fired, on either client. Taps on the Live Activity and through intents
  re-plan alerts like in-app taps (the scheduler runs from those handlers too).
- `LocalNotificationRequest` gains `interruptionLevel` (default `.active`) and
  `fireAt: Date?`; `SystemNotificationCenter.add` uses
  `UNTimeIntervalNotificationTrigger(timeInterval: max(1, fireAt − now))` for
  `fireAt` and keeps the calendar trigger for `fireDate` (existing callers
  unchanged). `FakeNotificationCenter` records both.
- **Foreground**: `NotificationResponder.willPresent` presents alerts with
  `.banner, .sound`; the app plays `QuickrHaptic.alert` (new case) and the run
  screen shows the alert label inline for 10 s. That label is run-screen state
  (`AppEnvironment.runAlerts.label(runId:)`), not `RunPresentation.alertLine`,
  which stays the persistent next-alert line and is nil when none remain.
- **Accepted limitation (OQ-11)**: when another device taps Lap while this phone
  is locked, this phone's pending alerts are stale until it wakes (a Live
  Activity push runs no app code). The Live Activity countdown is correct
  because the server computes `alert_at`.

### 9.2 PWA **[pwa]**

`src/lib/runs/alerts.ts` (pure:
`nextAlert(run, timer, now) -> {at, label, key} | null` on the server clock,
same maths as §9.1) and `src/components/runs/RunAlerts.tsx` mounted in
`AppShell` beside `RunNotices`:

- one `setTimeout` to the next alert over all local runs; recomputed on every
  `LocalRun` change and on `visibilitychange` (frozen timers in the background
  fire late; an alert more than 30 s late is dropped);
- fires: a toast (`"{label} · {segment}"`), `navigator.vibrate([200,100,200])`
  (no-op on iOS), a short synthesised Web Audio tone (OQ-13) from an
  `AudioContext` created and resumed on the Start/Lap tap (`useRunActions`
  `guarded`), and `registration.showNotification` when permission is `granted`;
- only while the page is open (requirement); a global **mute** toggle in App
  settings (`localStorage`). Alerts are **not muted by default**: the tone
  sounds until the user mutes it (the user asked for a reminder beep). Muted
  alerts show the toast only. One tab fires each alert (the fired record is
  shared across tabs).

### 9.3 Notices (v1 §11.4 additions)

| Reason        | Text                                                                                                                          |
| ------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `reverted`    | "{topic}'s resume was undone by a discard elsewhere."                                                                         |
| `deleted`     | silent (the removed tap was deleted on purpose)                                                                               |
| `not_stopped` | silent when the run is open on this device (a double tap); otherwise "{topic} isn't stopped, so there was nothing to resume." |
| `no_target`   | "Couldn't {resume / remove that}: {topic}'s run changed."                                                                     |

`reverted` is shown only when the reverted reopen was this device's and the
discard another's; `stale` stays silent.

**Known gap (#228, deferred to a `t2-followup`):** notices come from acks, so
`reverted` reaches the reopening device only when the other device's discard
lands before this device's reopen is acked. When the reopen was acked first,
the feed later sends only a run deletion and no notice is shown. Mitigation in
T2: the tile returns to "Saved" with the entry visible, and later taps on the
run get the `after_stop` notice.

## 10. Client ports checklist

Owner map from the brief §5 and the research ownership tables.

**Signatures (the one normative block; active-surfaces.md §1.1 and the M1 plan
copy it verbatim and nothing else restates it).**

```swift
// ios/QuickrKit/Sources/QuickrCore/Runs/RunPresentation.swift
public static func actions(_ state: RunState, status: RunStatus, timer: TopicTimer?, now: Date) -> [RunAction]
public static func headline(_ state: RunState, status: RunStatus, timer: TopicTimer?) -> Headline
public static func alertLine(_ state: RunState, timer: TopicTimer?, now: Date) -> String?
public static func resumable(_ entry: Entry, now: Date) -> Bool
```

```ts
// frontend/src/components/runs/model.ts
export function actions(
  state: RunState,
  status: RunStatus,
  timer: Timer | null,
  now: number,
): RunAction[];
export function headline(
  state: RunState,
  status: RunStatus,
  timer: Timer | null,
): Headline;
export function alertLine(
  state: RunState,
  timer: Timer | null,
  now: number,
): string | null;
export function resumable(entry: EntryOut, now: number): boolean;
```

`RunAction = { kind: Kind, label: string, role: primary | secondary | destructive | overflow, enabled: bool }`.
`RunAction.Kind` is **complete from day one**:
`start, next, lap, skip, pause, resume, stop, addDetails, reopen, revert, discard`.
`remove` is **not** a kind: it is an entry-detail action (content-display.md
§3.2). `timer` is optional (nil until the pinned version is stored; the model
then offers plain Next/Lap, as v1's `steps_unknown`).

**Primary and Auto rule (the single normative text; active-surfaces.md §1.2 and
§5.3 cite it; M1 owns the model, M2 lays it out).**

- **On-screen primary** = **Lap** when the open segment is a lap **or no named
  step remains** (`next_step == null`), labelled with the next lap type's label
  when `timer.laps` is non-empty ("Lap → Rest") and plain "Lap" otherwise; else
  **Next: {step}**. **Stop is never primary**: Stop, Pause, Resume and Reopen
  are secondary; Skip, Discard are overflow.
- **Auto** (the Action button, the Control, the small widget, Siri) is a
  separate rule: `timer.laps` non-empty → Auto = the on-screen primary (idle →
  Start); `timer.laps` empty → v1 §11.1's Auto (idle → Start; a named step
  remains → Next; otherwise → **Stop**), so a stepless Control still stops the
  dishwasher. It is implemented in **I1-WRITES** (`RunWrites.auto` / `autoTap`,
  `RunWrites.swift:212,233`) and the PWA's auto path, not in the presentation
  model.

Consumers: active-surfaces.md §1 and §5.3 (run screen, tiles, Live Activity,
widgets, Control). **M1-ACTIONS** ships the signatures above, the complete
`Kind` and the on-screen primary rule (first wave, shared branch); R18 pins the
rule.

**iOS** (`ios/QuickrKit/Sources/...` unless `App/`):

- `QuickrCore/Models/Topic.swift` `TopicTimer` v2 (Codable with defaults;
  `LapType`, `Variable`, `Alert`).
- `QuickrCore/Runs/RunModels.swift` (`.reopen`, `.remove`, `target`;
  `VoidReason` + 4; `RunSegment.lapType`,
  `RunState.terminalId/nextLapType/lapCount`), `RunFold.swift` (v4, `overlay`
  lap labelling: untyped until the version is stored), `RunPresentation.swift`
  (`actions(_:status:timer:now:) -> [RunAction]`, `headline`, `alertLine`,
  `resumable`), `TimingEdit.swift` (lap types, ids), `TimingStats.swift` (v3),
  new `TimerExpr.swift`, `RunNoticeText.swift`.
- `QuickrData/Session/RunWrites.swift` (`.reopen(target)`, `.remove(target)`,
  `auto` per the Auto rule above), `RunActions.swift`, `Contracts/RunDTO.swift`,
  `QuickrData/Outbox/*` ordering (reopen/remove wait for their `target` item,
  §5.5; K6 exempt when a `reopen` is queued), `Store/RunOverlay.swift`
  ("resuming" projection, §5.3), `Store/ServerLayer.swift` (§5.2 `run_closed`
  markers), new `Contracts/StoreSchema+T2M1.swift` (`t2m1_run_closed`; the
  registration line is added at merge time), `Store/StoreView.swift` (§5.3).
- `QuickrCore/Runs/RunActivity.swift` (§8.1 fields), new
  `QuickrData/LiveActivity/RunActivityCenter+Reopen.swift` (`startFor` on
  reopen; M2 owns `RunActivityCenter.swift` itself and makes the one-line call).
- `QuickrData/Notifications/RunAlerts.swift` (new),
  `Contracts/NotificationCenterProtocol.swift`,
  `Notifications/SystemNotificationCenter.swift`,
  `App/Notifications/Handler/NotificationResponder.swift`,
  `QuickrUI/Components/Haptics.swift` (`.alert`),
  `QuickrTestSupport/Fakes.swift`, `project.yml` (entitlement; one `// T2-M1`
  block), `App/AppEnvironment.swift` (scheduler wiring; one `// T2-M1` block).
- Builder:
  `QuickrCore/Builder/{Drafts,DraftSteps,DraftValidation,BuilderText,CompatibilityCheck}.swift`,
  `QuickrCore/Models/ServerInfo.swift` (`Limits`),
  `QuickrUI/Topics/Builder/{BuilderEditing,BuilderBindings,EditQuestionsModel}.swift`,
  `App/Topics/Builder/TimerEditorView.swift` + new `LapTypesEditorView.swift`,
  `VariablesEditorView.swift`, `AlertsEditorView.swift` (M1 MUST NOT edit
  `NewTopicScreen.topicSection` / `TopicSettingsView.detailsSection`: M3's).
- `App/Debug/UITestRuns.swift` and `UITestLaunch.swift` (fake server: new event
  types, v2 timer), request goldens `recordRunEvent.reopen/remove`.

**PWA** (`frontend/src/...`):

- `lib/runs/types.ts`, `fold.ts` (v4), `localView.ts` (`overlay` labelling,
  `statusOf`), `actions.ts` (`TapType`, `targetOf` for reopen/remove,
  `makesEntry` false for both), `notices.ts`, `stats.ts` (v3), new
  `timerExpr.ts`, new `alerts.ts`.
- `lib/outbox/kinds.ts` (`RunEventPayload.timer` replaces `steps` so offline
  runs know their lap types and alerts; `waitsFor` adds the pending `target`
  item for reopen/remove; `coalesce` K6 exempt when a `reopen` is queued, §5.5),
  `api/runs.ts` (ack rule for buried ids, §5.2, tests), `localView.ts`
  "resuming" projection (§5.3), `api/limits.ts` (`FALLBACK_LIMITS`).
- `components/runs/model.ts` (`actions`, `primaryAction` with Lap, the Auto rule
  above, `headline`, `alertLine`, `resumable`), `timingEdit.ts` (lap types), new
  `RunAlerts.tsx`, new `useRunAudio.ts` (the audio unlock; M2 owns
  `useRunActions.ts` and makes the one-line call), `AppShell.tsx` (mount),
  `pages/AppSettingsPage.tsx` (mute).
- Builder: `lib/builder.ts`, `components/builder/TimerEditor.tsx` + new
  `LapTypesEditor.tsx`, `VariablesEditor.tsx`, `AlertsEditor.tsx`,
  `serverErrors.ts`, `pages/topic/EditQuestionsPage.tsx`,
  `lib/builderUi.vectors.test.ts`.
- `test/fakeRunServer.ts` (folds with v4), regenerated `src/client/**` (one
  `make client` per merge; never hand-edited).

## 11. Compatibility

- **One coordinated bump in M1's first server WP**: `shared/api-level.json` →
  `api_level 2`, `min_client_level.ios = .web = 2`; `make api-level`,
  `make vectors` (client-versions.md §2). Reasons it is a break: new
  `RunEventType` values in `RunOut.events` (an installed iOS build fails to
  decode a feed page), run resurrection semantics (§5), fold v4 (an old port
  would disagree with the server on labels, `seg` and reopened runs), and
  `Timer` normalisation (extra keys in strict DTOs).
- `compat/supported-clients.json`: remove both listed builds (`20261028.170408`
  level 1, `20261026.143027` level 0: below the new minimum, so never checked);
  add `LiveActivityVectorTests` to `suites` (issue #111) so the next listed
  build is covered. The user is on TestFlight 20261028.170408 (session memory
  `project-cv-build-installed.md`); the orchestrator decided that raising the
  minimum is acceptable (requirements.md says nothing about client levels).
- `CONTENT_STATE_VERSION` stays 1: only optional fields are added (§8.1).
- **Signing**: the Time Sensitive capability (§9.1) is a TestFlight profile
  change; it lands only after the signing path is verified, and a build never
  fails on it (fallback `.active`).
- M2–M4 are additive at level 2 and bump nothing. Release: one `v*` tag from
  `feat/t2`.
- **Migration order**: M1's Alembic `20261126_e6f3a9b4c215_timers_v2` (down
  `d5e2f8a3c104`) merges to `feat/t2` **before** M3's
  `20261127_f7a4b0c5d326_topic_appearance` (down `e6f3a9b4c215`) and M3b's
  `20261201_a8b5c1d6e437_topic_photo` (down `f7a4b0c5d326`); M4 has none. iOS
  store migrations are independent per milestone (`t2m1_*`, own file).

## 12. Tests

### 12.1 Shared vectors

| File                            | Generator (version)                                   | New or changed cases                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| ------------------------------- | ----------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `run-fold-vectors.json`         | `test_run_fold_vectors.py` (3 → 4); `timer_sets`      | every v1 case re-pinned with `lap_type`/`terminal_id`/`next_lap_type`/`lap_count`; `renamed-laps`, `tiktok-cycle`, `three-types-with-step`, `reopen-accidental-stop` (§6.1), `reopen-then-restop-labels`, `reopen-not-terminal` (`not_stopped`), `reopen-unknown-target` (`no_target`), `reopen-after-discard` (`already_closed`), `reopen-stale-at`, `reopen-too-long`, `reopen-double-tap`, `reopen-revert-by-discard` (§6.2), `reopen-revert-then-reopen-again`, `reopen-second-stop-new-terminal`, `stop-reopen-stop-reopen-discard-discard`, `stop-reopen-remove-gap-revert-reopen-remove-gap-revert`, `reopen-offline-stop-earlier-than-reopen`, `reopen-while-paused-ends-pause`, `reopen-gap-removed-user-pause-inside-gap`, `resume-inside-gap-stale`, `gap-pause-equal-time-user-resume`, `gap-resume-equal-time-user-pause`, `two-gap-pauses-equal-time`, `reopen-lap-inside-gap` (§6.6), `remove-pause` (§6.3a), `remove-pause-resume-deleted`, `remove-void-pause-noop`, `remove-pause-changes-which-pause-applies`, `remove-gap-pause` (§6.3b, the stop `deleted`), `remove-lap-merges-previous`, `remove-lap-renumbers-types` (§6.4), `remove-lap-ghost-keeps-later-lap-applied`, `remove-two-laps-ghosts-stack`, `remove-stale-lap-no-ghost`, `remove-lap-after-stop-late-merge` (§6.5), `remove-lap-after-stop-then-late-lap` (§6.5, revision 3), `remove-years-later-applies` (no 7-day bound), `remove-next-is-no-target`, `remove-terminal-stop-no-target`, `remove-twice-no-target`, `remove-at-before-target-no-target`, `remove-then-revert-restores-stop`, `timing-carries-event-ids`, `timing-pre-v2-null-ids`, `frozen-reopen-run-edited`, `frozen-remove-entry-deleted` |
| `timer-expr-vectors.json` (new) | `test_timer_expr_vectors.py` (1)                      | §2.5 list                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `builder-vectors.json`          | `test_builder_vectors.py` (3 → 4)                     | §1.3 list                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `builder-ui-vectors.json`       | `builderUi.vectors.test.ts`                           | `new_lap_type`, `lap_type_label`, `variable`, `alert_expr`, `timer_output` v2, `timer_changes` v2                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `timing-stats-vectors.json`     | `test_timing_stats_vectors.py` (2 → 3)                | §7.4 list                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `live-activity-vectors.json`    | `test_live_activity_vectors.py` (2 → 3); `timer_sets` | §8.2 list incl. `payload_budget_truncation`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `api/*.json`                    | `test_api_fixtures.py`                                | `recordRunEvent.reopen`, `recordRunEvent.restop`, `recordRunEvent.remove`, `recordRunEvent.remove_late`, `recordRunEvent.revert`, `listChanges.reopened_run` (a `run` deletion with `revision`), `getEntry.v1_timing` (a stored v1 timing: ids null), `getLimits` (new rows), `getTopicTiming` (lap types), `getTopic` / `listTopicVersions` (normalised timer), `getRun` (MCP)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `requests/*.json`               | Swift golden generator                                | `recordRunEvent.reopen`, `recordRunEvent.remove`, `publishTopicVersion.timer_v2`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `getClientVersions` fixture     | `make vectors` after the bump                         | level 2                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |

`shared/fixtures/README.md` gains a row for `timer-expr-vectors.json`.

### 12.2 Backend (continuing timers.md §13.2)

| #   | Case                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| T18 | Every fold v4 vector through the real endpoint gives the same `RunState`, effects and (when stopped) entry `timing` as the pure fold.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| T19 | Reopen of a stopped run: 200 applied, run `running`, `ended_at` null, revision + 1, `(run, upsert)` logged, the entry unchanged (same revision) and still returned by `getEntry`; `createEntry` with its id replays it.                                                                                                                                                                                                                                                                                                                                                                                                               |
| T20 | Re-stop: entry `timing` and `captured_at` replaced, revision + 1, `(entry, upsert)` then `(run, delete)`; no `deleted_ids` row; a stop with answers on the re-stop merges them.                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| T21 | Discard after reopen (revert): run `stopped`, `ended_at` restored, `(run, delete)` logged, no tombstone, entry revision unchanged; the reopen is `reverted` in `RunOut.events`; a reopened **finishing** run's discard leaves it `discarded` with a tombstone.                                                                                                                                                                                                                                                                                                                                                                        |
| T22 | Reopen while the topic has another open run: 409 `conflict`, nothing stored (event count unchanged).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| T23 | Reopen on an edited run → `run_edited`; on a run whose entry was deleted → `entry_deleted`; on a discarded run → `already_closed`; naming a non-terminal stop → `not_stopped`; an unknown id → `no_target`; `target: null` resolves to the terminal and `RunEventOut.target` carries it; `remove` without `target` → 422; `Timing` carries `terminal_id`, `segments[].event_id`/`opened_by`, `pauses[].id` (null after a `TimingEdit`; a stored v1 timing is served with all four null, `getEntry.v1_timing`); `PATCH /entries/{id}` with `timing` while the run is open or finishing → 409 `conflict`, nothing changed.              |
| T24 | Remove on an open run (pause, lap, gap pause): applied, `(run, upsert)`; the `seg` ghost rule keeps a later lap applied (§6.4) and a tap after the remove with the renumbered `seg` applies.                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| T25 | Remove on a stopped unedited run: late merge, entry revision + 1, `runs.edited` false, `(entry, upsert)` only; a later late lap still merges. Remove of a `next`, a terminal stop, a removed id, or with `at ≤ target.at` → `no_target`.                                                                                                                                                                                                                                                                                                                                                                                              |
| T26 | A stop writes no `deleted_ids` row; a discard and a topic delete do. The data migration removes the rows of stopped runs and keeps those of discarded ones (`test_migrations.py`).                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| T27 | `test_feed_runs.py` T7/T8 updated: a stopped run's deletion is still emitted (from its log row) and carries `revision`; a topic-cascade run deletion carries `revision: null`; a run that stopped, reopened and re-stopped within one page is one deletion; an incremental page after a reopen carries the run as an **item** again (resurrection); both cuts of §5.1: stop → reopen → re-stop split every way (the middle page emits nothing for the run), and stop → reopen split with the run open at read time (the first page emits the item at its current revision); bootstrap deletions carry `revision`.                     |
| T28 | `Timer` v2 validation: every §1.3 vector; the v1 shape is accepted; output is normalised with `at_ms`; `GET /limits` carries the seven new rows; `checkTopicVersion` and MCP accept v2.                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| T29 | `timer_expr`: every §2.5 vector; a 65-character expression is `too_long` at 64; results are identical for the same operations in Python (the ports check the same file).                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| T30 | Live Activity: an applied reopen sends `start` to push-to-start tokens (not the originating device's with `live_activity: true`); `content_state` fills `alert_at`/`alert_label` from active time, null while paused; no `terminal_id`; `encode` enforces the byte budget on the encoded body (§8.2): `start_longest_labels` v2 fits untruncated, `payload_budget_truncation` truncates `alert_label`, `next_label`, `label`, `topic_name` in that order to 32 characters until the body is ≤ 4 096 bytes; `payload_budget_terminal` nulls `next_label`/`alert_label`, empties `topic_name` and asserts the fixed-field bound (§8.2). |
| T31 | `getTopicTiming.lap_types` over mixed typed/untyped runs and a renamed lap type across versions; `series[].lap_types`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| T32 | MCP: `run_action reopen` defaults `target` to `terminal_id` and refuses when null; `run_action remove` requires `target`; `get_run`; `INSTRUCTIONS` mentions reopen/remove (string check).                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| T33 | `test_identity.py` `_mutations`: no new operations (reopen/remove reuse `recordRunEvent`); `test_compat_gate.py` passes after the level-2 bump with the two builds removed.                                                                                                                                                                                                                                                                                                                                                                                                                                                           |

### 12.3 iOS (continuing §13.3)

| #   | Case                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | Class |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----- |
| R13 | Fold v4, expression, stats v3 and Live Activity v3 vectors; `TopicTimer` decodes v1 and v2 JSON                                                                                                                                                                                                                                                                                                                                                                                                                                   | host  |
| R14 | `ServerLayer`: a `run` deletion writes a `run_closed(id, revision)` marker from `deletion.revision` (∞ when null) and ∞ for the aliases, no tombstone, and removes alias rows; a closing ack writes the marker from `response.run.revision`; a feed upsert applies iff its revision beats the marker and clears it; the topic cascade still tombstones; `t2m1_run_closed` creates the tables and converts run tombstones (∞ under a tombstoned topic, else 0); markers prune at 30 days (`RunSyncTests`)                          | host  |
| R15 | `RunOverlay`: a queued reopen opens the run locally (entry hidden, §5.3); a queued remove relabels at once; a discard queued after a reopen on a run with no entry shows discarded and projects no optimistic entry; `overlay` without the version leaves laps untyped                                                                                                                                                                                                                                                            | host  |
| R16 | Outbox: reopen/remove wait for the start and for their pending `target` item (a failed target holds nothing); an event enqueued after a pending reopen waits for it (`lap-waits-for-pending-reopen`); K6 drops a never-sent run with its remove items; `k6-not-on-revert`: a discard after a queued reopen is appended, nothing dropped, the optimistic entry stays; `no_target`/`not_stopped`/`reverted` acks and their notices, the `reverted` notice on the reopening device only (two-device test)                            | host  |
| R17 | `RunAlertPlan`: plan from open segment, paused → none, cap 8, identifiers, time-sensitive; scheduler compares identifier + `fireAt` + content against `FakeNotificationCenter` and replaces a request whose `fireAt` moved (pause/resume, a corrected time) under the same identifier; cancel-all on stop/discard; a Live Activity push is not a trigger                                                                                                                                                                          | host  |
| R18 | `RunPresentation.actions(_:status:timer:now:)`: Lap primary when the open segment is a lap or no step remains (labelled with the next lap type when typed), Next otherwise, Stop never primary, Reopen secondary, Discard destructive; Auto = the primary when `timer.laps` is non-empty, v1's Auto (… → Stop) when empty; `resumable` 15 min / 7 days rules                                                                                                                                                                      | host  |
| R19 | Builder models: lap types, variables and alerts drafts; `DraftValidation` paths; `timerChanges` text; `BuilderUIVectorTests` new sections                                                                                                                                                                                                                                                                                                                                                                                         | host  |
| R20 | `LiveActivityReconcileTests`: a reopen this device made requests an activity (`startFor`); one made elsewhere waits for push-to-start                                                                                                                                                                                                                                                                                                                                                                                             | host  |
| R21 | UI test (`RunUITests`): start, lap, stop, Resume from the saved state, lap, stop; the entry shows three laps and one pause. **Run by M2** (the Resume control lives in M2-owned files); M1's sim WP keeps R22 and the resurrection tests (R14)                                                                                                                                                                                                                                                                                    | sim   |
| R22 | UI test (`BuilderUITests`/`TimingUITests`): publish a topic with two lap types, a variable and an alert; the run screen shows "Run 1" then "Rest 1"                                                                                                                                                                                                                                                                                                                                                                               | sim   |
| R23 | `SystemNotificationCenterTests`: `fireAt` → interval trigger, `interruptionLevel` set                                                                                                                                                                                                                                                                                                                                                                                                                                             | sim   |
| R24 | Closed markers, acks: a delayed **pre-close** ack (lower revision) for a run the feed has since closed leaves it closed; a higher-revision ack that is not an applied `reopen` leaves it closed; an applied-reopen ack reopens it and clears the marker; a closing ack writes the marker from `response.run.revision`; **a delayed stop ack arriving after a reopen upsert with a higher revision is a no-op apart from acking the item** (the row stays, no marker is written)                                                   | host  |
| R25 | Closed markers, feed: a run deletion with `revision` on one page and its reopen upsert (higher revision) on the next apply in turn; a deletion received with no local row still fences a delayed older upsert; **an older feed deletion applied after a newer ack is a no-op**; every marker write is `max(existing, new)`; a bootstrap after a reopen lists the run as an item and its earlier deletion carries `revision`; a deletion with `revision: null` (topic cascade) is permanent; markers older than 30 days are pruned | host  |
| R26 | Entry-origin projections: a reopen queued from an entry with no run row shows a running run built from the entry's timing (entry hidden) and is replaced by the ack's `RunOut`; a remove queued the same way projects no run and shows the entry re-projected with a pending mark, `revision` unchanged; `targetOf` reads `terminal_id` / `event_id` / `pause.id` from the timing and sends `target: null` from a pre-v2 timing                                                                                                   | host  |
| R27 | `t2m1_run_closed`: run tombstones become markers (0 under a live topic, ∞ under a tombstoned topic) and are deleted, on live and stage tables; the migration increments `layer_gen`, so an outcome whose `ctx.layer_gen` predates it fails the §5.5 fence and is discarded (a request started before the migration, completing after it); a `run.event` item queued before the migration is re-sent and its ack obeys the marker rules; an epoch rebuild replaces the marker set from bootstrap deletions' `revision`             | host  |

### 12.4 PWA

Vitest: fold v4, expression and stats vectors; `localView` (reopen hides the
entry, remove relabels, `targetOf` for reopen/remove from the run or from the
entry's timing ids and `target: null` from a pre-v2 timing, the "resuming"
projection for a reopen, the re-projected entry with a pending mark for a
remove, a discard queued after a reopen on a run with no entry projects no
optimistic entry, Resume hidden while the topic has a local open run,
`makesEntry`); outbox kind (`waitsFor`: reopen/remove wait for their pending
`target` item and the start, a failed target holds nothing;
`lap-waits-for-pending-reopen`; K6; `k6-not-on-revert`: a discard after a queued
reopen is appended, never coalesced); `api/runs.ts` resurrection (a closed run's
marker is beaten by a higher-revision list row and by an applied-reopen
response; a delayed older ack and a non-reopen ack stay buried; bootstrap after
a reopen lists the run); `notices` (`reverted` shown to the reopening device
only); `notices`; `alerts.ts` (next alert, paused, late drop) and
`RunAlerts.tsx` with fake timers (toast, notification when granted, mute);
`model.ts` `actions`/`resumable`; builder (`draftFromTimer` v2, `timerFromDraft`
normalised, `timerChanges`, server error paths); `RunFlow.test.tsx` reopen and
remove flows against `fakeRunServer` (v4); `EditQuestionsPage` publishes v2.

### 12.5 Device checks (not automatable)

1. Lap alert with the phone locked: the notification sounds and breaks through a
   Focus (time-sensitive); the Live Activity countdown reaches 0 at the same
   instant.
2. Lap on the PWA while the phone is locked: the phone's alerts are stale
   (OQ-11); after unlocking they are re-planned.
3. Reopen from the PWA: the phone's Live Activity reappears by push-to-start;
   reopen on the phone from the tile or the entry (M2/M4 surfaces; never from
   the ended activity, active-surfaces.md §4.4): the activity is requested
   locally.
4. Resume within 15 minutes from the tile; after 15 minutes only from the entry.
5. Web Audio tone on an installed iOS PWA after the Start tap; silent switch
   mutes it.

## 13. Open questions

Each default is written into the spec; the plan lists them for the user.

| OQ    | Question                                             | Default in this spec                                                                                                                                                                                           | If the alternative is chosen                                                                               |
| ----- | ---------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| OQ-1  | `resumable` window on tiles/toasts                   | 15 minutes after the stop; always from the entry detail within 7 days. "Unedited" = `run.edited == false` (a `TimingEdit`); answers/notes/meta changes never block Resume or the server's `reopen`             | A longer window keeps "Resume" on tiles of long-finished runs; a shorter one hides accidental stops sooner |
| OQ-2  | Discard on a reopened run                            | **Revert** (the reopen is undone, the entry stays)                                                                                                                                                             | "Discard = delete the entry" would make the only way out of a reopen destructive                           |
| OQ-3  | Lap numbering with lap types                         | Per type ("Run 2, Rest 2")                                                                                                                                                                                     | Global ("Run 3, Rest 4") simplifies the label rule but reads worse for run/rest                            |
| OQ-4  | Alerts on steps                                      | Yes, same schema and editor                                                                                                                                                                                    | Lap-type-only alerts save one editor section and the `Step.alerts` field                                   |
| OQ-5  | Bare number in an expression                         | Error `type` ("add a unit")                                                                                                                                                                                    | Treating it as seconds would make `t*0.5` and `30` both durations; ambiguity for `t/2+30`                  |
| OQ-6  | Time-sensitive interruption level                    | Yes (entitlement in `project.yml`), after the TestFlight signing path is verified; fallback `.active` + a portal step on `docs/t2/device-checklist.md` if the capability needs the user's portal access (§9.1) | Without it, Focus modes silence lap alerts; no App Store review item                                       |
| OQ-11 | Stale alerts after another device's tap while locked | Accepted limitation; the Live Activity countdown stays right                                                                                                                                                   | A silent push that wakes the app to re-plan would add a push path and battery cost                         |
| OQ-13 | PWA audible cue                                      | A short synthesised Web Audio tone, mute toggle                                                                                                                                                                | Vibrate + toast only: silent on iOS, where vibrate is a no-op                                              |
| OQ-14 | The entry during a reopen                            | Kept on the server; hidden on clients while the run is open or finishing                                                                                                                                       | Deleting it at reopen would tombstone the id (F3) and make the run unresumable for good                    |
| OQ-9  | Topic tags                                           | Owned by appearance.md (M3); not covered here                                                                                                                                                                  | —                                                                                                          |

**Decided (was a note here):** a `reopen`/`remove` also waits for the queued
item its `target` names (§5.5), so a reopen can't overtake its own device's
stop.

## Review log (round 1)

C = `codex-r1.md` (S1 numbered in file order), K = `claude-r1.md`; the lead's
adjudication is `adjudication-r1.md` §A–§C.

| Finding                                 | Outcome                                                                                                                           |
| --------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| C-S1 #1 permanent-deletion contract     | fixed in §5.1 (closed vs deleted; only deleted runs are tombstoned)                                                               |
| C-S1 #2 vanished-entity invariant       | fixed in §5.1 (emission rule from the log row; missing-and-untombstoned cannot occur), §4.3                                       |
| C-S1 #3 iOS marker                      | fixed in §5.2 (`run_closed(id, revision)`, feed/ack rules, prune), R14, §12.4                                                     |
| C-S1 #4 revert pops the wrong reopen    | fixed in §3.4 (`open_reopen`), vector `stop-reopen-stop-reopen-discard-discard`                                                   |
| C-S1 #5 gap resume closes a user pause  | fixed in §3.4 (decision: a reopen ends whatever pause is open), two vectors                                                       |
| C-S1 #6 7-day bound on `remove`         | **rejected**: a remove is an edit like `TimingEdit`, bounded only by `at > target.at` (§3.4); vector `remove-years-later-applies` |
| C-S1 #7 example 6.5                     | fixed in §6.5 (full post-late-lap timing, revision 3), vector `remove-lap-after-stop-then-late-lap`                               |
| C-S1 #8 scheduler by identifier         | fixed in §9.1 (compare identifier + `fireAt` + content, replace), R17                                                             |
| C-S2 LA push as a trigger               | fixed in §9.1 (triggers: local-run change, app active, sync)                                                                      |
| C-S2 `terminal_id` in the content state | fixed in §8.1 (dropped), §12.5, T30                                                                                               |
| C-S2 payload size after M3              | fixed in §8.2 (M3 re-runs the size vector with `attributes.appearance`)                                                           |
| K-S1 primary rule ×3                    | fixed in §10 (single normative text, M2's rule; Auto separate), R18                                                               |
| K-S1 targets for stopped runs           | fixed in §3.3, §4.2, §5.3, §7.1 (ids in `Timing` incl. `opened_by`; `reopen` target may be null; "resuming"), R26                 |
| K-S1 K6 erases a reverted run           | fixed in §5.5 (K6 exempt when a reopen is queued), R16, §12.4                                                                     |
| K-S2 6.3(b) effect                      | fixed in §3.4 (`void(t, deleted)` in pass 1, restored on revert), §6.3                                                            |
| K-S2 `gap_resume` semantics             | fixed in §3.4 (as C-S1 #5)                                                                                                        |
| K-S2 determinism invariant              | fixed in §3.4 (restated; property test constraints)                                                                               |
| K-S2 cross-refs and `actions` signature | fixed in §10 (`actions(_:status:timer:now:)`); other docs' references are theirs                                                  |
| K-S3 downgrade story                    | fixed in §4.3 (leave the enum values; one sentence)                                                                               |
| K-S3 `revision += 1` double count       | fixed in §4.1                                                                                                                     |
| K-S3 `terminal_id` dead weight          | fixed in §8.1 (as C-S2)                                                                                                           |
| K-S3 cross-device reopen note           | fixed in §3.4 (reworded: local-view determinism)                                                                                  |
| K-S3 "requirements" citation            | fixed in §11                                                                                                                      |
| K-S3 size check tests nothing new       | fixed in §8.2                                                                                                                     |
| K-S3 unit names as variables            | fixed in §1.1, §1.3, vector `variable-name-reserved-unit`                                                                         |
| K-S3 `ServerLayer.swift:78-81`          | fixed in §5.2 ("also checked")                                                                                                    |
| K-S3 key namespace per timer            | fixed in §7.4 (`lap_types[]` and `steps[]` keyed separately)                                                                      |
| K-S2 signing proof, K-S2/S3 plan items  | the planner's (adjudication §E); §9.1 and §11 already carry the `.active` fallback                                                |

## Review log (round 2)

C = `codex-r2.md` (S1 numbered in file order), K = `claude-r2.md`; the lead's
adjudication is `adjudication-r2.md` §A.

| Finding                                                         | Outcome                                                                                                                                                                                                                        |
| --------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| C-S1 #1 paginated replay needs historical state                 | **rejected** (a misreading: `_page` emits by current state and never replays history); §5.1 "Paginated replay" rewritten to the real contract, T27 pins both cuts                                                              |
| C-S1 #2 deletion without a local row                            | fixed in §5.2 (`FeedDeletion.revision` is the durable fence), §7.1                                                                                                                                                             |
| C-S1 #3 clearing and pruning markers                            | fixed in §5.2 (lifetime argument: cursor-ordered pages, 15 s / 30 s bounded responses, generation check)                                                                                                                       |
| C-S1 #4 migration drops the fence                               | fixed in §5.2 (tombstones converted to markers; the migration runs before any flush), R27                                                                                                                                      |
| C-S1 #5 cascade and alias tombstones                            | fixed in §5.2 (∞ markers for aliases and tombstoned topics; cascade still tombstones)                                                                                                                                          |
| C-S1 #6 revert leaves removes applied                           | fixed in §3.4 (effects fresh on every fold; re-eligibility after a new reopen), vector `stop-reopen-remove-gap-revert-reopen-remove-gap-revert`                                                                                |
| C-S1 #7 equal-time synthetic events                             | fixed in §3.4 (roles carry ids and a rank; the gap owns the open pause), vectors `gap-pause-equal-time-user-resume`, `gap-resume-equal-time-user-pause`                                                                        |
| C-S1 #8 removing a void pause                                   | fixed in §3.4 (identity-based eligibility kept; a dependent resume is `deleted`, a reason change only), vector `remove-void-pause-noop`                                                                                        |
| C-S2 remove before its target                                   | **rejected**: a target id is learnt only from the server, where the target is already stored; the issuing device's own view is ordered by §5.5 (§3.4)                                                                          |
| C-S2 6.7 lap overtakes the stop/reopen                          | fixed in §5.5 (an event enqueued after a pending reopen waits for it), §6.7, R16, §12.4                                                                                                                                        |
| C-S2 6.2 notice reversed                                        | fixed in §6.2 (matches §9.3), two-device test in R16/§12.4                                                                                                                                                                     |
| C-S2 payload bytes                                              | fixed in §8.2 (byte budget on the encoded body, ordered truncation to 32 chars), vector `payload_budget_truncation`, T30                                                                                                       |
| C-S2 sync-protocol F2 consumers                                 | fixed in §5.1 (docs commit to sync-protocol.md §1.3 F2/F3 in M1-FEED's scope)                                                                                                                                                  |
| C-S2 ghost guard and offline taps                               | fixed in §3.5 (product contract stated: re-tap; no causal versioning)                                                                                                                                                          |
| K-S1 `Timing.terminal_id` non-nullable                          | fixed in §3.3, §7.1 (all four ids `null` only on pre-v2 timings; Resume sends `target: null`), vector `timing-pre-v2-null-ids`, fixture `getEntry.v1_timing`, T23                                                              |
| K-S1 `actions` signature ×3                                     | fixed in §10 (one verbatim block for both platforms; `Kind` complete from day one; `remove` not a kind; Auto in I1-WRITES; `RunIntentWrites` dropped)                                                                          |
| K-S2 taps after a pending reopen                                | fixed in §5.5, §6.7 (as C-S2)                                                                                                                                                                                                  |
| K-S2 `remove` from an entry, three behaviours                   | fixed in §5.3 (no run projected; entry re-projected with a pending mark), glossary, R26, §12.4                                                                                                                                 |
| K-S3 pagination per page                                        | as C-S1 #1                                                                                                                                                                                                                     |
| K-S3 offline `resume` inside the gap                            | fixed in §3.4: the gap owns the open pause, so the resume is void `stale` (the adjudication said `not_paused`; both are silent, and the outcome asked for, stopped time never active, holds), vector `resume-inside-gap-stale` |
| K-S3 local view of a finishing revert                           | fixed in §5.3, R15, §12.4                                                                                                                                                                                                      |
| K-S3 resurrection details (aliases, cascade, Resume while open) | fixed in §5.2 (aliases ∞; conversion rule), §5.3 (Resume hidden while a local run is open)                                                                                                                                     |
| K-S3 `TimingEdit` on a reopened run                             | fixed in §7.2 (409 `conflict` while the run is open or finishing), T23                                                                                                                                                         |
| K-S3 `RunAction.Kind` on day one; `remove` kind                 | fixed in §10                                                                                                                                                                                                                   |
| K-S3 cross-reference rot (§7.1 → §5.3)                          | the other docs'; timers2 has no such reference                                                                                                                                                                                 |
| K-S1/S2/S3 plan and other-doc items                             | the planner's and writer B's (adjudication §B, §C)                                                                                                                                                                             |

### Round 2, Codex verification (`codex-r2-verify.md`)

| Finding                                       | Outcome                                                                                                                                                                                 |
| --------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| New S1: role order not total                  | fixed in §3.4 (key `(at, rank, id)` with role ids; "id-independent" dropped), vector `two-gap-pauses-equal-time`                                                                        |
| New S1: delayed close erases a newer reopen   | fixed in §5.2 (revision ordering on closes too; a close against a newer row is a no-op apart from the ack; markers only raised), R24, R25, §12.4                                        |
| New S1: lifetime argument not a durable fence | fixed in §5.2 (numbered invariant citing sync-protocol.md §5.5 fence, outbox.md §4 15 s / sync-protocol.md §1.1 30 s, outbox.md §6.1/§6.3; the migration bumps `layer_gen`), R27        |
| New S1: "revision at close" not readable      | fixed in §5.2 (`FeedDeletion.revision` = the run's revision in the page's REPEATABLE READ snapshot, with the proof that it bounds every upsert; late events only raise the fence), §5.1 |
| Partial #8: "only a reason change" overstated | fixed in §3.4 (claim narrowed to a void pause), vector `remove-pause-changes-which-pause-applies`                                                                                       |
| Partial #13: payload after four truncations   | fixed in §8.2 (terminal step, computed fixed-field bound), vector `payload_budget_terminal`, T30                                                                                        |
| Partial #14: sync-protocol F2/F3              | fixed in §5.1 (exact replacement sentences for M1-FEED's docs commit, consumer tests named)                                                                                             |
| Partial #3/#4/#5: pruning, migration, aliases | fixed in §5.2 (as the three S1 items above; ∞ markers pruned too, harmlessly)                                                                                                           |

## Decisions

Settled in the design brief and not reopened here: timer config stays versioned
(§1.5); items 1 and 4 are one concept (§1.1); reopen is a new event with a gap
pause, not a `resume` naming the stop (§3); a deleted entry is gone for good;
`remove` is the one-tap deletion for pauses and laps on open and stopped runs,
step boundaries stay `TimingEdit`'s (§3.6); a stop no longer tombstones (§4.3);
one coordinated `api_level 2` bump (§11).

**[deviation]** list for the M0 lead: (1) a reopen whose resume role finds no
open pause stays `applied` rather than `not_paused` (§3.4); (2) `changes.py`
must emit a stopped run's deletion from its log row (§4.3); (3)
`max_short_label_length 64` is added to the limits (§1.2); (4) MCP gains a small
`get_run` (`remove` via MCP needs the event list) (§7.3); (5) reopen is also
accepted on a `finishing` run, and its revert discards it (§4.1); (6) the PWA
runs cache is already revision-aware (§5.2). All six were accepted by the M0
lead in round 1.

## Traceability

| Requirement                                                         | Where                       |
| ------------------------------------------------------------------- | --------------------------- |
| 1. Rename "lap"                                                     | §1.1, §3.2, §6.5            |
| 2. Resume a session after an accidental stop; the gap is a pause    | §3.4, §4.1, §6.1, §8.3      |
| 2. Delete a pause; delete a lap into the previous (or next) segment | §3.4, §3.5, §3.6, §6.3–§6.5 |
| 2. A deleted entry is gone for good                                 | Purpose, §3.6, OQ-14        |
| 4. Laps tik-tok between types                                       | §1.1, §3.2, §6.4            |
| 5. Alerts per lap type (and step), expressions over variables       | §1.1, §2, §8.1, §9          |
| 5. Alerts fire on a locked iPhone; the PWA only while open          | §9.1, §9.2, §12.5           |
| Reopen designed against the feed/tombstone invariants               | §4.3, §4.4, §5              |
| Raising the minimum client level is acceptable                      | §11                         |
| Model for M2's controls (`actions`, `resumable`)                    | §10, R18                    |
| Lap-type stats for M4                                               | §7.4                        |
