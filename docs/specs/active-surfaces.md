# Spec: active surfaces (run controls, the active home section, Live Activity, widgets)

**Status:** draft (revision 3, 2026-11-25, after review round 2). **Applies
to:** the iOS app (run screen, home, Live Activity, widgets, Controls, intents)
and the PWA (run panel, topics page, running bar, record page). **Companion
specs:** [timers2.md](timers2.md) (M1: the action model, lap types, alerts,
`reopen` and `remove`), [appearance.md](appearance.md) (M3: `TopicTheme`),
[content-display.md](content-display.md) (M4: `TopicSummaryLine`),
[timers.md](timers.md) (v1 surfaces, revised here by reference) and
[sync-protocol.md](../ios/specs/sync-protocol.md). Where this spec is silent,
timers.md §10.3 and §11 hold unchanged. **Plan:** [t2-plan.md](t2-plan.md)
(milestone M2).

## Purpose

The user's words (requirements.md, items 3, 6 and 7):

> 3. Make the "lap" button more primary in the timer type, stop is currently the
>    "main" button and lap it kindve tucked away. It should be bigger, all the
>    buttons should: if you in the control mode I want big chunky controls
>    separated from the lap table but without duplication. The same for the live
>    activities etc!

> 6. They should be more obvious on the homepage (see image!) 7. Same comments
>    as 1-5: the lap functionality needs to be better from this view!

The screenshot shows a running "Smoke-interactive" tile that looks like every
idle tile except for a "Running · 1:44 / Lap 2 0:41" line and a big orange
**Stop** block; there is no Lap control on it at all
(`ios/App/Home/Tiles/TopicTile.swift:98-115` offers Next or Stop only).

This spec owns **layout**: which action goes where, how big, on every surface
that shows an open run. It does not own what the actions are. M1 owns the action
model (`RunAction`, §1) and the events behind it; M3 owns the colours; M4 owns
the idle tile's summary text. M2 renders what those provide.

**Normative language.** **MUST**, **MUST NOT**, **SHOULD** and **MAY** follow
RFC 2119. **[server]**, **[ios]** and **[pwa]** mark who implements a rule.

## Glossary

- **Action** — one `RunAction` (§1): a kind (`lap`, `next`, `stop`, …), a role
  and an enabled flag. Produced by M1's presentation model from a run.
- **Primary** — the one action with role `primary`. Exactly one while a run is
  open (§1.2).
- **Secondary** — role `secondary`: Stop, Pause/Resume. Always visible beside
  the primary.
- **Overflow** — role `overflow` or `destructive`: in a menu (iOS toolbar
  `ellipsis.circle`; PWA "More" button).
- **Headline** — the open segment's label with its counter, from
  `headline(run)`: "Lap 3", "Rest 2 · lap 4", "Shower · 2 of 5".
- **Alert line** — the next alert's label and countdown, from
  `alertLine(run, now)`; nil while paused or when none remain.
- **Active topic** — a topic whose local view has an **open** run (running or
  paused). A finishing run is not active: it keeps v1's "Add details" treatment.
- **Active now** — the home section listing active topics, above "Due now".
- **Resumable** — `resumable(entry, now)` is true: the entry is an unedited
  timed entry of the latest stop and the stop was within 15 minutes (OQ-1).

## 1. The run action model (consumed from M1)

M1 lands this interface in its first wave (M1-ACTIONS, `RunPresentation.swift`
and `components/runs/model.ts`). `RunAction.Kind` is **complete from day one**,
`reopen` and `revert` included (A13); what arrives later is the events behind
them, and until then those kinds are simply never returned. `remove` is **not**
a kind: it is an entry-detail action (content-display.md §3.2). **M2 MUST NOT**
switch on a kind to decide placement; it switches on `role`. It MAY switch on
kind for the icon and the title.

### 1.1 Signatures

**[ios]** `QuickrCore/Runs/RunPresentation.swift` (M1-owned):

```swift
public struct RunAction: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case start
        case next(label: String)              // "Next: Shower" — the step it opens
        case lap(nextTypeLabel: String?)      // nil: untyped laps ("Lap"); "Rest": the lap it opens
        case skip(label: String)              // the step a skip would skip
        case pause, resume, stop
        case addDetails                       // finishing run
        case reopen(target: UUID)             // the terminal stop's id: entry.timing.terminalId (timers2.md §3.3)
        case revert                           // discard of a reopened run (timers2.md §3.4, §4.1)
        case discard
    }
    public enum Role: Sendable, Hashable { case primary, secondary, destructive, overflow }
    public var kind: Kind
    public var role: Role
    public var enabled: Bool
    /// Stable per kind: "start", "next", "lap", "skip", "pause", "resume", "stop",
    /// "addDetails", "reopen", "revert", "discard" — the accessibility id suffix.
    public var id: String
}

// Verbatim from timers2.md §10 (A13); M1-ACTIONS and the plans copy this block, nothing restates it.
extension RunPresentation {
    static func actions(_ state: RunState, status: RunStatus, timer: TopicTimer?, now: Date) -> [RunAction]
    static func headline(_ state: RunState, status: RunStatus, timer: TopicTimer?) -> Headline
    static func alertLine(_ state: RunState, timer: TopicTimer?, now: Date) -> String?
    static func resumable(_ entry: Entry, now: Date) -> Bool
}
```

`Headline` is M1's value type (timers2.md §10): M2 reads its `text` ("Rest 2 ·
lap 4", "Shower · 2 of 5", "Running"/"Paused" when nothing is open) and its
optional `counter` ("L4") for the compact Dynamic Island. `alertLine` returns
the rendered line ("Half way · in 0:12") or nil; the countdown instant for the
Live Activity comes from the content state's `alert_at`, not from here.

`actions` returns the list in display order: the primary first, then
secondaries, then overflow, destructive last. `timer == nil` (steps unknown,
timers.md §10.3 `steps_unknown`) yields the v1 fallback: a plain `next` primary
and no `skip`.

**[pwa]** `src/components/runs/model.ts` (M1-owned):

