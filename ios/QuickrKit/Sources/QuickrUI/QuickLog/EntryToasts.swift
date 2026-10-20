import Foundation
import QuickrCore

/// A logged entry and the store it went to.
public struct LoggedEntry: Sendable, Hashable {
    public var id: UUID
    public var scope: EntryScope

    public init(id: UUID, scope: EntryScope) {
        self.id = id
        self.scope = scope
    }
}

/// The entry writes a screen makes, in UI terms. The app implements it over `AppSession`
/// (`SessionEntryWriter`); tests use a fake.
@MainActor
public protocol EntryWriter: AnyObject {
    /// The store writes go to now; nil before one is bound.
    var scope: EntryScope? { get }
    /// Enqueues the entry durably and returns its id (also its outbox item's id) and store.
    /// `capturedAt` nil is now; the record screen passes its own time and notes.
    func log(_ topic: QuickLogTopic, answers: [String: AnswerValue], capturedAt: Date?, notes: String?)
        async throws -> LoggedEntry
    /// Asks for a flush and waits up to `wait` for the outcome (`OutboxFlushScheduler.sendNow`).
    /// `.queued` when `scope` is no longer the active store: the entry waits in its own.
    func sendNow(_ entry: LoggedEntry, wait: Duration) async -> EntryDelivery
    /// Undo of a log: removes the create, or queues a DELETE if it may have been sent (true); false
    /// when there was nothing to undo. Throws `EntryWriteError.scopeChanged` once `scope` isn't
    /// the active store.
    func undoLog(_ entryId: UUID, in scope: EntryScope) async throws -> Bool
    /// Undo of a held delete: true when the entry is restored, false when the delete already left.
    /// Throws `EntryWriteError.scopeChanged` like `undoLog`.
    func undoDelete(_ entryId: UUID, in scope: EntryScope) async throws -> Bool
    /// What to tell the user about a refused write.
    func failure(_ error: any Error) -> EntryWriteFailure
}

extension EntryWriter {
    /// A quick-log: captured now, without notes.
    public func log(_ topic: QuickLogTopic, answers: [String: AnswerValue]) async throws -> LoggedEntry {
        try await log(topic, answers: answers, capturedAt: nil, notes: nil)
    }
}

/// Writer errors of the UI layer's own.
public enum EntryWriteError: Error, Sendable, Hashable {
    /// The store the entry went to is no longer the active one (a server switch or a reset).
    case scopeChanged
}

/// What `sendNow` saw within its wait.
public enum EntryDelivery: Sendable, Hashable {
    case sent
    /// Saved on this device; it syncs later.
    case queued
    /// The server refused it, with its message.
    case failed(String)
    /// The entry was deleted meanwhile and will never be recorded.
    case notSaved
}

public enum EntryWriteFailure: Sendable, Hashable {
    /// The entry was deleted (`OutboxError.entryDeleted`): it won't be recorded.
    case notSaved
    /// The entry belongs to a store that is no longer active (`EntryWriteError.scopeChanged`).
    case scopeChanged
    case message(String)
}

/// The toasts around entry writes, with their Undo actions (the PWA's `useQuickLog`,
/// `useUndoLog` and `useDeleteEntryWithUndo`). Undo toasts stay up for the 6 s undo window.
@MainActor
public final class EntryToasts {
    public let center: ToastCenter
    private let writer: any EntryWriter

    public init(center: ToastCenter, writer: any EntryWriter) {
        self.center = center
        self.writer = writer
    }

    /// "Logged Mild", with Undo. Queued entries say they will sync.
    public func logged(_ entry: LoggedEntry, label: String, topicName: String, sent: Bool) {
        center.show(
            Toast(
                "Logged \(label)", message: sent ? topicName : "\(topicName) · saved on this device, will sync",
                tone: sent ? .ok : .info,
                action: Toast.Action("Undo") { [weak self] in
                    Task { await self?.undoLog(entry, topicName: topicName) }
                }))
    }

    public func logFailed(topicName: String, _ failure: EntryWriteFailure) {
        switch failure {
        case .notSaved:
            center.show(Toast("Not saved", message: "This entry was deleted, so it won’t be recorded.", tone: .danger))
        case .scopeChanged:
            center.show(Toast("Couldn’t log \(topicName)", message: "The server changed. Try again.", tone: .danger))
        case .message(let message):
            center.show(Toast("Couldn’t log \(topicName)", message: message, tone: .danger))
        }
    }

    /// The Undo of a log. "Undone" only when the create was removed or a DELETE now reserves its
    /// id; never for a store that is no longer active, nor when there was nothing to undo.
    public func undoLog(_ entry: LoggedEntry, topicName: String) async {
        do {
            if try await writer.undoLog(entry.id, in: entry.scope) {
                center.show(Toast("Undone", message: "\(topicName) entry removed.", tone: .info))
            } else {
                center.show(Toast("Nothing to undo", message: "This entry was already removed.", tone: .info))
            }
        } catch {
            switch writer.failure(error) {
            case .scopeChanged:
                center.show(Toast("Couldn’t undo", message: Self.scopeChanged, tone: .danger))
            case .notSaved:
                center.show(
                    Toast(
                        "Couldn’t undo", message: "This entry was already deleted — check \(topicName) › Entries.",
                        tone: .danger))
            case .message(let message):
                center.show(
                    Toast(
                        "Couldn’t undo", message: "\(message) — delete it from \(topicName) › Entries.", tone: .danger))
            }
        }
    }

    /// "Entry deleted", with Undo while the delete is held (the entries list and entry screen).
    /// Call it right after the delete, so the Undo is tied to that store.
    public func deleted(entryId: UUID) {
        guard let scope = writer.scope else { return }
        center.show(
            Toast(
                "Entry deleted",
                action: Toast.Action("Undo") { [weak self] in
                    Task { await self?.undoDelete(entryId: entryId, in: scope) }
                }))
    }

    public func undoDelete(entryId: UUID, in scope: EntryScope) async {
        do {
            if try await writer.undoDelete(entryId, in: scope) {
                center.show(Toast("Entry restored", tone: .info))
            } else {
                center.show(Toast("Couldn’t undo", message: "The delete was already sent.", tone: .danger))
            }
        } catch {
            let message =
                switch writer.failure(error) {
                case .notSaved: "This entry was already deleted"
                case .scopeChanged: Self.scopeChanged
                case .message(let message): message
                }
            center.show(Toast("Couldn’t undo", message: message, tone: .danger))
        }
    }

    static let scopeChanged = "The server changed since then. Nothing was undone."
}
