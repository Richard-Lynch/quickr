import Foundation
import GRDB
import QuickrCore

/// The view (sync-protocol.md §3.2–§3.3): the server layer with the outbox overlay applied and the
/// derived fields recomputed, computed on read inside the caller's read transaction, so it is
/// always consistent with its inputs. Server rows with no outbox items are final as stored and are
/// read and counted in SQL; only the few entities with items go through `EntryOverlay`. Entries
/// are inner-joined to the server `topic` table: an entry (or a queued create) stays invisible
/// until its topic arrives.
public enum StoreView {
    /// The recomputed derived fields of one topic (§3.3). `due` is DUE's.
    public struct Derived: Sendable, Hashable {
        public var entryCount: Int
        public var lastCapturedAt: Date?

        public init(entryCount: Int = 0, lastCapturedAt: Date? = nil) {
            self.entryCount = entryCount
            self.lastCapturedAt = lastCapturedAt
        }

        mutating func count(_ capturedAt: Date) {
            entryCount += 1
            lastCapturedAt = max(lastCapturedAt ?? capturedAt, capturedAt)
        }
    }

    private static let entriesWithItems = "SELECT entity_id FROM outbox_item WHERE entity_kind = 'entry'"

    // MARK: - Topics

    /// Every view topic, archived included, by lowercased name then id (the server's `name` sort).
    public static func topics(_ db: Database) throws -> [ViewTopic] {
        try viewTopics(db, rows: Row.fetchAll(db, sql: "SELECT * FROM topic ORDER BY lower(name), id"))
    }

    public static func topic(_ db: Database, id: String) throws -> ViewTopic? {
        try viewTopics(db, rows: Row.fetchAll(db, sql: "SELECT * FROM topic WHERE id = ?", arguments: [id])).first
    }

    public static func topic(_ db: Database, slug: String) throws -> ViewTopic? {
        try viewTopics(db, rows: Row.fetchAll(db, sql: "SELECT * FROM topic WHERE slug = ?", arguments: [slug])).first
    }

    private static func viewTopics(_ db: Database, rows: [Row]) throws -> [ViewTopic] {
        guard !rows.isEmpty else { return [] }
        let ids: [String] = rows.map { $0["id"] }
        let topicId = ids.count == 1 ? ids[0] : nil
        let derived = try self.derived(db, topicId: topicId)
        let items = Dictionary(
            grouping: try OutboxStorage.items(db, entityKind: .topic, entityIds: ids), by: \.entityId)
        return try rows.map { row in
            var topic = try Topic(serverRow: row)
            let id = topic.id.wireString
            let counts = derived[id] ?? Derived()
            topic.entryCount = counts.entryCount
            topic.lastCapturedAt = counts.lastCapturedAt
            return TopicOverlay.resolve(server: topic, items: items[id] ?? [])
        }
    }

    // MARK: - Derived fields (§3.3, §6a rule 3)

