import Foundation
import GRDB
import QuickrCore
import QuickrTestSupport
import Testing

@testable import QuickrData

/// The NSE's streamed overlay (`StoreView.streamOverlays`, `EntryOverlay.Builder`) against the
/// full view and EDIT's fix mode (`StoreView.entry(_:id:before:)`) on the same queue: a refused
/// edit (cups 99) with a later edit behind it (cups 7, notes), then the refused one fixed (cups 3).
@Suite(.timeLimit(.minutes(2))) struct OverlayStreamTests {
    static let topic = Make.topic(name: "Coffee")

    static func update(_ entry: Entry, _ patch: EntryUpdateDTO) -> NewOutboxItem {
        NewOutboxItem(
            id: UUID(),
            payload: .entryUpdate(entryId: entry.id.wireString, topicId: entry.topicId.wireString, patch: patch),
            baseRevision: entry.revision, origin: .app, hold: nil)
    }

    /// The streamed overlay of `entry` (it's the only queued entity).
    static func streamed(_ s: TestStore) throws -> EntryOverlay? {
        try s.read { db in
            var found: EntryOverlay?
            try StoreView.streamOverlays(db) { overlay in
                found = overlay
                return false
            }
            return found
        }
    }

    @Test func aRefusedEditThenALaterOneThenTheFixAgreeEverywhere() throws {
        let s = try TestStore()
        let entry = Make.entry(topicId: Self.topic.id, answers: ["mood": .int(1)])
        try s.write { db in
            _ = try ServerLayer.upsert(db, topic: Self.topic)
            _ = try ServerLayer.upsert(db, entry: entry)
        }
        let refused = try s.enqueue(Self.update(entry, EntryUpdateDTO(answers: ["mood": .int(99)])).payload)
        try s.setState(refused, .failed, reason: .rejected)
        _ = try s.enqueue(Self.update(entry, EntryUpdateDTO(answers: ["mood": .int(4)], notes: "later")).payload)

        // A failed update isn't applied; the later one is. Streamed = resolved = shown.
        let shown = try #require(try s.read { db in try StoreView.entry(db, id: entry.id.wireString) })
        #expect(shown.entry.answers["mood"] == .int(4) && shown.entry.notes == "later")
        #expect(shown.syncState == .failed(.rejected))
        let streamed = try #require(try Self.streamed(s))
        #expect(streamed.viewEntry == shown)
        // Fix mode starts from before the refused item: the server's row, no 99, no later edit.
        let before = try s.read { db in try StoreView.entry(db, id: entry.id.wireString, before: refused.seq) }
        #expect(before == entry)

        // The fix replaces the refused item in place (cups 3, pending) and the later edit loses
        // the key the correction set: still one agreement.
        try s.write { db in
            try db.execute(
                sql: """
                    UPDATE outbox_item SET state = 'pending', failure_reason = NULL, payload_json = ?
                    WHERE id = ?
                    """,
                arguments: [
                    try OutboxPayload.entryUpdate(
                        entryId: entry.id.wireString, topicId: entry.topicId.wireString,
                        patch: EntryUpdateDTO(answers: ["mood": .int(3)])
                    ).encoded(), refused.id,
                ])
        }
        let fixed = try #require(try s.read { db in try StoreView.entry(db, id: entry.id.wireString) })
        #expect(fixed.entry.answers["mood"] == .int(4), "the later edit still applies on top")
        #expect(fixed.syncState == .pending)
        #expect(try Self.streamed(s)?.viewEntry == fixed)
    }
}
