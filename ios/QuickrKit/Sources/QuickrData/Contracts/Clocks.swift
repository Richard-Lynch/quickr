import Foundation

/// Wall-clock time: for display, `captured_at`, `created_at` and skew estimates only. Never for
/// leases, holds or backoff deadlines (sync-protocol.md §10).
///
/// Named `WallClock`, not `Clock`, so it doesn't shadow the standard library's `Clock`.
public protocol WallClock: Sendable {
    func now() -> Date
}

public struct SystemWallClock: WallClock {
    public init() {}

    public func now() -> Date { Date() }
}

/// A point in lease time: nanoseconds of `mach_continuous_time` since boot, paired with the boot
/// session id (sync-protocol.md §5.3). Comparable only within one boot.
public struct LeaseInstant: Sendable, Hashable {
    public var bootId: String
    /// Nanoseconds since boot, counting through sleep. Signed so it stores as an SQLite INTEGER.
    public var ct: Int64

    public init(bootId: String, ct: Int64) {
        self.bootId = bootId
        self.ct = ct
    }

    public func adding(_ duration: Duration) -> LeaseInstant {
        let (seconds, attoseconds) = duration.components
        let nanos = seconds * 1_000_000_000 + attoseconds / 1_000_000_000
        return LeaseInstant(bootId: bootId, ct: ct + nanos)
    }

    /// Whether a deadline stored as `(boot_id, ct)` has passed at this instant. A deadline from
    /// another boot has always passed (outbox.md §2, sync-protocol.md §5.3).
    public func hasPassed(deadline: LeaseInstant) -> Bool {
        deadline.bootId != bootId || ct >= deadline.ct
    }
}

/// Lease time, shared by every process on the device. The production implementation reads
/// `mach_continuous_time()` (scaled by `mach_timebase_info`) and `sysctl kern.bootsessionuuid`,
/// falling back to `kern.boottime` (sync-protocol.md §5.3); it lands with STORE.
public protocol LeaseClock: Sendable {
    func now() -> LeaseInstant
}
