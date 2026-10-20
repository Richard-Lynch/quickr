import Foundation
import QuickrCore

/// Which store a write went to: the server and its store generation. A toast's Undo and a
/// `sendNow` act only while it is still the active one, so a server switch or a reset in between
/// never sends them to another store.
public struct EntryScope: Sendable, Hashable {
    public var id: String

    public init(_ id: String) {
        self.id = id
    }
}

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
    func log(_ topic: EntryTopic, answers: [String: AnswerValue], capturedAt: Date?, notes: String?)
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
        try await log(topic.entryTopic, answers: answers, capturedAt: nil, notes: nil)
    }
}

/// The topic an entry is logged against: any topic, not only a quick-log one.
public struct EntryTopic: Sendable, Hashable {
    public var id: UUID
    public var slug: String
    public var name: String
    /// The version the answers are given against (the topic's current one for a new entry).
    public var version: Int

    public init(id: UUID, slug: String, name: String, version: Int) {
        self.id = id
        self.slug = slug
        self.name = name
        self.version = version
    }

    public init(_ topic: Topic) {
        self.init(id: topic.id, slug: topic.slug, name: topic.name, version: topic.currentVersion)
    }
}

/// The record screen's writes beyond `EntryWriter` (the tiles never need them): dropping a
/// refused new entry, fixing a refused one, and reading back the item's version. Every one is
/// tied to the store it acts in, and throws `EntryWriteError.scopeChanged` once that isn't the
/// active one, like Undo.
@MainActor
public protocol EntryFixing: EntryWriter {
    /// Drops a refused new entry from the queue (the record screen keeps the answers on the form;
    /// tiles keep theirs for the sync sheet).
    func discard(_ entry: LoggedEntry) async throws
    /// Replaces a refused entry's body and queues it again (CAS on `rowVersion`). Returns the
    /// entry to `sendNow`.
    func fix(
        itemId: String, rowVersion: Int, topic: EntryTopic, answers: [String: AnswerValue], capturedAt: Date,
        notes: String?, in scope: EntryScope
    ) async throws -> LoggedEntry
    /// The item's current version (every fix moves it), or nil once it is gone.
    func rowVersion(itemId: String, in scope: EntryScope) async throws -> Int?
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
    /// The server refused it, with its message and, when its body had one, its `Problem` (the
    /// record screen puts that on the fields).
    case failed(String, problem: Problem? = nil)
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

    /// The record screen's save (the PWA's texts): "Logged Workout", or "Saved on this device …",
    /// with Undo tied to the entry's store.
    public func recorded(_ entry: LoggedEntry, topicName: String, sent: Bool) {
        center.show(
            Toast(
                sent ? "Logged \(topicName)" : "Saved on this device",
                message: sent ? nil : "It will sync automatically when you’re back online.", tone: sent ? .ok : .info,
                action: Toast.Action("Undo") { [weak self] in
                    Task { await self?.undoLog(entry, topicName: topicName) }
                }))
    }

    /// A fixed entry went out again (no Undo: it is the user's correction).
    public func fixed(topicName: String, sent: Bool) {
        center.show(
            Toast(
                sent ? "Logged \(topicName)" : "Saved on this device",
                message: sent ? nil : "It will sync automatically when you’re back online.", tone: sent ? .ok : .info))
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
        deleted(entryId: entryId, in: scope)
    }

    /// `deleted(entryId:)` for a delete made in `scope` (taken before the delete's await, so a
    /// rebind meanwhile can't point the Undo at another store).
    public func deleted(entryId: UUID, in scope: EntryScope) {
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
