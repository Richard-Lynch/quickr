import Foundation

/// What the run surfaces show (timers.md §11.1, §11.2), from a run's fold state and its pinned
/// version's steps: the ticking totals, the primary button, Skip's target and the step checklist.
/// The PWA's `components/runs/model.ts`.
///
/// Pure. Instants are epoch milliseconds on the server's clock, as the run's are. `steps` nil
/// means the pinned version isn't known here yet: the clock still runs, Skip is off, there is no
/// step list, and the primary button is a plain Next (with Stop beside it), since a step may
/// remain.
public enum RunPresentation {
    // MARK: - Clocks

    /// The time inside `from...to` covered by `pauses` and the open pause (since `pausedSince`).
    static func paused(within from: Int, _ to: Int, pauses: [RunPause], pausedSince: Int?) -> Int {
        var all = pauses
        if let pausedSince { all.append(RunPause(start: pausedSince, end: to)) }
        return all.reduce(0) { sum, pause in sum + max(0, min(pause.end, to) - max(pause.start, from)) }
    }

    /// The run's active time so far: wall time minus paused time, up to `now` or its end. A
    /// `now` read before the open pause began (a clock that hasn't ticked since) counts as the
    /// pause's start, so a paused clock never runs backwards.
    public static func activeMs(_ state: RunState, now: Int) -> Int {
        let now = max(now, state.pausedSince ?? now)
        let end = state.endedAt ?? max(now, state.startedAt)
        let paused = paused(within: state.startedAt, end, pauses: state.pauses, pausedSince: state.pausedSince)
        return end - state.startedAt - paused
    }

    /// The open segment's active time so far; 0 once the run has closed.
    public static func segmentMs(_ state: RunState, now: Int) -> Int {
        guard let open = state.open else { return 0 }
        let now = max(now, state.pausedSince ?? now)
        let to = max(now, open.startedAt)
        return to - open.startedAt
            - paused(within: open.startedAt, to, pauses: state.pauses, pausedSince: state.pausedSince)
    }

    // MARK: - Controls

    /// The primary button (§11.1): "Next: {next step}" while a named step remains, else Stop
    /// (with Lap beside it). Unknown steps: a plain "Next", with Stop beside it.
    public enum Primary: Sendable, Hashable {
        case next(label: String)
        case stop

        public var title: String {
            switch self {
            case .next(let label): label
            case .stop: "Stop"
            }
        }

        public var isNext: Bool {
            if case .next = self { return true }
            return false
        }
    }

    public static func primary(_ state: RunState, steps: [TopicTimer.Step]?) -> Primary {
        guard let steps else { return .next(label: "Next") }
        guard let key = state.nextStep else { return .stop }
        return .next(label: "Next: \(label(of: key, in: steps))")
    }

    /// The step a Skip would skip: the open step, or after a lap the next one (§4.2). Nil when no
    /// step is left, the run isn't open, or the steps aren't known (a skip must name its step).
    public struct SkipTarget: Sendable, Hashable {
        public var key: String
        public var label: String
    }

    public static func skipTarget(_ state: RunState, steps: [TopicTimer.Step]?) -> SkipTarget? {
        guard let open = state.open, let steps else { return nil }
        guard let key = open.kind == .step ? open.step : state.nextStep else { return nil }
        let label = open.kind == .step && open.step == key ? open.label : label(of: key, in: steps)
        return SkipTarget(key: key, label: label)
    }

    static func label(of key: String, in steps: [TopicTimer.Step]) -> String {
        steps.first { $0.key == key }?.label ?? key
    }

    // MARK: - RunAction (timers2.md §10; active-surfaces.md §1.1–§1.2)

    /// OQ-1: how long after its stop a run is offered "Resume run" on tiles, toasts and the run
    /// screen (timers2.md glossary, "Resumable").
    public static let reopenWindowMs = 15 * 60 * 1000

