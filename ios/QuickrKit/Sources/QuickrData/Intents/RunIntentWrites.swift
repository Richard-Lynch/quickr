import Foundation
import GRDB
import QuickrCore

/// What a run intent asks for (timers.md §11.3): a timed widget's button, the timer Control, the
/// Action button (`AdvanceRunIntent`) or Siri (`RunActionIntent`).
public enum RunIntentAction: String, Sendable, Hashable, CaseIterable {
    /// §11.1: no open run → Start; a named step remains, or the steps aren't known → Next;
    /// otherwise → Stop. A finishing run isn't open, so Auto starts a new run then.
    case auto
    case start, next, lap, stop, pause, resume
}

/// One run intent: what to do, to which topic, from which surface.
public struct RunIntentRequest: Sendable, Hashable {
    /// What a widget drew: the run and segment its content showed. A tap on a run that has moved
    /// on since (stopped, or another segment) does nothing (`RunTapTarget.shown`).
    public struct Shown: Sendable, Hashable {
        public var runId: String
        public var seg: Int

        public init(runId: String, seg: Int) {
            self.runId = runId
            self.seg = seg
        }
    }

    public var action: RunIntentAction
    /// Nil (Siri without a topic): the only open run; several, or none for a start, are asked.
    public var topicId: UUID?
    /// `.widget` for a widget's button and the Control, `.siri` for Siri, Shortcuts and the
    /// Action button.
    public var origin: OutboxOrigin
    /// The store a widget or Control was drawn from: it acts only while that one is active.
    public var scope: EntryScope?
    public var shown: Shown?

    public init(
        action: RunIntentAction, topicId: UUID?, origin: OutboxOrigin, scope: EntryScope? = nil, shown: Shown? = nil
    ) {
        self.action = action
        self.topicId = topicId
        self.origin = origin
        self.scope = scope
        self.shown = shown
    }
}

/// What a run intent did, and what it says (§11.3, "Spoken results").
public enum RunIntentOutcome: Sendable, Hashable {
    /// `first`: the first step's label. `waitingDetails`: the topic's last run is still finishing.
    case started(topic: String, first: String?, waitingDetails: Bool)
    /// Next closed `done` after `ms`; `next` is the step it opened (nil for a lap, or unknown steps).
    case advanced(done: String, ms: Int, next: String?)
    case lapped(done: String, ms: Int)
    case paused(topic: String)
    case resumed(topic: String)
    /// The stop made the entry: the run's active time.
    case saved(topic: String, ms: Int)
    /// The stop left the run finishing: its required answers are still to come (§3.5).
    case savedNeedsDetails(topic: String, ms: Int)

    // Nothing written:
    case alreadyRunning(topic: String)
    /// `finishing`: stopped already, waiting for its details.
    case notRunning(topic: String, finishing: Bool)
    case alreadyPaused(topic: String)
    case notPaused(topic: String)
    /// A widget's tap on a run or segment that has moved on since it was drawn.
    case moved(topic: String)
    case notTimed(topic: String)
    case archived(topic: String)
    case topicNotFound
    /// No topic given, and nothing to act on.
    case nothingRunning
    /// No topic given: one of `topics` (open runs) must be chosen; empty, any topic (a start).
    case chooseTopic([TopicRef])
    /// Inside the topic's tap cooldown (`RunActions.admits`): a double press.
    case ignored(topic: String?)

    /// The dialog, with durations as `duration` writes them: `DurationFormat.format` on screen
    /// ("4:12"), `RunPresentation.spoken` for Siri's voice ("4 minutes 12 seconds").
    public func text(duration: (Int) -> String) -> String {
        switch self {
        case .started(let topic, let first, let waiting):
            var text = "Started \(topic)."
            if let first { text += " First: \(first)." }
            if waiting { text += " Its last run still needs details." }
            return text
        case .advanced(let done, let ms, let next):
            return "\(done) took \(duration(ms))." + (next.map { " Next: \($0)." } ?? "")
        case .lapped(let done, let ms): return "\(done) took \(duration(ms))."
        case .paused(let topic): return "Paused \(topic)."
        case .resumed(let topic): return "Resumed \(topic)."
        case .saved(let topic, let ms): return "Saved \(topic): \(duration(ms))."
        case .savedNeedsDetails(_, let ms): return "Saved \(duration(ms)). Open quickR to add details."
        case .alreadyRunning(let topic): return "\(topic) is already running."
        case .notRunning(let topic, let finishing):
            return finishing ? "\(topic) is already stopped. Open quickR to add details." : "\(topic) isn't running."
        case .alreadyPaused(let topic): return "\(topic) is already paused."
        case .notPaused(let topic): return "\(topic) isn't paused."
        case .moved(let topic): return "\(topic) has moved on since: nothing was changed."
        case .notTimed(let topic): return "\(topic) isn't timed: log it in quickR."
        case .archived(let topic): return "\(topic) is archived."
        case .topicNotFound: return IntentLogging.Failure.topicNotFound.description
        case .nothingRunning: return "Nothing is running in quickR."
        case .chooseTopic: return "Which topic?"
        case .ignored(let topic): return topic.map { "\($0): already on it." } ?? "Already on it."
        }
    }

