import Foundation
import QuickrCore
import QuickrData
import QuickrUI

/// The record screen's writes, over `AppSession`: enqueue through the outbox, send at once with
/// the record screen's 8 s wait (outbox.md §10), and read the item back to tell sent, queued and
/// refused apart.
@MainActor
final class RecordSessionWriter: RecordWriter {
    static let sendWait: Duration = .seconds(8)

    let session: AppSession

    init(session: AppSession) {
        self.session = session
    }

    func log(_ topic: Topic, answers: [String: AnswerValue], capturedAt: Date, notes: String?) async throws -> UUID {
        try await session.log(
            topic: Self.ref(topic), answers: answers, capturedAt: capturedAt, notes: notes,
            version: topic.currentVersion)
    }

    func sendNow(_ entryId: UUID) async -> RecordDelivery {
        guard let scheduler = session.scheduler, let store = session.store else { return .queued }
        let itemId = entryId.wireString
        if await scheduler.sendNow(itemId: itemId, wait: Self.sendWait) { return .sent }
        // Still queued, or refused: the item says which.
        guard let item = try? await store.outbox.item(id: itemId) else { return .sent }
        guard item.state == .failed else { return .queued }
        if item.failureReason == .deletedElsewhere { return .notSaved }
        let failure = item.failureDetails
        return .rejected(failure?.problem, message: failure?.message ?? "The server refused this entry.")
    }

    func discard(_ entryId: UUID) async {
        // Best effort: if it stays, the sync sheet still lists it to retry or discard.
        _ = try? await session.outbox?.discard(itemId: entryId.wireString, origin: .app)
    }

    func fix(
        _ fix: RecordFix, topic: Topic, answers: [String: AnswerValue], capturedAt: Date, notes: String?
    ) async throws {
        guard let outbox = session.outbox else { throw AppSession.SessionError.noStore }
        let body = EntryCreateDTO(
            id: nil, answers: answers, source: OutboxOrigin.app.source, capturedAt: capturedAt, notes: notes,
            version: topic.currentVersion)
        try await outbox.fix(
            itemId: fix.itemId, payload: .entryCreate(topic: Self.ref(topic), body: body), rowVersion: fix.rowVersion)
        await session.scheduler?.requestFlush(reason: .enqueue)
    }

    func failure(_ error: any Error) -> RecordFailure {
        switch error {
        case OutboxError.entryDeleted: .notSaved
        case OutboxError.itemChanged: .message("This entry changed meanwhile. Open it again from the sync list.")
        case AppSession.SessionError.noStore: .message("Connect to a server first.")
        default: .message(String(describing: error))
        }
    }

    static func ref(_ topic: Topic) -> TopicRef {
        TopicRef(id: topic.id, slug: topic.slug, name: topic.name)
    }
}
