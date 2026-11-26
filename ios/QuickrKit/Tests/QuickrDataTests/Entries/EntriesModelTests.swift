import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport
import Synchronization
import Testing

/// `EntriesModel` over a real `AppSession` and store (offline: every request fails): the server's
/// entries filtered and ordered like the server, the device-only ones pinned on top in outbox
/// order, edits and deletes through the outbox, and a clean start over on a rebind.
@MainActor
@Suite struct EntriesModelTests {
    /// 2026-10-20 12:00 UTC: a Tuesday.
    nonisolated static let now = Date(timeIntervalSince1970: 1_792_497_600)
    nonisolated static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    nonisolated static let topicId = UUID(uuidString: "00000000-0000-4000-8000-0000000000aa")!
    nonisolated static let glasses = Question(
        key: "glasses", label: "Glasses", kind: .int(.init(min: 0, unit: "glasses")))
    nonisolated static let mood = Question(
        key: "mood", label: "Mood",
        kind: .choice(.init(options: [.init(value: "good", label: "Good"), .init(value: "meh", label: "Meh")])))
    /// Only version 1 had it.
    nonisolated static let note = Question(key: "note", label: "Note", required: false, kind: .string(.init()))

    nonisolated static let topic = Topic(
        id: topicId, slug: "water", name: "Water", currentVersion: 2, revision: 1, questionCount: 2,
        createdAt: now.addingTimeInterval(-86_400 * 100), updatedAt: now.addingTimeInterval(-86_400 * 100),
        questions: [glasses, mood])

    nonisolated static func entry(
        _ n: Int, daysAgo: Double, version: Int = 2, source: String = "ios", answers: [String: AnswerValue] = [:]
    ) -> Entry {
        let at = now.addingTimeInterval(-daysAgo * 86_400)
        return Entry(
            id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!, topicId: topicId,
            version: version, revision: 1, source: source, channel: .ios, capturedAt: at, createdAt: at,
            updatedAt: at, answers: answers.isEmpty ? ["glasses": .int(n)] : answers)
    }

    /// Two entries at the same instant (3 before 2 by id), others older, one outside 30 days, one
    /// from version 1 with a source of its own.
    nonisolated static let entries: [Entry] = [
        entry(3, daysAgo: 1), entry(2, daysAgo: 1), entry(4, daysAgo: 0.5), entry(5, daysAgo: 10, source: "api"),
        entry(6, daysAgo: 40), entry(7, daysAgo: 20, version: 1, source: "csv", answers: ["note": .string("old")]),
    ]

    @MainActor struct World {
        let root: URL
        let session: AppSession
        let partitions: StorePartitions

        /// - Parameter seeded: false leaves the store empty (the topic arrives later).
        init(active: Bool = true, seeded: Bool = true) async throws {
            root = URL.temporaryDirectory.appending(path: "quickr-entries-\(UUID().uuidString)")
            let location = StoreLocation(root: root)
            partitions = try StorePartitions.open(at: location, notifier: nil)
            let store = try await partitions.createStore(serverId: "s", baseURL: "https://quickr.example")
            if active { try await partitions.registry.setActive("s") }
            if seeded { try await EntriesModelTests.seed(store) }
            var coordinator = SyncCoordinator.Configuration()
            coordinator.autoRetry = false
            session = try AppSession(
                configuration: .init(location: location, transport: Offline(), coordinator: coordinator))
            await session.start()
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }

        func model(_ ref: String = "water") async throws -> (EntriesModel, Task<Void, Never>) {
            let model = EntriesModel(
                session: session, topicRef: ref, now: EntriesModelTests.now, calendar: EntriesModelTests.utc)
            let observing = Task { await model.observe() }
            // Ready, or settled on "not found".
            try await eventually("the entries are read") { await MainActor.run { model.phase != .loading } }
            return (model, observing)
        }
    }

    struct Offline: Transport {
        func send(_ request: HTTPRequest) async throws -> HTTPResponse { throw URLError(.notConnectedToInternet) }
    }

    nonisolated static func seed(_ store: LocalStore) async throws {
        try await store.writer.write { db in
            _ = try ServerLayer.upsert(db, topic: topic)
            for (n, questions) in [(1, [glasses, note]), (2, [glasses, mood])] {
                _ = try ServerLayer.insert(
                    db, version: TopicVersion(version: n, questions: questions, createdAt: now), id: UUID(),
                    topicId: topicId)
            }
            for entry in entries { _ = try ServerLayer.upsert(db, entry: entry) }
        }
    }

    static func ids(_ entries: [EntriesModel.Row]) -> [Int] {
        entries.map { Int($0.id.uuidString.suffix(12))! }
    }

    static var water: TopicRef { TopicRef(id: topicId, slug: "water", name: "Water") }

    // MARK: - Tests

