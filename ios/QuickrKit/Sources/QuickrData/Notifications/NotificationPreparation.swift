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
/// Everything else (a test push, `v > 1`, `sync`, not quickR's) is delivered untouched, and so is
/// a reminder whose ids or descriptor break the contract (``isWellFormed(_:)``): nothing of it is
/// registered in the append-only table.
///
/// The NSE's time can run out mid-way (`serviceExtensionTimeWillExpire` delivers the original):
/// it cancels the task, and every side effect (removals, registration) checks for that first.
/// The store reads are bounded (`StoreView.dueTopics`, `hasPendingEntry`): no entry answers are
/// held beyond one queued entity at a time.
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
        guard let q = incoming.quickr, q.v == 1, q.kind == "due", Self.isWellFormed(q) else { return out }
        let arriving = NotificationSnapshot(
            id: incoming.id, categoryIdentifier: incoming.categoryIdentifier, quickr: q)

        // L1: our own pending local reminder for this slot, and delivered local ones for it.
        if let slot = q.slot, !Task.isCancelled {
            center.removePendingNotificationRequests(withIdentifiers: [slot.localRequestIdentifier])
        }
        let delivered = await center.deliveredNotifications()
        let duplicates = ReminderDedup.identifiersToRemove(arriving: arriving, delivered: delivered)
        if !duplicates.isEmpty, !Task.isCancelled { center.removeDeliveredNotifications(withIdentifiers: duplicates) }

        // Before first unlock the registry can't be opened: untouched.
        guard let registry = try? registry() else { return out }
        // Adds and evicts only: deleting rows is the app's job (§5.2), off the NSE's budget.
        let categories = NotificationCategories(
            registry: registry, center: center, wallClock: ClosureWallClock(now), prunes: false)
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

        // A timed reminder's Start isn't registered until the app handles it (I-NOTIF, timers.md
        // §10.2): until then it shows as a plain reminder, as before.
        if let descriptor = q.quickLog, descriptor != .timed, let topicId = q.topicId, let version = q.version {
            let category = NotificationCategory(
                serverId: q.serverId, topicId: topicId, version: version, descriptor: descriptor)
            if category.id != incoming.categoryIdentifier {
                Self.log.notice(
                    "category drift: server \(incoming.categoryIdentifier, privacy: .public), client \(category.id, privacy: .public)"
                )
            }
            guard !Task.isCancelled else { return out }
            // The reminder being shown ranks first in the capped selection (§5.2).
            _ = try? await categories.register(
                [.init(serverId: q.serverId, topicId: topicId, category: category)], as: .pushed)
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
        if !older.isEmpty, !Task.isCancelled { center.removeDeliveredNotifications(withIdentifiers: older.map(\.id)) }
        return out
    }

    /// L6 and the badge (§8), from the active store's view at `now + skew`. A read that fails leaves
    /// both alone.
    private func prepareFromActiveStore(_ store: LocalStore, q: QuickrNotificationInfo, out: inout Prepared) async {
        // The topics and their open runs in one read, so the badge counts one state of the store.
        guard
            let (topics, openRuns) = try? await store.writer.read({ db in
                (try StoreView.dueTopics(db), try RunOverlay.openRunTopics(db))
            })
        else { return }
        let clock = (try? await store.syncState.syncState())?.serverClock ?? .device
        let now = clock.now(at: now())
        if let topicId = q.topicId, let dueSince = q.dueSince.flatMap(Self.date),
            (try? await store.writer.read({ db in
                try StoreView.hasPendingEntry(db, topicId: topicId, capturedSince: dueSince)
            })) == true
        {
            out.body = Self.alreadyLoggedBody
            out.categoryIdentifier = ""
        }
        out.badge = TopicListing.dueCount(topics.map(\.topic), now: now, openRuns: openRuns)
    }

    /// The reminder's ids and descriptor keep the contract (§2.1, §2.3, §4.2), so its category's
    /// action ids parse: lowercase canonical UUIDs, a version ≥ 1, a key and option values in the key
    /// grammar (no `|`), distinct values, 1–6 active options with all of up to 4 shown or the 3
    /// most used of 5–6, labels within 64 scalars, and number bounds that hold together.
    static func isWellFormed(_ q: QuickrNotificationInfo) -> Bool {
        guard ActionIdentifier.isCanonicalUUID(q.serverId), let topicId = q.topicId,
            ActionIdentifier.isCanonicalUUID(topicId)
        else { return false }
        guard let descriptor = q.quickLog else { return q.version.map { $0 >= 1 } ?? true }
        guard let version = q.version, version >= 1 else { return false }
        // A single or timed topic's descriptor has no key (its action's is empty); every other one has one.
        guard descriptor == .single || descriptor == .timed || ActionIdentifier.isKey(descriptor.key) else {
            return false
        }
        func fits(_ text: String?) -> Bool { (text?.unicodeScalars.count ?? 0) <= NotificationCategory.maxLabelLength }
        switch descriptor {
        case .choice(let choice):
            let values = choice.options.map(\.value)
            let shown =
                choice.totalOptions <= NotificationCategory.shownOptions
                ? choice.totalOptions : NotificationCategory.mostUsedOptions
            return (1...6).contains(choice.totalOptions) && values.count == shown
                && values.allSatisfy(ActionIdentifier.isKey) && Set(values).count == values.count
                && fits(choice.label) && choice.options.allSatisfy { fits($0.label) }
        case .number(let number):
            return ["int", "double"].contains(number.type) && fits(number.label) && fits(number.unit)
                && (number.decimals.map { (0...10).contains($0) } ?? true)
                && inOrder([number.min, number.lastValue, number.max], type: number.type)
        case .single:
            return true
        case .timed:
            return true
        }
    }

    /// The numbers present are of the question's type and ascending, compared exactly: an int's
    /// as integers (a binary64 can't tell 2^53 from 2^53 + 1), a double's as finite doubles.
    static func inOrder(_ numbers: [QuickLogNumber?], type: String) -> Bool {
        let present = numbers.compactMap(\.self)
        switch type {
        case "int":
            let ints = present.compactMap { if case .int(let n) = $0 { n } else { nil } }
            return ints.count == present.count && zip(ints, ints.dropFirst()).allSatisfy { $0 <= $1 }
        default:
            let doubles = present.compactMap { if case .double(let x) = $0 { x } else { nil } }
            return doubles.count == present.count && doubles.allSatisfy(\.isFinite)
                && zip(doubles, doubles.dropFirst()).allSatisfy { $0 <= $1 }
        }
    }

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
