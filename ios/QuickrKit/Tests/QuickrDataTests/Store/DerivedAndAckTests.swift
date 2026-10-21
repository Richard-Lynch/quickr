import Foundation
import GRDB
import QuickrCore
@_spi(Testing) import QuickrData
import QuickrTestSupport
import Testing

/// §3.3 derived fields (rule 3), recomputed locally from the view.
@Suite(.timeLimit(.minutes(5))) struct DerivedFieldTests {
    @Test func countsAndLastCapturedFollowTheView() async throws {
        let s = try TestStore()
        let topic = Make.topic()
        let other = Make.topic(name: "Other")
        let a = Make.entry(topicId: topic.id, version: 1, minutes: 0)
        let b = Make.entry(topicId: topic.id, version: 2, minutes: 30)
        let c = Make.entry(topicId: topic.id, version: 2, minutes: 60)
        try s.write { (db: Database) throws in
            for t in [topic, other] { _ = try ServerLayer.upsert(db, topic: t) }
            for e in [a, b, c] { _ = try ServerLayer.upsert(db, entry: e) }
            for v in [1, 2] { _ = try ServerLayer.insert(db, version: Make.version(v), id: UUID(), topicId: topic.id) }
        }
        var derived = try s.read { db in try StoreView.derived(db) }
        #expect(derived[topic.id.wireString] == .init(entryCount: 3, lastCapturedAt: c.capturedAt))
        #expect(derived[other.id.wireString] == nil)

        // Held delete of the newest, active delete of another, a pending create (counted), a failed
        // create (not counted) and a create that pushes last_captured_at.
        try s.enqueue(.entryDelete(entryId: c.id.wireString, topicId: topic.id.wireString), hold: s.clock.now())
        try s.enqueue(.entryDelete(entryId: a.id.wireString, topicId: topic.id.wireString))
        try s.enqueue(Make.createPayload(topic: topic, minutes: 45))
        let failed = try s.enqueue(Make.createPayload(topic: topic, minutes: 500))
        try s.setState(failed, .failed, reason: .rejected)

        derived = try s.read { db in try StoreView.derived(db) }
        #expect(
            derived[topic.id.wireString] == .init(entryCount: 2, lastCapturedAt: Make.t0.addingTimeInterval(45 * 60)))
        let viewTopic = try #require(try await s.store.topics.topic(id: topic.id)?.topic)
        #expect(viewTopic.entryCount == 2)
        #expect(viewTopic.due == nil)
        // The create is pinned to version 1 (Make.createPayload); b is v2.
        #expect(try await s.store.versions.versions(topicId: topic.id).map(\.entryCount) == [1, 1])
        // The failed create is listed (flagged) but not the latest counted entry.
        #expect(
            try await s.store.entries.latestEntry(topicId: topic.id)?.entry.capturedAt
                == Make.t0.addingTimeInterval(45 * 60))
        let listed = try await s.store.entries.entries(topicId: topic.id, limit: nil)
        #expect(listed.first?.syncState == .failed(.rejected))
        #expect(listed.count == 3)
    }

    @Test func aTopicWithNoCountedEntriesHasNoLastCaptured() async throws {
        let s = try TestStore()
        let topic = Make.topic()
        let only = Make.entry(topicId: topic.id)
        try s.write { (db: Database) throws in
            _ = try ServerLayer.upsert(db, topic: topic)
            _ = try ServerLayer.upsert(db, entry: only)
        }
        try s.enqueue(.entryDelete(entryId: only.id.wireString, topicId: topic.id.wireString))
        let viewTopic = try #require(try await s.store.topics.topic(id: topic.id)?.topic)
        #expect(viewTopic.entryCount == 0)
        #expect(viewTopic.lastCapturedAt == nil)
        #expect(try await s.store.entries.latestEntry(topicId: topic.id) == nil)
    }
}

