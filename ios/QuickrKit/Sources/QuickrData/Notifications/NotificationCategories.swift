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
/// The selection (§5.2), in order: the push a registration is for; categories of pushes shown in
/// the last ``pushWindow`` (latest push first, by a registry counter); current categories of topics due within ``dueWindow`` of now, either way (closest
/// first); categories of delivered notifications (still on screen); then the most recently
/// wanted. A row outside the selection that is neither current nor on screen, and wasn't
/// wanted in the last day, can't be needed again, so the same transaction deletes it.
public struct NotificationCategories: Sendable {
    /// At most this many categories are registered (§5.2). The system keeps at most 100 (checkpoint
    /// D's probe read back 100 of 150, 1,000 and 5,000 on the iOS 26 simulator); 90 leaves room.
    /// D9 on a device confirms it; change it here only.
    public static let registrationCap = 90
    /// A push's category (the NSE's) comes first for this long after the push.
    public static let pushWindow: TimeInterval = 86_400
    /// Next, a current category whose topic is due, or was due, within this long of now.
    public static let dueWindow: TimeInterval = 7 * 86_400
    /// A row wanted this recently is never deleted, even outside the selection: a notification
    /// shown since the caller's snapshot of the delivered ones may still use it (the NSE's row,
    /// which the app's refresh can make not current before it's on any snapshot).
    public static let deleteGrace: TimeInterval = 86_400

    public let registry: Registry
    public let center: any NotificationCenterProtocol
    let wallClock: any WallClock
    /// At most this many registered; nil registers every row (checkpoint D9 only, which measures
    /// the system's own limit).
    let cap: Int?
    /// Whether registering deletes rows that can't be needed. The app does; the NSE, on its tight
    /// budget, only adds and evicts from the selection, and leaves deleting to the app.
    let prunes: Bool