    /// On screen: "Shower took 4:12. Next: Breakfast."
    public var shownText: String { text(duration: DurationFormat.format) }

    /// Spoken: "Shower took 4 minutes 12 seconds. Next: Breakfast."
    public var spokenText: String { text(duration: RunPresentation.spoken) }
}

/// What `RunWrites.perform(_:)` did: the outcome, the topic it acted on, and whether it enqueued.
public struct RunIntentResult: Sendable, Hashable {
    public var outcome: RunIntentOutcome
    public var topicId: UUID?
    /// One `run.event` item was enqueued (the caller flushes).
    public var wrote: Bool
    /// It was enqueued while this build is below the server's minimum (client-versions.md §4.1):
    /// kept for the updated build, not flushed.
    public var clientOutdated = false

    public init(_ outcome: RunIntentOutcome, topicId: UUID? = nil, wrote: Bool = false) {
        self.outcome = outcome
        self.topicId = topicId
        self.wrote = wrote
    }

    /// On screen, with "Saved on this iPhone. Update quickR to sync." while outdated.
    public var shownText: String { ClientOutdated.saying(outcome.shownText, outdated: clientOutdated) }

    /// Spoken, likewise.
    public var spokenText: String { ClientOutdated.saying(outcome.spokenText, outdated: clientOutdated) }

    /// A start was enqueued: this device requests the run's Live Activity (I-LA).
    public var started: Bool {
        if case .started = outcome { return wrote }
        return false
    }
}

