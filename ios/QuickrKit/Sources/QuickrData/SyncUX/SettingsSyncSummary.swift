import Foundation

/// Settings ▸ "Offline & sync" (the PWA's `SyncSection`): online or offline, what is waiting,
/// when the last pull succeeded, and why pulls keep failing. Built on the sync pill's rules
/// (`SyncPillState`), so the two never disagree.
public struct SettingsSyncSummary: Sendable, Hashable {
    /// The section's badge.
    public enum Connection: Sendable, Hashable {
        case online
        /// No network path, or the server can't be reached.
        case offline
    }

    public var connection: Connection
    /// "All changes synced", or the pill's label ("3 waiting to sync", "1 failed to sync", …).
    public var headline: String
    /// The last successful pull; nil before the first.
    public var lastSyncAt: Date?
    /// Why pulls keep failing, once the pill says "Sync error".
    public var problem: String?
    /// Something to review in the sync sheet: items waiting or failed.
    public var hasItems: Bool

    public init(summary: OutboxSummary?, status: SyncStatus, online: Bool) {
        let pill = SyncPillState.make(summary: summary, status: status, online: online)
        connection = if case .offline = pill { .offline } else { .online }
        headline = pill == .hidden ? "All changes synced" : pill.label
        lastSyncAt = status.lastSyncAt
        problem = pill == .syncError ? status.lastFailure.map(Self.describe) : nil
        hasItems = (summary?.queued ?? 0) - (summary?.held ?? 0) > 0 || (summary?.failed ?? 0) > 0
    }

    static func describe(_ failure: SyncFailure) -> String {
        switch failure {
        case .unreachable(let reason): "Can't reach the server (\(reason))."
        case .protocolError(let reason): "The server's changes couldn't be read (\(reason))."
        case .rejected(let status, let message): message ?? "The server refused the request (\(status))."
        case .leaseBusy: "Another part of quickR was busy; it will try again."
        case .storage(let reason): "This iPhone's copy couldn't be updated (\(reason))."
        }
    }
}
