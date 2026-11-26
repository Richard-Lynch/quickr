import Foundation
import GRDB
import QuickrCore

/// The widgets' reads from a store: one topic, or the due-first list. Read-only, so it works on a
/// `ReadOnlyStores` store in the widget extension.
public struct WidgetReader: Sendable {
    let store: LocalStore

    public init(store: LocalStore) { self.store = store }

    /// One topic (nil once it's gone: deleted, or another server's). `now` is the device time its
    /// run's pending alert is the next after.
    public func topic(id: UUID, now: Date = .now) async throws -> WidgetTopic? {
        guard let view = try await store.topics.topic(id: id) else { return nil }
        return try await widgetTopic(view.topic, state: storeState(), runs: runs(topicId: id), now: now)
    }

    /// One topic as it reads from `now`, then from each pending alert of its run on, up to `end`
    /// and at most `limit` alerts: `alert_at` is the next alert after the instant it's read for,
    /// so from an alert on the widget shows the one after it, or none (a timeline's entries, which
    /// WidgetKit shows without asking again). The first is `topic(id:now:)`.
    public func topicByAlert(id: UUID, now: Date, until end: Date, limit: Int = 8) async throws
        -> [(from: Date, topic: WidgetTopic?)]
    {
        var shown: [(from: Date, topic: WidgetTopic?)] = [(now, try await topic(id: id, now: now))]
        while shown.count <= limit, let last = shown.last,
            let at = last.topic?.runDisplay?.alert.map({ Date(timeIntervalSince1970: $0.at) }), at > last.from,
            at <= end
        {
            // A millisecond on: `alert_at` is rounded down to the millisecond it's computed for.
            shown.append((at, try await topic(id: id, now: at.addingTimeInterval(0.001))))
        }
        return shown
    }

    /// Active topics, due first (the home list's order at device time `now`, in server time), for
    /// the due-list widget.
    public func dueList(now: Date) async throws -> [WidgetTopic] {
        let state = try await storeState()
        let topics = try await store.topics.topics().map(\.topic)
        let runs = try await runs(topicId: nil)
        let listed = TopicListing.list(
            topics, topic: { $0 }, now: ServerClock(skew: state.skew).now(at: now), status: .active, sort: .due,
            query: "")
        var result: [WidgetTopic] = []
        for item in listed { result.append(try await widgetTopic(item.topic, state: state, runs: runs, now: now)) }
        return result
    }

    /// The store's measured skew in seconds (0 before the first pull, sync-protocol.md §10), and
    /// whether this build is too old for its server (client-versions.md §4.1).
    private func storeState() async throws -> (skew: TimeInterval, updateRequired: Bool) {
        let state = try await store.syncState.syncState()
        return ((state?.serverClock ?? .device).skew, state?.isClientOutdated ?? false)
    }

    /// The local view of runs (of one topic, or all), with the pinned timer of each one a widget
    /// can show (open or finishing) as the Live Activity reads it (`RunActivitySnapshot.timers`).
    private func runs(topicId: UUID?) async throws -> Runs {
        try await store.writer.read { db in
            let runs = try RunOverlay.localRuns(db, topicId: topicId?.wireString)
            let shown = runs.filter { $0.isOpen || $0.status == .finishing }
            return Runs(all: runs, timers: try RunActivitySnapshot.timers(db, runs: shown))
        }
    }

    struct Runs: Sendable {
        var all: [LocalRun]
        /// By run id: the pinned version's timer, when it's stored and timed.
        var timers: [String: TopicTimer]
    }

    /// The run a timed widget shows (timers.md §11.3): the topic's open run, else its newest
    /// finishing one (the home tile's choice), as its Live Activity's content state at `now`: with
    /// the pinned timer's lap types (`next_label` in a typed lap) and its pending alert
    /// (`alert_at`, the next after `now`).
    static func shownRun(_ topicId: UUID, in runs: Runs, now: Date) -> RunActivityState? {
        let mine = runs.all.filter { $0.topicId == topicId }
        let finishing = mine.filter { $0.status == .finishing }.max { $0.state.startedAt < $1.state.startedAt }
        guard let run = mine.first(where: \.isOpen) ?? finishing else { return nil }
        return RunActivitySnapshot.state(run, timer: runs.timers[run.id], now: now)
            ?? RunActivitySnapshot.stateWithoutSteps(run)
    }

    /// Whether the topic's open run takes the lap-typed Auto (§5.3), as `RunWrites.autoTap` decides
    /// it: from the run's pinned timer, so a timer edited mid-run doesn't change what the one
    /// button says it will do. Nil without an open run (Auto starts one on the current timer).
    static func openRunLapTyped(_ topicId: UUID, in runs: Runs) -> Bool? {
        guard let run = runs.all.first(where: { $0.topicId == topicId && $0.isOpen }) else { return nil }
        return run.steps != nil && !(run.timer?.laps.isEmpty ?? true)
    }

    /// The open run's Auto press as `RunWrites.autoTap` makes it (§5.3); nil without an open run.
    static func openRunAuto(_ topicId: UUID, in runs: Runs) -> WidgetRunButton? {
        guard let run = runs.all.first(where: { $0.topicId == topicId && $0.isOpen }) else { return nil }
        switch RunWrites.autoTap(run) {
        case .lap: return .lap
        case .stop: return .stop
        default: return .next
        }
    }

    private func widgetTopic(
        _ topic: Topic, state: (skew: TimeInterval, updateRequired: Bool), runs: Runs, now: Date
    ) async throws -> WidgetTopic {
        let quick = QuickLog(questions: topic.questions)
        var lastAnswer: AnswerValue?
        if let question = quick?.question, let latest = try await store.entries.latestEntry(topicId: topic.id) {
            lastAnswer = latest.entry.answers[question.key]
        }
        // Counted in SQL: a long offline backlog is many rows with payloads, and a widget's
        // timeline has little memory and time.
        let topicId = topic.id.wireString
        let (queued, failed) = try await store.writer.read { db -> (Int, Int) in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT COALESCE(SUM(state != 'failed'), 0) AS queued, COALESCE(SUM(state = 'failed'), 0) AS failed
                    FROM outbox_item WHERE topic_id = ? AND kind = ?
                    """,
                arguments: [topicId, OutboxKind.entryCreate.rawValue])
            return (row?["queued"] ?? 0, row?["failed"] ?? 0)
        }
        return WidgetTopic(
            topic: topic, quick: quick, lastAnswer: lastAnswer, queued: queued, failed: failed, scope: store.scope,
            skew: state.skew, hasOpenRun: RunOverlay.openRunTopics(runs.all).contains(topic.id),
            run: Self.shownRun(topic.id, in: runs, now: now), runLapTyped: Self.openRunLapTyped(topic.id, in: runs),
            runAuto: Self.openRunAuto(topic.id, in: runs), updateRequired: state.updateRequired)
    }
}
