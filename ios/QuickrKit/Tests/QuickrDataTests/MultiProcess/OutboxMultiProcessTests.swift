// Multi-process tests run on the Mac host only: iOS has no `Process` (sync-protocol.md §13 G5).
#if os(macOS)
import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// outbox.md §13 cases 8–10, 23–24, 32, 34, 39–40, 45–46 and 48 with real processes: each `Outbox`
/// runs in its own `ProcessHelper` child, on its own SQLite connection to the shared file, and
/// sends over loopback HTTP to `FakeServer`. "A is stopped" is a SIGSTOP while its request is
/// held at the server; lease time moves in the shared clock file.
extension MultiProcessTests {
    @Suite struct OutboxMP {
        @Test("8, 9 · MP: A SIGSTOPped past the TTL; B recovers and resends; A's late 201 writes nothing")
        func case08And09() async throws {
            try await OutboxWorld.run { w in
                let a = try await w.world.spawn("app:A")
                let b = try await w.world.spawn("widget:B", open: "extension")
                let id = try await w.log(a)
                let gate = w.world.gate()
                w.server.inject(.post, .delay(gate))
                let flushA = try a.start("flush", ["budgetMs": "120000"])
                try await gate.arrived()
                a.suspend()
                try w.world.leaseClock.advance(by: .seconds(31))

                let reportB = try await b.run("flush")
                #expect(reportB["acked"] == "1" && w.items.isEmpty && w.server.entry(id) != nil)
                #expect(w.item(id) == nil)
                #expect(w.server.requests.count == 2)  // A's POST (held) and B's resend
                let before = try w.snapshot()

                a.resume()
                gate.open()  // A gets its 201 now
                let reportA = try await a.reply(flushA)
                #expect(reportA.result["ending"] == "superseded" && reportA.result["acked"] == "0")
                #expect(try w.snapshot() == before)
                #expect(w.server.count(.post) == 2 && w.server.with { $0.entries.count } == 1)
                #expect(w.server.requests.count == 2)  // nothing after the supersession
                #expect(try await w.store.leases.record(.flush).owner == nil)
            }
        }

        /// 9 with the item still claimable: B holds it in flight when A's late answer (a 422)
        /// arrives. Only A's sender check (lease and claim token) stops A from failing B's item.
        @Test("9b · MP: a SIGSTOPped sender's late 422 doesn't fail the item B now has in flight")
        func case09LateTerminal() async throws {
            try await OutboxWorld.run { w in
                let a = try await w.world.spawn("app:A")
                let b = try await w.world.spawn("widget:B", open: "extension")
                let id = try await w.log(a)
                let gateA = w.world.gate()
                let gateB = w.world.gate()
                w.server.inject(
                    .post, .delay(gateA, override: header(FakeServer.problem(422, "invalid_answers", "late"))))
                w.server.inject(.post, .delay(gateB))
                let flushA = try a.start("flush", ["budgetMs": "120000"])
                try await gateA.arrived()
                a.suspend()
                try w.world.leaseClock.advance(by: .seconds(31))
                let flushB = try b.start("flush", ["budgetMs": "120000"])
                try await gateB.arrived()  // B recovered the item and has it in flight
                #expect(w.server.requests.count == 2)
                let before = try w.snapshot()

                a.resume()
                gateA.open()
                #expect(try await a.reply(flushA).result["ending"] == "superseded")
                #expect(try w.snapshot() == before)
                #expect(w.item(id)?.state == .inFlight && w.item(id)?.claimOwner == "widget:B")
                gateB.open()
                #expect(try await b.reply(flushB).result["acked"] == "1")
                #expect(w.item(id) == nil && w.server.entry(id) != nil)
                #expect(w.server.requests.count == 2)  // A sent nothing after its late 422
            }
        }

        @Test("10 · MP: A SIGKILLed holding the lease; after the TTL B recovers, resends and acks")
        func case10() async throws {
            try await OutboxWorld.run { w in
                let a = try await w.world.spawn("app:A")
                let b = try await w.world.spawn("widget:B", open: "extension")
                let id = try await w.log(a)
                let gate = w.world.gate()
                w.server.inject(.post, .delay(gate))
                _ = try a.start("flush", ["budgetMs": "120000"])
                try await gate.arrived()
                await a.killNow()
                #expect(try await w.store.leases.record(.flush).owner == "app:A")
                #expect(w.item(id)?.state == .inFlight)

                try w.world.leaseClock.advance(by: .seconds(29))
                #expect(try await b.run("flush")["ending"] == "busy")
                try w.world.leaseClock.advance(by: .seconds(1))
                let report = try await b.run("flush")
                #expect(report["acked"] == "1" && w.item(id) == nil && w.server.entry(id) != nil)
                #expect(w.server.count(.post) == 2 && w.server.requests.count == 2)
                gate.open()  // the dead process's request finally lands: a replay of the same id
                #expect(w.server.with { $0.entries.count } == 1)
            }
        }

