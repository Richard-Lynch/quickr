import Foundation
import GRDB
import QuickrCore

/// A run as this device sees it (timers.md §8.3): the fold of the server-layer run's events, in
/// their arrival order, then this device's active `run.event` items for the run and its aliases,
/// in outbox `seq` order. Failed items are left out (the sync sheet lists them).
public struct LocalRun: Sendable, Hashable, Identifiable {
    /// The server's id for the run (a merge target), or the queued start's id. Lowercase.
    public var id: String
    public var topicId: UUID
    /// The topic as the queued items name it; nil for a run known only from the server.
    public var topic: TopicRef?
    /// The version the run is pinned to (never the topic's current one).
    public var version: Int
    /// As the server will have it once the queued items are in, `finishing` included.
    public var status: RunStatus
    public var state: RunState
    /// The server's events in arrival order, then the queued ones in `seq` order.
    public var events: [RunEvent]
    /// Other run ids that route here: the server's aliases, and the queued items' run ids.
    public var aliases: [String]
    /// The server layer's run, once the server has answered for it.
    public var server: Run?
    /// The run's active queued items, in `seq` order.
    public var queued: [OutboxItem]
    /// The pinned version's steps; nil when that version isn't stored here yet (the fold then
    /// uses no steps, so a start still shows its clock).
    public var steps: [TopicTimer.Step]?
    /// Whether the pinned version has a required question (a stop without answers then leaves the
    /// run finishing, §3.5); nil when the version isn't stored.
    public var requiresAnswers: Bool?
    /// Whether the pinned version has any question (Stop then opens the answers form, §11.2);
    /// nil when the version isn't stored.
    public var hasQuestions: Bool?
    /// The pinned version's timer (steps and lap types, timers2.md §1.1); nil when that version
    /// isn't stored here, or is untimed.
    public var timer: TopicTimer? = nil
    /// A reopen queued from the run's entry while no run row is here (timers2.md §5.3): the run is
    /// projected from the entry's timing, "Resuming…" without controls, until the ack replaces it
    /// with the server's run. It takes no tap but its revert (a discard).
    public var resuming = false

    public var isOpen: Bool { status.isOpen }

    /// Whether `runId` (its own id or an alias) routes to this run.
    public func answers(to runId: String) -> Bool {
        let runId = runId.lowercased()
        return id == runId || aliases.contains(runId)
    }

    /// The id of the pause a resume would end: the latest applied pause, while paused.
    public var openPauseId: String? { Self.openPauseId(state, events) }

    static func openPauseId(_ state: RunState, _ events: [RunEvent]) -> String? {
        guard state.pausedSince != nil else { return nil }
        var latest: RunEvent?
        for event in events where event.type == .pause && state.effects[event.id.lowercased()] == .applied {
            guard let current = latest else {
                latest = event
                continue
            }
            if event.at > current.at || (event.at == current.at && codePointGreater(event.id, current.id)) {
                latest = event
            }
        }
        return latest?.id.lowercased()
    }

    /// Every `at` the run has here, for the clamp (timers.md §5.1 item 4).
    var ats: [Int] { events.map(\.at) }
}

