import Foundation
import QuickrCore
import QuickrTestSupport
import Testing

@testable import QuickrData

/// Links keep their server (notifications.md §7.5): servers A and B both have a topic with the
/// slug `mood`, as different topics. B is active. A reminder from A (its body, its "More…") and a
/// widget cached from A's store name A's topic by id and are refused while B is active, never
/// opened on B's `mood`. While A is active they open A's topic.
@Suite(.timeLimit(.minutes(2))) struct LinkScopeTests {
    static let serverA = "0b9e0000-0000-4000-8000-0000000000aa"
    static let serverB = "0b9e0000-0000-4000-8000-0000000000bb"
    static let dueSince = "2026-03-04T11:00:00Z"

    final class World: Sendable {
        let dir: TempDirectory
        let partitions: StorePartitions
        let moodA: Topic
        let moodB: Topic
        let stores: [String: LocalStore]

        init() async throws {
            dir = try TempDirectory()
            partitions = try StorePartitions.open(at: StoreLocation(root: dir.url), notifier: nil)
            var moodA = Make.topic(name: "Mood")
            moodA.questions = [Self.mood(6)]
            var moodB = Make.topic(name: "Mood")  // another topic, the same slug
            moodB.questions = [Self.mood(2)]
            #expect(moodA.slug == moodB.slug && moodA.id != moodB.id)
            (self.moodA, self.moodB) = (moodA, moodB)
            var stores: [String: LocalStore] = [:]
            for (serverId, topic) in [(LinkScopeTests.serverA, moodA), (LinkScopeTests.serverB, moodB)] {
                let store = try await partitions.createStore(
                    serverId: serverId, baseURL: "https://\(serverId.suffix(2)).example")
                try await store.writer.write { db in
                    try db.execute(sql: "UPDATE sync_state SET epoch = 'E1', bootstrap_complete = 1")
                    _ = try ServerLayer.upsert(db, topic: topic)
                }
                stores[serverId] = store
            }
            self.stores = stores
            try await partitions.registry.setActive(LinkScopeTests.serverB)
        }

        deinit { dir.cleanup() }

        static func mood(_ n: Int) -> Question {
            Question(
                key: "mood", label: "Mood",
                kind: .choice(.init(options: (0..<n).map { EnumOption(value: "o\($0)", label: "O\($0)") })))
        }

        var handler: NotificationActionHandler {
            NotificationActionHandler(
                partitions: partitions, center: FakeNotificationCenter(), sender: { _ in nil }, owner: "app:test",
                wallClock: FakeClock(), isProtectedDataAvailable: { true }, reloadWidgets: {})
        }

        /// A's reminder for its `mood`, as the server builds it (`url` by slug).
        var reminderFromA: (info: QuickrNotificationInfo, category: NotificationCategory) {
            let descriptor = NotificationCategory.descriptor(questions: moodA.questions, counts: [:], last: nil)!
            let category = NotificationCategory(
                serverId: LinkScopeTests.serverA, topicId: moodA.id.wireString, version: 1, descriptor: descriptor)
            let info = QuickrNotificationInfo(
                kind: "due", serverId: LinkScopeTests.serverA, topicId: moodA.id.wireString, topicSlug: moodA.slug,
                version: 1, dueSince: LinkScopeTests.dueSince, url: "/t/\(moodA.slug)/record", quickLog: descriptor)
            return (info, category)
        }

        func scope(_ serverId: String) -> EntryScope { stores[serverId]!.scope }

        /// The check with `active` bound, the registry agreeing (unless `registry` says otherwise).
        func check(
            _ serverId: String, storeGen: Int? = nil, active: EntryScope?, registry: String?? = .none
        ) async throws -> LinkScope.Check {
            let registryActive = registry ?? active?.serverId
            if let registryActive { try await partitions.registry.setActive(registryActive) }
            return await LinkScope.check(
                serverId: serverId, storeGen: storeGen, active: active, registry: partitions.registry)
        }
    }

    /// The outcome's path names A's topic by id: the route the app would show.
    static func route(_ outcome: NotificationActionOutcome) throws -> (route: Route, serverId: String) {
        guard case .open(let path, let serverId, _) = outcome else {
            Issue.record("not an open: \(outcome)")
            throw CancellationError()
        }
        let routes = try #require(DeepLink.routes(forPath: path))
        return (try #require(routes.first), serverId)
    }

    @Test func aReminderBodyFromAnotherServerIsRefusedNotOpenedOnItsSameSlugTopic() async throws {
        let w = try await World()
        let outcome = await w.handler.handle(.init(action: .open, quickr: w.reminderFromA.info))
        let (route, serverId) = try Self.route(outcome)
        #expect(serverId == Self.serverA)
        #expect(route == .record(TopicLinkRef(id: w.moodA.id)), "A's topic by id, not `mood`")
        #expect(route.topic?.id != w.moodB.id)
        #expect(try await w.check(serverId, active: w.scope(Self.serverB)) == .otherServer(name: "aa.example"))
        // With A active it opens A's topic.
        #expect(try await w.check(serverId, active: w.scope(Self.serverA)) == .open)
    }

    @Test func moreFromAnotherServerIsRefusedToo() async throws {
        let w = try await World()
        let reminder = w.reminderFromA
        #expect(reminder.category.actions.last?.kind == "open")
        let outcome = await w.handler.handle(
            .init(action: .custom(reminder.category.actions[3].identifier), quickr: reminder.info))
        let (route, serverId) = try Self.route(outcome)
        #expect(route == .record(TopicLinkRef(id: w.moodA.id)))
        #expect(serverId == Self.serverA)
        #expect(try await w.check(serverId, active: w.scope(Self.serverB)) == .otherServer(name: "aa.example"))
    }

    /// A tap-to-fix's text carries its server, so the app hands it only to that server's topic.
    @Test func aTapToFixsPrefillCarriesItsServer() async throws {
        let w = try await World()
        var info = w.reminderFromA.info
        info.kind = "fix"
        info.prefill = ["mood": "abc"]
        let outcome = await w.handler.handle(.init(action: .open, quickr: info))
        guard case .open(_, _, let prefill?) = outcome else {
            Issue.record("no prefill: \(outcome)")
            return
        }
        #expect(
            prefill
                == NotificationPrefill(serverId: Self.serverA, topicId: w.moodA.id.wireString, texts: ["mood": "abc"]))
    }

    @Test func aWidgetCachedFromAnotherServerIsRefused() async throws {
        let w = try await World()
        // The widget was rendered while A was active.
        let shown = try #require(try await WidgetReader(store: w.stores[Self.serverA]!).topic(id: w.moodA.id))
        let link = try #require(DeepLink.link(for: shown.recordURL))
        let scope = try #require(link.scope)
        #expect(link.routes == [.record(TopicLinkRef(id: w.moodA.id))], "by id, not `mood`")
        #expect(scope == w.scope(Self.serverA))
        // B active: refused.
        #expect(
            try await w.check(scope.serverId, storeGen: scope.storeGen, active: w.scope(Self.serverB))
                == .otherServer(name: "aa.example"))
        // A active again: opens.
        #expect(try await w.check(scope.serverId, storeGen: scope.storeGen, active: w.scope(Self.serverA)) == .open)
        // A reset since (a new store generation): stale, the widget refreshes.
        #expect(
            try await w.check(
                scope.serverId, storeGen: scope.storeGen, active: EntryScope(serverId: Self.serverA, storeGen: 2))
                == .stale)
        // A server quickR doesn't have any more: stale.
        #expect(
            try await w.check("0b9e0000-0000-4000-8000-0000000000cc", storeGen: 1, active: w.scope(Self.serverB))
                == .stale)
    }

    @Test func refusalsSayWhy() {
        #expect(LinkScope.message(.open) == nil)
        #expect(LinkScope.message(.otherServer(name: "aa.example"))?.contains("aa.example") == true)
        #expect(LinkScope.message(.stale) != nil)
    }

    /// Mid-switch the registry already names one server while the bound store is still the
    /// other's: the app asks again rather than trust either.
    @Test func aSwitchInProgressIsBusy() async throws {
        let w = try await World()
        #expect(
            try await w.check(Self.serverA, active: w.scope(Self.serverB), registry: .some(Self.serverA)) == .busy)
        #expect(try await w.check(Self.serverA, active: nil, registry: .some(Self.serverB)) == .busy)
        #expect(LinkScope.message(.busy) != nil)
    }

    // MARK: - Opening against the binding as it is when the route is set

    /// The bound store the closure reports, call by call (the last repeats).
    @MainActor final class Bindings {
        var sequence: [EntryScope?]
        var calls = 0
        init(_ sequence: [EntryScope?]) { self.sequence = sequence }
        func next() -> EntryScope? {
            defer { calls += 1 }
            return sequence[min(calls, sequence.count - 1)]
        }
    }

    /// A switch to A finishing during the first check: asked again, then opened once.
    @MainActor @Test func aSwitchFinishingDuringTheCheckIsCheckedAgainThenOpens() async throws {
        let w = try await World()
        try await w.partitions.registry.setActive(Self.serverA)  // the registry has switched...
        let bindings = Bindings([w.scope(Self.serverB), w.scope(Self.serverA)])  // ...the binding follows
        var opened = 0
        let result = await LinkScope.open(
            serverId: Self.serverA, storeGen: nil, binding: bindings.next, registry: w.partitions.registry,
            attempts: 5, pause: .zero
        ) { opened += 1 }
        #expect(result == .open && opened == 1)
    }

    /// The binding changes between the check and the route (a switch to B): not opened on B.
    @MainActor @Test func aBindingThatChangesAfterTheCheckIsNotRoutedTo() async throws {
        let w = try await World()
        try await w.partitions.registry.setActive(Self.serverA)
        // Checked with A bound (open), but B is bound by the time the route would be set.
        let bindings = Bindings([w.scope(Self.serverA), w.scope(Self.serverB)])
        var opened = 0
        let result = await LinkScope.open(
            serverId: Self.serverA, storeGen: nil, binding: bindings.next, registry: w.partitions.registry,
            attempts: 3, pause: .zero
        ) { opened += 1 }
        #expect(opened == 0)
        #expect(result == .busy, "the registry (A) and the binding (B) never agree again")
    }

    /// A switch that never settles gives up as busy, without opening.
    @MainActor @Test func aSwitchThatNeverSettlesIsBusy() async throws {
        let w = try await World()  // the registry says B
        var opened = 0
        let alwaysA: @MainActor () -> EntryScope? = { [w] in w.scope(Self.serverA) }
        let result = await LinkScope.open(
            serverId: Self.serverB, storeGen: nil, binding: alwaysA, registry: w.partitions.registry, attempts: 3,
            pause: .zero
        ) { opened += 1 }
        #expect(result == .busy && opened == 0)
    }
}