        @Test("23 · MP: an update while the create is in flight in another process is appended")
        func case23() async throws {
            try await OutboxWorld.run { w in
                let a = try await w.world.spawn("app:A")
                let b = try await w.world.spawn("widget:B", open: "extension")
                let id = try await w.log(a)
                let gate = w.world.gate()
                w.server.inject(.post, .delay(gate))
                let flushA = try a.start("flush")
                try await gate.arrived()
                let create = try #require(w.item(id))
                #expect(create.state == .inFlight)
                let result = try await b.run(
                    "update", ["id": id.wireString, "topicId": w.topic.id.wireString, "notes": "n"])
                #expect(result["result"] == "appended")
                #expect(w.item(id)?.payloadJSON == create.payloadJSON && w.item(id)?.rowVersion == create.rowVersion)
                gate.open()
                #expect(try await a.reply(flushA).result["acked"] == "2")
                #expect(w.server.entry(id)?.notes == "n" && w.items.isEmpty)
                #expect(
                    w.server.calls == [
                        "POST /api/v1/topics/\(w.topic.id.wireString)/entries",
                        "PATCH /api/v1/entries/\(id.wireString)",
                    ])
            }
        }

        @Test("24 · MP: unarchive (app), create (widget), archive (app): no K3 across the create")
        func case24() async throws {
            try await OutboxWorld.run(topicRevision: 4, topicStatus: .archived) { w in
                let app = try await w.world.spawn("app:A")
                let widget = try await w.world.spawn("widget:B", open: "extension")
                try await app.run("unarchive", ["topicId": w.topic.id.wireString])
                let id = try await w.log(widget)
                #expect(try await app.run("archive", ["topicId": w.topic.id.wireString])["result"] == "appended")
                #expect(w.items.map(\.kind) == [.topicUnarchive, .entryCreate, .topicArchive])
                #expect(w.items.map(\.origin) == [.app, .widget, .app])
                #expect(try await app.run("flush")["acked"] == "3")
                let path = "/api/v1/topics/\(w.topic.id.wireString)"
                #expect(w.server.calls == ["POST \(path)/unarchive", "POST \(path)/entries", "POST \(path)/archive"])
                #expect(w.server.handled.allSatisfy { !$0.hasSuffix("409") })
                #expect(w.server.entry(id) != nil && w.items.isEmpty)
                #expect(w.server.with { $0.topics[w.topic.id.wireString]?.status } == .archived)
            }
        }

        /// The MP half of 32. The INT half (the real backend's 409 `stale_revision` and revision
        /// numbers) is `make ios-integration` (QuickrDataIntegrationTests, Outbox case 32).
        @Test("32 · MP: a SIGSTOPped sender's late stale_revision doesn't rebase or resend")
        func case32() async throws {
            try await OutboxWorld.run { w in
                let a = try await w.world.spawn("app:A")
                let b = try await w.world.spawn("widget:B", open: "extension")
                let entry = try w.seedEntry(revision: 3)
                let ids = ["id": entry.id.wireString, "topicId": w.topic.id.wireString]
                try await a.run("update", ids.merging(["notes": "u1"]) { $1 })
                let gate = w.world.gate()
                w.server.inject(.patch, .delay(gate))
                let flushA = try a.start("flush", ["budgetMs": "120000"])
                try await gate.arrived()  // A's PATCH (expected 3) is held in the network
                a.suspend()
                try await b.run("update", ids.merging(["notes": "u2"]) { $1 })
                try w.world.leaseClock.advance(by: .seconds(31))

                let reportB = try await b.run("flush")
                #expect(reportB["acked"] == "2" && w.server.entry(entry.id)?.revision == 5)
                #expect(w.server.requests.count == 3)  // A's held PATCH, B's two
                let before = try w.snapshot()

                a.resume()
                gate.open()  // A's original PATCH lands late: 409 stale_revision
                let reportA = try await a.reply(flushA)
                #expect(reportA.result["ending"] == "superseded")
                #expect(w.server.handled.contains("PATCH /api/v1/entries/\(entry.id.wireString) → 409"))
                #expect(w.server.count(.patch) == 3 && w.server.count(.get) == 0 && w.server.requests.count == 3)
                #expect(!w.server.requests.contains { $0.method == .patch && $0.expectedRevision == 5 })
                #expect(w.server.entry(entry.id)?.revision == 5 && w.server.entry(entry.id)?.notes == "u2")
                #expect(try w.snapshot() == before)
            }
        }