    /// The run's actions in display order: the primary first, then secondaries, then overflow,
    /// destructive last (active-surfaces.md §1.1, §1.2). The on-screen primary rule (timers2.md
    /// §10): Lap when the open segment is a lap or no named step remains, labelled with the lap it
    /// opens when the timer has lap types ("Lap → Rest"), else Next with the step it opens; Stop is
    /// never primary. `timer == nil` (steps unknown) is the v1 fallback: `next(label: "")`, which
    /// §1.3 renders as a plain "Next", and no `skip`, no `lap`.
    ///
    /// - An open run reached by a reopen (`state.reopenId`) offers `revert` instead of `discard`
    ///   (row 10).
    /// - A closed run (stopped or discarded) is idle (rows 1–3): `start` (primary). A stopped run
    ///   with a terminal also offers `reopen(terminalId)` (secondary) within `reopenWindowMs` of
    ///   its stop (row 13). The store-level rules (the entry unedited, the latest stop, no other
    ///   open run: A15) are `resumable`'s and the surface's. A topic with no run doesn't call this.
    /// - A finishing run: `addDetails`, `discard` (row 12).
    ///
    /// Not expressible here: rows 11 (a queued reopen's "resuming" run shows no controls) and 14
    /// (busy: every `enabled` false). `RunActions.actions(for:timer:now:)` adds both. Every
    /// action returned here is enabled.
    // Verbatim from timers2.md §10 (A13).
    public static func actions(_ state: RunState, status: RunStatus, timer: TopicTimer?, now: Date) -> [RunAction] {
        switch status {
        case .finishing:
            return [
                RunAction(kind: .addDetails, role: .primary, enabled: true),
                RunAction(kind: .discard, role: .destructive, enabled: true),
            ]
        case .stopped, .discarded:
            var out = [RunAction(kind: .start, role: .primary, enabled: true)]
            if status == .stopped, let id = state.terminalId, let target = UUID(uuidString: id),
                let end = state.endedAt, RunInstant.milliseconds(now) - end <= reopenWindowMs
            {
                out.append(RunAction(kind: .reopen(target: target), role: .secondary, enabled: true))
            }
            return out
        case .running, .paused:
            break
        }
        let primary: RunAction.Kind
        if let timer {
            if state.open?.kind == .lap || state.nextStep == nil {
                let next = state.nextLapType.flatMap { key in timer.laps.first { $0.key == key }?.label }
                primary = .lap(nextTypeLabel: next)
            } else {
                primary = .next(label: label(of: state.nextStep ?? "", in: timer.steps))
            }
        } else {
            primary = .next(label: "")
        }
        var out = [
            RunAction(kind: primary, role: .primary, enabled: true),
            RunAction(kind: .stop, role: .secondary, enabled: true),
            RunAction(kind: status == .paused ? .resume : .pause, role: .secondary, enabled: true),
        ]
        if let skip = skipTarget(state, steps: timer?.steps) {
            out.append(RunAction(kind: .skip(label: skip.label), role: .overflow, enabled: true))
        }
        out.append(RunAction(kind: state.reopenId != nil ? .revert : .discard, role: .destructive, enabled: true))
        return out
    }

    /// The open segment's label with its counter (active-surfaces.md §1.1):
    ///
    /// - a typed lap: "{label} · lap {n}" ("Rest 2 · lap 4"), counter "L{n}", where n is the lap's
    ///   number in the run (`lapCount + 1`);
    /// - an untyped lap: its label ("Lap 3"), counter "L3";
    /// - a step: "{label} · {position} of {count}" over the timer's steps ("Shower · 2 of 5"), no
    ///   counter; the bare label when the timer isn't known or lacks the step;
    /// - nothing open: "Running", or "Paused" while `status` is paused.
    public static func headline(_ state: RunState, status: RunStatus, timer: TopicTimer?) -> Headline {
        guard let open = state.open else {
            return Headline(text: status == .paused ? "Paused" : "Running", counter: nil)
        }
        switch open.kind {
        case .lap:
            let n = state.lapCount + 1
            let text = open.lapType != nil ? "\(open.label) · lap \(n)" : open.label
            return Headline(text: text, counter: "L\(n)")
        case .step:
            guard let steps = timer?.steps, let index = steps.firstIndex(where: { $0.key == open.step }) else {
                return Headline(text: open.label, counter: nil)
            }
            return Headline(text: "\(open.label) · \(index + 1) of \(steps.count)", counter: nil)
        }
    }

