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
