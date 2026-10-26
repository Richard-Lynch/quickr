import Foundation
import GRDB
import QuickrCore

/// Writes into the server layer (`topic`, `topic_version`, `entry`, `run`, `run_alias`,
/// `tombstone`) or its staging copy, under the §4.2 upsert guards (sync-protocol.md §4.2–§4.3).
/// These run inside a transaction the caller holds and has already **fenced** (§5.5); they never
/// check leases themselves.
public enum ServerLayer {
    /// The live layer or the rebuild's staging copy (§7).
    public enum Layer: String, Sendable, Hashable {
        case live = ""
        case stage = "stage_"

        func table(_ name: String) -> String { rawValue + name }
    }

    public enum UpsertOutcome: Sendable, Hashable {
        case applied
        /// Dropped: the id (or its topic) is tombstoned. Ids are never reused (F3).
        case tombstoned
        /// Dropped: the stored row has a higher revision.
        case stale
        /// Dropped: a version with that id or `(topic_id, version)` already exists (versions are
        /// immutable).
        case exists
    }

    // MARK: - Upserts

    public static func upsert(_ db: Database, topic: Topic, into layer: Layer = .live) throws -> UpsertOutcome {
        let id = topic.id.wireString
        if try isTombstoned(db, kind: .topic, id: id, layer: layer) { return .tombstoned }
        if let stored = try revision(db, table: layer.table("topic"), id: id), stored > topic.revision { return .stale }
        try db.execute(
            sql: """
                INSERT OR REPLACE INTO \(layer.table("topic"))
                  (id, slug, name, description, status, current_version, revision, question_count, created_at,
                   updated_at, archived_at, schedule_json, schedule_updated_at, questions_json)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                id, topic.slug, topic.name, topic.description, topic.status.rawValue, topic.currentVersion,
                topic.revision, topic.questionCount, topic.createdAt.unixSeconds, topic.updatedAt.unixSeconds,
                topic.archivedAt?.unixSeconds, try topic.schedule.map { try StoreJSON.encode(ScheduleDTO($0)) },
                topic.scheduleUpdatedAt?.unixSeconds, try StoreJSON.encode(topic.questions.map(QuestionDTO.init)),
            ])
        return .applied
    }

    public static func upsert(_ db: Database, entry: Entry, into layer: Layer = .live) throws -> UpsertOutcome {
        let id = entry.id.wireString
        if try isTombstoned(db, kind: .entry, id: id, layer: layer)
            || isTombstoned(db, kind: .topic, id: entry.topicId.wireString, layer: layer)
        {
            return .tombstoned
        }
        if let stored = try revision(db, table: layer.table("entry"), id: id), stored > entry.revision { return .stale }
        // `timing_json` (store v3) is written only for a timed entry; null is its default, so an
        // untimed one is the same row a v1 file holds.
        var values: [String: (any DatabaseValueConvertible)?] = [
            "id": id, "topic_id": entry.topicId.wireString, "version": entry.version, "revision": entry.revision,
            "source": entry.source, "channel": entry.channel.rawValue, "captured_at": entry.capturedAt.unixSeconds,
            "created_at": entry.createdAt.unixSeconds, "updated_at": entry.updatedAt.unixSeconds,
            "notes": entry.notes, "meta_json": try StoreJSON.encode(entry.meta),
            "answers_json": try StoreJSON.encode(entry.answers.mapValues(WireAnswer.init)),
        ]
        if let timing = entry.timing { values["timing_json"] = try StoreJSON.encode(TimingDTO(timing)) }
        try insert(db, values, into: layer.table("entry"), or: "REPLACE")
        return .applied
    }

    /// An open or finishing run (timers.md §7.2), under the same guards as an entry. Its alias rows
    /// are replaced by its `aliases`.
    public static func upsert(_ db: Database, run: Run, into layer: Layer = .live) throws -> UpsertOutcome {
        let id = run.id.wireString
        let topicId = run.topicId.wireString
        if try isTombstoned(db, kind: .run, id: id, layer: layer)
            || isTombstoned(db, kind: .topic, id: topicId, layer: layer)
        {
            return .tombstoned
        }
        if let stored = try revision(db, table: layer.table("run"), id: id), stored > run.revision { return .stale }
        try db.execute(
            sql: """
                INSERT OR REPLACE INTO \(layer.table("run")) (id, topic_id, status, revision, started_at, run_json)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                id, topicId, run.status.rawValue, run.revision, run.startedAt, try StoreJSON.encode(RunDTO(run)),
            ])
        try db.execute(sql: "DELETE FROM \(layer.table("run_alias")) WHERE run_id = ?", arguments: [id])
        for alias in run.aliases {
            try db.execute(
                sql: "INSERT OR REPLACE INTO \(layer.table("run_alias")) (id, run_id, topic_id) VALUES (?, ?, ?)",
                arguments: [alias.wireString, id, topicId])
        }
        return .applied
    }

    /// A `RunEventResult` (timers.md §8.1 "Ack"), in the live layer: the entry, when present, and
    /// the run under the guards. `sentTo` differs from the run's id after a merge (§4.5): it is
    /// recorded as an alias, so the local view re-keys this device's queued events to the run. A
    /// closed run (stopped or discarded) is applied as the run deletion the feed would bring, so
    /// the device never shows it open again. Returns the run's upsert outcome (nil for a deletion).
    @discardableResult
    public static func apply(_ db: Database, runEvent result: RunEventResult, sentTo: UUID) throws -> UpsertOutcome? {
        let run = result.run
        if let entry = result.entry { _ = try upsert(db, entry: entry) }
        let closed = run.status == .stopped || run.status == .discarded
        // The open run first: its upsert replaces the run's alias rows with its `aliases`.
        let outcome = closed ? nil : try upsert(db, run: run)
        let topicId = run.topicId.wireString
        let alias = sentTo.wireString
        if sentTo != run.id, try !isTombstoned(db, kind: .run, id: alias),
            try !isTombstoned(db, kind: .topic, id: topicId)
        {
            try db.execute(
                sql: "INSERT OR REPLACE INTO run_alias (id, run_id, topic_id) VALUES (?, ?, ?)",
                arguments: [alias, run.id.wireString, topicId])
        }
        guard closed else { return outcome }
        // Tombstones the run and its aliases, `sentTo` included.
        try applyDeletion(db, kind: .run, id: run.id, topicId: run.topicId, seq: nil)
        return nil
    }

    /// Versions are immutable: insert if absent, otherwise ignore.
    public static func insert(
        _ db: Database, version: TopicVersion, id: UUID, topicId: UUID, into layer: Layer = .live
    ) throws -> UpsertOutcome {
        if try isTombstoned(db, kind: .version, id: id.wireString, layer: layer)
            || isTombstoned(db, kind: .topic, id: topicId.wireString, layer: layer)
        {
            return .tombstoned
        }
        // `timer_json` (store v2) is written only for a timed version; null is its default, so an
        // untimed one is the same row a v1 file holds.
        var values: [String: (any DatabaseValueConvertible)?] = [
            "id": id.wireString, "topic_id": topicId.wireString, "version": version.version,
            "questions_json": try StoreJSON.encode(version.questions.map(QuestionDTO.init)),
            "change_note": version.changeNote, "created_at": version.createdAt.unixSeconds,
        ]
        if let timer = version.timer { values["timer_json"] = try StoreJSON.encode(timer) }
        try insert(db, values, into: layer.table("topic_version"), or: "IGNORE")
        return db.changesCount > 0 ? .applied : .exists
    }

    /// `INSERT OR <conflict>` of the given columns only.
    private static func insert(
        _ db: Database, _ values: [String: (any DatabaseValueConvertible)?], into table: String, or conflict: String
    ) throws {
        let columns = values.keys.sorted()
        try db.execute(
            sql: """
                INSERT OR \(conflict) INTO \(table) (\(columns.joined(separator: ", ")))
                VALUES (\(columns.map { _ in "?" }.joined(separator: ", ")))
                """,
            arguments: StatementArguments(columns.map { values[$0] ?? nil }))
    }

    // MARK: - Tombstones (§4.3 steps 1, 2 and 4)

    /// Inserts the tombstone (idempotent) and deletes the row. A run's deletion also removes its
    /// alias rows and tombstones their ids as kind `run`; its id may be an alias's (a topic's
    /// deletion lists them), which goes too. A
    /// topic tombstone also removes the topic's versions, entries, runs and aliases and tombstones
    /// them, runs and aliases as kind `run` (the local cascade incremental pages rely on, F3;
    /// timers.md §7.2); in the live layer it also clears the topic's `ui_draft`, `stats_cache` and
    /// `widget_state` rows. Dependent outbox items (step 3) are SYNC's.
    public static func applyDeletion(
        _ db: Database, kind: Deletion.EntityKind, id: UUID, topicId: UUID, seq: Int?, into layer: Layer = .live
    ) throws {
        let id = id.wireString
        let topicId = topicId.wireString
        try insertTombstone(db, kind: kind, id: id, topicId: topicId, seq: seq, layer: layer)
        switch kind {
        case .entry:
            try db.execute(sql: "DELETE FROM \(layer.table("entry")) WHERE id = ?", arguments: [id])
        case .version:
            try db.execute(sql: "DELETE FROM \(layer.table("topic_version")) WHERE id = ?", arguments: [id])
        case .run:
            try db.execute(sql: "DELETE FROM \(layer.table("run")) WHERE id = ?", arguments: [id])
            // The aliases close with the run: tombstoned too, so nothing recreates one as a run.
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO \(layer.table("tombstone")) (kind, id, topic_id, seq)
                    SELECT 'run', id, topic_id, ? FROM \(layer.table("run_alias")) WHERE run_id = ?
                    """,
                arguments: [seq, id])
            try db.execute(
                sql: "DELETE FROM \(layer.table("run_alias")) WHERE run_id = ? OR id = ?", arguments: [id, id])
        case .topic:
            let children: [(Deletion.EntityKind, String)] = [
                (.entry, "entry"), (.version, "topic_version"), (.run, "run"), (.run, "run_alias"),
            ]
            for (child, table) in children {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO \(layer.table("tombstone")) (kind, id, topic_id, seq)
                        SELECT ?, id, topic_id, ? FROM \(layer.table(table)) WHERE topic_id = ?
                        """,
                    arguments: [child.rawValue, seq, id])
                try db.execute(sql: "DELETE FROM \(layer.table(table)) WHERE topic_id = ?", arguments: [id])
            }
            try db.execute(sql: "DELETE FROM \(layer.table("topic")) WHERE id = ?", arguments: [id])
            if layer == .live {
                for table in ["ui_draft", "stats_cache", "widget_state"] {
                    try db.execute(sql: "DELETE FROM \(table) WHERE topic_id = ?", arguments: [id])
                }
            }
        }
    }

    public static func isTombstoned(_ db: Database, kind: Deletion.EntityKind, id: String, layer: Layer = .live)
        throws -> Bool
    {
        try Bool.fetchOne(
            db, sql: "SELECT EXISTS (SELECT 1 FROM \(layer.table("tombstone")) WHERE kind = ? AND id = ?)",
            arguments: [kind.rawValue, id]) ?? false
    }

    /// The live server-layer revision of an entity, nil if there's no row.
    public static func revision(_ db: Database, entityKind: OutboxEntityKind, id: String) throws -> Int? {
        try revision(db, table: entityKind.rawValue, id: id)
    }

    private static func revision(_ db: Database, table: String, id: String) throws -> Int? {
        try Int.fetchOne(db, sql: "SELECT revision FROM \(table) WHERE id = ?", arguments: [id])
    }

    private static func insertTombstone(
        _ db: Database, kind: Deletion.EntityKind, id: String, topicId: String, seq: Int?, layer: Layer
    ) throws {
        try db.execute(
            sql: "INSERT OR IGNORE INTO \(layer.table("tombstone")) (kind, id, topic_id, seq) VALUES (?, ?, ?, ?)",
            arguments: [kind.rawValue, id, topicId, seq])
    }
}

