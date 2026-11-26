import Foundation

/// The run fold: a run's events in, its state and timing out (timers.md §4, §2.3; fold v4:
/// timers2.md §3, whose §3.4 pseudocode is normative).
///
/// A port of backend/app/services/run_fold.py, the reference (the PWA's `lib/runs/fold.ts` is the
/// other port). `shared/fixtures/run-fold-vectors.json` is the contract all three check. Every
/// instant is integer epoch milliseconds, so durations are exact integer differences and segment
/// sums equal the totals exactly.
///
/// - `fold` replays a run's events (in arrival order) into a `RunState` over its version's
///   `timer` (steps and lap types). Pass 1, by arrival: duplicates, starts, terminals, reopens
///   (and their revert by a discard) and removes. Pass 2, by `(at, rank, id)`: everything else,
///   with each reopened stop a gap pause and its reopen a gap resume; a resume at the same instant
///   as the pause it names comes right after it (§4.1, §4.2). Effects are outputs of one fold.
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

    /// The label of the run's `n`-th lap segment (1-based) with no lap types.
    public static func lapLabel(_ n: Int) -> String { "Lap \(n)" }

    /// The lap type key and label of the run's `n`-th lap segment (1-based): laps cycle through
    /// `laps` in order with a per-type ordinal ("Run 2"); with none, `(nil, "Lap n")` (§3.2).
    public static func lapTyping(_ n: Int, _ laps: [TopicTimer.LapType]) -> (lapType: String?, label: String) {
        guard !laps.isEmpty else { return (nil, lapLabel(n)) }
        let type = laps[(n - 1) % laps.count]
        return (type.key, "\(type.label) \((n - 1) / laps.count + 1)")
    }

    /// v1 callers: a fold over `steps` and no lap types.
    public static func fold(
        runId: String, steps: [TopicTimer.Step], events: [RunEvent], frozen: RunFrozen? = nil
    ) throws -> RunState {
        try fold(runId: runId, timer: TopicTimer(steps: steps), events: events, frozen: frozen)
    }

    /// Replay `events` (in arrival order) of run `runId` over its version's `timer`.
    ///
    /// A stop before the start or more than 7 days after it is void (`before_start`, `too_long`)
    /// and doesn't close the run.
    public static func fold(
        runId: String, timer: TopicTimer, events: [RunEvent], frozen: RunFrozen? = nil
    ) throws -> RunState {
        let runId = runId.lowercased()
        guard let start = events.first(where: { $0.id.lowercased() == runId && $0.type == .start }) else {
            throw FoldError.missingStart
        }
        var effects: [String: RunEffect] = [:]
        var arrival = Arrival(runId: runId, start: start)
        arrival.run(events, frozen, &effects)
        let terminal = arrival.terminal

        var clock = Clock(timer: timer, startedAt: start.at, removed: arrival.removed)
        let end = terminal?.at
        for item in timeOrdered(arrival.accepted, gaps: arrival.gaps()) {
            switch item {
            case .gapPause(let at, let id), .gapResume(let at, let id):
                // Never recorded; skipped outside the run.
                guard at >= start.at, end.map({ at <= $0 }) ?? true else { continue }
                if case .gapPause = item { clock.gapPause(at: at, id: id) } else { clock.endPause(at: at) }
            case .event(let e):
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
        }
        var state = clock.state(startedAt: start.at, terminal: terminal, effects: effects)
        if state.status.isOpen { state.reopenId = arrival.openReopen?.reopen.id.lowercased() }
        return state
    }

    /// The applied reopen that cleared the current terminal of an open run, from its events in
    /// arrival order and their recorded effects (what `fold` sets as `RunState.reopenId`): the
    /// last applied reopen with no applied stop or discard after it. For a state that didn't
    /// come from `fold` (the server's).
    public static func openReopen(events: [RunEvent], effects: [String: RunEffect], status: RunStatus) -> String? {
        guard status.isOpen else { return nil }
        var open: String?
        var seen: Set<String> = []
        for e in events {
            let id = e.id.lowercased()
            guard seen.insert(id).inserted, effects[id] == .applied else { continue }
            switch e.type {
            case .reopen: open = id
            case .stop, .discard: open = nil
            default: break
            }
        }
        return open
    }

    /// `state` with `events` (in arrival order) applied over it, for a run whose version's steps
    /// aren't known here (timers.md §8.3): only the events that need no steps, so an offline
    /// pause, resume, lap, stop or discard still shows. A next or skip, and an event `state`
    /// already has an effect for, is left out (the server folds it). `pauseId` is the id of
    /// `state`'s open pause: a resume naming another, or any resume when it isn't known, is stale.
    /// A stop, pause or lap before the open segment's start, and a resume before its pause, is
    /// stale (it would end a segment or a pause before it began).
    ///
    /// Fold v4 (timers2.md §10): a lap opened here is untyped ("Lap n", no `lapType`) until the
    /// version is stored, and the next lap's type is then unknown (`nextLapType` nil); a stop sets
    /// `terminalId`. A reopen or remove is left out (the server folds it; I1-WRITES' "resuming"
    /// projection, §5.3, covers a queued reopen).
    public static func overlay(_ state: RunState, events: [RunEvent], pauseId: String? = nil) -> RunState {
        var s = state
        var pauseId = pauseId?.lowercased()
        let leftOut: Set<RunEventType> = [.next, .skip, .reopen, .remove]
        let mine = events.filter { s.effects[$0.id.lowercased()] == nil && !leftOut.contains($0.type) }
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
            if let since = s.pausedSince { s.pauses.append(RunPause(start: since, end: terminal.at, id: pauseId)) }
            s.pausedSince = nil
            overlayClose(&s, at: terminal.at)
            s.status = .stopped
            s.endedAt = terminal.at
            s.terminalId = terminal.id.lowercased()
        } else {
            s.status = .discarded
            s.pausedSince = nil
            s.terminalId = nil
        }
        s.open = nil
        s.nextStep = nil
        s.nextLapType = nil
        s.reopenId = nil
        return s
    }

    /// Apply one in-range pause, resume or lap to an open run's state; its void reason, or nil.
    private static func overlayApply(_ s: inout RunState, _ e: RunEvent, _ pauseId: inout String?) -> VoidReason? {
        if e.type != .resume, let open = s.open, e.at < open.startedAt { return .stale }
        switch e.type {
        case .lap:
            if e.seg != s.segments.count { return .stale }
            overlayClose(&s, at: e.at)
            s.open = RunOpenSegment(
                index: s.segments.count, kind: .lap, step: nil, label: lapLabel(s.lapCount + 1), startedAt: e.at)
            s.nextLapType = nil  // untyped until the version is stored
        case .pause:
            if s.pausedSince != nil { return .alreadyPaused }
            s.pausedSince = e.at
            s.status = .paused
            pauseId = e.id.lowercased()
        case .resume:
            guard let since = s.pausedSince else { return .notPaused }
            guard let open = pauseId, (e.pauseId ?? "").lowercased() == open else { return .stale }
            if e.at < since { return .stale }  // it would end the pause before it began
            s.pauses.append(RunPause(start: since, end: e.at, id: open))
            s.pausedSince = nil
            s.status = .running
            pauseId = nil
        default:
            break
        }
        return nil
    }

    /// Close `s`'s open segment at `at`, keeping its kind, step, label and lap type (an open
    /// segment carries no opener id: the server's fold fills it).
    private static func overlayClose(_ s: inout RunState, at: Int) {
        guard let open = s.open else { return }
        let paused = overlap(open.startedAt, at, s.pauses, openPause: s.pausedSince)
        s.segments.append(
            RunSegment(
                kind: open.kind, step: open.step, label: open.label, startedAt: open.startedAt, endedAt: at,
                activeMs: at - open.startedAt - paused, pausedMs: paused, lapType: open.lapType))
        if open.kind == .lap { s.lapCount += 1 }
        s.open = nil
    }

    /// One item of pass 2: a user event, or a reopened stop's gap pause (id = the stop's) or a
    /// reopen's gap resume (id = the reopen's), timers2.md §3.4.
    enum Item {
        case event(RunEvent)
        case gapPause(at: Int, id: String)
        case gapResume(at: Int, id: String)
    }

    /// Pass 2's order `(at, rank, id)`: at equal `at` a gap pause (rank 0) comes before every user
    /// event (rank 1) and a gap resume (rank 2) after them; user events by lowercase id, except
    /// that a resume at the same instant as the pause it names comes right after that pause.
    static func timeOrdered(_ accepted: [RunEvent], gaps: [Item]) -> [Item] {
        var pauses: [String: Int] = [:]
        for e in accepted where e.type == .pause { pauses[e.id.lowercased()] = e.at }
        func key(_ item: Item) -> SortKey {
            switch item {
            case .gapPause(let at, let id): return SortKey(at: at, rank: 0, id: id, sub: 0, tie: "")
            case .gapResume(let at, let id): return SortKey(at: at, rank: 2, id: id, sub: 0, tie: "")
            case .event(let e):
                let named = (e.pauseId ?? "").lowercased()
                if e.type == .resume, pauses[named] == e.at {
                    return SortKey(at: e.at, rank: 1, id: named, sub: 1, tie: e.id.lowercased())
                }
                return SortKey(at: e.at, rank: 1, id: e.id.lowercased(), sub: 0, tie: "")
            }
        }
        return (accepted.map(Item.event) + gaps).map { (key($0), $0) }.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// The user events alone in pass 2's order.
    static func timeOrdered(_ accepted: [RunEvent]) -> [RunEvent] {
        timeOrdered(accepted, gaps: []).compactMap { if case .event(let e) = $0 { e } else { nil } }
    }

    struct SortKey: Comparable {
        var at: Int
        var rank: Int
        var id: String
        var sub: Int
        var tie: String

        static func < (a: SortKey, b: SortKey) -> Bool {
            if a.at != b.at { return a.at < b.at }
            if a.rank != b.rank { return a.rank < b.rank }
            if a.id != b.id { return codePointLess(a.id, b.id) }
            if a.sub != b.sub { return a.sub < b.sub }
            return codePointLess(a.tie, b.tie)
        }
    }

    /// Pass 1, arrival order (§4.2, timers2.md §3.4): duplicates, starts, the frozen cut-off,
    /// terminals, reopens (and their revert by a discard) and removes. Records their effects.
    struct Arrival {
        let runId: String
        let start: RunEvent
        /// The first occurrence of each (lowercase) id.
        var seen: [String: RunEvent] = [:]
        var terminal: RunEvent?
        var accepted: [RunEvent] = []
        /// The (stop, reopen) that cleared the CURRENT terminal.
        var openReopen: (stop: RunEvent, reopen: RunEvent)?
        /// Every applied (stop, reopen) pair, for pass 2's gap roles.
        var roles: [(stop: RunEvent, reopen: RunEvent)] = []
        /// Target id (lowercase) → the remove that applied.
        var removed: [String: RunEvent] = [:]

        init(runId: String, start: RunEvent) {
            self.runId = runId
            self.start = start
        }

        func gaps() -> [Item] {
            roles.filter { removed[$0.stop.id.lowercased()] == nil }.map {
                Item.gapPause(at: $0.stop.at, id: $0.stop.id.lowercased())
            } + roles.map { Item.gapResume(at: $0.reopen.at, id: $0.reopen.id.lowercased()) }
        }

        mutating func run(_ events: [RunEvent], _ frozen: RunFrozen?, _ effects: inout [String: RunEffect]) {
            for (i, e) in events.enumerated() {
                let eid = e.id.lowercased()
                guard seen[eid] == nil else { continue }
                seen[eid] = e
                if e.type == .finish { continue }
                let reason: VoidReason?
                if let frozen, i >= frozen.after {
                    reason = frozen.reason
                } else {
                    switch e.type {
                    case .start: reason = eid == runId ? nil : .merged
                    case .stop: reason = stop(e)
                    case .discard: reason = discard(e, &effects)
                    case .reopen: reason = reopen(e)
                    case .remove: reason = remove(e, &effects)
                    case .next, .lap, .skip, .pause, .resume:
                        accepted.append(e)
                        continue
                    case .finish: continue
                    }
                }
                effects[eid] = RunEffect(reason)
            }
        }

        mutating func stop(_ e: RunEvent) -> VoidReason? {
            // An out-of-range stop is never a terminal, whenever it arrives (the server refuses it).
            if e.at < start.at { return .beforeStart }
            if e.at > start.at + maxRunMs { return .tooLong }
            if terminal != nil { return .alreadyClosed }
            terminal = e
            openReopen = nil  // a new terminal ends the reopen transaction
            return nil
        }

        mutating func discard(_ e: RunEvent, _ effects: inout [String: RunEffect]) -> VoidReason? {
            if terminal != nil { return .alreadyClosed }
            guard let pair = openReopen else {
                terminal = e
                return nil
            }
            let (stop, reopen) = pair
            // The terminal was cleared by a reopen: revert (OQ-2).
            openReopen = nil
            effects[reopen.id.lowercased()] = .void(.reverted)
            terminal = stop
            roles.removeAll { $0.stop.id == stop.id && $0.reopen.id == reopen.id }
            let sid = stop.id.lowercased()
            if let remove = removed.removeValue(forKey: sid) {  // the gap pause had been removed
                effects[sid] = .applied
                effects[remove.id.lowercased()] = .void(.noTarget)
            }
            return nil  // the discard closed what the reopen opened
        }

        mutating func reopen(_ e: RunEvent) -> VoidReason? {
            let target = (e.target ?? "").lowercased()
            guard let t = seen[target], t.type == .stop else { return .noTarget }
            if let terminal, terminal.type == .discard { return .alreadyClosed }
            guard let terminal, terminal.id.lowercased() == target else { return .notStopped }
            if e.at <= t.at { return .stale }
            if e.at > start.at + maxRunMs { return .tooLong }
            openReopen = (t, e)
            roles.append((t, e))
            self.terminal = nil
            return nil
        }

        /// Eligibility is by type and identity only: a pause, a lap, or a reopened stop, not yet
        /// removed, with `e.at` after it; there is no 7-day bound.
        mutating func remove(_ e: RunEvent, _ effects: inout [String: RunEffect]) -> VoidReason? {
            let target = (e.target ?? "").lowercased()
            guard let t = seen[target], removed[target] == nil, e.at > t.at else { return .noTarget }
            switch t.type {
            case .stop:
                guard roles.contains(where: { $0.stop.id.lowercased() == target }) else { return .noTarget }
                effects[target] = .void(.deleted)  // the gap pause goes; its reopen stays applied
            case .pause, .lap:
                break
            default:
                return .noTarget
            }
            removed[target] = e
            return nil
        }
    }

    /// Pass 2's state: the open segment, the steps still to come, what has closed, the open pause
    /// and its owner, and the ghost boundaries of removed laps.
    struct Clock {
        /// A closed segment before labelling: its step (nil for a lap), bounds and opener.
        struct Closed {
            var step: TopicTimer.Step?
            var startedAt: Int
            var endedAt: Int
            var eventId: String?
            var openedBy: RunOpenedBy?
        }

        let timer: TopicTimer
        var pending: ArraySlice<TopicTimer.Step>
        var openStep: TopicTimer.Step?  // nil: a lap
        var openStart: Int
        var openEvent: (id: String?, by: RunOpenedBy?) = (nil, .start)
        var closed: [Closed] = []
        var skipped: [String] = []
        var pauses: [RunPause] = []
        var pausedSince: Int?
        var pauseId: String?
        let removed: [String: RunEvent]
        /// (lap.at, remove.at) of removed lap boundaries.
        var ghosts: [(lapAt: Int, removedAt: Int)] = []

        init(timer: TopicTimer, startedAt: Int, removed: [String: RunEvent]) {
            self.timer = timer
            pending = timer.steps[...]
            openStep = pending.popFirst()
            openStart = startedAt
            self.removed = removed
        }

        /// The next step, or a lap once the steps run out.
        mutating func pop() -> TopicTimer.Step? { pending.popFirst() }

        /// §3.5: the closed segments plus the removed boundaries a device tapping at `at` still
        /// saw (removed later than `at`).
        func expectedSeg(_ at: Int) -> Int {
            closed.count + ghosts.count { $0.lapAt < at && at < $0.removedAt }
        }

        mutating func close(at: Int, then: TopicTimer.Step?, eventId: String?, openedBy: RunOpenedBy?) {
            closed.append(
                Closed(step: openStep, startedAt: openStart, endedAt: at, eventId: openEvent.id, openedBy: openEvent.by)
            )
            openStep = then
            openStart = at
            openEvent = (eventId, openedBy)
        }

        mutating func endPause(at: Int) {
            guard let since = pausedSince else { return }
            pauses.append(RunPause(start: since, end: at, id: pauseId))
            pausedSince = nil
            pauseId = nil
        }

        /// A gap pause in range: the gap OWNS the open pause, so a user resume inside it is stale.
        mutating func gapPause(at: Int, id: String) {
            if pausedSince == nil { pausedSince = at }
            pauseId = id
        }

        /// Apply one in-range event; its void reason, or nil when it applied.
        mutating func apply(_ e: RunEvent) -> VoidReason? {
            let eid = e.id.lowercased()
            if let remove = removed[eid] {  // a deleted boundary or pause
                if e.type == .lap, e.seg == expectedSeg(e.at) { ghosts.append((e.at, remove.at)) }
                return .deleted
            }
            if [.next, .lap, .skip].contains(e.type) && e.seg != expectedSeg(e.at) { return .stale }
            switch e.type {
            case .next:
                close(at: e.at, then: pop(), eventId: eid, openedBy: .next)
            case .lap:
                close(at: e.at, then: nil, eventId: eid, openedBy: .lap)
            case .skip:
                return skip(e.step)
            case .pause:
                if pausedSince != nil { return .alreadyPaused }
                pausedSince = e.at
                pauseId = eid
            case .resume:
                let named = (e.pauseId ?? "").lowercased()
                if removed[named] != nil { return .deleted }
                if pausedSince == nil { return .notPaused }
                if named != pauseId { return .stale }  // it ends an older pause, or one the gap took over
                endPause(at: e.at)
            case .start, .stop, .discard, .finish, .reopen, .remove:  // never reach pass 2
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
            var terminalId: String?
            if let terminal, terminal.type == .stop {
                endPause(at: terminal.at)  // stop while paused ends the pause
                close(at: terminal.at, then: nil, eventId: nil, openedBy: nil)
                status = .stopped
                endedAt = terminal.at
                terminalId = terminal.id.lowercased()
            } else if terminal != nil {
                status = .discarded
                pausedSince = nil
                pauseId = nil
            } else {
                status = pausedSince != nil ? .paused : .running
            }

            let laps = timer.laps
            let segments = RunFold.segments(closed, pauses: pauses, laps: laps, openPause: pausedSince)
            let lapCount = segments.count { $0.kind == .lap }
            var open: RunOpenSegment?
            var nextLapType: String?
            if status.isOpen {
                let typing: (lapType: String?, label: String) =
                    openStep.map { (nil, $0.label) } ?? lapTyping(lapCount + 1, laps)
                open = RunOpenSegment(
                    index: closed.count, kind: openStep == nil ? .lap : .step, step: openStep?.key,
                    label: typing.label, startedAt: openStart, lapType: typing.lapType)
                if !laps.isEmpty {  // the lap a `lap` tap would open now
                    nextLapType = lapTyping(lapCount + (openStep == nil ? 1 : 0) + 1, laps).lapType
                }
            }
            return RunState(
                status: status, startedAt: startedAt, endedAt: endedAt, open: open,
                nextStep: open != nil ? pending.first?.key : nil, pausedSince: pausedSince, segments: segments,
                skipped: skipped, pauses: pauses, effects: effects, terminalId: terminalId, nextLapType: nextLapType,
                lapCount: lapCount)
        }
    }

    /// How much of `[start, end)` the pauses cover. `openPause` is the start of a pause not resumed
    /// yet, which covers up to `end` (measured to `end`: no "not resumed" sentinel).
    static func overlap(_ start: Int, _ end: Int, _ pauses: [RunPause], openPause: Int? = nil) -> Int {
        var paused = pauses.reduce(0) { $0 + max(0, min(end, $1.end) - max(start, $1.start)) }
        if let openPause { paused += max(0, end - max(start, openPause)) }
        return paused
    }

    /// Closed segments with their labels and lap types (§3.2). Pauses stay whole; each segment's
    /// `pausedMs` is its overlap with them (T5).
    static func segments(
        _ closed: [Clock.Closed], pauses: [RunPause], laps: [TopicTimer.LapType], openPause: Int?
    ) -> [RunSegment] {
        var lapN = 0
        return closed.map { c in
            let typing: (lapType: String?, label: String)
            if let step = c.step {
                typing = (nil, step.label)
            } else {
                lapN += 1
                typing = lapTyping(lapN, laps)
            }
            let paused = overlap(c.startedAt, c.endedAt, pauses, openPause: openPause)
            return RunSegment(
                kind: c.step == nil ? .lap : .step, step: c.step?.key, label: typing.label, startedAt: c.startedAt,
                endedAt: c.endedAt, activeMs: c.endedAt - c.startedAt - paused, pausedMs: paused,
                lapType: typing.lapType, eventId: c.eventId, openedBy: c.openedBy)
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
            edited: false, segments: state.segments, skipped: state.skipped, pauses: state.pauses,
            terminalId: state.terminalId)
    }
}

/// Code point order, like Python's `str` comparison (Swift's `<` on `String` compares canonical
/// equivalents equal and isn't code point order).
func codePointLess(_ a: String, _ b: String) -> Bool {
    a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars)
}
