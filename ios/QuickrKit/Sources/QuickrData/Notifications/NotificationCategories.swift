import Foundation
import GRDB
import QuickrCore

/// Category registration (notifications.md §5): the registry's `notification_category` table,
/// and the system's category set kept to its highest-priority rows, at most ``registrationCap``.
///
/// - ``register(_:)`` (§5.2): one `IMMEDIATE` registry transaction inserts the rows (current, with
///   their due time), reads the capped selection and hands it to `setNotificationCategories`
///   (synchronous). The registry's write lock is the cross-process mutex, and every process
///   selects from the same table by the same rule, so none registers a set that drops another's
///   higher-priority category.
/// - ``reconcile()`` (§5.3): on activation (and at the start of an NSE run) re-registers when the
///   system is missing any category of the capped selection. The center is asked outside any
///   transaction.
/// - ``refresh(from:)``: the app's call after a sync, a server switch, a reset or launch: the
///   category of every quick-loggable active topic in the store, computed with the server's rules,
///   becomes the server's current set. The NSE may never run (spike F1), so these must be
///   registered ahead of any push.
///
/// The selection (§5.2), in order: current categories of topics due now or within ``dueWindow``
/// (soonest first); categories of delivered notifications (still on screen); then the most
/// recently wanted. A row outside the selection that is neither current nor on screen can't be
/// needed again, so the same transaction deletes it.
public struct NotificationCategories: Sendable {
    /// At most this many categories are registered (§5.2). The system keeps at most 100 (checkpoint
    /// D's probe read back 100 of 150, 1,000 and 5,000 on the iOS 26 simulator); 90 leaves room.
    /// D9 on a device confirms it; change it here only.
    public static let registrationCap = 90
    /// A current category whose topic is due within this long (or overdue) comes first.
    public static let dueWindow: TimeInterval = 7 * 86_400

    public let registry: Registry
    public let center: any NotificationCenterProtocol
    let wallClock: any WallClock
    /// At most this many registered; nil registers every row (checkpoint D9 only, which measures
    /// the system's own limit).
    let cap: Int?

    public init(
        registry: Registry, center: any NotificationCenterProtocol, wallClock: any WallClock = SystemWallClock(),
        cap: Int? = NotificationCategories.registrationCap
    ) {
        self.registry = registry
        self.center = center
        self.wallClock = wallClock
        self.cap = cap
    }

    /// A row to insert: the category of one topic for one server, and when that topic is next due
    /// (nil: unscheduled, or not known).
    public struct Row: Sendable, Hashable {
        public var serverId: String
        public var topicId: String
        public var category: NotificationCategory
        public var dueAt: Date?

        public init(serverId: String, topicId: String, category: NotificationCategory, dueAt: Date? = nil) {
            self.serverId = serverId
            self.topicId = topicId
            self.category = category
            self.dueAt = dueAt
        }
    }

    /// §5.2: inserts `rows` (an existing id keeps its actions; never changed in place), marks them
    /// current with their due time and registers the capped selection. Returns the registered ids.
    @discardableResult
    public func register(_ rows: [Row]) async throws -> [String] {
        try await update(rows, replacingCurrentOf: nil, always: true)
    }

    /// §5.3: re-registers when the system is missing any category of the capped selection. Returns
    /// whether it did. Asks the center before the (short) read, never inside a transaction.
    @discardableResult
    public func reconcile() async throws -> Bool {
        let registered = Set(await center.notificationCategories().map(\.id))
        let delivered = await deliveredCategories()
        let now = wallClock.now()
        let cap = cap
        let selection = try await registry.writer.read { db in
            try Self.select(db, now: now, delivered: delivered, cap: cap).selected
        }
        guard !Set(selection.map(\.id)).isSubset(of: registered) else { return false }
        // Cancelled while the center answered (the NSE's time ran out): no registration.
        try Task.checkCancellation()
        try await register([])
        return true
    }

    /// The categories of every quick-loggable active topic in `store` become its server's current
    /// set (with their due times). Registers when the capped selection changed. Returns the
    /// topics' category ids.
    @discardableResult
    public func refresh(from store: LocalStore) async throws -> [String] {
        let rows = try await Self.rows(in: store, now: wallClock.now())
        try await update(rows, replacingCurrentOf: store.serverId, always: false)
        return rows.map(\.category.id)
    }

