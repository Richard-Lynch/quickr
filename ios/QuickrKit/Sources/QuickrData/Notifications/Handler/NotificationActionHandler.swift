import Foundation
import GRDB
import QuickrCore

/// A response to one of quickR's notifications, reduced to what the handler reads (the app maps
/// `UNNotificationResponse` to it).
public struct NotificationActionResponse: Sendable, Hashable {
    public enum Action: Sendable, Hashable {
        /// The body was tapped (`UNNotificationDefaultActionIdentifier`).
        case open
        /// `UNNotificationDismissActionIdentifier`.
        case dismiss
        /// One of the category's actions: its identifier (`q1|…`).
        case custom(String)
    }

    public var action: Action
    /// What the user typed into a text input action.
    public var userText: String?
    /// The notification's title: the topic name, for messages.
    public var title: String
    /// `userInfo.quickr`; nil for a notification that isn't quickR's.
    public var quickr: QuickrNotificationInfo?

    public init(action: Action, userText: String? = nil, title: String = "", quickr: QuickrNotificationInfo?) {
        self.action = action
        self.userText = userText
        self.title = title
        self.quickr = quickr
    }
}

/// What handling a response did.
public enum NotificationActionOutcome: Sendable, Hashable {
    /// Nothing to do: dismissed, or not a quickR notification.
    case none
    /// Open this PWA path (`quickr.url`) in the app, with a tap-to-fix's text for the record screen.
    case open(path: String, prefill: NotificationPrefill?)
    /// The entry was enqueued in `serverId`'s store; `flush` is how the flush ended (nil when the
    /// store isn't the active one, which is never flushed from here).
    case logged(entryId: UUID, serverId: String, flush: OutboxFlushReport.Ending?)
    /// The reminder was logged before (the first answer wins): nothing was written. Still flushed
    /// like a new entry (`flush`), so a queued first answer goes out now.
    case alreadyLogged(entryId: UUID, OutboxCreateOnceResult.Duplicate, flush: OutboxFlushReport.Ending?)
    /// Nothing was written; the failure notification says why.
    case refused(NotificationActionFailure)
    /// The typed number didn't validate: nothing was written; the tap-to-fix notification is up.
    case needsFix(raw: String, message: String)
}

/// What a tap-to-fix notification brings back to the record screen (notifications.md §7.3): the
/// raw text per question key, for its topic.
public struct NotificationPrefill: Sendable, Hashable {
    public var topicId: String
    public var texts: [String: String]

    public init(topicId: String, texts: [String: String]) {
        self.topicId = topicId
        self.texts = texts
    }
}

/// Why an action couldn't log (notifications.md §7.1 `fail`).
public enum NotificationActionFailure: Sendable, Hashable {
    /// The action doesn't match its reminder (or isn't one).
    case invalid
    /// §6a rule 8: the reminder's server isn't registered any more.
    case unknownServer
    /// Before first unlock: the store can't be opened.
    case locked
    case topicDeleted
    case topicArchived
    /// The store couldn't be opened or written.
    case storeUnavailable

    func message(topic: String) -> String {
        switch self {
        case .invalid, .storeUnavailable: "Couldn't log — open quickR to log"
        case .unknownServer: "This reminder came from a server you've removed from quickR"
        case .locked: "Unlock your iPhone, then tap to log"
        case .topicDeleted: "\(topic) was deleted"
        case .topicArchived: "\(topic) is archived"
        }
    }
}

/// The notification action handler (notifications.md §7.1), in the app process: validates the
/// action against its reminder, writes the entry into that reminder's server's store in one
/// transaction (with the shared action entry id, so a reminder logs once), clears the reminder,
/// updates the badge for the active store and flushes it within the budget. Failures write
/// nothing and post an explanatory notification.
///
/// No call to the notification center happens inside a transaction (§5.2): the delivered and
/// pending snapshots are taken after the write has committed.
public struct NotificationActionHandler: Sendable {
    /// §7.1 step 10 / outbox.md §10: a forced flush, polling the lease within the same budget.
    public static let flushBudget: Duration = .seconds(5)

