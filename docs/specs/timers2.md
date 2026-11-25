# Spec: timers v2 (lap types, alerts, reopen and remove)

**Status:** draft (revision 1, 2026-11-25). **Applies to:** the backend, the
PWA, the iOS app (app, widgets, Live Activity, intents, notifications) and the
MCP server. **Companion specs:** [timers.md](timers.md) (v1: this spec changes
it **by reference**; v1 stays as history with a banner pointing here),
[sync-protocol.md](../ios/specs/sync-protocol.md),
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

| timers.md (v1)                      | Change in v2                                                                                                                                             | Here       |
| ----------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- |
| §2.1 `Timer = {steps}`              | `Timer` gains `laps` (lap types), `variables` and per-step/per-lap-type `alerts`; output normalised; six new limits                                      | §1, §7     |
| §2.3 `Segment` / `Timing`           | `Segment` gains `lap_type`; lap labels follow the lap-type rule ("Run 2", "Rest 2") instead of always "Lap n"                                            | §3.2, §7   |
| §2.4 the change log                 | A **stop no longer tombstones** the run id; only a discard (and a topic delete) writes `deleted_ids(kind=run)`. A run may come back after a run deletion | §4, §5     |
| §3.2 `RunEventIn`                   | Two event types, `reopen` and `remove`, with a `target`                                                                                                  | §3, §7     |
| §3.5 Stop, §3.7 Discard             | A stopped run can be reopened; a discard of a reopened run **reverts** the reopen (OQ-2)                                                                 | §3.4, §4.1 |
| §4 the fold                         | Fold **v4**: input `timer` instead of `steps`; reopen (gap pause), remove (deleted boundaries, the `seg` ghost rule); four new void reasons              | §3         |
| §4.4 late merges                    | `reopen` and `remove` are exempt from `after_stop`; a remove on a stopped unedited run is a late merge                                                   | §3.6       |
| §7.1 feed, §7.2 iOS store, §7.3 PWA | Resurrection rule: a `run` deletion is not permanent on clients; iOS drops run tombstones; `changes.py` emits a stop's deletion from its log row         | §5         |
| §8 outbox                           | `reopen`/`remove` are `run.event` items that wait for the run's start **and for the queued item their `target` names**; nothing else changes             | §5.5       |
| §9 stats                            | `TopicTiming.lap_types` and `SeriesPoint.lap_types` (M4 consumes)                                                                                        | §7.4       |
| §10.3 Live Activity content state   | Optional fields `lap_type`, `lap_count`, `alert_at`, `alert_label`, `terminal_id`; `next_label` also for laps; push-to-start on reopen                   | §8         |
| §11.1 primary button                | Lap is the primary for lap-driven runs; `actions(run, timer, now)` is M1's model, M2 lays it out                                                         | §10        |
| §11.4 notices                       | Notices for `reverted`, `deleted`, `not_stopped`, `no_target`                                                                                            | §9.3       |
| §11.6 MCP                           | `run_action` gains `reopen` and `remove`; topic tools take the v2 `Timer`                                                                                | §7.3       |
| §12 compatibility                   | `api_level 1 → 2`, `min_client_level = 2` on both platforms                                                                                              | §11        |
| (new)                               | Alerts: expression grammar, iOS local-notification scheduling, PWA in-page alerts                                                                        | §2, §9     |

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

