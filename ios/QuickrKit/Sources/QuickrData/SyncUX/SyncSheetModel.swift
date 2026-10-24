import Foundation
import QuickrCore

/// One outbox item as the sync sheet lists it (the PWA's `OutboxRow`), with the actions
/// outbox.md §11 allows in its state. Pure: built from the items, the topics they name and the
/// clocks, and tested on the host.
public struct SyncItemRow: Identifiable, Sendable, Hashable {
    public enum Tone: Sendable, Hashable {
        case waiting
        /// May have been delivered: "Sending… (checking)".
        case checking
        /// A delete in its undo window.
        case held
        /// Queued behind a failed item of its scope (§7.2).
        case blocked
        case failed
    }

    public var id: String
    /// The store the item is in. An action runs only while it is still the active store, so a
    /// server switch or a reset in between never sends it to another store's item with the same id.
    public var scope: EntryScope
    /// "Entry · Mood", "Edit · Mood", "Delete · Mood", "Archive · Mood", "Unarchive · Mood".
    public var title: String
    /// When it happened: the entry's capture time for a log, else when it was queued.
    public var when: Date
    /// The PWA's status line ("Waiting to sync", "Failed — …", "… · retrying shortly").
    public var status: String
    public var tone: Tone
    /// Retry is allowed (failed except deleted elsewhere, pending, uncertain).
    public var canRetry: Bool
    /// "Retry as is" for a failed item, "Retry now" otherwise (the PWA's).
    public var retryTitle: String
    /// RECORD's fix mode, for a failed create that never reached the server (§11 Fix); for a
    /// refused run event, its answers form or its run screen (`runFix`).
    public var fix: Route?
    /// Anything not being sent right now can be discarded (confirmed: "Discard for good").
    public var canDiscard: Bool
    /// A failed item whose entity was deleted elsewhere is dismissed instead.
    public var canDismiss: Bool
    /// Unique across stores: the list's identity for the row.
    public var scopedId: String { "\(scope.id)/\(id)" }
}

/// A topic's name and id, for the rows' titles.
public struct SyncTopicInfo: Sendable, Hashable {
    public var name: String
    public init(name: String) { self.name = name }
}

/// What the sync sheet shows.
public struct SyncSheetModel: Sendable, Hashable {
    public var rows: [SyncItemRow]
    /// "Everything is synced.", or "2 items waiting · 1 failed" (the PWA's header).
    public var headline: String
    /// "Sync now" shows when something is waiting (and is disabled offline).
    public var canSyncNow: Bool
    public var online: Bool
    public var lastSyncAt: Date?

    public init(
        items: [OutboxItem], topics: [String: SyncTopicInfo], online: Bool, lastSyncAt: Date?, now: LeaseInstant,
        scope: EntryScope = EntryScope("")
    ) {
        var ordering = OutboxScope()
        var rows: [SyncItemRow] = []
        var titles: [String: String] = [:]
        for item in items {
            defer { ordering.add(item) }
            let title = Self.title(item, topics: topics)
            titles[item.id] = title
            var blockedBy: String?
            if item.state == .pending || item.state == .uncertain, let first = ordering.earliest(before: item),
                first.state == .failed
            {
                blockedBy = titles[first.id]
            }
            rows.append(Self.row(item, title: title, blockedBy: blockedBy, online: online, now: now, scope: scope))
        }
        self.rows = rows
        self.online = online
        self.lastSyncAt = lastSyncAt
        let failed = rows.count { $0.tone == .failed }
        // A delete in its undo window isn't waiting to sync yet (as on the pill).
        let waiting = rows.count { $0.tone != .failed && $0.tone != .held }
        headline =
            waiting + failed == 0
            ? "Everything is synced."
            : [
                waiting > 0 ? "\(waiting) \(waiting == 1 ? "item" : "items") waiting" : nil,
                failed > 0 ? "\(failed) failed" : nil,
            ].compactMap(\.self).joined(separator: " · ")
        canSyncNow = waiting > 0
    }

