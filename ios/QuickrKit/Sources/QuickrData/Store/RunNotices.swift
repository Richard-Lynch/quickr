import Foundation
import GRDB
import QuickrCore

/// A §11.4 notice (timers.md): a run tap of this device that the server voided for a reason the
/// user is told about. Kept in the store (`run_notice`) from its ack until it is toasted or
/// dismissed, so the sync sheet still lists it after the app was ended.
public struct RunNotice: Sendable, Hashable, Identifiable {
    /// The event's id (its outbox item's).
    public var id: String
    public var runId: String
    public var topicId: String
    public var topicName: String
    public var tap: RunEventType
    public var reason: VoidReason
    /// The run's end (epoch ms), for `after_stop`.
    public var stoppedAt: Int?
    /// When the ack recorded it (wall clock).
    public var createdAt: Date

    public init(
        id: String, runId: String, topicId: String, topicName: String, tap: RunEventType, reason: VoidReason,
        stoppedAt: Int?, createdAt: Date
    ) {
        self.id = id
        self.runId = runId
        self.topicId = topicId
        self.topicName = topicName
        self.tap = tap
        self.reason = reason
        self.stoppedAt = stoppedAt
        self.createdAt = createdAt
    }

    /// What it says (`RunNoticeText`).
    public func text(locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        RunNoticeText.text(
            topic: topicName, tap: tap, reason: reason, stoppedAt: stoppedAt, locale: locale, timeZone: timeZone)
            ?? "\(topicName) was already stopped."
    }

    /// Nil for a row whose tap or reason this build doesn't know.
    init?(row: Row) {
        guard let tap = RunEventType(rawValue: row["tap"]), let reason = VoidReason(rawValue: row["reason"]) else {
            return nil
        }
        self.init(
            id: row["id"], runId: row["run_id"], topicId: row["topic_id"], topicName: row["topic_name"], tap: tap,
            reason: reason, stoppedAt: row["stopped_at"],
            createdAt: Date(timeIntervalSince1970: row["created_at"]))
    }
}

/// `run_notice`, read and written inside the caller's transaction.
enum RunNoticeStorage {
    /// Records `void` (once per event: a replayed ack keeps the first).
    static func record(_ db: Database, _ void: RunVoid, wall: Date) throws {
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO run_notice
                  (id, run_id, topic_id, topic_name, tap, reason, stopped_at, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                void.eventId.lowercased(), void.runId.lowercased(), void.topic.id.lowercased(), void.topic.name,
                void.type.rawValue, void.reason.rawValue, void.stoppedAt, wall.timeIntervalSince1970,
            ])
    }

    /// Oldest first.
    static func all(_ db: Database) throws -> [RunNotice] {
        try Row.fetchAll(db, sql: "SELECT * FROM run_notice ORDER BY created_at, id").compactMap(RunNotice.init(row:))
    }
}

/// The store's §11.4 notices: what the app toasts while on screen, and the sync sheet lists.
public struct GRDBRunNoticeRepository: Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    /// Every notice, oldest first.
    public func all() async throws -> [RunNotice] {
        try await writer.read { db in try RunNoticeStorage.all(db) }
    }

    /// `all()`, re-emitted on every change (another process's acks too, through `refresh`).
    public func observe(refresh: AsyncStream<Void>? = nil) -> AsyncThrowingStream<[RunNotice], any Error> {
        StoreObservation.values(in: writer, refresh: refresh) { db in try RunNoticeStorage.all(db) }
    }

    /// Removes a notice once it has been shown as a toast, or the user dismissed it.
    public func dismiss(id: String) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM run_notice WHERE id = ?", arguments: [id.lowercased()])
        }
    }
}
