import Foundation

/// Why a flush is requested, which decides its policy (outbox.md §10). Platform wiring
/// (`scenePhase`, `NWPathMonitor`, `BGAppRefreshTask`, the foreground timer) is SYNC-UX's.
public enum OutboxFlushReason: Sendable, Hashable {
    /// The app enqueued something.
    case enqueue
    /// `scenePhase → active`.
    case activation
    /// `NWPathMonitor` satisfied.
    case networkAvailable
    /// The user tapped Retry.
    case retry
    /// The foreground timer for the earliest due time or hold.
    case timer
    case afterPull
    /// `scenePhase → background`: holds are released first; the caller cancels on expiration.
    case background
    /// `BGAppRefreshTask`, after the coordinator's pull; the caller cancels on expiration.
    case backgroundRefresh

    public var policy: OutboxFlushPolicy {
        switch self {
        case .enqueue: OutboxFlushPolicy(force: false, leaseWait: .milliseconds(2500))
        case .activation, .networkAvailable, .retry: OutboxFlushPolicy(force: true, leaseWait: .seconds(30))
        case .timer, .afterPull: OutboxFlushPolicy(force: false, leaseWait: .zero)
        case .background, .backgroundRefresh:
            OutboxFlushPolicy(force: true, leaseWait: .seconds(5), releasesAllHolds: self == .background)
        }
    }
}

/// How one flush runs (outbox.md §10).
public struct OutboxFlushPolicy: Sendable, Hashable {
    public var force: Bool
    /// The wall time the flush may spend; the app's default is "until the queue drains or a
    /// network error", bounded so a flush never runs unattended forever.
    public var budget: Duration
    /// How long to poll a busy `flush` lease; zero gives up at once.
    public var leaseWait: Duration
    public var releasesAllHolds: Bool

    public init(force: Bool, budget: Duration = .seconds(600), leaseWait: Duration, releasesAllHolds: Bool = false) {
        self.force = force
        self.budget = budget
        self.leaseWait = leaseWait
        self.releasesAllHolds = releasesAllHolds
    }

    /// An extension's flush (outbox.md §10): forced, one budget for everything, never waits for
    /// the lease (the widget and App Intents give up; the item stays queued). The notification
    /// action handler polls within its budget instead: `leaseWait = budget`.
    public static func extensionFlush(budget: Duration, pollsLease: Bool = false) -> OutboxFlushPolicy {
        OutboxFlushPolicy(force: true, budget: budget, leaseWait: pollsLease ? budget : .zero)
    }

    /// Two requests that arrive while a flush runs become one follow-up flush that does both.
    func merged(with other: OutboxFlushPolicy) -> OutboxFlushPolicy {
        OutboxFlushPolicy(
            force: force || other.force, budget: max(budget, other.budget), leaseWait: max(leaseWait, other.leaseWait),
            releasesAllHolds: releasesAllHolds || other.releasesAllHolds)
    }
}

/// The app's flush coalescer: `requestFlush` starts a flush, or, while one runs, schedules exactly
/// one follow-up with the merged policy. Extensions call `Outbox.flush` directly with
/// `OutboxFlushPolicy.extensionFlush`.
public actor OutboxFlushScheduler {
    public let outbox: Outbox
    private var running: Task<OutboxFlushReport?, Never>?
    private var followUp: OutboxFlushPolicy?
    private var retired = false
    private var paused = false
    /// The most recent report, for the sync pill and tests.
    public private(set) var lastReport: OutboxFlushReport?
    /// The policy of every flush this scheduler started, in order.
    public private(set) var started: [OutboxFlushPolicy] = []

    public init(outbox: Outbox) { self.outbox = outbox }

    /// Requests a flush and returns at once.
    public func requestFlush(reason: OutboxFlushReason) {
        request(reason.policy)
    }

    /// Requests a flush and waits for the flushes running or scheduled when it was made to end.
    @discardableResult
    public func flushNow(reason: OutboxFlushReason) async -> OutboxFlushReport? {
        request(reason.policy)
        return await waitUntilIdle()
    }

    /// Waits for the running flush and any follow-up to end, without requesting one.
    @discardableResult
    public func waitUntilIdle() async -> OutboxFlushReport? {
        // `finished` runs inside the task, so after each await `running` is nil or the follow-up.
        while let running { _ = await running.value }
        return lastReport
    }

    /// `sendNow` (outbox.md §10): flushes, then waits up to `wait` (2.5 s for a quick-log, 8 s
    /// for the record screen) for the item to leave the queue. True when it did; false means
    /// "queued" (or failed: read the item).
    public func sendNow(itemId: String, wait: Duration) async -> Bool {
        request(OutboxFlushReason.enqueue.policy)
        let deadline = ContinuousClock.now.advanced(by: wait)
        let repository = outbox.store.outbox
        while ContinuousClock.now < deadline {
            guard let item = try? await repository.item(id: itemId) else { return true }
            if item.state == .failed { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private func request(_ policy: OutboxFlushPolicy) {
        guard !retired, !paused else { return }
        guard running == nil else {
            followUp = followUp.map { $0.merged(with: policy) } ?? policy
            return
        }
        start(policy)
    }

    private func start(_ policy: OutboxFlushPolicy) {
        started.append(policy)
        let outbox = outbox
        running = Task {
            if policy.releasesAllHolds { _ = try? await outbox.releaseHolds(all: true) }
            let report = try? await outbox.flush(
                force: policy.force, budget: policy.budget, leaseWait: policy.leaseWait)
            self.finished(report)
            return report
        }
    }

    private func finished(_ report: OutboxFlushReport?) {
        if let report { lastReport = report }
        running = nil
        if !retired, !paused, let next = followUp {
            followUp = nil
            start(next)
        }
    }

    /// Cancels the running flush (a background task's expiration handler): its request is
    /// cancelled, its item becomes `uncertain` and the lease is released (§10).
    public func cancel() {
        followUp = nil
        running?.cancel()
    }

    /// Ends this scheduler for good (its store was reset, or the app switched servers): cancels
    /// the running flush, and refuses every later request, so once it returns no flush of this
    /// store starts again. `OutboxFlushBridge.bind` retires the scheduler it replaces.
    public func retire() {
        retired = true
        cancel()
    }

    public var isRetired: Bool { retired }

    /// The app is going to be suspended: cancels the running flush and starts no new one (for a
    /// pull, a signal or an enqueue) until `resume()`, so no flush transaction is open while the
    /// process is suspended. The queue keeps every item; activation flushes them.
    public func pause() {
        paused = true
        cancel()
    }

    public func resume() { paused = false }

    public var isPaused: Bool { paused }

    /// A flush is running (or its follow-up is about to start).
    public var isFlushing: Bool { running != nil }
}
