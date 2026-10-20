import GRDB
import QuickrCore

/// Decides whether a store is the active one and acts on it in one step (notifications.md §7.1
/// steps 8 and 10, §8): the check and the start of `act` have no suspension between them, so a
/// server switch or a reset can't slip in after the decision. The badge and the flush are only
/// ever the active store's.
public protocol ActiveStoreGate: Sendable {
    /// Runs `act` if `scope` (a store's server and generation) is the active store's, returning
    /// its result; nil, without running it, otherwise.
    func whenActive<T: Sendable>(_ scope: EntryScope, _ act: @Sendable () async -> T) async -> T?
}

/// The registry's active server at its current generation (no reset pending), read in one
/// transaction just before `act`. For a process without a session and for tests: the registry is
/// written by other processes too, so a switch between that read and `act` isn't excluded. The
/// app uses its session's binding (`AppSession.whenActive`).
public struct RegistryActiveGate: ActiveStoreGate {
    let registry: Registry

    public init(registry: Registry) { self.registry = registry }

    public func whenActive<T: Sendable>(_ scope: EntryScope, _ act: @Sendable () async -> T) async -> T? {
        let active = try? await registry.writer.read { db in try Self.activeScope(db) }
        guard active == scope else { return nil }
        return await act()
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

extension AppSession {
    /// `ActiveStoreGate` over the session, on the main actor where the binding changes: the active
    /// store is the bound one. Before the session has bound (a launch in the background for a
    /// notification action) it is the registry's; the binding is checked again after that read,
    /// so a bind that happened meanwhile decides.
    public func whenActive<T: Sendable>(_ scope: EntryScope, _ act: @Sendable () async -> T) async -> T? {
        let registryScope: EntryScope? =
            if binding == nil {
                try? await registryActiveScope()
            } else {
                nil
            }
        guard (binding?.scope ?? registryScope) == scope else { return nil }
        return await act()
    }

    private func registryActiveScope() async throws -> EntryScope? {
        try await partitions.registry.writer.read { db in try RegistryActiveGate.activeScope(db) }
    }
}

/// The app's gate: its session's (`AppSession.whenActive`).
public struct SessionActiveGate: ActiveStoreGate {
    let session: AppSession

    public init(session: AppSession) { self.session = session }

    public func whenActive<T: Sendable>(_ scope: EntryScope, _ act: @Sendable () async -> T) async -> T? {
        await session.whenActive(scope, act)
    }
}
