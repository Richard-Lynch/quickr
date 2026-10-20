import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport
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

        init(active: Bool = true) async throws {
            root = URL.temporaryDirectory.appending(path: "quickr-entries-\(UUID().uuidString)")
            let location = StoreLocation(root: root)
            partitions = try StorePartitions.open(at: location, notifier: nil)
            let store = try await partitions.createStore(serverId: "s", baseURL: "https://quickr.example")
            if active { try await partitions.registry.setActive("s") }
            try await EntriesModelTests.seed(store)
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
            try await eventually("the entries are read") { await MainActor.run { model.loaded } }
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

    static func ids(_ entries: [ViewEntry]) -> [Int] {
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

        let first = try await w.session.log(
            topic: Self.water, answers: ["glasses": .int(1)], capturedAt: Self.now.addingTimeInterval(-60), version: 2)
        let second = try await w.session.log(
            topic: Self.water, answers: ["glasses": .int(2)], capturedAt: Self.now.addingTimeInterval(-86_400 * 60),
            version: 2)
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
        #expect(model.rows.first { $0.id == two }?.entry.answers["glasses"] == .int(9))

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
        try await eventually("the new store is read") { await MainActor.run { model.loaded } }
        #expect(model.phase == .missing)
        #expect(model.rows.isEmpty && model.pinned.isEmpty && model.sources.isEmpty)

        try await old.writer.write { db in _ = try ServerLayer.upsert(db, entry: Self.entry(9, daysAgo: 0.1)) }
        try await Task.sleep(for: .milliseconds(300))  // settle: an emission takes milliseconds
        #expect(model.rows.isEmpty, "the old store's change doesn't land")
        #expect(model.phase == .missing)
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

    @Test func withoutAServer() async throws {
        let w = try await World(active: false)
        defer { w.cleanup() }
        let model = EntriesModel(session: w.session, topicRef: "water", now: Self.now)
        await model.observe()
        #expect(model.phase == .noServer)
    }
}
