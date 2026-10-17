import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// outbox.md §13 cases 17–20, 33, 35–38, 43, 44, 49, 50, 55–58: remote deletes and tombstones,
/// `stale_revision` recovery, acks and pull-acks, and the identity/epoch checks (§5.2 step 0).
@Suite struct OutboxServerStateTests {
    @Test("17 · (fake server) PATCH 404 after a remote delete tombstones E; the update fails deleted_elsewhere")
    func case17() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let entry = try h.seedEntry()
        try await outbox.updateEntry(id: entry.id, topicId: h.topic.id, patch: h.patch(notes: "x"), origin: .app)
        h.server.deleteEntry(entry.id)
        _ = try await outbox.flushNow()
        #expect(try h.isTombstoned(entry.id) && h.view(entry.id) == nil)
        let update = try #require(h.items.single)
        #expect(update.state == .failed && update.failureReason == .deletedElsewhere)
        // Dismiss only.
        await #expect(throws: OutboxError.self) { try await outbox.retry(itemId: update.id) }
        try await outbox.dismiss(itemId: update.id)
        #expect(h.items.isEmpty)
    }

    @Test("18 · the tombstone from a pull fails the update without a request; no zombie row")
    func case18() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let entry = try h.seedEntry()
        try await outbox.updateEntry(id: entry.id, topicId: h.topic.id, patch: h.patch(notes: "x"), origin: .app)
        try h.applyTombstone(.entry, id: entry.id, topicId: h.topic.id)
        #expect(h.items.single?.failureReason == .deletedElsewhere)
        #expect(h.view(entry.id) == nil && h.viewEntries().isEmpty)
        _ = try await outbox.flushNow()
        #expect(h.server.requests.isEmpty)
    }

    @Test("19 · a topic tombstone fails its creates and updates, retires its archive and clears local state")
    func case19() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let entry = try h.seedEntry()
        try await h.log(outbox)
        try await h.log(outbox, minutes: 1)
        try await outbox.updateEntry(id: entry.id, topicId: h.topic.id, patch: h.patch(notes: "x"), origin: .app)
        try await outbox.archiveTopic(id: h.topic.id, origin: .app)
        let topicId = h.topic.id.wireString
        try h.write { db in
            try db.execute(
                sql: "INSERT INTO ui_draft (key, topic_id, payload_json, updated_at) VALUES ('d', ?, '{}', 0)",
                arguments: [topicId])
            try db.execute(
                sql: "INSERT INTO widget_state (key, topic_id, payload_json, updated_at) VALUES ('w', ?, '{}', 0)",
                arguments: [topicId])
        }
        try h.applyTombstone(.topic, id: h.topic.id, topicId: h.topic.id)
        #expect(h.items.map(\.kind) == [.entryCreate, .entryCreate, .entryUpdate])
        #expect(h.items.allSatisfy { $0.state == .failed && $0.failureReason == .deletedElsewhere })
        let leftovers = try h.read { db in
            try Int.fetchOne(
                db, sql: "SELECT (SELECT COUNT(*) FROM ui_draft) + (SELECT COUNT(*) FROM widget_state)") ?? -1
        }
        #expect(leftovers == 0)
    }

    @Test("20 · a pending delete is retired silently by its tombstone")
    func case20() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let entry = try h.seedEntry()
        try await outbox.deleteEntry(id: entry.id, topicId: h.topic.id, undoable: false, origin: .app)
        try h.applyTombstone(.entry, id: entry.id, topicId: h.topic.id)
        #expect(h.items.isEmpty)
    }

    @Test("33 · stale_revision: verify, refetch, rebase, resend; the next update chains to the result")
    func case33() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let entry = try h.seedEntry(revision: 3)
        try await outbox.updateEntry(id: entry.id, topicId: h.topic.id, patch: h.patch(mood: 1), origin: .app)
        h.server.edit(entry.id)  // another device: revision 4
        _ = try await outbox.flushNow()
        #expect(h.server.requests.map(\.method) == [.patch, .get, .patch])
        #expect(h.server.requests.compactMap(\.expectedRevision) == [3, 4])
        let server = try #require(h.server.entry(entry.id))
        #expect(server.revision == 5 && server.notes == "edited elsewhere" && server.answers["mood"] == .int(1))
        #expect(h.items.isEmpty && h.view(entry.id)?.entry.revision == 5)
        guard
            case .appended(let next) = try await outbox.updateEntry(
                id: entry.id, topicId: h.topic.id, patch: h.patch(notes: "again"), origin: .app)
        else {
            Issue.record("not appended")
            return
        }
        #expect(next.baseRevision == 5)
    }

    @Test("35 · stale_revision four times fails the update as a conflict after 3 rebases")
    func case35() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let entry = try h.seedEntry(revision: 1)
        try await outbox.updateEntry(id: entry.id, topicId: h.topic.id, patch: h.patch(mood: 2), origin: .app)
        let id = entry.id.wireString
        h.server.inject(
            .patch, once: false,
            .before { state in state.entries[id]?.revision += 1 })
        _ = try await outbox.flushNow()
        let item = try #require(h.items.single)
        #expect(item.state == .failed && item.failureReason == .conflict && item.rebaseCount == 4)
        #expect(item.errorInfo?.message == "Changed on another device — review and retry")
        #expect(h.server.count(.patch) == 4 && h.server.count(.get) == 4)
        // Retry resets the rebase count.
        try await outbox.retry(itemId: item.id)
        #expect(h.item(item.id)?.rebaseCount == 0 && h.item(item.id)?.state == .pending)
    }

    @Test("36 · an older page applied after the ack is dropped by the revision guard")
    func case36() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let entry = try h.seedEntry(revision: 1)
        try await outbox.updateEntry(id: entry.id, topicId: h.topic.id, patch: h.patch(notes: "mine"), origin: .app)
        _ = try await outbox.flushNow()
        try h.applyPage(entry)  // fetched before the PATCH, applied after its ack
        let view = try #require(h.view(entry.id))
        #expect(view.entry.notes == "mine" && view.entry.revision == 2 && view.syncState == .synced)
        #expect(h.viewEntries().count == 1)
    }

    @Test("37 · a pull that delivers an uncertain create acks it: no duplicate overlay")
    func case37() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let id = try await h.log(outbox)
        h.server.inject(.post, .lose(.timedOut(requestStarted: true)))
        _ = try await outbox.flush(force: true, budget: .seconds(30))
        try await outbox.updateEntry(id: id, topicId: h.topic.id, patch: h.patch(notes: "later"), origin: .app)
        try h.applyPage(try #require(h.server.entry(id)))
        let update = try #require(h.items.single)
        #expect(update.kind == .entryUpdate && update.baseRevision == 1)
        #expect(h.viewEntries().count == 1 && h.view(id)?.entry.notes == "later")
    }

    @Test("38 · (fake server) epoch rotation: 409 restores, the rebuild swaps, items resend with the new epoch")
    func case38() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let entry = try h.seedEntry()
        let rejected = try await h.log(outbox)
        h.server.inject(.post, .respond(header(FakeServer.problem(422, "invalid_answers", "bad"))))
        _ = try await outbox.flushNow()
        let uncertain = try await h.log(outbox, minutes: 1)
        h.server.inject(.post, .lose(.timedOut(requestStarted: true)))
        _ = try await outbox.flushNow()
        try await outbox.updateEntry(id: entry.id, topicId: h.topic.id, patch: h.patch(notes: "p"), origin: .app)
        let before = h.items
        h.server.with { $0.epoch = "E2" }

        let report = try await outbox.flushNow()
        #expect(report.ending == .mismatch(.epoch))
        #expect(try h.flag("epoch_suspect") && h.signals == [.epochSuspect])
        #expect(h.items == before)

        // The coordinator rebuilds and swaps (sync §7): new epoch, new layer_gen, flags cleared.
        try h.setSyncState("epoch = 'E2', layer_gen = layer_gen + 1, epoch_suspect = 0")
        _ = try await outbox.flushNow()
        let sends = h.server.requests.suffix(2)
        #expect(sends.allSatisfy { $0.headers[QuickrHeader.expectEpoch] == "E2" })
        #expect(h.server.entry(uncertain) != nil && h.server.entry(entry.id)?.notes == "p")
        #expect(h.items.single?.id == rejected.wireString && h.items.single?.state == .failed)
    }

    @Test(
        "43 · a create for a topic deleted on the server fails topic_missing, then the pull makes it deleted_elsewhere")
    func case43() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let id = try await h.log(outbox)
        h.server.deleteTopic(h.topic.id)
        _ = try await outbox.flushNow()
        #expect(h.item(id)?.failureReason == .topicMissing && h.signals == [.pullRequested])
        try h.applyTombstone(.topic, id: h.topic.id, topicId: h.topic.id)
        #expect(h.item(id)?.failureReason == .deletedElsewhere)
    }

    @Test("44 · Retry of an uncertain create whose entry was deleted elsewhere: failed deleted_elsewhere")
    func case44() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let id = try await h.log(outbox)
        h.server.inject(.post, .lose(.timedOut(requestStarted: true)))
        _ = try await outbox.flushNow()
        h.server.deleteEntry(id)
        try await outbox.retry(itemId: id.wireString)
        _ = try await outbox.flushNow()
        let item = try #require(h.item(id))
        #expect(item.state == .failed && item.failureReason == .deletedElsewhere)
        #expect(item.errorInfo?.message == "Deleted on another device" && item.errorInfo?.status == 409)
        #expect(try h.isTombstoned(id))
    }

    @Test("49 · (fake server) a different server answers server_mismatch: restored, identity mismatch, no entry")
    func case49() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let id = try await h.log(outbox)
        let before = try #require(h.item(id))
        h.server.with { $0.serverId = "server-2" }
        let report = try await outbox.flushNow()
        #expect(report.ending == .mismatch(.identity) && h.signals == [.identityMismatch])
        let item = try #require(h.item(id))
        #expect(item.state == .pending && item.attempts == 0 && !item.maybeDelivered && item.claimToken == nil)
        #expect(item.due == before.due)
        #expect(try h.flag("identity_mismatch") && h.server.entry(id) == nil)
        // Claims stay refused until the coordinator resolves the mismatch.
        #expect(try await outbox.flushNow().ending == .paused)
    }

    @Test("50 · a 2xx without X-QuickR-Server-Id is discarded: uncertain, identity mismatch")
    func case50() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let id = try await h.log(outbox)
        var response = FakeServer.ok(201, Make.entry(id: id, topicId: h.topic.id))
        response.headers[QuickrHeader.epoch] = "E1"
        h.server.inject(.post, .respond(response))
        _ = try await outbox.flushNow()
        let item = try #require(h.item(id))
        #expect(item.state == .uncertain && item.maybeDelivered && item.claimToken == nil)
        #expect(try h.flag("identity_mismatch"))
        #expect(try h.read { db in try ServerLayer.revision(db, entityKind: .entry, id: id.wireString) } == nil)
    }

    @Test("55 · a 404 from another epoch during the refetch is not 'gone': the update is restored")
    func case55() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let entry = try h.seedEntry(revision: 3)
        try await outbox.updateEntry(id: entry.id, topicId: h.topic.id, patch: h.patch(notes: "x"), origin: .app)
        let before = try #require(h.items.single)
        h.server.edit(entry.id)  // stale_revision on the PATCH
        // The server is restored (E2, without E) before the refetch.
        h.server.inject(
            .get,
            .before { state in
                state.epoch = "E2"
                state.entries = [:]
            })
        let leaseAtSignal = LeaseProbe()
        let probed = Outbox(
            store: h.store, sender: outbox.sender, owner: "app:1",
            onSignal: { _ in leaseAtSignal.owner = (try? h.lease())?.owner }, random: { 0.5 })
        let report = try await probed.flushNow()
        #expect(report.ending == .mismatch(.epoch))
        #expect(try !h.isTombstoned(entry.id) && h.view(entry.id) != nil)
        let item = try #require(h.items.single)
        #expect(item.state == .pending && item.attempts == before.attempts && item.failureReason == nil)
        #expect(item.claimToken == nil && item.preClaimJSON == nil)
        #expect(try h.flag("epoch_suspect"))
        #expect(leaseAtSignal.owner == nil)  // flush was released before the coordinator was signalled

        try h.setSyncState("epoch = 'E2', layer_gen = layer_gen + 1, epoch_suspect = 0")
        _ = try await outbox.flushNow()
        #expect(h.server.requests.last?.headers[QuickrHeader.expectEpoch] == "E2")
    }

    @Test("56 · a PATCH 404 labelled with another epoch is not 'gone': uncertain, epoch suspect")
    func case56() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let entry = try h.seedEntry()
        try await outbox.updateEntry(id: entry.id, topicId: h.topic.id, patch: h.patch(notes: "x"), origin: .app)
        h.server.inject(.patch, .respond(header(FakeServer.problem(404, "not_found"), epoch: "E9")))
        _ = try await outbox.flushNow()
        let item = try #require(h.items.single)
        #expect(item.state == .uncertain && item.maybeDelivered)
        #expect(try !h.isTombstoned(entry.id) && h.flag("epoch_suspect"))
    }

    @Test("57 · a 404 without quickR headers is a retry, never terminal, never 'gone'")
    func case57() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let entry = try h.seedEntry()
        try await outbox.updateEntry(id: entry.id, topicId: h.topic.id, patch: h.patch(notes: "x"), origin: .app)
        h.server.inject(.patch, .respond(HTTPResponse(status: 404, body: Data("Not Found".utf8))))
        _ = try await outbox.flushNow()
        let item = try #require(h.items.single)
        #expect(item.state == .pending && !item.maybeDelivered && item.failureReason == nil)
        #expect(item.errorInfo?.message == "Unexpected response from the server")
        #expect(try !h.isTombstoned(entry.id))
    }

    @Test("58 · a precondition 409 restores state, attempts and deadline and clears every claim field")
    func case58() async throws {
        let h = try OutboxHarness()
        let outbox = h.outbox()
        let id = try await h.log(outbox)
        for _ in 0..<2 {
            h.server.inject(.post, .lose(.timedOut(requestStarted: true)))
            _ = try await outbox.flushNow()
        }
        let before = try #require(h.item(id))
        #expect(before.state == .uncertain && before.attempts == 2 && before.due != nil)
        h.server.with { $0.epoch = "E2" }
        _ = try await outbox.flushNow()
        let item = try #require(h.item(id))
        #expect(item.state == before.state && item.attempts == 2 && item.due == before.due)
        #expect(item.maybeDelivered)
        #expect(
            item.claimToken == nil && item.claimOwner == nil && item.claimLayerGen == nil && item.claimEpoch == nil
                && item.preClaimJSON == nil)
    }
}

/// Records what a signal handler saw.
final class LeaseProbe: @unchecked Sendable {
    var owner: String? = "unset"
}
