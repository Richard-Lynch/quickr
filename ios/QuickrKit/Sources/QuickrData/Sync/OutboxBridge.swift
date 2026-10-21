import Foundation
import Synchronization

// The two directions between the app's outbox and its coordinator (sync-protocol.md §5.6, §7,
// outbox.md §10). Extensions don't use these: they post `ChangeSignalName.syncRequested`, which
// `SyncCoordinator.listen(to:)` handles.
//
// Ownership: the coordinator holds the bridge, the bridge holds the bound scheduler, the
// scheduler holds its outbox, and the outbox holds its `onSignal`. Pass `outboxSignalHandler`
// (which holds the coordinator weakly) as `onSignal`, never a closure that captures the
// coordinator, or the four keep each other alive.

extension SyncCoordinator {
    /// The app's `Outbox.onSignal`. By the time a signal arrives the outbox has set its flag in
    /// the fenced outcome transaction and released `flush` (§5.6), so the coordinator only has to
    /// run, asynchronously: `.epochSuspect` and `.pullRequested` make its next live page confirm
    /// the epoch (or start the rebuild) and pull; `.identityMismatch` makes it re-probe, which
    /// returns `.identityMismatch` while the URL reaches another server (SYNC-UX shows the banner).
    /// Returns at once.
    public nonisolated func handle(_ signal: OutboxSignal) {
        switch signal {
        case .epochSuspect, .pullRequested, .identityMismatch:
            // A burst of signals spawns one run; a signal once it has started schedules another.
            let alreadyScheduled = signalRunPending.withLock { scheduled in
                defer { scheduled = true }
                return scheduled
            }
            guard !alreadyScheduled else { return }
            Task {
                self.signalRunPending.withLock { $0 = false }
                _ = await self.sync(reason: .requested)
            }
        }
    }

    /// `handle(_:)` with the coordinator held weakly: what to pass as `Outbox.onSignal` (see the
    /// ownership note above). A signal after the coordinator is gone is dropped.
    public nonisolated var outboxSignalHandler: @Sendable (OutboxSignal) -> Void {
        { [weak self] signal in self?.handle(signal) }
    }
}

/// The coordinator's `FlushRequester` in the app: forwards to the active store's
/// `OutboxFlushScheduler`. A scheduler belongs to one store, so bind it when a store opens, bind
/// the new one after a reset or a server switch, and bind nil when there is no store.
///
/// `bind` never lets two stores flush at once. Binds run one after another, each after every
/// earlier one has finished; each unbinds first (requests meanwhile are dropped), retires the
/// scheduler it replaces and waits for that one's flush to end, and only then publishes. Once
/// `bind` has returned, the old store never starts another flush. A request with nothing bound is
/// dropped (the binder requests a flush after binding).
public actor OutboxFlushBridge: FlushRequester {
    private var scheduler: OutboxFlushScheduler?
    /// The latest `bind`; the next one starts when it has finished.
    private var lastBind: Task<Void, Never>?
    /// A forward is scheduled and hasn't started: a burst of requests spawns one task.
    private nonisolated let pending = Mutex(false)

    public init() {}

    /// Binds `scheduler` (or nothing), after every earlier `bind`, retiring the one it replaces
    /// before publishing.
    public func bind(_ scheduler: OutboxFlushScheduler?) async {
        let previous = lastBind
        let bind = Task {
            await previous?.value
            await self.swap(to: scheduler)
        }
        lastBind = bind
        await bind.value
    }

    private func swap(to next: OutboxFlushScheduler?) async {
        let old = scheduler
        scheduler = nil
        if let old, old !== next {
            await old.retire()
            _ = await old.waitUntilIdle()
        }
        scheduler = next
    }

    public var bound: OutboxFlushScheduler? { scheduler }

    /// After a pull and after a swap alike, a non-forced flush that doesn't wait for the lease
    /// (outbox.md §10 "after a pull"): kept items are due and go out with the new epoch.
    public nonisolated func requestFlush(reason: FlushRequestReason) {
        let alreadyScheduled = pending.withLock { scheduled in
            defer { scheduled = true }
            return scheduled
        }
        guard !alreadyScheduled else { return }
        Task { await self.forward() }
    }

    private func forward() async {
        pending.withLock { $0 = false }  // a request from now on schedules another forward
        await scheduler?.requestFlush(reason: .afterPull)
    }
}
