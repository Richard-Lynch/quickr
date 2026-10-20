import Foundation
import QuickrCore

/// The entry writes a screen makes, in UI terms. The app implements it over `AppSession`
/// (`SessionEntryWriter`); tests use a fake.
@MainActor
public protocol EntryWriter: AnyObject {
    /// Enqueues the entry durably and returns its id (also its outbox item's id).
    func log(_ topic: QuickLogTopic, answers: [String: AnswerValue]) async throws -> UUID
    /// Asks for a flush and waits up to `wait` for the outcome (`OutboxFlushScheduler.sendNow`).
    func sendNow(_ entryId: UUID, wait: Duration) async -> EntryDelivery
    /// Undo of a log: removes the create, or queues a DELETE if it may have been sent. Done either way.
    func undoLog(_ entryId: UUID) async throws
    /// Undo of a held delete: true when the entry is restored, false when the delete already left.
    func undoDelete(_ entryId: UUID) async throws -> Bool
    /// What to tell the user about a refused write.
    func failure(_ error: any Error) -> EntryWriteFailure
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
    public func logged(entryId: UUID, label: String, topicName: String, sent: Bool) {
        center.show(
            Toast(
                "Logged \(label)", message: sent ? topicName : "\(topicName) · saved on this device, will sync",
                tone: sent ? .ok : .info,
                action: Toast.Action("Undo") { [weak self] in
                    Task { await self?.undoLog(entryId: entryId, topicName: topicName) }
                }))
    }

    public func logFailed(topicName: String, _ failure: EntryWriteFailure) {
        switch failure {
        case .notSaved:
            center.show(Toast("Not saved", message: "This entry was deleted, so it won’t be recorded.", tone: .danger))
        case .message(let message):
            center.show(Toast("Couldn’t log \(topicName)", message: message, tone: .danger))
        }
    }

    /// The Undo of a log. Undone means the entry was never sent or its id is reserved on the server.
    public func undoLog(entryId: UUID, topicName: String) async {
        do {
            try await writer.undoLog(entryId)
            center.show(Toast("Undone", message: "\(topicName) entry removed.", tone: .info))
        } catch {
            let message =
                switch writer.failure(error) {
                case .notSaved: "This entry was already deleted"
                case .message(let message): message
                }
            center.show(
                Toast(
                    "Couldn’t undo", message: "\(message) — delete it from \(topicName) › Entries.", tone: .danger))
        }
    }

    /// "Entry deleted", with Undo while the delete is held (the entries list and entry screen).
    public func deleted(entryId: UUID) {
        center.show(
            Toast(
                "Entry deleted",
                action: Toast.Action("Undo") { [weak self] in
                    Task { await self?.undoDelete(entryId: entryId) }
                }))
    }

    public func undoDelete(entryId: UUID) async {
        do {
            if try await writer.undoDelete(entryId) {
                center.show(Toast("Entry restored", tone: .info))
            } else {
                center.show(Toast("Couldn’t undo", message: "The delete was already sent.", tone: .danger))
            }
        } catch {
            let message =
                switch writer.failure(error) {
                case .notSaved: "This entry was already deleted"
                case .message(let message): message
                }
            center.show(Toast("Couldn’t undo", message: message, tone: .danger))
        }
    }
}
