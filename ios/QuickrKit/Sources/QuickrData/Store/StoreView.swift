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

    // MARK: - Entries

    /// A topic's view entries, newest `captured_at` first (then id). Includes rows flagged
    /// `failed`, failed creates among them (the UI pins those under "Not synced"); `countedOnly`
    /// leaves failed creates out.
    public static func entries(_ db: Database, topicId: String, limit: Int? = nil, countedOnly: Bool = false) throws
        -> [ViewEntry]
    {
        guard try topicExists(db, topicId) else { return [] }
        let book = QuestionBook(db)
        let questions = { (row: Row) in book.questions(row["topic_id"], row["version"]) }
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
            try Entry(serverRow: row, questions: book.questions(row["topic_id"], row["version"]))
        }
        let overlay = try EntryOverlay.resolve(
            server: server, items: OutboxStorage.items(db, entityKind: .entry, entityId: id), questions: book.lookup)
        guard let viewEntry = overlay.viewEntry, try topicExists(db, viewEntry.entry.topicId.wireString) else {
            return nil
        }
        return viewEntry
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
                    try Entry(serverRow: row, questions: book.questions(row["topic_id"], row["version"]))
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
/// version's own questions, else the topic's current ones, else none.
final class QuestionBook {
    private let db: Database
    private var cache: [String: [Question]] = [:]

    init(_ db: Database) { self.db = db }

    var lookup: QuestionLookup { { [self] topicId, version in questions(topicId.wireString, version) } }

    func questions(_ topicId: String, _ version: Int) -> [Question] {
        let key = "\(topicId)#\(version)"
        if let cached = cache[key] { return cached }
        let json =
            (try? String.fetchOne(
                db, sql: "SELECT questions_json FROM topic_version WHERE topic_id = ? AND version = ?",
                arguments: [topicId, version]))
            ?? (try? String.fetchOne(db, sql: "SELECT questions_json FROM topic WHERE id = ?", arguments: [topicId]))
        let questions = json.flatMap { try? StoreJSON.decode([QuestionDTO].self, $0).toDomain() } ?? []
        cache[key] = questions
        return questions
    }
}
