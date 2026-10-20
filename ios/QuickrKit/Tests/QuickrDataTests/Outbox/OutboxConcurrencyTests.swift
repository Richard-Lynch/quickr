import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// outbox.md §13 multi-process cases 8–10, 23, 32, 34, 39, 40, 45, 46, simulated in one process: two
/// `Outbox` instances on two pools over one file, sharing the lease clock. "SIGSTOP" is a request
/// held in the network by a `Gate` while lease time passes; "SIGCONT" opens it. The real
/// multi-process runs are in `MultiProcess/OutboxMultiProcessTests`.
@Suite(.timeLimit(.minutes(2))) struct OutboxConcurrencyTests {
    @Test("8, 9 · (single process) lock expiry: B recovers and resends; A's late 201 writes nothing")
    func case08And09() async throws {
        let h = try OutboxHarness()
        let a = h.outbox(owner: "app:A")
        let b = try h.process("widget:B")
        let id = try await h.log(a)
        let gate = Gate()
        h.server.inject(.post, .delay(gate))
        let flushA = background { try await a.flushNow(budget: .seconds(120)) }
        await gate.arrival()
        h.clock.advance(by: .seconds(31))  // A is stopped past the TTL

        let reportB = try await b.flushNow()
        #expect(try reportB.acked == 1 && h.items.isEmpty && h.server.entry(id) != nil)
        let before = try h.snapshot()

        gate.open()  // A resumes and gets its 201
        let reportA = try await flushA.value
        #expect(reportA.ending == .superseded && reportA.acked == 0)
        #expect(try h.snapshot() == before)
        #expect(h.server.count(.post) == 2 && h.server.with { $0.entries.count } == 1)
    }

    @Test("9b · (single process) a superseded sender's late 422 doesn't fail the item B now holds in flight")
    func case09LateTerminal() async throws {
        let h = try OutboxHarness()
        let a = h.outbox(owner: "app:A")
        let b = try h.process("widget:B")
        let id = try await h.log(a)
        let gateA = Gate()
        let gateB = Gate()
        h.server.inject(.post, .delay(gateA, override: header(FakeServer.problem(422, "invalid_answers", "late"))))
        h.server.inject(.post, .delay(gateB))
        let flushA = background { try await a.flushNow(budget: .seconds(120)) }
        await gateA.arrival()
        h.clock.advance(by: .seconds(31))
        let flushB = background { try await b.flushNow(budget: .seconds(120)) }
        await gateB.arrival()  // B recovered the item and has it in flight
        let before = try h.snapshot()

        gateA.open()
        #expect(try await flushA.value.ending == .superseded)
        #expect(try h.snapshot() == before)
        #expect(try h.item(id)?.state == .inFlight)
        gateB.open()
        #expect(try await flushB.value.acked == 1 && h.item(id) == nil)
    }

    @Test("S2 · the claim-token fence alone discards an outcome, even with the flush lease still valid")
    func claimTokenFence() async throws {
        let h = try OutboxHarness()
        let a = h.outbox(owner: "app:A")
        let id = try await h.log(a)
        let gate = Gate()
        h.server.inject(.post, .delay(gate, override: header(FakeServer.problem(422, "invalid_answers", "late"))))
        let flush = background { try await a.flushNow() }
        await gate.arrival()
        // Another claim of the item, under the same valid lease (a defence-in-depth check: no
        // reachable path does this without also changing the lease token).
        try h.write { db in
            try db.execute(sql: "UPDATE outbox_item SET claim_token = 'other' WHERE id = ?", arguments: [id.wireString])
        }
        let before = try h.snapshot()
        gate.open()
        #expect(try await flush.value.ending == .superseded)
        #expect(try h.snapshot() == before)
        #expect(try h.item(id)?.state == .inFlight && h.item(id)?.claimToken == "other")
    }

    @Test("10 · (single process) the holder dies: after the TTL, recovery, resend, ack")
    func case10() async throws {
        let h = try OutboxHarness()
        let a = h.outbox(owner: "app:A")
        let b = try h.process("widget:B")
        let id = try await h.log(a)
        let gate = Gate()
        h.server.inject(.post, .delay(gate))
        let flushA = background { try await a.flushNow(budget: .seconds(120)) }
        await gate.arrival()  // A never comes back
        h.clock.advance(by: .seconds(29))
        #expect(try await b.flushNow().ending == .busy)
        h.clock.advance(by: .seconds(1))
        let report = try await b.flushNow()
        #expect(try report.acked == 1 && h.item(id) == nil && h.server.entry(id) != nil)
        gate.open()
        _ = try await flushA.value
    }

    @Test(
        "23 · (single process) an update while the create is in flight elsewhere is appended; the create is untouched")
    func case23() async throws {
        let h = try OutboxHarness()
        let a = h.outbox(owner: "app:A")
        let b = try h.process("widget:B")
        let id = try await h.log(a)
        let gate = Gate()
        h.server.inject(.post, .delay(gate))
        let flushA = background { try await a.flushNow() }
        await gate.arrival()
        let create = try #require(try h.item(id))
        guard
            case .appended = try await b.updateEntry(
                id: id, topicId: h.topic.id, patch: h.patch(notes: "n"), origin: .widget)
        else {
            Issue.record("not appended")
            return
        }
        #expect(try h.item(id)?.payloadJSON == create.payloadJSON && h.item(id)?.rowVersion == create.rowVersion)
        gate.open()
        _ = try await flushA.value
        #expect(try h.server.entry(id)?.notes == "n" && h.items.isEmpty)
    }

    @Test("32 · (single process) a superseded sender's late stale_revision doesn't rebase or resend")
    func case32() async throws {
        let h = try OutboxHarness()
        let a = h.outbox(owner: "app:A")
        let b = try h.process("widget:B")
        let entry = try h.seedEntry(revision: 3)
        try await a.updateEntry(id: entry.id, topicId: h.topic.id, patch: h.patch(notes: "u1"), origin: .app)
        let gate = Gate()
        h.server.inject(.patch, .delay(gate))
        let flushA = background { try await a.flushNow(budget: .seconds(120)) }
        await gate.arrival()  // A's PATCH (expected 3) is held in the network
        try await b.updateEntry(id: entry.id, topicId: h.topic.id, patch: h.patch(notes: "u2"), origin: .widget)
        h.clock.advance(by: .seconds(31))

        let reportB = try await b.flushNow()
        #expect(reportB.acked == 2 && h.server.entry(entry.id)?.revision == 5)
        let before = try h.snapshot()

        gate.open()  // A's original PATCH lands late: 409 stale_revision
        let reportA = try await flushA.value
        #expect(reportA.ending == .superseded)
        #expect(h.server.handled.contains("PATCH /api/v1/entries/\(entry.id.wireString) → 409"))
        #expect(h.server.count(.patch) == 3 && h.server.count(.get) == 0)
        #expect(!h.server.requests.contains { $0.method == .patch && $0.expectedRevision == 5 })
        #expect(h.server.entry(entry.id)?.revision == 5 && h.server.entry(entry.id)?.notes == "u2")
        #expect(try h.snapshot() == before)
    }

    @Test("34 · (single process) B takes over between A's refetch and rebase: A's step 3 fails, B's state stands")
    func case34() async throws {
        let h = try OutboxHarness()
        let a = h.outbox(owner: "app:A")
        let b = try h.process("widget:B")
        let entry = try h.seedEntry(revision: 3)
        try await a.updateEntry(id: entry.id, topicId: h.topic.id, patch: h.patch(mood: 1), origin: .app)
        h.server.edit(entry.id)  // revision 4 elsewhere
        let gate = Gate()
        h.server.inject(.get, .delay(gate))
        let flushA = background { try await a.flushNow(budget: .seconds(120)) }
        await gate.arrival()  // A is between the GET and the rebase
        h.clock.advance(by: .seconds(31))

        let reportB = try await b.flushNow()
        #expect(try reportB.acked == 1 && h.server.entry(entry.id)?.revision == 5 && h.items.isEmpty)
        let before = try h.snapshot()

        gate.open()
        let reportA = try await flushA.value
        #expect(reportA.ending == .superseded)
        #expect(try h.snapshot() == before)
        #expect(h.server.count(.patch) == 3)
    }

    @Test("39 · (single process) update and delete for E from two processes serialise in either order")
    func case39() async throws {
        // The update commits first: it stays queued while the delete is held, then §8.3 drops it.
        do {
            let h = try OutboxHarness()
            let app = h.outbox(owner: "app:1")
            let widget = try h.process("widget:1")
            let entry = try h.seedEntry()
            try await app.updateEntry(id: entry.id, topicId: h.topic.id, patch: h.patch(notes: "x"), origin: .app)
            try await widget.deleteEntry(id: entry.id, topicId: h.topic.id, undoable: true, origin: .widget)
            #expect(try h.items.map(\.kind) == [.entryUpdate, .entryDelete])
            h.clock.advance(by: Outbox.holdDuration)
            _ = try await app.flushNow()
            #expect(try h.server.requests.map(\.method) == [.delete] && h.items.isEmpty)
        }
        // The delete commits first: C0 rejects the update.
        do {
            let h = try OutboxHarness()
            let app = h.outbox(owner: "app:1")
            let widget = try h.process("widget:1")
            let entry = try h.seedEntry()
            try await widget.deleteEntry(id: entry.id, topicId: h.topic.id, undoable: true, origin: .widget)
            await #expect(throws: OutboxError.entryDeleted) {
                try await app.updateEntry(id: entry.id, topicId: h.topic.id, patch: h.patch(notes: "x"), origin: .app)
            }
        }
        // Truly concurrent: exactly one delete each time, and SQLITE_BUSY never surfaces.
        let h = try OutboxHarness()
        let app = h.outbox(owner: "app:1")
        let widget = try h.process("widget:1")
        for _ in 0..<20 {
            let entry = try h.seedEntry()
            async let update = updateUnlessDeleted(app, h, entry.id)
            async let delete = widget.deleteEntry(id: entry.id, topicId: h.topic.id, undoable: true, origin: .widget)
            _ = try await (update, delete)
            let items = try h.read { db in
                try OutboxStorage.items(db, entityKind: .entry, entityId: entry.id.wireString)
            }
            #expect(items.filter { $0.kind == .entryDelete }.count == 1)
        }
    }

    private func updateUnlessDeleted(_ outbox: Outbox, _ h: OutboxHarness, _ id: UUID) async throws {
        do {
            try await outbox.updateEntry(id: id, topicId: h.topic.id, patch: h.patch(notes: "x"), origin: .app)
        } catch OutboxError.entryDeleted {}
    }

    @Test("45 · (single process) the wall clock set back 3 h doesn't delay a takeover")
    func case45() async throws {
        let h = try OutboxHarness()
        let a = h.outbox(owner: "app:A")
        let b = try h.process("widget:B")
        let id = try await h.log(a)
        let gate = Gate()
        h.server.inject(.post, .delay(gate))
        let flushA = background { try await a.flushNow(budget: .seconds(120)) }
        await gate.arrival()
        h.wall.advance(by: -3 * 3600)
        h.clock.advance(by: .seconds(30))
        #expect(try await b.flushNow().acked == 1 && h.item(id) == nil)
        gate.open()
        _ = try await flushA.value
    }

    @Test("46 · (single process) the wall clock set forward 3 h gives no early takeover")
    func case46() async throws {
        let h = try OutboxHarness()
        let a = h.outbox(owner: "app:A")
        let b = try h.process("widget:B")
        let id = try await h.log(a)
        let gate = Gate()
        h.server.inject(.post, .delay(gate))
        let flushA = background { try await a.flushNow(budget: .seconds(120)) }
        await gate.arrival()
        h.wall.advance(by: 3 * 3600)
        h.clock.advance(by: .seconds(10))
        #expect(try await b.flushNow().ending == .busy)
        gate.open()
        #expect(try await flushA.value.acked == 1 && h.item(id) == nil)
    }
}

/// The real-time cases of `OutboxConcurrencyTests` (see `TimingTests`).
extension TimingTests {
    @Suite struct OutboxConcurrencyTiming {
        @Test("40 · (single process) the widget logs while the app's request is slow: it gives up, the app sends it")
        func case40() async throws {
            let h = try OutboxHarness()
            let app = h.outbox(owner: "app:1")
            let widget = try h.process("widget:1")
            let first = try await h.log(app)
            let gate = Gate()
            h.server.inject(.post, .delay(gate))
            let flushApp = background { try await app.flushNow() }
            await gate.arrival()
            let logged = try await h.log(widget)
            let policy = OutboxFlushPolicy.extensionFlush(budget: .seconds(4))
            let report = try await widget.flush(force: policy.force, budget: policy.budget, leaseWait: policy.leaseWait)
            #expect(report.ending == .busy)
            #expect(try #require(report.elapsed) < .seconds(4))
            #expect(try h.item(logged)?.state == .pending)
            gate.open()
            _ = try await flushApp.value
            #expect(try h.server.entry(first) != nil && h.server.entry(logged) != nil && h.items.isEmpty)
        }
    }
}
