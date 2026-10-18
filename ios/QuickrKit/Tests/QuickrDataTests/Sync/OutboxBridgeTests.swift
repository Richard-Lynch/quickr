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
        // The coordinator asks for the flush right after it commits the swap.
        try await eventually("the swap asks for a flush") { env.recorder.flushes.contains(.afterSwap) }
    }

    @Test func theBridgeForwardsToTheBoundScheduler() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        try await env.connect(env.coordinator())
        let scheduler = try await Self.scheduler(env)
        let bridge = OutboxFlushBridge()

        bridge.requestFlush(reason: .afterSwap)  // nothing bound: dropped
        try await Task.sleep(for: .milliseconds(50))
        #expect(await scheduler.started.isEmpty)

        await bridge.bind(scheduler)
        bridge.requestFlush(reason: .afterSwap)
        bridge.requestFlush(reason: .afterPull)  // same burst: coalesced into one forward
        try await eventually("a flush starts") { await scheduler.started.count >= 1 }
        _ = await scheduler.waitUntilIdle()
        let burst = await scheduler.started.count
        bridge.requestFlush(reason: .afterPull)  // after the forward: another one
        try await eventually("another flush starts") { await scheduler.started.count > burst }
        #expect(await scheduler.started.allSatisfy { $0 == OutboxFlushReason.afterPull.policy })

        await bridge.bind(nil)
        #expect(await scheduler.isRetired)
        bridge.requestFlush(reason: .afterPull)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await scheduler.started.count == 2)
    }

    /// Open (nothing → A), reset (A → B) and switch (B → nothing), each with flush requests still
    /// on their way: once `bind` returns, the scheduler it replaced never starts another flush.
    @Test func bindingRevokesRequestsAlreadyOnTheirWay() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        try await env.connect(env.coordinator())
        let a = try await Self.scheduler(env)
        let b = try await Self.scheduler(env)
        let bridge = OutboxFlushBridge()

        for _ in 0..<50 { bridge.requestFlush(reason: .afterPull) }
        await bridge.bind(a)  // open: whatever was pending finds A (or nothing)
        for _ in 0..<50 { bridge.requestFlush(reason: .afterPull) }
        await bridge.bind(b)  // reset: requests in flight must not start flushes on A
        #expect(await a.isRetired)
        let aStarted = await a.started.count
        bridge.requestFlush(reason: .afterSwap)
        try await eventually("B receives a request while it is bound") { await b.started.count > 0 }
        for _ in 0..<50 { bridge.requestFlush(reason: .afterSwap) }
        await bridge.bind(nil)  // server switch
        #expect(await b.isRetired)
        let bStarted = await b.started.count

        try await Task.sleep(for: .milliseconds(200))
        #expect(await a.started.count == aStarted)
        #expect(await b.started.count == bStarted)
        #expect(await bridge.bound == nil)
    }

    /// The production wiring (coordinator → bridge → scheduler → outbox → `outboxSignalHandler`)
    /// is freed once the app lets go of it: the handler holds the coordinator weakly.
    @Test func theWiringIsFreedWhenReleased() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        try await env.connect(env.coordinator())
        let store = try await env.activeStore()
        let refs = WeakRefs()
        do {
            let bridge = OutboxFlushBridge()
            let coordinator = SyncCoordinator(
                partitions: env.partitions, feed: env.feed, flush: bridge, owner: "app:A")
            let outbox = Outbox(
                store: store, sender: NeverSends(), owner: "app:A", onSignal: coordinator.outboxSignalHandler)
            let scheduler = OutboxFlushScheduler(outbox: outbox)
            await bridge.bind(scheduler)
            _ = await coordinator.sync(reason: .requested)
            _ = await scheduler.waitUntilIdle()
            outbox.onSignal(.pullRequested)
            refs.coordinator = coordinator
            refs.scheduler = scheduler
            refs.bridge = bridge
        }
        try await eventually("the wiring is freed") {
            refs.coordinator == nil && refs.scheduler == nil && refs.bridge == nil
        }
    }

    static func scheduler(_ env: SyncEnv) async throws -> OutboxFlushScheduler {
        OutboxFlushScheduler(outbox: Outbox(store: try await env.activeStore(), sender: NeverSends(), owner: "app:A"))
    }
}

/// Weak references read from a polling closure.
private final class WeakRefs: @unchecked Sendable {
    weak var coordinator: SyncCoordinator?
    weak var scheduler: OutboxFlushScheduler?
    weak var bridge: OutboxFlushBridge?
}

/// A sender for an outbox that never has anything to send.
private struct NeverSends: OutboxSender {
    func send(_ request: OutboxRequest) async -> APIResponse<OutboxSuccess> {
        Issue.record("unexpected send \(request.operation)")
        return await withUnsafeContinuation { _ in }
    }
}