| Term               | Meaning                                                                                                                                                                                                                                                                                                                                                |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Lap type**       | A named kind of lap in `timer.laps`: `{key, label, alerts}`. Laps cycle through the version's lap types in order; with none, laps are untyped ("Lap _n_", v1).                                                                                                                                                                                         |
| **Variable**       | A named duration in `timer.variables` (`{name, ms}`) that alert expressions refer to (`t`, `rest`).                                                                                                                                                                                                                                                    |
| **Alert**          | `{key, label, at}` on a step or lap type: a cue that fires when the segment's **active** time reaches `at_ms` (the evaluated expression). Paused time doesn't count.                                                                                                                                                                                   |
| **Reopen**         | The event `reopen(target = the terminal stop's id)`: it un-terminates a stopped (or finishing) run. The gap between the stop and the reopen is a **gap pause**.                                                                                                                                                                                        |
| **Remove**         | The event `remove(target)`: it voids a pause (its time becomes active), a lap boundary (the lap merges into the previous segment) or a reopened stop (the gap pause goes).                                                                                                                                                                             |
| **Gap pause**      | The pause from a reopened stop's `at` to its reopen's `at`. It is a `Pause` like any other once folded, so T3/T5 hold and stats count it as paused time.                                                                                                                                                                                               |
| **Revert**         | A `discard` on a run whose terminal was cleared by a reopen: the reopen becomes void `reverted`, the stop is the terminal again. The way out of an accidental reopen.                                                                                                                                                                                  |
| **Resumable**      | An entry a client offers "Resume run" for: a timed entry whose run is the topic's latest stop and whose times are **unedited** (`run.edited == false`, i.e. `timing.edited` false; answers, notes and meta changes don't count), within 15 minutes of the stop on tiles and toasts (OQ-1), and from the entry detail within 7 days of the run's start. |
| **Terminal id**    | `RunState.terminal_id`: the id of the applied stop that closed the run (null while open or discarded). A reopen names it.                                                                                                                                                                                                                              |
| **Ghost boundary** | A removed lap boundary, which still counts toward the expected `seg` of taps made between the lap and its removal (§3.5).                                                                                                                                                                                                                              |

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
VarName     = ^[a-z][a-z0-9_]{0,15}$           (stored lowercase; input case-insensitive)
Expr        = 1..64 chars, grammar §2
```

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
| `variables.{i}.name`                 | pattern (after lowercasing); unique (case-insensitive)                                               |
| `variables.{i}.ms`                   | 0 ≤ ms ≤ 604 800 000                                                                                 |
| `{steps\|laps}.{i}.alerts`           | ≤ 8                                                                                                  |
| `{steps\|laps}.{i}.alerts.{j}.key`   | pattern; unique within the owner                                                                     |
| `{steps\|laps}.{i}.alerts.{j}.label` | 1..64                                                                                                |
| `{steps\|laps}.{i}.alerts.{j}.at`    | 1..64 chars, then evaluates without error (§2); the message is `"{code} at {pos}: {detail}"`         |

Pinned in `builder-vectors.json` `timers[]` (generator
`GENERATOR_VERSION 3 → 4`), new cases: `laps-one-type`, `laps-two-types`,
`laps-max`, `laps-too-many`, `lap-key-collides-with-step`, `lap-label-65`,
`variables-max`, `variables-too-many`, `variable-name-uppercase-normalised`,
`variable-name-duplicate-case`, `variable-ms-negative`, `variable-ms-over-7d`,
`alerts-max`, `alerts-too-many`, `alert-key-duplicate`, `alert-expr-syntax`,
`alert-expr-unknown-variable`, `alert-expr-type`, `alert-expr-65-chars`,
`alert-on-step`, `v1-shape-accepted`, `output-normalised`.

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

### 2.4 Evaluation

Numbers and durations are IEEE doubles during evaluation (ms for durations:
`1.5m` = 1.5 × 60 000); the three implementations perform the same operations in
the same order, so results are bit-identical. The final duration is **truncated
toward zero to whole ms** (`int()`, `Math.trunc`, `Int()`). Intermediate values
are never rounded. A unit literal is `number × factor` with factors 1, 1 000, 60
000, 3 600 000.

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
- New `VoidReason`s: `reverted`, `not_stopped`, `deleted`, `no_target` (§3.4).
- `Event` gains `target: id | null`.

### 3.4 Replay (full pseudocode)

```
fold(timer, events_in_arrival_order):
  steps = timer.steps; laps = timer.laps
  seen = {}; terminal = null; accepted = []
  reopened = []                 // (stop S, reopen R) pairs in arrival order; the last is current
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
      else: terminal = e
      continue
    if e.type == discard:
      if terminal: void(e, already_closed); continue
      if reopened and last(reopened).R is applied:        // the terminal was cleared by a reopen: REVERT (OQ-2)
        (S, R) = pop(reopened)
        void(R, reverted); terminal = S
        for rm in removes with rm.target == S.id and applied(rm): void(rm, no_target); removed -= S.id
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
      else: apply(e); reopened += (t, e); terminal = null
      continue
    if e.type == remove:
      t = seen event with id == e.target
      eligible = t and t.id ∉ removed and e.at > t.at and
                 (t.type ∈ {pause, lap} or (t.type == stop and (t, _) ∈ reopened))
      if !eligible: void(e, no_target) else: apply(e); removed[t.id] = e
      continue
    accepted += e                                         // next, lap, skip, pause, resume

  // pass 2: time. The reopened stops and reopens take part as synthetic pause/resume roles;
  // their recorded effects are pass 1's and are not changed here.
  roles = [ gap_pause(S) for (S, R) in reopened if S.id ∉ removed ] + [ gap_resume(R) for (S, R) in reopened ]
  st = { open: Seg(step = pop(pending = steps), start = start.at, index = 0),
         paused_since: null, pause_id: null, segments: [], skipped: [], pauses: [] }
  ghosts = []                                             // (lap.at, remove.at) of removed lap boundaries
  end = terminal ? terminal.at : +∞
  expected_seg(e) = len(st.segments) + |{ g ∈ ghosts : g.at < e.at < g.removed_at }|
  for e in sort(accepted + roles, by (at, id)):           // a resume at its pause's at right after it (v1 §4.1)
    if e is a role:                                       // never recorded; skipped outside the run
      if e.at < start.at or e.at > end: continue
      gap_pause(S):  if !st.paused_since: st.paused_since = S.at; st.pause_id = S.id    // else: the pause continues
      gap_resume(R): if st.paused_since: st.pauses += [st.paused_since, R.at); st.paused_since = null
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
- **A reopen's effect is pass 1's.** Its resume role is a no-op when no pause is
  open at `R.at` (the gap pause was removed, or an offline resume ended it).
  **[deviation]** The brief voids such a reopen `not_paused`, which would
  contradict its pass-1 `applied` effect and re-terminate the run; the role is
  silent instead.