        @Test("34 · MP: B takes over while A is SIGSTOPped between the refetch and the rebase")
        func case34() async throws {
            try await OutboxWorld.run { w in
                let a = try await w.world.spawn("app:A")
                let b = try await w.world.spawn("widget:B", open: "extension")
                let entry = try w.seedEntry(revision: 3)
                try await a.run("update", ["id": entry.id.wireString, "topicId": w.topic.id.wireString, "mood": "1"])
                w.server.edit(entry.id)  // revision 4 elsewhere
                let gate = w.world.gate()
                w.server.inject(.get, .delay(gate))
                let flushA = try a.start("flush", ["budgetMs": "120000"])
                try await gate.arrived()  // A got 409, and its GET is held: it is between refetch and rebase
                a.suspend()
                try w.world.leaseClock.advance(by: .seconds(31))

                let reportB = try await b.run("flush")
                #expect(reportB["acked"] == "1" && w.server.entry(entry.id)?.revision == 5 && w.items.isEmpty)
                let requests = w.server.calls
                let before = try w.snapshot()

                a.resume()
                gate.open()
                #expect(try await a.reply(flushA).result["ending"] == "superseded")
                #expect(try w.snapshot() == before)
                #expect(w.server.count(.patch) == 3)
                #expect(w.server.calls == requests)  // A's step 3 sent nothing
            }
        }

        @Test("39 · MP: app and widget enqueue an update and a delete for E at the same instant")
        func case39() async throws {
            try await OutboxWorld.run { w in
                let app = try await w.world.spawn("app:A")
                let widget = try await w.world.spawn("widget:B", open: "extension")
                // The update commits first: it waits behind the held delete, then §8.3 drops it.
                let first = try w.seedEntry()
                let firstIds = ["id": first.id.wireString, "topicId": w.topic.id.wireString]
                try await app.run("update", firstIds.merging(["notes": "x"]) { $1 })
                try await widget.run("delete", firstIds.merging(["undoable": "true"]) { $1 })
                #expect(w.items.map(\.kind) == [.entryUpdate, .entryDelete])
                try w.world.leaseClock.advance(by: Outbox.holdDuration)
                _ = try await app.run("flush")
                #expect(w.server.requests.map(\.method) == [.delete] && w.items.isEmpty)

                // The delete commits first: C0 rejects the update.
                let second = try w.seedEntry()
                let secondIds = ["id": second.id.wireString, "topicId": w.topic.id.wireString]
                try await widget.run("delete", secondIds.merging(["undoable": "true"]) { $1 })
                let rejected = try await app.reply(try app.start("update", secondIds.merging(["notes": "x"]) { $1 }))
                #expect(!rejected.ok && rejected.error?.contains("entryDeleted") == true, "\(rejected.error ?? "")")

                // Truly concurrent, from two processes: exactly one delete each time, no SQLITE_BUSY.
                for _ in 0..<20 {
                    let entry = try w.seedEntry()
                    let ids = ["id": entry.id.wireString, "topicId": w.topic.id.wireString]
                    let update = try app.start("update", ids.merging(["notes": "x"]) { $1 })
                    let delete = try widget.start("delete", ids.merging(["undoable": "true"]) { $1 })
                    let (u, d) = (try await app.reply(update), try await widget.reply(delete))
                    #expect(d.ok, "delete: \(d.error ?? "")")
                    #expect(u.ok || u.error?.contains("entryDeleted") == true, "update: \(u.error ?? "")")
                    let items = try await w.store.writer.read { db in
                        try OutboxStorage.items(db, entityKind: .entry, entityId: entry.id.wireString)
                    }
                    #expect(items.filter { $0.kind == .entryDelete }.count == 1)
                }
            }
        }

