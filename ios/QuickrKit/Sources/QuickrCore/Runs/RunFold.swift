import Foundation

/// The run fold: a run's events in, its state and timing out (timers.md §4, §2.3).
///
/// A port of backend/app/services/run_fold.py, the reference (the PWA's `lib/runs/fold.ts` is the
/// other port). `shared/fixtures/run-fold-vectors.json` is the contract all three check. Every
/// instant is integer epoch milliseconds, so durations are exact integer differences and segment
/// sums equal the totals exactly.
///
/// - `fold` replays a run's events (in arrival order) into a `RunState`: terminal events by
///   arrival, everything else by `(at, id)`, except that a resume at the same instant as the pause
///   it names comes right after it (§4.1, §4.2).
/// - `projectTiming` turns a stopped run's state into the entry's `Timing`.
///
/// Decided outside the fold, by the server (§3.6, §3.7, §4.4): `finish` (no effect here), the
/// discard of a finishing run, `finishing` versus `stopped` (the fold says `stopped`), and the
/// `frozen` cut-off after which arrivals are void and not folded.
public enum RunFold {
    /// §5: a run lasts at most 7 days from its start.
    public static let maxRunMs = 7 * 24 * 60 * 60 * 1000

    public enum FoldError: Error, Equatable {
        /// The run's own start (the event whose id is the run's) isn't among the events.
        case missingStart
        /// Only a stopped run has a timing.
        case notStopped
    }

    /// The label of the run's `n`-th lap segment (1-based).
    public static func lapLabel(_ n: Int) -> String { "Lap \(n)" }

    /// Replay `events` (in arrival order) of run `runId` over its version's `steps`.
    ///
    /// A stop before the start or more than 7 days after it is void (`before_start`, `too_long`)
    /// and doesn't close the run.
    public static func fold(
        runId: String, steps: [TopicTimer.Step], events: [RunEvent], frozen: RunFrozen? = nil
    ) throws -> RunState {
        let runId = runId.lowercased()
        guard let start = events.first(where: { $0.id.lowercased() == runId && $0.type == .start }) else {
            throw FoldError.missingStart
        }
        var effects: [String: RunEffect] = [:]
        let (terminal, accepted) = arrivalPass(runId: runId, start: start, events, frozen, &effects)

        var clock = Clock(steps: steps, startedAt: start.at)
        let end = terminal?.at
        for e in timeOrdered(accepted) {
            let reason: VoidReason?
            if e.at < start.at {
                reason = .beforeStart
            } else if let end, e.at > end {
                reason = .afterStop
            } else if e.at > start.at + maxRunMs {
                reason = .tooLong
            } else {
                reason = clock.apply(e)
            }
            effects[e.id.lowercased()] = RunEffect(reason)
        }
        return clock.state(startedAt: start.at, terminal: terminal, effects: effects)
    }

