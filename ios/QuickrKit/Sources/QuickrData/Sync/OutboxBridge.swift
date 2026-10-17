import Foundation
import Synchronization

// The two directions between the app's outbox and its coordinator (sync-protocol.md §5.6, §7,
// outbox.md §10). Extensions don't use these: they post `ChangeSignalName.syncRequested`, which
// `SyncCoordinator.listen(to:)` handles.

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
            Task { _ = await self.sync(reason: .requested) }
        }
    }
}

/// The coordinator's `FlushRequester` in the app: forwards to the active store's
/// `OutboxFlushScheduler`, which runs the flush under its own `flush` lease. The scheduler belongs
/// to a store, so bind it when a store opens and again after a reset or a server switch; a request
/// with nothing bound is dropped (the next enqueue, activation or timer flushes).
public final class OutboxFlushBridge: FlushRequester {
    private let scheduler = Mutex<OutboxFlushScheduler?>(nil)

    public init(_ scheduler: OutboxFlushScheduler? = nil) {
        self.scheduler.withLock { $0 = scheduler }
    }

    public func bind(_ scheduler: OutboxFlushScheduler?) {
        self.scheduler.withLock { $0 = scheduler }
    }

    /// After a pull and after a swap alike, a non-forced flush that doesn't wait for the lease
    /// (outbox.md §10 "after a pull"): kept items are due and go out with the new epoch.
    public func requestFlush(reason: FlushRequestReason) {
        guard let scheduler = scheduler.withLock({ $0 }) else { return }
        Task { await scheduler.requestFlush(reason: .afterPull) }
    }
}