// MARK: - Row codecs

enum StoreJSON {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try WireCoding.encoder().encode(value), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try WireCoding.decoder().decode(type, from: Data(json.utf8))
    }
}

extension Date {
    var unixSeconds: Double { timeIntervalSince1970 }

    init(unixSeconds: Double) { self.init(timeIntervalSince1970: unixSeconds) }
}

extension Topic {
    /// A `topic` row; derived fields are left empty for the view to fill. `timer` comes from the
    /// row's `timer_json`, the current version's (`StoreView.topicRows`).
    init(serverRow row: Row) throws {
        let id: String = row["id"]
        let scheduleJSON: String? = row["schedule_json"]
        let status: String = row["status"]
        guard let status = TopicStatus(rawValue: status) else { throw StoreError.corruptRow("topic \(id) status") }
        self.init(
            id: try .wire(id, "topic.id"), slug: row["slug"], name: row["name"], description: row["description"],
            status: status, currentVersion: row["current_version"], revision: row["revision"],
            questionCount: row["question_count"], createdAt: Date(unixSeconds: row["created_at"]),
            updatedAt: Date(unixSeconds: row["updated_at"]),
            archivedAt: (row["archived_at"] as Double?).map(Date.init(unixSeconds:)),
            schedule: try scheduleJSON.map { try StoreJSON.decode(ScheduleDTO.self, $0).toDomain() },
            scheduleUpdatedAt: (row["schedule_updated_at"] as Double?).map(Date.init(unixSeconds:)),
            timer: try (row["timer_json"] as String?).map { try StoreJSON.decode(TopicTimer.self, $0) },
            questions: try StoreJSON.decode([QuestionDTO].self, row["questions_json"]).toDomain())
    }
}

