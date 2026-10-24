import Foundation

/// What the sync pill shows (the PWA's `SyncIndicator`, plus the iOS-only pull states). Pure, so
/// every combination is tested on the host; the view only picks colours and icons.
public enum SyncPillState: Sendable, Hashable {
    /// All is well: no pill (as in the PWA).
    case hidden
    /// "This address now points to a different quickR server" (sync-protocol.md §8.3).
    case differentServer
    /// Items failed and need the user (Retry, Fix or Discard).
    case failed(count: Int)
    /// No network path, or the server can't be reached (the last pull got no response). `waiting`
    /// items will sync when it's back.
    case offline(waiting: Int)
    /// Items are queued or being sent. `checking`: some may have been delivered already (outbox
    /// §3, "Sending… (checking)").
    case waiting(count: Int, checking: Bool)
    /// The first pull of a new store (sync-protocol.md §2.1 step 5); `progress` in 0…1 when the
    /// head is known.
    case loadingHistory(progress: Double?)
    /// Pulls keep failing for another reason (a response that breaks the feed, a refusal, the
    /// store).
    case syncError
    /// Only §11.4 run notices are waiting (timers.md): the pill opens the sheet that lists them.
    case notices(count: Int)

    /// Pull failures in a row before the pill says "Sync error" (a single blip retries quietly).
    public static let failuresBeforeError = 3

    /// The pill for the outbox `summary` (nil before a store is open), the coordinator's
    /// `status`, and whether the device is `online`. Precedence: a different server, failed
    /// items, offline (no path, or the server unreachable), items waiting, the first pull,
    /// repeated pull failures, then `notices` (§11.4 run notices waiting for the sync sheet).
    public static func make(summary: OutboxSummary?, status: SyncStatus, online: Bool, notices: Int = 0)
        -> SyncPillState
    {
        if status.identityMismatch { return .differentServer }
        let failed = summary?.failed ?? 0
        if failed > 0 { return .failed(count: failed) }
        // A held delete is still in its undo window: it isn't waiting to sync yet.
        let waiting = max(0, (summary?.queued ?? 0) - (summary?.held ?? 0))
        let unreachable = if case .unreachable = status.lastFailure { true } else { false }
        if !online || unreachable { return .offline(waiting: waiting) }
        if waiting > 0 { return .waiting(count: waiting, checking: (summary?.uncertain ?? 0) > 0) }
        if case .pulling(bootstrapping: true, let cursor, let head) = status.activity {
            return .loadingHistory(progress: head > 0 ? min(1, Double(cursor) / Double(head)) : nil)
        }
        if status.lastFailure != nil, status.consecutiveFailures >= failuresBeforeError { return .syncError }
        if notices > 0 { return .notices(count: notices) }
        return .hidden
    }

    public var isVisible: Bool { self != .hidden }

    /// The pill's text (the PWA's labels where it has them).
    public var label: String {
        switch self {
        case .hidden: ""
        case .differentServer: "Different server"
        case .failed(let count): "\(count) failed to sync"
        case .offline(let waiting): waiting > 0 ? "Offline · \(waiting) waiting to sync" : "Offline"
        case .waiting(let count, _): "\(count) waiting to sync"
        case .loadingHistory: "Loading history"
        case .syncError: "Sync error"
        case .notices(let count): count == 1 ? "1 notice" : "\(count) notices"
        }
    }

    /// The compact text for narrow layouts (the PWA's small-screen label).
    public var shortLabel: String {
        switch self {
        case .failed(let count): "\(count) failed"
        case .waiting(let count, _): "\(count)"
        case .offline: "Offline"
        default: label
        }
    }

    /// VoiceOver: the full label, and what tapping does.
    public var accessibilityLabel: String {
        switch self {
        case .hidden: ""
        case .waiting(let count, true): "\(count) waiting to sync, checking"
        case .loadingHistory(let progress?): "Loading history, \(Int((progress * 100).rounded())) percent"
        default: label
        }
    }
}
