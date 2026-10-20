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

        // Back online: the regained path flushes (forced) and the entry goes.
        UITestLaunch.server.offline = false
        UITestLaunch.network.set(online: true)
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

        try await environment.sync.retry(row.id)
        try await eventually("retried and sent") { environment.sync.items.isEmpty }

        UITestLaunch.server.rejectNextCreate()
        _ = try await session.log(topic: UITestSyncControls.topic, answers: ["mood": .int(4)], version: 1)
        try await eventually("failed again") { environment.sync.summary?.failed == 1 }
        let failed = try #require(environment.sync.items.first)
        try await environment.sync.discard(failed.id)
        try await eventually("discarded") { environment.sync.items.isEmpty }
        await session.shutdown()
    }

    @Test func backgroundRefreshPullsSendsAndCompletes() async throws {
        let (environment, session, observing) = try await started()
        defer { observing.cancel() }

        // In the foreground there is nothing to do.
        environment.scenePhaseChanged(.active)
        let foreground = RecordingRefreshTask()
        await environment.backgroundRefresh(foreground)
        #expect(foreground.completions == [true] && !foreground.hasExpirationHandler)

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

/// A stand-in `BGAppRefreshTask`.
final class RecordingRefreshTask: BackgroundRefreshTask {
    private let state = Mutex<(completions: [Bool], handler: (@Sendable () -> Void)?)>(([], nil))

    var completions: [Bool] { state.withLock { $0.completions } }
    var hasExpirationHandler: Bool { state.withLock { $0.handler != nil } }

    func onExpiration(_ handler: @escaping @Sendable () -> Void) { state.withLock { $0.handler = handler } }

    func complete(success: Bool) { state.withLock { $0.completions.append(success) } }
}