    /// `state` with `events` (in arrival order) applied over it, for a run whose version's steps
    /// aren't known here (timers.md §8.3): only the events that need no steps, so an offline
    /// pause, resume, lap, stop or discard still shows. A next or skip, and an event `state`
    /// already has an effect for, is left out (the server folds it). `pauseId` is the id of
    /// `state`'s open pause: a resume naming another, or any resume when it isn't known, is stale.
    /// A stop, pause or lap before the open segment's start, and a resume before its pause, is
    /// stale (it would end a segment or a pause before it began).
    public static func overlay(_ state: RunState, events: [RunEvent], pauseId: String? = nil) -> RunState {
        var s = state
        var pauseId = pauseId?.lowercased()
        let mine = events.filter { s.effects[$0.id.lowercased()] == nil && $0.type != .next && $0.type != .skip }
        func inRange(_ e: RunEvent) -> VoidReason? {
            if e.at < s.startedAt { return .beforeStart }
            if e.at > s.startedAt + maxRunMs { return .tooLong }
            return nil
        }
        // Pass 1: the terminal by arrival, as in `fold`.
        var terminal: RunEvent?
        var accepted: [RunEvent] = []
        for e in mine where e.type != .start && e.type != .finish {
            guard e.type == .stop || e.type == .discard else {
                accepted.append(e)
                continue
            }
            var reason: VoidReason? = e.type == .stop ? inRange(e) : nil
            if reason == nil, !s.status.isOpen || terminal != nil { reason = .alreadyClosed }
            if reason == nil, e.type == .stop, let open = s.open, e.at < open.startedAt { reason = .stale }
            if reason == nil { terminal = e }
            s.effects[e.id.lowercased()] = RunEffect(reason)
        }
        // Pass 2: the rest by time, up to the terminal.
        for e in timeOrdered(accepted) {
            var reason = inRange(e)
            if reason == nil, !s.status.isOpen {
                reason = .alreadyClosed
            } else if reason == nil, let end = terminal?.at, e.at > end {
                reason = .afterStop
            } else if reason == nil {
                reason = overlayApply(&s, e, &pauseId)
            }
            s.effects[e.id.lowercased()] = RunEffect(reason)
        }
        guard let terminal else { return s }
        if terminal.type == .stop {
            if let since = s.pausedSince { s.pauses.append(RunPause(start: since, end: terminal.at)) }
            s.pausedSince = nil
            overlayClose(&s, at: terminal.at)
            s.status = .stopped
            s.endedAt = terminal.at
        } else {
            s.status = .discarded
            s.pausedSince = nil
        }
        s.open = nil
        s.nextStep = nil
        return s
    }

    /// Apply one in-range pause, resume or lap to an open run's state; its void reason, or nil.
    private static func overlayApply(_ s: inout RunState, _ e: RunEvent, _ pauseId: inout String?) -> VoidReason? {
        if e.type != .resume, let open = s.open, e.at < open.startedAt { return .stale }
        switch e.type {
        case .lap:
            if e.seg != s.segments.count { return .stale }
            overlayClose(&s, at: e.at)
            let laps = s.segments.count { $0.kind == .lap }
            s.open = RunOpenSegment(
                index: s.segments.count, kind: .lap, step: nil, label: lapLabel(laps + 1), startedAt: e.at)
        case .pause:
            if s.pausedSince != nil { return .alreadyPaused }
            s.pausedSince = e.at
            s.status = .paused
            pauseId = e.id.lowercased()
        case .resume:
            guard let since = s.pausedSince else { return .notPaused }
            guard let open = pauseId, (e.pauseId ?? "").lowercased() == open else { return .stale }
            if e.at < since { return .stale }  // it would end the pause before it began
            s.pauses.append(RunPause(start: since, end: e.at))
            s.pausedSince = nil
            s.status = .running
            pauseId = nil
        default:
            break
        }
        return nil
    }

    /// Close `s`'s open segment at `at`, keeping its kind, step and label.
    private static func overlayClose(_ s: inout RunState, at: Int) {
        guard let open = s.open else { return }
        let paused = overlap(open.startedAt, at, s.pauses, openPause: s.pausedSince)
        s.segments.append(
            RunSegment(
                kind: open.kind, step: open.step, label: open.label, startedAt: open.startedAt, endedAt: at,
                activeMs: at - open.startedAt - paused, pausedMs: paused))
        s.open = nil
    }

    /// Pass 2's order: `(at, id)` ascending, ids lowercase, except that a resume at the same
    /// instant as the pause it names comes right after that pause.
    static func timeOrdered(_ accepted: [RunEvent]) -> [RunEvent] {
        var pauses: [String: Int] = [:]
        for e in accepted where e.type == .pause { pauses[e.id.lowercased()] = e.at }
        func key(_ e: RunEvent) -> SortKey {
            let named = (e.pauseId ?? "").lowercased()
            if e.type == .resume, pauses[named] == e.at {
                return SortKey(at: e.at, id: named, rank: 1, tie: e.id.lowercased())
            }
            return SortKey(at: e.at, id: e.id.lowercased(), rank: 0, tie: "")
        }
        return accepted.map { (key($0), $0) }.sorted { $0.0 < $1.0 }.map(\.1)
    }

