import Foundation
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// `SyncCoordinator.handle(_:)` and `OutboxFlushBridge` (sync-protocol.md §5.6, §7). The
/// end-to-end versions against the real backend are in QuickrDataIntegrationTests (S8, S9, 38, 49).
@Suite struct OutboxBridgeTests {
    @Test(arguments: [OutboxSignal.epochSuspect, .pullRequested, .identityMismatch])
    func everySignalRunsTheCoordinator(_ signal: OutboxSignal) async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        try await env.connect(coordinator)
        let before = env.afters().count

        coordinator.handle(signal)
        try await eventually("the coordinator pulls") { env.afters().count > before }
    }

    @Test func epochSuspectFromTheOutboxRebuildsAfterARotation() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let coordinator = env.coordinator()
        let store = try await env.connect(coordinator)
        let gen = try await store.state().layerGen
        env.server.rotateEpoch(to: "e2")

        coordinator.handle(.epochSuspect)
        try await eventually("the rebuild swaps") {
            let state = try await env.activeStore().state()
            return state.epoch == "e2" && state.layerGen > gen
        }
        #expect(env.recorder.flushes.contains(.afterSwap))
    }

    @Test func theBridgeForwardsToTheBoundScheduler() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        try await env.connect(env.coordinator())
        let store = try await env.activeStore()
        let scheduler = OutboxFlushScheduler(outbox: Outbox(store: store, sender: NeverSends(), owner: "app:A"))
        let bridge = OutboxFlushBridge()

        bridge.requestFlush(reason: .afterSwap)  // nothing bound: dropped
        try await Task.sleep(for: .milliseconds(50))
        #expect(await scheduler.started.isEmpty)

        bridge.bind(scheduler)
        bridge.requestFlush(reason: .afterSwap)
        bridge.requestFlush(reason: .afterPull)
        try await eventually("both flushes start") { await scheduler.started.count == 2 }
        #expect(await scheduler.started.allSatisfy { $0 == OutboxFlushReason.afterPull.policy })

        bridge.bind(nil)
        bridge.requestFlush(reason: .afterPull)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await scheduler.started.count == 2)
    }
}

/// A sender for an outbox that never has anything to send.
private struct NeverSends: OutboxSender {
    func send(_ request: OutboxRequest) async -> APIResponse<OutboxSuccess> {
        Issue.record("unexpected send \(request.operation)")
        return await withUnsafeContinuation { _ in }
    }
}