    public init(
        registry: Registry, center: any NotificationCenterProtocol, wallClock: any WallClock = SystemWallClock(),
        cap: Int? = NotificationCategories.registrationCap, prunes: Bool = true
    ) {
        self.registry = registry
        self.center = center
        self.wallClock = wallClock
        self.cap = cap
        self.prunes = prunes
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

    /// How a caller wants its rows (§5.2).
    public enum Role: Sendable {
        /// The topic's category now (the app's refresh; tests and tools): current, with its due
        /// time.
        case current
        /// The category of a push being shown (the NSE): first in the selection for a day. Doesn't
        /// change which row is current; that's the app's view.
        case pushed
    }

    /// §5.2: inserts `rows` (an existing id keeps its actions; never changed in place), marks them
    /// as `role` says and registers the capped selection. Returns the registered ids.
    @discardableResult
    public func register(_ rows: [Row], as role: Role = .current) async throws -> [String] {
        try await update(rows, role: role, replacingCurrentOf: nil, always: true)
    }

    /// §5.3: re-registers when the system is missing any category of the capped selection, or when
    /// another registration happened after the system was asked. Returns whether it did. Asks the center before the (short) read, never inside a transaction.
    @discardableResult
    public func reconcile() async throws -> Bool {
        // The generation first: if any registration happens after the system answers, its answer
        // no longer stands and this re-registers.
        let asked = try await registry.writer.read(Self.generation)
        let registered = Set(await center.notificationCategories().map(\.id))
        let delivered = await deliveredCategories()
        let now = wallClock.now()
        let cap = cap
        let (selection, generation) = try await registry.writer.read { db in
            (try Self.select(db, now: now, delivered: delivered, cap: cap).selected, try Self.generation(db))
        }
        guard generation != asked || !Set(selection.map(\.id)).isSubset(of: registered) else { return false }
        // Cancelled while the center answered (the NSE's time ran out): no registration.
        try Task.checkCancellation()
        try await register([])
        return true
    }

    /// The categories of every quick-loggable active topic in `store` become its server's current
    /// set (with their due times). Registers when the system is missing any of the resulting
    /// selection. Returns the topics' category ids.
    @discardableResult
    public func refresh(from store: LocalStore) async throws -> [String] {
        let rows = try await Self.rows(in: store, now: wallClock.now())
        try await update(rows, role: .current, replacingCurrentOf: store.serverId, always: false)
        return rows.map(\.category.id)
    }

    /// One registry transaction: `replacingCurrentOf`'s rows stop being current, `rows` are
    /// inserted or touched as `role` says, rows that can't be needed are deleted (unless this
    /// process doesn't prune), and the selection is registered: always, or when the system's set
    /// (asked before the transaction) is missing any of it or may have changed since (another
    /// registration moved the registry's registration generation in between).
    private func update(_ rows: [Row], role: Role, replacingCurrentOf serverId: String?, always: Bool)
        async throws -> [String]
    {
        // A cancelled caller (the NSE out of time) registers nothing.
        try Task.checkCancellation()
        // Asked outside any transaction (§5.2), before the write lock: when registering only on a
        // change, what the system has (with the registration generation read before asking, so a
        // registration after it is noticed under the lock); and what's on screen.
        var asked: (generation: Int64, ids: Set<String>)?
        if !always {
            let generation = try await registry.writer.read(Self.generation)
            asked = (generation, Set(await center.notificationCategories().map(\.id)))
        }
        let installed = asked
        let delivered = await deliveredCategories()
        try Task.checkCancellation()
        let (cap, prunes, center, wallClock) = (cap, prunes, center, wallClock)
        let encoded = try rows.map { row in (row, try Self.encode(row.category.actions)) }
        return try await registry.writer.writeWithoutTransaction { db in
            var registered: [String] = []
            try db.inTransaction(.immediate) {
                // Read under the lock, so a later writer never stamps an earlier time.
                let now = wallClock.now()
                let time = now.timeIntervalSince1970
                if let serverId {
                    try db.execute(
                        sql: "UPDATE notification_category SET current = 0 WHERE server_id = ?", arguments: [serverId])
                }
                for (row, actions) in encoded {
                    // used_at and pushed_at never move back (another process's clock, a clock change).
                    switch role {
                    case .current:
                        try db.execute(
                            sql: """
                                INSERT INTO notification_category
                                  (id, server_id, topic_id, actions_json, created_at, current, due_at, used_at)
                                VALUES (?, ?, ?, ?, ?, 1, ?, ?)
                                ON CONFLICT (id) DO UPDATE SET
                                  current = 1, due_at = excluded.due_at, used_at = MAX(used_at, excluded.used_at)
                                """,
                            arguments: [
                                row.category.id, row.serverId, row.topicId, actions, time,
                                row.dueAt?.timeIntervalSince1970, time,
                            ])
                    case .pushed:
                        // Push order is a registry counter, not a clock: a later push always ranks
                        // first, whatever the clocks say.
                        let sequence =
                            try Int64.fetchOne(
                                db, sql: "SELECT COALESCE(MAX(push_seq), 0) + 1 FROM notification_category")
                            ?? 1
                        try db.execute(
                            sql: """
                                INSERT INTO notification_category
                                  (id, server_id, topic_id, actions_json, created_at, used_at, pushed_at, push_seq)
                                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                                ON CONFLICT (id) DO UPDATE SET
                                  used_at = MAX(used_at, excluded.used_at),
                                  pushed_at = MAX(COALESCE(pushed_at, 0), excluded.pushed_at),
                                  push_seq = excluded.push_seq
                                """,
                            arguments: [
                                row.category.id, row.serverId, row.topicId, actions, time, time, time, sequence,
                            ])
                    }
                }
                // The push being shown is in this registration, whatever else ranks.
                let required = role == .pushed ? Set(encoded.map(\.0.category.id)) : []
                let after = try Self.select(db, now: now, delivered: delivered, cap: cap, required: required)
                for id in prunes ? after.unneeded : [] {
                    try db.execute(sql: "DELETE FROM notification_category WHERE id = ?", arguments: [id])
                }
                registered = after.selected.map(\.id)
                // Synchronous, under the registry's write lock: no other process registers in between.
                let stale = try installed.map { try Self.generation(db) != $0.generation } ?? true
                if stale || !Set(registered).isSubset(of: installed?.ids ?? []) {
                    center.setNotificationCategories(after.selected)
                    try db.execute(sql: "UPDATE notification_registration SET generation = generation + 1 WHERE id = 1")
                }
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
    /// option counts and last value read from the store's view (queued entries included). Due
    /// state is the server's, at device time `now` on the store's clock (sync-protocol.md §10);
    /// `dueAt` is mapped back to device time, which the ranking compares across stores.
    public static func rows(in store: LocalStore, now: Date) async throws -> [Row] {
        let serverId = store.serverId
        return try await store.writer.read { db in
            let clock =
                try GRDB.Row.fetchOne(db, sql: "SELECT * FROM sync_state WHERE id = 1").map(SyncState.init(row:))?
                .serverClock ?? .device
            let serverNow = clock.now(at: now)
            return try StoreView.topics(db).compactMap { view -> Row? in
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
                let due = topic.schedule?.notify == true ? TopicListing.due(of: topic, at: serverNow) : nil
                let dueAt = due.flatMap { $0.isDue ? $0.dueSince ?? serverNow : $0.nextDueAt }
                return Row(
                    serverId: serverId, topicId: topic.id.wireString, category: category,
                    dueAt: dueAt.map { $0.addingTimeInterval(-clock.skew) })
            }
        }
    }

    /// The capped selection (§5.2) and the rows that can't be needed any more: outside it, not
    /// current, not on screen and not wanted within ``deleteGrace``. A row this build can't read
    /// (an unknown action kind from a newer build) keeps its readable actions.
    static func select(_ db: Database, now: Date, delivered: Set<String>, cap: Int?, required: Set<String> = [])
        throws
        -> (selected: [NotificationCategorySpec], unneeded: [String])
    {
        struct Candidate {
            let id: String
            let json: String
            let current: Bool
            let dueAt: Double?
            let usedAt: Double
            let pushedAt: Double?
            let pushSeq: Int64?
        }
        let candidates = try GRDB.Row.fetchAll(
            db, sql: "SELECT id, actions_json, current, due_at, used_at, pushed_at, push_seq FROM notification_category"
        ).map {
            Candidate(
                id: $0["id"], json: $0["actions_json"], current: $0["current"], dueAt: $0["due_at"],
                usedAt: $0["used_at"], pushedAt: $0["pushed_at"], pushSeq: $0["push_seq"])
        }
        let time = now.timeIntervalSince1970
        // (tier, then the order within it); the id breaks ties, so every process selects the
        // same rows from the same table at the same time.
        func rank(_ c: Candidate) -> (Int, Double) {
            if required.contains(c.id) { return (0, 0) }
            if let pushed = c.pushedAt, pushed >= time - pushWindow { return (1, -Double(c.pushSeq ?? 0)) }
            if c.current, let due = c.dueAt, abs(due - time) <= dueWindow { return (2, abs(due - time)) }
            if delivered.contains(c.id) { return (3, -c.usedAt) }
            return (4, -c.usedAt)
        }
        let ordered = candidates.map { ($0, rank($0)) }.sorted { a, b in
            a.1 != b.1 ? a.1 < b.1 : a.0.id < b.0.id
        }.map(\.0)
        let kept = cap.map { Array(ordered.prefix($0)) } ?? ordered
        let keptIds = Set(kept.map(\.id))
        let graceStart = time - deleteGrace
        let unneeded = ordered.filter {
            !keptIds.contains($0.id) && !$0.current && !delivered.contains($0.id) && $0.usedAt < graceStart
        }
        let selected = kept.map { c in
            NotificationCategorySpec(id: c.id, actions: ((try? decode(c.json)) ?? []).compactMap(\.spec))
        }
        return (selected, unneeded.map(\.id))
    }

    /// The registry's registration generation: moved by every `setNotificationCategories` call.
    static func generation(_ db: Database) throws -> Int64 {
        try Int64.fetchOne(db, sql: "SELECT generation FROM notification_registration WHERE id = 1") ?? 0
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
