import Foundation

/// The server's clock as this device reads it (sync-protocol.md §10): device time plus a store's
/// measured skew (`sync_state.skew_ms`, 0 before the first sample). Due state, the badge and
/// widget timelines use it; `captured_at` and "… ago" text use the device clock.
public struct ServerClock: Sendable, Hashable {
    /// Server time minus device time, in seconds.
    public var skew: TimeInterval

    public init(skew: TimeInterval) { self.skew = skew }

    public init(skewMilliseconds: Double) { skew = skewMilliseconds / 1000 }

    /// No skew measured (yet): the device clock.
    public static let device = ServerClock(skew: 0)

    /// Device time `date` on the server's clock.
    public func now(at date: Date) -> Date { date.addingTimeInterval(skew) }
}