    let partitions: StorePartitions
    let center: any NotificationCenterProtocol
    /// The sender for a store's outbox (the app's `APIClient` for its server); nil skips the flush.
    let sender: @Sendable (LocalStore) async -> (any OutboxSender)?
    /// The `flush` lease owner (`app:<launch id>`).
    let owner: String
    let wallClock: any WallClock
    /// `UIApplication.isProtectedDataAvailable`: false before first unlock.
    let isProtectedDataAvailable: @Sendable () async -> Bool
    let onSignal: @Sendable (OutboxSignal) -> Void
    /// §7.1 step 9: widgets show due state and last values.
    let reloadWidgets: @Sendable () -> Void
    let flushBudget: Duration
    /// Tests: runs between the preconditions and the write (step 4 → 5), to retire the store there.
    var beforeWriteForTesting: (@Sendable () async -> Void)?

    public init(
        partitions: StorePartitions, center: any NotificationCenterProtocol,
        sender: @escaping @Sendable (LocalStore) async -> (any OutboxSender)?, owner: String,
        wallClock: any WallClock = SystemWallClock(),
        isProtectedDataAvailable: @escaping @Sendable () async -> Bool = { true },
        onSignal: @escaping @Sendable (OutboxSignal) -> Void = { _ in },
        reloadWidgets: @escaping @Sendable () -> Void = {}, flushBudget: Duration = Self.flushBudget
    ) {
        self.partitions = partitions
        self.center = center
        self.sender = sender
        self.owner = owner
        self.wallClock = wallClock
        self.isProtectedDataAvailable = isProtectedDataAvailable
        self.onSignal = onSignal
        self.reloadWidgets = reloadWidgets
        self.flushBudget = flushBudget
    }

    public func handle(_ response: NotificationActionResponse) async -> NotificationActionOutcome {
        guard let q = response.quickr else { return .none }
        switch response.action {
        case .dismiss:
            return .none
        case .open:
            // The body opens `url`; a tap-to-fix notification brings the text it couldn't log.
            guard let url = q.url else { return .none }
            guard q.kind == "fix", let topicId = q.topicId, let texts = q.prefill else {
                return .open(path: url, prefill: nil)
            }
            return .open(path: url, prefill: NotificationPrefill(topicId: topicId, texts: texts))
        case .custom(let identifier):
            return await act(identifier, response, q)
        }
    }

    // MARK: - §7.2

    /// `willPresent`: whether a notification arriving in the foreground is shown. A reminder is not,
    /// and it is removed:
    /// - L2 (§11.2), any server: it is a local reminder for a slot whose remote reminder is
    ///   delivered (a remote one arriving removes the delivered local ones instead, L1/L3);
    /// - its slot is satisfied in the active store's view: the topic has an entry captured at or
    ///   after the slot (local, queued or synced), or the slot's shared action entry id is already
    ///   used (queued, on the server or deleted).
    /// Anything else is shown, including another server's reminder or one the store can't confirm.
    public func shouldPresent(_ notification: NotificationSnapshot) async -> Bool {
        guard let slot = notification.quickr?.slot else { return true }
        let delivered = await center.deliveredNotifications()  // outside any transaction
        let duplicates = ReminderDedup.identifiersToRemove(arriving: notification, delivered: delivered)
        if !duplicates.isEmpty { center.removeDeliveredNotifications(withIdentifiers: duplicates) }
        if duplicates.contains(notification.id) { return false }
        guard (try? await partitions.registry.repository.activeServerId()) == slot.serverId,
            await isProtectedDataAvailable(),
            let store = try? await partitions.openStore(serverId: slot.serverId, role: .app).store,
            let due = try? Date(slot.dueSince, strategy: .iso8601)
        else { return true }
        let entryId = ActionEntryId.make(serverId: slot.serverId, topicId: slot.topicId, dueSince: slot.dueSince)
            .wireString
        let satisfied = try? await store.writer.read { db -> Bool in
            if let last = try StoreView.topic(db, id: slot.topicId)?.topic.lastCapturedAt, last >= due { return true }
            return try !OutboxStorage.items(db, entityKind: .entry, entityId: entryId).isEmpty
                || ServerLayer.isTombstoned(db, kind: .entry, id: entryId)
                || ServerLayer.revision(db, entityKind: .entry, id: entryId) != nil
        }
        guard satisfied == true else { return true }
        center.removeDeliveredNotifications(withIdentifiers: [notification.id])
        return false
    }

    // MARK: - §7.1

