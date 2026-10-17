import Foundation
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// Retirement belongs to the still-current reset attempt (sync-protocol.md §12.1 steps 3–4): an
/// attempt aborted on the old file can't retire it afterwards, and an abort that comes after the
/// retire doesn't clear the intent.
@Suite struct ResetVetoTests {
    static let serverId = "veto-server"

    @Test func anAttemptAbortedJustBeforeItsRetireDoesNotRetire() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let old = try await env.partitions.createStore(serverId: Self.serverId, baseURL: "https://q.example")
        let intent = try await env.partitions.persistResetIntent(store: old, confirmedCount: 0, confirmedMaxSeq: 0)
        // X holds both leases and is about to retire; Y gave up waiting for them and aborts.
        let pair = try #require(try await old.leases.acquireSyncThenFlush(owner: "app:X", waitingUpTo: .seconds(1)))
        #expect(try await env.otherProcess().abortReset(intent, on: old) == .vetoed)
        let outcome = try await old.retire(
            confirmedCount: 0, confirmedMaxSeq: 0, intentToken: intent.pendingToken, sync: pair.sync, flush: pair.flush)
        #expect(outcome == .intentAborted)
        #expect(try await !old.isRetired())
        #expect(try await env.partitions.registry.repository.server(id: Self.serverId)?.pendingGen == nil)
        // A new attempt (a new token) is not affected by the old veto.
        let next = try await env.partitions.persistResetIntent(store: old, confirmedCount: 0, confirmedMaxSeq: 0)
        #expect(
            try await old.retire(
                confirmedCount: 0, confirmedMaxSeq: 0, intentToken: next.pendingToken, sync: pair.sync,
                flush: pair.flush) == .retired)
    }

    @Test func anAbortAfterTheRetireLeavesTheIntentForStepSix() async throws {
        let env = try SyncEnv()
        defer { env.cleanup() }
        let old = try await env.partitions.createStore(serverId: Self.serverId, baseURL: "https://q.example")
        let intent = try await env.partitions.persistResetIntent(store: old, confirmedCount: 0, confirmedMaxSeq: 0)
        let pair = try #require(try await old.leases.acquireSyncThenFlush(owner: "app:X", waitingUpTo: .seconds(1)))
        #expect(
            try await old.retire(
                confirmedCount: 0, confirmedMaxSeq: 0, intentToken: intent.pendingToken, sync: pair.sync,
                flush: pair.flush) == .retired)
        #expect(try await env.partitions.abortReset(intent, on: old) == .alreadyRetired)
        #expect(try await env.partitions.registry.repository.server(id: Self.serverId)?.pendingGen == 2)
    }
}