```ts
export type RunActionKind =
  | { type: "start" }
  | { type: "next"; label: string }
  | { type: "lap"; nextTypeLabel: string | null }
  | { type: "skip"; label: string }
  | { type: "pause" }
  | { type: "resume" }
  | { type: "stop" }
  | { type: "addDetails" }
  | { type: "reopen"; target: string }
  | { type: "revert" }
  | { type: "discard" };
export type RunActionRole =
  "primary" | "secondary" | "destructive" | "overflow";
export interface RunAction {
  kind: RunActionKind;
  role: RunActionRole;
  enabled: boolean;
  id: string;
}
// Verbatim from timers2.md §10 (A13): state + status, never a LocalRun.
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
/** Convenience over `actions`: the primary, for the tile and the running bar; null when the run isn't open. */
export function primaryAction(
  state: RunState,
  status: RunStatus,
  timer: Timer | null,
  now: number,
): RunAction | null;
```

Callers pass `run.state` and `run.status` from a `LocalRun`; the model never
takes the `LocalRun` itself, so the idle screen and the entry detail (which have
no run) can call `resumable` and build row 13 of the §1.2 table.

`PrimaryAction` (`model.ts:48`, `{type:'next'|'stop'}`) is replaced by
`primaryAction` returning a `RunAction`; `RunTile.tsx:123-127`,
`RunningBar.tsx:92-97` and `RunPanel.tsx:150-170` switch to it (§6).

### 1.2 The primary rule (defined in timers2.md §10; M2 relies on it)

timers2.md §10 is the single normative text. Quoted:

> On-screen primary = **Lap** (labelled with the next lap type when typed) when
> the open segment is a lap or no named step remains, else **Next**; **Stop is
> never primary.** Auto is separate: `timer.laps` non-empty → Auto = the
> primary; laps empty → v1 Auto (… → Stop).

In `RunState` terms: Lap when
`state.open.kind == .lap || state.nextStep == nil`. Pause/Resume are secondary
with Stop; Reopen is secondary (a visible Resume, rows 2 and 13); Skip is
overflow; Discard and Revert are `destructive` (overflow, last). This replaces
timers.md §11.1 "On the last step the primary button is **Stop**, with Lap
secondary." The Lap primary is labelled with the lap it opens:
`lap(nextTypeLabel: "Rest")`. The `actions` signature of §1.1 is the one
timers2.md §10 and M1-ACTIONS copy.

There is exactly one primary while a run is open; `start` is the primary of an
idle topic; `addDetails` the primary of a finishing run. The "Auto" advance of
one-button surfaces is §5.3.

**State → `[RunAction]` table** (B1). This is the fixture for the table-driven
tests of `actions` on both platforms (`RunPresentationTests`, `model.test.ts`):
one row per state, actions in display order as `kind` (role, enabled). `✓` =
enabled. `timer` is the run's pinned version's timer; "laps only" = `steps: []`.

| #   | State                                                  | Actions                                                                                                                                                                               |
| --- | ------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | idle, `timer == nil` (steps unknown; a reminder start) | `start` (primary ✓)                                                                                                                                                                   |
| 2   | idle, timer with steps                                 | `start` (primary ✓); `reopen(terminalId)` (secondary ✓) only when the latest entry is `resumable`                                                                                     |
| 3   | idle, laps only                                        | as 2                                                                                                                                                                                  |
| 4   | open, step open, a step remains, running               | `next(label)` (primary ✓), `stop` (secondary ✓), `pause` (secondary ✓), `skip(label)` (overflow ✓), `discard` (destructive ✓)                                                         |
| 5   | open, lap open (untyped or typed), running             | `lap(nextTypeLabel)` (primary ✓), `stop` (secondary ✓), `pause` (secondary ✓), `skip(label)` (overflow ✓ only if a step is still pending, else absent), `discard` (destructive ✓)     |
| 6   | open, last step open (`nextStep == nil`), running      | `lap(nextTypeLabel)` (primary ✓), `stop`, `pause` (secondary ✓), `skip(label)` (overflow ✓ — skips the open step), `discard` (destructive ✓)                                          |
| 7   | open, no steps, running (the stopwatch)                | `lap(nextTypeLabel)` (primary ✓), `stop`, `pause` (secondary ✓), `discard` (destructive ✓); no `skip`                                                                                 |
| 8   | open, paused (any of 4–7)                              | as the running row but `resume` replaces `pause`; the primary and `skip` are **present and ✓** (a tap while paused is valid: the fold resumes nothing, it closes the segment at `at`) |
| 9   | open, `timer == nil` (steps unknown)                   | `next("")` (primary ✓), `stop`, `pause`/`resume` (secondary ✓), `discard` (destructive ✓); no `skip`, no `lap`                                                                        |
| 10  | open after a `reopen` (terminal cleared)               | as 4–8 plus `revert` (destructive ✓) **instead of** `discard`                                                                                                                         |
| 11  | queued `reopen` not yet acked ("Resuming…" projection) | `[]` — no controls until the ack (§2.4)                                                                                                                                               |
| 12  | finishing                                              | `addDetails` (primary ✓), `discard` (destructive ✓)                                                                                                                                   |
| 13  | stopped, entry `resumable` (within OQ-1's window)      | `reopen(terminalId)` (secondary ✓) — rendered by the idle screen / tile / toast, beside `start` (primary ✓); only `start` once the window passes or the entry is edited               |
| 14  | any open state while `busy` (cooldown)                 | the same list with every `enabled == false`                                                                                                                                           |

Rows 2/13 are the same action seen from the topic and from the entry; row 13's
`reopen` is hidden while the topic has another open run (A15: the server would
answer 409 `conflict`).

**Idle rows 1–3 and 13 (M2 implementation decision, 2026-11-26).** They take the
topic's latest run: `actions(lastRun.state, lastRun.status, timer, now)` with
`stopped`/`discarded` yields `start` (primary) and, within OQ-1's window with
`terminalId` set, `reopen(terminalId)` (secondary). A topic with no run shows
`start` without calling `actions`. Row 9's `next("")` is the steps-unknown
fallback: no step label, rendered as a plain "Next" (§1.3).

**Placement.** The layout model (`RunControlsLayout` / `controlsLayout.ts`)
places by `role` only: `reopen`/`revert` land in their role's slot without code
changes. One exception: the active card's tile layout (§3.2, §6.2) picks Stop
and Pause/Resume out of the secondaries **by kind**, because they sit in
different rows.

### 1.3 Titles and icons (M2 renders)

| Kind               | Title                                   | Icon (iOS SF Symbol / PWA `Icon`) | VoiceOver / `aria-label`            |
| ------------------ | --------------------------------------- | --------------------------------- | ----------------------------------- |
| `start`            | "Start"                                 | `play` / `play`                   | "Start {topic}"                     |
| `next(label)`      | "Next: {label}"                         | `chevron.right` / `chevronRight`  | "Next: {label}"                     |
| `next("")`         | "Next"                                  | `chevron.right` / `chevronRight`  | "Next"                              |
| `lap(nil)`         | "Lap"                                   | `flag` / `flag`                   | "Lap"                               |
| `lap("Rest")`      | "Lap → Rest"                            | `flag` / `flag`                   | "Lap, then Rest"                    |
| `skip(label)`      | "Skip {label}"                          | `forward.end` / `skip`            | "Skip {label}"                      |
| `pause` / `resume` | "Pause" / "Resume"                      | `pause` / `play`                  | same                                |
| `stop`             | "Stop"                                  | `stop` / `stop`                   | "Stop {topic}"                      |
| `addDetails`       | "Add details"                           | `pencil` / `edit`                 | "Add details to {topic}"            |
| `reopen`           | "Resume run" (tile: "Resume · {total}") | `arrow.uturn.backward` / `undo`   | "Resume the last run of {topic}"    |
| `revert`           | "Undo resume…"                          | `arrow.uturn.forward` / `undo`    | "Undo the resume and keep the stop" |
| `discard`          | "Discard run…"                          | `trash` / `trash`                 | "Discard run"                       |

`…` marks a confirmation. Titles are not localised (as v1).

## 2. iOS run screen **[ios]**

`App/Runs/RunScreen.swift` is restructured; the controls move into a new
`App/Runs/RunControls.swift`; `App/Runs/RunViews.swift` keeps the shared pieces
(`RunDuration`, `RunStatusLine`, `runTicking`, `showStopOutcome`) and gains
`RunHeadline` and `RunAlertLine`.

### 2.1 Structure, top to bottom

1. **Header** (`OpenRunView`, kept): the Running/Paused badge (`run.state`),
   "Saved on this device"; the 60 pt total clock (`run.total`); the headline
   with the segment timer (`run.segment`: "Rest 2 · lap 4 0:41"); the alert line
   (`run.alert`: "Half way · in 0:12", a countdown ticking on the `RunTicker`;
   for 10 s after an alert fires, its label with a bell, per timers2.md §9: that
   label is run-screen state owned by I1-ALERTS,
   `AppEnvironment.runAlerts.label(runId:)`, not part of `alertLine`, which
   stays the persistent next-alert line and is nil when none remain). The
   headline replaces today's bare `open.label` (`RunScreen.swift:292-299`).
2. **Controls** (`RunControls`): see §2.2. Directly under the header, above the
   table, so the thumb reaches them without scrolling past the table.
3. **Table** (`StepList`, kept, `qrCard`): step rows (done, skipped, current,
   upcoming; ids `run.step.<key>`) then lap rows (`run.step.lap.<n>`) labelled
   by M1's rule ("Run 1", "Rest 1", …). A lap-type badge (the type's label,
   `QuickrBadge` neutral) sits on each typed lap row. The table contains **no
   buttons**: the `ViewThatFits` row of Lap/Skip/Pause
   (`RunScreen.swift:303-334`) is removed, as is the bottom safe-area bar
   (`:172-218`).

