import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// outbox.md §13 cases 11–16, 29–31, 51–54, 59–61: Undo of a log (`cancelCreate`, §9.1),
/// delete-with-undo (§9.2), S8 and suspension mid-send.
@Suite struct OutboxUndoTests {
    @Test("11 · lost response then Undo: only a standalone DELETE is sent")
    func case11() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let id = try await h.log(outbox)
        h.server.inject(.post, .lose(.timedOut(requestStarted: true)))
        _ = try await outbox.flushNow()
        #expect(try h.item(id)?.state == .uncertain && h.server.entry(id) != nil)

        #expect(try await outbox.undoLog(entryId: id, origin: .app) == .deleteQueued)
        #expect(try h.view(id) == nil)
        let delete = try #require(try h.items.single)
        #expect(delete.kind == .entryDelete && !delete.cancelsCreate)
        _ = try await outbox.flushNow()
        #expect(
            h.server.calls == [
                "POST /api/v1/topics/\(h.topic.id.wireString)/entries", "DELETE /api/v1/entries/\(id.wireString)",
            ])
        #expect(try h.server.entry(id) == nil && h.items.isEmpty && h.view(id) == nil)
    }

    @Test("12 · (fake server) a late POST after the undo DELETE gets entry_deleted")
    func case12() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let id = try await h.log(outbox)
        h.server.inject(.post, .respond(HTTPResponse(status: 502)))  // the POST is "still in the network"
        _ = try await outbox.flushNow()
        let post = try #require(h.server.requests.first)
        try await outbox.undoLog(entryId: id, origin: .app)
        _ = try await outbox.flushNow()
        let late = h.server.replay(post)
        #expect(late.status == 409)
        #expect(try Endpoints.decodeProblem(late.body).code == .entryDeleted)
        #expect(h.server.entry(id) == nil)
    }

    @Test("13 · Undo while the create is in flight: the POST is acked, then the DELETE follows")
    func case13() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let id = try await h.log(outbox)
        let gate = Gate()
        h.server.inject(.post, .delay(gate))
        let flush = background { try await outbox.flushNow() }
        await gate.arrival()
        #expect(try await outbox.undoLog(entryId: id, origin: .app) == .deleteQueued)
        #expect(try h.view(id) == nil)
        let delete = try #require(try h.items.last)
        #expect(delete.kind == .entryDelete && delete.cancelsCreate)
        gate.open()
        let report = try await flush.value
        #expect(report.acked == 2)
        #expect(h.server.count(.post) == 1 && h.server.count(.delete) == 1)
        #expect(try h.server.entry(id) == nil && h.items.isEmpty && h.view(id) == nil)
    }

    @Test("14 · Undo of a never-attempted create removes it; no requests")
    func case14() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let id = try await h.log(outbox)
        #expect(try await outbox.undoLog(entryId: id, origin: .app) == .removed)
        #expect(try h.items.isEmpty)
        _ = try await outbox.flushNow()
        #expect(h.server.requests.isEmpty)
    }

    @Test("15 · Undo of E leaves the later create F alone; only POST F is sent")
    func case15() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let e = try await h.log(outbox)
        let f = try await h.log(outbox, minutes: 1)
        #expect(try await outbox.undoLog(entryId: e, origin: .app) == .removed)
        #expect(try h.items.map(\.id) == [f.wireString])
        _ = try await outbox.flushNow()
        #expect(h.server.calls == ["POST /api/v1/topics/\(h.topic.id.wireString)/entries"])
        #expect(h.server.entry(f) != nil && h.server.entry(e) == nil)
    }

    @Test("16 · suspension mid-send: the request is cancelled, the item uncertain, the lease released")
    func case16() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let id = try await h.log(outbox)
        let gate = Gate()
        h.server.inject(.post, .delay(gate))
        let flush = background { try await outbox.flushNow() }
        await gate.arrival()
        flush.cancel()  // the background task's expiration handler
        let report = try await flush.value
        #expect(report.ending == .cancelled)
        #expect(gate.abandoned)
        let item = try #require(try h.item(id))
        #expect(item.state == .uncertain && item.maybeDelivered && item.claimToken == nil)
        #expect(try h.lease().owner == nil)
        gate.open()
    }

    @Test("16b · a budget expiring mid-send does the same")
    func case16Budget() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let id = try await h.log(outbox)
        let gate = Gate()
        h.server.inject(.post, .delay(gate))
        // Generous enough for the claim and send to happen first under a loaded test run.
        let report = try await outbox.flush(force: true, budget: .seconds(3))
        #expect(gate.abandoned)
        #expect(report.ending == .budgetExhausted)
        #expect(try h.item(id)?.state == .uncertain && h.item(id)?.maybeDelivered == true)
        #expect(try h.lease().owner == nil)
        gate.open()
    }

    @Test("16c · an expiration cancel releases at once: a 201 landing just after is reconciled next time")
    func case16AnswerDuringCancellation() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox(shutdownGrace: .seconds(3))
        let id = try await h.log(outbox)
        h.server.inject(.post, .answerOnCancel(Gate()))
        let flush = background { try await outbox.flushNow() }
        try await waitUntil { h.server.requests.count == 1 }
        let cancelled = ContinuousClock.now
        flush.cancel()
        let report = try await flush.value
        // No grace on cancellation: measured to the flush's own end, not to this task's resumption.
        #expect(try #require(report.endedAt) - cancelled < timingSlack(.milliseconds(500)))
        #expect(report.ending == .cancelled && report.acked == 0)
        #expect(try h.item(id)?.state == .uncertain && h.lease().owner == nil)
        #expect(h.server.entry(id) != nil)  // the POST committed
        // The next flush resends; the POST replay returns the existing entry.
        #expect(try await outbox.flushNow().acked == 1)
        #expect(try h.items.isEmpty && h.view(id)?.syncState == .synced)
        #expect(h.server.count(.post) == 2 && h.server.with { $0.entries.count } == 1)
    }

    @Test("16d · a 422 that lands within the grace after the request deadline fails the item")
    func case16TerminalWithinGrace() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let id = try await h.log(outbox)
        let problem = header(FakeServer.problem(422, "invalid_answers", "mood is required"))
        h.server.inject(.post, .answerOnCancel(Gate(), override: problem))
        let report = try await outbox.flush(force: true, budget: .seconds(2))
        // The answer came inside the budget.
        #expect(try #require(report.elapsed) <= .seconds(2) + timingSlack(.milliseconds(150)))
        #expect(report.ending == .budgetExhausted && report.failed == 1)
        let item = try #require(try h.item(id))
        #expect(item.state == .failed && item.failureReason == .rejected && !item.maybeDelivered)
        #expect(try item.errorInfo?.message == "Mood is required")
        #expect(h.server.requests.count == 1 && h.server.entry(id) == nil)
    }

    @Test("16e · a 201 that lands as the budget expires is kept")
    func case16AnswerAtDeadline() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let id = try await h.log(outbox)
        let second = try await h.log(outbox, minutes: 1)
        h.server.inject(.post, .answerOnCancel(Gate()))
        let report = try await outbox.flush(force: true, budget: .seconds(2))
        // The answer came inside the budget.
        #expect(try #require(report.elapsed) <= .seconds(2) + timingSlack(.milliseconds(150)))
        #expect(report.ending == .budgetExhausted && report.acked == 1)
        #expect(try h.item(id) == nil && h.server.entry(id) != nil)
        // The pass stops at the deadline: the next item is never claimed.
        #expect(try h.item(second)?.attempts == 0 && h.server.requests.count == 1)
    }

    @Test("16f · a sender that ignores cancellation can't hold a budget-expired flush past the grace")
    func case16StuckSenderAtDeadline() async throws {
        let h = try OutboxHarness()
        // Budget 5 s: the grace is 1 s (capped at 20 % of the budget, below the 3 s shutdown grace)
        // and requests stop at 3.75 s, leaving a loaded machine ample time to have the POST in
        // flight when the deadline passes; that is the premise, checked first.
        let outbox = h.outbox(shutdownGrace: .seconds(3))
        let id = try await h.log(outbox)
        let gate = Gate()
        h.server.inject(.post, .hang(gate))
        let report = try await outbox.flush(force: true, budget: .seconds(5))
        try #require(h.server.requests.count == 1, "the POST was in flight when the request deadline passed")
        // The grace and the release fit inside the budget, by the flush's own clock.
        let elapsed = try #require(report.elapsed)
        #expect(elapsed <= .seconds(5) + timingSlack(.milliseconds(250)), "elapsed \(elapsed)")
        #expect(report.ending == .budgetExhausted)
        let item = try #require(try h.item(id))
        #expect(item.state == .uncertain && item.maybeDelivered && item.claimToken == nil, "\(item)")
        #expect(try h.lease().owner == nil)
        // The stuck request finally completes: nobody listens, nothing is written.
        let before = try h.snapshot()
        gate.open()
        try await waitUntil { h.server.handled.count == 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(try h.snapshot() == before)
    }

    @Test("16g · an expiration handler's cancel ends the flush and frees the scheduler despite a stuck sender")
    func case16StuckSenderAtExpiration() async throws {
        let h = try OutboxHarness()
        let scheduler = OutboxFlushScheduler(outbox: h.outbox(shutdownGrace: .seconds(3)))
        let id = try await h.log(scheduler.outbox)
        let gate = Gate()
        h.server.inject(.post, .hang(gate))
        await scheduler.requestFlush(reason: .background)
        await gate.arrival()
        let cancelled = ContinuousClock.now
        await scheduler.cancel()
        let report = await scheduler.waitUntilIdle()
        // Released at once, no grace: measured to the flush's own end.
        #expect(try #require(report?.endedAt) - cancelled < timingSlack(.milliseconds(500)))
        #expect(report?.ending == .cancelled)
        #expect(try h.item(id)?.state == .uncertain && h.lease().owner == nil)
        gate.open()
    }

    @Test("16h · a stuck sender's late answer after another flusher took over is never applied")
    func case16StuckSenderAfterTakeover() async throws {
        let h = try OutboxHarness()
        let a = h.outbox(owner: "app:A", shutdownGrace: .milliseconds(300))
        let b = try h.process("widget:B")
        let id = try await h.log(a)
        try await h.log(a, minutes: 1)
        let gate = Gate()
        h.server.inject(.post, .hang(gate))
        let flushA = background { try await a.flushNow() }
        await gate.arrival()
        flushA.cancel()
        #expect(try await flushA.value.ending == .cancelled)
        // B takes over at once (A released the lease) and resends the uncertain create.
        let report = try await b.flushNow()
        #expect(report.acked == 2 && h.server.count(.post) == 3)
        let before = try h.snapshot()
        gate.open()  // A's original POST lands now and is answered: 201, the existing entry
        try await waitUntil { h.server.handled.count == 3 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(try h.snapshot() == before)
        #expect(h.server.with { $0.entries.count } == 2 && h.server.entry(id) != nil)
    }

    @Test("16i · the server commits before the grace ends but answers after it: the next flush reconciles")
    func case16CommittedAnswerAfterGrace() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let id = try await h.log(outbox)
        h.server.inject(.post, .commitThenDeliver(after: .seconds(3)))
        let report = try await outbox.flush(force: true, budget: .seconds(2))
        #expect(try #require(report.elapsed) <= .seconds(2) + timingSlack(.milliseconds(250)))
        #expect(report.ending == .budgetExhausted)
        #expect(try h.item(id)?.state == .uncertain && h.server.entry(id) != nil)
        // The resend is an idempotent replay: one entry, an empty outbox.
        #expect(try await outbox.flushNow().acked == 1)
        #expect(try h.items.isEmpty && h.view(id)?.syncState == .synced)
        #expect(h.server.with { $0.entries.count } == 1)
    }

    @Test("16j · same, reconciled by a pull instead: the page acks the create")
    func case16CommittedAnswerPulled() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let id = try await h.log(outbox)
        h.server.inject(.post, .commitThenDeliver(after: .seconds(3)))
        _ = try await outbox.flush(force: true, budget: .seconds(2))
        try h.applyPage(try #require(h.server.entry(id)))
        #expect(try h.items.isEmpty && h.viewEntries().count == 1 && h.view(id)?.syncState == .synced)
        #expect(try await outbox.flushNow().requests == 0 && h.server.count(.post) == 1)
    }

    @Test("16k · a stale_revision inside the grace starts no refetch; the flush still ends in budget")
    func case16StaleRevisionInsideGrace() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let entry = try h.seedEntry(revision: 3)
        try await outbox.updateEntry(id: entry.id, topicId: h.topic.id, patch: h.patch(notes: "x"), origin: .app)
        // Budget 2 s: requests stop at 1.4 s, the grace ends at 1.8 s. The PATCH is answered
        // stale_revision at 1.7 s, inside the grace; a refetch, if one started, would never answer.
        let stale = header(FakeServer.problem(409, "stale_revision", "stale revision"))
        h.server.inject(.patch, .answerOnCancel(Gate(), override: stale, after: .milliseconds(300)))
        let stuck = Gate()
        h.server.inject(.get, .hang(stuck))
        let report = try await outbox.flush(force: true, budget: .seconds(2))
        #expect(try #require(report.elapsed) <= .seconds(2) + timingSlack(.milliseconds(100)))
        #expect(report.ending == .budgetExhausted)
        #expect(h.server.count(.patch) == 1 && h.server.count(.get) == 0)
        let item = try #require(try h.items.single)
        #expect(item.state == .uncertain && item.claimToken == nil && item.baseRevision == 3)
        #expect(try h.lease().owner == nil)
        stuck.open()
    }

    @Test("29 · Undo of a held delete restores the queued create byte for byte")
    func case29() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let id = try await h.log(outbox)
        try await outbox.updateEntry(id: id, topicId: h.topic.id, patch: h.patch(notes: "edited"), origin: .app)
        let before = try #require(try h.item(id))
        try await outbox.deleteEntry(id: id, topicId: h.topic.id, undoable: true, origin: .app)
        #expect(try h.view(id) == nil)
        h.clock.advance(by: .seconds(3))
        #expect(try await outbox.undoDelete(entryId: id) == .restored)
        #expect(try h.items == [before])
        let view = try #require(try h.view(id))
        #expect(view.entry.notes == "edited" && view.syncState == .pending)
    }

    @Test("30 · Undo of a held delete keeps a pending update to a server row")
    func case30() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let entry = try h.seedEntry(revision: 3)
        try await outbox.updateEntry(id: entry.id, topicId: h.topic.id, patch: h.patch(notes: "mine"), origin: .app)
        try await outbox.deleteEntry(id: entry.id, topicId: h.topic.id, undoable: true, origin: .app)
        #expect(try await outbox.undoDelete(entryId: entry.id) == .restored)
        let update = try #require(try h.items.single)
        #expect(update.kind == .entryUpdate && update.baseRevision == 3)
        #expect(try h.view(entry.id)?.entry.notes == "mine")
    }

    @Test("31 · when the hold passes, the unsent create, its update and the delete all go; no requests")
    func case31() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let id = try await h.log(outbox)
        try await outbox.updateEntry(id: id, topicId: h.topic.id, patch: h.patch(notes: "edited"), origin: .app)
        try await outbox.deleteEntry(id: id, topicId: h.topic.id, undoable: true, origin: .app)
        h.clock.advance(by: .seconds(5))
        _ = try await outbox.flush(force: false, budget: .seconds(30))
        #expect(try h.items.count == 2)  // still held
        h.clock.advance(by: .seconds(1))
        _ = try await outbox.flush(force: false, budget: .seconds(30))
        #expect(try h.items.isEmpty && h.server.requests.isEmpty)
        #expect(try await outbox.undoDelete(entryId: id) == .nothingToDo)
    }

    @Test(
        "51 · (fake server) uncertain create with a delayed POST: Undo sends DELETE only; the POST lands as entry_deleted"
    )
    func case51() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let id = try await h.log(outbox)
        let gate = Gate()
        h.server.inject(.post, .delay(gate))
        let flush = background { try await outbox.flushNow() }
        await gate.arrival()
        flush.cancel()  // the client gives up; the POST stays in the network
        _ = try await flush.value
        #expect(try h.item(id)?.state == .uncertain)
        #expect(try await outbox.undoLog(entryId: id, origin: .app) == .deleteQueued)
        _ = try await outbox.flushNow()
        #expect(h.server.count(.delete) == 1 && h.server.count(.post) == 1)
        #expect(h.server.with { $0.deleted.contains(id.wireString) })
        gate.open()  // the delayed POST finally reaches the server
        let late = "POST /api/v1/topics/\(h.topic.id.wireString)/entries → 409"
        try await waitUntil { h.server.handled.contains(late) }
        #expect(gate.abandoned)
        #expect(try h.server.entry(id) == nil && h.items.isEmpty && h.view(id) == nil)
    }

    @Test("52 · in-flight create cancelled; the POST gets topic_archived: S8 removes it, the DELETE goes alone")
    func case52() async throws {
        try await cancelledCreateFails { h in h.server.setArchived(h.topic.id, true) }
    }

    @Test("53 · same as 52 with a 422")
    func case53() async throws {
        try await cancelledCreateFails(override: header(FakeServer.problem(422, "invalid_answers", "bad")))
    }

    private func cancelledCreateFails(
        override: HTTPResponse? = nil, before: (OutboxHarness) -> Void = { _ in }
    ) async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let id = try await h.log(outbox)
        let gate = Gate()
        h.server.inject(.post, .delay(gate, override: override))
        let flush = background { try await outbox.flushNow() }
        await gate.arrival()
        before(h)
        #expect(try await outbox.undoLog(entryId: id, origin: .app) == .deleteQueued)
        gate.open()
        _ = try await flush.value
        #expect(h.server.count(.delete) == 1)
        #expect(try h.items.isEmpty)  // no failed create left in the sync sheet
        #expect(h.server.entry(id) == nil && h.server.with { $0.deleted.contains(id.wireString) })
    }

    @Test("54 · uncertain create, topic archived meanwhile: Undo sends DELETE only")
    func case54() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let id = try await h.log(outbox)
        h.server.inject(.post, .respond(header(FakeServer.problem(500, "internal_error", "down"))))
        _ = try await outbox.flushNow()
        h.server.setArchived(h.topic.id, true)
        try await outbox.undoLog(entryId: id, origin: .app)
        _ = try await outbox.flushNow()
        #expect(h.server.count(.post) == 1 && h.server.count(.delete) == 1)
        #expect(h.server.requests.last.map { $0.method == .delete } == true)
        #expect(try h.items.isEmpty)
    }

    @Test("59 · (fake server) a committed POST with a garbled 201 is uncertain; Undo deletes it on the server")
    func case59() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let id = try await h.log(outbox)
        h.server.inject(.post, .garble(status: 201, body: Data(#"{"id": "trunc"#.utf8)))
        _ = try await outbox.flushNow()
        #expect(h.server.entry(id) != nil)
        let item = try #require(try h.item(id))
        #expect(item.state == .uncertain && item.maybeDelivered)
        #expect(try await outbox.undoLog(entryId: id, origin: .app) == .deleteQueued)
        _ = try await outbox.flushNow()
        #expect(try h.server.entry(id) == nil && h.items.isEmpty)
    }

    @Test("59b · a 201 EntryOut missing revision is garbled too")
    func case59MissingField() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let id = try await h.log(outbox)
        var json = try #require(
            try JSONSerialization.jsonObject(with: FakeServer.entryJSON(Make.entry(id: id, topicId: h.topic.id)))
                as? [String: Any])
        json["revision"] = nil
        h.server.inject(.post, .garble(status: 201, body: try JSONSerialization.data(withJSONObject: json)))
        _ = try await outbox.flushNow()
        #expect(try h.item(id)?.state == .uncertain && h.item(id)?.maybeDelivered == true)
    }

    @Test("60 · held delete of an unsent create, F queued after it: at release only POST F remains")
    func case60() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let e = try await h.log(outbox)
        let f = try await h.log(outbox, minutes: 1)
        try await outbox.deleteEntry(id: e, topicId: h.topic.id, undoable: true, origin: .app)
        h.clock.advance(by: Outbox.holdDuration)
        _ = try await outbox.flush(force: false, budget: .seconds(30))
        #expect(h.server.calls == ["POST /api/v1/topics/\(h.topic.id.wireString)/entries"])
        #expect(try h.server.entry(f) != nil && h.server.entry(e) == nil && h.items.isEmpty)
    }

    @Test("61 · held delete of an uncertain create: kept while held, then DELETE only")
    func case61() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let id = try await h.log(outbox)
        h.server.inject(.post, .lose(.timedOut(requestStarted: true)))
        _ = try await outbox.flushNow()
        try await outbox.updateEntry(id: id, topicId: h.topic.id, patch: h.patch(notes: "x"), origin: .app)
        let before = try h.items
        try await outbox.deleteEntry(id: id, topicId: h.topic.id, undoable: true, origin: .app)
        #expect(try Array(h.items.prefix(2)) == before)
        h.clock.advance(by: Outbox.holdDuration)
        _ = try await outbox.flush(force: true, budget: .seconds(30))
        #expect(h.server.count(.post) == 1 && h.server.count(.delete) == 1 && h.server.count(.patch) == 0)
        #expect(try h.server.entry(id) == nil && h.items.isEmpty)
    }
}

extension Array {
    /// The single element, or nil.
    var single: Element? { count == 1 ? first : nil }
}

/// Polls `condition` until it holds. `timeout` is a liveness ceiling (so a broken test fails
/// instead of hanging), never the timing under test: generous, because a loaded machine can delay
/// any task. Assert a real bound separately, from the flush's own `startedAt`/`endedAt`.
func waitUntil(timeout: Duration = .seconds(30), _ condition: @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("condition not met within \(timeout)")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
