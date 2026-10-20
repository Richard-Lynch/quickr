import Foundation
import OSLog
import QuickrCore

/// The Notification Service Extension's work on an incoming push (notifications.md §6), on value
/// types so it runs on the host: what to change in the notification before it is shown. No
/// network calls and no outbox access; the active store is only read.
///
/// For a `v: 1` `due` reminder:
/// 1. **L1** (§11.2): cancel our pending local reminder for the slot and remove delivered local
///    ones for it. No store needed, so this also runs before first unlock.
/// 2. Open the registry. When it can't be opened (before first unlock: file protection), the
///    notification goes out untouched.
/// 3. Reconcile categories (§5.3). A push from a server the registry doesn't know loses its
///    category (its actions could only be dropped).
/// 4. With a `quick_log`: compute the category as the server does, register it (§5.2) and use it,
///    logging a drift from the payload's.
/// 5. When the push is from the **active** server and its store opens: a slot already satisfied by
///    an entry only this device has says so, without actions (L6); the badge is the active store's
///    due count (§8). Any other push leaves the badge alone (N9).
/// 6. Remove delivered reminders for the same topic with an older slot.
///
/// Everything else (a test push, `v > 1`, `sync`, not quickR's) is delivered untouched.
public struct NotificationPreparation: Sendable {
    /// The notification as it arrived.
    public struct Incoming: Sendable, Hashable {
        public var id: String
        public var body: String
        public var categoryIdentifier: String
        public var quickr: QuickrNotificationInfo?

        public init(id: String, body: String, categoryIdentifier: String, quickr: QuickrNotificationInfo?) {
            self.id = id
            self.body = body
            self.categoryIdentifier = categoryIdentifier
            self.quickr = quickr
        }
    }

    /// What to show: the arriving values unless changed; `badge` nil leaves the badge alone.
    public struct Prepared: Sendable, Hashable {
        public var body: String
        public var categoryIdentifier: String
        public var badge: Int?
    }

    /// L6's body for a slot already logged on this device but not synced yet.
    public static let alreadyLoggedBody = "Already logged on this iPhone · syncing"

    private static let log = Logger(subsystem: "com.bahumia.quickr", category: "nse")

    public let center: any NotificationCenterProtocol
    /// The registry, read-write (category rows). Throws when it can't be opened (before first
    /// unlock).
    public let registry: @Sendable () throws -> Registry
    /// The active store, read-only; nil when it can't be opened (no file yet, a reset, file
    /// protection).
    public let activeStore: @Sendable () throws -> LocalStore?
    public let now: @Sendable () -> Date

    public init(
        center: any NotificationCenterProtocol, registry: @escaping @Sendable () throws -> Registry,
        activeStore: @escaping @Sendable () throws -> LocalStore?, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.center = center
        self.registry = registry
        self.activeStore = activeStore
        self.now = now
    }

    public func prepare(_ incoming: Incoming) async -> Prepared {
        var out = Prepared(body: incoming.body, categoryIdentifier: incoming.categoryIdentifier, badge: nil)
        guard let q = incoming.quickr, q.v == 1, q.kind == "due" else { return out }
        let arriving = NotificationSnapshot(
            id: incoming.id, categoryIdentifier: incoming.categoryIdentifier, quickr: q)

        // L1: our own pending local reminder for this slot, and delivered local ones for it.
        if let slot = q.slot {
            center.removePendingNotificationRequests(withIdentifiers: [slot.localRequestIdentifier])
        }
        let delivered = await center.deliveredNotifications()
        let duplicates = ReminderDedup.identifiersToRemove(arriving: arriving, delivered: delivered)
        if !duplicates.isEmpty { center.removeDeliveredNotifications(withIdentifiers: duplicates) }

        // Before first unlock the registry can't be opened: untouched.
        guard let registry = try? registry() else { return out }
        let categories = NotificationCategories(registry: registry, center: center)
        _ = try? await categories.reconcile()
        let known: RegisteredServer?
        do {
            known = try await registry.repository.server(id: q.serverId)
        } catch {
            return out
        }
        guard known != nil else {
            out.categoryIdentifier = ""
            return out
        }

        if let descriptor = q.quickLog, let topicId = q.topicId, let version = q.version {
            let category = NotificationCategory(
                serverId: q.serverId, topicId: topicId, version: version, descriptor: descriptor)
            if category.id != incoming.categoryIdentifier {
                Self.log.notice(
                    "category drift: server \(incoming.categoryIdentifier, privacy: .public), client \(category.id, privacy: .public)"
                )
            }
            _ = try? await categories.register(
                [.init(serverId: q.serverId, topicId: topicId, category: category)])
            out.categoryIdentifier = category.id
        }

        if (try? await registry.repository.activeServerId()) == q.serverId,
            let store = try? activeStore(), store.serverId == q.serverId
        {
            await prepareFromActiveStore(store, q: q, out: &out)
        }

        // Older reminders for the same topic are superseded by this one.
        let older = delivered.filter { snapshot in
            guard snapshot.id != incoming.id, let other = snapshot.quickr, other.kind == "due",
                other.serverId == q.serverId, other.topicId == q.topicId, let theirs = other.dueSince,
                let ours = q.dueSince
            else { return false }
            return Self.isEarlier(theirs, than: ours)
        }
        if !older.isEmpty { center.removeDeliveredNotifications(withIdentifiers: older.map(\.id)) }
        return out
    }

    /// L6 and the badge (§8), from the active store's view at `now + skew`. A read that fails leaves
    /// both alone.
    private func prepareFromActiveStore(_ store: LocalStore, q: QuickrNotificationInfo, out: inout Prepared) async {
        guard let topics = try? await store.topics.topics() else { return }
        let skew = (try? await store.syncState.syncState())?.skewMilliseconds ?? 0
        let now = now().addingTimeInterval(skew / 1000)
        if let topicId = q.topicId.flatMap(UUID.init(uuidString:)), let dueSince = q.dueSince.flatMap(Self.date),
            await Self.loggedLocally(store, topicId: topicId, since: dueSince)
        {
            out.body = Self.alreadyLoggedBody
            out.categoryIdentifier = ""
        }
        out.badge = TopicListing.badgeCount(topics.map(\.topic), now: now)
    }

    /// Whether an entry only this device has (its create or edit still queued) was captured at
    /// or after the slot: the slot is satisfied here, the server doesn't know yet.
    static func loggedLocally(_ store: LocalStore, topicId: UUID, since dueSince: Date) async -> Bool {
        // Newest first: every entry since the slot comes before any older one.
        guard let recent = try? await store.entries.entries(topicId: topicId, limit: recentEntries) else {
            return false
        }
        return recent.contains { $0.syncState == .pending && $0.entry.capturedAt >= dueSince }
    }

    /// How many of a topic's newest entries the check reads (the NSE has 24 MB).
    static let recentEntries = 50

    static func date(_ canonical: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return ISO8601DateFormatter().date(from: canonical) ?? formatter.date(from: canonical)
    }

    static func isEarlier(_ a: String, than b: String) -> Bool {
        guard let x = date(a), let y = date(b) else { return a < b }
        return x < y
    }
}

extension QuickrNotificationInfo {
    /// `userInfo["quickr"]` of a notification, or nil when it isn't quickR's (or can't be read).
    public init?(userInfo: [AnyHashable: Any]) {
        guard let object = userInfo["quickr"], JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(withJSONObject: object),
            let info = try? JSONDecoder().decode(QuickrNotificationInfo.self, from: data)
        else { return nil }
        self = info
    }
}
