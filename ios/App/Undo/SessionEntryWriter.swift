import Foundation
import QuickrCore
import QuickrData
import QuickrUI

/// The tiles' and toasts' `EntryWriter` over the app's session: each write enqueues through the
/// outbox and returns after the commit; `sendNow` is the scheduler's (outbox.md §10). Writes are
/// tied to the store they went to (`EntryScope`: server and store generation), so a toast's Undo
/// after a server switch or a reset is refused instead of reaching another store's outbox.
@MainActor
final class SessionEntryWriter: EntryFixing {
    /// The session of the moment (nil before it opens). Set by `AppEnvironment`.
    var session: @MainActor () -> AppSession? = { nil }

    var scope: EntryScope? { session()?.binding.map(Self.scope) }

    func log(_ topic: EntryTopic, answers: [String: AnswerValue], capturedAt: Date?, notes: String?)
        async throws -> LoggedEntry
    {
        let session = try requireSession()
        // Read before the call: `log` takes the outbox synchronously, on this actor, before it awaits.
        guard let scope else { throw AppSession.SessionError.noStore }
        let id = try await session.log(
            topic: TopicRef(id: topic.id, slug: topic.slug, name: topic.name), answers: answers,
            capturedAt: capturedAt, notes: notes, version: topic.version)
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

    /// Deletes an entry, held for Undo (outbox.md §9.2), in the store `scope` names; returns after
    /// the commit. Throws `EntryWriteError.scopeChanged` once that store isn't the active one.
    func delete(entryId: UUID, topicId: UUID, in scope: EntryScope) async throws {
        try await requireSession(scope).delete(entryId: entryId, topicId: topicId, undoable: true)
    }

    /// Deletes a row shown from the store `binding` names (a list's own binding, not the active
    /// store's), and returns the scope for the Undo toast. A row left over from before a server
    /// switch or reset is refused (`scopeChanged`) instead of deleting its id in the new store.
    func delete(_ entry: ViewEntry, from binding: AppSession.Binding) async throws -> EntryScope {
        let scope = Self.scope(binding)
        try await delete(entryId: entry.id, topicId: entry.entry.topicId, in: scope)
        return scope
    }

    // MARK: Record screen (EntryFixing)

    func discard(_ entry: LoggedEntry) async throws {
        let session = try requireSession(entry.scope)
        guard let outbox = session.outbox else { throw AppSession.SessionError.noStore }
        try await outbox.discard(itemId: entry.id.wireString, origin: .app)
    }

    func fix(
        itemId: String, rowVersion: Int, topic: EntryTopic, answers: [String: AnswerValue], capturedAt: Date,
        notes: String?, in scope: EntryScope
    ) async throws -> LoggedEntry {
        let session = try requireSession(scope)
        guard let outbox = session.outbox, let id = UUID(uuidString: itemId) else {
            throw AppSession.SessionError.noStore
        }
        let body = EntryCreateDTO(
            id: nil, answers: answers, source: OutboxOrigin.app.source, capturedAt: capturedAt, notes: notes,
            version: topic.version)
        try await outbox.fix(
            itemId: itemId,
            payload: .entryCreate(topic: TopicRef(id: topic.id, slug: topic.slug, name: topic.name), body: body),
            rowVersion: rowVersion)
        await session.scheduler?.requestFlush(reason: .enqueue)
        return LoggedEntry(id: id, scope: scope)
    }

    func rowVersion(itemId: String, in scope: EntryScope) async throws -> Int? {
        let session = try requireSession(scope)
        return try await session.store?.outbox.item(id: itemId)?.rowVersion
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
        case .failed(let info): .failed(info?.message ?? "The server refused it", problem: info?.problem)
        case .retired: .notSaved
        }
    }

    static func failure(_ error: any Error) -> EntryWriteFailure {
        switch error {
        case OutboxError.entryDeleted: .notSaved
        case OutboxError.itemChanged: .message("This entry changed meanwhile. Check it and save again.")
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