    /// One registry transaction: `replacingCurrentOf`'s rows stop being current, `rows` are
    /// inserted or touched (current, due time, last wanted now), rows that can't be needed are
    /// deleted, and the selection is registered: always, or only when it changed.
    private func update(_ rows: [Row], replacingCurrentOf serverId: String?, always: Bool) async throws -> [String] {
        // A cancelled caller (the NSE out of time) registers nothing.
        try Task.checkCancellation()
        // On screen now: asked outside any transaction (§5.2), before the write lock.
        let delivered = await deliveredCategories()
        try Task.checkCancellation()
        let now = wallClock.now()
        let cap = cap
        let center = center
        let encoded = try rows.map { row in (row, try Self.encode(row.category.actions)) }
        return try await registry.writer.writeWithoutTransaction { db in
            var registered: [String] = []
            try db.inTransaction(.immediate) {
                let before = try Self.select(db, now: now, delivered: delivered, cap: cap).selected.map(\.id)
                if let serverId {
                    try db.execute(
                        sql: "UPDATE notification_category SET current = 0 WHERE server_id = ?", arguments: [serverId])
                }
                for (row, actions) in encoded {
                    try db.execute(
                        sql: """
                            INSERT INTO notification_category
                              (id, server_id, topic_id, actions_json, created_at, current, due_at, used_at)
                            VALUES (?, ?, ?, ?, ?, 1, ?, ?)
                            ON CONFLICT (id) DO UPDATE SET current = 1, due_at = excluded.due_at, used_at = excluded.used_at
                            """,
                        arguments: [
                            row.category.id, row.serverId, row.topicId, actions, now.timeIntervalSince1970,
                            row.dueAt?.timeIntervalSince1970, now.timeIntervalSince1970,
                        ])
                }
                let after = try Self.select(db, now: now, delivered: delivered, cap: cap)
                for id in after.unneeded {
                    try db.execute(sql: "DELETE FROM notification_category WHERE id = ?", arguments: [id])
                }
                registered = after.selected.map(\.id)
                // Synchronous, under the registry's write lock: no other process registers in between.
                if always || Set(registered) != Set(before) { center.setNotificationCategories(after.selected) }
                return .commit
            }
            return registered
        }
    }

    /// The category ids of quickR's delivered notifications.
    private func deliveredCategories() async -> Set<String> {
        Set(await center.deliveredNotifications().map(\.categoryIdentifier).filter { !$0.isEmpty })
    }

    /// One row per quick-loggable active topic of the store (its current version), with the
    /// option counts and last value read from the store's view (queued entries included).
    public static func rows(in store: LocalStore, now: Date) async throws -> [Row] {
        let serverId = store.serverId
        return try await store.writer.read { db in
            try StoreView.topics(db).compactMap { view -> Row? in
                let topic = view.topic
                guard topic.status == .active, let quick = QuickLog(questions: topic.questions) else { return nil }
                let key = quick.question.key
                let entries = try StoreView.entries(db, topicId: topic.id.wireString, countedOnly: true)
                var counts: [String: Int] = [:]
                if case .chips(_, let options) = quick, options.count > NotificationCategory.shownOptions {
                    for entry in entries {
                        if case .string(let value) = entry.entry.answers[key] { counts[value, default: 0] += 1 }
                    }
                }
                // Newest first (captured_at, then id): the latest answer to the key.
                let last = entries.lazy.compactMap { $0.entry.answers[key] }.first
                guard
                    let category = NotificationCategory(
                        serverId: serverId, topicId: topic.id.wireString, version: topic.currentVersion,
                        questions: topic.questions, counts: counts, last: last)
                else { return nil }
                // When it's due: since when, if it is; otherwise next. Nil when it sends no
                // reminders (unscheduled, or `notify` off), so it has no due rank.
                let due = topic.schedule?.notify == true ? TopicListing.due(of: topic, at: now) : nil
                return Row(
                    serverId: serverId, topicId: topic.id.wireString, category: category,
                    dueAt: due.flatMap { $0.isDue ? $0.dueSince ?? now : $0.nextDueAt })
            }
        }
    }

    /// The capped selection (§5.2) and the rows that can't be needed any more: outside it, not
    /// current and not on screen. A row this build can't read (an unknown action kind from a newer
    /// build) keeps its readable actions.
    static func select(_ db: Database, now: Date, delivered: Set<String>, cap: Int?) throws
        -> (selected: [NotificationCategorySpec], unneeded: [String])
    {
        struct Candidate {
            let id: String
            let json: String
            let current: Bool
            let dueAt: Double?
            let usedAt: Double
        }
        let candidates = try GRDB.Row.fetchAll(
            db, sql: "SELECT id, actions_json, current, due_at, used_at FROM notification_category"
        ).map {
            Candidate(
                id: $0["id"], json: $0["actions_json"], current: $0["current"], dueAt: $0["due_at"],
                usedAt: $0["used_at"])
        }
        let horizon = now.timeIntervalSince1970 + dueWindow
        // (tier, then soonest due or most recently wanted); the id breaks ties, so every process
        // selects the same rows from the same table.
        func rank(_ c: Candidate) -> (Int, Double) {
            if c.current, let due = c.dueAt, due <= horizon { return (0, due) }
            if delivered.contains(c.id) { return (1, -c.usedAt) }
            return (2, -c.usedAt)
        }
        let ordered = candidates.sorted { a, b in
            let (ra, rb) = (rank(a), rank(b))
            return ra != rb ? ra < rb : a.id < b.id
        }
        let kept = cap.map { Array(ordered.prefix($0)) } ?? ordered
        let keptIds = Set(kept.map(\.id))
        let unneeded = ordered.filter { !keptIds.contains($0.id) && !$0.current && !delivered.contains($0.id) }
        let selected = kept.map { c in
            NotificationCategorySpec(id: c.id, actions: ((try? decode(c.json)) ?? []).compactMap(\.spec))
        }
        return (selected, unneeded.map(\.id))
    }

    static func encode(_ actions: [NotificationCategory.Action]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(actions), as: UTF8.self)
    }

    static func decode(_ json: String) throws -> [NotificationCategory.Action] {
        try JSONDecoder().decode([NotificationCategory.Action].self, from: Data(json.utf8))
    }
}