/// The local view of runs (timers.md §8.3), read inside the caller's transaction like the rest of
/// the view. A queued start makes an open run at once, offline too, and a device that is the only
/// one tapping sees exactly the state the server will reach. A queued reopen of a closed run
/// whose entry is here projects a "resuming" run from that entry (timers2.md §5.3,
/// `RunOverlay+Reopen.swift`).
///
/// The server layer is updated atomically with each ack (`ServerLayer.apply(runEvent:)`), so an
/// acked event never drops out of the view before the feed has it: unlike the PWA, no record of
/// acked events is kept.
public enum RunOverlay {
    /// The local runs (of one topic, or all): each server run with its queued items, then each run
    /// only this device's queued start knows. Items of a run that is in neither (it closed, and the
    /// server will decide their late merge, §4.4) make no run. Like entries, a run is hidden until
    /// its topic arrives. Includes finishing and just-closed runs: check `status`.
    public static func localRuns(_ db: Database, topicId: String? = nil) throws -> [LocalRun] {
        let servers = try StoreView.runs(db, topicId: topicId)
        let filter = topicId == nil ? "" : "AND topic_id = ?"
        let items = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM outbox_item
                WHERE kind = 'run.event' AND state IN ('pending', 'in_flight', 'uncertain') \(filter)
                ORDER BY entity_id, seq
                """,
            arguments: StatementArguments(topicId.map { [$0] } ?? [])
        ).map(OutboxItem.init(row:))
        if servers.isEmpty, items.isEmpty { return [] }

        var target: [String: String] = [:]
        // Run id → the merged ids stored for it (`run_alias`, the ack's included).
        var stored: [String: [String]] = [:]
        for run in servers {
            let id = run.id.wireString
            target[id] = id
            for alias in run.aliases { target[alias.wireString] = id }
        }
        for row in try Row.fetchAll(db, sql: "SELECT id, run_id FROM run_alias") {
            let runId: String = row["run_id"]
            if target[runId] == runId {
                target[row["id"]] = runId
                stored[runId, default: []].append(row["id"])
            }
        }
        var groups: [String: [OutboxItem]] = [:]
        for item in items { groups[target[item.entityId] ?? item.entityId, default: []].append(item) }
        // Outbox order within a run (its items may have been sent to several of its ids).
        groups = groups.mapValues { $0.sorted { $0.seq < $1.seq } }
        let order = groups.keys.sorted { (groups[$0]?.first?.seq ?? 0) < (groups[$1]?.first?.seq ?? 0) }

        let book = VersionBook(db)
        var result: [LocalRun] = []
        for server in servers {
            let id = server.id.wireString
            if let run = try build(
                db, id: id, server: server, queued: groups.removeValue(forKey: id) ?? [], aliases: stored[id] ?? [],
                book)
            {
                result.append(run)
            }
        }
        for key in order {
            guard let queued = groups[key] else { continue }
            // No start here: a reopen queued from the run's entry (timers2.md §5.3) resumes it.
            guard queued.contains(where: { $0.id == key }) else {
                if let run = try resuming(db, id: key, queued: queued, book) { result.append(run) }
                continue
            }
            // A closed run's marker (or a deleted one's tombstone): its start was answered
            // elsewhere, its queued taps are the server's to merge (§4.4).
            guard try !ServerLayer.isClosedRun(db, id: key),
                let run = try build(db, id: key, server: nil, queued: queued, aliases: [], book)
            else { continue }
            result.append(run)
        }
        return result
    }

    /// The run `runId` (its own id or an alias) routes to.
    public static func localRun(_ db: Database, id runId: String) throws -> LocalRun? {
        try localRuns(db).first { $0.answers(to: runId) }
    }

    /// The topic's open run (running or paused), if any: one per topic (§5).
    public static func openRun(_ db: Database, topicId: String) throws -> LocalRun? {
        try localRuns(db, topicId: topicId).first(where: \.isOpen)
    }

    /// The topics with an open local run (running or paused), queued starts included: what the due
    /// count leaves out (timers.md §11.1). A finishing run isn't open, so its topic keeps its due
    /// state.
    public static func openRunTopics(_ db: Database) throws -> TopicListing.OpenRunTopics {
        openRunTopics(try localRuns(db))
    }

    /// The same set from runs already read (`observeLocalRuns`): the one rule.
    public static func openRunTopics(_ runs: [LocalRun]) -> TopicListing.OpenRunTopics {
        Set(runs.filter(\.isOpen).map(\.topicId))
    }

    // MARK: - Building one run

    private static func build(
        _ db: Database, id: String, server: Run?, queued: [OutboxItem], aliases storedAliases: [String],
        _ book: VersionBook
    ) throws -> LocalRun? {
        let mine = queued.compactMap { item in (try? item.runEventPayload()).map { (item, $0) } }
        let start = mine.first { $0.0.id == id && $0.1.type == .start }?.1
        guard let topicId = server?.topicId ?? start.flatMap({ UUID(uuidString: $0.topic.id) }),
            let version = server?.version ?? start?.event.version,
            try topicExists(db, topicId.wireString)
        else { return nil }
        let info = try book.info(topicId.wireString, version)
        let events = (server?.foldEvents ?? []) + mine.compactMap { queuedEvent($0.0, $0.1) }

        let state: RunState
        if mine.isEmpty, let server {
            state = server.state
        } else if info.steps == nil, let server {
            // The pinned version isn't stored: the server's labels, not a fold over the wrong steps,
            // with this device's step-independent taps over them (a reopen of the server's closed
            // state first: `reopened(_:taps:)`).
            let (base, taps) = reopened(server.state, taps: mine.compactMap { queuedEvent($0.0, $0.1) })
            state = RunFold.overlay(
                base, events: taps,
                pauseId: base.pausedSince == nil ? nil : LocalRun.openPauseId(server.state, server.foldEvents))
        } else if let folded = try? RunFold.fold(
            runId: id, timer: info.timer ?? TopicTimer(steps: []), events: events)
        {
            state = folded
        } else if let server {
            state = server.state
        } else {
            return nil
        }

        var aliases = Set((server?.aliases.map(\.wireString) ?? []) + storedAliases)
        for (_, payload) in mine { aliases.insert(payload.runId) }
        aliases.remove(id)
        let entry =
            isReopened(state, events)
            ? try hasEntry(db, id: id, server: server, events: events, mine: mine, requiresAnswers: info.requiresAnswers)
            : false
        return LocalRun(
            id: id, topicId: topicId, topic: mine.last?.1.topic, version: version,
            status: status(
                server: server, state: state, events: events, mine: mine, requiresAnswers: info.requiresAnswers,
                entry: entry),
            state: state, events: events, aliases: aliases.sorted(), server: server, queued: queued,
            steps: info.steps, requiresAnswers: info.requiresAnswers, hasQuestions: info.hasQuestions,
            timer: info.timer)
    }

    static func queuedEvent(_ item: OutboxItem, _ payload: RunEventPayload) -> RunEvent? {
        guard let type = payload.type, let at = RunInstant.parse(payload.event.at) else { return nil }
        return RunEvent(
            id: item.id.lowercased(), type: type, at: at, seg: payload.event.seg, step: payload.event.step,
            pauseId: payload.event.pauseId?.lowercased(), target: payload.event.target?.lowercased())
    }

    /// The fold says `stopped`; the server decides `finishing` (§3.5), and a finishing run's
    /// discard and finish happen outside the fold (§3.6, §3.7). A discard that reverted a reopen
    /// (timers2.md §3.4) leaves the run `stopped` when it has its entry, and `discarded` when it
    /// doesn't (a reopened finishing run, §4.1, §5.3: no optimistic entry, A15). `entry`: the run
    /// was reopened and has its entry (`hasEntry`).
    private static func status(
        server: Run?, state: RunState, events: [RunEvent], mine: [(OutboxItem, RunEventPayload)],
        requiresAnswers: Bool?, entry: Bool
    ) -> RunStatus {
        if !state.status.isOpen, isReverted(state, events) || (state.status == .discarded && isReopened(state, events)) {
            return entry ? .stopped : .discarded
        }
        guard state.status == .stopped else { return state.status }
        guard
            stopLeavesFinishing(
                server: server, state: state, mine: mine.map(\.1), requiresAnswers: requiresAnswers, entry: entry)
        else { return .stopped }
        if mine.contains(where: { $0.1.type == .discard }) { return .discarded }
        if mine.contains(where: { $0.1.type == .finish }) { return .stopped }
        return .finishing
    }

    /// The server says the run is finishing, or its stop (the terminal) is this device's queued
    /// one, carries no answers and the version has a required question. A re-stop of a reopened
    /// run that has its entry never leaves it finishing (timers2.md §4.1): it updates the entry.
    private static func stopLeavesFinishing(
        server: Run?, state: RunState, mine: [RunEventPayload], requiresAnswers: Bool?, entry: Bool
    ) -> Bool {
        if entry { return false }
        if server?.status == .finishing { return true }
        guard let terminal = state.terminalId, let stop = mine.first(where: { $0.event.id.lowercased() == terminal })
        else { return false }
        return stop.type == .stop && stop.event.answers == nil && requiresAnswers == true
    }

    static func topicExists(_ db: Database, _ id: String) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM topic WHERE id = ?)", arguments: [id]) ?? false
    }

    // MARK: - Optimistic entries

    /// The entries that queued taps will make (§8.3), as entry overlays: a queued stop that won't
    /// leave its run finishing, or the finish of a finishing run, until the server's entry
    /// replaces it. The entry's id is the run's (§3.5), so a server row (or tombstone) for that id
    /// wins. The answers and notes are the last queued finish's, else the stop's. Only for runs
    /// whose pinned version is stored (the timing needs its steps).
    static func optimisticEntries(_ db: Database, topicId: String?, book: QuestionBook) throws -> [EntryOverlay] {
        // Most reads have no queued run event: they never touch the run tables.
        let filter = topicId == nil ? "" : "AND topic_id = ?"
        guard
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS (
                      SELECT 1 FROM outbox_item
                      WHERE kind = 'run.event' AND state IN ('pending', 'in_flight', 'uncertain') \(filter))
                    """,
                arguments: StatementArguments(topicId.map { [$0] } ?? [])) == true
        else { return [] }
        var result: [EntryOverlay] = []
        for run in try localRuns(db, topicId: topicId) {
            guard run.status == .stopped, !run.resuming, run.server?.status != .stopped, let steps = run.steps,
                let entryId = UUID(uuidString: run.id),
                try !ServerLayer.isTombstoned(db, kind: .entry, id: run.id),
                try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM entry WHERE id = ?)", arguments: [run.id])
                    == false,
                let timing = try? RunFold.projectTiming(run.state, steps: steps)
            else { continue }
            let carriers = run.queued.compactMap { item in (try? item.runEventPayload()).map { (item, $0) } }
            guard
                let carrier = carriers.last(where: { $0.1.type == .finish })
                    ?? carriers.first(where: { $0.1.type == .stop })
            else { continue }
            let (item, payload) = carrier
            let questions = try book.questions(run.topicId.wireString, run.version)
            let source =
                run.server?.events.first { $0.event.id.lowercased() == run.id }?.source
                ?? run.queued.first { $0.id == run.id }?.origin.source ?? item.origin.source
            let entry = Entry(
                id: entryId, topicId: run.topicId, version: run.version, revision: 0, source: source, channel: .ios,
                capturedAt: RunInstant.date(timing.endedAt), createdAt: item.createdAt, updatedAt: item.updatedAt,
                notes: payload.event.notes ?? "", meta: payload.event.meta ?? [:],
                answers: (payload.event.answers ?? [:]).compactMapValues { $0?.value }.normalized(for: questions),
                timing: timing)
            result.append(
                EntryOverlay(
                    entry: entry, syncState: .pending, hidden: false, undoable: false, createFailed: false,
                    lastError: nil, createSeq: item.seq))
        }
        return result
    }
}

