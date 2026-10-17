import Foundation
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// S8 under expiry recovery (outbox.md §6.3, S8): a flusher that takes over an abandoned `flush`
/// lease removes a cancelled create in the takeover transaction, so the create's POST is never
/// resent ahead of its cancellation DELETE. (The rebuild swap takes over through the same
/// `OutboxSyncEffects.recoverExpiredFlush`; see SyncRegressionTests.)
@Suite struct OutboxTakeoverTests {
    @Test("S8 · a takeover of an expired lease removes a cancelled in-flight create")
    func takeoverRemovesCancelledCreate() async throws {
        let h = try OutboxHarness()
        let a = h.outbox(owner: "app:A")
        let b = try h.process("widget:B")
        let id = try await h.log(a)
        let gate = Gate()
        h.server.inject(.post, .delay(gate))
        let flushA = background { try await a.flushNow(budget: .seconds(120)) }
        await gate.arrival()
        #expect(try await a.undoLog(entryId: id, origin: .app) == .deleteQueued)
        let cancel = try #require(h.items.last)
        #expect(cancel.cancelsCreate && h.item(id)?.state == .inFlight)

        // A is suspended past its 30 s lease; B takes the lease over while a rebuild is staging,
        // so B's pass claims nothing and only the takeover transaction runs.
        h.clock.advance(by: .seconds(31))
        try h.setSyncState("rebuilding = 'E2'")
        #expect(try await b.flushNow().ending == .paused)
        #expect(h.item(id) == nil)
        #expect(h.item(cancel.id)?.state == .pending)

        try h.setSyncState("rebuilding = NULL")
        let report = try await b.flushNow()
        #expect(report.acked == 1 && h.items.isEmpty)
        // The POST was only ever sent once (A's), never resent by B.
        #expect(h.server.requests.filter { $0.method == .post }.count == 1)

        gate.open()
        _ = try await flushA.value
        #expect(h.server.entry(id) == nil)
        #expect(h.items.isEmpty)
    }
}
