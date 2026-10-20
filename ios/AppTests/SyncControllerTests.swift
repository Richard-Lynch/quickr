import Foundation
import QuickrCore
import QuickrData
import Synchronization
import Testing

@testable import QuickR

/// SYNC-UX's app side over the UI-test fake server (`UITestLaunch`): the pill follows the outbox,
/// a regained network sends and pulls, and the background refresh pulls, sends and completes its
/// task. Serialized: the fake server's switches and the network path are shared statics.
@MainActor
@Suite(.serialized) struct SyncControllerTests {
    /// A started environment on the fake server, online, with the controller observing its store.
    private func started() async throws -> (AppEnvironment, AppSession, Task<Void, Never>) {
        UITestLaunch.server.offline = false
        UITestLaunch.network.set(online: true)
        let environment = UITestLaunch.environment()
        environment.settings.serverURL = UITestLaunch.fakeServer
        await environment.start()
        let session = try #require(environment.session)
        #expect(session.phase == .ready)
        let observing = Task { await environment.sync.observe(session) }
        return (environment, session, observing)
    }

    private func eventually(_ what: String, _ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while await !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out waiting until \(what)")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func thePillFollowsTheOutboxAndTheNetwork() async throws {
        let (environment, session, observing) = try await started()
        defer { observing.cancel() }
        #expect(environment.sync.pill(status: session.syncStatus) == .hidden)

        UITestLaunch.server.offline = true
        UITestLaunch.network.set(online: false)
        try await eventually("offline") { environment.sync.pill(status: session.syncStatus) == .offline(waiting: 0) }
        _ = try await session.log(topic: UITestSyncControls.topic, answers: ["mood": .int(3)], version: 1)
        try await eventually("one waiting") {
            environment.sync.pill(status: session.syncStatus) == .offline(waiting: 1)
        }
        let sheet = environment.sync.sheet(lastSyncAt: nil)
        #expect(sheet.rows.map(\.title) == ["Entry · Mood"] && !sheet.online)

        // Back online: the regained path asks for a forced flush, and the entry goes.
        let scheduler = try #require(session.scheduler)
        let flushes = await scheduler.started.count
        UITestLaunch.server.offline = false
        UITestLaunch.network.set(online: true)
        try await eventually("a network flush") {
            await scheduler.started.dropFirst(flushes).contains(OutboxFlushReason.networkAvailable.policy)
        }
        try await eventually("sent") { environment.sync.pill(status: session.syncStatus) == .hidden }
        #expect(environment.sync.items.isEmpty)
        await session.shutdown()
    }

    @Test func retryAndDiscardFromTheSheet() async throws {
        let (environment, session, observing) = try await started()
        defer { observing.cancel() }
        UITestLaunch.server.rejectNextCreate()
        _ = try await session.log(topic: UITestSyncControls.topic, answers: ["mood": .int(3)], version: 1)
        try await eventually("failed") { environment.sync.pill(status: session.syncStatus) == .failed(count: 1) }
        let row = try #require(environment.sync.sheet(lastSyncAt: nil).rows.first)
        #expect(row.status == "Failed — Mood is required" && row.fix != nil)

        try await environment.sync.retry(row)
        try await eventually("retried and sent") { environment.sync.items.isEmpty }

        UITestLaunch.server.rejectNextCreate()
        _ = try await session.log(topic: UITestSyncControls.topic, answers: ["mood": .int(4)], version: 1)
        try await eventually("failed again") { environment.sync.summary?.failed == 1 }
        let failed = try #require(environment.sync.sheet(lastSyncAt: nil).rows.first)
        try await environment.sync.discard(failed)
        try await eventually("discarded") { environment.sync.items.isEmpty }
        await session.shutdown()
    }

    /// A row from another store (the sheet was showing a store that has since been replaced) is
    /// refused, and nothing in the active store changes.
    @Test func actionsFromAnotherStoreAreRefused() async throws {
        let (environment, session, observing) = try await started()
        defer { observing.cancel() }
        UITestLaunch.server.rejectNextCreate()
        _ = try await session.log(topic: UITestSyncControls.topic, answers: ["mood": .int(3)], version: 1)
        try await eventually("failed") { environment.sync.summary?.failed == 1 }
        var stale = try #require(environment.sync.sheet(lastSyncAt: nil).rows.first)
        #expect(stale.scope == "\(UITestLaunch.fakeServerId)/1")
        stale.scope = "\(UITestLaunch.fakeServerId)/0"  // the store before a reset
        await #expect(throws: SyncActionError.self) { try await environment.sync.retry(stale) }
        await #expect(throws: SyncActionError.self) { try await environment.sync.discard(stale) }
        await #expect(throws: SyncActionError.self) { try await environment.sync.dismiss(stale) }
        #expect(throws: SyncActionError.self) { try environment.sync.fixRoute(stale) }
        #expect(environment.sync.summary?.failed == 1 && environment.sync.items.count == 1)
        await session.shutdown()
    }

