import Foundation
import Synchronization

/// Why a sync runs (sync-protocol.md §9). Recorded in the status; the loop is the same.
public enum SyncReason: String, Sendable, Hashable {
    case launch
    case bootstrap
    case activation
    case network
    case pullToRefresh
    case timer
    case afterFlush
    case afterOnlineOnly
    case background
    case push
    /// A non-coordinator saw a mismatch and asked for a run (§5.6).
    case requested
    case retry
}

/// Why a run stopped short of draining the feed.
public enum SyncFailure: Sendable, Hashable {
    /// No usable response (offline, timeout, 5xx, a proxy page, a redirect); retried with backoff.
    case unreachable(String)
    /// A response that breaks the feed contract (§2.2): it doesn't decode, or `next < cursor`.
    /// Nothing was applied; retried with backoff ("Sync error" if it persists).
    case protocolError(String)
    /// A non-2xx from quickR that retrying won't obviously fix (a 4xx). Retried with backoff.
    case rejected(status: Int, message: String?)
    /// A swap couldn't take `flush` in time (a sender held it); staging is kept and the swap is
    /// retried on the next run.
    case leaseBusy
    /// The store failed (SQLite, a corrupt row).
    case storage(String)
}

/// The result of one `sync` call.
public enum SyncResult: Sendable, Hashable {
    /// The feed is drained: the store is at the server's head.
    case synced
    /// Another coordinator holds `sync` (another app instance, or a reset).
    case busy
    /// No server is selected.
    case noActiveStore
    /// The store is in identity mismatch (§8.3): nothing is pulled until it is resolved.
    case identityMismatch
    /// A fence failed or the lease was lost: a newer coordinator owns the store (§5.5). The
    /// work stopped and wrote nothing.
    case superseded
    /// A local reset is running; sync resumes on the new file.
    case resetInProgress
    /// The app is going to be suspended (`SyncCoordinator.pause(generation:)`): no run starts until
    /// it becomes active again.
    case paused
    case failed(SyncFailure)
}

/// What the UI shows about sync (the sync pill, "Loading history", the mismatch banner,
/// Settings' clock warning).
public struct SyncStatus: Sendable, Hashable {
    public enum Activity: Sendable, Hashable {
        case idle
        /// Pulling the live feed. `bootstrapping` is true until the first drain (§2.1 step 5,
        /// "Loading history", progress `cursor / head`).
        case pulling(bootstrapping: Bool, cursor: Int, head: Int)
        /// Staging a rebuild (§7): the UI keeps showing the old data.
        case rebuilding(cursor: Int, head: Int)
        case resetting
    }

    public var serverId: String?
    public var activity: Activity = .idle
    /// `sync_state.last_pull_at`: the last page applied.
    public var lastSyncAt: Date?
    public var cursor: Int = 0
    public var headSeen: Int = 0
    public var bootstrapComplete = false
    /// A rebuild is staging (also while idle between runs).
    public var rebuilding = false
    public var epochSuspect = false
    /// "This address now points to a different quickR server" (§8.3).
    public var identityMismatch = false
    /// `server_time − device_time` (§10).
    public var skewMilliseconds: Double = 0
    /// The last run's failure, cleared by a drained run.
    public var lastFailure: SyncFailure?
    public var consecutiveFailures = 0
    /// When the automatic retry is due (lease-free monotonic delay from the failure).
    public var retryDelay: Duration?

    public init(serverId: String? = nil) { self.serverId = serverId }

    /// More changes are known to exist, or the last run failed.
    public var isBehind: Bool { cursor < headSeen || lastFailure != nil || rebuilding }

    /// Settings shows "Your iPhone's clock is off by X" past 5 minutes (§10).
    public var clockIsOff: Bool { abs(skewMilliseconds) > 300_000 }
}

/// Pull failure backoff (§9): `2 s · 2^(n−1)`, ±20 % jitter, capped at 5 minutes.
public enum SyncBackoff {
    public static let base: Duration = .seconds(2)
    public static let cap: Duration = .seconds(300)

    /// `failures` ≥ 1; `jitter` in −0.2…0.2.
    public static func delay(failures: Int, jitter: Double) -> Duration {
        let exponent = min(max(failures, 1) - 1, 16)
        let seconds = min(2.0 * pow(2.0, Double(exponent)), 300) * (1 + min(max(jitter, -0.2), 0.2))
        return min(.milliseconds(Int64(seconds * 1000)), cap)
    }
}

/// Fans one value out to any number of `AsyncStream`s, replaying the latest to new subscribers.
final class StatusBroadcaster: Sendable {
    private let state: Mutex<(value: SyncStatus, subscribers: [UUID: AsyncStream<SyncStatus>.Continuation])>

    init(_ initial: SyncStatus) { state = Mutex((initial, [:])) }

    var value: SyncStatus { state.withLock { $0.value } }

    func update(_ body: (inout SyncStatus) -> Void) {
        let (value, subscribers) = state.withLock { state -> (SyncStatus, [AsyncStream<SyncStatus>.Continuation]) in
            var value = state.value
            body(&value)
            guard value != state.value else { return (value, []) }
            state.value = value
            return (value, Array(state.subscribers.values))
        }
        for subscriber in subscribers { subscriber.yield(value) }
    }

    func stream() -> AsyncStream<SyncStatus> {
        let (stream, continuation) = AsyncStream.makeStream(of: SyncStatus.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        let current = state.withLock { state in
            state.subscribers[id] = continuation
            return state.value
        }
        continuation.yield(current)
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.subscribers.removeValue(forKey: id) }
        }
        return stream
    }
}
