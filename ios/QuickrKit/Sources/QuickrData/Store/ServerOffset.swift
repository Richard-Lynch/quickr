import Foundation
import GRDB
import QuickrCore

/// The store's run-event offset (timers.md §5.1 item 2): each sample replaces
/// `sync_state.server_offset_ms` (the latest response wins, no smoothing). Any process may write
/// it; every process stamps with it (`RunWrites`). A sample beyond 24 hours is a broken clock or a
/// wrong server, not a skew to stamp taps with (the server would refuse such `at`s, §5), so it is
/// ignored. Best effort: a failed write (a retired or suspended store) keeps the previous offset.
public struct StoreServerOffset: ServerOffsetRecorder {
    public static let maxOffsetMs = 24 * 60 * 60 * 1000

    public let writer: any DatabaseWriter

    public init(store: LocalStore) { writer = store.writer }

    public func record(offsetMs: Int) async {
        guard abs(offsetMs) <= Self.maxOffsetMs else { return }
        _ = try? await writer.write { db in
            try db.execute(
                sql:
                    "UPDATE sync_state SET server_offset_ms = ? WHERE id = 1 AND retired = 0 AND server_offset_ms != ?",
                arguments: [offsetMs, offsetMs])
        }
    }
}