    /// The system's time runs out while the session is still starting: the task completes once,
    /// unsuccessfully, and no background episode begins.
    @Test func expiryDuringStartupStopsBeforeAnyEpisode() async throws {
        UITestLaunch.server.offline = false
        let environment = UITestLaunch.environment()
        environment.settings.serverURL = UITestLaunch.fakeServer
        environment.scenePhaseChanged(.background)
        // GRDB's resume: a refresh episode posts it when it starts.
        let resumes = Counter()
        let observer = NotificationCenter.default.addObserver(
            forName: Notification.Name("GRDB.Database.Resume"), object: nil, queue: nil
        ) { _ in resumes.increment() }
        defer { NotificationCenter.default.removeObserver(observer) }
        let task = RecordingRefreshTask()
        let refresh = Task { await environment.backgroundRefresh(task) }
        await Task.yield()
        task.expire()
        await refresh.value
        try await eventually("completed") { task.completions == [false] }
        try await Task.sleep(for: .milliseconds(200))
        #expect(task.completions == [false])  // once
        #expect(resumes.count == 0, "an episode began after the expiry")
        await environment.session?.shutdown()
    }

    /// The time runs out while startup is connecting (its feed request held): the start itself
    /// stops. The request is cancelled, nothing more is sent, the connect never completes, the
    /// database is suspended; opening the app later finishes the connect.
    @Test func expiryDuringStartupStopsTheStartItself() async throws {
        UITestLaunch.server.offline = false
        UITestLaunch.server.holdFeed()
        defer { UITestLaunch.server.releaseFeed() }
        let environment = UITestLaunch.environment()
        environment.settings.serverURL = UITestLaunch.fakeServer
        environment.scenePhaseChanged(.background)
        let suspends = Counter()
        let observer = NotificationCenter.default.addObserver(
            forName: Notification.Name("GRDB.Database.Suspend"), object: nil, queue: nil
        ) { _ in suspends.increment() }
        defer { NotificationCenter.default.removeObserver(observer) }
        let task = RecordingRefreshTask()
        let refresh = Task { await environment.backgroundRefresh(task) }
        try await eventually("startup is fetching") { UITestLaunch.server.heldCount == 1 }
        let suspendsBefore = suspends.count

        task.expire()
        try await eventually("completed") { task.completions == [false] }
        try await eventually("the held request is cancelled") { UITestLaunch.server.heldCount == 0 }
        let requests = UITestLaunch.server.requestCount
        // Released before awaiting the refresh, so a start that kept going fails here, not hangs.
        UITestLaunch.server.releaseFeed()
        await refresh.value
        try await Task.sleep(for: .milliseconds(500))
        #expect(UITestLaunch.server.requestCount == requests, "startup went on after the expiry")
        #expect(environment.session?.phase != .ready)
        #expect(suspends.count > suspendsBefore)

        // Opened later: the interrupted connect finishes.
        environment.scenePhaseChanged(.active)
        try await eventually("connected") { environment.session?.phase == .ready }
        await environment.session?.shutdown()
    }

    /// The app is opened while a refresh is starting the session: the refresh does nothing, and
    /// the app stays in the foreground (nothing paused or suspended).
    @Test func activationDuringStartupWins() async throws {
        UITestLaunch.server.offline = false
        let environment = UITestLaunch.environment()
        environment.settings.serverURL = UITestLaunch.fakeServer
        environment.scenePhaseChanged(.background)
        let task = RecordingRefreshTask()
        let refresh = Task { await environment.backgroundRefresh(task) }
        await Task.yield()
        environment.scenePhaseChanged(.active)
        await refresh.value
        #expect(task.completions == [true])
        let session = try #require(environment.session)
        try await eventually("foreground") { !session.isBackgrounded }
        try await eventually("bound") { session.scheduler != nil }
        #expect(await session.scheduler?.isPaused == false)
        await session.shutdown()
    }

    @Test func backgroundRefreshPullsSendsAndCompletes() async throws {
        let (environment, session, observing) = try await started()
        defer { observing.cancel() }

        // In the foreground there is nothing to do.
        environment.scenePhaseChanged(.active)
        let foreground = RecordingRefreshTask()
        await environment.backgroundRefresh(foreground)
        #expect(foreground.completions == [true] && foreground.hasExpirationHandler)  // installed first

        // In the background: pull, send, complete; the expiration handler is in place.
        UITestLaunch.server.offline = true
        _ = try await session.log(topic: UITestSyncControls.topic, answers: ["mood": .int(5)], version: 1)
        try await eventually("queued") { environment.sync.summary?.queued == 1 }
        // The background flush can't send it (still unreachable); then the refresh can.
        environment.scenePhaseChanged(.background)
        try await eventually("backgrounded and paused") { await session.scheduler?.isPaused == true }
        #expect(try await session.outbox?.summary().queued == 1)
        UITestLaunch.server.offline = false
        let task = RecordingRefreshTask()
        await environment.backgroundRefresh(task)
        #expect(task.completions == [true] && task.hasExpirationHandler)
        #expect(try await session.outbox?.summary().queued == 0)
        await session.shutdown()
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

/// A stand-in `BGAppRefreshTask`; `expire()` runs the expiration handler as the system would.
final class RecordingRefreshTask: BackgroundRefreshTask {
    func expire() { state.withLock { $0.handler }?() }

    private let state = Mutex<(completions: [Bool], handler: (@Sendable () -> Void)?)>(([], nil))

    var completions: [Bool] { state.withLock { $0.completions } }
    var hasExpirationHandler: Bool { state.withLock { $0.handler != nil } }

    func onExpiration(_ handler: @escaping @Sendable () -> Void) { state.withLock { $0.handler = handler } }

    func complete(success: Bool) { state.withLock { $0.completions.append(success) } }
}