- **A later stop becomes the new terminal.** Including a stop whose `at` lies
  before the reopen (another device's offline stop): the run is then stopped at
  that `at`, the gap pause is cut there by the stop-while-paused rule, and taps
  after it are `after_stop`. A reopen targeting that stop recovers them. Rare,
  deterministic, accepted.
- **`remove` eligibility** is by type and identity only, not by the target's
  pass-2 effect: a remove of a `stale` lap applies and marks it `deleted`, which
  changes nothing. Clients only offer Remove on applied boundaries.
- **A reopen that arrives before its stop** is `no_target` for good: pass 1 is
  arrival order. From one device this can't happen: a reopen waits for the
  queued item its `target` names, as a remove does (§5.5). Across devices (B
  reopens A's stop while A's stop is still retrying) it can; B's reopen gets the
  `no_target` notice and the run stays resumable. Accepted.

### 3.5 The `seg` guard with removed laps

For an event `e` with a `seg`, the expected value is
`len(closed_at(e.at)) + |{removed lap boundaries L : L.at < e.at < remove(L).at}|`:
a boundary the tapping device still saw counts. A removed lap is a ghost only if
it would have been a boundary itself (`L.seg == expected_seg(L)` at its turn),
so a removed double tap that was already `stale` adds nothing. Monotonic
stamping (v1 §5.1) guarantees `remove.at > L.at` on the removing device; a
remove with `at ≤ L.at` from another device is `no_target`. A tap by a device
that hasn't yet seen the remove, made **after** `remove.at`, can be `stale` (it
counted the removed boundary): the same class as v1's cross-device double taps.

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
| stopped, `has_entry` | running / paused                      | **Reopen**: `status` follows the fold, `ended_at = NULL`, `revision += 1`, run upsert. **The entry stays** (id = run id, timing as of the last stop); nothing is logged for it.                                                                                                                                                                             |
| finishing            | running / paused                      | **Reopen** of a finishing run: as above; there is no entry                                                                                                                                                                                                                                                                                                  |
| stopped              | stopped                               | v1 `_merge_into_entry` (covers `remove` late merges)                                                                                                                                                                                                                                                                                                        |
| finishing            | stopped                               | v1: run upsert                                                                                                                                                                                                                                                                                                                                              |

`_close` logs `(run, delete)` only. A new `_discard` logs the delete **and**
tombstones. `_terminal_stop` (`runs.py:533-539`) returns the stop whose id is
`state.terminal_id`.

### 4.2 `record_event` additions

- `reopen` and `remove` require `target` (`_REQUIRED_FOR`).
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
  Downgrade drops the column and leaves the enum values (as `bb9d821fe436`
  documents).
- `changes.py:101-128` **MUST** emit a closed run row whose own delete row is on
  the page as a deletion **from the log row**, not from `deleted_ids`
  (`deleted_at = ChangeLog.at`): today the stop's tombstone is what makes
  `_page` emit it, and without the tombstone the deletion would be skipped
  (`vanished` without a tombstone is dropped, changes.py:117-128).
  **[addition]** to the brief, which lists no `changes.py` change.

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

### 5.1 Meaning of a `run` deletion (unchanged)