extension Entry {
    /// An `entry` row. `answers_json` is request-shaped, so answers are normalized for `questions`
    /// (the entry's version's), keeping `7.0` a double.
    init(serverRow row: Row, questions: [Question]) throws {
        let id: String = row["id"]
        let channel: String = row["channel"]
        guard let channel = Channel(rawValue: channel) else { throw StoreError.corruptRow("entry \(id) channel") }
        self.init(
            id: try .wire(id, "entry.id"), topicId: try .wire(row["topic_id"], "entry.topic_id"),
            version: row["version"], revision: row["revision"], source: row["source"], channel: channel,
            capturedAt: Date(unixSeconds: row["captured_at"]), createdAt: Date(unixSeconds: row["created_at"]),
            updatedAt: Date(unixSeconds: row["updated_at"]), notes: row["notes"],
            meta: try StoreJSON.decode([String: String].self, row["meta_json"]),
            answers: try StoreJSON.decode([String: WireAnswer].self, row["answers_json"]).mapValues(\.value)
                .normalized(for: questions),
            timing: try (row["timing_json"] as String?).map { try StoreJSON.decode(TimingDTO.self, $0).toDomain() })
    }
}

extension Run {
    /// A `run` row.
    init(serverRow row: Row) throws {
        self = try StoreJSON.decode(RunDTO.self, row["run_json"]).toDomain()
    }
}

extension TopicVersion {
    init(serverRow row: Row) throws {
        self.init(
            version: row["version"],
            questions: try StoreJSON.decode([QuestionDTO].self, row["questions_json"]).toDomain(),
            timer: try (row["timer_json"] as String?).map { try StoreJSON.decode(TopicTimer.self, $0) },
            changeNote: row["change_note"], createdAt: Date(unixSeconds: row["created_at"]))
    }
}