    /// The next alert of the open segment and its countdown: "Half way · in 0:12"
    /// (active-surfaces.md §1.1). The alerts are the open step's or lap type's (timers2.md §1.1),
    /// in `atMs` order then position; the next is the first whose `atMs` is beyond the segment's
    /// active time now (paused time doesn't count). Nil while paused, when nothing is open, when
    /// the timer isn't known, or when none remain. The countdown is `fmtDuration` (truncated).
    public static func alertLine(_ state: RunState, timer: TopicTimer?, now: Date) -> String? {
        guard let open = state.open, state.pausedSince == nil, let timer else { return nil }
        let active = segmentMs(state, now: RunInstant.milliseconds(now))
        let next = timer.alerts(step: open.step, lapType: open.lapType).enumerated()
            .compactMap { index, alert in alert.atMs.map { (at: $0, index: index, label: alert.label) } }
            .filter { $0.at > active }
            .min { ($0.at, $0.index) < ($1.at, $1.index) }
        guard let next else { return nil }
        return "\(next.label) · in \(DurationFormat.format(next.at - active))"
    }

    /// OQ-1: from the entry detail, a run can be reopened within 7 days of its start.
    public static let entryReopenWindowMs = 7 * 24 * 60 * 60 * 1000

    /// The entry's half of "resumable" (timers2.md glossary, OQ-1) on tiles, toasts and the run
    /// screen: a timed entry whose times are unedited (`timing.edited == false`, i.e.
    /// `run.edited == false`; answers, notes and meta changes don't count), within
    /// `reopenWindowMs` of its stop. The store's half (the entry is the topic's latest stop, the
    /// topic has no locally open run: A15, and the run isn't open here already) is
    /// `RunOverlay.resumable(_:entryId:now:)`, which surfaces call; `Entry` alone can't tell.
    public static func resumable(_ entry: Entry, now: Date) -> Bool {
        guard let timing = entry.timing, !timing.edited else { return false }
        return RunInstant.milliseconds(now) - timing.endedAt <= reopenWindowMs
    }

    /// `resumable` from the entry detail (OQ-1): unedited, within `entryReopenWindowMs` of the
    /// run's start.
    public static func resumableFromDetail(_ entry: Entry, now: Date) -> Bool {
        guard let timing = entry.timing, !timing.edited else { return false }
        return RunInstant.milliseconds(now) - timing.startedAt <= entryReopenWindowMs
    }

    // MARK: - The step list

    public enum StepStatus: String, Sendable, Hashable {
        case done, skipped, current, upcoming
    }

    /// One row of the step list: a step of the version, or a lap.
    public struct Row: Sendable, Hashable, Identifiable {
        /// The step's key, or "lap.{n}" for a lap.
        public var id: String
        /// 1-based position among the version's steps; nil for a lap.
        public var position: Int?
        public var label: String
        public var status: StepStatus
        /// Done: the segment's active time. Current: nil (the screen ticks it).
        public var ms: Int?
        public var isLap: Bool

        public init(id: String, position: Int?, label: String, status: StepStatus, ms: Int?, isLap: Bool) {
            self.id = id
            self.position = position
            self.label = label
            self.status = status
            self.ms = ms
            self.isLap = isLap
        }
    }

    /// Before Start: every step upcoming.
    public static func rows(steps: [TopicTimer.Step]) -> [Row] {
        steps.enumerated().map { index, step in
            Row(id: step.key, position: index + 1, label: step.label, status: .upcoming, ms: nil, isLap: false)
        }
    }

    /// The version's steps in order with their state in the run, then the closed laps, then an
    /// open lap (§11.2). No steps when they aren't known.
    public static func rows(_ state: RunState, steps: [TopicTimer.Step]?) -> [Row] {
        var rows: [Row] = []
        for (index, step) in (steps ?? []).enumerated() {
            let position = index + 1
            if let segment = state.segments.first(where: { $0.kind == .step && $0.step == step.key }) {
                rows.append(
                    Row(
                        id: step.key, position: position, label: segment.label, status: .done,
                        ms: segment.activeMs, isLap: false))
            } else if state.skipped.contains(step.key) {
                rows.append(
                    Row(id: step.key, position: position, label: step.label, status: .skipped, ms: nil, isLap: false))
            } else if let open = state.open, open.kind == .step, open.step == step.key {
                rows.append(
                    Row(id: step.key, position: position, label: open.label, status: .current, ms: nil, isLap: false))
            } else {
                rows.append(
                    Row(id: step.key, position: position, label: step.label, status: .upcoming, ms: nil, isLap: false))
            }
        }
        var lap = 0
        for segment in state.segments where segment.kind == .lap {
            lap += 1
            rows.append(
                Row(
                    id: "lap.\(lap)", position: nil, label: segment.label, status: .done, ms: segment.activeMs,
                    isLap: true))
        }
        if let open = state.open, open.kind == .lap {
            rows.append(
                Row(id: "lap.\(lap + 1)", position: nil, label: open.label, status: .current, ms: nil, isLap: true))
        }
        return rows
    }