/// The outbox repository: CRUD, the enqueue base revision (§7.3) and the retired refusal.
@Suite(.timeLimit(.minutes(5))) struct OutboxStorageTests {
    @Test func appendAssignsSeqStateAndBaseRevision() async throws {
        let s = try TestStore()
        let topic = Make.topic(revision: 4)
        let entry = Make.entry(topicId: topic.id, revision: 7)
        try s.write { (db: Database) throws in
            _ = try ServerLayer.upsert(db, topic: topic)
            _ = try ServerLayer.upsert(db, entry: entry)
        }
        let update = OutboxPayload.entryUpdate(
            entryId: entry.id.wireString, topicId: topic.id.wireString, patch: EntryUpdateDTO(notes: "x"))
        let first = try await s.store.outbox.appendRawForTesting(NewOutboxItem(payload: update, origin: .widget))
        let second = try await s.store.outbox.appendRawForTesting(NewOutboxItem(payload: update, origin: .app))
        let hold = s.clock.now().adding(.seconds(6))
        let held = try await s.store.outbox.appendRawForTesting(
            NewOutboxItem(
                payload: .entryDelete(entryId: entry.id.wireString, topicId: topic.id.wireString), origin: .app,
                hold: hold))
        let archive = try await s.store.outbox.appendRawForTesting(
            NewOutboxItem(payload: .topicArchive(topicId: topic.id.wireString), origin: .siri))

        #expect([first.seq, second.seq, held.seq, archive.seq] == [1, 2, 3, 4])
        #expect(first.baseRevision == 7 && first.state == .pending && first.entityId == entry.id.wireString)
        #expect(second.baseRevision == nil)
        #expect(held.state == .held && held.hold == hold)
        #expect(archive.baseRevision == 4 && archive.entityKind == .topic && archive.origin == .siri)
        #expect(try first.payload() == update)
        #expect(try await s.store.outbox.items().map(\.seq) == [1, 2, 3, 4])
        #expect(try await s.store.outbox.items(topicId: topic.id.wireString).count == 4)
        #expect(try await s.store.outbox.item(id: held.id) == held)
        let summary = try await s.store.outbox.summary()
        #expect(summary.count == 4 && summary.maxSeq == 4)
    }

    @Test func createItemsUseTheEntryIdAndRefuseARetiredFile() async throws {
        let s = try TestStore()
        let topic = Make.topic()
        let id = UUID()
        let created = try await s.store.outbox.appendRawForTesting(
            NewOutboxItem(id: id, payload: Make.createPayload(topic: topic), origin: .notification))
        #expect(created.id == id.wireString && created.entityId == id.wireString)
        #expect(created.topicId == topic.id.wireString && created.baseRevision == nil)

        try s.write { (db: Database) throws in try db.execute(sql: "UPDATE sync_state SET retired = 1") }
        await #expect(throws: StoreError.retired) {
            try await s.store.outbox.appendRawForTesting(
                NewOutboxItem(payload: Make.createPayload(topic: topic), origin: .app))
        }
    }

    @Test func emptySummaryIsZero() async throws {
        let s = try TestStore()
        let summary = try await s.store.outbox.summary()
        #expect(summary.count == 0 && summary.maxSeq == 0)
    }
}