    /// `entry_count` and `last_captured_at` per topic id from the counted view entries: hidden
    /// rows and entities whose create failed are excluded. All topics when `topicId` is nil.
    public static func derived(_ db: Database, topicId: String? = nil) throws -> [String: Derived] {
        var result: [String: Derived] = [:]
        let filter = topicId == nil ? "" : "AND topic_id = ?"
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT topic_id, COUNT(*) AS n, MAX(captured_at) AS last FROM entry
                WHERE id NOT IN (\(entriesWithItems)) \(filter)
                GROUP BY topic_id
                """,
            arguments: StatementArguments(topicId.map { [$0] } ?? []))
        for row in rows {
            result[row["topic_id"]] = Derived(
                entryCount: row["n"], lastCapturedAt: (row["last"] as Double?).map(Date.init(unixSeconds:)))
        }
        for overlay in try overlays(db, topicId: topicId) where overlay.isCounted {
            guard let entry = overlay.entry else { continue }
            result[entry.topicId.wireString, default: Derived()].count(entry.capturedAt)
        }
        return result
    }

    // MARK: - Bounded reads (the NSE has 24 MB)

    /// Every view topic like ``topics(_:)``, with what due states need, read in bounded memory:
    /// `last_captured_at` from ``lastCapturedAt(_:)``, and `status` / `archived_at` from each
    /// topic's latest queued archive or unarchive (``queuedTopicStates(_:)``, one row per topic).
    /// Not computed: `entry_count` (0) and the sync state (`.synced`).
    public static func dueTopics(_ db: Database) throws -> [ViewTopic] {
        let last = try lastCapturedAt(db)
        let states = try queuedTopicStates(db)
        return try Row.fetchAll(db, sql: "SELECT * FROM topic ORDER BY lower(name), id").map { row in
            var topic = try Topic(serverRow: row)
            let id = topic.id.wireString
            topic.entryCount = 0
            topic.lastCapturedAt = last[id]
            if let state = states[id] {
                topic.status = state.kind == .topicArchive ? .archived : .active
                topic.archivedAt = state.kind == .topicArchive ? state.at : nil
            }
            return ViewTopic(topic: topic)
        }
    }

    /// Per topic id, the latest topic item that isn't failed (what `TopicOverlay` ends on): its
    /// kind and `created_at`. One row per topic, whatever the queue's length.
    static func queuedTopicStates(_ db: Database) throws -> [String: (kind: OutboxKind, at: Date)] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT o.entity_id, o.kind, o.created_at FROM outbox_item AS o
                JOIN (
                  SELECT MAX(seq) AS seq FROM outbox_item
                  WHERE entity_kind = 'topic' AND state != 'failed' AND kind IN ('topic.archive', 'topic.unarchive')
                  GROUP BY entity_id
                ) AS latest ON o.seq = latest.seq
                """)
        var states: [String: (kind: OutboxKind, at: Date)] = [:]
        for row in rows {
            guard let kind = OutboxKind(rawValue: row["kind"]) else { continue }
            states[row["entity_id"]] = (kind, Date(unixSeconds: row["created_at"]))
        }
        return states
    }

    /// `last_captured_at` per topic id, as ``derived(_:topicId:)`` computes it, but never holding more
    /// than one queued entity at a time (``streamOverlays(_:topicId:onEntity:_:)``).
    public static func lastCapturedAt(_ db: Database) throws -> [String: Date] {
        var result: [String: Date] = [:]
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT topic_id, MAX(captured_at) AS last FROM entry
                WHERE id NOT IN (\(entriesWithItems)) GROUP BY topic_id
                """)
        for row in rows {
            if let last = row["last"] as Double? { result[row["topic_id"]] = Date(unixSeconds: last) }
        }
        try streamOverlays(db) { overlay in
            if overlay.isCounted, let entry = overlay.entry {
                let id = entry.topicId.wireString
                result[id] = max(result[id] ?? entry.capturedAt, entry.capturedAt)
            }
            return true
        }
        return result
    }

    /// Whether `topicId` has a counted entry only this device has so far (queued, not failed)
    /// captured at or after `since`: every such entity is checked, however many entries are newer.
    public static func hasPendingEntry(_ db: Database, topicId: String, capturedSince since: Date) throws -> Bool {
        var found = false
        try streamOverlays(db, topicId: topicId) { overlay in
            guard overlay.isCounted, overlay.syncState == .pending, let entry = overlay.entry,
                entry.capturedAt >= since
            else { return true }
            found = true
            return false
        }
        return found
    }

    /// Each entry entity with outbox items (of `topicId`, or all), resolved like
    /// ``overlays(_:topicId:book:)`` but streamed: items come through a cursor ordered by entity
    /// and `seq` and are folded into the entity's overlay one by one (`EntryOverlay.Builder`), so
    /// no item is kept after it is applied, however long the queue or one entity's backlog.
    /// Tombstoned entities and ones whose topic isn't here are skipped. `body` returns false to
    /// stop. The question sets the answers are typed against are cached for the last few versions
    /// only (``overlayQuestionSets``). `onEntity` sees each entity's item count and the cache's
    /// size (tests).
    static func streamOverlays(
        _ db: Database, topicId: String? = nil, onEntity: (_ items: Int, _ questionSets: Int) -> Void = { _, _ in },
        _ body: (EntryOverlay) throws -> Bool
    ) throws {
        let book = QuestionBook(db, capacity: overlayQuestionSets)
        var entity: String?
        var builder: EntryOverlay.Builder?
        var items = 0
        func finish() throws -> Bool {
            guard entity != nil else { return true }
            defer {
                onEntity(items, book.cachedCount)
                items = 0
            }
            guard let overlay = builder?.overlay, let entry = overlay.entry,
                try topicExists(db, entry.topicId.wireString)
            else { return true }
            return try body(overlay)
        }
        let filter = topicId == nil ? "" : "AND topic_id = ?"
        let cursor = try Row.fetchCursor(
            db,
            sql: "SELECT * FROM outbox_item WHERE entity_kind = 'entry' \(filter) ORDER BY entity_id, seq",
            arguments: StatementArguments(topicId.map { [$0] } ?? []))
        while let row = try cursor.next() {
            let item = try OutboxItem(row: row)
            if item.entityId != entity {
                guard try finish() else { return }
                entity = item.entityId
                // A tombstoned entity is skipped (nil builder); otherwise start from its server row.
                if try ServerLayer.isTombstoned(db, kind: .entry, id: item.entityId) {
                    builder = nil
                } else {
                    let server = try Row.fetchOne(
                        db, sql: "SELECT * FROM entry WHERE id = ?", arguments: [item.entityId]
                    ).map { row in
                        try Entry(serverRow: row, questions: try book.questions(row["topic_id"], row["version"]))
                    }
                    builder = EntryOverlay.Builder(server: server, questions: book.lookup)
                }
            }
            items += 1
            try builder?.apply(item)
        }
        _ = try finish()
    }

    /// How many (topic, version) question sets a stream keeps decoded.
    static let overlayQuestionSets = 8

    // MARK: - Entries

    /// A topic's view entries, newest `captured_at` first (then id). Includes rows flagged
    /// `failed`, failed creates among them (the UI pins those under "Not synced"); `countedOnly`
    /// leaves failed creates out.
    public static func entries(_ db: Database, topicId: String, limit: Int? = nil, countedOnly: Bool = false) throws
        -> [ViewEntry]
    {
        guard try topicExists(db, topicId) else { return [] }
        let book = QuestionBook(db)
        let questions = { (row: Row) in try book.questions(row["topic_id"], row["version"]) }
        let overlaid = try overlays(db, topicId: topicId, book: book)
            .filter { countedOnly ? $0.isCounted : $0.isVisible }
            .compactMap(\.viewEntry)
        let server = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM entry WHERE topic_id = ? AND id NOT IN (\(entriesWithItems))
                ORDER BY captured_at DESC, id DESC \(limit == nil ? "" : "LIMIT ?")
                """,
            arguments: StatementArguments([topicId] + (limit.map { [$0] } ?? []))
        ).map { row in ViewEntry(entry: try Entry(serverRow: row, questions: questions(row)), syncState: .synced) }
        let merged = (server + overlaid).sorted {
            ($0.entry.capturedAt, $0.id.wireString) > ($1.entry.capturedAt, $1.id.wireString)
        }
        return limit.map { Array(merged.prefix($0)) } ?? merged
    }

    public static func entry(_ db: Database, id: String) throws -> ViewEntry? {
        if try ServerLayer.isTombstoned(db, kind: .entry, id: id) { return nil }
        let book = QuestionBook(db)
        let server = try Row.fetchOne(db, sql: "SELECT * FROM entry WHERE id = ?", arguments: [id]).map { row in
            try Entry(serverRow: row, questions: try book.questions(row["topic_id"], row["version"]))
        }
        let overlay = try EntryOverlay.resolve(
            server: server, items: OutboxStorage.items(db, entityKind: .entry, entityId: id), questions: book.lookup)
        guard let viewEntry = overlay.viewEntry, try topicExists(db, viewEntry.entry.topicId.wireString) else {
            return nil
        }
        return viewEntry
    }

    /// The entry as it stood before outbox item `seq`: the server row with only the earlier items
    /// applied (a refused edit's fix starts from it, so later queued edits don't leak into the form).
    /// Nil when there's nothing to show.
    public static func entry(_ db: Database, id: String, before seq: Int64) throws -> Entry? {
        let book = QuestionBook(db)
        let server = try Row.fetchOne(db, sql: "SELECT * FROM entry WHERE id = ?", arguments: [id]).map { row in
            try Entry(serverRow: row, questions: try book.questions(row["topic_id"], row["version"]))
        }
        let items = try OutboxStorage.items(db, entityKind: .entry, entityId: id).filter { $0.seq < seq }
        return try EntryOverlay.resolve(server: server, items: items, questions: book.lookup).entry
    }

    /// The latest counted entry of a topic (repeat-last, quick-log `last_value`).
    public static func latestEntry(_ db: Database, topicId: String) throws -> ViewEntry? {
        try entries(db, topicId: topicId, limit: 1, countedOnly: true).first
    }

    // MARK: - Versions

    /// A topic's versions, oldest first, with `entry_count` recomputed from counted view entries.
    public static func versions(_ db: Database, topicId: String) throws -> [TopicVersion] {
        let rows = try Row.fetchAll(
            db, sql: "SELECT * FROM topic_version WHERE topic_id = ? ORDER BY version", arguments: [topicId])
        guard !rows.isEmpty else { return [] }
        var counts = Dictionary(
            uniqueKeysWithValues: try Row.fetchAll(
                db,
                sql: """
                    SELECT version, COUNT(*) AS n FROM entry
                    WHERE topic_id = ? AND id NOT IN (\(entriesWithItems)) GROUP BY version
                    """,
                arguments: [topicId]
            ).map { (row: Row) -> (Int, Int) in (row["version"], row["n"]) })
        for overlay in try overlays(db, topicId: topicId) where overlay.isCounted {
            if let entry = overlay.entry { counts[entry.version, default: 0] += 1 }
        }
        return try rows.map { row in
            var version = try TopicVersion(serverRow: row)
            version.entryCount = counts[version.version] ?? 0
            return version
        }
    }

    public static func version(_ db: Database, topicId: String, number: Int) throws -> TopicVersion? {
        try versions(db, topicId: topicId).first { $0.version == number }
    }

    // MARK: - Runs (timers.md §7.2)

    /// The server layer's runs of a topic (or all), open or finishing, oldest start first. Like
    /// entries, a run is hidden until its topic arrives. Queued `run.event` items are not folded in
    /// here: that is the local view of a run (timers.md §8.3).
    public static func runs(_ db: Database, topicId: String? = nil) throws -> [Run] {
        let filter = topicId == nil ? "" : "WHERE r.topic_id = ?"
        return try Row.fetchAll(
            db,
            sql: """
                SELECT r.* FROM run AS r JOIN topic AS t ON t.id = r.topic_id \(filter)
                ORDER BY r.started_at, r.id
                """,
            arguments: StatementArguments(topicId.map { [$0] } ?? [])
        ).map(Run.init(serverRow:))
    }

    /// The stored run with this id, or the one it was merged into (an alias, timers.md §4.5); nil
    /// when neither is stored or its topic isn't here.
    public static func run(_ db: Database, id: String) throws -> Run? {
        try Row.fetchOne(
            db,
            sql: """
                SELECT r.* FROM run AS r JOIN topic AS t ON t.id = r.topic_id
                WHERE r.id = ? OR r.id = (SELECT run_id FROM run_alias WHERE id = ?)
                """,
            arguments: [id, id]
        ).map(Run.init(serverRow:))
    }

    // MARK: - Overlay inputs

    /// The resolved overlays of every entry entity with outbox items (in one topic, or all),
    /// tombstoned ids and entities whose topic isn't in the server layer removed.
    static func overlays(_ db: Database, topicId: String?, book: QuestionBook? = nil) throws -> [EntryOverlay] {
        let book = book ?? QuestionBook(db)
        let items = try topicId.map { try OutboxStorage.items(db, topicId: $0) } ?? OutboxStorage.items(db)
        let byEntity = Dictionary(grouping: items.filter { $0.entityKind == .entry }, by: \.entityId)
        guard !byEntity.isEmpty else { return [] }
        let ids = Array(byEntity.keys)
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let servers = Dictionary(
            uniqueKeysWithValues: try Row.fetchAll(
                db, sql: "SELECT * FROM entry WHERE id IN (\(marks))", arguments: StatementArguments(ids)
            ).map { row in
                (
                    row["id"] as String,
                    try Entry(serverRow: row, questions: try book.questions(row["topic_id"], row["version"]))
                )
            })
        let tombstoned = Set(
            try String.fetchAll(
                db, sql: "SELECT id FROM tombstone WHERE kind = 'entry' AND id IN (\(marks))",
                arguments: StatementArguments(ids)))
        let topics = Set(try String.fetchAll(db, sql: "SELECT id FROM topic"))
        return try byEntity.compactMap { id, items in
            guard !tombstoned.contains(id) else { return nil }
            let overlay = try EntryOverlay.resolve(server: servers[id], items: items, questions: book.lookup)
            guard let entry = overlay.entry, topics.contains(entry.topicId.wireString) else { return nil }
            return overlay
        }
    }

    private static func topicExists(_ db: Database, _ id: String) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM topic WHERE id = ?)", arguments: [id]) ?? false
    }
}