    private func act(_ identifier: String, _ response: NotificationActionResponse, _ q: QuickrNotificationInfo)
        async -> NotificationActionOutcome
    {
        guard let topicId = q.topicId else { return .none }  // nothing to point a message at
        let topicName = response.title.isEmpty ? "This topic" : response.title
        // 1. Validate against userInfo.
        guard q.v == 1, q.kind == "due", let action = ActionIdentifier(identifier), action.matches(q),
            let dueSince = q.dueSince, let version = q.version, let quickLog = q.quickLog
        else { return await fail(.invalid, topicId: topicId, topic: topicName, q) }
        let answer: AnswerValue
        switch (action.kind, quickLog) {
        case (.more, _):
            // A `.foreground` action: the app opens on the record screen, nothing preselected.
            guard let url = q.url else { return .none }
            return .open(path: url, prefill: nil)
        case (.option, _):
            answer = .string(action.value)
        case (.number, .number(let number)):
            guard let last = number.lastValue else {
                return await fail(.invalid, topicId: topicId, topic: topicName, q)
            }
            answer =
                switch last {
                case .int(let n): .int(n)
                case .double(let x): .double(x)
                }
        case (.input, .number(let number)):
            let raw = response.userText ?? ""
            switch NotificationNumberInput.parse(raw, for: number) {
            case .success(let value):
                answer = value
            case .failure(let message):
                await postFix(raw: raw, key: number.key, topicId: topicId, topic: topicName, q)
                return .needsFix(raw: raw, message: message.message)
            }
        default:
            return await fail(.invalid, topicId: topicId, topic: topicName, q)
        }

        // 2. The reminder's server must still be registered (§6a rule 8).
        let registry = partitions.registry.repository
        guard (try? await registry.server(id: action.serverId)) != nil else {
            return await fail(.unknownServer, topicId: topicId, topic: topicName, q)
        }
        // 3. That server's current store, active or not.
        guard await isProtectedDataAvailable() else {
            return await fail(.locked, topicId: topicId, topic: topicName, q)
        }
        guard var store = try? await partitions.openStore(serverId: action.serverId, role: .app).store else {
            return await fail(.storeUnavailable, topicId: topicId, topic: topicName, q)
        }
        // 4. Preconditions from that store's view.
        let view: ViewTopic?
        do {
            let (topic, tombstoned) = try await store.writer.read { db in
                (try StoreView.topic(db, id: topicId), try ServerLayer.isTombstoned(db, kind: .topic, id: topicId))
            }
            if tombstoned { return await fail(.topicDeleted, topicId: topicId, topic: topicName, q) }
            if topic?.topic.status == .archived {
                return await fail(.topicArchived, topicId: topicId, topic: topic?.topic.name ?? topicName, q)
            }
            view = topic
        } catch {
            return await fail(.storeUnavailable, topicId: topicId, topic: topicName, q)
        }

        await beforeWriteForTesting?()
        // 5. One IMMEDIATE transaction, with the shared action entry id (§7.4).
        let entryId = ActionEntryId.make(serverId: action.serverId, topicId: topicId, dueSince: dueSince)
        guard let topicUUID = UUID(uuidString: topicId) else {
            return await fail(.invalid, topicId: topicId, topic: topicName, q)
        }
        let ref = TopicRef(
            id: topicUUID, slug: view?.topic.slug ?? q.topicSlug ?? "", name: view?.topic.name ?? response.title)
        let body = EntryCreateDTO(
            id: nil, answers: [action.key: answer], source: nil, capturedAt: wallClock.now(), notes: "", meta: [:],
            version: version)
        let result: OutboxCreateOnceResult
        do {
            result = try await createOnce(&store, entryId: entryId, topic: ref, body: body)
        } catch {
            return await fail(.storeUnavailable, topicId: topicId, topic: topicName, q)
        }
        // 6. The commit posted db-changed through the store's pool.

        // 7. Clear this topic's delivered reminders and the pending local ones now satisfied (L4).
        await clearReminders(serverId: action.serverId, topicId: topicId, store: store)
        // 8. The badge only reflects the active store (§8), as it is now: re-read after the awaits.
        if await isActive(store) { await updateBadge(store) }
        // 9. A new entry changes the topic's due state and last value.
        if case .created = result { reloadWidgets() }
        // 10. Flush the active store only, forced, within the budget; a duplicate too (its first
        // answer may still be queued).
        let flushed: OutboxFlushReport.Ending? = await isActive(store) ? await flush(store) : nil
        switch result {
        case .created: return .logged(entryId: entryId, serverId: action.serverId, flush: flushed)
        case .duplicate(let duplicate): return .alreadyLogged(entryId: entryId, duplicate, flush: flushed)
        }
    }

