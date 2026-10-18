import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport
import Synchronization
import Testing

/// `AppSession`, the app's composition root, over the simulated server (`FakeFeedServer` serves
/// the feed and accepts logs): open, connect, a known server at a new URL, a server switch, a
/// reset, another process's registry change, the scene-phase hooks, and teardown.
private let url2 = URL(string: "https://quickr.example.net")!
private let otherServerURL = URL(string: "https://other.example")!

@MainActor
@Suite struct AppSessionTests {

    /// A device (`SyncEnv`) whose transport also accepts logs, and a session over its files.
    struct World {
        let env: SyncEnv
        let notifications = NotificationCenter()
        let other: FakeFeedServer

        init() throws {
            env = try SyncEnv()
            other = try FakeFeedServer()
            other.serverId = "00000000-0000-4000-8000-0000000000bb"
            // FakeTransport answers with the first matching stub: the other server first, then logs
            // and deletes, then the default feed (on any other host).
            let (server, other) = (env.server, other)
            env.transport.reset()
            env.transport.stub(
                where: { $0.url.host == otherServerURL.host && $0.url.path == "/api/v1/changes" },
                { try other.respond($0) })
            env.transport.stub(where: { $0.method == .post }, { try server.respondToCreate($0) })
            env.transport.stub(
                where: { $0.method == .delete },
                { _ in
                    let snapshot = server.snapshot()
                    return HTTPResponse(
                        status: 204,
                        headers: [QuickrHeader.serverId: server.serverId, QuickrHeader.epoch: snapshot.epoch],
                        body: Data())
                })
            env.transport.stub(where: { $0.url.path == "/api/v1/changes" }, { try server.respond($0) })
        }

        @MainActor func session(transport: (any Transport)? = nil) throws -> AppSession {
            var coordinator = SyncCoordinator.Configuration()
            coordinator.autoRetry = false
            coordinator.jitter = { 0 }
            return try AppSession(
                configuration: .init(
                    location: StoreLocation(root: env.dir.url), transport: transport ?? env.transport,
                    notifier: env.notifier,
                    leaseClock: env.clock, wallClock: env.wall, coordinator: coordinator,
                    notificationCenter: notifications))
        }

        func posted(_ name: Notification.Name) -> Counter {
            let counter = Counter()
            notifications.addObserver(forName: name, object: nil, queue: nil) { _ in counter.increment() }
            return counter
        }
    }

    final class Counter: Sendable {
        private let value = Mutex(0)
        func increment() { value.withLock { $0 += 1 } }
        var count: Int { value.withLock { $0 } }
    }

