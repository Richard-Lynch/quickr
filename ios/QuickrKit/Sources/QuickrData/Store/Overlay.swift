import Foundation
import QuickrCore

extension OutboxItem {
    /// The decoded `last_error_json`, nil when absent or unreadable.
    public var lastError: OutboxErrorInfo? {
        lastErrorJSON.flatMap { try? WireCoding.decoder().decode(OutboxErrorInfo.self, from: Data($0.utf8)) }
    }
}

/// The questions an entry's answers are read against: `(topic id, version) → questions`. Request-
/// shaped answer maps don't say whether `7` is an int or a double, so answers rebuilt from them are
/// normalized for their question (`AnswerValue.normalized(for:)`).
public typealias QuestionLookup = (_ topicId: UUID, _ version: Int) throws -> [Question]

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
    /// The entity has an unresolved failed `entry.create` (with or without a server row): it shows
    /// only in the pinned "Not synced" section and is excluded from derived fields.
    public var createFailed: Bool

    public var isVisible: Bool { entry != nil && !hidden }
    /// Counted for `entry_count`, `last_captured_at` and version counts (§3.3).
    /// The error of the failed item behind `.failed`.
    public var lastError: OutboxErrorInfo?
    /// The `seq` of the create behind a row the server doesn't have yet (pending or failed):
    /// such rows pin above the list in outbox order. Nil once the server has the entry.
    public var createSeq: Int64?

    public var isCounted: Bool { isVisible && !createFailed }

    public var viewEntry: ViewEntry? {
        isVisible
            ? entry.map { ViewEntry(entry: $0, syncState: syncState, lastError: lastError, createSeq: createSeq) }
            : nil
    }

    /// `items` are the entity's unresolved items; they are applied in `seq` order. The caller
    /// handles tombstones (a tombstoned id never appears) and the topic join. `questions` types the
    /// answers of creates and patches.
    public static func resolve(server: Entry?, items: [OutboxItem], questions: QuestionLookup = { _, _ in [] })
        throws -> EntryOverlay
    {
        var entry = server
        var hidden = false
        var undoable = false
        var createFailed = false
        var pending = false
        var failed: OutboxItem?
        var createSeq: Int64?
        for item in items.sorted(by: { $0.seq < $1.seq }) {
            let isFailed = item.state == .failed
            // A failed item with reason deleted_elsewhere has no row; it appears only in the sync sheet.
            if isFailed && item.failureReason == .deletedElsewhere { continue }
            switch try item.payload() {
            case .entryCreate(let topic, let body):
                // A failed create excludes the entity from derived fields whatever the content
                // shows (§3.2–§3.3).
                if isFailed { createFailed = true }
                // With a server row, the server row wins: the create has landed.
                guard server == nil else { break }
                entry = try Entry(creating: item, topic: topic, body: body, questions: questions)
                createSeq = item.seq
                if !isFailed { pending = true }
            case .entryUpdate(_, _, let patch):
                guard var patched = entry else { break }
                patched.apply(patch, at: item.updatedAt, questions: try questions(patched.topicId, patched.version))
                entry = patched
                if !isFailed { pending = true }
            case .entryDelete:
                // A failed delete shows the row with its error; it is not hidden.
                guard !isFailed else { break }
                hidden = true
                undoable = item.state == .held
                pending = true
            case .topicArchive, .topicUnarchive:
                continue
            }
            if isFailed { failed = item }
        }
        return EntryOverlay(
            entry: entry,
            syncState: failed.map { .failed($0.failureReason ?? .rejected) } ?? (pending ? .pending : .synced),
            hidden: hidden, undoable: undoable, createFailed: createFailed, lastError: failed?.lastError,
            createSeq: createSeq)
    }
}

/// A topic's view row: `topic.archive` sets `archived` with `archived_at` = the item's
/// `created_at`, `topic.unarchive` sets `active`, in `seq` order. Failed topic items are not
/// applied; the topic is flagged instead. `pendingChange` is the kind of the latest queued or
/// failed topic item; `lastError` comes from the latest failed one.
public enum TopicOverlay {
    public static func resolve(server: Topic, items: [OutboxItem]) -> ViewTopic {
        var topic = server
        var pending = false
        var failed: OutboxItem?
        var latest: OutboxKind?
        for item in items.sorted(by: { $0.seq < $1.seq }) where item.entityKind == .topic {
            latest = item.kind
            if item.state == .failed {
                failed = item
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
        return ViewTopic(
            topic: topic,
            syncState: failed.map { .failed($0.failureReason ?? .rejected) } ?? (pending ? .pending : .synced),
            pendingChange: latest, lastError: failed?.lastError)
    }
}

extension Entry {
    /// The optimistic row an `entry.create` stands for until the server's arrives.
    init(creating item: OutboxItem, topic: TopicRef, body: EntryCreateDTO, questions: QuestionLookup) throws {
        let topicId = try UUID.wire(topic.id, "outbox.topic.id")
        let version = body.version ?? 0
        self.init(
            id: try .wire(item.entityId, "outbox.entity_id"), topicId: topicId, version: version, revision: 0,
            source: body.source ?? item.origin.source, channel: .ios,
            capturedAt: body.capturedAt ?? item.createdAt, createdAt: item.createdAt, updatedAt: item.updatedAt,
            notes: body.notes ?? "", meta: body.meta ?? [:],
            answers: body.domainAnswers(for: try questions(topicId, version)))
    }

    /// An `entry.update` patch: `answers` merges by key and `null` removes the key; `captured_at`,
    /// `notes`, `source` and `meta` are replaced when present.
    mutating func apply(_ patch: EntryUpdateDTO, at updatedAt: Date, questions: [Question]) {
        for (key, value) in patch.domainAnswers(for: questions) ?? [:] {
            if let value { answers[key] = value } else { answers.removeValue(forKey: key) }
        }
        if let capturedAt = patch.capturedAt { self.capturedAt = capturedAt }
        if let notes = patch.notes { self.notes = notes }
        if let source = patch.source { self.source = source }
        if let meta = patch.meta { self.meta = meta }
        self.updatedAt = updatedAt
    }
}
