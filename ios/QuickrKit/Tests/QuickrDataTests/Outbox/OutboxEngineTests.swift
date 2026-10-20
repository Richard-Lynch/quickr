import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// Engine behaviour outside the §13 matrix: the §5.2 rows the matrix doesn't name, S8 under
/// expiry recovery, the sync sheet's actions, the summary and the flush scheduler.
@Suite(.timeLimit(.minutes(2))) struct OutboxEngineTests {
    @Test func archive404RetiresAndUnarchive404FailsBothAskForAPull() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        try await outbox.archiveTopic(id: h.topic.id, origin: .app)
        h.server.deleteTopic(h.topic.id)
        _ = try await outbox.flushNow()
        #expect(try h.items.isEmpty && h.signals == [.pullRequested])

        let other = try OutboxHarness(topicStatus: .archived)
        let unarchiver = other.outbox()
        try await unarchiver.unarchiveTopic(id: other.topic.id, origin: .app)
        other.server.deleteTopic(other.topic.id)
        _ = try await unarchiver.flushNow()
        #expect(try other.items.single?.failureReason == .deletedElsewhere && other.signals == [.pullRequested])
    }

    @Test func aCreateToAnArchivedTopicFailsWithTheUnarchiveHint() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let id = try await h.log(outbox)
        h.server.setArchived(h.topic.id, true)
        _ = try await outbox.flushNow()
        let item = try #require(try h.item(id))
        #expect(item.failureReason == .topicArchived)
        #expect(try item.errorInfo?.message == "Topic is archived. Unarchive it to sync this entry.")
        // Fix is offered for topic_archived.
        await #expect(throws: OutboxError.itemChanged) {
            try await outbox.fix(itemId: item.id, payload: try item.payload(), rowVersion: item.rowVersion - 1)
        }
        try await outbox.fix(itemId: item.id, payload: try item.payload(), rowVersion: item.rowVersion)
        #expect(try h.item(id)?.state == .pending && h.item(id)?.rowVersion == item.rowVersion + 1)
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
        #expect(try h.server.count(.post) == 1 && h.server.count(.delete) == 1 && h.items.isEmpty)
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
        #expect(try h.items.isEmpty)
    }

    @Test func discardOfAMaybeDeliveredCreateQueuesAStandaloneDelete() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let id = try await h.log(outbox)
        h.server.inject(.post, .lose(.timedOut(requestStarted: true)))
        _ = try await outbox.flushNow()
        try await outbox.discard(itemId: id.wireString, origin: .app)
        let delete = try #require(try h.items.single)
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
        #expect(try summary.nextWake == h.item(id)?.due)
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
        #expect(try h.server.entry(id) == nil && h.items.isEmpty)
        #expect(try await outbox.undoLog(entryId: id, origin: .app) == .nothingToDo)
    }

    @Test func theSchedulerCoalescesRequestsIntoOneMergedFollowUp() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let scheduler = OutboxFlushScheduler(outbox: outbox)
        let first = try await h.log(outbox)
        let entry = try h.seedEntry()
        try await outbox.deleteEntry(id: entry.id, topicId: h.topic.id, undoable: true, origin: .app)
        let gate = Gate()
        h.server.inject(.post, .delay(gate))
        await scheduler.requestFlush(reason: .enqueue)
        await gate.arrival()
        // While it runs: three enqueues, an activation (forced) and a backgrounding (releases holds).
        let second = try await h.log(outbox, minutes: 1)
        for _ in 0..<3 { await scheduler.requestFlush(reason: .enqueue) }
        await scheduler.requestFlush(reason: .activation)
        await scheduler.requestFlush(reason: .background)
        #expect(await scheduler.started == [OutboxFlushReason.enqueue.policy])
        gate.open()
        await scheduler.waitUntilIdle()

        let merged = OutboxFlushPolicy(force: true, leaseWait: .seconds(30), releasesAllHolds: true)
        #expect(await scheduler.started == [OutboxFlushReason.enqueue.policy, merged])
        #expect(h.server.entry(first) != nil && h.server.entry(second) != nil)
        // Only the follow-up released the hold (the first flush's hold hadn't passed).
        #expect(h.server.entry(entry.id) == nil && h.server.count(.delete) == 1)
        #expect(try h.items.isEmpty)

        // With nothing running, one request is one flush.
        await scheduler.requestFlush(reason: .timer)
        await scheduler.waitUntilIdle()
        #expect(await scheduler.started.count == 3)
    }

    @Test func aFailedDeleteRejectsFurtherWritesAndLeavesTheQueueAlone() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let entry = try h.seedEntry()
        try await outbox.deleteEntry(id: entry.id, topicId: h.topic.id, undoable: false, origin: .app)
        h.server.inject(.delete, .respond(header(FakeServer.problem(422, "invalid_request", "no"))))
        _ = try await outbox.flushNow()
        let before = try h.items
        #expect(before.single?.state == .failed && before.single?.kind == .entryDelete)
        await #expect(throws: OutboxError.entryDeleted) {
            try await outbox.updateEntry(id: entry.id, topicId: h.topic.id, patch: h.patch(notes: "x"), origin: .app)
        }
        await #expect(throws: OutboxError.entryDeleted) {
            try await outbox.deleteEntry(id: entry.id, topicId: h.topic.id, undoable: true, origin: .app)
        }
        await #expect(throws: OutboxError.entryDeleted) {
            try await outbox.deleteEntry(id: entry.id, topicId: h.topic.id, undoable: false, origin: .app)
        }
        #expect(try await outbox.undoLog(entryId: entry.id, origin: .app) == .nothingToDo)
        #expect(try h.items == before)
    }

    @Test func aCreateSendsTheSourceOfItsOrigin() async throws {
        let h = try OutboxHarness()
        let widget = try h.process("widget:1")
        let id = UUID()
        var body = h.create()
        body.source = "ios"  // what a shared form might put there
        try await widget.createEntry(id: id, topic: h.ref, body: body, origin: .widget)
        #expect(try h.view(id)?.entry.source == "ios.widget")
        // Even a payload written with another source (an older build) is sent with the origin's.
        let raw = UUID()
        try h.write { db in
            _ = try OutboxStorage.append(
                db, NewOutboxItem(id: raw, payload: .entryCreate(topic: h.ref, body: body), origin: .siri),
                now: h.wall.now())
        }
        _ = try await widget.flushNow()
        let sources = h.server.requests.compactMap { $0.json?["source"] as? String }
        #expect(sources == ["ios.widget", "ios.siri"])
        #expect(h.server.entry(id)?.source == "ios.widget" && h.server.entry(raw)?.source == "ios.siri")
    }

    @Test func backgroundReleasesEveryHoldBeforeFlushing() async throws {
        let h = try OutboxHarness()
        let scheduler = OutboxFlushScheduler(outbox: h.outbox())
        let entry = try h.seedEntry()
        try await scheduler.outbox.deleteEntry(id: entry.id, topicId: h.topic.id, undoable: true, origin: .app)
        await scheduler.flushNow(reason: .background)
        #expect(try h.server.entry(entry.id) == nil && h.items.isEmpty)
    }

    /// `sendNow`'s outcomes (outbox.md §10). Waits are generous: each one ends at the outcome.
    @Test func sendNowReportsEachOutcome() async throws {
        let h = try OutboxHarness()
        let scheduler = OutboxFlushScheduler(outbox: h.outbox())
        let sent = try await h.log(scheduler.outbox)
        #expect(await scheduler.sendNow(itemId: sent.wireString, wait: .seconds(30)) == .sent)

        let rejected = try await h.log(scheduler.outbox, minutes: 1)
        h.server.inject(.post, .respond(header(FakeServer.problem(422, "invalid_answers", "mood is required"))))
        guard case .failed(let info) = await scheduler.sendNow(itemId: rejected.wireString, wait: .seconds(30)) else {
            Issue.record("a 422 is .failed")
            return
        }
        #expect(info?.message == "Mood is required" && info?.status == 422)
        try await scheduler.outbox.discard(itemId: rejected.wireString, origin: .app)

        // The id is reserved on the server: with no later delete here, the create fails
        // `deleted_elsewhere` (§5.2).
        let reserved = try await h.log(scheduler.outbox, minutes: 2)
        h.server.deleteEntry(reserved)
        guard case .failed(let gone) = await scheduler.sendNow(itemId: reserved.wireString, wait: .seconds(30)) else {
            Issue.record("a create whose id is reserved is .failed")
            return
        }
        #expect(gone?.message == "Deleted on another device")
        try await scheduler.outbox.discard(itemId: reserved.wireString, origin: .app)

        // Gone with a tombstone (retired by a later delete): never recorded.
        let retired = try await h.log(scheduler.outbox, minutes: 3)
        try h.write { db in
            try ServerLayer.applyDeletion(db, kind: .entry, id: retired, topicId: h.topic.id, seq: nil)
            _ = try OutboxStorage.delete(db, id: retired.wireString)
        }
        #expect(await scheduler.sendNow(itemId: retired.wireString, wait: .seconds(30)) == .retired)

        let offline = try await h.log(scheduler.outbox, minutes: 4)
        h.server.inject(.post, .lose(.unreachable("offline")))
        #expect(await scheduler.sendNow(itemId: offline.wireString, wait: .seconds(30)) == .queued)
        #expect(try h.item(offline)?.state == .pending)
    }

}

