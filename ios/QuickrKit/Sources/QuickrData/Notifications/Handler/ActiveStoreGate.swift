import GRDB
import QuickrCore

/// Which store is the active one now, for the notification handler's badge and flush
/// (notifications.md §7.1 steps 8 and 10, §8). The OS badge call and a flush can't be made atomic
/// with a server switch, so the handler decides with this, acts, and then checks again: the badge
/// is reconciled to whichever store is active afterwards, and a flush asks again once it holds its
/// lease, before it claims anything.
public protocol ActiveStoreGate: Sendable {
    /// The active store's server and generation; nil when there is none, or while the app is
    /// switching servers or binding (nothing counts as active then: the next activation
    /// recomputes the badge and flushes).
    func activeScope() async -> EntryScope?
}

/// The registry's active server at its current generation (no reset pending), read in one
/// transaction. For a process without a session, and for tests.
public struct RegistryActiveGate: ActiveStoreGate {
    let registry: Registry

    public init(registry: Registry) { self.registry = registry }

    public func activeScope() async -> EntryScope? {
        try? await registry.writer.read { db in try Self.activeScope(db) }
    }

    static func activeScope(_ db: Database) throws -> EntryScope? {
        guard
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT s.server_id, s.store_gen FROM active a JOIN server s ON s.server_id = a.server_id
                    WHERE s.pending_gen IS NULL
                    """)
        else { return nil }
        return EntryScope(serverId: row["server_id"], storeGen: row["store_gen"])
    }
}

/// The app's gate: its session's (`AppSession.activeScope()`).
public struct SessionActiveGate: ActiveStoreGate {
    let session: AppSession

    public init(session: AppSession) { self.session = session }

    public func activeScope() async -> EntryScope? { await session.activeScope() }
}
