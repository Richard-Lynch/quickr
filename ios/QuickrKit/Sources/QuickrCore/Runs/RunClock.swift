import Foundation

/// Run-event time: the server's clock, monotonic per device (timers.md §5.1).
///
/// Pure helpers, the port of the PWA's `lib/runs/clock.ts`; the API client feeds them samples and
/// the outbox stamps events with them. All values are integer epoch milliseconds.
///
/// - Every `/api/v1` response carries `X-QuickR-Server-Time`, the server's time in integer epoch
///   milliseconds (`parseServerTime`).
/// - The client keeps one offset, from the **latest** response whose round trip took at most 5 s;
///   0 before the first sample (`nextOffset`).
/// - A run event's `at` is device now + offset, and always after the latest `at` among that run's
///   events in the local view (`stamp`).
public enum RunClock {
    public static let serverTimeHeader = "X-QuickR-Server-Time"

    /// Samples with a longer round trip are ignored.
    public static let maxSampleRoundTripMs = 5000

    /// The offset before the first sample.
    public static let initialOffsetMs = 0

    /// `X-QuickR-Server-Time`'s value as epoch milliseconds, or nil when it isn't an integer.
    public static func parseServerTime(_ value: String?) -> Int? {
        guard let text = value?.trimmingCharacters(in: .whitespaces), !text.isEmpty,
            text.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) })
        else { return nil }
        return Int(text)
    }

    /// One response's offset estimate, `server_time − (t_send + t_recv) / 2` (whole ms, floored),
    /// or nil when it doesn't qualify: a round trip over 5 s, or a negative one (the device clock
    /// moved during the request). `sent` and `received` are device epoch milliseconds, read just
    /// before the request and just after its response.
    public static func offsetSample(serverTime: Int, sent: Int, received: Int) -> Int? {
        let roundTrip = received - sent
        guard roundTrip >= 0, roundTrip <= maxSampleRoundTripMs else { return nil }
        return RunInstant.floorDiv(2 * serverTime - sent - received, 2)
    }

    /// The offset after a response: its sample when it qualifies (the latest wins), else `current`.
    public static func nextOffset(current: Int, serverTime: Int?, sent: Int, received: Int) -> Int {
        guard let serverTime else { return current }
        return offsetSample(serverTime: serverTime, sent: sent, received: received) ?? current
    }

    /// Device now plus the offset (§5.1 step 3).
    public static func serverNow(deviceNow: Int, offset: Int) -> Int { deviceNow + offset }

    /// `at`, clamped to at least the run's latest `at` + 1 ms (`max(at, latest + 1)`), so a
    /// device's own events stay in the order it made them. Strictly after: with an equal `at` the
    /// fold's id tie-break (§4.1) could put a later tap first and void the earlier one as stale.
    public static func clamp(_ at: Int, after latest: Int?) -> Int {
        guard let latest else { return at }
        return max(at, latest + 1)
    }

    /// The `at` for a new event of a run: device now + offset, clamped to just after the latest
    /// `at` among `runAts`, the run's events in the local view (its own queued ones and the
    /// server's). Offline, `offset` is simply the last one known.
    public static func stamp(deviceNow: Int, offset: Int, runAts: some Sequence<Int>) -> Int {
        clamp(serverNow(deviceNow: deviceNow, offset: offset), after: runAts.max())
    }

    /// `stamp` with the device clock read as a `Date` (truncated to the millisecond).
    public static func stamp(deviceNow: Date, offset: Int, runAts: some Sequence<Int>) -> Int {
        stamp(deviceNow: RunInstant.milliseconds(deviceNow), offset: offset, runAts: runAts)
    }
}