/// The real-time cases of `OutboxEngineTests` (see `TimingTests`).
extension TimingTests {
    @Suite struct OutboxEngineTiming {
        @Test func leasePollingNeverAttemptsPastTheRequestDeadline() async throws {
            let h = try OutboxHarness()
            let outbox = h.outbox()
            try await h.log(outbox)
            // No time for requests at all: not even one attempt, though the lease is free.
            for leaseWait in [Duration.zero, .seconds(1)] {
                #expect(try await outbox.flush(force: true, budget: .zero, leaseWait: leaseWait).ending == .busy)
                #expect(try h.lease().owner == nil)
            }
            // Held elsewhere: polling stops at the request deadline (0.7 s of a 1 s budget), not
            // at the 5 s lease wait, and the flush ends without the lease.
            let holder = try #require(try await h.store.leases.tryAcquire(.flush, owner: "widget:9"))
            let polled = try await outbox.flush(force: true, budget: .seconds(1), leaseWait: .seconds(5))
            #expect(polled.ending == .busy)
            #expect(try #require(polled.elapsed) <= .seconds(1))
            #expect(try h.lease().owner == "widget:9" && h.server.requests.isEmpty)
            _ = try await h.store.leases.release(holder)
        }

        /// The enqueue's own flush often reaches the item before `sendNow` does. An attempt that had
        /// already failed, or that is in flight and then fails, still ends the wait at once.
        @Test func sendNowSeesAnAttemptThatStartedBeforeIt() async throws {
            let h = try OutboxHarness()
            let scheduler = OutboxFlushScheduler(outbox: h.outbox())

            // (a) Already attempted and back in the queue.
            let failed = try await h.log(scheduler.outbox)
            h.server.inject(.post, .lose(.unreachable("offline")))
            _ = try await scheduler.outbox.flushNow()
            #expect(try h.item(failed)?.attempts == 1)
            var started = ContinuousClock.now
            #expect(await scheduler.sendNow(itemId: failed.wireString, wait: .seconds(30)) == .queued)
            #expect(ContinuousClock.now - started < .seconds(5))

            // (b) In flight when sendNow starts; then the server fails it (uncertain).
            let claimed = try await h.log(scheduler.outbox, minutes: 1)
            let gate = Gate()
            h.server.inject(.post, .delay(gate, override: header(FakeServer.problem(503, "internal_error", "down"))))
            let flush = background { try await scheduler.outbox.flushNow() }
            await gate.arrival()
            #expect(try h.item(claimed)?.state == .inFlight)
            started = ContinuousClock.now
            let waiting = Task { await scheduler.sendNow(itemId: claimed.wireString, wait: .seconds(30)) }
            gate.open()
            #expect(await waiting.value == .queued)
            #expect(ContinuousClock.now - started < .seconds(5))
            _ = try await flush.value
        }

        @Test func sendNowReportsSentOrQueued() async throws {
            let h = try OutboxHarness()
            let scheduler = OutboxFlushScheduler(outbox: h.outbox())
            let sent = try await h.log(scheduler.outbox)
            #expect(await scheduler.sendNow(itemId: sent.wireString, wait: .seconds(2.5)) == .sent)
            // Offline: "queued" as soon as the attempt fails, like the PWA, not after the full wait.
            let queued = try await h.log(scheduler.outbox, minutes: 1)
            h.server.inject(.post, .lose(.unreachable("offline")))
            let started = ContinuousClock.now
            #expect(await scheduler.sendNow(itemId: queued.wireString, wait: .seconds(10)) == .queued)
            #expect(ContinuousClock.now - started < .seconds(5))
        }
    }
}