    struct SortKey: Comparable {
        var at: Int
        var id: String
        var rank: Int
        var tie: String

        static func < (a: SortKey, b: SortKey) -> Bool {
            if a.at != b.at { return a.at < b.at }
            if a.id != b.id { return codePointLess(a.id, b.id) }
            if a.rank != b.rank { return a.rank < b.rank }
            return codePointLess(a.tie, b.tie)
        }
    }

    /// Pass 1, arrival order (§4.2): duplicates, starts, terminals and the frozen cut-off. Records
    /// their effects; returns the terminal and the events left for pass 2.
    static func arrivalPass(
        runId: String, start: RunEvent, _ events: [RunEvent], _ frozen: RunFrozen?,
        _ effects: inout [String: RunEffect]
    ) -> (terminal: RunEvent?, accepted: [RunEvent]) {
        var seen: Set<String> = []
        var terminal: RunEvent?
        var accepted: [RunEvent] = []
        for (i, e) in events.enumerated() {
            let eid = e.id.lowercased()
            guard seen.insert(eid).inserted else { continue }
            if e.type == .finish { continue }
            var reason: VoidReason?
            if let frozen, i >= frozen.after {
                reason = frozen.reason
            } else if e.type == .start {
                reason = eid == runId ? nil : .merged
            } else if e.type == .stop || e.type == .discard {
                // An out-of-range stop is never a terminal, whenever it arrives (the server refuses it).
                if e.type == .stop && e.at < start.at {
                    reason = .beforeStart
                } else if e.type == .stop && e.at > start.at + maxRunMs {
                    reason = .tooLong
                } else if terminal != nil {
                    reason = .alreadyClosed
                } else {
                    terminal = e
                }
            } else {
                accepted.append(e)
                continue
            }
            effects[eid] = RunEffect(reason)
        }
        return (terminal, accepted)
    }

    /// Pass 2's state: the open segment, the steps still to come, and what has closed.
    struct Clock {
        /// A closed segment before labelling: its step (nil for a lap) and bounds.
        typealias Closed = (step: TopicTimer.Step?, startedAt: Int, endedAt: Int)

        var pending: ArraySlice<TopicTimer.Step>
        var openStep: TopicTimer.Step?  // nil: a lap
        var openStart: Int
        var closed: [Closed] = []
        var skipped: [String] = []
        var pauses: [RunPause] = []
        var pausedSince: Int?
        var pauseId: String?

        init(steps: [TopicTimer.Step], startedAt: Int) {
            pending = steps[...]
            openStep = pending.popFirst()
            openStart = startedAt
        }

        /// The next step, or a lap once the steps run out.
        mutating func pop() -> TopicTimer.Step? { pending.popFirst() }

        mutating func close(at: Int, then: TopicTimer.Step?) {
            closed.append((openStep, openStart, at))
            openStep = then
            openStart = at
        }

        /// Apply one in-range event; its void reason, or nil when it applied.
        mutating func apply(_ e: RunEvent) -> VoidReason? {
            if [.next, .lap, .skip].contains(e.type) && e.seg != closed.count { return .stale }
            switch e.type {
            case .next:
                close(at: e.at, then: pop())
            case .lap:
                close(at: e.at, then: nil)
            case .skip:
                return skip(e.step)
            case .pause:
                if pausedSince != nil { return .alreadyPaused }
                pausedSince = e.at
                pauseId = e.id.lowercased()
            case .resume:
                guard let since = pausedSince else { return .notPaused }
                if (e.pauseId ?? "").lowercased() != pauseId { return .stale }  // it ends an older pause
                pauses.append(RunPause(start: since, end: e.at))
                pausedSince = nil
                pauseId = nil
            case .start, .stop, .discard, .finish:  // never reach pass 2
                preconditionFailure("\(e.type) in pass 2")
            }
            return nil
        }

        mutating func skip(_ step: String?) -> VoidReason? {
            if let open = openStep {
                if step != open.key { return .stale }
                skipped.append(open.key)
                openStep = pop()  // relabel the open segment: no time moves
                return nil
            }
            guard let head = pending.first else { return .noStep }
            if step != head.key { return .stale }
            skipped.append(head.key)
            pending.removeFirst()
            return nil
        }