    @Test func withoutAServerItWaitsForOnboarding() async throws {
        let w = try World()
        defer { w.env.cleanup() }
        let session = try w.session()
        await session.start()
        #expect(session.phase == .noServer)
        #expect(session.store == nil && session.outbox == nil && session.binding == nil)
        await #expect(throws: AppSession.SessionError.noStore) {
            try await session.log(topic: Payloads.water, answers: ["glasses": .int(1)], version: 1)
        }
        await session.shutdown()
    }

    @Test func startConnectsToTheConfiguredServerAndBinds() async throws {
        let w = try World()
        defer { w.env.cleanup() }
        let session = try w.session()
        await session.start(serverURL: SyncEnv.baseURL)
        #expect(session.phase == .ready)
        #expect(session.binding?.serverId == FakeFeedServer.defaultServerId)
        #expect(session.binding?.baseURL == SyncEnv.baseURL && session.binding?.storeGen == 1)
        #expect(session.scheduler != nil && session.store?.serverId == FakeFeedServer.defaultServerId)
        #expect(try await session.topics.topics().map(\.topic.id.wireString).contains(FakeFeedServer.water))
        // A second start is a no-op; a relaunch binds the same store without connecting again.
        await session.start(serverURL: SyncEnv.baseURL)
        await session.shutdown()
        let relaunch = try w.session()
        await relaunch.start()
        #expect(relaunch.phase == .ready && relaunch.binding == session.binding ?? relaunch.binding)
        await relaunch.shutdown()
    }

    @Test func aLogIsEnqueuedFlushedAndPulledBack() async throws {
        let w = try World()
        defer { w.env.cleanup() }
        let session = try w.session()
        await session.start(serverURL: SyncEnv.baseURL)
        let store = try #require(session.store)

        let id = try await session.log(topic: Payloads.water, answers: ["glasses": .int(3)], version: 1)
        #expect(try await store.entries.entry(id: id) != nil, "visible at once (overlay)")
        try await eventually("the log is flushed") { try await store.outbox.items().isEmpty }
        #expect(w.env.server.liveEntries()[id.wireString] == 1)
        let post = try #require(w.env.transport.requests.last { $0.method == .post })
        #expect(post.url.host == SyncEnv.baseURL.host && post.url.path.hasSuffix("/entries"))

        #expect(await session.coordinator.sync(reason: .requested) == .synced)
        #expect(try await store.entries.entry(id: id)?.syncState == .synced)
        await session.shutdown()
    }

    @Test func aKnownServerAtANewURLGetsANewSender() async throws {
        let w = try World()
        defer { w.env.cleanup() }
        let session = try w.session()
        await session.start(serverURL: SyncEnv.baseURL)
        let before = try #require(session.scheduler)

        let result = await session.connect(baseURL: url2)
        guard case .connected(_, isNew: false, .synced) = result else {
            Issue.record("connect: \(result)")
            return
        }
        #expect(session.binding?.baseURL == url2)
        let after = try #require(session.scheduler)
        #expect(after !== before)
        #expect(await before.isRetired)
        #expect(await !after.isRetired)
        let id = try await session.log(topic: Payloads.water, answers: ["glasses": .int(1)], version: 1)
        try await eventually("the log is flushed") { try await session.store?.outbox.items().isEmpty == true }
        let post = try #require(w.env.transport.requests.last { $0.method == .post })
        #expect(post.url.host == url2.host, "the sender follows the new URL")
        #expect(w.env.server.liveEntries()[id.wireString] == 1)
        await session.shutdown()
    }

    @Test func switchingServersRebindsToTheOtherStore() async throws {
        let w = try World()
        defer { w.env.cleanup() }
        let session = try w.session()
        await session.start(serverURL: SyncEnv.baseURL)
        let first = try #require(session.scheduler)

        _ = await session.connect(baseURL: otherServerURL)
        #expect(session.binding?.serverId == w.other.serverId)
        #expect(session.store?.serverId == w.other.serverId)
        #expect(await first.isRetired)
        // And back: the first server's store, bound again.
        _ = await session.connect(baseURL: SyncEnv.baseURL)
        #expect(session.binding?.serverId == FakeFeedServer.defaultServerId)
        await session.shutdown()
    }

    @Test func aResetRebindsToTheNewGeneration() async throws {
        let w = try World()
        defer { w.env.cleanup() }
        let session = try w.session()
        await session.start(serverURL: SyncEnv.baseURL)
        let before = try #require(session.scheduler)

        let warning = try #require(try await session.coordinator.resetWarning())
        _ = try await session.coordinator.performReset(confirmed: warning)
        try await eventually("the session follows the reset") { await MainActor.run { session.binding?.storeGen == 2 } }
        #expect(session.store?.storeGen == 2)
        #expect(await before.isRetired)
        await session.shutdown()
    }

    @Test func anotherProcessDeselectingTheServerUnbinds() async throws {
        let w = try World()
        defer { w.env.cleanup() }
        let session = try w.session()
        await session.start(serverURL: SyncEnv.baseURL)
        let before = try #require(session.scheduler)

        try await w.env.otherProcess().registry.setActive(nil)  // posts registry-changed
        try await eventually("the session unbinds") { await MainActor.run { session.phase == .noServer } }
        #expect(session.store == nil && session.binding == nil)
        #expect(await before.isRetired)
        await session.shutdown()
    }

    @Test func scenePhaseHooksFlushSyncAndSuspend() async throws {
        let w = try World()
        defer { w.env.cleanup() }
        let suspended = w.posted(Database.suspendNotification)
        let resumed = w.posted(Database.resumeNotification)
        let session = try w.session()
        await session.start(serverURL: SyncEnv.baseURL)
        let scheduler = try #require(session.scheduler)

        // Background: a held delete is released and sent, then GRDB is suspended.
        let id = try await session.log(topic: Payloads.water, answers: ["glasses": .int(1)], version: 1)
        _ = await scheduler.waitUntilIdle()
        try await session.delete(entryId: id, topicId: UUID(uuidString: FakeFeedServer.water)!, undoable: true)
        _ = await session.didEnterBackground()
        #expect(await scheduler.started.contains(OutboxFlushReason.background.policy))
        #expect(w.env.transport.requests.contains { $0.method == .delete })
        #expect(suspended.count == 1)

        // Foreground: resume, flush (activation) and pull.
        let pulls = w.env.afters().count
        let flushes = await scheduler.started.count
        await session.didBecomeActive()
        #expect(resumed.count == 1)
        // A forced flush with activation's lease wait (merged into a follow-up if one was running).
        try await eventually("activation flushes") {
            await scheduler.started.dropFirst(flushes).contains { $0.force && $0.leaseWait >= .seconds(30) }
        }
        try await eventually("activation pulls") { w.env.afters().count > pulls }

        await session.backgroundTimeExpiring()
        #expect(suspended.count == 2)
        await session.shutdown()
    }

    @Test func expiryWaitsForTheCancelledFlushBeforeSuspending() async throws {
        let w = try World()
        defer { w.env.cleanup() }
        let gate = Gate()
        let session = try w.session(transport: GatedTransport(w.env.transport, gate) { $0.method == .post })
        await session.start(serverURL: SyncEnv.baseURL)
        let store = try #require(session.store)
        let scheduler = try #require(session.scheduler)
        // When suspend is posted, the flush must have ended and released its lease.
        let leaseFreeAtSuspend = Mutex<Bool?>(nil)
        w.notifications.addObserver(forName: Database.suspendNotification, object: nil, queue: nil) { _ in
            let free = (try? store.writer.read { db in try LeaseTable.record(db, .flush).owner == nil }) ?? false
            leaseFreeAtSuspend.withLock { $0 = free }
        }

        _ = try await session.log(topic: Payloads.water, answers: ["glasses": .int(1)], version: 1)
        await gate.arrival()  // the POST is in flight
        await session.backgroundTimeExpiring(within: .seconds(10))
        #expect(leaseFreeAtSuspend.withLock { $0 } == true)
        #expect(await scheduler.lastReport?.ending == .cancelled)
        // Paused until activation: a pull's flush request starts nothing.
        let started = await scheduler.started.count
        _ = await session.coordinator.sync(reason: .requested)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await scheduler.started.count == started)
        #expect(await scheduler.isPaused)
        await session.didBecomeActive()
        #expect(await !scheduler.isPaused)
        gate.releaseAll()
        await session.shutdown()
    }

    @Test func expiryIsBoundedByTheRemainingTime() async throws {
        let w = try World()
        defer { w.env.cleanup() }
        let gate = Gate()
        let suspended = w.posted(Database.suspendNotification)
        let session = try w.session(
            transport: GatedTransport(w.env.transport, gate) { $0.url.path == "/api/v1/changes" && gate.armed })
        await session.start(serverURL: SyncEnv.baseURL)
        gate.arm()
        let pull = Task { await session.coordinator.sync(reason: .requested) }
        await gate.arrival()  // a pull is parked and won't end

        let started = ContinuousClock.now
        await session.backgroundTimeExpiring(within: .milliseconds(300))
        #expect(ContinuousClock.now - started < .seconds(10), "returned at the bound, not when the pull ends")
        #expect(suspended.count == 1)
        gate.releaseAll()
        _ = await pull.value
        await session.shutdown()
    }

    @Test func theReadOnlyTopicsNeverCreateAStoreFile() async throws {
        let w = try World()
        defer { w.env.cleanup() }
        // Registered and active, but its file isn't there yet (onboarding in another process).
        _ = try await w.env.partitions.registry.register(
            serverId: "s-new", baseURL: "https://new.example", now: Make.t0)
        try await w.env.partitions.registry.setActive("s-new")
        let topics = ActiveStoreTopicRepository(partitions: try w.env.otherProcess())
        #expect(try await topics.topics().isEmpty)
        let server = try #require(try await w.env.partitions.registry.repository.server(id: "s-new"))
        let file = StoreLocation(root: w.env.dir.url).storeURL(for: server)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        // No active server at all: empty too.
        try await w.env.partitions.registry.setActive(nil)
        #expect(try await topics.topics().isEmpty)
    }

    @Test func aShutDownSessionIsFreed() async throws {
        let w = try World()
        defer { w.env.cleanup() }
        let refs = WeakRefs()
        do {
            let session = try w.session()
            await session.start(serverURL: SyncEnv.baseURL)
            _ = try await session.log(topic: Payloads.water, answers: ["glasses": .int(1)], version: 1)
            _ = await session.scheduler?.waitUntilIdle()
            await session.didBecomeActive()
            await session.shutdown()
            refs.session = session
            refs.coordinator = session.coordinator
            refs.scheduler = session.scheduler
        }
        try await eventually("the session is freed") {
            refs.session == nil && refs.coordinator == nil
        }
    }
}

private final class WeakRefs: @unchecked Sendable {
    weak var session: AppSession?
    weak var coordinator: SyncCoordinator?
    weak var scheduler: OutboxFlushScheduler?
}

/// Parks the requests `matches` selects at `gate` (until it opens), then sends them on.
private final class GatedTransport: Transport {
    private let inner: any Transport
    private let gate: Gate
    private let matches: @Sendable (HTTPRequest) -> Bool

    init(_ inner: any Transport, _ gate: Gate, matches: @escaping @Sendable (HTTPRequest) -> Bool) {
        self.inner = inner
        self.gate = gate
        self.matches = matches
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if matches(request) { await gate.arrive() }
        return try await inner.send(request)
    }
}

extension Gate {
    private static let armedGates = Mutex<Set<ObjectIdentifier>>([])

    /// Whether `arm()` was called: lets a gate let earlier requests through.
    var armed: Bool { Self.armedGates.withLock { $0.contains(ObjectIdentifier(self)) } }

    func arm() { _ = Self.armedGates.withLock { $0.insert(ObjectIdentifier(self)) } }
}