The whole screen scrolls; the controls are not pinned. Rationale: a pinned 72
pt + 56 pt stack hides a third of the table on a small phone; the header +
controls fit above the fold at the default text size, which is the common case.

### 2.2 `RunControls`

```swift
struct RunControls: View {
    let actions: [RunAction]            // from RunPresentation.actions
    let topic: TopicRef
    let busy: Bool                      // environment.runActions.isBusy(topic.id)
    let perform: (RunAction) -> Void
}
```

- **Primary**: one button, full width, **minimum height 72 pt**
  (`QuickrButtonSize.hero`, a new case in `QuickrUI/Components/Buttons.swift`
  beside `large` 56 pt at `Buttons.swift:13-25`), `.qr(.primary, size: .hero)`,
  font `.qr(.sansSemiBold, size: 22, relativeTo: .title2)`, icon 28 pt,
  `accessibilityIdentifier("run.primary")`. Its tint is the topic theme's
  `tint`/`onTint` (M3; accent until then).
- **Secondaries**: a row of equal-width 56 pt buttons
  (`.qr(.secondary, size: .large)`): Stop (`run.stop`, icon `stop`, danger text
  colour), then Pause or Resume (`run.pause` / `run.resume`). With the steps
  unknown the row still shows Stop and Pause.
- **Overflow**: the toolbar `Menu` (`run.menu`, kept at
  `RunScreen.swift:103-115`) lists, in order, Skip (`run.skip`, disabled when M1
  gives none), Resume run (`run.reopen`, idle screen only, §2.4), Undo resume…
  (`run.revert`), Discard run… (`run.discard`). Destructive items use
  `role: .destructive`; both confirm with the existing alert text.
- Every button is disabled while `busy` (the 450 ms cooldown, timers.md §11.1)
  or when `action.enabled` is false; the layout never changes under the finger
  (the cooldown exists for that).
- **No duplication**: an action rendered as the primary or a secondary MUST NOT
  also appear in the menu or the table.

### 2.3 Sizes at accessibility text sizes

At `dynamicTypeSize.isAccessibilitySize` the secondary row stacks vertically
(`AnyLayout(VStackLayout)` as `TileView.swift:49-51` does); the primary keeps 72
pt minimum and grows with its two-line label (`lineLimit(2)`,
`minimumScaleFactor(0.8)`, kept from `RunScreen.swift:189-190`). The total clock
keeps `minimumScaleFactor(0.5)` (`RunViews.swift:50`).

### 2.4 Idle and finishing states

- Idle (`run.start` primary at the same 72 pt): if the topic's latest entry is
  `resumable`, a 56 pt secondary **Resume · 1:44** (`run.reopen`) sits under
  Start; it sends `reopen(target: entry.timing.terminalId)` (timers2.md §3.3:
  `Timing` carries `terminal_id`, so no run row or `getRun` is needed, offline
  included) and the screen shows the open run. Offline, until the ack, the local
  view projects the run as **"Resuming…"** (timers2.md §5.3: closed segments
  from the entry, status running, the open segment continuing from `reopen.at`);
  the screen shows the header with that badge and **no controls**. The same
  action is in the overflow menu for 7 days from the entry detail (M4, OQ-1).
