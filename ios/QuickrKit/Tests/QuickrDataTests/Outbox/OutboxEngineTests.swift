import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// Engine behaviour outside the §13 matrix: the §5.2 rows the matrix doesn't name, S8 under
/// expiry recovery, the sync sheet's actions, the summary and the flush scheduler.
@Suite struct OutboxEngineTests {
    @Test func archive404RetiresAndUnarchive404FailsBothAskForAPull() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        try await outbox.archiveTopic(id: h.topic.id, origin: .app)
        h.server.deleteTopic(h.topic.id)
        _ = try await outbox.flushNow()
        #expect(h.items.isEmpty && h.signals == [.pullRequested])

        let other = try OutboxHarness(topicStatus: .archived)
        let unarchiver = other.outbox()
        try await unarchiver.unarchiveTopic(id: other.topic.id, origin: .app)
        other.server.deleteTopic(other.topic.id)
        _ = try await unarchiver.flushNow()
        #expect(other.items.single?.failureReason == .deletedElsewhere && other.signals == [.pullRequested])
    }

    @Test func aCreateToAnArchivedTopicFailsWithTheUnarchiveHint() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let id = try await h.log(outbox)
        h.server.setArchived(h.topic.id, true)
        _ = try await outbox.flushNow()
        let item = try #require(h.item(id))
        #expect(item.failureReason == .topicArchived)
        #expect(item.errorInfo?.message == "Topic is archived. Unarchive it to sync this entry.")
        // Fix is offered for topic_archived.
        await #expect(throws: OutboxError.itemChanged) {
            try await outbox.fix(itemId: item.id, payload: try item.payload(), rowVersion: item.rowVersion - 1)
        }
        try await outbox.fix(itemId: item.id, payload: try item.payload(), rowVersion: item.rowVersion)
        #expect(h.item(id)?.state == .pending && h.item(id)?.rowVersion == item.rowVersion + 1)
    }

    @Test func deleteOf404OrReservedIdIsDone() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let entry = try h.seedEntry()
        try await outbox.deleteEntry(id: entry.id, topicId: h.topic.id, undoable: false, origin: .app)
        h.server.inject(.delete, .respond(header(FakeServer.problem(404, "not_found"))))
        _ = try await outbox.flushNow()
        #expect(try h.items.isEmpty && h.isTombstoned(entry.id) && h.view(entry.id) == nil)
    }

    @Test func undoDuringFlightThenCrashRemovesTheCreateAtRecovery() async throws {
        let h = try OutboxHarness()
        let a = h.outbox(owner: "app:A")
        let b = try h.process("widget:B")
        let id = try await h.log(a)
        let gate = Gate()
        h.server.inject(.post, .delay(gate))
        let flushA = background { try await a.flushNow(budget: .seconds(120)) }
        await gate.arrival()
        try await a.undoLog(entryId: id, origin: .app)
        h.clock.advance(by: .seconds(31))
        _ = try await b.flushNow()
        // S8 at recovery: the create is gone and never resent; the DELETE went alone.
        #expect(h.server.count(.post) == 1 && h.server.count(.delete) == 1 && h.items.isEmpty)
        gate.open()
        _ = try await flushA.value
        #expect(h.server.entry(id) == nil)
    }

    @Test func aFailedCreateBlocksItsEntityAndDiscardCascades() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let id = try await h.log(outbox)
        h.server.inject(.post, .respond(header(FakeServer.problem(422, "invalid_answers", "bad"))))
        _ = try await outbox.flushNow()
        try await outbox.updateEntry(id: id, topicId: h.topic.id, patch: h.patch(notes: "n"), origin: .app)
        let other = try await h.log(outbox, minutes: 5)
        _ = try await outbox.flushNow()
        #expect(h.server.entry(other) != nil)  // other entities aren't blocked
        let summary = try await outbox.summary()
        #expect(summary.failed == 1 && summary.blocked == 1 && summary.queued == 1)
        try await outbox.discard(itemId: id.wireString, origin: .app)
        #expect(h.items.isEmpty)
    }

    @Test func discardOfAMaybeDeliveredCreateQueuesAStandaloneDelete() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let id = try await h.log(outbox)
        h.server.inject(.post, .lose(.timedOut(requestStarted: true)))
        _ = try await outbox.flushNow()
        try await outbox.discard(itemId: id.wireString, origin: .app)
        let delete = try #require(h.items.single)
        #expect(delete.kind == .entryDelete)
        await #expect(throws: OutboxError.self) { try await outbox.dismiss(itemId: delete.id) }
    }

    @Test func summaryReportsOfflineAndTheNextWake() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        #expect(try await outbox.summary().isEmpty)
        let id = try await h.log(outbox)
        h.server.inject(.post, .lose(.unreachable("offline")))
        _ = try await outbox.flushNow()
        let entry = try h.seedEntry()
        try await outbox.deleteEntry(id: entry.id, topicId: h.topic.id, undoable: true, origin: .app)
        let summary = try await outbox.summary()
        #expect(summary.queued == 2 && summary.held == 1 && summary.offline)
        #expect(summary.nextWake == h.item(id)?.due)
    }

    @Test func enqueueRefusesARetiredStoreAndHiddenEntries() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let entry = try h.seedEntry()
        try h.applyTombstone(.entry, id: entry.id, topicId: h.topic.id)
        await #expect(throws: OutboxError.entryDeleted) {
            try await outbox.deleteEntry(id: entry.id, topicId: h.topic.id, undoable: false, origin: .app)
        }
        try h.setSyncState("retired = 1")
        await #expect(throws: StoreError.retired) { try await h.log(outbox) }
    }

    @Test func undoLogOfAnAckedEntryQueuesADelete() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let id = try await h.log(outbox)
        _ = try await outbox.flushNow()
        #expect(try await outbox.undoLog(entryId: id, origin: .app) == .deleteQueued)
        #expect(try await outbox.undoLog(entryId: id, origin: .app) == .nothingToDo)
        _ = try await outbox.flushNow()
        #expect(h.server.entry(id) == nil && h.items.isEmpty)
        #expect(try await outbox.undoLog(entryId: id, origin: .app) == .nothingToDo)
    }

    @Test func theSchedulerCoalescesRequestsIntoOneFollowUp() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let scheduler = OutboxFlushScheduler(outbox: outbox)
        let first = try await h.log(outbox)
        let gate = Gate()
        h.server.inject(.post, .delay(gate))
        await scheduler.requestFlush(reason: .enqueue)
        await gate.arrival()
        let second = try await h.log(outbox, minutes: 1)
        for _ in 0..<5 { await scheduler.requestFlush(reason: .enqueue) }
        gate.open()
        let report = await scheduler.flushNow(reason: .timer)
        #expect(report?.ending == .drained)
        #expect(h.server.entry(first) != nil && h.server.entry(second) != nil)
        #expect(h.server.count(.post) == 2)
    }

    @Test func sendNowReportsSentOrQueued() async throws {
        let h = try OutboxHarness()
        let scheduler = OutboxFlushScheduler(outbox: h.outbox())
        let sent = try await h.log(scheduler.outbox)
        #expect(await scheduler.sendNow(itemId: sent.wireString, wait: .seconds(2.5)))
        let queued = try await h.log(scheduler.outbox, minutes: 1)
        h.server.inject(.post, .lose(.unreachable("offline")))
        #expect(await !scheduler.sendNow(itemId: queued.wireString, wait: .milliseconds(300)))
    }

    @Test func backgroundReleasesEveryHoldBeforeFlushing() async throws {
        let h = try OutboxHarness()
        let scheduler = OutboxFlushScheduler(outbox: h.outbox())
        let entry = try h.seedEntry()
        try await scheduler.outbox.deleteEntry(id: entry.id, topicId: h.topic.id, undoable: true, origin: .app)
        await scheduler.flushNow(reason: .background)
        #expect(h.server.entry(entry.id) == nil && h.items.isEmpty)
    }
}