/// The atomic ack (sync-protocol.md §6, rule 7).
@Suite(.timeLimit(.minutes(5))) struct AtomicAckTests {
    struct Fixture {
        let s: TestStore
        let topic = Make.topic()
        let entry: Entry
        let flush: LeaseClaim
        let item: OutboxItem
        let sender: SenderContext

        /// A topic and an entry on the server, an `entry.update` claimed in flight with `flush` held.
        init(path: String? = nil) async throws {
            s = try TestStore(path: path)
            entry = Make.entry(topicId: topic.id, revision: 3)
            try s.write { [topic, entry] (db: Database) throws in
                _ = try ServerLayer.upsert(db, topic: topic)
                _ = try ServerLayer.upsert(db, entry: entry)
            }
            flush = try #require(try await s.store.leases.tryAcquire(.flush, owner: "widget:1"))
            let queued = try s.enqueue(
                .entryUpdate(
                    entryId: entry.id.wireString, topicId: topic.id.wireString, patch: EntryUpdateDTO(notes: "mine")))
            let token = "claim-1"
            try s.write { (db: Database) throws in
                try db.execute(
                    sql: """
                        UPDATE outbox_item SET state = 'in_flight', claim_token = ?, claim_owner = 'widget:1',
                          claim_layer_gen = 1, claim_epoch = 'E1', attempts = 1 WHERE id = ?
                        """,
                    arguments: [token, queued.id])
            }
            item = queued
            sender = SenderContext(flush: flush, claimToken: token, layerGen: 1, epoch: "E1")
        }

        var acked: Entry {
            var acked = entry
            acked.revision = 4
            acked.notes = "mine"
            return acked
        }
    }

    @Test func ackUpsertsTheRowAndDeletesTheItemTogether() async throws {
        let f = try await Fixture()
        let next = try f.s.enqueue(
            .entryUpdate(
                entryId: f.entry.id.wireString, topicId: f.topic.id.wireString, patch: EntryUpdateDTO(notes: "later")))
        #expect(next.baseRevision == nil)

        let outcome = try await f.s.store.ack(itemId: f.item.id, sender: f.sender, effect: .entry(f.acked))
        #expect(outcome == .acked(.applied))
        #expect(try await f.s.store.outbox.item(id: f.item.id) == nil)
        // Revision chaining: the next item inherits the acked revision.
        #expect(try await f.s.store.outbox.item(id: next.id)?.baseRevision == 4)
        // The view shows the server row with the remaining item applied, once.
        let view = try #require(try await f.s.store.entries.entry(id: f.entry.id))
        #expect(view.entry.notes == "later" && view.entry.revision == 4 && view.syncState == .pending)
    }

    @Test func aStaleResponseStillAcks() async throws {
        let f = try await Fixture()
        var older = f.acked
        older.revision = 2
        #expect(try await f.s.store.ack(itemId: f.item.id, sender: f.sender, effect: .entry(older)) == .acked(.stale))
        #expect(try await f.s.store.outbox.item(id: f.item.id) == nil)
        #expect(try await f.s.store.entries.entry(id: f.entry.id)?.entry.revision == 3)
    }

    @Test func aDeleteAckTombstones() async throws {
        let f = try await Fixture()
        let outcome = try await f.s.store.ack(
            itemId: f.item.id, sender: f.sender, effect: .entryDeleted(id: f.entry.id, topicId: f.topic.id))
        #expect(outcome == .acked(nil))
        try f.s.read { (db: Database) throws in
            #expect(try ServerLayer.isTombstoned(db, kind: .entry, id: f.entry.id.wireString))
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entry") == 0)
        }
        #expect(try await f.s.store.topics.topic(id: f.topic.id)?.topic.entryCount == 0)
    }

    @Test func aTopicAck() async throws {
        let f = try await Fixture()
        var archived = f.topic
        archived.status = .archived
        archived.revision = 2
        let outcome = try await f.s.store.ack(itemId: f.item.id, sender: f.sender, effect: .topic(archived))
        #expect(outcome == .acked(.applied))
        #expect(try await f.s.store.topics.topic(id: f.topic.id)?.topic.status == .archived)
    }

    enum Break: String, CaseIterable, Sendable {
        case retired, layerGen, epoch, leaseExpired, leaseTakenOver, claimToken, itemGone
    }

    @Test(arguments: Break.allCases) func aFailedFenceWritesNothing(_ breakage: Break) async throws {
        let f = try await Fixture()
        var expected: FenceFailure
        switch breakage {
        case .retired:
            try f.s.write { (db: Database) throws in try db.execute(sql: "UPDATE sync_state SET retired = 1") }
            expected = .retired
        case .layerGen:
            try f.s.write { (db: Database) throws in try db.execute(sql: "UPDATE sync_state SET layer_gen = 2") }
            expected = .layerGen
        case .epoch:
            try f.s.write { (db: Database) throws in try db.execute(sql: "UPDATE sync_state SET epoch = 'E2'") }
            expected = .epoch
        case .leaseExpired:
            f.s.clock.advance(by: .seconds(31))
            expected = .lease(.flush)
        case .leaseTakenOver:
            f.s.clock.advance(by: .seconds(31))
            _ = try #require(try await f.s.store.leases.tryAcquire(.flush, owner: "app:2"))
            expected = .lease(.flush)
        case .claimToken:
            try f.s.write { (db: Database) throws in
                try db.execute(sql: "UPDATE outbox_item SET claim_token = 'other' WHERE id = ?", arguments: [f.item.id])
            }
            expected = .claim
        case .itemGone:
            try f.s.write { (db: Database) throws in _ = try OutboxStorage.delete(db, id: f.item.id) }
            expected = .claim
        }
        let before = try f.s.read { (db: Database) throws in
            try (Row.fetchAll(db, sql: "SELECT * FROM entry"), Row.fetchAll(db, sql: "SELECT * FROM outbox_item"))
        }
        let outcome = try await f.s.store.ack(itemId: f.item.id, sender: f.sender, effect: .entry(f.acked))
        #expect(outcome == .fenced(expected))
        let after = try f.s.read { (db: Database) throws in
            try (Row.fetchAll(db, sql: "SELECT * FROM entry"), Row.fetchAll(db, sql: "SELECT * FROM outbox_item"))
        }
        #expect(before.0 == after.0)
        #expect(before.1 == after.1)
    }
}
