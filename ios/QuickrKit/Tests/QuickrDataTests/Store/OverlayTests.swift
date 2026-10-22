import Foundation
import GRDB
import QuickrCore
import QuickrData
import QuickrTestSupport
import Testing

/// The §3.2 overlay table (sync-protocol.md), case by case, then through the store.
@Suite(.timeLimit(.minutes(5))) struct OverlayTests {
    private static let topic = Make.topic()
    private static let server = Make.entry(topicId: topic.id, answers: ["mood": .int(2), "where": .string("home")])

    private static func item(
        _ seq: Int64, _ payload: OutboxPayload, _ state: OutboxState = .pending, reason: OutboxFailureReason? = nil,
        entity: UUID = server.id
    ) -> OutboxItem {
        OutboxItem(
            seq: seq, id: payload.kind == .entryCreate ? entity.wireString : UUID().wireString, kind: payload.kind,
            entityId: entity.wireString, topicId: topic.id.wireString, payloadJSON: try! payload.encoded(),
            state: state, failureReason: reason, origin: .widget, createdAt: Make.t0.addingTimeInterval(Double(seq)),
            updatedAt: Make.t0.addingTimeInterval(Double(seq)))
    }

    private static let create = Make.createPayload(topic: topic, minutes: 5)
    private static let update = OutboxPayload.entryUpdate(
        entryId: server.id.wireString, topicId: topic.id.wireString,
        patch: EntryUpdateDTO(answers: ["mood": .int(5), "where": nil], notes: "edited"))
    private static let delete = OutboxPayload.entryDelete(entryId: server.id.wireString, topicId: topic.id.wireString)

    struct Case: Sendable, CustomTestStringConvertible {
        var name: String
        var server: Entry?
        var items: [OutboxItem]
        var visible: Bool
        var counted: Bool
        var state: RecordSyncState
        var undoable = false
        var check: @Sendable (Entry?) -> Bool = { _ in true }

        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "server row, no items", server: server, items: [], visible: true, counted: true, state: .synced),
        Case(
            name: "active create, no server row: synthesised", server: nil, items: [item(1, create, .pending)],
            visible: true, counted: true, state: .pending,
            check: { entry in
                entry?.answers == ["mood": .int(4)] && entry?.source == "ios" && entry?.revision == 0
                    && entry?.capturedAt == Make.t0.addingTimeInterval(300)
            }),
        Case(
            name: "in-flight create with server row: server wins", server: server, items: [item(1, create, .inFlight)],
            visible: true, counted: true, state: .synced, check: { $0 == server }),
        Case(
            name: "uncertain create, no server row", server: nil, items: [item(1, create, .uncertain)], visible: true,
            counted: true, state: .pending),
        Case(
            name: "active update patches: answers merge, null removes, notes replaced", server: server,
            items: [item(1, update)], visible: true, counted: true, state: .pending,
            check: { $0?.answers == ["mood": .int(5)] && $0?.notes == "edited" }),
        Case(
            name: "create then update, unsent", server: nil, items: [item(1, create), item(2, update)], visible: true,
            counted: true, state: .pending, check: { $0?.answers == ["mood": .int(5)] && $0?.notes == "edited" }),
        Case(
            name: "active delete hides", server: server, items: [item(1, delete)], visible: false, counted: false,
            state: .pending),
        Case(
            name: "held delete hides, undoable, earlier items kept", server: server,
            items: [item(1, update), item(2, delete, .held)], visible: false, counted: false, state: .pending,
            undoable: true, check: { $0?.notes == "edited" }),
        Case(
            name: "failed create shows what the user entered, not counted", server: nil,
            items: [item(1, create, .failed, reason: .rejected)], visible: true, counted: false,
            state: .failed(.rejected), check: { $0?.answers == ["mood": .int(4)] }),
        Case(
            name: "failed update still applied for display", server: server,
            items: [item(1, update, .failed, reason: .conflict)], visible: true, counted: true,
            state: .failed(.conflict), check: { $0?.notes == "edited" }),
        Case(
            name: "failed delete shows the row", server: server, items: [item(1, delete, .failed, reason: .rejected)],
            visible: true, counted: true, state: .failed(.rejected)),
        Case(
            name: "failed deleted_elsewhere create has no row", server: nil,
            items: [item(1, create, .failed, reason: .deletedElsewhere)], visible: false, counted: false,
            state: .synced),
        Case(
            name: "failed create blocks nothing: a later pending update still shows, flagged failed", server: nil,
            items: [item(1, create, .failed, reason: .topicArchived), item(2, update)], visible: true, counted: false,
            state: .failed(.topicArchived)),
        Case(
            name: "update without any row has nothing to patch", server: nil, items: [item(1, update)], visible: false,
            counted: false, state: .synced),
    ]

    @Test(arguments: cases) func entryOverlay(_ c: Case) throws {
        let overlay = try EntryOverlay.resolve(server: c.server, items: c.items.reversed())  // order comes from seq
        #expect(overlay.isVisible == c.visible)
        #expect(overlay.isCounted == c.counted)
        #expect(overlay.syncState == c.state)
        #expect(overlay.undoable == c.undoable)
        #expect(c.check(overlay.entry))
    }

    @Test func topicOverlayAppliesArchivesInOrderAndFlagsFailures() {
        let topic = Self.topic
        let archive = OutboxPayload.topicArchive(topicId: topic.id.wireString)
        let unarchive = OutboxPayload.topicUnarchive(topicId: topic.id.wireString)
        func item(_ seq: Int64, _ payload: OutboxPayload, _ state: OutboxState = .pending) -> OutboxItem {
            Self.item(seq, payload, state, reason: state == .failed ? .conflict : nil, entity: topic.id)
        }
        let archived = TopicOverlay.resolve(server: topic, items: [item(1, archive)])
        #expect(archived.topic.status == .archived)
        #expect(archived.topic.archivedAt == Make.t0.addingTimeInterval(1))
        #expect(archived.syncState == .pending)

        let back = TopicOverlay.resolve(server: topic, items: [item(2, unarchive), item(1, archive)])
        #expect(back.topic.status == .active && back.topic.archivedAt == nil)

        #expect(archived.pendingChange == .topicArchive && back.pendingChange == .topicUnarchive)

        var failedItem = item(1, archive, .failed)
        failedItem.lastErrorJSON = #"{"message":"Topic changed elsewhere","status":409}"#
        let failed = TopicOverlay.resolve(server: topic, items: [failedItem])
        #expect(failed.topic.status == .active)
        #expect(failed.syncState == .failed(.conflict))
        #expect(failed.pendingChange == .topicArchive)
        #expect(failed.lastError == OutboxErrorInfo(message: "Topic changed elsewhere", status: 409))

        let none = TopicOverlay.resolve(server: topic, items: [])
        #expect(none.syncState == .synced && none.pendingChange == nil && none.lastError == nil)
    }

    // MARK: - Through the store

    @Test func wholeDoublesStayDoublesThroughEveryPath() async throws {
        let s = try TestStore()
        let topic = Make.topic()
        let stored = Make.entry(topicId: topic.id, answers: ["mood": .int(3), "weight": .double(7.0)])
        try s.write { (db: Database) throws in
            _ = try ServerLayer.upsert(db, topic: topic)
            _ = try ServerLayer.upsert(db, entry: stored)
        }
        #expect(
            try await s.store.entries.entry(id: stored.id)?.entry.answers == ["mood": .int(3), "weight": .double(7)])

        let createId = UUID()
        try s.enqueue(
            Make.createPayload(topic: topic, answers: ["mood": .int(2), "weight": .double(70)]), id: createId)
        #expect(
            try await s.store.entries.entry(id: createId)?.entry.answers == ["mood": .int(2), "weight": .double(70)])

        try s.enqueue(
            .entryUpdate(
                entryId: stored.id.wireString, topicId: topic.id.wireString,
                patch: EntryUpdateDTO(answers: ["weight": .double(8), "mood": .double(4)])))
        #expect(
            try await s.store.entries.entry(id: stored.id)?.entry.answers == ["mood": .int(4), "weight": .double(8)])
    }

    @Test func unreadableQuestionsFailTheReadInsteadOfSkippingNormalization() async throws {
        let s = try TestStore()
        let topic = Make.topic()
        let entry = Make.entry(topicId: topic.id)
        try s.write { (db: Database) throws in
            _ = try ServerLayer.upsert(db, topic: topic)
            _ = try ServerLayer.upsert(db, entry: entry)
            try db.execute(sql: "UPDATE topic SET questions_json = '[{\"type\":\"nope\"}]'")
        }
        await #expect(throws: (any Error).self) { try await s.store.entries.entry(id: entry.id) }
        await #expect(throws: (any Error).self) { try await s.store.entries.entries(topicId: topic.id, limit: nil) }
    }

    @Test func failedEntriesCarryTheirLastError() async throws {
        let s = try TestStore()
        let topic = Make.topic()
        try s.write { (db: Database) throws in _ = try ServerLayer.upsert(db, topic: topic) }
        let item = try s.enqueue(Make.createPayload(topic: topic))
        try s.setState(item, .failed, reason: .rejected)
        try s.write { (db: Database) throws in
            try db.execute(
                sql: "UPDATE outbox_item SET last_error_json = ? WHERE id = ?",
                arguments: [#"{"message":"Answer out of range","status":422}"#, item.id])
        }
        let view = try #require(try await s.store.entries.entries(topicId: topic.id, limit: nil).first)
        #expect(view.syncState == .failed(.rejected))
        #expect(view.lastError == OutboxErrorInfo(message: "Answer out of range", status: 422))
    }

    @Test func orphanEntriesAndQueuedCreatesWaitForTheirTopic() async throws {
        let s = try TestStore()
        let topic = Make.topic()
        let orphan = Make.entry(topicId: topic.id)
        let createId = UUID()
        try s.write { (db: Database) throws in _ = try ServerLayer.upsert(db, entry: orphan) }
        try s.enqueue(Make.createPayload(topic: topic), id: createId)
        #expect(try await s.store.entries.entries(topicId: topic.id, limit: nil).isEmpty)
        #expect(try await s.store.entries.entry(id: orphan.id) == nil)

        try s.write { (db: Database) throws in _ = try ServerLayer.upsert(db, topic: topic) }
        #expect(
            Set(try await s.store.entries.entries(topicId: topic.id, limit: nil).map(\.id)) == [orphan.id, createId])
        #expect(try await s.store.topics.topic(id: topic.id)?.topic.entryCount == 2)
    }

    @Test func aTombstonedIdNeverAppearsWhateverTheOverlayHolds() async throws {
        let s = try TestStore()
        let topic = Make.topic()
        let entry = Make.entry(topicId: topic.id)
        try s.write { (db: Database) throws in
            _ = try ServerLayer.upsert(db, topic: topic)
            try ServerLayer.applyDeletion(db, kind: .entry, id: entry.id, topicId: topic.id, seq: 3)
        }
        try s.enqueue(Make.createPayload(topic: topic), id: entry.id)
        #expect(try await s.store.entries.entry(id: entry.id) == nil)
        #expect(try await s.store.entries.entries(topicId: topic.id, limit: nil).isEmpty)
        #expect(try await s.store.topics.topic(id: topic.id)?.topic.entryCount == 0)
    }

    @Test func entriesMergeServerAndOverlayRowsByCapturedAt() async throws {
        let s = try TestStore()
        let topic = Make.topic()
        let old = Make.entry(topicId: topic.id, minutes: 0)
        let edited = Make.entry(topicId: topic.id, minutes: 10)
        let deleted = Make.entry(topicId: topic.id, minutes: 20)
        try s.write { (db: Database) throws in
            _ = try ServerLayer.upsert(db, topic: topic)
            for e in [old, edited, deleted] { _ = try ServerLayer.upsert(db, entry: e) }
        }
        // Move `edited` to the newest position; delete `deleted`; queue a create in the middle.
        try s.enqueue(
            .entryUpdate(
                entryId: edited.id.wireString, topicId: topic.id.wireString,
                patch: EntryUpdateDTO(capturedAt: Make.t0.addingTimeInterval(3600))))
        try s.enqueue(.entryDelete(entryId: deleted.id.wireString, topicId: topic.id.wireString))
        let createId = UUID()
        try s.enqueue(Make.createPayload(topic: topic, minutes: 5), id: createId)

        let all = try await s.store.entries.entries(topicId: topic.id, limit: nil)
        #expect(all.map(\.id) == [edited.id, createId, old.id])
        #expect(all.map(\.syncState) == [.pending, .pending, .synced])
        let two = try await s.store.entries.entries(topicId: topic.id, limit: 2)
        #expect(two.map(\.id) == [edited.id, createId])
    }

    @Test func topicsAreFlaggedAndOrderedByName() async throws {
        let s = try TestStore()
        let b = Make.topic(name: "beta")
        let a = Make.topic(name: "Alpha")
        try s.write { (db: Database) throws in for t in [b, a] { _ = try ServerLayer.upsert(db, topic: t) } }
        let failed = try s.enqueue(.topicArchive(topicId: b.id.wireString))
        try s.setState(failed, .failed, reason: .conflict)
        let topics = try await s.store.topics.topics()
        #expect(topics.map(\.topic.name) == ["Alpha", "beta"])
        #expect(topics.map(\.syncState) == [.synced, .failed(.conflict)])
        #expect(try await s.store.topics.topic(slug: "alpha")?.id == a.id)
    }
}
