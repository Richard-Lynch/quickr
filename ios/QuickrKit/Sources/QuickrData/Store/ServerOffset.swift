import Foundation
import GRDB
import QuickrCore

/// The store's run-event offset (timers.md §5.1 item 2): each sample replaces
/// `sync_state.server_offset_ms` (the latest response wins, no smoothing). Any process may write
/// it; every process stamps with it (`RunWrites`). A sample beyond 24 hours is a broken clock or a
/// wrong server, not a skew to stamp taps with (the server would refuse such `at`s, §5), so it is
/// ignored. A sample within 5 ms of the stored offset writes nothing: the clocks haven't moved, and
/// a write would re-run every observation of `sync_state`. Best effort: a failed write (a retired or suspended store) keeps the previous offset.
public struct StoreServerOffset: ServerOffsetRecorder {
    public static let maxOffsetMs = 24 * 60 * 60 * 1000

    public let writer: any DatabaseWriter

    public init(store: LocalStore) { writer = store.writer }

    /// Samples this close to the stored offset are not written.
    public static let minChangeMs = 5

    public func record(offsetMs: Int) async {
        guard abs(offsetMs) <= Self.maxOffsetMs else { return }
        // Read first: a write that changes nothing would still wake every observer.
        let stored: Int?? = try? await writer.read { db in
            try Int.fetchOne(db, sql: "SELECT server_offset_ms FROM sync_state WHERE id = 1 AND retired = 0")
        }
        guard let current = stored ?? nil, abs(current - offsetMs) > Self.minChangeMs else { return }
        _ = try? await writer.write { db in
            try db.execute(
                sql: "UPDATE sync_state SET server_offset_ms = ? WHERE id = 1 AND retired = 0",
                arguments: [offsetMs])
        }
    }
}