"The run is no longer open or finishing: it stopped, was discarded, or went with
its topic" (api.py `FeedDeletion`). What changes is permanence: **a run may come
back** after a deletion, as a `(run, upsert)` with a later seq and a higher
`revision`.

### 5.2 Resurrection rule (every client)

A client MUST NOT keep a permanent tombstone for a `run` deletion: it deletes
the row (and the run's alias rows) and nothing else. A later upsert inserts the
run again; the revision guard (sync-protocol.md §4.2) applies only when a row
exists. The topic cascade still tombstones the topic's runs: the topic is gone,
and the topic tombstone is checked first anyway (`ServerLayer.swift:78-81`).

- **[ios]** `ServerLayer.applyDeletion(.run)` (`ServerLayer.swift:182-192`)
  stops inserting tombstones for the run id and its aliases; it still deletes
  the `run` and `run_alias` rows. `upsert(run:)` re-inserts the aliases from
  `run.aliases`. Store migration `t2m1_run_tombstones` in a new file
  `StoreSchema+T2M1.swift`, registered after `v6` (`StoreSchema.swift:24`):
  `DELETE FROM tombstone WHERE kind = 'run'` and the same on `stage_tombstone`.
  Dependent-items rule unchanged: queued `run.event` items of a deleted run are
  kept and sent (v1 §7.2). The ack path (`OutboxFlush` →
  `ServerLayer.apply(runEvent:)`, `ServerLayer.swift:108-124`) applies a closed
  run's deletion the same way.
- **[pwa]** `src/api/runs.ts` closed-run tombstones are **already
  revision-aware** (`tombstones` keeps the closing revision and `buried`
  compares `>=`, runs.ts:26-45): a listed or responded run with a higher
  revision wins. M1 adds the resurrection tests and keeps the alias rule
  (`Infinity`: an alias never becomes a run of its own).

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
server answers `no_target`). Both outboxes implement it: the PWA in `kinds.ts`
`waitsFor` (`kinds.ts:142-170`), iOS as one more case of the outbox.md §7.1
extension in v1 §8.1. No new coalescing. A `target` is the id of an event in the
local view, queued or acked. Classification is v1 §8.1's; the new void reasons
are acks with notices (§9.3). K6 still drops a never-sent run as a whole,
reopen/remove items included. Request goldens `recordRunEvent.reopen.json`,
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
Clients: "Saved 1:30" again; the entry is visible. The device shows the
`reverted` notice only if the reopen was made elsewhere (§9.3).

### 6.3 Remove a pause; remove the gap pause after a reopen

(a) Open run: `start 0:00`, `p1 pause 1:00`, `r1 resume 1:20 (pause_id p1)`,
`e1 lap 2:00 (seg 0)`, `x1 remove 2:10 (target p1)`. After `x1`: `p1` and `r1`
are void `deleted`, `pauses []`, `Lap 1 0:00–2:00 active 120 000`. Run upsert
each time.

(b) `start 0:00`, `S stop 1:00`, `R1 reopen 1:30 (target S)`,
`x2 remove 1:40 (target S)`. After `x2`: `S` void `deleted` (the stop stays
reopened: `R1` applied, terminal null), no gap pause, the open segment runs
since 0:00 with `paused_ms 0`; the clock shows 1:40 at 1:40. A later `stop 2:00`
closes `Lap 1 0:00–2:00 (120 000)` with no pauses; entry revision 2.

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
`(entry, upsert)`, no run row. A late lap from another device at 2:00 with seg 2
still applies: expected = 1 + ghost(1:00 < 2:00 < 3:40) = 2 ✓ (a further late
merge). "Into the next" would have sent `remove(target = e2)` (the lap at 1:05).

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
(5xx): `r1` waits for `s1` (its `target`, §5.5) and `l1` goes ahead (it waits
for the start only); once `s1` is acked, `r1` goes and applies. (c) `s1` is
refused 422 `before_start` (a clock jump) → `s1` failed; a failed target holds
nothing, so `r1` goes: `no_target` (no such stop) → notice "nothing to resume".
The server's run is open since 0:00 with no gap; the local view, which leaves
failed items out of the fold (v1 §8.3), shows the same.

## 7. API **[server]**

### 7.1 Schema diffs

