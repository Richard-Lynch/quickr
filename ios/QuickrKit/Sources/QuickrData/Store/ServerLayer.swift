import Foundation
import GRDB
import QuickrCore

/// Writes into the server layer (`topic`, `topic_version`, `entry`, `run`, `run_alias`,
/// `tombstone`, `run_closed`) or its staging copy, under the §4.2 upsert guards (sync-protocol.md
/// §4.2–§4.3) and, for runs, the closed-marker rules (timers2.md §5.2).
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
        /// Dropped: the run is closed here (`run_closed`) at or above the upsert's revision, or the
        /// upsert is an ack whose event isn't an applied `reopen` (timers2.md §5.2).
        case closed
    }

    /// The event an ack answers, for the marker rule (timers2.md §5.2): only an applied `reopen`
    /// may reopen a run this device holds as closed.
    public struct AckedEvent: Sendable, Hashable {
        public var type: RunEventType?
        public var effect: RunEffect

        public init(type: RunEventType?, effect: RunEffect) {
            self.type = type
            self.effect = effect
        }

        var reopens: Bool { type == .reopen && effect == .applied }
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
        // T2-M3
        try TopicAppearance.write(db, topic.appearance, topicId: id, table: layer.table("topic"))
        // end T2-M3
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
    /// are replaced by its `aliases`. Against a closed marker (no row) it applies only above the
    /// marker's revision and, for an ack (`acked`), only when the acked event is an applied
    /// `reopen`; applying clears the marker (timers2.md §5.2). A run deleted with its topic is
    /// tombstoned, never reopened.
    public static func upsert(
        _ db: Database, run: Run, into layer: Layer = .live, acked: AckedEvent? = nil
    ) throws -> UpsertOutcome {
        let id = run.id.wireString
        let topicId = run.topicId.wireString
        if try isTombstoned(db, kind: .run, id: id, layer: layer)
            || isTombstoned(db, kind: .topic, id: topicId, layer: layer)
        {
            return .tombstoned
        }
        if let stored = try revision(db, table: layer.table("run"), id: id) {
            if stored > run.revision { return .stale }
        } else if let marker = try closedMarker(db, id: id, layer: layer) {
            if run.revision <= marker { return .closed }
            if let acked, !acked.reopens { return .closed }
        }
        try db.execute(sql: "DELETE FROM \(layer.table("run_closed")) WHERE id = ?", arguments: [id])
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
    /// recorded as an alias of a run held here, so the local view re-keys this device's queued
    /// events to the run.
    ///
    /// The marker rules (timers2.md §5.2), with `type` the acked event's type: an open or
    /// finishing run is an upsert that, against a closed marker, applies only above it and only
    /// for an applied `reopen` (a delayed ack of an older tap never reopens a run). A closed run
    /// (stopped or discarded) is a close at `run.revision`: against a row it applies only when the
    /// row is older (a delayed stop ack never closes a run a newer reopen opened), deleting the
    /// row and writing the marker, its aliases and `sentTo` at ∞. Returns the run's upsert outcome
    /// (nil for a close).
    @discardableResult
    public static func apply(
        _ db: Database, runEvent result: RunEventResult, sentTo: UUID, type: RunEventType?, wall: Date
    ) throws -> UpsertOutcome? {
        let run = result.run
        if let entry = result.entry { _ = try upsert(db, entry: entry) }
        let closed = run.status == .stopped || run.status == .discarded
        // The open run first: its upsert replaces the run's alias rows with its `aliases`.
        let outcome =
            closed ? nil : try upsert(db, run: run, acked: AckedEvent(type: type, effect: result.effect))
        let id = run.id.wireString
        let topicId = run.topicId.wireString
        if try isTombstoned(db, kind: .topic, id: topicId) { return outcome }
        let alias = sentTo.wireString
        // A close records no alias row: if it applies, `sentTo` closes at ∞ with the run's aliases;
        // if it doesn't (a newer reopen), it is a no-op apart from the ack.
        if !closed, sentTo != run.id, try revision(db, table: "run", id: id) != nil,
            try !isTombstoned(db, kind: .run, id: alias)
        {
            try db.execute(
                sql: "INSERT OR REPLACE INTO run_alias (id, run_id, topic_id) VALUES (?, ?, ?)",
                arguments: [alias, id, topicId])
        }
        guard closed else { return outcome }
        try close(
            db, runId: id, revision: run.revision, aliases: run.aliases.map(\.wireString) + [alias], wall: wall,
            layer: .live)
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

    // MARK: - Tombstones (§4.3 steps 1, 2 and 4) and closed markers (timers2.md §5.2)

    /// Inserts the tombstone (idempotent) and deletes the row. A run's deletion means closed, not
    /// gone (timers2.md §5.1): no tombstone, but a closed marker at `revision` (∞ when nil: a topic
    /// cascade) and ∞ markers for its aliases, through `close`; its id may be an alias's (a topic's
    /// deletion lists them), whose row goes too. A
    /// topic tombstone also removes the topic's versions, entries, runs and aliases and tombstones
    /// them, runs and aliases as kind `run` (the local cascade incremental pages rely on, F3;
    /// timers.md §7.2; they are deleted, not closed); in the live layer it also clears the topic's
    /// `ui_draft`, `stats_cache` and `widget_state` rows. Dependent outbox items (step 3) are SYNC's.
    /// `wall` stamps a run's markers for the 30-day prune.
    public static func applyDeletion(
        _ db: Database, kind: Deletion.EntityKind, id: UUID, topicId: UUID, seq: Int?, revision: Int? = nil,
        wall: Date = Date(), into layer: Layer = .live
    ) throws {
        let id = id.wireString
        let topicId = topicId.wireString
        if kind == .run {
            try close(db, runId: id, revision: revision, aliases: [], wall: wall, layer: layer)
            return
        }
        try insertTombstone(db, kind: kind, id: id, topicId: topicId, seq: seq, layer: layer)
        switch kind {
        case .entry:
            try db.execute(sql: "DELETE FROM \(layer.table("entry")) WHERE id = ?", arguments: [id])
        case .version:
            try db.execute(sql: "DELETE FROM \(layer.table("topic_version")) WHERE id = ?", arguments: [id])
        case .run:
            break
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

    /// A close of run `runId` at `revision` (nil: ∞), from a feed deletion or a closing ack
    /// (timers2.md §5.2). Against a row it applies only when `revision` is above the row's (else
    /// the row is a newer state, a reopen, and this is a no-op): the row goes and the marker is
    /// raised to `revision`; the run's alias rows go, their ids and `aliases` raised to ∞ (an alias
    /// never becomes a run of its own). Against a marker it raises it. Returns whether it applied.
    @discardableResult
    static func close(
        _ db: Database, runId id: String, revision: Int?, aliases: [String], wall: Date, layer: Layer
    ) throws -> Bool {
        let fence = revision ?? StoreSchema.closedForever
        if let stored = try self.revision(db, table: layer.table("run"), id: id), stored >= fence { return false }
        try db.execute(sql: "DELETE FROM \(layer.table("run")) WHERE id = ?", arguments: [id])
        try raiseMarker(db, id: id, revision: fence, wall: wall, layer: layer)
        let aliasRows = try String.fetchAll(
            db, sql: "SELECT id FROM \(layer.table("run_alias")) WHERE run_id = ?", arguments: [id])
        for alias in Set(aliasRows + aliases.map { $0.lowercased() }) where alias != id {
            try raiseMarker(db, id: alias, revision: StoreSchema.closedForever, wall: wall, layer: layer)
        }
        try db.execute(
            sql: "DELETE FROM \(layer.table("run_alias")) WHERE run_id = ? OR id = ?", arguments: [id, id])
        return true
    }

    /// Every marker write is `max(existing, new)`: a marker is only ever raised (timers2.md §5.2).
    /// `closed_at` is the latest write.
    static func raiseMarker(_ db: Database, id: String, revision: Int, wall: Date, layer: Layer) throws {
        try db.execute(
            sql: """
                INSERT INTO \(layer.table("run_closed")) (id, revision, closed_at) VALUES (?, ?, ?)
                ON CONFLICT (id) DO UPDATE SET
                  revision = max(revision, excluded.revision), closed_at = excluded.closed_at
                """,
            arguments: [id, revision, markerTime(wall)])
    }

    /// The run's closed-marker revision (`StoreSchema.closedForever` for ∞), nil when it has none.
    public static func closedMarker(_ db: Database, id: String, layer: Layer = .live) throws -> Int? {
        try Int.fetchOne(
            db, sql: "SELECT revision FROM \(layer.table("run_closed")) WHERE id = ?", arguments: [id.lowercased()])
    }

    /// Whether `id` is a run (or alias) closed here: a closed marker, or a tombstone (a run
    /// deleted with its topic).
    public static func isClosedRun(_ db: Database, id: String) throws -> Bool {
        try closedMarker(db, id: id) != nil || isTombstoned(db, kind: .run, id: id.lowercased())
    }

    /// How long a closed marker is kept (timers2.md §5.2): far beyond any outcome the §5.5 fence
    /// still lets through (a lease TTL plus a request timeout).
    public static let markerLifetime: TimeInterval = 30 * 24 * 3600

    /// Drops the markers last written more than `markerLifetime` before `wall`, the ∞ ones too
    /// (the topic tombstone and the server's id rules cover them).
    public static func pruneClosedMarkers(_ db: Database, wall: Date, layer: Layer = .live) throws {
        try db.execute(
            sql: "DELETE FROM \(layer.table("run_closed")) WHERE julianday(closed_at) < julianday(?)",
            arguments: [markerTime(wall.addingTimeInterval(-markerLifetime))])
    }

    /// `closed_at`'s text: UTC, `RunInstant` precision, the shape the migration writes.
    static func markerTime(_ date: Date) -> String { RunInstant.format(RunInstant.milliseconds(date)) }

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

    /// Store JSON may predate a wire field (a run cached before fold v4): decoders that know
    /// such a field read it leniently here (`CodingUserInfoKey.storedJSON`), never off the wire.
    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let decoder = WireCoding.decoder()
        decoder.userInfo[.storedJSON] = true
        return try decoder.decode(type, from: Data(json.utf8))
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
