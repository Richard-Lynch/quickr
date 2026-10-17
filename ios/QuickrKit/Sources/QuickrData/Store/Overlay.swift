import Foundation
import QuickrCore

/// A topic as the view shows it (sync-protocol.md §3.2): the server row with the archive items
/// applied and derived fields recomputed. `due` is left nil for DUE to fill.
public struct ViewTopic: Sendable, Hashable, Identifiable {
    public var topic: Topic
    public var syncState: RecordSyncState

    public init(topic: Topic, syncState: RecordSyncState) {
        self.topic = topic
        self.syncState = syncState
    }

    public var id: UUID { topic.id }
}

/// One entity's view row: the server row (if any) with its outbox items applied in `seq` order,
/// exactly per the §3.2 table. A pure function, so the table is tested case by case.
public struct EntryOverlay: Sendable, Hashable {
    /// The row to show, before hiding; nil when there's nothing to show.
    public var entry: Entry?
    public var syncState: RecordSyncState
    /// An active or held `entry.delete` hides the row.
    public var hidden: Bool
    /// Hidden by a `held` delete, so Undo can bring it back.
    public var undoable: Bool
    /// The entity's `entry.create` failed and the server has no row: it shows only in the pinned
    /// "Not synced" section and is excluded from derived fields.
    public var createFailed: Bool

    public var isVisible: Bool { entry != nil && !hidden }
    /// Counted for `entry_count`, `last_captured_at` and version counts (§3.3).
    public var isCounted: Bool { isVisible && !createFailed }

    public var viewEntry: ViewEntry? { isVisible ? entry.map { ViewEntry(entry: $0, syncState: syncState) } : nil }

    /// `items` are the entity's unresolved items; they are applied in `seq` order. The caller
    /// handles tombstones (a tombstoned id never appears) and the topic join.
    public static func resolve(server: Entry?, items: [OutboxItem]) throws -> EntryOverlay {
        var entry = server
        var hidden = false
        var undoable = false
        var createFailed = false
        var pending = false
        var failure: OutboxFailureReason?
        for item in items.sorted(by: { $0.seq < $1.seq }) {
            let failed = item.state == .failed
            // A failed item with reason deleted_elsewhere has no row; it appears only in the sync sheet.
            if failed && item.failureReason == .deletedElsewhere { continue }
            switch try item.payload() {
            case .entryCreate(let topic, let body):
                // With a server row, the server row wins: the create has landed.
                guard server == nil else { break }
                entry = try Entry(creating: item, topic: topic, body: body)
                if failed { createFailed = true } else { pending = true }
            case .entryUpdate(_, _, let patch):
                guard var patched = entry else { break }
                patched.apply(patch, at: item.updatedAt)
                entry = patched
                if !failed { pending = true }
            case .entryDelete:
                // A failed delete shows the row with its error; it is not hidden.
                guard !failed else { break }
                hidden = true
                undoable = item.state == .held
                pending = true
            case .topicArchive, .topicUnarchive:
                continue
            }
            if failed { failure = failure ?? item.failureReason ?? .rejected }
        }
        let syncState: RecordSyncState = failure.map { .failed($0) } ?? (pending ? .pending : .synced)
        return EntryOverlay(
            entry: entry, syncState: syncState, hidden: hidden, undoable: undoable, createFailed: createFailed)
    }
}

/// A topic's view row: `topic.archive` sets `archived` with `archived_at` = the item's
/// `created_at`, `topic.unarchive` sets `active`, in `seq` order. Failed topic items are not
/// applied; the topic is flagged instead.
public enum TopicOverlay {
    public static func resolve(server: Topic, items: [OutboxItem]) -> ViewTopic {
        var topic = server
        var pending = false
        var failure: OutboxFailureReason?
        for item in items.sorted(by: { $0.seq < $1.seq }) where item.entityKind == .topic {
            if item.state == .failed {
                failure = failure ?? item.failureReason ?? .rejected
                continue
            }
            switch item.kind {
            case .topicArchive:
                topic.status = .archived
                topic.archivedAt = item.createdAt
            case .topicUnarchive:
                topic.status = .active
                topic.archivedAt = nil
            default:
                continue
            }
            pending = true
        }
        return ViewTopic(topic: topic, syncState: failure.map { .failed($0) } ?? (pending ? .pending : .synced))
    }
}

extension Entry {
    /// The optimistic row an `entry.create` stands for until the server's arrives.
    init(creating item: OutboxItem, topic: TopicRef, body: EntryCreateDTO) throws {
        self.init(
            id: try .wire(item.entityId, "outbox.entity_id"), topicId: try .wire(topic.id, "outbox.topic.id"),
            version: body.version ?? 0, revision: 0, source: body.source ?? item.origin.source, channel: .ios,
            capturedAt: body.capturedAt ?? item.createdAt, createdAt: item.createdAt, updatedAt: item.updatedAt,
            notes: body.notes ?? "", meta: body.meta ?? [:],
            answers: body.answers.compactMapValues { $0?.value })
    }

    /// An `entry.update` patch: `answers` merges by key and `null` removes the key; `captured_at`,
    /// `notes`, `source` and `meta` are replaced when present.
    mutating func apply(_ patch: EntryUpdateDTO, at updatedAt: Date) {
        for (key, value) in patch.answers ?? [:] {
            if let value { answers[key] = value.value } else { answers.removeValue(forKey: key) }
        }
        if let capturedAt = patch.capturedAt { self.capturedAt = capturedAt }
        if let notes = patch.notes { self.notes = notes }
        if let source = patch.source { self.source = source }
        if let meta = patch.meta { self.meta = meta }
        self.updatedAt = updatedAt
    }
}