        @Test("40 · MP: the widget logs while the app holds the lease with a slow request")
        func case40() async throws {
            try await OutboxWorld.run { w in
                let app = try await w.world.spawn("app:A")
                let widget = try await w.world.spawn("widget:B", open: "extension")
                let first = try await w.log(app)
                let gate = w.world.gate()
                w.server.inject(.post, .delay(gate))
                let flushApp = try app.start("flush")
                try await gate.arrived()
                let logged = try await w.log(widget)
                let started = ContinuousClock.now
                // The widget's `perform()` flush: 4 s budget, no lease polling (§10).
                let report = try await widget.run("flush", ["budgetMs": "4000", "leaseWaitMs": "0"])
                #expect(report["ending"] == "busy" && ContinuousClock.now - started < .seconds(4))
                #expect(w.item(logged)?.state == .pending)
                gate.open()
                #expect(try await app.reply(flushApp).result["acked"] == "2")
                #expect(w.server.entry(first) != nil && w.server.entry(logged) != nil && w.items.isEmpty)
                #expect(w.server.requests.map(\.method) == [.post, .post])  // the widget sent nothing
            }
        }

        @Test("45 · MP: wall clock back 3 h, the holder dies; B takes over after 30 s of lease time")
        func case45() async throws {
            try await OutboxWorld.run { w in
                let a = try await w.world.spawn("app:A")
                let b = try await w.world.spawn("widget:B", open: "extension")
                let id = try await w.log(a)
                let gate = w.world.gate()
                w.server.inject(.post, .delay(gate))
                _ = try a.start("flush", ["budgetMs": "120000"])
                try await gate.arrived()
                try w.world.wall.advance(by: -3 * 3600)
                await a.killNow()
                try w.world.leaseClock.advance(by: .seconds(29))
                #expect(try await b.run("flush")["ending"] == "busy")
                try w.world.leaseClock.advance(by: .seconds(1))
                #expect(try await b.run("flush")["acked"] == "1")
                #expect(w.item(id) == nil && w.server.entry(id) != nil)
                #expect(w.server.requests.count == 2)  // A's (held, dead) and B's
                gate.open()
            }
        }

        @Test("46 · MP: wall clock forward 3 h while the holder lives; no early takeover")
        func case46() async throws {
            try await OutboxWorld.run { w in
                let a = try await w.world.spawn("app:A")
                let b = try await w.world.spawn("widget:B", open: "extension")
                let id = try await w.log(a)
                let gate = w.world.gate()
                w.server.inject(.post, .delay(gate))
                let flushA = try a.start("flush", ["budgetMs": "120000"])
                try await gate.arrived()
                try w.world.wall.advance(by: 3 * 3600)
                try w.world.leaseClock.advance(by: .seconds(10))
                #expect(try await b.run("flush")["ending"] == "busy")
                #expect(try await w.store.leases.record(.flush).owner == "app:A")
                gate.open()
                #expect(try await a.reply(flushA).result["acked"] == "1")
                #expect(w.item(id) == nil && w.server.entry(id) != nil)
                #expect(w.server.requests.count == 1)  // B, refused, sent nothing
            }
        }

        @Test("48 · MP: an item, a hold and a lease row from before a reboot are all due after it")
        func case48() async throws {
            try await OutboxWorld.run { w in
                let a = try await w.world.spawn("app:A")
                let holder = try await w.world.spawn("widget:H", open: "extension")
                let entry = try w.seedEntry()
                let id = try await w.log(a)
                w.server.inject(.post, .respond(header(HTTPResponse(status: 503))))
                _ = try await a.run("flush")  // backoff deadline set
                #expect(w.item(id)?.due != nil)
                try await a.run(
                    "delete", ["id": entry.id.wireString, "topicId": w.topic.id.wireString, "undoable": "true"])
                // Another process holds the lease when the device reboots; it never comes back.
                #expect(try await holder.run("leaseAcquire", ["name": "flush"])["acquired"] == "true")
                await holder.killNow()
                try w.world.leaseClock.reboot(bootId: "boot-2", ct: 1)
                let a2 = try await w.world.spawn("app:A2")  // the app after the reboot
                let report = try await a2.run("flush", ["force": "false"])
                #expect(report["ending"] == "drained")
                #expect(w.items.isEmpty)
                #expect(w.server.entry(id) != nil && w.server.entry(entry.id) == nil)
                #expect(w.server.requests.map(\.method) == [.post, .post, .delete])
                _ = a
            }
        }
    }
}
#endif