extension RunWrites {
    /// A run intent, decided and written in one transaction, so what it says is what it did:
    /// the topic (given, or the only open run), the action (Auto resolved, `RunWrites.autoTap`),
    /// then one start or tap through the façade. A widget's tap targets the run and segment it
    /// showed; every other surface the current state. It never reads the scope: the caller
    /// checks that the request's store is this one.
    public func perform(_ request: RunIntentRequest) async throws -> RunIntentResult {
        let tapAt = now()
        let device = await device()
        let origin = origin
        var written = try await write { db, now, wall -> RunIntentResult in
            if try StoreFence.isRetired(db) { throw StoreError.retired }
            let topic: Topic
            switch try Self.resolve(db, request) {
            case .topic(let found): topic = found
            case .done(let result): return result
            }
            let ref = TopicRef(id: topic.id, slug: topic.slug, name: topic.name)
            let name = topic.name
            func result(_ outcome: RunIntentOutcome, wrote: Bool = false) -> RunIntentResult {
                RunIntentResult(outcome, topicId: topic.id, wrote: wrote)
            }
            let runs = try RunOverlay.localRuns(db, topicId: topic.id.wireString)
            let open = runs.first(where: \.isOpen)
            let finishing = runs.contains { $0.status == .finishing }

            var action = request.action
            if action == .auto { action = open.map { Self.autoTap($0) == .next ? .next : .stop } ?? .start }
            if action == .start {
                guard open == nil else { return result(.alreadyRunning(topic: name)) }
                guard topic.status != .archived else { return result(.archived(topic: name)) }
                guard topic.timer != nil else { return result(.notTimed(topic: name)) }
                let started = try Self.start(
                    db, topic: ref, version: topic.currentVersion, id: nil, meta: nil, tapAt: tapAt, device: device,
                    origin: origin, now: now, wall: wall)
                guard started.started else { return result(.alreadyRunning(topic: name)) }
                let first = try RunOverlay.localRun(db, id: started.runId)?.state.open.flatMap {
                    $0.kind == .step ? $0.label : nil
                }
                return result(.started(topic: name, first: first, waitingDetails: finishing), wrote: true)
            }

            // A widget's tap goes to the run it showed, and only while that one is open.
            let run: LocalRun
            let target: RunTapTarget
            if let shown = request.shown {
                guard let showed = runs.first(where: { $0.answers(to: shown.runId) }), showed.isOpen else {
                    return result(open == nil ? .notRunning(topic: name, finishing: finishing) : .moved(topic: name))
                }
                (run, target) = (showed, .shown(seg: shown.seg, step: nil, pauseId: nil))
            } else {
                guard let open else { return result(.notRunning(topic: name, finishing: finishing)) }
                (run, target) = (open, .current)
            }
            let type: RunTapType =
                switch action {
                case .next: .next
                case .lap: .lap
                case .pause: .pause
                case .resume: .resume
                case .stop, .start, .auto: .stop
                }
            let enqueued = try Self.tap(
                db, type, run: run, target: target, body: Body(), tapAt: tapAt, device: device, origin: origin,
                now: now, wall: wall)
            guard case .appended(let item)? = enqueued,
                let at = (try item.runEventPayload()).flatMap({ RunInstant.parse($0.event.at) })
            else {
                switch type {
                case .pause: return result(.alreadyPaused(topic: name))
                case .resume: return result(.notPaused(topic: name))
                default: return result(.moved(topic: name))
                }
            }
            let after = try RunOverlay.localRun(db, id: run.id)
            // A widget's stale segment: queued as shown, void in the fold (and on the server).
            if case .void? = after?.state.effects[item.id.lowercased()] {
                return result(.moved(topic: name), wrote: true)
            }
            let segment = run.state.open?.label ?? name
            let outcome: RunIntentOutcome
            switch type {
            case .next:
                // Unknown steps: the local fold can't say which step opened.
                let next = run.steps == nil ? nil : after?.state.open.flatMap { $0.kind == .step ? $0.label : nil }
                outcome = .advanced(done: segment, ms: RunPresentation.segmentMs(run.state, now: at), next: next)
            case .lap:
                outcome = .lapped(done: segment, ms: RunPresentation.segmentMs(run.state, now: at))
            case .pause:
                outcome = .paused(topic: name)
            case .resume:
                outcome = .resumed(topic: name)
            default:
                // The app's rule (`RunActions.stop`): a version with questions, or whose questions
                // aren't known, has details to add.
                let ms = RunPresentation.activeMs(run.state, now: at)
                outcome =
                    run.hasQuestions != false ? .savedNeedsDetails(topic: name, ms: ms) : .saved(topic: name, ms: ms)
            }
            return result(outcome, wrote: true)
        }
        if written.wrote { written.clientOutdated = await ClientOutdated.isOutdated(store) }
        return written
    }

    /// The topic `request` acts on, read before the write so the caller can apply the topic's
    /// cooldown: the given one, or the only open run's; nil when there is none to act on (several
    /// open runs, none, or an unknown topic: `perform` says which).
    public func topicId(for request: RunIntentRequest) async throws -> UUID? {
        try await store.writer.read { db in
            guard case .topic(let topic) = try Self.resolve(db, request) else { return nil }
            return topic.id
        }
    }

    private enum Resolved {
        case topic(Topic)
        case done(RunIntentResult)
    }

    /// The request's topic: the given one, or the only open run's. Several open runs (or none,
    /// for a start) ask which.
    private static func resolve(_ db: Database, _ request: RunIntentRequest) throws -> Resolved {
        if let id = request.topicId {
            guard let found = try StoreView.topic(db, id: id.wireString) else {
                return .done(RunIntentResult(.topicNotFound))
            }
            return .topic(found.topic)
        }
        let open = try RunOverlay.localRuns(db).filter(\.isOpen)
        guard open.count == 1 else {
            if open.isEmpty {
                let starts = request.action == .start || request.action == .auto
                return .done(RunIntentResult(starts ? .chooseTopic([]) : .nothingRunning))
            }
            var refs: [TopicRef] = []
            for run in open {
                guard let topic = try StoreView.topic(db, id: run.topicId.wireString)?.topic else { continue }
                refs.append(TopicRef(id: topic.id, slug: topic.slug, name: topic.name))
            }
            refs.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return .done(RunIntentResult(.chooseTopic(refs)))
        }
        guard let topic = try StoreView.topic(db, id: open[0].topicId.wireString)?.topic else {
            return .done(RunIntentResult(.topicNotFound))
        }
        return .topic(topic)
    }
}
