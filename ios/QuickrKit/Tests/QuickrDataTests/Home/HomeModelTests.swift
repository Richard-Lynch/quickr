import Foundation
import QuickrCore
import QuickrData
import QuickrTestSupport
import Synchronization
import Testing

/// `HomeModel` over a real `AppSession` and store (offline: every request fails): it lists what
/// the store holds like `TopicListing`, follows the store, debounces the search and moves with
/// the clock.
@MainActor
@Suite struct HomeModelTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    /// A session over a store seeded with `topics`, started (bound).
    @MainActor struct World {
        let root: URL
        let session: AppSession
        let store: LocalStore
        let partitions: StorePartitions

        /// - Parameter bootstrapped: mark the store's first bootstrap done, as a real sync would.
        init(topics: [Topic], active: Bool = true, bootstrapped: Bool = false) async throws {
            root = URL.temporaryDirectory.appending(path: "quickr-home-\(UUID().uuidString)")
            let location = StoreLocation(root: root)
            let partitions = try StorePartitions.open(at: location, notifier: nil)
            let store = try await partitions.createStore(serverId: "s", baseURL: "https://quickr.example")
            if active { try await partitions.registry.setActive("s") }
            try await HomeModelTests.seed(store, topics)
            if bootstrapped {
                try await store.writer.write { db in try db.execute(sql: "UPDATE sync_state SET bootstrap_complete = 1")
                }
            }
            self.partitions = partitions
            var coordinator = SyncCoordinator.Configuration()
            coordinator.autoRetry = false
            session = try AppSession(
                configuration: .init(location: location, transport: Offline(), coordinator: coordinator))
            await session.start()
            self.store = store
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }

        /// A model observing the store, with the list read at least once.
        func model(debounce: Duration = .zero) async throws -> (HomeModel, Task<Void, Never>) {
            let model = HomeModel(session: session, now: HomeModelTests.now, debounce: debounce)
            let observing = Task { await model.observe() }
            try await eventually("the list is read") { await MainActor.run { model.loaded } }
            return (model, observing)
        }
    }

    /// The topics and, for each one logged, an entry at `lastCapturedAt` (the store derives
    /// `entry_count` and `last_captured_at` from its entries).
    static func seed(_ store: LocalStore, _ topics: [Topic]) async throws {
        try await store.writer.write { db in
            for topic in topics {
                _ = try ServerLayer.upsert(db, topic: topic)
                guard let at = topic.lastCapturedAt else { continue }
                let entry = Entry(
                    id: UUID(), topicId: topic.id, version: 1, revision: 1, source: "test", channel: .ios,
                    capturedAt: at, createdAt: at, updatedAt: at, answers: [:])
                _ = try ServerLayer.upsert(db, entry: entry)
            }
        }
    }

    struct Offline: Transport {
        func send(_ request: HTTPRequest) async throws -> HTTPResponse { throw URLError(.notConnectedToInternet) }
    }

    static func topic(
        _ n: Int, _ name: String, status: TopicStatus = .active, everyMinutes: Int? = nil,
        lastMinutesAgo: Double? = nil,
        questions: [Question] = []
    ) -> Topic {
        let last = lastMinutesAgo.map { now.addingTimeInterval(-$0 * 60) }
        return Topic(
            id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!,
            slug: name.lowercased().replacingOccurrences(of: " ", with: "-"), name: name, status: status,
            currentVersion: 1, revision: 1, questionCount: questions.count, entryCount: last == nil ? 0 : 1,
            lastCapturedAt: last, createdAt: now.addingTimeInterval(-86_400 * 30),
            updatedAt: now.addingTimeInterval(-86_400 * Double(n)),
            schedule: everyMinutes.map { .interval(.init(everyMinutes: $0, timezone: "UTC")) },
            scheduleUpdatedAt: now.addingTimeInterval(-86_400 * 30), questions: questions)
    }

    /// Overdue (due 60 min), due (10 min), soon (in 30 min), unscheduled ×2, archived (and due).
    static let mixed: [Topic] = [
        topic(1, "Meds", everyMinutes: 240, lastMinutesAgo: 300),
        topic(2, "Water", everyMinutes: 120, lastMinutesAgo: 130),
        topic(3, "Stretch", everyMinutes: 180, lastMinutesAgo: 150),
        topic(
            4, "Sleep",
            questions: [
                Question(key: "hours", label: "Hours slept", helpText: "Including naps", kind: .double(.init()))
            ]),
        topic(5, "Mood", lastMinutesAgo: 45),
        topic(6, "Old habit", status: .archived, everyMinutes: 60, lastMinutesAgo: 600),
    ]

    static func names(_ rows: [HomeModel.Row]) -> [String] { rows.map(\.topic.name) }

    @Test func listsTheStoreInSectionsWithTheBadge() async throws {
        let w = try await World(topics: Self.mixed)
        defer { w.cleanup() }
        let (model, observing) = try await w.model()
        defer { observing.cancel() }

        #expect(model.phase == .ready)
        #expect(model.isSectioned)
        #expect(Self.names(model.sections.due) == ["Meds", "Water"], "longest due first")
        #expect(Self.names(model.sections.upcoming) == ["Stretch"])
        #expect(Self.names(model.sections.other) == ["Mood", "Sleep"], "unscheduled by recent activity")
        #expect(Self.names(model.rows) == ["Meds", "Water", "Stretch", "Mood", "Sleep"], "archived is filtered out")
        #expect(model.badgeCount == 2, "the archived topic is never due")
    }

    @Test func theListMatchesTopicListing() async throws {
        let w = try await World(topics: Self.mixed)
        defer { w.cleanup() }
        let (model, observing) = try await w.model()
        defer { observing.cancel() }
        for status in TopicStatusFilter.allCases {
            for sort in TopicSort.allCases {
                model.status = status
                model.sort = sort
                let expected = TopicListing.list(
                    Self.mixed, topic: { $0 }, now: Self.now, status: status, sort: sort, query: "")
                #expect(model.rows.map(\.topic.id) == expected.map(\.topic.id), "\(status) \(sort)")
                #expect(model.isSectioned == (status == .active && sort == .due))
                #expect(model.hasNonDefaultFilter == (status != .active || sort != .due))
            }
        }
    }

    @Test func searchIsDebouncedAndTrimmed() async throws {
        let w = try await World(topics: Self.mixed)
        defer { w.cleanup() }
        let (model, observing) = try await w.model(debounce: .milliseconds(100))
        defer { observing.cancel() }

        model.search = "  NAPS "
        #expect(model.query == "", "not before the debounce")
        #expect(model.rows.count == 5)
        try await eventually("the search applies") { await MainActor.run { model.query == "NAPS" } }
        #expect(Self.names(model.rows) == ["Sleep"], "a question's help text matches, case-insensitively")
        #expect(!model.isSectioned)
        #expect(model.isFiltered)
        #expect(model.badgeCount == 2, "the badge ignores the search")

        // A burst applies once, with the last text.
        model.search = "w"
        model.search = "wa"
        model.search = "wat"
        try await eventually("the last search applies") { await MainActor.run { model.query == "wat" } }
        #expect(Self.names(model.rows) == ["Water"])
        model.search = "   "
        try await eventually("an empty search clears") { await MainActor.run { model.query.isEmpty } }
        #expect(model.isSectioned)
        #expect(!model.isFiltered)
    }

    @Test func theListFollowsTheStore() async throws {
        let w = try await World(topics: Self.mixed)
        defer { w.cleanup() }
        let (model, observing) = try await w.model()
        defer { observing.cancel() }

        let new = Self.topic(7, "Plants", everyMinutes: 30, lastMinutesAgo: 120)  // due 90 min: first
        // Through the session's own store: another pool's write only shows after a refresh poke.
        try await Self.seed(try #require(w.session.store), [new])
        try await eventually("the new topic shows") {
            await MainActor.run { Self.names(model.sections.due) == ["Plants", "Meds", "Water"] }
        }
        #expect(model.badgeCount == 3)
    }

    @Test func theClockMovesTopicsIntoDueNow() async throws {
        let w = try await World(topics: Self.mixed)
        defer { w.cleanup() }
        let (model, observing) = try await w.model()
        defer { observing.cancel() }

        #expect(Self.names(model.sections.upcoming) == ["Stretch"])
        model.tick(Self.now.addingTimeInterval(31 * 60))  // Stretch's slot passes
        #expect(Self.names(model.sections.due) == ["Meds", "Water", "Stretch"])
        #expect(model.sections.upcoming.isEmpty)
        #expect(model.badgeCount == 3)
    }

    @Test func withoutAServerItAsksForOnboarding() async throws {
        let w = try await World(topics: Self.mixed, active: false)
        defer { w.cleanup() }
        let model = HomeModel(session: w.session, now: Self.now, debounce: .zero)
        await model.observe()  // no store: returns at once
        #expect(model.phase == .noServer)
        #expect(model.rows.isEmpty)
    }

    /// Nothing stored, never bootstrapped, and the first sync can't reach the server: "You're
    /// offline", also once the empty store has been read.
    @Test func anEmptyStoreThatNeverSyncedReadsOffline() async throws {
        let w = try await World(topics: [])
        defer { w.cleanup() }
        let model = HomeModel(session: w.session, now: Self.now, debounce: .zero)
        let observing = Task { await model.observe() }
        defer { observing.cancel() }
        try await eventually("the empty list is read") { await MainActor.run { model.loaded } }
        _ = await w.session.coordinator.sync(reason: .requested)  // fails: offline
        try await eventually("the failed sync shows") { await MainActor.run { model.phase == .offline } }
        #expect(model.isOfflineWithoutData)
        #expect(!model.isOnline)
    }

    /// An empty store that did bootstrap is a server with no topics: "Track anything", offline or not.
    @Test func anEmptyBootstrappedStoreReadsTrackAnything() async throws {
        let w = try await World(topics: [], bootstrapped: true)
        defer { w.cleanup() }
        let model = HomeModel(session: w.session, now: Self.now, debounce: .zero)
        let observing = Task { await model.observe() }
        defer { observing.cancel() }
        _ = await w.session.coordinator.sync(reason: .requested)  // fails: offline
        try await eventually("the bootstrap flag is read") {
            await MainActor.run { model.loaded && model.bootstrapped }
        }
        #expect(!model.isOnline)
        #expect(model.phase == .ready)
        #expect(model.rows.isEmpty && !model.isFiltered, "the screen shows \"Track anything\"")
    }

    /// A rebind starts over: the new store's topics and counts only, and the old observation's late
    /// values (it hasn't stopped yet) are dropped. Without a store, everything is empty.
    @Test func aRebindStartsOverAndDropsTheOldObservation() async throws {
        let w = try await World(topics: Self.mixed)
        defer { w.cleanup() }
        let (model, first) = try await w.model()
        defer { first.cancel() }
        _ = try await w.session.log(
            topic: TopicRef(id: Self.mixed[0].id, slug: Self.mixed[0].slug, name: Self.mixed[0].name), answers: [:],
            version: 1)
        try await eventually("the pending log counts") { await MainActor.run { model.pendingCount == 1 } }
        let old = try #require(w.session.store)

        // Switch to another server's store; the first observation keeps running.
        let other = try await w.partitions.createStore(serverId: "t", baseURL: "https://other.example")
        try await Self.seed(other, [Self.topic(11, "Reading", lastMinutesAgo: 10)])
        try await w.partitions.registry.setActive("t")
        await w.session.rebind()
        let second = Task { await model.observe() }
        defer { second.cancel() }
        try await eventually("the new store shows") { await MainActor.run { model.loaded } }
        #expect(Self.names(model.rows) == ["Reading"])
        #expect(model.pendingCount == 0)
        #expect(model.badgeCount == 0)

        // The old store changes: its observation's value must not land.
        try await Self.seed(old, [Self.topic(12, "Stale", lastMinutesAgo: 5)])
        try await Task.sleep(for: .milliseconds(300))  // settle: an emission takes milliseconds
        #expect(Self.names(model.rows) == ["Reading"])

        // No server at all: empty, counts included.
        let reading = Self.topic(11, "Reading")
        _ = try await w.session.log(
            topic: TopicRef(id: reading.id, slug: reading.slug, name: reading.name), answers: [:], version: 1)
        try await eventually("the new store's pending log counts") {
            await MainActor.run { model.pendingCount == 1 }
        }
        try await w.partitions.registry.setActive(nil)
        await w.session.rebind()
        await model.observe()
        #expect(model.topics.isEmpty && model.pendingCount == 0 && model.failedCount == 0)
        #expect(model.phase == .noServer)
    }

    @Test func aRetryRestartsTheObservation() async throws {
        let w = try await World(topics: Self.mixed)
        defer { w.cleanup() }
        let model = HomeModel(session: w.session, now: Self.now, debounce: .zero)
        let before = model.attempt
        await model.retry()
        #expect(model.attempt == before + 1, "the view keys its observing task by `attempt`")
    }
}