    static func title(_ item: OutboxItem, topics: [String: SyncTopicInfo]) -> String {
        var name = topics[item.topicId]?.name
        if name == nil, case .entryCreate(let topic, _)? = try? item.payload() { name = topic.name }
        let event = try? item.runEventPayload()
        if name == nil, let event { name = event.topic.name }
        let topic = name ?? "a topic"
        return switch item.kind {
        case .entryCreate: "Entry · \(topic)"
        case .entryUpdate: "Edit · \(topic)"
        case .entryDelete: "Delete · \(topic)"
        case .topicArchive: "Archive · \(topic)"
        case .topicUnarchive: "Unarchive · \(topic)"
        case .runEvent:
            event?.type == .finish ? "Details · \(topic)" : "\(event?.event.type.capitalized ?? "Timer") · \(topic)"
        }
    }

    static func row(
        _ item: OutboxItem, title: String, blockedBy: String?, online: Bool, now: LeaseInstant, scope: EntryScope
    ) -> SyncItemRow {
        let failed = item.state == .failed
        let deletedElsewhere = failed && item.failureReason == .deletedElsewhere
        var when = item.createdAt
        if case .entryCreate(_, let body)? = try? item.payload(), let capturedAt = body.capturedAt { when = capturedAt }
        let (status, tone) = statusLine(item, blockedBy: blockedBy, online: online, now: now)
        let fixable: Set<OutboxFailureReason> = [.rejected, .topicArchived, .futureTime]
        let canFix = failed && !item.maybeDelivered && item.failureReason.map(fixable.contains) == true
        let topicRef = UUID(uuidString: item.topicId).map { TopicLinkRef(id: $0) }
        let fix: Route? =
            switch item.kind {
            case .entryCreate: canFix ? topicRef.map { .record($0, fix: item.id) } : nil
            case .runEvent: canFix ? topicRef.flatMap { runFix(item, topic: $0) } : nil
            default: nil
            }
        return SyncItemRow(
            id: item.id, scope: scope, title: title, when: when, status: status, tone: tone,
            canRetry: !deletedElsewhere && item.state != .held && item.state != .inFlight,
            retryTitle: failed ? "Retry as is" : "Retry now", fix: fix,
            canDiscard: !deletedElsewhere && item.state != .inFlight, canDismiss: deletedElsewhere)
    }

    /// Fix for a refused run event (timers.md §8.1): answers (a `finish`, or a `stop` that carried
    /// them) refused with a 422 open the run's answers form with them; a plain `stop`, the run
    /// screen, where the run shows open again and can be stopped or discarded. Nothing else.
    static func runFix(_ item: OutboxItem, topic: TopicLinkRef) -> Route? {
        guard let payload = try? item.runEventPayload(), let type = payload.type else { return nil }
        let answers = type == .finish || (type == .stop && payload.event.answers != nil)
        if answers {
            guard item.lastError?.status == 422, let runId = UUID(uuidString: payload.runId) else { return nil }
            return .runDetails(topic, runId: runId, fix: item.id)
        }
        return type == .stop ? .run(topic) : nil
    }

    static func statusLine(_ item: OutboxItem, blockedBy: String?, online: Bool, now: LeaseInstant)
        -> (String, SyncItemRow.Tone)
    {
        switch item.state {
        case .failed:
            if item.failureReason == .deletedElsewhere { return ("Deleted on another device", .failed) }
            return ("Failed — \(item.lastError?.message ?? "rejected")", .failed)
        case .held:
            return ("Deleting — you can still undo", .held)
        case .inFlight:
            return (
                item.maybeDelivered ? "Sending… (checking)" : "Sending…", item.maybeDelivered ? .checking : .waiting
            )
        case .pending, .uncertain:
            if let blockedBy { return ("Waiting for \(blockedBy)", .blocked) }
            let tone: SyncItemRow.Tone = item.state == .uncertain ? .checking : .waiting
            if item.attempts == 0 { return ("Waiting to sync", tone) }
            let error = item.state == .uncertain ? "Sending… (checking)" : (item.lastError?.message ?? "Not sent yet")
            return ("\(error) · retrying \(retryWhen(item.due, online: online, now: now))", tone)
        }
    }

    /// The PWA's: "when back online", "shortly" (within a minute) or "in N min".
    static func retryWhen(_ due: LeaseInstant?, online: Bool, now: LeaseInstant) -> String {
        guard online else { return "when back online" }
        guard let due, !now.hasPassed(deadline: due) else { return "shortly" }
        let seconds = Double(due.ct - now.ct) / 1_000_000_000
        if seconds < 60 { return "shortly" }
        let minutes = Int((seconds / 60).rounded(.up))
        return "in \(minutes) min"
    }
}
