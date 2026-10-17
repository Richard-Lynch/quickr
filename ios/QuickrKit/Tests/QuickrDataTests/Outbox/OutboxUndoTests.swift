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

    @Test("16c · a 201 that lands while the task is cancelled is kept: acked, not uncertain")
    func case16AnswerDuringCancellation() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let id = try await h.log(outbox)
        h.server.inject(.post, .answerOnCancel(Gate()))
        let flush = background { try await outbox.flushNow() }
        try await waitUntil { h.server.requests.count == 1 }
        flush.cancel()
        let report = try await flush.value
        #expect(report.ending == .cancelled && report.acked == 1)
        #expect(try h.items.isEmpty && h.view(id)?.syncState == .synced)
        #expect(h.server.calls == ["POST /api/v1/topics/\(h.topic.id.wireString)/entries"] && h.server.entry(id) != nil)
        #expect(try h.lease().owner == nil)
    }

    @Test("16d · a 422 that lands while the task is cancelled fails the item")
    func case16TerminalDuringCancellation() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let id = try await h.log(outbox)
        let problem = header(FakeServer.problem(422, "invalid_answers", "mood is required"))
        h.server.inject(.post, .answerOnCancel(Gate(), override: problem))
        let flush = background { try await outbox.flushNow() }
        try await waitUntil { h.server.requests.count == 1 }
        flush.cancel()
        #expect(try await flush.value.ending == .cancelled)
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
        #expect(report.ending == .budgetExhausted && report.acked == 1)
        #expect(try h.item(id) == nil && h.server.entry(id) != nil)
        // The pass stops at the deadline: the next item is never claimed.
        #expect(try h.item(second)?.attempts == 0 && h.server.requests.count == 1)
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

/// Polls `condition` for up to 5 s.
func waitUntil(_ condition: @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("condition not met within 5 s")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