    @Test func listsTheServersEntriesInTheServersOrder() async throws {
        let w = try await World()
        defer { w.cleanup() }
        let (model, observing) = try await w.model()
        defer { observing.cancel() }

        #expect(model.phase == .ready)
        #expect(Self.ids(model.rows) == [4, 2, 3, 5, 7], "newest first; equal times by id ascending; 30 days")
        #expect(model.pinned.isEmpty)
        #expect(model.sources.map(\.value) == ["ios", "api", "csv"], "most entries first, then by name")
        #expect(model.versionChoices == [2, 1])
        #expect(model.columns.map(\.key) == ["glasses", "mood", "note"], "current questions, then older keys")
    }

    @Test func theFiltersApplyOnTheDevice() async throws {
        let w = try await World()
        defer { w.cleanup() }
        let (model, observing) = try await w.model()
        defer { observing.cancel() }

        model.filters.range = .all
        #expect(Self.ids(model.rows) == [4, 2, 3, 5, 7, 6])
        model.filters.range = .sevenDays
        #expect(Self.ids(model.rows) == [4, 2, 3])
        model.filters = EntryListFilters(range: .all, version: 1)
        #expect(Self.ids(model.rows) == [7])
        model.filters = EntryListFilters(range: .all, source: "api")
        #expect(Self.ids(model.rows) == [5])
        model.filters = EntryListFilters(range: .all, version: 1, source: "api")
        #expect(model.rows.isEmpty && !model.hasNoEntriesAtAll, "\"No entries match\"")
        #expect(model.sources.count == 3, "the source choices ignore the filters")
    }

    /// The range starts at local midnight, days back: an entry at 00:00 of the first day is in.
    @Test func theRangeStartsAtLocalMidnight() {
        let start = EntryRange.sevenDays.start(now: Self.now, calendar: Self.utc)
        #expect(start == Date(timeIntervalSince1970: 1_792_497_600 - 12 * 3600 - 6 * 86_400))
        #expect(EntryRange.all.start(now: Self.now, calendar: Self.utc) == nil)
        #expect(EntryRange(parsing: "bogus") == .thirtyDays)
        #expect(EntryRange(parsing: nil) == .thirtyDays)
    }