- Finishing: `run.addDetails` primary (72 pt); Discard run… in the menu, as v1
  (issue #74 unchanged).

### 2.5 Haptics

Start keeps `.qrHaptic(.logged, trigger: starts)` (`RunScreen.swift:122`). Lap
and Next add `.qrHaptic(.selection, trigger: taps)`; Stop `.logged`. An alert
firing in the foreground uses M1's `QuickrHaptic.alert`.

## 3. iOS home **[ios]**

### 3.1 "Active now"

`HomeView.list` (`HomeView.swift:142-180`) gains a first section:

```
HomeSection(title: "Active now", count: model.activeRows.count, tone: .live, identifier: "home.section.active")
```

shown only when `activeRows` is non-empty, above "Due now", in both the
sectioned and the searched/filtered layout (a search that matches an active
topic still shows it first). `Tone.live` is a new case of `HomeSection.Tone`
(`HomeView.swift:378`): a `timer` glyph in `accentStrong` with the same
reduce-motion-guarded pulse as `.accent` (`:389-394`).

**Partition is UI-level, no vector change.** `HomeModel`
(`QuickrData/Home/ HomeModel.swift`) adds

```swift
public var activeRows: [Row]        // rows whose runs[id] is open, most recently started first
public var inactiveSections: TopicListing.Sections<Row>   // sections with activeRows removed
public var inactiveRows: [Row]      // rows with activeRows removed (unsectioned layout)
```

computed in `relist()` from `rows`/`sections` and `openRuns`.
`TopicListing.sections(...)` (`QuickrCore/Home/TopicListing.swift`),
`home-vectors.json` and `home-due-vectors.json` are **unchanged**: an open run
already removes a topic from "Due now" (`TopicListing.swift:184-196`), and the
active partition is a view over the listing's output. `HomeModelTests` pins the
partition; no `home-active-vectors.json` is added. Rationale: the PWA partitions
the same way in `TopicsPage` (§6.2) from `tileRuns`, so both clients derive it
from one rule ("open run ⇒ active") that needs no fixture.

`badgeCount` and `dueCount` are unchanged (`timers.md §11.1`).

### 3.2 `ActiveTopicCard`

New file `App/Home/Tiles/ActiveTopicCard.swift`, used by `TopicTile.timedTile`
when `RunTileState` is `.open`; idle and finishing timed topics keep `TileView`
(`TopicTile.swift:45-68`).

```swift
struct ActiveTopicCard: View {
    let topic: ViewTopic
    let run: LocalRun
    let onOpen: () -> Void        // the run screen
}
```

The card reads `environment.runTicker.serverNow` itself and holds the ticker
with `.runTicking` while running (M2 implementation correction: no `now`
parameter).

Layout (one card, `qrCard`, tinted: background `tintSoft`, border
`tint.opacity(0.45)`, 4 pt leading bar `tint`; via `.topicTheme(for:)` from M3,
accent tokens until then):

| Row        | Content                                                                                                                                                                                                                               | Ids                                                   |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------- |
| Title      | `TopicGlyphView` (M3) + name (`.qr(.title)`); trailing a small **Pause**/**Resume** text button (44 pt target)                                                                                                                        | `tile.<slug>` (card), `tile.<slug>.pause`/`.resume`   |
| Clock      | the **segment** timer, `.qr(.sansSemiBold, size: 40, relativeTo: .largeTitle)`, `monospacedDigit`, dimmed when paused; the total to its right in `.qr(.footnote)` ("total 12:40")                                                     | `tile.<slug>.segment`, `tile.<slug>.total`            |
| Headline   | "Running · Rest 2 · lap 4" / "Paused · …" as a `QuickrBadge` (accent, or warn when paused)                                                                                                                                            | `run.status` (kept, `RunStatusLine`)                  |
| Alert line | "Half way · in 0:12" when `alertLine` is non-nil; otherwise the row collapses                                                                                                                                                         | `tile.<slug>.alert`                                   |
| Controls   | the **primary** (Lap/Next) as a 56 pt `.qr(.primary, size: .large)` filling the row, and **Stop** as a 56 pt secondary of at least `QuickrMetrics.logBlockWidth` (84 pt), at its natural width; the primary fills the rest of the row | `tile.<slug>.run` (primary, kept), `tile.<slug>.stop` |

Tapping anywhere else opens the run screen (`onOpen`), as the timed tile does
today (`TopicTile.swift:53`). The segment clock is the big one because the lap
is what the user is timing; the run total is secondary (the screenshot shows the
opposite and the user called it unclear). Stop outcomes go through
`showStopOutcome` (`RunViews.swift:99-107`); the "Saved X: 7:42" toast gains a
**Resume** action while `resumable` (OQ-1).

At accessibility sizes the controls row stacks (primary over Stop, both full
width) and the Pause/Resume text button moves under the headline.

### 3.3 Idle tiles

Unchanged in structure (`TileView`, `TopicTile.plainTile`/`timedTile`). Two
slots change by other milestones:

- theme: `.topicTheme(for: topic)` tints the accent bar, border and the Log/
  Start block (M3 patches `TileView.swift:84-88, :101-105`);
- the "Last … · 3 days ago" line (`TopicTile.lastLine`, `:182-190`) becomes
  `TopicSummaryLine(entry:questions:timer:fallback:)` (M4) for every tile with
  entries. Until M4 lands, M2 keeps `lastLine`.

An idle **timed** tile whose latest entry is `resumable` adds a text button
"Resume · 1:44" (`tile.<slug>.reopen`) in the tile's quick slot, directly under
the meta line, 44 pt tall, for 15 minutes after the stop; its target is
**`entry.timing.terminalId`** (the latest local entry's, the optimistic one
included — the run row is gone from the store by then). The stop toast's
**Resume** action (§3.2) uses the same source. On tap the card switches to
`ActiveTopicCard`; while the reopen is queued and unacked the card shows the
**"Resuming…"** badge in place of "Running" and hides its controls row
(timers2.md §5.3 projection), then the ordinary open layout on ack.

## 4. Live Activity **[ios]**

Files: `Widgets/RunActivityWidget.swift`,
`QuickrCore/Runs/RunActivityDisplay.swift` (M2); the content state
(`RunActivity.swift`, `live_activity.py`, vectors) is M1's (timers2.md §8.1) and
adds `lap_type`, `lap_count`, `next_label` for laps, `alert_at` and
`alert_label` (no `terminal_id`: Resume is never offered from an ended activity,
§4.4, so the content state carries no target); M3 adds `attributes.appearance`.

### 4.1 `RunActivityDisplay` additions

```swift
public var headline: String            // "Rest 2 · lap 4", "Shower · 2 of 5", "Lap 3"
public var lapCounter: String?          // compact Dynamic Island: "L4" (lap_count + 1 while a lap is open)
public var alert: Alert?                // nil while paused, ended, or none pending
public struct Alert: Sendable, Hashable { public var label: String; public var at: Double }  // Unix seconds
public var primary: Button              // buttons[0]
public var tint: TopicTheme?            // M3: from attributes.appearance; nil = accent
```

`Button` (`RunActivityDisplay.swift:19-41`) keeps its five cases; `title` for
`.lap` becomes "Lap → {next_label}" when the state's `next_label` is set during
a lap, else "Lap". The primary rule from the content state alone:

```
stepsUnknown == true            → .next
stepIndex != nil && nextLabel != nil → .next      // a step is open and another follows
otherwise                       → .lap            // a lap is open, or the last step is
```

(v1 tested `nextLabel != nil` only, `RunActivityDisplay.swift:104`; M1 now sets
`next_label` during typed laps, so the step check is required.) `buttons` stays
`[primary, pause|resume, stop]`; `islandButtons` stays `[primary, stop]`. Pinned
by `RunActivityDisplayTests` over the new vector cases `update_tiktok_lap`,
`update_alert_pending`, `update_alert_paused`, `start_renamed_laps`,
`update_reopened`.

### 4.2 Lock Screen and banner

```
[glyph] Topic name                                  2 of 5 | L4
0:41  Rest 2 · lap 4                     total 12:40
                                      ⏰ Half way · 0:12
[   Lap → Rest   ] [ Pause ] [ Stop ]
```

iOS truncates a Lock Screen Live Activity taller than 160 pt (ActivityKit: "The
system may truncate a Live Activity if its height exceeds 160 points"). So the
layout is two text rows and one button row:

- Row 1: the topic name, with "2 of 5", "L4" or "2 of 5 | L4" trailing.
- Row 2: the segment timer (largeTitle), then the headline, then a trailing
  stack with the total and, below it, the alert countdown (hidden when nil). The
  headline truncates first.
- The button row: the primary at ½ the width (≥ 56 pt tall), then Pause/Resume
  and Stop at ¼ each (≥ 44 pt).
- Dynamic Type is capped at the widgets' xxLarge (§7), so the button row stays
  above the 160 pt cut.

- The primary is `Button(intent:)` `.buttonStyle(.borderedProminent)` with
  `.tint(display.tint?.tint ?? Color.qr.accentStrong)`, `controlSize(.large)`,
  half the row; Stop stays `.bordered` with `Color.qr.danger`
  (`RunActivityWidget.swift:113-114`); Pause/Resume `.bordered` accent.
- The alert countdown is
  `Text(timerInterval: now...Date(timeIntervalSince1970: alert.at), countsDown: true)`
  prefixed by the label; it reaches 0:00 and stays there until the next push or
  local update (the activity cannot sound: timers2.md §9).
- The background tint is `tintSoft` when a theme is present (M3), `paper`
  otherwise (`RunActivityWidget.swift:16`).
- Ended states are unchanged (`endedText`).

### 4.3 Dynamic Island

| Region            | Content                                                                              |
| ----------------- | ------------------------------------------------------------------------------------ |
| compact leading   | `lapCounter` ("L4") during a lap; the step number in a step; `timer` glyph otherwise |
| compact trailing  | the segment timer (unchanged)                                                        |
| minimal           | the segment timer (unchanged)                                                        |
| expanded leading  | segment timer (title)                                                                |
| expanded trailing | total timer (footnote) and, under it, the alert countdown when pending               |
| expanded center   | `headline`                                                                           |
| expanded bottom   | `islandButtons`: the primary (prominent, 2/3 width) and Stop (1/3)                   |

### 4.4 Taps

Unchanged: `RunActivityButtonIntent(button, attributes:, state:)` carries `seg`
from the content state (`QuickrData/Intents/RunActivityIntents.swift`); a Lap
tap is `.lap` as today. No new intent is added for M2; `reopen` is never offered
from the activity (it has ended by then; the ended state shows "Saved · 7:42"
for 15 minutes and the tile is one tap away). This is M2's decision, in writing:
the content state therefore has no `terminal_id` (adjudication C3).

## 5. Widgets and Controls **[ios]**

### 5.1 Topic widget (`WidgetViews.timedHome`, `WidgetViews.swift:251-304`)

- The open state shows `headline` instead of the bare label (`:265`) and, on
  medium and large, the alert line under the total when pending.
- `runControls`: the primary chip (Lap/Next, title per §1.3, `widgetAccentable`
  filled with the theme tint in full-colour mode) and Stop. Small: one chip, the
  one-button rule of §5.3. `WidgetTopic.runButtons(compact:)`
  (`WidgetTopic.swift:126-138`) already takes `display.buttons.first`, so the
  §4.1 rule flows through; `compact` changes per §5.3.
- `WidgetRunButton` (`:101-112`) is unchanged; `runButtonLabel(.lap)` becomes
  "Lap, then {next_label}" when set.
- Tinted and accented rendering modes (`WidgetStyle.isAccented`,
  `WidgetViews.swift:32-45`): no fills; the primary chip is outlined and
  `widgetAccentable`, exactly as today's chips.

### 5.2 Timer Control (`Widgets/TopicControl.swift:157-181`)

`TimerControlValue(shown)` detail text: "Start" (idle), "Next: {label}" (a step
follows), **"Lap"** or **"Lap → Rest"** (the primary is Lap; icon `flag`),
"Stop" only in the §5.3 carve-out (icon `stop`), "Add details" (finishing,
intent opens the app). The control's one button runs
`RunWidgetIntent(action: .auto)`, unchanged. **No second Control kind is
added**: one Control is one button, and the small widget and Siri cover the
rest.

### 5.3 The one-button rule ("Auto")

One-button surfaces are the Control, the small widget, the Action button
(`AdvanceRunIntent`) and the Siri topic phrase. timers.md §11.1 defined Auto as
idle → Start; a named step remains → Next; otherwise → Stop. The brief (§2) says
widgets and Controls mirror the primary rule, and that "Auto already does the
primary". Read literally, a stepless stopwatch (the dishwasher) could then never
be stopped from a Control. The rule is **defined by M1 (timers2.md §10)** and
consumed here:

- `timer.laps` non-empty (the topic declares lap types): Auto **is the primary**
  (Start → Lap → Lap …); Stop is never Auto.
- `timer.laps` empty: v1 Auto is kept (Start → Next … → **Stop**), so the
  one-press dishwasher still works. On such a topic the on-screen primary is
  still Lap per §1.2; only the one-button surfaces differ, and their detail text
  says what they will do.

The Auto rule is implemented in M1's **I1-WRITES** WP (`RunWrites.auto`,
`RunWrites.swift:212-229`, and the PWA equivalent in `actions.ts`), not in
M1-ACTIONS, which ships the on-screen primary only (A13). M2 only renders what
`RunWrites.auto` decides. `RunActionKind` (Siri,
`QuickrData/Intents/RunIntents.swift:52-76`) gains `lap` ("Lap the timer in
quickR"); the App Shortcut count stays at one for runs (timers.md §11.3).

## 6. PWA **[pwa]**

### 6.1 Run panel (`RunPanel.tsx`, new `RunControls.tsx`)

`RunPanel` (`RunPanel.tsx:33-191`) is restructured as §2.1: header card (badge,
total `text-[3.75rem]`, headline + segment `Duration`, alert line
`data-testid="alert-line"`), then `<RunControls/>`, then `<Steps/>` without the
`grid-cols-3` control row (`:110-137`) and without the Discard link
(`:139-146`). `StickyActions` (`AppShell.tsx:157-176`) is no longer used by the
open state; `RunStart` keeps it for Start.

```tsx
export function RunControls({
  actions,
  busy,
  onAction,
}: {
  actions: RunAction[];
  busy: boolean;
  onAction: (a: RunAction) => void;
}): JSX.Element;
```

- Primary: `<Button size="hero" variant="primary">` — a new `hero` size in
  `ui/Button.tsx` (`min-h-[4.5rem]` = 72 px, `text-xl`, icon `size-7`), full
  width, `data-testid="run-primary"`, tinted by `--topic-tint`/`--topic-on-tint`
  (M3; accent until then).
- Secondaries: a `grid grid-cols-2 gap-2` of `size="lg"` (56 px) secondary
  buttons: Stop (`data-testid="run-stop"`, `text-danger`), Pause/Resume
  (`run-pause` / `run-resume`).
- Overflow: an `IconButton` "More" (`run-more`) opening a `Sheet` listing Skip,
  Resume run, Undo resume…, Discard run… (the last two through `ConfirmSheet`
  with the existing copy, `RunPanel.tsx:173-188`).
- `disabled` = `busy || !action.enabled`.

### 6.2 Topics page and `ActiveTopicCard.tsx`

`TopicsPage.tsx` computes
`active = items.filter(t => { const r = tileRuns.get(t.id); return r && isOpen(r) })`
and removes those ids from `sections.due/upcoming/other` and from the
unsectioned list; it renders `<Section title="Active now" tone="live">` first
(`id="section-active-now"` by the existing rule at `TopicsPage.tsx:310`),
whenever `active` is non-empty, sectioned or not. `splitByDue` and
`home-due-vectors.json` are unchanged (the same decision as §3.1).

`<ActiveTopicCard topic run now/>` (`src/components/topics/ActiveTopicCard.tsx`)
mirrors §3.2: `<article>` with `style={topicStyle(topic.appearance)}` (M3),
`bg-topic-tint-soft border-topic-tint/45` (the one utility set of appearance.md
§4.2), a 4 px `bg-topic-tint` left bar; title row with `<TopicGlyph/>` and a
Pause/Resume text button (`data-testid="card-pause"` / `card-resume`); the
segment `Duration` at `text-5xl`, total beside it; the status badge
`data-testid="card-status"` ("Running · {headline}"; the card does not reuse
`<RunStatus/>`, whose total and segment the clock row already shows); alert
line; controls row: the primary
(`<Button size="lg" variant="primary" className="flex-1">`,
`data-testid="card-primary"`) and Stop (`w-[5.25rem]`, `card-stop`). The whole
card links to `/t/{slug}/record`. `TopicTile` renders it instead of its own
markup when `running` (`TopicTile.tsx:102`).

### 6.3 Tile, running bar, record page

- `RunTileAction` (`RunTile.tsx:79-152`) is used only by idle and finishing
  timed tiles now; `useRunPrimary` (`:159-192`) returns
  `primaryAction(run, timer)` with `onTap` dispatching `lap` as it does `next`.
  The running bar (`RunningBar.tsx:84-99`) renders the primary's icon and title
  (`flag`/"Lap → Rest"), no Stop (the bar links to the panel). The running bar
  leaves out a run whose controls are already on screen: the run panel's, and an
  "Active now" card's (each card registers its topic while mounted). A running
  topic the topics page doesn't list keeps its bar row.
- `RecordPage` timed branch: idle `RunStart` gains "Resume · 1:44"
  (`run-reopen`) under Start while `resumable(lastEntry)`, target
  `lastEntry.timing.terminal_id` (`last_entry` from the topic summary,
  content-display.md §2, or the optimistic entry); `onStopped`
  (`RecordPage.tsx:272-281`) passes a toast
  `action: { label: 'Resume', onClick }` for 15 minutes with the same target. A
  queued, unacked reopen renders the panel header with a "Resuming…" badge and
  no `RunControls` (the `localView` projection of timers2.md §5.3). **Undo
  resume** on such a run is a revert: the outbox MUST NOT K6-coalesce it
  (timers2.md §5.5, `k6-not-on-revert`), so the saved entry survives.
- `useRunActions.tap` already accepts any `TapType`; `reopen`/`remove` are M1's
  additions to `actions.ts`.

## 7. Motion, haptics, accessibility

- **Reduce motion.** Every animation goes through `withQRAnimation` /
  `qrAnimation` / `@QuickrReduceMotion` (`QuickrUI/Tokens/Motion.swift`);
  `ios/scripts/lint-motion.sh` fails the gate on a bare `withAnimation`. The
  "Active now" pulse and the card's primary press scale are off under Reduce
  Motion; the PWA uses `motion-reduce:hidden` on the pulse
  (`TopicsPage.tsx:322`) and `motion-reduce:transform-none`.
- **Dynamic Type.** At accessibility sizes: secondaries stack (§2.3), the active
  card stacks its controls (§3.2), the home list is a plain `VStack`
  (`HomeView.swift:185-192`). Widgets cap at `xxLarge`
  (`WidgetStyle.largestTypeSize`).
- **VoiceOver.** The active card is one container
  (`accessibilityElement(children: .contain)`) whose first element is the
  title + headline + clock combined (`.updatesFrequently` while running; UI
  tests read `tile.<slug>.segment` / `.total` / `run.status` values from that
  element's label), then the controls in order primary, Stop, Pause. The clock
  keeps `RunPresentation.spoken(ms)` labels (`RunViews.swift:51`). The "Active
  now" header reads "Active now, 1".
- **Tap targets.** Everything tappable is ≥ 44 pt; the primary ≥ 72 pt; the
  tile's Pause text button has a 44 pt hit area despite its small glyph.
- **Haptics** as §2.5; the PWA keeps its 10 ms `buzz()` per tap
  (`useRunActions.ts:28-34`).

## 8. Seams

### 8.1 Provides (M2 → others)

| Interface                                         | Consumers                    | Notes                                                                  |
| ------------------------------------------------- | ---------------------------- | ---------------------------------------------------------------------- |
| `RunControls` (iOS, PWA)                          | M4 entry detail (Resume run) | M4 renders a single `RunAction` row with `RunControls` secondary style |
| `ActiveTopicCard`                                 | —                            | home only                                                              |
| `QuickrButtonSize.hero`, PWA `Button size="hero"` | M1 builder? no; M4 none      | shared UI; added in M2's first WP                                      |
| `HomeSection.Tone.live`                           | —                            |                                                                        |
| `RunActivityDisplay.headline/alert/primary/tint`  | widgets (M2), tests          |                                                                        |

### 8.2 Consumes (others → M2), with the behaviour before the provider lands

| Interface                                                                                                                                           | Provider                                    | Before it lands                                                                                                                                             |
| --------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `RunAction`, `actions`, `headline`, `alertLine`, `resumable` (§1)                                                                                   | M1-ACTIONS (hard edge)                      | M2 layout WPs do not start. The stub ships v1 kinds; `reopen`/`revert`/`remove` come later and need no layout edit                                          |
| `RunState.terminalId`, `nextLapType`, `lapCount`, `Segment.lapType`                                                                                 | M1                                          | `headline` falls back to `open.label`; `lapCounter` nil                                                                                                     |
| `Timing.terminalId` (the tile/toast/idle-screen Resume target, timers2.md §3.3); the "Resuming…" projection (§5.3); K6 exemption for reverts (§5.5) | M1                                          | Resume is not shown on tiles/toasts/idle screens until `Timing.terminalId` exists; `ActiveTopicCard` treats a run with a queued `reopen` as plain "Running" |
| Content state fields `lap_type`, `lap_count`, `alert_at`, `alert_label`                                                                             | M1 (patch to `RunActivity.swift` + vectors) | optional: `RunActivityDisplay` treats them as nil (no alert line, step-number compact)                                                                      |
| `TopicTheme`, `.topicTheme(for:)`, `TopicGlyphView`; PWA `topicStyle`, `<TopicGlyph/>`                                                              | M3 (soft)                                   | `TopicTheme.default` = accent tokens, no glyph: M2 codes against the protocol in appearance.md §4 and ships a one-file default until M3 merges              |
| `attributes.appearance`                                                                                                                             | M3                                          | nil → accent tint                                                                                                                                           |
| `TopicSummaryLine`                                                                                                                                  | M4 (soft)                                   | idle tiles keep `lastLine` / the PWA "Last …" span                                                                                                          |
| Auto rule in `RunWrites.auto` (§5.3, timers2.md §10)                                                                                                | M1 **I1-WRITES**                            | until I1-WRITES merges the Control keeps v1 Auto; M2 renders the detail text from the returned action                                                       |

**Rendering by role, stated once:** M1-ACTIONS (first wave) ships the complete
`RunAction` enum (`reopen` and `revert` included, A13) while its `actions` still
returns only today's kinds. M2 places buttons by `role` (`primary` / `secondary`
/ `destructive` / `overflow`) and MUST NOT special-case a kind for placement, so
when M1's later WPs start returning `reopen` and `revert` they appear in the
right slot with no layout edit; the only per-kind code in M2 is the title/icon
table of §1.3.

## 9. Tests

| Where                                                 | Runs on       | What                                                                                                                                                                                           |
| ----------------------------------------------------- | ------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `RunActivityDisplayTests`                             | host          | §4.1 primary rule over every `live-activity-vectors.json` case incl. the five new ones; `headline`, `lapCounter`, `alert` nil while paused                                                     |
| `HomeModelTests`, PWA `RunTile.test.tsx` (projection) | host / vitest | a queued unacked `reopen` from an entry yields an active row/card in the "Resuming…" state with no controls; the target sent equals `entry.timing.terminal_id`; on ack the card shows controls |
| `HomeModelTests`                                      | host          | `activeRows` partition: open run ⇒ active and absent from `inactiveSections`; paused counts; finishing does not; ordering by `startedAt`                                                       |
| `TimedWidgetTests`, `WidgetControlTests`              | host / sim    | `runButtons` lap primary; `TimerControlValue` detail "Lap → Rest" / "Stop" per §5.3 on a `laps: []` timer                                                                                      |
| `RunUITests`                                          | simulator     | one flow: start → lap (primary, `run.primary`) → pause → resume → stop (secondary `run.stop`) → answers; asserts the table has no buttons and `run.lap` is absent while Lap is primary         |
| `HomeTests`                                           | simulator     | one flow: start from a tile → `home.section.active` appears first with `tile.<slug>.run` (Lap) and `tile.<slug>.stop` → stop → section disappears; XXXL variant stacks the controls            |
| `WidgetViewsUITests`                                  | simulator     | gallery screenshots: timed small/medium/accessory, light/dark/tinted, with a lap primary and an alert line                                                                                     |
| Device checks (DEVICE-DAY)                            | device        | Live Activity: primary prominence, alert countdown reaching 0:00, Dynamic Island compact "L4"; a Lap tap from the Lock Screen                                                                  |
| PWA `RunFlow.test.tsx`                                | vitest        | the panel renders `run-primary` = Lap on a lap, Stop secondary, "More" holds Skip/Discard; disabled under cooldown; no duplicate control in the steps list                                     |
| PWA `TopicsPage.test.tsx` (new), `TopicTile.test.tsx` | vitest        | "Active now" section first, active topic absent from other sections; `ActiveTopicCard` primary/Stop/Pause test ids; search keeps the active section                                            |
| PWA `RunTile.test.tsx`                                | vitest        | running bar renders the lap primary; idle tile shows Resume within 15 min of a stop (fake clock), not after                                                                                    |

Sim WPs are the last wave of the milestone (≤ 1 at a time per brief §6); vectors
are M1's, consumed here.

## 10. Open questions

- **OQ-1** (brief) — `resumable` window on tiles and toasts: default **15
  minutes**; from the entry detail, 7 days from the start (M4). M2 only reads
  the predicate.
- **OQ-M2-a** — one-button Auto on lap-typed topics never stops (§5.3; owned by
  M1, timers2.md §10). Default as written; the alternative (Auto = primary
  everywhere) strands the dishwasher Control.
- **OQ-M2-b** — pinned vs scrolling controls on the run screen (§2.1). Default:
  scrolling. Revisit if device checks show the table pushing the controls off a
  4.7" screen at large text.
- **OQ-M2-c** — the active card's big clock is the **segment**, not the total
  (§3.2). Default as written; one toggle in Settings is not planned.

## 11. Decisions

- D-1 Roles decide placement; kinds decide titles and icons (§1).
- D-2 Stop is never the primary on any surface; the Lap primary carries the next
  lap type's label (§1.2, brief §2).
- D-3 Controls sit between the header and the table and the table has no buttons
  (§2.1); the v1 bottom bar and the Lap/Skip/Pause row go.
- D-4 "Active now" is a UI-level partition by open runs; `TopicListing`,
  `splitByDue` and their vectors are untouched (§3.1, §6.2).
- D-5 Auto follows the primary only on lap-typed timers; the rule is M1's
  (timers2.md §10) and M2 consumes it (§5.3).
- D-6 No second Control; no new Live Activity intent (§4.4, §5.2).
- D-7 The active card's dominant clock is the segment timer (§3.2).
- D-8 `hero` button size (72 pt / 72 px) is added to both design systems rather
  than special-casing the run screen.

## 12. Traceability

| User item                                      | Where                                     |
| ---------------------------------------------- | ----------------------------------------- |
| 3 Lap primary, big chunky controls             | §1.2, §2.2, §6.1                          |
| 3 separated from the lap table, no duplication | §2.1 (D-3), §6.1                          |
| 3 "the same for the live activities etc."      | §4, §5                                    |
| 6 active topics obvious on the home page       | §3.1, §3.2, §6.2                          |
| 7 lap functionality from the home view         | §3.2 controls row, §6.2, §6.3 running bar |
| 2 resume a session (surface only)              | §2.4, §3.3, §6.3; events in timers2.md    |
| 5 alerts visible while running                 | §2.1 alert line, §4.2 countdown, §5.1     |
| 9 colour on active surfaces                    | §3.2, §4.2, §6.2 via appearance.md        |

## 13. Review log (round 1)

| Finding                                                                  | Outcome                                                                                                                                             |
| ------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| K-S1 three primary rules across timers2 §10 / M2 / M1-ACTIONS            | Fixed in §1.2 (A9, D9): timers2.md §10 quoted verbatim as the single normative text; Auto stated separately                                         |
| K-S1 clients have no source for a stopped run's reopen/remove target     | Fixed in §1.1, §2.4, §3.3, §6.3, §8.2 (A7, D9): targets come from `entry.timing.terminal_id`; "Resuming…" projection without controls until the ack |
| K-S1 K6 erases a saved run on an offline revert                          | Fixed in §6.3 (A8): Undo resume is a revert and MUST NOT coalesce; rule and vectors are M1's (timers2 §5.5)                                         |
| C-S2 / K-S3 `terminal_id` in the content state has no consumer           | Fixed in §4, §4.4 (C3): dropped; M2 owns the decision that an ended activity never offers Resume                                                    |
| K-S2 / C-S3 wrong timers2 section references; three `actions` signatures | Fixed in §1.1, §2.1, §4, §4.2 (D8): §3.4/§4.1, §8.1, §9; the §1.1 signature is canonical                                                            |
| K-S3 id drift (`tile.<slug>.run`, `run.menu`)                            | No change here (D8): the spec's ids stand; the plan aligns to them                                                                                  |
| K-S2 I2-LA dependency on M1-LA-STATE is hard                             | Plan matter (M2-plan); §8.2 already lists the content-state fields as M1-provided with nil fallbacks                                                |

### Round 2

| Finding                                                      | Outcome                                                                                                                         |
| ------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------- |
| K-S1 `actions` signature still three things                  | Fixed in §1.1 (A13/B2): both platforms' signatures copied verbatim from timers2.md §10; PWA takes `state, status, timer, now`   |
| K-S2 the seven-state table cited by the plans does not exist | Fixed in §1.2 (B1): 14-row state → `[RunAction]` table, the fixture for the table-driven tests                                  |
| K-S2 M1-ACTIONS cannot implement Auto; `RunIntentWrites`     | Fixed in §5.3, §8.2 (A13/B2): Auto lands in I1-WRITES; M1-ACTIONS ships the on-screen primary only                              |
| K-S3 `RunAction.Kind` from day one; `remove` as a kind       | Fixed in §1 (A13): enum complete from day one; `remove` is an entry-detail action, not a kind                                   |
| K-S2 accessibility-id drift                                  | No change (B3): ids live here (§2.2 `run.menu`, §3.2 `tile.<slug>.run\|stop\|pause\|resume\|reopen`); plans stop repeating them |
| K-S3 "timers2.md §7.1" for the Resuming projection           | Fixed in §2.4, §3.3, §6.3, §8.2: §5.3                                                                                           |
| K-S3 PWA topic utilities have three spellings                | Fixed in §6.2 (B6): the appearance.md §4.2 set                                                                                  |

### M2 implementation corrections

| Finding                                                  | Outcome                                                                                                                              |
| -------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| I2-LA: iOS truncates a Lock Screen activity above 160 pt | Fixed in §4.2: two text rows and one button row (primary ½, Pause/Resume ¼, Stop ¼); Dynamic Type capped at xxLarge                  |
| M1 seams (rows 1–3, 9, 13; 10 s alert label)             | Fixed in §1.2, §1.3, §2.1: idle rows from the latest run; `next("")` → "Next"; `reopen` secondary; the 10 s label is I1-ALERTS state |
| I2-HOME / F2-HOME / F2-BAR / MODEL-ADOPT                 | Fixed in §1.2 (placement), §3.2 (no `now`, Stop width, combined element), §3.3 (Resume slot), §6.2 (`card-status`), §6.3 (bar)       |