        mutating func state(startedAt: Int, terminal: RunEvent?, effects: [String: RunEffect]) -> RunState {
            let status: RunStatus
            var endedAt: Int?
            if let terminal, terminal.type == .stop {
                if let since = pausedSince {  // stop while paused ends the pause
                    pauses.append(RunPause(start: since, end: terminal.at))
                    pausedSince = nil
                }
                close(at: terminal.at, then: nil)
                status = .stopped
                endedAt = terminal.at
            } else if terminal != nil {
                status = .discarded
                pausedSince = nil
            } else {
                status = pausedSince != nil ? .paused : .running
            }

            let segments = RunFold.segments(closed, pauses: pauses, openPause: pausedSince)
            var open: RunOpenSegment?
            if status.isOpen {
                let laps = segments.count { $0.kind == .lap }
                open = RunOpenSegment(
                    index: closed.count, kind: openStep == nil ? .lap : .step, step: openStep?.key,
                    label: openStep?.label ?? RunFold.lapLabel(laps + 1), startedAt: openStart)
            }
            return RunState(
                status: status, startedAt: startedAt, endedAt: endedAt, open: open,
                nextStep: open != nil ? pending.first?.key : nil, pausedSince: pausedSince, segments: segments,
                skipped: skipped, pauses: pauses, effects: effects)
        }
    }

    /// How much of `[start, end)` the pauses cover. `openPause` is the start of a pause not resumed
    /// yet, which covers up to `end` (measured to `end`: no "not resumed" sentinel).
    static func overlap(_ start: Int, _ end: Int, _ pauses: [RunPause], openPause: Int? = nil) -> Int {
        var paused = pauses.reduce(0) { $0 + max(0, min(end, $1.end) - max(start, $1.start)) }
        if let openPause { paused += max(0, end - max(start, openPause)) }
        return paused
    }

    /// Closed segments with their labels. Pauses stay whole; each segment's `pausedMs` is its
    /// overlap with them (T5).
    static func segments(_ closed: [Clock.Closed], pauses: [RunPause], openPause: Int?) -> [RunSegment] {
        var laps = 0
        return closed.map { step, startedAt, endedAt in
            if step == nil { laps += 1 }
            let paused = overlap(startedAt, endedAt, pauses, openPause: openPause)
            return RunSegment(
                kind: step == nil ? .lap : .step, step: step?.key, label: step?.label ?? lapLabel(laps),
                startedAt: startedAt, endedAt: endedAt, activeMs: endedAt - startedAt - paused, pausedMs: paused)
        }
    }

    // MARK: - Timing

    /// §9.1: the version has no steps, or every one of its steps has a segment and none was
    /// skipped. A run stopped before it reached its last step is not complete.
    public static func isComplete(steps: [TopicTimer.Step], segments: [RunSegment], skipped: [String]) -> Bool {
        let done = Set(segments.compactMap(\.step))
        return skipped.isEmpty && steps.allSatisfy { done.contains($0.key) }
    }

    /// A stopped run's `Timing`: exactly its fold state (§4.3). `steps` are the run version's
    /// steps, the ones it was folded over.
    public static func projectTiming(_ state: RunState, steps: [TopicTimer.Step]) throws -> Timing {
        guard state.status == .stopped, let endedAt = state.endedAt else { throw FoldError.notStopped }
        let paused = state.pauses.reduce(0) { $0 + $1.end - $1.start }
        return Timing(
            startedAt: state.startedAt, endedAt: endedAt, activeMs: endedAt - state.startedAt - paused,
            pausedMs: paused, complete: isComplete(steps: steps, segments: state.segments, skipped: state.skipped),
            edited: false, segments: state.segments, skipped: state.skipped, pauses: state.pauses)
    }
}

/// Code point order, like Python's `str` comparison (Swift's `<` on `String` compares canonical
/// equivalents equal and isn't code point order).
func codePointLess(_ a: String, _ b: String) -> Bool {
    a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars)
}
