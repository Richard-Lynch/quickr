import Foundation

/// The foreground flush timer (outbox.md §10): it fires at the earliest backoff deadline or
/// hold, at most 60 s apart while something waits, and never sooner than 1 s (so an item that
/// stays due, because it is blocked or the flush is paused, doesn't spin).
public enum FlushTimerPolicy {
    public static let cap: Duration = .seconds(60)
    public static let floor: Duration = .seconds(1)

    /// How long to wait before the next timer flush, from the summary's `nextWake`; nil when
    /// nothing waits (no timer).
    public static func delay(until wake: LeaseInstant?, now: LeaseInstant) -> Duration? {
        guard let wake else { return nil }
        guard !now.hasPassed(deadline: wake) else { return floor }
        let remaining = Duration.nanoseconds(wake.ct - now.ct)
        return min(cap, max(floor, remaining))
    }
}

/// Sleeps for a duration; the timer's only source of time, so tests drive it.
public protocol FlushTimerSleeper: Sendable {
    func sleep(for duration: Duration) async throws
}

public struct ContinuousSleeper: FlushTimerSleeper {
    public init() {}

    public func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}

/// Runs the foreground timer: after each `reschedule()` (an outbox change, the app becoming
/// active, the timer's own flush) it asks for the next wake, sleeps until it, then `fire`s (a
/// non-forced `.timer` flush). Only one sleep is pending; a reschedule replaces it.
@MainActor
public final class ForegroundFlushTimer {
    private let sleeper: any FlushTimerSleeper
    private let nextWake: @Sendable () async -> LeaseInstant?
    private let now: @Sendable () -> LeaseInstant
    private let fire: @Sendable () async -> Void
    private var pending: Task<Void, Never>?
    /// What the last schedule decided (tests and diagnostics).
    public private(set) var scheduledDelay: Duration?

    public init(
        sleeper: any FlushTimerSleeper = ContinuousSleeper(), nextWake: @escaping @Sendable () async -> LeaseInstant?,
        now: @escaping @Sendable () -> LeaseInstant, fire: @escaping @Sendable () async -> Void
    ) {
        self.sleeper = sleeper
        self.nextWake = nextWake
        self.now = now
        self.fire = fire
    }

    /// Replaces the pending sleep with one for the current next wake (none when nothing waits).
    public func reschedule() {
        pending?.cancel()
        let (sleeper, nextWake, now, fire) = (sleeper, nextWake, now, fire)
        pending = Task { [weak self] in
            let delay = FlushTimerPolicy.delay(until: await nextWake(), now: now())
            guard !Task.isCancelled else { return }
            self?.scheduledDelay = delay
            guard let delay else { return }
            do {
                try await sleeper.sleep(for: delay)
            } catch {
                return  // replaced or stopped
            }
            guard !Task.isCancelled else { return }
            await fire()
            self?.reschedule()
        }
    }

    /// No timer (the app went to the background, or the store closed).
    public func stop() {
        pending?.cancel()
        pending = nil
        scheduledDelay = nil
    }
}
