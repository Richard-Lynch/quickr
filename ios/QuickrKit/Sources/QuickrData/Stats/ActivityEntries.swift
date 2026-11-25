import Foundation
import GRDB
import QuickrCore

/// The Overview's activity strip reads its entries from the store, not the server
/// (content-display.md §4.2, D-5): every counted view entry captured from the first cell's local
/// midnight on, so the query bound and the cells derive from the same date.
extension LocalStore {
    /// A topic's counted view entries captured at or after `from`, newest first: the server rows
    /// with the outbox applied, queued creates and queued run stops included, hidden rows and
    /// failed creates left out (as `entry_count` counts them).
    public func entries(topicId: UUID, from: Date) async throws -> [ViewEntry] {
        let topicId = topicId.wireString
        return try await writer.read { db in try StoreView.entries(db, topicId: topicId, from: from) }
    }
}

extension LocalStore {
    /// ``entries(topicId:from:)``, re-emitted on every change (here, or signalled by `refresh`).
    public func observeEntries(topicId: UUID, from: Date, refresh: AsyncStream<Void>? = nil)
        -> AsyncThrowingStream<[ViewEntry], any Error>
    {
        let topicId = topicId.wireString
        return StoreObservation.values(in: writer, refresh: refresh) { db in
            try StoreView.entries(db, topicId: topicId, from: from)
        }
    }
}

extension StoreView {
    /// ``entries(_:topicId:limit:countedOnly:)`` with `countedOnly` and a `captured_at >= from`
    /// bound, filtered in SQL for the server rows (the `(topic_id, captured_at)` index).
    static func entries(_ db: Database, topicId: String, from: Date) throws -> [ViewEntry] {
        guard
            try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM topic WHERE id = ?)", arguments: [topicId])
                ?? false
        else { return [] }
        let book = QuestionBook(db)
        let overlaid = try overlays(db, topicId: topicId, book: book)
            .filter(\.isCounted)
            .compactMap(\.viewEntry)
            .filter { $0.entry.capturedAt >= from }
        let server = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM entry
                WHERE topic_id = ? AND captured_at >= ?
                  AND id NOT IN (SELECT entity_id FROM outbox_item WHERE entity_kind = 'entry')
                """,
            arguments: [topicId, from.timeIntervalSince1970]
        ).map { row in
            ViewEntry(
                entry: try Entry(serverRow: row, questions: try book.questions(row["topic_id"], row["version"])),
                syncState: .synced)
        }
        return (server + overlaid).sorted {
            ($0.entry.capturedAt, $0.id.wireString) > ($1.entry.capturedAt, $1.id.wireString)
        }
    }
}
