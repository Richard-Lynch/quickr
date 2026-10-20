import Foundation
import QuickrCore
import QuickrData
import QuickrUI

/// The tiles' and toasts' `EntryWriter` over the app's session: each write enqueues through the
/// outbox and returns after the commit; `sendNow` is the scheduler's (outbox.md §10). Writes are
/// tied to the store they went to (`EntryScope`: server and store generation), so a toast's Undo
/// after a server switch or a reset is refused instead of reaching another store's outbox.
@MainActor
final class SessionEntryWriter: EntryWriter {
    /// The session of the moment (nil before it opens). Set by `AppEnvironment`.
    var session: @MainActor () -> AppSession? = { nil }

    var scope: EntryScope? { session()?.binding.map(Self.scope) }

    func log(_ topic: QuickLogTopic, answers: [String: AnswerValue]) async throws -> LoggedEntry {
        let session = try requireSession()
        // Read before the call: `log` takes the outbox synchronously, on this actor, before it awaits.
        guard let scope else { throw AppSession.SessionError.noStore }
        let id = try await session.log(
            topic: TopicRef(id: topic.id, slug: topic.slug, name: topic.name), answers: answers,
            version: topic.version)
        return LoggedEntry(id: id, scope: scope)
    }

    func sendNow(_ entry: LoggedEntry, wait: Duration) async -> EntryDelivery {
        // Another store is active now: the entry waits in its own and syncs when that is back.
        guard scope == entry.scope, let scheduler = session()?.scheduler else { return .queued }
        return Self.delivery(await scheduler.sendNow(itemId: entry.id.wireString, wait: wait))
    }

    func undoLog(_ entryId: UUID, in scope: EntryScope) async throws -> Bool {
        let session = try requireSession(scope)
        // Removed, or a DELETE queued: undone (outbox.md §9.1). Nothing to do is not "Undone".
        return try await session.undoLog(entryId: entryId) != .nothingToDo
    }

    func undoDelete(_ entryId: UUID, in scope: EntryScope) async throws -> Bool {
        try await requireSession(scope).undoDelete(entryId: entryId) == .restored
    }

    func failure(_ error: any Error) -> EntryWriteFailure { Self.failure(error) }

    static func scope(_ binding: AppSession.Binding) -> EntryScope {
        // Not the base URL: a new address for the same server keeps the same store.
        EntryScope("\(binding.serverId)/\(binding.storeGen)")
    }

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
        case EntryWriteError.scopeChanged: .scopeChanged
        case StoreError.retired: .message("This device’s data was just reset. Try again.")
        case AppSession.SessionError.noStore: .message("Connect to a server first.")
        default: .message(String(describing: error))
        }
    }

    private func requireSession() throws -> AppSession {
        guard let session = session() else { throw AppSession.SessionError.noStore }
        return session
    }

    /// The session, while `scope` is still its active store. Checked and used without an await in
    /// between, so a rebind can't slip in before the call takes the outbox.
    private func requireSession(_ scope: EntryScope) throws -> AppSession {
        let session = try requireSession()
        guard self.scope == scope else { throw EntryWriteError.scopeChanged }
        return session
    }
}
