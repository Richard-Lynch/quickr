import Foundation
import QuickrCore
import QuickrData
import QuickrUI

/// The tiles' and toasts' `EntryWriter` over the app's session: each write enqueues through the
/// outbox and returns after the commit; `sendNow` is the scheduler's (outbox.md §10).
@MainActor
final class SessionEntryWriter: EntryWriter {
    /// The session of the moment (nil before it opens). Set by `AppEnvironment`.
    var session: @MainActor () -> AppSession? = { nil }

    func log(_ topic: QuickLogTopic, answers: [String: AnswerValue]) async throws -> UUID {
        try await requireSession().log(
            topic: TopicRef(id: topic.id, slug: topic.slug, name: topic.name), answers: answers,
            version: topic.version)
    }

    func sendNow(_ entryId: UUID, wait: Duration) async -> EntryDelivery {
        guard let scheduler = session()?.scheduler else { return .queued }
        return Self.delivery(await scheduler.sendNow(itemId: entryId.wireString, wait: wait))
    }

    func undoLog(_ entryId: UUID) async throws {
        // Removed, a DELETE queued, or nothing left to do: undone in every case (outbox.md §9.1).
        _ = try await requireSession().undoLog(entryId: entryId)
    }

    func undoDelete(_ entryId: UUID) async throws -> Bool {
        try await requireSession().undoDelete(entryId: entryId) == .restored
    }

    func failure(_ error: any Error) -> EntryWriteFailure { Self.failure(error) }

    static func delivery(_ result: OutboxSendNowResult) -> EntryDelivery {
        switch result {
        case .sent: .sent
        case .queued: .queued
        case .failed(let info): .failed(info?.message ?? "The server refused it")
        case .retired: .notSaved
        }
    }

    static func failure(_ error: any Error) -> EntryWriteFailure {
        switch error {
        case OutboxError.entryDeleted: .notSaved
        case StoreError.retired: .message("This device’s data was just reset. Try again.")
        case AppSession.SessionError.noStore: .message("Connect to a server first.")
        default: .message(String(describing: error))
        }
    }

    private func requireSession() throws -> AppSession {
        guard let session = session() else { throw AppSession.SessionError.noStore }
        return session
    }
}