/// The questions of each `(topic, version)`, read lazily within one read transaction: the
/// version's own questions, else the topic's current ones, else none (an orphan row). SQL and
/// decoding errors propagate.
final class QuestionBook {
    private let db: Database
    private var cache: [String: [Question]] = [:]
    /// Keys by last use, oldest first; only kept when `capacity` bounds the cache.
    private var recent: [String] = []
    /// At most this many question sets are kept (least recently used go first); nil keeps all.
    private let capacity: Int?

    init(_ db: Database, capacity: Int? = nil) {
        self.db = db
        self.capacity = capacity
    }

    /// The question sets held now.
    var cachedCount: Int { cache.count }

    var lookup: QuestionLookup { { [self] topicId, version in try questions(topicId.wireString, version) } }

    func questions(_ topicId: String, _ version: Int) throws -> [Question] {
        let key = "\(topicId)#\(version)"
        if let cached = cache[key] {
            if capacity != nil {
                recent.removeAll { $0 == key }
                recent.append(key)
            }
            return cached
        }
        let json =
            try String.fetchOne(
                db, sql: "SELECT questions_json FROM topic_version WHERE topic_id = ? AND version = ?",
                arguments: [topicId, version])
            ?? String.fetchOne(db, sql: "SELECT questions_json FROM topic WHERE id = ?", arguments: [topicId])
        let questions = try json.map { try StoreJSON.decode([QuestionDTO].self, $0).toDomain() } ?? []
        cache[key] = questions
        if let capacity {
            recent.append(key)
            while recent.count > capacity { cache[recent.removeFirst()] = nil }
        }
        return questions
    }
}