    /// Entries only this device has pin on top in the order they were logged, whatever the
    /// filters; a refused one shows its error.
    @Test func deviceOnlyEntriesPinInOutboxOrderUnfiltered() async throws {
        let w = try await World()
        defer { w.cleanup() }
        let (model, observing) = try await w.model()
        defer { observing.cancel() }

        // Logged first, captured earlier: newest-first would put it second.
        let first = try await w.session.log(
            topic: Self.water, answers: ["glasses": .int(1)], capturedAt: Self.now.addingTimeInterval(-86_400 * 60),
            version: 2)
        let second = try await w.session.log(
            topic: Self.water, answers: ["glasses": .int(2)], capturedAt: Self.now.addingTimeInterval(-60), version: 2)
        try await eventually("both pin") { await MainActor.run { model.pinned.count == 2 } }
        #expect(model.pinned.map(\.id) == [first, second], "logged order, not captured order")
        #expect(model.pinned.allSatisfy { $0.syncState == .pending })
        model.filters = EntryListFilters(range: .sevenDays, version: 1)
        #expect(model.pinned.count == 2, "never filtered")
        #expect(model.rows.allSatisfy { !$0.isLocalOnly })

        // The server refuses the first.
        let store = try #require(w.session.store)
        try await store.writer.write { db in
            try db.execute(
                sql:
                    "UPDATE outbox_item SET state = 'failed', failure_reason = 'rejected', last_error_json = ? WHERE id = ?",
                arguments: [#"{"message":"glasses: too many"}"#, first.wireString])
        }
        w.session.refresh.poke()
        try await eventually("the failure shows") {
            await MainActor.run { model.pinned.first?.syncState == .failed(.rejected) }
        }
        #expect(model.pinned.first?.lastError?.message == "glasses: too many")
    }

    /// An edit to a server entry keeps it in place, marked as waiting; a delete hides it until
    /// Undo brings it back.
    @Test func editsStayInPlaceAndDeletesHideUntilUndone() async throws {
        let w = try await World()
        defer { w.cleanup() }
        let (model, observing) = try await w.model()
        defer { observing.cancel() }

        let two = Self.entries[1].id
        try await w.session.update(
            entryId: two, topicId: Self.topicId, patch: EntryUpdateDTO(answers: ["glasses": .int(9)]))
        try await eventually("the edit shows") {
            await MainActor.run { model.rows.first { $0.id == two }?.syncState == .pending }
        }
        #expect(Self.ids(model.rows) == [4, 2, 3, 5, 7], "in place")
        #expect(model.pinned.isEmpty, "an edit is not pinned")
        #expect(model.rows.first { $0.id == two }?.entry.entry.answers["glasses"] == .int(9))

        try await w.session.delete(entryId: two, topicId: Self.topicId, undoable: true)
        try await eventually("the delete hides it") { await MainActor.run { Self.ids(model.rows) == [4, 3, 5, 7] } }
        #expect(try await w.session.undoDelete(entryId: two) == .restored)
        try await eventually("Undo brings it back") {
            await MainActor.run { Self.ids(model.rows) == [4, 2, 3, 5, 7] }
        }
    }

    /// A rebind starts over, and the old store's late values are dropped: here the other server's
    /// store doesn't have the topic.
    @Test func aRebindStartsOverAndDropsTheOldObservation() async throws {
        let w = try await World()
        defer { w.cleanup() }
        let (model, first) = try await w.model()
        defer { first.cancel() }
        let old = try #require(w.session.store)

        _ = try await w.partitions.createStore(serverId: "t", baseURL: "https://other.example")
        try await w.partitions.registry.setActive("t")
        await w.session.rebind()
        let second = Task { await model.observe() }
        defer { second.cancel() }
        try await eventually("the new store is read") { await MainActor.run { model.phase == .missing } }
        #expect(model.rows.isEmpty && model.pinned.isEmpty && model.sources.isEmpty)

        try await old.writer.write { db in _ = try ServerLayer.upsert(db, entry: Self.entry(9, daysAgo: 0.1)) }
        try await Task.sleep(for: .milliseconds(300))  // settle: an emission takes milliseconds
        #expect(model.rows.isEmpty, "the old store's change doesn't land")
        #expect(model.phase == .missing)
    }

    /// A link opened before the first sync: "Topic not found" until the topic arrives, then the
    /// list, without starting over.
    @Test func aTopicThatArrivesLaterShowsUp() async throws {
        let w = try await World(seeded: false)
        defer { w.cleanup() }
        let model = EntriesModel(session: w.session, topicRef: "water", now: Self.now, calendar: Self.utc)
        let observing = Task { await model.observe() }
        defer { observing.cancel() }
        try await eventually("the topic list is read") { await MainActor.run { model.phase == .missing } }

        // The first sync brings it, through the session's own store.
        try await Self.seed(try #require(w.session.store))
        try await eventually("the list appears") { await MainActor.run { model.phase == .ready } }
        #expect(Self.ids(model.rows) == [4, 2, 3, 5, 7])
        #expect(model.columns.map(\.key) == ["glasses", "mood", "note"])
    }

    /// The rows keep the binding of the store they came from: after a rebind, until the
    /// observation restarts, a write on a row on screen targets the old store (and is refused).
    @Test func theRowsKeepTheirStoresBinding() async throws {
        let w = try await World()
        defer { w.cleanup() }
        let (model, first) = try await w.model()
        defer { first.cancel() }
        let a = try #require(w.session.binding)
        #expect(model.binding == a)
        let oldRow = try #require(model.rows.first)
        #expect(oldRow.binding == a)

        _ = try await w.partitions.createStore(serverId: "t", baseURL: "https://other.example")
        try await w.partitions.registry.setActive("t")
        await w.session.rebind()
        #expect(w.session.binding != a)
        #expect(model.binding == a, "the rows on screen are still A's")
        #expect(!model.rows.isEmpty)

        // Restarted on the new binding: B's, with A's rows gone.
        let second = Task { await model.observe() }
        defer { second.cancel() }
        try await eventually("the observation restarts") {
            await MainActor.run { model.binding == w.session.binding && model.rows.isEmpty }
        }
        #expect(oldRow.binding == a, "a rendered row keeps the binding it was read under")
    }

    @Test func aTopicByIdAndAMissingOne() async throws {
        let w = try await World()
        defer { w.cleanup() }
        let (byId, a) = try await w.model(Self.topicId.uuidString.lowercased())
        defer { a.cancel() }
        #expect(byId.phase == .ready && byId.rows.count == 5)
        let (missing, b) = try await w.model("nope")
        defer { b.cancel() }
        #expect(missing.phase == .missing)
    }

    // MARK: - Summary and timing chip (content-display.md §3.1)

    nonisolated static let runId = UUID(uuidString: "00000000-0000-4000-8000-0000000000bb")!
    /// Optional, so a stop ends the run (no finishing step) and its entry is projected at once.
    nonisolated static let effort = Question(
        key: "effort", label: "Effort", required: false, kind: .int(.init(min: 0)))
    /// A lap timer.
    nonisolated static let laps = TopicTimer(steps: [])

    nonisolated static func lap(_ n: Int, _ start: Int, _ end: Int) -> RunSegment {
        RunSegment(
            kind: .lap, step: nil, label: "Lap \(n)", startedAt: start, endedAt: end, activeMs: end - start, pausedMs: 0
        )
    }

    /// A timed topic "run": a timed entry (3 laps, 12:40 active) and an untimed one.
    nonisolated static func seedTimed(_ store: LocalStore) async throws {
        let run = Topic(
            id: runId, slug: "run", name: "Run", currentVersion: 1, revision: 1, questionCount: 1,
            createdAt: now.addingTimeInterval(-86_400 * 100), updatedAt: now.addingTimeInterval(-86_400 * 100),
            timer: laps, questions: [effort])
        let start = RunInstant.milliseconds(now.addingTimeInterval(-3_600))
        let timing = Timing(
            startedAt: start, endedAt: start + 780_000, activeMs: 760_000, pausedMs: 20_000, complete: true,
            edited: false,
            segments: [
                lap(1, start, start + 200_000), lap(2, start + 200_000, start + 520_000),
                lap(3, start + 520_000, start + 780_000),
            ],
            skipped: [], pauses: [RunPause(start: start + 300_000, end: start + 320_000)])
        @Sendable func entry(_ n: Int, effort: Int, timing: Timing?) -> Entry {
            let at = timing.map { RunInstant.date($0.endedAt) } ?? now.addingTimeInterval(-7_200)
            return Entry(
                id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!, topicId: runId, version: 1,
                revision: 1, source: "ios", channel: .ios, capturedAt: at, createdAt: at, updatedAt: at,
                answers: ["effort": .int(effort)], timing: timing)
        }
        try await store.writer.write { db in
            _ = try ServerLayer.upsert(db, topic: run)
            _ = try ServerLayer.insert(
                db, version: TopicVersion(version: 1, questions: [effort], timer: laps, createdAt: now), id: UUID(),
                topicId: runId)
            _ = try ServerLayer.upsert(db, entry: entry(21, effort: 7, timing: timing))
            _ = try ServerLayer.upsert(db, entry: entry(22, effort: 4, timing: nil))
        }
    }

    /// Each row carries its summary line and, when timed, its chip; a queued run's entry (pinned,
    /// pending) has the same chip; an untimed entry of a timed topic has none.
    @Test func rowsCarryTheSummaryAndTheTimingChip() async throws {
        let w = try await World()
        defer { w.cleanup() }
        let store = try #require(w.session.store)
        try await Self.seedTimed(store)
        let (model, observing) = try await w.model("run")
        defer { observing.cancel() }

        #expect(Self.ids(model.rows) == [21, 22])
        let timed = try #require(model.rows.first)
        #expect(timed.summary == "12:40 · 3 laps · Effort: 7")
        #expect(
            timed.timing
                == EntryTimingModel.Chip(text: "12:40 · 3 laps", accessibilityLabel: "12 minutes 40 seconds, 3 laps"))
        let untimed = try #require(model.rows.last)
        #expect(untimed.summary == "Effort: 4")
        #expect(untimed.timing == nil, "an untimed entry of a timed topic has no chip")

        // A run stopped here, not yet sent: its entry pins, pending, with the same chip.
        let clock = Mutex(RunInstant.milliseconds(Self.now.addingTimeInterval(-600)))
        let writes = RunWrites(store: store, origin: .app, now: { clock.withLock { $0 } })
        let started = try await writes.start(topic: TopicRef(id: Self.runId, slug: "run", name: "Run"), version: 1)
        clock.withLock { $0 += 60_000 }
        _ = try await writes.lap(runId: started.runId)
        clock.withLock { $0 += 75_000 }
        _ = try await writes.stop(runId: started.runId)
        w.session.refresh.poke()
        try await eventually("the run's entry pins") { await MainActor.run { model.pinned.count == 1 } }
        let pending = try #require(model.pinned.first)
        #expect(pending.syncState == .pending)
        #expect(pending.summary == "2:15 · 2 laps", "no answers yet: the timing part alone")
        #expect(
            pending.timing
                == EntryTimingModel.Chip(text: "2:15 · 2 laps", accessibilityLabel: "2 minutes 15 seconds, 2 laps"))
    }

    /// The summary uses the entry's own version's questions: an answer only an older version
    /// asked is labelled from that version.
    @Test func theSummaryUsesTheEntrysVersion() async throws {
        let w = try await World()
        defer { w.cleanup() }
        let (model, observing) = try await w.model()
        defer { observing.cancel() }

        model.filters.range = .all
        #expect(model.rows.first { $0.id == Self.entries[5].id }?.summary == "Note: old")
        #expect(model.rows.first { $0.id == Self.entries[0].id }?.summary == "Glasses: 3 glasses")
        #expect(model.rows.allSatisfy { $0.timing == nil })
    }

    @Test func withoutAServer() async throws {
        let w = try await World(active: false)
        defer { w.cleanup() }
        let model = EntriesModel(session: w.session, topicRef: "water", now: Self.now)
        await model.observe()
        #expect(model.phase == .noServer)
    }
}