    // MARK: - Accessibility

    /// A duration as VoiceOver should read it: "4 minutes 12 seconds", "1 hour 2 minutes 5
    /// seconds", "0 seconds". Truncated to whole seconds like `DurationFormat`.
    public static func spoken(_ ms: Int) -> String {
        let seconds = max(0, ms) / 1000
        let (hours, rest) = seconds.quotientAndRemainder(dividingBy: 3600)
        let (minutes, secs) = rest.quotientAndRemainder(dividingBy: 60)
        func unit(_ n: Int, _ one: String) -> String { "\(n) \(one)\(n == 1 ? "" : "s")" }
        var parts: [String] = []
        if hours > 0 { parts.append(unit(hours, "hour")) }
        if minutes > 0 { parts.append(unit(minutes, "minute")) }
        if secs > 0 || parts.isEmpty { parts.append(unit(secs, "second")) }
        return parts.joined(separator: " ")
    }
}

/// One control of a run (active-surfaces.md §1.1): what it does, where it goes and whether it is
/// enabled. Surfaces place it by `role` and may read `kind` for the title and icon (§1.3).
public struct RunAction: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case start
        /// "Shower": the step it opens (M2 renders "Next: Shower", §1.3). Empty: the steps are
        /// unknown (`timer == nil`, row 9), so a plain "Next".
        case next(label: String)
        case lap(nextTypeLabel: String?)  // nil: untyped laps ("Lap"); "Rest": the lap it opens
        case skip(label: String)  // the step a skip would skip
        case pause, resume, stop
        case addDetails  // finishing run
        case reopen(target: UUID)  // the terminal stop's id: entry.timing.terminalId (timers2.md §3.3)
        case revert  // discard of a reopened run (timers2.md §3.4, §4.1)
        case discard

        /// Stable per kind: the accessibility id suffix.
        public var id: String {
            switch self {
            case .start: "start"
            case .next: "next"
            case .lap: "lap"
            case .skip: "skip"
            case .pause: "pause"
            case .resume: "resume"
            case .stop: "stop"
            case .addDetails: "addDetails"
            case .reopen: "reopen"
            case .revert: "revert"
            case .discard: "discard"
            }
        }
    }
    public enum Role: Sendable, Hashable { case primary, secondary, destructive, overflow }
    public var kind: Kind
    public var role: Role
    public var enabled: Bool
    /// Stable per kind: "start", "next", "lap", "skip", "pause", "resume", "stop",
    /// "addDetails", "reopen", "revert", "discard" — the accessibility id suffix.
    public var id: String

    public init(kind: Kind, role: Role, enabled: Bool) {
        self.kind = kind
        self.role = role
        self.enabled = enabled
        self.id = kind.id
    }
}

/// The headline of an open run (active-surfaces.md §1.1): "Rest 2 · lap 4", "Shower · 2 of 5",
/// "Running"/"Paused" when nothing is open, and the compact counter ("L4") for the Dynamic Island.
public struct Headline: Sendable, Hashable {
    public var text: String
    public var counter: String?

    public init(text: String, counter: String?) {
        self.text = text
        self.counter = counter
    }
}

/// What a timed topic's home tile shows (timers.md §11.1, §11.2), decided from the topic and the
/// run the home model has for it.
public enum RunTileState: Sendable, Hashable {
    /// Not timed: the ordinary tile (quick-log and Log).
    case untimed
    /// Timed, no open run: Start.
    case idle
    /// An open run: "Running · 4:12" (or "Paused · …"), the open segment, and the primary button.
    case open(paused: Bool)
    /// Stopped, waiting for its answers: "Add details".
    case finishing

    /// `timed` is the topic's current version's timer being non-nil (`Topic.timer`). A run the
    /// home model has makes the topic timed even before its version is stored, so a tile never
    /// one-tap logs an untimed entry for a topic that is being timed.
    public init(timed: Bool, run status: RunStatus?) {
        switch status {
        case .running: self = .open(paused: false)
        case .paused: self = .open(paused: true)
        case .finishing: self = .finishing
        case .stopped, .discarded, nil: self = timed ? .idle : .untimed
        }
    }

    public var isTimed: Bool { self != .untimed }
}
