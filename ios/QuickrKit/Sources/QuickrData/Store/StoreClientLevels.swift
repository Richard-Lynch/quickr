import Foundation
import GRDB
import QuickrCore

/// The store's API-level state (client-versions.md §4.1, §4.5), in `sync_state`:
/// - `client_outdated_min` is set by a 426 `client_outdated` and by a response whose `ios`
///   minimum is above `APILevel.current`. It is cleared by a response whose minimum this build
///   meets (the server rolled back), and at the first open after an update (`clearIfMet`).
/// - `server_api_level` is the latest response's `X-QuickR-Api-Level`.
///
/// Any process may write both. A write that changes nothing is skipped, so it doesn't re-run every
/// observation of `sync_state`. Owed APNs deletions don't age while outdated: when the flag clears,
/// every owed row's `first_attempt_at` is reset to now (the registry's `pending_unregister`, just
/// before the store's transaction, since no registry transaction is ever open together with a
/// store one). Best effort: a failed write (a retired or suspended store) keeps the old state.
public struct StoreClientLevels: ClientLevelGate {
    public let store: LocalStore

    public init(store: LocalStore) { self.store = store }

    public func outdatedMinimum() async -> Int? {
        guard let stored = try? await read(), ClientOutdated.refuses(stored.minimum) else { return nil }
        return stored.minimum
    }

    public func record(_ levels: ServerLevels, outdatedMinimum: Int?) async {
        guard let stored = try? await read() else { return }
        var minimum = stored.minimum
        if let outdatedMinimum {
            // Refused: whatever it says, this build is below it.
            minimum = max(outdatedMinimum, levels.minClientLevelIOS ?? 0, APILevel.current + 1)
        } else if let demanded = levels.minClientLevelIOS {
            minimum = demanded > APILevel.current ? demanded : nil
        }
        let apiLevel = levels.apiLevel ?? stored.apiLevel
        guard minimum != stored.minimum || apiLevel != stored.apiLevel else { return }
        if stored.minimum != nil, minimum == nil { await resetOwedDeletions() }
        let (newMinimum, newApiLevel) = (minimum, apiLevel)
        _ = try? await store.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE sync_state SET client_outdated_min = ?, server_api_level = ?
                    WHERE id = 1 AND retired = 0
                    """,
                arguments: [newMinimum, newApiLevel])
        }
    }

    /// Clears a flag this build meets: the first open after an update.
    public func clearIfMet() async {
        guard let stored = try? await read(), let minimum = stored.minimum, !ClientOutdated.refuses(minimum) else {
            return
        }
        await resetOwedDeletions()
        _ = try? await store.writer.write { db in
            try db.execute(
                sql: "UPDATE sync_state SET client_outdated_min = NULL WHERE id = 1 AND client_outdated_min = ?",
                arguments: [minimum])
        }
    }

    private func read() async throws -> (minimum: Int?, apiLevel: Int?)? {
        try await store.writer.read { db in
            try Row.fetchOne(
                db, sql: "SELECT client_outdated_min, server_api_level FROM sync_state WHERE id = 1 AND retired = 0"
            ).map { ($0["client_outdated_min"], $0["server_api_level"]) }
        }
    }

    private func resetOwedDeletions() async {
        guard let registry = store.registry else { return }
        let now = store.wallClock.now()
        _ = try? await registry.writer.write { db in try PushRegistration.resetOwedAge(db, now: now) }
    }
}