```
RunEventIn.type  : + "reopen" | "remove"
RunEventIn.target: UUID | null      // required for reopen (RunState.terminal_id) and remove
RunEventOut      : + target: UUID | null
VoidReason       : + "reverted" | "not_stopped" | "deleted" | "no_target"
RunOpenSegment, TimingSegment : + lap_type: str | null
RunState         : + terminal_id: UUID | null, next_lap_type: str | null, lap_count: int
Timer            : + laps: LapType[], variables: Variable[]; Step + alerts: Alert[]   (§1.1)
Limits           : + max_steps, max_lap_types, max_variables, max_alerts, max_expr_length,
                     max_var_name_length, max_short_label_length
TopicTiming      : + lap_types: [{key, label, laps, best_ms, median_ms, mean_ms}]
TimingSeriesPoint: + lap_types: {key: active_ms}
```

`RunEventIn`'s validator: `answers`/`notes` only on stop and finish (v1);
`target` only on reopen and remove (422 otherwise). `run_events.target_id`
stores it.

### 7.2 Errors

| Status | Code              | When                                                                                                       |
| ------ | ----------------- | ---------------------------------------------------------------------------------------------------------- |
| 409    | `conflict`        | `reopen` while the topic has another open run (nothing stored)                                             |
| 422    | `invalid_request` | `target` missing for reopen/remove, or present on another type; v2 `Timer` validation (§1.3, dotted paths) |
| 422    | `run_too_long`    | A re-stop more than 7 days after `started_at` (v1 rule; the revert is the way out)                         |
| 422    | `before_start`    | A re-stop before `started_at` (v1)                                                                         |

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
`laps`. `timing-stats-vectors.json` `GENERATOR_VERSION 2 → 3`, new cases
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
terminal_id: String?    // set in `end` for a stopped run, so the ended activity can offer Resume (M2 decides whether it does)
```

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
`step_index == nil` (and `lap_type`). `LiveActivityVectorTests` keeps checking
size ≤ 4 KB with 30 steps and 8 lap types of 64-character labels
(`start_longest_labels` v2).

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
- **Scheduler** diffs the plan against pending requests (by identifier) and
  adds/removes the difference: on every local-run change (`observeLocalRuns`),
  on resume from background, and after a Live Activity push updates the store.
  Cancels all `quickr.alert.{run_id}.*` on stop, discard, and when the run
  leaves the local view. Requests whose instant is already past are not
  scheduled (an alert missed while the app was dead is missed; the Live Activity
  countdown covered it).
- `LocalNotificationRequest` gains `interruptionLevel` (default `.active`) and
  `fireAt: Date?`; `SystemNotificationCenter.add` uses
  `UNTimeIntervalNotificationTrigger(timeInterval: max(1, fireAt − now))` for
  `fireAt` and keeps the calendar trigger for `fireDate` (existing callers
  unchanged). `FakeNotificationCenter` records both.
- **Foreground**: `NotificationResponder.willPresent` presents alerts with
  `.banner, .sound`; the app plays `QuickrHaptic.alert` (new case) and the run
  screen shows the alert label inline for 10 s (`RunPresentation.alertLine`).
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
  settings (`localStorage`, default on).

### 9.3 Notices (v1 §11.4 additions)

| Reason        | Text                                                                                                                          |
| ------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `reverted`    | "{topic}'s resume was undone by a discard elsewhere."                                                                         |
| `deleted`     | silent (the removed tap was deleted on purpose)                                                                               |
| `not_stopped` | silent when the run is open on this device (a double tap); otherwise "{topic} isn't stopped, so there was nothing to resume." |
| `no_target`   | "Couldn't {resume / remove that}: {topic}'s run changed."                                                                     |

`reverted` is shown only when the reverted reopen was this device's and the
discard another's; `stale` stays silent.

## 10. Client ports checklist

Owner map from the brief §5 and the research ownership tables.

**Primary and Auto rule (M1 owns the model; M2 lays it out).**
`RunPresentation.actions(run, timer, now)` / `RunPresentation.primary` on iOS
and `model.ts` `actions` / `primaryAction` on the PWA define the primary action:
**Lap**, labelled with the next lap type ("Lap → Rest"; plain "Lap" when
untyped), whenever `timer.laps` is non-empty; otherwise v1 §11.1's rule (Next
while a named step remains, Stop on the last step or with no steps). Stop is
secondary; Pause/Resume secondary; Skip, Reopen, Discard overflow. **Auto**
(`RunWrites.auto`, `RunIntentWrites`, the PWA's auto path) follows the primary:
idle → Start, else the primary. Consumers: active-surfaces.md §1 and §5.3 (run
screen, tiles, Live Activity, widgets, Control). M1 lands the `RunAction` enum
with v1's actions in its first wave, then adds `reopen`/`revert`/`remove`.

**iOS** (`ios/QuickrKit/Sources/...` unless `App/`):

- `QuickrCore/Models/Topic.swift` `TopicTimer` v2 (Codable with defaults;
  `LapType`, `Variable`, `Alert`).
- `QuickrCore/Runs/RunModels.swift` (`.reopen`, `.remove`, `target`;
  `VoidReason` + 4; `RunSegment.lapType`,
  `RunState.terminalId/nextLapType/lapCount`), `RunFold.swift` (v4, `overlay`
  lap labelling: untyped until the version is stored), `RunPresentation.swift`
  (`actions(run, timer, now) -> [RunAction]`, `headline`, `alertLine`,
  `resumable`), `TimingEdit.swift` (lap types), `TimingStats.swift` (v3), new
  `TimerExpr.swift`, `RunNoticeText.swift`.
- `QuickrData/Session/RunWrites.swift` (`.reopen(target)`, `.remove(target)`,
  `auto` follows the primary), `RunActions.swift`, `Contracts/RunDTO.swift`,
  `QuickrData/Outbox/*` ordering (reopen/remove wait for their `target` item,
  §5.5), `Store/RunOverlay.swift`, `Store/ServerLayer.swift` (§5.2), new
  `Contracts/StoreSchema+T2M1.swift` (+ one registration line),
  `Store/StoreView.swift` (§5.3).
- `QuickrCore/Runs/RunActivity.swift` (§8.1 fields),
  `QuickrData/LiveActivity/RunActivityCenter.swift` (`startFor` on reopen).
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
  item for reopen/remove, §5.5), `api/runs.ts` (tests), `api/limits.ts`
  (`FALLBACK_LIMITS`).
- `components/runs/model.ts` (`actions`, `primaryAction` with Lap, the Auto rule
  above, `headline`, `alertLine`, `resumable`), `timingEdit.ts` (lap types), new
  `RunAlerts.tsx`, `useRunActions.ts` (audio unlock), `AppShell.tsx` (mount),
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
  build is covered. The user is on TestFlight 20261028.170408; raising the
  minimum is acceptable (requirements).
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

| File                            | Generator (version)                                   | New or changed cases                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| ------------------------------- | ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `run-fold-vectors.json`         | `test_run_fold_vectors.py` (3 → 4); `timer_sets`      | every v1 case re-pinned with `lap_type`/`terminal_id`/`next_lap_type`/`lap_count`; `renamed-laps`, `tiktok-cycle`, `three-types-with-step`, `reopen-accidental-stop` (§6.1), `reopen-then-restop-labels`, `reopen-not-terminal` (`not_stopped`), `reopen-unknown-target` (`no_target`), `reopen-after-discard` (`already_closed`), `reopen-stale-at`, `reopen-too-long`, `reopen-double-tap`, `reopen-revert-by-discard` (§6.2), `reopen-revert-then-reopen-again`, `reopen-second-stop-new-terminal`, `reopen-offline-stop-earlier-than-reopen`, `reopen-stop-while-paused-pause-continues`, `reopen-lap-inside-gap` (§6.6), `remove-pause` (§6.3a), `remove-pause-resume-deleted`, `remove-gap-pause` (§6.3b), `remove-lap-merges-previous`, `remove-lap-renumbers-types` (§6.4), `remove-lap-ghost-keeps-later-lap-applied`, `remove-two-laps-ghosts-stack`, `remove-stale-lap-no-ghost`, `remove-lap-after-stop-late-merge` (§6.5), `remove-next-is-no-target`, `remove-terminal-stop-no-target`, `remove-twice-no-target`, `remove-at-before-target-no-target`, `remove-then-revert-restores-stop`, `frozen-reopen-run-edited`, `frozen-remove-entry-deleted` |
| `timer-expr-vectors.json` (new) | `test_timer_expr_vectors.py` (1)                      | §2.5 list                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `builder-vectors.json`          | `test_builder_vectors.py` (3 → 4)                     | §1.3 list                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `builder-ui-vectors.json`       | `builderUi.vectors.test.ts`                           | `new_lap_type`, `lap_type_label`, `variable`, `alert_expr`, `timer_output` v2, `timer_changes` v2                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `timing-stats-vectors.json`     | `test_timing_stats_vectors.py` (2 → 3)                | §7.4 list                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `live-activity-vectors.json`    | `test_live_activity_vectors.py` (2 → 3); `timer_sets` | §8.2 list                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `api/*.json`                    | `test_api_fixtures.py`                                | `recordRunEvent.reopen`, `recordRunEvent.restop`, `recordRunEvent.remove`, `recordRunEvent.remove_late`, `recordRunEvent.revert`, `listChanges.reopened_run`, `getLimits` (new rows), `getTopicTiming` (lap types), `getTopic` / `listTopicVersions` (normalised timer), `getRun` (MCP)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `requests/*.json`               | Swift golden generator                                | `recordRunEvent.reopen`, `recordRunEvent.remove`, `publishTopicVersion.timer_v2`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `getClientVersions` fixture     | `make vectors` after the bump                         | level 2                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |

`shared/fixtures/README.md` gains a row for `timer-expr-vectors.json`.

### 12.2 Backend (continuing timers.md §13.2)

| #   | Case                                                                                                                                                                                                                                                                                                                                        |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| T18 | Every fold v4 vector through the real endpoint gives the same `RunState`, effects and (when stopped) entry `timing` as the pure fold.                                                                                                                                                                                                       |
| T19 | Reopen of a stopped run: 200 applied, run `running`, `ended_at` null, revision + 1, `(run, upsert)` logged, the entry unchanged (same revision) and still returned by `getEntry`; `createEntry` with its id replays it.                                                                                                                     |
| T20 | Re-stop: entry `timing` and `captured_at` replaced, revision + 1, `(entry, upsert)` then `(run, delete)`; no `deleted_ids` row; a stop with answers on the re-stop merges them.                                                                                                                                                             |
| T21 | Discard after reopen (revert): run `stopped`, `ended_at` restored, `(run, delete)` logged, no tombstone, entry revision unchanged; the reopen is `reverted` in `RunOut.events`; a reopened **finishing** run's discard leaves it `discarded` with a tombstone.                                                                              |
| T22 | Reopen while the topic has another open run: 409 `conflict`, nothing stored (event count unchanged).                                                                                                                                                                                                                                        |
| T23 | Reopen on an edited run → `run_edited`; on a run whose entry was deleted → `entry_deleted`; on a discarded run → `already_closed`; naming a non-terminal stop → `not_stopped`; an unknown id → `no_target`; without `target` → 422.                                                                                                         |
| T24 | Remove on an open run (pause, lap, gap pause): applied, `(run, upsert)`; the `seg` ghost rule keeps a later lap applied (§6.4) and a tap after the remove with the renumbered `seg` applies.                                                                                                                                                |
| T25 | Remove on a stopped unedited run: late merge, entry revision + 1, `runs.edited` false, `(entry, upsert)` only; a later late lap still merges. Remove of a `next`, a terminal stop, a removed id, or with `at ≤ target.at` → `no_target`.                                                                                                    |
| T26 | A stop writes no `deleted_ids` row; a discard and a topic delete do. The data migration removes the rows of stopped runs and keeps those of discarded ones (`test_migrations.py`).                                                                                                                                                          |
| T27 | `test_feed_runs.py` T7/T8 updated: a stopped run's deletion is still emitted (from its log row); a run that stopped, reopened and re-stopped within one page is one deletion; an incremental page after a reopen carries the run as an **item** again (resurrection); `limit` cutting between the reopen's upsert and the re-stop's delete. |
| T28 | `Timer` v2 validation: every §1.3 vector; the v1 shape is accepted; output is normalised with `at_ms`; `GET /limits` carries the seven new rows; `checkTopicVersion` and MCP accept v2.                                                                                                                                                     |
| T29 | `timer_expr`: every §2.5 vector; a 65-character expression is `too_long` at 64; results are identical for the same operations in Python (the ports check the same file).                                                                                                                                                                    |
| T30 | Live Activity: an applied reopen sends `start` to push-to-start tokens (not the originating device's with `live_activity: true`); `content_state` fills `alert_at`/`alert_label` from active time, null while paused; `terminal_id` in `end`; payloads ≤ 4 KB.                                                                              |
| T31 | `getTopicTiming.lap_types` over mixed typed/untyped runs and a renamed lap type across versions; `series[].lap_types`.                                                                                                                                                                                                                      |
| T32 | MCP: `run_action reopen` defaults `target` to `terminal_id` and refuses when null; `run_action remove` requires `target`; `get_run`; `INSTRUCTIONS` mentions reopen/remove (string check).                                                                                                                                                  |
| T33 | `test_identity.py` `_mutations`: no new operations (reopen/remove reuse `recordRunEvent`); `test_compat_gate.py` passes after the level-2 bump with the two builds removed.                                                                                                                                                                 |

### 12.3 iOS (continuing §13.3)

| #   | Case                                                                                                                                                                                                                                                                                    | Class |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----- |
| R13 | Fold v4, expression, stats v3 and Live Activity v3 vectors; `TopicTimer` decodes v1 and v2 JSON                                                                                                                                                                                         | host  |
| R14 | `ServerLayer`: a `run` deletion leaves no tombstone and removes alias rows; a later upsert of the same id applies; the topic cascade still tombstones; `t2m1_run_tombstones` empties `tombstone`/`stage_tombstone` of kind run; an epoch rebuild stages a reopened run (`RunSyncTests`) | host  |
| R15 | `RunOverlay`: a queued reopen opens the run locally (entry hidden, §5.3); a queued remove relabels at once; `overlay` without the version leaves laps untyped                                                                                                                           | host  |
| R16 | Outbox: reopen/remove wait for the start and for their pending `target` item (a failed target holds nothing); K6 drops them with a never-sent run; `no_target`/`not_stopped`/`reverted` acks and their notices                                                                          | host  |
| R17 | `RunAlertPlan`: plan from open segment, paused → none, cap 8, identifiers, time-sensitive; scheduler diff adds/cancels against `FakeNotificationCenter`; cancel-all on stop/discard                                                                                                     | host  |
| R18 | `RunPresentation.actions`: Lap primary for lap-driven runs, Next otherwise, Stop secondary, Reopen/Discard overflow; `resumable` 15 min / 7 days rules                                                                                                                                  | host  |
| R19 | Builder models: lap types, variables and alerts drafts; `DraftValidation` paths; `timerChanges` text; `BuilderUIVectorTests` new sections                                                                                                                                               | host  |
| R20 | `LiveActivityReconcileTests`: a reopen this device made requests an activity (`startFor`); one made elsewhere waits for push-to-start                                                                                                                                                   | host  |
| R21 | UI test (`RunUITests`): start, lap, stop, Resume from the saved state, lap, stop; the entry shows three laps and one pause. **Run by M2** (the Resume control lives in M2-owned files); M1's sim WP keeps R22 and the resurrection tests (R14)                                          | sim   |
| R22 | UI test (`BuilderUITests`/`TimingUITests`): publish a topic with two lap types, a variable and an alert; the run screen shows "Run 1" then "Rest 1"                                                                                                                                     | sim   |
| R23 | `SystemNotificationCenterTests`: `fireAt` → interval trigger, `interruptionLevel` set                                                                                                                                                                                                   | sim   |

### 12.4 PWA

Vitest: fold v4, expression and stats vectors; `localView` (reopen hides the
entry, remove relabels, `targetOf` for reopen/remove, `makesEntry`); outbox kind
(`waitsFor`: reopen/remove wait for their pending `target` item and the start, a
failed target holds nothing; K6); `api/runs.ts` resurrection (a closed run's
tombstone is beaten by a higher-revision list row and by the reopen response);
`notices`; `alerts.ts` (next alert, paused, late drop) and `RunAlerts.tsx` with
fake timers (toast, notification when granted, mute); `model.ts`
`actions`/`resumable`; builder (`draftFromTimer` v2, `timerFromDraft`
normalised, `timerChanges`, server error paths); `RunFlow.test.tsx` reopen and
remove flows against `fakeRunServer` (v4); `EditQuestionsPage` publishes v2.

### 12.5 Device checks (not automatable)

1. Lap alert with the phone locked: the notification sounds and breaks through a
   Focus (time-sensitive); the Live Activity countdown reaches 0 at the same
   instant.
2. Lap on the PWA while the phone is locked: the phone's alerts are stale
   (OQ-11); after unlocking they are re-planned.
3. Reopen from the PWA: the phone's Live Activity reappears by push-to-start;
   reopen on the phone with the app killed (from the ended activity if M2 adds
   it): the activity is requested locally.
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

| OQ-9 | Topic tags | Owned by appearance.md (M3); not covered here | — |

**Decided (was a note here):** a `reopen`/`remove` also waits for the queued
item its `target` names (§5.5), so a reopen can't overtake its own device's
stop.

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
`get_run` so `terminal_id` is reachable (§7.3); (5) reopen is also accepted on a
`finishing` run, and its revert discards it (§4.1); (6) the PWA runs cache is
already revision-aware (§5.2).

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
