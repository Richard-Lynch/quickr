import Foundation
import GRDB
import QuickrCore

/// Category registration (notifications.md §5): the registry's append-only `notification_category`
/// table, and the system's category set kept equal to the whole table.
///
/// - ``register(_:)`` (§5.2): one `IMMEDIATE` registry transaction inserts the new rows, reads the
///   full union and hands it to `setNotificationCategories` (synchronous). The registry's write
///   lock is the cross-process mutex, so no process ever registers a set that misses another's.
/// - ``reconcile()`` (§5.3): on activation (and at the start of an NSE run) re-registers the union
///   when the system lost any of it. The center is asked outside any transaction.
/// - ``refresh(from:now:)``: the app's call after a sync, a server switch, a reset or launch: the
///   category of every quick-loggable active topic in the store, computed with the server's rules.
///   The NSE may never run (spike F1), so these must be registered ahead of any push.
public struct NotificationCategories: Sendable {
    public let registry: Registry
    public let center: any NotificationCenterProtocol
    let wallClock: any WallClock

    public init(registry: Registry, center: any NotificationCenterProtocol, wallClock: any WallClock = SystemWallClock()) {
        self.registry = registry
        self.center = center
        self.wallClock = wallClock
    }

    /// A row to insert: the category of one topic for one server.
    public struct Row: Sendable, Hashable {
        public var serverId: String
        public var topicId: String
        public var category: NotificationCategory

        public init(serverId: String, topicId: String, category: NotificationCategory) {
            self.serverId = serverId
            self.topicId = topicId
            self.category = category
        }
    }

    /// §5.2: inserts `rows` (existing ids are kept as they are) and registers the whole table.
    /// Returns the registered category ids.
    @discardableResult
    public func register(_ rows: [Row]) async throws -> [String] {
        let now = wallClock.now().timeIntervalSince1970
        let center = center
        let encoded = try rows.map { row in (row, try Self.encode(row.category.actions)) }
        return try await registry.writer.writeWithoutTransaction { db in
            var registered: [NotificationCategorySpec] = []
            try db.inTransaction(.immediate) {
                for (row, actions) in encoded {
                    try db.execute(
                        sql: """
                            INSERT OR IGNORE INTO notification_category (id, server_id, topic_id, actions_json, created_at)
                            VALUES (?, ?, ?, ?, ?)
                            """,
                        arguments: [row.category.id, row.serverId, row.topicId, actions, now])
                }
                registered = try Self.union(db)
                // Synchronous, under the registry's write lock: no other process registers in between.
                center.setNotificationCategories(registered)
                return .commit
            }
            return registered.map(\.id)
        }
    }

    /// §5.3: re-registers the union when the system is missing any category of the table. Returns
    /// whether it did. Asks the center before the (short) read, never inside a transaction.
    @discardableResult
    public func reconcile() async throws -> Bool {
        let registered = Set(await center.notificationCategories().map(\.id))
        let ids = try await registry.writer.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM notification_category")
        }
        guard !Set(ids).isSubset(of: registered) else { return false }
        try await register([])
        return true
    }

    /// The categories of every quick-loggable active topic in `store`, registered when any of them
    /// is new to the table. Returns the topics' category ids.
    @discardableResult
    public func refresh(from store: LocalStore) async throws -> [String] {
        let rows = try await Self.rows(in: store)
        let ids = rows.map(\.category.id)
        let known = try await registry.writer.read { db in
            try Set(String.fetchAll(db, sql: "SELECT id FROM notification_category"))
        }
        let new = rows.filter { !known.contains($0.category.id) }
        if !new.isEmpty { try await register(new) }
        return ids
    }

    /// One row per quick-loggable active topic of the store (its current version), with the
    /// option counts and last value read from the store's view (queued entries included).
    static func rows(in store: LocalStore) async throws -> [Row] {
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
                return Row(serverId: serverId, topicId: topic.id.wireString, category: category)
            }
        }
    }

    /// Every row of the table, as the system registers them. A row this build can't read (an
    /// unknown action kind from a newer build) keeps its readable actions.
    static func union(_ db: Database) throws -> [NotificationCategorySpec] {
        try GRDB.Row.fetchAll(db, sql: "SELECT id, actions_json FROM notification_category ORDER BY created_at, id").map {
            row in
            let actions = (try? decode(row["actions_json"])) ?? []
            return NotificationCategorySpec(id: row["id"], actions: actions.compactMap(\.spec))
        }
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