/// The steps and required-question flag of each `(topic, version)`, read lazily within one read
/// transaction.
final class VersionBook {
    struct Info {
        /// The version's timer (steps and lap types, the fold's input); nil when not stored or
        /// untimed.
        var timer: TopicTimer?
        var steps: [TopicTimer.Step]?
        var requiresAnswers: Bool?
        var hasQuestions: Bool?
    }

    private let db: Database
    private var cache: [String: Info] = [:]

    init(_ db: Database) { self.db = db }

    /// A stored version's steps (none for an untimed one) and question flags; all nil when the
    /// version isn't stored.
    func info(_ topicId: String, _ version: Int) throws -> Info {
        let key = "\(topicId)#\(version)"
        if let cached = cache[key] { return cached }
        let row = try Row.fetchOne(
            db, sql: "SELECT questions_json, timer_json FROM topic_version WHERE topic_id = ? AND version = ?",
            arguments: [topicId, version])
        var info = Info()
        if let row {
            let timer = try (row["timer_json"] as String?).map { try StoreJSON.decode(TopicTimer.self, $0) }
            info.timer = timer
            info.steps = timer?.steps ?? []
            let questions = try StoreJSON.decode([QuestionDTO].self, row["questions_json"]).toDomain()
            info.requiresAnswers = questions.contains(where: \.required)
            info.hasQuestions = !questions.isEmpty
        }
        cache[key] = info
        return info
    }
}

/// Code point order, like the fold's id tie-break.
private func codePointGreater(_ a: String, _ b: String) -> Bool {
    b.lowercased().unicodeScalars.lexicographicallyPrecedes(a.lowercased().unicodeScalars)
}