    /// Whether `store` is the active server's current file right now: the badge and the flush are
    /// for it alone, and a server switch or a reset may have happened during the handler's awaits.
    private func isActive(_ store: LocalStore) async -> Bool {
        let registry = partitions.registry.repository
        guard (try? await registry.activeServerId()) == store.serverId,
            let server = try? await registry.server(id: store.serverId)
        else { return false }
        return server.storeGen == store.storeGen && server.pendingGen == nil
    }

    /// Step 5's transaction. A store retired meanwhile is reopened and the write retried once.
    private func createOnce(_ store: inout LocalStore, entryId: UUID, topic: TopicRef, body: EntryCreateDTO)
        async throws -> OutboxCreateOnceResult
    {
        func attempt(_ store: LocalStore) async throws -> OutboxCreateOnceResult {
            try await store.createEntryIfAbsent(id: entryId, topic: topic, body: body, origin: .notification)
        }
        do {
            return try await attempt(store)
        } catch StoreError.retired {
            store = try await partitions.openStore(serverId: store.serverId, role: .app).store
            return try await attempt(store)
        }
    }

    /// L4 (§11.2): removes every delivered notification of `(server, topic)`, and cancels our pending
    /// local reminders for the topic's slots the view now satisfies (an entry captured at or after
    /// the slot).
    private func clearReminders(serverId: String, topicId: String, store: LocalStore) async {
        let delivered = await center.deliveredNotifications()
        let ids = delivered.filter { $0.quickr?.serverId == serverId && $0.quickr?.topicId == topicId }.map(\.id)
        if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }

        let lastCaptured = try? await store.writer.read { db in
            try StoreView.topic(db, id: topicId)?.topic.lastCapturedAt
        }
        guard let lastCaptured = lastCaptured ?? nil else { return }
        let pending = await center.pendingNotificationRequests()
        let satisfied = pending.filter { request in
            guard let slot = request.quickr?.slot, request.quickr?.origin == .local, slot.serverId == serverId,
                slot.topicId == topicId, request.id == slot.localRequestIdentifier,
                let at = try? Date(slot.dueSince, strategy: .iso8601)
            else { return false }
            return at <= lastCaptured
        }
        if !satisfied.isEmpty { center.removePendingNotificationRequests(withIdentifiers: satisfied.map(\.id)) }
    }

    /// The active store's due count (`dueCount`), at device time plus the measured skew.
    private func updateBadge(_ store: LocalStore) async {
        let wall = wallClock.now()
        guard
            let count = try? await store.writer.read({ db -> Int in
                let state = try Row.fetchOne(db, sql: "SELECT * FROM sync_state WHERE id = 1").map(SyncState.init(row:))
                let skew = state?.skewMilliseconds ?? 0
                let now = wall.addingTimeInterval(skew / 1000)
                return TopicListing.badgeCount(try StoreView.topics(db).map(\.topic), now: now)
            })
        else { return }
        try? await center.setBadgeCount(count)
    }

    private func flush(_ store: LocalStore) async -> OutboxFlushReport.Ending? {
        guard let sender = await sender(store) else { return nil }
        let outbox = Outbox(store: store, sender: sender, owner: owner, onSignal: onSignal)
        return try? await outbox.flush(force: true, budget: flushBudget, leaseWait: flushBudget).ending
    }

    // MARK: - Failure notifications

    /// `fail(msg)`: `quickr.err.{topic_id}` in the topic's thread, no category; tapping opens `url`.
    private func fail(
        _ failure: NotificationActionFailure, topicId: String, topic: String, _ q: QuickrNotificationInfo
    ) async -> NotificationActionOutcome {
        let request = LocalNotificationRequest(
            id: "quickr.err.\(topicId)", title: topic, body: failure.message(topic: topic),
            threadIdentifier: "topic-\(topicId)",
            quickr: QuickrNotificationInfo(
                kind: "error", serverId: q.serverId, topicId: topicId, topicSlug: q.topicSlug, url: q.url))
        try? await center.add(request)
        return .refused(failure)
    }

    /// §7.3 step 5: tap to fix, with the raw text for the record screen.
    private func postFix(raw: String, key: String, topicId: String, topic: String, _ q: QuickrNotificationInfo) async {
        let request = LocalNotificationRequest(
            id: "quickr.fix.\(topicId)", title: "Couldn't log \(topic)",
            body: "“\(raw)” isn't a valid value — tap to fix", threadIdentifier: "topic-\(topicId)",
            quickr: QuickrNotificationInfo(
                kind: "fix", serverId: q.serverId, topicId: topicId, topicSlug: q.topicSlug, url: q.url,
                prefill: [key: raw]))
        try? await center.add(request)
    }
}
