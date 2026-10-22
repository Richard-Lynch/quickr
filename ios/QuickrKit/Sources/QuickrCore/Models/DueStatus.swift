import Foundation

/// Whether a topic is due, as computed by `compute_due` (server) or its Swift port (client).
/// The client recomputes it locally and ignores the server's value (sync-protocol.md §3.3).
public struct DueStatus: Sendable, Hashable {
    public var isDue: Bool
    public var dueSince: Date?
    public var nextDueAt: Date?
    public var lastEntryAt: Date?

    public init(isDue: Bool, dueSince: Date? = nil, nextDueAt: Date? = nil, lastEntryAt: Date? = nil) {
        self.isDue = isDue
        self.dueSince = dueSince
        self.nextDueAt = nextDueAt
        self.lastEntryAt = lastEntryAt
    }
}
