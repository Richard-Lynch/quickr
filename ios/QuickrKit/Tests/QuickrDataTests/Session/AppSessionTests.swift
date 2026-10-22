import Foundation
import GRDB
import QuickrCore
@_spi(Testing) import QuickrData
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

        @MainActor func session(
            transport: (any Transport)? = nil, categoryCenter: (any NotificationCenterProtocol)? = nil
        ) throws -> AppSession {
            var coordinator = SyncCoordinator.Configuration()
            coordinator.autoRetry = false
            coordinator.jitter = { 0 }
            return try AppSession(
                configuration: .init(
                    location: StoreLocation(root: env.dir.url), transport: transport ?? env.transport,
                    notifier: env.notifier,
                    leaseClock: env.clock, wallClock: env.wall, coordinator: coordinator,
                    notificationCenter: notifications, categoryCenter: categoryCenter))
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

    /// notifications.md §5.2 callers: binding registers the store's categories, and so does a sync
    /// that changes data; activation reconciles (§5.3). The NSE may never run (spike F1).
    @Test func theBoundStoresCategoriesAreRegisteredAndReconciledOnActivation() async throws {
        let w = try World()
        defer { w.env.cleanup() }
        let center = FakeNotificationCenter()
        let session = try w.session(categoryCenter: center)
        await session.start(serverURL: SyncEnv.baseURL)
        await session.categoryRefreshSettled()
        let store = try #require(session.store)
        let expected = Set(try await NotificationCategories.rows(in: store, now: Date()).map(\.category.id))
        #expect(!expected.isEmpty, "the fixture has quick-loggable topics")
        #expect(Set(center.withState { $0.categories.map(\.id) }) == expected)

        // A log changes the water topic's last value: a new category after the next sync.
        _ = try await session.log(topic: Payloads.water, answers: ["glasses": .int(4)], version: 1)
        try await eventually("the log is flushed") { try await store.outbox.items().isEmpty }
        #expect(await session.coordinator.sync(reason: .requested) == .synced)
        try await eventually("the new category is registered") {
            await session.categoryRefreshSettled()
            let now = Set(try await NotificationCategories.rows(in: store, now: Date()).map(\.category.id))
            return !now.isSubset(of: expected) && Set(center.withState { $0.categories.map(\.id) }).isSuperset(of: now)
        }

        // The system lost them (a reboot): activation re-registers the union.
        center.withState { $0.categories = [] }
        await session.didBecomeActive()
        try await eventually("reconciled") { !center.withState { $0.categories }.isEmpty }
        let table = Set(try await session.partitions.registry.repository.notificationCategories().map(\.id))
        #expect(Set(center.withState { $0.categories.map(\.id) }) == table)
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

    /// The notification handler's gate (notifications.md §7.1 steps 8, 10): the bound store while
    /// the registry agrees; nothing during a switch or before the first bind; the registry's only
    /// for a session that never started.
    @Test func activeScopeIsTheBoundStoreAndNothingDuringASwitch() async throws {
        let w = try World()
        defer { w.env.cleanup() }
        let session = try w.session()
        await session.start(serverURL: SyncEnv.baseURL)
        let scope = try #require(session.binding?.scope)
        #expect(await session.activeScope() == scope)

        // A switch to the other server, held before its bind: the registry has moved, the binding
        // not yet. Neither store counts as active.
        let gate = Gate()
        defer { gate.releaseAll() }
        session.beforeBindForTesting = { await gate.arrive() }
        let connect = Task { await session.connect(baseURL: otherServerURL) }
        try await within("the switch holds its bind", timeout: .seconds(10)) { await gate.arrival() }
        #expect(await session.activeScope() == nil)
        gate.open()
        _ = try await within("the switch finished", timeout: .seconds(10)) { await connect.value }
        #expect(await session.activeScope()?.id.hasPrefix(w.other.serverId) == true)
        session.beforeBindForTesting = nil
        await session.shutdown()

        // A launch in the background for an action: never started, nothing binding: the registry.
        let background = try w.session()
        let registryScope = try #require(await background.activeScope())
        #expect(registryScope.id.hasPrefix(w.other.serverId))
        // Its first bind pending (started, held before the bind): nothing.
        let first = Gate()
        defer { first.releaseAll() }
        background.beforeBindForTesting = { await first.arrive() }
        let start = Task { await background.start() }
        try await within("the first bind is held", timeout: .seconds(10)) { await first.arrival() }
        #expect(await background.activeScope() == nil)
        first.open()
        try await within("started", timeout: .seconds(10)) { await start.value }
        #expect(await background.activeScope() == registryScope)
        await background.shutdown()
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
        let episode = session.beginBackground()
        _ = await session.didEnterBackground(episode)
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

        // An expiration after the app became active is stale: nothing is paused or suspended.
        await session.backgroundTimeExpiring(episode)
        #expect(suspended.count == 1)
        #expect(await !scheduler.isPaused)
        await session.shutdown()
    }

    @Test func afterStartTheStatusHasTheLastPull() async throws {
        let w = try World()
        defer { w.env.cleanup() }
        let session = try w.session()
        await session.start(serverURL: SyncEnv.baseURL)
        try await eventually("last pull published") { @MainActor in session.syncStatus.lastSyncAt != nil }
        #expect(session.coordinator.status.lastSyncAt != nil)
        await session.shutdown()
    }

    /// STATS: the bound store has a stats loader over it; none before a bind or after teardown.
    @Test func theBoundStoreHasAStatsLoader() async throws {
        let w = try World()
        defer { w.env.cleanup() }
        let session = try w.session()
        #expect(session.stats == nil)
        await session.start(serverURL: SyncEnv.baseURL)
        try await eventually("bound") { @MainActor in session.store != nil }
        #expect(session.stats != nil)
        await session.shutdown()
        #expect(session.stats == nil)
    }

    @Test func backgroundRefreshPullsThenSendsThenSuspends() async throws {
        let w = try World()
        defer { w.env.cleanup() }
        let suspended = w.posted(Database.suspendNotification)
        let resumed = w.posted(Database.resumeNotification)
        let session = try w.session()
        #expect(await session.backgroundRefresh(session.beginBackground()) == nil)  // not started
        await session.start(serverURL: SyncEnv.baseURL)
        let scheduler = try #require(session.scheduler)

        // In the background (paused), an entry is queued: nothing sends it.
        _ = await session.didEnterBackground(session.beginBackground())
        let suspendedBefore = suspended.count
        _ = try await session.log(topic: Payloads.water, answers: ["glasses": .int(2)], version: 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!w.env.transport.requests.contains { $0.method == .post })

        // BGAppRefreshTask: resume, pull, send, then pause and suspend again.
        let pulls = w.env.afters().count
        let episode = session.beginBackground()
        #expect(await session.backgroundRefresh(episode) == .synced)
        #expect(w.env.afters().count > pulls)
        #expect(w.env.transport.requests.contains { $0.method == .post })
        #expect(await scheduler.started.contains(OutboxFlushReason.backgroundRefresh.policy))
        #expect(resumed.count >= 1 && suspended.count == suspendedBefore + 1)
        #expect(await scheduler.isPaused)

        // Once the app is active, the old episode's refresh does nothing.
        await session.didBecomeActive()
        #expect(await session.backgroundRefresh(episode) == nil)
        #expect(suspended.count == suspendedBefore + 1 && !session.isBackgrounded)
        await session.shutdown()
    }

    /// The refresh's time runs out mid-pull: the pull is cancelled (the lease freed), GRDB is
    /// suspended once, the refresh does nothing more, and nothing of that episode resumes later.
    @Test func expiryDuringABackgroundRefreshStopsThePull() async throws {
        let w = try World()
        defer { w.env.cleanup() }
        let suspended = w.posted(Database.suspendNotification)
        let gate = Gate()
        let armed = Mutex(false)
        let session = try w.session(
            transport: GatedTransport(w.env.transport, gate) { request in
                // Only the refresh's pull is held (armed just before it).
                request.url.path == "/api/v1/changes" && armed.withLock { $0 }
            })
        await session.start(serverURL: SyncEnv.baseURL)
        let store = try #require(session.store)
        _ = await session.didEnterBackground(session.beginBackground())
        let before = suspended.count

        armed.withLock { $0 = true }
        let episode = session.beginBackground()
        let refresh = Task { await session.backgroundRefresh(episode) }
        await gate.arrival()  // the refresh's pull is in flight
        await session.backgroundTimeExpiring(episode, within: .seconds(10))
        let result = await refresh.value
        #expect(result == .paused || result == nil)
        #expect(suspended.count == before + 1)
        #expect(try await store.writer.read { db in try LeaseTable.record(db, .sync).owner } == nil)
        // The expired episode stays stopped: its refresh does nothing, and runs are refused.
        #expect(await session.backgroundRefresh(episode) == nil)
        #expect(await session.coordinator.sync(reason: .requested) == .paused)
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
        let episode = session.beginBackground()
        let background = Task { await session.didEnterBackground(episode) }  // waits for that flush
        await session.backgroundTimeExpiring(episode, within: .seconds(10))
        _ = await background.value
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

    @Test func aBackgroundFlushEndingAfterActivationDoesntSuspend() async throws {
        let w = try World()
        defer { w.env.cleanup() }
        let gate = Gate()
        let suspended = w.posted(Database.suspendNotification)
        let session = try w.session(transport: GatedTransport(w.env.transport, gate) { $0.method == .post })
        await session.start(serverURL: SyncEnv.baseURL)
        let scheduler = try #require(session.scheduler)
        _ = try await session.log(topic: Payloads.water, answers: ["glasses": .int(1)], version: 1)
        await gate.arrival()  // the sender is blocked

        let background = Task { await session.didEnterBackground() }
        try await eventually("backgrounded") { await MainActor.run { session.isBackgrounded } }
        await session.didBecomeActive()  // foreground work starts while the background flush waits
        gate.open()
        _ = await background.value  // the old background call completes now
        #expect(suspended.count == 0, "a stale background completion never suspends")
        #expect(await !scheduler.isPaused)
        try await eventually("the log is delivered") { try await session.store?.outbox.items().isEmpty == true }
        await session.shutdown()
    }

    /// background₁ → active → background₂, then background₁'s expiry and completion arrive late:
    /// background₂'s flush is not cancelled, and background₂ stays paused (flushes and pulls).
    @Test func aStaleEpisodeNeverTouchesTheCurrentOne() async throws {
        let w = try World()
        defer { w.env.cleanup() }
        let gate = Gate()
        let suspended = w.posted(Database.suspendNotification)
        let session = try w.session(transport: GatedTransport(w.env.transport, gate) { $0.method == .post })
        await session.start(serverURL: SyncEnv.baseURL)
        let scheduler = try #require(session.scheduler)
        _ = try await session.log(topic: Payloads.water, answers: ["glasses": .int(1)], version: 1)
        await gate.arrival()  // a flush is in flight, its sender blocked

        let first = session.beginBackground()
        let firstWork = Task { await session.didEnterBackground(first) }
        await session.didBecomeActive()
        let second = session.beginBackground()
        let secondWork = Task { await session.didEnterBackground(second) }

        await session.backgroundTimeExpiring(first)  // stale: must not cancel the current episode's flush
        #expect(await scheduler.isFlushing, "background₂'s flush is still running")
        #expect(await session.coordinator.sync(reason: .requested) == .paused)

        gate.open()
        _ = await firstWork.value  // background₁ completes late: leaves the pause state alone
        _ = await secondWork.value
        #expect(await scheduler.isPaused, "background₂ is paused")
        #expect(await session.coordinator.sync(reason: .requested) == .paused)
        #expect(suspended.count == 1, "only background₂ suspends")

        await session.didBecomeActive()
        #expect(await !scheduler.isPaused)
        #expect(await session.coordinator.sync(reason: .requested) == .synced)
        await session.shutdown()
    }

    /// A rebind starts in the background and its bind is held; the app becomes active meanwhile
    /// (resuming the old scheduler), then the bind completes: the new scheduler is published
    /// resumed, matching the scene, and a log goes out.
    @Test func aSchedulerPublishedAfterAnActivationIsResumed() async throws {
        let w = try World()
        defer { w.env.cleanup() }
        let session = try w.session()
        await session.start(serverURL: SyncEnv.baseURL)
        let old = try #require(session.scheduler)
        let gate = Gate()
        defer { gate.releaseAll() }
        session.beforeBindForTesting = { await gate.arrive() }
        let episode = session.beginBackground()
        _ = await session.didEnterBackground(episode)
        #expect(await old.isPaused)

        let rebind = Task { await session.connect(baseURL: SyncEnv.baseURL) }  // forced: a new scheduler
        try await within("the rebind holds its bind") { await gate.arrival() }
        let activation = Task { await session.didBecomeActive() }  // its rebind queues behind the held one
        try await eventually("the activation resumed the old scheduler") {
            await !old.isPaused
        }
        gate.open()
        _ = try await within("the rebind finished") { await rebind.value }
        try await within("the activation finished") { await activation.value }

        let scheduler = try #require(session.scheduler)
        #expect(scheduler !== old)
        #expect(await !scheduler.isPaused, "published resumed: the scene is in the foreground")
        _ = try await session.log(topic: Payloads.water, answers: ["glasses": .int(1)], version: 1)
        try await eventually("the log is delivered") {
            try await session.store?.outbox.items().isEmpty == true
        }
        await session.shutdown()
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

    // MARK: - Holding the store resumed (HANDLER-RESUME)

    /// A hold resumes GRDB only if the session suspended it, and its last release suspends it
    /// again; nested holds share it, and a second release of one hold does nothing.
    @Test func holdsResumeASuspendedStoreAndSuspendItAgain() async throws {
        let w = try World()
        let resumed = w.posted(Database.resumeNotification)
        let suspended = w.posted(Database.suspendNotification)
        let session = try w.session()
        await session.start(serverURL: SyncEnv.baseURL)

        // In the foreground nothing is suspended: a hold posts nothing.
        let (resumes, suspends) = (resumed.count, suspended.count)
        session.holdStoreResumed().release()
        #expect(resumed.count == resumes && suspended.count == suspends)

        _ = await session.didEnterBackground(session.beginBackground())
        #expect(suspended.count == suspends + 1)

        let outer = session.holdStoreResumed()
        #expect(resumed.count == resumes + 1, "the first hold resumes")
        let inner = session.holdStoreResumed()
        inner.release()
        #expect(resumed.count == resumes + 1 && suspended.count == suspends + 1, "one hold still open")
        outer.release()
        #expect(suspended.count == suspends + 2, "the last release suspends again")
        outer.release()
        #expect(suspended.count == suspends + 2, "a second release does nothing")
        await session.shutdown()
    }

    /// The episode finishing while a hold is open waits for its release; an activation during a
    /// hold wins, and the release then leaves the store resumed.
    @Test func aSuspendDuringAHoldWaitsAndAnActivationWins() async throws {
        let w = try World()
        let resumed = w.posted(Database.resumeNotification)
        let suspended = w.posted(Database.suspendNotification)
        let session = try w.session()
        await session.start(serverURL: SyncEnv.baseURL)

        let episode = session.beginBackground()
        let suspends = suspended.count
        let hold = session.holdStoreResumed()  // an action arrives as the app goes to the background
        _ = await session.didEnterBackground(episode)
        #expect(suspended.count == suspends, "the episode's suspend waits for the hold")
        hold.release()
        #expect(suspended.count == suspends + 1)

        let resumes = resumed.count
        let late = session.holdStoreResumed()
        #expect(resumed.count == resumes + 1)
        await session.didBecomeActive()
        late.release()
        #expect(suspended.count == suspends + 1, "back in the foreground: not suspended again")
        await session.shutdown()
    }

    /// An expiring episode doesn't wait for a hold: GRDB is suspended before its background task
    /// ends, the hold's late release does nothing, and a later hold resumes it again (Codex r1).
    @Test func anExpirySuspendsDespiteAnOpenHold() async throws {
        let w = try World()
        let resumed = w.posted(Database.resumeNotification)
        let suspended = w.posted(Database.suspendNotification)
        let session = try w.session()
        await session.start(serverURL: SyncEnv.baseURL)

        let episode = session.beginBackground()
        let parked = session.holdStoreResumed()  // a response still running when the time is up
        let suspends = suspended.count
        await session.backgroundTimeExpiring(episode, within: .seconds(5))
        #expect(suspended.count == suspends + 1, "suspended at expiry, the hold still open")
        parked.release()
        #expect(suspended.count == suspends + 1, "the ended hold's release does nothing")

        let resumes = resumed.count
        let next = session.holdStoreResumed()
        #expect(resumed.count == resumes + 1, "a later hold resumes")
        next.release()
        #expect(suspended.count == suspends + 2, "and suspends again")
        await session.shutdown()
    }

    /// An ended hold's work still unwinding while newer holds open, then an activation and a
    /// refresh episode: its late release never suspends the store under them (Codex r2).
    @Test func anEndedHoldNeverSuspendsUnderNewerHoldsOrEpisodes() async throws {
        let w = try World()
        let resumed = w.posted(Database.resumeNotification)
        let suspended = w.posted(Database.suspendNotification)
        let session = try w.session()
        await session.start(serverURL: SyncEnv.baseURL)

        let expiring = session.beginBackground()
        let parked = session.holdStoreResumed()  // cancelled at expiry, still unwinding
        await session.backgroundTimeExpiring(expiring, within: .seconds(5))
        let (resumes, suspends) = (resumed.count, suspended.count)
        let fresh = session.holdStoreResumed()  // another action, with its own background task
        #expect(resumed.count == resumes + 1)
        parked.release()
        #expect(suspended.count == suspends, "the ended hold doesn't suspend under the new one")
        fresh.release()
        #expect(suspended.count == suspends + 1, "the new hold's release does")

        // An activation: the parked work's release (a second ended hold) changes nothing.
        let unwinding = session.holdStoreResumed()
        await session.backgroundTimeExpiring(session.beginBackground(), within: .seconds(5))
        await session.didBecomeActive()
        unwinding.release()
        #expect(suspended.count == suspends + 2, "only the expiry suspended; the foreground stays resumed")

        // A refresh episode after an expiry: it resumes, the stale release doesn't suspend mid-pull,
        // and the episode suspends at its end.
        let stale = session.holdStoreResumed()
        await session.backgroundTimeExpiring(session.beginBackground(), within: .seconds(5))
        let afterExpiry = suspended.count
        let refresh = session.beginBackground()
        stale.release()
        #expect(suspended.count == afterExpiry)
        let resumesBefore = resumed.count
        _ = await session.backgroundRefresh(refresh)
        #expect(resumed.count == resumesBefore + 1)
        #expect(suspended.count == afterExpiry + 1, "suspended once, by the refresh's end")
        await session.shutdown()
    }
}

/// The real-time case of `AppSessionTests` (see `TimingTests`).
extension TimingTests {
    @MainActor @Suite struct AppSessionTiming {
        @Test func expiryIsBoundedByTheRemainingTime() async throws {
            let w = try AppSessionTests.World()
            defer { w.env.cleanup() }
            let gate = Gate()
            let suspended = w.posted(Database.suspendNotification)
            let session = try w.session(
                transport: GatedTransport(w.env.transport, gate) { $0.url.path == "/api/v1/changes" && gate.armed })
            await session.start(serverURL: SyncEnv.baseURL)
            gate.arm()
            let pull = Task { await session.coordinator.sync(reason: .requested) }
            await gate.arrival()  // a pull is parked and won't end

            let episode = session.beginBackground()
            let background = Task { await session.didEnterBackground(episode) }  // waits for the parked pull
            let started = ContinuousClock.now
            await session.backgroundTimeExpiring(episode, within: .milliseconds(300))
            #expect(ContinuousClock.now - started < .seconds(10), "returned at the bound, not when the pull ends")
            #expect(suspended.count == 1)
            gate.releaseAll()
            _ = await pull.value
            _ = await background.value
            await session.shutdown()
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
        if matches(request) {
            // A cancelled request (an expiry) stops waiting, as URLSession's does.
            try await withTaskCancellationHandler {
                await gate.arrive()
            } onCancel: {
                gate.open()
            }
            try Task.checkCancellation()
        }
        return try await inner.send(request)
    }
}

extension Gate {
    private static let armedGates = Mutex<Set<ObjectIdentifier>>([])

    /// Whether `arm()` was called: lets a gate let earlier requests through.
    var armed: Bool { Self.armedGates.withLock { $0.contains(ObjectIdentifier(self)) } }

    func arm() { _ = Self.armedGates.withLock { $0.insert(ObjectIdentifier(self)) } }

}
